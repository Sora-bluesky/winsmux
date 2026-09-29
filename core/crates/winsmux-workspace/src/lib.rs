//! Workspace protocol, Windows host transport, and connection authorization.
pub mod auth;
pub mod client;
pub mod contract;
pub mod host;
#[cfg(windows)]
pub(crate) mod provider;
#[cfg(windows)]
pub(crate) mod runtime;
#[cfg(windows)]
pub(crate) mod service;
#[cfg(windows)]
pub(crate) mod store;
pub use contract::{
    canonical_request, parse_request, parse_response, parse_snapshot, serialize_response,
    serialize_snapshot, ContractError, Request, Response, Snapshot,
};

#[cfg(windows)]
pub fn run_internal_git_reader() -> i32 {
    service::git_reader::run_internal_git_reader()
}

#[cfg(all(windows, debug_assertions))]
pub mod memory_testing {
    pub use crate::contract::ingress::{
        prepare_request, HostCodecError, HostCodecPhase, PreparedRequest, WireCorrelation,
    };
    pub use crate::host::admission::{
        AllocationAuthority, AllocationError, AllocationPool, AllocationSnapshot, ChargedVec,
        ConnectionSupervisor, ConnectionSupervisorError, OwnedFrame, ACTIVE_BYTES,
        ACTIVE_OWNER_BYTES, ACTIVE_PUBLIC_BYTES, PUBLIC_WORKER_STACK_BYTES, RETAINED_BYTES,
    };

    pub fn fail_after_allocations(authority: &AllocationAuthority, successful_allocations: usize) {
        authority.fail_after_allocations(successful_allocations);
    }

    pub use crate::auth::testing::SendGateHold;
    pub use crate::auth::{
        Authorization, PhaseHold, ProductPhase, TestingConnectionSnapshot, TestingEventWaiter,
        TestingReplayReceipt,
    };
    pub use crate::host::io::WriteBodyHold;
    pub use crate::runtime::spawn::{
        classify_readfile, exit_code, handle_signaled, issue_pending_overlapped_write,
        job_active_processes, prove_overlapped_cancel_is_not_delivery,
        prove_readfile_after_pty_and_job_close, resume_once, retained_write_count,
        retained_write_identities, spawn_suspended_shell, suspend_once, IoObservation,
        PreparedChild, ReadClass, ReadCloseProof, WriteIdentity, STILL_ACTIVE,
    };
    pub use crate::runtime::{
        Activation, IoObserveEvent, IoObserveKind, RunIoObserveGuard, RunIoStats, RuntimeService,
        TestingDataSlot,
    };
    pub use crate::service::output::{
        decode_cursor, encode_cursor, OpaqueCursor, ResolvedCursor, os_wait_timeout,
        resolve_read_cursor,
    };
    pub use crate::service::replay::{ledger_class, LedgerClass};
    pub use crate::service::run::{key_byte, key_payload};
    pub use crate::store::root_identity::{
        classify_path_syntax, console_host_pid, exclusive_directory_hold, generate_console_ctrl_c,
        observe_root, paths_are_windows_aliases, reobserve_state, short_path_name,
        stop_owned_process_tree, testing_create_unpaired_surrogate_directory,
        testing_os_utf16_final_path, testing_probe_volumes, testing_remove_wide_directory,
        ExclusiveDirectoryHold, ObserveError, ObserveHold, ObservedRoot, VolumeProbe,
        WideCreateReceipt,
    };
}

/// Run the public workspace CLI namespace once.
///
/// The calling process must exit after this function returns. A second call in
/// the same process, reuse of standard input, joining the blocking input reader,
/// and restoration of an inherited Ctrl+C-ignore attribute are outside this
/// one-shot boundary. Diagnostics are fixed classifications and never include
/// request, path, environment, or handle data.
pub fn run_cli(arguments: &[String]) -> i32 {
    #[cfg(windows)]
    if let [command, handle] = arguments {
        if command == "__host-child" {
            return host::run_child_cli(handle);
        }
    }
    let result = match arguments {
        [command] if command == "host" => host::run_launcher(),
        [command] if command == "connect" => client::run_connect(),
        #[cfg(not(windows))]
        [command, handle] if command == "__host-child" => host::run_child(handle),
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        [command, owner, ready, discard, parent] if command == "__task870-host-stop-reply-loss" => {
            host::run_child_stop_reply_loss(owner, ready, discard, parent)
        }
        #[cfg(all(windows, debug_assertions))]
        [command, owner, report, release, launcher_pid] if command == "__test-inherit-helper" => {
            host::testing::run_inheritance_helper(owner, report, release, launcher_pid)
        }
        _ => Err(host::HostError::Usage),
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("winsmux workspace: {}", error.classification());
            error.exit_code()
        }
    }
}
