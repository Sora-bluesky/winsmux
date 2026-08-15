use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn opted_in_empty() -> &'static str {
    "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
}

#[test]
fn settings_view_keeps_user_overrides_after_preset_fields() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        opted_in_empty().replace(
            "agent-slots: []\n",
            "agent-slots:\n  - slot-id: worker-6\n    reasoning-effort: low\n",
        ),
    )
    .unwrap();
    let save = bin()
        .args([
            "team-profile",
            "--action",
            "save",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .args(["--slot-id", "worker-2", "--field", "lifecycle", "--value", "one-shot"])
        .output()
        .expect("save");
    assert!(
        save.status.success(),
        "stderr={} stdout={}",
        String::from_utf8_lossy(&save.stderr),
        String::from_utf8_lossy(&save.stdout)
    );
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "settings-view",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .output()
        .expect("settings-view");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stdout={stdout}");
    assert!(stdout.contains("\"source\":\"override\"") || stdout.contains("\"source\": \"override\""));
    assert!(stdout.contains("worker-6"));
    assert!(stdout.contains("reasoning-effort"));
    assert!(stdout.contains("one-shot"));
    assert!(stdout.contains(".winsmux/runs/worker-2/result.md"));
}

#[test]
fn start_gate_accepts_official_six_slot_preset() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "start-gate",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .output()
        .expect("start-gate");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stdout={stdout}");
    assert!(stdout.contains("\"transaction\":\"accepted\"") || stdout.contains("\"transaction\": \"accepted\""));
    assert!(stdout.contains("\"partial_start\":false") || stdout.contains("\"partial_start\": false"));
}

#[test]
fn start_gate_refuses_unrunnable_slot_transactionally() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        opted_in_empty().replace(
            "agent-slots: []\n",
            "agent-slots:\n  - slot-id: worker-3\n    model: not-a-real-model\n",
        ),
    )
    .unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "start-gate",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .output()
        .expect("start-gate refuse");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success(), "unrunnable start must fail closed stdout={stdout}");
    assert!(stdout.contains("\"transaction\":\"rejected\"") || stdout.contains("\"transaction\": \"rejected\""));
    assert!(stdout.contains("\"partial_start\":false") || stdout.contains("\"partial_start\": false"));
}

#[test]
fn pre_release_gate_records_skipped_windows_gates() {
    let output = bin()
        .args(["team-profile", "--action", "pre-release-gate", "--json"])
        .output()
        .expect("pre-release-gate");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "stderr={} stdout={}",
        String::from_utf8_lossy(&output.stderr),
        stdout
    );
    assert!(stdout.contains("git-guard.ps1"));
    assert!(stdout.contains("skipped_windows_gates"));
    assert!(stdout.contains("task_785_artifact"));
    assert!(stdout.contains("common_contract_parity"));
}
