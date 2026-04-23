#[path = "../src/manifest_contract.rs"]
mod manifest_contract;

#[path = "../src/event_contract.rs"]
mod event_contract;

#[path = "../src/ledger.rs"]
mod ledger;

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

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

#[test]
fn ledger_contract_loads_live_winsmux_files() {
    let fixture = TempProject::new("live-files");
    fixture.write_winsmux_file("manifest.yaml", MANIFEST_FIXTURE);
    fixture.write_winsmux_file("events.jsonl", EVENTS_FIXTURE);

    let snapshot = ledger::LedgerSnapshot::from_project_dir(fixture.path())
        .expect("ledger snapshot should load live .winsmux files");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.pane_count(), 2);
    assert_eq!(snapshot.event_count(), 5);
}

#[test]
fn ledger_contract_allows_missing_live_events_file() {
    let fixture = TempProject::new("missing-events");
    fixture.write_winsmux_file("manifest.yaml", MANIFEST_FIXTURE);

    let snapshot = ledger::LedgerSnapshot::from_project_dir(fixture.path())
        .expect("missing events.jsonl should be treated as an empty event stream");

    assert_eq!(snapshot.session_name(), "winsmux-orchestra");
    assert_eq!(snapshot.event_count(), 0);
}

struct TempProject {
    root: PathBuf,
}

impl TempProject {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "winsmux-ledger-contract-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".winsmux")).expect("temp .winsmux dir should be created");
        Self { root }
    }

    fn path(&self) -> &std::path::Path {
        &self.root
    }

    fn write_winsmux_file(&self, name: &str, content: &str) {
        fs::write(self.root.join(".winsmux").join(name), content)
            .expect("temp winsmux file should be written");
    }
}

impl Drop for TempProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
