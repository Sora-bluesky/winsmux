//! ConPTY / job / CREATE_SUSPENDED spawn. PTY children inherit no host handles.

use std::ffi::c_void;
#[cfg(debug_assertions)]
use std::io::Write;
use std::mem::{size_of, ManuallyDrop};
use std::pin::Pin;
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex};
use windows_sys::Win32::Foundation::{
    CloseHandle, DuplicateHandle, GetLastError, SetHandleInformation, DUPLICATE_SAME_ACCESS,
    ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF, ERROR_IO_INCOMPLETE, ERROR_IO_PENDING,
    ERROR_OPERATION_ABORTED, GENERIC_READ, GENERIC_WRITE, HANDLE, HANDLE_FLAG_INHERIT,
    INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, SearchPathW, WriteFile, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND,
};
use windows_sys::Win32::System::Console::{ClosePseudoConsole, CreatePseudoConsole, COORD, HPCON};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicAccountingInformation,
    JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
    TerminateJobObject,
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::Pipes::{CreateNamedPipeW, PIPE_TYPE_BYTE, PIPE_WAIT};
use windows_sys::Win32::System::Threading::{
    CreateEventW, CreateProcessW, DeleteProcThreadAttributeList, GetCurrentProcess,
    GetExitCodeProcess, InitializeProcThreadAttributeList, ResumeThread, SuspendThread,
    TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject, CREATE_SUSPENDED,
    CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, INFINITE,
    LPPROC_THREAD_ATTRIBUTE_LIST, PROCESS_INFORMATION, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    STARTF_USESTDHANDLES, STARTUPINFOEXW,
};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

pub const STILL_ACTIVE: u32 = 259;
pub const INITIAL_COLS: i16 = 80;
pub const INITIAL_ROWS: i16 = 24;

pub struct RawHandle(pub HANDLE);
unsafe impl Send for RawHandle {}
unsafe impl Sync for RawHandle {}

impl Drop for RawHandle {
    fn drop(&mut self) {
        self.close();
    }
}

impl RawHandle {
    pub fn invalid() -> Self {
        Self(INVALID_HANDLE_VALUE)
    }

    pub fn is_valid(&self) -> bool {
        !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE
    }

    pub fn take(&mut self) -> HANDLE {
        let handle = self.0;
        self.0 = INVALID_HANDLE_VALUE;
        handle
    }

    pub fn close(&mut self) {
        if self.is_valid() {
            unsafe {
                CloseHandle(self.0);
            }
            self.0 = INVALID_HANDLE_VALUE;
        }
    }
}

pub struct PseudoConsole(pub HPCON);
unsafe impl Send for PseudoConsole {}
unsafe impl Sync for PseudoConsole {}

impl Drop for PseudoConsole {
    fn drop(&mut self) {
        self.close();
    }
}

impl PseudoConsole {
    pub fn close(&mut self) {
        if self.0 != 0 {
            unsafe {
                ClosePseudoConsole(self.0);
            }
            self.0 = 0;
        }
    }

    pub fn take(&mut self) -> HPCON {
        let handle = self.0;
        self.0 = 0;
        handle
    }
}

struct AttributeList {
    storage: Vec<usize>,
    hpcon: HPCON,
}

impl AttributeList {
    fn for_pseudoconsole(hpcon: HPCON) -> Result<Self, SpawnError> {
        let mut required = 0usize;
        unsafe {
            InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut required);
        }
        if required == 0 {
            return Err(SpawnError::Runtime);
        }
        let mut storage = vec![0usize; required.div_ceil(size_of::<usize>())];
        let list = storage.as_mut_ptr().cast::<c_void>();
        if unsafe { InitializeProcThreadAttributeList(list, 1, 0, &mut required) } == 0 {
            return Err(SpawnError::Runtime);
        }
        let mut attributes = Self { storage, hpcon };
        let list = attributes.storage.as_mut_ptr().cast::<c_void>();
        let updated = unsafe {
            UpdateProcThreadAttribute(
                list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                attributes.hpcon as *mut c_void,
                size_of::<HPCON>(),
                null_mut(),
                null(),
            )
        };
        if updated == 0 {
            unsafe {
                DeleteProcThreadAttributeList(list);
            }
            std::mem::forget(attributes);
            return Err(SpawnError::Runtime);
        }
        Ok(attributes)
    }

    fn raw(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_mut_ptr().cast::<c_void>()
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.raw());
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpawnError {
    Runtime,
    Exhausted,
}

pub struct PreparedChild {
    pub process: RawHandle,
    pub thread: RawHandle,
    pub job: RawHandle,
    pub hpcon: PseudoConsole,
    pub input: RawHandle,
    pub output: RawHandle,
    pub inherit_owner: bool,
    pub inherit_public: bool,
    pub b_inherit_handles: bool,
    kill_on_drop: bool,
    write: Option<PinnedWrite>,
}

impl PreparedChild {
    pub fn assign_to_job(&self) -> bool {
        unsafe { AssignProcessToJobObject(self.job.0, self.process.0) != 0 }
    }

    pub fn disarm(&mut self) {
        self.kill_on_drop = false;
    }

    pub fn write_ctrl_c(&mut self) -> bool {
        if let Some(op) = self.write.take() {
            return finish_issued_write(&mut self.write, op, false);
        }
        if !self.input.is_valid() {
            return false;
        }
        match issue_write_byte(self.input.0, 0x03) {
            IssueStart::Immediate { written } => written == 1,
            IssueStart::Pending(op) => finish_issued_write(&mut self.write, op, false),
            IssueStart::Failed(_) => false,
        }
    }

    pub fn take_write(&mut self) -> Option<PinnedWrite> {
        self.write.take()
    }

    pub fn wait_exit(&self) -> Option<u32> {
        if !self.process.is_valid() {
            return None;
        }
        unsafe {
            WaitForSingleObject(self.process.0, INFINITE);
        }
        exit_code(self.process.0)
    }

    pub fn rollback(mut self) -> bool {
        if let Some(op) = self.write.take() {
            retain_write(op);
        }
        let stopped = self.stop_unpublished_and_observe();
        if !stopped {
            self.kill_on_drop = false;
            recover_unobserved_child(self);
            return false;
        }
        self.thread.close();
        self.process.close();
        self.job.close();
        self.hpcon.close();
        self.input.close();
        self.output.close();
        self.kill_on_drop = false;
        stopped
    }

    fn stop_unpublished_and_observe(&mut self) -> bool {
        let job_terminated = self.job.is_valid()
            && unsafe { TerminateJobObject(self.job.0, 1) } != 0;
        if !job_terminated {
            self.kill_unpublished();
        }
        if self.process.is_valid()
            && unsafe { WaitForSingleObject(self.process.0, INFINITE) } != WAIT_OBJECT_0
        {
            return false;
        }
        if !self.job.is_valid() {
            return true;
        }
        loop {
            match job_active_processes(self.job.0) {
                Some(0) => return true,
                Some(_) if job_terminated => std::thread::yield_now(),
                Some(_) => return false,
                None => return false,
            }
        }
    }

    fn kill_unpublished(&mut self) {
        if self.process.is_valid() {
            unsafe {
                TerminateProcess(self.process.0, 1);
            }
        }
    }
}

impl Drop for PreparedChild {
    fn drop(&mut self) {
        if self.kill_on_drop {
            self.kill_unpublished();
        }
    }
}

fn dos_cwd(cwd: &str) -> String {
    match cwd.strip_prefix(r"\\?\") {
        Some(rest) => {
            if let Some(unc) = rest.strip_prefix("UNC\\") {
                format!(r"\\{unc}")
            } else {
                rest.to_owned()
            }
        }
        None => cwd.to_owned(),
    }
}

fn inheritable_attributes() -> SECURITY_ATTRIBUTES {
    SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    }
}

fn quote_argument(argument: &str) -> String {
    if argument.is_empty() {
        return "\"\"".to_owned();
    }
    if !argument
        .bytes()
        .any(|byte| matches!(byte, b' ' | b'\t' | b'\n' | b'\x0b' | b'"'))
    {
        return argument.to_owned();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for ch in argument.chars() {
        if ch == '\\' {
            backslashes += 1;
            continue;
        }
        if ch == '"' {
            quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
            quoted.push('"');
            backslashes = 0;
            continue;
        }
        quoted.push_str(&"\\".repeat(backslashes));
        quoted.push(ch);
        backslashes = 0;
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

pub fn search_pwsh() -> Result<String, SpawnError> {
    let name: Vec<u16> = "pwsh.exe"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut buffer = vec![0u16; 32_768];
    let written = unsafe {
        SearchPathW(
            null(),
            name.as_ptr(),
            null(),
            buffer.len() as u32,
            buffer.as_mut_ptr(),
            null_mut(),
        )
    };
    if written == 0 || written as usize >= buffer.len() {
        return Err(SpawnError::Runtime);
    }
    Ok(String::from_utf16_lossy(&buffer[..written as usize]))
}

pub fn spawn_suspended_shell(cwd: &str, executable: &str) -> Result<PreparedChild, SpawnError> {
    spawn_suspended(cwd, executable, &["-NoLogo"])
}

#[cfg(debug_assertions)]
fn trace_spawn_for_real_cli_test(
    executable: &str,
    current_directory: &str,
    arguments: &[&str],
    pid: u32,
) {
    if std::env::var_os("WINSMUX_TASK868_OBSERVE_SPAWNS").as_deref()
        != Some(std::ffi::OsStr::new("1"))
    {
        return;
    }
    let Some(home) = std::env::var_os("USERPROFILE") else {
        return;
    };
    static TRACE_LOCK: Mutex<()> = Mutex::new(());
    let Ok(_guard) = TRACE_LOCK.lock() else {
        return;
    };
    let path = std::path::PathBuf::from(home).join(".winsmux-task868-spawn-observation.jsonl");
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    else {
        return;
    };
    let row = serde_json::json!({
        "executable": executable,
        "current_directory": current_directory,
        "arguments": arguments,
        "pid": pid,
    });
    if let Ok(bytes) = serde_json::to_vec(&row) {
        let _ = file.write_all(&bytes);
        let _ = file.write_all(b"\n");
    }
}

static UNCERTAIN_CHILDREN: Mutex<Vec<PreparedChild>> = Mutex::new(Vec::new());

fn retain_uncertain_child(child: PreparedChild) {
    match UNCERTAIN_CHILDREN.lock() {
        Ok(mut held) => held.push(child),
        Err(_) => std::mem::forget(child),
    }
}

fn recover_unobserved_child(child: PreparedChild) {
    let pending = Arc::new(Mutex::new(Some(child)));
    let worker_pending = Arc::clone(&pending);
    let started = std::thread::Builder::new()
        .name("winsmux-unpublished-reaper".to_owned())
        .spawn(move || {
            let Some(mut child) = worker_pending.lock().ok().and_then(|mut slot| slot.take()) else {
                return;
            };
            if child.process.is_valid()
                && unsafe { WaitForSingleObject(child.process.0, INFINITE) } != WAIT_OBJECT_0
            {
                retain_uncertain_child(child);
                return;
            }
            if child.job.is_valid() {
                match job_active_processes(child.job.0) {
                    Some(0) => {}
                    Some(_) if unsafe { TerminateJobObject(child.job.0, 1) } != 0 => {
                        loop {
                            match job_active_processes(child.job.0) {
                                Some(0) => break,
                                Some(_) => std::thread::yield_now(),
                                None => {
                                    retain_uncertain_child(child);
                                    return;
                                }
                            }
                        }
                    }
                    _ => {
                        retain_uncertain_child(child);
                        return;
                    }
                }
            }
            child.kill_on_drop = false;
        });
    if started.is_err() {
        if let Some(child) = pending.lock().ok().and_then(|mut slot| slot.take()) {
            retain_uncertain_child(child);
        }
    }
}

pub fn spawn_suspended(
    cwd: &str,
    executable: &str,
    arguments: &[&str],
) -> Result<PreparedChild, SpawnError> {
    spawn_suspended_inner(cwd, executable, arguments, true)
}

pub(crate) fn spawn_suspended_probe(
    cwd: &str,
    executable: &str,
    arguments: &[&str],
) -> Result<PreparedChild, SpawnError> {
    spawn_suspended_inner(cwd, executable, arguments, false)
}

fn spawn_suspended_inner(
    cwd: &str,
    executable: &str,
    arguments: &[&str],
    assign_job: bool,
) -> Result<PreparedChild, SpawnError> {
    let (mut input_write, mut input_read) =
        create_named_pipe_pair(PIPE_ACCESS_OUTBOUND, GENERIC_READ, true, 4096)?;
    let (mut output_read, mut output_write) =
        create_named_pipe_pair(PIPE_ACCESS_INBOUND, GENERIC_WRITE, false, 4096)?;
    let size = COORD {
        X: INITIAL_COLS,
        Y: INITIAL_ROWS,
    };
    let mut hpcon: HPCON = 0;
    let created_con =
        unsafe { CreatePseudoConsole(size, input_read.0, output_write.0, 0, &mut hpcon) };
    unsafe {
        SetHandleInformation(input_write.0, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(output_read.0, HANDLE_FLAG_INHERIT, 0);
    }
    if created_con != 0 || hpcon == 0 {
        input_read.close();
        output_write.close();
        input_write.close();
        output_read.close();
        return Err(SpawnError::Runtime);
    }
    let mut hpcon = PseudoConsole(hpcon);
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() || job == INVALID_HANDLE_VALUE {
        hpcon.close();
        input_read.close();
        output_write.close();
        input_write.close();
        output_read.close();
        return Err(SpawnError::Runtime);
    }
    let mut job = RawHandle(job);
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            (&mut limits as *mut JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast::<c_void>(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        job.close();
        hpcon.close();
        input_read.close();
        output_write.close();
        input_write.close();
        output_read.close();
        return Err(SpawnError::Runtime);
    }
    let mut attributes = match AttributeList::for_pseudoconsole(hpcon.0) {
        Ok(list) => list,
        Err(error) => {
            job.close();
            hpcon.close();
            input_read.close();
            output_write.close();
            input_write.close();
            output_read.close();
            return Err(error);
        }
    };
    let mut command_line = quote_argument(executable);
    for argument in arguments {
        command_line.push(' ');
        command_line.push_str(&quote_argument(argument));
    }
    let mut command_wide: Vec<u16> = command_line
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let exe_wide: Vec<u16> = executable
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let current_directory = dos_cwd(cwd);
    let cwd_wide: Vec<u16> = current_directory
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut startup = STARTUPINFOEXW::default();
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
    startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
    startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
    startup.lpAttributeList = attributes.raw();
    let mut information = PROCESS_INFORMATION::default();
    let created = unsafe {
        CreateProcessW(
            exe_wide.as_ptr(),
            command_wide.as_mut_ptr(),
            null(),
            null(),
            0,
            CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            null(),
            cwd_wide.as_ptr(),
            &mut startup.StartupInfo,
            &mut information,
        )
    };
    drop(attributes);
    input_read.close();
    output_write.close();
    if created == 0 {
        job.close();
        hpcon.close();
        input_write.close();
        output_read.close();
        return Err(SpawnError::Runtime);
    }
    let mut child = PreparedChild {
        process: RawHandle(information.hProcess),
        thread: RawHandle(information.hThread),
        job,
        hpcon,
        input: input_write,
        output: output_read,
        inherit_owner: false,
        inherit_public: false,
        b_inherit_handles: false,
        kill_on_drop: true,
        write: None,
    };
    #[cfg(debug_assertions)]
    trace_spawn_for_real_cli_test(executable, &current_directory, arguments, information.dwProcessId);
    if assign_job && !child.assign_to_job() {
        // The suspended root is not in the Job. Keep every handle until its
        // termination is observed; a failed wait is not cleanup proof.
        loop {
            unsafe { TerminateProcess(child.process.0, 1) };
            if unsafe { WaitForSingleObject(child.process.0, 0) } == WAIT_OBJECT_0 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        child.disarm();
        return Err(SpawnError::Runtime);
    }
    Ok(child)
}

pub fn spawn_usual_shell_child(cwd: &str) -> Result<PreparedChild, SpawnError> {
    let executable = search_pwsh()?;
    spawn_suspended_shell(cwd, &executable)
}

pub fn duplicate_handle(handle: HANDLE) -> Option<HANDLE> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return None;
    }
    let mut duplicated = INVALID_HANDLE_VALUE;
    let ok = unsafe {
        DuplicateHandle(
            GetCurrentProcess(),
            handle,
            GetCurrentProcess(),
            &mut duplicated,
            0,
            0,
            DUPLICATE_SAME_ACCESS,
        )
    };
    if ok == 0 || duplicated.is_null() || duplicated == INVALID_HANDLE_VALUE {
        None
    } else {
        Some(duplicated)
    }
}

pub fn resume_once(thread: HANDLE) -> u32 {
    unsafe { ResumeThread(thread) }
}

pub fn suspend_once(thread: HANDLE) -> u32 {
    unsafe { SuspendThread(thread) }
}

fn next_pipe_name() -> Vec<u16> {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let name = format!(
        r"\\.\pipe\winsmux-864-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    name.encode_utf16().chain(std::iter::once(0)).collect()
}

fn create_named_pipe_pair(
    server_access: u32,
    client_access: u32,
    overlapped_server: bool,
    buffer: u32,
) -> Result<(RawHandle, RawHandle), SpawnError> {
    let name = next_pipe_name();
    let mut attributes = inheritable_attributes();
    let mut server_mode = server_access;
    if overlapped_server {
        server_mode |= FILE_FLAG_OVERLAPPED;
    }
    let server = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            server_mode,
            PIPE_TYPE_BYTE | PIPE_WAIT,
            1,
            buffer,
            buffer,
            0,
            &mut attributes,
        )
    };
    if server.is_null() || server == INVALID_HANDLE_VALUE {
        return Err(SpawnError::Runtime);
    }
    let client = unsafe {
        CreateFileW(
            name.as_ptr(),
            client_access,
            0,
            &mut attributes,
            OPEN_EXISTING,
            0,
            null_mut(),
        )
    };
    if client.is_null() || client == INVALID_HANDLE_VALUE {
        unsafe {
            CloseHandle(server);
        }
        return Err(SpawnError::Runtime);
    }
    Ok((RawHandle(server), RawHandle(client)))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadClass {
    Payload,
    TrueZero,
    Drain,
    ReadError,
}

pub fn classify_readfile(ok: i32, n: u32, gle: u32) -> ReadClass {
    if ok != 0 {
        if n == 0 {
            ReadClass::TrueZero
        } else {
            ReadClass::Payload
        }
    } else if gle == ERROR_BROKEN_PIPE || gle == ERROR_HANDLE_EOF {
        ReadClass::Drain
    } else {
        ReadClass::ReadError
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WriteIdentity {
    pub pin: usize,
    pub overlapped: usize,
    pub event: HANDLE,
    pub file: HANDLE,
}

#[derive(Debug)]
pub enum IoObservation {
    Pending,
    QueryFailed(u32),
    Completed { ok: bool, written: u32, gle: u32 },
}

pub enum WriteResult {
    Delivered,
    Aborted,
    IoFailed,
    Unknown,
}

pub struct WriteOp {
    payload: Vec<u8>,
    overlapped: OVERLAPPED,
    event: HANDLE,
    file: HANDLE,
    completed: bool,
}

unsafe impl Send for WriteOp {}

pub struct PinnedWrite {
    inner: ManuallyDrop<Pin<Box<WriteOp>>>,
}

unsafe impl Send for PinnedWrite {}

static HOST_RETAINED: Mutex<Vec<Pin<Box<WriteOp>>>> = Mutex::new(Vec::new());

fn leak_pin(pin: Pin<Box<WriteOp>>) {
    if let Ok(mut held) = HOST_RETAINED.lock() {
        held.push(pin);
    } else {
        std::mem::forget(pin);
    }
}

pub fn retain_write(op: PinnedWrite) {
    leak_pin(op.into_pin());
}

pub fn retained_write_count() -> usize {
    HOST_RETAINED.lock().map(|held| held.len()).unwrap_or(0)
}

fn identity_of(op: &WriteOp) -> WriteIdentity {
    WriteIdentity {
        pin: op as *const WriteOp as usize,
        overlapped: std::ptr::addr_of!(op.overlapped) as usize,
        event: op.event,
        file: op.file,
    }
}

pub fn retained_write_identities() -> Vec<WriteIdentity> {
    HOST_RETAINED
        .lock()
        .map(|held| {
            held.iter()
                .map(|pin| identity_of(pin.as_ref().get_ref()))
                .collect()
        })
        .unwrap_or_default()
}

pub enum IssueStart {
    Pending(PinnedWrite),
    Immediate { written: u32 },
    Failed(u32),
}

pub fn issue_write_byte(file: HANDLE, byte: u8) -> IssueStart {
    issue_write_bytes(file, &[byte])
}

pub fn issue_write_bytes(file: HANDLE, payload: &[u8]) -> IssueStart {
    if file.is_null() || file == INVALID_HANDLE_VALUE {
        return IssueStart::Failed(0);
    }
    let Ok(n) = u32::try_from(payload.len()) else {
        return IssueStart::Failed(0);
    };
    unsafe {
        let event = CreateEventW(null(), 1, 0, null());
        if event.is_null() || event == INVALID_HANDLE_VALUE {
            return IssueStart::Failed(GetLastError());
        }
        let mut boxed = Box::new(WriteOp {
            payload: payload.to_vec(),
            overlapped: std::mem::zeroed(),
            event,
            file,
            completed: false,
        });
        boxed.overlapped.hEvent = event;
        let ok = WriteFile(
            file,
            boxed.payload.as_ptr(),
            n,
            null_mut(),
            &mut boxed.overlapped,
        );
        let gle = GetLastError();
        if ok == 0 && gle != ERROR_IO_PENDING {
            CloseHandle(event);
            return IssueStart::Failed(gle);
        }
        if ok != 0 {
            let mut written = 0u32;
            let gor = GetOverlappedResult(file, &mut boxed.overlapped, &mut written, 0);
            CloseHandle(event);
            boxed.event = INVALID_HANDLE_VALUE;
            boxed.completed = true;
            if gor != 0 && written == n {
                return IssueStart::Immediate { written };
            }
            return IssueStart::Failed(GetLastError());
        }
        IssueStart::Pending(PinnedWrite::new(boxed))
    }
}

fn finish_issued_write(
    slot: &mut Option<PinnedWrite>,
    mut op: PinnedWrite,
    cancel_requested: bool,
) -> bool {
    let obs = op.query();
    match op.classify_payload(&obs, cancel_requested) {
        WriteResult::Delivered => {
            op.mark_completed_and_close_event();
            true
        }
        WriteResult::Aborted | WriteResult::IoFailed => {
            op.mark_completed_and_close_event();
            false
        }
        WriteResult::Unknown => {
            *slot = Some(op);
            false
        }
    }
}

fn classify_with_len(obs: &IoObservation, cancel_requested: bool, expected: u32) -> WriteResult {
    match obs {
        IoObservation::Completed {
            ok: true, written, ..
        } if *written == expected => WriteResult::Delivered,
        IoObservation::Completed {
            ok: false,
            gle: ERROR_OPERATION_ABORTED,
            ..
        } if cancel_requested => WriteResult::Aborted,
        IoObservation::Completed { .. } => WriteResult::IoFailed,
        IoObservation::Pending | IoObservation::QueryFailed(_) => WriteResult::Unknown,
    }
}

impl PinnedWrite {
    fn new(boxed: Box<WriteOp>) -> Self {
        Self {
            inner: ManuallyDrop::new(Pin::from(boxed)),
        }
    }

    fn into_pin(mut self) -> Pin<Box<WriteOp>> {
        let pin = unsafe { ManuallyDrop::take(&mut self.inner) };
        std::mem::forget(self);
        pin
    }

    fn inner_mut(&mut self) -> &mut WriteOp {
        unsafe { Pin::get_unchecked_mut(Pin::as_mut(&mut *self.inner)) }
    }

    fn inner(&self) -> &WriteOp {
        Pin::as_ref(&*self.inner).get_ref()
    }

    pub fn request_cancel(&self) -> u32 {
        unsafe {
            let op = self.inner();
            let ok = CancelIoEx(op.file, &op.overlapped);
            if ok == 0 {
                GetLastError()
            } else {
                0
            }
        }
    }

    pub fn wait_event(&self) -> u32 {
        unsafe { WaitForSingleObject(self.inner().event, INFINITE) }
    }

    pub fn query(&mut self) -> IoObservation {
        unsafe {
            let op = self.inner_mut();
            let mut written = 0u32;
            let gor = GetOverlappedResult(op.file, &mut op.overlapped, &mut written, 0);
            if gor != 0 {
                op.completed = true;
                return IoObservation::Completed {
                    ok: true,
                    written,
                    gle: 0,
                };
            }
            let gle = GetLastError();
            if gle == ERROR_IO_INCOMPLETE {
                return IoObservation::Pending;
            }
            if gle == ERROR_OPERATION_ABORTED || gle == ERROR_BROKEN_PIPE || gle == ERROR_HANDLE_EOF
            {
                op.completed = true;
                return IoObservation::Completed {
                    ok: false,
                    written,
                    gle,
                };
            }
            IoObservation::QueryFailed(gle)
        }
    }

    pub fn classify(obs: &IoObservation, cancel_requested: bool) -> WriteResult {
        classify_with_len(obs, cancel_requested, 1)
    }

    pub fn classify_payload(&self, obs: &IoObservation, cancel_requested: bool) -> WriteResult {
        let Some(expected) = u32::try_from(self.inner().payload.len()).ok() else {
            return match obs {
                IoObservation::Pending | IoObservation::QueryFailed(_) => WriteResult::Unknown,
                IoObservation::Completed {
                    ok: false,
                    gle: ERROR_OPERATION_ABORTED,
                    ..
                } if cancel_requested => WriteResult::Aborted,
                IoObservation::Completed { .. } => WriteResult::IoFailed,
            };
        };
        classify_with_len(obs, cancel_requested, expected)
    }

    pub fn identity(&self) -> WriteIdentity {
        identity_of(self.inner())
    }

    pub fn mark_completed_and_close_event(&mut self) {
        let op = self.inner_mut();
        op.completed = true;
        if !op.event.is_null() && op.event != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(op.event);
            }
            op.event = INVALID_HANDLE_VALUE;
        }
    }
}

impl Drop for PinnedWrite {
    fn drop(&mut self) {
        let pin = unsafe { ManuallyDrop::take(&mut self.inner) };
        if pin.as_ref().get_ref().completed {
            drop(pin);
        } else {
            leak_pin(pin);
        }
    }
}

impl Drop for WriteOp {
    fn drop(&mut self) {
        if self.completed && !self.event.is_null() && self.event != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.event);
            }
            self.event = INVALID_HANDLE_VALUE;
        }
    }
}

#[cfg(test)]
mod write_bytes_tests {
    use super::*;

    fn completed(ok: bool, written: u32, gle: u32) -> IoObservation {
        IoObservation::Completed { ok, written, gle }
    }

    #[test]
    fn shared_classifier_full_multibyte_completion_is_delivered() {
        let obs = completed(true, 7, 0);
        assert!(matches!(
            classify_with_len(&obs, false, 7),
            WriteResult::Delivered
        ));
    }

    #[test]
    fn shared_classifier_partial_success_is_not_delivered() {
        let obs = completed(true, 3, 0);
        assert!(matches!(
            classify_with_len(&obs, false, 7),
            WriteResult::IoFailed
        ));
    }

    #[test]
    fn shared_classifier_overcount_is_not_delivered() {
        let obs = completed(true, 8, 0);
        assert!(matches!(
            classify_with_len(&obs, false, 7),
            WriteResult::IoFailed
        ));
    }

    #[test]
    fn shared_classifier_pending_and_query_failed_are_unknown() {
        assert!(matches!(
            classify_with_len(&IoObservation::Pending, true, 4),
            WriteResult::Unknown
        ));
        assert!(matches!(
            classify_with_len(&IoObservation::QueryFailed(5), false, 4),
            WriteResult::Unknown
        ));
    }

    #[test]
    fn shared_classifier_requested_abort_is_aborted_unsolicited_is_io_failed() {
        let abort = completed(false, 0, ERROR_OPERATION_ABORTED);
        assert!(matches!(
            classify_with_len(&abort, true, 4),
            WriteResult::Aborted
        ));
        assert!(matches!(
            classify_with_len(&abort, false, 4),
            WriteResult::IoFailed
        ));
    }

    #[test]
    fn one_byte_classify_keeps_written_one_delivery_rule() {
        let full = completed(true, 1, 0);
        let empty = completed(true, 0, 0);
        let two = completed(true, 2, 0);
        assert!(matches!(
            PinnedWrite::classify(&full, false),
            WriteResult::Delivered
        ));
        assert!(matches!(
            PinnedWrite::classify(&empty, false),
            WriteResult::IoFailed
        ));
        assert!(matches!(
            PinnedWrite::classify(&two, false),
            WriteResult::IoFailed
        ));
    }

    #[test]
    fn empty_payload_length_delivers_only_on_zero_written() {
        assert!(matches!(
            classify_with_len(&completed(true, 0, 0), false, 0),
            WriteResult::Delivered
        ));
        assert!(matches!(
            classify_with_len(&completed(true, 1, 0), false, 0),
            WriteResult::IoFailed
        ));
    }

    #[test]
    fn named_pipe_multibyte_write_delivers_exact_owned_payload() {
        let payload: &[u8] = b"hello\xE4\xB8\x96\xE7\x95\x8C\x0D";
        let (mut server, mut client) =
            create_named_pipe_pair(PIPE_ACCESS_OUTBOUND, GENERIC_READ, true, 4096)
                .expect("named pipe pair");
        match issue_write_bytes(server.0, payload) {
            IssueStart::Immediate { written } => {
                assert_eq!(written as usize, payload.len());
            }
            IssueStart::Pending(mut op) => {
                assert_eq!(op.inner().payload.as_slice(), payload);
                assert_eq!(op.wait_event(), WAIT_OBJECT_0);
                let obs = op.query();
                assert!(matches!(
                    op.classify_payload(&obs, false),
                    WriteResult::Delivered
                ));
                op.mark_completed_and_close_event();
            }
            IssueStart::Failed(gle) => panic!("issue_write_bytes failed: {gle}"),
        }
        let mut buf = [0u8; 64];
        let mut n = 0u32;
        let ok = unsafe {
            ReadFile(
                client.0,
                buf.as_mut_ptr(),
                buf.len() as u32,
                &mut n,
                null_mut(),
            )
        };
        assert_ne!(ok, 0);
        assert_eq!(&buf[..n as usize], payload);
        client.close();
        server.close();
    }

    #[test]
    fn named_pipe_pending_multibyte_keeps_payload_and_cancel_is_not_delivery() {
        let payload: &[u8] = b"ABC\x0D";
        let (mut server, mut client) =
            create_named_pipe_pair(PIPE_ACCESS_OUTBOUND, GENERIC_READ, true, 1)
                .expect("named pipe pair");
        let mut fills = Vec::new();
        let mut filled = 0usize;
        let pending_start = loop {
            match issue_write_byte(server.0, 0) {
                IssueStart::Pending(op) => {
                    fills.push(op);
                    break issue_write_bytes(server.0, payload);
                }
                IssueStart::Immediate { .. } => {
                    filled += 1;
                    if filled > 8192 {
                        client.close();
                        server.close();
                        panic!("pipe never filled");
                    }
                }
                IssueStart::Failed(_) => {
                    client.close();
                    server.close();
                    panic!("fill failed");
                }
            }
        };
        let IssueStart::Pending(mut op) = pending_start else {
            for fill in fills {
                retain_write(fill);
            }
            client.close();
            server.close();
            panic!("multi-byte write was not pending");
        };
        assert_eq!(op.inner().payload.as_slice(), payload);
        assert_eq!(op.identity().file, server.0);
        let expected = u32::try_from(payload.len()).expect("payload fits in DWORD");
        let full = completed(true, expected, 0);
        let partial = completed(true, 1, 0);
        let over = completed(true, expected + 1, 0);
        assert!(matches!(
            op.classify_payload(&full, false),
            WriteResult::Delivered
        ));
        assert!(matches!(
            op.classify_payload(&partial, false),
            WriteResult::IoFailed
        ));
        assert!(matches!(
            op.classify_payload(&over, false),
            WriteResult::IoFailed
        ));
        assert!(matches!(
            PinnedWrite::classify(&partial, false),
            WriteResult::Delivered
        ));
        assert!(matches!(
            op.classify_payload(&IoObservation::Pending, true),
            WriteResult::Unknown
        ));
        let _ = op.request_cancel();
        if op.wait_event() != WAIT_OBJECT_0 {
            retain_write(op);
            for fill in fills {
                retain_write(fill);
            }
            client.close();
            server.close();
            panic!("cancel wait failed");
        }
        let obs = op.query();
        assert!(matches!(
            op.classify_payload(&obs, true),
            WriteResult::Aborted
        ));
        op.mark_completed_and_close_event();
        for fill in fills {
            retain_write(fill);
        }
        client.close();
        server.close();
    }
}

pub fn prove_overlapped_cancel_is_not_delivery() -> bool {
    let Ok((mut server, mut client)) =
        create_named_pipe_pair(PIPE_ACCESS_OUTBOUND, GENERIC_READ, true, 1)
    else {
        return false;
    };
    let mut fills = Vec::new();
    let pending_ctrl = loop {
        match issue_write_byte(server.0, 0) {
            IssueStart::Pending(op) => {
                fills.push(op);
                break issue_write_byte(server.0, 0x03);
            }
            IssueStart::Immediate { .. } => {
                if fills.len() > 8192 {
                    client.close();
                    server.close();
                    return false;
                }
            }
            IssueStart::Failed(_) => {
                client.close();
                server.close();
                return false;
            }
        }
    };
    let IssueStart::Pending(mut op) = pending_ctrl else {
        for fill in fills {
            retain_write(fill);
        }
        client.close();
        server.close();
        return false;
    };
    let _ = op.request_cancel();
    if op.wait_event() != WAIT_OBJECT_0 {
        retain_write(op);
        for fill in fills {
            retain_write(fill);
        }
        client.close();
        server.close();
        return false;
    }
    let obs = op.query();
    let aborted = matches!(PinnedWrite::classify(&obs, true), WriteResult::Aborted);
    if matches!(PinnedWrite::classify(&obs, true), WriteResult::Unknown) {
        retain_write(op);
    } else {
        op.mark_completed_and_close_event();
    }
    for fill in fills {
        retain_write(fill);
    }
    client.close();
    server.close();
    aborted
}

pub const ERROR_NOT_FOUND: u32 = 1168;

#[derive(Clone, Copy, Debug)]
pub struct ReadCloseProof {
    pub csi_gle: u32,
    pub csi_not_found: bool,
    pub first_ok: i32,
    pub first_n: u32,
    pub first_gle: u32,
    pub first_class: ReadClass,
    pub second_ok: i32,
    pub second_n: u32,
    pub second_gle: u32,
    pub second_class: ReadClass,
    pub job_ok: i32,
    pub job_n: u32,
    pub job_gle: u32,
    pub job_class: ReadClass,
}

fn sync_read(handle: HANDLE) -> (i32, u32, u32) {
    let mut buffer = [0u8; 64];
    let mut n = 0u32;
    let ok = unsafe {
        ReadFile(
            handle,
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut n,
            std::ptr::null_mut(),
        )
    };
    let gle = if ok != 0 {
        0
    } else {
        unsafe { GetLastError() }
    };
    (ok, n, gle)
}

fn read_until_terminal(handle: HANDLE) -> ((i32, u32, u32), (i32, u32, u32)) {
    loop {
        let first = sync_read(handle);
        match classify_readfile(first.0, first.1, first.2) {
            ReadClass::Payload | ReadClass::TrueZero => continue,
            ReadClass::Drain | ReadClass::ReadError => {
                let second = sync_read(handle);
                return (first, second);
            }
        }
    }
}

pub fn prove_readfile_after_pty_and_job_close(
    cwd: &str,
    executable: &str,
) -> Option<ReadCloseProof> {
    let mut child = spawn_suspended_shell(cwd, executable).ok()?;
    child.disarm();
    let output = child.output.take();
    if output.is_null() || output == INVALID_HANDLE_VALUE {
        child.rollback();
        return None;
    }
    let mut unused: OVERLAPPED = unsafe { std::mem::zeroed() };
    let csi_ok = unsafe { CancelIoEx(output, &unused) };
    let csi_gle = if csi_ok == 0 {
        unsafe { GetLastError() }
    } else {
        0
    };
    let _ = unused;
    let (tx, rx) = std::sync::mpsc::channel();
    let output_bits = output as usize;
    let reader = std::thread::spawn(move || {
        let handle = output_bits as HANDLE;
        let pair = read_until_terminal(handle);
        unsafe {
            CloseHandle(handle);
        }
        let _ = tx.send(pair);
    });
    let previous = resume_once(child.thread.0);
    if previous == u32::MAX {
        child.rollback();
        return None;
    }
    unsafe {
        WaitForSingleObject(child.process.0, 10_000);
    }
    let pair = match rx.recv_timeout(std::time::Duration::from_millis(500)) {
        Ok(pair) => pair,
        Err(_) => {
            let hpcon = child.hpcon.take();
            if hpcon != 0 {
                unsafe {
                    ClosePseudoConsole(hpcon);
                }
            }
            rx.recv_timeout(std::time::Duration::from_secs(10)).ok()?
        }
    };
    let hpcon = child.hpcon.take();
    if hpcon != 0 {
        unsafe {
            ClosePseudoConsole(hpcon);
        }
    }
    let _ = reader.join();
    let (first, second) = pair;
    let first_class = classify_readfile(first.0, first.1, first.2);
    let second_class = classify_readfile(second.0, second.1, second.2);
    child.rollback();

    let mut job_child = spawn_suspended_shell(cwd, executable).ok()?;
    job_child.disarm();
    let job_output = job_child.output.take();
    if job_output.is_null() || job_output == INVALID_HANDLE_VALUE {
        job_child.rollback();
        return None;
    }
    let (job_tx, job_rx) = std::sync::mpsc::channel();
    let job_bits = job_output as usize;
    let job_reader = std::thread::spawn(move || {
        let handle = job_bits as HANDLE;
        let pair = read_until_terminal(handle);
        unsafe {
            CloseHandle(handle);
        }
        let _ = job_tx.send(pair);
    });
    let _ = resume_once(job_child.thread.0);
    let job = job_child.job.take();
    if !job.is_null() && job != INVALID_HANDLE_VALUE {
        unsafe {
            CloseHandle(job);
        }
    }
    let job_pair = match job_rx.recv_timeout(std::time::Duration::from_secs(10)) {
        Ok(pair) => pair,
        Err(_) => {
            let hpcon = job_child.hpcon.take();
            if hpcon != 0 {
                unsafe {
                    ClosePseudoConsole(hpcon);
                }
            }
            job_rx
                .recv_timeout(std::time::Duration::from_secs(10))
                .ok()?
        }
    };
    let _ = job_reader.join();
    job_child.rollback();
    let job_read = job_pair.0;
    Some(ReadCloseProof {
        csi_gle,
        csi_not_found: csi_gle == ERROR_NOT_FOUND,
        first_ok: first.0,
        first_n: first.1,
        first_gle: first.2,
        first_class,
        second_ok: second.0,
        second_n: second.1,
        second_gle: second.2,
        second_class,
        job_ok: job_read.0,
        job_n: job_read.1,
        job_gle: job_read.2,
        job_class: classify_readfile(job_read.0, job_read.1, job_read.2),
    })
}

pub fn issue_pending_overlapped_write() -> Option<(PinnedWrite, WriteIdentity, IoObservation)> {
    let Ok((mut server, mut client)) =
        create_named_pipe_pair(PIPE_ACCESS_OUTBOUND, GENERIC_READ, true, 1)
    else {
        return None;
    };
    let mut fills = Vec::new();
    let pending = loop {
        match issue_write_byte(server.0, 0) {
            IssueStart::Pending(op) => {
                fills.push(op);
                break issue_write_byte(server.0, 0x03);
            }
            IssueStart::Immediate { .. } => {
                if fills.len() > 8192 {
                    client.close();
                    server.close();
                    return None;
                }
            }
            IssueStart::Failed(_) => {
                client.close();
                server.close();
                return None;
            }
        }
    };
    let IssueStart::Pending(mut op) = pending else {
        for fill in fills {
            retain_write(fill);
        }
        client.close();
        server.close();
        return None;
    };
    for fill in fills {
        retain_write(fill);
    }
    std::mem::forget(client);
    std::mem::forget(server);
    let identity = op.identity();
    let obs = op.query();
    Some((op, identity, obs))
}

pub fn handle_signaled(process: HANDLE) -> Option<bool> {
    match unsafe { WaitForSingleObject(process, 0) } {
        WAIT_OBJECT_0 => Some(true),
        WAIT_TIMEOUT => Some(false),
        _ => None,
    }
}

pub fn exit_code(process: HANDLE) -> Option<u32> {
    let mut code = 0u32;
    if unsafe { GetExitCodeProcess(process, &mut code) } == 0 {
        None
    } else {
        Some(code)
    }
}

pub fn job_active_processes(job: HANDLE) -> Option<u32> {
    let mut info = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
    let mut returned = 0u32;
    let ok = unsafe {
        QueryInformationJobObject(
            job,
            JobObjectBasicAccountingInformation,
            (&mut info as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast::<c_void>(),
            size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
            &mut returned,
        )
    };
    if ok == 0 {
        None
    } else {
        Some(info.ActiveProcesses)
    }
}

pub fn resize_pseudoconsole(hpcon: HPCON, cols: i16, rows: i16) -> bool {
    if !(1..=32767).contains(&cols) || !(1..=32767).contains(&rows) {
        return false;
    }
    let size = COORD { X: cols, Y: rows };
    unsafe { windows_sys::Win32::System::Console::ResizePseudoConsole(hpcon, size) == 0 }
}

#[cfg(test)]
mod provider_spawn_tests {
    use super::*;

    #[test]
    fn explicit_application_uses_exact_project_cwd() {
        let root = std::env::temp_dir().join(format!("winsmux-provider-cwd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("isolated cwd");
        let executable = search_pwsh().expect("pwsh.exe");
        let cwd = root.to_str().expect("Unicode cwd");
        let command = "[IO.File]::WriteAllText('cwd-marker.txt','cwd-ok')";
        let mut child = spawn_suspended(cwd, &executable, &["-NoProfile", "-Command", command])
            .expect("suspended child");
        assert_eq!(resume_once(child.thread.0), 1);
        child.disarm();
        assert_eq!(child.wait_exit(), Some(0));
        assert_eq!(job_active_processes(child.job.0), Some(0));
        child.hpcon.close();
        drop(child);
        assert_eq!(std::fs::read(root.join("cwd-marker.txt")).expect("cwd marker"), b"cwd-ok");
        std::fs::remove_dir_all(root).expect("isolated cleanup");
    }

    #[test]
    fn argument_quoting_preserves_quotes_and_terminal_backslashes() {
        assert_eq!(quote_argument("simple"), "simple");
        assert_eq!(quote_argument("a b"), "\"a b\"");
        assert_eq!(quote_argument("a\\\"b"), "\"a\\\\\\\"b\"");
        assert_eq!(quote_argument("a b\\"), "\"a b\\\\\"");
    }
}
