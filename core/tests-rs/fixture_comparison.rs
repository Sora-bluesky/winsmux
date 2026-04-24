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

use serde_json::Value;
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
    let root = repo_root();
    let manifest = rust_parity_support::read_text_fixture(&root, "manifest.yaml");
    let events = rust_parity_support::read_text_fixture(&root, "events.jsonl");
    ledger::LedgerSnapshot::from_manifest_and_events(&manifest, &events)
        .expect("frozen manifest and event fixtures should load")
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
