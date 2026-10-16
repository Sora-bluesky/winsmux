//! Opaque output cursors and events.wait projection over EventAccounting snapshots.
//!
//! This module does not increment `event_seq`, register waiters, or own a second
//! event log. Auth snapshots under Authorization.inner, drops that lock, then
//! calls these helpers. Waiter overflow is `resource_exhausted` for the call,
//! never `record_loss` of a retained event (N3).
//!
//! Missing interface: `EventAccounting` / `EventWaiter` stay private in `auth`.
//! Auth must pass `committed_seq`, `dropped_through`, and `&[MetadataEvent]`
//! (plus a grant/project callback). Do not invent a local event registry.

use crate::contract::ingress::{CanonicalValue, Measure};
use crate::contract::{
    ErrorCode, EventData, EventsWaitData, InstanceId, MetadataEvent, NonEmpty, OutputReadData,
    ProjectId, RunId, U, WaitStatus, MAX_MESSAGE_BYTES, MAX_SAFE_INTEGER,
};
use crate::runtime::{envelope_text, RuntimeService};
use std::time::Duration;

const CURSOR_PREFIX: &str = "v1:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpaqueCursor {
    pub instance_id: InstanceId,
    pub run_id: RunId,
    pub offset: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolvedCursor {
    Start,
    Offset(u64),
    GapToLive,
}

pub fn encode_cursor(instance_id: &InstanceId, run_id: &RunId, offset: u64) -> NonEmpty {
    NonEmpty::new(format!(
        "{CURSOR_PREFIX}{}/{}/{offset}",
        instance_id.as_str(),
        run_id.as_str()
    ))
    .expect("opaque cursor is non-empty")
}

pub fn decode_cursor(text: &str) -> Option<OpaqueCursor> {
    let rest = text.strip_prefix(CURSOR_PREFIX)?;
    let mut parts = rest.split('/');
    let instance = parts.next()?;
    let run = parts.next()?;
    let offset = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    let instance_id = InstanceId::new(instance.to_owned()).ok()?;
    let run_id = RunId::new(run.to_owned()).ok()?;
    if offset.is_empty()
        || !offset.bytes().all(|byte| byte.is_ascii_digit())
        || (offset.len() > 1 && offset.starts_with('0'))
    {
        return None;
    }
    let offset = offset.parse::<u64>().ok()?;
    Some(OpaqueCursor {
        instance_id,
        run_id,
        offset,
    })
}

pub fn resolve_read_cursor(
    cursor: Option<&str>,
    this_instance: &InstanceId,
    this_run: &RunId,
) -> ResolvedCursor {
    let Some(text) = cursor else {
        return ResolvedCursor::Start;
    };
    match decode_cursor(text) {
        Some(decoded)
            if decoded.instance_id.as_str() == this_instance.as_str()
                && decoded.run_id.as_str() == this_run.as_str() =>
        {
            ResolvedCursor::Offset(decoded.offset)
        }
        _ => ResolvedCursor::GapToLive,
    }
}

pub fn read_output(
    runtime: &RuntimeService,
    instance_id: &InstanceId,
    run_id: &RunId,
    cursor: Option<&str>,
    max_bytes: u64,
) -> Result<OutputReadData, ErrorCode> {
    match resolve_read_cursor(cursor, instance_id, run_id) {
        ResolvedCursor::GapToLive => {
            let live = runtime.read_output(run_id, None, u64::MAX, run_id.as_str())?;
            Ok(OutputReadData {
                run_id: run_id.clone(),
                text: String::new(),
                next_cursor: encode_cursor(instance_id, run_id, live.next_cursor),
                gap: true,
                truncated: false,
            })
        }
        ResolvedCursor::Start => {
            slice_to_read(runtime, instance_id, run_id, None, max_bytes)
        }
        ResolvedCursor::Offset(offset) => {
            slice_to_read(runtime, instance_id, run_id, Some(offset), max_bytes)
        }
    }
}

fn slice_to_read(
    runtime: &RuntimeService,
    instance_id: &InstanceId,
    run_id: &RunId,
    cursor: Option<u64>,
    max_bytes: u64,
) -> Result<OutputReadData, ErrorCode> {
    let slice = runtime.read_output(run_id, cursor, max_bytes, run_id.as_str())?;
    let (text, env_truncated) = envelope_text(&slice.text, max_bytes);
    let next_offset = slice.origin.saturating_add(text.len() as u64);
    Ok(OutputReadData {
        run_id: run_id.clone(),
        text,
        next_cursor: encode_cursor(instance_id, run_id, next_offset),
        gap: slice.gap,
        truncated: slice.truncated || env_truncated,
    })
}

pub fn events_envelope_budget() -> usize {
    MAX_MESSAGE_BYTES.saturating_sub(1024)
}

pub fn remaining_wait_ms(wait_ms: u64, elapsed: Duration) -> u64 {
    let elapsed_ms = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
    wait_ms.saturating_sub(elapsed_ms)
}

/// `None` means do not enter OS wait. `Some` is always finite; never `INFINITE` (`u32::MAX`).
pub fn os_wait_timeout(wait_ms: u64, elapsed: Duration) -> Option<u32> {
    if wait_ms == 0 {
        return None;
    }
    let remaining = remaining_wait_ms(wait_ms, elapsed);
    if remaining == 0 {
        return None;
    }
    Some(u32::try_from(remaining.min(u64::from(u32::MAX - 1))).expect("capped below u32::MAX"))
}

pub fn event_passes_grant(
    event: &MetadataEvent,
    event_project: Option<&ProjectId>,
    grants: &[ProjectId],
    owner: bool,
    same_actor_operation: bool,
) -> bool {
    match &event.data {
        EventData::ConnectionStateChanged { .. } => owner,
        EventData::OperationStateChanged { .. } => same_actor_operation,
        EventData::TopologyChanged { project_id, .. } => {
            if owner {
                return true;
            }
            match project_id.0.as_ref() {
                None => true,
                Some(id) => grants.iter().any(|granted| granted.as_str() == id.as_str()),
            }
        }
        EventData::RunStateChanged { .. } => {
            if owner {
                return true;
            }
            event_project.is_some_and(|project| {
                grants
                    .iter()
                    .any(|granted| granted.as_str() == project.as_str())
            })
        }
    }
}

fn encoded_len(value: &impl CanonicalValue) -> Result<usize, ErrorCode> {
    let mut measure = Measure(0);
    value
        .write_canonical(&mut measure)
        .map_err(|_| ErrorCode::ResourceExhausted)?;
    Ok(measure.0)
}

/// Project a wait snapshot. Does not publish, reserve, or record_loss.
pub fn project_events_wait(
    after: U,
    committed_seq: u64,
    dropped_through: u64,
    events: &[MetadataEvent],
    mut visible: impl FnMut(&MetadataEvent) -> bool,
    envelope_budget: usize,
) -> Result<EventsWaitData, ErrorCode> {
    let after = after.get();
    if after > committed_seq {
        return Err(ErrorCode::InvalidRequest);
    }
    let mut scanned_through = after;
    let mut selected: Vec<MetadataEvent> = Vec::new();
    let mut used = 0usize;
    let mut unsent_visible = false;
    for event in events {
        let seq = event.event_seq.get();
        if seq <= after || seq > committed_seq {
            continue;
        }
        if !visible(event) {
            scanned_through = seq;
            continue;
        }
        let size = encoded_len(event)?;
        if size > envelope_budget {
            return Err(ErrorCode::ResourceExhausted);
        }
        let extra = if selected.is_empty() {
            size
        } else {
            size.saturating_add(1)
        };
        if used.saturating_add(extra) > envelope_budget {
            unsent_visible = true;
            break;
        }
        selected.push(event.clone());
        used = used.saturating_add(extra);
        scanned_through = seq;
    }
    let next = if unsent_visible {
        scanned_through
    } else {
        committed_seq
    };
    if next < after {
        return Err(ErrorCode::InvalidRequest);
    }
    let next_event_seq = U::new(next).map_err(|_| ErrorCode::ResourceExhausted)?;
    let gap = after < dropped_through;
    let status = if gap {
        WaitStatus::Gap
    } else if selected.is_empty() {
        WaitStatus::NoChange
    } else {
        WaitStatus::Events
    };
    Ok(EventsWaitData {
        status,
        events: selected,
        next_event_seq,
    })
}

#[cfg(test)]
mod cursor_and_wait_tests {
    use super::*;
    use crate::contract::{EventData, Nullable, PaneId, Timestamp};

    fn instance(nibble: char) -> InstanceId {
        InstanceId::new(format!("10000000-0000-4000-8000-00000000000{nibble}")).expect("instance")
    }

    fn run(nibble: char) -> RunId {
        RunId::new(format!("50000000-0000-4000-8000-00000000000{nibble}")).expect("run")
    }

    fn project(nibble: char) -> ProjectId {
        ProjectId::new(format!("30000000-0000-4000-8000-00000000000{nibble}")).expect("project")
    }

    fn stamp() -> Timestamp {
        Timestamp::new("1970-01-01T00:00:00.000Z").expect("epoch")
    }

    fn topology(seq: u64, project: Option<ProjectId>) -> MetadataEvent {
        MetadataEvent {
            event_seq: U::new(seq).expect("seq"),
            observed_at: stamp(),
            data: EventData::TopologyChanged {
                topology_revision: U::new(seq.max(1)).expect("rev"),
                project_id: Nullable(project),
                pane_id: Nullable(None),
            },
        }
    }

    #[test]
    fn opaque_cursor_round_trips_and_rejects_decimal_or_malformed() {
        let instance_id = instance('1');
        let run_id = run('1');
        let encoded = encode_cursor(&instance_id, &run_id, 12);
        let decoded = decode_cursor(encoded.as_str()).expect("decode");
        assert_eq!(decoded.instance_id.as_str(), instance_id.as_str());
        assert_eq!(decoded.run_id.as_str(), run_id.as_str());
        assert_eq!(decoded.offset, 12);
        assert_eq!(decode_cursor("12"), None);
        assert_eq!(decode_cursor("not-a-cursor"), None);
        assert_eq!(decode_cursor("v1:other-instance/x/0"), None);
        assert_eq!(
            resolve_read_cursor(Some("12"), &instance_id, &run_id),
            ResolvedCursor::GapToLive
        );
        assert_eq!(
            resolve_read_cursor(None, &instance_id, &run_id),
            ResolvedCursor::Start
        );
        assert_eq!(
            resolve_read_cursor(Some(encoded.as_str()), &instance_id, &run_id),
            ResolvedCursor::Offset(12)
        );
        let foreign = encode_cursor(&instance('2'), &run_id, 0);
        assert_eq!(
            resolve_read_cursor(Some(foreign.as_str()), &instance_id, &run_id),
            ResolvedCursor::GapToLive
        );
        let other_run = encode_cursor(&instance_id, &run('2'), 4);
        assert_eq!(
            resolve_read_cursor(Some(other_run.as_str()), &instance_id, &run_id),
            ResolvedCursor::GapToLive
        );
    }

    #[test]
    fn wait_ms_never_maps_to_infinite_and_zero_does_not_block() {
        assert_eq!(os_wait_timeout(0, Duration::ZERO), None);
        assert_eq!(os_wait_timeout(0, Duration::from_millis(5)), None);
        assert_eq!(os_wait_timeout(1, Duration::ZERO), Some(1));
        assert_eq!(os_wait_timeout(1, Duration::from_millis(1)), None);
        let max = os_wait_timeout(u64::from(u32::MAX), Duration::ZERO).expect("finite");
        assert_eq!(max, u32::MAX - 1);
        assert_ne!(max, u32::MAX);
        let huge = os_wait_timeout(MAX_SAFE_INTEGER, Duration::ZERO).expect("finite");
        assert_eq!(huge, u32::MAX - 1);
        assert!(os_wait_timeout(10, Duration::from_millis(3)).expect("remain") <= 7);
    }

    #[test]
    fn future_event_cursor_is_invalid_request_not_a_success_body() {
        let after = U::new(3).expect("after");
        let err = project_events_wait(after, 2, 0, &[], |_| true, events_envelope_budget())
            .unwrap_err();
        assert_eq!(err, ErrorCode::InvalidRequest);
    }

    #[test]
    fn gap_next_is_not_before_after_and_filter_is_not_gap() {
        let after = U::new(0).expect("after");
        let a = project('a');
        let b = project('b');
        let log = [
            topology(1, Some(b.clone())),
            topology(2, Some(a.clone())),
        ];
        let grants = [a.clone()];
        let filtered = project_events_wait(
            after,
            2,
            0,
            &log,
            |event| event_passes_grant(event, None, &grants, false, false),
            events_envelope_budget(),
        )
        .expect("filter");
        assert_eq!(filtered.status, WaitStatus::Events);
        assert_eq!(filtered.events.len(), 1);
        assert_eq!(filtered.events[0].event_seq.get(), 2);
        assert_eq!(filtered.next_event_seq.get(), 2);

        let gap = project_events_wait(after, 4, 3, &[], |_| true, events_envelope_budget())
            .expect("gap");
        assert_eq!(gap.status, WaitStatus::Gap);
        assert!(gap.events.is_empty());
        assert_eq!(gap.next_event_seq.get(), 4);
        assert!(gap.next_event_seq.get() >= after.get());

        let quiet = project_events_wait(
            U::new(2).expect("live after"),
            2,
            0,
            &log,
            |_| true,
            events_envelope_budget(),
        )
        .expect("quiet");
        assert_eq!(quiet.status, WaitStatus::NoChange);
        assert!(quiet.events.is_empty());
        assert_eq!(quiet.next_event_seq.get(), 2);
    }

    #[test]
    fn pagination_does_not_skip_an_unsent_visible_event() {
        let e1 = topology(1, None);
        let e2 = topology(2, None);
        let e3 = topology(3, None);
        let size1 = encoded_len(&e1).expect("e1");
        let size2 = encoded_len(&e2).expect("e2");
        let budget = size1.saturating_add(1).saturating_add(size2);
        let page = project_events_wait(
            U::new(0).expect("after"),
            3,
            0,
            &[e1, e2, e3],
            |_| true,
            budget,
        )
        .expect("page");
        assert_eq!(page.status, WaitStatus::Events);
        assert_eq!(page.events.len(), 2);
        assert_eq!(page.events[1].event_seq.get(), 2);
        assert_eq!(page.next_event_seq.get(), 2);
        assert_ne!(page.next_event_seq.get(), 3);

        let too_small = encoded_len(&topology(1, None)).expect("one") - 1;
        assert_eq!(
            project_events_wait(
                U::new(0).expect("after"),
                1,
                0,
                &[topology(1, None)],
                |_| true,
                too_small.max(0),
            )
            .unwrap_err(),
            ErrorCode::ResourceExhausted
        );
    }

    #[test]
    fn hidden_events_may_advance_scan_but_foreign_is_not_gap() {
        let a = project('a');
        let b = project('b');
        let log = [
            topology(1, Some(b.clone())),
            topology(2, Some(b.clone())),
            topology(3, Some(a.clone())),
        ];
        let grants = [a];
        let page = project_events_wait(
            U::new(0).expect("after"),
            3,
            0,
            &log,
            |event| event_passes_grant(event, None, &grants, false, false),
            events_envelope_budget(),
        )
        .expect("visible after hidden");
        assert_eq!(page.status, WaitStatus::Events);
        assert_eq!(page.events.len(), 1);
        assert_eq!(page.events[0].event_seq.get(), 3);
        assert_eq!(page.next_event_seq.get(), 3);

        let none = project_events_wait(
            U::new(0).expect("after"),
            2,
            0,
            &log[..2],
            |event| event_passes_grant(event, None, &grants, false, false),
            events_envelope_budget(),
        )
        .expect("all foreign");
        assert_eq!(none.status, WaitStatus::NoChange);
        assert!(none.events.is_empty());
        assert_eq!(none.next_event_seq.get(), 2);
    }

    #[test]
    fn public_run_state_without_project_does_not_leak() {
        let run_event = MetadataEvent {
            event_seq: U::new(1).expect("seq"),
            observed_at: stamp(),
            data: EventData::RunStateChanged {
                run: crate::contract::RunObservation {
                    run_id: run('1'),
                    pane_id: PaneId::new("40000000-0000-4000-8000-000000000001").expect("pane"),
                    process: crate::contract::Process::Running,
                    work: crate::contract::Work::Unknown,
                    evidence: crate::contract::Evidence::Unavailable,
                    observed_at: stamp(),
                    current: true,
                    exit_code: Nullable(None),
                },
            },
        };
        assert!(!event_passes_grant(
            &run_event,
            None,
            &[project('a')],
            false,
            false
        ));
        assert!(event_passes_grant(
            &run_event,
            Some(&project('a')),
            &[project('a')],
            false,
            false
        ));
        assert!(!event_passes_grant(
            &run_event,
            Some(&project('b')),
            &[project('a')],
            false,
            false
        ));
    }
}
