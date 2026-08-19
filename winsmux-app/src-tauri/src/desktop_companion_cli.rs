use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::desktop_backend::{apply_desktop_winsmux_child_env, hide_subprocess_window};

pub(crate) fn build_companion_ledger_command(
    companion: &Path,
    effective_project_dir: &Path,
    args: &[String],
    app_pid: u32,
) -> Command {
    let mut command = Command::new(companion);
    command.args(args).current_dir(effective_project_dir);
    apply_desktop_winsmux_child_env(&mut command, Some(companion), app_pid);
    hide_subprocess_window(&mut command);
    command
}

pub(crate) fn build_companion_stream_command(
    companion: &Path,
    effective_project_dir: &Path,
    args: &[String],
    app_pid: u32,
) -> Command {
    let mut command =
        build_companion_ledger_command(companion, effective_project_dir, args, app_pid);
    command
        .env("WINSMUX_DESKTOP_SUMMARY_STREAM_POLL_SECONDS", "5")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

pub(crate) fn spawn_companion_stream_child(
    companion: &Path,
    effective_project_dir: &Path,
    args: &[String],
    app_pid: u32,
) -> std::io::Result<std::process::Child> {
    let mut command =
        build_companion_stream_command(companion, effective_project_dir, args, app_pid);
    let child = command.spawn()?;
    #[cfg(test)]
    record_spawned_companion(companion.to_path_buf(), child.id());
    Ok(child)
}

pub(crate) fn force_terminate_child(child: &mut std::process::Child) {
    let pid = child.id();
    let _ = child.kill();
    force_terminate_pid(pid);
}

pub(crate) fn force_terminate_pid(pid: u32) {
    #[cfg(windows)]
    {
        unsafe {
            use windows_sys::Win32::Foundation::CloseHandle;
            use windows_sys::Win32::System::Threading::{
                OpenProcess, TerminateProcess, PROCESS_TERMINATE,
            };
            let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !handle.is_null() {
                let _ = TerminateProcess(handle, 1);
                let _ = CloseHandle(handle);
            }
        }
        let mut command = Command::new("taskkill");
        command
            .args(["/F", "/T", "/PID", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        hide_subprocess_window(&mut command);
        let _ = command.status();
    }
    #[cfg(not(windows))]
    {
        let _ = pid;
    }
}

#[cfg(test)]
use std::cell::RefCell;
#[cfg(test)]
use std::sync::Mutex;

#[cfg(test)]
#[derive(Clone, Debug)]
pub(crate) struct SpawnedCompanion {
    pub program: PathBuf,
    pub pid: u32,
}

#[cfg(test)]
thread_local! {
    static COMPANION_CLI_OVERRIDE: RefCell<Option<Option<PathBuf>>> = RefCell::new(None);
}

#[cfg(test)]
static LAST_SPAWNED: Mutex<Option<SpawnedCompanion>> = Mutex::new(None);

#[cfg(test)]
pub(crate) fn companion_cli_override() -> Option<Option<PathBuf>> {
    COMPANION_CLI_OVERRIDE.with(|cell| cell.borrow().clone())
}

#[cfg(test)]
pub(crate) fn set_companion_cli_override(path: Option<PathBuf>) {
    COMPANION_CLI_OVERRIDE.with(|cell| *cell.borrow_mut() = Some(path));
    *LAST_SPAWNED.lock().expect("spawn probe") = None;
}

#[cfg(test)]
pub(crate) fn clear_companion_cli_override() {
    COMPANION_CLI_OVERRIDE.with(|cell| *cell.borrow_mut() = None);
}

#[cfg(test)]
pub(crate) fn last_spawned_companion() -> Option<SpawnedCompanion> {
    LAST_SPAWNED.lock().ok().and_then(|guard| guard.clone())
}

#[cfg(test)]
fn record_spawned_companion(program: PathBuf, pid: u32) {
    if let Ok(mut guard) = LAST_SPAWNED.lock() {
        *guard = Some(SpawnedCompanion { program, pid });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop_backend::{
        load_desktop_summary_snapshot, resolve_companion_winsmux_cli,
        spawn_desktop_summary_refresh_stream, DesktopCommand, DesktopCommandTransport,
        DesktopStreamCommand, DesktopSummarySnapshot, PwshScriptTransport,
    };
    use serde_json::Value;
    use std::ffi::OsStr;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    struct CompanionOverrideGuard;

    impl Drop for CompanionOverrideGuard {
        fn drop(&mut self) {
            clear_companion_cli_override();
        }
    }

    fn override_companion(path: Option<PathBuf>) -> CompanionOverrideGuard {
        set_companion_cli_override(path);
        CompanionOverrideGuard
    }

    fn workspace_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
    }

    fn winsmux_cli_candidates() -> Vec<PathBuf> {
        let mut candidates = Vec::new();
        if let Some(dir) = std::env::var_os("CARGO_TARGET_DIR") {
            candidates.push(PathBuf::from(dir).join("debug").join("winsmux.exe"));
        }
        let root = workspace_root();
        candidates.push(root.join("target").join("debug").join("winsmux.exe"));
        candidates.push(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("target")
                .join("debug")
                .join("winsmux.exe"),
        );
        candidates
    }

    fn ensure_winsmux_cli() -> PathBuf {
        for candidate in winsmux_cli_candidates() {
            if candidate.is_file() {
                return candidate;
            }
        }
        let status = Command::new("cargo")
            .args(["build", "-p", "winsmux"])
            .current_dir(workspace_root())
            .status()
            .expect("cargo build -p winsmux should start");
        assert!(status.success(), "cargo build -p winsmux failed");
        winsmux_cli_candidates()
            .into_iter()
            .find(|path| path.is_file())
            .expect("winsmux.exe should exist after cargo build -p winsmux")
    }

    fn make_temp_project_dir(name: &str) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "winsmux-{name}-{}-{suffix}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("temp project dir");
        path
    }

    fn write_manifest(project_dir: &Path) {
        let winsmux_dir = project_dir.join(".winsmux");
        fs::create_dir_all(&winsmux_dir).expect("create .winsmux");
        fs::write(
            winsmux_dir.join("manifest.yaml"),
            r#"
version: 1
session:
  name: winsmux-orchestra
panes:
  builder-1:
    pane_id: "%2"
    role: Builder
    state: running
    task_id: TASK-266
    task: Add Rust operator read models
    task_state: in_progress
    parent_run_id: operator:session-1
    goal: Keep Rust read models aligned
    task_type: implementation
    priority: P0
    blocking: true
    review_state: pending
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: abc123
    changed_file_count: 2
    changed_files: '["core/src/main.rs","core/src/operator_cli.rs"]'
    write_scope: '["core/src/operator_cli.rs"]'
    read_scope: '["scripts/winsmux-core.ps1"]'
    constraints: '["preserve PowerShell JSON shape"]'
    expected_output: Rust read-only CLI
    verification_plan: '["cargo test --manifest-path core/Cargo.toml --test operator_cli"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-24T12:00:00+09:00
  reviewer-1:
    pane_id: "%3"
    role: Reviewer
    state: idle
    task_state: waiting
    review_state: PASS
    branch: codex/task266-rust-operator-readmodels-20260424
    head_sha: def456
"#,
        )
        .expect("write manifest");
        fs::create_dir_all(winsmux_dir.join("observation-packs")).expect("observation dir");
        fs::create_dir_all(winsmux_dir.join("consultations")).expect("consult dir");
        fs::write(
            winsmux_dir.join("observation-packs").join("task-266.json"),
            r#"{"packet_type":"observation_pack","run_id":"task:TASK-266","summary":"captured operator read model"}"#,
        )
        .expect("write observation pack");
        fs::write(
            winsmux_dir.join("consultations").join("task-266.json"),
            r#"{"packet_type":"consultation_packet","run_id":"task:TASK-266","recommendation":"keep read-only"}"#,
        )
        .expect("write consultation packet");
        fs::write(
            winsmux_dir.join("events.jsonl"),
            r#"{"timestamp":"2026-04-24T12:00:01+09:00","session":"winsmux-orchestra","event":"operator.review_requested","message":"review requested","label":"builder-1","pane_id":"%2","role":"Builder","status":"review_requested","data":{"task_id":"TASK-266","run_id":"task:TASK-266","hypothesis":"Rust can read operator evidence","test_plan":["read manifest"],"result":"captured","confidence":0.91,"next_action":"commit_ready","observation_pack_ref":".winsmux/observation-packs/task-266.json","consultation_ref":".winsmux/consultations/task-266.json"}}
{"timestamp":"2026-04-24T12:00:02+09:00","session":"winsmux-orchestra","event":"operator.commit_ready","message":"ready to commit","label":"builder-1","pane_id":"%2","role":"Builder","status":"commit_ready","data":{"task_id":"TASK-266"}}
"#,
        )
        .expect("write events");
    }

    fn canonicalize_json(value: Value) -> Value {
        match value {
            Value::Object(map) => {
                let mut items: Vec<_> = map
                    .into_iter()
                    .map(|(key, child)| (key, canonicalize_json(child)))
                    .collect();
                items.sort_by(|left, right| left.0.cmp(&right.0));
                Value::Object(items.into_iter().collect())
            }
            Value::Array(items) => {
                Value::Array(items.into_iter().map(canonicalize_json).collect())
            }
            other => other,
        }
    }

    fn snapshot_fingerprint(snapshot: &DesktopSummarySnapshot) -> Value {
        let mut value = serde_json::to_value(snapshot).expect("serialize snapshot");
        if let Some(object) = value.as_object_mut() {
            object.remove("generated_at");
        }
        canonicalize_json(value)
    }

    fn process_image_name(pid: u32) -> Option<String> {
        let mut command = Command::new("tasklist");
        command.args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let output = command.output().ok()?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().next()?.trim();
        if !line.starts_with('"') {
            return None;
        }
        let mut parts = line.split(',');
        let name = parts.next()?.trim_matches('"').to_string();
        let listed_pid = parts.next()?.trim_matches('"');
        if listed_pid != pid.to_string() || name.is_empty() {
            return None;
        }
        Some(name)
    }

    #[cfg(windows)]
    fn process_is_running(pid: u32) -> bool {
        unsafe {
            use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
            use windows_sys::Win32::System::Threading::{
                GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            };
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            let _ = CloseHandle(handle);
            ok != 0 && code == STILL_ACTIVE as u32
        }
    }

    #[test]
    fn summary_transport_spawns_companion_winsmux_not_pwsh() {
        let companion = PathBuf::from(r"C:\winsmux-task801\winsmux.exe");
        let project_dir = PathBuf::from(r"C:\winsmux-task801\project");
        let args = vec!["desktop-summary".to_string(), "--json".to_string()];
        let command = build_companion_ledger_command(&companion, &project_dir, &args, 4242);
        let program = PathBuf::from(command.get_program());
        assert_eq!(program, companion);
        assert_ne!(program.file_name(), Some(OsStr::new("pwsh")));
        assert_ne!(program.file_name(), Some(OsStr::new("pwsh.exe")));
        let argv: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(argv, args);
        assert!(!argv.iter().any(|arg| arg.eq_ignore_ascii_case("pwsh")));
        assert!(!argv.iter().any(|arg| arg == "-NoProfile"));

        let _guard = override_companion(None);
        assert!(
            resolve_companion_winsmux_cli().is_none(),
            "missing companion must fail closed"
        );
        let err = PwshScriptTransport
            .request_json(&DesktopCommand::SummarySnapshot {
                project_dir: Some(project_dir.display().to_string()),
            })
            .expect_err("missing companion must not start pwsh");
        assert!(
            err.contains("companion winsmux CLI was not found"),
            "unexpected transport error: {err}"
        );
        let stop = Arc::new(AtomicBool::new(false));
        let spawn_err = spawn_desktop_summary_refresh_stream(
            DesktopStreamCommand::Summary {
                project_dir: Some(project_dir.display().to_string()),
            },
            stop,
            |_| {},
        )
        .expect_err("missing companion must fail before stream thread spawn");
        assert!(
            spawn_err.contains("companion winsmux CLI was not found"),
            "unexpected stream error: {spawn_err}"
        );
    }

    #[test]
    fn desktop_summary_snapshot_json_matches_cli_desktop_summary() {
        let bin = ensure_winsmux_cli();
        let _guard = override_companion(Some(bin.clone()));
        let fixture = make_temp_project_dir("desktop-summary-parity");
        write_manifest(&fixture);

        let via_transport = load_desktop_summary_snapshot(
            &PwshScriptTransport,
            Some(fixture.to_string_lossy().into_owned()),
        )
        .expect("companion transport snapshot");

        let output = Command::new(&bin)
            .args(["desktop-summary", "--json"])
            .current_dir(&fixture)
            .output()
            .expect("winsmux desktop-summary --json should start");
        assert!(
            output.status.success(),
            "winsmux desktop-summary --json failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let via_cli: DesktopSummarySnapshot = serde_json::from_slice(&output.stdout)
            .expect("CLI desktop-summary JSON should parse as DesktopSummarySnapshot");

        assert_eq!(
            snapshot_fingerprint(&via_transport),
            snapshot_fingerprint(&via_cli)
        );
        let _ = fs::remove_dir_all(&fixture);
    }

    #[test]
    fn desktop_summary_refresh_stream_crash_leaves_no_pwsh_writer() {
        let bin = ensure_winsmux_cli();
        let mock_dir = make_temp_project_dir("desktop-summary-stream-mock");
        let mock_bin = mock_dir.join("winsmux.exe");
        fs::copy(&bin, &mock_bin).expect("copy companion winsmux.exe mock");
        let _guard = override_companion(Some(mock_bin.clone()));
        let fixture = make_temp_project_dir("desktop-summary-stream");
        write_manifest(&fixture);

        let stream_command = build_companion_stream_command(
            &mock_bin,
            &fixture,
            &[
                "desktop-summary".to_string(),
                "--stream".to_string(),
                "--json".to_string(),
            ],
            4242,
        );
        let program = PathBuf::from(stream_command.get_program());
        assert_eq!(program, mock_bin);
        assert_eq!(program.file_name(), Some(OsStr::new("winsmux.exe")));
        assert_ne!(program.file_name(), Some(OsStr::new("pwsh.exe")));

        let stop = Arc::new(AtomicBool::new(false));
        spawn_desktop_summary_refresh_stream(
            DesktopStreamCommand::Summary {
                project_dir: Some(fixture.to_string_lossy().into_owned()),
            },
            stop.clone(),
            |_| {},
        )
        .expect("companion stream should start");

        let spawned = (0..200)
            .find_map(|_| match last_spawned_companion() {
                Some(spawned) if spawned.program == mock_bin => Some(spawned),
                _ => {
                    thread::sleep(Duration::from_millis(50));
                    None
                }
            })
            .expect("stream should spawn a companion child");
        assert_ne!(spawned.pid, 0, "companion child pid");
        let image = process_image_name(spawned.pid).unwrap_or_default();
        assert!(
            image.to_ascii_lowercase().contains("winsmux"),
            "child image should be companion winsmux, got {image:?}"
        );
        assert!(
            !image.to_ascii_lowercase().contains("pwsh"),
            "this spawn must not be pwsh, got {image:?}"
        );

        stop.store(true, Ordering::SeqCst);
        force_terminate_pid(spawned.pid);
        let gone = (0..200).any(|_| {
            if !process_is_running(spawned.pid) {
                true
            } else {
                thread::sleep(Duration::from_millis(50));
                false
            }
        });
        assert!(gone, "killed stream child should not keep writing");
        let _ = fs::remove_dir_all(&fixture);
        let _ = fs::remove_dir_all(&mock_dir);
    }
}
