//! Metadata-only input quiescence commands for the authorized main WebView.
use std::sync::Arc;
use serde::{Deserialize, Serialize};
use tauri::{ipc, Manager, State, WebviewWindow};
use crate::workspace_transport::{main_local_webview, WorkspaceManager};

#[derive(Clone, Serialize)]
pub(crate) struct GuardWake {
    pub lease: String,
    pub revision: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct GuardFence {
    pub nonce: String,
    pub state: &'static str,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct GuardStatus {
    pub(crate) lease: String,
    pub(crate) revision: String,
    pub(crate) fence: Option<GuardFence>,
    pub(crate) resume_allowed: bool,
    pub(crate) admission_error: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisterBody { binding: String }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StatusBody { lease: String }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplyBody { lease: String, nonce: String, safe: bool }

fn decode<T: serde::de::DeserializeOwned>(body: &str) -> Result<T, &'static str> {
    if body.len() > winsmux_workspace::contract::MAX_MESSAGE_BYTES {
        return Err("input_guard_invalid");
    }
    // Deserialize directly into the strict DTO: Value would collapse duplicate keys.
    serde_json::from_str(body).map_err(|_| "input_guard_invalid")
}
fn canonical_id(value: &str) -> Result<u64, &'static str> {
    let id = value.parse::<u64>().map_err(|_| "input_guard_invalid")?;
    if id == 0 || id.to_string() != value { return Err("input_guard_invalid"); }
    Ok(id)
}
fn canonical_binding(value: &str) -> Result<(), &'static str> {
    let id = uuid::Uuid::parse_str(value).map_err(|_| "input_guard_invalid")?;
    if id.to_string() != value { return Err("input_guard_invalid"); }
    Ok(())
}

#[tauri::command]
pub fn workspace_input_guard_register(
    window: WebviewWindow,
    manager: State<'_, Arc<WorkspaceManager>>,
    invocation: ipc::Request<'_>,
    request_json: String,
) -> Result<GuardStatus, &'static str> {
    if !main_local_webview(&window, &invocation) { return Err("wrong_window"); }
    let request: RegisterBody = decode(&request_json)?;
    canonical_binding(&request.binding)?;
    manager.register_input_guard(&request.binding, window.app_handle())
}

#[tauri::command]
pub fn workspace_input_guard_status(
    window: WebviewWindow,
    manager: State<'_, Arc<WorkspaceManager>>,
    invocation: ipc::Request<'_>,
    request_json: String,
) -> Result<GuardStatus, &'static str> {
    if !main_local_webview(&window, &invocation) { return Err("wrong_window"); }
    let request: StatusBody = decode(&request_json)?;
    manager.input_guard_status(canonical_id(&request.lease)?)
}

#[tauri::command]
pub fn workspace_input_guard_reply(
    window: WebviewWindow,
    manager: State<'_, Arc<WorkspaceManager>>,
    invocation: ipc::Request<'_>,
    request_json: String,
) -> Result<GuardStatus, &'static str> {
    if !main_local_webview(&window, &invocation) { return Err("wrong_window"); }
    let request: ReplyBody = decode(&request_json)?;
    manager.reply_input_guard(canonical_id(&request.lease)?, canonical_id(&request.nonce)?, request.safe)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_shape_rejects_unknown_duplicate_missing_and_wrong_types() {
        for body in [
            r#"{"binding":"a","binding":"b"}"#,
            r#"{"binding":"a","extra":0}"#, r#"{}"#, r#"{"binding":1}"#,
        ] { assert!(decode::<RegisterBody>(body).is_err()); }
        for body in [
            r#"{"lease":"1","lease":"1"}"#, r#"{"lease":"1","nonce":"1"}"#,
            r#"{"lease":1}"#, r#"[]"#,
        ] { assert!(decode::<StatusBody>(body).is_err()); }
        for body in [
            r#"{"lease":"1","nonce":"2","safe":true,"safe":true}"#,
            r#"{"lease":"1","nonce":"2","safe":"true"}"#,
            r#"{"lease":"1","nonce":"2","safe":true,"text":"x"}"#,
            r#"{"lease":"1","nonce":"2"}"#,
        ] { assert!(decode::<ReplyBody>(body).is_err()); }
        assert!(decode::<ReplyBody>(r#"{"lease":"1","nonce":"2","safe":false}"#).is_ok());
    }
    #[test]
    fn identifiers_remain_canonical_u64_and_uuid_strings() {
        for v in ["0", "01", "+1", "-1", "1.0", " 1", "1 ", "18446744073709551616"] {
            assert!(canonical_id(v).is_err(), "{v}");
        }
        assert_eq!(canonical_id("18446744073709551615"), Ok(u64::MAX));
        assert_eq!(canonical_id("9007199254740993"), Ok(9_007_199_254_740_993));
        assert!(canonical_binding("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").is_ok());
        for v in ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa", "invalid"] {
            assert!(canonical_binding(v).is_err());
        }
    }
    #[test]
    fn body_cap_uses_the_existing_contract_and_no_text_enters_status() {
        let over = " ".repeat(winsmux_workspace::contract::MAX_MESSAGE_BYTES + 1);
        assert!(decode::<StatusBody>(&over).is_err());
        let status = GuardStatus {lease:"1".into(), revision:"9007199254740993".into(),
            fence:Some(GuardFence {nonce:"2".into(),state:"released"}), resume_allowed:true, admission_error:None};
        let value=serde_json::to_value(status).unwrap();
        assert_eq!(value.as_object().unwrap().len(),5);
        assert!(value.get("text").is_none());
        assert_eq!(value["revision"],"9007199254740993");
    }
}
