use super::{GitSupervisor, ReaderResponse, SupervisorState};
use crate::contract::{ErrorCode, MAX_MESSAGE_BYTES};
use crate::host::admission::ACTIVE_BYTES;
use crate::host::io::OwnedHandle;
use std::ffi::c_void;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;
use windows_sys::Win32::Foundation::{
    HANDLE, GENERIC_READ, GENERIC_WRITE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
    FILE_ATTRIBUTE_NORMAL, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_READ_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, ReadFile, WriteFile,
};
use windows_sys::Win32::System::JobObjects::{
    CreateJobObjectW, IsProcessInJob, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_ACTIVE_PROCESS, JOB_OBJECT_LIMIT_JOB_MEMORY, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::Pipes::CreatePipe;
use windows_sys::Win32::System::SystemInformation::GetWindowsDirectoryW;
use windows_sys::Win32::System::Threading::{
    CreateProcessW, DeleteProcThreadAttributeList, GetExitCodeProcess,
    InitializeProcThreadAttributeList, ResumeThread, TerminateProcess,
    UpdateProcThreadAttribute, WaitForSingleObject,
    CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, INFINITE,
    PROCESS_INFORMATION, PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROC_THREAD_ATTRIBUTE_JOB_LIST,
    PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY, STARTF_USESTDHANDLES, STARTUPINFOEXW, STARTUPINFOW,
};
use windows_sys::Win32::System::WindowsProgramming::PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;

struct Attributes { storage: Vec<usize> }
impl Attributes {
    fn new(jobs: &mut [HANDLE; 2], handles: &mut [HANDLE; 3], policy: &mut u32,
        mitigation: &mut u64) -> Result<Self, ErrorCode> {
        let mut size = 0usize;
        unsafe { InitializeProcThreadAttributeList(null_mut(), 4, 0, &mut size); }
        if size == 0 { return Err(ErrorCode::RuntimeFailed); }
        let mut storage = vec![0usize; size.div_ceil(size_of::<usize>())];
        let list = storage.as_mut_ptr().cast::<c_void>();
        if unsafe { InitializeProcThreadAttributeList(list, 4, 0, &mut size) } == 0 {
            return Err(ErrorCode::RuntimeFailed);
        }
        let result = (|| {
            for (attribute, data, bytes) in [
                (PROC_THREAD_ATTRIBUTE_JOB_LIST, jobs.as_mut_ptr().cast::<c_void>(), size_of::<[HANDLE; 2]>()),
                (PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles.as_mut_ptr().cast::<c_void>(), size_of::<[HANDLE; 3]>()),
                (PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY, (policy as *mut u32).cast::<c_void>(), size_of::<u32>()),
                (PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY, (mitigation as *mut u64).cast::<c_void>(), size_of::<u64>()),
            ] {
                if unsafe { UpdateProcThreadAttribute(list, 0, attribute as usize, data, bytes, null_mut(), null()) } == 0 {
                    return Err(ErrorCode::RuntimeFailed);
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            unsafe { DeleteProcThreadAttributeList(list); }
            return Err(error);
        }
        Ok(Self { storage })
    }
    fn raw(&mut self) -> *mut c_void { self.storage.as_mut_ptr().cast() }
}
impl Drop for Attributes {
    fn drop(&mut self) { unsafe { DeleteProcThreadAttributeList(self.raw()); } }
}

fn owned(raw: HANDLE) -> Result<OwnedHandle, ErrorCode> {
    unsafe { OwnedHandle::from_raw(raw) }.map_err(|_| ErrorCode::RuntimeFailed)
}

fn job(memory_limit: Option<usize>) -> Result<OwnedHandle, ErrorCode> {
    let handle = owned(unsafe { CreateJobObjectW(null(), null()) })?;
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if let Some(bytes) = memory_limit {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
        limits.JobMemoryLimit = bytes;
    } else {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit = 1;
    }
    if unsafe { SetInformationJobObject(
        handle.raw(), JobObjectExtendedLimitInformation,
        (&mut limits as *mut JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
        size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
    ) } == 0 { return Err(ErrorCode::RuntimeFailed); }
    Ok(handle)
}

fn pipe() -> Result<(OwnedHandle, OwnedHandle), ErrorCode> {
    let mut read = null_mut();
    let mut write = null_mut();
    if unsafe { CreatePipe(&mut read, &mut write, null(), 0) } == 0 {
        return Err(ErrorCode::RuntimeFailed);
    }
    Ok((owned(read)?, owned(write)?))
}

fn inherited(handle: HANDLE) -> Result<OwnedHandle, ErrorCode> {
    use windows_sys::Win32::Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS};
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    let mut duplicate = null_mut();
    if unsafe { DuplicateHandle(
        GetCurrentProcess(), handle, GetCurrentProcess(), &mut duplicate,
        0, 1, DUPLICATE_SAME_ACCESS,
    ) } == 0 { return Err(ErrorCode::RuntimeFailed); }
    owned(duplicate)
}

fn wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}

fn held_image() -> Result<(PathBuf, Vec<OwnedHandle>, OwnedHandle), ErrorCode> {
    let path = std::env::current_exe().map_err(|_| ErrorCode::RuntimeFailed)?;
    held_image_at(path)
}

fn held_image_at(path: PathBuf) -> Result<(PathBuf, Vec<OwnedHandle>, OwnedHandle), ErrorCode> {
    if !path.is_absolute() || path.as_os_str().is_empty() { return Err(ErrorCode::UnsupportedFile); }
    let mut parents = Vec::new();
    for parent in path.parent().ok_or(ErrorCode::UnsupportedFile)?.ancestors().collect::<Vec<_>>().into_iter().rev() {
        let handle = owned(unsafe { CreateFileW(
            wide(parent).as_ptr(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
            null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        ) })?;
        let info = file_info(handle.raw())?;
        if info.dwFileAttributes & 0x400 != 0 || info.dwFileAttributes & 0x10 == 0 {
            return Err(ErrorCode::UnsupportedFile);
        }
        parents.push(handle);
    }
    let image = owned(unsafe { CreateFileW(
        wide(&path).as_ptr(), FILE_READ_ATTRIBUTES | GENERIC_READ, FILE_SHARE_READ,
        null(), OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, null_mut(),
    ) })?;
    let info = file_info(image.raw())?;
    if info.dwFileAttributes & 0x400 != 0 || info.dwFileAttributes & 0x10 != 0 {
        return Err(ErrorCode::UnsupportedFile);
    }
    Ok((path, parents, image))
}

fn file_info(handle: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION, ErrorCode> {
    let mut info = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 {
        return Err(ErrorCode::RuntimeFailed);
    }
    Ok(info)
}

fn write_all(handle: HANDLE, bytes: &[u8]) -> Result<(), ErrorCode> {
    let mut remaining = bytes;
    while !remaining.is_empty() {
        let mut written = 0u32;
        let count = u32::try_from(remaining.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
        if unsafe { WriteFile(handle, remaining.as_ptr(), count, &mut written, null_mut()) } == 0 || written == 0 {
            return Err(ErrorCode::RuntimeFailed);
        }
        remaining = &remaining[written as usize..];
    }
    Ok(())
}

fn read_exact(handle: HANDLE, mut output: &mut [u8]) -> Result<(), ErrorCode> {
    while !output.is_empty() {
        let mut count = 0u32;
        if unsafe { ReadFile(handle, output.as_mut_ptr(), output.len() as u32, &mut count, null_mut()) } == 0
            || count == 0 { return Err(ErrorCode::RuntimeFailed); }
        output = &mut output[count as usize..];
    }
    Ok(())
}

fn read_response(handle: HANDLE) -> Result<Vec<u8>, ErrorCode> {
    let mut size = [0u8; 4];
    read_exact(handle, &mut size)?;
    let size = u32::from_le_bytes(size) as usize;
    if size == 0 || size > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(size).map_err(|_| ErrorCode::ResourceExhausted)?;
    bytes.resize(size, 0);
    read_exact(handle, &mut bytes)?;
    let mut extra = 0u8;
    let mut count = 0u32;
    if unsafe { ReadFile(handle, &mut extra, 1, &mut count, null_mut()) } != 0 && count != 0 {
        return Err(ErrorCode::RuntimeFailed);
    }
    Ok(bytes)
}

struct ReaderExecution {
    process: OwnedHandle,
    request_job: OwnedHandle,
    writer: Option<JoinHandle<Result<(), ErrorCode>>>,
    reader: Option<JoinHandle<()>>,
    stopped: bool,
}

impl ReaderExecution {
    fn new(process: OwnedHandle, request_job: OwnedHandle) -> Self {
        Self { process, request_job, writer: None, reader: None, stopped: false }
    }

    fn terminate_wait(&mut self) {
        if self.stopped { return; }
        unsafe {
            TerminateJobObject(self.request_job.raw(), 1);
            TerminateProcess(self.process.raw(), 1);
            WaitForSingleObject(self.process.raw(), INFINITE);
        }
        self.stopped = true;
    }

    fn wait(&mut self, cancelled: &impl Fn() -> bool) -> Result<(), ErrorCode> {
        loop {
            match unsafe { WaitForSingleObject(self.process.raw(), 20) } {
                WAIT_OBJECT_0 => {
                    self.stopped = true;
                    return Ok(());
                }
                WAIT_TIMEOUT if cancelled() => {
                    self.terminate_wait();
                    return Err(ErrorCode::StateUnknown);
                }
                WAIT_TIMEOUT => {}
                _ => {
                    self.terminate_wait();
                    return Err(ErrorCode::RuntimeFailed);
                }
            }
        }
    }

    fn join_workers(&mut self) -> Result<(), ErrorCode> {
        let writer = self.writer.take().map(|worker| worker.join());
        let reader = self.reader.take().map(|worker| worker.join());
        if writer.as_ref().is_some_and(|result| result.is_err()) || reader.is_some_and(|result| result.is_err()) {
            return Err(ErrorCode::RuntimeFailed);
        }
        if let Some(Ok(Err(error))) = writer { return Err(error); }
        Ok(())
    }
}

impl Drop for ReaderExecution {
    fn drop(&mut self) {
        self.terminate_wait();
        let _ = self.join_workers();
    }
}

#[cfg(debug_assertions)]
fn fail_worker_start(which: &str) -> bool {
    let name = match which {
        "FIRST" => "WINSMUX_TASK867_FAIL_GIT_FIRST_WORKER_START",
        "SECOND" => "WINSMUX_TASK867_FAIL_GIT_SECOND_WORKER_START",
        _ => return false,
    };
    std::env::var_os(name).is_some()
}

#[cfg(not(debug_assertions))]
fn fail_worker_start(_which: &str) -> bool { false }

pub(super) fn execute(
    supervisor: &GitSupervisor, frame: &[u8], cancelled: impl Fn() -> bool,
) -> Result<ReaderResponse, ErrorCode> {
    if cancelled() { return Err(ErrorCode::StateUnknown); }
    super::decode_input(frame)?;
    let mut wire = Vec::new();
    wire.try_reserve_exact(4 + frame.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
    wire.extend_from_slice(&(frame.len() as u32).to_le_bytes());
    wire.extend_from_slice(frame);
    let (tx, rx) = mpsc::sync_channel(1);
    let (image_path, _image_parents, image) = held_image()?;
    super::image_imports::inspect_held_image(image.raw())?;
    let image_before = file_info(image.raw())?;
    let mut guard = supervisor.state.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
    let aggregate = match &mut *guard {
        SupervisorState::Closed => return Err(ErrorCode::StateUnknown),
        SupervisorState::Open(slot) => {
            if slot.is_none() { *slot = Some(job(Some(ACTIVE_BYTES))?); }
            slot.as_ref().ok_or(ErrorCode::RuntimeFailed)?
        }
    };
    let request_job = job(None)?;
    let (stdin_read, stdin_write) = pipe()?;
    let (stdout_read, stdout_write) = pipe()?;
    let nul = owned(unsafe { CreateFileW(
        wide(Path::new("NUL")).as_ptr(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        null(), OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null_mut(),
    ) })?;
    let child_stdin = inherited(stdin_read.raw())?;
    let child_stdout = inherited(stdout_write.raw())?;
    let child_stderr = inherited(nul.raw())?;
    let mut jobs = [aggregate.raw(), request_job.raw()];
    let mut handles = [child_stdin.raw(), child_stdout.raw(), child_stderr.raw()];
    let mut policy = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
    let mut mitigation = 1u64 << 60;
    let mut attributes = Attributes::new(&mut jobs, &mut handles, &mut policy, &mut mitigation)?;
    let mut startup = STARTUPINFOEXW::default();
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = child_stdin.raw();
    startup.StartupInfo.hStdOutput = child_stdout.raw();
    startup.StartupInfo.hStdError = child_stderr.raw();
    startup.lpAttributeList = attributes.raw();
    let mut process_info = PROCESS_INFORMATION::default();
    let mut command: Vec<u16> = "\"winsmux\" --winsmux-internal-git-reader\0".encode_utf16().collect();
    let env = minimal_environment()?;
    let cwd = image_path.parent().ok_or(ErrorCode::UnsupportedFile)?;
    let created = unsafe { CreateProcessW(
        wide(&image_path).as_ptr(), command.as_mut_ptr(), null(), null(), 1,
        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
        env.as_ptr().cast(), wide(cwd).as_ptr(),
        &startup.StartupInfo as *const STARTUPINFOW, &mut process_info,
    ) };
    if created == 0 { return Err(ErrorCode::RuntimeFailed); }
    let process = owned(process_info.hProcess)?;
    let thread = owned(process_info.hThread)?;
    let mut execution = ReaderExecution::new(process, request_job);
    let launched = (|| {
        let after = file_info(image.raw())?;
        if after.dwVolumeSerialNumber != image_before.dwVolumeSerialNumber
            || after.nFileIndexLow != image_before.nFileIndexLow
            || after.nFileIndexHigh != image_before.nFileIndexHigh {
            return Err(ErrorCode::UnsupportedFile);
        }
        for job in jobs {
            let mut member = 0;
            if unsafe { IsProcessInJob(execution.process.raw(), job, &mut member) } == 0 || member == 0 {
                return Err(ErrorCode::RuntimeFailed);
            }
        }
        if unsafe { ResumeThread(thread.raw()) } == u32::MAX { return Err(ErrorCode::RuntimeFailed); }
        Ok(())
    })();
    launched?;
    drop(guard);
    drop(stdin_read);
    drop(stdout_write);
    drop(child_stdin);
    drop(child_stdout);
    drop(child_stderr);
    if fail_worker_start("FIRST") { return Err(ErrorCode::ResourceExhausted); }
    execution.writer = Some(thread::Builder::new().name("winsmux-git-frame-writer".into())
        .spawn(move || write_all(stdin_write.raw(), &wire))
        .map_err(|_| ErrorCode::ResourceExhausted)?);
    if fail_worker_start("SECOND") { return Err(ErrorCode::ResourceExhausted); }
    execution.reader = Some(thread::Builder::new().name("winsmux-git-frame-reader".into())
        .spawn(move || { let _ = tx.send(read_response(stdout_read.raw())); })
        .map_err(|_| ErrorCode::ResourceExhausted)?);
    let outcome = loop {
        match rx.recv_timeout(Duration::from_millis(20)) {
            Ok(result) => break result,
            Err(mpsc::RecvTimeoutError::Disconnected) => break Err(ErrorCode::RuntimeFailed),
            Err(mpsc::RecvTimeoutError::Timeout) if cancelled() => break Err(ErrorCode::StateUnknown),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    };
    let wait_result = if outcome.is_err() {
        execution.terminate_wait();
        Ok(())
    } else {
        execution.wait(&cancelled)
    };
    let worker_result = execution.join_workers();
    wait_result?;
    worker_result?;
    let mut exit_code = 0;
    if let Err(error) = outcome { return Err(error); }
    if unsafe { GetExitCodeProcess(execution.process.raw(), &mut exit_code) } == 0 || exit_code != 0 {
        return Err(ErrorCode::RuntimeFailed);
    }
    let response: ReaderResponse = serde_json::from_slice(&outcome?)
        .map_err(|_| ErrorCode::RuntimeFailed)?;
    match response { ReaderResponse::Error { code } => Err(code), response => Ok(response) }
}

fn minimal_environment() -> Result<Vec<u16>, ErrorCode> {
    let mut windows = vec![0u16; 1024];
    let count = unsafe { GetWindowsDirectoryW(windows.as_mut_ptr(), windows.len() as u32) } as usize;
    if count == 0 || count >= windows.len() { return Err(ErrorCode::RuntimeFailed); }
    let system_root = String::from_utf16(&windows[..count]).map_err(|_| ErrorCode::RuntimeFailed)?;
    let mut env = Vec::new();
    for entry in [format!("SystemRoot={system_root}"), format!("WINDIR={system_root}")] {
        env.extend(entry.encode_utf16());
        env.push(0);
    }
    env.push(0);
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_image_jobs_and_inheritance_attributes_are_available() {
        let (_path, _parents, image) = held_image().expect("trusted fixed helper image");
        assert_eq!(file_info(image.raw()).unwrap().dwFileAttributes & 0x400, 0);
        let aggregate = job(Some(ACTIVE_BYTES)).expect("memory-limited aggregate job");
        let request = job(None).expect("one-process request job");
        let (read, write) = pipe().expect("private framed pipe");
        let inherited = inherited(read.raw()).expect("inheritable explicit handle");
        let mut jobs = [aggregate.raw(), request.raw()];
        let mut handles = [inherited.raw(), inherited.raw(), inherited.raw()];
        let mut policy = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
        let mut mitigation = 1u64 << 60;
        Attributes::new(&mut jobs, &mut handles, &mut policy, &mut mitigation).expect("atomic launch attributes");
        drop(write);
    }

    #[test]
    fn framed_helper_output_refuses_oversize_incomplete_and_extra_bytes() {
        let (read, write) = pipe().unwrap();
        write_all(write.raw(), &((MAX_MESSAGE_BYTES as u32) + 1).to_le_bytes()).unwrap();
        drop(write);
        assert_eq!(read_response(read.raw()).err(), Some(ErrorCode::ResourceExhausted));
        let (read, write) = pipe().unwrap();
        write_all(write.raw(), &8u32.to_le_bytes()).unwrap();
        write_all(write.raw(), b"short").unwrap();
        drop(write);
        assert_eq!(read_response(read.raw()).err(), Some(ErrorCode::RuntimeFailed));
        let (read, write) = pipe().unwrap();
        write_all(write.raw(), &2u32.to_le_bytes()).unwrap();
        write_all(write.raw(), b"{}x").unwrap();
        drop(write);
        assert_eq!(read_response(read.raw()).err(), Some(ErrorCode::RuntimeFailed));
    }
}
