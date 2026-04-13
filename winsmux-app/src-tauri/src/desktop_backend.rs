use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

const DESKTOP_JSON_RPC_VERSION: &str = "2.0";
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_INTERNAL_ERROR: i32 = -32603;
const JSON_RPC_SERVER_ERROR: i32 = -32000;

#[derive(Serialize, Deserialize)]
pub struct DesktopSummarySnapshot {
    pub generated_at: String,
    pub project_dir: String,
    pub board: serde_json::Value,
    pub inbox: serde_json::Value,
    pub digest: serde_json::Value,
    pub run_projections: Vec<DesktopRunProjection>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopRunProjection {
    pub run_id: String,
    pub pane_id: String,
    pub label: String,
    pub branch: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub verification_outcome: String,
    pub security_blocked: String,
    pub changed_files: Vec<String>,
    pub next_action: String,
    pub summary: String,
    pub reasons: Vec<String>,
}

#[derive(Deserialize)]
pub struct DesktopJsonRpcRequest {
    pub jsonrpc: String,
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Option<Value>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct DesktopJsonRpcError {
    pub code: i32,
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(untagged)]
pub enum DesktopJsonRpcResponse {
    Success {
        jsonrpc: String,
        id: Value,
        result: Value,
    },
    Error {
        jsonrpc: String,
        id: Value,
        error: DesktopJsonRpcError,
    },
}

pub enum DesktopCommand {
    SummarySnapshot {
        project_dir: Option<String>,
    },
    RunExplain {
        run_id: String,
        project_dir: Option<String>,
    },
}

impl DesktopCommand {
    fn project_dir(&self) -> Option<&str> {
        match self {
            DesktopCommand::SummarySnapshot { project_dir } => project_dir.as_deref(),
            DesktopCommand::RunExplain { project_dir, .. } => project_dir.as_deref(),
        }
    }

    fn winsmux_args(&self) -> Vec<String> {
        match self {
            DesktopCommand::SummarySnapshot { .. } => {
                vec!["desktop-summary".to_string(), "--json".to_string()]
            }
            DesktopCommand::RunExplain { run_id, .. } => {
                vec!["explain".to_string(), run_id.clone(), "--json".to_string()]
            }
        }
    }
}

pub trait DesktopCommandTransport {
    fn request_json(&self, command: &DesktopCommand) -> Result<Value, String>;
}

pub struct PwshScriptTransport;

impl DesktopCommandTransport for PwshScriptTransport {
    fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
        run_winsmux_json(
            command.project_dir().map(|path| path.to_string()),
            &command.winsmux_args(),
        )
    }
}

pub fn load_desktop_summary_snapshot(
    transport: &dyn DesktopCommandTransport,
    project_dir: Option<String>,
) -> Result<DesktopSummarySnapshot, String> {
    let snapshot = transport.request_json(&DesktopCommand::SummarySnapshot { project_dir })?;
    serde_json::from_value(snapshot)
        .map_err(|err| format!("Failed to parse desktop summary payload: {err}"))
}

pub fn load_desktop_run_explain(
    transport: &dyn DesktopCommandTransport,
    run_id: String,
    project_dir: Option<String>,
) -> Result<Value, String> {
    transport.request_json(&DesktopCommand::RunExplain {
        run_id,
        project_dir,
    })
}

pub fn handle_desktop_json_rpc(
    transport: &dyn DesktopCommandTransport,
    request: DesktopJsonRpcRequest,
    project_dir: Option<String>,
) -> DesktopJsonRpcResponse {
    let request_id = request.id.clone();
    if request.jsonrpc != DESKTOP_JSON_RPC_VERSION {
        return json_rpc_error(
            request_id,
            JSON_RPC_INVALID_REQUEST,
            "desktop_json_rpc expects jsonrpc=\"2.0\"",
        );
    }

    let params = request.params;
    let resolved_project_dir = resolve_project_dir(project_dir, params.as_ref());

    match request.method.as_str() {
        "desktop.summary.snapshot" => {
            match load_desktop_summary_snapshot(transport, resolved_project_dir) {
                Ok(snapshot) => match serde_json::to_value(snapshot) {
                    Ok(result) => json_rpc_result(request_id, result),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop summary payload: {err}"),
                    ),
                },
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        "desktop.run.explain" => {
            let run_id = match get_required_string_param(params.as_ref(), &["runId", "run_id"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };

            match load_desktop_run_explain(transport, run_id, resolved_project_dir) {
                Ok(result) => json_rpc_result(request_id, result),
                Err(err) => json_rpc_error(request_id, JSON_RPC_SERVER_ERROR, err),
            }
        }
        _ => json_rpc_error(
            request_id,
            JSON_RPC_METHOD_NOT_FOUND,
            format!("Unknown desktop JSON-RPC method: {}", request.method),
        ),
    }
}

fn resolve_project_dir(project_dir: Option<String>, params: Option<&Value>) -> Option<String> {
    if let Some(path) = project_dir.filter(|value| !value.trim().is_empty()) {
        return Some(path);
    }

    get_optional_string_param(params, &["projectDir", "project_dir"])
}

fn get_required_string_param(params: Option<&Value>, keys: &[&str]) -> Result<String, String> {
    get_optional_string_param(params, keys)
        .ok_or_else(|| format!("Missing required params field: {}", keys.join(" or ")))
}

fn get_optional_string_param(params: Option<&Value>, keys: &[&str]) -> Option<String> {
    let object = params?.as_object()?;
    for key in keys {
        let value = object.get(*key)?.as_str()?.trim();
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }

    None
}

fn json_rpc_result(id: Value, result: Value) -> DesktopJsonRpcResponse {
    DesktopJsonRpcResponse::Success {
        jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
        id,
        result,
    }
}

fn json_rpc_error(id: Value, code: i32, message: impl Into<String>) -> DesktopJsonRpcResponse {
    DesktopJsonRpcResponse::Error {
        jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
        id,
        error: DesktopJsonRpcError {
            code,
            message: message.into(),
        },
    }
}

fn looks_like_repo_root(path: &Path) -> bool {
    path.join("scripts").join("winsmux-core.ps1").exists()
}

fn resolve_repo_root() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Ok(current_dir) = std::env::current_dir() {
        candidates.push(current_dir);
    }
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            candidates.push(parent.to_path_buf());
        }
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));

    for candidate in candidates {
        for ancestor in candidate.ancestors() {
            if looks_like_repo_root(ancestor) {
                return Ok(ancestor.to_path_buf());
            }
        }
    }

    Err("Could not locate winsmux repo root from the Tauri runtime".to_string())
}

fn run_winsmux_json(project_dir: Option<String>, args: &[String]) -> Result<Value, String> {
    let repo_root = resolve_repo_root()?;
    let effective_project_dir = match project_dir {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => repo_root.clone(),
    };
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let script_literal = script_path.to_string_lossy().replace('\'', "''");
    let args_literal = args
        .iter()
        .map(|item| format!("'{}'", item.replace('\'', "''")))
        .collect::<Vec<_>>()
        .join(" ");
    let command_text = format!("& {{ & '{}' {} }}", script_literal, args_literal);

    let output = Command::new("pwsh")
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(command_text)
        .current_dir(&effective_project_dir)
        .output()
        .map_err(|err| format!("Failed to start winsmux-core.ps1: {err}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() { stderr } else { stdout };
        return Err(format!("winsmux-core.ps1 failed: {}", detail));
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stdout.is_empty() {
        return Err("winsmux-core.ps1 returned empty JSON output".to_string());
    }

    serde_json::from_str(&stdout)
        .map_err(|err| format!("Failed to parse winsmux JSON payload: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;
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
    fn load_desktop_summary_snapshot_deserializes_transport_payload() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "generated_at": "2026-04-13T00:00:00Z",
                "project_dir": "C:/repo",
                "board": { "summary": { "pane_count": 1 }, "panes": [] },
                "inbox": { "summary": { "item_count": 0 }, "items": [] },
                "digest": { "summary": { "item_count": 1 }, "items": [] },
                "run_projections": [{
                    "run_id": "run-1",
                    "pane_id": "%1",
                    "label": "builder-1",
                    "branch": "codex/task",
                    "task": "Implement",
                    "task_state": "in_progress",
                    "review_state": "PENDING",
                    "verification_outcome": "",
                    "security_blocked": "",
                    "changed_files": ["winsmux-app/src/main.ts"],
                    "next_action": "review_requested",
                    "summary": "Implement",
                    "reasons": ["task_state=in_progress"]
                }]
            }),
        };

        let snapshot = load_desktop_summary_snapshot(&transport, None).unwrap();

        assert_eq!(snapshot.project_dir, "C:/repo");
        assert_eq!(snapshot.run_projections.len(), 1);
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["desktop-summary --json"]
        );
    }

    #[test]
    fn load_desktop_run_explain_uses_explain_command() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "run": { "run_id": "run-7" },
                "explanation": { "summary": "ok", "reasons": [], "next_action": "idle" },
                "evidence_digest": { "changed_files": [], "changed_file_count": 0 },
                "recent_events": []
            }),
        };

        let payload = load_desktop_run_explain(&transport, "run-7".to_string(), None).unwrap();

        assert_eq!(payload["run"]["run_id"], "run-7");
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["explain run-7 --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_routes_summary_snapshot() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({
                "generated_at": "2026-04-13T00:00:00Z",
                "project_dir": "C:/repo",
                "board": { "summary": { "pane_count": 1 }, "panes": [] },
                "inbox": { "summary": { "item_count": 0 }, "items": [] },
                "digest": { "summary": { "item_count": 1 }, "items": [] },
                "run_projections": []
            }),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-1"),
                method: "desktop.summary.snapshot".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-1"));
                assert_eq!(result["project_dir"], "C:/repo");
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert_eq!(
            transport.requests.borrow().as_slice(),
            ["desktop-summary --json"]
        );
    }

    #[test]
    fn handle_desktop_json_rpc_rejects_unknown_method() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-2"),
                method: "desktop.unknown".to_string(),
                params: None,
            },
            None,
        );

        match response {
            DesktopJsonRpcResponse::Error { id, error, .. } => {
                assert_eq!(id, serde_json::json!("req-2"));
                assert_eq!(error.code, JSON_RPC_METHOD_NOT_FOUND);
            }
            DesktopJsonRpcResponse::Success { .. } => panic!("expected error response"),
        }
        assert!(transport.requests.borrow().is_empty());
    }

    #[test]
    fn handle_desktop_json_rpc_requires_run_id_for_explain() {
        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-3"),
                method: "desktop.run.explain".to_string(),
                params: Some(serde_json::json!({})),
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
}
