use std::fs;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
}

#[test]
fn judge_missing_output_is_incomplete_even_with_pty_and_zero_exit() {
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("result.md");
    let pty = dir.path().join("pty.txt");
    fs::write(&pty, "pane transcript").unwrap();
    let result = bin()
        .args(["worker-artifact", "--action", "judge", "--json", "--output"])
        .arg(&output)
        .args(["--exit-code", "0", "--pty-capture"])
        .arg(&pty)
        .output()
        .expect("judge");
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(!result.status.success(), "stdout={stdout}");
    assert!(stdout.contains("\"status\":\"incomplete\"") || stdout.contains("\"status\": \"incomplete\""));
    assert!(stdout.contains("pty_capture_is_auxiliary"));
    assert!(stdout.contains("missing_artifact"));
}

#[test]
fn judge_result_md_and_zero_exit_is_complete() {
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("result.md");
    fs::write(&output, "# result\ndone\n").unwrap();
    let result = bin()
        .args(["worker-artifact", "--action", "judge", "--json", "--output"])
        .arg(&output)
        .args(["--exit-code", "0"])
        .output()
        .expect("judge complete");
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(result.status.success(), "stderr={} stdout={}", String::from_utf8_lossy(&result.stderr), stdout);
    assert!(stdout.contains("\"status\":\"complete\"") || stdout.contains("\"status\": \"complete\""));
}

#[test]
fn classify_dispatchable_names_result_md_artifact_path() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join(".winsmux.yaml"),
        "config-version: 1\nteam-profile:\n  schema-version: 1\n  preset: official-balanced-v1\n  preset-revision: 1\n  update-policy: retain-overrides\nagent-slots: []\n",
    )
    .unwrap();
    let result = bin()
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
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(result.status.success(), "stdout={stdout}");
    assert!(stdout.contains(".winsmux/runs/worker-2/result.md"));
    assert!(stdout.contains("pty_capture_is_auxiliary"));
}
