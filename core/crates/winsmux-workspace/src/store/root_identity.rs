use crate::contract::{ErrorCode, Hex16, Hex32, RootIdentity, RootState};
use crate::host::admission::{AllocationAuthority, AllocationError, AllocationPool, ChargedVec};
use crate::host::io::OwnedHandle;
use sha2::{Digest, Sha256};
use std::ptr::{null, null_mut};
#[cfg(debug_assertions)]
use std::sync::{Arc, Condvar, Mutex};
#[cfg(debug_assertions)]
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_ACCESS_DENIED, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND,
    ERROR_SHARING_VIOLATION, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::System::Console::{
    AttachConsole, FreeConsole, GenerateConsoleCtrlEvent, SetConsoleCtrlHandler, CTRL_C_EVENT,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, GetDriveTypeW, GetFileInformationByHandle,
    GetFileInformationByHandleEx, GetFinalPathNameByHandleW, GetShortPathNameW, QueryDosDeviceW,
    RemoveDirectoryW, BY_HANDLE_FILE_INFORMATION,
    FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_ID_INFO, FILE_SHARE_READ, FileIdInfo, OPEN_EXISTING, ReadFile, SetFilePointerEx,
    FILE_BEGIN,
};

const FILE_READ_ATTRIBUTES: u32 = 0x0080;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const FILE_READ_DATA: u32 = 0x0001;
const SYNCHRONIZE: u32 = 0x00100000;
const FILE_OPEN: u32 = 1;
const FILE_DIRECTORY_FILE: u32 = 0x00000001;
const FILE_NON_DIRECTORY_FILE: u32 = 0x00000040;
const FILE_SYNCHRONOUS_IO_NONALERT: u32 = 0x00000020;
const FILE_OPEN_REPARSE_POINT: u32 = 0x00200000;
const OBJ_CASE_INSENSITIVE: u32 = 0x00000040;
const DRIVE_FIXED: u32 = 3;
const FILE_CASE_SENSITIVE_INFO: i32 = 23;
const FILE_CS_FLAG_CASE_SENSITIVE_DIR: u32 = 0x00000001;
const CSTR_EQUAL: i32 = 2;

#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *const u16,
}

#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root_directory: HANDLE,
    object_name: *const UnicodeString,
    attributes: u32,
    security_descriptor: *const core::ffi::c_void,
    security_quality_of_service: *const core::ffi::c_void,
}

#[repr(C)]
struct IoStatusBlock {
    status: i32,
    information: usize,
}

#[repr(C)]
struct FileCaseSensitiveInfo {
    flags: u32,
}

#[link(name = "ntdll")]
extern "system" {
    fn NtCreateFile(
        file_handle: *mut HANDLE,
        desired_access: u32,
        object_attributes: *const ObjectAttributes,
        io_status_block: *mut IoStatusBlock,
        allocation_size: *const i64,
        file_attributes: u32,
        share_access: u32,
        create_disposition: u32,
        create_options: u32,
        ea_buffer: *const core::ffi::c_void,
        ea_length: u32,
    ) -> i32;
    fn NtQueryDirectoryFile(
        file_handle: HANDLE,
        event: HANDLE,
        apc_routine: *const core::ffi::c_void,
        apc_context: *const core::ffi::c_void,
        io_status_block: *mut IoStatusBlock,
        file_information: *mut core::ffi::c_void,
        length: u32,
        file_information_class: i32,
        return_single_entry: u8,
        file_name: *const UnicodeString,
        restart_scan: u8,
    ) -> i32;
    fn NtQueryInformationProcess(
        process_handle: HANDLE,
        process_information_class: i32,
        process_information: *mut core::ffi::c_void,
        process_information_length: u32,
        return_length: *mut u32,
    ) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn CompareStringOrdinal(
        string1: *const u16,
        count1: i32,
        string2: *const u16,
        count2: i32,
        ignore_case: i32,
    ) -> i32;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObserveError {
    InvalidRequest,
    UnsupportedFile,
    PermissionDenied,
    TargetNotFound,
    SharingViolation,
    Exhausted,
    RuntimeFailed,
}

impl ObserveError {
    pub fn code(self) -> ErrorCode {
        match self {
            Self::InvalidRequest => ErrorCode::InvalidRequest,
            Self::UnsupportedFile => ErrorCode::UnsupportedFile,
            Self::PermissionDenied => ErrorCode::PermissionDenied,
            Self::TargetNotFound => ErrorCode::TargetNotFound,
            Self::SharingViolation | Self::RuntimeFailed => ErrorCode::RuntimeFailed,
            Self::Exhausted => ErrorCode::ResourceExhausted,
        }
    }
}

pub struct ObservedRoot {
    pub identity: RootIdentity,
    pub actual_path: String,
    pub input_path: String,
    _handles: Vec<OwnedHandle>,
}

/// A request-local view of source bytes. Every included file and traversed
/// directory remains open until the caller finishes the helper request. These
/// handles deny ordinary write/delete opens and are never transferred to the
/// helper.
pub(crate) struct CapturedProjectTree {
    _root: ObservedRoot,
    _directories: Vec<OwnedHandle>,
    pub(crate) files: Vec<CapturedProjectFile>,
}

pub(crate) struct CapturedProjectFile {
    pub(crate) relative: String,
    pub(crate) bytes: Vec<u8>,
    held: OwnedHandle,
    identity: RootIdentity,
    digest: [u8; 32],
}

impl CapturedProjectTree {
    pub(crate) fn verify(&self) -> Result<(), ErrorCode> {
        for file in &self.files {
            let observed = file_identity(file.held.raw()).map_err(ObserveError::code)?;
            if observed != file.identity { return Err(ErrorCode::RootChanged); }
            let current = read_held_bytes(file.held.raw(), file.bytes.len())?;
            if current != file.bytes || Sha256::digest(&current).as_slice() != file.digest {
                return Err(ErrorCode::RootChanged);
            }
        }
        Ok(())
    }
}

/// Capture only caller-approved names. Filtering happens before file bytes
/// are read, so configuration, alternates, and unknown Git metadata cannot
/// enter either the frame or a helper-controlled search path.
pub(crate) fn capture_project_tree(
    path: &str,
    expected_root: &RootIdentity,
    authority: &AllocationAuthority,
    pool: AllocationPool,
    mut include: impl FnMut(&str, bool) -> Result<bool, ErrorCode>,
) -> Result<Option<CapturedProjectTree>, ErrorCode> {
    let root = observe_root(path, authority, pool).map_err(ObserveError::code)?;
    if &root.identity != expected_root { return Err(ErrorCode::RootChanged); }
    let held = root._handles.last().expect("held root").raw();
    let names = held_directory_names(held).map_err(ObserveError::code)?;
    let Some(git_name) = names.iter().find(|name| name.eq_ignore_ascii_case(".git")) else {
        return Ok(None);
    };
    if git_name != ".git" { return Err(ErrorCode::UnsupportedFile); }
    let git = match open_relative_component(held, git_name) {
        Ok(git) => git,
        Err(_) if open_relative_file(held, git_name).is_ok() => return Ok(None),
        Err(error) => return Err(error.code()),
    };
    inspect_directory(git.raw()).map_err(ObserveError::code)?;
    let mut capture = CapturedProjectTree {
        _root: root, _directories: vec![git], files: Vec::new(),
    };
    let mut used = 0usize;
    capture_held_directory(held, "", expected_root, &mut used, &mut include, &mut capture)?;
    capture.verify()?;
    Ok(Some(capture))
}

fn capture_held_directory(
    parent: HANDLE, prefix: &str, root: &RootIdentity, used: &mut usize,
    include: &mut impl FnMut(&str, bool) -> Result<bool, ErrorCode>,
    capture: &mut CapturedProjectTree,
) -> Result<(), ErrorCode> {
    let mut names = held_directory_names(parent).map_err(ObserveError::code)?;
    names.sort();
    if names.windows(2).any(|pair| pair[0].eq_ignore_ascii_case(&pair[1])) {
        return Err(ErrorCode::UnsupportedFile);
    }
    for name in &names {
        let relative = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
        crate::contract::RelativePath::new(relative.clone()).map_err(|_| ErrorCode::UnsupportedFile)?;
        if !prefix.is_empty() && name.eq_ignore_ascii_case(".git") {
            return Err(ErrorCode::UnsupportedFile);
        }
        *used = used.checked_add(relative.len() + std::mem::size_of::<String>())
            .filter(|sum| *sum <= crate::contract::MAX_MESSAGE_BYTES)
            .ok_or(ErrorCode::ResourceExhausted)?;
        if let Ok(directory) = open_relative_component(parent, name) {
            inspect_directory(directory.raw()).map_err(ObserveError::code)?;
            let descend = include(&relative, true)?;
            if descend {
                let held = directory.raw();
                capture._directories.push(directory);
                capture_held_directory(held, &relative, root, used, include, capture)?;
            }
            continue;
        }
        let file = open_relative_file(parent, name).map_err(ObserveError::code)?;
        let info = file_information(file.raw()).map_err(ObserveError::code)?;
        if info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) != 0
            || info.nNumberOfLinks != 1
        { return Err(ErrorCode::UnsupportedFile); }
        let identity = file_identity(file.raw()).map_err(ObserveError::code)?;
        if identity.volume_serial != root.volume_serial { return Err(ErrorCode::UnsupportedFile); }
        if !include(&relative, false)? { continue; }
        let size = ((info.nFileSizeHigh as u64) << 32) | info.nFileSizeLow as u64;
        let size = usize::try_from(size).map_err(|_| ErrorCode::ResourceExhausted)?;
        *used = used.checked_add(size).filter(|sum| *sum <= crate::contract::MAX_MESSAGE_BYTES)
            .ok_or(ErrorCode::ResourceExhausted)?;
        let bytes = read_held_bytes(file.raw(), size)?;
        let after = file_information(file.raw()).map_err(ObserveError::code)?;
        if info.nFileIndexHigh != after.nFileIndexHigh || info.nFileIndexLow != after.nFileIndexLow
            || info.nFileSizeHigh != after.nFileSizeHigh || info.nFileSizeLow != after.nFileSizeLow
            || info.ftLastWriteTime.dwHighDateTime != after.ftLastWriteTime.dwHighDateTime
            || info.ftLastWriteTime.dwLowDateTime != after.ftLastWriteTime.dwLowDateTime
        { return Err(ErrorCode::RootChanged); }
        let digest: [u8; 32] = Sha256::digest(&bytes).into();
        capture.files.push(CapturedProjectFile { relative, bytes, held: file, identity, digest });
    }
    let mut after = held_directory_names(parent).map_err(ObserveError::code)?;
    after.sort();
    if names != after { return Err(ErrorCode::RootChanged); }
    Ok(())
}

fn read_held_bytes(handle: HANDLE, size: usize) -> Result<Vec<u8>, ErrorCode> {
    if unsafe { SetFilePointerEx(handle, 0, null_mut(), FILE_BEGIN) } == 0 {
        return Err(map_last_error().code());
    }
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(size).map_err(|_| ErrorCode::ResourceExhausted)?;
    bytes.resize(size, 0);
    let mut offset = 0;
    while offset < size {
        let mut count = 0u32;
        let chunk = (size - offset).min(64 * 1024);
        if unsafe { ReadFile(handle, bytes[offset..].as_mut_ptr(), chunk as u32, &mut count, null_mut()) } == 0 {
            return Err(map_last_error().code());
        }
        if count == 0 { return Err(ErrorCode::RootChanged); }
        offset += count as usize;
    }
    let mut extra = 0u8;
    let mut count = 0u32;
    if unsafe { ReadFile(handle, &mut extra, 1, &mut count, null_mut()) } == 0 {
        return Err(map_last_error().code());
    }
    if count != 0 { return Err(ErrorCode::RootChanged); }
    Ok(bytes)
}

pub(crate) fn held_directory_names(directory: HANDLE) -> Result<Vec<String>, ObserveError> {
    const STATUS_NO_MORE_FILES: i32 = 0x8000_0006u32 as i32;
    const FILE_DIRECTORY_INFORMATION: i32 = 1;
    let mut names = Vec::new();
    let mut name_budget = 0usize;
    #[repr(align(8))]
    struct Aligned([u8; 64 * 1024]);
    let mut storage = Aligned([0u8; 64 * 1024]);
    let buffer = &mut storage.0;
    let mut restart = 1u8;
    loop {
        let mut io = IoStatusBlock { status: 0, information: 0 };
        let status = unsafe { NtQueryDirectoryFile(
            directory, null_mut(), null(), null(), &mut io,
            buffer.as_mut_ptr().cast(), buffer.len() as u32,
            FILE_DIRECTORY_INFORMATION, 0, null(), restart,
        ) };
        restart = 0;
        if status == STATUS_NO_MORE_FILES { break; }
        if status < 0 { return Err(map_ntstatus(status)); }
        let limit = io.information.min(buffer.len());
        let mut offset = 0usize;
        loop {
            if offset.checked_add(64).is_none_or(|end| end > limit) { return Err(ObserveError::UnsupportedFile); }
            let next = u32::from_le_bytes(buffer[offset..offset + 4].try_into().unwrap()) as usize;
            let name_len = u32::from_le_bytes(buffer[offset + 60..offset + 64].try_into().unwrap()) as usize;
            if name_len == 0 || name_len % 2 != 0 || offset + 64 + name_len > limit {
                return Err(ObserveError::UnsupportedFile);
            }
            let units: Vec<u16> = buffer[offset + 64..offset + 64 + name_len]
                .chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
            let name = String::from_utf16(&units).map_err(|_| ObserveError::UnsupportedFile)?;
            if name != "." && name != ".." {
                name_budget = name_budget.checked_add(name.len().saturating_add(std::mem::size_of::<String>()))
                    .filter(|n| *n <= crate::contract::MAX_MESSAGE_BYTES)
                    .ok_or(ObserveError::Exhausted)?;
                names.try_reserve(1).map_err(|_| ObserveError::Exhausted)?;
                names.push(name);
            }
            if next == 0 { break; }
            if next < 64 || offset.checked_add(next).is_none_or(|end| end > limit) {
                return Err(ObserveError::UnsupportedFile);
            }
            offset += next;
        }
    }
    Ok(names)
}

/// Holds the root, each ancestor, and the leaf against replacement while a
/// registration or preview is prepared. No path-based reopen follows validation.
pub struct ObservedFile {
    _root: ObservedRoot,
    _ancestors: Vec<OwnedHandle>,
    leaf: OwnedHandle,
    pub identity: RootIdentity,
    pub size_bytes: u64,
}

impl ObservedFile {
    pub fn read(&self, buffer: &mut [u8]) -> Result<usize, ObserveError> {
        let mut read = 0u32;
        let count = u32::try_from(buffer.len()).map_err(|_| ObserveError::Exhausted)?;
        let ok = unsafe {
            ReadFile(
                self.leaf.raw(),
                buffer.as_mut_ptr(),
                count,
                &mut read,
                null_mut(),
            )
        };
        if ok == 0 { Err(map_last_error()) } else { Ok(read as usize) }
    }
}

pub fn observe_project_file(
    path: &str,
    expected_root: &RootIdentity,
    relative_path: &str,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ObservedFile, ErrorCode> {
    // The wire type validates syntax, but this is a second service boundary.
    crate::contract::RelativePath::new(relative_path.to_owned())
        .map_err(|_| ErrorCode::InvalidRequest)?;
    let root = observe_root(path, authority, pool).map_err(ObserveError::code)?;
    if &root.identity != expected_root {
        return Err(ErrorCode::RootChanged);
    }
    let mut ancestors = Vec::new();
    let mut parent = root._handles.last().expect("observed root handle").raw();
    let mut segments = relative_path.split('/').peekable();
    while let Some(segment) = segments.next() {
        if segments.peek().is_none() {
            let leaf = open_relative_file(parent, segment).map_err(ObserveError::code)?;
            let info = file_information(leaf.raw()).map_err(ObserveError::code)?;
            if info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) != 0
                || info.nNumberOfLinks != 1
            {
                return Err(ErrorCode::UnsupportedFile);
            }
            let identity = file_identity(leaf.raw()).map_err(ObserveError::code)?;
            if identity.volume_serial != root.identity.volume_serial {
                return Err(ErrorCode::UnsupportedFile);
            }
            return Ok(ObservedFile {
                _root: root,
                _ancestors: ancestors,
                leaf,
                identity,
                size_bytes: (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow),
            });
        }
        let child = open_relative_component(parent, segment).map_err(ObserveError::code)?;
        inspect_directory(child.raw()).map_err(ObserveError::code)?;
        parent = child.raw();
        ancestors.push(child);
    }
    Err(ErrorCode::InvalidRequest)
}

struct ParsedPath {
    drive: u8,
    components: Vec<String>,
    original: String,
}

pub fn classify_path_syntax(path: &str) -> Result<(), ObserveError> {
    parse_drive_absolute(path).map(|_| ())
}

pub fn short_path_name(path: &str) -> Option<String> {
    let utf16: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let mut out = vec![0u16; 512];
    let written = unsafe { GetShortPathNameW(utf16.as_ptr(), out.as_mut_ptr(), out.len() as u32) };
    if written == 0 || written as usize >= out.len() {
        return None;
    }
    let end = out.iter().position(|unit| *unit == 0).unwrap_or(written as usize);
    let short = String::from_utf16(&out[..end]).ok()?;
    if short.eq_ignore_ascii_case(path) || !short.contains('~') {
        None
    } else {
        Some(short)
    }
}

pub struct ExclusiveDirectoryHold {
    _handle: OwnedHandle,
}

pub fn exclusive_directory_hold(path: &str) -> Result<ExclusiveDirectoryHold, ObserveError> {
    let parsed = parse_drive_absolute(path)?;
    let utf16: Vec<u16> = parsed.original.encode_utf16().chain(Some(0)).collect();
    let handle = unsafe {
        CreateFileW(
            utf16.as_ptr(),
            FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE,
            0,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
        )
    };
    Ok(ExclusiveDirectoryHold {
        _handle: owned_handle(handle)?,
    })
}

const PROCESS_CONSOLE_HOST_PROCESS: i32 = 49;

pub fn console_host_pid(process_id: u32) -> Option<u32> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return None;
    }
    let mut info: usize = 0;
    let mut returned = 0u32;
    let status = unsafe {
        NtQueryInformationProcess(
            handle,
            PROCESS_CONSOLE_HOST_PROCESS,
            &mut info as *mut usize as *mut core::ffi::c_void,
            std::mem::size_of::<usize>() as u32,
            &mut returned,
        )
    };
    unsafe {
        CloseHandle(handle);
    }
    if status < 0 || info == 0 {
        return None;
    }
    Some((info & !1) as u32)
}

pub fn generate_console_ctrl_c(process_id: u32) -> bool {
    unsafe {
        let _ = FreeConsole();
        if AttachConsole(process_id) == 0 {
            return false;
        }
        let _ = SetConsoleCtrlHandler(None, 1);
        let ok = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) != 0;
        let _ = SetConsoleCtrlHandler(None, 0);
        let _ = FreeConsole();
        ok
    }
}

fn terminate_pid(process_id: u32) -> bool {
    let handle = unsafe { OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return false;
    }
    let ok = unsafe { TerminateProcess(handle, 1) } != 0;
    unsafe {
        CloseHandle(handle);
    }
    ok
}

pub fn stop_owned_process_tree(root: u32) {
    let _ = generate_console_ctrl_c(root);
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot.is_null() || snapshot == INVALID_HANDLE_VALUE {
        let _ = terminate_pid(root);
        return;
    }
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        cntUsage: 0,
        th32ProcessID: 0,
        th32DefaultHeapID: 0,
        th32ModuleID: 0,
        cntThreads: 0,
        th32ParentProcessID: 0,
        pcPriClassBase: 0,
        dwFlags: 0,
        szExeFile: [0; 260],
    };
    let mut children = Vec::new();
    unsafe {
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                if entry.th32ParentProcessID == root {
                    children.push(entry.th32ProcessID);
                }
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snapshot);
    }
    for child in children {
        let _ = generate_console_ctrl_c(child);
        let _ = terminate_pid(child);
    }
    let _ = terminate_pid(root);
}

#[cfg(debug_assertions)]
#[derive(Clone)]
pub struct ObserveHold {
    prefix: String,
    entered: Arc<(Mutex<bool>, Condvar)>,
    release: Arc<(Mutex<bool>, Condvar)>,
}

#[cfg(debug_assertions)]
static OBSERVE_HOLD: Mutex<Vec<ObserveHold>> = Mutex::new(Vec::new());

#[cfg(debug_assertions)]
impl ObserveHold {
    pub fn install(prefix: impl AsRef<str>) -> Self {
        let hold = Self {
            prefix: prefix.as_ref().to_owned(),
            entered: Arc::new((Mutex::new(false), Condvar::new())),
            release: Arc::new((Mutex::new(false), Condvar::new())),
        };
        OBSERVE_HOLD
            .lock()
            .expect("observe hold")
            .push(hold.clone());
        hold
    }

    pub fn wait_entered(&self) {
        let (lock, cvar) = &*self.entered;
        let mut entered = lock.lock().expect("entered");
        let deadline = Instant::now() + Duration::from_secs(15);
        while !*entered {
            let now = Instant::now();
            if now >= deadline {
                panic!("observe hold did not enter");
            }
            let (guard, timed) = cvar
                .wait_timeout(entered, deadline.saturating_duration_since(now))
                .expect("entered wait");
            entered = guard;
            if timed.timed_out() && !*entered {
                panic!("observe hold did not enter");
            }
        }
    }

    pub fn release_waiters(&self) {
        let (lock, cvar) = &*self.release;
        *lock.lock().expect("release") = true;
        cvar.notify_all();
    }

    pub fn clear(&self) {
        let mut holds = OBSERVE_HOLD.lock().expect("observe hold");
        holds.retain(|hold| !Arc::ptr_eq(&hold.entered, &self.entered));
    }
}

#[cfg(debug_assertions)]
fn path_matches_hold(path: &str, prefix: &str) -> bool {
    let normalize = |value: &str| {
        value
            .replace('/', "\\")
            .trim_end_matches('\\')
            .to_owned()
    };
    let path = normalize(path);
    let prefix = normalize(prefix);
    path == prefix
        || path.starts_with(&format!("{prefix}\\"))
        || paths_are_windows_aliases(&path, &prefix)
}

#[cfg(debug_assertions)]
fn wait_installed_observe_hold(path: &str) {
    let hold = OBSERVE_HOLD.lock().ok().and_then(|guard| {
        guard
            .iter()
            .find(|hold| path_matches_hold(path, &hold.prefix))
            .cloned()
    });
    let Some(hold) = hold else {
        return;
    };
    {
        let (lock, cvar) = &*hold.entered;
        *lock.lock().expect("entered") = true;
        cvar.notify_all();
    }
    let (lock, cvar) = &*hold.release;
    let mut released = lock.lock().expect("release");
    let deadline = Instant::now() + Duration::from_secs(15);
    while !*released {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let (guard, timed) = cvar
            .wait_timeout(released, deadline.saturating_duration_since(now))
            .expect("release wait");
        released = guard;
        if timed.timed_out() {
            break;
        }
    }
}

pub fn observe_root(
    path: &str,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ObservedRoot, ObserveError> {
    let parsed = parse_drive_absolute(path)?;
    let mut handles = Vec::new();
    let root = open_drive_root(parsed.drive)?;
    inspect_directory(root.raw())?;
    confirm_fixed_local_volume(parsed.drive, root.raw())?;
    handles.push(root);
    for component in &parsed.components {
        let child = open_relative_component(handles.last().expect("parent handle").raw(), component)?;
        inspect_directory(child.raw())?;
        handles.push(child);
    }
    #[cfg(debug_assertions)]
    wait_installed_observe_hold(path);
    let leaf = handles.last().expect("leaf handle").raw();
    let identity = file_identity(leaf)?;
    let actual_path = final_path(leaf, authority, pool)?;
    Ok(ObservedRoot {
        identity,
        actual_path,
        input_path: parsed.original,
        _handles: handles,
    })
}

pub fn reobserve_state(
    path: &str,
    expected: &RootIdentity,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> RootState {
    match observe_root(path, authority, pool) {
        Ok(observed) => {
            if observed.identity == *expected {
                RootState::Verified
            } else {
                RootState::Changed
            }
        }
        Err(ObserveError::TargetNotFound) => RootState::Unavailable,
        Err(_) => RootState::Unknown,
    }
}

pub fn paths_are_windows_aliases(left: &str, right: &str) -> bool {
    let left = alias_utf16(left);
    let right = alias_utf16(right);
    unsafe {
        CompareStringOrdinal(
            left.as_ptr(),
            left.len() as i32,
            right.as_ptr(),
            right.len() as i32,
            1,
        ) == CSTR_EQUAL
    }
}

fn parse_drive_absolute(path: &str) -> Result<ParsedPath, ObserveError> {
    if path.is_empty() || path.contains('\0') || path.contains('\u{FFFD}') {
        return Err(ObserveError::InvalidRequest);
    }
    if path.starts_with(r"\\.\")
        || path.starts_with("//./")
        || path.starts_with(r"\\?\UNC\")
        || path.starts_with("//?/UNC/")
        || path.eq_ignore_ascii_case("NUL")
    {
        return Err(ObserveError::InvalidRequest);
    }
    let verbatim = path.starts_with(r"\\?\") || path.starts_with("//?/");
    if !verbatim && (path.starts_with(r"\\") || path.starts_with("//")) {
        return Err(ObserveError::InvalidRequest);
    }
    let rest = if verbatim { &path[4..] } else { path };
    let bytes = rest.as_bytes();
    if bytes.len() < 3
        || !bytes[0].is_ascii_alphabetic()
        || bytes[1] != b':'
        || (bytes[2] != b'\\' && bytes[2] != b'/')
    {
        return Err(ObserveError::InvalidRequest);
    }
    let drive = bytes[0].to_ascii_uppercase();
    let mut components = Vec::new();
    for component in rest[2..].split(|ch| ch == '/' || ch == '\\') {
        if component.is_empty() {
            continue;
        }
        if component == "." || component == ".." || component.contains(':') {
            return Err(ObserveError::InvalidRequest);
        }
        if component.ends_with('.') || component.ends_with(' ') {
            return Err(ObserveError::InvalidRequest);
        }
        if dos_reserved(component) {
            return Err(ObserveError::InvalidRequest);
        }
        components.push(component.to_owned());
    }
    Ok(ParsedPath {
        drive,
        components,
        original: path.to_owned(),
    })
}

fn dos_reserved(component: &str) -> bool {
    let base = component.split('.').next().unwrap_or(component);
    ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        .iter()
        .any(|name| base.eq_ignore_ascii_case(name))
        || ["COM", "LPT"].iter().any(|prefix| {
            base.get(..3)
                .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
                && base.get(3..).is_some_and(|n| {
                    matches!(
                        n,
                        "1" | "2"
                            | "3"
                            | "4"
                            | "5"
                            | "6"
                            | "7"
                            | "8"
                            | "9"
                            | "¹"
                            | "²"
                            | "³"
                    )
                })
        })
}

fn alias_utf16(path: &str) -> Vec<u16> {
    let stripped = path
        .strip_prefix(r"\\?\")
        .or_else(|| path.strip_prefix("//?/"))
        .unwrap_or(path);
    let mut normalized = stripped.replace('/', "\\");
    let bytes = normalized.as_bytes();
    if bytes.len() >= 3 && bytes[1] == b':' {
        if let Some(first) = normalized.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
    }
    while normalized.len() > 3 && normalized.ends_with('\\') {
        normalized.pop();
    }
    normalized.encode_utf16().collect()
}

fn open_drive_root(drive: u8) -> Result<OwnedHandle, ObserveError> {
    let path = format!(r"\\?\{}:\", drive as char);
    let utf16: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let handle = unsafe {
        CreateFileW(
            utf16.as_ptr(),
            FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE,
            FILE_SHARE_READ,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
        )
    };
    owned_handle(handle)
}

fn confirm_fixed_local_volume(drive: u8, root: HANDLE) -> Result<(), ObserveError> {
    let mut root_path: Vec<u16> = format!("{}:\\", drive as char)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let drive_type = unsafe { GetDriveTypeW(root_path.as_mut_ptr()) };
    if drive_type != DRIVE_FIXED {
        return Err(ObserveError::UnsupportedFile);
    }
    let mut device: Vec<u16> = format!("{}:", drive as char)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut target = vec![0u16; 1024];
    let written = unsafe { QueryDosDeviceW(device.as_mut_ptr(), target.as_mut_ptr(), target.len() as u32) };
    if written == 0 {
        return Err(ObserveError::UnsupportedFile);
    }
    let end = target.iter().position(|unit| *unit == 0).unwrap_or(target.len());
    let text = String::from_utf16(&target[..end]).map_err(|_| ObserveError::UnsupportedFile)?;
    if text.starts_with(r"\??\") {
        return Err(ObserveError::UnsupportedFile);
    }
    let _ = root;
    Ok(())
}

fn open_relative_component(parent: HANDLE, component: &str) -> Result<OwnedHandle, ObserveError> {
    open_relative(parent, component, true)
}

fn open_relative_file(parent: HANDLE, component: &str) -> Result<OwnedHandle, ObserveError> {
    open_relative(parent, component, false)
}

fn open_relative(parent: HANDLE, component: &str, directory: bool) -> Result<OwnedHandle, ObserveError> {
    let access = FILE_READ_ATTRIBUTES
        | (if directory { FILE_LIST_DIRECTORY } else { FILE_READ_DATA })
        | SYNCHRONIZE;
    let options = (if directory { FILE_DIRECTORY_FILE } else { FILE_NON_DIRECTORY_FILE })
        | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT;
    open_relative_with_access(parent, component, access, options)
}

fn open_relative_with_access(
    parent: HANDLE, component: &str, access: u32, options: u32,
) -> Result<OwnedHandle, ObserveError> {
    let name: Vec<u16> = component.encode_utf16().chain(Some(0)).collect();
    let byte_len = (name.len() - 1)
        .checked_mul(2)
        .ok_or(ObserveError::InvalidRequest)?;
    if byte_len > u16::MAX as usize {
        return Err(ObserveError::InvalidRequest);
    }
    let unicode = UnicodeString {
        length: byte_len as u16,
        maximum_length: (byte_len + 2) as u16,
        buffer: name.as_ptr(),
    };
    let attributes = ObjectAttributes {
        length: std::mem::size_of::<ObjectAttributes>() as u32,
        root_directory: parent,
        object_name: &unicode,
        attributes: OBJ_CASE_INSENSITIVE,
        security_descriptor: null(),
        security_quality_of_service: null(),
    };
    let mut handle: HANDLE = INVALID_HANDLE_VALUE;
    let mut io = IoStatusBlock {
        status: 0,
        information: 0,
    };
    let status = unsafe {
        NtCreateFile(
            &mut handle,
            access,
            &attributes,
            &mut io,
            null(),
            0,
            FILE_SHARE_READ,
            FILE_OPEN,
            options,
            null(),
            0,
        )
    };
    if status < 0 {
        return Err(map_ntstatus(status));
    }
    owned_handle(handle)
}

fn file_information(handle: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION, ObserveError> {
    let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
    if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 {
        Err(map_last_error())
    } else {
        Ok(info)
    }
}

fn inspect_directory(handle: HANDLE) -> Result<(), ObserveError> {
    let mut info = BY_HANDLE_FILE_INFORMATION {
        dwFileAttributes: 0,
        ftCreationTime: windows_sys::Win32::Foundation::FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        },
        ftLastAccessTime: windows_sys::Win32::Foundation::FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        },
        ftLastWriteTime: windows_sys::Win32::Foundation::FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        },
        dwVolumeSerialNumber: 0,
        nFileSizeHigh: 0,
        nFileSizeLow: 0,
        nNumberOfLinks: 0,
        nFileIndexHigh: 0,
        nFileIndexLow: 0,
    };
    let ok = unsafe { GetFileInformationByHandle(handle, &mut info) };
    if ok == 0 {
        return Err(map_last_error());
    }
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(ObserveError::UnsupportedFile);
    }
    if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(ObserveError::UnsupportedFile);
    }
    let mut case_info = FileCaseSensitiveInfo { flags: 0 };
    let case_ok = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FILE_CASE_SENSITIVE_INFO,
            &mut case_info as *mut FileCaseSensitiveInfo as *mut core::ffi::c_void,
            std::mem::size_of::<FileCaseSensitiveInfo>() as u32,
        )
    };
    if case_ok == 0 {
        return Err(ObserveError::UnsupportedFile);
    }
    if case_info.flags & FILE_CS_FLAG_CASE_SENSITIVE_DIR != 0 {
        return Err(ObserveError::UnsupportedFile);
    }
    Ok(())
}

fn file_identity(handle: HANDLE) -> Result<RootIdentity, ObserveError> {
    let mut info = FILE_ID_INFO {
        VolumeSerialNumber: 0,
        FileId: windows_sys::Win32::Storage::FileSystem::FILE_ID_128 { Identifier: [0; 16] },
    };
    let ok = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            &mut info as *mut FILE_ID_INFO as *mut core::ffi::c_void,
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
    };
    if ok == 0 {
        return Err(map_last_error());
    }
    Ok(RootIdentity {
        volume_serial: Hex16::new(hex_encode(&info.VolumeSerialNumber.to_le_bytes()))
            .map_err(|_| ObserveError::RuntimeFailed)?,
        file_id: Hex32::new(hex_encode(&info.FileId.Identifier))
            .map_err(|_| ObserveError::RuntimeFailed)?,
    })
}

fn final_path(
    handle: HANDLE,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<String, ObserveError> {
    let mut units = ChargedVec::<u16>::with_capacity(authority, pool, 1024, 1024 * 2)
        .map_err(|_| ObserveError::Exhausted)?;
    units
        .try_resize(1024, 0)
        .map_err(|_| ObserveError::Exhausted)?;
    let needed = unsafe { GetFinalPathNameByHandleW(handle, units.as_mut_ptr(), units.len() as u32, 0) };
    if needed == 0 {
        return Err(map_last_error());
    }
    if needed as usize >= units.len() {
        let count = needed as usize + 1;
        let bytes = count
            .checked_mul(2)
            .ok_or(ObserveError::Exhausted)?;
        units = ChargedVec::<u16>::with_capacity(authority, pool, count, bytes)
            .map_err(|_| ObserveError::Exhausted)?;
        units
            .try_resize(count, 0)
            .map_err(|_| ObserveError::Exhausted)?;
        let written =
            unsafe { GetFinalPathNameByHandleW(handle, units.as_mut_ptr(), units.len() as u32, 0) };
        if written == 0 || written as usize >= units.len() {
            return Err(map_last_error());
        }
    }
    let end = units.iter().position(|unit| *unit == 0).unwrap_or(units.len());
    String::from_utf16(&units[..end]).map_err(|_| ObserveError::UnsupportedFile)
}

fn owned_handle(handle: HANDLE) -> Result<OwnedHandle, ObserveError> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(map_last_error());
    }
    unsafe { OwnedHandle::from_raw(handle) }.map_err(|_| map_last_error())
}

fn map_last_error() -> ObserveError {
    match unsafe { GetLastError() } {
        ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => ObserveError::TargetNotFound,
        ERROR_ACCESS_DENIED => ObserveError::PermissionDenied,
        ERROR_SHARING_VIOLATION => ObserveError::SharingViolation,
        _ => ObserveError::RuntimeFailed,
    }
}

fn map_ntstatus(status: i32) -> ObserveError {
    const STATUS_OBJECT_NAME_NOT_FOUND: i32 = -1073741772;
    const STATUS_OBJECT_PATH_NOT_FOUND: i32 = -1073741771;
    const STATUS_ACCESS_DENIED: i32 = -1073741790;
    const STATUS_SHARING_VIOLATION: i32 = -1073741757;
    const STATUS_NOT_A_DIRECTORY: i32 = -1073741633;
    const STATUS_FILE_IS_A_DIRECTORY: i32 = -1073741638;
    match status {
        STATUS_OBJECT_NAME_NOT_FOUND | STATUS_OBJECT_PATH_NOT_FOUND => ObserveError::TargetNotFound,
        STATUS_ACCESS_DENIED => ObserveError::PermissionDenied,
        STATUS_SHARING_VIOLATION => ObserveError::SharingViolation,
        STATUS_NOT_A_DIRECTORY | STATUS_FILE_IS_A_DIRECTORY => ObserveError::UnsupportedFile,
        _ => ObserveError::RuntimeFailed,
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

impl From<AllocationError> for ObserveError {
    fn from(_: AllocationError) -> Self {
        Self::Exhausted
    }
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone)]
pub struct VolumeProbe {
    pub letter: char,
    pub drive_type: u32,
    pub dos_device: Option<String>,
    pub dos_device_gle: u32,
    pub subst: bool,
    pub fixed: bool,
}

#[cfg(debug_assertions)]
pub fn testing_probe_volumes() -> [VolumeProbe; 26] {
    core::array::from_fn(|index| {
        let letter = (b'A' + index as u8) as char;
        let mut root_path: Vec<u16> = format!("{letter}:\\").encode_utf16().chain(Some(0)).collect();
        let drive_type = unsafe { GetDriveTypeW(root_path.as_mut_ptr()) };
        let mut device: Vec<u16> = format!("{letter}:").encode_utf16().chain(Some(0)).collect();
        let mut target = vec![0u16; 1024];
        let written =
            unsafe { QueryDosDeviceW(device.as_mut_ptr(), target.as_mut_ptr(), target.len() as u32) };
        let dos_device_gle = if written == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        let dos_device = if written == 0 {
            None
        } else {
            let end = target
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(written as usize);
            String::from_utf16(&target[..end]).ok()
        };
        let subst = dos_device
            .as_deref()
            .is_some_and(|text| text.starts_with(r"\??\"));
        VolumeProbe {
            letter,
            drive_type,
            dos_device,
            dos_device_gle,
            subst,
            fixed: drive_type == DRIVE_FIXED && !subst,
        }
    })
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone, Copy)]
pub struct WideCreateReceipt {
    pub created: bool,
    pub last_error: u32,
}

#[cfg(debug_assertions)]
pub fn testing_create_unpaired_surrogate_directory(parent: &str) -> (Vec<u16>, WideCreateReceipt) {
    let mut wide: Vec<u16> = parent.encode_utf16().collect();
    if wide.last().is_none_or(|unit| *unit != b'\\' as u16 && *unit != b'/' as u16) {
        wide.push(b'\\' as u16);
    }
    wide.push(0xD800);
    wide.push(0);
    let created = unsafe { CreateDirectoryW(wide.as_ptr(), null()) } != 0;
    let last_error = if created {
        0
    } else {
        unsafe { GetLastError() }
    };
    (
        wide,
        WideCreateReceipt {
            created,
            last_error,
        },
    )
}

#[cfg(debug_assertions)]
pub fn testing_remove_wide_directory(path: &[u16]) -> (bool, u32) {
    let mut terminated = Vec::with_capacity(path.len() + 1);
    terminated.extend_from_slice(path);
    if terminated.last() != Some(&0) {
        terminated.push(0);
    }
    let removed = unsafe { RemoveDirectoryW(terminated.as_ptr()) } != 0;
    let last_error = if removed {
        0
    } else {
        unsafe { GetLastError() }
    };
    (removed, last_error)
}

#[cfg(debug_assertions)]
pub fn testing_os_utf16_final_path(
    wide: &[u16],
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<String, ObserveError> {
    let mut terminated = Vec::with_capacity(wide.len() + 1);
    terminated.extend_from_slice(wide);
    if terminated.last() != Some(&0) {
        terminated.push(0);
    }
    let handle = unsafe {
        CreateFileW(
            terminated.as_ptr(),
            FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE,
            FILE_SHARE_READ,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
        )
    };
    let owned = owned_handle(handle)?;
    final_path(owned.raw(), authority, pool)
}
