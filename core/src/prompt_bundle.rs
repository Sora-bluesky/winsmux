use std::{
    fs,
    io::{self, ErrorKind},
    path::Path,
};

use serde_json::{json, Value as JsonValue};
use sha2::{Digest, Sha256};

use crate::instruction_pack::{self, compose_pack};
use crate::team_profile::{self, ResolvedSlot, ResolvedTeam};

pub(crate) fn project_launch(
    project_dir: &Path,
    session_id: &str,
    slot_id: &str,
    worktree: Option<&str>,
    read_write_scope: Option<&str>,
) -> io::Result<JsonValue> {
    let session_id = require_token(session_id, "session-id")?;
    let slot_id = require_token(slot_id, "slot-id")?;
    let team = team_profile::resolve_project(project_dir).map_err(issues_error)?;
    if !team.opted_in {
        return Err(invalid_input(
            "prompt-bundle projection requires an opted-in team-profile.",
        ));
    }
    let slot = team
        .slots
        .iter()
        .find(|slot| slot.slot_id == slot_id)
        .ok_or_else(|| invalid_input(format!("unknown slot-id '{slot_id}'.")))?
        .clone();
    let pack = compose_pack(
        &slot.provider,
        &slot.model,
        &slot.role_profile,
        &slot.lifecycle,
        &slot.task_classes,
    )
    .map_err(pack_error)?;
    let metadata = launch_metadata(&slot, worktree, read_write_scope);
    if metadata.contains("task-id") || metadata.contains("task_id") {
        return Err(invalid_data("launch metadata must not include a task ID."));
    }
    let body = format!("{}\n\n{}\n", pack.body.trim_end(), metadata.trim_end());
    if body.to_ascii_lowercase().contains("task-id:") || body.contains("{{task") {
        return Err(invalid_data("launch bundle must not include a task identity."));
    }
    let digest = format!("{:x}", Sha256::digest(body.as_bytes()));
    let rel_path = format!(".winsmux/runtime/prompt-bundles/{session_id}/{slot_id}.md");
    let bundle_path = project_dir.join(&rel_path);
    let original_bundle = if bundle_path.is_file() {
        Some(fs::read(&bundle_path)?)
    } else {
        None
    };
    let projection = projection_value(
        &team,
        &slot,
        project_dir,
        &session_id,
        &rel_path,
        &digest,
        &pack.template_ids,
    )?;

    fs::create_dir_all(bundle_path.parent().ok_or_else(|| {
        invalid_input("prompt-bundle path has no parent directory.")
    })?)?;
    let tmp_bundle = bundle_path.with_extension("md.tmp-prompt-bundle");
    fs::write(&tmp_bundle, &body)?;
    if let Err(error) = replace_existing_file(&tmp_bundle, &bundle_path) {
        let _ = fs::remove_file(&tmp_bundle);
        restore_previous_bundle(&bundle_path, original_bundle.as_deref());
        return Err(error);
    }
    Ok(json!({
        "schema_version": 1,
        "ok": true,
        "action": "project-launch",
        "bundle_path": rel_path,
        "digest_sha256": digest,
        "template_ids": pack.template_ids,
        "projection": projection,
    }))
}

fn launch_metadata(
    slot: &ResolvedSlot,
    worktree: Option<&str>,
    read_write_scope: Option<&str>,
) -> String {
    let worktree = worktree.unwrap_or("(unset)");
    let scope = read_write_scope.unwrap_or("session");
    let evidence = slot.task_classes.join(",");
    format!(
        "# Launch metadata\n\n- slot-id: {}\n- worktree: {}\n- read-write-scope: {}\n- evidence-class: {}\n",
        slot.slot_id, worktree, scope, evidence
    )
}

fn projection_value(
    team: &ResolvedTeam,
    slot: &ResolvedSlot,
    project_dir: &Path,
    session_id: &str,
    rel_path: &str,
    digest: &str,
    template_ids: &[String],
) -> io::Result<JsonValue> {
    let source = fs::read(project_dir.join(".winsmux.yaml"))?;
    let source_config_sha256 = format!("{:x}", Sha256::digest(&source));
    let instruction_registry_sha256 = instruction_pack::registry_sha256()?;
    let meta = team.team_profile.as_ref();
    Ok(json!({
        "session": {
            "team_profile": {
                "preset": meta.map(|item| item.preset.clone()),
                "preset_revision": meta.map(|item| item.preset_revision),
                "source_config_sha256": source_config_sha256,
                "instruction_registry_sha256": instruction_registry_sha256,
                "session_id": session_id,
            }
        },
        "pane": {
            "slot_id": slot.slot_id,
            "assignment": {
                "provider": slot.provider,
                "model": slot.model,
                "launch_model": slot.launch_model,
                "reasoning_effort": slot.reasoning_effort,
                "role_profile": slot.role_profile,
                "lifecycle": slot.lifecycle,
                "task_classes": slot.task_classes,
                "worker_backend": slot.worker_backend,
                "source": if slot.overrides.is_empty() { "preset" } else { "override" },
            },
            "prompt_bundle": {
                "path": rel_path,
                "sha256": digest,
                "template_ids": template_ids,
            },
            "status": "ready"
        }
    }))
}

fn require_token(value: &str, name: &str) -> io::Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.contains(['/', '\\', '\0', '\n', '\r'])
        || trimmed.contains("..")
    {
        return Err(invalid_input(format!("invalid {name}.")));
    }
    Ok(trimmed.to_string())
}

fn issues_error(issues: Vec<team_profile::ValidationIssue>) -> io::Error {
    invalid_data(serde_json::to_string(&issues).unwrap_or_else(|_| "team-profile validation failed.".into()))
}

fn pack_error(issues: Vec<instruction_pack::InstructionIssue>) -> io::Error {
    invalid_data(serde_json::to_string(&issues).unwrap_or_else(|_| "instruction-pack projection failed.".into()))
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(ErrorKind::InvalidData, message.into())
}

fn restore_previous_bundle(bundle_path: &Path, original_bundle: Option<&[u8]>) {
    if let Some(original) = original_bundle {
        let _ = fs::write(bundle_path, original);
    } else {
        let _ = fs::remove_file(bundle_path);
    }
}

fn replace_existing_file(tmp_path: &Path, path: &Path) -> io::Result<()> {
    replace_existing_file_os(tmp_path, path)
}

#[cfg(windows)]
fn replace_existing_file_os(tmp_path: &Path, path: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    fn wide(value: &Path) -> Vec<u16> {
        value
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    let tmp = wide(tmp_path);
    let target = wide(path);
    let moved = unsafe {
        MoveFileExW(
            tmp.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_existing_file_os(tmp_path: &Path, path: &Path) -> io::Result<()> {
    fs::rename(tmp_path, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn opted_in_empty() -> &'static str {
        "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
    }

    fn seed_project() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
        dir
    }

    #[test]
    fn project_launch_writes_bundle_without_task_id() {
        let dir = seed_project();
        let payload = project_launch(dir.path(), "sess-1", "worker-1", Some("wt"), Some("session"))
            .expect("project");
        let rel = payload["bundle_path"].as_str().unwrap();
        let body = fs::read_to_string(dir.path().join(rel)).unwrap();
        assert!(body.contains("# Launch metadata"));
        assert!(body.contains("slot-id: worker-1"));
        assert!(body.contains("A1 delegation"));
        assert!(!body.to_ascii_lowercase().contains("task-id"));
        assert!(!body.contains("TASK-"));
        assert_eq!(payload["projection"]["pane"]["status"], "ready");
        assert!(payload["projection"]["pane"]["assignment"]
            .as_object()
            .expect("assignment")
            .contains_key("worker_backend"));
        assert!(payload["projection"]["pane"]["prompt_bundle"]["sha256"].as_str().unwrap().len() == 64);
        assert!(payload["projection"]["pane"].get("task_id").is_none());
        assert!(payload["projection"]["session"]["team_profile"].is_object());
        assert!(!dir.path().join(".winsmux/manifest.yaml").exists());
    }

    #[test]
    fn project_launch_does_not_create_stub_manifest_when_missing() {
        let dir = seed_project();
        assert!(!dir.path().join(".winsmux/manifest.yaml").exists());
        let payload = project_launch(dir.path(), "sess-1", "worker-1", None, None).unwrap();
        assert!(!dir.path().join(".winsmux/manifest.yaml").exists());
        assert_eq!(
            payload["projection"]["pane"]["prompt_bundle"]["path"],
            ".winsmux/runtime/prompt-bundles/sess-1/worker-1.md"
        );
        assert!(payload["projection"]["session"]["team_profile"].is_object());
    }

    #[test]
    fn project_launch_does_not_mutate_existing_live_manifest() {
        let dir = seed_project();
        let winsmux = dir.path().join(".winsmux");
        fs::create_dir_all(&winsmux).unwrap();
        let original = "version: 1\nsession:\n  name: existing\npanes:\n  worker-1:\n    pane_id: '%1'\n    role: Worker\n    label: worker-1\n  operator:\n    pane_id: '%0'\n    role: Operator\n";
        let manifest_path = winsmux.join("manifest.yaml");
        fs::write(&manifest_path, original).unwrap();
        let payload = project_launch(dir.path(), "sess-1", "worker-1", None, None).unwrap();
        assert_eq!(fs::read_to_string(&manifest_path).unwrap(), original);
        assert!(payload["projection"]["pane"]["prompt_bundle"].is_object());
        assert!(payload["projection"]["session"]["team_profile"].is_object());
        let bundle = dir.path().join(
            payload["bundle_path"]
                .as_str()
                .expect("bundle_path"),
        );
        assert!(fs::read_to_string(bundle).unwrap().contains("slot-id: worker-1"));
        assert!(!original.contains("team_profile:"));
    }

    #[test]
    fn failed_projection_does_not_write_partial_manifest() {
        let dir = seed_project();
        let winsmux = dir.path().join(".winsmux");
        fs::create_dir_all(&winsmux).unwrap();
        let original = "version: 1\nsession:\n  name: keep\npanes: {}\n";
        fs::write(winsmux.join("manifest.yaml"), original).unwrap();
        let err = project_launch(dir.path(), "sess-1", "worker-9", None, None).unwrap_err();
        assert!(!err.to_string().is_empty());
        assert_eq!(fs::read_to_string(winsmux.join("manifest.yaml")).unwrap(), original);
        let runtime = dir.path().join(".winsmux/runtime/prompt-bundles");
        assert!(!runtime.exists() || fs::read_dir(runtime).map(|entries| entries.count()).unwrap_or(0) == 0);
    }

    #[test]
    fn legacy_without_team_profile_is_not_projected() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), "agent-slots:\n  - slot-id: worker-1\n").unwrap();
        let err = project_launch(dir.path(), "sess-1", "worker-1", None, None).unwrap_err();
        assert!(err.to_string().contains("opted-in"));
    }
}
