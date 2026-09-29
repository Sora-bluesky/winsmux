//! RuntimeService: Win32 owner for pane runs. Ownership starts at reservation.
//!
//! Data writes, keys, resize, interrupt/stop, cancellation, failed spawn,
//! `testing_install_write`, generation close, and physical teardown for one
//! run share the private owner in `session`. Caller must seal the operation
//! terminal before `finish_data`; this module never assigns Free first.

pub mod session;
pub mod spawn;
pub mod topology;

use crate::contract::{ErrorCode, PaneId, Process, ProjectId, Provider, RunId, Work, MAX_MESSAGE_BYTES};
use crate::provider::lifecycle::{ProbeRegistry, ReadyProvider};
use crate::store::root_identity::ObservedRoot;
use session::{
    clamp_text_to_envelope, json_string_len, now_timestamp, DataKind, DataTicket, NativeOutcome,
    ReadSlice, RunSession, SessionPhase, TestingRunIoStats,
};
use spawn::{resume_once, spawn_usual_shell_child, PreparedChild};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use windows_sys::Win32::Foundation::HANDLE;

pub use session::{
    DataKind as RunDataKind, DataTicket as RunDataTicket, NativeOutcome as RunNativeOutcome,
    TestingDataSlot, TestingRunIoStats as RunIoStats,
};
#[cfg(debug_assertions)]
pub use session::{IoObserveEvent, IoObserveKind, RunIoObserveGuard};

/// Test evidence survives removal of the owning session. These duplicates
/// observe the process and workers; keeping a job or PTY duplicate would change
/// the cleanup behavior under test, so neither is retained.
#[cfg(debug_assertions)]
pub struct RetainedCleanupObservation {
    run_id: RunId,
    process_id: u32,
    creation_time: u64,
    process: spawn::RawHandle,
    reader: spawn::RawHandle,
    waiter: spawn::RawHandle,
    teardown: spawn::RawHandle,
    shared: Arc<session::SessionShared>,
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetainedCleanupSnapshot {
    pub run_id: RunId,
    pub process_id: u32,
    pub creation_time: u64,
    pub prepared_job_members: u32,
    pub process_signaled: bool,
    pub reader_signaled: bool,
    pub waiter_signaled: bool,
    pub teardown_signaled: bool,
    pub handle_signaled: bool,
    pub drain_complete: bool,
    pub reader_returned: bool,
    pub waiter_returned: bool,
    pub teardown_returned: bool,
    pub pty_closed: bool,
    pub write_pending: bool,
    pub job_contained: bool,
    pub job_active_processes: Option<u32>,
    pub io: session::TestingCleanupIoSnapshot,
}

#[cfg(debug_assertions)]
fn validate_observation_handle(handle: HANDLE) -> Result<(), ErrorCode> {
    if handle.is_null() || handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
        // -1 is also the Win32 current-process pseudo HANDLE. It is never an
        // owned duplicate and must not silently identify the testing process.
        return Err(ErrorCode::RuntimeFailed);
    }
    Ok(())
}

#[cfg(debug_assertions)]
fn inspect_process_identity(handle: HANDLE) -> Result<(u32, u64), ErrorCode> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetProcessId, GetProcessTimes};
    validate_observation_handle(handle)?;
    let zero = || FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let (mut creation, mut exit, mut kernel, mut user) = (zero(), zero(), zero(), zero());
    // The caller retains the exact process HANDLE throughout both queries.
    let process_id = unsafe { GetProcessId(handle) };
    if process_id == 0
        || unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } == 0
    {
        return Err(ErrorCode::RuntimeFailed);
    }
    Ok((
        process_id,
        ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64,
    ))
}

#[cfg(debug_assertions)]
fn inspect_signaled(handle: HANDLE) -> Result<bool, ErrorCode> {
    use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
    validate_observation_handle(handle)?;
    match unsafe { windows_sys::Win32::System::Threading::WaitForSingleObject(handle, 0) } {
        WAIT_OBJECT_0 => Ok(true),
        WAIT_TIMEOUT => Ok(false),
        _ => Err(ErrorCode::RuntimeFailed),
    }
}

#[cfg(debug_assertions)]
impl RetainedCleanupObservation {
    pub fn snapshot(&self) -> Result<RetainedCleanupSnapshot, ErrorCode> {
        if inspect_process_identity(self.process.0)? != (self.process_id, self.creation_time)
            || self.shared.run_id != self.run_id
        {
            return Err(ErrorCode::RuntimeFailed);
        }
        let io = self.shared.testing_inspect_cleanup()?;
        let (job_contained, job_active_processes) = self.shared.testing_inspect_job_ownership()?;
        Ok(RetainedCleanupSnapshot {
            run_id: self.run_id.clone(),
            process_id: self.process_id,
            creation_time: self.creation_time,
            prepared_job_members: 1,
            process_signaled: inspect_signaled(self.process.0)?,
            reader_signaled: inspect_signaled(self.reader.0)?,
            waiter_signaled: inspect_signaled(self.waiter.0)?,
            teardown_signaled: inspect_signaled(self.teardown.0)?,
            handle_signaled: self.shared.handle_signaled.load(Ordering::SeqCst),
            drain_complete: self.shared.drain_flag.load(Ordering::SeqCst),
            reader_returned: self.shared.reader_returned.load(Ordering::SeqCst),
            waiter_returned: self.shared.waiter_returned.load(Ordering::SeqCst),
            teardown_returned: self.shared.teardown_returned.load(Ordering::SeqCst),
            pty_closed: self.shared.pty_closed.load(Ordering::SeqCst),
            write_pending: self.shared.write_pending.load(Ordering::SeqCst),
            job_contained,
            job_active_processes,
            io,
        })
    }
}

pub struct RuntimeService {
    inner: Mutex<Inner>,
    generation_visible: AtomicBool,
    provider_probes: OnceLock<ProbeRegistry>,
}

struct Inner {
    sessions: HashMap<String, RunSession>,
    exit_callback: Option<Arc<dyn Fn(RunId) + Send + Sync>>,
}

impl RuntimeService {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                sessions: HashMap::new(),
                exit_callback: None,
            }),
            generation_visible: AtomicBool::new(true),
            provider_probes: OnceLock::new(),
        }
    }

    pub fn start_provider_probes(&self) {
        self.provider_probes.get_or_init(ProbeRegistry::start);
    }

    pub fn ready_provider(&self, provider: Provider) -> Option<ReadyProvider> {
        self.provider_probes.get()?.ready(provider)
    }

    pub fn cancel_provider_probes(&self) -> bool {
        self.provider_probes.get().is_none_or(ProbeRegistry::cancel_all)
    }

    pub fn drain_provider_probes(&self) -> bool {
        self.provider_probes
            .get()
            .is_none_or(ProbeRegistry::cancel_and_join)
    }

    fn shared_of(&self, run_id: &RunId) -> Result<Arc<session::SessionShared>, ErrorCode> {
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        Ok(Arc::clone(&session.shared))
    }

    pub fn insert_preparing(
        &self,
        project_id: ProjectId,
        pane_id: PaneId,
        run_id: RunId,
    ) -> Result<(), ErrorCode> {
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let key = run_id.as_str().to_owned();
        if inner.sessions.contains_key(&key) {
            return Err(ErrorCode::OperationConflict);
        }
        let mut session = RunSession::new(project_id, pane_id, run_id);
        if let Some(callback) = inner.exit_callback.clone() {
            session.shared.set_exit_callback(callback);
        }
        if !self.generation_visible.load(Ordering::SeqCst) {
            session.shared.set_generation_open(false);
        }
        inner.sessions.insert(key, session);
        Ok(())
    }

    pub fn attach_root(&self, run_id: &RunId, observed: ObservedRoot) -> Result<(), ErrorCode> {
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get_mut(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        session.observed_root = Some(observed);
        Ok(())
    }

    pub fn spawn_usual_shell_child(cwd: &str) -> Result<PreparedChild, ErrorCode> {
        spawn_usual_shell_child(cwd).map_err(|_| ErrorCode::RuntimeFailed)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn spawn_testing_shell_child(
        cwd: &str,
        executable: &str,
    ) -> Result<PreparedChild, ErrorCode> {
        spawn::spawn_suspended_shell(cwd, executable).map_err(|_| ErrorCode::RuntimeFailed)
    }

    pub fn attach_child(&self, run_id: &RunId, child: PreparedChild) -> Result<(), ErrorCode> {
        let mut inner = match self.inner.lock() {
            Ok(inner) => inner,
            Err(_) => {
                child.rollback();
                return Err(ErrorCode::RuntimeFailed);
            }
        };
        let missing = !inner.sessions.contains_key(run_id.as_str());
        let conflict = inner
            .sessions
            .get(run_id.as_str())
            .is_some_and(|session| session.phase != SessionPhase::Preparing);
        if missing || conflict {
            drop(inner);
            child.rollback();
            return Err(if missing {
                ErrorCode::TargetNotFound
            } else {
                ErrorCode::OperationConflict
            });
        }
        let session = inner
            .sessions
            .get_mut(run_id.as_str())
            .expect("preparing session remains after conflict checks");
        session.attach_child(child);
        session.start_idle_workers();
        Ok(())
    }

    pub fn has_session(&self, run_id: &RunId) -> bool {
        self.inner
            .lock()
            .ok()
            .is_some_and(|inner| inner.sessions.contains_key(run_id.as_str()))
    }

    #[cfg(debug_assertions)]
    pub fn testing_retain_cleanup(
        &self,
        run_id: &RunId,
    ) -> Result<RetainedCleanupObservation, ErrorCode> {
        self.retain_cleanup_with(run_id, spawn::duplicate_handle)
    }

    #[cfg(debug_assertions)]
    fn retain_cleanup_with(
        &self,
        run_id: &RunId,
        mut duplicate: impl FnMut(HANDLE) -> Option<HANDLE>,
    ) -> Result<RetainedCleanupObservation, ErrorCode> {
        use std::os::windows::io::AsRawHandle;
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        if session.phase != SessionPhase::Preparing || session.published || session.current {
            return Err(ErrorCode::OperationConflict);
        }
        let child = session.child.as_ref().ok_or(ErrorCode::RuntimeFailed)?;
        session
            .shared
            .testing_inspect_single_member(child.process.0)?;
        let (process_id, creation_time) = inspect_process_identity(child.process.0)?;
        let process = spawn::RawHandle(duplicate(child.process.0).ok_or(ErrorCode::RuntimeFailed)?);
        let mut copy_worker = |worker: &Option<std::thread::JoinHandle<()>>| {
            let handle = worker
                .as_ref()
                .ok_or(ErrorCode::RuntimeFailed)?
                .as_raw_handle();
            duplicate(handle)
                .map(spawn::RawHandle)
                .ok_or(ErrorCode::RuntimeFailed)
        };
        let reader = copy_worker(&session.reader)?;
        let waiter = copy_worker(&session.waiter)?;
        let teardown = copy_worker(&session.teardown)?;
        Ok(RetainedCleanupObservation {
            run_id: run_id.clone(),
            process_id,
            creation_time,
            process,
            reader,
            waiter,
            teardown,
            shared: Arc::clone(&session.shared),
        })
    }

    pub fn session_clean(&self, run_id: &RunId) -> bool {
        self.inner.lock().ok().is_some_and(|inner| {
            inner
                .sessions
                .get(run_id.as_str())
                .is_some_and(RunSession::session_clean)
        })
    }

    pub fn any_unclean(&self, project: &ProjectId) -> bool {
        self.inner.lock().ok().is_some_and(|inner| {
            inner.sessions.values().any(|session| {
                session.project_id.as_str() == project.as_str() && !session.session_clean()
            })
        })
    }

    pub fn preparing_exists(&self, project: &ProjectId) -> bool {
        self.inner.lock().ok().is_some_and(|inner| {
            inner.sessions.values().any(|session| {
                session.project_id.as_str() == project.as_str()
                    && session.phase == SessionPhase::Preparing
            })
        })
    }

    pub fn resume_and_observe(&self, run_id: &RunId) -> Result<Activation, ErrorCode> {
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get_mut(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        let thread = session
            .child
            .as_ref()
            .map(|child| child.thread.0)
            .ok_or(ErrorCode::RuntimeFailed)?;
        let previous = resume_once(thread);
        if previous == u32::MAX {
            session.phase = SessionPhase::Failed;
            return Ok(Activation::ResumeFailed);
        }
        if previous == 0 {
            session.phase = SessionPhase::Failed;
            session
                .shared
                .force_killed
                .store(true, std::sync::atomic::Ordering::SeqCst);
            return Ok(Activation::AlreadyRunnable);
        }
        if previous > 1 {
            session.phase = SessionPhase::Failed;
            return Ok(Activation::ExtraSuspension);
        }
        if let Some(child) = session.child.as_mut() {
            child.disarm();
        }
        #[cfg(debug_assertions)]
        if std::mem::take(&mut session.testing_wait_for_exit_before_observe)
            && !session.testing_wait_for_process_exit()
        {
            session.phase = SessionPhase::Failed;
            return Err(ErrorCode::RuntimeFailed);
        }
        let (process, work, code) = session.observe_handle();
        session.published = true;
        session.current = true;
        session.phase = SessionPhase::Published;
        session.process_state = process;
        session.work = work;
        session.started_at = now_timestamp();
        if matches!(process, Process::Exited) {
            session.queue_cleanup();
        }
        Ok(Activation::Published {
            process,
            work,
            exit_code: code,
        })
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_require_exit_before_observe(
        &self,
        run_id: &RunId,
    ) -> Result<(), ErrorCode> {
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get_mut(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        session.testing_wait_for_exit_before_observe = true;
        Ok(())
    }

    pub fn finalize_failure(&self, run_id: &RunId, kill: bool) {
        let mut jobs = Vec::new();
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(mut session) = inner.sessions.remove(run_id.as_str()) {
                session.phase = SessionPhase::Failed;
                session.published = false;
                session.current = false;
                if kill {
                    session
                        .shared
                        .force_killed
                        .store(true, std::sync::atomic::Ordering::SeqCst);
                }
                session.shared.cancel_all_fifo_and_pins();
                if let Some(mut child) = session.child.take() {
                    child.disarm();
                    if let Some(op) = child.take_write() {
                        spawn::retain_write(op);
                    }
                    child.thread.close();
                    child.process.close();
                }
                let job = session.shared.take_job_for_containment();
                if !job.is_null() && job != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                    jobs.push(job);
                }
                session.shared.request_cleanup();
            }
        }
        for job in jobs {
            if !job.is_null() {
                unsafe {
                    windows_sys::Win32::Foundation::CloseHandle(job);
                }
            }
        }
    }

    pub fn mark_published_current(&self, run_id: &RunId, current: bool) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(session) = inner.sessions.get_mut(run_id.as_str()) {
                session.current = current;
            }
        }
    }

    pub fn admit_interrupt(&self, run_id: &RunId) -> Result<bool, ErrorCode> {
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        if !session.published {
            return Err(ErrorCode::TargetNotFound);
        }
        let (process, _, _) = session.observe_handle();
        if session
            .shared
            .handle_signaled
            .load(std::sync::atomic::Ordering::SeqCst)
            || matches!(process, Process::Exited)
        {
            return Ok(false);
        }
        session.shared.set_stop_interrupt();
        Ok(true)
    }

    pub fn deliver_ctrl_c(&self, run_id: &RunId) -> Result<bool, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        Ok(session::write_ctrl_c_on(&shared))
    }

    pub fn queue_cleanup(&self, run_id: &RunId) {
        if let Ok(inner) = self.inner.lock() {
            if let Some(session) = inner.sessions.get(run_id.as_str()) {
                session.shared.request_cleanup();
            }
        }
    }

    pub fn resize(&self, run_id: &RunId, cols: i16, rows: i16) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.resize_complete(cols, rows)
    }

    /// Enqueue write/key/resize and return a run-bound ticket before waiting.
    /// Admission still requires this ticket to be FIFO head and the data slot
    /// to be Free.
    pub fn enqueue_data(
        &self,
        run_id: &RunId,
        kind: DataKind,
        payload_len: usize,
    ) -> Result<DataTicket, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.enqueue_data(kind, payload_len, None)
    }

    pub(crate) fn enqueue_operation_data(
        &self,
        run_id: &RunId,
        kind: DataKind,
        payload_len: usize,
        operation_key: [u8; 36],
    ) -> Result<DataTicket, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.enqueue_data(kind, payload_len, Some(operation_key))
    }

    /// Wait until `ticket` is this run's FIFO head and the data slot is Free,
    /// then admit it. Empty write/key (`payload_len == 0`) moves Admitted ->
    /// Sealing Delivered{0} without WriteFile. Caller must seal the operation
    /// terminal, then call `finish_data`; Free is never assigned before that seal.
    pub fn admit_data(&self, run_id: &RunId, ticket: DataTicket) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.admit_data(ticket)
    }

    /// Admit write/key/resize as FIFO head. Equivalent to `enqueue_data` then
    /// `admit_data`. Empty write/key (`payload_len == 0`) moves Admitted ->
    /// Sealing Delivered{0} without WriteFile. Caller must seal the operation
    /// terminal, then call `finish_data`; Free is never assigned before that seal.
    pub fn begin_data(
        &self,
        run_id: &RunId,
        kind: DataKind,
        payload_len: usize,
    ) -> Result<DataTicket, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.begin_data(kind, payload_len)
    }

    /// Issue WriteFile for an admitted write/key with runtime/run locks dropped.
    /// Classifies into Sealing or RetainedUnknown and does not assign Free.
    /// Key Enter/Tab/Escape/Interrupt bytes are issued as supplied.
    pub fn issue_write(
        &self,
        run_id: &RunId,
        ticket: DataTicket,
        payload: &[u8],
    ) -> Result<NativeOutcome, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.issue_write(ticket, payload)
    }

    /// Issue ResizePseudoConsole for an admitted resize with locks dropped.
    /// Does not publish seq. Caller seals the terminal, then `finish_data`.
    pub fn issue_resize(
        &self,
        run_id: &RunId,
        ticket: DataTicket,
        cols: i16,
        rows: i16,
    ) -> Result<NativeOutcome, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.issue_resize(ticket, cols, rows)
    }

    /// After the caller has sealed the operation terminal, commit `input_seq`
    /// for full Delivered (empty `payload_len == 0` counts), free the FIFO
    /// head, and notify waiters.
    pub fn finish_data(&self, run_id: &RunId, ticket: DataTicket) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.finish_data(ticket)
    }

    pub(crate) fn reserved_input_seq(
        &self,
        run_id: &RunId,
        ticket: DataTicket,
    ) -> Result<Option<u64>, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.reserved_input_seq(ticket)
    }

    pub(crate) fn commit_data_with<T, E>(
        &self,
        run_id: &RunId,
        ticket: DataTicket,
        commit: impl FnOnce(Option<u64>) -> Result<T, E>,
    ) -> Result<Result<T, E>, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.commit_data_with(ticket, commit)
    }

    pub fn cancel_data(&self, run_id: &RunId, ticket: DataTicket) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.cancel_data(ticket)
    }

    pub fn reject_unissued(&self, run_id: &RunId, ticket: DataTicket) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.reject_unissued(ticket)
    }

    /// Auth revoke/close calls this after dropping Authorization.inner.
    /// Cancels FIFO waiters and exact pins; does not CloseHandle/ClosePseudoConsole.
    pub fn cancel_and_wake_after_auth_unlock(&self) {
        self.generation_visible.store(false, Ordering::SeqCst);
        let sessions: Vec<Arc<session::SessionShared>> = match self.inner.lock() {
            Ok(inner) => inner
                .sessions
                .values()
                .map(|session| Arc::clone(&session.shared))
                .collect(),
            Err(_) => return,
        };
        for shared in sessions {
            shared.set_generation_open(false);
            shared.cancel_all_fifo_and_pins();
        }
    }

    pub fn set_generation_visible(&self, visible: bool) {
        self.generation_visible.store(visible, Ordering::SeqCst);
        if let Ok(inner) = self.inner.lock() {
            for session in inner.sessions.values() {
                session.shared.set_generation_open(visible);
            }
        }
    }

    pub fn generation_is_visible(&self) -> bool {
        self.generation_visible.load(Ordering::SeqCst)
    }

    /// Authorization installs a Weak-capturing closure at construction.
    /// Waiter invokes it only after runtime/run locks are dropped.
    pub fn set_exit_callback(&self, callback: Arc<dyn Fn(RunId) + Send + Sync>) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        inner.exit_callback = Some(Arc::clone(&callback));
        for session in inner.sessions.values() {
            session.shared.set_exit_callback(Arc::clone(&callback));
        }
    }

    pub fn occupancy_blocks_close(&self, run_id: &RunId) -> bool {
        let Ok(inner) = self.inner.lock() else {
            return true;
        };
        let Some(session) = inner.sessions.get(run_id.as_str()) else {
            return false;
        };
        session.shared.occupancy_blocks_close() || !session.session_clean()
    }

    pub fn testing_input_stats(&self, run_id: &RunId) -> Option<TestingRunIoStats> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        Some(session.shared.io_snapshot())
    }

    #[cfg(debug_assertions)]
    pub fn testing_output_tail_shape(&self, run_id: &RunId) -> Option<String> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        let shape = session.shared.output.lock().ok()?.testing_tail_shape();
        Some(shape)
    }

    #[cfg(debug_assertions)]
    pub fn testing_attach_io_observe(
        &self,
        run_id: &RunId,
    ) -> Result<session::RunIoObserveGuard, ErrorCode> {
        let shared = self.shared_of(run_id)?;
        session::attach_io_observe(&shared)
    }

    pub fn read_output(
        &self,
        run_id: &RunId,
        cursor: Option<u64>,
        max_bytes: u64,
        request_run: &str,
    ) -> Result<ReadSlice, ErrorCode> {
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        let ring = session
            .shared
            .output
            .lock()
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        Ok(ring.snapshot(cursor, max_bytes, run_id.as_str(), request_run))
    }

    pub fn observation(
        &self,
        run_id: &RunId,
    ) -> Result<(Process, Work, Option<u32>, bool), ErrorCode> {
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        let session = inner
            .sessions
            .get_mut(run_id.as_str())
            .ok_or(ErrorCode::TargetNotFound)?;
        let (process, work, code) = session.observe_handle();
        session.process_state = process;
        session.work = work;
        if matches!(process, Process::Exited) {
            session.queue_cleanup();
        }
        Ok((process, work, code, session.current))
    }

    pub fn mark_current(&self, run_id: &RunId, current: bool) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(session) = inner.sessions.get_mut(run_id.as_str()) {
                session.current = current;
            }
        }
    }

    pub fn isolation_flags(&self, run_id: &RunId) -> Option<(bool, bool, bool)> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        Some((
            session.b_inherit_handles,
            session.inherit_owner,
            session.inherit_public,
        ))
    }

    pub fn testing_session_io(&self, run_id: &RunId) -> Option<(bool, bool, bool, usize)> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        let decoded = session
            .shared
            .output
            .lock()
            .ok()
            .map(|ring| ring.decoded_len())
            .unwrap_or(0);
        Some((
            session
                .shared
                .drain_flag
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .reader_returned
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .reader_error
                .load(std::sync::atomic::Ordering::SeqCst),
            decoded,
        ))
    }

    pub fn testing_session_clean_bits(
        &self,
        run_id: &RunId,
    ) -> Option<(
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        Option<u32>,
    )> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        let active = session.shared.job_active_processes();
        Some((
            session.session_clean(),
            session
                .shared
                .handle_signaled
                .load(std::sync::atomic::Ordering::SeqCst),
            session.job_empty(),
            session
                .shared
                .drain_flag
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .reader_returned
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .waiter_returned
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .teardown_returned
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .pty_closed
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .force_killed
                .load(std::sync::atomic::Ordering::SeqCst),
            active,
        ))
    }

    #[cfg(debug_assertions)]
    pub fn testing_owned_process_identity(&self, run_id: &RunId) -> Option<(u32, u64)> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        let child = session
            .child
            .as_ref()
            .filter(|child| child.process.is_valid())?;
        let handle = child.process.0;
        // SAFETY: the session lock keeps the still-owned process HANDLE live.
        unsafe {
            let pid = windows_sys::Win32::System::Threading::GetProcessId(handle);
            if pid == 0 {
                return None;
            }
            let mut creation = windows_sys::Win32::Foundation::FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            };
            let mut exit_time = windows_sys::Win32::Foundation::FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            };
            let mut kernel = windows_sys::Win32::Foundation::FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            };
            let mut user = windows_sys::Win32::Foundation::FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            };
            if windows_sys::Win32::System::Threading::GetProcessTimes(
                handle,
                &mut creation,
                &mut exit_time,
                &mut kernel,
                &mut user,
            ) == 0
            {
                return None;
            }
            Some((
                pid,
                ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64,
            ))
        }
    }

    pub fn testing_ctrl_c_stats(&self, run_id: &RunId) -> Option<(u32, bool, bool, bool)> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        Some((
            session.ctrl_c_writes(),
            session.ctrl_c_delivered(),
            session
                .shared
                .write_cancelled
                .load(std::sync::atomic::Ordering::SeqCst),
            session
                .shared
                .write_pending
                .load(std::sync::atomic::Ordering::SeqCst),
        ))
    }

    #[cfg(debug_assertions)]
    pub fn testing_job_stop_stats(
        &self,
        run_id: &RunId,
    ) -> Option<(u32, bool, bool, bool, Option<u32>, Option<u32>)> {
        let inner = self.inner.lock().ok()?;
        let session = inner.sessions.get(run_id.as_str())?;
        Some(session.shared.testing_job_stop_stats())
    }

    #[cfg(debug_assertions)]
    pub fn testing_fail_job_terminate_once(&self, run_id: &RunId) -> Result<(), ErrorCode> {
        let shared = self.shared_of(run_id)?;
        shared.fail_job_terminate_once();
        Ok(())
    }

    pub fn testing_has_session(&self, run_id: &RunId) -> bool {
        self.inner
            .lock()
            .ok()
            .is_some_and(|inner| inner.sessions.contains_key(run_id.as_str()))
    }

    pub fn testing_install_write(
        &self,
        run_id: &RunId,
        op: spawn::PinnedWrite,
    ) -> Result<(), ErrorCode> {
        let Ok(inner) = self.inner.lock() else {
            spawn::retain_write(op);
            return Err(ErrorCode::RuntimeFailed);
        };
        let Some(session) = inner.sessions.get(run_id.as_str()) else {
            spawn::retain_write(op);
            return Err(ErrorCode::TargetNotFound);
        };
        session.shared.install_pinned_write(op)
    }

    pub fn take_jobs_for_generation_close(&self) -> Vec<HANDLE> {
        self.generation_visible.store(false, Ordering::SeqCst);
        let Ok(mut inner) = self.inner.lock() else {
            return Vec::new();
        };
        let mut jobs = Vec::new();
        for session in inner.sessions.values_mut() {
            session.shared.set_generation_open(false);
            session.shared.cancel_all_fifo_and_pins();
            if session.phase == SessionPhase::Preparing {
                let job = session.shared.take_job_for_containment();
                if !job.is_null() && job != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                    jobs.push(job);
                }
                session.phase = SessionPhase::Failed;
                session
                    .shared
                    .force_killed
                    .store(true, std::sync::atomic::Ordering::SeqCst);
                session.shared.request_cleanup();
                continue;
            }
            if session.session_clean() {
                continue;
            }
            session
                .shared
                .force_killed
                .store(true, std::sync::atomic::Ordering::SeqCst);
            let job = session.shared.take_job_for_containment();
            if !job.is_null() && job != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                jobs.push(job);
            }
            session.shared.request_cleanup();
        }
        jobs
    }
}

#[derive(Debug)]
pub enum Activation {
    Published {
        process: Process,
        work: Work,
        exit_code: Option<u32>,
    },
    AlreadyRunnable,
    ExtraSuspension,
    ResumeFailed,
}

impl Drop for RuntimeService {
    fn drop(&mut self) {
        let _ = self.drain_provider_probes();
        if let Ok(inner) = self.inner.lock() {
            for session in inner.sessions.values() {
                session.shared.retain_pin();
            }
        }
        let jobs = self.take_jobs_for_generation_close();
        for job in jobs {
            if !job.is_null() {
                unsafe {
                    windows_sys::Win32::Foundation::CloseHandle(job);
                }
            }
        }
    }
}

pub fn envelope_text(text: &str, max_bytes: u64) -> (String, bool) {
    let budget = MAX_MESSAGE_BYTES.saturating_sub(1024);
    let (clamped, truncated) =
        clamp_text_to_envelope(text, max_bytes, budget.max(json_string_len("") + 8));
    (clamped, truncated)
}

#[cfg(test)]
mod envelope_tests {
    use super::envelope_text;

    #[test]
    fn large_japanese_is_truncated_not_empty() {
        let huge = "あ".repeat(400_000);
        let (text, truncated) = envelope_text(&huge, u64::MAX);
        assert!(truncated);
        assert!(!text.is_empty());
        assert!(text.len() < 1_048_576);
    }
}

#[cfg(all(test, debug_assertions))]
mod cleanup_observer_retained_tests {
    use super::*;
    use std::sync::mpsc::{self, Sender};
    use std::time::{Duration, Instant};

    struct ReleaseOnDrop(Option<Sender<()>>);
    impl Drop for ReleaseOnDrop {
        fn drop(&mut self) {
            if let Some(sender) = self.0.take() {
                let _ = sender.send(());
            }
        }
    }

    fn prepared_runtime() -> (RuntimeService, RunId) {
        let runtime = RuntimeService::new();
        let project = ProjectId::new(uuid::Uuid::new_v4().to_string()).unwrap();
        let pane = PaneId::new(uuid::Uuid::new_v4().to_string()).unwrap();
        let run = RunId::new(uuid::Uuid::new_v4().to_string()).unwrap();
        runtime
            .insert_preparing(project, pane, run.clone())
            .unwrap();
        let child = RuntimeService::spawn_usual_shell_child(std::env::temp_dir().to_str().unwrap())
            .unwrap();
        runtime.attach_child(&run, child).unwrap();
        (runtime, run)
    }

    fn released(snapshot: &RetainedCleanupSnapshot) -> bool {
        snapshot.process_signaled
            && snapshot.reader_signaled
            && snapshot.waiter_signaled
            && snapshot.teardown_signaled
            && snapshot.handle_signaled
            && snapshot.drain_complete
            && snapshot.reader_returned
            && snapshot.waiter_returned
            && snapshot.teardown_returned
            && snapshot.pty_closed
            && !snapshot.write_pending
            && snapshot.io.pty_closed
            && !snapshot.io.write_pending
            && !snapshot.io.pin_present
            && !snapshot.io.input_handle_present
            && !snapshot.io.hpcon_handle_present
            && snapshot.io.input_lease_count == 0
            && snapshot.io.hpcon_lease_count == 0
    }

    fn wait_released(observer: &RetainedCleanupObservation) -> RetainedCleanupSnapshot {
        // Reuse the existing native runtime completion observation contract.
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let snapshot = observer.snapshot().unwrap();
            if released(&snapshot) {
                return snapshot;
            }
            assert!(
                Instant::now() < deadline,
                "retained cleanup incomplete: {snapshot:?}"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn same_object(first: HANDLE, second: HANDLE) -> bool {
        unsafe { windows_sys::Win32::Foundation::CompareObjectHandles(first, second) != 0 }
    }

    #[test]
    fn cleanup_observer_retains_exact_process_after_session_removal() {
        let (runtime, run) = prepared_runtime();
        let observer = runtime.testing_retain_cleanup(&run).unwrap();
        let before = observer.snapshot().unwrap();
        assert_eq!(before.run_id, run);
        assert_eq!(before.prepared_job_members, 1);
        assert_eq!(before.job_active_processes, Some(1));
        assert!(!before.process_signaled && !before.job_contained && !released(&before));
        assert!(before.io.input_handle_present && before.io.hpcon_handle_present);
        assert_eq!(observer.snapshot().unwrap(), before);
        runtime.finalize_failure(&run, true);
        assert!(!runtime.has_session(&run));
        assert_eq!(runtime.testing_owned_process_identity(&run), None);
        let after = wait_released(&observer);
        assert_eq!(
            (after.process_id, after.creation_time),
            (before.process_id, before.creation_time)
        );
        assert!(after.job_contained);
        assert_eq!(after.job_active_processes, None); // Ownership released, not a native count of zero.
        assert_eq!(observer.snapshot().unwrap(), after);
        let weak = Arc::downgrade(&observer.shared);
        let handles = [
            observer.process.0,
            observer.reader.0,
            observer.waiter.0,
            observer.teardown.0,
        ];
        let identities = handles.map(|handle| {
            spawn::RawHandle(spawn::duplicate_handle(handle).expect("duplicate identity handle"))
        });
        for (handle, identity) in handles.iter().zip(&identities) {
            assert!(same_object(*handle, identity.0));
        }
        drop(observer);
        for (handle, identity) in handles.iter().zip(&identities) {
            assert!(
                !same_object(*handle, identity.0),
                "observation duplicate still points to the original object"
            );
        }
        assert!(
            weak.upgrade().is_none(),
            "observation must not retain session state after drop"
        );
    }

    #[test]
    fn cleanup_observer_waiter_flag_does_not_prove_callback_thread_exit() {
        let (runtime, run) = prepared_runtime();
        let (entered_sender, entered) = mpsc::channel();
        let (release, released_receiver) = mpsc::channel();
        let released_receiver = Arc::new(Mutex::new(released_receiver));
        let release = ReleaseOnDrop(Some(release));
        runtime.set_exit_callback(Arc::new(move |_| {
            let _ = entered_sender.send(());
            let _ = released_receiver.lock().unwrap().recv();
        }));
        let observer = runtime.testing_retain_cleanup(&run).unwrap();
        runtime.finalize_failure(&run, true);
        entered
            .recv_timeout(Duration::from_secs(30))
            .expect("exact waiter entered callback");
        let during = observer.snapshot().unwrap();
        assert!(during.process_signaled && during.waiter_returned);
        assert!(!during.waiter_signaled && !released(&during));
        drop(release);
        assert!(released(&wait_released(&observer)));
    }

    #[test]
    fn cleanup_observer_partial_acquisition_releases_only_its_duplicates() {
        let (runtime, run) = prepared_runtime();
        let mut copies = Vec::new();
        let mut identities = Vec::new();
        let failed = runtime.retain_cleanup_with(&run, |handle| {
            if copies.len() == 2 {
                return None;
            }
            let copy = spawn::duplicate_handle(handle).unwrap();
            identities.push(spawn::RawHandle(spawn::duplicate_handle(copy).unwrap()));
            copies.push(copy);
            Some(copy)
        });
        assert!(matches!(failed, Err(ErrorCode::RuntimeFailed)));
        assert_eq!(copies.len(), 2);
        for (copy, identity) in copies.into_iter().zip(&identities) {
            assert!(!same_object(copy, identity.0));
        }
        assert_eq!(runtime.testing_job_stop_stats(&run).unwrap().5, Some(1));
        let observer = runtime.testing_retain_cleanup(&run).unwrap();
        runtime.finalize_failure(&run, true);
        wait_released(&observer);
    }

    #[test]
    fn cleanup_observer_rejects_missing_unprepared_and_wrong_identity() {
        let runtime = RuntimeService::new();
        let run = RunId::new(uuid::Uuid::new_v4().to_string()).unwrap();
        assert!(matches!(
            runtime.testing_retain_cleanup(&run),
            Err(ErrorCode::TargetNotFound)
        ));
        runtime
            .insert_preparing(
                ProjectId::new(uuid::Uuid::new_v4().to_string()).unwrap(),
                PaneId::new(uuid::Uuid::new_v4().to_string()).unwrap(),
                run.clone(),
            )
            .unwrap();
        assert!(matches!(
            runtime.testing_retain_cleanup(&run),
            Err(ErrorCode::RuntimeFailed)
        ));
        runtime.finalize_failure(&run, false);
        for handle in [
            std::ptr::null_mut(),
            windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE,
        ] {
            assert_eq!(inspect_signaled(handle), Err(ErrorCode::RuntimeFailed));
            assert_eq!(
                inspect_process_identity(handle),
                Err(ErrorCode::RuntimeFailed)
            );
        }
        let (runtime, run) = prepared_runtime();
        let mut observer = runtime.testing_retain_cleanup(&run).unwrap();
        let identity = observer.creation_time;
        observer.creation_time ^= 1;
        assert_eq!(observer.snapshot(), Err(ErrorCode::RuntimeFailed));
        observer.creation_time = identity;
        runtime.finalize_failure(&run, true);
        wait_released(&observer);
    }
}

#[cfg(test)]
mod owner_api_tests {
    use super::*;
    use crate::contract::{ErrorCode, PaneId, ProjectId, RunId};
    use spawn::issue_pending_overlapped_write;

    #[test]
    fn testing_install_write_is_pinned_not_teardown() {
        let runtime = RuntimeService::new();
        let project = ProjectId::new("30000000-0000-4000-8000-00000000af01").expect("p");
        let pane = PaneId::new("40000000-0000-4000-8000-00000000af01").expect("pane");
        let run = RunId::new("50000000-0000-4000-8000-00000000af01").expect("run");
        runtime
            .insert_preparing(project, pane, run.clone())
            .expect("prep");
        let (op, _, _) = issue_pending_overlapped_write().expect("pending pin");
        runtime.testing_install_write(&run, op).expect("install");
        let stats = runtime.testing_input_stats(&run).expect("stats");
        assert_eq!(stats.data_slot, TestingDataSlot::Pinned);
        assert!(!stats.teardown_ctrl_reserved);
        assert!(stats.write_pending);
        assert_eq!(stats.input_lease_count, 0);
    }

    #[test]
    fn enqueue_ticket_is_run_bound_before_admit() {
        let runtime = RuntimeService::new();
        let run_a = RunId::new("50000000-0000-4000-8000-00000000af11").expect("run a");
        let run_b = RunId::new("50000000-0000-4000-8000-00000000af12").expect("run b");
        runtime
            .insert_preparing(
                ProjectId::new("30000000-0000-4000-8000-00000000af11").expect("p a"),
                PaneId::new("40000000-0000-4000-8000-00000000af11").expect("pane a"),
                run_a.clone(),
            )
            .expect("prep a");
        runtime
            .insert_preparing(
                ProjectId::new("30000000-0000-4000-8000-00000000af11").expect("p b"),
                PaneId::new("40000000-0000-4000-8000-00000000af11").expect("pane b"),
                run_b.clone(),
            )
            .expect("prep b");
        let ticket_a = runtime
            .enqueue_data(&run_a, RunDataKind::Write, 1)
            .expect("enqueue a");
        let ticket_b = runtime
            .enqueue_data(&run_b, RunDataKind::Write, 1)
            .expect("enqueue b");
        assert_ne!(ticket_a, ticket_b);
        let stats_a = runtime.testing_input_stats(&run_a).expect("stats a");
        let stats_b = runtime.testing_input_stats(&run_b).expect("stats b");
        assert_eq!(stats_a.fifo_ids, vec![ticket_a.as_u64()]);
        assert_eq!(stats_b.fifo_ids, vec![ticket_b.as_u64()]);
        assert_eq!(stats_a.data_slot, TestingDataSlot::Free);
        assert_eq!(stats_b.data_slot, TestingDataSlot::Free);
        assert_eq!(
            runtime.cancel_data(&run_b, ticket_a).unwrap_err(),
            ErrorCode::TargetNotFound
        );
        assert_eq!(
            runtime
                .testing_input_stats(&run_a)
                .expect("stats a")
                .fifo_ids,
            vec![ticket_a.as_u64()]
        );
        assert_eq!(
            runtime
                .testing_input_stats(&run_b)
                .expect("stats b")
                .fifo_ids,
            vec![ticket_b.as_u64()]
        );
        runtime.cancel_data(&run_a, ticket_a).expect("cancel a");
        runtime
            .cancel_data(&run_a, ticket_a)
            .expect("repeat cancel a");
        assert!(runtime
            .testing_input_stats(&run_a)
            .expect("stats a")
            .fifo_ids
            .is_empty());
        assert_eq!(
            runtime
                .testing_input_stats(&run_b)
                .expect("stats b")
                .fifo_ids,
            vec![ticket_b.as_u64()]
        );
    }
}

/// All-session restore/HostStop classification. Not a per-project or current-run subset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CompleteSessionQuiescence {
    Preparing,
    Unclean,
    Clean,
}

fn classify_quiescence<'a>(
    sessions: impl Iterator<Item = &'a RunSession>,
) -> CompleteSessionQuiescence {
    let mut unclean = false;
    for session in sessions {
        if session.phase == SessionPhase::Preparing {
            return CompleteSessionQuiescence::Preparing;
        }
        unclean |= !session.session_clean();
    }
    if unclean {
        CompleteSessionQuiescence::Unclean
    } else {
        CompleteSessionQuiescence::Clean
    }
}

impl RuntimeService {
    /// Every workspace run reference must still name its original runtime owner.
    /// A missing or mismatched record is unknown, never evidence of cleanliness.
    pub(crate) fn project_session_quiescence(
        &self,
        project_id: &ProjectId,
        panes: &topology::ProjectPanes,
    ) -> Result<CompleteSessionQuiescence, ErrorCode> {
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        for pane in &panes.panes {
            for run in pane.current_run.iter().chain(&pane.previous_runs) {
                let session = inner
                    .sessions
                    .get(run.as_str())
                    .ok_or(ErrorCode::RuntimeFailed)?;
                if session.project_id.as_str() != project_id.as_str()
                    || session.pane_id.as_str() != pane.id.as_str()
                {
                    return Err(ErrorCode::RuntimeFailed);
                }
            }
        }
        Ok(classify_quiescence(inner.sessions.values().filter(|session| {
            session.project_id.as_str() == project_id.as_str()
        })))
    }

    /// Read-only complete-session classification. Poison is RuntimeFailed, never Clean.
    pub(crate) fn complete_session_quiescence(
        &self,
    ) -> Result<CompleteSessionQuiescence, ErrorCode> {
        let inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        Ok(classify_quiescence(inner.sessions.values()))
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_set_unclean_project_session(
        &self,
        project_id: ProjectId,
        live: bool,
    ) -> Result<(), ErrorCode> {
        let pane_id = PaneId::new("40000000-0000-4000-8000-000000000866")
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        let run_id = RunId::new(format!("5{}", &project_id.as_str()[1..]))
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        let mut inner = self.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        if let Some(existing) = inner.sessions.get(run_id.as_str()) {
            if existing.project_id.as_str() != project_id.as_str()
                || existing.pane_id.as_str() != pane_id.as_str()
            {
                return Err(ErrorCode::OperationConflict);
            }
        }
        if live {
            if !inner.sessions.contains_key(run_id.as_str()) {
                let mut session = RunSession::new(project_id, pane_id, run_id.clone());
                session.phase = SessionPhase::Failed;
                inner.sessions.insert(run_id.as_str().to_owned(), session);
            }
        } else {
            inner.sessions.remove(run_id.as_str());
        }
        Ok(())
    }
}

#[cfg(test)]
mod complete_session_quiescence_tests {
    use super::{CompleteSessionQuiescence, RuntimeService, SessionPhase};
    use crate::contract::{ErrorCode, NonEmpty, Nullable, PaneId, ProjectId, RunId};
    use crate::runtime::topology::{PaneRecord, ProjectPanes};
    use std::sync::atomic::Ordering;

    fn session_len(runtime: &RuntimeService) -> usize {
        runtime.inner.lock().expect("lock").sessions.len()
    }

    fn retained_state(
        runtime: &RuntimeService,
        run: &RunId,
    ) -> (
        usize,
        bool,
        SessionPhase,
        bool,
        bool,
        Option<(
            bool,
            bool,
            bool,
            bool,
            bool,
            bool,
            bool,
            bool,
            bool,
            Option<u32>,
        )>,
    ) {
        let (phase, current, clean) = {
            let inner = runtime.inner.lock().expect("lock");
            let session = inner.sessions.get(run.as_str()).expect("session");
            (session.phase, session.current, session.session_clean())
        };
        (
            session_len(runtime),
            runtime.testing_has_session(run),
            phase,
            current,
            clean,
            runtime.testing_session_clean_bits(run),
        )
    }

    fn mark_clean_history(
        runtime: &RuntimeService,
        project: ProjectId,
        pane: PaneId,
        run: &RunId,
        current: bool,
    ) {
        runtime
            .insert_preparing(project, pane, run.clone())
            .expect("prep");
        {
            let mut inner = runtime.inner.lock().expect("lock");
            let session = inner.sessions.get_mut(run.as_str()).expect("session");
            session.phase = SessionPhase::Failed;
            session.current = current;
            session
                .shared
                .handle_signaled
                .store(true, Ordering::SeqCst);
            session.shared.drain_flag.store(true, Ordering::SeqCst);
            session
                .shared
                .reader_returned
                .store(true, Ordering::SeqCst);
            session
                .shared
                .waiter_returned
                .store(true, Ordering::SeqCst);
            session
                .shared
                .teardown_returned
                .store(true, Ordering::SeqCst);
            session.shared.pty_closed.store(true, Ordering::SeqCst);
        }
        assert!(runtime.session_clean(run), "clean history flags");
    }

    #[test]
    fn empty_sessions_are_clean() {
        let runtime = RuntimeService::new();
        assert_eq!(session_len(&runtime), 0);
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Clean)
        );
        assert_eq!(session_len(&runtime), 0);
    }

    #[test]
    fn all_clean_histories_are_clean_and_unmutated() {
        let runtime = RuntimeService::new();
        let run_current =
            RunId::new("50000000-0000-4000-8000-0000000086a1").expect("run current");
        let run_history =
            RunId::new("50000000-0000-4000-8000-0000000086a2").expect("run history");
        mark_clean_history(
            &runtime,
            ProjectId::new("30000000-0000-4000-8000-0000000086a1").expect("p current"),
            PaneId::new("40000000-0000-4000-8000-0000000086a1").expect("pane current"),
            &run_current,
            true,
        );
        mark_clean_history(
            &runtime,
            ProjectId::new("30000000-0000-4000-8000-0000000086a2").expect("p history"),
            PaneId::new("40000000-0000-4000-8000-0000000086a2").expect("pane history"),
            &run_history,
            false,
        );
        let before_current = retained_state(&runtime, &run_current);
        let before_history = retained_state(&runtime, &run_history);
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Clean)
        );
        assert_eq!(retained_state(&runtime, &run_current), before_current);
        assert_eq!(retained_state(&runtime, &run_history), before_history);
        assert!(runtime.session_clean(&run_current));
        assert!(runtime.session_clean(&run_history));
    }

    #[test]
    fn unattached_preparing_is_preparing_and_unmutated() {
        let runtime = RuntimeService::new();
        let run = RunId::new("50000000-0000-4000-8000-0000000086b1").expect("run");
        runtime
            .insert_preparing(
                ProjectId::new("30000000-0000-4000-8000-0000000086b1").expect("p"),
                PaneId::new("40000000-0000-4000-8000-0000000086b1").expect("pane"),
                run.clone(),
            )
            .expect("prep");
        let unattached = {
            let inner = runtime.inner.lock().expect("lock");
            inner
                .sessions
                .get(run.as_str())
                .expect("session")
                .child
                .is_none()
        };
        assert!(unattached);
        let before = retained_state(&runtime, &run);
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Preparing)
        );
        assert_eq!(retained_state(&runtime, &run), before);
        let inner = runtime.inner.lock().expect("lock");
        let session = inner.sessions.get(run.as_str()).expect("session");
        assert_eq!(session.phase, SessionPhase::Preparing);
        assert!(session.child.is_none());
    }

    #[test]
    fn unclean_historical_non_current_session_is_unclean_and_unmutated() {
        let runtime = RuntimeService::new();
        let run_current =
            RunId::new("50000000-0000-4000-8000-0000000086d1").expect("run current");
        let run_history =
            RunId::new("50000000-0000-4000-8000-0000000086d2").expect("run history");
        mark_clean_history(
            &runtime,
            ProjectId::new("30000000-0000-4000-8000-0000000086d1").expect("p current"),
            PaneId::new("40000000-0000-4000-8000-0000000086d1").expect("pane current"),
            &run_current,
            true,
        );
        runtime
            .insert_preparing(
                ProjectId::new("30000000-0000-4000-8000-0000000086d2").expect("p history"),
                PaneId::new("40000000-0000-4000-8000-0000000086d2").expect("pane history"),
                run_history.clone(),
            )
            .expect("prep");
        {
            let mut inner = runtime.inner.lock().expect("lock");
            let session = inner
                .sessions
                .get_mut(run_history.as_str())
                .expect("session");
            session.phase = SessionPhase::Failed;
            session.current = false;
        }
        assert!(!runtime.session_clean(&run_history));
        assert!(runtime.session_clean(&run_current));
        let before_current = retained_state(&runtime, &run_current);
        let before_history = retained_state(&runtime, &run_history);
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Unclean)
        );
        assert_eq!(retained_state(&runtime, &run_current), before_current);
        assert_eq!(retained_state(&runtime, &run_history), before_history);
        let inner = runtime.inner.lock().expect("lock");
        let history = inner.sessions.get(run_history.as_str()).expect("history");
        assert_eq!(history.phase, SessionPhase::Failed);
        assert!(!history.current);
    }

    #[test]
    fn preparing_takes_precedence_in_either_insertion_order() {
        fn insert_other(runtime: &RuntimeService, run: &RunId, clean: bool) {
            if clean {
                mark_clean_history(
                    runtime,
                    ProjectId::new("30000000-0000-4000-8000-0000000086c1").expect("p other"),
                    PaneId::new("40000000-0000-4000-8000-0000000086c1").expect("pane other"),
                    run,
                    true,
                );
            } else {
                runtime
                    .insert_preparing(
                        ProjectId::new("30000000-0000-4000-8000-0000000086c1").expect("p other"),
                        PaneId::new("40000000-0000-4000-8000-0000000086c1").expect("pane other"),
                        run.clone(),
                    )
                    .expect("other");
                let mut inner = runtime.inner.lock().expect("lock");
                let session = inner.sessions.get_mut(run.as_str()).expect("other");
                session.phase = SessionPhase::Failed;
                session.current = false;
            }
        }
        fn insert_prep(runtime: &RuntimeService, run: &RunId) {
            runtime
                .insert_preparing(
                    ProjectId::new("30000000-0000-4000-8000-0000000086c2").expect("p prep"),
                    PaneId::new("40000000-0000-4000-8000-0000000086c2").expect("pane prep"),
                    run.clone(),
                )
                .expect("prep");
        }
        for prep_first in [true, false] {
            for other_clean in [true, false] {
                let runtime = RuntimeService::new();
                let run_other =
                    RunId::new("50000000-0000-4000-8000-0000000086c1").expect("run other");
                let run_prep =
                    RunId::new("50000000-0000-4000-8000-0000000086c2").expect("run prep");
                if prep_first {
                    insert_prep(&runtime, &run_prep);
                    insert_other(&runtime, &run_other, other_clean);
                } else {
                    insert_other(&runtime, &run_other, other_clean);
                    insert_prep(&runtime, &run_prep);
                }
                let before_other = retained_state(&runtime, &run_other);
                let before_prep = retained_state(&runtime, &run_prep);
                assert_eq!(
                    runtime.complete_session_quiescence(),
                    Ok(CompleteSessionQuiescence::Preparing)
                );
                assert_eq!(retained_state(&runtime, &run_other), before_other);
                assert_eq!(retained_state(&runtime, &run_prep), before_prep);
                let inner = runtime.inner.lock().expect("lock");
                let prep = inner.sessions.get(run_prep.as_str()).expect("prep");
                assert_eq!(prep.phase, SessionPhase::Preparing);
                assert!(prep.child.is_none());
            }
        }
    }

    #[test]
    fn poisoned_query_returns_runtime_failed_never_clean() {
        let runtime = RuntimeService::new();
        let run = RunId::new("50000000-0000-4000-8000-0000000086e1").expect("run");
        mark_clean_history(
            &runtime,
            ProjectId::new("30000000-0000-4000-8000-0000000086e1").expect("p"),
            PaneId::new("40000000-0000-4000-8000-0000000086e1").expect("pane"),
            &run,
            true,
        );
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Clean)
        );
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _inner = runtime.inner.lock().expect("lock");
            panic!("poison complete-session quiescence mutex");
        }));
        assert!(panicked.is_err());
        let result = runtime.complete_session_quiescence();
        assert_eq!(result, Err(ErrorCode::RuntimeFailed));
        assert!(!matches!(result, Ok(CompleteSessionQuiescence::Clean)));
        let project = ProjectId::new("30000000-0000-4000-8000-0000000086e1").expect("project");
        assert_eq!(
            runtime.project_session_quiescence(&project, &ProjectPanes::default()),
            Err(ErrorCode::RuntimeFailed)
        );
    }

    #[test]
    fn project_quiescence_scopes_siblings_and_rejects_missing_or_mismatched_references() {
        let runtime = RuntimeService::new();
        let project = ProjectId::new("30000000-0000-4000-8000-0000000086f1").unwrap();
        let sibling = ProjectId::new("30000000-0000-4000-8000-0000000086f2").unwrap();
        let pane = PaneId::new("40000000-0000-4000-8000-0000000086f1").unwrap();
        let sibling_pane = PaneId::new("40000000-0000-4000-8000-0000000086f2").unwrap();
        let run = RunId::new("50000000-0000-4000-8000-0000000086f5").unwrap();
        let sibling_run = RunId::new("50000000-0000-4000-8000-0000000086f6").unwrap();
        mark_clean_history(&runtime, project.clone(), pane.clone(), &run, true);
        runtime
            .insert_preparing(sibling.clone(), sibling_pane, sibling_run)
            .unwrap();
        let mut panes = ProjectPanes {
            panes: vec![PaneRecord {
                id: pane.clone(),
                current_run: Some(run.clone()),
                previous_runs: Vec::new(),
                shell_profile_id: NonEmpty::new("pwsh").unwrap(),
                provider_profile: Nullable(None),
            }],
            ..ProjectPanes::default()
        };
        assert_eq!(
            runtime.project_session_quiescence(&project, &panes),
            Ok(CompleteSessionQuiescence::Clean)
        );
        assert_eq!(
            runtime.complete_session_quiescence(),
            Ok(CompleteSessionQuiescence::Preparing)
        );
        panes.panes[0].previous_runs.push(
            RunId::new("50000000-0000-4000-8000-0000000086f3").unwrap(),
        );
        assert_eq!(
            runtime.project_session_quiescence(&project, &panes),
            Err(ErrorCode::RuntimeFailed)
        );
        panes.panes[0].previous_runs.clear();
        panes.panes[0].id = PaneId::new("40000000-0000-4000-8000-0000000086f4").unwrap();
        assert_eq!(
            runtime.project_session_quiescence(&project, &panes),
            Err(ErrorCode::RuntimeFailed)
        );
        panes.panes[0].id = pane;
        assert_eq!(
            runtime.project_session_quiescence(&sibling, &panes),
            Err(ErrorCode::RuntimeFailed)
        );
        runtime
            .testing_set_unclean_project_session(project.clone(), true)
            .unwrap();
        assert_eq!(
            runtime.project_session_quiescence(&project, &panes),
            Ok(CompleteSessionQuiescence::Unclean)
        );
    }
}
