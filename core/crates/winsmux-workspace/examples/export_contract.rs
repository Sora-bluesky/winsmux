use std::{env, fs, path::Path};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().skip(1).collect();
    if !args.is_empty() && args != ["--check"] {
        return Err("usage: export_contract [--check]".into());
    }
    let check = !args.is_empty();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap();
    if check {
        return winsmux_workspace::contract::projection::check_artifacts(|name| {
            fs::read(root.join(name)).ok()
        })
        .map_err(|paths| {
            for name in paths {
                eprintln!("contract projection differs: {name}");
            }
            "contract projections are not current".into()
        });
    }
    for (name, bytes) in winsmux_workspace::contract::projection::artifacts() {
        let path = root.join(&name);
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, bytes)?;
        println!("generated {name}");
    }
    Ok(())
}
