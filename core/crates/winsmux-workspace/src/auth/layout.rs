use super::{
    admit_owner_effect, bump_topology, close_open_connections, publish_connection_state,
    publish_topology_change, reserve_forget_drains, seal_terminal, take_unsignaled_cancellations,
    topology_denial, validated_key, write_error, write_success_data, Authorization, EventCredit, GenerationState,
    MetadataEvent, OwnerDispatch, RecordState, State,
};
use crate::contract::{
    ConnectionState, ErrorCode, HostStopData, LayoutRestoreData, LayoutSaveData, Request, Snapshot,
    Success, True, U, MAX_MESSAGE_BYTES,
};
use crate::host::admission::{AllocationAuthority, AllocationPool, ChargedVec};
use crate::runtime::CompleteSessionQuiescence;
use crate::store::root_identity::{observe_root, ObservedRoot};

fn layout_dispatch(
    forget_drains: Option<ChargedVec<super::GenerationCancel>>,
    stop_after_reply: bool,
) -> OwnerDispatch {
    OwnerDispatch {
        cancellation: None,
        forget_drains,
        observation: None,
        stop_after_reply,
    }
}

fn deny(
    auth: &Authorization,
    state: &State,
    request: &Request,
    out: &mut ChargedVec<u8>,
    code: ErrorCode,
) -> Option<OwnerDispatch> {
    write_error(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        code,
    )?;
    Some(layout_dispatch(None, false))
}

fn fail_retained(
    auth: &Authorization,
    state: &mut State,
    request: &Request,
    out: &mut ChargedVec<u8>,
    code: ErrorCode,
) -> Option<OwnerDispatch> {
    write_error(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        code,
    )?;
    seal_terminal(state, request, out, false)?;
    Some(layout_dispatch(None, false))
}

fn layout_identity(state: &State) -> Result<(U, U), ErrorCode> {
    let generation = U::new(0).map_err(|_| ErrorCode::PersistenceFailed)?;
    let topology = U::new(state.topology_revision).map_err(|_| ErrorCode::PersistenceFailed)?;
    Ok((generation, topology))
}


fn save_current_layout(
    auth: &Authorization,
    state: &mut State,
) -> Result<(U, U), ErrorCode> {
    let (generation, topology) = layout_identity(state)?;
    let snapshot = state.workspace.snapshot(generation.clone(), topology.clone())?;
    let observed = observe_snapshot_roots(&snapshot, &auth.shared.allocations)?;
    let transaction = state
        .layout
        .begin(&auth.shared.allocations, AllocationPool::ActiveOwner)?;
    transaction.save(
        &snapshot,
        &auth.shared.allocations,
        AllocationPool::ActiveOwner,
    )?;
    drop(observed);
    Ok((generation, topology))
}

fn complete_workspace_quiescence(
    state: &State,
) -> Result<CompleteSessionQuiescence, ErrorCode> {
    for project in state.workspace.projects() {
        state
            .runtime
            .project_session_quiescence(&project.id, &project.panes)?;
    }
    state.runtime.complete_session_quiescence()
}

fn restore_occupancy_code(state: &State) -> Option<ErrorCode> {
    if state
        .workspace
        .projects()
        .iter()
        .any(|project| project.spawn_reserved)
    {
        return Some(ErrorCode::OperationConflict);
    }
    match complete_workspace_quiescence(state) {
        Err(_) => Some(ErrorCode::RuntimeFailed),
        Ok(CompleteSessionQuiescence::Preparing) => Some(ErrorCode::OperationConflict),
        Ok(CompleteSessionQuiescence::Unclean) => Some(ErrorCode::AlreadyRunning),
        Ok(CompleteSessionQuiescence::Clean) => None,
    }
}

fn host_stop_blocked(state: &State) -> bool {
    if state
        .workspace
        .projects()
        .iter()
        .any(|project| project.spawn_reserved)
    {
        return true;
    }
    !matches!(
        complete_workspace_quiescence(state),
        Ok(CompleteSessionQuiescence::Clean)
    )
}

fn restore_needs_revoke(state: &State, index: usize) -> bool {
    let record = &state.connections[index];
    !matches!(
        record.state,
        RecordState::Closing | RecordState::Finished
    ) && !record.revoked_published
}

fn revoke_event_count(state: &State) -> usize {
    (0..state.connections.len())
        .filter(|index| restore_needs_revoke(state, *index))
        .count()
}

fn charged_restore_vec<T>(
    allocations: &AllocationAuthority,
    count: usize,
) -> Result<ChargedVec<T>, ErrorCode> {
    let bytes = count
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(ErrorCode::ResourceExhausted)?;
    ChargedVec::with_capacity(allocations, AllocationPool::ActiveOwner, count, bytes)
        .map_err(|_| ErrorCode::ResourceExhausted)
}

fn observe_snapshot_roots(
    snapshot: &Snapshot,
    allocations: &AllocationAuthority,
) -> Result<ChargedVec<ObservedRoot>, ErrorCode> {
    let mut observed = charged_restore_vec::<ObservedRoot>(allocations, snapshot.projects.len())?;
    for project in &snapshot.projects {
        let root = observe_root(
            project.path.as_str(),
            allocations,
            AllocationPool::ActiveOwner,
        )
        .map_err(|error| error.code())?;
        if root.identity != project.root_identity {
            return Err(ErrorCode::RootChanged);
        }
        observed
            .try_push(root)
            .map_err(|_| ErrorCode::ResourceExhausted)?;
    }
    Ok(observed)
}

fn release_held_event_credits(
    state: &mut State,
    credits: &mut ChargedVec<EventCredit>,
    topology_credit: Option<EventCredit>,
) {
    while !credits.is_empty() {
        if let Some(credit) = credits.remove(credits.len() - 1) {
            state.events.release(credit);
        }
    }
    if let Some(credit) = topology_credit {
        state.events.release(credit);
    }
}

fn reserve_held_event_credits(
    state: &mut State,
    allocations: &AllocationAuthority,
    count: usize,
    credits: &mut ChargedVec<EventCredit>,
) -> Result<(), ErrorCode> {
    for _ in 0..count {
        if credits.len() >= credits.capacity_elements() {
            return Err(ErrorCode::ResourceExhausted);
        }
        let credit = state.events.try_reserve(allocations, 1)?;
        credits
            .try_push(credit)
            .map_err(|_| ErrorCode::ResourceExhausted)?;
    }
    Ok(())
}

fn reserve_restore_metadata_log(
    state: &mut State,
    allocations: &AllocationAuthority,
) -> Result<(), ErrorCode> {
    let extra_events = revoke_event_count(state)
        .checked_add(1)
        .ok_or(ErrorCode::ResourceExhausted)?;
    let needed = state
        .events
        .log
        .len()
        .checked_add(extra_events)
        .ok_or(ErrorCode::ResourceExhausted)?;
    if needed <= state.events.log.capacity_elements() {
        return Ok(());
    }
    let bytes = needed
        .checked_mul(std::mem::size_of::<MetadataEvent>())
        .ok_or(ErrorCode::ResourceExhausted)?;
    state
        .events
        .log
        .try_grow_retained(allocations, AllocationPool::ActiveOwner, needed, bytes)
        .map_err(|_| ErrorCode::ResourceExhausted)
}

fn publish_held_revokes(
    allocations: &AllocationAuthority,
    state: &mut State,
    credits: &mut ChargedVec<EventCredit>,
) {
    for index in 0..state.connections.len() {
        if !restore_needs_revoke(state, index) {
            continue;
        }
        let key = state.connections[index].connection_key;
        let credit = credits
            .remove(0)
            .expect("restore revoke credits were reserved exactly");
        publish_connection_state(
            allocations,
            state,
            &key,
            ConnectionState::Revoked,
            credit,
        );
    }
    release_held_event_credits(state, credits, None);
}

pub(crate) fn dispatch_owner_layout_save(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<OwnerDispatch> {
    if admit_owner_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
    )
    .is_none()
    {
        return deny(auth, &state, request, out, ErrorCode::ResourceExhausted);
    }
    match save_current_layout(auth, &mut state) {
        Ok((generation, topology)) => {
            write_success_data(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                Success::LayoutSave(LayoutSaveData {
                    generation,
                    saved_topology_revision: topology,
                }),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(layout_dispatch(None, false))
        }
        Err(code) => fail_retained(auth, &mut state, request, out, code),
    }
}

pub(crate) fn dispatch_owner_layout_restore(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<OwnerDispatch> {
    if let Some(code) = topology_denial(request, &state) {
        return deny(auth, &state, request, out, code);
    }
    if let Some(code) = restore_occupancy_code(&state) {
        return deny(auth, &state, request, out, code);
    }
    if admit_owner_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
    )
    .is_none()
    {
        return deny(auth, &state, request, out, ErrorCode::ResourceExhausted);
    }
    let allocations = &auth.shared.allocations;
    let transaction = match state.layout.begin(allocations, AllocationPool::ActiveOwner) {
        Ok(transaction) => transaction,
        Err(code) => return fail_retained(auth, &mut state, request, out, code),
    };
    let snapshot = match transaction.read_confirmed(allocations, AllocationPool::ActiveOwner) {
        Ok(snapshot) => snapshot,
        Err(code) => return fail_retained(auth, &mut state, request, out, code),
    };
    let observed = match observe_snapshot_roots(&snapshot, allocations) {
        Ok(observed) => observed,
        Err(code) => return fail_retained(auth, &mut state, request, out, code),
    };
    let replacement = match crate::service::workspace::WorkspaceService::from_snapshot(
        allocations,
        &snapshot,
        &observed,
    ) {
        Ok(workspace) => workspace,
        Err(code) => return fail_retained(auth, &mut state, request, out, code),
    };
    let revoke_needed = revoke_event_count(&state);
    let mut revoke_credits = match charged_restore_vec::<EventCredit>(allocations, revoke_needed) {
        Ok(credits) => credits,
        Err(code) => return fail_retained(auth, &mut state, request, out, code),
    };
    if let Err(code) =
        reserve_held_event_credits(&mut state, allocations, revoke_needed, &mut revoke_credits)
    {
        release_held_event_credits(&mut state, &mut revoke_credits, None);
        return fail_retained(auth, &mut state, request, out, code);
    }
    let topology_credit = match state.events.try_reserve(allocations, 1) {
        Ok(credit) => credit,
        Err(code) => {
            release_held_event_credits(&mut state, &mut revoke_credits, None);
            return fail_retained(auth, &mut state, request, out, code);
        }
    };
    if reserve_forget_drains(&mut state, allocations).is_err() {
        release_held_event_credits(&mut state, &mut revoke_credits, Some(topology_credit));
        return fail_retained(
            auth,
            &mut state,
            request,
            out,
            ErrorCode::ResourceExhausted,
        );
    }
    if let Err(code) = reserve_restore_metadata_log(&mut state, allocations) {
        release_held_event_credits(&mut state, &mut revoke_credits, Some(topology_credit));
        return fail_retained(auth, &mut state, request, out, code);
    }
    publish_held_revokes(allocations, &mut state, &mut revoke_credits);
    close_open_connections(allocations, &mut state);
    let _ = bump_topology(&mut state);
    state.workspace = replacement;
    state.artifacts.invalidate_all();
    publish_topology_change(allocations, &mut state, topology_credit, None, None);
    write_success_data(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        Success::LayoutRestore(LayoutRestoreData {
            restored: True,
            generation: snapshot.generation.clone(),
        }),
    )?;
    seal_terminal(&mut state, request, out, false)?;
    let drains = take_unsignaled_cancellations(&mut state, allocations);
    let forget_drains = if drains.is_empty() {
        None
    } else {
        Some(drains)
    };
    drop(observed);
    drop(transaction);
    Some(layout_dispatch(forget_drains, false))
}

pub(crate) fn dispatch_owner_host_stop(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<OwnerDispatch> {
    if host_stop_blocked(&state) {
        return deny(auth, &state, request, out, ErrorCode::RuntimeFailed);
    }
    // The production owner loop supplies this entire bounded frame before dispatch.
    // Check it before touching C so an error can also replace the prepared success.
    if out.capacity_elements() < MAX_MESSAGE_BYTES {
        return deny(auth, &state, request, out, ErrorCode::ResourceExhausted);
    }
    let (generation, topology) = match layout_identity(&state) {
        Ok(value) => value,
        Err(code) => return deny(auth, &state, request, out, code),
    };
    write_success_data(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        Success::HostStop(HostStopData {
            stopped: True,
            saved_generation: generation,
            saved_topology_revision: topology,
        }),
    )?;
    if admit_owner_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
    )
    .is_none()
    {
        return deny(auth, &state, request, out, ErrorCode::ResourceExhausted);
    }
    if let Err(code) = save_current_layout(auth, &mut state) {
        return fail_retained(auth, &mut state, request, out, code);
    }
    let key = validated_key(request.operation_id.as_str());
    let saved_topology = state.topology_revision;
    state.stop_reserved = Some(key);
    let runtime = std::sync::Arc::clone(&state.runtime);
    // Notification is not completion. The same registry owns both joins, outside
    // the authorization mutex so existing replies and recovery can still proceed.
    runtime.cancel_provider_probes();
    drop(state);
    let joined = runtime.drain_provider_probes();
    let mut state = auth.shared.inner.lock().ok()?;
    if state.generation != GenerationState::Open || state.stop_reserved != Some(key) {
        return fail_retained(auth, &mut state, request, out, ErrorCode::StateUnknown);
    }
    state.stop_reserved = None;
    if !joined {
        return fail_retained(auth, &mut state, request, out, ErrorCode::RuntimeFailed);
    }
    if state.topology_revision != saved_topology || host_stop_blocked(&state) {
        return fail_retained(auth, &mut state, request, out, ErrorCode::OperationConflict);
    }
    let (generation, topology) = layout_identity(&state).ok()?;
    write_success_data(out, request, &auth.shared.instance_id, state.event_seq(),
        state.topology_revision, Success::HostStop(HostStopData {
            stopped: True, saved_generation: generation, saved_topology_revision: topology,
        }))?;
    seal_terminal(&mut state, request, out, false)?;
    state.generation = GenerationState::Closing;
    state.artifacts.invalidate_all();
    state.runtime.set_generation_visible(false);
    Some(layout_dispatch(None, true))
}

#[cfg(debug_assertions)]
impl Authorization {
    pub fn testing_install_isolated_layout(&self, root: &std::path::Path) -> bool {
        let Ok(store) = crate::store::layout::LayoutStore::open_isolated(root) else {
            return false;
        };
        let Ok(mut state) = self.shared.inner.lock() else {
            return false;
        };
        if state.generation != GenerationState::Open
            || state.topology_revision != 0
            || state.event_seq() != 0
            || !state.connections.is_empty()
            || !state.replay.slots.is_empty()
        {
            return false;
        }
        state.layout = store;
        true
    }

    pub fn testing_release_layout_guard_for_invalid_setup(&self) -> bool {
        let Ok(mut state) = self.shared.inner.lock() else {
            return false;
        };
        state.layout.testing_release_guard_for_invalid_setup();
        true
    }

    pub fn testing_insert_preparing_run(
        &self,
        project_id: crate::contract::ProjectId,
        pane_id: crate::contract::PaneId,
        run_id: crate::contract::RunId,
    ) -> Result<(), ErrorCode> {
        let state = self
            .shared
            .inner
            .lock()
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        state.runtime.insert_preparing(project_id, pane_id, run_id)
    }
}

#[cfg(test)]
impl Authorization {
    pub fn testing_inject_layout_fault(
        &self,
        fault: crate::store::layout::LayoutStoreFault,
    ) -> bool {
        let Ok(mut state) = self.shared.inner.lock() else {
            return false;
        };
        state.layout.inject_fault(fault);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::super::testing::Harness;
    use super::*;
    use crate::contract::{
        Action, CapabilitiesGetParams, Empty, Nullable, OperationId, OperationParams, OperationPhase, Outcome, PaneId,
        ProjectId, RunId, Version,
    };
    use crate::store::layout::LayoutStoreFault;
    use std::fs;
    use std::path::PathBuf;

    fn isolate(harness: &Harness) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "winsmux-auth-layout-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        assert!(
            harness
                .authorization()
                .testing_install_isolated_layout(&root),
            "isolated layout store"
        );
        root
    }

    fn owner_request(harness: &Harness, op: u8, action: Action, expected: Option<u64>) -> Request {
        Request {
            schema_version: Version::new(1).expect("v1"),
            instance_id: Nullable(Some(harness.instance_id())),
            operation_id: OperationId::new(format!(
                "{op:08x}-0000-4000-8000-000000000866"
            ))
            .expect("operation id"),
            expected_topology_revision: Nullable(
                expected.map(|value| U::new(value).expect("revision")),
            ),
            action,
        }
    }

    fn error_of(response: &crate::contract::Response) -> ErrorCode {
        response.error.0.as_ref().expect("error response").code()
    }

    fn operation_outcome(
        harness: &Harness,
        query_id: u8,
        target: &OperationId,
    ) -> (OperationPhase, Option<Outcome>, Option<ErrorCode>) {
        let response = harness.owner(&owner_request(
            harness,
            query_id,
            Action::OperationGet(OperationParams {
                operation_id: target.clone(),
            }),
            None,
        ));
        assert!(response.accepted);
        let Some(Success::OperationGet(data)) = response.result.0 else {
            panic!("expected operation.get result");
        };
        (
            data.operation.phase,
            data.operation.outcome.0,
            data.operation.error_code.0,
        )
    }

    fn preparing_ids() -> (ProjectId, PaneId, RunId) {
        (
            ProjectId::new("30000000-0000-4000-8000-000000000866").expect("project"),
            PaneId::new("40000000-0000-4000-8000-000000000866").expect("pane"),
            RunId::new("50000000-0000-4000-8000-000000000866").expect("run"),
        )
    }

    #[test]
    fn public_layout_and_stop_are_permission_denied_before_io() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let client = harness.connect("pwsh");
        for action in [
            Action::LayoutSave(Empty {}),
            Action::LayoutRestore(Empty {}),
            Action::HostStop(Empty {}),
        ] {
            let expected = if matches!(action, Action::LayoutRestore(_)) {
                Some(0)
            } else {
                None
            };
            let response = client
                .request(&owner_request(&harness, 1, action, expected))
                .expect("public reply");
            assert!(!response.accepted);
            assert_eq!(error_of(&response), ErrorCode::PermissionDenied);
            assert_eq!(
                harness.authorization().testing_replay_phase(&response.operation_id),
                None,
            );
        }
        assert!(!root.join("confirmed.json").exists());
        assert!(harness.authorization().generation_is_open());
    }

    #[test]
    fn owner_isolated_save_restore_does_not_resume_runs() {
        let harness = Harness::new(Vec::new());
        let _root = isolate(&harness);
        let save = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
        assert!(save.accepted);
        match save.result.0 {
            Some(Success::LayoutSave(_)) => {}
            other => panic!("expected layout.save success, got {other:?}"),
        }
        let restore = harness.owner(&owner_request(&harness,
            2,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert!(restore.accepted);
        match restore.result.0 {
            Some(Success::LayoutRestore(data)) => {
                assert_eq!(data.restored, True);
            }
            other => panic!("expected layout.restore success, got {other:?}"),
        }
        assert!(harness.authorization().testing_selected().is_none());
        let (project, pane, run) = preparing_ids();
        assert!(!harness.authorization().testing_has_session(&run));
        let _ = (project, pane);
    }

    #[test]
    fn layout_save_replay_returns_first_result_without_second_write() {
        let harness = Harness::new(Vec::new());
        let _root = isolate(&harness);
        let request = owner_request(&harness, 1, Action::LayoutSave(Empty {}), None);
        let first = harness.owner(&request);
        assert!(first.accepted);
        assert_eq!(
            harness
                .authorization()
                .testing_replay_phase(&request.operation_id),
            Some("done")
        );
        assert!(harness
            .authorization()
            .testing_inject_layout_fault(LayoutStoreFault::TempWrite));
        let replayed = harness.owner(&request);
        assert!(replayed.accepted);
        assert_eq!(first.result, replayed.result);
        assert_eq!(first.topology_revision, replayed.topology_revision);
        assert!(harness.authorization().generation_is_open());
    }

    #[test]
    fn corrupt_missing_unknown_c_preserves_state_even_with_b() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let first = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
        assert!(first.accepted);
        let second = harness.owner(&owner_request(&harness, 2, Action::LayoutSave(Empty {}), None));
        assert!(second.accepted);
        let confirmed = root.join("confirmed.json");
        let backup = root.join("backup.json");
        assert!(confirmed.exists());
        let backup_before = fs::read(&backup).unwrap_or_default();
        let selected_before = harness.authorization().testing_selected();
        let counters_before = harness.authorization().testing_counters();

        fs::write(&confirmed, b"not-a-snapshot").expect("corrupt C");
        let corrupt = harness.owner(&owner_request(&harness,
            3,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert!(!corrupt.accepted);
        assert_eq!(error_of(&corrupt), ErrorCode::PersistenceFailed);
        assert_eq!(harness.authorization().testing_selected(), selected_before);
        assert_eq!(harness.authorization().testing_counters(), counters_before);
        assert_eq!(fs::read(&backup).unwrap_or_default(), backup_before);

        let _ = fs::remove_file(&confirmed);
        let missing = harness.owner(&owner_request(&harness,
            4,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert!(!missing.accepted);
        assert_eq!(error_of(&missing), ErrorCode::PersistenceFailed);
        assert_eq!(harness.authorization().testing_selected(), selected_before);
        assert_eq!(harness.authorization().testing_counters(), counters_before);
        assert_eq!(fs::read(&backup).unwrap_or_default(), backup_before);

        fs::write(
            &confirmed,
            br#"{"generation":0,"layouts":[],"panes":[],"projects":[],"schema_version":2,"selected_pane_id":null,"selected_project_id":null,"topology_revision":0}"#,
        )
        .expect("unknown schema C");
        let unknown = harness.owner(&owner_request(&harness,
            5,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert!(!unknown.accepted);
        assert_eq!(error_of(&unknown), ErrorCode::PersistenceFailed);
        assert_eq!(harness.authorization().testing_selected(), selected_before);
        assert_eq!(harness.authorization().testing_counters(), counters_before);
        assert_eq!(fs::read(&backup).unwrap_or_default(), backup_before);
        assert!(harness.authorization().generation_is_open());
    }

    #[test]
    fn layout_restore_stale_revision_does_not_touch_store() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let stale = harness.owner(&owner_request(&harness,
            1,
            Action::LayoutRestore(Empty {}),
            Some(1),
        ));
        assert!(!stale.accepted);
        assert_eq!(error_of(&stale), ErrorCode::StaleTopology);
        assert!(!root.join("confirmed.json").exists());
        assert_eq!(harness.authorization().testing_counters(), (0, 0));
    }

    #[test]
    fn restore_and_stop_refuse_all_session_occupancy() {
        let project =
            ProjectId::new("30000000-0000-4000-8000-000000000861").expect("project");
        let live = Harness::new(vec![project.clone()]);
        let live_root = isolate(&live);
        assert!(live
            .authorization()
            .testing_set_occupancy(&project, true, false));
        let live_restore = live.owner(&owner_request(&live,
            1,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert_eq!(error_of(&live_restore), ErrorCode::AlreadyRunning);
        let live_request = owner_request(&live, 2, Action::HostStop(Empty {}), None);
        let live_stop = live.owner(&live_request);
        assert_eq!(error_of(&live_stop), ErrorCode::RuntimeFailed);
        assert_eq!(
            live.authorization().testing_replay_phase(&live_request.operation_id),
            None
        );
        assert!(live.authorization().generation_is_open());
        assert!(!live_root.join("confirmed.json").exists());

        let reserved_project =
            ProjectId::new("30000000-0000-4000-8000-000000000862").expect("project");
        let reserved = Harness::new(vec![reserved_project.clone()]);
        isolate(&reserved);
        assert!(reserved.authorization().testing_set_occupancy(
            &reserved_project,
            false,
            true
        ));
        let reserved_restore = reserved.owner(&owner_request(&reserved,
            1,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert_eq!(error_of(&reserved_restore), ErrorCode::OperationConflict);
        let reserved_request = owner_request(&reserved, 2, Action::HostStop(Empty {}), None);
        let reserved_stop = reserved.owner(&reserved_request);
        assert_eq!(error_of(&reserved_stop), ErrorCode::RuntimeFailed);
        assert_eq!(
            reserved.authorization().testing_replay_phase(&reserved_request.operation_id),
            None
        );
        assert!(reserved.authorization().generation_is_open());

        let preparing = Harness::new(Vec::new());
        let preparing_root = isolate(&preparing);
        let (project_id, pane_id, run_id) = preparing_ids();
        preparing
            .authorization()
            .testing_insert_preparing_run(project_id, pane_id, run_id)
            .expect("preparing session");
        let preparing_restore = preparing.owner(&owner_request(&preparing,
            1,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert_eq!(error_of(&preparing_restore), ErrorCode::OperationConflict);
        let preparing_request = owner_request(&preparing, 2, Action::HostStop(Empty {}), None);
        let preparing_stop = preparing.owner(&preparing_request);
        assert_eq!(error_of(&preparing_stop), ErrorCode::RuntimeFailed);
        assert_eq!(
            preparing.authorization().testing_replay_phase(&preparing_request.operation_id),
            None
        );
        assert!(preparing.authorization().generation_is_open());
        assert!(!preparing_root.join("confirmed.json").exists());

        let poisoned = Harness::new(Vec::new());
        isolate(&poisoned);
        poisoned.poison();
        assert!(poisoned
            .try_owner(&owner_request(&poisoned, 1, Action::HostStop(Empty {}), None))
            .is_none());
        assert!(poisoned
            .try_owner(&owner_request(&poisoned,
                2,
                Action::LayoutRestore(Empty {}),
                Some(0)
            ))
            .is_none());
    }

    #[test]
    fn host_stop_clean_commits_closing_and_refuses_admission() {
        let harness = Harness::new(Vec::new());
        isolate(&harness);
        let auth = harness.authorization();
        let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
        assert!(!runtime.testing_provider_registry_started());
        let request = owner_request(&harness, 1, Action::HostStop(Empty {}), None);
        let stopped = harness.owner(&request);
        assert!(stopped.accepted);
        match stopped.result.0 {
            Some(Success::HostStop(data)) => {
                assert_eq!(data.stopped, True);
            }
            other => panic!("expected host.stop success, got {other:?}"),
        }
        assert!(harness.generation_is_closed());
        assert_eq!(
            harness.authorization().testing_replay_phase(&request.operation_id),
            Some("done")
        );
        assert!(!harness.authorization().generation_is_open());
        assert!(!harness.authentication_permitted());
        harness.start_provider_probes();
        assert!(!runtime.testing_provider_registry_started(), "late start created old-generation workers");
        assert!(harness.try_connect("pwsh").is_none());
        assert!(harness
            .try_owner(&owner_request(&harness, 2, Action::LayoutSave(Empty {}), None))
            .is_none());
        assert!(harness
            .try_owner(&owner_request(&harness, 3, Action::ProjectList(Empty {}), None))
            .is_none());
    }

    fn json_request(h: &Harness, operation: &str, params: serde_json::Value) -> Request {
        crate::contract::parse_request(&serde_json::to_vec(&serde_json::json!({
            "schema_version":1,"instance_id":h.instance_id(),
            "operation_id":uuid::Uuid::new_v4().to_string(),"expected_topology_revision":null,
            "operation":operation,"params":params
        })).unwrap()).unwrap()
    }

    fn grant_metadata(h: &Harness, c: &super::super::testing::Client) {
        assert!(c.request(&json_request(h, "connection.request", serde_json::json!({
            "project_ids":[],"scopes":["metadata"]
        }))).unwrap().accepted);
        assert!(h.owner(&json_request(h, "connection.decide", serde_json::json!({
            "connection_id":c.connection_id(),"decision":"allow","project_ids":[],"scopes":["metadata"]
        }))).accepted);
    }

    #[test]
    fn host_stop_waits_outside_auth_lock_preserves_sends_and_reserves_new_work() {
        let h = std::sync::Arc::new(Harness::new(Vec::new()));
        let root = isolate(&h);
        let client = h.connect("existing-client");
        grant_metadata(&h, &client);
        let before = h.authorization().testing_connection_snapshot(&client.connection_id());
        let auth = h.authorization();
        let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
        let release = runtime.testing_install_provider_join_gate();
        let request = owner_request(&h, 1, Action::HostStop(Empty {}), None);
        let (tx, rx) = std::sync::mpsc::channel();
        let owner = std::sync::Arc::clone(&h); let stopping = request.clone();
        let worker = std::thread::spawn(move || { tx.send(owner.owner(&stopping)).unwrap(); });
        let start = std::time::Instant::now();
        loop {
            if auth.shared.inner.try_lock().ok().is_some_and(|s| s.stop_reserved.is_some()) { break; }
            assert!(start.elapsed()<std::time::Duration::from_secs(30));
            std::thread::yield_now();
        }
        assert!(rx.try_recv().is_err(), "success before worker join");
        let saved = fs::read(root.join("confirmed.json")).unwrap();
        assert_eq!(error_of(&h.owner(&request)), ErrorCode::InProgress);
        let mut changed = request.clone(); changed.action = Action::LayoutSave(Empty {});
        assert_eq!(error_of(&h.owner(&changed)), ErrorCode::OperationConflict);
        assert_eq!(error_of(&client.request(&request).unwrap()), ErrorCode::PermissionDenied);
        let another = owner_request(&h, 2, Action::HostStop(Empty {}), None);
        assert_eq!(error_of(&h.owner(&another)), ErrorCode::OperationConflict);
        let fresh = json_request(&h, "capabilities.get", serde_json::json!({}));
        assert_eq!(error_of(&client.request(&fresh).unwrap()), ErrorCode::OperationConflict);
        assert!(client.send_if_current(), "reservation revoked existing reply permit");
        assert_eq!(auth.testing_connection_snapshot(&client.connection_id()), before);
        assert!(!h.authentication_permitted());
        assert!(h.try_connect("new-client").is_none());
        assert_eq!(fs::read(root.join("confirmed.json")).unwrap(), saved);
        assert!(!runtime.is_provider_ready(crate::contract::Provider::Codex));
        release.send(()).unwrap();
        let result = rx.recv_timeout(std::time::Duration::from_secs(30)).unwrap();
        worker.join().unwrap();
        assert!(result.accepted && h.generation_is_closed());
        assert_eq!(fs::read(root.join("confirmed.json")).unwrap(), saved);
        assert!(auth.drain_provider_probes());
    }

    #[test]
    fn host_stop_join_failure_replays_failure_and_keeps_existing_connection_usable() {
        let h = Harness::new(Vec::new()); isolate(&h);
        let client = h.connect("existing-client");
        grant_metadata(&h, &client);
        let auth = h.authorization();
        let before = auth.testing_connection_snapshot(&client.connection_id());
        let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
        runtime.testing_install_provider_join_failure();
        let request = owner_request(&h, 1, Action::HostStop(Empty {}), None);
        let first = h.owner(&request);
        assert_eq!(error_of(&first), ErrorCode::RuntimeFailed);
        assert!(auth.generation_is_open() && h.authentication_permitted());
        assert_eq!(h.owner(&request), first);
        assert_eq!(error_of(&h.owner(&owner_request(&h, 2, Action::HostStop(Empty {}), None))), ErrorCode::RuntimeFailed);
        assert!(!auth.drain_provider_probes(), "final drain erased a failed join");
        assert_eq!(auth.testing_connection_snapshot(&client.connection_id()), before);
        assert!(client.send_if_current());
        assert!(client.request(&json_request(&h, "capabilities.get", serde_json::json!({}))).unwrap().accepted);
        assert!(client.request(&json_request(&h, "diagnostics.get", serde_json::json!({}))).unwrap().accepted);
        assert!(h.owner(&owner_request(&h, 3, Action::ProjectList(Empty {}), None)).accepted);
        assert!(!runtime.is_provider_ready(crate::contract::Provider::Codex));
        assert!(!runtime.is_provider_ready(crate::contract::Provider::Claude));
    }

    #[test]
    fn host_stop_public_admission_and_preauth_share_the_reservation_gate() {
        use crate::host::admission::ConnectionSupervisor;
        use crate::host::io::CancelEvent;
        let h = std::sync::Arc::new(Harness::new(Vec::new()));
        isolate(&h);
        let client = h.connect("existing-client");
        grant_metadata(&h, &client);
        let auth = h.authorization();
        let before = auth.testing_connection_snapshot(&client.connection_id());
        let generation_cancel = std::sync::Arc::new(CancelEvent::new().unwrap());
        let supervisor = ConnectionSupervisor::new(auth.clone(), generation_cancel).unwrap();
        let (lease_tx, lease_rx) = std::sync::mpsc::channel();
        let (worker_release, worker_wait) = std::sync::mpsc::channel();
        supervisor.spawn(std::sync::Arc::new(CancelEvent::new().unwrap()), move |lease| {
            lease_tx.send(lease).unwrap();
            let _ = worker_wait.recv();
        }).unwrap();
        let lease = lease_rx.recv_timeout(std::time::Duration::from_secs(30)).unwrap();
        assert!(auth.begin_worker_authentication(&lease).is_some());
        let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
        let release = runtime.testing_install_provider_join_gate();
        let request = owner_request(&h, 1, Action::HostStop(Empty {}), None);
        let owner = h.clone();
        let stopping = std::thread::spawn(move || owner.owner(&request));
        let start = std::time::Instant::now();
        loop {
            if auth.shared.inner.try_lock().ok().is_some_and(|s| s.stop_reserved.is_some()) { break; }
            assert!(start.elapsed() < std::time::Duration::from_secs(30));
            std::thread::yield_now();
        }
        let counts_before = (auth.record_count(), auth.allocations().snapshot().active_public);
        let ran = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_ran = ran.clone();
        let admission = supervisor.spawn(std::sync::Arc::new(CancelEvent::new().unwrap()), move |_| {
            worker_ran.store(true, std::sync::atomic::Ordering::SeqCst);
        });
        let refused_without_fatal = admission.is_ok();
        let no_new_auth = auth.begin_worker_authentication(&lease).is_none();
        let no_new_proof = auth.begin_worker_proof_send(&lease).is_none();
        let name = super::super::charge_executable_name(auth.allocations(),
            crate::contract::NonEmpty::new("reservation-test").unwrap()).unwrap();
        let no_publication = !auth.mark_verified(&lease, name);
        let counts_after = (auth.record_count(), auth.allocations().snapshot().active_public);
        let preserved = auth.testing_connection_snapshot(&client.connection_id()) == before
            && client.send_if_current() && auth.generation_is_open();
        worker_release.send(()).unwrap();
        release.send(()).unwrap();
        let stopped = stopping.join().unwrap();
        supervisor.close_and_reap().unwrap();
        assert!(refused_without_fatal, "reservation became a fatal supervisor error");
        assert!(no_new_auth && no_new_proof && no_publication,
            "pre-admitted worker crossed the authentication reservation gate");
        assert!(!ran.load(std::sync::atomic::Ordering::SeqCst));
        assert_eq!(counts_after, counts_before, "refused admission changed charged ownership");
        assert!(preserved && stopped.accepted);
    }

    #[test]
    fn host_stop_join_cannot_reopen_or_succeed_after_external_generation_end() {
        for failed in [false, true] {
            let h = std::sync::Arc::new(Harness::new(Vec::new())); isolate(&h);
            let auth = h.authorization();
            let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
            let release = runtime.testing_install_provider_join_gate();
            let request = owner_request(&h, 1, Action::HostStop(Empty {}), None);
            let owner = std::sync::Arc::clone(&h);
            let worker = std::thread::spawn(move || owner.owner(&request));
            let start = std::time::Instant::now();
            loop {
                if auth.shared.inner.try_lock().ok().is_some_and(|s| s.stop_reserved.is_some()) { break; }
                assert!(start.elapsed()<std::time::Duration::from_secs(30));
                std::thread::yield_now();
            }
            if failed { auth.fail_generation().signal_cancellations(); } else { h.close_generation(); }
            release.send(()).unwrap();
            let response = worker.join().unwrap();
            assert!(!response.accepted && response.result.0.is_none());
            assert_eq!(error_of(&response), ErrorCode::StateUnknown);
            let state = auth.shared.inner.lock().unwrap();
            assert_eq!(state.generation, if failed { GenerationState::Failed } else { GenerationState::Closing });
        }
    }

    #[test]
    fn host_stop_failed_join_distinguishes_living_and_finished_authentication() {
        use crate::host::admission::ConnectionSupervisor;
        use crate::host::io::CancelEvent;
        use windows_sys::Win32::System::Threading::WaitForSingleObject;
        use windows_sys::Win32::Foundation::WAIT_OBJECT_0;
        for finished in [false, true] {
            let h = std::sync::Arc::new(Harness::new(Vec::new())); isolate(&h);
            let auth = h.authorization();
            let existing = h.connect("existing-client"); grant_metadata(&h, &existing);
            let before = auth.testing_connection_snapshot(&existing.connection_id());
            let supervisor = ConnectionSupervisor::new(auth.clone(),
                std::sync::Arc::new(CancelEvent::new().unwrap())).unwrap();
            let (lease_tx, lease_rx) = std::sync::mpsc::channel();
            let (finish, finish_wait) = std::sync::mpsc::channel();
            supervisor.spawn(std::sync::Arc::new(CancelEvent::new().unwrap()), move |lease| {
                lease_tx.send(lease).unwrap(); let _ = finish_wait.recv();
            }).unwrap();
            let lease = lease_rx.recv_timeout(std::time::Duration::from_secs(30)).unwrap();
            let release = auth.testing_install_stop_join_gate(true);
            let command = owner_request(&h, 1, Action::HostStop(Empty {}), None);
            let owner = h.clone(); let stopping = std::thread::spawn(move || owner.owner(&command));
            let start = std::time::Instant::now();
            while !auth.testing_stop_is_reserved() {
                assert!(start.elapsed() < std::time::Duration::from_secs(30));
                std::thread::yield_now();
            }
            assert!(auth.begin_worker_authentication(&lease).is_none());
            assert!(auth.begin_worker_proof_send(&lease).is_none());
            let mut finish = Some(finish);
            if finished {
                finish.take().unwrap().send(()).unwrap();
                assert_eq!(unsafe { WaitForSingleObject(supervisor.completion_raw(), 30_000) }, WAIT_OBJECT_0);
            }
            release.send(()).unwrap();
            assert_eq!(error_of(&stopping.join().unwrap()), ErrorCode::RuntimeFailed);
            assert!(auth.generation_is_open());
            assert_eq!(auth.begin_worker_authentication(&lease).is_some(), !finished);
            assert_eq!(auth.begin_worker_proof_send(&lease).is_some(), !finished);
            let name = super::super::charge_executable_name(auth.allocations(),
                crate::contract::NonEmpty::new("living-attempt").unwrap()).unwrap();
            assert_eq!(auth.mark_verified(&lease, name), !finished);
            assert_eq!(auth.testing_connection_snapshot(&existing.connection_id()), before);
            assert!(existing.send_if_current());
            if let Some(finish) = finish { finish.send(()).unwrap(); }
            assert_eq!(unsafe { WaitForSingleObject(supervisor.completion_raw(), 30_000) }, WAIT_OBJECT_0);
            assert_eq!(supervisor.reap_completed(), Ok(1));
            assert_eq!(supervisor.reap_completed(), Ok(0));
            assert!(auth.begin_worker_authentication(&lease).is_none());
            assert_eq!(auth.testing_connection_owned_bytes().1, 0);
            supervisor.close_and_reap().unwrap();
        }
    }

    #[test]
    fn failed_save_leaves_generation_open() {
        let harness = Harness::new(Vec::new());
        isolate(&harness);
        assert!(harness
            .authorization()
            .testing_inject_layout_fault(LayoutStoreFault::TempWrite));
        let save = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
        assert!(!save.accepted);
        assert_eq!(error_of(&save), ErrorCode::PersistenceFailed);
        assert!(harness.authorization().generation_is_open());
        assert!(!harness.generation_is_closed());

        let stop_harness = Harness::new(Vec::new());
        isolate(&stop_harness);
        assert!(stop_harness
            .authorization()
            .testing_inject_layout_fault(LayoutStoreFault::TempWrite));
        let stop = stop_harness.owner(&owner_request(&stop_harness, 1, Action::HostStop(Empty {}), None));
        assert!(!stop.accepted);
        assert_eq!(error_of(&stop), ErrorCode::PersistenceFailed);
        assert!(stop_harness.authorization().generation_is_open());
        assert!(!stop_harness.generation_is_closed());
        assert!(stop_harness.authentication_permitted());
    }

    #[test]
    fn host_stop_pre_effect_refusal_keeps_id_vacant() {
        let project = ProjectId::new("30000000-0000-4000-8000-000000000863").unwrap();
        let harness = Harness::new(vec![project.clone()]);
        let root = isolate(&harness);
        assert!(harness.authorization().testing_set_occupancy(&project, true, false));
        let request = owner_request(&harness, 1, Action::HostStop(Empty {}), None);
        let denied = harness.owner(&request);
        assert_eq!(error_of(&denied), ErrorCode::RuntimeFailed);
        assert_eq!(
            harness.authorization().testing_replay_phase(&request.operation_id),
            None
        );
        assert!(!root.join("confirmed.json").exists());
        assert!(!root.join("backup.json").exists());
        assert!(harness.authorization().generation_is_open());
        let reused = harness.owner(&owner_request(
            &harness,
            1,
            Action::CapabilitiesGet(CapabilitiesGetParams::default()),
            None,
        ));
        assert!(reused.accepted, "a pre-effect denial did not reserve the ID");
        assert_eq!(
            harness.authorization().testing_replay_phase(&request.operation_id),
            None
        );
    }

    #[test]
    fn host_stop_output_and_ledger_capacity_fail_before_store_write() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let request = owner_request(&harness, 1, Action::HostStop(Empty {}), None);
        let canonical = crate::contract::canonical_request(&request).expect("canonical request");
        let mut small_out = ChargedVec::with_capacity(
            harness.authorization().allocations(),
            AllocationPool::ActiveOwner,
            512,
            512,
        )
        .expect("small output");
        let dispatch = harness
            .authorization()
            .dispatch_owner(&request, &canonical, &mut small_out);
        assert!(dispatch.is_some());
        let limited = crate::contract::parse_response(&request, &small_out).expect("denial");
        assert_eq!(error_of(&limited), ErrorCode::ResourceExhausted);
        assert_eq!(
            harness.authorization().testing_replay_phase(&request.operation_id),
            None
        );
        assert!(!root.join("confirmed.json").exists());
        assert!(!root.join("backup.json").exists());
        assert!(harness.authorization().generation_is_open());

        let exhausted = harness.owner_after(&request, |allocations| {
            allocations.fail_after_allocations(0)
        });
        assert_eq!(error_of(&exhausted), ErrorCode::ResourceExhausted);
        assert_eq!(
            harness.authorization().testing_replay_phase(&request.operation_id),
            None
        );
        assert!(!root.join("confirmed.json").exists());
        assert!(!root.join("backup.json").exists());
        assert!(harness.authorization().generation_is_open());
        let stopped = harness.owner(&request);
        assert!(stopped.accepted);
        assert!(harness.generation_is_closed());
    }

    #[test]
    fn host_stop_fault_matrix_retains_first_error_without_second_save() {
        for (prior_save, fault, expected) in [
            (
                false,
                LayoutStoreFault::TempWrite,
                ErrorCode::PersistenceFailed,
            ),
            (
                false,
                LayoutStoreFault::ConfirmedReadback,
                ErrorCode::PersistenceFailed,
            ),
            (
                false,
                LayoutStoreFault::ConfirmedReadbackMemory,
                ErrorCode::ResourceExhausted,
            ),
            (
                true,
                LayoutStoreFault::TempWrite,
                ErrorCode::PersistenceFailed,
            ),
            (
                true,
                LayoutStoreFault::ConfirmedReadback,
                ErrorCode::PersistenceFailed,
            ),
            (
                true,
                LayoutStoreFault::ConfirmedReadbackMemory,
                ErrorCode::ResourceExhausted,
            ),
        ] {
            let harness = Harness::new(Vec::new());
            let root = isolate(&harness);
            if prior_save {
                let saved = harness.owner(&owner_request(
                    &harness,
                    9,
                    Action::LayoutSave(Empty {}),
                    None,
                ));
                assert!(saved.accepted);
            }
            let auth = harness.authorization();
            let runtime = std::sync::Arc::clone(&auth.shared.inner.lock().unwrap().runtime);
            runtime.testing_install_ready_providers();
            let client = harness.connect("save-failure-client");
            grant_metadata(&harness, &client);
            let grants = auth.testing_connection_snapshot(&client.connection_id());
            let confirmed = root.join("confirmed.json");
            let backup = root.join("backup.json");
            let c_before = fs::read(&confirmed).ok();
            let b_before = fs::read(&backup).ok();
            let request = owner_request(&harness, 1, Action::HostStop(Empty {}), None);
            assert!(harness.authorization().testing_inject_layout_fault(fault));
            let first = harness.owner(&request);
            assert!(!first.accepted, "{prior_save:?} {fault:?}");
            assert_eq!(error_of(&first), expected, "{prior_save:?} {fault:?}");
            assert_eq!(
                harness.authorization().testing_replay_phase(&request.operation_id),
                Some("done")
            );
            assert!(harness.authorization().generation_is_open());
            assert!(!harness.generation_is_closed());
            assert!(runtime.is_provider_ready(crate::contract::Provider::Codex));
            assert!(runtime.is_provider_ready(crate::contract::Provider::Claude));
            runtime.refresh_provider_probes(true);
            assert!(runtime.is_provider_ready(crate::contract::Provider::Codex));
            assert!(harness.authentication_permitted());
            assert!(client.send_if_current());
            assert_eq!(auth.testing_connection_snapshot(&client.connection_id()), grants);
            let c_after = fs::read(&confirmed).ok();
            let b_after = fs::read(&backup).ok();
            if fault == LayoutStoreFault::TempWrite {
                assert_eq!(c_after, c_before);
            } else {
                assert!(c_after.is_some(), "C replacement must have happened");
            }
            assert_eq!(
                b_after,
                if prior_save { c_before.clone() } else { b_before }
            );
            assert_eq!(
                operation_outcome(&harness, 2, &request.operation_id),
                (OperationPhase::Completed, Some(Outcome::Failed), Some(expected)),
            );
            assert!(harness.authorization().testing_inject_layout_fault(LayoutStoreFault::None));
            let replayed = harness.owner(&request);
            assert_eq!(replayed, first, "same ID must replay the first terminal");
            assert_eq!(fs::read(&confirmed).ok(), c_after);
            assert_eq!(fs::read(&backup).ok(), b_after);
            assert!(harness.authorization().generation_is_open());
            let changed = owner_request(&harness, 1, Action::LayoutSave(Empty {}), None);
            let conflict = harness.owner(&changed);
            assert_eq!(error_of(&conflict), ErrorCode::OperationConflict);
            assert_eq!(fs::read(&confirmed).ok(), c_after);
            assert_eq!(fs::read(&backup).ok(), b_after);
            let retried = harness.owner(&owner_request(
                &harness,
                3,
                Action::HostStop(Empty {}),
                None,
            ));
            assert!(retried.accepted, "new ID may retry after state check");
            assert!(harness.generation_is_closed());
        }
    }
    fn event_log_occupancy(harness: &Harness) -> (usize, usize, u64) {
        let authorization = harness.authorization();
        let state = authorization
            .shared
            .inner
            .lock()
            .expect("test authorization lock");
        (
            state.events.log.len(),
            state.events.log.capacity_elements(),
            state.events.dropped_through(),
        )
    }

    fn assert_restore_publication(
        harness: &Harness,
        log_len_before: usize,
        dropped_before: u64,
        revoked: &[crate::contract::ConnectionId],
    ) {
        let authorization = harness.authorization();
        let state = authorization
            .shared
            .inner
            .lock()
            .expect("test authorization lock");
        assert_eq!(state.events.dropped_through(), dropped_before);
        let added = &state.events.log[log_len_before..];
        assert_eq!(added.len(), revoked.len() + 1);
        for (event, connection_id) in added.iter().zip(revoked.iter()) {
            match &event.data {
                super::super::EventData::ConnectionStateChanged {
                    connection_id: published,
                    state: connection_state,
                } => {
                    assert_eq!(published, connection_id);
                    assert_eq!(connection_state, &ConnectionState::Revoked);
                }
                other => panic!("expected revoke metadata, got {other:?}"),
            }
        }
        match &added[revoked.len()].data {
            super::super::EventData::TopologyChanged {
                topology_revision: published,
                project_id,
                pane_id,
            } => {
                assert_eq!(
                    *published,
                    U::new(state.topology_revision).expect("topology revision")
                );
                assert!(project_id.0.is_none());
                assert!(pane_id.0.is_none());
            }
            other => panic!("expected topology metadata, got {other:?}"),
        }
    }

    #[test]
    fn restore_revokes_connected_clients_restores_saved_layout_without_runs_and_replays() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let client_a = harness.connect("pwsh");
        let client_b = harness.connect("pwsh");
        let save = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
        assert!(save.accepted);
        match save.result.0 {
            Some(Success::LayoutSave(_)) => {}
            other => panic!("expected layout.save success, got {other:?}"),
        }
        assert_eq!(harness.record_count(), 2);
        let seq_before = harness.event_seq();
        let states_before = harness.record_states();
        assert!(states_before
            .iter()
            .all(|state| *state != "closing" && *state != "finished"));
        let (log_len_before, log_capacity_before, dropped_before) =
            event_log_occupancy(&harness);
        let required_events = states_before
            .iter()
            .filter(|state| **state != "closing" && **state != "finished")
            .count()
            .checked_add(1)
            .expect("restore publication count");
        assert!(
            log_capacity_before.saturating_sub(log_len_before) < required_events,
            "live event log occupancy must require restore publication growth"
        );
        let request = owner_request(&harness, 2, Action::LayoutRestore(Empty {}), Some(0));
        let restored = harness.owner(&request);
        assert!(restored.accepted);
        match restored.result.0 {
            Some(Success::LayoutRestore(ref data)) => {
                assert_eq!(data.restored, True);
            }
            other => panic!("expected layout.restore success, got {other:?}"),
        }
        assert_restore_publication(
            &harness,
            log_len_before,
            dropped_before,
            &[client_a.connection_id(), client_b.connection_id()],
        );
        assert_eq!(harness.event_seq(), seq_before + 3);
        assert!(harness
            .record_states()
            .iter()
            .all(|state| *state == "closing" || *state == "finished"));
        assert!(client_a.cancelled());
        assert!(client_b.cancelled());
        assert!(harness.authorization().testing_selected().is_none());
        let (project, pane, run) = preparing_ids();
        assert!(!harness.authorization().testing_has_session(&run));
        let _ = (project, pane);
        assert!(harness.authorization().generation_is_open());
        assert!(!harness.generation_is_closed());
        assert!(root.join("confirmed.json").exists());
        let seq_after = harness.event_seq();
        let counters_after = harness.authorization().testing_counters();
        let replayed = harness.owner(&request);
        assert!(replayed.accepted);
        assert_eq!(restored.result, replayed.result);
        assert_eq!(restored.topology_revision, replayed.topology_revision);
        assert_eq!(harness.event_seq(), seq_after);
        assert_eq!(harness.authorization().testing_counters(), counters_after);
        assert_eq!(event_log_occupancy(&harness).0, log_len_before + required_events);
        assert_eq!(event_log_occupancy(&harness).2, dropped_before);
        assert_eq!(
            harness
                .authorization()
                .testing_replay_phase(&request.operation_id),
            Some("done")
        );
    }

    #[test]
    fn restore_preparation_allocation_failures_preserve_workspace_grants_topology_and_disk() {
        let mut failed_positions = 0usize;
        let mut k = 0usize;
        loop {
            let harness = Harness::new(Vec::new());
            let root = isolate(&harness);
            let client_a = harness.connect("pwsh");
            let client_b = harness.connect("pwsh");
            let save = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
            assert!(save.accepted);
            let confirmed = root.join("confirmed.json");
            let disk_before = fs::read(&confirmed).expect("saved confirmed");
            let selected_before = harness.authorization().testing_selected();
            let counters_before = harness.authorization().testing_counters();
            let states_before = harness.record_states();
            let seq_before = harness.event_seq();
            let outstanding_before = harness.authorization().testing_outstanding_credits();
            let expected_clients = [client_a.connection_id(), client_b.connection_id()];
            let (log_len_before, log_capacity_before, dropped_before) =
                event_log_occupancy(&harness);
            assert!(states_before
                .iter()
                .all(|state| *state != "closing" && *state != "finished"));
            let required_events = states_before
                .iter()
                .filter(|state| **state != "closing" && **state != "finished")
                .count()
                .checked_add(1)
                .expect("restore publication count");
            assert!(
                log_capacity_before.saturating_sub(log_len_before) < required_events,
                "live event log occupancy must require restore publication growth"
            );
            let request = owner_request(&harness, 2, Action::LayoutRestore(Empty {}), Some(0));
            let restored = harness.owner_after(&request, |allocations| {
                allocations.fail_after_allocations(k);
            });
            if restored.accepted {
                assert_restore_publication(
                    &harness,
                    log_len_before,
                    dropped_before,
                    &expected_clients,
                );
                assert_eq!(event_log_occupancy(&harness).2, dropped_before);
                assert_eq!(harness.event_seq(), seq_before + 3);
                assert!(harness
                    .record_states()
                    .iter()
                    .all(|state| *state == "closing" || *state == "finished"));
                assert!(client_a.cancelled());
                assert!(client_b.cancelled());
                assert!(harness.authorization().testing_selected().is_none());
                let (project, pane, run) = preparing_ids();
                assert!(!harness.authorization().testing_has_session(&run));
                let _ = (project, pane);
                assert!(harness.authorization().generation_is_open());
                assert_eq!(fs::read(&confirmed).expect("saved confirmed"), disk_before);
                harness.allocations().fail_after_allocations(0);
                assert!(harness.allocations().allocation_is_forced_to_fail());
                let seq_after = harness.event_seq();
                let counters_after = harness.authorization().testing_counters();
                let replayed = harness.owner(&request);
                assert!(replayed.accepted);
                assert_eq!(restored.result, replayed.result);
                assert_eq!(restored.topology_revision, replayed.topology_revision);
                assert_eq!(harness.event_seq(), seq_after);
                assert_eq!(harness.authorization().testing_counters(), counters_after);
                assert_eq!(
                    event_log_occupancy(&harness).0,
                    log_len_before + required_events
                );
                assert_eq!(event_log_occupancy(&harness).2, dropped_before);
                break;
            }
            failed_positions = failed_positions
                .checked_add(1)
                .expect("preparation allocation positions");
            let code = error_of(&restored);
            assert!(
                code == ErrorCode::ResourceExhausted || code == ErrorCode::PersistenceFailed,
                "unexpected restore preparation error {code:?}"
            );
            assert_eq!(fs::read(&confirmed).expect("saved confirmed"), disk_before);
            assert_eq!(harness.authorization().testing_selected(), selected_before);
            assert_eq!(harness.authorization().testing_counters(), counters_before);
            assert_eq!(harness.record_states(), states_before);
            assert_eq!(harness.event_seq(), seq_before);
            assert_eq!(
                harness.authorization().testing_outstanding_credits(),
                outstanding_before
            );
            assert!(harness.authorization().generation_is_open());
            assert!(!client_a.cancelled());
            assert!(!client_b.cancelled());
            k = k.checked_add(1).expect("next allocation position");
        }
        assert!(failed_positions > 0);
    }

    #[test]
    fn restore_event_seq_capacity_boundary_preserves_state() {
        let harness = Harness::new(Vec::new());
        let root = isolate(&harness);
        let client_a = harness.connect("pwsh");
        let client_b = harness.connect("pwsh");
        let save = harness.owner(&owner_request(&harness, 1, Action::LayoutSave(Empty {}), None));
        assert!(save.accepted);
        let confirmed = root.join("confirmed.json");
        let disk_before = fs::read(&confirmed).expect("saved confirmed");
        let selected_before = harness.authorization().testing_selected();
        let states_before = harness.record_states();
        harness.set_event_seq_to_max();
        let counters_before = harness.authorization().testing_counters();
        let outstanding_before = harness.authorization().testing_outstanding_credits();
        let restore = harness.owner(&owner_request(&harness,
            2,
            Action::LayoutRestore(Empty {}),
            Some(0),
        ));
        assert!(!restore.accepted);
        assert_eq!(error_of(&restore), ErrorCode::ResourceExhausted);
        assert_eq!(harness.event_seq(), crate::contract::MAX_SAFE_INTEGER);
        assert_eq!(fs::read(&confirmed).unwrap_or_default(), disk_before);
        assert_eq!(harness.authorization().testing_selected(), selected_before);
        assert_eq!(harness.authorization().testing_counters(), counters_before);
        assert_eq!(harness.record_states(), states_before);
        assert_eq!(
            harness.authorization().testing_outstanding_credits(),
            outstanding_before
        );
        assert!(harness.authorization().generation_is_open());
        assert!(!client_a.cancelled());
        assert!(!client_b.cancelled());
    }
}
