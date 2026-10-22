//! One owner for the current-user x64 NSIS publication and its inverse.
//! Context, persisted state and package bytes are inputs, never authorization.
use crate::desktop_install::{
    parse_install_plan, parse_install_plan_shape, parse_sha256, sha256_hex, valid_member_path,
    license_inventory_matches, validate_current_license_inventory, StartupReceipt,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

const VERSION: &str = "0.38.0";
const HOST: &str = "x86_64-pc-windows-msvc";
const CONTROL: &str = ".winsmux-desktop";
const PLAN_FILE: &str = "winsmux.install-plan.json";
const LEGACY: &str = include_str!("desktop_nsis_legacy_v0380.json");
type Result<T> = std::result::Result<T, Error>;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Usage,
    Context,
    Plan,
    Actor,
    Path(u16),
    // A file winsmux created or parked cannot be confirmed by presence, content and ownership.
    Member,
    // A path this install publishes to holds something winsmux does not own and cannot park.
    Occupied,
    // A known folder this install published a link to no longer resolves where it did.
    FolderMoved,
    Registration,
    LegacyIncomplete(LegacyCheck),
    Busy,
    Pending,
    Io,
    Startup,
    // T-only finite observation; the original startup error carries no private text.
    StartupClass(crate::desktop_install::DesktopInstallError),
}
// Which legacy admission check refused, so the installer can say what it needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegacyCheck {
    Inventory,
    Receipt,
    Profile,
}
impl Error {
    pub fn classification(self) -> &'static str {
        match self {
            Self::Usage => "usage",
            Self::Context => "context_refused",
            Self::Plan => "plan_refused",
            Self::Actor => "actor_refused",
            Self::Path(_) => "path_refused",
            Self::Member => "member_unconfirmed",
            Self::Occupied => "destination_occupied",
            Self::FolderMoved => "shortcut_folder_moved",
            Self::Registration => "registration_conflict",
            Self::LegacyIncomplete(check) => match check {
                LegacyCheck::Inventory => "legacy_inventory_incomplete",
                LegacyCheck::Receipt => "legacy_receipt_missing",
                LegacyCheck::Profile => "legacy_profile_incomplete",
            },
            Self::Busy => "work_running_or_locked",
            Self::Pending => "pending_unconfirmed",
            Self::Io => "io_unconfirmed",
            Self::Startup => "startup_unconfirmed",
            Self::StartupClass(error) => match error {
                crate::desktop_install::DesktopInstallError::Usage => "nsis_startup_usage",
                crate::desktop_install::DesktopInstallError::Plan => "nsis_startup_plan",
                crate::desktop_install::DesktopInstallError::Path => "nsis_startup_path",
                crate::desktop_install::DesktopInstallError::Member => "nsis_startup_member",
                crate::desktop_install::DesktopInstallError::Actor => "nsis_startup_actor",
                crate::desktop_install::DesktopInstallError::Isolation => "nsis_startup_isolation",
                crate::desktop_install::DesktopInstallError::Launch => "nsis_startup_launch",
                crate::desktop_install::DesktopInstallError::Receipt => "nsis_startup_receipt",
                crate::desktop_install::DesktopInstallError::Timeout => "nsis_startup_timeout",
                crate::desktop_install::DesktopInstallError::Cleanup => "nsis_startup_cleanup",
            },
        }
    }
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Install,
    Uninstall,
}
impl Action {
    fn text(self) -> &'static str {
        if self == Self::Install {
            "install"
        } else {
            "uninstall"
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Context {
    pub action: Action,
    pub root: PathBuf,
    pub source: PathBuf,
    pub plan_sha256: [u8; 32],
    pub language: u32,
    pub start_menu: bool,
    pub desktop: bool,
    pub update: bool,
}
pub fn parse_arguments(args: &[String]) -> Result<(Action, PathBuf)> {
    if args.len() != 3 || args[1] != "--context" || args[2].is_empty() || args[2].contains('\0') {
        return Err(Error::Usage);
    }
    let action = match args[0].as_str() {
        "nsis-install" => Action::Install,
        "nsis-uninstall" => Action::Uninstall,
        _ => return Err(Error::Usage),
    };
    Ok((action, PathBuf::from(&args[2])))
}
pub fn parse_context(bytes: &[u8], action: Action) -> Result<Context> {
    if bytes.len() % 2 != 0 {
        return Err(Error::Context);
    }
    let mut units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|p| u16::from_le_bytes([p[0], p[1]]))
        .collect();
    if units.first() == Some(&0xfeff) {
        units.remove(0);
    }
    if units.contains(&0) || units.contains(&0xfeff) {
        return Err(Error::Context);
    }
    let text = String::from_utf16(&units).map_err(|_| Error::Context)?;
    let lines: Vec<_> = text
        .strip_suffix("\r\n")
        .or_else(|| text.strip_suffix('\n'))
        .unwrap_or(&text)
        .split('\n')
        .collect();
    let keys = [
        "schema",
        "command",
        "root",
        "source",
        "plan_sha256",
        "version",
        "language",
        "start_menu",
        "desktop",
        "update",
    ];
    if lines.len() != keys.len() {
        return Err(Error::Context);
    }
    let mut vals = Vec::new();
    for (line, key) in lines.iter().zip(keys) {
        let line = line.strip_suffix('\r').unwrap_or(line);
        let (got, val) = line.split_once('=').ok_or(Error::Context)?;
        if got != key || val.is_empty() || val.chars().any(|c| c.is_control() || c == '\u{feff}') {
            return Err(Error::Context);
        }
        vals.push(val);
    }
    if vals[0] != "winsmux-nsis-context/v1" || vals[1] != action.text() || vals[5] != VERSION {
        return Err(Error::Context);
    }
    let flag = |v: &str| match v {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(Error::Context),
    };
    let root = PathBuf::from(vals[2]);
    let source = PathBuf::from(vals[3]);
    strict_absolute_role(&root, PathRole::ContextRoot)?;
    strict_absolute_role(&source, PathRole::ContextSource)?;
    Ok(Context {
        action,
        root,
        source,
        plan_sha256: parse_sha256(vals[4]).map_err(|_| Error::Context)?,
        language: match vals[6] {
            "1033" => 1033,
            "1041" => 1041,
            _ => return Err(Error::Context),
        },
        start_menu: flag(vals[7])?,
        desktop: flag(vals[8])?,
        update: flag(vals[9])?,
    })
}
// Diagnostic only: observe an already-refused tilde path; never retry with its expansion.
#[derive(Clone, Copy)]
enum PathRole {
    ContextArgumentParent,
    ContextRoot,
    ContextSource,
    CurrentHelperParent,
    KnownFolderDesktop,
    KnownFolderPrograms,
    DerivedPath,
}
#[derive(Clone, Copy)]
enum TildeShape {
    TildeRemovedAndStrictValid,
    TildeRemainsOrStrictInvalid,
    LookupFailed,
}
fn tilde_role_code(role: PathRole, shape: TildeShape) -> u8 {
    match (role, shape) {
        (PathRole::ContextArgumentParent, TildeShape::TildeRemovedAndStrictValid) => 205,
        (PathRole::ContextArgumentParent, TildeShape::TildeRemainsOrStrictInvalid) => 206,
        (PathRole::ContextArgumentParent, TildeShape::LookupFailed) => 207,
        (PathRole::ContextRoot, TildeShape::TildeRemovedAndStrictValid) => 208,
        (PathRole::ContextRoot, TildeShape::TildeRemainsOrStrictInvalid) => 209,
        (PathRole::ContextRoot, TildeShape::LookupFailed) => 210,
        (PathRole::ContextSource, TildeShape::TildeRemovedAndStrictValid) => 211,
        (PathRole::ContextSource, TildeShape::TildeRemainsOrStrictInvalid) => 212,
        (PathRole::ContextSource, TildeShape::LookupFailed) => 213,
        (PathRole::CurrentHelperParent, TildeShape::TildeRemovedAndStrictValid) => 214,
        (PathRole::CurrentHelperParent, TildeShape::TildeRemainsOrStrictInvalid) => 215,
        (PathRole::CurrentHelperParent, TildeShape::LookupFailed) => 216,
        (PathRole::KnownFolderDesktop, TildeShape::TildeRemovedAndStrictValid) => 217,
        (PathRole::KnownFolderDesktop, TildeShape::TildeRemainsOrStrictInvalid) => 218,
        (PathRole::KnownFolderDesktop, TildeShape::LookupFailed) => 219,
        (PathRole::KnownFolderPrograms, TildeShape::TildeRemovedAndStrictValid) => 220,
        (PathRole::KnownFolderPrograms, TildeShape::TildeRemainsOrStrictInvalid) => 221,
        (PathRole::KnownFolderPrograms, TildeShape::LookupFailed) => 222,
        (PathRole::DerivedPath, TildeShape::TildeRemovedAndStrictValid) => 223,
        (PathRole::DerivedPath, TildeShape::TildeRemainsOrStrictInvalid) => 224,
        (PathRole::DerivedPath, TildeShape::LookupFailed) => 225,
    }
}
// T-only: classify an already-refused native handle, never retry or admit it.
#[derive(Clone, Copy)]
enum HandleScope {
    ContextArgumentParent,
    ContextRoot,
    ContextSource,
    CurrentHelperParent,
    KnownFolderDesktop,
    KnownFolderPrograms,
    DerivedPath,
    DirectoryFlush,
    ExclusionMutex,
    ProcessSnapshot,
    OwnedDirectoryCleanup,
}
#[derive(Clone, Copy)]
enum HandleBucket {
    AccessDenied,
    SharingOrLock,
    NotFound,
    InvalidNameOrLength,
    InvalidParameter,
    PrivilegeNotHeld,
    Resource,
    Other,
}
fn handle_bucket(error: u32) -> HandleBucket {
    match error {
        5 => HandleBucket::AccessDenied,
        32 | 33 => HandleBucket::SharingOrLock,
        2 | 3 => HandleBucket::NotFound,
        123 | 161 | 206 => HandleBucket::InvalidNameOrLength,
        87 => HandleBucket::InvalidParameter,
        1314 => HandleBucket::PrivilegeNotHeld,
        8 | 14 | 1450 => HandleBucket::Resource,
        _ => HandleBucket::Other,
    }
}
fn directory_handle_scope(role: PathRole) -> HandleScope {
    match role {
        PathRole::ContextArgumentParent => HandleScope::ContextArgumentParent,
        PathRole::ContextRoot => HandleScope::ContextRoot,
        PathRole::ContextSource => HandleScope::ContextSource,
        PathRole::CurrentHelperParent => HandleScope::CurrentHelperParent,
        PathRole::KnownFolderDesktop => HandleScope::KnownFolderDesktop,
        PathRole::KnownFolderPrograms => HandleScope::KnownFolderPrograms,
        PathRole::DerivedPath => HandleScope::DerivedPath,
    }
}
fn handle_code(scope: HandleScope, bucket: HandleBucket) -> u16 {
    match (scope, bucket) {
        (HandleScope::ContextArgumentParent, HandleBucket::AccessDenied) => 226,
        (HandleScope::ContextArgumentParent, HandleBucket::SharingOrLock) => 227,
        (HandleScope::ContextArgumentParent, HandleBucket::NotFound) => 228,
        (HandleScope::ContextArgumentParent, HandleBucket::InvalidNameOrLength) => 229,
        (HandleScope::ContextArgumentParent, HandleBucket::InvalidParameter) => 230,
        (HandleScope::ContextArgumentParent, HandleBucket::PrivilegeNotHeld) => 231,
        (HandleScope::ContextArgumentParent, HandleBucket::Resource) => 232,
        (HandleScope::ContextArgumentParent, HandleBucket::Other) => 233,
        (HandleScope::ContextRoot, HandleBucket::AccessDenied) => 234,
        (HandleScope::ContextRoot, HandleBucket::SharingOrLock) => 235,
        (HandleScope::ContextRoot, HandleBucket::NotFound) => 236,
        (HandleScope::ContextRoot, HandleBucket::InvalidNameOrLength) => 237,
        (HandleScope::ContextRoot, HandleBucket::InvalidParameter) => 238,
        (HandleScope::ContextRoot, HandleBucket::PrivilegeNotHeld) => 239,
        (HandleScope::ContextRoot, HandleBucket::Resource) => 240,
        (HandleScope::ContextRoot, HandleBucket::Other) => 241,
        (HandleScope::ContextSource, HandleBucket::AccessDenied) => 242,
        (HandleScope::ContextSource, HandleBucket::SharingOrLock) => 243,
        (HandleScope::ContextSource, HandleBucket::NotFound) => 244,
        (HandleScope::ContextSource, HandleBucket::InvalidNameOrLength) => 245,
        (HandleScope::ContextSource, HandleBucket::InvalidParameter) => 246,
        (HandleScope::ContextSource, HandleBucket::PrivilegeNotHeld) => 247,
        (HandleScope::ContextSource, HandleBucket::Resource) => 248,
        (HandleScope::ContextSource, HandleBucket::Other) => 249,
        (HandleScope::CurrentHelperParent, HandleBucket::AccessDenied) => 250,
        (HandleScope::CurrentHelperParent, HandleBucket::SharingOrLock) => 251,
        (HandleScope::CurrentHelperParent, HandleBucket::NotFound) => 252,
        (HandleScope::CurrentHelperParent, HandleBucket::InvalidNameOrLength) => 253,
        (HandleScope::CurrentHelperParent, HandleBucket::InvalidParameter) => 254,
        (HandleScope::CurrentHelperParent, HandleBucket::PrivilegeNotHeld) => 255,
        (HandleScope::CurrentHelperParent, HandleBucket::Resource) => 256,
        (HandleScope::CurrentHelperParent, HandleBucket::Other) => 257,
        (HandleScope::KnownFolderDesktop, HandleBucket::AccessDenied) => 258,
        (HandleScope::KnownFolderDesktop, HandleBucket::SharingOrLock) => 259,
        (HandleScope::KnownFolderDesktop, HandleBucket::NotFound) => 260,
        (HandleScope::KnownFolderDesktop, HandleBucket::InvalidNameOrLength) => 261,
        (HandleScope::KnownFolderDesktop, HandleBucket::InvalidParameter) => 262,
        (HandleScope::KnownFolderDesktop, HandleBucket::PrivilegeNotHeld) => 263,
        (HandleScope::KnownFolderDesktop, HandleBucket::Resource) => 264,
        (HandleScope::KnownFolderDesktop, HandleBucket::Other) => 265,
        (HandleScope::KnownFolderPrograms, HandleBucket::AccessDenied) => 266,
        (HandleScope::KnownFolderPrograms, HandleBucket::SharingOrLock) => 267,
        (HandleScope::KnownFolderPrograms, HandleBucket::NotFound) => 268,
        (HandleScope::KnownFolderPrograms, HandleBucket::InvalidNameOrLength) => 269,
        (HandleScope::KnownFolderPrograms, HandleBucket::InvalidParameter) => 270,
        (HandleScope::KnownFolderPrograms, HandleBucket::PrivilegeNotHeld) => 271,
        (HandleScope::KnownFolderPrograms, HandleBucket::Resource) => 272,
        (HandleScope::KnownFolderPrograms, HandleBucket::Other) => 273,
        (HandleScope::DerivedPath, HandleBucket::AccessDenied) => 274,
        (HandleScope::DerivedPath, HandleBucket::SharingOrLock) => 275,
        (HandleScope::DerivedPath, HandleBucket::NotFound) => 276,
        (HandleScope::DerivedPath, HandleBucket::InvalidNameOrLength) => 277,
        (HandleScope::DerivedPath, HandleBucket::InvalidParameter) => 278,
        (HandleScope::DerivedPath, HandleBucket::PrivilegeNotHeld) => 279,
        (HandleScope::DerivedPath, HandleBucket::Resource) => 280,
        (HandleScope::DerivedPath, HandleBucket::Other) => 281,
        (HandleScope::DirectoryFlush, HandleBucket::AccessDenied) => 282,
        (HandleScope::DirectoryFlush, HandleBucket::SharingOrLock) => 283,
        (HandleScope::DirectoryFlush, HandleBucket::NotFound) => 284,
        (HandleScope::DirectoryFlush, HandleBucket::InvalidNameOrLength) => 285,
        (HandleScope::DirectoryFlush, HandleBucket::InvalidParameter) => 286,
        (HandleScope::DirectoryFlush, HandleBucket::PrivilegeNotHeld) => 287,
        (HandleScope::DirectoryFlush, HandleBucket::Resource) => 288,
        (HandleScope::DirectoryFlush, HandleBucket::Other) => 289,
        (HandleScope::ExclusionMutex, HandleBucket::AccessDenied) => 290,
        (HandleScope::ExclusionMutex, HandleBucket::SharingOrLock) => 291,
        (HandleScope::ExclusionMutex, HandleBucket::NotFound) => 292,
        (HandleScope::ExclusionMutex, HandleBucket::InvalidNameOrLength) => 293,
        (HandleScope::ExclusionMutex, HandleBucket::InvalidParameter) => 294,
        (HandleScope::ExclusionMutex, HandleBucket::PrivilegeNotHeld) => 295,
        (HandleScope::ExclusionMutex, HandleBucket::Resource) => 296,
        (HandleScope::ExclusionMutex, HandleBucket::Other) => 297,
        (HandleScope::ProcessSnapshot, HandleBucket::AccessDenied) => 298,
        (HandleScope::ProcessSnapshot, HandleBucket::SharingOrLock) => 299,
        (HandleScope::ProcessSnapshot, HandleBucket::NotFound) => 300,
        (HandleScope::ProcessSnapshot, HandleBucket::InvalidNameOrLength) => 301,
        (HandleScope::ProcessSnapshot, HandleBucket::InvalidParameter) => 302,
        (HandleScope::ProcessSnapshot, HandleBucket::PrivilegeNotHeld) => 303,
        (HandleScope::ProcessSnapshot, HandleBucket::Resource) => 304,
        (HandleScope::ProcessSnapshot, HandleBucket::Other) => 305,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::AccessDenied) => 306,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::SharingOrLock) => 307,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::NotFound) => 308,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::InvalidNameOrLength) => 309,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::InvalidParameter) => 310,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::PrivilegeNotHeld) => 311,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::Resource) => 312,
        (HandleScope::OwnedDirectoryCleanup, HandleBucket::Other) => 313,
    }
}
// T-only: annotate only an already-propagated DerivedPath/NotFound refusal.
#[derive(Clone, Copy)]
#[repr(u16)]
enum DerivedOrigin {
    NearestExisting = 316,
    OwnedExistingOperation = 317,
    OwnedCreationParent = 318,
    OwnedPostcreationLeaf = 319,
    TreeDirectory = 320,
    JournalParent = 321,
    JournalOps = 322,
    ValidateControl = 323,
    ValidateOps = 324,
    ValidateOwnedDirectory = 325,
    CleanupDirectoryParent = 326,
    CleanupOps = 327,
    AdmitControl = 328,
    AdmitOps = 329,
    TreeFileParent = 330,
    LegacyMemberParent = 331,
    LegacyDesktopParent = 332,
    LegacyProgramsParent = 333,
    ManagedStateParent = 334,
    ManagedPlanParent = 335,
    ManagedMemberParent = 336,
    ManagedDesktopParent = 337,
    ManagedProgramsParent = 338,
    SourcePlanParent = 339,
    SourceMemberParent = 340,
    SourceUninstallerParent = 341,
    SourceDesktopDecodeParent = 342,
    SourceProgramsDecodeParent = 343,
    SourceRootRebindParent = 344,
    SourceDesktopRebindParent = 345,
    SourceProgramsRebindParent = 346,
    TransactionSourceTotalParent = 347,
    TransactionSourceAdmitParent = 348,
    CopySourceParent = 349,
    TransactionOldLiveParent = 350,
    TransactionNewPrivateParent = 351,
    RestoredStateParent = 352,
    CommittedStateParent = 353,
    CommittedMemberParent = 354,
    PublishedMemberParent = 355,
    CleanupPrivateMemberParent = 356,
    RestoreNewMoveSource = 357,
    RestoreNewMoveDestination = 358,
    RestoreOldMoveSource = 359,
    RestoreOldMoveDestination = 360,
    BackupOldMoveSource = 361,
    BackupOldMoveDestination = 362,
    PublishRootMoveSource = 363,
    PublishRootMoveDestination = 364,
    PublishShortcutMoveSource = 365,
    PublishShortcutMoveDestination = 366,
    CommitStateMoveSource = 367,
    CommitStateMoveDestination = 368,
    // 161-172: the preserved-link moves and, per move site, the final-name readback after the rename.
    PublishPreservedMoveSource = 161,
    PublishPreservedMoveDestination = 162,
    RestorePreservedMoveSource = 163,
    RestorePreservedMoveDestination = 164,
    BackupOldMoveReadback = 165,
    PublishRootMoveReadback = 166,
    PublishShortcutMoveReadback = 167,
    CommitStateMoveReadback = 168,
    PublishPreservedMoveReadback = 169,
    RestoreNewMoveReadback = 170,
    RestorePreservedMoveReadback = 171,
    RestoreOldMoveReadback = 172,
}
// Source parent, destination parent, and the readback of the renamed file, for one move site.
type MoveOrigins = (DerivedOrigin, DerivedOrigin, DerivedOrigin);
fn derived_origin<T>(result: Result<T>, origin: Option<DerivedOrigin>) -> Result<T> {
    match (result, origin) {
        (Err(Error::Path(276)), Some(origin)) => Err(Error::Path(origin as u16)),
        (unchanged, _) => unchanged,
    }
}
// T-only: a final-name refusal (106-108) while confirming a move whose rename already happened.
fn readback_origin<T>(result: Result<T>, origin: Option<DerivedOrigin>) -> Result<T> {
    match (result, origin) {
        (Err(Error::Path(106..=108)), Some(origin)) => Err(Error::Path(origin as u16)),
        (unchanged, _) => unchanged,
    }
}
fn source_rebind_origin(domain: &str) -> Option<DerivedOrigin> {
    match domain {
        "root" => Some(DerivedOrigin::SourceRootRebindParent),
        "desktop" => Some(DerivedOrigin::SourceDesktopRebindParent),
        "start_menu" => Some(DerivedOrigin::SourceProgramsRebindParent),
        _ => None,
    }
}
fn shortcut_origin(kind: &str, desktop: DerivedOrigin, programs: DerivedOrigin) -> Option<DerivedOrigin> {
    match kind {
        "desktop" => Some(desktop),
        "start_menu" => Some(programs),
        _ => None,
    }
}
fn strict_absolute(path: &Path) -> Result<()> {
    strict_absolute_role(path, PathRole::DerivedPath)
}
fn strict_absolute_role(path: &Path, role: PathRole) -> Result<()> {
    match strict_absolute_original(path) {
        Err(Error::Path(203)) => Err(Error::Path(u16::from(tilde_role_code(role, tilde_shape(path))))),
        unchanged => unchanged,
    }
}
#[cfg(windows)]
fn tilde_shape(path: &Path) -> TildeShape {
    use windows_sys::Win32::Storage::FileSystem::GetLongPathNameW;
    let Some(text) = path.to_str() else {
        return TildeShape::LookupFailed;
    };
    let mut input: Vec<u16> = text.replace('/', "\\").encode_utf16().collect();
    if input.contains(&0) {
        return TildeShape::LookupFailed;
    }
    input.push(0);
    let required = unsafe { GetLongPathNameW(input.as_ptr(), std::ptr::null_mut(), 0) };
    let Some(capacity) = required.checked_add(1).filter(|_| required != 0) else {
        return TildeShape::LookupFailed;
    };
    let mut output = vec![0; capacity as usize];
    let written = unsafe { GetLongPathNameW(input.as_ptr(), output.as_mut_ptr(), capacity) };
    if written == 0 || written >= capacity {
        return TildeShape::LookupFailed;
    }
    match String::from_utf16(&output[..written as usize]) {
        Ok(expanded) if !expanded.contains('~')
            && strict_absolute_original(Path::new(&expanded)).is_ok() => {
                TildeShape::TildeRemovedAndStrictValid
            }
        _ => TildeShape::TildeRemainsOrStrictInvalid,
    }
}
#[cfg(not(windows))]
fn tilde_shape(_: &Path) -> TildeShape {
    TildeShape::LookupFailed
}
fn strict_absolute_original(path: &Path) -> Result<()> {
    let t = path.to_str().ok_or(Error::Path(100))?.replace('/', "\\");
    let b = t.as_bytes();
    if b.len() < 4
        || !b[0].is_ascii_alphabetic()
        || b[1] != b':'
        || b[2] != b'\\'
    {
        return Err(Error::Path(200));
    }
    for part in t[3..].split('\\') {
        if !valid_member_path(part) {
            let code = if part.is_empty() {
                201
            } else if matches!(part, "." | "..") {
                202
            } else if part.ends_with(['.', ' ']) {
                204
            } else if part.contains('~') {
                203
            } else {
                204
            };
            return Err(Error::Path(code));
        }
    }
    Ok(())
}
fn hash(bytes: &[u8]) -> String {
    sha256_hex(&Sha256::digest(bytes))
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RawValue {
    #[serde(rename = "type")]
    pub kind: u32,
    pub data: Vec<u8>,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SlotPhase {
    Prepared,
    WriteIntent,
    PublishedConfirmed,
    RestoreIntent,
    Restored,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub id: u32,
    pub prior: Option<RawValue>,
    pub desired: Option<RawValue>,
    pub phase: SlotPhase,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotDecision {
    Keep,
    WritePrior,
    WriteDesired,
    Pending,
}
pub fn slot_publish(slot: &Slot, current: &Option<RawValue>) -> SlotDecision {
    if slot.phase != SlotPhase::Prepared {
        return SlotDecision::Pending;
    }
    if current != &slot.prior {
        return SlotDecision::Pending;
    }
    if slot.prior == slot.desired {
        SlotDecision::Keep
    } else {
        SlotDecision::WriteDesired
    }
}
pub fn slot_restore(slot: &Slot, current: &Option<RawValue>) -> SlotDecision {
    match slot.phase {
        SlotPhase::Prepared => {
            if current == &slot.prior {
                SlotDecision::Keep
            } else {
                SlotDecision::Pending
            }
        }
        SlotPhase::PublishedConfirmed | SlotPhase::RestoreIntent | SlotPhase::Restored => {
            if current == &slot.prior {
                SlotDecision::Keep
            } else if current == &slot.desired && slot.phase != SlotPhase::Restored {
                SlotDecision::WritePrior
            } else {
                SlotDecision::Pending
            }
        }
        // Coincidentally equal data never confirms an interrupted write.
        SlotPhase::WriteIntent => SlotDecision::Pending,
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub volume: String,
    pub index: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Member {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub identity: Identity,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Shortcut {
    kind: String,
    member: Member,
    target: String,
    aumid: String,
    // The known folder the link was published to, as it resolved then. The 23b679cc helper recorded
    // none, and an absent value is left out so its state files keep their exact bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    folder: Option<String>,
}
// A same-name link another install owns, parked under the control namespace for the
// lifetime of this install and moved back to its known folder on uninstall.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct PreservedShortcut {
    kind: String,
    member: Member,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    folder: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Installed {
    schema: String,
    generation: String,
    legacy_capture: Option<LegacyBinding>,
    actor_sid: String,
    root: String,
    root_identity: Identity,
    host: String,
    version: String,
    plan_sha256: String,
    plan_bytes: Vec<u8>,
    members: Vec<Member>,
    registration: Vec<Option<RawValue>>,
    shortcuts: Vec<Shortcut>,
    // Helpers before c3394c04 wrote no preserved field. An empty list serializes to their exact
    // bytes, so their state files, journals and commit bytes still pass the re-serialization checks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    preserved: Vec<PreservedShortcut>,
    operation_id: String,
    action: Action,
    #[serde(skip)]
    state_member: Option<Member>,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum MovePhase {
    Prepared,
    MoveIntent,
    MovedConfirmed,
    RestoreIntent,
    Restored,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Move {
    member: Member,
    domain: String,
    phase: MovePhase,
    // A known-folder row names the folder it resolved to when the operation was planned, so recovery
    // never moves a link into a folder that resolves elsewhere by then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    folder: Option<String>,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Prepared,
    BackingUp,
    Publishing,
    StartupVerified,
    Registering,
    CommitIntent,
    Committed,
    Restoring,
    Restored,
    PendingUnconfirmed,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct OwnedDir {
    path: String,
    identity: Identity,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pending {
    schema: String,
    operation_id: String,
    action: Action,
    actor_sid: String,
    root: String,
    root_identity: Identity,
    plan_sha256: String,
    plan_bytes: Vec<u8>,
    prior_state: Option<Vec<u8>>,
    old: Vec<Move>,
    new: Vec<Move>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    preserved: Vec<Move>,
    slots: Vec<Slot>,
    phase: Phase,
    commit_bytes: Option<Vec<u8>>,
    journal_identity: Option<Identity>,
    control_identity: Identity,
    ops_identity: Identity,
    owned_dirs: Vec<OwnedDir>,
}
#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    schema: &'static str,
    operation_id: String,
    action: Action,
    version: &'static str,
    plan_sha256: String,
    startup_receipt: Option<StartupReceipt>,
    owned_registration_verified: bool,
    durable_commit: bool,
    outcome: &'static str,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Legacy {
    schema: String,
    version: String,
    host: String,
    install_mode: String,
    registry_view: u32,
    original_installer: LegacyAsset,
    installed_inventory_complete: bool,
    capture_receipt_sha256: Option<String>,
    files: Vec<crate::desktop_install::InstallMember>,
    registration_profile: Option<LegacyProfile>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyAsset {
    bytes: u64,
    sha256: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyProfile {
    root: String,
    #[serde(deserialize_with = "deserialize_legacy_language")]
    language: Option<u32>,
    registration: Vec<Option<RawValue>>,
    shortcuts: Vec<LegacyShortcut>,
}
fn deserialize_legacy_language<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<u32>, D::Error> {
    // The custom field deserializer keeps the nullable field required in strict JSON.
    Option::<u32>::deserialize(deserializer)
}
fn legacy_language_matches(profile: &LegacyProfile) -> bool {
    match (profile.language, profile.registration.get(1)) {
        (None, Some(None)) => true,
        (Some(language @ (1033 | 1041)), Some(Some(value))) => *value == sz(&language.to_string()),
        _ => false,
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyShortcut {
    kind: String,
    bytes: u64,
    sha256: String,
    target: String,
    aumid: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyBinding {
    original_installer_sha256: String,
    capture_receipt_sha256: String,
}
fn legacy() -> Result<Legacy> {
    let p: Legacy = serde_json::from_str(LEGACY).map_err(|_| Error::Plan)?;
    #[cfg(all(test, windows))]
    let p = native::legacy_fixture().unwrap_or(p);
    if p.schema != "winsmux-desktop-nsis-legacy-v0380/v1"
        || p.version != VERSION
        || p.host != HOST
        || p.install_mode != "currentUser"
        || p.registry_view != 64
        || p.original_installer.bytes != 9920209
        || p.original_installer.sha256
            != "c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2"
    {
        return Err(Error::Plan);
    }
    Ok(p)
}
pub fn legacy_admission_complete() -> Result<()> {
    let p = legacy()?;
    if !p.installed_inventory_complete
        || !p
            .files
            .iter()
            .any(|f| f.role == "uninstaller" && f.path == "uninstall.exe")
    {
        return Err(Error::LegacyIncomplete(LegacyCheck::Inventory));
    }
    if p.capture_receipt_sha256
        .as_ref()
        .is_none_or(|s| parse_sha256(s).is_err())
    {
        return Err(Error::LegacyIncomplete(LegacyCheck::Receipt));
    }
    if p.registration_profile.as_ref().is_none_or(|profile| {
        profile.registration.len() != 22 || !legacy_language_matches(profile)
    }) {
        return Err(Error::LegacyIncomplete(LegacyCheck::Profile));
    }
    Ok(())
}
fn checked_plan(bytes: &[u8], sha: &str) -> Result<crate::desktop_install::InstallPlan> {
    let expected = parse_sha256(sha).map_err(|_| Error::Plan)?;
    let current = parse_install_plan(bytes, expected, "nsis", VERSION).map_err(|_| Error::Plan);
    #[cfg(all(test, windows))]
    if current.is_err() {
        let plan = parse_install_plan_shape(bytes, expected, "nsis", VERSION).map_err(|_| Error::Plan)?;
        if native::synthetic_license_profile(&plan) { return Ok(plan); }
    }
    current
}

// Persisted ownership can be the complete current profile or the complete known historical profile.
// This recognizer never authorizes a new incoming historical install.
fn checked_owned_plan(bytes: &[u8], sha: &str) -> Result<crate::desktop_install::InstallPlan> {
    let plan = parse_install_plan_shape(bytes, parse_sha256(sha).map_err(|_| Error::Plan)?, "nsis", VERSION)
        .map_err(|_| Error::Plan)?;
    let historical: Legacy = serde_json::from_str(LEGACY).map_err(|_| Error::Plan)?;
    if validate_current_license_inventory(&plan.files).is_ok()
        || license_inventory_matches(&plan.files, &historical.files)
    { return Ok(plan); }
    #[cfg(all(test, windows))]
    if native::synthetic_license_profile(&plan) { return Ok(plan); }
    Err(Error::Plan)
}
fn member_inventory_valid(rows: &[Member], plan_bytes: &[u8], plan_sha: &str) -> Result<()> {
    let plan = checked_owned_plan(plan_bytes, plan_sha)?;
    let mut required: Vec<_> = plan
        .files
        .iter()
        .map(|r| (r.path.clone(), r.bytes, r.sha256.clone()))
        .collect();
    required.push((PLAN_FILE.into(), plan_bytes.len() as u64, hash(plan_bytes)));
    let mut seen = HashSet::new();
    if rows.len() != required.len() + 1 {
        return Err(Error::Plan);
    }
    for row in rows {
        if !seen.insert(row.path.to_lowercase())
            || row.bytes == 0
            || parse_sha256(&row.sha256).is_err()
        {
            return Err(Error::Plan);
        }
        if row.path == "uninstall.exe" {
            continue;
        }
        if !required
            .iter()
            .any(|(p, b, h)| p == &row.path && b == &row.bytes && h == &row.sha256)
        {
            return Err(Error::Plan);
        }
    }
    if !seen.contains("uninstall.exe") {
        return Err(Error::Plan);
    }
    Ok(())
}
fn sz(value: &str) -> RawValue {
    RawValue {
        kind: 1,
        data: value
            .encode_utf16()
            .chain([0])
            .flat_map(u16::to_le_bytes)
            .collect(),
    }
}
fn dword(value: u32) -> RawValue {
    RawValue {
        kind: 4,
        data: value.to_le_bytes().to_vec(),
    }
}
fn slot_key(id: u32) -> Result<(&'static str, &'static str)> {
    const PRODUCT: &str = "Software\\github\\winsmux";
    const UNINST: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\winsmux";
    let names = [
        "MainBinaryName",
        "DisplayName",
        "DisplayIcon",
        "DisplayVersion",
        "Publisher",
        "InstallLocation",
        "UninstallString",
        "NoModify",
        "NoRepair",
        "EstimatedSize",
    ];
    match id {
        0 => Ok((PRODUCT, "")),
        1 => Ok((PRODUCT, "Installer Language")),
        2..=11 => Ok((UNINST, names[(id - 2) as usize])),
        12..=21 => {
            let i = (id - 12) % 5;
            let key = match (id < 17, i == 4) {
                (true, false) => "Software\\Classes\\Directory\\shell\\winsmux",
                (true, true) => "Software\\Classes\\Directory\\shell\\winsmux\\command",
                (false, false) => "Software\\Classes\\Directory\\Background\\shell\\winsmux",
                (false, true) => {
                    "Software\\Classes\\Directory\\Background\\shell\\winsmux\\command"
                }
            };
            Ok((key, ["", "MUIVerb", "Icon", "Position", ""][i as usize]))
        }
        22 => Ok((
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "winsmux",
        )),
        _ => Err(Error::Plan),
    }
}
fn desired_slots(root: &str, language: u32, total: u64) -> Result<Vec<Option<RawValue>>> {
    let gui = format!("{root}\\winsmux-app.exe");
    let label = if language == 1041 {
        "winsmuxで開く"
    } else {
        "Open with winsmux"
    };
    let size: u32 = total.div_ceil(1024).try_into().map_err(|_| Error::Plan)?;
    let mut vals = vec![
        sz(root),
        sz(&language.to_string()),
        sz("winsmux-app.exe"),
        sz("winsmux"),
        sz(&format!("\"{gui}\"")),
        sz(VERSION),
        sz("github"),
        sz(&format!("\"{root}\"")),
        sz(&format!("\"{root}\\uninstall.exe\"")),
        dword(1),
        dword(1),
        dword(size),
    ];
    for arg in ["%1", "%V"] {
        vals.extend([
            sz(label),
            sz(label),
            sz(&format!("\"{gui}\",0")),
            sz("Top"),
            sz(&format!("\"{gui}\" \"{arg}\"")),
        ]);
    }
    Ok(vals.into_iter().map(Some).collect())
}

pub fn run(args: &[String]) -> i32 {
    let result = parse_arguments(args).and_then(|(action, path)| {
        #[cfg(windows)]
        {
            native::run_context(action, &path)
        }
        #[cfg(not(windows))]
        {
            let _ = (action, path);
            Err(Error::Actor)
        }
    });
    match result {
        Ok(receipt) => match serde_json::to_string(&receipt) {
            Ok(json) => {
                println!("{json}");
                0
            }
            Err(_) => {
                eprintln!("winsmux installer: pending_unconfirmed");
                3
            }
        },
        Err(error) => {
            eprintln!("winsmux installer: {}", error.classification());
            match error {
                Error::Path(code @ (100..=172 | 200..=368)) => i32::from(code),
                Error::Pending => 3,
                _ => 2,
            }
        }
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::{c_void, OsStr},
        fs::{self, File, OpenOptions},
        io::{Read, Seek, SeekFrom, Write},
        mem::size_of,
        os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle},
        ptr::{null, null_mut},
    };
    use windows_sys::Win32::{
        Foundation::{
            CloseHandle, GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND,
            ERROR_NO_TOKEN, ERROR_PATH_NOT_FOUND, HANDLE, INVALID_HANDLE_VALUE,
        },
        Security::Authorization::ConvertSidToStringSidW,
        Security::{
            GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenElevation,
            TokenIntegrityLevel, TokenUser, TOKEN_ELEVATION, TOKEN_MANDATORY_LABEL, TOKEN_QUERY,
            TOKEN_USER,
        },
        Storage::FileSystem::{
            CreateFileW, FileRenameInfo, GetFileInformationByHandle, GetFinalPathNameByHandleW,
            SetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_ADD_FILE,
            FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_FLAG_WRITE_THROUGH, FILE_READ_ATTRIBUTES,
            FILE_RENAME_INFO, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, VOLUME_NAME_GUID,
        },
        System::Com::CoTaskMemFree,
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
        System::Registry::{
            RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegFlushKey, RegOpenKeyExW,
            RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE,
            KEY_SET_VALUE, KEY_WOW64_64KEY, REG_OPTION_NON_VOLATILE,
        },
        System::Threading::{
            CreateMutexW, GetCurrentProcess, GetCurrentThread, OpenProcess, OpenProcessToken,
            OpenThreadToken, QueryFullProcessImageNameW, ReleaseMutex,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::Shell::{FOLDERID_Desktop, FOLDERID_Programs, SHGetKnownFolderPath},
    };
    #[cfg(test)]
    pub(super) fn synthetic_license_profile(plan: &crate::desktop_install::InstallPlan) -> bool {
        // Exact synthetic payload is restricted to the active Native Mock, never production.
        if !hooks::MOCK.with(|m| m.borrow().is_some()) { return false; }
        let fixed: Legacy = serde_json::from_str(LEGACY).expect("fixed legacy source");
        let path = fixed.files.iter().find(|row| row.role == "license").expect("legacy license").path.as_str();
        let rows: Vec<_> = plan.files.iter().filter(|row| row.role == "license").collect();
        rows.len() == 1 && rows[0].path == path && rows[0].bytes == b"synthetic license".len() as u64
            && rows[0].sha256 == hash(b"synthetic license")
    }

    const DELETE_ACCESS: u32 = 0x10000;
    // SDK ABI: pointer-sized NTSTATUS/Pointer union, then ULONG_PTR Information.
    #[repr(C)]
    struct IoStatus {
        status: isize,
        information: usize,
    }
    #[repr(C)]
    struct UnicodeName {
        length: u16,
        maximum_length: u16,
        buffer: *mut u16,
    }
    #[repr(C)]
    struct ObjectAttributes {
        length: u32,
        root: HANDLE,
        name: *mut UnicodeName,
        attributes: u32,
        security: *mut c_void,
        quality: *mut c_void,
    }
    #[link(name = "ntdll")]
    extern "system" {
        fn NtFlushBuffersFile(file: HANDLE, status: *mut IoStatus) -> i32;
        fn NtCreateFile(
            file: *mut HANDLE,
            access: u32,
            object: *mut ObjectAttributes,
            status: *mut IoStatus,
            allocation: *const i64,
            attributes: u32,
            share: u32,
            disposition: u32,
            options: u32,
            ea: *const c_void,
            ea_length: u32,
        ) -> i32;
    }
    fn flush_handle(handle: HANDLE) -> Result<()> {
        let mut status = IoStatus {
            status: 0,
            information: 0,
        };
        if unsafe { NtFlushBuffersFile(handle, &mut status) } < 0 {
            Err(Error::Pending)
        } else {
            Ok(())
        }
    }
    struct Handle(HANDLE);
    impl Handle {
        fn new(h: HANDLE, refused: u16) -> Result<Self> {
            if h.is_null() || h == INVALID_HANDLE_VALUE {
                Err(Error::Path(refused))
            } else {
                Ok(Self(h))
            }
        }
    }
    impl Handle {
        fn win32(h: HANDLE, scope: HandleScope, error: u32) -> Result<Self> {
            Self::new(h, handle_code(scope, handle_bucket(error)))
        }
    }
    impl Drop for Handle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    fn wide(s: &OsStr) -> Result<Vec<u16>> {
        let mut v: Vec<_> = s.encode_wide().collect();
        if v.contains(&0) {
            return Err(Error::Path(103));
        }
        v.push(0);
        Ok(v)
    }
    /// Inputs remain strict DOS absolute paths. Only filesystem API transport uses
    /// extended length syntax; this never admits caller UNC/device/alias syntax.
    fn path_wide(path: &Path) -> Result<Vec<u16>> {
        let text = path_text(path)?;
        let b = text.as_bytes();
        if b.len() == 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\' {
        } else {
            strict_absolute(path)?;
        }
        wide(OsStr::new(&format!(r"\\?\{}", text)))
    }
    fn path_text(p: &Path) -> Result<String> {
        p.to_str().map(|s| s.replace('/', "\\")).ok_or(Error::Path(104))
    }
    fn same_path(a: &Path, b: &Path) -> bool {
        path_text(a)
            .ok()
            .zip(path_text(b).ok())
            .is_some_and(|(a, b)| a.eq_ignore_ascii_case(&b))
    }
    fn info(h: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION> {
        let mut i = BY_HANDLE_FILE_INFORMATION::default();
        if unsafe { GetFileInformationByHandle(h, &mut i) } == 0
            || i.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            Err(Error::Path(105))
        } else {
            Ok(i)
        }
    }
    fn final_name(h: HANDLE, flags: u32) -> Result<String> {
        #[cfg(test)]
        if hooks::take_final_name_refusal() {
            return Err(Error::Path(106));
        }
        let n = unsafe { GetFinalPathNameByHandleW(h, null_mut(), 0, flags) };
        if n == 0 {
            return Err(Error::Path(106));
        }
        let mut v = vec![0; n as usize + 1];
        let n = unsafe { GetFinalPathNameByHandleW(h, v.as_mut_ptr(), v.len() as u32, flags) };
        if n == 0 || n as usize >= v.len() {
            return Err(Error::Path(107));
        }
        String::from_utf16(&v[..n as usize]).map_err(|_| Error::Path(108))
    }
    fn identity(h: HANDLE) -> Result<Identity> {
        let i = info(h)?;
        let v = final_name(h, VOLUME_NAME_GUID)?;
        let end = v.find('}').ok_or(Error::Path(109))?;
        if !v.starts_with(r"\\?\Volume{") {
            return Err(Error::Path(110));
        }
        Ok(Identity {
            volume: v[..=end].to_ascii_lowercase(),
            index: ((i.nFileIndexHigh as u64) << 32) | i.nFileIndexLow as u64,
        })
    }
    fn canonical(h: HANDLE) -> Result<PathBuf> {
        let n = final_name(h, 0)?;
        if !n.starts_with(r"\\?\") || n.starts_with(r"\\?\UNC\") {
            return Err(Error::Path(111));
        }
        Ok(n[4..].into())
    }
    struct Dirs {
        holds: Vec<Handle>,
        path: PathBuf,
        id: Identity,
    }
    impl Dirs {
        fn open(p: &Path) -> Result<Self> {
            Self::open_role(p, PathRole::DerivedPath)
        }
        fn open_role(p: &Path, role: PathRole) -> Result<Self> {
            let t = path_text(p)?;
            if t.len() != 3 {
                strict_absolute_role(p, role)?;
            }
            let mut cur = PathBuf::from(&t[..3]);
            let mut holds = Vec::new();
            for part in std::iter::once(None).chain(t[3..].split('\\').map(Some)) {
                if let Some(part) = part {
                    cur.push(part);
                }
                let n = path_wide(&cur)?;
                let raw = unsafe {
                    CreateFileW(
                        n.as_ptr(),
                        FILE_READ_ATTRIBUTES | 0x20, // FILE_TRAVERSE
                        FILE_SHARE_READ | FILE_SHARE_WRITE,
                        null(),
                        OPEN_EXISTING,
                        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                        null_mut(),
                    )
                };
                let error = unsafe { GetLastError() };
                let h = Handle::win32(raw, directory_handle_scope(role), error)?;
                if info(h.0)?.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
                    || !same_path(&cur, &canonical(h.0)?)
                {
                    return Err(Error::Path(112));
                }
                holds.push(h);
            }
            let last = holds.last().ok_or(Error::Path(113))?;
            Ok(Self {
                path: canonical(last.0)?,
                id: identity(last.0)?,
                holds,
            })
        }
        fn flush(&self) -> Result<()> {
            self.reobserve()?;
            let name = path_wide(&self.path)?;
            let raw = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    FILE_READ_ATTRIBUTES | FILE_ADD_FILE | 0x100000,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    null(),
                    OPEN_EXISTING,
                    FILE_FLAG_BACKUP_SEMANTICS
                        | FILE_FLAG_OPEN_REPARSE_POINT
                        | FILE_FLAG_WRITE_THROUGH,
                    null_mut(),
                )
            };
            let error = unsafe { GetLastError() };
            let h = Handle::win32(raw, HandleScope::DirectoryFlush, error)?;
            if identity(h.0)? != self.id || !same_path(&self.path, &canonical(h.0)?) {
                return Err(Error::Pending);
            }
            flush_handle(h.0)
        }
        fn reobserve(&self) -> Result<()> {
            for h in &self.holds {
                info(h.0)?;
            }
            let h = self.holds.last().ok_or(Error::Path(114))?;
            if identity(h.0)? != self.id || !same_path(&self.path, &canonical(h.0)?) {
                return Err(Error::Path(115));
            }
            Ok(())
        }
    }
    struct Observed {
        file: File,
        member: Member,
        _parents: Dirs,
    }
    fn file_member(file: &mut File, p: &Path, relative: &str) -> Result<Member> {
        let h = file.as_raw_handle() as HANDLE;
        let i = info(h)?;
        if i.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0
            || i.nNumberOfLinks != 1
            || !same_path(p, &canonical(h)?)
        {
            return Err(Error::Path(116));
        }
        file.seek(SeekFrom::Start(0))
            .map_err(|e| diagnostic_io(&e))?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .map_err(|e| diagnostic_io(&e))?;
        Ok(Member {
            path: relative.into(),
            bytes: bytes.len() as u64,
            sha256: hash(&bytes),
            identity: identity(h)?,
        })
    }
    fn observe(p: &Path, relative: &str, mutable: bool) -> Result<Observed> {
        observe_role(p, relative, mutable, PathRole::DerivedPath)
    }
    fn observed_open_error(error: std::io::Error) -> Error {
        // An absent required file is not running work; unknown IO remains unconfirmed.
        match error.raw_os_error() {
            Some(2 | 3) => Error::Member,
            Some(32 | 33) => Error::Busy,
            _ => Error::Io,
        }
    }
    fn observe_role(p: &Path, relative: &str, mutable: bool, role: PathRole) -> Result<Observed> {
        let dirs = Dirs::open_role(p.parent().ok_or(Error::Path(117))?, role)?;
        let access = if mutable {
            0xC0000000 | DELETE_ACCESS
        } else {
            0x80000000
        };
        let mut file = OpenOptions::new()
            .read(true)
            .access_mode(access)
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH)
            .open(p)
            .map_err(observed_open_error)?;
        let member = file_member(&mut file, p, relative)?;
        dirs.reobserve()?;
        Ok(Observed {
            file,
            member,
            _parents: dirs,
        })
    }
    fn read_plain(p: &Path) -> Result<Vec<u8>> {
        read_plain_role(p, PathRole::DerivedPath)
    }
    fn read_plain_role(p: &Path, role: PathRole) -> Result<Vec<u8>> {
        let mut h = observe_role(p, "read", false, role)?;
        h.file
            .seek(SeekFrom::Start(0))
            .map_err(|e| diagnostic_io(&e))?;
        let mut b = Vec::new();
        h.file.read_to_end(&mut b).map_err(|e| diagnostic_io(&e))?;
        Ok(b)
    }
    fn exists(p: &Path) -> Result<bool> {
        match fs::symlink_metadata(p) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(Error::Path(118)),
        }
    }
    fn nearest(p: &Path) -> Result<Dirs> {
        let mut q = p.to_path_buf();
        while !exists(&q)? {
            q = q.parent().ok_or(Error::Path(119))?.into();
        }
        if fs::symlink_metadata(&q).map_err(|_| Error::Path(120))?.is_file() {
            q = q.parent().ok_or(Error::Path(121))?.into();
        }
        derived_origin(Dirs::open(&q), Some(DerivedOrigin::NearestExisting))
    }
    fn admit_volume(root: &Dirs, paths: &[PathBuf]) -> Result<Vec<Dirs>> {
        let mut holds = Vec::new();
        for p in paths {
            let d = nearest(p)?;
            if d.id.volume != root.id.volume {
                return Err(Error::Path(122));
            }
            d.flush()?;
            holds.push(d);
        }
        Ok(holds)
    }
    fn create_dir_owned(p: &Path, parent: &Dirs) -> Result<Identity> {
        let leaf = p.file_name().and_then(|v| v.to_str()).ok_or(Error::Path(123))?;
        if !valid_member_path(leaf) || leaf.contains('/') || leaf.contains('\\') {
            return Err(Error::Path(124));
        }
        let mut name = wide(OsStr::new(leaf))?;
        let bytes = (name.len() - 1).checked_mul(2).ok_or(Error::Path(125))?;
        let mut unicode = UnicodeName {
            length: bytes.try_into().map_err(|_| Error::Path(126))?,
            maximum_length: (bytes + 2).try_into().map_err(|_| Error::Path(127))?,
            buffer: name.as_mut_ptr(),
        };
        let mut object = ObjectAttributes {
            length: size_of::<ObjectAttributes>() as u32,
            root: parent.holds.last().ok_or(Error::Path(128))?.0,
            name: &mut unicode,
            attributes: 0x40,
            security: null_mut(),
            quality: null_mut(),
        };
        let mut status = IoStatus {
            status: 0,
            information: 0,
        };
        let mut raw = null_mut();
        let result = unsafe {
            NtCreateFile(
                &mut raw,
                DELETE_ACCESS | FILE_READ_ATTRIBUTES | FILE_ADD_FILE | 0x100000,
                &mut object,
                &mut status,
                null(),
                FILE_ATTRIBUTE_DIRECTORY,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                2,
                1 | 2 | 0x20 | FILE_FLAG_OPEN_REPARSE_POINT,
                null(),
                0,
            )
        };
        if result < 0 {
            return Err(Error::Pending);
        }
        let held = Handle::new(raw, 314)?;
        if status.information != 2
            || info(held.0)?.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            || !same_path(p, &canonical(held.0)?)
        {
            return Err(Error::Pending);
        }
        let id = identity(held.0)?;
        if id.volume != parent.id.volume {
            return Err(Error::Path(129));
        }
        flush_handle(held.0)?;
        parent.flush()?;
        Ok(id)
    }
    fn make_dirs_owned(p: &Path, root: &Dirs, owned: &mut Vec<OwnedDir>) -> Result<Dirs> {
        let nearest = nearest(p)?;
        if nearest.id.volume != root.id.volume {
            return Err(Error::Path(130));
        }
        let mut missing = Vec::new();
        let mut q = p.to_path_buf();
        while !exists(&q)? {
            missing.push(q.clone());
            q = q.parent().ok_or(Error::Path(131))?.into();
        }
        // An existing operation leaf is never adopted by name, including empty X.
        let ops = root.path.join(CONTROL).join("ops");
        if q.starts_with(&ops) && q != ops {
            let observed = derived_origin(Dirs::open(&q), Some(DerivedOrigin::OwnedExistingOperation))?;
            if !owned
                .iter()
                .any(|d| root.path.join(&d.path) == q && d.identity == observed.id)
            {
                return Err(Error::Pending);
            }
        }
        for d in missing.into_iter().rev() {
            let parent = derived_origin(Dirs::open(d.parent().ok_or(Error::Path(132))?), Some(DerivedOrigin::OwnedCreationParent))?;
            let id = create_dir_owned(&d, &parent)?;
            let rel = d.strip_prefix(&root.path).map_err(|_| Error::Path(133))?;
            owned.push(OwnedDir {
                path: path_text(rel)?,
                identity: id,
            });
        }
        let held = derived_origin(Dirs::open(p), Some(DerivedOrigin::OwnedPostcreationLeaf))?;
        if owned
            .iter()
            .any(|d| root.path.join(&d.path) == p && d.identity != held.id)
        {
            return Err(Error::Pending);
        }
        held.flush()?;
        Ok(held)
    }
    fn exact(p: &Path, row: &Member, mutable: bool) -> Result<Observed> {
        let seen = observe(p, &row.path, mutable)?;
        if seen.member != *row {
            return Err(Error::Member);
        }
        Ok(seen)
    }
    /// Expected object stays leased across the kernel rename and full readback.
    #[cfg(test)]
    fn move_exact(from: &Path, to: &Path, row: &Member, root: &Dirs) -> Result<()> {
        move_exact_with_origins(from, to, row, root, None)
    }
    fn move_exact_with_origins(from: &Path, to: &Path, row: &Member, root: &Dirs, origins: Option<MoveOrigins>) -> Result<()> {
        let mut source = derived_origin(exact(from, row, true), origins.map(|o| o.0))?;
        let parent = derived_origin(Dirs::open(to.parent().ok_or(Error::Path(134))?), origins.map(|o| o.1))?;
        // An occupied destination is this move's destination refusal when the move names one.
        if exists(to)? {
            return Err(origins.map_or(Error::Path(135), |o| Error::Path(o.1 as u16)));
        }
        if parent.id.volume != row.identity.volume || root.id.volume != row.identity.volume {
            return Err(Error::Path(135));
        }
        root.reobserve()?;
        source._parents.flush()?;
        parent.flush()?;
        flush_handle(source.file.as_raw_handle() as HANDLE)?;
        let name = path_wide(to)?;
        let length = (name.len() - 1) * 2;
        let offset = std::mem::offset_of!(FILE_RENAME_INFO, FileName);
        let size = (offset + length + 2).max(size_of::<FILE_RENAME_INFO>());
        let mut storage = vec![0usize; size.div_ceil(size_of::<usize>())];
        let rename = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
        unsafe {
            (*rename).Anonymous.Flags = 0;
            (*rename).RootDirectory = null_mut();
            (*rename).FileNameLength = length.try_into().map_err(|_| Error::Path(136))?;
            std::ptr::copy_nonoverlapping(
                name.as_ptr(),
                (*rename).FileName.as_mut_ptr(),
                name.len(),
            );
        }
        cut("move_before")?;
        if unsafe {
            SetFileInformationByHandle(
                source.file.as_raw_handle() as HANDLE,
                FileRenameInfo,
                rename.cast(),
                size as u32,
            )
        } == 0
        {
            return Err(Error::Pending);
        }
        cut("move_after")?;
        // The rename is done. A final-name refusal from here on is the move's readback refusal, whether
        // it comes from re-identifying either parent or from reading the renamed file back.
        let confirmed = (|| -> Result<bool> {
            flush_handle(source.file.as_raw_handle() as HANDLE)?;
            source._parents.flush()?;
            parent.flush()?;
            Ok(file_member(&mut source.file, to, &row.path)? == *row && !exists(from)?)
        })();
        if !readback_origin(confirmed, origins.map(|o| o.2))? {
            return Err(Error::Pending);
        }
        Ok(())
    }
    fn delete_held(file: &File) -> Result<()> {
        use windows_sys::Win32::Storage::FileSystem::{
            FileDispositionInfo, SetFileInformationByHandle, FILE_DISPOSITION_INFO,
        };
        let flag = FILE_DISPOSITION_INFO { DeleteFile: true };
        if unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle() as HANDLE,
                FileDispositionInfo,
                (&flag as *const FILE_DISPOSITION_INFO).cast(),
                size_of::<FILE_DISPOSITION_INFO>() as u32,
            )
        } == 0
        {
            Err(Error::Pending)
        } else {
            Ok(())
        }
    }
    fn copy_new(
        from: &Path,
        to: &Path,
        root: &Dirs,
        admitted: &Member,
        owned: &mut Vec<OwnedDir>,
    ) -> Result<Member> {
        let mut src = derived_origin(exact(from, admitted, false), Some(DerivedOrigin::CopySourceParent))?;
        let parent = make_dirs_owned(to.parent().ok_or(Error::Path(137))?, root, owned)?;
        let mut dst = OpenOptions::new()
            .read(true)
            .write(true)
            .access_mode(0xC0000000 | DELETE_ACCESS)
            .create_new(true)
            .share_mode(0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH)
            .open(to)
            .map_err(|e| diagnostic_io(&e))?;
        let result = (|| -> Result<Member> {
            src.file
                .seek(SeekFrom::Start(0))
                .map_err(|e| diagnostic_io(&e))?;
            cut("import_before")?;
            std::io::copy(&mut src.file, &mut dst).map_err(|e| diagnostic_io(&e))?;
            dst.sync_all().map_err(|e| diagnostic_io(&e))?;
            flush_handle(dst.as_raw_handle() as HANDLE)?;
            parent.flush()?;
            cut("import_after")?;
            let row = file_member(&mut dst, to, "new")?;
            if row.bytes != admitted.bytes || row.sha256 != admitted.sha256 {
                return Err(Error::Member);
            }
            cut("import_record_before")?;
            Ok(row)
        })();
        if result.is_err() {
            delete_held(&dst)?;
        }
        result
    }
    fn stage_state(
        bytes: &[u8],
        to: &Path,
        root: &Dirs,
        owned: &mut Vec<OwnedDir>,
    ) -> Result<Member> {
        let parent = make_dirs_owned(to.parent().ok_or(Error::Path(138))?, root, owned)?;
        if parent.id.volume != root.id.volume {
            return Err(Error::Path(139));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .access_mode(0xC0000000 | DELETE_ACCESS)
            .create_new(true)
            .share_mode(0)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH)
            .open(to)
            .map_err(|e| diagnostic_io(&e))?;
        let result = (|| -> Result<Member> {
            cut("state_stage_before")?;
            let middle = bytes.len() / 2;
            file.write_all(&bytes[..middle])
                .map_err(|e| diagnostic_io(&e))?;
            cut("state_stage_partial")?;
            file.write_all(&bytes[middle..])
                .map_err(|e| diagnostic_io(&e))?;
            cut("state_stage_before_sync")?;
            file.sync_all().map_err(|e| diagnostic_io(&e))?;
            flush_handle(file.as_raw_handle() as HANDLE)?;
            parent.flush()?;
            file.seek(SeekFrom::Start(0))
                .map_err(|e| diagnostic_io(&e))?;
            let mut got = Vec::new();
            file.read_to_end(&mut got).map_err(|e| diagnostic_io(&e))?;
            if got != bytes {
                return Err(Error::Pending);
            }
            let handle = file.as_raw_handle() as HANDLE;
            if info(handle)?.nNumberOfLinks != 1 || !same_path(to, &canonical(handle)?) {
                return Err(Error::Path(140));
            }
            parent.reobserve()?;
            let member = Member {
                path: "installed.json".into(),
                bytes: bytes.len() as u64,
                sha256: hash(bytes),
                identity: identity(handle)?,
            };
            cut("state_stage_after")?;
            Ok(member)
        })();
        match result {
            Ok(member) => Ok(member),
            Err(error) => {
                delete_held(&file)?;
                Err(error)
            }
        }
    }
    struct ImportGuard<'a> {
        root: &'a Dirs,
        id: String,
        rows: Vec<Move>,
        hold: Option<Dirs>,
        dirs: Vec<OwnedDir>,
        control_identity: Identity,
        ops_identity: Identity,
        armed: bool,
    }
    impl Drop for ImportGuard<'_> {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            self.hold.take();
            let p = Pending {
                schema: String::new(),
                operation_id: self.id.clone(),
                action: Action::Install,
                actor_sid: String::new(),
                root: String::new(),
                root_identity: self.root.id.clone(),
                plan_sha256: String::new(),
                plan_bytes: Vec::new(),
                prior_state: None,
                old: Vec::new(),
                new: self.rows.clone(),
                preserved: Vec::new(),
                slots: Vec::new(),
                phase: Phase::Prepared,
                commit_bytes: None,
                journal_identity: None,
                control_identity: self.control_identity.clone(),
                ops_identity: self.ops_identity.clone(),
                owned_dirs: self.dirs.clone(),
            };
            let _ = cleanup_owned(&p, self.root);
        }
    }
    fn refuse_msi() -> Result<()> {
        #[link(name = "msi")]
        extern "system" {
            fn MsiEnumRelatedProductsW(
                upgrade: *const u16,
                reserved: u32,
                index: u32,
                product: *mut u16,
            ) -> u32;
        }
        let upgrade = wide(OsStr::new("{5A7BA441-A5F4-5622-B257-7BF2575E6D74}"))?;
        let mut product = [0u16; 39];
        match unsafe { MsiEnumRelatedProductsW(upgrade.as_ptr(), 0, 0, product.as_mut_ptr()) } {
            259 => {}
            _ => return Err(Error::Registration),
        }
        // This named slot belongs to the fixed MSI path, not the NSIS default value.
        let name = wide(OsStr::new("Software\\github\\winsmux"))?;
        let mut h = null_mut();
        let status = unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                name.as_ptr(),
                0,
                KEY_QUERY_VALUE | KEY_WOW64_64KEY,
                &mut h,
            )
        };
        if matches!(status, ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND) {
            return Ok(());
        }
        if status != 0 {
            return Err(Error::Registration);
        }
        let key = Key(h);
        let value = wide(OsStr::new("InstallDir"))?;
        let mut size = 0;
        let status = unsafe {
            RegQueryValueExW(
                key.0,
                value.as_ptr(),
                null(),
                null_mut(),
                null_mut(),
                &mut size,
            )
        };
        if status != ERROR_FILE_NOT_FOUND {
            return Err(Error::Registration);
        }
        Ok(())
    }
    fn actor_sid() -> Result<String> {
        fn sid(effective: bool) -> Result<String> {
            let mut raw = null_mut();
            if effective
                && unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut raw) } == 0
                && unsafe { GetLastError() } != ERROR_NO_TOKEN
            {
                return Err(Error::Actor);
            }
            if raw.is_null()
                && unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) } == 0
            {
                return Err(Error::Actor);
            }
            let token = Handle::new(raw, 315)?;
            let mut elevation = TOKEN_ELEVATION::default();
            let mut n = 0;
            if unsafe {
                GetTokenInformation(
                    token.0,
                    TokenElevation,
                    (&mut elevation as *mut TOKEN_ELEVATION).cast(),
                    size_of::<TOKEN_ELEVATION>() as u32,
                    &mut n,
                )
            } == 0
                || elevation.TokenIsElevated != 0
            {
                return Err(Error::Actor);
            }
            let mut integrity_size = 0;
            unsafe {
                GetTokenInformation(
                    token.0,
                    TokenIntegrityLevel,
                    null_mut(),
                    0,
                    &mut integrity_size,
                );
            }
            if integrity_size == 0 {
                return Err(Error::Actor);
            }
            let mut integrity =
                vec![0usize; (integrity_size as usize).div_ceil(size_of::<usize>())];
            if unsafe {
                GetTokenInformation(
                    token.0,
                    TokenIntegrityLevel,
                    integrity.as_mut_ptr().cast(),
                    integrity_size,
                    &mut integrity_size,
                )
            } == 0
            {
                return Err(Error::Actor);
            }
            let label = unsafe { &*integrity.as_ptr().cast::<TOKEN_MANDATORY_LABEL>() };
            let count = unsafe { GetSidSubAuthorityCount(label.Label.Sid) };
            if count.is_null() || unsafe { *count } == 0 {
                return Err(Error::Actor);
            }
            let rid = unsafe { GetSidSubAuthority(label.Label.Sid, (*count - 1) as u32) };
            if rid.is_null() || !(0x2000..0x3000).contains(unsafe { &*rid }) {
                return Err(Error::Actor);
            }
            unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut n) };
            if n == 0 {
                return Err(Error::Actor);
            }
            let mut v = vec![0usize; (n as usize).div_ceil(size_of::<usize>())];
            if unsafe { GetTokenInformation(token.0, TokenUser, v.as_mut_ptr().cast(), n, &mut n) }
                == 0
            {
                return Err(Error::Actor);
            }
            let user = unsafe { &*v.as_ptr().cast::<TOKEN_USER>() };
            let mut text = null_mut();
            if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) } == 0 {
                return Err(Error::Actor);
            }
            let mut len = 0;
            unsafe {
                while *text.add(len) != 0 {
                    len += 1;
                }
            }
            let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(text, len) })
                .map_err(|_| Error::Actor);
            unsafe {
                LocalFree(text.cast());
            }
            sid
        }
        let a = sid(false)?;
        if a != sid(true)? || matches!(a.as_str(), "S-1-5-18" | "S-1-5-19" | "S-1-5-20") {
            return Err(Error::Actor);
        }
        Ok(a)
    }
    struct Exclusion(Handle);
    impl Drop for Exclusion {
        fn drop(&mut self) {
            unsafe {
                ReleaseMutex(self.0 .0);
            }
        }
    }
    fn exclusion(root: &Dirs, sid: &str) -> Result<Exclusion> {
        let name = format!(
            "Local\\winsmux-nsis-{}",
            hash(format!("{}:{}:{}", sid, root.id.volume, root.id.index).as_bytes())
        );
        let name = wide(OsStr::new(&name))?;
        let raw = unsafe { CreateMutexW(null(), 1, name.as_ptr()) };
        let error = unsafe { GetLastError() };
        let handle = Handle::win32(raw, HandleScope::ExclusionMutex, error)?;
        if error == ERROR_ALREADY_EXISTS {
            return Err(Error::Busy);
        }
        Ok(Exclusion(handle))
    }
    fn no_running(root: &Path) -> Result<()> {
        let raw = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        let error = unsafe { GetLastError() };
        let snap = Handle::win32(raw, HandleScope::ProcessSnapshot, error)?;
        let mut p = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut ok = unsafe { Process32FirstW(snap.0, &mut p) };
        while ok != 0 {
            if p.th32ProcessID != std::process::id() {
                let name = String::from_utf16_lossy(
                    &p.szExeFile[..p
                        .szExeFile
                        .iter()
                        .position(|v| *v == 0)
                        .unwrap_or(p.szExeFile.len())],
                );
                let relevant = [
                    "winsmux-app.exe",
                    "winsmux.exe",
                    "winsmux-workspace-mcp.exe",
                ]
                .iter()
                .any(|n| name.eq_ignore_ascii_case(n));
                if relevant {
                    let raw = unsafe {
                        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, p.th32ProcessID)
                    };
                    if raw.is_null() {
                        return Err(Error::Busy);
                    }
                    let h = Handle(raw);
                    let mut buf = vec![0u16; 32768];
                    let mut n = buf.len() as u32;
                    if unsafe { QueryFullProcessImageNameW(h.0, 0, buf.as_mut_ptr(), &mut n) } == 0
                    {
                        return Err(Error::Busy);
                    }
                    let image = PathBuf::from(
                        String::from_utf16(&buf[..n as usize]).map_err(|_| Error::Busy)?,
                    );
                    if image.parent().is_some_and(|parent| same_path(parent, root)) {
                        return Err(Error::Busy);
                    }
                }
            }
            ok = unsafe { Process32NextW(snap.0, &mut p) };
        }
        Ok(())
    }
    fn known_shortcut(kind: &str) -> Result<PathBuf> {
        #[cfg(test)]
        if let Some(root) =
            hooks::MOCK.with(|m| m.borrow().as_ref().and_then(|m| m.shortcut_root.clone()))
        {
            if !matches!(kind, "desktop" | "start_menu") {
                return Err(Error::Plan);
            }
            return Ok(root.join(kind).join("winsmux.lnk"));
        }
        let id = match kind {
            "desktop" => &FOLDERID_Desktop,
            "start_menu" => &FOLDERID_Programs,
            _ => return Err(Error::Plan),
        };
        let mut raw = null_mut();
        if unsafe { SHGetKnownFolderPath(id, 0, null_mut(), &mut raw) } < 0 || raw.is_null() {
            return Err(Error::Path(141));
        }
        let mut n = 0;
        unsafe {
            while *raw.add(n) != 0 {
                n += 1;
            }
        }
        let text = String::from_utf16(unsafe { std::slice::from_raw_parts(raw, n) })
            .map_err(|_| Error::Path(142));
        unsafe {
            CoTaskMemFree(raw.cast());
        }
        let p = PathBuf::from(text?).join("winsmux.lnk");
        let role = if kind == "desktop" { PathRole::KnownFolderDesktop } else { PathRole::KnownFolderPrograms };
        strict_absolute_role(&p, role)?;
        Ok(p)
    }
    /// The link path for `kind` as its known folder resolves now. A recorded folder that resolves
    /// elsewhere, as after a moved Desktop or OneDrive backing it up, is refused, so nothing is
    /// published to, removed from or returned to a folder the record does not name.
    fn recorded_shortcut(kind: &str, folder: Option<&str>) -> Result<PathBuf> {
        let path = known_shortcut(kind)?;
        if folder.is_some_and(|recorded| !path.parent().is_some_and(|now| same_path(Path::new(recorded), now))) {
            return Err(Error::FolderMoved);
        }
        Ok(path)
    }
    fn shortcut_folder(link: &Path) -> Result<String> {
        path_text(link.parent().ok_or(Error::Path(117))?)
    }
    struct Key(HKEY);
    impl Drop for Key {
        fn drop(&mut self) {
            unsafe {
                RegCloseKey(self.0);
            }
        }
    }
    fn key(id: u32, write: bool) -> Result<Option<Key>> {
        let (key, _) = slot_key(id)?;
        let name = wide(OsStr::new(key))?;
        let mut out = null_mut();
        let mask = KEY_WOW64_64KEY | KEY_QUERY_VALUE | if write { KEY_SET_VALUE } else { 0 };
        let result = if write {
            unsafe {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    name.as_ptr(),
                    0,
                    null(),
                    REG_OPTION_NON_VOLATILE,
                    mask,
                    null(),
                    &mut out,
                    null_mut(),
                )
            }
        } else {
            unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, name.as_ptr(), 0, mask, &mut out) }
        };
        if !write && matches!(result, ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND) {
            return Ok(None);
        }
        if result != 0 {
            return Err(Error::Registration);
        }
        Ok(Some(Key(out)))
    }
    fn read_slot(id: u32) -> Result<Option<RawValue>> {
        #[cfg(test)]
        if let Some(value) = hooks::read(id) {
            return value;
        }
        let Some(key) = key(id, false)? else {
            return Ok(None);
        };
        let (_, value) = slot_key(id)?;
        let name = wide(OsStr::new(value))?;
        let mut kind = 0;
        let mut count = 0;
        let result = unsafe {
            RegQueryValueExW(
                key.0,
                name.as_ptr(),
                null(),
                &mut kind,
                null_mut(),
                &mut count,
            )
        };
        if result == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if result != 0 {
            return Err(Error::Registration);
        }
        let mut data = vec![0; count as usize];
        let result = unsafe {
            RegQueryValueExW(
                key.0,
                name.as_ptr(),
                null(),
                &mut kind,
                data.as_mut_ptr(),
                &mut count,
            )
        };
        if result != 0 || count as usize > data.len() {
            return Err(Error::Registration);
        }
        data.truncate(count as usize);
        Ok(Some(RawValue { kind, data }))
    }
    fn write_slot(id: u32, value: &Option<RawValue>) -> Result<()> {
        cut("slot_before_write")?;
        #[cfg(test)]
        if let Some(result) = hooks::write(id, value) {
            result?;
            cut("slot_after_write")?;
            return Ok(());
        }
        if value.is_none() && read_slot(id)?.is_none() {
            return Ok(());
        }
        let key = if value.is_some() {
            key(id, true)?.ok_or(Error::Registration)?
        } else {
            let (key_name, _) = slot_key(id)?;
            let n = wide(OsStr::new(key_name))?;
            let mut h = null_mut();
            if unsafe {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    n.as_ptr(),
                    0,
                    KEY_WOW64_64KEY | KEY_QUERY_VALUE | KEY_SET_VALUE,
                    &mut h,
                )
            } != 0
            {
                return Err(Error::Registration);
            }
            Key(h)
        };
        let (_, name) = slot_key(id)?;
        let name = wide(OsStr::new(name))?;
        let result = match value {
            Some(v) => unsafe {
                RegSetValueExW(
                    key.0,
                    name.as_ptr(),
                    0,
                    v.kind,
                    v.data.as_ptr(),
                    v.data.len().try_into().map_err(|_| Error::Registration)?,
                )
            },
            None => unsafe { RegDeleteValueW(key.0, name.as_ptr()) },
        };
        if result != 0 || unsafe { RegFlushKey(key.0) } != 0 {
            return Err(Error::Registration);
        }
        cut("slot_after_write")?;
        if read_slot(id)? != *value {
            return Err(Error::Registration);
        }
        Ok(())
    }

    #[cfg(test)]
    mod hooks {
        use super::*;
        use std::cell::RefCell;
        #[derive(Default)]
        pub(super) struct Mock {
            pub slots: Vec<Option<RawValue>>,
            pub legacy: Option<Legacy>,
            pub steps: usize,
            pub fail: Option<usize>,
            pub crash: bool,
            pub startup_fail: bool,
            pub foreign_write: bool,
            pub trace: Vec<String>,
            pub barrier: Option<Box<dyn FnMut(&str)>>,
            pub shortcut_root: Option<PathBuf>,
            pub proof_key: String,
            pub proof_trace: Vec<(String, String)>,
            pub final_name_refusal: bool,
            pub reports: Vec<String>,
        }
        thread_local! {pub(super) static MOCK:RefCell<Option<Mock>>=const{RefCell::new(None)};}
        pub(super) fn take_final_name_refusal() -> bool {
            MOCK.with(|m| m.borrow_mut().as_mut().is_some_and(|m| std::mem::take(&mut m.final_name_refusal)))
        }
        pub(super) fn cut(label: &str) -> Result<()> {
            let barrier = MOCK.with(|m| m.borrow_mut().as_mut().and_then(|m| m.barrier.take()));
            if let Some(mut barrier) = barrier {
                barrier(label);
                MOCK.with(|m| {
                    if let Some(m) = m.borrow_mut().as_mut() {
                        m.barrier = Some(barrier);
                    }
                });
            }
            MOCK.with(|m| {
                let mut m = m.borrow_mut();
                if let Some(m) = m.as_mut() {
                    m.steps += 1;
                    m.trace.push(label.into());
                    m.proof_trace.push((label.into(), m.proof_key.clone()));
                    if m.fail == Some(m.steps) {
                        m.fail = None;
                        if m.crash {
                            std::panic::panic_any("synthetic crash cut");
                        }
                        return Err(Error::Io);
                    }
                }
                Ok(())
            })
        }
        pub(super) fn mark(p: &Pending) {
            let mut classes = std::collections::BTreeSet::new();
            for row in &p.old {
                classes.insert(format!("old:{}:{:?}", row.domain, row.phase));
            }
            for row in &p.new {
                classes.insert(format!("new:{}:{:?}", row.domain, row.phase));
            }
            for row in &p.preserved {
                classes.insert(format!("preserved:{}:{:?}", row.domain, row.phase));
            }
            for row in &p.slots {
                classes.insert(format!("slot:{:?}", row.phase));
            }
            MOCK.with(|m| {
                if let Some(m) = m.borrow_mut().as_mut() {
                    m.proof_key = format!("{:?}|{:?}", p.phase, classes);
                }
            });
        }
        pub(super) fn read(id: u32) -> Option<Result<Option<RawValue>>> {
            MOCK.with(|m| {
                m.borrow()
                    .as_ref()
                    .map(|m| Ok(m.slots[id as usize].clone()))
            })
        }
        pub(super) fn write(id: u32, value: &Option<RawValue>) -> Option<Result<()>> {
            MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let m = m.as_mut()?;
                m.slots[id as usize] = value.clone();
                if m.foreign_write {
                    m.foreign_write = false;
                    m.slots[id as usize] = Some(RawValue {
                        kind: 3,
                        data: vec![88],
                    });
                    return Some(Err(Error::Registration));
                }
                Some(Ok(()))
            })
        }
    }
    #[cfg(test)]
    pub(super) fn legacy_fixture() -> Option<Legacy> {
        hooks::MOCK.with(|m| m.borrow().as_ref().and_then(|m| m.legacy.clone()))
    }
    #[track_caller]
    fn diagnostic_io(error: &std::io::Error) -> Error {
        #[cfg(test)]
        {
            let at = std::panic::Location::caller();
            let trace = hooks::MOCK.with(|m| {
                m.borrow()
                    .as_ref()
                    .map(|m| m.trace.iter().rev().take(4).cloned().collect::<Vec<_>>())
            });
            eprintln!(
                "synthetic native IO line={} os_error={:?} kind={:?} last_steps={:?}",
                at.line(),
                error.raw_os_error(),
                error.kind(),
                trace
            );
        }
        #[cfg(not(test))]
        {
            let _ = error;
        }
        Error::Io
    }
    fn cut(label: &str) -> Result<()> {
        #[cfg(test)]
        {
            hooks::cut(label)?;
        }
        #[cfg(not(test))]
        {
            let _ = label;
        }
        Ok(())
    }
    /// One stderr line beside the final classification; NSIS prints every line to the details view.
    fn report(line: String) {
        eprintln!("{line}");
        #[cfg(test)]
        hooks::MOCK.with(|m| {
            if let Some(m) = m.borrow_mut().as_mut() {
                m.reports.push(line);
            }
        });
    }
    fn refusal_text(error: Error) -> String {
        match error {
            Error::Path(code) => format!("path_refused:{code}"),
            other => other.classification().into(),
        }
    }
    // The first row a restore could not finish. Its journaled phase stays for the next run.
    struct RestoreIncomplete {
        error: Error,
        domain: String,
        path: String,
    }
    fn report_restore_incomplete(error: Error, incomplete: Option<&RestoreIncomplete>) {
        report(match incomplete {
            Some(row) => format!(
                "winsmux installer: restore_incomplete {} {} {}",
                refusal_text(row.error),
                row.domain,
                row.path
            ),
            None => format!("winsmux installer: restore_incomplete {}", refusal_text(error)),
        });
    }
    fn startup(request: crate::desktop_install::StartupVerifyRequest) -> Result<StartupReceipt> {
        #[cfg(test)]
        if let Some(result) = hooks::MOCK.with(|m| {
            m.borrow().as_ref().map(|m| {
                if m.startup_fail {
                    Err(Error::Startup)
                } else {
                    Ok(StartupReceipt {
                        schema: "winsmux-desktop-startup-receipt/v1".into(),
                        operation_id: uuid::Uuid::new_v4().to_string(),
                        version: VERSION.into(),
                        gui_sha256: sha256_hex(&request.expected_gui_sha256),
                        normal_mount: true,
                        native_ready: true,
                        actor_verified: true,
                        probe_processes_exited: true,
                    })
                }
            })
        }) {
            return result;
        }
        crate::desktop_install::verify_desktop_startup(request).map_err(Error::StartupClass)
    }
    fn verify_link(p: &Path, target: &Path) -> Result<()> {
        let mut leased = observe(p, "winsmux.lnk", false)?;
        verify_link_held(&mut leased, target)
    }
    fn verify_link_held(leased: &mut Observed, target: &Path) -> Result<()> {
        use windows_sys::{
            core::GUID,
            Win32::System::Com::{
                CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
                COINIT_APARTMENTTHREADED,
            },
        };
        #[repr(C)]
        struct Unknown {
            table: *const *const c_void,
        }
        #[repr(C)]
        struct Property {
            fmtid: GUID,
            pid: u32,
        }
        #[repr(C)]
        struct Variant {
            vt: u16,
            res: [u16; 3],
            data: [usize; 2],
        }
        struct Com(*mut Unknown);
        impl Drop for Com {
            fn drop(&mut self) {
                if !self.0.is_null() {
                    unsafe {
                        let f: unsafe extern "system" fn(*mut Unknown) -> u32 =
                            std::mem::transmute(*(*self.0).table.add(2));
                        f(self.0);
                    }
                }
            }
        }
        struct Apartment;
        impl Drop for Apartment {
            fn drop(&mut self) {
                unsafe {
                    CoUninitialize();
                }
            }
        }
        let hr = unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) };
        if hr < 0 {
            return Err(Error::Member);
        }
        let _apartment = Apartment;
        let clsid = GUID::from_u128(0x00021401_0000_0000_c000_000000000046);
        let iid = GUID::from_u128(0x000214f9_0000_0000_c000_000000000046);
        let persist = GUID::from_u128(0x00000109_0000_0000_c000_000000000046);
        let property = GUID::from_u128(0x886d8eeb_8cf2_4446_8d02_cdba1dbdcf99);
        let mut raw = null_mut();
        if unsafe { CoCreateInstance(&clsid, null_mut(), CLSCTX_INPROC_SERVER, &iid, &mut raw) } < 0
        {
            return Err(Error::Member);
        }
        let link = Com(raw.cast());
        unsafe fn query(obj: *mut Unknown, id: &GUID) -> Result<Com> {
            let f: unsafe extern "system" fn(*mut Unknown, *const GUID, *mut *mut c_void) -> i32 =
                std::mem::transmute(*(*obj).table);
            let mut p = null_mut();
            if f(obj, id, &mut p) < 0 || p.is_null() {
                Err(Error::Member)
            } else {
                Ok(Com(p.cast()))
            }
        }
        let persist = unsafe { query(link.0, &persist) }?;
        // Decode the exact leased object; COM receives only its immutable byte snapshot.
        #[link(name = "shlwapi")]
        extern "system" {
            fn SHCreateMemStream(bytes: *const u8, count: u32) -> *mut c_void;
        }
        let mut bytes = Vec::new();
        leased
            .file
            .seek(SeekFrom::Start(0))
            .map_err(|_| Error::Member)?;
        leased
            .file
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Member)?;
        cut("link_stream_before")?;
        let stream = Com(unsafe {
            SHCreateMemStream(
                bytes.as_ptr(),
                bytes.len().try_into().map_err(|_| Error::Member)?,
            )
        }
        .cast());
        if stream.0.is_null() {
            return Err(Error::Member);
        }
        let load: unsafe extern "system" fn(*mut Unknown, *mut Unknown) -> i32 =
            unsafe { std::mem::transmute(*(*persist.0).table.add(5)) };
        if unsafe { load(persist.0, stream.0) } < 0 {
            return Err(Error::Member);
        }
        let mut text = vec![0u16; 32768];
        let get: unsafe extern "system" fn(*mut Unknown, *mut u16, i32, *mut c_void, u32) -> i32 =
            unsafe { std::mem::transmute(*(*link.0).table.add(3)) };
        if unsafe { get(link.0, text.as_mut_ptr(), text.len() as i32, null_mut(), 4) } < 0 {
            return Err(Error::Member);
        }
        let n = text.iter().position(|c| *c == 0).ok_or(Error::Member)?;
        let found = PathBuf::from(String::from_utf16(&text[..n]).map_err(|_| Error::Member)?);
        if !same_path(&found, target) {
            return Err(Error::Member);
        }
        let args: unsafe extern "system" fn(*mut Unknown, *mut u16, i32) -> i32 =
            unsafe { std::mem::transmute(*(*link.0).table.add(10)) };
        text.fill(0);
        if unsafe { args(link.0, text.as_mut_ptr(), text.len() as i32) } < 0 || text[0] != 0 {
            return Err(Error::Member);
        }
        let store = unsafe { query(link.0, &property) }?;
        let key = Property {
            fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3),
            pid: 5,
        };
        let mut value = Variant {
            vt: 0,
            res: [0; 3],
            data: [0; 2],
        };
        let get: unsafe extern "system" fn(*mut Unknown, *const Property, *mut Variant) -> i32 =
            unsafe { std::mem::transmute(*(*store.0).table.add(5)) };
        if unsafe { get(store.0, &key, &mut value) } < 0 {
            return Err(Error::Member);
        }
        #[link(name = "ole32")]
        extern "system" {
            fn PropVariantClear(value: *mut Variant) -> i32;
        }
        let result = if matches!(value.vt, 8 | 31) && value.data[0] != 0 {
            let p = value.data[0] as *const u16;
            let mut n = 0;
            unsafe {
                while n < 32768 && *p.add(n) != 0 {
                    n += 1;
                }
            }
            if n >= 32768 {
                Err(Error::Member)
            } else {
                String::from_utf16(unsafe { std::slice::from_raw_parts(p, n) })
                    .map_err(|_| Error::Member)
                    .and_then(|v| {
                        if v == "io.github.sora-bluesky.winsmux" {
                            Ok(())
                        } else {
                            Err(Error::Member)
                        }
                    })
            }
        } else {
            Err(Error::Member)
        };
        unsafe {
            PropVariantClear(&mut value);
        }
        result
    }
    fn tree(root: &Path) -> Result<HashSet<String>> {
        fn visit(dir: &Path, prefix: &str, out: &mut HashSet<String>) -> Result<()> {
            let _held = derived_origin(Dirs::open(dir), Some(DerivedOrigin::TreeDirectory))?;
            for entry in fs::read_dir(dir).map_err(|_| Error::Path(143))? {
                let entry = entry.map_err(|_| Error::Path(144))?;
                let name = entry.file_name().into_string().map_err(|_| Error::Path(145))?;
                if !valid_member_path(&name) {
                    return Err(Error::Path(146));
                }
                let rel = format!("{prefix}{name}");
                let meta = fs::symlink_metadata(entry.path()).map_err(|_| Error::Path(147))?;
                if meta.file_type().is_symlink() {
                    return Err(Error::Path(148));
                }
                if meta.is_dir() {
                    visit(&entry.path(), &format!("{rel}/"), out)?;
                } else {
                    derived_origin(observe(&entry.path(), &rel, false), Some(DerivedOrigin::TreeFileParent))?;
                    if !out.insert(rel) {
                        return Err(Error::Path(149));
                    }
                }
            }
            Ok(())
        }
        let mut out = HashSet::new();
        visit(root, "", &mut out)?;
        Ok(out)
    }
    #[derive(Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct JournalEnvelope {
        schema: String,
        sha256: String,
        payload: Pending,
    }
    struct Journal {
        file: File,
        path: PathBuf,
        parent: Dirs,
        last: Option<Vec<u8>>,
    }
    impl Journal {
        fn open(path: &Path, new: bool) -> Result<Self> {
            let parent = derived_origin(Dirs::open(path.parent().ok_or(Error::Path(150))?), Some(DerivedOrigin::JournalParent))?;
            parent.flush()?;
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .access_mode(0xC0000000 | DELETE_ACCESS)
                .create_new(new)
                .share_mode(0)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH)
                .open(path)
                .map_err(|_| Error::Pending)?;
            let h = file.as_raw_handle() as HANDLE;
            if info(h)?.nNumberOfLinks != 1 || !same_path(path, &canonical(h)?) {
                return Err(Error::Pending);
            }
            Ok(Self {
                file,
                path: path.into(),
                parent,
                last: None,
            })
        }
        fn id(&self) -> Result<Identity> {
            identity(self.file.as_raw_handle() as HANDLE)
        }
        fn bytes(&mut self) -> Result<Vec<u8>> {
            if !same_path(&self.path, &canonical(self.file.as_raw_handle() as HANDLE)?) {
                return Err(Error::Pending);
            }
            self.file
                .seek(SeekFrom::Start(0))
                .map_err(|_| Error::Pending)?;
            let mut bytes = Vec::new();
            self.file
                .read_to_end(&mut bytes)
                .map_err(|_| Error::Pending)?;
            if self.last.as_ref().is_some_and(|last| *last != bytes) {
                return Err(Error::Pending);
            }
            Ok(bytes)
        }
        fn load(&mut self) -> Result<Pending> {
            let bytes = self.bytes()?;
            let envelope: JournalEnvelope =
                serde_json::from_slice(&bytes).map_err(|_| Error::Pending)?;
            let payload = serde_json::to_vec(&envelope.payload).map_err(|_| Error::Pending)?;
            if envelope.schema != "winsmux-desktop-nsis-journal/v1"
                || hash(&payload) != envelope.sha256
                || serde_json::to_vec(&envelope).map_err(|_| Error::Pending)? != bytes
                || envelope.payload.journal_identity.as_ref() != Some(&self.id()?)
                || envelope.payload.control_identity != self.parent.id
            {
                return Err(Error::Pending);
            }
            let ops = derived_origin(Dirs::open(&self.parent.path.join("ops")), Some(DerivedOrigin::JournalOps))?;
            if ops.id != envelope.payload.ops_identity {
                return Err(Error::Pending);
            }
            self.last = Some(bytes);
            Ok(envelope.payload)
        }
        fn save(&mut self, p: &Pending) -> Result<()> {
            if p.journal_identity.as_ref() != Some(&self.id()?)
                || p.control_identity != self.parent.id
            {
                return Err(Error::Pending);
            }
            let prior = self.bytes()?;
            if self.last.is_none() && !prior.is_empty() {
                return Err(Error::Pending);
            }
            let payload = serde_json::to_vec(p).map_err(|_| Error::Pending)?;
            let envelope = JournalEnvelope {
                schema: "winsmux-desktop-nsis-journal/v1".into(),
                sha256: hash(&payload),
                payload: p.clone(),
            };
            let bytes = serde_json::to_vec(&envelope).map_err(|_| Error::Pending)?;
            #[cfg(test)]
            hooks::mark(p);
            cut("journal_before")?;
            self.file
                .seek(SeekFrom::Start(0))
                .map_err(|_| Error::Pending)?;
            self.file.write_all(&bytes).map_err(|_| Error::Pending)?;
            self.file
                .set_len(bytes.len() as u64)
                .map_err(|_| Error::Pending)?;
            self.file.sync_all().map_err(|_| Error::Pending)?;
            flush_handle(self.file.as_raw_handle() as HANDLE)?;
            self.parent.flush()?;
            // Read exactly the object just written; reset only this expected readback.
            self.last = None;
            let got = self.bytes()?;
            if got != bytes {
                return Err(Error::Pending);
            }
            self.last = Some(bytes);
            cut("journal_after")?;
            Ok(())
        }
        fn finish(mut self) -> Result<()> {
            self.bytes()?;
            let Journal {
                file, path, parent, ..
            } = self;
            delete_held(&file)?;
            drop(file);
            parent.flush()?;
            if exists(&path)? {
                return Err(Error::Pending);
            }
            cut("journal_finish_after")?;
            Ok(())
        }
    }
    fn live_path(root: &Path, row: &Move) -> Result<PathBuf> {
        match row.domain.as_str() {
            "root" => Ok(root.join(&row.member.path)),
            "state" if row.member.path == "installed.json" => {
                Ok(root.join(CONTROL).join("installed.json"))
            }
            "desktop" | "start_menu" if row.member.path == "winsmux.lnk" => {
                recorded_shortcut(&row.domain, row.folder.as_deref())
            }
            _ => Err(Error::Plan),
        }
    }
    fn private_path(root: &Path, id: &str, area: &str, row: &Move) -> PathBuf {
        root.join(CONTROL)
            .join("ops")
            .join(id)
            .join(area)
            .join(&row.domain)
            .join(&row.member.path)
    }
    fn preserved_path(root: &Path, kind: &str) -> Result<PathBuf> {
        if !matches!(kind, "desktop" | "start_menu") {
            return Err(Error::Plan);
        }
        Ok(root.join(CONTROL).join("preserved").join(format!("{kind}-winsmux.lnk")))
    }
    /// Forward direction of a preserved foreign link: parked on install, back to its known folder on uninstall.
    fn preserved_endpoints(root: &Path, action: Action, row: &Move) -> Result<(PathBuf, PathBuf)> {
        let live = live_path(root, row)?;
        let parked = preserved_path(root, &row.domain)?;
        Ok(if action == Action::Install { (live, parked) } else { (parked, live) })
    }
    /// Whether one of `rows` accounts for `live`: its `path_of` resolves to the same path and, when
    /// `verify` is set, its recorded member is what sits there.
    fn row_holds(rows: &[Move], live: &Path, path_of: impl Fn(&Move) -> Result<PathBuf>, verify: bool) -> bool {
        rows.iter().any(|row| {
            path_of(row).is_ok_and(|path| same_path(&path, live) && (!verify || exact(live, &row.member, false).is_ok()))
        })
    }
    fn preserved_move(row: &PreservedShortcut) -> Move {
        Move { member: row.member.clone(), domain: row.kind.clone(), phase: MovePhase::Prepared, folder: row.folder.clone() }
    }
    fn validate_installed(s: &Installed, root: &Dirs, sid: &str) -> Result<()> {
        if s.schema != "winsmux-desktop-nsis-installed/v1"
            || s.host != HOST
            || s.version != VERSION
            || s.actor_sid != sid
            || s.root_identity != root.id
            || !same_path(Path::new(&s.root), &root.path)
            || s.registration.len() != 22
            || s.action != Action::Install
        {
            return Err(Error::Plan);
        }
        let id = uuid::Uuid::parse_str(&s.operation_id).map_err(|_| Error::Plan)?;
        if id.get_version_num() != 4 || id.to_string() != s.operation_id {
            return Err(Error::Plan);
        }
        if s.generation == "managed" {
            member_inventory_valid(&s.members, &s.plan_bytes, &s.plan_sha256)?;
            if let Some(binding) = &s.legacy_capture {
                if binding.original_installer_sha256
                    != "c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2"
                    || parse_sha256(&binding.capture_receipt_sha256).is_err()
                {
                    return Err(Error::Plan);
                }
            }
        } else if s.generation == "legacy" {
            legacy_admission_complete()?;
            let l = legacy()?;
            let profile = l
                .registration_profile
                .as_ref()
                .ok_or(Error::LegacyIncomplete(LegacyCheck::Profile))?;
            let binding = s.legacy_capture.as_ref().ok_or(Error::Plan)?;
            if binding.original_installer_sha256 != l.original_installer.sha256
                || Some(&binding.capture_receipt_sha256) != l.capture_receipt_sha256.as_ref()
                || !same_path(Path::new(&profile.root), &root.path)
                || profile.registration != s.registration
                || s.shortcuts.len() != profile.shortcuts.len()
                || s.shortcuts.iter().any(|link| {
                    !profile.shortcuts.iter().any(|captured| {
                        link.kind == captured.kind
                            && link.member.bytes == captured.bytes
                            && link.target == captured.target
                            && link.aumid == captured.aumid
                    })
                })
                || s.members.len() != l.files.len()
                || s.members.iter().any(|m| {
                    !l.files
                        .iter()
                        .any(|r| m.path == r.path && m.bytes == r.bytes && m.sha256 == r.sha256)
                })
            {
                return Err(Error::Plan);
            }
        } else {
            return Err(Error::Plan);
        }

        let mut kinds = HashSet::new();
        for link in &s.shortcuts {
            if !kinds.insert(link.kind.clone())
                || !matches!(link.kind.as_str(), "desktop" | "start_menu")
                || link.member.path != "winsmux.lnk"
                || link.aumid != "io.github.sora-bluesky.winsmux"
                || !same_path(Path::new(&link.target), &root.path.join("winsmux-app.exe"))
                || parse_sha256(&link.member.sha256).is_err()
            {
                return Err(Error::Plan);
            }
        }
        let mut preserved_kinds = HashSet::new();
        for row in &s.preserved {
            if s.generation != "managed"
                || !preserved_kinds.insert(row.kind.clone())
                || !kinds.contains(&row.kind)
                || row.member.path != "winsmux.lnk"
                || parse_sha256(&row.member.sha256).is_err()
            {
                return Err(Error::Plan);
            }
        }
        if s.generation == "legacy" {
            return Ok(());
        }
        // Derive registration from owned members and the captured, fixed language.
        let language = if s.registration.get(1) == Some(&Some(sz("1041"))) {
            1041
        } else if s.registration.get(1) == Some(&Some(sz("1033"))) {
            1033
        } else {
            return Err(Error::Plan);
        };
        let total = s
            .members
            .iter()
            .try_fold(0u64, |n, m| n.checked_add(m.bytes).ok_or(Error::Plan))?;
        if desired_slots(&s.root, language, total)? != s.registration {
            return Err(Error::Plan);
        }
        Ok(())
    }
    fn admit_legacy(
        root: &Dirs,
        sid: &str,
        new_plan: &[u8],
        new_sha: &str,
    ) -> Result<(Installed, Vec<u8>)> {
        legacy_admission_complete()?;
        let l = legacy()?;
        let profile = l
            .registration_profile
            .as_ref()
            .ok_or(Error::LegacyIncomplete(LegacyCheck::Profile))?;
        // admit_previous reaches here only when legacy_profile_claims matched profile.root to this
        // root, so the root is not compared again.
        if profile.registration.len() != 22 {
            return Err(Error::LegacyIncomplete(LegacyCheck::Profile));
        }
        let mut members = Vec::new();
        let mut paths = HashSet::new();
        for row in &l.files {
            if !valid_member_path(&row.path)
                || row.path.starts_with(CONTROL)
                || !paths.insert(row.path.to_lowercase())
                || parse_sha256(&row.sha256).is_err()
            {
                return Err(Error::Plan);
            }
            let actual = derived_origin(observe(&root.path.join(&row.path), &row.path, true), Some(DerivedOrigin::LegacyMemberParent))?.member;
            if actual.bytes != row.bytes || actual.sha256 != row.sha256 {
                return Err(Error::Member);
            }
            members.push(actual);
        }
        let mut shortcuts = Vec::new();
        for row in &profile.shortcuts {
            if !matches!(row.kind.as_str(), "desktop" | "start_menu")
                || row.aumid != "io.github.sora-bluesky.winsmux"
                || !same_path(Path::new(&row.target), &root.path.join("winsmux-app.exe"))
            {
                return Err(Error::Plan);
            }
            let path = known_shortcut(&row.kind)?;
            let mut leased = derived_origin(observe(&path, "winsmux.lnk", true), shortcut_origin(&row.kind, DerivedOrigin::LegacyDesktopParent, DerivedOrigin::LegacyProgramsParent))?;
            if leased.member.bytes != row.bytes {
                return Err(Error::Member);
            }
            verify_link_held(&mut leased, &root.path.join("winsmux-app.exe"))?;
            let member = leased.member.clone();
            shortcuts.push(Shortcut {
                kind: row.kind.clone(),
                member,
                target: row.target.clone(),
                aumid: row.aumid.clone(),
                folder: Some(shortcut_folder(&path)?),
            });
        }
        for (i, v) in profile.registration.iter().enumerate() {
            if read_slot(i as u32)? != *v {
                return Err(Error::Registration);
            }
        }
        let state = Installed {
            schema: "winsmux-desktop-nsis-installed/v1".into(),
            generation: "legacy".into(),
            legacy_capture: Some(LegacyBinding {
                original_installer_sha256: l.original_installer.sha256,
                capture_receipt_sha256: l.capture_receipt_sha256.ok_or(Error::LegacyIncomplete(LegacyCheck::Receipt))?,
            }),
            actor_sid: sid.into(),
            root: profile.root.clone(),
            root_identity: root.id.clone(),
            host: HOST.into(),
            version: VERSION.into(),
            plan_sha256: new_sha.into(),
            plan_bytes: new_plan.to_vec(),
            members,
            registration: profile.registration.clone(),
            shortcuts,
            preserved: Vec::new(),
            operation_id: uuid::Uuid::new_v4().to_string(),
            action: Action::Install,
            state_member: None,
        };
        validate_installed(&state, root, sid)?;
        let bytes = serde_json::to_vec(&state).map_err(|_| Error::Plan)?;
        Ok((state, bytes))
    }
    fn commit_state(p: &Pending, root: &Dirs) -> Result<Installed> {
        let prior: Option<Installed> = p
            .prior_state
            .as_ref()
            .map(|bytes| serde_json::from_slice(bytes).map_err(|_| Error::Pending))
            .transpose()?;
        let published: Vec<&Move> = p
            .new
            .iter()
            .filter(|r| matches!(r.domain.as_str(), "desktop" | "start_menu"))
            .collect();
        // A kind published again replaces the prior row, which an update does only when that link was gone.
        let mut shortcuts: Vec<Shortcut> = prior
            .as_ref()
            .map(|state| state.shortcuts.iter().filter(|s| !published.iter().any(|r| r.domain == s.kind)).cloned().collect())
            .unwrap_or_default();
        for row in published {
            shortcuts.push(Shortcut {
                kind: row.domain.clone(),
                member: row.member.clone(),
                target: path_text(&root.path.join("winsmux-app.exe"))?,
                aumid: "io.github.sora-bluesky.winsmux".into(),
                folder: row.folder.clone(),
            });
        }
        let mut preserved = prior
            .as_ref()
            .map(|state| state.preserved.clone())
            .unwrap_or_default();
        preserved.extend(p.preserved.iter().map(|row| PreservedShortcut {
            kind: row.domain.clone(),
            member: row.member.clone(),
            folder: row.folder.clone(),
        }));
        let state = Installed {
            schema: "winsmux-desktop-nsis-installed/v1".into(),
            generation: "managed".into(),
            legacy_capture: prior.as_ref().and_then(|s| s.legacy_capture.clone()),
            actor_sid: p.actor_sid.clone(),
            root: p.root.clone(),
            root_identity: p.root_identity.clone(),
            host: HOST.into(),
            version: VERSION.into(),
            plan_sha256: p.plan_sha256.clone(),
            plan_bytes: p.plan_bytes.clone(),
            members: p
                .new
                .iter()
                .filter(|r| r.domain == "root")
                .map(|r| r.member.clone())
                .collect(),
            registration: p.slots[..22].iter().map(|r| r.desired.clone()).collect(),
            shortcuts,
            preserved,
            operation_id: p.operation_id.clone(),
            action: Action::Install,
            state_member: None,
        };
        validate_installed(&state, root, &p.actor_sid)?;
        Ok(state)
    }
    fn state_row(p: &Pending) -> Result<&Move> {
        let rows: Vec<_> = p.new.iter().filter(|r| r.domain == "state").collect();
        if rows.len() != 1 || rows[0].member.path != "installed.json" {
            return Err(Error::Pending);
        }
        Ok(rows[0])
    }
    fn validate_commit_state(p: &Pending, root: &Dirs) -> Result<()> {
        if p.action == Action::Uninstall {
            if p.commit_bytes.is_some() || p.new.iter().any(|r| r.domain == "state") {
                return Err(Error::Pending);
            }
            return Ok(());
        }
        let bytes = p.commit_bytes.as_ref().ok_or(Error::Pending)?;
        let parsed: Installed = serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
        validate_installed(&parsed, root, &p.actor_sid)?;
        if serde_json::to_vec(&commit_state(p, root)?).map_err(|_| Error::Pending)? != *bytes {
            return Err(Error::Pending);
        }
        let row = state_row(p)?;
        if row.member.bytes != bytes.len() as u64
            || row.member.sha256 != hash(bytes)
            || row.member.identity.volume != root.id.volume
        {
            return Err(Error::Pending);
        }
        Ok(())
    }
    fn validate_pending(p: &Pending, root: &Dirs, sid: &str) -> Result<()> {
        let id = uuid::Uuid::parse_str(&p.operation_id).map_err(|_| Error::Pending)?;
        if p.schema != "winsmux-desktop-nsis-pending/v1"
            || id.get_version_num() != 4
            || id.to_string() != p.operation_id
            || p.actor_sid != sid
            || p.root_identity != root.id
            || !same_path(Path::new(&p.root), &root.path)
        {
            return Err(Error::Pending);
        }
        if p.journal_identity
            .as_ref()
            .is_none_or(|id| id.volume != root.id.volume)
            || derived_origin(Dirs::open(&root.path.join(CONTROL)), Some(DerivedOrigin::ValidateControl))?.id != p.control_identity
            || derived_origin(Dirs::open(&root.path.join(CONTROL).join("ops")), Some(DerivedOrigin::ValidateOps))?.id != p.ops_identity
        {
            return Err(Error::Pending);
        }
        let operation = root.path.join(CONTROL).join("ops").join(&p.operation_id);
        let mut allowed = HashSet::from([
            root.path.join(CONTROL),
            root.path.join(CONTROL).join("ops"),
            operation.clone(),
        ]);
        let mut targets = Vec::new();
        for row in p.old.iter().chain(&p.new) {
            targets.extend([
                live_path(&root.path, row)?,
                private_path(&root.path, &p.operation_id, "old", row),
                private_path(&root.path, &p.operation_id, "new", row),
            ]);
        }
        for row in &p.preserved {
            let (from, to) = preserved_endpoints(&root.path, p.action, row)?;
            targets.extend([from, to]);
        }
        for target in targets {
            let mut parent = target.parent().ok_or(Error::Pending)?.to_path_buf();
            while parent.starts_with(&root.path) && parent != root.path {
                allowed.insert(parent.clone());
                parent = parent.parent().ok_or(Error::Pending)?.into();
            }
        }
        let mut dir_names = HashSet::new();
        for row in &p.owned_dirs {
            let relative = Path::new(&row.path);
            if relative.is_absolute()
                || relative
                    .components()
                    .any(|v| !matches!(v, std::path::Component::Normal(_)))
            {
                return Err(Error::Pending);
            }
            let path = root.path.join(relative);
            if !allowed.contains(&path)
                || !dir_names.insert(path.clone())
                || row.identity.volume != root.id.volume
            {
                return Err(Error::Pending);
            }
            if exists(&path)? && derived_origin(Dirs::open(&path), Some(DerivedOrigin::ValidateOwnedDirectory))?.id != row.identity {
                return Err(Error::Pending);
            }
        }
        for path in allowed.iter().filter(|p| p.starts_with(&operation)) {
            if !p
                .owned_dirs
                .iter()
                .any(|d| root.path.join(&d.path) == *path)
            {
                return Err(Error::Pending);
            }
        }
        let plan = checked_owned_plan(&p.plan_bytes, &p.plan_sha256)?;
        let mut old_expected = Vec::new();
        // Uninstall backs up only the product links still in their known folders, so these rows
        // may be absent from p.old but nothing else may stand in for them.
        let mut old_optional = Vec::new();
        let mut prior_preserved = Vec::new();
        if let Some(bytes) = &p.prior_state {
            let s: Installed = serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
            validate_installed(&s, root, sid)?;
            prior_preserved = s.preserved.clone();
            old_expected.extend(s.members.iter().map(|m| ("root".to_string(), m.clone())));
            if p.action == Action::Uninstall {
                old_optional.extend(
                    s.shortcuts
                        .iter()
                        .map(|s| (s.kind.clone(), s.member.clone())),
                );
            }
            if s.generation == "managed" {
                let state = p
                    .old
                    .iter()
                    .find(|m| m.domain == "state")
                    .ok_or(Error::Pending)?;
                if state.member.bytes != bytes.len() as u64
                    || state.member.sha256 != hash(bytes)
                    || state.member.path != "installed.json"
                {
                    return Err(Error::Pending);
                }
                old_expected.push(("state".into(), state.member.clone()));
            }
        }
        let matches_row = |m: &Move, rows: &[(String, Member)]| rows.iter().any(|(d, row)| d == &m.domain && row == &m.member);
        let required = p.old.iter().filter(|m| matches_row(m, &old_expected)).count();
        let mut seen_old = HashSet::new();
        if required != old_expected.len()
            || p.old.iter().any(|m| {
                !seen_old.insert((m.domain.clone(), m.member.path.clone()))
                    || !(matches_row(m, &old_expected) || matches_row(m, &old_optional))
            })
        {
            return Err(Error::Pending);
        }
        // Install parks a foreign link only where this operation publishes; uninstall brings
        // back exactly the rows the owned state recorded.
        let mut preserved_kinds = HashSet::new();
        for row in &p.preserved {
            preserved_endpoints(&root.path, p.action, row)?;
            if !preserved_kinds.insert(row.domain.clone())
                || parse_sha256(&row.member.sha256).is_err()
                || row.member.identity.volume != root.id.volume
            {
                return Err(Error::Pending);
            }
            let admitted = if p.action == Action::Install {
                p.new.iter().any(|n| n.domain == row.domain)
            } else {
                prior_preserved
                    .iter()
                    .any(|q| q.kind == row.domain && q.member == row.member)
            };
            if !admitted {
                return Err(Error::Pending);
            }
        }
        if p.action == Action::Uninstall && p.preserved.len() != prior_preserved.len() {
            return Err(Error::Pending);
        }
        let mut seen = HashSet::new();
        for row in &p.new {
            if !seen.insert((row.domain.clone(), row.member.path.clone()))
                || parse_sha256(&row.member.sha256).is_err()
                || row.member.identity.volume != root.id.volume
            {
                return Err(Error::Pending);
            }
            match row.domain.as_str() {
                "root" => {
                    if row.member.path == PLAN_FILE {
                        if row.member.bytes != p.plan_bytes.len() as u64
                            || row.member.sha256 != p.plan_sha256
                        {
                            return Err(Error::Pending);
                        }
                    } else if row.member.path != "uninstall.exe"
                        && !plan.files.iter().any(|m| {
                            m.path == row.member.path
                                && m.bytes == row.member.bytes
                                && m.sha256 == row.member.sha256
                        })
                    {
                        return Err(Error::Pending);
                    }
                }
                "state" if p.action == Action::Install && row.member.path == "installed.json" => {}
                "desktop" | "start_menu" if row.member.path == "winsmux.lnk" => {}
                _ => return Err(Error::Pending),
            }
        }
        if p.action == Action::Install {
            let members: Vec<_> = p
                .new
                .iter()
                .filter(|m| m.domain == "root")
                .map(|m| m.member.clone())
                .collect();
            member_inventory_valid(&members, &p.plan_bytes, &p.plan_sha256)?;
        } else if !p.new.is_empty() {
            return Err(Error::Pending);
        }
        if p.slots.len() < 22 || p.slots.len() > 23 {
            return Err(Error::Pending);
        }
        for (i, s) in p.slots.iter().enumerate() {
            if s.id != i as u32 {
                return Err(Error::Pending);
            }
            if i == 22 && p.action != Action::Uninstall {
                return Err(Error::Pending);
            }
        }
        validate_commit_state(p, root)?;
        // P and D are derived from the owned state and fixed registration schema.
        if let Some(bytes) = &p.prior_state {
            let old: Installed = serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
            if p.slots[..22]
                .iter()
                .zip(&old.registration)
                .any(|(s, v)| &s.prior != v)
            {
                return Err(Error::Pending);
            }
        } else if p.slots.iter().any(|s| s.prior.is_some()) {
            return Err(Error::Pending);
        }
        if p.action == Action::Uninstall && p.slots.iter().any(|s| s.desired.is_some()) {
            return Err(Error::Pending);
        }
        if p.action == Action::Install {
            let total = p
                .new
                .iter()
                .filter(|r| r.domain == "root")
                .try_fold(0u64, |s, r| {
                    s.checked_add(r.member.bytes).ok_or(Error::Pending)
                })?;
            let language = if p.slots[1].desired == Some(sz("1033")) {
                1033
            } else if p.slots[1].desired == Some(sz("1041")) {
                1041
            } else {
                return Err(Error::Pending);
            };
            let desired = desired_slots(&p.root, language, total)?;
            if p.slots[..22]
                .iter()
                .zip(desired)
                .any(|(s, v)| s.desired != v)
            {
                return Err(Error::Pending);
            }
        }
        if p.slots.len() == 23
            && p.slots[22].prior != Some(sz(&format!("\"{}\\winsmux-app.exe\"", p.root)))
        {
            return Err(Error::Pending);
        }
        Ok(())
    }
    // Ok(true) restored the row, Ok(false) left it uncertain, Err refused it. The restore goes on either way.
    fn restore_row(
        outcome: Result<bool>,
        domain: &str,
        path: &str,
        uncertain: &mut bool,
        incomplete: &mut Option<RestoreIncomplete>,
    ) {
        match outcome {
            Ok(true) => {}
            Ok(false) => *uncertain = true,
            Err(error) => {
                *uncertain = true;
                if incomplete.is_none() {
                    *incomplete = Some(RestoreIncomplete { error, domain: domain.into(), path: path.into() });
                }
            }
        }
    }
    fn row_report_path(path: Result<PathBuf>, row: &Move) -> String {
        path.ok().and_then(|p| path_text(&p).ok()).unwrap_or_else(|| row.member.path.clone())
    }
    fn restore(p: &mut Pending, j: &mut Journal, root: &Dirs, incomplete: &mut Option<RestoreIncomplete>) -> Result<()> {
        p.phase = Phase::Restoring;
        j.save(p)?;
        // Registration first, then files: never point an external X at guessed files.
        // Every row is attempted. A row that refuses keeps its journaled phase, the other rows still go
        // back, and the run ends PendingUnconfirmed so the next run finishes the rest.
        let mut uncertain = false;
        for i in (0..p.slots.len()).rev() {
            let outcome = (|| -> Result<bool> {
                let current = read_slot(p.slots[i].id)?;
                match slot_restore(&p.slots[i], &current) {
                    SlotDecision::Keep => {
                        p.slots[i].phase = SlotPhase::Restored;
                        j.save(p)?;
                        Ok(true)
                    }
                    SlotDecision::WritePrior => {
                        p.slots[i].phase = SlotPhase::RestoreIntent;
                        j.save(p)?;
                        if read_slot(p.slots[i].id)? != p.slots[i].desired {
                            return Ok(false);
                        }
                        write_slot(p.slots[i].id, &p.slots[i].prior)?;
                        p.slots[i].phase = SlotPhase::Restored;
                        j.save(p)?;
                        Ok(true)
                    }
                    _ => Ok(false),
                }
            })();
            restore_row(outcome, "registration", &format!("slot:{}", p.slots[i].id), &mut uncertain, incomplete);
        }
        for i in (0..p.new.len()).rev() {
            let row = p.new[i].clone();
            if matches!(row.phase, MovePhase::Prepared | MovePhase::Restored) {
                continue;
            }
            let outcome = (|| -> Result<bool> {
                let live = live_path(&root.path, &row)?;
                let new = private_path(&root.path, &p.operation_id, "new", &row);
                if exists(&live)? {
                    if exact(&live, &row.member, true).is_err() || exists(&new)? {
                        return Ok(false);
                    }
                    p.new[i].phase = MovePhase::RestoreIntent;
                    j.save(p)?;
                    move_exact_with_origins(&live, &new, &row.member, root, Some((DerivedOrigin::RestoreNewMoveSource, DerivedOrigin::RestoreNewMoveDestination, DerivedOrigin::RestoreNewMoveReadback)))?;
                } else if !exists(&new)? || exact(&new, &row.member, true).is_err() {
                    return Ok(false);
                }
                p.new[i].phase = MovePhase::Restored;
                j.save(p)?;
                Ok(true)
            })();
            restore_row(outcome, &row.domain, &row_report_path(live_path(&root.path, &row), &row), &mut uncertain, incomplete);
        }
        // Preserved links go back before old shortcut rows reclaim the same known-folder path.
        for i in (0..p.preserved.len()).rev() {
            let row = p.preserved[i].clone();
            if matches!(row.phase, MovePhase::Prepared | MovePhase::Restored) {
                continue;
            }
            let outcome = (|| -> Result<bool> {
                let (from, to) = preserved_endpoints(&root.path, p.action, &row)?;
                if exists(&from)? {
                    if exact(&from, &row.member, true).is_err() || exists(&to)? {
                        return Ok(false);
                    }
                } else if exists(&to)? {
                    if exact(&to, &row.member, true).is_err() {
                        return Ok(false);
                    }
                    p.preserved[i].phase = MovePhase::RestoreIntent;
                    j.save(p)?;
                    move_exact_with_origins(&to, &from, &row.member, root, Some((DerivedOrigin::RestorePreservedMoveSource, DerivedOrigin::RestorePreservedMoveDestination, DerivedOrigin::RestorePreservedMoveReadback)))?;
                } else {
                    return Ok(false);
                }
                p.preserved[i].phase = MovePhase::Restored;
                j.save(p)?;
                Ok(true)
            })();
            let from = preserved_endpoints(&root.path, p.action, &row).map(|pair| pair.0);
            restore_row(outcome, &row.domain, &row_report_path(from, &row), &mut uncertain, incomplete);
        }
        for i in (0..p.old.len()).rev() {
            let row = p.old[i].clone();
            let outcome = (|| -> Result<bool> {
                let live = live_path(&root.path, &row)?;
                let old = private_path(&root.path, &p.operation_id, "old", &row);
                if exists(&live)? {
                    if exact(&live, &row.member, true).is_err() || exists(&old)? {
                        return Ok(false);
                    }
                } else if exists(&old)? {
                    if exact(&old, &row.member, true).is_err() {
                        return Ok(false);
                    }
                    p.old[i].phase = MovePhase::RestoreIntent;
                    j.save(p)?;
                    move_exact_with_origins(&old, &live, &row.member, root, Some((DerivedOrigin::RestoreOldMoveSource, DerivedOrigin::RestoreOldMoveDestination, DerivedOrigin::RestoreOldMoveReadback)))?;
                } else {
                    return Ok(false);
                }
                p.old[i].phase = MovePhase::Restored;
                j.save(p)?;
                Ok(true)
            })();
            restore_row(outcome, &row.domain, &row_report_path(live_path(&root.path, &row), &row), &mut uncertain, incomplete);
        }
        for s in &p.slots {
            if read_slot(s.id)? != s.prior {
                uncertain = true;
            }
        }
        for m in &p.old {
            if exact(&live_path(&root.path, m)?, &m.member, true).is_err() {
                uncertain = true;
            }
        }
        for m in &p.preserved {
            let (from, _) = preserved_endpoints(&root.path, p.action, m)?;
            if exact(&from, &m.member, true).is_err() {
                uncertain = true;
            }
        }
        if uncertain {
            p.phase = Phase::PendingUnconfirmed;
            j.save(p)?;
            return Err(Error::Pending);
        }
        verify_restored(p, root)?;
        p.phase = Phase::Restored;
        j.save(p)?;
        Ok(())
    }

    fn verify_restored(p: &Pending, root: &Dirs) -> Result<()> {
        for slot in &p.slots {
            if read_slot(slot.id)? != slot.prior {
                return Err(Error::Pending);
            }
        }
        for row in &p.old {
            exact(&live_path(&root.path, row)?, &row.member, false).map_err(|_| Error::Pending)?;
        }
        if let Some(bytes) = &p.prior_state {
            let old: Installed = serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
            validate_installed(&old, root, &p.actor_sid)?;
            // A link this operation backed up is checked with p.old above. One it never touched
            // was either in place or already gone before the operation, and stays whichever it was.
            for link in &old.shortcuts {
                let path = recorded_shortcut(&link.kind, link.folder.as_deref())?;
                if !p.old.iter().any(|row| row.domain == link.kind) && !exists(&path)? {
                    continue;
                }
                let mut held = exact(&path, &link.member, false).map_err(|_| Error::Pending)?;
                verify_link_held(&mut held, &root.path.join("winsmux-app.exe"))?;
            }
            if old.generation == "managed"
                && derived_origin(read_plain(&root.path.join(CONTROL).join("installed.json")), Some(DerivedOrigin::RestoredStateParent))? != *bytes
            {
                return Err(Error::Pending);
            }
        }
        for row in &p.preserved {
            verify_preserved_at(p, root, row, false)?;
        }
        for row in &p.new {
            let live = live_path(&root.path, row)?;
            if exists(&live)?
                && !row_holds(&p.old, &live, |old| live_path(&root.path, old), true)
                && !row_holds(&p.preserved, &live, |kept| preserved_endpoints(&root.path, p.action, kept).map(|(from, _)| from), true)
            {
                return Err(Error::Pending);
            }
        }
        root.reobserve()?;
        Ok(())
    }
    /// After a restore the foreign link is back at its forward source; after a commit it is at the
    /// forward destination. Whenever it is live, nothing may remain parked under its name.
    fn verify_preserved_at(p: &Pending, root: &Dirs, row: &Move, committed: bool) -> Result<()> {
        let (from, to) = preserved_endpoints(&root.path, p.action, row)?;
        let expected = if committed { &to } else { &from };
        exact(expected, &row.member, false).map_err(|_| Error::Pending)?;
        let parked = preserved_path(&root.path, &row.domain)?;
        if !same_path(expected, &parked) && exists(&parked)? {
            return Err(Error::Pending);
        }
        Ok(())
    }
    fn verify_committed(p: &Pending, root: &Dirs) -> Result<()> {
        for s in &p.slots {
            if s.phase != SlotPhase::PublishedConfirmed && s.prior != s.desired {
                return Err(Error::Pending);
            }
            if read_slot(s.id)? != s.desired {
                return Err(Error::Pending);
            }
        }
        if p.action == Action::Install {
            let bytes = p.commit_bytes.as_ref().ok_or(Error::Pending)?;
            if derived_origin(read_plain(&root.path.join(CONTROL).join("installed.json")), Some(DerivedOrigin::CommittedStateParent))? != *bytes {
                return Err(Error::Pending);
            }
            let state: Installed = serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
            validate_installed(&state, root, &p.actor_sid)?;
            for m in &p.new {
                let path = live_path(&root.path, m)?;
                let mut held = derived_origin(exact(&path, &m.member, false), Some(DerivedOrigin::CommittedMemberParent))?;
                if matches!(m.domain.as_str(), "desktop" | "start_menu") {
                    verify_link_held(&mut held, &root.path.join("winsmux-app.exe"))?;
                }
            }
        } else {
            // A removed product link may have handed its known-folder path back to a preserved one.
            for m in &p.old {
                let live = live_path(&root.path, m)?;
                if exists(&live)?
                    && !row_holds(&p.preserved, &live, |kept| preserved_endpoints(&root.path, p.action, kept).map(|(_, to)| to), true)
                {
                    return Err(Error::Pending);
                }
            }
        }
        for row in &p.preserved {
            verify_preserved_at(p, root, row, true)?;
        }
        root.reobserve()?;
        Ok(())
    }
    fn cleanup_owned(p: &Pending, root: &Dirs) -> Result<()> {
        for (area, rows) in [("old", &p.old), ("new", &p.new)] {
            for row in rows {
                let path = private_path(&root.path, &p.operation_id, area, row);
                if exists(&path)? {
                    let h = derived_origin(exact(&path, &row.member, true), Some(DerivedOrigin::CleanupPrivateMemberParent))?;
                    cut("cleanup_file_before")?;
                    delete_held(&h.file)?;
                    let Observed {
                        file,
                        _parents: parent,
                        ..
                    } = h;
                    drop(file);
                    parent.flush()?;
                    if exists(&path)? {
                        return Err(Error::Pending);
                    }
                    cut("cleanup_file_after")?;
                }
            }
        }
        let stop = root.path.join(CONTROL).join("ops").join(&p.operation_id);
        let mut dirs: Vec<_> = p
            .owned_dirs
            .iter()
            .filter(|d| root.path.join(&d.path).starts_with(&stop))
            .collect();
        dirs.sort_by_key(|d| std::cmp::Reverse(Path::new(&d.path).components().count()));
        for row in dirs {
            let path = root.path.join(&row.path);
            if !exists(&path)? {
                continue;
            }
            // Hold ancestors, never an incompatible duplicate handle of this leaf.
            let parent = derived_origin(Dirs::open(path.parent().ok_or(Error::Path(151))?), Some(DerivedOrigin::CleanupDirectoryParent))?;
            let name = path_wide(&path)?;
            let raw = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    DELETE_ACCESS | FILE_READ_ATTRIBUTES | FILE_ADD_FILE | 0x100000,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    null(),
                    OPEN_EXISTING,
                    FILE_FLAG_BACKUP_SEMANTICS
                        | FILE_FLAG_OPEN_REPARSE_POINT
                        | FILE_FLAG_WRITE_THROUGH,
                    null_mut(),
                )
            };
            let error = unsafe { GetLastError() };
            let held = Handle::win32(raw, HandleScope::OwnedDirectoryCleanup, error)?;
            if identity(held.0)? != row.identity
                || !same_path(&path, &canonical(held.0)?)
                || info(held.0)?.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            {
                return Err(Error::Pending);
            }
            cut("cleanup_dir_before")?;
            let flag =
                windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO { DeleteFile: true };
            if unsafe {
                SetFileInformationByHandle(
                    held.0,
                    windows_sys::Win32::Storage::FileSystem::FileDispositionInfo,
                    (&flag
                        as *const windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO)
                        .cast(),
                    size_of::<windows_sys::Win32::Storage::FileSystem::FILE_DISPOSITION_INFO>()
                        as u32,
                )
            } == 0
            {
                return Err(Error::Pending);
            }
            drop(held);
            parent.flush()?;
            if exists(&path)? {
                return Err(Error::Pending);
            }
            cut("cleanup_dir_after")?;
        }
        let ops = derived_origin(Dirs::open(&root.path.join(CONTROL).join("ops")), Some(DerivedOrigin::CleanupOps))?;
        if ops.id != p.ops_identity || ops.id.volume != root.id.volume {
            return Err(Error::Pending);
        }
        if fs::read_dir(&ops.path)
            .map_err(|_| Error::Pending)?
            .next()
            .is_some()
        {
            return Err(Error::Pending);
        }
        Ok(())
    }
    fn committed_layout(p: &Pending, root: &Dirs) -> Result<bool> {
        if !matches!(p.phase, Phase::CommitIntent | Phase::Committed) {
            return Ok(false);
        }
        validate_commit_state(p, root)?;
        if p.preserved.iter().any(|r| r.phase != MovePhase::MovedConfirmed) {
            return Err(Error::Pending);
        }
        if p.action == Action::Uninstall {
            if p.old.iter().any(|r| r.phase != MovePhase::MovedConfirmed) {
                return Err(Error::Pending);
            }
            verify_committed(p, root)?;
            return Ok(true);
        }
        let row = state_row(p)?;
        let live = live_path(&root.path, row)?;
        let private = private_path(&root.path, &p.operation_id, "new", row);
        if exists(&live)? {
            if !matches!(row.phase, MovePhase::MoveIntent | MovePhase::MovedConfirmed)
                || exists(&private)?
            {
                return Err(Error::Pending);
            }
            exact(&live, &row.member, false).map_err(|_| Error::Pending)?;
            verify_committed(p, root)?;
            return Ok(true);
        }
        if p.phase == Phase::Committed {
            return Err(Error::Pending);
        }
        exact(&private, &row.member, false).map_err(|_| Error::Pending)?;
        Ok(false)
    }
    fn absence_terminal(p: &Pending) -> Result<bool> {
        if p.phase == Phase::Committed && p.action == Action::Uninstall {
            return Ok(true);
        }
        if p.phase != Phase::Restored {
            return Ok(false);
        }
        let prior: Option<Installed> = p
            .prior_state
            .as_ref()
            .map(|bytes| serde_json::from_slice(bytes).map_err(|_| Error::Pending))
            .transpose()?;
        Ok(prior.as_ref().is_none_or(|old| old.generation == "legacy"))
    }
    fn complete_pending(p: &mut Pending, journal: &mut Journal, root: &Dirs, incomplete: &mut Option<RestoreIncomplete>) -> Result<bool> {
        if matches!(
            p.phase,
            Phase::Restored | Phase::Restoring | Phase::PendingUnconfirmed
        ) {
            restore(p, journal, root, incomplete)?;
        } else if committed_layout(p, root)? {
            if p.action == Action::Install {
                let row = p
                    .new
                    .iter_mut()
                    .find(|r| r.domain == "state")
                    .ok_or(Error::Pending)?;
                row.phase = MovePhase::MovedConfirmed;
            }
            p.phase = Phase::Committed;
            journal.save(p)?;
            verify_committed(p, root)?;
        } else {
            restore(p, journal, root, incomplete)?;
        }
        cleanup_owned(p, root)?;
        if p.phase == Phase::Restored {
            verify_restored(p, root)?;
        } else {
            verify_committed(p, root)?;
        }
        absence_terminal(p)
    }
    fn admit_previous(
        root: &Dirs,
        sid: &str,
        plan_bytes: &[u8],
        plan_sha256: &str,
    ) -> Result<(Option<(Installed, Vec<u8>)>, Option<Journal>)> {
        let pending = root.path.join(CONTROL).join("pending.json");
        let mut absence = false;
        let mut inherited = None;
        let mut terminal_prior = None;
        if exists(&pending)? {
            let mut journal = Journal::open(&pending, false)?;
            let mut p = journal.load()?;
            validate_pending(&p, root, sid)?;
            let mut incomplete = None;
            let completed = complete_pending(&mut p, &mut journal, root, &mut incomplete);
            if let Err(error) = completed {
                report_restore_incomplete(error, incomplete.as_ref());
            }
            if completed? {
                absence = true;
                if p.phase == Phase::Restored {
                    terminal_prior = p
                        .prior_state
                        .as_ref()
                        .map(|bytes| {
                            let state =
                                serde_json::from_slice(bytes).map_err(|_| Error::Pending)?;
                            Ok((state, bytes.clone()))
                        })
                        .transpose()?;
                }
                inherited = Some(journal);
            } else {
                journal.finish()?;
            }
        }
        let state_path = root.path.join(CONTROL).join("installed.json");
        let old = if absence {
            if exists(&state_path)? {
                return Err(Error::Pending);
            }
            terminal_prior
        } else if exists(&state_path)? {
            let mut leased = derived_origin(observe(&state_path, "installed.json", true), Some(DerivedOrigin::ManagedStateParent))?;
            let mut bytes = Vec::new();
            leased
                .file
                .seek(SeekFrom::Start(0))
                .map_err(|_| Error::Pending)?;
            leased
                .file
                .read_to_end(&mut bytes)
                .map_err(|_| Error::Pending)?;
            let mut state: Installed = serde_json::from_slice(&bytes).map_err(|_| Error::Plan)?;
            state.state_member = Some(leased.member.clone());
            validate_installed(&state, root, sid)?;
            if derived_origin(read_plain(&root.path.join(PLAN_FILE)), Some(DerivedOrigin::ManagedPlanParent))? != state.plan_bytes {
                return Err(Error::Member);
            }
            for member in &state.members {
                derived_origin(exact(&root.path.join(&member.path), member, true), Some(DerivedOrigin::ManagedMemberParent))?;
            }
            for link in &state.shortcuts {
                if let Some(mut held) = owned_shortcut_or_absent(link)? {
                    verify_link_held(&mut held, &root.path.join("winsmux-app.exe"))?;
                }
            }
            for row in &state.preserved {
                exact(&preserved_path(&root.path, &row.kind)?, &row.member, true)?;
            }
            for (id, value) in state.registration.iter().enumerate() {
                if read_slot(id as u32)? != *value {
                    return Err(Error::Registration);
                }
            }
            Some((state, bytes))
        } else if fs::read_dir(&root.path)
            .map_err(|_| Error::Path(152))?
            .next()
            .is_some()
            && legacy_profile_claims(root)?
        {
            Some(admit_legacy(root, sid, plan_bytes, plan_sha256)?)
        } else {
            // A used root the captured legacy profile does not name is a first install. Its entries
            // stay untouched and any collision with a member path is refused later as Occupied.
            None
        };
        let preserved_kinds: Vec<String> = old
            .as_ref()
            .map(|(state, _)| state.preserved.iter().map(|row| row.kind.clone()).collect())
            .unwrap_or_default();
        admit_control_namespace(root, inherited.as_ref(), &preserved_kinds)?;
        Ok((old, inherited))
    }
    /// A product link another installer deleted from its known folder is already in the state an
    /// uninstall would leave, and an update publishes it again, so its absence is admitted while the
    /// recorded folder still resolves there. A state with no folder record cannot tell a deleted link
    /// from a moved folder, so there the absent link stays unconfirmed. The recorded file with other
    /// content (the user edited it in place) is unconfirmed. A different file at that path is foreign
    /// and the user moves it away. The parked link stays untouched.
    fn owned_shortcut_or_absent(link: &Shortcut) -> Result<Option<Observed>> {
        let path = recorded_shortcut(&link.kind, link.folder.as_deref())?;
        if !exists(&path)? {
            return if link.folder.is_some() { Ok(None) } else { Err(Error::Member) };
        }
        let origin = shortcut_origin(&link.kind, DerivedOrigin::ManagedDesktopParent, DerivedOrigin::ManagedProgramsParent);
        let seen = derived_origin(observe(&path, &link.member.path, true), origin)?;
        if seen.member == link.member {
            Ok(Some(seen))
        } else if seen.member.identity == link.member.identity {
            Err(Error::Member)
        } else {
            Err(Error::Occupied)
        }
    }
    fn legacy_profile_claims(root: &Dirs) -> Result<bool> {
        Ok(legacy()?
            .registration_profile
            .as_ref()
            .is_some_and(|profile| same_path(Path::new(&profile.root), &root.path)))
    }
    fn source_rows(
        ctx: &Context,
        plan: &crate::desktop_install::InstallPlan,
    ) -> Result<Vec<(String, String, PathBuf, Member)>> {
        let mut rows: Vec<(String, String, PathBuf)> = Vec::new();
        if ctx.action == Action::Install {
            for row in &plan.files {
                let p = ctx.source.join(&row.path);
                let seen = derived_origin(observe(&p, &row.path, false), Some(DerivedOrigin::SourceMemberParent))?;
                if seen.member.bytes != row.bytes || seen.member.sha256 != row.sha256 {
                    return Err(Error::Member);
                }
                rows.push(("root".into(), row.path.clone(), p));
            }
            rows.push(("root".into(), PLAN_FILE.into(), ctx.source.join(PLAN_FILE)));
            let un = ctx.source.join("uninstall.exe");
            let u = derived_origin(observe(&un, "uninstall.exe", false), Some(DerivedOrigin::SourceUninstallerParent))?;
            if u.member.bytes == 0 {
                return Err(Error::Member);
            }
            rows.push(("root".into(), "uninstall.exe".into(), un));
            for (kind, enabled) in [("start_menu", ctx.start_menu), ("desktop", ctx.desktop)] {
                if enabled {
                    let p = ctx.source.join("shortcuts").join(format!("{kind}.lnk"));
                    derived_origin(verify_link(&p, &ctx.root.join("winsmux-app.exe")), shortcut_origin(kind, DerivedOrigin::SourceDesktopDecodeParent, DerivedOrigin::SourceProgramsDecodeParent))?;
                    rows.push((kind.into(), "winsmux.lnk".into(), p));
                }
            }
            let actual = tree(&ctx.source)?;
            let expected: HashSet<_> = rows
                .iter()
                .map(|(kind, rel, _)| {
                    if kind == "root" {
                        rel.clone()
                    } else {
                        format!("shortcuts/{kind}.lnk")
                    }
                })
                .collect();
            if actual != expected {
                return Err(Error::Member);
            }
        } else {
            let actual = tree(&ctx.source)?;
            if actual != HashSet::from([PLAN_FILE.into()]) {
                return Err(Error::Member);
            }
        }
        let bound = rows
            .into_iter()
            .map(|(domain, relative, path)| {
                let mut held = derived_origin(observe(&path, &relative, false), source_rebind_origin(&domain))?;
                if domain != "root" {
                    verify_link_held(&mut held, &ctx.root.join("winsmux-app.exe"))?;
                }
                let member = held.member.clone();
                Ok((domain, relative, path, member))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(bound)
    }
    fn admit_control_namespace(root: &Dirs, retained: Option<&Journal>, preserved_kinds: &[String]) -> Result<()> {
        let control = root.path.join(CONTROL);
        if !exists(&control)? {
            if !preserved_kinds.is_empty() {
                return Err(Error::Member);
            }
            return Ok(());
        }
        let _held = derived_origin(Dirs::open(&control), Some(DerivedOrigin::AdmitControl))?;
        let entries: HashSet<_> = fs::read_dir(&control)
            .map_err(|_| Error::Path(153))?
            .map(|e| e.map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect::<std::io::Result<_>>()
            .map_err(|_| Error::Path(154))?;
        if let Some(journal) = retained {
            if !same_path(&journal.path, &control.join("pending.json"))
                || !same_path(
                    &journal.path,
                    &canonical(journal.file.as_raw_handle() as HANDLE)?,
                )
            {
                return Err(Error::Pending);
            }
        }
        if entries.iter().any(|s| {
            !matches!(s.as_str(), "installed.json" | "ops" | "preserved")
                && !(s == "pending.json" && retained.is_some())
        }) {
            return Err(Error::Path(155));
        }
        let ops = control.join("ops");
        if exists(&ops)? {
            let _ops = derived_origin(Dirs::open(&ops), Some(DerivedOrigin::AdmitOps))?;
            if fs::read_dir(&ops)
                .map_err(|_| Error::Path(156))?
                .next()
                .is_some()
            {
                return Err(Error::Pending);
            }
        }
        // The parked area holds exactly the foreign links the owned state records, or nothing.
        let parked = control.join("preserved");
        let expected: HashSet<String> = preserved_kinds
            .iter()
            .map(|kind| format!("{kind}-winsmux.lnk"))
            .collect();
        if exists(&parked)? {
            let _parked = Dirs::open(&parked)?;
            let actual: HashSet<String> = fs::read_dir(&parked)
                .map_err(|_| Error::Path(156))?
                .map(|e| e.map(|e| e.file_name().to_string_lossy().into_owned()))
                .collect::<std::io::Result<_>>()
                .map_err(|_| Error::Path(154))?;
            if actual != expected {
                return Err(Error::Path(155));
            }
        } else if !expected.is_empty() {
            return Err(Error::Member);
        }
        Ok(())
    }
    fn run_transaction(
        ctx: &Context,
        root: &Dirs,
        sid: String,
        plan_bytes: Vec<u8>,
        plan: crate::desktop_install::InstallPlan,
        old: Option<(Installed, Vec<u8>)>,
        sources: Vec<(String, String, PathBuf, Member)>,
        inherited: Option<Journal>,
    ) -> Result<Receipt> {
        let total = if ctx.action == Action::Install {
            sources.iter().filter(|(d, _, _, _)| d == "root").try_fold(
                0u64,
                |sum, (_, _, path, expected)| {
                    {
                        derived_origin(exact(path, expected, false), Some(DerivedOrigin::TransactionSourceTotalParent))?;
                        sum.checked_add(expected.bytes)
                    }
                    .ok_or(Error::Plan)
                },
            )?
        } else {
            0
        };
        let desired = if ctx.action == Action::Install {
            desired_slots(&path_text(&root.path)?, ctx.language, total)?
        } else {
            vec![None; 22]
        };
        let mut slots = Vec::new();
        for (i, d) in desired.into_iter().enumerate() {
            let prior = read_slot(i as u32)?;
            if let Some((state, _)) = &old {
                if prior != state.registration[i] {
                    return Err(Error::Registration);
                }
            } else if prior.is_some() {
                return Err(Error::Registration);
            }
            slots.push(Slot {
                id: i as u32,
                prior,
                desired: d,
                phase: SlotPhase::Prepared,
            });
        }
        if ctx.action == Action::Uninstall {
            let prior = read_slot(22)?;
            if prior
                == Some(sz(&format!(
                    "\"{}\\winsmux-app.exe\"",
                    path_text(&root.path)?
                )))
            {
                slots.push(Slot {
                    id: 22,
                    prior,
                    desired: None,
                    phase: SlotPhase::Prepared,
                });
            }
        }
        let id = uuid::Uuid::new_v4().to_string();
        let control = root.path.join(CONTROL);
        let mut created_dirs = Vec::new();
        let _control = make_dirs_owned(&control, root, &mut created_dirs)?;
        let ops = make_dirs_owned(&control.join("ops"), root, &mut created_dirs)?;
        let control_identity = _control.id.clone();
        let ops_identity = ops.id.clone();
        let private = root.path.join(CONTROL).join("ops").join(&id);
        if exists(&private)? {
            return Err(Error::Path(157));
        }
        let mut import_guard = ImportGuard {
            root,
            id: id.clone(),
            rows: Vec::new(),
            hold: Some(make_dirs_owned(&private, root, &mut created_dirs)?),
            dirs: created_dirs,
            control_identity: control_identity.clone(),
            ops_identity: ops_identity.clone(),
            armed: true,
        };
        let mut old_rows = Vec::new();
        let prior_state = old.as_ref().map(|(_, bytes)| bytes.clone());
        if let Some((state, _)) = &old {
            for m in &state.members {
                old_rows.push(Move {
                    member: m.clone(),
                    domain: "root".into(),
                    phase: MovePhase::Prepared,
                    folder: None,
                });
            }
            if ctx.action == Action::Uninstall {
                // A product link already gone from its known folder has no row: there is nothing to
                // back up or remove, and the parked link below returns to the free path.
                for link in &state.shortcuts {
                    let path = recorded_shortcut(&link.kind, link.folder.as_deref())?;
                    if exists(&path)? {
                        old_rows.push(Move {
                            member: link.member.clone(),
                            domain: link.kind.clone(),
                            phase: MovePhase::Prepared,
                            folder: Some(shortcut_folder(&path)?),
                        });
                    }
                }
            }
            if state.generation == "managed" {
                old_rows.push(Move {
                    member: state.state_member.clone().ok_or(Error::Pending)?,
                    domain: "state".into(),
                    phase: MovePhase::Prepared,
                    folder: None,
                });
            }
        }
        let mut new_rows = Vec::new();
        if ctx.action == Action::Install {
            for (domain, relative, from, admitted) in sources {
                derived_origin(exact(&from, &admitted, false), Some(DerivedOrigin::TransactionSourceAdmitParent))?;
                let mut folder = None;
                if domain != "root" {
                    // An update keeps a product link that is still in place and publishes one that is gone.
                    let kept = old.as_ref().and_then(|(state, _)| state.shortcuts.iter().find(|s| s.kind == domain));
                    if let Some(link) = kept {
                        if exists(&recorded_shortcut(&domain, link.folder.as_deref())?)? {
                            continue;
                        }
                    }
                    folder = Some(shortcut_folder(&known_shortcut(&domain)?)?);
                }
                let row = Move {
                    member: Member {
                        path: relative.clone(),
                        bytes: 0,
                        sha256: String::new(),
                        identity: root.id.clone(),
                    },
                    domain,
                    phase: MovePhase::Prepared,
                    folder,
                };
                let path = private_path(&root.path, &id, "new", &row);
                import_guard.rows.push(row.clone());
                let mut m = copy_new(&from, &path, root, &admitted, &mut import_guard.dirs)?;
                if m.bytes != admitted.bytes || m.sha256 != admitted.sha256 {
                    return Err(Error::Member);
                }
                m.path = relative;
                let complete = Move { member: m, ..row };
                *import_guard.rows.last_mut().ok_or(Error::Io)? = complete.clone();
                new_rows.push(complete);
            }
        }
        if ctx.action == Action::Install {
            let members: Vec<_> = new_rows
                .iter()
                .filter(|r| r.domain == "root")
                .map(|r| r.member.clone())
                .collect();
            member_inventory_valid(&members, &plan_bytes, &sha256_hex(&ctx.plan_sha256))?;
        }
        let mut preserved_rows = Vec::new();
        if ctx.action == Action::Install {
            for row in &new_rows {
                let live = live_path(&root.path, row)?;
                // An update's root members are old rows at the same paths; only a path nobody owns is judged.
                if !exists(&live)? || row_holds(&old_rows, &live, |m| live_path(&root.path, m), false) {
                    continue;
                }
                if !matches!(row.domain.as_str(), "desktop" | "start_menu") {
                    return Err(Error::Occupied);
                }
                // A same-name link that another install owns is parked intact and comes back on uninstall.
                // One on another volume cannot be moved intact, so the user moves it away instead.
                let seen = observe(&live, "winsmux.lnk", true)?;
                if seen.member.identity.volume != root.id.volume {
                    return Err(Error::Occupied);
                }
                preserved_rows.push(Move {
                    member: seen.member.clone(),
                    domain: row.domain.clone(),
                    phase: MovePhase::Prepared,
                    folder: row.folder.clone(),
                });
            }
        } else if let Some((state, _)) = &old {
            preserved_rows.extend(state.preserved.iter().map(preserved_move));
        }
        let mut paths = Vec::new();
        for row in old_rows.iter().chain(&new_rows) {
            paths.extend([
                live_path(&root.path, row)?,
                private_path(&root.path, &id, "old", row),
                private_path(&root.path, &id, "new", row),
            ]);
        }
        for row in &preserved_rows {
            let (from, to) = preserved_endpoints(&root.path, ctx.action, row)?;
            paths.extend([from, to]);
        }
        paths.extend([control.join("installed.json"), control.join("pending.json")]);
        // Every potential forward/inverse parent exists and is owned before Prepared.
        for target in &paths {
            let parent = target.parent().ok_or(Error::Path(158))?;
            if parent.starts_with(&root.path) {
                make_dirs_owned(parent, root, &mut import_guard.dirs)?;
            }
        }
        let _volumes = admit_volume(root, &paths)?;
        no_running(&root.path)?;
        for row in &old_rows {
            let held = derived_origin(exact(&live_path(&root.path, row)?, &row.member, true), Some(DerivedOrigin::TransactionOldLiveParent))?;
            flush_handle(held.file.as_raw_handle() as HANDLE)?;
            held._parents.flush()?;
        }
        for row in &new_rows {
            derived_origin(exact(
                &private_path(&root.path, &id, "new", row),
                &row.member,
                true,
            ), Some(DerivedOrigin::TransactionNewPrivateParent))?;
            let live = live_path(&root.path, row)?;
            if exists(&live)?
                && !row_holds(&old_rows, &live, |m| live_path(&root.path, m), false)
                && !row_holds(&preserved_rows, &live, |m| live_path(&root.path, m), false)
            {
                return Err(Error::Occupied);
            }
        }
        for row in &preserved_rows {
            let (from, _) = preserved_endpoints(&root.path, ctx.action, row)?;
            exact(&from, &row.member, true)?;
        }
        let mut p = Pending {
            schema: "winsmux-desktop-nsis-pending/v1".into(),
            operation_id: id.clone(),
            action: ctx.action,
            actor_sid: sid.clone(),
            root: path_text(&root.path)?,
            root_identity: root.id.clone(),
            plan_sha256: sha256_hex(&ctx.plan_sha256),
            plan_bytes,
            prior_state,
            old: old_rows,
            new: new_rows,
            preserved: preserved_rows,
            slots,
            phase: Phase::Prepared,
            commit_bytes: None,
            journal_identity: None,
            control_identity,
            ops_identity,
            owned_dirs: import_guard.dirs.clone(),
        };
        if ctx.action == Action::Install {
            p.commit_bytes =
                Some(serde_json::to_vec(&commit_state(&p, root)?).map_err(|_| Error::Plan)?);
            let row = Move {
                member: Member {
                    path: "installed.json".into(),
                    bytes: 0,
                    sha256: String::new(),
                    identity: root.id.clone(),
                },
                domain: "state".into(),
                phase: MovePhase::Prepared,
                folder: None,
            };
            let path = private_path(&root.path, &id, "new", &row);
            import_guard.rows.push(row.clone());
            let member = stage_state(
                p.commit_bytes.as_ref().unwrap(),
                &path,
                root,
                &mut import_guard.dirs,
            )?;
            let row = Move { member, ..row };
            *import_guard.rows.last_mut().ok_or(Error::Io)? = row.clone();
            p.new.push(row);
        }
        for row in p.old.iter().chain(&p.new) {
            for area in ["old", "new"] {
                let target = private_path(&root.path, &id, area, row);
                make_dirs_owned(
                    target.parent().ok_or(Error::Path(159))?,
                    root,
                    &mut import_guard.dirs,
                )?;
            }
        }
        p.owned_dirs = import_guard.dirs.clone();
        let inherited_terminal = inherited.is_some();
        let mut journal = match inherited {
            Some(journal) => journal,
            None => Journal::open(&control.join("pending.json"), true)?,
        };
        p.journal_identity = Some(journal.id()?);
        validate_pending(&p, root, &sid)?;
        if inherited_terminal {
            let previous = journal.load()?;
            validate_pending(&previous, root, &sid)?;
            if !absence_terminal(&previous)? {
                return Err(Error::Pending);
            }
            if previous.phase == Phase::Restored {
                verify_restored(&previous, root)?;
            } else {
                verify_committed(&previous, root)?;
            }
            cut("journal_handoff_before")?;
            journal.save(&p)?;
            import_guard.armed = false;
            cut("journal_handoff_after")?;
        } else {
            journal.save(&p)?;
            import_guard.armed = false;
        }
        let mut startup_receipt = None;
        let result = (|| -> Result<()> {
            p.phase = Phase::BackingUp;
            journal.save(&p)?;
            for i in 0..p.old.len() {
                let row = p.old[i].clone();
                p.old[i].phase = MovePhase::MoveIntent;
                journal.save(&p)?;
                move_exact_with_origins(
                    &live_path(&root.path, &row)?,
                    &private_path(&root.path, &id, "old", &row),
                    &row.member,
                    root,
                    Some((DerivedOrigin::BackupOldMoveSource, DerivedOrigin::BackupOldMoveDestination, DerivedOrigin::BackupOldMoveReadback)),
                )?;
                p.old[i].phase = MovePhase::MovedConfirmed;
                journal.save(&p)?;
            }
            if ctx.action == Action::Install {
                publish_preserved(&mut p, &mut journal, root)?;
            }
            p.phase = Phase::Publishing;
            journal.save(&p)?;
            for i in 0..p.new.len() {
                let row = p.new[i].clone();
                if row.domain != "root" {
                    continue;
                }
                p.new[i].phase = MovePhase::MoveIntent;
                journal.save(&p)?;
                move_exact_with_origins(
                    &private_path(&root.path, &id, "new", &row),
                    &live_path(&root.path, &row)?,
                    &row.member,
                    root,
                    Some((DerivedOrigin::PublishRootMoveSource, DerivedOrigin::PublishRootMoveDestination, DerivedOrigin::PublishRootMoveReadback)),
                )?;
                p.new[i].phase = MovePhase::MovedConfirmed;
                journal.save(&p)?;
            }
            if ctx.action == Action::Install {
                let gui = plan
                    .files
                    .iter()
                    .find(|m| m.role == "gui")
                    .ok_or(Error::Plan)?;
                startup_receipt = Some(startup(crate::desktop_install::StartupVerifyRequest {
                    gui_path: root.path.join(&gui.path),
                    expected_gui_sha256: parse_sha256(&gui.sha256).map_err(|_| Error::Plan)?,
                    expected_version: VERSION.into(),
                    expected_actor_sid: sid.clone(),
                })?);
                p.phase = Phase::StartupVerified;
                journal.save(&p)?;
            }
            p.phase = Phase::Registering;
            journal.save(&p)?;
            for i in 0..p.new.len() {
                let row = p.new[i].clone();
                if !matches!(row.domain.as_str(), "desktop" | "start_menu") {
                    continue;
                }
                p.new[i].phase = MovePhase::MoveIntent;
                journal.save(&p)?;
                move_exact_with_origins(
                    &private_path(&root.path, &id, "new", &row),
                    &live_path(&root.path, &row)?,
                    &row.member,
                    root,
                    Some((DerivedOrigin::PublishShortcutMoveSource, DerivedOrigin::PublishShortcutMoveDestination, DerivedOrigin::PublishShortcutMoveReadback)),
                )?;
                p.new[i].phase = MovePhase::MovedConfirmed;
                journal.save(&p)?;
            }
            if ctx.action == Action::Uninstall {
                publish_preserved(&mut p, &mut journal, root)?;
            }
            for i in 0..p.slots.len() {
                let current = read_slot(p.slots[i].id)?;
                match slot_publish(&p.slots[i], &current) {
                    SlotDecision::Keep => {
                        p.slots[i].phase = SlotPhase::PublishedConfirmed;
                        journal.save(&p)?;
                    }
                    SlotDecision::WriteDesired => {
                        p.slots[i].phase = SlotPhase::WriteIntent;
                        journal.save(&p)?;
                        if read_slot(p.slots[i].id)? != p.slots[i].prior {
                            return Err(Error::Registration);
                        }
                        write_slot(p.slots[i].id, &p.slots[i].desired)?;
                        p.slots[i].phase = SlotPhase::PublishedConfirmed;
                        journal.save(&p)?;
                    }
                    _ => return Err(Error::Registration),
                }
            }
            for m in p.new.iter().filter(|m| m.domain != "state") {
                derived_origin(exact(&live_path(&root.path, m)?, &m.member, false), Some(DerivedOrigin::PublishedMemberParent))?;
            }
            for s in &p.slots {
                if read_slot(s.id)? != s.desired {
                    return Err(Error::Registration);
                }
            }
            root.reobserve()?;
            p.phase = Phase::CommitIntent;
            journal.save(&p)?;
            if ctx.action == Action::Install {
                let index = p
                    .new
                    .iter()
                    .position(|r| r.domain == "state")
                    .ok_or(Error::Pending)?;
                p.new[index].phase = MovePhase::MoveIntent;
                journal.save(&p)?;
                let row = p.new[index].clone();
                cut("commit_before")?;
                move_exact_with_origins(
                    &private_path(&root.path, &id, "new", &row),
                    &live_path(&root.path, &row)?,
                    &row.member,
                    root,
                    Some((DerivedOrigin::CommitStateMoveSource, DerivedOrigin::CommitStateMoveDestination, DerivedOrigin::CommitStateMoveReadback)),
                )?;
                cut("commit_after")?;
                p.new[index].phase = MovePhase::MovedConfirmed;
                journal.save(&p)?;
            }
            p.phase = Phase::Committed;
            journal.save(&p)?;
            verify_committed(&p, root)?;
            Ok(())
        })();
        drop(_volumes);
        import_guard.hold.take();
        if let Err(error) = result {
            let mut incomplete = None;
            let absent = match complete_pending(&mut p, &mut journal, root, &mut incomplete) {
                Ok(absent) => absent,
                // The journal stays for the next run; the refusal that started the restore is the verdict.
                Err(restore_error) => {
                    report_restore_incomplete(restore_error, incomplete.as_ref());
                    return Err(error);
                }
            };
            if p.phase != Phase::Committed {
                if !absent {
                    cut("journal_finish_before")?;
                    journal.finish()?;
                }
                return Err(error);
            }
            if !absent {
                cut("journal_finish_before")?;
                journal.finish()?;
            }
        } else {
            verify_committed(&p, root)?;
            cleanup_owned(&p, root)?;
            if !absence_terminal(&p)? {
                cut("journal_finish_before")?;
                journal.finish()?;
            }
        }
        Ok(Receipt {
            schema: "winsmux-desktop-nsis-transaction-receipt/v1",
            operation_id: id,
            action: ctx.action,
            version: VERSION,
            plan_sha256: p.plan_sha256,
            startup_receipt,
            owned_registration_verified: true,
            durable_commit: true,
            outcome: "committed",
        })
    }
    fn publish_preserved(p: &mut Pending, journal: &mut Journal, root: &Dirs) -> Result<()> {
        for i in 0..p.preserved.len() {
            let row = p.preserved[i].clone();
            let (from, to) = preserved_endpoints(&root.path, p.action, &row)?;
            p.preserved[i].phase = MovePhase::MoveIntent;
            journal.save(p)?;
            move_exact_with_origins(&from, &to, &row.member, root, Some((DerivedOrigin::PublishPreservedMoveSource, DerivedOrigin::PublishPreservedMoveDestination, DerivedOrigin::PublishPreservedMoveReadback)))?;
            p.preserved[i].phase = MovePhase::MovedConfirmed;
            journal.save(p)?;
        }
        Ok(())
    }
    pub(super) fn run_context(action: Action, path: &Path) -> Result<Receipt> {
        let ctx = parse_context(&read_plain_role(path, PathRole::ContextArgumentParent)?, action)?;
        let sid = actor_sid()?;
        refuse_msi()?;
        let source = Dirs::open_role(&ctx.source, PathRole::ContextSource)?;
        let plan_bytes = derived_origin(read_plain(&ctx.source.join(PLAN_FILE)), Some(DerivedOrigin::SourcePlanParent))?;
        let plan = if action == Action::Install {
            checked_plan(&plan_bytes, &sha256_hex(&ctx.plan_sha256))?
        } else {
            checked_owned_plan(&plan_bytes, &sha256_hex(&ctx.plan_sha256))?
        };
        let helper = plan
            .files
            .iter()
            .find(|m| m.role == "cli")
            .ok_or(Error::Plan)?;
        let self_exe = std::env::current_exe().map_err(|_| Error::Member)?;
        let me = observe_role(&self_exe, "helper", false, PathRole::CurrentHelperParent)?;
        if me.member.bytes != helper.bytes || me.member.sha256 != helper.sha256 {
            return Err(Error::Member);
        }
        drop(me);
        let sources = source_rows(&ctx, &plan)?;
        source.reobserve()?;
        let parent = nearest(&ctx.root)?;
        let root_exists = exists(&ctx.root)?;
        if !root_exists {
            if action == Action::Uninstall {
                return Err(Error::Member);
            }
            fs::create_dir(&ctx.root).map_err(|e| diagnostic_io(&e))?;
        }
        let root = Dirs::open_role(&ctx.root, PathRole::ContextRoot)?;
        let _exclusion = exclusion(&root, &sid)?;
        if root.id.volume != parent.id.volume {
            return Err(Error::Path(160));
        }
        no_running(&root.path)?;
        let (old, inherited) =
            admit_previous(&root, &sid, &plan_bytes, &sha256_hex(&ctx.plan_sha256))?;
        if action == Action::Uninstall && old.is_none() {
            return Err(Error::Member);
        }
        // All target slots, including new external links, are admitted before import.
        let control = root.path.join(CONTROL);
        let mut targets = vec![control.clone(), control.join("ops")];
        for (_, rel, _, _) in &sources {
            targets.push(root.path.join(rel));
        }
        for (kind, enabled) in [("desktop", ctx.desktop), ("start_menu", ctx.start_menu)] {
            if enabled {
                targets.push(known_shortcut(kind)?);
            }
        }
        if let Some((state, _)) = &old {
            for link in &state.shortcuts {
                targets.push(recorded_shortcut(&link.kind, link.folder.as_deref())?);
            }
            for row in &state.preserved {
                targets.push(recorded_shortcut(&row.kind, row.folder.as_deref())?);
                targets.push(preserved_path(&root.path, &row.kind)?);
            }
        }
        let _volume_holds = admit_volume(&root, &targets)?;
        run_transaction(&ctx, &root, sid, plan_bytes, plan, old, sources, inherited)
    }
    #[cfg(test)]
    mod transaction_tests {
        use super::*;
        struct Fixture {
            base: PathBuf,
            root: Dirs,
            ctx: Context,
            plan_bytes: Vec<u8>,
        }
        #[derive(Clone, Copy)]
        enum FullLicenseProfile { Current, OldManaged }
        fn full_rows(profile: FullLicenseProfile) -> Vec<crate::desktop_install::InstallMember> {
            match profile {
                FullLicenseProfile::Current => crate::desktop_install::current_license_inventory().unwrap().to_vec(),
                FullLicenseProfile::OldManaged => {
                    let fixed:Legacy=serde_json::from_str(LEGACY).unwrap();
                    fixed.files.into_iter().filter(|row|row.role=="license").collect()
                }
            }
        }
        fn full_payload(profile: FullLicenseProfile, row: &crate::desktop_install::InstallMember) -> Vec<u8> {
            // Test data supplies bytes only. Production embedded tuples remain the authority.
            let root=PathBuf::from(option_env!("WINSMUX_DESKTOP_LICENSE_FIXTURE_ROOT").expect("fixed full-license test inputs required"));
            let label=match profile {FullLicenseProfile::Current=>"current",FullLicenseProfile::OldManaged=>"old-managed"};
            let bytes=fs::read(root.join(label).join(&row.path)).unwrap();
            assert_eq!(bytes.len() as u64,row.bytes);assert_eq!(hash(&bytes),row.sha256);bytes
        }
        fn set_full_source(f:&mut Fixture,profile:FullLicenseProfile) {
            let mut value:serde_json::Value=serde_json::from_slice(&f.plan_bytes).unwrap();
            value["files"].as_array_mut().unwrap().retain(|row|row["role"]!="license");
            for row in full_rows(profile) {
                let bytes=full_payload(profile,&row);let file=f.ctx.source.join(&row.path);
                fs::create_dir_all(file.parent().unwrap()).unwrap();fs::write(file,bytes).unwrap();
                value["files"].as_array_mut().unwrap().push(serde_json::json!({"role":"license","path":row.path,"bytes":row.bytes,"sha256":row.sha256}));
            }
            f.plan_bytes=serde_json::to_vec(&value).unwrap();f.ctx.plan_sha256=Sha256::digest(&f.plan_bytes).into();
            fs::write(f.ctx.source.join(PLAN_FILE),&f.plan_bytes).unwrap();
        }
        fn seed_old_managed(f:&Fixture) {
            assert!(checked_plan(&f.plan_bytes,&hash(&f.plan_bytes)).is_err());
            let plan=checked_owned_plan(&f.plan_bytes,&hash(&f.plan_bytes)).unwrap();
            let (previous,inherited)=admit_previous(&f.root,"S-1-5-21-100",&f.plan_bytes,&hash(&f.plan_bytes)).unwrap();
            let sources=source_rows(&f.ctx,&plan).unwrap();
            // Reconstruct a historical owned transaction; this does not admit an old incoming install.
            run_transaction(&f.ctx,&f.root,"S-1-5-21-100".into(),f.plan_bytes.clone(),plan,previous,sources,inherited).unwrap();
            let state=old(f).unwrap().0;
            assert!(checked_owned_plan(&state.plan_bytes,&state.plan_sha256).is_ok());
        }
        fn full_legacy_setup(f:&Fixture) {
            let mut baseline:Legacy=serde_json::from_str(LEGACY).unwrap();
            for row in &mut baseline.files {
                let bytes=if row.role=="license" {full_payload(FullLicenseProfile::OldManaged,row)} else {format!("old full legacy Mock {}",row.path).into_bytes()};
                let file=f.root.path.join(&row.path);fs::create_dir_all(file.parent().unwrap()).unwrap();fs::write(file,&bytes).unwrap();
                row.bytes=bytes.len() as u64;row.sha256=hash(&bytes);
            }
            let mut registration=vec![None;22];registration[0]=Some(sz("old full legacy Mock"));registration[4]=Some(sz(&path_text(&f.root.path).unwrap()));
            baseline.registration_profile=Some(LegacyProfile{root:path_text(&f.root.path).unwrap(),language:None,registration:registration.clone(),shortcuts:Vec::new()});
            hooks::MOCK.with(|m|{let mut m=m.borrow_mut();let mock=m.as_mut().unwrap();mock.slots[..22].clone_from_slice(&registration);mock.legacy=Some(baseline)});
        }
        fn full_mode_fixture(mode:&str)->Fixture {
            let mut f=fixture();
            match mode {
                "fresh"=>set_full_source(&mut f,FullLicenseProfile::Current),
                "managed-current"=>{set_full_source(&mut f,FullLicenseProfile::Current);execute(&f).unwrap();},
                "managed-old"=>{set_full_source(&mut f,FullLicenseProfile::OldManaged);seed_old_managed(&f);set_full_source(&mut f,FullLicenseProfile::Current);},
                "legacy-old"=>{set_full_source(&mut f,FullLicenseProfile::Current);full_legacy_setup(&f);},
                _=>panic!("unknown full fixture mode"),
            }
            reset_steps(None,false);f
        }
        fn add_project(f:&Fixture) {
            fs::create_dir_all(f.root.path.join("project/src")).unwrap();fs::write(f.root.path.join("project/src/sentinel.txt"),b"user project preserved").unwrap();
            fs::write(f.root.path.join("unknown-user-file.bin"),b"unknown bytes preserved").unwrap();
        }
        fn assert_project(f:&Fixture) {
            assert_eq!(fs::read(f.root.path.join("project/src/sentinel.txt")).unwrap(),b"user project preserved");
            assert_eq!(fs::read(f.root.path.join("unknown-user-file.bin")).unwrap(),b"unknown bytes preserved");
        }
        fn profile_state(f:&Fixture,current:bool) {
            let state=old(f).unwrap().0;
            let plan=checked_owned_plan(&state.plan_bytes,&state.plan_sha256).unwrap();
            assert_eq!(validate_current_license_inventory(&plan.files).is_ok(),current);
            assert_previous(f,&state);
        }
        #[test]
        #[ignore = "requires fixed authentic current/old license byte fixture"]
        fn current_plan_authority_family_full_install_update_and_uninstall() {
            for mode in ["fresh"] {
                let mut f=full_mode_fixture(mode);
                if mode!="fresh" {add_project(&f);}
                assert!(execute(&f).unwrap().durable_commit);profile_state(&f,true);
                if mode=="fresh" {add_project(&f);}
                assert_project(&f);assert!(execute(&f).unwrap().durable_commit);profile_state(&f,true);assert_project(&f);
                f.ctx.action=Action::Uninstall;
                assert!(execute(&f).unwrap().durable_commit);assert_project(&f);
                assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
                for row in full_rows(FullLicenseProfile::Current) {assert!(!exists(&f.root.path.join(row.path)).unwrap());}
                assert!(hooks::MOCK.with(|m|m.borrow().as_ref().unwrap().slots.iter().all(Option::is_none)));
            }
            let mut old_fixture=fixture();set_full_source(&mut old_fixture,FullLicenseProfile::OldManaged);seed_old_managed(&old_fixture);
            add_project(&old_fixture);old_fixture.ctx.action=Action::Uninstall;
            assert!(execute(&old_fixture).unwrap().durable_commit);assert_project(&old_fixture);
        }
        fn fail_at_full_phase(call:impl FnOnce()->Result<()>,phase:Option<Phase>,label:&'static str) {
            hooks::MOCK.with(|m|m.borrow_mut().as_mut().unwrap().barrier=Some(Box::new(move|seen|{
                let matches=phase.is_none_or(|phase|hooks::MOCK.with(|m|m.borrow().as_ref().unwrap().proof_key.starts_with(&format!("{phase:?}|"))));
                if seen==label&&matches {std::panic::panic_any("full profile phase cut");}
            })));
            assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(call)).is_err());
            hooks::MOCK.with(|m|m.borrow_mut().as_mut().unwrap().barrier=None);reset_steps(None,false);
        }
        fn crash_full_phase(f:&Fixture,phase:Phase) {
            fail_at_full_phase(||execute(f).map(|_|()),Some(phase),"journal_after");
        }
        #[test]
        #[ignore = "requires fixed authentic current/old license byte fixture"]
        fn current_plan_authority_family_publishing_commit_and_restore_reentry() {
            for mode in ["managed-current","managed-old","legacy-old"] {
                for phase in [Phase::Publishing,Phase::CommitIntent] {
                    let f=full_mode_fixture(mode);add_project(&f);
                    let prior=admit_previous(&f.root,"S-1-5-21-100",&f.plan_bytes,&hash(&f.plan_bytes)).unwrap().0.unwrap().0;
                    crash_full_phase(&f,phase);
                    let pending=read_plain(&f.root.path.join(CONTROL).join("pending.json")).unwrap();
                    let envelope:JournalEnvelope=serde_json::from_slice(&pending).unwrap();assert_eq!(envelope.payload.phase,phase);
                    recover_if_readable(&f).unwrap();assert_project(&f);assert_previous(&f,&prior);
                    assert!(execute(&f).unwrap().durable_commit);profile_state(&f,true);assert_project(&f);
                }
                // State publication happened, but its confirmation journal did not: confirm the actual current commit.
                let committed=full_mode_fixture(mode);add_project(&committed);
                fail_at_full_phase(||execute(&committed).map(|_|()),None,"commit_after");
                recover_if_readable(&committed).unwrap();profile_state(&committed,true);assert_project(&committed);
                let mut f=full_mode_fixture(mode);add_project(&f);let prior=admit_previous(&f.root,"S-1-5-21-100",&f.plan_bytes,&hash(&f.plan_bytes)).unwrap().0.unwrap().0;
                crash_full_phase(&f,Phase::Publishing);
                fail_at_full_phase(||recover_if_readable(&f),Some(Phase::Restoring),"journal_after");
                recover_if_readable(&f).unwrap();assert_previous(&f,&prior);assert_project(&f);
                assert!(execute(&f).unwrap().durable_commit);profile_state(&f,true);assert_project(&f);
                f.ctx.action=Action::Uninstall;assert!(execute(&f).unwrap().durable_commit);assert_project(&f);
                assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            }
        }
        #[test]
        #[ignore = "requires fixed authentic current/old license byte fixture"]
        fn current_plan_authority_family_uninstall_restore_and_commit_confirmation() {
            for phase in [Phase::Publishing,Phase::CommitIntent] {
                let mut f=full_mode_fixture("managed-current");add_project(&f);let prior=old(&f).unwrap().0;
                f.ctx.action=Action::Uninstall;crash_full_phase(&f,phase);
                recover_if_readable(&f).unwrap();assert_project(&f);
                if phase==Phase::Publishing {assert_previous(&f,&prior);assert!(execute(&f).unwrap().durable_commit);}
                else {assert!(hooks::MOCK.with(|m|m.borrow().as_ref().unwrap().slots.iter().all(Option::is_none)));}
                assert_project(&f);assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            }
            let mut restoring=full_mode_fixture("managed-current");add_project(&restoring);let prior=old(&restoring).unwrap().0;
            restoring.ctx.action=Action::Uninstall;crash_full_phase(&restoring,Phase::Publishing);
            fail_at_full_phase(||recover_if_readable(&restoring),Some(Phase::Restoring),"journal_after");
            recover_if_readable(&restoring).unwrap();assert_previous(&restoring,&prior);assert_project(&restoring);
            assert!(execute(&restoring).unwrap().durable_commit);assert_project(&restoring);
            let mut committed=full_mode_fixture("managed-current");add_project(&committed);committed.ctx.action=Action::Uninstall;
            crash_full_phase(&committed,Phase::Committed);
            recover_if_readable(&committed).unwrap();assert_project(&committed);
            assert!(!exists(&committed.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert!(hooks::MOCK.with(|m|m.borrow().as_ref().unwrap().slots.iter().all(Option::is_none)));
        }
        fn forge_installed_profile(bytes:&[u8])->Vec<u8> {
            let mut state:Installed=serde_json::from_slice(bytes).unwrap();
            let mut plan:serde_json::Value=serde_json::from_slice(&state.plan_bytes).unwrap();
            let row=plan["files"].as_array_mut().unwrap().iter_mut().find(|row|row["role"]=="license").unwrap();
            let path=row["path"].as_str().unwrap().to_string();row["sha256"]="00".repeat(32).into();
            state.plan_bytes=serde_json::to_vec(&plan).unwrap();state.plan_sha256=hash(&state.plan_bytes);
            state.members.iter_mut().find(|row|row.path==path).unwrap().sha256="00".repeat(32);
            let plan_member=state.members.iter_mut().find(|row|row.path==PLAN_FILE).unwrap();plan_member.bytes=state.plan_bytes.len() as u64;plan_member.sha256=state.plan_sha256.clone();
            serde_json::to_vec(&state).unwrap()
        }
        fn full_tree_state(f:&Fixture)->Vec<Member> {
            let mut names:Vec<_>=tree(&f.root.path).unwrap().into_iter().collect();names.sort();
            names.into_iter().map(|name|observe(&f.root.path.join(&name),&name,false).unwrap().member.clone()).collect()
        }

        #[test]
        #[ignore = "requires fixed authentic current/old license byte fixture"]
        fn current_plan_authority_family_forged_persisted_profiles_refuse_without_mutation() {
            for mode in ["managed-current","managed-old"] {
                let f=full_mode_fixture(mode);add_project(&f);
                let state=old(&f).unwrap().0;let before=tree(&f.root.path).unwrap();
                let slots:Vec<_>=(0..23).map(|i|read_slot(i).unwrap()).collect();
                let forged:Installed=serde_json::from_slice(&forge_installed_profile(&serde_json::to_vec(&state).unwrap())).unwrap();
                assert!(validate_installed(&forged,&f.root,"S-1-5-21-100").is_err());
                assert_eq!(tree(&f.root.path).unwrap(),before);assert_eq!((0..23).map(|i|read_slot(i).unwrap()).collect::<Vec<_>>(),slots);assert_previous(&f,&state);
                let f=full_mode_fixture(mode);add_project(&f);crash_full_phase(&f,Phase::Publishing);
                let file=f.root.path.join(CONTROL).join("pending.json");let bytes=read_plain(&file).unwrap();let envelope:JournalEnvelope=serde_json::from_slice(&bytes).unwrap();let p=envelope.payload;let snapshot=full_tree_state(&f);let prior_slots:Vec<_>=(0..23).map(|i|read_slot(i).unwrap()).collect();
                for which in ["plan","prior","commit"] {
                    let mut bad=p.clone();
                    if which=="plan" {
                        let mut plan:serde_json::Value=serde_json::from_slice(&p.plan_bytes).unwrap();
                        plan["files"].as_array_mut().unwrap().iter_mut().find(|row|row["role"]=="license").unwrap()["sha256"]="00".repeat(32).into();
                        bad.plan_bytes=serde_json::to_vec(&plan).unwrap();bad.plan_sha256=hash(&bad.plan_bytes);
                    }
                    else if which=="prior" {bad.prior_state=Some(forge_installed_profile(p.prior_state.as_ref().unwrap()));}
                    else {bad.commit_bytes=Some(forge_installed_profile(p.commit_bytes.as_ref().unwrap()));}
                    assert!(validate_pending(&bad,&f.root,"S-1-5-21-100").is_err(),"forged {which}");
                    assert_eq!(read_plain(&file).unwrap(),bytes);assert_eq!(full_tree_state(&f),snapshot);assert_eq!((0..23).map(|i|read_slot(i).unwrap()).collect::<Vec<_>>(),prior_slots);assert_project(&f);
                }
                recover_if_readable(&f).unwrap();assert_project(&f);assert!(execute(&f).unwrap().durable_commit);
                // All original bytes and registration were checked immediately after the refused validator.
            }
        }

        fn identity_cut_selection(mode: &str) -> Vec<usize> {
            let trace = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().proof_trace.clone());
            let mut groups = std::collections::BTreeMap::<(String, String), Vec<usize>>::new();
            for (i, key) in trace.iter().enumerate() {
                groups.entry(key.clone()).or_default().push(i + 1);
            }
            let mut selected = std::collections::BTreeSet::new();
            for (_, positions) in &groups {
                selected.insert(positions[0]);
                selected.insert(*positions.last().unwrap());
            }
            eprintln!("identity class mode={} events={} transition_classes={} selected={} controlled+crash",mode,trace.len(),groups.len(),selected.len());
            selected.into_iter().collect()
        }
        fn identity_mode_cuts(bounded: bool) {
            for mode in ["fresh", "legacy", "managed"] {
                let good = mode_fixture(mode);
                let trace = operation_trace(&good);
                let cuts: Vec<usize> = if bounded {
                    identity_cut_selection(mode)
                } else {
                    (1..=trace.len()).collect()
                };
                for crash in [false, true] {
                    for at in &cuts {
                        let f = mode_fixture(mode);
                        let (prior, _) = admit_previous(
                            &f.root,
                            "S-1-5-21-100",
                            &f.plan_bytes,
                            &sha256_hex(&f.ctx.plan_sha256),
                        )
                        .unwrap();
                        let prior_raw: Vec<_> = (0..23).map(|i| read_slot(i).unwrap()).collect();
                        reset_steps(Some(*at), crash);
                        let _ =
                            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f)));
                        reset_steps(None, false);
                        assert_public_complete_or_absent(&f);
                        let pending_path = f.root.path.join(CONTROL).join("pending.json");
                        let raw_at_cut: Vec<_> = (0..23).map(|i| read_slot(i).unwrap()).collect();
                        let pending_at_cut = read_plain(&pending_path).ok().and_then(|bytes| {
                            serde_json::from_slice::<JournalEnvelope>(&bytes)
                                .ok()
                                .map(|e| e.payload)
                        });
                        let pending_bytes = read_plain(&pending_path).ok();
                        let recovery = recover_if_readable(&f);
                        if recovery.is_err() {
                            if let Some(pending) = &pending_at_cut {
                                assert!(
                                    pending
                                        .slots
                                        .iter()
                                        .any(|slot| slot.phase == SlotPhase::WriteIntent),
                                    "unexplained confirmed-journal refusal: {mode} cut {at} {}",
                                    trace[*at - 1]
                                );
                                for slot in &pending.slots {
                                    if slot.phase == SlotPhase::WriteIntent {
                                        assert_eq!(
                                            read_slot(slot.id).unwrap(),
                                            raw_at_cut[slot.id as usize]
                                        );
                                    }
                                }
                            } else {
                                // Before a readable first journal, no old/public
                                // mutation has happened. Unknown private bytes or an
                                // unreadable journal remain untouched and refused.
                                assert_eq!(
                                    (0..23).map(|i| read_slot(i).unwrap()).collect::<Vec<_>>(),
                                    prior_raw
                                );
                                if let Some((old, _)) = &prior {
                                    assert_previous(&f, old);
                                }
                            }
                            assert!(execute(&f).is_err());
                            if let Some(pending) = &pending_at_cut {
                                for slot in &pending.slots {
                                    if slot.phase == SlotPhase::WriteIntent {
                                        assert_eq!(
                                            read_slot(slot.id).unwrap(),
                                            raw_at_cut[slot.id as usize]
                                        );
                                    }
                                }
                            } else {
                                assert_eq!(read_plain(&pending_path).ok(), pending_bytes);
                            }
                        } else {
                            assert_public_complete_or_absent(&f);
                            if let Some((current, _)) = old(&f) {
                                for row in &current.members {
                                    exact(&f.root.path.join(&row.path), row, true).unwrap();
                                }
                            } else {
                                assert_eq!(
                                    (0..23).map(|i| read_slot(i).unwrap()).collect::<Vec<_>>(),
                                    prior_raw
                                );
                                if let Some((old, _)) = &prior {
                                    assert_previous(&f, old);
                                }
                                if exists(&pending_path).unwrap() {
                                    let mut journal = Journal::open(&pending_path, false).unwrap();
                                    let p = journal.load().unwrap();
                                    validate_pending(&p, &f.root, "S-1-5-21-100").unwrap();
                                    assert_eq!(p.phase, Phase::Restored);
                                    assert!(absence_terminal(&p).unwrap());
                                } else {
                                    // A controlled pre-journal stage error can leave the
                                    // exact old profile and no pending operation. The same
                                    // legacy classifier admits it again. A fresh root keeps
                                    // only the empty control namespace and stays a first install.
                                    assert_ne!(mode, "managed");
                                    let (previous, inherited) = admit_previous(
                                        &f.root,
                                        "S-1-5-21-100",
                                        &f.plan_bytes,
                                        &sha256_hex(&f.ctx.plan_sha256),
                                    )
                                    .unwrap();
                                    assert!(inherited.is_none());
                                    if mode == "legacy" {
                                        let (previous, _) = previous.unwrap();
                                        assert_eq!(previous.generation, "legacy");
                                        assert_previous(&f, &previous);
                                    } else {
                                        assert!(previous.is_none());
                                    }
                                }
                            }
                            assert!(execute(&f).unwrap().durable_commit, "{mode} cut {at}");
                        }
                    }
                }
            }
        }
        fn identity_uninstall_cuts(bounded: bool) {
            fn uninstall(f: &Fixture) -> Result<Receipt> {
                let mut ctx = f.ctx.clone();
                ctx.action = Action::Uninstall;
                let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
                let (previous, inherited) = admit_previous(
                    &f.root,
                    "S-1-5-21-100",
                    &f.plan_bytes,
                    &sha256_hex(&f.ctx.plan_sha256),
                )?;
                run_transaction(
                    &ctx,
                    &f.root,
                    "S-1-5-21-100".into(),
                    f.plan_bytes.clone(),
                    plan,
                    previous,
                    Vec::new(),
                    inherited,
                )
            }
            let good = fixture();
            execute(&good).unwrap();
            reset_steps(None, false);
            uninstall(&good).unwrap();
            let count = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps);
            let cuts: Vec<usize> = if bounded {
                identity_cut_selection("uninstall")
            } else {
                (1..=count).collect()
            };
            for crash in [false, true] {
                for at in cuts.iter().copied() {
                    let f = fixture();
                    execute(&f).unwrap();
                    let previous = old(&f).unwrap().0;
                    fs::write(
                        f.root.path.join("project-settings-sentinel"),
                        b"retain exact user bytes",
                    )
                    .unwrap();
                    reset_steps(Some(at), crash);
                    let result =
                        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| uninstall(&f)));
                    reset_steps(None, false);
                    let recovery = recover_if_readable(&f);
                    if recovery.is_ok() {
                        if let Some((current, _)) = old(&f) {
                            assert_eq!(current.operation_id, previous.operation_id);
                            assert_previous(&f, &previous);
                        } else {
                            for m in &previous.members {
                                assert!(!exists(&f.root.path.join(&m.path)).unwrap());
                            }
                            for id in 0..22 {
                                assert_eq!(read_slot(id).unwrap(), None);
                            }
                        }
                    } else {
                        assert!(
                            exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap()
                                || admit_control_namespace(&f.root, None, &[]) == Err(Error::Pending)
                        );
                    }
                    if recovery.is_ok() {
                        assert!(execute(&f).unwrap().durable_commit);
                    }
                    if let Ok(Ok(receipt)) = result {
                        assert!(receipt.durable_commit && receipt.startup_receipt.is_none());
                    }
                    assert_eq!(
                        fs::read(f.root.path.join("project-settings-sentinel")).unwrap(),
                        b"retain exact user bytes"
                    );
                }
            }
        }

        fn identity_test_link(path: &Path, target: &Path) {
            use windows_sys::{
                core::GUID,
                Win32::System::Com::{
                    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
                    COINIT_APARTMENTTHREADED,
                },
            };
            #[repr(C)]
            struct Obj {
                table: *const *const c_void,
            }
            #[repr(C)]
            struct Key {
                fmtid: GUID,
                pid: u32,
            }
            #[repr(C)]
            struct Value {
                vt: u16,
                res: [u16; 3],
                data: [usize; 2],
            }
            unsafe fn release(p: *mut Obj) {
                let f: unsafe extern "system" fn(*mut Obj) -> u32 =
                    std::mem::transmute(*(*p).table.add(2));
                f(p);
            }
            unsafe fn query(p: *mut Obj, id: &GUID) -> *mut Obj {
                let f: unsafe extern "system" fn(*mut Obj, *const GUID, *mut *mut c_void) -> i32 =
                    std::mem::transmute(*(*p).table);
                let mut out = null_mut();
                assert!(f(p, id, &mut out) >= 0);
                out.cast()
            }
            unsafe {
                assert!(CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) >= 0);
                let cls = GUID::from_u128(0x00021401_0000_0000_c000_000000000046);
                let iid = GUID::from_u128(0x000214f9_0000_0000_c000_000000000046);
                let mut out = null_mut();
                assert!(
                    CoCreateInstance(&cls, null_mut(), CLSCTX_INPROC_SERVER, &iid, &mut out) >= 0
                );
                let link: *mut Obj = out.cast();
                let set: unsafe extern "system" fn(*mut Obj, *const u16) -> i32 =
                    std::mem::transmute(*(*link).table.add(20));
                let name = wide(target.as_os_str()).unwrap();
                assert!(set(link, name.as_ptr()) >= 0);
                let store = query(
                    link,
                    &GUID::from_u128(0x886d8eeb_8cf2_4446_8d02_cdba1dbdcf99),
                );
                let key = Key {
                    fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3),
                    pid: 5,
                };
                let aumid = wide(OsStr::new("io.github.sora-bluesky.winsmux")).unwrap();
                let value = Value {
                    vt: 31,
                    res: [0; 3],
                    data: [aumid.as_ptr() as usize, 0],
                };
                let put: unsafe extern "system" fn(*mut Obj, *const Key, *const Value) -> i32 =
                    std::mem::transmute(*(*store).table.add(6));
                assert!(put(store, &key, &value) >= 0);
                let commit: unsafe extern "system" fn(*mut Obj) -> i32 =
                    std::mem::transmute(*(*store).table.add(7));
                assert!(commit(store) >= 0);
                let persist = query(
                    link,
                    &GUID::from_u128(0x0000010b_0000_0000_c000_000000000046),
                );
                let save: unsafe extern "system" fn(*mut Obj, *const u16, i32) -> i32 =
                    std::mem::transmute(*(*persist).table.add(6));
                let output = wide(path.as_os_str()).unwrap();
                assert!(!path.exists());
                assert!(save(persist, output.as_ptr(), 1) >= 0);
                release(persist);
                release(store);
                release(link);
                CoUninitialize();
            }
        }
        #[test]
        fn filesystem_identity_family_legacy_dynamic_shortcuts_stream_and_uninstall() {
            let mut f = fixture();
            legacy_fixture_setup(&f);
            let known = f.base.join("synthetic-known-folders");
            hooks::MOCK
                .with(|m| m.borrow_mut().as_mut().unwrap().shortcut_root = Some(known.clone()));
            let mut captured = Vec::new();
            for kind in ["desktop", "start_menu"] {
                let path = known.join(kind).join("winsmux.lnk");
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                identity_test_link(&path, &f.root.path.join("winsmux-app.exe"));
                let actual = observe(&path, "winsmux.lnk", false).unwrap().member;
                // Old VM link SHA remains provenance, never repinned into compiled JSON.
                let row:LegacyShortcut=serde_json::from_value(serde_json::json!({"kind":kind,"bytes":actual.bytes,"sha256":"00".repeat(32),"target":path_text(&f.root.path.join("winsmux-app.exe")).unwrap(),"aumid":"io.github.sora-bluesky.winsmux"})).unwrap();
                captured.push(row);
            }
            hooks::MOCK.with(|m| {
                m.borrow_mut()
                    .as_mut()
                    .unwrap()
                    .legacy
                    .as_mut()
                    .unwrap()
                    .registration_profile
                    .as_mut()
                    .unwrap()
                    .shortcuts = captured
            });
            let (admitted, _) = admit_legacy(
                &f.root,
                "S-1-5-21-100",
                &f.plan_bytes,
                &sha256_hex(&f.ctx.plan_sha256),
            )
            .unwrap();
            assert_eq!(admitted.shortcuts.len(), 2);
            for link in &admitted.shortcuts {
                assert_ne!(link.member.sha256, "00".repeat(32));
                let path = known_shortcut(&link.kind).unwrap();
                identity_barrier(
                    "link_stream_before",
                    path.clone(),
                    f.base.join(format!("park-{}", link.kind)),
                );
                let mut held = exact(&path, &link.member, true).unwrap();
                verify_link_held(&mut held, &f.root.path.join("winsmux-app.exe")).unwrap();
                hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            }
            execute(&f).unwrap();
            let installed = old(&f).unwrap().0;
            assert_eq!(installed.shortcuts, admitted.shortcuts);
            f.ctx.action = Action::Uninstall;
            execute(&f).unwrap();
            assert!(!known.join("desktop/winsmux.lnk").exists());
            assert!(!known.join("start_menu/winsmux.lnk").exists());
        }

        fn identity_barrier(label: &'static str, source: PathBuf, target: PathBuf) {
            hooks::MOCK.with(|m| {
                m.borrow_mut().as_mut().unwrap().barrier = Some(Box::new(move |at| {
                    if at == label {
                        let source = source.clone();
                        let target = target.clone();
                        let result = std::thread::spawn(move || {
                            let rename = fs::rename(&source, &target).unwrap_err().raw_os_error();
                            let write = OpenOptions::new()
                                .write(true)
                                .open(&source)
                                .unwrap_err()
                                .raw_os_error();
                            (rename, write)
                        })
                        .join()
                        .unwrap();
                        assert_eq!(result, (Some(32), Some(32)));
                    }
                }))
            });
        }
        #[test]
        fn filesystem_identity_family_positive_modes() {
            for mode in ["fresh", "legacy", "managed"] {
                let mut f = mode_fixture(mode);
                execute(&f).unwrap();
                execute(&f).unwrap();
                f.ctx.action = Action::Uninstall;
                execute(&f).unwrap();
                assert!(!f.root.path.join(CONTROL).join("installed.json").exists());
                f.ctx.action = Action::Install;
                execute(&f).unwrap();
            }
        }
        #[test]
        fn filesystem_identity_family_move_and_copy_object_authority() {
            let f = fixture();
            let p = f.root.path.join("object-P");
            let q = f.root.path.join("object-Q");
            fs::write(&p, b"owned P").unwrap();
            let row = observe(&p, "object-P", false).unwrap().member;
            identity_barrier("move_before", p.clone(), f.root.path.join("attacker-park"));
            move_exact(&p, &q, &row, &f.root).unwrap();
            assert_eq!(observe(&q, &row.path, false).unwrap().member, row);
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            fs::write(&p, b"foreign X").unwrap();
            let x = observe(&p, "X", false).unwrap().member;
            assert!(move_exact(&q, &p, &row, &f.root).is_err());
            assert_eq!(observe(&p, "X", false).unwrap().member, x);
            let original = f.root.path.join("preserved-original");
            fs::rename(&q, &original).unwrap();
            fs::write(&q, b"owned P").unwrap();
            let qx = observe(&q, &row.path, false).unwrap().member;
            assert_ne!(qx.identity, row.identity);
            assert!(move_exact(&q, &f.root.path.join("no-mutation"), &row, &f.root).is_err());
            assert_eq!(observe(&q, &row.path, false).unwrap().member, qx);
            let source = f.base.join("source/winsmux.exe");
            let admitted = observe(&source, "winsmux.exe", false).unwrap().member;
            let dest = f.root.path.join("copied-object");
            identity_barrier(
                "import_record_before",
                dest.clone(),
                f.root.path.join("copy-park"),
            );
            let mut dirs = Vec::new();
            let created = copy_new(&source, &dest, &f.root, &admitted, &mut dirs).unwrap();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            assert_eq!(observe(&dest, "new", false).unwrap().member, created);
            let parked = f.root.path.join("copy-original");
            fs::rename(&dest, &parked).unwrap();
            fs::copy(&parked, &dest).unwrap();
            assert!(exact(&dest, &created, true).is_err());
            assert_eq!(fs::read(&dest).unwrap(), fs::read(&parked).unwrap());
        }
        #[test]
        fn filesystem_identity_family_journal_substitution_and_digest() {
            let f = fixture();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().startup_fail = true);
            assert!(execute(&f).is_err());
            let pending = f.root.path.join(CONTROL).join("pending.json");
            let bytes = fs::read(&pending).unwrap();
            let mut j = Journal::open(&pending, false).unwrap();
            let state = j.load().unwrap();
            assert_eq!(state.journal_identity, Some(j.id().unwrap()));
            assert_eq!(fs::read(&pending).unwrap_err().raw_os_error(), Some(32));
            drop(j);
            let original = f.root.path.join("preserved-journal");
            fs::rename(&pending, &original).unwrap();
            fs::write(&pending, &bytes).unwrap();
            let foreign = observe(&pending, "pending.json", false).unwrap().member;
            assert!(admit_previous(
                &f.root,
                "S-1-5-21-100",
                &f.plan_bytes,
                &sha256_hex(&f.ctx.plan_sha256)
            )
            .is_err());
            assert_eq!(
                observe(&pending, "pending.json", false).unwrap().member,
                foreign
            );
            let moved = f.root.path.join("preserved-foreign-journal");
            fs::rename(&pending, &moved).unwrap();
            fs::rename(&original, &pending).unwrap();
            let mut envelope: JournalEnvelope = serde_json::from_slice(&bytes).unwrap();
            envelope.payload.phase = Phase::Committed;
            let altered = serde_json::to_vec(&envelope).unwrap();
            fs::write(&pending, &altered).unwrap();
            let changed = observe(&pending, "pending.json", false).unwrap().member;
            let mut j = Journal::open(&pending, false).unwrap();
            assert!(j.load().is_err());
            drop(j);
            assert_eq!(
                observe(&pending, "pending.json", false).unwrap().member,
                changed
            );
        }
        #[test]
        fn filesystem_identity_family_directory_authority_and_nonempty() {
            let f = fixture();
            let control = f.root.path.join(CONTROL);
            let mut dirs = Vec::new();
            let c = make_dirs_owned(&control, &f.root, &mut dirs).unwrap();
            let ops = make_dirs_owned(&control.join("ops"), &f.root, &mut dirs).unwrap();
            let id = uuid::Uuid::new_v4().to_string();
            let leaf = control.join("ops").join(&id);
            let held = make_dirs_owned(&leaf, &f.root, &mut dirs).unwrap();
            let original_id = held.id.clone();
            drop(held);
            let p = Pending {
                schema: String::new(),
                operation_id: id.clone(),
                action: Action::Install,
                actor_sid: String::new(),
                root: String::new(),
                root_identity: f.root.id.clone(),
                plan_sha256: String::new(),
                plan_bytes: Vec::new(),
                prior_state: None,
                old: Vec::new(),
                new: Vec::new(),
                preserved: Vec::new(),
                slots: Vec::new(),
                phase: Phase::Prepared,
                commit_bytes: None,
                journal_identity: None,
                control_identity: c.id.clone(),
                ops_identity: ops.id.clone(),
                owned_dirs: dirs,
            };
            let child = leaf.join("foreign-child");
            fs::write(&child, b"X child").unwrap();
            let x = observe(&child, "X", false).unwrap().member;
            assert!(cleanup_owned(&p, &f.root).is_err());
            assert_eq!(observe(&child, "X", false).unwrap().member, x);
            fs::rename(&child, f.root.path.join("preserved-child")).unwrap();
            let parked = f.root.path.join("preserved-directory");
            fs::rename(&leaf, &parked).unwrap();
            fs::create_dir(&leaf).unwrap();
            let foreign = Dirs::open(&leaf).unwrap().id;
            assert_ne!(foreign, original_id);
            assert!(cleanup_owned(&p, &f.root).is_err());
            assert_eq!(Dirs::open(&leaf).unwrap().id, foreign);
            assert!(make_dirs_owned(&leaf, &f.root, &mut Vec::new()).is_err());
            assert_eq!(Dirs::open(&parked).unwrap().id, original_id);
        }
        #[test]
        fn filesystem_identity_family_terminal_handoff() {
            commit_publication_family_terminal_handoff_and_uninstall_reentry();
        }
        #[test]
        fn filesystem_identity_family_three_modes_all_cuts() {
            identity_mode_cuts(true);
        }
        #[test]
        fn filesystem_identity_family_uninstall_all_cuts() {
            identity_uninstall_cuts(true);
        }

        #[test]
        fn filesystem_identity_family_post_delete_directory_reappearance() {
            // The existing long/alias boundary is repeated only for the new rename API.
            long_internal_paths_and_alias_boundaries_use_the_same_move_owner();
            let f = fixture();
            let control = f.root.path.join(CONTROL);
            let mut dirs = Vec::new();
            let c = make_dirs_owned(&control, &f.root, &mut dirs).unwrap();
            let ops = make_dirs_owned(&control.join("ops"), &f.root, &mut dirs).unwrap();
            let id = uuid::Uuid::new_v4().to_string();
            let leaf = control.join("ops").join(&id);
            let held = make_dirs_owned(&leaf, &f.root, &mut dirs).unwrap();
            let original_id = held.id.clone();
            drop(held);
            let p = Pending {
                schema: String::new(),
                operation_id: id,
                action: Action::Install,
                actor_sid: String::new(),
                root: String::new(),
                root_identity: f.root.id.clone(),
                plan_sha256: String::new(),
                plan_bytes: Vec::new(),
                prior_state: None,
                old: Vec::new(),
                new: Vec::new(),
                preserved: Vec::new(),
                slots: Vec::new(),
                phase: Phase::Prepared,
                commit_bytes: None,
                journal_identity: None,
                control_identity: c.id.clone(),
                ops_identity: ops.id.clone(),
                owned_dirs: dirs,
            };
            let foreign = std::sync::Arc::new(std::sync::Mutex::new(None));
            let captured = foreign.clone();
            let target = leaf.clone();
            let park = f.root.path.join("directory-park");
            hooks::MOCK.with(|m| {
                m.borrow_mut().as_mut().unwrap().barrier = Some(Box::new(move |label| {
                    if label == "cleanup_dir_before" {
                        let (source, dest) = (target.clone(), park.clone());
                        let error = std::thread::spawn(move || fs::rename(source, dest))
                            .join()
                            .unwrap()
                            .unwrap_err();
                        assert_eq!(error.raw_os_error(), Some(32));
                    }
                    let unobserved = { captured.lock().unwrap().is_none() };
                    if label == "cleanup_dir_after" && unobserved {
                        let source = target.clone();
                        let identity = std::thread::spawn(move || {
                            fs::create_dir(&source).unwrap();
                            Dirs::open(&source).unwrap().id.clone()
                        })
                        .join()
                        .unwrap();
                        *captured.lock().unwrap() = Some(identity);
                    }
                }));
            });
            assert_eq!(cleanup_owned(&p, &f.root).err(), Some(Error::Pending));
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            let x = foreign.lock().unwrap().clone().unwrap();
            assert_ne!(x, original_id);
            assert_eq!(Dirs::open(&leaf).unwrap().id, x);
            assert!(fs::read_dir(&leaf).unwrap().next().is_none());
            assert!(!exists(&f.root.path.join("directory-park")).unwrap());
            assert_eq!(cleanup_owned(&p, &f.root).err(), Some(Error::Pending));
            assert_eq!(Dirs::open(&leaf).unwrap().id, x);
            assert!(fs::read_dir(&leaf).unwrap().next().is_none());
            let mut recorded = p.owned_dirs.clone();
            assert!(make_dirs_owned(&leaf, &f.root, &mut recorded).is_err());
            assert_eq!(Dirs::open(&leaf).unwrap().id, x);
        }

        fn fixture() -> Fixture {
            let base = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .unwrap()
                .join("synthetic-native")
                .join(uuid::Uuid::new_v4().to_string());
            fixture_at(base)
        }
        fn fixture_at(base: PathBuf) -> Fixture {
            hooks::MOCK.with(|m| *m.borrow_mut() = None);
            fs::create_dir_all(base.join("source")).unwrap();
            fs::create_dir(base.join("installed")).unwrap();
            let root = Dirs::open(&base.join("installed")).unwrap();
            let license = legacy()
                .unwrap()
                .files
                .into_iter()
                .find(|r| r.role == "license")
                .unwrap()
                .path;
            let mut rows = Vec::new();
            for (role, path, bytes) in [
                ("gui", "winsmux-app.exe", b"synthetic gui".as_slice()),
                ("cli", "winsmux.exe", b"synthetic cli".as_slice()),
                (
                    "mcp",
                    "winsmux-workspace-mcp.exe",
                    b"synthetic mcp".as_slice(),
                ),
                ("license", license.as_str(), b"synthetic license".as_slice()),
            ] {
                let file = base.join("source").join(path);
                fs::create_dir_all(file.parent().unwrap()).unwrap();
                fs::write(&file, bytes).unwrap();
                rows.push(serde_json::json!({"role":role,"path":path,"bytes":bytes.len(),"sha256":hash(bytes)}));
            }
            let plan_bytes=serde_json::to_vec(&serde_json::json!({"schema":"winsmux-desktop-install-plan/v1","flavor":"nsis","version":VERSION,"host":HOST,"files":rows})).unwrap();
            fs::write(base.join("source").join(PLAN_FILE), &plan_bytes).unwrap();
            fs::write(
                base.join("source/uninstall.exe"),
                b"synthetic standard uninstaller",
            )
            .unwrap();
            let ctx = Context {
                action: Action::Install,
                root: root.path.clone(),
                source: base.join("source"),
                plan_sha256: Sha256::digest(&plan_bytes).into(),
                language: 1041,
                start_menu: false,
                desktop: false,
                update: false,
            };
            hooks::MOCK.with(|m| {
                *m.borrow_mut() = Some(hooks::Mock {
                    slots: vec![None; 23],
                    ..Default::default()
                })
            });
            Fixture {
                base,
                root,
                ctx,
                plan_bytes,
            }
        }
        fn legacy_fixture_setup(f: &Fixture) {
            // This thread-local input double exercises the fixed legacy admission
            // mechanism in the owned scratch. It is never a CI capture or runtime profile.
            let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
            let mut baseline = legacy().unwrap();
            baseline.files.clear();
            for row in &plan.files {
                let target = f.root.path.join(&row.path);
                fs::create_dir_all(target.parent().unwrap()).unwrap();
                let bytes = format!("old fixture {}", row.path).into_bytes();
                fs::write(&target, &bytes).unwrap();
                let mut member = row.clone();
                member.bytes = bytes.len() as u64;
                member.sha256 = hash(&bytes);
                baseline.files.push(member);
            }
            let bytes = b"old fixture uninstaller";
            fs::write(f.root.path.join("uninstall.exe"), bytes).unwrap();
            let mut uninstaller = plan.files[0].clone();
            uninstaller.role = "uninstaller".into();
            uninstaller.path = "uninstall.exe".into();
            uninstaller.bytes = bytes.len() as u64;
            uninstaller.sha256 = hash(bytes);
            baseline.files.push(uninstaller);
            let mut raw = vec![None; 22];
            raw[0] = Some(sz("old fixture product"));
            raw[4] = Some(sz(&path_text(&f.root.path).unwrap()));
            baseline.installed_inventory_complete = true;
            baseline.registration_profile = Some(LegacyProfile {
                root: path_text(&f.root.path).unwrap(),
                language: None,
                registration: raw.clone(),
                shortcuts: Vec::new(),
            });
            hooks::MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let mock = m.as_mut().unwrap();
                mock.slots[..22].clone_from_slice(&raw);
                mock.legacy = Some(baseline);
            });
        }
        fn mode_fixture(mode: &str) -> Fixture {
            let f = fixture();
            match mode {
                "fresh" => {}
                "legacy" => legacy_fixture_setup(&f),
                "managed" => {
                    execute(&f).unwrap();
                }
                _ => panic!("unknown fixture mode"),
            }
            reset_steps(None, false);
            f
        }
        fn old(f: &Fixture) -> Option<(Installed, Vec<u8>)> {
            let p = f.root.path.join(CONTROL).join("installed.json");
            if !exists(&p).unwrap() {
                return None;
            }
            let mut held = observe(&p, "installed.json", true).unwrap();
            let mut bytes = Vec::new();
            held.file.seek(SeekFrom::Start(0)).unwrap();
            held.file.read_to_end(&mut bytes).unwrap();
            let mut s: Installed = serde_json::from_slice(&bytes).unwrap();
            s.state_member = Some(held.member.clone());
            validate_installed(&s, &f.root, "S-1-5-21-100").unwrap();
            Some((s, bytes))
        }
        fn execute(f: &Fixture) -> Result<Receipt> {
            let (previous, inherited) = admit_previous(
                &f.root,
                "S-1-5-21-100",
                &f.plan_bytes,
                &sha256_hex(&f.ctx.plan_sha256),
            )?;
            let plan = if f.ctx.action == Action::Install {
                checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap()
            } else {
                checked_owned_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap()
            };
            let sources = if f.ctx.action == Action::Install {
                source_rows(&f.ctx, &plan)?
            } else {
                Vec::new()
            };
            run_transaction(
                &f.ctx,
                &f.root,
                "S-1-5-21-100".into(),
                f.plan_bytes.clone(),
                plan,
                previous,
                sources,
                inherited,
            )
        }
        fn reset_steps(fail: Option<usize>, crash: bool) {
            hooks::MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let m = m.as_mut().unwrap();
                m.steps = 0;
                m.fail = fail;
                m.crash = crash;
                m.trace.clear();
                m.proof_trace.clear();
                m.proof_key.clear();
                m.final_name_refusal = false;
                m.reports.clear();
            });
        }
        fn reports() -> Vec<String> {
            hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().reports.clone())
        }
        fn assert_previous(f: &Fixture, state: &Installed) {
            for m in &state.members {
                exact(&f.root.path.join(&m.path), m, true).unwrap();
            }
            for (i, v) in state.registration.iter().enumerate() {
                assert_eq!(read_slot(i as u32).unwrap(), *v);
            }
        }
        fn recover_if_readable(f: &Fixture) -> Result<()> {
            admit_previous(
                &f.root,
                "S-1-5-21-100",
                &f.plan_bytes,
                &sha256_hex(&f.ctx.plan_sha256),
            )
            .map(|_| ())
        }
        fn operation_trace(f: &Fixture) -> Vec<String> {
            reset_steps(None, false);
            execute(f).unwrap();
            hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().trace.clone())
        }
        fn crash_at(f: &Fixture, at: usize) {
            reset_steps(Some(at), true);
            assert!(std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(f))).is_err());
            reset_steps(None, false);
        }
        fn assert_public_complete_or_absent(f: &Fixture) {
            let state = f.root.path.join(CONTROL).join("installed.json");
            if exists(&state).unwrap() {
                let bytes = read_plain(&state).unwrap();
                assert!(!bytes.is_empty());
                let installed: Installed = serde_json::from_slice(&bytes).unwrap();
                validate_installed(&installed, &f.root, "S-1-5-21-100").unwrap();
            }
        }
        #[test]
        fn commit_publication_family_reentry_all_modes() {
            identity_mode_cuts(false);
        }
        #[test]
        fn commit_publication_family_interrupted_restore_and_cleanup_reentry() {
            for mode in ["fresh", "legacy", "managed"] {
                let good = mode_fixture(mode);
                let trace = operation_trace(&good);
                let before = trace.iter().position(|l| l == "commit_before").unwrap() + 1;
                let probe = mode_fixture(mode);
                crash_at(&probe, before);
                recover_if_readable(&probe).unwrap();
                let recovery_trace =
                    hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().trace.clone());
                let mut cuts = std::collections::BTreeSet::new();
                for (i, label) in recovery_trace.iter().enumerate() {
                    if label.starts_with("move_")
                        || label.starts_with("cleanup_")
                        || label.starts_with("journal_finish_")
                    {
                        cuts.insert(i + 1);
                        if i > 0 && recovery_trace[i - 1].starts_with("journal_") {
                            cuts.insert(i);
                        }
                    }
                }
                assert!(!cuts.is_empty());
                for at in cuts {
                    let f = mode_fixture(mode);
                    crash_at(&f, before);
                    reset_steps(Some(at), true);
                    assert!(
                        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            recover_if_readable(&f)
                        }))
                        .is_err(),
                        "{mode} recovery cut {at}"
                    );
                    reset_steps(None, false);
                    recover_if_readable(&f).unwrap();
                    assert_public_complete_or_absent(&f);
                    assert!(execute(&f).unwrap().durable_commit);
                }
            }
        }
        #[test]
        fn commit_publication_family_foreign_state_identity_and_bytes_preserved() {
            for mode in ["fresh", "legacy", "managed"] {
                for published in [false, true] {
                    for changed_bytes in [false, true] {
                        let good = mode_fixture(mode);
                        let trace = operation_trace(&good);
                        let label = if published {
                            "commit_after"
                        } else {
                            "commit_before"
                        };
                        let cut = trace.iter().position(|l| l == label).unwrap() + 1;
                        let f = mode_fixture(mode);
                        crash_at(&f, cut);
                        let pending_path = f.root.path.join(CONTROL).join("pending.json");
                        let mut journal = Journal::open(&pending_path, false).unwrap();
                        let p = journal.load().unwrap();
                        drop(journal);
                        let row = state_row(&p).unwrap();
                        let target = if published {
                            live_path(&f.root.path, row).unwrap()
                        } else {
                            private_path(&f.root.path, &p.operation_id, "new", row)
                        };
                        let original = read_plain(&target).unwrap();
                        if changed_bytes {
                            fs::write(&target, b"foreign same-inode bytes").unwrap();
                        } else {
                            fs::rename(&target, f.base.join("preserved-original-state")).unwrap();
                            fs::write(&target, &original).unwrap();
                        }
                        let observed = observe(&target, "installed.json", true).unwrap().member;
                        if changed_bytes {
                            assert_eq!(observed.identity, row.member.identity);
                            assert_ne!(observed.sha256, row.member.sha256);
                        } else {
                            assert_ne!(observed.identity, row.member.identity);
                            assert_eq!(observed.sha256, row.member.sha256);
                        }
                        let raw: Vec<_> = (0..23).map(|i| read_slot(i).unwrap()).collect();
                        for _ in 0..2 {
                            assert_eq!(execute(&f).err(), Some(Error::Pending));
                            exact(&target, &observed, true).unwrap();
                            assert_eq!(
                                (0..23).map(|i| read_slot(i).unwrap()).collect::<Vec<_>>(),
                                raw
                            );
                            assert!(exists(&pending_path).unwrap());
                        }
                    }
                }
            }
            for mode in ["fresh", "legacy", "managed"] {
                let good = mode_fixture(mode);
                let trace = operation_trace(&good);
                let cut = trace.iter().position(|l| l == "commit_before").unwrap() + 1;
                let f = mode_fixture(mode);
                crash_at(&f, cut);
                let target = f.root.path.join(CONTROL).join("installed.json");
                fs::write(&target, b"foreign preexisting destination").unwrap();
                let foreign = observe(&target, "installed.json", true).unwrap().member;
                let raw: Vec<_> = (0..23).map(|i| read_slot(i).unwrap()).collect();
                for _ in 0..2 {
                    assert_eq!(execute(&f).err(), Some(Error::Pending));
                    exact(&target, &foreign, true).unwrap();
                    assert_eq!(
                        (0..23).map(|i| read_slot(i).unwrap()).collect::<Vec<_>>(),
                        raw
                    );
                }
            }
        }
        #[test]
        fn commit_publication_family_terminal_handoff_and_uninstall_reentry() {
            for mode in ["fresh", "legacy", "managed"] {
                let good = mode_fixture(mode);
                let trace = operation_trace(&good);
                let before = trace.iter().position(|l| l == "commit_before").unwrap() + 1;
                // Each fixture owns the thread-local registry/profile double until
                // its whole journey ends. A probe never interrupts another fixture.
                let handoff_trace = if mode != "managed" {
                    let probe = mode_fixture(mode);
                    crash_at(&probe, before);
                    recover_if_readable(&probe).unwrap();
                    Some(operation_trace(&probe))
                } else {
                    None
                };
                let f = mode_fixture(mode);
                crash_at(&f, before);
                recover_if_readable(&f).unwrap();
                let terminal = f.root.path.join(CONTROL).join("pending.json");
                if let Some(handoff_trace) = &handoff_trace {
                    assert!(exists(&terminal).unwrap());
                    let mut j = Journal::open(&terminal, false).unwrap();
                    let p = j.load().unwrap();
                    drop(j);
                    assert_eq!(p.phase, Phase::Restored);
                    verify_restored(&p, &f.root).unwrap();
                    let snapshot = read_plain(&terminal).unwrap();
                    let gui = f.ctx.source.join("winsmux-app.exe");
                    let original = fs::read(&gui).unwrap();
                    fs::write(&gui, b"foreign source").unwrap();
                    assert!(execute(&f).is_err());
                    assert_eq!(read_plain(&terminal).unwrap(), snapshot);
                    fs::write(&gui, original).unwrap();
                    let stage_cut = handoff_trace
                        .iter()
                        .position(|l| l == "state_stage_partial")
                        .unwrap()
                        + 1;
                    reset_steps(Some(stage_cut), false);
                    assert!(execute(&f).is_err());
                    reset_steps(None, false);
                    assert_eq!(read_plain(&terminal).unwrap(), snapshot);
                    recover_if_readable(&f).unwrap();
                }
                assert!(execute(&f).unwrap().durable_commit);
                let mut uninstall = f.ctx.clone();
                uninstall.action = Action::Uninstall;
                let (previous, inherited) = admit_previous(
                    &f.root,
                    "S-1-5-21-100",
                    &f.plan_bytes,
                    &sha256_hex(&f.ctx.plan_sha256),
                )
                .unwrap();
                let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
                assert!(
                    run_transaction(
                        &uninstall,
                        &f.root,
                        "S-1-5-21-100".into(),
                        f.plan_bytes.clone(),
                        plan,
                        previous,
                        Vec::new(),
                        inherited
                    )
                    .unwrap()
                    .durable_commit
                );
                assert!(exists(&terminal).unwrap());
                assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
                assert!(execute(&f).unwrap().durable_commit);
                // The original fixture is finished before another Mock is installed.
                if let Some(handoff_trace) = handoff_trace {
                    for label in ["journal_handoff_before", "journal_handoff_after"] {
                        let at = handoff_trace.iter().position(|l| l == label).unwrap() + 1;
                        let next = mode_fixture(mode);
                        crash_at(&next, before);
                        recover_if_readable(&next).unwrap();
                        crash_at(&next, at);
                        recover_if_readable(&next).unwrap();
                        assert!(execute(&next).unwrap().durable_commit);
                    }
                }
            }
            // An empty control namespace is what a pre-journal error leaves behind. It is a
            // first install, not an unknown legacy inventory.
            let unknown = fixture();
            fs::create_dir(unknown.root.path.join(CONTROL)).unwrap();
            assert!(execute(&unknown).unwrap().durable_commit);
            assert_eq!(old(&unknown).unwrap().0.generation, "managed");
        }
        #[test]
        fn nullable_language_restore_preserves_absence_and_external_registration() {
            let good = fixture();
            execute(&good).unwrap();
            let trace = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().trace.clone());
            let cut = trace
                .iter()
                .position(|label| label == "commit_before")
                .unwrap()
                + 1;
            for external in [false, true] {
                let f = fixture();
                reset_steps(Some(cut), true);
                assert!(
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f))).is_err()
                );
                let pending = f.root.path.join(CONTROL).join("pending.json");
                let mut j = Journal::open(&pending, false).unwrap();
                let p = j.load().unwrap();
                validate_pending(&p, &f.root, "S-1-5-21-100").unwrap();
                assert_eq!(p.slots[1].prior, None);
                assert_eq!(p.slots[1].desired, Some(sz("1041")));
                assert_eq!(p.slots[1].phase, SlotPhase::PublishedConfirmed);
                drop(j);
                reset_steps(None, false);
                let foreign = Some(RawValue {
                    kind: 7,
                    data: vec![90, 0, 0, 0],
                });
                if external {
                    hooks::MOCK
                        .with(|m| m.borrow_mut().as_mut().unwrap().slots[1] = foreign.clone());
                }
                let recovered = recover_if_readable(&f);
                if external {
                    assert_eq!(recovered, Err(Error::Pending));
                    assert_eq!(read_slot(1).unwrap(), foreign);
                    assert!(exists(&pending).unwrap());
                    assert_eq!(recover_if_readable(&f), Err(Error::Pending));
                    assert_eq!(read_slot(1).unwrap(), foreign);
                    assert!(exists(&pending).unwrap());
                } else {
                    recovered.unwrap();
                    assert_eq!(read_slot(1).unwrap(), None);
                    assert!(exists(&pending).unwrap());
                    assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
                    assert!(!exists(&f.root.path.join("winsmux-app.exe")).unwrap());
                }
                for id in (0..22).filter(|id| *id != 1) {
                    assert_eq!(read_slot(id).unwrap(), None);
                }
                if !external {
                    assert!(execute(&f).unwrap().durable_commit);
                }
            }
        }
        #[test]
        fn actual_native_moves_preserve_identity_and_foreign_destination() {
            let f = fixture();
            let source = f.base.join("source/winsmux.exe");
            let row = observe(&source, "winsmux.exe", true).unwrap().member;
            let dest = f.root.path.join("winsmux.exe");
            move_exact(&source, &dest, &row, &f.root).unwrap();
            exact(&dest, &row, true).unwrap();
            move_exact(&dest, &source, &row, &f.root).unwrap();
            exact(&source, &row, true).unwrap();
            fs::write(&dest, b"foreign bytes").unwrap();
            assert!(move_exact(&source, &dest, &row, &f.root).is_err());
            assert_eq!(fs::read(&dest).unwrap(), b"foreign bytes");
            exact(&source, &row, true).unwrap();
            let link = f.base.join("source/hardlink.exe");
            fs::hard_link(&source, &link).unwrap();
            assert!(observe(&source, "winsmux.exe", false).is_err());
        }
        #[test]
        fn install_reinstall_uninstall_and_project_preservation() {
            let mut f = fixture();
            let r = execute(&f).unwrap();
            assert!(r.durable_commit);
            assert!(r.startup_receipt.is_some());
            let prior = old(&f).unwrap().0;
            fs::create_dir(f.root.path.join("project")).unwrap();
            fs::write(
                f.root.path.join("project/.git"),
                b"project pointer sentinel",
            )
            .unwrap();
            fs::write(f.base.join("outside-settings.json"), b"settings sentinel").unwrap();
            assert!(execute(&f).unwrap().durable_commit);
            assert_eq!(
                fs::read(f.root.path.join("project/.git")).unwrap(),
                b"project pointer sentinel"
            );
            let installed = old(&f).unwrap().0;
            assert_ne!(prior.operation_id, installed.operation_id);
            f.ctx.action = Action::Uninstall;
            let receipt = execute(&f).unwrap();
            assert!(receipt.durable_commit && receipt.startup_receipt.is_none());
            for m in &installed.members {
                assert!(!exists(&f.root.path.join(&m.path)).unwrap());
            }
            assert_eq!(
                fs::read(f.root.path.join("project/.git")).unwrap(),
                b"project pointer sentinel"
            );
            assert_eq!(
                fs::read(f.base.join("outside-settings.json")).unwrap(),
                b"settings sentinel"
            );
            for id in 0..22 {
                assert_eq!(read_slot(id).unwrap(), None);
            }
        }
        #[test]
        fn every_update_mutation_cut_is_restored_or_truthfully_pending() {
            let mut good = fixture();
            execute(&good).unwrap();
            good.ctx.language = 1033;
            reset_steps(None, false);
            execute(&good).unwrap();
            let cuts = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps);
            assert!(cuts > 30);
            for at in 1..=cuts {
                let mut f = fixture();
                execute(&f).unwrap();
                let previous = old(&f).unwrap().0;
                f.ctx.language = 1033;
                fs::write(f.root.path.join("sentinel.json"), b"user state").unwrap();
                reset_steps(Some(at), false);
                let result = execute(&f);
                reset_steps(None, false);
                if let Ok(receipt) = result {
                    assert!(receipt.durable_commit);
                    let bytes =
                        read_plain(&f.root.path.join(CONTROL).join("installed.json")).unwrap();
                    assert_ne!(
                        serde_json::from_slice::<Installed>(&bytes)
                            .unwrap()
                            .operation_id,
                        previous.operation_id
                    );
                } else {
                    let recovery = recover_if_readable(&f);
                    if recovery.is_ok() {
                        let current = old(&f).unwrap().0;
                        if current.operation_id == previous.operation_id {
                            assert_previous(&f, &previous);
                        } else {
                            assert!(current.members.iter().all(|m| exact(
                                &f.root.path.join(&m.path),
                                m,
                                true
                            )
                            .is_ok()));
                        }
                    } else {
                        assert!(
                            (exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap()
                                || admit_control_namespace(&f.root, None, &[]) == Err(Error::Pending))
                        );
                    }
                }
                assert_eq!(
                    fs::read(f.root.path.join("sentinel.json")).unwrap(),
                    b"user state"
                );
            }
        }
        #[test]
        fn crash_reentry_and_external_registration_are_preserved() {
            let mut good = fixture();
            execute(&good).unwrap();
            good.ctx.language = 1033;
            reset_steps(None, false);
            execute(&good).unwrap();
            let cuts = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps);
            for at in 1..=cuts {
                let mut f = fixture();
                execute(&f).unwrap();
                let (previous, previous_bytes) = old(&f).unwrap();
                f.ctx.language = 1033;
                reset_steps(Some(at), true);
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f)));
                let at_cut = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().trace.clone());
                let raw_at_cut: Vec<_> = (0..23).map(|id| read_slot(id).unwrap()).collect();
                let pending_path = f.root.path.join(CONTROL).join("pending.json");
                let pending_at_cut = read_plain(&pending_path).ok().and_then(|bytes| {
                    serde_json::from_slice::<JournalEnvelope>(&bytes)
                        .ok()
                        .map(|e| e.payload)
                });
                reset_steps(None, false);
                let recovery = recover_if_readable(&f);
                if let Some(pending) = &pending_at_cut {
                    // A write intent has no durable publication confirmation. Recovery
                    // must preserve the observed C even when it coincides with P or D.
                    for slot in &pending.slots {
                        if slot.phase == SlotPhase::WriteIntent {
                            assert_eq!(read_slot(slot.id).unwrap(), raw_at_cut[slot.id as usize]);
                            assert!(recovery.is_err());
                        }
                    }
                }
                match recovery {
                    Ok(()) => {
                        let state = old(&f).unwrap().0;
                        if state.operation_id == previous.operation_id {
                            assert_previous(&f, &previous);
                        }
                    }
                    Err(_) => {
                        if !exists(&pending_path).unwrap() {
                            assert_eq!(admit_control_namespace(&f.root, None, &[]), Err(Error::Pending));
                            assert!(!at_cut.is_empty());
                            assert!(at_cut.iter().all(|step| !matches!(
                                step.as_str(),
                                "move_before" | "slot_before_write" | "commit_before"
                            )));
                            // exact checks include full bytes/hash and volume/file ID.
                            assert_previous(&f, &previous);
                            assert_eq!(
                                read_plain(&f.root.path.join(CONTROL).join("installed.json"))
                                    .unwrap(),
                                previous_bytes
                            );
                            assert_eq!(
                                (0..23).map(|id| read_slot(id).unwrap()).collect::<Vec<_>>(),
                                raw_at_cut
                            );
                            reset_steps(None, false);
                            assert_eq!(execute(&f).err(), Some(Error::Pending));
                            assert!(hooks::MOCK.with(|m| m
                                .borrow()
                                .as_ref()
                                .unwrap()
                                .trace
                                .is_empty()));
                            assert_previous(&f, &previous);
                            assert_eq!(
                                read_plain(&f.root.path.join(CONTROL).join("installed.json"))
                                    .unwrap(),
                                previous_bytes
                            );
                        } else {
                            let pending_bytes = read_plain(&pending_path).unwrap();
                            let raw_before_reentry: Vec<_> =
                                (0..23).map(|id| read_slot(id).unwrap()).collect();
                            reset_steps(None, false);
                            assert_eq!(execute(&f).err(), Some(Error::Pending));
                            assert_eq!(read_plain(&pending_path).unwrap(), pending_bytes);
                            assert_eq!(
                                (0..23).map(|id| read_slot(id).unwrap()).collect::<Vec<_>>(),
                                raw_before_reentry
                            );
                        }
                    }
                }
            }
            let f = fixture();
            execute(&f).unwrap();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().startup_fail = true);
            assert!(execute(&f).is_err());
            let before = old(&f).unwrap().0;
            assert_previous(&f, &before);
            // Fresh install writes a different P/D; an external X after write is never overwritten by restore.
            let f = fixture();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().foreign_write = true);
            let earlier = reports().len();
            // The registration refusal that started the restore is the verdict; the restore that could
            // not put the slot back is the extra line.
            assert_eq!(execute(&f).err(), Some(Error::Registration));
            assert_eq!(reports()[earlier..], ["winsmux installer: restore_incomplete pending_unconfirmed".to_string()]);
            assert_eq!(
                read_slot(0).unwrap(),
                Some(RawValue {
                    kind: 3,
                    data: vec![88]
                })
            );
            assert!(exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap());
        }
        #[test]
        fn long_internal_paths_and_alias_boundaries_use_the_same_move_owner() {
            let f = fixture();
            let long = f.base.join("long".repeat(35)).join("next".repeat(20));
            fs::create_dir_all(&long).unwrap();
            let held = Dirs::open(&long).unwrap();
            assert!(path_text(&held.path).unwrap().encode_utf16().count() > 260);
            let path = long.join("member.bin");
            fs::write(&path, b"owned long path").unwrap();
            let row = observe(&path, "member.bin", true).unwrap().member;
            let dest = long.join("moved.bin");
            move_exact(&path, &dest, &row, &held).unwrap();
            move_exact(&dest, &path, &row, &held).unwrap();
            exact(&path, &row, true).unwrap();
            let bytes = path_wide(&path).unwrap();
            assert!(String::from_utf16(&bytes[..bytes.len() - 1])
                .unwrap()
                .starts_with(r"\\?\"));
            for bad in [
                r"\\?\C:\owned\file",
                r"\\server\share\file",
                r"C:\owned\..\file",
                r"C:\owned\file:stream",
                r"C:\OWNED~1\file",
            ] {
                assert!(path_wide(Path::new(bad)).is_err());
            }
            Dirs::open(Path::new(&path_text(&f.root.path).unwrap()[..3])).unwrap();
        }
        // Real owned filesystem IO; registry and startup remain the existing thread-local doubles.
        fn observed_open_fixture() -> Fixture {
            let base = std::env::temp_dir().join(format!("winsmux-observed-open-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&base).expect("exclusive observed-open fixture");
            let f = fixture_at(base);
            execute(&f).expect("managed owned fixture setup");
            fs::create_dir(f.root.path.join("project")).expect("owned project sentinel directory");
            fs::write(f.root.path.join("project/settings.json"), b"owned project sentinel").unwrap();
            fs::write(f.base.join("user-sentinel.json"), b"outside user sentinel").unwrap();
            let shortcuts = f.base.join("owned-shortcuts");
            for kind in ["desktop", "start_menu"] {
                let path = shortcuts.join(kind).join("winsmux.lnk");
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                identity_test_link(&path, &f.root.path.join("winsmux-app.exe"));
            }
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().shortcut_root = Some(shortcuts));
            f
        }
        #[derive(PartialEq, Eq)]
        struct ObservedOpenSnapshot {
            directories: Vec<(String, Identity)>,
            files: Vec<(String, Member, Vec<u8>)>,
            registration_double: Vec<Option<RawValue>>,
            external: Vec<(Member, Vec<u8>)>,
        }
        fn observed_open_bytes(path: &Path, relative: &str) -> (Member, Vec<u8>) {
            let mut held = observe(path, relative, false).expect("protected owned file snapshot");
            let mut bytes = Vec::new();
            held.file.seek(SeekFrom::Start(0)).unwrap();
            held.file.read_to_end(&mut bytes).unwrap();
            (held.member.clone(), bytes)
        }
        fn observed_open_snapshot(f: &Fixture) -> ObservedOpenSnapshot {
            fn visit(dir: &Path, relative: &str, snapshot: &mut ObservedOpenSnapshot) {
                let held = Dirs::open(dir).expect("protected owned directory snapshot");
                snapshot.directories.push((relative.into(), held.id.clone()));
                let mut entries = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect::<Vec<_>>();
                entries.sort();
                for path in entries {
                    let leaf = path.file_name().unwrap().to_str().unwrap();
                    let name = if relative.is_empty() { leaf.to_owned() } else { format!("{relative}/{leaf}") };
                    if fs::symlink_metadata(&path).unwrap().is_dir() { visit(&path, &name, snapshot); }
                    else { let (member, bytes) = observed_open_bytes(&path, &name); snapshot.files.push((name, member, bytes)); }
                }
            }
            let mut snapshot = ObservedOpenSnapshot { directories: Vec::new(), files: Vec::new(), registration_double: (0..23).map(|id| read_slot(id).unwrap()).collect(), external: Vec::new() };
            visit(&f.root.path, "", &mut snapshot);
            snapshot.external.push(observed_open_bytes(&f.base.join("user-sentinel.json"), "user-sentinel.json"));
            for kind in ["desktop", "start_menu"] {
                snapshot.external.push(observed_open_bytes(&known_shortcut(kind).unwrap(), "winsmux.lnk"));
            }
            snapshot
        }
        #[test]
        fn observed_open_native_missing_source_gui_preserves_owned_state() {
            let f = observed_open_fixture();
            fs::remove_file(f.ctx.source.join("winsmux-app.exe")).unwrap();
            let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
            let before = observed_open_snapshot(&f);
            reset_steps(None, false);
            let result = source_rows(&f.ctx, &plan).map(|_| ());
            assert!(observed_open_snapshot(&f) == before, "protected owned state changed");
            assert_eq!(hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps), 0, "source refusal reached a transaction mutation");
            assert_eq!(result, Err(Error::Member), "missing source GUI classification");
        }

        #[test]
        fn observed_open_pure_error_classes_are_truthful() {
            for raw in [2, 3] { assert_eq!(observed_open_error(std::io::Error::from_raw_os_error(raw)), Error::Member); }
            for raw in [32, 33] { assert_eq!(observed_open_error(std::io::Error::from_raw_os_error(raw)), Error::Busy); }
            for raw in [5, 1314, 123, 161, 206, 87, 8, 14, 1450, 0, -1, i32::MIN, i32::MAX, 6, 80, 183, 9999] {
                assert_eq!(observed_open_error(std::io::Error::from_raw_os_error(raw)), Error::Io);
            }
            for kind in [std::io::ErrorKind::NotFound, std::io::ErrorKind::PermissionDenied, std::io::ErrorKind::Other] {
                assert_eq!(observed_open_error(std::io::Error::new(kind, "synthetic error without raw code")), Error::Io);
            }
            assert_eq!(Error::Member.classification(), "member_unconfirmed");
            assert_eq!(Error::Occupied.classification(), "destination_occupied");
            assert_eq!(Error::FolderMoved.classification(), "shortcut_folder_moved");
            assert_eq!(Error::Busy.classification(), "work_running_or_locked");
            assert_eq!(Error::LegacyIncomplete(LegacyCheck::Inventory).classification(), "legacy_inventory_incomplete");
            assert_eq!(Error::LegacyIncomplete(LegacyCheck::Receipt).classification(), "legacy_receipt_missing");
            assert_eq!(Error::LegacyIncomplete(LegacyCheck::Profile).classification(), "legacy_profile_incomplete");
            assert_eq!(Error::Io.classification(), "io_unconfirmed");
        }

        // TASK-881 real-machine refusal (2026-10-21): %LOCALAPPDATA%\winsmux already held the private
        // GUI's runtime entries and no .winsmux-desktop/installed.json. admit_previous treats every
        // non-empty unmanaged root as a legacy install, and the compiled legacy profile root is the CI
        // capture path, so a first install onto a used root is refused instead of preserving the entries.
        #[test]
        fn first_install_onto_root_with_foreign_user_entries_preserves_them() {
            let f = fixture();
            for dir in ["artifact-snapshots", "ui-attach", "workspace"] {
                fs::create_dir(f.root.path.join(dir)).unwrap();
            }
            fs::write(f.root.path.join("workspace/layout.json"), b"user layout preserved").unwrap();
            fs::write(f.root.path.join("planning-root.txt"), b"C:\\project\\winsmux\r\n").unwrap();
            reset_steps(None, false);
            let result = execute(&f);
            assert_eq!(result.as_ref().err(), None, "a used root without installed.json is a first install, not a legacy inventory");
            assert!(result.unwrap().durable_commit);
            assert_eq!(old(&f).unwrap().0.generation, "managed");
            assert_eq!(fs::read(f.root.path.join("workspace/layout.json")).unwrap(), b"user layout preserved");
            assert_eq!(fs::read(f.root.path.join("planning-root.txt")).unwrap(), b"C:\\project\\winsmux\r\n");
            for dir in ["artifact-snapshots", "ui-attach"] {
                assert!(f.root.path.join(dir).is_dir(), "{dir} was removed");
            }
        }

        #[test]
        fn legacy_profile_root_is_still_admitted_as_legacy() {
            let f = mode_fixture("legacy");
            let (previous, inherited) = admit_previous(
                &f.root,
                "S-1-5-21-100",
                &f.plan_bytes,
                &sha256_hex(&f.ctx.plan_sha256),
            )
            .unwrap();
            assert!(inherited.is_none());
            assert_eq!(previous.unwrap().0.generation, "legacy");
            assert!(execute(&f).unwrap().durable_commit);
            assert!(old(&f).unwrap().0.legacy_capture.is_some());
        }

        #[test]
        fn first_install_refuses_a_foreign_file_at_a_member_path_and_leaves_the_root_alone() {
            let f = fixture();
            fs::write(f.root.path.join("winsmux.exe"), b"another product's cli").unwrap();
            fs::write(f.root.path.join("notes.txt"), b"user notes").unwrap();
            reset_steps(None, false);
            assert_eq!(execute(&f).err(), Some(Error::Occupied), "a foreign file at a member path is a collision, not an unconfirmed member");
            assert_eq!(fs::read(f.root.path.join("winsmux.exe")).unwrap(), b"another product's cli");
            assert_eq!(fs::read(f.root.path.join("notes.txt")).unwrap(), b"user notes");
            assert!(!exists(&f.root.path.join("winsmux-app.exe")).unwrap());
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert!(hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().slots.iter().all(Option::is_none)));
        }

        // Same machine, next refusal once the root is admitted: Desktop\winsmux.lnk and
        // Programs\winsmux.lnk already pointed at another winsmux-app.exe (TASK-876 private install).
        fn foreign_shortcut_fixture() -> (Fixture, PathBuf, Vec<(String, Vec<u8>)>) {
            foreign_shortcut_fixture_enabling(&["desktop", "start_menu"])
        }
        /// Both known folders hold a link another install owns; the install publishes only `enabled`.
        fn foreign_shortcut_fixture_enabling(enabled: &[&str]) -> (Fixture, PathBuf, Vec<(String, Vec<u8>)>) {
            let mut f = fixture();
            let known = f.base.join("synthetic-known-folders");
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().shortcut_root = Some(known.clone()));
            let foreign_target = f.base.join("private-install").join("winsmux-app.exe");
            fs::create_dir_all(foreign_target.parent().unwrap()).unwrap();
            fs::write(&foreign_target, b"private gui").unwrap();
            let mut foreign = Vec::new();
            for kind in ["desktop", "start_menu"] {
                let link = known.join(kind).join("winsmux.lnk");
                fs::create_dir_all(link.parent().unwrap()).unwrap();
                identity_test_link(&link, &foreign_target);
                foreign.push((kind.to_string(), fs::read(&link).unwrap()));
            }
            for kind in enabled {
                enable_shortcut_source(&mut f, kind);
            }
            reset_steps(None, false);
            (f, known, foreign)
        }
        fn enable_shortcut_source(f: &mut Fixture, kind: &str) {
            let source = f.ctx.source.join("shortcuts").join(format!("{kind}.lnk"));
            fs::create_dir_all(source.parent().unwrap()).unwrap();
            identity_test_link(&source, &f.root.path.join("winsmux-app.exe"));
            match kind {
                "desktop" => f.ctx.desktop = true,
                "start_menu" => f.ctx.start_menu = true,
                _ => panic!("unknown shortcut kind"),
            }
        }
        fn parked_bytes_intact(f: &Fixture, foreign: &[(String, Vec<u8>)]) {
            for (kind, bytes) in foreign {
                assert_eq!(fs::read(parked_link(f, kind)).unwrap(), *bytes, "{kind} parked bytes");
            }
        }
        fn parked_link(f: &Fixture, kind: &str) -> PathBuf {
            preserved_path(&f.root.path, kind).unwrap()
        }
        fn assert_foreign_parked(f: &Fixture, known: &Path, foreign: &[(String, Vec<u8>)]) {
            let state = old(f).unwrap().0;
            assert_eq!(state.preserved.len(), foreign.len());
            for (kind, bytes) in foreign {
                verify_link(&known.join(kind).join("winsmux.lnk"), &f.root.path.join("winsmux-app.exe")).unwrap();
                assert_eq!(fs::read(parked_link(f, kind)).unwrap(), *bytes, "{kind} parked bytes");
                let row = state.preserved.iter().find(|r| &r.kind == kind).unwrap();
                assert_eq!(row.member.sha256, hash(bytes));
            }
        }
        fn assert_foreign_live(f: &Fixture, known: &Path, foreign: &[(String, Vec<u8>)]) {
            for (kind, bytes) in foreign {
                assert_eq!(fs::read(known.join(kind).join("winsmux.lnk")).unwrap(), *bytes, "{kind} live bytes");
                assert!(!exists(&parked_link(f, kind)).unwrap(), "{kind} still parked");
            }
        }
        #[test]
        fn first_install_with_foreign_same_name_shortcuts_completes_and_preserves_them() {
            let (f, known, foreign) = foreign_shortcut_fixture();
            let result = execute(&f);
            assert_eq!(result.as_ref().err(), None, "a same-name link owned by another install must not refuse the install");
            assert!(result.unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            // An update keeps the parked links and the product links in place.
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
        }
        #[test]
        fn uninstall_returns_preserved_foreign_shortcuts_to_their_known_folders() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert_foreign_live(&f, &known, &foreign);
            // The same root installs again and parks the same links again.
            f.ctx.action = Action::Install;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
        }
        #[test]
        fn install_rollback_after_publishing_returns_preserved_foreign_shortcuts() {
            let (good, _, _) = foreign_shortcut_fixture();
            let trace = operation_trace(&good);
            let at = trace.iter().position(|l| l == "commit_before").unwrap() + 1;
            let (f, known, foreign) = foreign_shortcut_fixture();
            reset_steps(Some(at), false);
            assert_eq!(execute(&f).err(), Some(Error::Io));
            reset_steps(None, false);
            assert_foreign_live(&f, &known, &foreign);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
        }
        // TASK-881 realmachine-aa97da9d: a used root (three directories and one file, no
        // installed.json) and both known folders holding a link of another winsmux install.
        fn task881_layout_fixture() -> (Fixture, PathBuf, Vec<(String, Vec<u8>)>) {
            let (f, known, foreign) = foreign_shortcut_fixture();
            for dir in ["artifact-snapshots", "ui-attach", "workspace"] {
                fs::create_dir(f.root.path.join(dir)).unwrap();
            }
            fs::write(f.root.path.join("planning-root.txt"), b"user planning root").unwrap();
            (f, known, foreign)
        }
        fn assert_task881_root_entries_intact(f: &Fixture) {
            for dir in ["artifact-snapshots", "ui-attach", "workspace"] {
                assert!(fs::symlink_metadata(f.root.path.join(dir)).unwrap().is_dir(), "{dir}");
            }
            assert_eq!(fs::read(f.root.path.join("planning-root.txt")).unwrap(), b"user planning root");
        }
        /// The forward run fails after both foreign links are parked and the root rows are
        /// published. During the restore, the preserved `kind` link's move back fails right after
        /// its rename (the TASK-881 journal: desktop restore_intent, start_menu moved_confirmed).
        /// `readback` fails the renamed file's final-name readback (the real machine's 106);
        /// otherwise the next cut, the journal write after the move, refuses with Io.
        fn fail_restore_of_preserved(f: &Fixture, kind: &'static str) -> Result<Receipt> {
            fail_restore_of_preserved_at(f, kind, false)
        }
        fn fail_restore_of_preserved_at(f: &Fixture, kind: &'static str, readback: bool) -> Result<Receipt> {
            hooks::MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let m = m.as_mut().unwrap();
                m.startup_fail = true;
                m.barrier = Some(Box::new(move |label| {
                    hooks::MOCK.with(|m| {
                        let mut m = m.borrow_mut();
                        let m = m.as_mut().unwrap();
                        if label == "move_after"
                            && m.proof_key.starts_with("Restoring|")
                            && m.proof_key.contains(&format!("preserved:{kind}:RestoreIntent"))
                        {
                            if readback {
                                m.final_name_refusal = true;
                            } else {
                                m.fail = Some(m.steps + 1);
                            }
                        }
                    });
                }));
            });
            let result = execute(f);
            hooks::MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let m = m.as_mut().unwrap();
                m.barrier = None;
                m.startup_fail = false;
            });
            let kept = reports();
            reset_steps(None, false);
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().reports = kept);
            result
        }
        #[test]
        fn task881_layout_is_admitted_as_a_first_install() {
            let (f, known, foreign) = task881_layout_fixture();
            let result = execute(&f);
            assert_eq!(result.as_ref().err(), None, "a used root without installed.json plus two foreign links is a first install");
            assert!(result.unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            assert_task881_root_entries_intact(&f);
        }
        #[test]
        fn task881_rollback_returns_every_preserved_link_when_one_restore_move_fails() {
            let (f, known, foreign) = task881_layout_fixture();
            let _ = fail_restore_of_preserved(&f, "desktop");
            // The desktop link was renamed back before the cut. The start menu link must not stay
            // parked because a later row's readback failed.
            assert_foreign_live(&f, &known, &foreign);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert_task881_root_entries_intact(&f);
        }
        #[test]
        fn task881_rollback_failure_reports_the_refusal_that_started_it() {
            let (f, known, _) = task881_layout_fixture();
            assert_eq!(fail_restore_of_preserved(&f, "desktop").err(), Some(Error::Startup));
            let live = path_text(&known.join("desktop").join("winsmux.lnk")).unwrap();
            assert_eq!(reports(), vec![format!("winsmux installer: restore_incomplete io_unconfirmed desktop {live}")]);
        }
        /// The real machine's shape: the desktop link is renamed back, then its final-name readback
        /// refuses. The start menu link still goes back, the refusal names the restore move's readback,
        /// and the run still ends with the refusal that started the restore.
        #[test]
        fn task881_rollback_readback_refusal_names_the_restore_move_and_returns_the_other_link() {
            let (f, known, foreign) = task881_layout_fixture();
            assert_eq!(fail_restore_of_preserved_at(&f, "desktop", true).err(), Some(Error::Startup));
            assert_foreign_live(&f, &known, &foreign);
            let live = path_text(&known.join("desktop").join("winsmux.lnk")).unwrap();
            assert_eq!(reports(), vec![format!("winsmux installer: restore_incomplete path_refused:171 desktop {live}")]);
            let journal = f.root.path.join(CONTROL).join("pending.json");
            assert!(exists(&journal).unwrap(), "the journal stays for re-entry");
            recover_if_readable(&f).unwrap();
            assert_foreign_live(&f, &known, &foreign);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            assert!(!exists(&journal).unwrap());
            assert_task881_root_entries_intact(&f);
        }
        #[test]
        fn task881_preserved_link_readback_refusal_names_the_publish_move() {
            let (f, known, foreign) = task881_layout_fixture();
            hooks::MOCK.with(|m| {
                m.borrow_mut().as_mut().unwrap().barrier = Some(Box::new(|label| {
                    hooks::MOCK.with(|m| {
                        let mut m = m.borrow_mut();
                        let m = m.as_mut().unwrap();
                        if label == "move_after" && m.proof_key.starts_with("BackingUp|") && m.proof_key.contains("preserved:desktop:MoveIntent") {
                            m.final_name_refusal = true;
                        }
                    });
                }))
            });
            let err = execute(&f).err();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            reset_steps(None, false);
            assert_eq!(err, Some(Error::Path(169)));
            // The restore found the parked link and put it back without a refusal of its own.
            assert_foreign_live(&f, &known, &foreign);
            assert_eq!(reports(), Vec::<String>::new());
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
        }
        #[test]
        fn task881_rerun_from_the_interrupted_journal_returns_the_parked_link_and_installs() {
            let (f, known, foreign) = task881_layout_fixture();
            let _ = fail_restore_of_preserved(&f, "desktop");
            let journal = f.root.path.join(CONTROL).join("pending.json");
            assert!(exists(&journal).unwrap(), "the journal stays for re-entry");
            recover_if_readable(&f).unwrap();
            assert_foreign_live(&f, &known, &foreign);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            assert!(!exists(&journal).unwrap());
            assert_task881_root_entries_intact(&f);
        }
        #[test]
        fn task881_preserved_link_move_refusals_name_their_move() {
            let (f, _, _) = task881_layout_fixture();
            let parked = parked_link(&f, "start_menu");
            hooks::MOCK.with(|m| {
                m.borrow_mut().as_mut().unwrap().barrier = Some(Box::new(move |label| {
                    let armed = hooks::MOCK.with(|m| {
                        let m = m.borrow();
                        let m = m.as_ref().unwrap();
                        m.proof_key.starts_with("BackingUp|") && m.proof_key.contains("preserved:start_menu:MoveIntent")
                    });
                    if label == "journal_after" && armed && !parked.exists() {
                        fs::write(&parked, b"foreign file at the parked path").unwrap();
                    }
                }))
            });
            let err = execute(&f).err();
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().barrier = None);
            reset_steps(None, false);
            // 135 is every move's "destination occupied or wrong volume" and 3 (pending_unconfirmed)
            // is the restore's verdict. Neither names the move that refused. 162 is the
            // PublishPreservedMoveDestination origin.
            assert_eq!(err, Some(Error::Path(162)));
        }
        /// Fails, once, the final-name readback of the first restore move made while `class` is
        /// journaled (for example "new:root:RestoreIntent"). The rename itself has already happened.
        fn arm_restore_readback_refusal(class: &'static str) {
            let mut fired = false;
            hooks::MOCK.with(|m| {
                m.borrow_mut().as_mut().unwrap().barrier = Some(Box::new(move |label| {
                    if fired || label != "move_after" {
                        return;
                    }
                    fired = hooks::MOCK.with(|m| {
                        let mut m = m.borrow_mut();
                        let m = m.as_mut().unwrap();
                        let armed = m.proof_key.starts_with("Restoring|") && m.proof_key.contains(class);
                        m.final_name_refusal |= armed;
                        armed
                    });
                }));
            });
        }
        fn disarm_restore_faults() {
            hooks::MOCK.with(|m| {
                let mut m = m.borrow_mut();
                let m = m.as_mut().unwrap();
                m.barrier = None;
                m.startup_fail = false;
            });
            reset_steps(None, false);
        }
        /// The 1-based cut that comes first after every journaled class in `classes` holds.
        fn first_cut_after(trace: &[(String, String)], classes: &[&str]) -> usize {
            trace.iter().position(|(_, key)| classes.iter().all(|c| key.contains(c))).unwrap() + 1
        }
        /// A managed update rolls back. The new root file's move back to the private area is renamed,
        /// then its readback refuses, and the old file returns to the same live path. The next run finds
        /// the new file in the private area and the old one live, and finishes the restore.
        #[test]
        fn task881_reentry_finishes_a_new_root_row_whose_live_path_the_old_row_took_back() {
            let f = mode_fixture("managed");
            let (state, _) = old(&f).unwrap();
            arm_restore_readback_refusal("new:root:RestoreIntent");
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().startup_fail = true);
            assert_eq!(execute(&f).err(), Some(Error::Startup));
            disarm_restore_faults();
            assert_eq!(recover_if_readable(&f), Ok(()));
            assert!(!exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap());
            assert_previous(&f, &state);
            assert!(execute(&f).unwrap().durable_commit);
        }
        /// A first install over two foreign links rolls back after publishing its own links. The product
        /// Desktop link's move back to the private area is renamed, then its readback refuses, and the
        /// foreign link returns to the same Desktop path. The next run finishes the restore, and the
        /// install after it parks the foreign links again.
        #[test]
        fn task881_reentry_finishes_a_new_link_row_whose_live_path_the_preserved_link_took_back() {
            let (good, _, _) = task881_layout_fixture();
            let trace = operation_trace(&good);
            let at = trace.iter().position(|l| l == "commit_before").unwrap() + 1;
            let (f, known, foreign) = task881_layout_fixture();
            reset_steps(Some(at), false);
            arm_restore_readback_refusal("new:desktop:RestoreIntent");
            assert_eq!(execute(&f).err(), Some(Error::Io));
            disarm_restore_faults();
            assert_foreign_live(&f, &known, &foreign);
            assert_eq!(recover_if_readable(&f), Ok(()));
            assert_foreign_live(&f, &known, &foreign);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            assert_task881_root_entries_intact(&f);
        }
        /// An uninstall that put the foreign links back rolls back. The foreign Desktop link's move back
        /// to its parked path is renamed, then its readback refuses, and the product link returns to the
        /// Desktop path the foreign link left. The next run finishes the restore, and the uninstall after
        /// it returns the foreign links.
        #[test]
        fn task881_reentry_finishes_a_preserved_row_whose_other_endpoint_the_old_link_took_back() {
            let (mut good, _, _) = foreign_shortcut_fixture();
            assert!(execute(&good).unwrap().durable_commit);
            good.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&good).unwrap().durable_commit);
            let proof = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().proof_trace.clone());
            let at = first_cut_after(&proof, &["preserved:desktop:MovedConfirmed", "preserved:start_menu:MovedConfirmed"]);
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            f.ctx.action = Action::Uninstall;
            reset_steps(Some(at), false);
            arm_restore_readback_refusal("preserved:desktop:RestoreIntent");
            assert_eq!(execute(&f).err(), Some(Error::Io));
            disarm_restore_faults();
            assert_eq!(recover_if_readable(&f), Ok(()));
            assert_foreign_parked(&f, &known, &foreign);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_live(&f, &known, &foreign);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
        }
        #[test]
        fn every_install_cut_class_keeps_the_foreign_shortcut_bytes_in_exactly_one_place() {
            let (good, _, _) = foreign_shortcut_fixture();
            operation_trace(&good);
            for at in identity_cut_selection("foreign-shortcuts") {
                for crash in [false, true] {
                    let (f, known, foreign) = foreign_shortcut_fixture();
                    reset_steps(Some(at), crash);
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f)));
                    reset_steps(None, false);
                    let recovery = recover_if_readable(&f);
                    for (kind, bytes) in &foreign {
                        let live = fs::read(known.join(kind).join("winsmux.lnk")).ok() == Some(bytes.clone());
                        let parked = fs::read(parked_link(&f, kind)).ok() == Some(bytes.clone());
                        assert!(live ^ parked, "cut {at} crash {crash} {kind}: live={live} parked={parked}");
                    }
                    if recovery.is_ok() {
                        if old(&f).is_some() {
                            assert_foreign_parked(&f, &known, &foreign);
                        } else {
                            assert_foreign_live(&f, &known, &foreign);
                        }
                        assert!(execute(&f).unwrap().durable_commit, "cut {at} crash {crash}");
                        assert_foreign_parked(&f, &known, &foreign);
                    }
                }
            }
        }
        #[test]
        fn every_uninstall_cut_class_keeps_the_foreign_shortcut_bytes_in_exactly_one_place() {
            let (mut good, _, _) = foreign_shortcut_fixture();
            assert!(execute(&good).unwrap().durable_commit);
            good.ctx.action = Action::Uninstall;
            operation_trace(&good);
            for at in identity_cut_selection("foreign-shortcuts-uninstall") {
                for crash in [false, true] {
                    let (mut f, known, foreign) = foreign_shortcut_fixture();
                    assert!(execute(&f).unwrap().durable_commit);
                    f.ctx.action = Action::Uninstall;
                    reset_steps(Some(at), crash);
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f)));
                    reset_steps(None, false);
                    let recovery = recover_if_readable(&f);
                    for (kind, bytes) in &foreign {
                        let live = fs::read(known.join(kind).join("winsmux.lnk")).ok() == Some(bytes.clone());
                        let parked = fs::read(parked_link(&f, kind)).ok() == Some(bytes.clone());
                        assert!(live ^ parked, "uninstall cut {at} crash {crash} {kind}: live={live} parked={parked}");
                    }
                    if recovery.is_ok() {
                        if old(&f).is_some() {
                            assert_foreign_parked(&f, &known, &foreign);
                            assert!(execute(&f).unwrap().durable_commit, "uninstall cut {at} crash {crash}");
                        }
                        assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
                        assert_foreign_live(&f, &known, &foreign);
                    }
                }
            }
        }
        // The uninstall backs up only the product links still in their known folders, so with the
        // Desktop one already gone the pending validator and the restore verifier take the shorter
        // set of old rows. Every cut of that uninstall keeps each foreign link in exactly one place.
        #[test]
        fn every_uninstall_cut_class_without_the_desktop_product_link_keeps_the_foreign_bytes_in_one_place() {
            let without_desktop_link = || {
                let (mut f, known, foreign) = foreign_shortcut_fixture();
                assert!(execute(&f).unwrap().durable_commit);
                fs::remove_file(known.join("desktop").join("winsmux.lnk")).unwrap();
                f.ctx.action = Action::Uninstall;
                reset_steps(None, false);
                (f, known, foreign)
            };
            let (good, _, _) = without_desktop_link();
            operation_trace(&good);
            let cuts = identity_cut_selection("foreign-shortcuts-uninstall-without-desktop-link");
            let mut rolled_back = 0;
            for &at in &cuts {
                for crash in [false, true] {
                    let (f, known, foreign) = without_desktop_link();
                    reset_steps(Some(at), crash);
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| execute(&f)));
                    reset_steps(None, false);
                    let interrupted = exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap();
                    let recovery = recover_if_readable(&f);
                    for (kind, bytes) in &foreign {
                        let live = fs::read(known.join(kind).join("winsmux.lnk")).ok() == Some(bytes.clone());
                        let parked = fs::read(parked_link(&f, kind)).ok() == Some(bytes.clone());
                        assert!(live ^ parked, "uninstall cut {at} crash {crash} {kind}: live={live} parked={parked}");
                    }
                    if recovery.is_ok() {
                        if old(&f).is_some() {
                            rolled_back += usize::from(interrupted);
                            parked_bytes_intact(&f, &foreign);
                            assert!(!exists(&known.join("desktop").join("winsmux.lnk")).unwrap(), "cut {at} crash {crash}: a link the operation never touched came back");
                            verify_link(&known.join("start_menu").join("winsmux.lnk"), &f.root.path.join("winsmux-app.exe")).unwrap();
                            assert!(execute(&f).unwrap().durable_commit, "uninstall after cut {at} crash {crash}");
                        }
                        assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
                        assert_foreign_live(&f, &known, &foreign);
                    }
                }
            }
            assert!(rolled_back > 0, "no recovery rolled an interrupted uninstall back, so the restore verifier never ran");
        }
        #[test]
        fn first_install_refuses_a_stray_file_in_the_parked_area_and_leaves_everything() {
            let (f, known, foreign) = foreign_shortcut_fixture();
            let stray = parked_link(&f, "desktop");
            fs::create_dir_all(stray.parent().unwrap()).unwrap();
            fs::write(&stray, b"not parked by winsmux").unwrap();
            assert_eq!(execute(&f).err(), Some(Error::Path(155)), "a parked area nobody's state records is refused before anything moves");
            assert_eq!(fs::read(&stray).unwrap(), b"not parked by winsmux");
            for (kind, bytes) in &foreign {
                assert_eq!(fs::read(known.join(kind).join("winsmux.lnk")).unwrap(), *bytes, "{kind} live bytes");
            }
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert!(!exists(&f.root.path.join("winsmux-app.exe")).unwrap());
        }
        #[test]
        fn update_and_uninstall_refuse_a_changed_parked_link_and_leave_everything() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            let before = old(&f).unwrap().1;
            fs::write(parked_link(&f, "desktop"), b"edited while parked").unwrap();
            assert_eq!(execute(&f).err(), Some(Error::Member), "update: a parked link winsmux cannot vouch for");
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert_eq!(execute(&f).err(), Some(Error::Member), "uninstall: a parked link winsmux cannot vouch for");
            assert_eq!(fs::read(parked_link(&f, "desktop")).unwrap(), b"edited while parked");
            assert_eq!(fs::read(parked_link(&f, "start_menu")).unwrap(), foreign[1].1);
            assert_eq!(old(&f).unwrap().1, before, "owned state changed by a refusal");
            for kind in ["desktop", "start_menu"] {
                verify_link(&known.join(kind).join("winsmux.lnk"), &f.root.path.join("winsmux-app.exe")).unwrap();
            }
        }
        #[test]
        fn update_parks_a_newly_enabled_kind_beside_the_one_already_parked() {
            let (mut f, known, foreign) = foreign_shortcut_fixture_enabling(&["desktop"]);
            assert!(execute(&f).unwrap().durable_commit);
            let state = old(&f).unwrap().0;
            assert_eq!(state.preserved.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["desktop"]);
            assert_eq!(fs::read(known.join("start_menu").join("winsmux.lnk")).unwrap(), foreign[1].1, "a kind the install does not publish stays where it is");
            enable_shortcut_source(&mut f, "start_menu");
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_live(&f, &known, &foreign);
        }
        // Another install (the TASK-876 private build) owns the parked links. When it is updated or
        // removed it may delete or recreate Desktop\winsmux.lnk by name, which is now the product link.
        #[test]
        fn product_link_deleted_by_another_install_is_republished_on_update_and_skipped_on_uninstall() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            let desktop = known.join("desktop").join("winsmux.lnk");
            fs::remove_file(&desktop).unwrap();
            reset_steps(None, false);
            let update = execute(&f);
            assert_eq!(update.as_ref().err(), None, "a product link already gone must not stop the update");
            assert!(update.unwrap().durable_commit);
            assert_foreign_parked(&f, &known, &foreign);
            let state = old(&f).unwrap().0;
            assert_eq!(state.shortcuts.len(), 2);
            assert_eq!(state.shortcuts.iter().find(|s| s.kind == "desktop").unwrap().member.sha256, hash(&fs::read(&desktop).unwrap()));
            fs::remove_file(&desktop).unwrap();
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            let uninstall = execute(&f);
            assert_eq!(uninstall.as_ref().err(), None, "a product link already gone must not stop the uninstall");
            assert!(uninstall.unwrap().durable_commit);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
            assert_foreign_live(&f, &known, &foreign);
        }
        #[test]
        fn product_link_recreated_by_another_install_is_occupied_until_the_user_moves_it() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            let before = old(&f).unwrap().1;
            let desktop = known.join("desktop").join("winsmux.lnk");
            fs::remove_file(&desktop).unwrap();
            fs::write(&desktop, b"recreated by the other install").unwrap();
            reset_steps(None, false);
            assert_eq!(execute(&f).err(), Some(Error::Occupied), "update");
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert_eq!(execute(&f).err(), Some(Error::Occupied), "uninstall");
            assert_eq!(fs::read(&desktop).unwrap(), b"recreated by the other install");
            parked_bytes_intact(&f, &foreign);
            assert_eq!(old(&f).unwrap().1, before, "owned state changed by a refusal");
            fs::remove_file(&desktop).unwrap();
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert_foreign_live(&f, &known, &foreign);
        }
        /// Update and uninstall both refuse with `expected`, and neither touches the owned state or
        /// the parked links.
        fn refuse_update_and_uninstall(f: &mut Fixture, foreign: &[(String, Vec<u8>)], expected: Error, case: &str) {
            let before = old(f).unwrap().1;
            for action in [Action::Install, Action::Uninstall] {
                f.ctx.action = action;
                reset_steps(None, false);
                assert_eq!(execute(f).err(), Some(expected), "{case}: {action:?}");
            }
            f.ctx.action = Action::Install;
            reset_steps(None, false);
            parked_bytes_intact(f, foreign);
            assert_eq!(old(f).unwrap().1, before, "{case}: owned state changed by a refusal");
        }
        #[test]
        fn product_link_edited_in_place_is_unconfirmed_and_a_replacing_file_is_occupied() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            let desktop = known.join("desktop").join("winsmux.lnk");
            let published = fs::read(&desktop).unwrap();
            // Changing the icon in the link's properties rewrites the same file with other bytes.
            let mut edited = published.clone();
            edited.extend_from_slice(b"edited in place");
            fs::write(&desktop, &edited).unwrap();
            refuse_update_and_uninstall(&mut f, &foreign, Error::Member, "edited in place");
            assert_eq!(fs::read(&desktop).unwrap(), edited);
            fs::write(&desktop, &published).unwrap();
            assert!(execute(&f).unwrap().durable_commit, "the link put back is the product link again");
            let replacement = known.join("desktop").join("replacement.lnk");
            fs::write(&replacement, &published).unwrap();
            fs::rename(&replacement, &desktop).unwrap();
            refuse_update_and_uninstall(&mut f, &foreign, Error::Occupied, "the same bytes in another file");
            assert_eq!(fs::read(&desktop).unwrap(), published);
        }
        fn set_shortcut_root(root: &Path) {
            hooks::MOCK.with(|m| m.borrow_mut().as_mut().unwrap().shortcut_root = Some(root.to_path_buf()));
        }
        /// OneDrive backing up the Desktop, or the user moving it from its properties, points the
        /// known folders at new, empty folders while the old ones keep their links.
        fn move_known_folders(f: &Fixture) -> PathBuf {
            let moved = f.base.join("moved-known-folders");
            for kind in ["desktop", "start_menu"] {
                fs::create_dir_all(moved.join(kind)).unwrap();
            }
            set_shortcut_root(&moved);
            moved
        }
        #[test]
        fn a_moved_known_folder_stops_update_and_uninstall_and_leaves_every_link_where_it_was() {
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            let product = ["desktop", "start_menu"].map(|kind| fs::read(known.join(kind).join("winsmux.lnk")).unwrap());
            let moved = move_known_folders(&f);
            refuse_update_and_uninstall(&mut f, &foreign, Error::FolderMoved, "moved known folders");
            for (kind, bytes) in ["desktop", "start_menu"].iter().zip(&product) {
                assert_eq!(fs::read(known.join(kind).join("winsmux.lnk")).unwrap(), *bytes, "{kind} product link in the recorded folder");
                assert!(!exists(&moved.join(kind).join("winsmux.lnk")).unwrap(), "{kind} link written to the moved folder");
            }
            set_shortcut_root(&known);
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit, "uninstall with the folders back in place");
            assert_foreign_live(&f, &known, &foreign);
        }
        #[test]
        fn a_known_folder_moved_during_an_interrupted_uninstall_stops_recovery_until_it_is_back() {
            let (mut good, _, _) = foreign_shortcut_fixture();
            assert!(execute(&good).unwrap().durable_commit);
            good.ctx.action = Action::Uninstall;
            operation_trace(&good);
            let trace = hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().proof_trace.clone());
            let at = trace.iter().position(|(label, key)| label == "move_after" && key.contains("old:desktop:MoveIntent")).unwrap() + 1;
            let (mut f, known, foreign) = foreign_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            f.ctx.action = Action::Uninstall;
            crash_at(&f, at);
            let journal = f.root.path.join(CONTROL).join("pending.json");
            let pending = fs::read(&journal).unwrap();
            assert!(!exists(&known.join("desktop").join("winsmux.lnk")).unwrap(), "the product link is in the operation's backup");
            let moved = move_known_folders(&f);
            assert_eq!(recover_if_readable(&f), Err(Error::FolderMoved));
            assert_eq!(fs::read(&journal).unwrap(), pending, "recovery data changed by a refusal");
            for kind in ["desktop", "start_menu"] {
                assert!(!exists(&moved.join(kind).join("winsmux.lnk")).unwrap(), "{kind} link restored into the moved folder");
            }
            parked_bytes_intact(&f, &foreign);
            set_shortcut_root(&known);
            recover_if_readable(&f).unwrap();
            assert_foreign_parked(&f, &known, &foreign);
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit, "uninstall after the recovery");
            assert_foreign_live(&f, &known, &foreign);
        }
        /// Desktop and Start menu links the install publishes, with no foreign link in either folder.
        fn product_shortcut_fixture() -> (Fixture, PathBuf) {
            let mut f = fixture();
            let known = f.base.join("synthetic-known-folders");
            set_shortcut_root(&known);
            for kind in ["desktop", "start_menu"] {
                fs::create_dir_all(known.join(kind)).unwrap();
                enable_shortcut_source(&mut f, kind);
            }
            reset_steps(None, false);
            (f, known)
        }
        // The 23b679cc helper recorded no folder. A link of its state still in place passes the exact
        // check, which binds its file identity, and stays unrecorded until it is published again. A
        // missing one may be deleted or may sit in a folder that has moved, so it is not taken as removed.
        #[test]
        fn a_state_without_folder_records_keeps_links_in_place_and_refuses_a_missing_one() {
            let (mut f, known) = product_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            write_pre_preserved_state(&f);
            assert!(execute(&f).unwrap().durable_commit, "update");
            assert!(!String::from_utf8(old(&f).unwrap().1).unwrap().contains("\"folder\""), "a kept link gains no record");
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit, "uninstall");
            for kind in ["desktop", "start_menu"] {
                assert!(!exists(&known.join(kind).join("winsmux.lnk")).unwrap(), "{kind} link left after uninstall");
            }
            let (mut f, known) = product_shortcut_fixture();
            assert!(execute(&f).unwrap().durable_commit);
            write_pre_preserved_state(&f);
            let start_menu = fs::read(known.join("start_menu").join("winsmux.lnk")).unwrap();
            fs::remove_file(known.join("desktop").join("winsmux.lnk")).unwrap();
            refuse_update_and_uninstall(&mut f, &[], Error::Member, "a missing link without a folder record");
            assert!(!exists(&known.join("desktop").join("winsmux.lnk")).unwrap());
            assert_eq!(fs::read(known.join("start_menu").join("winsmux.lnk")).unwrap(), start_menu);
        }
        /// The objects the 23b679cc helper serialized, named by the field or list that holds them,
        /// with their keys sorted.
        const SHAPES_23B679CC: &[(&str, &[&str])] = &[
            ("installed", &["action", "actor_sid", "generation", "host", "legacy_capture", "members", "operation_id", "plan_bytes", "plan_sha256", "registration", "root", "root_identity", "schema", "shortcuts", "version"]),
            ("journal", &["payload", "schema", "sha256"]),
            ("payload", &["action", "actor_sid", "commit_bytes", "control_identity", "journal_identity", "new", "old", "operation_id", "ops_identity", "owned_dirs", "phase", "plan_bytes", "plan_sha256", "prior_state", "root", "root_identity", "schema", "slots"]),
            ("legacy_capture", &["capture_receipt_sha256", "original_installer_sha256"]),
            ("shortcuts", &["aumid", "kind", "member", "target"]),
            ("old", &["domain", "member", "phase"]),
            ("new", &["domain", "member", "phase"]),
            ("members", &["bytes", "identity", "path", "sha256"]),
            ("member", &["bytes", "identity", "path", "sha256"]),
            ("slots", &["desired", "id", "phase", "prior"]),
            ("registration", &["data", "type"]),
            ("prior", &["data", "type"]),
            ("desired", &["data", "type"]),
            ("owned_dirs", &["identity", "path"]),
            ("identity", &["index", "volume"]),
            ("root_identity", &["index", "volume"]),
            ("journal_identity", &["index", "volume"]),
            ("control_identity", &["index", "volume"]),
            ("ops_identity", &["index", "volume"]),
        ];
        fn assert_23b679cc_shape(value: &serde_json::Value, held_by: &str) {
            match value {
                serde_json::Value::Object(map) => {
                    let expected = SHAPES_23B679CC.iter().find(|(name, _)| *name == held_by).unwrap_or_else(|| panic!("the 23b679cc helper wrote no object in {held_by}")).1;
                    let mut keys: Vec<&str> = map.keys().map(String::as_str).collect();
                    keys.sort();
                    assert_eq!(keys, expected, "keys of an object in {held_by}");
                    for (key, child) in map {
                        assert_23b679cc_shape(child, key);
                    }
                }
                serde_json::Value::Array(items) => items.iter().for_each(|item| assert_23b679cc_shape(item, held_by)),
                _ => {}
            }
        }
        /// Fails unless `text` (installed.json, or pending.json with the states it embeds) has,
        /// at every depth, exactly the keys the 23b679cc helper wrote.
        fn assert_23b679cc_keys(text: &str) {
            let value: serde_json::Value = serde_json::from_str(text).unwrap();
            if value["schema"] == "winsmux-desktop-nsis-installed/v1" {
                return assert_23b679cc_shape(&value, "installed");
            }
            assert_eq!(value["schema"], "winsmux-desktop-nsis-journal/v1");
            assert_23b679cc_shape(&value, "journal");
            for embedded in [&value["payload"]["prior_state"], &value["payload"]["commit_bytes"]] {
                if let Some(bytes) = embedded.as_array() {
                    let bytes: Vec<u8> = bytes.iter().map(|b| b.as_u64().unwrap() as u8).collect();
                    assert_23b679cc_shape(&serde_json::from_slice(&bytes).unwrap(), "installed");
                }
            }
        }
        /// What the 23b679cc helper would have written for this file. That helper wrote no preserved
        /// field and no folder record. The current helper leaves an empty preserved list out, so with
        /// no parked link only the folder records differ, and they are removed here. The key check
        /// pins this premise: a field added later fails here instead of silently turning these
        /// fixtures into current-helper files.
        fn bytes_of_23b679cc(path: &Path) -> String {
            let text = String::from_utf8(fs::read(path).unwrap()).unwrap();
            let needle = ",\"folder\":\"";
            let mut stripped = String::new();
            let mut rest = text.as_str();
            while let Some(at) = rest.find(needle) {
                stripped.push_str(&rest[..at]);
                // A Windows path holds no quote, so the value ends at the next one.
                let value = &rest[at + needle.len()..];
                rest = &value[value.find('"').unwrap() + 1..];
            }
            stripped.push_str(rest);
            assert_23b679cc_keys(&stripped);
            stripped
        }
        fn write_pre_preserved_state(f: &Fixture) {
            let state = f.root.path.join(CONTROL).join("installed.json");
            fs::write(&state, bytes_of_23b679cc(&state)).unwrap();
        }
        fn write_pre_preserved_journal(f: &Fixture) {
            let journal = f.root.path.join(CONTROL).join("pending.json");
            let text = bytes_of_23b679cc(&journal);
            let start = text.find("\"payload\":").unwrap() + "\"payload\":".len();
            let payload = &text[start..text.len() - 1];
            let sha = hash(payload.as_bytes());
            let old_sha = text["{\"schema\":\"winsmux-desktop-nsis-journal/v1\",\"sha256\":\"".len()..][..64].to_string();
            fs::write(&journal, text.replacen(&old_sha, &sha, 1)).unwrap();
        }
        #[test]
        fn update_interrupted_by_the_pre_preserved_helper_during_backing_up_is_completed() {
            let good = mode_fixture("managed");
            let trace = operation_trace(&good);
            let at = trace.iter().position(|l| l == "move_after").unwrap() + 1;
            let f = mode_fixture("managed");
            write_pre_preserved_state(&f);
            let previous = old(&f).unwrap().0;
            assert!(previous.preserved.is_empty());
            crash_at(&f, at);
            assert!(exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap());
            write_pre_preserved_journal(&f);
            let result = execute(&f);
            assert_eq!(result.as_ref().err(), None, "the pre-preserved journal must be recovered, not refused");
            assert!(result.unwrap().durable_commit);
            let state = old(&f).unwrap().0;
            assert_ne!(state.operation_id, previous.operation_id);
            assert_previous(&f, &state);
            assert!(!exists(&f.root.path.join(CONTROL).join("pending.json")).unwrap());
        }
        #[test]
        fn install_committed_by_the_pre_preserved_helper_is_admitted_for_update_and_uninstall() {
            let mut f = mode_fixture("managed");
            write_pre_preserved_state(&f);
            let previous = old(&f).unwrap().0;
            assert!(execute(&f).unwrap().durable_commit);
            assert_ne!(old(&f).unwrap().0.operation_id, previous.operation_id);
            f.ctx.action = Action::Uninstall;
            reset_steps(None, false);
            assert!(execute(&f).unwrap().durable_commit);
            assert!(!exists(&f.root.path.join(CONTROL).join("installed.json")).unwrap());
        }
        #[test]
        fn observed_open_native_readonly_and_mutable_success_missing_and_sharing() {
            for mutable in [false, true] {
                let f = observed_open_fixture();
                let probe = f.base.join("open-probe.bin");
                fs::write(&probe, b"owned observed-open probe").unwrap();
                let before = observed_open_snapshot(&f);
                let expected = observed_open_bytes(&probe, "open-probe.bin");
                let successful = observe(&probe, "open-probe.bin", mutable).expect("successful observed open");
                assert!(successful.member == expected.0, "successful open changed identity or digest");
                drop(successful);
                let missing = observe(&f.base.join("absent.bin"), "absent.bin", mutable).map(|_| ());
                assert_eq!(missing, Err(Error::Member), "missing observed leaf classification");
                let missing_parent = observe(&f.base.join("absent-parent/member.bin"), "member.bin", mutable).map(|_| ());
                assert!(matches!(missing_parent, Err(Error::Path(_))), "missing ancestor left its Path responsibility");
                let blocker = OpenOptions::new().read(true).share_mode(0).open(&probe).unwrap();
                let locked = observe(&probe, "open-probe.bin", mutable).map(|_| ());
                assert_eq!(locked, Err(Error::Busy), "real sharing conflict classification");
                drop(blocker);
                assert!(observed_open_bytes(&probe, "open-probe.bin") == expected, "probe bytes or identity changed");
                assert!(observed_open_snapshot(&f) == before, "protected state changed during observed opens");
                let released = f.base.join("released-probe.bin");
                fs::rename(&probe, &released).expect("successful and refused observed-open handles released");
                assert!(observed_open_bytes(&released, "open-probe.bin") == expected, "rename changed probe bytes or identity");
            }
        }
        #[test]
        fn observed_open_native_hash_source_refusal_preserves_owned_state() {
            let f = observed_open_fixture();
            fs::write(f.ctx.source.join("winsmux-app.exe"), b"tampered source GUI").unwrap();
            let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
            let before = observed_open_snapshot(&f);
            reset_steps(None, false);
            let result = source_rows(&f.ctx, &plan).map(|_| ());
            assert_eq!(result, Err(Error::Member), "hash source GUI classification");
            assert!(observed_open_snapshot(&f) == before, "protected state changed after hash refusal");
            assert_eq!(hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps), 0);
        }
        #[test]
        fn observed_open_native_installed_and_control_absence_preserves_owned_state() {
            for relative in ["winsmux-app.exe", ".winsmux-desktop/installed.json"] {
                let f = observed_open_fixture();
                let target = f.root.path.join(relative);
                let member = observed_open_bytes(&target, relative).0;
                fs::remove_file(&target).unwrap();
                let before = observed_open_snapshot(&f);
                reset_steps(None, false);
                for mutable in [false, true] {
                    assert_eq!(exact(&target, &member, mutable).map(|_| ()), Err(Error::Member), "missing expected installed/control leaf classification");
                }
                assert_eq!(read_plain(&target).map(|_| ()), Err(Error::Member), "missing control/read-only leaf classification");
                let admitted = admit_previous(&f.root, "S-1-5-21-100", &f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256));
                if relative == "winsmux-app.exe" {
                    assert!(admitted.is_err(), "missing installed member became ownership");
                    assert_eq!(hooks::MOCK.with(|m| m.borrow().as_ref().unwrap().steps), 0);
                } else {
                    // Without installed.json the root is a first install. Its registration is
                    // still live, so the transaction refuses before anything moves.
                    assert!(admitted.unwrap().0.is_none(), "missing control member became ownership");
                    assert_eq!(execute(&f).err(), Some(Error::Registration), "orphaned registration classification");
                }
                assert!(observed_open_snapshot(&f) == before, "protected state changed after installed/control absence");
            }
        }
        #[test]
        fn stage_tamper_in_every_source_role_refuses_before_old_mutation() {
            for relative in [
                "winsmux-app.exe",
                "winsmux.exe",
                "winsmux-workspace-mcp.exe",
                PLAN_FILE,
                "uninstall.exe",
            ] {
                let f = fixture();
                execute(&f).unwrap();
                let previous = old(&f).unwrap().0;
                let plan = checked_plan(&f.plan_bytes, &sha256_hex(&f.ctx.plan_sha256)).unwrap();
                let sources = source_rows(&f.ctx, &plan).unwrap();
                fs::write(f.ctx.source.join(relative), b"changed after admission").unwrap();
                assert!(run_transaction(
                    &f.ctx,
                    &f.root,
                    "S-1-5-21-100".into(),
                    f.plan_bytes.clone(),
                    plan,
                    old(&f),
                    sources,
                    None,
                )
                .is_err());
                assert_previous(&f, &previous);
                assert!(admit_control_namespace(&f.root, None, &[]).is_ok());
            }
        }
        #[test]
        fn every_uninstall_mutation_and_crash_cut_preserves_state_or_commits_removal() {
            identity_uninstall_cuts(false);
        }
    }
}

#[cfg(test)]
mod legacy_language_tests {
    use super::*;
    fn profile(language: serde_json::Value, value: Option<RawValue>) -> serde_json::Value {
        let mut registration = vec![None; 22];
        registration[1] = value;
        serde_json::json!({"root":"C:\\captured", "language":language,
            "registration":registration, "shortcuts":[]})
    }
    #[test]
    fn nullable_legacy_language_exact_raw_binding() {
        for (language, value) in [
            (None, None),
            (Some(1033), Some(sz("1033"))),
            (Some(1041), Some(sz("1041"))),
        ] {
            let parsed: LegacyProfile =
                serde_json::from_value(profile(serde_json::json!(language), value)).unwrap();
            assert!(legacy_language_matches(&parsed));
            assert_eq!(parsed.language, language);
        }
        for (language, value) in [
            (None, Some(sz("1033"))),
            (Some(1033), None),
            (Some(1041), Some(sz("1033"))),
            (Some(0), None),
            (Some(1042), Some(sz("1042"))),
            (
                Some(1033),
                Some(RawValue {
                    kind: 4,
                    data: vec![9, 4, 0, 0],
                }),
            ),
            (
                Some(1033),
                Some(RawValue {
                    kind: 1,
                    data: b"1033\0".to_vec(),
                }),
            ),
            (
                Some(1033),
                Some(RawValue {
                    kind: 1,
                    data: vec![0, 0xd8, 0, 0],
                }),
            ),
            (
                Some(1033),
                Some(RawValue {
                    kind: 1,
                    data: vec![49, 0, 48, 0, 51, 0, 51, 0],
                }),
            ),
            (
                Some(1033),
                Some(RawValue {
                    kind: 1,
                    data: vec![49, 0, 48, 0, 51, 0, 51, 0, 0, 0, 0, 0],
                }),
            ),
            (Some(1033), Some(sz("1033\0foreign"))),
        ] {
            let parsed: LegacyProfile =
                serde_json::from_value(profile(serde_json::json!(language), value)).unwrap();
            assert!(!legacy_language_matches(&parsed));
        }
        let mut missing_slot: LegacyProfile =
            serde_json::from_value(profile(serde_json::Value::Null, None)).unwrap();
        missing_slot.registration.clear();
        assert!(!legacy_language_matches(&missing_slot));
    }
    #[test]
    fn nullable_legacy_language_strict_json_requires_the_field() {
        let good = profile(serde_json::Value::Null, None);
        for field in ["root", "language", "registration", "shortcuts"] {
            let mut missing = good.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(serde_json::from_value::<LegacyProfile>(missing).is_err());
        }
        for raw in [
            serde_json::json!({"type":1}),
            serde_json::json!({"data":[0,0]}),
            serde_json::json!({"type":-1,"data":[]}),
            serde_json::json!({"type":1,"data":[256]}),
            serde_json::json!({"type":1,"data":"1033"}),
            serde_json::json!({"type":1,"data":[],"guess":true}),
        ] {
            let mut invalid = good.clone();
            invalid["registration"][1] = raw;
            assert!(serde_json::from_value::<LegacyProfile>(invalid).is_err());
        }
        for value in [
            serde_json::json!("1033"),
            serde_json::json!(true),
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!(4294967296u64),
            serde_json::json!([]),
            serde_json::json!({}),
        ] {
            assert!(serde_json::from_value::<LegacyProfile>(profile(value, None)).is_err());
        }
        let mut unknown = good.clone();
        unknown["guess"] = serde_json::json!(1033);
        assert!(serde_json::from_value::<LegacyProfile>(unknown).is_err());
        let duplicate = serde_json::to_string(&good).unwrap().replacen(
            "\"language\":null",
            "\"language\":null,\"language\":1033",
            1,
        );
        assert!(serde_json::from_str::<LegacyProfile>(&duplicate).is_err());
    }
}

#[cfg(test)]
mod license_authority_tests {
    use super::*;
    fn plan(current: bool) -> Vec<u8> {
        let mut rows=vec![
            serde_json::json!({"role":"gui","path":"winsmux-app.exe","bytes":1,"sha256":"01".repeat(32)}),
            serde_json::json!({"role":"cli","path":"winsmux.exe","bytes":1,"sha256":"01".repeat(32)}),
            serde_json::json!({"role":"mcp","path":"winsmux-workspace-mcp.exe","bytes":1,"sha256":"01".repeat(32)}),
        ];
        if current {
            let authority:serde_json::Value=serde_json::from_str(include_str!("desktop_current_licenses_v0380.json")).unwrap();
            rows.extend(authority["files"].as_array().unwrap().iter().map(|tuple|{let mut row=tuple.clone();row["role"]="license".into();row}));
        } else {
            let fixed:Legacy=serde_json::from_str(LEGACY).unwrap();
            rows.extend(fixed.files.iter().filter(|row|row.role=="license").map(|row|serde_json::json!({"role":"license","path":row.path,"bytes":row.bytes,"sha256":row.sha256})));
        }
        serde_json::to_vec(&serde_json::json!({"schema":"winsmux-desktop-install-plan/v1","flavor":"nsis","version":VERSION,"host":HOST,"files":rows})).unwrap()
    }
    fn owned(bytes:&[u8])->bool {checked_owned_plan(bytes,&hash(bytes)).is_ok()}
    fn members(bytes:&[u8])->Vec<Member> {
        let p:crate::desktop_install::InstallPlan=serde_json::from_slice(bytes).unwrap();
        let mut rows:Vec<_>=p.files.iter().enumerate().map(|(i,row)|Member{path:row.path.clone(),bytes:row.bytes,sha256:row.sha256.clone(),identity:Identity{volume:"test-only".into(),index:i as u64+1}}).collect();
        for (path,length,digest) in [(PLAN_FILE,bytes.len() as u64,hash(bytes)),("uninstall.exe",1,"01".repeat(32))] {
            rows.push(Member{path:path.into(),bytes:length,sha256:digest,identity:Identity{volume:"test-only".into(),index:rows.len() as u64+1}});
        }
        rows
    }
    #[test]
    fn current_incoming_and_exact_current_or_historical_ownership_are_distinct() {
        let current=plan(true);let old=plan(false);
        assert!(checked_plan(&current,&hash(&current)).is_ok());assert!(checked_plan(&old,&hash(&old)).is_err());
        for bytes in [&current,&old] {assert!(owned(bytes));assert!(member_inventory_valid(&members(bytes),bytes,&hash(bytes)).is_ok());}
        let current_value:serde_json::Value=serde_json::from_slice(&current).unwrap();
        let mut hybrid:serde_json::Value=serde_json::from_slice(&old).unwrap();
        for row in current_value["files"].as_array().unwrap().iter().filter(|row|row["role"]=="license") {
            if !hybrid["files"].as_array().unwrap().iter().any(|known|known["path"]==row["path"]) {hybrid["files"].as_array_mut().unwrap().push(row.clone());}
        }
        let bytes=serde_json::to_vec(&hybrid).unwrap();assert!(!owned(&bytes));
        assert!(member_inventory_valid(&members(&bytes),&bytes,&hash(&bytes)).is_err());
    }
    #[test]
    fn complete_profiles_reject_subsets_hybrids_and_self_consistent_forged_member_state() {
        for current in [false,true] {
            let good=plan(current);let value:serde_json::Value=serde_json::from_slice(&good).unwrap();
            for mode in ["missing","extra","duplicate","case","bytes","hash","role"] {
                let mut bad=value.clone();let index=bad["files"].as_array().unwrap().iter().position(|r|r["role"]=="license").unwrap();
                match mode {
                    "missing"=>{bad["files"].as_array_mut().unwrap().remove(index);},
                    "extra"=>{let mut row=bad["files"][index].clone();row["path"]="licenses/extra.txt".into();bad["files"].as_array_mut().unwrap().push(row);},
                    "duplicate"=>{let row=bad["files"][index].clone();bad["files"].as_array_mut().unwrap().push(row);},
                    "case"=>bad["files"][index]["path"]=bad["files"][index]["path"].as_str().unwrap().to_uppercase().into(),
                    "bytes"=>bad["files"][index]["bytes"]=(bad["files"][index]["bytes"].as_u64().unwrap()+1).into(),
                    "hash"=>bad["files"][index]["sha256"]="00".repeat(32).into(),
                    "role"=>bad["files"][index]["role"]="unknown".into(),
                    _=>unreachable!(),
                }
                let bytes=serde_json::to_vec(&bad).unwrap();assert!(!owned(&bytes),"{current} {mode}");
                assert!(member_inventory_valid(&members(&bytes),&bytes,&hash(&bytes)).is_err(),"forged self-consistent state {current} {mode}");
            }
            let mut rows=members(&good);rows[0].sha256="00".repeat(32);assert!(member_inventory_valid(&rows,&good,&hash(&good)).is_err());
        }
    }
}
