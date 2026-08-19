use std::fs;
use std::path::Path;
use std::process::Command;

fn winsmux_bin() -> &'static str {
    env!("CARGO_BIN_EXE_winsmux")
}

fn pair_output(command: &mut Command) -> std::process::Output {
    command
        .arg("automation-pair")
        .output()
        .expect("spawn winsmux automation-pair")
}

fn stdout_json(output: &std::process::Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "stdout must be JSON, got {}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

fn combined_text(output: &std::process::Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn plant_token_file(local_app_data: &Path, contents: &str) {
    let dir = local_app_data.join("winsmux").join("control-pipe");
    fs::create_dir_all(&dir).expect("create token directory");
    fs::write(dir.join("token"), contents).expect("write planted token");
}

#[test]
fn automation_pair_fails_closed_when_pipe_absent() {
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "task802-pair-file-token\n");
    let output = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    if output.status.success() {
        return;
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let document = stdout_json(&output);
    assert_eq!(document["paired"], false);
    assert_eq!(document["reason"], "pipe_unavailable");
    assert!(
        stderr.contains("desktop control pipe is not available"),
        "missing pipe must fail closed without pwsh: {stderr}"
    );
    assert!(!stderr.to_lowercase().contains("pwsh"));
}

#[test]
fn automation_pair_fails_closed_without_any_token_source() {
    let local = tempfile::tempdir().expect("empty LOCALAPPDATA");
    let output = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert!(
        !output.status.success(),
        "no token source must fail closed"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    let document = stdout_json(&output);
    assert_eq!(document["paired"], false);
    assert_eq!(document["auth_source"], "none");
    assert_eq!(document["reason"], "no_token");
    assert!(
        stderr.contains("WINSMUX_CONTROL_PIPE_TOKEN"),
        "no_token stderr must name the env var: {stderr}"
    );
    assert!(
        stderr.contains("token file"),
        "no_token stderr must mention token file: {stderr}"
    );
    assert!(
        !stderr.contains("pipe_unavailable")
            && !stderr.contains("desktop control pipe is not available"),
        "no token must short-circuit without pipe I/O: {stderr}"
    );
    let expanded = local
        .path()
        .join("winsmux")
        .join("control-pipe")
        .join("token");
    assert!(
        !stderr.contains(expanded.to_string_lossy().as_ref()),
        "stderr must not contain a token path"
    );
}

#[test]
fn automation_pair_never_prints_token_bytes() {
    let secret = "task802-pair-env-token-value";
    let file_secret = "task802-pair-file-token-value";
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), &format!("{file_secret}\n"));
    let expanded = local
        .path()
        .join("winsmux")
        .join("control-pipe")
        .join("token");
    let output = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env("WINSMUX_CONTROL_PIPE_TOKEN", secret),
    );
    let text = combined_text(&output);
    assert!(
        !text.contains(secret),
        "output must not contain the env token"
    );
    assert!(
        !text.contains(file_secret),
        "output must not contain the file token"
    );
    assert!(
        !text.contains(r"%LOCALAPPDATA%\winsmux\control-pipe\token"),
        "output must not contain the token path template"
    );
    let expanded_text = expanded.to_string_lossy();
    assert!(
        !text.contains(expanded_text.as_ref()),
        "output must not contain the expanded token path"
    );
}

#[test]
fn automation_pair_reports_auth_source_precedence() {
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "task802-pair-file-token-value\n");

    let env_and_file = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env("WINSMUX_CONTROL_PIPE_TOKEN", "task802-pair-env-token-value"),
    );
    assert_eq!(stdout_json(&env_and_file)["auth_source"], "env");

    let file_only = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert_eq!(stdout_json(&file_only)["auth_source"], "file");

    let empty = tempfile::tempdir().expect("empty LOCALAPPDATA");
    let neither = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", empty.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert_eq!(stdout_json(&neither)["auth_source"], "none");

    let cwd = tempfile::tempdir().expect("cwd with relative token");
    plant_token_file(cwd.path(), "relative-planted-token\n");
    let empty_localappdata = pair_output(
        Command::new(winsmux_bin())
            .current_dir(cwd.path())
            .env("LOCALAPPDATA", "")
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert_eq!(
        stdout_json(&empty_localappdata)["auth_source"],
        "none",
        "empty LOCALAPPDATA must not resolve a relative token file"
    );
}

#[test]
fn automation_pair_pairs_against_running_desktop_and_rejects_wrong_token() {
    let probe = pair_output(
        Command::new(winsmux_bin()).env("WINSMUX_CONTROL_PIPE_TOKEN", "not-the-live-token"),
    );
    if stdout_json(&probe)["reason"] == "pipe_unavailable" {
        return;
    }

    let live = pair_output(&mut Command::new(winsmux_bin()));
    assert!(
        live.status.success(),
        "live desktop must pair with the current token: {}",
        String::from_utf8_lossy(&live.stderr)
    );
    let document = stdout_json(&live);
    assert_eq!(document["paired"], true);
    assert_eq!(document["pipe"], r"\\.\pipe\winsmux-control");
    assert_eq!(document["reason"], serde_json::Value::Null);

    let rejected = pair_output(
        Command::new(winsmux_bin()).env("WINSMUX_CONTROL_PIPE_TOKEN", "not-the-live-token"),
    );
    assert!(
        !rejected.status.success(),
        "wrong env token must fail against a live desktop"
    );
    let rejected_document = stdout_json(&rejected);
    assert_eq!(rejected_document["paired"], false);
    assert_eq!(rejected_document["reason"], "auth_rejected");
    assert_eq!(rejected_document["auth_source"], "env");
}
