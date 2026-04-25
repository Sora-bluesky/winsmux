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
