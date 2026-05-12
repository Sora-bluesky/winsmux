#[path = "../src/event_contract.rs"]
mod event_contract;

use event_contract::{parse_event_jsonl, EventRecord};
use serde_json::{Map, Value};
use std::path::PathBuf;

mod rust_parity_support {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/test_support/rust_parity.rs"
    ));
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn read_fixture(name: &str) -> String {
    rust_parity_support::read_text_fixture(&repo_root(), name)
}

fn parse_single_record(line: &str) -> EventRecord {
    let mut records = parse_event_jsonl(line).expect("single-line event should parse");
    records.pop().expect("single-line parse should return one event")
}

fn resolved_branch(record: &EventRecord) -> String {
    if !record.branch.is_empty() {
        return record.branch.clone();
    }

    record
        .data
        .get("branch")
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string()
}

fn resolved_head_sha(record: &EventRecord) -> String {
    if !record.head_sha.is_empty() {
        return record.head_sha.clone();
    }

    record
        .data
        .get("head_sha")
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string()
}

#[test]
fn event_fixture_deserializes_and_validates() {
    let records =
        parse_event_jsonl(&read_fixture("events.jsonl")).expect("event fixture should parse");

    assert_eq!(records.len(), 5);
    assert_eq!(records[0].event, "pane.consult_result");
    assert_eq!(records[0].branch, "worktree-builder-1");
    assert_eq!(records[0].head_sha, "abc1234def5678");
    assert_eq!(records[1].status, "completed");
    assert_eq!(records[1].exit_reason, "completed");
    assert_eq!(records[2].event, "server.restarted");
    assert_eq!(records[2].role, "");
    assert_eq!(records[2].data["attempt"], 1);
    assert_eq!(records[3].branch, "");
    assert_eq!(records[3].head_sha, "");
    assert_eq!(records[3].data["branch"], "worktree-builder-2");
    assert_eq!(records[3].data["head_sha"], "1234567abcdef0");
    assert_eq!(resolved_branch(&records[3]), "worktree-builder-2");
    assert_eq!(resolved_head_sha(&records[3]), "1234567abcdef0");
    assert_eq!(records[4].branch, "worktree-builder-3");
    assert_eq!(records[4].head_sha, "feedbee1234567");
    assert_eq!(records[4].data["branch"], "stale-branch");
    assert_eq!(records[4].data["head_sha"], "stale-head");
    assert_eq!(resolved_branch(&records[4]), "worktree-builder-3");
    assert_eq!(resolved_head_sha(&records[4]), "feedbee1234567");
}

#[test]
fn event_accepts_utf8_bom_on_first_line() {
    let records = parse_event_jsonl(
        "\u{feff}{\"timestamp\":\"2026-05-12T20:58:00+09:00\",\"event\":\"pane.completed\"}",
    )
    .expect("BOM-prefixed event stream should parse");

    assert_eq!(records.len(), 1);
    assert_eq!(records[0].event, "pane.completed");
}

#[test]
fn event_accepts_sparse_legacy_poll_event_shape() {
    let record = parse_single_record(
        r#"{"timestamp":"2026-04-07T09:00:00.0000000+09:00","event":"pane.completed","pane_id":"%2","label":"builder-1"}"#,
    );

    assert_eq!(record.timestamp, "2026-04-07T09:00:00.0000000+09:00");
    assert_eq!(record.event, "pane.completed");
    assert_eq!(record.pane_id, "%2");
    assert_eq!(record.label, "builder-1");
    assert_eq!(record.session, "");
    assert_eq!(record.message, "");
    assert_eq!(record.role, "");
}

#[test]
fn event_accepts_null_optional_fields() {
    let record = parse_single_record(
        r#"{"timestamp":"2026-04-23T12:00:00+09:00","event":"pane.completed","session":null,"message":null,"label":null,"pane_id":null,"role":null,"status":null,"exit_reason":null,"source":null,"branch":null,"head_sha":null,"data":null}"#,
    );

    assert_eq!(record.session, "");
    assert_eq!(record.message, "");
    assert_eq!(record.label, "");
    assert_eq!(record.pane_id, "");
    assert_eq!(record.role, "");
    assert_eq!(record.status, "");
    assert_eq!(record.exit_reason, "");
    assert_eq!(record.source, "");
    assert_eq!(record.branch, "");
    assert_eq!(record.head_sha, "");
    assert_eq!(record.data, Value::Object(Map::new()));
}

#[test]
fn event_rejects_missing_timestamp() {
    let err = parse_event_jsonl(r#"{"event":"pane.completed"}"#)
        .expect_err("missing timestamp should fail");
    assert!(err.contains("failed to parse event line 1"));
}

#[test]
fn event_rejects_missing_event() {
    let err = parse_event_jsonl(r#"{"timestamp":"2026-04-23T12:00:00+09:00"}"#)
        .expect_err("missing event should fail");
    assert!(err.contains("failed to parse event line 1"));
}

#[test]
fn event_rejects_unknown_top_level_field() {
    let err = parse_event_jsonl(
        r#"{"timestamp":"2026-04-23T12:00:00+09:00","event":"pane.completed","unexpected":true}"#,
    )
    .expect_err("unknown top-level field should fail");
    assert!(err.contains("failed to parse event line 1"));
}

#[test]
fn event_rejects_non_object_data() {
    let err = parse_event_jsonl(
        r#"{"timestamp":"2026-04-23T12:00:00+09:00","event":"pane.completed","data":["bad"]}"#,
    )
    .expect_err("non-object data should fail");
    assert!(err.contains("failed to parse event line 1"));
}
