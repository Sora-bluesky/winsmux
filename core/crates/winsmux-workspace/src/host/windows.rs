use super::admission::{
    AllocationPool, ChargedValue, ChargedVec, ConnectionSupervisor, ConnectionSupervisorError,
    OwnedFrame,
};
#[cfg(debug_assertions)]
use super::io::write_public_frame;
use super::io::{
    connect_overlapped, connect_overlapped_with_wake, decode_length, read_exact, read_frame,
    read_frame_owned, write_frame, CancelEvent, IoError, OwnedHandle,
};
use super::process::{spawn_host, spawn_host_at, ChildProcess};
use super::security::{
    verify_pipe_peer_charged, Identity, SecurityDescriptor, SecurityMode, ServerCapabilityToken,
};
use super::server_identity::{
    encode_request, parse_request as parse_auth_request, random_challenge, verify_response,
    ServerKey, AUTH_REQUEST_BYTES,
};
use super::{Discovery, HostError};
use crate::auth::{AuthenticationIoPermit, Authorization, ProofSendPermit};
use crate::client::{artifact_request_admitted, drive_requests, map_io, ConsoleSession};
use crate::contract::ingress::{prepare_request, HostCodecError};
use crate::contract::{
    canonical_request, parse_response, NonEmpty, ProjectId, Request, Response, MAX_MESSAGE_BYTES,
};
use std::io::{IsTerminal, Write};
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr::null_mut;
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;
use windows_sys::Win32::Foundation::{
    GetHandleInformation, SetHandleInformation, GENERIC_READ, GENERIC_WRITE, HANDLE,
    HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileType, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, FILE_TYPE_PIPE,
    OPEN_EXISTING, PIPE_ACCESS_DUPLEX, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Pipes::{
    CreateNamedPipeW, GetNamedPipeClientProcessId, GetNamedPipeInfo, GetNamedPipeServerProcessId,
    PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
    PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CreateMutexExW, GetCurrentProcessId, ReleaseMutex, WaitForSingleObject, MUTEX_MODIFY_STATE,
};

struct HostMutex {
    handle: OwnedHandle,
}

#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
mod stop_reply_loss {
    use super::*;
    use windows_sys::Win32::Foundation::DuplicateHandle;
    use windows_sys::Win32::System::Threading::{
        CreateEventW, GetCurrentProcess, GetProcessId, ResetEvent, SetEvent,
        WaitForMultipleObjects, INFINITE, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    const SYNCHRONIZE: u32 = 0x00100000;

    struct Events {
        ready: OwnedHandle,
        discard: OwnedHandle,
        parent: OwnedHandle,
    }

    /// Rust-only debug fixture. No public request can enable this checkpoint.
    pub struct StopReplyLossGate(Arc<Events>);

    pub struct StopReplyLossRelease(Arc<Events>);

    impl StopReplyLossRelease {
        pub fn signal(&self) {
            unsafe {
                SetEvent(self.0.discard.raw());
            }
        }
    }
    impl Drop for StopReplyLossRelease {
        fn drop(&mut self) {
            self.signal();
        }
    }
    impl Drop for StopReplyLossGate {
        fn drop(&mut self) {
            unsafe {
                SetEvent(self.0.discard.raw());
            }
        }
    }
    impl StopReplyLossGate {
        pub fn new() -> Result<Self, HostError> {
            Self::create_with(|| unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) })
        }
        fn create_with(mut create_event: impl FnMut() -> HANDLE) -> Result<Self, HostError> {
            let ready = unsafe { OwnedHandle::from_raw(create_event()) }.map_err(map_io)?;
            let discard = unsafe { OwnedHandle::from_raw(create_event()) }.map_err(map_io)?;
            let mut parent = null_mut();
            if unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    GetCurrentProcess(),
                    GetCurrentProcess(),
                    &mut parent,
                    SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                    0,
                    0,
                )
            } == 0
            {
                return Err(HostError::Startup);
            }
            Ok(Self(Arc::new(Events {
                ready,
                discard,
                parent: unsafe { OwnedHandle::from_raw(parent) }.map_err(map_io)?,
            })))
        }
        pub fn ready(&self) -> bool {
            unsafe { WaitForSingleObject(self.0.ready.raw(), 0) == WAIT_OBJECT_0 }
        }
        pub fn release_on_drop(&self) -> StopReplyLossRelease {
            StopReplyLossRelease(self.0.clone())
        }
        pub(super) fn handles(&self, owner: HANDLE) -> [HANDLE; 4] {
            [
                owner,
                self.0.ready.raw(),
                self.0.discard.raw(),
                self.0.parent.raw(),
            ]
        }
    }

    pub(super) struct ChildGate {
        ready: OwnedHandle,
        discard: OwnedHandle,
        parent: OwnedHandle,
    }
    impl ChildGate {
        pub(super) fn parse(owner: HANDLE, arguments: [&str; 3]) -> Result<Self, HostError> {
            let handles = arguments
                .map(|value| usize::from_str_radix(value, 16).map(|value| value as HANDLE));
            let [Ok(ready), Ok(discard), Ok(parent)] = handles else {
                return Err(HostError::Startup);
            };
            if ready == discard
                || ready == parent
                || discard == parent
                || [ready, discard, parent].contains(&owner)
            {
                return Err(HostError::Startup);
            }
            let mut server_pid = 0;
            if unsafe { GetNamedPipeServerProcessId(owner, &mut server_pid) } == 0
                || server_pid == 0
                || unsafe { GetProcessId(parent) } != server_pid
            {
                return Err(HostError::Startup);
            }
            for handle in [ready, discard, parent] {
                let mut flags = 0;
                if handle.is_null()
                    || handle == INVALID_HANDLE_VALUE
                    || unsafe { GetHandleInformation(handle, &mut flags) } == 0
                    || flags & HANDLE_FLAG_INHERIT == 0
                {
                    return Err(HostError::Startup);
                }
            }
            for event in [ready, discard] {
                if unsafe { WaitForSingleObject(event, 0) } != WAIT_TIMEOUT
                    || unsafe { ResetEvent(event) } == 0
                {
                    return Err(HostError::Startup);
                }
            }
            for handle in [ready, discard, parent] {
                if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) } == 0 {
                    return Err(HostError::Startup);
                }
            }
            Ok(Self {
                ready: unsafe { OwnedHandle::from_raw(ready) }.map_err(map_io)?,
                discard: unsafe { OwnedHandle::from_raw(discard) }.map_err(map_io)?,
                parent: unsafe { OwnedHandle::from_raw(parent) }.map_err(map_io)?,
            })
        }
        pub(super) fn discard_reply(&self) -> Result<(), IoError> {
            if unsafe { SetEvent(self.ready.raw()) } == 0 {
                return Err(IoError::Failed);
            }
            let waits = [self.discard.raw(), self.parent.raw()];
            match unsafe { WaitForMultipleObjects(2, waits.as_ptr(), 0, INFINITE) } {
                value if value == WAIT_OBJECT_0 || value == WAIT_OBJECT_0 + 1 => Ok(()),
                _ => Err(IoError::Failed),
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use windows_sys::Win32::System::Threading::{GetProcessHandleCount, OpenProcess};
        fn count() -> u32 {
            let mut value = 0;
            assert_ne!(
                unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut value) },
                0
            );
            value
        }
        fn executable() -> std::path::PathBuf {
            std::env::var_os("TASK870_TEST_CLI")
                .expect("feature CLI fixture")
                .into()
        }
        fn closed(handles: &[HANDLE]) {
            for handle in handles {
                let mut flags = 0;
                assert_eq!(
                    unsafe { GetHandleInformation(*handle, &mut flags) },
                    0,
                    "fixture-owned handle remains open"
                );
            }
        }

        #[test]
        fn stop_reply_gate_create_failure_closes_prior_event() {
            let mut first = null_mut();
            let mut count = 0;
            let result = StopReplyLossGate::create_with(|| {
                count += 1;
                if count == 1 {
                    first = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
                    first
                } else {
                    null_mut()
                }
            });
            assert!(result.is_err());
            assert!(!first.is_null());
            closed(&[first]);
        }

        #[test]
        fn stop_reply_gate_failed_spawn_and_parent_identity_are_closed() {
            // Initialize Windows security/pipe support before comparing the fixture cohort.
            drop(create_private_channel(&Identity::current().unwrap()).unwrap());
            let before = count();
            let retained;
            {
                let gate = StopReplyLossGate::new().unwrap();
                retained = [
                    gate.0.ready.raw(),
                    gate.0.discard.raw(),
                    gate.0.parent.raw(),
                ];
                assert!(WorkspaceOwner::start_with_stop_reply_loss_gate(
                    Path::new("missing-task870-cli.exe"),
                    &gate
                )
                .is_err());
                for missing_query in [false, true] {
                    let identity = Identity::current().unwrap();
                    let (endpoint, inherited) = create_private_channel(&identity).unwrap();
                    // A queryable different process, or the correct PID without query rights.
                    let process = if missing_query {
                        unsafe {
                            OwnedHandle::from_raw(OpenProcess(
                                SYNCHRONIZE,
                                0,
                                GetCurrentProcessId(),
                            ))
                        }
                        .unwrap()
                    } else {
                        let mut child = std::process::Command::new("cmd.exe")
                            .args(["/c", "pause"])
                            .stdin(std::process::Stdio::piped())
                            .stdout(std::process::Stdio::null())
                            .spawn()
                            .unwrap();
                        let process = unsafe {
                            OwnedHandle::from_raw(OpenProcess(
                                SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                0,
                                child.id(),
                            ))
                        }
                        .unwrap();
                        drop(child.stdin.take());
                        let _ = child.wait();
                        process
                    };
                    let mut handles = gate.handles(inherited.raw());
                    handles[3] = process.raw();
                    let child = super::super::super::process::spawn_stop_reply_loss(
                        &executable(),
                        &handles,
                    )
                    .unwrap();
                    let child_handle = child.raw();
                    drop(inherited);
                    assert!(read_frame(endpoint.raw(), &[]).is_err());
                    drop(endpoint);
                    assert_ne!(child.wait().unwrap(), 0);
                    drop(child);
                    closed(&[child_handle]);
                }
            }
            closed(&retained);
            eprintln!(
                "TASK870_GATE_PROCESS_COUNTS before={before} after={} owned_handles_closed=true",
                count()
            );
        }

        #[test]
        fn stop_reply_gate_ready_abandon_releases_before_owner_collection() {
            use crate::contract::{Action, Empty, Nullable, OperationId, Version};
            let before = count();
            let retained;
            {
                let gate = Arc::new(StopReplyLossGate::new().unwrap());
                retained = [
                    gate.0.ready.raw(),
                    gate.0.discard.raw(),
                    gate.0.parent.raw(),
                ];
                let mut owner =
                    WorkspaceOwner::start_with_stop_reply_loss_gate(&executable(), &gate).unwrap();
                let instance = owner.discovery().instance_id().clone();
                let worker = std::thread::spawn(move || {
                    let child_handle = owner.child.as_ref().unwrap().raw();
                    let owner_handle = owner.endpoint.as_ref().unwrap().raw();
                    for _ in 0..60 {
                        let request = Request {
                            schema_version: Version::new(1).unwrap(),
                            instance_id: Nullable(Some(instance.clone())),
                            operation_id: OperationId::new(uuid::Uuid::new_v4().to_string())
                                .unwrap(),
                            expected_topology_revision: Nullable(None),
                            action: Action::HostStop(Empty {}),
                        };
                        match owner.request(&request) {
                            Err(WorkspaceRequestError::TransportUncertain) => {
                                drop(owner);
                                closed(&[child_handle, owner_handle]);
                                return;
                            }
                            Ok(response) if !response.accepted => {
                                std::thread::sleep(std::time::Duration::from_millis(500))
                            }
                            other => panic!("unexpected stop result: {other:?}"),
                        }
                    }
                    panic!("stop did not become quiescent");
                });
                let release = gate.release_on_drop();
                for _ in 0..300 {
                    if gate.ready() {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                assert!(gate.ready(), "accepted save/stop checkpoint not reached");
                // Intentional validation abandonment while the parent is alive.
                drop(release);
                worker.join().unwrap();
            }
            closed(&retained);
            eprintln!(
                "TASK870_GATE_PROCESS_COUNTS before={before} after={} owned_handles_closed=true",
                count()
            );
        }
    }
}

#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
pub use stop_reply_loss::{StopReplyLossGate, StopReplyLossRelease};

impl Drop for HostMutex {
    fn drop(&mut self) {
        unsafe {
            ReleaseMutex(self.handle.raw());
        }
    }
}

#[cfg(debug_assertions)]
#[derive(Clone, Copy)]
enum LauncherStartupStage {
    Terminal,
    Identity,
    InheritanceProbe,
    Console,
    Channel,
    ChildSpawn,
    StartupFrame,
    ProbeReady,
    DiscoveryFrame,
    DiscoveryParse,
    DiscoveryValidation,
    DiscoverySerialization,
    OutputStarted,
}

#[cfg(debug_assertions)]
impl LauncherStartupStage {
    fn label(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Identity => "identity",
            Self::InheritanceProbe => "inheritance_probe",
            Self::Console => "console",
            Self::Channel => "channel",
            Self::ChildSpawn => "child_spawn",
            Self::StartupFrame => "startup_frame",
            Self::ProbeReady => "probe_ready",
            Self::DiscoveryFrame => "discovery_frame",
            Self::DiscoveryParse => "discovery_parse",
            Self::DiscoveryValidation => "discovery_validation",
            Self::DiscoverySerialization => "discovery_serialization",
            Self::OutputStarted => "output_started",
        }
    }
}

// Reserved only for an opted-in debug __host-child that failed before it
// attempted its first private startup frame. Never encode handles or paths.
#[cfg(debug_assertions)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChildStartupStage {
    Handle,
    Identity,
    Mutex,
    InheritanceProbe,
    Capability,
    ServerKey,
    Authorization,
    CancelEvent,
    Supervisor,
    Discovery,
    PublicPipe,
    AcceptThread,
    DiscoverySerialization,
}

#[cfg(debug_assertions)]
impl ChildStartupStage {
    fn code(self) -> i32 {
        80 + self as i32
    }
    fn from_code(code: u32) -> Option<Self> {
        match code {
            80 => Some(Self::Handle),
            81 => Some(Self::Identity),
            82 => Some(Self::Mutex),
            83 => Some(Self::InheritanceProbe),
            84 => Some(Self::Capability),
            85 => Some(Self::ServerKey),
            86 => Some(Self::Authorization),
            87 => Some(Self::CancelEvent),
            88 => Some(Self::Supervisor),
            89 => Some(Self::Discovery),
            90 => Some(Self::PublicPipe),
            91 => Some(Self::AcceptThread),
            92 => Some(Self::DiscoverySerialization),
            _ => None,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Self::Handle => "handle",
            Self::Identity => "identity",
            Self::Mutex => "mutex",
            Self::InheritanceProbe => "inheritance_probe",
            Self::Capability => "capability",
            Self::ServerKey => "server_key",
            Self::Authorization => "authorization",
            Self::CancelEvent => "cancel_event",
            Self::Supervisor => "supervisor",
            Self::Discovery => "discovery",
            Self::PublicPipe => "public_pipe",
            Self::AcceptThread => "accept_thread",
            Self::DiscoverySerialization => "discovery_serialization",
        }
    }
}

#[cfg(debug_assertions)]
struct ChildStartupTrace {
    stage: std::cell::Cell<ChildStartupStage>,
    frame_attempted: std::cell::Cell<bool>,
}

#[cfg(debug_assertions)]
impl ChildStartupTrace {
    fn new() -> Self {
        Self {
            stage: std::cell::Cell::new(ChildStartupStage::Handle),
            frame_attempted: std::cell::Cell::new(false),
        }
    }
    fn set(&self, stage: ChildStartupStage) {
        self.stage.set(stage);
    }
    fn exit_code(&self, error: HostError) -> i32 {
        if !self.frame_attempted.get() && error != HostError::Cancelled {
            self.stage.get().code()
        } else {
            error.exit_code()
        }
    }
}

#[cfg(debug_assertions)]
fn attempt_first_startup_frame(
    trace: Option<&ChildStartupTrace>,
    write_once: impl FnOnce() -> Result<(), HostError>,
) -> Result<(), HostError> {
    if let Some(trace) = trace {
        trace.frame_attempted.set(true);
    }
    write_once()
}

#[cfg(all(test, debug_assertions))]
mod child_startup_trace_tests {
    use super::*;

    #[test]
    fn reserved_codes_decode_only_known_stages() {
        for code in 80..=92 {
            let stage = ChildStartupStage::from_code(code).expect("reserved stage");
            assert_eq!(stage.code(), code as i32);
        }
        for code in [0, 1, 79, 93, 95, 130, u32::MAX] {
            assert!(ChildStartupStage::from_code(code).is_none());
        }
    }

    #[test]
    fn first_frame_attempt_suppresses_preframe_code_even_on_immediate_or_partial_failure() {
        for written_bytes in [0, 3] {
            let trace = ChildStartupTrace::new();
            trace.set(ChildStartupStage::DiscoverySerialization);
            let result = attempt_first_startup_frame(Some(&trace), || {
                let _simulated_written_bytes = written_bytes;
                Err(HostError::Transport)
            });
            assert_eq!(result, Err(HostError::Transport));
            assert!(trace.frame_attempted.get());
            assert_eq!(trace.exit_code(HostError::Transport), 1);
        }
    }

    #[test]
    fn successful_frame_then_cleanup_failure_does_not_claim_startup_failure() {
        let trace = ChildStartupTrace::new();
        attempt_first_startup_frame(Some(&trace), || Ok(())).expect("first frame");
        let result = finish_host_result(Some(HostError::Transport), false);
        assert_eq!(result, Err(HostError::Transport));
        assert_eq!(trace.exit_code(result.unwrap_err()), 1);
    }

    #[test]
    fn first_error_and_launcher_request_error_keep_priority() {
        let trace = ChildStartupTrace::new();
        trace.set(ChildStartupStage::ServerKey);
        let mut first = Some(HostError::Startup);
        record_first_error(&mut first, HostError::Transport);
        assert_eq!(first, Some(HostError::Startup));
        assert_eq!(
            trace.exit_code(first.unwrap()),
            ChildStartupStage::ServerKey.code()
        );
        assert_eq!(
            combine_launcher_results(
                Err(HostError::Protocol),
                Ok(84),
                LauncherStartupStage::StartupFrame,
                true
            ),
            Err(HostError::Protocol)
        );
        assert_eq!(
            combine_launcher_results(
                Err(HostError::Transport),
                Err(HostError::Startup),
                LauncherStartupStage::StartupFrame,
                true
            ),
            Err(HostError::Transport)
        );
        assert_eq!(
            combine_launcher_results(Ok(()), Ok(84), LauncherStartupStage::StartupFrame, true),
            Err(HostError::Transport)
        );
    }
}

pub fn run_launcher() -> Result<(), HostError> {
    #[cfg(debug_assertions)]
    let startup_stage = std::cell::Cell::new(LauncherStartupStage::Terminal);
    #[cfg(debug_assertions)]
    let result = run_launcher_inner(&startup_stage);
    #[cfg(not(debug_assertions))]
    let result = run_launcher_inner();
    #[cfg(debug_assertions)]
    if std::env::var("WINSMUX_TASK876_STARTUP_TRACE").as_deref() == Ok("1") {
        if let Err(error) = result {
            if !matches!(startup_stage.get(), LauncherStartupStage::OutputStarted) {
                eprintln!(
                    "TASK876_OWNER_STARTUP stage={} class={}",
                    startup_stage.get().label(),
                    error.classification()
                );
            }
        }
    }
    result
}

fn run_launcher_inner(
    #[cfg(debug_assertions)] startup_stage: &std::cell::Cell<LauncherStartupStage>,
) -> Result<(), HostError> {
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        return Err(HostError::InteractiveRequired);
    }

    #[cfg(debug_assertions)]
    startup_stage.set(LauncherStartupStage::Identity);
    let identity = Identity::current().map_err(map_io)?;
    #[cfg(debug_assertions)]
    startup_stage.set(LauncherStartupStage::InheritanceProbe);
    #[cfg(debug_assertions)]
    let launcher_probe = super::testing::LauncherInheritanceProbe::start(&identity)?;
    #[cfg(debug_assertions)]
    startup_stage.set(LauncherStartupStage::Console);
    let session = ConsoleSession::start()?;
    let result = (|| {
        #[cfg(debug_assertions)]
        startup_stage.set(LauncherStartupStage::Channel);
        let (owner_handle, inherited) = create_private_channel(&identity)?;
        #[cfg(debug_assertions)]
        startup_stage.set(LauncherStartupStage::ChildSpawn);
        let child = spawn_host(inherited.raw()).map_err(map_io)?;
        drop(inherited);
        #[cfg(debug_assertions)]
        let launcher_probe_error = launcher_probe
            .as_ref()
            .and_then(|probe| probe.child_spawned().err());
        let mut owner = Some(owner_handle);
        let request_result = (|| {
            #[cfg(debug_assertions)]
            if let Some(error) = launcher_probe_error {
                return Err(error);
            }
            #[cfg(debug_assertions)]
            startup_stage.set(LauncherStartupStage::StartupFrame);
            let startup = read_frame(
                owner.as_ref().expect("owner channel is present").raw(),
                &[session.cancel().raw()],
            )
            .map_err(map_io)?;
            #[cfg(debug_assertions)]
            let startup = match launcher_probe.as_ref() {
                Some(probe) => {
                    startup_stage.set(LauncherStartupStage::ProbeReady);
                    probe.verify_ready(&startup)?;
                    startup_stage.set(LauncherStartupStage::DiscoveryFrame);
                    read_frame(
                        owner.as_ref().expect("owner channel is present").raw(),
                        &[session.cancel().raw()],
                    )
                    .map_err(map_io)?
                }
                None => startup,
            };
            #[cfg(debug_assertions)]
            startup_stage.set(LauncherStartupStage::DiscoveryParse);
            let discovery: Discovery =
                serde_json::from_slice(&startup).map_err(|_| HostError::Protocol)?;
            #[cfg(debug_assertions)]
            startup_stage.set(LauncherStartupStage::DiscoveryValidation);
            let fingerprint = discovery.validate_for(&identity)?;
            #[cfg(debug_assertions)]
            startup_stage.set(LauncherStartupStage::DiscoverySerialization);
            let line = serde_json::to_vec(&discovery).map_err(|_| HostError::Protocol)?;
            let mut stdout = std::io::stdout().lock();
            #[cfg(debug_assertions)]
            startup_stage.set(LauncherStartupStage::OutputStarted);
            stdout
                .write_all(&line)
                .and_then(|_| stdout.write_all(b"\n"))
                .and_then(|_| stdout.flush())
                .map_err(|_| HostError::Transport)?;
            drop(stdout);
            drive_requests(
                owner.take().expect("owner channel is present"),
                session.cancel(),
                Some((&discovery, fingerprint)),
            )
        })();

        // Closing the private endpoint is the owner's shutdown signal. Keep the
        // console session alive until the child has also been collected.
        drop(owner.take());
        let child_result = child.wait().map_err(map_io);
        #[cfg(debug_assertions)]
        let combined = combine_launcher_results(
            request_result,
            child_result,
            startup_stage.get(),
            std::env::var("WINSMUX_TASK876_STARTUP_TRACE").as_deref() == Ok("1"),
        );
        #[cfg(not(debug_assertions))]
        let combined = combine_launcher_results(request_result, child_result);
        combined
    })();
    session.finish(result)
}

fn combine_launcher_results(
    request_result: Result<(), HostError>,
    child_result: Result<u32, HostError>,
    #[cfg(debug_assertions)] startup_stage: LauncherStartupStage,
    #[cfg(debug_assertions)] trace_enabled: bool,
) -> Result<(), HostError> {
    #[cfg(debug_assertions)]
    if trace_enabled
        && request_result == Err(HostError::Transport)
        && matches!(startup_stage, LauncherStartupStage::StartupFrame)
    {
        if let Ok(code) = child_result {
            if let Some(stage) = ChildStartupStage::from_code(code) {
                eprintln!("TASK876_CHILD_STARTUP stage={}", stage.label());
            }
        }
    }
    match request_result {
        Err(error) => Err(error),
        Ok(()) => match child_result {
            Ok(0) => Ok(()),
            Ok(_) => Err(HostError::Transport),
            Err(error) => Err(error),
        },
    }
}

fn wait_child(child: ChildProcess) -> Result<(), HostError> {
    match child.wait().map_err(map_io)? {
        0 => Ok(()),
        _ => Err(HostError::Transport),
    }
}

/// The private owner endpoint and exact child process for one host generation.
/// Dropping it closes only this endpoint and collects only this child.
pub struct WorkspaceOwner {
    endpoint: Option<OwnedHandle>,
    child: Option<ChildProcess>,
    cancel: CancelEvent,
    discovery: Discovery,
    fingerprint: String,
    artifact_review_available: Option<bool>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    stop_reply_release: Option<StopReplyLossRelease>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceRequestError {
    ProtocolFailed,
    TransportUncertain,
}

impl WorkspaceOwner {
    pub fn start(executable: &Path) -> Result<Self, HostError> {
        Self::start_inner(
            executable,
            #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
            None,
        )
    }

    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    pub fn start_with_stop_reply_loss_gate(
        executable: &Path,
        gate: &StopReplyLossGate,
    ) -> Result<Self, HostError> {
        Self::start_inner(executable, Some(gate))
    }

    fn start_inner(
        executable: &Path,
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))] gate: Option<
            &StopReplyLossGate,
        >,
    ) -> Result<Self, HostError> {
        let identity = Identity::current().map_err(map_io)?;
        let cancel = CancelEvent::new().map_err(map_io)?;
        let (endpoint, inherited) = create_private_channel(&identity)?;
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        let stop_reply_release = gate.map(StopReplyLossGate::release_on_drop);
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        let child = match gate {
            Some(gate) => {
                super::process::spawn_stop_reply_loss(executable, &gate.handles(inherited.raw()))
            }
            None => spawn_host_at(inherited.raw(), executable),
        }
        .map_err(map_io)?;
        #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
        let child = spawn_host_at(inherited.raw(), executable).map_err(map_io)?;
        drop(inherited);
        let startup = read_frame(endpoint.raw(), &[cancel.raw()]).map_err(map_io);
        let validated = startup.and_then(|bytes| {
            let discovery: Discovery =
                serde_json::from_slice(&bytes).map_err(|_| HostError::Protocol)?;
            let fingerprint = discovery.validate_for(&identity)?.to_owned();
            Ok((discovery, fingerprint))
        });
        match validated {
            Ok((discovery, fingerprint)) => Ok(Self {
                endpoint: Some(endpoint),
                child: Some(child),
                cancel,
                discovery,
                fingerprint,
                artifact_review_available: None,
                #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
                stop_reply_release,
            }),
            Err(error) => {
                #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
                drop(stop_reply_release);
                drop(endpoint);
                let _ = wait_child(child);
                Err(error)
            }
        }
    }

    /// This value is validated against the current Windows identity at startup.
    pub fn discovery(&self) -> &Discovery {
        &self.discovery
    }

    pub fn request(&mut self, request: &Request) -> Result<Response, WorkspaceRequestError> {
        if request.instance_id.0.as_ref() != Some(&self.discovery.instance_id) {
            return Err(WorkspaceRequestError::ProtocolFailed);
        }
        if !artifact_request_admitted(
            request,
            Some((&self.discovery, &self.fingerprint)),
            &self.cancel,
            &mut self.artifact_review_available,
        ) {
            return Err(WorkspaceRequestError::ProtocolFailed);
        }
        let payload =
            canonical_request(request).map_err(|_| WorkspaceRequestError::ProtocolFailed)?;
        let endpoint = self
            .endpoint
            .as_ref()
            .ok_or(WorkspaceRequestError::TransportUncertain)?;
        write_frame(endpoint.raw(), &payload, &[self.cancel.raw()])
            .map_err(|_| WorkspaceRequestError::TransportUncertain)?;
        let response = read_frame(endpoint.raw(), &[self.cancel.raw()])
            .map_err(|_| WorkspaceRequestError::TransportUncertain)?;
        parse_response(request, &response).map_err(|_| WorkspaceRequestError::TransportUncertain)
    }

    pub fn collect(&mut self) -> Result<(), HostError> {
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        drop(self.stop_reply_release.take());
        drop(self.endpoint.take());
        match self.child.as_ref() {
            Some(child) => match child.wait().map_err(map_io)? {
                0 => {
                    drop(self.child.take());
                    Ok(())
                }
                _ => Err(HostError::Transport),
            },
            None => Err(HostError::Transport),
        }
    }

    /// Explicit unknown-state collection. Endpoint closure is not a save claim.
    /// Retain the child handle when exit cannot be observed; Drop is only fallback.
    pub fn force_collect(&mut self) -> Result<(), HostError> {
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        drop(self.stop_reply_release.take());
        drop(self.endpoint.take());
        let child = self.child.as_ref().ok_or(HostError::Transport)?;
        child.wait().map_err(map_io)?;
        drop(self.child.take());
        Ok(())
    }
}

impl Drop for WorkspaceOwner {
    fn drop(&mut self) {
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        drop(self.stop_reply_release.take());
        drop(self.endpoint.take());
        if let Some(child) = self.child.take() {
            let _ = wait_child(child);
        }
    }
}

pub fn run_child(argument: &str) -> Result<(), HostError> {
    run_child_inner(
        argument,
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        None,
        #[cfg(debug_assertions)]
        None,
    )
}

pub(crate) fn run_child_cli(argument: &str) -> i32 {
    #[cfg(debug_assertions)]
    if std::env::var("WINSMUX_TASK876_STARTUP_TRACE").as_deref() == Ok("1") {
        let trace = ChildStartupTrace::new();
        let result = run_child_inner(
            argument,
            #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
            None,
            Some(&trace),
        );
        return match result {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("winsmux workspace: {}", error.classification());
                trace.exit_code(error)
            }
        };
    }
    match run_child(argument) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("winsmux workspace: {}", error.classification());
            error.exit_code()
        }
    }
}

#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
pub fn run_child_stop_reply_loss(
    owner: &str,
    ready: &str,
    discard: &str,
    parent: &str,
) -> Result<(), HostError> {
    run_child_inner(owner, Some([ready, discard, parent]), None)
}

fn run_child_inner(
    argument: &str,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))] gate_arguments: Option<
        [&str; 3],
    >,
    #[cfg(debug_assertions)] trace: Option<&ChildStartupTrace>,
) -> Result<(), HostError> {
    let raw = usize::from_str_radix(argument, 16).map_err(|_| HostError::Startup)? as HANDLE;
    if raw.is_null() || raw == INVALID_HANDLE_VALUE {
        return Err(HostError::Startup);
    }
    let mut flags = 0u32;
    if unsafe { GetHandleInformation(raw, &mut flags) } == 0
        || flags & HANDLE_FLAG_INHERIT == 0
        || unsafe { GetFileType(raw) } != FILE_TYPE_PIPE
    {
        return Err(HostError::Startup);
    }
    let mut pipe_flags = 0u32;
    if unsafe { GetNamedPipeInfo(raw, &mut pipe_flags, null_mut(), null_mut(), null_mut()) } == 0
        || unsafe { SetHandleInformation(raw, HANDLE_FLAG_INHERIT, 0) } == 0
    {
        return Err(HostError::Startup);
    }
    let owner = unsafe { OwnedHandle::from_raw(raw) }.map_err(map_io)?;
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    let gate = gate_arguments
        .map(|arguments| stop_reply_loss::ChildGate::parse(raw, arguments))
        .transpose()?;
    run_host(
        owner,
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        gate,
        #[cfg(debug_assertions)]
        trace,
    )
}

fn run_host(
    owner: OwnedHandle,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))] gate: Option<
        stop_reply_loss::ChildGate,
    >,
    #[cfg(debug_assertions)] trace: Option<&ChildStartupTrace>,
) -> Result<(), HostError> {
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Identity);
    }
    let identity = Identity::current().map_err(map_io)?;
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Mutex);
    }
    let _mutex = acquire_host_mutex(&identity)?;
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::InheritanceProbe);
    }
    #[cfg(debug_assertions)]
    let mut inheritance_probe = super::testing::InheritanceProbe::start(owner.raw())?;
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Capability);
    }
    let server_capability = ServerCapabilityToken::create(&identity).map_err(map_io)?;
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::ServerKey);
    }
    let server_key = Arc::new(ServerKey::generate().map_err(map_io)?);
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Authorization);
    }
    let authorization = Arc::new(Authorization::new(Vec::new()));
    authorization.start_provider_probes();
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::CancelEvent);
    }
    let host_cancel = Arc::new(CancelEvent::new().map_err(map_io)?);
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Supervisor);
    }
    let supervisor = ConnectionSupervisor::new(authorization.clone(), host_cancel.clone())
        .map_err(map_supervisor)?;
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::Discovery);
    }
    let discovery = Discovery::for_server(
        &identity,
        authorization.instance_id().clone(),
        server_key.fingerprint(),
    )?;
    let pipe_name = discovery.pipe_name.clone();

    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::PublicPipe);
    }
    let listener =
        create_public_pipe(&pipe_name, &identity, true, &server_capability).map_err(map_io)?;
    let accept_authorization = authorization.clone();
    let accept_cancel = host_cancel.clone();
    let accept_identity = identity.clone();
    let accept_name = pipe_name.clone();
    let accept_key = server_key.clone();
    let accept_instance = discovery.instance_id.clone();
    let shutdown_authorization = accept_authorization.clone();
    let shutdown_cancel = accept_cancel.clone();
    let accept_supervisor = supervisor.clone();
    #[cfg(debug_assertions)]
    if let Some(trace) = trace {
        trace.set(ChildStartupStage::AcceptThread);
    }
    let accept_thread = std::thread::Builder::new()
        .name("winsmux-workspace-accept".to_owned())
        .spawn(move || {
            run_supervised_accept_guarded(
                &shutdown_authorization,
                &shutdown_cancel,
                &accept_supervisor,
                || {
                    accept_loop(
                        accept_name,
                        accept_identity,
                        server_capability,
                        accept_key,
                        accept_instance,
                        accept_authorization,
                        accept_cancel,
                        accept_supervisor.clone(),
                        listener,
                    )
                },
            )
        })
        .map_err(|_| HostError::Startup)?;

    // Discovery is deliberately outside the generation's supervised accept loop.
    // Failure here only makes the extension unavailable.
    let sidecar_thread = start_artifact_review_sidecar(
        &discovery,
        &identity,
        server_key.clone(),
        host_cancel.clone(),
    );

    let mut first_error = None;
    let mut owner_cancelled = false;
    let startup_result = (|| -> Result<(), HostError> {
        #[cfg(debug_assertions)]
        if let Some(trace) = trace {
            trace.set(ChildStartupStage::DiscoverySerialization);
        }
        let discovery_bytes = serde_json::to_vec(&discovery).map_err(|_| HostError::Protocol)?;
        #[cfg(debug_assertions)]
        if inheritance_probe.is_some() {
            attempt_first_startup_frame(trace, || {
                write_frame(
                    owner.raw(),
                    super::testing::HANDLE_PROBE_READY,
                    &[host_cancel.raw()],
                )
                .map_err(map_io)
            })?;
        }
        #[cfg(debug_assertions)]
        attempt_first_startup_frame(trace, || {
            write_frame(owner.raw(), &discovery_bytes, &[host_cancel.raw()]).map_err(map_io)
        })?;
        #[cfg(not(debug_assertions))]
        write_frame(owner.raw(), &discovery_bytes, &[host_cancel.raw()]).map_err(map_io)?;
        match owner_loop_inner(
            owner.raw(),
            &authorization,
            &host_cancel,
            #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
            gate.as_ref(),
        ) {
            Ok(()) | Err(IoError::Eof) => Ok(()),
            Err(IoError::Cancelled) => {
                owner_cancelled = true;
                Ok(())
            }
            Err(error) => Err(map_io(error)),
        }
    })();
    if let Err(error) = startup_result {
        record_first_error(&mut first_error, error);
    }

    close_and_collect_host_threads(
        &authorization,
        &host_cancel,
        accept_thread,
        &mut first_error,
    );
    if !authorization.drain_provider_probes() {
        record_first_error(&mut first_error, HostError::Transport);
    }
    if let Some(sidecar_thread) = sidecar_thread {
        let _ = sidecar_thread.join();
    }

    #[cfg(debug_assertions)]
    if let Some(probe) = inheritance_probe.take() {
        if let Err(error) = probe.finish() {
            record_first_error(&mut first_error, error);
        }
    }

    finish_host_result(first_error, owner_cancelled)
}

const ARTIFACT_REVIEW_IDENTITY: &[u8; 18] = b"artifact_review_v1";

fn start_artifact_review_sidecar(
    discovery: &Discovery,
    identity: &Identity,
    server_key: Arc<ServerKey>,
    host_cancel: Arc<CancelEvent>,
) -> Option<JoinHandle<()>> {
    let capability = ServerCapabilityToken::create(identity).ok()?;
    let name = discovery.artifact_review_pipe_name();
    #[cfg(debug_assertions)]
    if std::env::var_os("WINSMUX_TASK867_FAIL_SIDECAR_CREATE").is_some() {
        return None;
    }
    let listener = create_public_pipe(&name, identity, true, &capability).ok()?;
    let identity = identity.clone();
    let instance = discovery.instance_id.clone();
    std::thread::Builder::new()
        .name("winsmux-artifact-review-discovery".to_owned())
        .spawn(move || {
            let _ = catch_unwind(AssertUnwindSafe(|| {
                let sidecar_allocations = super::admission::AllocationAuthority::host();
                let mut listener = listener;
                loop {
                    match connect_overlapped(listener.raw(), &[host_cancel.raw()]) {
                        Ok(()) => {}
                        Err(_) => break,
                    }
                    // Make a new listener before serving the connected peer. A failure
                    // cannot propagate into the ordinary host supervisor.
                    let next = create_public_pipe(&name, &identity, false, &capability);
                    serve_artifact_review_sidecar(
                        &listener,
                        &identity,
                        &server_key,
                        &instance,
                        &name,
                        &sidecar_allocations,
                        &host_cancel,
                    );
                    match next {
                        Ok(pipe) => listener = pipe,
                        Err(_) => break,
                    }
                }
            }));
        })
        .ok()
}

fn serve_artifact_review_sidecar(
    pipe: &OwnedHandle,
    identity: &Identity,
    server_key: &ServerKey,
    instance: &crate::contract::InstanceId,
    name: &str,
    allocations: &super::admission::AllocationAuthority,
    host_cancel: &CancelEvent,
) {
    #[cfg(debug_assertions)]
    if std::env::var_os("WINSMUX_TASK867_FAIL_SIDECAR_ADMISSION").is_some() {
        return;
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("WINSMUX_TASK867_FAIL_SIDECAR_RESOURCE").is_some() {
        allocations.fail_after_allocations(0);
    }
    let Ok((_executable, authentication)) =
        read_authenticated_challenge(pipe.raw(), identity, &[host_cancel.raw()], allocations)
    else {
        return;
    };
    let Ok(challenge) = parse_auth_request(&authentication) else {
        return;
    };
    let mut client_pid = 0u32;
    if unsafe { GetNamedPipeClientProcessId(pipe.raw(), &mut client_pid) } == 0 || client_pid == 0 {
        return;
    }
    let Ok(mut proof) = server_key.response(instance, name, &challenge, client_pid, unsafe {
        GetCurrentProcessId()
    }) else {
        return;
    };
    #[cfg(debug_assertions)]
    if std::env::var_os("WINSMUX_TASK867_FAIL_SIDECAR_PROOF").is_some() {
        proof[proof.len() - 1] ^= 1;
    }
    if write_frame(pipe.raw(), &proof, &[host_cancel.raw()]).is_err() {
        return;
    }
    let _ = write_frame(pipe.raw(), ARTIFACT_REVIEW_IDENTITY, &[host_cancel.raw()]);
}

fn record_first_error(first: &mut Option<HostError>, error: HostError) {
    if first.is_none() {
        *first = Some(error);
    }
}

fn close_and_collect_host_threads(
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    accept_thread: JoinHandle<Result<(), IoError>>,
    first_error: &mut Option<HostError>,
) {
    close_and_cancel(authorization, host_cancel);
    match accept_thread.join() {
        Ok(Ok(())) => {}
        Ok(Err(error)) => record_first_error(first_error, map_io(error)),
        Err(_) => record_first_error(first_error, HostError::Transport),
    }
}

fn finish_host_result(
    mut first_error: Option<HostError>,
    owner_cancelled: bool,
) -> Result<(), HostError> {
    if first_error.is_none() && owner_cancelled {
        record_first_error(&mut first_error, HostError::Cancelled);
    }
    first_error.map_or(Ok(()), Err)
}

fn close_and_cancel(authorization: &Authorization, host_cancel: &CancelEvent) {
    let closed = authorization.close_generation();
    host_cancel.signal();
    closed.signal_cancellations();
    closed.reap_jobs();
}

fn run_accept_guarded(
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    accept: impl FnOnce() -> Result<(), IoError>,
) -> Result<(), IoError> {
    match catch_unwind(AssertUnwindSafe(accept)) {
        Ok(result) => {
            if result.is_err() {
                close_and_cancel(authorization, host_cancel);
            }
            result
        }
        Err(payload) => {
            close_and_cancel(authorization, host_cancel);
            resume_unwind(payload)
        }
    }
}

fn run_supervised_accept_guarded(
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    supervisor: &ConnectionSupervisor,
    accept: impl FnOnce() -> Result<(), IoError>,
) -> Result<(), IoError> {
    match catch_unwind(AssertUnwindSafe(accept)) {
        Ok(result) => {
            close_and_cancel(authorization, host_cancel);
            let cleanup = supervisor
                .close_and_reap()
                .map(|_| ())
                .map_err(map_supervisor_io);
            result.and(cleanup)
        }
        Err(payload) => {
            close_and_cancel(authorization, host_cancel);
            let _ = supervisor.close_and_reap();
            resume_unwind(payload)
        }
    }
}

#[cfg(debug_assertions)]
pub(super) fn close_and_collect_host_threads_for_test(
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    accept_thread: JoinHandle<Result<(), IoError>>,
    worker_receiver: mpsc::Receiver<JoinHandle<()>>,
    first_error: &mut Option<HostError>,
) {
    close_and_cancel(authorization, host_cancel);
    match accept_thread.join() {
        Ok(Ok(())) => {}
        Ok(Err(error)) => record_first_error(first_error, map_io(error)),
        Err(_) => record_first_error(first_error, HostError::Transport),
    }
    for worker in worker_receiver {
        if worker.join().is_err() {
            record_first_error(first_error, HostError::Transport);
        }
    }
}

#[cfg(debug_assertions)]
pub(super) fn finish_host_result_for_test(
    first_error: Option<HostError>,
    owner_cancelled: bool,
) -> Result<(), HostError> {
    finish_host_result(first_error, owner_cancelled)
}

#[cfg(debug_assertions)]
pub(super) fn run_accept_guarded_for_test(
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    accept: impl FnOnce() -> Result<(), IoError>,
) -> Result<(), IoError> {
    run_accept_guarded(authorization, host_cancel, accept)
}

fn owner_loop(
    owner: HANDLE,
    authorization: &Authorization,
    host_cancel: &CancelEvent,
) -> Result<(), IoError> {
    owner_loop_inner(
        owner,
        authorization,
        host_cancel,
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        None,
    )
}

fn owner_loop_inner(
    owner: HANDLE,
    authorization: &Authorization,
    host_cancel: &CancelEvent,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))] gate: Option<
        &stop_reply_loss::ChildGate,
    >,
) -> Result<(), IoError> {
    let mut send = ChargedVec::with_capacity(
        authorization.allocations(),
        AllocationPool::ActiveOwner,
        MAX_MESSAGE_BYTES,
        MAX_MESSAGE_BYTES,
    )
    .map_err(|_| IoError::Failed)?;
    loop {
        let frame = read_frame_owned(
            owner,
            &[host_cancel.raw()],
            authorization.allocations(),
            AllocationPool::ActiveOwner,
        )?;
        let prepared = match prepare_request(
            frame,
            authorization.allocations(),
            AllocationPool::ActiveOwner,
        ) {
            Ok(prepared) => prepared,
            Err(error) => {
                reply_codec_error(authorization, error, &mut send, owner, &[host_cancel.raw()])?;
                continue;
            }
        };
        let mut dispatch = authorization
            .dispatch_owner(prepared.request(), prepared.canonical(), &mut send)
            .ok_or(IoError::Failed)?;
        dispatch.signal_cancellations();
        let observation = dispatch.observation.take();
        drop(prepared);
        #[cfg(debug_assertions)]
        crate::auth::wait_owner_publication();
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        if dispatch.stop_after_reply {
            if let Some(gate) = gate {
                if let Some(hold) = observation {
                    authorization.release_observation(hold);
                }
                gate.discard_reply()?;
                return Ok(());
            }
        }
        let written = write_frame(owner, &send, &[host_cancel.raw()]);
        if let Some(hold) = observation {
            authorization.release_observation(hold);
        }
        written?;
        if dispatch.stop_after_reply {
            return Ok(());
        }
        send.clear();
    }
}

fn accept_loop(
    pipe_name: String,
    identity: Identity,
    server_capability: ServerCapabilityToken,
    server_key: Arc<ServerKey>,
    instance_id: crate::contract::InstanceId,
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
    supervisor: ConnectionSupervisor,
    mut listener: OwnedHandle,
) -> Result<(), IoError> {
    loop {
        match connect_overlapped_with_wake(
            listener.raw(),
            host_cancel.raw(),
            supervisor.completion_raw(),
            || {
                supervisor
                    .reap_completed()
                    .map(|_| ())
                    .map_err(map_supervisor_io)
            },
        ) {
            Ok(()) => {}
            Err(IoError::Cancelled) => return Ok(()),
            Err(error) => return Err(error),
        }

        let connection = listener;
        let worker_authorization = authorization.clone();
        let worker_identity = identity.clone();
        let worker_cancel = host_cancel.clone();
        let worker_key = server_key.clone();
        let worker_instance = instance_id.clone();
        let worker_name = pipe_name.clone();
        let connection_cancel = Arc::new(CancelEvent::new()?);
        let worker_connection_cancel = connection_cancel.clone();
        // Both Spawned and normal Refused continue the listener. Only real
        // supervisor errors leave this loop and close the host generation.
        supervisor
            .spawn(connection_cancel, move |lease| {
                handle_public_connection(
                    connection,
                    worker_identity,
                    worker_key,
                    worker_instance,
                    worker_name,
                    worker_authorization,
                    worker_cancel,
                    worker_connection_cancel,
                    lease,
                );
            })
            .map_err(map_supervisor_io)?;
        let next = match create_public_pipe(&pipe_name, &identity, false, &server_capability) {
            Ok(next) => next,
            Err(error) => return Err(error),
        };
        listener = next;
    }
}

fn handle_public_connection(
    pipe: OwnedHandle,
    identity: Identity,
    server_key: Arc<ServerKey>,
    instance_id: crate::contract::InstanceId,
    pipe_name: String,
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
    connection_cancel: Arc<CancelEvent>,
    lease: crate::auth::ConnectionLease,
) {
    let mut observer = NoConnectionObserver;
    handle_public_connection_inner(
        pipe,
        identity,
        server_key,
        instance_id,
        pipe_name,
        authorization,
        host_cancel,
        Some((connection_cancel, lease)),
        &mut observer,
    );
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ConnectionCheckpoint {
    BeforeAuthenticationPermit,
    AfterAuthenticationPermit,
    AfterAuthenticationRead,
    BeforeProofPermit,
    AfterProofPermit,
    AfterProofWrite,
    BeforeAttach,
    AfterAttach,
    AfterResponseWrite,
}

pub(super) trait ConnectionObserver {
    fn reached(&mut self, checkpoint: ConnectionCheckpoint);
}

struct NoConnectionObserver;

impl ConnectionObserver for NoConnectionObserver {
    fn reached(&mut self, _checkpoint: ConnectionCheckpoint) {}
}

#[cfg(debug_assertions)]
pub(super) fn handle_public_connection_observed(
    pipe: OwnedHandle,
    identity: Identity,
    server_key: Arc<ServerKey>,
    instance_id: crate::contract::InstanceId,
    pipe_name: String,
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
    mut observer: impl ConnectionObserver,
) {
    handle_public_connection_inner(
        pipe,
        identity,
        server_key,
        instance_id,
        pipe_name,
        authorization,
        host_cancel,
        None,
        &mut observer,
    );
}

fn handle_public_connection_inner(
    pipe: OwnedHandle,
    identity: Identity,
    server_key: Arc<ServerKey>,
    instance_id: crate::contract::InstanceId,
    pipe_name: String,
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
    admitted: Option<(Arc<CancelEvent>, crate::auth::ConnectionLease)>,
    observer: &mut impl ConnectionObserver,
) {
    observer.reached(ConnectionCheckpoint::BeforeAuthenticationPermit);
    let authentication_permit = match admitted.as_ref() {
        Some((_, lease)) => authorization.begin_worker_authentication(lease),
        None => authorization.begin_authentication(),
    };
    let authentication_permit = match authentication_permit {
        Some(permit) => permit,
        None => return,
    };
    observer.reached(ConnectionCheckpoint::AfterAuthenticationPermit);
    let connection_cancel_raw = admitted.as_ref().map(|(cancel, _)| cancel.raw());
    let mut cancellation_handles = [host_cancel.raw(), null_mut()];
    let cancellation_count = if let Some(connection_cancel) = connection_cancel_raw {
        cancellation_handles[1] = connection_cancel;
        2
    } else {
        1
    };
    let authentication_cancellations = &cancellation_handles[..cancellation_count];
    let (executable, authentication) = match read_public_authentication(
        pipe.raw(),
        &identity,
        authentication_cancellations,
        authentication_permit,
        authorization.allocations(),
    ) {
        Ok(authentication) => authentication,
        Err(_) => return,
    };
    observer.reached(ConnectionCheckpoint::AfterAuthenticationRead);
    let challenge = match parse_auth_request(&authentication) {
        Ok(challenge) => challenge,
        Err(_) => return,
    };
    let mut client_pid = 0u32;
    if unsafe { GetNamedPipeClientProcessId(pipe.raw(), &mut client_pid) } == 0 || client_pid == 0 {
        return;
    }
    let proof =
        match server_key.response(&instance_id, &pipe_name, &challenge, client_pid, unsafe {
            GetCurrentProcessId()
        }) {
            Ok(proof) => proof,
            Err(_) => return,
        };
    observer.reached(ConnectionCheckpoint::BeforeProofPermit);
    let proof_permit = match admitted.as_ref() {
        Some((_, lease)) => authorization.begin_worker_proof_send(lease),
        None => authorization.begin_proof_send(),
    };
    let proof_permit = match proof_permit {
        Some(permit) => permit,
        None => return,
    };
    observer.reached(ConnectionCheckpoint::AfterProofPermit);
    if write_public_proof(
        pipe.raw(),
        &proof,
        authentication_cancellations,
        proof_permit,
    )
    .is_err()
    {
        return;
    }
    observer.reached(ConnectionCheckpoint::AfterProofWrite);
    observer.reached(ConnectionCheckpoint::BeforeAttach);
    let (connection_cancel, lease) = match admitted {
        Some((cancel, lease)) => {
            if !authorization.mark_verified(&lease, executable) {
                return;
            }
            (cancel, lease)
        }
        None => {
            #[cfg(not(debug_assertions))]
            return;
            #[cfg(debug_assertions)]
            let cancel = match CancelEvent::new() {
                Ok(cancel) => Arc::new(cancel),
                Err(_) => return,
            };
            #[cfg(debug_assertions)]
            let lease = match authorization
                .attach_verified_fixture((*executable).clone(), cancel.clone())
            {
                Some(lease) => lease,
                None => return,
            };
            #[cfg(debug_assertions)]
            (cancel, lease)
        }
    };
    observer.reached(ConnectionCheckpoint::AfterAttach);

    let mut send = match ChargedVec::with_capacity(
        authorization.allocations(),
        AllocationPool::ActivePublic,
        MAX_MESSAGE_BYTES,
        MAX_MESSAGE_BYTES,
    ) {
        Ok(send) => send,
        Err(_) => {
            authorization.disconnect(&lease);
            return;
        }
    };
    let mut run = || -> Result<(), IoError> {
        loop {
            let mut current_header = [0u8; 4];
            read_exact(
                pipe.raw(),
                &mut current_header,
                &[host_cancel.raw(), connection_cancel.raw()],
            )?;
            let _ = verify_pipe_peer_charged(
                pipe.raw(),
                &identity,
                None,
                authorization.allocations(),
                AllocationPool::ActivePublic,
            )
            .map_err(|_| IoError::Failed)?;
            let length = decode_length(current_header)?;
            let mut body = OwnedFrame::allocate(
                authorization.allocations(),
                AllocationPool::ActivePublic,
                length,
            )
            .map_err(|_| IoError::Failed)?;
            read_exact(
                pipe.raw(),
                &mut body,
                &[host_cancel.raw(), connection_cancel.raw()],
            )?;
            let prepared = match prepare_request(
                body,
                authorization.allocations(),
                AllocationPool::ActivePublic,
            ) {
                Ok(prepared) => prepared,
                Err(error) => {
                    reply_public_codec_error(
                        &authorization,
                        &lease,
                        error,
                        &mut send,
                        pipe.raw(),
                        &[host_cancel.raw(), connection_cancel.raw()],
                    )?;
                    continue;
                }
            };
            let mut dispatch = authorization
                .dispatch_client(&lease, prepared.request(), prepared.canonical(), &mut send)
                .ok_or(IoError::Cancelled)?;
            let observation = dispatch.observation.take();
            drop(prepared);
            let sent = authorization.send_if_current(&lease, || {
                write_lease_response(
                    pipe.raw(),
                    &send,
                    &[host_cancel.raw(), connection_cancel.raw()],
                    &lease,
                )
            });
            if let Some(hold) = observation {
                authorization.release_observation(hold);
            }
            match sent {
                None => {
                    send.clear();
                    continue;
                }
                Some(result) => result?,
            }
            send.clear();
            observer.reached(ConnectionCheckpoint::AfterResponseWrite);
        }
    };
    let _ = run();
    authorization.disconnect(&lease);
}

fn reply_codec_error(
    authorization: &crate::auth::Authorization,
    error: HostCodecError,
    send: &mut ChargedVec<u8>,
    owner: HANDLE,
    cancellations: &[HANDLE],
) -> Result<(), IoError> {
    match error {
        HostCodecError::Contract(_) => Err(IoError::Protocol),
        HostCodecError::Exhausted {
            correlation: None, ..
        } => Err(IoError::Failed),
        HostCodecError::Exhausted {
            correlation: Some(correlation),
            ..
        } => {
            authorization
                .write_correlated_exhausted(&correlation, send)
                .ok_or(IoError::Failed)?;
            write_frame(owner, send, cancellations)?;
            send.clear();
            Ok(())
        }
    }
}

fn reply_public_codec_error(
    authorization: &crate::auth::Authorization,
    lease: &crate::auth::ConnectionLease,
    error: HostCodecError,
    send: &mut ChargedVec<u8>,
    pipe: HANDLE,
    cancellations: &[HANDLE],
) -> Result<(), IoError> {
    match error {
        HostCodecError::Contract(_) => Err(IoError::Protocol),
        HostCodecError::Exhausted {
            correlation: None, ..
        } => Err(IoError::Failed),
        HostCodecError::Exhausted {
            correlation: Some(correlation),
            ..
        } => {
            authorization
                .write_correlated_exhausted(&correlation, send)
                .ok_or(IoError::Failed)?;
            match authorization.send_if_current(lease, || {
                write_lease_response(pipe, send, cancellations, lease)
            }) {
                None => {
                    send.clear();
                    Ok(())
                }
                Some(result) => {
                    result?;
                    send.clear();
                    Ok(())
                }
            }
        }
    }
}

fn map_supervisor(_error: ConnectionSupervisorError) -> HostError {
    HostError::Startup
}

fn map_supervisor_io(_error: ConnectionSupervisorError) -> IoError {
    IoError::Failed
}

fn read_public_authentication(
    pipe: HANDLE,
    identity: &Identity,
    cancellations: &[HANDLE],
    _permit: AuthenticationIoPermit,
    allocations: &crate::host::admission::AllocationAuthority,
) -> Result<(ChargedValue<NonEmpty>, [u8; AUTH_REQUEST_BYTES]), IoError> {
    read_authenticated_challenge(pipe, identity, cancellations, allocations)
}

fn read_authenticated_challenge(
    pipe: HANDLE,
    identity: &Identity,
    cancellations: &[HANDLE],
    allocations: &crate::host::admission::AllocationAuthority,
) -> Result<(ChargedValue<NonEmpty>, [u8; AUTH_REQUEST_BYTES]), IoError> {
    let mut header = [0u8; 4];
    read_exact(pipe, &mut header, cancellations)?;
    let executable = verify_pipe_peer_charged(
        pipe,
        identity,
        None,
        allocations,
        AllocationPool::ActivePublic,
    )
    .map_err(|_| IoError::Failed)?;
    if u32::from_le_bytes(header) as usize != AUTH_REQUEST_BYTES {
        return Err(IoError::Protocol);
    }
    let mut authentication = [0u8; AUTH_REQUEST_BYTES];
    read_exact(pipe, &mut authentication, cancellations)?;
    Ok((executable, authentication))
}

fn write_public_proof(
    pipe: HANDLE,
    proof: &[u8],
    cancellations: &[HANDLE],
    _permit: ProofSendPermit,
) -> Result<(), IoError> {
    write_frame(pipe, proof, cancellations)
}

fn write_lease_response(
    handle: HANDLE,
    body: &[u8],
    cancellations: &[HANDLE],
    lease: &crate::auth::ConnectionLease,
) -> Result<(), IoError> {
    #[cfg(debug_assertions)]
    {
        write_public_frame(handle, body, cancellations, &lease.connection_id())
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = lease;
        write_frame(handle, body, cancellations)
    }
}

#[cfg(debug_assertions)]
pub(super) fn create_private_channel_for_test(
    identity: &Identity,
) -> Result<(OwnedHandle, OwnedHandle), HostError> {
    create_private_channel(identity)
}

#[cfg(debug_assertions)]
pub(super) fn close_on_owner_eof_for_test(
    owner: OwnedHandle,
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
) -> Result<(), IoError> {
    let result = owner_loop(owner.raw(), &authorization, &host_cancel);
    close_and_cancel(&authorization, &host_cancel);
    result
}

fn acquire_host_mutex(identity: &Identity) -> Result<HostMutex, HostError> {
    let name = format!(r"Local\winsmux-workspace-v1-{}", identity.logon_key());
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let mut descriptor = SecurityDescriptor::new(identity, SecurityMode::Mutex).map_err(map_io)?;
    let attributes = descriptor.attributes(false);
    let handle = unsafe {
        CreateMutexExW(
            &attributes,
            wide.as_ptr(),
            0,
            MUTEX_MODIFY_STATE | 0x0010_0000,
        )
    };
    let handle = unsafe { OwnedHandle::from_raw(handle) }.map_err(map_io)?;
    match unsafe { WaitForSingleObject(handle.raw(), 0) } {
        WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(HostMutex { handle }),
        WAIT_TIMEOUT => Err(HostError::Startup),
        _ => Err(HostError::Startup),
    }
}

fn create_private_channel(identity: &Identity) -> Result<(OwnedHandle, OwnedHandle), HostError> {
    let name = format!(r"\\.\pipe\winsmux-workspace-owner-{}", uuid::Uuid::new_v4());
    let server =
        create_pipe(&name, identity, true, false, SecurityMode::CurrentLogon, 1).map_err(map_io)?;
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let client = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
            null_mut(),
        )
    };
    let client = if client == INVALID_HANDLE_VALUE {
        return Err(HostError::Startup);
    } else {
        unsafe { OwnedHandle::from_raw(client) }.map_err(map_io)?
    };
    connect_overlapped(server.raw(), &[]).map_err(map_io)?;
    Ok((client, server))
}

fn create_public_pipe(
    name: &str,
    identity: &Identity,
    first: bool,
    capability: &ServerCapabilityToken,
) -> Result<OwnedHandle, IoError> {
    capability.while_impersonating(|| {
        create_pipe(
            name,
            identity,
            first,
            true,
            SecurityMode::PublicPipe {
                server_logon: capability.logon(),
            },
            PIPE_UNLIMITED_INSTANCES,
        )
    })
}

pub(super) fn create_pipe(
    name: &str,
    identity: &Identity,
    first: bool,
    reject_remote: bool,
    mode: SecurityMode<'_>,
    max_instances: u32,
) -> Result<OwnedHandle, IoError> {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let mut descriptor = SecurityDescriptor::new(identity, mode)?;
    let attributes = descriptor.attributes(false);
    let mut open_mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
    if first {
        open_mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
    }
    let mut pipe_mode = PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT;
    if reject_remote {
        pipe_mode |= PIPE_REJECT_REMOTE_CLIENTS;
    }
    let handle = unsafe {
        CreateNamedPipeW(
            wide.as_ptr(),
            open_mode,
            pipe_mode,
            max_instances,
            MAX_MESSAGE_BYTES as u32,
            MAX_MESSAGE_BYTES as u32,
            0,
            &attributes,
        )
    };
    unsafe { OwnedHandle::from_raw(handle) }
}

#[cfg(debug_assertions)]
pub struct ProductClient {
    pipe: OwnedHandle,
    cancel: Arc<CancelEvent>,
}

#[cfg(debug_assertions)]
pub struct ProductHost {
    authorization: Arc<crate::auth::Authorization>,
    supervisor: ConnectionSupervisor,
    host_cancel: Arc<CancelEvent>,
    owner_client: OwnedHandle,
    discovery: Discovery,
    server_key: Arc<ServerKey>,
    instance_id: crate::contract::InstanceId,
    accept_thread: Option<JoinHandle<Result<(), IoError>>>,
    owner_thread: Option<JoinHandle<Result<(), IoError>>>,
    sidecar_thread: Option<JoinHandle<()>>,
}

#[cfg(debug_assertions)]
pub struct SupervisedPreauth {
    host: ProductHost,
    _stalled: ProductClient,
}

#[cfg(debug_assertions)]
impl ProductHost {
    pub fn start(projects: Vec<ProjectId>) -> Result<Self, HostError> {
        let identity = Identity::current().map_err(map_io)?;
        let server_capability = ServerCapabilityToken::create(&identity).map_err(map_io)?;
        let server_key = Arc::new(ServerKey::generate().map_err(map_io)?);
        let authorization = Arc::new(crate::auth::Authorization::new(projects));
        let host_cancel = Arc::new(CancelEvent::new().map_err(map_io)?);
        let supervisor = ConnectionSupervisor::new(authorization.clone(), host_cancel.clone())
            .map_err(map_supervisor)?;
        let instance_id = authorization.instance_id().clone();
        let discovery =
            Discovery::for_server(&identity, instance_id.clone(), server_key.fingerprint())?;
        let listener =
            create_public_pipe(&discovery.pipe_name, &identity, true, &server_capability)
                .map_err(map_io)?;
        let (owner_client, owner_server) = create_private_channel(&identity)?;

        let owner_authorization = authorization.clone();
        let owner_cancel = host_cancel.clone();
        let owner_thread = std::thread::Builder::new()
            .name("winsmux-workspace-test-owner".to_owned())
            .spawn(move || {
                match owner_loop(owner_server.raw(), &owner_authorization, &owner_cancel) {
                    Ok(()) | Err(IoError::Eof) | Err(IoError::Cancelled) => Ok(()),
                    Err(error) => Err(error),
                }
            })
            .map_err(|_| HostError::Startup)?;

        let accept_authorization = authorization.clone();
        let accept_cancel = host_cancel.clone();
        let accept_identity = identity.clone();
        let accept_name = discovery.pipe_name.clone();
        let accept_key = server_key.clone();
        let accept_instance = instance_id.clone();
        let accept_supervisor = supervisor.clone();
        let accept_thread = std::thread::Builder::new()
            .name("winsmux-workspace-test-accept".to_owned())
            .spawn(move || {
                accept_loop(
                    accept_name,
                    accept_identity,
                    server_capability,
                    accept_key,
                    accept_instance,
                    accept_authorization,
                    accept_cancel,
                    accept_supervisor,
                    listener,
                )
            })
            .map_err(|_| HostError::Startup)?;

        let sidecar_thread = start_artifact_review_sidecar(
            &discovery,
            &identity,
            server_key.clone(),
            host_cancel.clone(),
        );

        Ok(Self {
            authorization,
            supervisor,
            host_cancel,
            owner_client,
            discovery,
            server_key,
            instance_id,
            accept_thread: Some(accept_thread),
            owner_thread: Some(owner_thread),
            sidecar_thread,
        })
    }

    pub fn instance_id(&self) -> &crate::contract::InstanceId {
        &self.instance_id
    }

    pub fn extension_proof_available(&self) -> bool {
        let cancel = match CancelEvent::new() {
            Ok(cancel) => cancel,
            Err(_) => return false,
        };
        crate::client::probe_artifact_review(
            &self.discovery,
            self.server_key.fingerprint(),
            &cancel,
        )
    }

    pub fn allocations(&self) -> &crate::host::admission::AllocationAuthority {
        self.authorization.allocations()
    }

    pub fn owner_pipe(&self) -> HANDLE {
        self.owner_client.raw()
    }

    pub fn authorization(&self) -> Arc<crate::auth::Authorization> {
        self.authorization.clone()
    }

    pub fn record_count(&self) -> usize {
        self.authorization.record_count()
    }

    pub fn event_seq(&self) -> u64 {
        self.authorization.event_seq()
    }

    pub fn set_event_seq_to_max(&self) {
        self.authorization.set_event_seq_to_max();
    }

    pub fn generation_is_open(&self) -> bool {
        self.authorization.generation_is_open()
    }

    pub fn connect_stalled(&self) -> Result<ProductClient, HostError> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            match open_client_pipe(&self.discovery.pipe_name) {
                Ok(pipe) => {
                    return Ok(ProductClient {
                        pipe,
                        cancel: Arc::new(CancelEvent::new().map_err(map_io)?),
                    });
                }
                Err(_) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(error) => return Err(error),
            }
        }
    }

    pub fn connect_authenticated(&self) -> Result<ProductClient, HostError> {
        let client = self.connect_stalled()?;
        client.authenticate(self)?;
        Ok(client)
    }

    pub fn owner_request(&self, request: &Request) -> Result<Response, HostError> {
        let body = self.owner_frame(request)?;
        parse_response(request, &body).map_err(|_| HostError::Protocol)
    }

    pub fn owner_frame(&self, request: &Request) -> Result<Vec<u8>, HostError> {
        let bytes = canonical_request(request).map_err(|_| HostError::Protocol)?;
        self.owner_bytes(&bytes)
    }

    pub fn owner_bytes(&self, bytes: &[u8]) -> Result<Vec<u8>, HostError> {
        write_frame(self.owner_client.raw(), bytes, &[self.host_cancel.raw()]).map_err(map_io)?;
        read_frame(self.owner_client.raw(), &[self.host_cancel.raw()]).map_err(map_io)
    }

    pub fn owner_json(&self, operation: &str, params: serde_json::Value) -> Response {
        let instance = serde_json::to_value(&self.instance_id)
            .ok()
            .and_then(|value| value.as_str().map(str::to_owned));
        let request = product_request(operation, instance.as_deref(), params);
        self.owner_request(&request).expect("owner_loop response")
    }

    pub fn owner_list(&self) -> Response {
        self.owner_json("connection.list", serde_json::json!({}))
    }

    pub fn revoke(&self, connection_id: &str) -> Response {
        self.owner_json(
            "connection.revoke",
            serde_json::json!({"connection_id": connection_id}),
        )
    }

    pub fn decide_allow(
        &self,
        connection_id: &str,
        project_ids: serde_json::Value,
        scopes: serde_json::Value,
    ) -> Response {
        self.owner_json(
            "connection.decide",
            serde_json::json!({
                "connection_id": connection_id,
                "decision": "allow",
                "project_ids": project_ids,
                "scopes": scopes
            }),
        )
    }

    pub fn wait_connections(&self, min: usize, timeout: std::time::Duration) -> serde_json::Value {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let listed = serde_json::to_value(&self.owner_list()).expect("list json");
            let count = listed["result"]["data"]["connections"]
                .as_array()
                .map(Vec::len)
                .unwrap_or(0);
            if count >= min {
                return listed;
            }
            if std::time::Instant::now() >= deadline {
                panic!("product accept did not publish {min} connection(s): {listed}");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    pub fn wait_idle(&self, timeout: std::time::Duration) {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if self.record_count() == 0 {
                return;
            }
            let _ = self.supervisor.reap_completed();
            if std::time::Instant::now() >= deadline {
                panic!(
                    "product workers were not joined, leftover {}",
                    self.record_count()
                );
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    pub fn shutdown(mut self) -> Result<(), HostError> {
        self.host_cancel.signal();
        let closed = self.authorization.close_generation();
        closed.signal_cancellations();
        closed.reap_jobs();
        let reap = self
            .supervisor
            .close_and_reap()
            .map(|_| ())
            .map_err(|_| HostError::Transport);
        if let Some(thread) = self.accept_thread.take() {
            match thread.join() {
                Ok(Ok(())) | Ok(Err(IoError::Cancelled)) | Ok(Err(IoError::Eof)) => {}
                Ok(Err(_)) | Err(_) => return Err(HostError::Transport),
            }
        }
        if let Some(thread) = self.sidecar_thread.take() {
            let _ = thread.join();
        }
        drop(self.owner_client);
        if let Some(thread) = self.owner_thread.take() {
            match thread.join() {
                Ok(Ok(())) | Ok(Err(IoError::Cancelled)) | Ok(Err(IoError::Eof)) => {}
                Ok(Err(_)) | Err(_) => return Err(HostError::Transport),
            }
        }
        if !self.authorization.drain_provider_probes() {
            return Err(HostError::Transport);
        }
        reap
    }
}

#[cfg(debug_assertions)]
impl ProductClient {
    pub fn authenticate(&self, host: &ProductHost) -> Result<(), HostError> {
        let mut server_pid = 0u32;
        if unsafe { GetNamedPipeServerProcessId(self.pipe.raw(), &mut server_pid) } == 0
            || server_pid == 0
        {
            return Err(HostError::Transport);
        }
        let challenge = random_challenge().map_err(map_io)?;
        let request = encode_request(&challenge);
        write_frame(self.pipe.raw(), &request, &[self.cancel.raw()]).map_err(map_io)?;
        let response = read_frame(self.pipe.raw(), &[self.cancel.raw()]).map_err(map_io)?;
        verify_response(
            &response,
            host.server_key.fingerprint(),
            &host.discovery.instance_id,
            &host.discovery.pipe_name,
            &challenge,
            unsafe { GetCurrentProcessId() },
            server_pid,
        )
        .map_err(map_io)
    }

    pub fn transact(&self, request: &Request) -> Result<Response, HostError> {
        let bytes = canonical_request(request).map_err(|_| HostError::Protocol)?;
        self.send_bytes(&bytes)?;
        let body = self.read_bytes()?;
        parse_response(request, &body).map_err(|_| HostError::Protocol)
    }

    pub fn send_bytes(&self, bytes: &[u8]) -> Result<(), HostError> {
        write_frame(self.pipe.raw(), bytes, &[self.cancel.raw()]).map_err(map_io)
    }

    pub fn pipe_handle(&self) -> HANDLE {
        self.pipe.raw()
    }

    pub fn read_bytes(&self) -> Result<Vec<u8>, HostError> {
        read_frame(self.pipe.raw(), &[self.cancel.raw()]).map_err(map_io)
    }
}

#[cfg(debug_assertions)]
fn product_request(
    operation: &str,
    instance_id: Option<&str>,
    params: serde_json::Value,
) -> Request {
    let value = serde_json::json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": uuid::Uuid::new_v4().to_string(),
        "expected_topology_revision": null,
        "operation": operation,
        "params": params,
    });
    crate::contract::parse_request(&serde_json::to_vec(&value).expect("request JSON"))
        .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

#[cfg(debug_assertions)]
impl SupervisedPreauth {
    pub fn start() -> Result<Self, HostError> {
        let host = ProductHost::start(Vec::new())?;
        let stalled = host.connect_stalled()?;
        Ok(Self {
            host,
            _stalled: stalled,
        })
    }

    pub fn owner_list(&self) -> Response {
        self.host.owner_list()
    }

    pub fn revoke(&self, connection_id: &str) -> Response {
        self.host.revoke(connection_id)
    }

    pub fn shutdown(self) -> Result<(), HostError> {
        self.host.shutdown()
    }
}

#[cfg(debug_assertions)]
fn open_client_pipe(name: &str) -> Result<OwnedHandle, HostError> {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let client = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
            null_mut(),
        )
    };
    if client == INVALID_HANDLE_VALUE {
        Err(HostError::Startup)
    } else {
        unsafe { OwnedHandle::from_raw(client) }.map_err(map_io)
    }
}

#[cfg(test)]
mod close_authentication_tests {
    use super::*;
    use crate::auth::testing::Harness;
    use crate::contract::ErrorCode;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    fn request(h: &Harness, operation: &str) -> Request {
        crate::contract::parse_request(&serde_json::to_vec(&serde_json::json!({
            "schema_version":1,"instance_id":h.instance_id(),
            "operation_id":uuid::Uuid::new_v4().to_string(),"expected_topology_revision":null,
            "operation":operation,"params":{}
        })).unwrap()).unwrap()
    }

    fn harness() -> Harness {
        let h = Harness::new(Vec::new());
        let root = std::env::temp_dir().join(format!("winsmux-close-native-{}", uuid::Uuid::new_v4()));
        assert!(h.authorization().testing_install_isolated_layout(&root));
        h
    }

    fn stop(h: &Harness, fail: bool) -> (mpsc::Sender<()>, JoinHandle<Response>) {
        let auth = h.authorization();
        let release = auth.testing_install_stop_join_gate(fail);
        let stopping = h.clone();
        let command = request(h, "host.stop");
        let thread = std::thread::spawn(move || stopping.owner(&command));
        let start = Instant::now();
        while !auth.testing_stop_is_reserved() {
            assert!(start.elapsed() < Duration::from_secs(30), "stop reservation missing");
            std::thread::yield_now();
        }
        (release, thread)
    }

    struct Gate {
        target: ConnectionCheckpoint,
        reached: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
        trace: Arc<Mutex<Vec<ConnectionCheckpoint>>>,
    }
    impl ConnectionObserver for Gate {
        fn reached(&mut self, checkpoint: ConnectionCheckpoint) {
            self.trace.lock().unwrap().push(checkpoint);
            if checkpoint == self.target {
                self.reached.send(()).unwrap();
                self.release.recv_timeout(Duration::from_secs(30)).unwrap();
            }
        }
    }

    #[test]
    fn native_managed_and_fixture_stages_obey_stop_reservation() {
        use ConnectionCheckpoint::*;
        for managed in [false, true] {
            for fail in [false, true] {
                for target in [BeforeAuthenticationPermit, AfterAuthenticationPermit,
                    BeforeProofPermit, AfterProofPermit, BeforeAttach] {
                    let h = harness();
                    let auth = h.authorization();
                    let existing = h.connect("existing-reply");
                    let before = auth.testing_connection_snapshot(&existing.connection_id());
                    let charges = auth.allocations().snapshot().active_public;
                    let tables = auth.testing_connection_owned_bytes().0;
                    let identity = Identity::current().unwrap();
                    let key = Arc::new(ServerKey::generate().unwrap());
                    let discovery = Discovery::for_server(&identity, h.instance_id(), key.fingerprint()).unwrap();
                    let capability = ServerCapabilityToken::create(&identity).unwrap();
                    let server = create_public_pipe(&discovery.pipe_name, &identity, true, &capability).unwrap();
                    let client = open_client_pipe(&discovery.pipe_name).unwrap();
                    connect_overlapped(server.raw(), &[]).unwrap();
                    let challenge = random_challenge().unwrap();
                    write_frame(client.raw(), &encode_request(&challenge), &[]).unwrap();
                    let host_cancel = Arc::new(CancelEvent::new().unwrap());
                    let supervisor = ConnectionSupervisor::new(auth.clone(), host_cancel.clone()).unwrap();
                    let (at, reached) = mpsc::channel();
                    let (resume, resume_wait) = mpsc::channel();
                    let trace = Arc::new(Mutex::new(Vec::new()));
                    let mut observer = Gate { target, reached: at, release: resume_wait, trace: trace.clone() };
                    let worker_auth = auth.clone();
                    let worker_cancel = host_cancel.clone();
                    let connection_cancel = Arc::new(CancelEvent::new().unwrap());
                    let worker_connection_cancel = connection_cancel.clone();
                    let body = move |lease: Option<crate::auth::ConnectionLease>| {
                        handle_public_connection_inner(server, identity, key, discovery.instance_id,
                            discovery.pipe_name, worker_auth, worker_cancel,
                            lease.map(|lease| (worker_connection_cancel, lease)), &mut observer);
                    };
                    let worker = if managed {
                        supervisor.spawn(connection_cancel, move |lease| body(Some(lease))).unwrap();
                        None
                    } else { Some(std::thread::spawn(move || body(None))) };
                    reached.recv_timeout(Duration::from_secs(30)).unwrap();
                    let (release, stopping) = stop(&h, fail);
                    resume.send(()).unwrap();
                    if let Some(worker) = worker { worker.join().unwrap(); }
                    else {
                        assert_eq!(unsafe { WaitForSingleObject(supervisor.completion_raw(), 30_000) }, WAIT_OBJECT_0);
                        assert_eq!(supervisor.reap_completed(), Ok(1));
                        assert_eq!(supervisor.reap_completed(), Ok(0));
                    }
                    let observed = trace.lock().unwrap().clone();
                    assert!(!observed.contains(&AfterAttach), "new Unpaired publication: {managed}/{fail}/{target:?}");
                    assert_eq!(observed.contains(&AfterAuthenticationRead), target != BeforeAuthenticationPermit);
                    assert_eq!(observed.contains(&AfterProofWrite), matches!(target, AfterProofPermit | BeforeAttach));
                    assert_eq!(auth.record_count(), 1, "worker record did not retire");
                    let (current_tables, stacks) = auth.testing_connection_owned_bytes();
                    assert_eq!(stacks, 0, "retired native worker retained a stack charge");
                    // Existing live fixtures keep the explicitly charged table's
                    // grown capacity. Every worker-owned byte must still return.
                    assert_eq!(auth.allocations().snapshot().active_public - current_tables,
                        charges - tables, "worker-owned charge did not return");
                    assert_eq!(auth.testing_connection_snapshot(&existing.connection_id()), before);
                    assert!(existing.send_if_current() && auth.generation_is_open());
                    release.send(()).unwrap();
                    let stopped = stopping.join().unwrap();
                    if fail {
                        assert_eq!(stopped.error.0.as_ref().unwrap().code(), ErrorCode::RuntimeFailed);
                        assert!(auth.generation_is_open() && existing.send_if_current());
                        assert_eq!(auth.testing_connection_snapshot(&existing.connection_id()), before);
                    } else { assert!(stopped.accepted && !auth.generation_is_open()); }
                    assert_eq!(supervisor.close_and_reap(), Ok(0));
                    drop(client);
                }
            }
        }
    }

    #[test]
    fn native_accept_refusal_keeps_listener_and_existing_reply_alive() {
        for fail in [false, true] {
            let h = harness();
            let auth = h.authorization();
            let existing = h.connect("existing-reply");
            let before = auth.testing_connection_snapshot(&existing.connection_id());
            let charges = auth.allocations().snapshot().active_public;
            let identity = Identity::current().unwrap();
            let key = Arc::new(ServerKey::generate().unwrap());
            let discovery = Discovery::for_server(&identity, h.instance_id(), key.fingerprint()).unwrap();
            let capability = ServerCapabilityToken::create(&identity).unwrap();
            let listener = create_public_pipe(&discovery.pipe_name, &identity, true, &capability).unwrap();
            let cancel = Arc::new(CancelEvent::new().unwrap());
            let supervisor = ConnectionSupervisor::new(auth.clone(), cancel.clone()).unwrap();
            let accept_auth = auth.clone();
            let accept_cancel = cancel.clone();
            let accept_supervisor = supervisor.clone();
            let accept_discovery = discovery.clone();
            let accept_identity = identity.clone();
            let accept = std::thread::spawn(move || run_supervised_accept_guarded(
                &accept_auth, &accept_cancel, &accept_supervisor,
                || accept_loop(accept_discovery.pipe_name, accept_identity, capability, key,
                    accept_discovery.instance_id, accept_auth.clone(), accept_cancel.clone(),
                    accept_supervisor.clone(), listener)));
            let (release, stopping) = stop(&h, fail);
            // Capacity exhaustion must not hide the normal reservation refusal.
            let fill = auth.allocations().claim(AllocationPool::ActivePublic,
                super::super::admission::ACTIVE_PUBLIC_BYTES - charges).unwrap();
            let client = open_client_pipe(&discovery.pipe_name).unwrap();
            assert_eq!(read_frame(client.raw(), &[cancel.raw()]), Err(IoError::Eof));
            drop(fill);
            assert_eq!(unsafe { WaitForSingleObject(cancel.raw(), 0) }, WAIT_TIMEOUT);
            assert!(!accept.is_finished());
            assert!(auth.generation_is_open() && existing.send_if_current());
            assert_eq!(auth.testing_connection_snapshot(&existing.connection_id()), before);
            assert_eq!(auth.record_count(), 1);
            assert_eq!(auth.allocations().snapshot().active_public, charges);
            release.send(()).unwrap();
            let stopped = stopping.join().unwrap();
            if fail {
                assert_eq!(stopped.error.0.as_ref().unwrap().code(), ErrorCode::RuntimeFailed);
                assert!(auth.generation_is_open());
                // The same real listener must still authenticate a fresh attempt.
                let fresh = open_client_pipe(&discovery.pipe_name).unwrap();
                let challenge = random_challenge().unwrap();
                write_frame(fresh.raw(), &encode_request(&challenge), &[cancel.raw()]).unwrap();
                let proof = read_frame(fresh.raw(), &[cancel.raw()]).unwrap();
                verify_response(&proof, discovery.validate_for(&identity).unwrap(),
                    &discovery.instance_id, &discovery.pipe_name, &challenge,
                    unsafe { GetCurrentProcessId() }, unsafe { GetCurrentProcessId() }).unwrap();
                let command = request(&h, "capabilities.get");
                write_frame(fresh.raw(), &serde_json::to_vec(&command).unwrap(), &[cancel.raw()]).unwrap();
                let response = parse_response(&command, &read_frame(fresh.raw(), &[cancel.raw()]).unwrap()).unwrap();
                assert!(response.accepted);
                drop(fresh);
            } else { assert!(stopped.accepted); }
            cancel.signal();
            assert_eq!(accept.join().unwrap(), Ok(()));
            assert_eq!(supervisor.reap_completed(), Ok(0));
        }
    }
}
