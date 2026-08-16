use std::fs;
use std::io::{BufRead, BufReader, Write as _};
use std::path::{Path, PathBuf};
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

fn make_temp_project_dir(name: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("winsmux-{name}-{}-{suffix}", std::process::id()));
    fs::create_dir_all(&path).expect("test should create temp project directory");
    path
}

fn events_jsonl(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("events.jsonl")
}

fn write_events_jsonl(project_dir: &Path, contents: &str) {
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux directory");
    fs::write(events_jsonl(project_dir), contents).expect("test should write events.jsonl");
}

fn event_line(event: &str, extra_fields: &str) -> String {
    if extra_fields.is_empty() {
        format!(r#"{{"timestamp":"2026-04-24T12:00:00+09:00","event":"{event}"}}"#)
    } else {
        format!(
            r#"{{"timestamp":"2026-04-24T12:00:00+09:00","event":"{event}",{extra_fields}}}"#
        )
    }
}

fn run_events(project_dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .current_dir(project_dir)
        .output()
        .expect("winsmux command should run")
}

fn run_events_json(project_dir: &Path, extra_args: &[&str]) -> serde_json::Value {
    let mut args = vec![
        "events",
        "--json",
        "--project-dir",
        project_dir.to_str().expect("temp path should be utf-8"),
    ];
    args.extend_from_slice(extra_args);
    let output = run_events(project_dir, &args);
    assert!(
        output.status.success(),
        "winsmux events should succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert!(
        json.is_object(),
        "public events payload must be an object wrapper, not {:?}",
        json
    );
    assert!(json.get("cursor").is_some(), "wrapper must include cursor");
    assert!(
        json.get("events")
            .and_then(serde_json::Value::as_array)
            .is_some(),
        "wrapper must include events array"
    );
    json
}

fn spawn_events_follow(project_dir: &Path) -> (ChildKillGuard, mpsc::Receiver<String>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "events",
            "--follow",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ])
        .current_dir(project_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("winsmux events --follow should start");
    let stdout = child.stdout.take().expect("child should expose stdout");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else {
                break;
            };
            if !line.trim().is_empty() {
                let _ = sender.send(line);
            }
        }
    });
    (ChildKillGuard(child), receiver)
}

fn assert_usage_failure(output: &std::process::Output) {
    assert!(
        !output.status.success(),
        "command should fail closed without --json"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux events"),
        "stderr should print events usage: {stderr}"
    );
}

fn mixed_mapped_and_unmapped_jsonl() -> String {
    [
        event_line(
            "pane.started",
            r#""pane_id":"%1","role":"Builder","run_id":"run-1""#,
        ),
        event_line("pipeline.verify.pass", ""),
        event_line("pane.idle", r#""exit_reason":"completed""#),
        event_line("task.checked_out", r#""task_id":"TASK-1""#),
        event_line(
            "operator.commit_ready",
            r#""run_id":"run-1","task_id":"TASK-1""#,
        ),
    ]
    .join("\n")
        + "\n"
}

#[test]
fn events_e01_missing_jsonl_returns_empty_wrapper() {
    let project_dir = make_temp_project_dir("events-e01");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");

    let json = run_events_json(&project_dir, &[]);

    assert_eq!(json["cursor"], 0);
    assert_eq!(
        json["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );
}

#[test]
fn events_e02_mixed_mapped_and_unmapped_omits_unmapped_and_preserves_jsonl() {
    let project_dir = make_temp_project_dir("events-e02");
    let original = mixed_mapped_and_unmapped_jsonl();
    write_events_jsonl(&project_dir, &original);
    let before = fs::read(events_jsonl(&project_dir)).expect("test should read jsonl bytes");

    let json = run_events_json(&project_dir, &[]);

    let after = fs::read(events_jsonl(&project_dir)).expect("test should reread jsonl bytes");
    assert_eq!(before, after, "events must not mutate jsonl bytes");
    assert_eq!(json["cursor"], 5);
    let events = json["events"].as_array().expect("events should be array");
    assert_eq!(events.len(), 3, "only mapped objects should be returned");
    assert_eq!(events[0]["type"], "thread_created");
    assert_eq!(events[0]["cursor"], 0);
    assert_eq!(events[0]["pane_id"], "%1");
    assert_eq!(events[0]["run_id"], "run-1");
    assert_eq!(events[0]["role"], "Builder");
    assert_eq!(events[1]["type"], "status_idle");
    assert_eq!(events[1]["cursor"], 2);
    assert_eq!(events[1]["stop_reason"], "completed");
    assert_eq!(events[2]["type"], "message_received");
    assert_eq!(events[2]["cursor"], 4);
    assert_eq!(events[2]["run_id"], "run-1");
    assert_eq!(events[2]["task_id"], "TASK-1");
    for event in events {
        let type_name = event["type"].as_str().unwrap_or_default();
        assert!(
            matches!(
                type_name,
                "thread_created"
                    | "status_running"
                    | "status_idle"
                    | "message_received"
                    | "requires_action"
            ),
            "unexpected condensed type: {type_name}"
        );
        assert!(
            event.get("event").is_none(),
            "must not copy source event name as a public key"
        );
        assert!(
            event.get("timestamp").is_none(),
            "must not copy unknown jsonl keys"
        );
    }
}

#[test]
fn events_e03_malformed_line_fails_closed_without_partial_events() {
    let project_dir = make_temp_project_dir("events-e03");
    write_events_jsonl(
        &project_dir,
        &(event_line(
            "pane.started",
            r#""pane_id":"%1","role":"Builder","run_id":"run-1""#,
        ) + "\nthis is not json\n"),
    );

    let output = run_events(
        &project_dir,
        &[
            "events",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );

    assert!(!output.status.success(), "malformed jsonl must fail closed");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("2"),
        "stderr should include the malformed line number: {stderr}"
    );
    if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
        let events = json
            .get("events")
            .and_then(serde_json::Value::as_array)
            .cloned()
            .unwrap_or_default();
        assert!(
            events.is_empty(),
            "must not emit a partial public events wrapper: {json}"
        );
    } else {
        assert!(
            String::from_utf8_lossy(&output.stdout)
                .trim()
                .is_empty()
                || !String::from_utf8_lossy(&output.stdout).contains("thread_created"),
            "stdout must not leak partial public events: {}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
}

#[test]
fn events_e04_missing_json_flag_is_usage_error() {
    let project_dir = make_temp_project_dir("events-e04");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");
    let output = run_events(
        &project_dir,
        &[
            "events",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );
    assert_usage_failure(&output);
}

#[test]
fn events_e05_follow_json_emits_one_wrapper_per_mapped_line() {
    let project_dir = make_temp_project_dir("events-e05");
    write_events_jsonl(&project_dir, "");
    let (_child, receiver) = spawn_events_follow(&project_dir);

    let line = wait_for_follow_line(&receiver, |_| {
        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(events_jsonl(&project_dir))
            .expect("test should open events.jsonl");
        writeln!(
            file,
            "{}",
            event_line("pane.idle", r#""pane_id":"%1","exit_reason":"done""#)
        )
        .expect("test should append mapped event");
        file.flush().expect("test should flush events");
    });
    let json: serde_json::Value =
        serde_json::from_str(line.trim()).expect("follow output should be JSON");
    assert!(json.is_object(), "follow must print the object wrapper");
    assert_eq!(
        json["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        1
    );
    assert_eq!(json["events"][0]["type"], "status_idle");
    assert_eq!(json["cursor"], 1);
}

#[test]
fn events_e06_follow_without_json_is_usage_error() {
    let project_dir = make_temp_project_dir("events-e06");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");
    let output = run_events(
        &project_dir,
        &[
            "events",
            "--follow",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );
    assert_usage_failure(&output);
}

#[test]
fn events_e07_poll_events_json_remains_usage_error() {
    let project_dir = make_temp_project_dir("events-e07");
    fs::create_dir_all(project_dir.join(".winsmux")).expect("test should create .winsmux");
    let output = run_events(
        &project_dir,
        &[
            "poll-events",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("temp path should be utf-8"),
        ],
    );
    assert!(
        !output.status.success(),
        "poll-events --json must stay invalid"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("usage: winsmux poll-events"),
        "poll-events --json should keep printing poll-events usage: {stderr}"
    );
    assert!(
        !stderr.contains("usage: winsmux events "),
        "poll-events must not be rewired to the condensed events usage"
    );
}

#[test]
fn events_e08_pane_idle_empty_exit_reason_has_empty_stop_reason() {
    let project_dir = make_temp_project_dir("events-e08");
    write_events_jsonl(&project_dir, &(event_line("pane.idle", "") + "\n"));

    let json = run_events_json(&project_dir, &[]);

    assert_eq!(json["cursor"], 1);
    assert_eq!(json["events"].as_array().expect("events").len(), 1);
    assert_eq!(json["events"][0]["type"], "status_idle");
    assert_eq!(json["events"][0]["stop_reason"], "");
}

#[test]
fn events_e09_pane_crashed_maps_to_requires_action() {
    let project_dir = make_temp_project_dir("events-e09");
    write_events_jsonl(
        &project_dir,
        &(event_line("pane.crashed", r#""pane_id":"%2""#) + "\n"),
    );

    let json = run_events_json(&project_dir, &[]);

    assert_eq!(json["events"].as_array().expect("events").len(), 1);
    assert_eq!(json["events"][0]["type"], "requires_action");
    assert_eq!(json["events"][0]["pane_id"], "%2");
    assert_eq!(json["events"][0]["cursor"], 0);
}

#[test]
fn events_e10_pipeline_verify_pass_advances_cursor_with_empty_events() {
    let project_dir = make_temp_project_dir("events-e10");
    write_events_jsonl(
        &project_dir,
        &(event_line("pipeline.verify.pass", "") + "\n"),
    );

    let json = run_events_json(&project_dir, &[]);

    assert_eq!(json["cursor"], 1, "unmapped lines must still advance cursor");
    assert_eq!(
        json["events"]
            .as_array()
            .expect("events should be array")
            .len(),
        0
    );
}

#[test]
fn events_e11_other_project_dir_does_not_read_this_repo_jsonl() {
    let poison_dir = make_temp_project_dir("events-e11-poison");
    write_events_jsonl(
        &poison_dir,
        &(event_line(
            "pane.started",
            r#""pane_id":"%9","role":"Builder","run_id":"poison-run""#,
        ) + "\n"),
    );
    let other_dir = make_temp_project_dir("events-e11-other");
    fs::create_dir_all(other_dir.join(".winsmux")).expect("test should create other .winsmux");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "events",
            "--json",
            "--project-dir",
            other_dir.to_str().expect("temp path should be utf-8"),
        ])
        .current_dir(&poison_dir)
        .output()
        .expect("winsmux command should run");

    assert!(
        output.status.success(),
        "events should succeed for the other project-dir: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("stdout should be JSON");
    assert_eq!(json["cursor"], 0);
    assert_eq!(json["events"].as_array().expect("events").len(), 0);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("poison-run"),
        "must not read jsonl from the current working directory: {stdout}"
    );
}

#[test]
fn events_e12_missing_project_dir_path_fails_closed() {
    let project_dir = make_temp_project_dir("events-e12");
    let missing = project_dir.join("does-not-exist");
    let output = run_events(
        &project_dir,
        &[
            "events",
            "--json",
            "--project-dir",
            missing.to_str().expect("temp path should be utf-8"),
        ],
    );
    assert!(
        !output.status.success(),
        "missing --project-dir path must fail closed"
    );
    assert!(
        serde_json::from_slice::<serde_json::Value>(&output.stdout).is_err()
            || output.stdout.is_empty(),
        "must not emit a public events wrapper for a missing project-dir"
    );
}

#[test]
fn events_e13_follow_waits_for_torn_line_then_emits_completed_mapped_event() {
    let project_dir = make_temp_project_dir("events-e13");
    write_events_jsonl(&project_dir, "");
    let (_child, receiver) = spawn_events_follow(&project_dir);

    let torn = r#"{"timestamp":"2026-04-24T12:00:00+09:00","event":"pane.idle""#;
    fs::write(events_jsonl(&project_dir), torn).expect("test should write torn jsonl line");
    assert!(
        receiver.recv_timeout(Duration::from_millis(600)).is_err(),
        "torn last line must not emit a wrapper"
    );

    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(events_jsonl(&project_dir))
        .expect("test should reopen events.jsonl");
    writeln!(file, r#","exit_reason":"idle"}}"#).expect("test should complete torn line");
    file.flush().expect("test should flush completed line");

    let line = receiver
        .recv_timeout(Duration::from_secs(3))
        .expect("completed mapped line should emit one wrapper");
    let json: serde_json::Value =
        serde_json::from_str(line.trim()).expect("follow output should be JSON");
    assert_eq!(json["events"].as_array().expect("events").len(), 1);
    assert_eq!(json["events"][0]["type"], "status_idle");
    assert_eq!(json["events"][0]["stop_reason"], "idle");
}

#[test]
fn events_e14_pane_started_emits_only_thread_created() {
    let project_dir = make_temp_project_dir("events-e14");
    write_events_jsonl(
        &project_dir,
        &(event_line(
            "pane.started",
            r#""pane_id":"%3","role":"Worker","run_id":"run-14""#,
        ) + "\n"),
    );

    let json = run_events_json(&project_dir, &[]);

    let events = json["events"].as_array().expect("events should be array");
    assert_eq!(events.len(), 1, "pane.started must emit exactly one object");
    assert_eq!(events[0]["type"], "thread_created");
    assert_ne!(events[0]["type"], "status_running");
    assert_eq!(events[0]["pane_id"], "%3");
    assert_eq!(events[0]["run_id"], "run-14");
    assert_eq!(events[0]["role"], "Worker");
}

fn wait_for_follow_line(
    receiver: &mpsc::Receiver<String>,
    mut append_event: impl FnMut(usize),
) -> String {
    for attempt in 0..20 {
        append_event(attempt);
        if let Ok(line) = receiver.recv_timeout(Duration::from_millis(250)) {
            return line;
        }
    }
    panic!("follow should emit one condensed wrapper");
}
