//! Private desktop-installer startup verification. Never mutates installed files.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

const PLAN_SCHEMA: &str = "winsmux-desktop-install-plan/v1";
const RECEIPT_SCHEMA: &str = "winsmux-desktop-startup-receipt/v1";
const HOST: &str = "x86_64-pc-windows-msvc";
// The existing desktop public-release observation contract.
const OBSERVATION_MS: u64 = 180_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopInstallError {
    Usage,
    Plan,
    Path,
    Member,
    Actor,
    Isolation,
    Launch,
    Receipt,
    Timeout,
    Cleanup,
}
impl DesktopInstallError {
    pub fn classification(self) -> &'static str {
        match self {
            Self::Usage => "usage",
            Self::Plan => "plan_refused",
            Self::Path => "path_refused",
            Self::Member => "member_unconfirmed",
            Self::Actor => "actor_refused",
            Self::Isolation => "isolation_failed",
            Self::Launch => "launch_failed",
            Self::Receipt => "startup_unconfirmed",
            Self::Timeout => "startup_timeout",
            Self::Cleanup => "probe_exit_unconfirmed",
        }
    }
}
impl std::fmt::Display for DesktopInstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.classification())
    }
}
impl std::error::Error for DesktopInstallError {}

#[derive(Debug, Clone)]
pub struct StartupVerifyRequest {
    pub gui_path: PathBuf,
    pub expected_gui_sha256: [u8; 32],
    pub expected_version: String,
    pub expected_actor_sid: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct StartupReceipt {
    pub schema: String,
    pub operation_id: String,
    pub version: String,
    pub gui_sha256: String,
    pub normal_mount: bool,
    pub native_ready: bool,
    pub actor_verified: bool,
    pub probe_processes_exited: bool,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallMember {
    pub role: String,
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallPlan {
    pub schema: String,
    pub flavor: String,
    pub version: String,
    pub host: String,
    pub files: Vec<InstallMember>,
}
#[derive(Debug, Clone)]
pub struct MsiVerifyArguments {
    pub root: PathBuf,
    pub version: String,
    pub plan_sha256: [u8; 32],
    pub user_sid: String,
}

pub fn parse_sha256(value: &str) -> Result<[u8; 32], DesktopInstallError> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(DesktopInstallError::Plan);
    }
    let mut digest = [0; 32];
    for (i, byte) in digest.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[i * 2..i * 2 + 2], 16)
            .map_err(|_| DesktopInstallError::Plan)?;
    }
    Ok(digest)
}
pub fn sha256_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'+'))
}
fn valid_sid(value: &str) -> bool {
    value.starts_with("S-1-")
        && value[4..]
            .split('-')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}
pub fn parse_msi_arguments(
    arguments: &[String],
) -> Result<MsiVerifyArguments, DesktopInstallError> {
    if arguments.len() != 9 || arguments[0] != "msi-verify" {
        return Err(DesktopInstallError::Usage);
    }
    let mut root = None;
    let mut version = None;
    let mut hash = None;
    let mut sid = None;
    for pair in arguments[1..].chunks_exact(2) {
        if pair[1].is_empty() || pair[1].contains('\0') {
            return Err(DesktopInstallError::Usage);
        }
        match pair[0].as_str() {
            "--root" if root.is_none() => root = Some(PathBuf::from(&pair[1])),
            "--version" if version.is_none() && valid_version(&pair[1]) => {
                version = Some(pair[1].clone())
            }
            "--plan-sha256" if hash.is_none() => {
                hash = Some(parse_sha256(&pair[1]).map_err(|_| DesktopInstallError::Usage)?)
            }
            "--user-sid" if sid.is_none() && valid_sid(&pair[1]) => sid = Some(pair[1].clone()),
            _ => return Err(DesktopInstallError::Usage),
        }
    }
    Ok(MsiVerifyArguments {
        root: root.ok_or(DesktopInstallError::Usage)?,
        version: version.ok_or(DesktopInstallError::Usage)?,
        plan_sha256: hash.ok_or(DesktopInstallError::Usage)?,
        user_sid: sid.ok_or(DesktopInstallError::Usage)?,
    })
}
fn safe_component(value: &str) -> bool {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.ends_with(['.', ' '])
        || value.contains('~')
        || value.chars().any(|c| c < ' ' || "<>:\"/\\|?*".contains(c))
    {
        return false;
    }
    let stem = value
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end()
        .to_uppercase();
    !matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) && !["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"].contains(&stem.as_str())
        && !(stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'0'..=b'9'))
}
pub fn valid_member_path(value: &str) -> bool {
    value.split('/').all(safe_component)
}
pub fn parse_install_plan(
    bytes: &[u8],
    expected: [u8; 32],
    flavor: &str,
    version: &str,
) -> Result<InstallPlan, DesktopInstallError> {
    if <[u8; 32]>::from(Sha256::digest(bytes)) != expected {
        return Err(DesktopInstallError::Plan);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| DesktopInstallError::Plan)?;
    let plan: InstallPlan = serde_json::from_str(text).map_err(|_| DesktopInstallError::Plan)?;
    if plan.schema != PLAN_SCHEMA
        || plan.flavor != flavor
        || !matches!(flavor, "msi" | "nsis")
        || plan.version != version
        || !valid_version(version)
        || plan.host != HOST
    {
        return Err(DesktopInstallError::Plan);
    }
    let mut paths = HashSet::new();
    let mut roles = HashSet::new();
    let mut licenses = 0;
    for row in &plan.files {
        if !valid_member_path(&row.path)
            || !paths.insert(row.path.to_lowercase())
            || parse_sha256(&row.sha256).is_err()
            || row.bytes == 0
        {
            return Err(DesktopInstallError::Plan);
        }
        let fixed = match row.role.as_str() {
            "gui" => Some("winsmux-app.exe"),
            "cli" => Some("winsmux.exe"),
            "mcp" => Some("winsmux-workspace-mcp.exe"),
            "app_lib" if flavor == "msi" => Some("winsmux_app_lib.dll"),
            "license" => None,
            _ => return Err(DesktopInstallError::Plan),
        };
        if let Some(path) = fixed {
            if row.path != path || !roles.insert(row.role.as_str()) {
                return Err(DesktopInstallError::Plan);
            }
        } else {
            if !row.path.starts_with("licenses/") {
                return Err(DesktopInstallError::Plan);
            }
            licenses += 1;
        }
    }
    if licenses == 0 || roles.len() != if flavor == "msi" { 4 } else { 3 } {
        return Err(DesktopInstallError::Plan);
    }
    Ok(plan)
}
fn parse_wire_receipt(
    bytes: &[u8],
    operation: &str,
    request: &StartupVerifyRequest,
) -> Result<StartupReceipt, DesktopInstallError> {
    let receipt: StartupReceipt =
        serde_json::from_slice(bytes).map_err(|_| DesktopInstallError::Receipt)?;
    if receipt.schema != RECEIPT_SCHEMA
        || receipt.operation_id != operation
        || receipt.version != request.expected_version
        || receipt.gui_sha256 != sha256_hex(&request.expected_gui_sha256)
        || !receipt.normal_mount
        || !receipt.native_ready
        || !receipt.actor_verified
        || receipt.probe_processes_exited
    {
        return Err(DesktopInstallError::Receipt);
    }
    Ok(receipt)
}

/// Called before legacy CLI cleanup. Failure output is a fixed classification.
pub fn run_internal_desktop_installer(arguments: &[String]) -> i32 {
    if arguments.first().is_some_and(|verb| matches!(verb.as_str(), "nsis-install" | "nsis-uninstall")) {
        return crate::desktop_nsis::run(arguments);
    }
    let result = parse_msi_arguments(arguments).and_then(run_msi_verifier);
    match result {
        Ok(receipt) => match serde_json::to_string(&receipt) {
            Ok(json) => {
                println!("{json}");
                0
            }
            Err(_) => {
                eprintln!("winsmux installer: startup_unconfirmed");
                2
            }
        },
        Err(error) => {
            eprintln!("winsmux installer: {}", error.classification());
            2
        }
    }
}
#[cfg(not(windows))]
fn run_msi_verifier(_: MsiVerifyArguments) -> Result<StartupReceipt, DesktopInstallError> {
    Err(DesktopInstallError::Launch)
}
#[cfg(not(windows))]
pub fn verify_desktop_startup(
    _: StartupVerifyRequest,
) -> Result<StartupReceipt, DesktopInstallError> {
    Err(DesktopInstallError::Launch)
}
#[cfg(windows)]
fn run_msi_verifier(args: MsiVerifyArguments) -> Result<StartupReceipt, DesktopInstallError> {
    native::verify_msi(args)
}
#[cfg(windows)]
pub fn verify_desktop_startup(
    request: StartupVerifyRequest,
) -> Result<StartupReceipt, DesktopInstallError> {
    native::verify_startup(request)
}

#[derive(Debug, Clone)]
pub struct StartupProbeContext {
    pub operation_id: String,
    pub pipe_name: String,
    pub project_dir: PathBuf,
    pub webview_data_dir: PathBuf,
}
impl StartupProbeContext {
    /// Exact private arguments: ordinary launches without a private flag remain ordinary.
    pub fn parse(arguments: &[String]) -> Result<Option<Self>, DesktopInstallError> {
        if !arguments
            .iter()
            .any(|a| a.starts_with("--winsmux-installer-"))
        {
            return Ok(None);
        }
        if arguments.len() != 6 {
            return Err(DesktopInstallError::Usage);
        }
        let mut operation = None;
        let mut pipe = None;
        let mut project = None;
        for pair in arguments.chunks_exact(2) {
            match pair[0].as_str() {
                "--winsmux-installer-probe" if operation.is_none() => {
                    operation = Some(pair[1].clone())
                }
                "--winsmux-installer-pipe" if pipe.is_none() => pipe = Some(pair[1].clone()),
                "--project-dir" if project.is_none() => project = Some(PathBuf::from(&pair[1])),
                _ => return Err(DesktopInstallError::Usage),
            }
        }
        let operation_id = operation.ok_or(DesktopInstallError::Usage)?;
        let id = uuid::Uuid::parse_str(&operation_id).map_err(|_| DesktopInstallError::Usage)?;
        if id.get_version_num() != 4 || id.to_string() != operation_id {
            return Err(DesktopInstallError::Usage);
        }
        let pipe_name = pipe.ok_or(DesktopInstallError::Usage)?;
        if pipe_name != format!(r"\\.\pipe\winsmux-installer-{operation_id}") {
            return Err(DesktopInstallError::Usage);
        }
        let project_dir = project.ok_or(DesktopInstallError::Usage)?;
        let operation_dir = std::env::temp_dir().join(format!("winsmux-installer-{operation_id}"));
        if project_dir != operation_dir.join("project") {
            return Err(DesktopInstallError::Isolation);
        }
        Ok(Some(Self {
            operation_id,
            pipe_name,
            project_dir,
            webview_data_dir: operation_dir.join("webview"),
        }))
    }
    #[cfg(windows)]
    pub fn validate(&self) -> Result<(), DesktopInstallError> {
        native::validate_probe_context(self)
    }
    #[cfg(not(windows))]
    pub fn validate(&self) -> Result<(), DesktopInstallError> {
        Err(DesktopInstallError::Isolation)
    }
    #[cfg(windows)]
    pub fn send(&self, version: &str) -> Result<(), DesktopInstallError> {
        native::send_probe_receipt(self, version)
    }
    #[cfg(not(windows))]
    pub fn send(&self, _: &str) -> Result<(), DesktopInstallError> {
        Err(DesktopInstallError::Receipt)
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::{c_void, OsStr},
        fs::{File, OpenOptions},
        io::Read,
        mem::size_of,
        os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle},
        ptr::{null, null_mut},
        time::{Duration, Instant},
    };
    use windows_sys::Win32::{
        Foundation::{
            CloseHandle, GetLastError, LocalFree, ERROR_NO_DATA, ERROR_NO_TOKEN,
            ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, GENERIC_WRITE, HANDLE,
            INVALID_HANDLE_VALUE, WAIT_OBJECT_0,
        },
        Security::Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
            SDDL_REVISION_1,
        },
        Security::{GetTokenInformation, TokenUser, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER},
        Storage::FileSystem::{
            CreateDirectoryW, CreateFileW, FlushFileBuffers, GetFileInformationByHandle,
            GetFinalPathNameByHandleW, GetLongPathNameW, ReadFile, WriteFile, BY_HANDLE_FILE_INFORMATION,
            FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES, FILE_TRAVERSE,
            FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, PIPE_ACCESS_INBOUND,
        },
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
        System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicAccountingInformation,
            JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
            TerminateJobObject, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        System::Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId,
            GetNamedPipeServerProcessId, PIPE_NOWAIT, PIPE_READMODE_MESSAGE,
            PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE,
        },
        System::Threading::{
            CreateProcessW, GetCurrentProcess, GetCurrentThread, OpenProcessToken, OpenThreadToken,
            QueryFullProcessImageNameW, ResumeThread, TerminateProcess, WaitForSingleObject,
            CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, STARTUPINFOW,
        },
    };
    struct Handle(HANDLE);
    impl Handle {
        fn new(value: HANDLE, error: DesktopInstallError) -> Result<Self, DesktopInstallError> {
            if value.is_null() || value == INVALID_HANDLE_VALUE {
                Err(error)
            } else {
                Ok(Self(value))
            }
        }
    }
    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    struct Security(*mut c_void);
    impl Security {
        fn actor(sid: &str) -> Result<Self, DesktopInstallError> {
            if !valid_sid(sid) {
                return Err(DesktopInstallError::Actor);
            }
            let sddl = wide(OsStr::new(&format!("O:{sid}D:P(A;OICI;FA;;;{sid})")))?;
            let mut descriptor = null_mut();
            if unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    null_mut(),
                )
            } == 0
            {
                return Err(DesktopInstallError::Actor);
            }
            Ok(Self(descriptor))
        }
        fn attributes(&self) -> SECURITY_ATTRIBUTES {
            SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: self.0,
                bInheritHandle: 0,
            }
        }
    }
    impl Drop for Security {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    fn wide(value: &OsStr) -> Result<Vec<u16>, DesktopInstallError> {
        let mut result: Vec<_> = value.encode_wide().collect();
        if result.contains(&0) {
            return Err(DesktopInstallError::Path);
        }
        result.push(0);
        Ok(result)
    }
    fn token_sid(process: HANDLE, effective: bool) -> Result<String, DesktopInstallError> {
        let mut raw = null_mut();
        if effective
            && unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut raw) } == 0
            && unsafe { GetLastError() } != ERROR_NO_TOKEN
        {
            return Err(DesktopInstallError::Actor);
        }
        if raw.is_null() && unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut raw) } == 0 {
            return Err(DesktopInstallError::Actor);
        }
        let token = Handle::new(raw, DesktopInstallError::Actor)?;
        let mut required = 0;
        unsafe {
            GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut required);
        }
        if required == 0 {
            return Err(DesktopInstallError::Actor);
        }
        let mut words = vec![0usize; (required as usize).div_ceil(size_of::<usize>())];
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                words.as_mut_ptr().cast(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(DesktopInstallError::Actor);
        }
        let user = unsafe { &*words.as_ptr().cast::<TOKEN_USER>() };
        let mut text = null_mut();
        if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) } == 0 {
            return Err(DesktopInstallError::Actor);
        }
        let mut count = 0;
        unsafe {
            while *text.add(count) != 0 {
                count += 1;
            }
        }
        let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(text, count) })
            .map_err(|_| DesktopInstallError::Actor);
        unsafe {
            LocalFree(text.cast());
        }
        sid
    }
    fn actor(expected: &str) -> Result<(), DesktopInstallError> {
        if token_sid(unsafe { GetCurrentProcess() }, true)? != expected
            || token_sid(unsafe { GetCurrentProcess() }, false)? != expected
        {
            return Err(DesktopInstallError::Actor);
        }
        Ok(())
    }
    fn info(handle: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION, DesktopInstallError> {
        let mut data = BY_HANDLE_FILE_INFORMATION::default();
        if unsafe { GetFileInformationByHandle(handle, &mut data) } == 0
            || data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            return Err(DesktopInstallError::Path);
        }
        Ok(data)
    }
    fn final_path(handle: HANDLE) -> Result<PathBuf, DesktopInstallError> {
        let n = unsafe { GetFinalPathNameByHandleW(handle, null_mut(), 0, 0) };
        if n == 0 {
            return Err(DesktopInstallError::Path);
        }
        let mut data = vec![0u16; n as usize + 1];
        let written =
            unsafe { GetFinalPathNameByHandleW(handle, data.as_mut_ptr(), data.len() as u32, 0) };
        if written == 0 || written as usize >= data.len() {
            return Err(DesktopInstallError::Path);
        }
        let text =
            String::from_utf16(&data[..written as usize]).map_err(|_| DesktopInstallError::Path)?;
        if !text.starts_with(r"\\?\") || text.starts_with(r"\\?\UNC\") {
            return Err(DesktopInstallError::Path);
        }
        Ok(PathBuf::from(&text[4..]))
    }
    fn same_path(a: &Path, b: &Path) -> bool {
        a.as_os_str()
            .to_string_lossy()
            .replace('/', "\\")
            .trim_end_matches('\\')
            .eq_ignore_ascii_case(
                b.as_os_str()
                    .to_string_lossy()
                    .replace('/', "\\")
                    .trim_end_matches('\\'),
            )
    }
    fn same_file(a: &BY_HANDLE_FILE_INFORMATION, b: &BY_HANDLE_FILE_INFORMATION) -> bool {
        a.dwVolumeSerialNumber == b.dwVolumeSerialNumber
            && a.nFileIndexHigh == b.nFileIndexHigh
            && a.nFileIndexLow == b.nFileIndexLow
    }
    fn strict_absolute(path: &Path) -> Result<(), DesktopInstallError> {
        let text = path
            .to_str()
            .ok_or(DesktopInstallError::Path)?
            .replace('/', "\\");
        let text = if text.len() > 3 {
            text.trim_end_matches('\\')
        } else {
            &text
        };
        let bytes = text.as_bytes();
        if bytes.len() < 3
            || !bytes[0].is_ascii_alphabetic()
            || bytes[1] != b':'
            || bytes[2] != b'\\'
            || (text.len() > 3 && !text[3..].split('\\').all(safe_component))
        {
            return Err(DesktopInstallError::Path);
        }
        Ok(())
    }
    // Hold every ancestor without delete sharing; no junction or DOS alias is accepted.
    struct DirectoryHold {
        handles: Vec<Handle>,
        path: PathBuf,
    }
    impl DirectoryHold {
        fn open(path: &Path) -> Result<Self, DesktopInstallError> {
            strict_absolute(path)?;
            let text = path
                .to_str()
                .ok_or(DesktopInstallError::Path)?
                .replace('/', "\\");
            let text = if text.len() > 3 {
                text.trim_end_matches('\\')
            } else {
                &text
            };
            let mut current = PathBuf::from(&text[..3]);
            let mut handles = Vec::new();
            for component in std::iter::once(None).chain(
                text[3..]
                    .split('\\')
                    .filter(|value| !value.is_empty())
                    .map(Some),
            ) {
                if let Some(component) = component {
                    current.push(component);
                }
                let name = wide(current.as_os_str())?;
                let handle = Handle::new(
                    unsafe {
                        CreateFileW(
                            name.as_ptr(),
                            FILE_READ_ATTRIBUTES | FILE_TRAVERSE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE,
                            null(),
                            OPEN_EXISTING,
                            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                            null_mut(),
                        )
                    },
                    DesktopInstallError::Path,
                )?;
                if info(handle.0)?.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
                    || !same_path(&current, &final_path(handle.0)?)
                {
                    return Err(DesktopInstallError::Path);
                }
                handles.push(handle);
            }
            if handles.is_empty() {
                return Err(DesktopInstallError::Path);
            }
            Ok(Self {
                path: final_path(handles.last().unwrap().0)?,
                handles,
            })
        }
        fn reobserve(&self) -> Result<(), DesktopInstallError> {
            for handle in &self.handles {
                info(handle.0)?;
            }
            if !same_path(&self.path, &final_path(self.handles.last().unwrap().0)?) {
                return Err(DesktopInstallError::Path);
            }
            Ok(())
        }
    }
    struct ImageHold {
        file: File,
        identity: BY_HANDLE_FILE_INFORMATION,
        path: PathBuf,
        digest: [u8; 32],
    }
    impl ImageHold {
        fn open(path: &Path) -> Result<Self, DesktopInstallError> {
            strict_absolute(path)?;
            let file = OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(path)
                .map_err(|_| DesktopInstallError::Member)?;
            let identity = info(file.as_raw_handle())?;
            if identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0
                || identity.nNumberOfLinks != 1
                || !same_path(path, &final_path(file.as_raw_handle())?)
            {
                return Err(DesktopInstallError::Path);
            }
            let mut reader = &file;
            let mut hash = Sha256::new();
            let mut buffer = [0; 65536];
            loop {
                let n = reader
                    .read(&mut buffer)
                    .map_err(|_| DesktopInstallError::Member)?;
                if n == 0 {
                    break;
                }
                hash.update(&buffer[..n]);
            }
            Ok(Self {
                path: final_path(file.as_raw_handle())?,
                file,
                identity,
                digest: hash.finalize().into(),
            })
        }
        fn reobserve(&self) -> Result<(), DesktopInstallError> {
            let now = info(self.file.as_raw_handle())?;
            if !same_file(&self.identity, &now)
                || now.nNumberOfLinks != 1
                || !same_path(&self.path, &final_path(self.file.as_raw_handle())?)
            {
                return Err(DesktopInstallError::Member);
            }
            Ok(())
        }
        fn len(&self) -> u64 {
            ((self.identity.nFileSizeHigh as u64) << 32) | self.identity.nFileSizeLow as u64
        }
    }
    pub(super) fn verify_msi(
        args: MsiVerifyArguments,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        actor(&args.user_sid)?;
        let root = DirectoryHold::open(&args.root)?;
        let plan_path = root.path.join("winsmux.install-plan.json");
        let plan_file = ImageHold::open(&plan_path)?;
        let bytes = std::fs::read(&plan_file.path).map_err(|_| DesktopInstallError::Plan)?;
        let plan = parse_install_plan(&bytes, args.plan_sha256, "msi", &args.version)?;
        let mut directories = Vec::new();
        let mut members = Vec::new();
        let mut gui = None;
        for member in &plan.files {
            let path = root.path.join(&member.path);
            directories.push(DirectoryHold::open(
                path.parent().ok_or(DesktopInstallError::Path)?,
            )?);
            let file = ImageHold::open(&path)?;
            if file.len() != member.bytes || file.digest != parse_sha256(&member.sha256)? {
                return Err(DesktopInstallError::Member);
            }
            if member.role == "gui" {
                gui = Some((file.path.clone(), file.digest));
            }
            members.push(file);
        }
        root.reobserve()?;
        plan_file.reobserve()?;
        for file in &members {
            file.reobserve()?;
        }
        let (gui_path, expected_gui_sha256) = gui.ok_or(DesktopInstallError::Plan)?;
        let receipt = verify_startup(StartupVerifyRequest {
            gui_path,
            expected_gui_sha256,
            expected_version: args.version,
            expected_actor_sid: args.user_sid,
        })?;
        root.reobserve()?;
        for file in &members {
            file.reobserve()?;
        }
        Ok(receipt)
    }
    // Only the internally selected operation-temp producer may expand DOS aliases.
    // Installed roots, plans, members and GUI images still use strict consumers.
    fn operation_temp_input(path: &Path) -> Result<PathBuf, DesktopInstallError> {
        let text = path.to_str().ok_or(DesktopInstallError::Path)?.replace('/', "\\");
        let text = if text.len() > 3 { text.trim_end_matches('\\') } else { &text };
        let bytes = text.as_bytes();
        if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic()
            || bytes[1] != b':' || bytes[2] != b'\\'
            || text.encode_utf16().count() >= 32768
            || (text.len() > 3 && !text[3..].split('\\')
                .all(|part| safe_component(&part.replace('~', "x"))))
        {
            return Err(DesktopInstallError::Path);
        }
        Ok(PathBuf::from(text))
    }
    fn operation_temp_capacity(required: u32) -> Result<usize, DesktopInstallError> {
        if required == 0 || required > 32768 {
            return Err(DesktopInstallError::Path);
        }
        Ok(required as usize)
    }
    fn operation_temp_long_result(
        buffer: &[u16],
        written: u32,
    ) -> Result<PathBuf, DesktopInstallError> {
        if buffer.is_empty() || buffer.len() > 32768
            || written == 0 || written as usize >= buffer.len()
        {
            return Err(DesktopInstallError::Path);
        }
        let text = String::from_utf16(&buffer[..written as usize])
            .map_err(|_| DesktopInstallError::Path)?;
        let path = PathBuf::from(text);
        strict_absolute(&path)?;
        Ok(path)
    }
    fn operation_temp_same_identity(
        before: &BY_HANDLE_FILE_INFORMATION,
        raw_now: &BY_HANDLE_FILE_INFORMATION,
        long_now: &BY_HANDLE_FILE_INFORMATION,
    ) -> bool {
        before.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
            == FILE_ATTRIBUTE_DIRECTORY
            && raw_now.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                == FILE_ATTRIBUTE_DIRECTORY
            && long_now.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                == FILE_ATTRIBUTE_DIRECTORY
            && same_file(before, raw_now)
            && same_file(raw_now, long_now)
    }
    fn operation_temp_parent() -> Result<DirectoryHold, DesktopInstallError> {
        let source = std::env::temp_dir();
        let input = operation_temp_input(&source)?;
        let text = input.to_str().ok_or(DesktopInstallError::Path)?;
        if !text.contains('~') {
            return DirectoryHold::open(&source);
        }

        // Pin every raw ancestor before conversion, so a junction cannot be hidden.
        let mut raw = Vec::new();
        let mut current = PathBuf::from(&text[..3]);
        for component in std::iter::once(None).chain(
            text[3..].split('\\').filter(|part| !part.is_empty()).map(Some),
        ) {
            if let Some(component) = component { current.push(component); }
            let name = wide(current.as_os_str())?;
            let handle = Handle::new(
                unsafe {
                    CreateFileW(
                        name.as_ptr(), FILE_READ_ATTRIBUTES | FILE_TRAVERSE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        null(), OPEN_EXISTING,
                        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null_mut(),
                    )
                },
                DesktopInstallError::Path,
            )?;
            let identity = info(handle.0)?;
            if identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
                return Err(DesktopInstallError::Path);
            }
            raw.push((handle, identity));
        }
        let name = wide(input.as_os_str())?;
        let required = unsafe { GetLongPathNameW(name.as_ptr(), null_mut(), 0) };
        let mut buffer = vec![0u16; operation_temp_capacity(required)?];
        let written = unsafe {
            GetLongPathNameW(name.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32)
        };
        let expanded = operation_temp_long_result(&buffer, written)?;
        let long = DirectoryHold::open(&expanded)?;
        long.reobserve()?;
        if raw.len() != long.handles.len() {
            return Err(DesktopInstallError::Path);
        }
        for ((handle, before), other) in raw.iter().zip(long.handles.iter()) {
            if !operation_temp_same_identity(before, &info(handle.0)?, &info(other.0)?) {
                return Err(DesktopInstallError::Path);
            }
        }
        long.reobserve()?;
        // The long leases overlap all raw leases, then the operation's own ancestor leases.
        Ok(long)
    }

    #[repr(C)]
    struct OperationIoStatus {
        status: isize,
        information: usize,
    }
    #[repr(C)]
    struct OperationUnicodeName {
        length: u16,
        maximum_length: u16,
        buffer: *mut u16,
    }
    #[repr(C)]
    struct OperationObjectAttributes {
        length: u32,
        root: HANDLE,
        name: *mut OperationUnicodeName,
        attributes: u32,
        security: *mut c_void,
        quality: *mut c_void,
    }
    #[link(name = "ntdll")]
    extern "system" {
        fn NtCreateFile(
            file: *mut HANDLE,
            access: u32,
            object: *mut OperationObjectAttributes,
            status: *mut OperationIoStatus,
            allocation: *const i64,
            attributes: u32,
            share: u32,
            disposition: u32,
            options: u32,
            ea: *const c_void,
            ea_length: u32,
        ) -> i32;
    }
    fn operation_leaf(name: &OsStr) -> Result<Vec<u16>, DesktopInstallError> {
        let text = name.to_str().ok_or(DesktopInstallError::Cleanup)?;
        if text.is_empty() || matches!(text, "." | "..")
            || text.chars().any(|c| matches!(c, '\0' | '/' | '\\' | ':'))
        {
            return Err(DesktopInstallError::Cleanup);
        }
        wide(name).map_err(|_| DesktopInstallError::Cleanup)
    }
    // Exact parent-relative NT transport; Win32 BACKUP_SEMANTICS is not an NT option.
    fn operation_relative_handle(
        parent: HANDLE,
        leaf: &OsStr,
        access: u32,
        share: u32,
        disposition: u32,
        options: u32,
        security: *mut c_void,
    ) -> Result<Handle, i32> {
        let mut name = operation_leaf(leaf).map_err(|_| 0i32)?;
        let length = (name.len() - 1).checked_mul(2).ok_or(0i32)?;
        let mut unicode = OperationUnicodeName {
            length: length.try_into().map_err(|_| 0i32)?,
            maximum_length: (length + 2).try_into().map_err(|_| 0i32)?,
            buffer: name.as_mut_ptr(),
        };
        let mut object = OperationObjectAttributes {
            length: size_of::<OperationObjectAttributes>() as u32,
            root: parent,
            name: &mut unicode,
            attributes: 0x40,
            security,
            quality: null_mut(),
        };
        let mut status = OperationIoStatus { status: 0, information: 0 };
        let mut raw = null_mut();
        let result = unsafe {
            NtCreateFile(&mut raw, access, &mut object, &mut status, null(),
                if options & 1 != 0 { FILE_ATTRIBUTE_DIRECTORY } else { 0 },
                share, disposition, options, null(), 0)
        };
        // FILE_CREATE must report FILE_CREATED; FILE_OPEN must report FILE_OPENED.
        let expected = if disposition == 2 { 2 } else { 1 };
        let handle = Handle::new(raw, DesktopInstallError::Cleanup).map_err(|_| result)?;
        if result != 0 || status.information != expected {
            return Err(result);
        }
        Ok(handle)
    }
    fn operation_create_root(
        parent: &DirectoryHold,
        leaf: &OsStr,
        security: &Security,
    ) -> Result<(Handle, BY_HANDLE_FILE_INFORMATION), DesktopInstallError> {
        parent.reobserve()?;
        let attributes = security.attributes();
        let handle = operation_relative_handle(
            parent.handles.last().ok_or(DesktopInstallError::Isolation)?.0,
            leaf, FILE_READ_ATTRIBUTES | FILE_TRAVERSE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, 2,
            0x00000001 | 0x00200000, attributes.lpSecurityDescriptor,
        ).map_err(|_| DesktopInstallError::Isolation)?;
        let identity = info(handle.0)?;
        if identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            || !same_path(&parent.path.join(leaf), &final_path(handle.0)?)
        {
            return Err(DesktopInstallError::Isolation);
        }
        parent.reobserve()?;
        Ok((handle, identity))
    }
    struct OperationCleanupNode {
        handle: Handle,
        path: PathBuf,
        identity: BY_HANDLE_FILE_INFORMATION,
        directory: bool,
    }
    impl OperationCleanupNode {
        fn open(
            parent: HANDLE,
            parent_path: &Path,
            leaf: &OsStr,
            directory: bool,
        ) -> Result<Self, DesktopInstallError> {
            operation_leaf(leaf)?;
            let path = parent_path.join(leaf);
            let access = 0x00010000 | FILE_READ_ATTRIBUTES | 0x00100000
                | if directory { FILE_TRAVERSE } else { 0 };
            let options = 0x00200000 | 0x00000020
                | if directory { 0x00000001 } else { 0x00000040 };
            let handle = operation_relative_handle(
                parent, leaf, access, FILE_SHARE_READ, 1, options, null_mut(),
            ).map_err(|_| DesktopInstallError::Cleanup)?;
            let identity = info(handle.0).map_err(|_| DesktopInstallError::Cleanup)?;
            if (identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory
                || !same_path(&path, &final_path(handle.0).map_err(|_| DesktopInstallError::Cleanup)?)
            {
                return Err(DesktopInstallError::Cleanup);
            }
            Ok(Self { handle, path, identity, directory })
        }
        fn reobserve(&self) -> Result<(), DesktopInstallError> {
            let now = info(self.handle.0).map_err(|_| DesktopInstallError::Cleanup)?;
            if !same_file(&self.identity, &now)
                || (now.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != self.directory
                || !same_path(&self.path, &final_path(self.handle.0).map_err(|_| DesktopInstallError::Cleanup)?)
            {
                return Err(DesktopInstallError::Cleanup);
            }
            Ok(())
        }
        fn delete(self) -> Result<(), DesktopInstallError> {
            self.reobserve()?;
            let flag = windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO {
                DeleteFile: true,
            };
            if unsafe {
                windows_sys::Win32::Storage::FileSystem::SetFileInformationByHandle(
                    self.handle.0, windows_sys::Win32::Storage::FileSystem::FileDispositionInfo,
                    (&flag as *const windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO).cast(),
                    size_of::<windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO>() as u32,
                )
            } == 0 {
                return Err(DesktopInstallError::Cleanup);
            }
            Ok(())
        }
    }

    struct ProbeProfilePaths {
        home: PathBuf,
        app_data: PathBuf,
        local: PathBuf,
        roaming: PathBuf,
    }
    fn probe_profile_paths(operation: &Path) -> ProbeProfilePaths {
        let home = operation.join("profile");
        let app_data = home.join("AppData");
        ProbeProfilePaths {
            home,
            local: app_data.join("Local"),
            roaming: app_data.join("Roaming"),
            app_data,
        }
    }

    struct OperationDirectory {
        path: PathBuf,
        hold: Option<DirectoryHold>,
        identity: BY_HANDLE_FILE_INFORMATION,
        terminal: bool,
    }
    impl OperationDirectory {
        fn create(id: &str, sid: &str) -> Result<Self, DesktopInstallError> {
            let parent = operation_temp_parent()?;
            let path = parent.path.join(format!("winsmux-installer-{id}"));
            let security = Security::actor(sid)?;
            let attributes = security.attributes();
            let (created, identity) = operation_create_root(
                &parent, path.file_name().ok_or(DesktopInstallError::Isolation)?, &security,
            )?;
            let hold = DirectoryHold::open(&path)?;
            if !same_file(&identity, &info(created.0)?)
                || !same_file(&identity, &info(hold.handles.last().unwrap().0)?)
                || !same_path(&path, &final_path(created.0)?)
            {
                return Err(DesktopInstallError::Isolation);
            }
            parent.reobserve()?;
            hold.reobserve()?;
            drop(created);
            let mut result = Self {
                path,
                hold: Some(hold),
                identity,
                terminal: true,
            };
            let profile = probe_profile_paths(&result.path);
            for child in [
                result.path.join("project"), result.path.join("webview"),
                profile.home, profile.app_data, profile.local, profile.roaming,
            ] {
                let name = wide(child.as_os_str())?;
                if unsafe { CreateDirectoryW(name.as_ptr(), &attributes) } == 0 {
                    return Err(DesktopInstallError::Isolation);
                }
            }
            let mut options = git2::RepositoryInitOptions::new();
            options
                .external_template(false)
                .no_reinit(true)
                .initial_head("main");
            git2::Repository::init_opts(result.path.join("project"), &options)
                .map_err(|_| DesktopInstallError::Isolation)?;
            result.hold.as_ref().unwrap().reobserve()?;
            result.terminal = true;
            Ok(result)
        }
    }
    fn cleanup_operation_node(node: OperationCleanupNode) -> Result<(), DesktopInstallError> {
        node.reobserve()?;
        if node.directory {
            for entry in std::fs::read_dir(&node.path).map_err(|_| DesktopInstallError::Cleanup)? {
                let entry = entry.map_err(|_| DesktopInstallError::Cleanup)?;
                let name = entry.file_name();
                operation_leaf(&name)?;
                // Enumeration supplies only a type hint; the relative open is the authority.
                let hint = entry.file_type().map_err(|_| DesktopInstallError::Cleanup)?;
                if hint.is_symlink() || (!hint.is_dir() && !hint.is_file()) {
                    return Err(DesktopInstallError::Cleanup);
                }
                node.reobserve()?;
                let child = OperationCleanupNode::open(
                    node.handle.0, &node.path, &name, hint.is_dir(),
                )?;
                cleanup_operation_node(child)?;
                node.reobserve()?;
            }
        }
        node.delete()
    }

    fn cleanup_operation_root(
        parents: &DirectoryHold,
        path: &Path,
        identity: &BY_HANDLE_FILE_INFORMATION,
    ) -> Result<(), DesktopInstallError> {
        parents.reobserve().map_err(|_| DesktopInstallError::Cleanup)?;
        let leaf = path.file_name().ok_or(DesktopInstallError::Cleanup)?;
        let root = OperationCleanupNode::open(
            parents.handles.last().ok_or(DesktopInstallError::Cleanup)?.0,
            &parents.path, leaf, true,
        )?;
        if !same_file(identity, &root.identity) {
            return Err(DesktopInstallError::Cleanup);
        }
        cleanup_operation_node(root)?;
        parents.reobserve().map_err(|_| DesktopInstallError::Cleanup)
    }
    impl Drop for OperationDirectory {
        fn drop(&mut self) {
            if !self.terminal || !self.hold.as_ref().is_some_and(|h| h.reobserve().is_ok()) {
                return;
            }
            let Some(mut parents) = self.hold.take() else { return; };
            // Release only this leaf. Every ancestor stays leased throughout cleanup.
            let Some(leaf) = parents.handles.pop() else { return; };
            drop(leaf);
            let Some(parent_path) = self.path.parent() else { return; };
            parents.path = parent_path.to_path_buf();
            let _ = cleanup_operation_root(&parents, &self.path, &self.identity);
        }
    }
    struct OwnedJob {
        job: Handle,
        process: Option<Handle>,
        pid: u32,
        terminal: bool,
        assigned: bool,
    }
    impl OwnedJob {
        fn create() -> Result<Self, DesktopInstallError> {
            let job = Handle::new(
                unsafe { CreateJobObjectW(null(), null()) },
                DesktopInstallError::Launch,
            )?;
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if unsafe {
                SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            } == 0
            {
                return Err(DesktopInstallError::Launch);
            }
            Ok(Self {
                job,
                process: None,
                pid: 0,
                terminal: true,
                assigned: false,
            })
        }
        fn launch(
            &mut self,
            image: &ImageHold,
            directory: &OperationDirectory,
            id: &str,
            pipe: &str,
            sid: &str,
        ) -> Result<(), DesktopInstallError> {
            let exe = wide(image.path.as_os_str())?;
            let command = [
                image.path.as_os_str(),
                OsStr::new("--project-dir"),
                directory.path.join("project").as_os_str(),
                OsStr::new("--winsmux-installer-probe"),
                OsStr::new(id),
                OsStr::new("--winsmux-installer-pipe"),
                OsStr::new(pipe),
            ]
            .iter()
            .map(|arg| quote(arg))
            .collect::<Result<Vec<_>, _>>()?
            .join(" ");
            let mut command = wide(OsStr::new(&command))?;
            let cwd = wide(directory.path.as_os_str())?;
            let temp_parent = directory.path.parent()
                .ok_or(DesktopInstallError::Isolation)?.to_path_buf();
            let profile = probe_profile_paths(&directory.path);
            let mut env: Vec<(std::ffi::OsString, std::ffi::OsString)> = std::env::vars_os()
                .filter(|(key, _)| {
                    ![
                        "TMP",
                        "TEMP",
                        "USERPROFILE",
                        "APPDATA",
                        "LOCALAPPDATA",
                        "HOME",
                        "GIT_CONFIG_GLOBAL",
                        "GIT_CONFIG_SYSTEM",
                        "GIT_CONFIG_NOSYSTEM",
                        "WINSMUX_DESKTOP_REMOTE_DEBUGGING_PORT",
                        "WINSMUX_DESKTOP_REMOTE_DEBUGGING_CONSENT",
                    ]
                    .iter()
                    .any(|name| key.to_string_lossy().eq_ignore_ascii_case(name))
                })
                .collect();
            for (name, value) in [
                ("TMP", temp_parent.clone()),
                ("TEMP", temp_parent),
                ("USERPROFILE", profile.home.clone()),
                ("HOME", profile.home),
                ("LOCALAPPDATA", profile.local),
                ("APPDATA", profile.roaming),
                ("GIT_CONFIG_GLOBAL", directory.path.join("absent-gitconfig")),
                ("GIT_CONFIG_SYSTEM", directory.path.join("absent-gitconfig")),
            ] {
                env.push((name.into(), value.into_os_string()));
            }
            env.push(("GIT_CONFIG_NOSYSTEM".into(), "1".into()));
            env.sort_by_key(|(key, _)| key.to_string_lossy().to_ascii_uppercase());
            let mut block = Vec::new();
            for (key, value) in env {
                block.extend(key.encode_wide());
                block.push(b'=' as u16);
                block.extend(value.encode_wide());
                block.push(0);
            }
            block.push(0);
            let startup = STARTUPINFOW {
                cb: size_of::<STARTUPINFOW>() as u32,
                ..Default::default()
            };
            let mut child = PROCESS_INFORMATION::default();
            if unsafe {
                CreateProcessW(
                    exe.as_ptr(),
                    command.as_mut_ptr(),
                    null(),
                    null(),
                    0,
                    CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                    block.as_ptr().cast(),
                    cwd.as_ptr(),
                    &startup,
                    &mut child,
                )
            } == 0
            {
                return Err(DesktopInstallError::Launch);
            }
            let process = Handle::new(child.hProcess, DesktopInstallError::Launch)?;
            let thread = Handle::new(child.hThread, DesktopInstallError::Launch)?;
            // An assignment failure still owns this exact suspended handle; never kill by name.
            self.pid = child.dwProcessId;
            self.process = Some(process);
            self.terminal = false;
            if unsafe { AssignProcessToJobObject(self.job.0, self.process.as_ref().unwrap().0) }
                == 0
            {
                return Err(DesktopInstallError::Launch);
            }
            self.assigned = true;
            if token_sid(self.process.as_ref().unwrap().0, false)? != sid {
                return Err(DesktopInstallError::Actor);
            }
            self.verify_image(image)?;
            if unsafe { ResumeThread(thread.0) } == u32::MAX {
                return Err(DesktopInstallError::Launch);
            }
            Ok(())
        }
        fn verify_image(&self, expected: &ImageHold) -> Result<(), DesktopInstallError> {
            let process = self.process.as_ref().ok_or(DesktopInstallError::Launch)?;
            let mut data = vec![0u16; 32768];
            let mut size = data.len() as u32;
            if unsafe { QueryFullProcessImageNameW(process.0, 0, data.as_mut_ptr(), &mut size) }
                == 0
            {
                return Err(DesktopInstallError::Member);
            }
            let path = PathBuf::from(
                String::from_utf16(&data[..size as usize])
                    .map_err(|_| DesktopInstallError::Path)?,
            );
            let loaded = ImageHold::open(&path)?;
            if !same_file(&expected.identity, &loaded.identity) || expected.digest != loaded.digest
            {
                return Err(DesktopInstallError::Member);
            }
            expected.reobserve()
        }
        fn stop(&mut self) -> Result<(), DesktopInstallError> {
            if self.terminal {
                return Ok(());
            }
            let terminated = if self.assigned {
                unsafe { TerminateJobObject(self.job.0, 0) }
            } else {
                unsafe {
                    TerminateProcess(
                        self.process.as_ref().ok_or(DesktopInstallError::Cleanup)?.0,
                        2,
                    )
                }
            };
            if terminated == 0
                && self
                    .process
                    .as_ref()
                    .is_none_or(|p| unsafe { WaitForSingleObject(p.0, 0) } != WAIT_OBJECT_0)
            {
                return Err(DesktopInstallError::Cleanup);
            }
            let deadline = Instant::now() + Duration::from_millis(OBSERVATION_MS);
            loop {
                let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
                if unsafe {
                    QueryInformationJobObject(
                        self.job.0,
                        JobObjectBasicAccountingInformation,
                        (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                        size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                        null_mut(),
                    )
                } == 0
                {
                    return Err(DesktopInstallError::Cleanup);
                }
                if accounting.ActiveProcesses == 0
                    && self.process.as_ref().is_none_or(
                        |process| unsafe { WaitForSingleObject(process.0, 0) } == WAIT_OBJECT_0,
                    )
                {
                    self.terminal = true;
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    return Err(DesktopInstallError::Cleanup);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
    impl Drop for OwnedJob {
        fn drop(&mut self) {
            if !self.terminal {
                let _ = self.stop();
            }
        }
    }
    fn quote(value: &OsStr) -> Result<String, DesktopInstallError> {
        let text = value.to_str().ok_or(DesktopInstallError::Path)?;
        if text.contains('\0') {
            return Err(DesktopInstallError::Path);
        }
        let mut out = String::from("\"");
        let mut slashes = 0;
        for ch in text.chars() {
            if ch == '\\' {
                slashes += 1;
                continue;
            }
            if ch == '"' {
                out.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
            } else {
                out.extend(std::iter::repeat_n('\\', slashes));
            }
            slashes = 0;
            out.push(ch);
        }
        out.extend(std::iter::repeat_n('\\', slashes * 2));
        out.push('"');
        Ok(out)
    }
    fn create_pipe(name: &str, sid: &str) -> Result<Handle, DesktopInstallError> {
        let security = Security::actor(sid)?;
        let attributes = security.attributes();
        let name = wide(OsStr::new(name))?;
        Handle::new(
            unsafe {
                CreateNamedPipeW(
                    name.as_ptr(),
                    PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
                    PIPE_TYPE_MESSAGE
                        | PIPE_READMODE_MESSAGE
                        | PIPE_NOWAIT
                        | PIPE_REJECT_REMOTE_CLIENTS,
                    1,
                    0,
                    4096,
                    0,
                    &attributes,
                )
            },
            DesktopInstallError::Isolation,
        )
    }
    fn read_receipt(
        pipe: &Handle,
        owned: &OwnedJob,
        image: &ImageHold,
        id: &str,
        request: &StartupVerifyRequest,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        let deadline = Instant::now() + Duration::from_millis(OBSERVATION_MS);
        let mut connected = false;
        loop {
            if unsafe {
                WaitForSingleObject(
                    owned.process.as_ref().ok_or(DesktopInstallError::Launch)?.0,
                    0,
                )
            } == WAIT_OBJECT_0
            {
                return Err(DesktopInstallError::Receipt);
            }
            if !connected {
                let ok = unsafe { ConnectNamedPipe(pipe.0, null_mut()) };
                let error = if ok == 0 {
                    unsafe { GetLastError() }
                } else {
                    ERROR_PIPE_CONNECTED
                };
                match error {
                    ERROR_PIPE_CONNECTED => connected = true,
                    ERROR_PIPE_LISTENING | ERROR_NO_DATA => {}
                    _ => return Err(DesktopInstallError::Receipt),
                }
            }
            if connected {
                let mut pid = 0;
                if unsafe { GetNamedPipeClientProcessId(pipe.0, &mut pid) } == 0 || pid != owned.pid
                {
                    return Err(DesktopInstallError::Receipt);
                }
                if token_sid(owned.process.as_ref().unwrap().0, false)?
                    != request.expected_actor_sid
                {
                    return Err(DesktopInstallError::Actor);
                }
                owned.verify_image(image)?;
                let mut buffer = [0; 4096];
                let mut read = 0;
                if unsafe {
                    ReadFile(
                        pipe.0,
                        buffer.as_mut_ptr(),
                        buffer.len() as u32,
                        &mut read,
                        null_mut(),
                    )
                } != 0
                {
                    if read != 0 {
                        return parse_wire_receipt(&buffer[..read as usize], id, request);
                    }
                } else if !matches!(unsafe { GetLastError() }, ERROR_NO_DATA) {
                    return Err(DesktopInstallError::Receipt);
                }
            }
            if Instant::now() >= deadline {
                return Err(DesktopInstallError::Timeout);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    pub(super) fn verify_startup(
        request: StartupVerifyRequest,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        if !valid_version(&request.expected_version) {
            return Err(DesktopInstallError::Usage);
        }
        actor(&request.expected_actor_sid)?;
        let root =
            DirectoryHold::open(request.gui_path.parent().ok_or(DesktopInstallError::Path)?)?;
        let image = ImageHold::open(&request.gui_path)?;
        if image.digest != request.expected_gui_sha256 {
            return Err(DesktopInstallError::Member);
        }
        let operation = uuid::Uuid::new_v4().to_string();
        let pipe_name = format!(r"\\.\pipe\winsmux-installer-{operation}");
        let mut directory = OperationDirectory::create(&operation, &request.expected_actor_sid)?;
        let pipe = create_pipe(&pipe_name, &request.expected_actor_sid)?;
        let mut owned = OwnedJob::create()?;
        directory.terminal = false;
        let result = owned
            .launch(
                &image,
                &directory,
                &operation,
                &pipe_name,
                &request.expected_actor_sid,
            )
            .and_then(|()| read_receipt(&pipe, &owned, &image, &operation, &request));
        let cleanup = owned.stop();
        directory.terminal = cleanup.is_ok();
        cleanup?;
        root.reobserve()?;
        image.reobserve()?;
        let mut receipt = result?;
        receipt.probe_processes_exited = true;
        Ok(receipt)
    }
    pub(super) fn validate_probe_context(
        context: &StartupProbeContext,
    ) -> Result<(), DesktopInstallError> {
        let root = DirectoryHold::open(
            context
                .project_dir
                .parent()
                .ok_or(DesktopInstallError::Isolation)?,
        )?;
        let project = DirectoryHold::open(&context.project_dir)?;
        let webview = DirectoryHold::open(&context.webview_data_dir)?;
        let operation = context.project_dir.parent().ok_or(DesktopInstallError::Isolation)?;
        let profile = probe_profile_paths(operation);
        for (name, expected) in [
            ("HOME", &profile.home), ("USERPROFILE", &profile.home),
            ("LOCALAPPDATA", &profile.local), ("APPDATA", &profile.roaming),
        ] {
            let actual = PathBuf::from(std::env::var_os(name).ok_or(DesktopInstallError::Isolation)?);
            strict_absolute(&actual).map_err(|_| DesktopInstallError::Isolation)?;
            if !same_path(&actual, expected) {
                return Err(DesktopInstallError::Isolation);
            }
        }
        let actual_local = crate::store::layout::local_app_data()
            .map_err(|_| DesktopInstallError::Isolation)?;
        strict_absolute(&actual_local).map_err(|_| DesktopInstallError::Isolation)?;
        if !same_path(&actual_local, &profile.local) {
            return Err(DesktopInstallError::Isolation);
        }
        let mut profile_holds = Vec::new();
        for expected in [&profile.home, &profile.app_data, &profile.local, &profile.roaming] {
            profile_holds.push(DirectoryHold::open(expected).map_err(|_| DesktopInstallError::Isolation)?);
        }
        let repository = git2::Repository::open(&context.project_dir)
            .map_err(|_| DesktopInstallError::Isolation)?;
        if repository
            .workdir()
            .is_none_or(|p| !same_path(p, &context.project_dir))
        {
            return Err(DesktopInstallError::Isolation);
        }
        root.reobserve()?;
        project.reobserve()?;
        webview.reobserve()?;
        for hold in &profile_holds {
            hold.reobserve().map_err(|_| DesktopInstallError::Isolation)?;
        }
        Ok(())
    }
    fn parent_pid() -> Result<u32, DesktopInstallError> {
        let snapshot = Handle::new(
            unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) },
            DesktopInstallError::Actor,
        )?;
        let mut row = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut ok = unsafe { Process32FirstW(snapshot.0, &mut row) };
        while ok != 0 {
            if row.th32ProcessID == std::process::id() {
                return Ok(row.th32ParentProcessID);
            }
            ok = unsafe { Process32NextW(snapshot.0, &mut row) };
        }
        Err(DesktopInstallError::Actor)
    }
    pub(super) fn send_probe_receipt(
        context: &StartupProbeContext,
        version: &str,
    ) -> Result<(), DesktopInstallError> {
        validate_probe_context(context)?;
        let name = wide(OsStr::new(&context.pipe_name))?;
        let pipe = Handle::new(
            unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_WRITE,
                    0,
                    null(),
                    OPEN_EXISTING,
                    0,
                    null_mut(),
                )
            },
            DesktopInstallError::Receipt,
        )?;
        let mut server = 0;
        if unsafe { GetNamedPipeServerProcessId(pipe.0, &mut server) } == 0
            || server != parent_pid()?
        {
            return Err(DesktopInstallError::Actor);
        }
        let sid = token_sid(unsafe { GetCurrentProcess() }, true)?;
        actor(&sid)?;
        let image =
            ImageHold::open(&std::env::current_exe().map_err(|_| DesktopInstallError::Member)?)?;
        let receipt = StartupReceipt {
            schema: RECEIPT_SCHEMA.into(),
            operation_id: context.operation_id.clone(),
            version: version.into(),
            gui_sha256: sha256_hex(&image.digest),
            normal_mount: true,
            native_ready: true,
            actor_verified: true,
            probe_processes_exited: false,
        };
        let bytes = serde_json::to_vec(&receipt).map_err(|_| DesktopInstallError::Receipt)?;
        let mut written = 0;
        if bytes.len() > 4096
            || unsafe {
                WriteFile(
                    pipe.0,
                    bytes.as_ptr(),
                    bytes.len() as u32,
                    &mut written,
                    null_mut(),
                )
            } == 0
            || written as usize != bytes.len()
        {
            return Err(DesktopInstallError::Receipt);
        }
        if unsafe { FlushFileBuffers(pipe.0) } == 0 {
            return Err(DesktopInstallError::Receipt);
        }
        Ok(())
    }
    #[cfg(test)]
    mod native_boundary_tests {
        use super::*;
        #[test]
        fn directory_hold_accepts_drive_root_and_temp_with_trailing_separator() {
            let temp = std::env::temp_dir();
            let text = temp.to_str().unwrap();
            let drive = PathBuf::from(&text[..3]);
            DirectoryHold::open(&drive).unwrap().reobserve().unwrap();
            DirectoryHold::open(&temp).unwrap().reobserve().unwrap();
        }
    }
}

#[cfg(test)]
mod receipt_tests {
    use super::*;
    #[test]
    fn receipt_binds_operation_image_version_actor_and_mount_without_cleanup_claim() {
        let id = uuid::Uuid::new_v4().to_string();
        let request = StartupVerifyRequest {
            gui_path: "unused".into(),
            expected_gui_sha256: [1; 32],
            expected_version: "0.38.0".into(),
            expected_actor_sid: "S-1-5-21-1".into(),
        };
        let receipt = StartupReceipt {
            schema: RECEIPT_SCHEMA.into(),
            operation_id: id.clone(),
            version: request.expected_version.clone(),
            gui_sha256: sha256_hex(&request.expected_gui_sha256),
            normal_mount: true,
            native_ready: true,
            actor_verified: true,
            probe_processes_exited: false,
        };
        let good = serde_json::to_value(&receipt).unwrap();
        assert!(parse_wire_receipt(&serde_json::to_vec(&good).unwrap(), &id, &request).is_ok());
        for (key, value) in [
            ("schema", serde_json::json!("wrong")),
            (
                "operation_id",
                serde_json::json!(uuid::Uuid::new_v4().to_string()),
            ),
            ("version", serde_json::json!("0.0.0")),
            ("gui_sha256", serde_json::json!("00".repeat(32))),
            ("normal_mount", serde_json::json!(false)),
            ("native_ready", serde_json::json!(false)),
            ("actor_verified", serde_json::json!(false)),
            ("probe_processes_exited", serde_json::json!(true)),
        ] {
            let mut bad = good.clone();
            bad[key] = value;
            assert!(
                parse_wire_receipt(&serde_json::to_vec(&bad).unwrap(), &id, &request).is_err(),
                "{key}"
            );
        }
        let mut extra = good;
        extra["unknown"] = true.into();
        assert!(parse_wire_receipt(&serde_json::to_vec(&extra).unwrap(), &id, &request).is_err());
        let text = serde_json::to_string(&receipt).unwrap().replacen(
            "\"normal_mount\":",
            "\"normal_mount\":true,\"normal_mount\":",
            1,
        );
        assert!(parse_wire_receipt(text.as_bytes(), &id, &request).is_err());
    }
}
