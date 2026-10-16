//! Owns browser accelerator policy before any winsmux WebView becomes visible.
use tauri::{ipc, Manager, Runtime, WebviewWindow};

#[cfg(windows)]
use std::{collections::HashMap, sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Arc, Condvar, Mutex}};
#[cfg(windows)]
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
#[cfg(windows)]
use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2Settings3;
#[cfg(windows)]
use windows::core::{BOOL, Interface};

#[cfg(windows)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase { Pending, Ready, Failed, Closed }

#[cfg(windows)]
#[derive(Clone, Copy)]
struct Generation { id: u64, hwnd: Option<usize>, phase: Phase }

#[cfg(windows)]
#[derive(Default)]
struct Gate {
    rows: Mutex<HashMap<String, Generation>>,
    changed: Condvar,
    next: AtomicU64,
    startup_reported: AtomicBool,
}

#[cfg(windows)]
impl Gate {
    fn register(&self, label: String, hwnd: Option<usize>) -> Option<u64> {
        let id = self.next.fetch_add(1, Ordering::Relaxed).checked_add(1)?;
        let mut rows = self.rows.lock().ok()?;
        rows.insert(label, Generation { id, hwnd, phase: if hwnd.is_some() { Phase::Pending } else { Phase::Failed } });
        self.changed.notify_all();
        Some(id)
    }

    fn finish(&self, label: &str, id: u64, phase: Phase) {
        if let Ok(mut rows) = self.rows.lock() {
            if let Some(row) = rows.get_mut(label) {
                if row.id == id && row.phase == Phase::Pending { row.phase = phase; }
            }
            self.changed.notify_all();
        }
    }

    fn close(&self, label: &str, id: u64) {
        if let Ok(mut rows) = self.rows.lock() {
            if let Some(row) = rows.get_mut(label) {
                if row.id == id { row.phase = Phase::Closed; }
            }
            self.changed.notify_all();
        }
    }

    fn wait_ready(&self, label: &str, hwnd: usize) -> Result<(), String> {
        let mut rows = self.rows.lock().map_err(|_| "accelerator_policy_unavailable")?;
        loop {
            match rows.get(label) {
                Some(row) if row.hwnd == Some(hwnd) && row.phase == Phase::Ready => return Ok(()),
                Some(row) if row.hwnd == Some(hwnd) && row.phase == Phase::Pending => {
                    rows = self.changed.wait(rows).map_err(|_| "accelerator_policy_unavailable")?;
                }
                _ => return Err("accelerator_policy_unavailable".into()),
            }
        }
    }

    fn ready(&self, label: &str, hwnd: usize) -> bool {
        self.rows.lock().is_ok_and(|rows| rows.get(label).is_some_and(|row| row.hwnd == Some(hwnd) && row.phase == Phase::Ready))
    }

    fn show_if_ready(&self, label: &str, hwnd: usize, show: impl FnOnce() -> tauri::Result<()>) -> Result<(), String> {
        if !self.ready(label, hwnd) { return Err("accelerator_policy_unavailable".into()); }
        show().map_err(|_| "window_show_failed".into())
    }
}

#[cfg(windows)]
fn hwnd<R: Runtime>(window: &WebviewWindow<R>) -> Result<usize, String> {
    window.hwnd().map(|value| value.0 as usize).map_err(|_| "accelerator_policy_unavailable".into())
}

#[cfg(windows)]
fn disable_browser_accelerators(view: tauri::webview::PlatformWebview) -> bool {
    let result = (|| -> windows::core::Result<bool> {
        let core = unsafe { view.controller().CoreWebView2()? };
        let settings = unsafe { core.Settings()? };
        let settings3: ICoreWebView2Settings3 = settings.cast()?;
        unsafe {
            settings3.SetAreBrowserAcceleratorKeysEnabled(false)?;
            let mut enabled = BOOL::default();
            settings3.AreBrowserAcceleratorKeysEnabled(&mut enabled)?;
            Ok(!enabled.as_bool())
        }
    })();
    matches!(result, Ok(true))
}

pub fn install<R: Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    #[cfg(windows)]
    {
        let gate = Arc::new(Gate::default());
        let on_ready_gate = Arc::clone(&gate);
        return builder.manage(gate).plugin(tauri::plugin::Builder::<R>::new("webview-accelerators")
            .on_webview_ready(move |webview| {
                let label = webview.label().to_owned();
                let window = webview.window();
                let window_hwnd = window.hwnd().ok().map(|value| value.0 as usize);
                let Some(id) = on_ready_gate.register(label.clone(), window_hwnd) else { return; };
                let close_gate = Arc::clone(&on_ready_gate);
                let close_label = label.clone();
                window.on_window_event(move |event| {
                    if matches!(event, tauri::WindowEvent::Destroyed) { close_gate.close(&close_label, id); }
                });
                if window_hwnd.is_none() { return; }
                let callback_gate = Arc::clone(&on_ready_gate);
                let callback_label = label.clone();
                if webview.with_webview(move |view| {
                    callback_gate.finish(&callback_label, id,
                        if disable_browser_accelerators(view) { Phase::Ready } else { Phase::Failed });
                }).is_err() {
                    on_ready_gate.finish(&label, id, Phase::Failed);
                }
            }).build());
    }
    #[cfg(not(windows))]
    { builder }
}

pub async fn await_ready<R: Runtime>(window: &WebviewWindow<R>) -> Result<(), String> {
    #[cfg(windows)]
    {
        let gate = Arc::clone(window.app_handle().state::<Arc<Gate>>().inner());
        let label = window.label().to_owned();
        let hwnd = hwnd(window)?;
        return tauri::async_runtime::spawn_blocking(move || gate.wait_ready(&label, hwnd))
            .await.map_err(|_| "accelerator_policy_unavailable".to_owned())?;
    }
    #[cfg(not(windows))]
    { let _ = window; Ok(()) }
}

pub fn show_if_ready<R: Runtime>(window: &WebviewWindow<R>) -> Result<(), String> {
    #[cfg(windows)]
    {
        let gate = window.app_handle().state::<Arc<Gate>>();
        return gate.show_if_ready(window.label(), hwnd(window)?, || window.show());
    }
    #[cfg(not(windows))]
    { window.show().map_err(|_| "window_show_failed".into()) }
}

#[cfg(windows)]
fn report_main_failure<R: Runtime>(app: &tauri::AppHandle<R>) {
    let gate = app.state::<Arc<Gate>>();
    if gate.startup_reported.swap(true, Ordering::SeqCst) { return; }
    let app = app.clone();
    app.dialog().message("画面のキー操作を安全に設定できませんでした。winsmuxを終了します。")
        .title("winsmux — 起動を確認できません")
        .kind(MessageDialogKind::Error).buttons(MessageDialogButtons::Ok)
        .show(move |_| app.exit(2));
}

#[cfg(windows)]
pub fn report_hidden_completion_error<R: Runtime>(app: &tauri::AppHandle<R>) {
    app.dialog().message("作業場所の閉鎖を確認できません。状態を保持しています。")
        .title("winsmux — 閉鎖を確認できません")
        .kind(MessageDialogKind::Warning).buttons(MessageDialogButtons::Ok)
        .show(|_| {});
}

#[tauri::command]
pub async fn startup_main_policy_ready(window: WebviewWindow, invocation: ipc::Request<'_>) -> Result<(), String> {
    if !crate::workspace_transport::main_local_webview(&window, &invocation) { return Err("wrong_window".into()); }
    if let Err(error) = await_ready(&window).await {
        #[cfg(windows)] report_main_failure(window.app_handle());
        return Err(error);
    }
    Ok(())
}

#[tauri::command]
pub fn startup_main_show(window: WebviewWindow, invocation: ipc::Request<'_>) -> Result<(), String> {
    if !crate::workspace_transport::main_local_webview(&window, &invocation) { return Err("wrong_window".into()); }
    if let Err(error) = show_if_ready(&window) {
        #[cfg(windows)] report_main_failure(window.app_handle());
        return Err(error);
    }
    Ok(())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn only_current_generation_ready_can_be_shown() {
        let gate = Gate::default();
        let first = gate.register("main".into(), Some(11)).unwrap();
        assert!(!gate.ready("main", 11));
        gate.finish("main", first, Phase::Failed);
        assert!(!gate.ready("main", 11));
        let second = gate.register("main".into(), Some(22)).unwrap();
        gate.finish("main", first, Phase::Ready);
        assert!(!gate.ready("main", 22));
        assert!(!gate.ready("main", 11));
        gate.finish("main", second, Phase::Ready);
        assert!(gate.ready("main", 22));
        assert!(!gate.ready("main", 11));
        gate.close("main", first);
        assert!(gate.ready("main", 22));
        gate.close("main", second);
        assert!(!gate.ready("main", 22));
    }

    #[test]
    fn failed_and_missing_window_identity_cannot_be_reused() {
        let gate = Gate::default();
        let failed = gate.register("secondary".into(), None).unwrap();
        gate.finish("secondary", failed, Phase::Ready);
        assert!(!gate.ready("secondary", 9));
        let next = gate.register("secondary".into(), Some(9)).unwrap();
        gate.finish("secondary", next, Phase::Failed);
        assert!(gate.wait_ready("secondary", 9).is_err());
        assert!(!gate.ready("secondary", 9));
    }

    #[test]
    fn failed_pending_closed_and_old_generation_never_invoke_show() {
        let gate = Gate::default();
        let mut shows = 0;
        let first = gate.register("main".into(), Some(11)).unwrap();
        assert!(gate.show_if_ready("main", 11, || { shows += 1; Ok(()) }).is_err());
        gate.finish("main", first, Phase::Failed);
        assert!(gate.show_if_ready("main", 11, || { shows += 1; Ok(()) }).is_err());
        let second = gate.register("main".into(), Some(22)).unwrap();
        gate.finish("main", first, Phase::Ready);
        assert!(gate.show_if_ready("main", 11, || { shows += 1; Ok(()) }).is_err());
        assert!(gate.show_if_ready("main", 22, || { shows += 1; Ok(()) }).is_err());
        gate.finish("main", second, Phase::Ready);
        assert!(gate.show_if_ready("main", 22, || { shows += 1; Ok(()) }).is_ok());
        gate.close("main", second);
        assert!(gate.show_if_ready("main", 22, || { shows += 1; Ok(()) }).is_err());
        assert_eq!(shows, 1);
    }
}
