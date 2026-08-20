use std::collections::HashMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::desktop_backend::{
    DesktopCommand, DesktopCommandTransport, DesktopJsonRpcError, DesktopJsonRpcResponse,
    DESKTOP_JSON_RPC_VERSION, JSON_RPC_INTERNAL_ERROR, JSON_RPC_SERVER_ERROR,
};
use crate::desktop_control_plane_params::consume_external_params;

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct DesktopProviderCapabilitiesParams {}

#[derive(Serialize, Deserialize, JsonSchema)]
pub struct DesktopProviderCapabilitiesSnapshot {
    pub version: u64,
    pub providers: HashMap<String, Value>,
}

pub fn load_desktop_provider_capabilities(
    transport: &dyn DesktopCommandTransport,
    project_dir: Option<String>,
) -> Result<DesktopProviderCapabilitiesSnapshot, String> {
    let snapshot =
        transport.request_json(&DesktopCommand::ProviderCapabilities { project_dir })?;
    serde_json::from_value(snapshot).map_err(|err| {
        format!("Failed to parse desktop provider capabilities payload: {err}")
    })
}

pub fn json_rpc(
    transport: &dyn DesktopCommandTransport,
    id: Value,
    project_dir: Option<String>,
    params: Option<Value>,
) -> DesktopJsonRpcResponse {
    let _params = consume_external_params::<DesktopProviderCapabilitiesParams>(params.as_ref());
    match load_desktop_provider_capabilities(transport, project_dir) {
        Ok(snapshot) => match serde_json::to_value(snapshot) {
            Ok(result) => DesktopJsonRpcResponse::Success {
                jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
                id,
                result,
            },
            Err(err) => DesktopJsonRpcResponse::Error {
                jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
                id,
                error: DesktopJsonRpcError {
                    code: JSON_RPC_INTERNAL_ERROR,
                    message: format!(
                        "Failed to serialize desktop provider capabilities payload: {err}"
                    ),
                },
            },
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_backend::{
        handle_desktop_json_rpc, DesktopJsonRpcRequest, DesktopJsonRpcResponse,
    };
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

    fn serialized_result_has_no_registry_path_or_absolute_path(result: &Value) {
        let serialized =
            serde_json::to_string(result).expect("serialize provider capabilities result");
        assert!(
            !serialized.contains("registry_path"),
            "serialized result must drop registry_path: {serialized}"
        );
        assert!(
            !serialized.contains(r"C:\") && !serialized.contains("C:/"),
            "serialized result must not contain a drive-letter path: {serialized}"
        );
        assert!(
            result.get("registry_path").is_none(),
            "typed result must not expose registry_path"
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_provider_capabilities() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "version": 1,
                "registry_path": r"C:\Users\example\project\.winsmux\provider-capabilities.json",
                "providers": {
                    "codex": {
                        "adapter": "codex",
                        "display_name": "Codex"
                    }
                }
            }),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-provider-capabilities"),
                method: "desktop.provider.capabilities".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-provider-capabilities"));
                assert_eq!(result["version"], 1);
                assert_eq!(result["providers"]["codex"]["adapter"], "codex");
                assert_eq!(result["providers"]["codex"]["display_name"], "Codex");
                serialized_result_has_no_registry_path_or_absolute_path(&result);
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["provider-capabilities --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_provider_capabilities_empty_registry() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "version": 1,
                "providers": {},
                "registry_path": r"C:\Users\example\project\.winsmux\provider-capabilities.json"
            }),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-provider-capabilities-empty"),
                method: "desktop.provider.capabilities".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-provider-capabilities-empty"));
                assert_eq!(result["version"], 1);
                assert_eq!(result["providers"], serde_json::json!({}));
                serialized_result_has_no_registry_path_or_absolute_path(&result);
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["provider-capabilities --json"]
        );
    }
}
