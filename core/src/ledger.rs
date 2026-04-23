use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::manifest_contract::{NormalizedManifestPane, WinsmuxManifest};
use std::collections::{HashMap, HashSet};

#[derive(Debug)]
pub struct LedgerSnapshot {
    manifest: WinsmuxManifest,
    events: Vec<EventRecord>,
    panes: Vec<NormalizedManifestPane>,
    panes_by_id: HashMap<String, NormalizedManifestPane>,
}

impl LedgerSnapshot {
    pub fn from_manifest_and_events(
        manifest_yaml: &str,
        events_jsonl: &str,
    ) -> Result<Self, String> {
        let manifest = WinsmuxManifest::from_yaml(manifest_yaml)
            .map_err(|err| format!("failed to parse manifest: {err}"))?;
        manifest.validate()?;

        let events = parse_event_jsonl(events_jsonl)?;
        let panes = manifest.normalized_panes();
        let panes_by_id = index_panes_by_id(&panes)?;

        let snapshot = Self {
            manifest,
            events,
            panes,
            panes_by_id,
        };
        snapshot.validate_event_sessions()?;
        Ok(snapshot)
    }

    pub fn session_name(&self) -> &str {
        &self.manifest.session.name
    }

    pub fn pane_count(&self) -> usize {
        self.panes.len()
    }

    pub fn event_count(&self) -> usize {
        self.events.len()
    }

    pub fn pane_labels(&self) -> Vec<String> {
        self.panes.iter().map(|pane| pane.label.clone()).collect()
    }

    pub fn events_for_pane(&self, pane_id: &str) -> Vec<&EventRecord> {
        self.events
            .iter()
            .filter(|event| event.pane_id == pane_id)
            .collect()
    }

    pub fn unknown_event_pane_ids(&self) -> Vec<String> {
        let known: HashSet<&str> = self.panes_by_id.keys().map(String::as_str).collect();
        let mut unknown: Vec<String> = self
            .events
            .iter()
            .filter_map(|event| {
                let pane_id = event.pane_id.trim();
                if pane_id.is_empty() || known.contains(pane_id) {
                    None
                } else {
                    Some(pane_id.to_string())
                }
            })
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        unknown.sort();
        unknown
    }

    fn validate_event_sessions(&self) -> Result<(), String> {
        let session_name = self.session_name();
        if session_name.trim().is_empty() {
            return Ok(());
        }

        for event in &self.events {
            if event.session.trim().is_empty() || event.session == session_name {
                continue;
            }

            return Err(format!(
                "event '{}' belongs to session '{}', expected '{}'",
                event.event, event.session, session_name
            ));
        }

        Ok(())
    }
}

fn index_panes_by_id(
    panes: &[NormalizedManifestPane],
) -> Result<HashMap<String, NormalizedManifestPane>, String> {
    let mut panes_by_id = HashMap::new();
    for pane in panes {
        let pane_id = pane.pane_id.trim();
        if pane_id.is_empty() {
            continue;
        }
        if panes_by_id
            .insert(pane_id.to_string(), pane.clone())
            .is_some()
        {
            return Err(format!("duplicate manifest pane_id '{pane_id}'"));
        }
    }
    Ok(panes_by_id)
}

#[cfg(test)]
mod tests {
    use super::LedgerSnapshot;

    const MANIFEST_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/manifest.yaml");
    const EVENTS_FIXTURE: &str = include_str!("../../tests/fixtures/rust-parity/events.jsonl");

    #[test]
    fn ledger_snapshot_loads_manifest_and_events() {
        let snapshot =
            LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, EVENTS_FIXTURE).unwrap();

        assert_eq!(snapshot.session_name(), "winsmux-orchestra");
        assert_eq!(snapshot.pane_count(), 2);
        assert_eq!(snapshot.event_count(), 5);
        assert!(snapshot.pane_labels().contains(&"builder-1".to_string()));
        assert_eq!(snapshot.events_for_pane("%2").len(), 2);
        assert_eq!(
            snapshot.unknown_event_pane_ids(),
            vec!["%7".to_string(), "%9".to_string()]
        );
    }

    #[test]
    fn ledger_snapshot_rejects_wrong_event_session() {
        let events = r#"{"timestamp":"2026-04-23T12:00:00+09:00","session":"other","event":"pane.completed"}"#;

        let err = LedgerSnapshot::from_manifest_and_events(MANIFEST_FIXTURE, events).unwrap_err();

        assert!(err.contains("belongs to session 'other'"));
    }

    #[test]
    fn ledger_snapshot_rejects_duplicate_manifest_pane_id() {
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

        let err = LedgerSnapshot::from_manifest_and_events(manifest, "").unwrap_err();

        assert!(err.contains("duplicate manifest pane_id '%2'"));
    }
}
