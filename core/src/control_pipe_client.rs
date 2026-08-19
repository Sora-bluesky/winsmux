use std::io;

pub const AUTOMATION_CONTRACT_COMMAND: &str = "automation-contract";
pub const AUTOMATION_DISCOVER_COMMAND: &str = "automation-discover";
pub const DESKTOP_CONTROL_PIPE_NAME: &str = r"\\.\pipe\winsmux-control";
const AUTOMATION_CONTRACT_REQUEST: &[u8] =
    br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#;
const PIPE_UNAVAILABLE: &str = "desktop control pipe is not available";
const CONTROL_PIPE_TOKEN_ENV: &str = "WINSMUX_CONTROL_PIPE_TOKEN";

pub fn run_automation_contract_command() -> io::Result<()> {
    let response = send_control_pipe_request(AUTOMATION_CONTRACT_REQUEST)?;
    let value: serde_json::Value = serde_json::from_slice(&response).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("desktop control pipe returned invalid JSON: {err}"),
        )
    })?;
    if let Some(message) = value
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(|message| message.as_str())
    {
        return Err(io::Error::new(io::ErrorKind::Other, message.to_string()));
    }
    let result = value.get("result").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "desktop control pipe returned no JSON-RPC result",
        )
    })?;
    println!(
        "{}",
        serde_json::to_string(result).map_err(|err| io::Error::new(
            io::ErrorKind::InvalidData,
            format!("desktop control pipe result could not be serialized: {err}"),
        ))?
    );
    Ok(())
}

pub fn run_automation_discover_command() -> io::Result<()> {
    let auth_source = discover_auth_source();
    let mut desktop_running = false;
    let mut contract_version = serde_json::Value::Null;
    match send_control_pipe_request(AUTOMATION_CONTRACT_REQUEST) {
        Ok(response) => {
            if let Some(version) = contract_version_from_pipe_response(&response) {
                desktop_running = true;
                contract_version = version;
            }
        }
        Err(_) => {}
    }
    let connect_ready = desktop_running && auth_source != "none";
    let document = serde_json::json!({
        "desktop_running": desktop_running,
        "pipe": DESKTOP_CONTROL_PIPE_NAME,
        "contract_version": contract_version,
        "auth_source": auth_source,
        "connect_ready": connect_ready,
    });
    println!(
        "{}",
        serde_json::to_string(&document).map_err(|err| io::Error::new(
            io::ErrorKind::InvalidData,
            format!("automation discover result could not be serialized: {err}"),
        ))?
    );
    if desktop_running {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE))
    }
}

fn discover_auth_source() -> &'static str {
    match std::env::var(CONTROL_PIPE_TOKEN_ENV) {
        Ok(value) if !value.trim().is_empty() => "env",
        _ if control_pipe_token_file_is_nonempty() => "file",
        _ => "none",
    }
}

fn control_pipe_token_file_is_nonempty() -> bool {
    let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") else {
        return false;
    };
    if local_app_data.is_empty() {
        return false;
    }
    let path = std::path::PathBuf::from(local_app_data)
        .join("winsmux")
        .join("control-pipe")
        .join("token");
    std::fs::read_to_string(path)
        .ok()
        .is_some_and(|contents| !contents.trim().is_empty())
}

fn contract_version_from_pipe_response(response: &[u8]) -> Option<serde_json::Value> {
    let value: serde_json::Value = serde_json::from_slice(response).ok()?;
    if value.get("jsonrpc")?.as_str()? != "2.0" {
        return None;
    }
    if value.get("id") != Some(&serde_json::json!(1)) {
        return None;
    }
    if value.get("error").is_some() {
        return None;
    }
    let result = value.get("result")?;
    if result.get("scope")?.as_str()? != "external_control_pipe" {
        return None;
    }
    let version = result.get("version")?;
    if !version.is_number() {
        return None;
    }
    Some(version.clone())
}

fn send_control_pipe_request(payload: &[u8]) -> io::Result<Vec<u8>> {
    #[cfg(windows)]
    {
        send_control_pipe_request_windows(payload)
    }
    #[cfg(not(windows))]
    {
        let _ = payload;
        Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE))
    }
}

#[cfg(windows)]
fn send_control_pipe_request_windows(payload: &[u8]) -> io::Result<Vec<u8>> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY, GENERIC_READ,
        GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, ReadFile, WriteFile, FILE_ATTRIBUTE_NORMAL, OPEN_EXISTING,
        SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
    };
    use windows_sys::Win32::System::Pipes::{SetNamedPipeHandleState, WaitNamedPipeW, PIPE_READMODE_MESSAGE};

    struct PipeHandle(HANDLE);
    impl Drop for PipeHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    let pipe_name: Vec<u16> = OsStr::new(DESKTOP_CONTROL_PIPE_NAME)
        .encode_wide()
        .chain(Some(0))
        .collect();

    let handle = unsafe {
        let mut attempt = 0;
        loop {
            let opened = CreateFileW(
                pipe_name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null_mut(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            );
            if opened != INVALID_HANDLE_VALUE {
                break opened;
            }
            let error = GetLastError();
            if error == ERROR_FILE_NOT_FOUND {
                return Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE));
            }
            if error != ERROR_PIPE_BUSY || attempt >= 20 {
                return Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE));
            }
            WaitNamedPipeW(pipe_name.as_ptr(), 250);
            attempt += 1;
        }
    };
    let pipe = PipeHandle(handle);
    let read_mode = PIPE_READMODE_MESSAGE;
    let mode_ok = unsafe { SetNamedPipeHandleState(pipe.0, &read_mode, null_mut(), null_mut()) };
    if mode_ok == 0 {
        return Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE));
    }

    let mut bytes_written = 0u32;
    let write_ok = unsafe {
        WriteFile(
            pipe.0,
            payload.as_ptr().cast(),
            payload.len() as u32,
            &mut bytes_written,
            null_mut(),
        )
    };
    if write_ok == 0 {
        return Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE));
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
        return Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE));
    }
    buffer.truncate(bytes_read as usize);
    Ok(buffer)
}

#[cfg(test)]
mod tests {
    use super::contract_version_from_pipe_response;

    #[test]
    fn contract_liveness_rejects_invalid_json() {
        assert!(contract_version_from_pipe_response(b"not-json").is_none());
    }

    #[test]
    fn contract_liveness_rejects_jsonrpc_error() {
        let body = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"nope"}}"#;
        assert!(contract_version_from_pipe_response(body).is_none());
    }

    #[test]
    fn contract_liveness_rejects_missing_version() {
        let body = br#"{"jsonrpc":"2.0","id":1,"result":{"scope":"external_control_pipe"}}"#;
        assert!(contract_version_from_pipe_response(body).is_none());
    }

    #[test]
    fn contract_liveness_rejects_result_without_jsonrpc_envelope() {
        let body = br#"{"result":{"scope":"external_control_pipe","version":1}}"#;
        assert!(contract_version_from_pipe_response(body).is_none());
    }

    #[test]
    fn contract_liveness_rejects_mismatched_request_id() {
        let body = br#"{"jsonrpc":"2.0","id":99,"result":{"scope":"external_control_pipe","version":1}}"#;
        assert!(contract_version_from_pipe_response(body).is_none());
    }

    #[test]
    fn contract_liveness_accepts_contract_result() {
        let body = br#"{"jsonrpc":"2.0","id":1,"result":{"version":1,"scope":"external_control_pipe"}}"#;
        assert_eq!(
            contract_version_from_pipe_response(body),
            Some(serde_json::json!(1))
        );
    }
}
