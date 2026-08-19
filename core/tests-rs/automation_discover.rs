use std::fs;
use std::path::Path;
use std::process::Command;

fn winsmux_bin() -> &'static str {
    env!("CARGO_BIN_EXE_winsmux")
}

fn discover_output(command: &mut Command) -> std::process::Output {
    command
        .arg("automation-discover")
        .output()
        .expect("spawn winsmux automation-discover")
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
fn automation_discover_fails_closed_when_pipe_absent() {
    let output = discover_output(&mut Command::new(winsmux_bin()));
    if output.status.success() {
        return;
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let document = stdout_json(&output);
    assert_eq!(document["desktop_running"], false);
    assert_eq!(document["connect_ready"], false);
    assert!(
        stderr.contains("desktop control pipe is not available"),
        "missing pipe must fail closed without pwsh: {stderr}"
    );
    assert!(!stderr.to_lowercase().contains("pwsh"));
}

#[test]
fn automation_discover_does_not_trust_stale_token_file() {
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "planted-stale-token\n");
    let output = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    if output.status.success() {
        return;
    }
    let document = stdout_json(&output);
    assert_eq!(
        document["desktop_running"], false,
        "leftover token file must not fake liveness"
    );
}

#[test]
fn automation_discover_never_prints_token_bytes() {
    let secret = "task802-env-token-value";
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "task802-file-token-value\n");
    let expanded = local
        .path()
        .join("winsmux")
        .join("control-pipe")
        .join("token");
    let output = discover_output(
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
        !text.contains("task802-file-token-value"),
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
fn automation_discover_reports_auth_source_precedence() {
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "task802-file-token-value\n");

    let env_and_file = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env("WINSMUX_CONTROL_PIPE_TOKEN", "task802-env-token-value"),
    );
    assert_eq!(stdout_json(&env_and_file)["auth_source"], "env");

    let file_only = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert_eq!(stdout_json(&file_only)["auth_source"], "file");

    let empty = tempfile::tempdir().expect("empty LOCALAPPDATA");
    let neither = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", empty.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert_eq!(stdout_json(&neither)["auth_source"], "none");

    let cwd = tempfile::tempdir().expect("cwd with relative token");
    plant_token_file(cwd.path(), "relative-planted-token\n");
    let empty_localappdata = discover_output(
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
fn automation_discover_reports_running_desktop_contract() {
    let output = discover_output(&mut Command::new(winsmux_bin()));
    if !output.status.success() {
        return;
    }
    let document = stdout_json(&output);
    assert_eq!(document["desktop_running"], true);
    assert_eq!(
        document["pipe"],
        r"\\.\pipe\winsmux-control"
    );
    assert!(
        document["contract_version"].is_number(),
        "live contract version must be present"
    );
}
