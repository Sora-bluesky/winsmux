use serde_json::Value;

use crate::desktop_backend::{
    DesktopCommand, DesktopCommandTransport, DesktopJsonRpcError, DesktopJsonRpcResponse,
    DESKTOP_JSON_RPC_VERSION, JSON_RPC_INVALID_PARAMS, JSON_RPC_SERVER_ERROR,
};

pub fn load_desktop_team_profile_settings_view(
    transport: &dyn DesktopCommandTransport,
    project_dir: Option<String>,
) -> Result<Value, String> {
    transport.request_json(&DesktopCommand::TeamProfileSettingsView { project_dir })
}

pub fn reset_desktop_team_profile_field(
    transport: &dyn DesktopCommandTransport,
    slot_id: String,
    field: String,
    project_dir: Option<String>,
) -> Result<Value, String> {
    transport.request_json(&DesktopCommand::TeamProfileResetField {
        slot_id,
        field,
        project_dir,
    })
}

pub fn json_rpc_settings_view(
    transport: &dyn DesktopCommandTransport,
    id: Value,
    project_dir: Option<String>,
) -> DesktopJsonRpcResponse {
    match load_desktop_team_profile_settings_view(transport, project_dir) {
        Ok(result) => DesktopJsonRpcResponse::Success {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            result,
        },
        Err(message) => DesktopJsonRpcResponse::Error {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            error: DesktopJsonRpcError {
                code: JSON_RPC_SERVER_ERROR,
                message,
            },
        },
    }
}

pub fn json_rpc_reset_field(
    transport: &dyn DesktopCommandTransport,
    id: Value,
    project_dir: Option<String>,
    params: Option<Value>,
) -> DesktopJsonRpcResponse {
    let slot_id = match get_required_string_param(params.as_ref(), &["slotId", "slot_id", "slot"]) {
        Ok(value) => value,
        Err(message) => {
            return DesktopJsonRpcResponse::Error {
                jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
                id,
                error: DesktopJsonRpcError {
                    code: JSON_RPC_INVALID_PARAMS,
                    message,
                },
            };
        }
    };
    let field = match get_required_string_param(params.as_ref(), &["field"]) {
        Ok(value) => value,
        Err(message) => {
            return DesktopJsonRpcResponse::Error {
                jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
                id,
                error: DesktopJsonRpcError {
                    code: JSON_RPC_INVALID_PARAMS,
                    message,
                },
            };
        }
    };

    match reset_desktop_team_profile_field(transport, slot_id, field, project_dir) {
        Ok(result) => DesktopJsonRpcResponse::Success {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            result,
        },
        Err(message) => DesktopJsonRpcResponse::Error {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            error: DesktopJsonRpcError {
                code: JSON_RPC_SERVER_ERROR,
                message,
            },
        },
    }
}

fn get_optional_string_param(params: Option<&Value>, keys: &[&str]) -> Option<String> {
    let object = params?.as_object()?;
    for key in keys {
        if let Some(value) = object.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn get_required_string_param(params: Option<&Value>, keys: &[&str]) -> Result<String, String> {
    get_optional_string_param(params, keys)
        .ok_or_else(|| format!("Missing required desktop JSON-RPC parameter: {}", keys.join("|")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_backend::{
        handle_desktop_json_rpc, DesktopJsonRpcRequest, DesktopJsonRpcResponse,
    };
    use serde_json::Value;
    use std::cell::RefCell;

    struct FakeTransport {
        requests: RefCell<Vec<String>>,
        response: Value,
    }

    impl DesktopCommandTransport for FakeTransport {
        fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
            self.requests
                .borrow_mut()
                .push(command.winsmux_args().join(" "));
            Ok(self.response.clone())
        }
    }

    #[test]
    fn handle_desktop_json_rpc_routes_team_profile_settings_view() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "schema_version": 1,
                "action": "settings-view",
                "ok": true,
                "opted_in": true,
                "rows": []
            }),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-team-profile-view"),
                method: "desktop.team_profile.settings_view".to_string(),
                params: Some(serde_json::json!({})),
            },
            None,
        );
        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-team-profile-view"));
                assert_eq!(result["action"], "settings-view");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["team-profile --action settings-view --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_team_profile_reset_field() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({"schema_version":1,"ok":true,"action":"reset-field"}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-team-profile-reset"),
                method: "desktop.team_profile.reset_field".to_string(),
                params: Some(serde_json::json!({
                    "slotId": "worker-1",
                    "field": "provider"
                })),
            },
            None,
        );
        match response {
            DesktopJsonRpcResponse::Success { result, .. } => {
                assert_eq!(result["action"], "reset-field");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["team-profile --action reset-field --slot-id worker-1 --field provider --json"]
        );
    }
}
