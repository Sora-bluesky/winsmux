use std::fs;
use std::path::PathBuf;

use clap::Parser;
use git_graph::commit::{read_repo_commits, read_stdin_log};
use git_graph::lane::assign_lanes;
use git_graph::layout::build_layout;
use git_graph::render::render_svg;

#[derive(Debug, Parser)]
#[command(name = "git-graph")]
#[command(about = "Render a VS Code-style Git history graph as SVG.")]
struct Args {
    #[arg(long, default_value = ".")]
    repo: PathBuf,

    #[arg(long, default_value_t = 50)]
    max: usize,

    #[arg(long)]
    out: Option<PathBuf>,

    #[arg(long)]
    from_stdin: bool,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let mut commits = if args.from_stdin {
        read_stdin_log()?
    } else {
        read_repo_commits(&args.repo, args.max)?
    };

    commits.truncate(args.max);
    let head_id = commits.first().map(|commit| commit.id.as_str());
    let rows = assign_lanes(&commits);
    let layout = build_layout(rows);
    let svg = render_svg(&layout, head_id);

    if let Some(out) = args.out {
        fs::write(out, svg)?;
    } else {
        print!("{svg}");
    }

    Ok(())
}
