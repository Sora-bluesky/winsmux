//! Protocol adapter over RunIoOwner. No second occupancy registry.
//!
//! Authorization admits, then calls enqueue -> admit -> (revalidate) ->
//! issue with locks dropped -> seal the protocol terminal -> finish.
//! `finish_after_terminal` is the only Free transition this adapter invokes.
//! `run.interrupt` joins StopLane and must not call `RuntimeService::deliver_ctrl_c`.
//!
//! Missing interface: `RuntimeService::finish_data` does not return the committed
//! `input_seq`. Callers pass that seq into `input_write_data` / `input_key_data`
//! after finish. Do not invent a parallel counter here.

use crate::contract::{
    AcceptedPhase, ErrorCode, Evidence, ExitCode, InputKey, InputKeyData, InputWriteData,
    Nullable, OneByte, OperationGetData, OperationId, OperationPhase, OperationStatus, P, PaneId,
    Process, RunGetData, RunId, RunInterruptData, RunObservation, Timestamp, True, U, Work,
};
use crate::runtime::session::now_timestamp;
use crate::runtime::{RunDataKind, RunDataTicket, RunNativeOutcome, RuntimeService};

/// ConPTY bytes for `input.key`. Enter is CR once (A-ENTER-BYTE); do not retry LF.
pub fn key_byte(key: InputKey) -> u8 {
    match key {
        InputKey::Enter => 0x0D,
        InputKey::Tab => 0x09,
        InputKey::Escape => 0x1B,
        InputKey::Interrupt => 0x03,
    }
}

pub fn key_payload(key: InputKey) -> [u8; 1] {
    [key_byte(key)]
}

pub fn hpcon_size(cols: u64, rows: u64) -> Result<(i16, i16), ErrorCode> {
    if !(1..=32767).contains(&cols) || !(1..=32767).contains(&rows) {
        return Err(ErrorCode::InvalidRequest);
    }
    Ok((cols as i16, rows as i16))
}

pub fn enqueue_write(
    runtime: &RuntimeService,
    run_id: &RunId,
    text: &str,
) -> Result<RunDataTicket, ErrorCode> {
    runtime.enqueue_data(run_id, RunDataKind::Write, text.len())
}

pub fn enqueue_key(
    runtime: &RuntimeService,
    run_id: &RunId,
    _key: InputKey,
) -> Result<RunDataTicket, ErrorCode> {
    runtime.enqueue_data(run_id, RunDataKind::Key, 1)
}

pub fn enqueue_resize(
    runtime: &RuntimeService,
    run_id: &RunId,
    cols: u64,
    rows: u64,
) -> Result<RunDataTicket, ErrorCode> {
    let _ = hpcon_size(cols, rows)?;
    runtime.enqueue_data(run_id, RunDataKind::Resize, 0)
}

pub fn admit_fifo(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
) -> Result<(), ErrorCode> {
    runtime.admit_data(run_id, ticket)
}

/// Native WriteFile with auth/runtime/run locks already dropped by RunIoOwner.
/// `Ok` => DataSlot::Sealing; seal the terminal, then `finish_after_terminal`.
/// `Err(StateUnknown)` after a pin retains native ownership. The protocol
/// terminal still seals under the original ticket; the slot is freed only
/// after both native completion and protocol sealing.
/// `Err(InvalidRequest)` => Sealing; seal the error, then finish.
pub fn issue_write(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
    payload: &[u8],
) -> Result<RunNativeOutcome, ErrorCode> {
    runtime.issue_write(run_id, ticket, payload)
}

/// Native ResizePseudoConsole with locks dropped. No EventAccounting credit.
pub fn issue_resize(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
    cols: u64,
    rows: u64,
) -> Result<RunNativeOutcome, ErrorCode> {
    let (cols, rows) = hpcon_size(cols, rows)?;
    runtime.issue_resize(run_id, ticket, cols, rows)
}

/// Occupancy stays with the original ticket until the caller seals its terminal.
pub fn finish_after_terminal(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
) -> Result<(), ErrorCode> {
    runtime.finish_data(run_id, ticket)
}

pub fn cancel_fifo(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
) -> Result<(), ErrorCode> {
    runtime.cancel_data(run_id, ticket)
}

/// StopLane only: sets StopFlag, cancels an exact pin, returns immediately.
/// Does not wait DataSlot, does not issue 0x03, does not call deliver_ctrl_c.
/// `Ok(false)` is not_running. Caller publishes, seals, drops locks, then
/// `queue_stop_cleanup`.
pub fn admit_stop_lane(
    runtime: &RuntimeService,
    run_id: &RunId,
) -> Result<bool, ErrorCode> {
    runtime.admit_interrupt(run_id)
}

pub fn queue_stop_cleanup(runtime: &RuntimeService, run_id: &RunId) {
    runtime.queue_cleanup(run_id);
}

pub fn occupancy_blocks_close(runtime: &RuntimeService, run_id: &RunId) -> bool {
    runtime.occupancy_blocks_close(run_id)
}

pub fn close_blocked_for_runs<'a>(
    runtime: &RuntimeService,
    runs: impl IntoIterator<Item = &'a RunId>,
) -> bool {
    runs.into_iter().any(|run| occupancy_blocks_close(runtime, run))
}

pub fn delivered_written_bytes(
    outcome: RunNativeOutcome,
    payload_len: usize,
) -> Result<u64, ErrorCode> {
    match outcome {
        RunNativeOutcome::Delivered { written } if written as usize == payload_len => {
            Ok(u64::from(written))
        }
        _ => Err(ErrorCode::StateUnknown),
    }
}

fn seq_p(input_seq: u64) -> Result<P, ErrorCode> {
    P::new(input_seq).map_err(|_| ErrorCode::ResourceExhausted)
}

fn bytes_u(written_bytes: u64) -> Result<U, ErrorCode> {
    U::new(written_bytes).map_err(|_| ErrorCode::ResourceExhausted)
}

pub fn input_write_data(
    pane_id: PaneId,
    run_id: RunId,
    input_seq: u64,
    written_bytes: u64,
) -> Result<InputWriteData, ErrorCode> {
    Ok(InputWriteData {
        pane_id,
        run_id,
        input_seq: seq_p(input_seq)?,
        written_bytes: bytes_u(written_bytes)?,
    })
}

pub fn input_key_data(
    pane_id: PaneId,
    run_id: RunId,
    input_seq: u64,
    key: InputKey,
) -> Result<InputKeyData, ErrorCode> {
    Ok(InputKeyData {
        pane_id,
        run_id,
        input_seq: seq_p(input_seq)?,
        key,
        sent: True,
        written_bytes: OneByte::new(1).expect("OneByte is 1..=1"),
    })
}

pub fn interrupt_accepted(run_id: RunId) -> RunInterruptData {
    RunInterruptData {
        run_id,
        phase: AcceptedPhase::Accepted,
    }
}

pub fn map_run_observation(
    run_id: RunId,
    pane_id: PaneId,
    process: Process,
    work: Work,
    exit_code: Option<u32>,
    current: bool,
) -> RunObservation {
    let exited = matches!(process, Process::Exited);
    RunObservation {
        run_id,
        pane_id,
        process,
        work: if exited {
            work
        } else {
            Work::Unknown
        },
        evidence: if exited {
            Evidence::ProcessExit
        } else {
            Evidence::Unavailable
        },
        observed_at: now_timestamp().unwrap_or_else(|| {
            Timestamp::new("1970-01-01T00:00:00.000Z").expect("epoch")
        }),
        current,
        exit_code: Nullable(if exited {
            exit_code.and_then(|value| ExitCode::new(value as i32).ok())
        } else {
            None
        }),
    }
}

pub fn run_get_data(
    run_id: RunId,
    pane_id: PaneId,
    process: Process,
    work: Work,
    exit_code: Option<u32>,
    current: bool,
) -> RunGetData {
    RunGetData {
        cleanup_complete: None,
        run: map_run_observation(run_id, pane_id, process, work, exit_code, current),
    }
}

/// Cleanup can finish after an earlier running observation. That response
/// remains conservatively unconfirmed; a fresh read can confirm both facts.
pub(crate) fn cleanup_confirmed(process: Process, session_clean: bool) -> bool {
    process == Process::Exited && session_clean
}

pub fn operation_get_unknown(operation_id: OperationId) -> OperationGetData {
    OperationGetData {
        operation: OperationStatus {
            operation_id,
            phase: OperationPhase::Unknown,
            outcome: Nullable(None),
            error_code: Nullable(None),
        },
    }
}

pub fn reject_unissued(
    runtime: &RuntimeService,
    run_id: &RunId,
    ticket: RunDataTicket,
) -> Result<(), ErrorCode> {
    match runtime.reject_unissued(run_id, ticket) {
        Ok(()) | Err(ErrorCode::StateUnknown) => {
            let _ = runtime.finish_data(run_id, ticket);
            Ok(())
        }
        Err(code) => Err(code),
    }
}

pub fn operation_get_completed(
    operation_id: OperationId,
    outcome: crate::contract::Outcome,
    error_code: Option<ErrorCode>,
) -> OperationGetData {
    OperationGetData {
        operation: OperationStatus {
            operation_id,
            phase: OperationPhase::Completed,
            outcome: Nullable(Some(outcome)),
            error_code: Nullable(error_code),
        },
    }
}

pub fn operation_get_in_progress(operation_id: OperationId) -> OperationGetData {
    OperationGetData {
        operation: OperationStatus {
            operation_id,
            phase: OperationPhase::InProgress,
            outcome: Nullable(None),
            error_code: Nullable(None),
        },
    }
}

#[cfg(test)]
mod adapter_boundary_tests {
    use super::*;
    use crate::contract::{PaneId, ProjectId};
    use crate::runtime::TestingDataSlot;

    fn ids() -> (ProjectId, PaneId, RunId) {
        (
            ProjectId::new("30000000-0000-4000-8000-00000000af21").expect("p"),
            PaneId::new("40000000-0000-4000-8000-00000000af21").expect("pane"),
            RunId::new("50000000-0000-4000-8000-00000000af21").expect("run"),
        )
    }

    fn preparing() -> (RuntimeService, RunId) {
        let runtime = RuntimeService::new();
        let (project, pane, run) = ids();
        runtime
            .insert_preparing(project, pane, run.clone())
            .expect("prep");
        (runtime, run)
    }

    #[test]
    fn key_bytes_are_single_conpty_bytes_and_interrupt_is_data_etx() {
        assert_eq!(key_byte(InputKey::Enter), 0x0D);
        assert_eq!(key_byte(InputKey::Tab), 0x09);
        assert_eq!(key_byte(InputKey::Escape), 0x1B);
        assert_eq!(key_byte(InputKey::Interrupt), 0x03);
        assert_eq!(key_payload(InputKey::Enter), [0x0D]);
        assert_eq!(key_payload(InputKey::Interrupt).len(), 1);
    }

    #[test]
    fn resize_rejects_zero_and_values_above_32767_before_enqueue() {
        assert_eq!(hpcon_size(0, 24).unwrap_err(), ErrorCode::InvalidRequest);
        assert_eq!(hpcon_size(80, 32768).unwrap_err(), ErrorCode::InvalidRequest);
        assert_eq!(hpcon_size(1, 32767).expect("bounds"), (1, 32767));
        let (runtime, run) = preparing();
        assert_eq!(
            enqueue_resize(&runtime, &run, 0, 24).unwrap_err(),
            ErrorCode::InvalidRequest
        );
        assert!(
            runtime
                .testing_input_stats(&run)
                .expect("stats")
                .fifo_ids
                .is_empty()
        );
    }

    #[test]
    fn enqueue_write_and_key_are_run_bound_without_issue_or_stop_flag() {
        let (runtime, run) = preparing();
        let text = "あ";
        assert_eq!(text.len(), 3);
        let write = enqueue_write(&runtime, &run, text).expect("write ticket");
        let key = enqueue_key(&runtime, &run, InputKey::Interrupt).expect("key ticket");
        assert_ne!(write, key);
        let stats = runtime.testing_input_stats(&run).expect("stats");
        assert_eq!(stats.fifo_ids, vec![write.as_u64(), key.as_u64()]);
        assert_eq!(stats.data_slot, TestingDataSlot::Free);
        assert_eq!(stats.input_seq, 0);
        assert!(!stats.stop_flag);
        assert!(!stats.teardown_ctrl_reserved);
        assert_eq!(
            admit_stop_lane(&runtime, &run).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert!(!runtime
            .testing_input_stats(&run)
            .expect("stats")
            .stop_flag);
    }

    #[test]
    fn empty_write_enqueues_zero_payload_without_native_issue() {
        let (runtime, run) = preparing();
        let ticket = enqueue_write(&runtime, &run, "").expect("empty");
        let stats = runtime.testing_input_stats(&run).expect("stats");
        assert_eq!(stats.fifo_ids, vec![ticket.as_u64()]);
        assert_eq!(stats.data_slot, TestingDataSlot::Free);
        assert_eq!(
            delivered_written_bytes(RunNativeOutcome::Delivered { written: 0 }, 0).expect("empty"),
            0
        );
    }

    #[test]
    fn partial_or_aborted_native_outcome_is_state_unknown_not_success() {
        assert_eq!(
            delivered_written_bytes(RunNativeOutcome::Delivered { written: 1 }, 3).unwrap_err(),
            ErrorCode::StateUnknown
        );
        assert_eq!(
            delivered_written_bytes(RunNativeOutcome::Aborted, 1).unwrap_err(),
            ErrorCode::StateUnknown
        );
        assert_eq!(
            delivered_written_bytes(RunNativeOutcome::IoFailed, 1).unwrap_err(),
            ErrorCode::StateUnknown
        );
        assert_eq!(
            delivered_written_bytes(RunNativeOutcome::Delivered { written: 3 }, 3).expect("full"),
            3
        );
    }

    #[test]
    fn running_observation_cannot_advertise_work_or_exit() {
        let (_, pane, run) = ids();
        let mapped = map_run_observation(
            run.clone(),
            pane.clone(),
            Process::Running,
            Work::Succeeded,
            Some(0),
            true,
        );
        assert_eq!(mapped.work, Work::Unknown);
        assert_eq!(mapped.evidence, Evidence::Unavailable);
        assert!(mapped.exit_code.0.is_none());
        let exited = map_run_observation(
            run,
            pane,
            Process::Exited,
            Work::Unknown,
            Some(0),
            false,
        );
        assert_eq!(exited.work, Work::Unknown);
        assert_eq!(exited.evidence, Evidence::ProcessExit);
        assert_eq!(exited.exit_code.0.map(|code| code.get()), Some(0));
    }

    #[test]
    fn operation_get_bodies_have_no_text_and_vacant_is_unknown() {
        let id = OperationId::new("10000000-0000-4000-8000-00000000af21").expect("op");
        let vacant = operation_get_unknown(id.clone());
        assert_eq!(vacant.operation.phase, OperationPhase::Unknown);
        assert!(vacant.operation.outcome.0.is_none());
        assert!(vacant.operation.error_code.0.is_none());
        let inflight = operation_get_in_progress(id);
        assert_eq!(inflight.operation.phase, OperationPhase::InProgress);
        assert!(inflight.operation.outcome.0.is_none());
    }

    #[test]
    fn input_seq_zero_cannot_be_a_visible_p_value() {
        let (_, pane, run) = ids();
        assert_eq!(
            input_write_data(pane.clone(), run.clone(), 0, 0).unwrap_err(),
            ErrorCode::ResourceExhausted
        );
        let body = input_write_data(pane, run, 1, 0).expect("empty delivery seq 1");
        assert_eq!(body.input_seq.get(), 1);
        assert_eq!(body.written_bytes.get(), 0);
    }

    #[test]
    fn foreign_ticket_cancel_does_not_clear_this_run_fifo() {
        let runtime = RuntimeService::new();
        let (project, pane, run_a) = ids();
        let run_b = RunId::new("50000000-0000-4000-8000-00000000af22").expect("run b");
        runtime
            .insert_preparing(project.clone(), pane.clone(), run_a.clone())
            .expect("a");
        runtime
            .insert_preparing(project, pane, run_b.clone())
            .expect("b");
        let ticket_a = enqueue_write(&runtime, &run_a, "x").expect("a");
        let ticket_b = enqueue_key(&runtime, &run_b, InputKey::Tab).expect("b");
        assert_eq!(
            cancel_fifo(&runtime, &run_b, ticket_a).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert_eq!(
            runtime
                .testing_input_stats(&run_a)
                .expect("a")
                .fifo_ids,
            vec![ticket_a.as_u64()]
        );
        assert_eq!(
            runtime
                .testing_input_stats(&run_b)
                .expect("b")
                .fifo_ids,
            vec![ticket_b.as_u64()]
        );
    }
}
    #[test]
    fn cleanup_read_confirms_both_observation_and_complete_runtime_predicate() {
        for process in Process::ALL {
            for clean in [false, true] {
                assert_eq!(cleanup_confirmed(*process, clean), *process == Process::Exited && clean);
            }
        }
        // Earlier running observation, followed by worker completion: the
        // later fresh exit read, not the earlier read, can confirm both facts.
        assert!(!cleanup_confirmed(Process::Running, true));
        assert!(cleanup_confirmed(Process::Exited, true));
    }
