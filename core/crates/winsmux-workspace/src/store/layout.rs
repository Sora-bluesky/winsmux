//! User-unit layout snapshot store: private v1 ACL, held local-fixed identity,
//! share-mode-0 lease, and the C/B preflight plus staged replace family.

use crate::contract::{
    parse_snapshot, serialize_snapshot, ErrorCode, Snapshot, MAX_MESSAGE_BYTES,
};
use crate::host::admission::{AllocationAuthority, AllocationError, AllocationPool, ChargedVec};
use crate::host::io::OwnedHandle;
use crate::host::security::{Identity, Sid};
use crate::store::root_identity::{classify_path_syntax, observe_root, ObserveError, ObservedRoot};
use std::ffi::c_void;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND,
    GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
    SetSecurityInfo, SDDL_REVISION_1, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    CreateWellKnownSid, EqualSid, GetAce, GetAclInformation, GetSecurityDescriptorControl,
    IsValidSid, ACCESS_ALLOWED_ACE, ACE_HEADER, ACL_SIZE_INFORMATION, AclSizeInformation,
    DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    SECURITY_ATTRIBUTES, SE_DACL_PROTECTED,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, FlushFileBuffers, GetDriveTypeW, GetFileInformationByHandle,
    GetFileSizeEx, QueryDosDeviceW, ReadFile, SetEndOfFile,
    SetFilePointerEx, WriteFile, BY_HANDLE_FILE_INFORMATION, CREATE_NEW, DELETE,
    FILE_ALL_ACCESS, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_REPARSE_POINT,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
    OPEN_EXISTING, READ_CONTROL, WRITE_OWNER,
};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::UI::Shell::{FOLDERID_LocalAppData, SHGetKnownFolderPath};


// Private CI observation only. Every release expansion remains the original expression/body.
macro_rules! observe_store_scope {
    ($phase:literal, $target:expr, $body:block) => {{
        #[cfg(debug_assertions)] { stop_observation::scope($phase, $target, || $body) }
        #[cfg(not(debug_assertions))] $body
    }};
}
macro_rules! observe_store_bool {
    ($api:literal, $value:expr) => {{
        #[cfg(debug_assertions)] { let value = $value; if value == 0 { stop_observation::native($api, unsafe { GetLastError() }); } value }
        #[cfg(not(debug_assertions))] { $value }
    }};
}
macro_rules! observe_store_status {
    ($api:literal, $value:expr) => {{
        #[cfg(debug_assertions)] { let value = $value; if value != 0 { stop_observation::native($api, value); } value }
        #[cfg(not(debug_assertions))] { $value }
    }};
}
#[cfg(debug_assertions)]
pub(crate) mod stop_observation {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{FILE_SHARE_WRITE, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT};
    const ROOT_ENV: &str = "WINSMUX_TASK876_STOP_OBSERVATION";
    const NONCE_ENV: &str = "WINSMUX_TASK876_STOP_NONCE";
    const TEST: &str = "real_host_without_provider_path_keeps_launch_unadvertised";
    #[derive(Clone, Copy)]
    struct Frame { phase: &'static str, target: &'static str }
    #[derive(Clone, serde::Serialize)]
    struct Failure { phase: &'static str, target: &'static str, refusal: &'static str, api: &'static str, error_class: &'static str }
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request { schema: u32, test: String, nonce: String, root: [u64; 3] }
    struct Carrier { root: PathBuf, nonce: String, root_id: [u64; 3], _locks: Vec<OwnedHandle>, _request: File }
    struct State { carrier: Option<Carrier>, v1: PathBuf, operation: String, instance: String, frame: Frame, failure: Option<Failure>, save_result: &'static str }
    thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; static OBSERVER_FAILED: Cell<bool> = const { Cell::new(false) }; }
    pub(crate) struct Attempt { armed: bool }
    fn with_state(f: impl FnOnce(&mut State)) { let _ = STATE.try_with(|cell| { if let Ok(mut state) = cell.try_borrow_mut() { if let Some(state) = state.as_mut() { f(state); } } else { let _ = OBSERVER_FAILED.try_with(|flag| flag.set(true)); } }); }
    pub(crate) fn role(path: &Path) -> &'static str {
        let mut role = "unknown";
        with_state(|s| {
            if path == s.v1 { role = "store"; }
            else if path == s.v1.join(LEASE_NAME) { role = "lease"; }
            else if path == s.v1.join(CONFIRMED_NAME) { role = "confirmed"; }
            else if path == s.v1.join(BACKUP_NAME) { role = "backup"; }
            else if path == s.v1.join(TEMP_NAME) { role = "temp"; }
            else if path.parent().is_none() { role = "volume"; }
            else { let mut p = s.v1.parent(); for name in ["workspace", "winsmux", "known_folder"] { if p == Some(path) { role = name; break; } p = p.and_then(Path::parent); } if role == "unknown" { role = "ancestor"; } }
        }); role
    }
    pub(crate) fn name(name: &str) -> &'static str { match name { LEASE_NAME => "lease", CONFIRMED_NAME => "confirmed", BACKUP_NAME => "backup", TEMP_NAME => "temp", _ => "unknown" } }
    pub(crate) fn inherited() -> &'static str { let mut target = "unknown"; with_state(|s| target = s.frame.target); target }
    fn mark(phase: &'static str, target: &'static str, refusal: &'static str, api: &'static str, error_class: &'static str) {
        with_state(|s| if s.failure.is_none() { s.failure = Some(Failure { phase, target, refusal, api, error_class }); });
    }
    pub(crate) fn native(api: &'static str, error: u32) {
        let class = match error { 5 => "access_denied", 32 | 33 => "sharing_violation", 2 | 3 => "not_found", 80 | 183 => "already_exists", _ => "other_native" };
        let mut frame = Frame { phase: "unknown", target: "unknown" }; with_state(|s| frame = s.frame);
        mark(frame.phase, frame.target, "native_api", api, class);
    }
    pub(crate) fn nt_failure() { let mut frame = Frame { phase: "unknown", target: "unknown" }; with_state(|s| frame = s.frame); mark(frame.phase, frame.target, "native_api", "nt_set_information_file", "nt_status_failure"); }
    pub(crate) fn condition(phase: &'static str, target: &'static str) { mark(phase, target, "condition", "none", "not_native"); }
    pub(crate) fn handled() { with_state(|s| s.failure = None); }
    pub(crate) fn scope<T>(phase: &'static str, target: &'static str, body: impl FnOnce() -> Result<T, ErrorCode>) -> Result<T, ErrorCode> {
        let mut previous = None;
        with_state(|s| { previous = Some((s.frame, s.failure.clone())); s.frame = Frame { phase, target }; });
        let result = body();
        with_state(|s| {
            if result.is_ok() { if let Some((_, pending)) = &previous { s.failure = pending.clone(); } }
            else if s.failure.is_none() { s.failure = Some(Failure { phase, target, refusal: if phase == "store_root_observe" || phase == "snapshot_build" || phase == "snapshot_roots" { "dependency_unobserved" } else { "condition" }, api: "none", error_class: if phase == "store_root_observe" || phase == "snapshot_build" || phase == "snapshot_roots" { "unknown" } else { "not_native" } }); }
            if let Some((frame, _)) = previous { s.frame = frame; }
        }); result
    }
    pub(crate) fn save_result<T>(result: &Result<T, ErrorCode>) { with_state(|s| s.save_result = if result.is_ok() { "completed" } else { "refused" }); }
    fn identity(handle: HANDLE, directory: bool) -> Option<[u64; 3]> {
        let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
        if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory || (!directory && info.nNumberOfLinks != 1) { return None; }
        Some([info.dwVolumeSerialNumber as u64, ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64, ((info.ftCreationTime.dwHighDateTime as u64) << 32) | info.ftCreationTime.dwLowDateTime as u64])
    }
    impl Carrier {
        fn read() -> Option<Self> {
            if std::env::var("WINSMUX_TASK876_STARTUP_TRACE").as_deref() != Ok("1") { return None; }
            let root = PathBuf::from(std::env::var_os(ROOT_ENV)?);
            let expected = PathBuf::from(std::env::var_os("USERPROFILE")?).join(".winsmux-stop-attempt");
            if root != expected || !is_drive_absolute(&root) || root.components().any(|c| matches!(c, std::path::Component::ParentDir | std::path::Component::CurDir)) { return None; }
            let nonce = std::env::var(NONCE_ENV).ok()?;
            if nonce.len() != 32 || !nonce.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) { return None; }
            let mut locks = Vec::new();
            for path in ancestor_paths(&root).ok()? {
                let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
                let raw = unsafe { CreateFileW(wide.as_ptr(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null_mut()) };
                if invalid_handle(raw) { return None; }
                let h = unsafe { OwnedHandle::from_raw(raw).ok()? }; identity(h.raw(), true)?; locks.push(h);
            }
            let root_id = identity(locks.last()?.raw(), true)?;
            let mut request = OpenOptions::new().read(true).share_mode(FILE_SHARE_READ).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(root.join("request.json")).ok()?;
            identity(request.as_raw_handle().cast(), false)?;
            if request.metadata().ok()?.len() > 1024 { return None; }
            let mut bytes = Vec::new(); request.read_to_end(&mut bytes).ok()?;
            let value: Request = serde_json::from_slice(&bytes).ok()?;
            if value.schema != 1 || value.test != TEST || value.nonce != nonce || value.root != root_id { return None; }
            Some(Self { root, nonce, root_id, _locks: locks, _request: request })
        }
        fn write(&self, value: &serde_json::Value) -> Option<()> {
            if identity(self._locks.last()?.raw(), true)? != self.root_id { return None; }
            let bytes = serde_json::to_vec(value).ok()?; if bytes.len() > 1024 { return None; }
            let mut file = OpenOptions::new().write(true).create_new(true).share_mode(0).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(self.root.join("result.json")).ok()?;
            identity(file.as_raw_handle().cast(), false)?; file.write_all(&bytes).ok()?; file.flush().ok()?; Some(())
        }
    }
    impl Attempt {
        pub(crate) fn begin(store: &LayoutStore, operation: &str, instance: &str) -> Self {
            let prepared = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| { STATE.try_with(|cell| { let slot = cell.try_borrow().ok()?; if slot.is_some() { None } else { Some(()) } }).ok()??; let carrier = Carrier::read()?; let state = State { carrier: Some(carrier), v1: store.v1.clone(), operation: operation.to_owned(), instance: instance.to_owned(), frame: Frame { phase: "unknown", target: "preparation" }, failure: None, save_result: "unknown" }; STATE.try_with(|cell| { let mut slot = cell.try_borrow_mut().ok()?; if slot.is_some() { return None; } *slot = Some(state); let _ = OBSERVER_FAILED.try_with(|flag| flag.set(false)); Some(()) }).ok()? }));
            Self { armed: matches!(prepared, Ok(Some(()))) }
        }
    }
    impl Drop for Attempt {
        fn drop(&mut self) {
            if !self.armed { return; }
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let state = STATE.try_with(|cell| cell.try_borrow_mut().ok()?.take()).ok().flatten();
                if let Some(s) = state {
                    let Some(carrier) = s.carrier.as_ref() else { return; };
                    let (phase, target, refusal, api, error_class) = match &s.failure { Some(f) if s.save_result == "refused" && !OBSERVER_FAILED.try_with(Cell::get).unwrap_or(true) => (f.phase, f.target, f.refusal, f.api, f.error_class), _ => ("unknown", "unknown", "unknown", "unknown", "unknown") };
                    let record = serde_json::json!({"schema":1,"nonce":&carrier.nonce,"operation_id":&s.operation,"instance_id":&s.instance,"save_result":s.save_result,"phase":phase,"target":target,"refusal":refusal,"api":api,"error_class":error_class,"store_binding":"actual_layout_v1"});
                    let _ = carrier.write(&record);
                }
            }));
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        fn reset() {
            STATE.with(|c| *c.borrow_mut() = Some(State { carrier: None, v1: PathBuf::from(r"C:\fixture\AppData\Local\winsmux\workspace\v1"), operation: "fixture".into(), instance: "fixture".into(), frame: Frame { phase: "unknown", target: "preparation" }, failure: None, save_result: "unknown" }));
            OBSERVER_FAILED.with(|f| f.set(false));
        }
        fn failure() -> Option<Failure> { STATE.with(|c| c.borrow().as_ref().and_then(|s| s.failure.clone())) }
        #[test] fn normal_absence_then_create_has_no_refusal() {
            reset();
            let result = scope("lease_acquire", "lease", || { let absent: Result<Option<()>, ErrorCode> = scope("file_open", "lease", || Ok(None)); assert!(absent?.is_none()); scope("file_open", "lease", || Ok(())) });
            assert!(result.is_ok()); assert!(failure().is_none());
        }
        #[test] fn recovered_create_conflict_is_discarded_before_later_failure() {
            reset();
            let result: Result<(), ErrorCode> = scope("temp_acquire", "temp", || {
                let conflict: Result<(), ErrorCode> = scope("file_open", "temp", || { native("create_file", 183); Err(ErrorCode::PersistenceFailed) });
                assert!(conflict.is_err()); handled();
                scope("snapshot_owner", "temp", || { condition("snapshot_owner", "temp"); Err(ErrorCode::PersistenceFailed) })
            });
            assert_eq!(result, Err(ErrorCode::PersistenceFailed)); let f = failure().unwrap(); assert_eq!(f.phase, "snapshot_owner"); assert_eq!(f.refusal, "condition");
        }
        #[test] fn successful_recovery_and_sibling_scope_do_not_leak_tentative_errors() {
            reset();
            let result: Result<(), ErrorCode> = scope("lease_acquire", "lease", || { let failed: Result<(), ErrorCode> = scope("file_open", "lease", || { native("create_file", 183); Err(ErrorCode::PersistenceFailed) }); assert!(failed.is_err()); handled(); scope("file_open", "lease", || Ok(())) });
            assert!(result.is_ok()); assert!(failure().is_none());
            STATE.with(|c| *c.borrow_mut() = None); let result: Result<(), ErrorCode> = scope("snapshot_read", "confirmed", || Err(ErrorCode::PersistenceFailed)); assert!(result.is_err()); assert!(failure().is_none());
        }
        #[test] fn propagated_native_refusal_survives_parent_and_result_is_unchanged() {
            reset();
            let result: Result<(), ErrorCode> = scope("store_begin", "store", || scope("directory_chain", "store", || scope("ancestor_open", "ancestor", || { native("create_file", 5); Err(ErrorCode::PersistenceFailed) })));
            assert_eq!(result, Err(ErrorCode::PersistenceFailed)); let f = failure().unwrap(); assert_eq!((f.phase, f.target, f.api, f.error_class), ("ancestor_open", "ancestor", "create_file", "access_denied"));
        }
        #[test] fn dependency_and_borrow_failure_remain_unobserved_as_native_causes() {
            reset(); let result: Result<(), ErrorCode> = scope("store_root_observe", "store", || Err(ErrorCode::PersistenceFailed)); assert!(result.is_err()); assert_eq!(failure().unwrap().refusal, "dependency_unobserved");
            STATE.with(|c| { let _held = c.borrow_mut(); let result: Result<(), ErrorCode> = scope("private_acl", "store", || Err(ErrorCode::PersistenceFailed)); assert!(result.is_err()); }); assert!(OBSERVER_FAILED.with(Cell::get));
        }
        #[test] fn observer_scope_preserves_action_unwind_and_actual_role_inventory() {
            reset();
            let panic = std::panic::catch_unwind(|| scope::<()>("snapshot_read", "confirmed", || panic!("synthetic unwind"))); assert!(panic.is_err());
            assert_eq!(role(Path::new(r"C:\fixture\AppData\Local\winsmux\workspace\v1\confirmed.json")), "confirmed");
            assert_eq!(role(Path::new(r"C:\fixture\AppData\Local")), "known_folder");
        }
    }

}

const CONFIRMED_NAME: &str = "confirmed.json";
const BACKUP_NAME: &str = "backup.json";
const TEMP_NAME: &str = "temp.json";
const LEASE_NAME: &str = "lease";
const WIN_LOCAL_SYSTEM_SID: i32 = 22;
const WIN_BUILTIN_ADMINISTRATORS_SID: i32 = 26;
const SID_MAX_BYTES: usize = 68;
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
const FILE_READ_ATTRIBUTES: u32 = 0x0080;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const SYNCHRONIZE: u32 = 0x00100000;
const DRIVE_FIXED: u32 = 3;
const DIRECTORY_HOLD_ACCESS: u32 =
    FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | SYNCHRONIZE | READ_CONTROL;
const MANAGED_WRITE_ACCESS: u32 = GENERIC_READ | GENERIC_WRITE | DELETE | WRITE_OWNER;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SnapshotOwner {
    User,
    Administrators,
}

/// Per-instance fault points for module tests. Not a public store operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LayoutStoreFault {
    None,
    TempWrite,
    TempFlush,
    TempReadback,
    ConfirmedReplace,
    ConfirmedReadback,
    ConfirmedReadbackMemory,
    BackupWrite,
    BackupFlush,
    BackupReadback,
    BackupReplace,
}

#[derive(Clone, Copy)]
enum Target {
    Backup,
    Confirmed,
}

struct PrivateDescriptor {
    descriptor: PSECURITY_DESCRIPTOR,
}

/// Held ancestors from the volume root through the product v1 directory.
struct DirectoryChain {
    handles: Vec<OwnedHandle>,
    v1: PathBuf,
}

/// Same opened handle that was proved ordinary, single-link, and private.
struct ManagedFile {
    handle: OwnedHandle,
}

/// Product-owned layout store rooted at user-unit LocalAppData winsmux/workspace/v1
/// or at a host-created isolated directory.
pub(crate) struct LayoutStore {
    v1: PathBuf,
    identity: Identity,
    create_parents: bool,
    fault: LayoutStoreFault,
    _chain: Option<DirectoryChain>,
}

/// One share-mode-0 lease plus held local-fixed ancestor identity.
/// Drop releases the lease handle and never unlinks the lease file.
pub(crate) struct LayoutTransaction {
    v1: PathBuf,
    identity: Identity,
    _observed: ObservedRoot,
    _chain: DirectoryChain,
    _lease: ManagedFile,
    fault: LayoutStoreFault,
}

impl PrivateDescriptor {
    fn for_user(user: &Sid) -> Result<Self, ErrorCode> {
    observe_store_scope!("descriptor", stop_observation::inherited(), {
        let sddl = format!(
            "D:P(A;OICI;FA;;;{})(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",
            sid_sddl(user)?
        );
        let wide: Vec<u16> = sddl.encode_utf16().chain(std::iter::once(0)).collect();
        let mut descriptor = null_mut();
        if unsafe {
            observe_store_bool!("convert_security_descriptor", ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            ))
        } == 0
            || descriptor.is_null()
        {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(Self { descriptor })

    })
}

    fn for_user_owned_snapshot(user: &Sid) -> Result<Self, ErrorCode> {
    observe_store_scope!("descriptor", stop_observation::inherited(), {
        let sid = sid_sddl(user)?;
        let sddl = format!(
            "O:{sid}D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        );
        let wide: Vec<u16> = sddl.encode_utf16().chain(std::iter::once(0)).collect();
        let mut descriptor = null_mut();
        if unsafe {
            observe_store_bool!("convert_security_descriptor", ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut(),
            ))
        } == 0 || descriptor.is_null() {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(Self { descriptor })

    })
}

    fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.descriptor,
            bInheritHandle: 0,
        }
    }
}

impl Drop for PrivateDescriptor {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            unsafe {
                LocalFree(self.descriptor);
            }
            self.descriptor = null_mut();
        }
    }
}

impl DirectoryChain {
    fn acquire(v1: &Path, user: &Sid, create_parents: bool) -> Result<Self, ErrorCode> {
    observe_store_scope!("directory_chain", stop_observation::role(v1), {
        admit_existing_supported_volume(v1)?;
        let paths = ancestor_paths(v1)?;
        let last = paths.len().checked_sub(1).ok_or(ErrorCode::PersistenceFailed)?;
        let first_create = if create_parents {
            last.saturating_sub(2)
        } else {
            last
        };
        let mut handles = Vec::new();
        for (index, path) in paths.iter().enumerate() {
            match open_directory(path)? {
                Some(handle) => handles.push(handle),
                None => {
                    if index == 0 || index < first_create {
                        return Err(ErrorCode::PersistenceFailed);
                    }
                    let _parent = handles.last().ok_or(ErrorCode::PersistenceFailed)?;
                    create_directory(path, if index == last { Some(user) } else { None })?;
                    match open_directory(path)? {
                        Some(handle) => handles.push(handle),
                        None => return Err(ErrorCode::PersistenceFailed),
                    }
                }
            }
        }
        let leaf = handles.last().ok_or(ErrorCode::PersistenceFailed)?;
        check_private_acl_handle(leaf.raw(), user)?;
        Ok(Self {
            handles,
            v1: v1.to_path_buf(),
        })

    })
}

    fn open_existing(
        &self,
        name: &str,
        access: u32,
        share: u32,
        user: &Sid,
    ) -> Result<Option<ManagedFile>, ErrorCode> {
    observe_store_scope!("existing_snapshot_open", stop_observation::name(name), {
        let path = self.v1.join(name);
        match open_file(&path, access, share, OPEN_EXISTING, null())? {
            None => Ok(None),
            Some(handle) => Ok(Some(ManagedFile::proved_snapshot_read(handle, user)?)),
        }

    })
}

    fn acquire_writable(&self, name: &str, user: &Sid) -> Result<ManagedFile, ErrorCode> {
    observe_store_scope!("temp_acquire", stop_observation::name(name), {
        let path = self.v1.join(name);
        if let Some(handle) = open_file(&path, MANAGED_WRITE_ACCESS, 0, OPEN_EXISTING, null())? {
            return ManagedFile::proved_writable_snapshot(handle, user);
        }
        let descriptor = PrivateDescriptor::for_user_owned_snapshot(user)?;
        let sa = descriptor.attributes();
        match open_file(&path, MANAGED_WRITE_ACCESS, 0, CREATE_NEW, &sa) {
            Ok(Some(handle)) => ManagedFile::proved_writable_snapshot(handle, user),
            Ok(None) | Err(_) => {
                #[cfg(debug_assertions)] stop_observation::handled();
                let handle = open_file(&path, MANAGED_WRITE_ACCESS, 0, OPEN_EXISTING, null())?
                    .ok_or(ErrorCode::PersistenceFailed)?;
                ManagedFile::proved_writable_snapshot(handle, user)
            }
        }

    })
}

    fn open_lease(&self, user: &Sid) -> Result<ManagedFile, ErrorCode> {
    observe_store_scope!("lease_acquire", "lease", {
        let path = self.v1.join(LEASE_NAME);
        if let Some(handle) = open_file(&path, GENERIC_READ | GENERIC_WRITE, 0, OPEN_EXISTING, null())?
        {
            return ManagedFile::proved(handle, user);
        }
        let descriptor = PrivateDescriptor::for_user(user)?;
        let sa = descriptor.attributes();
        match open_file(&path, GENERIC_READ | GENERIC_WRITE, 0, CREATE_NEW, &sa) {
            Ok(Some(handle)) => ManagedFile::proved(handle, user),
            Ok(None) | Err(_) => {
                #[cfg(debug_assertions)] stop_observation::handled();
                let handle = open_file(
                    &path,
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    OPEN_EXISTING,
                    null(),
                )?
                .ok_or(ErrorCode::PersistenceFailed)?;
                ManagedFile::proved(handle, user)
            }
        }

    })
}
}

impl ManagedFile {
    fn proved(handle: OwnedHandle, user: &Sid) -> Result<Self, ErrorCode> {
    observe_store_scope!("lease_validate", stop_observation::inherited(), {
        let file = Self { handle };
        inspect_ordinary_single_link(file.handle.raw())?;
        check_private_acl_handle(file.handle.raw(), user)?;
        Ok(file)

    })
}

    fn proved_snapshot_read(handle: OwnedHandle, user: &Sid) -> Result<Self, ErrorCode> {
    observe_store_scope!("snapshot_validate", stop_observation::inherited(), {
        let file = Self { handle };
        inspect_ordinary_single_link(file.raw())?;
        snapshot_owner(file.raw(), user)?;
        Ok(file)

    })
}

    fn proved_writable_snapshot(handle: OwnedHandle, user: &Sid) -> Result<Self, ErrorCode> {
    observe_store_scope!("snapshot_owner", stop_observation::inherited(), {
        let file = Self::proved_snapshot_read(handle, user)?;
        if snapshot_owner(file.raw(), user)? == SnapshotOwner::Administrators {
            if unsafe {
                observe_store_status!("set_security_info", SetSecurityInfo(
                    file.raw(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                    user.as_ptr(), null_mut(), null(), null(),
                ))
            } != 0 {
                return Err(ErrorCode::PersistenceFailed);
            }
            if snapshot_owner(file.raw(), user)? != SnapshotOwner::User {
                return Err(ErrorCode::PersistenceFailed);
            }
        }
        Ok(file)

    })
}

    fn raw(&self) -> HANDLE {
        self.handle.raw()
    }

    fn replace_contents(&self, bytes: &[u8]) -> Result<(), ErrorCode> {
    observe_store_scope!("temp_write", stop_observation::inherited(), {
        if unsafe { observe_store_bool!("set_file_pointer", SetFilePointerEx(self.handle.raw(), 0, null_mut(), 0)) } == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        if unsafe { observe_store_bool!("set_end_of_file", SetEndOfFile(self.handle.raw())) } == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        write_all(self.handle.raw(), bytes)

    })
}

    fn flush(&self) -> Result<(), ErrorCode> {
    observe_store_scope!("temp_flush", stop_observation::inherited(), {
        if unsafe { observe_store_bool!("flush_file", FlushFileBuffers(self.handle.raw())) } == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(())

    })
}

    fn read_bytes(
        &self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<Vec<u8>, ErrorCode> {
    observe_store_scope!("snapshot_read", stop_observation::inherited(), {
        read_file_bytes(self.handle.raw(), authority, pool)

    })
}

    fn readback_equals(
        &self,
        expected: &[u8],
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<(), ErrorCode> {
    observe_store_scope!("readback", stop_observation::inherited(), {
        readback_equals(self.handle.raw(), expected, authority, pool)

    })
}

    fn rename_replace(&self, leaf: &str) -> Result<(), ErrorCode> {
    observe_store_scope!("rename", stop_observation::inherited(), {
        rename_held(self.handle.raw(), leaf, true)

    })
}

    fn prove_after_rename(&self, user: &Sid) -> Result<(), ErrorCode> {
    observe_store_scope!("final_owner", stop_observation::inherited(), {
        inspect_ordinary_single_link(self.handle.raw())?;
        if snapshot_owner(self.handle.raw(), user)? != SnapshotOwner::User {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(())

    })
}
}

impl LayoutStore {
    pub(crate) fn open_user_unit() -> Result<Self, ErrorCode> {
        let identity = Identity::current().map_err(|_| ErrorCode::PersistenceFailed)?;
        let v1 = local_app_data()?
            .join("winsmux")
            .join("workspace")
            .join("v1");
        if !is_drive_absolute(&v1) {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(Self {
            v1,
            identity,
            create_parents: true,
            fault: LayoutStoreFault::None,
            _chain: None,
        })
    }

    /// Host-initialization isolated root only. Not a request, env, or project path.
    pub(crate) fn open_isolated(root: &Path) -> Result<Self, ErrorCode> {
        if !is_drive_absolute(root) {
            return Err(ErrorCode::PersistenceFailed);
        }
        let identity = Identity::current().map_err(|_| ErrorCode::PersistenceFailed)?;
        let chain = DirectoryChain::acquire(root, &identity.user, false)?;
        Ok(Self {
            v1: root.to_path_buf(),
            identity,
            create_parents: false,
            fault: LayoutStoreFault::None,
            _chain: Some(chain),
        })
    }

    #[cfg(test)]
    pub(crate) fn inject_fault(&mut self, fault: LayoutStoreFault) {
        self.fault = fault;
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_release_guard_for_invalid_setup(&mut self) {
        drop(self._chain.take());
    }

    pub(crate) fn begin(
        &self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<LayoutTransaction, ErrorCode> {
    observe_store_scope!("store_begin", "store", {
        let chain = DirectoryChain::acquire(&self.v1, &self.identity.user, self.create_parents)?;
        let observed = observe_store(path_str(&self.v1)?, authority, pool)?;
        check_private_acl_handle(
            chain.handles.last().ok_or(ErrorCode::PersistenceFailed)?.raw(),
            &self.identity.user,
        )?;
        let lease = chain.open_lease(&self.identity.user)?;
        Ok(LayoutTransaction {
            v1: self.v1.clone(),
            identity: self.identity.clone(),
            _observed: observed,
            _chain: chain,
            _lease: lease,
            fault: self.fault,
        })

    })
}
}

impl LayoutTransaction {
    pub(crate) fn save(
        &self,
        snapshot: &Snapshot,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<(), ErrorCode> {
    observe_store_scope!("snapshot_save", "store", {
        let intended = observe_store_scope!("snapshot_serialize", "preparation", { serialize_snapshot(snapshot).map_err(|_| ErrorCode::PersistenceFailed) })?;
        let confirmed = self.classify_confirmed(authority, pool)?;
        let backup = self.classify_backup(authority, pool)?;
        match (confirmed, backup) {
            (None, None) => self.stage_replace(
                CONFIRMED_NAME,
                &intended,
                Some(snapshot),
                Target::Confirmed,
                authority,
                pool,
            ),
            (Some((proved, _)), backup_bytes) => {
                let refresh = backup_bytes
                    .as_ref()
                    .map_or(true, |(existing, owner)| {
                        existing != &proved || *owner != SnapshotOwner::User
                    });
                if refresh {
                    self.stage_replace(
                        BACKUP_NAME,
                        &proved,
                        None,
                        Target::Backup,
                        authority,
                        pool,
                    )?;
                }
                self.stage_replace(
                    CONFIRMED_NAME,
                    &intended,
                    Some(snapshot),
                    Target::Confirmed,
                    authority,
                    pool,
                )
            }
            (None, Some(_)) => { #[cfg(debug_assertions)] stop_observation::condition("confirmed_backup_policy", "backup"); Err(ErrorCode::PersistenceFailed) },
        }

    })
}

    pub(crate) fn read_confirmed(
        &self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<Snapshot, ErrorCode> {
    observe_store_scope!("confirmed_read", "confirmed", {
        match self.classify_confirmed(authority, pool)? {
            Some((_, snapshot)) => Ok(snapshot),
            None => Err(ErrorCode::PersistenceFailed),
        }

    })
}

    #[cfg(test)]
    fn lease_key(&self) -> Result<(u32, u64), ErrorCode> {
        file_index_key(self._lease.raw())
    }

    fn classify_confirmed(
        &self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<Option<(Vec<u8>, Snapshot)>, ErrorCode> {
    observe_store_scope!("confirmed_preflight", "confirmed", {
        match self._chain.open_existing(
            CONFIRMED_NAME,
            GENERIC_READ,
            FILE_SHARE_READ,
            &self.identity.user,
        )? {
            None => Ok(None),
            Some(file) => {
                let bytes = file.read_bytes(authority, pool)?;
                let snapshot = parse_snapshot(&bytes).map_err(|_| ErrorCode::PersistenceFailed)?;
                Ok(Some((bytes, snapshot)))
            }
        }

    })
}

    fn classify_backup(
        &self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<Option<(Vec<u8>, SnapshotOwner)>, ErrorCode> {
    observe_store_scope!("backup_preflight", "backup", {
        match self._chain.open_existing(
            BACKUP_NAME,
            GENERIC_READ,
            FILE_SHARE_READ,
            &self.identity.user,
        )? {
            None => Ok(None),
            Some(file) => Ok(Some((
                file.read_bytes(authority, pool)?,
                snapshot_owner(file.raw(), &self.identity.user)?,
            ))),
        }

    })
}

    fn stage_replace(
        &self,
        destination_name: &str,
        bytes: &[u8],
        snapshot: Option<&Snapshot>,
        target: Target,
        authority: &AllocationAuthority,
        pool: AllocationPool,
    ) -> Result<(), ErrorCode> {
    observe_store_scope!("stage_replace", stop_observation::name(destination_name), {
        if self.write_fault(target) {
            return Err(ErrorCode::PersistenceFailed);
        }
        let file = self._chain.acquire_writable(TEMP_NAME, &self.identity.user)?;
        if let Err(err) = file.replace_contents(bytes) {
            return Err(err);
        }
        if self.flush_fault(target) {
            return Err(ErrorCode::PersistenceFailed);
        }
        if let Err(err) = file.flush() {
            return Err(err);
        }
        if self.temp_readback_fault(target) {
            return Err(ErrorCode::PersistenceFailed);
        }
        if let Err(err) = file.readback_equals(bytes, authority, pool) {
            return Err(err);
        }
        if let Err(err) = prove_bytes(bytes, snapshot) {
            return Err(err);
        }
        if self.replace_fault(target) {
            return Err(ErrorCode::PersistenceFailed);
        }
        if let Err(err) = file.rename_replace(destination_name) {
            return Err(err);
        }
        if self.final_readback_fault(target) {
            return Err(ErrorCode::PersistenceFailed);
        }
        file.prove_after_rename(&self.identity.user)?;
        if matches!(target, Target::Confirmed)
            && self.injected(LayoutStoreFault::ConfirmedReadbackMemory)
        {
            return Err(ErrorCode::ResourceExhausted);
        }
        let got = file.read_bytes(authority, pool)?;
        if got != bytes {
            return Err(ErrorCode::PersistenceFailed);
        }
        prove_bytes(&got, snapshot)

    })
}

    fn injected(&self, fault: LayoutStoreFault) -> bool {
        self.fault == fault
    }

    fn write_fault(&self, target: Target) -> bool {
        match target {
            Target::Backup => self.injected(LayoutStoreFault::BackupWrite),
            Target::Confirmed => self.injected(LayoutStoreFault::TempWrite),
        }
    }

    fn flush_fault(&self, target: Target) -> bool {
        match target {
            Target::Backup => self.injected(LayoutStoreFault::BackupFlush),
            Target::Confirmed => self.injected(LayoutStoreFault::TempFlush),
        }
    }

    fn temp_readback_fault(&self, target: Target) -> bool {
        match target {
            Target::Backup => self.injected(LayoutStoreFault::BackupReadback),
            Target::Confirmed => self.injected(LayoutStoreFault::TempReadback),
        }
    }

    fn replace_fault(&self, target: Target) -> bool {
        match target {
            Target::Backup => self.injected(LayoutStoreFault::BackupReplace),
            Target::Confirmed => self.injected(LayoutStoreFault::ConfirmedReplace),
        }
    }

    fn final_readback_fault(&self, target: Target) -> bool {
        match target {
            Target::Backup => false,
            Target::Confirmed => self.injected(LayoutStoreFault::ConfirmedReadback),
        }
    }
}

pub(crate) fn local_app_data() -> Result<PathBuf, ErrorCode> {
    let mut raw = null_mut();
    let hr = unsafe { SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, null_mut(), &mut raw) };
    if hr < 0 || raw.is_null() {
        if !raw.is_null() {
            unsafe {
                CoTaskMemFree(raw.cast());
            }
        }
        return Err(ErrorCode::PersistenceFailed);
    }
    let mut len = 0usize;
    unsafe {
        while *raw.add(len) != 0 {
            len += 1;
        }
    }
    let text = String::from_utf16(unsafe { std::slice::from_raw_parts(raw, len) });
    unsafe {
        CoTaskMemFree(raw.cast());
    }
    let text = text.map_err(|_| ErrorCode::PersistenceFailed)?;
    if text.is_empty() {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(PathBuf::from(text))
}

fn is_drive_absolute(path: &Path) -> bool {
    path_str(path).ok().is_some_and(|s| {
        let bytes = s.as_bytes();
        bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/')
    })
}

fn path_str(path: &Path) -> Result<&str, ErrorCode> {
    observe_store_scope!("path_encoding", stop_observation::role(path), {
    path.to_str()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
        .ok_or(ErrorCode::PersistenceFailed)

    })
}

fn wide_path(path: &Path) -> Result<Vec<u16>, ErrorCode> {
    observe_store_scope!("path_encoding", stop_observation::role(path), {
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    if wide.is_empty() || wide.contains(&0) {
        return Err(ErrorCode::PersistenceFailed);
    }
    wide.push(0);
    Ok(wide)

    })
}

fn normalize_ancestor(path: &Path) -> Option<PathBuf> {
    let text = path.to_str()?;
    let bytes = text.as_bytes();
    if bytes.len() == 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return Some(PathBuf::from(format!("{}:\\", bytes[0] as char)));
    }
    if is_drive_absolute(path) {
        Some(path.to_path_buf())
    } else {
        None
    }
}

fn ancestor_paths(path: &Path) -> Result<Vec<PathBuf>, ErrorCode> {
    observe_store_scope!("ancestor_shape", stop_observation::role(path), {
    let mut items = Vec::new();
    let mut current = normalize_ancestor(path).ok_or(ErrorCode::PersistenceFailed)?;
    loop {
        items.push(current.clone());
        let Some(parent) = current.parent() else {
            break;
        };
        let Some(next) = normalize_ancestor(parent) else {
            break;
        };
        if next == current {
            break;
        }
        current = next;
    }
    items.reverse();
    if items.is_empty() {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(items)

    })
}

fn observe_store(
    path: &str,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ObservedRoot, ErrorCode> {
    observe_store_scope!("store_root_observe", "store", {
    match observe_root(path, authority, pool) {
        Ok(root) => Ok(root),
        Err(ObserveError::Exhausted) => Err(ErrorCode::ResourceExhausted),
        Err(_) => Err(ErrorCode::PersistenceFailed),
    }

    })
}

fn invalid_handle(handle: HANDLE) -> bool {
    handle.is_null() || handle == INVALID_HANDLE_VALUE
}

fn open_directory(path: &Path) -> Result<Option<OwnedHandle>, ErrorCode> {
    observe_store_scope!("ancestor_open", stop_observation::role(path), {
    let wide = wide_path(path)?;
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            DIRECTORY_HOLD_ACCESS,
            FILE_SHARE_READ,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };
    if invalid_handle(handle) {
        let error = unsafe { GetLastError() };
        return match error {
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => Ok(None),
            _ => { #[cfg(debug_assertions)] stop_observation::native("create_file", error); Err(ErrorCode::PersistenceFailed) },
        };
    }
    let owned =
        unsafe { OwnedHandle::from_raw(handle) }.map_err(|_| ErrorCode::PersistenceFailed)?;
    inspect_held_directory(owned.raw())?;
    Ok(Some(owned))

    })
}

fn admit_existing_supported_volume(path: &Path) -> Result<(), ErrorCode> {
    observe_store_scope!("volume_admission", "volume", {
    let text = path_str(path)?;
    classify_path_syntax(text).map_err(|_| ErrorCode::PersistenceFailed)?;
    if !is_drive_absolute(path) {
        return Err(ErrorCode::PersistenceFailed);
    }
    confirm_fixed_local_non_subst_volume(text.as_bytes()[0].to_ascii_uppercase())

    })
}

fn dos_device_target_is_subst(mapped: &str) -> bool {
    mapped.starts_with(r"\??\")
}

fn confirm_fixed_local_non_subst_volume(drive: u8) -> Result<(), ErrorCode> {
    observe_store_scope!("volume_policy", "volume", {
    let mut root_path: Vec<u16> = format!("{}:\\", drive as char)
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let drive_type = unsafe { GetDriveTypeW(root_path.as_mut_ptr()) };
    if drive_type != DRIVE_FIXED {
        return Err(ErrorCode::PersistenceFailed);
    }
    let mut device: Vec<u16> = format!("{}:", drive as char)
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut target = vec![0u16; 1024];
    let written =
        unsafe { observe_store_bool!("query_dos_device", QueryDosDeviceW(device.as_mut_ptr(), target.as_mut_ptr(), target.len() as u32)) };
    if written == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    let end = target
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(target.len());
    let mapped = String::from_utf16(&target[..end]).map_err(|_| ErrorCode::PersistenceFailed)?;
    if dos_device_target_is_subst(&mapped) {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(())

    })
}

fn create_directory(path: &Path, user: Option<&Sid>) -> Result<(), ErrorCode> {
    observe_store_scope!("directory_create", stop_observation::role(path), {
    let wide = wide_path(path)?;
    let created = if let Some(user) = user {
        let descriptor = PrivateDescriptor::for_user(user)?;
        let sa = descriptor.attributes();
        unsafe { CreateDirectoryW(wide.as_ptr(), &sa) }
    } else {
        unsafe { CreateDirectoryW(wide.as_ptr(), null()) }
    };
    if created == 0 {
        let err = unsafe { GetLastError() };
        if err != ERROR_ALREADY_EXISTS {
            #[cfg(debug_assertions)] stop_observation::native("create_directory", err);
            return Err(ErrorCode::PersistenceFailed);
        }
    }
    Ok(())

    })
}

fn open_file(
    path: &Path,
    access: u32,
    share: u32,
    disposition: u32,
    security: *const SECURITY_ATTRIBUTES,
) -> Result<Option<OwnedHandle>, ErrorCode> {
    observe_store_scope!("file_open", stop_observation::role(path), {
    let wide = wide_path(path)?;
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            access,
            share,
            security,
            disposition,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };
    if invalid_handle(handle) {
        let error = unsafe { GetLastError() };
        return match error {
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND if disposition == OPEN_EXISTING => Ok(None),
            _ => { #[cfg(debug_assertions)] stop_observation::native("create_file", error); Err(ErrorCode::PersistenceFailed) },
        };
    }
    let owned =
        unsafe { OwnedHandle::from_raw(handle) }.map_err(|_| ErrorCode::PersistenceFailed)?;
    Ok(Some(owned))

    })
}

fn inspect_held_directory(handle: HANDLE) -> Result<(), ErrorCode> {
    observe_store_scope!("directory_inspect", stop_observation::inherited(), {
    let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
    if unsafe { observe_store_bool!("get_file_information", GetFileInformationByHandle(handle, &mut info)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
        || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(())

    })
}

fn inspect_ordinary_single_link(handle: HANDLE) -> Result<(), ErrorCode> {
    observe_store_scope!("file_inspect", stop_observation::inherited(), {
    let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
    if unsafe { observe_store_bool!("get_file_information", GetFileInformationByHandle(handle, &mut info)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0
        || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || info.nNumberOfLinks != 1
    {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(())

    })
}

fn file_index_key(handle: HANDLE) -> Result<(u32, u64), ErrorCode> {
    let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
    if unsafe { observe_store_bool!("get_file_information", GetFileInformationByHandle(handle, &mut info)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    let index = ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64;
    Ok((info.dwVolumeSerialNumber, index))
}

mod nt_rename {
    use std::ffi::c_void;
    use windows_sys::Win32::Foundation::HANDLE;

    pub const FILE_RENAME_INFORMATION: u32 = 10;

    #[repr(C)]
    pub struct IoStatusBlock {
        pub status: usize,
        pub information: usize,
    }

    #[repr(C)]
    pub struct FileRenameInformation {
        pub replace_if_exists: u8,
        pub root_directory: HANDLE,
        pub file_name_length: u32,
        pub file_name: [u16; 1],
    }

    #[link(name = "ntdll")]
    extern "system" {
        pub fn NtSetInformationFile(
            file_handle: HANDLE,
            io_status_block: *mut IoStatusBlock,
            file_information: *const c_void,
            length: u32,
            file_information_class: u32,
        ) -> i32;
    }
}

fn rename_held(handle: HANDLE, leaf: &str, replace: bool) -> Result<(), ErrorCode> {
    observe_store_scope!("rename", stop_observation::name(leaf), {
    if leaf != CONFIRMED_NAME && leaf != BACKUP_NAME {
        return Err(ErrorCode::PersistenceFailed);
    }
    let name: Vec<u16> = leaf.encode_utf16().collect();
    if name.is_empty() || name.contains(&0) {
        return Err(ErrorCode::PersistenceFailed);
    }
    let name_bytes = name
        .len()
        .checked_mul(2)
        .ok_or(ErrorCode::PersistenceFailed)?;
    let name_bytes_u32 = u32::try_from(name_bytes).map_err(|_| ErrorCode::PersistenceFailed)?;
    let extra = name
        .len()
        .checked_sub(1)
        .and_then(|units| units.checked_mul(2))
        .ok_or(ErrorCode::PersistenceFailed)?;
    let size = size_of::<nt_rename::FileRenameInformation>()
        .checked_add(extra)
        .ok_or(ErrorCode::PersistenceFailed)?;
    let size_u32 = u32::try_from(size).map_err(|_| ErrorCode::PersistenceFailed)?;
    let words = size.div_ceil(size_of::<u64>());
    let mut storage = vec![0u64; words];
    let buffer = storage.as_mut_ptr() as *mut u8;
    unsafe {
        let info = buffer as *mut nt_rename::FileRenameInformation;
        (*info).replace_if_exists = u8::from(replace);
        (*info).root_directory = null_mut();
        (*info).file_name_length = name_bytes_u32;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).file_name.as_mut_ptr(), name.len());
        let mut io_status = nt_rename::IoStatusBlock {
            status: 0,
            information: 0,
        };
        let status = nt_rename::NtSetInformationFile(
            handle,
            &mut io_status,
            buffer.cast(),
            size_u32,
            nt_rename::FILE_RENAME_INFORMATION,
        );
        if status != 0 {
            #[cfg(debug_assertions)] stop_observation::nt_failure();
            return Err(ErrorCode::PersistenceFailed);
        }
    }
    Ok(())

    })
}

fn allocation(_: AllocationError) -> ErrorCode {
    ErrorCode::ResourceExhausted
}

fn read_file_bytes(
    handle: HANDLE,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<Vec<u8>, ErrorCode> {
    observe_store_scope!("snapshot_read", stop_observation::inherited(), {
    let mut size = 0i64;
    if unsafe { observe_store_bool!("set_file_pointer", SetFilePointerEx(handle, 0, null_mut(), 0)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    if unsafe { observe_store_bool!("get_file_size", GetFileSizeEx(handle, &mut size)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    if size < 0 || size as u64 > MAX_MESSAGE_BYTES as u64 {
        return Err(ErrorCode::PersistenceFailed);
    }
    let size = size as usize;
    if size == 0 {
        return Ok(Vec::new());
    }
    let mut buf = ChargedVec::<u8>::with_capacity(authority, pool, size, size).map_err(allocation)?;
    buf.try_resize(size, 0).map_err(allocation)?;
    read_all(handle, &mut buf)?;
    Ok(buf.to_vec())

    })
}

fn read_all(handle: HANDLE, buf: &mut [u8]) -> Result<(), ErrorCode> {
    observe_store_scope!("snapshot_read", stop_observation::inherited(), {
    let mut offset = 0;
    while offset < buf.len() {
        let mut transferred = 0u32;
        let ok = unsafe {
            observe_store_bool!("read_file", ReadFile(
                handle,
                buf[offset..].as_mut_ptr().cast(),
                (buf.len() - offset) as u32,
                &mut transferred,
                null_mut(),
            ))
        };
        if ok == 0 || transferred == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        offset += transferred as usize;
    }
    Ok(())

    })
}

fn write_all(handle: HANDLE, mut data: &[u8]) -> Result<(), ErrorCode> {
    observe_store_scope!("temp_write", stop_observation::inherited(), {
    while !data.is_empty() {
        let mut transferred = 0u32;
        let ok = unsafe {
            observe_store_bool!("write_file", WriteFile(
                handle,
                data.as_ptr().cast(),
                data.len() as u32,
                &mut transferred,
                null_mut(),
            ))
        };
        if ok == 0 || transferred == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        data = &data[transferred as usize..];
    }
    Ok(())

    })
}

fn readback_equals(
    handle: HANDLE,
    expected: &[u8],
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<(), ErrorCode> {
    observe_store_scope!("readback", stop_observation::inherited(), {
    if unsafe { observe_store_bool!("set_file_pointer", SetFilePointerEx(handle, 0, null_mut(), 0)) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    let got = read_file_bytes(handle, authority, pool)?;
    if got.as_slice() != expected {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(())

    })
}

fn prove_bytes(bytes: &[u8], snapshot: Option<&Snapshot>) -> Result<(), ErrorCode> {
    observe_store_scope!("snapshot_validate", stop_observation::inherited(), {
    parse_snapshot(bytes).map_err(|_| ErrorCode::PersistenceFailed)?;
    if let Some(snapshot) = snapshot {
        let canonical = serialize_snapshot(snapshot).map_err(|_| ErrorCode::PersistenceFailed)?;
        if canonical != bytes {
            return Err(ErrorCode::PersistenceFailed);
        }
    }
    Ok(())

    })
}

fn sid_sddl(sid: &Sid) -> Result<String, ErrorCode> {
    observe_store_scope!("descriptor", stop_observation::inherited(), {
    let mut value = null_mut();
    if unsafe { observe_store_bool!("convert_sid_string", ConvertSidToStringSidW(sid.as_ptr(), &mut value)) } == 0 || value.is_null() {
        return Err(ErrorCode::PersistenceFailed);
    }
    let mut length = 0usize;
    unsafe {
        while *value.add(length) != 0 {
            length += 1;
        }
    }
    let result = String::from_utf16(unsafe { std::slice::from_raw_parts(value, length) })
        .map_err(|_| ErrorCode::PersistenceFailed);
    unsafe {
        LocalFree(value.cast::<c_void>());
    }
    result

    })
}

fn well_known_sid(kind: i32) -> Result<[u8; SID_MAX_BYTES], ErrorCode> {
    observe_store_scope!("descriptor", stop_observation::inherited(), {
    let mut sid = [0u8; SID_MAX_BYTES];
    let mut len = sid.len() as u32;
    let ok = unsafe { observe_store_bool!("create_well_known_sid", CreateWellKnownSid(kind, null_mut(), sid.as_mut_ptr().cast(), &mut len)) };
    if ok == 0 || len == 0 || len as usize > sid.len() {
        return Err(ErrorCode::PersistenceFailed);
    }
    if unsafe { IsValidSid(sid.as_mut_ptr().cast()) } == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(sid)

    })
}

fn check_private_acl_handle(handle: HANDLE, user: &Sid) -> Result<(), ErrorCode> {
    observe_store_scope!("private_acl", stop_observation::inherited(), {
    let mut dacl = null_mut();
    let mut sd: PSECURITY_DESCRIPTOR = null_mut();
    let err = unsafe {
        observe_store_status!("get_security_info", GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut sd,
        ))
    };
    if err != 0 || sd.is_null() || dacl.is_null() {
        if !sd.is_null() {
            unsafe {
                LocalFree(sd);
            }
        }
        return Err(ErrorCode::PersistenceFailed);
    }
    let result = dacl_is_private(dacl, user, false);
    unsafe {
        LocalFree(sd);
    }
    result

    })
}

fn snapshot_owner(handle: HANDLE, user: &Sid) -> Result<SnapshotOwner, ErrorCode> {
    observe_store_scope!("snapshot_owner", stop_observation::inherited(), {
    let mut owner: PSID = null_mut();
    let mut dacl = null_mut();
    let mut sd: PSECURITY_DESCRIPTOR = null_mut();
    let err = unsafe {
        observe_store_status!("get_security_info", GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut sd,
        ))
    };
    if err != 0 || sd.is_null() || owner.is_null() || dacl.is_null() {
        if !sd.is_null() {
            unsafe { LocalFree(sd); }
        }
        return Err(ErrorCode::PersistenceFailed);
    }
    let result = (|| {
        let mut control = 0u16;
        let mut revision = 0u32;
        if unsafe { observe_store_bool!("get_sd_control", GetSecurityDescriptorControl(sd, &mut control, &mut revision)) } == 0
            || control & SE_DACL_PROTECTED == 0
        {
            return Err(ErrorCode::PersistenceFailed);
        }
        dacl_is_private(dacl, user, true)?;
        if unsafe { EqualSid(owner, user.as_ptr()) } != 0 {
            return Ok(SnapshotOwner::User);
        }
        let admins = well_known_sid(WIN_BUILTIN_ADMINISTRATORS_SID)?;
        if unsafe { EqualSid(owner, admins.as_ptr().cast_mut().cast()) } != 0 {
            return Ok(SnapshotOwner::Administrators);
        }
        Err(ErrorCode::PersistenceFailed)
    })();
    unsafe { LocalFree(sd); }
    result

    })
}

fn dacl_is_private(
    dacl: *mut windows_sys::Win32::Security::ACL,
    user: &Sid,
    require_full_user_access: bool,
) -> Result<(), ErrorCode> {
    observe_store_scope!("private_acl", stop_observation::inherited(), {
    let mut info = ACL_SIZE_INFORMATION {
        AclBytesInUse: 0,
        AclBytesFree: 0,
        AceCount: 0,
    };
    if unsafe {
        observe_store_bool!("get_acl_information", GetAclInformation(
            dacl,
            (&mut info as *mut ACL_SIZE_INFORMATION).cast(),
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        ))
    } == 0
    {
        return Err(ErrorCode::PersistenceFailed);
    }
    if info.AceCount == 0 {
        return Err(ErrorCode::PersistenceFailed);
    }
    let system = well_known_sid(WIN_LOCAL_SYSTEM_SID)?;
    let admins = well_known_sid(WIN_BUILTIN_ADMINISTRATORS_SID)?;
    let mut saw_user = false;
    let mut saw_user_full_access = false;
    for index in 0..info.AceCount {
        let mut ace: *mut c_void = null_mut();
        if unsafe { observe_store_bool!("get_ace", GetAce(dacl, index, &mut ace)) } == 0 || ace.is_null() {
            return Err(ErrorCode::PersistenceFailed);
        }
        let header = unsafe { &*(ace as *const ACE_HEADER) };
        if header.AceType != ACCESS_ALLOWED_ACE_TYPE {
            return Err(ErrorCode::PersistenceFailed);
        }
        let allowed = unsafe { &*(ace as *const ACCESS_ALLOWED_ACE) };
        let sid: PSID = (&allowed.SidStart as *const u32).cast::<c_void>().cast_mut();
        if unsafe { IsValidSid(sid) } == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        if unsafe { EqualSid(sid, user.as_ptr()) } != 0 {
            saw_user = true;
            saw_user_full_access |= allowed.Mask & FILE_ALL_ACCESS == FILE_ALL_ACCESS;
            continue;
        }
        let system_ok = unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } != 0;
        let admin_ok = unsafe { EqualSid(sid, admins.as_ptr().cast_mut().cast()) } != 0;
        if system_ok || admin_ok {
            continue;
        }
        return Err(ErrorCode::PersistenceFailed);
    }
    if !saw_user || (require_full_user_access && !saw_user_full_access) {
        return Err(ErrorCode::PersistenceFailed);
    }
    Ok(())

    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::{
        Axis, Hex16, Hex32, LayoutNode, NonEmpty, Nullable, PaneId, ProjectId, Ratio,
        RootIdentity, SavedLayout, SavedPane, SavedProject, U, Version,
    };
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSecurityDescriptorToStringSecurityDescriptorW, GetNamedSecurityInfoW,
        SetNamedSecurityInfoW,
    };
    use windows_sys::Win32::Security::{
        GetSecurityDescriptorDacl, UNPROTECTED_DACL_SECURITY_INFORMATION,
    };
    use windows_sys::Win32::Storage::FileSystem::{CREATE_ALWAYS, FILE_SHARE_DELETE, FILE_SHARE_WRITE};

    static SEQ: AtomicU64 = AtomicU64::new(1);

    struct OwnedFixture {
        root: PathBuf,
    }

    fn exclusive_create_directory(path: &Path) -> Result<(), ErrorCode> {
        let wide = wide_path(path)?;
        if unsafe { CreateDirectoryW(wide.as_ptr(), null()) } == 0 {
            return Err(ErrorCode::PersistenceFailed);
        }
        Ok(())
    }

    fn unique_root() -> (OwnedFixture, PathBuf) {
        loop {
            let root = std::env::temp_dir().join(format!(
                "winsmux-task866-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, Ordering::Relaxed)
            ));
            match exclusive_create_directory(&root) {
                Ok(()) => {
                    return (
                        OwnedFixture {
                            root: root.clone(),
                        },
                        root,
                    );
                }
                Err(_) if root.exists() => {}
                Err(_) => panic!("fixture parent create failed"),
            }
        }
    }

    fn fixture() -> (OwnedFixture, LayoutStore, AllocationAuthority) {
        let (guard, parent) = unique_root();
        let root = parent.join("v1");
        let store = LayoutStore::open_isolated(&root).expect("isolated v1");
        (guard, store, AllocationAuthority::host())
    }

    fn allow_invalid_leaf_setup(store: &mut LayoutStore) {
        store.testing_release_guard_for_invalid_setup();
    }

    fn pool() -> AllocationPool {
        AllocationPool::ActiveOwner
    }

    fn empty(generation: u64, topology: u64) -> Snapshot {
        Snapshot {
            schema_version: Version::new(1).expect("schema"),
            generation: U::new(generation).expect("generation"),
            topology_revision: U::new(topology).expect("topology"),
            projects: Vec::new(),
            panes: Vec::new(),
            layouts: Vec::new(),
            selected_project_id: Nullable(None),
            selected_pane_id: Nullable(None),
        }
    }

    fn unordered_layout(generation: u64, topology: u64) -> Snapshot {
        let first_project = ProjectId::new("30000000-0000-4000-8000-000000000001").unwrap();
        let second_project = ProjectId::new("30000000-0000-4000-8000-000000000002").unwrap();
        let first_pane = PaneId::new("40000000-0000-4000-8000-000000000001").unwrap();
        let second_pane = PaneId::new("40000000-0000-4000-8000-000000000002").unwrap();
        let third_pane = PaneId::new("40000000-0000-4000-8000-000000000003").unwrap();
        let identity = |suffix| RootIdentity {
            volume_serial: Hex16::new("0000000000000001").unwrap(),
            file_id: Hex32::new(suffix).unwrap(),
        };
        Snapshot {
            schema_version: Version::new(1).unwrap(),
            generation: U::new(generation).unwrap(),
            topology_revision: U::new(topology).unwrap(),
            projects: vec![
                SavedProject {
                    project_id: second_project.clone(),
                    path: NonEmpty::new("C:\\fixture\\second").unwrap(),
                    display_name: "second".to_owned(),
                    root_identity: identity("00000000000000000000000000000002"),
                },
                SavedProject {
                    project_id: first_project.clone(),
                    path: NonEmpty::new("C:\\fixture\\first").unwrap(),
                    display_name: "first".to_owned(),
                    root_identity: identity("00000000000000000000000000000001"),
                },
            ],
            panes: vec![
                SavedPane {
                    pane_id: third_pane.clone(),
                    project_id: second_project.clone(),
                    shell_profile_id: NonEmpty::new("pwsh").unwrap(),
                    provider_profile: Nullable(None),
                },
                SavedPane {
                    pane_id: second_pane.clone(),
                    project_id: second_project.clone(),
                    shell_profile_id: NonEmpty::new("pwsh").unwrap(),
                    provider_profile: Nullable(None),
                },
                SavedPane {
                    pane_id: first_pane.clone(),
                    project_id: first_project.clone(),
                    shell_profile_id: NonEmpty::new("pwsh").unwrap(),
                    provider_profile: Nullable(None),
                },
            ],
            layouts: vec![
                SavedLayout {
                    project_id: second_project.clone(),
                    root: Nullable(Some(
                        LayoutNode::split(
                            Axis::Vertical,
                            Ratio::new(0.5).unwrap(),
                            LayoutNode::leaf(third_pane),
                            LayoutNode::leaf(second_pane),
                        )
                        .unwrap(),
                    )),
                },
                SavedLayout {
                    project_id: first_project.clone(),
                    root: Nullable(Some(LayoutNode::leaf(first_pane))),
                },
            ],
            selected_project_id: Nullable(Some(second_project)),
            selected_pane_id: Nullable(None),
        }
    }

    fn bytes(snapshot: &Snapshot) -> Vec<u8> {
        serialize_snapshot(snapshot).expect("serialize")
    }

    fn save_once(
        store: &LayoutStore,
        snapshot: &Snapshot,
        authority: &AllocationAuthority,
    ) -> Result<(), ErrorCode> {
        let tx = store.begin(authority, pool())?;
        tx.save(snapshot, authority, pool())
    }

    fn plant(store: &LayoutStore, name: &str, payload: &[u8]) {
        let path = store.v1.join(name);
        let wide = wide_path(&path).expect("plant path");
        let descriptor = PrivateDescriptor::for_user(&store.identity.user).expect("plant acl");
        let sa = descriptor.attributes();
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ,
                &sa,
                CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        let handle = unsafe { OwnedHandle::from_raw(handle) }.expect("plant handle");
        write_all(handle.raw(), payload).expect("plant write");
    }

    fn disk(store: &LayoutStore, name: &str) -> Vec<u8> {
        fs::read(store.v1.join(name)).expect("disk bytes")
    }

    fn open_query_handle(path: &Path) -> OwnedHandle {
        let wide = wide_path(path).expect("query path");
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                null(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        unsafe { OwnedHandle::from_raw(handle) }.expect("query handle")
    }

    fn file_key_path(path: &Path) -> (u32, u64) {
        file_index_key(open_query_handle(path).raw()).expect("file key")
    }

    fn nlinks(path: &Path) -> u32 {
        let handle = open_query_handle(path);
        let mut info = unsafe { std::mem::zeroed::<BY_HANDLE_FILE_INFORMATION>() };
        assert_ne!(
            unsafe { GetFileInformationByHandle(handle.raw(), &mut info) },
            0
        );
        info.nNumberOfLinks
    }

    fn dacl_sddl(path: &Path) -> Option<String> {
        let wide = wide_path(path).ok()?;
        let mut sd = null_mut();
        let err = unsafe {
            GetNamedSecurityInfoW(
                wide.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                &mut sd,
            )
        };
        if err != 0 || sd.is_null() {
            if !sd.is_null() {
                unsafe {
                    LocalFree(sd);
                }
            }
            return None;
        }
        let mut text = null_mut();
        let ok = unsafe {
            ConvertSecurityDescriptorToStringSecurityDescriptorW(
                sd,
                SDDL_REVISION_1,
                DACL_SECURITY_INFORMATION,
                &mut text,
                null_mut(),
            )
        };
        let result = if ok == 0 || text.is_null() {
            None
        } else {
            let mut len = 0usize;
            unsafe {
                while *text.add(len) != 0 {
                    len += 1;
                }
            }
            String::from_utf16(unsafe { std::slice::from_raw_parts(text, len) }).ok()
        };
        if !text.is_null() {
            unsafe {
                LocalFree(text.cast::<c_void>());
            }
        }
        unsafe {
            LocalFree(sd);
        }
        result
    }

    fn force_everyone_dacl(path: &Path) {
        let sddl: Vec<u16> = "D:P(A;;FA;;;WD)"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut sd = null_mut();
        assert_ne!(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut sd,
                    null_mut(),
                )
            },
            0
        );
        let mut present = 0i32;
        let mut defaulted = 0i32;
        let mut dacl = null_mut();
        assert_ne!(
            unsafe { GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaulted) },
            0
        );
        let mut wide = wide_path(path).expect("acl path");
        let err = unsafe {
            SetNamedSecurityInfoW(
                wide.as_mut_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | 0x8000_0000,
                null_mut(),
                null_mut(),
                dacl,
                null_mut(),
            )
        };
        unsafe {
            LocalFree(sd);
        }
        assert_eq!(err, 0);
    }

    fn unprotect_existing_dacl(path: &Path) {
        let mut wide = wide_path(path).expect("dacl path");
        let mut dacl = null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = null_mut();
        let read = unsafe {
            GetNamedSecurityInfoW(
                wide.as_ptr(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                null_mut(), null_mut(), &mut dacl, null_mut(), &mut sd,
            )
        };
        assert_eq!(read, 0);
        assert!(!sd.is_null());
        assert!(!dacl.is_null());
        let write = unsafe {
            SetNamedSecurityInfoW(
                wide.as_mut_ptr(), SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFORMATION,
                null_mut(), null_mut(), dacl, null_mut(),
            )
        };
        unsafe { LocalFree(sd); }
        assert_eq!(write, 0);
    }

    fn assert_user_owned_snapshot(store: &LayoutStore, name: &str) {
        let handle = open_query_handle(&store.v1.join(name));
        assert_eq!(
            snapshot_owner(handle.raw(), &store.identity.user).expect("private snapshot"),
            SnapshotOwner::User,
        );
    }

    fn junction(link: &Path, target: &Path) {
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .status()
            .expect("mklink");
        assert!(status.success());
    }

    #[test]
    fn production_root_is_user_unit_v1() {
        let store = LayoutStore::open_user_unit().expect("known folder");
        assert_eq!(store.v1.file_name().and_then(|n| n.to_str()), Some("v1"));
        assert_eq!(
            store
                .v1
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str()),
            Some("workspace")
        );
        assert_eq!(
            store
                .v1
                .parent()
                .and_then(|p| p.parent())
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str()),
            Some("winsmux")
        );
    }

    #[test]
    fn first_save_observed_absent_does_not_invent_backup() {
        let (_guard, store, authority) = fixture();
        save_once(&store, &empty(1, 1), &authority).expect("first save");
        assert!(store.v1.join(CONFIRMED_NAME).is_file());
        assert!(!store.v1.join(BACKUP_NAME).exists());
        assert_user_owned_snapshot(&store, CONFIRMED_NAME);
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()).expect("read C"),
            empty(1, 1)
        );
    }

    #[test]
    fn leftover_temp_is_ignored_on_first_save() {
        let (_guard, store, authority) = fixture();
        plant(&store, TEMP_NAME, b"torn");
        save_once(&store, &empty(2, 3), &authority).expect("first save ignores T");
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(2, 3)));
        assert!(!store.v1.join(BACKUP_NAME).exists());
    }

    #[test]
    fn later_save_preserves_exact_proved_confirmed_bytes() {
        let (_guard, store, authority) = fixture();
        let first = empty(4, 5);
        let second = empty(6, 7);
        save_once(&store, &first, &authority).expect("first");
        save_once(&store, &second, &authority).expect("later");
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&first));
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&second));
        assert_user_owned_snapshot(&store, BACKUP_NAME);
        assert_user_owned_snapshot(&store, CONFIRMED_NAME);
    }

    #[test]
    fn private_legacy_temp_is_reowned_before_staging_on_same_file() {
        let (_guard, store, authority) = fixture();
        plant(&store, TEMP_NAME, b"legacy-temp");
        let temp_key = file_key_path(&store.v1.join(TEMP_NAME));
        save_once(&store, &empty(8, 9), &authority).expect("save via legacy temp");
        assert_eq!(file_key_path(&store.v1.join(CONFIRMED_NAME)), temp_key);
        assert_user_owned_snapshot(&store, CONFIRMED_NAME);
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(8, 9)));
    }

    #[test]
    fn equal_bytes_legacy_backup_is_refreshed_to_user_owner() {
        let (_guard, store, authority) = fixture();
        let first = empty(10, 11);
        save_once(&store, &first, &authority).expect("first save");
        plant(&store, BACKUP_NAME, &bytes(&first));
        let old_owner = snapshot_owner(
            open_query_handle(&store.v1.join(BACKUP_NAME)).raw(),
            &store.identity.user,
        )
        .expect("private legacy backup");
        let old_key = file_key_path(&store.v1.join(BACKUP_NAME));
        let second = empty(12, 13);
        save_once(&store, &second, &authority).expect("later save");
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&first));
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&second));
        assert_user_owned_snapshot(&store, BACKUP_NAME);
        assert_user_owned_snapshot(&store, CONFIRMED_NAME);
        if old_owner == SnapshotOwner::Administrators {
            assert_ne!(file_key_path(&store.v1.join(BACKUP_NAME)), old_key);
        }
    }

    #[test]
    fn unprotected_snapshot_dacl_fails_before_mutating_existing_bytes() {
        let (_guard, store, authority) = fixture();
        plant(&store, TEMP_NAME, b"keep-temp");
        let temp_key = file_key_path(&store.v1.join(TEMP_NAME));
        unprotect_existing_dacl(&store.v1.join(TEMP_NAME));
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, TEMP_NAME), b"keep-temp");
        assert_eq!(file_key_path(&store.v1.join(TEMP_NAME)), temp_key);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());

        let (_guard, store, authority) = fixture();
        save_once(&store, &empty(2, 2), &authority).expect("first save");
        let c_before = disk(&store, CONFIRMED_NAME);
        let c_key = file_key_path(&store.v1.join(CONFIRMED_NAME));
        unprotect_existing_dacl(&store.v1.join(CONFIRMED_NAME));
        assert_eq!(
            save_once(&store, &empty(3, 3), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), c_before);
        assert_eq!(file_key_path(&store.v1.join(CONFIRMED_NAME)), c_key);
        assert!(!store.v1.join(BACKUP_NAME).exists());

        let (_guard, store, authority) = fixture();
        save_once(&store, &empty(4, 4), &authority).expect("first save");
        plant(&store, BACKUP_NAME, &bytes(&empty(4, 4)));
        let c_before = disk(&store, CONFIRMED_NAME);
        let b_before = disk(&store, BACKUP_NAME);
        let b_key = file_key_path(&store.v1.join(BACKUP_NAME));
        unprotect_existing_dacl(&store.v1.join(BACKUP_NAME));
        assert_eq!(
            save_once(&store, &empty(5, 5), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), c_before);
        assert_eq!(disk(&store, BACKUP_NAME), b_before);
        assert_eq!(file_key_path(&store.v1.join(BACKUP_NAME)), b_key);
    }

    #[test]
    fn canonical_save_sorts_only_top_level_arrays_and_keeps_previous_c_bytes() {
        let (_guard, store, authority) = fixture();
        let first = unordered_layout(4, 5);
        let first_bytes = bytes(&first);
        let canonical_first = parse_snapshot(&first_bytes).expect("canonical C");
        assert_ne!(canonical_first.projects, first.projects);
        assert_ne!(canonical_first.panes, first.panes);
        assert_ne!(canonical_first.layouts, first.layouts);
        assert_eq!(canonical_first.layouts[1].root, first.layouts[0].root);
        assert_eq!(prove_bytes(&first_bytes, Some(&first)), Ok(()));
        assert_eq!(prove_bytes(b"{", Some(&first)), Err(ErrorCode::PersistenceFailed));

        save_once(&store, &first, &authority).expect("unordered first save");
        assert_eq!(disk(&store, CONFIRMED_NAME), first_bytes);
        let second = unordered_layout(6, 7);
        assert_eq!(
            prove_bytes(&first_bytes, Some(&second)),
            Err(ErrorCode::PersistenceFailed)
        );
        save_once(&store, &second, &authority).expect("unordered later save");
        assert_eq!(disk(&store, BACKUP_NAME), first_bytes);
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&second));
    }

    #[test]
    fn unacknowledged_valid_confirmed_is_later_save_baseline() {
        let (_guard, store, authority) = fixture();
        let planted = empty(8, 9);
        let next = empty(10, 11);
        plant(&store, CONFIRMED_NAME, &bytes(&planted));
        save_once(&store, &next, &authority).expect("later from unacked C");
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&planted));
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&next));
    }

    #[test]
    fn save_fails_when_confirmed_absent_and_backup_present() {
        let (_guard, store, authority) = fixture();
        let backup = empty(1, 1);
        plant(&store, BACKUP_NAME, &bytes(&backup));
        let before = disk(&store, BACKUP_NAME);
        assert_eq!(
            save_once(&store, &empty(2, 2), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, BACKUP_NAME), before);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
    }

    #[test]
    fn save_fails_on_corrupt_confirmed_without_touching_backup() {
        let (_guard, store, authority) = fixture();
        let backup = empty(1, 2);
        plant(&store, CONFIRMED_NAME, b"{");
        plant(&store, BACKUP_NAME, &bytes(&backup));
        let before_b = disk(&store, BACKUP_NAME);
        let before_c = disk(&store, CONFIRMED_NAME);
        assert_eq!(
            save_once(&store, &empty(3, 4), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, BACKUP_NAME), before_b);
        assert_eq!(disk(&store, CONFIRMED_NAME), before_c);
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
    }

    #[test]
    fn save_fails_on_unknown_schema_confirmed() {
        let (_guard, store, authority) = fixture();
        let backup = empty(1, 1);
        plant(
            &store,
            CONFIRMED_NAME,
            br#"{"schema_version":2,"generation":0,"topology_revision":0,"projects":[],"panes":[],"layouts":[],"selected_project_id":null,"selected_pane_id":null}"#,
        );
        plant(&store, BACKUP_NAME, &bytes(&backup));
        let before_b = disk(&store, BACKUP_NAME);
        assert_eq!(
            save_once(&store, &empty(2, 2), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, BACKUP_NAME), before_b);
    }

    #[test]
    fn save_fails_on_invariant_invalid_confirmed() {
        let (_guard, store, authority) = fixture();
        plant(
            &store,
            CONFIRMED_NAME,
            br#"{"schema_version":1,"generation":0,"topology_revision":0,"projects":[],"panes":[],"layouts":[],"selected_project_id":null,"selected_pane_id":"40000000-0000-4000-8000-000000000000"}"#,
        );
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert!(!store.v1.join(BACKUP_NAME).exists());
    }

    #[test]
    fn save_fails_on_unreadable_confirmed() {
        let (_guard, store, authority) = fixture();
        fs::create_dir(store.v1.join(CONFIRMED_NAME)).expect("dir as C");
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert!(!store.v1.join(BACKUP_NAME).exists());
        assert!(store.v1.join(CONFIRMED_NAME).is_dir());
    }

    #[test]
    fn save_fails_when_backup_inaccessible() {
        let (_guard, store, authority) = fixture();
        save_once(&store, &empty(1, 1), &authority).expect("first");
        let before = disk(&store, CONFIRMED_NAME);
        fs::create_dir(store.v1.join(BACKUP_NAME)).expect("dir as B");
        assert_eq!(
            save_once(&store, &empty(2, 2), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), before);
        assert!(store.v1.join(BACKUP_NAME).is_dir());
    }

    #[test]
    fn read_confirmed_ignores_valid_backup() {
        let (_guard, store, authority) = fixture();
        plant(&store, BACKUP_NAME, &bytes(&empty(9, 9)));
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
        drop(tx);
        plant(&store, CONFIRMED_NAME, b"not-json");
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&empty(9, 9)));
    }

    #[test]
    fn first_save_temp_faults_leave_confirmed_and_backup_absent() {
        for fault in [
            LayoutStoreFault::TempWrite,
            LayoutStoreFault::TempFlush,
            LayoutStoreFault::TempReadback,
        ] {
            let (_guard, mut store, authority) = fixture();
            store.inject_fault(fault);
            let tx = store.begin(&authority, pool()).expect("lease");
            assert_eq!(
                tx.save(&empty(1, 1), &authority, pool()),
                Err(ErrorCode::PersistenceFailed)
            );
            drop(tx);
            assert!(!store.v1.join(CONFIRMED_NAME).exists());
            assert!(!store.v1.join(BACKUP_NAME).exists());
        }
    }

    #[test]
    fn first_save_replace_fault_does_not_invent_backup() {
        let (_guard, mut store, authority) = fixture();
        store.inject_fault(LayoutStoreFault::ConfirmedReplace);
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.save(&empty(1, 1), &authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
        drop(tx);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        assert!(!store.v1.join(BACKUP_NAME).exists());
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.read_confirmed(&authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
    }

    #[test]
    fn first_save_readback_fault_does_not_delete_confirmed() {
        let (_guard, mut store, authority) = fixture();
        store.inject_fault(LayoutStoreFault::ConfirmedReadback);
        let tx = store.begin(&authority, pool()).expect("lease");
        assert_eq!(
            tx.save(&empty(1, 1), &authority, pool()),
            Err(ErrorCode::PersistenceFailed)
        );
        drop(tx);
        assert!(!store.v1.join(BACKUP_NAME).exists());
        assert!(store.v1.join(CONFIRMED_NAME).is_file());
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(1, 1)));
    }

    #[test]
    fn later_save_backup_faults_leave_confirmed_untouched() {
        for fault in [
            LayoutStoreFault::BackupWrite,
            LayoutStoreFault::BackupFlush,
            LayoutStoreFault::BackupReadback,
            LayoutStoreFault::BackupReplace,
        ] {
            let (_guard, mut store, authority) = fixture();
            let first = empty(1, 1);
            save_once(&store, &first, &authority).expect("first");
            store.inject_fault(fault);
            let tx = store.begin(&authority, pool()).expect("lease");
            assert_eq!(
                tx.save(&empty(2, 2), &authority, pool()),
                Err(ErrorCode::PersistenceFailed)
            );
            drop(tx);
            assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&first));
            assert!(!store.v1.join(BACKUP_NAME).is_file() || disk(&store, BACKUP_NAME) == bytes(&first));
        }
    }

    #[test]
    fn later_save_temp_fault_leaves_confirmed_and_backup_untouched() {
        let (_guard, mut store, authority) = fixture();
        let first = empty(3, 4);
        save_once(&store, &first, &authority).expect("first");
        plant(&store, BACKUP_NAME, &bytes(&first));
        store.inject_fault(LayoutStoreFault::TempFlush);
        assert_eq!(
            save_once(&store, &empty(5, 6), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&first));
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&first));
    }

    #[test]
    fn later_save_replace_fault_keeps_backup_proved_bytes() {
        let (_guard, mut store, authority) = fixture();
        let first = empty(7, 8);
        save_once(&store, &first, &authority).expect("first");
        store.inject_fault(LayoutStoreFault::ConfirmedReplace);
        assert_eq!(
            save_once(&store, &empty(9, 10), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&first));
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&first));
    }

    #[test]
    fn later_save_readback_fault_keeps_backup_and_does_not_delete_confirmed() {
        let (_guard, mut store, authority) = fixture();
        let first = empty(11, 12);
        let second = empty(13, 14);
        save_once(&store, &first, &authority).expect("first");
        store.inject_fault(LayoutStoreFault::ConfirmedReadback);
        assert_eq!(
            save_once(&store, &second, &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, BACKUP_NAME), bytes(&first));
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&second));
    }

    #[test]
    fn lease_contention_and_stable_lock_identity() {
        let (_guard, store, authority) = fixture();
        let tx1 = store.begin(&authority, pool()).expect("holder");
        let store2 = LayoutStore::open_isolated(&store.v1).expect("second open");
        assert_eq!(
            store2.begin(&authority, pool()).err(),
            Some(ErrorCode::PersistenceFailed)
        );
        tx1.save(&empty(1, 1), &authority, pool()).expect("holder save");
        let identity = tx1.lease_key().expect("lease key");
        let lease = store.v1.join(LEASE_NAME);
        drop(tx1);
        assert!(lease.is_file());
        let tx2 = store2.begin(&authority, pool()).expect("reacquire");
        assert_eq!(tx2.lease_key().expect("lease key after"), identity);
        drop(tx2);
        assert!(lease.is_file());
    }

    #[test]
    fn ordinary_ancestor_permissions_allow_save() {
        let (_guard, store, authority) = fixture();
        let parent = store.v1.parent().expect("parent").to_path_buf();
        let parent_before = dacl_sddl(&parent);
        let drive = parent.to_str().and_then(|s| s.chars().next()).map(|letter| {
            PathBuf::from(format!("{}:\\", letter))
        });
        let drive_before = drive.as_ref().and_then(|path| dacl_sddl(path));
        save_once(&store, &empty(1, 1), &authority).expect("save with ordinary ancestors");
        if let (Some(before), Some(after)) = (parent_before, dacl_sddl(&parent)) {
            assert_eq!(before, after);
        }
        if let (Some(path), Some(before)) = (drive.as_ref(), drive_before) {
            if let Some(after) = dacl_sddl(path) {
                assert_eq!(before, after);
            }
        }
    }

    #[test]
    fn store_reparse_root_is_rejected() {
        let (_guard_target, target) = unique_root();
        let (_guard_link, link_parent) = unique_root();
        let link = link_parent.join("j");
        junction(&link, &target);
        let opened = LayoutStore::open_isolated(&link);
        let _ = fs::remove_dir(&link);
        assert!(opened.is_err());
    }

    #[test]
    fn store_other_end_user_acl_is_rejected() {
        let (_guard, store, authority) = fixture();
        force_everyone_dacl(&store.v1);
        assert_eq!(
            store.begin(&authority, pool()).err(),
            Some(ErrorCode::PersistenceFailed)
        );
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
    }

    #[test]
    fn held_directory_allows_child_writes_and_refuses_rename() {
        let (_guard, store, authority) = fixture();
        let tx = store.begin(&authority, pool()).expect("held v1");
        fs::write(store.v1.join("child-ok.txt"), b"ok").expect("child write");
        let moved = store.v1.with_file_name(format!(
            "{}-moved",
            store.v1.file_name().and_then(|n| n.to_str()).expect("name")
        ));
        assert!(fs::rename(&store.v1, &moved).is_err());
        tx.save(&empty(1, 1), &authority, pool())
            .expect("save under held directory");
    }

    #[test]
    fn reject_ancestor_junction_before_child_creation() {
        let (_guard_target, target) = unique_root();
        let (_guard_link, link_parent) = unique_root();
        let junction_path = link_parent.join("junc");
        junction(&junction_path, &target);
        let child = junction_path.join("v1");
        assert!(!child.exists());
        let opened = LayoutStore::open_isolated(&child);
        assert!(opened.is_err());
        assert!(!child.exists());
        let _ = fs::remove_dir(&junction_path);
    }

    #[test]
    fn guards_hold_through_child_creation() {
        let (_guard, store, authority) = fixture();
        let parent = store.v1.parent().expect("parent").to_path_buf();
        let moved = parent.with_file_name(format!(
            "{}-moved",
            parent.file_name().and_then(|n| n.to_str()).expect("parent name")
        ));
        assert!(fs::rename(&parent, &moved).is_err());
        fs::write(parent.join("sibling-ok.txt"), b"ok").expect("sibling write under held parent");
        fs::write(store.v1.join("child-ok.txt"), b"ok").expect("child write under held v1");
        save_once(&store, &empty(1, 1), &authority).expect("save while ancestor guards live");
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(1, 1)));
        assert!(fs::rename(&parent, &moved).is_err());
    }

    #[test]
    fn reject_hardlinked_temp_before_mutation() {
        let (_guard, mut store, authority) = fixture();
        allow_invalid_leaf_setup(&mut store);
        plant(&store, "victim.dat", b"hl-temp-victim");
        fs::hard_link(store.v1.join("victim.dat"), store.v1.join(TEMP_NAME)).expect("temp hardlink");
        let before = disk(&store, "victim.dat");
        let key = file_key_path(&store.v1.join("victim.dat"));
        assert!(nlinks(&store.v1.join(TEMP_NAME)) >= 2);
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, "victim.dat"), before);
        assert_eq!(disk(&store, TEMP_NAME), before);
        assert_eq!(file_key_path(&store.v1.join("victim.dat")), key);
        assert!(nlinks(&store.v1.join(TEMP_NAME)) >= 2);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        assert!(!store.v1.join(BACKUP_NAME).exists());
    }

    #[test]
    fn reject_private_acl_temp_before_mutation() {
        let (_guard, store, authority) = fixture();
        plant(&store, TEMP_NAME, b"acl-temp-bytes");
        let before = disk(&store, TEMP_NAME);
        let key = file_key_path(&store.v1.join(TEMP_NAME));
        force_everyone_dacl(&store.v1.join(TEMP_NAME));
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, TEMP_NAME), before);
        assert_eq!(file_key_path(&store.v1.join(TEMP_NAME)), key);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        assert!(!store.v1.join(BACKUP_NAME).exists());
    }

    #[test]
    fn reject_hardlinked_c_b_lease_without_writes() {
        let (_guard, mut store, authority) = fixture();
        allow_invalid_leaf_setup(&mut store);
        plant(&store, "lease-victim.dat", b"lease-victim-bytes");
        fs::hard_link(store.v1.join("lease-victim.dat"), store.v1.join(LEASE_NAME))
            .expect("lease hardlink");
        let lease_before = disk(&store, "lease-victim.dat");
        let lease_key = file_key_path(&store.v1.join("lease-victim.dat"));
        assert!(nlinks(&store.v1.join(LEASE_NAME)) >= 2);
        assert_eq!(
            store.begin(&authority, pool()).err(),
            Some(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, "lease-victim.dat"), lease_before);
        assert_eq!(file_key_path(&store.v1.join("lease-victim.dat")), lease_key);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());

        let (_guard, mut store, authority) = fixture();
        allow_invalid_leaf_setup(&mut store);
        plant(&store, "c-victim.dat", b"c-victim-bytes");
        fs::hard_link(store.v1.join("c-victim.dat"), store.v1.join(CONFIRMED_NAME))
            .expect("C hardlink");
        let c_before = disk(&store, "c-victim.dat");
        let c_key = file_key_path(&store.v1.join("c-victim.dat"));
        assert!(nlinks(&store.v1.join(CONFIRMED_NAME)) >= 2);
        assert_eq!(
            save_once(&store, &empty(2, 2), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, "c-victim.dat"), c_before);
        assert_eq!(disk(&store, CONFIRMED_NAME), c_before);
        assert_eq!(file_key_path(&store.v1.join("c-victim.dat")), c_key);
        assert!(!store.v1.join(BACKUP_NAME).exists());

        let (_guard, mut store, authority) = fixture();
        let first = empty(3, 3);
        save_once(&store, &first, &authority).expect("first C");
        let confirmed_before = disk(&store, CONFIRMED_NAME);
        allow_invalid_leaf_setup(&mut store);
        plant(&store, "b-victim.dat", b"b-victim-bytes");
        fs::hard_link(store.v1.join("b-victim.dat"), store.v1.join(BACKUP_NAME))
            .expect("B hardlink");
        let b_before = disk(&store, "b-victim.dat");
        let b_key = file_key_path(&store.v1.join("b-victim.dat"));
        assert!(nlinks(&store.v1.join(BACKUP_NAME)) >= 2);
        assert_eq!(
            save_once(&store, &empty(4, 4), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(disk(&store, CONFIRMED_NAME), confirmed_before);
        assert_eq!(disk(&store, "b-victim.dat"), b_before);
        assert_eq!(disk(&store, BACKUP_NAME), b_before);
        assert_eq!(file_key_path(&store.v1.join("b-victim.dat")), b_key);
    }

    #[test]
    fn failed_temp_acquisition_preserves_existing_entry() {
        let (_guard, store, authority) = fixture();
        let temp = store.v1.join(TEMP_NAME);
        fs::create_dir(&temp).expect("temp dir");
        let nested = temp.join("nested-victim.bin");
        fs::write(&nested, b"nested-keep").expect("nested victim");
        assert_eq!(
            save_once(&store, &empty(1, 1), &authority),
            Err(ErrorCode::PersistenceFailed)
        );
        assert!(temp.is_dir());
        assert_eq!(fs::read(&nested).expect("nested after"), b"nested-keep");
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        assert!(!store.v1.join(BACKUP_NAME).exists());
    }

    #[test]
    fn fixture_collision_retains_existing_bytes() {
        let (_owned, root) = unique_root();
        let victim = root.join("victim.txt");
        fs::write(&victim, b"retain-these-bytes").expect("victim");
        let before = fs::read(&victim).expect("before");
        let key = file_key_path(&victim);
        assert_eq!(
            exclusive_create_directory(&root),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(fs::read(&victim).expect("after"), before);
        assert_eq!(before, b"retain-these-bytes");
        assert_eq!(file_key_path(&victim), key);
    }
    #[test]
    fn acquired_directory_handle_reads_dacl_on_local_fixed_volume() {
        let (_guard, store, authority) = fixture();
        admit_existing_supported_volume(&store.v1).expect("local fixed volume");
        let handle = open_directory(&store.v1)
            .expect("open held v1")
            .expect("v1 present");
        let mut dacl = null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = null_mut();
        let err = unsafe {
            GetSecurityInfo(
                handle.raw(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut sd,
            )
        };
        assert_eq!(err, 0);
        assert!(!sd.is_null());
        assert!(!dacl.is_null());
        if !sd.is_null() {
            unsafe {
                LocalFree(sd);
            }
        }
        check_private_acl_handle(handle.raw(), &store.identity.user).expect("private v1 dacl");
        save_once(&store, &empty(1, 1), &authority).expect("save with acl-capable handles");
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(1, 1)));
    }

    #[test]
    fn acquired_ancestor_handle_reads_acl_without_rewriting() {
        let (_guard, store, _authority) = fixture();
        let parent = store.v1.parent().expect("parent").to_path_buf();
        let sibling = parent.join("sibling-dir");
        exclusive_create_directory(&sibling).expect("sibling");
        let before_parent = dacl_sddl(&parent).expect("parent dacl before");
        let before_sibling = dacl_sddl(&sibling).expect("sibling dacl before");
        let parent_handle = open_directory(&parent)
            .expect("open parent")
            .expect("parent present");
        let sibling_handle = open_directory(&sibling)
            .expect("open sibling")
            .expect("sibling present");
        let mut dacl = null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = null_mut();
        let parent_err = unsafe {
            GetSecurityInfo(
                parent_handle.raw(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut sd,
            )
        };
        assert_eq!(parent_err, 0);
        assert!(!dacl.is_null());
        if !sd.is_null() {
            unsafe {
                LocalFree(sd);
            }
        }
        dacl = null_mut();
        sd = null_mut();
        let sibling_err = unsafe {
            GetSecurityInfo(
                sibling_handle.raw(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut sd,
            )
        };
        assert_eq!(sibling_err, 0);
        assert!(!dacl.is_null());
        if !sd.is_null() {
            unsafe {
                LocalFree(sd);
            }
        }
        assert_eq!(
            before_parent,
            dacl_sddl(&parent).expect("parent dacl after")
        );
        assert_eq!(
            before_sibling,
            dacl_sddl(&sibling).expect("sibling dacl after")
        );
    }

    #[test]
    fn reject_unsupported_syntax_before_first_directory_mutation() {
        let (_owned, root) = unique_root();
        let marker = root.join("keep.bin");
        fs::write(&marker, b"keep-bytes").expect("marker");
        let identity = Identity::current().expect("identity");

        let trailing_dot = root.join("v1.");
        assert!(!trailing_dot.exists());
        assert!(classify_path_syntax(path_str(&trailing_dot).expect("trailing-dot text")).is_err());
        assert_eq!(
            DirectoryChain::acquire(&trailing_dot, &identity.user, true)
                .err()
                .expect("trailing-dot acquire"),
            ErrorCode::PersistenceFailed
        );
        assert!(!trailing_dot.exists());
        assert_eq!(
            LayoutStore::open_isolated(&trailing_dot)
                .err()
                .expect("trailing-dot isolated"),
            ErrorCode::PersistenceFailed
        );
        assert!(!trailing_dot.exists());

        let dotted = root.join(".").join("v1");
        assert!(classify_path_syntax(path_str(&dotted).expect("dot-component text")).is_err());
        assert_eq!(
            DirectoryChain::acquire(&dotted, &identity.user, true)
                .err()
                .expect("dot-component acquire"),
            ErrorCode::PersistenceFailed
        );
        assert!(!root.join("v1").exists());

        let up = root.join("..").join(format!(
            "winsmux-task866-syntax-{}-v1",
            std::process::id()
        ));
        assert!(classify_path_syntax(path_str(&up).expect("dotdot-component text")).is_err());
        assert_eq!(
            DirectoryChain::acquire(&up, &identity.user, true)
                .err()
                .expect("dotdot-component acquire"),
            ErrorCode::PersistenceFailed
        );

        assert_eq!(fs::read(&marker).expect("marker after"), b"keep-bytes");
        assert!(root.is_dir());
    }

    #[test]
    fn reject_non_fixed_volume_before_first_directory_mutation() {
        let (_owned, safe) = unique_root();
        let marker = safe.join("keep.bin");
        fs::write(&marker, b"keep-bytes").expect("marker");
        let safe_text = path_str(&safe).expect("safe path");
        let safe_letter = safe_text.as_bytes()[0].to_ascii_uppercase();
        let identity = Identity::current().expect("identity");
        let mut candidate = None;
        for letter in b'A'..=b'Z' {
            if letter == safe_letter {
                continue;
            }
            let mut root_path: Vec<u16> = format!("{}:\\", letter as char)
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let drive_type = unsafe { GetDriveTypeW(root_path.as_mut_ptr()) };
            let mut device: Vec<u16> = format!("{}:", letter as char)
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let mut target = vec![0u16; 1024];
            let written = unsafe {
                QueryDosDeviceW(device.as_mut_ptr(), target.as_mut_ptr(), target.len() as u32)
            };
            let subst = if written == 0 {
                false
            } else {
                let end = target
                    .iter()
                    .position(|unit| *unit == 0)
                    .unwrap_or(target.len());
                String::from_utf16(&target[..end])
                    .ok()
                    .is_some_and(|text| dos_device_target_is_subst(&text))
            };
            if drive_type != DRIVE_FIXED || subst {
                candidate = Some(letter);
                break;
            }
        }
        let letter = candidate.expect("non-fixed or subst volume");
        let parent = PathBuf::from(format!(
            "{}:\\winsmux-task866-vol-{}-reject",
            letter as char,
            std::process::id()
        ));
        let v1 = parent.join("v1");
        let parent_before = parent.exists();
        let v1_before = v1.exists();
        assert_eq!(
            DirectoryChain::acquire(&v1, &identity.user, true)
                .err()
                .expect("non-fixed acquire"),
            ErrorCode::PersistenceFailed
        );
        assert_eq!(
            LayoutStore::open_isolated(&v1)
                .err()
                .expect("non-fixed isolated"),
            ErrorCode::PersistenceFailed
        );
        if !parent_before {
            assert!(!parent.exists());
        }
        if !v1_before {
            assert!(!v1.exists());
        }
        assert_eq!(fs::read(&marker).expect("marker after"), b"keep-bytes");
    }

    #[test]
    fn dos_device_target_prefix_discriminates_nt_and_volume_device_strings() {
        let subst_target = String::from_utf16(&[
            b'\\' as u16,
            b'?' as u16,
            b'?' as u16,
            b'\\' as u16,
            b'C' as u16,
            b':' as u16,
            b'\\' as u16,
            b'm' as u16,
        ])
        .expect("nt dos device");
        let volume_device = String::from_utf16(&[
            b'\\' as u16,
            b'D' as u16,
            b'e' as u16,
            b'v' as u16,
            b'i' as u16,
            b'c' as u16,
            b'e' as u16,
            b'\\' as u16,
            b'H' as u16,
            b'a' as u16,
            b'r' as u16,
            b'd' as u16,
            b'd' as u16,
            b'i' as u16,
            b's' as u16,
            b'k' as u16,
            b'V' as u16,
            b'o' as u16,
            b'l' as u16,
            b'u' as u16,
            b'm' as u16,
            b'e' as u16,
            b'1' as u16,
        ])
        .expect("volume device");
        assert!(dos_device_target_is_subst(&subst_target));
        assert!(!dos_device_target_is_subst(&volume_device));
        assert!(dos_device_target_is_subst("\\??\\C:\\mapped-target"));
        assert!(!dos_device_target_is_subst("\\Device\\HarddiskVolume1"));
    }

    #[test]
    fn same_handle_complete_reads_rewind_including_empty() {
        let (_guard, store, authority) = fixture();
        let tx = store.begin(&authority, pool()).expect("lease");
        let payload = bytes(&empty(21, 21));
        let file = tx
            ._chain
            .acquire_writable(TEMP_NAME, &store.identity.user)
            .expect("temp");
        file.replace_contents(&payload).expect("write");
        file.flush().expect("flush");
        file.readback_equals(&payload, &authority, pool())
            .expect("readback");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("after readback"),
            payload
        );
        assert_eq!(
            read_file_bytes(file.raw(), &authority, pool()).expect("direct repeat"),
            payload
        );
        file.replace_contents(b"").expect("empty");
        file.flush().expect("empty flush");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("empty first"),
            b""
        );
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("empty second"),
            b""
        );
    }

    fn held_parent_move_denied(store: &LayoutStore) -> PathBuf {
        let moved = store.v1.with_file_name(format!(
            "{}-moved",
            store.v1.file_name().and_then(|n| n.to_str()).expect("name")
        ));
        assert!(fs::rename(&store.v1, &moved).is_err());
        moved
    }

    fn stage_temp_payload(
        tx: &LayoutTransaction,
        payload: &[u8],
        authority: &AllocationAuthority,
    ) -> ManagedFile {
        let file = tx
            ._chain
            .acquire_writable(TEMP_NAME, &tx.identity.user)
            .expect("temp");
        file.replace_contents(payload).expect("write");
        file.flush().expect("flush");
        file.readback_equals(payload, authority, pool())
            .expect("readback");
        file
    }

    #[test]
    fn native_rename_create_replace_c_and_b_under_live_guards() {
        let (_guard, store, authority) = fixture();
        let tx = store.begin(&authority, pool()).expect("lease");
        let moved = held_parent_move_denied(&store);
        let created_c = bytes(&empty(31, 1));
        let replaced_c = bytes(&empty(32, 2));
        let created_b = bytes(&empty(33, 3));
        let replaced_b = bytes(&empty(34, 4));

        let file = stage_temp_payload(&tx, &created_c, &authority);
        let key_c = file_index_key(file.raw()).expect("key C create");
        rename_held(file.raw(), CONFIRMED_NAME, false).expect("create C");
        file.prove_after_rename(&store.identity.user)
            .expect("prove C create");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("read C create"),
            created_c
        );
        assert_eq!(file_index_key(file.raw()).expect("key C create after"), key_c);
        assert!(!store.v1.join(TEMP_NAME).exists());
        drop(file);
        assert_eq!(disk(&store, CONFIRMED_NAME), created_c);
        assert_eq!(file_key_path(&store.v1.join(CONFIRMED_NAME)), key_c);
        assert_eq!(nlinks(&store.v1.join(CONFIRMED_NAME)), 1);
        assert!(fs::rename(&store.v1, &moved).is_err());

        let file = stage_temp_payload(&tx, &replaced_c, &authority);
        let key_c2 = file_index_key(file.raw()).expect("key C replace");
        file.rename_replace(CONFIRMED_NAME).expect("replace C leaf");
        file.prove_after_rename(&store.identity.user)
            .expect("prove C replace");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("read C replace"),
            replaced_c
        );
        assert_eq!(
            file_index_key(file.raw()).expect("key C replace after"),
            key_c2
        );
        assert!(!store.v1.join(TEMP_NAME).exists());
        drop(file);
        assert_eq!(disk(&store, CONFIRMED_NAME), replaced_c);
        assert_eq!(file_key_path(&store.v1.join(CONFIRMED_NAME)), key_c2);
        assert_eq!(nlinks(&store.v1.join(CONFIRMED_NAME)), 1);

        let file = stage_temp_payload(&tx, &created_b, &authority);
        let key_b = file_index_key(file.raw()).expect("key B create");
        rename_held(file.raw(), BACKUP_NAME, false).expect("create B");
        file.prove_after_rename(&store.identity.user)
            .expect("prove B create");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("read B create"),
            created_b
        );
        assert_eq!(file_index_key(file.raw()).expect("key B create after"), key_b);
        assert!(!store.v1.join(TEMP_NAME).exists());
        drop(file);
        assert_eq!(disk(&store, BACKUP_NAME), created_b);
        assert_eq!(disk(&store, CONFIRMED_NAME), replaced_c);
        assert_eq!(file_key_path(&store.v1.join(BACKUP_NAME)), key_b);
        assert_eq!(nlinks(&store.v1.join(BACKUP_NAME)), 1);

        let file = stage_temp_payload(&tx, &replaced_b, &authority);
        let key_b2 = file_index_key(file.raw()).expect("key B replace");
        file.rename_replace(BACKUP_NAME).expect("replace B leaf");
        file.prove_after_rename(&store.identity.user)
            .expect("prove B replace");
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("read B replace"),
            replaced_b
        );
        assert_eq!(
            file_index_key(file.raw()).expect("key B replace after"),
            key_b2
        );
        assert!(!store.v1.join(TEMP_NAME).exists());
        drop(file);
        assert_eq!(disk(&store, BACKUP_NAME), replaced_b);
        assert_eq!(disk(&store, CONFIRMED_NAME), replaced_c);
        assert_eq!(file_key_path(&store.v1.join(BACKUP_NAME)), key_b2);
        assert_eq!(nlinks(&store.v1.join(BACKUP_NAME)), 1);

        assert!(fs::rename(&store.v1, &moved).is_err());
        tx.save(&empty(35, 5), &authority, pool())
            .expect("save under live guards");
        assert!(fs::rename(&store.v1, &moved).is_err());
        assert_eq!(disk(&store, CONFIRMED_NAME), bytes(&empty(35, 5)));
        assert_eq!(disk(&store, BACKUP_NAME), replaced_c);
        assert!(!store.v1.join(TEMP_NAME).exists());
    }

    #[test]
    fn native_rename_rejects_invalid_leaves_without_mutation() {
        let (_guard, store, authority) = fixture();
        let tx = store.begin(&authority, pool()).expect("lease");
        let payload = bytes(&empty(41, 1));
        let file = stage_temp_payload(&tx, &payload, &authority);
        let key = file_index_key(file.raw()).expect("key");
        for leaf in [
            "",
            TEMP_NAME,
            LEASE_NAME,
            "confirmed.json.bak",
            "confirmed.json/..",
            "../confirmed.json",
            "confirmed.json/../backup.json",
            "/confirmed.json",
        ] {
            assert_eq!(
                rename_held(file.raw(), leaf, true),
                Err(ErrorCode::PersistenceFailed)
            );
            assert_eq!(
                file.rename_replace(leaf),
                Err(ErrorCode::PersistenceFailed)
            );
        }
        let abs_text = store
            .v1
            .join(CONFIRMED_NAME)
            .to_str()
            .expect("absolute dest")
            .to_string();
        assert_eq!(
            rename_held(file.raw(), &abs_text, true),
            Err(ErrorCode::PersistenceFailed)
        );
        let slash_abs = format!("{}/{}", store.v1.to_str().expect("v1"), CONFIRMED_NAME);
        assert_eq!(
            rename_held(file.raw(), &slash_abs, true),
            Err(ErrorCode::PersistenceFailed)
        );
        let win_up = format!("..\\{}", CONFIRMED_NAME);
        assert_eq!(
            rename_held(file.raw(), &win_up, true),
            Err(ErrorCode::PersistenceFailed)
        );
        let win_abs = format!(
            "{}\\{}",
            store.v1.to_str().expect("v1"),
            CONFIRMED_NAME
        );
        assert_eq!(
            rename_held(file.raw(), &win_abs, true),
            Err(ErrorCode::PersistenceFailed)
        );
        assert_eq!(file_index_key(file.raw()).expect("key after"), key);
        assert_eq!(
            file.read_bytes(&authority, pool()).expect("payload after"),
            payload
        );
        inspect_ordinary_single_link(file.raw()).expect("single link");
        drop(file);
        assert_eq!(disk(&store, TEMP_NAME), payload);
        assert!(!store.v1.join(CONFIRMED_NAME).exists());
        assert!(!store.v1.join(BACKUP_NAME).exists());
        assert_eq!(nlinks(&store.v1.join(TEMP_NAME)), 1);
    }

}
