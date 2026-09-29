//! Fixed byte protocol for the isolated, memory-only Git reader.

mod native;
mod image_imports;

use crate::contract::{ErrorCode, FileKind, RelativePath, MAX_MESSAGE_BYTES};
use git2::Patch;
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::Match;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::Mutex;
use crate::host::io::OwnedHandle;
use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Console::{GetStdHandle, STD_OUTPUT_HANDLE};
use windows_sys::Win32::System::LibraryLoader::{
    SetDefaultDllDirectories, LOAD_LIBRARY_SEARCH_APPLICATION_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32,
};

const MAGIC: &[u8; 8] = b"WSMXGIT4";
const SHA256_BYTES: usize = 32;
type Oid = [u8; 20];

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, tag = "result", rename_all = "snake_case")]
pub(super) enum ReaderResponse {
    List { paths: Vec<String> },
    Diff { kind: FileKind, text: Option<String>, truncated: bool },
    Error { code: ErrorCode },
}

pub(crate) struct GitSupervisor {
    state: Mutex<SupervisorState>,
}

enum SupervisorState {
    Open(Option<OwnedHandle>),
    Closed,
}

impl GitSupervisor {
    pub(crate) fn new() -> Self { Self { state: Mutex::new(SupervisorState::Open(None)) } }
    pub(crate) fn close(&self) { *self.state.lock().unwrap() = SupervisorState::Closed; }
}

pub(super) enum ReaderOperation<'a> {
    List,
    Diff { path: &'a RelativePath, max_bytes: usize },
}

pub(super) fn execute(
    supervisor: &GitSupervisor, frame: &[u8], cancelled: impl Fn() -> bool,
) -> Result<ReaderResponse, ErrorCode> {
    native::execute(supervisor, frame, cancelled)
}

fn append_u16(out: &mut Vec<u8>, value: usize) -> Result<(), ErrorCode> {
    out.extend_from_slice(&u16::try_from(value).map_err(|_| ErrorCode::ResourceExhausted)?.to_le_bytes());
    Ok(())
}

fn append_u32(out: &mut Vec<u8>, value: usize) -> Result<(), ErrorCode> {
    out.extend_from_slice(&u32::try_from(value).map_err(|_| ErrorCode::ResourceExhausted)?.to_le_bytes());
    Ok(())
}

/// The outer native pipe adds one length prefix. The body has its own digest
/// and exact-consumption check; it contains no repository path or OS handle.
pub(super) fn encode_input(
    operation: ReaderOperation<'_>, ignore_case: bool, files: &[(&str, Vec<u8>)],
) -> Result<Vec<u8>, ErrorCode> {
    let (tag, path, max_bytes) = match operation {
        ReaderOperation::List => (1u8, "", 0usize),
        ReaderOperation::Diff { path, max_bytes } => (2u8, path.as_str(), max_bytes),
    };
    let mut out = Vec::new();
    out.extend_from_slice(MAGIC);
    out.push(tag);
    out.push(u8::from(ignore_case));
    append_u32(&mut out, max_bytes)?;
    append_u16(&mut out, path.len())?;
    out.extend_from_slice(path.as_bytes());
    append_u32(&mut out, files.len())?;
    let mut sorted = files.iter().collect::<Vec<_>>();
    sorted.sort_by(|left, right| left.0.cmp(right.0));
    let mut previous = None::<&str>;
    for (name, bytes) in sorted {
        if previous.is_some_and(|before| before >= *name || before.eq_ignore_ascii_case(name)) {
            return Err(ErrorCode::UnsupportedFile);
        }
        previous = Some(name);
        RelativePath::new((*name).to_owned()).map_err(|_| ErrorCode::UnsupportedFile)?;
        append_u16(&mut out, name.len())?;
        out.extend_from_slice(name.as_bytes());
        append_u32(&mut out, bytes.len())?;
        out.extend_from_slice(bytes);
        if out.len() + SHA256_BYTES > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    }
    let digest = Sha256::digest(&out);
    out.extend_from_slice(&digest);
    if out.len() > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    Ok(out)
}

struct Cursor<'a> { input: &'a [u8], pos: usize }
impl<'a> Cursor<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], ErrorCode> {
        let end = self.pos.checked_add(count).filter(|end| *end <= self.input.len())
            .ok_or(ErrorCode::UnsupportedFile)?;
        let slice = &self.input[self.pos..end];
        self.pos = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8, ErrorCode> { Ok(self.take(1)?[0]) }
    fn u16_le(&mut self) -> Result<usize, ErrorCode> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()) as usize)
    }
    fn u32_le(&mut self) -> Result<usize, ErrorCode> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()) as usize)
    }
}

struct Input {
    operation: u8,
    ignore_case: bool,
    path: Option<String>,
    max_bytes: usize,
    files: BTreeMap<String, Vec<u8>>,
}

fn decode_input(input: &[u8]) -> Result<Input, ErrorCode> {
    if input.len() < MAGIC.len() + 2 + 4 + 2 + 4 + SHA256_BYTES || input.len() > MAX_MESSAGE_BYTES {
        return Err(ErrorCode::UnsupportedFile);
    }
    let end = input.len() - SHA256_BYTES;
    if Sha256::digest(&input[..end]).as_slice() != &input[end..] {
        return Err(ErrorCode::UnsupportedFile);
    }
    let mut cursor = Cursor { input: &input[..end], pos: 0 };
    if cursor.take(8)? != MAGIC { return Err(ErrorCode::UnsupportedFile); }
    let operation = cursor.u8()?;
    if operation != 1 && operation != 2 { return Err(ErrorCode::UnsupportedFile); }
    let ignore_case = match cursor.u8()? {
        0 => false,
        1 => true,
        _ => return Err(ErrorCode::UnsupportedFile),
    };
    let max_bytes = cursor.u32_le()?;
    let path_len = cursor.u16_le()?;
    let path_bytes = cursor.take(path_len)?;
    let path = if operation == 2 {
        let path = std::str::from_utf8(path_bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
        Some(RelativePath::new(path.to_owned()).map_err(|_| ErrorCode::UnsupportedFile)?.as_str().to_owned())
    } else {
        if !path_bytes.is_empty() || max_bytes != 0 { return Err(ErrorCode::UnsupportedFile); }
        None
    };
    let count = cursor.u32_le()?;
    if count > MAX_MESSAGE_BYTES / 8 { return Err(ErrorCode::UnsupportedFile); }
    let mut files = BTreeMap::new();
    let mut previous = None::<String>;
    for _ in 0..count {
        let name_len = cursor.u16_le()?;
        let name = std::str::from_utf8(cursor.take(name_len)?)
            .map_err(|_| ErrorCode::UnsupportedFile)?;
        RelativePath::new(name.to_owned()).map_err(|_| ErrorCode::UnsupportedFile)?;
        if previous.as_deref().is_some_and(|before| before >= name || before.eq_ignore_ascii_case(name)) {
            return Err(ErrorCode::UnsupportedFile);
        }
        if name.starts_with(".git/") && !super::git_snapshot::safe_git_component(name, false) {
            return Err(ErrorCode::UnsupportedFile);
        }
        previous = Some(name.to_owned());
        let data_len = cursor.u32_le()?;
        let bytes = cursor.take(data_len)?.to_vec();
        files.insert(name.to_owned(), bytes);
    }
    if cursor.pos != end { return Err(ErrorCode::UnsupportedFile); }
    if !files.contains_key(".git/HEAD") { return Err(ErrorCode::UnsupportedFile); }
    Ok(Input { operation, ignore_case, path, max_bytes, files })
}

fn read_frame(mut reader: impl Read) -> Result<Vec<u8>, ErrorCode> {
    let mut prefix = [0u8; 4];
    reader.read_exact(&mut prefix).map_err(|_| ErrorCode::RuntimeFailed)?;
    let len = u32::from_le_bytes(prefix) as usize;
    if len == 0 || len > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).map_err(|_| ErrorCode::RuntimeFailed)?;
    let mut extra = [0u8; 1];
    if reader.read(&mut extra).map_err(|_| ErrorCode::RuntimeFailed)? != 0 {
        return Err(ErrorCode::UnsupportedFile);
    }
    Ok(body)
}

fn write_frame(mut writer: impl Write, body: &[u8]) -> Result<(), ErrorCode> {
    if body.is_empty() || body.len() > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    writer.write_all(&(body.len() as u32).to_le_bytes()).map_err(|_| ErrorCode::RuntimeFailed)?;
    writer.write_all(body).map_err(|_| ErrorCode::RuntimeFailed)?;
    writer.flush().map_err(|_| ErrorCode::RuntimeFailed)
}

pub(crate) fn run_internal_git_reader() -> i32 {
    let frame = match read_frame(std::io::stdin()) { Ok(frame) => frame, Err(_) => return 1 };
    if unsafe { SetDefaultDllDirectories(
        LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) } == 0 { return 1; }
    let response = match read_repository(&frame) {
        Ok(response) => response,
        Err(code) => ReaderResponse::Error { code },
    };
    let bytes = match serde_json::to_vec(&response) { Ok(bytes) => bytes, Err(_) => return 1 };
    if write_frame(std::io::stdout(), &bytes).is_err() { return 1; }
    let output = unsafe { GetStdHandle(STD_OUTPUT_HANDLE) };
    if output.is_null() || output == INVALID_HANDLE_VALUE || unsafe { CloseHandle(output) } == 0 {
        return 1;
    }
    0
}

fn read_repository(frame: &[u8]) -> Result<ReaderResponse, ErrorCode> {
    let input = decode_input(frame)?;
    let interpreted = Interpreted::new(&input)?;
    match input.operation {
        1 => Ok(ReaderResponse::List { paths: interpreted.candidates()? }),
        2 => interpreted.diff(input.path.as_deref().ok_or(ErrorCode::UnsupportedFile)?, input.max_bytes),
        _ => Err(ErrorCode::UnsupportedFile),
    }
}

#[derive(Clone)]
struct GitObject { kind: u8, bytes: Vec<u8> }

struct Interpreted<'a> {
    input: &'a Input,
    objects: HashMap<Oid, GitObject>,
    head: BTreeMap<String, (u32, Oid)>,
    index: BTreeMap<String, (u32, Oid)>,
    workdir: BTreeMap<String, Oid>,
    ignore_rules: Vec<FixedIgnore>,
}

struct FixedIgnore {
    directory: String,
    matcher: Gitignore,
}

fn metadata_name(path: &str) -> Option<&str> {
    let name = path.rsplit('/').next()?;
    match name.to_ascii_lowercase().as_str() {
        ".gitignore" => Some(".gitignore"),
        ".gitattributes" => Some(".gitattributes"),
        ".gitmodules" => Some(".gitmodules"),
        _ => None,
    }
}

fn harmless_metadata(bytes: &[u8], gitmodules: bool) -> Result<(), ErrorCode> {
    let text = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
    if text.lines().any(|line| {
        let line = line.trim();
        !line.is_empty() && !line.starts_with('#') && !(gitmodules && line.starts_with(';'))
    }) { return Err(ErrorCode::UnsupportedFile); }
    Ok(())
}

fn fixed_ignores(input: &Input) -> Result<Vec<FixedIgnore>, ErrorCode> {
    let mut rules = Vec::new();
    for (name, bytes) in &input.files {
        if name.starts_with(".git/") || metadata_name(name) != Some(".gitignore") { continue; }
        let directory = name.rsplit_once('/').map(|(dir, _)| dir).unwrap_or("");
        let virtual_root = Path::new("__winsmux_fixed_gitinput__").join(directory);
        let mut builder = GitignoreBuilder::new(&virtual_root);
        builder.case_insensitive(input.ignore_case).map_err(|_| ErrorCode::UnsupportedFile)?;
        let source = std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
        for line in source.lines() {
            builder.add_line(None, line).map_err(|_| ErrorCode::UnsupportedFile)?;
        }
        let matcher = builder.build().map_err(|_| ErrorCode::UnsupportedFile)?;
        rules.push(FixedIgnore { directory: directory.to_owned(), matcher });
    }
    rules.sort_by(|a, b| a.directory.matches('/').count().cmp(&b.directory.matches('/').count())
        .then_with(|| a.directory.cmp(&b.directory)));
    Ok(rules)
}

fn ignore_match(rules: &[FixedIgnore], path: &str, directory: bool) -> bool {
    let mut ignored = false;
    for rule in rules {
        if !rule.directory.is_empty() && !path.starts_with(&format!("{}/", rule.directory)) {
            continue;
        }
        let logical = Path::new("__winsmux_fixed_gitinput__").join(path);
        match rule.matcher.matched(&logical, directory) {
            Match::Ignore(_) => ignored = true,
            Match::Whitelist(_) => ignored = false,
            Match::None => {}
        }
    }
    ignored
}

fn is_ignored(rules: &[FixedIgnore], path: &str) -> bool {
    let mut ancestor = String::new();
    for segment in path.split('/').take(path.split('/').count().saturating_sub(1)) {
        if !ancestor.is_empty() { ancestor.push('/'); }
        ancestor.push_str(segment);
        if ignore_match(rules, &ancestor, true) { return true; }
    }
    ignore_match(rules, path, false)
}

impl<'a> Interpreted<'a> {
    fn new(input: &'a Input) -> Result<Self, ErrorCode> {
        let mut objects = HashMap::new();
        let mut decoded = 0usize;
        for (name, bytes) in &input.files {
            if let Some(oid) = loose_name(name)? {
                let object = decode_loose(bytes)?;
                decoded = decoded.checked_add(object.bytes.len())
                    .filter(|sum| *sum <= MAX_MESSAGE_BYTES).ok_or(ErrorCode::ResourceExhausted)?;
                if hash_object(object.kind, &object.bytes)? != oid || objects.insert(oid, object).is_some() {
                    return Err(ErrorCode::UnsupportedFile);
                }
            }
        }
        decode_packs(&input.files, &mut objects)?;
        let ignore_rules = fixed_ignores(input)?;
        let head = head_tree(&input.files, &objects)?;
        let index = if let Some(bytes) = input.files.get(".git/index") {
            parse_index(bytes)?
        } else {
            if !head.is_empty() { return Err(ErrorCode::UnsupportedFile); }
            BTreeMap::new()
        };
        let mut workdir = BTreeMap::new();
        for (name, bytes) in &input.files {
            if name == ".git" || name.starts_with(".git/") { continue; }
            match metadata_name(name) {
                Some(".gitattributes") => harmless_metadata(bytes, false)?,
                Some(".gitmodules") => harmless_metadata(bytes, true)?,
                _ => {}
            }
            let oid = hash_object(3, bytes)?;
            if workdir.insert(name.to_owned(), oid).is_some() { return Err(ErrorCode::UnsupportedFile); }
        }
        for (_, oid) in head.values().chain(index.values()) {
            if objects.get(oid).is_none_or(|object| object.kind != 3) {
                return Err(ErrorCode::UnsupportedFile);
            }
        }
        for (path, (_, oid)) in head.iter().chain(index.iter()) {
            let gitmodules = match metadata_name(path) {
                Some(".gitattributes") => false,
                Some(".gitmodules") => true,
                _ => continue,
            };
            let object = objects.get(oid).ok_or(ErrorCode::UnsupportedFile)?;
            harmless_metadata(&object.bytes, gitmodules)?;
        }
        let mut folded = BTreeMap::<String, String>::new();
        for path in head.keys().chain(index.keys()).chain(workdir.keys()) {
            let key = path.to_lowercase();
            if let Some(prior) = folded.insert(key, path.clone()) {
                if prior != *path { return Err(ErrorCode::UnsupportedFile); }
            }
        }
        Ok(Self { input, objects, head, index, workdir, ignore_rules })
    }

    fn candidates(&self) -> Result<Vec<String>, ErrorCode> {
        let mut paths = BTreeSet::new();
        paths.extend(self.head.keys().cloned());
        paths.extend(self.index.keys().cloned());
        paths.extend(self.workdir.keys().cloned());
        let mut result = Vec::new();
        for path in paths {
            let head = self.head.get(&path);
            let index = self.index.get(&path);
            let work = self.workdir.get(&path);
            if head.is_none() && index.is_none() && is_ignored(&self.ignore_rules, &path) {
                continue;
            }
            if head != index || index.map(|entry| &entry.1) != work {
                result.push(path);
            }
        }
        Ok(result)
    }

    fn diff(&self, path: &str, max_bytes: usize) -> Result<ReaderResponse, ErrorCode> {
        let work = self.input.files.get(path).ok_or(ErrorCode::TargetNotFound)?;
        let head = self.head.get(path);
        let index = self.index.get(path);
        if head.is_some_and(|h| index.is_some_and(|i| h.0 != i.0)) {
            return Err(ErrorCode::UnsupportedFile);
        }
        let old = head.map(|(_, oid)| self.objects.get(oid).map(|value| value.bytes.as_slice()))
            .transpose_option()?.unwrap_or(&[]);
        let deleted = head.is_some() && index.is_none();
        let new = if deleted { &[][..] } else { work.as_slice() };
        if old.contains(&0) || new.contains(&0)
            || std::str::from_utf8(old).is_err() || std::str::from_utf8(new).is_err() {
            return Ok(ReaderResponse::Diff { kind: FileKind::Binary, text: None, truncated: false });
        }
        if !deleted && head.is_some() && old == new {
            return Ok(ReaderResponse::Diff { kind: FileKind::Text, text: Some(String::new()), truncated: false });
        }
        let text = render_patch(path, old, new, head.is_none(), deleted)?;
        let mut end = text.len().min(max_bytes);
        while !text.is_char_boundary(end) { end -= 1; }
        Ok(ReaderResponse::Diff {
            kind: FileKind::Text, text: Some(text[..end].to_owned()), truncated: end < text.len(),
        })
    }
}

trait TransposeOption<T> { fn transpose_option(self) -> Result<Option<T>, ErrorCode>; }
impl<T> TransposeOption<T> for Option<Option<T>> {
    fn transpose_option(self) -> Result<Option<T>, ErrorCode> {
        match self { Some(None) => Err(ErrorCode::UnsupportedFile), Some(Some(value)) => Ok(Some(value)), None => Ok(None) }
    }
}

fn render_patch(path: &str, old: &[u8], new: &[u8], added: bool, deleted: bool) -> Result<String, ErrorCode> {
    let name = Path::new(path);
    let mut patch = Patch::from_buffers(old, Some(name), new, Some(name), None)
        .map_err(|_| ErrorCode::UnsupportedFile)?;
    let raw = patch.to_buf().map_err(|_| ErrorCode::UnsupportedFile)?;
    let raw = std::str::from_utf8(raw.as_ref()).map_err(|_| ErrorCode::UnsupportedFile)?;
    let hunks = raw.find("@@ ").map_or("", |offset| &raw[offset..]);
    let mut out = format!("diff --git a/{path} b/{path}\n");
    if added { out.push_str("new file mode 100644\n"); }
    if deleted { out.push_str("deleted file mode 100644\n"); }
    out.push_str(if added { "--- /dev/null\n" } else { "--- a/" });
    if !added { out.push_str(path); out.push('\n'); }
    out.push_str(if deleted { "+++ /dev/null\n" } else { "+++ b/" });
    if !deleted { out.push_str(path); out.push('\n'); }
    out.push_str(hunks);
    if out.len() > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
    Ok(out)
}

fn hash_object(kind: u8, bytes: &[u8]) -> Result<Oid, ErrorCode> {
    let kind = match kind { 1 => "commit", 2 => "tree", 3 => "blob", _ => return Err(ErrorCode::UnsupportedFile) };
    let header = format!("{kind} {}\0", bytes.len());
    let mut whole = Vec::new();
    whole.try_reserve_exact(header.len() + bytes.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
    whole.extend_from_slice(header.as_bytes());
    whole.extend_from_slice(bytes);
    super::git_snapshot::sha1(&whole)
}

fn parse_hex_oid(value: &str) -> Result<Oid, ErrorCode> {
    if !super::git_snapshot::hex40(value) { return Err(ErrorCode::UnsupportedFile); }
    let mut result = [0u8; 20];
    for (i, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(pair).map_err(|_| ErrorCode::UnsupportedFile)?;
        result[i] = u8::from_str_radix(text, 16).map_err(|_| ErrorCode::UnsupportedFile)?;
    }
    Ok(result)
}

fn loose_name(name: &str) -> Result<Option<Oid>, ErrorCode> {
    let Some(tail) = name.strip_prefix(".git/objects/") else { return Ok(None) };
    let Some((first, second)) = tail.split_once('/') else { return Ok(None) };
    if first == "pack" || first == "info" { return Ok(None); }
    if first.len() != 2 || second.len() != 38 { return Err(ErrorCode::UnsupportedFile); }
    Ok(Some(parse_hex_oid(&format!("{first}{second}"))?))
}

fn decode_loose(input: &[u8]) -> Result<GitObject, ErrorCode> {
    let (raw, used) = inflate(input)?;
    if used != input.len() { return Err(ErrorCode::UnsupportedFile); }
    let nul = raw.iter().position(|byte| *byte == 0).ok_or(ErrorCode::UnsupportedFile)?;
    let header = std::str::from_utf8(&raw[..nul]).map_err(|_| ErrorCode::UnsupportedFile)?;
    let (kind, size) = header.split_once(' ').ok_or(ErrorCode::UnsupportedFile)?;
    let kind = match kind { "commit" => 1, "tree" => 2, "blob" => 3, _ => return Err(ErrorCode::UnsupportedFile) };
    let size = size.parse::<usize>().map_err(|_| ErrorCode::UnsupportedFile)?;
    if raw.len() - nul - 1 != size { return Err(ErrorCode::UnsupportedFile); }
    Ok(GitObject { kind, bytes: raw[nul + 1..].to_vec() })
}

fn inflate(input: &[u8]) -> Result<(Vec<u8>, usize), ErrorCode> {
    use flate2::{Decompress, FlushDecompress, Status};
    let mut inflater = Decompress::new(true);
    let mut output = Vec::new();
    loop {
        let mut chunk = [0u8; 8192];
        let before_in = inflater.total_in();
        let before_out = inflater.total_out();
        let status = inflater.decompress(&input[before_in as usize..], &mut chunk, FlushDecompress::None)
            .map_err(|_| ErrorCode::UnsupportedFile)?;
        let written = (inflater.total_out() - before_out) as usize;
        if output.len().checked_add(written).is_none_or(|len| len > MAX_MESSAGE_BYTES) {
            return Err(ErrorCode::ResourceExhausted);
        }
        output.extend_from_slice(&chunk[..written]);
        if status == Status::StreamEnd { return Ok((output, inflater.total_in() as usize)); }
        if inflater.total_in() == before_in && inflater.total_out() == before_out {
            return Err(ErrorCode::UnsupportedFile);
        }
    }
}

fn parse_index(bytes: &[u8]) -> Result<BTreeMap<String, (u32, Oid)>, ErrorCode> {
    let normalized = super::git_snapshot::sanitize_index(bytes)?;
    let bytes = normalized.as_slice();
    let mut result = BTreeMap::new();
    let mut pos = 12usize;
    let end = bytes.len() - 20;
    let count = u32::from_be_bytes(bytes[8..12].try_into().unwrap()) as usize;
    for _ in 0..count {
        let mode = u32::from_be_bytes(bytes[pos + 24..pos + 28].try_into().unwrap());
        let oid: Oid = bytes[pos + 40..pos + 60].try_into().unwrap();
        let nul = bytes[pos + 62..end].iter().position(|byte| *byte == 0).ok_or(ErrorCode::UnsupportedFile)?;
        let name = std::str::from_utf8(&bytes[pos + 62..pos + 62 + nul]).map_err(|_| ErrorCode::UnsupportedFile)?;
        if result.insert(name.to_owned(), (mode, oid)).is_some() { return Err(ErrorCode::UnsupportedFile); }
        pos += (62 + nul + 1 + 7) & !7;
    }
    Ok(result)
}

fn head_tree(files: &BTreeMap<String, Vec<u8>>, objects: &HashMap<Oid, GitObject>)
    -> Result<BTreeMap<String, (u32, Oid)>, ErrorCode> {
    let head = files.get(".git/HEAD").ok_or(ErrorCode::UnsupportedFile)?;
    super::git_snapshot::validate_ref(".git/HEAD", head)?;
    let text = std::str::from_utf8(head).map_err(|_| ErrorCode::UnsupportedFile)?.trim_end_matches(['\r', '\n']);
    let oid = if let Some(reference) = text.strip_prefix("ref: ") {
        let name = format!(".git/{reference}");
        if let Some(bytes) = files.get(&name) {
            parse_hex_oid(std::str::from_utf8(bytes).map_err(|_| ErrorCode::UnsupportedFile)?.trim())?
        } else {
            let mut found = None;
            if let Some(packed) = files.get(".git/packed-refs") {
                for line in std::str::from_utf8(packed).map_err(|_| ErrorCode::UnsupportedFile)?.lines() {
                    if let Some((hash, candidate)) = line.split_once(' ') {
                        if candidate == reference { found = Some(parse_hex_oid(hash)?); }
                    }
                }
            }
            let Some(oid) = found else { return Ok(BTreeMap::new()) };
            oid
        }
    } else { parse_hex_oid(text)? };
    let commit = objects.get(&oid).filter(|value| value.kind == 1).ok_or(ErrorCode::UnsupportedFile)?;
    let first = commit.bytes.split(|byte| *byte == b'\n').next().ok_or(ErrorCode::UnsupportedFile)?;
    let tree = first.strip_prefix(b"tree ").ok_or(ErrorCode::UnsupportedFile)?;
    let tree = parse_hex_oid(std::str::from_utf8(tree).map_err(|_| ErrorCode::UnsupportedFile)?)?;
    let mut paths = BTreeMap::new();
    visit_tree(tree, "", objects, &mut paths, 0)?;
    Ok(paths)
}

fn visit_tree(
    oid: Oid, prefix: &str, objects: &HashMap<Oid, GitObject>,
    paths: &mut BTreeMap<String, (u32, Oid)>, depth: usize,
) -> Result<(), ErrorCode> {
    if depth > 64 { return Err(ErrorCode::UnsupportedFile); }
    let tree = objects.get(&oid).filter(|value| value.kind == 2).ok_or(ErrorCode::UnsupportedFile)?;
    let mut pos = 0;
    while pos < tree.bytes.len() {
        let space = tree.bytes[pos..].iter().position(|byte| *byte == b' ').ok_or(ErrorCode::UnsupportedFile)? + pos;
        let nul = tree.bytes[space + 1..].iter().position(|byte| *byte == 0).ok_or(ErrorCode::UnsupportedFile)? + space + 1;
        let mode = std::str::from_utf8(&tree.bytes[pos..space]).map_err(|_| ErrorCode::UnsupportedFile)?;
        let name = std::str::from_utf8(&tree.bytes[space + 1..nul]).map_err(|_| ErrorCode::UnsupportedFile)?;
        let end = nul.checked_add(21).filter(|end| *end <= tree.bytes.len()).ok_or(ErrorCode::UnsupportedFile)?;
        let child: Oid = tree.bytes[nul + 1..end].try_into().unwrap();
        let path = if prefix.is_empty() { name.to_owned() } else { format!("{prefix}/{name}") };
        RelativePath::new(path.clone()).map_err(|_| ErrorCode::UnsupportedFile)?;
        match mode {
            "40000" => visit_tree(child, &path, objects, paths, depth + 1)?,
            "100644" | "100755" => {
                let mode = if mode == "100644" { 0o100644 } else { 0o100755 };
                if paths.insert(path, (mode, child)).is_some() { return Err(ErrorCode::UnsupportedFile); }
            }
            _ => return Err(ErrorCode::UnsupportedFile),
        }
        pos = end;
    }
    Ok(())
}

#[derive(Clone, Copy)]
enum PackBase { None, Offset(usize), Oid(Oid) }

struct PackEntry {
    offset: usize,
    crc: u32,
    kind: u8,
    base: PackBase,
    data: Vec<u8>,
    resolved: Option<(Oid, GitObject)>,
}

fn decode_packs(files: &BTreeMap<String, Vec<u8>>, objects: &mut HashMap<Oid, GitObject>) -> Result<(), ErrorCode> {
    let prefix = ".git/objects/pack/pack-";
    let mut pairs = BTreeMap::<String, (Option<&[u8]>, Option<&[u8]>)>::new();
    for (name, bytes) in files {
        let Some(tail) = name.strip_prefix(prefix) else { continue };
        let Some((stem, extension)) = tail.rsplit_once('.') else { return Err(ErrorCode::UnsupportedFile) };
        if !super::git_snapshot::hex40(stem) { return Err(ErrorCode::UnsupportedFile); }
        let pair = pairs.entry(stem.to_owned()).or_default();
        match extension {
            "pack" if pair.0.is_none() => pair.0 = Some(bytes),
            "idx" if pair.1.is_none() => pair.1 = Some(bytes),
            _ => return Err(ErrorCode::UnsupportedFile),
        }
    }
    for (_, (pack, index)) in pairs {
        parse_pack(pack.ok_or(ErrorCode::UnsupportedFile)?, index.ok_or(ErrorCode::UnsupportedFile)?, objects)?;
    }
    Ok(())
}

fn be32(input: &[u8], offset: usize) -> Result<u32, ErrorCode> {
    Ok(u32::from_be_bytes(input.get(offset..offset + 4).ok_or(ErrorCode::UnsupportedFile)?
        .try_into().unwrap()))
}

fn parse_pack(pack: &[u8], index: &[u8], objects: &mut HashMap<Oid, GitObject>) -> Result<(), ErrorCode> {
    if pack.len() < 32 || &pack[..4] != b"PACK" { return Err(ErrorCode::UnsupportedFile); }
    if !matches!(be32(pack, 4)?, 2 | 3) { return Err(ErrorCode::UnsupportedFile); }
    let count = be32(pack, 8)? as usize;
    if count > MAX_MESSAGE_BYTES / 20 { return Err(ErrorCode::ResourceExhausted); }
    let end = pack.len() - 20;
    if super::git_snapshot::sha1(&pack[..end])? != pack[end..] {
        return Err(ErrorCode::UnsupportedFile);
    }
    let mut entries = Vec::new();
    entries.try_reserve_exact(count).map_err(|_| ErrorCode::ResourceExhausted)?;
    let mut pos = 12usize;
    for _ in 0..count {
        if pos >= end { return Err(ErrorCode::UnsupportedFile); }
        let offset = pos;
        let first = pack[pos];
        pos += 1;
        let kind = (first >> 4) & 7;
        if !matches!(kind, 1 | 2 | 3 | 6 | 7) { return Err(ErrorCode::UnsupportedFile); }
        let mut size = (first & 0x0f) as usize;
        let mut shift = 4usize;
        let mut byte = first;
        while byte & 0x80 != 0 {
            byte = *pack.get(pos).ok_or(ErrorCode::UnsupportedFile)?;
            pos += 1;
            size |= ((byte & 0x7f) as usize).checked_shl(shift as u32).ok_or(ErrorCode::UnsupportedFile)?;
            shift += 7;
            if shift > 32 { return Err(ErrorCode::ResourceExhausted); }
        }
        if size > MAX_MESSAGE_BYTES { return Err(ErrorCode::ResourceExhausted); }
        let base = match kind {
            6 => {
                let mut byte = *pack.get(pos).ok_or(ErrorCode::UnsupportedFile)?;
                pos += 1;
                let mut backward = (byte & 0x7f) as usize;
                while byte & 0x80 != 0 {
                    byte = *pack.get(pos).ok_or(ErrorCode::UnsupportedFile)?;
                    pos += 1;
                    backward = backward.checked_add(1).and_then(|value| value.checked_mul(128))
                        .and_then(|value| value.checked_add((byte & 0x7f) as usize))
                        .ok_or(ErrorCode::UnsupportedFile)?;
                }
                PackBase::Offset(offset.checked_sub(backward).ok_or(ErrorCode::UnsupportedFile)?)
            }
            7 => {
                let base: Oid = pack.get(pos..pos + 20).ok_or(ErrorCode::UnsupportedFile)?
                    .try_into().unwrap();
                pos += 20;
                PackBase::Oid(base)
            }
            _ => PackBase::None,
        };
        let (data, consumed) = inflate(&pack[pos..end])?;
        if data.len() != size { return Err(ErrorCode::UnsupportedFile); }
        pos = pos.checked_add(consumed).filter(|value| *value <= end)
            .ok_or(ErrorCode::UnsupportedFile)?;
        let crc = crc32fast::hash(&pack[offset..pos]);
        entries.push(PackEntry { offset, crc, kind, base, data, resolved: None });
    }
    if pos != end { return Err(ErrorCode::UnsupportedFile); }
    let by_offset: HashMap<usize, usize> = entries.iter().enumerate().map(|(i, entry)| (entry.offset, i)).collect();
    if by_offset.len() != entries.len() { return Err(ErrorCode::UnsupportedFile); }
    let mut decoded = objects.values().try_fold(0usize, |sum, object| sum.checked_add(object.bytes.len()))
        .filter(|sum| *sum <= MAX_MESSAGE_BYTES).ok_or(ErrorCode::ResourceExhausted)?;
    for _ in 0..entries.len() {
        let mut progress = false;
        for i in 0..entries.len() {
            if entries[i].resolved.is_some() { continue; }
            let base = match entries[i].base {
                PackBase::None => None,
                PackBase::Offset(offset) => {
                    let index = *by_offset.get(&offset).ok_or(ErrorCode::UnsupportedFile)?;
                    entries[index].resolved.as_ref().map(|(_, object)| object.clone())
                }
                PackBase::Oid(oid) => objects.get(&oid).cloned(),
            };
            let object = match entries[i].base {
                PackBase::None => GitObject { kind: entries[i].kind, bytes: entries[i].data.clone() },
                _ => {
                    let Some(base) = base else { continue };
                    GitObject { kind: base.kind, bytes: apply_delta(&base.bytes, &entries[i].data)? }
                }
            };
            let oid = hash_object(object.kind, &object.bytes)?;
            if let Some(existing) = objects.get(&oid) {
                if existing.kind != object.kind || existing.bytes != object.bytes {
                    return Err(ErrorCode::UnsupportedFile);
                }
            } else {
                decoded = decoded.checked_add(object.bytes.len())
                    .filter(|sum| *sum <= MAX_MESSAGE_BYTES).ok_or(ErrorCode::ResourceExhausted)?;
                objects.insert(oid, object.clone());
            }
            entries[i].resolved = Some((oid, object));
            progress = true;
        }
        if entries.iter().all(|entry| entry.resolved.is_some()) { break; }
        if !progress { return Err(ErrorCode::UnsupportedFile); }
    }
    if entries.iter().any(|entry| entry.resolved.is_none()) { return Err(ErrorCode::UnsupportedFile); }
    verify_index(index, &pack[end..], &entries)?;
    Ok(())
}

fn delta_varint(bytes: &[u8], pos: &mut usize) -> Result<usize, ErrorCode> {
    let mut value = 0usize;
    let mut shift = 0usize;
    loop {
        let byte = *bytes.get(*pos).ok_or(ErrorCode::UnsupportedFile)?;
        *pos += 1;
        value |= ((byte & 0x7f) as usize).checked_shl(shift as u32).ok_or(ErrorCode::UnsupportedFile)?;
        if byte & 0x80 == 0 { return Ok(value); }
        shift += 7;
        if shift > 28 { return Err(ErrorCode::ResourceExhausted); }
    }
}

fn apply_delta(base: &[u8], delta: &[u8]) -> Result<Vec<u8>, ErrorCode> {
    let mut pos = 0;
    let source_size = delta_varint(delta, &mut pos)?;
    let target_size = delta_varint(delta, &mut pos)?;
    if source_size != base.len() || target_size > MAX_MESSAGE_BYTES {
        return Err(ErrorCode::UnsupportedFile);
    }
    let mut output = Vec::new();
    output.try_reserve_exact(target_size).map_err(|_| ErrorCode::ResourceExhausted)?;
    while pos < delta.len() {
        let instruction = delta[pos];
        pos += 1;
        if instruction & 0x80 != 0 {
            let mut offset = 0usize;
            let mut size = 0usize;
            for bit in 0..4 {
                if instruction & (1 << bit) != 0 {
                    offset |= (*delta.get(pos).ok_or(ErrorCode::UnsupportedFile)? as usize) << (bit * 8);
                    pos += 1;
                }
            }
            for bit in 0..3 {
                if instruction & (1 << (bit + 4)) != 0 {
                    size |= (*delta.get(pos).ok_or(ErrorCode::UnsupportedFile)? as usize) << (bit * 8);
                    pos += 1;
                }
            }
            if size == 0 { size = 0x10000; }
            let end = offset.checked_add(size).filter(|end| *end <= base.len())
                .ok_or(ErrorCode::UnsupportedFile)?;
            output.extend_from_slice(&base[offset..end]);
        } else if instruction != 0 {
            let end = pos.checked_add(instruction as usize).filter(|end| *end <= delta.len())
                .ok_or(ErrorCode::UnsupportedFile)?;
            output.extend_from_slice(&delta[pos..end]);
            pos = end;
        } else {
            return Err(ErrorCode::UnsupportedFile);
        }
        if output.len() > target_size { return Err(ErrorCode::UnsupportedFile); }
    }
    if output.len() != target_size { return Err(ErrorCode::UnsupportedFile); }
    Ok(output)
}

fn verify_index(index: &[u8], pack_digest: &[u8], entries: &[PackEntry]) -> Result<(), ErrorCode> {
    if index.len() < 8 + 256 * 4 + 40 || &index[..4] != b"\xfftOc" || be32(index, 4)? != 2 {
        return Err(ErrorCode::UnsupportedFile);
    }
    let end = index.len() - 40;
    if super::git_snapshot::sha1(&index[..index.len() - 20])? != index[index.len() - 20..] {
        return Err(ErrorCode::UnsupportedFile);
    }
    if &index[end..end + 20] != pack_digest { return Err(ErrorCode::UnsupportedFile); }
    let mut last = 0usize;
    let mut fanout = [0usize; 256];
    for (i, slot) in fanout.iter_mut().enumerate() {
        *slot = be32(index, 8 + i * 4)? as usize;
        if *slot < last || *slot > entries.len() { return Err(ErrorCode::UnsupportedFile); }
        last = *slot;
    }
    if last != entries.len() { return Err(ErrorCode::UnsupportedFile); }
    let table: usize = 8 + 256 * 4;
    let names_end = table.checked_add(entries.len() * 20).ok_or(ErrorCode::UnsupportedFile)?;
    let crc_end = names_end.checked_add(entries.len() * 4).ok_or(ErrorCode::UnsupportedFile)?;
    let offset_end = crc_end.checked_add(entries.len() * 4).ok_or(ErrorCode::UnsupportedFile)?;
    if offset_end != end { return Err(ErrorCode::UnsupportedFile); }
    let by_offset: HashMap<usize, &PackEntry> = entries.iter().map(|entry| (entry.offset, entry)).collect();
    let mut previous = None::<Oid>;
    let mut counted = [0usize; 256];
    for i in 0..entries.len() {
        let oid: Oid = index[table + i * 20..table + (i + 1) * 20].try_into().unwrap();
        if previous.is_some_and(|prior| prior >= oid) { return Err(ErrorCode::UnsupportedFile); }
        previous = Some(oid);
        counted[oid[0] as usize] += 1;
        let crc = be32(index, names_end + i * 4)?;
        let offset = be32(index, crc_end + i * 4)?;
        if offset & 0x8000_0000 != 0 { return Err(ErrorCode::UnsupportedFile); }
        let entry = by_offset.get(&(offset as usize)).ok_or(ErrorCode::UnsupportedFile)?;
        if entry.crc != crc || entry.resolved.as_ref().is_none_or(|(actual, _)| *actual != oid) {
            return Err(ErrorCode::UnsupportedFile);
        }
    }
    let mut running = 0usize;
    for (i, count) in counted.into_iter().enumerate() {
        running += count;
        if running != fanout[i] { return Err(ErrorCode::UnsupportedFile); }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::ZlibEncoder, Compression};

    fn hex(oid: &Oid) -> String { oid.iter().map(|byte| format!("{byte:02x}")).collect() }

    fn loose(kind: u8, bytes: &[u8]) -> (String, Vec<u8>, Oid) {
        let oid = hash_object(kind, bytes).unwrap();
        let name = hex(&oid);
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        let label = match kind { 1 => "commit", 2 => "tree", 3 => "blob", _ => unreachable!() };
        encoder.write_all(format!("{label} {}\0", bytes.len()).as_bytes()).unwrap();
        encoder.write_all(bytes).unwrap();
        (format!(".git/objects/{}/{}", &name[..2], &name[2..]), encoder.finish().unwrap(), oid)
    }

    fn index(entry: Option<(&str, Oid)>) -> Vec<u8> {
        let mut bytes = b"DIRC".to_vec();
        bytes.extend_from_slice(&2u32.to_be_bytes());
        bytes.extend_from_slice(&(entry.is_some() as u32).to_be_bytes());
        if let Some((name, oid)) = entry {
            let start = bytes.len();
            bytes.extend_from_slice(&[0u8; 62]);
            bytes[start + 24..start + 28].copy_from_slice(&0o100644u32.to_be_bytes());
            bytes[start + 40..start + 60].copy_from_slice(&oid);
            bytes[start + 60..start + 62].copy_from_slice(&(name.len() as u16).to_be_bytes());
            bytes.extend_from_slice(name.as_bytes());
            bytes.push(0);
            while (bytes.len() - start) % 8 != 0 { bytes.push(0); }
        }
        let checksum = super::super::git_snapshot::sha1(&bytes).unwrap();
        bytes.extend_from_slice(&checksum);
        bytes
    }

    fn fixture_named_with_head(path: &str, head_blob: &[u8], index_blob: Option<&[u8]>, work: Option<&[u8]>) -> Vec<(String, Vec<u8>)> {
        let (blob_name, blob, base_oid) = loose(3, head_blob);
        let mut tree = format!("100644 {path}\0").into_bytes();
        tree.extend_from_slice(&base_oid);
        let (tree_name, tree_bytes, tree_oid) = loose(2, &tree);
        let commit = format!("tree {}\nauthor a <a@b> 0 +0000\ncommitter a <a@b> 0 +0000\n\nbase\n", hex(&tree_oid));
        let (commit_name, commit_bytes, commit_oid) = loose(1, commit.as_bytes());
        let mut files = vec![
            (".git/HEAD".to_owned(), format!("{}\n", hex(&commit_oid)).into_bytes()),
            (blob_name, blob), (tree_name, tree_bytes), (commit_name, commit_bytes),
        ];
        if let Some(bytes) = index_blob {
            let (name, object, oid) = loose(3, bytes);
            if oid != base_oid { files.push((name, object)); }
            files.push((".git/index".to_owned(), index(Some((path, oid)))));
        } else {
            files.push((".git/index".to_owned(), index(None)));
        }
        if let Some(bytes) = work { files.push((path.to_owned(), bytes.to_vec())); }
        files
    }

    fn fixture_named(path: &str, index_blob: Option<&[u8]>, work: Option<&[u8]>) -> Vec<(String, Vec<u8>)> {
        fixture_named_with_head(path, b"base\n", index_blob, work)
    }

    fn fixture(index_blob: Option<&[u8]>, work: Option<&[u8]>) -> Vec<(String, Vec<u8>)> {
        fixture_named("tracked.txt", index_blob, work)
    }

    fn frame(operation: ReaderOperation<'_>, files: &[(String, Vec<u8>)]) -> Vec<u8> {
        frame_with_case(operation, false, files)
    }

    fn frame_with_case(operation: ReaderOperation<'_>, ignore_case: bool, files: &[(String, Vec<u8>)]) -> Vec<u8> {
        let borrowed = files.iter().map(|(name, bytes)| (name.as_str(), bytes.clone())).collect::<Vec<_>>();
        encode_input(operation, ignore_case, &borrowed).unwrap()
    }

    #[test]
    fn fixed_frame_rejects_mutation_duplicate_and_trailing_bytes() {
        let files = fixture(Some(b"base\n"), Some(b"base\n"));
        let valid = frame(ReaderOperation::List, &files);
        assert!(decode_input(&valid).is_ok());
        let mut changed = valid.clone();
        changed[15] ^= 1;
        assert!(decode_input(&changed).is_err());
        let mut extra = valid.clone();
        extra.push(0);
        assert!(decode_input(&extra).is_err());
        let mut duplicate = files;
        duplicate.push(("TRACKED.TXT".to_owned(), b"x".to_vec()));
        assert_eq!(encode_input(ReaderOperation::List, false,
            &duplicate.iter().map(|(name, bytes)| (name.as_str(), bytes.clone())).collect::<Vec<_>>()).err(),
            Some(ErrorCode::UnsupportedFile));
    }

    #[test]
    fn whole_capture_above_wire_limit_fails_without_truncation() {
        let head = b"ref: refs/heads/main\n".to_vec();
        let oversized = vec![b'x'; MAX_MESSAGE_BYTES];
        assert_eq!(encode_input(ReaderOperation::List, false,
            &[(".git/HEAD", head), ("large.txt", oversized)]).err(),
            Some(ErrorCode::ResourceExhausted));
    }

    #[test]
    fn optional_index_extension_is_normalized_before_parsing() {
        let mut files = fixture(Some(b"base\n"), Some(b"base\n"));
        let index = &mut files.iter_mut().find(|(name, _)| name == ".git/index").unwrap().1;
        index.truncate(index.len() - 20);
        index.extend_from_slice(b"TREE");
        index.extend_from_slice(&3u32.to_be_bytes());
        index.extend_from_slice(b"abc");
        index.extend_from_slice(&super::super::git_snapshot::sha1(index).unwrap());
        let result = read_repository(&frame(ReaderOperation::List, &files));
        assert!(matches!(result, Ok(ReaderResponse::List { .. })));
    }

    #[test]
    fn unmerged_index_stages_are_rejected_before_list_or_diff() {
        let oid = hash_object(3, b"base\n").unwrap();
        for stage in [1u16, 2, 3] {
            let mut single = index(Some(("tracked.txt", oid)));
            single[72..74].copy_from_slice(&((stage << 12) | 11).to_be_bytes());
            single.truncate(single.len() - 20);
            single.extend_from_slice(&super::super::git_snapshot::sha1(&single).unwrap());
            assert_eq!(super::super::git_snapshot::sanitize_index(&single).err(), Some(ErrorCode::UnsupportedFile));
            let mut files = fixture(Some(b"base\n"), Some(b"base\n"));
            files.iter_mut().find(|(name, _)| name == ".git/index").unwrap().1 = single;
            assert!(matches!(read_repository(&frame(ReaderOperation::List, &files)),
                Err(ErrorCode::UnsupportedFile)));
            let path = RelativePath::new("tracked.txt".to_owned()).unwrap();
            assert!(matches!(read_repository(&frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 }, &files)),
                Err(ErrorCode::UnsupportedFile)));
        }

        let left = index(Some(("a.txt", oid)));
        let right = index(Some(("b.txt", oid)));
        let mut multiple = left[..12].to_vec();
        multiple[8..12].copy_from_slice(&2u32.to_be_bytes());
        multiple.extend_from_slice(&left[12..left.len() - 20]);
        multiple.extend_from_slice(&right[12..right.len() - 20]);
        multiple[72..74].copy_from_slice(&(0x1000u16 | 5).to_be_bytes());
        let second = left.len() - 20;
        multiple[second + 60..second + 62].copy_from_slice(&(0x3000u16 | 5).to_be_bytes());
        multiple.extend_from_slice(&super::super::git_snapshot::sha1(&multiple).unwrap());
        assert_eq!(super::super::git_snapshot::sanitize_index(&multiple).err(), Some(ErrorCode::UnsupportedFile));
    }

    fn listed(frame: &[u8]) -> Vec<String> {
        let ReaderResponse::List { paths } = read_repository(frame).unwrap() else { panic!("list response") };
        paths
    }

    #[test]
    fn fixed_ignore_rules_match_case_nested_negation_and_tracked_files() {
        let mut files = vec![
            (".git/HEAD".to_owned(), b"ref: refs/heads/main\n".to_vec()),
            (".gitignore".to_owned(), b"*.log\n!keep.log\nblocked/\n".to_vec()),
            ("TRACE.LOG".to_owned(), b"visible when case-sensitive\n".to_vec()),
            ("drop.log".to_owned(), b"ignored\n".to_vec()),
            ("keep.log".to_owned(), b"negated\n".to_vec()),
            ("nested/.gitignore".to_owned(), b"!trace.log\n*.tmp\n".to_vec()),
            ("nested/trace.log".to_owned(), b"nested negation\n".to_vec()),
            ("nested/drop.tmp".to_owned(), b"nested ignore\n".to_vec()),
            ("blocked/.gitignore".to_owned(), b"!inside.txt\n".to_vec()),
            ("blocked/inside.txt".to_owned(), b"parent excluded\n".to_vec()),
            (".gitattributes".to_owned(), b"# harmless\n".to_vec()),
            (".gitmodules".to_owned(), b"; harmless\n".to_vec()),
        ];
        let sensitive = listed(&frame_with_case(ReaderOperation::List, false, &files));
        assert!(sensitive.contains(&"TRACE.LOG".to_owned()));
        assert!(sensitive.contains(&"keep.log".to_owned()));
        assert!(sensitive.contains(&"nested/trace.log".to_owned()));
        assert!(sensitive.contains(&".gitattributes".to_owned()));
        assert!(sensitive.contains(&".gitmodules".to_owned()));
        assert!(!sensitive.contains(&"drop.log".to_owned()));
        assert!(!sensitive.contains(&"nested/drop.tmp".to_owned()));
        assert!(!sensitive.contains(&"blocked/inside.txt".to_owned()));
        let insensitive = listed(&frame_with_case(ReaderOperation::List, true, &files));
        assert!(!insensitive.contains(&"TRACE.LOG".to_owned()));
        files.iter_mut().find(|(name, _)| name == ".gitattributes").unwrap().1 = b"*.txt filter=outside\n".to_vec();
        assert!(matches!(read_repository(&frame(ReaderOperation::List, &files)), Err(ErrorCode::UnsupportedFile)));
        files.iter_mut().find(|(name, _)| name == ".gitattributes").unwrap().1 = b"# harmless\n".to_vec();
        files.iter_mut().find(|(name, _)| name == ".gitignore").unwrap().1 = vec![0xff];
        assert!(matches!(read_repository(&frame(ReaderOperation::List, &files)), Err(ErrorCode::UnsupportedFile)));

        let mut tracked = fixture_named("TRACE.LOG", Some(b"base\n"), Some(b"modified\n"));
        tracked.push((".gitignore".to_owned(), b"*.log\n".to_vec()));
        for ignore_case in [false, true] {
            let paths = listed(&frame_with_case(ReaderOperation::List, ignore_case, &tracked));
            assert!(paths.contains(&"TRACE.LOG".to_owned()));
        }
    }

    #[test]
    fn indexed_metadata_cannot_supply_unseen_filter_or_submodule_rules() {
        for (path, bytes) in [
            (".gitattributes", b"*.txt filter=outside\n".as_slice()),
            (".gitmodules", b"[submodule \"outside\"]\npath = child\n".as_slice()),
        ] {
            let files = fixture_named(path, Some(bytes), None);
            assert!(matches!(read_repository(&frame(ReaderOperation::List, &files)),
                Err(ErrorCode::UnsupportedFile)), "indexed {path} must reject");
        }
        for path in [".gitattributes", ".gitmodules"] {
            let files = fixture_named_with_head(path, b"# comment only\n", Some(b"# comment only\n"), None);
            assert!(matches!(read_repository(&frame(ReaderOperation::List, &files)),
                Ok(ReaderResponse::List { .. })), "benign indexed {path} must work");
        }
    }

    #[test]
    fn unchanged_and_staged_cancellation_keep_absent_distinct_from_empty() {
        let path = RelativePath::new("tracked.txt".to_owned()).unwrap();
        let unchanged = frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 },
            &fixture(Some(b"base\n"), Some(b"base\n")));
        let ReaderResponse::Diff { kind, text, truncated } = read_repository(&unchanged).unwrap() else { panic!("diff") };
        assert_eq!(kind, FileKind::Text);
        assert_eq!(text.as_deref(), Some(""));
        assert!(!truncated);
        let staged = fixture(Some(b"staged\n"), Some(b"base\n"));
        let ReaderResponse::List { paths } = read_repository(&frame(ReaderOperation::List, &staged)).unwrap() else { panic!("list") };
        assert_eq!(paths, ["tracked.txt"]);
        let ReaderResponse::Diff { text, .. } = read_repository(&frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 }, &staged)).unwrap() else { panic!("diff") };
        assert_eq!(text.as_deref(), Some(""));
        let recreated = fixture(None, Some(b"recreated\n"));
        let ReaderResponse::Diff { text, .. } = read_repository(&frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 }, &recreated)).unwrap() else { panic!("diff") };
        assert!(text.unwrap().contains("deleted file mode"));
        let absent = fixture(None, None);
        assert_eq!(read_repository(&frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 }, &absent)).err(),
            Some(ErrorCode::TargetNotFound));
    }

    #[test]
    fn new_empty_file_is_added_with_header() {
        let mut files = fixture(Some(b"base\n"), Some(b"base\n"));
        files.push(("empty.txt".to_owned(), Vec::new()));
        let path = RelativePath::new("empty.txt".to_owned()).unwrap();
        let ReaderResponse::Diff { kind, text, .. } = read_repository(&frame(ReaderOperation::Diff { path: &path, max_bytes: 4096 }, &files)).unwrap() else { panic!("diff") };
        assert_eq!(kind, FileKind::Text);
        assert!(text.unwrap().contains("new file mode 100644"));
    }

    fn compressed(bytes: &[u8]) -> Vec<u8> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(bytes).unwrap();
        encoder.finish().unwrap()
    }

    fn packed_header(kind: u8, mut size: usize) -> Vec<u8> {
        let mut first = (kind << 4) | (size as u8 & 15);
        size >>= 4;
        if size != 0 { first |= 0x80; }
        let mut bytes = vec![first];
        while size != 0 {
            let mut byte = (size & 0x7f) as u8;
            size >>= 7;
            if size != 0 { byte |= 0x80; }
            bytes.push(byte);
        }
        bytes
    }

    fn pack_fixture(version: u32) -> (Vec<u8>, Vec<u8>, [Oid; 3]) {
        let base = b"base\n";
        let ofs_target = b"base plus\n";
        let ref_target = b"base ref\n";
        let oids = [hash_object(3, base).unwrap(), hash_object(3, ofs_target).unwrap(),
            hash_object(3, ref_target).unwrap()];
        let ofs_delta = [vec![5, 10, 0x90, 4, 6], b" plus\n".to_vec()].concat();
        let ref_delta = [vec![5, 9, 0x90, 4, 5], b" ref\n".to_vec()].concat();
        let mut pack = b"PACK".to_vec();
        pack.extend_from_slice(&version.to_be_bytes());
        pack.extend_from_slice(&3u32.to_be_bytes());
        let mut entries = Vec::new();
        let first = pack.len();
        pack.extend_from_slice(&packed_header(3, base.len()));
        pack.extend_from_slice(&compressed(base));
        entries.push((oids[0], first, crc32fast::hash(&pack[first..])));
        let second = pack.len();
        pack.extend_from_slice(&packed_header(6, ofs_delta.len()));
        pack.push((second - first) as u8);
        pack.extend_from_slice(&compressed(&ofs_delta));
        entries.push((oids[1], second, crc32fast::hash(&pack[second..])));
        let third = pack.len();
        pack.extend_from_slice(&packed_header(7, ref_delta.len()));
        pack.extend_from_slice(&oids[0]);
        pack.extend_from_slice(&compressed(&ref_delta));
        entries.push((oids[2], third, crc32fast::hash(&pack[third..])));
        let pack_digest = super::super::git_snapshot::sha1(&pack).unwrap();
        pack.extend_from_slice(&pack_digest);
        entries.sort_by_key(|entry| entry.0);
        let mut index = b"\xfftOc".to_vec();
        index.extend_from_slice(&2u32.to_be_bytes());
        for first in 0usize..256 {
            let count = entries.iter().filter(|entry| entry.0[0] as usize <= first).count() as u32;
            index.extend_from_slice(&count.to_be_bytes());
        }
        for (oid, _, _) in &entries { index.extend_from_slice(oid); }
        for (_, _, crc) in &entries { index.extend_from_slice(&crc.to_be_bytes()); }
        for (_, offset, _) in &entries { index.extend_from_slice(&(*offset as u32).to_be_bytes()); }
        index.extend_from_slice(&pack_digest);
        let index_digest = super::super::git_snapshot::sha1(&index).unwrap();
        index.extend_from_slice(&index_digest);
        (pack, index, oids)
    }

    #[test]
    fn pack_v2_v3_ofs_and_ref_delta_verify_ids_crc_and_trailers() {
        for version in [2, 3] {
            let (pack, index, oids) = pack_fixture(version);
            let mut objects = HashMap::new();
            parse_pack(&pack, &index, &mut objects).unwrap();
            assert_eq!(objects.get(&oids[0]).unwrap().bytes, b"base\n");
            assert_eq!(objects.get(&oids[1]).unwrap().bytes, b"base plus\n");
            assert_eq!(objects.get(&oids[2]).unwrap().bytes, b"base ref\n");
            let mut bad_crc = index.clone();
            let crc_start = 8 + 256 * 4 + 3 * 20;
            bad_crc[crc_start] ^= 1;
            let checksum = super::super::git_snapshot::sha1(&bad_crc[..bad_crc.len() - 20]).unwrap();
            let end = bad_crc.len();
            bad_crc[end - 20..].copy_from_slice(&checksum);
            assert_eq!(parse_pack(&pack, &bad_crc, &mut HashMap::new()).err(), Some(ErrorCode::UnsupportedFile));
            let mut bad_pack = pack.clone();
            bad_pack[16] ^= 1;
            assert_eq!(parse_pack(&bad_pack, &index, &mut HashMap::new()).err(), Some(ErrorCode::UnsupportedFile));
        }
    }
}
