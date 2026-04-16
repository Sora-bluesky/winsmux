use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

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

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DesktopSummaryRefreshSignal {
    pub source: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopRunProjection {
    pub run_id: String,
    pub pane_id: String,
    pub label: String,
    pub branch: String,
    pub worktree: String,
    pub head_sha: String,
    pub head_short: String,
    pub provider_target: String,
    pub task: String,
    pub task_state: String,
    pub review_state: String,
    pub verification_outcome: String,
    pub security_blocked: String,
    pub changed_files: Vec<String>,
    pub next_action: String,
    pub summary: String,
    pub reasons: Vec<String>,
    pub hypothesis: String,
    pub confidence: Option<f64>,
    pub observation_pack_ref: String,
    pub consultation_ref: String,
}

#[derive(Serialize, Deserialize)]
pub struct DesktopEditorFilePayload {
    pub path: String,
    pub content: String,
    pub line_count: usize,
    pub truncated: bool,
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

pub enum DesktopStreamCommand {
    Inbox { project_dir: Option<String> },
    Digest { project_dir: Option<String> },
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

impl DesktopStreamCommand {
    fn project_dir(&self) -> Option<&str> {
        match self {
            DesktopStreamCommand::Inbox { project_dir } => project_dir.as_deref(),
            DesktopStreamCommand::Digest { project_dir } => project_dir.as_deref(),
        }
    }

    fn winsmux_args(&self) -> Vec<String> {
        match self {
            DesktopStreamCommand::Inbox { .. } => {
                vec![
                    "inbox".to_string(),
                    "--stream".to_string(),
                    "--json".to_string(),
                ]
            }
            DesktopStreamCommand::Digest { .. } => {
                vec![
                    "digest".to_string(),
                    "--stream".to_string(),
                    "--json".to_string(),
                ]
            }
        }
    }

    fn source_name(&self) -> &'static str {
        match self {
            DesktopStreamCommand::Inbox { .. } => "inbox",
            DesktopStreamCommand::Digest { .. } => "digest",
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

pub fn load_desktop_editor_file(
    path: String,
    worktree: Option<String>,
    project_dir: Option<String>,
) -> Result<DesktopEditorFilePayload, String> {
    read_desktop_editor_file(project_dir, worktree, &path)
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
        "desktop.editor.read" => {
            let path = match get_required_string_param(params.as_ref(), &["path"]) {
                Ok(value) => value,
                Err(err) => {
                    return json_rpc_error(request_id, JSON_RPC_INVALID_PARAMS, err);
                }
            };
            let worktree = get_optional_string_param(params.as_ref(), &["worktree"]);

            match load_desktop_editor_file(path, worktree, resolved_project_dir) {
                Ok(result) => match serde_json::to_value(result) {
                    Ok(value) => json_rpc_result(request_id, value),
                    Err(err) => json_rpc_error(
                        request_id,
                        JSON_RPC_INTERNAL_ERROR,
                        format!("Failed to serialize desktop editor payload: {err}"),
                    ),
                },
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

fn resolve_effective_project_dir(project_dir: Option<String>) -> Result<PathBuf, String> {
    let repo_root = resolve_repo_root()?;
    Ok(match project_dir {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => repo_root,
    })
}

fn build_winsmux_command_text(script_path: &Path, args: &[String]) -> String {
    let script_literal = script_path.to_string_lossy().replace('\'', "''");
    let args_literal = args
        .iter()
        .map(|item| format!("'{}'", item.replace('\'', "''")))
        .collect::<Vec<_>>()
        .join(" ");

    format!("& {{ & '{}' {} }}", script_literal, args_literal)
}

pub fn parse_desktop_summary_stream_signal(
    source: &str,
    line: &str,
) -> Option<DesktopSummaryRefreshSignal> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }

    let payload: Value = serde_json::from_str(trimmed).ok()?;
    let object = payload.as_object()?;

    let is_valid = match source {
        "digest" => object
            .get("run_id")
            .and_then(|value| value.as_str())
            .is_some(),
        "inbox" => {
            object
                .get("kind")
                .and_then(|value| value.as_str())
                .is_some()
                && object
                    .get("pane_id")
                    .and_then(|value| value.as_str())
                    .is_some()
        }
        _ => false,
    };
    if !is_valid {
        return None;
    }

    Some(DesktopSummaryRefreshSignal {
        source: source.to_string(),
        reason: format!("{}.stream", source),
        pane_id: object
            .get("pane_id")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
        run_id: object
            .get("run_id")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
    })
}

pub fn spawn_desktop_summary_refresh_stream<F>(
    command: DesktopStreamCommand,
    stop_requested: Arc<AtomicBool>,
    mut on_signal: F,
) -> Result<(), String>
where
    F: FnMut(DesktopSummaryRefreshSignal) + Send + 'static,
{
    let repo_root = resolve_repo_root()?;
    let effective_project_dir =
        resolve_effective_project_dir(command.project_dir().map(|value| value.to_string()))?;
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let command_text = build_winsmux_command_text(&script_path, &command.winsmux_args());
    let source = command.source_name().to_string();

    thread::spawn(move || {
        while !stop_requested.load(Ordering::Relaxed) {
            let mut child = match Command::new("pwsh")
                .arg("-NoProfile")
                .arg("-ExecutionPolicy")
                .arg("Bypass")
                .arg("-Command")
                .arg(&command_text)
                .current_dir(&effective_project_dir)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
            {
                Ok(child) => child,
                Err(err) => {
                    eprintln!("Failed to start {} summary stream: {}", source, err);
                    if stop_requested.load(Ordering::Relaxed) {
                        break;
                    }
                    thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            if let Some(stderr) = child.stderr.take() {
                let stderr_source = source.clone();
                thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
                            eprintln!("winsmux {} stream stderr: {}", stderr_source, trimmed);
                        }
                    }
                });
            }

            let stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => {
                    eprintln!("winsmux {} stream stdout pipe missing", source);
                    let _ = child.kill();
                    let _ = child.wait();
                    if stop_requested.load(Ordering::Relaxed) {
                        break;
                    }
                    thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };

            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if stop_requested.load(Ordering::Relaxed) {
                    let _ = child.kill();
                    break;
                }
                match line {
                    Ok(line) => {
                        if let Some(signal) = parse_desktop_summary_stream_signal(&source, &line) {
                            on_signal(signal);
                        }
                    }
                    Err(err) => {
                        eprintln!("winsmux {} stream read failed: {}", source, err);
                        break;
                    }
                }
            }

            let _ = child.wait();
            if stop_requested.load(Ordering::Relaxed) {
                break;
            }
            thread::sleep(Duration::from_secs(2));
        }
    });

    Ok(())
}

fn resolve_desktop_read_root(
    project_dir: Option<String>,
    worktree: Option<String>,
) -> Result<PathBuf, String> {
    let effective_project_dir = resolve_effective_project_dir(project_dir)?;
    let normalized_project_dir = effective_project_dir
        .canonicalize()
        .map_err(|err| format!("Failed to resolve project root for file preview: {err}"))?;

    let requested_root = match worktree {
        Some(path) if !path.trim().is_empty() => {
            let requested = PathBuf::from(path);
            if requested.is_absolute() {
                requested
            } else {
                effective_project_dir.join(requested)
            }
        }
        _ => effective_project_dir.clone(),
    };

    let normalized_requested_root = requested_root
        .canonicalize()
        .map_err(|err| format!("Failed to resolve worktree root for file preview: {err}"))?;

    if !normalized_requested_root.starts_with(&normalized_project_dir) {
        return Err(
            "desktop.editor.read rejected a worktree path outside the project directory"
                .to_string(),
        );
    }

    Ok(normalized_requested_root)
}

fn read_desktop_editor_file(
    project_dir: Option<String>,
    worktree: Option<String>,
    relative_path: &str,
) -> Result<DesktopEditorFilePayload, String> {
    let read_root = resolve_desktop_read_root(project_dir, worktree)?;
    let requested_path = PathBuf::from(relative_path);
    if requested_path.is_absolute() {
        return Err("desktop.editor.read expects a project-relative path".to_string());
    }

    let full_path = read_root.join(&requested_path);
    let normalized_full_path = full_path
        .canonicalize()
        .map_err(|err| format!("Failed to resolve file preview path: {err}"))?;

    if !normalized_full_path.starts_with(&read_root) {
        return Err(
            "desktop.editor.read rejected a path outside the selected worktree".to_string(),
        );
    }

    let bytes = fs::read(&normalized_full_path)
        .map_err(|err| format!("Failed to read file preview: {err}"))?;
    const MAX_PREVIEW_BYTES: usize = 32 * 1024;
    let truncated = bytes.len() > MAX_PREVIEW_BYTES;
    let preview_bytes = if truncated {
        &bytes[..MAX_PREVIEW_BYTES]
    } else {
        bytes.as_slice()
    };
    let content = String::from_utf8_lossy(preview_bytes).to_string();
    let line_count = content.lines().count().max(1);

    Ok(DesktopEditorFilePayload {
        path: requested_path.to_string_lossy().replace('\\', "/"),
        content,
        line_count,
        truncated,
    })
}

fn run_winsmux_json(project_dir: Option<String>, args: &[String]) -> Result<Value, String> {
    let repo_root = resolve_repo_root()?;
    let effective_project_dir = resolve_effective_project_dir(project_dir)?;
    let script_path = repo_root.join("scripts").join("winsmux-core.ps1");
    let command_text = build_winsmux_command_text(&script_path, args);

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
                    "worktree": ".worktrees/builder-1",
                    "head_sha": "abc1234def5678",
                    "head_short": "abc1234",
                    "provider_target": "codex:gpt-5.4",
                    "task": "Implement",
                    "task_state": "in_progress",
                    "review_state": "PENDING",
                    "verification_outcome": "",
                    "security_blocked": "",
                    "changed_files": ["winsmux-app/src/main.ts"],
                    "next_action": "review_requested",
                    "summary": "Implement",
                    "reasons": ["task_state=in_progress"],
                    "hypothesis": "projection should surface detail",
                    "confidence": 0.75,
                    "observation_pack_ref": "obs-1",
                    "consultation_ref": "consult-1"
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
    fn handle_desktop_json_rpc_routes_editor_read() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-editor-read-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(temp_dir.join("winsmux-app").join("src")).unwrap();
        std::fs::write(
            temp_dir.join("winsmux-app").join("src").join("main.ts"),
            "console.log('hello');\nconsole.log('world');\n",
        )
        .unwrap();

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-file"),
                method: "desktop.editor.read".to_string(),
                params: Some(serde_json::json!({
                    "path": "winsmux-app/src/main.ts",
                    "worktree": "."
                })),
            },
            Some(temp_dir.to_string_lossy().to_string()),
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-file"));
                assert_eq!(result["path"], "winsmux-app/src/main.ts");
                assert_eq!(result["line_count"], 2);
                assert_eq!(result["truncated"], false);
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }
        assert!(transport.requests.borrow().is_empty());

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn handle_desktop_json_rpc_routes_editor_read_from_worktree() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-editor-worktree-{}",
            std::process::id()
        ));
        let worktree_dir = temp_dir.join(".worktrees").join("builder-1");
        let target_file = worktree_dir.join("winsmux-app").join("src").join("main.ts");

        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(target_file.parent().unwrap()).unwrap();
        std::fs::write(&target_file, "console.log('worktree');\n").unwrap();

        let transport = FakeTransport {
            requests: RefCell::new(Vec::new()),
            response: serde_json::json!({}),
        };
        let response = handle_desktop_json_rpc(
            &transport,
            DesktopJsonRpcRequest {
                jsonrpc: "2.0".to_string(),
                id: serde_json::json!("req-worktree"),
                method: "desktop.editor.read".to_string(),
                params: Some(serde_json::json!({
                    "path": "winsmux-app/src/main.ts",
                    "worktree": ".worktrees/builder-1"
                })),
            },
            Some(temp_dir.to_string_lossy().to_string()),
        );

        match response {
            DesktopJsonRpcResponse::Success { id, result, .. } => {
                assert_eq!(id, serde_json::json!("req-worktree"));
                assert_eq!(result["path"], "winsmux-app/src/main.ts");
                assert!(result["content"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("worktree"));
            }
            DesktopJsonRpcResponse::Error { error, .. } => {
                panic!("expected success, got {:?}", error);
            }
        }

        let _ = std::fs::remove_dir_all(temp_dir);
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

    #[test]
    fn parse_desktop_summary_stream_signal_extracts_digest_run_and_pane() {
        let signal = parse_desktop_summary_stream_signal(
            "digest",
            r#"{"run_id":"task:task-289","pane_id":"%4","label":"builder-1"}"#,
        )
        .unwrap();

        assert_eq!(
            signal,
            DesktopSummaryRefreshSignal {
                source: "digest".to_string(),
                reason: "digest.stream".to_string(),
                pane_id: Some("%4".to_string()),
                run_id: Some("task:task-289".to_string()),
            }
        );
    }

    #[test]
    fn parse_desktop_summary_stream_signal_accepts_inbox_items_without_run_id() {
        let signal = parse_desktop_summary_stream_signal(
            "inbox",
            r#"{"kind":"review_requested","pane_id":"%7","label":"reviewer-1"}"#,
        )
        .unwrap();

        assert_eq!(signal.source, "inbox");
        assert_eq!(signal.reason, "inbox.stream");
        assert_eq!(signal.pane_id.as_deref(), Some("%7"));
        assert_eq!(signal.run_id, None);
    }

    #[test]
    fn parse_desktop_summary_stream_signal_rejects_untyped_json_lines() {
        assert!(parse_desktop_summary_stream_signal("digest", r#"{"pane_id":"%2"}"#).is_none());
        assert!(
            parse_desktop_summary_stream_signal("inbox", r#"{"message":"missing kind"}"#).is_none()
        );
    }
}
