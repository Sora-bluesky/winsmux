use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

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
    assert_eq!(last_event["data"]["result"], "Ship the Rust command");
    assert_eq!(last_event["data"]["confidence"], 0.82);
    assert_eq!(last_event["data"]["next_action"], json["next_test"]);
    assert_eq!(last_event["data"]["consultation_ref"], consultation_ref);

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
fn operator_cli_read_models_require_json_flag() {
    let project_dir = make_temp_project_dir("requires-json");
    write_manifest(&project_dir);

    for command in ["board", "inbox", "digest", "runs"] {
        let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
            .arg(command)
            .current_dir(&project_dir)
            .output()
            .expect("winsmux command should run");

        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("currently supports only --json"),
            "unexpected stderr for {command}: {stderr}"
        );
    }
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
        body.push_str(
            "if \"%1\"==\"capture-pane\" (\r\n  echo PS C:\\repo^>\r\n  echo ^>\r\n  exit /b 0\r\n)\r\n",
        );
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
        body.push_str("if [ \"$1\" = \"capture-pane\" ]; then\n  printf '%s\\n' 'PS /repo>' '>'\n  exit 0\nfi\n");
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
