//! One lifetime owner for admission, input, public I/O and stdout publication.

#[cfg(not(windows))]
pub fn run_stdio(_: winsmux_workspace::host::Discovery) -> Result<(), winsmux_workspace::host::HostError> {
    Err(winsmux_workspace::host::HostError::Startup)
}

#[cfg(windows)]
pub use windows::run_stdio;
#[cfg(all(windows, debug_assertions))]
pub mod testing { pub use super::windows::testing::*; }

#[cfg(windows)]
mod windows {
    use crate::{admit_input, ClassifiedInput, stdio, CallTicket, Effect, ReceiptState, Session};
    use std::io::{self, BufReader, Read, Write};
    use std::mem::{size_of, zeroed};
    use std::os::windows::io::AsRawHandle;
    use std::ptr::{null, null_mut};
    use std::sync::{Arc, Condvar, Mutex, MutexGuard};
    use std::thread::{self, JoinHandle};
    use winsmux_workspace::client::{PublicCancellation, PublicClient, PublicRequestError};
    use winsmux_workspace::contract::{Request, Response};
    use winsmux_workspace::host::{Discovery, HostError};
    use windows_sys::Wdk::Storage::FileSystem::{NtQueryInformationFile, FileAccessInformation,
        FileModeInformation, FILE_ACCESS_INFORMATION, FILE_MODE_INFORMATION,
        FILE_SYNCHRONOUS_IO_ALERT, FILE_SYNCHRONOUS_IO_NONALERT};
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::Storage::FileSystem::{GetFileType, ReadFile, FILE_TYPE_PIPE, FILE_READ_DATA};
    use windows_sys::Win32::System::Console::{GetStdHandle, STD_INPUT_HANDLE};
    use windows_sys::Win32::System::IO::{CancelIoEx, CancelSynchronousIo, GetOverlappedResult,
        IO_STATUS_BLOCK, OVERLAPPED};
    use windows_sys::Win32::System::Pipes::{GetNamedPipeInfo, GetNamedPipeHandleStateW,
        PIPE_TYPE_MESSAGE, PIPE_READMODE_MESSAGE, PIPE_NOWAIT};
    use windows_sys::Win32::System::Threading::{CreateEventW, GetCurrentProcess, SetEvent,
        WaitForSingleObject, WaitForMultipleObjects, ResetEvent, INFINITE};

    struct Handle(HANDLE);
    unsafe impl Send for Handle {}
    unsafe impl Sync for Handle {}
    impl Handle {
        fn new(raw: HANDLE) -> Result<Self, HostError> {
            if raw.is_null() || raw == INVALID_HANDLE_VALUE { Err(HostError::Startup) } else { Ok(Self(raw)) }
        }
        fn event() -> Result<Self, HostError> { Self::new(unsafe { CreateEventW(null(), 1, 0, null()) }) }
    }
    impl Drop for Handle { fn drop(&mut self) { unsafe { CloseHandle(self.0); } } }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum InputMode { Synchronous, Overlapped }
    struct AdmittedInput { handle: Handle, mode: InputMode }
    struct QueryLease {
        handle: Handle,
        iosb: IO_STATUS_BLOCK,
        access: FILE_ACCESS_INFORMATION,
        mode: FILE_MODE_INFORMATION,
    }
    unsafe impl Send for QueryLease {}
    enum AdmissionFailure { Rejected, Pending(Box<QueryLease>) }
    #[derive(Debug, PartialEq, Eq)]
    enum QueryDecision { Complete, Rejected, RetainPending }
    fn query_decision(returned: i32, waited: Option<u32>, final_status: i32, bytes: usize) -> QueryDecision {
        let status = if returned == STATUS_PENDING {
            if waited != Some(WAIT_OBJECT_0) || final_status == STATUS_PENDING { return QueryDecision::RetainPending; }
            final_status
        } else { returned };
        if status == STATUS_SUCCESS && bytes == 4 { QueryDecision::Complete } else { QueryDecision::Rejected }
    }
    fn read_granted(access: u32) -> bool { access & FILE_READ_DATA != 0 }
    fn input_mode(mode: u32) -> Option<InputMode> {
        match mode & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT) {
            0 => Some(InputMode::Overlapped),
            FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT => Some(InputMode::Synchronous),
            _ => None,
        }
    }

    #[cfg(debug_assertions)]
    pub mod testing {
        use super::*;
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum GatePoint {
            AccessComplete, ModeComplete, BeforeReaderSpawn, ReaderRegistered, BeforeAuth,
            Authenticated, BeforeRead, ReadComplete, BeforeDeposit, BeforeSend,
            BeforePublish, BeforeWrite, AfterFlush,
        }
        #[derive(Default, Debug, Clone, serde::Serialize)]
        pub struct Observations {
            pub access_queries: u64, pub mode_queries: u64, pub read_capable: bool,
            pub access_returned_status: Option<i32>, pub mode_returned_status: Option<i32>,
            pub access_final_status: Option<i32>, pub mode_final_status: Option<i32>,
            pub access_information: Option<usize>, pub mode_information: Option<usize>,
            pub access_flags: Option<u32>, pub input_mode_flags: Option<u32>,
            pub readers_started: u64, pub auth_attempts: u64, pub auth_completed: u64,
            pub ordinary_attempts: u64, pub reader_exited: u64, pub worker_exited: u64,
            pub eof_observed: bool, pub synchronous_reads: u64, pub overlapped_reads: u64,
            pub read_completions:u64, pub completed_read_bytes:u64, pub first_read_bytes:Option<u32>,
            pub async_drains: u64, pub sync_cancel_attempts: u64, pub replies_flushed: u64,
            pub control_cancel_signals: u64,
            pub receipts: u64, pub bootstrap_receipts: u64, pub reader_joined: bool,
            pub worker_joined: bool, pub writer_joined: bool,
        }
        struct GateState { reached: bool, released: bool, stopped: bool, receipts:u64, remaining_visits:u64 }
        struct Gate { point: GatePoint, state: Mutex<GateState>, changed: Condvar }
        #[derive(Clone, Default)]
        pub struct RuntimeGates { gate: Option<Arc<Gate>> }
        pub struct GateController { gate: Arc<Gate> }
        impl RuntimeGates {
            pub fn hold(point: GatePoint) -> (Self, GateController) {
                Self::hold_nth(point,1)
            }
            /// Select the exact publication occurrence in a fixed fixture
            /// journey (e.g. call reply after initialize); not a retry limit.
            pub fn hold_nth(point:GatePoint,visit:u64)->(Self,GateController) {
                assert!(visit>0);
                let gate = Arc::new(Gate { point, state: Mutex::new(GateState { reached:false, released:false, stopped:false, receipts:0, remaining_visits:visit }), changed:Condvar::new() });
                (Self { gate:Some(gate.clone()) }, GateController { gate })
            }
            pub(super) fn stop(&self) {
                if let Some(gate) = &self.gate {
                    gate.state.lock().unwrap_or_else(|p| p.into_inner()).stopped = true;
                    gate.changed.notify_all();
                }
            }
            pub(super) fn reach(&self, point: GatePoint) -> bool {
                if let Some(gate) = self.gate.as_ref().filter(|g| g.point == point) {
                    let mut state = gate.state.lock().unwrap_or_else(|p| p.into_inner());
                    if state.stopped {return true;}
                    if state.remaining_visits>1 {state.remaining_visits-=1;return false;}
                    state.reached = true; gate.changed.notify_all();
                    while !state.released && !state.stopped {
                        state = gate.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                    }
                    return state.stopped;
                }
                false
            }
            pub(super) fn receipt(&self) {
                if let Some(gate)=&self.gate {
                    gate.state.lock().unwrap_or_else(|p|p.into_inner()).receipts+=1;
                    gate.changed.notify_all();
                }
            }
        }
        impl GateController {
            pub fn wait_reached(&self) -> bool {
                let mut state = self.gate.state.lock().unwrap_or_else(|p| p.into_inner());
                while !state.reached && !state.stopped {
                    state = self.gate.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                }
                state.reached
            }
            pub fn release(&self) {
                self.gate.state.lock().unwrap_or_else(|p| p.into_inner()).released = true;
                self.gate.changed.notify_all();
            }
            /// Wait for actual production complete-line deposits, not writes to stdin.
            pub fn wait_receipts(&self,count:u64) -> bool {
                let mut state=self.gate.state.lock().unwrap_or_else(|p|p.into_inner());
                while state.receipts<count&&!state.stopped {
                    state=self.gate.changed.wait(state).unwrap_or_else(|p|p.into_inner());
                }
                state.receipts>=count
            }
            pub fn cancel(&self) {
                self.gate.state.lock().unwrap_or_else(|p| p.into_inner()).stopped = true;
                self.gate.changed.notify_all();
            }
        }
        impl Drop for GateController { fn drop(&mut self) { self.release(); } }
        pub fn run_stdio_fixture(discovery: Discovery, gates: RuntimeGates)
            -> (Result<(), HostError>, Observations) { super::run_core(discovery, gates) }
    }
    #[cfg(debug_assertions)]
    use testing::{GatePoint, Observations, RuntimeGates};
    #[cfg(debug_assertions)]
    fn observe(shared: &Shared, update: impl FnOnce(&mut Observations)) { update(&mut lock(shared).observations); }
    #[cfg(debug_assertions)]
    fn gate(shared: &Shared, point: GatePoint) { if shared.gates.reach(point) { fail(shared, None); } }

    fn pipe_metadata(handle: HANDLE) -> bool {
        let mut flags = 0;
        let mut state = 0;
        unsafe {
            GetFileType(handle) == FILE_TYPE_PIPE
                && GetNamedPipeInfo(handle, &mut flags, null_mut(), null_mut(), null_mut()) != 0
                && flags & PIPE_TYPE_MESSAGE == 0
                && GetNamedPipeHandleStateW(handle, &mut state, null_mut(), null_mut(), null_mut(), null_mut(), 0) != 0
                && state & (PIPE_READMODE_MESSAGE | PIPE_NOWAIT) == 0
        }
    }

    /// Query buffers remain at their Box address through actual native completion.
    fn query(lease: &mut QueryLease, access: bool, shared: &Shared) -> Result<(), bool> {
        lease.iosb = unsafe { zeroed() };
        let (buffer, class) = if access {
            (&mut lease.access as *mut FILE_ACCESS_INFORMATION as *mut _, FileAccessInformation)
        } else { (&mut lease.mode as *mut FILE_MODE_INFORMATION as *mut _, FileModeInformation) };
        let returned = unsafe { NtQueryInformationFile(lease.handle.0, &mut lease.iosb, buffer, 4, class) };
        #[cfg(debug_assertions)]
        observe(shared,|o|if access{o.access_returned_status=Some(returned)}else{o.mode_returned_status=Some(returned)});
        let waited = if returned == STATUS_PENDING { Some(unsafe { WaitForSingleObject(lease.handle.0, INFINITE) }) } else { None };
        // Failed/ambiguous waits do not establish completion. Do not even read
        // the IOSB or output memory while the native operation may still write.
        if returned==STATUS_PENDING && waited!=Some(WAIT_OBJECT_0) {return Err(true);}
        let final_status=if returned==STATUS_PENDING {unsafe {lease.iosb.Anonymous.Status}}else{returned};
        if final_status==STATUS_PENDING {return Err(true);}
        let information=lease.iosb.Information;
        #[cfg(debug_assertions)]
        observe(shared,|o|if access{o.access_final_status=Some(final_status);o.access_information=Some(information)}else{o.mode_final_status=Some(final_status);o.mode_information=Some(information)});
        #[cfg(not(debug_assertions))]
        let _=shared;
        match query_decision(returned, waited, final_status, information) {
            QueryDecision::Complete => Ok(()), QueryDecision::Rejected => Err(false), QueryDecision::RetainPending => Err(true),
        }
    }

    fn admit(shared: &Shared) -> Result<AdmittedInput, AdmissionFailure> {
        let original = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        if original.is_null() || original == INVALID_HANDLE_VALUE { return Err(AdmissionFailure::Rejected); }
        let mut duplicate = null_mut();
        let process = unsafe { GetCurrentProcess() };
        if unsafe { DuplicateHandle(process, original, process, &mut duplicate, 0, 0, DUPLICATE_SAME_ACCESS) } == 0 {
            return Err(AdmissionFailure::Rejected);
        }
        let handle = Handle::new(duplicate).map_err(|_| AdmissionFailure::Rejected)?;
        if !pipe_metadata(handle.0) { return Err(AdmissionFailure::Rejected); }
        if !matches!(unsafe { WaitForSingleObject(handle.0, 0) }, WAIT_OBJECT_0 | WAIT_TIMEOUT) {
            return Err(AdmissionFailure::Rejected);
        }
        assert_eq!(size_of::<FILE_ACCESS_INFORMATION>(), 4);
        assert_eq!(size_of::<FILE_MODE_INFORMATION>(), 4);
        let mut lease = Box::new(QueryLease { handle, iosb: unsafe { zeroed() },
            access: unsafe { zeroed() }, mode: unsafe { zeroed() } });
        if lock(shared).closed { return Err(AdmissionFailure::Rejected); }
        #[cfg(debug_assertions)]
        observe(shared, |o| o.access_queries += 1);
        if let Err(pending) = query(&mut lease, true, shared) {
            return Err(if pending { AdmissionFailure::Pending(lease) } else { AdmissionFailure::Rejected });
        }
        #[cfg(debug_assertions)]
        { observe(shared, |o| {o.read_capable = read_granted(lease.access.AccessFlags);o.access_flags=Some(lease.access.AccessFlags);}); gate(shared, GatePoint::AccessComplete); }
        if !read_granted(lease.access.AccessFlags) || lock(shared).closed { return Err(AdmissionFailure::Rejected); }
        #[cfg(debug_assertions)]
        observe(shared, |o| o.mode_queries += 1);
        if let Err(pending) = query(&mut lease, false, shared) {
            return Err(if pending { AdmissionFailure::Pending(lease) } else { AdmissionFailure::Rejected });
        }
        let mode = input_mode(lease.mode.Mode).ok_or(AdmissionFailure::Rejected)?;
        #[cfg(debug_assertions)]
        {observe(shared,|o|o.input_mode_flags=Some(lease.mode.Mode));gate(shared, GatePoint::ModeComplete);}
        if lock(shared).closed { return Err(AdmissionFailure::Rejected); }
        Ok(AdmittedInput { handle: lease.handle, mode })
    }

    struct InputReceipt { input: ClassifiedInput, state: ReceiptState, id: Option<serde_json::Value> }
    struct Work { ticket: CallTicket, request: Request, cancel: PublicCancellation }
    struct Outcome { ticket: CallTicket, result: Result<Response, PublicRequestError> }
    struct Flight { id: Option<serde_json::Value>, ticket: Option<CallTicket>, bytes: Vec<u8> }
    struct State {
        session: Session,
        closed: bool,
        failure: Option<HostError>,
        authenticated: bool,
        reader: Option<JoinHandle<()>>,
        reader_started: bool,
        bootstrap: Option<InputReceipt>,
        input: Option<InputReceipt>,
        work: Option<Work>,
        pending_call: Option<(CallTicket, Request)>,
        active_cancel: Option<(CallTicket, PublicCancellation)>,
        outcome: Option<Outcome>,
        flight: Option<Flight>,
        writer_claimed: bool,
        query_failure: Option<Box<QueryLease>>,
        #[cfg(debug_assertions)]
        observations: Observations,
    }
    struct Shared {
        state: Mutex<State>, changed: Condvar, stop: Handle, startup: PublicCancellation,
        #[cfg(debug_assertions)]
        gates: RuntimeGates,
    }
    fn lock(shared: &Shared) -> MutexGuard<'_, State> {
        shared.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
    fn close(shared: &Shared, state: &mut State, error: Option<HostError>) {
        if state.closed { return; }
        state.closed = true;
        if state.failure.is_none() { state.failure = error; }
        state.session.close();
        state.work = None;
        state.pending_call = None;
        state.bootstrap = None;
        state.input = None;
        shared.startup.cancel();
        if let Some((_, cancellation)) = &state.active_cancel { cancellation.cancel(); }
        unsafe { SetEvent(shared.stop.0); }
        #[cfg(debug_assertions)]
        shared.gates.stop();
        shared.changed.notify_all();
    }
    fn fail(shared: &Shared, error: Option<HostError>) { close(shared, &mut lock(shared), error); }

    fn apply_input_receipt(shared: &Shared, state: &mut State, receipt: InputReceipt) -> Result<(), HostError> {
        let effect = state.session.on_admitted_receipt(receipt.input, receipt.state);
        match effect {
            Effect::Reply(bytes) => state.flight = Some(Flight { id: receipt.id, ticket: None, bytes }),
            Effect::StartCall { request, .. } => {
                let ticket = state.session.active_ticket().expect("validated call");
                let cancel = PublicCancellation::new()?;
                state.active_cancel = Some((ticket.clone(), cancel));
                // Claim remains deferred until all already deposited input is judged.
                state.pending_call = Some((ticket, request));
            }
            Effect::CancelHost => {
                state.work = None;
                state.pending_call = None;
                if let Some((_, cancel)) = &state.active_cancel {
                    cancel.cancel();
                    #[cfg(debug_assertions)]
                    { state.observations.control_cancel_signals += 1; }
                }
            }
            Effect::Close { .. } => close(shared, state, Some(HostError::Protocol)),
            _ => (),
        }
        Ok(())
    }

    struct NativeReader { input: AdmittedInput, shared: Arc<Shared>, completion: Handle }
    fn input_failure_fence(shared: &Shared) -> ! {
        fail(shared, Some(HostError::Transport));
        let mut state = lock(shared);
        loop {
            // This thread retains its live native buffer/OVERLAPPED/handle.
            // An ambiguous completion cannot be turned into Drop or a successful exit.
            state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
        }
    }
    fn completed_read_error(shared: &Shared, error: u32) -> io::Result<usize> {
        match error {
            ERROR_BROKEN_PIPE | ERROR_OPERATION_ABORTED => read_error(error),
            _ => input_failure_fence(shared),
        }
    }
    impl Read for NativeReader {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            loop {
                if lock(&self.shared).closed { return Err(io::ErrorKind::Interrupted.into()); }
                if !pipe_metadata(self.input.handle.0) { return Err(io::ErrorKind::InvalidData.into()); }
                #[cfg(debug_assertions)]
                gate(&self.shared, GatePoint::BeforeRead);
                let mut count = 0;
                let mut overlapped: OVERLAPPED = unsafe { zeroed() };
                overlapped.hEvent = self.completion.0;
                let asynchronous = self.input.mode == InputMode::Overlapped;
                if asynchronous && unsafe {ResetEvent(self.completion.0)}==0 {
                    return Err(io::ErrorKind::Other.into());
                }
                #[cfg(debug_assertions)]
                observe(&self.shared, |o| if asynchronous { o.overlapped_reads += 1; } else { o.synchronous_reads += 1; });
                let started = unsafe { ReadFile(self.input.handle.0, bytes.as_mut_ptr(), bytes.len() as u32,
                    if asynchronous { null_mut() } else { &mut count },
                    if asynchronous { &mut overlapped } else { null_mut() }) };
                let start_error = if started == 0 { unsafe { GetLastError() } } else { 0 };
                if asynchronous && (started != 0 || start_error == ERROR_IO_PENDING) {
                    let mut pending = started == 0;
                    if started != 0 && unsafe { GetOverlappedResult(self.input.handle.0, &overlapped, &mut count, 0) } == 0 {
                        let error = unsafe { GetLastError() };
                        if error == ERROR_IO_INCOMPLETE { pending = true; }
                        else { return completed_read_error(&self.shared, error); }
                    }
                    if pending {
                        let stopped = lock(&self.shared).closed;
                        let handles = [self.completion.0, self.shared.stop.0];
                        let waited = if stopped { WAIT_OBJECT_0 + 1 } else {
                            unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) }
                        };
                        if waited != WAIT_OBJECT_0 || lock(&self.shared).closed {
                            unsafe { CancelIoEx(self.input.handle.0, &overlapped); }
                            #[cfg(debug_assertions)]
                            observe(&self.shared, |o| o.async_drains += 1);
                        }
                        if unsafe { GetOverlappedResult(self.input.handle.0, &overlapped, &mut count, 1) } == 0 {
                            return completed_read_error(&self.shared, unsafe { GetLastError() });
                        }
                        if waited != WAIT_OBJECT_0 && waited != WAIT_OBJECT_0 + 1 {
                            return Err(io::ErrorKind::Other.into());
                        }
                    }
                } else if started == 0 {
                    if !asynchronous && start_error == ERROR_IO_PENDING { input_failure_fence(&self.shared); }
                    return read_error(start_error);
                }
                #[cfg(debug_assertions)]
                observe(&self.shared,|o|{o.read_completions+=1;o.completed_read_bytes+=u64::from(count);o.first_read_bytes.get_or_insert(count);});
                #[cfg(debug_assertions)]
                gate(&self.shared, GatePoint::ReadComplete);
                if lock(&self.shared).closed { return Err(io::ErrorKind::Interrupted.into()); }
                if !pipe_metadata(self.input.handle.0) { return Err(io::ErrorKind::InvalidData.into()); }
                if count != 0 { return Ok(count as usize); }
                // A successful zero-byte pipe read is not EOF.
            }
        }
    }
    fn read_error(error: u32) -> io::Result<usize> {
        match error {
            ERROR_BROKEN_PIPE => Ok(0),
            ERROR_OPERATION_ABORTED => Err(io::ErrorKind::Interrupted.into()),
            _ => Err(io::ErrorKind::Other.into()),
        }
    }

    fn reader(input: AdmittedInput, shared: Arc<Shared>) {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<(), stdio::LineError> {
            { let mut state = lock(&shared); state.reader_started = true;
                #[cfg(debug_assertions)]
                { state.observations.readers_started += 1; }
                shared.changed.notify_all(); }
            let completion = Handle::event().map_err(|_| stdio::LineError::Io)?;
            let mut source = BufReader::new(NativeReader { input, shared: shared.clone(), completion });
            loop {
                let line = match stdio::read_line(&mut source)? { Some(line) => line, None => {
                    #[cfg(debug_assertions)]
                    observe(&shared, |o| o.eof_observed = true);
                    fail(&shared, None); return Ok(());
                } };
                let input = admit_input(&line);
                let id = input.id();
                let notification = input.is_notification();
                #[cfg(debug_assertions)]
                gate(&shared, GatePoint::BeforeDeposit);
                let mut state = lock(&shared);
                let duplicate = |state:&State| id.as_ref().is_some_and(|id| {
                    state.session.active_id()==Some(id)
                        ||state.flight.as_ref().and_then(|f|f.id.as_ref())==Some(id)
                        ||state.bootstrap.as_ref().and_then(|r|r.id.as_ref())==Some(id)
                        ||state.input.as_ref().and_then(|r|r.id.as_ref())==Some(id)
                });
                if duplicate(&state) {close(&shared,&mut state,Some(HostError::Protocol));return Ok(());}
                while state.input.is_some() && !state.closed {
                    state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                }
                if state.closed { return Ok(()); }
                if duplicate(&state) { close(&shared, &mut state, Some(HostError::Protocol)); return Ok(()); }
                let receipt = InputReceipt { input, state: state.session.receipt_state(), id };
                if !state.authenticated && notification { continue; }
                #[cfg(debug_assertions)]
                { state.observations.receipts += 1; }
                if !state.authenticated && state.bootstrap.is_none() {
                    #[cfg(debug_assertions)]
                    { state.observations.bootstrap_receipts += 1; }
                    state.bootstrap = Some(receipt);
                }
                else { state.input = Some(receipt); }
                #[cfg(debug_assertions)]
                shared.gates.receipt();
                shared.changed.notify_all();
            }
        }));
        match result {
            Ok(Ok(())) => (),
            Ok(Err(error)) if !lock(&shared).closed => fail(&shared, Some(if error == stdio::LineError::Io { HostError::Transport } else { HostError::Protocol })),
            Err(_) => fail(&shared, Some(HostError::Transport)),
            _ => (),
        }
        #[cfg(debug_assertions)]
        observe(&shared, |o| o.reader_exited += 1);
    }

    // The result and its diagnostic belong to the same call ticket. A completed
    // cancellation has already settled Unknown/no-response; its later drained
    // worker result cannot change the session or process terminal outcome.
    fn apply_outcome(session:&mut Session,outcome:Outcome)->Option<HostError> {
        if !session.accepts_outcome(&outcome.ticket) {return None;}
        match outcome.result {
            Ok(response)=>{session.complete_ticket(&outcome.ticket,&response);None}
            Err(PublicRequestError::ProtocolFailed)=>{session.protocol_failed_ticket(&outcome.ticket);None}
            Err(PublicRequestError::TransportUncertain(_))=>{session.transport_lost_ticket(&outcome.ticket);Some(HostError::Transport)}
        }
    }
    fn worker(discovery: Discovery, shared: Arc<Shared>) {
        let input = match admit(&shared) {
            Ok(input) => input,
            Err(AdmissionFailure::Rejected) => { fail(&shared, Some(HostError::Startup)); return; }
            Err(AdmissionFailure::Pending(lease)) => {
                let mut state = lock(&shared);
                state.query_failure = Some(lease);
                close(&shared, &mut state, Some(HostError::Startup));
                return;
            }
        };
        #[cfg(debug_assertions)]
        gate(&shared, GatePoint::BeforeReaderSpawn);
        if lock(&shared).closed { return; }
        let reader_shared = shared.clone();
        let reader_thread = match thread::Builder::new().name("mcp-input".into()).spawn(move || reader(input, reader_shared)) {
            Ok(reader) => reader,
            Err(_) => { fail(&shared, Some(HostError::Startup)); return; }
        };
        {
            let mut state = lock(&shared);
            state.reader = Some(reader_thread);
            while !state.reader_started && !state.closed {
                state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
            }
            if state.closed { return; }
        }
        #[cfg(debug_assertions)]
        { gate(&shared, GatePoint::ReaderRegistered); gate(&shared, GatePoint::BeforeAuth); }
        if lock(&shared).closed { return; }
        #[cfg(debug_assertions)]
        observe(&shared, |o| o.auth_attempts += 1);
        let mut client = match PublicClient::connect(&discovery, &shared.startup) {
            Ok(client) => client,
            Err(error) => { if !lock(&shared).closed { fail(&shared, Some(error)); } return; }
        };
        #[cfg(debug_assertions)]
        { observe(&shared, |o| o.auth_completed += 1); gate(&shared, GatePoint::Authenticated); }
        {
            let mut state = lock(&shared);
            if state.closed { return; }
            state.authenticated = true;
            shared.changed.notify_all();
        }
        loop {
            let work = {
                let mut state = lock(&shared);
                while state.work.is_none() && !state.closed {
                    state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                }
                if state.closed { return; }
                state.work.take().expect("work ready")
            };
            #[cfg(debug_assertions)]
            observe(&shared, |o| o.ordinary_attempts += 1);
            let result = client.request(&work.request, &work.cancel);
            let mut state = lock(&shared);
            if state.closed { return; }
            state.outcome = Some(Outcome { ticket: work.ticket, result });
            shared.changed.notify_all();
        }
    }

    fn writer(shared: Arc<Shared>) {
        let mut stdout = io::stdout().lock();
        loop {
            let flight = {
                let mut state = lock(&shared);
                while (state.flight.is_none() || state.writer_claimed) && !state.closed {
                    state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
                }
                if state.closed { return; }
                state.writer_claimed = true;
                let flight = state.flight.as_ref().expect("flight ready");
                Flight { id: flight.id.clone(), ticket: flight.ticket.clone(), bytes: flight.bytes.clone() }
            };
            #[cfg(debug_assertions)]
            gate(&shared, GatePoint::BeforeWrite);
            let result = stdout.write_all(&flight.bytes).and_then(|_| stdout.write_all(b"\n")).and_then(|_| stdout.flush());
            #[cfg(debug_assertions)]
            gate(&shared, GatePoint::AfterFlush);
            let mut state = lock(&shared);
            if result.is_err() { close(&shared, &mut state, Some(HostError::Transport)); return; }
            if let Some(ticket) = flight.ticket { state.session.mark_written_ticket(&ticket); }
            state.flight = None;
            state.writer_claimed = false;
            #[cfg(debug_assertions)]
            { state.observations.replies_flushed += 1; }
            shared.changed.notify_all();
        }
    }

    /// Drop follows the same stop/cancel/drain/join path as every fatal input.
    struct LifecycleGuard { shared: Arc<Shared>, worker: Option<JoinHandle<()>>, writer: Option<JoinHandle<()>> }
    impl LifecycleGuard {
        fn finish(&mut self) {
            fail(&self.shared, None);
            if let Some(worker) = self.worker.take() {
                if worker.join().is_err() { lock(&self.shared).failure = Some(HostError::Transport); }
                #[cfg(debug_assertions)]
                observe(&self.shared, |o| o.worker_joined = true);
            }
            let reader = lock(&self.shared).reader.take();
            if let Some(reader) = reader {
                let raw = reader.as_raw_handle();
                loop {
                    let waited = unsafe { WaitForSingleObject(raw, 0) };
                    if waited == WAIT_OBJECT_0 { break; }
                    if waited == WAIT_FAILED {
                        // Keep the owning JoinHandle alive; no successful cleanup is possible.
                        lock(&self.shared).failure = Some(HostError::Transport);
                    }
                    unsafe { CancelSynchronousIo(raw); }
                    #[cfg(debug_assertions)]
                    observe(&self.shared, |o| o.sync_cancel_attempts += 1);
                    thread::yield_now();
                }
                if reader.join().is_err() { lock(&self.shared).failure = Some(HostError::Transport); }
                #[cfg(debug_assertions)]
                observe(&self.shared, |o| o.reader_joined = true);
            }
            if let Some(writer) = self.writer.take() {
                if writer.join().is_err() { lock(&self.shared).failure = Some(HostError::Transport); }
                #[cfg(debug_assertions)]
                observe(&self.shared, |o| o.writer_joined = true);
            }
            let mut state = lock(&self.shared);
            while state.query_failure.is_some() {
                // Failure fence retains lease storage/handle. Never fabricate a completed exit.
                state = self.shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
            }
        }
    }
    impl Drop for LifecycleGuard { fn drop(&mut self) { self.finish(); } }

    pub fn run_stdio(discovery: Discovery) -> Result<(), HostError> {
        #[cfg(debug_assertions)]
        { run_core(discovery, RuntimeGates::default()).0 }
        #[cfg(not(debug_assertions))]
        { run_core(discovery) }
    }

    #[cfg(debug_assertions)]
    fn run_core(discovery: Discovery, gates: RuntimeGates) -> (Result<(), HostError>, Observations) {
        let result = run_inner(discovery, gates);
        match result { Ok((result, observations)) => (result, observations), Err(error) => (Err(error), Observations::default()) }
    }
    #[cfg(not(debug_assertions))]
    fn run_core(discovery: Discovery) -> Result<(), HostError> { run_inner(discovery) }

    #[cfg(debug_assertions)]
    type RunResult = Result<(Result<(), HostError>, Observations), HostError>;
    #[cfg(not(debug_assertions))]
    type RunResult = Result<(), HostError>;
    fn run_inner(discovery: Discovery, #[cfg(debug_assertions)] gates: RuntimeGates) -> RunResult {
        let shared = Arc::new(Shared { state: Mutex::new(State {
            session: Session::new(), closed: false, failure: None, authenticated: false, reader: None, reader_started: false,
            bootstrap: None, input: None, work: None, pending_call: None, active_cancel: None, outcome: None,
            flight: None, writer_claimed: false, query_failure: None,
            #[cfg(debug_assertions)]
            observations: Observations::default(),
        }), changed: Condvar::new(), stop: Handle::event()?, startup: PublicCancellation::new()?,
            #[cfg(debug_assertions)] gates });
        let mut guard = LifecycleGuard { shared: shared.clone(), worker: None, writer: None };
        let writer_shared = shared.clone();
        guard.writer = Some(thread::Builder::new().name("mcp-output".into()).spawn(move || {
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| writer(writer_shared.clone()))).is_err() {
                fail(&writer_shared, Some(HostError::Transport));
            }
        }).map_err(|_| HostError::Startup)?);
        let worker_shared = shared.clone();
        guard.worker = Some(thread::Builder::new().name("mcp-public".into()).spawn(move || {
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| worker(discovery, worker_shared.clone()))).is_err() {
                fail(&worker_shared, Some(HostError::Transport));
            }
            #[cfg(debug_assertions)]
            observe(&worker_shared, |o| o.worker_exited += 1);
        }).map_err(|_| HostError::Startup)?);
        {
            let mut state = lock(&shared);
            loop {
                if state.closed { break; }
                if state.authenticated && state.flight.is_none() {
                    if let Some(receipt) = state.bootstrap.take().or_else(|| state.input.take()) {
                        apply_input_receipt(&shared, &mut state, receipt)?;
                        shared.changed.notify_all();
                        continue;
                    }
                    #[cfg(debug_assertions)]
                    if state.pending_call.is_some() {
                        drop(state); gate(&shared, GatePoint::BeforeSend); state = lock(&shared);
                        if state.closed || state.input.is_some() { continue; }
                    }
                    if let Some((ticket, request)) = state.pending_call.take() {
                        if state.session.begin_send_ticket(&ticket) {
                            state.work = Some(Work { ticket, request, cancel: state.active_cancel.as_ref().expect("registered").1.clone() });
                        }
                        shared.changed.notify_all();
                    }
                    if let Some(outcome) = state.outcome.take() {
                        if let Some(failure)=apply_outcome(&mut state.session,outcome) {state.failure=Some(failure);}
                    }
                    if let Some(ticket) = state.session.active_ticket() {
                        #[cfg(debug_assertions)]
                        if state.session.pending_reply().is_some() {
                            drop(state); gate(&shared, GatePoint::BeforePublish); state = lock(&shared);
                            if state.closed || state.input.is_some() { continue; }
                        }
                        if let Some(bytes) = state.session.claim_reply(&ticket) {
                            state.flight = Some(Flight { id: state.session.active_id().cloned(), ticket: Some(ticket), bytes });
                            shared.changed.notify_all();
                            continue;
                        }
                    }
                }
                state = shared.changed.wait(state).unwrap_or_else(|p| p.into_inner());
            }
        }
        guard.finish();
        let failure = lock(&shared).failure;
        #[cfg(debug_assertions)]
        { let observations = lock(&shared).observations.clone(); Ok((failure.map_or(Ok(()), Err), observations)) }
        #[cfg(not(debug_assertions))]
        { failure.map_or(Ok(()), Err) }
    }

    #[cfg(test)]
    mod admission_tests {
        use super::*;
        fn started_call()->(Session,CallTicket) {
            let mut session=Session::new();
            session.on_line(br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#);
            session.on_line(br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#);
            assert!(matches!(session.on_line(br#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"project.list","params":{}}}}"#),Effect::StartCall{..}));
            let ticket=session.active_ticket().unwrap();(session,ticket)
        }
        fn sample_outcome(ticket:CallTicket,kind:u8)->Outcome {
            let result=match kind {
                0|1=>{
                    let request=winsmux_workspace::contract::parse_request(br#"{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"project.list","params":{}}"#).unwrap();
                    let body=serde_json::json!({"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","accepted":kind==0,"topology_revision":0,"event_seq":0,
                        "result":if kind==0{serde_json::json!({"operation":"project.list","data":{"projects":[],"selected_project_id":null}})}else{serde_json::Value::Null},
                        "error":if kind==1{serde_json::to_value(winsmux_workspace::contract::ErrorCode::PermissionDenied.with_target(None).unwrap()).unwrap()}else{serde_json::Value::Null}});
                    Ok(winsmux_workspace::contract::parse_response(&request,&serde_json::to_vec(&body).unwrap()).unwrap())
                }
                2=>Err(PublicRequestError::ProtocolFailed),
                3=>Err(PublicRequestError::TransportUncertain(HostError::Cancelled)),
                4=>Err(PublicRequestError::TransportUncertain(HostError::Transport)),
                5=>Err(PublicRequestError::TransportUncertain(HostError::Protocol)),
                _=>unreachable!(),
            };Outcome{ticket,result}
        }
        #[cfg(debug_assertions)]
        #[derive(Debug, PartialEq)]
        struct InputVector {
            session: String, active: Option<CallTicket>, pending: Option<(CallTicket,Vec<u8>)>,
            work: Option<(CallTicket,Vec<u8>)>, active_cancel: Option<CallTicket>, outcome: Option<(CallTicket,String)>,
            flight: Option<(Option<serde_json::Value>,Option<CallTicket>,Vec<u8>)>, failure: Option<HostError>,
            closed: bool, authenticated: bool, writer_claimed: bool, cancel_signals: u64,
        }
        #[cfg(debug_assertions)]
        fn input_vector(state:&State)->InputVector {
            InputVector {
                session:format!("{:?}",state.session),active:state.session.active_ticket(),
                pending:state.pending_call.as_ref().map(|(ticket,request)|(ticket.clone(),winsmux_workspace::contract::canonical_request(request).unwrap())),
                work:state.work.as_ref().map(|work|(work.ticket.clone(),winsmux_workspace::contract::canonical_request(&work.request).unwrap())),
                active_cancel:state.active_cancel.as_ref().map(|(ticket,_)|ticket.clone()),
                outcome:state.outcome.as_ref().map(|outcome|(outcome.ticket.clone(),format!("{:?}",outcome.result))),
                flight:state.flight.as_ref().map(|flight|(flight.id.clone(),flight.ticket.clone(),flight.bytes.clone())),
                failure:state.failure,closed:state.closed,authenticated:state.authenticated,writer_claimed:state.writer_claimed,
                cancel_signals:state.observations.control_cancel_signals,
            }
        }
        #[cfg(debug_assertions)]
        fn protected_input_state(stage:usize)->State {
            let (mut session,ticket)=started_call();
            if stage>=1 {assert!(session.begin_send_ticket(&ticket));}
            if stage>=2 {assert_eq!(apply_outcome(&mut session,sample_outcome(ticket.clone(),0)),None);}
            let flight=if stage==3 {Some(Flight{id:Some(serde_json::json!(8)),ticket:Some(ticket.clone()),bytes:session.claim_reply(&ticket).unwrap()})}else{None};
            let request=||winsmux_workspace::contract::parse_request(br#"{"schema_version":1,"instance_id":"10000000-0000-4000-8000-000000000000","operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":null,"operation":"project.list","params":{}}"#).unwrap();
            let cancel=PublicCancellation::new().unwrap();
            State{session,closed:false,failure:None,authenticated:true,reader:None,reader_started:true,bootstrap:None,input:None,
                work:if stage==1{Some(Work{ticket:ticket.clone(),request:request(),cancel:cancel.clone()})}else{None},
                pending_call:if stage==0{Some((ticket.clone(),request()))}else{None},active_cancel:Some((ticket.clone(),cancel)),
                outcome:if stage==1{Some(sample_outcome(ticket.clone(),0))}else{None},flight,writer_claimed:stage==3,query_failure:None,
                observations:Observations::default()}
        }
        #[cfg(debug_assertions)]
        #[test]
        fn cancellation_admission_preserves_runtime_work_signal_result_and_flight() {
            let shared=Shared{state:Mutex::new(protected_input_state(0)),changed:Condvar::new(),stop:Handle::event().unwrap(),
                startup:PublicCancellation::new().unwrap(),gates:RuntimeGates::default()};
            let mut inputs=crate::notification_admission_tests::malformed();
            inputs.extend([br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#.to_vec(),
                br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"unknown"}}"#.to_vec()]);
            for stage in 0..4 {for raw in &inputs {for origin in 0..3 {
                let mut state=protected_input_state(stage);
                let receipt=match origin {0=>state.session.receipt_state(),1=>protected_input_state(1).session.receipt_state(),
                    2=>protected_input_state(3).session.receipt_state(),_=>unreachable!()};
                let before=input_vector(&state);let input=admit_input(raw);assert!(input.is_notification());assert!(input.id().is_none());
                apply_input_receipt(&shared,&mut state,InputReceipt{input,state:receipt,id:None}).unwrap();
                assert_eq!(input_vector(&state),before,"stage={stage}, origin={origin}");
                if stage==0{assert!(state.session.begin_send_ticket(before.active.as_ref().unwrap()));}
            }}}
            for stage in 0..4 {for raw in crate::notification_admission_tests::legal() {for origin in 0..3 {
                let mut state=protected_input_state(stage);
                let receipt=match origin {0=>state.session.receipt_state(),1=>protected_input_state(1).session.receipt_state(),
                    2=>protected_input_state(3).session.receipt_state(),_=>unreachable!()};
                let before=input_vector(&state);let input=admit_input(&raw);
                apply_input_receipt(&shared,&mut state,InputReceipt{input,state:receipt,id:None}).unwrap();
                if origin!=0||stage==3 {assert_eq!(input_vector(&state),before);}else{
                    assert!(state.session.active_ticket().is_none());assert!(state.session.pending_reply().is_none());
                    assert_eq!(state.session.connection_unknown(),stage!=0);
                    assert_eq!(state.observations.control_cancel_signals,u64::from(stage!=0));
                    if stage!=0{assert!(state.work.is_none());assert!(state.pending_call.is_none());}
                    assert_eq!(state.failure,None);assert!(state.flight.is_none());
                }
            }}}
            eprintln!("notification runtime property: malformed30+unknown2 x phases4 x current/stale/publishing-receipt3=384; legal5 x phases4 x receipt3=60; pending/work/cancel/result/flight/diagnostic exact");
        }
        #[test]
        fn outcome_diagnostic_and_session_obey_the_same_ticket() {
            // 6 real result classes x all legal ownership/phase/close classes.
            for kind in 0..6 {for stage in 0..9 {for stale in [false,true] {
                let (mut session,ticket)=started_call();
                if matches!(stage,1|2|3|4|6|7|8){assert!(session.begin_send_ticket(&ticket));}
                if matches!(stage,2|3|4|8){assert_eq!(apply_outcome(&mut session,sample_outcome(ticket.clone(),0)),None);}
                if matches!(stage,3|4){assert!(session.claim_reply(&ticket).is_some());}
                if stage==4{assert!(session.mark_written_ticket(&ticket));}
                if matches!(stage,5|6){session.on_line(br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8}}"#);}
                if matches!(stage,7|8){session.close();}
                let delivered=if stale{started_call().1}else{ticket.clone()};
                let before=format!("{session:?}");let before_ticket=session.active_ticket();let before_unknown=session.connection_unknown();
                let diagnostic=apply_outcome(&mut session,sample_outcome(delivered,kind));
                if stage==1&&!stale {
                    assert_eq!(diagnostic,if kind>=3{Some(HostError::Transport)}else{None});
                    assert_eq!(session.connection_unknown(),kind>=3);assert!(session.pending_reply().is_some());
                    let reply:serde_json::Value=serde_json::from_slice(session.pending_reply().unwrap()).unwrap();assert_eq!(reply["id"],8);
                    if kind>=2{assert_eq!(reply["error"]["code"],-32603);}else{assert_eq!(reply["result"]["structuredContent"]["accepted"],kind==0);}
                }else{
                    assert_eq!(diagnostic,None,"stale/phase/close cannot alter terminal diagnostic kind={kind} stage={stage}");
                    assert_eq!(format!("{session:?}"),before);assert_eq!(session.active_ticket(),before_ticket);assert_eq!(session.connection_unknown(),before_unknown);
                }
            }}}
        }
        #[test]
        fn query_completion_and_ownership_class() {
            for kind in ["Access", "Mode"] {
                for status in [STATUS_SUCCESS, STATUS_ACCESS_DENIED, STATUS_INVALID_INFO_CLASS] {
                    for bytes in [0,3,4,5] {
                        let expected = if status == STATUS_SUCCESS && bytes == 4 { QueryDecision::Complete } else { QueryDecision::Rejected };
                        assert_eq!(query_decision(status,None,STATUS_PENDING,bytes),expected,"{kind} immediate");
                        assert_eq!(query_decision(STATUS_PENDING,Some(WAIT_OBJECT_0),status,bytes),expected,"{kind} completed");
                        for wait in [WAIT_FAILED,WAIT_TIMEOUT,WAIT_OBJECT_0+1] {
                            assert_eq!(query_decision(STATUS_PENDING,Some(wait),status,bytes),QueryDecision::RetainPending,"{kind} owned fence");
                        }
                    }
                }
                assert_eq!(query_decision(STATUS_PENDING,Some(WAIT_OBJECT_0),STATUS_PENDING,4),QueryDecision::RetainPending,"{kind} still pending");
            }
        }
        #[test]
        fn actual_read_right_and_io_mode_are_independent() {
            for access in [0,2,128,2|128,0x00100000,0x00120116] { assert!(!read_granted(access)); }
            for access in [1,1|128,0x00120189,0x001a019f] { assert!(read_granted(access)); }
            assert_eq!(input_mode(0),Some(InputMode::Overlapped));
            assert_eq!(input_mode(FILE_SYNCHRONOUS_IO_ALERT),Some(InputMode::Synchronous));
            assert_eq!(input_mode(FILE_SYNCHRONOUS_IO_NONALERT),Some(InputMode::Synchronous));
            assert_eq!(input_mode(FILE_SYNCHRONOUS_IO_ALERT|FILE_SYNCHRONOUS_IO_NONALERT),None);
        }
    }
}
