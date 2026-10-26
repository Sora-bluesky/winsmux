use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use winsmux_workspace::auth::testing::Harness;
use winsmux_workspace::contract::{parse_request, OperationClass, OperationName};

pub struct Scratch(pub PathBuf);
impl Scratch {
    pub fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!("{label}-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("remove owned acceptance scratch");
    }
}
pub fn request(h: &Harness, operation: &str, params: Value) -> winsmux_workspace::contract::Request {
    let name: OperationName = serde_json::from_value(json!(operation)).unwrap();
    let revision = if name.class() == OperationClass::T {
        json!(h.authorization().testing_counters().1)
    } else { Value::Null };
    parse_request(&serde_json::to_vec(&json!({
        "schema_version": 1, "instance_id": h.instance_id(),
        "operation_id": uuid::Uuid::new_v4().to_string(),
        "expected_topology_revision": revision, "operation": operation, "params": params
    })).unwrap()).unwrap()
}
pub fn owner(h: &Harness, operation: &str, params: Value) -> Value {
    serde_json::to_value(h.owner(&request(h, operation, params))).unwrap()
}
pub fn accepted(response: &Value) -> &Value {
    assert_eq!(response["accepted"], true, "{response}");
    assert!(response["error"].is_null(), "{response}");
    &response["result"]["data"]
}
pub fn snapshot(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn visit(root: &Path, dir: &Path, result: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for item in fs::read_dir(dir).unwrap() {
            let item = item.unwrap();
            assert!(!item.file_type().unwrap().is_symlink());
            if item.file_type().unwrap().is_dir() { visit(root, &item.path(), result); }
            else { result.insert(item.path().strip_prefix(root).unwrap().to_owned(), fs::read(item.path()).unwrap()); }
        }
    }
    let mut result = BTreeMap::new();
    visit(root, root, &mut result);
    result
}
