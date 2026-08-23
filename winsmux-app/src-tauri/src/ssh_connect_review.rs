use crate::desktop_backend::{
    apply_desktop_winsmux_child_env, hide_subprocess_window, resolve_companion_winsmux_cli,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const REMOTE_HELPER_PROTOCOL_VERSION: u16 = 1;
const REMOTE_HELPER_MAX_FRAME_LEN: u32 = 523;
const STATUS_MISSING_RECORD_MARKER: &str = "has no local record";

static NONCE_COUNTER: AtomicU64 = AtomicU64::new(1);
static REQUEST_CHILDREN: OnceLock<Mutex<HashMap<String, RequestRuntime>>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SshConnectReviewAction {
    Inspect,
    Confirm,
    Runtime,
    Stop,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SshConnectReviewRequest {
    action: SshConnectReviewAction,
    request_id: String,
    alias: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum HostState {
    NotFound,
    Pending,
    Registered,
    Blocked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum RuntimeState {
    Unavailable,
    HandshakeConfirmed,
    Stopped,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct SafeProfileSnapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    host_state: Option<HostState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    confirmed_fingerprint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    presented_fingerprint: Option<String>,
}

struct ConfirmProfileResult {
    profile: SafeProfileSnapshot,
    error_code: Option<&'static str>,
}

impl ConfirmProfileResult {
    fn completed(profile: SafeProfileSnapshot) -> Self {
        Self {
            profile,
            error_code: None,
        }
    }

    fn pending_audit(profile: SafeProfileSnapshot, error: ReviewFailure) -> Self {
        Self {
            profile,
            error_code: Some(error.0),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SshConnectReviewResponse {
    ok: bool,
    action: SshConnectReviewAction,
    #[serde(flatten)]
    profile: SafeProfileSnapshot,
    #[serde(skip_serializing_if = "Option::is_none")]
    runtime_state: Option<RuntimeState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<&'static str>,
}

#[derive(Clone, Debug)]
struct ProcessOutput {
    success: bool,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReviewFailure(&'static str);

enum RequestRuntime {
    Starting,
    Child(Child),
    Stopped,
}

trait ReviewRunner {
    fn run(&mut self, args: &[String]) -> Result<ProcessOutput, ReviewFailure>;
    fn begin_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure>;
    fn runtime_handshake(&mut self, request_id: &str, alias: &str) -> Result<(), ReviewFailure>;
    fn finish_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure>;
    fn stop(&mut self, request_id: &str) -> Result<bool, ReviewFailure>;
}

trait ReapChild {
    fn has_exited(&mut self) -> io::Result<bool>;
    fn kill_child(&mut self) -> io::Result<()>;
    fn wait_for_exit(&mut self) -> io::Result<()>;
}

impl ReapChild for Child {
    fn has_exited(&mut self) -> io::Result<bool> {
        self.try_wait().map(|status| status.is_some())
    }

    fn kill_child(&mut self) -> io::Result<()> {
        self.kill()
    }

    fn wait_for_exit(&mut self) -> io::Result<()> {
        self.wait().map(|_| ())
    }
}

fn reap_child<C: ReapChild>(child: &mut C) -> Result<(), ReviewFailure> {
    if child
        .has_exited()
        .map_err(|_| ReviewFailure("ssh_connect_review_child_status_failed"))?
    {
        return Ok(());
    }
    if child.kill_child().is_err()
        && !child
            .has_exited()
            .map_err(|_| ReviewFailure("ssh_connect_review_child_status_failed"))?
    {
        return Err(ReviewFailure("ssh_connect_review_child_kill_failed"));
    }
    child
        .wait_for_exit()
        .map_err(|_| ReviewFailure("ssh_connect_review_child_reap_failed"))
}

fn request_children() -> &'static Mutex<HashMap<String, RequestRuntime>> {
    REQUEST_CHILDREN.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock_request_children() -> MutexGuard<'static, HashMap<String, RequestRuntime>> {
    request_children()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn begin_request_runtime(request_id: &str) -> Result<(), ReviewFailure> {
    let mut children = lock_request_children();
    match children.get(request_id) {
        Some(RequestRuntime::Stopped) => {
            return Err(ReviewFailure("ssh_connect_review_runtime_stopped"));
        }
        Some(_) => return Err(ReviewFailure("ssh_connect_review_request_busy")),
        None => {}
    }
    children.insert(request_id.to_string(), RequestRuntime::Starting);
    Ok(())
}

fn start_request_child(
    request_id: &str,
    command: &mut Command,
) -> Result<(ChildStdin, ChildStdout), ReviewFailure> {
    let mut children = lock_request_children();
    match children.get(request_id) {
        Some(RequestRuntime::Starting) => {}
        Some(RequestRuntime::Stopped) | None => {
            return Err(ReviewFailure("ssh_connect_review_runtime_stopped"));
        }
        Some(RequestRuntime::Child(_)) => {
            return Err(ReviewFailure("ssh_connect_review_request_busy"));
        }
    }
    let mut child = command
        .spawn()
        .map_err(|_| ReviewFailure("ssh_connect_review_runtime_spawn_failed"))?;
    let Some(child_stdin) = child.stdin.take() else {
        drop(children);
        let _ = reap_child(&mut child);
        return Err(ReviewFailure("ssh_connect_review_runtime_stdin_missing"));
    };
    let Some(child_stdout) = child.stdout.take() else {
        drop(child_stdin);
        drop(children);
        let _ = reap_child(&mut child);
        return Err(ReviewFailure("ssh_connect_review_runtime_stdout_missing"));
    };
    children.insert(request_id.to_string(), RequestRuntime::Child(child));
    Ok((child_stdin, child_stdout))
}

fn stop_request_child(request_id: &str) -> Result<bool, ReviewFailure> {
    let entry = {
        let mut children = lock_request_children();
        children.insert(request_id.to_string(), RequestRuntime::Stopped)
    };
    match entry {
        None => Ok(false),
        Some(RequestRuntime::Starting) => Ok(true),
        Some(RequestRuntime::Stopped) => Ok(false),
        Some(RequestRuntime::Child(mut child)) => {
            reap_child(&mut child)?;
            Ok(true)
        }
    }
}

fn finish_request_runtime(request_id: &str) -> Result<(), ReviewFailure> {
    let entry = {
        let mut children = lock_request_children();
        if matches!(children.get(request_id), Some(RequestRuntime::Stopped)) {
            return Ok(());
        }
        children.remove(request_id)
    };
    if let Some(entry) = entry {
        if let RequestRuntime::Child(mut child) = entry {
            reap_child(&mut child)?;
        }
    }
    Ok(())
}

fn token_is_legal(value: &str) -> bool {
    let mut chars = value.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
}

fn required_alias(request: &SshConnectReviewRequest) -> Result<&str, ReviewFailure> {
    let alias = request
        .alias
        .as_deref()
        .ok_or(ReviewFailure("ssh_connect_review_alias_required"))?;
    if !token_is_legal(alias) {
        return Err(ReviewFailure("ssh_connect_review_alias_invalid"));
    }
    Ok(alias)
}

fn safe_fingerprint(value: Option<&Value>) -> Option<String> {
    let value = value?.as_str()?;
    let encoded = value.strip_prefix("sha256:")?;
    if encoded.len() != 64
        || !encoded
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
    {
        return None;
    }
    Some(value.to_string())
}

fn parse_host_state(value: &Value) -> Result<HostState, ReviewFailure> {
    match value.get("state").and_then(Value::as_str) {
        Some("pending") => Ok(HostState::Pending),
        Some("registered") => Ok(HostState::Registered),
        Some("blocked") => Ok(HostState::Blocked),
        _ => Err(ReviewFailure("ssh_connect_review_host_state_invalid")),
    }
}

fn safe_profile_snapshot(value: &Value) -> Result<SafeProfileSnapshot, ReviewFailure> {
    Ok(SafeProfileSnapshot {
        host_state: Some(parse_host_state(value)?),
        confirmed_fingerprint: safe_fingerprint(value.get("confirmed_fingerprint")),
        presented_fingerprint: safe_fingerprint(value.get("presented_fingerprint")),
    })
}

fn host_profile_args(action: &str, alias: &str) -> Vec<String> {
    vec![
        "host-profile".to_string(),
        action.to_string(),
        alias.to_string(),
        "--json".to_string(),
    ]
}

fn parse_success_json(
    output: &ProcessOutput,
    error_code: &'static str,
) -> Result<Value, ReviewFailure> {
    if !output.success {
        return Err(ReviewFailure(error_code));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|_| ReviewFailure("ssh_connect_review_json_invalid"))
}

fn inspect_status<R: ReviewRunner>(
    runner: &mut R,
    alias: &str,
) -> Result<SafeProfileSnapshot, ReviewFailure> {
    let output = runner.run(&host_profile_args("status", alias))?;
    if !output.success {
        if String::from_utf8_lossy(&output.stderr).contains(STATUS_MISSING_RECORD_MARKER) {
            return Ok(SafeProfileSnapshot {
                host_state: Some(HostState::NotFound),
                ..SafeProfileSnapshot::default()
            });
        }
        return Err(ReviewFailure("ssh_connect_review_status_failed"));
    }
    let value = parse_success_json(&output, "ssh_connect_review_status_failed")?;
    safe_profile_snapshot(&value)
}

fn response(
    action: SshConnectReviewAction,
    profile: SafeProfileSnapshot,
    runtime_state: Option<RuntimeState>,
) -> SshConnectReviewResponse {
    SshConnectReviewResponse {
        ok: true,
        action,
        profile,
        runtime_state,
        error_code: None,
    }
}

fn confirm_profile<R: ReviewRunner>(
    runner: &mut R,
    alias: &str,
) -> Result<ConfirmProfileResult, ReviewFailure> {
    let check_output = runner.run(&host_profile_args("check", alias))?;
    let check_value = parse_success_json(&check_output, "ssh_connect_review_check_failed")?;
    let mut checked = safe_profile_snapshot(&check_value)?;
    checked.presented_fingerprint = None;
    if checked.host_state != Some(HostState::Pending) {
        return Ok(ConfirmProfileResult::completed(checked));
    }

    let register_output = match runner.run(&host_profile_args("register", alias)) {
        Ok(output) => output,
        Err(error) => return Ok(ConfirmProfileResult::pending_audit(checked, error)),
    };
    let register_value =
        match parse_success_json(&register_output, "ssh_connect_review_register_failed") {
            Ok(value) => value,
            Err(error) => return Ok(ConfirmProfileResult::pending_audit(checked, error)),
        };
    let registered = match safe_profile_snapshot(&register_value) {
        Ok(snapshot) => snapshot,
        Err(error) => return Ok(ConfirmProfileResult::pending_audit(checked, error)),
    };
    if registered.host_state != Some(HostState::Registered) {
        return Ok(ConfirmProfileResult::pending_audit(
            checked,
            ReviewFailure("ssh_connect_review_register_state_invalid"),
        ));
    }
    Ok(ConfirmProfileResult::completed(registered))
}

fn handle_request_with<R: ReviewRunner>(
    request: SshConnectReviewRequest,
    runner: &mut R,
) -> Result<SshConnectReviewResponse, ReviewFailure> {
    if !token_is_legal(&request.request_id) {
        return Err(ReviewFailure("ssh_connect_review_request_id_invalid"));
    }
    match request.action {
        SshConnectReviewAction::Inspect => {
            let profile = inspect_status(runner, required_alias(&request)?)?;
            Ok(response(request.action, profile, None))
        }
        SshConnectReviewAction::Confirm => {
            let confirmation = confirm_profile(runner, required_alias(&request)?)?;
            Ok(SshConnectReviewResponse {
                ok: confirmation.error_code.is_none(),
                action: request.action,
                profile: confirmation.profile,
                runtime_state: None,
                error_code: confirmation.error_code,
            })
        }
        SshConnectReviewAction::Runtime => {
            let alias = required_alias(&request)?;
            runner.begin_runtime(&request.request_id)?;
            let outcome = (|| {
                let profile = inspect_status(runner, alias)?;
                if profile.host_state != Some(HostState::Registered) {
                    return Ok(response(
                        request.action,
                        profile,
                        Some(RuntimeState::Unavailable),
                    ));
                }
                runner.runtime_handshake(&request.request_id, alias)?;
                Ok(response(
                    request.action,
                    profile,
                    Some(RuntimeState::HandshakeConfirmed),
                ))
            })();
            let finished = runner.finish_runtime(&request.request_id);
            match (outcome, finished) {
                (_, Err(error)) => Err(error),
                (Err(error), Ok(())) => Err(error),
                (Ok(result), Ok(())) => Ok(result),
            }
        }
        SshConnectReviewAction::Stop => {
            let _ = runner.stop(&request.request_id)?;
            Ok(response(
                request.action,
                SafeProfileSnapshot::default(),
                Some(RuntimeState::Stopped),
            ))
        }
    }
}

fn build_companion_command(args: &[String]) -> Result<Command, ReviewFailure> {
    let companion = resolve_companion_winsmux_cli()
        .ok_or(ReviewFailure("ssh_connect_review_companion_unavailable"))?;
    let mut command = Command::new(&companion);
    command.args(args);
    apply_desktop_winsmux_child_env(&mut command, Some(&companion), std::process::id());
    hide_subprocess_window(&mut command);
    Ok(command)
}

fn handshake_nonce() -> String {
    let counter = NONCE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hasher = Sha256::new();
    hasher.update(std::process::id().to_le_bytes());
    hasher.update(counter.to_le_bytes());
    hasher.update(timestamp.to_le_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn encode_hello_frame(nonce: &str) -> Result<Vec<u8>, ReviewFailure> {
    let payload = serde_json::to_vec(&json!({
        "type": "hello",
        "protocol_version": REMOTE_HELPER_PROTOCOL_VERSION,
        "client_version": env!("CARGO_PKG_VERSION"),
        "nonce": nonce,
        "capabilities": ["frame-v1"],
        "peer_frame_limit": REMOTE_HELPER_MAX_FRAME_LEN,
    }))
    .map_err(|_| ReviewFailure("ssh_connect_review_hello_encode_failed"))?;
    if payload.is_empty() || payload.len() > REMOTE_HELPER_MAX_FRAME_LEN as usize {
        return Err(ReviewFailure("ssh_connect_review_hello_oversized"));
    }
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

fn read_welcome_frame<R: Read>(reader: &mut R, nonce: &str) -> Result<(), ReviewFailure> {
    let mut prefix = [0u8; 4];
    reader
        .read_exact(&mut prefix)
        .map_err(|_| ReviewFailure("ssh_connect_review_handshake_read_failed"))?;
    let length = u32::from_be_bytes(prefix);
    if length == 0 || length > REMOTE_HELPER_MAX_FRAME_LEN {
        return Err(ReviewFailure("ssh_connect_review_handshake_frame_invalid"));
    }
    let mut payload = vec![0u8; length as usize];
    reader
        .read_exact(&mut payload)
        .map_err(|_| ReviewFailure("ssh_connect_review_handshake_read_failed"))?;
    let value: Value = serde_json::from_slice(&payload)
        .map_err(|_| ReviewFailure("ssh_connect_review_handshake_json_invalid"))?;
    let exact_fields = value.as_object().is_some_and(|object| {
        object.len() == 5
            && [
                "type",
                "protocol_version",
                "nonce",
                "capabilities",
                "peer_frame_limit",
            ]
            .iter()
            .all(|field| object.contains_key(*field))
    });
    let frame_v1_only = value
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|items| items.len() == 1 && items[0].as_str() == Some("frame-v1"));
    if !exact_fields
        || value.get("type").and_then(Value::as_str) != Some("welcome")
        || value.get("protocol_version").and_then(Value::as_u64)
            != Some(REMOTE_HELPER_PROTOCOL_VERSION as u64)
        || value.get("nonce").and_then(Value::as_str) != Some(nonce)
        || value.get("peer_frame_limit").and_then(Value::as_u64)
            != Some(REMOTE_HELPER_MAX_FRAME_LEN as u64)
        || !frame_v1_only
    {
        return Err(ReviewFailure("ssh_connect_review_handshake_rejected"));
    }
    Ok(())
}

fn runtime_args(alias: &str) -> Vec<String> {
    vec![
        "ssh-helper-stdio".to_string(),
        "--".to_string(),
        alias.to_string(),
    ]
}

fn perform_runtime_handshake(request_id: &str, alias: &str) -> Result<(), ReviewFailure> {
    let args = runtime_args(alias);
    let mut command = build_companion_command(&args)?;
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let (mut child_stdin, mut child_stdout) = start_request_child(request_id, &mut command)?;

    let nonce = handshake_nonce();
    let handshake = (|| {
        let frame = encode_hello_frame(&nonce)?;
        child_stdin
            .write_all(&frame)
            .and_then(|_| child_stdin.flush())
            .map_err(|_| ReviewFailure("ssh_connect_review_handshake_write_failed"))?;
        drop(child_stdin);
        read_welcome_frame(&mut child_stdout, &nonce)
    })();
    handshake
}

struct NativeReviewRunner;

impl ReviewRunner for NativeReviewRunner {
    fn run(&mut self, args: &[String]) -> Result<ProcessOutput, ReviewFailure> {
        let mut command = build_companion_command(args)?;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let output = command
            .output()
            .map_err(|_| ReviewFailure("ssh_connect_review_process_spawn_failed"))?;
        Ok(ProcessOutput {
            success: output.status.success(),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }

    fn begin_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure> {
        begin_request_runtime(request_id)
    }

    fn runtime_handshake(&mut self, request_id: &str, alias: &str) -> Result<(), ReviewFailure> {
        perform_runtime_handshake(request_id, alias)
    }

    fn finish_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure> {
        finish_request_runtime(request_id)
    }

    fn stop(&mut self, request_id: &str) -> Result<bool, ReviewFailure> {
        stop_request_child(request_id)
    }
}

#[tauri::command]
pub(crate) async fn ssh_connect_review(
    request: SshConnectReviewRequest,
) -> Result<SshConnectReviewResponse, String> {
    tauri::async_runtime::spawn_blocking(move || {
        handle_request_with(request, &mut NativeReviewRunner).map_err(|error| error.0.to_string())
    })
    .await
    .map_err(|_| "ssh_connect_review_task_failed".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_companion_cli::{clear_companion_cli_override, set_companion_cli_override};
    use serde_json::json;
    use std::collections::VecDeque;
    use std::path::PathBuf;

    #[derive(Default)]
    struct FakeRunner {
        begin_calls: Vec<String>,
        commands: Vec<Vec<String>>,
        finish_calls: Vec<String>,
        outputs: VecDeque<ProcessOutput>,
        runtime_calls: Vec<(String, String)>,
        stop_calls: Vec<String>,
        stop_result: bool,
        use_request_tombstones: bool,
    }

    impl ReviewRunner for FakeRunner {
        fn run(&mut self, args: &[String]) -> Result<ProcessOutput, ReviewFailure> {
            self.commands.push(args.to_vec());
            self.outputs
                .pop_front()
                .ok_or(ReviewFailure("missing_fake_output"))
        }

        fn begin_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure> {
            self.begin_calls.push(request_id.to_string());
            if self.use_request_tombstones {
                return begin_request_runtime(request_id);
            }
            Ok(())
        }

        fn runtime_handshake(
            &mut self,
            request_id: &str,
            alias: &str,
        ) -> Result<(), ReviewFailure> {
            self.runtime_calls
                .push((request_id.to_string(), alias.to_string()));
            Ok(())
        }

        fn finish_runtime(&mut self, request_id: &str) -> Result<(), ReviewFailure> {
            self.finish_calls.push(request_id.to_string());
            Ok(())
        }

        fn stop(&mut self, request_id: &str) -> Result<bool, ReviewFailure> {
            self.stop_calls.push(request_id.to_string());
            Ok(self.stop_result)
        }
    }

    fn request(action: SshConnectReviewAction) -> SshConnectReviewRequest {
        SshConnectReviewRequest {
            action,
            request_id: "request-776".to_string(),
            alias: Some("registered-alias".to_string()),
        }
    }

    fn successful(value: Value) -> ProcessOutput {
        ProcessOutput {
            success: true,
            stdout: serde_json::to_vec(&value).expect("fixture JSON should encode"),
            stderr: Vec::new(),
        }
    }

    fn test_fingerprint(fill: char) -> String {
        format!("sha256:{}", fill.to_string().repeat(64))
    }

    #[test]
    fn inspect_only_spawns_status() {
        let mut runner = FakeRunner::default();
        let fingerprint = test_fingerprint('a');
        runner.outputs.push_back(successful(json!({
            "state": "registered",
            "confirmed_fingerprint": fingerprint
        })));

        let response = handle_request_with(request(SshConnectReviewAction::Inspect), &mut runner)
            .expect("inspect should succeed");

        assert_eq!(response.profile.host_state, Some(HostState::Registered));
        assert_eq!(
            response.profile.confirmed_fingerprint,
            Some(test_fingerprint('a'))
        );
        assert_eq!(
            runner.commands,
            vec![vec![
                "host-profile".to_string(),
                "status".to_string(),
                "registered-alias".to_string(),
                "--json".to_string(),
            ]]
        );
    }

    #[test]
    fn missing_status_record_is_a_first_class_host_state() {
        let mut runner = FakeRunner::default();
        runner.outputs.push_back(ProcessOutput {
            success: false,
            stdout: Vec::new(),
            stderr: b"host-profile 'private-alias' has no local record".to_vec(),
        });

        let response = handle_request_with(request(SshConnectReviewAction::Inspect), &mut runner)
            .expect("missing status should not become a silent check");

        assert_eq!(response.profile.host_state, Some(HostState::NotFound));
        assert_eq!(runner.commands.len(), 1);
        assert_eq!(runner.commands[0][..2], ["host-profile", "status"]);
    }

    #[test]
    fn unregistered_runtime_never_spawns_helper() {
        let mut runner = FakeRunner::default();
        runner.outputs.push_back(successful(json!({
            "state": "pending",
            "confirmed_fingerprint": null
        })));

        let response = handle_request_with(request(SshConnectReviewAction::Runtime), &mut runner)
            .expect("unregistered runtime should return a safe state");

        assert_eq!(response.runtime_state, Some(RuntimeState::Unavailable));
        assert!(runner.runtime_calls.is_empty());
        assert_eq!(runner.begin_calls, vec!["request-776"]);
        assert_eq!(runner.finish_calls, vec!["request-776"]);
        assert_eq!(runner.commands[0][..2], ["host-profile", "status"]);
    }

    #[test]
    fn registered_runtime_performs_one_handshake() {
        let mut runner = FakeRunner::default();
        runner.outputs.push_back(successful(json!({
            "state": "registered",
            "confirmed_fingerprint": "SHA256:confirmed"
        })));

        let response = handle_request_with(request(SshConnectReviewAction::Runtime), &mut runner)
            .expect("registered runtime should perform a handshake");

        assert_eq!(
            response.runtime_state,
            Some(RuntimeState::HandshakeConfirmed)
        );
        assert_eq!(
            runner.runtime_calls,
            vec![("request-776".to_string(), "registered-alias".to_string())]
        );
        assert_eq!(runner.begin_calls, vec!["request-776"]);
        assert_eq!(runner.finish_calls, vec!["request-776"]);
    }

    #[test]
    fn confirm_runs_check_then_register_without_copying_check_presentation() {
        let mut runner = FakeRunner::default();
        let fingerprint = test_fingerprint('b');
        runner.outputs.push_back(successful(json!({
            "state": "pending",
            "presented_fingerprint": fingerprint,
            "confirmed_fingerprint": null
        })));
        runner.outputs.push_back(successful(json!({
            "state": "registered",
            "confirmed_fingerprint": test_fingerprint('b')
        })));

        let response = handle_request_with(request(SshConnectReviewAction::Confirm), &mut runner)
            .expect("pending confirmation should register");

        assert_eq!(response.profile.host_state, Some(HostState::Registered));
        assert_eq!(response.profile.presented_fingerprint, None);
        assert_eq!(
            response.profile.confirmed_fingerprint,
            Some(test_fingerprint('b'))
        );
        assert_eq!(runner.commands.len(), 2);
        assert_eq!(runner.commands[0][..2], ["host-profile", "check"]);
        assert_eq!(runner.commands[1][..2], ["host-profile", "register"]);
    }

    #[test]
    fn confirm_keeps_a_redacted_pending_audit_when_register_fails() {
        let mut runner = FakeRunner::default();
        runner.outputs.push_back(successful(json!({
            "state": "pending",
            "presented_fingerprint": test_fingerprint('c'),
            "confirmed_fingerprint": null
        })));
        runner.outputs.push_back(ProcessOutput {
            success: false,
            stdout: Vec::new(),
            stderr: b"private register failure".to_vec(),
        });

        let response = handle_request_with(request(SshConnectReviewAction::Confirm), &mut runner)
            .expect("the completed check must remain as a redacted audit");

        assert!(!response.ok);
        assert_eq!(response.profile.host_state, Some(HostState::Pending));
        assert_eq!(response.profile.presented_fingerprint, None);
        assert_eq!(
            response.error_code,
            Some("ssh_connect_review_register_failed")
        );
        let rendered = serde_json::to_string(&response).expect("pending audit should serialize");
        assert!(!rendered.contains("private register failure"));
        assert!(!rendered.contains(&test_fingerprint('c')));
        assert_eq!(runner.commands.len(), 2);
        assert_eq!(runner.commands[0][..2], ["host-profile", "check"]);
        assert_eq!(runner.commands[1][..2], ["host-profile", "register"]);
    }

    #[test]
    fn blocked_check_does_not_register() {
        let mut runner = FakeRunner::default();
        runner.outputs.push_back(successful(json!({
            "state": "blocked",
            "presented_fingerprint": test_fingerprint('d'),
            "confirmed_fingerprint": "SHA256:confirmed"
        })));

        let response = handle_request_with(request(SshConnectReviewAction::Confirm), &mut runner)
            .expect("blocked is a first-class result");

        assert_eq!(response.profile.host_state, Some(HostState::Blocked));
        assert_eq!(response.profile.presented_fingerprint, None);
        assert_eq!(runner.commands.len(), 1);
        assert_eq!(runner.commands[0][..2], ["host-profile", "check"]);
    }

    #[test]
    fn stop_targets_only_the_request_child() {
        let mut runner = FakeRunner {
            stop_result: true,
            ..FakeRunner::default()
        };
        let mut stop_request = request(SshConnectReviewAction::Stop);
        stop_request.alias = None;

        let response =
            handle_request_with(stop_request, &mut runner).expect("safe stop should be idempotent");

        assert_eq!(response.runtime_state, Some(RuntimeState::Stopped));
        assert_eq!(runner.stop_calls, vec!["request-776"]);
        assert!(runner.commands.is_empty());
        assert!(runner.runtime_calls.is_empty());
    }

    #[test]
    fn stop_before_begin_blocks_later_runtime() {
        let request_id = format!(
            "request-776-stop-before-begin-{}",
            NONCE_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let mut runner = FakeRunner {
            use_request_tombstones: true,
            ..FakeRunner::default()
        };
        let mut runtime_request = request(SshConnectReviewAction::Runtime);
        runtime_request.request_id = request_id.clone();

        assert_eq!(stop_request_child(&request_id), Ok(false));
        let error = handle_request_with(runtime_request, &mut runner)
            .expect_err("a tombstoned request must fail before status or handshake");

        assert_eq!(error, ReviewFailure("ssh_connect_review_runtime_stopped"));
        assert!(runner.commands.is_empty());
        assert!(runner.runtime_calls.is_empty());
    }

    #[derive(Default)]
    struct FakeChild {
        exited: bool,
        killed: bool,
        waited: bool,
    }

    impl ReapChild for FakeChild {
        fn has_exited(&mut self) -> io::Result<bool> {
            Ok(self.exited)
        }

        fn kill_child(&mut self) -> io::Result<()> {
            self.killed = true;
            Ok(())
        }

        fn wait_for_exit(&mut self) -> io::Result<()> {
            self.waited = true;
            Ok(())
        }
    }

    #[test]
    fn stop_reaps_the_request_child() {
        let mut child = FakeChild::default();

        reap_child(&mut child).expect("stop should reap the child");

        assert!(child.killed);
        assert!(child.waited);
    }

    #[test]
    fn redaction_keeps_fingerprints_and_strips_private_fields() {
        let fingerprint = test_fingerprint('f');
        let raw = json!({
            "state": "registered",
            "hostname": "private.example.internal",
            "user": "private-user",
            "identity_file": "C:\\Users\\private-user\\.ssh\\id_ed25519",
            "key_comment": "private-user@private-host",
            "transcript": "raw helper output",
            "confirmed_fingerprint": fingerprint
        });

        let safe = safe_profile_snapshot(&raw).expect("safe snapshot should parse");
        let rendered = serde_json::to_string(&safe).expect("safe snapshot should serialize");

        assert!(rendered.contains(&test_fingerprint('f')));
        for secret in [
            "private.example.internal",
            "private-user",
            "id_ed25519",
            "private-host",
            "raw helper output",
        ] {
            assert!(!rendered.contains(secret), "private field leaked: {secret}");
        }
    }

    #[test]
    fn runtime_argv_is_the_frozen_companion_command() {
        assert_eq!(
            runtime_args("registered-alias"),
            ["ssh-helper-stdio", "--", "registered-alias"]
        );
    }

    #[test]
    fn hello_and_welcome_are_the_only_runtime_protocol_messages() {
        let nonce = "00".repeat(32);
        let hello = encode_hello_frame(&nonce).expect("hello frame should encode");
        let declared = u32::from_be_bytes(hello[..4].try_into().expect("four-byte prefix"));
        let hello_json: Value =
            serde_json::from_slice(&hello[4..]).expect("hello payload should be JSON");
        assert_eq!(declared as usize, hello.len() - 4);
        assert_eq!(hello_json["type"], "hello");
        assert_eq!(
            hello_json["protocol_version"],
            REMOTE_HELPER_PROTOCOL_VERSION
        );
        assert!(hello_json.get("pty").is_none());

        let welcome_payload = serde_json::to_vec(&json!({
            "type": "welcome",
            "protocol_version": REMOTE_HELPER_PROTOCOL_VERSION,
            "nonce": nonce,
            "capabilities": ["frame-v1"],
            "peer_frame_limit": REMOTE_HELPER_MAX_FRAME_LEN,
        }))
        .expect("welcome payload should encode");
        let mut welcome = Vec::new();
        welcome.extend_from_slice(&(welcome_payload.len() as u32).to_be_bytes());
        welcome.extend_from_slice(&welcome_payload);
        read_welcome_frame(&mut welcome.as_slice(), &"00".repeat(32))
            .expect("matching Welcome should be accepted");

        let pty_payload = serde_json::to_vec(&json!({
            "type": "welcome",
            "protocol_version": REMOTE_HELPER_PROTOCOL_VERSION,
            "nonce": "00".repeat(32),
            "capabilities": ["frame-v1"],
            "peer_frame_limit": REMOTE_HELPER_MAX_FRAME_LEN,
            "pty": "must-not-be-accepted",
        }))
        .expect("malformed payload should encode");
        let mut pty_welcome = Vec::new();
        pty_welcome.extend_from_slice(&(pty_payload.len() as u32).to_be_bytes());
        pty_welcome.extend_from_slice(&pty_payload);
        assert!(read_welcome_frame(&mut pty_welcome.as_slice(), &"00".repeat(32)).is_err());
    }

    struct CompanionOverrideGuard;

    impl Drop for CompanionOverrideGuard {
        fn drop(&mut self) {
            clear_companion_cli_override();
        }
    }

    #[test]
    fn companion_override_builds_an_argv_command() {
        let companion = PathBuf::from("test-companion-winsmux.exe");
        set_companion_cli_override(Some(companion.clone()));
        let _guard = CompanionOverrideGuard;
        let args = host_profile_args("status", "registered-alias");

        let command = build_companion_command(&args).expect("override should resolve");
        let actual_args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert_eq!(command.get_program(), companion.as_os_str());
        assert_eq!(actual_args, args);
    }
}
