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
pub(crate) fn parse_install_plan_shape(
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

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CurrentLicenseAuthority {
    schema: String,
    version: String,
    host: String,
    binding_sha256: String,
    policy_sha256: String,
    input_sha256: String,
    catalog_sha256: String,
    files: Vec<CurrentLicenseTuple>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CurrentLicenseTuple {
    path: String,
    bytes: u64,
    sha256: String,
}

pub(crate) fn current_license_inventory() -> Result<&'static [InstallMember], DesktopInstallError> {
    static CURRENT: std::sync::OnceLock<Result<Vec<InstallMember>, DesktopInstallError>> = std::sync::OnceLock::new();
    CURRENT.get_or_init(|| {
        let source: CurrentLicenseAuthority = serde_json::from_str(include_str!("desktop_current_licenses_v0380.json"))
            .map_err(|_| DesktopInstallError::Plan)?;
        if source.schema != "winsmux-desktop-current-licenses/v1" || source.version != "0.38.0" || source.host != HOST
            || source.binding_sha256 != "657393576db1a503d75de3ba90480ea804b2d7c6dceb42c7f0a40a31ed5d1110"
            || source.policy_sha256 != "747a0f64e59b81b1908559c3adc1c7c16ca0b8b1f9f2a34e8036de8696e08bc1"
            || source.input_sha256 != "fef0dfe3322dfc45db7be1c4de6c492075265e80b5414d60bef14a24fa10f471"
            || source.catalog_sha256 != "7b15a31bbaa0f5865be35c6d2c117f95c41d8a3acff8664e042cc8b5fbe879e4"
            || source.files.is_empty()
        { return Err(DesktopInstallError::Plan); }
        let mut names = HashSet::new();
        let mut previous: Option<String> = None;
        let mut rows = Vec::new();
        for row in source.files {
            if !valid_member_path(&row.path) || !row.path.starts_with("licenses/") || row.bytes == 0
                || parse_sha256(&row.sha256).is_err() || !names.insert(row.path.to_lowercase())
                || previous.as_ref().is_some_and(|last| last >= &row.path)
            { return Err(DesktopInstallError::Plan); }
            previous = Some(row.path.clone());
            rows.push(InstallMember { role: "license".into(), path: row.path, bytes: row.bytes, sha256: row.sha256 });
        }
        if !names.contains("licenses/manifest.json") || !names.contains("licenses/third_party_notices.txt") {
            return Err(DesktopInstallError::Plan);
        }
        Ok(rows)
    }).as_ref().map(Vec::as_slice).map_err(|error| *error)
}

/// Complete tuple equality. Callers first validate the plan shape and case uniqueness.
pub(crate) fn license_inventory_matches(rows: &[InstallMember], expected: &[InstallMember]) -> bool {
    let expected: Vec<_> = expected.iter().filter(|row| row.role == "license").collect();
    let received: Vec<_> = rows.iter().filter(|row| row.role == "license").collect();
    !expected.is_empty() && received.len() == expected.len() && received.iter().all(|row| {
        expected.iter().any(|known| row.path == known.path && row.bytes == known.bytes && row.sha256 == known.sha256)
    })
}

pub(crate) fn validate_current_license_inventory(rows: &[InstallMember]) -> Result<(), DesktopInstallError> {
    if !license_inventory_matches(rows, current_license_inventory()?) { return Err(DesktopInstallError::Plan); }
    Ok(())
}

/// Incoming Desktop payloads always use the complete current embedded authority.
pub fn parse_install_plan(bytes: &[u8], expected: [u8; 32], flavor: &str, version: &str) -> Result<InstallPlan, DesktopInstallError> {
    let plan = parse_install_plan_shape(bytes, expected, flavor, version)?;
    if plan.version != "0.38.0" { return Err(DesktopInstallError::Plan); }
    validate_current_license_inventory(&plan.files)?;
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

// Diagnostic-only MSI observation. No path or caller-controlled value is retained.
mod msi_path_observation {
    use super::DesktopInstallError;
    use std::cell::Cell;
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum Site { MsiRoot, MsiPlanFile, MsiMemberParent, MsiMemberFile, SharedGuiParent, SharedGuiFile, TempParent, OperationRoot, LoadedGuiImage }
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum Reason { InfoNotFound, InfoAccessDenied, InfoSharing, InfoInvalidName, InfoNameTooLong, InfoOther, FinalQueryNotFound, FinalQueryAccessDenied, FinalQuerySharing, FinalQueryInvalidName, FinalQueryNameTooLong, FinalQueryOther, FinalReadNotFound, FinalReadAccessDenied, FinalReadSharing, FinalReadInvalidName, FinalReadNameTooLong, FinalReadOther, Reparse, FinalReadLength, FinalUtf16, FinalNamespace, DirectoryOpenNotFound, DirectoryOpenAccessDenied, DirectoryOpenSharing, DirectoryOpenInvalidName, DirectoryOpenNameTooLong, DirectoryOpenOther, NotDirectory, CanonicalMismatch, DriveShape, ComponentUnsafe, TildeExpandsStrict, TildeRemainsLong, TildeLookupUnconfirmed, IsDirectory, LinkCount, PathTextNonunicode, LoadedNameUtf16 }
    #[derive(Clone, Copy)]
    struct State {
        active: bool,
        site: Option<Site>,
        reason: Option<Reason>,
        first: Option<i32>,
    }
    impl State { const fn inactive() -> Self {
        Self { active: false, site: None, reason: None, first: None }
    } }
    thread_local! { static STATE: Cell<State> = const { Cell::new(State::inactive()) }; }
    pub(super) struct Session(State);
    impl Session {
        pub(super) fn begin() -> Self {
            Self(STATE.with(|s| s.replace(State { active: true, ..State::inactive() })))
        }
    }
    impl Drop for Session {
        fn drop(&mut self) { STATE.with(|s| s.set(self.0)); }
    }
    struct Scope(State);
    impl Drop for Scope {
        fn drop(&mut self) {
            STATE.with(|s| {
                let first = s.get().first;
                s.set(State { first, ..self.0 });
            });
        }
    }
    pub(super) fn active_site() -> bool {
        STATE.with(|s| { let v=s.get(); v.active && v.site.is_some() })
    }
    pub(super) fn note(reason: Reason) {
        STATE.with(|s| {
            let mut v=s.get();
            if v.active && v.site.is_some() && v.reason.is_none() { v.reason=Some(reason); s.set(v); }
        });
    }
    pub(super) fn boundary<T>(site: Site, call: impl FnOnce() -> Result<T, DesktopInstallError>) -> Result<T, DesktopInstallError> {
        let before=STATE.with(Cell::get);
        if !before.active { return call(); }
        STATE.with(|s| s.set(State { site: Some(site), reason: None, ..before }));
        let scope=Scope(before);
        let result=call();
        if matches!(&result, Err(DesktopInstallError::Path)) {
            STATE.with(|s| {
                let mut v=s.get();
                if v.first.is_none() {
                    v.first=Some(v.reason.and_then(|reason| code(site,reason)).unwrap_or(66));
                    s.set(v);
                }
            });
        }
        drop(scope);
        result
    }
    pub(super) fn path_exit() -> i32 { STATE.with(|s| s.get().first.unwrap_or(66)) }
    pub(super) fn code(site: Site, reason: Reason) -> Option<i32> {
        match (site,reason) {
            (Site::MsiRoot, Reason::InfoNotFound) => Some(1000),
            (Site::MsiRoot, Reason::InfoAccessDenied) => Some(1001),
            (Site::MsiRoot, Reason::InfoSharing) => Some(1002),
            (Site::MsiRoot, Reason::InfoInvalidName) => Some(1003),
            (Site::MsiRoot, Reason::InfoNameTooLong) => Some(1004),
            (Site::MsiRoot, Reason::InfoOther) => Some(1005),
            (Site::MsiRoot, Reason::FinalQueryNotFound) => Some(1006),
            (Site::MsiRoot, Reason::FinalQueryAccessDenied) => Some(1007),
            (Site::MsiRoot, Reason::FinalQuerySharing) => Some(1008),
            (Site::MsiRoot, Reason::FinalQueryInvalidName) => Some(1009),
            (Site::MsiRoot, Reason::FinalQueryNameTooLong) => Some(1010),
            (Site::MsiRoot, Reason::FinalQueryOther) => Some(1011),
            (Site::MsiRoot, Reason::FinalReadNotFound) => Some(1012),
            (Site::MsiRoot, Reason::FinalReadAccessDenied) => Some(1013),
            (Site::MsiRoot, Reason::FinalReadSharing) => Some(1014),
            (Site::MsiRoot, Reason::FinalReadInvalidName) => Some(1015),
            (Site::MsiRoot, Reason::FinalReadNameTooLong) => Some(1016),
            (Site::MsiRoot, Reason::FinalReadOther) => Some(1017),
            (Site::MsiRoot, Reason::Reparse) => Some(1018),
            (Site::MsiRoot, Reason::FinalReadLength) => Some(1019),
            (Site::MsiRoot, Reason::FinalUtf16) => Some(1020),
            (Site::MsiRoot, Reason::FinalNamespace) => Some(1021),
            (Site::MsiRoot, Reason::DirectoryOpenNotFound) => Some(1022),
            (Site::MsiRoot, Reason::DirectoryOpenAccessDenied) => Some(1023),
            (Site::MsiRoot, Reason::DirectoryOpenSharing) => Some(1024),
            (Site::MsiRoot, Reason::DirectoryOpenInvalidName) => Some(1025),
            (Site::MsiRoot, Reason::DirectoryOpenNameTooLong) => Some(1026),
            (Site::MsiRoot, Reason::DirectoryOpenOther) => Some(1027),
            (Site::MsiRoot, Reason::NotDirectory) => Some(1028),
            (Site::MsiRoot, Reason::CanonicalMismatch) => Some(1029),
            (Site::MsiRoot, Reason::DriveShape) => Some(1030),
            (Site::MsiRoot, Reason::ComponentUnsafe) => Some(1031),
            (Site::MsiRoot, Reason::TildeExpandsStrict) => Some(1032),
            (Site::MsiRoot, Reason::TildeRemainsLong) => Some(1033),
            (Site::MsiRoot, Reason::TildeLookupUnconfirmed) => Some(1034),
            (Site::MsiPlanFile, Reason::InfoNotFound) => Some(1035),
            (Site::MsiPlanFile, Reason::InfoAccessDenied) => Some(1036),
            (Site::MsiPlanFile, Reason::InfoSharing) => Some(1037),
            (Site::MsiPlanFile, Reason::InfoInvalidName) => Some(1038),
            (Site::MsiPlanFile, Reason::InfoNameTooLong) => Some(1039),
            (Site::MsiPlanFile, Reason::InfoOther) => Some(1040),
            (Site::MsiPlanFile, Reason::FinalQueryNotFound) => Some(1041),
            (Site::MsiPlanFile, Reason::FinalQueryAccessDenied) => Some(1042),
            (Site::MsiPlanFile, Reason::FinalQuerySharing) => Some(1043),
            (Site::MsiPlanFile, Reason::FinalQueryInvalidName) => Some(1044),
            (Site::MsiPlanFile, Reason::FinalQueryNameTooLong) => Some(1045),
            (Site::MsiPlanFile, Reason::FinalQueryOther) => Some(1046),
            (Site::MsiPlanFile, Reason::FinalReadNotFound) => Some(1047),
            (Site::MsiPlanFile, Reason::FinalReadAccessDenied) => Some(1048),
            (Site::MsiPlanFile, Reason::FinalReadSharing) => Some(1049),
            (Site::MsiPlanFile, Reason::FinalReadInvalidName) => Some(1050),
            (Site::MsiPlanFile, Reason::FinalReadNameTooLong) => Some(1051),
            (Site::MsiPlanFile, Reason::FinalReadOther) => Some(1052),
            (Site::MsiPlanFile, Reason::Reparse) => Some(1053),
            (Site::MsiPlanFile, Reason::FinalReadLength) => Some(1054),
            (Site::MsiPlanFile, Reason::FinalUtf16) => Some(1055),
            (Site::MsiPlanFile, Reason::FinalNamespace) => Some(1056),
            (Site::MsiPlanFile, Reason::IsDirectory) => Some(1057),
            (Site::MsiPlanFile, Reason::LinkCount) => Some(1058),
            (Site::MsiPlanFile, Reason::CanonicalMismatch) => Some(1059),
            (Site::MsiMemberParent, Reason::InfoNotFound) => Some(1060),
            (Site::MsiMemberParent, Reason::InfoAccessDenied) => Some(1061),
            (Site::MsiMemberParent, Reason::InfoSharing) => Some(1062),
            (Site::MsiMemberParent, Reason::InfoInvalidName) => Some(1063),
            (Site::MsiMemberParent, Reason::InfoNameTooLong) => Some(1064),
            (Site::MsiMemberParent, Reason::InfoOther) => Some(1065),
            (Site::MsiMemberParent, Reason::FinalQueryNotFound) => Some(1066),
            (Site::MsiMemberParent, Reason::FinalQueryAccessDenied) => Some(1067),
            (Site::MsiMemberParent, Reason::FinalQuerySharing) => Some(1068),
            (Site::MsiMemberParent, Reason::FinalQueryInvalidName) => Some(1069),
            (Site::MsiMemberParent, Reason::FinalQueryNameTooLong) => Some(1070),
            (Site::MsiMemberParent, Reason::FinalQueryOther) => Some(1071),
            (Site::MsiMemberParent, Reason::FinalReadNotFound) => Some(1072),
            (Site::MsiMemberParent, Reason::FinalReadAccessDenied) => Some(1073),
            (Site::MsiMemberParent, Reason::FinalReadSharing) => Some(1074),
            (Site::MsiMemberParent, Reason::FinalReadInvalidName) => Some(1075),
            (Site::MsiMemberParent, Reason::FinalReadNameTooLong) => Some(1076),
            (Site::MsiMemberParent, Reason::FinalReadOther) => Some(1077),
            (Site::MsiMemberParent, Reason::Reparse) => Some(1078),
            (Site::MsiMemberParent, Reason::FinalReadLength) => Some(1079),
            (Site::MsiMemberParent, Reason::FinalUtf16) => Some(1080),
            (Site::MsiMemberParent, Reason::FinalNamespace) => Some(1081),
            (Site::MsiMemberParent, Reason::DirectoryOpenNotFound) => Some(1082),
            (Site::MsiMemberParent, Reason::DirectoryOpenAccessDenied) => Some(1083),
            (Site::MsiMemberParent, Reason::DirectoryOpenSharing) => Some(1084),
            (Site::MsiMemberParent, Reason::DirectoryOpenInvalidName) => Some(1085),
            (Site::MsiMemberParent, Reason::DirectoryOpenNameTooLong) => Some(1086),
            (Site::MsiMemberParent, Reason::DirectoryOpenOther) => Some(1087),
            (Site::MsiMemberParent, Reason::NotDirectory) => Some(1088),
            (Site::MsiMemberParent, Reason::CanonicalMismatch) => Some(1089),
            (Site::MsiMemberFile, Reason::InfoNotFound) => Some(1090),
            (Site::MsiMemberFile, Reason::InfoAccessDenied) => Some(1091),
            (Site::MsiMemberFile, Reason::InfoSharing) => Some(1092),
            (Site::MsiMemberFile, Reason::InfoInvalidName) => Some(1093),
            (Site::MsiMemberFile, Reason::InfoNameTooLong) => Some(1094),
            (Site::MsiMemberFile, Reason::InfoOther) => Some(1095),
            (Site::MsiMemberFile, Reason::FinalQueryNotFound) => Some(1096),
            (Site::MsiMemberFile, Reason::FinalQueryAccessDenied) => Some(1097),
            (Site::MsiMemberFile, Reason::FinalQuerySharing) => Some(1098),
            (Site::MsiMemberFile, Reason::FinalQueryInvalidName) => Some(1099),
            (Site::MsiMemberFile, Reason::FinalQueryNameTooLong) => Some(1100),
            (Site::MsiMemberFile, Reason::FinalQueryOther) => Some(1101),
            (Site::MsiMemberFile, Reason::FinalReadNotFound) => Some(1102),
            (Site::MsiMemberFile, Reason::FinalReadAccessDenied) => Some(1103),
            (Site::MsiMemberFile, Reason::FinalReadSharing) => Some(1104),
            (Site::MsiMemberFile, Reason::FinalReadInvalidName) => Some(1105),
            (Site::MsiMemberFile, Reason::FinalReadNameTooLong) => Some(1106),
            (Site::MsiMemberFile, Reason::FinalReadOther) => Some(1107),
            (Site::MsiMemberFile, Reason::Reparse) => Some(1108),
            (Site::MsiMemberFile, Reason::FinalReadLength) => Some(1109),
            (Site::MsiMemberFile, Reason::FinalUtf16) => Some(1110),
            (Site::MsiMemberFile, Reason::FinalNamespace) => Some(1111),
            (Site::MsiMemberFile, Reason::IsDirectory) => Some(1112),
            (Site::MsiMemberFile, Reason::LinkCount) => Some(1113),
            (Site::MsiMemberFile, Reason::CanonicalMismatch) => Some(1114),
            (Site::SharedGuiParent, Reason::InfoNotFound) => Some(1115),
            (Site::SharedGuiParent, Reason::InfoAccessDenied) => Some(1116),
            (Site::SharedGuiParent, Reason::InfoSharing) => Some(1117),
            (Site::SharedGuiParent, Reason::InfoInvalidName) => Some(1118),
            (Site::SharedGuiParent, Reason::InfoNameTooLong) => Some(1119),
            (Site::SharedGuiParent, Reason::InfoOther) => Some(1120),
            (Site::SharedGuiParent, Reason::FinalQueryNotFound) => Some(1121),
            (Site::SharedGuiParent, Reason::FinalQueryAccessDenied) => Some(1122),
            (Site::SharedGuiParent, Reason::FinalQuerySharing) => Some(1123),
            (Site::SharedGuiParent, Reason::FinalQueryInvalidName) => Some(1124),
            (Site::SharedGuiParent, Reason::FinalQueryNameTooLong) => Some(1125),
            (Site::SharedGuiParent, Reason::FinalQueryOther) => Some(1126),
            (Site::SharedGuiParent, Reason::FinalReadNotFound) => Some(1127),
            (Site::SharedGuiParent, Reason::FinalReadAccessDenied) => Some(1128),
            (Site::SharedGuiParent, Reason::FinalReadSharing) => Some(1129),
            (Site::SharedGuiParent, Reason::FinalReadInvalidName) => Some(1130),
            (Site::SharedGuiParent, Reason::FinalReadNameTooLong) => Some(1131),
            (Site::SharedGuiParent, Reason::FinalReadOther) => Some(1132),
            (Site::SharedGuiParent, Reason::Reparse) => Some(1133),
            (Site::SharedGuiParent, Reason::FinalReadLength) => Some(1134),
            (Site::SharedGuiParent, Reason::FinalUtf16) => Some(1135),
            (Site::SharedGuiParent, Reason::FinalNamespace) => Some(1136),
            (Site::SharedGuiParent, Reason::DirectoryOpenNotFound) => Some(1137),
            (Site::SharedGuiParent, Reason::DirectoryOpenAccessDenied) => Some(1138),
            (Site::SharedGuiParent, Reason::DirectoryOpenSharing) => Some(1139),
            (Site::SharedGuiParent, Reason::DirectoryOpenInvalidName) => Some(1140),
            (Site::SharedGuiParent, Reason::DirectoryOpenNameTooLong) => Some(1141),
            (Site::SharedGuiParent, Reason::DirectoryOpenOther) => Some(1142),
            (Site::SharedGuiParent, Reason::NotDirectory) => Some(1143),
            (Site::SharedGuiParent, Reason::CanonicalMismatch) => Some(1144),
            (Site::SharedGuiFile, Reason::InfoNotFound) => Some(1145),
            (Site::SharedGuiFile, Reason::InfoAccessDenied) => Some(1146),
            (Site::SharedGuiFile, Reason::InfoSharing) => Some(1147),
            (Site::SharedGuiFile, Reason::InfoInvalidName) => Some(1148),
            (Site::SharedGuiFile, Reason::InfoNameTooLong) => Some(1149),
            (Site::SharedGuiFile, Reason::InfoOther) => Some(1150),
            (Site::SharedGuiFile, Reason::FinalQueryNotFound) => Some(1151),
            (Site::SharedGuiFile, Reason::FinalQueryAccessDenied) => Some(1152),
            (Site::SharedGuiFile, Reason::FinalQuerySharing) => Some(1153),
            (Site::SharedGuiFile, Reason::FinalQueryInvalidName) => Some(1154),
            (Site::SharedGuiFile, Reason::FinalQueryNameTooLong) => Some(1155),
            (Site::SharedGuiFile, Reason::FinalQueryOther) => Some(1156),
            (Site::SharedGuiFile, Reason::FinalReadNotFound) => Some(1157),
            (Site::SharedGuiFile, Reason::FinalReadAccessDenied) => Some(1158),
            (Site::SharedGuiFile, Reason::FinalReadSharing) => Some(1159),
            (Site::SharedGuiFile, Reason::FinalReadInvalidName) => Some(1160),
            (Site::SharedGuiFile, Reason::FinalReadNameTooLong) => Some(1161),
            (Site::SharedGuiFile, Reason::FinalReadOther) => Some(1162),
            (Site::SharedGuiFile, Reason::Reparse) => Some(1163),
            (Site::SharedGuiFile, Reason::FinalReadLength) => Some(1164),
            (Site::SharedGuiFile, Reason::FinalUtf16) => Some(1165),
            (Site::SharedGuiFile, Reason::FinalNamespace) => Some(1166),
            (Site::SharedGuiFile, Reason::IsDirectory) => Some(1167),
            (Site::SharedGuiFile, Reason::LinkCount) => Some(1168),
            (Site::SharedGuiFile, Reason::CanonicalMismatch) => Some(1169),
            (Site::TempParent, Reason::InfoNotFound) => Some(1170),
            (Site::TempParent, Reason::InfoAccessDenied) => Some(1171),
            (Site::TempParent, Reason::InfoSharing) => Some(1172),
            (Site::TempParent, Reason::InfoInvalidName) => Some(1173),
            (Site::TempParent, Reason::InfoNameTooLong) => Some(1174),
            (Site::TempParent, Reason::InfoOther) => Some(1175),
            (Site::TempParent, Reason::FinalQueryNotFound) => Some(1176),
            (Site::TempParent, Reason::FinalQueryAccessDenied) => Some(1177),
            (Site::TempParent, Reason::FinalQuerySharing) => Some(1178),
            (Site::TempParent, Reason::FinalQueryInvalidName) => Some(1179),
            (Site::TempParent, Reason::FinalQueryNameTooLong) => Some(1180),
            (Site::TempParent, Reason::FinalQueryOther) => Some(1181),
            (Site::TempParent, Reason::FinalReadNotFound) => Some(1182),
            (Site::TempParent, Reason::FinalReadAccessDenied) => Some(1183),
            (Site::TempParent, Reason::FinalReadSharing) => Some(1184),
            (Site::TempParent, Reason::FinalReadInvalidName) => Some(1185),
            (Site::TempParent, Reason::FinalReadNameTooLong) => Some(1186),
            (Site::TempParent, Reason::FinalReadOther) => Some(1187),
            (Site::TempParent, Reason::Reparse) => Some(1188),
            (Site::TempParent, Reason::FinalReadLength) => Some(1189),
            (Site::TempParent, Reason::FinalUtf16) => Some(1190),
            (Site::TempParent, Reason::FinalNamespace) => Some(1191),
            (Site::TempParent, Reason::DirectoryOpenNotFound) => Some(1192),
            (Site::TempParent, Reason::DirectoryOpenAccessDenied) => Some(1193),
            (Site::TempParent, Reason::DirectoryOpenSharing) => Some(1194),
            (Site::TempParent, Reason::DirectoryOpenInvalidName) => Some(1195),
            (Site::TempParent, Reason::DirectoryOpenNameTooLong) => Some(1196),
            (Site::TempParent, Reason::DirectoryOpenOther) => Some(1197),
            (Site::TempParent, Reason::NotDirectory) => Some(1198),
            (Site::TempParent, Reason::CanonicalMismatch) => Some(1199),
            (Site::TempParent, Reason::DriveShape) => Some(1200),
            (Site::TempParent, Reason::ComponentUnsafe) => Some(1201),
            (Site::TempParent, Reason::TildeExpandsStrict) => Some(1202),
            (Site::TempParent, Reason::TildeRemainsLong) => Some(1203),
            (Site::TempParent, Reason::TildeLookupUnconfirmed) => Some(1204),
            (Site::TempParent, Reason::PathTextNonunicode) => Some(1205),
            (Site::OperationRoot, Reason::InfoNotFound) => Some(1206),
            (Site::OperationRoot, Reason::InfoAccessDenied) => Some(1207),
            (Site::OperationRoot, Reason::InfoSharing) => Some(1208),
            (Site::OperationRoot, Reason::InfoInvalidName) => Some(1209),
            (Site::OperationRoot, Reason::InfoNameTooLong) => Some(1210),
            (Site::OperationRoot, Reason::InfoOther) => Some(1211),
            (Site::OperationRoot, Reason::FinalQueryNotFound) => Some(1212),
            (Site::OperationRoot, Reason::FinalQueryAccessDenied) => Some(1213),
            (Site::OperationRoot, Reason::FinalQuerySharing) => Some(1214),
            (Site::OperationRoot, Reason::FinalQueryInvalidName) => Some(1215),
            (Site::OperationRoot, Reason::FinalQueryNameTooLong) => Some(1216),
            (Site::OperationRoot, Reason::FinalQueryOther) => Some(1217),
            (Site::OperationRoot, Reason::FinalReadNotFound) => Some(1218),
            (Site::OperationRoot, Reason::FinalReadAccessDenied) => Some(1219),
            (Site::OperationRoot, Reason::FinalReadSharing) => Some(1220),
            (Site::OperationRoot, Reason::FinalReadInvalidName) => Some(1221),
            (Site::OperationRoot, Reason::FinalReadNameTooLong) => Some(1222),
            (Site::OperationRoot, Reason::FinalReadOther) => Some(1223),
            (Site::OperationRoot, Reason::Reparse) => Some(1224),
            (Site::OperationRoot, Reason::FinalReadLength) => Some(1225),
            (Site::OperationRoot, Reason::FinalUtf16) => Some(1226),
            (Site::OperationRoot, Reason::FinalNamespace) => Some(1227),
            (Site::OperationRoot, Reason::DirectoryOpenNotFound) => Some(1228),
            (Site::OperationRoot, Reason::DirectoryOpenAccessDenied) => Some(1229),
            (Site::OperationRoot, Reason::DirectoryOpenSharing) => Some(1230),
            (Site::OperationRoot, Reason::DirectoryOpenInvalidName) => Some(1231),
            (Site::OperationRoot, Reason::DirectoryOpenNameTooLong) => Some(1232),
            (Site::OperationRoot, Reason::DirectoryOpenOther) => Some(1233),
            (Site::OperationRoot, Reason::NotDirectory) => Some(1234),
            (Site::OperationRoot, Reason::CanonicalMismatch) => Some(1235),
            (Site::LoadedGuiImage, Reason::InfoNotFound) => Some(1236),
            (Site::LoadedGuiImage, Reason::InfoAccessDenied) => Some(1237),
            (Site::LoadedGuiImage, Reason::InfoSharing) => Some(1238),
            (Site::LoadedGuiImage, Reason::InfoInvalidName) => Some(1239),
            (Site::LoadedGuiImage, Reason::InfoNameTooLong) => Some(1240),
            (Site::LoadedGuiImage, Reason::InfoOther) => Some(1241),
            (Site::LoadedGuiImage, Reason::FinalQueryNotFound) => Some(1242),
            (Site::LoadedGuiImage, Reason::FinalQueryAccessDenied) => Some(1243),
            (Site::LoadedGuiImage, Reason::FinalQuerySharing) => Some(1244),
            (Site::LoadedGuiImage, Reason::FinalQueryInvalidName) => Some(1245),
            (Site::LoadedGuiImage, Reason::FinalQueryNameTooLong) => Some(1246),
            (Site::LoadedGuiImage, Reason::FinalQueryOther) => Some(1247),
            (Site::LoadedGuiImage, Reason::FinalReadNotFound) => Some(1248),
            (Site::LoadedGuiImage, Reason::FinalReadAccessDenied) => Some(1249),
            (Site::LoadedGuiImage, Reason::FinalReadSharing) => Some(1250),
            (Site::LoadedGuiImage, Reason::FinalReadInvalidName) => Some(1251),
            (Site::LoadedGuiImage, Reason::FinalReadNameTooLong) => Some(1252),
            (Site::LoadedGuiImage, Reason::FinalReadOther) => Some(1253),
            (Site::LoadedGuiImage, Reason::Reparse) => Some(1254),
            (Site::LoadedGuiImage, Reason::FinalReadLength) => Some(1255),
            (Site::LoadedGuiImage, Reason::FinalUtf16) => Some(1256),
            (Site::LoadedGuiImage, Reason::FinalNamespace) => Some(1257),
            (Site::LoadedGuiImage, Reason::IsDirectory) => Some(1258),
            (Site::LoadedGuiImage, Reason::LinkCount) => Some(1259),
            (Site::LoadedGuiImage, Reason::CanonicalMismatch) => Some(1260),
            (Site::LoadedGuiImage, Reason::DriveShape) => Some(1261),
            (Site::LoadedGuiImage, Reason::ComponentUnsafe) => Some(1262),
            (Site::LoadedGuiImage, Reason::TildeExpandsStrict) => Some(1263),
            (Site::LoadedGuiImage, Reason::TildeRemainsLong) => Some(1264),
            (Site::LoadedGuiImage, Reason::TildeLookupUnconfirmed) => Some(1265),
            (Site::LoadedGuiImage, Reason::LoadedNameUtf16) => Some(1266),
            _ => None,
        }
    }
    pub(super) fn api_reason(api: u8, error: u32) -> Reason {
        let bucket = match error { 2|3 => 0, 5 => 1, 32|33 => 2, 123|161 => 3, 206 => 4, _ => 5 };
        const REASONS: [[Reason;6];4] = [
            [Reason::InfoNotFound, Reason::InfoAccessDenied, Reason::InfoSharing, Reason::InfoInvalidName, Reason::InfoNameTooLong, Reason::InfoOther],
            [Reason::FinalQueryNotFound, Reason::FinalQueryAccessDenied, Reason::FinalQuerySharing, Reason::FinalQueryInvalidName, Reason::FinalQueryNameTooLong, Reason::FinalQueryOther],
            [Reason::FinalReadNotFound, Reason::FinalReadAccessDenied, Reason::FinalReadSharing, Reason::FinalReadInvalidName, Reason::FinalReadNameTooLong, Reason::FinalReadOther],
            [Reason::DirectoryOpenNotFound, Reason::DirectoryOpenAccessDenied, Reason::DirectoryOpenSharing, Reason::DirectoryOpenInvalidName, Reason::DirectoryOpenNameTooLong, Reason::DirectoryOpenOther],
        ];
        REASONS[api as usize][bucket]
    }
}

// T-only CI fault fixture; never part of the normal distribution source.
const MSI_FAULT_REQUEST: &str = "msi-startup-fault-request.json";
const MSI_FAULT_CONSUMED: &str = "msi-startup-fault-consumed.json";
const MSI_FAULT_REQUEST_SCHEMA: &str = "winsmux-msi-startup-fault-request/v1";
const MSI_FAULT_CONSUMED_SCHEMA: &str = "winsmux-msi-startup-fault-consumed/v1";
const MSI_FAULT_REQUEST_LIMIT: usize = b"{\"schema\":\"winsmux-msi-startup-fault-request/v1\",\"nonce\":\"\"}".len() + 36;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MsiFaultRequest { schema: String, nonce: String }
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MsiFaultConsumed { schema: String, nonce: String, operation_id: String, applied: bool }
fn msi_fault_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.get_version_num() == 4
        && id.get_variant() == uuid::Variant::RFC4122 && id.to_string() == value)
}
fn msi_fault_request(bytes: &[u8]) -> Option<MsiFaultRequest> {
    if bytes.len() != MSI_FAULT_REQUEST_LIMIT { return None; }
    let request: MsiFaultRequest = serde_json::from_slice(bytes).ok()?;
    if request.schema != MSI_FAULT_REQUEST_SCHEMA || !msi_fault_uuid(&request.nonce)
        || serde_json::to_vec(&request).ok()?.as_slice() != bytes { return None; }
    Some(request)
}
fn msi_fault_fixture_parent(root: &Path) -> Option<&Path> {
    if root.file_name()?.to_str()? != "日本語 & winsmux" { return None; }
    let parent = root.parent()?;
    if parent.parent()?.file_name()?.to_str()? != "winsmux-task880-native" { return None; }
    let pieces: Vec<_> = parent.file_name()?.to_str()?.split('.').collect();
    if pieces.len() != 4 || pieces[3] != "MSI"
        || pieces[..2].iter().any(|s| s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()))
        || pieces[2].len() != 40 || !pieces[2].bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) { return None; }
    Some(parent)
}

/// Called before legacy CLI cleanup. Failure output is a fixed classification.
pub fn run_internal_desktop_installer(arguments: &[String]) -> i32 {
    if arguments.first().is_some_and(|verb| matches!(verb.as_str(), "nsis-install" | "nsis-uninstall")) {
        return crate::desktop_nsis::run(arguments);
    }
    let _msi_path_session = msi_path_observation::Session::begin();
    let result = parse_msi_arguments(arguments).and_then(run_msi_verifier);
    match result {
        Ok(receipt) => match serde_json::to_string(&receipt) {
            Ok(json) => {
                println!("{json}");
                0
            }
            Err(_) => {
                eprintln!("winsmux installer: startup_unconfirmed");
                71
            }
        },
        Err(error) => {
            eprintln!("winsmux installer: {}", error.classification());
            match error {
                DesktopInstallError::Usage => 64,
                DesktopInstallError::Plan => 65,
                DesktopInstallError::Path => msi_path_observation::path_exit(),
                DesktopInstallError::Member => 67,
                DesktopInstallError::Actor => 68,
                DesktopInstallError::Isolation => 69,
                DesktopInstallError::Launch => 70,
                DesktopInstallError::Receipt => 71,
                DesktopInstallError::Timeout => 72,
                DesktopInstallError::Cleanup => 73,
            }
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
    use super::msi_path_observation::{self as path_observation, Reason, Site};
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
    fn failed_path(reason: Reason) -> DesktopInstallError {
        path_observation::note(reason);
        DesktopInstallError::Path
    }
    fn failed_path_api(api: u8, error: u32) -> DesktopInstallError {
        failed_path(path_observation::api_reason(api,error))
    }
    fn info(handle: HANDLE) -> Result<BY_HANDLE_FILE_INFORMATION, DesktopInstallError> {
        let mut data = BY_HANDLE_FILE_INFORMATION::default();
        if unsafe { GetFileInformationByHandle(handle, &mut data) } == 0 {
            let error=unsafe { GetLastError() };
            return Err(failed_path_api(0,error));
        }
        if data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(failed_path(Reason::Reparse));
        }
        Ok(data)
    }
    fn final_path(handle: HANDLE) -> Result<PathBuf, DesktopInstallError> {
        let n = unsafe { GetFinalPathNameByHandleW(handle, null_mut(), 0, 0) };
        if n == 0 {
            let error=unsafe { GetLastError() };
            return Err(failed_path_api(1,error));
        }
        let mut data = vec![0u16; n as usize + 1];
        let written =
            unsafe { GetFinalPathNameByHandleW(handle, data.as_mut_ptr(), data.len() as u32, 0) };
        if written == 0 {
            let error=unsafe { GetLastError() };
            return Err(failed_path_api(2,error));
        }
        if written as usize >= data.len() {
            return Err(failed_path(Reason::FinalReadLength));
        }
        let text =
            String::from_utf16(&data[..written as usize]).map_err(|_| failed_path(Reason::FinalUtf16))?;
        if !text.starts_with(r"\\?\") || text.starts_with(r"\\?\UNC\") {
            return Err(failed_path(Reason::FinalNamespace));
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
    // Failure-only probe. It never retries acceptance, changes the returned error, or records a path.
    fn failed_tilde_reason(path: &Path) -> Reason {
        fn raw_identity(path: &Path) -> Option<(Handle,BY_HANDLE_FILE_INFORMATION)> {
            let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            let raw=unsafe { CreateFileW(name.as_ptr(),FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ|FILE_SHARE_WRITE,null(),OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,null_mut()) };
            let handle=Handle::new(raw,DesktopInstallError::Path).ok()?;
            let mut value=BY_HANDLE_FILE_INFORMATION::default();
            if unsafe { GetFileInformationByHandle(handle.0,&mut value) }==0
                || value.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return None; }
            Some((handle,value))
        }
        let fallback=Reason::TildeLookupUnconfirmed;
        if !path_observation::active_site() { return fallback; }
        let input:Vec<u16>=path.as_os_str().encode_wide().chain(Some(0)).collect();
        let required=unsafe { GetLongPathNameW(input.as_ptr(),null_mut(),0) };
        if required==0 || required>32768 { return fallback; }
        let mut output=vec![0u16;required as usize+1];
        let used=unsafe { GetLongPathNameW(input.as_ptr(),output.as_mut_ptr(),output.len() as u32) };
        if used==0 || used as usize>=output.len() { return fallback; }
        let Ok(expanded)=String::from_utf16(&output[..used as usize]) else { return fallback; };
        let expanded_path=PathBuf::from(&expanded);
        let Some((_original_handle,original))=raw_identity(path) else { return fallback; };
        let Some((_expanded_handle,other))=raw_identity(&expanded_path) else { return fallback; };
        if !same_file(&original,&other) { return fallback; }
        if expanded.contains('~') { return Reason::TildeRemainsLong; }
        let normalized=expanded.replace('/',"\\");
        let bytes=normalized.as_bytes();
        if bytes.len()>=3 && bytes[0].is_ascii_alphabetic() && bytes[1]==b':'
            && bytes[2]==b'\\' && (normalized.len()==3
                || normalized[3..].trim_end_matches('\\').split('\\').all(safe_component)) {
            Reason::TildeExpandsStrict
        } else { fallback }
    }
    fn strict_absolute(path: &Path) -> Result<(), DesktopInstallError> {
        let text = path
            .to_str()
            .ok_or_else(|| failed_path(Reason::PathTextNonunicode))?
            .replace('/', "\\");
        let text = if text.len() > 3 {
            text.trim_end_matches('\\')
        } else {
            &text
        };
        let bytes = text.as_bytes();
        if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic()
            || bytes[1] != b':' || bytes[2] != b'\\' {
            return Err(failed_path(Reason::DriveShape));
        }
        if text.len() > 3 && !text[3..].split('\\').all(safe_component) {
            let reason=if text.contains('~')
                && text[3..].split('\\').all(|part| safe_component(&part.replace('~',"x"))) {
                    failed_tilde_reason(path)
                } else { Reason::ComponentUnsafe };
            return Err(failed_path(reason));
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
                ).map_err(|error| {
                    let code=unsafe { GetLastError() };
                    path_observation::note(path_observation::api_reason(3,code));
                    error
                })?;
                if info(handle.0)?.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
                    return Err(failed_path(Reason::NotDirectory));
                }
                if !same_path(&current, &final_path(handle.0)?) {
                    return Err(failed_path(Reason::CanonicalMismatch));
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
                return Err(failed_path(Reason::CanonicalMismatch));
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
            if identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
                return Err(failed_path(Reason::IsDirectory));
            }
            if identity.nNumberOfLinks != 1 {
                return Err(failed_path(Reason::LinkCount));
            }
            if !same_path(path, &final_path(file.as_raw_handle())?) {
                return Err(failed_path(Reason::CanonicalMismatch));
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
        let root = path_observation::boundary(Site::MsiRoot, || DirectoryHold::open(&args.root))?;
        let plan_path = root.path.join("winsmux.install-plan.json");
        let plan_file = path_observation::boundary(Site::MsiPlanFile, || ImageHold::open(&plan_path))?;
        let bytes = std::fs::read(&plan_file.path).map_err(|_| DesktopInstallError::Plan)?;
        let plan = parse_install_plan(&bytes, args.plan_sha256, "msi", &args.version)?;
        let mut directories = Vec::new();
        let mut members = Vec::new();
        let mut gui = None;
        for member in &plan.files {
            let path = root.path.join(&member.path);
            directories.push(path_observation::boundary(Site::MsiMemberParent, || DirectoryHold::open(
                path.parent().ok_or(DesktopInstallError::Path)?,
            ))?);
            let file = path_observation::boundary(Site::MsiMemberFile, || ImageHold::open(&path))?;
            if file.len() != member.bytes || file.digest != parse_sha256(&member.sha256)? {
                return Err(DesktopInstallError::Member);
            }
            if member.role == "gui" {
                gui = Some((file.path.clone(), file.digest));
            }
            members.push(file);
        }
        path_observation::boundary(Site::MsiRoot, || root.reobserve())?;
        path_observation::boundary(Site::MsiPlanFile, || plan_file.reobserve())?;
        for file in &members {
            path_observation::boundary(Site::MsiMemberFile, || file.reobserve())?;
        }
        let (gui_path, expected_gui_sha256) = gui.ok_or(DesktopInstallError::Plan)?;
        let fault = MsiStartupFaultArm::take(&root);
        let receipt = verify_startup_inner(StartupVerifyRequest {
            gui_path,
            expected_gui_sha256,
            expected_version: args.version,
            expected_actor_sid: args.user_sid,
        }, fault)?;
        path_observation::boundary(Site::MsiRoot, || root.reobserve())?;
        for file in &members {
            path_observation::boundary(Site::MsiMemberFile, || file.reobserve())?;
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
            let parent = path_observation::boundary(Site::TempParent, operation_temp_parent)?;
            let path = parent.path.join(format!("winsmux-installer-{id}"));
            let security = Security::actor(sid)?;
            let attributes = security.attributes();
            let (created, identity) = operation_create_root(
                &parent, path.file_name().ok_or(DesktopInstallError::Isolation)?, &security,
            )?;
            let hold = path_observation::boundary(Site::OperationRoot, || DirectoryHold::open(&path))?;
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
            path_observation::boundary(Site::OperationRoot, || result.hold.as_ref().unwrap().reobserve())?;
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
    // This move-only fixture can affect only the GUI HANDLE already owned by this helper.
    struct MsiStartupFaultArm {
        file: Handle,
        parent: DirectoryHold,
        identity: BY_HANDLE_FILE_INFORMATION,
        nonce: String,
        consumed: bool,
    }
    impl MsiStartupFaultArm {
        fn take(root: &DirectoryHold) -> Option<Self> {
            let parent = DirectoryHold::open(msi_fault_fixture_parent(&root.path)?).ok()?;
            root.reobserve().ok()?;
            parent.reobserve().ok()?;
            let file = operation_relative_handle(parent.handles.last()?.0, OsStr::new(MSI_FAULT_REQUEST),
                0x80000000 | 0x40000000 | 0x00010000 | FILE_READ_ATTRIBUTES | 0x00100000,
                FILE_SHARE_READ, 1, 0x00000040 | 0x00000020 | 0x00200000, null_mut()).ok()?;
            let identity = info(file.0).ok()?;
            let length = ((identity.nFileSizeHigh as u64) << 32) | identity.nFileSizeLow as u64;
            if identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 || identity.nNumberOfLinks != 1
                || length != MSI_FAULT_REQUEST_LIMIT as u64
                || !same_path(&parent.path.join(MSI_FAULT_REQUEST), &final_path(file.0).ok()?) { return None; }
            let mut bytes = vec![0; MSI_FAULT_REQUEST_LIMIT]; let mut read = 0;
            if unsafe { ReadFile(file.0, bytes.as_mut_ptr(), bytes.len() as u32, &mut read, null_mut()) } == 0
                || read as usize != bytes.len() { return None; }
            let after = info(file.0).ok()?;
            if !same_file(&identity, &after) || after.nNumberOfLinks != 1
                || after.nFileSizeHigh != identity.nFileSizeHigh || after.nFileSizeLow != identity.nFileSizeLow { return None; }
            let request = msi_fault_request(&bytes)?;
            parent.reobserve().ok()?; root.reobserve().ok()?;
            Some(Self { parent, file, identity, nonce: request.nonce, consumed: false })
        }
        fn reobserve(&self, leaf: &str) -> Option<()> {
            self.parent.reobserve().ok()?;
            let now = info(self.file.0).ok()?;
            if !same_file(&self.identity, &now) || now.nNumberOfLinks != 1
                || now.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0
                || !same_path(&self.parent.path.join(leaf), &final_path(self.file.0).ok()?) { return None; }
            Some(())
        }
        fn consume(&mut self) -> Option<()> {
            if self.consumed { return None; }
            self.reobserve(MSI_FAULT_REQUEST)?;
            use windows_sys::Win32::Storage::FileSystem::{FILE_RENAME_INFO, FileRenameInfo, SetFileInformationByHandle};
            // Same non-replacing held-file rename layout as desktop_nsis::move_exact_with_origins.
            let name = wide(self.parent.path.join(MSI_FAULT_CONSUMED).as_os_str()).ok()?;
            let length = (name.len() - 1) * 2;
            let offset = std::mem::offset_of!(FILE_RENAME_INFO, FileName);
            let size = (offset + length + 2).max(size_of::<FILE_RENAME_INFO>());
            let mut storage = vec![0usize; size.div_ceil(size_of::<usize>())];
            let rename = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
            unsafe {
                (*rename).Anonymous.Flags = 0;
                (*rename).RootDirectory = null_mut();
                (*rename).FileNameLength = length.try_into().ok()?;
                std::ptr::copy_nonoverlapping(name.as_ptr(), (*rename).FileName.as_mut_ptr(), name.len());
            }
            if unsafe { SetFileInformationByHandle(self.file.0, FileRenameInfo, rename.cast(), size as u32) } == 0 { return None; }
            self.consumed = true;
            self.reobserve(MSI_FAULT_CONSUMED)
        }
        fn record(&self, operation: &str, applied: bool) -> Option<()> {
            use windows_sys::Win32::Storage::FileSystem::{SetFilePointerEx, SetEndOfFile, FILE_BEGIN};
            self.reobserve(MSI_FAULT_CONSUMED)?;
            let value = MsiFaultConsumed { schema: MSI_FAULT_CONSUMED_SCHEMA.into(), nonce: self.nonce.clone(), operation_id: operation.into(), applied };
            let bytes = serde_json::to_vec(&value).ok()?;
            if unsafe { SetFilePointerEx(self.file.0, 0, null_mut(), FILE_BEGIN) } == 0 { return None; }
            let mut written = 0;
            if unsafe { WriteFile(self.file.0, bytes.as_ptr(), bytes.len() as u32, &mut written, null_mut()) } == 0
                || written as usize != bytes.len() || unsafe { SetEndOfFile(self.file.0) } == 0
                || unsafe { FlushFileBuffers(self.file.0) } == 0 { return None; }
            self.reobserve(MSI_FAULT_CONSUMED)
        }
        fn apply(&mut self, owned: &OwnedJob, operation: &str, deadline: Instant) {
            let _ = (|| -> Option<()> {
                let process = owned.process.as_ref()?;
                if !owned.assigned || !msi_fault_uuid(operation)
                    || unsafe { WaitForSingleObject(process.0, 0) } != 258 { return None; }
                self.consume()?;
                self.record(operation, false)?;
                let remaining = deadline.saturating_duration_since(Instant::now()).as_millis();
                if remaining == 0 || remaining > u32::MAX as u128
                    || unsafe { WaitForSingleObject(process.0, 0) } != 258 { return None; }
                if unsafe { TerminateProcess(process.0, 123) } == 0 { return None; }
                let remaining = deadline.saturating_duration_since(Instant::now()).as_millis();
                if unsafe { WaitForSingleObject(process.0, remaining.min(u32::MAX as u128) as u32) } != WAIT_OBJECT_0 { return None; }
                self.record(operation, true)
            })();
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
            let loaded = path_observation::boundary(Site::LoadedGuiImage, || {
                let path = PathBuf::from(
                    String::from_utf16(&data[..size as usize])
                        .map_err(|_| failed_path(Reason::LoadedNameUtf16))?,
                );
                ImageHold::open(&path)
            })?;
            if !same_file(&expected.identity, &loaded.identity) || expected.digest != loaded.digest
            {
                return Err(DesktopInstallError::Member);
            }
            path_observation::boundary(Site::SharedGuiFile, || expected.reobserve())
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
        fault: Option<&mut MsiStartupFaultArm>,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        let deadline = Instant::now() + Duration::from_millis(OBSERVATION_MS);
        if let Some(arm) = fault { arm.apply(owned, id, deadline); }
        let mut connected = false;
        loop {
            let mut timeout_phase = None;
            let root_wait = unsafe {
                WaitForSingleObject(
                    owned.process.as_ref().ok_or(DesktopInstallError::Launch)?.0,
                    0,
                )
            };
            if root_wait == WAIT_OBJECT_0 {
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
                    ERROR_PIPE_LISTENING => timeout_phase = Some("awaiting_pipe_listening"),
                    ERROR_NO_DATA => timeout_phase = Some("awaiting_pipe_no_data"),
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
                    timeout_phase = Some("verified_peer_read_zero");
                } else {
                    let read_error = unsafe { GetLastError() };
                    if !matches!(read_error, ERROR_NO_DATA) {
                        return Err(DesktopInstallError::Receipt);
                    }
                    timeout_phase = Some("verified_peer_read_no_data");
                }
            }
            if Instant::now() >= deadline {
                let root_wait = match root_wait {
                    windows_sys::Win32::Foundation::WAIT_TIMEOUT => "timeout",
                    windows_sys::Win32::Foundation::WAIT_FAILED => "failed",
                    _ => "other",
                };
                let timeout_phase = timeout_phase.unwrap_or("phase_unobserved");
                eprintln!("winsmux installer: startup_timeout_phase root_wait={root_wait} phase={timeout_phase}");
                return Err(DesktopInstallError::Timeout);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    pub(super) fn verify_startup(
        request: StartupVerifyRequest,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        verify_startup_inner(request, None)
    }
    fn verify_startup_inner(
        request: StartupVerifyRequest,
        mut fault: Option<MsiStartupFaultArm>,
    ) -> Result<StartupReceipt, DesktopInstallError> {
        if !valid_version(&request.expected_version) {
            return Err(DesktopInstallError::Usage);
        }
        actor(&request.expected_actor_sid)?;
        let root = path_observation::boundary(Site::SharedGuiParent, ||
            DirectoryHold::open(request.gui_path.parent().ok_or(DesktopInstallError::Path)?))?;
        let image = path_observation::boundary(Site::SharedGuiFile, || ImageHold::open(&request.gui_path))?;
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
            .and_then(|()| read_receipt(&pipe, &owned, &image, &operation, &request, fault.as_mut()));
        let cleanup = owned.stop();
        directory.terminal = cleanup.is_ok();
        cleanup?;
        path_observation::boundary(Site::SharedGuiParent, || root.reobserve())?;
        path_observation::boundary(Site::SharedGuiFile, || image.reobserve())?;
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
