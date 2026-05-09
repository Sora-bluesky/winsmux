mod control_pipe;
mod desktop_backend;
mod pty_backend;

use control_pipe::start_control_pipe_server;
use desktop_backend::{
    handle_desktop_json_rpc, load_desktop_run_explain, load_desktop_summary_snapshot,
    spawn_desktop_summary_refresh_stream, DesktopExplainPayload, DesktopJsonRpcRequest,
    DesktopJsonRpcResponse, DesktopStreamCommand, DesktopSummaryRefreshSignal,
    DesktopSummarySnapshot, DesktopVoiceCaptureStatus, PwshScriptTransport,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use pty_backend::{
    handle_pty_json_rpc, PtyCommand, PtyCommandTransport, PtyJsonRpcRequest, PtyJsonRpcResponse,
};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
const NATIVE_VOICE_METER_ONLY_REASON: &str =
    "Native microphone capture is available for metering only; desktop dictation still uses the documented text fallback.";
const NATIVE_VOICE_DICTATION_FALLBACK_REASON: &str =
    "Use browser speech recognition for composer dictation. Native microphone capture does not transcribe audio into text.";

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

    let mut cmd = CommandBuilder::new("pwsh");
    cmd.arg("-NoLogo");

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
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            if !alive.load(Ordering::SeqCst) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).to_string();
                    let Ok(current_panes) = panes.lock() else {
                        break;
                    };
                    let is_current = current_panes
                        .get(&pane_id)
                        .map(|pty| pty.generation == generation && Arc::ptr_eq(&pty.alive, &alive))
                        .unwrap_or(false);
                    if !is_current || !alive.load(Ordering::SeqCst) {
                        break;
                    }
                    if let Ok(mut history) = output_history.lock() {
                        history.push_str(&data);
                        trim_pty_history(&mut history);
                    }
                    let _ = app_handle.emit(
                        "pty-output",
                        serde_json::json!({"pane_id": pane_id, "data": data}),
                    );
                }
                Err(_) => break,
            }
        }
    });
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

fn stop_single_pty(entry: &SinglePty) {
    entry.alive.store(false, Ordering::SeqCst);
    if let Ok(mut child) = entry.child.lock() {
        let _ = child.kill();
    }
}

fn close_pty(app: &AppHandle, pane_id: &str) -> Result<(), String> {
    let manager = app.state::<PtyManager>();
    let mut panes = manager.panes.lock().map_err(|e| e.to_string())?;
    let entry = panes
        .remove(pane_id)
        .ok_or_else(|| format!("Pane {} not found", pane_id))?;
    stop_single_pty(&entry);
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
            start_desktop_summary_refresh_streams(&app_handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            desktop_summary_snapshot,
            desktop_run_explain,
            desktop_json_rpc,
            desktop_voice_capture_status,
            desktop_voice_capture_start,
            desktop_voice_capture_stop,
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
            let manager = app_handle.state::<DesktopSummaryStreamManager>();
            manager.stop_requested.store(true, Ordering::SeqCst);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_pty_history_preserves_utf8_boundaries() {
        let mut history = "あ".repeat((PTY_CAPTURE_LIMIT / 3) + 2);

        trim_pty_history(&mut history);

        assert!(history.len() <= PTY_CAPTURE_LIMIT);
        assert!(history.is_char_boundary(0));
        assert!(history.ends_with('あ'));
    }

    #[test]
    fn limit_pty_capture_output_returns_recent_lines() {
        let output = limit_pty_capture_output("one\ntwo\nthree\nfour\n", Some(2));

        assert_eq!(output, "three\nfour");
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
