#[path = "../src/manifest_contract.rs"]
mod manifest_contract;

#[path = "../src/event_contract.rs"]
mod event_contract;

#[path = "../src/ledger.rs"]
mod ledger;

const MANIFEST_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/manifest.yaml");
const EVENTS_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/events.jsonl");

#[test]
fn ledger_contract_loads_frozen_manifest_and_events() {
    let snapshot =
        ledger::LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE)
            .expect("ledger snapshot should load frozen fixtures");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.pane_count(), 2);
    assert_eq!(
        snapshot.pane_labels(),
        vec!["builder-1".to_string(), "reviewer-1".to_string()]
    );
    assert_eq!(snapshot.event_count(), 5);
    assert_eq!(snapshot.events_for_pane("%2").len(), 2);
    assert_eq!(
        snapshot.unknown_event_pane_ids(),
        vec!["%7".to_string(), "%9".to_string()]
    );
}

#[test]
fn ledger_contract_rejects_duplicate_manifest_pane_id() {
    let manifest = r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
  reviewer-1:
    pane_id: "%2"
    role: Reviewer
"#;

    let err = ledger::LedgerSnapshot::from_manifest_and_events(manifest, EVENTS_FIXTURE)
        .expect_err("duplicate manifest pane_id must be rejected");

    assert!(err.contains("duplicate manifest pane_id '%2'"));
}
