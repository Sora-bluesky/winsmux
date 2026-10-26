#[cfg(windows)]
mod windows_session_contract {
    use serde_json::Value;
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Mutex, MutexGuard};
    use std::thread;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    struct Fixture {
        _serial: MutexGuard<'static, ()>,
        exe: PathBuf,
        home: PathBuf,
        namespace: String,
        extra_namespaces: Vec<String>,
    }

    impl Fixture {
        fn new() -> Self {
            // Keep the shell baseline and pane startup measurements free from
            // concurrent sessions created by this test target.
            static SESSION_CONTRACT_SERIAL: Mutex<()> = Mutex::new(());
            let serial = SESSION_CONTRACT_SERIAL
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            let exe = PathBuf::from(
                env::var("CARGO_BIN_EXE_winsmux")
                    .expect("cargo should expose CARGO_BIN_EXE_winsmux"),
            );
            let unique = unique_id("session-contract");
            let home = env::temp_dir().join(&unique);
            fs::create_dir_all(home.join(".psmux")).expect("fixture should create .psmux");
            fs::write(
                home.join("fixture.conf"),
                "set -g default-shell cmd.exe\nset -g default-command 'cmd.exe /D /Q'\n",
            )
            .expect("fixture should select a shell without user profiles");
            Self {
                _serial: serial,
                exe,
                home,
                namespace: unique.replace('-', "_"),
                extra_namespaces: Vec::new(),
            }
        }

        fn run(&self, args: &[&str]) -> Output {
            self.run_with_env(args, &[])
        }

        fn run_with_env(&self, args: &[&str], overrides: &[(&str, &str)]) -> Output {
            let mut command = Command::new(&self.exe);
            command
                .args(args)
                .current_dir(&self.home)
                .env("USERPROFILE", &self.home)
                .env("HOME", &self.home)
                .env("XDG_CONFIG_HOME", self.home.join(".config"))
                .env("LOCALAPPDATA", self.home.join("local"))
                .env("APPDATA", self.home.join("roaming"))
                .env("COMPUTERNAME", "winsmux-test-host")
                .env("HOSTNAME", "winsmux-test-host")
                .env("PSMUX_CONFIG_FILE", self.home.join("fixture.conf"))
                .env("PSMUX_NO_WARM", "1")
                .env("PSMUX_ALLOW_NESTING", "1")
                .env_remove("PSMUX_TARGET_SESSION")
                .env_remove("PSMUX_TARGET_FULL")
                .env_remove("PSMUX_ACTIVE")
                .env_remove("PSMUX_SESSION")
                .env_remove("TMUX")
                .envs(overrides.iter().copied());
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
            for namespace in std::iter::once(&self.namespace).chain(&self.extra_namespaces) {
                let _ = self.run(&["-L", namespace, "kill-server"]);
            }
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
        let registry = wait_for_registry(
            &fixture.registry_path(session),
            "contain valid JSON",
            |_| true,
        )
        .expect("detached session should publish registry json");
        assert_eq!(
            registry["session"].as_str(),
            Some(fixture.base(session).as_str())
        );
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

        let has_session = fixture.run(&["-L", &fixture.namespace, "-t", session, "has-session"]);
        assert!(
            has_session.status.success(),
            "has-session should authenticate and return success\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&has_session.stdout),
            String::from_utf8_lossy(&has_session.stderr)
        );

        let registry = wait_for_registry_state(&fixture.registry_path(session), "ready")
            .expect("has-session should leave registry in ready state");
        assert!(
            registry["ready_at"].as_u64().is_some(),
            "registry must include ready_at after startup: {registry:?}"
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

    fn wait_for_registry(
        path: &Path,
        expectation: &str,
        matches: impl Fn(&Value) -> bool,
    ) -> Result<Value, String> {
        let deadline = Instant::now() + Duration::from_secs(3);
        let poll_interval = Duration::from_millis(25);
        let mut attempts = 0;

        let last_diagnostic = loop {
            attempts += 1;
            let diagnostic = match fs::read(path) {
                Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                    Ok(registry) if matches(&registry) => return Ok(registry),
                    Ok(registry) => {
                        format!("valid JSON did not match ({})", registry_summary(&registry))
                    }
                    Err(error) => format!(
                        "JSON parse error at line {} column {}: {:?}",
                        error.line(),
                        error.column(),
                        error.classify()
                    ),
                },
                Err(error) => format!("I/O error ({:?}): {error}", error.kind()),
            };

            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break diagnostic;
            }
            thread::sleep(poll_interval.min(remaining));
        };

        Err(format!(
            "timed out waiting for registry path={} expectation={expectation:?} attempts={attempts}; last observation: {last_diagnostic}",
            path.display()
        ))
    }

    fn wait_for_registry_state(path: &Path, state: &str) -> Result<Value, String> {
        wait_for_registry(path, &format!("reach state {state:?}"), |registry| {
            registry["state"].as_str() == Some(state)
        })
    }

    fn registry_summary(registry: &Value) -> String {
        let session = registry["session"]
            .as_str()
            .unwrap_or("<missing-or-non-string>");
        let state = registry["state"]
            .as_str()
            .unwrap_or("<missing-or-non-string>");
        let server_pid = registry["server_pid"]
            .as_u64()
            .map_or_else(|| "<missing-or-non-u64>".to_string(), |pid| pid.to_string());
        format!("session={session:?}, state={state:?}, server_pid={server_pid}")
    }

    fn unique_id(prefix: &str) -> String {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        format!(
            "{prefix}-{}-{millis}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        )
    }

    mod compatibility {
        include!("legacy_cli_contract.rs");
    }
}

#[cfg(not(windows))]
#[test]
fn session_contract_is_windows_only() {
    eprintln!("session readiness contract is Windows-only");
}
