//! Request-local Git source capture. No snapshot directory or lease is made.

use crate::contract::{ErrorCode, FileKind, Nullable, RelativePath, RootIdentity, StringSet};
use crate::host::admission::{AllocationAuthority, AllocationPool};
use crate::store::root_identity::{self, CapturedProjectTree, ObservedFile};
use std::cell::Cell;
use windows_sys::Win32::Security::Cryptography::{
    BCryptCloseAlgorithmProvider, BCryptHash, BCryptOpenAlgorithmProvider, BCRYPT_SHA1_ALGORITHM,
};

pub(crate) struct CapturedRepository {
    tree: CapturedProjectTree,
    ignore_case: bool,
}

pub(crate) enum CaptureFailure {
    Walk(ErrorCode),
    Repository(ErrorCode),
}

impl CaptureFailure {
    pub(crate) fn code(self) -> ErrorCode {
        match self {
            Self::Walk(code) | Self::Repository(code) => code,
        }
    }
}

impl CapturedRepository {
    pub(crate) fn new(
        project_path: &str, expected_root: &RootIdentity,
        authority: &AllocationAuthority, pool: AllocationPool,
    ) -> Result<Option<Self>, ErrorCode> {
        Self::capture(project_path, expected_root, authority, pool).map_err(CaptureFailure::code)
    }

    pub(crate) fn capture(
        project_path: &str, expected_root: &RootIdentity,
        authority: &AllocationAuthority, pool: AllocationPool,
    ) -> Result<Option<Self>, CaptureFailure> {
        let saw_objects = Cell::new(false);
        let rejected_metadata = Cell::new(false);
        let tree = match root_identity::capture_project_tree(
            project_path, expected_root, authority, pool,
            |relative, directory| {
                if relative.eq_ignore_ascii_case(".git/objects/info/alternates")
                    || relative.eq_ignore_ascii_case(".git/info/attributes") {
                    rejected_metadata.set(true);
                    return Err(ErrorCode::UnsupportedFile);
                }
                if relative == ".git/objects" && directory { saw_objects.set(true); }
                if relative == ".git" { return Ok(true); }
                if relative.starts_with(".git/") {
                    if !directory && matches!(relative, ".git/config" | ".git/info/exclude") {
                        return Ok(true);
                    }
                    return Ok(safe_git_component(relative, directory));
                }
                Ok(true)
            },
        ) {
            Ok(tree) => tree,
            Err(_) if rejected_metadata.get() => {
                return Err(CaptureFailure::Repository(ErrorCode::UnsupportedFile));
            }
            Err(code) => return Err(CaptureFailure::Walk(code)),
        };
        let Some(tree) = tree else { return Ok(None) };
        if !saw_objects.get() || !tree.files.iter().any(|entry| entry.relative == ".git/HEAD") {
            return Err(CaptureFailure::Repository(ErrorCode::UnsupportedFile));
        }
        let mut ignore_case = None;
        for entry in &tree.files {
            match entry.relative.as_str() {
                ".git/config" => ignore_case = validate_source_config(&entry.bytes).map_err(CaptureFailure::Repository)?,
                ".git/info/exclude" => validate_excludes(&entry.bytes).map_err(CaptureFailure::Repository)?,
                _ => {}
            }
        }
        Ok(Some(Self { tree, ignore_case: ignore_case.unwrap_or(false) }))
    }

    fn frame(&self, operation: super::git_reader::ReaderOperation<'_>) -> Result<Vec<u8>, ErrorCode> {
        self.tree.verify()?;
        let mut files = Vec::new();
        files.try_reserve_exact(self.tree.files.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
        for entry in &self.tree.files {
            if matches!(entry.relative.as_str(), ".git/config" | ".git/info/exclude") {
                continue;
            }
            let bytes = if entry.relative == ".git/index" {
                sanitize_index(&entry.bytes)?
            } else {
                if entry.relative == ".git/HEAD" || entry.relative == ".git/packed-refs"
                    || entry.relative.starts_with(".git/refs/") {
                    validate_ref(&entry.relative, &entry.bytes)?;
                }
                entry.bytes.clone()
            };
            files.push((entry.relative.as_str(), bytes));
        }
        super::git_reader::encode_input(operation, self.ignore_case, &files)
    }

    pub(crate) fn candidates(
        &self, supervisor: &super::git_reader::GitSupervisor,
        cancelled: impl Fn() -> bool,
    ) -> Result<StringSet<RelativePath>, ErrorCode> {
        let frame = self.frame(super::git_reader::ReaderOperation::List)?;
        let response = super::git_reader::execute(supervisor, &frame, cancelled)?;
        self.tree.verify()?;
        let super::git_reader::ReaderResponse::List { paths } = response else {
            return Err(ErrorCode::RuntimeFailed);
        };
        let mut canonical = Vec::new();
        canonical.try_reserve_exact(paths.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
        for path in paths {
            canonical.push(RelativePath::new(path).map_err(|_| ErrorCode::UnsupportedFile)?);
        }
        canonical.sort();
        canonical.dedup();
        StringSet::new(canonical).map_err(|_| ErrorCode::ResourceExhausted)
    }

    pub(crate) fn diff(
        &self, supervisor: &super::git_reader::GitSupervisor, path: &RelativePath,
        max_bytes: usize, cancelled: impl Fn() -> bool,
    ) -> Result<(FileKind, Nullable<String>, bool), ErrorCode> {
        let frame = self.frame(super::git_reader::ReaderOperation::Diff { path, max_bytes })?;
        let response = super::git_reader::execute(supervisor, &frame, cancelled)?;
        self.tree.verify()?;
        let super::git_reader::ReaderResponse::Diff { kind, text, truncated } = response else {
            return Err(ErrorCode::RuntimeFailed);
        };
        if text.as_ref().is_some_and(|value| value.len() > max_bytes)
            || (kind == FileKind::Binary && (text.is_some() || truncated)) {
            return Err(ErrorCode::RuntimeFailed);
        }
        Ok((kind, Nullable(text), truncated))
    }

    pub(crate) fn verify_selected(&self, path: &RelativePath, current: &ObservedFile) -> Result<(), ErrorCode> {
        let expected = self.tree.files.iter().find(|file| file.relative == path.as_str())
            .ok_or(ErrorCode::RootChanged)?;
        if current.size_bytes != expected.bytes.len() as u64 {
            return Err(ErrorCode::RootChanged);
        }
        let mut position = 0usize;
        let mut buffer = [0u8; 8192];
        while position < expected.bytes.len() {
            let count = buffer.len().min(expected.bytes.len() - position);
            let read = current.read(&mut buffer[..count]).map_err(|error| error.code())?;
            if read == 0 || buffer[..read] != expected.bytes[position..position + read] {
                return Err(ErrorCode::RootChanged);
            }
            position += read;
        }
        if current.read(&mut buffer[..1]).map_err(|error| error.code())? != 0 {
            return Err(ErrorCode::RootChanged);
        }
        Ok(())
    }
}

fn validate_excludes(bytes: &[u8]) -> Result<(), ErrorCode> {
    let source = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
    if source.lines().any(|line| {
        let line = line.trim();
        !line.is_empty() && !line.starts_with('#')
    }) { return Err(ErrorCode::UnsupportedFile); }
    Ok(())
}

fn validate_source_config(bytes: &[u8]) -> Result<Option<bool>, ErrorCode> {
    let source = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
    let mut section = String::new();
    let mut ignore_case = None;
    for line in source.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(['#', ';']) { continue; }
        if line.contains('\\') || line.contains('\0') { return Err(ErrorCode::UnsupportedFile); }
        if line.starts_with('[') {
            let inner = line.strip_prefix('[').and_then(|line| line.strip_suffix(']'))
                .ok_or(ErrorCode::UnsupportedFile)?;
            section = inner.split([' ', '\t', '"']).next().unwrap_or("").to_ascii_lowercase();
            if section == "core" && !inner.eq_ignore_ascii_case("core") {
                return Err(ErrorCode::UnsupportedFile);
            }
            if !matches!(section.as_str(), "core" | "remote" | "branch" | "user"
                | "credential" | "receive" | "advice" | "init" | "gc" | "pull" | "push") {
                return Err(ErrorCode::UnsupportedFile);
            }
            continue;
        }
        let (key, value) = line.split_once('=').ok_or(ErrorCode::UnsupportedFile)?;
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim().to_ascii_lowercase();
        if section.is_empty() || key.is_empty() { return Err(ErrorCode::UnsupportedFile); }
        if section == "core" {
            match key.as_str() {
                "ignorecase" if matches!(value.as_str(), "true" | "false") && ignore_case.is_none() => {
                    ignore_case = Some(value == "true");
                }
                "repositoryformatversion" if value == "0" => {}
                "bare" if value == "false" => {}
                "filemode" | "logallrefupdates" | "symlinks" | "quotepath" | "longpaths"
                    if matches!(value.as_str(), "true" | "false") => {}
                _ => return Err(ErrorCode::UnsupportedFile),
            }
        }
    }
    Ok(ignore_case)
}

pub(super) fn safe_git_component(relative: &str, directory: bool) -> bool {
    let tail = &relative[5..];
    if directory {
        return tail == "info" || tail == "objects" || tail == "objects/info" || tail == "objects/pack"
            || tail == "refs" || tail.strip_prefix("refs/").is_some_and(safe_ref_name)
            || (tail.starts_with("objects/") && tail.len() == "objects/xx".len()
                && tail[8..].bytes().all(|byte| byte.is_ascii_hexdigit()));
    }
    if tail == "HEAD" || tail == "index" || tail == "packed-refs" { return true; }
    if tail.starts_with("refs/") { return safe_ref_name(&tail[5..]); }
    if let Some(object) = tail.strip_prefix("objects/") {
        if object.len() == 41 && object.as_bytes()[2] == b'/' {
            return object[..2].bytes().all(|byte| byte.is_ascii_hexdigit())
                && object[3..].bytes().all(|byte| byte.is_ascii_hexdigit());
        }
        if let Some(pack) = object.strip_prefix("pack/pack-") {
            let hash = pack.strip_suffix(".pack").or_else(|| pack.strip_suffix(".idx"));
            return hash.is_some_and(|hash| hash.len() == 40 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()));
        }
    }
    false
}

pub(super) fn safe_ref_name(name: &str) -> bool {
    !name.is_empty() && !name.contains("..") && !name.contains("@{")
        && name.split('/').all(|part| !part.is_empty() && !part.starts_with('.') && !part.ends_with(".lock")
            && !part.ends_with('.') && !part.bytes().any(|byte| matches!(byte, b' ' | b'~' | b'^' | b':' | b'?' | b'*' | b'[' | b'\\')))
}

pub(super) fn validate_ref(relative: &str, bytes: &[u8]) -> Result<(), ErrorCode> {
    if relative == ".git/packed-refs" {
        let text = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
        for line in text.lines() {
            if line.starts_with('#') || line.is_empty() { continue; }
            if let Some(hash) = line.strip_prefix('^') {
                if !hex40(hash) { return Err(ErrorCode::UnsupportedFile); }
                continue;
            }
            let Some((hash, name)) = line.split_once(' ') else { return Err(ErrorCode::UnsupportedFile) };
            if !hex40(hash) || !name.starts_with("refs/") || !safe_ref_name(&name[5..]) {
                return Err(ErrorCode::UnsupportedFile);
            }
        }
        return Ok(());
    }
    let text = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
    let value = text.trim_end_matches(['\r', '\n']);
    if hex40(value) { return Ok(()); }
    if relative == ".git/HEAD" && value.strip_prefix("ref: refs/").is_some_and(safe_ref_name) {
        return Ok(());
    }
    Err(ErrorCode::UnsupportedFile)
}

pub(super) fn hex40(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(super) fn sanitize_index(bytes: &[u8]) -> Result<Vec<u8>, ErrorCode> {
    if bytes.len() < 32 || &bytes[..4] != b"DIRC" { return Err(ErrorCode::UnsupportedFile); }
    let end = bytes.len() - 20;
    if sha1(&bytes[..end])? != bytes[end..] { return Err(ErrorCode::UnsupportedFile); }
    let version = u32::from_be_bytes(bytes[4..8].try_into().unwrap());
    if version != 2 && version != 3 { return Err(ErrorCode::UnsupportedFile); }
    let entries = u32::from_be_bytes(bytes[8..12].try_into().unwrap()) as usize;
    let mut pos = 12usize;
    let mut previous: Option<&str> = None;
    for _ in 0..entries {
        if pos.checked_add(62).is_none_or(|next| next > end) { return Err(ErrorCode::UnsupportedFile); }
        let mode = u32::from_be_bytes(bytes[pos + 24..pos + 28].try_into().unwrap());
        if !matches!(mode, 0o100644 | 0o100755) { return Err(ErrorCode::UnsupportedFile); }
        let flags = u16::from_be_bytes(bytes[pos + 60..pos + 62].try_into().unwrap());
        if flags & 0x7000 != 0 { return Err(ErrorCode::UnsupportedFile); }
        let Some(nul) = bytes[pos + 62..end].iter().position(|byte| *byte == 0) else { return Err(ErrorCode::UnsupportedFile) };
        let name = std::str::from_utf8(&bytes[pos + 62..pos + 62 + nul]).map_err(|_| ErrorCode::UnsupportedFile)?;
        RelativePath::new(name.to_owned()).map_err(|_| ErrorCode::UnsupportedFile)?;
        if (flags & 0x0fff) != 0x0fff && (flags & 0x0fff) as usize != nul {
            return Err(ErrorCode::UnsupportedFile);
        }
        if previous.is_some_and(|before| before >= name || before.eq_ignore_ascii_case(name)) {
            return Err(ErrorCode::UnsupportedFile);
        }
        previous = Some(name);
        let next = pos.checked_add((62 + nul + 1 + 7) & !7).ok_or(ErrorCode::UnsupportedFile)?;
        if next > end || bytes[pos + 62 + nul..next].iter().any(|byte| *byte != 0) {
            return Err(ErrorCode::UnsupportedFile);
        }
        pos = next;
    }
    let entries_end = pos;
    while pos < end {
        if pos.checked_add(8).is_none_or(|next| next > end) { return Err(ErrorCode::UnsupportedFile); }
        let signature = &bytes[pos..pos + 4];
        if !signature.iter().all(u8::is_ascii_alphabetic) || !signature[0].is_ascii_uppercase() {
            return Err(ErrorCode::UnsupportedFile);
        }
        let length = u32::from_be_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        pos = pos.checked_add(8).and_then(|value| value.checked_add(length))
            .filter(|value| *value <= end).ok_or(ErrorCode::UnsupportedFile)?;
    }
    let mut sanitized = Vec::new();
    sanitized.try_reserve_exact(entries_end + 20).map_err(|_| ErrorCode::ResourceExhausted)?;
    sanitized.extend_from_slice(&bytes[..entries_end]);
    sanitized.extend_from_slice(&sha1(&sanitized)?);
    Ok(sanitized)
}

pub(super) fn sha1(bytes: &[u8]) -> Result<[u8; 20], ErrorCode> {
    let size = u32::try_from(bytes.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
    let mut algorithm = std::ptr::null_mut();
    if unsafe { BCryptOpenAlgorithmProvider(&mut algorithm, BCRYPT_SHA1_ALGORITHM, std::ptr::null(), 0) } < 0
        || algorithm.is_null() { return Err(ErrorCode::RuntimeFailed); }
    let mut digest = [0u8; 20];
    let status = unsafe { BCryptHash(
        algorithm, std::ptr::null(), 0, bytes.as_ptr(), size, digest.as_mut_ptr(), digest.len() as u32,
    ) };
    unsafe { BCryptCloseAlgorithmProvider(algorithm, 0); }
    if status < 0 { Err(ErrorCode::RuntimeFailed) } else { Ok(digest) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use crate::host::admission::{AllocationAuthority, AllocationPool};
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::Storage::FileSystem::{FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE};

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateFileMappingW(file: windows_sys::Win32::Foundation::HANDLE,
            attributes: *const core::ffi::c_void, protect: u32, high: u32, low: u32,
            name: *const u16) -> windows_sys::Win32::Foundation::HANDLE;
        fn MapViewOfFile(mapping: windows_sys::Win32::Foundation::HANDLE,
            access: u32, high: u32, low: u32, size: usize) -> *mut u8;
        fn UnmapViewOfFile(view: *const u8) -> i32;
    }

    #[test]
    fn source_config_and_exclude_rules_are_explicitly_rejected() {
        let ordinary = b"[core]\nrepositoryformatversion = 0\nfilemode = false\nbare = false\nlogallrefupdates = true\n[remote \"origin\"]\nurl = https://example.invalid/repo\n";
        assert_eq!(validate_source_config(ordinary), Ok(None));
        assert_eq!(validate_source_config(b"[core]\nignoreCase = true\n"), Ok(Some(true)));
        assert_eq!(validate_source_config(b"[core]\nignoreCase = false\n"), Ok(Some(false)));
        assert_eq!(validate_source_config(b"[core]\nignoreCase = true\nignorecase = false\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_source_config(b"[core]\nignoreCase = yes\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_source_config(b"[core \"other\"]\nignoreCase = true\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_source_config(b"[include]\npath = C:/outside/config\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_source_config(b"[core]\nautocrlf = true\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_source_config(b"[filter \"evil\"]\nclean = cmd\n"), Err(ErrorCode::UnsupportedFile));
        assert_eq!(validate_excludes(b"# default comments\n\n"), Ok(()));
        assert_eq!(validate_excludes(b"*.private\n"), Err(ErrorCode::UnsupportedFile));
    }

    #[test]
    fn source_info_attributes_cannot_be_silently_ignored() {
        let root = std::env::temp_dir().join(format!("winsmux-p03-attributes-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join(".git/objects")).unwrap();
        fs::create_dir_all(root.join(".git/info")).unwrap();
        fs::write(root.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        fs::write(root.join(".git/config"), b"[core]\nrepositoryformatversion = 0\nbare = false\n").unwrap();
        fs::write(root.join(".git/info/attributes"), b"*.txt filter=outside\n").unwrap();
        let authority = AllocationAuthority::host();
        let path = root.to_str().unwrap();
        let identity = root_identity::observe_root(path, &authority, AllocationPool::ActiveOwner).unwrap().identity;
        match CapturedRepository::new(path, &identity, &authority, AllocationPool::ActiveOwner) {
            Err(error) => assert_eq!(error, ErrorCode::UnsupportedFile),
            Ok(_) => panic!("source attributes must reject capture"),
        }
        fs::remove_file(root.join(".git/info/attributes")).unwrap();
        fs::write(root.join(".git/info/exclude"), b"*.private\n").unwrap();
        match CapturedRepository::new(path, &identity, &authority, AllocationPool::ActiveOwner) {
            Err(error) => assert_eq!(error, ErrorCode::UnsupportedFile),
            Ok(_) => panic!("source exclude rules must reject capture"),
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn held_capture_refuses_ordinary_write_and_rename_until_request_finishes() {
        let root = std::env::temp_dir().join(format!("winsmux-p03-capture-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join(".git/objects")).unwrap();
        fs::write(root.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        fs::write(root.join(".git/config"), b"[core]\nrepositoryformatversion = 0\nbare = false\n").unwrap();
        fs::write(root.join("selected.txt"), b"fixed bytes\n").unwrap();
        let authority = AllocationAuthority::host();
        let path = root.to_str().unwrap();
        let identity = root_identity::observe_root(path, &authority, AllocationPool::ActiveOwner).unwrap().identity;
        let captured = CapturedRepository::new(path, &identity, &authority, AllocationPool::ActiveOwner)
            .unwrap().unwrap();
        let frame = captured.frame(super::super::git_reader::ReaderOperation::List).unwrap();
        assert!(frame.starts_with(b"WSMXGIT4"));
        assert!(fs::write(root.join("selected.txt"), b"changed").is_err());
        assert!(fs::write(root.join(".git/HEAD"), b"changed").is_err());
        assert!(fs::rename(root.join("selected.txt"), root.join("replacement.txt")).is_err());
        captured.tree.verify().unwrap();
        drop(captured);
        fs::write(root.join("selected.txt"), b"changed").unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cross_directory_rename_is_observational_and_selected_handle_cannot_switch_target() {
        let root = std::env::temp_dir().join(format!("winsmux-p03-rename-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join(".git/objects")).unwrap();
        fs::create_dir(root.join("A")).unwrap();
        fs::create_dir(root.join("B")).unwrap();
        fs::write(root.join("B/selected.txt"), b"fixed target\n").unwrap();
        fs::write(root.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        fs::write(root.join(".git/config"), b"[core]\nrepositoryformatversion = 0\nbare = false\n").unwrap();
        let authority = AllocationAuthority::host();
        let path = root.to_str().unwrap();
        let identity = root_identity::observe_root(path, &authority, AllocationPool::ActiveOwner).unwrap().identity;
        let mut rename_attempted = false;
        let mut rename_succeeded = false;
        let captured = root_identity::capture_project_tree(
            path, &identity, &authority, AllocationPool::ActiveOwner,
            |relative, directory| {
                if relative == "B" && directory {
                    fs::write(root.join("A/moving.txt"), b"moving bytes\n").unwrap();
                    rename_succeeded = fs::rename(root.join("A/moving.txt"), root.join("B/moving.txt")).is_ok();
                    rename_attempted = true;
                }
                Ok(true)
            },
        ).unwrap().unwrap();
        assert!(rename_attempted);
        let selected = captured.files.iter().find(|file| file.relative == "B/selected.txt").unwrap();
        assert_eq!(selected.bytes, b"fixed target\n");
        assert!(!captured.files.iter().any(|file| file.relative == "A/moving.txt"));
        assert_eq!(captured.files.iter().any(|file| file.relative == "B/moving.txt"), rename_succeeded);
        assert!(fs::rename(root.join("B/selected.txt"), root.join("A/selected.txt")).is_err());
        assert!(fs::write(root.join("B/selected.txt"), b"wrong target\n").is_err());
        captured.verify().unwrap();
        drop(captured);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn preexisting_writable_mapping_view_rejects_capture_on_windows() {
        let root = std::env::temp_dir().join(format!("winsmux-p03-map-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(root.join(".git/objects")).unwrap();
        fs::write(root.join(".git/HEAD"), b"ref: refs/heads/main\n").unwrap();
        fs::write(root.join(".git/config"), b"[core]\nrepositoryformatversion = 0\nbare = false\n").unwrap();
        fs::write(root.join("selected.txt"), b"original bytes\n").unwrap();
        let writable = fs::OpenOptions::new().read(true).write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .open(root.join("selected.txt")).unwrap();
        let mapping = unsafe { CreateFileMappingW(writable.as_raw_handle() as _, std::ptr::null(),
            0x04, 0, 0, std::ptr::null()) };
        assert!(!mapping.is_null());
        let view = unsafe { MapViewOfFile(mapping, 0x0002, 0, 0, 0) };
        assert!(!view.is_null());
        unsafe { CloseHandle(mapping); }
        drop(writable);
        let authority = AllocationAuthority::host();
        let path = root.to_str().unwrap();
        let identity = root_identity::observe_root(path, &authority, AllocationPool::ActiveOwner).unwrap().identity;
        assert!(matches!(
            CapturedRepository::new(path, &identity, &authority, AllocationPool::ActiveOwner),
            Err(ErrorCode::RuntimeFailed)
        ));
        unsafe { assert_ne!(UnmapViewOfFile(view), 0); }
        fs::remove_dir_all(root).unwrap();
    }
}
