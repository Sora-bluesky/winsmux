use serde::de::DeserializeOwned;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

pub fn read_text_fixture(repo_root: &Path, name: &str) -> String {
    let path = fixture_path(repo_root, name);
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read fixture {}: {}", path.display(), err))
}

#[allow(dead_code)]
pub fn read_json_fixture(repo_root: &Path, name: &str) -> Value {
    let raw = read_text_fixture(repo_root, name);
    serde_json::from_str(&raw)
        .unwrap_or_else(|err| panic!("failed to parse fixture {}: {}", fixture_path(repo_root, name).display(), err))
}

#[allow(dead_code)]
pub fn read_json_fixture_typed<T: DeserializeOwned>(repo_root: &Path, name: &str) -> T {
    let raw = read_text_fixture(repo_root, name);
    serde_json::from_str(&raw)
        .unwrap_or_else(|err| panic!("failed to parse typed fixture {}: {}", fixture_path(repo_root, name).display(), err))
}

#[allow(dead_code)]
pub fn read_jsonl_fixture_typed<T: DeserializeOwned>(repo_root: &Path, name: &str) -> Vec<T> {
    let path = fixture_path(repo_root, name);
    let raw = read_text_fixture(repo_root, name);
    raw.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line).unwrap_or_else(|err| {
                panic!(
                    "failed to parse jsonl fixture {}: {}",
                    path.display(),
                    err
                )
            })
        })
        .collect()
}

fn fixture_path(repo_root: &Path, name: &str) -> PathBuf {
    repo_root
        .join("tests")
        .join("fixtures")
        .join("rust-parity")
        .join(name)
}
