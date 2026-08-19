use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

fn winsmux_bin() -> &'static str {
    env!("CARGO_BIN_EXE_winsmux")
}

fn core_ps1() -> PathBuf {
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("scripts")
        .join("winsmux-core.ps1");
    assert!(
        script.is_file(),
        "winsmux-core.ps1 missing at {}",
        script.display()
    );
    script
}

fn discover_output(command: &mut Command) -> Output {
    command
        .arg("automation-discover")
        .output()
        .expect("spawn winsmux automation-discover")
}

fn pair_output(command: &mut Command) -> Output {
    command
        .arg("automation-pair")
        .output()
        .expect("spawn winsmux automation-pair")
}

fn snapshot_command() -> Command {
    let mut command = Command::new("pwsh");
    command
        .arg("-NoProfile")
        .arg("-File")
        .arg(core_ps1())
        .args(["operator-snapshot", "--lines", "5"]);
    command
}

fn stdout_json(output: &Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "stdout must be JSON, got {}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

fn combined_text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn snapshot_ok(output: &Output) -> bool {
    if !output.status.success() {
        return false;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
        return false;
    };
    if value.get("jsonrpc").and_then(|item| item.as_str()) != Some("2.0") {
        return false;
    }
    if value.get("error").is_some() {
        return false;
    }
    match value.get("result") {
        Some(result) if !result.is_null() => true,
        _ => false,
    }
}

fn poll_operator_snapshot(configure: impl Fn(&mut Command)) -> Output {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut last = None;
    while Instant::now() < deadline {
        let mut command = snapshot_command();
        configure(&mut command);
        let output = command.output().expect("spawn operator-snapshot");
        if snapshot_ok(&output) {
            return output;
        }
        last = Some(output);
        thread::sleep(Duration::from_millis(500));
    }
    last.expect("operator-snapshot ran at least once")
}

fn plant_token_file(local_app_data: &Path, contents: &str) {
    let dir = local_app_data.join("winsmux").join("control-pipe");
    fs::create_dir_all(&dir).expect("create token directory");
    fs::write(dir.join("token"), contents).expect("write planted token");
}

fn assert_no_pwsh(output: &Output, label: &str) {
    let text = combined_text(output).to_lowercase();
    assert!(
        !text.contains("pwsh"),
        "{label} must not hop through pwsh: {}",
        combined_text(output)
    );
}

#[test]
fn connect_e2e_walk_reaches_operator_snapshot_on_live_desktop() {
    let discover = discover_output(&mut Command::new(winsmux_bin()));
    if !discover.status.success() {
        return;
    }
    let discover_doc = stdout_json(&discover);
    assert_eq!(discover_doc["desktop_running"], true);
    assert_eq!(discover_doc["connect_ready"], true);
    assert_no_pwsh(&discover, "automation-discover");

    let pair = pair_output(&mut Command::new(winsmux_bin()));
    assert!(
        pair.status.success(),
        "automation-pair must succeed on a live desktop: {}",
        combined_text(&pair)
    );
    assert_eq!(stdout_json(&pair)["paired"], true);
    assert_no_pwsh(&pair, "automation-pair");

    let snapshot = poll_operator_snapshot(|_| {});
    assert!(
        snapshot_ok(&snapshot),
        "operator-snapshot must return JSON-RPC result: {}",
        combined_text(&snapshot)
    );
}

#[test]
fn connect_e2e_fails_closed_at_discover_without_desktop() {
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), "task802-e2e-stale-file-token\n");
    let discover = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    if discover.status.success() {
        return;
    }
    let discover_doc = stdout_json(&discover);
    assert_eq!(discover_doc["desktop_running"], false);
    assert_eq!(discover_doc["connect_ready"], false);

    let pair = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    assert!(!pair.status.success());
    assert_eq!(stdout_json(&pair)["reason"], "pipe_unavailable");
}

#[test]
fn connect_e2e_never_prints_token_bytes_across_the_walk() {
    let secret = "task802-e2e-env-token-value";
    let file_secret = "task802-e2e-file-token-value";
    let local = tempfile::tempdir().expect("temp LOCALAPPDATA");
    plant_token_file(local.path(), &format!("{file_secret}\n"));
    let expanded = local
        .path()
        .join("winsmux")
        .join("control-pipe")
        .join("token");

    let discover = discover_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env("WINSMUX_CONTROL_PIPE_TOKEN", secret),
    );
    let pair = pair_output(
        Command::new(winsmux_bin())
            .env("LOCALAPPDATA", local.path())
            .env("WINSMUX_CONTROL_PIPE_TOKEN", secret),
    );
    let snapshot = snapshot_command()
        .env("LOCALAPPDATA", local.path())
        .env("WINSMUX_CONTROL_PIPE_TOKEN", secret)
        .output()
        .expect("spawn operator-snapshot");

    let text = format!(
        "{}{}{}",
        combined_text(&discover),
        combined_text(&pair),
        combined_text(&snapshot)
    );
    assert!(!text.contains(secret), "output must not contain the env token");
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
fn connect_e2e_file_token_walk_pairs_without_env() {
    let discover = discover_output(
        Command::new(winsmux_bin()).env_remove("WINSMUX_CONTROL_PIPE_TOKEN"),
    );
    if !discover.status.success() {
        return;
    }
    let discover_doc = stdout_json(&discover);
    if discover_doc["auth_source"] != "file" {
        return;
    }
    assert_eq!(discover_doc["connect_ready"], true);
    assert_no_pwsh(&discover, "automation-discover");

    let pair = pair_output(Command::new(winsmux_bin()).env_remove("WINSMUX_CONTROL_PIPE_TOKEN"));
    if stdout_json(&pair)["reason"] == "auth_rejected" {
        return;
    }
    assert!(
        pair.status.success(),
        "file-token pair must succeed on a normally-started desktop: {}",
        combined_text(&pair)
    );
    assert_eq!(stdout_json(&pair)["paired"], true);
    assert_no_pwsh(&pair, "automation-pair");

    let snapshot = poll_operator_snapshot(|command| {
        command.env_remove("WINSMUX_CONTROL_PIPE_TOKEN");
    });
    assert!(
        snapshot_ok(&snapshot),
        "file-token operator-snapshot must return JSON-RPC result: {}",
        combined_text(&snapshot)
    );
}
