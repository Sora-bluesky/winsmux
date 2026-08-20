use std::io;
use std::path::PathBuf;

pub const AUTOMATION_CONTRACT_COMMAND: &str = "automation-contract";
pub const AUTOMATION_DISCOVER_COMMAND: &str = "automation-discover";
pub const AUTOMATION_PAIR_COMMAND: &str = "automation-pair";
pub const DESKTOP_CONTROL_PIPE_NAME: &str = r"\\.\pipe\winsmux-control";
const AUTOMATION_CONTRACT_REQUEST: &[u8] =
    br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#;
const PIPE_UNAVAILABLE: &str = "desktop control pipe is not available";
const PIPE_ACCESS_DENIED: &str = "desktop control pipe access denied";
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
    let send_result = send_control_pipe_request(AUTOMATION_CONTRACT_REQUEST);
    let (document, status) = discover_outcome(send_result, auth_source);
    println!(
        "{}",
        serde_json::to_string(&document).map_err(|err| io::Error::new(
            io::ErrorKind::InvalidData,
            format!("automation discover result could not be serialized: {err}"),
        ))?
    );
    status
}

pub fn run_automation_pair_command() -> io::Result<()> {
    let (auth_source, token) = match resolve_control_pipe_token() {
        Some(resolved) => resolved,
        None => {
            print_pair_document(false, "none", Some("no_token"))?;
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{CONTROL_PIPE_TOKEN_ENV} or a non-empty token file is required"),
            ));
        }
    };

    let request = pairing_confirm_request(&token)?;
    drop(token);

    match send_control_pipe_request(&request) {
        Ok(response) => match classify_pairing_response(&response) {
            PairClassify::Paired => {
                print_pair_document(true, auth_source, None)?;
                Ok(())
            }
            PairClassify::AuthRejected => {
                print_pair_document(false, auth_source, Some("auth_rejected"))?;
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "Control pipe method requires a valid {CONTROL_PIPE_TOKEN_ENV} value in auth.token"
                    ),
                ))
            }
            PairClassify::Invalid => {
                print_pair_document(false, auth_source, Some("invalid_response"))?;
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "desktop control pipe returned an invalid pairing response",
                ))
            }
        },
        Err(err) => {
            let reason = pair_pipe_error_reason(&err);
            print_pair_document(false, auth_source, Some(reason))?;
            if err.kind() == io::ErrorKind::PermissionDenied {
                Err(err)
            } else {
                Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE))
            }
        }
    }
}

fn print_pair_document(
    paired: bool,
    auth_source: &str,
    reason: Option<&str>,
) -> io::Result<()> {
    let document = serde_json::json!({
        "paired": paired,
        "pipe": DESKTOP_CONTROL_PIPE_NAME,
        "auth_source": auth_source,
        "reason": reason,
    });
    println!(
        "{}",
        serde_json::to_string(&document).map_err(|err| io::Error::new(
            io::ErrorKind::InvalidData,
            format!("automation pair result could not be serialized: {err}"),
        ))?
    );
    Ok(())
}

fn pairing_confirm_request(token: &str) -> io::Result<Vec<u8>> {
    serde_json::to_vec(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "desktop.pairing.confirm",
        "auth": { "token": token },
    }))
    .map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("pairing request could not be serialized: {err}"),
        )
    })
}

#[derive(Debug, PartialEq, Eq)]
enum PairClassify {
    Paired,
    AuthRejected,
    Invalid,
}

fn classify_pairing_response(response: &[u8]) -> PairClassify {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(response) else {
        return PairClassify::Invalid;
    };
    if value.get("jsonrpc").and_then(|item| item.as_str()) != Some("2.0") {
        return PairClassify::Invalid;
    }
    if value.get("id") != Some(&serde_json::json!(1)) {
        return PairClassify::Invalid;
    }
    if let Some(error) = value.get("error") {
        let code = error.get("code").and_then(|item| item.as_i64());
        let message = error
            .get("message")
            .and_then(|item| item.as_str())
            .unwrap_or("");
        if code == Some(-32600) && message.contains(CONTROL_PIPE_TOKEN_ENV) {
            return PairClassify::AuthRejected;
        }
        return PairClassify::Invalid;
    }
    let Some(result) = value.get("result") else {
        return PairClassify::Invalid;
    };
    if result.get("paired") != Some(&serde_json::json!(true)) {
        return PairClassify::Invalid;
    }
    if result.get("scope").and_then(|item| item.as_str()) != Some("external_control_pipe") {
        return PairClassify::Invalid;
    }
    if !result.get("version").is_some_and(|item| item.is_number()) {
        return PairClassify::Invalid;
    }
    PairClassify::Paired
}

fn discover_auth_source() -> &'static str {
    match resolve_control_pipe_token() {
        Some((source, _)) => source,
        None => "none",
    }
}

fn discover_outcome(
    send_result: io::Result<Vec<u8>>,
    auth_source: &str,
) -> (serde_json::Value, io::Result<()>) {
    let access_denied = matches!(
        &send_result,
        Err(err) if err.kind() == io::ErrorKind::PermissionDenied
    );
    let mut desktop_running = false;
    let mut contract_version = serde_json::Value::Null;
    if let Ok(response) = send_result {
        if let Some(version) = contract_version_from_pipe_response(&response) {
            desktop_running = true;
            contract_version = version;
        }
    }
    let connect_ready = desktop_running && auth_source != "none";
    let document = serde_json::json!({
        "desktop_running": desktop_running,
        "pipe": DESKTOP_CONTROL_PIPE_NAME,
        "contract_version": contract_version,
        "auth_source": auth_source,
        "connect_ready": connect_ready,
    });
    let status = if desktop_running {
        Ok(())
    } else if access_denied {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            PIPE_ACCESS_DENIED,
        ))
    } else {
        Err(io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE))
    };
    (document, status)
}

fn pair_pipe_error_reason(err: &io::Error) -> &'static str {
    if err.kind() == io::ErrorKind::PermissionDenied {
        "access_denied"
    } else {
        "pipe_unavailable"
    }
}

fn resolve_control_pipe_token() -> Option<(&'static str, String)> {
    match std::env::var(CONTROL_PIPE_TOKEN_ENV) {
        Ok(value) if !value.trim().is_empty() => Some(("env", value.trim().to_string())),
        _ => control_pipe_token_file_contents().map(|token| ("file", token)),
    }
}

fn control_pipe_token_file_contents() -> Option<String> {
    let local_app_data = std::env::var_os("LOCALAPPDATA")?;
    if local_app_data.is_empty() {
        return None;
    }
    let path = PathBuf::from(local_app_data)
        .join("winsmux")
        .join("control-pipe")
        .join("token");
    let contents = std::fs::read_to_string(path).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
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
        CloseHandle, GetLastError, ERROR_ACCESS_DENIED, ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY,
        GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
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
                return Err(map_control_pipe_createfile_error(error));
            }
            if error == ERROR_ACCESS_DENIED {
                return Err(map_control_pipe_createfile_error(error));
            }
            if error != ERROR_PIPE_BUSY || attempt >= 20 {
                return Err(map_control_pipe_createfile_error(error));
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

#[cfg(windows)]
fn map_control_pipe_createfile_error(error: u32) -> io::Error {
    use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
    if error == ERROR_ACCESS_DENIED {
        io::Error::new(io::ErrorKind::PermissionDenied, PIPE_ACCESS_DENIED)
    } else {
        io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        classify_pairing_response, contract_version_from_pipe_response, discover_outcome,
        pair_pipe_error_reason, PairClassify, PIPE_ACCESS_DENIED, PIPE_UNAVAILABLE,
    };
    #[cfg(windows)]
    use super::map_control_pipe_createfile_error;
    use std::io;

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

    #[test]
    fn pairing_classifier_accepts_static_confirm() {
        let body = br#"{"jsonrpc":"2.0","id":1,"result":{"paired":true,"scope":"external_control_pipe","version":1}}"#;
        assert_eq!(
            classify_pairing_response(body),
            PairClassify::Paired
        );
    }

    #[test]
    fn pairing_classifier_rejects_auth_error_naming_token_env() {
        let body = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Control pipe method requires a valid WINSMUX_CONTROL_PIPE_TOKEN value in auth.token"}}"#;
        assert_eq!(
            classify_pairing_response(body),
            PairClassify::AuthRejected
        );
    }

    #[test]
    fn pairing_classifier_rejects_error_without_token_env() {
        let body = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"nope"}}"#;
        assert_eq!(
            classify_pairing_response(body),
            PairClassify::Invalid
        );
    }

    #[test]
    fn pairing_classifier_rejects_mismatched_id() {
        let body = br#"{"jsonrpc":"2.0","id":99,"result":{"paired":true,"scope":"external_control_pipe","version":1}}"#;
        assert_eq!(
            classify_pairing_response(body),
            PairClassify::Invalid
        );
    }

    #[test]
    fn discover_access_denied_does_not_claim_running_or_unavailable() {
        let err = io::Error::new(io::ErrorKind::PermissionDenied, PIPE_ACCESS_DENIED);
        let (document, status) = discover_outcome(Err(err), "file");
        assert_eq!(document["desktop_running"], false);
        assert_eq!(document["connect_ready"], false);
        assert!(document.get("reason").is_none());
        let status = status.expect_err("denied discover must fail");
        assert_eq!(status.kind(), io::ErrorKind::PermissionDenied);
        let msg = status.to_string();
        assert!(msg.contains("access denied"), "{msg}");
        assert!(!msg.contains(PIPE_UNAVAILABLE), "{msg}");
    }

    #[test]
    fn discover_unavailable_stays_not_found() {
        let err = io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE);
        let (document, status) = discover_outcome(Err(err), "none");
        assert_eq!(document["desktop_running"], false);
        let status = status.expect_err("absent pipe");
        assert_eq!(status.kind(), io::ErrorKind::NotFound);
        assert!(status.to_string().contains(PIPE_UNAVAILABLE));
    }

    #[test]
    fn pair_pipe_error_splits_denied_from_unavailable() {
        let denied = io::Error::new(io::ErrorKind::PermissionDenied, PIPE_ACCESS_DENIED);
        assert_eq!(pair_pipe_error_reason(&denied), "access_denied");
        let missing = io::Error::new(io::ErrorKind::NotFound, PIPE_UNAVAILABLE);
        assert_eq!(pair_pipe_error_reason(&missing), "pipe_unavailable");
    }

    #[cfg(windows)]
    #[test]
    fn map_createfile_access_denied_is_typed_deny() {
        use windows_sys::Win32::Foundation::{
            ERROR_ACCESS_DENIED, ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY,
        };
        let denied = map_control_pipe_createfile_error(ERROR_ACCESS_DENIED);
        assert_eq!(denied.kind(), io::ErrorKind::PermissionDenied);
        assert!(denied.to_string().contains("access denied"));
        assert!(!denied.to_string().contains(PIPE_UNAVAILABLE));
        let missing = map_control_pipe_createfile_error(ERROR_FILE_NOT_FOUND);
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
        assert!(missing.to_string().contains(PIPE_UNAVAILABLE));
        let busy = map_control_pipe_createfile_error(ERROR_PIPE_BUSY);
        assert_eq!(busy.kind(), io::ErrorKind::NotFound);
        assert!(busy.to_string().contains(PIPE_UNAVAILABLE));
    }
}
