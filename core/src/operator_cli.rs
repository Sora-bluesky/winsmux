use std::{
    env,
    io::{self, Write},
};

use crate::ledger::LedgerSnapshot;

pub fn run_board_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("usage: winsmux board --json");
        return Ok(());
    }

    if args.len() != 1 || args[0] != "--json" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "winsmux board currently supports only --json in the Rust CLI",
        ));
    }

    let project_dir = env::current_dir()?;
    let snapshot = LedgerSnapshot::from_project_dir(&project_dir).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to load winsmux ledger: {err}"),
        )
    })?;
    let projection = snapshot.board_projection();

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, &projection).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize board projection: {err}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}

pub fn run_status_command(args: &[&String]) -> io::Result<()> {
    if args.iter().any(|arg| *arg == "-h" || *arg == "--help") {
        println!("usage: winsmux status --json");
        return Ok(());
    }

    if args.len() != 1 || args[0] != "--json" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "winsmux status currently supports only --json in the Rust CLI",
        ));
    }

    let project_dir = env::current_dir()?;
    let snapshot = LedgerSnapshot::from_project_dir(&project_dir).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to load winsmux ledger: {err}"),
        )
    })?;
    let status = serde_json::json!({
        "session": {
            "name": snapshot.session_name(),
            "pane_count": snapshot.pane_count(),
            "event_count": snapshot.event_count(),
        },
        "panes": snapshot.pane_read_models(),
    });

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, &status).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize status projection: {err}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}
