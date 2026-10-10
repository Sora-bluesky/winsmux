fn main() {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    let result = if arguments.len() != 2 || arguments[0] != "--discovery-json" {
        Err(winsmux_workspace::host::HostError::Usage)
    } else {
        arguments[1].to_str().ok_or(winsmux_workspace::host::HostError::Protocol)
            .and_then(|text| winsmux_workspace_mcp::parse_discovery(text.as_bytes())
                .map_err(|_| winsmux_workspace::host::HostError::Protocol))
            .and_then(winsmux_workspace_mcp::runtime::run_stdio)
    };
    if let Err(error) = result {
        eprintln!("winsmux workspace mcp: {}", error.classification());
        std::process::exit(if matches!(error, winsmux_workspace::host::HostError::Usage) { 2 } else { 1 });
    }
}
