use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let profiles = manifest_dir
        .join("..")
        .join("winsmux-core")
        .join("agents")
        .join("profiles");
    println!("cargo:rerun-if-changed={}", profiles.display());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let dest = out_dir.join("embedded_profiles.rs");
    let mut files = Vec::new();
    collect_files(&profiles, &profiles, &mut files);
    files.sort();
    let mut out = fs::File::create(&dest).expect("create embedded_profiles.rs");
    writeln!(
        out,
        "fn embedded_profile(rel: &str) -> Option<&'static str> {{"
    )
    .unwrap();
    writeln!(out, "    let normalized = rel.replace('\\\\', \"/\");").unwrap();
    writeln!(out, "    match normalized.as_str() {{").unwrap();
    for rel in &files {
        let abs = profiles
            .join(rel)
            .canonicalize()
            .expect("canonicalize profile");
        let rel_lit = rel.replace('\\', "/");
        writeln!(
            out,
            "        \"{}\" => Some(include_str!(r\"{}\")),",
            rel_lit,
            abs.display()
        )
        .unwrap();
        println!("cargo:rerun-if-changed={}", abs.display());
    }
    writeln!(out, "        _ => None,").unwrap();
    writeln!(out, "    }}").unwrap();
    writeln!(out, "}}").unwrap();
}

fn collect_files(root: &Path, dir: &Path, files: &mut Vec<String>) {
    for entry in fs::read_dir(dir).expect("read profiles") {
        let entry = entry.expect("profile entry");
        let path = entry.path();
        if path.is_dir() {
            collect_files(root, &path, files);
            continue;
        }
        let rel = path
            .strip_prefix(root)
            .expect("profile prefix")
            .to_string_lossy()
            .replace('\\', "/");
        files.push(rel);
    }
}
