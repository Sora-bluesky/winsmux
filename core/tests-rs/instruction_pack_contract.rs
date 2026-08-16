use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn opted_in_empty() -> &'static str {
    "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
}

#[test]
fn dispatch_task_still_refuses_unclassifiable_when_packs_exist() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .current_dir(dir.path())
        .args(["dispatch-task", "implement the leftover change"])
        .output()
        .expect("run dispatch-task");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success(), "stdout={stdout}");
    assert!(stdout.contains("missing_delegation"));
    assert!(!stdout.contains("instruction_pack"));
}

#[test]
fn dispatchable_classify_bundles_a1_criteria() {
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
        .expect("classify");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&output.stderr), stdout);
    assert!(stdout.contains("frozen-spec-implementation"));
    assert!(stdout.contains("instruction_pack"));
    assert!(stdout.contains("template_ids"));
    assert!(stdout.contains("design-judgment"));
}
