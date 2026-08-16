use std::{
    fs,
    io::{self, ErrorKind},
    path::Path,
};

use serde_json::{json, Value as JsonValue};
use serde_yaml::{Mapping, Value};
use sha2::{Digest, Sha256};

use crate::instruction_pack::{self, compose_pack};
use crate::team_profile::{self, ResolvedSlot, ResolvedTeam};
use crate::workspace_recipe::parse_workspace_yaml;

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
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let original_manifest = if manifest_path.is_file() {
        Some(fs::read_to_string(&manifest_path)?)
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
    let merged_manifest = match original_manifest.as_deref() {
        Some(original) => merge_manifest(original, &projection, &slot.slot_id)?,
        None => merge_manifest(
            "version: 2\nsession: {}\npanes: {}\n",
            &projection,
            &slot.slot_id,
        )?,
    };

    fs::create_dir_all(bundle_path.parent().ok_or_else(|| {
        invalid_input("prompt-bundle path has no parent directory.")
    })?)?;
    fs::create_dir_all(manifest_path.parent().ok_or_else(|| {
        invalid_input("manifest path has no parent directory.")
    })?)?;
    let tmp_bundle = bundle_path.with_extension("md.tmp-prompt-bundle");
    fs::write(&tmp_bundle, &body)?;
    let tmp_manifest = manifest_path.with_extension("yaml.tmp-prompt-bundle");
    fs::write(&tmp_manifest, &merged_manifest)?;
    if let Err(error) = replace_existing_file(&tmp_bundle, &bundle_path) {
        let _ = fs::remove_file(&tmp_bundle);
        let _ = fs::remove_file(&tmp_manifest);
        return Err(error);
    }
    if let Err(error) = replace_existing_file(&tmp_manifest, &manifest_path) {
        let _ = fs::remove_file(&tmp_manifest);
        let _ = fs::remove_file(&bundle_path);
        if let Some(original) = original_manifest {
            let _ = fs::write(&manifest_path, original);
        }
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

fn merge_manifest(original: &str, projection: &JsonValue, slot_id: &str) -> io::Result<String> {
    let mut root = parse_workspace_yaml(original)?;
    let mapping = root
        .as_mapping_mut()
        .ok_or_else(|| invalid_data("manifest.yaml must be a mapping."))?;
    let session = mapping
        .entry(Value::String("session".into()))
        .or_insert(Value::Mapping(Mapping::new()));
    let session_map = session
        .as_mapping_mut()
        .ok_or_else(|| invalid_data("manifest session must be a mapping."))?;
    session_map.insert(
        Value::String("team_profile".into()),
        json_to_yaml(&projection["session"]["team_profile"]),
    );
    let panes = mapping
        .entry(Value::String("panes".into()))
        .or_insert(Value::Mapping(Mapping::new()));
    match panes {
        Value::Mapping(map) => {
            let entry = map
                .entry(Value::String(slot_id.into()))
                .or_insert(Value::Mapping(Mapping::new()));
            merge_pane(entry, &projection["pane"])?;
        }
        Value::Sequence(items) => {
            let mut found = false;
            for item in items.iter_mut() {
                let Some(map) = item.as_mapping_mut() else {
                    continue;
                };
                let id = map
                    .get(&Value::String("slot_id".into()))
                    .or_else(|| map.get(&Value::String("label".into())))
                    .and_then(Value::as_str);
                if id == Some(slot_id) {
                    merge_pane(item, &projection["pane"])?;
                    found = true;
                    break;
                }
            }
            if !found {
                items.push(json_to_yaml(&projection["pane"]));
            }
        }
        _ => {
            return Err(invalid_data("manifest panes must be a mapping or sequence."));
        }
    }
    serde_yaml::to_string(&root).map_err(|error| invalid_data(error.to_string()))
}

fn merge_pane(pane: &mut Value, projection: &JsonValue) -> io::Result<()> {
    let map = pane
        .as_mapping_mut()
        .ok_or_else(|| invalid_data("manifest pane must be a mapping."))?;
    for key in ["slot_id", "assignment", "prompt_bundle", "status"] {
        map.insert(
            Value::String(key.into()),
            json_to_yaml(&projection[key]),
        );
    }
    Ok(())
}

fn json_to_yaml(value: &JsonValue) -> Value {
    serde_yaml::to_value(value).unwrap_or(Value::Null)
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

#[cfg(windows)]
fn replace_existing_file(tmp_path: &Path, path: &Path) -> io::Result<()> {
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
fn replace_existing_file(tmp_path: &Path, path: &Path) -> io::Result<()> {
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
        let saved = fs::read_to_string(dir.path().join(".winsmux/manifest.yaml")).unwrap();
        assert!(saved.contains("team_profile:"));
        assert!(saved.contains("prompt_bundle:"));
    }

    #[test]
    fn project_launch_writes_manifest_when_missing() {
        let dir = seed_project();
        assert!(!dir.path().join(".winsmux/manifest.yaml").exists());
        project_launch(dir.path(), "sess-1", "worker-1", None, None).unwrap();
        let saved = fs::read_to_string(dir.path().join(".winsmux/manifest.yaml")).unwrap();
        assert!(saved.contains("team_profile:"));
        assert!(saved.contains("prompt_bundle:"));
        assert!(saved.contains("worker-1"));
    }

    #[test]
    fn project_launch_merges_existing_manifest_and_preserves_other_panes() {
        let dir = seed_project();
        let winsmux = dir.path().join(".winsmux");
        fs::create_dir_all(&winsmux).unwrap();
        fs::write(
            winsmux.join("manifest.yaml"),
            "version: 1\nsession:\n  name: existing\npanes:\n  worker-1:\n    pane_id: '%1'\n    role: Worker\n    label: worker-1\n  operator:\n    pane_id: '%0'\n    role: Operator\n",
        )
        .unwrap();
        project_launch(dir.path(), "sess-1", "worker-1", None, None).unwrap();
        let saved = fs::read_to_string(winsmux.join("manifest.yaml")).unwrap();
        assert!(saved.contains("name: existing"));
        assert!(saved.contains("team_profile:"));
        assert!(saved.contains("prompt_bundle:"));
        assert!(saved.contains("role: Operator"));
        assert!(!saved.contains("A1 delegation"));
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
