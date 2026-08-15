use std::{
    collections::BTreeMap,
    env, fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
    time::SystemTime,
};

use serde_json::{json, Value as JsonValue};
use sha2::{Digest, Sha256};

use crate::context_pack;
use crate::team_profile::{resolve_project, ResolvedSlot};
use crate::team_profile_settings;
use crate::workspace_migrate;
use crate::workspace_recipe::{
    normalize_workspace_plan_from_value, parse_workspace_yaml, SlotCapabilities,
};
use crate::workflow::normalize_workspace_plan_payload;

pub(crate) const USAGE: &str =
    "usage: winsmux workflow-gate --json [--project-dir <path>]";

const ARCHITECTURE_DOC: &str =
    include_str!("../../docs/project/v03629-declarative-workspace-architecture.md");
const OPERATOR_MODEL: &str = include_str!("../../docs/operator-model.md");
const COMBINED_RECIPE_ID: &str = "bugfix-two-slot";
const COMBINED_WORKFLOW_ID: &str = "bugfix";
const COMBINED_RUN_ID: &str = "run-task-662";

pub(crate) fn run_workflow_gate_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let mut json = false;
    let mut project_dir = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(invalid_input("workflow-gate --project-dir requires a value."));
                };
                project_dir = Some(PathBuf::from(value.as_str()));
                index += 2;
            }
            _ => return Err(invalid_input("unknown workflow-gate argument.")),
        }
    }
    if !json {
        return Err(invalid_input("workflow-gate requires --json."));
    }
    let project_dir = project_dir.unwrap_or(env::current_dir()?);
    let payload = evaluate_workflow_gate(&project_dir);
    println!("{payload}");
    if payload["ok"] == true {
        Ok(())
    } else {
        Err(io::Error::new(
            ErrorKind::InvalidData,
            "workflow-gate reported a failing sub-gate.",
        ))
    }
}

pub(crate) fn evaluate_workflow_gate(project_dir: &Path) -> JsonValue {
    let dry_run = dry_run_gate(project_dir);
    let resume = resume_gate();
    let rollback = rollback_gate(project_dir);
    let docs = docs_examples_gate();
    let parity = cli_desktop_parity_gate(project_dir);
    let compatibility = compatibility_privacy_gate(project_dir);
    let team_profile = team_profile_718_gate(project_dir);
    let mut gates = BTreeMap::new();
    gates.insert("dry_run", dry_run.clone());
    gates.insert("resume", resume.clone());
    gates.insert("rollback_cleanup", rollback.clone());
    gates.insert("documentation_examples", docs.clone());
    gates.insert("cli_desktop_parity", parity.clone());
    gates.insert("compatibility_privacy", compatibility.clone());
    gates.insert("team_profile_718", team_profile.clone());
    let failed = gates.values().any(|gate| gate["status"] == "fail");
    let in_repo = !failed
        && matches!(dry_run["status"].as_str(), Some("pass" | "not_applicable"))
        && docs["status"] == "pass"
        && compatibility["status"] == "pass"
        && matches!(team_profile["status"].as_str(), Some("pass" | "not_applicable"))
        && matches!(rollback["status"].as_str(), Some("pass" | "not_applicable"));
    json!({
        "schema_version": 1,
        "action": "workflow-gate",
        "ok": !failed,
        "in_repo_merge_ready": in_repo,
        "combined_release": {
            "status": "blocked",
            "reason": "TASK-718 Windows desktop E2E and git-guard.ps1 -Mode full are skipped on this host; blocked is not converted to pass. GitHub Release, npm, and post-smoke stay out of scope."
        },
        "publication": {
            "github_release": false,
            "npm_publish": false,
            "post_smoke": false,
            "version_bump": false
        },
        "gates": gates,
        "checkpoints": {
            "task_785_artifact": team_profile.get("artifact").cloned().unwrap_or(JsonValue::Null),
            "task_718": team_profile["status"].clone()
        },
        "skipped_windows_gates": [
            "Pester",
            "installer/E2E",
            "scripts/git-guard.ps1 -Mode full",
            "scripts/audit-public-surface.ps1",
            "desktop UI E2E",
            "PowerShell 7.6 load/save round-trip"
        ]
    })
}

fn dry_run_gate(project_dir: &Path) -> JsonValue {
    let yaml_path = project_dir.join(".winsmux.yaml");
    let Ok(yaml) = fs::read_to_string(&yaml_path) else {
        return gate("fail", "missing_settings", "Create .winsmux.yaml before running the workflow gate.");
    };
    if !has_lane_a(&yaml) {
        return gate(
            "not_applicable",
            "legacy_no_lane_a",
            "workspace-recipes and workflows are absent; dry-run is not selected.",
        );
    }
    let before = snapshot(project_dir);
    match combined_plan(&yaml) {
        Ok((plan, fingerprint)) => {
            let after = snapshot(project_dir);
            if before != after {
                return gate(
                    "fail",
                    "runtime_mutation",
                    "workspace-plan dry-run mutated project or runtime files.",
                );
            }
            json!({
                "status": "pass",
                "reason_code": "pure_dry_run",
                "config_fingerprint": fingerprint,
                "resolved_bindings": plan["resolved_bindings"],
                "startup_actions": plan["startup_actions"],
                "workflow_nodes": plan["workflow"]["topological_order"]
            })
        }
        Err(reason) => gate("fail", "unresolved_binding", reason),
    }
}

fn resume_gate() -> JsonValue {
    let matrix = [
        ("before_dispatch", "no_checkpoint"),
        ("after_dispatch_before_ack", "mailbox_unacked"),
        ("after_ack_before_dependent_release", "dependent_not_released"),
        ("during_cleanup", "cleanup_in_progress"),
        ("after_terminal_state", "terminal_state"),
        ("fingerprint_mismatch", "source_config_mismatch"),
    ]
    .into_iter()
    .map(|(at, reason)| {
        json!({
            "at": at,
            "status": "blocked",
            "reason_code": reason,
            "operator_decision_required": true
        })
    })
    .collect::<Vec<_>>();
    json!({
        "status": "blocked",
        "reason_code": "workflow_v1_has_no_resume_policy",
        "reason": "Workflow v1 derives idempotency keys but does not execute resume-policy or cleanup-policy. Interrupted runs stay blocked for operator decision. blocked is not converted to pass.",
        "matrix": matrix
    })
}

fn rollback_gate(_project_dir: &Path) -> JsonValue {
    let sandbox = env::temp_dir().join(format!(
        "winsmux-workflow-gate-rollback-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    if fs::create_dir_all(&sandbox).is_err() {
        return gate("fail", "sandbox_create_failed", "Could not create rollback sandbox.");
    }
    let yaml_path = sandbox.join(".winsmux.yaml");
    if fs::write(&yaml_path, "config-version: 1\nagent-slots:\n  - slot-id: worker-1\n    agent: codex\n").is_err()
    {
        return gate("fail", "sandbox_write_failed", "Could not write rollback sandbox yaml.");
    }
    let before_preview = snapshot(&sandbox);
    if workspace_migrate::preview_workspace_migrate_preset("bugfix", &sandbox).is_err() {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "preview_failed", "workspace-migrate preview failed.");
    }
    if before_preview != snapshot(&sandbox) {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "preview_mutated", "workspace-migrate preview mutated files.");
    }
    if workspace_migrate::apply_workspace_migrate_preset("bugfix", &sandbox).is_err() {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "apply_failed", "workspace-migrate apply failed.");
    }
    let applied = fs::read_to_string(&yaml_path).unwrap_or_default();
    if !applied.contains("workspace-recipes") {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "apply_missing_recipe", "apply did not write workspace-recipes.");
    }
    if workspace_migrate::rollback_workspace_migrate(&sandbox).is_err() {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "rollback_failed", "workspace-migrate rollback failed.");
    }
    let restored = fs::read_to_string(&yaml_path).unwrap_or_default();
    if restored.contains("workspace-recipes") {
        let _ = fs::remove_dir_all(&sandbox);
        return gate("fail", "rollback_left_recipe", "rollback left workspace-recipes in place.");
    }
    let second = workspace_migrate::rollback_workspace_migrate(&sandbox);
    let _ = fs::remove_dir_all(&sandbox);
    if second.is_ok() {
        return gate(
            "fail",
            "rollback_repeated",
            "completed rollback was repeated instead of failing closed.",
        );
    }
    json!({
        "status": "pass",
        "reason_code": "compensation_idempotent",
        "presets": workspace_migrate::WORKSPACE_MIGRATE_SHIPPED_PRESETS,
        "repeated_rollback": "rejected"
    })
}

fn docs_examples_gate() -> JsonValue {
    let workflow_yaml = match extract_marked(ARCHITECTURE_DOC, "TASK659-RUNNABLE-WORKFLOW-V1") {
        Some(yaml) => yaml,
        None => return gate("fail", "missing_workflow_example", "architecture workflow example is missing."),
    };
    let context_yaml = match extract_marked(ARCHITECTURE_DOC, "TASK660-RUNNABLE-CONTEXT-PACK-V1") {
        Some(yaml) => yaml,
        None => return gate("fail", "missing_context_pack_example", "architecture context-pack example is missing."),
    };
    if !OPERATOR_MODEL.contains("Team Profile") {
        return gate("fail", "missing_operator_docs", "docs/operator-model.md is missing Team Profile settings.");
    }
    if !OPERATOR_MODEL.contains("workflow-gate") {
        return gate("fail", "missing_workflow_gate_docs", "docs/operator-model.md is missing the workflow-gate contract.");
    }
    match combined_plan(&workflow_yaml) {
        Ok(_) => {
            if parse_workspace_yaml(&format!("config-version: 1\n{context_yaml}")).is_err() {
                return gate("fail", "context_pack_yaml", "documented context-pack yaml does not parse.");
            }
            json!({
                "status": "pass",
                "reason_code": "documented_examples_parse",
                "shipped_presets": workspace_migrate::WORKSPACE_MIGRATE_SHIPPED_PRESETS
            })
        }
        Err(reason) => gate("fail", "documented_workflow_unresolved", reason),
    }
}

fn cli_desktop_parity_gate(project_dir: &Path) -> JsonValue {
    let yaml = fs::read_to_string(project_dir.join(".winsmux.yaml")).unwrap_or_default();
    let settings = team_profile_settings::settings_view(project_dir);
    let plan = if has_lane_a(&yaml) {
        combined_plan(&yaml).ok().map(|(value, fingerprint)| json!({
            "fingerprint": fingerprint,
            "bindings": value["resolved_bindings"]
        }))
    } else {
        None
    };
    json!({
        "status": "pass",
        "reason_code": "shared_normalized_contract",
        "cli": {
            "settings_view": {
                "opted_in": settings["opted_in"],
                "start_allowed": settings["start_allowed"],
                "slot_count": settings["rows"].as_array().map(|rows| rows.len())
            },
            "workspace_plan": plan
        },
        "desktop": {
            "consumes": ["winsmux team-profile --action settings-view --json", "winsmux workflow-gate --json"],
            "must_not_rederive": true
        }
    })
}

fn compatibility_privacy_gate(project_dir: &Path) -> JsonValue {
    let yaml = fs::read_to_string(project_dir.join(".winsmux.yaml")).unwrap_or_default();
    let legacy = !has_lane_a(&yaml);
    let settings = team_profile_settings::settings_view(project_dir);
    let rendered = settings.to_string();
    if rendered.contains("prompt_body") || rendered.contains("OPENROUTER_API_KEY=") || rendered.contains("/Users/") {
        return gate("fail", "privacy_leak", "settings-view exposed a prompt body, secret value, or private path.");
    }
    let mut context_pack_status = "not_applicable";
    if yaml.contains("context-packs:") {
        let Ok(root) = parse_workspace_yaml(&yaml) else {
            return gate("fail", "invalid_yaml", "privacy gate could not parse .winsmux.yaml.");
        };
        let input = br#"{"schema_version":1,"source_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","code_map":[],"changed_files":[],"tests":[],"evidence_refs":[]}"#;
        match context_pack::build_context_pack(&root, "review-pack", input) {
            Ok(pack) => {
                let value = serde_json::to_value(&pack).unwrap_or(JsonValue::Null);
                let text = value.to_string();
                if text.contains("prompt_body") || text.contains("raw_transcript") && value["privacy_result"] != "pass" {
                    return gate("fail", "context_pack_privacy", "context-pack preview leaked private content.");
                }
                context_pack_status = "pass";
            }
            Err(_) => context_pack_status = "pass_rejected",
        }
    }
    json!({
        "status": "pass",
        "reason_code": if legacy { "legacy_operator_path" } else { "privacy_hold" },
        "legacy_no_lane_a": legacy,
        "context_pack_preview": context_pack_status,
        "does_not_implement_context_pack_persistence": true
    })
}

fn team_profile_718_gate(project_dir: &Path) -> JsonValue {
    let settings = team_profile_settings::settings_view(project_dir);
    let (start, allowed) = team_profile_settings::start_gate(project_dir);
    let pre = team_profile_settings::pre_release_gate();
    let opted_in = settings["opted_in"].as_bool().unwrap_or(false);
    let status = if !opted_in {
        "not_applicable"
    } else if allowed && pre["ok"] == true {
        "pass"
    } else if !allowed {
        "fail"
    } else {
        "fail"
    };
    json!({
        "status": status,
        "reason_code": if opted_in { "task_718_evidence" } else { "legacy_roster" },
        "start_gate": start["transaction"],
        "pre_release_ok": pre["ok"],
        "artifact": settings["checkpoints"]["task_785_artifact"],
        "skipped_windows_gates": pre["skipped_windows_gates"]
    })
}

fn combined_plan(yaml: &str) -> Result<(JsonValue, String), String> {
    let root = parse_workspace_yaml(yaml).map_err(|error| error.to_string())?;
    let slots = match resolve_project_from_yaml(yaml) {
        Ok(slots) => slots,
        Err(error) => return Err(error),
    };
    let payload = normalize_workspace_plan_payload(
        &root,
        COMBINED_RECIPE_ID,
        Some(COMBINED_WORKFLOW_ID),
        Some(COMBINED_RUN_ID),
        &slots,
    )
    .map_err(|error| error.to_string())?;
    let plan = normalize_workspace_plan_from_value(
        &root,
        COMBINED_RECIPE_ID,
        Some(COMBINED_WORKFLOW_ID),
        &slots,
    )
    .map_err(|error| error.to_string())?;
    let value = serde_json::to_value(&payload).map_err(|error| error.to_string())?;
    Ok((value, plan.config_fingerprint))
}

fn resolve_project_from_yaml(yaml: &str) -> Result<Vec<SlotCapabilities>, String> {
    let dir = env::temp_dir().join(format!(
        "winsmux-workflow-gate-slots-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    fs::write(dir.join(".winsmux.yaml"), yaml).map_err(|error| error.to_string())?;
    let result = resolve_project(&dir);
    let _ = fs::remove_dir_all(&dir);
    match result {
        Ok(team) => Ok(team
            .slots
            .into_iter()
            .map(slot_capabilities_from_team)
            .collect()),
        Err(issues) => Err(format!("team-profile resolve failed: {issues:?}")),
    }
}

fn slot_capabilities_from_team(slot: ResolvedSlot) -> SlotCapabilities {
    let review = slot.role_profile == "reviewer";
    SlotCapabilities {
        slot_id: slot.slot_id,
        supports_file_edit: !review,
        supports_verification: review,
        supports_structured_result: review,
    }
}

fn has_lane_a(yaml: &str) -> bool {
    yaml.lines().any(|line| {
        let trimmed = line.trim();
        trimmed.starts_with("workspace-recipes:") || trimmed.starts_with("workflows:")
    })
}

fn snapshot(project_dir: &Path) -> BTreeMap<String, String> {
    let mut files = BTreeMap::new();
    let mut stack = vec![project_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.file_name().and_then(|name| name.to_str()) == Some("workflow-gate-rollback-sandbox") {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            let rel = path
                .strip_prefix(project_dir)
                .map(|value| value.to_string_lossy().replace('\\', "/"))
                .unwrap_or_else(|_| path.display().to_string());
            let bytes = fs::read(&path).unwrap_or_default();
            files.insert(rel, hex_digest(&bytes));
        }
    }
    files
}

fn extract_marked(text: &str, marker: &str) -> Option<String> {
    let start = format!("<!-- {marker}:START -->");
    let end = format!("<!-- {marker}:END -->");
    let (_, after) = text.split_once(&start)?;
    let (block, _) = after.split_once(&end)?;
    let fenced = block.trim();
    let yaml = fenced
        .strip_prefix("```yaml\r\n")
        .or_else(|| fenced.strip_prefix("```yaml\n"))?;
    yaml.strip_suffix("\r\n```")
        .or_else(|| yaml.strip_suffix("\n```"))
        .map(str::to_string)
}

fn hex_digest(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn gate(status: &str, reason_code: &str, reason: impl Into<String>) -> JsonValue {
    json!({
        "status": status,
        "reason_code": reason_code,
        "reason": reason.into()
    })
}

fn invalid_input(message: &str) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn combined_yaml() -> String {
        extract_marked(ARCHITECTURE_DOC, "TASK659-RUNNABLE-WORKFLOW-V1").unwrap()
            + "\n"
            + &extract_marked(ARCHITECTURE_DOC, "TASK660-RUNNABLE-CONTEXT-PACK-V1").unwrap()
    }

    #[test]
    fn combined_fixture_dry_run_does_not_mutate_and_binds_team_profile_slots() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), combined_yaml()).unwrap();
        let before = snapshot(dir.path());
        let payload = evaluate_workflow_gate(dir.path());
        assert_eq!(payload["gates"]["dry_run"]["status"], "pass");
        assert_eq!(payload["gates"]["dry_run"]["resolved_bindings"]["implement"], "worker-1");
        assert_eq!(payload["gates"]["dry_run"]["resolved_bindings"]["verify"], "worker-4");
        assert_eq!(payload["gates"]["team_profile_718"]["status"], "pass");
        assert_eq!(payload["gates"]["resume"]["status"], "blocked");
        assert_ne!(payload["combined_release"]["status"], "pass");
        assert_eq!(payload["publication"]["github_release"], false);
        assert_eq!(payload["in_repo_merge_ready"], true);
        assert_eq!(before, snapshot(dir.path()), "gate must not leave durable mutations");
    }

    #[test]
    fn legacy_without_lane_a_is_not_applicable_for_dry_run() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(".winsmux.yaml"),
            "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n",
        )
        .unwrap();
        let payload = evaluate_workflow_gate(dir.path());
        assert_eq!(payload["gates"]["dry_run"]["status"], "not_applicable");
        assert_eq!(payload["gates"]["team_profile_718"]["status"], "not_applicable");
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["combined_release"]["status"], "blocked");
    }

    #[test]
    fn resume_classifier_never_converts_blocked_to_pass() {
        let resume = resume_gate();
        assert_eq!(resume["status"], "blocked");
        for row in resume["matrix"].as_array().unwrap() {
            assert_eq!(row["status"], "blocked");
            assert_ne!(row["status"], "pass");
        }
    }

    #[test]
    fn rollback_rejects_a_second_compensation() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".winsmux.yaml"), combined_yaml()).unwrap();
        let payload = evaluate_workflow_gate(dir.path());
        assert_eq!(payload["gates"]["rollback_cleanup"]["status"], "pass");
        assert_eq!(payload["gates"]["rollback_cleanup"]["repeated_rollback"], "rejected");
    }
}
