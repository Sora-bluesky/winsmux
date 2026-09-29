#![cfg(windows)]

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::process::{Child as ProcessChild, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use windows_sys::Win32::Foundation::{
    CloseHandle, DuplicateHandle, GetLastError, SetLastError, DUPLICATE_SAME_ACCESS,
    ERROR_ALREADY_EXISTS, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, WAIT_FAILED,
    WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::{DeviceIoControl, OVERLAPPED};
use windows_sys::Win32::System::Ioctl::{
    FSCTL_REQUEST_OPLOCK, OPLOCK_LEVEL_CACHE_HANDLE, OPLOCK_LEVEL_CACHE_READ,
    OPLOCK_LEVEL_CACHE_WRITE, REQUEST_OPLOCK_INPUT_BUFFER, REQUEST_OPLOCK_INPUT_FLAG_REQUEST,
    REQUEST_OPLOCK_OUTPUT_BUFFER,
};
use windows_sys::Win32::System::Console::{
    AttachConsole, FreeConsole, GenerateConsoleCtrlEvent, GetConsoleMode, GetStdHandle,
    SetConsoleCtrlHandler, SetConsoleMode, CTRL_C_EVENT, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT,
    ENABLE_PROCESSED_INPUT, STD_INPUT_HANDLE,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetCurrentProcess, OpenEventW, SetEvent, TerminateProcess,
    WaitForMultipleObjects, WaitForSingleObject, EVENT_ALL_ACCESS, EVENT_MODIFY_STATE, INFINITE,
};
use winsmux_workspace::host::testing::{
    acquire_host_mutex_probe, canonical_discovery_json, open_host_mutex_handle, RogueProof,
    RogueServer, SlowPublicClient, SlowStage,
};
use winsmux_workspace::{canonical_request, parse_request, parse_response, Request, Response};

const ENV_MARKER: &str = "TASK862_ENV_SECRET_MARKER";
const ARG_MARKER: &str = "TASK862_ARG_SECRET_MARKER";
const INPUT_MARKER: &str = "TASK862_INPUT_SECRET_MARKER";
const CTRL_HELPER_TARGET: &str = "WINSMUX_TASK862_CTRL_TARGET";
const CONNECT_READY_EVENT: &str = "WINSMUX_TASK862_CONNECT_READY_EVENT";
const HANDLE_PROBE_REQUEST: &str = "WINSMUX_TASK862_HANDLE_PROBE";
const CONSOLE_MODE_TARGET: &str = "WINSMUX_TASK862_CONSOLE_MODE_TARGET";
const CONSOLE_MODE_RELEASE_EVENT: &str = "WINSMUX_TASK862_CONSOLE_MODE_RELEASE_EVENT";
const CONSOLE_MODE_DURING_EVENT: &str = "WINSMUX_TASK862_CONSOLE_MODE_DURING_EVENT";
const CONSOLE_MODE_AFTER_EVENT: &str = "WINSMUX_TASK862_CONSOLE_MODE_AFTER_EVENT";
const CONSOLE_MODE_STATE_PATH: &str = "WINSMUX_TASK862_CONSOLE_MODE_STATE_PATH";
const MUTEX_OWNER_HELPER: &str = "WINSMUX_TASK862_MUTEX_OWNER_HELPER";
const MUTEX_OWNER_READY_EVENT: &str = "WINSMUX_TASK862_MUTEX_OWNER_READY_EVENT";
const HELPER_FIXTURE_MODE: &str = "WINSMUX_TASK862_HELPER_FIXTURE_MODE";
const HELPER_FIXTURE_READY_EVENT: &str = "WINSMUX_TASK862_HELPER_FIXTURE_READY_EVENT";
const HELPER_FIXTURE_RELEASE_EVENT: &str = "WINSMUX_TASK862_HELPER_FIXTURE_RELEASE_EVENT";
const HELPER_FIXTURE_STATE_PATH: &str = "WINSMUX_TASK862_HELPER_FIXTURE_STATE_PATH";
const CONSOLE_SESSION_FIXTURE: &str = "WINSMUX_TASK862_CONSOLE_SESSION_FIXTURE";
const CONSOLE_SESSION_FIXTURE_STATE: &str = "WINSMUX_TASK862_CONSOLE_SESSION_FIXTURE_STATE";
const HELPER_FIXTURE_NOISE: &str = "TASK862_MUTEX_OWNER_READY diagnostic-only";
const FAIL_CNG: &str = "WINSMUX_TASK862_FAIL_CNG";
const FAIL_SERVER_TOKEN: &str = "WINSMUX_TASK862_FAIL_SERVER_TOKEN";
static NEXT_OPERATION: AtomicU64 = AtomicU64::new(1);
static NEXT_HELPER_RUN: AtomicU64 = AtomicU64::new(1);
static HOST_TEST_LOCK: Mutex<()> = Mutex::new(());

#[path = "support/conpty_json.rs"]
mod conpty_json;
use conpty_json::{extract_json, JsonOutput as OutputStream};

fn extract_all_json(bytes: &[u8]) -> Vec<Value> {
    let mut buffer = bytes.to_vec();
    let mut values = Vec::new();
    while let Some(value) = extract_json(&mut buffer) {
        values.push(value);
    }
    values
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

struct OwnedTestHandle(HANDLE);

impl OwnedTestHandle {
    fn fresh_event(name: &str) -> Result<Self, String> {
        let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            SetLastError(0);
        }
        let handle = unsafe { CreateEventW(std::ptr::null(), 1, 0, wide.as_ptr()) };
        let last_error = unsafe { GetLastError() };
        if handle.is_null() {
            return Err(format!("create event failed: {last_error}"));
        }
        if last_error == ERROR_ALREADY_EXISTS {
            unsafe {
                CloseHandle(handle);
            }
            return Err("event name already exists".to_owned());
        }
        Ok(Self(handle))
    }

    fn open_event(name: &str, access: u32) -> Result<Self, String> {
        let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        let handle = unsafe { OpenEventW(access, 0, wide.as_ptr()) };
        if handle.is_null() {
            return Err(format!("open event failed: {}", unsafe { GetLastError() }));
        }
        Ok(Self(handle))
    }

    fn duplicate(handle: HANDLE, label: &str) -> Result<Self, String> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(format!("{label} handle was invalid"));
        }
        let process = unsafe { GetCurrentProcess() };
        let mut duplicate = std::ptr::null_mut();
        if unsafe {
            DuplicateHandle(
                process,
                handle,
                process,
                &mut duplicate,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        } == 0
        {
            return Err(format!("duplicate {label} handle failed: {}", unsafe {
                GetLastError()
            }));
        }
        Ok(Self(duplicate))
    }

    fn from_file(handle: HANDLE, label: &str) -> Result<Self, String> {
        if handle == INVALID_HANDLE_VALUE {
            return Err(format!("{label} failed: {}", unsafe { GetLastError() }));
        }
        Ok(Self(handle))
    }

    fn raw(&self) -> HANDLE {
        self.0
    }

    fn signal(&self) -> Result<(), String> {
        if unsafe { SetEvent(self.0) } == 0 {
            return Err(format!("signal event failed: {}", unsafe {
                GetLastError()
            }));
        }
        Ok(())
    }
}

impl Drop for OwnedTestHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

#[derive(Clone, Copy)]
enum HelperStage {
    Intermediate,
    Final,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EventProcessWait {
    Event,
    Process,
}

fn wait_for_event_or_process(
    event: HANDLE,
    process: HANDLE,
    label: &str,
    stage: &str,
) -> Result<EventProcessWait, String> {
    let handles = [event, process];
    let wait =
        unsafe { WaitForMultipleObjects(handles.len() as u32, handles.as_ptr(), 0, INFINITE) };
    if wait == WAIT_FAILED {
        return Err(format!("{label} wait failed at {stage}: {}", unsafe {
            GetLastError()
        }));
    }
    match wait {
        WAIT_OBJECT_0 => Ok(EventProcessWait::Event),
        value if value == WAIT_OBJECT_0 + 1 => Ok(EventProcessWait::Process),
        _ => Err(format!(
            "{label} wait returned unexpected value {wait:#x} at {stage}"
        )),
    }
}

fn wait_for_connect_ready(event: HANDLE, process: HANDLE, label: &str) -> Result<(), String> {
    match wait_for_event_or_process(event, process, label, "connect readiness")? {
        EventProcessWait::Process => {
            return Err(format!("{label} ended before connect readiness"));
        }
        EventProcessWait::Event => {}
    }
    match unsafe { WaitForSingleObject(process, 0) } {
        WAIT_TIMEOUT => Ok(()),
        WAIT_OBJECT_0 => Err(format!(
            "{label} ended at the connect readiness observation point"
        )),
        WAIT_FAILED => Err(format!(
            "{label} zero-wait failed at connect readiness: {}",
            unsafe { GetLastError() }
        )),
        wait => Err(format!(
            "{label} zero-wait returned unexpected value {wait:#x} at connect readiness"
        )),
    }
}

struct HelperLifecycle {
    label: &'static str,
    child: Option<ProcessChild>,
    diagnostics: tempfile::NamedTempFile,
}

impl HelperLifecycle {
    fn spawn(
        label: &'static str,
        test_name: &str,
        stdin: Stdio,
        configure: impl FnOnce(&mut Command),
    ) -> Result<Self, String> {
        let diagnostics = tempfile::NamedTempFile::new()
            .map_err(|error| format!("create {label} diagnostics: {error}"))?;
        let diagnostic_writer = diagnostics
            .reopen()
            .map_err(|error| format!("open {label} diagnostics for child: {error}"))?;
        let mut command = Command::new(
            std::env::current_exe()
                .map_err(|error| format!("resolve current test executable: {error}"))?,
        );
        command.args(["--exact", test_name, "--nocapture"]);
        configure(&mut command);
        let child = command
            .stdin(stdin)
            .stdout(Stdio::null())
            .stderr(Stdio::from(diagnostic_writer))
            .spawn()
            .map_err(|error| format!("spawn {label}: {error}"))?;
        Ok(Self {
            label,
            child: Some(child),
            diagnostics,
        })
    }

    fn wait_for_event(
        &mut self,
        event: &OwnedTestHandle,
        stage: &str,
        kind: HelperStage,
    ) -> Result<(), String> {
        self.wait_for_raw_event(event.raw(), stage, kind)
    }

    fn wait_for_raw_event(
        &mut self,
        event: HANDLE,
        stage: &str,
        kind: HelperStage,
    ) -> Result<(), String> {
        let child_handle = AsRawHandle::as_raw_handle(
            self.child
                .as_ref()
                .ok_or_else(|| format!("{} child already reaped", self.label))?,
        ) as HANDLE;
        if wait_for_event_or_process(event, child_handle, self.label, stage)?
            == EventProcessWait::Process
        {
            let status = self
                .child
                .as_mut()
                .expect("checked helper child")
                .wait()
                .map_err(|error| format!("wait {} after early exit: {error}", self.label))?;
            self.child.take();
            return Err(self.ended_before(stage, status));
        }
        if matches!(kind, HelperStage::Intermediate) {
            let status = self
                .child
                .as_mut()
                .expect("checked helper child")
                .try_wait()
                .map_err(|error| format!("inspect {} at {stage}: {error}", self.label))?;
            if let Some(status) = status {
                self.child.take();
                return Err(self.ended_before(stage, status));
            }
        }
        Ok(())
    }

    fn finish_success(&mut self) -> Result<(), String> {
        let status = self
            .child
            .as_mut()
            .ok_or_else(|| format!("{} child already reaped", self.label))?
            .wait()
            .map_err(|error| format!("wait {} completion: {error}", self.label))?;
        self.child.take();
        if !status.success() {
            return Err(format!(
                "{} failed ({status}): {}",
                self.label,
                self.diagnostic_text()
            ));
        }
        Ok(())
    }

    fn terminate_running(&mut self) -> Result<(), String> {
        let status = self
            .child
            .as_mut()
            .ok_or_else(|| format!("{} child already reaped", self.label))?
            .try_wait()
            .map_err(|error| format!("inspect {} before termination: {error}", self.label))?;
        if let Some(status) = status {
            self.child.take();
            return Err(format!(
                "{} ended before owned termination ({status}): {}",
                self.label,
                self.diagnostic_text()
            ));
        }
        let kill_result = self.child.as_mut().expect("checked helper child").kill();
        if let Err(error) = kill_result {
            let status = self.child.as_mut().expect("checked helper child").wait();
            self.child.take();
            return Err(format!(
                "terminate {} failed ({error}); final status {status:?}: {}",
                self.label,
                self.diagnostic_text()
            ));
        }
        self.child
            .as_mut()
            .expect("checked helper child")
            .wait()
            .map_err(|error| format!("wait terminated {}: {error}", self.label))?;
        self.child.take();
        Ok(())
    }

    fn duplicate_process_handle(&self) -> Result<OwnedTestHandle, String> {
        let child = self
            .child
            .as_ref()
            .ok_or_else(|| format!("{} child already reaped", self.label))?;
        OwnedTestHandle::duplicate(AsRawHandle::as_raw_handle(child) as HANDLE, "child process")
    }

    fn ended_before(&self, stage: &str, status: std::process::ExitStatus) -> String {
        format!(
            "{} ended before {stage} ({status}): {}",
            self.label,
            self.diagnostic_text()
        )
    }

    fn diagnostic_text(&self) -> String {
        std::fs::read(self.diagnostics.path())
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
            .unwrap_or_else(|error| format!("<diagnostics unavailable: {error}>"))
    }
}

impl Drop for HelperLifecycle {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if !matches!(child.try_wait(), Ok(Some(_))) {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

fn helper_run_stem(kind: &str) -> String {
    format!(
        "Local\\winsmux-task862-helper-{}-{}-{kind}",
        std::process::id(),
        NEXT_HELPER_RUN.fetch_add(1, Ordering::SeqCst)
    )
}

fn connect_ready_event_name() -> String {
    format!(
        "Local\\winsmux-task862-connect-ready-{}-{}",
        std::process::id(),
        NEXT_HELPER_RUN.fetch_add(1, Ordering::SeqCst)
    )
}

fn read_console_modes(path: &Path, expected: usize) -> Result<Vec<u32>, String> {
    let bytes = std::fs::read(path).map_err(|error| format!("read console mode state: {error}"))?;
    let expected_bytes = expected
        .checked_mul(4)
        .ok_or_else(|| "console mode count overflow".to_owned())?;
    if bytes.len() != expected_bytes {
        return Err(format!(
            "console mode state length was {}, expected {expected_bytes}",
            bytes.len()
        ));
    }
    Ok(bytes
        .chunks_exact(4)
        .map(|bytes| u32::from_le_bytes(bytes.try_into().expect("four-byte mode")))
        .collect())
}

fn write_console_modes(path: &Path, modes: &[u32]) -> Result<(), String> {
    let bytes: Vec<u8> = modes.iter().flat_map(|mode| mode.to_le_bytes()).collect();
    std::fs::write(path, bytes).map_err(|error| format!("write console mode state: {error}"))
}

fn managed_console_mode(original: u32) -> u32 {
    (original | ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT) & !ENABLE_ECHO_INPUT
}

struct ConsoleModeObserver {
    label: &'static str,
    helper: HelperLifecycle,
    state_path: tempfile::TempPath,
    _during_ready: OwnedTestHandle,
    after_ready: OwnedTestHandle,
    release: OwnedTestHandle,
    during: u32,
}

impl ConsoleModeObserver {
    fn start(target: u32, label: &'static str) -> Result<Self, String> {
        let stem = helper_run_stem("console-mode");
        let release_name = format!("{stem}-release");
        let during_name = format!("{stem}-during");
        let after_name = format!("{stem}-after");
        let release = OwnedTestHandle::fresh_event(&release_name)
            .map_err(|error| format!("create console mode release event: {error}"))?;
        let during_ready = OwnedTestHandle::fresh_event(&during_name)
            .map_err(|error| format!("create console mode during event: {error}"))?;
        let after_ready = OwnedTestHandle::fresh_event(&after_name)
            .map_err(|error| format!("create console mode after event: {error}"))?;
        let state_path = tempfile::NamedTempFile::new()
            .map_err(|error| format!("create console mode state file: {error}"))?
            .into_temp_path();
        let mut helper = HelperLifecycle::spawn(
            "console mode observer",
            "console_mode_observer_process",
            Stdio::null(),
            |command| {
                command
                    .env(CONSOLE_MODE_TARGET, target.to_string())
                    .env(CONSOLE_MODE_RELEASE_EVENT, &release_name)
                    .env(CONSOLE_MODE_DURING_EVENT, &during_name)
                    .env(CONSOLE_MODE_AFTER_EVENT, &after_name)
                    .env(CONSOLE_MODE_STATE_PATH, state_path.as_os_str());
            },
        )?;
        helper
            .wait_for_event(
                &during_ready,
                "active console mode",
                HelperStage::Intermediate,
            )
            .map_err(|error| format!("observe active console mode: {error}"))?;
        let during = read_console_modes(&state_path, 1)
            .map_err(|error| format!("read active console mode: {error}"))?[0];
        if during & ENABLE_ECHO_INPUT != 0 {
            return Err(format!(
                "{label} left ENABLE_ECHO_INPUT enabled: {during:#x}"
            ));
        }
        if during & (ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT)
            != ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT
        {
            return Err(format!(
                "{label} did not enable processed and line input: {during:#x}"
            ));
        }
        Ok(Self {
            label,
            helper,
            state_path,
            _during_ready: during_ready,
            after_ready,
            release,
            during,
        })
    }

    fn assert_restored(&mut self) {
        self.release.signal().expect("release console observer");
        self.helper
            .wait_for_event(
                &self.after_ready,
                "restored console mode",
                HelperStage::Final,
            )
            .expect("observe restored console mode");
        let modes = read_console_modes(&self.state_path, 2).expect("read restored console mode");
        assert_eq!(modes[0], self.during, "active console mode changed");
        let after = modes[1];
        assert_eq!(
            self.during,
            managed_console_mode(after),
            "{} did not apply the managed console mode formula",
            self.label
        );
        self.helper
            .finish_success()
            .expect("finish console mode observer");
        println!(
            "TASK862_CONSOLE_MODE_PROOF {} during={} after={}",
            self.label, self.during, after
        );
    }
}

struct InteractiveResources {
    child: Option<Box<dyn Child + Send + Sync>>,
    target_process: Option<OwnedTestHandle>,
    master: Option<Box<dyn MasterPty + Send>>,
    writer: Option<Box<dyn Write + Send>>,
    output: Option<OutputStream>,
    mode_observer: Option<ConsoleModeObserver>,
}

impl InteractiveResources {
    fn from_child(child: Box<dyn Child + Send + Sync>) -> Result<Self, String> {
        let mut resources = Self {
            child: Some(child),
            target_process: None,
            master: None,
            writer: None,
            output: None,
            mode_observer: None,
        };
        let raw = resources
            .child
            .as_ref()
            .and_then(|child| child.as_raw_handle())
            .ok_or_else(|| "ConPTY child did not expose a process handle".to_owned())?
            as HANDLE;
        resources.target_process = Some(OwnedTestHandle::duplicate(raw, "ConPTY child process")?);
        Ok(resources)
    }

    fn duplicate_target_handle(&self) -> Result<OwnedTestHandle, String> {
        let target = self
            .target_process
            .as_ref()
            .ok_or_else(|| "ConPTY child process handle was released".to_owned())?;
        OwnedTestHandle::duplicate(target.raw(), "ConPTY child process")
    }

    fn cleanup_nonpanic(&mut self) {
        drop(self.mode_observer.take());

        let target = self
            .target_process
            .as_ref()
            .map(OwnedTestHandle::raw)
            .or_else(|| {
                self.child
                    .as_ref()
                    .and_then(|child| child.as_raw_handle())
                    .map(|handle| handle as HANDLE)
            });
        if let (Some(target), Some(child)) = (target, self.child.as_mut()) {
            let target_wait = unsafe { WaitForSingleObject(target, 0) };
            let should_reap = if target_wait == WAIT_OBJECT_0 {
                true
            } else if target_wait == WAIT_TIMEOUT {
                (unsafe { TerminateProcess(target, 1) }) != 0
                    || (unsafe { WaitForSingleObject(target, 0) }) == WAIT_OBJECT_0
            } else {
                false
            };
            if should_reap {
                let _ = child.wait();
            }
        }
        self.child.take();
        self.target_process.take();

        drop(self.writer.take());
        drop(self.master.take());
        if let Some(output) = self.output.as_mut() {
            output.join_nonpanic();
        }
        self.output.take();
    }
}

impl Drop for InteractiveResources {
    fn drop(&mut self) {
        self.cleanup_nonpanic();
    }
}

struct InteractiveHost {
    resources: InteractiveResources,
    is_connect: bool,
    discovery_count: usize,
    response_count: usize,
    forbidden_echoes: Vec<Vec<u8>>,
}

struct HostExit {
    code: u32,
    output: Vec<u8>,
}

impl InteractiveHost {
    fn receive_json(&mut self) -> Value {
        let process = self
            .resources
            .target_process
            .as_ref()
            .expect("ConPTY client process")
            .raw();
        let received = self
            .resources
            .output
            .as_ref()
            .expect("interactive output")
            .next_json_with_process(process);
        match received {
            Ok(value) => value,
            Err(exit) => {
                if exit.signaled {
                    if let Some(observer) = self.resources.mode_observer.as_mut() {
                        observer.assert_restored();
                    }
                    drop(self.resources.mode_observer.take());
                }
                drop(self.resources.writer.take());
                drop(self.resources.master.take());
                let output = self.resources.output.as_mut().expect("interactive output");
                output.join_nonpanic();
                if let Some(value) = output.finish_json_after_reader_join() {
                    return value;
                }
                let captured = output.captured();
                panic!(
                    "interactive client ended before JSON response: {exit:?}; output={}",
                    String::from_utf8_lossy(&captured)
                );
            }
        }
    }

    fn start(binary: &Path, home: &Path) -> Self {
        Self::start_with_arguments(binary, home, &["workspace", "host"])
    }

    fn start_client(binary: &Path, home: &Path, discovery: &Value) -> Self {
        let mut client = Self::start_with_arguments(binary, home, &["workspace", "connect"]);
        let bytes = serde_json::to_vec(discovery).expect("discovery JSON");
        client.forbidden_echoes.push(bytes.clone());
        let writer = client.resources.writer.as_mut().expect("connect input");
        writer
            .write_all(&bytes)
            .and_then(|_| writer.write_all(b"\r\n"))
            .and_then(|_| writer.flush())
            .expect("write trusted discovery");
        client
    }

    fn start_with_arguments(binary: &Path, home: &Path, arguments: &[&str]) -> Self {
        Self::start_with_environment(binary, home, arguments, &[])
    }

    fn start_with_environment(
        binary: &Path,
        home: &Path,
        arguments: &[&str],
        environment: &[(&str, &str)],
    ) -> Self {
        Self::start_with_environment_after_spawn(binary, home, arguments, environment, |_| {})
    }

    fn start_with_environment_after_spawn(
        binary: &Path,
        home: &Path,
        arguments: &[&str],
        environment: &[(&str, &str)],
        after_spawn: impl FnOnce(&InteractiveResources),
    ) -> Self {
        std::fs::create_dir_all(home.join("AppData").join("Local"))
            .expect("prepare isolated Windows LocalAppData");
        let is_connect = arguments == ["workspace", "connect"];
        let connect_ready = if is_connect {
            let name = connect_ready_event_name();
            let event = OwnedTestHandle::fresh_event(&name).expect("create connect ready event");
            Some((name, event))
        } else {
            None
        };
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 4096,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open ConPTY");
        let mut command = CommandBuilder::new(binary);
        command.args(arguments.iter().copied());
        command.env("USERPROFILE", home);
        command.env("HOME", home);
        command.env("WINSMUX_TASK862_MARKER", ENV_MARKER);
        command.env_remove(CONNECT_READY_EVENT);
        for (name, value) in environment {
            command.env(name, value);
        }
        if let Some((name, _)) = connect_ready.as_ref() {
            command.env(CONNECT_READY_EVENT, name);
        }
        if arguments == ["workspace", "host"] {
            command.env(HANDLE_PROBE_REQUEST, "1");
        }
        let child = pair
            .slave
            .spawn_command(command)
            .expect("spawn real winsmux.exe in ConPTY");
        let mut resources = InteractiveResources::from_child(child)
            .expect("retain owned ConPTY child process handle");
        after_spawn(&resources);
        drop(pair.slave);
        // portable-pty may replace its ConPTY and pipe pair during the
        // spawn-time passthrough fallback. Take the active master endpoints
        // only after spawn has completed.
        let reader = pair.master.try_clone_reader().expect("clone ConPTY reader");
        let mut writer = pair.master.take_writer().expect("take ConPTY writer");
        // PSEUDOCONSOLE_INHERIT_CURSOR emits DSR (CSI 6 n) and waits for the
        // terminal emulator's cursor-position report before the child runs.
        writer
            .write_all(b"\x1b[1;1R")
            .and_then(|_| writer.flush())
            .expect("answer ConPTY cursor query");
        resources.master = Some(pair.master);
        resources.writer = Some(writer);
        resources.output = Some(OutputStream::start(reader));
        if let Some((_, ready)) = connect_ready.as_ref() {
            let target = resources
                .target_process
                .as_ref()
                .expect("owned ConPTY child process handle");
            if let Err(error) =
                wait_for_connect_ready(ready.raw(), target.raw(), "interactive connect")
            {
                let raw_output = resources
                    .output
                    .as_ref()
                    .map(OutputStream::captured)
                    .unwrap_or_default();
                panic!(
                    "interactive connect did not become ready: {error}; captured_raw_bytes={raw_output:?}"
                );
            }
        }
        Self {
            resources,
            is_connect,
            discovery_count: 0,
            response_count: 0,
            forbidden_echoes: Vec::new(),
        }
    }

    fn discovery(&mut self) -> Value {
        assert!(!self.is_connect, "connect clients do not emit discovery");
        assert_eq!(self.discovery_count, 0, "discovery is emitted once");
        let discovery = self.receive_json();
        assert!(
            discovery.get("accepted").is_none(),
            "discovery was a response: {discovery}"
        );
        self.discovery_count += 1;
        discovery
    }

    fn transact(&mut self, request: &Request) -> Response {
        let request_bytes =
            write_request(self.resources.writer.as_mut().expect("host input"), request);
        self.forbidden_echoes.push(request_bytes);
        let value = self.receive_json();
        assert!(
            value.get("accepted").is_some(),
            "interactive stdout contained a non-response JSON object: {value}"
        );
        self.response_count += 1;
        parse_cli_response(request, value)
    }

    fn observe_console_input(&mut self, label: &'static str) {
        assert!(
            self.resources.mode_observer.is_none(),
            "console is already observed"
        );
        let target = self
            .resources
            .child
            .as_ref()
            .expect("ConPTY child")
            .process_id()
            .expect("ConPTY client process ID");
        match ConsoleModeObserver::start(target, label) {
            Ok(observer) => self.resources.mode_observer = Some(observer),
            Err(error) => {
                let target_status = self
                    .resources
                    .child
                    .as_mut()
                    .expect("ConPTY child")
                    .try_wait();
                let raw_output = self
                    .resources
                    .output
                    .as_ref()
                    .expect("interactive output")
                    .captured();
                panic!(
                    "start console mode observer for {label} failed: {error}; target_pid={target}; target_try_wait={target_status:?}; captured_raw_bytes={raw_output:?}"
                );
            }
        }
    }

    fn write_raw(&mut self, bytes: &[u8]) {
        self.forbidden_echoes.push(bytes.to_vec());
        let writer = self.resources.writer.as_mut().expect("terminal input");
        writer
            .write_all(bytes)
            .and_then(|_| writer.write_all(b"\r\n"))
            .and_then(|_| writer.flush())
            .expect("write raw terminal input");
    }

    fn request_then_exit(mut self, request: &Request) -> HostExit {
        let request_bytes = write_request(
            self.resources.writer.as_mut().expect("terminal input"),
            request,
        );
        self.forbidden_echoes.push(request_bytes);
        self.wait_for_exit()
    }

    fn console_eof(mut self) -> HostExit {
        self.write_terminal_input(b"\x1a\r");
        self.wait_for_exit()
    }

    fn ctrl_c(self) -> HostExit {
        let target = self
            .resources
            .child
            .as_ref()
            .expect("ConPTY child")
            .process_id()
            .expect("ConPTY client process ID");
        send_ctrl_c(target);
        self.wait_for_exit()
    }

    fn ctrl_c_byte(mut self) -> HostExit {
        self.forbidden_echoes.push(vec![0x03]);
        self.write_terminal_input(&[0x03]);
        self.wait_for_exit()
    }

    fn terminate_owner(mut self) -> HostExit {
        assert!(
            self.resources.mode_observer.is_none(),
            "TerminateProcess cannot prove Rust guard destruction"
        );
        self.resources
            .child
            .as_mut()
            .expect("ConPTY child")
            .kill()
            .expect("terminate ConPTY owner process");
        // TerminateProcess bypasses Rust Drop. The later master teardown proves
        // only the synthetic ConPTY lifetime boundary, not mode restoration.
        self.wait_for_exit()
    }

    fn write_terminal_input(&mut self, bytes: &[u8]) {
        let writer = self.resources.writer.as_mut().expect("terminal input");
        writer
            .write_all(bytes)
            .and_then(|_| writer.flush())
            .expect("write terminal input");
    }

    fn wait_for_exit(mut self) -> HostExit {
        let status = self
            .resources
            .child
            .as_mut()
            .expect("ConPTY child")
            .wait()
            .expect("wait ConPTY host");
        if let Some(observer) = self.resources.mode_observer.as_mut() {
            observer.assert_restored();
        }
        drop(self.resources.mode_observer.take());
        self.resources.child.take();
        self.resources.target_process.take();
        drop(self.resources.writer.take());
        drop(self.resources.master.take());
        let output_stream = self.resources.output.as_mut().expect("interactive output");
        output_stream.join();
        let output = output_stream.captured();
        self.resources.output.take();
        self.assert_output_contract(&output);
        HostExit {
            code: status.exit_code(),
            output,
        }
    }

    fn assert_output_contract(&self, output: &[u8]) {
        for request in &self.forbidden_echoes {
            assert!(
                !contains_bytes(output, request),
                "interactive output echoed request bytes: {}",
                String::from_utf8_lossy(request)
            );
        }
        let values = extract_all_json(output);
        let response_start = self.discovery_count;
        assert_eq!(
            values.len(),
            response_start + self.response_count,
            "unexpected JSON in interactive output: {}",
            String::from_utf8_lossy(output)
        );
        if self.discovery_count == 1 {
            assert!(!self.is_connect, "connect output contained discovery");
            assert!(values[0].get("accepted").is_none(), "{}", values[0]);
        } else {
            assert_eq!(self.discovery_count, 0, "discovery count");
        }
        for response in values.iter().skip(response_start) {
            assert!(
                response.get("accepted").is_some(),
                "captured JSON was not a response: {response}"
            );
        }
    }
}

fn send_ctrl_c(target: u32) {
    let output = Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", "console_ctrl_helper_process", "--nocapture"])
        .env(CTRL_HELPER_TARGET, target.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run console control helper");
    assert!(
        output.status.success(),
        "console control helper failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn abandon_host_mutex() -> winsmux_workspace::host::testing::MutexHandleProbe {
    let ready_name = format!("{}-ready", helper_run_stem("mutex-owner"));
    let ready = OwnedTestHandle::fresh_event(&ready_name).expect("create mutex owner ready event");
    let mut helper = HelperLifecycle::spawn(
        "mutex owner helper",
        "mutex_owner_helper_process",
        Stdio::piped(),
        |command| {
            command
                .env(MUTEX_OWNER_HELPER, "1")
                .env(MUTEX_OWNER_READY_EVENT, &ready_name);
        },
    )
    .expect("spawn mutex owner helper");
    helper
        .wait_for_event(&ready, "mutex ownership", HelperStage::Intermediate)
        .unwrap_or_else(|error| panic!("{error}"));
    let retained = open_host_mutex_handle().expect("retain abandoned mutex object");
    helper
        .terminate_running()
        .expect("terminate owned mutex helper after retaining object");
    retained
}

#[test]
fn console_ctrl_helper_process() {
    let Some(target) = std::env::var_os(CTRL_HELPER_TARGET) else {
        return;
    };
    let target = target
        .to_string_lossy()
        .parse::<u32>()
        .expect("console control target PID");
    unsafe {
        // This helper is a separate process. Detach only its inherited console,
        // attach it to the target ConPTY, ignore the event in the helper, then
        // emit a real OS CTRL_C_EVENT to that console.
        FreeConsole();
        assert_ne!(AttachConsole(target), 0, "attach target console");
        assert_ne!(SetConsoleCtrlHandler(None, 1), 0, "ignore helper Ctrl+C");
        assert_ne!(
            GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0),
            0,
            "generate Ctrl+C"
        );
        FreeConsole();
    }
}

#[test]
fn mutex_owner_helper_process() {
    if std::env::var(MUTEX_OWNER_HELPER).as_deref() != Ok("1") {
        return;
    }
    let _ownership = acquire_host_mutex_probe().expect("acquire host mutex in helper");
    let event_name =
        std::env::var_os(MUTEX_OWNER_READY_EVENT).expect("mutex owner ready event name");
    let ready = OwnedTestHandle::open_event(&event_name.to_string_lossy(), EVENT_MODIFY_STATE)
        .expect("open mutex owner ready event");
    ready.signal().expect("signal mutex ownership");
    let mut byte = [0u8; 1];
    let _ = std::io::stdin().read_exact(&mut byte);
}

#[test]
fn console_mode_observer_process() {
    let Some(target) = std::env::var_os(CONSOLE_MODE_TARGET) else {
        return;
    };
    let release_name =
        std::env::var_os(CONSOLE_MODE_RELEASE_EVENT).expect("console mode release event name");
    let during_name =
        std::env::var_os(CONSOLE_MODE_DURING_EVENT).expect("console mode during event name");
    let after_name =
        std::env::var_os(CONSOLE_MODE_AFTER_EVENT).expect("console mode after event name");
    let state_path =
        PathBuf::from(std::env::var_os(CONSOLE_MODE_STATE_PATH).expect("console mode state path"));
    let target = target
        .to_string_lossy()
        .parse::<u32>()
        .expect("console mode target PID");
    let release = OwnedTestHandle::open_event(&release_name.to_string_lossy(), EVENT_ALL_ACCESS)
        .expect("open console mode release event");
    let during_ready =
        OwnedTestHandle::open_event(&during_name.to_string_lossy(), EVENT_MODIFY_STATE)
            .expect("open console mode during event");
    let after_ready =
        OwnedTestHandle::open_event(&after_name.to_string_lossy(), EVENT_MODIFY_STATE)
            .expect("open console mode after event");
    let input_name: Vec<u16> = "CONIN$".encode_utf16().chain(std::iter::once(0)).collect();
    let free_console = unsafe { FreeConsole() };
    let free_console_error = (free_console == 0).then(std::io::Error::last_os_error);
    let attach_console = unsafe { AttachConsole(target) };
    if attach_console == 0 {
        let attach_console_error = std::io::Error::last_os_error();
        panic!(
            "attach observed console failed: target_pid={target}; FreeConsole returned {free_console}; FreeConsole error={free_console_error:?}; AttachConsole error={attach_console_error:?}"
        );
    }
    assert_ne!(
        unsafe { SetConsoleCtrlHandler(None, 1) },
        0,
        "ignore observer Ctrl+C"
    );
    let input = unsafe {
        CreateFileW(
            input_name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    };
    let input =
        OwnedTestHandle::from_file(input, "open observed CONIN$").expect("open observed CONIN$");
    let mut during = 0u32;
    assert_ne!(
        unsafe { GetConsoleMode(input.raw(), &mut during) },
        0,
        "read active mode"
    );
    write_console_modes(&state_path, &[during]).expect("write active console mode");
    during_ready
        .signal()
        .expect("signal active console mode ready");
    assert_eq!(
        unsafe { WaitForSingleObject(release.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "wait for observed process exit"
    );
    let mut after = 0u32;
    assert_ne!(
        unsafe { GetConsoleMode(input.raw(), &mut after) },
        0,
        "read restored mode"
    );
    write_console_modes(&state_path, &[during, after]).expect("write restored console mode");
    after_ready
        .signal()
        .expect("signal restored console mode ready");
    unsafe {
        FreeConsole();
    }
}

#[test]
fn console_session_run_cli_fixture_process() {
    if std::env::var(CONSOLE_SESSION_FIXTURE).as_deref() != Ok("1") {
        return;
    }
    let state_path = PathBuf::from(
        std::env::var_os(CONSOLE_SESSION_FIXTURE_STATE)
            .expect("console session fixture state path"),
    );
    let input = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
    assert!(!input.is_null(), "fixture console input handle is null");
    assert_ne!(
        input, INVALID_HANDLE_VALUE,
        "fixture console input handle is invalid"
    );
    let mut initial = 0u32;
    assert_ne!(
        unsafe { GetConsoleMode(input, &mut initial) },
        0,
        "read fixture initial console mode"
    );
    let seeded = (initial | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT) & !ENABLE_PROCESSED_INPUT;
    assert_ne!(
        unsafe { SetConsoleMode(input, seeded) },
        0,
        "seed fixture console mode"
    );
    write_console_modes(&state_path, &[seeded]).expect("write seeded fixture console mode");

    let code = winsmux_workspace::run_cli(&["connect".to_owned()]);
    let mut after = 0u32;
    assert_ne!(
        unsafe { GetConsoleMode(input, &mut after) },
        0,
        "read fixture restored console mode"
    );
    write_console_modes(&state_path, &[seeded, after, code as u32])
        .expect("write fixture console session result");
    assert_eq!(code, 130, "public run_cli(connect) cancellation exit");
    assert_eq!(
        after, seeded,
        "public run_cli(connect) restored seeded mode"
    );
}

#[test]
fn helper_lifecycle_fixture_process() {
    let Some(mode) = std::env::var_os(HELPER_FIXTURE_MODE) else {
        return;
    };
    let mode = mode.to_string_lossy();
    if mode == "diagnostic-exit" {
        eprintln!("{HELPER_FIXTURE_NOISE}");
        return;
    }
    let ready_name =
        std::env::var_os(HELPER_FIXTURE_READY_EVENT).expect("fixture ready event name");
    let ready = OwnedTestHandle::open_event(&ready_name.to_string_lossy(), EVENT_MODIFY_STATE)
        .expect("open fixture ready event");
    match mode.as_ref() {
        "exit-after-ready" | "hold-after-ready" => {
            let release_name =
                std::env::var_os(HELPER_FIXTURE_RELEASE_EVENT).expect("fixture release event name");
            let release =
                OwnedTestHandle::open_event(&release_name.to_string_lossy(), EVENT_ALL_ACCESS)
                    .expect("open fixture release event");
            ready.signal().expect("signal fixture ready");
            assert_eq!(
                unsafe { WaitForSingleObject(release.raw(), INFINITE) },
                WAIT_OBJECT_0,
                "wait for fixture release"
            );
            if mode == "exit-after-ready" {
                eprintln!("fixture exited before final event");
                return;
            }
            unreachable!("hold fixture was released unexpectedly");
        }
        "final-ready-success"
        | "final-ready-failure"
        | "final-missing"
        | "final-short"
        | "final-extra" => {
            let state_path = PathBuf::from(
                std::env::var_os(HELPER_FIXTURE_STATE_PATH).expect("fixture state path"),
            );
            match mode.as_ref() {
                "final-ready-success" | "final-ready-failure" => {
                    write_console_modes(&state_path, &[0x1122_3344, 0x5566_7788])
                        .expect("write valid fixture state");
                }
                "final-missing" => {}
                "final-short" => {
                    std::fs::write(&state_path, [0u8; 7]).expect("write short fixture state");
                }
                "final-extra" => {
                    std::fs::write(&state_path, [0u8; 9]).expect("write extra fixture state");
                }
                _ => unreachable!(),
            }
            ready.signal().expect("signal fixture final event");
            if mode == "final-ready-failure" {
                eprintln!("{HELPER_FIXTURE_NOISE}");
                std::process::exit(7);
            }
        }
        other => panic!("unknown helper fixture mode: {other}"),
    }
}

fn spawn_helper_fixture(
    mode: &str,
    ready_name: &str,
    release_name: Option<&str>,
    state_path: Option<&Path>,
) -> HelperLifecycle {
    HelperLifecycle::spawn(
        "helper lifecycle fixture",
        "helper_lifecycle_fixture_process",
        Stdio::null(),
        |command| {
            command
                .env_remove(HELPER_FIXTURE_MODE)
                .env_remove(HELPER_FIXTURE_READY_EVENT)
                .env_remove(HELPER_FIXTURE_RELEASE_EVENT)
                .env_remove(HELPER_FIXTURE_STATE_PATH)
                .env(HELPER_FIXTURE_MODE, mode)
                .env(HELPER_FIXTURE_READY_EVENT, ready_name);
            if let Some(release_name) = release_name {
                command.env(HELPER_FIXTURE_RELEASE_EVENT, release_name);
            }
            if let Some(state_path) = state_path {
                command.env(HELPER_FIXTURE_STATE_PATH, state_path.as_os_str());
            }
        },
    )
    .expect("spawn helper lifecycle fixture")
}

#[test]
fn helper_lifecycle_rejects_actual_helper_early_exit_and_diagnostic_noise() {
    let mutex_ready_name = format!("{}-ready", helper_run_stem("mutex-early-exit"));
    let mutex_ready =
        OwnedTestHandle::fresh_event(&mutex_ready_name).expect("create mutex early-exit event");
    let mut mutex = HelperLifecycle::spawn(
        "mutex owner helper",
        "mutex_owner_helper_process",
        Stdio::null(),
        |command| {
            command
                .env_remove(MUTEX_OWNER_HELPER)
                .env_remove(MUTEX_OWNER_READY_EVENT);
        },
    )
    .expect("spawn early-exit mutex helper");
    let error = mutex
        .wait_for_event(&mutex_ready, "mutex ownership", HelperStage::Intermediate)
        .expect_err("early-exit mutex helper must not report ownership");
    assert!(
        error.contains("ended before mutex ownership"),
        "unexpected early-exit diagnostic: {error}"
    );

    let console_ready_name = format!("{}-ready", helper_run_stem("console-early-exit"));
    let console_ready =
        OwnedTestHandle::fresh_event(&console_ready_name).expect("create console early-exit event");
    let mut console = HelperLifecycle::spawn(
        "console mode observer",
        "console_mode_observer_process",
        Stdio::null(),
        |command| {
            command
                .env_remove(CONSOLE_MODE_TARGET)
                .env_remove(CONSOLE_MODE_RELEASE_EVENT)
                .env_remove(CONSOLE_MODE_DURING_EVENT)
                .env_remove(CONSOLE_MODE_AFTER_EVENT)
                .env_remove(CONSOLE_MODE_STATE_PATH);
        },
    )
    .expect("spawn early-exit console helper");
    let error = console
        .wait_for_event(
            &console_ready,
            "active console mode",
            HelperStage::Intermediate,
        )
        .expect_err("early-exit console helper must not report active mode");
    assert!(
        error.contains("ended before active console mode"),
        "unexpected early-exit diagnostic: {error}"
    );

    let noise_ready_name = format!("{}-ready", helper_run_stem("diagnostic-noise"));
    let noise_ready =
        OwnedTestHandle::fresh_event(&noise_ready_name).expect("create diagnostic-noise event");
    let mut noise = spawn_helper_fixture("diagnostic-exit", &noise_ready_name, None, None);
    let error = noise
        .wait_for_event(&noise_ready, "fixture readiness", HelperStage::Intermediate)
        .expect_err("diagnostic text must not satisfy readiness");
    assert!(
        error.contains(HELPER_FIXTURE_NOISE),
        "helper stderr was not retained: {error}"
    );
}

#[test]
fn helper_lifecycle_enforces_stage_data_and_exit_status() {
    let stage_stem = helper_run_stem("intermediate-exit");
    let ready_name = format!("{stage_stem}-ready");
    let after_name = format!("{stage_stem}-after");
    let release_name = format!("{stage_stem}-release");
    let ready = OwnedTestHandle::fresh_event(&ready_name).expect("create fixture ready event");
    let after = OwnedTestHandle::fresh_event(&after_name).expect("create fixture after event");
    let release =
        OwnedTestHandle::fresh_event(&release_name).expect("create fixture release event");
    let mut staged =
        spawn_helper_fixture("exit-after-ready", &ready_name, Some(&release_name), None);
    staged
        .wait_for_event(&ready, "intermediate fixture", HelperStage::Intermediate)
        .expect("observe intermediate fixture");
    release.signal().expect("release intermediate fixture");
    let error = staged
        .wait_for_event(&after, "final fixture", HelperStage::Final)
        .expect_err("exit after intermediate stage must not satisfy final stage");
    assert!(
        error.contains("ended before final fixture"),
        "unexpected intermediate-exit diagnostic: {error}"
    );

    let success_name = format!("{}-final", helper_run_stem("final-success"));
    let success_ready =
        OwnedTestHandle::fresh_event(&success_name).expect("create success final event");
    let success_state = tempfile::NamedTempFile::new()
        .expect("create success fixture state")
        .into_temp_path();
    let mut success = spawn_helper_fixture(
        "final-ready-success",
        &success_name,
        None,
        Some(&success_state),
    );
    success
        .wait_for_event(&success_ready, "final fixture", HelperStage::Final)
        .expect("observe successful final event");
    assert_eq!(
        read_console_modes(&success_state, 2).expect("read successful final state"),
        [0x1122_3344, 0x5566_7788]
    );
    success.finish_success().expect("finish successful fixture");

    let failure_name = format!("{}-final", helper_run_stem("final-failure"));
    let failure_ready =
        OwnedTestHandle::fresh_event(&failure_name).expect("create failure final event");
    let failure_state = tempfile::NamedTempFile::new()
        .expect("create failure fixture state")
        .into_temp_path();
    let mut failure = spawn_helper_fixture(
        "final-ready-failure",
        &failure_name,
        None,
        Some(&failure_state),
    );
    failure
        .wait_for_event(&failure_ready, "final fixture", HelperStage::Final)
        .expect("observe failing final event");
    assert_eq!(
        read_console_modes(&failure_state, 2).expect("read failing final state"),
        [0x1122_3344, 0x5566_7788]
    );
    let error = failure
        .finish_success()
        .expect_err("non-success child status must reject final stage");
    assert!(
        error.contains(HELPER_FIXTURE_NOISE),
        "failure diagnostics were not retained: {error}"
    );

    for (mode, actual_bytes) in [
        ("final-missing", 0usize),
        ("final-short", 7usize),
        ("final-extra", 9usize),
    ] {
        let event_name = format!("{}-final", helper_run_stem(mode));
        let event = OwnedTestHandle::fresh_event(&event_name).expect("create invalid-data event");
        let state = tempfile::NamedTempFile::new()
            .expect("create invalid fixture state")
            .into_temp_path();
        let mut helper = spawn_helper_fixture(mode, &event_name, None, Some(&state));
        helper
            .wait_for_event(&event, "invalid-data final fixture", HelperStage::Final)
            .expect("observe invalid-data final event");
        let error = read_console_modes(&state, 2)
            .expect_err("invalid fixed-length data must reject final stage");
        assert!(
            error.contains(&format!("length was {actual_bytes}, expected 8")),
            "unexpected fixed-length diagnostic: {error}"
        );
        helper.finish_success().expect("reap invalid-data fixture");
    }

    for actual_bytes in [0usize, 3usize, 5usize] {
        let state = tempfile::NamedTempFile::new().expect("create during-mode state");
        std::fs::write(state.path(), vec![0u8; actual_bytes])
            .expect("write invalid during-mode state");
        let error = read_console_modes(state.path(), 1)
            .expect_err("during mode must contain exactly four bytes");
        assert!(
            error.contains(&format!("length was {actual_bytes}, expected 4")),
            "unexpected during-length diagnostic: {error}"
        );
    }
}

#[test]
fn helper_lifecycle_reaps_owned_child_after_wait_failure_and_panic() {
    let wait_stem = helper_run_stem("wait-failure");
    let wait_ready_name = format!("{wait_stem}-ready");
    let wait_release_name = format!("{wait_stem}-release");
    let wait_ready =
        OwnedTestHandle::fresh_event(&wait_ready_name).expect("create wait-failure ready event");
    let _wait_release = OwnedTestHandle::fresh_event(&wait_release_name)
        .expect("create wait-failure release event");
    let mut wait_helper = spawn_helper_fixture(
        "hold-after-ready",
        &wait_ready_name,
        Some(&wait_release_name),
        None,
    );
    wait_helper
        .wait_for_event(
            &wait_ready,
            "wait-failure fixture",
            HelperStage::Intermediate,
        )
        .expect("observe wait-failure fixture");
    let wait_process = wait_helper
        .duplicate_process_handle()
        .expect("duplicate wait-failure child handle");
    let error = wait_helper
        .wait_for_raw_event(
            std::ptr::null_mut(),
            "invalid event handle",
            HelperStage::Final,
        )
        .expect_err("invalid event handle must fail the wait");
    assert!(
        error.contains("wait failed"),
        "unexpected wait error: {error}"
    );
    drop(wait_helper);
    assert_eq!(
        unsafe { WaitForSingleObject(wait_process.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "wait-failure child was not reaped"
    );

    let panic_stem = helper_run_stem("panic-drop");
    let panic_ready_name = format!("{panic_stem}-ready");
    let panic_release_name = format!("{panic_stem}-release");
    let panic_ready =
        OwnedTestHandle::fresh_event(&panic_ready_name).expect("create panic ready event");
    let _panic_release =
        OwnedTestHandle::fresh_event(&panic_release_name).expect("create panic release event");
    let mut panic_helper = spawn_helper_fixture(
        "hold-after-ready",
        &panic_ready_name,
        Some(&panic_release_name),
        None,
    );
    panic_helper
        .wait_for_event(&panic_ready, "panic fixture", HelperStage::Intermediate)
        .expect("observe panic fixture");
    let panic_process = panic_helper
        .duplicate_process_handle()
        .expect("duplicate panic child handle");
    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _owned_helper = panic_helper;
        panic!("intentional helper lifecycle teardown proof");
    }));
    assert!(panic_result.is_err(), "teardown proof did not panic");
    assert_eq!(
        unsafe { WaitForSingleObject(panic_process.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "panic-owned child was not reaped"
    );
}

#[test]
fn connect_ready_wait_rejects_event_and_process_signaled_together() {
    let event_name = format!("{}-ready", helper_run_stem("simultaneous-ready-exit"));
    let event = OwnedTestHandle::fresh_event(&event_name).expect("create simultaneous event");
    let state = tempfile::NamedTempFile::new()
        .expect("create simultaneous fixture state")
        .into_temp_path();
    let mut helper = spawn_helper_fixture("final-ready-success", &event_name, None, Some(&state));
    let process = helper
        .duplicate_process_handle()
        .expect("duplicate simultaneous child handle");
    assert_eq!(
        unsafe { WaitForSingleObject(process.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "wait for simultaneous fixture exit"
    );
    assert_eq!(
        unsafe { WaitForSingleObject(event.raw(), 0) },
        WAIT_OBJECT_0,
        "simultaneous fixture did not signal its event"
    );
    let error = wait_for_connect_ready(event.raw(), process.raw(), "simultaneous fixture")
        .expect_err("a signaled process must reject a simultaneous ready event");
    assert!(
        error.contains("ended at the connect readiness observation point"),
        "unexpected simultaneous signal diagnostic: {error}"
    );
    helper
        .finish_success()
        .expect("reap simultaneous ready fixture");
}

#[test]
fn interactive_resources_reap_actual_children_on_panics_and_double_cleanup() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");

    let mut constructor_process = None;
    let constructor_panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _host = InteractiveHost::start_with_environment_after_spawn(
            &binary,
            home.path(),
            &["workspace", "connect"],
            &[],
            |resources| {
                constructor_process = Some(
                    resources
                        .duplicate_target_handle()
                        .expect("duplicate constructor-panic target handle"),
                );
                panic!("intentional interactive constructor teardown proof");
            },
        );
    }));
    assert!(
        constructor_panic.is_err(),
        "constructor proof did not panic"
    );
    assert_eq!(
        unsafe {
            WaitForSingleObject(
                constructor_process
                    .as_ref()
                    .expect("constructor target handle")
                    .raw(),
                INFINITE,
            )
        },
        WAIT_OBJECT_0,
        "constructor-panic target was not reaped"
    );

    let host =
        InteractiveHost::start_with_arguments(&binary, home.path(), &["workspace", "connect"]);
    let later_process = host
        .resources
        .duplicate_target_handle()
        .expect("duplicate later-panic target handle");
    let later_panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _owned_host = host;
        panic!("intentional interactive post-constructor teardown proof");
    }));
    assert!(later_panic.is_err(), "post-constructor proof did not panic");
    assert_eq!(
        unsafe { WaitForSingleObject(later_process.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "post-constructor panic target was not reaped"
    );

    let mut twice =
        InteractiveHost::start_with_arguments(&binary, home.path(), &["workspace", "connect"]);
    let twice_process = twice
        .resources
        .duplicate_target_handle()
        .expect("duplicate double-cleanup target handle");
    twice.resources.cleanup_nonpanic();
    twice.resources.cleanup_nonpanic();
    drop(twice);
    assert_eq!(
        unsafe { WaitForSingleObject(twice_process.raw(), 0) },
        WAIT_OBJECT_0,
        "double-cleanup target was not reaped"
    );
}

#[test]
fn owned_event_initialization_rejects_collision_and_releases_partial_state() {
    let event_name = helper_run_stem("event-collision");
    let result = (|| -> Result<(), String> {
        let _first = OwnedTestHandle::fresh_event(&event_name)?;
        let _collision = OwnedTestHandle::fresh_event(&event_name)?;
        Ok(())
    })();
    let error = result.expect_err("existing event name must reject partial initialization");
    assert_eq!(error, "event name already exists");

    let replacement =
        OwnedTestHandle::fresh_event(&event_name).expect("partial event handles were released");
    replacement
        .signal()
        .expect("signal replacement event after collision");
    assert_eq!(
        unsafe { WaitForSingleObject(replacement.raw(), INFINITE) },
        WAIT_OBJECT_0,
        "replacement event was not independently usable"
    );
}

struct PublicClient {
    child: ProcessChild,
    input: Option<ChildStdin>,
    output: OutputStream,
    stderr: Arc<Mutex<Vec<u8>>>,
    stderr_thread: Option<JoinHandle<()>>,
}

struct ClientExit {
    code: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

impl PublicClient {
    fn start(binary: &Path, home: &Path, discovery: &Value) -> Self {
        let mut child = Command::new(binary)
            .args(["workspace", "connect"])
            .env("USERPROFILE", home)
            .env("HOME", home)
            .env("WINSMUX_TASK862_MARKER", ENV_MARKER)
            .env_remove(CONNECT_READY_EVENT)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn public workspace client");
        let input = child.stdin.take().expect("client stdin");
        let stdout = child.stdout.take().expect("client stdout");
        let mut stderr_reader = child.stderr.take().expect("client stderr");
        let stderr = Arc::new(Mutex::new(Vec::new()));
        let thread_stderr = stderr.clone();
        let stderr_thread = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stderr_reader
                .read_to_end(&mut bytes)
                .expect("read client stderr");
            *thread_stderr.lock().expect("stderr capture") = bytes;
        });
        let mut result = Self {
            child,
            input: Some(input),
            output: OutputStream::start(Box::new(stdout)),
            stderr,
            stderr_thread: Some(stderr_thread),
        };
        let input = result.input.as_mut().expect("client input");
        let bytes = serde_json::to_vec(discovery).expect("discovery JSON");
        input.write_all(&bytes).expect("write trusted discovery");
        input.write_all(b"\r\n").expect("terminate discovery");
        input.flush().expect("flush trusted discovery");
        result
    }

    fn transact(&mut self, request: &Request) -> Response {
        let _ = write_request(self.input.as_mut().expect("client input"), request);
        parse_cli_response(request, self.output.next_json())
    }

    fn request_then_finish(mut self, request: &Request) -> ClientExit {
        if let Some(input) = self.input.as_mut() {
            let _ = input.write_all(&canonical_request(request).expect("canonical request"));
            let _ = input.write_all(b"\r\n");
            let _ = input.flush();
        }
        self.finish()
    }

    fn finish(mut self) -> ClientExit {
        drop(self.input.take());
        let status = self.child.wait().expect("wait public client");
        self.output.join();
        if let Some(thread) = self.stderr_thread.take() {
            thread.join().expect("stderr reader thread");
        }
        ClientExit {
            code: status.code().unwrap_or(1),
            stdout: self.output.captured(),
            stderr: self.stderr.lock().expect("stderr capture").clone(),
        }
    }
}

fn write_request(writer: &mut (dyn Write + Send), request: &Request) -> Vec<u8> {
    let bytes = canonical_request(request).expect("canonical request");
    writer.write_all(&bytes).expect("write request");
    writer.write_all(b"\r\n").expect("terminate request");
    writer.flush().expect("flush request");
    bytes
}

fn parse_cli_response(request: &Request, value: Value) -> Response {
    parse_response(
        request,
        &serde_json::to_vec(&value).expect("response JSON bytes"),
    )
    .unwrap_or_else(|error| panic!("response correlation: {error}: {value}"))
}

fn request(operation: &str, instance_id: Option<&str>, params: Value) -> Request {
    request_rev(operation, instance_id, None, params)
}

fn request_rev(
    operation: &str,
    instance_id: Option<&str>,
    revision: Option<u64>,
    params: Value,
) -> Request {
    let operation_id = format!(
        "20000000-0000-4000-8000-{:012x}",
        NEXT_OPERATION.fetch_add(1, Ordering::SeqCst)
    );
    let value = json!({
        "schema_version": 1,
        "instance_id": instance_id,
        "operation_id": operation_id,
        "expected_topology_revision": revision,
        "operation": operation,
        "params": params,
    });
    parse_request(&serde_json::to_vec(&value).expect("request JSON"))
        .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).expect("serialize value")
}

fn assert_error(response: &Response, code: &str) {
    let response = value(response);
    assert_eq!(response["accepted"], json!(false), "{response}");
    assert_eq!(response["error"]["code"], json!(code), "{response}");
}

fn assert_success(response: &Response, operation: &str) -> Value {
    let response = value(response);
    assert_eq!(response["accepted"], json!(true), "{response}");
    assert_eq!(response["result"]["operation"], json!(operation));
    response
}

fn stop_after_provider_cleanup(host: &mut InteractiveHost, instance: &str) -> Response {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        let response = host.transact(&request("host.stop", Some(instance), json!({})));
        if value(&response)["accepted"] == json!(true) {
            return response;
        }
        assert_error(&response, "operation_conflict");
        assert!(
            std::time::Instant::now() < deadline,
            "provider cleanup did not finish before host.stop"
        );
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}

fn wait_for_host_mutex_release() {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        if let Ok(owned) = acquire_host_mutex_probe() {
            drop(owned);
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "previous host retained the singleton mutex after owner exit"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[test]
fn real_owner_and_granted_client_preview_selected_artifact() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("isolated home");
    let project = home.path().join("artifact-project");
    std::fs::create_dir(&project).expect("project directory");
    let text = "selected 日本語\n";
    std::fs::write(project.join("result.txt"), text.as_bytes()).expect("selected text");
    std::fs::write(project.join("binary.bin"), [0u8, 255, 42]).expect("selected binary");

    let mut host = InteractiveHost::start(&binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().expect("instance ID");
    let opened = assert_success(&host.transact(&request_rev(
        "project.open", Some(instance), Some(0), json!({"path":project.to_string_lossy()}),
    )), "project.open");
    let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    let created = assert_success(&host.transact(&request_rev(
        "pane.create", Some(instance), opened["topology_revision"].as_u64(),
        json!({"project_id":project_id,"shell_profile_id":"pwsh"}),
    )), "pane.create");
    let run_id = created["result"]["data"]["run_id"].as_str().unwrap();
    let registered = assert_success(&host.transact(&request(
        "artifact.register", Some(instance),
        json!({"project_id":project_id,"relative_path":"result.txt","run_id":run_id}),
    )), "artifact.register");
    assert_eq!(registered["result"]["data"]["artifact"]["run_id"], run_id);
    assert_eq!(registered["result"]["data"]["artifact"]["association"], "caller_selected");
    let artifact_id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let preview = assert_success(&host.transact(&request(
        "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
    )), "artifact.read");
    assert_eq!(preview["result"]["data"]["text"], text);
    assert_eq!(preview["result"]["data"]["truncated"], false);
    assert_eq!(std::fs::read(project.join("result.txt")).unwrap(), text.as_bytes());

    let mut client = PublicClient::start(&binary, home.path(), &discovery);
    let pending = assert_success(&client.transact(&request(
        "connection.request", None,
        json!({"project_ids":[project_id],"scopes":["read_output"]}),
    )), "connection.request");
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
    assert_success(&host.transact(&request(
        "connection.decide", Some(instance),
        json!({"connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"]}),
    )), "connection.decide");
    let listed = assert_success(&client.transact(&request(
        "artifact.list", Some(instance), json!({"project_id":project_id}),
    )), "artifact.list");
    assert_eq!(listed["result"]["data"]["registered"].as_array().unwrap().len(), 1);
    let client_read = assert_success(&client.transact(&request(
        "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":4}),
    )), "artifact.read");
    assert_eq!(client_read["result"]["data"]["text"], "sele");
    assert_eq!(client_read["result"]["data"]["truncated"], true);
    let binary = assert_success(&client.transact(&request(
        "artifact.register", Some(instance),
        json!({"project_id":project_id,"relative_path":"binary.bin","run_id":null}),
    )), "artifact.register");
    let binary_id = binary["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let binary_read = assert_success(&client.transact(&request(
        "artifact.read", Some(instance), json!({"artifact_id":binary_id,"max_bytes":100}),
    )), "artifact.read");
    assert_eq!(binary_read["result"]["data"]["kind"], "binary");
    assert_eq!(binary_read["result"]["data"]["text"], Value::Null);
    assert_eq!(std::fs::read(project.join("binary.bin")).unwrap(), [0u8, 255, 42]);
    drop(client.finish());
    let interrupted = assert_success(&host.transact(&request(
        "run.interrupt", Some(instance), json!({"run_id":run_id}),
    )), "run.interrupt");
    assert_eq!(interrupted["result"]["data"]["phase"], "accepted");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let observed = assert_success(&host.transact(&request(
            "run.get", Some(instance), json!({"run_id":run_id}),
        )), "run.get");
        if observed["result"]["data"]["run"]["process"] == "exited" {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "run remained active: {observed}");
        std::thread::yield_now();
    }
    assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
}

struct ReadSentinelOplock {
    file: HANDLE,
    event: HANDLE,
    _output: Box<REQUEST_OPLOCK_OUTPUT_BUFFER>,
    _overlapped: Box<OVERLAPPED>,
}

impl ReadSentinelOplock {
    fn start(path: &Path) -> Self {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let file = unsafe { CreateFileW(
            wide.as_ptr(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(), OPEN_EXISTING, FILE_FLAG_OVERLAPPED, std::ptr::null_mut(),
        ) };
        assert!(!file.is_null() && file != INVALID_HANDLE_VALUE);
        let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
        assert!(!event.is_null());
        let input = REQUEST_OPLOCK_INPUT_BUFFER {
            StructureVersion: 1,
            StructureLength: std::mem::size_of::<REQUEST_OPLOCK_INPUT_BUFFER>() as u16,
            RequestedOplockLevel: OPLOCK_LEVEL_CACHE_READ | OPLOCK_LEVEL_CACHE_WRITE
                | OPLOCK_LEVEL_CACHE_HANDLE,
            Flags: REQUEST_OPLOCK_INPUT_FLAG_REQUEST,
        };
        let mut output = Box::new(REQUEST_OPLOCK_OUTPUT_BUFFER {
            StructureVersion: 1,
            StructureLength: std::mem::size_of::<REQUEST_OPLOCK_OUTPUT_BUFFER>() as u16,
            ..Default::default()
        });
        let mut overlapped = Box::<OVERLAPPED>::default();
        overlapped.hEvent = event;
        let mut transferred = 0;
        let granted = unsafe { DeviceIoControl(
            file, FSCTL_REQUEST_OPLOCK, (&input as *const REQUEST_OPLOCK_INPUT_BUFFER).cast(),
            std::mem::size_of::<REQUEST_OPLOCK_INPUT_BUFFER>() as u32,
            (&mut *output as *mut REQUEST_OPLOCK_OUTPUT_BUFFER).cast(),
            std::mem::size_of::<REQUEST_OPLOCK_OUTPUT_BUFFER>() as u32,
            &mut transferred, &mut *overlapped,
        ) };
        assert_eq!(granted, 0);
        assert_eq!(unsafe { GetLastError() }, windows_sys::Win32::Foundation::ERROR_IO_PENDING);
        Self { file, event, _output: output, _overlapped: overlapped }
    }

    fn broke(&self) -> bool {
        (unsafe { WaitForSingleObject(self.event, 0) }) == WAIT_OBJECT_0
    }
}

impl Drop for ReadSentinelOplock {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.file); CloseHandle(self.event); }
    }
}

#[test]
fn fixed_git_reader_consumes_only_frame_when_source_metadata_appears_mid_read() {
    use sha2::{Digest, Sha256};

    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join("source");
    std::fs::create_dir_all(project.join(".git/objects/info")).unwrap();
    let sentinel = home.path().join("outside-sentinel.txt");
    std::fs::write(&sentinel, b"readable outside sentinel\n").unwrap();
    let mut body = b"WSMXGIT4".to_vec();
    body.push(1); // list
    body.push(0); // case-sensitive ignore matching
    body.extend_from_slice(&0u32.to_le_bytes());
    body.extend_from_slice(&0u16.to_le_bytes());
    body.extend_from_slice(&2u32.to_le_bytes());
    for (name, bytes) in [
        (".git/HEAD", b"ref: refs/heads/main\n".as_slice()),
        ("tracked.txt", b"observed bytes\n".as_slice()),
    ] {
        body.extend_from_slice(&(name.len() as u16).to_le_bytes());
        body.extend_from_slice(name.as_bytes());
        body.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        body.extend_from_slice(bytes);
    }
    body.extend_from_slice(&Sha256::digest(&body));
    let mut frame = (body.len() as u32).to_le_bytes().to_vec();
    frame.extend_from_slice(&body);

    let watch = ReadSentinelOplock::start(&sentinel);
    let mut child = Command::new(binary())
        .arg("--winsmux-internal-git-reader")
        .current_dir(home.path())
        .env_clear()
        .env("SystemRoot", std::env::var_os("SystemRoot").unwrap())
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let midpoint = frame.len() / 2;
    stdin.write_all(&frame[..midpoint]).unwrap();
    stdin.flush().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(50));
    std::fs::write(project.join(".git/config"),
        format!("[include]\npath = {}\n", sentinel.display())).unwrap();
    std::fs::write(project.join(".git/objects/info/alternates"),
        format!("{}\n", sentinel.display())).unwrap();
    stdin.write_all(&frame[midpoint..]).unwrap();
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "fixed reader failed: {}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stdout.len() >= 4);
    let size = u32::from_le_bytes(output.stdout[..4].try_into().unwrap()) as usize;
    assert_eq!(size + 4, output.stdout.len());
    let response: Value = serde_json::from_slice(&output.stdout[4..]).unwrap();
    assert_eq!(response["result"], "list");
    assert_eq!(response["paths"], json!(["tracked.txt"]));
    assert!(!watch.broke(), "fixed helper opened the readable outside sentinel");
    drop(watch);
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"readable outside sentinel\n");
}

#[test]
fn git_worker_start_failures_preserve_real_owner_and_client_generation() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    for fault in [
        "WINSMUX_TASK867_FAIL_GIT_FIRST_WORKER_START",
        "WINSMUX_TASK867_FAIL_GIT_SECOND_WORKER_START",
    ] {
        let home = tempfile::tempdir().unwrap();
        let project = home.path().join("git-worker-fault");
        std::fs::create_dir(&project).unwrap();
        let git = |args: &[&str]| {
            let output = Command::new(r"C:\Program Files\Git\bin\git.exe")
                .current_dir(&project).env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", "NUL").args(args).output().unwrap();
            assert!(output.status.success(), "git fixture failed: {}", String::from_utf8_lossy(&output.stderr));
        };
        git(&["init", "-q"]);
        std::fs::write(project.join("result.txt"), b"base\n").unwrap();
        git(&["add", "--", "result.txt"]);
        git(&["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base"]);
        std::fs::write(project.join("result.txt"), b"modified\n").unwrap();
        let mut host = InteractiveHost::start_with_environment(
            &binary, home.path(), &["workspace", "host"], &[(fault, "1")],
        );
        let discovery = host.discovery();
        let instance = discovery["instance_id"].as_str().unwrap();
        let opened = assert_success(&host.transact(&request_rev(
            "project.open", Some(instance), Some(0), json!({"path":project.to_string_lossy()}),
        )), "project.open");
        let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
        let registered = assert_success(&host.transact(&request(
            "artifact.register", Some(instance),
            json!({"project_id":project_id,"relative_path":"result.txt","run_id":null}),
        )), "artifact.register");
        let artifact_id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
        assert_error(&host.transact(&request(
            "artifact.list", Some(instance), json!({"project_id":project_id}),
        )), "resource_exhausted");
        let capabilities = assert_success(&host.transact(&request(
            "capabilities.get", Some(instance), json!({}),
        )), "capabilities.get");
        assert_eq!(capabilities["instance_id"], instance);
        let read = assert_success(&host.transact(&request(
            "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
        )), "artifact.read");
        assert_eq!(read["result"]["data"]["text"], "modified\n");
        let mut client = PublicClient::start(&binary, home.path(), &discovery);
        let pending = assert_success(&client.transact(&request(
            "connection.request", None, json!({"project_ids":[project_id],"scopes":["read_output"]}),
        )), "connection.request");
        let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
        assert_success(&host.transact(&request(
            "connection.decide", Some(instance), json!({
                "connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"],
            }),
        )), "connection.decide");
        assert_error(&client.transact(&request(
            "artifact.list", Some(instance), json!({"project_id":project_id}),
        )), "resource_exhausted");
        let client_read = assert_success(&client.transact(&request(
            "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
        )), "artifact.read");
        assert_eq!(client_read["result"]["data"]["text"], "modified\n");
        assert_eq!(client.finish().code, 0);
        assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
        assert_eq!(host.wait_for_exit().code, 0);
        assert_eq!(std::fs::read(project.join("result.txt")).unwrap(), b"modified\n");
    }
}

#[test]
fn real_git_ignore_candidates_match_git_status_for_all_case_modes() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().unwrap();
    let mut host = InteractiveHost::start(&binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().unwrap();
    let mut revision = 0;
    for (case, setting) in [("true", Some("true")), ("false", Some("false")), ("absent", None)] {
        let project = home.path().join(format!("ignore-{case}"));
        std::fs::create_dir(&project).unwrap();
        let git = |args: &[&str]| {
            let output = Command::new(r"C:\Program Files\Git\bin\git.exe")
                .current_dir(&project).env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", "NUL").args(args).output().unwrap();
            assert!(output.status.success(), "git fixture {case}: {}", String::from_utf8_lossy(&output.stderr));
            output.stdout
        };
        git(&["init", "-q"]);
        match setting {
            Some(value) => { git(&["config", "core.ignoreCase", value]); }
            None => { git(&["config", "--unset", "core.ignoreCase"]); }
        }
        std::fs::write(project.join("TRACE.LOG"), b"base\n").unwrap();
        git(&["add", "--", "TRACE.LOG"]);
        git(&["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base"]);
        std::fs::write(project.join("TRACE.LOG"), b"changed\n").unwrap();
        std::fs::write(project.join(".gitignore"), b"*.log\n!keep.log\nblocked/\n").unwrap();
        std::fs::write(project.join(".gitattributes"), b"# harmless\n").unwrap();
        std::fs::write(project.join(".gitmodules"), b"# harmless\n").unwrap();
        std::fs::write(project.join("UPPER.LOG"), b"case check\n").unwrap();
        std::fs::write(project.join("drop.log"), b"ignored\n").unwrap();
        std::fs::write(project.join("keep.log"), b"negated\n").unwrap();
        std::fs::create_dir(project.join("nested")).unwrap();
        std::fs::write(project.join("nested/.gitignore"), b"*.tmp\n!keep.tmp\n").unwrap();
        std::fs::write(project.join("nested/drop.tmp"), b"ignored\n").unwrap();
        std::fs::write(project.join("nested/keep.tmp"), b"negated\n").unwrap();
        std::fs::create_dir(project.join("blocked")).unwrap();
        std::fs::write(project.join("blocked/.gitignore"), b"!keep.txt\n").unwrap();
        std::fs::write(project.join("blocked/keep.txt"), b"parent ignored\n").unwrap();
        let porcelain = git(&["status", "--porcelain=v1", "--untracked-files=all", "-z"]);
        let mut expected = porcelain.split(|byte| *byte == 0).filter(|entry| !entry.is_empty())
            .map(|entry| {
                assert!(entry.len() >= 4 && entry[2] == b' ', "unexpected porcelain row: {entry:?}");
                String::from_utf8(entry[3..].to_vec()).unwrap().replace('\\', "/")
            }).collect::<Vec<_>>();
        expected.sort();
        let opened = assert_success(&host.transact(&request_rev(
            "project.open", Some(instance), Some(revision), json!({"path":project.to_string_lossy()}),
        )), "project.open");
        revision = opened["topology_revision"].as_u64().unwrap();
        let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
        let listed = assert_success(&host.transact(&request(
            "artifact.list", Some(instance), json!({"project_id":project_id}),
        )), "artifact.list");
        let mut actual = listed["result"]["data"]["git_candidates"].as_array().unwrap().iter()
            .map(|value| value.as_str().unwrap().to_owned()).collect::<Vec<_>>();
        actual.sort();
        assert_eq!(actual, expected, "case {case} candidate mismatch");
        assert!(actual.contains(&"TRACE.LOG".to_owned()), "tracked ignore rule must not hide status");
        assert_eq!(actual.contains(&"UPPER.LOG".to_owned()), setting != Some("true"));
        assert!(actual.contains(&"keep.log".to_owned()));
        assert!(actual.contains(&"nested/keep.tmp".to_owned()));
        assert!(!actual.contains(&"blocked/keep.txt".to_owned()));
    }
    assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
}

#[test]
fn git_diff_keeps_selected_file_and_root_held_after_helper_reply() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join("held-diff");
    std::fs::create_dir(&project).unwrap();
    let git = |args: &[&str]| {
        let output = Command::new(r"C:\Program Files\Git\bin\git.exe")
            .current_dir(&project).env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "NUL").args(args).output().unwrap();
        assert!(output.status.success(), "git fixture: {}", String::from_utf8_lossy(&output.stderr));
    };
    git(&["init", "-q"]);
    std::fs::write(project.join("selected.txt"), b"base\n").unwrap();
    git(&["add", "--", "selected.txt"]);
    git(&["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base"]);
    std::fs::write(project.join("selected.txt"), b"changed\n").unwrap();
    let nonce = format!("{}-{}", std::process::id(), NEXT_OPERATION.fetch_add(1, Ordering::Relaxed));
    let ready_name = format!("Local\\winsmux-p04-diff-ready-{nonce}");
    let release_name = format!("Local\\winsmux-p04-diff-release-{nonce}");
    let ready = OwnedTestHandle::fresh_event(&ready_name).unwrap();
    let release = OwnedTestHandle::fresh_event(&release_name).unwrap();
    let mut host = InteractiveHost::start_with_environment(&binary, home.path(), &["workspace", "host"], &[
        ("WINSMUX_TASK867_DIFF_READY_EVENT", &ready_name),
        ("WINSMUX_TASK867_DIFF_RELEASE_EVENT", &release_name),
    ]);
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().unwrap().to_owned();
    let opened = assert_success(&host.transact(&request_rev(
        "project.open", Some(&instance), Some(0), json!({"path":project.to_string_lossy()}),
    )), "project.open");
    let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    let registered = assert_success(&host.transact(&request(
        "artifact.register", Some(&instance),
        json!({"project_id":project_id,"relative_path":"selected.txt","run_id":null}),
    )), "artifact.register");
    let artifact_id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let diff_request = request("artifact.diff", Some(&instance), json!({"artifact_id":artifact_id,"max_bytes":4096}));
    let project_for_race = project.clone();
    let moved_root = home.path().join("moved-root");
    let ready_handle = ready.raw() as usize;
    let release_handle = release.raw() as usize;
    let worker = std::thread::spawn(move || {
        let entered = unsafe { WaitForSingleObject(ready_handle as HANDLE, 30_000) };
        let denied = if entered == WAIT_OBJECT_0 {
            (
                std::fs::write(project_for_race.join("selected.txt"), b"wrong target\n").is_err(),
                std::fs::rename(project_for_race.join("selected.txt"), project_for_race.join("replacement.txt")).is_err(),
                std::fs::rename(&project_for_race, moved_root).is_err(),
            )
        } else { (false, false, false) };
        assert_ne!(unsafe { SetEvent(release_handle as HANDLE) }, 0);
        (entered, denied)
    });
    let response = host.transact(&diff_request);
    let (entered, denied) = worker.join().unwrap();
    assert_eq!(entered, WAIT_OBJECT_0, "helper result did not reach held publication window");
    assert_eq!(denied, (true, true, true), "selected file or root was mutable before response");
    let result = assert_success(&response, "artifact.diff");
    assert!(result["result"]["data"]["text"].as_str().unwrap().contains("+changed"));
    assert_eq!(std::fs::read(project.join("selected.txt")).unwrap(), b"changed\n");
    assert_success(&stop_after_provider_cleanup(&mut host, &instance), "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
}

#[test]
fn real_owner_and_client_review_git_results_without_writing_sources() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("isolated home");
    let project = home.path().join("review-project");
    std::fs::create_dir(&project).unwrap();
    let git = |args: &[&str]| {
        let output = Command::new(r"C:\Program Files\Git\bin\git.exe")
            .current_dir(&project)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "NUL")
            .args(args).output().unwrap();
        assert!(output.status.success(), "synthetic git fixture: {}", String::from_utf8_lossy(&output.stderr));
    };
    git(&["init", "-q"]);
    std::fs::write(project.join("left.txt"), b"base\n").unwrap();
    git(&["add", "--", "left.txt"]);
    git(&["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base"]);
    std::fs::write(project.join("left.txt"), b"chosen left\n").unwrap();
    std::fs::write(project.join("right.bin"), [0u8, 255, 42]).unwrap();

    let mut host = InteractiveHost::start(&binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().unwrap();
    let opened = assert_success(&host.transact(&request_rev(
        "project.open", Some(instance), Some(0), json!({"path":project.to_string_lossy()}),
    )), "project.open");
    let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    let left = assert_success(&host.transact(&request(
        "artifact.register", Some(instance),
        json!({"project_id":project_id,"relative_path":"left.txt","run_id":null}),
    )), "artifact.register");
    let right = assert_success(&host.transact(&request(
        "artifact.register", Some(instance),
        json!({"project_id":project_id,"relative_path":"right.bin","run_id":null}),
    )), "artifact.register");
    let left_id = left["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let right_id = right["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let read_left = assert_success(&host.transact(&request(
        "artifact.read", Some(instance), json!({"artifact_id":left_id,"max_bytes":100}),
    )), "artifact.read");
    let read_right = assert_success(&host.transact(&request(
        "artifact.read", Some(instance), json!({"artifact_id":right_id,"max_bytes":100}),
    )), "artifact.read");
    assert_eq!(read_left["result"]["data"]["text"], "chosen left\n");
    assert_eq!(read_right["result"]["data"]["kind"], "binary");
    let listed = assert_success(&host.transact(&request(
        "artifact.list", Some(instance), json!({"project_id":project_id}),
    )), "artifact.list");
    assert_eq!(listed["result"]["data"]["registered"].as_array().unwrap().len(), 2);
    assert_eq!(listed["result"]["data"]["git_candidates"], json!(["left.txt", "right.bin"]));
    let diff_left = assert_success(&host.transact(&request(
        "artifact.diff", Some(instance), json!({"artifact_id":left_id,"max_bytes":4096}),
    )), "artifact.diff");
    assert!(diff_left["result"]["data"]["text"].as_str().unwrap().contains("+chosen left"));
    std::fs::write(project.join("left.txt"), b"base\n").unwrap();
    let unchanged_owner = assert_success(&host.transact(&request(
        "artifact.diff", Some(instance), json!({"artifact_id":left_id,"max_bytes":4096}),
    )), "artifact.diff");
    assert_eq!(unchanged_owner["result"]["data"]["kind"], "text");
    assert_eq!(unchanged_owner["result"]["data"]["text"], "");
    std::fs::write(project.join("left.txt"), b"chosen left\n").unwrap();
    let diff_right = assert_success(&host.transact(&request(
        "artifact.diff", Some(instance), json!({"artifact_id":right_id,"max_bytes":4096}),
    )), "artifact.diff");
    assert_eq!(diff_right["result"]["data"]["kind"], "binary");
    assert!(diff_right["result"]["data"]["text"].is_null());

    let choice = assert_success(&host.transact(&request(
        "artifact.choose", Some(instance), json!({
            "project_id":project_id,"left_artifact_id":right_id,
            "right_artifact_id":left_id,"kept_artifact_id":left_id,
        }),
    )), "artifact.choose");
    assert_eq!(choice["result"]["data"]["kept_artifact_id"], left_id);
    let mut client = PublicClient::start(&binary, home.path(), &discovery);
    let pending = assert_success(&client.transact(&request(
        "connection.request", None, json!({"project_ids":[project_id],"scopes":["read_output"]}),
    )), "connection.request");
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
    assert_success(&host.transact(&request(
        "connection.decide", Some(instance), json!({
            "connection_id":connection_id,"decision":"allow","project_ids":[project_id],"scopes":["read_output"],
        }),
    )), "connection.decide");
    std::fs::write(project.join("left.txt"), b"base\n").unwrap();
    let unchanged_client = assert_success(&client.transact(&request(
        "artifact.diff", Some(instance), json!({"artifact_id":left_id,"max_bytes":4096}),
    )), "artifact.diff");
    assert_eq!(unchanged_client["result"]["data"]["kind"], "text");
    assert_eq!(unchanged_client["result"]["data"]["text"], "");
    std::fs::write(project.join("left.txt"), b"chosen left\n").unwrap();
    let choices = assert_success(&client.transact(&request(
        "artifact.choice.list", Some(instance), json!({"project_id":project_id}),
    )), "artifact.choice.list");
    assert_eq!(choices["result"]["data"]["choices"].as_array().unwrap().len(), 1);
    assert_error(&client.transact(&request(
        "artifact.choose", Some(instance), json!({
            "project_id":project_id,"left_artifact_id":left_id,
            "right_artifact_id":right_id,"kept_artifact_id":right_id,
        }),
    )), "permission_denied");
    drop(client.finish());
    let rechoice = assert_success(&host.transact(&request(
        "artifact.choose", Some(instance), json!({
            "project_id":project_id,"left_artifact_id":left_id,
            "right_artifact_id":right_id,"kept_artifact_id":right_id,
        }),
    )), "artifact.choose");
    assert_eq!(rechoice["result"]["data"]["kept_artifact_id"], right_id);
    let sentinel = home.path().join("outside-sentinel.txt");
    std::fs::write(&sentinel, b"readable outside sentinel\n").unwrap();
    let positive_watch = ReadSentinelOplock::start(&sentinel);
    let sentinel_read = sentinel.clone();
    let positive = std::thread::spawn(move || std::fs::read(sentinel_read));
    assert_eq!(unsafe { WaitForSingleObject(positive_watch.event, 5000) }, WAIT_OBJECT_0,
        "OS oplock must observe the positive-control read");
    drop(positive_watch);
    assert_eq!(positive.join().unwrap().unwrap(), b"readable outside sentinel\n");

    let config = project.join(".git/config");
    let original_config = std::fs::read(&config).unwrap();
    let mut injected_config = original_config.clone();
    injected_config.extend_from_slice(format!("\n[include]\npath = {}\n", sentinel.display()).as_bytes());
    std::fs::write(&config, injected_config).unwrap();
    let watch = ReadSentinelOplock::start(&sentinel);
    assert_error(&host.transact(&request(
        "artifact.list", Some(instance), json!({"project_id":project_id}),
    )), "unsupported_file");
    assert!(!watch.broke(), "source config include never opened outside sentinel");
    drop(watch);
    std::fs::write(&config, original_config).unwrap();

    std::fs::write(project.join(".git/objects/info/alternates"),
        format!("{}\n", sentinel.display())).unwrap();
    let watch = ReadSentinelOplock::start(&sentinel);
    assert_error(&host.transact(&request(
        "artifact.list", Some(instance), json!({"project_id":project_id}),
    )), "unsupported_file");
    assert!(!watch.broke(), "source alternates never opened outside sentinel");
    drop(watch);
    let independent = assert_success(&host.transact(&request(
        "artifact.choice.list", Some(instance), json!({"project_id":project_id}),
    )), "artifact.choice.list");
    assert_eq!(independent["result"]["data"]["choices"][0]["kept_artifact_id"], right_id);
    assert_eq!(std::fs::read(project.join("left.txt")).unwrap(), b"chosen left\n");
    assert_eq!(std::fs::read(project.join("right.bin")).unwrap(), [0u8, 255, 42]);
    assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
}

#[test]
fn optional_artifact_sidecar_failures_keep_real_owner_generation_usable() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    for fault in [
        "WINSMUX_TASK867_FAIL_SIDECAR_CREATE",
        "WINSMUX_TASK867_FAIL_SIDECAR_ADMISSION",
        "WINSMUX_TASK867_FAIL_SIDECAR_RESOURCE",
        "WINSMUX_TASK867_FAIL_SIDECAR_PROOF",
    ] {
        let home = tempfile::tempdir().expect("isolated home");
        let project = home.path().join("ordinary-project");
        std::fs::create_dir(&project).unwrap();
        std::fs::write(project.join("result.txt"), b"still available\n").unwrap();
        let mut host = InteractiveHost::start_with_environment(
            &binary, home.path(), &["workspace", "host"], &[(fault, "1")],
        );
        let discovery = host.discovery();
        let instance = discovery["instance_id"].as_str().unwrap();
        let opened = assert_success(&host.transact(&request_rev(
            "project.open", Some(instance), Some(0), json!({"path":project.to_string_lossy()}),
        )), "project.open");
        let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
        let created = assert_success(&host.transact(&request_rev(
            "pane.create", Some(instance), opened["topology_revision"].as_u64(),
            json!({"project_id":project_id,"shell_profile_id":"pwsh"}),
        )), "pane.create");
        let run_id = created["result"]["data"]["run_id"].as_str().unwrap();
        let registered = assert_success(&host.transact(&request(
            "artifact.register", Some(instance),
            json!({"project_id":project_id,"relative_path":"result.txt","run_id":run_id}),
        )), "artifact.register");
        let artifact_id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();

        let unavailable = request(
            "artifact.choice.list", Some(instance), json!({"project_id":project_id}),
        );
        host.write_raw(&canonical_request(&unavailable).unwrap());
        let capabilities = assert_success(&host.transact(&request(
            "capabilities.get", Some(instance), json!({}),
        )), "capabilities.get");
        assert_eq!(capabilities["instance_id"], instance, "{fault}: host generation changed");
        assert_eq!(capabilities["result"]["data"]["operations"].as_array().unwrap().len(), 29);
        assert!(contains_bytes(
            &host.resources.output.as_ref().unwrap().captured(),
            b"winsmux workspace: protocol_failed",
        ), "{fault}: unavailable extension diagnostic was not emitted");
        let run = assert_success(&host.transact(&request(
            "run.get", Some(instance), json!({"run_id":run_id}),
        )), "run.get");
        assert_eq!(run["result"]["data"]["run"]["run_id"], run_id);
        let preview = assert_success(&host.transact(&request(
            "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
        )), "artifact.read");
        assert_eq!(preview["result"]["data"]["text"], "still available\n");

        let mut client = PublicClient::start(&binary, home.path(), &discovery);
        let pending = assert_success(&client.transact(&request(
            "connection.request", None,
            json!({"project_ids":[project_id],"scopes":["read_output"]}),
        )), "connection.request");
        let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
        assert_success(&host.transact(&request(
            "connection.decide", Some(instance), json!({
                "connection_id":connection_id,"decision":"allow",
                "project_ids":[project_id],"scopes":["read_output"],
            }),
        )), "connection.decide");
        let client_read = assert_success(&client.transact(&request(
            "artifact.read", Some(instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
        )), "artifact.read");
        assert_eq!(client_read["result"]["data"]["text"], "still available\n");
        assert_eq!(client.finish().code, 0);

        assert_success(&host.transact(&request(
            "run.interrupt", Some(instance), json!({"run_id":run_id}),
        )), "run.interrupt");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let observed = assert_success(&host.transact(&request(
                "run.get", Some(instance), json!({"run_id":run_id}),
            )), "run.get");
            if observed["result"]["data"]["run"]["process"] == "exited" { break; }
            assert!(std::time::Instant::now() < deadline, "{fault}: run remained active");
            std::thread::yield_now();
        }
        assert_eq!(std::fs::read(project.join("result.txt")).unwrap(), b"still available\n");
        assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
        assert_eq!(host.wait_for_exit().code, 0, "{fault}: owner host did not stop normally");
    }
}

#[test]
#[ignore = "run with WINSMUX_TASK867_OLD_HOST_BINARY built from frozen P01 tree"]
fn old_and_new_workspace_binaries_preserve_v1_and_reject_unproved_review() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let old = PathBuf::from(std::env::var_os("WINSMUX_TASK867_OLD_HOST_BINARY")
        .expect("exact P01 host binary path"));
    assert!(old.is_file(), "exact P01 host binary is required");
    let new = binary();
    let home = tempfile::tempdir().expect("isolated home");
    let project = home.path().join("ordinary-project");
    std::fs::create_dir(&project).unwrap();
    std::fs::write(project.join("result.txt"), b"old-host result\n").unwrap();

    let mut old_host = InteractiveHost::start(&old, home.path());
    let old_discovery = old_host.discovery();
    let old_instance = old_discovery["instance_id"].as_str().unwrap();
    let opened = assert_success(&old_host.transact(&request_rev(
        "project.open", Some(old_instance), Some(0), json!({"path":project.to_string_lossy()}),
    )), "project.open");
    let project_id = opened["result"]["data"]["project_id"].as_str().unwrap();
    let registered = assert_success(&old_host.transact(&request(
        "artifact.register", Some(old_instance), json!({
            "project_id":project_id,"relative_path":"result.txt","run_id":null,
        }),
    )), "artifact.register");
    let artifact_id = registered["result"]["data"]["artifact"]["artifact_id"].as_str().unwrap();
    let mut new_client = PublicClient::start(&new, home.path(), &old_discovery);
    let capabilities = assert_success(&new_client.transact(&request(
        "capabilities.get", None, json!({}),
    )), "capabilities.get");
    assert_eq!(capabilities["result"]["data"]["operations"].as_array().unwrap().len(), 29);
    let pending = assert_success(&new_client.transact(&request(
        "connection.request", None, json!({"project_ids":[project_id],"scopes":["read_output"]}),
    )), "connection.request");
    let connection_id = pending["result"]["data"]["connection_id"].as_str().unwrap();
    assert_success(&old_host.transact(&request(
        "connection.decide", Some(old_instance), json!({
            "connection_id":connection_id,"decision":"allow",
            "project_ids":[project_id],"scopes":["read_output"],
        }),
    )), "connection.decide");
    let listed = assert_success(&new_client.transact(&request(
        "artifact.list", Some(old_instance), json!({"project_id":project_id}),
    )), "artifact.list");
    assert_eq!(listed["result"]["data"]["registered"].as_array().unwrap().len(), 1);
    let rejected = request(
        "artifact.choice.list", Some(old_instance), json!({"project_id":project_id}),
    );
    let _ = write_request(new_client.input.as_mut().unwrap(), &rejected);
    let still_connected = assert_success(&new_client.transact(&request(
        "capabilities.get", None, json!({}),
    )), "capabilities.get");
    assert_eq!(still_connected["result"]["data"]["operations"].as_array().unwrap().len(), 29);
    let finished = new_client.finish();
    assert_eq!(finished.code, 0);
    assert_eq!(String::from_utf8(finished.stderr).unwrap().trim(),
        "winsmux workspace: protocol_failed");
    assert_eq!(extract_all_json(&finished.stdout).len(), 4,
        "only four ordinary v1 responses may be emitted");
    let readable = assert_success(&old_host.transact(&request(
        "artifact.read", Some(old_instance), json!({"artifact_id":artifact_id,"max_bytes":100}),
    )), "artifact.read");
    assert_eq!(readable["result"]["data"]["text"], "old-host result\n");
    assert_success(&old_host.transact(&request("host.stop", Some(old_instance), json!({}))), "host.stop");
    assert_eq!(old_host.wait_for_exit().code, 0);

    let mut new_host = InteractiveHost::start(&new, home.path());
    let new_discovery = new_host.discovery();
    let new_instance = new_discovery["instance_id"].as_str().unwrap();
    let mut old_client = PublicClient::start(&old, home.path(), &new_discovery);
    let capabilities = assert_success(&old_client.transact(&request(
        "capabilities.get", None, json!({}),
    )), "capabilities.get");
    assert_eq!(capabilities["result"]["data"]["operations"].as_array().unwrap().len(), 29);
    assert_eq!(old_client.finish().code, 0);
    assert_success(&stop_after_provider_cleanup(&mut new_host, new_instance), "host.stop");
    assert_eq!(new_host.wait_for_exit().code, 0);

    let mut old_host = InteractiveHost::start(&old, home.path());
    let old_discovery = old_host.discovery();
    let old_instance = old_discovery["instance_id"].as_str().unwrap();
    let mut old_client = PublicClient::start(&old, home.path(), &old_discovery);
    assert_success(&old_client.transact(&request("capabilities.get", None, json!({}))), "capabilities.get");
    assert_eq!(old_client.finish().code, 0);
    assert_success(&old_host.transact(&request("host.stop", Some(old_instance), json!({}))), "host.stop");
    assert_eq!(old_host.wait_for_exit().code, 0);
}

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_winsmux"))
}

// Codec failures are transport boundaries, never synthetic correlated refusals.
fn task871_empty_host_guard_codec_boundary(host_binary: &Path, reject_legal_guard: bool) {
    let home = tempfile::tempdir().expect("task871 dedicated empty host home");
    let mut host = InteractiveHost::start(host_binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().unwrap();
    let legacy = request_rev("pane.close", Some(instance), Some(0), json!({"pane_id":"40000000-0000-4000-8000-000000000000"}));
    assert_error(&host.transact(&legacy), "target_not_found");
    let mut client = PublicClient::start(&binary(), home.path(), &discovery);
    assert_success(&client.transact(&request("capabilities.get", None, json!({}))), "capabilities.get");
    let params = if reject_legal_guard {
        json!({"pane_id":"40000000-0000-4000-8000-000000000000","expected_current_run_id":null})
    } else {
        json!({"pane_id":"40000000-0000-4000-8000-000000000000","expected_current_run_id":false})
    };
    let input = json!({"schema_version":1,"instance_id":instance,"operation_id":"20000000-0000-4000-8000-000000000000","expected_topology_revision":0,"operation":"pane.close","params":params});
    // Owner codec failure closes its actual OS process and generation.
    host.write_raw(&serde_json::to_vec(&input).unwrap());
    let exit = host.wait_for_exit();
    assert_eq!(exit.code, 1, "{}", String::from_utf8_lossy(&exit.output));
    // ConPTY may interleave its mode-restoration CSI between the fixed prefix
    // and classification. Both must occur; JSON accounting remains exact.
    assert!(contains_bytes(&exit.output, b"winsmux workspace: "));
    assert!(contains_bytes(&exit.output, b"protocol_failed"));
    assert_eq!(extract_all_json(&exit.output).len(), 2, "discovery and legal legacy refusal only, no guarded Response");
    // The connected public client cannot observe a correlated close response.
    let query = request("capabilities.get", None, json!({}));
    let ended = client.request_then_finish(&query);
    assert_eq!(extract_all_json(&ended.stdout).len(), 1, "only pre-boundary capability response");
    assert_ne!(ended.code, 0, "closed generation must terminate public transport");
    wait_for_host_mutex_release();

    // Invalid public ingress cuts only this connection; the owner remains usable.
    let mut host = InteractiveHost::start(host_binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().unwrap();
    let mut client = PublicClient::start(&binary(), home.path(), &discovery);
    assert_success(&client.transact(&request("capabilities.get", None, json!({}))), "capabilities.get");
    let mut input = input;
    input["instance_id"] = json!(instance);
    let bytes = serde_json::to_vec(&input).unwrap();
    let writer = client.input.as_mut().unwrap();
    writer.write_all(&bytes).unwrap(); writer.write_all(b"\r\n").unwrap(); writer.flush().unwrap();
    let ended = client.finish();
    assert_eq!(extract_all_json(&ended.stdout).len(), 1, "public malformed request has no Response");
    assert_ne!(ended.code, 0);
    assert_success(&host.transact(&request("capabilities.get", None, json!({}))), "capabilities.get");
    assert_success(&stop_after_provider_cleanup(&mut host, instance), "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
    wait_for_host_mutex_release();
}

#[test]
fn task871_guard_present_invalid_has_actual_owner_and_public_protocol_boundaries() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    task871_empty_host_guard_codec_boundary(&binary(), false);
}

#[test]
#[ignore = "requires exact adopted tree622 old decoder binary in WINSMUX_TASK871_OLD_HOST_BINARY"]
fn task871_guard_new_request_old_decoder_has_actual_protocol_boundaries() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let old = PathBuf::from(std::env::var_os("WINSMUX_TASK871_OLD_HOST_BINARY").expect("exact tree622 binary"));
    assert!(old.is_file());
    task871_empty_host_guard_codec_boundary(&old, true);
}

fn fixed_environment(binary: &Path, home: &Path) -> Command {
    let mut command = Command::new(binary);
    command
        .env("USERPROFILE", home)
        .env("HOME", home)
        .env("WINSMUX_TASK862_MARKER", ENV_MARKER)
        .env_remove(CONNECT_READY_EVENT);
    command
}

fn assert_fixed_failure(output: std::process::Output, code: i32, classification: &str) {
    assert_eq!(output.status.code(), Some(code));
    assert!(
        output.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let stderr = String::from_utf8(output.stderr).expect("UTF-8 fixed diagnostic");
    assert_eq!(
        stderr.trim(),
        format!("winsmux workspace: {classification}")
    );
    for marker in [ENV_MARKER, ARG_MARKER, INPUT_MARKER] {
        assert!(
            !stderr.contains(marker),
            "diagnostic leaked marker: {stderr}"
        );
    }
}

fn create_legacy_fixture(home: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let directory = home.join(".psmux");
    std::fs::create_dir_all(&directory).expect("create legacy fixture directory");
    let fixtures = [
        (
            directory.join("legacy.port"),
            b"TASK862_PORT_BYTES\r\n".to_vec(),
        ),
        (
            directory.join("legacy.key"),
            b"TASK862_KEY_BYTES\0\xff".to_vec(),
        ),
        (
            directory.join("legacy.json"),
            b"{\"legacy\":true}\r\n".to_vec(),
        ),
    ];
    for (path, bytes) in &fixtures {
        std::fs::write(path, bytes).expect("write legacy fixture");
    }
    fixtures.into_iter().collect()
}

fn assert_fixture_unchanged(fixtures: &[(PathBuf, Vec<u8>)]) {
    for (path, expected) in fixtures {
        assert_eq!(std::fs::read(path).expect("read legacy fixture"), *expected);
    }
}

fn assert_client_transport_exit(exit: ClientExit) {
    assert_eq!(exit.code, 1, "{}", String::from_utf8_lossy(&exit.stderr));
    let stderr = String::from_utf8(exit.stderr).expect("client diagnostic UTF-8");
    assert_eq!(stderr.trim(), "winsmux workspace: transport_failed");
    let stdout = String::from_utf8_lossy(&exit.stdout);
    for marker in [ENV_MARKER, ARG_MARKER, INPUT_MARKER] {
        assert!(!stderr.contains(marker));
        assert!(!stdout.contains(marker));
    }
}

fn assert_client_protocol_exit(exit: ClientExit) {
    assert_eq!(exit.code, 1, "{}", String::from_utf8_lossy(&exit.stderr));
    assert!(
        exit.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&exit.stdout)
    );
    let stderr = String::from_utf8(exit.stderr).expect("client diagnostic UTF-8");
    assert_eq!(stderr.trim(), "winsmux workspace: protocol_failed");
    for marker in [ENV_MARKER, ARG_MARKER, INPUT_MARKER] {
        assert!(!stderr.contains(marker));
    }
}

fn run_redirected_connect(binary: &Path, home: &Path, input: &[u8]) -> std::process::Output {
    let mut child = fixed_environment(binary, home)
        .args(["workspace", "connect"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn redirected connect");
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input);
        let _ = stdin.flush();
    }
    child.wait_with_output().expect("wait redirected connect")
}

fn prove_public_run_cli_with_seeded_console_mode(home: &Path) {
    let ready_name = connect_ready_event_name();
    let ready = OwnedTestHandle::fresh_event(&ready_name).expect("create fixture ready event");
    let state = tempfile::NamedTempFile::new().expect("create console session fixture state");
    let state_value = state.path().as_os_str().to_string_lossy().into_owned();
    let current_exe = std::env::current_exe().expect("current test executable");
    let mut fixture = InteractiveHost::start_with_environment(
        &current_exe,
        home,
        &[
            "--exact",
            "console_session_run_cli_fixture_process",
            "--nocapture",
        ],
        &[
            (CONSOLE_SESSION_FIXTURE, "1"),
            (CONSOLE_SESSION_FIXTURE_STATE, state_value.as_str()),
            (CONNECT_READY_EVENT, ready_name.as_str()),
        ],
    );
    let target_handle = fixture
        .resources
        .target_process
        .as_ref()
        .expect("fixture target process handle");
    wait_for_connect_ready(ready.raw(), target_handle.raw(), "run_cli fixture")
        .expect("public run_cli(connect) readiness");
    let seeded = read_console_modes(state.path(), 1).expect("read seeded fixture mode")[0];
    assert_eq!(
        seeded & ENABLE_PROCESSED_INPUT,
        0,
        "fixture must seed processed input off"
    );
    assert_eq!(
        seeded & (ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT),
        ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT,
        "fixture must seed valid line and echo input"
    );
    fixture.observe_console_input("run-cli-connect-seeded-mode");
    let exit = fixture.ctrl_c_byte();
    assert_eq!(exit.code, 0, "{}", String::from_utf8_lossy(&exit.output));
    assert!(
        String::from_utf8_lossy(&exit.output).contains("cancelled"),
        "{}",
        String::from_utf8_lossy(&exit.output)
    );
    let modes = read_console_modes(state.path(), 3).expect("read console session fixture result");
    assert_eq!(modes, vec![seeded, seeded, 130]);
    println!(
        "TASK862_PUBLIC_RUN_CLI_MODE_PROOF seeded={} restored={} exit={}",
        modes[0], modes[1], modes[2]
    );
}

#[test]
fn workspace_connect_validates_discovery_and_cancels_while_waiting_for_it() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    prove_public_run_cli_with_seeded_console_mode(home.path());
    let canonical_bytes = canonical_discovery_json().expect("canonical discovery");
    let canonical: Value =
        serde_json::from_slice(&canonical_bytes).expect("canonical discovery JSON");
    let mut invalid = Vec::new();

    let mut value = canonical.clone();
    value["unknown"] = json!(INPUT_MARKER);
    invalid.push(serde_json::to_vec(&value).unwrap());

    let mut value = canonical.clone();
    value["schema_version"] = json!(2);
    invalid.push(serde_json::to_vec(&value).unwrap());

    let mut value = canonical.clone();
    value["instance_id"] = json!("not-a-uuid");
    invalid.push(serde_json::to_vec(&value).unwrap());

    let pipe = canonical["pipe_name"].as_str().expect("canonical pipe");
    let mut value = canonical.clone();
    value["pipe_name"] = json!(format!("{}A", &pipe[..pipe.len() - 1]));
    invalid.push(serde_json::to_vec(&value).unwrap());

    let prefix = r"\\.\pipe\winsmux-workspace-v1-";
    let rest = pipe.strip_prefix(prefix).expect("canonical pipe prefix");
    let mut changed_logon = rest.as_bytes().to_vec();
    changed_logon[0] = if changed_logon[0] == b'a' { b'b' } else { b'a' };
    let mut value = canonical.clone();
    value["pipe_name"] = json!(format!(
        "{prefix}{}",
        String::from_utf8(changed_logon).unwrap()
    ));
    invalid.push(serde_json::to_vec(&value).unwrap());

    for alias in [
        pipe.replacen(r"\\.\pipe\", r"\\server\pipe\", 1),
        pipe.replacen(r"\\.\pipe\", r"\\?\pipe\", 1),
        pipe.replacen(r"\\.\pipe\", r"\\.\PIPE\", 1),
        pipe.replacen(r"\\.\pipe\", r"\\.\pipe\\", 1),
    ] {
        let mut value = canonical.clone();
        value["pipe_name"] = json!(alias);
        invalid.push(serde_json::to_vec(&value).unwrap());
    }

    let instance = canonical["instance_id"].as_str().unwrap();
    invalid.push(
        format!(
            "{{\"instance_id\":\"{instance}\",\"instance_id\":\"{instance}\",\"pipe_name\":{},\"schema_version\":1}}",
            serde_json::to_string(pipe).unwrap()
        )
        .into_bytes(),
    );
    invalid.push([b"\xef\xbb\xbf".as_slice(), canonical_bytes.as_slice()].concat());
    invalid.push(b"".to_vec());
    invalid.push([canonical_bytes.as_slice(), canonical_bytes.as_slice()].concat());
    invalid.push(vec![b'x'; 1024 * 1024 + 2]);

    for mut bytes in invalid {
        bytes.push(b'\n');
        assert_fixed_failure(
            run_redirected_connect(&binary, home.path(), &bytes),
            1,
            "protocol_failed",
        );
    }

    let clean_eof = fixed_environment(&binary, home.path())
        .args(["workspace", "connect"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run connect with EOF before discovery");
    assert_eq!(clean_eof.status.code(), Some(0));
    assert!(clean_eof.stdout.is_empty());
    assert!(clean_eof.stderr.is_empty());

    let mut interactive_eof =
        InteractiveHost::start_with_arguments(&binary, home.path(), &["workspace", "connect"]);
    interactive_eof.observe_console_input("connect-discovery-eof");
    let eof_exit = interactive_eof.console_eof();
    assert_eq!(
        eof_exit.code,
        0,
        "{}",
        String::from_utf8_lossy(&eof_exit.output)
    );

    let mut interactive_ctrl =
        InteractiveHost::start_with_arguments(&binary, home.path(), &["workspace", "connect"]);
    interactive_ctrl.observe_console_input("connect-discovery-ctrl-c");
    let ctrl_exit = interactive_ctrl.ctrl_c_byte();
    assert_eq!(
        ctrl_exit.code,
        130,
        "{}",
        String::from_utf8_lossy(&ctrl_exit.output)
    );
    assert!(String::from_utf8_lossy(&ctrl_exit.output).contains("cancelled"));
}

#[test]
fn host_startup_fails_closed_before_discovery_when_security_primitives_fail() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    for injection in [FAIL_SERVER_TOKEN, FAIL_CNG] {
        let exit = InteractiveHost::start_with_environment(
            &binary,
            home.path(),
            &["workspace", "host"],
            &[(injection, "1")],
        )
        .wait_for_exit();
        assert_eq!(
            exit.code,
            1,
            "{injection}: {}",
            String::from_utf8_lossy(&exit.output)
        );
        assert!(
            String::from_utf8_lossy(&exit.output).contains("transport_failed"),
            "{injection}: {}",
            String::from_utf8_lossy(&exit.output)
        );
        assert!(
            extract_all_json(&exit.output).is_empty(),
            "{injection}: {}",
            String::from_utf8_lossy(&exit.output)
        );
    }
}

#[test]
fn real_connect_rejects_every_rogue_server_proof_before_request_bytes() {
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    let victim_request = request(
        "input.write",
        Some("10000000-0000-4000-8000-000000000001"),
        json!({
            "pane_id": "40000000-0000-4000-8000-000000000000",
            "run_id": "50000000-0000-4000-8000-000000000000",
            "text": INPUT_MARKER
        }),
    );

    for kind in [
        RogueProof::KeySubstitution,
        RogueProof::SignatureMutation,
        RogueProof::ReplayNonce,
        RogueProof::InstanceMismatch,
        RogueProof::PipeNameMismatch,
        RogueProof::ClientPidMismatch,
        RogueProof::ServerPidMismatch,
        RogueProof::SameLogonRelay,
        RogueProof::WrongLength,
        RogueProof::WrongMagic,
    ] {
        let rogue = RogueServer::start(kind).unwrap_or_else(|error| panic!("{kind:?}: {error:?}"));
        let discovery: Value =
            serde_json::from_slice(rogue.discovery()).expect("rogue discovery JSON");
        let exit = PublicClient::start(&binary, home.path(), &discovery)
            .request_then_finish(&victim_request);
        assert_client_protocol_exit(exit);
        let evidence = rogue
            .finish()
            .unwrap_or_else(|error| panic!("{kind:?}: {error:?}"));
        assert_eq!(
            evidence.authentication_request_bytes, 44,
            "{kind:?}: {evidence:?}"
        );
        assert_eq!(
            evidence.request_bytes_after_proof, 0,
            "{kind:?}: {evidence:?}"
        );
    }
}

#[test]
fn real_conpty_host_supports_allow_revoke_deny_and_owner_lifetime() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    let fixtures = create_legacy_fixture(home.path());

    let mut host = InteractiveHost::start(&binary, home.path());
    let discovery = host.discovery();
    host.observe_console_input("host-eof");
    let discovery_object = discovery.as_object().expect("discovery object");
    assert_eq!(discovery_object.len(), 3, "{discovery}");
    assert!(discovery_object.contains_key("instance_id"));
    assert!(discovery_object.contains_key("pipe_name"));
    assert_eq!(discovery["schema_version"], json!(1));
    let instance = discovery["instance_id"]
        .as_str()
        .expect("instance ID")
        .to_owned();
    assert!(!discovery.to_string().contains(ENV_MARKER));
    let retained_mutex_handle = open_host_mutex_handle().expect("retain host mutex handle");

    let second_host = InteractiveHost::start(&binary, home.path()).wait_for_exit();
    assert_eq!(
        second_host.code,
        1,
        "{}",
        String::from_utf8_lossy(&second_host.output)
    );
    let second_output = String::from_utf8_lossy(&second_host.output);
    assert!(second_output.contains("winsmux workspace: "));
    assert!(second_output.contains("transport_failed"));
    assert!(!second_output.contains(ENV_MARKER));
    assert!(extract_all_json(&second_host.output).is_empty());

    let mut invalid_client = InteractiveHost::start_client(&binary, home.path(), &discovery);
    assert_success(
        &invalid_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    invalid_client.observe_console_input("connect-protocol-failure");
    invalid_client.write_raw(
        format!(
            "{{\"schema_version\":1,\"instance_id\":null,\"operation_id\":\"20000000-0000-4000-8000-000000000000\",\"expected_topology_revision\":null,\"operation\":\"capabilities.get\",\"params\":{{}},\"actor\":\"{INPUT_MARKER}\"}}"
        )
        .as_bytes(),
    );
    let invalid = invalid_client.wait_for_exit();
    assert_eq!(invalid.code, 1);
    let invalid_output = String::from_utf8_lossy(&invalid.output);
    assert!(invalid_output.contains("winsmux workspace: protocol_failed"));
    assert!(!invalid_output.contains(INPUT_MARKER));

    let mut client = PublicClient::start(&binary, home.path(), &discovery);
    let initial = client.transact(&request("capabilities.get", None, json!({})));
    assert_success(&initial, "capabilities.get");

    let pending = client.transact(&request(
        "connection.request",
        None,
        json!({"project_ids": [], "scopes": ["metadata", "control"]}),
    ));
    let pending = assert_success(&pending, "connection.request");
    let connection_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("connection ID")
        .to_owned();
    let listed = host.transact(&request("connection.list", Some(&instance), json!({})));
    let listed = assert_success(&listed, "connection.list");
    let connections = listed["result"]["data"]["connections"]
        .as_array()
        .expect("connections");
    assert_eq!(connections.len(), 1, "{listed}");
    assert_eq!(connections[0]["connection_id"], connection_id);
    assert_eq!(connections[0]["executable_name"], json!("winsmux.exe"));

    let non_owner = client.transact(&request("connection.list", Some(&instance), json!({})));
    assert_error(&non_owner, "permission_denied");
    let allowed = host.transact(&request(
        "connection.decide",
        Some(&instance),
        json!({
            "connection_id": connection_id,
            "decision": "allow",
            "project_ids": [],
            "scopes": ["metadata"]
        }),
    ));
    assert_success(&allowed, "connection.decide");
    let rich = client.transact(&request("capabilities.get", None, json!({})));
    let rich = assert_success(&rich, "capabilities.get");
    let providers = rich["result"]["data"]["providers"]
        .as_array()
        .expect("authorized provider list");
    for row in providers {
        assert!(
            row["provider"] == json!("codex") || row["provider"] == json!("claude"),
            "{rich}"
        );
        assert!(row["version"].as_str().is_some_and(|version| !version.is_empty()));
    }
    let operations = rich["result"]["data"]["operations"]
        .as_array()
        .expect("authorized operation list");
    assert_eq!(
        operations.contains(&json!("agent.launch")),
        !providers.is_empty(),
        "{rich}"
    );
    let service = client.transact(&request("project.list", Some(&instance), json!({})));
    let service = assert_success(&service, "project.list");
    assert_eq!(service["result"]["data"]["projects"], json!([]));
    assert_eq!(
        service["result"]["data"]["selected_project_id"],
        Value::Null
    );
    let revoked = host.transact(&request(
        "connection.revoke",
        Some(&instance),
        json!({"connection_id": connection_id}),
    ));
    assert_success(&revoked, "connection.revoke");
    assert_client_transport_exit(client.request_then_finish(&request(
        "capabilities.get",
        None,
        json!({}),
    )));

    let mut denied_client = PublicClient::start(&binary, home.path(), &discovery);
    let pending = denied_client.transact(&request(
        "connection.request",
        None,
        json!({"project_ids": [], "scopes": ["metadata"]}),
    ));
    let pending = assert_success(&pending, "connection.request");
    let denied_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("deny connection ID")
        .to_owned();
    let denied = host.transact(&request(
        "connection.decide",
        Some(&instance),
        json!({
            "connection_id": denied_id,
            "decision": "deny",
            "project_ids": [],
            "scopes": []
        }),
    ));
    assert_success(&denied, "connection.decide");
    assert_client_transport_exit(denied_client.request_then_finish(&request(
        "capabilities.get",
        None,
        json!({}),
    )));

    let discovery_bytes = serde_json::to_vec(&discovery).expect("discovery bytes");
    let slow_request = canonical_request(&request("capabilities.get", None, json!({})))
        .expect("slow request bytes");
    let slow_clients = [
        SlowStage::AuthenticationHeader,
        SlowStage::AuthenticationBody,
        SlowStage::ProofReader,
        SlowStage::RequestHeader,
        SlowStage::RequestBody,
        SlowStage::ResponseReader,
    ]
    .into_iter()
    .map(|stage| {
        SlowPublicClient::hold(&discovery_bytes, stage, &slow_request)
            .unwrap_or_else(|error| panic!("{stage:?}: {error:?}"))
    })
    .collect::<Vec<_>>();

    let mut parallel_client = PublicClient::start(&binary, home.path(), &discovery);
    assert_success(
        &parallel_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    let parallel_pending = assert_success(
        &parallel_client.transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [], "scopes": ["metadata"]}),
        )),
        "connection.request",
    );
    let parallel_id = parallel_pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("parallel connection ID")
        .to_owned();
    let parallel_list = assert_success(
        &host.transact(&request("connection.list", Some(&instance), json!({}))),
        "connection.list",
    );
    assert!(
        parallel_list["result"]["data"]["connections"]
            .as_array()
            .expect("parallel connections")
            .iter()
            .any(|connection| connection["connection_id"] == parallel_id),
        "{parallel_list}"
    );
    assert_success(
        &host.transact(&request(
            "connection.decide",
            Some(&instance),
            json!({
                "connection_id": parallel_id,
                "decision": "allow",
                "project_ids": [],
                "scopes": ["metadata"]
            }),
        )),
        "connection.decide",
    );
    assert_success(
        &parallel_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    assert_success(
        &host.transact(&request(
            "connection.revoke",
            Some(&instance),
            json!({"connection_id": parallel_id}),
        )),
        "connection.revoke",
    );
    assert_client_transport_exit(parallel_client.request_then_finish(&request(
        "capabilities.get",
        None,
        json!({}),
    )));

    let mut lifetime_client = PublicClient::start(&binary, home.path(), &discovery);
    let pending = lifetime_client.transact(&request(
        "connection.request",
        None,
        json!({"project_ids": [], "scopes": ["metadata"]}),
    ));
    let pending = assert_success(&pending, "connection.request");
    let lifetime_id = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("lifetime connection ID")
        .to_owned();
    assert_success(
        &host.transact(&request(
            "connection.decide",
            Some(&instance),
            json!({
                "connection_id": lifetime_id,
                "decision": "allow",
                "project_ids": [],
                "scopes": ["metadata"]
            }),
        )),
        "connection.decide",
    );

    let mut transport_client = InteractiveHost::start_client(&binary, home.path(), &discovery);
    assert_success(
        &transport_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    transport_client.observe_console_input("connect-transport-failure");

    let stopped = stop_after_provider_cleanup(&mut host, &instance);
    let stopped = assert_success(&stopped, "host.stop");
    assert_eq!(stopped["result"]["data"]["stopped"], json!(true));
    let host_exit = host.wait_for_exit();
    assert_eq!(
        host_exit.code,
        0,
        "{}",
        String::from_utf8_lossy(&host_exit.output)
    );
    let host_output = String::from_utf8_lossy(&host_exit.output);
    assert!(!host_output.contains(ENV_MARKER));
    assert!(!host_output.contains("expected_topology_revision"));

    let mut restarted = InteractiveHost::start(&binary, home.path());
    let restarted_discovery = restarted.discovery();
    assert_ne!(restarted_discovery["instance_id"], json!(instance));
    assert_ne!(restarted_discovery["pipe_name"], discovery["pipe_name"]);
    restarted.observe_console_input("host-ctrl-c");
    drop(slow_clients);
    drop(retained_mutex_handle);

    assert_client_transport_exit(lifetime_client.request_then_finish(&request(
        "capabilities.get",
        None,
        json!({}),
    )));
    let transport_exit =
        transport_client.request_then_exit(&request("capabilities.get", None, json!({})));
    assert_eq!(
        transport_exit.code,
        1,
        "{}",
        String::from_utf8_lossy(&transport_exit.output)
    );
    assert!(String::from_utf8_lossy(&transport_exit.output)
        .contains("winsmux workspace: transport_failed"));

    let mut eof_client = InteractiveHost::start_client(&binary, home.path(), &restarted_discovery);
    assert_success(
        &eof_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    eof_client.observe_console_input("connect-eof");
    let eof_client_exit = eof_client.console_eof();
    assert_eq!(
        eof_client_exit.code,
        0,
        "{}",
        String::from_utf8_lossy(&eof_client_exit.output)
    );

    let mut interactive_client =
        InteractiveHost::start_client(&binary, home.path(), &restarted_discovery);
    assert_success(
        &interactive_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    interactive_client.observe_console_input("connect-ctrl-c");
    let interrupted_client = interactive_client.ctrl_c();
    assert_eq!(
        interrupted_client.code,
        130,
        "{}",
        String::from_utf8_lossy(&interrupted_client.output)
    );
    assert!(String::from_utf8_lossy(&interrupted_client.output).contains("cancelled"));
    assert_success(
        &restarted.transact(&request(
            "connection.list",
            restarted_discovery["instance_id"].as_str(),
            json!({}),
        )),
        "connection.list",
    );

    let ctrl_mutex_handle = open_host_mutex_handle().expect("retain mutex across owner Ctrl+C");
    let restarted_exit = restarted.ctrl_c_byte();
    assert_eq!(
        restarted_exit.code,
        130,
        "{}",
        String::from_utf8_lossy(&restarted_exit.output)
    );
    assert!(String::from_utf8_lossy(&restarted_exit.output).contains("cancelled"));

    wait_for_host_mutex_release();
    let mut orphaned = InteractiveHost::start(&binary, home.path());
    let orphaned_discovery = orphaned.discovery();
    drop(ctrl_mutex_handle);
    let orphaned_instance = orphaned_discovery["instance_id"]
        .as_str()
        .expect("orphaned host instance")
        .to_owned();
    let mut orphaned_client = PublicClient::start(&binary, home.path(), &orphaned_discovery);
    let pending = assert_success(
        &orphaned_client.transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [], "scopes": ["metadata"]}),
        )),
        "connection.request",
    );
    let orphaned_connection = pending["result"]["data"]["connection_id"]
        .as_str()
        .expect("orphaned connection ID")
        .to_owned();
    assert_success(
        &orphaned.transact(&request(
            "connection.decide",
            Some(&orphaned_instance),
            json!({
                "connection_id": orphaned_connection,
                "decision": "allow",
                "project_ids": [],
                "scopes": ["metadata"]
            }),
        )),
        "connection.decide",
    );
    let kill_mutex_handle = open_host_mutex_handle().expect("retain mutex across owner kill");
    let terminated_owner = orphaned.terminate_owner();
    assert_eq!(terminated_owner.code, 1);
    wait_for_host_mutex_release();
    assert_client_transport_exit(orphaned_client.request_then_finish(&request(
        "capabilities.get",
        None,
        json!({}),
    )));

    let stale_discovery = serde_json::to_vec(&orphaned_discovery).expect("stale discovery bytes");
    let stale_rogue =
        RogueServer::start_for_stale_discovery(&stale_discovery).expect("stale-name rogue");
    let stale_exit =
        PublicClient::start(&binary, home.path(), &orphaned_discovery).request_then_finish(
            &request("project.list", Some(&orphaned_instance), json!({})),
        );
    assert_client_protocol_exit(stale_exit);
    let stale_evidence = stale_rogue.finish().expect("stale-name rogue evidence");
    assert_eq!(stale_evidence.authentication_request_bytes, 44);
    assert_eq!(stale_evidence.request_bytes_after_proof, 0);

    let mut final_host = InteractiveHost::start(&binary, home.path());
    let final_discovery = final_host.discovery();
    drop(kill_mutex_handle);
    assert_ne!(final_discovery["instance_id"], json!(orphaned_instance));
    assert_ne!(
        final_discovery["pipe_name"],
        orphaned_discovery["pipe_name"]
    );
    let mut fresh_client = PublicClient::start(&binary, home.path(), &final_discovery);
    assert_success(
        &fresh_client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    let fresh_exit = fresh_client.finish();
    assert_eq!(
        fresh_exit.code,
        0,
        "{}",
        String::from_utf8_lossy(&fresh_exit.stderr)
    );
    assert!(fresh_exit.stderr.is_empty());
    final_host.observe_console_input("host-final-eof");
    assert_eq!(final_host.console_eof().code, 0);

    let abandoned_mutex_handle = abandon_host_mutex();
    let mut abandoned_restart = InteractiveHost::start(&binary, home.path());
    let abandoned_discovery = abandoned_restart.discovery();
    assert_ne!(
        abandoned_discovery["instance_id"],
        orphaned_discovery["instance_id"]
    );
    drop(abandoned_mutex_handle);
    assert_eq!(abandoned_restart.console_eof().code, 0);
    println!("TASK862_MUTEX_PROOF abandoned ownership recovered with retained handle");
    assert_fixture_unchanged(&fixtures);
}

#[test]
fn workspace_cli_rejects_nonterminal_owner_invalid_child_and_legacy_target_prefix() {
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    let fixtures = create_legacy_fixture(home.path());

    let nonterminal = fixed_environment(&binary, home.path())
        .args(["workspace", "host"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run nonterminal host");
    assert_fixed_failure(nonterminal, 2, "interactive_required");

    let invalid_child = fixed_environment(&binary, home.path())
        .args(["workspace", "__host-child", ARG_MARKER])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run invalid child mode");
    assert_fixed_failure(invalid_child, 1, "startup_failed");

    let legacy_target = fixed_environment(&binary, home.path())
        .args(["-t", ARG_MARKER, "workspace", "host"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run legacy target prefix");
    assert_fixed_failure(legacy_target, 2, "usage");
    assert_fixture_unchanged(&fixtures);
}

#[test]
fn real_conpty_owner_project_journey() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    let fixtures = create_legacy_fixture(home.path());
    let folder = home.path().join("プロジェクト");
    std::fs::create_dir_all(&folder).expect("japanese folder");
    std::fs::write(folder.join("marker.txt"), b"folder-bytes").expect("marker");
    let path = folder.to_string_lossy().into_owned();

    let mut host = InteractiveHost::start(&binary, home.path());
    let discovery = host.discovery();
    let instance = discovery["instance_id"]
        .as_str()
        .expect("instance")
        .to_owned();

    let empty = assert_success(
        &host.transact(&request("project.list", Some(&instance), json!({}))),
        "project.list",
    );
    assert_eq!(empty["result"]["data"]["projects"], json!([]));

    let opened = assert_success(
        &host.transact(&request_rev(
            "project.open",
            Some(&instance),
            Some(0),
            json!({"path": path}),
        )),
        "project.open",
    );
    assert_eq!(opened["result"]["data"]["created"], json!(true));
    let project = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("id")
        .to_owned();
    let revision = opened["topology_revision"].as_u64().expect("rev");

    let listed = assert_success(
        &host.transact(&request("project.list", Some(&instance), json!({}))),
        "project.list",
    );
    assert_eq!(
        listed["result"]["data"]["projects"][0]["project_id"],
        json!(project)
    );
    assert_eq!(
        listed["result"]["data"]["projects"][0]["display_name"],
        json!("プロジェクト")
    );

    let selected = assert_success(
        &host.transact(&request_rev(
            "project.select",
            Some(&instance),
            Some(revision),
            json!({"project_id": project}),
        )),
        "project.select",
    );
    assert_eq!(
        selected["result"]["data"]["selected_project_id"],
        json!(project)
    );
    let revision = selected["topology_revision"].as_u64().expect("rev");

    let forgotten = assert_success(
        &host.transact(&request_rev(
            "project.forget",
            Some(&instance),
            Some(revision),
            json!({"project_id": project}),
        )),
        "project.forget",
    );
    assert_eq!(forgotten["result"]["data"]["removed"], json!(true));
    assert_eq!(
        std::fs::read(folder.join("marker.txt")).expect("disk"),
        b"folder-bytes"
    );
    let after = assert_success(
        &host.transact(&request("project.list", Some(&instance), json!({}))),
        "project.list",
    );
    assert_eq!(after["result"]["data"]["projects"], json!([]));

    host.observe_console_input("host-project-eof");
    assert_eq!(host.console_eof().code, 0);
    assert_fixture_unchanged(&fixtures);
}

#[test]
fn real_conpty_save_stop_new_host_restore_keeps_layout_without_runs() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("temporary isolated home");
    let project_folder = home.path().join("saved-project");
    std::fs::create_dir_all(&project_folder).expect("project folder");
    let project_path = project_folder.to_string_lossy().into_owned();
    let store = home.path().join("AppData/Local/winsmux/workspace/v1");
    let confirmed = store.join("confirmed.json");
    let backup = store.join("backup.json");
    assert!(!confirmed.exists(), "isolated C must start absent");
    assert!(!backup.exists(), "isolated B must start absent");

    let mut first = InteractiveHost::start(&binary, home.path());
    let first_discovery = first.discovery();
    let first_instance = first_discovery["instance_id"]
        .as_str()
        .expect("first instance");
    let opened = assert_success(
        &first.transact(&request_rev(
            "project.open",
            Some(first_instance),
            Some(0),
            json!({"path": project_path}),
        )),
        "project.open",
    );
    let project_id = opened["result"]["data"]["project_id"]
        .as_str()
        .expect("project ID")
        .to_owned();
    let created = assert_success(
        &first.transact(&request_rev(
            "pane.create",
            Some(first_instance),
            opened["topology_revision"].as_u64(),
            json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
        )),
        "pane.create",
    );
    let pane_id = created["result"]["data"]["pane_id"]
        .as_str()
        .expect("pane ID")
        .to_owned();
    let run_id = created["result"]["data"]["run_id"]
        .as_str()
        .expect("run ID")
        .to_owned();
    let selected = assert_success(
        &first.transact(&request_rev(
            "pane.select",
            Some(first_instance),
            created["topology_revision"].as_u64(),
            json!({"pane_id": pane_id}),
        )),
        "pane.select",
    );
    assert_eq!(
        selected["result"]["data"]["selected_project_id"],
        json!(project_id)
    );
    assert_eq!(
        selected["result"]["data"]["selected_pane_id"],
        json!(pane_id)
    );
    let saved = assert_success(
        &first.transact(&request("layout.save", Some(first_instance), json!({}))),
        "layout.save",
    );
    assert_eq!(saved["instance_id"], json!(first_instance));
    let first_c = std::fs::read(&confirmed).expect("confirmed C after save");
    assert!(!backup.exists(), "first save must not invent B");
    assert!(!first_c
        .windows(run_id.len())
        .any(|part| part == run_id.as_bytes()));

    let interrupted = assert_success(
        &first.transact(&request(
            "run.interrupt",
            Some(first_instance),
            json!({"run_id": run_id}),
        )),
        "run.interrupt",
    );
    assert_eq!(interrupted["result"]["data"]["phase"], json!("accepted"));
    let run_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let run = assert_success(
            &first.transact(&request(
                "run.get",
                Some(first_instance),
                json!({"run_id": run_id}),
            )),
            "run.get",
        );
        if run["result"]["data"]["run"]["process"] == json!("exited") {
            break;
        }
        assert!(
            std::time::Instant::now() < run_deadline,
            "target run did not exit after interrupt: {run}"
        );
        std::thread::yield_now();
    }
    let stopped = assert_success(
        &stop_after_provider_cleanup(&mut first, first_instance),
        "host.stop",
    );
    assert_eq!(stopped["result"]["data"]["stopped"], json!(true));
    let first_exit = first.wait_for_exit();
    assert_eq!(
        first_exit.code,
        0,
        "{}",
        String::from_utf8_lossy(&first_exit.output)
    );
    assert_eq!(std::fs::read(&backup).expect("B after stop"), first_c);
    let stop_c = std::fs::read(&confirmed).expect("C after stop");
    assert!(!stop_c
        .windows(run_id.len())
        .any(|part| part == run_id.as_bytes()));

    let mut second = InteractiveHost::start(&binary, home.path());
    let second_discovery = second.discovery();
    let second_instance = second_discovery["instance_id"]
        .as_str()
        .expect("second instance");
    assert_ne!(first_instance, second_instance);
    let empty = assert_success(
        &second.transact(&request("project.list", Some(second_instance), json!({}))),
        "project.list",
    );
    assert_eq!(empty["result"]["data"]["projects"], json!([]));
    let restored = assert_success(
        &second.transact(&request_rev(
            "layout.restore",
            Some(second_instance),
            Some(empty["topology_revision"].as_u64().expect("new revision")),
            json!({}),
        )),
        "layout.restore",
    );
    assert_eq!(restored["result"]["data"]["restored"], json!(true));
    let projects = assert_success(
        &second.transact(&request("project.list", Some(second_instance), json!({}))),
        "project.list",
    );
    assert_eq!(
        projects["result"]["data"]["selected_project_id"],
        json!(project_id)
    );
    let panes = assert_success(
        &second.transact(&request(
            "pane.list",
            Some(second_instance),
            json!({"project_id": project_id}),
        )),
        "pane.list",
    );
    assert_eq!(panes["result"]["data"]["selected_pane_id"], json!(pane_id));
    assert_eq!(
        panes["result"]["data"]["panes"]
            .as_array()
            .expect("panes")
            .len(),
        1
    );
    assert_eq!(
        panes["result"]["data"]["panes"][0]["current_run_id"],
        json!(null)
    );
    assert_error(
        &second.transact(&request(
            "run.get",
            Some(second_instance),
            json!({"run_id": run_id}),
        )),
        "target_not_found",
    );
    assert_eq!(std::fs::read(&confirmed).expect("restore leaves C"), stop_c);
    assert_eq!(std::fs::read(&backup).expect("restore leaves B"), first_c);
    let second_stop = assert_success(
        &stop_after_provider_cleanup(&mut second, second_instance),
        "host.stop",
    );
    assert_eq!(second_stop["result"]["data"]["stopped"], json!(true));
    assert_eq!(second.wait_for_exit().code, 0);
}

#[test]
#[ignore = "requires installed official Codex and Claude CLIs"]
fn real_conpty_provider_launch_status_interrupt_and_replay() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let isolation_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root")
        .join(".evidence")
        .join("provider-e2e-homes");
    std::fs::create_dir_all(&isolation_root).expect("isolated home parent");
    let home = tempfile::Builder::new()
        .prefix("winsmux-provider-")
        .tempdir_in(&isolation_root)
        .expect("isolated non-TEMP home");
    let project_path = home.path().join("provider-project");
    std::fs::create_dir_all(&project_path).expect("project directory");
    let codex_home = home.path().join("codex-home");
    let claude_home = home.path().join("claude-home");
    std::fs::create_dir_all(&codex_home).expect("isolated Codex config");
    std::fs::create_dir_all(&claude_home).expect("isolated Claude config");
    let mut host = InteractiveHost::start_with_environment(
        &binary,
        home.path(),
        &["workspace", "host"],
        &[
            ("WINSMUX_TASK868_OBSERVE_SPAWNS", "1"),
            ("CODEX_HOME", codex_home.to_str().expect("Codex config path")),
            ("CLAUDE_CONFIG_DIR", claude_home.to_str().expect("Claude config path")),
            ("OPENAI_API_KEY", ""),
            ("ANTHROPIC_API_KEY", ""),
            ("CLAUDE_CODE_OAUTH_TOKEN", ""),
        ],
    );
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().expect("instance ID");

    let ready_deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        let capabilities = assert_success(
            &host.transact(&request("capabilities.get", Some(instance), json!({}))),
            "capabilities.get",
        );
        let providers = capabilities["result"]["data"]["providers"]
            .as_array()
            .expect("provider list");
        if ["codex", "claude"].iter().all(|name| {
            providers.iter().any(|row| row["provider"] == json!(name))
        }) {
            assert!(capabilities["result"]["data"]["operations"]
                .as_array()
                .expect("operations")
                .contains(&json!("agent.launch")));
            break;
        }
        assert!(
            std::time::Instant::now() < ready_deadline,
            "installed provider versions were not verified: {capabilities}"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    let opened = assert_success(
        &host.transact(&request_rev(
            "project.open",
            Some(instance),
            Some(0),
            json!({"path": project_path.to_string_lossy()}),
        )),
        "project.open",
    );
    let project_id = opened["result"]["data"]["project_id"].clone();
    let created = assert_success(
        &host.transact(&request_rev(
            "pane.create",
            Some(instance),
            opened["topology_revision"].as_u64(),
            json!({"project_id": project_id, "shell_profile_id": "pwsh"}),
        )),
        "pane.create",
    );
    let pane_id = created["result"]["data"]["pane_id"].clone();
    let initial_run = created["result"]["data"]["run_id"].clone();
    let mut client = PublicClient::start(&binary, home.path(), &discovery);
    let ungranted_launch = value(&client.transact(&request(
        "agent.launch",
        Some(instance),
        json!({"pane_id": pane_id, "provider": "codex", "model": null, "effort": null}),
    )));
    assert_eq!(ungranted_launch["accepted"], json!(false), "{ungranted_launch}");
    let pending = assert_success(
        &client.transact(&request(
            "connection.request",
            None,
            json!({"project_ids": [project_id], "scopes": ["metadata", "control"]}),
        )),
        "connection.request",
    );
    let connection_id = pending["result"]["data"]["connection_id"].clone();
    assert_success(
        &host.transact(&request(
            "connection.decide",
            Some(instance),
            json!({
                "connection_id": connection_id,
                "decision": "allow",
                "project_ids": [project_id],
                "scopes": ["metadata", "control"]
            }),
        )),
        "connection.decide",
    );
    let client_capabilities = assert_success(
        &client.transact(&request("capabilities.get", None, json!({}))),
        "capabilities.get",
    );
    for provider in ["codex", "claude"] {
        let row = client_capabilities["result"]["data"]["providers"]
            .as_array()
            .expect("client providers")
            .iter()
            .find(|row| row["provider"] == json!(provider))
            .unwrap_or_else(|| panic!("client missing {provider}: {client_capabilities}"));
        assert!(row["version"].as_str().is_some_and(|version| !version.is_empty()));
    }
    let interrupted = assert_success(
        &host.transact(&request("run.interrupt", Some(instance), json!({"run_id": initial_run}))),
        "run.interrupt",
    );
    assert_eq!(interrupted["result"]["data"]["phase"], json!("accepted"));

    let mut previous = initial_run;
    let mut previous_interrupted = true;
    for provider in ["codex", "claude"] {
        let exit_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let status = assert_success(
                &host.transact(&request("run.get", Some(instance), json!({"run_id": previous}))),
                "run.get",
            );
            if status["result"]["data"]["run"]["process"] == json!("exited") {
                assert_eq!(status["result"]["data"]["run"]["evidence"], json!("process_exit"));
                if previous_interrupted {
                    assert_eq!(status["result"]["data"]["run"]["work"], json!("interrupted"));
                }
                break;
            }
            assert!(std::time::Instant::now() < exit_deadline, "previous run did not exit: {status}");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }

        let launch_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let (launch_request, launched) = loop {
            let launch_request = request(
                "agent.launch",
                Some(instance),
                json!({"pane_id": pane_id, "provider": provider, "model": null, "effort": null}),
            );
            let response = value(&client.transact(&launch_request));
            if response["accepted"] == json!(true) {
                break (launch_request, response);
            }
            assert_eq!(response["error"]["code"], json!("already_running"), "{response}");
            assert!(std::time::Instant::now() < launch_deadline, "run cleanup did not finish");
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(launched["result"]["data"]["phase"], json!("accepted"));
        let replay = assert_success(&client.transact(&launch_request), "agent.launch");
        assert_eq!(replay["result"]["data"], launched["result"]["data"]);
        let run_id = launched["result"]["data"]["run_id"].clone();
        let status = assert_success(
            &client.transact(&request("run.get", Some(instance), json!({"run_id": run_id}))),
            "run.get",
        );
        assert_eq!(status["result"]["data"]["run"]["pane_id"], pane_id);
        if status["result"]["data"]["run"]["process"] == json!("running") {
            assert_eq!(status["result"]["data"]["run"]["work"], json!("unknown"));
            assert_eq!(status["result"]["data"]["run"]["evidence"], json!("unavailable"));
        }
        let stop = client.transact(&request("run.interrupt", Some(instance), json!({"run_id": run_id})));
        let stop = value(&stop);
        assert!(
            stop["accepted"] == json!(true) || stop["error"]["code"] == json!("not_running"),
            "{stop}"
        );
        previous_interrupted = stop["accepted"] == json!(true);
        previous = run_id;
    }
    let last_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let status = assert_success(
            &client.transact(&request("run.get", Some(instance), json!({"run_id": previous}))),
            "run.get",
        );
        if status["result"]["data"]["run"]["process"] == json!("exited") {
            assert_eq!(status["result"]["data"]["run"]["evidence"], json!("process_exit"));
            if previous_interrupted {
                assert_eq!(status["result"]["data"]["run"]["work"], json!("interrupted"));
            }
            break;
        }
        assert!(std::time::Instant::now() < last_deadline, "last run did not exit: {status}");
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let invalid_model = "winsmux-invalid-model-for-e2e";
    for provider in ["codex", "claude"] {
        let launch_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let launched = loop {
            let response = value(&client.transact(&request(
                "agent.launch",
                Some(instance),
                json!({"pane_id": pane_id, "provider": provider, "model": invalid_model, "effort": null}),
            )));
            if response["accepted"] == json!(true) {
                break response;
            }
            assert_eq!(response["error"]["code"], json!("already_running"), "{response}");
            assert!(std::time::Instant::now() < launch_deadline, "pane cleanup did not finish");
            std::thread::sleep(std::time::Duration::from_millis(100));
        };
        let run_id = launched["result"]["data"]["run_id"].clone();
        let status = assert_success(
            &client.transact(&request("run.get", Some(instance), json!({"run_id": run_id}))),
            "run.get",
        );
        let run = &status["result"]["data"]["run"];
        assert_ne!(run["work"], json!("succeeded"), "{status}");
        if run["process"] == json!("running") {
            assert_eq!(run["work"], json!("unknown"), "{status}");
            assert_eq!(run["evidence"], json!("unavailable"), "{status}");
            let interrupted = assert_success(
                &client.transact(&request("run.interrupt", Some(instance), json!({"run_id": run_id}))),
                "run.interrupt",
            );
            assert_eq!(interrupted["result"]["data"]["phase"], json!("accepted"));
        }
        let exit_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let status = assert_success(
                &client.transact(&request("run.get", Some(instance), json!({"run_id": run_id}))),
                "run.get",
            );
            if status["result"]["data"]["run"]["process"] == json!("exited") {
                assert_eq!(status["result"]["data"]["run"]["evidence"], json!("process_exit"));
                break;
            }
            assert!(std::time::Instant::now() < exit_deadline, "model run did not stop: {status}");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    // A value spelling a real CLI option must remain model/effort data.
    let option_shaped_model = "--help";
    let option_shaped_effort = "--version";
    for provider in ["codex", "claude"] {
        let launch_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let launched = loop {
            let response = value(&client.transact(&request(
                "agent.launch",
                Some(instance),
                json!({"pane_id": pane_id, "provider": provider, "model": option_shaped_model, "effort": option_shaped_effort}),
            )));
            if response["accepted"] == json!(true) {
                break response;
            }
            assert_eq!(response["error"]["code"], json!("already_running"), "{response}");
            assert!(std::time::Instant::now() < launch_deadline, "pane cleanup did not finish");
            std::thread::sleep(std::time::Duration::from_millis(100));
        };
        let run_id = launched["result"]["data"]["run_id"].clone();
        let status = assert_success(
            &client.transact(&request("run.get", Some(instance), json!({"run_id": run_id}))),
            "run.get",
        );
        let run = &status["result"]["data"]["run"];
        let requested_interrupt = run["process"] == json!("running");
        if requested_interrupt {
            assert_eq!(run["work"], json!("unknown"), "{status}");
            assert_eq!(run["evidence"], json!("unavailable"), "{status}");
            let interrupted = assert_success(
                &client.transact(&request("run.interrupt", Some(instance), json!({"run_id": run_id}))),
                "run.interrupt",
            );
            assert_eq!(interrupted["result"]["data"]["phase"], json!("accepted"));
        }
        let exit_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let status = assert_success(
                &client.transact(&request("run.get", Some(instance), json!({"run_id": run_id}))),
                "run.get",
            );
            let run = &status["result"]["data"]["run"];
            if run["process"] == json!("exited") {
                assert_eq!(run["evidence"], json!("process_exit"), "{status}");
                if requested_interrupt {
                    assert_eq!(run["work"], json!("interrupted"), "{status}");
                } else {
                    assert_eq!(run["work"], json!("failed"), "{status}");
                    assert!(run["exit_code"].as_u64().is_some_and(|code| code > 0), "{status}");
                }
                break;
            }
            assert_eq!(run["work"], json!("unknown"), "{status}");
            assert!(std::time::Instant::now() < exit_deadline, "option-shaped value run did not stop: {status}");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    let observations = std::fs::read_to_string(
        home.path().join(".winsmux-task868-spawn-observation.jsonl"),
    )
    .expect("actual CreateProcessW observations");
    let observations = observations
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).expect("spawn observation JSON"))
        .collect::<Vec<_>>();
    for provider in ["codex", "claude"] {
        assert!(
            observations.iter().any(|row| {
                row["executable"]
                    .as_str()
                    .is_some_and(|exe| exe.to_ascii_lowercase().ends_with(&format!("{provider}.exe")))
                    && row["current_directory"]
                        .as_str()
                        .is_some_and(|cwd| cwd.eq_ignore_ascii_case(&project_path.to_string_lossy()))
                    && row["pid"].as_u64().is_some_and(|pid| pid > 0)
            }),
            "{provider} was not created in the requested project cwd: {observations:?}"
        );
        let expected_model = format!("--model={invalid_model}");
        assert!(
            observations.iter().any(|row| {
                row["executable"]
                    .as_str()
                    .is_some_and(|exe| exe.to_ascii_lowercase().ends_with(&format!("{provider}.exe")))
                    && row["arguments"] == json!([expected_model])
            }),
            "{provider} did not receive the exact model value: {observations:?}"
        );
        let option_shaped_argv = if provider == "codex" {
            json!(["--model=--help", "-c", "model_reasoning_effort=--version"])
        } else {
            json!(["--model=--help", "--effort=--version"])
        };
        assert!(
            observations.iter().any(|row| {
                row["executable"]
                    .as_str()
                    .is_some_and(|exe| exe.to_ascii_lowercase().ends_with(&format!("{provider}.exe")))
                    && row["arguments"] == option_shaped_argv
            }),
            "{provider} did not receive option-shaped values as bound data: {observations:?}"
        );
    }
    assert_success(
        &host.transact(&request(
            "connection.revoke",
            Some(instance),
            json!({"connection_id": connection_id}),
        )),
        "connection.revoke",
    );
    assert_client_transport_exit(client.request_then_finish(&request(
        "run.get",
        Some(instance),
        json!({"run_id": previous}),
    )));
    assert_eq!(host.console_eof().code, 0);
}

#[test]
fn real_host_without_provider_path_keeps_launch_unadvertised() {
    let _host_test = HOST_TEST_LOCK.lock().expect("host test lock");
    let binary = binary();
    let home = tempfile::tempdir().expect("isolated host home");
    let system_root = std::env::var("SystemRoot").expect("Windows root");
    let system_path = format!(r"{system_root}\System32");
    let mut host = InteractiveHost::start_with_environment(
        &binary,
        home.path(),
        &["workspace", "host"],
        &[("PATH", &system_path)],
    );
    let discovery = host.discovery();
    let instance = discovery["instance_id"].as_str().expect("instance ID");
    let capabilities = assert_success(
        &host.transact(&request("capabilities.get", Some(instance), json!({}))),
        "capabilities.get",
    );
    assert_eq!(capabilities["result"]["data"]["providers"], json!([]));
    assert!(!capabilities["result"]["data"]["operations"]
        .as_array()
        .expect("operations")
        .contains(&json!("agent.launch")));
    let stopped = stop_after_provider_cleanup(&mut host, instance);
    assert_success(&stopped, "host.stop");
    assert_eq!(host.wait_for_exit().code, 0);
}
