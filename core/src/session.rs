use std::env;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Returns true if this port-file base name belongs to a warm (standby) server.
/// Warm sessions should be hidden from user-facing lists and never auto-attached.
pub fn is_warm_session(base: &str) -> bool {
    base == "__warm__" || base.ends_with("____warm__")
}

/// Return the port/key file base for the standby warm server.
pub fn warm_session_base(socket_name: Option<&str>) -> String {
    if let Some(socket_name) = socket_name {
        format!("{socket_name}____warm__")
    } else {
        "__warm__".to_string()
    }
}

fn psmux_dir() -> Option<std::path::PathBuf> {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).ok()?;
    Some(Path::new(&home).join(".psmux"))
}

pub const SESSION_REGISTRY_PROTOCOL_VERSION: u32 = 1;
pub const SESSION_RESTORE_STATE_CANDIDATE: &str = "candidate";
pub const SESSION_RESTORE_STATE_SETUP_REQUIRED: &str = "setup-required";
pub const SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED: &str = "agent-session-expired";
const SESSION_REGISTRY_STARTUP_DEADLINE: Duration = Duration::from_secs(60);
const LEGACY_PORT_FILE_STARTUP_GRACE: Duration = Duration::from_secs(5);
const LEGACY_SESSION_RESTORE_STATE_PANE_EXITED: &str = "pane_exited";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRegistryTranscriptRingSummary {
    #[serde(default)]
    pub byte_count: u64,
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(default)]
    pub raw_transcript_stored: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRegistryPaneRestoreMetadata {
    pub pane_id: String,
    pub window_id: String,
    pub window_index: usize,
    pub pane_index: usize,
    #[serde(default)]
    pub agent_cli_session_id: Option<String>,
    pub transcript_ring_summary: SessionRegistryTranscriptRingSummary,
    #[serde(default)]
    pub worktree: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub provider_target: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub model_source: Option<String>,
    #[serde(default)]
    pub context_capsule_ref: Option<String>,
    #[serde(default)]
    pub checkpoint_ref: Option<String>,
    pub restore_state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub setup_required_reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRegistryRestoreMetadata {
    pub restore_metadata_version: u32,
    pub layer: String,
    #[serde(default)]
    pub panes: Vec<SessionRegistryPaneRestoreMetadata>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionRestoreCandidate {
    pub session: String,
    pub namespace: Option<String>,
    pub owner: String,
    pub state: String,
    pub port: u16,
    pub created_at: u128,
    pub ready_at: Option<u128>,
    pub panes: Vec<SessionRegistryPaneRestoreMetadata>,
}

pub fn session_registry_now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

#[cfg(windows)]
pub fn current_process_started_at_millis() -> Option<u128> {
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    let handle = unsafe { GetCurrentProcess() };
    process_started_at_millis_for_handle(handle)
}

#[cfg(not(windows))]
pub fn current_process_started_at_millis() -> Option<u128> {
    None
}

pub fn new_session_instance_nonce() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};

    let seed = RandomState::new();
    let mut hasher = seed.build_hasher();
    hasher.write_u128(session_registry_now_millis());
    hasher.write_u32(std::process::id());
    format!("{:016x}", hasher.finish())
}

pub fn session_registry_path(psmux_dir: &Path, base: &str) -> PathBuf {
    psmux_dir.join(format!("{base}.registry.json"))
}

pub fn remove_session_registry_files(psmux_dir: &Path, base: &str) {
    let registry_path = session_registry_path(psmux_dir, base);
    let tmp_path = psmux_dir.join(format!("{base}.registry.json.tmp"));
    let _ = std::fs::remove_file(registry_path);
    let _ = std::fs::remove_file(tmp_path);
}

pub fn remove_session_state_files(psmux_dir: &Path, base: &str) {
    let _ = std::fs::remove_file(psmux_dir.join(format!("{base}.port")));
    let _ = std::fs::remove_file(psmux_dir.join(format!("{base}.key")));
    remove_session_registry_files(psmux_dir, base);
}

pub fn write_session_registry(
    psmux_dir: &Path,
    base: &str,
    port: u16,
    owner: &str,
    state: &str,
    instance_nonce: &str,
    process_started_at: u128,
    created_at: u128,
    ready_at: Option<u128>,
) -> io::Result<()> {
    write_session_registry_with_restore_metadata(
        psmux_dir,
        base,
        port,
        owner,
        state,
        instance_nonce,
        process_started_at,
        created_at,
        ready_at,
        None,
    )
}

pub fn write_session_registry_with_restore_metadata(
    psmux_dir: &Path,
    base: &str,
    port: u16,
    owner: &str,
    state: &str,
    instance_nonce: &str,
    process_started_at: u128,
    created_at: u128,
    ready_at: Option<u128>,
    restore: Option<&SessionRegistryRestoreMetadata>,
) -> io::Result<()> {
    let namespace = session_namespace_from_base(base);
    let registry_path = session_registry_path(psmux_dir, base);
    let tmp_path = psmux_dir.join(format!("{base}.registry.json.tmp"));
    let server_exe = env::current_exe()
        .ok()
        .map(|path| normalize_socket_selector_path(&path));
    let mut payload = serde_json::json!({
        "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
        "session": base,
        "namespace": namespace,
        "server_pid": std::process::id(),
        "process_started_at": process_started_at,
        "server_exe": server_exe,
        "instance_nonce": instance_nonce,
        "port": port,
        "state": state,
        "owner": owner,
        "created_at": created_at,
        "ready_at": ready_at
    });
    if let Some(restore) = restore {
        let restore_value = serde_json::to_value(restore).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize session restore metadata: {err}"),
            )
        })?;
        if let Some(payload) = payload.as_object_mut() {
            payload.insert("restore".to_string(), restore_value);
        }
    }
    let bytes = serde_json::to_vec_pretty(&payload).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize session registry: {err}"),
        )
    })?;
    std::fs::write(&tmp_path, bytes)?;
    std::fs::rename(&tmp_path, &registry_path)?;
    Ok(())
}

fn session_namespace_from_base(base: &str) -> Option<&str> {
    let (namespace, session_name) = base.split_once("__")?;
    if namespace.is_empty() || session_name.is_empty() || is_warm_session(base) {
        None
    } else {
        Some(namespace)
    }
}

fn read_session_registry(psmux_dir: &Path, base: &str) -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(session_registry_path(psmux_dir, base)).ok()?;
    serde_json::from_str(&text).ok()
}

fn registry_base_from_path(path: &Path) -> Option<String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .and_then(|name| name.strip_suffix(".registry.json"))
        .map(str::to_string)
}

pub fn enumerate_session_restore_candidates_in_dir(
    psmux_dir: &Path,
) -> Vec<SessionRestoreCandidate> {
    let Ok(entries) = std::fs::read_dir(psmux_dir) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| registry_base_from_path(path).is_some())
        .collect();
    paths.sort_by(|left, right| left.file_name().cmp(&right.file_name()));

    let mut candidates = Vec::new();
    for path in paths {
        let Some(base) = registry_base_from_path(&path) else {
            continue;
        };
        if is_warm_session(&base) {
            continue;
        }
        let Some(registry) = read_session_registry(psmux_dir, &base) else {
            continue;
        };
        if !registry_is_for_base(&registry, &base) || !registry_owner_matches_base(&registry, &base)
        {
            continue;
        }
        let Some(restore_value) = registry.get("restore").cloned() else {
            continue;
        };
        let Ok(restore) =
            serde_json::from_value::<SessionRegistryRestoreMetadata>(restore_value)
        else {
            continue;
        };
        if restore.panes.is_empty() {
            continue;
        }
        let Some(port) = registry["port"]
            .as_u64()
            .and_then(|value| u16::try_from(value).ok())
        else {
            continue;
        };
        let Some(owner) = registry["owner"].as_str() else {
            continue;
        };
        let Some(state) = registry["state"].as_str() else {
            continue;
        };
        let Some(created_at) = registry_u128(&registry, "created_at") else {
            continue;
        };
        let mut panes: Vec<SessionRegistryPaneRestoreMetadata> = restore
            .panes
            .into_iter()
            .map(normalize_session_registry_pane_restore_metadata)
            .collect();
        panes.sort_by(|left, right| {
            (
                left.window_index,
                left.pane_index,
                left.pane_id.as_str(),
            )
                .cmp(&(
                    right.window_index,
                    right.pane_index,
                    right.pane_id.as_str(),
                ))
        });
        candidates.push(SessionRestoreCandidate {
            session: base,
            namespace: registry["namespace"].as_str().map(str::to_string),
            owner: owner.to_string(),
            state: state.to_string(),
            port,
            created_at,
            ready_at: registry_u128(&registry, "ready_at"),
            panes,
        });
    }

    candidates
}

pub fn normalize_session_registry_pane_restore_metadata(
    mut pane: SessionRegistryPaneRestoreMetadata,
) -> SessionRegistryPaneRestoreMetadata {
    if pane.restore_state == SESSION_RESTORE_STATE_CANDIDATE {
        pane.setup_required_reason = None;
        return pane;
    }

    if pane.setup_required_reason.is_none() {
        pane.setup_required_reason = Some(match pane.restore_state.as_str() {
            LEGACY_SESSION_RESTORE_STATE_PANE_EXITED => {
                SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED
            }
            SESSION_RESTORE_STATE_SETUP_REQUIRED => {
                SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED
            }
            _ => SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED,
        }
        .to_string());
    }
    pane.restore_state = SESSION_RESTORE_STATE_SETUP_REQUIRED.to_string();
    pane
}

fn registry_u128(registry: &serde_json::Value, key: &str) -> Option<u128> {
    registry[key].as_u64().map(u128::from)
}

fn registry_is_for_base(registry: &serde_json::Value, base: &str) -> bool {
    registry["protocol_version"].as_u64() == Some(SESSION_REGISTRY_PROTOCOL_VERSION as u64)
        && registry["session"].as_str() == Some(base)
}

fn registry_server_exe_matches_current(registry: &serde_json::Value) -> bool {
    let Some(server_exe) = registry["server_exe"].as_str() else {
        return false;
    };
    let Some(current_exe) = env::current_exe()
        .ok()
        .map(|path| normalize_socket_selector_path(&path))
    else {
        return false;
    };
    server_exe == current_exe
}

fn registry_owner_matches_base(registry: &serde_json::Value, base: &str) -> bool {
    let expected_owner = if is_warm_session(base) {
        "warm"
    } else {
        "normal"
    };
    registry["owner"].as_str() == Some(expected_owner)
}

fn registry_has_cleanup_ownership_evidence(registry: &serde_json::Value, base: &str) -> bool {
    registry_is_for_base(registry, base)
        && registry_owner_matches_base(registry, base)
        && registry["server_pid"].as_u64().is_some_and(|pid| pid > 0)
        && registry_u128(registry, "process_started_at").is_some()
        && registry["instance_nonce"]
            .as_str()
            .is_some_and(|nonce| !nonce.trim().is_empty())
        && registry_server_exe_matches_current(registry)
}

fn registry_server_pid(registry: &serde_json::Value, base: &str) -> Option<u32> {
    if !registry_is_for_base(registry, base)
        || !registry_owner_matches_base(registry, base)
        || !registry_server_exe_matches_current(registry)
    {
        return None;
    }
    let pid = registry["server_pid"].as_u64()?;
    let pid = u32::try_from(pid).ok().filter(|pid| *pid > 0)?;
    if !registry_process_started_at_matches_pid(registry, pid) {
        return None;
    }
    Some(pid)
}

fn registry_process_started_at_matches_pid(registry: &serde_json::Value, pid: u32) -> bool {
    let Some(expected_started_at) = registry_u128(registry, "process_started_at") else {
        return false;
    };
    let Some(actual_started_at) = process_started_at_millis_for_pid(pid) else {
        return process_started_at_unavailable_matches_pid(pid);
    };
    actual_started_at == expected_started_at
}

#[cfg(windows)]
fn process_started_at_unavailable_matches_pid(_pid: u32) -> bool {
    false
}

#[cfg(not(windows))]
fn process_started_at_unavailable_matches_pid(pid: u32) -> bool {
    process_id_is_alive(pid)
}

#[cfg(windows)]
fn process_id_is_alive(pid: u32) -> bool {
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(desired_access: u32, inherit_handle: i32, process_id: u32) -> isize;
        fn CloseHandle(handle: isize) -> i32;
    }

    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle == 0 || handle == -1 {
            return false;
        }
        let _ = CloseHandle(handle);
        true
    }
}

#[cfg(not(windows))]
fn process_id_is_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(windows)]
fn process_started_at_millis_for_pid(pid: u32) -> Option<u128> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        return None;
    }
    let started_at = process_started_at_millis_for_handle(handle);
    unsafe {
        let _ = CloseHandle(handle);
    }
    started_at
}

#[cfg(windows)]
fn process_started_at_millis_for_handle(
    handle: windows_sys::Win32::Foundation::HANDLE,
) -> Option<u128> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetProcessTimes;

    let mut created = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut exited = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut kernel = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut user = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let ok = unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) };
    if ok == 0 {
        return None;
    }
    filetime_to_unix_millis(created)
}

#[cfg(windows)]
fn filetime_to_unix_millis(value: windows_sys::Win32::Foundation::FILETIME) -> Option<u128> {
    let ticks = ((value.dwHighDateTime as u64) << 32) | u64::from(value.dwLowDateTime);
    let unix_ticks = ticks.checked_sub(116_444_736_000_000_000)?;
    Some(u128::from(unix_ticks / 10_000))
}

#[cfg(not(windows))]
fn process_started_at_millis_for_pid(_pid: u32) -> Option<u128> {
    None
}

fn registry_is_within_startup_deadline(registry: &serde_json::Value, base: &str) -> bool {
    if !registry_is_for_base(registry, base)
        || !registry_owner_matches_base(registry, base)
        || registry["state"].as_str() != Some("starting")
    {
        return false;
    }
    let Some(created_at) = registry_u128(registry, "created_at") else {
        return false;
    };
    if registry_server_pid(registry, base).is_none() {
        return false;
    }
    let elapsed_ms = session_registry_now_millis().saturating_sub(created_at);
    elapsed_ms < SESSION_REGISTRY_STARTUP_DEADLINE.as_millis()
}

fn port_file_is_recent(path: &Path, max_age: Duration) -> bool {
    std::fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .map(|elapsed| elapsed < max_age)
        .unwrap_or(false)
}

fn authenticated_session_responds(psmux_dir: &Path, base: &str, port: u16) -> bool {
    let key_path = psmux_dir.join(format!("{base}.key"));
    let Ok(session_key) = std::fs::read_to_string(key_path) else {
        return false;
    };
    let session_key = session_key.trim();
    if session_key.is_empty() {
        return false;
    }
    let addr = format!("127.0.0.1:{port}");
    let Ok(sock_addr) = addr.parse() else {
        return false;
    };
    let Ok(mut stream) =
        std::net::TcpStream::connect_timeout(&sock_addr, Duration::from_millis(150))
    else {
        return false;
    };
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    if write!(stream, "AUTH {session_key}\n").is_err() {
        return false;
    }
    if std::io::Write::write_all(&mut stream, b"session-info\n").is_err() {
        return false;
    }
    if stream.flush().is_err() {
        return false;
    }
    let mut reader = std::io::BufReader::new(stream);
    let mut auth_line = String::new();
    std::io::BufRead::read_line(&mut reader, &mut auth_line).is_ok()
        && auth_line.trim() == "OK"
}

fn cleanup_is_allowed_for_dead_state(
    psmux_dir: &Path,
    base: &str,
    port_path: &Path,
    registry: Option<&serde_json::Value>,
) -> bool {
    if let Some(registry) = registry {
        return registry_has_cleanup_ownership_evidence(registry, base);
    }
    !port_file_is_recent(port_path, LEGACY_PORT_FILE_STARTUP_GRACE)
        && !session_registry_path(psmux_dir, base).exists()
}

pub fn socket_path_session_base(socket_path: &str) -> Option<String> {
    let selector = normalize_socket_selector(socket_path)?;
    let path = Path::new(&selector);
    let looks_like_path =
        selector.contains('\\') || selector.contains('/') || path.extension().is_some();
    if looks_like_path {
        let hash = stable_socket_namespace_hash(&selector);
        return Some(format!("socket-{hash:016x}"));
    }

    let candidate = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&selector)
        .trim()
        .to_string();

    if candidate.is_empty() || is_warm_session(&candidate) {
        return None;
    }

    Some(candidate)
}

pub fn normalize_socket_selector(socket_path: &str) -> Option<String> {
    let trimmed = socket_path.trim();
    if trimmed.is_empty() {
        return None;
    }

    let path = Path::new(trimmed);
    let looks_like_path =
        trimmed.contains('\\') || trimmed.contains('/') || path.extension().is_some();
    if looks_like_path {
        return Some(normalize_socket_selector_path(path));
    }

    Some(trimmed.to_string())
}

fn normalize_socket_selector_path(path: &Path) -> String {
    let full_path: PathBuf = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .map(|current_dir| current_dir.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let normalized = full_path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        normalized.to_lowercase()
    } else {
        normalized
    }
}

fn stable_socket_namespace_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

pub fn resolve_last_session_name_with_prefix(prefix: &str) -> Option<String> {
    let dir = psmux_dir()?;

    let last_session = std::fs::read_to_string(dir.join("last_session")).ok();
    let last_session = last_session.as_deref().map(str::trim).unwrap_or("");
    if !last_session.is_empty()
        && !is_warm_session(last_session)
        && last_session.starts_with(prefix)
        && dir.join(format!("{last_session}.port")).is_file()
    {
        return Some(last_session.to_string());
    }

    let mut picks: Vec<(String, std::time::SystemTime)> = Vec::new();

    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            if let Some(fname) = e.file_name().to_str() {
                if let Some((base, ext)) = fname.rsplit_once('.') {
                    if ext != "port" || is_warm_session(base) || !base.starts_with(prefix) {
                        continue;
                    }

                    if let Ok(md) = e.metadata() {
                        picks.push((
                            base.to_string(),
                            md.modified()
                                .unwrap_or(std::time::SystemTime::UNIX_EPOCH),
                        ));
                    }
                }
            }
        }
    }

    picks.sort_by_key(|(_, t)| *t);
    picks.last().map(|(n, _)| n.clone())
}

fn port_is_open(port: u16, timeout: Duration) -> bool {
    let addr = format!("127.0.0.1:{port}");
    let Ok(sock_addr) = addr.parse() else {
        return false;
    };
    std::net::TcpStream::connect_timeout(&sock_addr, timeout).is_ok()
}

fn wait_for_port_close(port: u16, deadline: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < deadline {
        if !port_is_open(port, Duration::from_millis(50)) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    !port_is_open(port, Duration::from_millis(50))
}

/// Ask a server to shut down and wait until its TCP port is closed.
pub fn request_server_shutdown(port: u16, session_key: &str) -> bool {
    let addr = format!("127.0.0.1:{port}");
    let Ok(sock_addr) = addr.parse() else {
        return false;
    };
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(
        &sock_addr,
        Duration::from_millis(500),
    ) else {
        return true;
    };

    let _ = stream.set_nodelay(true);
    let _ = write!(stream, "AUTH {}\n", session_key);
    let _ = stream.flush();
    let _ = stream.write_all(b"kill-server\n");
    let _ = stream.flush();
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(2000)));

    let mut buf = [0u8; 64];
    loop {
        match std::io::Read::read(&mut stream, &mut buf) {
            Ok(0) => break,
            Err(_) => break,
            Ok(_) => continue,
        }
    }

    wait_for_port_close(port, Duration::from_millis(3000))
}

/// Clean up the standby warm server for a namespace after `kill-server`.
pub fn cleanup_warm_server_for_socket(socket_name: Option<&str>) {
    let Some(dir) = psmux_dir() else {
        return;
    };
    cleanup_warm_server_for_socket_in_dir(&dir, socket_name);
}

fn cleanup_warm_server_for_socket_in_dir(psmux_dir: &Path, socket_name: Option<&str>) {
    let warm_base = warm_session_base(socket_name);
    let port_path = psmux_dir.join(format!("{warm_base}.port"));
    let key_path = psmux_dir.join(format!("{warm_base}.key"));

    let mut can_remove = true;
    if let Ok(port_str) = std::fs::read_to_string(&port_path) {
        if let Ok(port) = port_str.trim().parse::<u16>() {
            let session_key = std::fs::read_to_string(&key_path)
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            can_remove = request_server_shutdown(port, &session_key);
        }
    }

    if can_remove {
        remove_session_state_files(psmux_dir, &warm_base);
    }
}

/// Find the next available numeric session name (tmux-compatible).
/// tmux uses a monotonically incrementing counter, but since psmux has
/// no persistent server state, we scan existing port files and pick
/// the lowest non-negative integer not already in use.
/// When `ns_prefix` is Some("foo"), names are checked as "foo__0", "foo__1", etc.
pub fn next_session_name(ns_prefix: Option<&str>) -> String {
    let home = match env::var("USERPROFILE").or_else(|_| env::var("HOME")) {
        Ok(h) => h,
        Err(_) => return "0".to_string(),
    };
    let psmux_dir = format!("{}\\.psmux", home);
    let mut used: std::collections::HashSet<u32> = std::collections::HashSet::new();
    if let Ok(entries) = std::fs::read_dir(&psmux_dir) {
        for entry in entries.flatten() {
            if let Some(fname) = entry.file_name().to_str() {
                if let Some((base, ext)) = fname.rsplit_once('.') {
                    if ext != "port" { continue; }
                    if is_warm_session(base) { continue; }
                    // Extract the session name part (after namespace prefix if any)
                    let session_part = if let Some(pfx) = ns_prefix {
                        let full_pfx = format!("{}__", pfx);
                        if base.starts_with(&full_pfx) {
                            &base[full_pfx.len()..]
                        } else {
                            continue; // different namespace
                        }
                    } else {
                        if base.contains("__") { continue; } // namespaced session
                        base
                    };
                    if let Ok(n) = session_part.parse::<u32>() {
                        used.insert(n);
                    }
                }
            }
        }
    }
    let mut id = 0u32;
    while used.contains(&id) {
        id += 1;
    }
    id.to_string()
}

/// Clean up any stale port files (where server is not actually running)
pub fn cleanup_stale_port_files() {
    let home = match env::var("USERPROFILE").or_else(|_| env::var("HOME")) {
        Ok(h) => h,
        Err(_) => return,
    };
    let psmux_dir = Path::new(&home).join(".psmux");
    if let Ok(entries) = std::fs::read_dir(&psmux_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "port").unwrap_or(false) {
                let Some(base) = path.file_stem().and_then(|value| value.to_str()) else {
                    continue;
                };
                let registry = read_session_registry(&psmux_dir, base);
                if registry
                    .as_ref()
                    .is_some_and(|value| registry_is_within_startup_deadline(value, base))
                    || (registry.is_none()
                        && port_file_is_recent(&path, LEGACY_PORT_FILE_STARTUP_GRACE))
                {
                    continue;
                }
                if registry
                    .as_ref()
                    .and_then(|value| registry_server_pid(value, base))
                    .is_some_and(process_id_is_alive)
                {
                    continue;
                }
                let cleanup_allowed =
                    cleanup_is_allowed_for_dead_state(&psmux_dir, base, &path, registry.as_ref());
                if let Ok(port_str) = std::fs::read_to_string(&path) {
                    if let Ok(port) = port_str.trim().parse::<u16>() {
                        if authenticated_session_responds(&psmux_dir, base, port) {
                            continue;
                        }
                        if port_is_open(port, Duration::from_millis(100)) && registry.is_none() {
                            continue;
                        }
                        if cleanup_allowed {
                            remove_session_state_files(&psmux_dir, base);
                        }
                    } else {
                        if cleanup_allowed {
                            remove_session_state_files(&psmux_dir, base);
                        }
                    }
                } else if cleanup_allowed {
                    remove_session_state_files(&psmux_dir, base);
                }
            }
        }
    }
}

/// Read the session key from the key file
pub fn read_session_key(session: &str) -> io::Result<String> {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).unwrap_or_default();
    let keypath = format!("{}\\.psmux\\{}.key", home, session);
    std::fs::read_to_string(&keypath).map(|s| s.trim().to_string())
}

/// Send an authenticated command to a server
pub fn send_auth_cmd(addr: &str, key: &str, cmd: &[u8]) -> io::Result<()> {
    let sock_addr: std::net::SocketAddr = addr.parse().map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    if let Ok(mut s) = std::net::TcpStream::connect_timeout(&sock_addr, Duration::from_millis(50)) {
        let _ = s.set_nodelay(true);
        let _ = write!(s, "AUTH {}\n", key);
        let _ = std::io::Write::write_all(&mut s, cmd);
        let _ = s.flush();
    }
    Ok(())
}

/// Send an authenticated command and get response
pub fn send_auth_cmd_response(addr: &str, key: &str, cmd: &[u8]) -> io::Result<String> {
    let mut s = std::net::TcpStream::connect(addr)?;
    let _ = s.set_nodelay(true);
    let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = write!(s, "AUTH {}\n", key);
    let _ = std::io::Write::write_all(&mut s, cmd);
    let _ = s.flush();
    let mut br = std::io::BufReader::new(&mut s);
    let mut auth_line = String::new();
    let _ = std::io::BufRead::read_line(&mut br, &mut auth_line);
    let mut buf = String::new();
    let _ = std::io::Read::read_to_string(&mut br, &mut buf);
    Ok(buf)
}

pub fn send_control(line: String) -> io::Result<()> {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).unwrap_or_default();
    let mut target = env::var("PSMUX_TARGET_SESSION").ok().unwrap_or_else(|| "default".to_string());
    // Never target a warm (standby) session — resolve to a real session instead
    if is_warm_session(&target) {
        target = resolve_last_session_name().unwrap_or_else(|| "default".to_string());
    }
    let full_target = env::var("PSMUX_TARGET_FULL").ok();
    let path = format!("{}\\.psmux\\{}.port", home, target);
    let port = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse::<u16>().ok()).ok_or_else(|| io::Error::new(io::ErrorKind::Other, format!("no server running on session '{}'", target)))?.clone();
    let session_key = read_session_key(&target).unwrap_or_default();
    let addr: std::net::SocketAddr = format!("127.0.0.1:{}", port).parse().unwrap();
    let mut stream = std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(2000))?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = write!(stream, "AUTH {}\n", session_key);
    if let Some(ref ft) = full_target {
        let _ = write!(stream, "TARGET {}\n", ft);
    }
    let _ = write!(stream, "{}", line);
    let _ = stream.flush();
    // Read the "OK" response to drain the receive buffer before closing.
    // This prevents Windows from sending RST (due to unread data) which
    // could cause the server to lose the command.
    let mut buf = [0u8; 64];
    let _ = std::io::Read::read(&mut stream, &mut buf);
    Ok(())
}

pub fn send_control_with_response(line: String) -> io::Result<String> {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).unwrap_or_default();
    let mut target = env::var("PSMUX_TARGET_SESSION").ok().unwrap_or_else(|| "default".to_string());
    // Never target a warm (standby) session — resolve to a real session instead
    if is_warm_session(&target) {
        target = resolve_last_session_name().unwrap_or_else(|| "default".to_string());
    }
    let full_target = env::var("PSMUX_TARGET_FULL").ok();
    let path = format!("{}\\.psmux\\{}.port", home, target);
    let port = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse::<u16>().ok()).ok_or_else(|| io::Error::new(io::ErrorKind::Other, format!("no server running on session '{}'", target)))?.clone();
    let session_key = read_session_key(&target).unwrap_or_default();
    let addr = format!("127.0.0.1:{}", port);
    let mut stream = std::net::TcpStream::connect(&addr)?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(2000)));
    let _ = write!(stream, "AUTH {}\n", session_key);
    if let Some(ref ft) = full_target {
        let _ = write!(stream, "TARGET {}\n", ft);
    }
    let _ = write!(stream, "{}", line);
    let _ = stream.flush();
    let mut buf = Vec::new();
    let mut temp = [0u8; 4096];
    loop {
        match std::io::Read::read(&mut stream, &mut temp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&temp[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => break,
            Err(_) => break,
        }
    }
    let result = String::from_utf8_lossy(&buf).to_string();
    // Strip the "OK\n" AUTH response prefix if present
    let result = if result.starts_with("OK\n") {
        result[3..].to_string()
    } else if result.starts_with("OK\r\n") {
        result[4..].to_string()
    } else {
        result
    };
    Ok(result)
}

pub fn require_safe_environment_connection(
    reader: &mut impl io::BufRead,
    writer: &mut impl Write,
) -> io::Result<()> {
    writeln!(
        writer,
        "show-environment {}",
        crate::commands::SHOW_ENVIRONMENT_SAFE_CAPABILITY_FLAG
    )?;
    writer.flush()?;

    let mut response = String::new();
    reader.read_line(&mut response)?;
    let decoded = crate::commands::decode_safe_environment_response(&response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if decoded != crate::commands::SafeEnvironmentResponse::Ok(String::new()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            crate::commands::incompatible_environment_response_error(),
        ));
    }
    Ok(())
}

/// Send a control message to a specific port with authentication
pub fn send_control_to_port(port: u16, msg: &str, session_key: &str) -> io::Result<()> {
    let addr = format!("127.0.0.1:{}", port);
    if let Ok(mut stream) = std::net::TcpStream::connect(&addr) {
        let _ = stream.set_nodelay(true);
        let _ = write!(stream, "AUTH {}\n", session_key);
        let _ = stream.write_all(msg.as_bytes());
        let _ = stream.flush();
        // Drain the OK response to prevent RST
        let mut buf = [0u8; 64];
        let _ = stream.set_read_timeout(Some(Duration::from_millis(50)));
        let _ = std::io::Read::read(&mut stream, &mut buf);
    }
    Ok(())
}

pub fn resolve_last_session_name() -> Option<String> {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).ok()?;
    let dir = format!("{}\\.psmux", home);
    let last = std::fs::read_to_string(format!("{}\\last_session", dir)).ok();
    if let Some(name) = last {
        let name = name.trim().to_string();
        let p = format!("{}\\{}.port", dir, name);
        if std::path::Path::new(&p).exists() { return Some(name); }
    }
    let mut picks: Vec<(String, std::time::SystemTime)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        for e in rd.flatten() {
            if let Some(fname) = e.file_name().to_str() {
                if let Some((base, ext)) = fname.rsplit_once('.') {
                    if ext == "port" { if let Ok(md) = e.metadata() { picks.push((base.to_string(), md.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH))); } }
                }
            }
        }
    }
    // Exclude warm (standby) sessions — users should never auto-attach to them
    picks.retain(|(n, _)| !is_warm_session(n));
    picks.sort_by_key(|(_, t)| *t);
    picks.last().map(|(n, _)| n.clone())
}

pub fn resolve_default_session_name() -> Option<String> {
    if let Ok(name) = env::var("PSMUX_DEFAULT_SESSION") {
        let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).ok()?;
        let p = format!("{}\\.psmux\\{}.port", home, name);
        if std::path::Path::new(&p).exists() { return Some(name); }
    }
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).ok()?;
    let candidates = [format!("{}\\.psmuxrc", home), format!("{}\\.psmux\\pmuxrc", home)];
    for cfg in candidates.iter() {
        if let Ok(text) = std::fs::read_to_string(cfg) {
            let line = text.lines().find(|l| !l.trim().is_empty())?;
            let name = if let Some(rest) = line.strip_prefix("default-session ") { rest.trim().to_string() } else { line.trim().to_string() };
            let p = format!("{}\\.psmux\\{}.port", home, name);
            if std::path::Path::new(&p).exists() { return Some(name); }
        }
    }
    None
}

pub fn reap_children_placeholder() -> io::Result<bool> { Ok(false) }

/// Return the names of all live sessions by scanning .psmux/*.port files.
pub fn list_session_names() -> Vec<String> {
    let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_default();
    let dir = format!("{}\\.psmux", home);
    let mut names = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            if let Some(fname) = e.file_name().to_str().map(|s| s.to_string()) {
                if let Some((base, ext)) = fname.rsplit_once('.') {
                    if ext == "port" {
                        if is_warm_session(base) { continue; }
                        names.push(base.to_string());
                    }
                }
            }
        }
    }
    names.sort();
    names
}

/// A tree entry used by choose-tree: either a session header or a window under a session.
#[derive(Clone, Debug)]
pub struct TreeEntry {
    pub session_name: String,
    pub session_port: u16,
    pub is_session_header: bool,
    pub window_index: Option<usize>,
    pub window_name: String,
    pub window_panes: usize,
    pub window_size: String,
    pub is_current_session: bool,
    pub is_active_window: bool,
}

/// List all running sessions and their windows for choose-tree display.
/// Queries each running server via its TCP port for window list info.
pub fn list_all_sessions_tree(current_session: &str, current_windows: &[(String, usize, String, bool)]) -> Vec<TreeEntry> {
    let home = match env::var("USERPROFILE").or_else(|_| env::var("HOME")) {
        Ok(h) => h,
        Err(_) => return vec![],
    };
    let psmux_dir = format!("{}\\.psmux", home);
    let mut sessions: Vec<(String, u16, std::time::SystemTime)> = Vec::new();

    if let Ok(entries) = std::fs::read_dir(&psmux_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "port").unwrap_or(false) {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    // Hide warm (standby) sessions from choose-tree
                    if is_warm_session(stem) { continue; }
                    if let Ok(port_str) = std::fs::read_to_string(&path) {
                        if let Ok(port) = port_str.trim().parse::<u16>() {
                            let mtime = entry.metadata()
                                .and_then(|m| m.modified())
                                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
                            sessions.push((stem.to_string(), port, mtime));
                        }
                    }
                }
            }
        }
    }

    sessions.sort_by_key(|(name, _, _)| name.clone());

    let mut tree = Vec::new();
    for (name, port, _) in &sessions {
        let is_current = name == current_session;
        // Session header
        tree.push(TreeEntry {
            session_name: name.clone(),
            session_port: *port,
            is_session_header: true,
            window_index: None,
            window_name: String::new(),
            window_panes: 0,
            window_size: String::new(),
            is_current_session: is_current,
            is_active_window: false,
        });

        if is_current {
            // Use local data for the current session (fast, no IPC)
            for (i, (wname, panes, size, is_active)) in current_windows.iter().enumerate() {
                tree.push(TreeEntry {
                    session_name: name.clone(),
                    session_port: *port,
                    is_session_header: false,
                    window_index: Some(i),
                    window_name: wname.clone(),
                    window_panes: *panes,
                    window_size: size.clone(),
                    is_current_session: true,
                    is_active_window: *is_active,
                });
            }
        } else {
            // Query remote session for its window list
            let key = read_session_key(name).unwrap_or_default();
            let addr = format!("127.0.0.1:{}", port);
            if let Ok(resp) = send_auth_cmd_response(&addr, &key, b"list-windows -F \"#{window_index}:#{window_name}:#{window_panes}:#{window_width}x#{window_height}:#{window_active}\"\n") {
                for line in resp.lines() {
                    let line = line.trim();
                    if line.is_empty() { continue; }
                    let parts: Vec<&str> = line.splitn(5, ':').collect();
                    if parts.len() >= 5 {
                        let wi = parts[0].parse::<usize>().unwrap_or(0);
                        let wn = parts[1].to_string();
                        let wp = parts[2].parse::<usize>().unwrap_or(1);
                        let ws = parts[3].to_string();
                        let wa = parts[4] == "1";
                        tree.push(TreeEntry {
                            session_name: name.clone(),
                            session_port: *port,
                            is_session_header: false,
                            window_index: Some(wi),
                            window_name: wn,
                            window_panes: wp,
                            window_size: ws,
                            is_current_session: false,
                            is_active_window: wa,
                        });
                    }
                }
            }
        }
    }
    tree
}

/// Force-kill any remaining psmux/pmux/tmux server processes that didn't
/// exit via the TCP kill-server command.  This is the nuclear fallback that
/// guarantees kill-server always succeeds.
///
/// On Windows, uses CreateToolhelp32Snapshot to enumerate processes and
/// TerminateProcess to kill them.  Skips the current process.
#[cfg(windows)]
pub fn kill_remaining_server_processes() {
    const TH32CS_SNAPPROCESS: u32 = 0x00000002;
    const PROCESS_TERMINATE: u32 = 0x0001;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const INVALID_HANDLE: isize = -1;

    #[repr(C)]
    struct PROCESSENTRY32W {
        dw_size: u32,
        cnt_usage: u32,
        th32_process_id: u32,
        th32_default_heap_id: usize,
        th32_module_id: u32,
        cnt_threads: u32,
        th32_parent_process_id: u32,
        pc_pri_class_base: i32,
        dw_flags: u32,
        sz_exe_file: [u16; 260],
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateToolhelp32Snapshot(dw_flags: u32, th32_process_id: u32) -> isize;
        fn Process32FirstW(h_snapshot: isize, lppe: *mut PROCESSENTRY32W) -> i32;
        fn Process32NextW(h_snapshot: isize, lppe: *mut PROCESSENTRY32W) -> i32;
        fn OpenProcess(desired_access: u32, inherit_handle: i32, process_id: u32) -> isize;
        fn TerminateProcess(h_process: isize, exit_code: u32) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }

    let my_pid = std::process::id();

    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE || snap == 0 { return; }

        let mut pe: PROCESSENTRY32W = std::mem::zeroed();
        pe.dw_size = std::mem::size_of::<PROCESSENTRY32W>() as u32;

        let target_names: &[&str] = &["psmux.exe", "pmux.exe", "tmux.exe"];
        let mut pids_to_kill: Vec<u32> = Vec::new();

        if Process32FirstW(snap, &mut pe) != 0 {
            loop {
                let pid = pe.th32_process_id;
                if pid != my_pid {
                    // Extract exe name from wide string
                    let len = pe.sz_exe_file.iter().position(|&c| c == 0).unwrap_or(260);
                    let name = String::from_utf16_lossy(&pe.sz_exe_file[..len]);
                    let name_lower = name.to_lowercase();
                    for target in target_names {
                        if name_lower == *target || name_lower.ends_with(&format!("\\{}", target)) {
                            pids_to_kill.push(pid);
                            break;
                        }
                    }
                }
                if Process32NextW(snap, &mut pe) == 0 { break; }
            }
        }
        CloseHandle(snap);

        for pid in &pids_to_kill {
            let h = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, 0, *pid);
            if h != 0 && h != INVALID_HANDLE {
                let _ = TerminateProcess(h, 1);
                CloseHandle(h);
            }
        }
    }
}

#[cfg(not(windows))]
pub fn kill_remaining_server_processes() {
    // On non-Windows, use signal-based killing
    let _ = std::process::Command::new("pkill")
        .args(&["-f", "psmux|pmux"])
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn serve_capability_probe(response: String) -> (u16, std::thread::JoinHandle<()>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
            let mut auth = String::new();
            let mut command = String::new();
            std::io::BufRead::read_line(&mut reader, &mut auth).unwrap();
            write!(stream, "OK\n").unwrap();
            stream.flush().unwrap();
            std::io::BufRead::read_line(&mut reader, &mut command).unwrap();
            assert_eq!(auth, "AUTH synthetic-session-key\n");
            assert!(command.contains(crate::commands::SHOW_ENVIRONMENT_SAFE_CAPABILITY_FLAG));
            write!(stream, "{response}").unwrap();
            stream.flush().unwrap();
        });
        (port, handle)
    }

    #[test]
    fn safe_environment_capability_probe_accepts_marked_server() {
        let (port, server) = serve_capability_probe(
            crate::commands::encode_safe_environment_response(""),
        );
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(stream, "AUTH synthetic-session-key\n").unwrap();
        stream.flush().unwrap();
        let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
        let mut auth = String::new();
        std::io::BufRead::read_line(&mut reader, &mut auth).unwrap();
        assert_eq!(auth, "OK\n");
        require_safe_environment_connection(&mut reader, &mut stream).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn safe_environment_capability_probe_refuses_unmarked_legacy_output() {
        let (port, server) = serve_capability_probe(
            "TARGET_VAR=synthetic-target\nSECRET_VAR=synthetic-secret\n".to_string(),
        );
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(stream, "AUTH synthetic-session-key\n").unwrap();
        stream.flush().unwrap();
        let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
        let mut auth = String::new();
        std::io::BufRead::read_line(&mut reader, &mut auth).unwrap();
        assert_eq!(auth, "OK\n");
        let error = require_safe_environment_connection(&mut reader, &mut stream)
            .expect_err("an unmarked legacy response must be refused");
        server.join().unwrap();

        assert!(error.to_string().contains("restart"));
        assert!(!error.to_string().contains("synthetic-target"));
        assert!(!error.to_string().contains("synthetic-secret"));
    }

    #[test]
    fn warm_session_base_matches_namespace_encoding() {
        assert_eq!(warm_session_base(None), "__warm__");
        assert_eq!(warm_session_base(Some("preview")), "preview____warm__");
    }

    #[test]
    fn socket_path_session_base_preserves_simple_socket_names() {
        assert_eq!(
            socket_path_session_base("socket-name").as_deref(),
            Some("socket-name")
        );
    }

    #[test]
    fn socket_path_session_base_hashes_real_paths() {
        let first = socket_path_session_base(r"C:\a\mux.sock").expect("first path should resolve");
        let second = socket_path_session_base(r"C:\b\mux.sock").expect("second path should resolve");
        let relative = socket_path_session_base("mux.sock").expect("relative path should resolve");

        assert!(first.starts_with("socket-"));
        assert!(second.starts_with("socket-"));
        assert!(relative.starts_with("socket-"));
        assert_ne!(first, second);
        assert_ne!(first, relative);
        assert_ne!(second, relative);
    }

    #[test]
    fn normalize_socket_selector_resolves_relative_paths() {
        let expected = env::current_dir()
            .expect("test should read current dir")
            .join("mux.sock")
            .to_string_lossy()
            .replace('\\', "/");
        let expected = if cfg!(windows) {
            expected.to_lowercase()
        } else {
            expected
        };

        assert_eq!(
            normalize_socket_selector("mux.sock").as_deref(),
            Some(expected.as_str())
        );
    }

    #[test]
    fn resolve_last_session_name_with_prefix_prefers_matching_last_session() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("session-prefix");
        let psmux_dir = temp_home.join(".psmux");

        std::fs::write(psmux_dir.join("ops__older.port"), "1")
            .expect("test should write older port file");
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(psmux_dir.join("ops__newer.port"), "2")
            .expect("test should write newer port file");
        std::fs::write(psmux_dir.join("last_session"), "ops__older\n")
            .expect("test should write last_session");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        let resolved = resolve_last_session_name_with_prefix("ops__");

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let _ = std::fs::remove_dir_all(&temp_home);

        assert_eq!(resolved.as_deref(), Some("ops__older"));
    }

    #[test]
    fn cleanup_warm_server_for_socket_removes_only_matching_warm_files() {
        let dir = make_temp_psmux_dir("warm-cleanup");
        std::fs::write(dir.join("preview____warm__.port"), "not-a-port")
            .expect("test should write warm port file");
        std::fs::write(dir.join("preview____warm__.key"), "secret")
            .expect("test should write warm key file");
        let process_started_at = session_registry_now_millis().saturating_sub(120_000);
        write_session_registry(
            &dir,
            "preview____warm__",
            12345,
            "warm",
            "ready",
            "warm-cleanup-nonce",
            process_started_at,
            process_started_at,
            Some(session_registry_now_millis().saturating_sub(119_000)),
        )
        .expect("test should write warm registry file");
        std::fs::write(dir.join("preview__0.port"), "12345")
            .expect("test should write normal port file");
        std::fs::write(dir.join("other____warm__.port"), "12346")
            .expect("test should write other warm port file");

        cleanup_warm_server_for_socket_in_dir(&dir, Some("preview"));

        assert!(!dir.join("preview____warm__.port").exists());
        assert!(!dir.join("preview____warm__.key").exists());
        assert!(!session_registry_path(&dir, "preview____warm__").exists());
        assert!(dir.join("preview__0.port").exists());
        assert!(dir.join("other____warm__.port").exists());
    }

    #[test]
    fn cleanup_stale_port_files_preserves_recent_starting_registry_files() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("recent-starting-registry");
        let psmux_dir = temp_home.join(".psmux");
        let port_path = psmux_dir.join("starting.port");
        let key_path = psmux_dir.join("starting.key");

        std::fs::write(&port_path, "not-a-port")
            .expect("test should write recent port file");
        std::fs::write(&key_path, "secret")
            .expect("test should write recent key file");
        let created_at = session_registry_now_millis();
        let process_started_at = current_process_started_at_millis().unwrap_or(created_at);
        write_session_registry(
            &psmux_dir,
            "starting",
            42123,
            "normal",
            "starting",
            "fresh-starting-nonce",
            process_started_at,
            created_at,
            None,
        )
        .expect("test should write starting registry");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        cleanup_stale_port_files();

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let port_exists = port_path.exists();
        let key_exists = key_path.exists();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(port_exists, "recent starting .port file must not be deleted");
        assert!(key_exists, "recent starting .key file must not be deleted");
    }

    #[test]
    fn cleanup_stale_port_files_removes_old_versioned_dead_registry_files() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("old-dead-registry");
        let psmux_dir = temp_home.join(".psmux");
        let port_path = psmux_dir.join("dead.port");
        let key_path = psmux_dir.join("dead.key");
        let registry_path = session_registry_path(&psmux_dir, "dead");
        let created_at = session_registry_now_millis().saturating_sub(120_000);

        std::fs::write(&port_path, "not-a-port")
            .expect("test should write stale port file");
        std::fs::write(&key_path, "secret").expect("test should write stale key file");
        write_session_registry(
            &psmux_dir,
            "dead",
            42124,
            "normal",
            "ready",
            "old-dead-nonce",
            created_at,
            created_at,
            Some(created_at + 250),
        )
        .expect("test should write dead registry");
        let mut registry: serde_json::Value = serde_json::from_slice(
            &std::fs::read(&registry_path).expect("test should read dead registry"),
        )
        .expect("test registry should be valid JSON");
        registry["server_pid"] = serde_json::json!(u32::MAX);
        std::fs::write(
            &registry_path,
            serde_json::to_vec_pretty(&registry).expect("test should serialize dead registry"),
        )
        .expect("test should rewrite dead registry");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        cleanup_stale_port_files();

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let port_exists = port_path.exists();
        let key_exists = key_path.exists();
        let registry_exists = registry_path.exists();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(!port_exists, "old dead .port file should be removed");
        assert!(!key_exists, "old dead .key file should be removed");
        assert!(
            !registry_exists,
            "old dead registry file should be removed with port/key"
        );
    }

    #[test]
    fn cleanup_stale_port_files_tolerates_concurrent_startup_cleanup_passes() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("concurrent-startup-cleanup");
        let psmux_dir = temp_home.join(".psmux");
        let starting_port_path = psmux_dir.join("starting-race.port");
        let starting_key_path = psmux_dir.join("starting-race.key");
        let starting_registry_path = session_registry_path(&psmux_dir, "starting-race");

        std::fs::write(&starting_port_path, "not-a-port")
            .expect("test should write starting port file");
        std::fs::write(&starting_key_path, "secret")
            .expect("test should write starting key file");
        let created_at = session_registry_now_millis();
        let process_started_at = current_process_started_at_millis().unwrap_or(created_at);
        write_session_registry(
            &psmux_dir,
            "starting-race",
            42131,
            "normal",
            "starting",
            "starting-race-nonce",
            process_started_at,
            created_at,
            None,
        )
        .expect("test should write starting registry");

        for index in 0..12 {
            let base = format!("dead-race-{index}");
            let port_path = psmux_dir.join(format!("{base}.port"));
            let key_path = psmux_dir.join(format!("{base}.key"));
            let registry_path = session_registry_path(&psmux_dir, &base);
            let old_created_at = created_at.saturating_sub(120_000 + index);

            std::fs::write(&port_path, "not-a-port")
                .expect("test should write dead race port file");
            std::fs::write(&key_path, "secret").expect("test should write dead race key file");
            write_session_registry(
                &psmux_dir,
                &base,
                42140 + index as u16,
                "normal",
                "ready",
                &format!("dead-race-nonce-{index}"),
                old_created_at,
                old_created_at,
                Some(old_created_at + 250),
            )
            .expect("test should write dead race registry");
            let mut registry: serde_json::Value = serde_json::from_slice(
                &std::fs::read(&registry_path).expect("test should read dead race registry"),
            )
            .expect("test registry should be valid JSON");
            registry["server_pid"] = serde_json::json!(u32::MAX);
            std::fs::write(
                &registry_path,
                serde_json::to_vec_pretty(&registry)
                    .expect("test should serialize dead race registry"),
            )
            .expect("test should rewrite dead race registry");
        }

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        let handles: Vec<_> = (0..8)
            .map(|_| std::thread::spawn(cleanup_stale_port_files))
            .collect();
        for handle in handles {
            handle
                .join()
                .expect("cleanup worker should not panic during race soak");
        }

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let starting_port_exists = starting_port_path.exists();
        let starting_key_exists = starting_key_path.exists();
        let starting_registry_exists = starting_registry_path.exists();
        let dead_entries: Vec<_> = std::fs::read_dir(&psmux_dir)
            .expect("test should read psmux dir")
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().starts_with("dead-race-"))
            .collect();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(
            starting_port_exists,
            "concurrent cleanup must preserve recent starting .port evidence"
        );
        assert!(
            starting_key_exists,
            "concurrent cleanup must preserve recent starting .key evidence"
        );
        assert!(
            starting_registry_exists,
            "concurrent cleanup must preserve recent starting registry evidence"
        );
        assert!(
            dead_entries.is_empty(),
            "concurrent cleanup should remove all dead race fixtures"
        );
    }

    #[test]
    fn cleanup_stale_port_files_preserves_mismatched_registry_files() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("mismatched-registry");
        let psmux_dir = temp_home.join(".psmux");
        let port_path = psmux_dir.join("victim.port");
        let key_path = psmux_dir.join("victim.key");
        let registry_path = session_registry_path(&psmux_dir, "victim");
        let created_at = session_registry_now_millis().saturating_sub(120_000);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));

        std::fs::write(&port_path, "not-a-port")
            .expect("test should write victim port file");
        std::fs::write(&key_path, "secret").expect("test should write victim key file");
        let registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "other",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": created_at,
            "server_exe": server_exe,
            "instance_nonce": "mismatched-nonce",
            "port": 42125,
            "state": "ready",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": created_at + 250
        });
        std::fs::write(
            &registry_path,
            serde_json::to_vec_pretty(&registry).expect("test should serialize registry"),
        )
        .expect("test should write mismatched registry");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        cleanup_stale_port_files();

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let port_exists = port_path.exists();
        let key_exists = key_path.exists();
        let registry_exists = registry_path.exists();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(port_exists, "mismatched registry must not remove .port");
        assert!(key_exists, "mismatched registry must not remove .key");
        assert!(registry_exists, "mismatched registry must be preserved");
    }

    #[test]
    fn cleanup_stale_port_files_preserves_live_registry_process_files() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("live-registry-process");
        let psmux_dir = temp_home.join(".psmux");
        let port_path = psmux_dir.join("live.port");
        let key_path = psmux_dir.join("live.key");
        let registry_path = session_registry_path(&psmux_dir, "live");
        let created_at = session_registry_now_millis().saturating_sub(120_000);
        let process_started_at = current_process_started_at_millis().unwrap_or(created_at);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));

        std::fs::write(&port_path, "not-a-port")
            .expect("test should write live port file");
        std::fs::write(&key_path, "secret").expect("test should write live key file");
        let registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "live",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": process_started_at,
            "server_exe": server_exe,
            "instance_nonce": "live-registry-nonce",
            "port": 42126,
            "state": "ready",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": created_at + 250
        });
        std::fs::write(
            &registry_path,
            serde_json::to_vec_pretty(&registry).expect("test should serialize registry"),
        )
        .expect("test should write live registry");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        cleanup_stale_port_files();

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let port_exists = port_path.exists();
        let key_exists = key_path.exists();
        let registry_exists = registry_path.exists();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(port_exists, "live registry process must preserve .port");
        assert!(key_exists, "live registry process must preserve .key");
        assert!(registry_exists, "live registry process must preserve registry");
    }

    #[cfg(windows)]
    #[test]
    fn cleanup_stale_port_files_removes_reused_pid_registry_when_start_time_differs() {
        let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
        let old_userprofile = env::var_os("USERPROFILE");
        let old_home = env::var_os("HOME");
        let temp_home = make_temp_psmux_home("reused-pid-registry");
        let psmux_dir = temp_home.join(".psmux");
        let port_path = psmux_dir.join("reused.port");
        let key_path = psmux_dir.join("reused.key");
        let registry_path = session_registry_path(&psmux_dir, "reused");
        let created_at = session_registry_now_millis().saturating_sub(120_000);
        let actual_started_at = current_process_started_at_millis().unwrap_or(created_at);
        let stale_started_at = actual_started_at.saturating_sub(1);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));

        std::fs::write(&port_path, "not-a-port")
            .expect("test should write reused pid port file");
        std::fs::write(&key_path, "secret").expect("test should write reused pid key file");
        let registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "reused",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": stale_started_at,
            "server_exe": server_exe,
            "instance_nonce": "reused-pid-nonce",
            "port": 42127,
            "state": "ready",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": created_at + 250
        });
        std::fs::write(
            &registry_path,
            serde_json::to_vec_pretty(&registry).expect("test should serialize registry"),
        )
        .expect("test should write reused pid registry");

        env::set_var("USERPROFILE", &temp_home);
        env::set_var("HOME", &temp_home);
        cleanup_stale_port_files();

        restore_env("USERPROFILE", old_userprofile);
        restore_env("HOME", old_home);
        let port_exists = port_path.exists();
        let key_exists = key_path.exists();
        let registry_exists = registry_path.exists();
        let _ = std::fs::remove_dir_all(&temp_home);

        assert!(
            !port_exists,
            "reused pid registry must not preserve stale .port"
        );
        assert!(
            !key_exists,
            "reused pid registry must not preserve stale .key"
        );
        assert!(
            !registry_exists,
            "reused pid registry must not preserve registry"
        );
    }

    #[test]
    fn registry_owner_must_match_base_for_cleanup_and_liveness_evidence() {
        let created_at = session_registry_now_millis();
        let process_started_at = current_process_started_at_millis().unwrap_or(created_at);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));
        let normal_registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "normal",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": process_started_at,
            "server_exe": server_exe,
            "instance_nonce": "normal-owner-nonce",
            "port": 42128,
            "state": "ready",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": created_at + 250
        });
        let mut warm_owned_normal_registry = normal_registry.clone();
        warm_owned_normal_registry["owner"] = serde_json::json!("warm");

        assert!(registry_has_cleanup_ownership_evidence(
            &normal_registry,
            "normal"
        ));
        assert!(registry_server_pid(&normal_registry, "normal").is_some());
        assert!(
            !registry_has_cleanup_ownership_evidence(&warm_owned_normal_registry, "normal"),
            "warm owner metadata must not authorize normal session cleanup"
        );
        assert!(
            registry_server_pid(&warm_owned_normal_registry, "normal").is_none(),
            "warm owner metadata must not preserve normal session liveness"
        );
    }

    #[test]
    fn registry_owner_must_match_base_for_startup_deadline_evidence() {
        let created_at = session_registry_now_millis();
        let process_started_at = current_process_started_at_millis().unwrap_or(created_at);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));
        let normal_starting_registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "normal-starting",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": process_started_at,
            "server_exe": server_exe,
            "instance_nonce": "normal-starting-nonce",
            "port": 42129,
            "state": "starting",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": null
        });
        let mut warm_owned_starting_registry = normal_starting_registry.clone();
        warm_owned_starting_registry["owner"] = serde_json::json!("warm");

        assert!(registry_is_within_startup_deadline(
            &normal_starting_registry,
            "normal-starting"
        ));
        assert!(
            !registry_is_within_startup_deadline(
                &warm_owned_starting_registry,
                "normal-starting"
            ),
            "warm owner metadata must not preserve normal starting files"
        );
    }

    #[cfg(windows)]
    #[test]
    fn startup_deadline_requires_matching_process_start_time() {
        let created_at = session_registry_now_millis();
        let actual_started_at = current_process_started_at_millis().unwrap_or(created_at);
        let stale_started_at = actual_started_at.saturating_sub(120_000);
        let server_exe = env::current_exe()
            .ok()
            .map(|path| normalize_socket_selector_path(&path));
        let stale_starting_registry = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "starting-reused",
            "namespace": null,
            "server_pid": std::process::id(),
            "process_started_at": stale_started_at,
            "server_exe": server_exe,
            "instance_nonce": "starting-reused-nonce",
            "port": 42130,
            "state": "starting",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": null
        });

        assert!(
            !registry_is_within_startup_deadline(&stale_starting_registry, "starting-reused"),
            "starting registry grace must not bypass PID reuse protection"
        );
    }

    #[test]
    fn write_session_registry_publishes_versioned_non_secret_metadata() {
        let dir = make_temp_psmux_dir("session-registry-metadata");
        let created_at = 1_782_196_000_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let ready_at = Some(created_at + 250);
        let nonce = "nonce-for-test";

        write_session_registry(
            &dir,
            "ops__bench",
            42123,
            "normal",
            "ready",
            nonce,
            process_started_at,
            created_at,
            ready_at,
        )
        .expect("test should write session registry");

        let path = session_registry_path(&dir, "ops__bench");
        let text = std::fs::read_to_string(&path).expect("test should read registry");
        let json: serde_json::Value =
            serde_json::from_str(&text).expect("registry should be valid JSON");
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        assert_eq!(
            json["protocol_version"].as_u64(),
            Some(SESSION_REGISTRY_PROTOCOL_VERSION as u64)
        );
        assert_eq!(json["session"], "ops__bench");
        assert_eq!(json["namespace"], "ops");
        assert_eq!(json["server_pid"].as_u64(), Some(std::process::id() as u64));
        assert!(
            json["server_exe"].as_str().is_some_and(|value| !value.is_empty()),
            "session registry should include launch path evidence"
        );
        assert_eq!(json["instance_nonce"], nonce);
        assert_eq!(json["port"], 42123);
        assert_eq!(json["state"], "ready");
        assert_eq!(json["owner"], "normal");
        assert_eq!(
            json["process_started_at"].as_u64(),
            Some(process_started_at as u64)
        );
        assert_eq!(json["created_at"].as_u64(), Some(created_at as u64));
        assert_eq!(json["ready_at"].as_u64(), Some(ready_at.unwrap() as u64));
        assert!(
            !text.contains("secret"),
            "session registry metadata must not contain credential material"
        );
    }

    #[test]
    fn write_session_registry_publishes_restore_metadata_without_secret_material() {
        let dir = make_temp_psmux_dir("session-registry-restore-metadata");
        let created_at = 1_782_196_100_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let restore = sample_restore_metadata(vec![sample_pane_restore_metadata(
            "%2",
            0,
            0,
            Some("context-capsule:task-757:abc123"),
            Some("checkpoint:task-757:abc123"),
        )]);

        write_session_registry_with_restore_metadata(
            &dir,
            "ops__restore",
            42124,
            "normal",
            "ready",
            "nonce-for-restore-test",
            process_started_at,
            created_at,
            Some(created_at + 250),
            Some(&restore),
        )
        .expect("test should write session registry restore metadata");

        let path = session_registry_path(&dir, "ops__restore");
        let text = std::fs::read_to_string(&path).expect("test should read registry");
        let json: serde_json::Value =
            serde_json::from_str(&text).expect("registry should be valid JSON");
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        assert_eq!(
            json["protocol_version"].as_u64(),
            Some(SESSION_REGISTRY_PROTOCOL_VERSION as u64)
        );
        assert_eq!(json["restore"]["restore_metadata_version"], 1);
        assert_eq!(json["restore"]["layer"], "session_persistence_layer1");
        assert_eq!(json["restore"]["panes"][0]["pane_id"], "%2");
        assert_eq!(
            json["restore"]["panes"][0]["transcript_ring_summary"]["raw_transcript_stored"],
            false
        );
        assert!(
            !text.contains("secret") && !text.contains("token") && !text.contains("Users"),
            "restore metadata must not contain secret material or private local paths"
        );
    }

    #[test]
    fn enumerate_session_restore_candidates_filters_warm_and_legacy_registry() {
        let dir = make_temp_psmux_dir("session-restore-candidates");
        let created_at = 1_782_196_200_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let restore = sample_restore_metadata(vec![sample_pane_restore_metadata(
            "%2",
            0,
            0,
            Some("context-capsule:task-757:abc123"),
            Some("checkpoint:task-757:abc123"),
        )]);

        write_session_registry_with_restore_metadata(
            &dir,
            "ops__restore",
            42125,
            "normal",
            "ready",
            "nonce-restore",
            process_started_at,
            created_at,
            Some(created_at + 250),
            Some(&restore),
        )
        .expect("restore candidate registry should be written");
        write_session_registry(
            &dir,
            "ops__legacy",
            42126,
            "normal",
            "ready",
            "nonce-legacy",
            process_started_at,
            created_at,
            Some(created_at + 250),
        )
        .expect("legacy registry should be written");
        write_session_registry_with_restore_metadata(
            &dir,
            &warm_session_base(Some("ops")),
            42127,
            "warm",
            "ready",
            "nonce-warm",
            process_started_at,
            created_at,
            Some(created_at + 250),
            Some(&restore),
        )
        .expect("warm registry should be written");

        let candidates = enumerate_session_restore_candidates_in_dir(&dir);
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].session, "ops__restore");
        assert_eq!(candidates[0].namespace.as_deref(), Some("ops"));
        assert_eq!(candidates[0].owner, "normal");
        assert_eq!(candidates[0].state, "ready");
        assert_eq!(candidates[0].port, 42125);
        assert_eq!(candidates[0].panes[0].pane_id, "%2");
    }

    #[test]
    fn enumerate_session_restore_candidates_skips_malformed_restore_metadata() {
        let dir = make_temp_psmux_dir("session-restore-malformed");
        let created_at = 1_782_196_250_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let malformed = serde_json::json!({
            "protocol_version": SESSION_REGISTRY_PROTOCOL_VERSION,
            "session": "ops__restore",
            "namespace": "ops",
            "server_pid": std::process::id(),
            "process_started_at": process_started_at,
            "server_exe": env::current_exe()
                .ok()
                .map(|path| normalize_socket_selector_path(&path)),
            "instance_nonce": "nonce-malformed",
            "port": 42129,
            "state": "ready",
            "owner": "normal",
            "created_at": created_at,
            "ready_at": created_at + 250,
            "restore": {
                "restore_metadata_version": 1,
                "layer": "session_persistence_layer1",
                "panes": [
                    {
                        "pane_id": "%2"
                    }
                ]
            }
        });
        let text = serde_json::to_vec_pretty(&malformed).expect("test JSON should serialize");
        std::fs::write(session_registry_path(&dir, "ops__restore"), text)
            .expect("test should write malformed registry");

        let candidates = enumerate_session_restore_candidates_in_dir(&dir);
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        assert!(
            candidates.is_empty(),
            "malformed restore metadata must fail closed instead of becoming a candidate"
        );
    }

    #[test]
    fn enumerate_session_restore_candidates_preserves_pane_order() {
        let dir = make_temp_psmux_dir("session-restore-pane-order");
        let created_at = 1_782_196_300_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let restore = sample_restore_metadata(vec![
            sample_pane_restore_metadata("%4", 1, 1, None, Some("checkpoint:task-757:def456")),
            sample_pane_restore_metadata("%3", 0, 1, None, Some("checkpoint:task-757:abc124")),
            sample_pane_restore_metadata("%2", 0, 0, None, Some("checkpoint:task-757:abc123")),
        ]);

        write_session_registry_with_restore_metadata(
            &dir,
            "ops__restore",
            42128,
            "normal",
            "ready",
            "nonce-restore-order",
            process_started_at,
            created_at,
            Some(created_at + 250),
            Some(&restore),
        )
        .expect("restore candidate registry should be written");

        let candidates = enumerate_session_restore_candidates_in_dir(&dir);
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        let pane_ids: Vec<&str> = candidates[0]
            .panes
            .iter()
            .map(|pane| pane.pane_id.as_str())
            .collect();
        assert_eq!(pane_ids, vec!["%2", "%3", "%4"]);
    }

    #[test]
    fn enumerate_session_restore_candidates_marks_expired_panes_setup_required() {
        let dir = make_temp_psmux_dir("session-restore-expired-pane");
        let created_at = 1_782_196_350_000_u128;
        let process_started_at = created_at.saturating_sub(10_000);
        let mut pane =
            sample_pane_restore_metadata("%2", 0, 0, None, Some("checkpoint:task-759:expired"));
        pane.restore_state = "pane_exited".to_string();
        let restore = sample_restore_metadata(vec![pane]);

        write_session_registry_with_restore_metadata(
            &dir,
            "ops__expired",
            42130,
            "normal",
            "ready",
            "nonce-expired",
            process_started_at,
            created_at,
            Some(created_at + 250),
            Some(&restore),
        )
        .expect("expired pane registry should be written");

        let candidates = enumerate_session_restore_candidates_in_dir(&dir);
        let _ = std::fs::remove_dir_all(dir.parent().expect("temp dir should have parent"));

        assert_eq!(candidates.len(), 1);
        assert_eq!(
            candidates[0].panes[0].restore_state,
            SESSION_RESTORE_STATE_SETUP_REQUIRED
        );
        assert_eq!(
            candidates[0].panes[0].setup_required_reason.as_deref(),
            Some(SESSION_RESTORE_SETUP_REASON_AGENT_SESSION_EXPIRED)
        );
    }

    fn sample_restore_metadata(
        panes: Vec<SessionRegistryPaneRestoreMetadata>,
    ) -> SessionRegistryRestoreMetadata {
        SessionRegistryRestoreMetadata {
            restore_metadata_version: 1,
            layer: "session_persistence_layer1".to_string(),
            panes,
        }
    }

    fn sample_pane_restore_metadata(
        pane_id: &str,
        window_index: usize,
        pane_index: usize,
        context_capsule_ref: Option<&str>,
        checkpoint_ref: Option<&str>,
    ) -> SessionRegistryPaneRestoreMetadata {
        SessionRegistryPaneRestoreMetadata {
            pane_id: pane_id.to_string(),
            window_id: "window-1".to_string(),
            window_index,
            pane_index,
            agent_cli_session_id: Some(pane_id.to_string()),
            transcript_ring_summary: SessionRegistryTranscriptRingSummary {
                byte_count: 256,
                sha256: Some("abc123".to_string()),
                raw_transcript_stored: false,
            },
            worktree: Some(".worktrees/builder-1".to_string()),
            branch: Some("codex/task-757".to_string()),
            provider_target: Some("codex:gpt-5.5".to_string()),
            model: Some("gpt-5.5".to_string()),
            model_source: Some("provider_target".to_string()),
            context_capsule_ref: context_capsule_ref.map(str::to_string),
            checkpoint_ref: checkpoint_ref.map(str::to_string),
            restore_state: "candidate".to_string(),
            setup_required_reason: None,
        }
    }

    fn make_temp_psmux_dir(name: &str) -> std::path::PathBuf {
        make_temp_psmux_home(name).join(".psmux")
    }

    fn make_temp_psmux_home(name: &str) -> std::path::PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "winsmux-{name}-{}-{suffix}",
            std::process::id()
        ));
        std::fs::create_dir_all(path.join(".psmux")).expect("test should create temp dir");
        path
    }

    fn restore_env(name: &str, value: Option<std::ffi::OsString>) {
        if let Some(value) = value {
            env::set_var(name, value);
        } else {
            env::remove_var(name);
        }
    }
}
