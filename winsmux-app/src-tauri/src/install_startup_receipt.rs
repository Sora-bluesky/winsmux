//! Authenticated, single-use normal-mount acknowledgement for the private installer probe.
use std::sync::Mutex;
use tauri::{ipc, Manager, WebviewWindow};
use winsmux_workspace::desktop_install::StartupProbeContext;

pub struct ProbeState {
    context: Option<StartupProbeContext>,
    admitted_window: Mutex<Option<usize>>,
    sent: Mutex<bool>,
    diagnostics: ProbeDiagnostics,
}
impl ProbeState {
    pub fn from_args() -> Result<Self, String> {
        let raw: Vec<_> = std::env::args_os().skip(1).collect();
        if !raw.iter().any(|arg| {
            arg.to_str()
                .is_some_and(|value| value.starts_with("--winsmux-installer-"))
        }) {
            return Ok(Self {
                context: None,
                admitted_window: Mutex::new(None),
                sent: Mutex::new(false),
                diagnostics: ProbeDiagnostics::new(false),
            });
        }
        let args = raw
            .into_iter()
            .map(|arg| {
                arg.into_string()
                    .map_err(|_| "installer_probe_refused".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let context =
            StartupProbeContext::parse(&args).map_err(|_| "installer_probe_refused".to_owned())?;
        if let Some(context) = &context {
            context
                .validate()
                .map_err(|_| "installer_probe_refused".to_owned())?;
        }
        let diagnostics = ProbeDiagnostics::new(context.is_some());
        Ok(Self {
            context,
            admitted_window: Mutex::new(None),
            sent: Mutex::new(false),
            diagnostics,
        })
    }
    fn diagnostic_native(&self, window: &WebviewWindow, index: usize) {
        if self.context.is_some() { let _ = self.diagnostics.update(|state| state.native(index)); diagnostic_publish(window.app_handle()); }
    }
    pub fn data_directory(&self) -> Option<std::path::PathBuf> {
        self.context
            .as_ref()
            .map(|context| context.webview_data_dir.clone())
    }
    pub fn bind(&self, window: &WebviewWindow) -> Result<(), String> {
        if self.context.is_none() {
            return Ok(());
        }
        #[cfg(windows)]
        {
            let hwnd = window.hwnd().map_err(|_| "installer_probe_refused")?.0 as usize;
            let mut admitted = self
                .admitted_window
                .lock()
                .map_err(|_| "installer_probe_refused")?;
            if admitted.is_some() || hwnd == 0 {
                return Err("installer_probe_refused".into());
            }
            *admitted = Some(hwnd);
            let _ = self.diagnostics.update(|state| state.bind(hwnd)); diagnostic_publish(window.app_handle());
            Ok(())
        }
        #[cfg(not(windows))]
        {
            let _ = window;
            Err("installer_probe_refused".into())
        }
    }
}
fn admit_receipt(expected: Option<usize>, actual: usize, visible: bool, sent: bool) -> bool {
    expected == Some(actual) && actual != 0 && visible && !sent
}

#[tauri::command]
pub fn installer_startup_confirmed(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
) -> Result<(), String> {
    let state = window.app_handle().state::<ProbeState>();
    let Some(context) = &state.context else {
        return Ok(());
    };
    state.diagnostic_native(&window, 6);
    if !crate::workspace_transport::main_local_webview(&window, &invocation) {
        state.diagnostic_native(&window, 7);
        return Err("installer_probe_refused".into());
    }
    #[cfg(windows)]
    {
        let mut sent = state.sent.lock().map_err(|_| "installer_probe_refused")?;
        let expected = *state
            .admitted_window
            .lock()
            .map_err(|_| "installer_probe_refused")?;
        let actual = window.hwnd().map_err(|_| "installer_probe_refused")?.0 as usize;
        if !admit_receipt(
            expected,
            actual,
            window.is_visible().map_err(|_| "installer_probe_refused")?,
            *sent,
        ) {
            state.diagnostic_native(&window, 8);
            return Err("installer_probe_refused".into());
        }
        // Reuse the actual current generation policy gate. Pending/Failed/Closed/old HWND refuse.
        crate::webview_accelerators::show_if_ready(&window).inspect_err(|_| state.diagnostic_native(&window, 9))?;
        *sent = true;
        state.diagnostic_native(&window, 10);
        context
            .send(&window.app_handle().package_info().version.to_string())
            .inspect(|_| state.diagnostic_native(&window, 11))
            .inspect_err(|_| state.diagnostic_native(&window, 12))
            .map_err(|_| "installer_probe_refused".to_owned())
    }
    #[cfg(not(windows))]
    {
        let _ = (context, invocation);
        Err("installer_probe_refused".into())
    }
}
// BEGIN PRIVATE PROPERTY CORE
mod property_claims {
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    pub const NAMES: [&str; 2] = ["Winsmux.InstallerProbe.Native.v1", "Winsmux.InstallerProbe.Frontend.v1"];
    pub const TAG: u64 = (0x5753u64 << 40) | (1u64 << 32);
    pub const NATIVE_NAMES: [&str; 14] = ["context_valid","hwnd_bound","policy_pending","policy_ready","policy_failed","policy_closed","confirm_entered","confirm_origin_refused","confirm_window_refused","confirm_policy_refused","send_entered","send_completed","send_refused","trace_stopped"];
    pub const FRONTEND_NAMES: [&str; 26] = ["mount_entered","policy_entered","policy_completed","listeners_entered","listeners_completed","input_entered","input_completed","connect_entered","open_entered","open_completed","host_entered","host_completed","initial_project_entered","initial_project_completed","refresh_entered","refresh_completed","reveal_entered","reveal_completed","confirm_entered","confirm_completed","catch_entered","catch_observe_entered","catch_observe_completed","catch_reveal_entered","catch_reveal_completed","early_return"];
    pub fn valid_mask(mask: u32, frontend: bool) -> bool {
        if frontend {
            if mask & !((1u32 << 26) - 1) != 0 { return false; }
            for (entered, completed) in [(1,2),(3,4),(5,6),(8,9),(10,11),(12,13),(14,15),(16,17),(18,19),(21,22),(23,24)] {
                if mask & (1 << completed) != 0 && mask & (1 << entered) == 0 { return false; }
            }
        } else {
            if mask & !((1u32 << 14) - 1) != 0 { return false; }
            if mask != 0 && mask & 1 == 0 { return false; }
            if mask & ((1 << 3) | (1 << 4) | (1 << 5)) != 0 && mask & (1 << 2) == 0 { return false; }
            if mask & (1 << 3) != 0 && mask & (1 << 4) != 0 { return false; }
            if mask & (1 << 6) != 0 && mask & (1 << 1) == 0 { return false; }
            if mask & ((1 << 7) | (1 << 8) | (1 << 9) | (1 << 10)) != 0 && mask & (1 << 6) == 0 { return false; }
            if mask & ((1 << 11) | (1 << 12)) != 0 && mask & (1 << 10) == 0 { return false; }
            if mask & (1 << 11) != 0 && mask & (1 << 12) != 0 { return false; }
        }
        true
    }
    pub fn encode(mask: u32, frontend: bool) -> Option<u64> { valid_mask(mask, frontend).then_some(TAG | u64::from(mask)) }
    pub fn decode(value: u64, frontend: bool) -> Option<u32> {
        if value & !u64::from(u32::MAX) != TAG { return None; }
        let mask = value as u32;
        valid_mask(mask, frontend).then_some(mask)
    }
    pub fn frontend_index(claim: &str) -> Option<usize> { FRONTEND_NAMES.iter().position(|value| *value == claim) }
    pub fn admitted_window(bound: usize, actual: usize, expected_generation: Option<u64>, actual_generation: Option<u64>) -> bool {
        bound != 0 && bound == actual && expected_generation.is_some_and(|generation| generation != 0 && Some(generation) == actual_generation)
    }
    #[derive(Default, Clone, Debug, PartialEq, Eq)]
    pub struct State { pub native: u32, pub frontend: u32, pub hwnd: usize, pub policy_hwnd: usize, pub generation: Option<u64>, pub disabled: bool }
    impl State {
        pub fn enabled() -> Self { Self { native: 1, ..Self::default() } }
        pub fn bind(&mut self, hwnd: usize) -> bool {
            if self.disabled || hwnd == 0 || self.hwnd != 0 || (self.policy_hwnd != 0 && self.policy_hwnd != hwnd) { return false; }
            self.hwnd = hwnd; self.native |= 1 << 1; true
        }
        pub fn native(&mut self, index: usize) -> bool {
            if self.disabled || index >= 14 { return false; }
            let next = self.native | (1 << index);
            if !valid_mask(next, false) { return false; }
            self.native = next; true
        }
        pub fn policy(&mut self, hwnd: usize, generation: u64, phase: u8) -> bool {
            if self.disabled || hwnd == 0 || generation == 0 || phase > 3 || (self.hwnd != 0 && self.hwnd != hwnd) { return false; }
            if let Some(current) = self.generation {
                if generation != current || self.policy_hwnd != hwnd {
                    if generation > current { self.disabled = true; }
                    return false;
                }
            } else { self.generation = Some(generation); self.policy_hwnd = hwnd; }
            let next = self.native | (1 << 2) | match phase { 0 => 0, 1 => 1 << 3, 2 => 1 << 4, _ => 1 << 5 };
            if !valid_mask(next, false) { return false; }
            self.native = next; true
        }
        pub fn frontend(&mut self, hwnd: usize, generation: u64, index: usize) -> bool {
            if self.disabled || self.hwnd == 0 || hwnd != self.hwnd || self.policy_hwnd != hwnd || self.generation != Some(generation) || index >= 26 { return false; }
            let next = self.frontend | (1 << index);
            if !valid_mask(next, true) { return false; }
            self.frontend = next; true
        }
        pub fn values(&self) -> Option<[u64; 2]> {
            if self.disabled || self.hwnd == 0 { return None; }
            Some([encode(self.native, false)?, encode(self.frontend, true)?])
        }
    }
    pub trait Api {
        fn valid(&self, hwnd: usize) -> bool;
        fn get(&self, hwnd: usize, namespace: usize) -> Result<Option<u64>, ()>;
        fn set(&self, hwnd: usize, namespace: usize, value: u64) -> bool;
        fn remove(&self, hwnd: usize, namespace: usize) -> Option<u64>;
    }
    pub struct Publication { pub stopped: AtomicBool, pub failed: AtomicBool, hwnd: AtomicUsize, owned: [AtomicU64; 2] }
    impl Default for Publication { fn default() -> Self { Self { stopped: AtomicBool::new(false), failed: AtomicBool::new(false), hwnd: AtomicUsize::new(0), owned: [AtomicU64::new(0), AtomicU64::new(0)] } } }
    impl Publication {
        // All property API calls are serialized by the existing Tauri main thread.
        pub fn publish(&self, api: &impl Api, hwnd: usize, values: [u64; 2]) -> bool {
            if self.stopped.load(Ordering::Acquire) || hwnd == 0 || !api.valid(hwnd) { return false; }
            let prior = self.hwnd.load(Ordering::Acquire);
            if prior != 0 && prior != hwnd { self.failed.store(true, Ordering::Release); self.stop(api); return false; }
            self.hwnd.store(hwnd, Ordering::Release);
            for namespace in 0..2 {
                let expected = self.owned[namespace].load(Ordering::Acquire);
                if api.get(hwnd, namespace) != Ok(if expected == 0 { None } else { Some(expected) }) || decode(values[namespace], namespace == 1).is_none() {
                    self.failed.store(true, Ordering::Release); self.stop(api); return false;
                }
            }
            for namespace in 0..2 {
                if self.stopped.load(Ordering::Acquire) || !api.set(hwnd, namespace, values[namespace]) {
                    self.failed.store(true, Ordering::Release); self.stop(api); return false;
                }
                self.owned[namespace].store(values[namespace], Ordering::Release);
                if api.get(hwnd, namespace) != Ok(Some(values[namespace])) {
                    self.failed.store(true, Ordering::Release); self.stop(api); return false;
                }
            }
            true
        }
        pub fn stop(&self, api: &impl Api) {
            self.stopped.store(true, Ordering::Release);
            let hwnd = self.hwnd.load(Ordering::Acquire);
            for namespace in 0..2 {
                let expected = self.owned[namespace].load(Ordering::Acquire);
                if expected == 0 { continue; }
                if hwnd == 0 || !api.valid(hwnd) || api.get(hwnd, namespace) != Ok(Some(expected)) || api.remove(hwnd, namespace) != Some(expected) {
                    self.failed.store(true, Ordering::Release);
                } else { self.owned[namespace].store(0, Ordering::Release); }
            }
        }
    }
}
// END PRIVATE PROPERTY CORE

#[derive(Default)]
struct ProbeDiagnostics {
    state: Mutex<property_claims::State>,
    publication: property_claims::Publication,
}
impl ProbeDiagnostics {
    fn new(enabled: bool) -> Self {
        Self { state: Mutex::new(if enabled { property_claims::State::enabled() } else { property_claims::State::default() }), publication: property_claims::Publication::default() }
    }
    fn update(&self, action: impl FnOnce(&mut property_claims::State) -> bool) -> bool {
        if self.publication.stopped.load(std::sync::atomic::Ordering::Acquire) { return false; }
        match self.state.try_lock() {
            Ok(mut state) => state.native != 0 && action(&mut state),
            Err(_) => { self.publication.failed.store(true, std::sync::atomic::Ordering::Release); false }
        }
    }
}
#[cfg(windows)]
struct WindowPropertyApi;
#[cfg(windows)]
impl property_claims::Api for WindowPropertyApi {
    fn valid(&self, hwnd: usize) -> bool { usize::BITS == 64 && unsafe { property_win32::IsWindow(hwnd as _) != 0 } }
    fn get(&self, hwnd: usize, namespace: usize) -> Result<Option<u64>, ()> {
        let name: Vec<u16> = property_claims::NAMES[namespace].encode_utf16().chain(Some(0)).collect();
        let raw = unsafe { property_win32::GetPropW(hwnd as _, name.as_ptr()) } as usize as u64;
        Ok((raw != 0).then_some(raw))
    }
    fn set(&self, hwnd: usize, namespace: usize, value: u64) -> bool {
        let name: Vec<u16> = property_claims::NAMES[namespace].encode_utf16().chain(Some(0)).collect();
        unsafe { property_win32::SetPropW(hwnd as _, name.as_ptr(), value as usize as _) != 0 }
    }
    fn remove(&self, hwnd: usize, namespace: usize) -> Option<u64> {
        let name: Vec<u16> = property_claims::NAMES[namespace].encode_utf16().chain(Some(0)).collect();
        let raw = unsafe { property_win32::RemovePropW(hwnd as _, name.as_ptr()) } as usize as u64;
        (raw != 0).then_some(raw)
    }
}
#[cfg(windows)]
mod property_win32 {
    use windows_sys::Win32::Foundation::{HANDLE, HWND};
    #[link(name = "user32")]
    unsafe extern "system" {
        pub fn IsWindow(hwnd: HWND) -> i32;
        pub fn SetPropW(hwnd: HWND, name: *const u16, value: HANDLE) -> i32;
        pub fn GetPropW(hwnd: HWND, name: *const u16) -> HANDLE;
        pub fn RemovePropW(hwnd: HWND, name: *const u16) -> HANDLE;
    }
}
pub(crate) fn diagnostic_publish<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    #[cfg(windows)] {
        let app = app.clone(); let queue = app.clone();
        let queued = queue.run_on_main_thread(move || {
            let Some(probe) = app.try_state::<ProbeState>() else { return; };
            if probe.context.is_none() { return; }
            if probe.diagnostics.publication.failed.load(std::sync::atomic::Ordering::Acquire) { probe.diagnostics.publication.stop(&WindowPropertyApi); return; }
            if let Ok(state) = probe.diagnostics.state.try_lock() {
                if state.disabled { probe.diagnostics.publication.stop(&WindowPropertyApi); }
                else if let Some(values) = state.values() {
                    let Some(window) = app.get_webview_window("main") else { probe.diagnostics.publication.stop(&WindowPropertyApi); return; };
                    let actual = window.hwnd().ok().map(|handle| handle.0 as usize).unwrap_or(0);
                    let generation = crate::webview_accelerators::diagnostic_generation(&window);
                    if property_claims::admitted_window(state.hwnd, actual, state.generation, generation) { probe.diagnostics.publication.publish(&WindowPropertyApi, state.hwnd, values); }
                    else { probe.diagnostics.publication.stop(&WindowPropertyApi); }
                }
            };
        });
        if queued.is_err() { if let Some(probe) = queue.try_state::<ProbeState>() {
            probe.diagnostics.publication.failed.store(true, std::sync::atomic::Ordering::Release);
            probe.diagnostics.publication.stopped.store(true, std::sync::atomic::Ordering::Release);
        } }
    }
    #[cfg(not(windows))] let _ = app;
}
pub(crate) fn diagnostic_policy<R: tauri::Runtime>(app: &tauri::AppHandle<R>, hwnd: usize, generation: u64, phase: u8) {
    if let Some(probe) = app.try_state::<ProbeState>() {
        if probe.context.is_some() { let _ = probe.diagnostics.update(|state| state.policy(hwnd, generation, phase)); diagnostic_publish(app); }
    }
}
pub(crate) fn diagnostic_stop_before_dispatch(app: &tauri::AppHandle, event: &tauri::RunEvent) {
    #[cfg(windows)] {
        let stop = matches!(event, tauri::RunEvent::WindowEvent { label, event: tauri::WindowEvent::CloseRequested { .. }, .. } if label == "main")
            || matches!(event, tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit);
        if stop { if let Some(probe) = app.try_state::<ProbeState>() { let _ = probe.diagnostics.update(|state| state.native(13)); probe.diagnostics.publication.stop(&WindowPropertyApi); } }
    }
    #[cfg(not(windows))] let _ = (app, event);
}
impl Drop for ProbeDiagnostics {
    fn drop(&mut self) {
        #[cfg(windows)] self.publication.stop(&WindowPropertyApi);
    }
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FrontendClaimRequest { claim: String }
#[tauri::command]
pub fn installer_startup_observed(window: WebviewWindow, invocation: ipc::Request<'_>, request_json: String) -> Result<(), String> {
    let state = window.app_handle().state::<ProbeState>();
    if state.context.is_none() { return Ok(()); }
    if !crate::workspace_transport::main_local_webview(&window, &invocation) { return Err("installer_trace_refused".into()); }
    let request: FrontendClaimRequest = serde_json::from_str(&request_json).map_err(|_| "installer_trace_refused")?;
    let index = property_claims::frontend_index(&request.claim).ok_or("installer_trace_refused")?;
    #[cfg(windows)] {
        let hwnd = window.hwnd().map_err(|_| "installer_trace_refused")?.0 as usize;
        let generation = crate::webview_accelerators::diagnostic_generation(&window).ok_or("installer_trace_refused")?;
        let accepted = state.diagnostics.update(|trace| trace.frontend(hwnd, generation, index));
        diagnostic_publish(window.app_handle());
        if !accepted { return Err("installer_trace_refused".into()); }
        Ok(())
    }
    #[cfg(not(windows))] { let _ = index; Err("installer_trace_refused".into()) }
}

#[cfg(test)]
mod tests {
    use super::{admit_receipt, FrontendClaimRequest};
    #[test]
    fn frontend_request_has_only_one_fixed_claim_field() {
        assert!(serde_json::from_str::<FrontendClaimRequest>(r#"{"claim":"mount_entered"}"#).is_ok());
        for raw in [r#"{}"#, r#"{"claim":3}"#, r#"{"claim":"mount_entered","other":true}"#] {
            assert!(serde_json::from_str::<FrontendClaimRequest>(raw).is_err());
        }
    }
    #[test]
    fn only_admitted_visible_first_generation_can_send() {
        assert!(admit_receipt(Some(7), 7, true, false));
        assert!(!admit_receipt(None, 7, true, false));
        assert!(!admit_receipt(Some(7), 8, true, false));
        assert!(!admit_receipt(Some(7), 7, false, false));
        assert!(!admit_receipt(Some(7), 7, true, true));
    }
}
