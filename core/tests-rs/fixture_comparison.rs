#[path = "../src/manifest_contract.rs"]
mod manifest_contract;

#[path = "../src/event_contract.rs"]
mod event_contract;

#[path = "../src/ledger.rs"]
mod ledger;

mod rust_parity_support {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/test_support/rust_parity.rs"
    ));
}

use serde_json::{Map, Value};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ProjectionFixture {
    name: &'static str,
    file: &'static str,
}

const PROJECTION_FIXTURES: &[ProjectionFixture] = &[
    ProjectionFixture {
        name: "board",
        file: "board.json",
    },
    ProjectionFixture {
        name: "inbox",
        file: "inbox.json",
    },
    ProjectionFixture {
        name: "digest",
        file: "digest.json",
    },
    ProjectionFixture {
        name: "explain",
        file: "explain.json",
    },
];

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core crate should have a repository parent")
        .to_path_buf()
}

fn read_power_shell_golden(case: ProjectionFixture) -> Value {
    rust_parity_support::read_json_fixture(&repo_root(), case.file)
}

fn read_rust_ledger_snapshot() -> ledger::LedgerSnapshot {
    read_rust_ledger_snapshot_from("manifest.yaml", "events.jsonl")
}

fn read_rust_ledger_snapshot_from(
    manifest_file: &str,
    events_file: &str,
) -> ledger::LedgerSnapshot {
    let root = repo_root();
    let manifest = rust_parity_support::read_text_fixture(&root, manifest_file);
    let events = if events_file.is_empty() {
        String::new()
    } else {
        rust_parity_support::read_text_fixture(&root, events_file)
    };
    ledger::LedgerSnapshot::from_manifest_and_events(&manifest, &events)
        .expect("frozen manifest and event fixtures should load")
}

fn read_rust_projection(case: ProjectionFixture) -> Value {
    match case.name {
        "board" => {
            let snapshot = read_rust_ledger_snapshot_from("board-manifest.yaml", "");
            normalize_comparison_values(
                serde_json::to_value(snapshot.board_projection())
                    .expect("board projection should serialize to JSON"),
            )
        }
        "inbox" => {
            let snapshot =
                read_rust_ledger_snapshot_from("inbox-manifest.yaml", "inbox-events.jsonl");
            normalize_comparison_values(
                serde_json::to_value(snapshot.inbox_projection())
                    .expect("inbox projection should serialize to JSON"),
            )
        }
        "digest" => {
            let snapshot =
                read_rust_ledger_snapshot_from("digest-manifest.yaml", "digest-events.jsonl");
            normalize_comparison_values(
                serde_json::to_value(snapshot.digest_projection())
                    .expect("digest projection should serialize to JSON"),
            )
        }
        "explain" => normalize_comparison_values(
            serde_json::to_value(
                read_rust_ledger_snapshot_from("explain-manifest.yaml", "explain-events.jsonl")
                    .explain_projection("task:task-256")
                    .expect("fixture task should have an explain projection"),
            )
            .expect("explain projection should serialize to JSON"),
        ),
        _ => panic!("unknown projection fixture: {}", case.name),
    }
}

fn expected_rust_projection(case: ProjectionFixture) -> Value {
    let golden = read_power_shell_golden(case);

    match case.name {
        "board" => projection_with_items(&golden, &["summary"], "panes", BOARD_PANE_KEYS),
        "inbox" => projection_with_items(&golden, &["summary"], "items", INBOX_ITEM_KEYS),
        "digest" => projection_with_items(&golden, &["summary"], "items", DIGEST_ITEM_KEYS),
        "explain" => explain_projection_from_golden(&golden),
        _ => panic!("unknown projection fixture: {}", case.name),
    }
}

const BOARD_PANE_KEYS: &[&str] = &[
    "label",
    "pane_id",
    "role",
    "state",
    "task_id",
    "task",
    "task_state",
    "review_state",
    "phase",
    "activity",
    "detail",
    "branch",
    "worktree",
    "head_sha",
    "changed_file_count",
    "last_event_at",
];

const INBOX_ITEM_KEYS: &[&str] = &[
    "kind",
    "priority",
    "message",
    "label",
    "pane_id",
    "role",
    "task_id",
    "task",
    "task_state",
    "review_state",
    "phase",
    "activity",
    "detail",
    "branch",
    "head_sha",
    "changed_file_count",
    "event",
    "timestamp",
    "source",
];

const DIGEST_ITEM_KEYS: &[&str] = &[
    "run_id",
    "task_id",
    "task",
    "label",
    "pane_id",
    "role",
    "provider_target",
    "task_state",
    "review_state",
    "phase",
    "activity",
    "detail",
    "next_action",
    "branch",
    "worktree",
    "head_sha",
    "head_short",
    "changed_file_count",
    "changed_files",
    "action_item_count",
    "last_event",
    "last_event_at",
    "verification_verdict_summary",
    "security_verdict_summary",
    "monitoring_verdict_summary",
    "verification_outcome",
    "security_blocked",
    "hypothesis",
    "confidence",
    "observation_pack_ref",
    "consultation_ref",
];

const EXPLAIN_RUN_KEYS: &[&str] = &[
    "run_id",
    "task_id",
    "parent_run_id",
    "goal",
    "task",
    "task_type",
    "priority",
    "blocking",
    "state",
    "task_state",
    "review_state",
    "phase",
    "activity",
    "detail",
    "branch",
    "head_sha",
    "worktree",
    "primary_label",
    "primary_pane_id",
    "primary_role",
    "last_event",
    "last_event_at",
    "tokens_remaining",
    "pane_count",
    "changed_file_count",
    "labels",
    "pane_ids",
    "roles",
    "provider_target",
    "agent_role",
    "write_scope",
    "read_scope",
    "constraints",
    "expected_output",
    "verification_plan",
    "review_required",
    "timeout_policy",
    "handoff_refs",
    "action_items",
    "experiment_packet",
    "security_policy",
    "security_verdict",
    "verification_contract",
    "verification_result",
    "verification_evidence",
    "tdd_gate",
    "verification_envelope",
    "audit_chain",
    "outcome",
    "phase_gate",
    "draft_pr_gate",
    "changed_files",
];

const EXPLAIN_RECENT_EVENT_KEYS: &[&str] = &[
    "timestamp",
    "event",
    "status",
    "message",
    "label",
    "pane_id",
    "role",
    "task_id",
    "branch",
    "head_sha",
    "source",
    "hypothesis",
    "test_plan",
    "result",
    "confidence",
    "next_action",
    "observation_pack_ref",
    "consultation_ref",
    "run_id",
    "slot",
    "worktree",
    "env_fingerprint",
    "command_hash",
    "observation_pack",
    "consultation_packet",
    "verification_contract",
    "verification_result",
    "security_verdict",
];

fn projection_with_items(
    golden: &Value,
    singleton_keys: &[&str],
    item_key: &str,
    item_keys: &[&str],
) -> Value {
    let mut root = Map::new();
    for key in singleton_keys {
        insert_key(&mut root, golden, key);
    }
    root.insert(
        item_key.to_string(),
        Value::Array(select_array_objects(
            json_at_path(golden, &[item_key]),
            item_keys,
        )),
    );
    Value::Object(root)
}

fn explain_projection_from_golden(golden: &Value) -> Value {
    let mut root = Map::new();
    root.insert(
        "run".to_string(),
        select_object(json_at_path(golden, &["run"]), EXPLAIN_RUN_KEYS),
    );
    root.insert(
        "explanation".to_string(),
        json_at_path(golden, &["explanation"]).clone(),
    );
    root.insert(
        "evidence_digest".to_string(),
        select_object(json_at_path(golden, &["evidence_digest"]), DIGEST_ITEM_KEYS),
    );
    root.insert(
        "recent_events".to_string(),
        Value::Array(select_array_objects(
            json_at_path(golden, &["recent_events"]),
            EXPLAIN_RECENT_EVENT_KEYS,
        )),
    );
    Value::Object(root)
}

fn select_array_objects(value: &Value, keys: &[&str]) -> Vec<Value> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("expected JSON array, got {value:?}"))
        .iter()
        .map(|item| select_object(item, keys))
        .collect()
}

fn select_object(value: &Value, keys: &[&str]) -> Value {
    let mut selected = Map::new();
    for key in keys {
        insert_key(&mut selected, value, key);
    }
    normalize_expected_rust_values(Value::Object(selected))
}

fn insert_key(target: &mut Map<String, Value>, source: &Value, key: &str) {
    target.insert(key.to_string(), json_at_path(source, &[key]).clone());
}

fn normalize_expected_rust_values(value: Value) -> Value {
    normalize_comparison_values(value)
}

fn normalize_comparison_values(value: Value) -> Value {
    match value {
        Value::Array(items) => {
            Value::Array(items.into_iter().map(normalize_comparison_values).collect())
        }
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| {
                    let value = if key == "timestamp" {
                        Value::String("__TIMESTAMP__".to_string())
                    } else {
                        normalize_comparison_values(value)
                    };
                    (key, value)
                })
                .collect(),
        ),
        other => other,
    }
}

fn json_at_path<'a>(value: &'a Value, path: &[&str]) -> &'a Value {
    let mut current = value;
    for segment in path {
        current = current
            .get(*segment)
            .unwrap_or_else(|| panic!("JSON path {:?} should exist", path));
    }
    current
}

fn assert_projection_path_matches(case: ProjectionFixture, path: &[&str]) {
    let golden = expected_rust_projection(case);
    let rust = read_rust_projection(case);

    assert_eq!(
        json_at_path(&golden, path),
        json_at_path(&rust, path),
        "{} projection JSON path {:?} should match the PowerShell golden corpus",
        case.name,
        path
    );
}

fn assert_projection_matches(case: ProjectionFixture) {
    assert_eq!(
        expected_rust_projection(case),
        read_rust_projection(case),
        "{} Rust projection should match the modeled PowerShell golden corpus",
        case.name
    );
}

#[test]
fn fixture_comparison_harness_loads_power_shell_golden_corpus() {
    for case in PROJECTION_FIXTURES {
        let value = read_power_shell_golden(*case);
        assert!(
            value.is_object(),
            "{} fixture should be a JSON object",
            case.name
        );
    }
}

#[test]
fn fixture_comparison_harness_loads_rust_typed_projection_sources() {
    let snapshot = read_rust_ledger_snapshot();
    let board = snapshot.board_projection();
    let inbox = snapshot.inbox_projection();
    let digest = snapshot.digest_projection();
    let explain = snapshot
        .explain_projection("task:task-256")
        .expect("fixture task should have an explain projection");

    assert_eq!(board.summary.pane_count, 2);
    assert!(!inbox.items.is_empty());
    assert!(!digest.items.is_empty());
    assert_eq!(explain.run.run_id, "task:task-256");
}

#[test]
fn fixture_comparison_harness_declares_projection_coverage() {
    let names: Vec<_> = PROJECTION_FIXTURES.iter().map(|case| case.name).collect();

    assert_eq!(names, vec!["board", "inbox", "digest", "explain"]);
}

#[test]
fn fixture_comparison_harness_diffs_modeled_projection_payloads() {
    for case in PROJECTION_FIXTURES {
        assert_projection_matches(*case);
    }
}

#[test]
fn fixture_comparison_harness_diffs_explain_run_identity_payload() {
    let case = ProjectionFixture {
        name: "explain",
        file: "explain.json",
    };

    for path in [
        &["run", "run_id"][..],
        &["run", "task_id"],
        &["run", "task_state"],
        &["run", "review_state"],
        &["run", "branch"],
        &["run", "head_sha"],
        &["run", "primary_label"],
        &["run", "primary_pane_id"],
        &["run", "pane_count"],
        &["run", "changed_file_count"],
    ] {
        assert_projection_path_matches(case, path);
    }
}
