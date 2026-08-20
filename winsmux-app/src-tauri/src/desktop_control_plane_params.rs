use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct DesktopSummarySnapshotParams {}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct DesktopProviderCapabilitiesParams {}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct DesktopVoiceCaptureStatusParams {}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DesktopRunExplainParams {
    #[serde(rename = "runId", alias = "run_id")]
    pub run_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DesktopRunCompareParams {
    #[serde(rename = "leftRunId", alias = "left_run_id")]
    pub left_run_id: String,
    #[serde(rename = "rightRunId", alias = "right_run_id")]
    pub right_run_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DesktopRunPromoteParams {
    #[serde(rename = "runId", alias = "run_id")]
    pub run_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DesktopRunPickWinnerParams {
    #[serde(rename = "runId", alias = "run_id")]
    pub run_id: String,
    #[serde(rename = "peerSlot", alias = "peer_slot")]
    pub peer_slot: String,
    #[serde(alias = "message")]
    pub recommendation: String,
    #[serde(rename = "nextTest", alias = "next_test")]
    pub next_test: String,
    #[serde(default, deserialize_with = "optional_json_f64")]
    pub confidence: Option<f64>,
}

fn optional_json_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(value.and_then(|item| item.as_f64()))
}

pub(crate) fn deserialize_external_params<T: DeserializeOwned>(
    params: Option<&Value>,
) -> Result<T, String> {
    let value = match params {
        Some(Value::Null) | None => Value::Object(Default::default()),
        Some(value) => value.clone(),
    };
    serde_json::from_value(value).map_err(|err| err.to_string())
}

pub(crate) fn consume_external_params<T: DeserializeOwned + Default>(params: Option<&Value>) -> T {
    deserialize_external_params(params).unwrap_or_default()
}

pub(crate) fn required_trimmed_desktop_string(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("Missing required string param".to_string());
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use crate::desktop_backend::{
        handle_desktop_json_rpc, DesktopCommand, DesktopCommandTransport, DesktopJsonRpcRequest,
        DesktopJsonRpcResponse, JSON_RPC_INVALID_PARAMS,
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
    fn handle_desktop_json_rpc_rejects_duplicate_run_id_aliases() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-dup"),
                method: "desktop.run.explain".to_string(),
                params: Some(serde_json::json!({
                    "runId": "task:1",
                    "run_id": "task:1"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Error { error, .. } => {
                assert_eq!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            DesktopJsonRpcResponse::Success { .. } => panic!("expected invalid params error"),
        }
        assert!(transport.requests.borrow().is_empty());
    }

    #[test]
    fn handle_desktop_json_rpc_ignores_invalid_optional_pick_winner_confidence() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-conf"),
                method: "desktop.run.pick_winner".to_string(),
                params: Some(serde_json::json!({
                    "runId": "task:1",
                    "peerSlot": "builder-2",
                    "recommendation": "pick",
                    "nextTest": "promote",
                    "confidence": "high"
                })),
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Error { error, .. } => {
                assert_ne!(error.code, JSON_RPC_INVALID_PARAMS);
            }
            DesktopJsonRpcResponse::Success { .. } => {}
        }
    }
}
