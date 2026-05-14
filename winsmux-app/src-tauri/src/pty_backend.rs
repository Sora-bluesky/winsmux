use serde::{Deserialize, Serialize};
use serde_json::Value;

const PTY_JSON_RPC_VERSION: &str = "2.0";
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_SERVER_ERROR: i32 = -32000;

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
        "pty.spawn" => Ok(PtyCommand::Spawn {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
            cols: get_required_u16_param(params, &["cols"])?,
            rows: get_required_u16_param(params, &["rows"])?,
            startup_input: get_optional_string_param(params, &["startupInput", "startup_input"])?,
        }),
        "pty.write" => Ok(PtyCommand::Write {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
            data: get_required_pty_data_param(params, &["data"])?,
        }),
        "pty.resize" => Ok(PtyCommand::Resize {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
            cols: get_required_u16_param(params, &["cols"])?,
            rows: get_required_u16_param(params, &["rows"])?,
        }),
        "pty.capture" => Ok(PtyCommand::Capture {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
            lines: get_optional_u16_param(params, &["lines"])?,
        }),
        "pty.respawn" => Ok(PtyCommand::Respawn {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
        }),
        "pty.close" => Ok(PtyCommand::Close {
            pane_id: get_required_string_param(params, &["paneId", "pane_id"])?,
        }),
        _ => Err(ParseError::MethodNotFound(format!(
            "Unknown pty JSON-RPC method: {method}"
        ))),
    }
}

fn get_required_string_param(params: Option<&Value>, keys: &[&str]) -> Result<String, ParseError> {
    let object = params
        .and_then(Value::as_object)
        .ok_or_else(|| ParseError::InvalidParams(invalid_params(keys)))?;

    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Ok(trimmed.to_string());
            }
        }
    }

    Err(ParseError::InvalidParams(invalid_params(keys)))
}

fn get_optional_string_param(
    params: Option<&Value>,
    keys: &[&str],
) -> Result<Option<String>, ParseError> {
    let Some(object) = params.and_then(Value::as_object) else {
        return Ok(None);
    };

    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_str) {
            if !value.is_empty() {
                return Ok(Some(value.to_string()));
            }
        }
    }

    Ok(None)
}

fn get_required_pty_data_param(
    params: Option<&Value>,
    keys: &[&str],
) -> Result<String, ParseError> {
    let object = params
        .and_then(Value::as_object)
        .ok_or_else(|| ParseError::InvalidParams(invalid_params(keys)))?;

    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_str) {
            if !value.is_empty() {
                return Ok(value.to_string());
            }
        }
    }

    Err(ParseError::InvalidParams(invalid_params(keys)))
}

fn get_required_u16_param(params: Option<&Value>, keys: &[&str]) -> Result<u16, ParseError> {
    let object = params
        .and_then(Value::as_object)
        .ok_or_else(|| ParseError::InvalidParams(invalid_params(keys)))?;

    for key in keys {
        if let Some(raw) = object.get(*key).and_then(Value::as_u64) {
            let value = u16::try_from(raw).map_err(|_| {
                ParseError::InvalidParams(format!(
                    "Invalid params field {}: expected 0-65535",
                    keys.join(" or ")
                ))
            })?;
            return Ok(value);
        }
    }

    Err(ParseError::InvalidParams(invalid_params(keys)))
}

fn get_optional_u16_param(
    params: Option<&Value>,
    keys: &[&str],
) -> Result<Option<u16>, ParseError> {
    let Some(object) = params.and_then(Value::as_object) else {
        return Ok(None);
    };

    for key in keys {
        if let Some(raw) = object.get(*key).and_then(Value::as_u64) {
            let value = u16::try_from(raw).map_err(|_| {
                ParseError::InvalidParams(format!(
                    "Invalid params field {}: expected 0-65535",
                    keys.join(" or ")
                ))
            })?;
            return Ok(Some(value));
        }
    }

    Ok(None)
}

fn invalid_params(keys: &[&str]) -> String {
    format!("Missing required params field: {}", keys.join(" or "))
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
                startup_input: None
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
                startup_input: Some("claude\r".to_string())
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
}
