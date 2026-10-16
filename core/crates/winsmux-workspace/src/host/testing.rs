//! Windows-only test support for real pipe, token, and inheritance paths.
//!
//! This module is compiled only for debug builds. It does not add a runtime
//! switch that can weaken the production public-pipe ACL.

use super::io::{
    connect_after_start, connect_overlapped, decode_length, read_exact,
    read_exact_after_each_start, read_frame, read_once_after_start, write_all, write_frame,
    write_frame_after_header, write_once_after_start, CancelEvent, IoError, IoStart, OwnedHandle,
    WriteBodyHold,
};
use super::security::{
    token_group_attributes, token_identity, token_logon, token_user, verify_pipe_peer, Identity,
    PeerTrace, SecurityDescriptor, SecurityMode, ServerCapabilityToken, PIPE_DATA_ACCESS,
};
use super::server_identity::{
    encode_request as encode_auth_request, parse_request as parse_auth_request, random_challenge,
    verify_response as verify_auth_response, ServerKey, AUTH_REQUEST_BYTES, AUTH_RESPONSE_BYTES,
};
use super::windows::{
    close_and_collect_host_threads_for_test, close_on_owner_eof_for_test, create_pipe,
    create_private_channel_for_test, finish_host_result_for_test,
    handle_public_connection_observed, run_accept_guarded_for_test, ConnectionCheckpoint,
    ConnectionObserver, ProductClient, ProductHost,
};
use super::{
    process::{spawn_inheritance_helper, ChildProcess},
    Discovery, HostError,
};
use crate::auth::Authorization;
use crate::contract::{InstanceId, MAX_MESSAGE_BYTES};
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use windows_sys::Win32::Foundation::{
    CompareObjectHandles, GetHandleInformation, GetLastError, SetHandleInformation,
    ERROR_ACCESS_DENIED, ERROR_INVALID_HANDLE, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE,
    WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::{
    CreateRestrictedToken, ImpersonateAnonymousToken, ImpersonateLoggedOnUser, LogonUserW,
    RevertToSelf, DISABLE_MAX_PRIVILEGE, LOGON32_LOGON_NEW_CREDENTIALS, LOGON32_PROVIDER_WINNT50,
    SECURITY_ATTRIBUTES, SID_AND_ATTRIBUTES, TOKEN_QUERY,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileType, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, FILE_TYPE_PIPE,
    OPEN_EXISTING, PIPE_ACCESS_DUPLEX, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT, WRITE_DAC,
    WRITE_OWNER,
};
use windows_sys::Win32::System::Pipes::{
    CreateNamedPipeW, CreatePipe, GetNamedPipeClientProcessId, GetNamedPipeServerProcessId,
    PeekNamedPipe, WaitNamedPipeW, NMPWAIT_WAIT_FOREVER, PIPE_READMODE_BYTE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, CreateMutexExW, GetCurrentProcessId, GetCurrentThread, OpenEventW,
    OpenThreadToken, ReleaseMutex, SetEvent, WaitForSingleObject, EVENT_MODIFY_STATE, INFINITE,
    MUTEX_MODIFY_STATE,
};

const BODY_MARKER: &[u8] = b"TASK862_BODY_MUST_REMAIN_UNREAD";
pub(crate) const HANDLE_PROBE_REQUEST: &str = "WINSMUX_TASK862_HANDLE_PROBE";
pub(crate) const HANDLE_PROBE_READY: &[u8] = b"TASK862_HANDLE_PROBE_READY";
const HANDLE_PROBE_SENTINEL: &str = "WINSMUX_TASK862_SENTINEL_HANDLE";
const HANDLE_PROBE_SENTINEL_NAME: &str = "WINSMUX_TASK862_SENTINEL_NAME";
const HANDLE_PROBE_LAUNCHER_PID: &str = "WINSMUX_TASK862_LAUNCHER_PID";

pub(crate) struct LauncherInheritanceProbe {
    sentinel: OwnedHandle,
}

impl LauncherInheritanceProbe {
    pub(crate) fn start(identity: &Identity) -> Result<Option<Self>, HostError> {
        if std::env::var(HANDLE_PROBE_REQUEST).as_deref() != Ok("1") {
            return Ok(None);
        }
        let name = format!(r"Local\winsmux-task862-sentinel-{}", uuid::Uuid::new_v4());
        let wide_name = wide(&name);
        let mut descriptor = SecurityDescriptor::new(identity, SecurityMode::CurrentLogon)
            .map_err(|_| HostError::Startup)?;
        let attributes = descriptor.attributes(true);
        let sentinel = unsafe { CreateEventW(&attributes, 1, 0, wide_name.as_ptr()) };
        let sentinel =
            unsafe { OwnedHandle::from_raw(sentinel) }.map_err(|_| HostError::Startup)?;
        std::env::set_var(
            HANDLE_PROBE_SENTINEL,
            format!("{:x}", sentinel.raw() as usize),
        );
        std::env::set_var(HANDLE_PROBE_SENTINEL_NAME, name);
        std::env::set_var(
            HANDLE_PROBE_LAUNCHER_PID,
            unsafe { GetCurrentProcessId() }.to_string(),
        );
        Ok(Some(Self { sentinel }))
    }

    pub(crate) fn child_spawned(&self) -> Result<(), HostError> {
        clear_probe_child_environment();
        if unsafe { SetHandleInformation(self.sentinel.raw(), HANDLE_FLAG_INHERIT, 0) } == 0 {
            return Err(HostError::Startup);
        }
        Ok(())
    }

    pub(crate) fn verify_ready(&self, message: &[u8]) -> Result<(), HostError> {
        let mut flags = 0u32;
        if message != HANDLE_PROBE_READY
            || unsafe { GetHandleInformation(self.sentinel.raw(), &mut flags) } == 0
            || flags & HANDLE_FLAG_INHERIT != 0
        {
            return Err(HostError::Startup);
        }
        Ok(())
    }
}

impl Drop for LauncherInheritanceProbe {
    fn drop(&mut self) {
        clear_probe_child_environment();
    }
}

fn clear_probe_child_environment() {
    for name in [
        HANDLE_PROBE_SENTINEL,
        HANDLE_PROBE_SENTINEL_NAME,
        HANDLE_PROBE_LAUNCHER_PID,
    ] {
        std::env::remove_var(name);
    }
}

pub(crate) struct InheritanceProbe {
    release: OwnedHandle,
    child: Option<ChildProcess>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SentinelObservation {
    Absent,
    Present,
}

fn classify_sentinel_observation(
    result: Result<(), u32>,
) -> Result<SentinelObservation, HostError> {
    if result.is_ok() {
        Ok(SentinelObservation::Present)
    } else if result == Err(ERROR_INVALID_HANDLE) {
        Ok(SentinelObservation::Absent)
    } else {
        Err(HostError::Startup)
    }
}

fn observe_sentinel_handle(handle: HANDLE) -> Result<SentinelObservation, HostError> {
    let mut flags = 0u32;
    if unsafe { GetHandleInformation(handle, &mut flags) } != 0 {
        return Ok(SentinelObservation::Present);
    }
    let error = unsafe { GetLastError() };
    classify_sentinel_observation(Err(error))
}

fn verify_sentinel_not_inherited<Opened, Observe, Open, Same>(
    observe: Observe,
    open: Open,
    same_object: Same,
) -> Result<(), HostError>
where
    Observe: FnOnce() -> Result<SentinelObservation, HostError>,
    Open: FnOnce() -> Result<Opened, HostError>,
    Same: FnOnce(&Opened) -> bool,
{
    // Observe before opening by name: OpenEventW may reuse an absent handle's value.
    let observation = observe()?;
    let opened = open()?;
    if observation == SentinelObservation::Present && same_object(&opened) {
        return Err(HostError::Startup);
    }
    Ok(())
}

#[cfg(test)]
mod inheritance_probe_tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn sentinel_observation_distinguishes_absence_from_failure() {
        assert!(matches!(
            classify_sentinel_observation(Ok(())),
            Ok(SentinelObservation::Present)
        ));
        assert!(matches!(
            classify_sentinel_observation(Err(ERROR_INVALID_HANDLE)),
            Ok(SentinelObservation::Absent)
        ));
        assert!(classify_sentinel_observation(Err(ERROR_ACCESS_DENIED)).is_err());
        assert!(classify_sentinel_observation(Err(0)).is_err());
    }

    #[test]
    fn sentinel_check_observes_before_open_and_handles_numeric_reuse() {
        for (observation, opened_value, reject, compare) in [
            (SentinelObservation::Absent, 0x100usize, false, false),
            (SentinelObservation::Present, 0x100usize, true, true),
            (SentinelObservation::Present, 0x200usize, false, true),
        ] {
            let calls = RefCell::new(Vec::new());
            let result = verify_sentinel_not_inherited(
                || {
                    calls.borrow_mut().push("observe");
                    Ok(observation)
                },
                || {
                    calls.borrow_mut().push("open");
                    Ok(opened_value)
                },
                |opened| {
                    calls.borrow_mut().push("compare");
                    *opened == 0x100
                },
            );
            assert_eq!(result.is_err(), reject);
            let expected = if compare {
                vec!["observe", "open", "compare"]
            } else {
                vec!["observe", "open"]
            };
            assert_eq!(*calls.borrow(), expected);
        }
    }

    #[test]
    fn sentinel_check_fails_closed_when_observation_or_name_open_fails() {
        let calls = RefCell::new(Vec::new());
        let observation_failed = verify_sentinel_not_inherited(
            || {
                calls.borrow_mut().push("observe");
                Err(HostError::Startup)
            },
            || {
                calls.borrow_mut().push("open");
                Ok(0x100usize)
            },
            |_| {
                calls.borrow_mut().push("compare");
                true
            },
        );
        assert!(observation_failed.is_err());
        assert_eq!(*calls.borrow(), vec!["observe"]);

        calls.borrow_mut().clear();
        let name_open_failed = verify_sentinel_not_inherited(
            || {
                calls.borrow_mut().push("observe");
                Ok(SentinelObservation::Absent)
            },
            || {
                calls.borrow_mut().push("open");
                Err::<usize, _>(HostError::Startup)
            },
            |_| {
                calls.borrow_mut().push("compare");
                true
            },
        );
        assert!(name_open_failed.is_err());
        assert_eq!(*calls.borrow(), vec!["observe", "open"]);
    }
}

impl InheritanceProbe {
    pub(crate) fn start(owner: HANDLE) -> Result<Option<Self>, HostError> {
        if std::env::var(HANDLE_PROBE_REQUEST).as_deref() != Ok("1") {
            return Ok(None);
        }
        let sentinel_raw = parse_handle_environment(HANDLE_PROBE_SENTINEL)?;
        let sentinel_name =
            std::env::var(HANDLE_PROBE_SENTINEL_NAME).map_err(|_| HostError::Startup)?;
        let launcher_pid = std::env::var(HANDLE_PROBE_LAUNCHER_PID)
            .map_err(|_| HostError::Startup)?
            .parse::<u32>()
            .map_err(|_| HostError::Startup)?;

        verify_sentinel_not_inherited(
            || observe_sentinel_handle(sentinel_raw),
            || {
                unsafe {
                    OwnedHandle::from_raw(OpenEventW(
                        EVENT_MODIFY_STATE,
                        0,
                        wide(&sentinel_name).as_ptr(),
                    ))
                }
                .map_err(|_| HostError::Startup)
            },
            |opened| unsafe { CompareObjectHandles(sentinel_raw, opened.raw()) } != 0,
        )?;
        let mut owner_flags = 0u32;
        if unsafe { GetHandleInformation(owner, &mut owner_flags) } == 0
            || owner_flags & HANDLE_FLAG_INHERIT != 0
        {
            return Err(HostError::Startup);
        }

        let mut inheritable = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        let mut report_read = null_mut();
        let mut report_write = null_mut();
        if unsafe { CreatePipe(&mut report_read, &mut report_write, &mut inheritable, 0) } == 0 {
            return Err(HostError::Startup);
        }
        let report_read =
            unsafe { OwnedHandle::from_raw(report_read) }.map_err(|_| HostError::Startup)?;
        let report_write =
            unsafe { OwnedHandle::from_raw(report_write) }.map_err(|_| HostError::Startup)?;
        if unsafe { SetHandleInformation(report_read.raw(), HANDLE_FLAG_INHERIT, 0) } == 0 {
            return Err(HostError::Startup);
        }
        let release = unsafe { OwnedHandle::from_raw(CreateEventW(&inheritable, 1, 0, null())) }
            .map_err(|_| HostError::Startup)?;
        let child =
            spawn_inheritance_helper(owner, report_write.raw(), release.raw(), launcher_pid)
                .map_err(|_| HostError::Startup)?;
        drop(report_write);

        let probe = Self {
            release,
            child: Some(child),
        };
        let mut owner_access = 0xffu8;
        let mut transferred = 0u32;
        let read = unsafe {
            ReadFile(
                report_read.raw(),
                &mut owner_access,
                1,
                &mut transferred,
                null_mut(),
            )
        };
        if read == 0 || transferred != 1 || owner_access != 0 {
            probe.release_helper();
            return Err(HostError::Startup);
        }
        Ok(Some(probe))
    }

    pub(crate) fn finish(mut self) -> Result<(), HostError> {
        self.release_helper();
        let Some(child) = self.child.take() else {
            return Err(HostError::Startup);
        };
        match child.wait().map_err(|_| HostError::Transport)? {
            0 => Ok(()),
            _ => Err(HostError::Transport),
        }
    }

    fn release_helper(&self) {
        unsafe {
            SetEvent(self.release.raw());
        }
    }
}

impl Drop for InheritanceProbe {
    fn drop(&mut self) {
        self.release_helper();
        if let Some(child) = self.child.take() {
            let _ = child.wait();
        }
    }
}

fn parse_handle_environment(name: &str) -> Result<HANDLE, HostError> {
    let raw = std::env::var(name).map_err(|_| HostError::Startup)?;
    let raw = usize::from_str_radix(&raw, 16).map_err(|_| HostError::Startup)? as HANDLE;
    if raw.is_null() || raw == INVALID_HANDLE_VALUE {
        Err(HostError::Startup)
    } else {
        Ok(raw)
    }
}

pub fn run_inheritance_helper(
    owner: &str,
    report: &str,
    release: &str,
    launcher_pid: &str,
) -> Result<(), HostError> {
    let owner = parse_handle_argument(owner)?;
    let report = parse_handle_argument(report)?;
    let release = parse_handle_argument(release)?;
    let launcher_pid = launcher_pid
        .parse::<u32>()
        .map_err(|_| HostError::Startup)?;
    let report = unsafe { OwnedHandle::from_raw(report) }.map_err(|_| HostError::Startup)?;
    let release = unsafe { OwnedHandle::from_raw(release) }.map_err(|_| HostError::Startup)?;
    let mut report_flags = 0u32;
    let mut release_flags = 0u32;
    if unsafe { GetHandleInformation(report.raw(), &mut report_flags) } == 0
        || unsafe { GetHandleInformation(release.raw(), &mut release_flags) } == 0
        || report_flags & HANDLE_FLAG_INHERIT == 0
        || release_flags & HANDLE_FLAG_INHERIT == 0
    {
        return Err(HostError::Startup);
    }

    let mut peer_pid = 0u32;
    let owner_access = u8::from(
        unsafe { GetFileType(owner) } == FILE_TYPE_PIPE
            && unsafe { GetNamedPipeClientProcessId(owner, &mut peer_pid) } != 0
            && peer_pid == launcher_pid,
    );
    let mut transferred = 0u32;
    if unsafe { WriteFile(report.raw(), &owner_access, 1, &mut transferred, null_mut()) } == 0
        || transferred != 1
        || unsafe { WaitForSingleObject(release.raw(), INFINITE) } != WAIT_OBJECT_0
    {
        return Err(HostError::Transport);
    }
    Ok(())
}

fn parse_handle_argument(value: &str) -> Result<HANDLE, HostError> {
    let raw = usize::from_str_radix(value, 16).map_err(|_| HostError::Startup)? as HANDLE;
    if raw.is_null() || raw == INVALID_HANDLE_VALUE {
        Err(HostError::Startup)
    } else {
        Ok(raw)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeError {
    CurrentIdentity,
    TokenCreate,
    TokenQuery,
    TokenShape,
    Impersonate,
    Revert,
    PipeCreate,
    PipeOpen(u32),
    PipeConnect,
    PipeIo,
    PipePeek,
    Protocol,
    Thread,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerProbeEvidence {
    pub failure: String,
    pub impersonated: bool,
    pub user_checked: bool,
    pub logon_checked: bool,
    pub reverted: bool,
    pub body_marker_unread: bool,
    pub authorization_records: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OsAuthenticationEvidence {
    pub anonymous_user_differs: bool,
    pub anonymous_has_no_logon: bool,
    pub anonymous_production_acl_denied: bool,
    pub anonymous_peer: PeerProbeEvidence,
    pub new_credentials_same_user: bool,
    pub new_credentials_has_logon: bool,
    pub new_credentials_logon_differs: bool,
    pub new_credentials_current_logon_group_attributes: Option<u32>,
    pub new_credentials_current_logon_group_enabled: bool,
    pub new_credentials_current_logon_group_deny_only: bool,
    pub new_credentials_production_acl_allowed: bool,
    pub new_credentials_peer: PeerProbeEvidence,
    pub restricted_same_user: bool,
    pub restricted_logon_unchanged: bool,
    pub restricted_current_logon_group_attributes: Option<u32>,
    pub restricted_current_logon_group_enabled: bool,
    pub restricted_current_logon_group_deny_only: bool,
    pub restricted_production_acl_denied: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerCapabilityEvidence {
    pub same_user: bool,
    pub distinct_logon: bool,
    pub logon_group_enabled: bool,
    pub logon_group_not_deny_only: bool,
    pub token_not_inherited: bool,
    pub first_instance_created: bool,
    pub second_instance_created: bool,
    pub original_server_create_denied: bool,
    pub separate_server_token_create_denied: bool,
    pub original_data_connect_succeeded: bool,
    pub original_write_dac_denied: bool,
    pub original_write_owner_denied: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RogueProof {
    KeySubstitution,
    SignatureMutation,
    ReplayNonce,
    InstanceMismatch,
    PipeNameMismatch,
    ClientPidMismatch,
    ServerPidMismatch,
    SameLogonRelay,
    WrongLength,
    WrongMagic,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RogueEvidence {
    pub authentication_request_bytes: usize,
    pub request_bytes_after_proof: usize,
}

pub struct RogueServer {
    discovery: Vec<u8>,
    thread: Option<std::thread::JoinHandle<Result<RogueEvidence, ProbeError>>>,
}

pub struct SlowPublicClient {
    _handle: OwnedHandle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlowStage {
    AuthenticationHeader,
    AuthenticationBody,
    ProofReader,
    RequestHeader,
    RequestBody,
    ResponseReader,
}

pub struct MutexHandleProbe {
    _handle: OwnedHandle,
}

pub struct MutexOwnershipProbe {
    handle: OwnedHandle,
}

impl Drop for MutexOwnershipProbe {
    fn drop(&mut self) {
        unsafe {
            ReleaseMutex(self.handle.raw());
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FramingEvidence {
    pub zero_length_rejected: bool,
    pub over_limit_rejected: bool,
    pub exact_limit_accepted: bool,
    pub split_header_and_body_round_trip: bool,
    pub consecutive_frames_preserved: bool,
    pub partial_eof_rejected: bool,
    pub pending_read_cancelled_and_drained: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationIoEvidence {
    pub read_prestart_cancelled_without_consuming: bool,
    pub read_sync_completion_cancelled: bool,
    pub read_pending_completion_cancelled_and_drained: bool,
    pub read_partial_cancelled: bool,
    pub write_prestart_cancelled_without_writing: bool,
    pub write_sync_completion_cancelled: bool,
    pub write_pending_completion_cancelled_and_drained: bool,
    pub write_partial_frame_cancelled: bool,
    pub connect_prestart_cancelled: bool,
    pub connect_already_connected_cancelled: bool,
    pub connect_pending_completion_cancelled_and_drained: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationClosureEvidence {
    pub owner_eof_cases: usize,
    pub close_before_authentication_read: bool,
    pub authentication_permit_then_close_cancelled_read: bool,
    pub close_before_proof_send: bool,
    pub proof_permit_then_close_cancelled_write: bool,
    pub late_attach_records: usize,
    pub late_response_bytes: u32,
    pub late_worker_joined: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostEpilogueEvidence {
    pub startup_failure_preserved: bool,
    pub protocol_failure_preserved: bool,
    pub transport_failure_preserved: bool,
    pub owner_eof_remains_success: bool,
    pub owner_cancel_remains_cancelled: bool,
    pub accept_error_closed_cancelled_and_collected: bool,
    pub accept_panic_closed_cancelled_and_collected: bool,
    pub worker_panic_did_not_skip_later_join: bool,
    pub first_error_won_after_later_failures: bool,
}

struct BarrierObserver {
    target: ConnectionCheckpoint,
    reached: mpsc::Sender<()>,
    release: mpsc::Receiver<()>,
    trace: Arc<Mutex<Vec<ConnectionCheckpoint>>>,
}

impl ConnectionObserver for BarrierObserver {
    fn reached(&mut self, checkpoint: ConnectionCheckpoint) {
        self.trace
            .lock()
            .expect("connection trace lock")
            .push(checkpoint);
        if checkpoint == self.target {
            self.reached.send(()).expect("report connection checkpoint");
            self.release.recv().expect("release connection checkpoint");
        }
    }
}

struct ObservedConnection {
    client: OwnedHandle,
    identity: Identity,
    discovery: Discovery,
    authentication: [u8; AUTH_REQUEST_BYTES],
    authorization: Arc<Authorization>,
    host_cancel: Arc<CancelEvent>,
    worker: Option<std::thread::JoinHandle<()>>,
    reached: mpsc::Receiver<()>,
    release: mpsc::Sender<()>,
    trace: Arc<Mutex<Vec<ConnectionCheckpoint>>>,
}

struct ClosureCaseEvidence {
    trace: Vec<ConnectionCheckpoint>,
    owner_eof: bool,
    records: usize,
    response_bytes: u32,
    worker_joined: bool,
}

#[derive(Clone, Copy)]
enum AcceptTerminal {
    Success,
    Error,
    Panic,
}

struct EpilogueCaseEvidence {
    result: Result<(), HostError>,
    generation_closed: bool,
    guard_closed_before_cancel: bool,
    later_worker_completed: bool,
}

enum ProbeToken {
    Anonymous,
    LoggedOn(OwnedHandle),
}

impl ProbeToken {
    fn impersonate(&self) -> Result<(), ProbeError> {
        let impersonated = match self {
            Self::Anonymous => unsafe { ImpersonateAnonymousToken(GetCurrentThread()) },
            Self::LoggedOn(token) => unsafe { ImpersonateLoggedOnUser(token.raw()) },
        };
        if impersonated == 0 {
            Err(ProbeError::Impersonate)
        } else {
            Ok(())
        }
    }

    fn pipe_sqos(&self) -> u32 {
        SECURITY_IDENTIFICATION
    }
}

fn with_impersonation<T>(
    token: &ProbeToken,
    action: impl FnOnce() -> Result<T, ProbeError>,
) -> Result<T, ProbeError> {
    token.impersonate()?;
    let result = action();
    if unsafe { RevertToSelf() } == 0 {
        return Err(ProbeError::Revert);
    }
    result
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn create_new_credentials() -> Result<OwnedHandle, ProbeError> {
    let username = wide("winsmux_probe_nonexistent");
    let domain = wide(".");
    let credential = wide(&uuid::Uuid::new_v4().simple().to_string());
    let mut token = null_mut();
    let created = unsafe {
        LogonUserW(
            username.as_ptr(),
            domain.as_ptr(),
            credential.as_ptr(),
            LOGON32_LOGON_NEW_CREDENTIALS,
            LOGON32_PROVIDER_WINNT50,
            &mut token,
        )
    };
    if created == 0 {
        return Err(ProbeError::TokenCreate);
    }
    unsafe { OwnedHandle::from_raw(token) }.map_err(|_| ProbeError::TokenCreate)
}

fn restrict_current_logon(
    source: &OwnedHandle,
    current_logon: &super::security::Sid,
) -> Result<OwnedHandle, ProbeError> {
    let disabled = [SID_AND_ATTRIBUTES {
        Sid: current_logon.as_ptr(),
        Attributes: 0,
    }];
    let mut token = null_mut();
    if unsafe {
        CreateRestrictedToken(
            source.raw(),
            DISABLE_MAX_PRIVILEGE,
            disabled.len() as u32,
            disabled.as_ptr(),
            0,
            null_mut(),
            0,
            null_mut(),
            &mut token,
        )
    } == 0
    {
        return Err(ProbeError::TokenCreate);
    }
    unsafe { OwnedHandle::from_raw(token) }.map_err(|_| ProbeError::TokenCreate)
}

fn current_thread_token() -> Result<OwnedHandle, ProbeError> {
    let mut token = null_mut();
    if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } == 0 {
        return Err(ProbeError::TokenQuery);
    }
    unsafe { OwnedHandle::from_raw(token) }.map_err(|_| ProbeError::TokenQuery)
}

fn anonymous_shape(expected: Identity) -> Result<(bool, bool), ProbeError> {
    std::thread::spawn(move || {
        with_impersonation(&ProbeToken::Anonymous, || {
            let token = current_thread_token()?;
            let user = token_user(token.raw()).map_err(|_| ProbeError::TokenQuery)?;
            let has_no_logon = token_logon(token.raw()).is_err();
            Ok((!user.equals(&expected.user), has_no_logon))
        })
    })
    .join()
    .map_err(|_| ProbeError::Thread)?
}

fn new_credentials_shape(
    expected: &Identity,
    token: &OwnedHandle,
) -> Result<(bool, bool, bool), ProbeError> {
    let actual = token_identity(token.raw()).map_err(|_| ProbeError::TokenQuery)?;
    Ok((
        actual.user.equals(&expected.user),
        !actual.logon.bytes().is_empty(),
        !actual.logon.equals(&expected.logon),
    ))
}

fn open_pipe(name: &str, sqos: u32, desired_access: u32) -> Result<OwnedHandle, u32> {
    let name = wide(name);
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            desired_access,
            0,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | sqos,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        Err(unsafe { GetLastError() })
    } else {
        unsafe { OwnedHandle::from_raw(handle) }.map_err(|_| unsafe { GetLastError() })
    }
}

fn create_public_pipe(
    name: &str,
    expected: &Identity,
    capability: &ServerCapabilityToken,
    first: bool,
) -> Result<OwnedHandle, ProbeError> {
    capability
        .while_impersonating(|| {
            create_pipe(
                name,
                expected,
                first,
                true,
                SecurityMode::PublicPipe {
                    server_logon: capability.logon(),
                },
                PIPE_UNLIMITED_INSTANCES,
            )
        })
        .map_err(|_| ProbeError::PipeCreate)
}

fn create_additional_instance(name: &str) -> Result<OwnedHandle, u32> {
    let name = wide(name);
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            MAX_MESSAGE_BYTES as u32,
            MAX_MESSAGE_BYTES as u32,
            0,
            null(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        Err(unsafe { GetLastError() })
    } else {
        unsafe { OwnedHandle::from_raw(handle) }.map_err(|_| unsafe { GetLastError() })
    }
}

fn parse_discovery(bytes: &[u8]) -> Result<(Discovery, Identity), ProbeError> {
    let discovery: Discovery = serde_json::from_slice(bytes).map_err(|_| ProbeError::Protocol)?;
    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    discovery
        .validate_for(&identity)
        .map_err(|_| ProbeError::Protocol)?;
    Ok((discovery, identity))
}

fn open_discovery_pipe(
    discovery: &Discovery,
    identity: &Identity,
) -> Result<OwnedHandle, ProbeError> {
    discovery
        .validate_for(identity)
        .map_err(|_| ProbeError::Protocol)?;
    let name = wide(&discovery.pipe_name);
    if unsafe { WaitNamedPipeW(name.as_ptr(), NMPWAIT_WAIT_FOREVER) } == 0 {
        return Err(ProbeError::PipeOpen(unsafe { GetLastError() }));
    }
    open_pipe(
        &discovery.pipe_name,
        SECURITY_IDENTIFICATION,
        PIPE_DATA_ACCESS,
    )
    .map_err(ProbeError::PipeOpen)
}

fn different_pid(pid: u32) -> u32 {
    if pid == u32::MAX {
        1
    } else {
        pid + 1
    }
}

fn count_until_eof(handle: HANDLE) -> Result<usize, ProbeError> {
    let mut count = 0usize;
    let mut byte = [0u8; 1];
    loop {
        match read_exact(handle, &mut byte, &[]) {
            Ok(()) => count += 1,
            Err(IoError::Eof) => return Ok(count),
            Err(_) => return Err(ProbeError::PipeIo),
        }
    }
}

fn serve_rogue(
    server: OwnedHandle,
    discovery: Discovery,
    signing_key: ServerKey,
    kind: RogueProof,
) -> Result<RogueEvidence, ProbeError> {
    connect_overlapped(server.raw(), &[]).map_err(|_| ProbeError::PipeConnect)?;
    let mut header = [0u8; 4];
    read_exact(server.raw(), &mut header, &[]).map_err(|_| ProbeError::PipeIo)?;
    if u32::from_le_bytes(header) as usize != AUTH_REQUEST_BYTES {
        return Err(ProbeError::Protocol);
    }
    let mut authentication = [0u8; AUTH_REQUEST_BYTES];
    read_exact(server.raw(), &mut authentication, &[]).map_err(|_| ProbeError::PipeIo)?;
    let challenge = parse_auth_request(&authentication).map_err(|_| ProbeError::Protocol)?;
    let mut client_pid = 0u32;
    if unsafe { GetNamedPipeClientProcessId(server.raw(), &mut client_pid) } == 0 || client_pid == 0
    {
        return Err(ProbeError::PipeIo);
    }
    let server_pid = unsafe { GetCurrentProcessId() };

    let mut signed_challenge = challenge;
    if kind == RogueProof::ReplayNonce {
        signed_challenge[0] ^= 1;
    }
    let signed_instance = if kind == RogueProof::InstanceMismatch {
        InstanceId::new(uuid::Uuid::new_v4().to_string()).map_err(|_| ProbeError::Protocol)?
    } else {
        discovery.instance_id.clone()
    };
    let signed_name = if kind == RogueProof::PipeNameMismatch {
        format!("{}-relayed", discovery.pipe_name)
    } else {
        discovery.pipe_name.clone()
    };
    let signed_client_pid = if kind == RogueProof::ClientPidMismatch {
        different_pid(client_pid)
    } else if kind == RogueProof::SameLogonRelay {
        server_pid
    } else {
        client_pid
    };
    let signed_server_pid = if kind == RogueProof::ServerPidMismatch {
        different_pid(server_pid)
    } else if kind == RogueProof::SameLogonRelay {
        client_pid
    } else {
        server_pid
    };
    let mut response = signing_key
        .response(
            &signed_instance,
            &signed_name,
            &signed_challenge,
            signed_client_pid,
            signed_server_pid,
        )
        .map_err(|_| ProbeError::PipeIo)?;
    if kind == RogueProof::SignatureMutation {
        response[AUTH_RESPONSE_BYTES - 1] ^= 1;
    }
    if kind == RogueProof::WrongMagic {
        response[0] ^= 1;
    }
    if kind == RogueProof::WrongLength {
        let short = AUTH_RESPONSE_BYTES - 1;
        write_all(server.raw(), &(short as u32).to_le_bytes(), &[])
            .map_err(|_| ProbeError::PipeIo)?;
        write_all(server.raw(), &response[..short], &[]).map_err(|_| ProbeError::PipeIo)?;
    } else {
        write_frame(server.raw(), &response, &[]).map_err(|_| ProbeError::PipeIo)?;
    }
    let request_bytes_after_proof = count_until_eof(server.raw())?;
    Ok(RogueEvidence {
        authentication_request_bytes: authentication.len(),
        request_bytes_after_proof,
    })
}

impl RogueServer {
    pub fn start(kind: RogueProof) -> Result<Self, ProbeError> {
        let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
        let advertised_key = ServerKey::generate().map_err(|_| ProbeError::PipeCreate)?;
        let instance_id =
            InstanceId::new(uuid::Uuid::new_v4().to_string()).map_err(|_| ProbeError::Protocol)?;
        let discovery = Discovery::for_server(&identity, instance_id, advertised_key.fingerprint())
            .map_err(|_| ProbeError::Protocol)?;
        let signing_key = if kind == RogueProof::KeySubstitution {
            ServerKey::generate().map_err(|_| ProbeError::PipeCreate)?
        } else {
            advertised_key
        };
        Self::start_with(discovery, identity, signing_key, kind)
    }

    pub fn start_for_stale_discovery(bytes: &[u8]) -> Result<Self, ProbeError> {
        let (discovery, identity) = parse_discovery(bytes)?;
        let signing_key = ServerKey::generate().map_err(|_| ProbeError::PipeCreate)?;
        Self::start_with(
            discovery,
            identity,
            signing_key,
            RogueProof::KeySubstitution,
        )
    }

    fn start_with(
        discovery: Discovery,
        identity: Identity,
        signing_key: ServerKey,
        kind: RogueProof,
    ) -> Result<Self, ProbeError> {
        let capability =
            ServerCapabilityToken::create(&identity).map_err(|_| ProbeError::TokenCreate)?;
        let server = create_public_pipe(&discovery.pipe_name, &identity, &capability, true)?;
        let bytes = serde_json::to_vec(&discovery).map_err(|_| ProbeError::Protocol)?;
        let thread = std::thread::spawn(move || serve_rogue(server, discovery, signing_key, kind));
        Ok(Self {
            discovery: bytes,
            thread: Some(thread),
        })
    }

    pub fn discovery(&self) -> &[u8] {
        &self.discovery
    }

    pub fn finish(mut self) -> Result<RogueEvidence, ProbeError> {
        self.thread
            .take()
            .ok_or(ProbeError::Thread)?
            .join()
            .map_err(|_| ProbeError::Thread)?
    }
}

impl SlowPublicClient {
    pub fn hold(
        discovery_bytes: &[u8],
        stage: SlowStage,
        request: &[u8],
    ) -> Result<Self, ProbeError> {
        let (discovery, identity) = parse_discovery(discovery_bytes)?;
        let handle = open_discovery_pipe(&discovery, &identity)?;
        let auth = encode_auth_request(&random_challenge().map_err(|_| ProbeError::PipeIo)?);
        match stage {
            SlowStage::AuthenticationHeader => {
                write_all(handle.raw(), &44u32.to_le_bytes()[..2], &[])
                    .map_err(|_| ProbeError::PipeIo)?;
            }
            SlowStage::AuthenticationBody => {
                write_all(handle.raw(), &44u32.to_le_bytes(), &[])
                    .map_err(|_| ProbeError::PipeIo)?;
                write_all(handle.raw(), &auth[..2], &[]).map_err(|_| ProbeError::PipeIo)?;
            }
            SlowStage::ProofReader => {
                write_frame(handle.raw(), &auth, &[]).map_err(|_| ProbeError::PipeIo)?;
            }
            SlowStage::RequestHeader | SlowStage::RequestBody | SlowStage::ResponseReader => {
                let mut server_pid = 0u32;
                if unsafe { GetNamedPipeServerProcessId(handle.raw(), &mut server_pid) } == 0
                    || server_pid == 0
                {
                    return Err(ProbeError::PipeIo);
                }
                let challenge = parse_auth_request(&auth).map_err(|_| ProbeError::Protocol)?;
                write_frame(handle.raw(), &auth, &[]).map_err(|_| ProbeError::PipeIo)?;
                let response = read_frame(handle.raw(), &[]).map_err(|_| ProbeError::PipeIo)?;
                let fingerprint = discovery
                    .validate_for(&identity)
                    .map_err(|_| ProbeError::Protocol)?;
                verify_auth_response(
                    &response,
                    fingerprint,
                    &discovery.instance_id,
                    &discovery.pipe_name,
                    &challenge,
                    unsafe { GetCurrentProcessId() },
                    server_pid,
                )
                .map_err(|_| ProbeError::Protocol)?;
                if request.is_empty() {
                    return Err(ProbeError::Protocol);
                }
                let header = (request.len() as u32).to_le_bytes();
                match stage {
                    SlowStage::RequestHeader => {
                        write_all(handle.raw(), &header[..2], &[])
                            .map_err(|_| ProbeError::PipeIo)?;
                    }
                    SlowStage::RequestBody => {
                        write_all(handle.raw(), &header, &[]).map_err(|_| ProbeError::PipeIo)?;
                        write_all(handle.raw(), &request[..request.len().min(2)], &[])
                            .map_err(|_| ProbeError::PipeIo)?;
                    }
                    SlowStage::ResponseReader => {
                        write_frame(handle.raw(), request, &[]).map_err(|_| ProbeError::PipeIo)?;
                    }
                    _ => unreachable!(),
                }
            }
        }
        Ok(Self { _handle: handle })
    }
}

pub fn canonical_discovery_json() -> Result<Vec<u8>, ProbeError> {
    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let key = ServerKey::generate().map_err(|_| ProbeError::PipeCreate)?;
    let instance =
        InstanceId::new(uuid::Uuid::new_v4().to_string()).map_err(|_| ProbeError::Protocol)?;
    let discovery = Discovery::for_server(&identity, instance, key.fingerprint())
        .map_err(|_| ProbeError::Protocol)?;
    serde_json::to_vec(&discovery).map_err(|_| ProbeError::Protocol)
}

fn mutex_handle(identity: &Identity) -> Result<OwnedHandle, ProbeError> {
    let name = format!(r"Local\winsmux-workspace-v1-{}", identity.logon_key());
    let wide = wide(&name);
    let mut descriptor = SecurityDescriptor::new(identity, SecurityMode::Mutex)
        .map_err(|_| ProbeError::PipeCreate)?;
    let attributes = descriptor.attributes(false);
    let raw = unsafe {
        CreateMutexExW(
            &attributes,
            wide.as_ptr(),
            0,
            MUTEX_MODIFY_STATE | 0x0010_0000,
        )
    };
    unsafe { OwnedHandle::from_raw(raw) }.map_err(|_| ProbeError::PipeCreate)
}

pub fn open_host_mutex_handle() -> Result<MutexHandleProbe, ProbeError> {
    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    Ok(MutexHandleProbe {
        _handle: mutex_handle(&identity)?,
    })
}

pub fn acquire_host_mutex_probe() -> Result<MutexOwnershipProbe, ProbeError> {
    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let handle = mutex_handle(&identity)?;
    match unsafe { WaitForSingleObject(handle.raw(), 0) } {
        WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(MutexOwnershipProbe { handle }),
        WAIT_TIMEOUT => Err(ProbeError::PipeCreate),
        _ => Err(ProbeError::PipeCreate),
    }
}

fn production_acl_denies(expected: &Identity, token: ProbeToken) -> Result<bool, ProbeError> {
    let name = format!(
        r"\\.\pipe\winsmux-workspace-acl-probe-{}",
        uuid::Uuid::new_v4()
    );
    let capability =
        ServerCapabilityToken::create(expected).map_err(|_| ProbeError::TokenCreate)?;
    let _server = create_public_pipe(&name, expected, &capability, true)?;
    std::thread::spawn(move || {
        let sqos = token.pipe_sqos();
        with_impersonation(&token, || match open_pipe(&name, sqos, PIPE_DATA_ACCESS) {
            Err(error) => Ok(error == ERROR_ACCESS_DENIED),
            Ok(_) => Ok(false),
        })
    })
    .join()
    .map_err(|_| ProbeError::Thread)?
}

#[derive(Clone, Copy)]
enum PeerProbeMode {
    Production,
    Permissive,
}

fn peer_probe(
    expected: &Identity,
    token: ProbeToken,
    mode: PeerProbeMode,
) -> Result<PeerProbeEvidence, ProbeError> {
    let name = format!(
        r"\\.\pipe\winsmux-workspace-peer-probe-{}",
        uuid::Uuid::new_v4()
    );
    let capability = match mode {
        PeerProbeMode::Production => {
            Some(ServerCapabilityToken::create(expected).map_err(|_| ProbeError::TokenCreate)?)
        }
        PeerProbeMode::Permissive => None,
    };
    let server = match &capability {
        Some(capability) => create_public_pipe(&name, expected, capability, true)?,
        None => create_pipe(&name, expected, true, true, SecurityMode::PermissiveTest, 1)
            .map_err(|_| ProbeError::PipeCreate)?,
    };
    let failure_cancel = Arc::new(CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?);
    let thread_cancel = failure_cancel.clone();
    let (release_sender, release_receiver) = mpsc::channel::<()>();
    let client = std::thread::spawn(move || {
        let sqos = token.pipe_sqos();
        let result = with_impersonation(&token, || {
            let pipe = open_pipe(&name, sqos, PIPE_DATA_ACCESS).map_err(ProbeError::PipeOpen)?;
            let header = (BODY_MARKER.len() as u32).to_le_bytes();
            write_all(pipe.raw(), &header, &[]).map_err(|_| ProbeError::PipeIo)?;
            write_all(pipe.raw(), BODY_MARKER, &[]).map_err(|_| ProbeError::PipeIo)?;
            release_receiver.recv().map_err(|_| ProbeError::Thread)?;
            Ok(())
        });
        if result.is_err() {
            thread_cancel.signal();
        }
        result
    });

    let probe = (|| {
        connect_overlapped(server.raw(), &[failure_cancel.raw()])
            .map_err(|_| ProbeError::PipeConnect)?;
        let mut header = [0u8; 4];
        read_exact(server.raw(), &mut header, &[failure_cancel.raw()])
            .map_err(|_| ProbeError::PipeIo)?;
        if u32::from_le_bytes(header) as usize != BODY_MARKER.len() {
            return Err(ProbeError::PipeIo);
        }

        let authorization = Authorization::new(Vec::new());
        let trace = PeerTrace::default();
        let peer = verify_pipe_peer(server.raw(), expected, Some(&trace));
        if let Ok(executable) = &peer {
            let cancellation = Arc::new(CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?);
            let _ = authorization.attach_verified(executable.clone(), cancellation);
        }

        let mut available = 0u32;
        if unsafe {
            PeekNamedPipe(
                server.raw(),
                null_mut(),
                0,
                null_mut(),
                &mut available,
                null_mut(),
            )
        } == 0
        {
            return Err(ProbeError::PipePeek);
        }
        let failure = match peer {
            Ok(_) => "Accepted".to_string(),
            Err(failure) => format!("{failure:?}"),
        };
        Ok(PeerProbeEvidence {
            failure,
            impersonated: trace.impersonated.load(Ordering::SeqCst),
            user_checked: trace.user_checked.load(Ordering::SeqCst),
            logon_checked: trace.logon_checked.load(Ordering::SeqCst),
            reverted: trace.reverted.load(Ordering::SeqCst),
            body_marker_unread: available as usize == BODY_MARKER.len(),
            authorization_records: authorization.record_count(),
        })
    })();

    let _ = release_sender.send(());
    let client_result = client.join().map_err(|_| ProbeError::Thread)?;
    client_result?;
    probe
}

fn connected_test_pipe() -> Result<(OwnedHandle, OwnedHandle), ProbeError> {
    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let name = format!(
        r"\\.\pipe\winsmux-workspace-frame-probe-{}",
        uuid::Uuid::new_v4()
    );
    let server = create_pipe(&name, &identity, true, true, SecurityMode::CurrentLogon, 1)
        .map_err(|_| ProbeError::PipeCreate)?;
    let client = open_pipe(&name, SECURITY_IDENTIFICATION, PIPE_DATA_ACCESS)
        .map_err(ProbeError::PipeOpen)?;
    connect_overlapped(server.raw(), &[]).map_err(|_| ProbeError::PipeConnect)?;
    Ok((server, client))
}

fn available_bytes(handle: HANDLE) -> Result<u32, ProbeError> {
    let mut available = 0u32;
    if unsafe {
        PeekNamedPipe(
            handle,
            null_mut(),
            0,
            null_mut(),
            &mut available,
            null_mut(),
        )
    } == 0
    {
        Err(ProbeError::PipePeek)
    } else {
        Ok(available)
    }
}

/// Exercise stream framing and cancellation against real overlapped named-pipe
/// handles. The split writes prove `read_exact` does not assume message-sized
/// reads, and the cancellation join proves the pending OVERLAPPED completed
/// before its stack storage and buffer were released.
pub fn run_framing_probes() -> Result<FramingEvidence, ProbeError> {
    let zero_length_rejected = decode_length(0u32.to_le_bytes()) == Err(IoError::Protocol);
    let over_limit_rejected =
        decode_length(((MAX_MESSAGE_BYTES + 1) as u32).to_le_bytes()) == Err(IoError::Protocol);
    let exact_limit_accepted =
        decode_length((MAX_MESSAGE_BYTES as u32).to_le_bytes()) == Ok(MAX_MESSAGE_BYTES);

    let (server, client) = connected_test_pipe()?;
    let split_writer = std::thread::spawn(move || {
        let first = b"split-frame";
        let first_header = (first.len() as u32).to_le_bytes();
        write_all(client.raw(), &first_header[..1], &[]).map_err(|_| ProbeError::PipeIo)?;
        write_all(client.raw(), &first_header[1..], &[]).map_err(|_| ProbeError::PipeIo)?;
        write_all(client.raw(), &first[..3], &[]).map_err(|_| ProbeError::PipeIo)?;
        write_all(client.raw(), &first[3..], &[]).map_err(|_| ProbeError::PipeIo)?;
        write_frame(client.raw(), b"second-frame", &[]).map_err(|_| ProbeError::PipeIo)
    });
    let first = read_frame(server.raw(), &[]).map_err(|_| ProbeError::PipeIo)?;
    let second = read_frame(server.raw(), &[]).map_err(|_| ProbeError::PipeIo)?;
    split_writer.join().map_err(|_| ProbeError::Thread)??;
    let split_header_and_body_round_trip = first == b"split-frame";
    let consecutive_frames_preserved = second == b"second-frame";

    let (server, client) = connected_test_pipe()?;
    let eof_writer = std::thread::spawn(move || {
        write_all(client.raw(), &5u32.to_le_bytes(), &[]).map_err(|_| ProbeError::PipeIo)?;
        write_all(client.raw(), b"xy", &[]).map_err(|_| ProbeError::PipeIo)
    });
    let partial_eof_rejected = read_frame(server.raw(), &[]) == Err(IoError::Eof);
    eof_writer.join().map_err(|_| ProbeError::Thread)??;

    let (server, _client) = connected_test_pipe()?;
    let cancellation = Arc::new(CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?);
    let read_cancel = cancellation.clone();
    let pending = std::thread::spawn(move || {
        let mut byte = [0u8; 1];
        read_exact(server.raw(), &mut byte, &[read_cancel.raw()])
    });
    cancellation.signal();
    let pending_read_cancelled_and_drained =
        pending.join().map_err(|_| ProbeError::Thread)? == Err(IoError::Cancelled);

    Ok(FramingEvidence {
        zero_length_rejected,
        over_limit_rejected,
        exact_limit_accepted,
        split_header_and_body_round_trip,
        consecutive_frames_preserved,
        partial_eof_rejected,
        pending_read_cancelled_and_drained,
    })
}

/// Exercise every cancellation classification point with real overlapped pipe
/// handles. Checkpoints run immediately after the OS call and only control
/// which completion and cancellation signals are visible before classification.
pub fn run_generation_io_probes() -> Result<GenerationIoEvidence, ProbeError> {
    let (server, client) = connected_test_pipe()?;
    write_all(client.raw(), b"a", &[]).map_err(|_| ProbeError::PipeIo)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    cancel.signal();
    let mut byte = [0u8; 1];
    let read_prestart = read_once_after_start(server.raw(), &mut byte, &[cancel.raw()], |_| {});
    let read_prestart_cancelled_without_consuming =
        read_prestart == Err(IoError::Cancelled) && available_bytes(server.raw())? == 1;

    let (server, client) = connected_test_pipe()?;
    write_all(client.raw(), b"b", &[]).map_err(|_| ProbeError::PipeIo)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut read_start = None;
    let mut byte = [0u8; 1];
    let read_sync = read_once_after_start(server.raw(), &mut byte, &[cancel.raw()], |start| {
        read_start = Some(start);
        cancel.signal();
    });
    let read_sync_completion_cancelled =
        read_start == Some(IoStart::Synchronous) && read_sync == Err(IoError::Cancelled);

    let (server, client) = connected_test_pipe()?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut read_start = None;
    let mut checkpoint_write_failed = false;
    let mut byte = [0u8; 1];
    let read_pending = read_once_after_start(server.raw(), &mut byte, &[cancel.raw()], |start| {
        read_start = Some(start);
        if write_all(client.raw(), b"c", &[]).is_err() {
            checkpoint_write_failed = true;
        }
        cancel.signal();
    });
    if checkpoint_write_failed {
        return Err(ProbeError::PipeIo);
    }
    let read_pending_completion_cancelled_and_drained =
        read_start == Some(IoStart::Pending) && read_pending == Err(IoError::Cancelled);

    let (server, client) = connected_test_pipe()?;
    write_all(client.raw(), b"xy", &[]).map_err(|_| ProbeError::PipeIo)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut starts = Vec::new();
    let mut body = [0u8; 4];
    let read_partial =
        read_exact_after_each_start(server.raw(), &mut body, &[cancel.raw()], |start| {
            starts.push(start);
            if starts.len() == 2 {
                cancel.signal();
            }
        });
    let read_partial_cancelled = starts == [IoStart::Synchronous, IoStart::Pending]
        && body[..2] == *b"xy"
        && read_partial == Err(IoError::Cancelled);

    let (server, client) = connected_test_pipe()?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    cancel.signal();
    let write_prestart = write_once_after_start(client.raw(), b"d", &[cancel.raw()], |_| {});
    let write_prestart_cancelled_without_writing =
        write_prestart == Err(IoError::Cancelled) && available_bytes(server.raw())? == 0;

    let (_server, client) = connected_test_pipe()?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut write_start = None;
    let write_sync = write_once_after_start(client.raw(), b"e", &[cancel.raw()], |start| {
        write_start = Some(start);
        cancel.signal();
    });
    let write_sync_completion_cancelled =
        write_start == Some(IoStart::Synchronous) && write_sync == Err(IoError::Cancelled);

    let (server, client) = connected_test_pipe()?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let payload = vec![b'f'; MAX_MESSAGE_BYTES * 2];
    let mut drained = vec![0u8; payload.len()];
    let mut write_start = None;
    let mut checkpoint_read_failed = false;
    let write_pending = write_once_after_start(client.raw(), &payload, &[cancel.raw()], |start| {
        write_start = Some(start);
        if read_exact(server.raw(), &mut drained, &[]).is_err() {
            checkpoint_read_failed = true;
        }
        cancel.signal();
    });
    if checkpoint_read_failed {
        return Err(ProbeError::PipeIo);
    }
    let write_pending_completion_cancelled_and_drained = write_start == Some(IoStart::Pending)
        && drained == payload
        && write_pending == Err(IoError::Cancelled);

    let (server, client) = connected_test_pipe()?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let partial_body = b"body-must-not-be-written-after-cancel";
    let write_partial =
        write_frame_after_header(client.raw(), partial_body, &[cancel.raw()], || {
            cancel.signal()
        });
    let mut partial_header = [0u8; 4];
    read_exact(server.raw(), &mut partial_header, &[]).map_err(|_| ProbeError::PipeIo)?;
    let write_partial_frame_cancelled = write_partial == Err(IoError::Cancelled)
        && u32::from_le_bytes(partial_header) as usize == partial_body.len()
        && available_bytes(server.raw())? == 0;

    let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let name = format!(
        r"\\.\pipe\winsmux-workspace-connect-prestart-{}",
        uuid::Uuid::new_v4()
    );
    let server = create_pipe(&name, &identity, true, true, SecurityMode::CurrentLogon, 1)
        .map_err(|_| ProbeError::PipeCreate)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    cancel.signal();
    let mut connect_start = None;
    let connect_prestart_result = connect_after_start(server.raw(), &[cancel.raw()], |start| {
        connect_start = Some(start);
    });
    let connect_prestart_cancelled =
        connect_start.is_none() && connect_prestart_result == Err(IoError::Cancelled);

    let name = format!(
        r"\\.\pipe\winsmux-workspace-connect-synchronous-{}",
        uuid::Uuid::new_v4()
    );
    let server = create_pipe(&name, &identity, true, true, SecurityMode::CurrentLogon, 1)
        .map_err(|_| ProbeError::PipeCreate)?;
    let _client = open_pipe(&name, SECURITY_IDENTIFICATION, PIPE_DATA_ACCESS)
        .map_err(ProbeError::PipeOpen)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut connect_start = None;
    let connect_synchronous = connect_after_start(server.raw(), &[cancel.raw()], |start| {
        connect_start = Some(start);
        cancel.signal();
    });
    let connect_already_connected_cancelled = connect_start == Some(IoStart::Synchronous)
        && connect_synchronous == Err(IoError::Cancelled);

    let name = format!(
        r"\\.\pipe\winsmux-workspace-connect-pending-{}",
        uuid::Uuid::new_v4()
    );
    let server = create_pipe(&name, &identity, true, true, SecurityMode::CurrentLogon, 1)
        .map_err(|_| ProbeError::PipeCreate)?;
    let cancel = CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?;
    let mut connect_start = None;
    let mut opened = None;
    let mut open_error = None;
    let connect_pending = connect_after_start(server.raw(), &[cancel.raw()], |start| {
        connect_start = Some(start);
        match open_pipe(&name, SECURITY_IDENTIFICATION, PIPE_DATA_ACCESS) {
            Ok(client) => opened = Some(client),
            Err(error) => open_error = Some(error),
        }
        cancel.signal();
    });
    if let Some(error) = open_error {
        return Err(ProbeError::PipeOpen(error));
    }
    let connect_pending_completion_cancelled_and_drained = opened.is_some()
        && connect_start == Some(IoStart::Pending)
        && connect_pending == Err(IoError::Cancelled);

    Ok(GenerationIoEvidence {
        read_prestart_cancelled_without_consuming,
        read_sync_completion_cancelled,
        read_pending_completion_cancelled_and_drained,
        read_partial_cancelled,
        write_prestart_cancelled_without_writing,
        write_sync_completion_cancelled,
        write_pending_completion_cancelled_and_drained,
        write_partial_frame_cancelled,
        connect_prestart_cancelled,
        connect_already_connected_cancelled,
        connect_pending_completion_cancelled_and_drained,
    })
}

impl ObservedConnection {
    fn start(target: ConnectionCheckpoint) -> Result<Self, ProbeError> {
        let identity = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
        let server_key = Arc::new(ServerKey::generate().map_err(|_| ProbeError::PipeCreate)?);
        let instance_id =
            InstanceId::new(uuid::Uuid::new_v4().to_string()).map_err(|_| ProbeError::Protocol)?;
        let discovery =
            Discovery::for_server(&identity, instance_id.clone(), server_key.fingerprint())
                .map_err(|_| ProbeError::Protocol)?;
        let capability =
            ServerCapabilityToken::create(&identity).map_err(|_| ProbeError::TokenCreate)?;
        let server = create_public_pipe(&discovery.pipe_name, &identity, &capability, true)?;
        let client = open_discovery_pipe(&discovery, &identity)?;
        connect_overlapped(server.raw(), &[]).map_err(|_| ProbeError::PipeConnect)?;

        let challenge = random_challenge().map_err(|_| ProbeError::PipeIo)?;
        let authentication = encode_auth_request(&challenge);
        let authorization = Arc::new(Authorization::new(Vec::new()));
        let host_cancel = Arc::new(CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?);
        let (reached_sender, reached) = mpsc::channel();
        let (release, release_receiver) = mpsc::channel();
        let trace = Arc::new(Mutex::new(Vec::new()));
        let observer = BarrierObserver {
            target,
            reached: reached_sender,
            release: release_receiver,
            trace: trace.clone(),
        };
        let worker_authorization = authorization.clone();
        let worker_cancel = host_cancel.clone();
        let worker_identity = identity.clone();
        let worker_discovery = discovery.clone();
        let worker = std::thread::Builder::new()
            .name("task862-generation-observed-connection".to_owned())
            .spawn(move || {
                handle_public_connection_observed(
                    server,
                    worker_identity,
                    server_key,
                    instance_id,
                    worker_discovery.pipe_name,
                    worker_authorization,
                    worker_cancel,
                    observer,
                );
            })
            .map_err(|_| ProbeError::Thread)?;
        Ok(Self {
            client,
            identity,
            discovery,
            authentication,
            authorization,
            host_cancel,
            worker: Some(worker),
            reached,
            release,
            trace,
        })
    }

    fn send_authentication(&self) -> Result<(), ProbeError> {
        write_frame(self.client.raw(), &self.authentication, &[]).map_err(|_| ProbeError::PipeIo)
    }

    fn wait_at_checkpoint(&self) -> Result<(), ProbeError> {
        self.reached.recv().map_err(|_| ProbeError::Thread)
    }

    fn read_and_verify_proof(&self) -> Result<(), ProbeError> {
        let proof = read_frame(self.client.raw(), &[]).map_err(|_| ProbeError::PipeIo)?;
        let challenge =
            parse_auth_request(&self.authentication).map_err(|_| ProbeError::Protocol)?;
        let fingerprint = self
            .discovery
            .validate_for(&self.identity)
            .map_err(|_| ProbeError::Protocol)?;
        let mut server_pid = 0u32;
        if unsafe { GetNamedPipeServerProcessId(self.client.raw(), &mut server_pid) } == 0
            || server_pid == 0
        {
            return Err(ProbeError::PipeIo);
        }
        verify_auth_response(
            &proof,
            fingerprint,
            &self.discovery.instance_id,
            &self.discovery.pipe_name,
            &challenge,
            unsafe { GetCurrentProcessId() },
            server_pid,
        )
        .map_err(|_| ProbeError::Protocol)
    }

    fn queue_general_request(&self) -> Result<(), ProbeError> {
        const REQUEST: &[u8] = br#"{"schema_version":1,"instance_id":null,"operation_id":"20000000-0000-4000-8000-000000000001","expected_topology_revision":null,"operation":"capabilities.get","params":{}}"#;
        write_frame(self.client.raw(), REQUEST, &[]).map_err(|_| ProbeError::PipeIo)
    }

    fn close_through_owner_eof(&self) -> Result<bool, ProbeError> {
        let (owner_client, owner_host) =
            create_private_channel_for_test(&self.identity).map_err(|_| ProbeError::PipeCreate)?;
        let authorization = self.authorization.clone();
        let host_cancel = self.host_cancel.clone();
        let owner = std::thread::Builder::new()
            .name("task862-generation-owner-eof".to_owned())
            .spawn(move || close_on_owner_eof_for_test(owner_host, authorization, host_cancel))
            .map_err(|_| ProbeError::Thread)?;
        drop(owner_client);
        let result = owner.join().map_err(|_| ProbeError::Thread)?;
        Ok(result == Err(IoError::Eof))
    }

    fn finish(
        mut self,
        owner_eof: bool,
        response_bytes: u32,
    ) -> Result<ClosureCaseEvidence, ProbeError> {
        self.release.send(()).map_err(|_| ProbeError::Thread)?;
        let worker = self.worker.take().ok_or(ProbeError::Thread)?;
        let worker_joined = worker.join().is_ok();
        let trace = self.trace.lock().map_err(|_| ProbeError::Thread)?.clone();
        Ok(ClosureCaseEvidence {
            trace,
            owner_eof,
            records: self.authorization.record_count(),
            response_bytes,
            worker_joined,
        })
    }
}

fn run_closure_case(
    target: ConnectionCheckpoint,
    read_proof: bool,
    queue_request: bool,
) -> Result<ClosureCaseEvidence, ProbeError> {
    let connection = ObservedConnection::start(target)?;
    connection.send_authentication()?;
    connection.wait_at_checkpoint()?;
    if read_proof {
        connection.read_and_verify_proof()?;
    }
    if queue_request {
        connection.queue_general_request()?;
    }
    let owner_eof = connection.close_through_owner_eof()?;
    let response_bytes = available_bytes(connection.client.raw())?;
    connection.finish(owner_eof, response_bytes)
}

/// Drive the production public handler and shutdown choke point through each
/// pre-lease ordering with real public and private named pipes. The barriers
/// are in-process channels; no test command, named object, or inherited handle
/// is added to the product protocol.
pub fn run_generation_closure_probes() -> Result<GenerationClosureEvidence, ProbeError> {
    let close_before_auth = run_closure_case(
        ConnectionCheckpoint::BeforeAuthenticationPermit,
        false,
        false,
    )?;
    let auth_before_close = run_closure_case(
        ConnectionCheckpoint::AfterAuthenticationPermit,
        false,
        false,
    )?;
    let close_before_proof =
        run_closure_case(ConnectionCheckpoint::BeforeProofPermit, false, false)?;
    let proof_before_close =
        run_closure_case(ConnectionCheckpoint::AfterProofPermit, false, false)?;
    let late_attach = run_closure_case(ConnectionCheckpoint::BeforeAttach, true, true)?;

    let close_before_authentication_read = close_before_auth.owner_eof
        && close_before_auth.worker_joined
        && close_before_auth.records == 0
        && close_before_auth.response_bytes == 0
        && close_before_auth.trace == [ConnectionCheckpoint::BeforeAuthenticationPermit];
    let authentication_permit_then_close_cancelled_read = auth_before_close.owner_eof
        && auth_before_close.worker_joined
        && auth_before_close.records == 0
        && auth_before_close.response_bytes == 0
        && auth_before_close
            .trace
            .contains(&ConnectionCheckpoint::AfterAuthenticationPermit)
        && !auth_before_close
            .trace
            .contains(&ConnectionCheckpoint::AfterAuthenticationRead);
    let close_before_proof_send = close_before_proof.owner_eof
        && close_before_proof.worker_joined
        && close_before_proof.records == 0
        && close_before_proof.response_bytes == 0
        && close_before_proof
            .trace
            .contains(&ConnectionCheckpoint::AfterAuthenticationRead)
        && !close_before_proof
            .trace
            .contains(&ConnectionCheckpoint::AfterProofPermit);
    let proof_permit_then_close_cancelled_write = proof_before_close.owner_eof
        && proof_before_close.worker_joined
        && proof_before_close.records == 0
        && proof_before_close.response_bytes == 0
        && proof_before_close
            .trace
            .contains(&ConnectionCheckpoint::AfterProofPermit)
        && !proof_before_close
            .trace
            .contains(&ConnectionCheckpoint::AfterProofWrite);
    let late_worker_joined = late_attach.owner_eof
        && late_attach.worker_joined
        && late_attach
            .trace
            .contains(&ConnectionCheckpoint::AfterProofWrite)
        && late_attach
            .trace
            .contains(&ConnectionCheckpoint::BeforeAttach)
        && !late_attach
            .trace
            .contains(&ConnectionCheckpoint::AfterAttach)
        && !late_attach
            .trace
            .contains(&ConnectionCheckpoint::AfterResponseWrite);

    Ok(GenerationClosureEvidence {
        owner_eof_cases: [
            &close_before_auth,
            &auth_before_close,
            &close_before_proof,
            &proof_before_close,
            &late_attach,
        ]
        .into_iter()
        .filter(|case| case.owner_eof)
        .count(),
        close_before_authentication_read,
        authentication_permit_then_close_cancelled_read,
        close_before_proof_send,
        proof_permit_then_close_cancelled_write,
        late_attach_records: late_attach.records,
        late_response_bytes: late_attach.response_bytes,
        late_worker_joined,
    })
}

fn run_epilogue_case(
    terminal: AcceptTerminal,
    initial_error: Option<HostError>,
    owner_cancelled: bool,
    include_panicking_worker: bool,
) -> Result<EpilogueCaseEvidence, ProbeError> {
    let authorization = Arc::new(Authorization::new(Vec::new()));
    let host_cancel = Arc::new(CancelEvent::new().map_err(|_| ProbeError::PipeCreate)?);
    let later_worker_completed = Arc::new(AtomicBool::new(false));
    let (worker_sender, worker_receiver) = mpsc::channel();
    let (armed_sender, armed_receiver) = mpsc::sync_channel(0);
    let (release_sender, release_receiver) = mpsc::sync_channel(0);
    let (cancel_observed_sender, cancel_observed_receiver) = mpsc::channel();

    let accept_authorization = authorization.clone();
    let accept_cancel = host_cancel.clone();
    let worker_cancel = host_cancel.clone();
    let completed = later_worker_completed.clone();
    let accept_thread = std::thread::Builder::new()
        .name("task862-epilogue-accept".to_owned())
        .spawn(move || {
            run_accept_guarded_for_test(&accept_authorization, &accept_cancel, || {
                if include_panicking_worker {
                    let panicking = std::thread::Builder::new()
                        .name("task862-epilogue-panicking-worker".to_owned())
                        .spawn(|| panic!("intentional worker panic for join coverage"))
                        .map_err(|_| IoError::Failed)?;
                    worker_sender.send(panicking).map_err(|_| IoError::Failed)?;
                }

                let waiting = std::thread::Builder::new()
                    .name("task862-epilogue-later-worker".to_owned())
                    .spawn(move || {
                        if unsafe { WaitForSingleObject(worker_cancel.raw(), INFINITE) }
                            == WAIT_OBJECT_0
                        {
                            completed.store(true, Ordering::SeqCst);
                            let _ = cancel_observed_sender.send(());
                        }
                    })
                    .map_err(|_| IoError::Failed)?;
                worker_sender.send(waiting).map_err(|_| IoError::Failed)?;
                armed_sender.send(()).map_err(|_| IoError::Failed)?;
                release_receiver.recv().map_err(|_| IoError::Failed)?;

                match terminal {
                    AcceptTerminal::Success => Ok(()),
                    AcceptTerminal::Error => Err(IoError::Protocol),
                    AcceptTerminal::Panic => {
                        panic!("intentional accept panic for shutdown coverage")
                    }
                }
            })
        })
        .map_err(|_| ProbeError::Thread)?;

    armed_receiver.recv().map_err(|_| ProbeError::Thread)?;
    release_sender.send(()).map_err(|_| ProbeError::Thread)?;
    let guard_closed_before_cancel =
        if matches!(terminal, AcceptTerminal::Error | AcceptTerminal::Panic) {
            cancel_observed_receiver
                .recv()
                .map_err(|_| ProbeError::Thread)?;
            authorization.begin_authentication().is_none()
        } else {
            false
        };

    let mut first_error = initial_error;
    close_and_collect_host_threads_for_test(
        &authorization,
        &host_cancel,
        accept_thread,
        worker_receiver,
        &mut first_error,
    );
    let result = finish_host_result_for_test(first_error, owner_cancelled);
    Ok(EpilogueCaseEvidence {
        result,
        generation_closed: authorization.begin_authentication().is_none(),
        guard_closed_before_cancel,
        later_worker_completed: later_worker_completed.load(Ordering::SeqCst),
    })
}

/// Exercise the production accept guard, close/cancel ordering, complete join
/// loop, and final result classification with deterministic thread outcomes.
pub fn run_host_epilogue_probes() -> Result<HostEpilogueEvidence, ProbeError> {
    let startup = run_epilogue_case(
        AcceptTerminal::Success,
        Some(HostError::Startup),
        false,
        false,
    )?;
    let protocol = run_epilogue_case(
        AcceptTerminal::Success,
        Some(HostError::Protocol),
        false,
        false,
    )?;
    let transport = run_epilogue_case(
        AcceptTerminal::Success,
        Some(HostError::Transport),
        false,
        false,
    )?;
    let owner_eof = run_epilogue_case(AcceptTerminal::Success, None, false, false)?;
    let owner_cancel = run_epilogue_case(AcceptTerminal::Success, None, true, false)?;
    let accept_error = run_epilogue_case(AcceptTerminal::Error, None, false, false)?;
    let accept_panic = run_epilogue_case(AcceptTerminal::Panic, None, false, false)?;
    let worker_panic = run_epilogue_case(AcceptTerminal::Success, None, false, true)?;
    let first_error =
        run_epilogue_case(AcceptTerminal::Panic, Some(HostError::Startup), false, true)?;

    Ok(HostEpilogueEvidence {
        startup_failure_preserved: startup.result == Err(HostError::Startup)
            && startup.generation_closed
            && startup.later_worker_completed,
        protocol_failure_preserved: protocol.result == Err(HostError::Protocol)
            && protocol.generation_closed
            && protocol.later_worker_completed,
        transport_failure_preserved: transport.result == Err(HostError::Transport)
            && transport.generation_closed
            && transport.later_worker_completed,
        owner_eof_remains_success: owner_eof.result == Ok(())
            && owner_eof.generation_closed
            && owner_eof.later_worker_completed,
        owner_cancel_remains_cancelled: owner_cancel.result == Err(HostError::Cancelled)
            && owner_cancel.generation_closed
            && owner_cancel.later_worker_completed,
        accept_error_closed_cancelled_and_collected: accept_error.result
            == Err(HostError::Protocol)
            && accept_error.generation_closed
            && accept_error.guard_closed_before_cancel
            && accept_error.later_worker_completed,
        accept_panic_closed_cancelled_and_collected: accept_panic.result
            == Err(HostError::Transport)
            && accept_panic.generation_closed
            && accept_panic.guard_closed_before_cancel
            && accept_panic.later_worker_completed,
        worker_panic_did_not_skip_later_join: worker_panic.result == Err(HostError::Transport)
            && worker_panic.generation_closed
            && worker_panic.later_worker_completed,
        first_error_won_after_later_failures: first_error.result == Err(HostError::Startup)
            && first_error.generation_closed
            && first_error.guard_closed_before_cancel
            && first_error.later_worker_completed,
    })
}

/// Exercise both the production DACL and the shared header-first peer verifier
/// with the two real Windows token shapes required by the TASK-862 contract.
pub fn run_os_authentication_probes() -> Result<OsAuthenticationEvidence, ProbeError> {
    let expected = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let (anonymous_user_differs, anonymous_has_no_logon) = anonymous_shape(expected.clone())?;

    let shape_token = create_new_credentials()?;
    let (new_credentials_same_user, new_credentials_has_logon, new_credentials_logon_differs) =
        new_credentials_shape(&expected, &shape_token)?;
    let current_logon_group_attributes = token_group_attributes(shape_token.raw(), &expected.logon)
        .map_err(|_| ProbeError::TokenQuery)?;
    let current_logon_group_enabled =
        current_logon_group_attributes.is_some_and(|attributes| attributes & 0x0000_0004 != 0);
    let current_logon_group_deny_only =
        current_logon_group_attributes.is_some_and(|attributes| attributes & 0x0000_0010 != 0);
    let source_identity = token_identity(shape_token.raw()).map_err(|_| ProbeError::TokenQuery)?;
    let restricted = restrict_current_logon(&shape_token, &expected.logon)?;
    let restricted_identity =
        token_identity(restricted.raw()).map_err(|_| ProbeError::TokenQuery)?;
    let restricted_group_attributes = token_group_attributes(restricted.raw(), &expected.logon)
        .map_err(|_| ProbeError::TokenQuery)?;
    let restricted_group_enabled =
        restricted_group_attributes.is_some_and(|attributes| attributes & 0x0000_0004 != 0);
    let restricted_group_deny_only =
        restricted_group_attributes.is_some_and(|attributes| attributes & 0x0000_0010 != 0);
    let restricted_same_user = restricted_identity.user.equals(&source_identity.user);
    let restricted_logon_unchanged = restricted_identity.logon.equals(&source_identity.logon);
    if !anonymous_user_differs
        || !anonymous_has_no_logon
        || !new_credentials_same_user
        || !new_credentials_has_logon
        || !new_credentials_logon_differs
        || current_logon_group_attributes.is_none()
        || !current_logon_group_enabled
        || current_logon_group_deny_only
        || !restricted_same_user
        || !restricted_logon_unchanged
        || restricted_group_attributes.is_none()
        || restricted_group_enabled
        || !restricted_group_deny_only
    {
        return Err(ProbeError::TokenShape);
    }

    // The production-mode peer probe must connect through the unchanged DACL
    // before it can exercise the shared header-first inner verifier.
    let new_credentials_peer = peer_probe(
        &expected,
        ProbeToken::LoggedOn(create_new_credentials()?),
        PeerProbeMode::Production,
    )?;

    Ok(OsAuthenticationEvidence {
        anonymous_user_differs,
        anonymous_has_no_logon,
        anonymous_production_acl_denied: production_acl_denies(&expected, ProbeToken::Anonymous)?,
        anonymous_peer: peer_probe(&expected, ProbeToken::Anonymous, PeerProbeMode::Permissive)?,
        new_credentials_same_user,
        new_credentials_has_logon,
        new_credentials_logon_differs,
        new_credentials_current_logon_group_attributes: current_logon_group_attributes,
        new_credentials_current_logon_group_enabled: current_logon_group_enabled,
        new_credentials_current_logon_group_deny_only: current_logon_group_deny_only,
        new_credentials_production_acl_allowed: true,
        new_credentials_peer,
        restricted_same_user,
        restricted_logon_unchanged,
        restricted_current_logon_group_attributes: restricted_group_attributes,
        restricted_current_logon_group_enabled: restricted_group_enabled,
        restricted_current_logon_group_deny_only: restricted_group_deny_only,
        restricted_production_acl_denied: production_acl_denies(
            &expected,
            ProbeToken::LoggedOn(restricted),
        )?,
    })
}

/// Prove on the current Windows host that generation-specific server creation
/// and original-logon client data access are separate capabilities.
pub fn run_server_capability_probes() -> Result<ServerCapabilityEvidence, ProbeError> {
    let expected = Identity::current().map_err(|_| ProbeError::CurrentIdentity)?;
    let capability =
        ServerCapabilityToken::create(&expected).map_err(|_| ProbeError::TokenCreate)?;
    let capability_identity =
        token_identity(capability.raw()).map_err(|_| ProbeError::TokenQuery)?;
    let attributes = token_group_attributes(capability.raw(), capability.logon())
        .map_err(|_| ProbeError::TokenQuery)?
        .ok_or(ProbeError::TokenShape)?;
    let mut token_flags = HANDLE_FLAG_INHERIT;
    if unsafe { GetHandleInformation(capability.raw(), &mut token_flags) } == 0 {
        return Err(ProbeError::TokenQuery);
    }

    let name = format!(
        r"\\.\pipe\winsmux-workspace-capability-probe-{}",
        uuid::Uuid::new_v4()
    );
    let first = create_public_pipe(&name, &expected, &capability, true)?;
    let second = create_public_pipe(&name, &expected, &capability, false)?;

    let original_server_create_denied =
        matches!(create_additional_instance(&name), Err(ERROR_ACCESS_DENIED));
    let separate_token = ProbeToken::LoggedOn(create_new_credentials()?);
    let separate_server_token_create_denied = with_impersonation(&separate_token, || {
        Ok(matches!(
            create_additional_instance(&name),
            Err(ERROR_ACCESS_DENIED)
        ))
    })?;

    let data_client = open_pipe(&name, SECURITY_IDENTIFICATION, PIPE_DATA_ACCESS);
    let original_data_connect_succeeded = data_client.is_ok();
    let original_write_dac_denied = matches!(
        open_pipe(&name, SECURITY_IDENTIFICATION, PIPE_DATA_ACCESS | WRITE_DAC),
        Err(ERROR_ACCESS_DENIED)
    );
    let original_write_owner_denied = matches!(
        open_pipe(
            &name,
            SECURITY_IDENTIFICATION,
            PIPE_DATA_ACCESS | WRITE_OWNER
        ),
        Err(ERROR_ACCESS_DENIED)
    );

    drop(data_client);
    drop(second);
    drop(first);

    Ok(ServerCapabilityEvidence {
        same_user: capability_identity.user.equals(&expected.user),
        distinct_logon: !capability_identity.logon.equals(&expected.logon),
        logon_group_enabled: attributes & 0x0000_0004 != 0,
        logon_group_not_deny_only: attributes & 0x0000_0010 == 0,
        token_not_inherited: token_flags & HANDLE_FLAG_INHERIT == 0,
        first_instance_created: true,
        second_instance_created: true,
        original_server_create_denied,
        separate_server_token_create_denied,
        original_data_connect_succeeded,
        original_write_dac_denied,
        original_write_owner_denied,
    })
}

fn publication_request(
    operation: &str,
    instance_id: Option<&str>,
    operation_id: &str,
    revision: Option<u64>,
    params: serde_json::Value,
) -> crate::contract::Request {
    let value = serde_json::json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": operation_id,
        "expected_topology_revision": revision,
        "operation": operation,
        "params": params,
    });
    crate::contract::parse_request(&serde_json::to_vec(&value).expect("request JSON"))
        .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn response_json(response: &crate::contract::Response) -> serde_json::Value {
    serde_json::to_value(response).expect("response json")
}

/// Real owner/public pipe proof that request ingress is released before publication.
pub fn run_request_publication_probes() -> Result<(), String> {
    use crate::auth::{PhaseHold, ProductPhase};
    use crate::contract::ConnectionId;
    use std::fs;
    use std::thread;
    use std::time::Duration;

    let folder = std::env::temp_dir().join(format!("winsmux-864-pub-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let path = folder.to_string_lossy().into_owned();
    let host = ProductHost::start(Vec::new()).map_err(|error| format!("host {error:?}"))?;
    let instance = host.instance_id().as_str().to_owned();
    let opened = host
        .owner_request(&publication_request(
            "project.open",
            Some(&instance),
            "20000000-0000-4000-8000-00000000b001",
            Some(0),
            serde_json::json!({"path": path}),
        ))
        .map_err(|error| format!("open {error:?}"))?;
    let opened = response_json(&opened);
    if opened["accepted"] != serde_json::json!(true) {
        let _ = host.shutdown();
        return Err(format!("open rejected {opened}"));
    }
    let project = opened["result"]["data"]["project_id"]
        .as_str()
        .ok_or("open project_id")?
        .to_owned();
    let revision = opened["topology_revision"]
        .as_u64()
        .ok_or("open revision")?;
    let baseline = host.allocations().snapshot();

    host.allocations().fail_after_allocations(7);
    let hold = PhaseHold::install(ProductPhase::OwnerPublication);
    let select_request = publication_request(
        "project.select",
        Some(&instance),
        "20000000-0000-4000-8000-00000000b002",
        Some(revision),
        serde_json::json!({"project_id": project}),
    );
    let owner_handle = host.owner_pipe();
    let select_fault = thread::scope(|scope| {
        let worker = scope.spawn(|| host.owner_request(&select_request));
        hold.wait_entered();
        let unread = available_bytes(owner_handle).map_err(|error| format!("peek {error:?}"))?;
        let held = host.allocations().snapshot();
        if unread != 0 {
            hold.release_waiters();
            hold.clear();
            let _ = worker.join();
            return Err(format!("owner reply readable before write_frame: {unread}"));
        }
        if held.active_owner != baseline.active_owner {
            hold.release_waiters();
            hold.clear();
            let _ = worker.join();
            return Err(format!(
                "owner ingress still live at publication hold baseline={} held={}",
                baseline.active_owner, held.active_owner
            ));
        }
        if held.retained != baseline.retained {
            hold.release_waiters();
            hold.clear();
            let _ = worker.join();
            return Err(format!(
                "retained changed at publication hold baseline={} held={}",
                baseline.retained, held.retained
            ));
        }
        hold.release_waiters();
        hold.clear();
        worker
            .join()
            .map_err(|_| "owner select worker".to_string())?
            .map_err(|error| format!("select.terminal {error:?}"))
    })?;
    let select_fault = response_json(&select_fault);
    if select_fault["error"]["code"] != serde_json::json!("resource_exhausted") {
        let _ = host.shutdown();
        return Err(format!(
            "select.terminal expected resource_exhausted {select_fault}"
        ));
    }
    let listed = response_json(
        &host
            .owner_request(&publication_request(
                "project.list",
                Some(&instance),
                "20000000-0000-4000-8000-00000000b003",
                None,
                serde_json::json!({}),
            ))
            .map_err(|error| format!("list {error:?}"))?,
    );
    if listed["result"]["data"]["selected_project_id"] != serde_json::Value::Null {
        let _ = host.shutdown();
        return Err(format!("select.terminal applied selection {listed}"));
    }
    let selected = host
        .owner_request(&publication_request(
            "project.select",
            Some(&instance),
            "20000000-0000-4000-8000-00000000b002",
            Some(revision),
            serde_json::json!({"project_id": project}),
        ))
        .map_err(|error| format!("select reuse {error:?}"))?;
    let selected = response_json(&selected);
    if selected["accepted"] != serde_json::json!(true) {
        let _ = host.shutdown();
        return Err(format!("owner loop reuse failed {selected}"));
    }
    let revision = selected["topology_revision"].as_u64().ok_or("select rev")?;

    let public = host
        .connect_authenticated()
        .map_err(|error| format!("public connect {error:?}"))?;
    let listed = host.wait_connections(1, Duration::from_secs(2));
    let connection_id = listed["result"]["data"]["connections"][0]["connection_id"]
        .as_str()
        .ok_or("connection_id")?
        .to_owned();
    let cid = ConnectionId::new(connection_id.clone()).map_err(|_| "connection id")?;
    let public_baseline = host.allocations().snapshot();
    host.allocations().fail_after_allocations(7);
    let send_hold = PhaseHold::install_for(ProductPhase::SendGate, &cid);
    let body_hold = WriteBodyHold::install_for(&cid);
    let public_request = publication_request(
        "connection.request",
        None,
        "20000000-0000-4000-8000-00000000b004",
        None,
        serde_json::json!({"project_ids": [project], "scopes": ["metadata"]}),
    );
    let public_pipe = public.pipe_handle();
    let public_fault = thread::scope(|scope| {
        let public_worker = scope.spawn(|| public.transact(&public_request));
        send_hold.wait_entered();
        let public_unread =
            available_bytes(public_pipe).map_err(|error| format!("public peek {error:?}"))?;
        let public_held = host.allocations().snapshot();
        if public_unread != 0 {
            send_hold.release_waiters();
            send_hold.clear();
            body_hold.clear();
            let _ = public_worker.join();
            return Err(format!(
                "public reply readable before send: {public_unread}"
            ));
        }
        if public_held.active_public != public_baseline.active_public {
            send_hold.release_waiters();
            send_hold.clear();
            body_hold.clear();
            let _ = public_worker.join();
            return Err(format!(
                "public ingress still live at send gate baseline={} held={}",
                public_baseline.active_public, public_held.active_public
            ));
        }
        send_hold.release_waiters();
        send_hold.clear();
        body_hold.wait_header_written();
        body_hold.release_body();
        body_hold.clear();
        public_worker
            .join()
            .map_err(|_| "public worker".to_string())?
            .map_err(|error| format!("public connection.request {error:?}"))
    })?;
    let public_fault = response_json(&public_fault);
    if public_fault["error"]["code"] != serde_json::json!("resource_exhausted") {
        let _ = host.shutdown();
        return Err(format!(
            "public connection.request expected resource_exhausted {public_fault}"
        ));
    }
    let public_reuse = public
        .transact(&publication_request(
            "connection.request",
            None,
            "20000000-0000-4000-8000-00000000b007",
            None,
            serde_json::json!({"project_ids": [project], "scopes": ["metadata"]}),
        ))
        .map_err(|error| format!("public reuse {error:?}"))?;
    let public_reuse = response_json(&public_reuse);
    if public_reuse["accepted"] != serde_json::json!(true) {
        let _ = host.shutdown();
        return Err(format!("public loop reuse failed {public_reuse}"));
    }

    host.allocations().fail_after_allocations(7);
    let forgotten = host
        .owner_request(&publication_request(
            "project.forget",
            Some(&instance),
            "20000000-0000-4000-8000-00000000b005",
            Some(revision),
            serde_json::json!({"project_id": project}),
        ))
        .map_err(|error| format!("forget.terminal {error:?}"))?;
    let forgotten = response_json(&forgotten);
    if forgotten["error"]["code"] != serde_json::json!("resource_exhausted") {
        let _ = host.shutdown();
        return Err(format!(
            "forget.terminal expected resource_exhausted {forgotten}"
        ));
    }

    host.allocations().fail_after_allocations(7);
    let open_terminal = host
        .owner_request(&publication_request(
            "project.open",
            Some(&instance),
            "20000000-0000-4000-8000-00000000b006",
            Some(0),
            serde_json::json!({"path": path}),
        ))
        .map_err(|error| format!("open.terminal {error:?}"))?;
    let open_terminal = response_json(&open_terminal);
    if open_terminal["error"]["code"] != serde_json::json!("resource_exhausted") {
        let _ = host.shutdown();
        return Err(format!(
            "open.terminal expected resource_exhausted {open_terminal}"
        ));
    }

    host.shutdown()
        .map_err(|error| format!("shutdown {error:?}"))?;
    let _ = fs::remove_dir_all(&folder);
    Ok(())
}

#[cfg(test)]
mod request_publication_tests {
    #[test]
    fn request_publication_releases_before_owner_and_public_write() {
        super::run_request_publication_probes().expect("request publication native proof");
    }
}
