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
        let mut value = null_mut();
        if unsafe { ConvertSidToStringSidW(self.as_ptr(), &mut value) } == 0 || value.is_null() {
            return Err(IoError::Failed);
        }
        let mut length = 0usize;
        unsafe {
            while *value.add(length) != 0 {
                length += 1;
            }
        }
        let result = String::from_utf16(unsafe { std::slice::from_raw_parts(value, length) })
            .map_err(|_| IoError::Failed);
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
        let sddl = match mode {
            SecurityMode::CurrentLogon => format!("D:P(A;;GA;;;{})", identity.logon.sddl()?),
            SecurityMode::PublicPipe { server_logon } => format!(
                "D:P(A;;RC;;;OW)(A;;0x{PIPE_DATA_ACCESS:08x};;;{})(A;;GA;;;{})",
                identity.logon.sddl()?,
                server_logon.sddl()?,
            ),
            SecurityMode::Mutex => format!(
                "D:P(A;;RC;;;OW)(A;;0x00100001;;;{})",
                identity.logon.sddl()?
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
        } == 0
            || descriptor.is_null()
        {
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
        if unsafe { ImpersonateLoggedOnUser(self.token.raw()) } == 0 {
            return Err(IoError::Failed);
        }
        let result = operation();
        if unsafe { RevertToSelf() } == 0 {
            return Err(IoError::Failed);
        }
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
