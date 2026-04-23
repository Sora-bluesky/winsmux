use crate::desktop_backend::{
    handle_desktop_json_rpc, DesktopCommandTransport, DesktopJsonRpcRequest, PwshScriptTransport,
};
use serde_json::{json, Value};

pub const WINSMUX_CONTROL_PIPE_NAME: &str = r"\\.\pipe\winsmux-control";

const JSON_RPC_PARSE_ERROR: i32 = -32700;
const JSON_RPC_METHOD_NOT_FOUND: i32 = -32601;
const JSON_RPC_INVALID_PARAMS: i32 = -32602;
const JSON_RPC_INTERNAL_ERROR: i32 = -32603;

const CONTROL_PIPE_METHODS: &[&str] = &[
    "desktop.control_plane.contract",
    "desktop.summary.snapshot",
    "desktop.run.explain",
    "desktop.run.compare",
    "desktop.run.promote",
    "desktop.run.pick_winner",
];

pub fn handle_control_pipe_payload(
    transport: &dyn DesktopCommandTransport,
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
    if !CONTROL_PIPE_METHODS.contains(&method) {
        return serialize_control_pipe_error(
            request_id,
            JSON_RPC_METHOD_NOT_FOUND,
            format!("Control pipe method is not exposed: {method}"),
        );
    }
    if has_project_dir_override(&request_value) {
        return serialize_control_pipe_error(
            request_id,
            JSON_RPC_INVALID_PARAMS,
            "Control pipe requests must not override projectDir".to_string(),
        );
    }

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

    match serde_json::to_vec(&handle_desktop_json_rpc(transport, request, project_dir)) {
        Ok(value) => value,
        Err(err) => serialize_control_pipe_error(
            Value::Null,
            JSON_RPC_INTERNAL_ERROR,
            format!("Failed to serialize JSON-RPC response: {err}"),
        ),
    }
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

#[cfg(windows)]
pub fn start_control_pipe_server() {
    std::thread::spawn(move || loop {
        if let Err(err) = serve_one_control_pipe_client() {
            eprintln!("winsmux control pipe error: {err}");
        }
    });
}

#[cfg(not(windows))]
pub fn start_control_pipe_server() {}

#[cfg(windows)]
fn serve_one_control_pipe_client() -> Result<(), String> {
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

    let response = handle_control_pipe_payload(&PwshScriptTransport, &buffer, None);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_backend::{DesktopCommand, DesktopCommandTransport};
    use serde_json::json;

    struct StubTransport;

    impl DesktopCommandTransport for StubTransport {
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

    #[test]
    fn control_pipe_routes_json_rpc_to_desktop_handler() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}"#;
        let response = handle_control_pipe_payload(&StubTransport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 1);
        assert_eq!(value["result"]["version"], 1);
        assert_eq!(value["result"]["pipe"], WINSMUX_CONTROL_PIPE_NAME);
        assert_eq!(value["result"]["localhost_http"], false);
        assert_eq!(value["result"]["websocket"], false);
    }

    #[test]
    fn control_pipe_rejects_invalid_json() {
        let response = handle_control_pipe_payload(&StubTransport, b"{", None);
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
    fn control_pipe_rejects_project_dir_override() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.summary.snapshot","params":{"projectDir":"C:/other"}}"#;
        let response = handle_control_pipe_payload(&StubTransport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_INVALID_PARAMS);
    }

    #[test]
    fn control_pipe_blocks_editor_read() {
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"desktop.editor.read","params":{"path":"README.md"}}"#;
        let response = handle_control_pipe_payload(&StubTransport, payload, None);
        let value: Value = serde_json::from_slice(&response).expect("response should be JSON");

        assert_eq!(value["id"], 1);
        assert_eq!(value["error"]["code"], JSON_RPC_METHOD_NOT_FOUND);
    }
}
