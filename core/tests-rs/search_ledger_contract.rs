#[path = "../src/event_contract.rs"]
mod event_contract;

#[allow(dead_code)]
#[path = "../src/search_ledger.rs"]
mod search_ledger;

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn search_ledger_indexes_search_timeline_and_detail() {
    let mut ledger =
        search_ledger::SearchLedger::open_in_memory().expect("search ledger should open");
    let indexed = ledger
        .rebuild_from_events_jsonl(sample_events())
        .expect("events should index");

    assert_eq!(indexed, 4);

    let hits = ledger
        .search("TASK-307 search", 10)
        .expect("search should run");
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].entry.task_id, "TASK-307");
    assert!(hits
        .iter()
        .any(|hit| hit.entry.event == "operator.followup"));

    let timeline = ledger
        .timeline(search_ledger::SearchLedgerTimelineFilter {
            run_id: Some("run:task-307".to_string()),
            limit: 10,
            ..search_ledger::SearchLedgerTimelineFilter::default()
        })
        .expect("timeline should run");
    assert_eq!(timeline.len(), 3);
    assert_eq!(timeline[0].entry.event, "experiment.started");
    assert_eq!(timeline[2].entry.event, "experiment.finished");

    let detail = ledger
        .detail(timeline[1].entry.id)
        .expect("detail lookup should run")
        .expect("detail should exist");
    assert_eq!(detail.entry.event, "operator.followup");
    assert_eq!(
        detail.detail["data"]["hypothesis"],
        "FTS5 sidecar supports search"
    );
}

#[test]
fn search_ledger_suppresses_tagged_credentials_and_redacts_sensitive_fields() {
    let mut ledger =
        search_ledger::SearchLedger::open_in_memory().expect("search ledger should open");
    let events = r#"
{"timestamp":"2026-04-27T12:00:00+09:00","event":"credential.recorded","message":"token alpha-secret","task_id":"TASK-307","data":{"retention_tags":["credential"],"token":"alpha-secret"}}
{"timestamp":"2026-04-27T12:01:00+09:00","event":"operator.note","message":"token raw-message keep searchable note","task_id":"TASK-307","data":{"api_key":"plain-secret","privateKey":"raw-private","nested":{"password":"hidden","sshKey":"raw-ssh","authHeader":"raw-auth"},"note":"keep this","output":"neutral-secret-value","stderr":"Bearer raw-bearer"}}
"#;
    let indexed = ledger
        .rebuild_from_events_jsonl(events)
        .expect("events should index");

    assert_eq!(indexed, 1);
    assert!(ledger
        .search("alpha-secret", 10)
        .expect("credential search should run")
        .is_empty());
    assert!(ledger
        .search("plain-secret", 10)
        .expect("redacted search should run")
        .is_empty());
    assert!(ledger
        .search("raw-private", 10)
        .expect("private key search should run")
        .is_empty());
    assert!(ledger
        .search("raw-ssh", 10)
        .expect("ssh key search should run")
        .is_empty());
    assert!(ledger
        .search("raw-auth", 10)
        .expect("auth header search should run")
        .is_empty());
    assert!(ledger
        .search("raw-message", 10)
        .expect("message secret search should run")
        .is_empty());
    assert!(ledger
        .search("neutral-secret-value", 10)
        .expect("neutral-key secret search should run")
        .is_empty());
    assert!(ledger
        .search("raw-bearer", 10)
        .expect("bearer search should run")
        .is_empty());

    let hit = ledger
        .search("keep", 10)
        .expect("non-sensitive search should run")
        .pop()
        .expect("note should be searchable");
    let detail = ledger
        .detail(hit.entry.id)
        .expect("detail lookup should run")
        .expect("detail should exist");
    assert_eq!(hit.entry.message, "[redacted]");
    assert_eq!(detail.detail["message"], "[redacted]");
    assert_eq!(detail.detail["data"]["api_key"], "[redacted]");
    assert_eq!(detail.detail["data"]["privateKey"], "[redacted]");
    assert_eq!(detail.detail["data"]["nested"]["password"], "[redacted]");
    assert_eq!(detail.detail["data"]["nested"]["sshKey"], "[redacted]");
    assert_eq!(detail.detail["data"]["nested"]["authHeader"], "[redacted]");
    assert_eq!(detail.detail["data"]["note"], "keep this");
    assert_eq!(detail.detail["data"]["output"], "[redacted]");
    assert_eq!(detail.detail["data"]["stderr"], "[redacted]");
}

#[test]
fn search_ledger_rebuild_scrubs_removed_sidecar_text() {
    let project_dir = make_temp_project_dir("search-ledger-scrub");
    let sidecar_path = project_dir.join(".winsmux").join("search-ledger.sqlite");
    {
        let mut ledger =
            search_ledger::SearchLedger::open_sidecar(&sidecar_path).expect("sidecar should open");
        ledger
            .rebuild_from_events_jsonl(
                r#"{"timestamp":"2026-04-27T12:00:00+09:00","event":"operator.note","message":"temporary searchable phrase","task_id":"TASK-307","data":{"note":"temporary searchable phrase"}}"#,
            )
            .expect("initial event should index");
        ledger
            .rebuild_from_events_jsonl(
                r#"{"timestamp":"2026-04-27T12:01:00+09:00","event":"operator.note","message":"temporary searchable phrase","task_id":"TASK-307","data":{"suppress_search":true,"note":"temporary searchable phrase"}}"#,
            )
            .expect("suppressed rebuild should complete");
    }

    let sidecar_bytes = fs::read(&sidecar_path).expect("sidecar should be readable");
    let sidecar_text = String::from_utf8_lossy(&sidecar_bytes);
    assert!(
        !sidecar_text.contains("temporary searchable phrase"),
        "sidecar should not retain text from deleted rows"
    );
}

#[test]
fn search_ledger_uses_data_identifier_fallbacks() {
    let mut ledger =
        search_ledger::SearchLedger::open_in_memory().expect("search ledger should open");
    let events = r#"
{"timestamp":"2026-04-27T12:00:00+09:00","event":"pane.consult_request","message":"fallback identifiers should index","label":"builder-1","pane_id":"%2","role":"Builder","data":{"run_id":"run:fallback","task_id":"TASK-307","branch":"task-307-search-ledger","head_sha":"abc123"}}
"#;
    let indexed = ledger
        .rebuild_from_events_jsonl(events)
        .expect("events should index");

    assert_eq!(indexed, 1);
    let timeline = ledger
        .timeline(search_ledger::SearchLedgerTimelineFilter {
            run_id: Some("run:fallback".to_string()),
            task_id: Some("TASK-307".to_string()),
            limit: 10,
            ..search_ledger::SearchLedgerTimelineFilter::default()
        })
        .expect("timeline should use fallback identifiers");
    assert_eq!(timeline.len(), 1);
    assert_eq!(timeline[0].entry.branch, "task-307-search-ledger");
    assert_eq!(timeline[0].entry.head_sha, "abc123");

    let detail = ledger
        .detail(timeline[0].entry.id)
        .expect("detail lookup should run")
        .expect("detail should exist");
    assert_eq!(detail.detail["run_id"], "run:fallback");
    assert_eq!(detail.detail["task_id"], "TASK-307");
}

#[test]
fn search_ledger_cli_search_timeline_and_detail_json() {
    let project_dir = make_temp_project_dir("search-ledger-cli");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux");
    fs::write(winsmux_dir.join("events.jsonl"), sample_events()).expect("test should write events");

    let search = run_json(
        &project_dir,
        &[
            "search-ledger",
            "search",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("path should be utf-8"),
            "TASK-307",
        ],
    );
    assert_eq!(search["indexed_count"], 4);
    assert_eq!(search["hits"][0]["task_id"], "TASK-307");
    assert!(
        search["sidecar_path"]
            .as_str()
            .expect("sidecar path should be string")
            .ends_with(".winsmux\\search-ledger.sqlite")
            || search["sidecar_path"]
                .as_str()
                .expect("sidecar path should be string")
                .ends_with(".winsmux/search-ledger.sqlite")
    );

    let filtered_search = run_json(
        &project_dir,
        &[
            "search-ledger",
            "search",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("path should be utf-8"),
            "--task-id",
            "TASK-999",
            "TASK-307",
        ],
    );
    assert_eq!(
        filtered_search["hits"]
            .as_array()
            .expect("hits should be array")
            .len(),
        0
    );

    let detail_id = search["hits"][0]["id"]
        .as_i64()
        .expect("hit id should be numeric");
    let detail = run_json(
        &project_dir,
        &[
            "search-ledger",
            "detail",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("path should be utf-8"),
            &detail_id.to_string(),
        ],
    );
    assert_eq!(detail["detail"]["task_id"], "TASK-307");

    let timeline = run_json(
        &project_dir,
        &[
            "search-ledger",
            "timeline",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("path should be utf-8"),
            "--run-id",
            "run:task-307",
        ],
    );
    assert_eq!(
        timeline["items"]
            .as_array()
            .expect("items should be array")
            .len(),
        3
    );
    assert_eq!(timeline["items"][0]["event"], "experiment.started");
}

#[test]
fn search_ledger_cli_detail_rejects_inapplicable_filters() {
    let project_dir = make_temp_project_dir("search-ledger-detail-invalid");
    let winsmux_dir = project_dir.join(".winsmux");
    fs::create_dir_all(&winsmux_dir).expect("test should create .winsmux");
    fs::write(winsmux_dir.join("events.jsonl"), sample_events()).expect("test should write events");

    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args([
            "search-ledger",
            "detail",
            "--json",
            "--project-dir",
            project_dir.to_str().expect("path should be utf-8"),
            "--task-id",
            "TASK-307",
            "1",
        ])
        .current_dir(&project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(
        !output.status.success(),
        "detail with ignored filters should fail"
    );
    assert!(String::from_utf8_lossy(&output.stderr)
        .contains("detail accepts only --json, --project-dir, --sidecar, and one id"));
}

fn sample_events() -> &'static str {
    r#"
{"timestamp":"2026-04-27T12:00:00+09:00","event":"experiment.started","message":"Implement TASK-307 search ledger","label":"worker-a","pane_id":"%2","role":"Builder","run_id":"run:task-307","task_id":"TASK-307","data":{"hypothesis":"FTS5 sidecar supports search","test_plan":"cargo test search_ledger_contract"}}
{"timestamp":"2026-04-27T12:02:00+09:00","event":"operator.followup","message":"TASK-307 needs timeline detail display","label":"worker-a","pane_id":"%2","role":"Builder","run_id":"run:task-307","task_id":"TASK-307","data":{"hypothesis":"FTS5 sidecar supports search","next_action":"open detail"}}
{"timestamp":"2026-04-27T12:03:00+09:00","event":"experiment.finished","message":"search ledger tests passed","label":"worker-a","pane_id":"%2","role":"Builder","run_id":"run:task-307","task_id":"TASK-307","data":{"result":"pass"}}
{"timestamp":"2026-04-27T12:04:00+09:00","event":"review.note","message":"other task note","label":"reviewer","pane_id":"%3","role":"Reviewer","run_id":"run:task-999","task_id":"TASK-999","data":{"result":"ignored"}}
"#
}

fn run_json(project_dir: &Path, args: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_winsmux"))
        .args(args)
        .current_dir(project_dir)
        .output()
        .expect("winsmux command should run");
    assert!(
        output.status.success(),
        "command should succeed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("stdout should be JSON")
}

fn make_temp_project_dir(label: &str) -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after unix epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("winsmux-{label}-{unique}"));
    fs::create_dir_all(&dir).expect("test should create temp project dir");
    dir
}
