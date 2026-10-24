#![cfg(all(windows, debug_assertions))]

use serde_json::{json, Value};
use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, GENERIC_WRITE, HANDLE,
    INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, GetFileAttributesW, SetFileAttributesW,
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_READONLY, FILE_ATTRIBUTE_REPARSE_POINT,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::Threading::WaitForSingleObject;
use winsmux_workspace::contract::{parse_request, Request};
use winsmux_workspace::host::ProductHost;
use winsmux_workspace::memory_testing::{
    classify_path_syntax, observe_root, paths_are_windows_aliases, testing_probe_volumes,
    AllocationPool, ObserveError,
};

const LOCK_PATH_ENV: &str = "WINSMUX_TASK863_P01_LOCK_PATH";
const LOCK_READY_ENV: &str = "WINSMUX_TASK863_P01_LOCK_READY";
const LOCK_RELEASE_ENV: &str = "WINSMUX_TASK863_P01_LOCK_RELEASE";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const FILE_READ_ATTRIBUTES: u32 = 0x0080;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const SYNCHRONIZE: u32 = 0x0010_0000;
const LOCK_ACCESS: u32 = FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE;
const LOCK_SHARE: u32 = 0;
const LOCK_FLAGS: u32 = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT;
const FILE_ATTRIBUTE_RECALL_ON_OPEN: u32 = 0x0004_0000;
const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: u32 = 0x0040_0000;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
const DRIVE_REMOTE: u32 = 4;
const ERROR_ALREADY_EXISTS: u32 = 183;
const FIXTURE_PREFIX: &str = "winsmux-863-p01-";

fn next_operation_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!(
        "20000000-0000-4000-8000-{:012x}",
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

fn request(
    operation: &str,
    instance: Option<&str>,
    revision: Option<u64>,
    params: Value,
) -> Request {
    parse_request(
        &serde_json::to_vec(&json!({
            "schema_version": 1,
            "instance_id": instance,
            "operation_id": next_operation_id(),
            "expected_topology_revision": revision,
            "operation": operation,
            "params": params,
        }))
        .expect("json"),
    )
    .unwrap_or_else(|error| panic!("{operation}: {error}"))
}

fn value(response: &winsmux_workspace::Response) -> Value {
    serde_json::to_value(response).expect("json")
}

fn instance_of(host: &ProductHost) -> String {
    serde_json::to_value(host.instance_id())
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .expect("instance")
}

fn evidence_dir() -> PathBuf {
    let dir = std::env::var_os("WINSMUX_TEST_EVIDENCE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("verification-evidence")
        });
    fs::create_dir_all(&dir).expect("evidence dir");
    dir
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn strip_verbatim(path: &str) -> String {
    path.strip_prefix(r"\\?\")
        .or_else(|| path.strip_prefix("//?/"))
        .unwrap_or(path)
        .replace('/', "\\")
}

fn to_verbatim(path: &Path) -> PathBuf {
    let text = path_text(path);
    if text.starts_with(r"\\?\") || text.starts_with("//?/") {
        PathBuf::from(text)
    } else {
        PathBuf::from(format!(r"\\?\{}", strip_verbatim(&text)))
    }
}

fn wide_null(path: &Path) -> Vec<u16> {
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

fn error_code(body: &Value) -> Option<&str> {
    body.get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str)
}

fn accepted(body: &Value) -> bool {
    body.get("accepted") == Some(&json!(true))
}

fn project_id_of(body: &Value) -> Option<String> {
    body.pointer("/result/data/project_id")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn created_of(body: &Value) -> Option<bool> {
    body.pointer("/result/data/created").and_then(Value::as_bool)
}

fn revision_of(body: &Value) -> Option<u64> {
    body.get("topology_revision").and_then(Value::as_u64)
}

fn list_rows(body: &Value) -> &[Value] {
    body.pointer("/result/data/projects")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn selected_of(body: &Value) -> Value {
    body.pointer("/result/data/selected_project_id")
        .cloned()
        .unwrap_or(Value::Null)
}

fn owner_open(
    host: &ProductHost,
    inst: &str,
    revision: u64,
    path: &str,
) -> Result<Value, String> {
    match host.owner_request(&request(
        "project.open",
        Some(inst),
        Some(revision),
        json!({ "path": path }),
    )) {
        Ok(response) => Ok(value(&response)),
        Err(error) => Err(format!("owner_request transport: {error:?}")),
    }
}

fn owner_list(host: &ProductHost, inst: &str) -> Result<Value, String> {
    match host.owner_request(&request("project.list", Some(inst), None, json!({}))) {
        Ok(response) => Ok(value(&response)),
        Err(error) => Err(format!("owner_request transport: {error:?}")),
    }
}

fn owner_select(
    host: &ProductHost,
    inst: &str,
    revision: u64,
    project_id: &Value,
) -> Result<Value, String> {
    match host.owner_request(&request(
        "project.select",
        Some(inst),
        Some(revision),
        json!({ "project_id": project_id }),
    )) {
        Ok(response) => Ok(value(&response)),
        Err(error) => Err(format!("owner_request transport: {error:?}")),
    }
}

fn owner_forget(
    host: &ProductHost,
    inst: &str,
    revision: u64,
    project_id: &str,
) -> Result<Value, String> {
    match host.owner_request(&request(
        "project.forget",
        Some(inst),
        Some(revision),
        json!({ "project_id": project_id }),
    )) {
        Ok(response) => Ok(value(&response)),
        Err(error) => Err(format!("owner_request transport: {error:?}")),
    }
}

fn native_attributes(path: &Path) -> Result<u32, u32> {
    let wide = wide_null(path);
    let attrs = unsafe { GetFileAttributesW(wide.as_ptr()) };
    if attrs == INVALID_FILE_ATTRIBUTES {
        Err(unsafe { GetLastError() })
    } else {
        Ok(attrs)
    }
}

fn native_create_file_in(dir: &Path, name: &str) -> (i32, String) {
    let file = dir.join(name);
    match fs::write(&file, b"p01-write-probe") {
        Ok(()) => {
            let _ = fs::remove_file(&file);
            (0, "write_succeeded".to_owned())
        }
        Err(error) => (
            error.raw_os_error().unwrap_or(-1),
            format!("{error}"),
        ),
    }
}

fn native_open_directory(path: &Path, access: u32, share: u32, flags: u32) -> Result<HANDLE, u32> {
    let wide = wide_null(path);
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            access,
            share,
            std::ptr::null(),
            OPEN_EXISTING,
            flags,
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        Err(unsafe { GetLastError() })
    } else {
        Ok(handle)
    }
}

fn create_dir_w(path: &Path) -> Result<(), u32> {
    let wide = wide_null(path);
    let ok = unsafe { CreateDirectoryW(wide.as_ptr(), std::ptr::null()) };
    if ok != 0 {
        Ok(())
    } else {
        let gle = unsafe { GetLastError() };
        if gle == ERROR_ALREADY_EXISTS {
            Ok(())
        } else {
            Err(gle)
        }
    }
}

fn axis(id: &str, expected: Value, actual: Value, status: &str, reason: &str) -> Value {
    json!({
        "id": id,
        "expected": expected,
        "actual": actual,
        "status": status,
        "reason": reason,
    })
}

fn status_from(ok: bool) -> &'static str {
    if ok {
        "pass"
    } else {
        "fail"
    }
}

struct Evidence {
    path: PathBuf,
    axes: Vec<Value>,
}

impl Evidence {
    fn new() -> Self {
        Self {
            path: evidence_dir().join("observations.json"),
            axes: Vec::new(),
        }
    }

    fn push(&mut self, row: Value) {
        eprintln!(
            "P01 axis {} status={}",
            row["id"].as_str().unwrap_or("?"),
            row["status"].as_str().unwrap_or("?")
        );
        self.axes.push(row);
        self.flush();
    }

    fn flush(&self) {
        let body = json!({
            "task": "TASK-863.P01",
            "axes": self.axes,
        });
        let encoded = serde_json::to_vec_pretty(&body).expect("observations json");
        fs::write(&self.path, encoded).expect("write observations");
    }

    fn failed(&self) -> Vec<String> {
        self.axes
            .iter()
            .filter(|row| row["status"] == json!("fail"))
            .filter_map(|row| row["id"].as_str().map(str::to_owned))
            .collect()
    }
}

struct Fixture {
    root: PathBuf,
    token: String,
}

impl Fixture {
    fn create() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time")
            .as_nanos();
        let token = format!("p01-{stamp}");
        let root = std::env::temp_dir().join(format!("{FIXTURE_PREFIX}{stamp}"));
        fs::create_dir_all(&root).expect("fixture root");
        fs::write(root.join("OWNER.txt"), token.as_bytes()).expect("owner marker");
        let absolute = fs::canonicalize(&root).unwrap_or_else(|_| root.clone());
        Self {
            root: absolute,
            token,
        }
    }

    fn child(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::create_dir_all(&path).expect("child dir");
        path
    }

    fn owned_for_cleanup(&self, path: &Path) -> Result<(), String> {
        if !path.is_absolute() {
            return Err(format!("not absolute: {}", path.display()));
        }
        let path_norm = strip_verbatim(&path_text(path)).to_ascii_lowercase();
        let root_norm = strip_verbatim(&path_text(&self.root)).to_ascii_lowercase();
        if !path_norm.starts_with(&root_norm) {
            return Err(format!(
                "path {} is outside fixture {}",
                path.display(),
                self.root.display()
            ));
        }
        if !root_norm.contains(&FIXTURE_PREFIX.to_ascii_lowercase()) {
            return Err("fixture prefix missing from root".to_owned());
        }
        let marker = self.root.join("OWNER.txt");
        let text = fs::read_to_string(&marker).map_err(|error| format!("marker: {error}"))?;
        if text != self.token {
            return Err("owner marker mismatch".to_owned());
        }
        Ok(())
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        match self.owned_for_cleanup(&self.root) {
            Ok(()) => {
                if let Err(error) = fs::remove_dir_all(&self.root) {
                    let verbatim = to_verbatim(&self.root);
                    if let Err(second) = fs::remove_dir_all(&verbatim) {
                        eprintln!(
                            "fixture cleanup failed root={} first={error} verbatim={second}",
                            self.root.display()
                        );
                    }
                }
            }
            Err(reason) => {
                eprintln!(
                    "skip fixture cleanup root={} reason={reason}",
                    self.root.display()
                );
            }
        }
    }
}

fn run_lock_helper() {
    let path = std::env::var(LOCK_PATH_ENV).expect("lock path");
    let ready = PathBuf::from(std::env::var(LOCK_READY_ENV).expect("ready path"));
    let release = PathBuf::from(std::env::var(LOCK_RELEASE_ENV).expect("release path"));
    let wide: Vec<u16> = Path::new(&path)
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            LOCK_ACCESS,
            LOCK_SHARE,
            std::ptr::null(),
            OPEN_EXISTING,
            LOCK_FLAGS,
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        let gle = unsafe { GetLastError() };
        let _ = fs::write(
            &ready,
            format!("open_failed gle={gle} access=0x{LOCK_ACCESS:08X} share=0x{LOCK_SHARE:08X} flags=0x{LOCK_FLAGS:08X}\n"),
        );
        std::process::exit(2);
    }
    let body = format!(
        "held pid={} handle={handle:?} access=0x{LOCK_ACCESS:08X} share=0x{LOCK_SHARE:08X} flags=0x{LOCK_FLAGS:08X} disposition=OPEN_EXISTING path={path}\n",
        std::process::id()
    );
    fs::write(&ready, body.as_bytes()).expect("ready file");
    let deadline = Instant::now() + Duration::from_secs(90);
    while !release.exists() {
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    unsafe {
        let _ = CloseHandle(handle);
    }
}

struct ProcessLock {
    child: std::process::Child,
    pid: u32,
    process: HANDLE,
    ready_text: String,
    release: PathBuf,
}

impl ProcessLock {
    fn spawn(dir: &Path, fixture: &Fixture) -> Result<Self, String> {
        let ready = fixture.root.join("lock-ready.txt");
        let release = fixture.root.join("lock-release.txt");
        let _ = fs::remove_file(&ready);
        let _ = fs::remove_file(&release);
        let exe = std::env::current_exe().map_err(|error| format!("current_exe: {error}"))?;
        let mut child = Command::new(&exe)
            .args([
                "--exact",
                "windows_path_identity_axes",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(LOCK_PATH_ENV, path_text(dir))
            .env(LOCK_READY_ENV, path_text(&ready))
            .env(LOCK_RELEASE_ENV, path_text(&release))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|error| format!("spawn lock helper: {error}"))?;
        let pid = child.id();
        let process = child.as_raw_handle() as HANDLE;
        let deadline = Instant::now() + Duration::from_secs(20);
        let ready_text = loop {
            if let Ok(text) = fs::read_to_string(&ready) {
                if !text.is_empty() {
                    break text;
                }
            }
            match unsafe { WaitForSingleObject(process, 0) } {
                WAIT_OBJECT_0 => {
                    let status = child.try_wait().ok().flatten();
                    return Err(format!(
                        "lock helper exited before ready pid={pid} status={status:?} ready_exists={}",
                        ready.exists()
                    ));
                }
                WAIT_TIMEOUT => {}
                other => {
                    return Err(format!(
                        "WaitForSingleObject on helper process returned {other} gle={}",
                        unsafe { GetLastError() }
                    ));
                }
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                return Err(format!("lock helper ready timeout pid={pid}"));
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        if ready_text.starts_with("open_failed") {
            let _ = child.kill();
            return Err(ready_text);
        }
        Ok(Self {
            child,
            pid,
            process,
            ready_text,
            release,
        })
    }

    fn still_running(&self) -> Result<(), String> {
        match unsafe { WaitForSingleObject(self.process, 0) } {
            WAIT_TIMEOUT => Ok(()),
            WAIT_OBJECT_0 => Err(format!("lock helper pid={} already exited", self.pid)),
            other => Err(format!(
                "lock helper wait {other} gle={}",
                unsafe { GetLastError() }
            )),
        }
    }

    fn release(mut self) {
        let _ = fs::write(&self.release, b"release\n");
        let _ = self.child.wait();
    }
}

fn probe_unc(local: &Path) -> Value {
    let local_text = strip_verbatim(&path_text(local));
    let bytes = local_text.as_bytes();
    let mut probes = vec![json!({
        "kind": "syntax",
        "sample": r"\\server\share\dir",
        "classify": format!("{:?}", classify_path_syntax(r"\\server\share\dir")),
    })];
    if bytes.len() >= 3 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
        let drive = (bytes[0] as char).to_ascii_uppercase();
        let rest = &local_text[2..];
        let admin = format!(r"\\localhost\{drive}${rest}");
        let wide: Vec<u16> = admin.encode_utf16().chain(Some(0)).collect();
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS,
                std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
            )
        };
        let gle = if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            unsafe { GetLastError() }
        } else {
            unsafe {
                let _ = CloseHandle(handle);
            }
            0
        };
        probes.push(json!({
            "kind": "localhost_admin_share",
            "path": admin,
            "createfilew_gle": gle,
            "opened": gle == 0,
        }));
    }
    let remote_volumes: Vec<Value> = testing_probe_volumes()
        .into_iter()
        .filter(|volume| volume.drive_type == DRIVE_REMOTE)
        .map(|volume| {
            json!({
                "letter": volume.letter.to_string(),
                "drive_type": volume.drive_type,
                "dos_device": volume.dos_device,
                "subst": volume.subst,
            })
        })
        .collect();
    probes.push(json!({
        "kind": "remote_volumes",
        "count": remote_volumes.len(),
        "volumes": remote_volumes,
    }));
    json!(probes)
}

fn sample_onedrive_placeholder() -> Value {
    let keys = ["OneDrive", "OneDriveConsumer", "OneDriveCommercial"];
    let mut found = Vec::new();
    let mut scanned = 0u32;
    let mut roots: Vec<(String, PathBuf)> = Vec::new();
    for key in keys {
        if let Some(root) = std::env::var_os(key) {
            roots.push((key.to_owned(), PathBuf::from(root)));
        }
    }
    if let Some(profile) = std::env::var_os("USERPROFILE") {
        let candidate = PathBuf::from(profile).join("OneDrive");
        if !roots.iter().any(|(_, path)| path == &candidate) {
            roots.push(("USERPROFILE/OneDrive".to_owned(), candidate));
        }
    }
    for (key, root) in roots {
        if !root.is_dir() {
            found.push(json!({
                "env": key,
                "path": path_text(&root),
                "exists": false,
            }));
            continue;
        }
        let root_attrs = native_attributes(&root).ok();
        found.push(json!({
            "env": key,
            "path": path_text(&root),
            "exists": true,
            "attributes": root_attrs,
            "placeholder": root_attrs.is_some_and(is_placeholder_dir),
        }));
        if root_attrs.is_some_and(is_placeholder_dir) {
            return json!({
                "available": true,
                "path": path_text(&root),
                "attributes": root_attrs,
                "source": key,
                "scanned_children": 0,
            });
        }
        if let Ok(entries) = fs::read_dir(&root) {
            for entry in entries.flatten().take(64) {
                scanned += 1;
                let path = entry.path();
                let Ok(attrs) = native_attributes(&path) else {
                    continue;
                };
                if attrs & FILE_ATTRIBUTE_DIRECTORY == 0 {
                    continue;
                }
                if is_placeholder_dir(attrs) {
                    return json!({
                        "available": true,
                        "path": path_text(&path),
                        "attributes": attrs,
                        "source": key,
                        "scanned_children": scanned,
                    });
                }
            }
        }
    }
    json!({
        "available": false,
        "roots": found,
        "scanned_children": scanned,
    })
}

fn is_placeholder_dir(attrs: u32) -> bool {
    attrs & FILE_ATTRIBUTE_DIRECTORY != 0
        && (attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0
            || attrs & FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS != 0
            || attrs & FILE_ATTRIBUTE_RECALL_ON_OPEN != 0)
}

fn create_long_directory(base: &Path) -> Result<(PathBuf, String, usize), (u32, String)> {
    let mut current = to_verbatim(base);
    let chunk = "L".repeat(72);
    for index in 0..12 {
        current.push(format!("{chunk}{index}"));
        if let Err(gle) = create_dir_w(&current) {
            return Err((
                gle,
                format!(
                    "CreateDirectoryW failed gle={gle} at {}",
                    current.display()
                ),
            ));
        }
        let logical = strip_verbatim(&path_text(&current));
        if utf16_len(&logical) > 260 {
            let units = utf16_len(&logical);
            return Ok((current, logical, units));
        }
    }
    Err((
        0,
        format!(
            "nested directories stayed <=260 utf16 units last={} len={}",
            current.display(),
            utf16_len(&strip_verbatim(&path_text(&current)))
        ),
    ))
}

fn case_alias(path: &str) -> Option<String> {
    let stripped = strip_verbatim(path);
    let mut chars: Vec<char> = stripped.chars().collect();
    if chars
        .first()
        .is_some_and(|ch| ch.is_ascii_alphabetic() && ch.is_ascii_uppercase())
    {
        chars[0] = chars[0].to_ascii_lowercase();
        let flipped: String = chars.into_iter().collect();
        if flipped != stripped {
            return Some(flipped);
        }
    }
    None
}

fn ascii_component_alias(path: &Path, component: &str) -> Option<String> {
    let text = path_text(path);
    let lower = component.to_ascii_lowercase();
    if lower == component {
        return None;
    }
    let flipped = text.replace(component, &lower);
    if flipped == text {
        None
    } else {
        Some(flipped)
    }
}

#[test]
fn windows_path_identity_axes() {
    if std::env::var_os(LOCK_PATH_ENV).is_some() {
        run_lock_helper();
        return;
    }

    let mut evidence = Evidence::new();
    let fixture = Fixture::create();
    let marker = b"folder-bytes-p01";

    let normal_dir = fixture.child("plain-normal");
    fs::write(normal_dir.join("marker.txt"), marker).expect("normal marker");
    let japanese_dir = fixture.child("プロジェクト 空白");
    fs::write(japanese_dir.join("marker.txt"), marker).expect("japanese marker");
    let sibling_dir = fixture.child("sibling-b");
    fs::write(sibling_dir.join("marker.txt"), marker).expect("sibling marker");
    let readonly_dir = fixture.child("readonly-dir");
    fs::write(readonly_dir.join("marker.txt"), marker).expect("readonly marker");
    let lock_dir = fixture.child("lock-dir");
    fs::write(lock_dir.join("marker.txt"), marker).expect("lock marker");
    let file_path = fixture.root.join("not-a-directory.txt");
    fs::write(&file_path, b"file").expect("file");
    let missing_path = fixture.root.join("missing-root");

    let normal_path = path_text(&normal_dir);
    let japanese_path = path_text(&japanese_dir);
    let sibling_path = path_text(&sibling_dir);
    let readonly_path = path_text(&readonly_dir);
    let lock_path = path_text(&lock_dir);
    let file_text = path_text(&file_path);
    let missing_text = path_text(&missing_path);

    let host = match ProductHost::start(Vec::new()) {
        Ok(host) => host,
        Err(error) => {
            evidence.push(axis(
                "product_host_start",
                json!("ProductHost::start succeeds on native Windows"),
                json!({ "error": format!("{error:?}") }),
                "fail",
                "native host boundary did not start",
            ));
            panic!("ProductHost::start failed: {error:?}");
        }
    };
    let inst = instance_of(&host);

    let empty = match owner_list(&host, &inst) {
        Ok(body) => body,
        Err(error) => {
            evidence.push(axis(
                "empty_list",
                json!({ "accepted": true, "projects": [] }),
                json!({ "error": error }),
                "fail",
                "empty project.list did not return a parsed response",
            ));
            let _ = host.shutdown();
            panic!("empty list failed: {error}");
        }
    };
    let empty_ok = accepted(&empty) && list_rows(&empty).is_empty() && selected_of(&empty).is_null();
    evidence.push(axis(
        "empty_list",
        json!({ "accepted": true, "projects": [], "selected_project_id": null }),
        json!({
            "accepted": empty["accepted"],
            "projects": empty.pointer("/result/data/projects"),
            "selected_project_id": selected_of(&empty),
            "response": empty,
        }),
        status_from(empty_ok),
        if empty_ok {
            "empty registry before registration"
        } else {
            "empty list shape mismatch"
        },
    ));

    let mut revision = 0u64;

    let opened_normal = match owner_open(&host, &inst, revision, &normal_path) {
        Ok(body) => body,
        Err(error) => {
            evidence.push(axis(
                "normal_path",
                json!({ "accepted": true, "created": true, "stable_id": true }),
                json!({ "error": error }),
                "fail",
                "normal path open crashed the host boundary",
            ));
            let _ = host.shutdown();
            panic!("normal open transport: {error}");
        }
    };
    let normal_id = project_id_of(&opened_normal);
    let normal_ok = accepted(&opened_normal)
        && created_of(&opened_normal) == Some(true)
        && normal_id.is_some();
    if let Some(next) = revision_of(&opened_normal) {
        revision = next;
    }
    evidence.push(axis(
        "normal_path",
        json!({
            "accepted": true,
            "created": true,
            "same_physical_folder_keeps_id": true
        }),
        json!({
            "accepted": opened_normal["accepted"],
            "created": opened_normal.pointer("/result/data/created"),
            "project_id": normal_id,
            "topology_revision": revision_of(&opened_normal),
            "response": opened_normal,
            "input_path": normal_path,
        }),
        status_from(normal_ok),
        if normal_ok {
            "drive-absolute ASCII folder registered through ProductHost.owner_request"
        } else {
            "normal path did not register"
        },
    ));
    let normal_id = normal_id.expect("normal id");

    let again_normal = owner_open(&host, &inst, revision, &normal_path).expect("reopen normal");
    let again_ok = accepted(&again_normal)
        && created_of(&again_normal) == Some(false)
        && project_id_of(&again_normal).as_deref() == Some(normal_id.as_str())
        && revision_of(&again_normal) == Some(revision);
    evidence.push(axis(
        "normal_path_idempotent",
        json!({ "created": false, "project_id": normal_id, "revision_unchanged": true }),
        json!({
            "created": again_normal.pointer("/result/data/created"),
            "project_id": project_id_of(&again_normal),
            "topology_revision": revision_of(&again_normal),
            "response": again_normal,
        }),
        status_from(again_ok),
        if again_ok {
            "re-open of the same folder kept the ID and revision"
        } else {
            "re-open changed identity or revision"
        },
    ));

    let native_jp = observe_root(&japanese_path, host.allocations(), AllocationPool::ActiveOwner);
    let native_jp_ok = native_jp.is_ok();
    let native_jp_text = match &native_jp {
        Ok(observed) => json!({
            "actual_path": observed.actual_path,
            "input_path": observed.input_path,
            "identity": format!("{:?}", observed.identity),
        }),
        Err(error) => json!({ "observe_error": format!("{error:?}") }),
    };
    drop(native_jp);

    let opened_jp = match owner_open(&host, &inst, revision, &japanese_path) {
        Ok(body) => body,
        Err(error) => {
            evidence.push(axis(
                "japanese_space",
                json!({ "accepted": true, "created": true, "distinct_from_sibling": true }),
                json!({ "error": error, "native": native_jp_text }),
                "fail",
                "japanese/space folder open crashed the host boundary",
            ));
            let _ = host.shutdown();
            panic!("japanese open transport: {error}");
        }
    };
    let japanese_id = project_id_of(&opened_jp);
    let jp_ok = accepted(&opened_jp)
        && created_of(&opened_jp) == Some(true)
        && japanese_id.as_deref().is_some_and(|id| id != normal_id)
        && native_jp_ok;
    if let Some(next) = revision_of(&opened_jp) {
        revision = next;
    }
    evidence.push(axis(
        "japanese_space",
        json!({
            "accepted": true,
            "created": true,
            "project_id_distinct_from_normal": true,
            "native_observe_ok": true
        }),
        json!({
            "accepted": opened_jp["accepted"],
            "created": opened_jp.pointer("/result/data/created"),
            "project_id": japanese_id,
            "normal_project_id": normal_id,
            "topology_revision": revision_of(&opened_jp),
            "native": native_jp_text,
            "response": opened_jp,
            "input_path": japanese_path,
        }),
        status_from(jp_ok),
        if jp_ok {
            "Japanese name with space registered through ProductHost.owner_request; native observe_root succeeded"
        } else {
            "japanese/space folder did not register as a distinct project"
        },
    ));
    let japanese_id = japanese_id.expect("japanese id");

    let slash = japanese_path.replace('\\', "/");
    let trailing = format!("{}\\", japanese_path.trim_end_matches(['\\', '/']));
    let verbatim = format!(r"\\?\{}", strip_verbatim(&japanese_path).trim_start_matches(r"\\?\"));
    let drive_case = case_alias(&japanese_path);
    let mut alias_fail = false;
    let mut alias_actual = Vec::new();
    for (label, alias) in [
        ("slash", slash.clone()),
        ("trailing_separator", trailing.clone()),
        ("verbatim", verbatim.clone()),
    ] {
        let body = owner_open(&host, &inst, revision, &alias).expect("alias open");
        let ok = accepted(&body)
            && created_of(&body) == Some(false)
            && project_id_of(&body).as_deref() == Some(japanese_id.as_str())
            && revision_of(&body) == Some(revision);
        if !ok {
            alias_fail = true;
        }
        alias_actual.push(json!({
            "label": label,
            "input": alias,
            "accepted": body["accepted"],
            "created": body.pointer("/result/data/created"),
            "project_id": project_id_of(&body),
            "topology_revision": revision_of(&body),
            "response": body,
            "ok": ok,
        }));
    }
    evidence.push(axis(
        "alias_slash_trailing_verbatim",
        json!({
            "created": false,
            "project_id": japanese_id,
            "revision_unchanged": true
        }),
        json!(alias_actual),
        status_from(!alias_fail),
        if alias_fail {
            "an alias opened as a different project or advanced revision"
        } else {
            "slash, trailing separator, and verbatim drive form mapped to the same project ID"
        },
    ));

    match drive_case {
        Some(alias) => {
            let body = owner_open(&host, &inst, revision, &alias).expect("drive case alias");
            let ok = accepted(&body)
                && created_of(&body) == Some(false)
                && project_id_of(&body).as_deref() == Some(japanese_id.as_str())
                && revision_of(&body) == Some(revision);
            evidence.push(axis(
                "alias_drive_letter_case",
                json!({ "created": false, "project_id": japanese_id }),
                json!({
                    "input": alias,
                    "accepted": body["accepted"],
                    "created": body.pointer("/result/data/created"),
                    "project_id": project_id_of(&body),
                    "topology_revision": revision_of(&body),
                    "response": body,
                    "windows_alias": paths_are_windows_aliases(&japanese_path, &alias),
                }),
                status_from(ok),
                if ok {
                    "drive-letter case alias mapped to the same project ID on this filesystem"
                } else {
                    "drive-letter case alias did not preserve identity"
                },
            ));
        }
        None => {
            evidence.push(axis(
                "alias_drive_letter_case",
                json!("case alias where legal on this filesystem"),
                json!({ "input": japanese_path, "reason": "drive letter was not an uppercase ASCII letter" }),
                "not_run",
                "case alias was not legal for this path string",
            ));
        }
    }

    let ascii_dir = fixture.child("CaseAlias");
    fs::write(ascii_dir.join("marker.txt"), marker).expect("case marker");
    let ascii_path = path_text(&ascii_dir);
    let opened_ascii = owner_open(&host, &inst, revision, &ascii_path).expect("ascii case open");
    if let Some(next) = revision_of(&opened_ascii) {
        revision = next;
    }
    let ascii_id = project_id_of(&opened_ascii);
    match ascii_component_alias(&ascii_dir, "CaseAlias") {
        Some(alias) => {
            let body = owner_open(&host, &inst, revision, &alias).expect("component case alias");
            let ok = accepted(&opened_ascii)
                && accepted(&body)
                && created_of(&body) == Some(false)
                && project_id_of(&body) == ascii_id
                && revision_of(&body) == Some(revision);
            evidence.push(axis(
                "alias_component_case",
                json!({ "created": false, "same_id_as_CaseAlias": true }),
                json!({
                    "original": ascii_path,
                    "alias": alias,
                    "original_open": opened_ascii,
                    "alias_open": body,
                    "windows_alias": paths_are_windows_aliases(&ascii_path, &alias),
                }),
                status_from(ok),
                if ok {
                    "ASCII component case alias mapped to the same project ID"
                } else {
                    "ASCII component case alias did not preserve identity"
                },
            ));
        }
        None => {
            evidence.push(axis(
                "alias_component_case",
                json!("component case alias where legal"),
                json!({ "path": ascii_path }),
                "not_run",
                "component case alias could not be formed",
            ));
        }
    }

    let opened_sibling = owner_open(&host, &inst, revision, &sibling_path).expect("sibling open");
    let sibling_id = project_id_of(&opened_sibling);
    let sibling_ok = accepted(&opened_sibling)
        && created_of(&opened_sibling) == Some(true)
        && sibling_id
            .as_deref()
            .is_some_and(|id| id != normal_id && id != japanese_id);
    if let Some(next) = revision_of(&opened_sibling) {
        revision = next;
    }
    evidence.push(axis(
        "sibling_distinct",
        json!({
            "accepted": true,
            "created": true,
            "id_distinct_from_normal_and_japanese": true
        }),
        json!({
            "response": opened_sibling,
            "sibling_id": sibling_id,
            "normal_id": normal_id,
            "japanese_id": japanese_id,
        }),
        status_from(sibling_ok),
        if sibling_ok {
            "distinct sibling directory received a different project ID"
        } else {
            "sibling directory collided with another project ID"
        },
    ));
    let sibling_id = sibling_id.expect("sibling id");

    let selected = owner_select(&host, &inst, revision, &json!(sibling_id)).expect("select sibling");
    if let Some(next) = revision_of(&selected) {
        revision = next;
    }
    let listed_after_select = owner_list(&host, &inst).expect("list after select");
    let select_ok = accepted(&selected)
        && selected.pointer("/result/data/selected_project_id") == Some(&json!(sibling_id))
        && selected_of(&listed_after_select) == json!(sibling_id)
        && list_rows(&listed_after_select)
            .iter()
            .any(|row| row["project_id"] == json!(normal_id))
        && list_rows(&listed_after_select)
            .iter()
            .any(|row| row["project_id"] == json!(japanese_id))
        && list_rows(&listed_after_select)
            .iter()
            .any(|row| row["project_id"] == json!(sibling_id));

    let forgotten = owner_forget(&host, &inst, revision, &japanese_id).expect("forget japanese");
    if let Some(next) = revision_of(&forgotten) {
        revision = next;
    }
    let listed_after_forget = owner_list(&host, &inst).expect("list after forget");
    let sibling_bytes = fs::read(sibling_dir.join("marker.txt")).expect("sibling bytes");
    let japanese_bytes = fs::read(japanese_dir.join("marker.txt")).expect("japanese bytes");
    let forget_ok = accepted(&forgotten)
        && selected_of(&listed_after_forget) == json!(sibling_id)
        && list_rows(&listed_after_forget)
            .iter()
            .all(|row| row["project_id"] != json!(japanese_id))
        && list_rows(&listed_after_forget)
            .iter()
            .any(|row| row["project_id"] == json!(sibling_id))
        && list_rows(&listed_after_forget)
            .iter()
            .any(|row| row["project_id"] == json!(normal_id))
        && sibling_bytes == marker
        && japanese_bytes == marker;
    evidence.push(axis(
        "select_forget_isolation",
        json!({
            "select_sibling_only": true,
            "forget_japanese_leaves_sibling_selected": true,
            "sibling_and_normal_ids_preserved": true,
            "folder_bytes_unchanged": true
        }),
        json!({
            "select": selected,
            "list_after_select": listed_after_select,
            "forget": forgotten,
            "list_after_forget": listed_after_forget,
            "sibling_marker_bytes": sibling_bytes,
            "japanese_marker_bytes": japanese_bytes,
        }),
        status_from(select_ok && forget_ok),
        if select_ok && forget_ok {
            "select and forget acted on the intended project; sibling ID, selection, and folder bytes stayed"
        } else {
            "select/forget leaked onto a sibling project or changed disk bytes"
        },
    ));

    let reopened_jp = owner_open(&host, &inst, revision, &japanese_path).expect("reopen after forget");
    if let Some(next) = revision_of(&reopened_jp) {
        revision = next;
    }
    let reopen_id = project_id_of(&reopened_jp);
    let reopen_ok = accepted(&reopened_jp)
        && created_of(&reopened_jp) == Some(true)
        && reopen_id.as_deref().is_some_and(|id| id != japanese_id);
    evidence.push(axis(
        "reregister_new_id_after_forget",
        json!({ "created": true, "new_id": true, "old_id_not_reused": japanese_id }),
        json!({
            "response": reopened_jp,
            "new_id": reopen_id,
            "old_id": japanese_id,
        }),
        status_from(reopen_ok),
        if reopen_ok {
            "forgotten ID was not reused on re-registration"
        } else {
            "re-registration reused a forgotten ID or failed"
        },
    ));

    match create_long_directory(&fixture.child("long-base")) {
        Ok((long_dir, logical, units)) => {
            fs::write(long_dir.join("marker.txt"), marker)
                .or_else(|_| fs::write(to_verbatim(&long_dir).join("marker.txt"), marker))
                .ok();
            let verbatim_long = path_text(&to_verbatim(&PathBuf::from(&logical)));
            let body = match owner_open(&host, &inst, revision, &verbatim_long) {
                Ok(body) => body,
                Err(error) => json!({ "transport": error }),
            };
            if let Some(next) = revision_of(&body) {
                revision = next;
            }
            let ok = accepted(&body) && created_of(&body) == Some(true);
            evidence.push(axis(
                "long_path",
                json!({
                    "accepted": true,
                    "created": true,
                    "utf16_units_gt_260": true
                }),
                json!({
                    "utf16_units": units,
                    "logical_path_len_chars": logical.chars().count(),
                    "input": verbatim_long,
                    "response": body,
                }),
                status_from(ok),
                if ok {
                    "path longer than 260 UTF-16 units opened through ancestor-relative observation"
                } else {
                    "long path did not register; not claimed as supported beyond this measurement"
                },
            ));
        }
        Err((gle, reason)) => {
            evidence.push(axis(
                "long_path",
                json!({ "utf16_units_gt_260": true, "product_open_measured": true }),
                json!({ "create_gle": gle, "reason": reason }),
                "not_run",
                "could not create a >260 path from this owned fixture without OS setting changes",
            ));
        }
    }

    let unc_probe = probe_unc(&japanese_dir);
    let syntax_unc = r"\\server\share\dir";
    let unc_syntax_body = owner_open(&host, &inst, revision, syntax_unc).expect("unc syntax");
    let unc_syntax_ok = !accepted(&unc_syntax_body)
        && error_code(&unc_syntax_body) == Some("invalid_request")
        && revision_of(&unc_syntax_body) == Some(revision);
    let localhost = unc_probe
        .as_array()
        .and_then(|rows| {
            rows.iter()
                .find(|row| row["kind"] == json!("localhost_admin_share"))
        })
        .cloned();
    if let Some(row) = localhost.clone().filter(|row| row["opened"] == json!(true)) {
        let unc_path = row["path"].as_str().expect("unc path").to_owned();
        let body = owner_open(&host, &inst, revision, &unc_path).expect("real unc open");
        let listed = owner_list(&host, &inst).expect("list after unc");
        let sibling_still = list_rows(&listed)
            .iter()
            .any(|row| row["project_id"] == json!(sibling_id));
        let ok = !accepted(&body)
            && error_code(&body).is_some()
            && revision_of(&body) == Some(revision)
            && sibling_still;
        evidence.push(axis(
            "unc",
            json!({
                "no_crash": true,
                "observable_error": true,
                "sibling_preserved": true,
                "not_claimed_as_supported": true
            }),
            json!({
                "probe": unc_probe,
                "syntax_response": unc_syntax_body,
                "real_unc_response": body,
                "list_after": listed,
            }),
            status_from(ok && unc_syntax_ok),
            if ok {
                "real localhost admin-share UNC was available and rejected with a structured error; sibling state unchanged"
            } else {
                "real UNC path did not fail closed with a structured error"
            },
        ));
    } else {
        evidence.push(axis(
            "unc",
            json!({
                "real_unc_identity_only_if_owned_fixture_available": true,
                "syntax_rejected": true
            }),
            json!({
                "probe": unc_probe,
                "syntax_response": unc_syntax_body,
                "syntax_ok": unc_syntax_ok,
            }),
            if unc_syntax_ok { "not_run" } else { "fail" },
            if unc_syntax_ok {
                "no already-available owned UNC fixture could be opened without creating a share or changing permissions; UNC syntax still rejected as invalid_request"
            } else {
                "UNC syntax did not return invalid_request"
            },
        ));
    }

    let onedrive = sample_onedrive_placeholder();
    if onedrive["available"] == json!(true) {
        let path = onedrive["path"].as_str().expect("placeholder path").to_owned();
        let native = classify_path_syntax(&path);
        let body = owner_open(&host, &inst, revision, &path).expect("placeholder open");
        let listed = owner_list(&host, &inst).expect("list after placeholder");
        let sibling_still = list_rows(&listed)
            .iter()
            .any(|row| row["project_id"] == json!(sibling_id));
        let ok = !accepted(&body)
            && error_code(&body).is_some()
            && revision_of(&body) == Some(revision)
            && sibling_still;
        evidence.push(axis(
            "onedrive_placeholder",
            json!({
                "no_crash": true,
                "observable_error": true,
                "sibling_preserved": true
            }),
            json!({
                "probe": onedrive,
                "classify": format!("{native:?}"),
                "response": body,
                "list_after": listed,
            }),
            status_from(ok),
            if ok {
                "existing OneDrive placeholder directory produced a structured error; sibling state unchanged"
            } else {
                "OneDrive placeholder did not fail closed"
            },
        ));
    } else {
        evidence.push(axis(
            "onedrive_placeholder",
            json!("real placeholder directory from an already available owned fixture"),
            json!({ "probe": onedrive }),
            "not_run",
            "no OneDrive placeholder directory attributes were observed on already-available env roots without creating cloud files or modifying user data",
        ));
    }

    let before_readonly_attrs = native_attributes(&readonly_dir).ok();
    let wide_readonly = wide_null(&readonly_dir);
    let set_ok = unsafe {
        SetFileAttributesW(
            wide_readonly.as_ptr(),
            FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_DIRECTORY,
        )
    };
    let set_gle = if set_ok == 0 {
        unsafe { GetLastError() }
    } else {
        0
    };
    let after_readonly_attrs = native_attributes(&readonly_dir).ok();
    let write_into = native_create_file_in(&readonly_dir, "write-probe.txt");
    let dir_write_handle = native_open_directory(
        &readonly_dir,
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_FLAG_BACKUP_SEMANTICS,
    );
    let dir_write_gle = match dir_write_handle {
        Ok(handle) => {
            unsafe {
                let _ = CloseHandle(handle);
            }
            0
        }
        Err(gle) => gle,
    };
    let readonly_open = owner_open(&host, &inst, revision, &readonly_path).expect("readonly open");
    if accepted(&readonly_open) {
        if let Some(next) = revision_of(&readonly_open) {
            revision = next;
        }
    }
    let readonly_attr_set = after_readonly_attrs
        .is_some_and(|attrs| attrs & FILE_ATTRIBUTE_READONLY != 0)
        && set_gle == 0;
    let product_structured = accepted(&readonly_open) || error_code(&readonly_open).is_some();
    evidence.push(axis(
        "readonly_directory",
        json!({
            "attribute_is_not_write_proof": true,
            "native_write_observed_directly": true,
            "product_result_is_structured": true
        }),
        json!({
            "setfileattributes_gle": set_gle,
            "attributes_before": before_readonly_attrs,
            "attributes_after": after_readonly_attrs,
            "attribute_readonly_set": readonly_attr_set,
            "create_file_in_dir_os_error": write_into.0,
            "create_file_in_dir_text": write_into.1,
            "generic_write_open_dir_gle": dir_write_gle,
            "generic_write_open_denied": dir_write_gle == ERROR_ACCESS_DENIED,
            "product_response": readonly_open,
        }),
        status_from(readonly_attr_set && product_structured),
        "readonly attribute recorded; write denial taken only from the native create/open result, not from the attribute bit",
    ));
    let _ = unsafe { SetFileAttributesW(wide_readonly.as_ptr(), FILE_ATTRIBUTE_DIRECTORY) };

    match ProcessLock::spawn(&lock_dir, &fixture) {
        Ok(lock) => {
            let running = lock.still_running();
            let native_conflict = native_open_directory(
                &lock_dir,
                LOCK_ACCESS,
                FILE_SHARE_READ,
                LOCK_FLAGS,
            );
            let native_gle = match native_conflict {
                Ok(handle) => {
                    unsafe {
                        let _ = CloseHandle(handle);
                    }
                    0
                }
                Err(gle) => gle,
            };
            let locked_open = owner_open(&host, &inst, revision, &lock_path).expect("locked open");
            let listed = owner_list(&host, &inst).expect("list during lock");
            let sibling_still = list_rows(&listed)
                .iter()
                .any(|row| row["project_id"] == json!(sibling_id));
            let helper_ok = running.is_ok();
            let product_ok = !accepted(&locked_open)
                && error_code(&locked_open) == Some("runtime_failed")
                && revision_of(&locked_open) == Some(revision);
            evidence.push(axis(
                "other_process_lock",
                json!({
                    "helper_process_alive": true,
                    "access": format!("0x{LOCK_ACCESS:08X}"),
                    "share": format!("0x{LOCK_SHARE:08X}"),
                    "flags": format!("0x{LOCK_FLAGS:08X}"),
                    "product_error": "runtime_failed",
                    "revision_unchanged": true,
                    "sibling_preserved": true
                }),
                json!({
                    "helper_pid": lock.pid,
                    "helper_process_handle": format!("{:?}", lock.process),
                    "helper_ready": lock.ready_text,
                    "helper_running": helper_ok,
                    "native_createfilew_share_read_gle": native_gle,
                    "native_sharing_violation": native_gle == ERROR_SHARING_VIOLATION,
                    "product_response": locked_open,
                    "list_during": listed,
                }),
                status_from(helper_ok && product_ok && sibling_still),
                if helper_ok && product_ok && sibling_still {
                    "separately owned helper process held share=0; product returned runtime_failed; sibling unchanged"
                } else {
                    "other-process lock did not produce runtime_failed with sibling preservation"
                },
            ));
            lock.release();
            let unlocked = owner_open(&host, &inst, revision, &lock_path).expect("open after unlock");
            if accepted(&unlocked) {
                if let Some(next) = revision_of(&unlocked) {
                    revision = next;
                }
            }
            evidence.push(axis(
                "other_process_lock_released",
                json!({ "accepted": true, "created": true }),
                json!({ "response": unlocked }),
                status_from(accepted(&unlocked) && created_of(&unlocked) == Some(true)),
                if accepted(&unlocked) {
                    "open succeeded after the helper process released the share=0 handle"
                } else {
                    "open still failed after lock release"
                },
            ));
        }
        Err(reason) => {
            evidence.push(axis(
                "other_process_lock",
                json!({ "separate_process_share0_handle": true, "product_error": "runtime_failed" }),
                json!({ "spawn_error": reason }),
                "blocked",
                "could not hold a separately owned process handle on the lock fixture",
            ));
        }
    }

    let missing_open = owner_open(&host, &inst, revision, &missing_text).expect("missing open");
    let missing_ok = !accepted(&missing_open)
        && error_code(&missing_open) == Some("target_not_found")
        && revision_of(&missing_open) == Some(revision);
    evidence.push(axis(
        "missing_path",
        json!({ "error": "target_not_found", "revision_unchanged": true, "no_crash": true }),
        json!({ "response": missing_open, "input": missing_text }),
        status_from(missing_ok),
        if missing_ok {
            "missing directory returned target_not_found"
        } else {
            "missing directory did not return target_not_found"
        },
    ));

    let file_open = owner_open(&host, &inst, revision, &file_text).expect("file open");
    let file_attrs = native_attributes(&file_path).ok();
    let file_ok = !accepted(&file_open)
        && error_code(&file_open).is_some()
        && revision_of(&file_open) == Some(revision)
        && file_attrs.is_some_and(|attrs| attrs & FILE_ATTRIBUTE_DIRECTORY == 0);
    evidence.push(axis(
        "non_directory",
        json!({
            "structured_error": true,
            "revision_unchanged": true,
            "no_crash": true,
            "native_not_directory": true
        }),
        json!({
            "response": file_open,
            "input": file_text,
            "native_attributes": file_attrs,
            "wire_error": error_code(&file_open),
        }),
        status_from(file_ok),
        if file_ok {
            "existing file returned a structured error without crash or revision change; wire code is the native observation, not an inferred unsupported_file claim"
        } else {
            "file path crashed, changed revision, or was treated as a directory"
        },
    ));

    let cwd_relative = PathBuf::from("winsmux-863-p01-relative-must-not-create");
    let relative_existed = cwd_relative.exists();
    let rejected = [
        "relative",
        r"C:foo",
        r"\\server\share\dir",
        r"\\.\pipe\x",
        "NUL",
        r"C:\foo:stream",
        r"C:\foo\.\bar",
        r"C:\foo\..\bar",
        r"C:\foo ",
        r"C:\foo.",
        r"C:\CON",
        r"C:\PRN\out",
        r"C:\COM1",
        r"C:\LPT1\out",
        r"C:\AUX",
        r"C:\foo\NUL",
    ];
    let mut boundary_rows = Vec::new();
    let mut boundary_fail = false;
    for path in rejected {
        let classified = classify_path_syntax(path);
        let body = owner_open(&host, &inst, revision, path).expect("boundary open");
        let ok = classified == Err(ObserveError::InvalidRequest)
            && !accepted(&body)
            && error_code(&body) == Some("invalid_request")
            && revision_of(&body) == Some(revision);
        if !ok {
            boundary_fail = true;
        }
        boundary_rows.push(json!({
            "path": path,
            "classify": format!("{classified:?}"),
            "response": body,
            "ok": ok,
        }));
    }
    let relative_created = cwd_relative.exists() && !relative_existed;
    if relative_created {
        boundary_fail = true;
        let _ = fs::remove_dir_all(&cwd_relative);
    }
    evidence.push(axis(
        "boundary_rejection",
        json!({
            "invalid_request": true,
            "revision_unchanged": true,
            "no_relative_sidecar": true
        }),
        json!({
            "rows": boundary_rows,
            "relative_sidecar_created": relative_created,
        }),
        status_from(!boundary_fail),
        if boundary_fail {
            "a rejected path did not return invalid_request or created a relative sidecar"
        } else {
            "relative, UNC syntax, device, reserved, and dot/space-tail inputs returned invalid_request without creating sidecars"
        },
    ));

    let listed_final = owner_list(&host, &inst).expect("final list");
    evidence.push(axis(
        "final_registry_observation",
        json!("parsed project.list after the path-identity journey"),
        json!({ "response": listed_final }),
        "pass",
        "retained parsed ProductHost.owner_request responses for the journey",
    ));

    let _ = host.shutdown();
    let failed = evidence.failed();
    evidence.flush();
    if !failed.is_empty() {
        panic!("TASK-863.P01 failed axes: {}", failed.join(","));
    }
}
