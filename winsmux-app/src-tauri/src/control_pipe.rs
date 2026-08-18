use crate::desktop_backend::{
    handle_desktop_json_rpc, DesktopCommandTransport, DesktopJsonRpcRequest, PwshScriptTransport,
};
use crate::pty_backend::{
    handle_pty_json_rpc, PtyCommandTransport, PtyJsonRpcRequest, OPERATOR_CONTROL_PIPE_METHODS,
    PTY_CONTROL_PIPE_METHODS,
};
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
    control_pipe_auth_is_available()
        || CONTROL_PIPE_SERVER_INTENDED.load(Ordering::SeqCst)
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
    fs::write(path, token.as_bytes())
        .map_err(|_| "control-pipe token rotate failed".to_string())?;
    #[cfg(windows)]
    {
        if let Err(err) = apply_user_only_dacl(path) {
            let _ = fs::remove_file(path);
            return Err(err);
        }
        if let Err(err) = apply_user_only_dacl(parent) {
            let _ = fs::remove_file(path);
            return Err(err);
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
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
    if !existing_token_file_is_trusted(&path) {
        return None;
    }
    read_control_pipe_token_file()
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
    match read_control_pipe_token_file() {
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

#[cfg(windows)]
fn apply_user_only_dacl(path: &Path) -> Result<(), String> {
    #[cfg(test)]
    if FORCE_CONTROL_PIPE_DACL_FAILURE.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("control-pipe token rotate failed".to_string());
    }
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SetNamedSecurityInfoW,
        SDDL_REVISION_1, SE_FILE_OBJECT,
    };
    use windows_sys::Win32::Security::{
        GetSecurityDescriptorDacl, ACL, DACL_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
    };

    let sid = current_user_sid_string()?;
    // GENERIC_ALL maps for both files and directories. FILE_ALL_ACCESS (FA) on a
    // directory can fail SetNamedSecurityInfoW on GitHub-hosted Windows images.
    let sddl = format!("D:P(A;;GA;;;{sid})");
    let sddl_wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let mut path_wide = path_to_wide(path);
    unsafe {
        let mut sd: PSECURITY_DESCRIPTOR = core::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_wide.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            core::ptr::null_mut(),
        ) == 0
        {
            return Err("control-pipe token rotate failed".to_string());
        }
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
fn control_pipe_token_file_dacl_is_user_only(path: &Path) -> Result<bool, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_SUCCESS, HANDLE};
    use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        AclSizeInformation, EqualSid, GetAce, GetAclInformation, GetTokenInformation, TokenUser,
        ACE_HEADER, ACL, ACL_SIZE_INFORMATION, DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
        PSID, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

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
            DACL_SECURITY_INFORMATION,
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
        CloseHandle(token);
        let token_user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let equal = EqualSid(sid, token_user.User.Sid) != 0;
        local_free_ptr(sd);
        Ok(equal)
    }
}

const JSON_RPC_PARSE_ERROR: i32 = -32700;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_REQUEST: i32 = -32600;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_INTERNAL_ERROR: i32 = -32603;

pub const DESKTOP_CONTROL_PIPE_METHODS: &[&str] = &[
    "desktop.control_plane.contract",
    "desktop.summary.snapshot",
    "desktop.run.explain",
    "desktop.run.compare",
    "desktop.run.promote",
    "desktop.run.pick_winner",
    "desktop.voice.capture_status",
];

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
        return serialize_control_pipe_result(request.id, control_pipe_contract());
    }

    if !is_authorized_control_pipe_request(&request_value) {
        return serialize_control_pipe_error(
            request_id,
            JSON_RPC_INVALID_REQUEST,
            format!(
                "Control pipe method requires a valid {} value in auth.token",
                WINSMUX_CONTROL_PIPE_TOKEN_ENV
            ),
        );
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
        .copied()
        .collect()
}

fn control_pipe_contract() -> Value {
    json!({
    "version": 1,
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
    },
    "methods": control_pipe_methods(),
    "desktop_methods": DESKTOP_CONTROL_PIPE_METHODS,
    "pty_methods": PTY_CONTROL_PIPE_METHODS,
    "operator_methods": OPERATOR_CONTROL_PIPE_METHODS,
    "internal_desktop_methods_excluded": CONTROL_PIPE_EXCLUDED_INTERNAL_DESKTOP_METHODS,
    })
}

fn is_authorized_control_pipe_request(request_value: &Value) -> bool {
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
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FlushFileBuffers, ReadFile, WriteFile, FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX,
    };
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_MESSAGE,
        PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    struct PipeHandle(HANDLE);

    impl Drop for PipeHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    let pipe_name: Vec<u16> = OsStr::new(WINSMUX_CONTROL_PIPE_NAME)
        .encode_wide()
        .chain(Some(0))
        .collect();

    let handle = unsafe {
        CreateNamedPipeW(
            pipe_name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            1024 * 1024,
            1024 * 1024,
            0,
            null_mut(),
        )
    };

    if handle == INVALID_HANDLE_VALUE {
        return Err(format!("CreateNamedPipeW failed with {}", unsafe {
            GetLastError()
        }));
    }
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

    #[test]
    fn control_pipe_returns_external_contract_matching_allowlist() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["version"], 1);
        assert_eq!(value["result"]["scope"], "external_control_pipe");
        assert_eq!(value["result"]["transport"], "named_pipe_json_rpc");
        assert_eq!(value["result"]["pipe"], WINSMUX_CONTROL_PIPE_NAME);
        assert_eq!(value["result"]["localhost_http"], false);
        assert_eq!(value["result"]["websocket"], false);
        assert_eq!(value["result"]["auth"]["required_for_methods"], true);
        assert_eq!(
            value["result"]["auth"]["token_env"],
            WINSMUX_CONTROL_PIPE_TOKEN_ENV
        );
        assert_eq!(
            value["result"]["auth"]["token_file"],
            WINSMUX_CONTROL_PIPE_TOKEN_FILE_TEMPLATE
        );
        assert_eq!(value["result"]["auth"]["request_field"], "auth.token");
        assert_eq!(
            value["result"]["desktop_methods"],
            json!(DESKTOP_CONTROL_PIPE_METHODS)
        );
        assert_eq!(
            value["result"]["pty_methods"],
            json!(PTY_CONTROL_PIPE_METHODS)
        );
        assert_eq!(
            value["result"]["operator_methods"],
            json!(OPERATOR_CONTROL_PIPE_METHODS)
        );
        assert_eq!(value["result"]["methods"], json!(control_pipe_methods()));
        assert!(!value["result"]["methods"]
            .as_array()
            .expect("methods")
            .iter()
            .any(|method| method.as_str() == Some("desktop.editor.read")));
        assert!(!value["result"]["methods"]
            .as_array()
            .expect("methods")
            .iter()
            .any(|method| method.as_str() == Some("desktop.explorer.list")));
        assert!(value["result"]["methods"]
            .as_array()
            .expect("methods")
            .iter()
            .any(|method| method.as_str() == Some("pty.capture")));
        assert!(value["result"]["methods"]
            .as_array()
            .expect("methods")
            .iter()
            .any(|method| method.as_str() == Some("desktop.operator.snapshot")));
        assert!(value["result"]["methods"]
            .as_array()
            .expect("methods")
            .iter()
            .any(|method| method.as_str() == Some("desktop.operator.submit")));
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
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.operator.snapshot","params":{"lines":40},"auth":{"token":"operator-file-token"}}"#;
        let pty_transport = StubPtyTransport::new();
        let response =
            handle_control_pipe_payload(&StubDesktopTransport, &pty_transport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("json");
        assert_eq!(value["id"], 1);
        assert!(value.get("error").is_none() || value["error"].is_null());
    }
}
