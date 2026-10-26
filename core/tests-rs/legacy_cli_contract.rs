use super::*;
use std::collections::{BTreeSet, VecDeque};

impl Fixture {
    fn ok(&self, args: &[&str]) -> String {
        output_text(self.run(args), args)
    }

    fn scoped(&self, args: &[&str]) -> String {
        let mut all = vec!["-L", self.namespace.as_str()];
        all.extend_from_slice(args);
        self.ok(&all)
    }

    fn target(&self, session: &str, args: &[&str]) -> String {
        let mut all = vec!["-t", session];
        all.extend_from_slice(args);
        self.scoped(&all)
    }

    fn start(&self, name: &str) {
        self.scoped(&["new-session", "-d", "-s", name, "-x", "120", "-y", "40"]);
        self.target(name, &["has-session"]);
    }

    fn pane_ids(&self, session: &str) -> BTreeSet<String> {
        self.target(session, &["list-panes", "-F", "#{pane_id}"])
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn active(&self, session: &str) -> String {
        self.target(session, &["display-message", "-p", "#{pane_id}"])
    }

    fn select(&self, session: &str, pane: &str) {
        self.target(&format!("{session}:{pane}"), &["select-pane"]);
    }

    fn split(&self, session: &str, direction: &str) -> String {
        self.target(
            session,
            &["split-window", direction, "-P", "-F", "#{pane_id}"],
        )
    }

    fn config(&self, content: &str) {
        fs::write(
            self.home.join("fixture.conf"),
            format!(
                "set -g default-shell cmd.exe\nset -g default-command 'cmd.exe /D /Q'\n{content}\n"
            ),
        )
        .unwrap();
    }

    fn option(&self, session: &str, name: &str) -> String {
        self.target(session, &["show-options", "-g", "-v", name])
    }

    fn wait_capture(&self, target: &str, marker: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let captured = self.target(target, &["capture-pane", "-p"]);
            if captured.contains(marker) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "pane {target} never exposed {marker:?}: {captured:?}"
            );
            thread::sleep(Duration::from_millis(25));
        }
    }
}

fn output_text(output: Output, args: &[&str]) -> String {
    assert!(
        output.status.success(),
        "command {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("CLI output must be UTF-8")
        .trim()
        .to_owned()
}

fn matches(text: &str, pattern: &str) {
    assert!(
        regex::Regex::new(pattern).unwrap().is_match(text),
        "{text:?} does not match {pattern:?}"
    );
}

#[test]
fn cli_session_lifecycle_preserves_names_and_negative_existence() {
    let fixture = Fixture::new();
    fixture.start("first");
    fixture.start("second");
    assert!(!fixture
        .run(&["-L", &fixture.namespace, "has-session", "-t", "missing"])
        .status
        .success());
    let listed = fixture.scoped(&["list-sessions"]);
    assert!(
        listed.contains("first") && listed.contains("second"),
        "{listed}"
    );
    fixture.target("first", &["rename-session", "renamed"]);
    fixture.target("renamed", &["has-session"]);
    assert!(!fixture
        .run(&["-L", &fixture.namespace, "has-session", "-t", "first"])
        .status
        .success());
    assert_eq!(
        fixture.target("renamed", &["display-message", "-p", "#{session_name}"]),
        "renamed"
    );
    let listed = fixture.scoped(&["ls"]);
    assert!(
        listed.contains("renamed") && !listed.contains("first"),
        "{listed}"
    );
    fixture.target("renamed", &["kill-ses"]);
    assert!(!fixture
        .run(&["-L", &fixture.namespace, "has-session", "-t", "renamed"])
        .status
        .success());
    fixture.target("second", &["has-session"]);
    fixture.start("third");
    fixture.start("fourth");
    assert_eq!(fixture.scoped(&["ls"]).lines().count(), 3);
    fixture.scoped(&["kill-server"]);
    for name in ["second", "third", "fourth"] {
        assert!(!fixture
            .run(&["-L", &fixture.namespace, "has-session", "-t", name])
            .status
            .success());
    }
}

#[test]
fn cli_new_session_getopt_aliases_duplicates_and_auto_names() {
    let fixture = Fixture::new();
    for args in [
        vec!["new", "-d", "-s", "alpha"],
        vec!["new-session", "-s", "beta", "-d"],
        vec!["new", "-d", "-s", "-d"],
        vec!["new", "-s", "my-session", "-n", "editor", "-d"],
    ] {
        fixture.scoped(&args);
    }
    for name in ["alpha", "beta", "-d", "my-session"] {
        assert!(fixture.port_path(name).is_file(), "missing port for {name}");
        fixture.target(name, &["has-session"]);
    }
    assert_eq!(
        fixture.target("my-session", &["display-message", "-p", "#{window_name}"]),
        "editor"
    );
    let duplicate = fixture.run(&["-L", &fixture.namespace, "new", "-d", "-s", "alpha"]);
    assert!(format!(
        "{}{}",
        String::from_utf8_lossy(&duplicate.stdout),
        String::from_utf8_lossy(&duplicate.stderr)
    )
    .contains("already exists"));
    assert_eq!(fixture.scoped(&["ls"]).lines().count(), 4);
    fixture.scoped(&["new", "-d"]);
    let listed = fixture.scoped(&["ls"]);
    assert_eq!(listed.lines().count(), 5);
    assert!(
        listed
            .lines()
            .any(|line| line.split(':').next().unwrap().parse::<u64>().is_ok()),
        "{listed}"
    );
}

#[test]
fn cli_print_formats_cover_session_window_and_pane_creation() {
    let fixture = Fixture::new();
    assert_eq!(
        fixture.scoped(&["new-session", "-d", "-s", "printed", "-P"]),
        "printed:"
    );
    let pane = fixture.scoped(&["new-session", "-d", "-s", "pane", "-P", "-F", "#{pane_id}"]);
    matches(&pane, r"^%\d+$");
    assert_eq!(
        fixture.scoped(&[
            "new-session",
            "-d",
            "-s",
            "formatted",
            "-P",
            "-F",
            "#{session_name}:#{window_index}"
        ]),
        "formatted:0"
    );
    matches(
        &fixture.target("printed", &["new-window", "-P"]),
        r"^printed:\d+$",
    );
    for (format, pattern) in [
        ("#{pane_id}", r"^%\d+$"),
        ("#{session_name}", r"^printed$"),
        ("#{window_index}", r"^\d+$"),
        (
            "#{session_name}:#{window_index}:#{pane_id}",
            r"^printed:\d+:%\d+$",
        ),
        ("#{window_name}", r"^.+$"),
        ("#{pane_width}x#{pane_height}", r"^\d+x\d+$"),
    ] {
        matches(
            &fixture.target("printed", &["new-window", "-P", "-F", format]),
            pattern,
        );
    }
    matches(
        &fixture.target("pane", &["split-window", "-P"]),
        r"^pane:\d+\.\d+$",
    );
    for (format, pattern) in [
        ("#{pane_id}", r"^%\d+$"),
        ("#{session_name}", r"^pane$"),
        (
            "#{session_name}:#{window_index}:#{pane_id}",
            r"^pane:\d+:%\d+$",
        ),
        ("#{pane_index}", r"^\d+$"),
    ] {
        matches(
            &fixture.target("pane", &["split-window", "-h", "-P", "-F", format]),
            pattern,
        );
    }
    fixture.target("formatted", &["new-window", "-n", "second"]);
    let windows = fixture.target(
        "formatted",
        &[
            "list-windows",
            "-F",
            "#{window_index}:#{window_name} #{session_name} #{pane_id}",
        ],
    );
    assert_eq!(windows.lines().count(), 2);
    for line in windows.lines() {
        matches(line, r"^\d+:\S+ formatted %\d+$");
    }
    assert!(windows.contains("second"));
    assert!(fixture
        .target("formatted", &["list-windows"])
        .contains("panes"));
}

#[test]
fn cli_namespaces_and_tmux_targets_remain_isolated() {
    let mut fixture = Fixture::new();
    let other = format!("{}_other", fixture.namespace);
    fixture.extra_namespaces.push(other.clone());
    fixture.start("worker");
    fixture.start("sibling");
    fixture.ok(&["-L", &other, "new-session", "-d", "-s", "worker"]);
    assert!(fixture
        .home
        .join(".psmux")
        .join(format!("{other}__worker.port"))
        .is_file());
    assert_eq!(fixture.scoped(&["ls"]).lines().count(), 2);
    assert_eq!(fixture.ok(&["-L", &other, "ls"]).lines().count(), 1);
    let regular = fixture.run(&["ls"]);
    assert!(!String::from_utf8_lossy(&regular.stdout).contains("worker"));
    let port = fs::read_to_string(fixture.port_path("worker")).unwrap();
    let tmux = format!("/tmp/psmux-0/default,{},0", port.trim());
    let pane = fixture.split("worker", "-h");
    let query = [
        "display-message",
        "-t",
        &pane,
        "-p",
        "#{session_name}:#{pane_id}",
    ];
    assert_eq!(
        output_text(fixture.run_with_env(&query, &[("TMUX", &tmux)]), &query),
        format!("worker:{pane}")
    );
    for args in [
        vec![
            "select-pane",
            "-t",
            pane.as_str(),
            "-P",
            "bg=default,fg=cyan",
        ],
        vec!["select-pane", "-t", pane.as_str(), "-T", "TestAgent"],
        vec![
            "send-keys",
            "-t",
            pane.as_str(),
            "echo NAMED_MARKER",
            "Enter",
        ],
        vec!["resize-pane", "-t", pane.as_str(), "-x", "30"],
    ] {
        output_text(fixture.run_with_env(&args, &[("TMUX", &tmux)]), &args);
    }
    fixture.wait_capture(&format!("worker:{pane}"), "NAMED_MARKER");
    assert_eq!(
        fixture.target(
            &format!("worker:{pane}"),
            &["display-message", "-p", "#{pane_title}"]
        ),
        "TestAgent"
    );
    assert_eq!(fixture.pane_ids("worker").len(), 2);
    assert_eq!(fixture.pane_ids("sibling").len(), 1);
    let kill = ["kill-pane", "-t", pane.as_str()];
    output_text(fixture.run_with_env(&kill, &[("TMUX", &tmux)]), &kill);
    assert_eq!(fixture.pane_ids("worker").len(), 1);
    fixture.target("worker", &["kill-session"]);
    assert!(!fixture.port_path("worker").exists());
    fixture.ok(&["-L", &other, "has-session", "-t", "worker"]);
    fixture.ok(&["-L", &other, "kill-server"]);
}

#[test]
fn cli_layouts_preserve_panes_and_roundtrip_through_serialized_layout() {
    let fixture = Fixture::new();
    fixture.start("layout");
    fixture.split("layout", "-h");
    fixture.split("layout", "-v");
    fixture.split("layout", "-h");
    let ids = fixture.pane_ids("layout");
    assert_eq!(ids.len(), 4);
    for layout in [
        "even-horizontal",
        "even-vertical",
        "main-horizontal",
        "main-vertical",
        "tiled",
    ] {
        fixture.target("layout", &["select-layout", layout]);
        assert_eq!(fixture.pane_ids("layout"), ids, "{layout}");
    }
    // Exercise the forward/reverse cycle before testing symmetry, as the
    // original CLI journey does; selecting a named layout is a separate path.
    for _ in 0..5 {
        fixture.target("layout", &["next-layout"]);
    }
    for _ in 0..5 {
        fixture.target("layout", &["previous-layout"]);
    }
    let before = fixture.target("layout", &["display-message", "-p", "#{window_layout}"]);
    fixture.target("layout", &["next-layout"]);
    let next = fixture.target("layout", &["display-message", "-p", "#{window_layout}"]);
    assert_ne!(next, before);
    fixture.target("layout", &["previous-layout"]);
    assert_eq!(
        fixture.target("layout", &["display-message", "-p", "#{window_layout}"]),
        before
    );
    fixture.target("layout", &["select-layout", "even-horizontal"]);
    fixture.target("layout", &["select-layout", &before]);
    assert_eq!(fixture.pane_ids("layout"), ids);
}

fn assert_all_panes_reachable(fixture: &Fixture, session: &str, count: usize) {
    let ids = fixture.pane_ids(session);
    assert_eq!(ids.len(), count);
    let mut visited = BTreeSet::new();
    let mut queue = VecDeque::from([fixture.active(session)]);
    while let Some(pane) = queue.pop_front() {
        if !visited.insert(pane.clone()) {
            continue;
        }
        for direction in ["-L", "-R", "-U", "-D"] {
            fixture.select(session, &pane);
            fixture.target(session, &["select-pane", direction]);
            let next = fixture.active(session);
            assert!(ids.contains(&next));
            if !visited.contains(&next) {
                queue.push_back(next);
            }
        }
    }
    assert_eq!(visited, ids, "all {count} panes must be reachable");
}

#[test]
fn cli_pane_navigation_reaches_asymmetric_two_through_six_pane_trees() {
    let fixture = Fixture::new();
    fixture.start("navigation");
    for (index, direction) in ["-v", "-h", "-h", "-v", "-h"].into_iter().enumerate() {
        if index == 2 {
            fixture.target("navigation", &["select-pane", "-U"]);
        }
        fixture.split("navigation", direction);
        assert_all_panes_reachable(&fixture, "navigation", index + 2);
    }
    fixture.start("grid");
    fixture.split("grid", "-h");
    fixture.split("grid", "-v");
    fixture.split("grid", "-h");
    fixture.target("grid", &["select-layout", "tiled"]);
    assert_all_panes_reachable(&fixture, "grid", 4);
    fixture.target("grid", &["select-pane", "-t", "grid:.0"]);
    let origin = fixture.active("grid");
    let mut circuit = BTreeSet::from([origin.clone()]);
    for direction in ["-R", "-D", "-L"] {
        fixture.target("grid", &["select-pane", direction]);
        circuit.insert(fixture.active("grid"));
    }
    fixture.target("grid", &["select-pane", "-U"]);
    assert_eq!(fixture.active("grid"), origin);
    assert_eq!(circuit.len(), 4);
}

#[test]
fn cli_pane_mru_controls_directional_ties_and_kill_focus() {
    let fixture = Fixture::new();
    for name in ["active", "nonactive", "repeated"] {
        fixture.start(name);
        fixture.split(name, "-h");
        let bottom_right = fixture.split(name, "-v");
        fixture.target(name, &["select-pane", "-R"]);
        let left = fixture.active(name);
        assert_ne!(left, bottom_right);
        fixture.target(name, &["select-pane", "-R"]);
        assert_eq!(fixture.active(name), bottom_right);
        fixture.target(name, &["select-pane", "-U"]);
        let top_right = fixture.active(name);
        fixture.target(name, &["select-pane", "-L"]);
        assert_eq!(fixture.active(name), left);
        match name {
            "active" => {
                fixture.target(name, &["kill-pane"]);
                assert_eq!(fixture.active(name), top_right);
            }
            "nonactive" => {
                fixture.target(&format!("{name}:{top_right}"), &["kill-pane"]);
                assert_eq!(fixture.active(name), left);
            }
            _ => {
                fixture.target(name, &["select-pane", "-R"]);
                assert_eq!(fixture.active(name), top_right);
                fixture.target(name, &["select-pane", "-D"]);
                assert_eq!(fixture.active(name), bottom_right);
                fixture.target(name, &["kill-pane"]);
                assert_eq!(fixture.active(name), top_right);
            }
        }
        assert_eq!(fixture.pane_ids(name).len(), 2);
    }
}

#[test]
fn cli_handlers_and_aliases_reach_the_session_server() {
    let fixture = Fixture::new();
    fixture.start("handlers");
    let info = fixture.target("handlers", &["server-info"]);
    for pattern in [
        r"winsmux",
        r"pid: \d+",
        r"session: handlers",
        r"windows: \d+",
        r"uptime: \d+s",
        r"socket:",
    ] {
        matches(&info, pattern);
    }
    assert!(fixture.target("handlers", &["info"]).contains("winsmux"));
    for args in [
        vec!["command-prompt"],
        vec!["command-prompt", "-I", "test"],
        vec!["refresh-client"],
        vec!["refresh"],
        vec!["refresh-client", "-S"],
        vec!["send-prefix"],
        vec!["show-messages"],
        vec!["showmsgs"],
        vec!["suspend-client"],
        vec!["suspendc"],
        vec!["lock-client"],
        vec!["lockc"],
        // The CLI reserves lock/locks for operator file-lock operations.
        vec!["lock-server"],
        vec!["lock-session"],
        vec!["resize-window"],
        vec!["resizew"],
        vec!["customize-mode"],
        vec!["start-server"],
        vec!["start"],
        vec!["confirm-before", "echo test"],
        vec!["confirm", "echo test"],
        vec!["display-menu", "Item1", "a", "echo test"],
        vec!["menu", "Item1", "a", "echo test"],
        vec!["display-popup", "-E", "echo test"],
        vec!["popup", "-E", "echo test"],
        vec!["display-panes"],
        vec!["displayp"],
        vec!["choose-client"],
        vec!["respawn-window"],
        vec!["respawnw"],
        vec!["link-window"],
        vec!["linkw"],
        vec!["unlink-window"],
        vec!["unlinkw"],
    ] {
        fixture.target("handlers", &args);
    }
    let help = fixture.ok(&["--help"]);
    for alias in [
        "a, at, attach",
        "neww",
        "splitw",
        "killp",
        "kill-ses",
        "capturep",
        "send-keys, send",
    ] {
        assert!(help.contains(alias), "missing help alias {alias}");
    }
    matches(&fixture.ok(&["-V"]), r"winsmux \d+\.\d+\.\d+");
    assert!(!fixture.target("handlers", &["list-commands"]).is_empty());
}

#[test]
fn cli_options_and_source_file_preserve_config_roundtrips() {
    let fixture = Fixture::new();
    fixture.config("set -g escape-time 123\nset -g status-left '[BASIC]'\nset -g status-right 'right'\nset -g mouse on\nset -g prefix C-a\nbind-key X new-window\nbind-key Y split-window");
    fixture.start("config");
    for (name, value) in [
        ("escape-time", "123"),
        ("status-left", "[BASIC]"),
        ("status-right", "right"),
        ("mouse", "on"),
    ] {
        assert_eq!(fixture.option("config", name), value, "{name}");
    }
    let keys = fixture.target("config", &["list-keys"]);
    matches(&keys, r"(?m)^.*\bX\b.*new-window");
    for (name, value) in [
        ("main-pane-width", "85"),
        ("main-pane-height", "24"),
        ("window-size", "largest"),
        ("allow-passthrough", "on"),
        ("set-clipboard", "external"),
        ("prefix2", "C-a"),
    ] {
        fixture.target("config", &["set-option", "-g", name, value]);
        assert_eq!(fixture.option("config", name), value, "{name}");
    }
    let sourced = fixture.home.join("sourced.conf");
    fs::write(
        &sourced,
        "set -g escape-time 321\nset -g @source-marker loaded\nunbind-key X\n",
    )
    .unwrap();
    fixture.target("config", &["source-file", sourced.to_str().unwrap()]);
    assert_eq!(fixture.option("config", "escape-time"), "321");
    assert_eq!(fixture.option("config", "@source-marker"), "loaded");
    assert!(!regex::Regex::new(r"(?m)^.*\bX\b.*new-window")
        .unwrap()
        .is_match(&fixture.target("config", &["list-keys"])));
    fixture.target("config", &["rename-window", "editor"]);
    assert_eq!(
        fixture.target(
            "config",
            &[
                "display-message",
                "-p",
                "#S:#W:#{window_name}:#{session_name}"
            ]
        ),
        "config:editor:editor:config"
    );
    assert_eq!(
        fixture.target("config", &["display-message", "-p", "#H"]),
        "winsmux-test-host"
    );
    assert!(fixture
        .target("config", &["run-shell", "echo hello-from-run-shell"])
        .contains("hello-from-run-shell"));
    assert!(fixture
        .target("config", &["run-shell", "echo session=#S"])
        .contains("session="));
}

#[test]
fn cli_config_plugin_order_overrides_ppm_and_explicit_file() {
    let fixture = Fixture::new();
    for (name, content) in [
        ("sensible", "set -g escape-time 50\nset -g base-index 1\nset -g mouse on\nset -g @order-test first\n"),
        ("theme", "set -g status-style 'bg=#282828,fg=#ebdbb2'\nset -g pane-active-border-style 'fg=#8ec07c'\nset -g @order-test second\n"),
        ("ppm", "set -g @must-not-load true\n"),
    ] {
        let directory = fixture.psmux_dir().join("plugins").join(name);
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("plugin.conf"), content).unwrap();
    }
    fixture.config("set -g @plugin sensible\nset -g @plugin org/theme\nset -g @plugin ppm\nset -g automatic-rename off\nset -g cursor-blink off\nset -g cursor-style block\nset -g escape-time 200");
    fixture.start("plugins");
    for (name, value) in [
        ("base-index", "1"),
        ("mouse", "on"),
        ("@order-test", "second"),
        ("automatic-rename", "off"),
        ("cursor-blink", "off"),
        ("cursor-style", "block"),
        ("escape-time", "200"),
    ] {
        assert_eq!(fixture.option("plugins", name), value, "{name}");
    }
    assert!(fixture
        .option("plugins", "status-style")
        .contains("#282828"));
    assert!(fixture
        .option("plugins", "pane-active-border-style")
        .contains("#8ec07c"));
    assert!(!fixture
        .target("plugins", &["show-options", "-g"])
        .contains("@must-not-load"));
    let explicit = fixture.home.join("explicit.conf");
    fs::write(&explicit, "set -g default-shell cmd.exe\nset -g default-command 'cmd.exe /D /Q'\nset -g @custom-file yes-custom\nset -g escape-time 999\n").unwrap();
    let args = [
        "-L",
        fixture.namespace.as_str(),
        "new-session",
        "-d",
        "-s",
        "explicit",
    ];
    output_text(
        fixture.run_with_env(&args, &[("PSMUX_CONFIG_FILE", explicit.to_str().unwrap())]),
        &args,
    );
    assert_eq!(fixture.option("explicit", "@custom-file"), "yes-custom");
    assert_eq!(fixture.option("explicit", "escape-time"), "999");
}

#[test]
fn cli_repeated_pane_creation_exposes_each_shell_output() {
    let fixture = Fixture::new();
    fixture.start("startup");
    let mut targets = vec!["startup:0".to_string()];
    for _ in 0..10 {
        targets.push(fixture.target("startup", &["new-window", "-P"]));
    }
    for target in &targets {
        fixture.target(target, &["send-keys", "echo READY_MARKER", "Enter"]);
        fixture.wait_capture(target, "READY_MARKER");
    }
    for direction in ["-h", "-v", "-h", "-v"] {
        let pane = fixture.split("startup", direction);
        let target = format!("startup:{pane}");
        fixture.target(&target, &["send-keys", "echo SPLIT_READY", "Enter"]);
        fixture.wait_capture(&target, "SPLIT_READY");
    }
    fixture.start("second");
    fixture.target("second", &["send-keys", "echo SECOND_READY", "Enter"]);
    fixture.wait_capture("second", "SECOND_READY");
}

#[test]
fn cli_config_run_shell_reaches_the_started_session() {
    let fixture = Fixture::new();
    let script = fixture.home.join("startup.ps1");
    let exe = fixture
        .exe
        .to_string_lossy()
        .replace('\\', "/")
        .replace('\'', "''");
    fs::write(
        &script,
        format!(
            "& '{exe}' -L '{}' -t startup set-option -g @startup-result connected\n",
            fixture.namespace
        ),
    )
    .unwrap();
    let script_path = script.to_string_lossy().replace('\\', "/");
    fixture.config(&format!(
        "set -g @startup-result waiting\nrun-shell '{script_path}'"
    ));
    fixture.start("startup");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let value = fixture.option("startup", "@startup-result");
        if value == "connected" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "config run-shell did not reach its server: {value:?}"
        );
        thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn cli_config_follows_an_explicit_symlink() {
    let fixture = Fixture::new();
    let original = fixture.home.join("real.conf");
    let link = fixture.home.join("link.conf");
    fs::write(&original, "set -g default-shell cmd.exe\nset -g default-command 'cmd.exe /D /Q'\nset -g @symlink-test symlinked\nset -g escape-time 777\n").unwrap();
    std::os::windows::fs::symlink_file(&original, &link)
        .expect("isolated config symlink must be creatable");
    let args = [
        "-L",
        fixture.namespace.as_str(),
        "new-session",
        "-d",
        "-s",
        "linked",
    ];
    output_text(
        fixture.run_with_env(&args, &[("PSMUX_CONFIG_FILE", link.to_str().unwrap())]),
        &args,
    );
    assert_eq!(fixture.option("linked", "@symlink-test"), "symlinked");
    assert_eq!(fixture.option("linked", "escape-time"), "777");
}

#[test]
fn cli_persistent_control_connection_creates_ready_windows_and_panes() {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpStream;
    let fixture = Fixture::new();
    fixture.start("persistent");
    let port: u16 = fs::read_to_string(fixture.port_path("persistent"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let key = fs::read_to_string(
        fixture
            .psmux_dir()
            .join(format!("{}.key", fixture.base("persistent"))),
    )
    .unwrap();
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    writeln!(stream, "AUTH {}", key.trim()).unwrap();
    stream.flush().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut response = String::new();
    reader.read_line(&mut response).unwrap();
    assert_eq!(response.trim(), "OK");
    writeln!(stream, "PERSISTENT\nclient-size 120 40\nnew-window -n wire").unwrap();
    stream.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while !fixture
        .target("persistent", &["list-windows", "-F", "#{window_name}"])
        .lines()
        .any(|name| name == "wire")
    {
        assert!(
            Instant::now() < deadline,
            "persistent new-window never appeared"
        );
        thread::sleep(Duration::from_millis(25));
    }
    writeln!(stream, "split-window -h").unwrap();
    stream.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while fixture.pane_ids("persistent").len() != 2 {
        assert!(
            Instant::now() < deadline,
            "persistent split-window never appeared"
        );
        thread::sleep(Duration::from_millis(25));
    }
    for pane in fixture.pane_ids("persistent") {
        let target = format!("persistent:{pane}");
        fixture.target(&target, &["send-keys", "echo WIRE_READY", "Enter"]);
        fixture.wait_capture(&target, "WIRE_READY");
    }
}

#[test]
fn cli_window_startup_stays_within_the_inherited_shell_overhead_budget() {
    let fixture = Fixture::new();
    let mut baseline = Duration::ZERO;
    for _ in 0..5 {
        let started = Instant::now();
        let output = Command::new("pwsh")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Write-Output READY_MARKER",
            ])
            .current_dir(&fixture.home)
            .env("HOME", &fixture.home)
            .env("USERPROFILE", &fixture.home)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8(output.stdout)
            .unwrap()
            .contains("READY_MARKER"));
        baseline += started.elapsed();
    }
    // Preserve the former benchmark's 3-second overhead allowance while
    // excluding user profile scripts from the measured product path.
    let allowance = baseline / 5 + Duration::from_secs(3);
    fixture.config("set -g default-command 'pwsh -NoProfile -NoLogo -NoExit -Command Write-Output READY_MARKER'");
    fixture.start("latency");
    fixture.wait_capture("latency", "READY_MARKER");
    for _ in 0..5 {
        let started = Instant::now();
        let target = fixture.target("latency", &["new-window", "-P"]);
        fixture.wait_capture(&target, "READY_MARKER");
        assert!(
            started.elapsed() <= allowance,
            "new-window shell readiness exceeded baseline plus 3 seconds"
        );
    }
}
