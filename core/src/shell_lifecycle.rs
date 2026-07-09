// Shell restore/exit matrix:
// - default shell + warm pane + no start_dir -> transplant warm pane.
// - default shell + start_dir -> cold-spawn in that directory.
// - configured default-shell without warm pane -> cold-spawn configured shell.
// - explicit command -> bypass default-shell restore.
// - exited pane + remain-on-exit off -> prune pane.
// - exited pane + remain-on-exit on -> keep a dead pane.
// - reader closes while in alt-screen -> synthesize terminal restore.
// - exit-empty + all panes removed -> stop the server.
// - default-shell changes -> reset warm pane before the next spawn.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellSpawnRoute {
    WarmDefaultShell,
    FreshDefaultShell,
    ConfiguredDefaultShell,
    ExplicitCommand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneExitAction {
    PrunePane,
    MarkDeadPane,
}

pub fn classify_shell_spawn(
    command_present: bool,
    configured_default_shell_present: bool,
    start_dir_present: bool,
    warm_pane_available: bool,
) -> ShellSpawnRoute {
    if command_present {
        return ShellSpawnRoute::ExplicitCommand;
    }

    if !start_dir_present && warm_pane_available {
        return ShellSpawnRoute::WarmDefaultShell;
    }

    if configured_default_shell_present {
        ShellSpawnRoute::ConfiguredDefaultShell
    } else {
        ShellSpawnRoute::FreshDefaultShell
    }
}

pub fn should_transplant_warm_default_shell(
    command_present: bool,
    start_dir_present: bool,
    warm_pane_available: bool,
) -> bool {
    matches!(
        classify_shell_spawn(command_present, false, start_dir_present, warm_pane_available),
        ShellSpawnRoute::WarmDefaultShell
    )
}

pub fn classify_pane_exit(remain_on_exit: bool) -> PaneExitAction {
    if remain_on_exit {
        PaneExitAction::MarkDeadPane
    } else {
        PaneExitAction::PrunePane
    }
}

pub fn should_restore_terminal_after_reader_exit(in_alternate_screen: bool) -> bool {
    in_alternate_screen
}

pub fn should_stop_server_after_reap(exit_empty: bool, all_empty: bool) -> bool {
    exit_empty && all_empty
}

pub fn should_reset_warm_pane_after_default_shell_change(old_shell: &str, new_shell: &str) -> bool {
    old_shell != new_shell
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spawn_matrix_covers_default_shell_routes() {
        let cases = [
            (
                "default shell uses warm pane when no cwd override is requested",
                false,
                false,
                false,
                true,
                ShellSpawnRoute::WarmDefaultShell,
            ),
            (
                "default shell with start_dir bypasses warm pane and spawns fresh",
                false,
                false,
                true,
                true,
                ShellSpawnRoute::FreshDefaultShell,
            ),
            (
                "configured default shell cold-spawns when no warm pane is available",
                false,
                true,
                false,
                false,
                ShellSpawnRoute::ConfiguredDefaultShell,
            ),
            (
                "explicit command always bypasses default-shell restore path",
                true,
                true,
                false,
                true,
                ShellSpawnRoute::ExplicitCommand,
            ),
        ];

        for (name, command, configured, start_dir, warm, expected) in cases {
            assert_eq!(
                classify_shell_spawn(command, configured, start_dir, warm),
                expected,
                "{name}"
            );
        }

        assert!(
            should_transplant_warm_default_shell(false, false, true),
            "warm route must not need configured default-shell expansion"
        );
        assert!(
            !should_transplant_warm_default_shell(false, true, true),
            "start_dir bypasses warm route before configured default-shell expansion"
        );
    }

    #[test]
    fn exit_matrix_covers_normal_and_abnormal_return_paths() {
        assert_eq!(
            classify_pane_exit(false),
            PaneExitAction::PrunePane,
            "normal or abnormal pane exit prunes the pane when remain-on-exit is off"
        );
        assert_eq!(
            classify_pane_exit(true),
            PaneExitAction::MarkDeadPane,
            "normal or abnormal pane exit leaves a dead pane when remain-on-exit is on"
        );
        assert!(
            should_restore_terminal_after_reader_exit(true),
            "abnormal TUI exit while in alt-screen restores the terminal surface"
        );
        assert!(
            !should_restore_terminal_after_reader_exit(false),
            "plain shell exit does not synthesize an alt-screen restore"
        );
        assert!(
            should_stop_server_after_reap(true, true),
            "exit-empty stops the server only after the last pane is gone"
        );
        assert!(
            !should_stop_server_after_reap(true, false),
            "exit-empty does not stop the server while any pane remains"
        );
    }

    #[test]
    fn restart_matrix_resets_warm_pane_only_when_default_shell_changes() {
        assert!(should_reset_warm_pane_after_default_shell_change("pwsh", "cmd"));
        assert!(!should_reset_warm_pane_after_default_shell_change("pwsh", "pwsh"));
    }

    #[test]
    fn property_matrix_rejects_unsafe_warm_transplants() {
        for command_present in [false, true] {
            for configured_default_shell_present in [false, true] {
                for start_dir_present in [false, true] {
                    for warm_pane_available in [false, true] {
                        let route = classify_shell_spawn(
                            command_present,
                            configured_default_shell_present,
                            start_dir_present,
                            warm_pane_available,
                        );

                        if command_present {
                            assert_eq!(
                                route,
                                ShellSpawnRoute::ExplicitCommand,
                                "explicit commands must never use a warm default shell"
                            );
                        }

                        if start_dir_present {
                            assert_ne!(
                                route,
                                ShellSpawnRoute::WarmDefaultShell,
                                "start_dir must force a fresh process with the requested cwd"
                            );
                        }

                        if matches!(route, ShellSpawnRoute::WarmDefaultShell) {
                            assert!(!command_present);
                            assert!(!start_dir_present);
                            assert!(warm_pane_available);
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn hundred_run_soak_keeps_restore_exit_invariants() {
        for run in 0..100 {
            let command_present = run % 5 == 0;
            let configured_default_shell_present = run % 3 == 0;
            let start_dir_present = run % 7 == 0;
            let warm_pane_available = run % 2 == 0;
            let remain_on_exit = run % 11 == 0;
            let in_alternate_screen = run % 13 == 0;
            let exit_empty = run % 17 != 0;
            let all_empty = run % 19 == 0;

            let route = classify_shell_spawn(
                command_present,
                configured_default_shell_present,
                start_dir_present,
                warm_pane_available,
            );
            let exit_action = classify_pane_exit(remain_on_exit);

            assert_eq!(
                should_transplant_warm_default_shell(
                    command_present,
                    start_dir_present,
                    warm_pane_available,
                ),
                matches!(route, ShellSpawnRoute::WarmDefaultShell),
                "run {run}: warm transplant helper must match the route classifier"
            );
            assert_eq!(
                should_restore_terminal_after_reader_exit(in_alternate_screen),
                in_alternate_screen,
                "run {run}: terminal restore must be tied only to alt-screen state"
            );
            assert_eq!(
                should_stop_server_after_reap(exit_empty, all_empty),
                exit_empty && all_empty,
                "run {run}: exit-empty must stop only after the last pane is gone"
            );
            assert_eq!(
                matches!(exit_action, PaneExitAction::MarkDeadPane),
                remain_on_exit,
                "run {run}: remain-on-exit controls whether dead panes are retained"
            );
        }
    }

    #[test]
    fn concurrent_matrix_classification_is_deterministic() {
        let handles: Vec<_> = (0..8)
            .map(|worker| {
                std::thread::spawn(move || {
                    for run in 0..128 {
                        let command_present = (run + worker) % 4 == 0;
                        let configured_default_shell_present = (run + worker) % 3 == 0;
                        let start_dir_present = (run + worker) % 5 == 0;
                        let warm_pane_available = (run + worker) % 2 == 0;

                        let first = classify_shell_spawn(
                            command_present,
                            configured_default_shell_present,
                            start_dir_present,
                            warm_pane_available,
                        );
                        let second = classify_shell_spawn(
                            command_present,
                            configured_default_shell_present,
                            start_dir_present,
                            warm_pane_available,
                        );

                        assert_eq!(first, second, "worker {worker} run {run}");
                    }
                })
            })
            .collect();

        for handle in handles {
            handle.join().expect("classification worker should not panic");
        }
    }
}
