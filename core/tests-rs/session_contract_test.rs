#[cfg(windows)]
mod windows_session_contract {
    use serde_json::Value;
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::thread;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    struct Fixture {
        exe: PathBuf,
        home: PathBuf,
        namespace: String,
    }

    impl Fixture {
        fn new() -> Self {
            let exe = PathBuf::from(
                env::var("CARGO_BIN_EXE_winsmux")
                    .expect("cargo should expose CARGO_BIN_EXE_winsmux"),
            );
            let unique = unique_id("session-contract");
            let home = env::temp_dir().join(&unique);
            fs::create_dir_all(home.join(".psmux")).expect("fixture should create .psmux");
            Self {
                exe,
                home,
                namespace: unique.replace('-', "_"),
            }
        }

        fn run(&self, args: &[&str]) -> Output {
            let mut command = Command::new(&self.exe);
            command
                .args(args)
                .env("USERPROFILE", &self.home)
                .env("HOME", &self.home)
                .env("PSMUX_CONFIG_FILE", "NUL")
                .env("PSMUX_NO_WARM", "1")
                .env("PSMUX_ALLOW_NESTING", "1")
                .env_remove("PSMUX_TARGET_SESSION")
                .env_remove("PSMUX_TARGET_FULL")
                .env_remove("PSMUX_ACTIVE")
                .env_remove("PSMUX_SESSION")
                .env_remove("TMUX");
            command.output().expect("winsmux command should run")
        }

        fn base(&self, session: &str) -> String {
            format!("{}__{}", self.namespace, session)
        }

        fn psmux_dir(&self) -> PathBuf {
            self.home.join(".psmux")
        }

        fn port_path(&self, session: &str) -> PathBuf {
            self.psmux_dir()
                .join(format!("{}.port", self.base(session)))
        }

        fn registry_path(&self, session: &str) -> PathBuf {
            self.psmux_dir()
                .join(format!("{}.registry.json", self.base(session)))
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.run(&["-L", &self.namespace, "kill-server"]);
            thread::sleep(Duration::from_millis(150));
            let _ = fs::remove_dir_all(&self.home);
        }
    }

    #[test]
    fn detached_session_reaches_readiness_contract_with_registry_identity() {
        let fixture = Fixture::new();
        let session = "contract";
        let created = fixture.run(&[
            "-L",
            &fixture.namespace,
            "new-session",
            "-d",
            "-s",
            session,
            "--",
            "cmd.exe",
            "/K",
            "title winsmux-session-contract",
        ]);
        assert!(
            created.status.success(),
            "new-session should succeed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&created.stdout),
            String::from_utf8_lossy(&created.stderr)
        );

        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && !fixture.port_path(session).exists() {
            thread::sleep(Duration::from_millis(25));
        }

        assert!(
            fixture.port_path(session).exists(),
            "detached session should publish a port file"
        );
        let registry = read_registry(&fixture.registry_path(session))
            .expect("detached session should publish registry json");
        assert_eq!(
            registry["session"].as_str(),
            Some(fixture.base(session).as_str())
        );
        assert_eq!(registry["state"].as_str(), Some("ready"));
        assert!(
            registry["server_pid"].as_u64().is_some_and(|pid| pid > 0),
            "registry must include server_pid: {registry:?}"
        );
        assert!(
            registry["instance_nonce"]
                .as_str()
                .is_some_and(|nonce| !nonce.trim().is_empty()),
            "registry must include instance_nonce: {registry:?}"
        );
        assert!(
            registry["ready_at"].as_u64().is_some(),
            "registry must include ready_at after startup: {registry:?}"
        );

        let has_session = fixture.run(&["-L", &fixture.namespace, "-t", session, "has-session"]);
        assert!(
            has_session.status.success(),
            "has-session should authenticate and return success\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&has_session.stdout),
            String::from_utf8_lossy(&has_session.stderr)
        );

        let list_panes = fixture.run(&[
            "-L",
            &fixture.namespace,
            "-t",
            session,
            "list-panes",
            "-a",
            "-F",
            "#{pane_id} #{pane_pid} #{pane_current_command}",
        ]);
        let panes = String::from_utf8_lossy(&list_panes.stdout);
        assert!(
            list_panes.status.success() && !panes.trim().is_empty(),
            "list-panes should expose at least one pane\nstdout:\n{}\nstderr:\n{}",
            panes,
            String::from_utf8_lossy(&list_panes.stderr)
        );
    }

    fn read_registry(path: &Path) -> Option<Value> {
        let bytes = fs::read(path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn unique_id(prefix: &str) -> String {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        format!("{prefix}-{}-{millis}", std::process::id())
    }
}

#[cfg(not(windows))]
#[test]
fn session_contract_is_windows_only() {
    eprintln!("session readiness contract is Windows-only");
}
