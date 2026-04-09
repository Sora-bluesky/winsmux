use portable_pty::native_pty_system;

#[test]
fn focus_pane_by_id_returns_false_and_preserves_focus_when_target_is_missing() {
    let pty = native_pty_system();
    let mut app = crate::types::AppState::new("task205-focus".to_string());

    crate::pane::create_window(&*pty, &mut app, Some("cmd /c pause"), None).expect("first pane should spawn");
    crate::pane::create_window(&*pty, &mut app, Some("cmd /c pause"), None).expect("second pane should spawn");

    let original_window_idx = app.active_idx;
    let original_pane_id = crate::tree::get_active_pane_id(
        &app.windows[app.active_idx].root,
        &app.windows[app.active_idx].active_path,
    )
    .expect("active pane should exist");

    let missing_pane_id = original_pane_id + 9999;
    let focused = crate::tree::focus_pane_by_id(&mut app, missing_pane_id);

    assert!(!focused, "missing pane ids must report failure");
    assert_eq!(app.active_idx, original_window_idx, "missing targets must not change the active window");

    let current_pane_id = crate::tree::get_active_pane_id(
        &app.windows[app.active_idx].root,
        &app.windows[app.active_idx].active_path,
    )
    .expect("active pane should still exist");
    assert_eq!(current_pane_id, original_pane_id, "missing targets must preserve the active pane");
}
