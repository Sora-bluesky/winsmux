use std::io::{self, Write};
use std::process::ExitCode;
use winsmux_remote_helper::serve_stdio;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.as_slice() != ["serve", "--stdio"] {
        let _ = writeln!(
            io::stderr(),
            "usage: winsmux-remote-helper serve --stdio"
        );
        return ExitCode::from(2);
    }
    if let Err(error) = serve_stdio(io::stdin().lock(), io::stdout().lock()) {
        let _ = writeln!(io::stderr(), "{error}");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}
