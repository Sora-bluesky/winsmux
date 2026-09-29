//! Owned pane session: HANDLE wait, UTF-8 drain, 0x03 delivery, cleanup.
//!
//! Native WriteFile / ResizePseudoConsole / CloseHandle / ClosePseudoConsole
//! for one run share the private owner below. Caller seals the operation
//! terminal before `finish_data`; Free is never assigned first.

use super::spawn::{
    classify_readfile, duplicate_handle, exit_code, handle_signaled, issue_write_byte,
    issue_write_bytes, job_active_processes, resize_pseudoconsole, retain_write, IssueStart,
    PinnedWrite, PreparedChild, RawHandle, ReadClass, WriteIdentity, WriteResult,
};
use crate::contract::{
    ErrorCode, PaneId, Process, ProjectId, RunId, Timestamp, Work, MAX_MESSAGE_BYTES, P,
};
use crate::store::root_identity::ObservedRoot;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_ACCESS_DENIED, ERROR_NO_DATA, HANDLE, INVALID_HANDLE_VALUE,
    WAIT_OBJECT_0,
};
use windows_sys::Win32::Storage::FileSystem::ReadFile;
use windows_sys::Win32::System::JobObjects::TerminateJobObject;
use windows_sys::Win32::System::Threading::{WaitForSingleObject, INFINITE};

#[derive(Clone, Copy)]
pub(crate) struct SendHandle(pub HANDLE);
unsafe impl Send for SendHandle {}
unsafe impl Sync for SendHandle {}

#[derive(Clone, Copy)]
pub(crate) struct SendHpcon(pub windows_sys::Win32::System::Console::HPCON);
unsafe impl Send for SendHpcon {}
unsafe impl Sync for SendHpcon {}

const CTRL_C: u8 = 0x03;
const OWNER_INTERRUPT_EXIT_CODE: u32 = 0xC000_013A;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum JobTermination {
    Natural,
    OwnerRequested,
    OwnerApiSucceeded,
    OwnerApiFailed(u32),
}

struct JobOwnerState {
    handle: RawHandle,
    termination: JobTermination,
    containment: bool,
    #[cfg(debug_assertions)]
    attempts: u32,
    #[cfg(debug_assertions)]
    fail_terminate_once: bool,
}

struct JobOwner {
    state: Mutex<JobOwnerState>,
}

impl JobOwner {
    fn new() -> Self {
        Self {
            state: Mutex::new(JobOwnerState {
                handle: RawHandle::invalid(),
                termination: JobTermination::Natural,
                containment: false,
                #[cfg(debug_assertions)]
                attempts: 0,
                #[cfg(debug_assertions)]
                fail_terminate_once: false,
            }),
        }
    }

    fn install(&self, handle: RawHandle) {
        let mut state = self.state.lock().expect("job owner");
        assert!(!state.handle.is_valid(), "job owner installed once");
        assert!(!state.containment, "contained job owner cannot be installed");
        state.handle = handle;
    }

    fn active_processes(&self) -> Option<u32> {
        let state = self.state.lock().ok()?;
        if !state.handle.is_valid() {
            return None;
        }
        job_active_processes(state.handle.0)
    }

    fn is_empty(&self) -> bool {
        let Ok(state) = self.state.lock() else {
            return false;
        };
        if !state.handle.is_valid() {
            return true;
        }
        job_active_processes(state.handle.0).is_some_and(|active| active == 0)
    }

    fn terminate_for_owner_interrupt(&self) -> JobTermination {
        let mut state = self.state.lock().expect("job owner");
        if state.containment || !matches!(state.termination, JobTermination::Natural) {
            return state.termination;
        }
        if !state.handle.is_valid() {
            state.termination = JobTermination::OwnerApiFailed(ERROR_NO_DATA);
            return state.termination;
        }
        state.termination = JobTermination::OwnerRequested;
        #[cfg(debug_assertions)]
        {
            state.attempts += 1;
        }
        #[cfg(debug_assertions)]
        let (result, injected_error) = if std::mem::take(&mut state.fail_terminate_once) {
            (0, Some(ERROR_ACCESS_DENIED))
        } else {
            (
                unsafe { TerminateJobObject(state.handle.0, OWNER_INTERRUPT_EXIT_CODE) },
                None,
            )
        };
        #[cfg(not(debug_assertions))]
        let (result, injected_error) = (
            unsafe { TerminateJobObject(state.handle.0, OWNER_INTERRUPT_EXIT_CODE) },
            None,
        );
        state.termination = if result != 0 {
            JobTermination::OwnerApiSucceeded
        } else {
            let error = injected_error.unwrap_or_else(|| unsafe { GetLastError() });
            JobTermination::OwnerApiFailed(error)
        };
        state.termination
    }

    fn take_for_containment(&self) -> HANDLE {
        let mut state = self.state.lock().expect("job owner");
        state.containment = true;
        state.handle.take()
    }

    fn clean_termination(&self, force_killed: bool) -> bool {
        let Ok(state) = self.state.lock() else {
            return false;
        };
        !state.containment
            && matches!(
                (force_killed, state.termination),
                (false, JobTermination::Natural)
                    | (false, JobTermination::OwnerApiFailed(_))
                    | (true, JobTermination::OwnerApiSucceeded)
            )
    }

    #[cfg(debug_assertions)]
    fn fail_terminate_once(&self) {
        let mut state = self.state.lock().expect("job owner");
        state.fail_terminate_once = true;
    }

    #[cfg(debug_assertions)]
    fn testing_stats(&self) -> (u32, bool, bool, bool, Option<u32>, Option<u32>) {
        let state = self.state.lock().expect("job owner");
        let (succeeded, failed, error) = match state.termination {
            JobTermination::OwnerApiSucceeded => (true, false, None),
            JobTermination::OwnerApiFailed(error) => (false, true, Some(error)),
            JobTermination::Natural | JobTermination::OwnerRequested => (false, false, None),
        };
        let active = if state.handle.is_valid() {
            job_active_processes(state.handle.0)
        } else {
            None
        };
        (
            state.attempts,
            succeeded,
            failed,
            state.containment,
            error,
            active,
        )
    }

    #[cfg(debug_assertions)]
    fn inspect_single_member(&self, process: HANDLE) -> Result<(), ErrorCode> {
        let state = self.state.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        if state.containment || !state.handle.is_valid() {
            return Err(ErrorCode::RuntimeFailed);
        }
        let mut member = 0;
        // The job owner keeps this exact, unshared job HANDLE alive.
        let ok = unsafe {
            windows_sys::Win32::System::JobObjects::IsProcessInJob(
                process,
                state.handle.0,
                &mut member,
            )
        };
        if ok == 0 || member == 0 || job_active_processes(state.handle.0) != Some(1) {
            return Err(ErrorCode::RuntimeFailed);
        }
        Ok(())
    }

    #[cfg(debug_assertions)]
    fn inspect_ownership(&self) -> Result<(bool, Option<u32>), ErrorCode> {
        let state = self.state.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let active = if state.handle.is_valid() {
            Some(job_active_processes(state.handle.0).ok_or(ErrorCode::RuntimeFailed)?)
        } else {
            None
        };
        Ok((state.containment, active))
    }

}

#[cfg(all(test, debug_assertions))]
mod cleanup_observer_job_tests {
    use super::*;

    #[test]
    fn cleanup_observer_job_poison_is_never_recovered_or_reported_empty() {
        let job = Arc::new(JobOwner::new());
        let other = Arc::clone(&job);
        assert!(thread::spawn(move || {
            let _guard = other.state.lock().unwrap();
            panic!("intentional observation job poison");
        })
        .join()
        .is_err());
        assert_eq!(job.inspect_ownership(), Err(ErrorCode::RuntimeFailed));
        assert_eq!(
            job.inspect_single_member(INVALID_HANDLE_VALUE),
            Err(ErrorCode::RuntimeFailed)
        );
        assert!(job.state.is_poisoned());
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionPhase {
    Preparing,
    Published,
    Failed,
}

/// Opaque FIFO / DataSlot occupant. Identity only; never retargeted.
/// Bound to the run that issued it; a ticket from another run is rejected.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct DataTicket {
    id: u64,
    run_token: u64,
    operation_key: Option<[u8; 36]>,
}

impl DataTicket {
    pub fn as_u64(self) -> u64 {
        self.id
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DataKind {
    Write,
    Key,
    Resize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeOutcome {
    Delivered { written: u32 },
    Aborted,
    IoFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TestingDataSlot {
    Free,
    Admitted,
    Pinned,
    HpconBusy,
    Sealing,
    RetainedUnknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TestingRunIoStats {
    pub input_seq: u64,
    pub fifo_ids: Vec<u64>,
    pub fifo_head_id: Option<u64>,
    pub data_slot: TestingDataSlot,
    pub teardown_ctrl_reserved: bool,
    pub stop_flag: bool,
    pub input_lease_count: u32,
    pub hpcon_lease_count: u32,
    pub write_pending: bool,
    pub pty_closed: bool,
    pub input_sealed: bool,
    pub hpcon_sealed: bool,
    pub input_handle_present: bool,
    pub hpcon_handle_present: bool,
    #[cfg(debug_assertions)]
    pub generated_hpcon: Option<usize>,
    #[cfg(debug_assertions)]
    pub close_target_hpcon: Option<usize>,
    #[cfg(debug_assertions)]
    pub close_target_matches_generated: Option<bool>,
    #[cfg(debug_assertions)]
    pub close_skip_native_io: Option<bool>,
    #[cfg(debug_assertions)]
    pub close_native_entered: bool,
    #[cfg(debug_assertions)]
    pub close_native_returned: bool,
    #[cfg(debug_assertions)]
    pub close_output_bytes: Option<usize>,
}

/// Test evidence must not run the production lease reaper while observing it.
#[cfg(debug_assertions)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestingCleanupIoSnapshot {
    pub input_lease_count: u32,
    pub hpcon_lease_count: u32,
    pub input_leases: Vec<(u64, u64)>,
    pub hpcon_leases: Vec<(u64, u64)>,
    pub input_handle_present: bool,
    pub hpcon_handle_present: bool,
    pub write_pending: bool,
    pub pin_present: bool,
    pub pin_finalizing: bool,
    pub pin_cancel_requested: bool,
    pub pty_closed: bool,
    pub fifo: Vec<(u64, bool)>,
    pub stop_flag: bool,
}

pub struct OutputRing {
    decoded: Vec<u8>,
    start_cursor: u64,
    hold: Vec<u8>,
    gap: bool,
}

impl OutputRing {
    pub fn new() -> Self {
        Self {
            decoded: Vec::new(),
            start_cursor: 0,
            hold: Vec::new(),
            gap: false,
        }
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_tail_shape(&self) -> String {
        let start = self.decoded.len().saturating_sub(256);
        let mut shape = String::new();
        let mut last_class = None;
        for byte in &self.decoded[start..] {
            let class = if byte.is_ascii_alphabetic() {
                b'A'
            } else if byte.is_ascii_digit() {
                b'0'
            } else if *byte >= 0x80 {
                b'U'
            } else {
                *byte
            };
            if matches!(class, b'A' | b'0' | b'U') && last_class == Some(class) {
                continue;
            }
            match class {
                b'\r' => shape.push_str("\\r"),
                b'\n' => shape.push_str("\\n"),
                b'\t' => shape.push_str("\\t"),
                0x1b => shape.push_str("\\x1b"),
                value if value.is_ascii_graphic() || value == b' ' => shape.push(value as char),
                value => shape.push_str(&format!("\\x{value:02x}")),
            }
            last_class = Some(class);
        }
        shape
    }

    pub fn push_bytes(&mut self, chunk: &[u8], eof: bool) {
        self.hold.extend_from_slice(chunk);
        loop {
            match std::str::from_utf8(&self.hold) {
                Ok(text) => {
                    self.decoded.extend_from_slice(text.as_bytes());
                    self.hold.clear();
                    break;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    if valid > 0 {
                        self.decoded.extend_from_slice(&self.hold[..valid]);
                        self.hold.drain(..valid);
                        continue;
                    }
                    let Some(len) = error.error_len() else {
                        if eof {
                            self.decoded.extend_from_slice("\u{FFFD}".as_bytes());
                            self.hold.clear();
                            self.gap = true;
                        }
                        break;
                    };
                    self.decoded.extend_from_slice("\u{FFFD}".as_bytes());
                    self.hold.drain(..len);
                    self.gap = true;
                }
            }
        }
        const RETAIN: usize = MAX_MESSAGE_BYTES;
        if self.decoded.len() > RETAIN {
            let overflow = self.decoded.len() - RETAIN;
            let mut drop_at = overflow;
            while drop_at < self.decoded.len() && self.decoded[drop_at] & 0b1100_0000 == 0b1000_0000
            {
                drop_at += 1;
            }
            self.decoded.drain(..drop_at);
            self.start_cursor = self.start_cursor.saturating_add(drop_at as u64);
            self.gap = true;
        }
    }

    pub fn decoded_len(&self) -> usize {
        self.decoded.len()
    }

    pub fn snapshot(
        &self,
        cursor: Option<u64>,
        max_bytes: u64,
        run_id: &str,
        request_run: &str,
    ) -> ReadSlice {
        if run_id != request_run {
            return ReadSlice {
                text: String::new(),
                next_cursor: self.start_cursor,
                origin: self.start_cursor,
                gap: true,
                truncated: false,
            };
        }
        let cursor = cursor.unwrap_or(self.start_cursor);
        if cursor < self.start_cursor {
            return self.emit_from(self.start_cursor, max_bytes, true);
        }
        if cursor > self.start_cursor + self.decoded.len() as u64 {
            return ReadSlice {
                text: String::new(),
                next_cursor: cursor,
                origin: cursor,
                gap: true,
                truncated: false,
            };
        }
        self.emit_from(cursor, max_bytes, false)
    }

    fn emit_from(&self, cursor: u64, max_bytes: u64, forced_gap: bool) -> ReadSlice {
        let offset = (cursor - self.start_cursor) as usize;
        let remaining = &self.decoded[offset..];
        let mut take = remaining.len().min(max_bytes as usize);
        while take > 0 && !utf8_boundary(remaining, take) {
            take -= 1;
        }
        let text = if take == 0 {
            String::new()
        } else {
            String::from_utf8(remaining[..take].to_vec()).unwrap_or_default()
        };
        let truncated = take < remaining.len();
        ReadSlice {
            text,
            next_cursor: cursor + take as u64,
            origin: cursor,
            gap: forced_gap || (self.gap && cursor == self.start_cursor),
            truncated,
        }
    }
}

fn utf8_boundary(bytes: &[u8], index: usize) -> bool {
    index == 0 || index == bytes.len() || bytes[index] & 0b1100_0000 != 0b1000_0000
}

pub struct ReadSlice {
    pub text: String,
    pub next_cursor: u64,
    pub origin: u64,
    pub gap: bool,
    pub truncated: bool,
}

pub fn json_string_len(text: &str) -> usize {
    let mut n = 2usize;
    for ch in text.chars() {
        n += match ch {
            '"' | '\\' => 2,
            '\u{0008}' | '\u{000c}' | '\n' | '\r' | '\t' => 2,
            ch if (ch as u32) < 0x20 => 6,
            ch => ch.len_utf8(),
        };
    }
    n
}

pub fn clamp_text_to_envelope(
    text: &str,
    max_bytes: u64,
    envelope_budget: usize,
) -> (String, bool) {
    if text.is_empty() {
        return (String::new(), false);
    }
    let mut lo = 0usize;
    let mut hi = text.len();
    let mut best = 0usize;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        let Some((idx, _)) = text.char_indices().nth(mid).or_else(|| {
            if mid == 0 {
                None
            } else {
                Some((text.len(), '\0'))
            }
        }) else {
            break;
        };
        let candidate = &text[..idx.min(text.len())];
        let utf8 = candidate.len() as u64;
        let escaped = json_string_len(candidate);
        if utf8 <= max_bytes && escaped <= envelope_budget {
            best = candidate.len();
            if mid == text.chars().count() {
                break;
            }
            lo = mid + 1;
        } else if mid == 0 {
            best = 0;
            break;
        } else {
            hi = mid - 1;
        }
    }
    while best > 0 && !text.is_char_boundary(best) {
        best -= 1;
    }
    let truncated = best < text.len();
    (text[..best].to_string(), truncated)
}

mod native_owner {
    use super::{
        DataKind, DataTicket, NativeOutcome, SendHandle, SendHpcon, TestingDataSlot,
        TestingRunIoStats, CTRL_C,
    };
    use crate::contract::ErrorCode;
    use crate::contract::P;
    use crate::runtime::spawn::{
        issue_pending_overlapped_write, issue_write_byte, issue_write_bytes,
        resize_pseudoconsole, retain_write, IoObservation, IssueStart, PinnedWrite, WriteIdentity,
        WriteResult,
    };
    use std::cell::Cell;
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Condvar, Mutex, MutexGuard};
    #[cfg(debug_assertions)]
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Console::{ClosePseudoConsole, HPCON};

    const ST_LIVE: u64 = 0;
    const ST_CONSUMED: u64 = 1;
    const ST_ABANDONED: u64 = 2;

    thread_local! {
        static RUN_HELD: Cell<usize> = const { Cell::new(0) };
    }

    static NATIVE_LOCK_VIOLATIONS: AtomicU64 = AtomicU64::new(0);
    static NEXT_RUN_TOKEN: AtomicU64 = AtomicU64::new(1);

    pub(super) fn run_held() -> usize {
        RUN_HELD.with(Cell::get)
    }
    fn enter_run() {
        RUN_HELD.with(|c| c.set(c.get() + 1));
    }
    fn leave_run() {
        RUN_HELD.with(|c| c.set(c.get().saturating_sub(1)));
    }

    pub(super) fn native_lock_violation_count() -> u64 {
        NATIVE_LOCK_VIOLATIONS.load(Ordering::SeqCst)
    }
    #[cfg(test)]
    pub(super) fn test_native_issues(bundle: &RunBundle) -> u64 {
        bundle.test_native_issues.load(Ordering::SeqCst)
    }

    fn native_window<R>(f: impl FnOnce() -> R) -> R {
        if run_held() > 0 {
            NATIVE_LOCK_VIOLATIONS.fetch_add(1, Ordering::SeqCst);
        }
        f()
    }

    fn next_input_seq(current: u64) -> Result<u64, ErrorCode> {
        let next = current.checked_add(1).ok_or(ErrorCode::ResourceExhausted)?;
        P::new(next)
            .map(|_| next)
            .map_err(|_| ErrorCode::ResourceExhausted)
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum LeaseKind {
        Input,
        Hpcon,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum Admission {
        Open,
        Sealed,
    }

    /// Pin/overlapped stay integer identities; HANDLE bits use SendHandle so
    /// RunControl remains Send without marking the whole owner Send.
    #[derive(Clone, Copy)]
    struct SendWriteIdentity {
        pin: usize,
        overlapped: usize,
        event: SendHandle,
        file: SendHandle,
    }

    impl SendWriteIdentity {
        fn from_identity(id: WriteIdentity) -> Self {
            Self {
                pin: id.pin,
                overlapped: id.overlapped,
                event: SendHandle(id.event),
                file: SendHandle(id.file),
            }
        }

        fn matches(self, other: Self) -> bool {
            self.pin == other.pin
                && self.overlapped == other.overlapped
                && self.event.0 == other.event.0
                && self.file.0 == other.file.0
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum PinRole {
        Data {
            occupant: u64,
            payload_len: usize,
            kind: DataKind,
            reserved_seq: Option<u64>,
        },
        TeardownCtrl,
    }

    enum DataSlot {
        Free,
        Admitted {
            occupant: u64,
            payload_len: usize,
            kind: DataKind,
            reserved_seq: Option<u64>,
        },
        Pinned {
            occupant: u64,
            payload_len: usize,
            kind: DataKind,
            reserved_seq: Option<u64>,
        },
        HpconBusy {
            occupant: u64,
        },
        Sealing {
            occupant: u64,
            payload_len: usize,
            kind: DataKind,
            reserved_seq: Option<u64>,
            outcome: NativeOutcome,
        },
        RetainedUnknown {
            occupant: u64,
            protocol_sealed: bool,
        },
        UnknownSealPending {
            occupant: u64,
        },
    }

    impl DataSlot {
        fn occupant(&self) -> Option<u64> {
            match *self {
                DataSlot::Free => None,
                DataSlot::Admitted { occupant, .. }
                | DataSlot::Pinned { occupant, .. }
                | DataSlot::HpconBusy { occupant }
                | DataSlot::Sealing { occupant, .. }
                | DataSlot::RetainedUnknown { occupant, .. }
                | DataSlot::UnknownSealPending { occupant } => Some(occupant),
            }
        }

        fn testing(&self) -> TestingDataSlot {
            match self {
                DataSlot::Free => TestingDataSlot::Free,
                DataSlot::Admitted { .. } => TestingDataSlot::Admitted,
                DataSlot::Pinned { .. } => TestingDataSlot::Pinned,
                DataSlot::HpconBusy { .. } => TestingDataSlot::HpconBusy,
                DataSlot::Sealing { .. } => TestingDataSlot::Sealing,
                DataSlot::RetainedUnknown { .. } => TestingDataSlot::RetainedUnknown,
                DataSlot::UnknownSealPending { .. } => TestingDataSlot::Sealing,
            }
        }
    }

    struct FifoEntry {
        ticket: u64,
        operation_key: Option<[u8; 36]>,
        kind: DataKind,
        cancel_requested: bool,
        payload_len: usize,
    }

    struct RunControl {
        data_slot: DataSlot,
        fifo: VecDeque<FifoEntry>,
        stop_flag: bool,
        teardown_ctrl_reserved: bool,
        input_seq: u64,
        input_admission: Admission,
        hpcon_admission: Admission,
        input_lease_count: u32,
        hpcon_lease_count: u32,
        write_pending: bool,
        pty_closed: bool,
        interrupt_admitted: bool,
        input_handle: Option<SendHandle>,
        hpcon_handle: Option<SendHpcon>,
        input_leases: BTreeMap<u64, Arc<AtomicU64>>,
        hpcon_leases: BTreeMap<u64, Arc<AtomicU64>>,
        next_lease_id: u64,
        next_ticket_id: u64,
        pin: Option<PinnedWrite>,
        write_identity: Option<SendWriteIdentity>,
        pin_role: Option<PinRole>,
        pin_finalizing: bool,
        pin_cancel_requested: bool,
        #[cfg(debug_assertions)]
        generated_hpcon: Option<usize>,
        #[cfg(debug_assertions)]
        close_target_hpcon: Option<usize>,
        #[cfg(debug_assertions)]
        close_skip_native_io: Option<bool>,
        #[cfg(debug_assertions)]
        close_native_entered: bool,
        #[cfg(debug_assertions)]
        close_native_returned: bool,
        #[cfg(debug_assertions)]
        close_output_bytes: Option<usize>,
    }

    impl RunControl {
        fn new() -> Self {
            Self {
                data_slot: DataSlot::Free,
                fifo: VecDeque::new(),
                stop_flag: false,
                teardown_ctrl_reserved: false,
                input_seq: 0,
                input_admission: Admission::Open,
                hpcon_admission: Admission::Open,
                input_lease_count: 0,
                hpcon_lease_count: 0,
                write_pending: false,
                pty_closed: false,
                interrupt_admitted: false,
                input_handle: None,
                hpcon_handle: None,
                input_leases: BTreeMap::new(),
                hpcon_leases: BTreeMap::new(),
                next_lease_id: 0,
                next_ticket_id: 0,
                pin: None,
                write_identity: None,
                pin_role: None,
                pin_finalizing: false,
                pin_cancel_requested: false,
                #[cfg(debug_assertions)]
                generated_hpcon: None,
                #[cfg(debug_assertions)]
                close_target_hpcon: None,
                #[cfg(debug_assertions)]
                close_skip_native_io: None,
                #[cfg(debug_assertions)]
                close_native_entered: false,
                #[cfg(debug_assertions)]
                close_native_returned: false,
                #[cfg(debug_assertions)]
                close_output_bytes: None,
            }
        }

        fn reap_kind(&mut self, kind: LeaseKind) -> u32 {
            let (map, count) = match kind {
                LeaseKind::Input => (&mut self.input_leases, &mut self.input_lease_count),
                LeaseKind::Hpcon => (&mut self.hpcon_leases, &mut self.hpcon_lease_count),
            };
            let mut n = 0u32;
            map.retain(|_, state| {
                let live = state.load(Ordering::SeqCst) != ST_ABANDONED;
                if !live {
                    n = n.saturating_add(1);
                    *count = count.saturating_sub(1);
                }
                live
            });
            n
        }

        fn reap_all(&mut self) -> u32 {
            self.reap_kind(LeaseKind::Input) + self.reap_kind(LeaseKind::Hpcon)
        }

        fn alloc_ticket(&mut self) -> Result<u64, ErrorCode> {
            let id = self
                .next_ticket_id
                .checked_add(1)
                .ok_or(ErrorCode::ResourceExhausted)?;
            self.next_ticket_id = id;
            Ok(id)
        }

        fn acquire(&mut self, kind: LeaseKind) -> Result<(u64, Arc<AtomicU64>), ErrorCode> {
            self.reap_all();
            match kind {
                LeaseKind::Input => {
                    if self.input_admission != Admission::Open {
                        return Err(ErrorCode::StateUnknown);
                    }
                    if self.input_handle.is_none() || self.pty_closed {
                        return Err(ErrorCode::NotRunning);
                    }
                }
                LeaseKind::Hpcon => {
                    if self.hpcon_admission != Admission::Open {
                        return Err(ErrorCode::StateUnknown);
                    }
                    if self.hpcon_handle.is_none() || self.pty_closed {
                        return Err(ErrorCode::NotRunning);
                    }
                }
            }
            let id = self
                .next_lease_id
                .checked_add(1)
                .ok_or(ErrorCode::ResourceExhausted)?;
            self.next_lease_id = id;
            let state = Arc::new(AtomicU64::new(ST_LIVE));
            match kind {
                LeaseKind::Input => {
                    self.input_leases.insert(id, Arc::clone(&state));
                    self.input_lease_count = self
                        .input_lease_count
                        .checked_add(1)
                        .ok_or(ErrorCode::ResourceExhausted)?;
                }
                LeaseKind::Hpcon => {
                    self.hpcon_leases.insert(id, Arc::clone(&state));
                    self.hpcon_lease_count = self
                        .hpcon_lease_count
                        .checked_add(1)
                        .ok_or(ErrorCode::ResourceExhausted)?;
                }
            }
            Ok((id, state))
        }

        fn release_kind(&mut self, kind: LeaseKind, id: u64) {
            let (map, count) = match kind {
                LeaseKind::Input => (&mut self.input_leases, &mut self.input_lease_count),
                LeaseKind::Hpcon => (&mut self.hpcon_leases, &mut self.hpcon_lease_count),
            };
            if let Some(st) = map.remove(&id) {
                let prev = st.swap(ST_CONSUMED, Ordering::SeqCst);
                if prev == ST_LIVE || prev == ST_ABANDONED {
                    *count = count.saturating_sub(1);
                }
            }
        }

        fn cancel_ticket(&mut self, ticket: u64) {
            for e in &mut self.fifo {
                if e.ticket == ticket {
                    e.cancel_requested = true;
                }
            }
            let occ = self.data_slot.occupant();
            self.fifo
                .retain(|e| !e.cancel_requested || occ == Some(e.ticket));
        }

        fn cancel_all(&mut self) {
            for e in &mut self.fifo {
                e.cancel_requested = true;
            }
            let occ = self.data_slot.occupant();
            self.fifo.retain(|e| occ == Some(e.ticket));
        }

        fn ticket_cancelled(&self, ticket: u64) -> bool {
            self.fifo
                .iter()
                .any(|e| e.ticket == ticket && e.cancel_requested)
                || !self.fifo.iter().any(|e| e.ticket == ticket)
                    && self.data_slot.occupant() != Some(ticket)
        }

        fn begin_teardown_ctrl(&mut self) -> bool {
            let native_available = matches!(self.data_slot, DataSlot::Free | DataSlot::Sealing { .. });
            if !native_available || self.write_pending || self.teardown_ctrl_reserved {
                return false;
            }
            self.teardown_ctrl_reserved = true;
            true
        }

        fn pin_admitted(&mut self) -> Result<(), ErrorCode> {
            match self.data_slot {
                DataSlot::Admitted {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                } if payload_len > 0 => {
                    self.data_slot = DataSlot::Pinned {
                        occupant,
                        payload_len,
                        kind,
                        reserved_seq,
                    };
                    Ok(())
                }
                _ => Err(ErrorCode::StateUnknown),
            }
        }
    }

    #[cfg(debug_assertions)]
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum IoObserveKind {
        Enqueued,
        AdmitBlocked,
        Admitted,
        Issued,
        Finished,
        Cancelled,
    }

    #[cfg(debug_assertions)]
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub struct IoObserveEvent {
        pub kind: IoObserveKind,
        pub ticket: DataTicket,
        pub input_seq: u64,
        pub head: Option<u64>,
        pub slot_free: bool,
    }

    #[cfg(debug_assertions)]
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum ObserveLiveness {
        Armed,
        Inactive,
    }

    #[cfg(debug_assertions)]
    struct ObserveControl {
        liveness: ObserveLiveness,
        events: Vec<IoObserveEvent>,
        released: std::collections::BTreeSet<u64>,
        waiting: BTreeMap<u64, usize>,
        invalid: bool,
        issue_hold: bool,
        pinned_hold: bool,
        pending_native: bool,
    }

    #[cfg(debug_assertions)]
    struct IoObserveState {
        monitor: Mutex<ObserveControl>,
        cv: Condvar,
    }

    #[cfg(debug_assertions)]
    pub struct RunIoObserveGuard {
        bundle: Arc<RunBundle>,
        state: Arc<IoObserveState>,
    }

    pub(super) struct RunBundle {
        control: Mutex<RunControl>,
        progress: Condvar,
        generation_visible: AtomicBool,
        skip_native_io: AtomicBool,
        write_pending: AtomicBool,
        write_cancelled: AtomicBool,
        #[cfg(test)]
        test_native_issues: AtomicU64,
        run_token: u64,
        #[cfg(debug_assertions)]
        observe: Mutex<Option<Arc<IoObserveState>>>,
    }

    impl RunBundle {
        pub(super) fn new() -> Arc<Self> {
            Arc::new(Self {
                control: Mutex::new(RunControl::new()),
                progress: Condvar::new(),
                generation_visible: AtomicBool::new(true),
                skip_native_io: AtomicBool::new(false),
                write_pending: AtomicBool::new(false),
                write_cancelled: AtomicBool::new(false),
                #[cfg(test)]
                test_native_issues: AtomicU64::new(0),
                run_token: NEXT_RUN_TOKEN.fetch_add(1, Ordering::SeqCst),
                #[cfg(debug_assertions)]
                observe: Mutex::new(None),
            })
        }

        #[cfg(test)]
        pub(super) fn new_test(run_id: u64) -> Arc<Self> {
            let bundle = Self::new();
            bundle.skip_native_io.store(true, Ordering::SeqCst);
            {
                let mut g = bundle.control.lock().unwrap_or_else(|p| p.into_inner());
                g.input_handle = Some(SendHandle((1_000 + run_id) as HANDLE));
                g.hpcon_handle = Some(SendHpcon((2_000 + run_id) as HPCON));
            }
            bundle
        }
    }

    // lock order: capture observe slot Arc, drop slot, then monitor.
    // never monitor -> run control. never monitor across product cancel.
    // record_io may take monitor while holding run control; no inverse route.
    // Guard Drop: monitor Inactive+notify, drop monitor, then slot detach; never run.
    // wait_if_held is before lock_run. record_io never waits on test gates.

    #[cfg(debug_assertions)]
    fn observe_state(bundle: &RunBundle) -> Option<Arc<IoObserveState>> {
        bundle.observe.lock().ok()?.clone()
    }

    #[cfg(debug_assertions)]
    fn shutdown_observe(ctrl: &mut ObserveControl, cv: &Condvar) {
        ctrl.invalid = true;
        ctrl.liveness = ObserveLiveness::Inactive;
        cv.notify_all();
    }

    #[cfg(debug_assertions)]
    fn observe_query_live(ctrl: &ObserveControl) -> Result<(), ErrorCode> {
        if ctrl.invalid || ctrl.liveness != ObserveLiveness::Armed {
            Err(ErrorCode::RuntimeFailed)
        } else {
            Ok(())
        }
    }

    #[cfg(debug_assertions)]
    fn lock_observe(state: &IoObserveState) -> Result<MutexGuard<'_, ObserveControl>, ErrorCode> {
        match state.monitor.lock() {
            Ok(ctrl) => {
                observe_query_live(&ctrl)?;
                Ok(ctrl)
            }
            Err(poisoned) => {
                let mut ctrl = poisoned.into_inner();
                shutdown_observe(&mut ctrl, &state.cv);
                Err(ErrorCode::RuntimeFailed)
            }
        }
    }

    #[cfg(debug_assertions)]
    fn record_io(
        bundle: &RunBundle,
        kind: IoObserveKind,
        ticket: DataTicket,
        input_seq: u64,
        head: Option<u64>,
        slot_free: bool,
    ) {
        let Some(state) = observe_state(bundle) else {
            return;
        };
        let Ok(mut ctrl) = lock_observe(&state) else {
            return;
        };
        if ctrl.liveness != ObserveLiveness::Armed {
            return;
        }
        ctrl.events.push(IoObserveEvent {
            kind,
            ticket,
            input_seq,
            head,
            slot_free,
        });
        state.cv.notify_all();
    }

    #[cfg(debug_assertions)]
    fn wait_if_held(bundle: &RunBundle, ticket: DataTicket) {
        wait_if_held_at(bundle, ticket, false, false);
    }

    #[cfg(debug_assertions)]
    fn wait_if_held_issue(bundle: &RunBundle, ticket: DataTicket) {
        wait_if_held_at(bundle, ticket, true, false);
    }

    #[cfg(debug_assertions)]
    fn wait_if_held_pinned(bundle: &RunBundle, ticket: DataTicket) {
        wait_if_held_at(bundle, ticket, false, true);
    }

    #[cfg(debug_assertions)]
    fn wait_if_held_at(bundle: &RunBundle, ticket: DataTicket, issue: bool, pinned: bool) {
        let Some(state) = observe_state(bundle) else {
            return;
        };
        let Ok(mut ctrl) = lock_observe(&state) else {
            return;
        };
        if pinned {
            if !ctrl.pinned_hold {
                return;
            }
        } else if ctrl.pinned_hold || issue != ctrl.issue_hold {
            return;
        }
        if ctrl.liveness != ObserveLiveness::Armed || ctrl.released.contains(&ticket.id) {
            return;
        }
        *ctrl.waiting.entry(ticket.id).or_insert(0) += 1;
        state.cv.notify_all();
        while !ctrl.invalid
            && ctrl.liveness == ObserveLiveness::Armed
            && !ctrl.released.contains(&ticket.id)
        {
            match state.cv.wait(ctrl) {
                Ok(next) => ctrl = next,
                Err(poisoned) => {
                    let mut inner = poisoned.into_inner();
                    shutdown_observe(&mut inner, &state.cv);
                    return;
                }
            }
        }
        if let Some(count) = ctrl.waiting.get_mut(&ticket.id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                ctrl.waiting.remove(&ticket.id);
            }
        }
        state.cv.notify_all();
    }

    #[cfg(debug_assertions)]
    fn take_pending_native(bundle: &RunBundle) -> bool {
        let Some(state) = observe_state(bundle) else {
            return false;
        };
        let Ok(mut ctrl) = lock_observe(&state) else {
            return false;
        };
        if ctrl.liveness != ObserveLiveness::Armed || !ctrl.pending_native {
            return false;
        }
        ctrl.pending_native = false;
        true
    }

    #[cfg(debug_assertions)]
    pub(super) fn attach_observe(bundle: &Arc<RunBundle>) -> Result<RunIoObserveGuard, ErrorCode> {
        let state = Arc::new(IoObserveState {
            monitor: Mutex::new(ObserveControl {
                liveness: ObserveLiveness::Armed,
                events: Vec::new(),
                released: std::collections::BTreeSet::new(),
                waiting: BTreeMap::new(),
                invalid: false,
                issue_hold: false,
                pinned_hold: false,
                pending_native: false,
            }),
            cv: Condvar::new(),
        });
        let mut slot = bundle.observe.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        if slot.is_some() {
            return Err(ErrorCode::OperationConflict);
        }
        *slot = Some(Arc::clone(&state));
        Ok(RunIoObserveGuard {
            bundle: Arc::clone(bundle),
            state,
        })
    }

    #[cfg(all(test, debug_assertions))]
    pub(super) fn panic_holding_observe_monitor(guard: &RunIoObserveGuard) {
        let _ctrl = guard.state.monitor.lock().expect("observe monitor");
        panic!("poison observe monitor");
    }

    #[cfg(debug_assertions)]
    impl RunIoObserveGuard {
        pub fn events(&self) -> Result<Vec<IoObserveEvent>, ErrorCode> {
            let ctrl = lock_observe(&self.state)?;
            observe_query_live(&ctrl)?;
            Ok(ctrl.events.clone())
        }

        pub fn wait_for(
            &self,
            pred: impl Fn(&[IoObserveEvent]) -> bool,
            timeout: Duration,
        ) -> Result<Vec<IoObserveEvent>, ErrorCode> {
            let mut ctrl = lock_observe(&self.state)?;
            let deadline = Instant::now()
                .checked_add(timeout)
                .unwrap_or_else(Instant::now);
            loop {
                observe_query_live(&ctrl)?;
                match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| pred(&ctrl.events))) {
                    Ok(true) => return Ok(ctrl.events.clone()),
                    Ok(false) => {}
                    Err(payload) => {
                        shutdown_observe(&mut ctrl, &self.state.cv);
                        drop(ctrl);
                        std::panic::resume_unwind(payload);
                    }
                }
                let now = Instant::now();
                if now >= deadline {
                    return Err(ErrorCode::RuntimeFailed);
                }
                match self
                    .state
                    .cv
                    .wait_timeout(ctrl, deadline.saturating_duration_since(now))
                {
                    Ok((next, _)) => {
                        ctrl = next;
                    }
                    Err(poisoned) => {
                        let (mut inner, _) = poisoned.into_inner();
                        shutdown_observe(&mut inner, &self.state.cv);
                        return Err(ErrorCode::RuntimeFailed);
                    }
                }
            }
        }

        pub fn wait_until_waiting(
            &self,
            ticket: DataTicket,
            timeout: Duration,
        ) -> Result<(), ErrorCode> {
            let mut ctrl = lock_observe(&self.state)?;
            let deadline = Instant::now()
                .checked_add(timeout)
                .unwrap_or_else(Instant::now);
            loop {
                observe_query_live(&ctrl)?;
                if ctrl.waiting.contains_key(&ticket.id) {
                    return Ok(());
                }
                let now = Instant::now();
                if now >= deadline {
                    return Err(ErrorCode::RuntimeFailed);
                }
                match self
                    .state
                    .cv
                    .wait_timeout(ctrl, deadline.saturating_duration_since(now))
                {
                    Ok((next, _)) => {
                        ctrl = next;
                    }
                    Err(poisoned) => {
                        let (mut inner, _) = poisoned.into_inner();
                        shutdown_observe(&mut inner, &self.state.cv);
                        return Err(ErrorCode::RuntimeFailed);
                    }
                }
            }
        }

        pub fn ticket_released(&self, ticket: DataTicket) -> Result<bool, ErrorCode> {
            let ctrl = lock_observe(&self.state)?;
            observe_query_live(&ctrl)?;
            Ok(ctrl.released.contains(&ticket.id))
        }

        pub fn enable_issue_hold(&self) {
            let Ok(mut ctrl) = lock_observe(&self.state) else {
                return;
            };
            if ctrl.liveness != ObserveLiveness::Armed {
                return;
            }
            ctrl.issue_hold = true;
        }

        pub fn enable_pinned_hold(&self) {
            let Ok(mut ctrl) = lock_observe(&self.state) else {
                return;
            };
            if ctrl.liveness != ObserveLiveness::Armed {
                return;
            }
            ctrl.pinned_hold = true;
        }

        pub fn enable_pending_native(&self) {
            let Ok(mut ctrl) = lock_observe(&self.state) else {
                return;
            };
            if ctrl.liveness != ObserveLiveness::Armed {
                return;
            }
            ctrl.pending_native = true;
        }

        pub fn release(&self, ticket: DataTicket) {
            let Ok(mut ctrl) = lock_observe(&self.state) else {
                return;
            };
            if ctrl.liveness != ObserveLiveness::Armed {
                return;
            }
            ctrl.released.insert(ticket.id);
            self.state.cv.notify_all();
        }

        pub fn cancel_ticket(&self, ticket: DataTicket) -> Result<(), ErrorCode> {
            let result = cancel_data(&self.bundle, ticket);
            self.release(ticket);
            result
        }
    }

    #[cfg(debug_assertions)]
    impl Drop for RunIoObserveGuard {
        fn drop(&mut self) {
            match self.state.monitor.lock() {
                Ok(mut ctrl) => {
                    ctrl.liveness = ObserveLiveness::Inactive;
                    self.state.cv.notify_all();
                }
                Err(poisoned) => {
                    let mut ctrl = poisoned.into_inner();
                    shutdown_observe(&mut ctrl, &self.state.cv);
                }
            }
            let mut slot = self
                .bundle
                .observe
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            if slot
                .as_ref()
                .is_some_and(|state| Arc::ptr_eq(state, &self.state))
            {
                *slot = None;
            }
        }
    }

    struct NativeLease {
        kind: LeaseKind,
        id: u64,
        state: Arc<AtomicU64>,
        consumed: bool,
        bundle: Arc<RunBundle>,
    }

    impl NativeLease {
        fn release_under(mut self, ctrl: &mut RunControl) {
            ctrl.release_kind(self.kind, self.id);
            self.consumed = true;
        }
    }

    impl Drop for NativeLease {
        fn drop(&mut self) {
            if self.consumed {
                return;
            }
            if run_held() > 0 {
                let _ = self.state.compare_exchange(
                    ST_LIVE,
                    ST_ABANDONED,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                );
                return;
            }
            let mut g = self
                .bundle
                .control
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            g.release_kind(self.kind, self.id);
            self.consumed = true;
            self.bundle.progress.notify_all();
        }
    }

    struct RunGuard<'a> {
        bundle: &'a RunBundle,
        arc: Arc<RunBundle>,
        guard: Option<MutexGuard<'a, RunControl>>,
    }

    impl<'a> RunGuard<'a> {
        fn ctrl(&mut self) -> &mut RunControl {
            self.guard.as_mut().expect("run guard")
        }

        fn notify_all(&self) {
            self.bundle.progress.notify_all();
        }

        fn wait_while(&mut self, mut should_wait: impl FnMut(&RunControl) -> bool) {
            loop {
                {
                    let g = self.guard.as_mut().expect("run guard");
                    g.reap_all();
                    if !should_wait(g) {
                        return;
                    }
                }
                leave_run();
                let g = self.guard.take().expect("run guard");
                let g = self
                    .bundle
                    .progress
                    .wait(g)
                    .unwrap_or_else(|p| p.into_inner());
                enter_run();
                self.guard = Some(g);
            }
        }

        fn try_acquire(&mut self, kind: LeaseKind) -> Result<NativeLease, ErrorCode> {
            let (id, state) = self.ctrl().acquire(kind)?;
            Ok(NativeLease {
                kind,
                id,
                state,
                consumed: false,
                bundle: Arc::clone(&self.arc),
            })
        }
    }

    impl Drop for RunGuard<'_> {
        fn drop(&mut self) {
            if let Some(g) = self.guard.as_mut() {
                if g.reap_all() > 0 {
                    self.bundle.progress.notify_all();
                }
            }
            if run_held() > 0 {
                leave_run();
            }
            self.guard.take();
        }
    }

    fn settle_retained_unknown(control: &mut RunControl, occupant: u64) {
        let DataSlot::RetainedUnknown {
            occupant: current,
            protocol_sealed,
        } = control.data_slot
        else {
            return;
        };
        if current != occupant {
            return;
        }
        if protocol_sealed || !control.fifo.iter().any(|entry| entry.ticket == occupant) {
            control.fifo.retain(|entry| entry.ticket != occupant);
            control.data_slot = DataSlot::Free;
        } else {
            control.data_slot = DataSlot::UnknownSealPending { occupant };
        }
    }

    struct PinFinalizerGuard<'a> {
        bundle: Arc<RunBundle>,
        shared: Option<&'a super::SessionShared>,
        op: Option<PinnedWrite>,
        role: PinRole,
        identity: SendWriteIdentity,
        committed: bool,
    }

    impl<'a> PinFinalizerGuard<'a> {
        fn begin(
            bundle: &Arc<RunBundle>,
            shared: Option<&'a super::SessionShared>,
            op: PinnedWrite,
            role: PinRole,
        ) -> Result<Self, ErrorCode> {
            let identity = SendWriteIdentity::from_identity(op.identity());
            {
                let mut g = lock_run(bundle);
                if g.ctrl().pin.is_some() || g.ctrl().pin_finalizing {
                    return Err(ErrorCode::StateUnknown);
                }
                g.ctrl().write_identity = Some(identity);
                g.ctrl().pin_role = Some(role);
                g.ctrl().pin_finalizing = true;
                g.ctrl().write_pending = true;
                if let PinRole::Data { occupant, .. } = role {
                    g.ctrl().pin_cancel_requested |= g.ctrl().stop_flag
                        || g.ctrl().ticket_cancelled(occupant)
                        || !bundle.generation_visible.load(Ordering::SeqCst);
                }
                sync_pending(bundle, g.ctrl(), shared);
                g.notify_all();
            }
            Ok(Self {
                bundle: Arc::clone(bundle),
                shared,
                op: Some(op),
                role,
                identity,
                committed: false,
            })
        }

        fn take_pending(
            bundle: &Arc<RunBundle>,
            shared: Option<&'a super::SessionShared>,
        ) -> Option<Self> {
            let (op, role, identity) = {
                let mut g = lock_run(bundle);
                if g.ctrl().pin_finalizing {
                    return None;
                }
                let op = g.ctrl().pin.take()?;
                let role = g.ctrl().pin_role?;
                let identity = g.ctrl().write_identity?;
                if !SendWriteIdentity::from_identity(op.identity()).matches(identity) {
                    g.ctrl().pin = Some(op);
                    return None;
                }
                g.ctrl().pin_finalizing = true;
                g.ctrl().write_pending = true;
                sync_pending(bundle, g.ctrl(), shared);
                g.notify_all();
                (op, role, identity)
            };
            Some(Self {
                bundle: Arc::clone(bundle),
                shared,
                op: Some(op),
                role,
                identity,
                committed: false,
            })
        }

        fn query(&mut self) -> IoObservation {
            native_window(|| self.op.as_mut().expect("pin finalizer op").query())
        }

        fn request_cancel(&mut self) {
            let requested = {
                let mut g = lock_run(&self.bundle);
                if !g
                    .ctrl()
                    .write_identity
                    .is_some_and(|id| id.matches(self.identity))
                    || g.ctrl().pin_role != Some(self.role)
                {
                    false
                } else {
                    g.ctrl().pin_cancel_requested = true;
                    true
                }
            };
            if requested {
                let _ = self.op.as_ref().expect("pin finalizer op").request_cancel();
            }
        }

        fn wait_event(&self) {
            let _ = native_window(|| self.op.as_ref().expect("pin finalizer op").wait_event());
        }

        fn cancel_requested(&self) -> bool {
            let mut g = lock_run(&self.bundle);
            g.ctrl()
                .write_identity
                .is_some_and(|id| id.matches(self.identity))
                && g.ctrl().pin_role == Some(self.role)
                && g.ctrl().pin_cancel_requested
        }

        fn park_unknown(mut self) {
            let Some(op) = self.op.take() else {
                return;
            };
            {
                let mut g = lock_run(&self.bundle);
                if g.ctrl()
                    .write_identity
                    .is_some_and(|id| id.matches(self.identity))
                    && g.ctrl().pin_role == Some(self.role)
                {
                    if let PinRole::Data { occupant, .. } = self.role {
                        if matches!(g.ctrl().data_slot, DataSlot::Pinned { occupant: current, .. } if current == occupant)
                        {
                            g.ctrl().data_slot = DataSlot::RetainedUnknown {
                                occupant,
                                protocol_sealed: false,
                            };
                        }
                    }
                    g.ctrl().pin = Some(op);
                    g.ctrl().pin_finalizing = false;
                    g.ctrl().write_pending = true;
                    sync_pending(&self.bundle, g.ctrl(), self.shared);
                    g.notify_all();
                    self.committed = true;
                    return;
                }
            }
            retain_write(op);
            self.committed = true;
        }

        fn finish(mut self, class: WriteResult) -> NativeOutcome {
            let outcome = match class {
                WriteResult::Delivered => match self.role {
                    PinRole::Data { payload_len, .. } => NativeOutcome::Delivered {
                        written: payload_len as u32,
                    },
                    PinRole::TeardownCtrl => NativeOutcome::Delivered { written: 1 },
                },
                WriteResult::Aborted => NativeOutcome::Aborted,
                WriteResult::IoFailed | WriteResult::Unknown => NativeOutcome::IoFailed,
            };
            {
                let mut g = lock_run(&self.bundle);
                if g.ctrl()
                    .write_identity
                    .is_some_and(|id| id.matches(self.identity))
                    && g.ctrl().pin_role == Some(self.role)
                {
                    match self.role {
                        PinRole::Data {
                            occupant,
                            payload_len,
                            kind,
                            reserved_seq,
                        } => match g.ctrl().data_slot {
                            DataSlot::Pinned { occupant: current, .. } if current == occupant => {
                                g.ctrl().data_slot = DataSlot::Sealing {
                                    occupant,
                                    payload_len,
                                    kind,
                                    reserved_seq,
                                    outcome,
                                };
                            }
                            DataSlot::RetainedUnknown { occupant: current, .. }
                                if current == occupant => settle_retained_unknown(g.ctrl(), occupant),
                            _ => {}
                        },
                        PinRole::TeardownCtrl => {
                            if matches!(class, WriteResult::Delivered) {
                                if let Some(shared) = self.shared {
                                    shared.ctrl_c_delivered.store(true, Ordering::SeqCst);
                                    if let Ok(mut count) = shared.ctrl_c_writes.lock() {
                                        if *count == 0 {
                                            *count = 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if matches!(class, WriteResult::Aborted) {
                        if let Some(shared) = self.shared {
                            shared.write_cancelled.store(true, Ordering::SeqCst);
                        }
                    }
                    g.ctrl().write_pending = false;
                    g.ctrl().pin_finalizing = false;
                    g.ctrl().pin_cancel_requested = false;
                    g.ctrl().pin_role = None;
                    g.ctrl().write_identity = None;
                    sync_pending(&self.bundle, g.ctrl(), self.shared);
                    g.notify_all();
                }
            }
            if let Some(op) = self.op.as_mut() {
                native_window(|| op.mark_completed_and_close_event());
            }
            self.op.take();
            self.committed = true;
            outcome
        }
    }

    impl Drop for PinFinalizerGuard<'_> {
        fn drop(&mut self) {
            if self.committed {
                return;
            }
            let Some(op) = self.op.take() else {
                return;
            };
            let mut g = lock_run(&self.bundle);
            if g.ctrl()
                .write_identity
                .is_some_and(|id| id.matches(self.identity))
                && g.ctrl().pin_role == Some(self.role)
            {
                if let PinRole::Data { occupant, .. } = self.role {
                    if matches!(g.ctrl().data_slot, DataSlot::Pinned { occupant: current, .. } if current == occupant)
                    {
                        g.ctrl().data_slot = DataSlot::RetainedUnknown {
                            occupant,
                            protocol_sealed: false,
                        };
                    }
                }
                g.ctrl().pin = Some(op);
                g.ctrl().pin_finalizing = false;
                g.ctrl().write_pending = true;
                sync_pending(&self.bundle, g.ctrl(), self.shared);
                g.notify_all();
            } else {
                drop(g);
                retain_write(op);
            }
        }
    }

    struct NativeTransitionGuard {
        bundle: Arc<RunBundle>,
        ticket: u64,
        armed: bool,
    }

    impl NativeTransitionGuard {
        fn new(bundle: &Arc<RunBundle>, ticket: u64) -> Self {
            Self {
                bundle: Arc::clone(bundle),
                ticket,
                armed: true,
            }
        }

        fn commit(&mut self, outcome: NativeOutcome) -> Result<(), ErrorCode> {
            let mut g = lock_run(&self.bundle);
            let replacement = match g.ctrl().data_slot {
                DataSlot::Pinned {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                } if occupant == self.ticket => DataSlot::Sealing {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                    outcome,
                },
                DataSlot::HpconBusy { occupant } if occupant == self.ticket => {
                    DataSlot::Sealing {
                        occupant,
                        payload_len: 0,
                        kind: DataKind::Resize,
                        reserved_seq: None,
                        outcome,
                    }
                }
                DataSlot::Sealing { occupant, .. } if occupant == self.ticket => {
                    self.armed = false;
                    return Ok(());
                }
                _ => return Err(ErrorCode::StateUnknown),
            };
            g.ctrl().data_slot = replacement;
            g.notify_all();
            self.armed = false;
            Ok(())
        }

        fn handoff_pending(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for NativeTransitionGuard {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            let mut g = lock_run(&self.bundle);
            let outcome = if g.ctrl().stop_flag || g.ctrl().ticket_cancelled(self.ticket) {
                NativeOutcome::Aborted
            } else {
                NativeOutcome::IoFailed
            };
            let replacement = match g.ctrl().data_slot {
                DataSlot::Admitted {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                }
                | DataSlot::Pinned {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                } if occupant == self.ticket => Some(DataSlot::Sealing {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                    outcome,
                }),
                DataSlot::HpconBusy { occupant } if occupant == self.ticket => {
                    Some(DataSlot::Sealing {
                        occupant,
                        payload_len: 0,
                        kind: DataKind::Resize,
                        reserved_seq: None,
                        outcome,
                    })
                }
                _ => None,
            };
            if let Some(replacement) = replacement {
                g.ctrl().data_slot = replacement;
                g.notify_all();
            }
        }
    }

    fn lock_run(bundle: &Arc<RunBundle>) -> RunGuard<'_> {
        enter_run();
        let mut guard = bundle.control.lock().unwrap_or_else(|p| p.into_inner());
        guard.reap_all();
        RunGuard {
            bundle: bundle.as_ref(),
            arc: Arc::clone(bundle),
            guard: Some(guard),
        }
    }

    fn sync_pending(bundle: &RunBundle, ctrl: &RunControl, shared: Option<&super::SessionShared>) {
        bundle
            .write_pending
            .store(ctrl.write_pending, Ordering::SeqCst);
        bundle.write_cancelled.store(
            shared.is_some_and(|s| s.write_cancelled.load(Ordering::SeqCst)),
            Ordering::SeqCst,
        );
        if let Some(shared) = shared {
            shared
                .write_pending
                .store(ctrl.write_pending, Ordering::SeqCst);
        }
    }

    fn request_pin_cancel(ctrl: &mut RunControl) {
        if ctrl.write_pending {
            ctrl.pin_cancel_requested = true;
        }
    }

    fn ticket_run_matches(bundle: &RunBundle, ticket: DataTicket) -> Result<(), ErrorCode> {
        if ticket.run_token != bundle.run_token {
            Err(ErrorCode::TargetNotFound)
        } else {
            Ok(())
        }
    }

    pub(super) fn install_handles(bundle: &Arc<RunBundle>, input: HANDLE, hpcon: HPCON) {
        let mut g = lock_run(bundle);
        if !input.is_null() && input != INVALID_HANDLE_VALUE {
            g.ctrl().input_handle = Some(SendHandle(input));
        } else {
            g.ctrl().input_handle = None;
        }
        if hpcon != 0 {
            g.ctrl().hpcon_handle = Some(SendHpcon(hpcon));
        } else {
            g.ctrl().hpcon_handle = None;
        }
        #[cfg(debug_assertions)]
        {
            g.ctrl().generated_hpcon = (hpcon != 0).then_some(hpcon as usize);
        }
        g.ctrl().input_admission = Admission::Open;
        g.ctrl().hpcon_admission = Admission::Open;
        g.notify_all();
    }

    pub(super) fn set_generation_open(bundle: &Arc<RunBundle>, open: bool) {
        bundle.generation_visible.store(open, Ordering::SeqCst);
        let g = lock_run(bundle);
        g.notify_all();
    }

    pub(super) fn snapshot(bundle: &Arc<RunBundle>) -> TestingRunIoStats {
        let mut g = lock_run(bundle);
        let c = g.ctrl();
        TestingRunIoStats {
            input_seq: c.input_seq,
            fifo_ids: c.fifo.iter().map(|e| e.ticket).collect(),
            fifo_head_id: c.fifo.front().map(|e| e.ticket),
            data_slot: c.data_slot.testing(),
            teardown_ctrl_reserved: c.teardown_ctrl_reserved,
            stop_flag: c.stop_flag,
            input_lease_count: c.input_lease_count,
            hpcon_lease_count: c.hpcon_lease_count,
            write_pending: c.write_pending,
            pty_closed: c.pty_closed,
            input_sealed: c.input_admission == Admission::Sealed,
            hpcon_sealed: c.hpcon_admission == Admission::Sealed,
            input_handle_present: c
                .input_handle
                .is_some_and(|handle| !handle.0.is_null() && handle.0 != INVALID_HANDLE_VALUE),
            hpcon_handle_present: c.hpcon_handle.is_some_and(|handle| handle.0 != 0),
            #[cfg(debug_assertions)]
            generated_hpcon: c.generated_hpcon,
            #[cfg(debug_assertions)]
            close_target_hpcon: c.close_target_hpcon,
            #[cfg(debug_assertions)]
            close_target_matches_generated: c
                .close_target_hpcon
                .zip(c.generated_hpcon)
                .map(|(closed, generated)| closed == generated),
            #[cfg(debug_assertions)]
            close_skip_native_io: c.close_skip_native_io,
            #[cfg(debug_assertions)]
            close_native_entered: c.close_native_entered,
            #[cfg(debug_assertions)]
            close_native_returned: c.close_native_returned,
            #[cfg(debug_assertions)]
            close_output_bytes: c.close_output_bytes,
        }
    }

    #[cfg(debug_assertions)]
    pub(super) fn inspect_cleanup(
        bundle: &Arc<RunBundle>,
    ) -> Result<super::TestingCleanupIoSnapshot, ErrorCode> {
        // A plain immutable guard: RunGuard would reap abandoned leases on
        // acquisition/drop, and its poison recovery would hide lost evidence.
        let c = bundle
            .control
            .lock()
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        Ok(super::TestingCleanupIoSnapshot {
            input_lease_count: c.input_lease_count,
            hpcon_lease_count: c.hpcon_lease_count,
            input_leases: c
                .input_leases
                .iter()
                .map(|(id, state)| (*id, state.load(Ordering::SeqCst)))
                .collect(),
            hpcon_leases: c
                .hpcon_leases
                .iter()
                .map(|(id, state)| (*id, state.load(Ordering::SeqCst)))
                .collect(),
            input_handle_present: c
                .input_handle
                .is_some_and(|handle| !handle.0.is_null() && handle.0 != INVALID_HANDLE_VALUE),
            hpcon_handle_present: c.hpcon_handle.is_some_and(|handle| handle.0 != 0),
            write_pending: c.write_pending,
            pin_present: c.pin.is_some(),
            pin_finalizing: c.pin_finalizing,
            pin_cancel_requested: c.pin_cancel_requested,
            pty_closed: c.pty_closed,
            fifo: c
                .fifo
                .iter()
                .map(|entry| (entry.ticket, entry.cancel_requested))
                .collect(),
            stop_flag: c.stop_flag,
        })
    }

    #[cfg(all(test, debug_assertions))]
    mod cleanup_observer_tests {
        use super::*;

        #[test]
        fn cleanup_observer_keeps_abandoned_sibling_leases_and_cancellation() {
            let bundle = RunBundle::new();
            {
                let mut c = bundle.control.lock().unwrap();
                c.input_leases
                    .insert(11, Arc::new(AtomicU64::new(ST_ABANDONED)));
                c.hpcon_leases
                    .insert(12, Arc::new(AtomicU64::new(ST_ABANDONED)));
                c.input_lease_count = 1;
                c.hpcon_lease_count = 1;
                c.pin_cancel_requested = true;
                c.stop_flag = true;
                c.fifo.push_back(FifoEntry {
                    ticket: 7,
                    operation_key: None,
                    kind: DataKind::Write,
                    cancel_requested: true,
                    payload_len: 1,
                });
            }
            let before = inspect_cleanup(&bundle).unwrap();
            assert_eq!(before.input_leases, vec![(11, ST_ABANDONED)]);
            assert_eq!(before.hpcon_leases, vec![(12, ST_ABANDONED)]);
            assert_eq!((before.input_lease_count, before.hpcon_lease_count), (1, 1));
            assert!(before.pin_cancel_requested && before.stop_flag);
            assert_eq!(before.fifo, vec![(7, true)]);
            assert_eq!(inspect_cleanup(&bundle).unwrap(), before);
            // Establish why the old getter is unsuitable for this evidence.
            let old = snapshot(&bundle);
            assert_eq!((old.input_lease_count, old.hpcon_lease_count), (0, 0));
            let after_owner = inspect_cleanup(&bundle).unwrap();
            assert!(after_owner.input_leases.is_empty() && after_owner.hpcon_leases.is_empty());
            assert_eq!(after_owner.fifo, before.fifo);
            assert_eq!(
                after_owner.pin_cancel_requested,
                before.pin_cancel_requested
            );
        }

        #[test]
        fn cleanup_observer_rejects_poison_without_recovering() {
            let bundle = RunBundle::new();
            let other = Arc::clone(&bundle);
            assert!(std::thread::spawn(move || {
                let mut c = other.control.lock().unwrap();
                c.input_lease_count = 1;
                c.input_leases
                    .insert(13, Arc::new(AtomicU64::new(ST_ABANDONED)));
                panic!("intentional observer poison boundary");
            })
            .join()
            .is_err());
            assert_eq!(inspect_cleanup(&bundle), Err(ErrorCode::RuntimeFailed));
            assert!(bundle.control.is_poisoned());
            let c = bundle
                .control
                .lock()
                .err()
                .expect("poison must remain observable")
                .into_inner();
            assert_eq!(c.input_lease_count, 1);
            assert_eq!(
                c.input_leases.get(&13).unwrap().load(Ordering::SeqCst),
                ST_ABANDONED
            );
        }

        #[test]
        fn cleanup_observer_empty_and_closed_boundaries_are_distinct() {
            let bundle = RunBundle::new();
            let empty = inspect_cleanup(&bundle).unwrap();
            assert!(!empty.pty_closed && !empty.write_pending && !empty.pin_present);
            assert_eq!((empty.input_lease_count, empty.hpcon_lease_count), (0, 0));
            {
                let mut c = bundle.control.lock().unwrap();
                c.pty_closed = true;
                c.input_admission = Admission::Sealed;
                c.hpcon_admission = Admission::Sealed;
            }
            let closed = inspect_cleanup(&bundle).unwrap();
            assert!(
                closed.pty_closed && !closed.input_handle_present && !closed.hpcon_handle_present
            );
            assert_eq!(inspect_cleanup(&bundle).unwrap(), closed);
            assert_ne!(closed, empty);
        }
    }

    pub(super) fn occupancy_blocks_close(bundle: &Arc<RunBundle>) -> bool {
        !matches!(snapshot(bundle).data_slot, TestingDataSlot::Free)
    }

    pub(super) fn enqueue_data(
        bundle: &Arc<RunBundle>,
        kind: DataKind,
        payload_len: usize,
        operation_key: Option<[u8; 36]>,
    ) -> Result<DataTicket, ErrorCode> {
        let mut g = lock_run(bundle);
        if !bundle.generation_visible.load(Ordering::SeqCst) {
            return Err(ErrorCode::StateUnknown);
        }
        if matches!(g.ctrl().data_slot, DataSlot::RetainedUnknown { .. } | DataSlot::UnknownSealPending { .. }) {
            return Err(ErrorCode::StateUnknown);
        }
        if g.ctrl().pty_closed {
            return Err(ErrorCode::NotRunning);
        }
        if g.ctrl().stop_flag {
            return Err(ErrorCode::StateUnknown);
        }
        let id = g.ctrl().alloc_ticket()?;
        g.ctrl().fifo.push_back(FifoEntry {
            ticket: id,
            operation_key,
            kind,
            cancel_requested: false,
            payload_len,
        });
        let issued = DataTicket {
            id,
            run_token: bundle.run_token,
            operation_key,
        };
        #[cfg(debug_assertions)]
        {
            let input_seq = g.ctrl().input_seq;
            let head = g.ctrl().fifo.front().map(|e| e.ticket);
            let slot_free = matches!(g.ctrl().data_slot, DataSlot::Free);
            record_io(
                bundle,
                IoObserveKind::Enqueued,
                issued,
                input_seq,
                head,
                slot_free,
            );
        }
        Ok(issued)
    }

    pub(super) fn admit_data(bundle: &Arc<RunBundle>, ticket: DataTicket) -> Result<(), ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        #[cfg(debug_assertions)]
        wait_if_held(bundle, ticket);
        let ticket_id = ticket.id;
        let mut g = lock_run(bundle);
        if g.ctrl().data_slot.occupant() == Some(ticket_id) {
            match g.ctrl().data_slot {
                DataSlot::RetainedUnknown { .. } | DataSlot::UnknownSealPending { .. } => {
                    return Err(ErrorCode::StateUnknown)
                }
                DataSlot::Free => {}
                DataSlot::Admitted { .. }
                | DataSlot::Pinned { .. }
                | DataSlot::HpconBusy { .. }
                | DataSlot::Sealing { .. } => return Ok(()),
            }
        }
        loop {
            g.ctrl().reap_all();
            let occ = g.ctrl().data_slot.occupant();
            g.ctrl()
                .fifo
                .retain(|e| !e.cancel_requested || occ == Some(e.ticket));
            if !g.ctrl().fifo.iter().any(|e| e.ticket == ticket_id) {
                g.notify_all();
                return Err(ErrorCode::StateUnknown);
            }
            if !bundle.generation_visible.load(Ordering::SeqCst) {
                g.ctrl().cancel_ticket(ticket_id);
                g.notify_all();
                return Err(ErrorCode::StateUnknown);
            }
            if matches!(g.ctrl().data_slot, DataSlot::RetainedUnknown { .. } | DataSlot::UnknownSealPending { .. }) {
                g.ctrl().cancel_ticket(ticket_id);
                g.notify_all();
                return Err(ErrorCode::StateUnknown);
            }
            if g.ctrl().pty_closed {
                g.ctrl().cancel_ticket(ticket_id);
                g.notify_all();
                return Err(ErrorCode::NotRunning);
            }
            if g.ctrl()
                .fifo
                .iter()
                .any(|e| e.ticket == ticket_id && e.cancel_requested)
            {
                g.ctrl().cancel_ticket(ticket_id);
                g.notify_all();
                return Err(ErrorCode::StateUnknown);
            }
            if g.ctrl().stop_flag {
                g.ctrl().cancel_ticket(ticket_id);
                g.notify_all();
                return Err(ErrorCode::StateUnknown);
            }
            let is_head = g.ctrl().fifo.front().map(|e| e.ticket) == Some(ticket_id);
            let slot_free = matches!(g.ctrl().data_slot, DataSlot::Free);
            if !is_head || !slot_free {
                #[cfg(debug_assertions)]
                record_io(
                    bundle,
                    IoObserveKind::AdmitBlocked,
                    ticket,
                    g.ctrl().input_seq,
                    g.ctrl().fifo.front().map(|e| e.ticket),
                    slot_free,
                );
                let vis = Arc::clone(bundle);
                g.wait_while(move |c| {
                    if !c.fifo.iter().any(|e| e.ticket == ticket_id) {
                        return false;
                    }
                    if !vis.generation_visible.load(Ordering::SeqCst)
                        || c.pty_closed
                        || c.stop_flag
                        || matches!(c.data_slot, DataSlot::RetainedUnknown { .. } | DataSlot::UnknownSealPending { .. })
                        || c.fifo
                            .iter()
                            .any(|e| e.ticket == ticket_id && e.cancel_requested)
                    {
                        return false;
                    }
                    let head = c.fifo.front().map(|e| e.ticket) == Some(ticket_id);
                    !(head && matches!(c.data_slot, DataSlot::Free))
                });
                continue;
            }
            let (kind, payload_len) = match g.ctrl().fifo.front() {
                Some(entry)
                    if entry.ticket == ticket_id
                        && entry.operation_key == ticket.operation_key =>
                {
                    (entry.kind, entry.payload_len)
                }
                _ => {
                    g.notify_all();
                    return Err(ErrorCode::StateUnknown);
                }
            };
            match kind {
                DataKind::Write | DataKind::Key => {
                    let reserved_seq = match next_input_seq(g.ctrl().input_seq) {
                        Ok(seq) => seq,
                        Err(_) => {
                        g.ctrl().fifo.retain(|e| e.ticket != ticket_id);
                        g.notify_all();
                        return Err(ErrorCode::ResourceExhausted);
                        }
                    };
                    if g.ctrl().input_admission != Admission::Open
                        || g.ctrl().input_handle.is_none()
                    {
                        g.ctrl().cancel_ticket(ticket_id);
                        g.notify_all();
                        return Err(ErrorCode::NotRunning);
                    }
                    g.ctrl().data_slot = DataSlot::Admitted {
                        occupant: ticket_id,
                        payload_len,
                        kind,
                        reserved_seq: Some(reserved_seq),
                    };
                    #[cfg(debug_assertions)]
                    record_io(
                        bundle,
                        IoObserveKind::Admitted,
                        ticket,
                        g.ctrl().input_seq,
                        g.ctrl().fifo.front().map(|e| e.ticket),
                        false,
                    );
                    g.notify_all();
                    return Ok(());
                }
                DataKind::Resize => {
                    if g.ctrl().hpcon_admission != Admission::Open
                        || g.ctrl().hpcon_handle.is_none()
                    {
                        g.ctrl().cancel_ticket(ticket_id);
                        g.notify_all();
                        return Err(ErrorCode::NotRunning);
                    }
                    g.ctrl().data_slot = DataSlot::HpconBusy {
                        occupant: ticket_id,
                    };
                    return Ok(());
                }
            }
        }
    }

    pub(super) fn begin_data(
        bundle: &Arc<RunBundle>,
        kind: DataKind,
        payload_len: usize,
    ) -> Result<DataTicket, ErrorCode> {
        let ticket = enqueue_data(bundle, kind, payload_len, None)?;
        admit_data(bundle, ticket)?;
        Ok(ticket)
    }

    pub(super) fn issue_write(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
        ticket: DataTicket,
        payload: &[u8],
    ) -> Result<NativeOutcome, ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        #[cfg(debug_assertions)]
        wait_if_held_issue(bundle, ticket);
        #[cfg(debug_assertions)]
        let observe_ticket = ticket;
        let ticket = ticket.id;
        {
            let mut g = lock_run(bundle);
            match g.ctrl().data_slot {
                DataSlot::Sealing {
                    occupant,
                    payload_len: 0,
                    outcome,
                    ..
                } if occupant == ticket => {
                    return Ok(outcome);
                }
                DataSlot::Sealing {
                    occupant, outcome, ..
                } if occupant == ticket => {
                    return Ok(outcome);
                }
                DataSlot::Admitted {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                } if occupant == ticket && matches!(kind, DataKind::Write | DataKind::Key) => {
                    if payload.len() != payload_len {
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant,
                            payload_len,
                            kind,
                            reserved_seq,
                            outcome: NativeOutcome::IoFailed,
                        };
                        g.notify_all();
                        return Err(ErrorCode::InvalidRequest);
                    }
                    if g.ctrl().stop_flag
                        || g.ctrl().ticket_cancelled(ticket)
                        || !bundle.generation_visible.load(Ordering::SeqCst)
                        || g.ctrl().pty_closed
                    {
                        let outcome = if g.ctrl().stop_flag || g.ctrl().ticket_cancelled(ticket) {
                            NativeOutcome::Aborted
                        } else {
                            NativeOutcome::IoFailed
                        };
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant,
                            payload_len,
                            kind,
                            reserved_seq,
                            outcome,
                        };
                        g.notify_all();
                        return Ok(outcome);
                    }
                    if payload_len == 0 {
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant,
                            payload_len: 0,
                            kind,
                            reserved_seq,
                            outcome: NativeOutcome::Delivered { written: 0 },
                        };
                        g.notify_all();
                        return Ok(NativeOutcome::Delivered { written: 0 });
                    }
                    g.ctrl().pin_admitted()?;
                    g.notify_all();
                }
                _ => return Err(ErrorCode::StateUnknown),
            }
        }
        #[cfg(debug_assertions)]
        wait_if_held_pinned(bundle, observe_ticket);
        let mut transition = NativeTransitionGuard::new(bundle, ticket);
        let prepared = {
            let mut g = lock_run(bundle);
            match g.ctrl().data_slot {
                DataSlot::Sealing {
                    occupant, outcome, ..
                } if occupant == ticket => {
                    return Ok(outcome);
                }
                DataSlot::Pinned {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                } if occupant == ticket && matches!(kind, DataKind::Write | DataKind::Key) => {
                    if payload.len() != payload_len {
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant,
                            payload_len,
                            kind,
                            reserved_seq,
                            outcome: NativeOutcome::IoFailed,
                        };
                        g.notify_all();
                        return Err(ErrorCode::InvalidRequest);
                    }
                    if g.ctrl().stop_flag
                        || g.ctrl().ticket_cancelled(ticket)
                        || !bundle.generation_visible.load(Ordering::SeqCst)
                        || g.ctrl().pty_closed
                    {
                        let outcome = if g.ctrl().stop_flag || g.ctrl().ticket_cancelled(ticket) {
                            NativeOutcome::Aborted
                        } else {
                            NativeOutcome::IoFailed
                        };
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant,
                            payload_len,
                            kind,
                            reserved_seq,
                            outcome,
                        };
                        g.notify_all();
                        return Ok(outcome);
                    }
                    let lease = g.try_acquire(LeaseKind::Input)?;
                    let handle = g
                        .ctrl()
                        .input_handle
                        .map(|h| h.0)
                        .ok_or(ErrorCode::NotRunning)?;
                    Some((lease, handle, payload_len, kind, reserved_seq))
                }
                _ => return Err(ErrorCode::StateUnknown),
            }
        };
        let Some((lease, handle, payload_len, kind, reserved_seq)) = prepared else {
            return Err(ErrorCode::StateUnknown);
        };
        #[cfg(test)]
        bundle.test_native_issues.fetch_add(1, Ordering::SeqCst);
        #[cfg(debug_assertions)]
        record_io(bundle, IoObserveKind::Issued, observe_ticket, 0, None, false);
        let start = native_window(|| {
            if bundle.skip_native_io.load(Ordering::SeqCst) {
                return IssueStart::Failed(0);
            }
            #[cfg(debug_assertions)]
            if take_pending_native(bundle) {
                return issue_pending_overlapped_write()
                    .map(|(op, _, _)| IssueStart::Pending(op))
                    .unwrap_or(IssueStart::Failed(0));
            }
            issue_write_bytes(handle, payload)
        });
        let outcome = match start {
            IssueStart::Immediate { written } => {
                let outcome = if written as usize == payload_len {
                    NativeOutcome::Delivered { written }
                } else {
                    NativeOutcome::IoFailed
                };
                transition.commit(outcome)?;
                outcome
            }
            IssueStart::Failed(_) => {
                let outcome = NativeOutcome::IoFailed;
                transition.commit(outcome)?;
                outcome
            }
            IssueStart::Pending(op) => {
                let role = PinRole::Data {
                    occupant: ticket,
                    payload_len,
                    kind,
                    reserved_seq,
                };
                let mut finalizer = PinFinalizerGuard::begin(bundle, shared, op, role)?;
                transition.handoff_pending();
                let obs = finalizer.query();
                let class = finalizer
                    .op
                    .as_ref()
                    .expect("pin finalizer op")
                    .classify_payload(&obs, finalizer.cancel_requested());
                if matches!(class, WriteResult::Unknown) {
                    finalizer.park_unknown();
                    drop(lease);
                    return Err(ErrorCode::StateUnknown);
                }
                finalizer.finish(class)
            }
        };
        drop(lease);
        Ok(outcome)
    }

    pub(super) fn issue_resize(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
        cols: i16,
        rows: i16,
    ) -> Result<NativeOutcome, ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        #[cfg(debug_assertions)]
        wait_if_held_issue(bundle, ticket);
        let ticket = ticket.id;
        let mut transition = NativeTransitionGuard::new(bundle, ticket);
        if !(1..=32767).contains(&cols) || !(1..=32767).contains(&rows) {
            let mut g = lock_run(bundle);
            if matches!(g.ctrl().data_slot, DataSlot::HpconBusy { occupant } if occupant == ticket)
            {
                g.ctrl().data_slot = DataSlot::Sealing {
                    occupant: ticket,
                    payload_len: 0,
                    kind: DataKind::Resize,
                    reserved_seq: None,
                    outcome: NativeOutcome::IoFailed,
                };
                g.notify_all();
            }
            return Err(ErrorCode::InvalidRequest);
        }
        let (lease, hpcon) = {
            let mut g = lock_run(bundle);
            match g.ctrl().data_slot {
                DataSlot::HpconBusy { occupant } if occupant == ticket => {
                    if g.ctrl().stop_flag
                        || g.ctrl().ticket_cancelled(ticket)
                        || !bundle.generation_visible.load(Ordering::SeqCst)
                        || g.ctrl().pty_closed
                    {
                        let outcome = NativeOutcome::Aborted;
                        g.ctrl().data_slot = DataSlot::Sealing {
                            occupant: ticket,
                            payload_len: 0,
                            kind: DataKind::Resize,
                            reserved_seq: None,
                            outcome,
                        };
                        g.notify_all();
                        return Ok(outcome);
                    }
                    let lease = g.try_acquire(LeaseKind::Hpcon)?;
                    let hpcon = g
                        .ctrl()
                        .hpcon_handle
                        .map(|h| h.0)
                        .ok_or(ErrorCode::NotRunning)?;
                    (lease, hpcon)
                }
                DataSlot::Sealing {
                    occupant, outcome, ..
                } if occupant == ticket => {
                    return Ok(outcome);
                }
                _ => return Err(ErrorCode::StateUnknown),
            }
        };
        let ok = native_window(|| {
            if bundle.skip_native_io.load(Ordering::SeqCst) {
                return true;
            }
            resize_pseudoconsole(hpcon, cols, rows)
        });
        let outcome = if ok {
            NativeOutcome::Delivered { written: 0 }
        } else {
            NativeOutcome::IoFailed
        };
        transition.commit(outcome)?;
        drop(lease);
        if ok {
            Ok(outcome)
        } else {
            Err(ErrorCode::RuntimeFailed)
        }
    }

    pub(super) fn reserved_input_seq(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
    ) -> Result<Option<u64>, ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        let mut g = lock_run(bundle);
        let front_matches = g.ctrl().fifo.front().is_some_and(|entry| {
            entry.ticket == ticket.id && entry.operation_key == ticket.operation_key
        });
        if !front_matches {
            return Err(ErrorCode::StateUnknown);
        }
        match g.ctrl().data_slot {
            DataSlot::Admitted {
                occupant,
                reserved_seq,
                ..
            }
            | DataSlot::Pinned {
                occupant,
                reserved_seq,
                ..
            }
            | DataSlot::Sealing {
                occupant,
                reserved_seq,
                ..
            } if occupant == ticket.id => Ok(reserved_seq),
            DataSlot::HpconBusy { occupant } if occupant == ticket.id => Ok(None),
            _ => Err(ErrorCode::StateUnknown),
        }
    }

    pub(super) fn commit_data_with<T, E>(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
        protocol_seal: bool,
        commit: impl FnOnce(Option<u64>) -> Result<T, E>,
    ) -> Result<Result<T, E>, ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        let bound_ticket = ticket;
        #[cfg(debug_assertions)]
        let observe_ticket = ticket;
        let ticket = ticket.id;
        let mut g = lock_run(bundle);
        let front_matches = g.ctrl().fifo.front().is_some_and(|entry| {
            entry.ticket == ticket && entry.operation_key == bound_ticket.operation_key
        });
        if !front_matches {
            return Err(ErrorCode::StateUnknown);
        }
        match g.ctrl().data_slot {
            DataSlot::Sealing {
                occupant,
                payload_len,
                kind,
                reserved_seq,
                outcome,
            } if occupant == ticket => {
                let published_seq = if matches!(kind, DataKind::Write | DataKind::Key)
                    && matches!(outcome, NativeOutcome::Delivered { written } if written as usize == payload_len)
                {
                    reserved_seq
                } else {
                    None
                };
                let committed = match commit(published_seq) {
                    Ok(value) => value,
                    Err(error) => return Ok(Err(error)),
                };
                if matches!(kind, DataKind::Write | DataKind::Key) {
                    if let NativeOutcome::Delivered { written } = outcome {
                        if written as usize == payload_len {
                            let Some(seq) = reserved_seq else {
                                return Err(ErrorCode::StateUnknown);
                            };
                            g.ctrl().input_seq = seq;
                        }
                    }
                }
                if g.ctrl().fifo.front().map(|e| e.ticket) == Some(ticket) {
                    g.ctrl().fifo.pop_front();
                }
                g.ctrl().data_slot = DataSlot::Free;
                #[cfg(debug_assertions)]
                record_io(
                    bundle,
                    IoObserveKind::Finished,
                    observe_ticket,
                    g.ctrl().input_seq,
                    g.ctrl().fifo.front().map(|e| e.ticket),
                    true,
                );
                g.notify_all();
                Ok(Ok(committed))
            }
            DataSlot::RetainedUnknown {
                occupant,
                protocol_sealed: false,
            } if occupant == ticket && protocol_seal => {
                let committed = match commit(None) {
                    Ok(value) => value,
                    Err(error) => return Ok(Err(error)),
                };
                g.ctrl().data_slot = DataSlot::RetainedUnknown {
                    occupant,
                    protocol_sealed: true,
                };
                g.notify_all();
                Ok(Ok(committed))
            }
            DataSlot::UnknownSealPending { occupant }
                if occupant == ticket && protocol_seal =>
            {
                let committed = match commit(None) {
                    Ok(value) => value,
                    Err(error) => return Ok(Err(error)),
                };
                g.ctrl().fifo.pop_front();
                g.ctrl().data_slot = DataSlot::Free;
                g.notify_all();
                Ok(Ok(committed))
            }
            _ => Err(ErrorCode::StateUnknown),
        }
    }

    #[cfg(test)]
    mod unknown_seal_order_tests {
        use super::*;

        fn pending_unknown() -> (Arc<RunBundle>, DataTicket, DataTicket) {
            let owner = RunBundle::new_test(1);
            let original = begin_data(&owner, DataKind::Write, 1).expect("admit original");
            let sibling = enqueue_data(&owner, DataKind::Key, 1, None).expect("queue sibling");
            let mut guard = lock_run(&owner);
            assert_eq!(guard.ctrl().data_slot.occupant(), Some(original.id));
            guard.ctrl().data_slot = DataSlot::RetainedUnknown {
                occupant: original.id,
                protocol_sealed: false,
            };
            drop(guard);
            (owner, original, sibling)
        }

        #[test]
        fn protocol_first_keeps_native_ownership_until_completion() {
            let (owner, original, sibling) = pending_unknown();
            let mut seals = 0;
            assert_eq!(
                commit_data_with(&owner, original, true, |seq| {
                    assert_eq!(seq, None);
                    seals += 1;
                    Ok::<(), ()>(())
                }),
                Ok(Ok(()))
            );
            assert_eq!(seals, 1);
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::RetainedUnknown);
            assert_eq!(snapshot(&owner).fifo_ids, vec![original.id, sibling.id]);
            assert_eq!(snapshot(&owner).input_seq, 0);
            assert_eq!(commit_data_with(&owner, original, true, |_| Ok::<(), ()>(())), Err(ErrorCode::StateUnknown));
            {
                let mut guard = lock_run(&owner);
                settle_retained_unknown(guard.ctrl(), sibling.id);
            }
            assert_eq!(snapshot(&owner).fifo_ids, vec![original.id, sibling.id]);
            {
                let mut guard = lock_run(&owner);
                settle_retained_unknown(guard.ctrl(), original.id);
            }
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::Free);
            assert_eq!(snapshot(&owner).fifo_ids, vec![sibling.id]);
            assert_eq!(snapshot(&owner).input_seq, 0);
        }

        #[test]
        fn native_first_preserves_original_seal_right_and_sibling() {
            let (owner, original, sibling) = pending_unknown();
            {
                let mut guard = lock_run(&owner);
                settle_retained_unknown(guard.ctrl(), original.id);
            }
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::Sealing);
            assert_eq!(snapshot(&owner).fifo_ids, vec![original.id, sibling.id]);
            assert_eq!(enqueue_data(&owner, DataKind::Key, 1, None), Err(ErrorCode::StateUnknown));
            assert_eq!(commit_data_with(&owner, sibling, true, |_| Ok::<(), ()>(())), Err(ErrorCode::StateUnknown));
            assert_eq!(commit_data_with(&owner, original, false, |_| Ok::<(), ()>(())), Err(ErrorCode::StateUnknown));
            let mut seals = 0;
            assert_eq!(
                commit_data_with(&owner, original, true, |seq| {
                    assert_eq!(seq, None);
                    seals += 1;
                    Ok::<(), ()>(())
                }),
                Ok(Ok(()))
            );
            assert_eq!(seals, 1);
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::Free);
            assert_eq!(snapshot(&owner).fifo_ids, vec![sibling.id]);
            assert_eq!(snapshot(&owner).input_seq, 0);
            assert_eq!(commit_data_with(&owner, original, true, |_| Ok::<(), ()>(())), Err(ErrorCode::StateUnknown));
        }

        #[test]
        fn lease_acquire_failure_still_seals_original_slot() {
            let owner = RunBundle::new_test(1);
            let original = begin_data(&owner, DataKind::Write, 1).expect("admit original");
            let sibling = enqueue_data(&owner, DataKind::Key, 1, None).expect("queue sibling");
            {
                let mut guard = lock_run(&owner);
                guard.ctrl().input_admission = Admission::Sealed;
            }
            assert_eq!(issue_write(&owner, None, original, b"x"), Err(ErrorCode::StateUnknown));
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::Sealing);
            assert_eq!(snapshot(&owner).fifo_ids, vec![original.id, sibling.id]);
            let mut sealed = false;
            assert_eq!(
                commit_data_with(&owner, original, true, |seq| {
                    assert_eq!(seq, None);
                    sealed = true;
                    Ok::<(), ()>(())
                }),
                Ok(Ok(()))
            );
            assert!(sealed);
            assert_eq!(snapshot(&owner).data_slot, TestingDataSlot::Free);
            assert_eq!(snapshot(&owner).fifo_ids, vec![sibling.id]);
            assert_eq!(snapshot(&owner).input_seq, 0);
        }
    }

    pub(super) fn finish_data(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
    ) -> Result<(), ErrorCode> {
        match commit_data_with(bundle, ticket, false, |_| Ok::<(), ()>(()))? {
            Ok(()) => Ok(()),
            Err(()) => unreachable!("infallible terminal commit"),
        }
    }

    pub(super) fn reject_unissued(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
    ) -> Result<(), ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        let mut g = lock_run(bundle);
        match g.ctrl().data_slot {
            DataSlot::Admitted {
                occupant,
                payload_len,
                kind,
                reserved_seq,
            } if occupant == ticket.id => {
                g.ctrl().data_slot = DataSlot::Sealing {
                    occupant,
                    payload_len,
                    kind,
                    reserved_seq,
                    outcome: NativeOutcome::Aborted,
                };
                g.notify_all();
                Ok(())
            }
            DataSlot::HpconBusy { occupant } if occupant == ticket.id => {
                g.ctrl().data_slot = DataSlot::Sealing {
                    occupant,
                    payload_len: 0,
                    kind: DataKind::Resize,
                    reserved_seq: None,
                    outcome: NativeOutcome::Aborted,
                };
                g.notify_all();
                Ok(())
            }
            DataSlot::Sealing { occupant, .. } if occupant == ticket.id => Ok(()),
            DataSlot::Free => Ok(()),
            _ => {
                g.ctrl().cancel_ticket(ticket.id);
                g.notify_all();
                Ok(())
            }
        }
    }

    pub(super) fn cancel_data(
        bundle: &Arc<RunBundle>,
        ticket: DataTicket,
    ) -> Result<(), ErrorCode> {
        ticket_run_matches(bundle, ticket)?;
        let mut g = lock_run(bundle);
        let id = ticket.id;
        let occupying = g.ctrl().data_slot.occupant() == Some(id)
            && matches!(
                g.ctrl().data_slot,
                DataSlot::Pinned { .. } | DataSlot::RetainedUnknown { .. }
            );
        if occupying {
            request_pin_cancel(g.ctrl());
        }
        g.ctrl().cancel_ticket(id);
        #[cfg(debug_assertions)]
        record_io(
            bundle,
            IoObserveKind::Cancelled,
            ticket,
            g.ctrl().input_seq,
            g.ctrl().fifo.front().map(|e| e.ticket),
            matches!(g.ctrl().data_slot, DataSlot::Free),
        );
        g.notify_all();
        Ok(())
    }

    pub(super) fn cancel_all_fifo_and_pins(bundle: &Arc<RunBundle>) {
        let mut g = lock_run(bundle);
        g.ctrl().cancel_all();
        if matches!(
            g.ctrl().data_slot,
            DataSlot::Pinned { .. } | DataSlot::RetainedUnknown { .. }
        ) {
            request_pin_cancel(g.ctrl());
        }
        g.notify_all();
    }

    pub(super) fn retain_any_pin(bundle: &Arc<RunBundle>) {
        let mut g = lock_run(bundle);
        if let Some(op) = g.ctrl().pin.take() {
            g.ctrl().write_pending = true;
            bundle.write_pending.store(true, Ordering::SeqCst);
            retain_write(op);
        }
    }

    pub(super) fn install_pinned_write(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
        op: PinnedWrite,
    ) -> Result<(), ErrorCode> {
        let mut g = lock_run(bundle);
        if let Some(previous) = g.ctrl().pin.take() {
            retain_write(previous);
        }
        g.ctrl().write_identity = Some(SendWriteIdentity::from_identity(op.identity()));
        g.ctrl().write_pending = true;
        let reserved_seq = next_input_seq(g.ctrl().input_seq).ok();
        g.ctrl().pin_role = Some(PinRole::Data {
            occupant: 0,
            payload_len: 1,
            kind: DataKind::Write,
            reserved_seq,
        });
        g.ctrl().pin_finalizing = false;
        g.ctrl().pin_cancel_requested = false;
        g.ctrl().data_slot = DataSlot::Pinned {
            occupant: 0,
            payload_len: 1,
            kind: DataKind::Write,
            reserved_seq,
        };
        g.ctrl().pin = Some(op);
        if let Some(shared) = shared {
            shared.write_pending.store(true, Ordering::SeqCst);
            shared.write_issued.store(true, Ordering::SeqCst);
        }
        bundle.write_pending.store(true, Ordering::SeqCst);
        Ok(())
    }

    pub(super) fn set_stop_interrupt(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
    ) {
        let mut g = lock_run(bundle);
        g.ctrl().stop_flag = true;
        g.ctrl().interrupt_admitted = true;
        if let Some(shared) = shared {
            shared.interrupt_admitted.store(true, Ordering::SeqCst);
        }
        if matches!(
            g.ctrl().data_slot,
            DataSlot::Pinned { .. } | DataSlot::RetainedUnknown { .. }
        ) {
            request_pin_cancel(g.ctrl());
        }
        g.notify_all();
    }

    pub(super) fn write_teardown_ctrl_c(shared: &super::SessionShared) -> bool {
        let bundle = &shared.owner;
        if shared.ctrl_c_delivered.load(Ordering::SeqCst) {
            return true;
        }
        let acquired = {
            let mut g = lock_run(bundle);
            if !g.ctrl().begin_teardown_ctrl() {
                return false;
            }
            let lease = match g.try_acquire(LeaseKind::Input) {
                Ok(lease) => lease,
                Err(_) => return false,
            };
            let handle = match g.ctrl().input_handle {
                Some(h) if !h.0.is_null() && h.0 != INVALID_HANDLE_VALUE => h.0,
                _ => {
                    lease.release_under(g.ctrl());
                    return false;
                }
            };
            Some((lease, handle))
        };
        let Some((lease, handle)) = acquired else {
            return false;
        };
        shared.write_issued.store(true, Ordering::SeqCst);
        #[cfg(test)]
        bundle.test_native_issues.fetch_add(1, Ordering::SeqCst);
        let start = native_window(|| {
            if bundle.skip_native_io.load(Ordering::SeqCst) {
                return IssueStart::Failed(0);
            }
            issue_write_byte(handle, CTRL_C)
        });
        let delivered = {
            let mut g = lock_run(bundle);
            match start {
                IssueStart::Immediate { written } if written == 1 => {
                    if let Ok(mut count) = shared.ctrl_c_writes.lock() {
                        *count += 1;
                    }
                    shared.ctrl_c_delivered.store(true, Ordering::SeqCst);
                    g.ctrl().write_pending = false;
                    g.ctrl().pin_role = None;
                    g.ctrl().pin_finalizing = false;
                    g.ctrl().pin_cancel_requested = false;
                    g.ctrl().write_identity = None;
                    sync_pending(bundle, g.ctrl(), Some(shared));
                    true
                }
                IssueStart::Pending(op) => {
                    drop(g);
                    let Ok(finalizer) = PinFinalizerGuard::begin(
                        bundle,
                        Some(shared),
                        op,
                        PinRole::TeardownCtrl,
                    ) else {
                        return false;
                    };
                    finalizer.park_unknown();
                    false
                }
                IssueStart::Immediate { .. } | IssueStart::Failed(_) => false,
            }
        };
        drop(lease);
        delivered
    }

    pub(super) fn physical_close_hpcon(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
    ) {
        let handle = {
            let mut g = lock_run(bundle);
            g.ctrl().hpcon_admission = Admission::Sealed;
            g.notify_all();
            g.wait_while(|c| c.hpcon_lease_count > 0);
            let handle = g.ctrl().hpcon_handle.take().map(|h| h.0);
            #[cfg(debug_assertions)]
            {
                g.ctrl().close_target_hpcon = handle.map(|value| value as usize);
                g.ctrl().close_skip_native_io =
                    Some(bundle.skip_native_io.load(Ordering::SeqCst));
            }
            handle
        };
        if let Some(h) = handle {
            #[cfg(debug_assertions)]
            {
                let output_bytes = shared
                    .and_then(|value| value.output.lock().ok().map(|ring| ring.decoded_len()));
                let mut g = lock_run(bundle);
                g.ctrl().close_output_bytes = output_bytes;
            }
            if h != 0 && !bundle.skip_native_io.load(Ordering::SeqCst) {
                #[cfg(debug_assertions)]
                {
                    let mut g = lock_run(bundle);
                    g.ctrl().close_native_entered = true;
                }
                native_window(|| unsafe {
                    ClosePseudoConsole(h);
                });
                #[cfg(debug_assertions)]
                {
                    let mut g = lock_run(bundle);
                    g.ctrl().close_native_returned = true;
                }
            }
        }
        {
            let mut g = lock_run(bundle);
            g.ctrl().pty_closed = true;
            g.notify_all();
        }
        if let Some(shared) = shared {
            shared.pty_closed.store(true, Ordering::SeqCst);
        }
    }

    pub(super) fn physical_close_input(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
    ) {
        let handle = {
            let mut g = lock_run(bundle);
            g.ctrl().input_admission = Admission::Sealed;
            g.notify_all();
            g.wait_while(|c| c.input_lease_count > 0 || c.pin_finalizing);
            if g.ctrl().write_pending {
                sync_pending(bundle, g.ctrl(), shared);
                return;
            }
            g.ctrl().input_handle.take().map(|h| h.0)
        };
        if let Some(h) = handle {
            if !h.is_null()
                && h != INVALID_HANDLE_VALUE
                && !bundle.skip_native_io.load(Ordering::SeqCst)
            {
                native_window(|| unsafe {
                    CloseHandle(h);
                });
            }
        }
    }

    pub(super) fn finish_pin_after_unblocker(
        bundle: &Arc<RunBundle>,
        shared: &super::SessionShared,
    ) {
        let Some(mut finalizer) = PinFinalizerGuard::take_pending(bundle, Some(shared)) else {
            return;
        };
        finalizer.request_cancel();
        finalizer.wait_event();
        let obs = finalizer.query();
        let class = match finalizer.role {
            PinRole::Data { .. } => finalizer
                .op
                .as_ref()
                .expect("pin finalizer op")
                .classify_payload(&obs, true),
            PinRole::TeardownCtrl => PinnedWrite::classify(&obs, true),
        };
        if matches!(class, WriteResult::Unknown) {
            finalizer.park_unknown();
            return;
        }
        let _ = finalizer.finish(class);
    }

    pub(super) fn resize_complete(
        bundle: &Arc<RunBundle>,
        cols: i16,
        rows: i16,
    ) -> Result<(), ErrorCode> {
        if !(1..=32767).contains(&cols) || !(1..=32767).contains(&rows) {
            return Err(ErrorCode::RuntimeFailed);
        }
        let ticket = begin_data(bundle, DataKind::Resize, 0)?;
        match issue_resize(bundle, ticket, cols, rows) {
            Ok(_) => finish_data(bundle, ticket),
            Err(ErrorCode::RuntimeFailed) => {
                let _ = finish_data(bundle, ticket);
                Err(ErrorCode::RuntimeFailed)
            }
            Err(error) => Err(error),
        }
    }

    pub(super) fn testing_admit_write(
        bundle: &Arc<RunBundle>,
        occupant: u64,
        payload_len: usize,
    ) -> Result<(), ErrorCode> {
        let mut g = lock_run(bundle);
        g.ctrl().reap_all();
        if matches!(g.ctrl().data_slot, DataSlot::RetainedUnknown { .. } | DataSlot::UnknownSealPending { .. }) {
            return Err(ErrorCode::StateUnknown);
        }
        if !matches!(g.ctrl().data_slot, DataSlot::Free) {
            return Err(ErrorCode::AlreadyRunning);
        }
        if g.ctrl().stop_flag || g.ctrl().pty_closed || g.ctrl().input_admission != Admission::Open
        {
            return Err(ErrorCode::StateUnknown);
        }
        g.ctrl().fifo.push_back(FifoEntry {
            ticket: occupant,
            operation_key: None,
            kind: DataKind::Write,
            cancel_requested: false,
            payload_len,
        });
        let reserved_seq = next_input_seq(g.ctrl().input_seq).ok();
        g.ctrl().data_slot = DataSlot::Admitted {
            occupant,
            payload_len,
            kind: DataKind::Write,
            reserved_seq,
        };
        if payload_len == 0 {
            g.ctrl().data_slot = DataSlot::Sealing {
                occupant,
                payload_len: 0,
                kind: DataKind::Write,
                reserved_seq,
                outcome: NativeOutcome::Delivered { written: 0 },
            };
        }
        Ok(())
    }

    pub(super) fn testing_begin_teardown_ctrl(bundle: &Arc<RunBundle>) -> bool {
        let mut g = lock_run(bundle);
        g.ctrl().begin_teardown_ctrl()
    }

    pub(super) fn testing_set_data_slot_free(bundle: &Arc<RunBundle>) {
        let mut g = lock_run(bundle);
        g.ctrl().data_slot = DataSlot::Free;
        g.notify_all();
    }

    pub(super) fn testing_set_input_seq(bundle: &Arc<RunBundle>, seq: u64) {
        let mut g = lock_run(bundle);
        g.ctrl().input_seq = seq;
    }

    pub(super) fn panic_after_acquire_input(bundle: &Arc<RunBundle>) {
        let mut run = lock_run(bundle);
        let _lease = run.try_acquire(LeaseKind::Input).expect("lease");
        panic!("unwind with live lease");
    }

    pub(super) fn hold_kind(
        bundle: &Arc<RunBundle>,
        hpcon: bool,
        acquired: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        let kind = if hpcon {
            LeaseKind::Hpcon
        } else {
            LeaseKind::Input
        };
        let lease = {
            let mut g = lock_run(bundle);
            g.try_acquire(kind).expect("hold lease")
        };
        let _ = acquired.send(());
        let _ = release.recv();
        drop(lease);
    }

    pub(super) fn testing_query_pending_to_retained_unknown(
        bundle: &Arc<RunBundle>,
        shared: Option<&super::SessionShared>,
    ) {
        let Some(mut finalizer) = PinFinalizerGuard::take_pending(bundle, shared) else {
            return;
        };
        finalizer.request_cancel();
        finalizer.park_unknown();
    }

    pub(super) fn input_handle_is_some(bundle: &Arc<RunBundle>) -> bool {
        let mut g = lock_run(bundle);
        g.ctrl().input_handle.is_some()
    }

    pub(super) fn hpcon_handle_is_some(bundle: &Arc<RunBundle>) -> bool {
        let mut g = lock_run(bundle);
        g.ctrl().hpcon_handle.map(|h| h.0).is_some_and(|h| h != 0)
    }
}

#[cfg(debug_assertions)]
pub use native_owner::{IoObserveEvent, IoObserveKind, RunIoObserveGuard};

#[cfg(debug_assertions)]
pub(crate) fn attach_io_observe(
    shared: &SessionShared,
) -> Result<RunIoObserveGuard, ErrorCode> {
    native_owner::attach_observe(&shared.owner)
}

pub struct SessionShared {
    pub output: Mutex<OutputRing>,
    pub handle_signaled: AtomicBool,
    pub exit_code: Mutex<Option<u32>>,
    pub interrupt_admitted: AtomicBool,
    pub ctrl_c_delivered: AtomicBool,
    pub ctrl_c_writes: Mutex<u32>,
    pub write_pending: AtomicBool,
    pub write_issued: AtomicBool,
    pub write_cancelled: AtomicBool,
    pub drain_flag: AtomicBool,
    pub reader_returned: AtomicBool,
    pub waiter_returned: AtomicBool,
    pub teardown_returned: AtomicBool,
    pub reader_error: AtomicBool,
    pub pty_closed: AtomicBool,
    pub force_killed: AtomicBool,
    pub cleanup_queued: AtomicBool,
    pub stop_reader: AtomicBool,
    pub cleanup_mu: Mutex<()>,
    pub cleanup_cv: Condvar,
    job: JobOwner,
    pub(crate) owner: Arc<native_owner::RunBundle>,
    pub(crate) run_id: RunId,
    exit_callback: Mutex<Option<Arc<dyn Fn(RunId) + Send + Sync>>>,
}

impl SessionShared {
    pub fn new(run_id: RunId) -> Arc<Self> {
        let owner = native_owner::RunBundle::new();
        Arc::new(Self {
            output: Mutex::new(OutputRing::new()),
            handle_signaled: AtomicBool::new(false),
            exit_code: Mutex::new(None),
            interrupt_admitted: AtomicBool::new(false),
            ctrl_c_delivered: AtomicBool::new(false),
            ctrl_c_writes: Mutex::new(0),
            write_pending: AtomicBool::new(false),
            write_issued: AtomicBool::new(false),
            write_cancelled: AtomicBool::new(false),
            drain_flag: AtomicBool::new(false),
            reader_returned: AtomicBool::new(false),
            waiter_returned: AtomicBool::new(false),
            teardown_returned: AtomicBool::new(false),
            reader_error: AtomicBool::new(false),
            pty_closed: AtomicBool::new(false),
            force_killed: AtomicBool::new(false),
            cleanup_queued: AtomicBool::new(false),
            stop_reader: AtomicBool::new(false),
            cleanup_mu: Mutex::new(()),
            cleanup_cv: Condvar::new(),
            job: JobOwner::new(),
            owner,
            run_id,
            exit_callback: Mutex::new(None),
        })
    }

    pub fn request_cleanup(&self) {
        if self.cleanup_queued.swap(true, Ordering::SeqCst) {
            return;
        }
        let _guard = self.cleanup_mu.lock().expect("cleanup");
        self.cleanup_cv.notify_all();
    }

    pub(crate) fn set_exit_callback(&self, callback: Arc<dyn Fn(RunId) + Send + Sync>) {
        if let Ok(mut slot) = self.exit_callback.lock() {
            *slot = Some(callback);
        }
    }

    pub(crate) fn invoke_exit_callback(&self) {
        if native_owner::run_held() > 0 {
            return;
        }
        let callback = self.exit_callback.lock().ok().and_then(|slot| slot.clone());
        if let Some(callback) = callback {
            callback(self.run_id.clone());
        }
    }

    pub(crate) fn set_generation_open(&self, open: bool) {
        native_owner::set_generation_open(&self.owner, open);
    }

    pub(crate) fn enqueue_data(
        &self,
        kind: DataKind,
        payload_len: usize,
        operation_key: Option<[u8; 36]>,
    ) -> Result<DataTicket, ErrorCode> {
        native_owner::enqueue_data(&self.owner, kind, payload_len, operation_key)
    }

    pub(crate) fn admit_data(&self, ticket: DataTicket) -> Result<(), ErrorCode> {
        native_owner::admit_data(&self.owner, ticket)
    }

    pub(crate) fn begin_data(
        &self,
        kind: DataKind,
        payload_len: usize,
    ) -> Result<DataTicket, ErrorCode> {
        native_owner::begin_data(&self.owner, kind, payload_len)
    }

    pub(crate) fn issue_write(
        &self,
        ticket: DataTicket,
        payload: &[u8],
    ) -> Result<NativeOutcome, ErrorCode> {
        native_owner::issue_write(&self.owner, Some(self), ticket, payload)
    }

    pub(crate) fn issue_resize(
        &self,
        ticket: DataTicket,
        cols: i16,
        rows: i16,
    ) -> Result<NativeOutcome, ErrorCode> {
        native_owner::issue_resize(&self.owner, ticket, cols, rows)
    }

    pub(crate) fn finish_data(&self, ticket: DataTicket) -> Result<(), ErrorCode> {
        native_owner::finish_data(&self.owner, ticket)
    }

    pub(crate) fn reserved_input_seq(
        &self,
        ticket: DataTicket,
    ) -> Result<Option<u64>, ErrorCode> {
        native_owner::reserved_input_seq(&self.owner, ticket)
    }

    pub(crate) fn commit_data_with<T, E>(
        &self,
        ticket: DataTicket,
        commit: impl FnOnce(Option<u64>) -> Result<T, E>,
    ) -> Result<Result<T, E>, ErrorCode> {
        native_owner::commit_data_with(&self.owner, ticket, true, commit)
    }

    pub(crate) fn reject_unissued(&self, ticket: DataTicket) -> Result<(), ErrorCode> {
        native_owner::reject_unissued(&self.owner, ticket)
    }

    pub(crate) fn cancel_data(&self, ticket: DataTicket) -> Result<(), ErrorCode> {
        native_owner::cancel_data(&self.owner, ticket)
    }

    pub(crate) fn cancel_all_fifo_and_pins(&self) {
        native_owner::cancel_all_fifo_and_pins(&self.owner);
    }

    pub(crate) fn retain_pin(&self) {
        native_owner::retain_any_pin(&self.owner);
        self.write_pending.store(
            self.write_pending.load(Ordering::SeqCst)
                || native_owner::snapshot(&self.owner).write_pending,
            Ordering::SeqCst,
        );
    }

    pub(crate) fn install_pinned_write(&self, op: PinnedWrite) -> Result<(), ErrorCode> {
        native_owner::install_pinned_write(&self.owner, Some(self), op)
    }

    pub(crate) fn set_stop_interrupt(&self) {
        native_owner::set_stop_interrupt(&self.owner, Some(self));
    }

    fn install_job(&self, job: RawHandle) {
        self.job.install(job);
    }

    pub(crate) fn job_active_processes(&self) -> Option<u32> {
        self.job.active_processes()
    }

    pub(crate) fn take_job_for_containment(&self) -> HANDLE {
        self.job.take_for_containment()
    }

    #[cfg(debug_assertions)]
    pub(crate) fn fail_job_terminate_once(&self) {
        self.job.fail_terminate_once();
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_job_stop_stats(
        &self,
    ) -> (u32, bool, bool, bool, Option<u32>, Option<u32>) {
        self.job.testing_stats()
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_inspect_cleanup(&self) -> Result<TestingCleanupIoSnapshot, ErrorCode> {
        native_owner::inspect_cleanup(&self.owner)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_inspect_single_member(&self, process: HANDLE) -> Result<(), ErrorCode> {
        self.job.inspect_single_member(process)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_inspect_job_ownership(&self) -> Result<(bool, Option<u32>), ErrorCode> {
        self.job.inspect_ownership()
    }

    pub(crate) fn io_snapshot(&self) -> TestingRunIoStats {
        native_owner::snapshot(&self.owner)
    }

    pub(crate) fn occupancy_blocks_close(&self) -> bool {
        native_owner::occupancy_blocks_close(&self.owner)
    }

    pub(crate) fn resize_complete(&self, cols: i16, rows: i16) -> Result<(), ErrorCode> {
        if self.pty_closed.load(Ordering::SeqCst) {
            return Err(ErrorCode::NotRunning);
        }
        native_owner::resize_complete(&self.owner, cols, rows)
    }
}

pub struct RunSession {
    pub project_id: ProjectId,
    pub pane_id: PaneId,
    pub run_id: RunId,
    pub phase: SessionPhase,
    pub published: bool,
    pub current: bool,
    pub process_state: Process,
    pub work: Work,
    pub started_at: Option<Timestamp>,
    pub ended_at: Option<Timestamp>,
    pub observed_root: Option<ObservedRoot>,
    pub child: Option<PreparedChild>,
    pub shared: Arc<SessionShared>,
    pub reader: Option<JoinHandle<()>>,
    pub waiter: Option<JoinHandle<()>>,
    pub teardown: Option<JoinHandle<()>>,
    pub inherit_owner: bool,
    pub inherit_public: bool,
    pub b_inherit_handles: bool,
    #[cfg(debug_assertions)]
    pub(crate) testing_wait_for_exit_before_observe: bool,
}

impl RunSession {
    pub fn new(project_id: ProjectId, pane_id: PaneId, run_id: RunId) -> Self {
        Self {
            project_id,
            pane_id,
            run_id: run_id.clone(),
            phase: SessionPhase::Preparing,
            published: false,
            current: false,
            process_state: Process::Starting,
            work: Work::Unknown,
            started_at: None,
            ended_at: None,
            observed_root: None,
            child: None,
            shared: SessionShared::new(run_id),
            reader: None,
            waiter: None,
            teardown: None,
            inherit_owner: false,
            inherit_public: false,
            b_inherit_handles: false,
            #[cfg(debug_assertions)]
            testing_wait_for_exit_before_observe: false,
        }
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_wait_for_process_exit(&self) -> bool {
        let Some(child) = self.child.as_ref() else {
            return false;
        };
        unsafe { WaitForSingleObject(child.process.0, INFINITE) == WAIT_OBJECT_0 }
    }

    pub fn attach_child(&mut self, mut child: PreparedChild) {
        self.inherit_owner = child.inherit_owner;
        self.inherit_public = child.inherit_public;
        self.b_inherit_handles = child.b_inherit_handles;
        self.shared.install_job(RawHandle(child.job.take()));
        native_owner::install_handles(&self.shared.owner, child.input.take(), child.hpcon.take());
        self.child = Some(child);
    }

    pub fn session_clean(&self) -> bool {
        let force_killed = self.shared.force_killed.load(Ordering::SeqCst);
        self.phase != SessionPhase::Preparing
            && self.shared.handle_signaled.load(Ordering::SeqCst)
            && self.job_empty()
            && self.shared.drain_flag.load(Ordering::SeqCst)
            && self.shared.reader_returned.load(Ordering::SeqCst)
            && self.shared.waiter_returned.load(Ordering::SeqCst)
            && self.shared.teardown_returned.load(Ordering::SeqCst)
            && self.shared.pty_closed.load(Ordering::SeqCst)
            && self.shared.job.clean_termination(force_killed)
            && !self.shared.write_pending.load(Ordering::SeqCst)
    }

    pub fn job_empty(&self) -> bool {
        self.shared.job.is_empty()
    }

    pub fn start_idle_workers(&mut self) {
        let Some(child) = self.child.as_mut() else {
            return;
        };
        let output = SendHandle(child.output.take());
        let (process, close_wait_handle) = match duplicate_handle(child.process.0) {
            Some(handle) => (SendHandle(handle), true),
            None => (SendHandle(child.process.0), false),
        };
        let shared = Arc::clone(&self.shared);
        self.reader = Some(thread::spawn({
            let shared = Arc::clone(&shared);
            move || reader_loop(output, shared)
        }));
        self.waiter = Some(thread::spawn({
            let shared = Arc::clone(&shared);
            move || waiter_loop(process, shared, close_wait_handle)
        }));
        if self.teardown.is_none() {
            let shared = Arc::clone(&self.shared);
            let owner = Arc::clone(&self.shared.owner);
            self.teardown = Some(thread::spawn(move || teardown_idle(shared, owner)));
        }
    }

    pub fn queue_cleanup(&mut self) {
        self.shared.request_cleanup();
    }

    pub fn write_ctrl_c(&self) -> bool {
        write_ctrl_c_on(&self.shared)
    }

    pub fn ctrl_c_writes(&self) -> u32 {
        self.shared
            .ctrl_c_writes
            .lock()
            .map(|count| *count)
            .unwrap_or(0)
    }

    pub fn ctrl_c_delivered(&self) -> bool {
        self.shared.ctrl_c_delivered.load(Ordering::SeqCst)
    }

    pub fn observe_handle(&self) -> (Process, Work, Option<u32>) {
        let Some(child) = self.child.as_ref() else {
            return (Process::Unknown, Work::Unknown, None);
        };
        match handle_signaled(child.process.0) {
            Some(true) => {
                let code = exit_code(child.process.0);
                let work =
                    work_from_exit(code, self.shared.interrupt_admitted.load(Ordering::SeqCst));
                (Process::Exited, work, code)
            }
            Some(false) => (Process::Running, Work::Unknown, None),
            None => (Process::Unknown, Work::Unknown, None),
        }
    }
}

fn work_from_exit(code: Option<u32>, interrupted: bool) -> Work {
    if interrupted {
        return Work::Interrupted;
    }
    match code {
        Some(0) => Work::Unknown,
        Some(_) => Work::Failed,
        None => Work::Unknown,
    }
}

fn reader_loop(output: SendHandle, shared: Arc<SessionShared>) {
    let output = output.0;
    let mut buffer = [0u8; 4096];
    loop {
        let mut read = 0u32;
        let ok = unsafe {
            ReadFile(
                output,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut read,
                null_mut_overlapped(),
            )
        };
        let gle = if ok != 0 {
            0
        } else {
            unsafe { GetLastError() }
        };
        match classify_readfile(ok, read, gle) {
            ReadClass::Payload => {
                if let Ok(mut ring) = shared.output.lock() {
                    ring.push_bytes(&buffer[..read as usize], false);
                }
                continue;
            }
            ReadClass::TrueZero => continue,
            ReadClass::Drain => {
                if let Ok(mut ring) = shared.output.lock() {
                    ring.push_bytes(&[], true);
                }
                shared.drain_flag.store(true, Ordering::SeqCst);
            }
            ReadClass::ReadError => {
                let _ = ERROR_NO_DATA;
                shared.reader_error.store(true, Ordering::SeqCst);
            }
        }
        break;
    }
    unsafe {
        CloseHandle(output);
    }
    shared.reader_returned.store(true, Ordering::SeqCst);
    if let Ok(guard) = shared.cleanup_mu.lock() {
        shared.cleanup_cv.notify_all();
        drop(guard);
    }
}

fn waiter_loop(process: SendHandle, shared: Arc<SessionShared>, close_handle: bool) {
    let process = process.0;
    let wait = unsafe { WaitForSingleObject(process, INFINITE) };
    if wait != WAIT_OBJECT_0 {
        shared.waiter_returned.store(true, Ordering::SeqCst);
        if close_handle && process != INVALID_HANDLE_VALUE && !process.is_null() {
            unsafe {
                CloseHandle(process);
            }
        }
        return;
    }
    if let Some(code) = exit_code(process) {
        *shared.exit_code.lock().expect("exit") = Some(code);
    }
    shared.handle_signaled.store(true, Ordering::SeqCst);
    shared.request_cleanup();
    shared.waiter_returned.store(true, Ordering::SeqCst);
    if close_handle && process != INVALID_HANDLE_VALUE && !process.is_null() {
        unsafe {
            CloseHandle(process);
        }
    }
    shared.invoke_exit_callback();
}

fn teardown_idle(shared: Arc<SessionShared>, owner: Arc<native_owner::RunBundle>) {
    {
        let mut guard = shared.cleanup_mu.lock().expect("cleanup wait");
        while !shared.cleanup_queued.load(Ordering::SeqCst) {
            guard = shared.cleanup_cv.wait(guard).expect("cleanup wait");
        }
    }
    if shared.interrupt_admitted.load(Ordering::SeqCst) {
        let _ = write_ctrl_c_on(&shared);
        if matches!(
            shared.job.terminate_for_owner_interrupt(),
            JobTermination::OwnerApiSucceeded
        ) {
            shared.force_killed.store(true, Ordering::SeqCst);
        }
    }
    native_owner::physical_close_hpcon(&owner, Some(&shared));
    if shared.write_pending.load(Ordering::SeqCst) {
        native_owner::finish_pin_after_unblocker(&owner, &shared);
    }
    native_owner::physical_close_input(&owner, Some(&shared));
    shared.stop_reader.store(true, Ordering::SeqCst);
    {
        let mut guard = shared.cleanup_mu.lock().expect("reader wait");
        while !shared.reader_returned.load(Ordering::SeqCst) {
            guard = shared.cleanup_cv.wait(guard).expect("reader wait");
        }
    }
    if !shared.write_pending.load(Ordering::SeqCst) {
        shared.teardown_returned.store(true, Ordering::SeqCst);
    }
}

pub fn write_ctrl_c_on(shared: &SessionShared) -> bool {
    native_owner::write_teardown_ctrl_c(shared)
}

pub(crate) fn request_cancel_write(shared: &SessionShared) {
    shared.cancel_all_fifo_and_pins();
}

fn null_mut_overlapped() -> *mut windows_sys::Win32::System::IO::OVERLAPPED {
    std::ptr::null_mut()
}

pub fn now_timestamp() -> Option<Timestamp> {
    let stamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    Timestamp::new(&stamp).ok()
}

#[cfg(test)]
mod utf8_tests {
    use super::{clamp_text_to_envelope, json_string_len, OutputRing};
    use crate::contract::MAX_MESSAGE_BYTES;

    fn snap(ring: &OutputRing, cursor: Option<u64>, max_bytes: u64) -> (String, u64, bool, bool) {
        let slice = ring.snapshot(cursor, max_bytes, "run", "run");
        (slice.text, slice.next_cursor, slice.gap, slice.truncated)
    }

    #[test]
    fn malformed_preserves_neighbors() {
        let mut ring = OutputRing::new();
        ring.push_bytes(&[b'A', 0xff, b'B'], false);
        let (text, next, gap, truncated) = snap(&ring, None, 64);
        assert_eq!(text, "A\u{FFFD}B");
        assert_eq!(next, 5);
        assert!(gap);
        assert!(!truncated);
    }

    #[test]
    fn literal_replacement_is_not_gap() {
        let mut ring = OutputRing::new();
        ring.push_bytes("A\u{FFFD}B".as_bytes(), false);
        let (text, _, gap, _) = snap(&ring, None, 64);
        assert_eq!(text, "A\u{FFFD}B");
        assert!(!gap);
    }

    #[test]
    fn japanese_splits_and_one_byte_is_empty() {
        let mut ring = OutputRing::new();
        let bytes = "日本語".as_bytes();
        ring.push_bytes(&bytes[..1], false);
        let (text, next, gap, truncated) = snap(&ring, None, 64);
        assert_eq!(text, "");
        assert_eq!(next, 0);
        assert!(!gap);
        assert!(!truncated);
        ring.push_bytes(&bytes[1..], false);
        let (text, _, gap, _) = snap(&ring, None, 64);
        assert_eq!(text, "日本語");
        assert!(!gap);
        let (empty, _, _, truncated) = snap(&ring, None, 1);
        assert_eq!(empty, "");
        assert!(truncated);
    }

    #[test]
    fn emoji_and_incomplete_eof() {
        let mut ring = OutputRing::new();
        let bytes = "😀".as_bytes();
        ring.push_bytes(&bytes[..2], false);
        let (text, _, gap, _) = snap(&ring, None, 64);
        assert_eq!(text, "");
        assert!(!gap);
        ring.push_bytes(&[], true);
        let (text, _, gap, _) = snap(&ring, None, 64);
        assert_eq!(text, "\u{FFFD}");
        assert!(gap);
    }

    #[test]
    fn quote_escape_fits_envelope() {
        let text = "say \"hi\"\\\n";
        let escaped = json_string_len(text);
        assert!(escaped > text.len());
        let (clamped, truncated) = clamp_text_to_envelope(text, u64::MAX, escaped);
        assert_eq!(clamped, text);
        assert!(!truncated);
        let huge = "あ".repeat(400_000);
        let (clamped, truncated) =
            clamp_text_to_envelope(&huge, u64::MAX, MAX_MESSAGE_BYTES.saturating_sub(1024));
        assert!(truncated);
        assert!(!clamped.is_empty());
        assert!(json_string_len(&clamped) <= MAX_MESSAGE_BYTES);
    }
}

#[cfg(test)]
mod native_owner_proofs {
    use super::native_owner::{self, RunBundle};
    use super::{DataKind, NativeOutcome, RunId, RunSession, SessionShared, TestingDataSlot};
    use crate::contract::{ErrorCode, PaneId, ProjectId};
    use crate::runtime::spawn::issue_pending_overlapped_write;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc};
    use std::thread;
    use std::time::Duration;

    fn join(h: thread::JoinHandle<()>) {
        h.join().expect("thread join");
    }

    #[test]
    fn fifo_reverse_wake_and_cancelled_middle() {
        let owner = RunBundle::new_test(1);
        let other = RunBundle::new_test(2);

        let head = native_owner::begin_data(&owner, DataKind::Write, 0).expect("empty head");
        assert_eq!(
            native_owner::issue_write(&owner, None, head, &[]).expect("empty head issue"),
            NativeOutcome::Delivered { written: 0 }
        );
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Sealing
        );
        let middle =
            native_owner::enqueue_data(&owner, DataKind::Write, 1, None).expect("middle");
        let tail = native_owner::enqueue_data(&owner, DataKind::Write, 1, None).expect("tail");
        assert_ne!(head, middle);
        assert_ne!(middle, tail);
        assert_ne!(head, tail);
        assert_ne!(head.as_u64(), middle.as_u64());
        assert_ne!(middle.as_u64(), tail.as_u64());
        assert_ne!(head.as_u64(), tail.as_u64());
        let snap = native_owner::snapshot(&owner);
        assert_eq!(
            snap.fifo_ids,
            vec![head.as_u64(), middle.as_u64(), tail.as_u64()]
        );
        assert_eq!(snap.fifo_head_id, Some(head.as_u64()));

        assert_eq!(
            native_owner::cancel_data(&other, middle).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert_eq!(
            native_owner::admit_data(&other, tail).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert_eq!(
            native_owner::finish_data(&other, head).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert_eq!(
            native_owner::issue_write(&other, None, head, &[]).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        let snap_other = native_owner::snapshot(&other);
        assert!(snap_other.fifo_ids.is_empty());
        assert_eq!(snap_other.data_slot, TestingDataSlot::Free);
        let snap = native_owner::snapshot(&owner);
        assert_eq!(
            snap.fifo_ids,
            vec![head.as_u64(), middle.as_u64(), tail.as_u64()]
        );
        assert_eq!(snap.data_slot, TestingDataSlot::Sealing);
        assert_eq!(snap.fifo_head_id, Some(head.as_u64()));

        let owner_tail = Arc::clone(&owner);
        let (tail_started_tx, tail_started_rx) = mpsc::channel();
        let tail_wait = thread::spawn(move || {
            tail_started_tx.send(()).ok();
            native_owner::admit_data(&owner_tail, tail)
        });
        tail_started_rx.recv().expect("tail started");
        let owner_middle = Arc::clone(&owner);
        let (middle_started_tx, middle_started_rx) = mpsc::channel();
        let middle_wait = thread::spawn(move || {
            middle_started_tx.send(()).ok();
            native_owner::admit_data(&owner_middle, middle)
        });
        middle_started_rx.recv().expect("middle started");

        native_owner::cancel_data(&owner, middle).expect("cancel middle");
        native_owner::cancel_data(&owner, middle).expect("repeat cancel");
        assert_eq!(
            middle_wait.join().expect("middle join"),
            Err(ErrorCode::StateUnknown)
        );
        let snap = native_owner::snapshot(&owner);
        assert_eq!(snap.fifo_ids, vec![head.as_u64(), tail.as_u64()]);
        assert_eq!(snap.fifo_head_id, Some(head.as_u64()));
        assert_eq!(snap.data_slot, TestingDataSlot::Sealing);

        native_owner::finish_data(&owner, head).expect("seal then free");
        assert_eq!(tail_wait.join().expect("tail join"), Ok(()));
        let snap = native_owner::snapshot(&owner);
        assert_eq!(snap.data_slot, TestingDataSlot::Admitted);
        assert_eq!(snap.fifo_ids, vec![tail.as_u64()]);
        assert_eq!(snap.fifo_head_id, Some(tail.as_u64()));
        assert_eq!(snap.input_seq, 1);

        let stop_owner = RunBundle::new_test(3);
        let stop_head =
            native_owner::begin_data(&stop_owner, DataKind::Write, 0).expect("stop head");
        assert_eq!(
            native_owner::issue_write(&stop_owner, None, stop_head, &[]).expect("stop empty"),
            NativeOutcome::Delivered { written: 0 }
        );
        let stop_tail =
            native_owner::enqueue_data(&stop_owner, DataKind::Write, 1, None)
                .expect("stop tail");
        let before = native_owner::test_native_issues(&stop_owner);
        let stop_wait_owner = Arc::clone(&stop_owner);
        let (stop_started_tx, stop_started_rx) = mpsc::channel();
        let stop_wait = thread::spawn(move || {
            stop_started_tx.send(()).ok();
            native_owner::admit_data(&stop_wait_owner, stop_tail)
        });
        stop_started_rx.recv().expect("stop waiter started");
        native_owner::set_stop_interrupt(&stop_owner, None);
        assert_eq!(
            stop_wait.join().expect("stop join"),
            Err(ErrorCode::StateUnknown)
        );
        assert_eq!(native_owner::test_native_issues(&stop_owner), before);
        assert_eq!(
            native_owner::snapshot(&stop_owner).data_slot,
            TestingDataSlot::Sealing
        );
        native_owner::finish_data(&stop_owner, stop_head).expect("finish stop head");

        let gen_owner = RunBundle::new_test(4);
        let gen_head = native_owner::begin_data(&gen_owner, DataKind::Write, 0).expect("gen head");
        assert_eq!(
            native_owner::issue_write(&gen_owner, None, gen_head, &[]).expect("gen empty"),
            NativeOutcome::Delivered { written: 0 }
        );
        let gen_tail =
            native_owner::enqueue_data(&gen_owner, DataKind::Write, 1, None)
                .expect("gen tail");
        let before = native_owner::test_native_issues(&gen_owner);
        let gen_wait_owner = Arc::clone(&gen_owner);
        let (gen_started_tx, gen_started_rx) = mpsc::channel();
        let gen_wait = thread::spawn(move || {
            gen_started_tx.send(()).ok();
            native_owner::admit_data(&gen_wait_owner, gen_tail)
        });
        gen_started_rx.recv().expect("gen waiter started");
        native_owner::set_generation_open(&gen_owner, false);
        native_owner::cancel_all_fifo_and_pins(&gen_owner);
        assert_eq!(
            gen_wait.join().expect("gen join"),
            Err(ErrorCode::StateUnknown)
        );
        assert_eq!(native_owner::test_native_issues(&gen_owner), before);
        assert_eq!(
            native_owner::snapshot(&gen_owner).data_slot,
            TestingDataSlot::Sealing
        );
        native_owner::finish_data(&gen_owner, gen_head).expect("finish gen head");
    }

    #[test]
    fn input_seq_overflow_before_native_issue() {
        let owner = RunBundle::new_test(1);
        native_owner::testing_set_input_seq(&owner, 9_007_199_254_740_991);
        let before = native_owner::test_native_issues(&owner);
        let err = native_owner::begin_data(&owner, DataKind::Write, 3).unwrap_err();
        assert_eq!(err, ErrorCode::ResourceExhausted);
        assert_eq!(native_owner::test_native_issues(&owner), before);
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Free
        );
    }

    #[test]
    fn empty_input_no_issue() {
        let owner = RunBundle::new_test(1);
        let before = native_owner::test_native_issues(&owner);
        let ticket = native_owner::begin_data(&owner, DataKind::Write, 0).expect("empty");
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Admitted
        );
        let outcome = native_owner::issue_write(&owner, None, ticket, &[]).expect("no WriteFile");
        assert_eq!(outcome, NativeOutcome::Delivered { written: 0 });
        assert_eq!(native_owner::test_native_issues(&owner), before);
        native_owner::finish_data(&owner, ticket).expect("finish");
        assert_eq!(native_owner::snapshot(&owner).input_seq, 1);
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Free
        );
        assert_eq!(native_owner::test_native_issues(&owner), before);
    }

    #[test]
    fn one_issue_no_tail_retry() {
        let owner = RunBundle::new_test(1);
        let ticket = native_owner::begin_data(&owner, DataKind::Write, 3).expect("admit");
        let before = native_owner::test_native_issues(&owner);
        let first = native_owner::issue_write(&owner, None, ticket, &[1, 2, 3]);
        assert!(first.is_ok());
        let mid = native_owner::test_native_issues(&owner);
        assert_eq!(mid, before + 1);
        let again = native_owner::issue_write(&owner, None, ticket, &[1, 2, 3]);
        assert!(again.is_ok());
        assert_eq!(native_owner::test_native_issues(&owner), mid);
        native_owner::finish_data(&owner, ticket).ok();
    }

    #[test]
    fn admitted_before_stop_blocks_teardown() {
        let owner = RunBundle::new_test(1);
        native_owner::testing_admit_write(&owner, 1, 2).unwrap();
        assert!(!native_owner::testing_begin_teardown_ctrl(&owner));
        native_owner::testing_set_data_slot_free(&owner);
        assert!(native_owner::testing_begin_teardown_ctrl(&owner));
        assert!(!native_owner::testing_begin_teardown_ctrl(&owner));
    }

    #[test]
    fn pending_exact_pin_cancel_retained_unknown() {
        let owner = RunBundle::new_test(1);
        let (op, issued, _) = issue_pending_overlapped_write().expect("pending pin");
        native_owner::install_pinned_write(&owner, None, op).expect("install");
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Pinned
        );
        native_owner::testing_query_pending_to_retained_unknown(&owner, None);
        let snap = native_owner::snapshot(&owner);
        assert_eq!(snap.data_slot, TestingDataSlot::RetainedUnknown);
        assert!(snap.write_pending);
        assert_eq!(
            native_owner::testing_admit_write(&owner, 10, 1).unwrap_err(),
            ErrorCode::StateUnknown
        );
        native_owner::physical_close_input(&owner, None);
        assert!(native_owner::input_handle_is_some(&owner));
        assert!(native_owner::snapshot(&owner).write_pending);
        assert!(native_owner::snapshot(&owner).input_sealed);
        let _ = issued;
    }

    #[test]
    fn retained_unknown_stop_reaps_native_then_closes_input() {
        let owner = RunBundle::new_test(1);
        let run = RunId::new("50000000-0000-4000-8000-00000000ae10").expect("run");
        let shared = SessionShared::new(run);
        let (op, _issued, _) = issue_pending_overlapped_write().expect("pending pin");
        native_owner::install_pinned_write(&owner, Some(&shared), op).expect("install");
        native_owner::testing_query_pending_to_retained_unknown(&owner, Some(&shared));
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::RetainedUnknown
        );
        assert!(native_owner::snapshot(&owner).write_pending);

        native_owner::finish_pin_after_unblocker(&owner, &shared);

        let settled = native_owner::snapshot(&owner);
        assert!(!settled.write_pending);
        assert_eq!(settled.data_slot, TestingDataSlot::Free);
        native_owner::physical_close_input(&owner, Some(&shared));
        assert!(!native_owner::input_handle_is_some(&owner));
        assert!(native_owner::snapshot(&owner).input_sealed);
    }

    #[test]
    fn sealing_exclusion_until_terminal_seal() {
        let owner = RunBundle::new_test(1);
        let ticket = native_owner::begin_data(&owner, DataKind::Write, 0).unwrap();
        assert_eq!(
            native_owner::issue_write(&owner, None, ticket, &[]).unwrap(),
            NativeOutcome::Delivered { written: 0 }
        );
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Sealing
        );
        assert_eq!(
            native_owner::testing_admit_write(&owner, 99, 1).unwrap_err(),
            ErrorCode::AlreadyRunning
        );
        native_owner::finish_data(&owner, ticket).unwrap();
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Free
        );
        assert_eq!(native_owner::snapshot(&owner).input_seq, 1);
    }

    #[test]
    fn teardown_reservation_once() {
        let owner = RunBundle::new_test(1);
        assert!(native_owner::testing_begin_teardown_ctrl(&owner));
        assert!(!native_owner::testing_begin_teardown_ctrl(&owner));
        assert!(native_owner::snapshot(&owner).teardown_ctrl_reserved);
    }

    #[test]
    fn resize_vs_close_lease_drain() {
        let owner = RunBundle::new_test(1);
        let (acquired_tx, acquired_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let hold = Arc::clone(&owner);
        let holder = thread::spawn(move || {
            native_owner::hold_kind(&hold, true, acquired_tx, release_rx);
        });
        acquired_rx.recv().expect("holder acquired");
        let close = Arc::clone(&owner);
        let closer = thread::spawn(move || {
            native_owner::physical_close_hpcon(&close, None);
        });
        thread::sleep(Duration::from_millis(20));
        assert_eq!(native_owner::snapshot(&owner).hpcon_lease_count, 1);
        assert!(native_owner::hpcon_handle_is_some(&owner));
        release_tx.send(()).expect("release");
        join(holder);
        join(closer);
        let snap = native_owner::snapshot(&owner);
        assert_eq!(snap.hpcon_lease_count, 0);
        assert!(!native_owner::hpcon_handle_is_some(&owner));
        assert_eq!(native_owner::native_lock_violation_count(), 0);
    }

    #[test]
    fn same_run_unwind_reap_before_free() {
        let owner = RunBundle::new_test(1);
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            native_owner::panic_after_acquire_input(&owner);
        }));
        assert!(panicked.is_err());
        let snap = native_owner::snapshot(&owner);
        assert_eq!(snap.input_lease_count, 0);
        assert!(!snap.input_sealed);
        assert_eq!(native_owner::run_held(), 0);
        let ticket = native_owner::begin_data(&owner, DataKind::Write, 0).unwrap();
        native_owner::issue_write(&owner, None, ticket, &[]).unwrap();
        native_owner::finish_data(&owner, ticket).unwrap();
        assert_eq!(native_owner::snapshot(&owner).input_seq, 1);
    }

    #[test]
    fn two_run_independence() {
        let a = RunBundle::new_test(1);
        let b = RunBundle::new_test(2);
        let (acquired_tx, acquired_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let hold = Arc::clone(&a);
        let holder = thread::spawn(move || {
            native_owner::hold_kind(&hold, true, acquired_tx, release_rx);
        });
        acquired_rx.recv().expect("A held");
        native_owner::physical_close_hpcon(&b, None);
        native_owner::physical_close_input(&b, None);
        assert!(!native_owner::hpcon_handle_is_some(&b));
        assert!(!native_owner::input_handle_is_some(&b));
        let snap_a = native_owner::snapshot(&a);
        assert!(native_owner::hpcon_handle_is_some(&a));
        assert_eq!(snap_a.hpcon_lease_count, 1);
        assert!(!snap_a.hpcon_sealed);
        release_tx.send(()).expect("release A");
        join(holder);
        native_owner::physical_close_hpcon(&a, None);
        assert!(!native_owner::hpcon_handle_is_some(&a));
        assert_eq!(native_owner::snapshot(&a).hpcon_lease_count, 0);
    }

    #[test]
    fn exit_callback_after_locks() {
        let project = ProjectId::new("30000000-0000-4000-8000-00000000ae11").expect("p");
        let pane = PaneId::new("40000000-0000-4000-8000-00000000ae11").expect("pane");
        let run = RunId::new("50000000-0000-4000-8000-00000000ae11").expect("run");
        let session = RunSession::new(project, pane, run);
        let flag = Arc::new(AtomicBool::new(false));
        let seen_lock = Arc::new(AtomicBool::new(false));
        let f = Arc::clone(&flag);
        let held = Arc::clone(&seen_lock);
        session.shared.set_exit_callback(Arc::new(move |_id| {
            if native_owner::run_held() > 0 {
                held.store(true, Ordering::SeqCst);
            }
            f.store(true, Ordering::SeqCst);
        }));
        assert_eq!(native_owner::run_held(), 0);
        session.shared.invoke_exit_callback();
        assert!(flag.load(Ordering::SeqCst));
        assert!(!seen_lock.load(Ordering::SeqCst));
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_release_before_wait() {
        let owner = RunBundle::new_test(11);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        guard.release(t);
        assert!(guard.ticket_released(t).expect("released"));
        native_owner::admit_data(&owner, t).expect("release-before-wait");
        assert_eq!(
            native_owner::issue_write(&owner, None, t, &[]).expect("empty issue"),
            NativeOutcome::Delivered { written: 0 }
        );
        assert_eq!(
            native_owner::snapshot(&owner).data_slot,
            TestingDataSlot::Sealing
        );
        native_owner::finish_data(&owner, t).expect("finish");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_registered_release() {
        let owner = RunBundle::new_test(12);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        let wait_owner = Arc::clone(&owner);
        let waiter = thread::spawn(move || native_owner::admit_data(&wait_owner, t));
        guard
            .wait_until_waiting(t, Duration::from_secs(15))
            .expect("registered wait");
        guard.release(t);
        assert_eq!(waiter.join().expect("join"), Ok(()));
        native_owner::issue_write(&owner, None, t, &[]).expect("empty issue");
        native_owner::finish_data(&owner, t).expect("finish");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_drop_wakes_active_waiters() {
        let owner = RunBundle::new_test(13);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        let wait_owner = Arc::clone(&owner);
        let waiter = thread::spawn(move || native_owner::admit_data(&wait_owner, t));
        guard
            .wait_until_waiting(t, Duration::from_secs(15))
            .expect("waiting");
        drop(guard);
        assert_eq!(waiter.join().expect("drop-wake"), Ok(()));
        native_owner::issue_write(&owner, None, t, &[]).expect("empty issue");
        native_owner::finish_data(&owner, t).expect("finish");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_late_arrival_after_drop() {
        let owner = RunBundle::new_test(14);
        drop(native_owner::attach_observe(&owner).expect("attach"));
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        native_owner::admit_data(&owner, t).expect("late unarmed");
        native_owner::issue_write(&owner, None, t, &[]).expect("empty issue");
        native_owner::finish_data(&owner, t).expect("finish");
        drop(native_owner::attach_observe(&owner).expect("reattach"));
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_single_attach_conflict() {
        let owner = RunBundle::new_test(15);
        let first = native_owner::attach_observe(&owner).expect("first");
        assert_eq!(
            native_owner::attach_observe(&owner).err(),
            Some(ErrorCode::OperationConflict)
        );
        drop(first);
        drop(native_owner::attach_observe(&owner).expect("second"));
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_cancel_while_held() {
        let owner = RunBundle::new_test(16);
        let head = native_owner::begin_data(&owner, DataKind::Write, 0).expect("head");
        native_owner::issue_write(&owner, None, head, &[]).expect("empty head");
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let mid = native_owner::enqueue_data(&owner, DataKind::Write, 1, None).expect("mid");
        let wait_owner = Arc::clone(&owner);
        let waiter = thread::spawn(move || native_owner::admit_data(&wait_owner, mid));
        guard
            .wait_until_waiting(mid, Duration::from_secs(15))
            .expect("held");
        native_owner::cancel_data(&owner, mid).expect("cancel_data");
        guard.release(mid);
        assert_eq!(waiter.join().expect("join"), Err(ErrorCode::StateUnknown));
        assert!(guard
            .events()
            .expect("events")
            .iter()
            .all(|event| event.ticket != mid
                || event.kind != native_owner::IoObserveKind::Issued));
        native_owner::finish_data(&owner, head).expect("finish head");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_poisoned_shutdown_wake_error() {
        let owner = RunBundle::new_test(17);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        let wait_owner = Arc::clone(&owner);
        let waiter = thread::spawn(move || native_owner::admit_data(&wait_owner, t));
        guard
            .wait_until_waiting(t, Duration::from_secs(15))
            .expect("parked");
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            let _ = guard.wait_for(
                |_| panic!("poison observe predicate"),
                Duration::from_secs(1),
            );
        }));
        assert!(panicked.is_err());
        assert_eq!(waiter.join().expect("wake"), Ok(()));
        assert_eq!(guard.events().unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(guard.ticket_released(t).unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(
            guard
                .wait_until_waiting(t, Duration::from_secs(1))
                .unwrap_err(),
            ErrorCode::RuntimeFailed
        );
        assert_eq!(
            guard
                .wait_for(|_| true, Duration::from_secs(1))
                .unwrap_err(),
            ErrorCode::RuntimeFailed
        );
        let _ = native_owner::finish_data(&owner, t);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_wait_for_armed_predicate_success() {
        let owner = RunBundle::new_test(18);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        let events = guard
            .wait_for(
                |ev| {
                    ev.iter().any(|event| {
                        event.kind == native_owner::IoObserveKind::Enqueued && event.ticket == t
                    })
                },
                Duration::from_secs(15),
            )
            .expect("armed evidence");
        assert!(events.iter().any(|event| event.ticket == t));
        assert_eq!(guard.events().expect("events").len(), events.len());
        assert!(!guard.ticket_released(t).expect("query released"));
        guard.release(t);
        assert!(guard.ticket_released(t).expect("released"));
        native_owner::admit_data(&owner, t).expect("admit");
        native_owner::issue_write(&owner, None, t, &[]).expect("empty issue");
        native_owner::finish_data(&owner, t).expect("finish");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_inflight_wait_for_rejects_terminal_predicate() {
        let owner = RunBundle::new_test(19);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        let phase = std::sync::atomic::AtomicUsize::new(0);
        let (ready_tx, ready_rx) = mpsc::channel();
        thread::scope(|s| {
            let waiter = s.spawn(|| {
                guard.wait_for(
                    |ev| {
                        if phase.load(Ordering::SeqCst) == 0 {
                            let _ = ready_tx.send(());
                            false
                        } else {
                            !ev.is_empty()
                        }
                    },
                    Duration::from_secs(15),
                )
            });
            ready_rx.recv().expect("pred entered");
            let panicked = catch_unwind(AssertUnwindSafe(|| {
                let _ = guard.wait_for(
                    |_| {
                        phase.store(1, Ordering::SeqCst);
                        panic!("terminal invalidation");
                    },
                    Duration::from_secs(1),
                );
            }));
            assert!(panicked.is_err());
            assert_eq!(
                waiter.join().expect("join wait_for"),
                Err(ErrorCode::RuntimeFailed)
            );
        });
        assert_eq!(guard.events().unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(guard.ticket_released(t).unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(
            guard
                .wait_until_waiting(t, Duration::from_secs(1))
                .unwrap_err(),
            ErrorCode::RuntimeFailed
        );
        native_owner::admit_data(&owner, t).expect("product admit after observer terminal");
        native_owner::issue_write(&owner, None, t, &[]).expect("empty issue");
        native_owner::finish_data(&owner, t).expect("finish");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn observe_mutex_poison_shutdown_wake_error() {
        let owner = RunBundle::new_test(20);
        let guard = native_owner::attach_observe(&owner).expect("attach");
        let t = native_owner::enqueue_data(&owner, DataKind::Write, 0, None).expect("enq");
        struct ObserveReleaseOnDrop<'a> {
            guard: &'a super::RunIoObserveGuard,
            ticket: super::DataTicket,
        }
        impl Drop for ObserveReleaseOnDrop<'_> {
            fn drop(&mut self) {
                self.guard.release(self.ticket);
            }
        }
        let _release = ObserveReleaseOnDrop {
            guard: &guard,
            ticket: t,
        };
        let wait_owner = Arc::clone(&owner);
        let waiter = thread::spawn(move || native_owner::admit_data(&wait_owner, t));
        guard
            .wait_until_waiting(t, Duration::from_secs(15))
            .expect("parked");
        let panicked = catch_unwind(AssertUnwindSafe(|| {
            native_owner::panic_holding_observe_monitor(&guard);
        }));
        assert!(panicked.is_err());
        assert_eq!(guard.events().unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(waiter.join().expect("poison-wake"), Ok(()));
        assert_eq!(guard.ticket_released(t).unwrap_err(), ErrorCode::RuntimeFailed);
        assert_eq!(
            guard
                .wait_for(|_| true, Duration::from_secs(1))
                .unwrap_err(),
            ErrorCode::RuntimeFailed
        );
        let _ = native_owner::finish_data(&owner, t);
    }
}
