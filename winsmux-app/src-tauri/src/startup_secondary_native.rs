//! Closed, caller-owned operations for the readonly startup surface.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{ipc, WebviewWindow};

const PREVIEW_BYTES: usize = 32 * 1024;

pub(crate) fn startup_location_allowed(label: &str, url: &tauri::Url) -> bool {
    if label == "main" {
        let local = (url.scheme() == "tauri" && url.host_str() == Some("localhost")) || (matches!(url.scheme(), "http" | "https") && url.host_str() == Some("tauri.localhost"));
        return local && url.port().is_none() && url.username().is_empty() && url.password().is_none() && url.path() == "/" && url.fragment().is_none() && url.query_pairs().count() == 0;
    }
    let Some(suffix) = label.strip_prefix("secondary-surface-") else { return false };
    if suffix.is_empty() || !suffix.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') { return false; }
    let local = (url.scheme() == "tauri" && url.host_str() == Some("localhost"))
        || (matches!(url.scheme(), "http" | "https") && url.host_str() == Some("tauri.localhost"));
    if !local || url.port().is_some() || !url.username().is_empty() || url.password().is_some()
        || !matches!(url.path(), "/" | "/index.html") || url.fragment().is_some() { return false; }
    let pairs: Vec<_> = url.query_pairs().collect();
    pairs.len() == 2
        && pairs.iter().filter(|(k, v)| k == "popout" && v == "1").count() == 1
        && pairs.iter().filter(|(k, v)| k == "popout-key" && v.starts_with("winsmux.popout-surface.")).count() == 1
}

pub(crate) fn secondary_location_allowed(label: &str, url: &tauri::Url) -> bool { label != "main" && startup_location_allowed(label, url) }

pub(crate) fn main_local_caller(window: &WebviewWindow, invocation: &ipc::Request<'_>) -> bool {
    let Ok(url) = window.url() else { return false };
    window.label() == "main" && startup_location_allowed(window.label(), &url) && invocation.headers().get("origin").and_then(|v| v.to_str().ok()) == Some(url.origin().ascii_serialization().as_str())
}

fn caller_allowed(label: &str, url: &tauri::Url, origin: Option<&str>) -> bool {
    secondary_location_allowed(label, url) && origin == Some(url.origin().ascii_serialization().as_str())
}
fn local_caller(window: &WebviewWindow, invocation: &ipc::Request<'_>) -> bool {
    let Ok(url) = window.url() else { return false };
    caller_allowed(window.label(), &url, invocation.headers().get("origin").and_then(|value| value.to_str().ok()))
}

#[derive(Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum SecondaryRequest {
    #[serde(rename = "show")]
    Show,
    #[serde(rename = "editor-read")]
    EditorRead { project_dir: String, worktree: Option<String>, path: String },
}

fn parse_request(raw: &str) -> Result<SecondaryRequest, String> {
    let value: Value = serde_json::from_str(raw).map_err(|_| "secondary_invalid_request")?;
    let map = value.as_object().ok_or("secondary_invalid_request")?;
    let expected: &[&str] = match map.get("kind").and_then(Value::as_str) {
        Some("show") => &["kind"],
        Some("editor-read") => &["kind", "project_dir", "worktree", "path"],
        _ => return Err("secondary_invalid_request".into()),
    };
    if map.len() != expected.len() || !expected.iter().all(|key| map.contains_key(*key)) {
        return Err("secondary_invalid_request".into());
    }
    serde_json::from_str(raw).map_err(|_| "secondary_invalid_request".into())
}

#[derive(Serialize)]
struct FileReply { path: String, content: String, line_count: usize, truncated: bool }
#[derive(Serialize)]
struct ReadReply { project_dir: String, worktree: Option<String>, file: FileReply }

#[tauri::command]
pub(crate) async fn startup_secondary_request(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    request_json: String,
) -> Result<Value, String> {
    if !local_caller(&window, &invocation) { return Err("secondary_denied".into()); }
    match parse_request(&request_json)? {
        SecondaryRequest::Show => {
            crate::webview_accelerators::await_ready(&window).await.map_err(|_| "secondary_show_failed")?;
            crate::webview_accelerators::show_if_ready(&window).map_err(|_| "secondary_show_failed")?;
            Ok(json!({"shown":true}))
        }
        SecondaryRequest::EditorRead { project_dir, worktree, path } => {
            tauri::async_runtime::spawn_blocking(move || {
                let file = read_editor(&project_dir, worktree.as_deref(), &path)?;
                serde_json::to_value(ReadReply { project_dir, worktree, file }).map_err(|_| "secondary_read_failed".into())
            }).await.map_err(|_| "secondary_read_failed".to_owned())?
        }
    }
}

#[cfg(windows)]
fn read_editor(project: &str, worktree: Option<&str>, path: &str) -> Result<FileReply, String> {
    held::read_editor(project, worktree, path)
}
#[cfg(not(windows))]
fn read_editor(_: &str, _: Option<&str>, _: &str) -> Result<FileReply, String> {
    Err("secondary_read_unsupported".into())
}

fn relative_path(raw: &str) -> Result<String, String> {
    let path = raw.replace('\\', "/");
    if path.split('/').any(|part| {
        part.is_empty() || part == "." || part == ".." || part.ends_with(['.', ' '])
            || part.chars().any(|c| c.is_control() || c == ':') || reserved(part)
    }) { return Err("secondary_invalid_path".into()); }
    Ok(path)
}

fn reserved(part: &str) -> bool {
    let base = part.split('.').next().unwrap_or("");
    ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].iter().any(|name| base.eq_ignore_ascii_case(name))
        || ["COM", "LPT"].iter().any(|prefix| base.get(..3).is_some_and(|head| head.eq_ignore_ascii_case(prefix))
            && base.get(3..).is_some_and(|number| matches!(number, "1"|"2"|"3"|"4"|"5"|"6"|"7"|"8"|"9"|"¹"|"²"|"³")))
}

fn drive_path(raw: &str) -> Result<(u8, Vec<String>), String> {
    let normalized = raw.replace('\\', "/");
    let path = normalized.strip_prefix("//?/").unwrap_or(&normalized);
    let bytes = path.as_bytes();
    if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' || bytes[2] != b'/' {
        return Err("secondary_invalid_root".into());
    }
    let tail = path[3..].strip_suffix('/').unwrap_or(&path[3..]);
    let components = if tail.is_empty() { Vec::new() } else { relative_path(tail)?.split('/').map(str::to_owned).collect() };
    Ok((bytes[0].to_ascii_uppercase(), components))
}

#[cfg(windows)]
mod held {
    use super::{drive_path, relative_path, FileReply, PREVIEW_BYTES};
    use std::{fs::File, os::windows::io::{AsRawHandle, FromRawHandle}, ptr::{null, null_mut}};
    use windows_sys::Win32::{Foundation::{HANDLE, INVALID_HANDLE_VALUE}, Storage::FileSystem::{
        CreateFileW, GetDriveTypeW, GetFileInformationByHandle, GetFileInformationByHandleEx,
        GetFinalPathNameByHandleW, ReadFile, BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_DIRECTORY,
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_SHARE_READ, OPEN_EXISTING,
    }};

    const ATTRIBUTES: u32 = 0x80;
    const DATA: u32 = 1;
    const SYNCHRONIZE: u32 = 0x100000;
    #[repr(C)] struct UnicodeString { length: u16, maximum_length: u16, buffer: *const u16 }
    #[repr(C)] struct ObjectAttributes { length: u32, root_directory: HANDLE, object_name: *const UnicodeString,
        attributes: u32, security_descriptor: *const core::ffi::c_void, security_quality_of_service: *const core::ffi::c_void }
    #[repr(C)] struct IoStatusBlock { status: i32, information: usize }
    #[link(name = "ntdll")]
    extern "system" {
        fn NtCreateFile(handle: *mut HANDLE, access: u32, attributes: *const ObjectAttributes,
            status: *mut IoStatusBlock, allocation: *const i64, file_attributes: u32, share: u32,
            disposition: u32, options: u32, ea: *const core::ffi::c_void, ea_length: u32) -> i32;
    }
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Identity { volume: u32, high: u32, low: u32 }
    struct Held { file: File, identity: Identity, size: u64, canonical: String }
    impl Held { fn raw(&self) -> HANDLE { self.file.as_raw_handle() as HANDLE } }

    fn inspect(file: File, directory: bool) -> Result<Held, String> {
        let raw = file.as_raw_handle() as HANDLE;
        let info = information(raw)?;
        if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory
            || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 || (!directory && info.nNumberOfLinks != 1) {
            return Err("secondary_unsupported_file".into());
        }
        if directory {
            let mut flags = 0u32;
            if unsafe { GetFileInformationByHandleEx(raw, 23, (&mut flags as *mut u32).cast(), 4) } == 0 || flags & 1 != 0 {
                return Err("secondary_unsupported_root".into());
            }
        }
        let canonical = final_path(raw)?;
        drive_path(&canonical)?;
        Ok(Held { file, identity: identity(&info), size: size(&info), canonical })
    }
    fn information(raw: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION, String> {
        let mut info = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(raw, &mut info) } == 0 { return Err("secondary_read_failed".into()); }
        Ok(info)
    }
    fn identity(info: &BY_HANDLE_FILE_INFORMATION) -> Identity {
        Identity { volume: info.dwVolumeSerialNumber, high: info.nFileIndexHigh, low: info.nFileIndexLow }
    }
    fn size(info: &BY_HANDLE_FILE_INFORMATION) -> u64 { (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow) }
    fn final_path(raw: HANDLE) -> Result<String, String> {
        let needed = unsafe { GetFinalPathNameByHandleW(raw, null_mut(), 0, 0) };
        if needed == 0 { return Err("secondary_read_failed".into()); }
        let count = (needed as usize).checked_add(1).ok_or("secondary_read_failed")?;
        let mut units = Vec::new(); units.try_reserve_exact(count).map_err(|_| "secondary_read_failed")?;
        units.resize(count, 0u16);
        let written = unsafe { GetFinalPathNameByHandleW(raw, units.as_mut_ptr(), units.len() as u32, 0) };
        if written == 0 || written as usize >= units.len() { return Err("secondary_read_failed".into()); }
        String::from_utf16(&units[..written as usize]).map_err(|_| "secondary_invalid_path".into())
    }
    fn drive(drive: u8) -> Result<Held, String> {
        let path: Vec<u16> = format!("{}:\\", drive as char).encode_utf16().chain(Some(0)).collect();
        if unsafe { GetDriveTypeW(path.as_ptr()) } != 3 { return Err("secondary_unsupported_root".into()); }
        let raw = unsafe { CreateFileW(path.as_ptr(), ATTRIBUTES | DATA | SYNCHRONIZE, FILE_SHARE_READ,
            null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null_mut()) };
        if raw == INVALID_HANDLE_VALUE || raw.is_null() { return Err("secondary_read_failed".into()); }
        inspect(unsafe { File::from_raw_handle(raw.cast()) }, true)
    }
    fn child(parent: &Held, name: &str, directory: bool) -> Result<Held, String> {
        let units: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let bytes = (units.len() - 1).checked_mul(2).ok_or("secondary_invalid_path")?;
        let maximum = bytes.checked_add(2).and_then(|count| u16::try_from(count).ok()).ok_or("secondary_invalid_path")?;
        let text = UnicodeString { length: u16::try_from(bytes).map_err(|_| "secondary_invalid_path")?, maximum_length: maximum, buffer: units.as_ptr() };
        let attributes = ObjectAttributes { length: std::mem::size_of::<ObjectAttributes>() as u32, root_directory: parent.raw(),
            object_name: &text, attributes: 0x40, security_descriptor: null(), security_quality_of_service: null() };
        let mut status = IoStatusBlock { status: 0, information: 0 }; let mut raw = INVALID_HANDLE_VALUE;
        let result = unsafe { NtCreateFile(&mut raw, ATTRIBUTES | DATA | SYNCHRONIZE, &attributes, &mut status,
            null(), 0, FILE_SHARE_READ, 1, (if directory { 1 } else { 0x40 }) | 0x200000 | 0x20, null(), 0) };
        if result < 0 || raw == INVALID_HANDLE_VALUE || raw.is_null() { return Err("secondary_read_failed".into()); }
        let held = inspect(unsafe { File::from_raw_handle(raw.cast()) }, directory)?;
        if held.identity.volume != parent.identity.volume { return Err("secondary_unsupported_file".into()); }
        Ok(held)
    }
    fn absolute(path: &str) -> Result<Vec<Held>, String> {
        let (letter, parts) = drive_path(path)?;
        let mut handles = vec![drive(letter)?];
        for part in parts { handles.push(child(handles.last().expect("drive held"), &part, true)?); }
        Ok(handles)
    }
    fn verify(handles: &[Held]) -> Result<(), String> {
        for held in handles {
            let current = information(held.raw())?;
            if identity(&current) != held.identity || size(&current) != held.size || final_path(held.raw())? != held.canonical {
                return Err("secondary_root_changed".into());
            }
        }
        Ok(())
    }
    pub(super) fn read_editor(project: &str, worktree: Option<&str>, path: &str) -> Result<FileReply, String> {
        let relative = relative_path(path)?;
        let mut handles = absolute(project)?;
        let root_identity = handles.last().expect("root held").identity;
        if let Some(worktree) = worktree.filter(|value| !value.is_empty()) {
            if drive_path(worktree).is_ok() {
                let work_handles = absolute(worktree)?;
                if !work_handles.iter().any(|held| held.identity == root_identity) { return Err("secondary_outside_root".into()); }
                handles.extend(work_handles);
            } else {
                for part in relative_path(worktree)?.split('/') { handles.push(child(handles.last().expect("root held"), part, true)?); }
            }
        }
        let parts: Vec<_> = relative.split('/').collect();
        for part in &parts[..parts.len() - 1] { handles.push(child(handles.last().expect("read root held"), part, true)?); }
        let leaf = child(handles.last().expect("parent held"), parts.last().expect("file component"), false)?;
        let amount = usize::try_from(leaf.size.min(PREVIEW_BYTES as u64)).map_err(|_| "secondary_read_failed")?;
        let mut bytes = vec![0u8; amount]; let mut offset = 0;
        verify(&handles)?;
        while offset < amount {
            let mut read = 0u32;
            if unsafe { ReadFile(leaf.raw(), bytes[offset..].as_mut_ptr(), (amount - offset) as u32, &mut read, null_mut()) } == 0
                || read == 0 { return Err("secondary_read_failed".into()); }
            offset += read as usize;
        }
        verify(&handles)?; verify(std::slice::from_ref(&leaf))?;
        let content = String::from_utf8_lossy(&bytes).into_owned();
        let line_count = content.lines().count().max(1);
        Ok(FileReply { path: relative, content, line_count, truncated: leaf.size > PREVIEW_BYTES as u64 })
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::{fs, path::{Path, PathBuf}, os::windows::fs::OpenOptionsExt};
        struct Fixture(PathBuf);
        impl Fixture {
            fn new() -> Self {
                let temp = std::env::temp_dir();
                super::super::drive_path(temp.to_str().expect("UTF16 temp path")).expect("explicit local test root");
                let own = temp.join(format!("task871-held-{}", uuid::Uuid::new_v4()));
                fs::create_dir(&own).expect("create exclusive owned fixture");
                Self(own)
            }
            fn root(&self) -> String { self.0.to_str().unwrap().to_owned() }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                // Every entry was created by this fixture, under its exclusive UUID directory.
                // Remove the only reparse link itself before recursive owned-directory cleanup.
                let link = self.0.join("junction");
                if link.exists() { fs::remove_dir(&link).expect("remove owned junction itself"); }
                fs::remove_dir_all(&self.0).expect("release and remove owned fixture");
            }
        }
        fn assert_reply(reply: FileReply, path: &str, bytes: &[u8], truncated: bool) {
            let expected = String::from_utf8_lossy(bytes);
            assert_eq!(reply.path, path); assert_eq!(reply.content, expected);
            assert_eq!(reply.line_count, expected.lines().count().max(1)); assert_eq!(reply.truncated, truncated);
        }
        #[test]
        fn real_held_prefix_unicode_utf8_and_worktree_boundaries() {
            let fixture = Fixture::new(); let root = fixture.root();
            fs::create_dir(fixture.0.join("work")).unwrap();
            let work = fixture.0.join("work").to_str().unwrap().to_owned();
            let cases: Vec<Vec<u8>> = vec![vec![], b"line\r\nnext\n".to_vec(), "日本語\n".as_bytes().to_vec(),
                vec![0xff, b'\n', 0xe3, 0x81], vec![b'x'; PREVIEW_BYTES],
                { let mut bytes=vec![b'x'; PREVIEW_BYTES-1]; bytes.extend([0xe3,0x81,0x82]); bytes }];
            for (index, bytes) in cases.iter().enumerate() {
                let name=format!("日本語-{index}.txt");fs::write(fixture.0.join("work").join(&name),bytes).unwrap();
                for worktree in [Some("work"),Some(work.as_str())] {
                    assert_reply(read_editor(&root,worktree,&name).unwrap(),&name,&bytes[..bytes.len().min(PREVIEW_BYTES)],bytes.len()>PREVIEW_BYTES);
                }
                assert_reply(read_editor(&root,None,&format!("work\\{name}")).unwrap(),&format!("work/{name}"),&bytes[..bytes.len().min(PREVIEW_BYTES)],bytes.len()>PREVIEW_BYTES);
            }
            let extended=format!(r"\\?\{}",root);let extended_work=format!(r"\\?\{}",work);
            assert!(read_editor(&extended,Some(&extended_work),"日本語-0.txt").is_ok());
            assert!(read_editor(&root.to_ascii_uppercase(),Some(&work.to_ascii_lowercase()),"日本語-0.txt").is_ok());
            fs::write(fixture.0.join("root.txt"),b"root").unwrap();
            for worktree in [None,Some("")] { assert_reply(read_editor(&root,worktree,"root.txt").unwrap(),"root.txt",b"root",false); }
            let outside=Fixture::new();fs::write(outside.0.join("root.txt"),b"outside").unwrap();
            assert_eq!(read_editor(&root,Some(&outside.root()),"root.txt").err().as_deref(),Some("secondary_outside_root"));
        }
        #[test]
        fn real_missing_replaced_hardlink_directory_and_sharing_are_closed() {
            let fixture=Fixture::new();let root=fixture.root();let path=fixture.0.join("sample.txt");
            assert!(read_editor(&root,None,"sample.txt").is_err());
            assert!(read_editor(&format!("{root}/missing"),None,"sample.txt").is_err());
            assert!(read_editor(&root,Some("missing"),"sample.txt").is_err());
            fs::write(&path,b"old").unwrap();fs::remove_file(&path).unwrap();fs::write(&path,b"replacement").unwrap();
            assert_reply(read_editor(&root,None,"sample.txt").unwrap(),"sample.txt",b"replacement",false);
            // Pre-open replacement defines this request's identity. Held replacement is forbidden below.
            fs::hard_link(&path,fixture.0.join("alias.txt")).unwrap();assert!(read_editor(&root,None,"sample.txt").is_err());
            fs::remove_file(fixture.0.join("alias.txt")).unwrap();fs::create_dir(fixture.0.join("directory")).unwrap();
            assert!(read_editor(&root,None,"directory").is_err());
            let writer=fs::OpenOptions::new().write(true).share_mode(1|2|4).open(&path).unwrap();
            assert!(read_editor(&root,None,"sample.txt").is_err());drop(writer);
            let mut handles=absolute(&root).unwrap();let leaf=child(handles.last().unwrap(),"sample.txt",false).unwrap();
            assert!(fs::OpenOptions::new().write(true).open(&path).is_err());assert!(fs::remove_file(&path).is_err());
            assert!(fs::rename(&path,fixture.0.join("other.txt")).is_err());
            assert!(fs::rename(&fixture.0,fixture.0.with_extension("replacement")).is_err());
            verify(&handles).unwrap();verify(std::slice::from_ref(&leaf)).unwrap();drop(leaf);handles.clear();
            // All failed and successful paths release owned handles; these operations now succeed.
            fs::rename(&path,fixture.0.join("other.txt")).unwrap();fs::remove_file(fixture.0.join("other.txt")).unwrap();
        }
        fn junction(link: &Path,target: &Path) {
            use windows_sys::Win32::System::IO::DeviceIoControl;
            fs::create_dir(link).unwrap();
            let path: Vec<u16>=link.as_os_str().to_string_lossy().encode_utf16().chain(Some(0)).collect();
            let raw=unsafe { CreateFileW(path.as_ptr(),0x40000000,0,null(),OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,null_mut()) };
            assert!(raw!=INVALID_HANDLE_VALUE&&!raw.is_null());let file=unsafe { File::from_raw_handle(raw.cast()) };
            let substitute:Vec<u16>=format!(r"\??\{}",target.to_str().unwrap()).encode_utf16().collect();
            let print:Vec<u16>=target.to_str().unwrap().encode_utf16().collect();
            let data_len=8+(substitute.len()+1+print.len()+1)*2;
            let mut buffer=Vec::new();buffer.extend(0xa0000003u32.to_le_bytes());buffer.extend((data_len as u16).to_le_bytes());buffer.extend(0u16.to_le_bytes());
            for value in [0u16,(substitute.len()*2) as u16,((substitute.len()+1)*2) as u16,(print.len()*2) as u16] { buffer.extend(value.to_le_bytes()); }
            for value in substitute.into_iter().chain(Some(0)).chain(print).chain(Some(0)) { buffer.extend(value.to_le_bytes()); }
            let mut returned=0;
            assert_ne!(unsafe { DeviceIoControl(file.as_raw_handle().cast(),0x000900a4,buffer.as_ptr().cast(),buffer.len() as u32,null_mut(),0,&mut returned,null_mut()) },0,"owned junction creation: {}",std::io::Error::last_os_error());
        }
        #[test]
        fn real_reparse_root_worktree_and_ancestor_are_not_followed() {
            let fixture=Fixture::new();let target=Fixture::new();fs::write(target.0.join("sample.txt"),b"outside").unwrap();
            let link=fixture.0.join("junction");junction(&link,&target.0);
            assert!(read_editor(link.to_str().unwrap(),None,"sample.txt").is_err());
            assert!(read_editor(&fixture.root(),Some("junction"),"sample.txt").is_err());
            assert!(read_editor(&fixture.root(),None,"junction/sample.txt").is_err());
            fs::remove_dir(&link).unwrap();assert_reply(read_editor(&target.root(),None,"sample.txt").unwrap(),"sample.txt",b"outside",false);
        }
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_kind_and_explicit_path_table() {
        assert!(parse_request(r#"{"kind":"show"}"#).is_ok());
        assert!(parse_request(r#"{"kind":"editor-read","project_dir":"C:/p","worktree":null,"path":"a.txt"}"#).is_ok());
        for raw in [r#"{"kind":"show","label":"main"}"#, r#"{"kind":"editor-read","project_dir":"C:/p","path":"a"}"#,
            r#"{"kind":"unknown"}"#, "null", "[]", r#"{"kind":"editor-read","project_dir":false,"worktree":null,"path":"a"}"#] { assert!(parse_request(raw).is_err(), "{raw}"); }
        for root in ["C:/p", r"c:\p", r"\\?\C:\p", "C:/日本語"] { assert!(drive_path(root).is_ok(), "{root}"); }
        for root in ["", "p", "C:p", r"\\server\share", r"\\?\UNC\server\share", r"\\.\C:\p", "C:/p/../other"] { assert!(drive_path(root).is_err(), "{root}"); }
        for path in ["a.txt", "src/a", r"src\a", "日本語.txt"] { assert!(relative_path(path).is_ok()); }
        for path in ["", "/a", "C:/a", "../a", "a/../b", "a//b", "a/./b", "a:stream", "NUL.txt", "a.", "a ", "COM¹.txt"] { assert!(relative_path(path).is_err(), "{path}"); }
    }
    #[test]
    fn actual_origin_and_duplicate_request_table() {
        let url = tauri::Url::parse("https://tauri.localhost:443/index.html?popout=1&popout-key=winsmux.popout-surface.x").unwrap();
        assert!(caller_allowed("secondary-surface-test", &url, Some("https://tauri.localhost")));
        for origin in [None, Some("null"), Some("http://tauri.localhost"), Some("https://outside.invalid"), Some("https://tauri.localhost:443"), Some("https://tauri.localhost/")] {
            assert!(!caller_allowed("secondary-surface-test", &url, origin), "{origin:?}");
        }
        for label in ["main", "unknown", "secondary-surface-", "editor"] { assert!(!caller_allowed(label, &url, Some("https://tauri.localhost"))); }
        for raw in [r#"{"kind":"show","kind":"show"}"#, r#"{"kind":"editor-read","project_dir":"C:/p","project_dir":"C:/p","worktree":null,"path":"a"}"#,
            r#"{"kind":"editor-read","project_dir":"C:/p","worktree":null,"worktree":null,"path":"a"}"#, r#"{"kind":"editor-read","project_dir":"C:/p","worktree":null,"path":"a","path":"a"}"#] {
            assert!(parse_request(raw).is_err(), "duplicate field {raw}");
        }
    }
    #[test]
    fn secondary_url_table() {
        let label = "secondary-surface-test";
        for url in ["http://tauri.localhost/?popout=1&popout-key=winsmux.popout-surface.x",
            "http://tauri.localhost:80/index.html?popout-key=winsmux.popout-surface.x&popout=1",
            "https://tauri.localhost:443/?popout=1&popout-key=winsmux.popout-surface.x",
            "tauri://localhost/?popout=1&popout-key=winsmux.popout-surface.x"] { assert!(secondary_location_allowed(label, &tauri::Url::parse(url).unwrap()), "{url}"); }
        for url in ["http://tauri.localhost/?popout=1&popout-key=winsmux.popout-surface.x#",
            "http://tauri.localhost:1/?popout=1&popout-key=winsmux.popout-surface.x", "http://tauri.localhost/?popout=1&popout-key=x",
            "http://user@tauri.localhost/?popout=1&popout-key=winsmux.popout-surface.x", "http://example.com/?popout=1&popout-key=winsmux.popout-surface.x",
            "http://tauri.localhost/?popout=1&popout-key=winsmux.popout-surface.x&extra=1"] { assert!(!secondary_location_allowed(label, &tauri::Url::parse(url).unwrap()), "{url}"); }
        let url = tauri::Url::parse("http://tauri.localhost/?popout=1&popout-key=winsmux.popout-surface.x").unwrap();
        for label in ["main", "unknown", "secondary-surface-", "secondary-surface-x_", "editor"] { assert!(!secondary_location_allowed(label, &url)); }
    }
}
