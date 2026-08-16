use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn opted_in_empty() -> &'static str {
    "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
}

#[test]
fn team_profile_validate_json_accepts_official_empty_overrides() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "validate",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .output()
        .expect("run team-profile validate");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&output.stderr), stdout);
    assert!(stdout.contains("\"ok\":true"));
    assert!(stdout.contains("official-balanced-v1"));
    assert!(stdout.contains("worker-6"));
}

#[test]
fn dispatch_task_refuses_unclassifiable_when_team_profile_is_present() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .current_dir(dir.path())
        .args(["dispatch-task", "implement the leftover change"])
        .output()
        .expect("run dispatch-task");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "unclassifiable dispatch must fail closed stdout={stdout} stderr={stderr}");
    assert!(stdout.contains("\"delegation\":\"unclassifiable\"") || stdout.contains("\"delegation\": \"unclassifiable\""));
    assert!(stdout.contains("missing_delegation"));
}

#[test]
fn dispatch_task_returns_operator_owned_destructive_work() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .current_dir(dir.path())
        .args([
            "dispatch-task",
            "--task-class",
            "repository-operations",
            "--delegation",
            "destructive-ops",
            "reset the repository",
        ])
        .output()
        .expect("run dispatch-task");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success(), "operator-owned dispatch must return to operator stdout={stdout}");
    assert!(stdout.contains("\"delegation\":\"operator\"") || stdout.contains("\"delegation\": \"operator\""));
    assert!(stdout.contains("operator_owned"));
}

#[test]
fn team_profile_classify_worker_owned_is_dispatchable() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "classify",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .args([
            "--task-class",
            "implementation",
            "--delegation",
            "frozen-spec-implementation",
        ])
        .output()
        .expect("run team-profile classify");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&output.stderr), stdout);
    assert!(stdout.contains("\"status\":\"dispatchable\"") || stdout.contains("\"status\": \"dispatchable\""));
    assert!(stdout.contains("\"delegation\":\"worker\"") || stdout.contains("\"delegation\": \"worker\""));
    assert!(stdout.contains("worker-2"));
}

#[test]
fn team_profile_validate_json_fails_closed_for_invalid_profile() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        "team-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots:\n  - slot-id: worker-1\n    model: not-a-catalog-id\n",
    )
    .unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "validate",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .output()
        .expect("run team-profile validate");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !output.status.success(),
        "invalid validate must fail closed stderr={} stdout={}",
        String::from_utf8_lossy(&output.stderr),
        stdout
    );
    assert!(stdout.contains("\"ok\":false") || stdout.contains("\"ok\": false"));
}

#[test]
fn dispatch_task_forwards_classified_slot_instead_of_refusing() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .current_dir(dir.path())
        .args([
            "dispatch-task",
            "--task-class",
            "implementation",
            "--delegation",
            "frozen-spec-implementation",
            "implement the frozen spec",
        ])
        .output()
        .expect("run dispatch-task");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stdout.contains("missing_delegation"),
        "classified dispatch must not refuse stdout={stdout} stderr={stderr}"
    );
    assert!(
        !stdout.contains("unclassifiable"),
        "classified dispatch must not refuse as unclassifiable stdout={stdout} stderr={stderr}"
    );
}

#[test]
fn team_profile_reset_field_refuses_legacy_roster() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(".winsmux.yaml");
    let original = "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n";
    fs::write(&path, original).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "reset-field",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .args(["--slot-id", "worker-1", "--field", "provider"])
        .output()
        .expect("reset-field legacy");
    assert!(!output.status.success(), "legacy reset-field must fail");
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        combined.contains("opted-in team-profile"),
        "legacy reset-field must name the opt-in guard combined={combined}"
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), original);
}

#[test]
fn dispatch_task_without_team_profile_does_not_emit_team_profile_refusal() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        "agent-slots:\n  - slot-id: worker-1\n    agent: codex\n",
    )
    .unwrap();
    let output = bin()
        .current_dir(dir.path())
        .args(["dispatch-task", "implement leftover"])
        .output()
        .expect("run dispatch-task");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("missing_delegation"),
        "legacy dispatch must not use Team Profile unclassifiable refusal stdout={stdout}"
    );
}
