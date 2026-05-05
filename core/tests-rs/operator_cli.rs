use std::fs;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct ChildKillGuard(Child);

impl Drop for ChildKillGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn wait_for_stream_line(
    receiver: &mpsc::Receiver<String>,
    mut append_event: impl FnMut(usize),
) -> String {
    for attempt in 0..20 {
        append_event(attempt);
        if let Ok(line) = receiver.recv_timeout(Duration::from_millis(250)) {
            return line;
        }
    }
    panic!("stream should emit one refresh item");
}

#[test]
fn operator_cli_status_json_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("status-json");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["status", "--json"]);

    assert_eq!(json["session"]["name"], "winsmux-orchestra");
    assert_eq!(json["session"]["pane_count"], 2);
    assert_eq!(json["session"]["event_count"], 2);
    assert!(json["generated_at"].as_str().is_some());
    assert_eq!(
        json["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(json["summary"]["review_pending"], 1);
    assert_eq!(json["panes"][0]["label"], "builder-1");
    assert_eq!(json["panes"][0]["changed_files"][0], "core/src/main.rs");
}

#[test]
fn operator_cli_board_json_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("board-json");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["board", "--json"]);

    assert_eq!(json["summary"]["pane_count"], 2);
    assert!(json["generated_at"].as_str().is_some());
    assert_eq!(
        json["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(json["summary"]["dirty_panes"], 1);
    assert_eq!(json["summary"]["by_state"]["running"], 1);
    assert_eq!(json["summary"]["by_task_state"]["in_progress"], 1);
    assert_eq!(json["panes"][0]["task_id"], "TASK-266");
    assert_eq!(json["panes"][1]["role"], "Reviewer");
}

#[test]
#[cfg(windows)]
fn operator_cli_delegates_wrapper_commands_to_winsmux_core_script() {
    let project_dir = make_temp_project_dir("winsmux-core-bridge");
    let script_path = project_dir.join("winsmux-core-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("list")
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("bridge:list"),
        "unexpected stdout: {stdout}"
    );
}

#[test]
#[cfg(windows)]
fn operator_cli_forwards_namespace_flags_to_winsmux_core_script() {
    let project_dir = make_temp_project_dir("winsmux-core-namespace-bridge");
    let script_path = project_dir.join("winsmux-core-namespace-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:L=$env:WINSMUX_BRIDGE_NAMESPACE_L;S=$env:WINSMUX_BRIDGE_SOCKET_S;N=$env:WINSMUX_BRIDGE_SESSION_NAMESPACE;args=" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["-L", "ops", "-S", "socket-name", "list"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("bridge:L=ops;S=socket-name;N=socket-name;args=list"),
        "unexpected stdout: {stdout}"
    );
}

#[test]
#[cfg(windows)]
fn operator_cli_resolves_relative_socket_path_before_bridge_delegation() {
    let project_dir = make_temp_project_dir("winsmux-core-relative-socket-bridge");
    let script_path = project_dir.join("winsmux-core-relative-socket-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:S=$env:WINSMUX_BRIDGE_SOCKET_S;N=$env:WINSMUX_BRIDGE_SESSION_NAMESPACE;args=" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["-S", "mux.sock", "list"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected_socket = project_dir
        .join("mux.sock")
        .to_string_lossy()
        .replace('\\', "/")
        .to_lowercase();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(&format!("bridge:S={expected_socket};N=socket-")),
        "unexpected stdout: {stdout}"
    );
    assert!(stdout.contains(";args=list"), "unexpected stdout: {stdout}");
}

#[test]
#[cfg(windows)]
fn operator_cli_uses_socket_path_for_native_target_resolution() {
    let project_dir = make_temp_project_dir("winsmux-core-socket-target");
    let home_dir = project_dir.join("home");
    let psmux_dir = home_dir.join(".psmux");
    fs::create_dir_all(&psmux_dir).expect("test should create psmux dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "-L",
            "ops",
            "-S",
            "socket-name",
            "display-message",
            "-t",
            "winsmux-orchestra",
            "-p",
            "probe",
        ])
        .env("USERPROFILE", &home_dir)
        .env("HOME", &home_dir)
        .env_remove("PSMUX_TARGET_SESSION")
        .env_remove("PSMUX_TARGET_FULL")
        .env_remove("TMUX")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        !output.status.success(),
        "winsmux command should fail because the test only checks target resolution"
    );
    assert!(
        stderr.contains("socket-name__winsmux-orchestra"),
        "expected -S to select the socket namespace, got stderr={stderr}"
    );
    assert!(
        !stderr.contains("ops__winsmux-orchestra"),
        "expected -S to take precedence over -L, got stderr={stderr}"
    );
}

#[test]
fn operator_cli_keeps_native_operator_commands_in_rust_binary() {
    let project_dir = make_temp_project_dir("winsmux-core-native");
    write_manifest(&project_dir);
    let script_path = project_dir.join("winsmux-core-bridge.ps1");
    fs::write(
        &script_path,
        r#"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ("bridge:" + ($Rest -join "|"))
"#,
    )
    .expect("test should write fake winsmux-core script");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["board", "--json"])
        .env("WINSMUX_CORE_SCRIPT", &script_path)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("bridge:"),
        "native command unexpectedly delegated: {stdout}"
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("board output should be JSON");
    assert_eq!(json["summary"]["pane_count"], 2);
}

#[test]
fn operator_cli_board_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("board-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("board")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Label"));
    assert!(stdout.contains("TaskState"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("reviewer-1"));
    assert!(stdout.contains("in_progress"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_runs_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("runs-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("runs")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("RunId"));
    assert!(stdout.contains("ActionItems"));
    assert!(stdout.contains("task:TASK-266"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("Add Rust operator read models"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_meta_plan_json_writes_plan_artifacts_and_audit_log() {
    let project_dir = make_temp_project_dir("meta-plan-json");
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "日本語IME対応を含むメタ計画を作る",
            "--json",
        ],
    );

    assert_eq!(json["command"], "meta-plan");
    assert_eq!(json["contract_version"], 1);
    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        2
    );
    assert_eq!(json["roles"][0]["role_id"], "investigator");
    assert_eq!(json["roles"][0]["model_source"], "provider-default");
    assert_eq!(json["roles"][0]["reasoning_effort"], "provider-default");
    assert_eq!(json["roles"][0]["launch_contract"]["model_override"], false);
    assert_eq!(
        json["roles"][0]["launch_contract"]["args"][0],
        "--permission-mode"
    );
    assert_eq!(json["roles"][0]["launch_contract"]["args"][1], "plan");
    assert_eq!(json["roles"][1]["role_id"], "verifier");
    assert_eq!(json["roles"][1]["launch_contract"]["args"][2], "read-only");
    assert_eq!(json["approval_gate"]["single_user_approval"], true);
    assert_eq!(json["approval_gate"]["worker_execution_allowed"], false);
    assert_eq!(json["review_rounds"], 1);

    let plan_ref = json["integrated_plan_ref"]
        .as_str()
        .expect("integrated plan ref should be present");
    let plan_path = project_dir.join(plan_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let plan = fs::read_to_string(plan_path).expect("test should read integrated plan");
    assert!(plan.contains("Task hash:"));
    assert!(!plan.contains("日本語IME対応を含むメタ計画を作る"));
    assert!(plan.contains("## Safety And Approval Gates"));
    assert!(plan.contains("Private task and role prompt bodies are not retained"));

    let draft_ref = json["roles"][0]["draft_ref"]
        .as_str()
        .expect("draft ref should be present");
    let draft_path = project_dir.join(draft_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let draft = fs::read_to_string(draft_path).expect("test should read draft");
    assert!(draft.contains("Task hash:"));
    assert!(draft.contains("Role prompt hash:"));
    assert!(!draft.contains("日本語IME対応を含むメタ計画を作る"));
    assert!(!draft.contains("Gather facts, constraints, and unknowns. Do not edit files."));
    assert_eq!(
        json["roles"][0]["prompt_hash"]
            .as_str()
            .expect("prompt hash should be present")
            .len(),
        64
    );

    let audit_ref = json["audit_log_ref"]
        .as_str()
        .expect("audit log ref should be present");
    let audit_path = project_dir.join(audit_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let audit_raw = fs::read_to_string(audit_path).expect("test should read audit log");
    let events: Vec<serde_json::Value> = audit_raw
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("audit line should be JSON"))
        .collect();
    let event_names: Vec<&str> = events
        .iter()
        .filter_map(|event| event["event"].as_str())
        .collect();
    for expected in [
        "meta_plan_init",
        "role_assigned",
        "plan_drafted",
        "cross_review",
        "plan_merged",
        "exit_plan_mode",
    ] {
        assert!(
            event_names.contains(&expected),
            "missing audit event {expected}: {event_names:?}"
        );
    }
    let role_assigned = events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .count();
    assert_eq!(role_assigned, 2);
    assert!(events.iter().any(|event| {
        event["event"] == "meta_plan_init"
            && event["data"]["shield_harness"]["private_prompt_bodies_in_artifacts"] == false
    }));
    assert!(events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .all(|event| event["data"]["read_only"] == true));
    assert!(events
        .iter()
        .filter(|event| event["event"] == "role_assigned")
        .all(|event| event["data"]["prompt_hash"]
            .as_str()
            .map(|value| value.len() == 64)
            .unwrap_or(false)));
}

#[test]
fn operator_cli_meta_plan_roles_yaml_preserves_japanese_and_two_review_rounds() {
    let project_dir = make_temp_project_dir("meta-plan-roles-yaml");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    review_rounds: 2
    capabilities: [facts, constraints]
    prompt: |
      日本語コメントを壊さず、事実と制約を集める。
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    review_rounds: 2
    capabilities: [risk, tests]
    prompt: |
      回帰リスクと不足テストを確認する。
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    review_rounds: 2
    capabilities: [acceptance]
    prompt: |
      利用者の受け入れ条件を整理する。
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "日本語IME対応のロール計画",
            "--roles",
            &role_file_text,
            "--review-rounds",
            "2",
            "--json",
        ],
    );

    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        3
    );
    assert_eq!(json["roles"][0]["label"], "調査役");
    assert_eq!(json["roles"][2]["label"], "利用者代弁役");
    assert_eq!(json["review_rounds"], 2);
    assert!(json["role_source"]
        .as_str()
        .unwrap_or_default()
        .starts_with("yaml:roles.yaml:sha256:"));
    assert_eq!(
        json["cross_reviews"]
            .as_array()
            .expect("cross reviews should be an array")
            .len(),
        12
    );

    let draft_ref = json["roles"][0]["draft_ref"]
        .as_str()
        .expect("draft ref should be present");
    let draft_path = project_dir.join(draft_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let draft = fs::read_to_string(draft_path).expect("test should read draft");
    assert!(draft.contains("Role prompt hash:"));
    assert!(!draft.contains("日本語コメントを壊さず、事実と制約を集める。"));
    assert_eq!(
        json["roles"][0]["prompt_hash"]
            .as_str()
            .expect("prompt hash should be present")
            .len(),
        64
    );

    let audit_ref = json["audit_log_ref"]
        .as_str()
        .expect("audit log ref should be present");
    let audit_path = project_dir.join(audit_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let audit_raw = fs::read_to_string(audit_path).expect("test should read audit log");
    assert_eq!(
        audit_raw
            .lines()
            .filter(|line| line.contains("\"event\":\"cross_review\""))
            .count(),
        12
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_accepts_capability_registry_provider() {
    let project_dir = make_temp_project_dir("meta-plan-capability-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "local-research": {
      "adapter": "gemini",
      "command": "gemini-cli",
      "prompt_transports": ["file"],
      "supports_file_edit": false,
      "supports_verification": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    capabilities: [facts]
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [tests]
  - role_id: domain
    label: "領域専門役"
    provider: local-research
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [domain_research]
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "capability-driven role plan",
            "--roles",
            &role_file_text,
            "--json",
        ],
    );

    assert_eq!(
        json["roles"]
            .as_array()
            .expect("roles should be an array")
            .len(),
        3
    );
    assert_eq!(json["roles"][2]["provider"], "local-research");
    assert_eq!(json["roles"][2]["provider_adapter"], "gemini");
    assert_eq!(
        json["roles"][2]["launch_contract"]["provider_adapter"],
        "gemini"
    );
    assert_eq!(json["roles"][2]["launch_contract"]["command"], "gemini-cli");
    assert_eq!(
        json["roles"][2]["launch_contract"]["args"][0],
        "--approval-mode=plan"
    );
    assert_eq!(json["roles"][2]["launch_contract"]["model_override"], false);
    assert_eq!(
        json["roles"][2]["launch_contract"]["read_only_equivalent"],
        true
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_uses_capability_registry_for_builtin_provider() {
    let project_dir = make_temp_project_dir("meta-plan-builtin-capability-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv"],
      "supports_file_edit": true,
      "supports_verification": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    capabilities: [facts]
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [tests]
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    capabilities: [acceptance]
"#,
    )
    .expect("test should write role YAML");

    let role_file_text = role_file.to_string_lossy().to_string();
    let json = run_json(
        &project_dir,
        &[
            "meta-plan",
            "--task",
            "capability registry should override builtin command",
            "--roles",
            &role_file_text,
            "--json",
        ],
    );

    assert_eq!(json["roles"][0]["launch_contract"]["command"], "claude");
    assert_eq!(
        json["roles"][1]["launch_contract"]["command"],
        "codex-nightly"
    );
    assert_eq!(
        json["roles"][2]["launch_contract"]["command"],
        "codex-nightly"
    );
}

#[test]
fn operator_cli_meta_plan_roles_yaml_rejects_mutating_roles() {
    let project_dir = make_temp_project_dir("meta-plan-roles-yaml-reject");
    let role_file = project_dir.join("roles.yaml");
    fs::write(
        &role_file,
        r#"version: 1
roles:
  - role_id: investigator
    label: "調査役"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: false
  - role_id: verifier
    label: "検証役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
  - role_id: advocate
    label: "利用者代弁役"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
"#,
    )
    .expect("test should write role YAML");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "meta-plan",
            "--task",
            "reject mutating role",
            "--roles",
            role_file.to_str().expect("path should be utf-8"),
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        !output.status.success(),
        "meta-plan should reject mutating roles"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("must set read_only: true"), "{stderr}");
}

#[test]
fn operator_cli_explain_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("explain-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Run: task:TASK-266"));
    assert!(stdout.contains("Task: Add Rust operator read models"));
    assert!(stdout.contains("Primary: builder-1 (%2)"));
    assert!(stdout.contains("Next: commit_ready"));
    assert!(stdout.contains("Changed files:"));
    assert!(stdout.contains("- core/src/main.rs"));
    assert!(stdout.contains("Recent events:"));
    assert!(stdout.contains("operator.commit_ready"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_explain_follow_reports_matching_events() {
    let project_dir = make_temp_project_dir("explain-follow");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266", "--follow", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux follow command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else {
                break;
            };
            let _ = sender.send(line);
        }
    });

    let initial_line = receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("follow should print the initial explain payload");
    let initial: serde_json::Value =
        serde_json::from_str(initial_line.trim()).expect("initial output should be json");
    assert_eq!(initial["run"]["run_id"], "task:TASK-266");

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:10:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","message":"new evidence arrived","role":"Builder","branch":"codex/task266-rust-operator-readmodels-20260424","data":{{"next_action":"review","test_plan":"run focused test | inspect logs"}}}}"#,
            attempt + 1
        )
        .expect("test should append follow event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("follow output should be json");

    assert_eq!(item["event"], "operator.followup");
    assert_eq!(item["message"], "new evidence arrived");
    assert_eq!(
        item["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(item["test_plan"][0], "run focused test");
    assert_eq!(item["test_plan"][1], "inspect logs");
    assert_eq!(item["next_action"], "review");
}

#[test]
fn operator_cli_explain_follow_usage_includes_follow_flag() {
    let project_dir = make_temp_project_dir("explain-follow-usage");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux explain <run_id> [--json] [--follow]"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("explain")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("usage: winsmux explain <run_id> [--json] [--follow]"));
}

#[test]
fn operator_cli_inbox_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("inbox-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("inbox")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Kind"));
    assert!(stdout.contains("Message"));
    assert!(stdout.contains("review_pending"));
    assert!(stdout.contains("builder-1"));
    assert!(stdout.contains("pending"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_digest_text_reads_live_winsmux_manifest() {
    let project_dir = make_temp_project_dir("digest-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("digest")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Run: task:TASK-266"));
    assert!(stdout.contains("Primary: builder-1 (%2)"));
    assert!(stdout.contains("Task: Add Rust operator read models"));
    assert!(stdout.contains("State: in_progress / pending"));
    assert!(stdout.contains("Next: commit_ready"));
    assert!(stdout.contains("Git: codex/task266-rust-operator-readmodels-20260424 @ abc123"));
    assert!(stdout.contains("Changed files (2):"));
    assert!(stdout.contains("- core/src/operator_cli.rs"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_inbox_digest_runs_and_explain_use_ledger_projections() {
    let project_dir = make_temp_project_dir("read-models");
    write_manifest(&project_dir);

    let inbox = run_json(&project_dir, &["inbox", "--json"]);
    assert!(inbox["generated_at"].as_str().is_some());
    assert_eq!(
        inbox["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(inbox["summary"]["by_kind"]["review_pending"], 1);
    assert_eq!(inbox["items"][0]["kind"], "review_pending");

    let digest = run_json(&project_dir, &["digest", "--json"]);
    assert!(digest["generated_at"].as_str().is_some());
    assert_eq!(digest["items"][0]["run_id"], "task:TASK-266");
    assert_eq!(digest["items"][0]["review_state"], "pending");

    let desktop_summary = run_json(&project_dir, &["desktop-summary", "--json"]);
    assert!(desktop_summary["generated_at"].as_str().is_some());
    assert!(desktop_summary["board"]["generated_at"].as_str().is_some());
    assert!(desktop_summary["inbox"]["project_dir"].as_str().is_some());
    assert!(desktop_summary["digest"]["generated_at"].as_str().is_some());
    assert_eq!(desktop_summary["board"]["summary"]["pane_count"], 2);
    assert!(desktop_summary["board"]["panes"][0]
        .get("tokens_remaining")
        .is_some());
    assert!(desktop_summary["board"]["panes"][0]
        .get("task_owner")
        .is_some());
    assert!(desktop_summary["board"]["panes"][0]
        .get("event_count")
        .is_none());
    assert_eq!(desktop_summary["inbox"]["summary"]["item_count"], 2);
    assert_eq!(desktop_summary["digest"]["summary"]["item_count"], 2);
    assert_eq!(
        desktop_summary["run_projections"][0]["run_id"],
        "task:TASK-266"
    );
    assert_eq!(
        desktop_summary["run_projections"][0]["summary"],
        "Add Rust operator read models"
    );
    assert_eq!(
        desktop_summary["run_projections"][0]["next_action"],
        "commit_ready"
    );

    let runs = run_json(&project_dir, &["runs", "--json"]);
    assert_eq!(runs["summary"]["run_count"], 2);
    assert_eq!(runs["summary"]["review_pending"], 1);
    assert_eq!(runs["summary"]["dirty_runs"], 1);
    let task_run = runs["runs"]
        .as_array()
        .expect("runs should be an array")
        .iter()
        .find(|run| run["run_id"] == "task:TASK-266")
        .expect("task run should exist");
    assert_eq!(task_run["run_packet"]["priority"], "P0");
    assert_eq!(
        task_run["run_packet"]["task"],
        "Add Rust operator read models"
    );
    assert_eq!(
        task_run["run_packet"]["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(task_run["run_packet"]["labels"][0], "builder-1");
    assert_eq!(task_run["action_items"][0]["kind"], "review_pending");

    let explain = run_json(&project_dir, &["explain", "task:TASK-266", "--json"]);
    assert!(explain["generated_at"].as_str().is_some());
    assert_eq!(
        explain["project_dir"],
        project_dir.to_str().expect("temp path should be utf-8")
    );
    assert_eq!(explain["run"]["run_id"], "task:TASK-266");
    assert_eq!(
        explain["observation_pack"]["summary"],
        "captured operator read model"
    );
    assert!(explain["observation_pack"]["packet_type"].is_null());
    assert_eq!(
        explain["consultation_packet"]["recommendation"],
        "keep read-only"
    );
    assert_eq!(explain["explanation"]["next_action"], "commit_ready");
}

#[test]
fn operator_cli_desktop_summary_text_reports_counts() {
    let project_dir = make_temp_project_dir("desktop-summary-text");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Desktop summary: 2 panes, 2 inbox items, 2 digest items, 2 projections")
    );
}

#[test]
fn operator_cli_desktop_summary_stream_reports_refresh_events() {
    let project_dir = make_temp_project_dir("desktop-summary-stream");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary", "--stream", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux stream command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:00:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","pane_id":"%2","data":{{"task_id":"TASK-999"}}}}"#,
            attempt + 3
        )
        .expect("test should append event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("stream output should be json");

    assert_eq!(item["source"], "summary");
    assert_eq!(item["reason"], "operator.followup");
    assert_eq!(item["pane_id"], "%2");
    assert_eq!(item["run_id"], "task:TASK-999");
}

#[test]
fn operator_cli_desktop_summary_stream_accepts_top_level_run_fields() {
    let project_dir = make_temp_project_dir("desktop-summary-stream-top-level");
    write_manifest(&project_dir);

    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["desktop-summary", "--stream", "--json"])
        .current_dir(&project_dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("winsmux stream command should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let _child = ChildKillGuard(child);
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = sender.send(line);
    });

    let line = wait_for_stream_line(&receiver, |attempt| {
        let mut events = fs::OpenOptions::new()
            .append(true)
            .open(project_dir.join(".winsmux").join("events.jsonl"))
            .expect("test should open events file");
        use std::io::Write as _;
        writeln!(
            events,
            r#"{{"timestamp":"2026-04-24T12:00:{:02}+09:00","session":"winsmux-orchestra","event":"operator.followup","pane_id":"%2","run_id":"manual:1","task_id":"TASK-999","data":{{}}}}"#,
            attempt + 3
        )
        .expect("test should append event");
        events.flush().expect("test should flush events");
    });
    let item: serde_json::Value =
        serde_json::from_str(line.trim()).expect("stream output should be json");

    assert_eq!(item["source"], "summary");
    assert_eq!(item["reason"], "operator.followup");
    assert_eq!(item["run_id"], "manual:1");
}

#[test]
fn operator_cli_provider_capabilities_json_reads_registry() {
    let project_dir = make_temp_project_dir("provider-capabilities-json");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account"}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["local_interactive"],
      "supports_subagents": true
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "supports_parallel_runs": true
    }
  }
}"#,
    )
    .expect("test should write provider registry");

    let registry = run_json(&project_dir, &["provider-capabilities", "--json"]);

    assert_eq!(registry["version"], 1);
    let registry_path = registry["registry_path"]
        .as_str()
        .expect("registry path should be present");
    assert!(
        registry_path.ends_with(".winsmux\\provider-capabilities.json")
            || registry_path.ends_with(".winsmux/provider-capabilities.json")
    );
    assert_eq!(registry["providers"]["codex"]["adapter"], "codex");
    assert_eq!(
        registry["providers"]["codex"]["model_options"][1]["source"],
        "cli-discovery"
    );
    assert_eq!(
        registry["providers"]["codex"]["reasoning_efforts"][4],
        "xhigh"
    );
    assert_eq!(
        registry["providers"]["codex"]["local_access_note"],
        "Local Codex CLI catalog and ChatGPT account access."
    );
    assert_eq!(
        registry["providers"]["codex"]["prompt_transports"][2],
        "stdin"
    );
    assert_eq!(
        registry["providers"]["claude"]["supports_parallel_runs"],
        true
    );
}

#[test]
fn operator_cli_machine_contract_json_exposes_hook_facing_catalog() {
    let project_dir = make_temp_project_dir("machine-contract");

    let json = run_json(&project_dir, &["machine-contract", "--json"]);

    assert_eq!(json["version"], "0.24.2");
    assert_eq!(json["roles"][0]["canonical"], "operator");
    assert_eq!(json["roles"][1]["canonical"], "worker");
    assert_eq!(json["projection_surfaces"][1]["name"], "board");
    assert_eq!(json["projection_surfaces"][1]["command"], "board --json");
    assert_eq!(
        json["projection_surfaces"][4]["rust_type"],
        "LedgerRunsPayload"
    );
    assert_eq!(json["projection_surfaces"][6]["name"], "search-ledger");
    assert_eq!(
        json["projection_surfaces"][6]["command"],
        "search-ledger <search|timeline|detail> --json"
    );
    assert_eq!(
        json["review_state_file"]["path"],
        ".winsmux/review-state.json"
    );
    assert_eq!(json["event_taxonomy"][7]["group"], "security");
    assert_eq!(
        json["event_taxonomy"][7]["events"][3],
        "security.policy.blocked"
    );
    assert_eq!(
        json["verdict_fields"][1]["field"],
        "verification_result.outcome"
    );
}

#[test]
fn operator_cli_skills_json_exposes_agent_readable_contracts() {
    let project_dir = make_temp_project_dir("skills-json");

    let json = run_json(&project_dir, &["skills", "--json"]);

    assert_eq!(json["packet_type"], "progressive_skills_catalog");
    assert_eq!(json["private_skill_bodies_allowed"], false);
    assert_eq!(json["freeform_body_stored"], false);
    assert_eq!(json["skills"][0]["id"], "run-read-models");
    assert_eq!(json["skills"][0]["commands"][0], "runs --json");
    assert_eq!(
        json["skills"][1]["required_evidence"][1],
        "playbook_template_contract"
    );
    assert_eq!(json["skills"][1]["private_skill_body_stored"], false);
    assert_eq!(json["skills"][2]["review_role"], "tester");
}

#[test]
fn operator_cli_skills_help_and_command_lists_are_discoverable() {
    let project_dir = make_temp_project_dir("skills-help");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["skills", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("usage: winsmux skills"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("--help")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("skills"));
}

#[test]
fn operator_cli_skills_rejects_project_dir() {
    let project_dir = make_temp_project_dir("skills-rejects-project-dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["skills", "--json", "--project-dir"])
        .arg(project_dir.as_os_str())
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "skills should reject project-dir");
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("unknown argument for winsmux skills: --project-dir"));
}

#[test]
fn operator_cli_machine_contract_requires_json() {
    let project_dir = make_temp_project_dir("machine-contract-requires-json");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("machine-contract")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "machine-contract should fail");
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("winsmux machine-contract currently supports only --json"));
}

#[test]
fn operator_cli_machine_contract_rejects_project_dir() {
    let project_dir = make_temp_project_dir("machine-contract-rejects-project-dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["machine-contract", "--json", "--project-dir"])
        .arg(project_dir.as_os_str())
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        !output.status.success(),
        "machine-contract should reject project-dir"
    );
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("unknown argument for winsmux machine-contract: --project-dir"));
}

#[test]
fn operator_cli_rust_canary_json_reports_default_cli_gate() {
    let project_dir = make_temp_project_dir("rust-canary-default");

    let json = run_json(&project_dir, &["rust-canary", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-283");
    assert_eq!(json["target_version"], "v0.24.5");
    assert_eq!(json["phase"], "default-on-canary");
    assert_eq!(json["runtime"]["rust_cli_available"], true);
    assert_eq!(json["runtime"]["backend"], "cli");
    assert_eq!(json["runtime"]["backend_source"], "default");
    assert_eq!(json["runtime"]["tauri_backend_candidate"], false);
    assert_eq!(json["required_gates"][2], "shadow_cutover_gate");
    assert_eq!(json["blocking_conditions"][0], "invalid_WINSMUX_BACKEND");
}

#[test]
fn operator_cli_rust_canary_json_reports_tauri_candidate() {
    let project_dir = make_temp_project_dir("rust-canary-tauri");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rust-canary", "--json"])
        .env("WINSMUX_BACKEND", "desktop")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(json["runtime"]["backend"], "tauri");
    assert_eq!(json["runtime"]["backend_source"], "WINSMUX_BACKEND");
    assert_eq!(json["runtime"]["tauri_backend_candidate"], true);
}

#[test]
fn operator_cli_rust_canary_rejects_invalid_backend() {
    let project_dir = make_temp_project_dir("rust-canary-invalid");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rust-canary", "--json"])
        .env("WINSMUX_BACKEND", "remote")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "rust-canary should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("WINSMUX_BACKEND must be cli or tauri")
    );
}

#[test]
fn operator_cli_manual_checklist_json_reports_release_gate() {
    let project_dir = make_temp_project_dir("manual-checklist");

    let json = run_json(&project_dir, &["manual-checklist", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-316");
    assert_eq!(json["target_version"], "v0.24.5");
    assert_eq!(
        json["document"]["path"],
        "docs/internal/winsmux-manual-checklist-by-version.md"
    );
    assert_eq!(json["document"]["tracked"], false);
    assert_eq!(json["required_result_values"][0], "未");
    assert_eq!(json["required_result_values"][1], "合格");
    assert_eq!(json["required_result_values"][2], "不合格");
    assert_eq!(json["required_result_values"][3], "保留");
    assert_eq!(
        json["release_gates"][0],
        "version_by_version_results_recorded"
    );
    assert_eq!(json["v0_24_5_focus"][0], "legacy_alias_sunset");
    assert_eq!(
        json["blocking_conditions"][0],
        "missing_manual_checklist_document"
    );
}

#[test]
fn operator_cli_manual_checklist_text_reports_next_action() {
    let project_dir = make_temp_project_dir("manual-checklist-text");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("manual-checklist")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Manual checklist: docs/internal/winsmux-manual-checklist-by-version.md")
    );
    assert!(stdout.contains("Record v0.24.5 manual validation results"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_legacy_compat_gate_json_reports_inventory() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core manifest should have a repository parent")
        .to_path_buf();

    let json = run_json_with_cwd(&repo_root, &["legacy-compat-gate", "--json"]);

    assert_eq!(json["contract_version"], 1);
    assert_eq!(json["task_id"], "TASK-408");
    assert_eq!(json["target_version"], "v1.0.0");
    assert_eq!(
        json["inventory"]["path"],
        "docs/project/legacy-compat-surface-inventory.json"
    );
    assert_eq!(json["inventory"]["terms"][0], "psmux");
    assert_eq!(json["summary"]["passed"], true);
    assert!(json["summary"]["matched_file_count"].as_u64().unwrap() > 0);
    assert!(json["summary"]["intentional_shim_files"].as_u64().unwrap() > 0);
    assert!(json["summary"]["removal_candidate_files"].as_u64().unwrap() > 0);
    assert_eq!(json["summary"]["unclassified_count"], 0);
    assert_eq!(json["summary"]["private_reference_count"], 0);
    assert_eq!(
        json["blocking_conditions"][0],
        "unclassified_legacy_compat_surface"
    );
}

#[test]
fn operator_cli_legacy_compat_gate_rejects_private_inventory_reference() {
    let project_dir = make_temp_project_dir("legacy-compat-private-reference");
    run_git(&project_dir, &["init"]);
    fs::create_dir_all(project_dir.join("docs/project"))
        .expect("test should create docs project directory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.json"),
        r#"{
  "task": "TASK-408",
  "version": 1,
  "terms": ["psmux"],
  "allowed_classes": ["intentional-shim", "removal-candidate"],
  "target_version": "v1.0.0",
  "entries": [
    {
      "class": "intentional-shim",
      "owner": "test",
      "surface": "test",
      "reason": "test",
      "target": "test",
      "paths": ["docs/project/legacy-compat-surface-inventory.json"]
    }
  ],
  "example": "C:\\Users\\example"
}
"#,
    )
    .expect("test should write inventory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.md"),
        "# Legacy Compatibility Surface Inventory\n",
    )
    .expect("test should write inventory docs");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["legacy-compat-gate", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should contain JSON");
    assert_eq!(json["summary"]["passed"], false);
    assert_eq!(json["summary"]["private_reference_count"], 1);
    assert_eq!(
        json["private_reference_files"][0],
        "docs/project/legacy-compat-surface-inventory.json"
    );
}

#[test]
fn operator_cli_legacy_compat_gate_rejects_unclassified_reference() {
    let project_dir = make_temp_project_dir("legacy-compat-unclassified");
    run_git(&project_dir, &["init"]);
    fs::create_dir_all(project_dir.join("docs/project"))
        .expect("test should create docs project directory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.json"),
        r#"{
  "task": "TASK-408",
  "version": 1,
  "terms": ["psmux"],
  "allowed_classes": ["intentional-shim", "removal-candidate"],
  "target_version": "v1.0.0",
  "entries": [
    {
      "class": "intentional-shim",
      "owner": "test",
      "surface": "test",
      "reason": "test",
      "target": "test",
      "paths": ["docs/project/legacy-compat-surface-inventory.json"]
    }
  ]
}
"#,
    )
    .expect("test should write inventory");
    fs::write(
        project_dir.join("docs/project/legacy-compat-surface-inventory.md"),
        "# Legacy Compatibility Surface Inventory\n",
    )
    .expect("test should write inventory docs");
    fs::write(project_dir.join("untracked.txt"), "new psmux reference\n")
        .expect("test should write untracked compatibility reference");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["legacy-compat-gate", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should contain JSON");
    assert_eq!(json["summary"]["passed"], false);
    assert_eq!(json["summary"]["unclassified_count"], 1);
    assert_eq!(json["unclassified_files"][0], "untracked.txt");
}

#[test]
fn operator_cli_legacy_compat_gate_text_reports_next_action() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core manifest should have a repository parent")
        .to_path_buf();

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("legacy-compat-gate")
        .current_dir(&repo_root)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Legacy compatibility gate:"));
    assert!(stdout.contains("Before v1.0.0"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_guard_json_reports_release_guard_baseline() {
    let project_dir = make_temp_project_dir("guard-json");
    fs::create_dir_all(project_dir.join("scripts")).expect("test should create scripts dir");
    fs::write(project_dir.join("scripts").join("git-guard.ps1"), "")
        .expect("test should write git-guard script");
    fs::write(
        project_dir.join("scripts").join("audit-public-surface.ps1"),
        "",
    )
    .expect("test should write public surface audit script");
    fs::write(project_dir.join("scripts").join("gitleaks-history.ps1"), "")
        .expect("test should write gitleaks script");
    fs::write(
        project_dir
            .join("scripts")
            .join("gitleaks-history-baseline.txt"),
        "abc123\n",
    )
    .expect("test should write gitleaks baseline");
    fs::write(
        project_dir
            .join("scripts")
            .join("generate-release-notes.ps1"),
        "",
    )
    .expect("test should write release notes script");

    let json = run_json(&project_dir, &["guard", "--json"]);

    assert_eq!(json["command"], "guard");
    assert_eq!(json["task_ids"][0], "TASK-362");
    assert_eq!(json["task_ids"][1], "TASK-383");
    assert_eq!(json["task_ids"][2], "TASK-384");
    assert_eq!(json["target_version"], "v0.24.10");
    assert_eq!(json["summary"]["required_check_count"], 5);
    assert_eq!(json["summary"]["available_check_count"], 5);
    assert_eq!(
        json["observed_state"]["gitleaks_baseline_file"],
        "scripts/gitleaks-history-baseline.txt"
    );
    assert_eq!(
        json["evidence_contract"]["required_fields"][3],
        "audit_chain"
    );
    assert_eq!(
        json["public_safety"]["public_release_notes_language"],
        "English"
    );
}

#[test]
fn operator_cli_guard_text_summarizes_contract() {
    let project_dir = make_temp_project_dir("guard-text");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("guard")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Guard baseline: 5 checks for v0.24.10"));
    assert!(stdout.contains("Run the listed guard commands before release tagging"));
    assert!(!stdout.trim_start().starts_with('{'));
}

#[test]
fn operator_cli_provider_capabilities_json_reads_single_provider_case_insensitive() {
    let project_dir = make_temp_project_dir("provider-capabilities-single");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"Codex":{"adapter":" codex ","command":" codex ","prompt_transports":["ARGV"],"auth_modes":["LOCAL_INTERACTIVE"],"supports_file_edit":true,"supports_context_reset":true}}}"#,
    )
    .expect("test should write provider registry");

    let provider = run_json(&project_dir, &["provider-capabilities", "codex", "--json"]);

    assert_eq!(provider["provider_id"], "codex");
    assert_eq!(provider["capabilities"]["adapter"], "codex");
    assert_eq!(provider["capabilities"]["command"], "codex");
    assert_eq!(provider["capabilities"]["prompt_transports"][0], "argv");
    assert_eq!(
        provider["capabilities"]["auth_modes"][0],
        "local_interactive"
    );
    assert_eq!(provider["capabilities"]["supports_file_edit"], true);
    assert_eq!(provider["capabilities"]["supports_context_reset"], true);
}

#[test]
fn operator_cli_provider_capabilities_missing_provider_fails() {
    let project_dir = make_temp_project_dir("provider-capabilities-missing");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","command":"codex","prompt_transports":["argv"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "gemini", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "missing provider should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("provider capability 'gemini' was not found."),
        "stderr should explain missing provider"
    );
}

#[test]
fn operator_cli_provider_capabilities_rejects_invalid_registry_contract() {
    let project_dir = make_temp_project_dir("provider-capabilities-invalid");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","prompt_transports":["pipe"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "invalid registry should fail");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Invalid provider capability prompt transport 'pipe'.")
            || stderr.contains("Missing provider capability field 'command'."),
        "stderr should explain invalid registry contract: {stderr}"
    );
}

#[test]
fn operator_cli_provider_capabilities_rejects_blank_required_field() {
    let project_dir = make_temp_project_dir("provider-capabilities-blank-required");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{"version":1,"providers":{"codex":{"adapter":"codex","command":"   ","prompt_transports":["argv"]}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-capabilities", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "blank command should fail");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Missing provider capability field 'command'."),
        "stderr should explain missing normalized command"
    );
}

#[test]
fn operator_cli_provider_switch_writes_registry_entry() {
    let project_dir = make_temp_project_dir("provider-switch-write");
    write_provider_switch_fixture(&project_dir);

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--model-source",
            "operator-override",
            "--reasoning-effort",
            "xhigh",
            "--prompt-transport",
            "file",
            "--auth-mode",
            "claude-pro-max-oauth",
            "--reason",
            "operator requested provider switch",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "claude");
    assert_eq!(result["model"], "opus");
    assert_eq!(result["model_source"], "operator-override");
    assert_eq!(result["reasoning_effort"], "xhigh");
    assert_eq!(result["prompt_transport"], "file");
    assert_eq!(result["auth_mode"], "claude-pro-max-oauth");
    assert_eq!(result["auth_policy"], "local_interactive_only");
    assert_eq!(result["source"], "registry");
    assert_eq!(result["capability_adapter"], "claude");
    assert_eq!(result["capability_command"], "claude");
    assert_eq!(result["supports_file_edit"], true);
    assert_eq!(result["supports_subagents"], false);
    assert_eq!(result["supports_consultation"], true);
    assert_eq!(result["restart_requested"], false);
    assert_eq!(result["restarted"], false);

    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert_eq!(registry["slots"]["worker-1"]["agent"], "claude");
    assert_eq!(registry["slots"]["worker-1"]["model"], "opus");
    assert_eq!(
        registry["slots"]["worker-1"]["model_source"],
        "operator-override"
    );
    assert_eq!(registry["slots"]["worker-1"]["reasoning_effort"], "xhigh");
    assert_eq!(registry["slots"]["worker-1"]["prompt_transport"], "file");
    assert_eq!(
        registry["slots"]["worker-1"]["reason"],
        "operator requested provider switch"
    );
}

#[test]
fn operator_cli_provider_switch_rejects_blocked_auth_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-block-auth");
    write_provider_switch_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--auth-mode",
            "token-broker",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("must not broker OAuth"),
        "stderr should explain blocked auth mode"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_rejects_capability_selector_mismatch_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-capability-selector");
    write_provider_switch_fixture(&project_dir);

    let model_source_output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "codex",
            "--model",
            "gpt-5.5",
            "--model-source",
            "operator-override",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!model_source_output.status.success());
    assert!(
        String::from_utf8_lossy(&model_source_output.stderr)
            .contains("does not support model_source 'operator-override'"),
        "stderr should explain unsupported model source"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());

    let reasoning_output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "codex",
            "--reasoning-effort",
            "max",
            "--json",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!reasoning_output.status.success());
    assert!(
        String::from_utf8_lossy(&reasoning_output.stderr)
            .contains("does not support reasoning_effort 'max'"),
        "stderr should explain unsupported reasoning effort"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_validates_candidate_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-candidate-before-write");
    write_provider_switch_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-switch", "worker-1", "--agent", "claude", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Provider capability 'claude' does not support prompt_transport 'argv'"),
        "stderr should explain inherited transport mismatch"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_replaces_case_variant_registry_key() {
    let project_dir = make_temp_project_dir("provider-switch-case-key");
    write_provider_switch_fixture(&project_dir);

    let _ = run_json(
        &project_dir,
        &[
            "provider-switch",
            "WORKER-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );
    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.4",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["model"], "gpt-5.4");
    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    let slots = registry["slots"]
        .as_object()
        .expect("slots should be a map");
    assert_eq!(slots.len(), 1);
    assert!(slots.get("WORKER-1").is_none());
    assert_eq!(registry["slots"]["worker-1"]["model"], "gpt-5.4");
}

#[test]
fn operator_cli_provider_switch_clear_validates_fallback_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-clear-invalid-fallback");
    write_provider_switch_fixture(&project_dir);
    let settings = fs::read_to_string(project_dir.join(".winsmux.yaml"))
        .expect("test should read settings")
        .replace("agent: codex\n", "agent: claude\n")
        .replace("    agent: codex\n", "    agent: claude\n");
    fs::write(project_dir.join(".winsmux.yaml"), settings).expect("test should write settings");
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{"version":1,"slots":{"worker-1":{"agent":"claude","model":"opus","prompt_transport":"file","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#,
    )
    .expect("test should write provider registry");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["provider-switch", "worker-1", "--clear", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("Provider capability 'claude' does not support prompt_transport 'argv'"),
        "stderr should explain invalid fallback"
    );
    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert_eq!(registry["slots"]["worker-1"]["agent"], "claude");
    assert_eq!(registry["slots"]["worker-1"]["prompt_transport"], "file");
}

#[test]
fn operator_cli_provider_switch_clears_override() {
    let project_dir = make_temp_project_dir("provider-switch-clear");
    write_provider_switch_fixture(&project_dir);

    let _ = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--json",
        ],
    );
    let result = run_json(
        &project_dir,
        &["provider-switch", "worker-1", "--clear", "--json"],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.4");
    assert_eq!(result["prompt_transport"], "argv");
    assert_eq!(result["source"], "slot");
    assert_eq!(result["capability_adapter"], "codex");
    assert_eq!(result["supports_parallel_runs"], true);
    assert_eq!(result["supports_verification"], true);
    assert_eq!(result["supports_consultation"], false);
    assert_eq!(result["clear_requested"], true);
    assert_eq!(result["cleared"], true);

    let registry = read_json_file(&project_dir.join(".winsmux").join("provider-registry.json"));
    assert!(registry["slots"]["worker-1"].is_null());
}

#[test]
fn operator_cli_provider_switch_accepts_default_managed_slots() {
    let project_dir = make_temp_project_dir("provider-switch-default-slots");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
worker-count: 2
external-operator: true
"#,
    )
    .expect("test should write settings without explicit slots");

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-2",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-2");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.5");
    assert_eq!(result["source"], "registry");
}

#[test]
fn operator_cli_runtime_provider_default_keeps_configured_provider() {
    let project_dir = make_temp_project_dir("runtime-provider-default");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir
            .join(".winsmux")
            .join("runtime-role-preferences.json"),
        r#"{
  "version": 1,
  "roles": {
    "worker": {
      "provider": "provider-default",
      "model": "provider-default",
      "model_source": "provider-default",
      "reasoning_effort": "provider-default"
    }
  }
}"#,
    )
    .expect("test should write runtime role preferences");

    let result = run_json(
        &project_dir,
        &[
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--json",
        ],
    );

    assert_eq!(result["slot_id"], "worker-1");
    assert_eq!(result["agent"], "codex");
    assert_eq!(result["model"], "gpt-5.5");
    assert_eq!(result["source"], "registry");
}

#[test]
fn operator_cli_provider_switch_rejects_restart_stale_target_before_write() {
    let project_dir = make_temp_project_dir("provider-switch-restart-stale");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%stale"
    role: Builder
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%live"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("invalid target: %stale"),
        "stderr should explain stale pane target"
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("provider-registry.json")
        .exists());
}

#[test]
fn operator_cli_provider_switch_restart_uses_new_provider_adapter() {
    let project_dir = make_temp_project_dir("provider-switch-restart-adapter");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--agent",
            "claude",
            "--model",
            "opus",
            "--prompt-transport",
            "file",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["restarted"], true);
    assert_eq!(payload["restart_pane_id"], "%2");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"claude --model opus"));
    assert!(!log.contains("codex -c"));
}

#[test]
fn operator_cli_provider_switch_restart_skips_provider_default_model() {
    let project_dir = make_temp_project_dir("provider-switch-restart-provider-default");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "provider-default",
            "--reasoning-effort",
            "xhigh",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["model"], "provider-default");
    assert_eq!(payload["reasoning_effort"], "xhigh");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model_reasoning_effort=xhigh'"));
    assert!(!log.contains("model=provider-default"));
}

#[test]
fn operator_cli_provider_switch_restart_skips_provider_default_model_source() {
    let project_dir = make_temp_project_dir("provider-switch-restart-provider-default-source");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.4",
            "--model-source",
            "provider-default",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["model"], "gpt-5.4");
    assert_eq!(payload["model_source"], "provider-default");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex --sandbox"));
    assert!(!log.contains("model=gpt-5.4"));
}

#[test]
fn operator_cli_provider_switch_clear_restart_uses_configured_provider() {
    let project_dir = make_temp_project_dir("provider-switch-clear-restart-adapter");
    write_provider_switch_fixture(&project_dir);
    fs::write(
        project_dir.join(".winsmux").join("provider-registry.json"),
        r#"{"version":1,"slots":{"worker-1":{"agent":"claude","model":"opus","prompt_transport":"file","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#,
    )
    .expect("test should write provider registry");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    provider_target: claude:opus
    capability_adapter: claude
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--clear",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["agent"], "codex");
    assert_eq!(payload["source"], "slot");
    assert_eq!(payload["restarted"], true);
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model=gpt-5.4'"));
    assert!(!log.contains("claude --model opus"));
}

#[test]
fn operator_cli_provider_switch_restart_merges_partial_override_with_slot() {
    let project_dir = make_temp_project_dir("provider-switch-partial-restart");
    write_provider_switch_fixture(&project_dir);
    let settings = fs::read_to_string(project_dir.join(".winsmux.yaml"))
        .expect("test should read settings")
        .replace("    agent: codex\n", "    agent: claude\n")
        .replace(
            "    prompt-transport: argv\n",
            "    prompt-transport: file\n",
        );
    fs::write(project_dir.join(".winsmux.yaml"), settings).expect("test should write settings");
    fs::write(
        project_dir.join(".winsmux").join("manifest.yaml"),
        format!(
            r#"
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Builder
    launch_dir: {}
    capability_adapter: codex
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let result = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "opus",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        result.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let payload: serde_json::Value =
        serde_json::from_slice(&result.stdout).expect("stdout should be JSON");
    assert_eq!(payload["agent"], "claude");
    assert_eq!(payload["model"], "opus");
    assert_eq!(payload["source"], "registry");
    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("send-keys -t \"%2\" -l -- \"claude --model opus"));
    assert!(!log.contains("codex -c"));
}

#[test]
fn operator_cli_conflict_preflight_json_reports_clean_result() {
    let project_dir = make_temp_project_dir("conflict-preflight-clean");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "right.txt", "right\n");
    run_git(&project_dir, &["add", "right.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "right", "--json"],
    );

    assert_eq!(json["command"], "conflict-preflight");
    assert_eq!(json["status"], "clean");
    assert_eq!(json["reason"], "");
    assert_eq!(json["conflict_detected"], false);
    assert_eq!(json["left_ref"], "left");
    assert_eq!(json["right_ref"], "right");
    assert_eq!(json["merge_tree_exit_code"], 0);
    assert_eq!(json["overlap_paths"].as_array().unwrap().len(), 0);
    assert_eq!(json["left_only_paths"][0], "left.txt");
    assert_eq!(json["right_only_paths"][0], "right.txt");
}

#[test]
fn operator_cli_compare_preflight_json_uses_public_command_name() {
    let project_dir = make_temp_project_dir("compare-preflight-clean");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "right.txt", "right\n");
    run_git(&project_dir, &["add", "right.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["compare", "preflight", "left", "right", "--json"],
    );

    assert_eq!(json["command"], "compare preflight");
    assert_eq!(json["status"], "clean");
    assert_eq!(
        json["next_action"],
        "Safe to continue to compare UI or follow-up review."
    );
}

#[test]
fn operator_cli_compare_preflight_invalid_usage_reports_public_command() {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "preflight", "left-only"])
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "invalid usage should fail");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare preflight <left_ref> <right_ref> [--json]"),
        "stderr should show public usage: {stderr}"
    );
    assert!(
        !stderr.contains("conflict-preflight"),
        "public usage should not mention compatibility command: {stderr}"
    );
}

#[test]
fn operator_cli_conflict_preflight_json_reports_conflict() {
    let project_dir = make_temp_project_dir("conflict-preflight-conflict");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "shared.txt", "left\n");
    run_git(&project_dir, &["add", "shared.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "base"]);
    write_git_file(&project_dir, "shared.txt", "right\n");
    run_git(&project_dir, &["add", "shared.txt"]);
    run_git(&project_dir, &["commit", "-m", "right change"]);
    run_git(&project_dir, &["branch", "right"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "right", "--json"],
    );

    assert_eq!(json["status"], "conflict");
    assert_eq!(json["reason"], "merge_conflict");
    assert_eq!(json["conflict_detected"], true);
    assert_eq!(json["merge_tree_exit_code"], 1);
    assert_eq!(json["overlap_paths"][0], "shared.txt");
}

#[test]
fn operator_cli_conflict_preflight_json_reports_no_merge_base() {
    let project_dir = make_temp_project_dir("conflict-preflight-no-merge-base");
    init_conflict_preflight_repo(&project_dir);
    write_git_file(&project_dir, "left.txt", "left\n");
    run_git(&project_dir, &["add", "left.txt"]);
    run_git(&project_dir, &["commit", "-m", "left change"]);
    run_git(&project_dir, &["branch", "left"]);
    run_git(&project_dir, &["checkout", "--orphan", "unrelated"]);
    run_git(&project_dir, &["rm", "-rf", "."]);
    write_git_file(&project_dir, "unrelated.txt", "unrelated\n");
    run_git(&project_dir, &["add", "unrelated.txt"]);
    run_git(&project_dir, &["commit", "-m", "unrelated change"]);

    let json = run_json(
        &project_dir,
        &["conflict-preflight", "left", "unrelated", "--json"],
    );

    assert_eq!(json["status"], "blocked");
    assert_eq!(json["reason"], "no_merge_base");
    assert_eq!(json["merge_tree_exit_code"], serde_json::Value::Null);
    assert_eq!(json["conflict_detected"], false);
    assert_eq!(
        json["next_action"],
        "Choose related refs with a shared merge base and rerun winsmux conflict-preflight."
    );

    let alias_json = run_json(
        &project_dir,
        &["compare", "preflight", "left", "unrelated", "--json"],
    );
    assert_eq!(alias_json["command"], "compare preflight");
    assert_eq!(
        alias_json["next_action"],
        "Choose related refs with a shared merge base and rerun winsmux compare preflight."
    );
}

#[test]
fn operator_cli_signal_writes_temp_signal_file() {
    let project_dir = make_temp_project_dir("signal-command");
    let tmp_dir = project_dir.join("tmp");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&tmp_dir).expect("test should create tmp dir");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["signal", "desktop-ready"])
        .env("TMP", &tmp_dir)
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "sent signal: desktop-ready"
    );
    let signal_file = temp_dir
        .join("winsmux")
        .join("signals")
        .join("desktop-ready.signal");
    let signal = fs::read_to_string(signal_file).expect("signal file should exist");
    assert!(signal.contains('T'));
}

#[test]
fn operator_cli_signal_treats_leading_dash_as_channel() {
    let project_dir = make_temp_project_dir("signal-leading-dash");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["signal", "--json"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "sent signal: --json"
    );
    let signal_file = temp_dir
        .join("winsmux")
        .join("signals")
        .join("--json.signal");
    assert!(
        signal_file.exists(),
        "leading-dash channel should be literal"
    );
}

#[test]
fn operator_cli_wait_consumes_temp_signal_file() {
    let project_dir = make_temp_project_dir("wait-command");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("desktop-ready.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "desktop-ready", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: desktop-ready"
    );
    assert!(!signal_file.exists(), "wait should remove consumed signal");
}

#[test]
fn operator_cli_wait_treats_leading_dash_as_channel() {
    let project_dir = make_temp_project_dir("wait-leading-dash");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("--json.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "--json", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: --json"
    );
    assert!(
        !signal_file.exists(),
        "leading-dash channel should be literal"
    );
}

#[test]
fn operator_cli_wait_treats_dash_t_as_channel() {
    let project_dir = make_temp_project_dir("wait-dash-t");
    let temp_dir = project_dir.join("temp");
    let signal_dir = temp_dir.join("winsmux").join("signals");
    fs::create_dir_all(&signal_dir).expect("test should create signal dir");
    let signal_file = signal_dir.join("-t.signal");
    fs::write(&signal_file, "ready").expect("test should write signal file");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "-t", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "received signal: -t"
    );
    assert!(!signal_file.exists(), "-t channel should be literal");
}

#[test]
fn operator_cli_wait_signal_option_preserves_tmux_alias() {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "-S", "compat-channel"])
        .output()
        .expect("winsmux command should run");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("no server running") || output.status.success(),
        "wait -S should route to the tmux-compatible wait path: {stderr}"
    );
    assert!(
        !stderr.contains("Unknown command"),
        "wait -S must not fall through to unknown command"
    );
}

#[test]
fn operator_cli_wait_timeout_creates_signal_dir() {
    let project_dir = make_temp_project_dir("wait-creates-dir");
    let temp_dir = project_dir.join("temp");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "missing", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "wait should fail on timeout");
    assert!(
        temp_dir.join("winsmux").join("signals").exists(),
        "wait should establish the shared signal directory"
    );
}

#[test]
fn operator_cli_wait_times_out_without_signal() {
    let project_dir = make_temp_project_dir("wait-timeout");
    let temp_dir = project_dir.join("temp");
    fs::create_dir_all(&temp_dir).expect("test should create temp dir");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["wait", "missing", "0"])
        .env("TEMP", &temp_dir)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success(), "wait should fail on timeout");
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("timeout waiting for signal: missing (0s)"),
        "stderr should explain timeout: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn operator_cli_poll_events_returns_events_after_cursor() {
    let project_dir = make_temp_project_dir("poll-events");
    write_manifest(&project_dir);

    let json = run_json(&project_dir, &["poll-events", "1"]);

    assert_eq!(json["cursor"], 2);
    assert_eq!(
        json["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        1
    );
    assert_eq!(json["events"][0]["event"], "operator.commit_ready");
    assert_eq!(json["events"][0]["pane_id"], "%2");
}

#[test]
fn operator_cli_poll_events_handles_missing_file_and_cursor_bounds() {
    let project_dir = make_temp_project_dir("poll-events-empty");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");

    let missing = run_json(&project_dir, &["poll-events"]);
    assert_eq!(missing["cursor"], 0);
    assert_eq!(
        missing["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );

    fs::write(
        project_dir.join(".winsmux").join("events.jsonl"),
        r#"
{"timestamp":"2026-04-24T12:00:01+09:00","event":"one"}

{"timestamp":"2026-04-24T12:00:02+09:00","event":"two"}
"#,
    )
    .expect("test should write events");

    let past_end = run_json(&project_dir, &["poll-events", "99"]);
    assert_eq!(past_end["cursor"], 2);
    assert_eq!(
        past_end["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );

    let negative = run_json(&project_dir, &["poll-events", "-1"]);
    assert_eq!(negative["cursor"], 2);
    assert_eq!(
        negative["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        2
    );
}

#[test]
fn operator_cli_compare_runs_json_reports_evidence_delta() {
    let project_dir = make_temp_project_dir("compare-runs");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path).expect("test should read manifest");
    let manifest = manifest.replace(
        "    changed_files: '[\"core/src/operator_cli.rs\"]'",
        "    changed_files: '[\"core/src/operator_cli.rs\",\"C:\\\\Users\\\\Example\\\\secret.txt\",\"../private.md\"]'",
    );
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["left"]["run_id"], "task:task-a");
    assert_eq!(json["right"]["run_id"], "task:task-b");
    assert_eq!(json["confidence_delta"], 0.25);
    assert_eq!(json["shared_changed_files"][0], "core/src/operator_cli.rs");
    assert_eq!(json["right_only_changed_files"][0], "core/src/main.rs");
    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
    assert_eq!(json["recommend"]["reconcile_consult"], true);
    assert_eq!(
        json["recommend"]["playbook_template"]["packet_type"],
        "playbook_template_contract"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["required_evidence"][0],
        "winning_run"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["freeform_body_stored"],
        false
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["packet_type"],
        "managed_follow_up_run_contract"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_run_id"],
        "task:task-a"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["run_mode"],
        "operator_managed"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["playbook_template_ref"],
        "playbook:compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["required_evidence"][0],
        "winning_run"
    );
    let follow_up_changed_files = json["recommend"]["follow_up_run"]["changed_files"]
        .as_array()
        .expect("follow-up changed_files should be an array");
    assert_eq!(follow_up_changed_files.len(), 1);
    assert_eq!(follow_up_changed_files[0], "core/src/operator_cli.rs");
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_evidence_refs"][0],
        ".winsmux/observation-packs/task-a.json"
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["source_evidence_refs"][1],
        ".winsmux/consultations/task-a.json"
    );
    assert_eq!(json["recommend"]["follow_up_run"]["review_required"], true);
    assert_eq!(
        json["recommend"]["follow_up_run"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["recommend"]["follow_up_run"]["merge_requires_human"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["packet_type"],
        "diversity_policy_contract"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "mixed_provider"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "mixed_model"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["raw_model_prompts_stored"],
        false
    );
    assert!(
        json["recommend"]["playbook_template"]["diversity_policy"]["provider_target"].is_null()
    );
    let fields: Vec<_> = json["differences"]
        .as_array()
        .expect("differences should be array")
        .iter()
        .filter_map(|difference| difference["field"].as_str())
        .collect();
    assert!(fields.contains(&"result"));
    assert!(fields.contains(&"confidence"));
    assert!(fields.contains(&"changed_files"));
}

#[test]
fn operator_cli_compare_runs_preserves_follow_up_playbook_for_ci_paths() {
    let project_dir = make_temp_project_dir("compare-runs-ci-path-playbook");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path).expect("test should read manifest");
    let manifest = manifest.replace("core/src/operator_cli.rs", ".github/workflows/ci.yml");
    fs::write(manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "compare_winner_follow_up"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["template_refs"][0],
        "playbook:compare_winner_follow_up"
    );
}

#[test]
fn operator_cli_compare_runs_public_alias_reports_evidence_delta() {
    let project_dir = make_temp_project_dir("compare-runs-alias");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &["compare", "runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["left"]["run_id"], "task:task-a");
    assert_eq!(json["right"]["run_id"], "task:task-b");
    assert_eq!(json["confidence_delta"], 0.25);
    assert_eq!(json["recommend"]["winning_run_id"], "task:task-a");
}

#[test]
fn operator_cli_compare_runs_public_alias_reports_public_usage() {
    let project_dir = make_temp_project_dir("compare-runs-alias-usage");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "runs", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux compare runs"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "runs", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare runs"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_compare_runs_text_reports_differences() {
    let project_dir = make_temp_project_dir("compare-runs-text");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare-runs", "task:task-a", "task:task-b"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Compare: task:task-a vs task:task-b"));
    assert!(stdout.contains("Differences:"));
    assert!(stdout.contains("- result: left=cache hit right=rebuild clean"));
    assert!(stdout.contains("- changed_files: left=core/src/operator_cli.rs right=core/src/operator_cli.rs, core/src/main.rs"));
}

#[test]
fn operator_cli_compare_runs_uses_powershell_rounding() {
    let project_dir = make_temp_project_dir("compare-runs-rounding");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"confidence\":0.85", "\"confidence\":0.12345")
        .replace("\"confidence\":0.6", "\"confidence\":0.0");
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["confidence_delta"], 0.1234);
}

#[test]
fn operator_cli_compare_runs_marks_partial_provider_metadata_unknown() {
    let project_dir = make_temp_project_dir("compare-runs-partial-provider");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    provider_target: claude:opus\n", "");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let json = run_json(
        &project_dir,
        &[
            "compare-runs",
            "task:task-a",
            "task:task-b",
            "--json",
            "--project-dir",
            project_dir.to_str().unwrap(),
        ],
    );

    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["scope"],
        "run_set"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "unknown"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]
            ["provider_count_bucket"],
        "unknown"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "unknown"
    );
}

#[test]
fn operator_cli_compare_runs_emits_conflict_resolution_playbook_when_no_winner() {
    let project_dir = make_temp_project_dir("compare-runs-conflict-playbook");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"outcome\":\"PASS\"", "\"outcome\":\"FAIL\"");
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(
        &project_dir,
        &["compare-runs", "task:task-a", "task:task-b", "--json"],
    );

    assert_eq!(json["recommend"]["winning_run_id"], "");
    assert_eq!(
        json["recommend"]["playbook_template"]["flow"],
        "conflict_resolution"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["compare_run_ids"][0],
        "task:task-a"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["required_evidence"][0],
        "overlap_paths"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["scope"],
        "run_set"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "mixed_provider"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "mixed_model"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["projection"]["harness_mix"],
        "single_harness"
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["raw_provider_ids_stored"],
        false
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["recommend"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert!(json["recommend"]["follow_up_run"].is_null());
    let diversity_policy_text =
        json["recommend"]["playbook_template"]["diversity_policy"].to_string();
    assert!(!diversity_policy_text.contains("codex"));
    assert!(!diversity_policy_text.contains("claude"));
    assert!(!diversity_policy_text.contains("gpt-5.4"));
    assert!(!diversity_policy_text.contains("opus"));
}

#[test]
fn operator_cli_promote_tactic_writes_playbook_candidate() {
    let project_dir = make_temp_project_dir("promote-tactic");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "promote-tactic",
            "task:task-a",
            "--title",
            "Deterministic build command",
            "--json",
        ],
    );

    assert_eq!(json["run_id"], "task:task-a");
    assert!(json["candidate_ref"]
        .as_str()
        .expect("candidate ref should be a string")
        .starts_with(".winsmux/playbook-candidates/playbook-candidate-"));
    let candidate_path = json["candidate_path"]
        .as_str()
        .expect("candidate path should be a string");
    assert!(std::path::Path::new(candidate_path).is_file());
    let candidate_file =
        fs::read_to_string(candidate_path).expect("candidate file should be readable");
    let candidate_json: serde_json::Value =
        serde_json::from_str(&candidate_file).expect("candidate file should be JSON");
    assert_eq!(candidate_json["packet_type"], "playbook_candidate");
    assert_eq!(candidate_json["kind"], "playbook");
    assert!(candidate_json["generated_at"].as_str().is_some());
    assert_eq!(candidate_json["title"], "Deterministic build command");
    assert_eq!(candidate_json["summary"], "prefer cache command");
    assert_eq!(json["candidate"]["packet_type"], "playbook_candidate");
    assert_eq!(json["candidate"]["kind"], "playbook");
    assert_eq!(json["candidate"]["title"], "Deterministic build command");
    assert_eq!(json["candidate"]["summary"], "prefer cache command");
    assert_eq!(json["candidate"]["hypothesis"], "cache command is stable");
    assert_eq!(
        json["candidate"]["changed_files"][0],
        "core/src/operator_cli.rs"
    );
    assert_eq!(
        json["candidate"]["observation_pack_ref"],
        ".winsmux/observation-packs/task-a.json"
    );
    assert_eq!(
        json["candidate"]["consultation_ref"],
        ".winsmux/consultations/task-a.json"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["packet_type"],
        "playbook_template_contract"
    );
    assert_eq!(json["candidate"]["playbook_template"]["flow"], "bugfix");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "reproduction"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["team_memory_refs"][0],
        "team-memory:task-a:operator-standard"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["execution_backend"],
        "operator_managed"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["freeform_body_stored"],
        false
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["review_required"],
        true
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["human_approval_required"],
        true
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["auto_merge_allowed"],
        false
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["approval_defaults"]["merge_requires_human"],
        true
    );
    assert!(json["candidate"]["playbook_template"]["freeform_body"].is_null());
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["packet_type"],
        "diversity_policy_contract"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["projection"]["provider_mix"],
        "single_provider"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["projection"]["model_mix"],
        "single_model"
    );
    assert_eq!(
        json["candidate"]["playbook_template"]["diversity_policy"]["metadata_policy"]
            ["private_prompt_bodies_stored"],
        false
    );
    let diversity_policy_text =
        json["candidate"]["playbook_template"]["diversity_policy"].to_string();
    assert!(!diversity_policy_text.contains("codex"));
    assert!(!diversity_policy_text.contains("gpt-5.4"));
}

#[test]
fn operator_cli_compare_promote_alias_writes_playbook_candidate() {
    let project_dir = make_temp_project_dir("compare-promote-alias");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "compare",
            "promote",
            "task:task-a",
            "--title",
            "Deterministic build command",
            "--json",
        ],
    );

    assert_eq!(json["run_id"], "task:task-a");
    assert!(json["candidate_ref"]
        .as_str()
        .expect("candidate ref should be a string")
        .starts_with(".winsmux/playbook-candidates/playbook-candidate-"));
    assert_eq!(json["candidate"]["packet_type"], "playbook_candidate");
    assert_eq!(json["candidate"]["kind"], "playbook");
    assert_eq!(json["candidate"]["title"], "Deterministic build command");
    assert_eq!(json["candidate"]["summary"], "prefer cache command");
}

#[test]
fn operator_cli_promote_tactic_verification_kind_uses_ci_playbook() {
    let project_dir = make_temp_project_dir("promote-tactic-verification-playbook");
    write_compare_runs_fixture(&project_dir);

    let json = run_json(
        &project_dir,
        &[
            "promote-tactic",
            "task:task-a",
            "--kind",
            "verification",
            "--json",
        ],
    );

    assert_eq!(json["candidate"]["kind"], "verification");
    assert_eq!(json["candidate"]["playbook_template"]["flow"], "ci");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "workflow_status"
    );
}

#[test]
fn operator_cli_promote_tactic_review_next_action_uses_review_playbook() {
    let project_dir = make_temp_project_dir("promote-tactic-review-playbook");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace(
            "\"next_action\":\"promote tactic\"",
            "\"next_action\":\"review findings\"",
        );
    fs::write(events_path, events).expect("test should write events");

    let json = run_json(&project_dir, &["promote-tactic", "task:task-a", "--json"]);

    assert_eq!(json["candidate"]["playbook_template"]["flow"], "review");
    assert_eq!(
        json["candidate"]["playbook_template"]["required_evidence"][0],
        "findings"
    );
}

#[test]
fn operator_cli_compare_promote_alias_reports_public_usage() {
    let project_dir = make_temp_project_dir("compare-promote-alias-usage");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "promote", "--help"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("usage: winsmux compare promote"));

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare", "promote"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare promote"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_promote_tactic_rejects_unhealthy_run() {
    let project_dir = make_temp_project_dir("promote-tactic-unhealthy");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace("\"outcome\":\"PASS\"", "\"outcome\":\"FAIL\"");
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_missing_security_clearance() {
    let project_dir = make_temp_project_dir("promote-tactic-no-security");
    write_compare_runs_fixture(&project_dir);
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .lines()
        .filter(|line| !line.contains("\"event\":\"pipeline.security.allowed\""))
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_unreviewed_architecture_drift() {
    let project_dir = make_temp_project_dir("promote-tactic-architecture-drift");
    write_compare_runs_fixture(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replacen("    review_state: PASS", "    review_state: ", 1);
    fs::write(manifest_path, manifest).expect("test should write manifest");
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let events = fs::read_to_string(&events_path)
        .expect("test should read events")
        .replace(
            "verification passed",
            "architecture drift detected after verification",
        );
    fs::write(events_path, events).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("run is not promotable: task:task-a"));
}

#[test]
fn operator_cli_promote_tactic_rejects_unknown_kind() {
    let project_dir = make_temp_project_dir("promote-tactic-kind");
    write_compare_runs_fixture(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["promote-tactic", "task:task-a", "--kind", "unknown"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Unsupported promote kind: unknown"));
}

#[test]
fn operator_cli_consult_error_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-error");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-error",
            "stuck",
            "--message",
            "Reviewer context is missing",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("consult error recorded for operator:session-1"));

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation error"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_error");
    assert_eq!(last_event["message"], "Reviewer context is missing");
    let consultation_ref = last_event["data"]["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-error-"));

    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_error");
    assert_eq!(packet["mode"], "stuck");
    assert_eq!(packet["error"], "Reviewer context is missing");
    assert!(packet["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:stuck"));
    assert!(packet["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .contains("builder-1"));
    assert_eq!(
        packet["governance_cost_units"][0]["unit_id"],
        packet["cost_unit_refs"][0]
    );
    assert!(packet.get("recommendation").is_none());
    assert!(last_event["data"].get("result").is_none());
    assert_eq!(
        last_event["data"]["cost_unit_refs"],
        packet["cost_unit_refs"]
    );
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        packet["cost_unit_refs"][0]
    );

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.error");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_request_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-request");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-request",
            "early",
            "--message",
            "Please review the Rust port",
            "--target-slot",
            "reviewer-1",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("consult request recorded for operator:session-1"));

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation request"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_request");
    assert_eq!(last_event["message"], "Please review the Rust port");
    let consultation_ref = last_event["data"]["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-request-"));
    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_request");
    assert_eq!(packet["mode"], "early");
    assert_eq!(packet["request"], "Please review the Rust port");
    assert!(packet.get("recommendation").is_none());
    assert_eq!(
        packet["governance_cost_units"][0]["unit_type"],
        "governance_invocation"
    );
    assert_eq!(packet["governance_cost_units"][0]["kind"], "consult");
    assert_eq!(packet["governance_cost_units"][0]["mode"], "early");

    assert_eq!(last_event["data"]["consultation_ref"], consultation_ref);
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        packet["governance_cost_units"][0]["unit_id"]
    );
    assert!(last_event["data"].get("result").is_none());

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.request");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_result_records_packet_event_and_manifest() {
    let project_dir = make_temp_project_dir("consult-result");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Builder\n", "    role: Worker\n");
    fs::write(&manifest_path, manifest).expect("test should write manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-result",
            "final",
            "--message",
            "Ship the Rust command",
            "--confidence",
            "0.82",
            "--next-test",
            "cargo test --manifest-path core/Cargo.toml --test operator_cli",
            "--risk",
            "manifest update could drift",
            "--json",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(json["run_id"], "operator:session-1");
    assert_eq!(json["task_id"], "TASK-266");
    assert_eq!(json["pane_id"], "%2");
    assert_eq!(json["slot"], "builder-1");
    assert_eq!(json["kind"], "consult_result");
    assert_eq!(json["mode"], "final");
    assert_eq!(json["recommendation"], "Ship the Rust command");
    assert_eq!(json["confidence"], 0.82);
    assert_eq!(
        json["next_test"],
        "cargo test --manifest-path core/Cargo.toml --test operator_cli"
    );
    assert_eq!(json["risks"][0], "manifest update could drift");
    assert!(json["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:final"));
    assert!(json["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .contains("builder-1"));
    let consultation_ref = json["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    assert!(consultation_ref.starts_with(".winsmux/consultations/consult-result-"));

    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["packet_type"], "consultation_packet");
    assert_eq!(packet["kind"], "consult_result");
    assert_eq!(packet["mode"], "final");
    assert_eq!(packet["recommendation"], "Ship the Rust command");
    assert_eq!(packet["next_test"], json["next_test"]);
    assert_eq!(packet["risks"][0], "manifest update could drift");
    assert_eq!(packet["cost_unit_refs"], json["cost_unit_refs"]);
    assert_eq!(
        packet["governance_cost_units"][0]["unit_id"],
        json["cost_unit_refs"][0]
    );

    let events = fs::read_to_string(project_dir.join(".winsmux").join("events.jsonl"))
        .expect("events should be readable");
    let last_event: serde_json::Value = serde_json::from_str(
        events
            .lines()
            .filter(|line| !line.trim().is_empty())
            .last()
            .expect("events should contain a consultation result"),
    )
    .expect("event should be JSON");
    assert_eq!(last_event["event"], "pane.consult_result");
    assert_eq!(last_event["message"], "Ship the Rust command");
    assert_eq!(
        last_event["data"]["governance_cost_units"][0]["unit_id"],
        json["cost_unit_refs"][0]
    );
    assert_eq!(last_event["data"]["result"], "Ship the Rust command");
    assert_eq!(last_event["data"]["confidence"], 0.82);
    assert_eq!(last_event["data"]["next_action"], json["next_test"]);
    assert_eq!(last_event["data"]["consultation_ref"], consultation_ref);
    assert_eq!(last_event["data"]["cost_unit_refs"], json["cost_unit_refs"]);

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["last_event"], "consult.result");
    assert!(builder["last_event_at"].as_str().is_some());
}

#[test]
fn operator_cli_consult_result_accepts_run_override() {
    let project_dir = make_temp_project_dir("consult-result-run");
    write_manifest(&project_dir);

    let json = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-result",
            "reconcile",
            "--message",
            "Use the existing review state",
            "--target-slot",
            "reviewer-1",
            "--run-id",
            "task:TASK-266",
            "--json",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");

    assert!(
        json.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&json.stderr)
    );
    let result: serde_json::Value =
        serde_json::from_slice(&json.stdout).expect("stdout should be JSON");
    assert_eq!(result["run_id"], "task:TASK-266");
    assert_eq!(result["mode"], "reconcile");
    assert_eq!(result["target_slot"], "reviewer-1");
    assert_eq!(result["recommendation"], "Use the existing review state");
    assert!(result["confidence"].is_null());
    assert!(result["cost_unit_refs"][0]
        .as_str()
        .expect("cost unit ref should be a string")
        .starts_with("governance:consult:reconcile"));

    let consultation_ref = result["consultation_ref"]
        .as_str()
        .expect("consultation_ref should be a string");
    let packet_path =
        project_dir.join(consultation_ref.replace('/', std::path::MAIN_SEPARATOR_STR));
    let packet: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(packet_path).expect("packet should be readable"))
            .expect("packet should be JSON");
    assert_eq!(packet["confidence"], 0.0);
    assert_eq!(packet["next_test"], "");
    assert_eq!(
        packet["risks"]
            .as_array()
            .expect("risks should be an array")
            .len(),
        0
    );

    let explain = run_json(&project_dir, &["explain", "task:TASK-266", "--json"]);
    assert_eq!(
        explain["consultation_packet"]["recommendation"],
        "Use the existing review state"
    );
    assert_eq!(explain["consultation_packet"]["confidence"], 0.0);
    assert_eq!(explain["consultation_packet"]["next_test"], "");
    assert_eq!(
        explain["consultation_packet"]["risks"]
            .as_array()
            .expect("risks should be an array")
            .len(),
        0
    );
}

#[test]
fn operator_cli_consult_result_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-result-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-result", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let missing_message = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-result", "final"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!missing_message.status.success());
    assert!(
        String::from_utf8_lossy(&missing_message.stderr).contains("consult message is required")
    );
}

#[test]
fn operator_cli_consult_request_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-request-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let ignored_options = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-request",
            "early",
            "--message",
            "compat",
            "--json",
            "--run-id",
            "run-1",
            "--confidence",
            "0.5",
            "--next-test",
            "ignored",
            "--risk",
            "ignored",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(
        ignored_options.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&ignored_options.stderr)
    );

    let unknown_option = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "early", "--unknown", "value"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!unknown_option.status.success());
    assert!(String::from_utf8_lossy(&unknown_option.stderr)
        .contains("unknown argument for winsmux consult-request"));

    let bad_confidence = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-request", "early", "--confidence", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_confidence.status.success());
    assert!(
        String::from_utf8_lossy(&bad_confidence.stderr).contains("Invalid confidence value: nope")
    );
}

#[test]
fn operator_cli_consult_error_rejects_invalid_input() {
    let project_dir = make_temp_project_dir("consult-error-invalid");
    write_manifest(&project_dir);

    let bad_mode = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "later", "--message", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_mode.status.success());
    assert!(String::from_utf8_lossy(&bad_mode.stderr).contains("Unsupported consult mode"));

    let ignored_options = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "consult-error",
            "early",
            "--message",
            "compat",
            "--json",
            "--run-id",
            "run-1",
            "--confidence",
            "0.5",
            "--next-test",
            "ignored",
            "--risk",
            "ignored",
        ])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(
        ignored_options.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&ignored_options.stderr)
    );

    let unknown_option = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--unknown", "value"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!unknown_option.status.success());
    assert!(String::from_utf8_lossy(&unknown_option.stderr)
        .contains("unknown argument for winsmux consult-error"));

    let bad_confidence = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--confidence", "nope"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!bad_confidence.status.success());
    assert!(
        String::from_utf8_lossy(&bad_confidence.stderr).contains("Invalid confidence value: nope")
    );

    let missing_run_id = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["consult-error", "early", "--run-id"])
        .current_dir(&project_dir)
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Builder")
        .output()
        .expect("winsmux command should run");
    assert!(!missing_run_id.status.success());
    assert!(String::from_utf8_lossy(&missing_run_id.stderr).contains("--run-id requires a value"));
}

#[test]
fn operator_cli_accepts_project_dir_argument() {
    let project_dir = make_temp_project_dir("project-dir");
    write_manifest(&project_dir);

    let json = run_json_with_cwd(
        std::env::temp_dir(),
        &[
            "board",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );

    assert_eq!(json["summary"]["pane_count"], 2);
}

#[test]
fn operator_cli_rejects_unknown_and_extra_arguments() {
    let project_dir = make_temp_project_dir("invalid-args");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["board", "--json", "--bogus"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("unknown argument"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["explain", "task:TASK-266", "extra", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux explain"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["inbox", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux inbox [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["digest", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux digest [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["runs", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux runs [--json]"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["review-reset", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux review-reset"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["review-request", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux review-request"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "--json"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux restart"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux restart"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "1", "extra"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "not-a-number"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["poll-events", "2147483648"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["compare-runs", "task:a"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux compare-runs"),
        "unexpected stderr: {stderr}"
    );

    for command in ["review-approve", "review-fail"] {
        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .args([command, "--json"])
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(&format!("usage: winsmux {command}")),
            "unexpected stderr for {command}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_request_records_pending_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-request");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "other-branch": {
    "status": "PASS",
    "branch": "other-branch",
    "head_sha": "def456"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(
            "review request recorded for codex/task266-rust-operator-readmodels-20260424"
        ),
        "unexpected stdout: {stdout}"
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    assert!(state.get("other-branch").is_some());
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "PENDING");
    assert_eq!(
        record["branch"],
        "codex/task266-rust-operator-readmodels-20260424"
    );
    assert_eq!(
        record["head_sha"],
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    );
    assert!(record["request"]["id"]
        .as_str()
        .expect("request id should be a string")
        .starts_with("review-"));
    assert_eq!(record["request"]["target_review_pane_id"], "%3");
    assert_eq!(record["request"]["target_review_label"], "reviewer-1");
    assert_eq!(record["request"]["target_review_role"], "Reviewer");
    assert_eq!(record["request"]["target_reviewer_pane_id"], "%3");
    assert_eq!(record["request"]["review_contract"]["version"], 1);
    assert_eq!(
        record["request"]["review_contract"]["required_scope"][0],
        "design_impact"
    );
    assert_eq!(
        record["request"]["review_contract"]["required_scope"][3],
        "pathspec_completeness"
    );
    assert_eq!(
        record["request"]["review_contract"]["pathspec_policy"]["include_definition_hosts"],
        true
    );
    assert!(record["request"]["dispatched_at"].as_str().is_some());
    assert_eq!(record["reviewer"]["agent_name"], "codex");
    assert!(record["updatedAt"].as_str().is_some());

    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    let reviewer = panes
        .get(&serde_yaml::Value::String("reviewer-1".to_string()))
        .expect("reviewer-1 should exist");
    assert_eq!(reviewer["review_state"].as_str(), Some("pending"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Reviewer"));
    assert_eq!(
        reviewer["branch"].as_str(),
        Some("codex/task266-rust-operator-readmodels-20260424")
    );
    assert_eq!(
        reviewer["head_sha"].as_str(),
        Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    );
    assert_eq!(reviewer["last_event"].as_str(), Some("review.requested"));
}

#[test]
fn operator_cli_dispatch_review_sends_review_request_to_preferred_pane() {
    let project_dir = make_temp_project_dir("dispatch-review");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}"#,
    );
    let (winsmux_bin, log_path) = write_fake_winsmux_dispatch_review(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_BIN", winsmux_bin)
        .env("WINSMUX_PANE_ID", "%1")
        .env("WINSMUX_ROLE", "Operator")
        .env("WINSMUX_ROLE_MAP", r#"{"%1":"Operator"}"#)
        .env("WINSMUX_DISPATCH_REVIEW_POLL_ATTEMPTS", "0")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Dispatching review to reviewer-1 [%3]"),
        "unexpected stdout: {stdout}"
    );
    assert!(
        stdout.contains("PENDING confirmed. Reviewer pane will run review-approve or review-fail."),
        "unexpected stdout: {stdout}"
    );

    let log = fs::read_to_string(log_path).expect("test should read fake winsmux log");
    assert!(
        log.contains("send-keys") && log.contains("%3") && log.contains("winsmux review-request"),
        "unexpected fake winsmux log: {log}"
    );
    assert!(
        log.contains("send-keys") && log.contains("%3") && log.contains("Enter"),
        "unexpected fake winsmux log: {log}"
    );
}

#[test]
fn operator_cli_dispatch_review_rejects_stale_pending_review_state() {
    let project_dir = make_temp_project_dir("dispatch-review-stale");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}"#,
    );
    let (winsmux_bin, _log_path) = write_fake_winsmux_dispatch_review(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_BIN", winsmux_bin)
        .env("WINSMUX_PANE_ID", "%1")
        .env("WINSMUX_ROLE", "Operator")
        .env("WINSMUX_ROLE_MAP", r#"{"%1":"Operator"}"#)
        .env("WINSMUX_DISPATCH_REVIEW_POLL_ATTEMPTS", "0")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("review-request was not recorded after 0 attempts"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_dispatch_review_rejects_non_operator_role() {
    let project_dir = make_temp_project_dir("dispatch-review-role");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("dispatch-review")
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Worker"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("dispatch-review is not permitted for the current role"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_rejects_non_review_capable_pane() {
    let project_dir = make_temp_project_dir("review-request-builder");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%2")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%2":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("is not registered as a review-capable pane"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_rejects_role_gate_mismatch() {
    let project_dir = make_temp_project_dir("review-request-role-mismatch");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Worker")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("WINSMUX_ROLE mismatch for pane %3: expected Reviewer, got Worker"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_request_accepts_label_derived_reviewer_role() {
    let project_dir = make_temp_project_dir("review-request-label-role");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace("    role: Reviewer\n", "");
    fs::write(&manifest_path, manifest).expect("test should write manifest");
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["request"]["target_review_role"], "Reviewer");
}

#[test]
fn operator_cli_review_request_generates_distinct_request_ids() {
    let project_dir = make_temp_project_dir("review-request-distinct-id");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    let first = run_review_request_and_read_id(&project_dir);
    let second = run_review_request_and_read_id(&project_dir);

    assert_ne!(first, second);
}

#[test]
fn operator_cli_review_approve_records_pass_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-approve");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    run_review_request_and_read_id(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-approve")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review PASS recorded for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state = read_review_state(&project_dir);
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "PASS");
    assert_eq!(
        record["head_sha"],
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    );
    assert_eq!(record["reviewer"]["pane_id"], "%3");
    assert_eq!(record["reviewer"]["agent_name"], "codex");
    assert!(record["evidence"]["approved_at"].as_str().is_some());
    assert_eq!(record["evidence"]["approved_via"], "winsmux review-approve");
    assert_eq!(
        record["evidence"]["review_contract_snapshot"]["required_scope"][0],
        "design_impact"
    );

    let reviewer = read_manifest_pane(&project_dir, "reviewer-1");
    assert_eq!(reviewer["review_state"].as_str(), Some("pass"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Operator"));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.pass"));
}

#[test]
fn operator_cli_review_fail_records_fail_state_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-fail");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    run_review_request_and_read_id(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-fail")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .env("WINSMUX_AGENT_NAME", "codex")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review FAIL recorded for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state = read_review_state(&project_dir);
    let record = &state["codex/task266-rust-operator-readmodels-20260424"];
    assert_eq!(record["status"], "FAIL");
    assert!(record["evidence"]["failed_at"].as_str().is_some());
    assert_eq!(record["evidence"]["failed_via"], "winsmux review-fail");

    let reviewer = read_manifest_pane(&project_dir, "reviewer-1");
    assert_eq!(reviewer["review_state"].as_str(), Some("fail"));
    assert_eq!(reviewer["task_owner"].as_str(), Some("Operator"));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.fail"));
}

#[test]
fn operator_cli_review_result_requires_pending_request() {
    for command in ["review-approve", "review-fail"] {
        let project_dir = make_temp_project_dir(command);
        write_manifest(&project_dir);
        init_git_branch(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
        );
        set_git_head(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .arg(command)
            .env("WINSMUX_PANE_ID", "%3")
            .env("WINSMUX_ROLE", "Reviewer")
            .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("review request pending for codex/task266-rust-operator-readmodels-20260424 was not found"),
            "unexpected stderr for {command}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_result_requires_review_contract() {
    let project_dir = make_temp_project_dir("review-result-contract");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    set_git_head(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "target_review_pane_id": "%3"
    }
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-approve")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("is missing review_contract"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_review_result_rejects_pane_and_head_mismatch() {
    let cases = [
        (
            "review-result-pane-mismatch",
            r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "target_review_pane_id": "%9",
      "review_contract": {"required_scope":["design_impact"]}
    }
  }
}"#,
            "is assigned to %9, not %3",
        ),
        (
            "review-result-head-mismatch",
            r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PENDING",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "request": {
      "branch": "codex/task266-rust-operator-readmodels-20260424",
      "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "target_review_pane_id": "%3",
      "review_contract": {"required_scope":["design_impact"]}
    }
  }
}"#,
            "pending review request head mismatch",
        ),
    ];

    for (name, state, expected) in cases {
        let project_dir = make_temp_project_dir(name);
        write_manifest(&project_dir);
        init_git_branch(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
        );
        set_git_head(
            &project_dir,
            "codex/task266-rust-operator-readmodels-20260424",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        write_review_state(&project_dir, state);

        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .arg("review-approve")
            .env("WINSMUX_PANE_ID", "%3")
            .env("WINSMUX_ROLE", "Reviewer")
            .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(expected),
            "unexpected stderr for {name}: {stderr}"
        );
    }
}

#[test]
fn operator_cli_review_reset_clears_current_branch_and_manifest_pane() {
    let project_dir = make_temp_project_dir("review-reset");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PASS",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "abc123"
  },
  "other-branch": {
    "status": "PENDING",
    "branch": "other-branch",
    "head_sha": "def456"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-reset")
        .env("WINSMUX_PANE_ID", "%3")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("review PASS cleared for codex/task266-rust-operator-readmodels-20260424"),
        "unexpected stdout: {stdout}"
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should remain"))
            .expect("review state should be JSON");
    assert!(state
        .get("codex/task266-rust-operator-readmodels-20260424")
        .is_none());
    assert!(state.get("other-branch").is_some());

    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    let builder = panes
        .get(&serde_yaml::Value::String("builder-1".to_string()))
        .expect("builder-1 should exist");
    assert_eq!(builder["review_state"].as_str(), Some("pending"));
    assert_eq!(
        builder["branch"].as_str(),
        Some("codex/task266-rust-operator-readmodels-20260424")
    );
    assert_eq!(builder["head_sha"].as_str(), Some("abc123"));
    let reviewer = panes
        .get(&serde_yaml::Value::String("reviewer-1".to_string()))
        .expect("reviewer-1 should exist");
    assert_eq!(reviewer["review_state"].as_str(), Some(""));
    assert_eq!(reviewer["branch"].as_str(), Some(""));
    assert_eq!(reviewer["head_sha"].as_str(), Some(""));
    assert_eq!(reviewer["last_event"].as_str(), Some("review.reset"));
}

#[test]
fn operator_cli_review_reset_removes_empty_review_state_file() {
    let project_dir = make_temp_project_dir("review-reset-empty");
    write_manifest(&project_dir);
    init_git_branch(
        &project_dir,
        "codex/task266-rust-operator-readmodels-20260424",
    );
    write_review_state(
        &project_dir,
        r#"{
  "codex/task266-rust-operator-readmodels-20260424": {
    "status": "PASS",
    "branch": "codex/task266-rust-operator-readmodels-20260424",
    "head_sha": "abc123"
  }
}"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-reset")
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("review-state.json")
        .exists());
}

#[test]
fn operator_cli_rebind_worktree_updates_builder_paths() {
    let project_dir = make_temp_project_dir("rebind-worktree");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected_path = std::fs::canonicalize(&new_worktree)
        .expect("test should canonicalize path")
        .to_string_lossy()
        .to_string();
    let expected_path = strip_windows_extended_path_prefix(&expected_path);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(&format!("rebound %2 (builder-1) to {expected_path}")),
        "unexpected stdout: {stdout}"
    );

    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(builder["launch_dir"].as_str(), Some(expected_path.as_str()));
    assert_eq!(
        builder["builder_worktree_path"].as_str(),
        Some(expected_path.as_str())
    );
    assert!(!project_dir
        .join(".winsmux")
        .join("manifest.yaml.lock")
        .exists());
}

#[test]
fn operator_cli_rebind_worktree_rejects_reviewer_and_missing_path() {
    let project_dir = make_temp_project_dir("rebind-worktree-reject");
    write_manifest(&project_dir);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rebind-worktree", "reviewer-1", "."])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("rebind-worktree is only supported for Builder/Worker panes"),
        "unexpected stderr: {stderr}"
    );

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["rebind-worktree", "builder-1", "missing-worktree"])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("worktree path not found: missing-worktree"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_rebind_worktree_rejects_stale_manifest_target() {
    let project_dir = make_temp_project_dir("rebind-worktree-stale");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin =
        write_fake_winsmux_list_panes(&project_dir, Some("winsmux-orchestra"), &["%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_rebind_worktree_validates_target_in_manifest_session() {
    let project_dir = make_temp_project_dir("rebind-worktree-session");
    write_manifest(&project_dir);
    let new_worktree = project_dir.join(".worktrees").join("builder-9");
    fs::create_dir_all(&new_worktree).expect("test should create new worktree");
    let winsmux_bin = write_fake_winsmux_list_panes(&project_dir, Some("other-session"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "rebind-worktree",
            "builder-1",
            new_worktree.to_str().expect("temp path should be utf-8"),
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_restart_dispatches_launch_plan_and_updates_manifest() {
    let project_dir = make_temp_project_dir("restart");
    write_manifest(&project_dir);
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path)
        .expect("test should read manifest")
        .replace(
            "    provider_target: codex:gpt-5.4\n",
            "    provider_target: codex:gpt 5.4;unsafe\n",
        );
    fs::write(&manifest_path, manifest).expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2", "%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("restarted %2 (builder-1)"),
        "unexpected stdout: {stdout}"
    );

    let log = fs::read_to_string(&log_path).expect("fake winsmux log should exist");
    assert!(log.contains("respawn-pane -k -t \"%2\" -c"));
    assert!(log.contains("send-keys -t \"%2\" -l -- \"codex -c 'model=gpt 5.4;unsafe'"));
    assert!(log.contains("send-keys -t \"%2\" Enter"));
    let builder = read_manifest_pane(&project_dir, "builder-1");
    assert_eq!(
        builder["provider_target"].as_str(),
        Some("codex:gpt 5.4;unsafe")
    );
    assert_eq!(builder["capability_adapter"].as_str(), Some("codex"));
}

#[test]
fn operator_cli_restart_rejects_stale_manifest_target() {
    let project_dir = make_temp_project_dir("restart-stale");
    write_manifest(&project_dir);
    let (winsmux_bin, _log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%3"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "builder-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("invalid target: %2"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn operator_cli_restart_rejects_missing_provider_metadata() {
    let project_dir = make_temp_project_dir("restart-missing-provider-metadata");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(["restart", "worker-1"])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("restart provider metadata missing"),
        "unexpected stderr: {stderr}"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart should not dispatch a fallback command: {log}"
    );
    assert!(
        !winsmux_dir.join("provider-registry.json").exists(),
        "failed restart validation must not persist a partial provider override"
    );
}

#[test]
fn operator_cli_provider_switch_restart_rejects_partial_override_without_provider() {
    let project_dir = make_temp_project_dir("provider-switch-restart-missing-provider");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        format!(
            r#"
version: 1
session:
  name: winsmux-orchestra
  project_dir: {}
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    launch_dir: {}
"#,
            project_dir.display(),
            project_dir.display()
        ),
    )
    .expect("test should write manifest");
    let registry_path = winsmux_dir.join("provider-registry.json");
    let registry_before = r#"{"version":1,"slots":{"worker-9":{"agent":"claude","model":"opus","prompt_transport":"file","auth_mode":"claude-pro-max-oauth","reason":"keep existing override","updated_at_utc":"2026-04-26T00:00:00Z"}}}"#;
    fs::write(&registry_path, registry_before).expect("test should write provider registry");
    let (winsmux_bin, log_path) =
        write_fake_winsmux_restart(&project_dir, Some("winsmux-orchestra"), &["%2"]);

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "provider-switch",
            "worker-1",
            "--model",
            "gpt-5.5",
            "--model-source",
            "cli-discovery",
            "--restart",
            "--json",
        ])
        .env("WINSMUX_BIN", winsmux_bin)
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("restart provider metadata missing"),
        "unexpected stderr: {stderr}"
    );
    let log = fs::read_to_string(&log_path).unwrap_or_default();
    assert!(
        !log.contains("send-keys"),
        "restart should not dispatch a fallback command: {log}"
    );
    let registry_after =
        fs::read_to_string(&registry_path).expect("test should read provider registry");
    assert_eq!(
        registry_after, registry_before,
        "failed provider-switch restart validation must not mutate the provider registry"
    );
}

fn run_review_request_and_read_id(project_dir: &std::path::Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .arg("review-request")
        .env("WINSMUX_PANE_ID", "%3")
        .env("WINSMUX_ROLE", "Reviewer")
        .env("WINSMUX_ROLE_MAP", r#"{"%3":"Reviewer"}"#)
        .current_dir(project_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let state_path = project_dir.join(".winsmux").join("review-state.json");
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
            .expect("review state should be JSON");
    state["codex/task266-rust-operator-readmodels-20260424"]["request"]["id"]
        .as_str()
        .expect("request id should be a string")
        .to_string()
}

fn read_review_state(project_dir: &std::path::Path) -> serde_json::Value {
    let state_path = project_dir.join(".winsmux").join("review-state.json");
    serde_json::from_slice(&fs::read(&state_path).expect("review state should exist"))
        .expect("review state should be JSON")
}

fn read_manifest_pane(project_dir: &std::path::Path, label: &str) -> serde_yaml::Value {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest: serde_yaml::Value =
        serde_yaml::from_slice(&fs::read(&manifest_path).expect("manifest should exist"))
            .expect("manifest should be YAML");
    let panes = manifest["panes"]
        .as_mapping()
        .expect("panes should be a map");
    panes
        .get(serde_yaml::Value::String(label.to_string()))
        .expect("pane should exist")
        .clone()
}

fn strip_windows_extended_path_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = path.strip_prefix(r"\\?\") {
        return rest.to_string();
    }
    path.to_string()
}

fn write_fake_winsmux_dispatch_review(
    project_dir: &std::path::Path,
) -> (std::path::PathBuf, std::path::PathBuf) {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    let log_path = fake_dir.join("winsmux-dispatch-review.log");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-dispatch-review-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        body.push_str("echo %*>>\"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\"\r\n");
        body.push_str("if \"%1\"==\"capture-pane\" (\r\n");
        body.push_str("  findstr /c:\"winsmux review-request\" \"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\" >nul 2>nul\r\n");
        body.push_str("  if errorlevel 1 (\r\n");
        body.push_str("    echo PS C:\\repo^>\r\n");
        body.push_str("  ) else (\r\n");
        body.push_str("    echo PS C:\\repo^> winsmux review-request\r\n");
        body.push_str("  )\r\n");
        body.push_str("  exit /b 0\r\n)\r\n");
        body.push_str("if \"%1\"==\"send-keys\" exit /b 0\r\n");
        body.push_str("exit /b 1\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        (fake_path, log_path)
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-dispatch-review-fake");
        let mut body = String::from("#!/bin/sh\n");
        body.push_str("printf '%s\\n' \"$*\" >> '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("'\n");
        body.push_str("if [ \"$1\" = \"capture-pane\" ]; then\n");
        body.push_str("  if grep -q 'winsmux review-request' '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("'; then\n");
        body.push_str("    printf '%s\\n' 'PS /repo> winsmux review-request'\n");
        body.push_str("  else\n");
        body.push_str("    printf '%s\\n' 'PS /repo>'\n");
        body.push_str("  fi\n");
        body.push_str("  exit 0\n");
        body.push_str("fi\n");
        body.push_str("if [ \"$1\" = \"send-keys\" ]; then\n  exit 0\nfi\n");
        body.push_str("exit 1\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        (fake_path, log_path)
    }
}

fn write_fake_winsmux_list_panes(
    project_dir: &std::path::Path,
    expected_session: Option<&str>,
    pane_ids: &[&str],
) -> std::path::PathBuf {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        if let Some(session) = expected_session {
            body.push_str("if not \"%1\"==\"-t\" exit /b 0\r\n");
            body.push_str("if not \"%2\"==\"");
            body.push_str(session);
            body.push_str("\" exit /b 0\r\n");
        }
        body.push_str("if \"%3\"==\"list-panes\" (\r\n");
        for pane_id in pane_ids {
            body.push_str("  echo ");
            body.push_str(&pane_id.replace('%', "%%"));
            body.push_str("\r\n");
        }
        body.push_str("  exit /b 0\r\n)\r\nexit /b 1\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        fake_path
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-fake");
        let mut body = String::from("#!/bin/sh\n");
        if let Some(session) = expected_session {
            body.push_str("if [ \"$1\" != \"-t\" ] || [ \"$2\" != '");
            body.push_str(session);
            body.push_str("' ]; then\n  exit 0\nfi\n");
        }
        body.push_str("if [ \"$3\" = \"list-panes\" ]; then\n");
        for pane_id in pane_ids {
            body.push_str("  printf '%s\\n' '");
            body.push_str(pane_id);
            body.push_str("'\n");
        }
        body.push_str("  exit 0\nfi\nexit 1\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        fake_path
    }
}

fn write_fake_winsmux_restart(
    project_dir: &std::path::Path,
    expected_session: Option<&str>,
    pane_ids: &[&str],
) -> (std::path::PathBuf, std::path::PathBuf) {
    let fake_dir = project_dir.join(".test-bin");
    fs::create_dir_all(&fake_dir).expect("test should create fake bin dir");
    let log_path = fake_dir.join("winsmux-restart.log");
    #[cfg(windows)]
    {
        let fake_path = fake_dir.join("winsmux-restart-fake.cmd");
        let mut body = String::from("@echo off\r\n");
        body.push_str("echo %*>>\"");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("\"\r\n");
        if let Some(session) = expected_session {
            body.push_str("if \"%1\"==\"-t\" if not \"%2\"==\"");
            body.push_str(session);
            body.push_str("\" exit /b 0\r\n");
        }
        body.push_str("if \"%3\"==\"list-panes\" (\r\n");
        for pane_id in pane_ids {
            body.push_str("  echo ");
            body.push_str(&pane_id.replace('%', "%%"));
            body.push_str("\r\n");
        }
        body.push_str("  exit /b 0\r\n)\r\n");
        body.push_str("if \"%1\"==\"capture-pane\" (\r\n  echo PS C:\\repo^>\r\n  echo ^>\r\n  echo Welcome to Claude Code!\r\n  exit /b 0\r\n)\r\n");
        body.push_str("exit /b 0\r\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        (fake_path, log_path)
    }
    #[cfg(not(windows))]
    {
        let fake_path = fake_dir.join("winsmux-restart-fake");
        let mut body = String::from("#!/bin/sh\n");
        body.push_str("printf '%s\\n' \"$*\" >> '");
        body.push_str(&log_path.to_string_lossy());
        body.push_str("'\n");
        if let Some(session) = expected_session {
            body.push_str("if [ \"$1\" = \"-t\" ] && [ \"$2\" != '");
            body.push_str(session);
            body.push_str("' ]; then\n  exit 0\nfi\n");
        }
        body.push_str("if [ \"$3\" = \"list-panes\" ]; then\n");
        for pane_id in pane_ids {
            body.push_str("  printf '%s\\n' '");
            body.push_str(pane_id);
            body.push_str("'\n");
        }
        body.push_str("  exit 0\nfi\n");
        body.push_str("if [ \"$1\" = \"capture-pane\" ]; then\n  printf '%s\\n' 'PS /repo>' '>' 'Welcome to Claude Code!'\n  exit 0\nfi\n");
        body.push_str("exit 0\n");
        fs::write(&fake_path, body).expect("test should write fake winsmux");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_path)
                .expect("test should read fake winsmux metadata")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&fake_path, permissions)
                .expect("test should make fake winsmux executable");
        }
        (fake_path, log_path)
    }
}

fn run_json(project_dir: &std::path::Path, args: &[&str]) -> serde_json::Value {
    run_json_with_cwd(project_dir, args)
}

fn read_json_file(path: &std::path::Path) -> serde_json::Value {
    let raw = fs::read_to_string(path).expect("test should read JSON file");
    serde_json::from_str(&raw).expect("test file should contain JSON")
}

fn write_provider_switch_fixture(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        project_dir.join(".winsmux.yaml"),
        r#"
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    model-source: cli-discovery
    prompt-transport: argv
"#,
    )
    .expect("test should write settings");
    fs::write(
        winsmux_dir.join("provider-capabilities.json"),
        r#"{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account"}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "sonnet", "label": "Sonnet", "source": "official-doc"},
        {"id": "opus", "label": "Opus", "source": "official-doc"},
        {"id": "opusplan", "label": "Opus Plan", "source": "official-doc"}
      ],
      "model_sources": ["provider-default", "official-doc", "operator-override"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh", "max"],
      "local_access_note": "Local Claude Code account and settings.",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true
    },
    "gemini": {
      "adapter": "gemini",
      "command": "gemini",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "operator-override", "label": "Operator override", "source": "operator-override"}
      ],
      "model_sources": ["provider-default", "operator-override"],
      "reasoning_efforts": ["provider-default"],
      "local_access_note": "Local Gemini CLI account and settings.",
      "prompt_transports": ["argv", "file"],
      "auth_modes": ["gemini-local"],
      "local_interactive_oauth_modes": ["gemini-local"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true
    }
  }
}"#,
    )
    .expect("test should write provider capabilities");
}

fn run_json_with_cwd(cwd: impl AsRef<std::path::Path>, args: &[&str]) -> serde_json::Value {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .current_dir(cwd)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "winsmux command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("stdout should be JSON")
}

fn init_conflict_preflight_repo(project_dir: &std::path::Path) {
    run_git(project_dir, &["init"]);
    run_git(
        project_dir,
        &["config", "user.email", "winsmux-test@example.com"],
    );
    run_git(project_dir, &["config", "user.name", "winsmux test"]);
    write_git_file(project_dir, "base.txt", "base\n");
    run_git(project_dir, &["add", "base.txt"]);
    run_git(project_dir, &["commit", "-m", "base"]);
    run_git(project_dir, &["branch", "base"]);
}

fn write_git_file(project_dir: &std::path::Path, name: &str, text: &str) {
    fs::write(project_dir.join(name), text).expect("test should write git file");
}

fn run_git(project_dir: &std::path::Path, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(project_dir)
        .output()
        .expect("git should run");
    assert!(
        output.status.success(),
        "git {:?} failed\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_compare_runs_fixture(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    task_id: task-a
    task: Compare run A
    task_state: completed
    review_state: PASS
    branch: branch-a
    head_sha: aaaabbbbccccdddd
    provider_target: codex:gpt-5.4
    changed_file_count: 1
    changed_files: '["core/src/operator_cli.rs"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-24T12:00:00+09:00
  builder-2:
    pane_id: "%3"
    role: Worker
    task_id: task-b
    task: Compare run B
    task_state: completed
    review_state: PASS
    branch: branch-b
    head_sha: eeeeffff11112222
    provider_target: claude:opus
    changed_file_count: 2
    changed_files: '["core/src/operator_cli.rs","core/src/main.rs"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-24T12:01:00+09:00
"#,
    )
    .expect("test should write manifest");
    fs::write(
        winsmux_dir.join("events.jsonl"),
r#"{"timestamp":"2026-04-24T12:00:00+09:00","session":"winsmux-orchestra","event":"pane.consult_result","message":"consultation completed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","slot":"builder-1","hypothesis":"cache command is stable","result":"cache hit","confidence":0.85,"next_action":"promote tactic","observation_pack_ref":".winsmux/observation-packs/task-a.json","consultation_ref":".winsmux/consultations/task-a.json","worktree":".worktrees/a","env_fingerprint":"env-a","command_hash":"cmd-a"}}
{"timestamp":"2026-04-24T12:00:05+09:00","session":"winsmux-orchestra","event":"operator.mailbox.message_received","message":"team memory captured","source":"mailbox","data":{"task_id":"task-a","run_id":"task:task-a","source":"mailbox","team_memory_refs":["team-memory:task-a:operator-standard"]}}
{"timestamp":"2026-04-24T12:00:10+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","verification_result":{"outcome":"PASS","summary":"cache hit confirmed"}}}
{"timestamp":"2026-04-24T12:00:20+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","label":"builder-1","pane_id":"%2","role":"Builder","branch":"branch-a","head_sha":"aaaabbbbccccdddd","data":{"task_id":"task-a","run_id":"task:task-a","verdict":"ALLOW","reason":"verified safe"}}
{"timestamp":"2026-04-24T12:01:00+09:00","session":"winsmux-orchestra","event":"pane.consult_result","message":"consultation completed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","slot":"builder-2","hypothesis":"rebuild command is stable","result":"rebuild clean","confidence":0.6,"next_action":"promote tactic","observation_pack_ref":".winsmux/observation-packs/task-b.json","consultation_ref":".winsmux/consultations/task-b.json","worktree":".worktrees/b","env_fingerprint":"env-b","command_hash":"cmd-b"}}
{"timestamp":"2026-04-24T12:01:10+09:00","session":"winsmux-orchestra","event":"pipeline.verify.pass","message":"verification passed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","verification_result":{"outcome":"PASS","summary":"rebuild confirmed"}}}
{"timestamp":"2026-04-24T12:01:20+09:00","session":"winsmux-orchestra","event":"pipeline.security.allowed","message":"security allowed","label":"builder-2","pane_id":"%3","role":"Worker","branch":"branch-b","head_sha":"eeeeffff11112222","data":{"task_id":"task-b","run_id":"task:task-b","verdict":"ALLOW","reason":"verified safe"}}
"#,
    )
    .expect("test should write events");
    fs::create_dir_all(winsmux_dir.join("observation-packs"))
        .expect("test should create observation pack directory");
    fs::create_dir_all(winsmux_dir.join("consultations"))
        .expect("test should create consultation directory");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-a.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:task-a","summary":"captured cache command"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-a.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:task-a","recommendation":"prefer cache command"}"#,
    )
    .expect("test should write consultation packet");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-b.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:task-b","summary":"captured rebuild command"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-b.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:task-b","recommendation":"prefer rebuild command"}"#,
    )
    .expect("test should write consultation packet");
}

fn write_manifest(project_dir: &std::path::Path) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(
        winsmux_dir.join("manifest.yaml"),
        r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: running
    task_id: TASK-266
    task: Add Rust operator read models
    task_state: in_progress
    parent_run_id: operator:session-1
    goal: Keep Rust read models aligned
    task_type: implementation
    priority: P0
    blocking: true
    review_state: pending
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: abc123
    changed_file_count: 2
    changed_files:
      - core/src/main.rs
      - core/src/operator_cli.rs
    write_scope:
      - core/src/operator_cli.rs
    read_scope:
      - scripts/winsmux-core.ps1
    constraints:
      - preserve PowerShell JSON shape
    expected_output: Rust read-only CLI
    verification_plan:
      - cargo test --manifest-path core/Cargo.toml --test operator_cli
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs:
      - docs/handoff.md
    last_event: operator.review_requested
    last_event_at: 2026-04-24T12:00:00+09:00
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    state: idle
    task_state: waiting
    review_state: PASS
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: def456
"#,
    )
    .expect("test should write manifest");
    fs::create_dir_all(winsmux_dir.join("observation-packs"))
        .expect("test should create observation pack directory");
    fs::create_dir_all(winsmux_dir.join("consultations"))
        .expect("test should create consultation directory");
    fs::write(
        winsmux_dir.join("observation-packs").join("task-266.json"),
        r#"{"packet_type":"observation_pack","run_id":"task:TASK-266","summary":"captured operator read model"}"#,
    )
    .expect("test should write observation pack");
    fs::write(
        winsmux_dir.join("consultations").join("task-266.json"),
        r#"{"packet_type":"consultation_packet","run_id":"task:TASK-266","recommendation":"keep read-only"}"#,
    )
    .expect("test should write consultation packet");
    fs::write(
        winsmux_dir.join("events.jsonl"),
        r#"{"timestamp":"2026-04-24T12:00:01+09:00","session":"winsmux-orchestra","event":"operator.review_requested","message":"review requested","label":"builder-1","pane_id":"%2","role":"Builder","status":"review_requested","data":{"task_id":"TASK-266","run_id":"task:TASK-266","hypothesis":"Rust can read operator evidence","test_plan":["read manifest"],"result":"captured","confidence":0.91,"next_action":"commit_ready","observation_pack_ref":".winsmux/observation-packs/task-266.json","consultation_ref":".winsmux/consultations/task-266.json"}}
{"timestamp":"2026-04-24T12:00:02+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"ready to commit","label":"builder-1","pane_id":"%2","role":"Builder","status":"commit_ready","data":{"task_id":"TASK-266"}}
"#,
    )
    .expect("test should write events");
}

fn write_review_state(project_dir: &std::path::Path, content: &str) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(winsmux_dir.join("review-state.json"), content)
        .expect("test should write review state");
}

fn init_git_branch(project_dir: &std::path::Path, branch: &str) {
    let init = Command::new("git")
        .args(["init", "-b", branch])
        .current_dir(project_dir)
        .output()
        .expect("git init should run");
    assert!(
        init.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );
}

fn set_git_head(project_dir: &std::path::Path, branch: &str, head_sha: &str) {
    let ref_path = project_dir
        .join(".git")
        .join("refs")
        .join("heads")
        .join(branch.replace('/', std::path::MAIN_SEPARATOR_STR));
    fs::create_dir_all(ref_path.parent().expect("ref should have a parent"))
        .expect("test should create git ref directory");
    fs::write(ref_path, format!("{head_sha}\n")).expect("test should write git ref");
}

fn make_temp_project_dir(name: &str) -> std::path::PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("winsmux-{name}-{}-{suffix}", std::process::id()));
    fs::create_dir_all(&path).expect("test should create temp project directory");
    path
}
