use std::io::{self, Write};
use std::process::ExitCode;
#[cfg(not(target_os = "linux"))]
use winsmux_remote_helper::serve_stdio;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.as_slice() != ["serve", "--stdio"] {
        let _ = writeln!(io::stderr(), "usage: winsmux-remote-helper serve --stdio");
        return ExitCode::from(2);
    }
    #[cfg(target_os = "linux")]
    let result = winsmux_remote_helper::session::serve_brokered_stdio();
    #[cfg(not(target_os = "linux"))]
    let result = serve_stdio(io::stdin().lock(), io::stdout().lock());
    if let Err(error) = result {
        let _ = writeln!(io::stderr(), "{error}");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}
