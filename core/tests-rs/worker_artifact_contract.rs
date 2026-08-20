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

fn assert_judge_rejects(args: &[&str], exact_stderr: &str) {
    let result = bin().args(args).output().expect("judge reject");
    let stdout = String::from_utf8(result.stdout.clone()).expect("stdout utf-8");
    let stderr = String::from_utf8(result.stderr.clone()).expect("stderr utf-8");
    assert!(
        !result.status.success(),
        "expected process failure; stdout={stdout} stderr={stderr}"
    );
    assert_eq!(stderr, format!("winsmux: {exact_stderr}\n"));
    assert_eq!(stdout, "");
}

#[test]
fn judge_rejects_bad_arguments_fail_closed() {
    assert_judge_rejects(
        &[
            "worker-artifact",
            "--action",
            "judge",
            "--json",
            "--output",
            "result.md",
            "--exit-code",
            "0",
            "--nope",
        ],
        "unknown worker-artifact argument.",
    );
    assert_judge_rejects(
        &[
            "worker-artifact",
            "--action",
            "judge",
            "--output",
            "result.md",
            "--exit-code",
            "0",
        ],
        "worker-artifact requires --json.",
    );
    assert_judge_rejects(
        &[
            "worker-artifact",
            "--action",
            "inspect",
            "--json",
            "--output",
            "result.md",
            "--exit-code",
            "0",
        ],
        "worker-artifact --action must be judge.",
    );
    assert_judge_rejects(
        &[
            "worker-artifact",
            "--action",
            "judge",
            "--json",
            "--exit-code",
            "0",
        ],
        "worker-artifact requires --output.",
    );
    assert_judge_rejects(
        &[
            "worker-artifact",
            "--action",
            "judge",
            "--json",
            "--output",
            "result.md",
            "--exit-code",
            "abc",
        ],
        "worker-artifact --exit-code must be an integer.",
    );
}

#[test]
fn judge_present_artifact_nonzero_exit_is_failed_and_process_fails() {
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("result.md");
    fs::write(&output, "partial\n").unwrap();
    let result = bin()
        .args(["worker-artifact", "--action", "judge", "--json", "--output"])
        .arg(&output)
        .args(["--exit-code", "2"])
        .output()
        .expect("judge failed");
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(
        !result.status.success(),
        "expected process failure; stdout={stdout} stderr={}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        stdout.contains("\"status\":\"failed\"") || stdout.contains("\"status\": \"failed\"")
    );
    assert!(
        stdout.contains("\"completion_authority\":\"output-file-and-exit-code\"")
            || stdout.contains("\"completion_authority\": \"output-file-and-exit-code\"")
    );
}
