mod control_pipe;
mod desktop_backend;
mod pty_backend;

use control_pipe::{start_control_pipe_server, WINSMUX_CONTROL_PIPE_TOKEN_ENV};
use desktop_backend::{
    handle_desktop_json_rpc, load_desktop_run_explain, load_desktop_summary_snapshot,
    resolve_repo_root, spawn_desktop_summary_refresh_stream, DesktopExplainPayload,
    DesktopJsonRpcRequest, DesktopJsonRpcResponse, DesktopStreamCommand,
    DesktopSummaryRefreshSignal, DesktopSummarySnapshot, DesktopVoiceCaptureStatus,
    PwshScriptTransport,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use pty_backend::{
    handle_pty_json_rpc, PtyCommand, PtyCommandTransport, PtyJsonRpcRequest, PtyJsonRpcResponse,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

#[cfg(windows)]
use windows_sys::Win32::Media::Audio::{
    waveInAddBuffer, waveInClose, waveInOpen, waveInPrepareHeader, waveInReset, waveInStart,
    waveInStop, waveInUnprepareHeader, CALLBACK_NULL, WAVEFORMATEX, WAVEHDR, WAVE_FORMAT_PCM,
    WAVE_MAPPER, WHDR_DONE,
};
#[cfg(windows)]
use windows_sys::Win32::Media::{
    MMSYSERR_ALLOCATED, MMSYSERR_BADDEVICEID, MMSYSERR_NODRIVER, MMSYSERR_NOERROR,
};

const DESKTOP_SUMMARY_REFRESH_EVENT: &str = "desktop-summary-refresh";
const PTY_CAPTURE_LIMIT: usize = 64 * 1024;
const PTY_READ_BUFFER_BYTES: usize = 4096;
const PTY_OUTPUT_BATCH_LIMIT: usize = 16 * 1024;
const PTY_OUTPUT_BATCH_INTERVAL_MS: u64 = 16;
const PTY_OUTPUT_QUEUE_CAPACITY: usize = 128;
const PTY_CLOSE_WAIT_MS: u64 = 250;
const DESKTOP_SHUTDOWN_PTY_WAIT_MS: u64 = 750;
const DESKTOP_SHUTDOWN_VOICE_WAIT_MS: u64 = 3_000;
const DESKTOP_UPDATE_PROGRESS_EVENT: &str = "desktop-update-progress";
const WINSMUX_RELEASE_API_URL: &str =
    "https://api.github.com/repos/Sora-bluesky/winsmux/releases/latest";
const NATIVE_VOICE_METER_ONLY_REASON: &str =
    "Native microphone capture is available for metering only; desktop dictation still uses the documented text fallback.";
const NATIVE_VOICE_DICTATION_FALLBACK_REASON: &str =
    "Use browser speech recognition for composer dictation. Native microphone capture does not transcribe audio into text.";

fn normalize_existing_launch_project_dir(value: &str) -> Option<String> {
    let trimmed = value.trim().trim_matches('"').trim();
    if trimmed.is_empty() {
        return None;
    }

    let path = PathBuf::from(trimmed);
    if path.is_dir() {
        Some(path.to_string_lossy().to_string())
    } else {
        None
    }
}

fn resolve_initial_project_dir_from_args<I>(args: I) -> Option<String>
where
    I: IntoIterator<Item = String>,
{
    let mut args = args.into_iter();
    let _ = args.next();

    while let Some(arg) = args.next() {
        let trimmed = arg.trim();
        if trimmed.is_empty() || trimmed == "--" {
            continue;
        }

        if trimmed == "--project-dir" || trimmed == "--workspace" {
            if let Some(value) = args.next() {
                if let Some(path) = normalize_existing_launch_project_dir(&value) {
                    return Some(path);
                }
            }
            continue;
        }

        if let Some(value) = trimmed.strip_prefix("--project-dir=") {
            if let Some(path) = normalize_existing_launch_project_dir(value) {
                return Some(path);
            }
            continue;
        }

        if let Some(value) = trimmed.strip_prefix("--workspace=") {
            if let Some(path) = normalize_existing_launch_project_dir(value) {
                return Some(path);
            }
            continue;
        }

        if trimmed.starts_with('-') {
            continue;
        }

        if let Some(path) = normalize_existing_launch_project_dir(trimmed) {
            return Some(path);
        }
    }

    None
}

#[tauri::command]
fn desktop_initial_project_dir() -> Option<String> {
    resolve_initial_project_dir_from_args(std::env::args())
}

#[tauri::command]
fn desktop_control_pipe_enabled() -> bool {
    std::env::var_os(WINSMUX_CONTROL_PIPE_TOKEN_ENV).is_some()
}

#[derive(Debug, Deserialize)]
struct GitHubReleaseAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
    assets: Vec<GitHubReleaseAsset>,
}

#[derive(Debug, Serialize)]
struct DesktopUpdateCheck {
    available: bool,
    current_version: String,
    latest_version: String,
    release_url: String,
    installer_name: Option<String>,
    installer_url: Option<String>,
    expected_sha256: Option<String>,
    reason: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct DesktopUpdateProgress {
    stage: String,
    downloaded: u64,
    total: Option<u64>,
    percent: Option<f64>,
}

#[derive(Debug, Serialize)]
struct DesktopUpdateDownloadResult {
    installer_path: String,
    installer_name: String,
    sha256: String,
}

fn normalize_release_version(value: &str) -> String {
    value.trim().trim_start_matches('v').trim().to_string()
}

fn parse_version_segments(value: &str) -> Vec<u64> {
    normalize_release_version(value)
        .split('.')
        .map(|segment| {
            segment
                .chars()
                .take_while(|character| character.is_ascii_digit())
                .collect::<String>()
                .parse::<u64>()
                .unwrap_or(0)
        })
        .collect()
}

fn is_newer_version(latest: &str, current: &str) -> bool {
    let mut left = parse_version_segments(latest);
    let mut right = parse_version_segments(current);
    let length = left.len().max(right.len()).max(3);
    left.resize(length, 0);
    right.resize(length, 0);
    left > right
}

fn strip_sha256_digest(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            value
                .strip_prefix("sha256:")
                .unwrap_or(value)
                .to_ascii_lowercase()
        })
}

fn fetch_latest_github_release() -> Result<GitHubRelease, String> {
    ureq::get(WINSMUX_RELEASE_API_URL)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "winsmux-desktop-updater")
        .call()
        .map_err(|err| format!("failed to fetch latest release metadata: {err}"))?
        .into_json::<GitHubRelease>()
        .map_err(|err| format!("failed to parse latest release metadata: {err}"))
}

fn select_windows_setup_asset<'a>(
    release: &'a GitHubRelease,
    latest_version: &str,
) -> Option<&'a GitHubReleaseAsset> {
    let expected_name = format!("winsmux_{latest_version}_x64-setup.exe");
    release
        .assets
        .iter()
        .find(|asset| asset.name == expected_name)
        .or_else(|| {
            release
                .assets
                .iter()
                .find(|asset| asset.name.ends_with("_x64-setup.exe"))
        })
}

#[tauri::command]
fn desktop_update_check() -> Result<DesktopUpdateCheck, String> {
    let current_version = env!("CARGO_PKG_VERSION").to_string();

    #[cfg(not(windows))]
    {
        return Ok(DesktopUpdateCheck {
            available: false,
            latest_version: current_version.clone(),
            current_version,
            release_url: "https://github.com/Sora-bluesky/winsmux/releases/latest".to_string(),
            installer_name: None,
            installer_url: None,
            expected_sha256: None,
            reason: Some(
                "Desktop in-app updates are supported only for Windows setup installer builds."
                    .to_string(),
            ),
        });
    }

    #[cfg(windows)]
    {
        let release = fetch_latest_github_release()?;
        let latest_version = normalize_release_version(&release.tag_name);
        let installer = select_windows_setup_asset(&release, &latest_version);
        let available = is_newer_version(&latest_version, &current_version);

        Ok(DesktopUpdateCheck {
            available,
            current_version,
            latest_version,
            release_url: release.html_url.clone(),
            installer_name: installer.map(|asset| asset.name.clone()),
            installer_url: installer.map(|asset| asset.browser_download_url.clone()),
            expected_sha256: installer
                .and_then(|asset| strip_sha256_digest(asset.digest.as_deref())),
            reason: if installer.is_some() {
                None
            } else {
                Some("Latest release does not contain a Windows setup installer asset.".to_string())
            },
        })
    }
}

fn emit_desktop_update_progress(app: &AppHandle, stage: &str, downloaded: u64, total: Option<u64>) {
    let percent = total
        .filter(|total| *total > 0)
        .map(|total| (downloaded as f64 / total as f64 * 100.0).min(100.0));
    let _ = app.emit(
        DESKTOP_UPDATE_PROGRESS_EVENT,
        DesktopUpdateProgress {
            stage: stage.to_string(),
            downloaded,
            total,
            percent,
        },
    );
}

fn sanitize_installer_name(name: &str) -> Result<String, String> {
    let file_name = Path::new(name)
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "installer name must be a file name".to_string())?;
    if !file_name.ends_with(".exe") || !file_name.starts_with("winsmux_") {
        return Err("installer name must be a winsmux setup executable".to_string());
    }
    Ok(file_name.to_string())
}

fn hex_digest(bytes: impl AsRef<[u8]>) -> String {
    bytes
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

fn hash_file_sha256(path: &Path) -> Result<String, String> {
    let mut file = std::fs::File::open(path)
        .map_err(|err| format!("failed to open update installer for verification: {err}"))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|err| format!("failed to read update installer for verification: {err}"))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex_digest(hasher.finalize()))
}

#[tauri::command]
fn desktop_update_download_installer(
    app: AppHandle,
    installer_url: String,
    installer_name: String,
    expected_sha256: Option<String>,
) -> Result<DesktopUpdateDownloadResult, String> {
    #[cfg(not(windows))]
    {
        let _ = (app, installer_url, installer_name, expected_sha256);
        Err("Desktop installer updates are supported only on Windows.".to_string())
    }

    #[cfg(windows)]
    {
        let installer_name = sanitize_installer_name(&installer_name)?;
        let updates_dir = std::env::temp_dir().join("winsmux-updates");
        std::fs::create_dir_all(&updates_dir)
            .map_err(|err| format!("failed to create update download directory: {err}"))?;
        let installer_path = updates_dir.join(&installer_name);
        let response = ureq::get(&installer_url)
            .set("User-Agent", "winsmux-desktop-updater")
            .call()
            .map_err(|err| format!("failed to download update installer: {err}"))?;
        let total = response
            .header("Content-Length")
            .and_then(|value| value.parse::<u64>().ok());
        let mut reader = response.into_reader();
        let mut file = std::fs::File::create(&installer_path)
            .map_err(|err| format!("failed to create update installer file: {err}"))?;
        let mut hasher = Sha256::new();
        let mut downloaded = 0_u64;
        let mut buffer = [0_u8; 64 * 1024];

        emit_desktop_update_progress(&app, "downloading", downloaded, total);
        loop {
            let read = reader
                .read(&mut buffer)
                .map_err(|err| format!("failed to read update installer response: {err}"))?;
            if read == 0 {
                break;
            }
            file.write_all(&buffer[..read])
                .map_err(|err| format!("failed to write update installer file: {err}"))?;
            hasher.update(&buffer[..read]);
            downloaded += read as u64;
            emit_desktop_update_progress(&app, "downloading", downloaded, total);
        }

        let actual_sha256 = hex_digest(hasher.finalize());
        if let Some(expected) = expected_sha256 {
            let expected = expected.to_ascii_lowercase();
            if expected != actual_sha256 {
                let _ = std::fs::remove_file(&installer_path);
                return Err(format!(
                    "downloaded installer checksum mismatch: expected {expected}, got {actual_sha256}"
                ));
            }
        }
        emit_desktop_update_progress(&app, "downloaded", downloaded, total);

        Ok(DesktopUpdateDownloadResult {
            installer_path: installer_path.to_string_lossy().to_string(),
            installer_name,
            sha256: actual_sha256,
        })
    }
}

#[tauri::command]
fn desktop_update_launch_installer(
    app: AppHandle,
    installer_path: String,
    expected_sha256: String,
) -> Result<(), String> {
    let path = PathBuf::from(installer_path.trim());
    if !path.is_file() {
        return Err("update installer file does not exist".to_string());
    }
    if path.extension().and_then(|value| value.to_str()) != Some("exe") {
        return Err("update installer must be a Windows executable".to_string());
    }

    #[cfg(not(windows))]
    {
        let _ = (app, path, expected_sha256);
        return Err("Desktop installer updates are supported only on Windows.".to_string());
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        let updates_dir = std::env::temp_dir()
            .join("winsmux-updates")
            .canonicalize()
            .map_err(|err| format!("failed to verify update download directory: {err}"))?;
        let canonical_path = path
            .canonicalize()
            .map_err(|err| format!("failed to verify update installer path: {err}"))?;
        if !canonical_path.starts_with(&updates_dir) {
            return Err(
                "update installer must be launched from the winsmux update download directory"
                    .to_string(),
            );
        }
        let file_name = canonical_path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| "update installer file name is invalid".to_string())?;
        let _ = sanitize_installer_name(file_name)?;
        let expected = strip_sha256_digest(Some(&expected_sha256))
            .ok_or_else(|| "update installer checksum is required before launch".to_string())?;
        let actual = hash_file_sha256(&canonical_path)?;
        if actual != expected {
            return Err(format!(
                "update installer checksum changed before launch: expected {expected}, got {actual}"
            ));
        }
        let app_path = std::env::current_exe()
            .map_err(|err| format!("failed to resolve current winsmux executable: {err}"))?;
        let restart_script_path = std::env::temp_dir()
            .join("winsmux-updates")
            .join("winsmux-update-restart.ps1");
        let restart_script = r#"
param(
  [Parameter(Mandatory=$true)][string]$InstallerPath,
  [Parameter(Mandatory=$true)][string]$AppPath
)
$ErrorActionPreference = 'Stop'
$installer = Start-Process -FilePath $InstallerPath -PassThru
Wait-Process -Id $installer.Id
Start-Sleep -Milliseconds 500
Start-Process -FilePath $AppPath | Out-Null
"#;
        std::fs::write(&restart_script_path, restart_script)
            .map_err(|err| format!("failed to write update restart helper: {err}"))?;
        Command::new("powershell.exe")
            .args([
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
            ])
            .arg(&restart_script_path)
            .arg("-InstallerPath")
            .creation_flags(CREATE_NO_WINDOW)
            .arg(&canonical_path)
            .arg("-AppPath")
            .arg(&app_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| format!("failed to launch update restart helper: {err}"))?;
        app.exit(0);
    }

    Ok(())
}

struct SinglePty {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send>>>,
    output_history: Arc<Mutex<String>>,
    alive: Arc<AtomicBool>,
    generation: u64,
    cols: u16,
    rows: u16,
}

struct PtyManager {
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
    next_generation: AtomicU64,
}

struct DesktopSummaryStreamManager {
    started: AtomicBool,
    stop_requested: Arc<AtomicBool>,
}

struct DesktopShutdownManager {
    requested: AtomicBool,
}

#[derive(Debug, PartialEq, Eq)]
struct DesktopShutdownReport {
    voice_stop_requested: bool,
    voice_cleanup_completed: Option<bool>,
    pty_count: usize,
    pty_exited_count: usize,
}

struct VoiceCaptureSession {
    generation: u64,
    stop_requested: Arc<AtomicBool>,
    cleanup_complete: Arc<AtomicBool>,
}

#[derive(Clone, Debug)]
struct VoiceCaptureRuntimeSnapshot {
    generation: u64,
    state: String,
    permission: String,
    reason: String,
    meter_level: f64,
    running: bool,
    native_available: bool,
}

impl Default for VoiceCaptureRuntimeSnapshot {
    fn default() -> Self {
        Self {
            generation: 0,
            state: "stopped".to_string(),
            permission: "unknown".to_string(),
            reason: "Native microphone capture is ready.".to_string(),
            meter_level: 0.0,
            running: false,
            native_available: false,
        }
    }
}

struct VoiceCaptureManager {
    snapshot: Arc<Mutex<VoiceCaptureRuntimeSnapshot>>,
    session: Mutex<Option<VoiceCaptureSession>>,
    next_generation: AtomicU64,
}

struct TauriPtyTransport {
    app: AppHandle,
}

fn emit_desktop_summary_refresh(app: &AppHandle, signal: DesktopSummaryRefreshSignal) {
    let _ = app.emit(DESKTOP_SUMMARY_REFRESH_EVENT, signal);
}

fn start_desktop_summary_refresh_streams(app: &AppHandle) {
    let manager = app.state::<DesktopSummaryStreamManager>();
    if manager.started.swap(true, Ordering::SeqCst) {
        return;
    }

    let summary_app = app.clone();
    if let Err(err) = spawn_desktop_summary_refresh_stream(
        DesktopStreamCommand::Summary { project_dir: None },
        manager.stop_requested.clone(),
        move |signal| {
            emit_desktop_summary_refresh(&summary_app, signal);
        },
    ) {
        eprintln!("Failed to start desktop summary stream adapter: {}", err);
    }
}

fn schedule_desktop_summary_refresh_streams(app: AppHandle) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(250));
        start_desktop_summary_refresh_streams(&app);
    });
}

fn update_voice_capture_snapshot(
    snapshot: &Arc<Mutex<VoiceCaptureRuntimeSnapshot>>,
    generation: u64,
    update: impl FnOnce(&mut VoiceCaptureRuntimeSnapshot),
) {
    if let Ok(mut current) = snapshot.lock() {
        if current.generation == generation {
            update(&mut current);
        }
    }
}

fn wait_voice_capture_cleanup(session: &VoiceCaptureSession, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while !session.cleanup_complete.load(Ordering::SeqCst) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    true
}

fn request_voice_capture_shutdown(
    manager: &VoiceCaptureManager,
    timeout: Duration,
) -> Option<bool> {
    let existing = {
        let Ok(mut session) = manager.session.lock() else {
            return None;
        };
        session.take()
    }?;
    let generation = existing.generation;
    existing.stop_requested.store(true, Ordering::SeqCst);
    let completed = wait_voice_capture_cleanup(&existing, timeout);
    if completed {
        update_voice_capture_snapshot(&manager.snapshot, generation, |snapshot| {
            snapshot.state = "stopped".to_string();
            snapshot.reason =
                "Native microphone capture stopped during desktop shutdown.".to_string();
            snapshot.running = false;
            snapshot.meter_level = 0.0;
        });
    } else if let Ok(mut session) = manager.session.lock() {
        *session = Some(existing);
    }
    Some(completed)
}

fn desktop_voice_capture_status_from_snapshot(
    snapshot: VoiceCaptureRuntimeSnapshot,
) -> DesktopVoiceCaptureStatus {
    let status = load_desktop_summary_voice_capture_status();
    desktop_voice_capture_status_from_base(status, snapshot)
}

fn desktop_voice_capture_status_from_base(
    mut status: DesktopVoiceCaptureStatus,
    snapshot: VoiceCaptureRuntimeSnapshot,
) -> DesktopVoiceCaptureStatus {
    if status.native.device_count > 0 && snapshot.generation == 0 {
        apply_native_voice_dictation_fallback_contract(&mut status);
        status.native.available = true;
        status.native.state = "stopped".to_string();
        status.native.permission = "unknown".to_string();
        status.native.meter_supported = true;
        status.native.meter_level = 0.0;
        status.native.restart_supported = true;
        status.native.reason = NATIVE_VOICE_METER_ONLY_REASON.to_string();
        return status;
    }

    if snapshot.generation == 0 || status.native.device_count == 0 {
        return status;
    }

    status.capture_mode = if snapshot.native_available {
        "browser_fallback".to_string()
    } else {
        "unavailable".to_string()
    };
    status.native.available = snapshot.native_available;
    status.native.state = snapshot.state;
    status.native.permission = snapshot.permission;
    status.native.meter_supported = true;
    status.native.meter_level = snapshot.meter_level.clamp(0.0, 1.0);
    status.native.restart_supported = true;
    status.native.reason = snapshot.reason;
    status.browser_fallback.expected = true;
    status.browser_fallback.reason = if snapshot.native_available {
        NATIVE_VOICE_DICTATION_FALLBACK_REASON.to_string()
    } else {
        "Use browser speech recognition until the native capture backend is available.".to_string()
    };
    status
}

fn apply_native_voice_dictation_fallback_contract(status: &mut DesktopVoiceCaptureStatus) {
    status.capture_mode = "browser_fallback".to_string();
    status.browser_fallback.expected = true;
    status.browser_fallback.reason = NATIVE_VOICE_DICTATION_FALLBACK_REASON.to_string();
}

fn load_desktop_summary_voice_capture_status() -> DesktopVoiceCaptureStatus {
    desktop_backend::load_desktop_voice_capture_status()
}

fn get_voice_capture_status(app: &AppHandle) -> DesktopVoiceCaptureStatus {
    let manager = app.state::<VoiceCaptureManager>();
    let snapshot = manager
        .snapshot
        .lock()
        .map(|value| value.clone())
        .unwrap_or_default();
    desktop_voice_capture_status_from_snapshot(snapshot)
}

#[tauri::command]
async fn desktop_voice_capture_status(app: AppHandle) -> Result<DesktopVoiceCaptureStatus, String> {
    Ok(get_voice_capture_status(&app))
}

#[tauri::command]
async fn desktop_voice_capture_start(app: AppHandle) -> Result<DesktopVoiceCaptureStatus, String> {
    let manager = app.state::<VoiceCaptureManager>();
    let generation = manager.next_generation.fetch_add(1, Ordering::SeqCst);
    let stop_requested = Arc::new(AtomicBool::new(false));
    let cleanup_complete = Arc::new(AtomicBool::new(false));
    {
        let mut session = manager.session.lock().map_err(|e| e.to_string())?;
        if let Some(existing) = session.take() {
            existing.stop_requested.store(true, Ordering::SeqCst);
            if !wait_voice_capture_cleanup(&existing, Duration::from_secs(3)) {
                *session = Some(existing);
                return Err(
                    "Previous native microphone capture is still releasing the device.".to_string(),
                );
            }
        }
        *session = Some(VoiceCaptureSession {
            generation,
            stop_requested: stop_requested.clone(),
            cleanup_complete: cleanup_complete.clone(),
        });
    }
    {
        let mut snapshot = manager.snapshot.lock().map_err(|e| e.to_string())?;
        *snapshot = VoiceCaptureRuntimeSnapshot {
            generation,
            state: "restarting".to_string(),
            permission: "unknown".to_string(),
            reason: "Starting native microphone capture.".to_string(),
            meter_level: 0.0,
            running: true,
            native_available: true,
        };
    }

    let snapshot = manager.snapshot.clone();
    std::thread::spawn(move || {
        run_voice_capture_worker(snapshot, generation, stop_requested, cleanup_complete);
    });

    Ok(get_voice_capture_status(&app))
}

#[tauri::command]
async fn desktop_voice_capture_stop(
    app: AppHandle,
    cancelled: Option<bool>,
) -> Result<DesktopVoiceCaptureStatus, String> {
    let manager = app.state::<VoiceCaptureManager>();
    let generation = {
        let mut session = manager.session.lock().map_err(|e| e.to_string())?;
        match session.take() {
            Some(existing) => {
                existing.stop_requested.store(true, Ordering::SeqCst);
                if !wait_voice_capture_cleanup(&existing, Duration::from_secs(3)) {
                    *session = Some(existing);
                    return Err(
                        "Native microphone capture is still releasing the device.".to_string()
                    );
                }
                existing.generation
            }
            None => 0,
        }
    };

    let state = if cancelled.unwrap_or(false) {
        "cancelled"
    } else {
        "stopped"
    };
    if generation > 0 {
        update_voice_capture_snapshot(&manager.snapshot, generation, |snapshot| {
            snapshot.state = state.to_string();
            snapshot.reason = if state == "cancelled" {
                "Native microphone capture was cancelled by the user.".to_string()
            } else {
                "Native microphone capture stopped.".to_string()
            };
            snapshot.running = false;
            snapshot.meter_level = 0.0;
        });
    }

    Ok(get_voice_capture_status(&app))
}

fn run_voice_capture_worker(
    snapshot: Arc<Mutex<VoiceCaptureRuntimeSnapshot>>,
    generation: u64,
    stop_requested: Arc<AtomicBool>,
    cleanup_complete: Arc<AtomicBool>,
) {
    #[cfg(windows)]
    run_windows_voice_capture_worker(
        snapshot,
        generation,
        stop_requested,
        cleanup_complete.clone(),
    );

    #[cfg(not(windows))]
    {
        update_voice_capture_snapshot(&snapshot, generation, |current| {
            current.state = "unavailable".to_string();
            current.permission = "unknown".to_string();
            current.reason =
                "Native microphone capture is only implemented on Windows.".to_string();
            current.running = false;
            current.native_available = false;
            current.meter_level = 0.0;
        });
        cleanup_complete.store(true, Ordering::SeqCst);
    }
}

#[cfg(windows)]
fn run_windows_voice_capture_worker(
    snapshot: Arc<Mutex<VoiceCaptureRuntimeSnapshot>>,
    generation: u64,
    stop_requested: Arc<AtomicBool>,
    cleanup_complete: Arc<AtomicBool>,
) {
    const SAMPLE_RATE: u32 = 16_000;
    const CHANNELS: u16 = 1;
    const BITS_PER_SAMPLE: u16 = 16;
    const BUFFER_BYTES: usize = (SAMPLE_RATE as usize * 2) / 10;
    const BUFFER_COUNT: usize = 4;

    let format = WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM as u16,
        nChannels: CHANNELS,
        nSamplesPerSec: SAMPLE_RATE,
        nAvgBytesPerSec: SAMPLE_RATE * CHANNELS as u32 * (BITS_PER_SAMPLE as u32 / 8),
        nBlockAlign: CHANNELS * (BITS_PER_SAMPLE / 8),
        wBitsPerSample: BITS_PER_SAMPLE,
        cbSize: 0,
    };
    let mut handle = std::ptr::null_mut();
    let open_result = unsafe { waveInOpen(&mut handle, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) };
    if open_result != MMSYSERR_NOERROR {
        let (state, permission, native_available, reason) = map_wave_open_error(open_result);
        update_voice_capture_snapshot(&snapshot, generation, |current| {
            current.state = state;
            current.permission = permission;
            current.reason = reason;
            current.running = false;
            current.native_available = native_available;
            current.meter_level = 0.0;
        });
        cleanup_complete.store(true, Ordering::SeqCst);
        return;
    }

    update_voice_capture_snapshot(&snapshot, generation, |current| {
        current.state = "recording".to_string();
        current.permission = "granted".to_string();
        current.reason = "Native microphone capture is recording.".to_string();
        current.running = true;
        current.native_available = true;
        current.meter_level = 0.0;
    });

    let mut buffers = (0..BUFFER_COUNT)
        .map(|_| vec![0u8; BUFFER_BYTES])
        .collect::<Vec<_>>();
    let mut headers = buffers
        .iter_mut()
        .map(|buffer| WAVEHDR {
            lpData: buffer.as_mut_ptr(),
            dwBufferLength: buffer.len() as u32,
            dwBytesRecorded: 0,
            dwUser: 0,
            dwFlags: 0,
            dwLoops: 0,
            lpNext: std::ptr::null_mut(),
            reserved: 0,
        })
        .collect::<Vec<_>>();

    let header_size = std::mem::size_of::<WAVEHDR>() as u32;
    let mut queued_buffer_count = 0usize;
    for header in headers.iter_mut() {
        let prepare_result = unsafe { waveInPrepareHeader(handle, header, header_size) };
        if prepare_result == MMSYSERR_NOERROR {
            let add_result = unsafe { waveInAddBuffer(handle, header, header_size) };
            if add_result == MMSYSERR_NOERROR {
                queued_buffer_count += 1;
            }
        }
    }
    if queued_buffer_count == 0 {
        update_voice_capture_snapshot(&snapshot, generation, |current| {
            current.state = "permission_denied".to_string();
            current.permission = "denied".to_string();
            current.reason = "Windows could not queue a microphone capture buffer.".to_string();
            current.running = false;
            current.native_available = false;
            current.meter_level = 0.0;
        });
        for header in headers.iter_mut() {
            let _ = unsafe { waveInUnprepareHeader(handle, header, header_size) };
        }
        let _ = unsafe { waveInClose(handle) };
        cleanup_complete.store(true, Ordering::SeqCst);
        return;
    }

    let start_result = unsafe { waveInStart(handle) };
    if start_result != MMSYSERR_NOERROR {
        update_voice_capture_snapshot(&snapshot, generation, |current| {
            current.state = "permission_denied".to_string();
            current.permission = "denied".to_string();
            current.reason = format!(
                "Windows could not start microphone capture: MMSYSERR code {start_result}."
            );
            current.running = false;
            current.native_available = false;
            current.meter_level = 0.0;
        });
    } else {
        let mut last_voice_at = Instant::now();
        while !stop_requested.load(Ordering::SeqCst) {
            for (index, header) in headers.iter_mut().enumerate() {
                let flags = header.dwFlags;
                let recorded = header.dwBytesRecorded as usize;
                if flags & WHDR_DONE == 0 || recorded == 0 {
                    continue;
                }

                let bytes = &buffers[index][..recorded.min(BUFFER_BYTES)];
                let meter = calculate_pcm16_meter_level(bytes);
                if meter > 0.03 {
                    last_voice_at = Instant::now();
                }
                let silent = last_voice_at.elapsed() >= Duration::from_secs(2);
                update_voice_capture_snapshot(&snapshot, generation, |current| {
                    current.state = if silent {
                        "silence".to_string()
                    } else {
                        "recording".to_string()
                    };
                    current.permission = "granted".to_string();
                    current.reason = if silent {
                        "Native microphone capture is running, but no speech-level input has been detected.".to_string()
                    } else {
                        "Native microphone capture is recording.".to_string()
                    };
                    current.running = true;
                    current.native_available = true;
                    current.meter_level = meter;
                });

                header.dwBytesRecorded = 0;
                header.dwFlags &= !WHDR_DONE;
                let _ = unsafe { waveInAddBuffer(handle, header, header_size) };
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    let _ = unsafe { waveInStop(handle) };
    let _ = unsafe { waveInReset(handle) };
    for header in headers.iter_mut() {
        let _ = unsafe { waveInUnprepareHeader(handle, header, header_size) };
    }
    let _ = unsafe { waveInClose(handle) };
    cleanup_complete.store(true, Ordering::SeqCst);
    update_voice_capture_snapshot(&snapshot, generation, |current| {
        if current.running {
            current.state = "stopped".to_string();
            current.reason = "Native microphone capture stopped.".to_string();
        }
        current.running = false;
        current.meter_level = 0.0;
    });
}

#[cfg(windows)]
fn map_wave_open_error(result: u32) -> (String, String, bool, String) {
    match result {
        MMSYSERR_BADDEVICEID | MMSYSERR_NODRIVER => (
            "no_microphone".to_string(),
            "unknown".to_string(),
            false,
            "Windows did not expose a usable microphone input device.".to_string(),
        ),
        MMSYSERR_ALLOCATED => (
            "permission_denied".to_string(),
            "denied".to_string(),
            false,
            "Windows reported that the microphone input device is unavailable to this app."
                .to_string(),
        ),
        _ => (
            "permission_denied".to_string(),
            "denied".to_string(),
            false,
            format!("Windows could not open microphone capture: MMSYSERR code {result}."),
        ),
    }
}

fn calculate_pcm16_meter_level(bytes: &[u8]) -> f64 {
    let mut sum = 0f64;
    let mut count = 0f64;
    for chunk in bytes.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]) as f64 / i16::MAX as f64;
        sum += sample * sample;
        count += 1.0;
    }
    if count == 0.0 {
        return 0.0;
    }
    (sum / count).sqrt().clamp(0.0, 1.0)
}

#[tauri::command]
async fn desktop_summary_snapshot(
    project_dir: Option<String>,
) -> Result<DesktopSummarySnapshot, String> {
    let transport = PwshScriptTransport;
    load_desktop_summary_snapshot(&transport, project_dir)
}

#[tauri::command]
async fn desktop_run_explain(
    run_id: String,
    project_dir: Option<String>,
) -> Result<DesktopExplainPayload, String> {
    let transport = PwshScriptTransport;
    load_desktop_run_explain(&transport, run_id, project_dir)
}

#[tauri::command]
async fn desktop_json_rpc(
    request: DesktopJsonRpcRequest,
    project_dir: Option<String>,
) -> Result<DesktopJsonRpcResponse, String> {
    let transport = PwshScriptTransport;
    Ok(handle_desktop_json_rpc(&transport, request, project_dir))
}

#[tauri::command]
async fn pty_json_rpc(
    app: AppHandle,
    request: PtyJsonRpcRequest,
) -> Result<PtyJsonRpcResponse, String> {
    let transport = TauriPtyTransport { app };
    Ok(handle_pty_json_rpc(&transport, request))
}

#[tauri::command]
async fn pty_spawn(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    spawn_pty(&app, pane_id, cols, rows, None, "pty.spawn")
}

#[tauri::command]
async fn pty_write(app: AppHandle, pane_id: String, data: String) -> Result<(), String> {
    write_pty(&app, &pane_id, &data)
}

#[tauri::command]
async fn pty_resize(app: AppHandle, pane_id: String, cols: u16, rows: u16) -> Result<(), String> {
    resize_pty(&app, &pane_id, cols, rows)
}

#[tauri::command]
async fn pty_capture(
    app: AppHandle,
    pane_id: String,
    lines: Option<u16>,
) -> Result<serde_json::Value, String> {
    capture_pty(&app, &pane_id, lines)
}

#[tauri::command]
async fn pty_respawn(app: AppHandle, pane_id: String) -> Result<(), String> {
    respawn_pty(&app, &pane_id)
}

#[tauri::command]
async fn pty_close(app: AppHandle, pane_id: String) -> Result<(), String> {
    close_pty(&app, &pane_id)
}

fn spawn_pty(
    app: &AppHandle,
    pane_id: String,
    cols: u16,
    rows: u16,
    startup_input: Option<String>,
    reason: &str,
) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    {
        let panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if panes.contains_key(&pane_id) {
            return Err(format!("Pane {} already exists", pane_id));
        }
    }

    let generation = manager.next_generation.fetch_add(1, Ordering::SeqCst);
    let (single, reader, output_history, alive) = create_single_pty(cols, rows, generation)?;

    {
        let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if panes.contains_key(&pane_id) {
            stop_single_pty(&single);
            return Err(format!("Pane {} already exists", pane_id));
        }
        panes.insert(pane_id.clone(), single);
    }

    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: reason.to_string(),
            pane_id: Some(pane_id.clone()),
            run_id: None,
        },
    );

    start_pty_reader(
        app,
        pane_id.clone(),
        reader,
        output_history,
        alive,
        generation,
        manager.panes.clone(),
    );
    if let Some(input) = startup_input {
        write_pty(app, &pane_id, &input)?;
    }
    Ok(())
}

type PtyReader = Box<dyn Read + Send>;
type SinglePtyParts = (SinglePty, PtyReader, Arc<Mutex<String>>, Arc<AtomicBool>);

fn build_pty_command(workspace_dir: &Path) -> CommandBuilder {
    let mut cmd = CommandBuilder::new("pwsh");
    cmd.arg("-NoLogo");
    cmd.cwd(workspace_dir.as_os_str());
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env_remove(WINSMUX_CONTROL_PIPE_TOKEN_ENV);
    cmd
}

fn create_single_pty(cols: u16, rows: u16, generation: u64) -> Result<SinglePtyParts, String> {
    let pty_system = native_pty_system();

    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("Failed to open PTY: {e}"))?;

    let workspace_dir = resolve_repo_root()?;
    let cmd = build_pty_command(&workspace_dir);

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("Failed to spawn: {e}"))?;

    let writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("Failed to get writer: {e}"))?;

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("Failed to get reader: {e}"))?;
    let output_history = Arc::new(Mutex::new(String::new()));
    let alive = Arc::new(AtomicBool::new(true));

    let single = SinglePty {
        writer: Arc::new(Mutex::new(writer)),
        master: Arc::new(Mutex::new(pair.master)),
        child: Arc::new(Mutex::new(child)),
        output_history: output_history.clone(),
        alive: alive.clone(),
        generation,
        cols,
        rows,
    };

    Ok((single, reader, output_history, alive))
}

fn start_pty_reader(
    app: &AppHandle,
    pane_id: String,
    mut reader: PtyReader,
    output_history: Arc<Mutex<String>>,
    alive: Arc<AtomicBool>,
    generation: u64,
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
) {
    let app_handle = app.clone();
    let (output_tx, output_rx) = mpsc::sync_channel::<String>(PTY_OUTPUT_QUEUE_CAPACITY);
    start_pty_output_flusher(
        app_handle,
        pane_id.clone(),
        alive.clone(),
        generation,
        panes.clone(),
        output_rx,
    );
    std::thread::spawn(move || {
        let mut buf = [0u8; PTY_READ_BUFFER_BYTES];
        let mut pending_utf8 = Vec::new();
        loop {
            if !is_current_pty(&panes, &pane_id, generation, &alive) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = decode_pty_reader_bytes(&buf[..n], &mut pending_utf8);
                    if data.is_empty() {
                        continue;
                    }
                    if let Ok(mut history) = output_history.lock() {
                        append_pty_history(&mut history, &data);
                    }
                    if output_tx.send(data).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }

        if is_current_pty(&panes, &pane_id, generation, &alive) {
            let _ = publish_pending_pty_utf8(&mut pending_utf8, &output_history, &output_tx);
        }
    });
}

struct PtyOutputBatch {
    data: String,
    first_output_at: Instant,
}

impl PtyOutputBatch {
    fn new(now: Instant) -> Self {
        Self {
            data: String::new(),
            first_output_at: now,
        }
    }

    fn push(&mut self, data: &str, now: Instant) {
        if self.data.is_empty() {
            self.first_output_at = now;
        }
        self.data.push_str(data);
    }

    fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    fn should_flush(&self, now: Instant) -> bool {
        !self.data.is_empty()
            && (self.data.len() >= PTY_OUTPUT_BATCH_LIMIT
                || now.duration_since(self.first_output_at)
                    >= Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS))
    }

    fn recv_timeout(&self, now: Instant) -> Duration {
        if self.data.is_empty() {
            return Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS);
        }

        let flush_interval = Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS);
        (self.first_output_at + flush_interval)
            .checked_duration_since(now)
            .unwrap_or(Duration::from_millis(0))
    }

    fn take(&mut self, now: Instant) -> String {
        self.first_output_at = now;
        std::mem::take(&mut self.data)
    }
}

fn start_pty_output_flusher(
    app_handle: AppHandle,
    pane_id: String,
    alive: Arc<AtomicBool>,
    generation: u64,
    panes: Arc<Mutex<HashMap<String, SinglePty>>>,
    output_rx: Receiver<String>,
) {
    std::thread::spawn(move || {
        let mut batch = PtyOutputBatch::new(Instant::now());

        loop {
            if !is_current_pty(&panes, &pane_id, generation, &alive) {
                break;
            }

            match output_rx.recv_timeout(batch.recv_timeout(Instant::now())) {
                Ok(data) => {
                    let now = Instant::now();
                    batch.push(&data, now);
                    if batch.should_flush(now) {
                        if !is_current_pty(&panes, &pane_id, generation, &alive) {
                            break;
                        }
                        emit_pty_output_batch(&app_handle, &pane_id, &mut batch, now);
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    let now = Instant::now();
                    if batch.should_flush(now) {
                        if !is_current_pty(&panes, &pane_id, generation, &alive) {
                            break;
                        }
                        emit_pty_output_batch(&app_handle, &pane_id, &mut batch, now);
                    }
                }
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }

        if is_current_pty(&panes, &pane_id, generation, &alive) && !batch.is_empty() {
            emit_pty_output_batch(&app_handle, &pane_id, &mut batch, Instant::now());
        }
    });
}

fn emit_pty_output_batch(
    app_handle: &AppHandle,
    pane_id: &str,
    batch: &mut PtyOutputBatch,
    now: Instant,
) {
    let data = batch.take(now);
    if data.is_empty() {
        return;
    }

    let _ = app_handle.emit(
        "pty-output",
        serde_json::json!({"pane_id": pane_id, "data": data}),
    );
}

fn is_current_pty(
    panes: &Arc<Mutex<HashMap<String, SinglePty>>>,
    pane_id: &str,
    generation: u64,
    alive: &Arc<AtomicBool>,
) -> bool {
    if !alive.load(Ordering::SeqCst) {
        return false;
    }

    let Ok(current_panes) = panes.lock() else {
        return false;
    };
    current_panes
        .get(pane_id)
        .map(|pty| pty.generation == generation && Arc::ptr_eq(&pty.alive, alive))
        .unwrap_or(false)
}

fn decode_pty_reader_bytes(bytes: &[u8], pending_utf8: &mut Vec<u8>) -> String {
    let mut combined = Vec::with_capacity(pending_utf8.len() + bytes.len());
    combined.append(pending_utf8);
    combined.extend_from_slice(bytes);

    let mut output = String::new();
    let mut remaining = combined.as_slice();
    loop {
        match std::str::from_utf8(remaining) {
            Ok(valid) => {
                output.push_str(valid);
                break;
            }
            Err(error) => {
                let valid_up_to = error.valid_up_to();
                if valid_up_to > 0 {
                    if let Ok(valid) = std::str::from_utf8(&remaining[..valid_up_to]) {
                        output.push_str(valid);
                    }
                }

                let rest = &remaining[valid_up_to..];
                let Some(error_len) = error.error_len() else {
                    pending_utf8.extend_from_slice(rest);
                    break;
                };
                output.push('\u{fffd}');
                remaining = &rest[error_len..];
            }
        }
    }

    output
}

fn publish_pending_pty_utf8(
    pending_utf8: &mut Vec<u8>,
    output_history: &Arc<Mutex<String>>,
    output_tx: &SyncSender<String>,
) -> bool {
    if pending_utf8.is_empty() {
        return true;
    }

    let data = String::from_utf8_lossy(pending_utf8).to_string();
    pending_utf8.clear();
    if let Ok(mut history) = output_history.lock() {
        append_pty_history(&mut history, &data);
    }

    output_tx.send(data).is_ok()
}

fn append_pty_history(history: &mut String, data: &str) {
    history.push_str(data);
    trim_pty_history(history);
}

fn trim_pty_history(history: &mut String) {
    if history.len() <= PTY_CAPTURE_LIMIT {
        return;
    }

    let mut drain_to = history.len() - PTY_CAPTURE_LIMIT;
    while drain_to < history.len() && !history.is_char_boundary(drain_to) {
        drain_to += 1;
    }
    history.drain(..drain_to);
}

fn write_pty(app: &AppHandle, pane_id: &str, data: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let mut writer = pty.writer.lock().map_err(|e| e.to_string())?;
    writer
        .write_all(data.as_bytes())
        .map_err(|e| format!("Write failed: {e}"))?;
    writer.flush().map_err(|e| format!("Flush failed: {e}"))?;
    Ok(())
}

fn resize_pty(app: &AppHandle, pane_id: &str, cols: u16, rows: u16) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get_mut(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    {
        let master = pty.master.lock().map_err(|e| e.to_string())?;
        master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Resize failed: {e}"))?;
    }
    pty.cols = cols;
    pty.rows = rows;
    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.resize".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );
    Ok(())
}

fn limit_pty_capture_output(output: &str, lines: Option<u16>) -> String {
    let Some(lines) = lines else {
        return output.to_string();
    };
    if lines == 0 {
        return String::new();
    }

    let mut tail = output
        .lines()
        .rev()
        .take(lines as usize)
        .collect::<Vec<_>>();
    tail.reverse();
    tail.join("\n")
}

fn capture_pty(
    app: &AppHandle,
    pane_id: &str,
    lines: Option<u16>,
) -> Result<serde_json::Value, String> {
    let manager = app.state::<PtyManager>();
    let panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let pty = panes
        .get(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    let output = pty
        .output_history
        .lock()
        .map_err(|e| e.to_string())?
        .clone();
    let output = limit_pty_capture_output(&output, lines);
    Ok(serde_json::json!({
        "paneId": pane_id,
        "output": output
    }))
}

fn submit_operator_text_with(
    mut write: impl FnMut(&str) -> Result<(), String>,
    text: &str,
    submit_after_paste: bool,
) -> Result<(), String> {
    write(text)?;
    if submit_after_paste {
        write("\r")?;
    }
    Ok(())
}

fn submit_operator_text(
    app: &AppHandle,
    text: &str,
    submit_after_paste: bool,
) -> Result<(), String> {
    submit_operator_text_with(
        |data| write_pty(app, pty_backend::OPERATOR_PANE_ID, data),
        text,
        submit_after_paste,
    )
}

fn respawn_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let (cols, rows) = {
        let panes = manager.panes.lock().map_err(|e| e.to_string())?;
        let entry = panes
            .get(pane_id)
            .ok_or_else(|| format!("Pane {} not found", pane_id))?;
        (entry.cols, entry.rows)
    };
    let generation = manager.next_generation.fetch_add(1, Ordering::SeqCst);
    let (single, reader, output_history, alive) = create_single_pty(cols, rows, generation)?;

    let old_entry = {
        let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
        if !panes.contains_key(pane_id) {
            stop_single_pty(&single);
            return Err(format!("Pane {} not found", pane_id));
        }
        panes
            .insert(pane_id.to_string(), single)
            .expect("pane existence was checked before replacement")
    };

    stop_single_pty(&old_entry);
    drop(old_entry);

    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.respawn".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );

    start_pty_reader(
        app,
        pane_id.to_string(),
        reader,
        output_history,
        alive,
        generation,
        manager.panes.clone(),
    );
    Ok(())
}

fn wait_pty_child_exit(child: &mut dyn portable_pty::Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => {
                if Instant::now() >= deadline {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => return true,
        }
    }
}

fn stop_single_pty(entry: &SinglePty) -> bool {
    stop_single_pty_with_wait(entry, Duration::from_millis(0))
}

fn stop_single_pty_with_wait(entry: &SinglePty, timeout: Duration) -> bool {
    entry.alive.store(false, Ordering::SeqCst);
    if let Ok(mut child) = entry.child.lock() {
        let _ = child.kill();
        return wait_pty_child_exit(child.as_mut(), timeout);
    }
    false
}

fn drain_all_ptys(manager: &PtyManager, timeout: Duration) -> (usize, usize) {
    let entries = {
        let Ok(mut panes) = manager.panes.lock() else {
            return (0, 0);
        };
        std::mem::take(&mut *panes)
    };
    let total = entries.len();
    let mut exited = 0usize;
    for (_pane_id, entry) in entries {
        if stop_single_pty_with_wait(&entry, timeout) {
            exited += 1;
        }
        drop(entry.master);
        drop(entry.writer);
    }
    (total, exited)
}

fn request_desktop_runtime_shutdown(
    shutdown: &DesktopShutdownManager,
    summary: &DesktopSummaryStreamManager,
    voice: &VoiceCaptureManager,
    pty: &PtyManager,
    voice_timeout: Duration,
    pty_timeout: Duration,
) -> Option<DesktopShutdownReport> {
    if shutdown.requested.swap(true, Ordering::SeqCst) {
        return None;
    }

    summary.stop_requested.store(true, Ordering::SeqCst);
    let voice_cleanup_completed = request_voice_capture_shutdown(voice, voice_timeout);
    let (pty_count, pty_exited_count) = drain_all_ptys(pty, pty_timeout);
    Some(DesktopShutdownReport {
        voice_stop_requested: voice_cleanup_completed.is_some(),
        voice_cleanup_completed,
        pty_count,
        pty_exited_count,
    })
}

fn request_desktop_runtime_shutdown_for_app(app: &AppHandle) {
    let shutdown = app.state::<DesktopShutdownManager>();
    let summary = app.state::<DesktopSummaryStreamManager>();
    let voice = app.state::<VoiceCaptureManager>();
    let pty = app.state::<PtyManager>();
    if let Some(report) = request_desktop_runtime_shutdown(
        &shutdown,
        &summary,
        &voice,
        &pty,
        Duration::from_millis(DESKTOP_SHUTDOWN_VOICE_WAIT_MS),
        Duration::from_millis(DESKTOP_SHUTDOWN_PTY_WAIT_MS),
    ) {
        if report.pty_count != report.pty_exited_count {
            eprintln!(
                "Desktop shutdown stopped {}/{} PTY children before timeout.",
                report.pty_exited_count, report.pty_count
            );
        }
        if report.voice_cleanup_completed == Some(false) {
            eprintln!(
                "Desktop shutdown requested native voice capture stop, but cleanup timed out."
            );
        }
    }
}

fn close_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let entry = panes
        .remove(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    stop_single_pty_with_wait(&entry, Duration::from_millis(PTY_CLOSE_WAIT_MS));
    // Drop master to signal EOF to reader thread
    drop(entry.master);
    drop(entry.writer);
    emit_desktop_summary_refresh(
        app,
        DesktopSummaryRefreshSignal {
            source: "pty".to_string(),
            reason: "pty.close".to_string(),
            pane_id: Some(pane_id.to_string()),
            run_id: None,
        },
    );
    Ok(())
}

impl PtyCommandTransport for TauriPtyTransport {
    fn execute(&self, command: &PtyCommand) -> Result<serde_json::Value, String> {
        match command {
            PtyCommand::Spawn {
                pane_id,
                cols,
                rows,
                startup_input,
            } => {
                spawn_pty(
                    &self.app,
                    pane_id.clone(),
                    *cols,
                    *rows,
                    startup_input.clone(),
                    "pty.spawn",
                )?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Write { pane_id, data } => {
                write_pty(&self.app, pane_id, data)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Resize {
                pane_id,
                cols,
                rows,
            } => {
                resize_pty(&self.app, pane_id, *cols, *rows)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Capture { pane_id, lines } => capture_pty(&self.app, pane_id, *lines),
            PtyCommand::OperatorSnapshot { lines } => {
                capture_pty(&self.app, pty_backend::OPERATOR_PANE_ID, *lines)
            }
            PtyCommand::OperatorSubmit {
                text,
                submit_after_paste,
            } => {
                submit_operator_text(&self.app, text, *submit_after_paste)?;
                Ok(serde_json::json!({
                    "paneId": pty_backend::OPERATOR_PANE_ID,
                    "submitted": true
                }))
            }
            PtyCommand::Respawn { pane_id } => {
                respawn_pty(&self.app, pane_id)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
            PtyCommand::Close { pane_id } => {
                close_pty(&self.app, pane_id)?;
                Ok(serde_json::json!({ "paneId": pane_id }))
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(PtyManager {
            panes: Arc::new(Mutex::new(HashMap::new())),
            next_generation: AtomicU64::new(1),
        })
        .manage(DesktopSummaryStreamManager {
            started: AtomicBool::new(false),
            stop_requested: Arc::new(AtomicBool::new(false)),
        })
        .manage(DesktopShutdownManager {
            requested: AtomicBool::new(false),
        })
        .manage(VoiceCaptureManager {
            snapshot: Arc::new(Mutex::new(VoiceCaptureRuntimeSnapshot::default())),
            session: Mutex::new(None),
            next_generation: AtomicU64::new(1),
        })
        .setup(|app| {
            let app_handle = app.handle().clone();
            start_control_pipe_server(Arc::new(TauriPtyTransport {
                app: app_handle.clone(),
            }));
            schedule_desktop_summary_refresh_streams(app_handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            desktop_summary_snapshot,
            desktop_run_explain,
            desktop_json_rpc,
            desktop_voice_capture_status,
            desktop_voice_capture_start,
            desktop_voice_capture_stop,
            desktop_initial_project_dir,
            desktop_control_pipe_enabled,
            desktop_update_check,
            desktop_update_download_installer,
            desktop_update_launch_installer,
            pty_json_rpc,
            pty_spawn,
            pty_write,
            pty_resize,
            pty_capture,
            pty_respawn,
            pty_close
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if matches!(
            event,
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
        ) {
            request_desktop_runtime_shutdown_for_app(app_handle);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_temp_launch_project(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("winsmux-launch-arg-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("temp launch project should be created");
        path
    }

    #[test]
    fn launch_project_dir_accepts_explicit_flag() {
        let project_dir = make_temp_launch_project("explicit");
        let project_arg = project_dir.to_string_lossy().to_string();
        let resolved = resolve_initial_project_dir_from_args([
            "winsmux-app.exe".to_string(),
            "--project-dir".to_string(),
            project_arg.clone(),
        ])
        .expect("project dir should resolve");

        assert_eq!(resolved, project_arg);
        let _ = std::fs::remove_dir_all(project_dir);
    }

    #[test]
    fn launch_project_dir_accepts_explorer_positional_path() {
        let project_dir = make_temp_launch_project("positional");
        let project_arg = project_dir.to_string_lossy().to_string();
        let resolved = resolve_initial_project_dir_from_args([
            "winsmux-app.exe".to_string(),
            project_arg.clone(),
        ])
        .expect("project dir should resolve");

        assert_eq!(resolved, project_arg);
        let _ = std::fs::remove_dir_all(project_dir);
    }

    #[test]
    fn launch_project_dir_rejects_missing_or_non_directory_args() {
        let missing =
            std::env::temp_dir().join(format!("winsmux-launch-arg-missing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&missing);
        let resolved = resolve_initial_project_dir_from_args([
            "winsmux-app.exe".to_string(),
            "--project-dir".to_string(),
            missing.to_string_lossy().to_string(),
        ]);

        assert!(resolved.is_none());
    }

    #[test]
    fn trim_pty_history_preserves_utf8_boundaries() {
        let mut history = "あ".repeat((PTY_CAPTURE_LIMIT / 3) + 2);

        trim_pty_history(&mut history);

        assert!(history.len() <= PTY_CAPTURE_LIMIT);
        assert!(history.is_char_boundary(0));
        assert!(history.ends_with('あ'));
    }

    #[test]
    fn append_pty_history_keeps_recent_ring_contents() {
        let mut history = "old-output\n".to_string();
        let recent = format!("{}recent-marker", "x".repeat(PTY_CAPTURE_LIMIT + 32));

        append_pty_history(&mut history, &recent);

        assert!(history.len() <= PTY_CAPTURE_LIMIT);
        assert!(history.ends_with("recent-marker"));
        assert!(!history.contains("old-output"));
        assert!(history.is_char_boundary(0));
    }

    #[test]
    fn decode_pty_reader_bytes_preserves_split_utf8() {
        let mut pending = Vec::new();
        let character = "あ".as_bytes();

        let first = decode_pty_reader_bytes(&character[..1], &mut pending);
        let second = decode_pty_reader_bytes(&character[1..], &mut pending);

        assert_eq!(first, "");
        assert_eq!(second, "あ");
        assert!(pending.is_empty());
    }

    #[test]
    fn decode_pty_reader_bytes_replaces_invalid_utf8() {
        let mut pending = Vec::new();

        let decoded = decode_pty_reader_bytes(&[0xff, b'o', b'k'], &mut pending);

        assert_eq!(decoded, "\u{fffd}ok");
        assert!(pending.is_empty());
    }

    #[test]
    fn publish_pending_pty_utf8_updates_history_and_output() {
        let mut pending = vec![0xe3, 0x81];
        let history = Arc::new(Mutex::new(String::from("prefix")));
        let (tx, rx) = mpsc::sync_channel::<String>(1);

        assert!(publish_pending_pty_utf8(&mut pending, &history, &tx));

        assert!(pending.is_empty());
        assert_eq!(rx.try_recv().unwrap(), "\u{fffd}");
        assert_eq!(history.lock().unwrap().as_str(), "prefix\u{fffd}");
    }

    #[test]
    fn pty_output_batch_flushes_on_size_limit() {
        let now = Instant::now();
        let mut batch = PtyOutputBatch::new(now);

        batch.push(&"x".repeat(PTY_OUTPUT_BATCH_LIMIT - 1), now);
        assert!(!batch.should_flush(now));

        batch.push("x", now);
        assert!(batch.should_flush(now));
        assert_eq!(batch.take(now).len(), PTY_OUTPUT_BATCH_LIMIT);
        assert!(batch.is_empty());
    }

    #[test]
    fn pty_output_batch_flushes_on_interval() {
        let now = Instant::now();
        let mut batch = PtyOutputBatch::new(now);

        batch.push("ready", now);

        assert!(!batch.should_flush(now + Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS - 1)));
        assert!(batch.should_flush(now + Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS)));
    }

    #[test]
    fn pty_output_batch_recv_timeout_uses_remaining_interval() {
        let now = Instant::now();
        let mut batch = PtyOutputBatch::new(now);

        assert_eq!(
            batch.recv_timeout(now),
            Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS)
        );

        batch.push("ready", now);

        assert_eq!(
            batch.recv_timeout(now + Duration::from_millis(5)),
            Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS - 5)
        );
        assert_eq!(
            batch.recv_timeout(now + Duration::from_millis(PTY_OUTPUT_BATCH_INTERVAL_MS + 1)),
            Duration::from_millis(0)
        );
    }

    #[test]
    fn build_pty_command_sets_workspace_cwd() {
        let workspace = Path::new("C:\\repo\\winsmux");
        let command = build_pty_command(workspace);

        assert_eq!(
            command.get_cwd().and_then(|value| value.to_str()),
            Some("C:\\repo\\winsmux")
        );
        assert_eq!(
            command.get_env("TERM").and_then(|value| value.to_str()),
            Some("xterm-256color")
        );
        assert_eq!(
            command
                .get_env("COLORTERM")
                .and_then(|value| value.to_str()),
            Some("truecolor")
        );
        assert!(command.get_env(WINSMUX_CONTROL_PIPE_TOKEN_ENV).is_none());
    }

    #[test]
    fn limit_pty_capture_output_returns_recent_lines() {
        let output = limit_pty_capture_output("one\ntwo\nthree\nfour\n", Some(2));

        assert_eq!(output, "three\nfour");
    }

    #[test]
    fn submit_operator_text_writes_single_line_as_one_submit_write() {
        let mut writes = Vec::new();

        submit_operator_text_with(
            |data| {
                writes.push(data.to_string());
                Ok(())
            },
            "Continue with option 1\r",
            false,
        )
        .expect("single line submit should write");

        assert_eq!(writes, ["Continue with option 1\r"]);
    }

    #[test]
    fn submit_operator_text_writes_multiline_paste_then_enter() {
        let mut writes = Vec::new();

        submit_operator_text_with(
            |data| {
                writes.push(data.to_string());
                Ok(())
            },
            "\x1b[200~Line one\nLine two\x1b[201~",
            true,
        )
        .expect("multiline submit should write paste and enter");

        assert_eq!(writes, ["\x1b[200~Line one\nLine two\x1b[201~", "\r"]);
    }

    #[test]
    fn submit_operator_text_returns_error_when_enter_write_fails() {
        let mut writes = Vec::new();

        let err = submit_operator_text_with(
            |data| {
                writes.push(data.to_string());
                if data == "\r" {
                    Err("enter write failed".to_string())
                } else {
                    Ok(())
                }
            },
            "\x1b[200~Line one\nLine two\x1b[201~",
            true,
        )
        .expect_err("enter failure should fail submit");

        assert_eq!(err, "enter write failed");
        assert_eq!(writes, ["\x1b[200~Line one\nLine two\x1b[201~", "\r"]);
    }

    #[test]
    fn calculate_pcm16_meter_level_reports_silence() {
        assert_eq!(calculate_pcm16_meter_level(&[0, 0, 0, 0]), 0.0);
    }

    #[test]
    fn calculate_pcm16_meter_level_reports_signal_strength() {
        let level = calculate_pcm16_meter_level(&[
            0xff, 0x7f, // i16::MAX
            0x01, 0x80, // i16::MIN + 1
        ]);

        assert!(level > 0.99);
        assert!(level <= 1.0);
    }

    #[test]
    fn wait_voice_capture_cleanup_observes_completed_session() {
        let session = VoiceCaptureSession {
            generation: 1,
            stop_requested: Arc::new(AtomicBool::new(false)),
            cleanup_complete: Arc::new(AtomicBool::new(true)),
        };

        assert!(wait_voice_capture_cleanup(
            &session,
            Duration::from_millis(1)
        ));
    }

    #[test]
    fn wait_voice_capture_cleanup_times_out_for_busy_session() {
        let session = VoiceCaptureSession {
            generation: 1,
            stop_requested: Arc::new(AtomicBool::new(false)),
            cleanup_complete: Arc::new(AtomicBool::new(false)),
        };

        assert!(!wait_voice_capture_cleanup(
            &session,
            Duration::from_millis(1)
        ));
    }

    #[test]
    fn desktop_shutdown_stops_summary_voice_and_empty_pty_registry_once() {
        let shutdown = DesktopShutdownManager {
            requested: AtomicBool::new(false),
        };
        let summary = DesktopSummaryStreamManager {
            started: AtomicBool::new(false),
            stop_requested: Arc::new(AtomicBool::new(false)),
        };
        let voice_stop_requested = Arc::new(AtomicBool::new(false));
        let voice = VoiceCaptureManager {
            snapshot: Arc::new(Mutex::new(VoiceCaptureRuntimeSnapshot {
                generation: 1,
                state: "recording".to_string(),
                permission: "granted".to_string(),
                reason: "Native microphone capture is recording.".to_string(),
                meter_level: 0.4,
                running: true,
                native_available: true,
            })),
            session: Mutex::new(Some(VoiceCaptureSession {
                generation: 1,
                stop_requested: voice_stop_requested.clone(),
                cleanup_complete: Arc::new(AtomicBool::new(true)),
            })),
            next_generation: AtomicU64::new(2),
        };
        let pty = PtyManager {
            panes: Arc::new(Mutex::new(HashMap::new())),
            next_generation: AtomicU64::new(1),
        };

        let report = request_desktop_runtime_shutdown(
            &shutdown,
            &summary,
            &voice,
            &pty,
            Duration::from_millis(1),
            Duration::from_millis(1),
        )
        .expect("first shutdown request should run cleanup");

        assert!(summary.stop_requested.load(Ordering::SeqCst));
        assert!(voice_stop_requested.load(Ordering::SeqCst));
        assert_eq!(
            report,
            DesktopShutdownReport {
                voice_stop_requested: true,
                voice_cleanup_completed: Some(true),
                pty_count: 0,
                pty_exited_count: 0,
            }
        );
        let snapshot = voice.snapshot.lock().expect("snapshot lock").clone();
        assert_eq!(snapshot.state, "stopped");
        assert!(!snapshot.running);
        assert!(voice.session.lock().expect("session lock").is_none());

        assert!(request_desktop_runtime_shutdown(
            &shutdown,
            &summary,
            &voice,
            &pty,
            Duration::from_millis(1),
            Duration::from_millis(1),
        )
        .is_none());
    }

    #[test]
    fn native_voice_status_keeps_dictation_on_text_fallback_contract() {
        let mut status = desktop_backend::build_desktop_voice_capture_status(
            desktop_backend::DesktopVoiceDeviceProbe {
                device_count: 1,
                first_device_name: Some("USB Microphone".to_string()),
                error: None,
            },
        );

        status.native.available = true;
        status.native.meter_supported = true;
        apply_native_voice_dictation_fallback_contract(&mut status);

        assert_eq!(status.capture_mode, "browser_fallback");
        assert!(status.native.available);
        assert!(status.native.meter_supported);
        assert!(status.browser_fallback.expected);
        assert!(status
            .browser_fallback
            .reason
            .contains("does not transcribe audio into text"));
    }

    #[test]
    fn native_voice_snapshot_status_keeps_dictation_on_text_fallback_contract() {
        let base_status = desktop_backend::build_desktop_voice_capture_status(
            desktop_backend::DesktopVoiceDeviceProbe {
                device_count: 1,
                first_device_name: Some("USB Microphone".to_string()),
                error: None,
            },
        );
        let status = desktop_voice_capture_status_from_base(
            base_status,
            VoiceCaptureRuntimeSnapshot {
                generation: 7,
                state: "recording".to_string(),
                permission: "granted".to_string(),
                reason: "Native microphone capture is recording.".to_string(),
                meter_level: 1.5,
                running: true,
                native_available: true,
            },
        );

        assert_eq!(status.capture_mode, "browser_fallback");
        assert!(status.native.available);
        assert_eq!(status.native.state, "recording");
        assert_eq!(status.native.meter_level, 1.0);
        assert!(status.browser_fallback.expected);
        assert!(status
            .browser_fallback
            .reason
            .contains("does not transcribe audio into text"));
    }
}
