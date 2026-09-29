//! A held identity for the exact executable that a provider probe and run use.
//! The handles exclude write/delete sharing until the suspended child is owned.

use crate::contract::{Provider, MAX_MESSAGE_BYTES};
use crate::runtime::spawn::{
    self, classify_readfile, job_active_processes, resume_once, PreparedChild, RawHandle, ReadClass,
};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::Read;
use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle as StdRawHandle};
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, WAIT_OBJECT_0};
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND};
use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileInformationByHandle, GetFinalPathNameByHandleW, ReadFile,
    BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
    FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ, OPEN_EXISTING,
};
use windows_sys::Win32::System::JobObjects::TerminateJobObject;
use windows_sys::Win32::System::Threading::{WaitForSingleObject, INFINITE};

const FILE_READ_ATTRIBUTES: u32 = 0x0080;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const SYNCHRONIZE: u32 = 0x00100000;
const FILE_READ_DATA: u32 = 0x0001;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PinError {
    NotFound,
    UnsafePath,
    Access,
    Changed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    volume: u32,
    index: u64,
}

pub(crate) struct ExecutablePin {
    alias_path: String,
    path: String,
    identities: Vec<FileIdentity>,
    digest: [u8; 32],
    // Root and each ancestor stay open. A rename or junction replacement must
    // fail while the provider process is created from this pathname.
    _directories: Vec<File>,
    _alias: File,
    _executable: File,
    #[cfg(debug_assertions)]
    revalidate_hook: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl ExecutablePin {
    pub(crate) fn discover(provider: Provider) -> Result<Self, PinError> {
        let name = match provider {
            Provider::Codex => "codex.exe",
            Provider::Claude => "claude.exe",
        };
        let path = std::env::var_os("PATH").ok_or(PinError::NotFound)?;
        for directory in std::env::split_paths(&path) {
            let candidate = directory.join(name);
            let Some(candidate) = candidate.to_str() else {
                continue;
            };
            if absolute_disk_components(candidate).is_err() {
                continue;
            }
            match Self::open(candidate, name) {
                Err(PinError::NotFound) => continue,
                result => return result,
            }
        }
        Err(PinError::NotFound)
    }

    pub(crate) fn path(&self) -> &str {
        &self.path
    }

    #[cfg(debug_assertions)]
    pub(crate) fn set_revalidate_hook(&self, hook: Arc<dyn Fn() + Send + Sync>) -> bool {
        let Ok(mut slot) = self.revalidate_hook.lock() else {
            return false;
        };
        *slot = Some(hook);
        true
    }

    pub(crate) fn revalidate(&self, provider: Provider) -> Result<(), PinError> {
        #[cfg(debug_assertions)]
        if let Some(hook) = self
            .revalidate_hook
            .lock()
            .ok()
            .and_then(|hook| hook.as_ref().cloned())
        {
            hook();
        }
        let current = Self::discover(provider)?;
        if self.alias_path.eq_ignore_ascii_case(&current.alias_path)
            && self.path.eq_ignore_ascii_case(&current.path)
            && self.identities == current.identities
            && self.digest == current.digest
        {
            Ok(())
        } else {
            Err(PinError::Changed)
        }
    }

    fn open(alias_path: &str, expected_name: &str) -> Result<Self, PinError> {
        let alias_components = absolute_disk_components(alias_path)?;
        if !alias_components
            .last()
            .is_some_and(|name| name.eq_ignore_ascii_case(expected_name))
        {
            return Err(PinError::UnsafePath);
        }
        let alias = open_alias(alias_path)?;
        let path = final_local_path(&alias)?;
        let components = absolute_disk_components(&path)?;
        if !components
            .last()
            .is_some_and(|name| name.eq_ignore_ascii_case(expected_name))
        {
            return Err(PinError::UnsafePath);
        }
        let drive = &path[..1];
        let mut current = format!("{drive}:\\");
        let mut directories = Vec::with_capacity(components.len());
        let mut identities = Vec::with_capacity(components.len() + 1);
        let root = open_file(&current, true)?;
        identities.push(file_identity(&root)?);
        directories.push(root);
        for component in &components[..components.len() - 1] {
            current.push_str(component);
            current.push('\\');
            let directory = open_file(&current, true)?;
            identities.push(file_identity(&directory)?);
            directories.push(directory);
        }
        current.push_str(components.last().expect("nonempty components"));
        let mut executable = open_file(&current, false)?;
        if file_identity(&alias)? != file_identity(&executable)? {
            return Err(PinError::Changed);
        }
        identities.push(file_identity(&executable)?);
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let read = executable.read(&mut buffer).map_err(|_| PinError::Access)?;
            if read == 0 {
                break;
            }
            hash.update(&buffer[..read]);
        }
        let digest: [u8; 32] = hash.finalize().into();
        Ok(Self {
            alias_path: alias_path.to_owned(),
            path: current,
            identities,
            digest,
            _directories: directories,
            _alias: alias,
            _executable: executable,
            #[cfg(debug_assertions)]
            revalidate_hook: Mutex::new(None),
        })
    }
}

fn open_alias(path: &str) -> Result<File, PinError> {
    let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ,
            null(),
            OPEN_EXISTING,
            0,
            null_mut(),
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return match unsafe { GetLastError() } {
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => Err(PinError::NotFound),
            _ => Err(PinError::Access),
        };
    }
    Ok(unsafe { File::from_raw_handle(handle as StdRawHandle) })
}

fn final_local_path(file: &File) -> Result<String, PinError> {
    let handle = file.as_raw_handle() as HANDLE;
    let mut units = vec![0u16; 1024];
    let needed =
        unsafe { GetFinalPathNameByHandleW(handle, units.as_mut_ptr(), units.len() as u32, 0) };
    if needed == 0 || needed > 32_767 {
        return Err(PinError::UnsafePath);
    }
    if needed as usize >= units.len() {
        units.resize(needed as usize + 1, 0);
        let written =
            unsafe { GetFinalPathNameByHandleW(handle, units.as_mut_ptr(), units.len() as u32, 0) };
        if written == 0 || written as usize >= units.len() {
            return Err(PinError::UnsafePath);
        }
        units.truncate(written as usize);
    } else {
        units.truncate(needed as usize);
    }
    let final_path = String::from_utf16(&units).map_err(|_| PinError::UnsafePath)?;
    let physical = final_path
        .strip_prefix(r"\\?\")
        .ok_or(PinError::UnsafePath)?;
    absolute_disk_components(physical)?;
    Ok(physical.to_owned())
}

fn absolute_disk_components(path: &str) -> Result<Vec<&str>, PinError> {
    let bytes = path.as_bytes();
    if bytes.len() < 4
        || !bytes[0].is_ascii_alphabetic()
        || bytes[1] != b':'
        || bytes[2] != b'\\'
        || path.contains('/')
        || path.contains('\0')
    {
        return Err(PinError::UnsafePath);
    }
    let components: Vec<&str> = path[3..].split('\\').collect();
    if components
        .iter()
        .any(|part| part.is_empty() || *part == "." || *part == ".." || part.contains(':'))
    {
        return Err(PinError::UnsafePath);
    }
    Ok(components)
}

fn open_file(path: &str, directory: bool) -> Result<File, PinError> {
    let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let access = if directory {
        FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE
    } else {
        FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE
    };
    let flags = if directory {
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT
    } else {
        FILE_FLAG_OPEN_REPARSE_POINT
    };
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            access,
            FILE_SHARE_READ,
            null(),
            OPEN_EXISTING,
            flags,
            null_mut(),
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(PinError::Access);
    }
    let file = unsafe { File::from_raw_handle(handle as StdRawHandle) };
    let mut information = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(file.as_raw_handle() as HANDLE, &mut information) } == 0
    {
        return Err(PinError::Access);
    }
    if information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(PinError::UnsafePath);
    }
    Ok(file)
}

fn file_identity(file: &File) -> Result<FileIdentity, PinError> {
    let mut information = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(file.as_raw_handle() as HANDLE, &mut information) } == 0
    {
        return Err(PinError::Access);
    }
    Ok(FileIdentity {
        volume: information.dwVolumeSerialNumber,
        index: (u64::from(information.nFileIndexHigh) << 32) | u64::from(information.nFileIndexLow),
    })
}

pub(crate) struct ReadyProvider {
    pub(crate) version: String,
    pub(crate) pin: Arc<ExecutablePin>,
}

struct ProbeSlot {
    state: Mutex<ProbeState>,
    #[cfg(test)]
    checkpoint: Mutex<Option<Arc<dyn Fn(ProbeCheckpoint) + Send + Sync>>>,
    #[cfg(test)]
    force_assign_failure: AtomicBool,
    #[cfg(test)]
    wait_failure_budget: AtomicUsize,
}

#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum ProbeCheckpoint {
    BeforeSpawn,
    AfterSpawn,
    AfterJob,
    AfterReader,
    UnassignedWaitFailed,
}

enum ProbeState {
    Probing {
        cancelled: bool,
        job: Option<RawHandle>,
    },
    Ready(ReadyProvider),
    Failed,
}

pub(crate) struct ProbeRegistry {
    codex: Arc<ProbeSlot>,
    claude: Arc<ProbeSlot>,
    codex_worker: Mutex<Option<thread::JoinHandle<()>>>,
    claude_worker: Mutex<Option<thread::JoinHandle<()>>>,
}

impl ProbeRegistry {
    pub(crate) fn start() -> Self {
        let codex = Arc::new(ProbeSlot::probing());
        let claude = Arc::new(ProbeSlot::probing());
        let codex_worker = spawn_probe(Arc::clone(&codex), Provider::Codex);
        let claude_worker = spawn_probe(Arc::clone(&claude), Provider::Claude);
        Self {
            codex,
            claude,
            codex_worker: Mutex::new(codex_worker),
            claude_worker: Mutex::new(claude_worker),
        }
    }

    pub(crate) fn ready(&self, provider: Provider) -> Option<ReadyProvider> {
        self.slot(provider).ready()
    }

    pub(crate) fn cancel_all(&self) -> bool {
        self.codex.cancel();
        self.claude.cancel();
        let codex = self.join_finished(&self.codex_worker, &self.codex);
        let claude = self.join_finished(&self.claude_worker, &self.claude);
        codex && claude
    }

    pub(crate) fn cancel_and_join(&self) -> bool {
        self.codex.cancel();
        self.claude.cancel();
        let codex = self.join_worker(&self.codex_worker, &self.codex);
        let claude = self.join_worker(&self.claude_worker, &self.claude);
        codex && claude
    }

    fn join_finished(
        &self,
        worker: &Mutex<Option<thread::JoinHandle<()>>>,
        slot: &ProbeSlot,
    ) -> bool {
        let Ok(mut guard) = worker.lock() else {
            return false;
        };
        if guard.as_ref().is_some_and(|handle| !handle.is_finished()) {
            return false;
        }
        let joined = guard.take().is_none_or(|handle| handle.join().is_ok());
        joined && slot.is_terminal()
    }

    fn join_worker(
        &self,
        worker: &Mutex<Option<thread::JoinHandle<()>>>,
        slot: &ProbeSlot,
    ) -> bool {
        let Ok(mut guard) = worker.lock() else {
            return false;
        };
        let joined = guard.take().is_none_or(|handle| handle.join().is_ok());
        joined && slot.is_terminal()
    }

    fn slot(&self, provider: Provider) -> &ProbeSlot {
        match provider {
            Provider::Codex => &self.codex,
            Provider::Claude => &self.claude,
        }
    }
}

impl Drop for ProbeRegistry {
    fn drop(&mut self) {
        let _ = self.cancel_and_join();
    }
}

impl Clone for ReadyProvider {
    fn clone(&self) -> Self {
        Self {
            version: self.version.clone(),
            pin: Arc::clone(&self.pin),
        }
    }
}

impl ProbeSlot {
    fn is_terminal(&self) -> bool {
        self.state.lock().ok().is_some_and(|state| {
            matches!(&*state, ProbeState::Ready(_) | ProbeState::Failed)
        })
    }
    fn probing() -> Self {
        Self {
            state: Mutex::new(ProbeState::Probing {
                cancelled: false,
                job: None,
            }),
            #[cfg(test)]
            checkpoint: Mutex::new(None),
            #[cfg(test)]
            force_assign_failure: AtomicBool::new(false),
            #[cfg(test)]
            wait_failure_budget: AtomicUsize::new(0),
        }
    }

    #[cfg(test)]
    fn checkpoint(&self, point: ProbeCheckpoint) {
        let callback = self
            .checkpoint
            .lock()
            .ok()
            .and_then(|hook| hook.as_ref().cloned());
        if let Some(callback) = callback {
            callback(point);
        }
    }

    fn ready(&self) -> Option<ReadyProvider> {
        let guard = self.state.lock().ok()?;
        match &*guard {
            ProbeState::Ready(ready) => Some(ready.clone()),
            _ => None,
        }
    }

    fn cancelled(&self) -> bool {
        let Ok(guard) = self.state.lock() else {
            return true;
        };
        !matches!(
            &*guard,
            ProbeState::Probing {
                cancelled: false,
                ..
            }
        )
    }

    fn install_job(&self, handle: HANDLE) -> bool {
        let Some(duplicated) = spawn::duplicate_handle(handle) else {
            return false;
        };
        let Ok(mut guard) = self.state.lock() else {
            unsafe { CloseHandle(duplicated) };
            return false;
        };
        match &mut *guard {
            ProbeState::Probing {
                cancelled: false,
                job,
            } => {
                *job = Some(RawHandle(duplicated));
                true
            }
            _ => {
                unsafe { CloseHandle(duplicated) };
                false
            }
        }
    }

    fn cancel(&self) -> bool {
        let Ok(mut guard) = self.state.lock() else {
            return false;
        };
        match &mut *guard {
            ProbeState::Probing { cancelled, job } => {
                *cancelled = true;
                if let Some(job) = job {
                    unsafe { TerminateJobObject(job.0, 1) };
                }
                false
            }
            ProbeState::Ready(_) | ProbeState::Failed => true,
        }
    }

    fn finish(&self, ready: Option<ReadyProvider>) {
        let Ok(mut guard) = self.state.lock() else {
            return;
        };
        if let ProbeState::Probing { cancelled, .. } = &*guard {
            if !*cancelled {
                if let Some(ready) = ready {
                    *guard = ProbeState::Ready(ready);
                    return;
                }
            }
        }
        *guard = ProbeState::Failed;
    }
}

fn spawn_probe(slot: Arc<ProbeSlot>, provider: Provider) -> Option<thread::JoinHandle<()>> {
    let worker = Arc::clone(&slot);
    match thread::Builder::new()
        .name(format!("winsmux-version-{}", provider.wire()))
        .spawn(move || {
            let result = std::panic::catch_unwind(|| probe_version(&worker, provider))
                .ok()
                .flatten();
            worker.finish(result);
        })
    {
        Ok(handle) => Some(handle),
        Err(_) => {
            slot.finish(None);
            None
        }
    }
}

struct ProbeLease<'a> {
    child: Option<PreparedChild>,
    reader: Option<thread::JoinHandle<Option<Vec<u8>>>>,
    assigned: bool,
    slot: &'a ProbeSlot,
}

fn cleanup_observation(root: u32, active: Option<u32>) -> (bool, bool) {
    let done = root == WAIT_OBJECT_0 && active == Some(0);
    let observation_failed =
        (root != WAIT_OBJECT_0 && root != windows_sys::Win32::Foundation::WAIT_TIMEOUT)
            || active.is_none();
    (done, observation_failed)
}

impl<'a> ProbeLease<'a> {
    fn new(child: PreparedChild, slot: &'a ProbeSlot) -> Self {
        Self {
            child: Some(child),
            reader: None,
            assigned: false,
            slot,
        }
    }

    fn assign_job(&mut self) -> bool {
        #[cfg(test)]
        if self.slot.force_assign_failure.load(Ordering::SeqCst) {
            return false;
        }
        let assigned = self.child().assign_to_job();
        self.assigned = assigned;
        assigned
    }

    fn child(&self) -> &PreparedChild {
        self.child.as_ref().expect("probe child owned until cleanup")
    }

    fn child_mut(&mut self) -> &mut PreparedChild {
        self.child.as_mut().expect("probe child owned until cleanup")
    }

    // This lease is the only recovery owner. An unobservable Job is never
    // converted to Failed/Ready or handed to the generic detached reaper.
    fn cleanup(&mut self) -> (bool, Option<Vec<u8>>) {
        let Some(child) = self.child.as_mut() else {
            return (false, None);
        };
        let mut observed_without_error = true;
        loop {
            #[cfg(test)]
            let forced_wait_failure = self
                .slot
                .wait_failure_budget
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| count.checked_sub(1))
                .is_ok();
            #[cfg(test)]
            let root = if forced_wait_failure {
                windows_sys::Win32::Foundation::WAIT_FAILED
            } else {
                unsafe { WaitForSingleObject(child.process.0, 0) }
            };
            #[cfg(not(test))]
            let root = unsafe { WaitForSingleObject(child.process.0, 0) };
            let active = if self.assigned {
                job_active_processes(child.job.0)
            } else {
                Some(0)
            };
            let (done, observation_failed) = cleanup_observation(root, active);
            #[cfg(test)]
            if forced_wait_failure && !self.assigned {
                self.slot.checkpoint(ProbeCheckpoint::UnassignedWaitFailed);
            }
            if done {
                break;
            }
            if observation_failed {
                observed_without_error = false;
            }
            if self.assigned {
                unsafe { TerminateJobObject(child.job.0, 1) };
            } else {
                unsafe { windows_sys::Win32::System::Threading::TerminateProcess(child.process.0, 1) };
            }
            thread::sleep(std::time::Duration::from_millis(10));
        }
        child.input.close();
        child.hpcon.close();
        let bytes = self.reader.take().and_then(|reader| reader.join().ok()).flatten();
        let mut child = self.child.take().expect("probe child owned until cleanup");
        child.disarm();
        drop(child);
        (observed_without_error, bytes)
    }
}

impl Drop for ProbeLease<'_> {
    fn drop(&mut self) {
        if self.child.is_some() {
            let _ = self.cleanup();
        }
    }
}

fn probe_version(slot: &ProbeSlot, provider: Provider) -> Option<ReadyProvider> {
    if slot.cancelled() {
        return None;
    }
    let pin = ExecutablePin::discover(provider).ok()?;
    if slot.cancelled() || pin.revalidate(provider).is_err() {
        return None;
    }
    probe_version_from_verified_pin(slot, provider, pin)
}

fn probe_version_from_verified_pin(
    slot: &ProbeSlot,
    provider: Provider,
    pin: ExecutablePin,
) -> Option<ReadyProvider> {
    #[cfg(test)]
    slot.checkpoint(ProbeCheckpoint::BeforeSpawn);
    if slot.cancelled() {
        return None;
    }
    let cwd = std::env::temp_dir();
    let cwd = cwd.to_str()?;
    let mut lease = ProbeLease::new(spawn::spawn_suspended_probe(cwd, pin.path(), &["--version"]).ok()?, slot);
    #[cfg(test)]
    slot.checkpoint(ProbeCheckpoint::AfterSpawn);
    if !lease.assign_job() {
        return None;
    }
    if !slot.install_job(lease.child().job.0) || slot.cancelled() {
        return None;
    }
    #[cfg(test)]
    slot.checkpoint(ProbeCheckpoint::AfterJob);
    if slot.cancelled() {
        return None;
    }
    if resume_once(lease.child().thread.0) != 1 {
        return None;
    }
    let output = RawHandle(lease.child_mut().output.take());
    lease.reader = thread::Builder::new()
        .name("winsmux-version-output".to_owned())
        .spawn(move || read_version_output(output))
        .ok();
    if lease.reader.is_none() {
        return None;
    }
    #[cfg(test)]
    slot.checkpoint(ProbeCheckpoint::AfterReader);
    let root_waited = unsafe { WaitForSingleObject(lease.child().process.0, INFINITE) } == WAIT_OBJECT_0;
    let exit_code = if root_waited {
        spawn::exit_code(lease.child().process.0)
    } else {
        None
    };
    let had_descendants = !matches!(job_active_processes(lease.child().job.0), Some(0));
    let was_cancelled = slot.cancelled();
    let (recovered, bytes) = lease.cleanup();
    let clean = root_waited
        && exit_code == Some(0)
        && !had_descendants
        && !was_cancelled
        && recovered;
    if !clean {
        return None;
    }
    let version = parse_version(provider, &bytes?)?;
    Some(ReadyProvider {
        version,
        pin: Arc::new(pin),
    })
}

fn read_version_output(output: RawHandle) -> Option<Vec<u8>> {
    let mut result = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut too_large = false;
    loop {
        let mut read = 0u32;
        let ok = unsafe {
            ReadFile(
                output.0,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut read,
                null_mut(),
            )
        };
        let error = if ok == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        match classify_readfile(ok, read, error) {
            ReadClass::Payload => {
                if result.len().saturating_add(read as usize) <= MAX_MESSAGE_BYTES {
                    result.extend_from_slice(&buffer[..read as usize]);
                } else {
                    too_large = true;
                }
            }
            ReadClass::TrueZero => thread::yield_now(),
            ReadClass::Drain => return (!too_large).then_some(result),
            ReadClass::ReadError => return None,
        }
    }
}

fn parse_version(provider: Provider, bytes: &[u8]) -> Option<String> {
    let text = strip_conpty_controls(bytes)?;
    let line = text.trim();
    if line.is_empty() || line.chars().any(|ch| matches!(ch, '\r' | '\n' | '\0')) {
        return None;
    }
    let version = match provider {
        Provider::Codex => line.strip_prefix("codex-cli ")?,
        Provider::Claude => line.strip_suffix(" (Claude Code)")?,
    };
    let mut components = version.split('.');
    for _ in 0..3 {
        let component = components.next()?;
        if component.is_empty() || !component.bytes().all(|digit| digit.is_ascii_digit()) {
            return None;
        }
    }
    if components.next().is_some() {
        return None;
    }
    Some(version.to_owned())
}

fn strip_conpty_controls(bytes: &[u8]) -> Option<String> {
    let mut plain = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != 0x1b {
            plain.push(bytes[index]);
            index += 1;
            continue;
        }
        index += 1;
        match bytes.get(index) {
            Some(b'[') => {
                index += 1;
                while bytes
                    .get(index)
                    .is_some_and(|byte| (0x20..=0x3f).contains(byte))
                {
                    index += 1;
                }
                if !bytes
                    .get(index)
                    .is_some_and(|byte| (0x40..=0x7e).contains(byte))
                {
                    return None;
                }
                index += 1;
            }
            Some(b']') => {
                index += 1;
                loop {
                    match bytes.get(index) {
                        Some(0x07) => {
                            index += 1;
                            break;
                        }
                        Some(0x1b) if bytes.get(index + 1) == Some(&b'\\') => {
                            index += 2;
                            break;
                        }
                        Some(byte) if (0x20..=0x7e).contains(byte) => index += 1,
                        _ => return None,
                    }
                }
            }
            _ => return None,
        }
    }
    String::from_utf8(plain).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::process::Command;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn failed_state_cannot_claim_probe_worker_was_joined() {
        let codex = Arc::new(ProbeSlot::probing());
        let claude = Arc::new(ProbeSlot::probing());
        claude.finish(None);
        let (release_tx, release_rx) = mpsc::channel();
        let worker_slot = Arc::clone(&codex);
        let worker = thread::spawn(move || {
            worker_slot.finish(None);
            release_rx.recv().expect("release worker");
        });
        let registry = ProbeRegistry {
            codex,
            claude,
            codex_worker: Mutex::new(Some(worker)),
            claude_worker: Mutex::new(None),
        };
        assert!(!registry.cancel_all(), "terminal state preceded worker join");
        release_tx.send(()).expect("release worker");
        assert!(registry.cancel_and_join(), "both workers must be joined");
    }

    #[test]
    fn failed_job_query_is_pending_and_never_a_cleanup_proof() {
        assert_eq!(cleanup_observation(WAIT_OBJECT_0, None), (false, true));
        assert_eq!(cleanup_observation(WAIT_OBJECT_0, Some(1)), (false, false));
        assert_eq!(cleanup_observation(WAIT_OBJECT_0, Some(0)), (true, false));
    }

    #[test]
    fn a_ready_sibling_never_substitutes_for_a_missing_provider() {
        let root = std::env::temp_dir().join(format!("winsmux-no-fallback-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("provider fixture directory");
        let system = std::env::var_os("SystemRoot").expect("Windows root");
        fs::copy(
            Path::new(&system).join("System32").join("cmd.exe"),
            root.join("claude.exe"),
        )
        .expect("fixture executable");
        let pin = ExecutablePin::open(root.join("claude.exe").to_str().unwrap(), "claude.exe")
            .expect("Claude pin");
        let codex = Arc::new(ProbeSlot::probing());
        codex.finish(None);
        let claude = Arc::new(ProbeSlot::probing());
        claude.finish(Some(ReadyProvider {
            version: "fixture".to_owned(),
            pin: Arc::new(pin),
        }));
        let registry = ProbeRegistry {
            codex,
            claude,
            codex_worker: Mutex::new(None),
            claude_worker: Mutex::new(None),
        };
        assert!(registry.ready(Provider::Codex).is_none());
        assert_eq!(registry.ready(Provider::Claude).unwrap().version, "fixture");
        drop(registry);
        fs::remove_dir_all(root).expect("remove provider fixture");
    }

    fn cancel_at_probe_checkpoint(point: ProbeCheckpoint) {
        let root = std::env::temp_dir().join(format!("winsmux-probe-lease-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("probe fixture directory");
        let system = std::env::var_os("SystemRoot").expect("Windows root");
        let source = Path::new(&system).join("System32").join("cmd.exe");
        let executable = root.join("codex.exe");
        fs::copy(source, &executable).expect("probe fixture executable");
        let pin = ExecutablePin::open(executable.to_str().unwrap(), "codex.exe")
            .expect("fixture pin");
        let slot = Arc::new(ProbeSlot::probing());
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *slot.checkpoint.lock().expect("checkpoint lock") = Some(Arc::new(move |seen| {
            if seen == point {
                entered_tx.send(()).expect("checkpoint entered");
                release_rx.lock().expect("checkpoint receiver").recv().expect("release checkpoint");
            }
        }));
        let worker_slot = Arc::clone(&slot);
        let worker = thread::spawn(move || {
            let result = probe_version_from_verified_pin(&worker_slot, Provider::Codex, pin);
            worker_slot.finish(result);
        });
        entered_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("probe reached checkpoint");
        assert!(!slot.cancel(), "cancel before cleanup must remain pending");
        assert!(!worker.is_finished(), "held worker must retain its lease");
        release_tx.send(()).expect("release checkpoint");
        worker.join().expect("probe worker joined");
        assert!(slot.is_terminal(), "cleanup must precede terminal state");
        assert!(slot.ready().is_none(), "cancelled probe must not advertise Ready");
        drop(slot);
        fs::remove_dir_all(root).expect("remove probe fixture");
    }

    #[test]
    fn cancellation_owns_child_before_and_after_job_registration_and_reader_start() {
        for point in [
            ProbeCheckpoint::BeforeSpawn,
            ProbeCheckpoint::AfterSpawn,
            ProbeCheckpoint::AfterJob,
            ProbeCheckpoint::AfterReader,
        ] {
            cancel_at_probe_checkpoint(point);
        }
    }

    #[test]
    fn failed_job_assignment_and_failed_root_wait_keep_probe_nonterminal() {
        let root = std::env::temp_dir().join(format!(
            "winsmux-probe-assign-failure-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).expect("probe fixture directory");
        let system = std::env::var_os("SystemRoot").expect("Windows root");
        let executable = root.join("codex.exe");
        fs::copy(Path::new(&system).join("System32").join("cmd.exe"), &executable)
            .expect("fixture executable");
        let pin = ExecutablePin::open(executable.to_str().unwrap(), "codex.exe")
            .expect("fixture pin");
        let codex = Arc::new(ProbeSlot::probing());
        codex.force_assign_failure.store(true, Ordering::SeqCst);
        codex.wait_failure_budget.store(1, Ordering::SeqCst);
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *codex.checkpoint.lock().expect("checkpoint lock") = Some(Arc::new(move |seen| {
            if seen == ProbeCheckpoint::UnassignedWaitFailed {
                entered_tx.send(()).expect("failed wait observed");
                release_rx
                    .lock()
                    .expect("release receiver")
                    .recv()
                    .expect("release failed wait");
            }
        }));
        let worker_slot = Arc::clone(&codex);
        let worker = thread::spawn(move || {
            let result = probe_version_from_verified_pin(&worker_slot, Provider::Codex, pin);
            worker_slot.finish(result);
        });
        let claude = Arc::new(ProbeSlot::probing());
        claude.finish(None);
        let registry = ProbeRegistry {
            codex: Arc::clone(&codex),
            claude,
            codex_worker: Mutex::new(Some(worker)),
            claude_worker: Mutex::new(None),
        };
        entered_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("unassigned root reached failed wait");
        assert!(!codex.is_terminal(), "WAIT_FAILED cannot publish Failed");
        assert!(!registry.cancel_all(), "host stop must wait for root cleanup and worker join");
        release_tx.send(()).expect("release failed wait");
        assert!(registry.cancel_and_join(), "observed cleanup must join worker");
        assert!(codex.is_terminal());
        assert!(codex.ready().is_none());
        drop(registry);
        drop(codex);
        fs::remove_dir_all(root).expect("probe fixture cleanup");
    }

    #[test]
    fn version_parser_rejects_wrong_provider_and_partial_output() {
        assert_eq!(
            parse_version(Provider::Codex, b"codex-cli 0.156.1\r\n"),
            Some("0.156.1".into())
        );
        assert_eq!(
            parse_version(Provider::Claude, b"2.1.282 (Claude Code)\r\n"),
            Some("2.1.282".into())
        );
        assert!(parse_version(Provider::Codex, b"2.1.282 (Claude Code)").is_none());
        assert!(parse_version(Provider::Claude, b"codex-cli 0.156.1").is_none());
        assert!(parse_version(Provider::Codex, b"codex-cli 0.156").is_none());
        assert!(parse_version(Provider::Codex, b"codex-cli 0.156.1\nsecret").is_none());
        assert_eq!(
            parse_version(
                Provider::Codex,
                b"\x1b[?25l\x1b[Hcodex-cli 0.156.1\r\n\x1b[?25h"
            ),
            Some("0.156.1".into())
        );
        assert_eq!(
            parse_version(Provider::Codex, b"\x1b]0;title\x07codex-cli 0.156.1"),
            Some("0.156.1".into())
        );
        assert!(parse_version(Provider::Codex, b"\x1b]titlecodex-cli 0.156.1").is_none());
    }

    #[test]
    fn junction_alias_resolves_to_held_local_executable() {
        let root =
            std::env::temp_dir().join(format!("winsmux-provider-pin-{}", uuid::Uuid::new_v4()));
        let first = root.join("release-one");
        let second = root.join("release-two");
        fs::create_dir_all(&first).expect("first release");
        fs::create_dir_all(&second).expect("second release");
        let system = std::env::var_os("SystemRoot").expect("Windows root");
        let source = Path::new(&system).join("System32").join("cmd.exe");
        fs::copy(&source, first.join("codex.exe")).expect("first executable");
        fs::copy(&source, second.join("codex.exe")).expect("second executable");
        let alias = root.join("current");
        let junction = Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(&alias)
            .arg(&first)
            .output()
            .expect("mklink command");
        assert!(junction.status.success(), "junction creation failed");
        let alias_exe = alias.join("codex.exe");
        let alias_text = alias_exe.to_str().expect("Unicode path");
        let pin = ExecutablePin::open(alias_text, "codex.exe").expect("junction pin");
        assert!(pin
            .path()
            .eq_ignore_ascii_case(first.join("codex.exe").to_str().unwrap()));
        assert!(fs::write(first.join("codex.exe"), b"replacement").is_err());
        assert!(fs::rename(&first, root.join("renamed-release")).is_err());
        if fs::rename(&alias, root.join("old-current")).is_ok() {
            let second_junction = Command::new("cmd")
                .args(["/C", "mklink", "/J"])
                .arg(&alias)
                .arg(&second)
                .output()
                .expect("second mklink command");
            assert!(second_junction.status.success(), "alias retarget failed");
            let replacement = ExecutablePin::open(alias_text, "codex.exe").expect("retargeted pin");
            assert_ne!(pin.identities, replacement.identities);
            assert!(pin
                .path()
                .eq_ignore_ascii_case(first.join("codex.exe").to_str().unwrap()));
            drop(replacement);
            fs::remove_dir(&alias).expect("remove second junction");
            fs::rename(root.join("old-current"), &alias).expect("restore first junction");
        }
        drop(pin);
        fs::remove_dir(&alias).expect("remove first junction");
        fs::remove_dir_all(&root).expect("remove isolated fixture");
    }

    #[test]
    #[ignore = "requires an installed official Codex CLI"]
    fn real_codex_version_probe_is_owned_and_drained() {
        let pin = ExecutablePin::discover(Provider::Codex)
            .unwrap_or_else(|error| panic!("executable discovery failed: {error:?}"));
        pin.revalidate(Provider::Codex)
            .unwrap_or_else(|error| panic!("executable revalidation failed: {error:?}"));
        let slot = ProbeSlot::probing();
        let ready = probe_version(&slot, Provider::Codex);
        slot.finish(ready);
        assert!(slot.ready().is_some());
    }
}
