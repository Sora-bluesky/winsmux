use super::io::{IoError, OwnedHandle};
use crate::contract::NonEmpty;
use crate::host::admission::{
    AllocationAuthority, AllocationError, AllocationPool, ChargedValue, ChargedVec,
};
use sha2::{Digest, Sha256};
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use windows_sys::Win32::Foundation::{
    LocalFree, SetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{
    CopySid, EqualSid, GetLengthSid, GetTokenInformation, ImpersonateLoggedOnUser, IsValidSid,
    LogonUserW, RevertToSelf, TokenGroups, TokenLogonSid, TokenUser, LOGON32_LOGON_NEW_CREDENTIALS,
    LOGON32_PROVIDER_WINNT50, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_GROUPS,
    TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeClientProcessId, ImpersonateNamedPipeClient};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentThread, OpenProcess, OpenProcessToken, OpenThreadToken,
    QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
};

const SID_MAX_BYTES: usize = 68;

#[derive(Clone)]
pub(crate) struct Sid {
    bytes: [u8; SID_MAX_BYTES],
    byte_len: usize,
}

unsafe impl Send for Sid {}
unsafe impl Sync for Sid {}

pub(crate) const PIPE_DATA_ACCESS: u32 = 0x0012_019b;
const SE_GROUP_ENABLED: u32 = 0x0000_0004;
const SE_GROUP_USE_FOR_DENY_ONLY: u32 = 0x0000_0010;


// This observation belongs only to one traced initial public-pipe call. It never
// contains native error values, identities, names or descriptor strings.
#[cfg(debug_assertions)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PublicPipeErrorClass {
    AccessDenied = 1,
    PrivilegeNotHeld,
    BadImpersonationLevel,
    InvalidOwner,
    InvalidSecurityDescriptor,
    Unobserved,
}

#[cfg(debug_assertions)]
impl PublicPipeErrorClass {
    pub(super) fn last_error() -> Self {
        use windows_sys::Win32::Foundation::{
            GetLastError, ERROR_ACCESS_DENIED, ERROR_BAD_IMPERSONATION_LEVEL,
            ERROR_INVALID_OWNER, ERROR_INVALID_SECURITY_DESCR, ERROR_PRIVILEGE_NOT_HELD,
        };
        // Called directly after a failed API, before any cleanup or formatting.
        match unsafe { GetLastError() } {
            ERROR_ACCESS_DENIED => Self::AccessDenied,
            ERROR_PRIVILEGE_NOT_HELD => Self::PrivilegeNotHeld,
            ERROR_BAD_IMPERSONATION_LEVEL => Self::BadImpersonationLevel,
            ERROR_INVALID_OWNER => Self::InvalidOwner,
            ERROR_INVALID_SECURITY_DESCR => Self::InvalidSecurityDescriptor,
            _ => Self::Unobserved,
        }
    }

    pub(super) fn label(self) -> &'static str {
        match self {
            Self::AccessDenied => "access_denied",
            Self::PrivilegeNotHeld => "privilege_not_held",
            Self::BadImpersonationLevel => "bad_impersonation_level",
            Self::InvalidOwner => "invalid_owner",
            Self::InvalidSecurityDescriptor => "invalid_security_descriptor",
            Self::Unobserved => "unobserved",
        }
    }

    pub(super) fn from_index(value: u32) -> Option<Self> {
        Some(match value {
            1 => Self::AccessDenied,
            2 => Self::PrivilegeNotHeld,
            3 => Self::BadImpersonationLevel,
            4 => Self::InvalidOwner,
            5 => Self::InvalidSecurityDescriptor,
            6 => Self::Unobserved,
            _ => return None,
        })
    }
}

#[cfg(debug_assertions)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PublicPipeFailureApi {
    Impersonate = 1,
    SidToString,
    SddlToDescriptor,
    CreatePipe,
    DescriptorValidation,
}

#[cfg(debug_assertions)]
impl PublicPipeFailureApi {
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Impersonate => "impersonate",
            Self::SidToString => "sid_to_string",
            Self::SddlToDescriptor => "sddl_to_descriptor",
            Self::CreatePipe => "create_pipe",
            Self::DescriptorValidation => "descriptor_validation",
        }
    }
}

#[cfg(debug_assertions)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct PublicPipeFailures {
    pub(super) operation: Option<(PublicPipeFailureApi, PublicPipeErrorClass)>,
    pub(super) revert: Option<PublicPipeErrorClass>,
}

#[cfg(debug_assertions)]
pub(super) struct PublicPipeObservation {
    failures: std::cell::Cell<PublicPipeFailures>,
    token_query: Option<std::cell::RefCell<capability_token_query::Snapshot>>,
}

#[cfg(debug_assertions)]
impl PublicPipeObservation {
    pub(super) fn new() -> Self {
        Self { failures: std::cell::Cell::new(PublicPipeFailures::default()), token_query: None }
    }

    pub(super) fn operation_failed(&self, api: PublicPipeFailureApi, class: PublicPipeErrorClass) {
        let mut failures = self.failures.get();
        if failures.operation.is_none() {
            failures.operation = Some((api, class));
            self.failures.set(failures);
        }
    }

    pub(super) fn revert_failed(&self, class: PublicPipeErrorClass) {
        let mut failures = self.failures.get();
        failures.revert = Some(class);
        self.failures.set(failures);
    }

    pub(super) fn failures(&self) -> PublicPipeFailures { self.failures.get() }

    pub(super) fn with_token_query() -> Self {
        Self { failures: std::cell::Cell::new(PublicPipeFailures::default()),
            token_query: Some(std::cell::RefCell::new(capability_token_query::Snapshot::begin())) }
    }
    pub(super) fn token_context_canonical(&self) -> bool {
        self.token_query.as_ref().is_some_and(|s| s.borrow().canonical())
    }
    pub(super) fn token_identity(&self, success: bool) {
        if let Some(s) = &self.token_query { s.borrow_mut().identity(success); }
    }
    pub(super) fn token_capability(&self, token: Option<HANDLE>) {
        if let Some(s) = &self.token_query { s.borrow_mut().capability(token); }
    }
    fn token_impersonated(&self, success: bool) {
        if let Some(s) = &self.token_query { s.borrow_mut().impersonated(success); }
    }
    pub(super) fn token_pipe(&self, success: bool) {
        if let Some(s) = &self.token_query { s.borrow_mut().pipe(success); }
    }
    fn token_reverted(&self, success: bool) {
        if let Some(s) = &self.token_query { s.borrow_mut().reverted(success); }
    }
    pub(super) fn token_finish(&self, success: bool) {
        if let Some(s) = &self.token_query { s.borrow_mut().finish(success); }
    }
    pub(super) fn token_json(&self) -> serde_json::Value {
        self.token_query.as_ref().expect("token observation scope").borrow().json(self.failures())
    }

}


// One private ignored-test observation. Native identities stay inside this scope;
// only nullable fixed enums, booleans and equality relations are serialized.
#[cfg(debug_assertions)]
mod capability_token_query {
    use super::*;
    use serde_json::{json, Value};
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NO_TOKEN, LUID};
    use windows_sys::Win32::Security::{LookupPrivilegeValueW, TokenHasRestrictions,
        TokenPrivileges, TokenRestrictedSids, TokenStatistics, TOKEN_PRIVILEGES,
        TOKEN_STATISTICS, SID_AND_ATTRIBUTES, LUID_AND_ATTRIBUTES};

    // TokenHasRestrictions has measured BOOLEAN (1 byte) and DWORD (4 byte)
    // providers. Only this class permits those two widths; zero/nonzero is BOOL.
    fn decode_has_restrictions(success: bool, returned: u32, capacity: u32, bytes: [u8; 4]) -> Option<bool> {
        if !success || !matches!(capacity, 1 | 4) || returned > capacity { return None; }
        match returned {
            1 => Some(bytes[0] != 0),
            4 => Some(u32::from_ne_bytes(bytes) != 0),
            _ => None,
        }
    }

    fn has_restrictions(token: HANDLE) -> Option<bool> {
        let mut required = 0;
        unsafe { GetTokenInformation(token, TokenHasRestrictions, null_mut(), 0, &mut required); }
        if !matches!(required, 1 | 4) { return None; }
        let capacity = required;
        let mut value = 0u32;
        let success = unsafe { GetTokenInformation(token, TokenHasRestrictions,
            (&mut value as *mut u32).cast(), capacity, &mut required) } != 0;
        decode_has_restrictions(success, required, capacity, value.to_ne_bytes())
    }

    #[cfg(test)]
    mod restriction_width_tests {
        use super::decode_has_restrictions;
        #[test]
        fn has_restrictions_accepts_only_returned_boolean_or_dword() {
            let samples = [[0,0,0,0], [1,0,0,0], [2,0,0,0], [0,128,0,0], [0,0,0,128], [255,255,255,255]];
            for capacity in [1,4] {
                for bytes in samples {
                    assert_eq!(decode_has_restrictions(true,1,capacity,bytes),Some(bytes[0]!=0));
                    let expected = if capacity==4 {Some(u32::from_ne_bytes(bytes)!=0)} else {None};
                    assert_eq!(decode_has_restrictions(true,4,capacity,bytes),expected);
                }
            }
            // A one-byte return must ignore any unwritten/previous upper bytes.
            assert_eq!(decode_has_restrictions(true,1,4,[0,255,255,255]),Some(false));
            assert_eq!(decode_has_restrictions(true,1,4,[128,0,0,0]),Some(true));
        }
        #[test]
        fn has_restrictions_rejects_failure_bad_width_and_overrun() {
            for capacity in [0,1,2,3,4,5] {
                for returned in [0,1,2,3,4,5] {
                    assert_eq!(decode_has_restrictions(false,returned,capacity,[255;4]),None);
                    if !matches!(capacity,1|4) || !matches!(returned,1|4) || returned>capacity {
                        assert_eq!(decode_has_restrictions(true,returned,capacity,[255;4]),None);
                    }
                }
            }
        }
    }

    fn fixed<T>(token: HANDLE, class: i32) -> Option<T> {
        let mut value = std::mem::MaybeUninit::<T>::zeroed();
        let mut bytes = 0;
        let ok = unsafe { GetTokenInformation(token, class, value.as_mut_ptr().cast(),
            size_of::<T>() as u32, &mut bytes) };
        if ok == 0 || bytes as usize != size_of::<T>() { return None; }
        Some(unsafe { value.assume_init() })
    }

    // Private one-filter comparison; identities and authentication values never leave this scope.
    pub(super) fn filtered_matches_generation(source: HANDLE, filtered: HANDLE) -> bool {
        let Some(source_stats) = fixed::<TOKEN_STATISTICS>(source, TokenStatistics) else { return false; };
        let Some(filtered_stats) = fixed::<TOKEN_STATISTICS>(filtered, TokenStatistics) else { return false; };
        let (Ok(source_identity), Ok(filtered_identity)) =
            (Identity::from_token(source), Identity::from_token(filtered)) else { return false; };
        let Ok(Some(attributes)) = token_group_attributes(filtered, &filtered_identity.logon) else { return false; };
        matches!(source_stats.TokenType, 1 | 2) && filtered_stats.TokenType == source_stats.TokenType
            && source_stats.AuthenticationId.LowPart == filtered_stats.AuthenticationId.LowPart
            && source_stats.AuthenticationId.HighPart == filtered_stats.AuthenticationId.HighPart
            && source_identity.user.equals(&filtered_identity.user)
            && source_identity.logon.equals(&filtered_identity.logon)
            && attributes & SE_GROUP_ENABLED != 0 && attributes & SE_GROUP_USE_FOR_DENY_ONLY == 0
    }

    fn variable(token: HANDLE, class: i32) -> Option<(Vec<u64>, usize)> {
        let mut bytes = 0;
        unsafe { GetTokenInformation(token, class, null_mut(), 0, &mut bytes); }
        if bytes == 0 || bytes as usize > TOKEN_GROUPS_BYTES { return None; }
        let mut storage = vec![0u64; (bytes as usize + 7) / 8];
        let capacity = (storage.len() * 8) as u32;
        if unsafe { GetTokenInformation(token, class, storage.as_mut_ptr().cast(),
            capacity, &mut bytes) } == 0 || bytes == 0 || bytes > capacity { return None; }
        Some((storage, bytes as usize))
    }

    fn restricting_empty(token: HANDLE) -> Option<bool> {
        let (storage, bytes) = variable(token, TokenRestrictedSids)?;
        if bytes < size_of::<u32>() { return None; }
        let count = unsafe { storage.as_ptr().cast::<u32>().read() } as usize;
        let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
        if count != 0 && (bytes < offset || count > (bytes - offset) / size_of::<SID_AND_ATTRIBUTES>()) { return None; }
        Some(count == 0)
    }

    fn impersonate_privilege(token: HANDLE) -> Option<(bool, bool)> {
        let name = wide("SeImpersonatePrivilege");
        let mut luid = LUID { LowPart: 0, HighPart: 0 };
        if unsafe { LookupPrivilegeValueW(std::ptr::null(), name.as_ptr(), &mut luid) } == 0 { return None; }
        let (storage, bytes) = variable(token, TokenPrivileges)?;
        if bytes < size_of::<u32>() { return None; }
        let count = unsafe { storage.as_ptr().cast::<u32>().read() } as usize;
        let offset = std::mem::offset_of!(TOKEN_PRIVILEGES, Privileges);
        if bytes < offset || count > (bytes - offset) / size_of::<LUID_AND_ATTRIBUTES>() { return None; }
        let start = unsafe { storage.as_ptr().cast::<u8>().add(offset).cast::<LUID_AND_ATTRIBUTES>() };
        let mut found = None;
        for index in 0..count {
            let value = unsafe { start.add(index).read_unaligned() };
            if value.Luid.LowPart == luid.LowPart && value.Luid.HighPart == luid.HighPart {
                if found.is_some() { return None; }
                found = Some(value.Attributes & 2 != 0);
            }
        }
        Some((found.is_some(), found.unwrap_or(false)))
    }

    #[derive(Default)]
    struct Facts {
        kind: Option<&'static str>, level: Option<&'static str>,
        restricted: Option<bool>, restricting_empty: Option<bool>,
        privilege: Option<(bool, bool)>, identity: Option<Identity>,
        authentication: Option<(u32, i32)>,
    }
    impl Facts {
        fn read(token: HANDLE) -> Self {
            let statistics = fixed::<TOKEN_STATISTICS>(token, TokenStatistics);
            let kind = statistics.as_ref().and_then(|s| match s.TokenType {
                1 => Some("primary"), 2 => Some("impersonation"), _ => None });
            let level = statistics.as_ref().and_then(|s| match s.TokenType {
                1 => Some("not_applicable"),
                2 => match s.ImpersonationLevel { 0 => Some("anonymous"), 1 => Some("identification"),
                    2 => Some("impersonation"), 3 => Some("delegation"), _ => None }, _ => None });
            Self { kind, level,
                restricted: has_restrictions(token),
                restricting_empty: restricting_empty(token), privilege: impersonate_privilege(token),
                identity: Identity::from_token(token).ok(),
                authentication: statistics.map(|s| (s.AuthenticationId.LowPart, s.AuthenticationId.HighPart)) }
        }
        fn json(&self) -> Value {
            json!({"token_type": observed(self.kind), "impersonation_level": observed(self.level),
                "has_restrictions": observed(self.restricted), "restricting_sids_empty": observed(self.restricting_empty),
                "se_impersonate_present": observed(self.privilege.map(|p| p.0)),
                "se_impersonate_enabled": observed(self.privilege.map(|p| p.1))})
        }
    }
    fn observed<T: serde::Serialize>(value: Option<T>) -> Value {
        json!({"observed": value.is_some(), "value": value})
    }
    fn thread() -> (Option<bool>, Facts) {
        let mut token = null_mut();
        if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } == 0 {
            let absent = if unsafe { GetLastError() } == ERROR_NO_TOKEN { Some(true) } else { None };
            return (absent, Facts::default());
        }
        match unsafe { OwnedHandle::from_raw(token) } {
            Ok(token) => (Some(false), Facts::read(token.raw())),
            Err(_) => (None, Facts::default()),
        }
    }
    fn relations(a: &Facts, b: &Facts) -> Value {
        json!({"same_user": observed(a.identity.as_ref().zip(b.identity.as_ref()).map(|(a,b)| a.user.equals(&b.user))),
            "same_logon": observed(a.identity.as_ref().zip(b.identity.as_ref()).map(|(a,b)| a.logon.equals(&b.logon))),
            "same_authentication_id": observed(a.authentication.zip(b.authentication).map(|(a,b)| a == b))})
    }
    pub(super) struct Snapshot {
        primary: Facts, generation: Facts, effective: Facts,
        before_absent: Option<bool>, after_absent: Option<bool>,
        identity: &'static str, capability: &'static str, impersonate: &'static str,
        pipe: &'static str, revert: &'static str, result: &'static str,
    }
    impl Snapshot {
        pub(super) fn begin() -> Self {
            let mut token = null_mut();
            let primary = if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } != 0 {
                unsafe { OwnedHandle::from_raw(token) }.ok().map(|t| Facts::read(t.raw())).unwrap_or_default()
            } else { Facts::default() };
            let (before_absent, _) = thread();
            Self { primary, generation: Facts::default(), effective: Facts::default(), before_absent,
                after_absent: None, identity: "not_attempted", capability: "not_attempted",
                impersonate: "not_attempted", pipe: "not_attempted", revert: "not_attempted", result: "not_attempted" }
        }
        pub(super) fn canonical(&self) -> bool { self.before_absent == Some(true) }
        pub(super) fn identity(&mut self, success: bool) { self.identity = if success { "succeeded" } else { "failed" }; }
        pub(super) fn capability(&mut self, token: Option<HANDLE>) {
            self.capability = if token.is_some() { "succeeded" } else { "failed" };
            if let Some(token) = token { self.generation = Facts::read(token); }
        }
        pub(super) fn impersonated(&mut self, success: bool) {
            self.impersonate = if success { "succeeded" } else { "failed" };
            if success { self.effective = thread().1; }
        }
        pub(super) fn pipe(&mut self, success: bool) { self.pipe = if success { "succeeded" } else { "failed" }; }
        pub(super) fn reverted(&mut self, success: bool) {
            self.revert = if success { "succeeded" } else { "failed" };
            self.after_absent = thread().0;
        }
        pub(super) fn finish(&mut self, result: bool) { self.result = if result { "succeeded" } else { "failed" }; }
        pub(super) fn json(&self, failures: PublicPipeFailures) -> Value {
            let operation = failures.operation.map(|(api,class)| json!({"api":api.label(),"class":class.label()}));
            json!({"schema":"winsmux-server-capability-token-observation/v1",
                "thread_absent_before": observed(self.before_absent), "thread_absent_after": observed(self.after_absent),
                "primary": self.primary.json(), "generation": self.generation.json(), "effective": self.effective.json(),
                "generation_to_primary": relations(&self.generation,&self.primary),
                "effective_to_generation": relations(&self.effective,&self.generation),
                "operations":{"identity":self.identity,"capability":self.capability,"impersonate":self.impersonate,
                    "pipe":self.pipe,"revert":self.revert,"result":self.result},
                "operation_failure": observed(operation), "revert_failure": observed(failures.revert.map(|class|class.label()))})
        }
    }
}

impl Sid {
    unsafe fn copy_from(source: PSID) -> Result<Self, IoError> {
        if source.is_null() || IsValidSid(source) == 0 {
            return Err(IoError::Failed);
        }
        let byte_len = GetLengthSid(source) as usize;
        if byte_len == 0 || byte_len > SID_MAX_BYTES {
            return Err(IoError::Failed);
        }
        let mut bytes = [0u8; SID_MAX_BYTES];
        let destination = bytes.as_mut_ptr().cast::<c_void>();
        if CopySid(byte_len as u32, destination, source) == 0 {
            return Err(IoError::Failed);
        }
        Ok(Self { bytes, byte_len })
    }

    pub(crate) fn as_ptr(&self) -> PSID {
        self.bytes.as_ptr().cast_mut().cast::<c_void>()
    }

    pub(crate) fn bytes(&self) -> &[u8] {
        &self.bytes[..self.byte_len]
    }

    pub(crate) fn equals(&self, other: &Self) -> bool {
        unsafe { EqualSid(self.as_ptr(), other.as_ptr()) != 0 }
    }

    fn sddl(&self) -> Result<String, IoError> {
        self.sddl_inner(#[cfg(debug_assertions)] None)
    }

    #[cfg(debug_assertions)]
    fn sddl_observed(&self, observation: &PublicPipeObservation) -> Result<String, IoError> {
        self.sddl_inner(Some(observation))
    }

    fn sddl_inner(
        &self,
        #[cfg(debug_assertions)] observation: Option<&PublicPipeObservation>,
    ) -> Result<String, IoError> {
        let mut value = null_mut();
        if unsafe { ConvertSidToStringSidW(self.as_ptr(), &mut value) } == 0 {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.operation_failed(PublicPipeFailureApi::SidToString, PublicPipeErrorClass::last_error());
            }
            return Err(IoError::Failed);
        }
        if value.is_null() {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.operation_failed(PublicPipeFailureApi::DescriptorValidation, PublicPipeErrorClass::Unobserved);
            }
            return Err(IoError::Failed);
        }
        let mut length = 0usize;
        unsafe {
            while *value.add(length) != 0 {
                length += 1;
            }
        }
        let result = String::from_utf16(unsafe { std::slice::from_raw_parts(value, length) })
            .map_err(|_| {
                #[cfg(debug_assertions)]
                if let Some(observation) = observation {
                    observation.operation_failed(PublicPipeFailureApi::DescriptorValidation, PublicPipeErrorClass::Unobserved);
                }
                IoError::Failed
            });
        unsafe {
            LocalFree(value.cast::<c_void>());
        }
        result
    }
}

#[derive(Clone)]
pub(crate) struct Identity {
    pub(crate) user: Sid,
    pub(crate) logon: Sid,
}

impl Identity {
    pub(crate) fn current() -> Result<Self, IoError> {
        let mut token = null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(IoError::Failed);
        }
        let token = unsafe { OwnedHandle::from_raw(token)? };
        Self::from_token(token.raw())
    }

    pub(crate) fn logon_key(&self) -> String {
        let digest = Sha256::digest(self.logon.bytes());
        digest.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn from_token(token: HANDLE) -> Result<Self, IoError> {
        Ok(Self {
            user: token_sid(token, TokenUser)?,
            logon: token_sid(token, TokenLogonSid)?,
        })
    }
}

const TOKEN_INFO_BYTES: usize = 4096;

fn token_sid(token: HANDLE, information_class: i32) -> Result<Sid, IoError> {
    let mut required = 0u32;
    unsafe {
        GetTokenInformation(token, information_class, null_mut(), 0, &mut required);
    }
    if required == 0 || required as usize > TOKEN_INFO_BYTES {
        return Err(IoError::Failed);
    }
    let mut storage = [0u8; TOKEN_INFO_BYTES];
    if unsafe {
        GetTokenInformation(
            token,
            information_class,
            storage.as_mut_ptr().cast::<c_void>(),
            required,
            &mut required,
        )
    } == 0
        || required == 0
        || required as usize > TOKEN_INFO_BYTES
    {
        return Err(IoError::Failed);
    }
    let sid = unsafe {
        if information_class == TokenUser {
            (*(storage.as_ptr().cast::<TOKEN_USER>())).User.Sid
        } else if information_class == TokenLogonSid {
            let groups = &*(storage.as_ptr().cast::<TOKEN_GROUPS>());
            if groups.GroupCount != 1 {
                return Err(IoError::Failed);
            }
            groups.Groups[0].Sid
        } else {
            return Err(IoError::Failed);
        }
    };
    unsafe { Sid::copy_from(sid) }
}

#[derive(Clone, Copy)]
pub(crate) enum SecurityMode<'a> {
    CurrentLogon,
    PublicPipe {
        server_logon: &'a Sid,
    },
    Mutex,
    #[cfg(debug_assertions)]
    PermissiveTest,
}

pub(crate) struct SecurityDescriptor {
    descriptor: PSECURITY_DESCRIPTOR,
}

unsafe impl Send for SecurityDescriptor {}

impl SecurityDescriptor {
    pub(crate) fn new(identity: &Identity, mode: SecurityMode<'_>) -> Result<Self, IoError> {
        Self::new_inner(identity, mode, #[cfg(debug_assertions)] None)
    }

    #[cfg(debug_assertions)]
    pub(super) fn new_observed(identity: &Identity, mode: SecurityMode<'_>, observation: &PublicPipeObservation) -> Result<Self, IoError> {
        Self::new_inner(identity, mode, Some(observation))
    }

    fn new_inner(
        identity: &Identity,
        mode: SecurityMode<'_>,
        #[cfg(debug_assertions)] observation: Option<&PublicPipeObservation>,
    ) -> Result<Self, IoError> {
        let sid_sddl = |sid: &Sid| {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation { return sid.sddl_observed(observation); }
            sid.sddl()
        };
        let sddl = match mode {
            SecurityMode::CurrentLogon => format!("D:P(A;;GA;;;{})", sid_sddl(&identity.logon)?),
            SecurityMode::PublicPipe { server_logon } => format!(
                "D:P(A;;RC;;;OW)(A;;0x{PIPE_DATA_ACCESS:08x};;;{})(A;;GA;;;{})",
                sid_sddl(&identity.logon)?,
                sid_sddl(server_logon)?,
            ),
            SecurityMode::Mutex => format!(
                "D:P(A;;RC;;;OW)(A;;0x00100001;;;{})",
                sid_sddl(&identity.logon)?
            ),
            #[cfg(debug_assertions)]
            // Anonymous test tokens have untrusted mandatory integrity. The
            // isolated probe pipe deliberately carries the same untrusted
            // label so MIC does not mask the inner SID/logon verifier. This
            // mode is unavailable in non-debug builds.
            SecurityMode::PermissiveTest => {
                "D:P(A;;GA;;;WD)(A;;GA;;;AN)S:(ML;;NW;;;S-1-16-0)".to_string()
            }
        };
        let wide: Vec<u16> = sddl.encode_utf16().chain(std::iter::once(0)).collect();
        let mut descriptor = null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        } == 0 {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.operation_failed(PublicPipeFailureApi::SddlToDescriptor, PublicPipeErrorClass::last_error());
            }
            return Err(IoError::Failed);
        }
        if descriptor.is_null() {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.operation_failed(PublicPipeFailureApi::DescriptorValidation, PublicPipeErrorClass::Unobserved);
            }
            return Err(IoError::Failed);
        }
        Ok(Self { descriptor })
    }

    pub(crate) fn attributes(&mut self, inheritable: bool) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.descriptor,
            bInheritHandle: i32::from(inheritable),
        }
    }
}

/// A process-private token whose distinct enabled logon SID is the only ACE
/// allowed to create additional instances of the generation's public pipe.
pub(crate) struct ServerCapabilityToken {
    token: OwnedHandle,
    logon: Sid,
}

impl ServerCapabilityToken {
    pub(crate) fn create(original: &Identity) -> Result<Self, IoError> {
        #[cfg(debug_assertions)]
        if std::env::var_os("WINSMUX_TASK862_FAIL_SERVER_TOKEN").is_some() {
            return Err(IoError::Failed);
        }
        let username = wide(&format!("winsmux-{}", uuid::Uuid::new_v4().simple()));
        let domain = wide(".");
        let credential = wide(&uuid::Uuid::new_v4().simple().to_string());
        let mut raw = null_mut();
        if unsafe {
            LogonUserW(
                username.as_ptr(),
                domain.as_ptr(),
                credential.as_ptr(),
                LOGON32_LOGON_NEW_CREDENTIALS,
                LOGON32_PROVIDER_WINNT50,
                &mut raw,
            )
        } == 0
        {
            return Err(IoError::Failed);
        }
        let token = unsafe { OwnedHandle::from_raw(raw)? };
        if unsafe { SetHandleInformation(token.raw(), HANDLE_FLAG_INHERIT, 0) } == 0 {
            return Err(IoError::Failed);
        }
        let generated = Identity::from_token(token.raw())?;
        let attributes =
            token_group_attributes(token.raw(), &generated.logon)?.ok_or(IoError::Failed)?;
        if !generated.user.equals(&original.user)
            || generated.logon.equals(&original.logon)
            || attributes & SE_GROUP_ENABLED == 0
            || attributes & SE_GROUP_USE_FOR_DENY_ONLY != 0
        {
            return Err(IoError::Failed);
        }
        Ok(Self {
            token,
            logon: generated.logon,
        })
    }

    // Private ignored-test experiment; production generation is unchanged.
    #[cfg(debug_assertions)]
    pub(super) fn create_filtered_comparison(original: &Identity) -> Result<Self, IoError> {
        use windows_sys::Win32::Foundation::GetHandleInformation;
        use windows_sys::Win32::Security::{CreateRestrictedToken, DISABLE_MAX_PRIVILEGE};
        let source = Self::create(original)?;
        let mut raw = null_mut();
        if unsafe { CreateRestrictedToken(source.token.raw(), DISABLE_MAX_PRIVILEGE,
            0, std::ptr::null(), 0, std::ptr::null(), 0, std::ptr::null(), &mut raw) } == 0 {
            return Err(IoError::Failed);
        }
        let token = unsafe { OwnedHandle::from_raw(raw)? };
        let mut flags = HANDLE_FLAG_INHERIT;
        if unsafe { GetHandleInformation(token.raw(), &mut flags) } == 0
            || flags & HANDLE_FLAG_INHERIT != 0
            || !capability_token_query::filtered_matches_generation(source.token.raw(), token.raw()) {
            return Err(IoError::Failed);
        }
        Ok(Self { token, logon: source.logon.clone() })
    }

    pub(crate) fn logon(&self) -> &Sid {
        &self.logon
    }

    #[cfg(debug_assertions)]
    pub(crate) fn raw(&self) -> HANDLE {
        self.token.raw()
    }

    pub(crate) fn while_impersonating<T>(
        &self,
        operation: impl FnOnce() -> Result<T, IoError>,
    ) -> Result<T, IoError> {
        self.while_impersonating_inner(operation, #[cfg(debug_assertions)] None)
    }

    #[cfg(debug_assertions)]
    pub(super) fn while_impersonating_observed<T>(
        &self,
        observation: &PublicPipeObservation,
        operation: impl FnOnce() -> Result<T, IoError>,
    ) -> Result<T, IoError> {
        self.while_impersonating_inner(operation, Some(observation))
    }

    fn while_impersonating_inner<T>(
        &self,
        operation: impl FnOnce() -> Result<T, IoError>,
        #[cfg(debug_assertions)] observation: Option<&PublicPipeObservation>,
    ) -> Result<T, IoError> {
        if unsafe { ImpersonateLoggedOnUser(self.token.raw()) } == 0 {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.operation_failed(PublicPipeFailureApi::Impersonate, PublicPipeErrorClass::last_error());
                observation.token_impersonated(false);
            }
            return Err(IoError::Failed);
        }
        #[cfg(debug_assertions)]
        if let Some(observation) = observation { observation.token_impersonated(true); }
        let result = operation();
        if unsafe { RevertToSelf() } == 0 {
            #[cfg(debug_assertions)]
            if let Some(observation) = observation {
                observation.revert_failed(PublicPipeErrorClass::last_error());
                observation.token_reverted(false);
            }
            return Err(IoError::Failed);
        }
        #[cfg(debug_assertions)]
        if let Some(observation) = observation { observation.token_reverted(true); }
        result
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

impl Drop for SecurityDescriptor {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            unsafe {
                LocalFree(self.descriptor);
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PeerFailure {
    Impersonation,
    UserMismatch,
    LogonMissing,
    LogonMismatch,
    Revert,
    Executable,
}

#[derive(Default)]
pub(crate) struct PeerTrace {
    pub(crate) impersonated: AtomicBool,
    pub(crate) user_checked: AtomicBool,
    pub(crate) logon_checked: AtomicBool,
    pub(crate) reverted: AtomicBool,
}

pub(crate) fn verify_pipe_peer(
    pipe: HANDLE,
    expected: &Identity,
    trace: Option<&PeerTrace>,
) -> Result<NonEmpty, PeerFailure> {
    if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
        return Err(PeerFailure::Impersonation);
    }
    if let Some(trace) = trace {
        trace.impersonated.store(true, Ordering::SeqCst);
    }

    let identity_result = (|| {
        let mut token = null_mut();
        if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } == 0 {
            return Err(PeerFailure::Impersonation);
        }
        let token =
            unsafe { OwnedHandle::from_raw(token) }.map_err(|_| PeerFailure::Impersonation)?;
        let user = token_sid(token.raw(), TokenUser).map_err(|_| PeerFailure::Impersonation)?;
        if let Some(trace) = trace {
            trace.user_checked.store(true, Ordering::SeqCst);
        }
        if !user.equals(&expected.user) {
            return Err(PeerFailure::UserMismatch);
        }
        let logon = token_sid(token.raw(), TokenLogonSid).map_err(|_| PeerFailure::LogonMissing)?;
        if let Some(trace) = trace {
            trace.logon_checked.store(true, Ordering::SeqCst);
        }
        if !logon.equals(&expected.logon) {
            return Err(PeerFailure::LogonMismatch);
        }
        Ok(())
    })();

    if unsafe { RevertToSelf() } == 0 {
        return Err(PeerFailure::Revert);
    }
    if let Some(trace) = trace {
        trace.reverted.store(true, Ordering::SeqCst);
    }
    identity_result?;
    verified_client_executable(pipe).map_err(|_| PeerFailure::Executable)
}

pub(crate) fn verify_pipe_peer_charged(
    pipe: HANDLE,
    expected: &Identity,
    trace: Option<&PeerTrace>,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ChargedValue<NonEmpty>, PeerFailure> {
    if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
        return Err(PeerFailure::Impersonation);
    }
    if let Some(trace) = trace {
        trace.impersonated.store(true, Ordering::SeqCst);
    }

    let identity_result = (|| {
        let mut token = null_mut();
        if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } == 0 {
            return Err(PeerFailure::Impersonation);
        }
        let token =
            unsafe { OwnedHandle::from_raw(token) }.map_err(|_| PeerFailure::Impersonation)?;
        let user_matches = token_sid_matches_charged(
            token.raw(),
            TokenUser,
            &expected.user,
            authority,
            pool,
        )
        .map_err(|_| PeerFailure::Impersonation)?;
        if let Some(trace) = trace {
            trace.user_checked.store(true, Ordering::SeqCst);
        }
        if !user_matches {
            return Err(PeerFailure::UserMismatch);
        }
        let logon_matches = token_sid_matches_charged(
            token.raw(),
            TokenLogonSid,
            &expected.logon,
            authority,
            pool,
        )
        .map_err(|_| PeerFailure::LogonMissing)?;
        if let Some(trace) = trace {
            trace.logon_checked.store(true, Ordering::SeqCst);
        }
        if !logon_matches {
            return Err(PeerFailure::LogonMismatch);
        }
        Ok(())
    })();

    if unsafe { RevertToSelf() } == 0 {
        return Err(PeerFailure::Revert);
    }
    if let Some(trace) = trace {
        trace.reverted.store(true, Ordering::SeqCst);
    }
    identity_result?;
    verified_client_executable_charged(pipe, authority, pool)
        .map_err(|_| PeerFailure::Executable)
}

fn token_sid_matches_charged(
    token: HANDLE,
    information_class: i32,
    expected: &Sid,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<bool, AllocationError> {
    let mut required = 0u32;
    unsafe {
        GetTokenInformation(token, information_class, null_mut(), 0, &mut required);
    }
    if required == 0 {
        return Err(AllocationError::Allocator);
    }
    let required_bytes = required as usize;
    let word_count = required_bytes
        .checked_add(size_of::<usize>() - 1)
        .ok_or(AllocationError::Layout)?
        / size_of::<usize>();
    let capacity_bytes = word_count
        .checked_mul(size_of::<usize>())
        .ok_or(AllocationError::Layout)?;
    let mut storage = ChargedVec::with_capacity(
        authority,
        pool,
        word_count,
        capacity_bytes,
    )?;
    storage.try_resize(word_count, 0usize)?;
    let supplied = u32::try_from(capacity_bytes).map_err(|_| AllocationError::Layout)?;
    let mut returned = required;
    if unsafe {
        GetTokenInformation(
            token,
            information_class,
            storage.as_mut_ptr().cast::<c_void>(),
            supplied,
            &mut returned,
        )
    } == 0
        || returned == 0
        || returned as usize > capacity_bytes
    {
        return Err(AllocationError::Allocator);
    }
    let sid = unsafe {
        if information_class == TokenUser {
            if (returned as usize) < size_of::<TOKEN_USER>() {
                return Err(AllocationError::Allocator);
            }
            (*(storage.as_ptr().cast::<TOKEN_USER>())).User.Sid
        } else if information_class == TokenLogonSid {
            if (returned as usize) < size_of::<TOKEN_GROUPS>() {
                return Err(AllocationError::Allocator);
            }
            let groups = &*(storage.as_ptr().cast::<TOKEN_GROUPS>());
            if groups.GroupCount != 1 {
                return Err(AllocationError::Allocator);
            }
            groups.Groups[0].Sid
        } else {
            return Err(AllocationError::Layout);
        }
    };
    let start = storage.as_ptr() as usize;
    let end = start
        .checked_add(returned as usize)
        .ok_or(AllocationError::Layout)?;
    let sid_start = sid as usize;
    if sid.is_null() || sid_start < start || sid_start >= end || unsafe { IsValidSid(sid) } == 0 {
        return Err(AllocationError::Allocator);
    }
    let sid_end = sid_start
        .checked_add(unsafe { GetLengthSid(sid) } as usize)
        .ok_or(AllocationError::Layout)?;
    if sid_end > end {
        return Err(AllocationError::Allocator);
    }
    Ok(unsafe { EqualSid(sid, expected.as_ptr()) } != 0)
}

fn verified_client_executable(pipe: HANDLE) -> Result<NonEmpty, IoError> {
    let mut pid = 0u32;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 || pid == 0 {
        return Err(IoError::Failed);
    }
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    let process = unsafe { OwnedHandle::from_raw(process)? };
    let mut path = vec![0u16; 32_768];
    let mut length = path.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process.raw(), 0, path.as_mut_ptr(), &mut length) } == 0
        || length == 0
        || length as usize > path.len()
    {
        return Err(IoError::Failed);
    }
    let path = String::from_utf16(&path[..length as usize]).map_err(|_| IoError::Failed)?;
    let basename = path
        .rsplit(['\\', '/'])
        .next()
        .filter(|value| !value.is_empty())
        .ok_or(IoError::Failed)?;
    NonEmpty::new(basename).map_err(|_| IoError::Failed)
}

fn verified_client_executable_charged(
    pipe: HANDLE,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ChargedValue<NonEmpty>, AllocationError> {
    let mut pid = 0u32;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 || pid == 0 {
        return Err(AllocationError::Allocator);
    }
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    let process = unsafe { OwnedHandle::from_raw(process) }.map_err(|_| AllocationError::Allocator)?;
    const PATH_UNITS: usize = 32_768;
    let mut path = ChargedVec::with_capacity(
        authority,
        pool,
        PATH_UNITS,
        PATH_UNITS * size_of::<u16>(),
    )?;
    path.try_resize(PATH_UNITS, 0u16)?;
    let mut length = u32::try_from(path.len()).map_err(|_| AllocationError::Layout)?;
    if unsafe { QueryFullProcessImageNameW(process.raw(), 0, path.as_mut_ptr(), &mut length) } == 0
        || length == 0
        || length as usize > path.len()
    {
        return Err(AllocationError::Allocator);
    }
    let units = &path[..length as usize];
    let mut utf8_bytes = 0usize;
    for decoded in std::char::decode_utf16(units.iter().copied()) {
        let character = decoded.map_err(|_| AllocationError::Allocator)?;
        utf8_bytes = utf8_bytes
            .checked_add(character.len_utf8())
            .ok_or(AllocationError::Layout)?;
    }
    if utf8_bytes == 0 {
        return Err(AllocationError::Allocator);
    }
    let mut charge = authority.claim(pool, utf8_bytes)?;
    if authority.allocation_is_forced_to_fail() {
        return Err(AllocationError::Allocator);
    }
    let mut decoded_path = String::new();
    decoded_path
        .try_reserve_exact(utf8_bytes)
        .map_err(|_| AllocationError::Allocator)?;
    if decoded_path.capacity() > utf8_bytes {
        return Err(AllocationError::Allocator);
    }
    charge.reduce_to(decoded_path.capacity());
    for decoded in std::char::decode_utf16(units.iter().copied()) {
        decoded_path.push(decoded.map_err(|_| AllocationError::Allocator)?);
    }
    if decoded_path.len() != utf8_bytes {
        return Err(AllocationError::Allocator);
    }
    let basename_start = decoded_path
        .rfind(['\\', '/'])
        .map_or(0, |position| position + 1);
    if basename_start == decoded_path.len() {
        return Err(AllocationError::Allocator);
    }
    if basename_start != 0 {
        decoded_path.drain(..basename_start);
    }
    let executable = NonEmpty::new(decoded_path).map_err(|_| AllocationError::Allocator)?;
    Ok(ChargedValue::from_parts(executable, charge))
}

#[cfg(debug_assertions)]
pub(crate) fn token_identity(token: HANDLE) -> Result<Identity, IoError> {
    Identity::from_token(token)
}

#[cfg(debug_assertions)]
pub(crate) fn token_user(token: HANDLE) -> Result<Sid, IoError> {
    token_sid(token, TokenUser)
}

#[cfg(debug_assertions)]
pub(crate) fn token_logon(token: HANDLE) -> Result<Sid, IoError> {
    token_sid(token, TokenLogonSid)
}

const TOKEN_GROUPS_BYTES: usize = 16_384;

pub(crate) fn token_group_attributes(token: HANDLE, target: &Sid) -> Result<Option<u32>, IoError> {
    let mut required = 0u32;
    unsafe {
        GetTokenInformation(token, TokenGroups, null_mut(), 0, &mut required);
    }
    if required == 0 || required as usize > TOKEN_GROUPS_BYTES {
        return Err(IoError::Failed);
    }
    let mut storage = [0u8; TOKEN_GROUPS_BYTES];
    if unsafe {
        GetTokenInformation(
            token,
            TokenGroups,
            storage.as_mut_ptr().cast::<c_void>(),
            required,
            &mut required,
        )
    } == 0
        || required == 0
        || required as usize > TOKEN_GROUPS_BYTES
    {
        return Err(IoError::Failed);
    }
    let groups = unsafe { &*(storage.as_ptr().cast::<TOKEN_GROUPS>()) };
    for index in 0..groups.GroupCount as usize {
        let entry = unsafe { &*groups.Groups.as_ptr().add(index) };
        if unsafe { EqualSid(entry.Sid, target.as_ptr()) } != 0 {
            return Ok(Some(entry.Attributes));
        }
    }
    Ok(None)
}
