use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde_json::{json, Map, Value as JsonValue};

use crate::instruction_pack;
use crate::team_profile::{
    model_readiness, provider_readiness, resolve_project, ResolvedSlot, ResolvedTeam, ValidationIssue,
};

const ARTIFACT_PATTERN: &str = ".winsmux/runs/<slot-id>/result.md";
const ARTIFACT_JUDGE: &str = "winsmux worker-artifact --action judge --json";
const READINESS_CANNOT_RUN: [&str; 3] = ["blocked", "reference-only", "unavailable"];
const READINESS_LAUNCH_RECHECK: [&str; 2] = ["candidate", "setup-required"];
const READINESS_OK: [&str; 2] = ["selectable", "runnable"];
const COMMON_CONTRACT_STATES: [&str; 7] = [
    "selectable",
    "candidate",
    "setup-required",
    "runnable",
    "blocked",
    "reference-only",
    "unavailable",
];

pub(crate) fn settings_view(project_dir: &Path) -> JsonValue {
    match resolve_project(project_dir) {
        Ok(team) => view_from_team(team, Vec::new()),
        Err(issues) => view_from_failure(project_dir, issues),
    }
}

pub(crate) fn start_gate(project_dir: &Path) -> (JsonValue, bool) {
    let view = settings_view(project_dir);
    let opted_in = view["opted_in"].as_bool().unwrap_or(false);
    if !opted_in {
        let payload = json!({
            "schema_version": 1,
            "action": "start-gate",
            "opted_in": false,
            "ok": true,
            "transaction": "not_applicable",
            "start_allowed": false,
            "reason_code": "legacy_roster",
            "partial_start": false,
            "refused_slots": [],
            "warnings": [],
            "settings": view,
        });
        return (payload, true);
    }
    let start_allowed = view["start_allowed"].as_bool().unwrap_or(false);
    let refused: Vec<JsonValue> = view["rows"]
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .filter(|row| row["cannot_run"].as_bool().unwrap_or(false) || row["launch_blocked"].as_bool().unwrap_or(false))
        .cloned()
        .collect();
    let warnings = view["warnings"].clone();
    let reason = if start_allowed {
        JsonValue::Null
    } else if view["rows"].as_array().map(|rows| rows.len()).unwrap_or(0) != 6 {
        json!("six_slot_incomplete")
    } else {
        json!("slot_cannot_run")
    };
    let payload = json!({
        "schema_version": 1,
        "action": "start-gate",
        "opted_in": true,
        "ok": start_allowed,
        "transaction": if start_allowed { "accepted" } else { "rejected" },
        "start_allowed": start_allowed,
        "reason_code": reason,
        "partial_start": false,
        "refused_slots": refused.iter().map(|row| json!({
            "slot_id": row["slot_id"],
            "cannot_run": row["cannot_run"],
            "launch_blocked": row["launch_blocked"],
        })).collect::<Vec<_>>(),
        "warnings": warnings,
        "settings": view,
    });
    (payload, start_allowed)
}

pub(crate) fn pre_release_gate() -> JsonValue {
    let docs_ok = docs_examples_parse();
    let contract_ok = common_contract_parity();
    let diff_ok = git_diff_check();
    let public_ok = public_surface_docs();
    let git_guard = git_guard_status();
    let windows_skipped = json!([
        "Pester",
        "installer/E2E",
        "scripts/git-guard.ps1 -Mode full",
        "scripts/audit-public-surface.ps1",
        "desktop UI E2E",
        "PowerShell 7.6 load/save round-trip"
    ]);
    let linux_ok = docs_ok["ok"].as_bool().unwrap_or(false)
        && contract_ok["ok"].as_bool().unwrap_or(false)
        && diff_ok["ok"].as_bool().unwrap_or(false)
        && public_ok["ok"].as_bool().unwrap_or(false);
    json!({
        "schema_version": 1,
        "action": "pre-release-gate",
        "ok": linux_ok,
        "combined_release": "blocked_pending_task_662",
        "gates": {
            "focused_tests": {
                "status": "not_run",
                "evidence": "this action does not execute cargo test; required command remains cargo test --manifest-path core/Cargo.toml --locked --lib team_profile_settings --test team_profile_settings_contract"
            },
            "common_contract_parity": contract_ok,
            "public_surface_audit": public_ok,
            "git_diff_check": diff_ok,
            "git_guard_full": git_guard,
            "docs_examples": docs_ok
        },
        "checkpoints": artifact_checkpoint("pending"),
        "skipped_windows_gates": windows_skipped
    })
}

fn view_from_failure(project_dir: &Path, issues: Vec<ValidationIssue>) -> JsonValue {
    let yaml = fs::read_to_string(project_dir.join(".winsmux.yaml")).unwrap_or_default();
    let opted_in = yaml.lines().any(|line| {
        let trimmed = line.trim();
        trimmed.starts_with("team-profile:") || trimmed.starts_with("team_profile:")
    });
    json!({
        "schema_version": 1,
        "action": "settings-view",
        "opted_in": opted_in,
        "ok": false,
        "apply_allowed": false,
        "start_allowed": false,
        "preset": JsonValue::Null,
        "update_policy": if opted_in { json!("retain-overrides") } else { JsonValue::Null },
        "rows": [],
        "issues": issues,
        "warnings": [],
        "runtime_display": [],
        "checkpoints": artifact_checkpoint("pending"),
        "reason_code": "validation_failed"
    })
}

fn view_from_team(team: ResolvedTeam, extra_issues: Vec<ValidationIssue>) -> JsonValue {
    if !team.opted_in {
        return json!({
            "schema_version": 1,
            "action": "settings-view",
            "opted_in": false,
            "ok": true,
            "apply_allowed": true,
            "start_allowed": false,
            "preset": JsonValue::Null,
            "update_policy": JsonValue::Null,
            "rows": team.slots.iter().map(|slot| legacy_row(slot)).collect::<Vec<_>>(),
            "issues": extra_issues,
            "warnings": [],
            "runtime_display": team.slots.iter().map(|slot| runtime_display(slot, "legacy", "ok", JsonValue::Null)).collect::<Vec<_>>(),
            "checkpoints": artifact_checkpoint("not_applicable"),
            "reason_code": "legacy_roster"
        });
    }
    let mut rows = Vec::new();
    let mut issues = extra_issues;
    let mut warnings = Vec::new();
    for slot in &team.slots {
        let (row, mut slot_issues, mut slot_warnings) = annotate_slot(slot);
        issues.append(&mut slot_issues);
        warnings.append(&mut slot_warnings);
        rows.push(row);
    }
    let cannot_run = rows.iter().any(|row| row["cannot_run"].as_bool().unwrap_or(false));
    let launch_blocked = rows.iter().any(|row| row["launch_blocked"].as_bool().unwrap_or(false));
    let six = rows.len() == 6;
    let apply_allowed = !issues.iter().any(|issue| issue.severity == "error") && six;
    let start_allowed = six && !cannot_run && !launch_blocked;
    let runtime_display: Vec<JsonValue> = rows
        .iter()
        .map(|row| row["runtime_display"].clone())
        .collect();
    json!({
        "schema_version": 1,
        "action": "settings-view",
        "opted_in": true,
        "ok": start_allowed,
        "apply_allowed": apply_allowed,
        "start_allowed": start_allowed,
        "preset": team.team_profile.as_ref().map(|meta| json!({
            "id": meta.preset,
            "revision": meta.preset_revision,
            "update_policy": meta.update_policy,
        })),
        "update_policy": "retain-overrides",
        "rows": rows,
        "issues": issues,
        "warnings": warnings,
        "runtime_display": runtime_display,
        "checkpoints": artifact_checkpoint("pending"),
        "reason_code": if start_allowed { JsonValue::Null } else { json!("slot_cannot_run") }
    })
}

fn legacy_row(slot: &ResolvedSlot) -> JsonValue {
    json!({
        "slot_id": slot.slot_id,
        "cannot_run": false,
        "launch_blocked": false,
        "assignment": assignment_object(slot),
        "fields": field_sources(slot, "legacy"),
        "issues": [],
        "runtime_display": runtime_display(slot, "legacy", "ok", JsonValue::Null),
        "artifact": artifact_for_slot(&slot.slot_id)
    })
}

fn annotate_slot(slot: &ResolvedSlot) -> (JsonValue, Vec<ValidationIssue>, Vec<JsonValue>) {
    let mut issues = Vec::new();
    let mut warnings = Vec::new();
    let mut cannot_run = false;
    let mut launch_blocked = false;
    if let Some(state) = model_readiness(&slot.model) {
        apply_readiness(
            slot,
            "model",
            &state,
            &mut issues,
            &mut warnings,
            &mut cannot_run,
            &mut launch_blocked,
        );
    }
    if let Some(state) = provider_readiness(&slot.provider) {
        apply_readiness(
            slot,
            "provider",
            &state,
            &mut issues,
            &mut warnings,
            &mut cannot_run,
            &mut launch_blocked,
        );
    }
    let pack = match instruction_pack::compose_json(
        &slot.provider,
        &slot.model,
        &slot.role_profile,
        &slot.lifecycle,
        &slot.task_classes,
    ) {
        Ok(value) => value,
        Err(pack_issues) => {
            cannot_run = true;
            for pack_issue in pack_issues {
                issues.push(ValidationIssue {
                    slot_id: Some(slot.slot_id.clone()),
                    field: pack_issue.field,
                    code: pack_issue.code,
                    severity: "error".to_string(),
                    remediation: pack_issue.remediation,
                });
            }
            JsonValue::Null
        }
    };
    let validation = if cannot_run {
        "cannot_run"
    } else if launch_blocked {
        "warning"
    } else {
        "ok"
    };
    let source = if slot.overrides.is_empty() {
        "preset"
    } else {
        "override"
    };
    let row = json!({
        "slot_id": slot.slot_id,
        "cannot_run": cannot_run,
        "launch_blocked": launch_blocked,
        "assignment": assignment_object(slot),
        "fields": field_sources(slot, "preset"),
        "instruction_pack": pack,
        "issues": issues,
        "runtime_display": runtime_display(slot, source, validation, pack.get("digest_sha256").cloned().unwrap_or(JsonValue::Null)),
        "artifact": artifact_for_slot(&slot.slot_id)
    });
    (row, issues, warnings)
}

fn apply_readiness(
    slot: &ResolvedSlot,
    field: &str,
    state: &str,
    issues: &mut Vec<ValidationIssue>,
    warnings: &mut Vec<JsonValue>,
    cannot_run: &mut bool,
    launch_blocked: &mut bool,
) {
    if READINESS_CANNOT_RUN.contains(&state) {
        *cannot_run = true;
        let code = format!("catalog_{}", state.replace('-', "_"));
        let issue = ValidationIssue {
            slot_id: Some(slot.slot_id.clone()),
            field: field.to_string(),
            code: code.clone(),
            severity: "warning".to_string(),
            remediation: format!(
                "Catalog state '{state}' is non-runnable. The slot cannot start until the catalog entry is selectable."
            ),
        };
        warnings.push(json!({
            "slot_id": slot.slot_id,
            "field": field,
            "code": code,
            "catalog_state": state,
            "cannot_run": true
        }));
        issues.push(issue);
        return;
    }
    if READINESS_LAUNCH_RECHECK.contains(&state) {
        *launch_blocked = true;
        let code = format!("catalog_{}", state.replace('-', "_"));
        let issue = ValidationIssue {
            slot_id: Some(slot.slot_id.clone()),
            field: field.to_string(),
            code: code.clone(),
            severity: "warning".to_string(),
            remediation: format!(
                "Catalog state '{state}' requires a runtime readiness recheck. Warnings never authorize launch."
            ),
        };
        warnings.push(json!({
            "slot_id": slot.slot_id,
            "field": field,
            "code": code,
            "catalog_state": state,
            "required_env_name_only": true
        }));
        issues.push(issue);
        return;
    }
    if !READINESS_OK.contains(&state) && !state.is_empty() && !COMMON_CONTRACT_STATES.contains(&state) {
        *launch_blocked = true;
        warnings.push(json!({
            "slot_id": slot.slot_id,
            "field": field,
            "code": "catalog_unknown_state",
            "catalog_state": state
        }));
    }
}

fn assignment_object(slot: &ResolvedSlot) -> JsonValue {
    json!({
        "provider": slot.provider,
        "model": slot.model,
        "launch_model": slot.launch_model,
        "reasoning_effort": slot.reasoning_effort,
        "role_profile": slot.role_profile,
        "lifecycle": slot.lifecycle,
        "task_classes": slot.task_classes,
        "delegation": slot.delegation,
        "worker_backend": slot.worker_backend,
        "overrides": slot.overrides
    })
}

fn field_sources(slot: &ResolvedSlot, inherited: &str) -> JsonValue {
    let mut fields = Map::new();
    for (name, value) in [
        ("provider", json!(slot.provider)),
        ("model", json!(slot.model)),
        ("reasoning-effort", json!(slot.reasoning_effort)),
        ("role-profile", json!(slot.role_profile)),
        ("lifecycle", json!(slot.lifecycle)),
        ("task-classes", json!(slot.task_classes)),
        ("delegation", json!(slot.delegation)),
    ] {
        let source = if slot.overrides.iter().any(|item| item == name) {
            "override"
        } else {
            inherited
        };
        fields.insert(
            name.to_string(),
            json!({
                "value": value,
                "source": source
            }),
        );
    }
    JsonValue::Object(fields)
}

fn runtime_display(slot: &ResolvedSlot, source: &str, validation: &str, bundle_digest: JsonValue) -> JsonValue {
    json!({
        "slot_id": slot.slot_id,
        "provider": slot.provider,
        "model": slot.model,
        "reasoning_effort": slot.reasoning_effort,
        "role_profile": slot.role_profile,
        "lifecycle": slot.lifecycle,
        "task_classes": slot.task_classes,
        "source": source,
        "validation": validation,
        "prompt_bundle_digest": bundle_digest
    })
}

fn artifact_for_slot(slot_id: &str) -> JsonValue {
    json!({
        "output": format!(".winsmux/runs/{slot_id}/result.md"),
        "completion_authority": "output-file-and-exit-code",
        "pty_capture_is_auxiliary": true,
        "judge": ARTIFACT_JUDGE
    })
}

fn artifact_checkpoint(task_662: &str) -> JsonValue {
    json!({
        "task_785_artifact": {
            "completion_authority": "output-file-and-exit-code",
            "output_pattern": ARTIFACT_PATTERN,
            "judge": ARTIFACT_JUDGE,
            "pty_capture_is_auxiliary": true
        },
        "task_662": {
            "status": task_662,
            "requires": ["task-718-pre-release-gate"]
        }
    })
}

fn repo_root() -> PathBuf {
    if let Ok(manifest) = env::var("CARGO_MANIFEST_DIR") {
        return PathBuf::from(manifest).join("..");
    }
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn docs_examples_parse() -> JsonValue {
    let path = repo_root().join("docs/operator-model.md");
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) => {
            return json!({"ok": false, "reason": error.to_string()});
        }
    };
    let Some(example) = extract_marked_yaml(&text, "team-profile-settings-example") else {
        return json!({"ok": false, "reason": "missing team-profile-settings-example"});
    };
    let dir = match tempfile_dir() {
        Ok(dir) => dir,
        Err(error) => return json!({"ok": false, "reason": error}),
    };
    if fs::write(dir.join(".winsmux.yaml"), example).is_err() {
        return json!({"ok": false, "reason": "failed to write example"});
    }
    match resolve_project(&dir) {
        Ok(team) if team.opted_in && team.slots.len() == 6 => json!({"ok": true, "slots": 6}),
        Ok(_) => json!({"ok": false, "reason": "example did not resolve six opted-in slots"}),
        Err(issues) => json!({"ok": false, "reason": "example failed schema parse", "issues": issues}),
    }
}

fn public_surface_docs() -> JsonValue {
    let files = [
        repo_root().join("docs/operator-model.md"),
        repo_root().join("docs/provider-and-model-support.md"),
    ];
    let mut missing = Vec::new();
    let mut leaked = Vec::new();
    for path in files {
        let Ok(text) = fs::read_to_string(&path) else {
            missing.push(path.display().to_string());
            continue;
        };
        if !text.contains("Team Profile") {
            missing.push(format!("{}: missing Team Profile section", path.display()));
        }
        if text.contains("sk-") || text.contains("gho_") || text.contains("OPENROUTER_API_KEY=") {
            leaked.push(path.display().to_string());
        }
    }
    json!({
        "ok": missing.is_empty() && leaked.is_empty(),
        "status": if cfg!(windows) { "partial" } else { "linux_docs_scan" },
        "skipped": "scripts/audit-public-surface.ps1",
        "missing": missing,
        "leaked": leaked
    })
}

fn common_contract_parity() -> JsonValue {
    let mut unknown = Vec::new();
    for state in crate::team_profile::catalog_readiness_states() {
        if !COMMON_CONTRACT_STATES.contains(&state.as_str()) {
            unknown.push(state);
        }
    }
    json!({
        "ok": unknown.is_empty(),
        "catalog_states": crate::team_profile::catalog_readiness_states(),
        "contract_states": COMMON_CONTRACT_STATES,
        "unknown": unknown
    })
}

fn git_diff_check() -> JsonValue {
    let output = Command::new("git")
        .args(["diff", "--check"])
        .current_dir(repo_root())
        .output();
    match output {
        Ok(result) if result.status.success() => json!({"ok": true, "status": "pass"}),
        Ok(result) => json!({
            "ok": false,
            "status": "fail",
            "stdout": String::from_utf8_lossy(&result.stdout),
            "stderr": String::from_utf8_lossy(&result.stderr)
        }),
        Err(error) => json!({"ok": false, "status": "error", "reason": error.to_string()}),
    }
}

fn git_guard_status() -> JsonValue {
    json!({
        "status": "skipped",
        "reason": "scripts/git-guard.ps1 -Mode full is a Windows-only pre-release gate"
    })
}

fn extract_marked_yaml(text: &str, marker: &str) -> Option<String> {
    let mut take = false;
    let mut lines = Vec::new();
    for line in text.lines() {
        if line.contains(marker) {
            take = true;
            continue;
        }
        if take {
            if line.starts_with("```") {
                if lines.is_empty() {
                    continue;
                }
                break;
            }
            lines.push(line);
        }
    }
    if lines.is_empty() {
        None
    } else {
        Some(lines.join("\n") + "\n")
    }
}

fn tempfile_dir() -> Result<PathBuf, String> {
    let base = env::temp_dir().join(format!(
        "winsmux-team-profile-settings-{}",
        std::process::id()
    ));
    fs::create_dir_all(&base).map_err(|error| error.to_string())?;
    Ok(base)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn opted_in_empty() -> &'static str {
        "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
    }

    #[test]
    fn official_preset_settings_view_is_six_inherited_runnable_rows() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
        let view = settings_view(dir.path());
        assert_eq!(view["opted_in"], true);
        assert_eq!(view["start_allowed"], true);
        assert_eq!(view["apply_allowed"], true);
        let rows = view["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 6);
        assert!(rows.iter().all(|row| row["fields"]["provider"]["source"] == "preset"));
        assert!(rows.iter().all(|row| row["cannot_run"] == false));
        assert_eq!(view["checkpoints"]["task_785_artifact"]["pty_capture_is_auxiliary"], true);
        assert_eq!(view["checkpoints"]["task_662"]["status"], "pending");
    }

    #[test]
    fn pre_release_gate_does_not_mark_unrun_focused_tests_as_pass() {
        let payload = pre_release_gate();
        assert_eq!(payload["gates"]["focused_tests"]["status"], "not_run");
        assert_ne!(payload["gates"]["focused_tests"]["status"], "pass");
    }

    #[test]
    fn user_override_is_marked_and_other_slots_stay_inherited() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(".winsmux.yaml"),
            opted_in_empty().replace(
                "agent-slots: []\n",
                "agent-slots:\n  - slot-id: worker-6\n    reasoning-effort: low\n",
            ),
        )
        .unwrap();
        let view = settings_view(dir.path());
        let rows = view["rows"].as_array().unwrap();
        assert_eq!(rows[5]["fields"]["reasoning-effort"]["source"], "override");
        assert_eq!(rows[5]["fields"]["reasoning-effort"]["value"], "low");
        assert_eq!(rows[0]["fields"]["reasoning-effort"]["source"], "preset");
        assert_eq!(rows[0]["fields"]["provider"]["source"], "preset");
    }

    #[test]
    fn setup_required_provider_warns_and_refuses_start() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(".winsmux.yaml"),
            r#"config-version: 1
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-6
    provider: openrouter
    model: openrouter-glm-5-2
    worker-backend: api_llm
    reasoning-effort: provider-default
    role-profile: maintainer
    lifecycle: task
    task-classes: [documentation, repository-operations]
"#,
        )
        .unwrap();
        let view = settings_view(dir.path());
        assert_eq!(view["start_allowed"], false);
        assert_eq!(view["apply_allowed"], true);
        let rows = view["rows"].as_array().unwrap();
        assert_eq!(rows[5]["launch_blocked"], true);
        assert_eq!(rows[5]["cannot_run"], false);
        assert!(view["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|warning| warning["code"] == "catalog_setup_required"));
        let (gate, allowed) = start_gate(dir.path());
        assert!(!allowed);
        assert_eq!(gate["transaction"], "rejected");
        assert_eq!(gate["partial_start"], false);
    }

    #[test]
    fn unknown_model_refuses_apply_and_start() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(".winsmux.yaml"),
            opted_in_empty().replace(
                "agent-slots: []\n",
                "agent-slots:\n  - slot-id: worker-1\n    model: definitely-not-a-catalog-id\n",
            ),
        )
        .unwrap();
        let view = settings_view(dir.path());
        assert_eq!(view["ok"], false);
        assert_eq!(view["start_allowed"], false);
        assert_eq!(view["apply_allowed"], false);
        let (gate, allowed) = start_gate(dir.path());
        assert!(!allowed);
        assert_eq!(gate["transaction"], "rejected");
    }

    #[test]
    fn catalog_blocked_policy_is_non_runnable() {
        let mut cannot_run = false;
        let mut launch_blocked = false;
        let mut issues = Vec::new();
        let mut warnings = Vec::new();
        let slot = ResolvedSlot {
            slot_id: "worker-1".into(),
            provider: "codex".into(),
            model: "blocked-model".into(),
            launch_model: String::new(),
            reasoning_effort: "high".into(),
            role_profile: "builder".into(),
            lifecycle: "task".into(),
            task_classes: vec!["implementation".into()],
            delegation: vec!["frozen-spec-implementation".into()],
            overrides: vec![],
            worker_backend: None,
        };
        apply_readiness(
            &slot,
            "model",
            "blocked",
            &mut issues,
            &mut warnings,
            &mut cannot_run,
            &mut launch_blocked,
        );
        assert!(cannot_run);
        assert!(!launch_blocked);
        assert_eq!(issues[0].code, "catalog_blocked");
        apply_readiness(
            &slot,
            "model",
            "reference-only",
            &mut issues,
            &mut warnings,
            &mut cannot_run,
            &mut launch_blocked,
        );
        apply_readiness(
            &slot,
            "model",
            "unavailable",
            &mut issues,
            &mut warnings,
            &mut cannot_run,
            &mut launch_blocked,
        );
        assert!(issues.iter().any(|issue| issue.code == "catalog_reference_only"));
        assert!(issues.iter().any(|issue| issue.code == "catalog_unavailable"));
    }

    #[test]
    fn legacy_roster_start_gate_is_not_applicable() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(".winsmux.yaml"),
            "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n",
        )
        .unwrap();
        let (gate, ok) = start_gate(dir.path());
        assert!(ok);
        assert_eq!(gate["transaction"], "not_applicable");
        assert_eq!(gate["reason_code"], "legacy_roster");
    }

    #[test]
    fn runtime_display_omits_prompt_body_and_secrets() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
        let view = settings_view(dir.path());
        let rendered = view.to_string();
        assert!(!rendered.contains("prompt_body"));
        assert!(!rendered.contains("OPENROUTER_API_KEY="));
        let display = &view["runtime_display"][0];
        assert!(display.get("provider").is_some());
        assert!(display.get("model").is_some());
        assert!(display.get("source").is_some());
        assert!(display.get("validation").is_some());
        assert!(display.get("prompt_bundle_digest").is_some());
        assert!(display.get("prompt_body").is_none());
    }
}
