use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

fn opted_in_empty() -> &'static str {
    "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n"
}

#[test]
fn project_launch_cli_writes_bundle_and_status_projection() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "project-launch",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .args(["--session-id", "sess-cli", "--slot-id", "worker-1"])
        .output()
        .expect("project-launch");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&output.stderr), stdout);
    assert!(stdout.contains("\"ok\":true") || stdout.contains("\"ok\": true"));
    assert!(stdout.contains("prompt_bundle"));
    assert!(!stdout.contains("A1 delegation"));
    let bundle = dir.path().join(".winsmux/runtime/prompt-bundles/sess-cli/worker-1.md");
    let body = fs::read_to_string(&bundle).expect("bundle");
    assert!(body.contains("slot-id: worker-1"));
    assert!(!body.to_ascii_lowercase().contains("task-id"));
}

#[test]
fn project_launch_cli_refuses_unknown_slot_without_bundle() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join(".winsmux.yaml"), opted_in_empty()).unwrap();
    let output = bin()
        .args([
            "team-profile",
            "--action",
            "project-launch",
            "--json",
            "--project-dir",
        ])
        .arg(dir.path())
        .args(["--session-id", "sess-cli", "--slot-id", "worker-9"])
        .output()
        .expect("project-launch unknown");
    assert!(!output.status.success());
    assert!(!dir
        .path()
        .join(".winsmux/runtime/prompt-bundles/sess-cli/worker-9.md")
        .exists());
}
