use serde::de::DeserializeOwned;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

pub fn read_json_fixture(repo_root: &Path, name: &str) -> Value {
    let path = fixture_path(repo_root, name);
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read fixture {}: {}", path.display(), err));
    serde_json::from_str(&raw)
        .unwrap_or_else(|err| panic!("failed to parse fixture {}: {}", path.display(), err))
}

#[allow(dead_code)]
pub fn read_json_fixture_typed<T: DeserializeOwned>(repo_root: &Path, name: &str) -> T {
    let path = fixture_path(repo_root, name);
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read fixture {}: {}", path.display(), err));
    serde_json::from_str(&raw)
        .unwrap_or_else(|err| panic!("failed to parse typed fixture {}: {}", path.display(), err))
}

fn fixture_path(repo_root: &Path, name: &str) -> PathBuf {
    repo_root
        .join("tests")
        .join("fixtures")
        .join("rust-parity")
        .join(name)
}
