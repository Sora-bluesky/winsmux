use std::io;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HeadlessServerConfig {
    pub(crate) session_name: String,
    pub(crate) socket_name: Option<String>,
    pub(crate) initial_command: Option<String>,
    pub(crate) raw_command: Option<Vec<String>>,
    pub(crate) start_dir: Option<String>,
    pub(crate) window_name: Option<String>,
    pub(crate) initial_width: Option<u16>,
    pub(crate) initial_height: Option<u16>,
    pub(crate) group_target: Option<String>,
}

impl Default for HeadlessServerConfig {
    fn default() -> Self {
        Self {
            session_name: "default".to_string(),
            socket_name: None,
            initial_command: None,
            raw_command: None,
            start_dir: None,
            window_name: None,
            initial_width: None,
            initial_height: None,
            group_target: None,
        }
    }
}

impl HeadlessServerConfig {
    pub(crate) fn initial_size(&self) -> Option<(u16, u16)> {
        initial_size_from_parts(self.initial_width, self.initial_height)
    }

    pub(crate) fn warm(socket_name: Option<String>, initial_size: Option<(u16, u16)>) -> Self {
        let (initial_width, initial_height) = initial_size
            .map(|(width, height)| (Some(width), Some(height)))
            .unwrap_or((None, None));

        Self {
            session_name: "__warm__".to_string(),
            socket_name,
            initial_width,
            initial_height,
            ..Self::default()
        }
    }
}

pub(crate) fn parse_headless_server_config(args: &[String]) -> HeadlessServerConfig {
    let width = flag_value(args, "-x").and_then(|value| value.parse::<u16>().ok());
    let height = flag_value(args, "-y").and_then(|value| value.parse::<u16>().ok());

    HeadlessServerConfig {
        session_name: flag_value(args, "-s").unwrap_or_else(|| "default".to_string()),
        socket_name: flag_value(args, "-L"),
        initial_command: flag_value(args, "-c"),
        raw_command: raw_command_after_separator(args),
        start_dir: flag_value(args, "-d"),
        window_name: flag_value(args, "-n"),
        initial_width: width,
        initial_height: height,
        group_target: flag_value(args, "-g"),
    }
}

pub(crate) fn build_headless_server_args(config: &HeadlessServerConfig) -> Vec<String> {
    let mut args = vec![
        "server".to_string(),
        "-s".to_string(),
        config.session_name.clone(),
    ];

    push_flag_value(&mut args, "-L", config.socket_name.as_deref());
    push_flag_value(&mut args, "-c", config.initial_command.as_deref());
    push_flag_value(&mut args, "-d", config.start_dir.as_deref());
    push_flag_value(&mut args, "-n", config.window_name.as_deref());
    push_flag_value(
        &mut args,
        "-x",
        config.initial_width.as_ref().map(u16::to_string).as_deref(),
    );
    push_flag_value(
        &mut args,
        "-y",
        config
            .initial_height
            .as_ref()
            .map(u16::to_string)
            .as_deref(),
    );
    push_flag_value(&mut args, "-g", config.group_target.as_deref());

    if let Some(raw_command) = &config.raw_command {
        args.push("--".to_string());
        args.extend(raw_command.iter().cloned());
    }

    args
}

pub(crate) fn run_headless_server(config: HeadlessServerConfig) -> io::Result<()> {
    let initial_size = config.initial_size();

    crate::server::run_server(
        config.session_name,
        config.socket_name,
        config.initial_command,
        config.raw_command,
        config.start_dir,
        config.window_name,
        initial_size,
        config.group_target,
    )
}

pub(crate) fn spawn_headless_server(config: &HeadlessServerConfig) -> io::Result<()> {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("psmux"));
    let args = build_headless_server_args(config);
    spawn_headless_server_process(&exe, &args)
}

fn flag_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .take_while(|arg| arg.as_str() != "--")
        .position(|arg| arg == flag)
        .and_then(|index| args.get(index + 1))
        .cloned()
}

fn push_flag_value(args: &mut Vec<String>, flag: &str, value: Option<&str>) {
    if let Some(value) = value {
        args.push(flag.to_string());
        args.push(value.to_string());
    }
}

fn raw_command_after_separator(args: &[String]) -> Option<Vec<String>> {
    args.iter()
        .position(|arg| arg == "--")
        .map(|index| args.iter().skip(index + 1).cloned().collect::<Vec<_>>())
        .filter(|items| !items.is_empty())
}

fn initial_size_from_parts(width: Option<u16>, height: Option<u16>) -> Option<(u16, u16)> {
    match (width, height) {
        (Some(width), Some(height)) => Some((width, height)),
        (Some(width), None) => Some((width, 24)),
        (None, Some(height)) => Some((80, height)),
        _ => None,
    }
}

#[cfg(windows)]
fn spawn_headless_server_process(exe: &std::path::Path, args: &[String]) -> io::Result<()> {
    crate::platform::spawn_server_hidden(exe, args)
}

#[cfg(not(windows))]
fn spawn_headless_server_process(exe: &std::path::Path, args: &[String]) -> io::Result<()> {
    let mut cmd = std::process::Command::new(exe);
    for arg in args {
        cmd.arg(arg);
    }
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());
    let _child = cmd.spawn().map_err(|err| {
        io::Error::new(
            io::ErrorKind::Other,
            format!("failed to spawn server: {err}"),
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        build_headless_server_args, initial_size_from_parts, parse_headless_server_config,
        HeadlessServerConfig,
    };

    fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| item.to_string()).collect()
    }

    #[test]
    fn parse_headless_config_defaults_session_name() {
        let config = parse_headless_server_config(&args(&["winsmux", "server"]));
        assert_eq!(config.session_name, "default");
        assert_eq!(config.initial_size(), None);
        assert_eq!(config.raw_command, None);
    }

    #[test]
    fn parse_headless_config_reads_server_flags() {
        let config = parse_headless_server_config(&args(&[
            "winsmux", "server", "-s", "work", "-L", "ops", "-c", "pwsh", "-d", "C:/repo", "-n",
            "main", "-x", "120", "-y", "40", "-g", "shared",
        ]));

        assert_eq!(config.session_name, "work");
        assert_eq!(config.socket_name.as_deref(), Some("ops"));
        assert_eq!(config.initial_command.as_deref(), Some("pwsh"));
        assert_eq!(config.start_dir.as_deref(), Some("C:/repo"));
        assert_eq!(config.window_name.as_deref(), Some("main"));
        assert_eq!(config.initial_size(), Some((120, 40)));
        assert_eq!(config.group_target.as_deref(), Some("shared"));
    }

    #[test]
    fn parse_headless_config_keeps_raw_command_after_separator() {
        let config = parse_headless_server_config(&args(&[
            "winsmux", "server", "-s", "work", "--", "pwsh", "-NoLogo", "-x", "200",
        ]));

        assert_eq!(
            config.raw_command,
            Some(vec![
                "pwsh".to_string(),
                "-NoLogo".to_string(),
                "-x".to_string(),
                "200".to_string()
            ])
        );
        assert_eq!(config.initial_size(), None);
    }

    #[test]
    fn initial_size_keeps_legacy_fallbacks() {
        assert_eq!(initial_size_from_parts(Some(100), None), Some((100, 24)));
        assert_eq!(initial_size_from_parts(None, Some(30)), Some((80, 30)));
        assert_eq!(initial_size_from_parts(None, None), None);
    }

    #[test]
    fn build_headless_args_keeps_only_provided_size_flags() {
        let config = HeadlessServerConfig {
            session_name: "work".to_string(),
            initial_width: Some(100),
            ..HeadlessServerConfig::default()
        };

        assert_eq!(
            build_headless_server_args(&config),
            vec!["server", "-s", "work", "-x", "100"]
        );
    }

    #[test]
    fn build_headless_args_keeps_raw_command_after_separator() {
        let config = HeadlessServerConfig {
            session_name: "work".to_string(),
            socket_name: Some("ops".to_string()),
            raw_command: Some(vec!["pwsh".to_string(), "-NoLogo".to_string()]),
            ..HeadlessServerConfig::default()
        };

        assert_eq!(
            build_headless_server_args(&config),
            vec!["server", "-s", "work", "-L", "ops", "--", "pwsh", "-NoLogo"]
        );
    }

    #[test]
    fn warm_config_sets_session_socket_and_size() {
        let config = HeadlessServerConfig::warm(Some("ops".to_string()), Some((120, 30)));

        assert_eq!(
            build_headless_server_args(&config),
            vec!["server", "-s", "__warm__", "-L", "ops", "-x", "120", "-y", "30"]
        );
    }

    #[test]
    fn warm_config_allows_missing_size() {
        let config = HeadlessServerConfig::warm(Some("ops".to_string()), None);

        assert_eq!(
            build_headless_server_args(&config),
            vec!["server", "-s", "__warm__", "-L", "ops"]
        );
    }
}
