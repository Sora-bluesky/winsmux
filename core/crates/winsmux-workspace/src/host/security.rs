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


#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub(super) enum GuardFailure {
    PreexistingImpersonation=1, ThreadContextUnobserved, EffectiveTokenUnobserved,
    EffectiveLevelInsufficient, EffectiveIdentityMismatch,
}
impl GuardFailure {
    #[cfg(debug_assertions)]
    pub(super) fn label(self)->&'static str {match self {
        Self::PreexistingImpersonation=>"preexisting_impersonation",Self::ThreadContextUnobserved=>"thread_context_unobserved",
        Self::EffectiveTokenUnobserved=>"effective_token_unobserved",Self::EffectiveLevelInsufficient=>"effective_level_insufficient",
        Self::EffectiveIdentityMismatch=>"effective_identity_mismatch",
    }}
    #[cfg(debug_assertions)]
    pub(super) fn from_index(index:u32)->Option<Self>{Some(match index {
        1=>Self::PreexistingImpersonation,2=>Self::ThreadContextUnobserved,3=>Self::EffectiveTokenUnobserved,
        4=>Self::EffectiveLevelInsufficient,5=>Self::EffectiveIdentityMismatch,_=>return None,
    })}
}
#[derive(Clone,Copy,PartialEq,Eq)]
enum ThreadContext {Absent,Present,Unknown}
fn thread_context()->ThreadContext {
    let mut raw=null_mut();
    if unsafe {OpenThreadToken(GetCurrentThread(),TOKEN_QUERY,1,&mut raw)}==0 {
        return if unsafe {windows_sys::Win32::Foundation::GetLastError()}==windows_sys::Win32::Foundation::ERROR_NO_TOKEN {
            ThreadContext::Absent
        }else{ThreadContext::Unknown};
    }
    match unsafe {OwnedHandle::from_raw(raw)} {Ok(_)=>ThreadContext::Present,Err(_)=>ThreadContext::Unknown}
}
trait ImpersonationBackend {
    fn before(&self)->ThreadContext;
    fn assign(&self)->bool;
    fn restore(&self)->bool;
    fn fatal(&self)->!;
}
fn restoration_fail_stop()->! {
    unsafe {windows_sys::Win32::System::Threading::TerminateProcess(GetCurrentProcess(),0x574d4752);}
    std::process::abort()
}
struct WindowsImpersonation<F:Fn()->bool> {assign:F}
impl<F:Fn()->bool> ImpersonationBackend for WindowsImpersonation<F> {
    fn before(&self)->ThreadContext {thread_context()}
    fn assign(&self)->bool {(self.assign)()}
    fn restore(&self)->bool {unsafe {RevertToSelf()!=0}}
    fn fatal(&self)->! {restoration_fail_stop()}
}
// The sole owner after any successful assignment. Drop never calls tracing code.
struct Restoration<'a,B:ImpersonationBackend> {backend:&'a B,armed:bool}
impl<'a,B:ImpersonationBackend> Restoration<'a,B> {
    fn new(backend:&'a B)->Self {Self{backend,armed:true}}
    fn finish(&mut self) {
        if self.armed {
            self.armed=false;
            if !self.backend.restore() {self.backend.fatal();}
        }
    }
}
impl<B:ImpersonationBackend> Drop for Restoration<'_,B> {fn drop(&mut self){self.finish();}}
fn run_impersonation<B:ImpersonationBackend,T,E>(backend:&B,
    before_failed:impl FnOnce(GuardFailure)->E,assignment_failed:impl FnOnce()->E,
    after_assignment:impl FnOnce()->Result<(),E>,operation:impl FnOnce()->Result<T,E>,
    restored:impl FnOnce())->Result<T,E> {
    let reason=match backend.before(){ThreadContext::Absent=>None,ThreadContext::Present=>Some(GuardFailure::PreexistingImpersonation),ThreadContext::Unknown=>Some(GuardFailure::ThreadContextUnobserved)};
    if let Some(reason)=reason {return Err(before_failed(reason));}
    if !backend.assign() {return Err(assignment_failed());}
    let mut owner=Restoration::new(backend);
    let result=after_assignment().and_then(|()|operation());
    owner.finish();
    restored();
    result
}
pub(super) fn with_impersonation_lifetime<T,E>(assignment:impl Fn()->bool,
    before_failed:impl FnOnce(GuardFailure)->E,assignment_failed:impl FnOnce()->E,
    after_assignment:impl FnOnce()->Result<(),E>,operation:impl FnOnce()->Result<T,E>,restored:impl FnOnce())->Result<T,E> {
    run_impersonation(&WindowsImpersonation{assign:assignment},before_failed,assignment_failed,after_assignment,operation,restored)
}
fn effective_level(kind:i32,level:i32)->Result<(),GuardFailure> {
    if kind!=2 || !matches!(level,0..=3) {return Err(GuardFailure::EffectiveTokenUnobserved);}
    if level<2 {return Err(GuardFailure::EffectiveLevelInsufficient);}
    Ok(())
}
fn capability_identity_matches(a:&Identity,b:&Identity,a_auth:(u32,i32),b_auth:(u32,i32))->bool {
    a.user.bytes()==b.user.bytes() && a.logon.bytes()==b.logon.bytes() && a_auth==b_auth
}
fn effective_capability(token:HANDLE)->Result<(),GuardFailure> {
    use windows_sys::Win32::Security::{TokenStatistics,TOKEN_STATISTICS};
    let mut raw=null_mut();
    if unsafe {OpenThreadToken(GetCurrentThread(),TOKEN_QUERY,1,&mut raw)}==0 {return Err(GuardFailure::EffectiveTokenUnobserved);}
    let effective=unsafe {OwnedHandle::from_raw(raw)}.map_err(|_|GuardFailure::EffectiveTokenUnobserved)?;
    let stats=capability_constraints::fixed::<TOKEN_STATISTICS>(effective.raw(),TokenStatistics).ok_or(GuardFailure::EffectiveTokenUnobserved)?;
    effective_level(stats.TokenType,stats.ImpersonationLevel)?;
    let intended=capability_constraints::fixed::<TOKEN_STATISTICS>(token,TokenStatistics).ok_or(GuardFailure::EffectiveTokenUnobserved)?;
    let a=Identity::from_token(effective.raw()).map_err(|_|GuardFailure::EffectiveTokenUnobserved)?;
    let b=Identity::from_token(token).map_err(|_|GuardFailure::EffectiveTokenUnobserved)?;
    if !capability_identity_matches(&a,&b,(stats.AuthenticationId.LowPart,stats.AuthenticationId.HighPart),
        (intended.AuthenticationId.LowPart,intended.AuthenticationId.HighPart)) {
        return Err(GuardFailure::EffectiveIdentityMismatch);
    }
    Ok(())
}

#[cfg(all(test,debug_assertions))]
mod impersonation_lifetime_tests {
    use super::*;
    use std::cell::Cell;
    struct Mock {context:ThreadContext,assigned:bool,restore_ok:bool,assigns:Cell<u32>,restores:Cell<u32>,fatals:Cell<u32>}
    impl Mock {fn new(context:ThreadContext,assigned:bool,restore_ok:bool)->Self {Self{context,assigned,restore_ok,assigns:Cell::new(0),restores:Cell::new(0),fatals:Cell::new(0)}}}
    impl ImpersonationBackend for Mock {
        fn before(&self)->ThreadContext{self.context}
        fn assign(&self)->bool{self.assigns.set(self.assigns.get()+1);self.assigned}
        fn restore(&self)->bool{self.restores.set(self.restores.get()+1);self.restore_ok}
        fn fatal(&self)->!{self.fatals.set(self.fatals.get()+1);panic!("mock fatal; real seam is owned subprocess proof")}
    }
    #[test]
    fn server_shape_gate_distinguishes_unknown_low_level_and_identity() {
        for (kind,level,expected) in [(1,2,Err(GuardFailure::EffectiveTokenUnobserved)),(2,-1,Err(GuardFailure::EffectiveTokenUnobserved)),
            (2,4,Err(GuardFailure::EffectiveTokenUnobserved)),(2,0,Err(GuardFailure::EffectiveLevelInsufficient)),
            (2,1,Err(GuardFailure::EffectiveLevelInsufficient)),(2,2,Ok(())),(2,3,Ok(()))] {assert_eq!(effective_level(kind,level),expected);}
        fn sid(rid:u32)->Sid {let mut bytes=[0;SID_MAX_BYTES];bytes[..8].copy_from_slice(&[1,1,0,0,0,0,0,5]);bytes[8..12].copy_from_slice(&rid.to_le_bytes());Sid{bytes,byte_len:12}}
        let a=Identity{user:sid(1),logon:sid(2)};
        assert!(capability_identity_matches(&a,&a,(3,4),(3,4)));
        assert!(!capability_identity_matches(&a,&a,(3,4),(3,5)));
        assert!(!capability_identity_matches(&a,&Identity{user:sid(9),logon:sid(2)},(3,4),(3,4)));
        assert!(!capability_identity_matches(&a,&Identity{user:sid(1),logon:sid(9)},(3,4),(3,4)));
    }
    #[test]
    fn prequery_and_false_assignment_never_own_caller_context() {
        for (context,reason) in [(ThreadContext::Present,GuardFailure::PreexistingImpersonation),(ThreadContext::Unknown,GuardFailure::ThreadContextUnobserved)] {
            let m=Mock::new(context,true,true);let actions=Cell::new(0);
            let result=run_impersonation(&m,|r|r,||panic!("no assignment"),||Ok(()),||{actions.set(1);Ok(())},||panic!("no restoration"));
            assert_eq!(result,Err(reason));assert_eq!((m.assigns.get(),m.restores.get(),actions.get(),m.fatals.get()),(0,0,0,0));
        }
        let m=Mock::new(ThreadContext::Absent,false,true);
        let result=run_impersonation(&m,|_|"prequery",||"assignment",||Ok(()),||Ok(()),||panic!("not armed"));
        assert_eq!(result,Err("assignment"));assert_eq!((m.assigns.get(),m.restores.get(),m.fatals.get()),(1,0,0));
    }
    #[test]
    fn every_post_assignment_refusal_restores_once_before_return() {
        for reason in [GuardFailure::EffectiveTokenUnobserved,GuardFailure::EffectiveLevelInsufficient,GuardFailure::EffectiveIdentityMismatch] {
            let m=Mock::new(ThreadContext::Absent,true,true);let actions=Cell::new(0);let callback=Cell::new(0);
            let result=run_impersonation(&m,|r|r,||panic!("assignment succeeded"),||Err(reason),||{actions.set(1);Ok(())},||{assert_eq!(m.restores.get(),1);callback.set(1);});
            assert_eq!(result,Err(reason));assert_eq!((m.assigns.get(),m.restores.get(),actions.get(),callback.get()),(1,1,0,1));
        }
    }
    #[test]
    fn all_purposes_keep_action_error_and_unwind_cleanup_exactly_once() {
        // The three production purposes and raw-test scope use this same owner;
        // the purpose-specific closure retains its predicates and accounting.
        for _purpose in ["server","plain_peer","charged_peer","raw_test_probe"] {
            for success in [false,true] {
                let m=Mock::new(ThreadContext::Absent,true,true);let actions=Cell::new(0);
                let result=run_impersonation(&m,|_|"prequery",||"assignment",||Ok(()),||{actions.set(actions.get()+1);if success{Ok(7)}else{Err("operation")}},||{});
                assert_eq!(result,if success{Ok(7)}else{Err("operation")});assert_eq!((actions.get(),m.restores.get()),(1,1));
            }
            for before_action in [true,false] {
                let m=Mock::new(ThreadContext::Absent,true,true);let actions=Cell::new(0);
                let panic=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let _:Result<(),&str>=run_impersonation(&m,|_|"prequery",||"assignment",||{if before_action{panic!("validation/trace unwind")};Ok(())},||{actions.set(1);panic!("action unwind")},||panic!("no unwind callback"));
                }));
                assert!(panic.is_err());assert_eq!(m.restores.get(),1);assert_eq!(actions.get(),if before_action{0}else{1});
            }
        }
    }
    #[test]
    fn cleanup_failure_has_priority_and_disarms_before_any_callback() {
        let m=Mock::new(ThreadContext::Absent,true,false);let callbacks=Cell::new(0);
        let fatal=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _:Result<(),&str>=run_impersonation(&m,|_|"prequery",||"assignment",||Ok(()),||Err("operation"),||callbacks.set(1));
        }));
        assert!(fatal.is_err());assert_eq!((m.restores.get(),m.fatals.get(),callbacks.get()),(1,1,0));
        let m=Mock::new(ThreadContext::Absent,true,true);
        let unwind=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _:Result<(),&str>=run_impersonation(&m,|_|"prequery",||"assignment",||Ok(()),||Ok(()),||panic!("success callback unwind"));
        }));
        assert!(unwind.is_err());assert_eq!(m.restores.get(),1);
    }
}
#[cfg(debug_assertions)]
pub(super) fn restoration_failure_probe()->! {
    struct Injected {token:HANDLE}
    impl ImpersonationBackend for Injected {
        fn before(&self)->ThreadContext {thread_context()}
        fn assign(&self)->bool {unsafe {ImpersonateLoggedOnUser(self.token)!=0}}
        fn restore(&self)->bool {
            if unsafe {RevertToSelf()}==0 {restoration_fail_stop();}
            // Only this explicit test entry injects the cleanup result; no environment
            // variable is read by production assignment or restoration paths.
            let marker=b"WINSMUX_GUARD_RESTORE_INJECTED\n";let mut written=0;
            unsafe {windows_sys::Win32::Storage::FileSystem::WriteFile(
                windows_sys::Win32::System::Console::GetStdHandle(windows_sys::Win32::System::Console::STD_ERROR_HANDLE),
                marker.as_ptr(),marker.len() as u32,&mut written,null_mut());}
            false
        }
        fn fatal(&self)->! {restoration_fail_stop()}
    }
    let identity=Identity::current().expect("guard proof primary");
    let capability=ServerCapabilityToken::create(&identity).expect("guard proof capability");
    let _:Result<(),IoError>=run_impersonation(&Injected{token:capability.token.raw()},|_|IoError::Failed,||IoError::Failed,
        ||effective_capability(capability.token.raw()).map_err(|_|IoError::Failed),||Ok(()),||{});
    panic!("WINSMUX_GUARD_CONTINUATION")
}

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
    pub(super) guard: Option<GuardFailure>,
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

    pub(super) fn guard_failed(&self,reason:GuardFailure) {
        let mut failures=self.failures.get();failures.guard=Some(reason);self.failures.set(failures);
        if let Some(snapshot)=&self.token_query {snapshot.borrow_mut().guard_failed(reason);}
    }

    pub(super) fn failures(&self) -> PublicPipeFailures { self.failures.get() }

    pub(super) fn with_token_query() -> Self {
        Self { failures: std::cell::Cell::new(PublicPipeFailures::default()),
            token_query: Some(std::cell::RefCell::new(capability_token_query::Snapshot::begin())) }
    }
    pub(super) fn refuse_token_context(&self) {
        let reason=self.token_query.as_ref().map(|s|s.borrow().context_failure()).unwrap_or(GuardFailure::ThreadContextUnobserved);
        self.guard_failed(reason);
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

    pub(super) fn has_restrictions(token: HANDLE) -> Option<bool> {
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

    use super::capability_constraints::{fixed, variable, restricting_empty, Constraints, constraint_relations};

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
        primary_constraints: Constraints, generation_constraints: Constraints,
        before_absent: Option<bool>, after_absent: Option<bool>,
        identity: &'static str, capability: &'static str, impersonate: &'static str,
        pipe: &'static str, revert: &'static str, result: &'static str,
    }
    impl Snapshot {
        pub(super) fn begin() -> Self {
            let mut token = null_mut();
            let mut primary_constraints = Constraints::default();
            let primary = if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } != 0 {
                unsafe { OwnedHandle::from_raw(token) }.ok().map(|t| {
                    primary_constraints = Constraints::read(t.raw());
                    Facts::read(t.raw())
                }).unwrap_or_default()
            } else { Facts::default() };
            let (before_absent, _) = thread();
            Self { primary, generation: Facts::default(), effective: Facts::default(), before_absent,
                primary_constraints, generation_constraints: Constraints::default(),
                after_absent: None, identity: "not_attempted", capability: "not_attempted",
                impersonate: "not_attempted", pipe: "not_attempted", revert: "not_attempted", result: "not_attempted" }
        }
        pub(super) fn guard_failed(&mut self,reason:GuardFailure) {
            match reason {GuardFailure::PreexistingImpersonation=>self.before_absent=Some(false),
                GuardFailure::ThreadContextUnobserved=>self.before_absent=None,_=>{}}
        }
        pub(super) fn context_failure(&self)->GuardFailure {
            if self.before_absent==Some(false){GuardFailure::PreexistingImpersonation}else{GuardFailure::ThreadContextUnobserved}
        }
        pub(super) fn canonical(&self) -> bool { self.before_absent == Some(true) }
        pub(super) fn identity(&mut self, success: bool) { self.identity = if success { "succeeded" } else { "failed" }; }
        pub(super) fn capability(&mut self, token: Option<HANDLE>) {
            self.capability = if token.is_some() { "succeeded" } else { "failed" };
            if let Some(token) = token {
                self.generation_constraints = Constraints::read(token);
                self.generation = Facts::read(token);
            }
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
                "generation_constraints": constraint_relations(&self.primary_constraints,&self.generation_constraints),
                "effective_to_generation": relations(&self.effective,&self.generation),
                "operations":{"identity":self.identity,"capability":self.capability,"impersonate":self.impersonate,
                    "pipe":self.pipe,"revert":self.revert,"result":self.result},
                "operation_failure": observed(operation), "revert_failure": observed(failures.revert.map(|class|class.label())),
                "guard_failure": observed(failures.guard.map(|reason|reason.label()))})
        }
    }
}

// Shared production queries and comparisons; serialization remains debug-only.
mod capability_constraints {
    use super::*;
    use windows_sys::Win32::Security::{TokenPrivileges, TokenRestrictedSids, TokenStatistics,
        TOKEN_PRIVILEGES, TOKEN_STATISTICS, SID_AND_ATTRIBUTES, LUID_AND_ATTRIBUTES};
    #[cfg(debug_assertions)]
    use serde_json::{json,Value};
    pub(super) fn fixed<T>(token: HANDLE, class: i32) -> Option<T> {
        let mut value = std::mem::MaybeUninit::<T>::zeroed();
        let mut bytes = 0;
        let ok = unsafe { GetTokenInformation(token, class, value.as_mut_ptr().cast(),
            size_of::<T>() as u32, &mut bytes) };
        if ok == 0 || bytes as usize != size_of::<T>() { return None; }
        Some(unsafe { value.assume_init() })
    }

    pub(super) fn variable(token: HANDLE, class: i32) -> Option<(Vec<u64>, usize)> {
        let mut bytes = 0;
        unsafe { GetTokenInformation(token, class, null_mut(), 0, &mut bytes); }
        if bytes == 0 || bytes as usize > TOKEN_GROUPS_BYTES { return None; }
        let mut storage = vec![0u64; (bytes as usize + 7) / 8];
        let capacity = (storage.len() * 8) as u32;
        if unsafe { GetTokenInformation(token, class, storage.as_mut_ptr().cast(),
            capacity, &mut bytes) } == 0 || bytes == 0 || bytes > capacity { return None; }
        Some((storage, bytes as usize))
    }

    pub(super) fn restricting_empty(token: HANDLE) -> Option<bool> {
        let (storage, bytes) = variable(token, TokenRestrictedSids)?;
        if bytes < size_of::<u32>() { return None; }
        let count = unsafe { storage.as_ptr().cast::<u32>().read() } as usize;
        let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
        if count != 0 && (bytes < offset || count > (bytes - offset) / size_of::<SID_AND_ATTRIBUTES>()) { return None; }
        Some(count == 0)
    }

    // Query-only public attributes. Native SIDs/LUIDs never enter the JSON.
    const GROUP_KNOWN_ATTRIBUTES: u32 = 0xe000_007f;
    const PRIVILEGE_KNOWN_ATTRIBUTES: u32 = 0x8000_0007;

    fn bounded_sid(storage: &[u64], bytes: usize, sid: PSID) -> Option<Sid> {
        let start = storage.as_ptr() as usize;
        let end = start.checked_add(bytes)?;
        let address = sid as usize;
        if sid.is_null() || address < start || address.checked_add(8)? > end { return None; }
        let header = unsafe { std::slice::from_raw_parts(sid.cast::<u8>(), 8) };
        let length = 8usize.checked_add(4usize.checked_mul(header[1] as usize)?)?;
        if header[0] != 1 || header[1] > 15 || length > SID_MAX_BYTES
            || address.checked_add(length)? > end { return None; }
        unsafe { Sid::copy_from(sid).ok() }
    }
    fn integrity_rid(sid: &Sid) -> Option<u32> {
        let bytes = sid.bytes();
        if bytes.len() != 12 || bytes[..8] != [1,1,0,0,0,0,0,16] { return None; }
        let rid = u32::from_le_bytes(bytes[8..12].try_into().ok()?);
        match rid { 0 | 0x1000 | 0x2000 | 0x2100 | 0x3000 | 0x4000 | 0x5000 | 0x7000 => Some(rid), _ => None }
    }
    fn unique_groups(groups: &[(Sid, u32)]) -> bool {
        groups.iter().enumerate().all(|(i,(sid,attributes))| {
            attributes & !GROUP_KNOWN_ATTRIBUTES == 0
                && !(attributes & SE_GROUP_USE_FOR_DENY_ONLY != 0 && attributes & SE_GROUP_ENABLED != 0)
                && groups[..i].iter().all(|(previous,_)| previous.bytes() != sid.bytes())
        })
    }
    fn groups(token: HANDLE) -> Option<Vec<(Sid, u32)>> {
        let (storage, bytes) = variable(token, TokenGroups)?;
        let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
        if bytes < offset { return None; }
        let count = unsafe { storage.as_ptr().cast::<u32>().read() } as usize;
        if count > (bytes - offset) / size_of::<SID_AND_ATTRIBUTES>() { return None; }
        let start = unsafe { storage.as_ptr().cast::<u8>().add(offset).cast::<SID_AND_ATTRIBUTES>() };
        let mut result = Vec::with_capacity(count);
        for index in 0..count {
            let entry = unsafe { start.add(index).read_unaligned() };
            result.push((bounded_sid(&storage, bytes, entry.Sid)?, entry.Attributes));
        }
        unique_groups(&result).then_some(result)
    }
    type Privilege = ((u32, i32), u32);
    fn unique_privileges(privileges: &[Privilege]) -> bool {
        privileges.iter().enumerate().all(|(i,(luid,attributes))| {
            attributes & !PRIVILEGE_KNOWN_ATTRIBUTES == 0
                && !(attributes & 4 != 0 && attributes & 2 != 0)
                && privileges[..i].iter().all(|(previous,_)| previous != luid)
        })
    }
    fn privileges(token: HANDLE) -> Option<Vec<Privilege>> {
        let (storage, bytes) = variable(token, TokenPrivileges)?;
        let offset = std::mem::offset_of!(TOKEN_PRIVILEGES, Privileges);
        if bytes < offset { return None; }
        let count = unsafe { storage.as_ptr().cast::<u32>().read() } as usize;
        if count > (bytes - offset) / size_of::<LUID_AND_ATTRIBUTES>() { return None; }
        let start = unsafe { storage.as_ptr().cast::<u8>().add(offset).cast::<LUID_AND_ATTRIBUTES>() };
        let result: Vec<_> = (0..count).map(|index| {
            let entry = unsafe { start.add(index).read_unaligned() };
            ((entry.Luid.LowPart, entry.Luid.HighPart), entry.Attributes)
        }).collect();
        unique_privileges(&result).then_some(result)
    }
    fn integrity(token: HANDLE) -> Option<u32> {
        use windows_sys::Win32::Security::{TokenIntegrityLevel, TOKEN_MANDATORY_LABEL};
        let (storage, bytes) = variable(token, TokenIntegrityLevel)?;
        if bytes < size_of::<TOKEN_MANDATORY_LABEL>() { return None; }
        let label = unsafe { storage.as_ptr().cast::<TOKEN_MANDATORY_LABEL>().read_unaligned() };
        if label.Label.Attributes & !0x60 != 0 || label.Label.Attributes & 0x20 == 0 { return None; }
        integrity_rid(&bounded_sid(&storage, bytes, label.Label.Sid)?)
    }
    fn mandatory_policy(value: u32) -> Option<u32> { (value & !3 == 0).then_some(value) }
    fn elevation_type(value: i32) -> Option<i32> { matches!(value, 1..=3).then_some(value) }
    #[derive(Clone, Default)]
    pub(super) struct Constraints {
        groups: Option<Vec<(Sid, u32)>>, logon: Option<Sid>, privileges: Option<Vec<Privilege>>,
        integrity: Option<u32>, policy: Option<u32>, elevation: Option<bool>, elevation_type: Option<i32>,
        restricting_empty: Option<bool>, app_container: Option<bool>,
    }
    impl Constraints {
        pub(super) fn read(token: HANDLE) -> Self {
            use windows_sys::Win32::Security::{TokenMandatoryPolicy, TokenElevation, TokenElevationType,
                TOKEN_MANDATORY_POLICY, TOKEN_ELEVATION};
            Self { groups: groups(token), logon: token_sid(token, TokenLogonSid).ok(),
                privileges: privileges(token), integrity: integrity(token),
                policy: fixed::<TOKEN_MANDATORY_POLICY>(token, TokenMandatoryPolicy).and_then(|p| mandatory_policy(p.Policy)),
                elevation: fixed::<TOKEN_ELEVATION>(token, TokenElevation).map(|e| e.TokenIsElevated != 0),
                elevation_type: fixed::<i32>(token, TokenElevationType).and_then(elevation_type),
                restricting_empty: restricting_empty(token),
                app_container: fixed::<u32>(token, windows_sys::Win32::Security::TokenIsAppContainer).map(|v|v!=0) }
        }
    }
    fn comparable_group(sid: &Sid, attributes: u32, logon: &Sid, expected_integrity: Option<u32>) -> Option<bool> {
        if sid.bytes() == logon.bytes() { return Some(false); }
        if attributes & 0x60 != 0 {
            if attributes & 0x20 == 0 { return None; }
            return (integrity_rid(sid)? == expected_integrity?).then_some(false);
        }
        Some(true)
    }
    fn group_relations(primary: &Constraints, generation: &Constraints) -> Option<(bool,bool)> {
        let (a,b) = primary.groups.as_ref().zip(generation.groups.as_ref())?;
        let (old_logon,new_logon) = primary.logon.as_ref().zip(generation.logon.as_ref())?;
        if !unique_groups(a) || !unique_groups(b) { return None; }
        // Validate every exemption before evaluating either relation.
        for (sid,attributes) in a { comparable_group(sid,*attributes,old_logon,primary.integrity)?; }
        for (sid,attributes) in b { comparable_group(sid,*attributes,new_logon,generation.integrity)?; }
        let deny = a.iter().filter(|(sid,attributes)| comparable_group(sid,*attributes,old_logon,primary.integrity) == Some(true)
            && attributes & SE_GROUP_USE_FOR_DENY_ONLY != 0).all(|(sid,_)| {
                b.iter().any(|(other,attributes)| sid.bytes() == other.bytes() && attributes & SE_GROUP_USE_FOR_DENY_ONLY != 0)
            });
        let allow = b.iter().filter(|(sid,attributes)| comparable_group(sid,*attributes,new_logon,generation.integrity) == Some(true)
            && attributes & SE_GROUP_ENABLED != 0 && attributes & SE_GROUP_USE_FOR_DENY_ONLY == 0).all(|(sid,_)| {
                a.iter().any(|(other,attributes)| sid.bytes() == other.bytes()
                    && attributes & SE_GROUP_ENABLED != 0 && attributes & SE_GROUP_USE_FOR_DENY_ONLY == 0)
            });
        Some((deny,allow))
    }
    fn privilege_relations(primary: &Constraints, generation: &Constraints) -> Option<(bool,bool)> {
        let (a,b) = primary.privileges.as_ref().zip(generation.privileges.as_ref())?;
        if !unique_privileges(a) || !unique_privileges(b) { return None; }
        Some((b.iter().all(|(id,_)| a.iter().any(|(other,_)| id == other)),
            b.iter().filter(|(_,attributes)| attributes & 2 != 0).all(|(id,_)| {
                a.iter().any(|(other,attributes)| id == other && attributes & 2 != 0)
            })))
    }
    fn relations(a: &Constraints, b: &Constraints) -> [Option<bool>; 8] {
        let groups = group_relations(a,b);
        let privileges = privilege_relations(a,b);
        [groups.map(|v|v.0),groups.map(|v|v.1),privileges.map(|v|v.0),privileges.map(|v|v.1),
            a.integrity.zip(b.integrity).map(|(a,b)|b<=a),a.policy.zip(b.policy).map(|(a,b)|a==b),
            a.elevation.zip(b.elevation).map(|(a,b)|a==b),a.elevation_type.zip(b.elevation_type).map(|(a,b)|a==b)]
    }
    #[cfg(debug_assertions)]
    fn observed<T: serde::Serialize>(value: Option<T>) -> Value {
        json!({"observed": value.is_some(), "value": value})
    }
    #[cfg(debug_assertions)]
    pub(super) fn constraint_relations(a: &Constraints, b: &Constraints) -> Value {
        let r=relations(a,b);
        json!({"deny_only_groups_preserved":observed(r[0]),"no_new_allow_groups":observed(r[1]),
            "no_added_privileges":observed(r[2]),"no_newly_enabled_privileges":observed(r[3]),
            "integrity_not_raised":observed(r[4]),"mandatory_policy_same":observed(r[5]),
            "elevation_same":observed(r[6]),"elevation_type_same":observed(r[7])})
    }

    #[cfg(debug_assertions)]
    pub(super) fn caller_class() -> Option<Value> {
        let mut raw=null_mut();
        if unsafe {OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&mut raw)}==0 {return None;}
        let token=unsafe {OwnedHandle::from_raw(raw)}.ok()?;
        let value=Constraints::read(token.raw());
        let statistics=fixed::<TOKEN_STATISTICS>(token.raw(),TokenStatistics)?;
        if statistics.TokenType!=1 {return None;}
        let identity=Identity::from_token(token.raw()).ok()?;
        let session=fixed::<u32>(token.raw(),windows_sys::Win32::Security::TokenSessionId)?;
        let restricted=super::capability_token_query::has_restrictions(token.raw())?;
        let sid_sha256=Sha256::digest(identity.user.bytes()).iter().map(|byte|format!("{byte:02x}")).collect::<String>();
        Some(json!({"sid_sha256":sid_sha256,"session":session,"token_type":1,
            "elevation":if value.elevation? {1}else{0},"elevation_type":value.elevation_type?,
            "integrity_rid":value.integrity?,"restricted":if restricted {1}else{0},
            "app_container":if value.app_container? {1}else{0}}))
    }

    struct Reduction {
        deny: Vec<Sid>, delete: Vec<(u32,i32)>, lower_integrity: Option<u32>, lua: bool,
    }
    enum Plan { Compatible, Reduce(Reduction) }
    fn complete(value: &Constraints) -> bool {
        value.restricting_empty == Some(true) && value.app_container == Some(false)
            && relations(value,value).iter().all(|v|*v==Some(true))
    }
    fn repair_plan(primary: &Constraints, generation: &Constraints) -> Option<Plan> {
        if !complete(primary) || !complete(generation) { return None; }
        if relations(primary,generation).iter().all(|v|*v==Some(true)) { return Some(Plan::Compatible); }
        if primary.policy != generation.policy || primary.elevation_type != generation.elevation_type
            || (primary.elevation == Some(true) && generation.elevation != Some(true)) { return None; }
        let a=primary.groups.as_ref()?;let b=generation.groups.as_ref()?;
        let old_logon=primary.logon.as_ref()?;let new_logon=generation.logon.as_ref()?;
        let mut deny: Vec<Sid>=Vec::new();
        for (sid,attrs) in a {
            if comparable_group(sid,*attrs,old_logon,primary.integrity)? && attrs & SE_GROUP_USE_FOR_DENY_ONLY != 0 {
                let (_,generated)=b.iter().find(|(other,_)|other.bytes()==sid.bytes())?;
                if generated & SE_GROUP_USE_FOR_DENY_ONLY == 0 { deny.push(sid.clone()); }
            }
        }
        for (sid,attrs) in b {
            if comparable_group(sid,*attrs,new_logon,generation.integrity)?
                && attrs & SE_GROUP_ENABLED != 0 && attrs & SE_GROUP_USE_FOR_DENY_ONLY == 0
                && !a.iter().any(|(other,previous)|other.bytes()==sid.bytes()
                    && previous & SE_GROUP_ENABLED != 0 && previous & SE_GROUP_USE_FOR_DENY_ONLY == 0)
                && !deny.iter().any(|other|other.bytes()==sid.bytes()) { deny.push(sid.clone()); }
        }
        let delete=generation.privileges.as_ref()?.iter().filter(|(id,attrs)| {
            !primary.privileges.as_ref().unwrap().iter().any(|(previous,enabled)| {
                previous==id && (attrs & 2 == 0 || enabled & 2 != 0)
            })
        }).map(|(id,_)|*id).collect();
        Some(Plan::Reduce(Reduction {deny,delete,
            lower_integrity:(generation.integrity? > primary.integrity?).then_some(primary.integrity?),
            lua:primary.elevation==Some(false) && generation.elevation==Some(true)}))
    }
    fn logon_enabled(value: &Constraints, logon: &Sid) -> bool {
        value.groups.as_ref().is_some_and(|groups|groups.iter().any(|(sid,attrs)| {
            sid.bytes()==logon.bytes() && attrs & SE_GROUP_ENABLED != 0 && attrs & SE_GROUP_USE_FOR_DENY_ONLY == 0
        }))
    }
    fn unchanged(a: &Constraints,b: &Constraints) -> bool {
        let same_groups=a.groups.as_ref().zip(b.groups.as_ref()).is_some_and(|(a,b)| {
            a.len()==b.len() && a.iter().all(|(sid,attrs)|b.iter().any(|(other,previous)|sid.bytes()==other.bytes()&&attrs==previous))
        });
        let same_privileges=a.privileges.as_ref().zip(b.privileges.as_ref()).is_some_and(|(a,b)| {
            a.len()==b.len() && a.iter().all(|entry|b.contains(entry))
        });
        complete(a) && complete(b) && same_groups && same_privileges && a.integrity==b.integrity
            && a.policy==b.policy && a.elevation==b.elevation && a.elevation_type==b.elevation_type
            && a.logon.as_ref().zip(b.logon.as_ref()).is_some_and(|(a,b)|a.bytes()==b.bytes())
    }
    fn authentication(token: HANDLE) -> Option<(u32,i32)> {
        fixed::<TOKEN_STATISTICS>(token,TokenStatistics).filter(|s|s.TokenType==1)
            .map(|s|(s.AuthenticationId.LowPart,s.AuthenticationId.HighPart))
    }
    fn noninherit(token: HANDLE) -> bool {
        let mut flags=HANDLE_FLAG_INHERIT;
        (unsafe { windows_sys::Win32::Foundation::GetHandleInformation(token,&mut flags) }) != 0
            && flags & HANDLE_FLAG_INHERIT == 0
    }
    fn lower_integrity(token: HANDLE,rid: u32) -> Result<(),IoError> {
        use windows_sys::Win32::Security::{SetTokenInformation,TokenIntegrityLevel,TOKEN_MANDATORY_LABEL};
        let offset=size_of::<TOKEN_MANDATORY_LABEL>();let length=offset+12;
        let mut storage=vec![0u64;(length+7)/8];
        let sid=unsafe {storage.as_mut_ptr().cast::<u8>().add(offset)};
        unsafe {
            std::ptr::copy_nonoverlapping([1u8,1,0,0,0,0,0,16].as_ptr(),sid,8);
            std::ptr::copy_nonoverlapping(rid.to_le_bytes().as_ptr(),sid.add(8),4);
            storage.as_mut_ptr().cast::<TOKEN_MANDATORY_LABEL>().write(TOKEN_MANDATORY_LABEL {
                Label:SID_AND_ATTRIBUTES {Sid:sid.cast(),Attributes:0x20}
            });
        }
        if unsafe {SetTokenInformation(token,TokenIntegrityLevel,storage.as_ptr().cast(),length as u32)} == 0 {
            return Err(IoError::Failed);
        }
        Ok(())
    }
    pub(super) fn establish(original: &Identity) -> Result<(OwnedHandle,Sid),IoError> {
        use windows_sys::Win32::Security::{CreateRestrictedToken,LUA_TOKEN};
        let mut primary=null_mut();
        if unsafe {OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&mut primary)}==0 {return Err(IoError::Failed);}
        let primary=unsafe {OwnedHandle::from_raw(primary)?};
        let caller=Identity::from_token(primary.raw())?;
        let primary_constraints=Constraints::read(primary.raw());
        let primary_auth=authentication(primary.raw()).ok_or(IoError::Failed)?;
        if !complete(&primary_constraints) || caller.user.bytes()!=original.user.bytes()
            || caller.logon.bytes()!=original.logon.bytes() || !logon_enabled(&primary_constraints,&caller.logon) {
            return Err(IoError::Failed);
        }
        let username=wide(&format!("winsmux-{}",uuid::Uuid::new_v4().simple()));let domain=wide(".");
        let credential=wide(&uuid::Uuid::new_v4().simple().to_string());let mut raw=null_mut();
        if unsafe {LogonUserW(username.as_ptr(),domain.as_ptr(),credential.as_ptr(),
            LOGON32_LOGON_NEW_CREDENTIALS,LOGON32_PROVIDER_WINNT50,&mut raw)}==0 {return Err(IoError::Failed);}
        let raw=unsafe {OwnedHandle::from_raw(raw)?};
        if unsafe {SetHandleInformation(raw.raw(),HANDLE_FLAG_INHERIT,0)}==0 {return Err(IoError::Failed);}
        let raw_identity=Identity::from_token(raw.raw())?;
        let raw_auth=authentication(raw.raw()).ok_or(IoError::Failed)?;
        let raw_constraints=Constraints::read(raw.raw());
        if raw_identity.user.bytes()!=caller.user.bytes() || raw_identity.logon.bytes()==caller.logon.bytes()
            || !logon_enabled(&raw_constraints,&raw_identity.logon) || !noninherit(raw.raw()) {
            return Err(IoError::Failed);
        }
        let plan=repair_plan(&primary_constraints,&raw_constraints).ok_or(IoError::Failed)?;
        let token=match plan {
            Plan::Compatible=>raw,
            Plan::Reduce(plan)=>{
                let deny:Vec<_>=plan.deny.iter().map(|sid|SID_AND_ATTRIBUTES{Sid:sid.as_ptr(),Attributes:0}).collect();
                let delete:Vec<_>=plan.delete.iter().map(|(low,high)|LUID_AND_ATTRIBUTES {
                    Luid:windows_sys::Win32::Foundation::LUID{LowPart:*low,HighPart:*high},Attributes:0
                }).collect();
                let mut reduced=null_mut();
                if unsafe {CreateRestrictedToken(raw.raw(),if plan.lua {LUA_TOKEN}else{0},
                    deny.len() as u32,if deny.is_empty(){std::ptr::null()}else{deny.as_ptr()},
                    delete.len() as u32,if delete.is_empty(){std::ptr::null()}else{delete.as_ptr()},
                    0,std::ptr::null(),&mut reduced)}==0 {return Err(IoError::Failed);}
                let reduced=unsafe {OwnedHandle::from_raw(reduced)?};
                if unsafe {SetHandleInformation(reduced.raw(),HANDLE_FLAG_INHERIT,0)}==0 {return Err(IoError::Failed);}
                if let Some(rid)=plan.lower_integrity {lower_integrity(reduced.raw(),rid)?;}
                reduced
            }
        };
        let final_constraints=Constraints::read(token.raw());
        let final_identity=Identity::from_token(token.raw())?;
        if !complete(&final_constraints) || !relations(&primary_constraints,&final_constraints).iter().all(|v|*v==Some(true))
            || final_identity.user.bytes()!=raw_identity.user.bytes() || final_identity.logon.bytes()!=raw_identity.logon.bytes()
            || authentication(token.raw())!=Some(raw_auth) || !logon_enabled(&final_constraints,&raw_identity.logon)
            || !noninherit(token.raw()) || !unchanged(&primary_constraints,&Constraints::read(primary.raw()))
            || authentication(primary.raw())!=Some(primary_auth) {
            return Err(IoError::Failed);
        }
        Ok((token,final_identity.logon))
    }

    #[cfg(all(test,debug_assertions))]
    mod primary_constraint_relation_tests {
        use super::*;
        fn sid(rid: u32) -> Sid {
            let mut bytes = [0; SID_MAX_BYTES];
            bytes[..8].copy_from_slice(&[1,1,0,0,0,0,0,5]);
            bytes[8..12].copy_from_slice(&rid.to_le_bytes());
            Sid { bytes, byte_len: 12 }
        }
        fn sample(groups: &[(u32,u32)], privileges: &[Privilege]) -> Constraints {
            Constraints { groups: Some(groups.iter().map(|(rid,attrs)|(sid(*rid),*attrs)).collect()),
                logon: Some(sid(999)), privileges: Some(privileges.to_vec()), ..Constraints::default() }
        }
        fn modeled(groups: &[(u32,u32)], privileges: &[Privilege]) -> Constraints {
            Constraints {integrity:Some(0x2000),policy:Some(1),elevation:Some(false),elevation_type:Some(3),
                restricting_empty:Some(true),app_container:Some(false),..sample(groups,privileges)}
        }
        #[test]
        fn restriction_plan_repairs_all_modeled_expansions_together() {
            let a=modeled(&[(1,16),(2,0)],&[((1,0),0)]);
            let mut b=modeled(&[(1,4),(2,4),(3,4)],&[((1,0),2),((2,0),0)]);
            b.integrity=Some(0x3000);b.elevation=Some(true);
            let Some(Plan::Reduce(p))=repair_plan(&a,&b)else{panic!("expansion must have one reduction plan")};
            assert_eq!(p.deny.iter().map(|s|s.bytes().to_vec()).collect::<Vec<_>>(),vec![sid(1).bytes().to_vec(),sid(2).bytes().to_vec(),sid(3).bytes().to_vec()]);
            assert_eq!(p.delete,vec![(1,0),(2,0)]);assert_eq!(p.lower_integrity,Some(0x2000));assert!(p.lua);
        }
        #[test]
        fn restriction_plan_refuses_missing_deny_and_unrepresentable_state() {
            let a=modeled(&[(1,16)],&[]);let b=modeled(&[],&[]);
            assert!(repair_plan(&a,&b).is_none());
            let mut restricted=modeled(&[],&[]);restricted.restricting_empty=Some(false);
            assert!(repair_plan(&restricted,&modeled(&[],&[])).is_none());
            restricted.restricting_empty=None;
            assert!(repair_plan(&restricted,&modeled(&[],&[])).is_none());
            let mut a=modeled(&[],&[]);a.app_container=Some(true);assert!(repair_plan(&a,&modeled(&[],&[])).is_none());
            let mut a=modeled(&[],&[]);a.policy=None;assert!(repair_plan(&a,&modeled(&[],&[])).is_none());
        }
        #[test]
        fn restriction_plan_never_raises_or_changes_unmodeled_policy() {
            let a=modeled(&[],&[]);let mut b=modeled(&[],&[]);
            assert!(matches!(repair_plan(&a,&b),Some(Plan::Compatible)));
            b.integrity=Some(0x1000);assert!(matches!(repair_plan(&a,&b),Some(Plan::Compatible)));
            b.policy=Some(2);assert!(repair_plan(&a,&b).is_none());
            b.policy=Some(1);b.elevation_type=Some(1);assert!(repair_plan(&a,&b).is_none());
            b.elevation_type=Some(3);let mut elevated=a.clone();elevated.elevation=Some(true);
            assert!(repair_plan(&elevated,&b).is_none());
        }

        #[test]
        fn deny_only_removal_and_reenable_are_expansions() {
            let a = sample(&[(1,16)],&[]);
            assert_eq!(group_relations(&a,&sample(&[(1,16)],&[])),Some((true,true)));
            assert_eq!(group_relations(&a,&sample(&[],&[])),Some((false,true)));
            assert_eq!(group_relations(&a,&sample(&[(1,4)],&[])),Some((false,false)));
        }
        #[test]
        fn enabled_groups_cannot_be_added_or_newly_enabled() {
            let a = sample(&[(1,0),(2,4)],&[]);
            assert_eq!(group_relations(&a,&sample(&[(2,4)],&[])),Some((true,true)));
            assert_eq!(group_relations(&a,&sample(&[(1,4)],&[])),Some((true,false)));
            assert_eq!(group_relations(&a,&sample(&[(3,4)],&[])),Some((true,false)));
        }
        #[test]
        fn duplicate_and_unknown_group_inputs_are_missing() {
            let a = sample(&[(1,4)],&[]);
            for b in [sample(&[(1,4),(1,4)],&[]),sample(&[(1,0x100)],&[]),sample(&[(1,20)],&[]),sample(&[(1,0x20)],&[])] {
                assert_eq!(group_relations(&a,&b),None);
                assert_eq!(group_relations(&b,&a),None);
            }
            let mut b=sample(&[],&[]); b.logon=None;
            assert_eq!(group_relations(&a,&b),None);
        }
        #[test]
        fn exemptions_are_exact_logon_or_known_integrity_only() {
            let a=sample(&[],&[]); let mut b=sample(&[(999,4)],&[]);
            assert_eq!(group_relations(&a,&b),Some((true,true)));
            b.groups.as_mut().unwrap().push((sid(998),4));
            assert_eq!(group_relations(&a,&b),Some((true,false)));
            let mut integrity=sid(0x2000); integrity.bytes[7]=16;
            b.groups=Some(vec![(integrity.clone(),0x60)]);
            b.integrity=Some(0x2000);
            assert_eq!(group_relations(&a,&b),Some((true,true)));
            b.integrity=Some(0x3000);
            assert_eq!(group_relations(&a,&b),None);
            b.integrity=None;
            assert_eq!(group_relations(&a,&b),None);
            b.integrity=Some(0x2000);
            b.groups.as_mut().unwrap().push((integrity,0x60));
            assert_eq!(group_relations(&a,&b),None);
        }
        #[test]
        fn added_and_newly_enabled_privileges_are_distinct_expansions() {
            let a=sample(&[],&[((1,0),0),((2,1),2)]);
            assert_eq!(privilege_relations(&a,&sample(&[],&[((2,1),2)])),Some((true,true)));
            assert_eq!(privilege_relations(&a,&sample(&[],&[((1,0),2)])),Some((true,false)));
            assert_eq!(privilege_relations(&a,&sample(&[],&[((2,0),0)])),Some((false,true)));
        }
        #[test]
        fn duplicate_and_unknown_privilege_inputs_are_missing() {
            let a=sample(&[],&[]);
            for b in [sample(&[],&[((1,0),0),((1,0),0)]),sample(&[],&[((1,0),8)]),sample(&[],&[((1,0),6)])] {
                assert_eq!(privilege_relations(&a,&b),None);
                assert_eq!(privilege_relations(&b,&a),None);
            }
        }
        #[test]
        fn integrity_boundaries_and_independent_missing_are_observed() {
            let mut a=sample(&[],&[]); let mut b=sample(&[],&[]);
            a.integrity=Some(0x2000);
            for (rid,expected) in [(0x1000,true),(0x2000,true),(0x2100,false)] {
                b.integrity=Some(rid);
                let value=constraint_relations(&a,&b);
                assert_eq!(value["integrity_not_raised"],observed(Some(expected)));
                assert_eq!(value["mandatory_policy_same"],observed::<bool>(None));
                assert_eq!(value["no_added_privileges"],observed(Some(true)));
            }
            b.integrity=None;
            assert_eq!(constraint_relations(&a,&b)["integrity_not_raised"],observed::<bool>(None));
        }
        #[test]
        fn fixed_policy_and_elevation_domains_do_not_invent_success() {
            for value in 0..=3 { assert_eq!(mandatory_policy(value),Some(value)); }
            assert_eq!(mandatory_policy(4),None);
            for value in 1..=3 { assert_eq!(elevation_type(value),Some(value)); }
            for value in [0,4,-1] { assert_eq!(elevation_type(value),None); }
            let mut a=sample(&[],&[]); let mut b=sample(&[],&[]);
            a.policy=Some(1);b.policy=Some(2);a.elevation=Some(false);b.elevation=Some(true);
            a.elevation_type=Some(3);b.elevation_type=Some(2);
            let v=constraint_relations(&a,&b);
            for key in ["mandatory_policy_same","elevation_same","elevation_type_same"] { assert_eq!(v[key],observed(Some(false))); }
            b.policy=None;b.elevation=None;b.elevation_type=None;
            let v=constraint_relations(&a,&b);
            for key in ["mandatory_policy_same","elevation_same","elevation_type_same"] { assert_eq!(v[key],observed::<bool>(None)); }
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
        if std::env::var_os("WINSMUX_TASK862_FAIL_SERVER_TOKEN").is_some() {return Err(IoError::Failed);}
        let (token,logon)=capability_constraints::establish(original)?;
        Ok(Self {token,logon})
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
        &self,operation:impl FnOnce()->Result<T,IoError>,
        #[cfg(debug_assertions)] observation:Option<&PublicPipeObservation>,
    )->Result<T,IoError> {
        with_impersonation_lifetime(||unsafe {ImpersonateLoggedOnUser(self.token.raw())!=0},
            |reason|{
                #[cfg(debug_assertions)]
                if let Some(observation)=observation {observation.guard_failed(reason);}
                let _=reason;IoError::Failed
            },
            ||{
                #[cfg(debug_assertions)]
                {let class=PublicPipeErrorClass::last_error();if let Some(observation)=observation {
                    observation.operation_failed(PublicPipeFailureApi::Impersonate,class);observation.token_impersonated(false);
                }}
                IoError::Failed
            },
            ||{
                #[cfg(debug_assertions)]
                if let Some(observation)=observation {observation.token_impersonated(true);}
                effective_capability(self.token.raw()).map_err(|reason|{
                    #[cfg(debug_assertions)]
                    if let Some(observation)=observation {observation.guard_failed(reason);}
                    let _=reason;IoError::Failed
                })
            },operation,||{
                #[cfg(debug_assertions)]
                if let Some(observation)=observation {observation.token_reverted(true);}
            })
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
    with_impersonation_lifetime(||unsafe {ImpersonateNamedPipeClient(pipe)!=0},
        |_|PeerFailure::Impersonation,||PeerFailure::Impersonation,
        ||{if let Some(trace)=trace {trace.impersonated.store(true,Ordering::SeqCst);}Ok(())},
        ||{
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
        },||{if let Some(trace)=trace {trace.reverted.store(true,Ordering::SeqCst);}})?;
    verified_client_executable(pipe).map_err(|_| PeerFailure::Executable)
}

pub(crate) fn verify_pipe_peer_charged(
    pipe: HANDLE,
    expected: &Identity,
    trace: Option<&PeerTrace>,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ChargedValue<NonEmpty>, PeerFailure> {
    with_impersonation_lifetime(||unsafe {ImpersonateNamedPipeClient(pipe)!=0},
        |_|PeerFailure::Impersonation,||PeerFailure::Impersonation,
        ||{if let Some(trace)=trace {trace.impersonated.store(true,Ordering::SeqCst);}Ok(())},
        ||{
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
        },||{if let Some(trace)=trace {trace.reverted.store(true,Ordering::SeqCst);}})?;
    verified_client_executable_charged(pipe, authority, pool).map_err(|_| PeerFailure::Executable)
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
pub(super) fn server_capability_caller_class() -> Option<serde_json::Value> {
    capability_constraints::caller_class()
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
