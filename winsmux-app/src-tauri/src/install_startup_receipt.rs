//! Authenticated, single-use normal-mount acknowledgement for the private installer probe.
use std::sync::Mutex;
use tauri::{ipc, Manager, WebviewWindow};
use winsmux_workspace::desktop_install::StartupProbeContext;

pub struct ProbeState {
    context: Option<StartupProbeContext>,
    admitted_window: Mutex<Option<usize>>,
    sent: Mutex<bool>,
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
        Ok(Self {
            context,
            admitted_window: Mutex::new(None),
            sent: Mutex::new(false),
        })
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
    if !crate::workspace_transport::main_local_webview(&window, &invocation) {
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
            return Err("installer_probe_refused".into());
        }
        // Reuse the actual current generation policy gate. Pending/Failed/Closed/old HWND refuse.
        crate::webview_accelerators::show_if_ready(&window)?;
        *sent = true;
        context
            .send(&window.app_handle().package_info().version.to_string())
            .map_err(|_| "installer_probe_refused".to_owned())
    }
    #[cfg(not(windows))]
    {
        let _ = (context, invocation);
        Err("installer_probe_refused".into())
    }
}
#[cfg(test)]
mod tests {
    use super::admit_receipt;
    #[test]
    fn only_admitted_visible_first_generation_can_send() {
        assert!(admit_receipt(Some(7), 7, true, false));
        assert!(!admit_receipt(None, 7, true, false));
        assert!(!admit_receipt(Some(7), 8, true, false));
        assert!(!admit_receipt(Some(7), 7, false, false));
        assert!(!admit_receipt(Some(7), 7, true, true));
    }
}
