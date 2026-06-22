// Prevents an additional console window on Windows. Keep this active in debug
// builds too because local dogfood and desktop E2E runs must launch only the app.
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

fn main() {
    winsmux_app_lib::run()
}
