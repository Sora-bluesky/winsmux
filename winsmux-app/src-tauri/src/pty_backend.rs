use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

const PTY_JSON_RPC_VERSION: &str = "2.0";
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_SERVER_ERROR: i32 = -32000;

pub const OPERATOR_PANE_ID: &str = "operator";

pub const OPERATOR_CONTROL_PIPE_METHODS: &[&str] =
    &["desktop.operator.snapshot", "desktop.operator.submit"];

pub const PTY_CONTROL_PIPE_METHODS: &[&str] = &[
    "pty.spawn",
    "pty.write",
    "pty.resize",
    "pty.capture",
    "pty.respawn",
    "pty.close",
];

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtySpawnParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
    pub cols: u16,
    pub rows: u16,
    #[serde(
        default,
        rename = "startupInput",
        alias = "startup_input",
        deserialize_with = "optional_json_string"
    )]
    pub startup_input: Option<String>,
    #[serde(default, deserialize_with = "optional_json_string")]
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtyWriteParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
    pub data: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtyResizeParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtyCaptureParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
    #[serde(default, deserialize_with = "optional_json_u16")]
    pub lines: Option<u16>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtyRespawnParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PtyCloseParams {
    #[serde(rename = "paneId", alias = "pane_id")]
    pub pane_id: String,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct OperatorSnapshotParams {
    #[serde(default, deserialize_with = "optional_json_u16")]
    pub lines: Option<u16>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct OperatorSubmitParams {
    #[serde(alias = "message", alias = "data")]
    pub text: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PtyPaneResult {
    #[serde(rename = "paneId")]
    pub pane_id: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PtyCaptureResult {
    #[serde(rename = "paneId")]
    pub pane_id: String,
    pub output: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct OperatorSubmitResult {
    #[serde(rename = "paneId")]
    pub pane_id: String,
    pub submitted: bool,
}

#[derive(Deserialize)]
pub struct PtyJsonRpcRequest {
    pub jsonrpc: String,
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PtyJsonRpcError {
    pub code: i32,
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(untagged)]
pub enum PtyJsonRpcResponse {
    Success {
        jsonrpc: String,
        id: Value,
        result: Value,
    },
    Error {
        jsonrpc: String,
        id: Value,
        error: PtyJsonRpcError,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum PtyCommand {
    Spawn {
        pane_id: String,
        cols: u16,
        rows: u16,
        startup_input: Option<String>,
        cwd: Option<String>,
    },
    Write {
        pane_id: String,
        data: String,
    },
    Resize {
        pane_id: String,
        cols: u16,
        rows: u16,
    },
    Capture {
        pane_id: String,
        lines: Option<u16>,
    },
    OperatorSnapshot {
        lines: Option<u16>,
    },
    OperatorSubmit {
        text: String,
        submit_after_paste: bool,
    },
    Respawn {
        pane_id: String,
    },
    Close {
        pane_id: String,
    },
}

pub trait PtyCommandTransport {
    fn execute(&self, command: &PtyCommand) -> Result<Value, String>;
}

pub fn handle_pty_json_rpc(
    transport: &dyn PtyCommandTransport,
    request: PtyJsonRpcRequest,
) -> PtyJsonRpcResponse {
    let request_id = request.id.clone();
    if request.jsonrpc != PTY_JSON_RPC_VERSION {
        return json_rpc_error(
            request_id,
            JSON_RPC_INVALID_REQUEST,
            "pty_json_rpc expects jsonrpc=\"2.0\"",
        );
    }

    let command = match parse_command(request.method.as_str(), request.params.as_ref()) {
        Ok(command) => command,
        Err(ParseError::InvalidParams(message)) => {
            return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, message);
        }
        Err(ParseError::MethodNotFound(message)) => {
            return json_rpc_error(request_id, JSON_RPC_METHOD_NOT_FOUND, message);
        }
    };

    match transport.execute(&command) {
        Ok(result) => json_rpc_result(request_id, result),
        Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
    }
}

enum ParseError {
    InvalidParams(String),
    MethodNotFound(String),
}

fn parse_command(method: &str, params: Option<&Value>) -> Result<PtyCommand, ParseError> {
    match method {
        "pty.spawn" => {
            let parsed = deserialize_params::<PtySpawnParams>(params)?;
            Ok(PtyCommand::Spawn {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
                cols: parsed.cols,
                rows: parsed.rows,
                startup_input: optional_untrimmed_string(parsed.startup_input),
                cwd: optional_untrimmed_string(parsed.cwd),
            })
        }
        "pty.write" => {
            let parsed = deserialize_params::<PtyWriteParams>(params)?;
            Ok(PtyCommand::Write {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
                data: required_untrimmed_string(&parsed.data)?,
            })
        }
        "pty.resize" => {
            let parsed = deserialize_params::<PtyResizeParams>(params)?;
            Ok(PtyCommand::Resize {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
                cols: parsed.cols,
                rows: parsed.rows,
            })
        }
        "pty.capture" => {
            let parsed = deserialize_params::<PtyCaptureParams>(params)?;
            Ok(PtyCommand::Capture {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
                lines: parsed.lines,
            })
        }
        "desktop.operator.snapshot" => {
            reject_operator_pane_override(params)?;
            let parsed = deserialize_params::<OperatorSnapshotParams>(params)?;
            Ok(PtyCommand::OperatorSnapshot {
                lines: parsed.lines,
            })
        }
        "desktop.operator.submit" => {
            reject_operator_pane_override(params)?;
            let parsed = deserialize_params::<OperatorSubmitParams>(params)?;
            let (text, submit_after_paste) =
                normalize_operator_submit_text(required_untrimmed_string(&parsed.text)?);
            Ok(PtyCommand::OperatorSubmit {
                text,
                submit_after_paste,
            })
        }
        "pty.respawn" => {
            let parsed = deserialize_params::<PtyRespawnParams>(params)?;
            Ok(PtyCommand::Respawn {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
            })
        }
        "pty.close" => {
            let parsed = deserialize_params::<PtyCloseParams>(params)?;
            Ok(PtyCommand::Close {
                pane_id: required_trimmed_string(&parsed.pane_id)?,
            })
        }
        _ => Err(ParseError::MethodNotFound(format!(
            "Unknown pty JSON-RPC method: {method}"
        ))),
    }
}

fn reject_operator_pane_override(params: Option<&Value>) -> Result<(), ParseError> {
    let Some(object) = params.and_then(Value::as_object) else {
        return Ok(());
    };

    for key in ["paneId", "pane_id"] {
        if object.contains_key(key) {
            return Err(ParseError::InvalidParams(
                "desktop.operator.* methods always target the operator pane; remove paneId"
                    .to_string(),
            ));
        }
    }

    Ok(())
}

fn normalize_operator_submit_text(text: String) -> (String, bool) {
    let text = text
        .trim_end_matches(|character| character == '\r' || character == '\n')
        .to_string();
    if text.contains('\r') || text.contains('\n') {
        return (format!("\x1b[200~{text}\x1b[201~"), true);
    }
    (format!("{text}\r"), false)
}


fn optional_json_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(value.and_then(|item| item.as_str().map(str::to_string)))
}

fn optional_json_u16<'de, D>(deserializer: D) -> Result<Option<u16>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    let Some(value) = value else {
        return Ok(None);
    };
    let Some(raw) = value.as_u64() else {
        return Ok(None);
    };
    u16::try_from(raw).map(Some).map_err(|_| {
        serde::de::Error::custom("Invalid params field lines: expected 0-65535")
    })
}

fn deserialize_params<T: DeserializeOwned>(params: Option<&Value>) -> Result<T, ParseError> {
    let value = match params {
        Some(Value::Null) | None => Value::Object(Default::default()),
        Some(value) => value.clone(),
    };
    serde_json::from_value(value).map_err(|err| ParseError::InvalidParams(err.to_string()))
}

fn required_trimmed_string(value: &str) -> Result<String, ParseError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(ParseError::InvalidParams(
            "Missing required params field: paneId or pane_id".to_string(),
        ));
    }
    Ok(trimmed.to_string())
}

fn required_untrimmed_string(value: &str) -> Result<String, ParseError> {
    if value.is_empty() {
        return Err(ParseError::InvalidParams(
            "Missing required params field".to_string(),
        ));
    }
    Ok(value.to_string())
}

fn optional_untrimmed_string(value: Option<String>) -> Option<String> {
    value.filter(|item| !item.is_empty())
}

fn json_rpc_result(id: Value, result: Value) -> PtyJsonRpcResponse {
    PtyJsonRpcResponse::Success {
        jsonrpc: PTY_JSON_RPC_VERSION.to_string(),
        id,
        result,
    }
}

fn json_rpc_error(id: Value, code: i32, message: impl Into<String>) -> PtyJsonRpcResponse {
    PtyJsonRpcResponse::Error {
        jsonrpc: PTY_JSON_RPC_VERSION.to_string(),
        id,
        error: PtyJsonRpcError {
            code,
            message: message.into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeTransport {
        commands: RefCell<Vec<PtyCommand>>,
        response: Value,
    }

    impl PtyCommandTransport for FakeTransport {
        fn execute(&self, command: &PtyCommand) -> Result<Value, String> {
            self.commands.borrow_mut().push(command.clone());
            Ok(self.response.clone())
        }
    }

    #[test]
    fn handle_pty_json_rpc_routes_spawn() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-1"),
                method: "pty.spawn".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "cols": 120,
                    "rows": 40
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-1"));
                assert_eq!(result["paneId"], "pane-1");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Spawn {
                pane_id: "pane-1".to_string(),
                cols: 120,
                rows: 40,
                startup_input: None,
                cwd: None
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_spawn_startup_input() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "main" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-startup"),
                method: "pty.spawn".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "main",
                    "cols": 120,
                    "rows": 40,
                    "startupInput": "claude\r"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "main");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Spawn {
                pane_id: "main".to_string(),
                cols: 120,
                rows: 40,
                startup_input: Some("claude\r".to_string()),
                cwd: None
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_spawn_cwd() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "fork-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-cwd"),
                method: "pty.spawn".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "fork-1",
                    "cols": 80,
                    "rows": 24,
                    "startupInput": "codex\r",
                    "cwd": "C:/proj"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "fork-1");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Spawn {
                pane_id: "fork-1".to_string(),
                cols: 80,
                rows: 24,
                startup_input: Some("codex\r".to_string()),
                cwd: Some("C:/proj".to_string())
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_capture() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "paneId": "pane-1",
                "output": "ready"
            }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-capture"),
                method: "pty.capture".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "lines": 25
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["output"], "ready");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Capture {
                pane_id: "pane-1".to_string(),
                lines: Some(25)
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_operator_snapshot_without_pane_override() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "paneId": "operator",
                "output": "operator waiting"
            }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-operator-snapshot"),
                method: "desktop.operator.snapshot".to_string(),
                params: Some(serde_json::json!({
                    "lines": 80
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "operator");
                assert_eq!(result["output"], "operator waiting");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::OperatorSnapshot { lines: Some(80) }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_operator_submit_with_enter() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "paneId": "operator",
                "submitted": true
            }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-operator-submit"),
                method: "desktop.operator.submit".to_string(),
                params: Some(serde_json::json!({
                    "text": "Continue with option 1"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "operator");
                assert_eq!(result["submitted"], true);
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::OperatorSubmit {
                text: "Continue with option 1\r".to_string(),
                submit_after_paste: false,
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_multiline_operator_submit_with_bracketed_paste_and_enter() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "paneId": "operator",
                "submitted": true
            }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-operator-submit"),
                method: "desktop.operator.submit".to_string(),
                params: Some(serde_json::json!({
                    "text": "Line one\nLine two\n"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "operator");
                assert_eq!(result["submitted"], true);
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::OperatorSubmit {
                text: "\x1b[200~Line one\nLine two\x1b[201~".to_string(),
                submit_after_paste: true,
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_rejects_operator_pane_override() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-operator-override"),
                method: "desktop.operator.submit".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "worker-1",
                    "text": "Do not route to a worker directly"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
                assert!(error.message.contains("operator pane"));
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }

    #[test]
    fn handle_pty_json_rpc_routes_write_preserves_control_data() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-write"),
                method: "pty.write".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "data": "echo ready\r"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "pane-1");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Write {
                pane_id: "pane-1".to_string(),
                data: "echo ready\r".to_string()
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_write_allows_enter_only() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-enter"),
                method: "pty.write".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "data": "\r"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "pane-1");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Write {
                pane_id: "pane-1".to_string(),
                data: "\r".to_string()
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_routes_respawn() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-respawn"),
                method: "pty.respawn".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["paneId"], "pane-1");
            }
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Respawn {
                pane_id: "pane-1".to_string()
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_requires_pane_id() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-2"),
                method: "pty.close".to_string(),
                params: Some(serde_json::json!({})),
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }

    #[test]
    fn handle_pty_json_rpc_rejects_unknown_method() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-3"),
                method: "pty.unknown".to_string(),
                params: None,
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_METHOD_NOT_FOUND);
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected method not found error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }

    #[test]
    fn handle_pty_json_rpc_rejects_duplicate_pane_id_aliases() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-dup"),
                method: "pty.close".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "pane_id": "pane-1"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }

    #[test]
    fn handle_pty_json_rpc_ignores_invalid_optional_spawn_fields() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-optional-types"),
                method: "pty.spawn".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "cols": 120,
                    "rows": 40,
                    "startupInput": 123,
                    "cwd": true
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { .. } => {}
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Spawn {
                pane_id: "pane-1".to_string(),
                cols: 120,
                rows: 40,
                startup_input: None,
                cwd: None
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_ignores_invalid_optional_capture_lines() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({ "paneId": "pane-1", "output": "" }),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-lines"),
                method: "pty.capture".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "lines": "all"
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Success { .. } => {}
            PtyJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        assert_eq!(
            transport.commands.borrow().as_slice(),
            [PtyCommand::Capture {
                pane_id: "pane-1".to_string(),
                lines: None
            }]
        );
    }

    #[test]
    fn handle_pty_json_rpc_rejects_out_of_range_optional_capture_lines() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-lines-range"),
                method: "pty.capture".to_string(),
                params: Some(serde_json::json!({
                    "paneId": "pane-1",
                    "lines": 65536
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }

    #[test]
    fn handle_pty_json_rpc_rejects_out_of_range_optional_snapshot_lines() {
        let transport = FakeTransport {
            commands: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };

        let response = handle_pty_json_rpc(
            &transport,
            PtyJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-snap-range"),
                method: "desktop.operator.snapshot".to_string(),
                params: Some(serde_json::json!({
                    "lines": 65536
                })),
            },
        );

        match response {
            PtyJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            PtyJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }

        assert!(transport.commands.borrow().is_empty());
    }
}
