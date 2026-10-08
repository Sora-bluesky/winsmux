#![cfg(windows)]
#![windows_subsystem = "windows"]

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager};

struct NativeHarnessFailure(Arc<AtomicBool>);

// Private-command proof uses the production local origin without mounting a
// second frontend input owner. The normal GUI/IME proof retains production assets.
struct InputGuardFixtureAssets;
impl tauri::Assets<tauri::Wry> for InputGuardFixtureAssets {
    fn get(&self, key: &tauri::utils::assets::AssetKey) -> Option<std::borrow::Cow<'_, [u8]>> {
        (key.as_ref() == "/index.html").then_some(std::borrow::Cow::Borrowed(
            b"<!doctype html><html lang='ja'><head><meta charset='utf-8'><title>winsmux native IPC proof</title></head><body><p role='status'>TASK-872 native IPC verification</p></body></html>".as_slice(),
        ))
    }
    fn iter(&self) -> Box<tauri::utils::assets::AssetsIter<'_>> {
        let key = tauri::utils::assets::AssetKey::from("index.html");
        Box::new(std::iter::once((std::borrow::Cow::Borrowed("/index.html"), self.get(&key).unwrap())))
    }
    fn csp_hashes(&self, _: &tauri::utils::assets::AssetKey) -> Box<dyn Iterator<Item = tauri::utils::assets::CspHash<'_>> + '_> {
        Box::new(std::iter::empty())
    }
}

#[path = "../../../core/tests-rs/support/conpty_json.rs"]
mod conpty_json;

struct IndependentHost {
    child: Box<dyn portable_pty::Child + Send + Sync>,
    writer: Option<Box<dyn Write + Send>>,
    master: Option<Box<dyn portable_pty::MasterPty + Send>>,
    output: Option<conpty_json::JsonOutput>,
}

impl IndependentHost {
    // Match InteractiveHost::receive_json: child exit can precede the reader's
    // last queued chunk. Collect that chunk before classifying a missing frame.
    fn receive(&mut self) -> Result<Value, &'static str> {
        let process = self
            .child
            .as_raw_handle()
            .ok_or("independent process handle missing")?;
        let output = self.output.as_mut().ok_or("independent output missing")?;
        match output.next_json_with_process(process) {
            Ok(value) => Ok(value),
            Err(exit) => {
                eprintln!(
                    "TASK870_INDEPENDENT_OUTPUT_DRAIN reason={} signaled={} exit={:?}",
                    exit.reason, exit.signaled, exit.exit_code
                );
                drop(self.writer.take());
                drop(self.master.take());
                output.join_nonpanic();
                output
                    .finish_json_after_reader_join()
                    .ok_or("independent final response missing")
            }
        }
    }
}

impl Drop for IndependentHost {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        drop(self.writer.take());
        drop(self.master.take());
        if let Some(output) = self.output.as_mut() {
            output.join_nonpanic();
        }
    }
}

#[derive(Default)]
struct IndependentHostSlot(Arc<Mutex<Option<IndependentHost>>>);

#[tauri::command]
async fn native_independent_host_start(
    inputs: tauri::State<'_, NativeInputs>,
    slot: tauri::State<'_, IndependentHostSlot>,
) -> Result<Value, &'static str> {
    let binary = inputs.sidecar.clone();
    let home = inputs.home.clone();
    let slot = slot.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        use portable_pty::{native_pty_system, CommandBuilder, PtySize};
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 4096,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|_| "independent ConPTY open failed")?;
        let mut command = CommandBuilder::new(binary);
        command.args(["workspace", "host"]);
        command.env("USERPROFILE", &home);
        command.env("HOME", &home);
        let child = pair
            .slave
            .spawn_command(command)
            .map_err(|_| "independent CLI host spawn failed")?;
        drop(pair.slave);
        // Own the child before any later endpoint acquisition can fail.
        let mut host = IndependentHost {
            child,
            writer: None,
            master: Some(pair.master),
            output: None,
        };
        let reader = host
            .master
            .as_ref()
            .expect("owned ConPTY")
            .try_clone_reader()
            .map_err(|_| "independent reader failed")?;
        let writer = host
            .master
            .as_ref()
            .expect("owned ConPTY")
            .take_writer()
            .map_err(|_| "independent writer failed")?;
        host.writer = Some(writer);
        let writer = host.writer.as_mut().expect("owned writer");
        writer
            .write_all(b"\x1b[1;1R")
            .and_then(|_| writer.flush())
            .map_err(|_| "independent cursor reply failed")?;
        host.output = Some(conpty_json::JsonOutput::start(reader));
        eprintln!(
            "TASK870_INDEPENDENT_LAUNCH pid={} reader_started=true",
            host.child.process_id().unwrap_or(0)
        );
        let discovery = host.receive()?;
        eprintln!("TASK870_INDEPENDENT_DISCOVERY_RECEIVED");
        if discovery["instance_id"].as_str().is_none() {
            return Err("independent discovery malformed");
        }
        *slot.lock().map_err(|_| "independent host lock")? = Some(host);
        Ok(discovery)
    })
    .await
    .map_err(|_| "independent startup worker failed")?
}

#[tauri::command]
async fn native_independent_host_request(
    request_json: String,
    slot: tauri::State<'_, IndependentHostSlot>,
) -> Result<Value, &'static str> {
    let slot = slot.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let request = winsmux_workspace::parse_request(request_json.as_bytes())
            .map_err(|_| "independent request malformed")?;
        let mut slot = slot.lock().map_err(|_| "independent host lock")?;
        let host = slot.as_mut().ok_or("independent host absent")?;
        let bytes = winsmux_workspace::canonical_request(&request)
            .map_err(|_| "independent canonical request failed")?;
        let writer = host.writer.as_mut().ok_or("independent writer absent")?;
        writer
            .write_all(&bytes)
            .and_then(|_| writer.write_all(b"\r\n"))
            .and_then(|_| writer.flush())
            .map_err(|_| "independent request write failed")?;
        let response = host.receive()?;
        eprintln!("TASK870_INDEPENDENT_RESPONSE_RECEIVED");
        winsmux_workspace::parse_response(&request, &serde_json::to_vec(&response).unwrap())
            .map_err(|_| "independent response invalid")?;
        Ok(response)
    })
    .await
    .map_err(|_| "independent request worker failed")?
}

#[tauri::command]
async fn native_independent_host_report(
    app: tauri::AppHandle,
    value: Value,
    slot: tauri::State<'_, IndependentHostSlot>,
    manager: tauri::State<'_, Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>,
    inputs: tauri::State<'_, NativeInputs>,
) -> Result<(), &'static str> {
    std::fs::write(
        inputs.home.join("native-independent-host-report.json"),
        serde_json::to_vec(&value).unwrap(),
    )
    .map_err(|_| "independent report failed")?;
    // The child's singleton rejection closes the startup channel. Preserve the
    // same EOF -> transport_failed classification used by the CLI launcher.
    if value["guiError"] != json!("transport_failed")
        || value["before"]["accepted"] != json!(true)
        || value["before"]["result"] != value["after"]["result"]
        || value["before"]["instance_id"] != value["after"]["instance_id"]
        || value["before"]["topology_revision"] != value["after"]["topology_revision"]
        || value["saved"]["accepted"] != json!(true)
        || value["snapshotUnchanged"] != json!(true)
        || value["stop"]["accepted"] != json!(true)
        || manager.has_session()
    {
        return Err("independent host changed by GUI singleton attempt");
    }
    let slot = slot.0.clone();
    tauri::async_runtime::spawn_blocking(move||{
        let mut host=slot.lock().map_err(|_| "independent host lock")?.take().ok_or("independent host missing")?;
        let exit=host.child.wait().map_err(|_| "independent host wait failed")?;
        if !exit.success(){return Err("independent host stop exit failed");}
        drop(host);
        eprintln!("TASK870_NATIVE_INDEPENDENT_HOST_PROOF gui_startup_denied=true gui_session_absent=true original_instance_unchanged=true original_capabilities_unchanged=true original_stop_collected=true");
        Ok(())
    }).await.map_err(|_| "independent cleanup worker failed")??;
    app.exit(0);
    Ok(())
}

struct NativeInputs {
    home: PathBuf,
    project: PathBuf,
    sidecar: PathBuf,
    sibling: PathBuf,
    rollback_cli: PathBuf,
}

struct PublicCli {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
}

#[derive(Default)]
struct PublicCliSlot(Mutex<Option<PublicCli>>);

struct UnrelatedCli {
    child: Child,
    input: Option<ChildStdin>,
}

#[derive(Default)]
struct UnrelatedCliSlot(Mutex<Option<UnrelatedCli>>);

#[tauri::command]
fn native_unrelated_cli_start(
    inputs: tauri::State<'_, NativeInputs>,
    slot: tauri::State<'_, UnrelatedCliSlot>,
) -> Result<(), &'static str> {
    let mut guard = slot.0.lock().map_err(|_| "unrelated CLI lock failed")?;
    if guard.is_some() {
        return Err("unrelated CLI already open");
    }
    let mut child = Command::new(&inputs.sidecar)
        .args(["workspace", "connect"])
        .env("USERPROFILE", &inputs.home)
        .env("HOME", &inputs.home)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "unrelated CLI spawn failed")?;
    let input = child.stdin.take().ok_or("unrelated CLI stdin missing")?;
    *guard = Some(UnrelatedCli {
        child,
        input: Some(input),
    });
    Ok(())
}

#[tauri::command]
fn native_unrelated_cli_alive(
    slot: tauri::State<'_, UnrelatedCliSlot>,
) -> Result<bool, &'static str> {
    let mut guard = slot.0.lock().map_err(|_| "unrelated CLI lock failed")?;
    let process = guard.as_mut().ok_or("unrelated CLI absent")?;
    Ok(process
        .child
        .try_wait()
        .map_err(|_| "unrelated CLI query failed")?
        .is_none())
}

#[tauri::command]
fn native_unrelated_cli_close(
    slot: tauri::State<'_, UnrelatedCliSlot>,
) -> Result<(), &'static str> {
    let mut guard = slot.0.lock().map_err(|_| "unrelated CLI lock failed")?;
    let mut process = guard.take().ok_or("unrelated CLI absent")?;
    drop(process.input.take());
    let status = process
        .child
        .wait()
        .map_err(|_| "unrelated CLI wait failed")?;
    if !status.success() {
        return Err("unrelated CLI exit failed");
    }
    Ok(())
}

#[derive(Default)]
struct SnapshotBaseline(Mutex<Option<Vec<u8>>>);

#[derive(Default)]
struct ForceExitProof {
    cancelled: AtomicBool,
    confirmed: AtomicBool,
    cancellation_preserved: AtomicBool,
}

#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
struct NativeFaultGate(Arc<winsmux_workspace::host::StopReplyLossGate>);

#[derive(Default)]
struct FaultProof {
    ready: AtomicBool,
    snapshot_valid: AtomicBool,
    abandoned: AtomicBool,
    unknown_retained: AtomicBool,
}

#[tauri::command]
fn native_gate_ready(app: tauri::AppHandle) -> bool {
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    {
        return app.state::<NativeFaultGate>().0.ready();
    }
    #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
    {
        let _ = app;
        false
    }
}

#[tauri::command]
fn native_gate_validate_release(abandon: bool, app: tauri::AppHandle) -> Result<(), &'static str> {
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    {
        let gate = app.state::<NativeFaultGate>();
        // This guard outlives every validation return and signals before owner cleanup.
        let _release = gate.0.release_on_drop();
        if !gate.0.ready() {
            return Err("gate not ready");
        }
        let proof = app.state::<FaultProof>();
        proof.ready.store(true, Ordering::SeqCst);
        if abandon {
            proof.abandoned.store(true, Ordering::SeqCst);
            eprintln!("TASK870_NATIVE_FAULT_VALIDATION expected=validation_failed actual=validation_failed status=expected_failure");
            return Err("validation_failed");
        }
        let inputs = app.state::<NativeInputs>();
        let bytes = std::fs::read(confirmed_snapshot_path(&inputs))
            .map_err(|_| "fault snapshot unreadable")?;
        winsmux_workspace::parse_snapshot(&bytes).map_err(|_| "fault snapshot invalid")?;
        *app.state::<SnapshotBaseline>()
            .0
            .lock()
            .map_err(|_| "fault baseline lock")? = Some(bytes);
        proof.snapshot_valid.store(true, Ordering::SeqCst);
        Ok(())
    }
    #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
    {
        let _ = (abandon, app);
        Err("fault feature unavailable")
    }
}

#[tauri::command]
fn native_fault_unknown_proof(
    value: Value,
    proof: tauri::State<'_, FaultProof>,
) -> Result<(), &'static str> {
    if value["unknownOpen"] != json!("transport_uncertain")
        || value["reclose"] != json!("transport_uncertain")
        || value["windowRetained"] != json!(true)
    {
        return Err("lost reply incorrectly confirmed close");
    }
    proof.unknown_retained.store(true, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
fn native_gate_parent_exit(app: tauri::AppHandle) -> Result<(), &'static str> {
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    {
        if !app.state::<NativeFaultGate>().0.ready() {
            return Err("gate not ready");
        }
        let inputs = app.state::<NativeInputs>();
        let bytes = std::fs::read(confirmed_snapshot_path(&inputs))
            .map_err(|_| "parent exit snapshot unavailable")?;
        winsmux_workspace::parse_snapshot(&bytes).map_err(|_| "parent exit snapshot invalid")?;
        eprintln!("TASK870_NATIVE_FAULT_PARENT_EXIT_ARMED ready=true snapshot_valid=true discard_unsignaled=true pid={}",std::process::id());
        unsafe {
            use windows_sys::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
            if TerminateProcess(GetCurrentProcess(), 87) == 0 {
                return Err("parent termination failed");
            }
        }
        Ok(())
    }
    #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
    {
        let _ = app;
        Err("fault feature unavailable")
    }
}

#[tauri::command]
fn native_sidecar_report(app: tauri::AppHandle, value: Value, inputs: tauri::State<'_, NativeInputs>) {
    let verified = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let available = value["scenario"] == json!("sidecar-available");
        if available {
            assert_eq!(value["artifact"]["accepted"], json!(false));
            assert!(value["artifact"]["error"].is_object());
        } else {
            assert_eq!(value["artifactError"], json!("protocol_failed"));
            assert_eq!(value["sameIdOrdinary"]["accepted"], json!(true));
        }
        assert_eq!(value["before"]["result"], value["after"]["result"]);
        assert_eq!(
            value["before"]["topology_revision"],
            value["after"]["topology_revision"]
        );
        assert_eq!(value["after"]["accepted"], json!(true));
        assert_eq!(value["close"]["accepted"], json!(true));
        assert_eq!(
            std::fs::read(inputs.project.join("marker.txt")).unwrap(),
            b"task870 project"
        );
        std::fs::write(
            inputs.home.join("native-sidecar-report.json"),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        eprintln!("TASK870_NATIVE_SIDECAR_PROOF scenario={} response_class_preserved=true unavailable_zero_owner_frames={} next_request_usable=true state_preserved=true close_collected=true",value["scenario"],!available);
    }));
    if verified.is_err() {app.state::<NativeHarnessFailure>().0.store(true,Ordering::SeqCst);app.exit(1);return;}
    app.exit(0);
}

#[tauri::command]
fn native_record_snapshot_baseline(
    inputs: tauri::State<'_, NativeInputs>,
    baseline: tauri::State<'_, SnapshotBaseline>,
) -> Result<(), &'static str> {
    let bytes = std::fs::read(confirmed_snapshot_path(&inputs))
        .map_err(|_| "baseline snapshot unavailable")?;
    *baseline.0.lock().map_err(|_| "baseline lock failed")? = Some(bytes);
    Ok(())
}

#[tauri::command]
fn native_force_cancel_proof(
    value: Value,
    proof: tauri::State<'_, ForceExitProof>,
) -> Result<(), &'static str> {
    if value["healthyForce"] != json!("force_exit_unavailable")
        || value["cancelError"] != json!("force_exit_cancelled")
        || value["unknownOpen"] != json!("transport_uncertain")
        || value["snapshotUnchanged"] != json!(true)
    {
        return Err("force cancellation changed unknown owner or snapshot");
    }
    proof.cancellation_preserved.store(true, Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
async fn native_choose_force_dialog(
    confirm: bool,
    proof: tauri::State<'_, ForceExitProof>,
) -> Result<(), &'static str> {
    native_force_phase("driver_begin");
    if confirm {
        proof.confirmed.store(true, Ordering::SeqCst);
    } else {
        proof.cancelled.store(true, Ordering::SeqCst);
    }
    let chosen = match tauri::async_runtime::spawn_blocking(move || choose_owned_force_dialog(confirm)).await {
        Ok(Ok(chosen)) => chosen,
        Ok(Err(error)) => {
            native_force_phase("driver_operation_error");
            return Err(error);
        }
        Err(_) => {
            native_force_phase("driver_worker_error");
            return Err("force dialog driver failed");
        }
    };
    if !chosen {
        native_force_phase("driver_not_found");
        return Err("force dialog not found");
    }
    native_force_phase("driver_chosen");
    Ok(())
}

fn choose_owned_force_dialog(confirm: bool) -> Result<bool, &'static str> {
    native_force_phase("blocking_begin");
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::System::Threading::GetCurrentProcessId;
    #[link(name = "user32")]
    extern "system" {
        fn EnumWindows(
            callback: Option<unsafe extern "system" fn(HWND, isize) -> i32>,
            data: isize,
        ) -> i32;
        fn EnumChildWindows(
            parent: HWND,
            callback: Option<unsafe extern "system" fn(HWND, isize) -> i32>,
            data: isize,
        ) -> i32;
        fn GetWindowThreadProcessId(window: HWND, pid: *mut u32) -> u32;
        fn GetWindowTextW(window: HWND, text: *mut u16, capacity: i32) -> i32;
        fn PostMessageW(window: HWND, message: u32, wparam: usize, lparam: isize) -> i32;
    }
    struct Target {
        pid: u32,
        window: HWND,
    }
    unsafe extern "system" fn find(window: HWND, data: isize) -> i32 {
        let target = &mut *(data as *mut Target);
        let mut pid = 0;
        GetWindowThreadProcessId(window, &mut pid);
        let mut title = [0u16; 256];
        let count = GetWindowTextW(window, title.as_mut_ptr(), title.len() as i32);
        if pid == target.pid
            && String::from_utf16_lossy(&title[..count.max(0) as usize])
                == "Workspace state is uncertain"
        {
            target.window = window;
            return 0;
        }
        1
    }
    unsafe extern "system" fn collect(window: HWND, data: isize) -> i32 {
        let texts = &mut *(data as *mut Vec<String>);
        let mut text = [0u16; 2048];
        let count = GetWindowTextW(window, text.as_mut_ptr(), text.len() as i32);
        if count > 0 {
            texts.push(String::from_utf16_lossy(&text[..count as usize]));
        }
        1
    }
    for _ in 0..30 {
        let mut target = Target {
            pid: unsafe { GetCurrentProcessId() },
            window: std::ptr::null_mut(),
        };
        unsafe {
            EnumWindows(Some(find), &mut target as *mut _ as isize);
        }
        if !target.window.is_null() {
            native_force_phase("owned_dialog_found");
            let mut texts = Vec::<String>::new();
            unsafe {
                EnumChildWindows(target.window, Some(collect), &mut texts as *mut _ as isize);
            }
            let warning = texts.join(" ");
            let win32_warning_verified = warning.contains("Saving could not be confirmed")
                && warning.contains("last durable snapshot may be older");
            native_force_phase(if win32_warning_verified { "win32_warning_verified" } else { "uia_warning_selected" });
            let warning_verified = win32_warning_verified
                || owned_dialog_warning_via_automation(target.window as usize, target.pid);
            if !warning_verified {
                native_force_phase("warning_unverified");
                return Err("force dialog warning content missing");
            }
            eprintln!("TASK870_NATIVE_FORCE_DIALOG_PROOF own_pid=true title=true warning=true confirm={confirm}");
            if !confirm {
                native_force_phase("capture_hold_begin");
                capture_hold(
                    "warning",
                    target.window as usize,
                    "Workspace state is uncertain",
                )?;
                native_force_phase("capture_hold_return");
            }
            // TaskDialog's standard Yes/No IDs, sent only to this test's verified dialog.
            native_force_phase(if confirm { "choice_confirm_begin" } else { "choice_cancel_begin" });
            if unsafe { PostMessageW(target.window, 0x0400 + 102, if confirm { 6 } else { 7 }, 0) }
                == 0
            {
                native_force_phase("choice_dispatch_failed");
                return Err("force dialog choice dispatch failed");
            }
            native_force_phase("choice_dispatched");
            return Ok(true);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    native_force_phase("dialog_search_exhausted");
    Ok(false)
}

fn capture_hold(state: &str, hwnd: usize, title: &str) -> Result<(), &'static str> {
    let Some(root) = std::env::var_os("TASK870_CAPTURE_ROOT").map(PathBuf::from) else {
        return Ok(());
    };
    std::fs::create_dir_all(&root).map_err(|_| "capture root failed")?;
    let ready = root.join(format!("{state}-ready.json"));
    let proceed = root.join(format!("{state}-continue"));
    std::fs::write(
        &ready,
        serde_json::to_vec(
            &json!({"pid":std::process::id(),"hwnd":hwnd,"title":title,"state":state}),
        )
        .unwrap(),
    )
    .map_err(|_| "capture ready failed")?;
    eprintln!(
        "TASK870_NATIVE_CAPTURE_READY state={state} pid={} hwnd={hwnd} file={}",
        std::process::id(),
        ready.display()
    );
    while !proceed.is_file() {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Ok(())
}

#[tauri::command]
async fn native_capture_unknown(window: tauri::WebviewWindow) -> Result<(), &'static str> {
    let title = window.title().map_err(|_| "capture title failed")?;
    let hwnd = window.hwnd().map_err(|_| "capture HWND failed")?.0 as usize;
    tauri::async_runtime::spawn_blocking(move || capture_hold("unknown", hwnd, &title))
        .await
        .map_err(|_| "capture worker failed")?
}

fn native_force_phase(phase: &'static str) {
    let _ = writeln!(std::io::stderr().lock(), "TASK870_NATIVE_FORCE_PHASE phase={phase}");
}

#[tauri::command]
fn native_force_tail_phase(phase: String, rejected: bool) {
    if matches!(phase.as_str(), "report_begin" | "report_return" | "force_begin" | "choose_begin" | "choose_return" | "force_return") {
        let _ = writeln!(std::io::stderr().lock(), "TASK870_NATIVE_FORCE_TAIL phase={phase} promise_rejected={rejected}");
    }
}

#[repr(C)]
#[derive(Default)]
struct NativeObservedFileTime {
    low: u32,
    high: u32,
}

#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcess() -> *mut std::ffi::c_void;
    fn DuplicateHandle(source_process: *mut std::ffi::c_void, source: *mut std::ffi::c_void, target_process: *mut std::ffi::c_void, target: *mut *mut std::ffi::c_void, access: u32, inherit: i32, options: u32) -> i32;
    fn GetProcessTimes(process: *mut std::ffi::c_void, creation: *mut NativeObservedFileTime, exit: *mut NativeObservedFileTime, kernel: *mut NativeObservedFileTime, user: *mut NativeObservedFileTime) -> i32;
    fn QueryFullProcessImageNameW(process: *mut std::ffi::c_void, flags: u32, name: *mut u16, size: *mut u32) -> i32;
    fn WaitForSingleObject(object: *mut std::ffi::c_void, milliseconds: u32) -> u32;
    fn GetExitCodeProcess(process: *mut std::ffi::c_void, code: *mut u32) -> i32;
    fn CloseHandle(object: *mut std::ffi::c_void) -> i32;
}

struct NativeObservedProcess(*mut std::ffi::c_void);

// Only this non-inheritable duplicate is transferred; the original Child stays
// with wait_with_output. The observer never opens a process by its numeric PID.
unsafe impl Send for NativeObservedProcess {}

impl Drop for NativeObservedProcess {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0); }
    }
}

fn native_observe_uia_root(held: NativeObservedProcess, pid: u32) {
    let signaled = unsafe { WaitForSingleObject(held.0, u32::MAX) } == 0;
    let mut exit = 0;
    let available = signaled && unsafe { GetExitCodeProcess(held.0, &mut exit) } != 0;
    let _ = writeln!(std::io::stderr().lock(), "TASK870_NATIVE_UIA_ROOT pid={pid} signaled={signaled} exit_available={available} exit={exit}");
}

fn native_start_uia_observer(child: &Child) {
    use std::os::windows::ffi::OsStringExt;
    use std::os::windows::io::AsRawHandle;
    let mut duplicate = std::ptr::null_mut();
    let process = unsafe { GetCurrentProcess() };
    // SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, non-inheritable.
    if unsafe { DuplicateHandle(process, child.as_raw_handle(), process, &mut duplicate, 0x0010_1000, 0, 0) } == 0 {
        native_force_phase("uia_observer_handle_unavailable");
        return;
    }
    let held = NativeObservedProcess(duplicate);
    let pid = child.id();
    let mut creation = NativeObservedFileTime::default();
    let mut exit = NativeObservedFileTime::default();
    let mut kernel = NativeObservedFileTime::default();
    let mut user = NativeObservedFileTime::default();
    let time_available = unsafe { GetProcessTimes(held.0, &mut creation, &mut exit, &mut kernel, &mut user) } != 0;
    let created = (u64::from(creation.high) << 32) | u64::from(creation.low);
    let mut name = vec![0u16; 32768];
    let mut size = name.len() as u32;
    let image_sha = if unsafe { QueryFullProcessImageNameW(held.0, 0, name.as_mut_ptr(), &mut size) } != 0 {
        let path = PathBuf::from(std::ffi::OsString::from_wide(&name[..size as usize]));
        std::fs::read(path).ok().map(|bytes| format!("{:x}", Sha256::digest(bytes)))
    } else { None };
    let image_sha = match image_sha.as_deref() { Some(value) => value, None => "unavailable" };
    let _ = writeln!(std::io::stderr().lock(), "TASK870_NATIVE_UIA_IDENTITY pid={pid} creation_available={time_available} creation={created} image_sha256={image_sha}");
    // No join: this observation lives until natural root exit or harness exit.
    if std::thread::Builder::new().name("native-uia-observer".to_owned()).spawn(move || native_observe_uia_root(held, pid)).is_err() {
        native_force_phase("uia_observer_worker_unavailable");
    }
}

fn owned_dialog_warning_via_automation(window: usize, process_id: u32) -> bool {
    use std::os::windows::process::CommandExt;
    let script = format!(
        r#"$ErrorActionPreference='Stop'; Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes; $target=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]{window}); if ($target.Current.ProcessId -ne {process_id}) {{ exit 2 }}; $nodes=$target.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition); $names=foreach ($item in $nodes) {{ $item.Current.Name }}; $warning=$names -join ' '; if ($warning.Contains('Saving could not be confirmed') -and $warning.Contains('last durable snapshot may be older')) {{ [Console]::Write('warning_verified'); exit 0 }}; exit 3"#
    );
    let Some(windows_root)=std::env::var_os("SystemRoot") else{native_force_phase("uia_image_unavailable");return false;};
    native_force_phase("uia_spawn_begin");
    let child = Command::new(PathBuf::from(windows_root).join("System32/WindowsPowerShell/v1.0/powershell.exe"))
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(0x08000000)
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn();
    let child = match child {
        Ok(child) => child,
        Err(_) => { native_force_phase("uia_spawn_failed"); return false; }
    };
    native_force_phase("uia_spawned");
    native_start_uia_observer(&child);
    native_force_phase("uia_output_wait_begin");
    match child.wait_with_output() {
        Ok(output) => {
            let _ = writeln!(std::io::stderr().lock(), "TASK870_NATIVE_UIA_OUTPUT collected=true stdout_bytes={} stderr_bytes={}", output.stdout.len(), output.stderr.len());
            let verified = output.status.success() && output.stdout == b"warning_verified";
            native_force_phase(if verified { "uia_warning_verified" } else { "uia_warning_unverified" });
            verified
        }
        Err(_) => { native_force_phase("uia_output_unconfirmed"); false }
    }
}

fn confirmed_snapshot_path(inputs: &NativeInputs) -> PathBuf {
    inputs
        .home
        .join("AppData/Local/winsmux/workspace/v1/confirmed.json")
}

#[tauri::command]
fn native_block_snapshot_temp(
    block: bool,
    inputs: tauri::State<'_, NativeInputs>,
    baseline: tauri::State<'_, SnapshotBaseline>,
) -> Result<(), &'static str> {
    let obstruction = inputs
        .home
        .join("AppData/Local/winsmux/workspace/v1/temp.json");
    if block {
        let bytes = std::fs::read(confirmed_snapshot_path(&inputs))
            .map_err(|_| "baseline snapshot unavailable")?;
        *baseline.0.lock().map_err(|_| "baseline lock failed")? = Some(bytes);
        std::fs::create_dir(&obstruction).map_err(|_| "snapshot temp obstruction failed")
    } else {
        std::fs::remove_dir(&obstruction).map_err(|_| "snapshot temp recovery failed")
    }
}

#[tauri::command]
fn native_snapshot_unchanged(
    inputs: tauri::State<'_, NativeInputs>,
    baseline: tauri::State<'_, SnapshotBaseline>,
) -> Result<bool, &'static str> {
    let original = baseline.0.lock().map_err(|_| "baseline lock failed")?;
    let original = original.as_ref().ok_or("baseline snapshot absent")?;
    let current = std::fs::read(confirmed_snapshot_path(&inputs))
        .map_err(|_| "confirmed snapshot unreadable")?;
    Ok(&current == original)
}

#[tauri::command]
fn native_crash_kill(value: Value, inputs: tauri::State<'_, NativeInputs>) {
    let confirmed = std::fs::read(confirmed_snapshot_path(&inputs)).expect("crash baseline C");
    let snapshot: Value = serde_json::from_slice(&confirmed).expect("crash baseline snapshot JSON");
    winsmux_workspace::parse_snapshot(&confirmed).expect("crash baseline snapshot contract");
    assert_eq!(snapshot["projects"][0]["project_id"], value["project_id"]);
    assert_eq!(snapshot["panes"][0]["pane_id"], value["pane_id"]);
    assert_eq!(
        snapshot["projects"]
            .as_array()
            .expect("saved projects")
            .len(),
        1
    );
    assert_eq!(value["unsaved_project_accepted"], json!(true));
    std::fs::write(inputs.home.join("crash-confirmed-baseline.json"), confirmed)
        .expect("crash baseline record");
    std::fs::write(
        inputs.home.join("crash-expected.json"),
        serde_json::to_vec(&value).expect("crash expected JSON"),
    )
    .expect("crash expected record");
    eprintln!(
        "TASK870_NATIVE_CRASH_ARMED saved_project={} saved_pane={} unsaved_project=true",
        value["project_id"], value["pane_id"]
    );
    unsafe {
        use windows_sys::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
        if TerminateProcess(GetCurrentProcess(), 87) == 0 {
            std::process::exit(1);
        }
    }
}

#[tauri::command]
fn native_crash_snapshot_unchanged(inputs: tauri::State<'_, NativeInputs>) -> bool {
    std::fs::read(confirmed_snapshot_path(&inputs)).ok()
        == std::fs::read(inputs.home.join("crash-confirmed-baseline.json")).ok()
}

#[tauri::command]
fn native_crash_report(app: tauri::AppHandle, value: Value, inputs: tauri::State<'_, NativeInputs>) {
    let verified = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let expected: Value = serde_json::from_slice(
            &std::fs::read(inputs.home.join("crash-expected.json")).expect("crash expected bytes"),
        )
        .expect("crash expected JSON");
        assert!(
            value.get("failure").is_none(),
            "crash restore command failure: {}",
            value["failure"]
        );
        assert_ne!(value["session"]["instance_id"], expected["instance_id"]);
        assert_eq!(value["stale"], json!("protocol_failed"));
        assert_eq!(value["restored"]["accepted"], json!(true));
        let projects = value["projects"]["result"]["data"]["projects"]
            .as_array()
            .expect("restored projects");
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0]["project_id"], expected["project_id"]);
        let panes = value["panes"]["result"]["data"]["panes"]
            .as_array()
            .expect("restored panes");
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0]["pane_id"], expected["pane_id"]);
        assert!(panes[0]["current_run_id"].is_null());
        assert_eq!(value["snapshotUnchanged"], json!(true));
        assert_eq!(value["close"]["accepted"], json!(true));
    }));
    if verified.is_err() {
        eprintln!("TASK870_NATIVE_CRASH_RESTORE_FAILED report invariant");
        app.state::<NativeHarnessFailure>().0.store(true,Ordering::SeqCst);
        app.exit(1);return;
    }
    eprintln!("TASK870_NATIVE_CRASH_RESTORE_PROOF new_instance=true stale_rejected=true saved_project=true saved_pane=true unsaved_project_absent=true no_live_run=true baseline_unchanged=true close_collected=true");
    app.exit(0);
}

#[tauri::command]
fn native_public_start(
    manager: tauri::State<'_, Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>,
    inputs: tauri::State<'_, NativeInputs>,
    slot: tauri::State<'_, PublicCliSlot>,
) -> Result<(), &'static str> {
    let discovery = manager.discovery().ok_or("owner session missing")?;
    let mut guard = slot.0.lock().map_err(|_| "public client lock failed")?;
    if guard.is_some() {
        return Err("public client already open");
    }
    let mut child = Command::new(&inputs.sidecar)
        .args(["workspace", "connect"])
        .env("USERPROFILE", &inputs.home)
        .env("HOME", &inputs.home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "public CLI spawn failed")?;
    let mut input = child.stdin.take().ok_or("public CLI stdin missing")?;
    let output = BufReader::new(child.stdout.take().ok_or("public CLI stdout missing")?);
    let discovery_bytes =
        serde_json::to_vec(&discovery).map_err(|_| "discovery serialization failed")?;
    input
        .write_all(&discovery_bytes)
        .and_then(|_| input.write_all(b"\r\n"))
        .and_then(|_| input.flush())
        .map_err(|_| "public CLI discovery send failed")?;
    *guard = Some(PublicCli {
        child,
        input: Some(input),
        output,
    });
    Ok(())
}

#[tauri::command]
fn native_public_request(
    request_json: String,
    slot: tauri::State<'_, PublicCliSlot>,
) -> Result<Value, &'static str> {
    let request = winsmux_workspace::parse_request(request_json.as_bytes())
        .map_err(|_| "public request invalid")?;
    let bytes = winsmux_workspace::canonical_request(&request)
        .map_err(|_| "public request canonicalization failed")?;
    let mut guard = slot.0.lock().map_err(|_| "public client lock failed")?;
    let client = guard.as_mut().ok_or("public client absent")?;
    let input = client.input.as_mut().ok_or("public CLI stdin closed")?;
    input
        .write_all(&bytes)
        .and_then(|_| input.write_all(b"\r\n"))
        .and_then(|_| input.flush())
        .map_err(|_| "public CLI request send failed")?;
    let mut line = String::new();
    if client
        .output
        .read_line(&mut line)
        .map_err(|_| "public CLI read failed")?
        == 0
    {
        return Err("public CLI ended before response");
    }
    let response = winsmux_workspace::parse_response(&request, line.as_bytes())
        .map_err(|_| "public CLI response correlation failed")?;
    serde_json::to_value(response).map_err(|_| "public CLI response serialization failed")
}

#[tauri::command]
fn native_public_close(slot: tauri::State<'_, PublicCliSlot>) -> Result<(), &'static str> {
    let mut client = slot
        .0
        .lock()
        .map_err(|_| "public client lock failed")?
        .take()
        .ok_or("public client absent")?;
    drop(client.input.take());
    let status = client.child.wait().map_err(|_| "public CLI wait failed")?;
    if !status.success() {
        return Err("public CLI exit failed");
    }
    Ok(())
}

#[tauri::command]
fn native_install_companion(valid: bool, inputs: tauri::State<'_, NativeInputs>) {
    let mut bytes = std::fs::read(&inputs.sidecar).expect("prepared sidecar bytes");
    if !valid {
        bytes[0] ^= 1;
    }
    std::fs::write(&inputs.sibling, bytes).expect("test-owned sibling CLI bytes");
}

#[tauri::command]
fn native_isolate_provider_path(inputs:tauri::State<'_,NativeInputs>)->Result<String,&'static str>{
    // Process-local fixture only: an empty owned PATH makes both optional version
    // probes finish as NotFound, without a cancellation bypass or provider child.
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    {
        let path=inputs.home.join("empty-provider-path");
        std::fs::create_dir_all(&path).map_err(|_|"fixture path unavailable")?;
        std::env::set_var("PATH",&path);
        Ok(path.to_string_lossy().into_owned())
    }
    #[cfg(not(all(windows,debug_assertions,feature="native-e2e-faults")))]
    {let _=inputs;Err("native fixture unavailable")}
}

#[tauri::command]
fn native_install_rollback_companion(
    inputs: tauri::State<'_, NativeInputs>,
) -> Result<String, &'static str> {
    let version = Command::new(&inputs.rollback_cli)
        .arg("--version")
        .output()
        .map_err(|_| "rollback CLI version probe failed")?;
    if !version.status.success() {
        return Err("rollback CLI version probe failed");
    }
    let version = String::from_utf8(version.stdout).map_err(|_| "rollback CLI version invalid")?;
    if !version.starts_with("winsmux ") || version.trim() == "winsmux 0.36.38" {
        return Err("rollback CLI is not an older winsmux release");
    }
    let old = std::fs::read(&inputs.rollback_cli).map_err(|_| "rollback CLI unreadable")?;
    let current = std::fs::read(&inputs.sidecar).map_err(|_| "prepared CLI unreadable")?;
    if old == current {
        return Err("rollback CLI matches prepared CLI");
    }
    std::fs::write(&inputs.sibling, old).map_err(|_| "rollback CLI install failed")?;
    Ok(version.trim().to_owned())
}


#[derive(Default)]
struct UpdateFixtureSlot(Mutex<Option<UpdateFixture>>);
struct UpdateFixture {path:PathBuf,bytes:Vec<u8>,sha:String,fail_spawn:bool,events:Vec<Value>}
#[tauri::command]
fn native_prepare_update_fixture(inputs:tauri::State<'_,NativeInputs>,slot:tauri::State<'_,Arc<UpdateFixtureSlot>>)->Result<Value,String>{
    use sha2::{Digest,Sha256};
    let root=std::env::temp_dir().join("winsmux-updates");
    std::fs::create_dir_all(&root).map_err(|e|e.to_string())?;
    let path=root.join(format!("winsmux_task870_owned_{}.exe",uuid::Uuid::new_v4()));
    let bytes=std::fs::read(PathBuf::from(std::env::var_os("SystemRoot").ok_or("Windows root absent")?).join("System32/cmd.exe")).map_err(|e|e.to_string())?;
    let sha=format!("{:x}",Sha256::digest(&bytes));
    std::fs::write(&path,&bytes).map_err(|e|e.to_string())?;
    let value=json!({"installerPath":path,"expectedSha256":sha});
    std::fs::write(inputs.home.join("owned-update-fixture.json"),serde_json::to_vec(&value).unwrap()).map_err(|e|e.to_string())?;
    let mut guard=slot.0.lock().map_err(|_|"fixture lock failed")?;
    if guard.is_some(){let _=std::fs::remove_file(&path);return Err("fixture already prepared".into());}
    *guard=Some(UpdateFixture{path,bytes,sha,fail_spawn:false,events:Vec::new()});Ok(value)
}
#[tauri::command]
fn native_update_fixture_control(mode:String,slot:tauri::State<'_,Arc<UpdateFixtureSlot>>)->Result<Value,String>{
    let mut guard=slot.0.lock().map_err(|_|"fixture lock failed")?;
    let fixture=guard.as_mut().ok_or("fixture absent")?;
    match mode.as_str(){
        "mutate"=>{let mut bytes=fixture.bytes.clone();bytes[0]^=1;std::fs::write(&fixture.path,bytes).map_err(|e|e.to_string())?;}
        "restore"=>{std::fs::write(&fixture.path,&fixture.bytes).map_err(|e|e.to_string())?;fixture.fail_spawn=false;}
        "fail_spawn"=>fixture.fail_spawn=true,
        "inspect"=>{},
        _=>return Err("fixture mode invalid".into()),
    }
    Ok(json!({"path":fixture.path,"sha":fixture.sha,"events":fixture.events}))
}
#[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
fn launch_owned_update_fixture(slot:&UpdateFixtureSlot,barrier:&LifecycleBarrier,home:&std::path::Path,path:&std::path::Path,sha:&str)->Result<(),String>{
    use std::os::windows::{process::CommandExt,io::AsRawHandle};
    use windows_sys::Win32::{Foundation::FILETIME,System::Threading::GetProcessTimes};
    let app=barrier.app.lock().unwrap().clone().ok_or("fixture app absent")?;
    let manager=app.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
    let lifecycle=manager.native_lifecycle_snapshot();
    let runtime=winsmux_app_lib::native_desktop_runtime_inventory(&app);
    let mut guard=slot.0.lock().map_err(|_|"fixture lock failed")?;
    let fixture=guard.as_mut().ok_or("fixture not configured")?;
    if path!=fixture.path.canonicalize().map_err(|e|e.to_string())?||sha!=fixture.sha{return Err("fixture identity mismatch".into());}
    if manager.has_session()||manager.discovery().is_some()||lifecycle["cleanup_done"]!=true||runtime["shutdown_requested"]!=true||runtime["children"].as_array().is_some_and(|children|children.iter().any(|child|child["alive"]==true)){
        return Err("helper preceded observed owner/old-runtime collection".into());
    }
    let mut event=json!({"lifecycle":lifecycle,"runtime":runtime,"path":path,"sha":sha,"spawned":false});
    if fixture.fail_spawn{
        event["known_spawn_failure"]=json!(true);fixture.events.push(event);
        let _=std::fs::write(home.join("owned-update-launches.json"),serde_json::to_vec(&fixture.events).unwrap());
        return Err("owned harmless helper pre-spawn failure".into());
    }
    let mut child=Command::new(path).args(["/d","/c","exit 0"]).creation_flags(0x08000000).spawn().map_err(|e|e.to_string())?;
    let mut created=FILETIME::default();let mut exited=FILETIME::default();let mut kernel=FILETIME::default();let mut user=FILETIME::default();
    let time_ok=unsafe{GetProcessTimes(child.as_raw_handle() as _,&mut created,&mut exited,&mut kernel,&mut user)};
    let status=child.wait().map_err(|e|e.to_string())?;
    event["spawned"]=json!(true);event["pid"]=json!(child.id());event["creation_filetime"]=if time_ok!=0{json!(((created.dwHighDateTime as u64)<<32)|created.dwLowDateTime as u64)}else{Value::Null};
    event["exit_code"]=json!(status.code());fixture.events.push(event);
    let _=std::fs::write(home.join("owned-update-launches.json"),serde_json::to_vec(&fixture.events).unwrap());
    if time_ok==0||!status.success(){return Err("owned helper collection proof failed".into());}
    eprintln!("TASK870_NATIVE_OWNED_UPDATE_HELPER pid={} creation_filetime={} exit0=true cleanup_preceded_helper=true",child.id(),((created.dwHighDateTime as u64)<<32)|created.dwLowDateTime as u64);
    Ok(())
}
#[derive(Default)]
struct NonOwnerReport(Mutex<Option<String>>);

#[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
#[derive(Default)]
struct LifecycleBarrier {
    state: Mutex<(Vec<String>,Vec<String>)>,
    changed: std::sync::Condvar,
    app:Mutex<Option<tauri::AppHandle>>,
    response_observations:Mutex<Vec<Value>>,
    abandon_fired:AtomicBool,
}

#[tauri::command]
fn native_request_app_exit(app:tauri::AppHandle,code:i32) { app.exit(code); }

#[tauri::command]
fn native_lifecycle_state(app:tauri::AppHandle) -> Value {
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    {
        let barrier=app.state::<Arc<LifecycleBarrier>>();
        let state=barrier.state.lock().unwrap();
        let manager=app.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
        let inputs=app.state::<NativeInputs>();
        let layout=inputs.home.join("AppData/Local/winsmux/workspace/v1");
        json!({"points":state.0,"lifecycle":manager.native_lifecycle_snapshot(),"has_session":manager.has_session(),"discovery":manager.discovery(),"runtime":winsmux_app_lib::native_desktop_runtime_inventory(&app),"confirmed_bytes":std::fs::read(layout.join("confirmed.json")).ok(),"backup_bytes":std::fs::read(layout.join("backup.json")).ok(),"response_observations":barrier.response_observations.lock().unwrap().clone()})
    }
    #[cfg(not(all(windows,debug_assertions,feature="native-e2e-faults")))]
    {let _=app;Value::Null}
}

#[tauri::command]
fn native_lifecycle_release(app:tauri::AppHandle,point:String) {
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    {
        let barrier=app.state::<Arc<LifecycleBarrier>>();
        barrier.state.lock().unwrap().1.push(point);
        barrier.changed.notify_all();
    }
    #[cfg(not(all(windows,debug_assertions,feature="native-e2e-faults")))]
    {let _=(app,point);}
}

#[tauri::command]
fn native_lifecycle_report(app:tauri::AppHandle,inputs:tauri::State<'_,NativeInputs>,value:Value) {
    let _=std::fs::write(inputs.home.join("lifecycle-webview-report.json"),serde_json::to_vec(&value).unwrap());
    eprintln!("TASK870_NATIVE_LIFECYCLE_WEBVIEW scenario={} failure={} stop_frames={} probe_join_refusals={} report=lifecycle-webview-report.json",value["scenario"],value.get("failure").unwrap_or(&Value::Null),value["finishing"]["lifecycle"]["responses"].as_array().map_or(0,|frames|frames.iter().filter(|frame|frame["request"]["operation"]=="host.stop").count()),value["probeJoinRefusals"].as_array().map_or(0,Vec::len));
    if value.get("failure").is_some() {
        // Unblock owned workers before actual app cleanup on a diagnostic failure.
        let obstruction=inputs.home.join("AppData/Local/winsmux/workspace/v1/temp.json");
        if obstruction.is_dir(){let _=std::fs::remove_dir(&obstruction);}
        for point in ["Opening","Busy","Stopping","RetryStopping","ConsumerTerminal","Finishing","RetryFinishing","BeforeHelper","RetryBeforeHelper"] {native_lifecycle_release(app.clone(),point.to_owned());}
        app.exit(1);
        #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
        {
            let cleanup_app=app.clone();
            let manager=Arc::clone(app.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>().inner());
            let report_path=inputs.home.join("diagnostic-explicit-cleanup-retries.json");
            std::thread::spawn(move||{
                let mut records=Vec::new();let mut seen=std::collections::HashSet::new();
                for _ in 0..60 {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    let state=manager.native_lifecycle_snapshot();
                    if state["phase"]=="ExitReleased"{break;}
                    if state["phase"]=="Ready"&&state["pending"]==false {
                        if let Some(record)=state["responses"].as_array().and_then(|frames|frames.last()) {
                            if record["request"]["operation"]=="host.stop"&&record["response"]["accepted"]==false&&record["response"]["error"]["code"]=="operation_conflict" {
                                let id=record["request"]["operation_id"].as_str().unwrap_or("").to_owned();
                                if seen.insert(id){
                                    records.push(state.clone());
                                    let _=std::fs::write(&report_path,serde_json::to_vec(&records).unwrap());
                                    // A new explicit diagnostic intent only after the prior correlated refusal.
                                    cleanup_app.exit(1);
                                }
                            }
                        }
                    }
                }
            });
        }
    }
}

#[tauri::command]
fn native_legacy_after_main(app:tauri::AppHandle,value:Value,inputs:tauri::State<'_,NativeInputs>) {
    std::fs::write(inputs.home.join("legacy-after-main.json"),serde_json::to_vec(&value).unwrap()).expect("test capture");
    let valid=app.get_webview_window("main").is_none() && app.get_webview_window("secondary").is_some() && value["output"].as_str().is_some_and(|s| s.contains("task870-after-main-live"));
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    {
        let inventory=winsmux_app_lib::native_desktop_runtime_inventory(&app);
        std::fs::write(inputs.home.join("legacy-inventory-after-main.json"),serde_json::to_vec(&inventory).unwrap()).expect("retained inventory");
    }
    if valid {eprintln!("TASK870_NATIVE_SECONDARY_LEGACY_PROOF main_destroyed=true secondary_retained=true actual_pty_io_after_destroy=true");}
    else {eprintln!("TASK870_NATIVE_SECONDARY_LEGACY_FAILED marker_missing=true actual_app_cleanup_follows=true");}
    app.exit(if valid {0}else{1});
}

#[tauri::command]
fn native_legacy_start_report(app:tauri::AppHandle,inputs:tauri::State<'_,NativeInputs>) -> Result<Value,String> {
        use windows_sys::Win32::{Foundation::{CloseHandle,FILETIME},System::Threading::{OpenProcess,GetProcessTimes,PROCESS_QUERY_LIMITED_INFORMATION}};
        fn creation(pid:u32)->Result<u64,String> {
            unsafe {let handle=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid);if handle.is_null(){return Err("owned process query failed".into());}let mut created=FILETIME::default();let mut exit=FILETIME::default();let mut kernel=FILETIME::default();let mut user=FILETIME::default();let ok=GetProcessTimes(handle,&mut created,&mut exit,&mut kernel,&mut user);CloseHandle(handle);if ok==0{return Err("owned process creation-time query failed".into());}Ok(((created.dwHighDateTime as u64)<<32)|created.dwLowDateTime as u64)}
        }
        #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
        let mut inventory=winsmux_app_lib::native_desktop_runtime_inventory(&app);
        #[cfg(not(all(windows,debug_assertions,feature="native-e2e-faults")))]
        let mut inventory=json!({"children":[],"runtime_inventory_available":false});
        inventory["native_pid"]=json!(std::process::id());
        inventory["native_creation_filetime"]=json!(creation(std::process::id())?);
        for child in inventory["children"].as_array_mut().expect("owned PTYs") {
            let pid=child["pid"].as_u64().expect("owned shell PID") as u32;
            child["creation_filetime"]=json!(creation(pid)?);
        }
        std::fs::write(inputs.home.join("legacy-start-inventory.json"),serde_json::to_vec(&inventory).unwrap()).expect("owned PID metadata");
        eprintln!("TASK870_NATIVE_LEGACY_START pid={} children={}",std::process::id(),inventory["children"].as_array().unwrap().len());
        Ok(inventory)
}

#[tauri::command]
fn native_nonowner_report(app:tauri::AppHandle,outcome: String, report: tauri::State<'_, NonOwnerReport>) {
    if outcome.starts_with("close-only-error:") {
        eprintln!("TASK870_NATIVE_NORMAL_CLOSE_FAILED {outcome}");
        app.exit(1);
        return;
    }
    let input_report = serde_json::from_str::<Vec<String>>(&outcome).is_ok_and(|values|values.len()==3);
    *report.0.lock().expect("nonowner report lock") = Some(outcome);
    if input_report { let _=app.emit_to("main","task872-secondary-input-report",()); }
}

#[tauri::command]
fn native_nonowner_status(report: tauri::State<'_, NonOwnerReport>) -> Option<String> {
    report.0.lock().expect("nonowner status lock").clone()
}

#[tauri::command]
fn native_request_window_close(window: tauri::WebviewWindow) -> Result<(), &'static str> {
    eprintln!("TASK870_NATIVE_CLOSE_DISPATCH");
    window.close().map_err(|_| "window close dispatch failed")
}

#[tauri::command]
fn native_window_title(window: tauri::WebviewWindow) -> Result<String, &'static str> {
    window.title().map_err(|_| "window title read failed")
}

#[tauri::command]
fn native_reset_window_title(window: tauri::WebviewWindow) -> Result<(), &'static str> {
    window
        .set_title("winsmux task870 native")
        .map_err(|_| "window title reset failed")
}

#[tauri::command]
fn native_record_owned_host(app:tauri::AppHandle,inputs:tauri::State<'_,NativeInputs>)->Result<Value,&'static str>{
    use windows_sys::Win32::{Foundation::{CloseHandle,FILETIME,INVALID_HANDLE_VALUE},Storage::FileSystem::{CreateFileW,OPEN_EXISTING},System::{Pipes::GetNamedPipeServerProcessId,Threading::{OpenProcess,GetProcessTimes,QueryFullProcessImageNameW,PROCESS_QUERY_LIMITED_INFORMATION}}};
    let manager=app.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
    let discovery=manager.discovery().ok_or("owned session missing")?;
    let name:Vec<u16>=discovery.pipe_name().encode_utf16().chain(Some(0)).collect();
    let pipe=unsafe{CreateFileW(name.as_ptr(),0,0,std::ptr::null(),OPEN_EXISTING,0,std::ptr::null_mut())};
    if pipe==INVALID_HANDLE_VALUE{return Err("owned pipe identity unavailable");}
    let mut pid=0;let ok=unsafe{GetNamedPipeServerProcessId(pipe,&mut pid)};unsafe{CloseHandle(pipe);}
    if ok==0||pid==0||pid==std::process::id(){return Err("owned pipe server identity invalid");}
    let process=unsafe{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid)};
    if process.is_null(){return Err("owned host identity query denied");}
    let result=(||{
        let mut image=[0u16;32768];let mut len=image.len() as u32;
        if unsafe{QueryFullProcessImageNameW(process,0,image.as_mut_ptr(),&mut len)}==0{return Err("owned host image unavailable");}
        let actual=std::fs::canonicalize(PathBuf::from(String::from_utf16_lossy(&image[..len as usize]))).map_err(|_|"owned host image invalid")?;
        let expected=std::fs::canonicalize(&inputs.sibling).map_err(|_|"owned sibling missing")?;
        if !actual.to_string_lossy().eq_ignore_ascii_case(&expected.to_string_lossy()){return Err("owned host image mismatch");}
        let mut created=FILETIME::default();let mut exit=FILETIME::default();let mut kernel=FILETIME::default();let mut user=FILETIME::default();
        if unsafe{GetProcessTimes(process,&mut created,&mut exit,&mut kernel,&mut user)}==0{return Err("owned host creation time unavailable");}
        let record=json!({"pid":pid,"creation_filetime":((created.dwHighDateTime as u64)<<32)|created.dwLowDateTime as u64,"native_parent_pid":std::process::id(),"image":actual,"instance_id":discovery.instance_id()});
        std::fs::write(inputs.home.join("owned-host-identity.json"),serde_json::to_vec(&record).unwrap()).map_err(|_|"owned host identity record failed")?;
        Ok(record)
    })();
    unsafe{CloseHandle(process);}result
}

#[tauri::command]
fn native_terminate_owned_host(
    manager: tauri::State<'_, Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>,
    inputs: tauri::State<'_, NativeInputs>,
) -> Result<u32, &'static str> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, OPEN_EXISTING};
    use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, TerminateProcess,
        WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
        PROCESS_TERMINATE,
    };

    let discovery = manager.discovery().ok_or("owner session missing")?;
    let name: Vec<u16> = discovery
        .pipe_name()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let pipe = unsafe {
        CreateFileW(
            name.as_ptr(),
            0,
            0,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    };
    if pipe == INVALID_HANDLE_VALUE {
        return Err("owned public pipe open failed");
    }
    let mut pid = 0;
    let queried = unsafe { GetNamedPipeServerProcessId(pipe, &mut pid) };
    unsafe {
        CloseHandle(pipe);
    }
    if queried == 0 || pid == 0 || pid == unsafe { GetCurrentProcessId() } {
        return Err("owned public pipe server identity failed");
    }
    let process = unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | PROCESS_SYNCHRONIZE,
            0,
            pid,
        )
    };
    if process.is_null() {
        return Err("owned host process open failed");
    }
    let mut image = [0u16; 32768];
    let mut image_len = image.len() as u32;
    let queried =
        unsafe { QueryFullProcessImageNameW(process, 0, image.as_mut_ptr(), &mut image_len) };
    if queried == 0 {
        unsafe {
            CloseHandle(process);
        }
        return Err("owned host image query failed");
    }
    let actual = PathBuf::from(String::from_utf16_lossy(&image[..image_len as usize]));
    let expected = std::fs::canonicalize(&inputs.sibling).map_err(|_| "owned CLI path missing")?;
    let actual = std::fs::canonicalize(actual).map_err(|_| "owned host image unreadable")?;
    if !actual
        .to_string_lossy()
        .eq_ignore_ascii_case(&expected.to_string_lossy())
    {
        unsafe {
            CloseHandle(process);
        }
        return Err("public pipe server is not this test's companion");
    }
    let stopped = unsafe { TerminateProcess(process, 87) };
    if stopped != 0 {
        unsafe {
            WaitForSingleObject(process, 30_000);
        }
    }
    unsafe {
        CloseHandle(process);
    }
    if stopped == 0 {
        return Err("owned host termination failed");
    }
    Ok(pid)
}

#[tauri::command]
fn native_report(app: tauri::AppHandle, value: Value, inputs: tauri::State<'_, NativeInputs>) -> bool {
    std::fs::write(
        inputs.home.join("native-report.json"),
        serde_json::to_vec_pretty(&value).expect("native report JSON"),
    )
    .expect("native report record");
    if let Err(reason) = validate_report(&value, &inputs) {
        eprintln!("TASK870_NATIVE_WEBVIEW2_FAILED {reason}");
        eprintln!(
            "TASK870_NATIVE_CODES failure={} close={} active_close={}",
            value["failure"],
            value["close"]["error"]["code"],
            value["activeClose"]["error"]["code"]
        );
        app.state::<NativeHarnessFailure>().0.store(true,Ordering::SeqCst);
        app.exit(1);return false;
    }
    eprintln!("TASK870_NATIVE_WEBVIEW2_PROOF instance={} project={} pane={} topology={} close={} reopen={} restored={} nonowner={} missing={} mismatch={} stale={} scope={} overgrant={} denied_read={} malformed={} oversize={}",
        value["session"]["instance_id"], value["opened"]["result"]["data"]["project_id"],
        value["created"]["result"]["data"]["pane_id"], value["created"]["topology_revision"],
        value["close"]["accepted"], value["reopened"]["instance_id"], value["restored"]["accepted"],
        value["nonOwner"], value["missingCompanion"], value["mismatchedCompanion"],
        value["stale"], value["alteredScope"], value["overgrant"]["error"]["code"],
        value["deniedRead"]["error"]["code"], value["malformed"], value["oversize"]);
    // The real journey ends in Unknown. Only its explicit owned force consent
    // may collect the host; a plain app.exit must remain refused.
    true
}

fn validate_report(report: &Value, inputs: &NativeInputs) -> Result<(), &'static str> {
    if report.get("failure").is_some() {
        return Err("command failed");
    }
    if report["capabilities"]["accepted"] != json!(true) {
        return Err("capabilities rejected");
    }
    if report["capabilities"]["instance_id"] != report["session"]["instance_id"] {
        return Err("instance correlation failed");
    }
    if report["malformed"] != json!("protocol_failed") {
        return Err("malformed request admitted");
    }
    if report["oversize"] != json!("protocol_failed") {
        return Err("oversize request admitted");
    }
    if report["nonOwner"] != json!("wrong_window") {
        return Err("secondary WebView admitted");
    }
    if report["missingCompanion"] != json!("companion_unavailable") {
        return Err("missing companion admitted");
    }
    if report["mismatchedCompanion"] != json!("companion_mismatch") {
        return Err("mismatched companion admitted");
    }
    if !report["rollbackVersion"]
        .as_str()
        .is_some_and(|version| version.starts_with("winsmux "))
        || report["wrongVersionCompanion"] != json!("companion_mismatch")
        || report["postSessionRollback"] != json!("companion_mismatch")
    {
        return Err("older CLI rollback pair admitted");
    }
    if report["stale"] != json!("protocol_failed") {
        return Err("stale instance admitted");
    }
    if report["alteredScope"] != json!("protocol_failed") {
        return Err("altered scope admitted");
    }
    if report["baseline"]["result"]["data"]["projects"] != json!([]) {
        return Err("nonempty baseline");
    }
    if report["opened"]["accepted"] != json!(true) {
        return Err("project.open rejected");
    }
    if report["created"]["accepted"] != json!(true) {
        return Err("pane.create rejected");
    }
    if report["panes"]["result"]["data"]["panes"][0]["pane_id"]
        != report["created"]["result"]["data"]["pane_id"]
    {
        return Err("pane.list mismatch");
    }
    if report["pending"]["accepted"] != json!(true) {
        return Err("public request rejected");
    }
    if report["overgrant"]["accepted"] != json!(false)
        || report["overgrant"]["error"]["code"] != json!("invalid_request")
    {
        return Err("owner overgrant admitted");
    }
    if report["pendingAfter"]["event_seq"] != report["pendingBefore"]["event_seq"]
        || report["pendingAfter"]["topology_revision"]
            != report["pendingBefore"]["topology_revision"]
        || report["pendingAfter"]["result"] != report["pendingBefore"]["result"]
    {
        return Err("overgrant changed pending state");
    }
    if report["metadataGrant"]["accepted"] != json!(true) {
        return Err("metadata grant rejected");
    }
    if report["deniedRead"]["accepted"] != json!(false)
        || report["deniedRead"]["error"]["code"] != json!("permission_denied")
    {
        return Err("public output read admitted without scope");
    }
    if report["grantAfterDeniedRead"]["event_seq"] != report["metadataGrant"]["event_seq"] {
        return Err("denied read changed grant event sequence");
    }
    if report["activeClose"]["accepted"] != json!(false) {
        return Err("active close accepted");
    }
    if report["normalCloseRefusal"] != json!("winsmux — workspace close refused: runtime_failed")
        || report["normalCloseRetryRefusal"] != report["normalCloseRefusal"]
    {
        return Err("normal close did not retain the window and reset its retry latch");
    }
    if report["afterRefusal"]["result"]["data"]["projects"][0]["project_id"]
        != report["opened"]["result"]["data"]["project_id"]
    {
        return Err("refusal changed project state");
    }
    if report["interrupted"]["accepted"] != json!(true) {
        return Err("run interrupt rejected");
    }
    if report["runAfterInterrupt"]["result"]["data"]["run"]["process"] != json!("exited") {
        return Err("run not exited");
    }
    if report["close"]["accepted"] != json!(true) {
        return Err("close refused");
    }
    if report["closedRequest"] != json!("session_closed") {
        return Err("closed session accepted a request");
    }
    if report["reopened"]["instance_id"] == report["session"]["instance_id"] {
        return Err("reopen reused instance");
    }
    if report["staleAfterRestart"] != json!("protocol_failed") {
        return Err("old instance admitted after reopen");
    }
    if report["restored"]["accepted"] != json!(true) {
        return Err("layout restore rejected");
    }
    if report["restoredProjects"]["result"]["data"]["projects"][0]["project_id"]
        != report["opened"]["result"]["data"]["project_id"]
    {
        return Err("restored project mismatch");
    }
    if report["restoredPanes"]["result"]["data"]["panes"][0]["pane_id"]
        != report["created"]["result"]["data"]["pane_id"]
    {
        return Err("restored pane mismatch");
    }
    if report["finalClose"]["accepted"] != json!(true) {
        return Err("reopened host close refused");
    }
    if report["unrelatedBeforeClose"] != json!(true)
        || report["unrelatedAfterClose"] != json!(true)
        || report["unrelatedAfterUnknown"] != json!(true)
    {
        return Err("unrelated CLI was stopped by workspace owner lifecycle");
    }
    if report["saveFailureRestore"]["accepted"] != json!(true)
        || report["saveFailure"]["accepted"] != json!(false)
        || report["saveFailure"]["error"]["code"] != json!("persistence_failed")
        || report["snapshotUnchanged"] != json!(true)
        || report["afterSaveFailure"]["accepted"] != json!(true)
        || report["saveRecoveryClose"]["accepted"] != json!(true)
    {
        return Err("save refusal damaged owner, snapshot, or retry");
    }
    if report["unknownSession"]["instance_id"] == report["reopened"]["instance_id"]
        || !report["terminatedHostPid"]
            .as_u64()
            .is_some_and(|pid| pid > 0)
        || report["unknownCloseTitle"] != json!("winsmux — workspace close uncertain")
        || report["unknownRepeatedCloseTitle"] != report["unknownCloseTitle"]
        || report["unknownOpen"] != json!("transport_uncertain")
    {
        return Err("uncertain stop did not retain the window and terminal unknown state");
    }
    let confirmed = inputs
        .home
        .join("AppData/Local/winsmux/workspace/v1/confirmed.json");
    if !confirmed.is_file() {
        return Err("durable snapshot missing");
    }
    let snapshot_bytes = std::fs::read(&confirmed).map_err(|_| "durable snapshot unreadable")?;
    winsmux_workspace::parse_snapshot(&snapshot_bytes).map_err(|_| "durable snapshot invalid")?;
    let snapshot: Value =
        serde_json::from_slice(&snapshot_bytes).map_err(|_| "durable snapshot JSON invalid")?;
    if snapshot["projects"][0]["project_id"] != report["opened"]["result"]["data"]["project_id"] {
        return Err("durable project mismatch");
    }
    if snapshot["panes"][0]["pane_id"] != report["created"]["result"]["data"]["pane_id"] {
        return Err("durable pane mismatch");
    }
    if std::fs::read(inputs.project.join("marker.txt"))
        .ok()
        .as_deref()
        != Some(b"task870 project".as_slice())
    {
        return Err("project target changed");
    }
    Ok(())
}

#[tauri::command]
fn native_input_guard_report(inputs:tauri::State<'_ ,NativeInputs>,failure:tauri::State<'_ ,NativeHarnessFailure>,value:Value) {
    std::fs::write(inputs.home.join("input-guard-webview-report.json"),serde_json::to_vec(&value).unwrap()).expect("input guard native report");
    let valid=value.get("failure").is_none() && value["checks"].as_array().is_some_and(|checks|!checks.is_empty()&&checks.iter().all(|row|row["passed"]==true));
    if !valid {failure.0.store(true,Ordering::SeqCst);}
    eprintln!("TASK872_NATIVE_INPUT_GUARD_REPORT passed={valid} checks={} failure={}",value["checks"].as_array().map_or(0,Vec::len),value["failure"]);
}

fn main() {
    let close_only = std::env::var_os("TASK870_NATIVE_CLOSE_ONLY").is_some();
    let native_args:Vec<String>=std::env::args().collect();
    let input_arguments=native_args.get(1).is_some_and(|value|value=="--input-guard");
    if input_arguments {assert_eq!(native_args.len(),4,"input guard fixture requires isolated home and rollback CLI");}
    let scenario = if input_arguments {"input-guard".to_owned()} else {std::env::var("TASK870_NATIVE_SCENARIO").unwrap_or_default()};
    let input_guard_scenario=scenario=="input-guard";
    let lifecycle_scenario=scenario.starts_with("lifecycle-");
    let natural_last_window=scenario=="lifecycle-natural-last";
    let silent_close = scenario == "stop-reply-silent-close";
    let fault_scenario = silent_close
        || scenario == "lifecycle-shared-direct-loss"
        || scenario == "stop-reply-loss"
        || scenario == "stop-reply-abandon"
        || scenario == "stop-reply-parent-exit";
    let force_exit_scenario = scenario == "force-exit" || fault_scenario;
    if scenario == "sidecar-absent" {
        std::env::set_var("WINSMUX_TASK867_FAIL_SIDECAR_CREATE", "1");
    }
    if scenario == "sidecar-badproof" {
        std::env::set_var("WINSMUX_TASK867_FAIL_SIDECAR_PROOF", "1");
    }
    eprintln!(
        "TASK870_NATIVE_WEBVIEW2_VERSION {}",
        tauri::webview_version().expect("WebView2 runtime version")
    );
    let rollback_cli = if input_arguments {Some(std::ffi::OsString::from(&native_args[3]))} else {std::env::var_os("TASK870_ROLLBACK_CLI")}
        .map(PathBuf::from)
        .expect("actual older winsmux CLI path for native version-pair proof");
    let home = if input_arguments {Some(std::ffi::OsString::from(&native_args[2]))} else {std::env::var_os("TASK870_NATIVE_HOME")}
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::temp_dir().join(format!(
                "winsmux-task870-native-home-{}",
                std::process::id()
            ))
        });
    std::fs::create_dir_all(home.join("AppData/Local")).expect("isolated Windows LocalAppData");
    let project = home.join("project");
    std::fs::create_dir_all(&project).expect("test project root");
    std::fs::write(project.join("marker.txt"), b"task870 project").expect("test project marker");
    let unsaved_project = home.join("unsaved-project");
    std::fs::create_dir_all(&unsaved_project).expect("unsaved test project root");
    std::env::set_var("USERPROFILE", &home);
    std::env::set_var("HOME", &home);

    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let bundled_sidecar = manifest.join(format!(
        "binaries/winsmux-{}.exe",
        env!("TAURI_ENV_TARGET_TRIPLE")
    ));
    let (sidecar, fault_companion_sha256) = if fault_scenario {
        let path = PathBuf::from(std::env::var_os("TASK876_NATIVE_FAULT_COMPANION")
            .expect("fault fixture requires a feature-matched isolated companion"));
        let expected = std::env::var("TASK876_NATIVE_FAULT_COMPANION_SHA256")
            .expect("fault fixture requires the isolated companion digest");
        let bytes = std::fs::read(&path).expect("read feature-matched isolated companion");
        let actual = format!("{:x}", Sha256::digest(&bytes));
        assert_eq!(actual, expected, "fault companion identity changed");
        assert!(bytes.windows(b"__task870-host-stop-reply-loss".len())
            .any(|window| window == b"__task870-host-stop-reply-loss"), "fault companion lacks the matching child feature");
        eprintln!("TASK876_NATIVE_FAULT_COMPANION sha256={actual} matched_feature=true");
        (path, Some(actual))
    } else { (bundled_sidecar, None) };
    let test_exe = std::env::current_exe().expect("native test binary");
    let sibling = test_exe
        .parent()
        .expect("test binary directory")
        .join("winsmux.exe");
    if sibling.is_file() {
        std::fs::remove_file(&sibling).expect("remove prior test-owned sibling");
    }

    let project_literal =
        serde_json::to_string(&project.to_string_lossy()).expect("project path JSON");
    let unsaved_project_literal = serde_json::to_string(&unsaved_project.to_string_lossy())
        .expect("unsaved project path JSON");
    let crash_expected_literal = if scenario == "crash-restore" {
        std::fs::read_to_string(home.join("crash-expected.json"))
            .expect("crash restore expected record")
    } else {
        "null".to_owned()
    };
    let manager = Arc::new(winsmux_app_lib::workspace_transport::WorkspaceManager::default());
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    let gate =
        Arc::new(winsmux_workspace::host::StopReplyLossGate::new().expect("native fault gate"));
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    let manager = if fault_scenario {
        Arc::new(
            winsmux_app_lib::workspace_transport::WorkspaceManager::for_stop_reply_loss(gate.clone())
                .with_native_companion_sha256(fault_companion_sha256.as_ref().expect("fault companion digest").clone()),
        )
    } else {
        manager
    };
    #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
    assert!(
        !fault_scenario,
        "fault scenario requires debug feature pair"
    );
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    let lifecycle_barrier=Arc::new(LifecycleBarrier::default());
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    let manager=if input_guard_scenario {
        // Capture real stop responses without the barriers used by fault cases.
        Arc::new(winsmux_app_lib::workspace_transport::WorkspaceManager::for_native_lifecycle(Arc::new(|_| {}),None))
    }else if lifecycle_scenario {
        let barrier=lifecycle_barrier.clone();let selected=scenario.clone();let proof_home=home.clone();
        let native_manager=winsmux_app_lib::workspace_transport::WorkspaceManager::for_native_lifecycle(Arc::new(move|point| {
            let mut point=format!("{point:?}");
            let shared_refusal=selected.starts_with("lifecycle-shared-");
            if shared_refusal&&point=="Stopping"&&barrier.state.lock().unwrap().0.iter().any(|prior|prior=="Stopping"){
                point="RetryStopping".to_owned();
            }
            if selected.starts_with("lifecycle-update-")&&matches!(point.as_str(),"Finishing"|"BeforeHelper")&&barrier.state.lock().unwrap().0.iter().any(|prior|prior==&point){
                point=format!("Retry{point}");
            }
            if point=="Response" {
                if let Some(app)=barrier.app.lock().unwrap().clone() {
                    let manager=app.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
                    let lifecycle=manager.native_lifecycle_snapshot();
                    let layout=proof_home.join("AppData/Local/winsmux/workspace/v1");
                    let record=json!({"record":lifecycle["responses"].as_array().and_then(|frames|frames.last()),"lifecycle":lifecycle,"runtime":winsmux_app_lib::native_desktop_runtime_inventory(&app),"confirmed_bytes":std::fs::read(layout.join("confirmed.json")).ok(),"backup_bytes":std::fs::read(layout.join("backup.json")).ok()});
                    let mut observations=barrier.response_observations.lock().unwrap();observations.push(record);
                    let _=std::fs::write(proof_home.join("response-observations.json"),serde_json::to_vec(&*observations).unwrap());
                }
            }
            if selected=="lifecycle-worker-abandon"&&point=="ConsumerTerminal"&&!barrier.abandon_fired.swap(true,Ordering::SeqCst) {
                // This test-owned blocking observer aborts only the original completion future.
                // The production guard must disarm its effects after actual owned collection.
                panic!("TASK870_EXPECTED_COMPLETION_OBSERVER_ABANDON");
            }
            let held=point=="Finishing" || (selected=="lifecycle-opening" && point=="Opening") || (selected=="lifecycle-busy" && point=="Busy") || (matches!(selected.as_str(),"lifecycle-stopping"|"lifecycle-finishing") && point=="Stopping")
                || (shared_refusal&&matches!(point.as_str(),"Stopping"|"RetryStopping"|"ConsumerTerminal"))
                || (selected.starts_with("lifecycle-update-")&&matches!(point.as_str(),"BeforeHelper"|"RetryFinishing"|"RetryBeforeHelper"))
                || (selected=="lifecycle-shared-direct-update"&&point=="BeforeHelper");
            let mut state=barrier.state.lock().unwrap();state.0.push(point.clone());
            eprintln!("TASK870_NATIVE_LIFECYCLE_POINT {point}");
            while held && !state.1.contains(&point) {state=barrier.changed.wait(state).unwrap();}
        }),if fault_scenario {Some(gate.clone())}else{None});
        Arc::new(match fault_companion_sha256.as_ref() {
            Some(digest)=>native_manager.with_native_companion_sha256(digest.clone()),
            None=>native_manager,
        })
    }else{manager};
    let observer_failed=Arc::new(AtomicBool::new(false));
    let builder = winsmux_app_lib::with_desktop_webview_policy(winsmux_app_lib::with_desktop_runtime_state(tauri::Builder::default()))
        .expect("closed native webview policy").manage(NativeHarnessFailure(observer_failed.clone()));
    let update_fixture=Arc::new(UpdateFixtureSlot::default());
    let builder=builder.manage(update_fixture.clone());
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    let builder = {
        let cleanup_home=home.clone();
        let update_home=home.clone();let update_slot=update_fixture.clone();let update_barrier=lifecycle_barrier.clone();
        builder.manage(winsmux_app_lib::NativeDesktopEffects {
            update_launcher:Arc::new(move|path,sha|launch_owned_update_fixture(&update_slot,&update_barrier,&update_home,path,sha)),
            cleanup_observer:Arc::new(move|report| {std::fs::write(cleanup_home.join("actual-cleanup-report.json"),serde_json::to_vec(&report).unwrap()).expect("actual cleanup report");eprintln!("TASK870_NATIVE_ACTUAL_CLEANUP pty_count={} pty_exited_count={}",report["pty_count"],report["pty_exited_count"]);}),
        })
    };
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    let builder = builder.manage(NativeFaultGate(gate));
    #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
    let builder=builder.manage(lifecycle_barrier);
    let mut context = tauri::generate_context!();
    if input_guard_scenario { context.set_assets(Box::new(InputGuardFixtureAssets)); }
    let app = builder
        .plugin(tauri_plugin_dialog::init())
        .manage(manager)
        .manage(NativeInputs { home, project, sidecar, sibling, rollback_cli })
        .manage(NonOwnerReport::default())
        .manage(PublicCliSlot::default())
        .manage(UnrelatedCliSlot::default())
        .manage(SnapshotBaseline::default())
        .manage(ForceExitProof::default())
        .manage(FaultProof::default())
        .manage(IndependentHostSlot::default())
        .invoke_handler(tauri::generate_handler![
            winsmux_app_lib::workspace_transport::workspace_session_open,
            winsmux_app_lib::workspace_transport::workspace_request,
            winsmux_app_lib::workspace_transport::workspace_discovery_get,
            winsmux_app_lib::workspace_transport::workspace_host_status,
            winsmux_app_lib::workspace_transport::workspace_session_close,
            winsmux_app_lib::workspace_transport::workspace_force_exit,
            winsmux_app_lib::workspace_input_guard::workspace_input_guard_register,
            winsmux_app_lib::workspace_input_guard::workspace_input_guard_status,
            winsmux_app_lib::workspace_input_guard::workspace_input_guard_reply,
            native_input_guard_report,
            winsmux_app_lib::desktop_lifecycle_commands::desktop_update_launch_installer,
            winsmux_app_lib::desktop_lifecycle_commands::pty_spawn,
            winsmux_app_lib::desktop_lifecycle_commands::pty_write,
            winsmux_app_lib::desktop_lifecycle_commands::pty_capture,
            native_legacy_after_main,
            native_legacy_start_report,
            native_request_app_exit,
            native_lifecycle_state,
            native_lifecycle_release,
            native_lifecycle_report,
            native_report,
            native_force_tail_phase,
            native_nonowner_report,
            native_nonowner_status,
            native_request_window_close,
            native_window_title,
            native_reset_window_title,
            native_terminate_owned_host,
            native_record_owned_host,
            native_install_companion,
            native_isolate_provider_path,
            native_prepare_update_fixture,
            native_update_fixture_control,
            native_install_rollback_companion,
            native_public_start,
            native_public_request,
            native_public_close,
            native_unrelated_cli_start,
            native_unrelated_cli_alive,
            native_unrelated_cli_close,
            native_block_snapshot_temp,
            native_snapshot_unchanged,
            native_crash_kill,
            native_crash_snapshot_unchanged,
            native_crash_report,
            native_record_snapshot_baseline,
            native_force_cancel_proof,
            native_choose_force_dialog,
            native_capture_unknown,
            native_gate_ready,
            native_gate_validate_release,
            native_fault_unknown_proof,
            native_gate_parent_exit,
            native_sidecar_report,
            native_independent_host_start,
            native_independent_host_request,
            native_independent_host_report,
        ])
        .on_page_load(move |webview, payload| {
            eprintln!("TASK870_NATIVE_PAGE_LOAD {:?} {}", payload.event(), webview.label());
            if payload.event() == tauri::webview::PageLoadEvent::Finished && webview.label() == "secondary" {
                if input_guard_scenario {
                    let script=r#"(async()=>{const invoke=window.__TAURI_INTERNALS__.invoke;const result=[];for(const [command,body] of [["workspace_input_guard_register",{binding:"87200000-0000-4000-8000-000000000003"}],["workspace_input_guard_status",{lease:"1"}],["workspace_input_guard_reply",{lease:"1",nonce:"1",safe:true}],["workspace_discovery_get",{}],["workspace_host_status",{}]]){let value="unexpected_success";try{await invoke(command,{requestJson:JSON.stringify(body)});}catch(error){value=String(error);}result.push(value);}await invoke("native_nonowner_report",{outcome:JSON.stringify(result)});})();"#;
                    webview.eval(script).expect("secondary actual input authorization");
                    return;
                }
                let script = r#"(async () => {
                    let outcome = 'unexpected_success';
                    try { await window.__TAURI_INTERNALS__.invoke('workspace_session_open'); }
                    catch (error) { outcome = String(error); }
                    await window.__TAURI_INTERNALS__.invoke('native_nonowner_report', {outcome});
                })();"#;
                webview.eval(script).expect("probe secondary native WebView2");
                return;
            }
            if payload.event() != tauri::webview::PageLoadEvent::Finished || webview.label() != "main" { return; }
            if input_guard_scenario {
                let script=r#"(async () => {
  const invoke = window.__TAURI_INTERNALS__.invoke;
  const output = {scope:'actual WebView2 IPC and workspace host; no Windows IME or Narrator claim', checks:[], wakes:[]};
  let lease, closing = false, serial = 0;
  const check = (name, value) => { output.checks.push({name, passed:!!value}); if (!value) throw new Error(name); };
  const rejects = async (name, command, body, expected) => {
    let actual = 'unexpected_success';
    try { await invoke(command, {requestJson:body}); } catch (error) { actual=String(error); }
    check(name, actual===expected);
  };
  const command = (name, body) => invoke('workspace_input_guard_'+name,{requestJson:JSON.stringify(body)});
  const changes=[], refusals=[]; let wakeWaiter, refusalWaiter;
  const listen = async (event, callback) => invoke('plugin:event|listen',{
    event,target:{kind:'Any'},handler:window.__TAURI_INTERNALS__.transformCallback(callback)
  });
  const nextWake = () => changes.length ? Promise.resolve(changes.shift()) : new Promise(resolve=>wakeWaiter=resolve);
  const nextRefusal = () => refusals.length ? Promise.resolve(refusals.shift()) : new Promise(resolve=>refusalWaiter=resolve);
  const pending = async () => {
    for (;;) {
      const value=await command('status',{lease});
      if(value.fence?.state==='pending') return value;
      await nextWake();
    }
  };
  try {
    await listen('workspace-close-refused',event=>{if(refusalWaiter){const resolve=refusalWaiter;refusalWaiter=null;resolve(event.payload);}else refusals.push(event.payload);});
    await listen('workspace-input-guard-changed',event=>{
      output.wakes.push(event.payload);
      if(wakeWaiter){const resolve=wakeWaiter;wakeWaiter=null;resolve(event.payload);}else changes.push(event.payload);
      if(closing && lease) void command('status',{lease}).then(value=>value.fence?.state==='pending' ? command('reply',{lease,nonce:value.fence.nonce,safe:true}) : undefined);
    });
    const binding='87200000-0000-4000-8000-000000000001';
    const initial=await command('register',{binding}); output.initial=initial; lease=initial.lease;
    check('register metadata shape',Object.keys(initial).sort().join(',')==='admission_error,fence,lease,resume_allowed,revision');
    check('register canonical lease and revision',/^[1-9][0-9]*$/.test(lease)&&/^[0-9]+$/.test(initial.revision));
    check('register empty ready without a released-fence proof',initial.fence===null&&initial.resume_allowed===false&&initial.admission_error===null);
    check('same binding retains lease',(await command('register',{binding})).lease===lease);
    await rejects('replacement binding refused','workspace_input_guard_register',JSON.stringify({binding:'87200000-0000-4000-8000-000000000002'}),'input_guard_owned');
    for(const [index,body] of ['{}','[]','{"binding":1}','{"binding":"x"}',`{"binding":"${binding}","binding":"${binding}"}`,`{"binding":"${binding}","text":"x"}`,' '.repeat(1048577)].entries())
      await rejects('invalid register '+index,'workspace_input_guard_register',body,'input_guard_invalid');
    for(const [index,body] of ['{}','[]','{"lease":1}','{"lease":"0"}','{"lease":"01"}','{"lease":"18446744073709551616"}',`{"lease":"${lease}","lease":"${lease}"}`,`{"lease":"${lease}","text":"x"}`].entries())
      await rejects('invalid status '+index,'workspace_input_guard_status',body,'input_guard_invalid');
    await rejects('different lease refused','workspace_input_guard_status',JSON.stringify({lease:String(BigInt(lease)+1n)}),'input_guard_owned');
    await rejects('no fence reply refused','workspace_input_guard_reply',JSON.stringify({lease,nonce:'1',safe:true}),'input_guard_stale');
    // The secondary listener is installed before reading its stored report, avoiding a page-load race.
    let secondaryResolve; const secondaryReady=new Promise(resolve=>secondaryResolve=resolve);
    await listen('task872-secondary-input-report',()=>secondaryResolve());
    if(!await invoke('native_nonowner_status')) await secondaryReady;
    output.secondary=JSON.parse(await invoke('native_nonowner_status'));
    check('secondary denies every private command',output.secondary.length===5&&output.secondary.every(value=>value==='wrong_window'));
    await invoke('native_install_companion',{valid:true});
    const session=await invoke('workspace_session_open');
    output.readyHostStatus=await invoke('workspace_host_status');
    check('main native status matches current host without secrets',output.readyHostStatus.phase==='Ready'
      &&output.readyHostStatus.instance_id===session.instance_id
      &&/^(0|[1-9][0-9]*)$/.test(output.readyHostStatus.generation)
      &&/^(0|[1-9][0-9]*)$/.test(output.readyHostStatus.revision)
      &&Object.keys(output.readyHostStatus).sort().join(',')==='force_offer,generation,instance_id,phase,revision');
    const request=(operation,params,revision=null)=>({schema_version:1,instance_id:session.instance_id,operation_id:`87200000-0000-4000-8001-${String(++serial).padStart(12,'0')}`,expected_topology_revision:revision,operation,params});
    const exchange=req=>invoke('workspace_request',{requestJson:JSON.stringify(req)});
    const send=(operation,params,revision=null)=>exchange(request(operation,params,revision));
    output.opened=await send('project.open',{path:__PROJECT_PATH_JSON__},0);
    check('real project opened',output.opened.accepted);
    const projectId=output.opened.result.data.project_id;
    output.created=await send('pane.create',{project_id:projectId,shell_profile_id:'pwsh'},output.opened.topology_revision);
    check('real pane and run created',output.created.accepted);
    const runId=output.created.result.data.run_id, paneId=output.created.result.data.pane_id;
    output.host=await invoke('native_record_owned_host');
    await invoke('pty_spawn',{paneId:'task872-legacy',cols:80,rows:24});
    output.legacyBefore=await invoke('native_legacy_start_report');
    check('actual legacy runtime remains live before native close',output.legacyBefore.children.length===1&&output.legacyBefore.children[0].alive&&!output.legacyBefore.shutdown_requested);
    await invoke('native_request_window_close');
    const first=await pending(); output.first=first;
    output.beforeRefusal=await invoke('native_lifecycle_state');
    check('pending input blocks stop',output.beforeRefusal.has_session&&output.beforeRefusal.lifecycle.responses.filter(row=>row.request.operation==='host.stop').length===0);
    const held=request('project.list',{});
    await rejects('native prewire fence exact classification','workspace_request',JSON.stringify(held),'shutdown_in_progress');
    const released=await command('reply',{lease,nonce:first.fence.nonce,safe:false});
    check('unsafe input releases same fence',released.fence?.nonce===first.fence.nonce&&released.fence.state==='released'&&released.resume_allowed);
    check('normal window close refused for input',await nextRefusal()==='input_pending');
    const recovered=await command('status',{lease}); output.recovered=recovered;
    check('current status recovers without relying on release event',recovered.fence?.state==='released'&&recovered.resume_allowed&&BigInt(recovered.revision)>=BigInt(first.revision));
    const explicit=await exchange(held);
    check('explicit same original request accepted after prewire refusal',explicit.accepted&&explicit.operation_id===held.operation_id);
    await invoke('native_request_window_close');
    const second=await pending(); output.second=second;
    check('new destructive fence replaces released nonce',second.fence.nonce!==first.fence.nonce);
    await rejects('old reply cannot release new fence','workspace_input_guard_reply',JSON.stringify({lease,nonce:first.fence.nonce,safe:false}),'input_guard_stale');
    for(const [index,body] of [JSON.stringify({lease,nonce:second.fence.nonce,safe:'true'}),`{"lease":"${lease}","nonce":"${second.fence.nonce}","safe":true,"safe":false}`,JSON.stringify({lease,nonce:second.fence.nonce,safe:true,text:'x'}),'{}','{"lease":"1","nonce":"01","safe":true}'].entries())
      await rejects('invalid reply '+index,'workspace_input_guard_reply',body,'input_guard_invalid');
    check('rejected replies leave pending current',(await command('status',{lease})).fence?.state==='pending');
    const approved=await command('reply',{lease,nonce:second.fence.nonce,safe:true});
    check('safe input approves exact fence',approved.fence?.nonce===second.fence.nonce&&approved.fence.state==='approved'&&!approved.resume_allowed);
    output.hostCloseRefusal=await nextRefusal();
    check('real live run prevents destructive stop',['operation_conflict','runtime_failed'].includes(output.hostCloseRefusal));
    const afterHostRefusal=await command('status',{lease});
    check('host known refusal releases same fence',afterHostRefusal.fence?.nonce===second.fence.nonce&&afterHostRefusal.fence.state==='released'&&afterHostRefusal.resume_allowed);
    output.sessionOnly=await invoke('workspace_session_close');
    check('session only live stop remains refused',!output.sessionOnly.accepted&&['operation_conflict','runtime_failed'].includes(output.sessionOnly.error?.code));
    const afterSessionOnly=await command('status',{lease});
    check('session only preserves released input lease',afterSessionOnly.fence?.nonce===second.fence.nonce&&afterSessionOnly.fence.state==='released'&&afterSessionOnly.resume_allowed);
    output.interrupted=await send('run.interrupt',{run_id:runId}); check('real run interrupt accepted',output.interrupted.accepted);
    for (;;) {
      const run=await send('run.get',{run_id:runId});
      if(run.result?.data?.run?.process==='exited'){output.exited=run;break;}
      await send('events.wait',{after_event_seq:run.event_seq,wait_ms:1000});
    }
    output.closedPane=await send('pane.close',{pane_id:paneId},output.exited.topology_revision); check('exited pane close accepted',output.closedPane.accepted);
    const current=await send('project.list',{});
    output.forgotten=await send('project.forget',{project_id:projectId},current.topology_revision); check('empty project forget accepted',output.forgotten.accepted);
    output.beforeFinal=await invoke('native_lifecycle_state');
    check('real host remains before final normal close',output.beforeFinal.has_session);
    check('wake metadata contains no text',output.wakes.every(wake=>Object.keys(wake).sort().join(',')==='lease,revision'));
    await invoke('native_input_guard_report',{value:output});
    closing=true;
    const ready=document.createElement("p");ready.setAttribute("role","status");ready.textContent="TASK-872 native IPC確認済み。通常のウィンドウ終了を検証する準備ができました。";document.body.append(ready);
  } catch(error) {
    output.failure=String(error);
    await invoke('native_input_guard_report',{value:output});
    closing=true;
  }
})();"#.replace("__PROJECT_PATH_JSON__", &project_literal);
                webview.eval(&script).expect("actual input guard IPC and owned host");
                return;
            }
            if scenario=="independent-host" {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke;const output={};
                    await invoke('native_install_companion',{valid:true});const discovery=await invoke('native_independent_host_start');let id=1;
                    const send=operation=>invoke('native_independent_host_request',{requestJson:JSON.stringify({schema_version:1,instance_id:discovery.instance_id,operation_id:`87000000-0000-4000-8006-${String(id++).padStart(12,'0')}`,expected_topology_revision:null,operation,params:{}})});
                    output.before=await send('capabilities.get');
                    output.saved=await send('layout.save');if(!output.saved.accepted)throw new Error('independent baseline save refused');
                    await invoke('native_record_snapshot_baseline');
                    try{await invoke('workspace_session_open');}catch(error){output.guiError=String(error);}
                    output.after=await send('capabilities.get');
                    output.snapshotUnchanged=await invoke('native_snapshot_unchanged');
                    for(let i=0;i<60;i++){output.stop=await send('host.stop');if(output.stop.accepted)break;const code=output.stop.error?.code;if(!['operation_conflict','runtime_failed'].includes(code))throw new Error('independent stop '+code);await new Promise(r=>setTimeout(r,500));}
                    await invoke('native_independent_host_report',{value:output});
                })().catch(error=>window.__TAURI_INTERNALS__.invoke('native_nonowner_report',{outcome:'close-only-error:'+String(error)}));"#;
                webview.eval(script).expect("native independent host journey");return;
            }
            if scenario.starts_with("sidecar-") {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke;const output={scenario:__SCENARIO__};
                    await invoke('native_install_companion',{valid:true});const session=await invoke('workspace_session_open');
                    const send=(operation,params,id)=>invoke('workspace_request',{requestJson:JSON.stringify({schema_version:1,instance_id:session.instance_id,operation_id:`87000000-0000-4000-8005-${String(id).padStart(12,'0')}`,expected_topology_revision:null,operation,params})});
                    output.before=await send('project.list',{},1);
                    try{output.artifact=await send('artifact.choice.list',{project_id:'87000000-0000-4000-8005-000000000999'},2);}catch(error){output.artifactError=String(error);}
                    if(output.scenario!=='sidecar-available')output.sameIdOrdinary=await send('project.list',{},2);
                    output.after=await send('project.list',{},3);
                    for(let i=0;i<60;i++){output.close=await invoke('workspace_session_close');if(output.close.accepted)break;const code=output.close.error?.code;if(!['operation_conflict','runtime_failed'].includes(code))throw new Error('unexpected sidecar close '+code);await new Promise(r=>setTimeout(r,500));}
                    await invoke('native_sidecar_report',{value:output});
                })().catch(error=>window.__TAURI_INTERNALS__.invoke('native_nonowner_report',{outcome:'close-only-error:'+String(error)}));"#.replace("__SCENARIO__",&serde_json::to_string(&scenario).unwrap());
                webview.eval(&script).expect("native artifact admission journey");return;
            }
            if silent_close {
                let script = r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke;
                    await invoke('native_install_companion',{valid:true});
                    const session=await invoke('workspace_session_open');
                    await invoke('native_record_owned_host');
                    const opened=await invoke('workspace_request',{requestJson:JSON.stringify({schema_version:1,instance_id:session.instance_id,operation_id:'87000000-0000-4000-8004-000000000101',expected_topology_revision:0,operation:'project.open',params:{path:__PROJECT_PATH_JSON__}})});
                    if(!opened.accepted) throw new Error('silent project missing');
                    await invoke('native_unrelated_cli_start');
                    await invoke('native_request_window_close');
                    for(let i=0;i<60;i++){if(await invoke('native_gate_ready'))break;await new Promise(r=>setTimeout(r,500));}
                    if(!(await invoke('native_gate_ready'))) throw new Error('silent gate missing');
                    const status=await invoke('workspace_host_status');
                    if(status.phase!=='Stopping'||status.force_offer!=='waiting') throw new Error('waiting offer missing');
                    await invoke('native_request_window_close');
                    await invoke('native_choose_force_dialog',{confirm:false});
                    let kept;
                    for(let i=0;i<60;i++){kept=await invoke('workspace_host_status');if(kept.force_offer==='waiting')break;await new Promise(r=>setTimeout(r,100));}
                    const title=await invoke('native_window_title');
                    if(!kept||kept.phase!=='Stopping'||kept.force_offer!=='waiting'||String(title).includes('uncertain')) throw new Error('declined close changed state');
                    const exit=invoke('workspace_force_exit');
                    await invoke('native_choose_force_dialog',{confirm:true});
                    await exit;
                })().catch(error=>window.__TAURI_INTERNALS__.invoke('native_nonowner_report',{outcome:'close-only-error:'+String(error)}));"#.replace("__PROJECT_PATH_JSON__", &project_literal);
                webview.eval(&script).expect("silent close scenario");
                return;
            }
            if fault_scenario && !lifecycle_scenario {
                let script = r#"(async () => {
                    const invoke=window.__TAURI_INTERNALS__.invoke; const output={};
                    await invoke('native_install_companion',{valid:true});
                    const session=await invoke('workspace_session_open');
                    await invoke('native_record_owned_host');
                    try { await invoke('workspace_force_exit'); } catch(error) { output.healthyForce=String(error); }
                    const opened=await invoke('workspace_request',{requestJson:JSON.stringify({schema_version:1,instance_id:session.instance_id,operation_id:'87000000-0000-4000-8004-000000000001',expected_topology_revision:0,operation:'project.open',params:{path:__PROJECT_PATH_JSON__}})});
                    if(!opened.accepted) throw new Error('fault project missing');
                    await invoke('native_unrelated_cli_start');
                    await invoke('native_request_window_close'); for(let i=0;i<60;i++) { if(await invoke('native_gate_ready')) break; await new Promise(r=>setTimeout(r,500)); }
                    if(!(await invoke('native_gate_ready'))) throw new Error('fault ready missing');
                    if (__PARENT_EXIT__) { await invoke('native_gate_parent_exit'); return; }
                    let validation='success';
                    try { await invoke('native_gate_validate_release',{abandon:__ABANDON__}); } catch(error) { validation=String(error); }
                    if (__ABANDON__ && validation!=='validation_failed') throw new Error('expected validation failure missing');
                    if (!__ABANDON__ && validation!=='success') throw new Error(validation);
                    for(let i=0;i<60;i++) { if((await invoke('native_window_title')).includes('uncertain')) break; await new Promise(r=>setTimeout(r,100)); }
                    output.windowRetained=(await invoke('native_window_title')).includes('uncertain');
                    try{await invoke('workspace_session_open');}catch(error){output.unknownOpen=String(error);}
                    try{await invoke('workspace_session_close');}catch(error){output.reclose=String(error);}
                    await invoke('native_request_window_close');
                    await invoke('native_fault_unknown_proof',{value:output});
                    if (__ABANDON__) await invoke('native_record_snapshot_baseline');
                    const cancel=invoke('workspace_force_exit'); await invoke('native_choose_force_dialog',{confirm:false});
                    try{await cancel;}catch(error){output.cancelError=String(error);}
                    output.snapshotUnchanged=await invoke('native_snapshot_unchanged');
                    await invoke('native_force_cancel_proof',{value:output});
                    await invoke('native_capture_unknown');
                    const force=invoke('workspace_force_exit'); await invoke('native_choose_force_dialog',{confirm:true}); await force;
                })().catch(error=>window.__TAURI_INTERNALS__.invoke('native_nonowner_report',{outcome:'close-only-error:'+String(error)}));"#
                    .replace("__PROJECT_PATH_JSON__", &project_literal)
                    .replace("__PARENT_EXIT__", if scenario == "stop-reply-parent-exit" { "true" } else { "false" })
                    .replace("__ABANDON__", if scenario == "stop-reply-abandon" { "true" } else { "false" });
                webview.eval(&script).expect("native lost reply journey");
                return;
            }
            if scenario == "force-exit" {
                let script = r#"(async () => {
                    const invoke = window.__TAURI_INTERNALS__.invoke;
                    const output = {};
                    await invoke('native_install_companion', {valid: true});
                    const session = await invoke('workspace_session_open');
                    try { await invoke('workspace_force_exit'); }
                    catch (error) { output.healthyForce = String(error); }
                    let sequence = 1;
                    const send = (operation, params, revision = null) => invoke('workspace_request', {requestJson: JSON.stringify({
                        schema_version: 1, instance_id: session.instance_id,
                        operation_id: `87000000-0000-4000-8003-${String(sequence++).padStart(12, '0')}`,
                        expected_topology_revision: revision, operation, params
                    })});
                    const opened = await send('project.open', {path: __PROJECT_PATH_JSON__}, 0);
                    const saved = await send('layout.save', {});
                    if (!opened.accepted || !saved.accepted) throw new Error('force exit baseline unavailable');
                    await invoke('native_record_snapshot_baseline');
                    await invoke('native_unrelated_cli_start');
                    await invoke('native_terminate_owned_host');
                    try { await send('project.list', {}); }
                    catch (error) { output.unknownRequest = String(error); }
                    if (output.unknownRequest !== 'transport_uncertain') throw new Error('unknown state missing');
                    const cancel = invoke('workspace_force_exit');
                    await invoke('native_choose_force_dialog', {confirm: false});
                    try { await cancel; }
                    catch (error) { output.cancelError = String(error); }
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.unknownOpen = String(error); }
                    output.snapshotUnchanged = await invoke('native_snapshot_unchanged');
                    await invoke('native_force_cancel_proof', {value: output});
                    await invoke('native_request_window_close');
                    for (let i=0;i<30;i++) {
                        if ((await invoke('native_window_title')).includes('uncertain')) break;
                        await new Promise(resolve=>setTimeout(resolve,100));
                    }
                    await invoke('native_capture_unknown');
                    const force = invoke('workspace_force_exit');
                    await invoke('native_choose_force_dialog', {confirm: true});
                    await force;
                })().catch(error => window.__TAURI_INTERNALS__.invoke('native_nonowner_report', {outcome: 'close-only-error:' + String(error)}));"#
                    .replace("__PROJECT_PATH_JSON__", &project_literal);
                webview.eval(&script).expect("native forced exit WebView2");
                return;
            }
            if scenario == "crash-prepare" {
                let script = r#"(async () => {
                    const invoke = window.__TAURI_INTERNALS__.invoke;
                    await invoke('native_install_companion', {valid: true});
                    const session = await invoke('workspace_session_open');
                    let sequence = 1;
                    const send = (operation, params, expected_topology_revision = null) => invoke('workspace_request', {requestJson: JSON.stringify({
                        schema_version: 1, instance_id: session.instance_id,
                        operation_id: `87000000-0000-4000-8001-${String(sequence++).padStart(12, '0')}`,
                        expected_topology_revision, operation, params
                    })});
                    const opened = await send('project.open', {path: __PROJECT_PATH_JSON__}, 0);
                    const projectId = opened.result.data.project_id;
                    const created = await send('pane.create', {project_id: projectId, shell_profile_id: 'pwsh'}, opened.topology_revision);
                    const saved = await send('layout.save', {});
                    if (!saved.accepted) throw new Error('precrash save rejected');
                    const unsaved = await send('project.open', {path: __UNSAVED_PROJECT_PATH_JSON__}, created.topology_revision);
                    await invoke('native_crash_kill', {value: {
                        instance_id: session.instance_id, project_id: projectId,
                        pane_id: created.result.data.pane_id, unsaved_project_accepted: unsaved.accepted
                    }});
                })().catch(error => window.__TAURI_INTERNALS__.invoke('native_nonowner_report', {outcome: 'close-only-error:' + String(error)}));"#
                    .replace("__PROJECT_PATH_JSON__", &project_literal)
                    .replace("__UNSAVED_PROJECT_PATH_JSON__", &unsaved_project_literal);
                webview.eval(&script).expect("native crash preparation WebView2");
                return;
            }
            if scenario == "crash-restore" {
                let script = r#"(async () => {
                    const invoke = window.__TAURI_INTERNALS__.invoke;
                    const output = {};
                    const expected = __CRASH_EXPECTED_JSON__;
                    try {
                        await invoke('native_install_companion', {valid: true});
                        output.session = await invoke('workspace_session_open');
                        let sequence = 1;
                        const send = (operation, params, revision = null, instance_id = output.session.instance_id) => invoke('workspace_request', {requestJson: JSON.stringify({
                            schema_version: 1, instance_id,
                            operation_id: `87000000-0000-4000-8002-${String(sequence++).padStart(12, '0')}`,
                            expected_topology_revision: revision, operation, params
                        })});
                        try { await send('project.list', {}, null, expected.instance_id); }
                        catch (error) { output.stale = String(error); }
                        output.restored = await send('layout.restore', {}, 0);
                        output.projects = await send('project.list', {});
                        output.panes = await send('pane.list', {project_id: expected.project_id});
                        output.snapshotUnchanged = await invoke('native_crash_snapshot_unchanged');
                        for (let attempt = 0; attempt < 60; attempt++) {
                            output.close = await invoke('workspace_session_close');
                            if (output.close.accepted || !['operation_conflict', 'runtime_failed'].includes(output.close.error?.code)) break;
                            await new Promise(resolve => setTimeout(resolve, 1000));
                        }
                    } catch (error) { output.failure = String(error); }
                    await invoke('native_crash_report', {value: output});
                })();"#.replace("__CRASH_EXPECTED_JSON__", &crash_expected_literal);
                webview.eval(&script).expect("native postcrash restore WebView2");
                return;
            }
            if scenario.starts_with("lifecycle-update-") {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:__SCENARIO__};
                    const wait=async predicate=>{for(let i=0;i<60;i++){const state=await invoke('native_lifecycle_state');if(predicate(state))return state;await new Promise(resolve=>setTimeout(resolve,500));}throw new Error('update checkpoint absent');};
                    const launch=()=>invoke('desktop_update_launch_installer',output.prepared);
                    try{
                        await invoke('native_install_companion',{valid:true});
                        await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});
                        output.before=await invoke('native_legacy_start_report');
                        output.providerPath=await invoke('native_isolate_provider_path');
                        output.session=await invoke('workspace_session_open');
                        output.prepared=await invoke('native_prepare_update_fixture');
                        void launch().then(value=>{output.commandResult=value;},error=>{output.commandError=String(error);});
                        output.finishing=await wait(state=>state.points.includes('Finishing'));
                        if(output.finishing.has_session||output.finishing.discovery!==null||output.finishing.runtime.shutdown_requested)throw new Error('update finished before owner collection');
                        output.beforeEffect=await invoke('native_update_fixture_control',{mode:'inspect'});
                        if(output.beforeEffect.events.length!==0)throw new Error('early update helper');
                        try{await launch();output.coalesced='accepted';}catch(error){output.coalesced=String(error);}
                        if(output.coalesced!=='shutdown_in_progress')throw new Error('repeat update did not coalesce');
                        await invoke('native_request_app_exit',{code:23});
                        output.conflict=await invoke('native_lifecycle_state');
                        if(output.conflict.lifecycle.reservation!==output.finishing.lifecycle.reservation)throw new Error('competing exit replaced update');
                        await invoke('native_lifecycle_release',{point:'Finishing'});
                        output.preHelper=await wait(state=>state.points.includes('BeforeHelper'));
                        output.preHelperFixture=await invoke('native_update_fixture_control',{mode:'inspect'});
                        if(!output.preHelper.runtime.shutdown_requested||!output.preHelper.lifecycle.cleanup_done||output.preHelperFixture.events.length)throw new Error('helper did not wait for actual old cleanup');
                        if(output.scenario==='lifecycle-update-revalidate-retry')await invoke('native_update_fixture_control',{mode:'mutate'});
                        if(output.scenario==='lifecycle-update-spawn-retry')await invoke('native_update_fixture_control',{mode:'fail_spawn'});
                        if(output.scenario!=='lifecycle-update-success'){
                            await invoke('native_lifecycle_release',{point:'BeforeHelper'});
                            output.failed=await wait(state=>state.lifecycle.phase==='FailedClosed');
                            for(let i=0;i<60&&!output.commandError;i++)await new Promise(resolve=>setTimeout(resolve,100));
                            output.failedFixture=await invoke('native_update_fixture_control',{mode:'inspect'});
                            if(!output.commandError||output.failed.has_session||output.failed.discovery!==null||output.failed.lifecycle.helper_started_or_uncertain||output.failedFixture.events.some(event=>event.spawned))throw new Error('failed update not closed/unstarted');
                            output.failureTitle=await invoke('native_window_title');
                            await invoke('native_update_fixture_control',{mode:'restore'});
                            // A genuine explicit retry uses the identical canonical path and SHA.
                            output.retryInput=output.prepared;
                            void launch().then(value=>{output.retryResult=value;},error=>{output.retryError=String(error);});
                            const retry=await wait(state=>state.points.includes('RetryFinishing')&&state.lifecycle.reservation!==output.failed.lifecycle.reservation&&state.lifecycle.pending);
                            output.retry=retry;
                            if(retry.lifecycle.generation!==output.failed.lifecycle.generation||!retry.lifecycle.cleanup_done)throw new Error('retry resurrected owner or repeated cleanup');
                            await invoke('native_lifecycle_release',{point:'RetryFinishing'});
                            output.retryPreHelper=await wait(state=>state.points.includes('RetryBeforeHelper'));
                        }
                        await invoke('native_lifecycle_report',{value:output});
                        await invoke('native_lifecycle_release',{point:'BeforeHelper'});
                        if(output.scenario!=='lifecycle-update-success')await invoke('native_lifecycle_release',{point:'RetryBeforeHelper'});
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#.replace("__SCENARIO__",&serde_json::to_string(&scenario).unwrap());
                webview.eval(&script).expect("registered update command ordering");
                return;
            }
            if scenario=="lifecycle-natural-last" {
                webview.eval(r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:'lifecycle-natural-last'};
                    try{
                        await invoke('native_install_companion',{valid:true});
                        await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});
                        output.before=await invoke('native_legacy_start_report');
                        output.providerPath=await invoke('native_isolate_provider_path');
                        output.session=await invoke('workspace_session_open');
                        await invoke('native_request_window_close');
                        for(let i=0;i<60;i++){const state=await invoke('native_lifecycle_state');if(state.points.includes('Finishing')){output.finishing=state;break;}await new Promise(resolve=>setTimeout(resolve,500));}
                        if(!output.finishing||output.finishing.has_session||output.finishing.discovery!==null||output.finishing.runtime.shutdown_requested||!output.finishing.runtime.children.some(child=>child.alive))throw new Error('last-window preclose invariant');
                        const frames=output.finishing.lifecycle.responses.filter(frame=>frame.request.operation==='host.stop');
                        if(frames.length!==1||!frames[0].response.accepted)throw new Error('last-window stop not one collected attempt');
                        await invoke('native_lifecycle_report',{value:output});
                        await invoke('native_lifecycle_release',{point:'Finishing'});
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#).expect("actual last-window natural exit");
                return;
            }
            if scenario=="lifecycle-shared-direct-loss" {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:'lifecycle-shared-direct-loss'};
                    const tick=()=>new Promise(resolve=>setTimeout(resolve,100));
                    const wait=async predicate=>{for(let i=0;i<300;i++){const state=await invoke('native_lifecycle_state');if(predicate(state))return state;await tick();}throw new Error('reply-loss checkpoint absent');};
                    const denied=async(command,args)=>{try{await invoke(command,args);return 'accepted';}catch(error){return String(error);}};
                    try{
                        await invoke('native_install_companion',{valid:true});
                        await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});
                        output.before=await invoke('native_legacy_start_report');
                        await invoke('native_isolate_provider_path');
                        const session=await invoke('workspace_session_open');output.session=session;
                        output.readyStatus=await invoke('workspace_host_status');
                        if(output.readyStatus.phase!=='Ready'||output.readyStatus.instance_id!==session.instance_id||Object.keys(output.readyStatus).sort().join(',')!=='force_offer,generation,instance_id,phase,revision')throw new Error('ready host status mismatch');
                        output.discovery=await invoke('workspace_discovery_get');
                        if(output.discovery.instance_id!==session.instance_id||output.discovery.schema_version!==session.schema_version||!output.discovery.pipe_name.startsWith('\\\\.\\pipe\\winsmux-workspace-v1-'))throw new Error('current discovery mismatch');
                        output.hostIdentity=await invoke('native_record_owned_host');
                        output.healthyForce=await denied('workspace_force_exit');
                        await invoke('native_unrelated_cli_start');
                        output.prepared=await invoke('native_prepare_update_fixture');
                        const request={schema_version:1,instance_id:session.instance_id,operation_id:'87100000-0000-4000-8007-000000000001',expected_topology_revision:null,operation:'host.stop',params:{}};
                        const producer=invoke('workspace_request',{requestJson:JSON.stringify(request)}).then(result=>{output.originalStop=result;},error=>{output.originalError=String(error);});
                        await wait(state=>state.points.includes('Stopping'));
                        output.pendingUpdate=await denied('desktop_update_launch_installer',output.prepared);
                        if(output.pendingUpdate!=='shutdown_conflict')throw new Error('pending loss accepted update');
                        await invoke('native_request_app_exit',{code:23});
                        output.attached=await wait(state=>state.lifecycle.worker);
                        await invoke('native_lifecycle_release',{point:'Stopping'});
                        for(let i=0;i<300&&!(await invoke('native_gate_ready'));i++)await tick();
                        if(!(await invoke('native_gate_ready')))throw new Error('accepted host stop did not reach reply gate');
                        output.ready=await invoke('native_lifecycle_state');
                        await invoke('native_gate_validate_release',{abandon:false});
                        await producer;
                        output.unknown=await wait(state=>state.points.includes('ConsumerTerminal')&&state.lifecycle.phase==='Unknown');
                        output.unknownStatus=await invoke('workspace_host_status');
                        if(output.unknownStatus.phase!=='Unknown'||output.unknownStatus.instance_id!==session.instance_id||BigInt(output.unknownStatus.revision)<=BigInt(output.readyStatus.revision))throw new Error('unknown host status mismatch');
                        const consumer=output.unknown.lifecycle.consumers.find(c=>c.reservation===output.attached.lifecycle.reservation);
                        if(output.originalError!=='transport_uncertain'||consumer?.result?.Err!=='transport_uncertain'||output.unknown.lifecycle.pending||output.unknown.lifecycle.responses.length||output.unknown.points.filter(p=>p==='Stopping').length!==1)throw new Error('reply loss replayed or incorrectly confirmed');
                        output.windowRetained=true;
                        output.unknownOpen=await denied('workspace_session_open');
                        output.unknownDiscovery=await denied('workspace_discovery_get');
                        if(output.unknownDiscovery!=='transport_uncertain')throw new Error('unknown discovery was published');
                        output.reclose=await denied('workspace_session_close');
                        output.unknownUpdate=await denied('desktop_update_launch_installer',output.prepared);
                        if(output.unknownUpdate!=='transport_uncertain')throw new Error('unknown update admitted');
                        await invoke('native_fault_unknown_proof',{value:output});
                        // A is held after its terminal. Force B on the same generation must survive A's late projection/Drop.
                        const cancel=invoke('workspace_force_exit').then(()=>{output.cancelError='accepted';},error=>{output.cancelError=String(error);});
                        output.forceB=await wait(state=>state.lifecycle.phase==='ForcePrompt');
                        output.promptStatus=await invoke('workspace_host_status');
                        if(output.promptStatus.phase!=='ForcePrompt'||output.promptStatus.instance_id!==session.instance_id)throw new Error('force prompt host status mismatch');
                        output.titleBeforeOld=await invoke('native_window_title');
                        await invoke('native_lifecycle_release',{point:'ConsumerTerminal'});await tick();await tick();
                        output.afterOld=await invoke('native_lifecycle_state');output.titleAfterOld=await invoke('native_window_title');
                        if(output.afterOld.lifecycle.phase!=='ForcePrompt'||output.afterOld.lifecycle.reservation!==output.forceB.lifecycle.reservation||output.titleAfterOld!==output.titleBeforeOld)throw new Error('old consumer damaged force B');
                        await invoke('native_choose_force_dialog',{confirm:false});await cancel;
                        output.afterCancel=await invoke('native_lifecycle_state');
                        output.cancelStatus=await invoke('workspace_host_status');
                        if(output.cancelStatus.phase!=='Unknown'||output.cancelStatus.instance_id!==session.instance_id)throw new Error('cancel host status mismatch');
                        if(output.afterCancel.lifecycle.phase!=='Unknown'||!output.afterCancel.has_session||output.afterCancel.runtime.shutdown_requested)throw new Error('force cancel changed owned unknown');
                        output.snapshotUnchanged=await invoke('native_snapshot_unchanged');
                        await invoke('native_force_cancel_proof',{value:output});
                        output.fixture=await invoke('native_update_fixture_control',{mode:'inspect'});
                        if(output.fixture.events.length)throw new Error('unknown/force allowed helper');
                        await invoke('native_lifecycle_report',{value:output});
                        const force=invoke('workspace_force_exit');await invoke('native_choose_force_dialog',{confirm:true});
                        output.forceCollected=await wait(state=>state.points.includes('Finishing')&&state.lifecycle.phase==='Finishing');
                        if(output.forceCollected.has_session||output.forceCollected.discovery!==null||output.forceCollected.runtime.shutdown_requested)throw new Error('force completion before observed owned collection');
                        await invoke('native_lifecycle_report',{value:output});await invoke('native_lifecycle_release',{point:'Finishing'});await force;
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#;
                webview.eval(script).expect("actual shared stop reply-loss journey");return;
            }
            if scenario.starts_with("lifecycle-shared-") {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:__SCENARIO__};
                    const tick=()=>new Promise(resolve=>setTimeout(resolve,100));
                    const wait=async predicate=>{for(let i=0;i<300;i++){const state=await invoke('native_lifecycle_state');if(predicate(state))return state;await tick();}throw new Error('shared-result checkpoint absent');};
                    const frames=state=>state.lifecycle.responses.filter(record=>record.request.operation==='host.stop');
                    const normalized=value=>Array.isArray(value)?value.map(normalized):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,normalized(value[key])])):value;
                    const denied=async(command,args)=>{try{await invoke(command,args);return 'accepted';}catch(error){return String(error);}};
                    let count=0,session;
                    const request=(operation,params={},revision=null)=>JSON.stringify({schema_version:1,instance_id:session.instance_id,operation_id:'87100000-0000-4000-8000-'+String(++count).padStart(12,'0'),expected_topology_revision:revision,operation,params});
                    const conserved=(before,after)=>{
                        if(after.discovery?.instance_id!==session.instance_id||after.lifecycle.generation!==before.lifecycle.generation)throw new Error('owner generation changed');
                        if(JSON.stringify(after.confirmed_bytes)!==JSON.stringify(before.confirmed_bytes)||JSON.stringify(after.backup_bytes)!==JSON.stringify(before.backup_bytes))throw new Error('durable bytes changed');
                        const original=before.runtime.children.find(child=>child.alive);
                        if(after.runtime.shutdown_requested||!after.runtime.children.some(child=>child.alive&&child.pid===original?.pid))throw new Error('old runtime changed');
                    };
                    try{
                        await invoke('native_install_companion',{valid:true});
                        await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});
                        await invoke('native_legacy_start_report');
                        if(output.scenario.endsWith('-accepted')||output.scenario.endsWith('-prewire'))output.providerPath=await invoke('native_isolate_provider_path');
                        session=await invoke('workspace_session_open');output.session=session;
                        output.hostIdentity=await invoke('native_record_owned_host');
                        output.save=await invoke('workspace_request',{requestJson:request('layout.save')});
                        if(!output.save.accepted)throw new Error('baseline save refused '+JSON.stringify(output.save));
                        output.before=await invoke('native_lifecycle_state');
                        const accepted=output.scenario.endsWith('-accepted'),prewire=output.scenario.endsWith('-prewire');
                        if(!accepted&&!prewire)await invoke('native_block_snapshot_temp',{block:true});
                        const stopArgs=output.scenario.includes('-direct-')?{requestJson:prewire?JSON.stringify({...JSON.parse(request('host.stop')),instance_id:'87000000-0000-4000-8000-000000000001'}):request('host.stop')}:undefined;
                        const stopCommand=stopArgs?'workspace_request':'workspace_session_close';
                        const direct=invoke(stopCommand,stopArgs).then(result=>(output.originalStop=result,result),error=>(output.originalError=String(error),null));
                        await wait(state=>state.points.includes('Stopping'));
                        output.prepared=await invoke('native_prepare_update_fixture');
                        output.pendingUpdate=await denied('desktop_update_launch_installer',output.prepared);
                        if(output.pendingUpdate!=='shutdown_conflict')throw new Error('pending session-only admitted update');
                        output.pendingUpdateFixture=await invoke('native_update_fixture_control',{mode:'inspect'});
                        if(output.pendingUpdateFixture.events.length)throw new Error('pending session-only launched helper');
                        await invoke('native_request_app_exit',{code:23});
                        output.attached=await wait(state=>state.lifecycle.worker);
                        output.concurrentClose=await denied('workspace_session_close');
                        if(output.concurrentClose!=='shutdown_in_progress')throw new Error('second stop admitted');
                        await invoke('native_lifecycle_release',{point:'Stopping'});
                        await direct;
                        if(accepted){
                            const terminal=await wait(state=>state.points.includes('ConsumerTerminal'));
                            if(!output.originalStop?.accepted||frames(terminal).length!==1||terminal.has_session||terminal.discovery!==null||terminal.lifecycle.phase!=='Finishing')throw new Error('one accepted stop did not collect');
                            if(terminal.lifecycle.consumers.find(c=>c.reservation===output.attached.lifecycle.reservation)?.result?.Ok!==null)throw new Error('accepted stop consumer failed');
                            output.terminal=terminal;
                            await invoke('native_lifecycle_release',{point:'ConsumerTerminal'});
                            output.finishing=await wait(state=>state.points.includes('Finishing'));
                            output.poststopOpen=await denied('workspace_session_open');
                            if(output.poststopOpen!=='shutdown_in_progress')throw new Error('accepted stop reopened owner');
                            await invoke('native_lifecycle_report',{value:output});
                            await invoke('native_lifecycle_release',{point:'Finishing'});return;
                        }
                        output.refused=await wait(state=>state.points.includes('ConsumerTerminal')&&!state.lifecycle.pending);
                        if(prewire?output.originalError!=='protocol_failed':output.originalStop.accepted||!['operation_conflict','persistence_failed'].includes(output.originalStop.error?.code))throw new Error('first refusal missing');
                        const initialFrames=prewire?0:1;
                        if(frames(output.refused).length!==initialFrames||output.refused.lifecycle.phase!=='Ready')throw new Error('first refusal replayed or latch retained');
                        conserved(output.before,output.refused);
                        const frame=frames(output.refused)[0];
                        if(!prewire&&(frame.request.operation_id!==output.originalStop.operation_id||JSON.stringify(normalized(frame.response))!==JSON.stringify(normalized(output.originalStop))))throw new Error('original response not shared');
                        const consumer=output.refused.lifecycle.consumers.find(consumer=>consumer.reservation===output.attached.lifecycle.reservation);
                        if(consumer?.result?.Err!==(prewire?'protocol_failed':output.originalStop.error.code))throw new Error('consumer did not receive sealed original refusal');
                        if(output.scenario==='lifecycle-shared-session-refusal'){
                            await invoke('native_lifecycle_release',{point:'ConsumerTerminal'});
                            for(let i=0;i<60;i++){output.firstRefusalTitle=await invoke('native_window_title');if(output.firstRefusalTitle.includes(output.originalStop.error.code))break;await tick();}
                            if(!output.firstRefusalTitle?.includes(output.originalStop.error.code))throw new Error('original refusal UI projection absent');
                        }
                        await invoke('workspace_request',{requestJson:request('capabilities.get')});
                        output.noRetry=await invoke('native_lifecycle_state');conserved(output.before,output.noRetry);
                        if(frames(output.noRetry).length!==initialFrames)throw new Error('automatic second frame');
                        // A's consumer stays held while a genuinely new B reservation owns the same generation.
                        const updateRetry=output.scenario==='lifecycle-shared-direct-update';
                        const retry=async()=>{if(updateRetry){void invoke('desktop_update_launch_installer',output.prepared).then(value=>{output.updateResult=value;},error=>{(output.updateErrors??=[]).push(String(error));});}else{await invoke('native_request_app_exit',{code:23});}};
                        await retry();
                        output.retryHeld=await wait(state=>state.points.includes('RetryStopping')&&state.lifecycle.worker);
                        if(output.retryHeld.lifecycle.reservation===output.attached.lifecycle.reservation)throw new Error('retry reused completion');
                        output.titleBeforeOld=await invoke('native_window_title');
                        await invoke('native_lifecycle_release',{point:'ConsumerTerminal'});
                        await tick();await tick();
                        output.afterOld=await invoke('native_lifecycle_state');
                        output.titleAfterOld=await invoke('native_window_title');
                        if(output.afterOld.lifecycle.reservation!==output.retryHeld.lifecycle.reservation||!output.afterOld.lifecycle.worker||output.afterOld.lifecycle.phase!=='Stopping'||output.titleAfterOld!==output.titleBeforeOld)throw new Error('stale A touched B state/projection');
                        conserved(output.before,output.afterOld);
                        if(!prewire)await invoke('native_block_snapshot_temp',{block:false});
                        await invoke('native_lifecycle_release',{point:'RetryStopping'});
                        for(let i=0;i<60;i++){
                            const state=await invoke('native_lifecycle_state');
                            if(state.points.includes('Finishing')){output.finishing=state;break;}
                            if(!state.lifecycle.pending){
                                const record=frames(state).at(-1);
                                if(record.response.accepted||record.response.error?.code!=='operation_conflict')throw new Error('unexpected explicit retry result '+JSON.stringify(record));
                                conserved(output.before,state);
                                (output.explicitProbeRefusals??=[]).push({record,state});
                                if(updateRetry){const fixture=await invoke('native_update_fixture_control',{mode:'inspect'});if(fixture.events.length)throw new Error('refused update launched helper');}
                                await retry();
                            }
                            await new Promise(resolve=>setTimeout(resolve,500));
                        }
                        if(!output.finishing)throw new Error('explicit recovery did not finish');
                        const stops=frames(output.finishing),ids=new Set(stops.map(frame=>frame.request.operation_id));
                        if(ids.size!==stops.length||stops.at(-1).response.accepted!==true)throw new Error('stop identity mismatch');
                        if(output.finishing.has_session||output.finishing.discovery!==null||output.finishing.runtime.shutdown_requested)throw new Error('finishing owner/effect invariant');
                        output.poststopOpen=await denied('workspace_session_open');
                        if(output.poststopOpen!=='shutdown_in_progress')throw new Error('poststop owner published');
                        await invoke('native_lifecycle_report',{value:output});
                        await invoke('native_lifecycle_release',{point:'Finishing'});
                        if(updateRetry){output.preHelper=await wait(state=>state.points.includes('BeforeHelper'));output.fixture=await invoke('native_update_fixture_control',{mode:'inspect'});if(!output.preHelper.runtime.shutdown_requested||output.fixture.events.length)throw new Error('update helper preceded actual cleanup');await invoke('native_lifecycle_report',{value:output});await invoke('native_lifecycle_release',{point:'BeforeHelper'});}
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#.replace("__SCENARIO__",&serde_json::to_string(&scenario).unwrap());
                webview.eval(&script).expect("actual shared-result command journey");
                return;
            }
            if scenario=="lifecycle-worker-abandon" {
                webview.eval(r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:'lifecycle-worker-abandon'};
                    const wait=async predicate=>{for(let i=0;i<60;i++){const state=await invoke('native_lifecycle_state');if(predicate(state))return state;await new Promise(resolve=>setTimeout(resolve,500));}throw new Error('abandon checkpoint absent');};
                    try{
                        await invoke('native_install_companion',{valid:true});await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});output.before=await invoke('native_legacy_start_report');
                        await invoke('native_isolate_provider_path');output.session=await invoke('workspace_session_open');output.prepared=await invoke('native_prepare_update_fixture');
                        await invoke('native_request_app_exit',{code:23});
                        output.abandoned=await wait(state=>state.lifecycle.phase==='FailedClosed');
                        output.fixture=await invoke('native_update_fixture_control',{mode:'inspect'});
                        const stops=output.abandoned.lifecycle.responses.filter(frame=>frame.request.operation==='host.stop');
                        if(stops.length!==1||!stops[0].response.accepted||output.abandoned.has_session||output.abandoned.discovery!==null||output.abandoned.lifecycle.worker||output.abandoned.runtime.shutdown_requested||!output.abandoned.runtime.children.some(child=>child.alive)||output.fixture.events.length)throw new Error('abandoned completion executed effects or reopened owner');
                        try{await invoke('workspace_session_open');output.reopen='accepted';}catch(error){output.reopen=String(error);}
                        if(output.reopen!=='shutdown_failed')throw new Error('abandoned collected owner reopened');
                        await invoke('native_lifecycle_report',{value:output});
                        // A genuinely new plain Exit disarms the unexecuted purpose and cleans up once.
                        await invoke('native_request_app_exit',{code:0});
                        output.recovery=await wait(state=>state.points.includes('Finishing'));
                        if(output.recovery.lifecycle.responses.filter(frame=>frame.request.operation==='host.stop').length!==1)throw new Error('abandon recovery replayed stop');
                        await invoke('native_lifecycle_report',{value:output});await invoke('native_lifecycle_release',{point:'Finishing'});
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#).expect("actual owned completion abandonment");return;
            }
            if lifecycle_scenario {
                let script=r#"(async()=>{
                    const invoke=window.__TAURI_INTERNALS__.invoke,output={scenario:__SCENARIO__};
                    const wait=async point=>{for(let i=0;i<60;i++){const state=await invoke('native_lifecycle_state');if(state.points.includes(point))return state;if(point==='Finishing'&&!state.lifecycle.pending){const record=state.lifecycle.responses.at(-1);if(record?.request.operation!=='host.stop'||record.response.accepted||record.response.error?.code!=='operation_conflict')throw new Error('unexpected stop failure '+JSON.stringify(record));if(record.request.operation_id!==record.response.operation_id||record.owner_instance!==record.response.instance_id||state.discovery?.instance_id!==record.owner_instance)throw new Error('stop correlation/owner changed');if(state.runtime.shutdown_requested||!state.runtime.children.some(child=>child.alive)||state.confirmed_bytes!==null||state.backup_bytes!==null)throw new Error('refusal changed C/run/cleanup');if(output.probeJoinRefusals?.some(prior=>prior.record.request.operation_id===record.request.operation_id))throw new Error('same stop request repeated');if(output.probeJoinRefusals?.length&&output.probeJoinRefusals[0].record.owner_instance!==record.owner_instance)throw new Error('retry changed owner');(output.probeJoinRefusals??=[]).push({cause:'provider_probe_cancel_join_pending',record,state});await invoke('native_request_app_exit',{code:23});}await new Promise(r=>setTimeout(r,500));}throw new Error('checkpoint not reached '+point);};
                    const denied=async(command,args)=>{try{await invoke(command,args);return 'accepted';}catch(error){return String(error);}};
                    try{
                        await invoke('native_install_companion',{valid:true});
                        await invoke('pty_spawn',{paneId:'task870-legacy',cols:80,rows:24});
                        await invoke('native_legacy_start_report');
                        let session;
                        if(output.scenario==='lifecycle-opening'){
                            void invoke('workspace_session_open').then(value=>{output.openResult=value;},error=>{output.openError=String(error);});
                            await wait('Opening');
                        }else{session=await invoke('workspace_session_open');}
                        const requestJson=JSON.stringify({schema_version:1,instance_id:session?.instance_id||'87000000-0000-4000-8000-000000000001',operation_id:'87000000-0000-4000-8000-000000000002',expected_topology_revision:null,operation:'capabilities.get',params:{}});
                        if(output.scenario==='lifecycle-busy'){void invoke('workspace_request',{requestJson}).then(value=>{output.busyResult=value;},error=>{output.busyError=String(error);});await wait('Busy');}
                        if(output.scenario==='lifecycle-stopping'){void invoke('workspace_session_close').then(value=>{output.stopResult=value;},error=>{output.stopError=String(error);});await wait('Stopping');}
                        if(output.scenario==='lifecycle-busy')await invoke('native_request_window_close');
                        await invoke('native_request_app_exit',{code:23});
                        for(let i=0;i<60;i++){const state=await invoke('native_lifecycle_state');if(state.lifecycle.pending)break;await new Promise(r=>setTimeout(r,500));if(i===59)throw new Error('exit reservation not observed');}
                        await invoke('native_request_app_exit',{code:23});
                        await invoke('native_request_app_exit',{code:24});
                        for(let i=0;i<60;i++){output.conflictTitle=await invoke('native_window_title');if(output.conflictTitle.includes('shutdown_conflict'))break;await new Promise(r=>setTimeout(r,500));}
                        output.pendingOpen=await denied('workspace_session_open');
                        output.pendingRequest=await denied('workspace_request',{requestJson});
                        output.pendingClose=await denied('workspace_session_close');
                        for(const point of ['Opening','Busy','Stopping'])await invoke('native_lifecycle_release',{point});
                        output.finishing=await wait('Finishing');
                        output.poststopOpen=await denied('workspace_session_open');
                        output.poststopRequest=await denied('workspace_request',{requestJson});
                        output.poststopClose=await denied('workspace_session_close');
                        for(const key of ['pendingOpen','pendingRequest','pendingClose','poststopOpen','poststopRequest','poststopClose'])if(output[key]!=='shutdown_in_progress')throw new Error(key+': '+output[key]);
                        if(output.finishing.has_session||output.finishing.discovery!==null||output.finishing.runtime.shutdown_requested)throw new Error('poststop ownership/cleanup invariant');
                        if(!output.conflictTitle.includes('shutdown_conflict'))throw new Error('different exit code did not conflict');
                        await invoke('native_lifecycle_report',{value:output});
                        await invoke('native_lifecycle_release',{point:'Finishing'});
                    }catch(error){output.failure=String(error);await invoke('native_lifecycle_report',{value:output});}
                })();"#.replace("__SCENARIO__",&serde_json::to_string(&scenario).unwrap());
                webview.eval(&script).expect("actual lifecycle command journey");
                return;
            }
            if close_only {
                webview.eval(r#"(async () => {
                    const invoke = window.__TAURI_INTERNALS__.invoke;
                    await invoke('native_install_companion', {valid: true});
                    await invoke('pty_spawn', {paneId:'task870-legacy',cols:80,rows:24});
                    await invoke('native_legacy_start_report');
                    await invoke('workspace_session_open');
                    await invoke('native_unrelated_cli_start');
                    for (let attempt = 0; attempt < 60; attempt++) {
                        await invoke('native_request_window_close');
                        await new Promise(resolve => setTimeout(resolve, 500));
                        const title = await invoke('native_window_title');
                        if (title.includes('workspace close uncertain')) throw new Error(title);
                    }
                    throw new Error('normal close did not destroy the window');
                })().catch(error => window.__TAURI_INTERNALS__.invoke('native_nonowner_report', {outcome: 'close-only-error:' + String(error)}));"#)
                    .expect("invoke normal close through actual WebView2");
                return;
            }
            let script = r#"(async () => {
                const output = {};
                let invoke;
                try {
                    invoke = window.__TAURI_INTERNALS__.invoke;
                    for (let attempt = 0; attempt < 30; attempt++) {
                        output.nonOwner = await invoke('native_nonowner_status');
                        if (output.nonOwner) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.missingCompanion = String(error); }
                    await invoke('native_install_companion', {valid: false});
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.mismatchedCompanion = String(error); }
                    output.rollbackVersion = await invoke('native_install_rollback_companion');
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.wrongVersionCompanion = String(error); }
                    await invoke('native_install_companion', {valid: true});
                    output.session = await invoke('workspace_session_open');
                    await invoke('native_unrelated_cli_start');
                    let currentInstance = output.session.instance_id;
                    let sequence = 1;
                    const request = (operation, params, expected_topology_revision = null, instance_id = currentInstance) => ({
                        schema_version: 1, instance_id,
                        operation_id: `87000000-0000-4000-8000-${String(sequence++).padStart(12, '0')}`,
                        expected_topology_revision, operation, params
                    });
                    const send = async (operation, params, revision = null) =>
                        invoke('workspace_request', {requestJson: JSON.stringify(request(operation, params, revision))});
                    const capabilityRequest = {
                        schema_version: 1, instance_id: output.session.instance_id,
                        operation_id: '87000000-0000-4000-8000-000000000111',
                        expected_topology_revision: null, operation: 'capabilities.get', params: {}
                    };
                    output.capabilities = await invoke('workspace_request', {requestJson: JSON.stringify(capabilityRequest)});
                    try { await invoke('workspace_request', {requestJson: '{'}); }
                    catch (error) { output.malformed = String(error); }
                    try { await invoke('workspace_request', {requestJson: ' '.repeat(1048577)}); }
                    catch (error) { output.oversize = String(error); }
                    output.baseline = await send('project.list', {});
                    try { await invoke('workspace_request', {requestJson: JSON.stringify(request('project.list', {}, null, '87000000-0000-4000-8000-000000000999'))}); }
                    catch (error) { output.stale = String(error); }
                    try { await send('connection.request', {project_ids: [], scopes: ['altered_scope']}); }
                    catch (error) { output.alteredScope = String(error); }
                    output.opened = await send('project.open', {path: __PROJECT_PATH_JSON__}, 0);
                    const projectId = output.opened.result.data.project_id;
                    output.created = await send('pane.create', {project_id: projectId, shell_profile_id: 'pwsh'}, output.opened.topology_revision);
                    const runId = output.created.result.data.run_id;
                    output.panes = await send('pane.list', {project_id: projectId});
                    await invoke('native_public_start');
                    output.pending = await invoke('native_public_request', {requestJson: JSON.stringify(request(
                        'connection.request', {project_ids: [projectId], scopes: ['metadata']}, null, null))});
                    const connectionId = output.pending.result.data.connection_id;
                    output.pendingBefore = await send('connection.list', {});
                    output.overgrant = await send('connection.decide', {
                        connection_id: connectionId, decision: 'allow', project_ids: [projectId],
                        scopes: ['metadata', 'read_output', 'control']
                    });
                    output.pendingAfter = await send('connection.list', {});
                    output.metadataGrant = await send('connection.decide', {
                        connection_id: connectionId, decision: 'allow', project_ids: [projectId], scopes: ['metadata']
                    });
                    output.deniedRead = await invoke('native_public_request', {requestJson: JSON.stringify(request(
                        'output.read', {run_id: runId, cursor: null, max_bytes: 100}))});
                    output.grantAfterDeniedRead = await send('connection.list', {});
                    await invoke('native_public_close');
                    output.unrelatedBeforeClose = await invoke('native_unrelated_cli_alive');
                    const refusedTitle = 'winsmux — workspace close refused: runtime_failed';
                    await invoke('native_request_window_close');
                    for (let attempt = 0; attempt < 30; attempt++) {
                        output.normalCloseRefusal = await invoke('native_window_title');
                        if (output.normalCloseRefusal === refusedTitle) break;
                        await new Promise(resolve => setTimeout(resolve, 100));
                    }
                    await invoke('native_reset_window_title');
                    await invoke('native_request_window_close');
                    for (let attempt = 0; attempt < 30; attempt++) {
                        output.normalCloseRetryRefusal = await invoke('native_window_title');
                        if (output.normalCloseRetryRefusal === refusedTitle) break;
                        await new Promise(resolve => setTimeout(resolve, 100));
                    }
                    output.activeClose = await invoke('workspace_session_close');
                    output.afterRefusal = await send('project.list', {});
                    output.interrupted = await send('run.interrupt', {run_id: runId});
                    for (let attempt = 0; attempt < 30; attempt++) {
                        output.runAfterInterrupt = await send('run.get', {run_id: runId});
                        if (output.runAfterInterrupt.result?.data?.run?.process === 'exited') break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    for (let attempt = 0; attempt < 60; attempt++) {
                        output.close = await invoke('workspace_session_close');
                        if (output.close.accepted || !['operation_conflict', 'runtime_failed'].includes(output.close.error?.code)) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    try { await send('project.list', {}); }
                    catch (error) { output.closedRequest = String(error); }
                    output.reopened = await invoke('workspace_session_open');
                    try { await invoke('workspace_request', {requestJson: JSON.stringify(request('project.list', {}))}); }
                    catch (error) { output.staleAfterRestart = String(error); }
                    currentInstance = output.reopened.instance_id;
                    output.restored = await send('layout.restore', {}, 0);
                    output.restoredProjects = await send('project.list', {});
                    output.restoredPanes = await send('pane.list', {project_id: projectId});
                    for (let attempt = 0; attempt < 60; attempt++) {
                        output.finalClose = await invoke('workspace_session_close');
                        if (output.finalClose.accepted || !['operation_conflict', 'runtime_failed'].includes(output.finalClose.error?.code)) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    await invoke('native_install_rollback_companion');
                    output.unrelatedAfterClose = await invoke('native_unrelated_cli_alive');
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.postSessionRollback = String(error); }
                    await invoke('native_install_companion', {valid: true});
                    output.saveFailureSession = await invoke('workspace_session_open');
                    currentInstance = output.saveFailureSession.instance_id;
                    output.saveFailureRestore = await send('layout.restore', {}, 0);
                    await invoke('native_block_snapshot_temp', {block: true});
                    for (let attempt = 0; attempt < 60; attempt++) {
                        output.saveFailure = await invoke('workspace_session_close');
                        if (output.saveFailure.error?.code === 'persistence_failed'
                            || !['operation_conflict', 'runtime_failed'].includes(output.saveFailure.error?.code)) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    output.snapshotUnchanged = await invoke('native_snapshot_unchanged');
                    output.afterSaveFailure = await send('project.list', {});
                    await invoke('native_block_snapshot_temp', {block: false});
                    for (let attempt = 0; attempt < 60; attempt++) {
                        output.saveRecoveryClose = await invoke('workspace_session_close');
                        if (output.saveRecoveryClose.accepted || !['operation_conflict', 'runtime_failed'].includes(output.saveRecoveryClose.error?.code)) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    output.unknownSession = await invoke('workspace_session_open');
                    output.terminatedHostPid = await invoke('native_terminate_owned_host');
                    await invoke('native_request_window_close');
                    for (let attempt = 0; attempt < 30; attempt++) {
                        output.unknownCloseTitle = await invoke('native_window_title');
                        if (output.unknownCloseTitle === 'winsmux — workspace close uncertain') break;
                        await new Promise(resolve => setTimeout(resolve, 100));
                    }
                    await invoke('native_request_window_close');
                    output.unknownRepeatedCloseTitle = await invoke('native_window_title');
                    try { await invoke('workspace_session_open'); }
                    catch (error) { output.unknownOpen = String(error); }
                    output.unrelatedAfterUnknown = await invoke('native_unrelated_cli_alive');
                    await invoke('native_unrelated_cli_close');
                } catch (error) { output.failure = String(error); }
                if (invoke) {
                    let phase='report_begin';
                    const observe=(rejected=false)=>{try {void invoke('native_force_tail_phase',{phase,rejected}).catch(()=>{});} catch {}};
                    try {
                        observe();
                        const reported=await invoke('native_report', {value: output});
                        phase='report_return';observe();
                        if (reported) {
                            phase='force_begin';observe();
                            const force=invoke('workspace_force_exit');
                            phase='choose_begin';observe();
                            await invoke('native_choose_force_dialog',{confirm:true});
                            phase='choose_return';observe();
                            await force;
                            phase='force_return';observe();
                        }
                    } catch (error) { observe(true);throw error; }
                }
            })();"#.replace("__PROJECT_PATH_JSON__", &project_literal);
            webview.eval(&script).expect("invoke registered commands in actual WebView2");
        })
        .setup(move|app| {
            eprintln!("TASK870_NATIVE_SETUP");
            #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
            {let barrier=app.state::<Arc<LifecycleBarrier>>();*barrier.app.lock().unwrap()=Some(app.handle().clone());}
            if !natural_last_window {
                let mut secondary = tauri::WebviewWindowBuilder::new(app, "secondary", tauri::WebviewUrl::App("index.html".into())).visible(!input_guard_scenario);
                if let Some(args) = winsmux_app_lib::desktop_webview_browser_args(app.handle())? { secondary = secondary.additional_browser_args(&args); }
                secondary.build().expect("secondary native WebView2 window");
            }
            let main = app.config().app.windows.iter().find(|window| window.label == "main")
                .expect("main window config");
            let mut main_builder = tauri::WebviewWindowBuilder::from_config(app.handle(), main).expect("main webview builder");
            if let Some(args) = winsmux_app_lib::desktop_webview_browser_args(app.handle())? { main_builder = main_builder.additional_browser_args(&args); }
            let window = main_builder.build().expect("main WebView2 window");
            window.show().expect("show native WebView2 test window");
            native_legacy_start_report(app.handle().clone(),app.state::<NativeInputs>()).expect("initial owned native identity");
            Ok(())
        })
        .build(context)
        .expect("native Tauri app");
    let callback_failed=observer_failed.clone();
    let outcome = winsmux_app_lib::run_windows_desktop_loop(app,move |app_handle, event| {
      match event {
        tauri::RunEvent::WindowEvent {label,event:tauri::WindowEvent::Destroyed,..} if input_guard_scenario && label=="main" => {
            let manager=app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
            let inputs=app_handle.state::<NativeInputs>();
            #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
            {
                let runtime=winsmux_app_lib::native_desktop_runtime_inventory(app_handle);
                let lifecycle=manager.native_lifecycle_snapshot();
                let stops=lifecycle["responses"].as_array().unwrap().iter().filter(|row|row["request"]["operation"]=="host.stop"&&row["response"]["accepted"]==true).count();
                let snapshot=std::fs::read(inputs.home.join("AppData/Local/winsmux/workspace/v1/confirmed.json")).ok();
                let legacy_retained=runtime["children"].as_array().is_some_and(|children|children.len()==1&&children[0]["pane_id"]=="task872-legacy"&&children[0]["alive"]==true);
                let valid=!manager.has_session()&&runtime["shutdown_requested"]==false&&legacy_retained&&lifecycle["phase"]=="MainClosed"&&stops==1&&snapshot.as_ref().is_some_and(|bytes|serde_json::from_slice::<Value>(bytes).is_ok());
                let value=json!({"passed":valid,"lifecycle":lifecycle,"runtime":runtime,"accepted_stop_frames":stops,"snapshot_valid":snapshot.is_some()});
                std::fs::write(inputs.home.join("input-guard-main-closed.json"),serde_json::to_vec(&value).unwrap()).expect("main closed input proof");
                if !valid {callback_failed.store(true,Ordering::SeqCst);}
                eprintln!("TASK872_NATIVE_MAIN_CLOSED passed={valid} accepted_stop_frames={stops}");
            }
            app_handle.exit(23);
        }
        tauri::RunEvent::ExitRequested {code,..} => { eprintln!("TASK870_NATIVE_ACTUAL_EXIT_REQUEST code={code:?}"); }
        tauri::RunEvent::WindowEvent{label,event:tauri::WindowEvent::Destroyed,..} if natural_last_window&&label=="main"=>{
            #[cfg(all(windows,debug_assertions,feature="native-e2e-faults"))]
            {
                let manager=app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
                let inventory=winsmux_app_lib::native_desktop_runtime_inventory(app_handle);
                let value=json!({"lifecycle":manager.native_lifecycle_snapshot(),"runtime":inventory,"secondary_present":app_handle.get_webview_window("secondary").is_some()});
                let inputs=app_handle.state::<NativeInputs>();
                let _=std::fs::write(inputs.home.join("natural-main-destroyed.json"),serde_json::to_vec(&value).unwrap());
                if value["runtime"]["shutdown_requested"]!=false||!value["runtime"]["children"].as_array().is_some_and(|children|children.iter().any(|child|child["alive"]==true))||value["secondary_present"]!=false{
                    callback_failed.store(true,Ordering::SeqCst);
                }
                eprintln!("TASK870_NATIVE_NATURAL_MAIN_DESTROYED {value}");
            }
        }
        tauri::RunEvent::WindowEvent {
            label,
            event: tauri::WindowEvent::Destroyed,
            ..
        } if close_only && label == "main" => {
            let manager = app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
            if manager.has_session() {
                eprintln!("TASK870_NATIVE_NORMAL_CLOSE_FAILED owner remained after window destruction");
                app_handle.exit(1);return;
            }
            let inputs = app_handle.state::<NativeInputs>();
            let snapshot = inputs.home.join("AppData/Local/winsmux/workspace/v1/confirmed.json");
            let persisted = std::fs::read(&snapshot).ok()
                .is_some_and(|bytes| winsmux_workspace::parse_snapshot(&bytes).is_ok());
            if !persisted {
                eprintln!("TASK870_NATIVE_NORMAL_CLOSE_FAILED snapshot missing or invalid");
                app_handle.exit(1);return;
            }
            let unrelated_slot = app_handle.state::<UnrelatedCliSlot>();
            let mut unrelated = unrelated_slot.0.lock().expect("unrelated CLI lock")
                .take().expect("unrelated CLI process");
            let alive = unrelated.child.try_wait().expect("unrelated CLI query").is_none();
            drop(unrelated.input.take());
            let exit = unrelated.child.wait().expect("unrelated CLI exit");
            if !alive || !exit.success() {
                eprintln!("TASK870_NATIVE_NORMAL_CLOSE_FAILED unrelated CLI changed");
                app_handle.exit(1);return;
            }
            eprintln!("TASK870_NATIVE_NORMAL_CLOSE_PROOF accepted_stop_collected=true window_destroyed=true snapshot_valid=true unrelated_cli_alive=true");
            let secondary=app_handle.get_webview_window("secondary").expect("retained secondary");
            secondary.eval(r#"(async()=>{const invoke=window.__TAURI_INTERNALS__.invoke;let output,answered=0,sent=false;for(let i=0;i<60;i++){output=await invoke('pty_capture',{paneId:'task870-legacy',lines:100});const queries=(String(output.output).match(/\x1b\[6n/g)||[]).length;if(queries>answered){await invoke('pty_write',{paneId:'task870-legacy',data:'\x1b[1;1R'});answered=queries;}if(!sent&&answered>0){await invoke('pty_write',{paneId:'task870-legacy',data:"[Console]::WriteLine([string]::Concat('task870-','after-main-live'))\r\n"});sent=true;}if(String(output.output).includes('task870-after-main-live'))break;await new Promise(r=>setTimeout(r,500));}await invoke('native_legacy_after_main',{value:output});})().catch(error=>window.__TAURI_INTERNALS__.invoke('native_nonowner_report',{outcome:'close-only-error:'+String(error)}));"#).expect("secondary actual legacy IO");
        }
        tauri::RunEvent::Exit if silent_close => {
            let manager = app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
            let unrelated_slot = app_handle.state::<UnrelatedCliSlot>();
            let mut unrelated = unrelated_slot.0.lock().expect("unrelated CLI lock").take().expect("unrelated CLI process");
            let alive = unrelated.child.try_wait().expect("unrelated CLI query").is_none();
            drop(unrelated.input.take());
            let exit = unrelated.child.wait().expect("unrelated CLI exit");
            if manager.has_session() || !alive || !exit.success() {
                eprintln!("TASK870_NATIVE_STOP_REPLY_SILENT_CLOSE_FAILED");
                callback_failed.store(true, Ordering::SeqCst);
                return;
            }
            eprintln!("TASK870_NATIVE_STOP_REPLY_SILENT_CLOSE_PROOF");
        }
        tauri::RunEvent::Exit if force_exit_scenario => {
            let manager = app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
            let proof = app_handle.state::<ForceExitProof>();
            let inputs = app_handle.state::<NativeInputs>();
            let baseline = app_handle.state::<SnapshotBaseline>();
            let unchanged = std::fs::read(confirmed_snapshot_path(&inputs)).ok()
                == baseline.0.lock().expect("force snapshot lock").clone();
            let unrelated_slot = app_handle.state::<UnrelatedCliSlot>();
            let mut unrelated = unrelated_slot.0.lock().expect("unrelated CLI lock")
                .take().expect("unrelated CLI process");
            let alive = unrelated.child.try_wait().expect("unrelated CLI query").is_none();
            drop(unrelated.input.take());
            let exit = unrelated.child.wait().expect("unrelated CLI exit");
            if manager.has_session() || !unchanged || !alive || !exit.success()
                || !proof.cancelled.load(Ordering::SeqCst)
                || !proof.confirmed.load(Ordering::SeqCst)
                || !proof.cancellation_preserved.load(Ordering::SeqCst) {
                eprintln!("TASK870_NATIVE_FORCE_EXIT_FAILED terminal invariant");
                callback_failed.store(true,Ordering::SeqCst);return;
            }
            eprintln!("TASK870_NATIVE_FORCE_EXIT_PROOF healthy_denied=true warning_shown=true cancel_retained_unknown=true confirmed_exit=true owner_collected=true snapshot_unchanged=true unrelated_cli_alive=true");
            if fault_scenario {
                let fault = app_handle.state::<FaultProof>();
                if !fault.ready.load(Ordering::SeqCst) || !fault.unknown_retained.load(Ordering::SeqCst) || !(fault.snapshot_valid.load(Ordering::SeqCst) || fault.abandoned.load(Ordering::SeqCst)) { callback_failed.store(true,Ordering::SeqCst);return; }
                eprintln!("TASK870_NATIVE_STOP_REPLY_LOSS_PROOF ready=true snapshot_valid={} expected_validation_failure={} unknown_retained=true no_implicit_open=true reclose_denied=true owner_collected=true unrelated_cli_alive=true", fault.snapshot_valid.load(Ordering::SeqCst), fault.abandoned.load(Ordering::SeqCst));
            }
        }
        tauri::RunEvent::Exit => {
            eprintln!("TASK870_NATIVE_ACTUAL_APP_EXIT");
            #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
            if input_guard_scenario {
                let manager=app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
                let inputs=app_handle.state::<NativeInputs>();
                let value=json!({"has_session":manager.has_session(),"main_present":app_handle.get_webview_window("main").is_some(),"runtime":winsmux_app_lib::native_desktop_runtime_inventory(app_handle)});
                if value["has_session"]!=false||value["main_present"]!=false||value["runtime"]["shutdown_requested"]!=true {callback_failed.store(true,Ordering::SeqCst);}
                std::fs::write(inputs.home.join("input-guard-app-exit.json"),serde_json::to_vec(&value).unwrap()).expect("input inherited final exit proof");
            }
            if lifecycle_scenario {
                let inputs=app_handle.state::<NativeInputs>();
                let manager=app_handle.state::<Arc<winsmux_app_lib::workspace_transport::WorkspaceManager>>();
                let value=json!({"has_session":manager.has_session(),"main_present":app_handle.get_webview_window("main").is_some(),"secondary_present":app_handle.get_webview_window("secondary").is_some()});
                let _=std::fs::write(inputs.home.join("lifecycle-actual-exit.json"),serde_json::to_vec(&value).unwrap());
                eprintln!("TASK870_NATIVE_LIFECYCLE_ACTUAL_EXIT {value}");
            }
        }
        _ => {}
      }
    });
    match outcome {
        winsmux_app_lib::DesktopLoopOutcome::Confirmed {code,runtime_code}=> {
            eprintln!("TASK870_NATIVE_EVENT_LOOP_RETURN runtime_code={runtime_code} confirmed_code={code} tauri_cleanup_returned=true");
            if let Some(fixture)=update_fixture.0.lock().unwrap().as_ref(){
                let removed=std::fs::remove_file(&fixture.path).is_ok();
                eprintln!("TASK870_NATIVE_OWNED_UPDATE_FIXTURE_REMOVED removed={removed} path={}",fixture.path.display());
                if !removed {observer_failed.store(true,Ordering::SeqCst);}
            }
            std::process::exit(if observer_failed.load(Ordering::SeqCst){1}else{code});
        }
        winsmux_app_lib::DesktopLoopOutcome::UnexpectedReturn {runtime_code}=>panic!("native event loop returned without confirmed completion: {runtime_code}"),
    }
}
