use crate::desktop_backend::{
    handle_desktop_json_rpc, DesktopCommandTransport, DesktopCompareRunsResult,
    DesktopExplainPayload, DesktopJsonRpcRequest, DesktopPickWinnerResult,
    DesktopPromoteTacticResult, DesktopSummarySnapshot, DesktopVoiceCaptureStatus,
    PwshScriptTransport,
};
use crate::desktop_control_plane_params::{
    DesktopRunCompareParams, DesktopRunExplainParams, DesktopRunPickWinnerParams,
    DesktopRunPromoteParams, DesktopSummarySnapshotParams, DesktopVoiceCaptureStatusParams,
};
use crate::desktop_provider_capabilities::{
    DesktopProviderCapabilitiesParams, DesktopProviderCapabilitiesSnapshot,
};
use crate::pty_backend::{
    handle_pty_json_rpc, OperatorSnapshotParams, OperatorSubmitParams, OperatorSubmitResult,
    PtyCaptureParams, PtyCaptureResult, PtyCloseParams, PtyCommandTransport, PtyJsonRpcRequest,
    PtyPaneResult, PtyResizeParams, PtyRespawnParams, PtySpawnParams, PtyWriteParams,
    OPERATOR_CONTROL_PIPE_METHODS, PTY_CONTROL_PIPE_METHODS,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const WINSMUX_CONTROL_PIPE_NAME: &str = r"\\.\pipe\winsmux-control";
pub const WINSMUX_CONTROL_PIPE_TOKEN_ENV: &str = "WINSMUX_CONTROL_PIPE_TOKEN";
pub const WINSMUX_CONTROL_PIPE_TOKEN_FILE_TEMPLATE: &str =
    r"%LOCALAPPDATA%\winsmux\control-pipe\token";
const CONTROL_PIPE_TOKEN_ROTATED_MARKER: &str = "control-pipe token: rotated";
const CONTROL_PIPE_TOKEN_REVOKED_MARKER: &str = "control-pipe token: revoked";
const CONTROL_PIPE_TOKEN_REVOKE_FAILED_MARKER: &str = "control-pipe token: revoke failed";
const PREVIOUS_TOKEN_TTL: Duration = Duration::from_secs(60);
const CONTROL_PIPE_TOKEN_RANDOM_BYTES: usize = 32;

struct ControlPipeAuthState {
    current: String,
    previous: Option<String>,
    previous_deadline: Instant,
}

static CONTROL_PIPE_AUTH_STATE: Mutex<Option<ControlPipeAuthState>> = Mutex::new(None);
static CONTROL_PIPE_SERVER_INTENDED: AtomicBool = AtomicBool::new(false);

fn control_pipe_auth_state_lock() -> std::sync::MutexGuard<'static, Option<ControlPipeAuthState>> {
    CONTROL_PIPE_AUTH_STATE
        .lock()
        .unwrap_or_else(|err| err.into_inner())
}

fn reset_control_pipe_auth_state() {
    *control_pipe_auth_state_lock() = None;
}

fn control_pipe_token_file_path() -> Option<PathBuf> {
    let local_app_data = std::env::var_os("LOCALAPPDATA")?;
    if local_app_data.is_empty() {
        return None;
    }
    Some(
        PathBuf::from(local_app_data)
            .join("winsmux")
            .join("control-pipe")
            .join("token"),
    )
}

fn process_env_control_pipe_token() -> Option<String> {
    match std::env::var(WINSMUX_CONTROL_PIPE_TOKEN_ENV) {
        Ok(value) if !value.trim().is_empty() => Some(value),
        _ => None,
    }
}

fn read_control_pipe_token_file() -> Option<String> {
    let path = control_pipe_token_file_path()?;
    let contents = fs::read_to_string(path).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub fn control_pipe_auth_is_available() -> bool {
    process_env_control_pipe_token().is_some() || read_control_pipe_token_file().is_some()
}

pub fn control_pipe_ui_is_enabled() -> bool {
    control_pipe_auth_is_available() || CONTROL_PIPE_SERVER_INTENDED.load(Ordering::SeqCst)
}

#[cfg(any(windows, test))]
fn mark_control_pipe_server_intended() {
    CONTROL_PIPE_SERVER_INTENDED.store(true, Ordering::SeqCst);
}

#[cfg(test)]
fn reset_control_pipe_server_intended() {
    CONTROL_PIPE_SERVER_INTENDED.store(false, Ordering::SeqCst);
}

fn generate_control_pipe_token() -> Result<String, String> {
    let mut bytes = [0u8; CONTROL_PIPE_TOKEN_RANDOM_BYTES];
    fill_random_bytes(&mut bytes)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(windows)]
fn fill_random_bytes(bytes: &mut [u8]) -> Result<(), String> {
    const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x0000_0002;
    #[link(name = "bcrypt")]
    extern "system" {
        fn BCryptGenRandom(
            h_algorithm: *mut core::ffi::c_void,
            pb_buffer: *mut u8,
            cb_buffer: u32,
            dw_flags: u32,
        ) -> i32;
    }
    let status = unsafe {
        BCryptGenRandom(
            core::ptr::null_mut(),
            bytes.as_mut_ptr(),
            bytes.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err("control-pipe token rotate failed".to_string())
    }
}

#[cfg(not(windows))]
fn fill_random_bytes(bytes: &mut [u8]) -> Result<(), String> {
    use std::io::Read;
    fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(bytes))
        .map_err(|_| "control-pipe token rotate failed".to_string())
}

fn write_control_pipe_token_file(path: &Path, token: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "control-pipe token rotate failed".to_string())?;
    fs::create_dir_all(parent).map_err(|_| "control-pipe token rotate failed".to_string())?;
    #[cfg(windows)]
    {
        write_control_pipe_token_file_windows(path, parent, token)
    }
    #[cfg(not(windows))]
    {
        fs::write(path, token.as_bytes())
            .map_err(|_| "control-pipe token rotate failed".to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }
}

fn existing_token_file_is_trusted(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(windows)]
    {
        control_pipe_token_file_dacl_is_user_only(path).unwrap_or(false)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o777 == 0o600)
            .unwrap_or(false)
    }
    #[cfg(not(any(windows, unix)))]
    {
        false
    }
}

fn read_trusted_previous_control_pipe_token() -> Option<String> {
    let path = control_pipe_token_file_path()?;
    read_trusted_previous_token_at_path(&path)
}

fn read_trusted_previous_token_at_path(path: &Path) -> Option<String> {
    #[cfg(windows)]
    {
        read_trusted_previous_token_windows(path)
    }
    #[cfg(unix)]
    {
        read_trusted_previous_token_unix(path)
    }
    #[cfg(not(any(windows, unix)))]
    {
        let _ = path;
        None
    }
}

#[cfg(unix)]
fn read_trusted_previous_token_unix(path: &Path) -> Option<String> {
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;

    let mut file = fs::File::open(path).ok()?;
    let mode = file.metadata().ok()?.permissions().mode() & 0o777;
    if mode != 0o600 {
        return None;
    }
    let mut contents = String::new();
    file.read_to_string(&mut contents).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn bootstrap_control_pipe_token() -> Result<(), String> {
    let path = control_pipe_token_file_path()
        .ok_or_else(|| "control-pipe token rotate failed".to_string())?;
    let previous = read_trusted_previous_control_pipe_token();
    let current = generate_control_pipe_token()?;
    write_control_pipe_token_file(&path, &current)?;
    *control_pipe_auth_state_lock() = Some(ControlPipeAuthState {
        current,
        previous,
        previous_deadline: Instant::now() + PREVIOUS_TOKEN_TTL,
    });
    eprintln!("{CONTROL_PIPE_TOKEN_ROTATED_MARKER}");
    Ok(())
}

pub fn revoke_control_pipe_token_on_exit() {
    let mut guard = control_pipe_auth_state_lock();
    if guard.is_none() {
        return;
    }
    // Unlink first while this process still owns Some-state. Clearing the lock
    // before remove_file would fall through to the untrusted file-token read.
    let unlink_ok = match control_pipe_token_file_path() {
        Some(path) => match fs::remove_file(&path) {
            Ok(()) => true,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => true,
            Err(_) => false,
        },
        None => false,
    };
    *guard = None;
    if unlink_ok {
        eprintln!("{CONTROL_PIPE_TOKEN_REVOKED_MARKER}");
    } else {
        eprintln!("{CONTROL_PIPE_TOKEN_REVOKE_FAILED_MARKER}");
    }
}

fn bootstrap_control_pipe_token_after_exclusive_pipe(
    already_bootstrapped: &mut bool,
) -> Result<(), String> {
    if *already_bootstrapped {
        return Ok(());
    }
    if process_env_control_pipe_token().is_some() {
        *already_bootstrapped = true;
        return Ok(());
    }
    bootstrap_control_pipe_token()?;
    *already_bootstrapped = true;
    Ok(())
}

fn authorize_rotated_or_file_token(provided: &str) -> bool {
    let mut guard = control_pipe_auth_state_lock();
    if let Some(state) = guard.as_mut() {
        if constant_time_string_eq(provided.as_bytes(), state.current.as_bytes()) {
            state.previous = None;
            return true;
        }
        if state.previous.is_some() && Instant::now() >= state.previous_deadline {
            state.previous = None;
            return false;
        }
        if let Some(previous) = state.previous.as_ref() {
            return constant_time_string_eq(provided.as_bytes(), previous.as_bytes());
        }
        return false;
    }
    drop(guard);
    match read_trusted_previous_control_pipe_token() {
        Some(file_token) => constant_time_string_eq(provided.as_bytes(), file_token.as_bytes()),
        None => false,
    }
}

#[cfg(windows)]
fn path_to_wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

#[cfg(windows)]
fn local_free_ptr(ptr: *mut core::ffi::c_void) {
    use windows_sys::Win32::Foundation::LocalFree;
    if !ptr.is_null() {
        unsafe {
            LocalFree(ptr);
        }
    }
}

#[cfg(windows)]
fn open_control_pipe_token_read_handle(
    path: &Path,
) -> Result<windows_sys::Win32::Foundation::HANDLE, String> {
    use windows_sys::Win32::Foundation::{GetLastError, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
        OPEN_EXISTING,
    };

    const GENERIC_READ: u32 = 0x8000_0000;
    const READ_CONTROL: u32 = 0x0002_0000;

    let path_wide = path_to_wide(path);
    let handle: HANDLE = unsafe {
        CreateFileW(
            path_wide.as_ptr(),
            GENERIC_READ | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_DELETE,
            core::ptr::null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT,
            core::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        Err(format!(
            "control-pipe token rotate failed ({})",
            unsafe { GetLastError() }
        ))
    } else {
        Ok(handle)
    }
}

#[cfg(windows)]
fn read_control_pipe_token_from_handle(
    handle: windows_sys::Win32::Foundation::HANDLE,
) -> Option<String> {
    use windows_sys::Win32::Storage::FileSystem::ReadFile;

    let mut buffer = vec![0u8; 4096];
    let mut bytes_read = 0u32;
    let ok = unsafe {
        ReadFile(
            handle,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
            &mut bytes_read,
            core::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return None;
    }
    buffer.truncate(bytes_read as usize);
    let contents = std::str::from_utf8(&buffer).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(windows)]
fn read_trusted_previous_token_windows(path: &Path) -> Option<String> {
    use windows_sys::Win32::Foundation::CloseHandle;

    let handle = open_control_pipe_token_read_handle(path).ok()?;
    let trusted = control_pipe_token_handle_dacl_is_user_only(handle).unwrap_or(false);
    let token = if trusted {
        read_control_pipe_token_from_handle(handle)
    } else {
        None
    };
    unsafe {
        CloseHandle(handle);
    }
    token
}

#[cfg(windows)]
fn current_user_sid_string() -> Result<String, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut token: HANDLE = core::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err("control-pipe token rotate failed".to_string());
        }
        let mut required = 0u32;
        GetTokenInformation(token, TokenUser, core::ptr::null_mut(), 0, &mut required);
        if required == 0 {
            CloseHandle(token);
            return Err("control-pipe token rotate failed".to_string());
        }
        let mut buffer = vec![0u8; required as usize];
        if GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            required,
            &mut required,
        ) == 0
        {
            CloseHandle(token);
            return Err("control-pipe token rotate failed".to_string());
        }
        CloseHandle(token);
        let token_user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut sid_string: windows_sys::core::PWSTR = core::ptr::null_mut();
        if ConvertSidToStringSidW(token_user.User.Sid, &mut sid_string) == 0 {
            return Err("control-pipe token rotate failed".to_string());
        }
        let mut len = 0usize;
        while *sid_string.add(len) != 0 {
            len += 1;
        }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(sid_string, len));
        local_free_ptr(sid_string.cast());
        Ok(text)
    }
}

#[cfg(all(windows, test))]
static FORCE_CONTROL_PIPE_DACL_FAILURE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(all(windows, test))]
static FORCE_CONTROL_PIPE_OWNER_MISMATCH: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(all(windows, test))]
static FORCE_CONTROL_PIPE_OBJECT_SD_FAILURE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn user_only_security_descriptor(
) -> Result<windows_sys::Win32::Security::PSECURITY_DESCRIPTOR, String> {
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::PSECURITY_DESCRIPTOR;

    let sid = current_user_sid_string()?;
    // GENERIC_ALL maps for both files and directories. FILE_ALL_ACCESS (FA) on a
    // directory can fail SetNamedSecurityInfoW on GitHub-hosted Windows images.
    let sddl = format!("D:P(A;;GA;;;{sid})");
    let sddl_wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut sd: PSECURITY_DESCRIPTOR = core::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_wide.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            core::ptr::null_mut(),
        ) == 0
            || sd.is_null()
        {
            return Err("control-pipe token rotate failed".to_string());
        }
        Ok(sd)
    }
}

#[cfg(windows)]
fn apply_user_only_dacl(path: &Path) -> Result<(), String> {
    #[cfg(test)]
    if FORCE_CONTROL_PIPE_DACL_FAILURE.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("control-pipe token rotate failed".to_string());
    }
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::Security::Authorization::{SetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        GetSecurityDescriptorDacl, ACL, DACL_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION,
    };

    let sd = user_only_security_descriptor()?;
    let mut path_wide = path_to_wide(path);
    unsafe {
        let mut present: windows_sys::core::BOOL = 0;
        let mut defaulted: windows_sys::core::BOOL = 0;
        let mut dacl: *mut ACL = core::ptr::null_mut();
        if GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaulted) == 0
            || present == 0
        {
            local_free_ptr(sd);
            return Err("control-pipe token rotate failed".to_string());
        }
        let status = SetNamedSecurityInfoW(
            path_wide.as_mut_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            core::ptr::null_mut(),
            core::ptr::null_mut(),
            dacl,
            core::ptr::null_mut(),
        );
        local_free_ptr(sd);
        if status != ERROR_SUCCESS {
            Err(format!("control-pipe token rotate failed ({status})"))
        } else {
            Ok(())
        }
    }
}

#[cfg(windows)]
fn write_control_pipe_token_file_windows(
    path: &Path,
    parent: &Path,
    token: &str,
) -> Result<(), String> {
    apply_user_only_dacl(parent)?;
    let mut last_err = "control-pipe token rotate failed".to_string();
    for _ in 0..8 {
        let mut name_bytes = [0u8; 16];
        fill_random_bytes(&mut name_bytes)?;
        let temp_hex: String = name_bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let temp_name = format!("token.{temp_hex}.tmp");
        let temp_path = parent.join(temp_name);
        match create_user_only_file_with_bytes(&temp_path, token.as_bytes()) {
            Ok(()) => {
                if let Err(err) = replace_file_atomic(&temp_path, path) {
                    let _ = fs::remove_file(&temp_path);
                    return Err(err);
                }
                return Ok(());
            }
            Err(err) if err == "control-pipe token rotate failed (exists)" => {
                last_err = err;
            }
            Err(err) => {
                let _ = fs::remove_file(&temp_path);
                return Err(err);
            }
        }
    }
    Err(last_err)
}

#[cfg(windows)]
fn create_user_only_file_with_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, ERROR_FILE_EXISTS, HANDLE,
        INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FlushFileBuffers, WriteFile, CREATE_NEW, FILE_ATTRIBUTE_NORMAL,
        FILE_FLAG_WRITE_THROUGH,
    };

    const GENERIC_WRITE: u32 = 0x4000_0000;

    let sd = user_only_security_descriptor()?;
    let path_wide = path_to_wide(path);
    unsafe {
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd,
            bInheritHandle: 0,
        };
        let handle: HANDLE = CreateFileW(
            path_wide.as_ptr(),
            GENERIC_WRITE,
            0,
            &sa,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH,
            core::ptr::null_mut(),
        );
        let create_error = GetLastError();
        local_free_ptr(sd);
        if handle == INVALID_HANDLE_VALUE {
            if create_error == ERROR_FILE_EXISTS || create_error == ERROR_ALREADY_EXISTS {
                return Err("control-pipe token rotate failed (exists)".to_string());
            }
            return Err(format!("control-pipe token rotate failed ({create_error})"));
        }
        let mut bytes_written = 0u32;
        let write_ok = WriteFile(
            handle,
            bytes.as_ptr(),
            bytes.len() as u32,
            &mut bytes_written,
            core::ptr::null_mut(),
        );
        if write_ok == 0 || bytes_written as usize != bytes.len() {
            CloseHandle(handle);
            return Err("control-pipe token rotate failed".to_string());
        }
        FlushFileBuffers(handle);
        CloseHandle(handle);
        Ok(())
    }
}

#[cfg(windows)]
fn create_user_only_named_pipe(
    pipe_name: &str,
) -> Result<windows_sys::Win32::Foundation::HANDLE, String> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{GetLastError, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows_sys::Win32::System::Pipes::{
        CreateNamedPipeW, PIPE_READMODE_MESSAGE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE,
        PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    #[cfg(test)]
    if FORCE_CONTROL_PIPE_OBJECT_SD_FAILURE.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("control-pipe object SD failed".to_string());
    }

    let sd = user_only_security_descriptor()
        .map_err(|_| "control-pipe object SD failed".to_string())?;
    if sd.is_null() {
        return Err("control-pipe object SD failed".to_string());
    }

    let name_wide: Vec<u16> = OsStr::new(pipe_name).encode_wide().chain(Some(0)).collect();
    let sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd,
        bInheritHandle: 0,
    };
    if sa.lpSecurityDescriptor.is_null() {
        local_free_ptr(sd);
        return Err("control-pipe object SD failed".to_string());
    }

    let handle: HANDLE = unsafe {
        CreateNamedPipeW(
            name_wide.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            1024 * 1024,
            1024 * 1024,
            0,
            &sa,
        )
    };
    let create_error = unsafe { GetLastError() };
    local_free_ptr(sd);
    if handle == INVALID_HANDLE_VALUE {
        Err(format!("CreateNamedPipeW failed with {create_error}"))
    } else {
        Ok(handle)
    }
}

#[cfg(windows)]
fn replace_file_atomic(from: &Path, to: &Path) -> Result<(), String> {
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let from_wide = path_to_wide(from);
    let to_wide = path_to_wide(to);
    let moved = unsafe {
        MoveFileExW(
            from_wide.as_ptr(),
            to_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(format!("control-pipe token rotate failed ({})", unsafe {
            GetLastError()
        }))
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn owner_sid_matches_current_principal(
    owner: windows_sys::Win32::Security::PSID,
    user_sid: windows_sys::Win32::Security::PSID,
    token_owner_sid: windows_sys::Win32::Security::PSID,
) -> bool {
    use windows_sys::Win32::Security::EqualSid;

    unsafe {
        // TokenOwner is the SID Windows stamps on files this process creates.
        // Elevated tokens often use BUILTIN\Administrators there; that SID can
        // be deny-only, so CheckTokenMembership is not a reliable owner check.
        if !user_sid.is_null() && EqualSid(owner, user_sid) != 0 {
            return true;
        }
        !token_owner_sid.is_null() && EqualSid(owner, token_owner_sid) != 0
    }
}

#[cfg(all(windows, test))]
fn sid_to_string_for_test(sid: windows_sys::Win32::Security::PSID) -> String {
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;

    if sid.is_null() {
        return "null".to_string();
    }
    unsafe {
        let mut text: windows_sys::core::PWSTR = core::ptr::null_mut();
        if ConvertSidToStringSidW(sid, &mut text) == 0 || text.is_null() {
            return "unprintable".to_string();
        }
        let mut len = 0usize;
        while *text.add(len) != 0 {
            len += 1;
        }
        let value = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        local_free_ptr(text.cast());
        value
    }
}

#[cfg(windows)]
fn control_pipe_token_handle_dacl_is_user_only(
    handle: windows_sys::Win32::Foundation::HANDLE,
) -> Result<bool, String> {
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    };

    unsafe {
        let mut owner: PSID = core::ptr::null_mut();
        let mut group: PSID = core::ptr::null_mut();
        let mut dacl: *mut ACL = core::ptr::null_mut();
        let mut sacl: *mut ACL = core::ptr::null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = core::ptr::null_mut();
        let status = GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            &mut group,
            &mut dacl,
            &mut sacl,
            &mut sd,
        );
        if status != ERROR_SUCCESS || dacl.is_null() {
            local_free_ptr(sd);
            return Err("control-pipe token rotate failed".to_string());
        }
        control_pipe_owner_and_dacl_are_user_only(owner, dacl, sd)
    }
}

#[cfg(windows)]
unsafe fn control_pipe_owner_and_dacl_are_user_only(
    owner: windows_sys::Win32::Security::PSID,
    dacl: *mut windows_sys::Win32::Security::ACL,
    sd: windows_sys::Win32::Security::PSECURITY_DESCRIPTOR,
) -> Result<bool, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    #[cfg(test)]
    use windows_sys::Win32::Security::Authorization::ConvertStringSidToSidW;
    use windows_sys::Win32::Security::{
        AclSizeInformation, EqualSid, GetAce, GetAclInformation, GetTokenInformation, TokenOwner,
        TokenUser, ACE_HEADER, ACL_SIZE_INFORMATION, PSID, TOKEN_OWNER, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    if owner.is_null() {
        local_free_ptr(sd);
        return Ok(false);
    }

    let mut token: HANDLE = core::ptr::null_mut();
    if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
        local_free_ptr(sd);
        return Err("control-pipe token rotate failed".to_string());
    }
    let mut required = 0u32;
    GetTokenInformation(token, TokenUser, core::ptr::null_mut(), 0, &mut required);
    if required == 0 {
        CloseHandle(token);
        local_free_ptr(sd);
        return Err("control-pipe token rotate failed".to_string());
    }
    let mut buffer = vec![0u8; required as usize];
    if GetTokenInformation(
        token,
        TokenUser,
        buffer.as_mut_ptr().cast(),
        required,
        &mut required,
    ) == 0
    {
        CloseHandle(token);
        local_free_ptr(sd);
        return Err("control-pipe token rotate failed".to_string());
    }
    let token_user = &*(buffer.as_ptr() as *const TOKEN_USER);
    let mut token_owner_required = 0u32;
    GetTokenInformation(
        token,
        TokenOwner,
        core::ptr::null_mut(),
        0,
        &mut token_owner_required,
    );
    let mut token_owner_buffer = vec![0u8; token_owner_required as usize];
    let token_owner_sid = if token_owner_required > 0
        && GetTokenInformation(
            token,
            TokenOwner,
            token_owner_buffer.as_mut_ptr().cast(),
            token_owner_required,
            &mut token_owner_required,
        ) != 0
    {
        (*(token_owner_buffer.as_ptr() as *const TOKEN_OWNER)).Owner
    } else {
        core::ptr::null_mut()
    };
    let mut owner_matches =
        owner_sid_matches_current_principal(owner, token_user.User.Sid, token_owner_sid);
    #[cfg(test)]
    {
        if FORCE_CONTROL_PIPE_OWNER_MISMATCH.load(std::sync::atomic::Ordering::SeqCst) {
            let everyone: Vec<u16> = "S-1-1-0".encode_utf16().chain(Some(0)).collect();
            let mut everyone_sid: PSID = core::ptr::null_mut();
            if ConvertStringSidToSidW(everyone.as_ptr(), &mut everyone_sid) == 0
                || everyone_sid.is_null()
            {
                CloseHandle(token);
                local_free_ptr(sd);
                return Err("control-pipe token rotate failed".to_string());
            }
            owner_matches = EqualSid(owner, everyone_sid) != 0;
            local_free_ptr(everyone_sid);
        }
    }
    CloseHandle(token);
    if !owner_matches {
        #[cfg(test)]
        eprintln!(
            "control-pipe owner rejected file={} user={} token_owner={}",
            sid_to_string_for_test(owner),
            sid_to_string_for_test(token_user.User.Sid),
            sid_to_string_for_test(token_owner_sid)
        );
        local_free_ptr(sd);
        return Ok(false);
    }

    let mut size_info = ACL_SIZE_INFORMATION {
        AceCount: 0,
        AclBytesInUse: 0,
        AclBytesFree: 0,
    };
    if GetAclInformation(
        dacl,
        std::ptr::addr_of_mut!(size_info).cast(),
        std::mem::size_of::<ACL_SIZE_INFORMATION>() as u32,
        AclSizeInformation,
    ) == 0
    {
        local_free_ptr(sd);
        return Err("control-pipe token rotate failed".to_string());
    }
    if size_info.AceCount != 1 {
        #[cfg(test)]
        eprintln!("control-pipe DACL AceCount={}", size_info.AceCount);
        local_free_ptr(sd);
        return Ok(false);
    }

    let mut ace_ptr: *mut core::ffi::c_void = core::ptr::null_mut();
    if GetAce(dacl, 0, &mut ace_ptr) == 0 {
        local_free_ptr(sd);
        return Err("control-pipe token rotate failed".to_string());
    }
    let header = &*(ace_ptr as *const ACE_HEADER);
    // ACCESS_ALLOWED_ACE_TYPE is 0; avoid extra SystemServices feature.
    if header.AceType != 0 {
        local_free_ptr(sd);
        return Ok(false);
    }
    let sid: PSID = ace_ptr.cast::<u8>().add(8).cast();
    let equal = EqualSid(sid, token_user.User.Sid) != 0;
    local_free_ptr(sd);
    Ok(equal)
}

#[cfg(windows)]
fn control_pipe_token_file_dacl_is_user_only(path: &Path) -> Result<bool, String> {
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    };

    let path_wide = path_to_wide(path);
    unsafe {
        let mut owner: PSID = core::ptr::null_mut();
        let mut group: PSID = core::ptr::null_mut();
        let mut dacl: *mut ACL = core::ptr::null_mut();
        let mut sacl: *mut ACL = core::ptr::null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = core::ptr::null_mut();
        let status = GetNamedSecurityInfoW(
            path_wide.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            &mut group,
            &mut dacl,
            &mut sacl,
            &mut sd,
        );
        if status != ERROR_SUCCESS || dacl.is_null() {
            local_free_ptr(sd);
            return Err("control-pipe token rotate failed".to_string());
        }
        control_pipe_owner_and_dacl_are_user_only(owner, dacl, sd)
    }
}

const JSON_RPC_PARSE_ERROR: i32 = -32700;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_INTERNAL_ERROR: i32 = -32603;
const CONTROL_PIPE_CONTRACT_VERSION: u64 = 2;
const UNSUPPORTED_CONTROL_PIPE_CONTRACT_VERSION: &str =
    "Unsupported control-plane contract version (supported: 2)";

pub const DESKTOP_CONTROL_PIPE_METHODS: &[&str] = &[
    "desktop.control_plane.contract",
    "desktop.summary.snapshot",
    "desktop.run.explain",
    "desktop.run.compare",
    "desktop.run.promote",
    "desktop.run.pick_winner",
    "desktop.voice.capture_status",
    "desktop.provider.capabilities",
];

const PAIRING_CONTROL_PIPE_METHODS: &[&str] = &["desktop.pairing.confirm"];

const CONTROL_PIPE_READ_SCOPE_METHODS: &[&str] = &[
    "desktop.summary.snapshot",
    "desktop.run.explain",
    "desktop.run.compare",
    "desktop.voice.capture_status",
    "desktop.provider.capabilities",
    "pty.capture",
    "desktop.operator.snapshot",
];

const CONTROL_PIPE_SCOPE_DENIED: &str = "Control pipe method is not allowed for auth.scope";

const CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS: &[&str] = &[
    "desktop.workers.status",
    "desktop.workers.start",
    "desktop.runtime.roles.apply",
    "desktop.dogfood.event",
    "desktop.explorer.list",
    "desktop.editor.read",
];

pub fn handle_control_pipe_payload(
    desktop_transport: &dyn DesktopCommandTransport,
    pty_transport: &dyn PtyCommandTransport,
    payload: &[u8],
    project_dir: Option<String>,
) -> Vec<u8> {
    let request_value = match serde_json::from_slice::<Value>(payload) {
        Ok(value) => value,
        Err(err) => {
            return serialize_control_pipe_error(
                Value::Null,
                JSON_RPC_PARSE_ERROR,
                format!("Invalid JSON-RPC request: {err}"),
            );
        }
    };
    let request_id = request_value.get("id").cloned().unwrap_or(Value::Null);
    let method = match request_value.get("method").and_then(Value::as_str) {
        Some(value) => value,
        None => {
            return serialize_control_pipe_error(
                request_id,
                JSON_RPC_INVALID_PARAMS,
                "JSON-RPC request method must be a string".to_string(),
            );
        }
    };
    if has_project_dir_override(&request_value) {
        return serialize_control_pipe_error(
            request_id,
            JSON_RPC_INVALID_PARAMS,
            "Control pipe requests must not override projectDir".to_string(),
        );
    }

    if method == "desktop.control_plane.contract" {
        let supported = control_pipe_contract_request_is_supported(&request_value);
        let request = match serde_json::from_value::<DesktopJsonRpcRequest>(request_value) {
            Ok(value) => value,
            Err(err) => {
                return serialize_control_pipe_error(
                    Value::Null,
                    JSON_RPC_PARSE_ERROR,
                    format!("Invalid JSON-RPC request: {err}"),
                );
            }
        };
        if request.jsonrpc != "2.0" {
            return serialize_control_pipe_error(
                request.id,
                JSON_RPC_INVALID_REQUEST,
                "desktop_json_rpc expects jsonrpc=\"2.0\"".to_string(),
            );
        }
        if !supported {
            return serialize_control_pipe_error(
                request.id,
                JSON_RPC_INVALID_PARAMS,
                UNSUPPORTED_CONTROL_PIPE_CONTRACT_VERSION.to_string(),
            );
        }
        return serialize_control_pipe_result(request.id, control_pipe_contract());
    }

    match authorize_control_pipe_request(&request_value, method) {
        ControlPipeRequestAuthz::Allowed => {}
        ControlPipeRequestAuthz::InvalidToken => {
            return serialize_control_pipe_error(
                request_id,
                JSON_RPC_INVALID_REQUEST,
                format!(
                    "Control pipe method requires a valid {} value in auth.token",
                    WINSMUX_CONTROL_PIPE_TOKEN_ENV
                ),
            );
        }
        ControlPipeRequestAuthz::InvalidScope => {
            return serialize_control_pipe_error(
                request_id,
                JSON_RPC_INVALID_REQUEST,
                CONTROL_PIPE_SCOPE_DENIED.to_string(),
            );
        }
    }

    if PAIRING_CONTROL_PIPE_METHODS.contains(&method) {
        let request = match serde_json::from_value::<DesktopJsonRpcRequest>(request_value) {
            Ok(value) => value,
            Err(err) => {
                return serialize_control_pipe_error(
                    Value::Null,
                    JSON_RPC_PARSE_ERROR,
                    format!("Invalid JSON-RPC request: {err}"),
                );
            }
        };
        if request.jsonrpc != "2.0" {
            return serialize_control_pipe_error(
                request.id,
                JSON_RPC_INVALID_REQUEST,
                "desktop_json_rpc expects jsonrpc=\"2.0\"".to_string(),
            );
        }
        let _params = consume_pairing_params(request.params.as_ref());
        return match serde_json::to_value(PairingConfirmResult {
            paired: true,
            scope: "external_control_pipe".to_string(),
            version: 1,
        }) {
            Ok(result) => serialize_control_pipe_result(request.id, result),
            Err(err) => serialize_control_pipe_error(
                request.id,
                JSON_RPC_INTERNAL_ERROR,
                format!("Failed to serialize pairing confirm payload: {err}"),
            ),
        };
    }

    if DESKTOP_CONTROL_PIPE_METHODS.contains(&method) {
        let request = match serde_json::from_value::<DesktopJsonRpcRequest>(request_value) {
            Ok(value) => value,
            Err(err) => {
                return serialize_control_pipe_error(
                    Value::Null,
                    JSON_RPC_PARSE_ERROR,
                    format!("Invalid JSON-RPC request: {err}"),
                );
            }
        };

        return match serde_json::to_vec(&handle_desktop_json_rpc(
            desktop_transport,
            request,
            project_dir,
        )) {
            Ok(value) => value,
            Err(err) => serialize_control_pipe_error(
                Value::Null,
                JSON_RPC_INTERNAL_ERROR,
                format!("Failed to serialize JSON-RPC response: {err}"),
            ),
        };
    }

    if is_pty_control_pipe_method(method) {
        let request = match serde_json::from_value::<PtyJsonRpcRequest>(request_value) {
            Ok(value) => value,
            Err(err) => {
                return serialize_control_pipe_error(
                    Value::Null,
                    JSON_RPC_PARSE_ERROR,
                    format!("Invalid JSON-RPC request: {err}"),
                );
            }
        };

        return match serde_json::to_vec(&handle_pty_json_rpc(pty_transport, request)) {
            Ok(value) => value,
            Err(err) => serialize_control_pipe_error(
                Value::Null,
                JSON_RPC_INTERNAL_ERROR,
                format!("Failed to serialize JSON-RPC response: {err}"),
            ),
        };
    }

    serialize_control_pipe_error(
        request_id,
        JSON_RPC_METHOD_NOT_FOUND,
        format!("Control pipe method is not exposed: {method}"),
    )
}

fn is_pty_control_pipe_method(method: &str) -> bool {
    PTY_CONTROL_PIPE_METHODS.contains(&method) || OPERATOR_CONTROL_PIPE_METHODS.contains(&method)
}

fn control_pipe_methods() -> Vec<&'static str> {
    DESKTOP_CONTROL_PIPE_METHODS
        .iter()
        .chain(PTY_CONTROL_PIPE_METHODS.iter())
        .chain(OPERATOR_CONTROL_PIPE_METHODS.iter())
        .chain(PAIRING_CONTROL_PIPE_METHODS.iter())
        .copied()
        .collect()
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
struct PairingConfirmParams {}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
struct PairingConfirmResult {
    paired: bool,
    scope: String,
    version: u32,
}

fn consume_pairing_params(params: Option<&Value>) -> PairingConfirmParams {
    let value = match params {
        Some(Value::Null) | None => Value::Object(Default::default()),
        Some(value) => value.clone(),
    };
    serde_json::from_value(value).unwrap_or_default()
}

fn schema_value<T: JsonSchema>() -> Value {
    serde_json::to_value(schemars::schema_for!(T)).expect("json schema must serialize")
}

fn method_schema<P: JsonSchema, R: JsonSchema>() -> Value {
    json!({
        "params": schema_value::<P>(),
        "result": schema_value::<R>(),
    })
}

fn control_pipe_method_schemas() -> Value {
    json!({
        "desktop.summary.snapshot": method_schema::<DesktopSummarySnapshotParams, DesktopSummarySnapshot>(),
        "desktop.run.explain": method_schema::<DesktopRunExplainParams, DesktopExplainPayload>(),
        "desktop.run.compare": method_schema::<DesktopRunCompareParams, DesktopCompareRunsResult>(),
        "desktop.run.promote": method_schema::<DesktopRunPromoteParams, DesktopPromoteTacticResult>(),
        "desktop.run.pick_winner": method_schema::<DesktopRunPickWinnerParams, DesktopPickWinnerResult>(),
        "desktop.voice.capture_status": method_schema::<DesktopVoiceCaptureStatusParams, DesktopVoiceCaptureStatus>(),
        "desktop.provider.capabilities": method_schema::<DesktopProviderCapabilitiesParams, DesktopProviderCapabilitiesSnapshot>(),
        "pty.spawn": method_schema::<PtySpawnParams, PtyPaneResult>(),
        "pty.write": method_schema::<PtyWriteParams, PtyPaneResult>(),
        "pty.resize": method_schema::<PtyResizeParams, PtyPaneResult>(),
        "pty.capture": method_schema::<PtyCaptureParams, PtyCaptureResult>(),
        "pty.respawn": method_schema::<PtyRespawnParams, PtyPaneResult>(),
        "pty.close": method_schema::<PtyCloseParams, PtyPaneResult>(),
        "desktop.operator.snapshot": method_schema::<OperatorSnapshotParams, PtyCaptureResult>(),
        "desktop.operator.submit": method_schema::<OperatorSubmitParams, OperatorSubmitResult>(),
        "desktop.pairing.confirm": method_schema::<PairingConfirmParams, PairingConfirmResult>(),
    })
}

fn control_pipe_contract_request_is_supported(request_value: &Value) -> bool {
    match request_value.get("params") {
        None => true,
        Some(Value::Object(map)) => {
            if map.keys().any(|key| key.as_str() != "version") {
                return false;
            }
            match map.get("version") {
                None => true,
                Some(Value::Number(number)) => {
                    number.as_u64() == Some(CONTROL_PIPE_CONTRACT_VERSION)
                }
                Some(_) => false,
            }
        }
        Some(_) => false,
    }
}

fn control_pipe_contract() -> Value {
    json!({
    "version": 2,
    "scope": "external_control_pipe",
    "transport": "named_pipe_json_rpc",
    "pipe": WINSMUX_CONTROL_PIPE_NAME,
    "jsonrpc": "2.0",
    "localhost_http": false,
    "websocket": false,
    "auth": {
        "required_for_methods": true,
        "token_env": WINSMUX_CONTROL_PIPE_TOKEN_ENV,
        "token_file": WINSMUX_CONTROL_PIPE_TOKEN_FILE_TEMPLATE,
        "request_field": "auth.token",
        "scope_field": "auth.scope",
        "scopes": ["read", "write"],
    },
    "methods": control_pipe_methods(),
    "desktop_methods": DESKTOP_CONTROL_PIPE_METHODS,
    "pty_methods": PTY_CONTROL_PIPE_METHODS,
    "operator_methods": OPERATOR_CONTROL_PIPE_METHODS,
    "pairing_methods": PAIRING_CONTROL_PIPE_METHODS,
    "internal_desktop_methods_excluded": CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS,
    "schemas": control_pipe_method_schemas(),
    })
}

enum ControlPipeRequestAuthz {
    Allowed,
    InvalidToken,
    InvalidScope,
}

fn control_pipe_token_matches(request_value: &Value) -> bool {
    let provided_token = match request_value
        .get("auth")
        .and_then(|auth| auth.get("token"))
        .and_then(Value::as_str)
    {
        Some(value) => value,
        None => return false,
    };

    if let Some(expected_token) = process_env_control_pipe_token() {
        return constant_time_string_eq(provided_token.as_bytes(), expected_token.as_bytes());
    }

    authorize_rotated_or_file_token(provided_token)
}

fn control_pipe_scope_allows_method(request_value: &Value, method: &str) -> bool {
    let Some(auth) = request_value.get("auth") else {
        return true;
    };
    match auth.get("scope") {
        None => true,
        Some(Value::Null) => false,
        Some(Value::String(scope)) => match scope.as_str() {
            "write" => true,
            "read" => CONTROL_PIPE_READ_SCOPE_METHODS.contains(&method),
            _ => false,
        },
        Some(_) => false,
    }
}

fn authorize_control_pipe_request(request_value: &Value, method: &str) -> ControlPipeRequestAuthz {
    if !control_pipe_token_matches(request_value) {
        return ControlPipeRequestAuthz::InvalidToken;
    }
    if !control_pipe_scope_allows_method(request_value, method) {
        return ControlPipeRequestAuthz::InvalidScope;
    }
    ControlPipeRequestAuthz::Allowed
}

fn constant_time_string_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    let mut diff = 0u8;
    for (left_byte, right_byte) in left.iter().zip(right.iter()) {
        diff |= left_byte ^ right_byte;
    }
    diff == 0
}

fn has_project_dir_override(request_value: &Value) -> bool {
    request_value
        .get("params")
        .and_then(Value::as_object)
        .is_some_and(|params| {
            params.contains_key("projectDir") || params.contains_key("project_dir")
        })
}

fn serialize_control_pipe_error(id: Value, code: i32, message: String) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message,
        },
    }))
    .unwrap_or_else(|_| {
        br#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to serialize JSON-RPC error"}}"#.to_vec()
    })
}

fn serialize_control_pipe_result(id: Value, result: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    }))
    .unwrap_or_else(|_| {
        br#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Failed to serialize JSON-RPC result"}}"#.to_vec()
    })
}

#[cfg(windows)]
pub fn start_control_pipe_server(pty_transport: Arc<dyn PtyCommandTransport + Send + Sync>) {
    mark_control_pipe_server_intended();
    std::thread::spawn(move || {
        let mut token_bootstrapped = false;
        loop {
            if let Err(err) =
                serve_one_control_pipe_client(pty_transport.as_ref(), &mut token_bootstrapped)
            {
                if is_control_pipe_startup_error(&err) {
                    eprintln!("winsmux control pipe disabled: {err}");
                    break;
                }
                eprintln!("winsmux control pipe error: {err}");
                std::thread::sleep(Duration::from_millis(250));
            }
        }
    });
}

#[cfg(not(windows))]
pub fn start_control_pipe_server(_pty_transport: Arc<dyn PtyCommandTransport + Send + Sync>) {}

#[cfg(windows)]
fn serve_one_control_pipe_client(
    pty_transport: &dyn PtyCommandTransport,
    token_bootstrapped: &mut bool,
) -> Result<(), String> {
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, HANDLE,
    };
    use windows_sys::Win32::Storage::FileSystem::{FlushFileBuffers, ReadFile, WriteFile};
    use windows_sys::Win32::System::Pipes::{ConnectNamedPipe, DisconnectNamedPipe};

    struct PipeHandle(HANDLE);

    impl Drop for PipeHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    let handle = create_user_only_named_pipe(WINSMUX_CONTROL_PIPE_NAME)?;
    let pipe = PipeHandle(handle);
    bootstrap_control_pipe_token_after_exclusive_pipe(token_bootstrapped)?;

    let connected = unsafe { ConnectNamedPipe(pipe.0, null_mut()) };
    if connected == 0 {
        let error = unsafe { GetLastError() };
        if error != ERROR_PIPE_CONNECTED {
            return Err(format!("ConnectNamedPipe failed with {error}"));
        }
    }

    let mut buffer = vec![0u8; 1024 * 1024];
    let mut bytes_read = 0u32;
    let read_ok = unsafe {
        ReadFile(
            pipe.0,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
            &mut bytes_read,
            null_mut(),
        )
    };
    if read_ok == 0 {
        return Err(format!("ReadFile failed with {}", unsafe {
            GetLastError()
        }));
    }
    buffer.truncate(bytes_read as usize);

    let response = handle_control_pipe_payload(&PwshScriptTransport, pty_transport, &buffer, None);
    let mut bytes_written = 0u32;
    let write_ok = unsafe {
        WriteFile(
            pipe.0,
            response.as_ptr().cast(),
            response.len() as u32,
            &mut bytes_written,
            null_mut(),
        )
    };
    if write_ok == 0 {
        return Err(format!("WriteFile failed with {}", unsafe {
            GetLastError()
        }));
    }
    if bytes_written as usize != response.len() {
        return Err(format!(
            "WriteFile wrote {} of {} bytes",
            bytes_written,
            response.len()
        ));
    }

    unsafe {
        FlushFileBuffers(pipe.0);
        DisconnectNamedPipe(pipe.0);
    }
    Ok(())
}

#[cfg(windows)]
fn is_control_pipe_startup_error(message: &str) -> bool {
    message.starts_with("CreateNamedPipeW failed")
        || message.starts_with("control-pipe token rotate failed")
        || message.starts_with("control-pipe object SD failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_backend::{DesktopCommand, DesktopCommandTransport};
    use crate::pty_backend::PtyCommand;
    use serde_json::json;
    use std::ffi::OsString;
    use std::sync::{Mutex, MutexGuard};

    static CONTROL_PIPE_TOKEN_ENV_LOCK: Mutex<()> = Mutex::new(());
    static CONTROL_PIPE_TEST_ISOLATION: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(0);

    struct ControlPipeTokenEnvGuard {
        previous_token: Option<OsString>,
        previous_localappdata: Option<OsString>,
        isolated_root: PathBuf,
        _lock: MutexGuard<'static, ()>,
    }

    impl Drop for ControlPipeTokenEnvGuard {
        fn drop(&mut self) {
            reset_control_pipe_auth_state();
            reset_control_pipe_server_intended();
            if let Some(previous) = self.previous_token.take() {
                std::env::set_var(WINSMUX_CONTROL_PIPE_TOKEN_ENV, previous);
            } else {
                std::env::remove_var(WINSMUX_CONTROL_PIPE_TOKEN_ENV);
            }
            if let Some(previous) = self.previous_localappdata.take() {
                std::env::set_var("LOCALAPPDATA", previous);
            } else {
                std::env::remove_var("LOCALAPPDATA");
            }
            let _ = fs::remove_dir_all(&self.isolated_root);
        }
    }

    fn isolate_control_pipe_paths_for_test() -> ControlPipeTokenEnvGuard {
        let lock = CONTROL_PIPE_TOKEN_ENV_LOCK
            .lock()
            .unwrap_or_else(|err| err.into_inner());
        reset_control_pipe_auth_state();
        reset_control_pipe_server_intended();
        let previous_token = std::env::var_os(WINSMUX_CONTROL_PIPE_TOKEN_ENV);
        let previous_localappdata = std::env::var_os("LOCALAPPDATA");
        std::env::remove_var(WINSMUX_CONTROL_PIPE_TOKEN_ENV);
        let isolated_root = std::env::temp_dir().join(format!(
            "winsmux-control-pipe-test-{}-{}",
            std::process::id(),
            CONTROL_PIPE_TEST_ISOLATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(&isolated_root).expect("isolated LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &isolated_root);
        ControlPipeTokenEnvGuard {
            previous_token,
            previous_localappdata,
            isolated_root,
            _lock: lock,
        }
    }

    fn set_control_pipe_token_for_test(token: Option<&str>) -> ControlPipeTokenEnvGuard {
        let guard = isolate_control_pipe_paths_for_test();
        if let Some(value) = token {
            std::env::set_var(WINSMUX_CONTROL_PIPE_TOKEN_ENV, value);
        }
        guard
    }

    fn leftover_control_pipe_token_temps(parent: &Path) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(parent) else {
            return Vec::new();
        };
        entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| {
                        name.starts_with("token.")
                            && name.ends_with(".tmp")
                            && name.len() == "token.".len() + 32 + ".tmp".len()
                    })
            })
            .collect()
    }

    fn harden_existing_token_file_for_test(path: &Path) {
        #[cfg(windows)]
        apply_user_only_dacl(path).expect("harden previous token file");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).expect("chmod 0600");
        }
    }

    fn expire_previous_control_pipe_token_for_test() {
        if let Some(state) = control_pipe_auth_state_lock().as_mut() {
            state.previous_deadline = Instant::now() - Duration::from_secs(1);
        }
    }

    fn capture_payload_with_token(token: &str) -> Vec<u8> {
        format!(
            r#"{{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{{"paneId":"pane-1"}},"auth":{{"token":"{token}"}}}}"#
        )
        .into_bytes()
    }

    fn control_pipe_payload_with_auth(method: &str, params: Value, auth: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
            "auth": auth,
        }))
        .expect("payload")
    }

    fn pairing_payload_with_token(token: Option<&str>) -> Vec<u8> {
        let mut request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "desktop.pairing.confirm",
        });
        if let Some(token) = token {
            request["auth"] = json!({ "token": token });
        }
        serde_json::to_vec(&request).expect("pairing payload")
    }

    struct StubDesktopTransport;

    impl DesktopCommandTransport for StubDesktopTransport {
        fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
            match command {
                DesktopCommand::SummarySnapshot { .. } => Ok(json!({
                    "version": 1,
                    "generated_at": "2026-04-23T00:00:00Z",
                    "project": {
                        "root": "C:/repo",
                        "branch": "main",
                        "head_sha": "abc123",
                        "base_sha": "def456",
                        "dirty": false,
                        "untracked_count": 0
                    },
                    "summary": {
                        "total_panes": 0,
                        "running": 0,
                        "waiting": 0,
                        "needs_attention": 0,
                        "ready_for_review": 0,
                        "by_state": {},
                        "by_review": {},
                        "by_task_state": {}
                    },
                    "board": [],
                    "inbox": {
                        "summary": {
                            "total": 0,
                            "unread": 0,
                            "high_priority": 0,
                            "by_kind": {}
                        },
                        "items": []
                    },
                    "runs": []
                })),
                _ => Err("unexpected command".to_string()),
            }
        }
    }

    struct RecordingDesktopTransport {
        calls: Mutex<usize>,
    }

    impl RecordingDesktopTransport {
        fn new() -> Self {
            Self {
                calls: Mutex::new(0),
            }
        }
    }

    impl DesktopCommandTransport for RecordingDesktopTransport {
        fn request_json(&self, command: &DesktopCommand) -> Result<Value, String> {
            *self.calls.lock().expect("calls lock") += 1;
            StubDesktopTransport.request_json(command)
        }
    }

    struct StubPtyTransport {
        commands: Mutex<Vec<PtyCommand>>,
    }

    impl StubPtyTransport {
        fn new() -> Self {
            Self {
                commands: Mutex::new(Vec::new()),
            }
        }
    }

    impl PtyCommandTransport for StubPtyTransport {
        fn execute(&self, command: &PtyCommand) -> Result<Value, String> {
            self.commands
                .lock()
                .expect("commands lock")
                .push(command.clone());
            match command {
                PtyCommand::Capture { pane_id, .. } => Ok(json!({
                    "paneId": pane_id,
                    "output": "ready"
                })),
                _ => Ok(json!({ "ok": true })),
            }
        }
    }

    fn automation_contract_jsonrpc_response() -> Value {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        serde_json::from_slice(&response).expect("response should be JSON")
    }

    fn assert_automation_contract_result(result: &Value) {
        assert_eq!(result["version"], 2);
        assert_eq!(result["scope"], "external_control_pipe");
        assert_eq!(result["transport"], "named_pipe_json_rpc");
        assert_eq!(result["pipe"], WINSMUX_CONTROL_PIPE_NAME);
        assert_eq!(result["localhost_http"], false);
        assert_eq!(result["websocket"], false);
        assert_eq!(result["auth"]["required_for_methods"], true);
        assert_eq!(result["auth"]["token_env"], WINSMUX_CONTROL_PIPE_TOKEN_ENV);
        assert_eq!(
            result["auth"]["token_file"],
            WINSMUX_CONTROL_PIPE_TOKEN_FILE_TEMPLATE
        );
        assert_eq!(result["auth"]["request_field"], "auth.token");
        assert_eq!(result["auth"]["scope_field"], "auth.scope");
        assert_eq!(result["auth"]["scopes"], json!(["read", "write"]));
        assert_eq!(result["desktop_methods"], json!(DESKTOP_CONTROL_PIPE_METHODS));
        assert_eq!(result["pty_methods"], json!(PTY_CONTROL_PIPE_METHODS));
        assert_eq!(
            result["operator_methods"],
            json!(OPERATOR_CONTROL_PIPE_METHODS)
        );
        assert_eq!(
            result["pairing_methods"],
            json!(PAIRING_CONTROL_PIPE_METHODS)
        );
        assert_eq!(result["methods"], json!(control_pipe_methods()));
        assert_eq!(
            result["internal_desktop_methods_excluded"],
            json!(CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS)
        );
        let methods = result["methods"].as_array().expect("methods");
        for excluded in CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS {
            assert!(
                !methods.iter().any(|method| method.as_str() == Some(*excluded)),
                "excluded internal method leaked: {excluded}"
            );
        }
        assert!(methods
            .iter()
            .any(|method| method.as_str() == Some("pty.capture")));
        assert!(methods
            .iter()
            .any(|method| method.as_str() == Some("desktop.operator.snapshot")));
        assert!(methods
            .iter()
            .any(|method| method.as_str() == Some("desktop.operator.submit")));
        assert!(methods
            .iter()
            .any(|method| method.as_str() == Some("desktop.pairing.confirm")));
    }

    #[test]
    fn control_pipe_returns_external_contract_matching_allowlist() {
        let value = automation_contract_jsonrpc_response();

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_automation_contract_result(&value["result"]);
    }

    fn checked_in_control_pipe_contract_artifact_path() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/control-plane-contract.v2.json")
    }

    fn repo_docs_path(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs").join(name)
    }

    fn method_bullet_name(line: &str) -> Option<&str> {
        let trimmed = line.trim();
        let rest = trimmed.strip_prefix("- `")?;
        let name = rest.strip_suffix('`')?;
        if name.is_empty() || name.contains('`') || name.contains(' ') {
            return None;
        }
        Some(name)
    }

    fn extract_method_list(markdown: &str, sentinel: &str) -> Vec<String> {
        let occurrences = markdown.matches(sentinel).count();
        assert_eq!(
            occurrences, 1,
            "sentinel must occur exactly once: {sentinel}"
        );
        let after = markdown.split_once(sentinel).expect("sentinel present").1;
        let mut methods = Vec::new();
        let mut in_list = false;
        for line in after.lines() {
            if let Some(name) = method_bullet_name(line) {
                methods.push(name.to_string());
                in_list = true;
                continue;
            }
            if in_list {
                break;
            }
        }
        methods
    }

    fn json_string_set(value: &Value) -> std::collections::HashSet<String> {
        value
            .as_array()
            .expect("contract list should be an array")
            .iter()
            .map(|item| {
                item.as_str()
                    .expect("contract list entry should be a string")
                    .to_string()
            })
            .collect()
    }

    fn set_from_names(names: &[String]) -> std::collections::HashSet<String> {
        let set: std::collections::HashSet<String> = names.iter().cloned().collect();
        assert_eq!(
            set.len(),
            names.len(),
            "method list contains duplicates: {names:?}"
        );
        set
    }

    fn assert_method_sets_equal(
        file: &str,
        list: &str,
        doc: &std::collections::HashSet<String>,
        contract: &std::collections::HashSet<String>,
    ) {
        if doc == contract {
            return;
        }
        let missing: Vec<_> = contract.difference(doc).cloned().collect();
        let extra: Vec<_> = doc.difference(contract).cloned().collect();
        panic!("{file} {list} drifted from docs/control-plane-contract.v2.json; missing {missing:?} extra {extra:?}");
    }

    fn assert_doc_method_lists_match_artifact(doc_name: &str) {
        let markdown = fs::read_to_string(repo_docs_path(doc_name)).unwrap_or_else(|err| {
            panic!("read {doc_name}: {err}");
        });
        let artifact_raw =
            fs::read_to_string(checked_in_control_pipe_contract_artifact_path()).unwrap_or_else(
                |err| panic!("read contract artifact: {err}"),
            );
        let artifact: Value =
            serde_json::from_str(&artifact_raw).expect("checked-in contract artifact should parse");

        let (desktop_sentinel, pty_sentinel, excluded_sentinel) =
            if doc_name.ends_with(".ja.md") {
                (
                    "named pipe は、現時点で次のデスクトップメソッドを公開します。",
                    "同じ pipe は、ローカルペイン制御用に次の PTY メソッドも公開します。",
                    "次のメソッドは、現時点では named pipe から公開しません。",
                )
            } else {
                (
                    "The named pipe currently exposes these desktop methods:",
                    "The same pipe also exposes these PTY methods for local pane control:",
                    "These methods are intentionally not exposed through the named pipe today:",
                )
            };

        let desktop = set_from_names(&extract_method_list(&markdown, desktop_sentinel));
        let pty = set_from_names(&extract_method_list(&markdown, pty_sentinel));
        let excluded = set_from_names(&extract_method_list(&markdown, excluded_sentinel));

        let mut expected_desktop = json_string_set(&artifact["desktop_methods"]);
        expected_desktop.extend(json_string_set(&artifact["pairing_methods"]));
        expected_desktop.extend(json_string_set(&artifact["operator_methods"]));
        let expected_pty = json_string_set(&artifact["pty_methods"]);
        let expected_excluded = json_string_set(&artifact["internal_desktop_methods_excluded"]);

        assert_method_sets_equal(doc_name, "desktop", &desktop, &expected_desktop);
        assert_method_sets_equal(doc_name, "pty", &pty, &expected_pty);
        assert_method_sets_equal(doc_name, "internal-excluded", &excluded, &expected_excluded);

        let exposed: std::collections::HashSet<_> = desktop.union(&pty).cloned().collect();
        let overlap: Vec<_> = exposed.intersection(&excluded).cloned().collect();
        assert!(
            overlap.is_empty(),
            "{doc_name} exposed methods overlap excluded methods: {overlap:?}"
        );
    }

    fn repo_root_path() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn surface_matrix_sentinel(doc_name: &str) -> &'static str {
        if doc_name.ends_with(".ja.md") {
            "この surface 互換マトリクスは、チェックイン済み v2 契約成果物に対して CI でゲートします。"
        } else {
            "This surface compatibility matrix is CI-gated against the checked-in v2 contract artifact."
        }
    }

    fn frozen_surface_matrix_cells() -> Vec<(&'static str, &'static str, &'static str, &'static str)>
    {
        vec![
            (
                "desktop.control_plane.contract",
                "yes",
                "automation-contract",
                "winsmux_automation_contract",
            ),
            (
                "desktop.summary.snapshot",
                "yes",
                "control-rpc only",
                "—",
            ),
            ("desktop.run.explain", "yes", "control-rpc only", "—"),
            ("desktop.run.compare", "yes", "control-rpc only", "—"),
            ("desktop.run.promote", "yes", "control-rpc only", "—"),
            (
                "desktop.run.pick_winner",
                "yes",
                "control-rpc only",
                "—",
            ),
            (
                "desktop.voice.capture_status",
                "yes",
                "control-rpc only",
                "—",
            ),
            (
                "desktop.provider.capabilities",
                "yes",
                "control-rpc only",
                "—",
            ),
            ("pty.spawn", "yes", "control-rpc only", "—"),
            ("pty.write", "yes", "control-rpc only", "—"),
            ("pty.resize", "yes", "control-rpc only", "—"),
            ("pty.capture", "yes", "control-rpc only", "—"),
            ("pty.respawn", "yes", "control-rpc only", "—"),
            ("pty.close", "yes", "control-rpc only", "—"),
            (
                "desktop.operator.snapshot",
                "yes",
                "operator-snapshot (ps1)",
                "—",
            ),
            (
                "desktop.operator.submit",
                "yes",
                "operator-submit (ps1)",
                "—",
            ),
            (
                "desktop.pairing.confirm",
                "yes",
                "automation-pair",
                "winsmux_automation_pair",
            ),
        ]
    }

    fn extract_surface_matrix_rows(
        markdown: &str,
        sentinel: &str,
    ) -> Vec<(String, String, String, String)> {
        let occurrences = markdown.matches(sentinel).count();
        assert_eq!(
            occurrences, 1,
            "surface matrix sentinel must occur exactly once: {sentinel}"
        );
        let after = markdown.split_once(sentinel).expect("sentinel present").1;
        let mut rows = Vec::new();
        let mut seen_header = false;
        for line in after.lines() {
            let trimmed = line.trim();
            if !trimmed.starts_with('|') {
                if seen_header && !rows.is_empty() {
                    break;
                }
                continue;
            }
            let cells: Vec<&str> = trimmed
                .trim_matches('|')
                .split('|')
                .map(str::trim)
                .collect();
            if cells.len() != 4 {
                continue;
            }
            if cells[0].eq_ignore_ascii_case("Method") {
                seen_header = true;
                continue;
            }
            if cells.iter().all(|cell| {
                cell.chars()
                    .all(|ch| ch == '-' || ch == ':' || ch.is_whitespace())
            }) {
                continue;
            }
            rows.push((
                cells[0].to_string(),
                cells[1].to_string(),
                cells[2].to_string(),
                cells[3].to_string(),
            ));
        }
        assert!(
            seen_header && !rows.is_empty(),
            "surface matrix table missing after sentinel: {sentinel}"
        );
        rows
    }

    fn assert_surface_matrix_first_source_pins() {
        let root = repo_root_path();
        let ps1 = fs::read_to_string(root.join("scripts/winsmux-core.ps1")).unwrap_or_else(|err| {
            panic!("read winsmux-core.ps1: {err}");
        });
        assert!(
            ps1.contains("-Method 'desktop.operator.snapshot'"),
            "ps1 must still send desktop.operator.snapshot"
        );
        assert!(
            ps1.contains("-Method 'desktop.operator.submit'"),
            "ps1 must still send desktop.operator.submit"
        );

        let rust = fs::read_to_string(root.join("core/src/control_pipe_client.rs")).unwrap_or_else(
            |err| panic!("read control_pipe_client.rs: {err}"),
        );
        assert!(
            rust.contains("pub const AUTOMATION_CONTRACT_COMMAND: &str = \"automation-contract\""),
            "native automation-contract constant missing"
        );
        assert!(
            rust.contains("pub const AUTOMATION_PAIR_COMMAND: &str = \"automation-pair\""),
            "native automation-pair constant missing"
        );
        assert!(
            rust.contains("\"method\": \"desktop.pairing.confirm\""),
            "native pairing request must still name desktop.pairing.confirm"
        );

        let mcp = fs::read_to_string(root.join("winsmux-core/mcp-server.js")).unwrap_or_else(|err| {
            panic!("read mcp-server.js: {err}");
        });
        assert!(
            mcp.contains("invokeNativeCli([\"automation-contract\"])"),
            "MCP contract tool must still invoke native automation-contract"
        );
        assert!(
            mcp.contains("invokeNativeCli([\"automation-pair\"])"),
            "MCP pair tool must still invoke native automation-pair"
        );
    }

    fn assert_doc_surface_matrix_matches_artifact(doc_name: &str) {
        let markdown = fs::read_to_string(repo_docs_path(doc_name)).unwrap_or_else(|err| {
            panic!("read {doc_name}: {err}");
        });
        let artifact_raw =
            fs::read_to_string(checked_in_control_pipe_contract_artifact_path()).unwrap_or_else(
                |err| panic!("read contract artifact: {err}"),
            );
        let artifact: Value =
            serde_json::from_str(&artifact_raw).expect("checked-in contract artifact should parse");
        let expected_methods = json_string_set(&artifact["methods"]);
        let frozen = frozen_surface_matrix_cells();
        let frozen_methods: std::collections::HashSet<String> =
            frozen.iter().map(|(method, _, _, _)| (*method).to_string()).collect();
        assert_eq!(
            frozen.len(),
            frozen_methods.len(),
            "frozen surface matrix mapping has duplicate methods"
        );
        assert_eq!(
            frozen_methods, expected_methods,
            "{doc_name} frozen mapping methods must equal artifact methods"
        );

        let cli_vocab: std::collections::HashSet<&str> = [
            "automation-contract",
            "automation-pair",
            "operator-snapshot (ps1)",
            "operator-submit (ps1)",
            "control-rpc only",
        ]
        .into_iter()
        .collect();
        let mcp_vocab: std::collections::HashSet<&str> = [
            "winsmux_automation_contract",
            "winsmux_automation_pair",
            "—",
        ]
        .into_iter()
        .collect();

        let expected_rows: std::collections::HashMap<&str, (&str, &str, &str)> = frozen
            .iter()
            .map(|(method, pipe, cli, mcp)| (*method, (*pipe, *cli, *mcp)))
            .collect();
        for (method, pipe, cli, mcp) in &frozen {
            assert_eq!(*pipe, "yes", "{method} pipe cell must be constant yes");
            assert!(
                cli_vocab.contains(cli),
                "{method} CLI cell {cli:?} is outside the frozen vocabulary"
            );
            assert!(
                mcp_vocab.contains(mcp),
                "{method} MCP cell {mcp:?} is outside the frozen vocabulary"
            );
        }

        let rows = extract_surface_matrix_rows(&markdown, surface_matrix_sentinel(doc_name));
        let row_methods: std::collections::HashSet<String> =
            rows.iter().map(|(method, _, _, _)| method.clone()).collect();
        assert_eq!(
            row_methods.len(),
            rows.len(),
            "{doc_name} surface matrix has duplicate methods"
        );
        assert_method_sets_equal(
            doc_name,
            "surface-matrix",
            &row_methods,
            &expected_methods,
        );
        for (method, pipe, cli, mcp) in &rows {
            let Some(expected) = expected_rows.get(method.as_str()) else {
                panic!("{doc_name} surface matrix has unexpected method {method}");
            };
            assert_eq!(pipe, expected.0, "{doc_name} {method} pipe cell drifted");
            assert_eq!(cli, expected.1, "{doc_name} {method} CLI cell drifted");
            assert_eq!(mcp, expected.2, "{doc_name} {method} MCP cell drifted");
        }

        assert_surface_matrix_first_source_pins();
    }

    #[test]
    fn control_pipe_contract_matches_checked_in_artifact() {
        let artifact_path = checked_in_control_pipe_contract_artifact_path();
        let raw = fs::read_to_string(&artifact_path).unwrap_or_else(|err| {
            panic!("read {}: {err}", artifact_path.display());
        });
        let artifact: Value =
            serde_json::from_str(&raw).expect("checked-in contract artifact should parse");
        let live = control_pipe_contract();
        if artifact != live {
            panic!(
                "docs/control-plane-contract.v2.json drifted from control_pipe_contract(); replace the file with this pretty JSON:\n{}",
                serde_json::to_string_pretty(&live).expect("serialize live contract")
            );
        }
    }

    #[test]
    fn control_pipe_contract_schemas_cover_every_method() {
        let contract = control_pipe_contract();
        let schemas = contract["schemas"]
            .as_object()
            .expect("schemas must be an object");
        let mut expected: Vec<&str> = control_pipe_methods()
            .into_iter()
            .filter(|method| *method != "desktop.control_plane.contract")
            .collect();
        let mut actual: Vec<&str> = schemas.keys().map(String::as_str).collect();
        expected.sort_unstable();
        actual.sort_unstable();
        assert_eq!(actual, expected);

        for method in expected {
            let entry = schemas
                .get(method)
                .and_then(Value::as_object)
                .unwrap_or_else(|| panic!("{method} schema entry must be an object"));
            let params = entry
                .get("params")
                .and_then(Value::as_object)
                .unwrap_or_else(|| panic!("{method} params schema must be a non-empty object"));
            let result = entry
                .get("result")
                .and_then(Value::as_object)
                .unwrap_or_else(|| panic!("{method} result schema must be a non-empty object"));
            assert!(
                !params.is_empty(),
                "{method} params schema must be a non-empty object"
            );
            assert!(
                !result.is_empty(),
                "{method} result schema must be a non-empty object"
            );
        }
    }

    #[test]
    fn control_pipe_contract_artifact_embeds_no_expanded_paths() {
        let artifact_path = checked_in_control_pipe_contract_artifact_path();
        let raw = fs::read_to_string(&artifact_path).unwrap_or_else(|err| {
            panic!("read {}: {err}", artifact_path.display());
        });
        let artifact: Value =
            serde_json::from_str(&raw).expect("checked-in contract artifact should parse");
        assert_eq!(
            artifact["auth"]["token_file"],
            WINSMUX_CONTROL_PIPE_TOKEN_FILE_TEMPLATE
        );
        assert!(
            !raw.contains(r"C:\Users") && !raw.contains(r"Users\"),
            "artifact must not embed expanded user paths"
        );
        assert!(
            raw.contains("%LOCALAPPDATA%"),
            "artifact must keep the literal LOCALAPPDATA token"
        );
        assert!(
            !raw.contains(r"AppData\Local") && !raw.contains("AppData/Local"),
            "artifact must not expand LOCALAPPDATA"
        );
    }

    #[test]
    fn external_control_plane_doc_method_lists_match_contract_artifact() {
        assert_doc_method_lists_match_artifact("external-control-plane.md");
    }

    #[test]
    fn external_control_plane_ja_doc_method_lists_match_contract_artifact() {
        assert_doc_method_lists_match_artifact("external-control-plane.ja.md");
    }

    #[test]
    fn external_control_plane_doc_surface_matrix_matches_contract_artifact() {
        assert_doc_surface_matrix_matches_artifact("external-control-plane.md");
    }

    #[test]
    fn external_control_plane_ja_doc_surface_matrix_matches_contract_artifact() {
        assert_doc_surface_matrix_matches_artifact("external-control-plane.ja.md");
    }

    #[test]
    fn automation_contract_matches_pipe_allowlist() {
        // Native CLI `automation-contract` prints this JSON-RPC `result` object.
        // Pipe-name override is forbidden, so CI cannot E2E the live named pipe;
        // this Desktop test is the frozen allowlist proof (source of truth stays here).
        let value = automation_contract_jsonrpc_response();
        assert_automation_contract_result(&value["result"]);
    }

    #[test]
    fn control_pipe_pairing_confirm_requires_token() {
        let pty_transport = StubPtyTransport::new();
        {
            let _guard = set_control_pipe_token_for_test(None);
            let missing = handle_control_pipe_payload(
                &StubDesktopTransport,
                &pty_transport,
                &pairing_payload_with_token(None),
                None,
            );
            let missing_value: Value = serde_json::from_slice(&missing).expect("missing json");
            assert_eq!(missing_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
            assert!(missing_value["error"]["message"]
                .as_str()
                .expect("error message")
                .contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
            assert!(
                !missing_value["error"]["message"]
                    .as_str()
                    .expect("error message")
                    .contains("auth.scope")
            );
        }

        let _guard = set_control_pipe_token_for_test(Some("expected-token"));
        let wrong = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some("wrong-token")),
            None,
        );
        let wrong_value: Value = serde_json::from_slice(&wrong).expect("wrong json");
        assert_eq!(wrong_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(wrong_value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_omitted_scope_still_allows_write() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "scope-file-token").expect("file token");
        harden_existing_token_file_for_test(&path);
        let pty_transport = StubPtyTransport::new();
        let response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &control_pipe_payload_with_auth(
                "pty.write",
                json!({"paneId":"pane-1","data":"x"}),
                json!({"token":"scope-file-token"}),
            ),
            None,
        );
        let value: Value = serde_json::from_slice(&response).expect("response json");
        assert!(
            value.get("error").is_none(),
            "omit auth.scope must keep full grant: {value}"
        );
        assert_eq!(value["result"]["ok"], true);
    }

    #[test]
    fn control_pipe_read_scope_cannot_write() {
        let _guard = set_control_pipe_token_for_test(Some("scope-token"));
        let pty_transport = StubPtyTransport::new();
        let denied = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &control_pipe_payload_with_auth(
                "pty.write",
                json!({"paneId":"pane-1","data":"x"}),
                json!({"token":"scope-token","scope":"read"}),
            ),
            None,
        );
        let denied_value: Value = serde_json::from_slice(&denied).expect("denied json");
        assert_eq!(denied_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        let message = denied_value["error"]["message"]
            .as_str()
            .expect("error message");
        assert!(
            message.contains("auth.scope"),
            "scope deny must name auth.scope: {message}"
        );
        assert!(
            !message.contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV),
            "scope deny must not look like a missing token"
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());

        let captured = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &control_pipe_payload_with_auth(
                "pty.capture",
                json!({"paneId":"pane-1"}),
                json!({"token":"scope-token","scope":"read"}),
            ),
            None,
        );
        let captured_value: Value = serde_json::from_slice(&captured).expect("capture json");
        assert!(
            captured_value.get("error").is_none(),
            "read scope must still capture: {captured_value}"
        );
        assert_eq!(captured_value["result"]["output"], "ready");
    }

    #[test]
    fn control_pipe_unknown_scope_is_denied() {
        let _guard = set_control_pipe_token_for_test(Some("scope-token"));
        let pty_transport = StubPtyTransport::new();
        for scope in [
            json!("admin"),
            json!(""),
            json!(null),
            json!(1),
            json!(true),
            json!(["read"]),
        ] {
            let denied = handle_control_pipe_payload(
                &StubDesktopTransport,
                &pty_transport,
                &control_pipe_payload_with_auth(
                    "pty.capture",
                    json!({"paneId":"pane-1"}),
                    json!({"token":"scope-token","scope":scope}),
                ),
                None,
            );
            let denied_value: Value = serde_json::from_slice(&denied).expect("denied json");
            assert_eq!(denied_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
            assert!(
                denied_value["error"]["message"]
                    .as_str()
                    .expect("error message")
                    .contains("auth.scope"),
                "unknown scope {scope} must deny"
            );
        }

        let contract = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#,
            None,
        );
        let contract_value: Value = serde_json::from_slice(&contract).expect("contract json");
        assert_eq!(contract_value["result"]["version"], 2);
        assert!(contract_value.get("error").is_none());
    }

    #[test]
    fn control_pipe_invalid_token_wins_over_scope() {
        let _guard = set_control_pipe_token_for_test(Some("expected-token"));
        let pty_transport = StubPtyTransport::new();
        let response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &control_pipe_payload_with_auth(
                "pty.capture",
                json!({"paneId":"pane-1"}),
                json!({"token":"wrong-token","scope":"read"}),
            ),
            None,
        );
        let value: Value = serde_json::from_slice(&response).expect("response json");
        let message = value["error"]["message"].as_str().expect("error message");
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(message.contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
        assert!(!message.contains("auth.scope"));
    }

    #[test]
    fn control_pipe_read_scope_union_covers_allowlist() {
        let allowlist: std::collections::HashSet<&str> = control_pipe_methods().into_iter().collect();
        let read: std::collections::HashSet<&str> =
            CONTROL_PIPE_READ_SCOPE_METHODS.iter().copied().collect();
        assert!(
            read.is_subset(&allowlist),
            "read grant leaked a method not on the allowlist"
        );
        let mutate: std::collections::HashSet<&str> =
            allowlist.difference(&read).copied().collect();
        let union: std::collections::HashSet<&str> = read.union(&mutate).copied().collect();
        assert_eq!(union, allowlist);
        assert!(mutate.contains("pty.write"));
        assert!(mutate.contains("desktop.control_plane.contract"));
        assert!(read.contains("pty.capture"));
    }

    #[test]
    fn control_pipe_pairing_confirm_returns_static_result_without_transport() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let desktop_transport = RecordingDesktopTransport::new();
        let pty_transport = StubPtyTransport::new();
        let response = handle_control_pipe_payload(
            &desktop_transport,
            &pty_transport,
            &pairing_payload_with_token(Some("test-control-token")),
            None,
        );
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");
        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["paired"], true);
        assert_eq!(value["result"]["scope"], "external_control_pipe");
        assert_eq!(value["result"]["version"], 1);
        assert_eq!(
            *desktop_transport.calls.lock().expect("calls lock"),
            0,
            "pairing confirm must not call the desktop transport"
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_pairing_confirm_accepts_previous_token_until_current_auth() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "previous-rotate-token").expect("previous token");
        harden_existing_token_file_for_test(&path);
        bootstrap_control_pipe_token().expect("bootstrap");
        let current = fs::read_to_string(&path).expect("current token");
        assert_ne!(current, "previous-rotate-token");

        let pty_transport = StubPtyTransport::new();
        let previous_response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some("previous-rotate-token")),
            None,
        );
        let previous_value: Value =
            serde_json::from_slice(&previous_response).expect("previous json");
        assert_eq!(previous_value["result"]["paired"], true);

        let current_response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some(&current)),
            None,
        );
        let current_value: Value = serde_json::from_slice(&current_response).expect("current json");
        assert_eq!(current_value["result"]["paired"], true);

        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some("previous-rotate-token")),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_pairing_confirm_rejects_previous_token_after_ttl() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "previous-ttl-token").expect("previous token");
        harden_existing_token_file_for_test(&path);
        bootstrap_control_pipe_token().expect("bootstrap");
        expire_previous_control_pipe_token_for_test();

        let pty_transport = StubPtyTransport::new();
        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some("previous-ttl-token")),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);

        let current = fs::read_to_string(&path).expect("current token");
        let accepted = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &pairing_payload_with_token(Some(&current)),
            None,
        );
        let accepted_value: Value = serde_json::from_slice(&accepted).expect("accepted json");
        assert_eq!(accepted_value["result"]["paired"], true);
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_contract_rejects_invalid_jsonrpc_version() {
        let payload = br#"{"jsonrpc":"1.0","id":1,"method":"desktop.control_plane.contract"}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
    }

    #[test]
    fn control_pipe_routes_voice_capture_status_to_desktop_handler() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.voice.capture_status","auth":{"token":"test-control-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["capture_mode"], "browser_fallback");
        assert_eq!(value["result"]["native"]["available"], false);
        assert_eq!(value["result"]["browser_fallback"]["expected"], true);
    }

    #[test]
    fn control_pipe_rejects_method_when_token_env_is_missing() {
        let _guard = set_control_pipe_token_for_test(None);
        let payload =
            br#"{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
        assert!(
            !value["error"]["message"]
                .as_str()
                .expect("error message")
                .contains("auth.scope")
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_rejects_method_when_token_is_wrong() {
        let _guard = set_control_pipe_token_for_test(Some("expected-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1"},"auth":{"token":"wrong-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
        assert!(
            !value["error"]["message"]
                .as_str()
                .expect("error message")
                .contains("auth.scope")
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_rejects_invalid_json() {
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, b"{", None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], Value::Null);
        assert_eq!(value["error"]["code"], JSON_RPC_PARSE_ERROR);
    }

    #[test]
    fn control_pipe_name_is_named_pipe_not_localhost_transport() {
        assert_eq!(WINSMUX_CONTROL_PIPE_NAME, r"\\.\pipe\winsmux-control");
        assert!(!WINSMUX_CONTROL_PIPE_NAME.contains("localhost"));
        assert!(!WINSMUX_CONTROL_PIPE_NAME.contains("ws://"));
        assert!(!WINSMUX_CONTROL_PIPE_NAME.contains("http://"));
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_startup_create_failure_disables_server_loop() {
        assert!(is_control_pipe_startup_error(
            "CreateNamedPipeW failed with 5"
        ));
        assert!(is_control_pipe_startup_error(
            "control-pipe object SD failed"
        ));
        assert!(!is_control_pipe_startup_error("ReadFile failed with 109"));
    }

    #[test]
    fn control_pipe_rejects_project_dir_override() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.summary.snapshot","params":{"projectDir":"C:/other"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_PARAMS);
    }

    #[test]
    fn control_pipe_routes_pty_methods_to_pty_handler() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload =
            br#"{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1"},"auth":{"token":"test-control-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["paneId"], "pane-1");
        assert_eq!(value["result"]["output"], "ready");
        assert_eq!(
            pty_transport
                .commands
                .lock()
                .expect("commands lock")
                .as_slice(),
            [PtyCommand::Capture {
                pane_id: "pane-1".to_string(),
                lines: None
            }]
        );
    }

    #[test]
    fn control_pipe_routes_operator_methods_to_operator_pane_only() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.operator.submit","params":{"message":"Run the approved cleanup once"},"auth":{"token":"test-control-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["ok"], true);
        assert_eq!(
            pty_transport
                .commands
                .lock()
                .expect("commands lock")
                .as_slice(),
            [PtyCommand::OperatorSubmit {
                text: "Run the approved cleanup once\r".to_string(),
                submit_after_paste: false,
            }]
        );
    }

    #[test]
    fn control_pipe_rejects_operator_method_pane_override() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.operator.snapshot","params":{"paneId":"worker-1","lines":40},"auth":{"token":"test-control-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_PARAMS);
        assert!(value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("operator pane"));
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_rejects_project_dir_override_for_pty_methods() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1","projectDir":"C:/other"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_PARAMS);
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_blocks_editor_read() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.editor.read","params":{"path":"README.md"},"auth":{"token":"test-control-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_METHOD_NOT_FOUND);
    }

    #[test]
    fn control_pipe_contract_omitted_params_returns_v2() {
        let empty_params =
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{}}"#;
        assert_tokenless_contract_result_is_live_document(
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#,
        );
        assert_tokenless_contract_result_is_live_document(empty_params);
    }

    #[test]
    fn control_pipe_contract_supported_version_returns_v2() {
        assert_tokenless_contract_result_is_live_document(
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":2}}"#,
        );
    }

    #[test]
    fn control_pipe_contract_rejects_unsupported_version() {
        let cases: &[&[u8]] = &[
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":3}}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":1}}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":0}}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":"2"}}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":null}}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":[]}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":null}"#,
            br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract","params":{"version":2,"extra":true}}"#,
        ];
        for payload in cases {
            assert_tokenless_contract_rejects_unsupported(payload);
        }
    }

    fn assert_tokenless_contract_result_is_live_document(payload: &[u8]) {
        let desktop_transport = RecordingDesktopTransport::new();
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&desktop_transport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert!(
            value.get("error").is_none(),
            "supported contract request must not error: {value}"
        );
        assert_eq!(value["result"], control_pipe_contract());
        assert_eq!(
            *desktop_transport.calls.lock().expect("calls lock"),
            0,
            "contract discovery must not reach the desktop transport"
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    fn assert_tokenless_contract_rejects_unsupported(payload: &[u8]) {
        let desktop_transport = RecordingDesktopTransport::new();
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&desktop_transport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1, "{}", String::from_utf8_lossy(payload));
        assert_eq!(
            value["error"]["code"],
            JSON_RPC_INVALID_PARAMS,
            "{}",
            String::from_utf8_lossy(payload)
        );
        assert_eq!(
            value["error"]["message"],
            UNSUPPORTED_CONTROL_PIPE_CONTRACT_VERSION,
            "{}",
            String::from_utf8_lossy(payload)
        );
        assert!(
            value.get("result").is_none(),
            "unsupported version must not return a document: {value}"
        );
        assert_eq!(
            *desktop_transport.calls.lock().expect("calls lock"),
            0,
            "unsupported contract version must not reach the desktop transport"
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_rejects_unknown_method() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.does.not.exist","auth":{"token":"test-control-token"}}"#;
        let desktop_transport = RecordingDesktopTransport::new();
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&desktop_transport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_METHOD_NOT_FOUND);
        assert!(value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("Control pipe method is not exposed"));
        assert_eq!(
            *desktop_transport.calls.lock().expect("calls lock"),
            0,
            "unknown methods must not reach the desktop transport"
        );
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_rejects_every_excluded_internal_method() {
        let _guard = set_control_pipe_token_for_test(Some("test-control-token"));
        for method in CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS {
            let payload = serde_json::to_vec(&json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": method,
                "auth": { "token": "test-control-token" },
            }))
            .expect("excluded method payload");
            let desktop_transport = RecordingDesktopTransport::new();
            let pty_transport = StubPtyTransport::new();
            let response =
                handle_control_pipe_payload(&desktop_transport, &pty_transport, &payload, None);
            let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

            assert_eq!(value["id"], 1, "{method}");
            assert_eq!(
                value["error"]["code"],
                JSON_RPC_METHOD_NOT_FOUND,
                "{method}"
            );
            assert!(
                value["error"]["message"]
                    .as_str()
                    .expect("error message")
                    .contains("Control pipe method is not exposed"),
                "{method}"
            );
            assert_eq!(
                *desktop_transport.calls.lock().expect("calls lock"),
                0,
                "{method} must not reach the desktop transport"
            );
            assert!(
                pty_transport
                    .commands
                    .lock()
                    .expect("commands lock")
                    .is_empty(),
                "{method} must not reach the pty transport"
            );
        }
    }

    #[test]
    fn control_pipe_bootstrap_creates_token_file() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        assert!(!path.exists());
        bootstrap_control_pipe_token().expect("bootstrap");
        let contents = fs::read_to_string(&path).expect("token file");
        assert_eq!(contents.len(), CONTROL_PIPE_TOKEN_RANDOM_BYTES * 2);
        assert!(contents.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert!(contents.chars().all(|ch| !ch.is_whitespace()));
        assert!(control_pipe_auth_is_available());
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_token_file_uses_user_only_dacl() {
        let _guard = isolate_control_pipe_paths_for_test();
        bootstrap_control_pipe_token().expect("bootstrap");
        let path = control_pipe_token_file_path().expect("token path");
        assert!(
            control_pipe_token_file_dacl_is_user_only(&path).expect("dacl query"),
            "token file DACL must be user-only"
        );
        let dir = path.parent().expect("token dir");
        assert!(
            control_pipe_token_file_dacl_is_user_only(dir).expect("dir dacl query"),
            "token directory DACL must be user-only"
        );
    }

    #[test]
    fn control_pipe_trusted_previous_token_is_captured() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "trusted-previous-token").expect("token a");
        harden_existing_token_file_for_test(&path);
        assert_eq!(
            read_trusted_previous_control_pipe_token().as_deref(),
            Some("trusted-previous-token")
        );
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_trusted_previous_survives_path_replace() {
        use windows_sys::Win32::Foundation::CloseHandle;

        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "token-a-held-handle").expect("token a");
        harden_existing_token_file_for_test(&path);

        let handle = open_control_pipe_token_read_handle(&path).expect("production open");

        // MOVEFILE_REPLACE_EXISTING on an open dest returns ERROR_ACCESS_DENIED (5)
        // even with FILE_SHARE_DELETE. Steal the name, then plant B at the same path.
        let stolen = path.with_extension("stolen");
        fs::rename(&path, &stolen).expect("steal name while handle held");
        fs::write(&path, "token-b-replaced-path").expect("token b at stolen name");
        assert_eq!(
            fs::read_to_string(&path).expect("path after replace").trim(),
            "token-b-replaced-path"
        );
        assert!(
            control_pipe_token_handle_dacl_is_user_only(handle).expect("handle dacl"),
            "held handle DACL must stay the opened file"
        );
        assert_eq!(
            read_control_pipe_token_from_handle(handle).as_deref(),
            Some("token-a-held-handle"),
            "handle must not follow the replaced path"
        );
        unsafe {
            CloseHandle(handle);
        }
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_object_uses_user_only_dacl() {
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};

        let name = format!(
            r"\\.\pipe\winsmux-control-dacl-{}-{}",
            std::process::id(),
            CONTROL_PIPE_TEST_ISOLATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        );
        let server = create_user_only_named_pipe(&name).expect("create user-only pipe");
        assert_ne!(server, INVALID_HANDLE_VALUE);
        let dacl_ok = control_pipe_token_file_dacl_is_user_only(Path::new(&name))
            .expect("pipe dacl query");
        assert!(dacl_ok, "named-pipe object DACL must be user-only");
        unsafe {
            CloseHandle(server);
        }
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_create_fails_closed_without_user_only_sd() {
        struct ResetObjectSd;
        impl Drop for ResetObjectSd {
            fn drop(&mut self) {
                FORCE_CONTROL_PIPE_OBJECT_SD_FAILURE
                    .store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _reset = ResetObjectSd;
        FORCE_CONTROL_PIPE_OBJECT_SD_FAILURE.store(true, std::sync::atomic::Ordering::SeqCst);
        let err = create_user_only_named_pipe(r"\\.\pipe\winsmux-control-dacl-force-sd")
            .expect_err("object SD failure must not listen");
        assert!(
            err.starts_with("control-pipe object SD failed"),
            "got {err}"
        );
        assert!(is_control_pipe_startup_error(&err));
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_same_user_client_still_opens() {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::Storage::FileSystem::CreateFileW;

        const GENERIC_READ: u32 = 0x8000_0000;
        const GENERIC_WRITE: u32 = 0x4000_0000;
        const OPEN_EXISTING: u32 = 3;

        let name = format!(
            r"\\.\pipe\winsmux-control-dacl-client-{}-{}",
            std::process::id(),
            CONTROL_PIPE_TEST_ISOLATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        );
        let server = create_user_only_named_pipe(&name).expect("create user-only pipe");
        let name_wide: Vec<u16> = OsStr::new(&name).encode_wide().chain(Some(0)).collect();
        let client = unsafe {
            CreateFileW(
                name_wide.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                core::ptr::null_mut(),
                OPEN_EXISTING,
                0,
                core::ptr::null_mut(),
            )
        };
        let client_err = unsafe { GetLastError() };
        assert_ne!(
            client, INVALID_HANDLE_VALUE,
            "same-user CreateFileW must open the user-only pipe (GetLastError={client_err})"
        );
        unsafe {
            CloseHandle(client);
            CloseHandle(server);
        }
    }

    #[test]
    fn control_pipe_ignores_planted_token_files() {
        let _guard = isolate_control_pipe_paths_for_test();
        let local = PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"));
        let planted_repo = local.join("repo").join(".winsmux").join("token");
        let planted_wrong_name = local.join("winsmux").join("control-pipe").join("token.bak");
        let planted_temp = std::env::temp_dir()
            .join(format!("winsmux-planted-{}-token", std::process::id()))
            .join("winsmux")
            .join("control-pipe")
            .join("token");
        fs::create_dir_all(planted_repo.parent().expect("repo parent")).expect("repo dir");
        fs::create_dir_all(planted_wrong_name.parent().expect("wrong parent")).expect("wrong dir");
        fs::create_dir_all(planted_temp.parent().expect("temp parent")).expect("temp dir");
        fs::write(&planted_repo, "planted-repo-token").expect("repo plant");
        fs::write(&planted_wrong_name, "planted-wrong-name-token").expect("name plant");
        fs::write(&planted_temp, "planted-temp-token").expect("temp plant");

        let exact = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(exact.parent().expect("exact parent")).expect("exact dir");
        fs::write(&exact, "exact-file-token").expect("exact token");
        harden_existing_token_file_for_test(&exact);

        let pty_transport = StubPtyTransport::new();
        for planted in [
            "planted-repo-token",
            "planted-wrong-name-token",
            "planted-temp-token",
        ] {
            let response = handle_control_pipe_payload(
                &StubDesktopTransport,
                &pty_transport,
                &capture_payload_with_token(planted),
                None,
            );
            let value: Value = serde_json::from_slice(&response).expect("json");
            assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        }

        let response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("exact-file-token"),
            None,
        );
        let value: Value = serde_json::from_slice(&response).expect("json");
        assert_eq!(value["result"]["paneId"], "pane-1");
        let _ = fs::remove_dir_all(
            planted_temp
                .parent()
                .and_then(|p| p.parent())
                .and_then(|p| p.parent())
                .unwrap_or(planted_temp.as_path()),
        );
    }

    #[test]
    fn control_pipe_rotate_accepts_previous_until_current_auth() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "previous-rotate-token").expect("previous token");
        harden_existing_token_file_for_test(&path);
        bootstrap_control_pipe_token().expect("bootstrap");
        let current = fs::read_to_string(&path).expect("current token");
        assert_ne!(current, "previous-rotate-token");

        let pty_transport = StubPtyTransport::new();
        let previous_response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("previous-rotate-token"),
            None,
        );
        let previous_value: Value =
            serde_json::from_slice(&previous_response).expect("previous json");
        assert_eq!(previous_value["result"]["paneId"], "pane-1");

        let current_response = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token(&current),
            None,
        );
        let current_value: Value = serde_json::from_slice(&current_response).expect("current json");
        assert_eq!(current_value["result"]["paneId"], "pane-1");

        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("previous-rotate-token"),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);
    }

    #[test]
    fn control_pipe_untrusted_previous_token_is_not_accepted() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "planted-previous-token").expect("planted token");
        assert!(!existing_token_file_is_trusted(&path));
        bootstrap_control_pipe_token().expect("bootstrap");
        let current = fs::read_to_string(&path).expect("current token");
        assert_ne!(current, "planted-previous-token");
        #[cfg(windows)]
        assert!(
            existing_token_file_is_trusted(&path),
            "replaced dest must keep the user-only create DACL"
        );
        assert!(
            leftover_control_pipe_token_temps(path.parent().expect("parent")).is_empty(),
            "atomic replace must not leave token.*.tmp"
        );

        let pty_transport = StubPtyTransport::new();
        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("planted-previous-token"),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);

        let accepted = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token(&current),
            None,
        );
        let accepted_value: Value = serde_json::from_slice(&accepted).expect("accepted json");
        assert_eq!(accepted_value["result"]["paneId"], "pane-1");
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_foreign_owner_previous_token_is_not_accepted() {
        struct ResetOwnerMismatch;
        impl Drop for ResetOwnerMismatch {
            fn drop(&mut self) {
                FORCE_CONTROL_PIPE_OWNER_MISMATCH.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _reset = ResetOwnerMismatch;
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "planted-foreign-owner-token").expect("planted token");
        apply_user_only_dacl(&path).expect("user-only DACL");
        assert!(
            existing_token_file_is_trusted(&path),
            "same-owner user-only DACL is the positive control"
        );
        FORCE_CONTROL_PIPE_OWNER_MISMATCH.store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(
            !existing_token_file_is_trusted(&path),
            "user-only DACL with a foreign owner must not be trusted"
        );

        bootstrap_control_pipe_token().expect("bootstrap");
        let current = fs::read_to_string(&path).expect("current token");
        assert_ne!(current, "planted-foreign-owner-token");

        let pty_transport = StubPtyTransport::new();
        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("planted-foreign-owner-token"),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);

        let accepted = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token(&current),
            None,
        );
        let accepted_value: Value = serde_json::from_slice(&accepted).expect("accepted json");
        assert_eq!(accepted_value["result"]["paneId"], "pane-1");
    }

    #[test]
    fn control_pipe_drops_previous_token_after_process_ttl() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "previous-ttl-token").expect("previous token");
        harden_existing_token_file_for_test(&path);
        bootstrap_control_pipe_token().expect("bootstrap");
        expire_previous_control_pipe_token_for_test();

        let pty_transport = StubPtyTransport::new();
        let rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("previous-ttl-token"),
            None,
        );
        let rejected_value: Value = serde_json::from_slice(&rejected).expect("rejected json");
        assert_eq!(rejected_value["error"]["code"], JSON_RPC_INVALID_REQUEST);

        let current = fs::read_to_string(&path).expect("current token");
        let accepted = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token(&current),
            None,
        );
        let accepted_value: Value = serde_json::from_slice(&accepted).expect("accepted json");
        assert_eq!(accepted_value["result"]["paneId"], "pane-1");
    }

    #[test]
    fn control_pipe_env_token_wins_over_token_file() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "file-token-value").expect("file token");
        std::env::set_var(WINSMUX_CONTROL_PIPE_TOKEN_ENV, "env-token-value");

        let pty_transport = StubPtyTransport::new();
        let file_rejected = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("file-token-value"),
            None,
        );
        let file_value: Value = serde_json::from_slice(&file_rejected).expect("file json");
        assert_eq!(file_value["error"]["code"], JSON_RPC_INVALID_REQUEST);

        let env_accepted = handle_control_pipe_payload(
            &StubDesktopTransport,
            &pty_transport,
            &capture_payload_with_token("env-token-value"),
            None,
        );
        let env_value: Value = serde_json::from_slice(&env_accepted).expect("env json");
        assert_eq!(env_value["result"]["paneId"], "pane-1");
    }

    #[test]
    fn control_pipe_does_not_rotate_until_exclusive_pipe_is_acquired() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "keep-existing-token").expect("existing token");

        let mut bootstrapped = false;
        assert_eq!(
            fs::read_to_string(&path).expect("unread token"),
            "keep-existing-token"
        );
        assert!(control_pipe_auth_state_lock().is_none());

        bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect("first exclusive bootstrap");
        assert!(bootstrapped);
        let current = fs::read_to_string(&path).expect("rotated token");
        assert_ne!(current, "keep-existing-token");
        assert_eq!(current.len(), CONTROL_PIPE_TOKEN_RANDOM_BYTES * 2);

        bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect("second exclusive bootstrap is a no-op");
        assert_eq!(fs::read_to_string(&path).expect("stable token"), current);
    }

    #[test]
    fn control_pipe_token_file_is_user_only_after_first_write() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        bootstrap_control_pipe_token().expect("bootstrap");
        assert!(path.is_file());
        #[cfg(windows)]
        assert!(
            existing_token_file_is_trusted(&path),
            "first write must create the dest with a user-only DACL"
        );
        assert!(
            leftover_control_pipe_token_temps(path.parent().expect("parent")).is_empty(),
            "first write must not leave token.*.tmp"
        );
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_bootstrap_fail_closed_when_dacl_hardening_fails() {
        struct ResetDaclFailure;
        impl Drop for ResetDaclFailure {
            fn drop(&mut self) {
                FORCE_CONTROL_PIPE_DACL_FAILURE.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _reset = ResetDaclFailure;
        let _guard = isolate_control_pipe_paths_for_test();
        FORCE_CONTROL_PIPE_DACL_FAILURE.store(true, std::sync::atomic::Ordering::SeqCst);
        let path = control_pipe_token_file_path().expect("token path");
        let mut bootstrapped = false;
        let err = bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect_err("hardening failure must fail closed");
        assert!(!bootstrapped);
        assert!(!path.exists(), "unhardened token file must be removed");
        if let Some(parent) = path.parent() {
            assert!(
                leftover_control_pipe_token_temps(parent).is_empty(),
                "fail-closed DACL must not leave a temp token file"
            );
        }
        assert!(control_pipe_auth_state_lock().is_none());
        assert!(!control_pipe_auth_is_available());
        assert!(is_control_pipe_startup_error(&err));
    }

    #[test]
    fn control_pipe_ui_enabled_before_token_file_exists() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        assert!(!path.exists());
        assert!(!control_pipe_auth_is_available());
        assert!(!control_pipe_ui_is_enabled());
        mark_control_pipe_server_intended();
        assert!(!control_pipe_auth_is_available());
        assert!(control_pipe_ui_is_enabled());
    }

    #[test]
    fn control_pipe_env_token_skips_file_rotate_after_exclusive_pipe() {
        let _guard = set_control_pipe_token_for_test(Some("env-token-value"));
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "keep-file-token").expect("file token");
        let mut bootstrapped = false;
        bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect("env token must not require file rotate");
        assert!(bootstrapped);
        assert_eq!(
            fs::read_to_string(&path).expect("unchanged file token"),
            "keep-file-token"
        );
        assert!(control_pipe_auth_state_lock().is_none());
        assert!(control_pipe_auth_is_available());
    }

    #[test]
    #[cfg(windows)]
    fn control_pipe_env_token_survives_file_dacl_hardening_failure() {
        struct ResetDaclFailure;
        impl Drop for ResetDaclFailure {
            fn drop(&mut self) {
                FORCE_CONTROL_PIPE_DACL_FAILURE.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _reset = ResetDaclFailure;
        let _guard = set_control_pipe_token_for_test(Some("env-token-value"));
        FORCE_CONTROL_PIPE_DACL_FAILURE.store(true, std::sync::atomic::Ordering::SeqCst);
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "keep-file-token").expect("file token");
        let mut bootstrapped = false;
        bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect("env token launch must not fail closed on file DACL");
        assert!(bootstrapped);
        assert_eq!(
            fs::read_to_string(&path).expect("unchanged file token"),
            "keep-file-token"
        );
        assert!(control_pipe_auth_is_available());
    }

    #[test]
    fn control_pipe_operator_snapshot_accepts_file_token() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "operator-file-token").expect("file token");
        harden_existing_token_file_for_test(&path);
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.operator.snapshot","params":{"lines":40},"auth":{"token":"operator-file-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("json");
        assert_eq!(value["id"], 1);
        assert!(value.get("error").is_none() || value["error"].is_null());
    }

    #[test]
    fn control_pipe_operator_snapshot_rejects_untrusted_file_token() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "planted-file-token").expect("planted file");
        assert!(
            control_pipe_auth_is_available(),
            "existence is not authorization"
        );
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.operator.snapshot","params":{"lines":40},"auth":{"token":"planted-file-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("json");
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_REQUEST);
        assert!(value["error"]["message"]
            .as_str()
            .expect("error message")
            .contains(WINSMUX_CONTROL_PIPE_TOKEN_ENV));
        assert!(pty_transport
            .commands
            .lock()
            .expect("commands lock")
            .is_empty());
    }

    #[test]
    fn control_pipe_revoke_on_exit_deletes_owned_token_file() {
        let _guard = isolate_control_pipe_paths_for_test();
        bootstrap_control_pipe_token().expect("bootstrap");
        let path = control_pipe_token_file_path().expect("token path");
        let current = fs::read_to_string(&path).expect("owned token");
        assert!(control_pipe_auth_state_lock().is_some());

        revoke_control_pipe_token_on_exit();

        assert!(!path.exists(), "owned token file must be deleted");
        assert!(control_pipe_auth_state_lock().is_none());
        assert!(!authorize_rotated_or_file_token(&current));
    }

    #[test]
    fn control_pipe_revoke_on_exit_leaves_unowned_file() {
        let _guard = isolate_control_pipe_paths_for_test();
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "planted-token").expect("planted file");
        assert!(control_pipe_auth_state_lock().is_none());

        revoke_control_pipe_token_on_exit();

        assert_eq!(
            fs::read_to_string(&path).expect("planted file remains"),
            "planted-token"
        );
        assert!(control_pipe_auth_state_lock().is_none());
    }

    #[test]
    fn control_pipe_revoke_on_exit_leaves_env_skip_planted_file() {
        let _guard = set_control_pipe_token_for_test(Some("env-token-value"));
        let path = control_pipe_token_file_path().expect("token path");
        fs::create_dir_all(path.parent().expect("parent")).expect("token dir");
        fs::write(&path, "keep-file-token").expect("file token");
        let mut bootstrapped = false;
        bootstrap_control_pipe_token_after_exclusive_pipe(&mut bootstrapped)
            .expect("env skip");
        assert!(bootstrapped);
        assert!(control_pipe_auth_state_lock().is_none());

        revoke_control_pipe_token_on_exit();

        assert_eq!(
            fs::read_to_string(&path).expect("env-skip planted file remains"),
            "keep-file-token"
        );
    }

    #[test]
    fn control_pipe_bootstrap_recovers_after_revoke() {
        let _guard = isolate_control_pipe_paths_for_test();
        bootstrap_control_pipe_token().expect("bootstrap");
        let path = control_pipe_token_file_path().expect("token path");
        let first = fs::read_to_string(&path).expect("first token");
        revoke_control_pipe_token_on_exit();
        assert!(!path.exists());

        bootstrap_control_pipe_token().expect("bootstrap after revoke");
        let second = fs::read_to_string(&path).expect("new token");
        assert_ne!(second, first);
        assert!(authorize_rotated_or_file_token(&second));
        #[cfg(windows)]
        assert!(
            existing_token_file_is_trusted(&path),
            "restart after revoke must recreate a user-only token file"
        );
    }
}
