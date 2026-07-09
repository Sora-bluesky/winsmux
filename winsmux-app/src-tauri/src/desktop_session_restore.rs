use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

use crate::desktop_backend::{
    resolve_repo_root, DesktopJsonRpcError, DesktopJsonRpcResponse, DESKTOP_JSON_RPC_VERSION,
    JSON_RPC_INTERNAL_ERROR, JSON_RPC_SERVER_ERROR,
};

const DESKTOP_SESSION_RESTORE_STATE_CANDIDATE: &str = "candidate";
const DESKTOP_SESSION_RESTORE_STATE_SETUP_REQUIRED: &str = "setup-required";
const DESKTOP_SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED: &str = "agent-session-expired";
const LEGACY_DESKTOP_SESSION_RESTORE_STATE_PANE_EXITED: &str = "pane_exited";

#[derive(Serialize, Deserialize)]
pub(crate) struct DesktopSessionRestoreCandidatePayload {
    pub(crate) version: u16,
    pub(crate) project_dir: String,
    pub(crate) registry_dir: String,
    pub(crate) candidates: Vec<DesktopSessionRestoreCandidate>,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct DesktopSessionRestoreCandidate {
    pub(crate) session: String,
    pub(crate) namespace: Option<String>,
    pub(crate) owner: String,
    pub(crate) state: String,
    pub(crate) port: u16,
    pub(crate) created_at: u64,
    pub(crate) ready_at: Option<u64>,
    pub(crate) restore_state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) setup_required_reason: Option<String>,
    pub(crate) panes: Vec<DesktopSessionRestorePane>,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct DesktopSessionRestorePane {
    pub(crate) pane_id: String,
    pub(crate) window_id: String,
    pub(crate) window_index: usize,
    pub(crate) pane_index: usize,
    #[serde(default)]
    pub(crate) agent_cli_session_id: Option<String>,
    pub(crate) transcript_ring_summary: DesktopSessionRestoreTranscriptRingSummary,
    #[serde(default)]
    pub(crate) worktree: Option<String>,
    #[serde(default)]
    pub(crate) branch: Option<String>,
    #[serde(default)]
    pub(crate) provider_target: Option<String>,
    #[serde(default)]
    pub(crate) model: Option<String>,
    #[serde(default)]
    pub(crate) model_source: Option<String>,
    #[serde(default)]
    pub(crate) context_capsule_ref: Option<String>,
    #[serde(default)]
    pub(crate) checkpoint_ref: Option<String>,
    pub(crate) restore_state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) setup_required_reason: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct DesktopSessionRestoreTranscriptRingSummary {
    #[serde(default)]
    pub(crate) byte_count: u64,
    #[serde(default)]
    pub(crate) sha256: Option<String>,
    #[serde(default)]
    pub(crate) raw_transcript_stored: bool,
}

#[derive(Deserialize)]
struct DesktopSessionRegistryRestoreMetadata {
    restore_metadata_version: u16,
    layer: String,
    #[serde(default)]
    panes: Vec<DesktopSessionRestorePane>,
}

pub(crate) fn json_rpc(
    id: Value,
    project_dir: Option<String>,
    params: Option<Value>,
) -> DesktopJsonRpcResponse {
    let registry_dir = get_optional_string_param(params.as_ref(), &["registryDir", "registry_dir"]);
    match load_desktop_session_restore_candidates(project_dir, registry_dir).and_then(|payload| {
        serde_json::to_value(payload)
            .map_err(|err| format!("Failed to serialize desktop session restore payload: {err}"))
    }) {
        Ok(result) => DesktopJsonRpcResponse::Success {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            result,
        },
        Err(message) => DesktopJsonRpcResponse::Error {
            jsonrpc: DESKTOP_JSON_RPC_VERSION.to_string(),
            id,
            error: DesktopJsonRpcError {
                code: if message.starts_with("Failed to serialize") {
                    JSON_RPC_INTERNAL_ERROR
                } else {
                    JSON_RPC_SERVER_ERROR
                },
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

pub(crate) fn load_desktop_session_restore_candidates(
    project_dir: Option<String>,
    registry_dir: Option<String>,
) -> Result<DesktopSessionRestoreCandidatePayload, String> {
    let project_root = resolve_effective_project_dir(project_dir)?
        .canonicalize()
        .map_err(|err| format!("Failed to resolve project root for session restore: {err}"))?;
    let (registry_path, registry_label, allow_outside_project) =
        resolve_session_registry_path(&project_root, registry_dir)?;

    let candidates = if registry_path.exists() {
        let normalized_registry_path = registry_path.canonicalize().map_err(|err| {
            format!("Failed to resolve session restore registry directory: {err}")
        })?;
        if !allow_outside_project && !normalized_registry_path.starts_with(&project_root) {
            return Err(
                "desktop.session.restore_candidates rejected a registryDir outside the project directory"
                    .to_string(),
            );
        }
        enumerate_desktop_session_restore_candidates(&normalized_registry_path)
    } else {
        Vec::new()
    };

    Ok(DesktopSessionRestoreCandidatePayload {
        version: 1,
        project_dir: project_root.to_string_lossy().to_string(),
        registry_dir: registry_label,
        candidates,
    })
}

fn resolve_session_registry_path(
    project_root: &Path,
    registry_dir: Option<String>,
) -> Result<(PathBuf, String, bool), String> {
    if let Some(registry_relative) = registry_dir {
        let registry_requested = PathBuf::from(&registry_relative);
        if registry_requested.is_absolute() {
            return Err(
                "desktop.session.restore_candidates expects a project-relative registryDir"
                    .to_string(),
            );
        }
        return Ok((
            project_root.join(&registry_requested),
            registry_requested.to_string_lossy().replace('\\', "/"),
            false,
        ));
    }

    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map_err(|err| format!("Failed to resolve home directory for session restore: {err}"))?;
    Ok((
        PathBuf::from(home).join(".psmux"),
        ".psmux".to_string(),
        true,
    ))
}

fn resolve_effective_project_dir(project_dir: Option<String>) -> Result<PathBuf, String> {
    if let Some(path) = project_dir {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    resolve_repo_root()
}

fn is_desktop_warm_session(base: &str) -> bool {
    base == "__warm__" || base.ends_with("____warm__")
}

fn desktop_session_namespace_from_base(base: &str) -> Option<String> {
    let (namespace, session_name) = base.split_once("__")?;
    if namespace.is_empty() || session_name.is_empty() || is_desktop_warm_session(base) {
        None
    } else {
        Some(namespace.to_string())
    }
}

fn desktop_registry_base_from_path(path: &Path) -> Option<String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .and_then(|name| name.strip_suffix(".registry.json"))
        .map(str::to_string)
}

fn desktop_registry_owner_matches_base(registry: &Value, base: &str) -> bool {
    let expected_owner = if is_desktop_warm_session(base) {
        "warm"
    } else {
        "normal"
    };
    registry["owner"].as_str() == Some(expected_owner)
}

fn normalize_desktop_session_restore_pane(pane: &mut DesktopSessionRestorePane) {
    if pane.restore_state == DESKTOP_SESSION_RESTORE_STATE_CANDIDATE {
        pane.setup_required_reason = None;
        return;
    }

    if pane.setup_required_reason.is_none() {
        pane.setup_required_reason = Some(
            match pane.restore_state.as_str() {
                LEGACY_DESKTOP_SESSION_RESTORE_STATE_PANE_EXITED => {
                    DESKTOP_SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED
                }
                DESKTOP_SESSION_RESTORE_STATE_SETUP_REQUIRED => {
                    DESKTOP_SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED
                }
                _ => DESKTOP_SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED,
            }
            .to_string(),
        );
    }
    pane.restore_state = DESKTOP_SESSION_RESTORE_STATE_SETUP_REQUIRED.to_string();
}

fn desktop_session_restore_candidate_state(
    panes: &[DesktopSessionRestorePane],
) -> (String, Option<String>) {
    if let Some(pane) = panes
        .iter()
        .find(|pane| pane.restore_state != DESKTOP_SESSION_RESTORE_STATE_CANDIDATE)
    {
        return (
            DESKTOP_SESSION_RESTORE_STATE_SETUP_REQUIRED.to_string(),
            pane.setup_required_reason.clone().or_else(|| {
                Some(DESKTOP_SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED.to_string())
            }),
        );
    }

    (DESKTOP_SESSION_RESTORE_STATE_CANDIDATE.to_string(), None)
}

fn read_desktop_session_restore_candidate(
    path: &Path,
    base: &str,
) -> Option<DesktopSessionRestoreCandidate> {
    if is_desktop_warm_session(base) {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    let registry: Value = serde_json::from_str(&text).ok()?;
    if registry["protocol_version"].as_u64()? != 1
        || registry["session"].as_str()? != base
        || !desktop_registry_owner_matches_base(&registry, base)
    {
        return None;
    }

    let restore_value = registry.get("restore")?.clone();
    let restore: DesktopSessionRegistryRestoreMetadata =
        serde_json::from_value(restore_value).ok()?;
    if restore.restore_metadata_version != 1
        || restore.layer != "session_persistence_layer1"
        || restore.panes.is_empty()
    {
        return None;
    }

    let port = registry["port"]
        .as_u64()
        .and_then(|value| u16::try_from(value).ok())?;
    let mut panes = restore.panes;
    panes.sort_by(|left, right| {
        (left.window_index, left.pane_index, left.pane_id.as_str()).cmp(&(
            right.window_index,
            right.pane_index,
            right.pane_id.as_str(),
        ))
    });
    for pane in &mut panes {
        normalize_desktop_session_restore_pane(pane);
    }
    let (restore_state, setup_required_reason) = desktop_session_restore_candidate_state(&panes);

    Some(DesktopSessionRestoreCandidate {
        session: base.to_string(),
        namespace: registry["namespace"]
            .as_str()
            .map(str::to_string)
            .or_else(|| desktop_session_namespace_from_base(base)),
        owner: registry["owner"].as_str()?.to_string(),
        state: registry["state"].as_str()?.to_string(),
        port,
        created_at: registry["created_at"].as_u64()?,
        ready_at: registry["ready_at"].as_u64(),
        restore_state,
        setup_required_reason,
        panes,
    })
}

fn enumerate_desktop_session_restore_candidates(
    registry_dir: &Path,
) -> Vec<DesktopSessionRestoreCandidate> {
    let Ok(entries) = fs::read_dir(registry_dir) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| desktop_registry_base_from_path(path).is_some())
        .collect();
    paths.sort_by(|left, right| left.file_name().cmp(&right.file_name()));

    paths
        .into_iter()
        .filter_map(|path| {
            let base = desktop_registry_base_from_path(&path)?;
            read_desktop_session_restore_candidate(&path, &base)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_desktop_session_restore_candidates_reads_session_registry_candidates() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-session-restore-{}",
            std::process::id()
        ));
        let registry_dir = temp_dir.join(".psmux");

        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&registry_dir).unwrap();
        std::fs::write(
            registry_dir.join("ops__packaged.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "ops__packaged",
                "namespace": "ops",
                "server_pid": 1234,
                "process_started_at": 1783580000000_u64,
                "server_exe": "winsmux.exe",
                "instance_nonce": "nonce-packaged",
                "port": 42125,
                "state": "ready",
                "owner": "normal",
                "created_at": 1783580001000_u64,
                "ready_at": 1783580002000_u64,
                "restore": {
                    "restore_metadata_version": 1,
                    "layer": "session_persistence_layer1",
                    "panes": [
                        {
                            "pane_id": "worker-2",
                            "window_id": "window-1",
                            "window_index": 0,
                            "pane_index": 1,
                            "agent_cli_session_id": "worker-2",
                            "transcript_ring_summary": {
                                "byte_count": 128,
                                "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                                "raw_transcript_stored": false
                            },
                            "provider_target": "grok-build:grok-4.5",
                            "model": "grok-4.5",
                            "model_source": "operator-override",
                            "context_capsule_ref": "capsule:packaged",
                            "checkpoint_ref": "checkpoint:packaged",
                            "restore_state": "candidate"
                        },
                        {
                            "pane_id": "worker-1",
                            "window_id": "window-1",
                            "window_index": 0,
                            "pane_index": 0,
                            "agent_cli_session_id": "worker-1",
                            "transcript_ring_summary": {
                                "byte_count": 64,
                                "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                                "raw_transcript_stored": false
                            },
                            "provider_target": "codex:gpt-5.4",
                            "model": "gpt-5.4",
                            "model_source": "operator-override",
                            "context_capsule_ref": "capsule:packaged",
                            "checkpoint_ref": "checkpoint:packaged",
                            "restore_state": "candidate"
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(
            registry_dir.join("ops____warm__.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "ops____warm__",
                "namespace": "ops",
                "port": 42126,
                "state": "ready",
                "owner": "warm",
                "created_at": 1783580001000_u64,
                "restore": {
                    "restore_metadata_version": 1,
                    "layer": "session_persistence_layer1",
                    "panes": []
                }
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(
            registry_dir.join("ops__legacy.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "ops__legacy",
                "namespace": "ops",
                "port": 42127,
                "state": "ready",
                "owner": "normal",
                "created_at": 1783580001000_u64
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(
            registry_dir.join("ops__stale_warm_owner.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "ops__stale_warm_owner",
                "namespace": "ops",
                "port": 42128,
                "state": "ready",
                "owner": "warm",
                "created_at": 1783580001000_u64,
                "restore": {
                    "restore_metadata_version": 1,
                    "layer": "session_persistence_layer1",
                    "panes": [
                        {
                            "pane_id": "worker-3",
                            "window_id": "window-1",
                            "window_index": 0,
                            "pane_index": 2,
                            "transcript_ring_summary": {
                                "byte_count": 16,
                                "raw_transcript_stored": false
                            },
                            "restore_state": "candidate"
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let payload = load_desktop_session_restore_candidates(
            Some(temp_dir.to_string_lossy().to_string()),
            Some(".psmux".to_string()),
        )
        .unwrap();
        let result = serde_json::to_value(payload).unwrap();

        assert_eq!(result["version"], 1);
        assert_eq!(result["registry_dir"], ".psmux");
        assert_eq!(result["candidates"].as_array().unwrap().len(), 1);
        assert_eq!(result["candidates"][0]["session"], "ops__packaged");
        assert_eq!(result["candidates"][0]["owner"], "normal");
        assert_eq!(result["candidates"][0]["namespace"], "ops");
        assert_eq!(result["candidates"][0]["restore_state"], "candidate");
        assert_eq!(result["candidates"][0]["panes"][0]["pane_id"], "worker-1");
        assert_eq!(result["candidates"][0]["panes"][1]["pane_id"], "worker-2");
        assert_eq!(
            result["candidates"][0]["panes"][1]["provider_target"],
            "grok-build:grok-4.5"
        );
        assert_eq!(
            result["candidates"][0]["panes"][1]["transcript_ring_summary"]["raw_transcript_stored"],
            false
        );

        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn load_desktop_session_restore_candidates_marks_expired_panes_setup_required() {
        let temp_dir = std::env::temp_dir().join(format!(
            "winsmux-desktop-session-restore-expired-{}",
            std::process::id()
        ));
        let registry_dir = temp_dir.join(".psmux");

        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&registry_dir).unwrap();
        std::fs::write(
            registry_dir.join("ops__expired.registry.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "protocol_version": 1,
                "session": "ops__expired",
                "namespace": "ops",
                "server_pid": 1234,
                "process_started_at": 1783580000000_u64,
                "server_exe": "winsmux.exe",
                "instance_nonce": "nonce-expired",
                "port": 42129,
                "state": "ready",
                "owner": "normal",
                "created_at": 1783580001000_u64,
                "ready_at": 1783580002000_u64,
                "restore": {
                    "restore_metadata_version": 1,
                    "layer": "session_persistence_layer1",
                    "panes": [
                        {
                            "pane_id": "worker-3",
                            "window_id": "window-1",
                            "window_index": 0,
                            "pane_index": 0,
                            "agent_cli_session_id": "worker-3",
                            "transcript_ring_summary": {
                                "byte_count": 32,
                                "raw_transcript_stored": false
                            },
                            "provider_target": "codex:gpt-5.4",
                            "model": "gpt-5.4",
                            "model_source": "operator-override",
                            "context_capsule_ref": "capsule:expired",
                            "checkpoint_ref": "checkpoint:expired",
                            "restore_state": "pane_exited"
                        }
                    ]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let payload = load_desktop_session_restore_candidates(
            Some(temp_dir.to_string_lossy().to_string()),
            Some(".psmux".to_string()),
        )
        .unwrap();
        let result = serde_json::to_value(payload).unwrap();

        assert_eq!(result["candidates"].as_array().unwrap().len(), 1);
        assert_eq!(result["candidates"][0]["restore_state"], "setup-required");
        assert_eq!(
            result["candidates"][0]["setup_required_reason"],
            "agent-session-expired"
        );
        assert_eq!(
            result["candidates"][0]["panes"][0]["restore_state"],
            "setup-required"
        );
        assert_eq!(
            result["candidates"][0]["panes"][0]["setup_required_reason"],
            "agent-session-expired"
        );

        let _ = std::fs::remove_dir_all(temp_dir);
    }
}
