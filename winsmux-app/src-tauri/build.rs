use sha2::{Digest, Sha256};
use std::{env, fs, path::PathBuf};

fn main() {
    let triple = env::var("TARGET").expect("Cargo target triple");
    let sidecar = PathBuf::from("binaries").join(format!("winsmux-{triple}.exe"));
    println!("cargo:rerun-if-changed={}", sidecar.display());
    let digest = fs::read(&sidecar)
        .ok()
        .filter(|bytes| !bytes.is_empty())
        .map(|bytes| format!("{:x}", Sha256::digest(bytes)))
        .unwrap_or_default();
    let out = PathBuf::from(env::var("OUT_DIR").expect("Cargo OUT_DIR"));
    fs::write(
        out.join("workspace_companion_hash.rs"),
        format!("pub(crate) const WORKSPACE_COMPANION_SHA256: &str = {digest:?};\n"),
    )
    .expect("write companion hash");
    tauri_build::build();
    if triple.contains("-windows-") {
        println!("cargo:rustc-link-arg-tests={}", out.join("resource.lib").display());
    }
}
