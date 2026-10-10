mod layout;
use crate::contract::ingress::{
    json_string, recovery_buffer_capacities, write_error_response, write_success_prefix,
    write_success_suffix, write_uuid_bytes, CanonicalValue, Measure, Output, Sink, WireCorrelation,
};
use crate::contract::{
    Action, ConnectionId, ConnectionState, Decision, ErrorCode, EventData, InstanceId,
    LiveConnectionState, MetadataEvent, NonEmpty, Nullable, OperationId, OperationName,
    OwnedCapacity, ProjectId, Request, Response, RootState, Scope, StringSet, Success, Timestamp,
    Version, MAX_MESSAGE_BYTES, MAX_SAFE_INTEGER, U,
};
use crate::host::admission::{
    AllocationAuthority, AllocationError, AllocationPool, CapacityCharge, ChargedValue, ChargedVec,
    ACTIVE_BYTES, RETAINED_BYTES,
    PUBLIC_WORKER_STACK_BYTES,
};
use crate::runtime::CompleteSessionQuiescence;
use crate::service::output as output_service;
use crate::service::artifact as artifact_service;
use crate::service::run as run_service;
use crate::service::workspace::{
    key_of, selected_if_visible, visible_rows, write_project_forget, write_project_list,
    write_project_open, write_project_select, OpenKind, OpenOutcome, SelectOutcome,
    WorkspaceService,
};
use crate::store::root_identity::{classify_path_syntax, observe_root, reobserve_state};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub trait CancelSignal: Send + Sync {
    fn cancel(&self);
}

#[derive(Clone)]
pub struct ConnectionLease {
    connection_key: [u8; 36],
    token: Arc<()>,
    live: Arc<AtomicBool>,
    send_gate: Arc<Mutex<()>>,
}

/// A one-stage right to begin reading the public authentication frame.
///
/// This type is intentionally neither `Clone` nor `Copy`. The public worker
/// consumes it when it enters the authentication read stage, and must acquire
/// a separate proof-send right before writing the server proof.
pub(crate) struct AuthenticationIoPermit {
    _private: (),
}

/// A one-stage right to write the server authentication proof.
pub(crate) struct ProofSendPermit {
    _private: (),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WorkerAdmissionError {
    Exhausted,
    State,
}

impl ConnectionLease {
    fn connection_key(&self) -> &[u8; 36] {
        &self.connection_key
    }

    #[cfg(debug_assertions)]
    pub(crate) fn connection_id(&self) -> ConnectionId {
        ConnectionId::new(
            std::str::from_utf8(&self.connection_key)
                .expect("connection keys are UUID text")
                .to_owned(),
        )
        .expect("connection keys are valid IDs")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) struct ReplaySlotKey(u64);

pub(crate) enum ReplayActor {
    Owner,
    Public(ConnectionLease),
}

pub(crate) struct ChargedProjectSet {
    project_keys: ChargedVec<[u8; 36]>,
}

impl ChargedProjectSet {
    pub(crate) fn from_project_set(
        authority: &AllocationAuthority,
        projects: &StringSet<ProjectId>,
    ) -> Result<Self, ReplayStorageError> {
        let bytes = projects
            .len()
            .checked_mul(std::mem::size_of::<[u8; 36]>())
            .ok_or(ReplayStorageError::Exhausted)?;
        let mut project_keys =
            ChargedVec::with_capacity(authority, AllocationPool::Retained, projects.len(), bytes)
                .map_err(|_| ReplayStorageError::Exhausted)?;
        for project in projects.iter() {
            project_keys
                .try_push(validated_key(project.as_str()))
                .map_err(|_| ReplayStorageError::Capacity)?;
        }
        let set = Self { project_keys };
        if !projects.iter().all(|project| set.contains(project)) {
            return Err(ReplayStorageError::Capacity);
        }
        Ok(set)
    }

    pub(crate) fn contains(&self, project: &ProjectId) -> bool {
        self.project_keys.contains(&validated_key(project.as_str()))
    }

    fn covered_by_current_grants(&self, granted: &[[u8; 36]]) -> bool {
        self.project_keys.iter().all(|key| granted.contains(key))
    }

    fn covered_by_pending_history(&self, granted: &[[u8; 36]], requested: &[[u8; 36]]) -> bool {
        self.project_keys
            .iter()
            .all(|key| granted.contains(key) || requested.contains(key))
    }

    fn keys(&self) -> &[[u8; 36]] {
        &self.project_keys
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SendCoverage {
    LiveLease,
    CurrentGrants,
}

pub(crate) enum SendPolicyTicket {
    Owner,
    Public {
        lease: ConnectionLease,
        project_ids: ChargedProjectSet,
        coverage: SendCoverage,
        field_scopes: ChargedVec<Scope>,
    },
}

impl SendPolicyTicket {
    pub(crate) fn owner() -> Self {
        Self::Owner
    }

    fn charged_scopes(
        authority: &AllocationAuthority,
        scopes: &[Scope],
    ) -> Result<ChargedVec<Scope>, ReplayStorageError> {
        let bytes = scopes
            .len()
            .checked_mul(std::mem::size_of::<Scope>())
            .ok_or(ReplayStorageError::Exhausted)?;
        let mut field_scopes =
            ChargedVec::with_capacity(authority, AllocationPool::Retained, scopes.len(), bytes)
                .map_err(|_| ReplayStorageError::Exhausted)?;
        for scope in scopes {
            field_scopes
                .try_push(*scope)
                .map_err(|_| ReplayStorageError::Capacity)?;
        }
        Ok(field_scopes)
    }

    pub(crate) fn public(
        authority: &AllocationAuthority,
        lease: ConnectionLease,
        project_ids: &StringSet<ProjectId>,
    ) -> Result<Self, ReplayStorageError> {
        Ok(Self::Public {
            lease,
            project_ids: ChargedProjectSet::from_project_set(authority, project_ids)?,
            coverage: SendCoverage::LiveLease,
            field_scopes: Self::charged_scopes(authority, &[])?,
        })
    }

    pub(crate) fn public_grants(
        authority: &AllocationAuthority,
        lease: ConnectionLease,
        project_ids: &StringSet<ProjectId>,
    ) -> Result<Self, ReplayStorageError> {
        Ok(Self::Public {
            lease,
            project_ids: ChargedProjectSet::from_project_set(authority, project_ids)?,
            coverage: SendCoverage::CurrentGrants,
            field_scopes: Self::charged_scopes(authority, &[])?,
        })
    }

    pub(crate) fn public_target(
        authority: &AllocationAuthority,
        lease: ConnectionLease,
        project_ids: &StringSet<ProjectId>,
        field_scopes: &[Scope],
    ) -> Result<Self, ReplayStorageError> {
        Ok(Self::Public {
            lease,
            project_ids: ChargedProjectSet::from_project_set(authority, project_ids)?,
            coverage: SendCoverage::CurrentGrants,
            field_scopes: Self::charged_scopes(authority, field_scopes)?,
        })
    }

    pub(crate) fn public_lease(
        authority: &AllocationAuthority,
        lease: ConnectionLease,
    ) -> Result<Self, ReplayStorageError> {
        Self::public(
            authority,
            lease,
            &StringSet::new(Vec::new()).map_err(|_| ReplayStorageError::Capacity)?,
        )
    }

    fn permits(&self, state: &State, caller_owner: bool, lease: Option<&ConnectionLease>) -> bool {
        if state.generation != GenerationState::Open {
            return false;
        }
        match self {
            Self::Owner => caller_owner,
            Self::Public {
                lease: stored,
                project_ids,
                coverage,
                field_scopes,
            } => {
                if caller_owner {
                    return false;
                }
                let Some(lease) = lease else {
                    return false;
                };
                if stored.connection_key() != lease.connection_key()
                    || !Arc::ptr_eq(&stored.token, &lease.token)
                    || !lease.live.load(Ordering::SeqCst)
                {
                    return false;
                }
                let Some(record) = connection(state, stored.connection_key()) else {
                    return false;
                };
                if !Arc::ptr_eq(&record.token, &lease.token) {
                    return false;
                }
                match coverage {
                    SendCoverage::LiveLease => {
                        matches!(
                            record.state,
                            RecordState::Unpaired | RecordState::Pending | RecordState::Granted
                        ) && project_ids.covered_by_pending_history(
                            &record.granted_project_ids,
                            &record.requested_project_ids,
                        )
                    }
                    SendCoverage::CurrentGrants => {
                        record.state == RecordState::Granted
                            && field_scopes
                                .iter()
                                .all(|scope| record.granted_scopes.contains(scope))
                            && project_ids.covered_by_current_grants(&record.granted_project_ids)
                            && project_ids.keys().iter().all(|key| {
                                project_from_key(key)
                                    .is_some_and(|id| state.workspace.contains(&id))
                            })
                    }
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ReplayCounters {
    pub(crate) topology_revision: u64,
    pub(crate) event_seq: u64,
}

enum ReplayOwnership {
    Recovery { connection_key: [u8; 36] },
    Effect,
}

enum ReplayPhase {
    Reserved,
    Preparing {
        operation_key: [u8; 36],
        actor: ReplayActor,
        ticket: SendPolicyTicket,
    },
    Done {
        operation_key: [u8; 36],
        actor: ReplayActor,
        counters: ReplayCounters,
        ticket: SendPolicyTicket,
    },
}

struct ReplaySlot {
    slot_key: ReplaySlotKey,
    ownership: ReplayOwnership,
    phase: ReplayPhase,
    canonical: ChargedVec<u8>,
    terminal: ChargedVec<u8>,
}

#[derive(Clone, Copy)]
struct ReplayIndexEntry {
    operation_key: [u8; 36],
    slot_key: ReplaySlotKey,
}

pub(crate) struct ReplayStorage {
    slots: ChargedVec<ReplaySlot>,
    index: ChargedVec<ReplayIndexEntry>,
    reserved_indexes: usize,
    next_slot_key: u64,
}

#[derive(Clone, Copy)]
pub(crate) struct RecoveryCredit {
    slot_key: ReplaySlotKey,
    connection_key: [u8; 36],
    consumed: bool,
}

pub(crate) struct EffectReservation {
    slot_key: ReplaySlotKey,
    consumed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ReplayStorageError {
    Exhausted,
    Conflict,
    InvalidReservation,
    Capacity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ReplayPhaseView {
    Preparing,
    Done,
}

pub(crate) struct ReplayRecordView<'a> {
    pub(crate) phase: ReplayPhaseView,
    pub(crate) actor: &'a ReplayActor,
    pub(crate) canonical: &'a [u8],
    pub(crate) terminal: &'a [u8],
    pub(crate) counters: Option<ReplayCounters>,
    pub(crate) ticket: Option<&'a SendPolicyTicket>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RecoveryRelease {
    ReleasedUnused,
    RetainedDone,
}

fn validated_key(value: &str) -> [u8; 36] {
    value
        .as_bytes()
        .try_into()
        .expect("validated contract IDs are 36-byte UUIDs")
}

impl ReplayStorage {
    fn new(authority: &AllocationAuthority) -> Result<Self, ReplayStorageError> {
        Ok(Self {
            slots: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .map_err(|_| ReplayStorageError::Exhausted)?,
            index: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .map_err(|_| ReplayStorageError::Exhausted)?,
            reserved_indexes: 0,
            next_slot_key: 1,
        })
    }

    pub(crate) fn reserve_recovery(
        &mut self,
        authority: &AllocationAuthority,
        connection_key: &[u8; 36],
    ) -> Result<RecoveryCredit, ReplayStorageError> {
        let connection_key = *connection_key;
        let capacities = recovery_buffer_capacities().map_err(|_| ReplayStorageError::Exhausted)?;
        let slot_key = self.reserve_slot(
            authority,
            AllocationPool::ActivePublic,
            ReplayOwnership::Recovery { connection_key },
            capacities.canonical,
            capacities.terminal,
        )?;
        Ok(RecoveryCredit {
            slot_key,
            connection_key,
            consumed: false,
        })
    }

    pub(crate) fn reserve_effect(
        &mut self,
        authority: &AllocationAuthority,
        transient_pool: AllocationPool,
        canonical_capacity: usize,
        terminal_capacity: usize,
    ) -> Result<EffectReservation, ReplayStorageError> {
        let slot_key = self.reserve_slot(
            authority,
            transient_pool,
            ReplayOwnership::Effect,
            canonical_capacity,
            terminal_capacity,
        )?;
        Ok(EffectReservation {
            slot_key,
            consumed: false,
        })
    }

    fn reserve_slot(
        &mut self,
        authority: &AllocationAuthority,
        transient_pool: AllocationPool,
        ownership: ReplayOwnership,
        canonical_capacity: usize,
        terminal_capacity: usize,
    ) -> Result<ReplaySlotKey, ReplayStorageError> {
        if transient_pool == AllocationPool::Retained {
            return Err(ReplayStorageError::Capacity);
        }
        let slot_key = ReplaySlotKey(self.next_slot_key);
        let next_slot_key = self
            .next_slot_key
            .checked_add(1)
            .ok_or(ReplayStorageError::Exhausted)?;
        let canonical = ChargedVec::with_capacity(
            authority,
            AllocationPool::Retained,
            canonical_capacity,
            canonical_capacity,
        )
        .map_err(|_| ReplayStorageError::Exhausted)?;
        let terminal = ChargedVec::with_capacity(
            authority,
            AllocationPool::Retained,
            terminal_capacity,
            terminal_capacity,
        )
        .map_err(|_| ReplayStorageError::Exhausted)?;
        self.ensure_table_capacity(authority, transient_pool)?;
        self.slots
            .try_push(ReplaySlot {
                slot_key,
                ownership,
                phase: ReplayPhase::Reserved,
                canonical,
                terminal,
            })
            .map_err(|_| ReplayStorageError::Capacity)?;
        self.reserved_indexes += 1;
        self.next_slot_key = next_slot_key;
        Ok(slot_key)
    }

    fn ensure_table_capacity(
        &mut self,
        authority: &AllocationAuthority,
        transient_pool: AllocationPool,
    ) -> Result<(), ReplayStorageError> {
        let index_needed = self
            .index
            .len()
            .checked_add(self.reserved_indexes)
            .and_then(|count| count.checked_add(1))
            .ok_or(ReplayStorageError::Exhausted)?;
        if index_needed > self.index.capacity_elements() {
            let bytes = index_needed
                .checked_mul(std::mem::size_of::<ReplayIndexEntry>())
                .ok_or(ReplayStorageError::Exhausted)?;
            self.index
                .try_grow_retained(authority, transient_pool, index_needed, bytes)
                .map_err(|_| ReplayStorageError::Exhausted)?;
        }

        let slots_needed = self
            .slots
            .len()
            .checked_add(1)
            .ok_or(ReplayStorageError::Exhausted)?;
        if slots_needed > self.slots.capacity_elements() {
            let bytes = slots_needed
                .checked_mul(std::mem::size_of::<ReplaySlot>())
                .ok_or(ReplayStorageError::Exhausted)?;
            self.slots
                .try_grow_retained(authority, transient_pool, slots_needed, bytes)
                .map_err(|_| ReplayStorageError::Exhausted)?;
        }
        Ok(())
    }

    pub(crate) fn begin_recovery(
        &mut self,
        credit: &mut RecoveryCredit,
        operation_id: &OperationId,
        canonical: &[u8],
    ) -> Result<(), ReplayStorageError> {
        if credit.consumed {
            return Err(ReplayStorageError::InvalidReservation);
        }
        let slot = self
            .slots
            .iter()
            .find(|slot| slot.slot_key == credit.slot_key)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        match &slot.ownership {
            ReplayOwnership::Recovery { connection_key }
                if connection_key == &credit.connection_key => {}
            _ => return Err(ReplayStorageError::InvalidReservation),
        }
        self.begin_slot(
            credit.slot_key,
            operation_id,
            ReplayActor::Owner,
            SendPolicyTicket::owner(),
            canonical,
        )?;
        credit.consumed = true;
        Ok(())
    }

    pub(crate) fn begin_effect(
        &mut self,
        reservation: &mut EffectReservation,
        operation_id: &OperationId,
        actor: ReplayActor,
        ticket: SendPolicyTicket,
        canonical: &[u8],
    ) -> Result<(), ReplayStorageError> {
        if reservation.consumed {
            return Err(ReplayStorageError::InvalidReservation);
        }
        let slot = self
            .slots
            .iter()
            .find(|slot| slot.slot_key == reservation.slot_key)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        if !matches!(slot.ownership, ReplayOwnership::Effect) {
            return Err(ReplayStorageError::InvalidReservation);
        }
        self.begin_slot(reservation.slot_key, operation_id, actor, ticket, canonical)?;
        reservation.consumed = true;
        Ok(())
    }

    fn begin_slot(
        &mut self,
        slot_key: ReplaySlotKey,
        operation_id: &OperationId,
        actor: ReplayActor,
        ticket: SendPolicyTicket,
        canonical: &[u8],
    ) -> Result<(), ReplayStorageError> {
        let operation_key = validated_key(operation_id.as_str());
        let insert_at = match self
            .index
            .binary_search_by_key(&operation_key, |entry| entry.operation_key)
        {
            Ok(_) => return Err(ReplayStorageError::Conflict),
            Err(index) => index,
        };
        let slot_position = self
            .slots
            .iter()
            .position(|slot| slot.slot_key == slot_key)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        let slot = &self.slots[slot_position];
        if !matches!(slot.phase, ReplayPhase::Reserved)
            || !slot.canonical.is_empty()
            || canonical.len() > slot.canonical.capacity_elements()
            || self.reserved_indexes == 0
            || self.index.len() == self.index.capacity_elements()
        {
            return Err(ReplayStorageError::Capacity);
        }

        self.slots[slot_position]
            .canonical
            .try_extend_from_slice(canonical)
            .map_err(|_| ReplayStorageError::Capacity)?;
        if self
            .index
            .try_insert(
                insert_at,
                ReplayIndexEntry {
                    operation_key,
                    slot_key,
                },
            )
            .is_err()
        {
            self.slots[slot_position].canonical.clear();
            return Err(ReplayStorageError::Capacity);
        }
        self.reserved_indexes -= 1;
        self.slots[slot_position].phase = ReplayPhase::Preparing {
            operation_key,
            actor,
            ticket,
        };
        Ok(())
    }

    pub(crate) fn finish_recovery(
        &mut self,
        operation_id: &OperationId,
        terminal: &[u8],
        counters: ReplayCounters,
    ) -> Result<(), ReplayStorageError> {
        self.finish_slot(operation_id, terminal, counters, true, true)
    }

    pub(crate) fn finish_effect(
        &mut self,
        operation_id: &OperationId,
        terminal: &[u8],
        counters: ReplayCounters,
    ) -> Result<(), ReplayStorageError> {
        self.finish_slot(operation_id, terminal, counters, false, true)
    }

    pub(crate) fn finish_native_data_effect(
        &mut self,
        operation_id: &OperationId,
        terminal: &[u8],
        counters: ReplayCounters,
    ) -> Result<(), ReplayStorageError> {
        self.finish_slot(operation_id, terminal, counters, false, false)
    }

    fn finish_slot(
        &mut self,
        operation_id: &OperationId,
        terminal: &[u8],
        counters: ReplayCounters,
        recovery: bool,
        compact: bool,
    ) -> Result<(), ReplayStorageError> {
        let operation_key = validated_key(operation_id.as_str());
        let index_position = self
            .index
            .binary_search_by_key(&operation_key, |entry| entry.operation_key)
            .map_err(|_| ReplayStorageError::InvalidReservation)?;
        let slot_key = self.index[index_position].slot_key;
        let slot_position = self
            .slots
            .iter()
            .position(|slot| slot.slot_key == slot_key)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        let slot = &mut self.slots[slot_position];
        let ownership_matches = matches!(
            (&slot.ownership, recovery),
            (ReplayOwnership::Recovery { .. }, true) | (ReplayOwnership::Effect, false)
        );
        let phase_matches = matches!(
            &slot.phase,
            ReplayPhase::Preparing {
                operation_key: preparing_key,
                ..
            } if preparing_key == &operation_key
        );
        if !ownership_matches
            || !phase_matches
            || !slot.terminal.is_empty()
            || terminal.len() > slot.terminal.capacity_elements()
        {
            return Err(ReplayStorageError::InvalidReservation);
        }
        slot.terminal
            .try_extend_from_slice(terminal)
            .map_err(|_| ReplayStorageError::Capacity)?;
        let ReplayPhase::Preparing { actor, ticket, .. } =
            std::mem::replace(&mut slot.phase, ReplayPhase::Reserved)
        else {
            unreachable!("preparing phase was validated")
        };
        slot.phase = ReplayPhase::Done {
            operation_key,
            actor,
            counters,
            ticket,
        };
        // Once Done is sealed, unused reservation capacity is optional. Failure
        // must preserve the exact terminal reply and never undo its effect.
        if compact {
            let _ = slot.terminal.try_compact_retained(AllocationPool::ActiveOwner);
        }
        Ok(())
    }

    pub(crate) fn lookup(&self, operation_id: &OperationId) -> Option<ReplayRecordView<'_>> {
        let operation_key = validated_key(operation_id.as_str());
        let index_position = self
            .index
            .binary_search_by_key(&operation_key, |entry| entry.operation_key)
            .ok()?;
        let slot_key = self.index[index_position].slot_key;
        let slot = self.slots.iter().find(|slot| slot.slot_key == slot_key)?;
        match &slot.phase {
            ReplayPhase::Reserved => None,
            ReplayPhase::Preparing { actor, ticket, .. } => Some(ReplayRecordView {
                phase: ReplayPhaseView::Preparing,
                actor,
                canonical: &slot.canonical,
                terminal: &slot.terminal,
                counters: None,
                ticket: Some(ticket),
            }),
            ReplayPhase::Done {
                actor,
                counters,
                ticket,
                ..
            } => Some(ReplayRecordView {
                phase: ReplayPhaseView::Done,
                actor,
                canonical: &slot.canonical,
                terminal: &slot.terminal,
                counters: Some(*counters),
                ticket: Some(ticket),
            }),
        }
    }

    pub(crate) fn release_unspawned(
        &mut self,
        credit: &RecoveryCredit,
    ) -> Result<(), ReplayStorageError> {
        if credit.consumed {
            return Err(ReplayStorageError::InvalidReservation);
        }
        self.remove_reserved_recovery(&credit)
    }

    pub(crate) fn release_unused_after_join(
        &mut self,
        credit: &RecoveryCredit,
    ) -> Result<RecoveryRelease, ReplayStorageError> {
        if !credit.consumed {
            self.remove_reserved_recovery(&credit)?;
            return Ok(RecoveryRelease::ReleasedUnused);
        }
        let slot = self
            .slots
            .iter()
            .find(|slot| slot.slot_key == credit.slot_key)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        let recovery_matches = matches!(
            &slot.ownership,
            ReplayOwnership::Recovery { connection_key }
                if connection_key == &credit.connection_key
        );
        if recovery_matches && matches!(slot.phase, ReplayPhase::Done { .. }) {
            Ok(RecoveryRelease::RetainedDone)
        } else {
            Err(ReplayStorageError::InvalidReservation)
        }
    }

    pub(crate) fn cancel_effect(
        &mut self,
        reservation: &EffectReservation,
    ) -> Result<(), ReplayStorageError> {
        if reservation.consumed {
            return Err(ReplayStorageError::InvalidReservation);
        }
        let position = self
            .slots
            .iter()
            .position(|slot| {
                slot.slot_key == reservation.slot_key
                    && matches!(slot.ownership, ReplayOwnership::Effect)
                    && matches!(slot.phase, ReplayPhase::Reserved)
            })
            .ok_or(ReplayStorageError::InvalidReservation)?;
        self.slots
            .remove(position)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        self.reserved_indexes = self
            .reserved_indexes
            .checked_sub(1)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        Ok(())
    }

    fn remove_reserved_recovery(
        &mut self,
        credit: &RecoveryCredit,
    ) -> Result<(), ReplayStorageError> {
        let position = self
            .slots
            .iter()
            .position(|slot| {
                slot.slot_key == credit.slot_key
                    && matches!(
                        &slot.ownership,
                        ReplayOwnership::Recovery { connection_key }
                            if connection_key == &credit.connection_key
                    )
                    && matches!(slot.phase, ReplayPhase::Reserved)
            })
            .ok_or(ReplayStorageError::InvalidReservation)?;
        self.slots
            .remove(position)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        self.reserved_indexes = self
            .reserved_indexes
            .checked_sub(1)
            .ok_or(ReplayStorageError::InvalidReservation)?;
        Ok(())
    }
}

const CREDIT_LIVE: u8 = 0;
const CREDIT_ABANDONED: u8 = 1;
const CREDIT_CONSUMED: u8 = 2;

struct CreditCell {
    state: AtomicU8,
}

struct CreditRecord {
    id: u64,
    cell: Arc<CreditCell>,
    _charge: Option<CapacityCharge>,
}

/// Once-token for one EventAccounting reservation. Drop never locks, waits,
/// publishes, or touches RuntimeService/RunControl; it only CAS Live->Abandoned.
pub(crate) struct EventCredit {
    id: u64,
    cell: Arc<CreditCell>,
    consumed: bool,
}

impl EventCredit {
    fn consume(&mut self) -> bool {
        if self.consumed {
            debug_assert!(false, "EventCredit double-consume");
            return false;
        }
        self.consumed = true;
        self.cell
            .state
            .compare_exchange(
                CREDIT_LIVE,
                CREDIT_CONSUMED,
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .is_ok()
    }
}

impl Drop for EventCredit {
    fn drop(&mut self) {
        if self.consumed {
            return;
        }
        let _ = self.cell.state.compare_exchange(
            CREDIT_LIVE,
            CREDIT_ABANDONED,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
    }
}

struct WaiterCell {
    signaled: AtomicBool,
}

#[cfg(debug_assertions)]
thread_local! {
    static PENDING_WAIT_OBSERVE: std::cell::Cell<Option<(u64, Option<[u8; 36]>)>> =
        const { std::cell::Cell::new(None) };
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone)]
pub struct TestingEventWaiter {
    pub after_event_seq: u64,
    pub connection_id: Option<String>,
}

struct WaiterRecord {
    cell: Arc<WaiterCell>,
    mutex: Arc<Mutex<()>>,
    condvar: Arc<Condvar>,
    _charge: Option<CapacityCharge>,
    #[cfg(debug_assertions)]
    after_event_seq: u64,
    #[cfg(debug_assertions)]
    connection_key: Option<[u8; 36]>,
}

pub(crate) struct EventWaiter {
    cell: Arc<WaiterCell>,
    mutex: Arc<Mutex<()>>,
    condvar: Arc<Condvar>,
}

impl EventWaiter {
    pub(crate) fn is_signaled(&self) -> bool {
        self.cell.signaled.load(Ordering::SeqCst)
    }

    pub(crate) fn reset(&self) {
        self.cell.signaled.store(false, Ordering::SeqCst);
    }

    pub(crate) fn wait_timeout(&self, timeout: Duration) -> bool {
        if self.cell.signaled.load(Ordering::SeqCst) {
            return true;
        }
        let Ok(mut guard) = self.mutex.lock() else {
            return self.cell.signaled.load(Ordering::SeqCst);
        };
        let deadline = Instant::now()
            .checked_add(timeout)
            .unwrap_or_else(Instant::now);
        while !self.cell.signaled.load(Ordering::SeqCst) {
            #[cfg(debug_assertions)]
            wait_product_phase(ProductPhase::EventWait, None);
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            match self
                .condvar
                .wait_timeout(guard, deadline.saturating_duration_since(now))
            {
                Ok((next, timed)) => {
                    guard = next;
                    if timed.timed_out() {
                        break;
                    }
                }
                Err(_) => return self.cell.signaled.load(Ordering::SeqCst),
            }
        }
        self.cell.signaled.load(Ordering::SeqCst)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn wait_signaled_timeout(&self, timeout: Duration) -> bool {
        self.wait_timeout(timeout)
    }
}

struct ExitLatch {
    run_key: [u8; 36],
    published_seq: u64,
    _charge: Option<CapacityCharge>,
}

struct EventAccounting {
    committed_seq: u64,
    outstanding_credits: u64,
    log: ChargedVec<MetadataEvent>,
    dropped_through: u64,
    waiters: ChargedVec<WaiterRecord>,
    credits: ChargedVec<CreditRecord>,
    next_credit_id: u64,
    exit_latches: ChargedVec<ExitLatch>,
    exit_latch_charge: u64,
    test_fail_append: bool,
}

fn grow_retained_vec<T>(
    values: &mut ChargedVec<T>,
    authority: &AllocationAuthority,
) -> Result<(), ErrorCode> {
    let needed = values
        .len()
        .checked_add(1)
        .ok_or(ErrorCode::ResourceExhausted)?;
    if needed <= values.capacity_elements() {
        return Ok(());
    }
    let bytes = needed
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(ErrorCode::ResourceExhausted)?;
    values
        .try_grow_retained(authority, AllocationPool::ActiveOwner, needed, bytes)
        .map_err(|_| ErrorCode::ResourceExhausted)
}

impl EventAccounting {
    fn new(authority: &AllocationAuthority) -> Self {
        Self {
            committed_seq: 0,
            outstanding_credits: 0,
            log: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .expect("zero-capacity event log initializes without allocation"),
            dropped_through: 0,
            waiters: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .expect("zero-capacity waiters initialize without allocation"),
            credits: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .expect("zero-capacity credits initialize without allocation"),
            next_credit_id: 1,
            exit_latches: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)
                .expect("zero-capacity exit latches initialize without allocation"),
            exit_latch_charge: 0,
            test_fail_append: false,
        }
    }

    fn committed_seq(&self) -> u64 {
        self.committed_seq
    }

    fn outstanding_credits(&self) -> u64 {
        self.outstanding_credits
    }

    fn dropped_through(&self) -> u64 {
        self.dropped_through
    }

    fn log_len(&self) -> usize {
        self.log.len()
    }

    fn exit_latch_charge(&self) -> u64 {
        self.exit_latch_charge
    }

    fn snapshot_for_wait(&self) -> (u64, u64, &[MetadataEvent]) {
        (self.committed_seq, self.dropped_through, &self.log)
    }

    fn reap_abandoned(&mut self) {
        let mut index = 0;
        while index < self.credits.len() {
            if self.credits[index].cell.state.load(Ordering::SeqCst) == CREDIT_ABANDONED {
                self.outstanding_credits = self.outstanding_credits.saturating_sub(1);
                self.credits.remove(index);
            } else {
                index += 1;
            }
        }
    }

    fn can_reserve(&mut self, n: u64) -> bool {
        self.reap_abandoned();
        self.committed_seq
            .checked_add(self.outstanding_credits)
            .and_then(|sum| sum.checked_add(n))
            .is_some_and(|sum| sum <= MAX_SAFE_INTEGER)
    }

    fn try_reserve(
        &mut self,
        authority: &AllocationAuthority,
        n: u64,
    ) -> Result<EventCredit, ErrorCode> {
        if n != 1 || !self.can_reserve(n) {
            return Err(ErrorCode::ResourceExhausted);
        }
        grow_retained_vec(&mut self.credits, authority)?;
        let charge = authority
            .claim(
                AllocationPool::Retained,
                std::mem::size_of::<CreditCell>().max(1),
            )
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        let next_credit_id = self
            .next_credit_id
            .checked_add(1)
            .ok_or(ErrorCode::ResourceExhausted)?;
        let cell = Arc::new(CreditCell {
            state: AtomicU8::new(CREDIT_LIVE),
        });
        let id = self.next_credit_id;
        self.credits
            .try_push(CreditRecord {
                id,
                cell: Arc::clone(&cell),
                _charge: Some(charge),
            })
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        self.next_credit_id = next_credit_id;
        self.outstanding_credits += 1;
        Ok(EventCredit {
            id,
            cell,
            consumed: false,
        })
    }

    fn remove_credit_record(&mut self, id: u64) {
        if let Some(index) = self.credits.iter().position(|record| record.id == id) {
            self.credits.remove(index);
        }
    }

    fn publish(
        &mut self,
        authority: &AllocationAuthority,
        mut credit: EventCredit,
        data: EventData,
        observed_at: Timestamp,
    ) -> u64 {
        self.reap_abandoned();
        if !credit.consume() {
            return self.committed_seq;
        }
        self.remove_credit_record(credit.id);
        self.outstanding_credits = self.outstanding_credits.saturating_sub(1);
        debug_assert!(self.committed_seq < MAX_SAFE_INTEGER);
        self.committed_seq += 1;
        let event_seq = U::new(self.committed_seq).expect("reserved seq fits U");
        let event = MetadataEvent {
            event_seq,
            observed_at,
            data,
        };
        if self.test_fail_append || self.try_append(authority, event).is_err() {
            self.test_fail_append = false;
            self.dropped_through = self.committed_seq;
        }
        self.wake_all();
        self.committed_seq
    }

    fn try_append(
        &mut self,
        authority: &AllocationAuthority,
        event: MetadataEvent,
    ) -> Result<(), ErrorCode> {
        grow_retained_vec(&mut self.log, authority)?;
        self.log
            .try_push(event)
            .map_err(|_| ErrorCode::ResourceExhausted)
    }

    fn release(&mut self, mut credit: EventCredit) {
        self.reap_abandoned();
        if !credit.consume() {
            return;
        }
        self.remove_credit_record(credit.id);
        self.outstanding_credits = self.outstanding_credits.saturating_sub(1);
    }

    fn wake_all(&mut self) {
        for waiter in self.waiters.iter() {
            let _guard = waiter
                .mutex
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            waiter.cell.signaled.store(true, Ordering::SeqCst);
            waiter.condvar.notify_all();
        }
    }

    fn register_waiter(
        &mut self,
        authority: &AllocationAuthority,
    ) -> Result<EventWaiter, ErrorCode> {
        self.reap_abandoned();
        grow_retained_vec(&mut self.waiters, authority)?;
        let charge = authority
            .claim(
                AllocationPool::Retained,
                std::mem::size_of::<WaiterCell>().max(1),
            )
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        let cell = Arc::new(WaiterCell {
            signaled: AtomicBool::new(false),
        });
        let mutex = Arc::new(Mutex::new(()));
        let condvar = Arc::new(Condvar::new());
        #[cfg(debug_assertions)]
        let (after_event_seq, connection_key) = PENDING_WAIT_OBSERVE
            .with(|cell| cell.get())
            .ok_or(ErrorCode::RuntimeFailed)?;
        self.waiters
            .try_push(WaiterRecord {
                cell: Arc::clone(&cell),
                mutex: Arc::clone(&mutex),
                condvar: Arc::clone(&condvar),
                _charge: Some(charge),
                #[cfg(debug_assertions)]
                after_event_seq,
                #[cfg(debug_assertions)]
                connection_key,
            })
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        Ok(EventWaiter {
            cell,
            mutex,
            condvar,
        })
    }

    fn unregister_waiter(&mut self, waiter: &EventWaiter) {
        if let Some(index) = self
            .waiters
            .iter()
            .position(|record| Arc::ptr_eq(&record.cell, &waiter.cell))
        {
            self.waiters.remove(index);
        }
    }

    #[cfg(debug_assertions)]
    fn waiter_snapshot(&self) -> Vec<TestingEventWaiter> {
        self.waiters
            .iter()
            .map(|record| TestingEventWaiter {
                after_event_seq: record.after_event_seq,
                connection_id: record.connection_key.and_then(|key| {
                    std::str::from_utf8(&key).ok().map(str::to_owned)
                }),
            })
            .collect()
    }

    fn has_exit_latch(&self, run_id: &crate::contract::RunId) -> bool {
        let key = validated_key(run_id.as_str());
        self.exit_latches.iter().any(|latch| latch.run_key == key)
    }

    fn insert_exit_latch(
        &mut self,
        authority: &AllocationAuthority,
        run_id: &crate::contract::RunId,
        published_seq: u64,
    ) -> Result<(), ErrorCode> {
        if self.has_exit_latch(run_id) {
            return Ok(());
        }
        grow_retained_vec(&mut self.exit_latches, authority)?;
        let charge = authority
            .claim(
                AllocationPool::Retained,
                std::mem::size_of::<ExitLatch>().max(1),
            )
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        self.exit_latches
            .try_push(ExitLatch {
                run_key: validated_key(run_id.as_str()),
                published_seq,
                _charge: Some(charge),
            })
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        self.exit_latch_charge = self.exit_latch_charge.saturating_add(1);
        Ok(())
    }

    fn preclaim_exit_latch(
        &mut self,
        authority: &AllocationAuthority,
        run_id: &crate::contract::RunId,
    ) -> Result<CapacityCharge, ErrorCode> {
        if self.has_exit_latch(run_id) {
            return Err(ErrorCode::OperationConflict);
        }
        grow_retained_vec(&mut self.exit_latches, authority)?;
        authority
            .claim(
                AllocationPool::Retained,
                std::mem::size_of::<ExitLatch>().max(1),
            )
            .map_err(|_| ErrorCode::ResourceExhausted)
    }

    fn commit_preclaimed_latch(
        &mut self,
        run_id: &crate::contract::RunId,
        published_seq: u64,
        charge: CapacityCharge,
    ) {
        if self.has_exit_latch(run_id) {
            drop(charge);
            return;
        }
        self.exit_latches
            .try_push(ExitLatch {
                run_key: validated_key(run_id.as_str()),
                published_seq,
                _charge: Some(charge),
            })
            .expect("exit latch slot was preclaimed");
        self.exit_latch_charge = self.exit_latch_charge.saturating_add(1);
    }

    fn remove_run_latch(&mut self, run_id: &crate::contract::RunId) {
        let key = validated_key(run_id.as_str());
        if let Some(index) = self
            .exit_latches
            .iter()
            .position(|latch| latch.run_key == key)
        {
            self.exit_latches.remove(index);
            self.exit_latch_charge = self.exit_latch_charge.saturating_sub(1);
        }
    }

    #[cfg(debug_assertions)]
    fn testing_set_committed_seq(&mut self, seq: u64) {
        self.reap_abandoned();
        self.committed_seq = seq.min(MAX_SAFE_INTEGER);
    }

    #[cfg(debug_assertions)]
    fn testing_fail_next_append(&mut self) {
        self.test_fail_append = true;
    }
}

fn now_or_epoch() -> Timestamp {
    crate::runtime::session::now_timestamp().unwrap_or_else(|| {
        Timestamp::new("1970-01-01T00:00:00.000Z").expect("epoch")
    })
}

fn connection_id_of(key: &[u8; 36]) -> Option<ConnectionId> {
    ConnectionId::new(std::str::from_utf8(key).ok()?.to_owned()).ok()
}

fn topology_revision_u(state: &State) -> U {
    U::new(state.topology_revision).expect("topology revision fits U")
}

fn publish_connection_state(
    allocations: &AllocationAuthority,
    state: &mut State,
    key: &[u8; 36],
    connection_state: ConnectionState,
    credit: EventCredit,
) {
    let Some(connection_id) = connection_id_of(key) else {
        state.events.release(credit);
        return;
    };
    state.events.publish(
        allocations,
        credit,
        EventData::ConnectionStateChanged {
            connection_id,
            state: connection_state,
        },
        now_or_epoch(),
    );
    if connection_state == ConnectionState::Revoked {
        if let Some(record) = connection_mut(state, key) {
            record.revoked_published = true;
        }
    }
}

fn publish_revoked_if_needed(
    allocations: &AllocationAuthority,
    state: &mut State,
    key: &[u8; 36],
) {
    if connection(state, key).is_some_and(|record| record.revoked_published) {
        return;
    }
    let Ok(credit) = state.events.try_reserve(allocations, 1) else {
        return;
    };
    publish_connection_state(
        allocations,
        state,
        key,
        ConnectionState::Revoked,
        credit,
    );
}

fn publish_topology_change(
    allocations: &AllocationAuthority,
    state: &mut State,
    credit: EventCredit,
    project_id: Option<ProjectId>,
    pane_id: Option<crate::contract::PaneId>,
) {
    state.events.publish(
        allocations,
        credit,
        EventData::TopologyChanged {
            topology_revision: topology_revision_u(state),
            project_id: Nullable(project_id),
            pane_id: Nullable(pane_id),
        },
        now_or_epoch(),
    );
}

fn pane_id_for_run(state: &State, run_id: &crate::contract::RunId) -> Option<crate::contract::PaneId> {
    state.workspace.projects().iter().find_map(|project| {
        project.panes.panes.iter().find_map(|pane| {
            pane.current_run
                .as_ref()
                .filter(|run| run.as_str() == run_id.as_str())
                .map(|_| pane.id.clone())
                .or_else(|| {
                    pane.previous_runs
                        .iter()
                        .any(|run| run.as_str() == run_id.as_str())
                        .then(|| pane.id.clone())
                })
        })
    })
}

fn try_publish_exit(
    allocations: &AllocationAuthority,
    state: &mut State,
    run_id: &crate::contract::RunId,
) -> Option<u64> {
    if state.events.has_exit_latch(run_id) || !state.runtime.has_session(run_id) {
        return None;
    }
    let pane_id = pane_id_for_run(state, run_id)?;
    let latch_charge = state.events.preclaim_exit_latch(allocations, run_id).ok()?;
    let credit = match state.events.try_reserve(allocations, 1) {
        Ok(credit) => credit,
        Err(_) => {
            drop(latch_charge);
            return None;
        }
    };
    let (process, work, code, current) = state.runtime.observation(run_id).unwrap_or((
        crate::contract::Process::Exited,
        crate::contract::Work::Unknown,
        None,
        false,
    ));
    let seq = state.events.publish(
        allocations,
        credit,
        EventData::RunStateChanged {
            run: live_observation(run_id.clone(), pane_id, process, work, code, current),
        },
        now_or_epoch(),
    );
    state
        .events
        .commit_preclaimed_latch(run_id, seq, latch_charge);
    Some(seq)
}

fn publish_exit_from_callback(shared: &AuthShared, run_id: crate::contract::RunId) {
    let mut state = match shared.inner.lock() {
        Ok(state) => state,
        Err(_) => return,
    };
    let _ = try_publish_exit(&shared.allocations, &mut state, &run_id);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RecordState {
    Authenticating,
    Unpaired,
    Pending,
    Granted,
    Closing,
    Finished,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OutboundPhase {
    Idle,
    Queued,
    Writing,
    Refused,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum GenerationState {
    Open,
    Closing,
    Failed,
}

enum WorkerOwnership {
    Fixture,
    AwaitingHandle,
    Published(JoinHandle<()>),
    Joining,
}

struct ConnectionIndexEntry {
    connection_key: [u8; 36],
    slot: usize,
}

struct ConnectionRecord {
    connection_key: [u8; 36],
    token: Arc<()>,
    live: Arc<AtomicBool>,
    send_gate: Arc<Mutex<()>>,
    executable_name: Option<ChargedValue<NonEmpty>>,
    observation: ObservationSlot,
    requested_project_ids: ChargedVec<[u8; 36]>,
    requested_scopes: ChargedVec<Scope>,
    granted_project_ids: ChargedVec<[u8; 36]>,
    granted_scopes: ChargedVec<Scope>,
    state: RecordState,
    revoked_published: bool,
    cancel: Arc<dyn CancelSignal>,
    cancel_signaled: bool,
    worker: WorkerOwnership,
    recovery_credit: RecoveryCredit,
    _stack_charge: Option<CapacityCharge>,
    outbound_phase: OutboundPhase,
    outbound_keys: ChargedVec<[u8; 36]>,
    inflight: ChargedVec<InflightTicket>,
}

#[derive(Clone, Copy)]
struct InflightTicket {
    run_key: [u8; 36],
    ticket: crate::runtime::RunDataTicket,
}

type GenerationCancel = (Arc<dyn CancelSignal>, Arc<Mutex<()>>);

struct State {
    generation: GenerationState,
    // Stop reserves new work without revoking existing leases or reply permits.
    stop_reserved: Option<[u8; 36]>,
    events: EventAccounting,
    topology_revision: u64,
    workspace: WorkspaceService,
    artifacts: artifact_service::ArtifactRegistry,
    connections: ChargedVec<ConnectionRecord>,
    connection_index: ChargedVec<ConnectionIndexEntry>,
    cancel_drain: ChargedVec<GenerationCancel>,
    replay: ReplayStorage,
    owner_observation: ObservationSlot,
    runtime: std::sync::Arc<crate::runtime::RuntimeService>,
    layout: crate::store::layout::LayoutStore,
    #[cfg(debug_assertions)]
    registration_fail_key: Option<[u8; 36]>,
    #[cfg(debug_assertions)]
    testing_spawn_executable: Option<String>,
    #[cfg(debug_assertions)]
    testing_spawn_prepared_hook: Option<Arc<dyn Fn(&crate::contract::RunId) + Send + Sync>>,
    #[cfg(debug_assertions)]
    testing_spawn_counts: (u64, u64),
    #[cfg(debug_assertions)]
    testing_fail_artifact_response_write: bool,
}

impl State {
    fn event_seq(&self) -> u64 {
        self.events.committed_seq()
    }
}

pub(crate) struct ObservationHold {
    operation_key: [u8; 36],
    owner: bool,
    connection_key: Option<[u8; 36]>,
}

pub(crate) struct ClientDispatch {
    pub(crate) observation: Option<ObservationHold>,
}

pub(crate) struct OwnerDispatch {
    cancellation: Option<(Arc<dyn CancelSignal>, Arc<Mutex<()>>)>,
    forget_drains: Option<ChargedVec<GenerationCancel>>,
    pub(crate) observation: Option<ObservationHold>,
    pub(crate) stop_after_reply: bool,
}

struct ObservationSlot {
    operation_key: Option<[u8; 36]>,
    actor_owner: bool,
    public_connection_key: Option<[u8; 36]>,
    canonical: ChargedVec<u8>,
    topology: u64,
}

impl ObservationSlot {
    fn vacant(
        allocations: &AllocationAuthority,
        pool: AllocationPool,
        bytes: usize,
    ) -> Result<Self, ReplayStorageError> {
        Ok(Self {
            operation_key: None,
            actor_owner: false,
            public_connection_key: None,
            canonical: ChargedVec::with_capacity(allocations, pool, bytes, bytes)
                .map_err(|_| ReplayStorageError::Exhausted)?,
            topology: 0,
        })
    }

    fn occupy(
        &mut self,
        operation_key: [u8; 36],
        actor_owner: bool,
        public_connection_key: Option<[u8; 36]>,
        canonical: &[u8],
        topology: u64,
    ) -> Result<(), ReplayStorageError> {
        if self.operation_key.is_some() {
            return Err(ReplayStorageError::Conflict);
        }
        self.canonical.clear();
        self.canonical
            .try_extend_from_slice(canonical)
            .map_err(|_| ReplayStorageError::Exhausted)?;
        self.operation_key = Some(operation_key);
        self.actor_owner = actor_owner;
        self.public_connection_key = public_connection_key;
        self.topology = topology;
        Ok(())
    }

    fn release(&mut self) {
        self.operation_key = None;
        self.actor_owner = false;
        self.public_connection_key = None;
        self.canonical.clear();
        self.topology = 0;
    }
}

pub(crate) struct GenerationClose {
    cancellations: ChargedVec<GenerationCancel>,
    jobs: Vec<windows_sys::Win32::Foundation::HANDLE>,
}

pub(crate) struct WorkerJoin {
    pub(crate) connection_key: [u8; 36],
    pub(crate) token: Arc<()>,
    pub(crate) handle: JoinHandle<()>,
}

pub(crate) enum ClosingWorkerStep {
    Join(WorkerJoin),
    WaitForPublication,
    Done,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WorkerLifecycleError {
    CompletionSignal,
    ProgressSignal,
    InvalidRecord,
}

pub(crate) enum WorkerPublish {
    Published,
    GenerationFailed,
    Rejected(JoinHandle<()>),
}

impl OwnerDispatch {
    pub(crate) fn signal_cancellations(&self) {
        if let Some(cancellation) = self.cancellation.as_ref() {
            signal_and_drain(std::slice::from_ref(cancellation));
        }
        if let Some(drains) = self.forget_drains.as_ref() {
            signal_and_drain(drains);
        }
    }
}

impl GenerationClose {
    /// Signal every connection only after the generation mutex has been
    /// released, then wait for each connection-local send gate to drain.
    pub(crate) fn signal_cancellations(&self) {
        signal_and_drain(&self.cancellations);
    }

    pub(crate) fn reap_jobs(self) {
        for job in self.jobs {
            if !job.is_null() {
                unsafe {
                    windows_sys::Win32::Foundation::CloseHandle(job);
                }
            }
        }
    }
}

/// OS-authenticated actor context passed to the later WorkspaceService only
/// after the connection's current grant covers the requested operation.
#[derive(Clone)]
#[allow(dead_code)]
pub(crate) struct AuthorizedConnection {
    pub(crate) connection_id: ConnectionId,
    pub(crate) instance_id: InstanceId,
    pub(crate) granted_project_ids: Vec<ProjectId>,
    pub(crate) granted_scopes: Vec<Scope>,
    event_seq: u64,
}

impl AuthorizedConnection {
    pub(crate) fn unsupported(&self, request: &Request) -> Response {
        error_response(
            request,
            &self.instance_id,
            self.event_seq,
            ErrorCode::UnsupportedCapability,
        )
    }
}

struct AuthShared {
    instance_id: InstanceId,
    allocations: AllocationAuthority,
    git_supervisor: crate::service::git_reader::GitSupervisor,
    inner: Mutex<State>,
}

/// The single owner of connection state, grants, and revocation generations.
/// Callers never provide an actor in JSON: public dispatch requires the opaque
/// lease created when a verified pipe peer is attached, while owner dispatch is
/// reachable only from the inherited private channel.
pub struct Authorization {
    shared: Arc<AuthShared>,
}

impl Authorization {
    pub(crate) fn start_provider_probes(&self) {
        if let Ok(state) = self.shared.inner.lock() {
            if generation_open(&state) {
                state.runtime.start_provider_probes();
            }
        }
    }

    pub(crate) fn new(registered_projects: impl IntoIterator<Item = ProjectId>) -> Self {
        let allocations = AllocationAuthority::host();
        let replay = ReplayStorage::new(&allocations)
            .expect("zero-capacity replay tables initialize without allocation");
        let projects: Vec<ProjectId> = registered_projects.into_iter().collect();
        let mut workspace =
            WorkspaceService::new(&allocations).expect("workspace table initializes");
        let artifacts = artifact_service::ArtifactRegistry::new(&allocations);
        workspace
            .seed(&allocations, &projects)
            .expect("test project seed fits in owner retained memory");
        let connections = ChargedVec::empty(&allocations, AllocationPool::ActivePublic);
        let connection_index = ChargedVec::empty(&allocations, AllocationPool::ActivePublic);
        let cancel_drain = ChargedVec::empty(&allocations, AllocationPool::ActivePublic);
        let owner_observation =
            ObservationSlot::vacant(&allocations, AllocationPool::ActiveOwner, MAX_MESSAGE_BYTES)
                .expect("owner observation slot");
        let events = EventAccounting::new(&allocations);
        let runtime = std::sync::Arc::new(crate::runtime::RuntimeService::new());
        let layout = crate::store::layout::LayoutStore::open_user_unit()
            .expect("user-unit layout store opens");
        let shared = Arc::new(AuthShared {
            instance_id: new_instance_id(),
            allocations,
            git_supervisor: crate::service::git_reader::GitSupervisor::new(),
            inner: Mutex::new(State {
                generation: GenerationState::Open,
                stop_reserved: None,
                events,
                topology_revision: 0,
                workspace,
                artifacts,
                connections,
                connection_index,
                cancel_drain,
                replay,
                owner_observation,
                runtime: runtime.clone(),
                layout,
                #[cfg(debug_assertions)]
                registration_fail_key: None,
                #[cfg(debug_assertions)]
                testing_spawn_executable: None,
                #[cfg(debug_assertions)]
                testing_spawn_prepared_hook: None,
                #[cfg(debug_assertions)]
                testing_spawn_counts: (0, 0),
                #[cfg(debug_assertions)]
                testing_fail_artifact_response_write: false,
            }),
        });
        let weak = Arc::downgrade(&shared);
        runtime.set_exit_callback(Arc::new(move |run_id| {
            let Some(shared) = weak.upgrade() else {
                return;
            };
            publish_exit_from_callback(&shared, run_id);
        }));
        Self { shared }
    }

    pub(crate) fn instance_id(&self) -> &InstanceId {
        &self.shared.instance_id
    }

    pub(crate) fn allocations(&self) -> &AllocationAuthority {
        &self.shared.allocations
    }

    pub(crate) fn begin_authentication(&self) -> Option<AuthenticationIoPermit> {
        let state = self.shared.inner.lock().ok()?;
        (generation_open(&state))
            .then_some(AuthenticationIoPermit { _private: () })
    }

    #[cfg(test)]
    pub(crate) fn testing_install_stop_join_gate(&self, fail: bool) -> std::sync::mpsc::Sender<()> {
        let state = self.shared.inner.lock().unwrap();
        state.runtime.testing_install_provider_join_gate_result(fail)
    }

    #[cfg(test)]
    pub(crate) fn testing_stop_is_reserved(&self) -> bool {
        self.shared.inner.lock().unwrap().stop_reserved.is_some()
    }

    #[cfg(test)]
    pub(crate) fn testing_connection_owned_bytes(&self) -> (usize, usize) {
        let state = self.shared.inner.lock().unwrap();
        let tables = state.connections.capacity_bytes() + state.connection_index.capacity_bytes()
            + state.cancel_drain.capacity_bytes();
        let stacks = state.connections.iter().filter_map(|record| record._stack_charge.as_ref())
            .map(CapacityCharge::bytes).sum();
        (tables, stacks)
    }

    pub(crate) fn begin_proof_send(&self) -> Option<ProofSendPermit> {
        let state = self.shared.inner.lock().ok()?;
        generation_open(&state).then_some(ProofSendPermit { _private: () })
    }

    pub(crate) fn admit_worker(
        &self,
        cancel: Arc<dyn CancelSignal>,
    ) -> Result<Option<ConnectionLease>, WorkerAdmissionError> {
        let mut state = self.shared.inner.lock().map_err(|_| WorkerAdmissionError::State)?;
        if !generation_open(&state) {
            return Ok(None);
        }
        // Refusal is an authorization state, not a capacity failure. Gate first
        // under the same lock before reserving stack, recovery, or record bytes.
        let stack_charge = self.shared.allocations
            .claim(AllocationPool::ActivePublic, PUBLIC_WORKER_STACK_BYTES)
            .map_err(|_| WorkerAdmissionError::Exhausted)?;
        let connection_key = unique_connection_key(&state);
        let recovery_credit = state
            .replay
            .reserve_recovery(&self.shared.allocations, &connection_key)
            .map_err(|_| WorkerAdmissionError::Exhausted)?;
        let lease = insert_connection(
            &mut state,
            &self.shared.allocations,
            connection_key,
            None,
            RecordState::Authenticating,
            cancel,
            WorkerOwnership::AwaitingHandle,
            recovery_credit,
            Some(stack_charge),
        );
        let Some(lease) = lease else {
            // Admission owns the whole reservation transaction. A record or
            // index allocation failure cannot orphan its unspawned credit.
            state.replay.release_unspawned(&recovery_credit)
                .map_err(|_| WorkerAdmissionError::State)?;
            return Err(WorkerAdmissionError::Exhausted);
        };
        match owner_list_bytes(&state) {
            Ok(bytes) if bytes <= MAX_MESSAGE_BYTES => Ok(Some(lease)),
            _ => {
                let recovery = connection(&state, lease.connection_key())
                    .expect("inserted connection")
                    .recovery_credit;
                let _ = state.replay.release_unspawned(&recovery);
                remove_connection(&mut state, &self.shared.allocations, lease.connection_key());
                Err(WorkerAdmissionError::Exhausted)
            }
        }
    }

    pub(crate) fn begin_worker_authentication(
        &self,
        lease: &ConnectionLease,
    ) -> Option<AuthenticationIoPermit> {
        let state = self.shared.inner.lock().ok()?;
        authentication_attempt_current(&state, lease)
        .then_some(AuthenticationIoPermit { _private: () })
    }

    pub(crate) fn begin_worker_proof_send(
        &self,
        lease: &ConnectionLease,
    ) -> Option<ProofSendPermit> {
        self.begin_worker_authentication(lease)
            .map(|_| ProofSendPermit { _private: () })
    }

    pub(crate) fn mark_verified(
        &self,
        lease: &ConnectionLease,
        executable_name: ChargedValue<NonEmpty>,
    ) -> bool {
        let Ok(mut state) = self.shared.inner.lock() else {
            return false;
        };
        if !authentication_attempt_current(&state, lease) {
            return false;
        }
        // Authenticating is not a wire EventData state; Unpaired is the first publication.
        let Ok(credit) = state.events.try_reserve(&self.shared.allocations, 1) else {
            return false;
        };
        let record = connection_mut(&mut state, lease.connection_key())
            .expect("verified connection remained present");
        record.executable_name = Some(executable_name);
        record.state = RecordState::Unpaired;
        if !list_fits(&state) {
            let record = connection_mut(&mut state, lease.connection_key())
                .expect("verified connection remained present");
            record.executable_name = None;
            record.state = RecordState::Authenticating;
            state.events.release(credit);
            return false;
        }
        let key = *lease.connection_key();
        publish_connection_state(
            &self.shared.allocations,
            &mut state,
            &key,
            ConnectionState::Unpaired,
            credit,
        );
        true
    }

    #[cfg(debug_assertions)]
    pub(crate) fn attach_verified_fixture(
        &self,
        executable_name: NonEmpty,
        cancel: Arc<dyn CancelSignal>,
    ) -> Option<ConnectionLease> {
        let mut state = self.shared.inner.lock().ok()?;
        if !generation_open(&state) {
            return None;
        }
        let connection_key = unique_connection_key(&state);
        let recovery_credit = state
            .replay
            .reserve_recovery(&self.shared.allocations, &connection_key)
            .ok()?;
        let charged_name = charge_executable_name(&self.shared.allocations, executable_name)?;
        let lease = insert_connection(
            &mut state,
            &self.shared.allocations,
            connection_key,
            Some(charged_name),
            RecordState::Unpaired,
            cancel,
            WorkerOwnership::Fixture,
            recovery_credit,
            None,
        )?;
        if !list_fits(&state) {
            let recovery = connection(&state, lease.connection_key())
                .expect("inserted fixture")
                .recovery_credit;
            let _ = state.replay.release_unspawned(&recovery);
            remove_connection(&mut state, &self.shared.allocations, lease.connection_key());
            return None;
        }
        Some(lease)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn attach_verified(
        &self,
        executable_name: NonEmpty,
        cancel: Arc<dyn CancelSignal>,
    ) -> Option<ConnectionLease> {
        self.attach_verified_fixture(executable_name, cancel)
    }

    pub(crate) fn publish_worker(
        &self,
        lease: &ConnectionLease,
        handle: JoinHandle<()>,
        set_completion: impl FnOnce() -> bool,
        set_progress: impl FnOnce() -> bool,
    ) -> WorkerPublish {
        let mut state = lock_lifecycle(&self.shared.inner);
        let generation_open = state.generation == GenerationState::Open;
        let Some(record) = connection_mut(&mut state, lease.connection_key()) else {
            return WorkerPublish::Rejected(handle);
        };
        if !Arc::ptr_eq(&record.token, &lease.token)
            || !matches!(record.worker, WorkerOwnership::AwaitingHandle)
        {
            return WorkerPublish::Rejected(handle);
        }
        record.worker = WorkerOwnership::Published(handle);
        let wake_completion = record.state == RecordState::Finished || !generation_open;
        let completion_ok = !wake_completion || set_completion();
        let progress_ok = generation_open || set_progress();
        if completion_ok && progress_ok {
            WorkerPublish::Published
        } else {
            fail_generation_locked(&self.shared.allocations, &mut state);
            WorkerPublish::GenerationFailed
        }
    }

    pub(crate) fn abort_unspawned(
        &self,
        lease: &ConnectionLease,
        set_progress: impl FnOnce() -> bool,
    ) -> bool {
        let mut state = lock_lifecycle(&self.shared.inner);
        let Some(record) = connection(&state, lease.connection_key()) else {
            return false;
        };
        if !Arc::ptr_eq(&record.token, &lease.token)
            || !matches!(record.worker, WorkerOwnership::AwaitingHandle)
        {
            return false;
        }
        let closing = state.generation != GenerationState::Open;
        let recovery = connection(&state, lease.connection_key())
            .expect("validated connection remained present")
            .recovery_credit;
        if state.replay.release_unspawned(&recovery).is_err() {
            return false;
        }
        remove_connection(&mut state, &self.shared.allocations, lease.connection_key());
        if closing && !set_progress() {
            fail_generation_locked(&self.shared.allocations, &mut state);
            return false;
        }
        true
    }

    pub(crate) fn finish_worker(
        &self,
        lease: &ConnectionLease,
        set_completion: impl FnOnce() -> bool,
    ) -> bool {
        let mut state = lock_lifecycle(&self.shared.inner);
        let Some(record) = connection_mut(&mut state, lease.connection_key()) else {
            return false;
        };
        if !Arc::ptr_eq(&record.token, &lease.token)
            || matches!(record.worker, WorkerOwnership::Fixture)
        {
            return false;
        }
        let key = *lease.connection_key();
        if connection(&state, &key)
            .is_some_and(|record| record.state != RecordState::Closing && record.state != RecordState::Finished)
        {
            publish_revoked_if_needed(&self.shared.allocations, &mut state, &key);
            let record = connection_mut(&mut state, &key).expect("record remained present");
            record.state = RecordState::Closing;
            record.granted_project_ids.clear();
            record.granted_scopes.clear();
            record.live.store(false, Ordering::SeqCst);
        }
        // Wire state remains Revoked; Finished must not take a second seq.
        if connection(&state, &key).is_some_and(|record| record.state != RecordState::Finished) {
            connection_mut(&mut state, &key)
                .expect("record remained present")
                .state = RecordState::Finished;
        }
        let tickets = take_inflight_tickets(
            &mut state,
            &self.shared.allocations,
            lease.connection_key(),
        );
        let runtime = std::sync::Arc::clone(&state.runtime);
        let ok = if set_completion() {
            true
        } else {
            fail_generation_locked(&self.shared.allocations, &mut state);
            false
        };
        drop(state);
        cancel_inflight_tickets(runtime.as_ref(), &tickets);
        ok
    }

    pub(crate) fn claim_ready_after_reset(
        &self,
        reset_completion: impl FnOnce() -> bool,
    ) -> Result<Option<WorkerJoin>, WorkerLifecycleError> {
        let mut state = lock_lifecycle(&self.shared.inner);
        if state.generation != GenerationState::Open {
            return Ok(None);
        }
        if !reset_completion() {
            fail_generation_locked(&self.shared.allocations, &mut state);
            return Err(WorkerLifecycleError::CompletionSignal);
        }
        Ok(claim_worker(&mut state, true))
    }

    pub(crate) fn claim_next_ready(&self) -> Option<WorkerJoin> {
        let mut state = lock_lifecycle(&self.shared.inner);
        claim_worker(&mut state, true)
    }

    pub(crate) fn closing_worker_step(
        &self,
        reset_progress: impl FnOnce() -> bool,
    ) -> Result<ClosingWorkerStep, WorkerLifecycleError> {
        let mut state = lock_lifecycle(&self.shared.inner);
        if state.generation == GenerationState::Open {
            return Err(WorkerLifecycleError::InvalidRecord);
        }
        if let Some(worker) = claim_worker(&mut state, false) {
            return Ok(ClosingWorkerStep::Join(worker));
        }
        if !state
            .connections
            .iter()
            .any(|record| matches!(record.worker, WorkerOwnership::AwaitingHandle))
        {
            return Ok(ClosingWorkerStep::Done);
        }
        if !reset_progress() {
            fail_generation_locked(&self.shared.allocations, &mut state);
            return Err(WorkerLifecycleError::ProgressSignal);
        }
        if let Some(worker) = claim_worker(&mut state, false) {
            Ok(ClosingWorkerStep::Join(worker))
        } else if state
            .connections
            .iter()
            .any(|record| matches!(record.worker, WorkerOwnership::AwaitingHandle))
        {
            Ok(ClosingWorkerStep::WaitForPublication)
        } else {
            Ok(ClosingWorkerStep::Done)
        }
    }

    pub(crate) fn write_correlated_exhausted(
        &self,
        correlation: &WireCorrelation,
        out: &mut ChargedVec<u8>,
    ) -> Option<()> {
        let state = self.shared.inner.lock().ok()?;
        let instance = correlation
            .instance_id
            .as_ref()
            .map_or(self.shared.instance_id.as_str(), InstanceId::as_str);
        out.clear();
        write_error_response(
            &mut Output(out),
            instance,
            correlation.operation_id.as_str(),
            state.event_seq(),
            state.topology_revision,
            ErrorCode::ResourceExhausted,
        )
        .ok()
    }

    pub(crate) fn release_observation(&self, hold: ObservationHold) {
        let Ok(mut state) = self.shared.inner.lock() else {
            return;
        };
        if hold.owner {
            if state.owner_observation.operation_key == Some(hold.operation_key) {
                state.owner_observation.release();
            }
            return;
        }
        if let Some(connection_key) = hold.connection_key {
            if let Some(record) = connection_mut(&mut state, &connection_key) {
                if record.observation.operation_key == Some(hold.operation_key) {
                    record.observation.release();
                }
            }
        }
    }

    pub(crate) fn dispatch_client(
        &self,
        lease: &ConnectionLease,
        request: &Request,
        canonical: &[u8],
        out: &mut ChargedVec<u8>,
    ) -> Option<ClientDispatch> {
        let mut state = self.shared.inner.lock().ok()?;
        if state.generation != GenerationState::Open {
            return None;
        }
        if !lease_matches(&state, lease) {
            return None;
        }
        match resolve_existing(
            &state,
            request,
            canonical,
            false,
            Some(lease),
            out,
            &self.shared.instance_id,
        ) {
            ExistingId::Replay => {
                queue_replay_outbound(&mut state, &self.shared.allocations, lease, request);
                return Some(ClientDispatch { observation: None });
            }
            ExistingId::Rejected => {
                return Some(ClientDispatch { observation: None });
            }
            ExistingId::Lock => return None,
            ExistingId::Vacant => {}
        }
        let topology = state.topology_revision;
        if request
            .instance_id
            .0
            .as_ref()
            .is_some_and(|instance| instance != &self.shared.instance_id)
        {
            write_error(
                out,
                request,
                &self.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::StateUnknown,
            )?;
            return Some(ClientDispatch { observation: None });
        }
        if state.stop_reserved.is_some() {
            write_error(out, request, &self.shared.instance_id, state.event_seq(), topology,
                ErrorCode::OperationConflict)?;
            return Some(ClientDispatch { observation: None });
        }

        match &request.action {
            Action::DiagnosticsGet(_) => {
                let record = connection(&state, lease.connection_key())?;
                if record.state != RecordState::Granted
                    || !record.granted_scopes.contains(&Scope::Metadata)
                {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::PermissionDenied,
                    )?;
                    return Some(ClientDispatch { observation: None });
                }
                let hold = occupy_observation(
                    &mut state,
                    request,
                    canonical,
                    false,
                    Some(lease.connection_key()),
                )?;
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_diagnostics(sink, &state.runtime),
                )?;
                Some(ClientDispatch {
                    observation: Some(hold),
                })
            }
            Action::CapabilitiesGet(_) => {
                let hold = occupy_observation(
                    &mut state,
                    request,
                    canonical,
                    false,
                    Some(lease.connection_key()),
                )?;
                let rich = connection(&state, lease.connection_key()).is_some_and(|record| {
                    record.state == RecordState::Granted
                        && record.granted_scopes.contains(&Scope::Metadata)
                });
                let refresh = match &request.action { Action::CapabilitiesGet(p) => p.refresh, _ => false };
                if refresh && !rich {
                    write_error(out, request, &self.shared.instance_id, state.event_seq(), topology,
                        ErrorCode::PermissionDenied)?;
                    return Some(ClientDispatch { observation: Some(hold) });
                }
                if rich { state.runtime.refresh_provider_probes(refresh); }
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_capabilities(sink, rich, &state.runtime),
                )?;
                Some(ClientDispatch {
                    observation: Some(hold),
                })
            }
            Action::ConnectionRequest(params) => {
                let registered = params
                    .project_ids
                    .iter()
                    .all(|project| registered_contains(&state, project));
                if !registered {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::InvalidRequest,
                    )?;
                    return Some(ClientDispatch { observation: None });
                }
                let current_state = connection(&state, lease.connection_key())?.state;
                let current_key = connection(&state, lease.connection_key())?.connection_key;
                let same_pending =
                    connection(&state, lease.connection_key()).is_some_and(|current| {
                        current.state == RecordState::Pending
                            && same_project_set(&current.requested_project_ids, &params.project_ids)
                            && same_scope_set(&current.requested_scopes, &params.scopes)
                    });
                match current_state {
                    RecordState::Unpaired => {
                        if admit_public_effect(
                            &mut state,
                            &self.shared.allocations,
                            request,
                            canonical,
                            lease,
                        )
                        .is_none()
                        {
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            return Some(ClientDispatch { observation: None });
                        }
                        let allocations = &self.shared.allocations;
                        let copied = {
                            let record = connection_mut(&mut state, lease.connection_key())?;
                            copy_project_keys(
                                &mut record.requested_project_ids,
                                allocations,
                                &params.project_ids,
                            )
                            .is_ok()
                                && copy_scopes(
                                    &mut record.requested_scopes,
                                    allocations,
                                    &params.scopes,
                                )
                                .is_ok()
                        };
                        if !copied || !list_fits(&state) {
                            if let Some(record) = connection_mut(&mut state, lease.connection_key())
                            {
                                record.requested_project_ids.clear();
                                record.requested_scopes.clear();
                            }
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            seal_terminal(&mut state, request, out, false)?;
                            return Some(ClientDispatch { observation: None });
                        }
                        let credit = match state.events.try_reserve(&self.shared.allocations, 1) {
                            Ok(credit) => credit,
                            Err(_) => {
                                let record = connection_mut(&mut state, lease.connection_key())?;
                                record.requested_project_ids.clear();
                                record.requested_scopes.clear();
                                write_error(
                                    out,
                                    request,
                                    &self.shared.instance_id,
                                    state.event_seq(),
                                    topology,
                                    ErrorCode::ResourceExhausted,
                                )?;
                                seal_terminal(&mut state, request, out, false)?;
                                return Some(ClientDispatch { observation: None });
                            }
                        };
                        let record = connection_mut(&mut state, lease.connection_key())?;
                        record.state = RecordState::Pending;
                        let key = record.connection_key;
                        publish_connection_state(
                            &self.shared.allocations,
                            &mut state,
                            &key,
                            ConnectionState::Pending,
                            credit,
                        );
                        write_success(
                            out,
                            request,
                            &self.shared.instance_id,
                            state.event_seq(),
                            topology,
                            |sink| write_connection_request(sink, &key),
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        Some(ClientDispatch { observation: None })
                    }
                    RecordState::Pending if same_pending => {
                        if admit_public_effect(
                            &mut state,
                            &self.shared.allocations,
                            request,
                            canonical,
                            lease,
                        )
                        .is_none()
                        {
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            return Some(ClientDispatch { observation: None });
                        }
                        let key = current_key;
                        write_success(
                            out,
                            request,
                            &self.shared.instance_id,
                            state.event_seq(),
                            topology,
                            |sink| write_connection_request(sink, &key),
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        Some(ClientDispatch { observation: None })
                    }
                    RecordState::Pending | RecordState::Granted => {
                        write_error(
                            out,
                            request,
                            &self.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::InvalidRequest,
                        )?;
                        Some(ClientDispatch { observation: None })
                    }
                    RecordState::Authenticating | RecordState::Closing | RecordState::Finished => {
                        None
                    }
                }
            }
            Action::ConnectionList(_)
            | Action::ConnectionDecide(_)
            | Action::ConnectionRevoke(_)
            | Action::HostStop(_)
            | Action::LayoutSave(_)
            | Action::LayoutRestore(_) => {
                write_error(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::PermissionDenied,
                )?;
                Some(ClientDispatch { observation: None })
            }
            Action::ProjectOpen(_) | Action::ProjectForget(_) => {
                write_error(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::PermissionDenied,
                )?;
                Some(ClientDispatch { observation: None })
            }
            Action::ProjectList(_) => {
                dispatch_public_project_list(self, state, lease, request, canonical, out)
            }
            Action::ArtifactRegister(_) | Action::ArtifactList(_) | Action::ArtifactRead(_) | Action::ArtifactDiff(_) => {
                dispatch_artifact(self, state, request, canonical, out, false, Some(lease))
                    .map(|reply| ClientDispatch { observation: reply.observation })
            }
            Action::ArtifactChoose(_) | Action::ArtifactChoiceList(_) => {
                dispatch_artifact_choice(self, state, request, canonical, out, false, Some(lease))
                    .map(|reply| ClientDispatch { observation: reply.observation })
            }
            Action::ProjectSelect(params) => dispatch_public_project_select(
                self,
                state,
                lease,
                request,
                canonical,
                out,
                params.project_id.0.clone(),
            ),
            Action::PaneCreate(_)
            | Action::PaneSplit(_)
            | Action::PaneSelect(_)
            | Action::PaneClose(_)
            | Action::PaneResize(_)
            | Action::PaneList(_)
            | Action::ShellLaunch(_)
            | Action::AgentLaunch(_)
            | Action::RunGet(_)
            | Action::RunInterrupt(_)
            | Action::OutputRead(_)
            | Action::InputWrite(_)
            | Action::InputKey(_)
            | Action::EventsWait(_)
            | Action::OperationGet(_) => {
                dispatch_client_runtime(self, state, lease, request, canonical, out)
            }
            _ => {
                let record = connection(&state, lease.connection_key())?;
                let authorized = record.state == RecordState::Granted
                    && required_scope(request.action.operation())
                        .is_some_and(|scope| record.granted_scopes.contains(&scope));
                if !authorized {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::PermissionDenied,
                    )?;
                    return Some(ClientDispatch { observation: None });
                }
                write_error(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::UnsupportedCapability,
                )?;
                Some(ClientDispatch { observation: None })
            }
        }
    }

    pub(crate) fn send_if_current<T>(
        &self,
        lease: &ConnectionLease,
        send: impl FnOnce() -> T,
    ) -> Option<T> {
        if !lease.live.load(Ordering::SeqCst) {
            return None;
        }
        let _send = lease.send_gate.lock().ok()?;
        if !lease.live.load(Ordering::SeqCst) {
            return None;
        }
        {
            let mut state = self.shared.inner.lock().ok()?;
            if state.generation != GenerationState::Open || !lease_matches(&state, lease) {
                return None;
            }
            if !admit_outbound_send(&mut state, lease.connection_key()) {
                return None;
            }
        }
        #[cfg(debug_assertions)]
        wait_product_phase(ProductPhase::SendGate, Some(lease.connection_key()));
        {
            let mut state = self.shared.inner.lock().ok()?;
            if !lease.live.load(Ordering::SeqCst)
                || state.generation != GenerationState::Open
                || !lease_matches(&state, lease)
            {
                clear_outbound_if_present(&mut state, lease.connection_key());
                return None;
            }
            let refuse = connection(&state, lease.connection_key()).is_some_and(|record| {
                record.cancel_signaled || record.outbound_phase == OutboundPhase::Refused
            });
            if refuse {
                clear_outbound_if_present(&mut state, lease.connection_key());
                return None;
            }
        }
        let sent = send();
        if let Ok(mut state) = self.shared.inner.lock() {
            clear_outbound_if_present(&mut state, lease.connection_key());
        }
        Some(sent)
    }

    pub(crate) fn dispatch_owner(
        &self,
        request: &Request,
        canonical: &[u8],
        out: &mut ChargedVec<u8>,
    ) -> Option<OwnerDispatch> {
        let mut state = self.shared.inner.lock().ok()?;
        if state.generation != GenerationState::Open {
            return None;
        }
        match resolve_existing(
            &state,
            request,
            canonical,
            true,
            None,
            out,
            &self.shared.instance_id,
        ) {
            ExistingId::Replay | ExistingId::Rejected => {
                return Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: None,
                    stop_after_reply: false,
                });
            }
            ExistingId::Lock => return None,
            ExistingId::Vacant => {}
        }
        let topology = state.topology_revision;
        if request
            .instance_id
            .0
            .as_ref()
            .is_some_and(|instance| instance != &self.shared.instance_id)
        {
            write_error(
                out,
                request,
                &self.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::StateUnknown,
            )?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }

        if state.stop_reserved.is_some() {
            write_error(out, request, &self.shared.instance_id, state.event_seq(), topology,
                ErrorCode::OperationConflict)?;
            return Some(owner_ok());
        }
        match &request.action {
            Action::DiagnosticsGet(_) => {
                let hold = occupy_observation(&mut state, request, canonical, true, None)?;
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_diagnostics(sink, &state.runtime),
                )?;
                Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: Some(hold),
                    stop_after_reply: false,
                })
            }
            Action::CapabilitiesGet(params) => {
                let hold = occupy_observation(&mut state, request, canonical, true, None)?;
                state.runtime.refresh_provider_probes(params.refresh);
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_capabilities(sink, true, &state.runtime),
                )?;
                Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: Some(hold),
                    stop_after_reply: false,
                })
            }
            Action::ConnectionList(_) => {
                let hold = occupy_observation(&mut state, request, canonical, true, None)?;
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_connection_list(sink, &state),
                )?;
                Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: Some(hold),
                    stop_after_reply: false,
                })
            }
            Action::ConnectionDecide(params) => {
                let key = validated_key(params.connection_id.as_str());
                let Some(record) = connection(&state, &key) else {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::TargetNotFound,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                };
                if record.state != RecordState::Pending {
                    let code =
                        if matches!(record.state, RecordState::Closing | RecordState::Finished) {
                            ErrorCode::TargetNotFound
                        } else {
                            ErrorCode::InvalidRequest
                        };
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                }
                let subset = params.project_ids.iter().all(|project| {
                    record
                        .requested_project_ids
                        .contains(&validated_key(project.as_str()))
                }) && params
                    .scopes
                    .iter()
                    .all(|scope| record.requested_scopes.contains(scope));
                let deny_is_empty = params.decision != Decision::Deny
                    || (params.project_ids.is_empty() && params.scopes.is_empty());
                let live = params
                    .project_ids
                    .iter()
                    .all(|project| state.workspace.contains(project));
                if !subset || !deny_is_empty || !live {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::InvalidRequest,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                }
                match params.decision {
                    Decision::Allow => {
                        if admit_owner_effect(&mut state, &self.shared.allocations, request, canonical)
                            .is_none()
                        {
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            return Some(OwnerDispatch {
                                cancellation: None,
                                forget_drains: None,
                                observation: None,
                                stop_after_reply: false,
                            });
                        }
                        let allocations = &self.shared.allocations;
                        let copied = {
                            let record = connection_mut(&mut state, &key)?;
                            copy_project_keys(
                                &mut record.granted_project_ids,
                                allocations,
                                &params.project_ids,
                            )
                            .is_ok()
                                && copy_scopes(
                                    &mut record.granted_scopes,
                                    allocations,
                                    &params.scopes,
                                )
                                .is_ok()
                        };
                        if !copied || !list_fits(&state) {
                            if let Some(record) = connection_mut(&mut state, &key) {
                                record.granted_project_ids.clear();
                                record.granted_scopes.clear();
                            }
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            seal_terminal(&mut state, request, out, false)?;
                            return Some(OwnerDispatch {
                                cancellation: None,
                                forget_drains: None,
                                observation: None,
                                stop_after_reply: false,
                            });
                        }
                        let credit = match state.events.try_reserve(&self.shared.allocations, 1) {
                            Ok(credit) => credit,
                            Err(_) => {
                                let record = connection_mut(&mut state, &key)?;
                                record.granted_project_ids.clear();
                                record.granted_scopes.clear();
                                write_error(
                                    out,
                                    request,
                                    &self.shared.instance_id,
                                    state.event_seq(),
                                    topology,
                                    ErrorCode::ResourceExhausted,
                                )?;
                                seal_terminal(&mut state, request, out, false)?;
                                return Some(OwnerDispatch {
                                    cancellation: None,
                                    forget_drains: None,
                                    observation: None,
                                    stop_after_reply: false,
                                });
                            }
                        };
                        connection_mut(&mut state, &key)?.state = RecordState::Granted;
                        publish_connection_state(
                            &self.shared.allocations,
                            &mut state,
                            &key,
                            ConnectionState::Granted,
                            credit,
                        );
                        write_success(
                            out,
                            request,
                            &self.shared.instance_id,
                            state.event_seq(),
                            topology,
                            |sink| write_connection_decide(sink, &key, true, params),
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        Some(OwnerDispatch {
                            cancellation: None,
                            forget_drains: None,
                            observation: None,
                            stop_after_reply: false,
                        })
                    }
                    Decision::Deny => {
                        if begin_connection_recovery(&mut state, &key, request, canonical).is_none()
                        {
                            write_error(
                                out,
                                request,
                                &self.shared.instance_id,
                                state.event_seq(),
                                topology,
                                ErrorCode::ResourceExhausted,
                            )?;
                            return Some(OwnerDispatch {
                                cancellation: None,
                                forget_drains: None,
                                observation: None,
                                stop_after_reply: false,
                            });
                        }
                        publish_revoked_if_needed(&self.shared.allocations, &mut state, &key);
                        let record = connection_mut(&mut state, &key)?;
                        record.state = RecordState::Closing;
                        record.granted_project_ids.clear();
                        record.granted_scopes.clear();
                        record.live.store(false, Ordering::SeqCst);
                        record.cancel_signaled = true;
                        let cancellation = Some((record.cancel.clone(), record.send_gate.clone()));
                        write_success(
                            out,
                            request,
                            &self.shared.instance_id,
                            state.event_seq(),
                            topology,
                            |sink| write_connection_decide(sink, &key, false, params),
                        )?;
                        seal_terminal(&mut state, request, out, true)?;
                        let tickets = take_inflight_tickets(
                            &mut state,
                            &self.shared.allocations,
                            &key,
                        );
                        let runtime = std::sync::Arc::clone(&state.runtime);
                        drop(state);
                        cancel_inflight_tickets(runtime.as_ref(), &tickets);
                        Some(OwnerDispatch {
                            cancellation,
                            forget_drains: None,
                            observation: None,
                            stop_after_reply: false,
                        })
                    }
                }
            }
            Action::ConnectionRevoke(params) => {
                let key = validated_key(params.connection_id.as_str());
                let Some(record) = connection(&state, &key) else {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::TargetNotFound,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                };
                if matches!(record.state, RecordState::Closing | RecordState::Finished) {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::TargetNotFound,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                }
                if begin_connection_recovery(&mut state, &key, request, canonical).is_none() {
                    write_error(
                        out,
                        request,
                        &self.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    return Some(OwnerDispatch {
                        cancellation: None,
                        forget_drains: None,
                        observation: None,
                        stop_after_reply: false,
                    });
                }
                publish_revoked_if_needed(&self.shared.allocations, &mut state, &key);
                let record = connection_mut(&mut state, &key)?;
                record.state = RecordState::Closing;
                record.granted_project_ids.clear();
                record.granted_scopes.clear();
                record.live.store(false, Ordering::SeqCst);
                record.cancel_signaled = true;
                let cancellation = Some((record.cancel.clone(), record.send_gate.clone()));
                write_success(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    |sink| write_connection_revoke(sink, &key),
                )?;
                seal_terminal(&mut state, request, out, true)?;
                let tickets = take_inflight_tickets(
                    &mut state,
                    &self.shared.allocations,
                    &key,
                );
                let runtime = std::sync::Arc::clone(&state.runtime);
                drop(state);
                cancel_inflight_tickets(runtime.as_ref(), &tickets);
                Some(OwnerDispatch {
                    cancellation,
                    forget_drains: None,
                    observation: None,
                    stop_after_reply: false,
                })
            }
            Action::LayoutSave(_) => layout::dispatch_owner_layout_save(
                self,
                state,
                request,
                canonical,
                out,
            ),
            Action::LayoutRestore(_) => layout::dispatch_owner_layout_restore(
                self,
                state,
                request,
                canonical,
                out,
            ),
            Action::HostStop(_) => layout::dispatch_owner_host_stop(
                self,
                state,
                request,
                canonical,
                out,
            ),
            Action::ConnectionRequest(_) => {
                write_error(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::InvalidRequest,
                )?;
                Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: None,
                    stop_after_reply: false,
                })
            }
            Action::ProjectList(_) => {
                dispatch_owner_project_list(self, state, request, canonical, out)
            }
            Action::ProjectOpen(params) => dispatch_owner_project_open(
                self,
                state,
                request,
                canonical,
                out,
                params.path.as_str(),
            ),
            Action::ProjectSelect(params) => dispatch_owner_project_select(
                self,
                state,
                request,
                canonical,
                out,
                params.project_id.0.clone(),
            ),
            Action::ProjectForget(params) => dispatch_owner_project_forget(
                self,
                state,
                request,
                canonical,
                out,
                params.project_id.clone(),
            ),
            Action::ArtifactRegister(_) | Action::ArtifactList(_) | Action::ArtifactRead(_) | Action::ArtifactDiff(_) => {
                dispatch_artifact(self, state, request, canonical, out, true, None)
            }
            Action::ArtifactChoose(_) | Action::ArtifactChoiceList(_) => {
                dispatch_artifact_choice(self, state, request, canonical, out, true, None)
            }
            Action::PaneCreate(_)
            | Action::PaneSplit(_)
            | Action::PaneSelect(_)
            | Action::PaneClose(_)
            | Action::PaneResize(_)
            | Action::PaneList(_)
            | Action::ShellLaunch(_)
            | Action::AgentLaunch(_)
            | Action::RunGet(_)
            | Action::RunInterrupt(_)
            | Action::OutputRead(_)
            | Action::InputWrite(_)
            | Action::InputKey(_)
            | Action::EventsWait(_)
            | Action::OperationGet(_) => dispatch_owner_runtime(self, state, request, canonical, out),
            _ => {
                write_error(
                    out,
                    request,
                    &self.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::UnsupportedCapability,
                )?;
                Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: None,
                    stop_after_reply: false,
                })
            }
        }
    }
    pub(crate) fn disconnect(&self, lease: &ConnectionLease) {
        let Ok(mut state) = self.shared.inner.lock() else {
            return;
        };
        if !lease_matches(&state, lease) {
            return;
        }
        let should_close = connection(&state, lease.connection_key()).is_some_and(|record| {
            Arc::ptr_eq(&record.token, &lease.token)
                && !matches!(record.state, RecordState::Closing | RecordState::Finished)
        });
        let tickets = take_inflight_tickets(
            &mut state,
            &self.shared.allocations,
            lease.connection_key(),
        );
        let runtime = std::sync::Arc::clone(&state.runtime);
        if should_close {
            let key = *lease.connection_key();
            publish_revoked_if_needed(&self.shared.allocations, &mut state, &key);
            let record = connection_mut(&mut state, lease.connection_key())
                .expect("matched connection remains present");
            record.state = RecordState::Closing;
            record.granted_project_ids.clear();
            record.granted_scopes.clear();
            record.live.store(false, Ordering::SeqCst);
        }
        state.events.wake_all();
        drop(state);
        cancel_inflight_tickets(runtime.as_ref(), &tickets);
    }

    pub(crate) fn close_generation(&self) -> GenerationClose {
        self.shared.git_supervisor.close();
        let mut state = lock_lifecycle(&self.shared.inner);
        if state.generation == GenerationState::Open {
            state.generation = GenerationState::Closing;
            state.artifacts.invalidate_all();
        }
        state.runtime.set_generation_visible(false);
        state.runtime.cancel_provider_probes();
        close_open_connections(&self.shared.allocations, &mut state);
        state.runtime.cancel_and_wake_after_auth_unlock();
        let jobs = state.runtime.take_jobs_for_generation_close();
        GenerationClose {
            cancellations: take_unsignaled_cancellations(&mut state, &self.shared.allocations),
            jobs,
        }
    }

    pub(crate) fn drain_provider_probes(&self) -> bool {
        let runtime = match self.shared.inner.lock() {
            Ok(state) => std::sync::Arc::clone(&state.runtime),
            Err(_) => return false,
        };
        runtime.drain_provider_probes()
    }

    pub fn testing_isolation_flags(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(bool, bool, bool)> {
        self.shared.inner.lock().ok()?.runtime.isolation_flags(run_id)
    }

    pub fn testing_session_io(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(bool, bool, bool, usize)> {
        self.shared.inner.lock().ok()?.runtime.testing_session_io(run_id)
    }

    pub fn testing_session_clean_bits(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        bool,
        Option<u32>,
    )> {
        self.shared
            .inner
            .lock()
            .ok()?
            .runtime
            .testing_session_clean_bits(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_owned_process_identity(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(u32, u64)> {
        self.shared
            .inner
            .lock()
            .ok()?
            .runtime
            .testing_owned_process_identity(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_spawn_counts(&self) -> (u64, u64) {
        self.shared
            .inner
            .lock()
            .expect("test authorization lock")
            .testing_spawn_counts
    }

    #[cfg(debug_assertions)]
    pub fn testing_retain_cleanup(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Result<crate::runtime::RetainedCleanupObservation, ErrorCode> {
        let runtime = Arc::clone(
            &self
                .shared
                .inner
                .lock()
                .map_err(|_| ErrorCode::RuntimeFailed)?
                .runtime,
        );
        runtime.testing_retain_cleanup(run_id)
    }

    pub fn testing_ctrl_c_stats(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(u32, bool, bool, bool)> {
        self.shared.inner.lock().ok()?.runtime.testing_ctrl_c_stats(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_job_stop_stats(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<(u32, bool, bool, bool, Option<u32>, Option<u32>)> {
        self.shared
            .inner
            .lock()
            .ok()?
            .runtime
            .testing_job_stop_stats(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_fail_job_terminate_once(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Result<(), crate::contract::ErrorCode> {
        self.shared
            .inner
            .lock()
            .map_err(|_| crate::contract::ErrorCode::RuntimeFailed)?
            .runtime
            .testing_fail_job_terminate_once(run_id)
    }

    pub fn testing_has_session(&self, run_id: &crate::contract::RunId) -> bool {
        self.shared
            .inner
            .lock()
            .ok()
            .is_some_and(|inner| inner.runtime.testing_has_session(run_id))
    }

    pub fn testing_input_stats(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<crate::runtime::RunIoStats> {
        self.shared
            .inner
            .lock()
            .ok()?
            .runtime
            .testing_input_stats(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_output_tail_shape(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Option<String> {
        self.shared
            .inner
            .lock()
            .ok()?
            .runtime
            .testing_output_tail_shape(run_id)
    }

    #[cfg(debug_assertions)]
    pub fn testing_attach_io_observe(
        &self,
        run_id: &crate::contract::RunId,
    ) -> Result<crate::runtime::RunIoObserveGuard, ErrorCode> {
        let inner = self.shared.inner.lock().map_err(|_| ErrorCode::RuntimeFailed)?;
        inner.runtime.testing_attach_io_observe(run_id)
    }

    pub(crate) fn fail_generation(&self) -> GenerationClose {
        let mut state = lock_lifecycle(&self.shared.inner);
        fail_generation_locked(&self.shared.allocations, &mut state);
        state.runtime.cancel_and_wake_after_auth_unlock();
        let jobs = state.runtime.take_jobs_for_generation_close();
        GenerationClose {
            cancellations: take_unsignaled_cancellations(&mut state, &self.shared.allocations),
            jobs,
        }
    }

    pub(crate) fn retire_worker(&self, connection_key: &[u8; 36], token: &Arc<()>) -> bool {
        let mut state = lock_lifecycle(&self.shared.inner);
        let matches = connection(&state, connection_key).is_some_and(|record| {
            Arc::ptr_eq(&record.token, token) && matches!(record.worker, WorkerOwnership::Joining)
        });
        let tickets = if matches {
            take_inflight_tickets(&mut state, &self.shared.allocations, connection_key)
        } else {
            ChargedVec::empty(&self.shared.allocations, AllocationPool::ActivePublic)
        };
        let runtime = std::sync::Arc::clone(&state.runtime);
        if matches {
            let recovery = connection(&state, connection_key)
                .expect("validated joining worker remained present")
                .recovery_credit;
            if state.replay.release_unused_after_join(&recovery).is_err() {
                drop(state);
                cancel_inflight_tickets(runtime.as_ref(), &tickets);
                return false;
            }
            remove_connection(&mut state, &self.shared.allocations, connection_key);
        }
        drop(state);
        cancel_inflight_tickets(runtime.as_ref(), &tickets);
        matches
    }

    #[cfg(debug_assertions)]
    pub(crate) fn record_count(&self) -> usize {
        self.shared
            .inner
            .lock()
            .map(|state| state.connections.len())
            .unwrap_or(0)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn event_seq(&self) -> u64 {
        self.shared
            .inner
            .lock()
            .map(|state| state.event_seq())
            .unwrap_or(MAX_SAFE_INTEGER)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn set_event_seq_to_max(&self) {
        self.shared
            .inner
            .lock()
            .expect("authorization lock")
            .events
            .testing_set_committed_seq(MAX_SAFE_INTEGER);
    }

    #[cfg(debug_assertions)]
    pub fn testing_replay_phase(&self, operation_id: &OperationId) -> Option<&'static str> {
        let state = self.shared.inner.lock().ok()?;
        state
            .replay
            .lookup(operation_id)
            .map(|view| match view.phase {
                ReplayPhaseView::Preparing => "preparing",
                ReplayPhaseView::Done => "done",
            })
    }

    #[cfg(debug_assertions)]
    pub fn testing_selected(&self) -> Option<ProjectId> {
        let state = self.shared.inner.lock().ok()?;
        state.workspace.selected().cloned()
    }

    #[cfg(debug_assertions)]
    pub fn testing_alias_charge_count(&self) -> usize {
        self.shared
            .inner
            .lock()
            .ok()
            .map(|state| state.workspace.testing_alias_charge_count())
            .unwrap_or(0)
    }

    #[cfg(debug_assertions)]
    pub fn testing_set_occupancy(
        &self,
        id: &ProjectId,
        live_run: bool,
        spawn_reserved: bool,
    ) -> bool {
        let Ok(mut state) = self.shared.inner.lock() else {
            return false;
        };
        if !state.workspace.contains(id) {
            return false;
        }
        if state
            .runtime
            .testing_set_unclean_project_session(id.clone(), live_run)
            .is_err()
        {
            return false;
        }
        state
            .workspace
            .set_fixture_occupancy(id, live_run, spawn_reserved)
    }

    #[cfg(debug_assertions)]
    pub fn testing_connection_snapshot(
        &self,
        id: &ConnectionId,
    ) -> Option<TestingConnectionSnapshot> {
        let state = self.shared.inner.lock().ok()?;
        let key = validated_key(id.as_str());
        let record = connection(&state, &key)?;
        Some(TestingConnectionSnapshot {
            connection_id: id.as_str().to_owned(),
            state: match record.state {
                RecordState::Authenticating => "authenticating",
                RecordState::Unpaired => "unpaired",
                RecordState::Pending => "pending",
                RecordState::Granted => "granted",
                RecordState::Closing => "closing",
                RecordState::Finished => "finished",
            },
            granted_project_ids: record
                .granted_project_ids
                .iter()
                .filter_map(|key| std::str::from_utf8(key).ok().map(str::to_owned))
                .collect(),
            granted_scopes: record
                .granted_scopes
                .iter()
                .map(|scope| scope.wire())
                .collect(),
        })
    }

    #[cfg(debug_assertions)]
    pub fn testing_replay_receipt(
        &self,
        operation_id: &OperationId,
    ) -> Option<TestingReplayReceipt> {
        let state = self.shared.inner.lock().ok()?;
        let view = state.replay.lookup(operation_id)?;
        Some(TestingReplayReceipt {
            phase: match view.phase {
                ReplayPhaseView::Preparing => "preparing",
                ReplayPhaseView::Done => "done",
            },
            event_seq: view.counters.map(|counters| counters.event_seq),
            topology_revision: view.counters.map(|counters| counters.topology_revision),
        })
    }

    #[cfg(debug_assertions)]
    pub fn testing_counters(&self) -> (u64, u64) {
        self.shared
            .inner
            .lock()
            .map(|state| (state.event_seq(), state.topology_revision))
            .unwrap_or((MAX_SAFE_INTEGER, MAX_SAFE_INTEGER))
    }

    #[cfg(debug_assertions)]
    pub fn testing_outstanding_credits(&self) -> u64 {
        self.shared
            .inner
            .lock()
            .map(|state| state.events.outstanding_credits())
            .unwrap_or(0)
    }

    #[cfg(debug_assertions)]
    pub fn testing_event_waiters(&self) -> Result<Vec<TestingEventWaiter>, ErrorCode> {
        let state = self
            .shared
            .inner
            .lock()
            .map_err(|_| ErrorCode::RuntimeFailed)?;
        Ok(state.events.waiter_snapshot())
    }

    #[cfg(debug_assertions)]
    pub fn testing_exit_latch_charge(&self) -> u64 {
        self.shared
            .inner
            .lock()
            .map(|state| state.events.exit_latch_charge())
            .unwrap_or(0)
    }

    #[cfg(debug_assertions)]
    pub fn testing_fire_exit_callback(&self, run_id: &crate::contract::RunId) {
        publish_exit_from_callback(&self.shared, run_id.clone());
    }

    #[cfg(debug_assertions)]
    pub fn testing_fail_registration_for(&self, id: &ConnectionId) {
        if let Ok(mut state) = self.shared.inner.lock() {
            state.registration_fail_key = Some(validated_key(id.as_str()));
        }
    }

    #[cfg(debug_assertions)]
    pub fn testing_clear_registration_fail(&self) {
        if let Ok(mut state) = self.shared.inner.lock() {
            state.registration_fail_key = None;
        }
    }

    #[cfg(debug_assertions)]
    pub fn testing_consume_forced_allocation_failure(&self) -> bool {
        self.shared.allocations.allocation_is_forced_to_fail()
    }


    pub(crate) fn generation_is_open(&self) -> bool {
        self.shared
            .inner
            .lock()
            .map(|state| state.generation == GenerationState::Open)
            .unwrap_or(false)
    }
}

enum ExistingId {
    Vacant,
    Replay,
    Rejected,
    Lock,
}

fn resolve_existing(
    state: &State,
    request: &Request,
    canonical: &[u8],
    caller_owner: bool,
    lease: Option<&ConnectionLease>,
    out: &mut ChargedVec<u8>,
    instance_id: &InstanceId,
) -> ExistingId {
    let operation_key = validated_key(request.operation_id.as_str());
    if let Some(slot) = find_observation(state, &operation_key) {
        let same_actor = observation_matches_caller(slot, caller_owner, lease);
        if !same_actor {
            return write_existing_error(
                out,
                request,
                instance_id,
                state,
                ErrorCode::PermissionDenied,
            );
        }
        if &slot.canonical[..] != canonical {
            return write_existing_error(
                out,
                request,
                instance_id,
                state,
                ErrorCode::OperationConflict,
            );
        }
        return write_existing_error(out, request, instance_id, state, ErrorCode::InProgress);
    }
    let Some(view) = state.replay.lookup(&request.operation_id) else {
        return ExistingId::Vacant;
    };
    if !replay_actor_matches(view.actor, caller_owner, lease) {
        return write_existing_error(
            out,
            request,
            instance_id,
            state,
            ErrorCode::PermissionDenied,
        );
    }
    if view.canonical != canonical {
        return write_existing_error(
            out,
            request,
            instance_id,
            state,
            ErrorCode::OperationConflict,
        );
    }
    match view.phase {
        ReplayPhaseView::Preparing => {
            write_existing_error(out, request, instance_id, state, ErrorCode::InProgress)
        }
        ReplayPhaseView::Done => {
            let Some(ticket) = view.ticket else {
                return ExistingId::Lock;
            };
            if !ticket.permits(state, caller_owner, lease) {
                return ExistingId::Lock;
            }
            if copy_terminal(out, view.terminal).is_some() {
                ExistingId::Replay
            } else {
                ExistingId::Lock
            }
        }
    }
}

fn write_existing_error(
    out: &mut ChargedVec<u8>,
    request: &Request,
    instance_id: &InstanceId,
    state: &State,
    code: ErrorCode,
) -> ExistingId {
    if write_error(
        out,
        request,
        instance_id,
        state.event_seq(),
        state.topology_revision,
        code,
    )
    .is_some()
    {
        ExistingId::Rejected
    } else {
        ExistingId::Lock
    }
}

fn find_observation<'a>(state: &'a State, operation_key: &[u8; 36]) -> Option<&'a ObservationSlot> {
    if state.owner_observation.operation_key.as_ref() == Some(operation_key) {
        return Some(&state.owner_observation);
    }
    state
        .connections
        .iter()
        .find(|record| record.observation.operation_key.as_ref() == Some(operation_key))
        .map(|record| &record.observation)
}

fn observation_matches_caller(
    slot: &ObservationSlot,
    caller_owner: bool,
    lease: Option<&ConnectionLease>,
) -> bool {
    if slot.actor_owner {
        caller_owner
    } else {
        !caller_owner
            && lease.is_some_and(|lease| {
                slot.public_connection_key.as_ref() == Some(lease.connection_key())
            })
    }
}

fn replay_actor_matches(
    actor: &ReplayActor,
    caller_owner: bool,
    lease: Option<&ConnectionLease>,
) -> bool {
    match actor {
        ReplayActor::Owner => caller_owner,
        ReplayActor::Public(stored) => {
            !caller_owner
                && lease.is_some_and(|lease| {
                    stored.connection_key() == lease.connection_key()
                        && Arc::ptr_eq(&stored.token, &lease.token)
                })
        }
    }
}

fn copy_terminal(out: &mut ChargedVec<u8>, terminal: &[u8]) -> Option<()> {
    out.clear();
    out.try_extend_from_slice(terminal).ok()
}

fn occupy_observation(
    state: &mut State,
    request: &Request,
    canonical: &[u8],
    owner: bool,
    connection_key: Option<&[u8; 36]>,
) -> Option<ObservationHold> {
    let operation_key = validated_key(request.operation_id.as_str());
    let public_key = connection_key.copied();
    if owner {
        state
            .owner_observation
            .occupy(
                operation_key,
                true,
                None,
                canonical,
                state.topology_revision,
            )
            .ok()?;
    } else {
        let topology = state.topology_revision;
        connection_mut(state, connection_key?)?
            .observation
            .occupy(operation_key, false, public_key, canonical, topology)
            .ok()?;
    }
    Some(ObservationHold {
        operation_key,
        owner,
        connection_key: public_key,
    })
}

fn native_data_terminal_capacity(request: &Request) -> Option<usize> {
    const SIZING_ID: &str = "00000000-0000-4000-8000-000000000000";
    let success = match &request.action {
        Action::InputWrite(params) => Success::InputWrite(
            run_service::input_write_data(
                params.pane_id.clone(),
                params.run_id.clone(),
                MAX_SAFE_INTEGER,
                MAX_MESSAGE_BYTES as u64,
            )
            .ok()?,
        ),
        Action::InputKey(params) => Success::InputKey(
            run_service::input_key_data(
                params.pane_id.clone(),
                params.run_id.clone(),
                MAX_SAFE_INTEGER,
                params.key,
            )
            .ok()?,
        ),
        Action::PaneResize(params) => Success::PaneResize(params.clone()),
        _ => return None,
    };
    let mut measured = Measure(0);
    write_success_prefix(&mut measured, SIZING_ID, SIZING_ID, MAX_SAFE_INTEGER).ok()?;
    success.write_canonical(&mut measured).ok()?;
    write_success_suffix(&mut measured, MAX_SAFE_INTEGER).ok()?;
    let mut maximum = measured.0;
    for code in ErrorCode::ALL {
        let mut error = Measure(0);
        write_error_response(
            &mut error,
            SIZING_ID,
            SIZING_ID,
            MAX_SAFE_INTEGER,
            MAX_SAFE_INTEGER,
            *code,
        )
        .ok()?;
        maximum = maximum.max(error.0);
    }
    (maximum <= MAX_MESSAGE_BYTES).then_some(maximum)
}

fn effect_capacities(canonical_len: usize, request: &Request) -> Option<(usize, usize)> {
    let terminal_capacity = match request.action {
        Action::InputWrite(_) | Action::InputKey(_) | Action::PaneResize(_) => {
            native_data_terminal_capacity(request)?
        }
        _ => MAX_MESSAGE_BYTES,
    };
    Some((canonical_len.max(1), terminal_capacity))
}

fn admit_retained_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    actor: ReplayActor,
    ticket: SendPolicyTicket,
    pool: AllocationPool,
) -> Option<()> {
    let (canonical_capacity, terminal_capacity) = effect_capacities(canonical.len(), request)?;
    let mut reservation = state
        .replay
        .reserve_effect(allocations, pool, canonical_capacity, terminal_capacity)
        .ok()?;
    if state
        .replay
        .begin_effect(
            &mut reservation,
            &request.operation_id,
            actor,
            ticket,
            canonical,
        )
        .is_err()
    {
        let _ = state.replay.cancel_effect(&reservation);
        return None;
    }
    Some(())
}

fn admit_public_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    lease: &ConnectionLease,
) -> Option<()> {
    let ticket = SendPolicyTicket::public_lease(allocations, lease.clone()).ok()?;
    admit_retained_effect(
        state,
        allocations,
        request,
        canonical,
        ReplayActor::Public(lease.clone()),
        ticket,
        AllocationPool::ActivePublic,
    )
}

fn admit_owner_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
) -> Option<()> {
    admit_retained_effect(
        state,
        allocations,
        request,
        canonical,
        ReplayActor::Owner,
        SendPolicyTicket::owner(),
        AllocationPool::ActiveOwner,
    )
}

fn seal_terminal(state: &mut State, request: &Request, out: &[u8], recovery: bool) -> Option<()> {
    let counters = ReplayCounters {
        topology_revision: state.topology_revision,
        event_seq: state.event_seq(),
    };
    if recovery {
        state
            .replay
            .finish_recovery(&request.operation_id, out, counters)
            .ok()
    } else if matches!(
        request.action,
        Action::InputWrite(_) | Action::InputKey(_) | Action::PaneResize(_)
    ) {
        state
            .replay
            .finish_native_data_effect(&request.operation_id, out, counters)
            .ok()
    } else {
        state
            .replay
            .finish_effect(&request.operation_id, out, counters)
            .ok()
    }
}

fn begin_connection_recovery(
    state: &mut State,
    connection_key: &[u8; 36],
    request: &Request,
    canonical: &[u8],
) -> Option<()> {
    let mut credit = connection(state, connection_key)?.recovery_credit;
    state
        .replay
        .begin_recovery(&mut credit, &request.operation_id, canonical)
        .ok()?;
    connection_mut(state, connection_key)?.recovery_credit = credit;
    Some(())
}

fn list_fits(state: &State) -> bool {
    owner_list_bytes(state).is_ok_and(|bytes| bytes <= MAX_MESSAGE_BYTES)
}

fn charge_executable_name(
    allocations: &AllocationAuthority,
    name: NonEmpty,
) -> Option<ChargedValue<NonEmpty>> {
    let bytes = name.owned_capacity();
    let charge = allocations
        .claim(AllocationPool::ActivePublic, bytes)
        .ok()?;
    Some(ChargedValue::from_parts(name, charge))
}

fn signal_and_drain(cancellations: &[(Arc<dyn CancelSignal>, Arc<Mutex<()>>)]) {
    for (cancellation, _) in cancellations {
        cancellation.cancel();
    }
    for (_, gate) in cancellations {
        match gate.lock() {
            Ok(guard) => drop(guard),
            Err(poisoned) => drop(poisoned.into_inner()),
        }
    }
}

fn new_instance_id() -> InstanceId {
    InstanceId::new(uuid::Uuid::new_v4().to_string()).expect("UUID v4 is a valid instance ID")
}

fn new_connection_key() -> [u8; 36] {
    let mut key = [0u8; 36];
    let encoded = uuid::Uuid::new_v4().hyphenated().encode_lower(&mut key);
    debug_assert_eq!(encoded.len(), 36);
    key
}

fn unique_connection_key(state: &State) -> [u8; 36] {
    loop {
        let candidate = new_connection_key();
        if connection_index_of(state, &candidate).is_none() {
            return candidate;
        }
    }
}

fn connection_index_of(state: &State, key: &[u8; 36]) -> Option<usize> {
    state
        .connection_index
        .binary_search_by_key(key, |entry| entry.connection_key)
        .ok()
        .map(|index| state.connection_index[index].slot)
}

fn connection<'a>(state: &'a State, key: &[u8; 36]) -> Option<&'a ConnectionRecord> {
    connection_index_of(state, key).map(|slot| &state.connections[slot])
}

fn connection_mut<'a>(state: &'a mut State, key: &[u8; 36]) -> Option<&'a mut ConnectionRecord> {
    let slot = connection_index_of(state, key)?;
    Some(&mut state.connections[slot])
}

fn expected_revision(request: &Request) -> u64 {
    request
        .expected_topology_revision
        .0
        .map(crate::contract::U::get)
        .unwrap_or(0)
}

fn relock_after_observe<'a>(
    auth: &'a Authorization,
    request: &Request,
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    seal_effect: bool,
) -> Result<std::sync::MutexGuard<'a, State>, Option<()>> {
    let mut state = match auth.shared.inner.lock() {
        Ok(state) => state,
        Err(poisoned) => poisoned.into_inner(),
    };
    let generation_open = state.generation == GenerationState::Open;
    let actor_ok = owner || lease.is_some_and(|lease| lease_matches(&state, lease));
    if generation_open && actor_ok && state.stop_reserved.is_none() {
        return Ok(state);
    }
    let topology = state.topology_revision;
    let code = if generation_open && state.stop_reserved.is_some() {
        ErrorCode::OperationConflict
    } else if generation_open {
        ErrorCode::PermissionDenied
    } else {
        ErrorCode::StateUnknown
    };
    let wrote = write_error(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        topology,
        code,
    )
    .is_some();
    if seal_effect {
        let _ = seal_terminal(&mut state, request, out, false);
    }
    if wrote {
        Err(Some(()))
    } else {
        Err(None)
    }
}

fn bump_topology(state: &mut State) -> bool {
    if state.topology_revision == MAX_SAFE_INTEGER {
        false
    } else {
        state.topology_revision += 1;
        true
    }
}

fn can_layout_change(state: &State) -> bool {
    state.topology_revision < MAX_SAFE_INTEGER
        && state
            .events
            .committed_seq()
            .checked_add(state.events.outstanding_credits())
            .and_then(|sum| sum.checked_add(1))
            .is_some_and(|sum| sum <= MAX_SAFE_INTEGER)
}

fn forget_grants(state: &mut State, project: &ProjectId) {
    let key = key_of(project);
    for record in state.connections.iter_mut() {
        let mut index = 0;
        while index < record.granted_project_ids.len() {
            if record.granted_project_ids[index] == key {
                record.granted_project_ids.remove(index);
            } else {
                index += 1;
            }
        }
    }
    state.events.wake_all();
}

fn queue_outbound(
    record: &mut ConnectionRecord,
    allocations: &AllocationAuthority,
    keys: &[[u8; 36]],
) -> Result<(), ReplayStorageError> {
    grow_active_vec(&mut record.outbound_keys, allocations, keys.len())?;
    record.outbound_keys.clear();
    for key in keys {
        record
            .outbound_keys
            .try_push(*key)
            .map_err(|_| ReplayStorageError::Capacity)?;
    }
    record.outbound_phase = OutboundPhase::Queued;
    Ok(())
}

fn clear_outbound(record: &mut ConnectionRecord) {
    record.outbound_keys.clear();
    record.outbound_phase = OutboundPhase::Idle;
}

fn clear_outbound_if_present(state: &mut State, key: &[u8; 36]) {
    if let Some(record) = connection_mut(state, key) {
        clear_outbound(record);
    }
}

fn outbound_still_valid(state: &State, record: &ConnectionRecord) -> bool {
    record.outbound_keys.iter().all(|key| {
        record.granted_project_ids.contains(key)
            && project_from_key(key).is_some_and(|id| state.workspace.contains(&id))
    })
}

fn admit_outbound_send(state: &mut State, connection_key: &[u8; 36]) -> bool {
    let valid = {
        let Some(record) = connection(state, connection_key) else {
            return false;
        };
        match record.outbound_phase {
            OutboundPhase::Idle => record.outbound_keys.is_empty(),
            OutboundPhase::Queued => outbound_still_valid(state, record),
            OutboundPhase::Writing => true,
            OutboundPhase::Refused => false,
        }
    };
    let Some(record) = connection_mut(state, connection_key) else {
        return false;
    };
    if !valid {
        clear_outbound(record);
        return false;
    }
    if record.outbound_phase == OutboundPhase::Queued {
        record.outbound_phase = OutboundPhase::Writing;
    }
    true
}

fn queue_replay_outbound(
    state: &mut State,
    allocations: &AllocationAuthority,
    lease: &ConnectionLease,
    request: &Request,
) {
    let Some(view) = state.replay.lookup(&request.operation_id) else {
        return;
    };
    let Some(ticket) = view.ticket else {
        return;
    };
    let keys = match ticket {
        SendPolicyTicket::Public {
            project_ids,
            coverage: SendCoverage::CurrentGrants,
            ..
        } => project_ids.keys().to_vec(),
        _ => return,
    };
    let Some(record) = connection_mut(state, lease.connection_key()) else {
        return;
    };
    if queue_outbound(record, allocations, &keys).is_err() {
        record.outbound_phase = OutboundPhase::Refused;
        record.outbound_keys.clear();
    }
}

fn reserve_forget_drains(
    state: &mut State,
    allocations: &AllocationAuthority,
) -> Result<(), ReplayStorageError> {
    grow_active_vec(
        &mut state.cancel_drain,
        allocations,
        state.connections.len(),
    )
}

fn collect_forget_drains(state: &mut State, project: &ProjectId) {
    let key = key_of(project);
    let count = state.connections.len();
    for index in 0..count {
        let covers = state.connections[index].outbound_keys.contains(&key);
        if !covers {
            continue;
        }
        match state.connections[index].outbound_phase {
            OutboundPhase::Queued => {
                state.connections[index].outbound_phase = OutboundPhase::Refused;
            }
            OutboundPhase::Writing => {
                state.connections[index].cancel_signaled = true;
                let cancel = state.connections[index].cancel.clone();
                let gate = state.connections[index].send_gate.clone();
                state
                    .cancel_drain
                    .try_push((cancel, gate))
                    .expect("forget drain slots were reserved before commit");
            }
            OutboundPhase::Idle | OutboundPhase::Refused => {}
        }
    }
}

fn take_forget_drains(
    state: &mut State,
    allocations: &AllocationAuthority,
) -> Option<ChargedVec<GenerationCancel>> {
    let drains = std::mem::replace(
        &mut state.cancel_drain,
        ChargedVec::empty(allocations, AllocationPool::ActivePublic),
    );
    if drains.is_empty() {
        None
    } else {
        Some(drains)
    }
}

fn admit_public_effect_with_target(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    lease: &ConnectionLease,
    projects: &StringSet<ProjectId>,
    field_scopes: &[Scope],
) -> Option<()> {
    let ticket =
        SendPolicyTicket::public_target(allocations, lease.clone(), projects, field_scopes).ok()?;
    admit_retained_effect(
        state,
        allocations,
        request,
        canonical,
        ReplayActor::Public(lease.clone()),
        ticket,
        AllocationPool::ActivePublic,
    )
}

fn admit_public_effect_with_projects(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    lease: &ConnectionLease,
    projects: &StringSet<ProjectId>,
) -> Option<()> {
    admit_public_effect_with_target(
        state,
        allocations,
        request,
        canonical,
        lease,
        projects,
        &[],
    )
}

fn project_from_key(key: &[u8; 36]) -> Option<ProjectId> {
    ProjectId::new(std::str::from_utf8(key).ok()?.to_owned()).ok()
}

fn snapshot_roots(
    state: &State,
    allowed: Option<&[[u8; 36]]>,
) -> Vec<(
    ProjectId,
    Option<String>,
    Option<crate::contract::RootIdentity>,
)> {
    state
        .workspace
        .projects()
        .iter()
        .filter(|project| {
            allowed.is_none_or(|granted| granted.iter().any(|key| *key == key_of(&project.id)))
        })
        .map(|project| {
            (
                project.id.clone(),
                project.path.clone(),
                project.identity.clone(),
            )
        })
        .collect()
}

fn observe_snapshots(
    snapshots: &[(
        ProjectId,
        Option<String>,
        Option<crate::contract::RootIdentity>,
    )],
    allocations: &AllocationAuthority,
    pool: AllocationPool,
) -> Vec<(ProjectId, RootState)> {
    snapshots
        .iter()
        .map(|(id, path, identity)| {
            let state = match (path.as_deref(), identity.as_ref()) {
                (Some(path), Some(identity)) => reobserve_state(path, identity, allocations, pool),
                _ => RootState::Unknown,
            };
            (id.clone(), state)
        })
        .collect()
}

fn dispatch_public_project_list(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    lease: &ConnectionLease,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<ClientDispatch> {
    let topology = state.topology_revision;
    let record = connection(&state, lease.connection_key())?;
    if record.state != RecordState::Granted || !record.granted_scopes.contains(&Scope::Metadata) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::PermissionDenied,
        )?;
        return Some(ClientDispatch { observation: None });
    }
    let granted: Vec<[u8; 36]> = record.granted_project_ids.iter().copied().collect();
    let hold = occupy_observation(
        &mut state,
        request,
        canonical,
        false,
        Some(lease.connection_key()),
    )?;
    if connection_mut(&mut state, lease.connection_key())
        .and_then(|record| queue_outbound(record, &auth.shared.allocations, &granted).ok())
        .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(ClientDispatch {
            observation: Some(hold),
        });
    }
    let snapshots = snapshot_roots(&state, Some(&granted));
    drop(state);
    let observed = observe_snapshots(&snapshots, &auth.shared.allocations, AllocationPool::ActivePublic);
    let mut state = match relock_after_observe(auth, request, out, false, Some(lease), false) {
        Ok(state) => state,
        Err(Some(())) => {
            if let Ok(mut state) = auth.shared.inner.lock() {
                if let Some(record) = connection_mut(&mut state, lease.connection_key()) {
                    if record.observation.operation_key == Some(hold.operation_key) {
                        record.observation.release();
                    }
                }
            }
            return Some(ClientDispatch {
                observation: Some(hold),
            });
        }
        Err(None) => return None,
    };
    let record = connection(&state, lease.connection_key())?;
    if record.state != RecordState::Granted || !record.granted_scopes.contains(&Scope::Metadata) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            state.topology_revision,
            ErrorCode::PermissionDenied,
        )?;
        return Some(ClientDispatch {
            observation: Some(hold),
        });
    }
    let granted: Vec<[u8; 36]> = record.granted_project_ids.iter().copied().collect();
    let read_output = record.granted_scopes.contains(&Scope::ReadOutput);
    if connection_mut(&mut state, lease.connection_key())
        .and_then(|record| {
            grow_active_vec(&mut record.outbound_keys, &auth.shared.allocations, granted.len()).ok()
        })
        .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            state.topology_revision,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(ClientDispatch {
            observation: Some(hold),
        });
    }
    let rows = visible_rows(
        state.workspace.projects(),
        false,
        true,
        read_output,
        &granted,
        &observed,
    );
    let selected = selected_if_visible(state.workspace.selected(), &rows).cloned();
    write_success(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        |sink| write_project_list(sink, &rows, selected.as_ref()),
    )?;
    if let Some(record) = connection_mut(&mut state, lease.connection_key()) {
        if record.outbound_phase != OutboundPhase::Refused
            && queue_outbound(record, &auth.shared.allocations, &granted).is_err()
        {
            record.outbound_phase = OutboundPhase::Refused;
            record.outbound_keys.clear();
        }
    }
    Some(ClientDispatch {
        observation: Some(hold),
    })
}

fn dispatch_owner_project_list(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<OwnerDispatch> {
    let hold = occupy_observation(&mut state, request, canonical, true, None)?;
    let snapshots = snapshot_roots(&state, None);
    drop(state);
    let observed = observe_snapshots(&snapshots, &auth.shared.allocations, AllocationPool::ActiveOwner);
    let state = match relock_after_observe(auth, request, out, true, None, false) {
        Ok(state) => state,
        Err(Some(())) => {
            if let Ok(mut state) = auth.shared.inner.lock() {
                if state.owner_observation.operation_key == Some(hold.operation_key) {
                    state.owner_observation.release();
                }
            }
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: Some(hold),
                stop_after_reply: false,
            });
        }
        Err(None) => return None,
    };
    let rows = visible_rows(state.workspace.projects(), true, true, true, &[], &observed);
    let selected = selected_if_visible(state.workspace.selected(), &rows).cloned();
    write_success(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        |sink| write_project_list(sink, &rows, selected.as_ref()),
    )?;
    Some(OwnerDispatch {
        cancellation: None,
        forget_drains: None,
        observation: Some(hold),
        stop_after_reply: false,
    })
}

fn dispatch_owner_project_open(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    path: &str,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    if classify_path_syntax(path).is_err() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::InvalidRequest,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    if admit_owner_effect(&mut state, &auth.shared.allocations, request, canonical).is_none() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    let expected = expected_revision(request);
    let path = path.to_owned();
    drop(state);
    let observed = observe_root(&path, &auth.shared.allocations, AllocationPool::ActiveOwner);
    let mut state = match relock_after_observe(auth, request, out, true, None, true) {
        Ok(state) => state,
        Err(Some(())) => {
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
        Err(None) => return None,
    };
    let topology = state.topology_revision;
    let observed = match observed {
        Ok(observed) => observed,
        Err(error) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                error.code(),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
    };
    match state.workspace.classify_open(&observed, expected, topology) {
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
        Ok(OpenKind::Create) if !can_layout_change(&state) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::ResourceExhausted,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
        Ok(_) => {}
    }
    let create_credit = match state.workspace.classify_open(&observed, expected, topology) {
        Ok(OpenKind::Create) => match state.events.try_reserve(&auth.shared.allocations, 1) {
            Ok(credit) => Some(credit),
            Err(_) => {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(OwnerDispatch {
                    cancellation: None,
                    forget_drains: None,
                    observation: None,
                    stop_after_reply: false,
                });
            }
        },
        _ => None,
    };
    match state
        .workspace
        .commit_open(&auth.shared.allocations, &observed, expected, topology)
    {
        Ok(OpenOutcome::Created(id)) => {
            let credit = create_credit.expect("Create reserved a credit before commit");
            let _ = bump_topology(&mut state);
            publish_topology_change(
                &auth.shared.allocations,
                &mut state,
                credit,
                Some(id.clone()),
                None,
            );
            write_success(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                |sink| write_project_open(sink, &id, true),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
        Ok(OpenOutcome::Existing(id)) => {
            if let Some(credit) = create_credit {
                state.events.release(credit);
            }
            write_success(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                |sink| write_project_open(sink, &id, false),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
        Err(code) => {
            if let Some(credit) = create_credit {
                state.events.release(credit);
            }
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
    }
}

fn dispatch_owner_project_select(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    target: Option<ProjectId>,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    if let Some(id) = target.as_ref() {
        if !state.workspace.contains(id) {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::TargetNotFound,
            )?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
    }
    if admit_owner_effect(&mut state, &auth.shared.allocations, request, canonical).is_none() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    let expected = expected_revision(request);
    let observe_target = target.as_ref().and_then(|id| {
        state
            .workspace
            .get(id)
            .and_then(|project| Some((project.path.clone()?, project.identity.clone()?)))
    });
    drop(state);
    let observed_state = observe_target.as_ref().map(|(path, identity)| {
        reobserve_state(
            path,
            identity,
            &auth.shared.allocations,
            AllocationPool::ActiveOwner,
        )
    });
    let mut state = match relock_after_observe(auth, request, out, true, None, true) {
        Ok(state) => state,
        Err(Some(())) => {
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
        Err(None) => return None,
    };
    let topology = state.topology_revision;
    if let Some(root) = observed_state {
        let code = match root {
            RootState::Verified => None,
            RootState::Unavailable => Some(ErrorCode::TargetNotFound),
            RootState::Changed => Some(ErrorCode::RootChanged),
            RootState::Unknown => Some(ErrorCode::PermissionDenied),
        };
        if let Some(code) = code {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
    }
    match state
        .workspace
        .classify_select(target.as_ref(), expected, topology)
    {
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
        Ok(SelectOutcome::Changed) if !can_layout_change(&state) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::ResourceExhausted,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
        Ok(outcome) => {
            let credit = if matches!(outcome, SelectOutcome::Changed) {
                match state.events.try_reserve(&auth.shared.allocations, 1) {
                    Ok(credit) => Some(credit),
                    Err(_) => {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        return Some(OwnerDispatch {
                            cancellation: None,
                            forget_drains: None,
                            observation: None,
                            stop_after_reply: false,
                        });
                    }
                }
            } else {
                None
            };
            state.workspace.apply_select(target.as_ref());
            if let Some(credit) = credit {
                let _ = bump_topology(&mut state);
                publish_topology_change(
                    &auth.shared.allocations,
                    &mut state,
                    credit,
                    target.clone(),
                    None,
                );
            }
            let selected = state.workspace.selected().cloned();
            write_success(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                |sink| write_project_select(sink, selected.as_ref()),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
    }
}

fn dispatch_owner_project_forget(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    project_id: ProjectId,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    if !state.workspace.contains(&project_id) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::TargetNotFound,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    let occupancy = state.workspace.get(&project_id).map(|project| {
        state
            .runtime
            .project_session_quiescence(&project_id, &project.panes)
    });
    let occupancy_code = match occupancy {
        Some(Ok(CompleteSessionQuiescence::Clean)) => None,
        Some(Ok(CompleteSessionQuiescence::Preparing)) => Some(ErrorCode::OperationConflict),
        Some(Ok(CompleteSessionQuiescence::Unclean)) => Some(ErrorCode::AlreadyRunning),
        Some(Err(_)) => Some(ErrorCode::RuntimeFailed),
        None => Some(ErrorCode::TargetNotFound),
    };
    if let Some(code) = occupancy_code {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            code,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    if admit_owner_effect(&mut state, &auth.shared.allocations, request, canonical).is_none() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    if !can_layout_change(&state) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    if reserve_forget_drains(&mut state, &auth.shared.allocations).is_err() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(OwnerDispatch {
            cancellation: None,
            forget_drains: None,
            observation: None,
            stop_after_reply: false,
        });
    }
    let credit = match state.events.try_reserve(&auth.shared.allocations, 1) {
        Ok(credit) => credit,
        Err(_) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::ResourceExhausted,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            });
        }
    };
    let expected = expected_revision(request);
    match state
        .workspace
        .commit_forget(&project_id, expected, topology)
    {
        Ok(id) => {
            state.artifacts.forget(&id);
            forget_grants(&mut state, &id);
            collect_forget_drains(&mut state, &id);
            let _ = bump_topology(&mut state);
            publish_topology_change(
                &auth.shared.allocations,
                &mut state,
                credit,
                Some(id.clone()),
                None,
            );
            write_success(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                |sink| write_project_forget(sink, &id),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: take_forget_drains(&mut state, &auth.shared.allocations),
                observation: None,
                stop_after_reply: false,
            })
        }
        Err(code) => {
            state.events.release(credit);
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(OwnerDispatch {
                cancellation: None,
                forget_drains: None,
                observation: None,
                stop_after_reply: false,
            })
        }
    }
}

fn new_pane_id() -> Result<crate::contract::PaneId, ErrorCode> {
    crate::contract::PaneId::new(uuid::Uuid::new_v4().to_string())
        .map_err(|_| ErrorCode::RuntimeFailed)
}

fn new_run_id() -> Result<crate::contract::RunId, ErrorCode> {
    crate::contract::RunId::new(uuid::Uuid::new_v4().to_string())
        .map_err(|_| ErrorCode::RuntimeFailed)
}

fn owner_ok() -> OwnerDispatch {
    OwnerDispatch {
        cancellation: None,
        forget_drains: None,
        observation: None,
        stop_after_reply: false,
    }
}

fn owner_hold(hold: ObservationHold) -> OwnerDispatch {
    OwnerDispatch {
        cancellation: None,
        forget_drains: None,
        observation: Some(hold),
        stop_after_reply: false,
    }
}

fn occupy_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> Option<()> {
    if owner {
        admit_owner_effect(state, allocations, request, canonical)
    } else {
        admit_public_effect(state, allocations, request, canonical, lease?)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TopologyAdmission {
    Allow,
    Stale,
    Exhausted,
}

fn topology_admission(request: &Request, state: &State) -> TopologyAdmission {
    if request.action.operation().class() != crate::contract::OperationClass::T {
        return TopologyAdmission::Allow;
    }
    let expected = request
        .expected_topology_revision
        .0
        .as_ref()
        .map(|value| value.get());
    if expected != Some(state.topology_revision) {
        TopologyAdmission::Stale
    } else if can_layout_change(state) {
        TopologyAdmission::Allow
    } else {
        TopologyAdmission::Exhausted
    }
}

fn topology_denial(request: &Request, state: &State) -> Option<ErrorCode> {
    match topology_admission(request, state) {
        TopologyAdmission::Allow => None,
        TopologyAdmission::Stale => Some(ErrorCode::StaleTopology),
        TopologyAdmission::Exhausted => Some(ErrorCode::ResourceExhausted),
    }
}

fn write_success_data(
    out: &mut ChargedVec<u8>,
    request: &Request,
    instance_id: &crate::contract::InstanceId,
    event_seq: u64,
    topology: u64,
    success: crate::contract::Success,
) -> Option<()> {
    write_success(out, request, instance_id, event_seq, topology, |sink| {
        success.write_canonical(sink)
    })
}

fn generation_open(state: &State) -> bool {
    state.generation == GenerationState::Open && state.stop_reserved.is_none()
}

fn authentication_attempt_current(state: &State, lease: &ConnectionLease) -> bool {
    generation_open(state) && connection(state, lease.connection_key()).is_some_and(|record| {
        record.state == RecordState::Authenticating && Arc::ptr_eq(&record.token, &lease.token)
    })
}

fn dummy_observation(
    run_id: crate::contract::RunId,
    pane_id: crate::contract::PaneId,
) -> crate::contract::RunObservation {
    crate::contract::RunObservation {
        run_id,
        pane_id,
        process: crate::contract::Process::Unknown,
        work: crate::contract::Work::Unknown,
        evidence: crate::contract::Evidence::Unavailable,
        observed_at: crate::runtime::session::now_timestamp().unwrap_or_else(|| {
            crate::contract::Timestamp::new("1970-01-01T00:00:00.000Z").expect("epoch")
        }),
        current: false,
        exit_code: crate::contract::Nullable(None),
    }
}

fn relock_state(auth: &Authorization) -> std::sync::MutexGuard<'_, State> {
    auth.shared
        .inner
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn covers_granted(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    project_id: &ProjectId,
) -> bool {
    if owner {
        return true;
    }
    lease
        .and_then(|lease| connection(state, lease.connection_key()))
        .is_some_and(|record| {
            record.state == RecordState::Granted
                && record.granted_project_ids.contains(&key_of(project_id))
        })
}

fn admitted_project(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    project_id: &ProjectId,
) -> bool {
    state.workspace.contains(project_id) && covers_granted(state, owner, lease, project_id)
}

fn admitted_project_for_pane(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    pane_id: &crate::contract::PaneId,
) -> Option<ProjectId> {
    let project_id = state.workspace.project_id_for_pane(pane_id)?;
    admitted_project(state, owner, lease, &project_id).then_some(project_id)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OccupancyKind {
    RetainedEffect,
    CurrentObservation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RunMembership {
    None,
    CurrentRun,
    PreviousPublished,
}

struct RuntimeAdmission {
    project_id: Option<ProjectId>,
    pane_id: Option<crate::contract::PaneId>,
    run_id: Option<crate::contract::RunId>,
    membership: RunMembership,
    field_scopes: Vec<Scope>,
    occupancy: OccupancyKind,
    grant_projects: Vec<ProjectId>,
}

enum AdmissionDecision {
    Admit(RuntimeAdmission),
    Deny {
        code: ErrorCode,
        bind_project: Option<ProjectId>,
    },
}

fn public_actor_scoped(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    request: &Request,
) -> bool {
    if owner {
        return true;
    }
    let Some(lease) = lease else {
        return false;
    };
    if !lease_matches(state, lease) {
        return false;
    }
    let Some(record) = connection(state, lease.connection_key()) else {
        return false;
    };
    record.state == RecordState::Granted
        && required_scope(request.action.operation())
            .map_or(true, |scope| record.granted_scopes.contains(&scope))
}

fn snapshot_grants(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> Vec<ProjectId> {
    if owner {
        return Vec::new();
    }
    lease
        .and_then(|lease| connection(state, lease.connection_key()))
        .map(|record| {
            record
                .granted_project_ids
                .iter()
                .filter_map(project_from_key)
                .collect()
        })
        .unwrap_or_default()
}

fn admit_named_project(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    project_id: &ProjectId,
    occupancy: OccupancyKind,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    match admitted_project(state, owner, lease, project_id).then(|| project_id.clone()) {
        Some(project_id) => AdmissionDecision::Admit(RuntimeAdmission {
            project_id: Some(project_id),
            pane_id: None,
            run_id: None,
            membership: RunMembership::None,
            field_scopes,
            occupancy,
            grant_projects: grants,
        }),
        None => AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        },
    }
}

fn admit_named_pane(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    pane_id: &crate::contract::PaneId,
    occupancy: OccupancyKind,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    match admitted_project_for_pane(state, owner, lease, pane_id) {
        Some(project_id) => AdmissionDecision::Admit(RuntimeAdmission {
            project_id: Some(project_id),
            pane_id: Some(pane_id.clone()),
            run_id: None,
            membership: RunMembership::None,
            field_scopes,
            occupancy,
            grant_projects: grants,
        }),
        None => AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        },
    }
}

fn admit_named_pane_with_current_guard(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    pane_id: &crate::contract::PaneId,
    expected: Option<&crate::contract::Nullable<crate::contract::RunId>>,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    let decision = admit_named_pane(
        state,
        owner,
        lease,
        pane_id,
        OccupancyKind::RetainedEffect,
        field_scopes,
        grants,
    );
    if let (Some(expected), Some(admitted)) = (expected, admitted_ref(&decision)) {
        let current = admitted
            .project_id
            .as_ref()
            .and_then(|id| state.workspace.panes(id))
            .and_then(|panes| panes.pane(pane_id))
            .map(|pane| &pane.current_run);
        if current != Some(&expected.0) {
            return AdmissionDecision::Deny {
                code: ErrorCode::TargetNotFound,
                bind_project: None,
            };
        }
    }
    decision
}

fn admit_current_run(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    pane_id: &crate::contract::PaneId,
    run_id: &crate::contract::RunId,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    match admitted_project_for_pane(state, owner, lease, pane_id) {
        None => AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        },
        Some(project_id) => {
            let current = state
                .workspace
                .panes(&project_id)
                .and_then(|panes| panes.pane(pane_id))
                .and_then(|pane| pane.current_run.clone());
            if current.as_ref() != Some(run_id) {
                return AdmissionDecision::Deny {
                    code: ErrorCode::TargetNotFound,
                    bind_project: Some(project_id),
                };
            }
            AdmissionDecision::Admit(RuntimeAdmission {
                project_id: Some(project_id),
                pane_id: Some(pane_id.clone()),
                run_id: Some(run_id.clone()),
                membership: RunMembership::CurrentRun,
                field_scopes,
                occupancy: OccupancyKind::RetainedEffect,
                grant_projects: grants,
            })
        }
    }
}

fn admit_published_run(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    run_id: &crate::contract::RunId,
    occupancy: OccupancyKind,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    let Some(pane_id) = pane_id_for_run(state, run_id) else {
        return AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        };
    };
    let Some(project_id) = run_is_published_on_pane(state, &pane_id, run_id) else {
        return AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        };
    };
    match admitted_project(state, owner, lease, &project_id).then(|| project_id.clone()) {
        None => AdmissionDecision::Deny {
            code: ErrorCode::TargetNotFound,
            bind_project: None,
        },
        Some(project_id) => {
            let current = pane_current_run(state, &pane_id)
                .is_some_and(|(_, current)| current.as_str() == run_id.as_str());
            AdmissionDecision::Admit(RuntimeAdmission {
                project_id: Some(project_id),
                pane_id: Some(pane_id),
                run_id: Some(run_id.clone()),
                membership: if current {
                    RunMembership::CurrentRun
                } else {
                    RunMembership::PreviousPublished
                },
                field_scopes,
                occupancy,
                grant_projects: grants,
            })
        }
    }
}

fn admit_actor_only(
    occupancy: OccupancyKind,
    field_scopes: Vec<Scope>,
    grants: Vec<ProjectId>,
) -> AdmissionDecision {
    AdmissionDecision::Admit(RuntimeAdmission {
        project_id: None,
        pane_id: None,
        run_id: None,
        membership: RunMembership::None,
        field_scopes,
        occupancy,
        grant_projects: grants,
    })
}

fn admit_runtime(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    request: &Request,
) -> AdmissionDecision {
    if !public_actor_scoped(state, owner, lease, request) {
        return AdmissionDecision::Deny {
            code: ErrorCode::PermissionDenied,
            bind_project: None,
        };
    }
    let grants = snapshot_grants(state, owner, lease);
    let control = vec![Scope::Control];
    let metadata = vec![Scope::Metadata];
    let read_output = vec![Scope::ReadOutput];
    match &request.action {
        Action::PaneList(params) => admit_named_project(
            state,
            owner,
            lease,
            &params.project_id,
            OccupancyKind::CurrentObservation,
            metadata,
            grants,
        ),
        Action::PaneCreate(params) => admit_named_project(
            state,
            owner,
            lease,
            &params.project_id,
            OccupancyKind::RetainedEffect,
            control,
            grants,
        ),
        Action::PaneSplit(params) => admit_named_pane(
            state,
            owner,
            lease,
            &params.pane_id,
            OccupancyKind::RetainedEffect,
            control,
            grants,
        ),
        Action::PaneSelect(params) => match params.pane_id.0.as_ref() {
            None => match state.workspace.selected() {
                Some(project_id) if admitted_project(state, owner, lease, project_id) => {
                    admit_named_project(
                        state,
                        owner,
                        lease,
                        project_id,
                        OccupancyKind::RetainedEffect,
                        control,
                        grants,
                    )
                }
                Some(_) => AdmissionDecision::Deny {
                    code: ErrorCode::PermissionDenied,
                    bind_project: None,
                },
                None if !owner => AdmissionDecision::Deny {
                    code: ErrorCode::PermissionDenied,
                    bind_project: None,
                },
                None => admit_actor_only(OccupancyKind::RetainedEffect, control, grants),
            },
            Some(pane_id) => admit_named_pane(
                state,
                owner,
                lease,
                pane_id,
                OccupancyKind::RetainedEffect,
                control,
                grants,
            ),
        },
        Action::PaneClose(params) => admit_named_pane_with_current_guard(
            state, owner, lease, &params.pane_id,
            params.expected_current_run_id.as_ref(), control, grants,
        ),
        Action::PaneResize(params) => admit_current_run(
            state,
            owner,
            lease,
            &params.pane_id,
            &params.run_id,
            control,
            grants,
        ),
        Action::ShellLaunch(params) => admit_named_pane_with_current_guard(
            state, owner, lease, &params.pane_id,
            params.expected_current_run_id.as_ref(), control, grants,
        ),
        Action::AgentLaunch(params) => admit_named_pane_with_current_guard(
            state, owner, lease, &params.pane_id,
            params.expected_current_run_id.as_ref(), control, grants,
        ),
        Action::RunGet(params) => admit_published_run(
            state,
            owner,
            lease,
            &params.run_id,
            OccupancyKind::CurrentObservation,
            metadata,
            grants,
        ),
        Action::RunInterrupt(params) => admit_published_run(
            state,
            owner,
            lease,
            &params.run_id,
            OccupancyKind::RetainedEffect,
            control,
            grants,
        ),
        Action::OutputRead(params) => admit_published_run(
            state,
            owner,
            lease,
            &params.run_id,
            OccupancyKind::CurrentObservation,
            read_output,
            grants,
        ),
        Action::InputWrite(params) => admit_current_run(
            state,
            owner,
            lease,
            &params.pane_id,
            &params.run_id,
            control,
            grants,
        ),
        Action::InputKey(params) => admit_current_run(
            state,
            owner,
            lease,
            &params.pane_id,
            &params.run_id,
            control,
            grants,
        ),
        Action::EventsWait(_) => {
            admit_actor_only(OccupancyKind::CurrentObservation, metadata, grants)
        }
        Action::OperationGet(_) => {
            admit_actor_only(OccupancyKind::CurrentObservation, control, grants)
        }
        _ => AdmissionDecision::Deny {
            code: ErrorCode::UnsupportedCapability,
            bind_project: None,
        },
    }
}

fn denied_code(decision: &AdmissionDecision) -> Option<ErrorCode> {
    match decision {
        AdmissionDecision::Deny { code, .. } => Some(*code),
        AdmissionDecision::Admit(_) => None,
    }
}

fn admitted_ref(decision: &AdmissionDecision) -> Option<&RuntimeAdmission> {
    match decision {
        AdmissionDecision::Admit(admitted) => Some(admitted),
        AdmissionDecision::Deny { .. } => None,
    }
}

fn occupy_decision_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    owner: bool,
    lease: Option<&ConnectionLease>,
    decision: &AdmissionDecision,
) -> Option<()> {
    match decision {
        AdmissionDecision::Admit(admitted) => occupy_runtime_effect(
            state,
            allocations,
            request,
            canonical,
            owner,
            lease,
            admitted.project_id.as_ref(),
            &admitted.field_scopes,
        ),
        AdmissionDecision::Deny { bind_project, .. } => occupy_runtime_effect(
            state,
            allocations,
            request,
            canonical,
            owner,
            lease,
            bind_project.as_ref(),
            &[Scope::Control],
        ),
    }
}

fn public_has_scope(state: &State, lease: Option<&ConnectionLease>, scope: Scope) -> bool {
    lease
        .and_then(|lease| connection(state, lease.connection_key()))
        .is_some_and(|record| {
            record.state == RecordState::Granted && record.granted_scopes.contains(&scope)
        })
}

fn queue_public_keys(
    state: &mut State,
    allocations: &AllocationAuthority,
    lease: Option<&ConnectionLease>,
    keys: &[[u8; 36]],
) -> bool {
    let Some(lease) = lease else {
        return true;
    };
    let Some(record) = connection_mut(state, lease.connection_key()) else {
        return false;
    };
    if queue_outbound(record, allocations, keys).is_err() {
        record.outbound_phase = OutboundPhase::Refused;
        record.outbound_keys.clear();
        return false;
    }
    true
}

fn single_project_set(id: ProjectId) -> Option<StringSet<ProjectId>> {
    StringSet::new(vec![id]).ok()
}

fn occupy_runtime_effect(
    state: &mut State,
    allocations: &AllocationAuthority,
    request: &Request,
    canonical: &[u8],
    owner: bool,
    lease: Option<&ConnectionLease>,
    project_id: Option<&ProjectId>,
    field_scopes: &[Scope],
) -> Option<()> {
    if owner {
        return admit_owner_effect(state, allocations, request, canonical);
    }
    let lease = lease?;
    if let Some(project_id) = project_id {
        let set = single_project_set(project_id.clone())?;
        return admit_public_effect_with_target(
            state,
            allocations,
            request,
            canonical,
            lease,
            &set,
            field_scopes,
        );
    }
    admit_public_effect(state, allocations, request, canonical, lease)
}

fn pane_current_run(
    state: &State,
    pane_id: &crate::contract::PaneId,
) -> Option<(ProjectId, crate::contract::RunId)> {
    let project_id = state.workspace.project_id_for_pane(pane_id)?;
    let run = state
        .workspace
        .panes(&project_id)
        .and_then(|panes| panes.pane(pane_id))
        .and_then(|pane| pane.current_run.clone())?;
    Some((project_id, run))
}

fn run_is_published_on_pane(
    state: &State,
    pane_id: &crate::contract::PaneId,
    run_id: &crate::contract::RunId,
) -> Option<ProjectId> {
    let project_id = state.workspace.project_id_for_pane(pane_id)?;
    let pane = state
        .workspace
        .panes(&project_id)
        .and_then(|panes| panes.pane(pane_id))?;
    let on_pane = pane
        .current_run
        .as_ref()
        .is_some_and(|run| run.as_str() == run_id.as_str())
        || pane
            .previous_runs
            .iter()
            .any(|run| run.as_str() == run_id.as_str());
    on_pane.then_some(project_id)
}

fn seal_and_finish_data(
    state: &mut State,
    request: &Request,
    out: &mut ChargedVec<u8>,
    runtime: &crate::runtime::RuntimeService,
    run_id: &crate::contract::RunId,
    ticket: crate::runtime::RunDataTicket,
) -> Option<()> {
    match runtime.commit_data_with(run_id, ticket, |_| {
        #[cfg(debug_assertions)]
        wait_product_phase(ProductPhase::ProtocolSeal, None);
        seal_terminal(state, request, out, false).ok_or(())
    }) {
        Ok(Ok(())) => Some(()),
        Ok(Err(())) | Err(_) => None,
    }
}

fn enqueue_and_register(
    state: &mut State,
    allocations: &AllocationAuthority,
    owner: bool,
    lease: Option<&ConnectionLease>,
    run_id: &crate::contract::RunId,
    operation_id: &OperationId,
    kind: crate::runtime::RunDataKind,
    payload_len: usize,
) -> Result<crate::runtime::RunDataTicket, ErrorCode> {
    if !owner {
        let lease = lease.ok_or(ErrorCode::PermissionDenied)?;
        {
            #[cfg(debug_assertions)]
            let fail_registration =
                state.registration_fail_key.as_ref() == Some(lease.connection_key());
            let record = connection_mut(state, lease.connection_key())
                .ok_or(ErrorCode::PermissionDenied)?;
            #[cfg(debug_assertions)]
            if fail_registration {
                let forced = record
                    .inflight
                    .capacity_elements()
                    .checked_add(1)
                    .ok_or(ErrorCode::ResourceExhausted)?;
                let bytes = forced
                    .checked_mul(std::mem::size_of::<InflightTicket>())
                    .ok_or(ErrorCode::ResourceExhausted)?;
                allocations.fail_after_allocations(0);
                let forced = record
                    .inflight
                    .try_grow(allocations, forced, bytes);
                if forced.is_err() {
                    return Err(ErrorCode::ResourceExhausted);
                }
            }
            let needed = record.inflight.len().saturating_add(1);
            grow_active_vec(&mut record.inflight, allocations, needed)
                .map_err(|_| ErrorCode::ResourceExhausted)?;
        }
    }
    let ticket = state.runtime.enqueue_operation_data(
        run_id,
        kind,
        payload_len,
        validated_key(operation_id.as_str()),
    )?;
    if !owner {
        let lease = lease.ok_or(ErrorCode::PermissionDenied)?;
        let pushed = {
            let record = connection_mut(state, lease.connection_key())
                .ok_or(ErrorCode::PermissionDenied)?;
            record
                .inflight
                .try_push(InflightTicket {
                    run_key: validated_key(run_id.as_str()),
                    ticket,
                })
                .is_ok()
        };
        if !pushed {
            let _ = state.runtime.cancel_data(run_id, ticket);
            return Err(ErrorCode::ResourceExhausted);
        }
    }
    Ok(ticket)
}

fn take_inflight_tickets(
    state: &mut State,
    allocations: &AllocationAuthority,
    connection_key: &[u8; 36],
) -> ChargedVec<InflightTicket> {
    let empty = ChargedVec::empty(allocations, AllocationPool::ActivePublic);
    let Some(record) = connection_mut(state, connection_key) else {
        return empty;
    };
    std::mem::replace(&mut record.inflight, empty)
}

fn cancel_inflight_tickets(
    runtime: &crate::runtime::RuntimeService,
    tickets: &ChargedVec<InflightTicket>,
) {
    for entry in tickets.iter() {
        if let Ok(run_id) = crate::contract::RunId::new(
            std::str::from_utf8(&entry.run_key)
                .unwrap_or("")
                .to_owned(),
        ) {
            let _ = runtime.cancel_data(&run_id, entry.ticket);
        }
    }
}

fn unregister_inflight(
    state: &mut State,
    connection_key: &[u8; 36],
    ticket: crate::runtime::RunDataTicket,
) {
    let Some(record) = connection_mut(state, connection_key) else {
        return;
    };
    if let Some(index) = record
        .inflight
        .iter()
        .position(|entry| entry.ticket == ticket)
    {
        record.inflight.remove(index);
    }
}

fn unregister_public_ticket(
    state: &mut State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    ticket: crate::runtime::RunDataTicket,
) {
    if owner {
        return;
    }
    if let Some(lease) = lease {
        unregister_inflight(state, lease.connection_key(), ticket);
    }
}

fn dispatch_run_payload(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    pane_id: crate::contract::PaneId,
    run_id: crate::contract::RunId,
    payload: Vec<u8>,
    key: Option<crate::contract::InputKey>,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let decision = admit_runtime(&state, owner, lease, request);
    if occupy_decision_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
        owner,
        lease,
        &decision,
    )
    .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(owner_ok());
    }
    let Some(admitted) = admitted_ref(&decision) else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    };
    let Some(project_id) = admitted.project_id.clone() else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::TargetNotFound,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    };
    match state.runtime.observation(&run_id) {
        Ok((process, _, _, _)) if matches!(process, crate::contract::Process::Exited) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::NotRunning,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
        Ok(_) => {}
    }
    if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    let runtime = std::sync::Arc::clone(&state.runtime);
    let kind = if key.is_some() {
        crate::runtime::RunDataKind::Key
    } else {
        crate::runtime::RunDataKind::Write
    };
    let payload_len = if key.is_some() { 1 } else { payload.len() };
    let ticket = match enqueue_and_register(
        &mut state,
        &auth.shared.allocations,
        owner,
        lease,
        &run_id,
        &request.operation_id,
        kind,
        payload_len,
    ) {
        Ok(ticket) => ticket,
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
    };
    drop(state);
    if let Err(code) = run_service::admit_fifo(runtime.as_ref(), &run_id, ticket) {
        let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
        let mut state = relock_state(auth);
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            state.topology_revision,
            code,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        unregister_public_ticket(&mut state, owner, lease, ticket);
        let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
        return Some(owner_ok());
    }

    {
        let mut state = relock_state(auth);
        let actor_ok = owner || lease.is_some_and(|lease| lease_matches(&state, lease));
        let recheck = admit_runtime(&state, owner, lease, request);
        let still_current = matches!(
            &recheck,
            AdmissionDecision::Admit(admitted)
                if admitted.membership == RunMembership::CurrentRun
                    && admitted.run_id.as_ref() == Some(&run_id)
        );
        if !generation_open(&state) || !actor_ok || !still_current {
            let code = if !generation_open(&state) {
                ErrorCode::StateUnknown
            } else if !actor_ok {
                ErrorCode::PermissionDenied
            } else {
                match &recheck {
                    AdmissionDecision::Deny { code, .. } => *code,
                    AdmissionDecision::Admit(_) => ErrorCode::TargetNotFound,
                }
            };
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            drop(state);
            let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
            let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
            return Some(owner_ok());
        }
    }

    let reserved_seq = match runtime.reserved_input_seq(&run_id, ticket) {
        Ok(Some(seq)) => seq,
        Ok(None) | Err(_) => {
            let mut state = relock_state(auth);
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                ErrorCode::StateUnknown,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            drop(state);
            let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
            let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
            return Some(owner_ok());
        }
    };
    let prepared_success = if let Some(key) = key {
        run_service::input_key_data(pane_id, run_id.clone(), reserved_seq, key)
            .map(crate::contract::Success::InputKey)
    } else {
        run_service::input_write_data(
            pane_id,
            run_id.clone(),
            reserved_seq,
            payload_len as u64,
        )
        .map(crate::contract::Success::InputWrite)
    };
    let prepared_success = match prepared_success {
        Ok(success) => success,
        Err(code) => {
            let mut state = relock_state(auth);
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            drop(state);
            let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
            let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
            return Some(owner_ok());
        }
    };

    let issue = run_service::issue_write(runtime.as_ref(), &run_id, ticket, &payload);
    let delivered = match &issue {
        Ok(outcome) => run_service::delivered_written_bytes(*outcome, payload.len()),
        Err(code) => Err(*code),
    };
    let mut state = relock_state(auth);
    match delivered {
        Ok(_) => {
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        state.topology_revision,
                        prepared_success,
                    )?;
                    seal_and_finish_data(
                        &mut state,
                        request,
                        out,
                        runtime.as_ref(),
                        &run_id,
                        ticket,
                    )?;
                    unregister_public_ticket(&mut state, owner, lease, ticket);
                    Some(owner_ok())
        }
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                code,
            )?;
            seal_and_finish_data(
                &mut state,
                request,
                out,
                runtime.as_ref(),
                &run_id,
                ticket,
            )?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            Some(owner_ok())
        }
    }
}

fn dispatch_resize_payload(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    params: &crate::contract::PaneResizeParams,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let decision = admit_runtime(&state, owner, lease, request);
    if occupy_decision_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
        owner,
        lease,
        &decision,
    )
    .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(owner_ok());
    }
    let Some(admitted) = admitted_ref(&decision) else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    };
    let Some(project_id) = admitted.project_id.clone() else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::TargetNotFound,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    };
    let cols = params.cols.get();
    let rows = params.rows.get();
    if run_service::hpcon_size(cols, rows).is_err() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::InvalidRequest,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    match state.runtime.observation(&params.run_id) {
        Ok((process, _, _, _)) if matches!(process, crate::contract::Process::Exited) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::NotRunning,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
        Ok(_) => {}
    }
    if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    let runtime = std::sync::Arc::clone(&state.runtime);
    let run_id = params.run_id.clone();
    let ticket = match enqueue_and_register(
        &mut state,
        &auth.shared.allocations,
        owner,
        lease,
        &run_id,
        &request.operation_id,
        crate::runtime::RunDataKind::Resize,
        0,
    ) {
        Ok(ticket) => ticket,
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
    };
    drop(state);
    if let Err(code) = run_service::admit_fifo(runtime.as_ref(), &run_id, ticket) {
        let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
        let mut state = relock_state(auth);
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            state.topology_revision,
            code,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        unregister_public_ticket(&mut state, owner, lease, ticket);
        let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
        return Some(owner_ok());
    }
    {
        let mut state = relock_state(auth);
        let actor_ok = owner || lease.is_some_and(|lease| lease_matches(&state, lease));
        let recheck = admit_runtime(&state, owner, lease, request);
        let still_current = matches!(
            &recheck,
            AdmissionDecision::Admit(admitted)
                if admitted.membership == RunMembership::CurrentRun
                    && admitted.run_id.as_ref() == Some(&run_id)
        );
        if !generation_open(&state) || !actor_ok || !still_current {
            let code = if !generation_open(&state) {
                ErrorCode::StateUnknown
            } else if !actor_ok {
                ErrorCode::PermissionDenied
            } else {
                match &recheck {
                    AdmissionDecision::Deny { code, .. } => *code,
                    AdmissionDecision::Admit(_) => ErrorCode::TargetNotFound,
                }
            };
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            drop(state);
            let _ = run_service::cancel_fifo(runtime.as_ref(), &run_id, ticket);
            let _ = run_service::reject_unissued(runtime.as_ref(), &run_id, ticket);
            return Some(owner_ok());
        }
    }
    let prepared_success = Success::PaneResize(params.clone());
    let issue = run_service::issue_resize(runtime.as_ref(), &run_id, ticket, cols, rows);
    let mut state = relock_state(auth);
    match &issue {
        Ok(crate::runtime::RunNativeOutcome::Delivered { .. }) => {
            write_success_data(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                prepared_success,
            )?;
            seal_and_finish_data(
                &mut state,
                request,
                out,
                runtime.as_ref(),
                &run_id,
                ticket,
            )?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            Some(owner_ok())
        }
        Ok(_) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                ErrorCode::StateUnknown,
            )?;
            seal_and_finish_data(
                &mut state,
                request,
                out,
                runtime.as_ref(),
                &run_id,
                ticket,
            )?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            Some(owner_ok())
        }
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                *code,
            )?;
            seal_and_finish_data(
                &mut state,
                request,
                out,
                runtime.as_ref(),
                &run_id,
                ticket,
            )?;
            unregister_public_ticket(&mut state, owner, lease, ticket);
            Some(owner_ok())
        }
    }
}

fn event_project(state: &State, event: &crate::contract::MetadataEvent) -> Option<ProjectId> {
    match &event.data {
        crate::contract::EventData::TopologyChanged { project_id, .. } => project_id.0.clone(),
        crate::contract::EventData::RunStateChanged { run } => {
            state.workspace.project_id_for_pane(&run.pane_id)
        }
        _ => None,
    }
}

fn live_observation(
    run_id: crate::contract::RunId,
    pane_id: crate::contract::PaneId,
    process: crate::contract::Process,
    work: crate::contract::Work,
    code: Option<u32>,
    current: bool,
) -> crate::contract::RunObservation {
    let exited = matches!(process, crate::contract::Process::Exited);
    crate::contract::RunObservation {
        run_id,
        pane_id,
        process,
        work: if exited {
            work
        } else {
            crate::contract::Work::Unknown
        },
        evidence: if exited {
            crate::contract::Evidence::ProcessExit
        } else {
            crate::contract::Evidence::Unavailable
        },
        observed_at: crate::runtime::session::now_timestamp().unwrap_or_else(|| {
            crate::contract::Timestamp::new("1970-01-01T00:00:00.000Z").expect("epoch")
        }),
        current,
        exit_code: crate::contract::Nullable(if exited {
            code.and_then(|value| crate::contract::ExitCode::new(value as i32).ok())
        } else {
            None
        }),
    }
}

fn dispatch_events_wait<'a>(
    auth: &'a Authorization,
    mut state: std::sync::MutexGuard<'a, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    params: &crate::contract::EventsWaitParams,
    grant_snapshot: Vec<ProjectId>,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let connection_key = lease.map(|item| item.connection_key());
    if params.after_event_seq.get() > state.event_seq() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::InvalidRequest,
        )?;
        return Some(owner_ok());
    }
    let Some(hold) = occupy_observation(&mut state, request, canonical, owner, connection_key) else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(owner_ok());
    };
    if !owner {
        if let Some(lease) = lease {
            let keys: Vec<[u8; 36]> = grant_snapshot
                .iter()
                .map(|id| validated_key(id.as_str()))
                .collect();
            if !queue_public_keys(&mut state, &auth.shared.allocations, Some(lease), &keys) {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_hold(hold));
            }
        }
    }
    #[cfg(debug_assertions)]
    PENDING_WAIT_OBSERVE.with(|cell| {
        cell.set(Some((
            params.after_event_seq.get(),
            lease.map(|item| *item.connection_key()),
        )));
    });
    let waiter = match state.events.register_waiter(&auth.shared.allocations) {
        Ok(waiter) => {
            #[cfg(debug_assertions)]
            PENDING_WAIT_OBSERVE.with(|cell| cell.set(None));
            waiter
        }
        Err(code) => {
            #[cfg(debug_assertions)]
            PENDING_WAIT_OBSERVE.with(|cell| cell.set(None));
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            return Some(owner_hold(hold));
        }
    };
    let wait_ms = params.after_event_seq;
    let after = params.after_event_seq;
    let wait_budget = params.wait_ms.get();
    let started = Instant::now();
    loop {
        if !generation_open(&state)
            || !(owner || lease.is_some_and(|lease| lease_matches(&state, lease)))
        {
            state.events.unregister_waiter(&waiter);
            let code = if generation_open(&state) {
                ErrorCode::PermissionDenied
            } else {
                ErrorCode::StateUnknown
            };
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                code,
            )?;
            return Some(owner_hold(hold));
        }
        let (committed, dropped, log) = state.events.snapshot_for_wait();
        let projected = output_service::project_events_wait(
            after,
            committed,
            dropped,
            log,
            |event| {
                let project = event_project(&state, event);
                output_service::event_passes_grant(
                    event,
                    project.as_ref(),
                    &grant_snapshot,
                    owner,
                    false,
                )
            },
            output_service::events_envelope_budget(),
        );
        match projected {
            Ok(data) => {
                let remaining = output_service::remaining_wait_ms(wait_budget, started.elapsed());
                let block = wait_budget > 0
                    && remaining > 0
                    && data.status == crate::contract::WaitStatus::NoChange
                    && output_service::os_wait_timeout(wait_budget, started.elapsed()).is_some();
                if !block {
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        state.topology_revision,
                        crate::contract::Success::EventsWait(data),
                    )?;
                    state.events.unregister_waiter(&waiter);
                    return Some(owner_hold(hold));
                }
            }
            Err(code) => {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    state.topology_revision,
                    code,
                )?;
                state.events.unregister_waiter(&waiter);
                return Some(owner_hold(hold));
            }
        }
        waiter.reset();
        drop(state);
        if let Some(timeout_ms) = output_service::os_wait_timeout(wait_budget, started.elapsed()) {
            waiter.wait_timeout(Duration::from_millis(u64::from(timeout_ms)));
        }
        state = match relock_after_observe(auth, request, out, owner, lease, false) {
            Ok(state) => state,
            Err(Some(())) => {
                if let Ok(mut inner) = auth.shared.inner.lock() {
                    inner.events.unregister_waiter(&waiter);
                }
                return Some(owner_hold(hold));
            }
            Err(None) => {
                if let Ok(mut inner) = auth.shared.inner.lock() {
                    inner.events.unregister_waiter(&waiter);
                }
                return None;
            }
        };
        let _ = wait_ms;
    }
}

fn dispatch_operation_get(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    params: &crate::contract::OperationParams,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let connection_key = lease.map(|item| item.connection_key());
    if let Some(view) = state.replay.lookup(&params.operation_id) {
        if !replay_actor_matches(view.actor, owner, lease) {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::PermissionDenied,
            )?;
            return Some(owner_ok());
        }
    }
    let Some(hold) = occupy_observation(&mut state, request, canonical, owner, connection_key) else {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(owner_ok());
    };
    let data = if find_observation(
        &state,
        &validated_key(params.operation_id.as_str()),
    )
    .is_some_and(|slot| {
        observation_matches_caller(slot, owner, lease)
            && slot.operation_key != Some(hold.operation_key)
    }) {
        run_service::operation_get_in_progress(params.operation_id.clone())
    } else if let Some(view) = state.replay.lookup(&params.operation_id) {
        match view.phase {
            ReplayPhaseView::Preparing => {
                run_service::operation_get_in_progress(params.operation_id.clone())
            }
            ReplayPhaseView::Done => {
                let pool = if owner {
                    AllocationPool::ActiveOwner
                } else {
                    AllocationPool::ActivePublic
                };
                let scratch = view
                    .canonical
                    .len()
                    .checked_add(view.terminal.len())
                    .filter(|bytes| *bytes > 0)
                    .unwrap_or(1);
                match auth.shared.allocations.claim(pool, scratch) {
                    Err(_) => {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        return Some(owner_hold(hold));
                    }
                    Ok(charge) => {
                        let projected = crate::contract::parse_request(view.canonical).and_then(
                            |original| crate::contract::parse_response(&original, view.terminal),
                        );
                        drop(charge);
                        match projected {
                            Ok(response) if response.accepted => {
                                run_service::operation_get_completed(
                                    params.operation_id.clone(),
                                    crate::contract::Outcome::Succeeded,
                                    None,
                                )
                            }
                            Ok(response) => match response.error.0.as_ref().map(|error| error.code()) {
                                Some(code) => run_service::operation_get_completed(
                                    params.operation_id.clone(),
                                    crate::contract::Outcome::Failed,
                                    Some(code),
                                ),
                                None => {
                                    write_error(
                                        out,
                                        request,
                                        &auth.shared.instance_id,
                                        state.event_seq(),
                                        topology,
                                        ErrorCode::RuntimeFailed,
                                    )?;
                                    return Some(owner_hold(hold));
                                }
                            },
                            Err(_) => {
                                write_error(
                                    out,
                                    request,
                                    &auth.shared.instance_id,
                                    state.event_seq(),
                                    topology,
                                    ErrorCode::RuntimeFailed,
                                )?;
                                return Some(owner_hold(hold));
                            }
                        }
                    }
                }
            }
        }
    } else {
        run_service::operation_get_unknown(params.operation_id.clone())
    };
    write_success_data(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        topology,
        crate::contract::Success::OperationGet(data),
    )?;
    Some(owner_hold(hold))
}

fn artifact_error(
    auth: &Authorization,
    state: &mut State,
    request: &Request,
    out: &mut ChargedVec<u8>,
    code: ErrorCode,
    retained: bool,
    hold: Option<ObservationHold>,
) -> Option<OwnerDispatch> {
    write_error(out, request, &auth.shared.instance_id, state.event_seq(), state.topology_revision, code)?;
    if retained { seal_terminal(state, request, out, false)?; }
    Some(hold.map_or_else(owner_ok, owner_hold))
}

fn artifact_authorized(
    state: &State,
    owner: bool,
    lease: Option<&ConnectionLease>,
    project_id: &ProjectId,
) -> bool {
    owner || (public_has_scope(state, lease, Scope::ReadOutput)
        && lease.is_some_and(|lease| admitted_project(state, false, Some(lease), project_id)))
}

fn artifact_request_reserved(
    state: &State,
    request: &Request,
    canonical: &[u8],
    retained: bool,
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> bool {
    if retained {
        return state.replay.lookup(&request.operation_id).is_some_and(|slot| {
            matches!(slot.phase, ReplayPhaseView::Preparing)
                && slot.canonical == canonical
                && replay_actor_matches(slot.actor, owner, lease)
        });
    }
    find_observation(state, &validated_key(request.operation_id.as_str()))
        .is_some_and(|slot| &slot.canonical[..] == canonical && observation_matches_caller(slot, owner, lease))
}

fn write_artifact_success(
    state: &mut State,
    out: &mut ChargedVec<u8>,
    request: &Request,
    instance_id: &InstanceId,
    success: Success,
) -> Option<()> {
    #[cfg(debug_assertions)]
    if std::mem::take(&mut state.testing_fail_artifact_response_write) {
        return None;
    }
    write_success_data(
        out, request, instance_id, state.event_seq(), state.topology_revision, success,
    )
}

struct DiffObservation {
    _source: crate::store::root_identity::ObservedFile,
    _snapshot: crate::service::git_snapshot::CapturedRepository,
    _current: crate::store::root_identity::ObservedFile,
    result: (crate::contract::FileKind, Nullable<String>, bool),
}

#[cfg(debug_assertions)]
fn pause_after_git_diff_for_test() -> Result<(), ErrorCode> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenEventW, SetEvent, WaitForSingleObject, INFINITE};

    struct TestHandle(windows_sys::Win32::Foundation::HANDLE);
    impl Drop for TestHandle {
        fn drop(&mut self) { if !self.0.is_null() { unsafe { CloseHandle(self.0); } } }
    }
    let (ready, release) = match (
        std::env::var_os("WINSMUX_TASK867_DIFF_READY_EVENT"),
        std::env::var_os("WINSMUX_TASK867_DIFF_RELEASE_EVENT"),
    ) {
        (None, None) => return Ok(()),
        (Some(ready), Some(release)) => (ready, release),
        _ => return Err(ErrorCode::RuntimeFailed),
    };
    let ready = ready.encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let release = release.encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let ready = TestHandle(unsafe { OpenEventW(0x0002, 0, ready.as_ptr()) });
    let release = TestHandle(unsafe { OpenEventW(0x0010_0000, 0, release.as_ptr()) });
    if ready.0.is_null() || release.0.is_null() { return Err(ErrorCode::RuntimeFailed); }
    if unsafe { SetEvent(ready.0) } == 0 { return Err(ErrorCode::RuntimeFailed); }
    if unsafe { WaitForSingleObject(release.0, INFINITE) } != 0 { return Err(ErrorCode::RuntimeFailed); }
    Ok(())
}

fn dispatch_artifact(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> Option<OwnerDispatch> {
    let pool = if owner { AllocationPool::ActiveOwner } else { AllocationPool::ActivePublic };
    if !owner && !public_has_scope(&state, lease, Scope::ReadOutput) {
        return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, None);
    }
    let project_id = match &request.action {
        Action::ArtifactRegister(params) => params.project_id.clone(),
        Action::ArtifactList(params) => params.project_id.clone(),
        Action::ArtifactRead(params) | Action::ArtifactDiff(params) => match state.artifacts.get(&params.artifact_id) {
            Some(entry) => entry.reference.project_id.clone(),
            None => return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None),
        },
        _ => return None,
    };
    if !artifact_authorized(&state, owner, lease, &project_id) {
        return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, None);
    }
    let Some(project) = state.workspace.get(&project_id) else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    let Some(path) = project.path.clone() else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    let Some(root_identity) = project.identity.clone() else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    match &request.action {
        Action::ArtifactRegister(params) => {
            if params.run_id.0.as_ref().is_some_and(|run| state.workspace.project_id_for_run(run).as_ref() != Some(&project_id)) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
            }
            let artifact_id = loop {
                let candidate = crate::contract::ArtifactId::new(uuid::Uuid::new_v4().to_string()).ok()?;
                if state.artifacts.get(&candidate).is_none() {
                    break candidate;
                }
            };
            let reference = crate::contract::ArtifactRef {
                artifact_id,
                project_id: project_id.clone(),
                relative_path: params.relative_path.clone(),
                run_id: params.run_id.clone(),
                association: Nullable(params.run_id.0.as_ref().map(|_| crate::contract::Association::CallerSelected)),
            };
            let charge = match state.artifacts.reserve_entry(&auth.shared.allocations, pool, &reference) {
                Ok(charge) => charge,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, None),
            };
            if occupy_runtime_effect(
                &mut state, &auth.shared.allocations, request, canonical, owner, lease,
                Some(&project_id), &[Scope::ReadOutput],
            ).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            }
            let epoch = state.artifacts.epoch();
            drop(state);
            let observed = artifact_service::open(&path, &root_identity, params.relative_path.as_str(), &auth.shared.allocations, pool);
            let mut state = match relock_after_observe(auth, request, out, owner, lease, true) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_ok()),
                Err(None) => return None,
            };
            let observed = match observed {
                Ok(file) => file,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, true, None),
            };
            if state.artifacts.epoch() != epoch || !state.workspace.get(&project_id).is_some_and(|project| project.identity.as_ref() == Some(&root_identity) && project.path.as_deref() == Some(path.as_str())) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, true, None);
            }
            if !artifact_request_reserved(&state, request, canonical, true, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, None);
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, true, None);
            }
            if params.run_id.0.as_ref().is_some_and(|run| state.workspace.project_id_for_run(run).as_ref() != Some(&project_id)) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, true, None);
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)]) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, true, None);
            }
            if write_artifact_success(&mut state, out, request, &auth.shared.instance_id,
                Success::ArtifactRegister(crate::contract::ArtifactRegisterData { artifact: reference.clone() })).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, true, None);
            }
            if state.artifacts.publish(reference, root_identity, observed.identity, charge).is_err() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, true, None);
            }
            seal_terminal(&mut state, request, out, false)?;
            Some(owner_ok())
        }
        Action::ArtifactList(_) => {
            let Some(hold) = occupy_observation(&mut state, request, canonical, owner, lease.map(ConnectionLease::connection_key)) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            };
            let epoch = state.artifacts.epoch();
            let count = state.artifacts.project_entries(&project_id).count();
            let bytes = state.artifacts.project_entries(&project_id)
                .try_fold(count.checked_mul(std::mem::size_of::<crate::contract::ArtifactRef>())?, |sum, entry| {
                    sum.checked_add(entry.reference.owned_capacity())
                })?;
            let _charge = match auth.shared.allocations.claim(pool, bytes) {
                Ok(charge) => charge,
                Err(_) => return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold)),
            };
            let mut refs = Vec::new();
            if refs.try_reserve_exact(count).is_err() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            refs.extend(state.artifacts.project_entries(&project_id).map(|entry| entry.reference.clone()));
            let _snapshot_charge = match auth.shared.allocations.claim(pool, crate::contract::MAX_MESSAGE_BYTES) {
                Ok(charge) => charge,
                Err(_) => return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold)),
            };
            drop(state);
            let observed = (|| -> Result<_, ErrorCode> {
                let empty = || crate::contract::StringSet::new(Vec::new()).map_err(|_| ErrorCode::ResourceExhausted);
                let softened = |code| match code {
                    ErrorCode::ResourceExhausted => crate::contract::Nullable(Some(crate::contract::GitCandidatesError::ResourceExhausted)),
                    ErrorCode::UnsupportedFile => crate::contract::Nullable(Some(crate::contract::GitCandidatesError::UnsupportedFile)),
                    _ => crate::contract::Nullable(None),
                };
                let snapshot = match crate::service::git_snapshot::CapturedRepository::capture(
                    &path, &root_identity, &auth.shared.allocations, pool,
                ) {
                    Ok(snapshot) => snapshot,
                    Err(crate::service::git_snapshot::CaptureFailure::Walk(code @ (ErrorCode::ResourceExhausted | ErrorCode::UnsupportedFile))) => {
                        return Ok((None, empty()?, softened(code), Some(code)));
                    }
                    Err(failure) => return Err(failure.code()),
                };
                let candidates = match &snapshot {
                    None => empty()?,
                    Some(snapshot) => snapshot.candidates(&auth.shared.git_supervisor, || {
                        let state = auth.shared.inner.lock().unwrap();
                        state.artifacts.epoch() != epoch
                            || !artifact_authorized(&state, owner, lease, &project_id)
                            || !artifact_request_reserved(&state, request, canonical, false, owner, lease)
                    })?,
                };
                Ok((snapshot, candidates, crate::contract::Nullable(None), None))
            })();
            let observed_root = crate::store::root_identity::observe_root(&path, &auth.shared.allocations, pool);
            let mut state = match relock_after_observe(auth, request, out, owner, lease, false) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_hold(hold)),
                Err(None) => return None,
            };
            let (_captured_repository, candidates, git_candidates_error, walk_code) = match observed {
                Ok(observed) => observed,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            let _observed_root = match observed_root {
                Ok(root) if root.identity == root_identity => root,
                _ => return artifact_error(auth, &mut state, request, out, walk_code.unwrap_or(ErrorCode::RootChanged), false, Some(hold)),
            };
            if !state.workspace.get(&project_id).is_some_and(|project| project.identity.as_ref() == Some(&root_identity) && project.path.as_deref() == Some(path.as_str())) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)]) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            if state.artifacts.epoch() != epoch || !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, Some(hold));
            }
            if !artifact_request_reserved(&state, request, canonical, false, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            let data = crate::contract::ArtifactListData {
                registered: refs,
                git_candidates: candidates,
                git_candidates_error,
            };
            if write_artifact_success(&mut state, out, request, &auth.shared.instance_id, Success::ArtifactList(data)).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            Some(owner_hold(hold))
        }
        Action::ArtifactRead(params) => {
            let Some(hold) = occupy_observation(&mut state, request, canonical, owner, lease.map(ConnectionLease::connection_key)) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            };
            let Some(entry) = state.artifacts.get(&params.artifact_id) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, Some(hold));
            };
            let relative = entry.reference.relative_path.clone();
            let identity = entry.file_identity.clone();
            if entry.root_identity != root_identity {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            let epoch = entry.epoch;
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)]) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            drop(state);
            let observed = artifact_service::open(&path, &root_identity, relative.as_str(), &auth.shared.allocations, pool);
            let mut state = match relock_after_observe(auth, request, out, owner, lease, false) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_hold(hold)),
                Err(None) => return None,
            };
            let file = match observed {
                Ok(file) => file,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            if file.identity != identity {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if state.artifacts.epoch() != epoch || state.artifacts.get(&params.artifact_id).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, Some(hold));
            }
            if !state.workspace.get(&project_id).is_some_and(|project| project.identity.as_ref() == Some(&root_identity) && project.path.as_deref() == Some(path.as_str())) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if !artifact_request_reserved(&state, request, canonical, false, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, Some(hold));
            }
            let frame_budget = match artifact_read_text_budget(
                request, &auth.shared.instance_id, state.event_seq(), state.topology_revision,
                &params.artifact_id, file.size_bytes,
            ) {
                Ok(budget) => budget,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            drop(state);
            let preview = artifact_preview(
                &file,
                &params.artifact_id,
                params.max_bytes.get(),
                frame_budget,
                &auth.shared.allocations,
                pool,
            );
            let mut state = match relock_after_observe(auth, request, out, owner, lease, false) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_hold(hold)),
                Err(None) => return None,
            };
            let (data, _preview_charge) = match preview {
                Ok(data) => data,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            if state.artifacts.epoch() != epoch || state.artifacts.get(&params.artifact_id).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, Some(hold));
            }
            if !state.workspace.get(&project_id).is_some_and(|project| project.identity.as_ref() == Some(&root_identity) && project.path.as_deref() == Some(path.as_str())) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if !artifact_request_reserved(&state, request, canonical, false, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, Some(hold));
            }
            if write_artifact_success(&mut state, out, request, &auth.shared.instance_id, Success::ArtifactRead(data)).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            Some(owner_hold(hold))
        }
        Action::ArtifactDiff(params) => {
            let Some(hold) = occupy_observation(&mut state, request, canonical, owner, lease.map(ConnectionLease::connection_key)) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            };
            let Some(entry) = state.artifacts.get(&params.artifact_id) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, Some(hold));
            };
            if entry.root_identity != root_identity {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            let relative = entry.reference.relative_path.clone();
            let identity = entry.file_identity.clone();
            let epoch = state.artifacts.epoch();
            let _snapshot_charge = match auth.shared.allocations.claim(pool, crate::contract::MAX_MESSAGE_BYTES) {
                Ok(charge) => charge,
                Err(_) => return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold)),
            };
            drop(state);
            let difference = (|| -> Result<DiffObservation, ErrorCode> {
                let source = artifact_service::open(
                    &path, &root_identity, relative.as_str(), &auth.shared.allocations, pool,
                )?;
                if source.identity != identity { return Err(ErrorCode::RootChanged); }
                let Some(snapshot) = crate::service::git_snapshot::CapturedRepository::new(
                    &path, &root_identity, &auth.shared.allocations, pool,
                )? else { return Err(ErrorCode::NotARepository) };
                let result = snapshot.diff(
                    &auth.shared.git_supervisor,
                    &relative,
                    usize::try_from(params.max_bytes.get()).unwrap_or(usize::MAX),
                    || {
                        let state = auth.shared.inner.lock().unwrap();
                        state.artifacts.epoch() != epoch
                            || !artifact_authorized(&state, owner, lease, &project_id)
                            || !artifact_request_reserved(&state, request, canonical, false, owner, lease)
                    },
                )?;
                let current = artifact_service::open(
                    &path, &root_identity, relative.as_str(), &auth.shared.allocations, pool,
                )?;
                if current.identity != identity { return Err(ErrorCode::RootChanged); }
                snapshot.verify_selected(&relative, &current)?;
                Ok(DiffObservation { _source: source, _snapshot: snapshot, _current: current, result })
            })().and_then(|observation| {
                #[cfg(debug_assertions)]
                pause_after_git_diff_for_test()?;
                Ok(observation)
            });
            let mut state = match relock_after_observe(auth, request, out, owner, lease, false) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_hold(hold)),
                Err(None) => return None,
            };
            let observation = match difference {
                Ok(observation) => observation,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            if state.artifacts.epoch() != epoch || state.artifacts.get(&params.artifact_id).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, Some(hold));
            }
            if !state.workspace.get(&project_id).is_some_and(|project| project.identity.as_ref() == Some(&root_identity) && project.path.as_deref() == Some(path.as_str())) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if !artifact_request_reserved(&state, request, canonical, false, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, Some(hold));
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)]) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            let (kind, text, truncated) = observation.result;
            let mut data = crate::contract::ArtifactDiffData {
                artifact_id: params.artifact_id.clone(), kind, text, truncated,
            };
            if let Err(code) = trim_artifact_diff_data(
                request, &auth.shared.instance_id, state.event_seq(), state.topology_revision,
                &mut data,
            ) {
                return artifact_error(auth, &mut state, request, out, code, false, Some(hold));
            }
            if write_artifact_success(&mut state, out, request, &auth.shared.instance_id, Success::ArtifactDiff(data)).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            Some(owner_hold(hold))
        }
        _ => None,
    }
}

struct ChoiceFileCheck {
    relative_path: crate::contract::RelativePath,
    identity: crate::contract::RootIdentity,
}

fn choice_file_check(
    state: &State,
    project_id: &ProjectId,
    root: &crate::contract::RootIdentity,
    id: &crate::contract::ArtifactId,
) -> Result<ChoiceFileCheck, ErrorCode> {
    let entry = state.artifacts.get(id).ok_or(ErrorCode::TargetNotFound)?;
    if &entry.reference.project_id != project_id {
        return Err(ErrorCode::TargetNotFound);
    }
    if &entry.root_identity != root {
        return Err(ErrorCode::RootChanged);
    }
    Ok(ChoiceFileCheck {
        relative_path: entry.reference.relative_path.clone(),
        identity: entry.file_identity.clone(),
    })
}

fn observe_choice_files(
    project_path: &str,
    root: &crate::contract::RootIdentity,
    checks: &[ChoiceFileCheck],
    allocations: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<Vec<crate::store::root_identity::ObservedFile>, ErrorCode> {
    let mut files = Vec::new();
    files.try_reserve_exact(checks.len()).map_err(|_| ErrorCode::ResourceExhausted)?;
    for check in checks {
        let file = artifact_service::open(
            project_path, root, check.relative_path.as_str(), allocations, pool,
        )?;
        if file.identity != check.identity {
            return Err(ErrorCode::RootChanged);
        }
        files.push(file);
    }
    Ok(files)
}

fn dispatch_artifact_choice(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> Option<OwnerDispatch> {
    let pool = if owner { AllocationPool::ActiveOwner } else { AllocationPool::ActivePublic };
    let project_id = match &request.action {
        Action::ArtifactChoose(params) => params.project_id.clone(),
        Action::ArtifactChoiceList(params) => params.project_id.clone(),
        _ => return None,
    };
    if matches!(request.action, Action::ArtifactChoose(_)) && !owner {
        return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, None);
    }
    if !artifact_authorized(&state, owner, lease, &project_id) {
        return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, None);
    }
    let Some(project) = state.workspace.get(&project_id) else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    let Some(path) = project.path.clone() else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    let Some(root) = project.identity.clone() else {
        return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, false, None);
    };
    match &request.action {
        Action::ArtifactChoose(params) => {
            if params.left_artifact_id == params.right_artifact_id
                || (params.kept_artifact_id != params.left_artifact_id
                    && params.kept_artifact_id != params.right_artifact_id)
            {
                return artifact_error(auth, &mut state, request, out, ErrorCode::InvalidRequest, false, None);
            }
            let (left, right) = if params.left_artifact_id < params.right_artifact_id {
                (&params.left_artifact_id, &params.right_artifact_id)
            } else {
                (&params.right_artifact_id, &params.left_artifact_id)
            };
            let choice = crate::contract::ArtifactChoiceData {
                left_artifact_id: left.clone(),
                right_artifact_id: right.clone(),
                kept_artifact_id: params.kept_artifact_id.clone(),
            };
            let checks = match (
                choice_file_check(&state, &project_id, &root, left),
                choice_file_check(&state, &project_id, &root, right),
            ) {
                (Ok(left), Ok(right)) => [left, right],
                (Err(code), _) | (_, Err(code)) =>
                    return artifact_error(auth, &mut state, request, out, code, false, None),
            };
            let check_bytes = checks.iter().try_fold(0usize, |sum, check| {
                sum.checked_add(std::mem::size_of::<ChoiceFileCheck>())
                    .and_then(|sum| sum.checked_add(check.relative_path.owned_capacity()))
                    .and_then(|sum| sum.checked_add(check.identity.owned_capacity()))
            });
            let Some(check_bytes) = check_bytes else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            };
            let _check_charge = match auth.shared.allocations.claim(pool, check_bytes) {
                Ok(charge) => charge,
                Err(_) => return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None),
            };
            let charge = match state.artifacts.reserve_choice(
                &auth.shared.allocations, pool, &project_id, &choice,
            ) {
                Ok(charge) => charge,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, None),
            };
            if occupy_runtime_effect(
                &mut state, &auth.shared.allocations, request, canonical, owner, lease,
                Some(&project_id), &[Scope::ReadOutput],
            ).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            }
            let epoch = state.artifacts.epoch();
            drop(state);
            let observed = observe_choice_files(&path, &root, &checks, &auth.shared.allocations, pool);
            let mut state = match relock_after_observe(auth, request, out, owner, lease, true) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_ok()),
                Err(None) => return None,
            };
            let _held_files = match observed {
                Ok(files) => files,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, true, None),
            };
            if state.artifacts.epoch() != epoch
                || !state.workspace.get(&project_id).is_some_and(|project| {
                    project.identity.as_ref() == Some(&root) && project.path.as_deref() == Some(path.as_str())
                })
            {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, true, None);
            }
            if !artifact_request_reserved(&state, request, canonical, true, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, None);
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, true, None);
            }
            for id in [left, right] {
                if state.artifacts.get(id).is_none() {
                    return artifact_error(auth, &mut state, request, out, ErrorCode::TargetNotFound, true, None);
                }
            }
            if write_artifact_success(
                &mut state, out, request, &auth.shared.instance_id,
                Success::ArtifactChoose(choice.clone()),
            ).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, true, None);
            }
            if state.artifacts.publish_choice(project_id, choice, charge).is_err() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, true, None);
            }
            seal_terminal(&mut state, request, out, false)?;
            Some(owner_ok())
        }
        Action::ArtifactChoiceList(_) => {
            let Some(hold) = occupy_observation(
                &mut state, request, canonical, owner, lease.map(ConnectionLease::connection_key),
            ) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, None);
            };
            let epoch = state.artifacts.epoch();
            let count = state.artifacts.project_choices(&project_id).count();
            let Some(base_bytes) = count.checked_mul(std::mem::size_of::<crate::contract::ArtifactChoiceData>()
                + 2 * std::mem::size_of::<ChoiceFileCheck>()) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            };
            let bytes = state.artifacts.project_choices(&project_id).try_fold(
                base_bytes,
                |sum, entry| {
                    let mut sum = sum;
                    sum = sum.checked_add(entry.choice.owned_capacity()).ok_or(ErrorCode::ResourceExhausted)?;
                    for id in [&entry.choice.left_artifact_id, &entry.choice.right_artifact_id] {
                        let file = state.artifacts.get(id).ok_or(ErrorCode::TargetNotFound)?;
                        sum = sum.checked_add(file.reference.relative_path.owned_capacity())
                            .and_then(|sum| sum.checked_add(file.file_identity.owned_capacity()))
                            .ok_or(ErrorCode::ResourceExhausted)?;
                    }
                    Ok(sum)
                },
            );
            let bytes = match bytes {
                Ok(bytes) => bytes,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            let _charge = match auth.shared.allocations.claim(pool, bytes) {
                Ok(charge) => charge,
                Err(_) => return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold)),
            };
            let mut choices = Vec::new();
            let mut checks = Vec::new();
            let Some(file_count) = count.checked_mul(2) else {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            };
            if choices.try_reserve_exact(count).is_err() || checks.try_reserve_exact(file_count).is_err() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            let copied: Result<(), ErrorCode> = state.artifacts.project_choices(&project_id).try_for_each(|entry| {
                let left = choice_file_check(&state, &project_id, &root, &entry.choice.left_artifact_id)?;
                let right = choice_file_check(&state, &project_id, &root, &entry.choice.right_artifact_id)?;
                choices.push(entry.choice.clone());
                checks.push(left);
                checks.push(right);
                Ok(())
            });
            if let Err(code) = copied {
                return artifact_error(auth, &mut state, request, out, code, false, Some(hold));
            }
            choices.sort_by(|a, b| {
                (&a.left_artifact_id, &a.right_artifact_id)
                    .cmp(&(&b.left_artifact_id, &b.right_artifact_id))
            });
            drop(state);
            let observed = observe_choice_files(&path, &root, &checks, &auth.shared.allocations, pool);
            let mut state = match relock_after_observe(auth, request, out, owner, lease, false) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_hold(hold)),
                Err(None) => return None,
            };
            let _held_files = match observed {
                Ok(files) => files,
                Err(code) => return artifact_error(auth, &mut state, request, out, code, false, Some(hold)),
            };
            if state.artifacts.epoch() != epoch
                || !state.workspace.get(&project_id).is_some_and(|project| {
                    project.identity.as_ref() == Some(&root) && project.path.as_deref() == Some(path.as_str())
                })
            {
                return artifact_error(auth, &mut state, request, out, ErrorCode::RootChanged, false, Some(hold));
            }
            if !artifact_authorized(&state, owner, lease, &project_id) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::PermissionDenied, false, Some(hold));
            }
            if !artifact_request_reserved(&state, request, canonical, false, owner, lease) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            if state.artifacts.project_choices(&project_id).count() != count
                || choices.iter().any(|choice| {
                    state.artifacts.choice(
                        &project_id, &choice.left_artifact_id, &choice.right_artifact_id,
                    ).is_none_or(|current| current.choice != *choice)
                })
            {
                return artifact_error(auth, &mut state, request, out, ErrorCode::StateUnknown, false, Some(hold));
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)]) {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            if write_artifact_success(
                &mut state, out, request, &auth.shared.instance_id,
                Success::ArtifactChoiceList(crate::contract::ArtifactChoiceListData { choices }),
            ).is_none() {
                return artifact_error(auth, &mut state, request, out, ErrorCode::ResourceExhausted, false, Some(hold));
            }
            Some(owner_hold(hold))
        }
        _ => None,
    }
}

fn artifact_preview(
    file: &crate::store::root_identity::ObservedFile,
    artifact_id: &crate::contract::ArtifactId,
    max_bytes: u64,
    frame_budget: usize,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<(crate::contract::ArtifactReadData, CapacityCharge), ErrorCode> {
    let size = U::new(file.size_bytes).map_err(|_| ErrorCode::UnsupportedFile)?;
    let cap = usize::try_from(max_bytes).unwrap_or(usize::MAX)
        .min(usize::try_from(file.size_bytes).unwrap_or(usize::MAX))
        .min(MAX_MESSAGE_BYTES);
    let mut raw = ChargedVec::<u8>::with_capacity(authority, pool, cap, cap)
        .map_err(|_| ErrorCode::ResourceExhausted)?;
    raw.try_resize(cap, 0).map_err(|_| ErrorCode::ResourceExhausted)?;
    let mut length = 0;
    while length < cap {
        let n = file.read(&mut raw[length..]).map_err(|error| error.code())?;
        if n == 0 { break; }
        length += n;
    }
    let bytes = &raw[..length];
    let text = match std::str::from_utf8(bytes) {
        Ok(text) if !text.contains('\0') => text,
        Err(error) if error.error_len().is_none() && (length as u64) < file.size_bytes => {
            std::str::from_utf8(&bytes[..error.valid_up_to()]).map_err(|_| ErrorCode::UnsupportedFile)?
        }
        _ => return Ok((crate::contract::ArtifactReadData {
            artifact_id: artifact_id.clone(),
            kind: crate::contract::FileKind::Binary,
            size_bytes: size,
            text: Nullable(None),
            truncated: false,
        }, authority.claim(pool, 0).map_err(|_| ErrorCode::ResourceExhausted)?)),
    };
    let mut encoded = 0usize;
    let mut end = 0usize;
    for ch in text.chars() {
        let cost = match ch {
            '"' | '\\' | '\n' | '\r' | '\t' | '\u{0008}' | '\u{000c}' => 2,
            '\u{0000}'..='\u{001f}' => 6,
            _ => ch.len_utf8(),
        };
        if encoded.checked_add(cost).is_none_or(|next| next > frame_budget) { break; }
        encoded += cost;
        end += ch.len_utf8();
    }
    let text_charge = authority.claim(pool, end).map_err(|_| ErrorCode::ResourceExhausted)?;
    let body = text[..end].to_owned();
    Ok((crate::contract::ArtifactReadData {
        artifact_id: artifact_id.clone(),
        kind: crate::contract::FileKind::Text,
        size_bytes: size,
        text: Nullable(Some(body)),
        truncated: (end as u64) < file.size_bytes,
    }, text_charge))
}

fn artifact_read_text_budget(
    request: &Request,
    instance_id: &InstanceId,
    event_seq: u64,
    topology: u64,
    artifact_id: &crate::contract::ArtifactId,
    size_bytes: u64,
) -> Result<usize, ErrorCode> {
    let mut measure = Measure(0);
    write_success_prefix(&mut measure, instance_text(request, instance_id), request.operation_id.as_str(), event_seq)
        .map_err(|_| ErrorCode::ResourceExhausted)?;
    Success::ArtifactRead(crate::contract::ArtifactReadData {
        artifact_id: artifact_id.clone(),
        kind: crate::contract::FileKind::Text,
        size_bytes: U::new(size_bytes).map_err(|_| ErrorCode::UnsupportedFile)?,
        text: Nullable(Some(String::new())),
        truncated: true,
    }).write_canonical(&mut measure).map_err(|_| ErrorCode::ResourceExhausted)?;
    write_success_suffix(&mut measure, topology).map_err(|_| ErrorCode::ResourceExhausted)?;
    MAX_MESSAGE_BYTES.checked_sub(measure.0).ok_or(ErrorCode::ResourceExhausted)
}

fn trim_artifact_diff_data(
    request: &Request,
    instance_id: &InstanceId,
    event_seq: u64,
    topology: u64,
    data: &mut crate::contract::ArtifactDiffData,
) -> Result<(), ErrorCode> {
    let Some(text) = data.text.0.as_mut() else { return Ok(()) };
    let mut measure = Measure(0);
    write_success_prefix(&mut measure, instance_text(request, instance_id), request.operation_id.as_str(), event_seq)
        .map_err(|_| ErrorCode::ResourceExhausted)?;
    Success::ArtifactDiff(crate::contract::ArtifactDiffData {
        artifact_id: data.artifact_id.clone(),
        kind: crate::contract::FileKind::Text,
        text: Nullable(Some(String::new())),
        truncated: true,
    }).write_canonical(&mut measure).map_err(|_| ErrorCode::ResourceExhausted)?;
    write_success_suffix(&mut measure, topology).map_err(|_| ErrorCode::ResourceExhausted)?;
    let budget = MAX_MESSAGE_BYTES.checked_sub(measure.0).ok_or(ErrorCode::ResourceExhausted)?;
    let mut encoded = 0usize;
    let mut end = 0usize;
    for ch in text.chars() {
        let cost = match ch {
            '"' | '\\' | '\n' | '\r' | '\t' | '\u{0008}' | '\u{000c}' => 2,
            '\u{0000}'..='\u{001f}' => 6,
            _ => ch.len_utf8(),
        };
        if encoded.checked_add(cost).is_none_or(|next| next > budget) { break; }
        encoded += cost;
        end += ch.len_utf8();
    }
    if end < text.len() {
        text.truncate(end);
        data.truncated = true;
    }
    Ok(())
}

fn dispatch_owner_runtime(
    auth: &Authorization,
    state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<OwnerDispatch> {
    dispatch_runtime(auth, state, request, canonical, out, true, None)
}

fn dispatch_client_runtime(
    auth: &Authorization,
    state: std::sync::MutexGuard<'_, State>,
    lease: &ConnectionLease,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
) -> Option<ClientDispatch> {
    dispatch_runtime(auth, state, request, canonical, out, false, Some(lease)).map(|reply| {
        ClientDispatch {
            observation: reply.observation,
        }
    })
}

fn pane_rows_in_id_order(
    panes: &crate::runtime::topology::ProjectPanes,
) -> Vec<(crate::contract::PaneId, Option<crate::contract::RunId>)> {
    let mut rows: Vec<_> = panes
        .panes
        .iter()
        .map(|pane| (pane.id.clone(), pane.current_run.clone()))
        .collect();
    rows.sort_by(|left, right| left.0.as_str().cmp(right.0.as_str()));
    rows
}

fn dispatch_runtime(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let decision = admit_runtime(&state, owner, lease, request);
    if let AdmissionDecision::Deny {
        code: ErrorCode::PermissionDenied,
        ..
    } = &decision
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::PermissionDenied,
        )?;
        return Some(owner_ok());
    }
    let connection_key = lease.map(|item| item.connection_key());
    match &request.action {
        Action::PaneList(params) => {
            let Some(hold) =
                occupy_observation(&mut state, request, canonical, owner, connection_key)
            else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            };
            if admitted_ref(&decision).is_none() {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                return Some(owner_hold(hold));
            }
            if !owner
                && !queue_public_keys(
                    &mut state,
                    &auth.shared.allocations,
                    lease,
                    &[key_of(&params.project_id)],
                )
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_hold(hold));
            }
            let Some(project) = state.workspace.get(&params.project_id) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_hold(hold));
            };
            let path = project.path.clone();
            let root = project.panes.root.clone();
            let selected = project.panes.selected_pane_id.clone();
            let pane_rows = pane_rows_in_id_order(&project.panes);
            let read_output = owner || public_has_scope(&state, lease, Scope::ReadOutput);
            let panes = pane_rows
                .into_iter()
                .map(|(pane_id, current_run)| crate::contract::PaneSummary {
                    pane_id: pane_id.clone(),
                    project_id: params.project_id.clone(),
                    current_run_id: crate::contract::Nullable(current_run.clone()),
                    observation: crate::contract::Nullable(current_run.map(|run| {
                        match state.runtime.observation(&run) {
                            Ok((process, work, code, current)) => {
                                live_observation(run, pane_id.clone(), process, work, code, current)
                            }
                            Err(_) => dummy_observation(run, pane_id.clone()),
                        }
                    })),
                    display_name: crate::contract::Nullable(None),
                    path: crate::contract::Nullable(if read_output {
                        path.clone()
                    } else {
                        None
                    }),
                })
                .collect();
            write_success_data(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                crate::contract::Success::PaneList(crate::contract::PaneListData {
                    project_id: params.project_id.clone(),
                    panes,
                    root: crate::contract::Nullable(root),
                    selected_pane_id: crate::contract::Nullable(selected),
                }),
            )?;
            Some(owner_hold(hold))
        }
        Action::PaneSelect(params) => {
            if occupy_decision_effect(
                &mut state,
                &auth.shared.allocations,
                request,
                canonical,
                owner,
                lease,
                &decision,
            )
            .is_none()
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            }
            let Some(admitted) = admitted_ref(&decision) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            };
            let pane_id = params.pane_id.0.clone();
            let project_id = admitted.project_id.clone();
            let root_target = pane_id.as_ref().and_then(|_| {
                project_id.as_ref().and_then(|id| {
                    state.workspace.get(id).and_then(|project| {
                        Some((project.path.clone()?, project.identity.clone()?))
                    })
                })
            });
            if pane_id.is_some() && root_target.is_none() {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            drop(state);
            let observed_root = root_target.as_ref().map(|(path, identity)| {
                reobserve_state(
                    path,
                    identity,
                    &auth.shared.allocations,
                    if owner { AllocationPool::ActiveOwner } else { AllocationPool::ActivePublic },
                )
            });
            let mut state = match relock_after_observe(auth, request, out, owner, lease, true) {
                Ok(state) => state,
                Err(Some(())) => return Some(owner_ok()),
                Err(None) => return None,
            };
            let topology = state.topology_revision;
            let current_decision = admit_runtime(&state, owner, lease, request);
            let still_admitted = admitted_ref(&current_decision).is_some_and(|current| {
                current.project_id == project_id && current.pane_id == pane_id
            });
            let same_root = root_target.as_ref().is_none_or(|(path, identity)| {
                project_id.as_ref().and_then(|id| state.workspace.get(id)).is_some_and(|project| {
                    project.path.as_ref() == Some(path) && project.identity.as_ref() == Some(identity)
                })
            });
            if !still_admitted || !same_root {
                let code = denied_code(&current_decision).unwrap_or(ErrorCode::TargetNotFound);
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    code,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            if let Some(root) = observed_root {
                let code = match root {
                    RootState::Verified => None,
                    RootState::Unavailable => Some(ErrorCode::TargetNotFound),
                    RootState::Changed => Some(ErrorCode::RootChanged),
                    RootState::Unknown => Some(ErrorCode::PermissionDenied),
                };
                if let Some(code) = code {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            }
            let outcome = match state.workspace.classify_selection(
                project_id.as_ref(),
                pane_id.as_ref(),
                expected_revision(request),
                topology,
            ) {
                Ok(outcome) => outcome,
                Err(code) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            };
            if matches!(outcome, SelectOutcome::Changed) && !can_layout_change(&state) {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            if !owner {
                let Some(id) = project_id.as_ref() else {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::PermissionDenied,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                };
                if !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(id)]) {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            }
            let credit = if matches!(outcome, SelectOutcome::Changed) {
                match state.events.try_reserve(&auth.shared.allocations, 1) {
                    Ok(credit) => Some(credit),
                    Err(_) => {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        return Some(owner_ok());
                    }
                }
            } else {
                None
            };
            state.workspace.apply_selection(project_id.as_ref(), pane_id.as_ref());
            if let Some(credit) = credit {
                bump_topology(&mut state);
                publish_topology_change(
                    &auth.shared.allocations,
                    &mut state,
                    credit,
                    project_id,
                    pane_id,
                );
            }
            let selected_project_id = state.workspace.selected().cloned();
            let selected_pane_id = state.workspace.selected_pane().cloned();
            write_success_data(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                crate::contract::Success::PaneSelect(crate::contract::Selection {
                    selected_project_id: crate::contract::Nullable(selected_project_id),
                    selected_pane_id: crate::contract::Nullable(selected_pane_id),
                }),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(owner_ok())
        }
        Action::PaneClose(params) => {
            if occupy_decision_effect(
                &mut state,
                &auth.shared.allocations,
                request,
                canonical,
                owner,
                lease,
                &decision,
            )
            .is_none()
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            }
            let Some(admitted) = admitted_ref(&decision) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            };
            let Some(project_id) = admitted.project_id.clone() else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            };
            if let Some(code) = topology_denial(request, &state) {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    code,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            if let Some(pane) = state
                .workspace
                .panes(&project_id)
                .and_then(|panes| panes.pane(&params.pane_id))
            {
                if run_service::close_blocked_for_runs(
                    &state.runtime,
                    pane.previous_runs.iter().chain(pane.current_run.iter()),
                ) {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::AlreadyRunning,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            let credit = match state.events.try_reserve(&auth.shared.allocations, 1) {
                Ok(credit) => credit,
                Err(_) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            };
            match state
                .workspace
                .close_pane_layout(&project_id, &params.pane_id)
            {
                Ok(_) => {
                    let selected = state
                        .workspace
                        .panes(&project_id)
                        .and_then(|panes| panes.selected_pane_id.clone());
                    bump_topology(&mut state);
                    publish_topology_change(
                        &auth.shared.allocations,
                        &mut state,
                        credit,
                        Some(project_id.clone()),
                        Some(params.pane_id.clone()),
                    );
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        state.topology_revision,
                        crate::contract::Success::PaneClose(crate::contract::PaneCloseData {
                            pane_id: params.pane_id.clone(),
                            closed: crate::contract::True,
                            selected_pane_id: crate::contract::Nullable(selected),
                        }),
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    Some(owner_ok())
                }
                Err(code) => {
                    state.events.release(credit);
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    Some(owner_ok())
                }
            }
        }
        Action::PaneResize(params) => {
            dispatch_resize_payload(auth, state, request, canonical, out, owner, lease, params)
        }
        Action::RunGet(params) => {
            let Some(hold) =
                occupy_observation(&mut state, request, canonical, owner, connection_key)
            else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            };
            let Some(admitted) = admitted_ref(&decision) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                return Some(owner_hold(hold));
            };
            let Some(pane_id) = admitted.pane_id.clone() else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_hold(hold));
            };
            let Some(project_id) = admitted.project_id.clone() else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_hold(hold));
            };
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_hold(hold));
            }
            match state.runtime.observation(&params.run_id) {
                Ok((process, work, code, current)) => {
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        crate::contract::Success::RunGet(crate::contract::RunGetData {
                            cleanup_complete: params.include_cleanup.map(|_| run_service::cleanup_confirmed(
                                process, state.runtime.session_clean(&params.run_id),
                            )),
                            run: live_observation(
                                params.run_id.clone(),
                                pane_id,
                                process,
                                work,
                                code,
                                current,
                            ),
                        }),
                    )?;
                    Some(owner_hold(hold))
                }
                Err(code) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    Some(owner_hold(hold))
                }
            }
        }
        Action::RunInterrupt(params) => {
            if occupy_decision_effect(
                &mut state,
                &auth.shared.allocations,
                request,
                canonical,
                owner,
                lease,
                &decision,
            )
            .is_none()
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            }
            let Some(admitted) = admitted_ref(&decision) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            };
            let Some(project_id) = admitted.project_id.clone() else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            };
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            let credit = match state.events.try_reserve(&auth.shared.allocations, 1) {
                Ok(credit) => credit,
                Err(_) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            };
            match run_service::admit_stop_lane(&state.runtime, &params.run_id) {
                Ok(false) => {
                    state.events.release(credit);
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::NotRunning,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    Some(owner_ok())
                }
                Ok(true) => {
                    if let Some(pane_id) = pane_id_for_run(&state, &params.run_id) {
                        let (process, work, code, current) = state
                            .runtime
                            .observation(&params.run_id)
                            .unwrap_or((
                                crate::contract::Process::Running,
                                crate::contract::Work::Unknown,
                                None,
                                true,
                            ));
                        state.events.publish(
                            &auth.shared.allocations,
                            credit,
                            EventData::RunStateChanged {
                                run: live_observation(
                                    params.run_id.clone(),
                                    pane_id,
                                    process,
                                    work,
                                    code,
                                    current,
                                ),
                            },
                            now_or_epoch(),
                        );
                    } else {
                        state.events.release(credit);
                    }
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        crate::contract::Success::RunInterrupt(run_service::interrupt_accepted(
                            params.run_id.clone(),
                        )),
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    let runtime = std::sync::Arc::clone(&state.runtime);
                    drop(state);
                    run_service::queue_stop_cleanup(runtime.as_ref(), &params.run_id);
                    Some(owner_ok())
                }
                Err(code) => {
                    state.events.release(credit);
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    Some(owner_ok())
                }
            }
        }
        Action::OutputRead(params) => {
            let Some(hold) =
                occupy_observation(&mut state, request, canonical, owner, connection_key)
            else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_ok());
            };
            let Some(admitted) = admitted_ref(&decision) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    denied_code(&decision).unwrap_or(ErrorCode::TargetNotFound),
                )?;
                return Some(owner_hold(hold));
            };
            let Some(project_id) = admitted.project_id.clone() else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_hold(hold));
            };
            if admitted.pane_id.is_none() {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_hold(hold));
            }
            if !owner && !queue_public_keys(&mut state, &auth.shared.allocations, lease, &[key_of(&project_id)])
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::ResourceExhausted,
                )?;
                return Some(owner_hold(hold));
            }
            let cursor = params.cursor.0.as_ref().map(|value| value.as_str());
            match output_service::read_output(
                &state.runtime,
                &auth.shared.instance_id,
                &params.run_id,
                cursor,
                params.max_bytes.get(),
            ) {
                Ok(data) => {
                    write_success_data(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        crate::contract::Success::OutputRead(data),
                    )?;
                    Some(owner_hold(hold))
                }
                Err(code) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    Some(owner_hold(hold))
                }
            }
        }
        Action::InputWrite(params) => dispatch_run_payload(
            auth,
            state,
            request,
            canonical,
            out,
            owner,
            lease,
            params.pane_id.clone(),
            params.run_id.clone(),
            params.text.as_bytes().to_vec(),
            None,
        ),
        Action::InputKey(params) => dispatch_run_payload(
            auth,
            state,
            request,
            canonical,
            out,
            owner,
            lease,
            params.pane_id.clone(),
            params.run_id.clone(),
            run_service::key_payload(params.key).to_vec(),
            Some(params.key),
        ),
        Action::EventsWait(params) => {
            let grants = admitted_ref(&decision)
                .map(|admitted| admitted.grant_projects.clone())
                .unwrap_or_default();
            dispatch_events_wait(
                auth, state, request, canonical, out, owner, lease, params, grants,
            )
        }
        Action::OperationGet(params) => {
            dispatch_operation_get(auth, state, request, canonical, out, owner, lease, params)
        }
        Action::PaneCreate(params) => {
            if let Some(code) = denied_code(&decision) {
                if occupy_decision_effect(
                    &mut state,
                    &auth.shared.allocations,
                    request,
                    canonical,
                    owner,
                    lease,
                    &decision,
                )
                .is_none()
                {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    return Some(owner_ok());
                }
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    code,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            spawn_pane(
                auth,
                state,
                request,
                canonical,
                out,
                owner,
                lease,
                SpawnKind::Create {
                    project_id: params.project_id.clone(),
                    shell: params.shell_profile_id.as_str().to_owned(),
                },
            )
        }
        Action::PaneSplit(params) => {
            if let Some(code) = denied_code(&decision) {
                if occupy_decision_effect(
                    &mut state,
                    &auth.shared.allocations,
                    request,
                    canonical,
                    owner,
                    lease,
                    &decision,
                )
                .is_none()
                {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    return Some(owner_ok());
                }
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    code,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            let Some(project_id) = admitted_ref(&decision).and_then(|admitted| admitted.project_id.clone()) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_ok());
            };
            spawn_pane(
                auth,
                state,
                request,
                canonical,
                out,
                owner,
                lease,
                SpawnKind::Split {
                    project_id,
                    target: params.pane_id.clone(),
                    axis: params.axis,
                    shell: "pwsh".to_owned(),
                },
            )
        }
        Action::ShellLaunch(_) | Action::AgentLaunch(_) => {
            let pane_id = match &request.action {
                Action::ShellLaunch(params) => &params.pane_id,
                Action::AgentLaunch(params) => &params.pane_id,
                _ => unreachable!("launch action"),
            };
            if let Some(code) = denied_code(&decision) {
                if occupy_decision_effect(
                    &mut state,
                    &auth.shared.allocations,
                    request,
                    canonical,
                    owner,
                    lease,
                    &decision,
                )
                .is_none()
                {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::ResourceExhausted,
                    )?;
                    return Some(owner_ok());
                }
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    code,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            let Some(project_id) = admitted_ref(&decision).and_then(|admitted| admitted.project_id.clone()) else {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(owner_ok());
            };
            match state
                .workspace
                .launch_occupancy_ok(&project_id, pane_id, &state.runtime)
            {
                Ok(true) => {}
                Ok(false) => {
                    if occupy_effect(
                        &mut state,
                        &auth.shared.allocations,
                        request,
                        canonical,
                        owner,
                        lease,
                    )
                    .is_none()
                    {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        return Some(owner_ok());
                    }
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::AlreadyRunning,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
                Err(code) => {
                    if occupy_effect(
                        &mut state,
                        &auth.shared.allocations,
                        request,
                        canonical,
                        owner,
                        lease,
                    )
                    .is_none()
                    {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        return Some(owner_ok());
                    }
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            }
            let kind = match &request.action {
                Action::ShellLaunch(params) => SpawnKind::Launch {
                    project_id,
                    pane_id: params.pane_id.clone(),
                    shell: params.shell_profile_id.as_str().to_owned(),
                },
                Action::AgentLaunch(params) => SpawnKind::Agent {
                    project_id,
                    pane_id: params.pane_id.clone(),
                    ready: state.runtime.ready_provider(params.provider),
                    arguments: crate::provider::launch_arguments(
                        params.provider,
                        &params.model,
                        &params.effort,
                    ),
                },
                _ => unreachable!("launch action"),
            };
            spawn_pane(
                auth,
                state,
                request,
                canonical,
                out,
                owner,
                lease,
                kind,
            )
        }
        _ => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::UnsupportedCapability,
            )?;
            Some(owner_ok())
        }
    }
}
enum SpawnKind {
    Create {
        project_id: crate::contract::ProjectId,
        shell: String,
    },
    Split {
        project_id: crate::contract::ProjectId,
        target: crate::contract::PaneId,
        axis: crate::contract::Axis,
        shell: String,
    },
    Launch {
        project_id: crate::contract::ProjectId,
        pane_id: crate::contract::PaneId,
        shell: String,
    },
    Agent {
        project_id: crate::contract::ProjectId,
        pane_id: crate::contract::PaneId,
        ready: Option<crate::provider::lifecycle::ReadyProvider>,
        arguments: Result<Vec<String>, ErrorCode>,
    },
}

fn spawn_fail(
    auth: &Authorization,
    state: &mut std::sync::MutexGuard<'_, State>,
    request: &Request,
    out: &mut ChargedVec<u8>,
    run_id: Option<&crate::contract::RunId>,
    project_id: Option<&crate::contract::ProjectId>,
    credit: Option<EventCredit>,
    code: ErrorCode,
) -> Option<OwnerDispatch> {
    if let Some(credit) = credit {
        state.events.release(credit);
    }
    if let Some(run_id) = run_id {
        state.runtime.finalize_failure(run_id, true);
    }
    if let Some(project_id) = project_id {
        let _ = state.workspace.set_spawn_reserved(project_id, false);
    }
    write_error(
        out,
        request,
        &auth.shared.instance_id,
        state.event_seq(),
        state.topology_revision,
        code,
    )?;
    seal_terminal(state, request, out, false)?;
    Some(owner_ok())
}

fn spawn_pane(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    owner: bool,
    lease: Option<&ConnectionLease>,
    kind: SpawnKind,
) -> Option<OwnerDispatch> {
    let topology = state.topology_revision;
    let (project_id, shell_profile) = match &kind {
        SpawnKind::Create { project_id, shell }
        | SpawnKind::Split {
            project_id, shell, ..
        }
        | SpawnKind::Launch {
            project_id, shell, ..
        } => (project_id.clone(), shell.clone()),
        SpawnKind::Agent { project_id, .. } => (project_id.clone(), "pwsh".to_owned()),
    };
    if occupy_runtime_effect(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
        owner,
        lease,
        Some(&project_id),
        &[Scope::Control],
    )
    .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(owner_ok());
    }
    if matches!(kind, SpawnKind::Create { .. } | SpawnKind::Split { .. })
        && state.workspace.panes(&project_id).is_some_and(|panes| {
            panes.panes.len() >= crate::contract::MAX_PANES_PER_PROJECT
        })
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    let provider_error = match &kind {
        SpawnKind::Agent { ready, arguments, .. } => arguments
            .as_ref()
            .err()
            .copied()
            .or_else(|| ready.is_none().then_some(ErrorCode::UnsupportedCapability)),
        _ => None,
    };
    if shell_profile != "pwsh" || provider_error.is_some() {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            provider_error.unwrap_or(ErrorCode::InvalidRequest),
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    if let Some(code) = topology_denial(request, &state) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            code,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    if state
        .workspace
        .get(&project_id)
        .is_some_and(|project| project.spawn_reserved)
        || state.runtime.preparing_exists(&project_id)
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::AlreadyRunning,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    let is_launch = matches!(kind, SpawnKind::Launch { .. } | SpawnKind::Agent { .. });
    let axis = match &kind {
        SpawnKind::Split { axis, .. } => *axis,
        _ => crate::runtime::topology::default_axis(),
    };
    let (pane_id, layout_target) = match &kind {
        SpawnKind::Create { .. } => {
            let empty = state
                .workspace
                .panes(&project_id)
                .is_some_and(|panes| panes.root.is_none());
            let new_pane = match new_pane_id() {
                Ok(id) => id,
                Err(code) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            };
            if empty {
                (new_pane, None)
            } else {
                let Some(target) = state.workspace.default_split_target(&project_id) else {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::TargetNotFound,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                };
                (new_pane, Some(target))
            }
        }
        SpawnKind::Split { target, .. } => {
            if !state
                .workspace
                .panes(&project_id)
                .is_some_and(|panes| panes.contains_pane(target))
            {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                seal_terminal(&mut state, request, out, false)?;
                return Some(owner_ok());
            }
            let new_pane = match new_pane_id() {
                Ok(id) => id,
                Err(code) => {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        code,
                    )?;
                    seal_terminal(&mut state, request, out, false)?;
                    return Some(owner_ok());
                }
            };
            (new_pane, Some(target.clone()))
        }
        SpawnKind::Launch { pane_id, .. } | SpawnKind::Agent { pane_id, .. } => (pane_id.clone(), None),
    };
    let run_id = match new_run_id() {
        Ok(id) => id,
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(owner_ok());
        }
    };
    if state
        .runtime
        .insert_preparing(project_id.clone(), pane_id.clone(), run_id.clone())
        .is_err()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::OperationConflict,
        )?;
        seal_terminal(&mut state, request, out, false)?;
        return Some(owner_ok());
    }
    let _ = state.workspace.set_spawn_reserved(&project_id, true);
    if let Some(panes) = state.workspace.panes_mut(&project_id) {
        panes.panes.reserve(panes.panes.len().saturating_add(1));
    }
    let needs_topology = request.action.operation().class() == crate::contract::OperationClass::T;
    if (needs_topology && !can_layout_change(&state)) || out.capacity_bytes() < MAX_MESSAGE_BYTES {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            None,
            ErrorCode::ResourceExhausted,
        );
    }
    let credit = match state.events.try_reserve(&auth.shared.allocations, 1) {
        Ok(credit) => credit,
        Err(_) => {
            return spawn_fail(
                auth,
                &mut state,
                request,
                out,
                Some(&run_id),
                Some(&project_id),
                None,
                ErrorCode::ResourceExhausted,
            );
        }
    };
    let root_path = state
        .workspace
        .get(&project_id)
        .and_then(|project| project.path.clone());
    let expected_identity = state
        .workspace
        .get(&project_id)
        .and_then(|project| project.identity.clone());
    let runtime = std::sync::Arc::clone(&state.runtime);
    #[cfg(debug_assertions)]
    let testing_spawn_executable = state.testing_spawn_executable.take();
    #[cfg(debug_assertions)]
    let testing_spawn_prepared_hook = state.testing_spawn_prepared_hook.take();
    drop(state);

    let observed = root_path.as_deref().and_then(|path| {
        crate::store::root_identity::observe_root(
            path,
            &auth.shared.allocations,
            crate::host::admission::AllocationPool::ActiveOwner,
        )
        .ok()
    });
    let mut state = auth.shared.inner.lock().ok()?;
    if !generation_open(&state) {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::StateUnknown,
        );
    }
    let Some(observed) = observed else {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::RuntimeFailed,
        );
    };
    if expected_identity
        .as_ref()
        .is_some_and(|expected| expected != &observed.identity)
    {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::PermissionDenied,
        );
    }
    let cwd = observed.actual_path.clone();
    let _ = runtime.attach_root(&run_id, observed);
    drop(state);

    let agent_pin = match &kind {
        SpawnKind::Agent { ready: Some(ready), .. } => {
            let provider = match &request.action {
                Action::AgentLaunch(params) => params.provider,
                _ => unreachable!("agent pin"),
            };
            match ready.pin(provider) {
                Ok(pin) => Some(pin),
                Err(_) => {
                    runtime.invalidate_provider(provider);
                    let mut state = auth.shared.inner.lock().ok()?;
                    return spawn_fail(auth, &mut state, request, out, Some(&run_id),
                        Some(&project_id), Some(credit), ErrorCode::RuntimeFailed);
                }
            }
        }
        _ => None,
    };
    let child_result = match &kind {
        SpawnKind::Agent {
            ready: Some(_),
            arguments: Ok(arguments),
            ..
        } => {
            if agent_pin.as_ref()?.revalidate(match &request.action {
                Action::AgentLaunch(params) => params.provider,
                _ => unreachable!("agent spawn"),
            }).is_err() {
                if let Action::AgentLaunch(params) = &request.action { runtime.invalidate_provider(params.provider); }
                Err(ErrorCode::RuntimeFailed)
            } else {
                let refs: Vec<&str> = arguments.iter().map(String::as_str).collect();
                crate::runtime::spawn::spawn_suspended(&cwd, agent_pin.as_ref()?.path(), &refs)
                    .map_err(|_| ErrorCode::RuntimeFailed)
            }
        }
        _ => {
            #[cfg(debug_assertions)]
            {
                match testing_spawn_executable.as_deref() {
                    Some(executable) => crate::runtime::RuntimeService::spawn_testing_shell_child(&cwd, executable),
                    None => crate::runtime::RuntimeService::spawn_usual_shell_child(&cwd),
                }
            }
            #[cfg(not(debug_assertions))]
            {
                crate::runtime::RuntimeService::spawn_usual_shell_child(&cwd)
            }
        }
    };
    let child = match child_result {
        Ok(child) => child,
        Err(code) => {
            let mut state = auth.shared.inner.lock().ok()?;
            return spawn_fail(
                auth,
                &mut state,
                request,
                out,
                Some(&run_id),
                Some(&project_id),
                Some(credit),
                code,
            );
        }
    };
    let mut state = auth.shared.inner.lock().ok()?;
    if !generation_open(&state) || !runtime.has_session(&run_id) {
        drop(state);
        child.rollback();
        let mut state = auth.shared.inner.lock().ok()?;
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::StateUnknown,
        );
    }
    if let Err(code) = runtime.attach_child(&run_id, child) {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            code,
        );
    }
    #[cfg(debug_assertions)]
    {
        state.testing_spawn_counts.0 += 1;
        if let Some(hook) = testing_spawn_prepared_hook {
            drop(state);
            hook(&run_id);
            state = auth.shared.inner.lock().ok()?;
        }
    }
    if let SpawnKind::Agent { ready: Some(_), .. } = &kind {
        let provider = match &request.action {
            Action::AgentLaunch(params) => params.provider,
            _ => unreachable!("agent resume"),
        };
        drop(state);
        let pin_valid = agent_pin.as_ref()?.revalidate(provider).is_ok();
        if !pin_valid { runtime.invalidate_provider(provider); }
        state = auth.shared.inner.lock().ok()?;
        if !pin_valid {
            return spawn_fail(
                auth, &mut state, request, out, Some(&run_id), Some(&project_id),
                Some(credit), ErrorCode::RuntimeFailed,
            );
        }
    }

    #[cfg(debug_assertions)]
    if testing_spawn_executable.is_some() {
        if let Err(code) = runtime.testing_require_exit_before_observe(&run_id) {
            return spawn_fail(
                auth,
                &mut state,
                request,
                out,
                Some(&run_id),
                Some(&project_id),
                Some(credit),
                code,
            );
        }
    }
    if !generation_open(&state) {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::StateUnknown,
        );
    }
    match admit_runtime(&state, owner, lease, request) {
        AdmissionDecision::Admit(admitted)
            if admitted.project_id.as_ref() == Some(&project_id) => {}
        AdmissionDecision::Deny { code, .. } => {
            return spawn_fail(
                auth,
                &mut state,
                request,
                out,
                Some(&run_id),
                Some(&project_id),
                Some(credit),
                code,
            );
        }
        AdmissionDecision::Admit(_) => {
            return spawn_fail(
                auth,
                &mut state,
                request,
                out,
                Some(&run_id),
                Some(&project_id),
                Some(credit),
                ErrorCode::TargetNotFound,
            );
        }
    }
    if let Some(code) = topology_denial(request, &state) {
        return spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            code,
        );
    }
    #[cfg(debug_assertions)]
    { state.testing_spawn_counts.1 += 1; }
    let activation = runtime.resume_and_observe(&run_id);
    drop(agent_pin);
    match activation {
        Ok(crate::runtime::Activation::Published {
            process,
            work,
            exit_code,
        }) => {
            if is_launch {
                let _ = state.workspace.set_pane_shell_profile(
                    &project_id,
                    &pane_id,
                    &shell_profile,
                );
                if let Some(previous) = state
                    .workspace
                    .replace_current_run(&project_id, &pane_id, run_id.clone())
                    .ok()
                    .flatten()
                {
                    runtime.mark_current(&previous, false);
                }
            } else if let Err(code) = state.workspace.add_pane(
                &project_id,
                pane_id.clone(),
                run_id.clone(),
                layout_target.as_ref(),
                axis,
                &shell_profile,
            ) {
                return spawn_fail(
                    auth,
                    &mut state,
                    request,
                    out,
                    Some(&run_id),
                    Some(&project_id),
                    Some(credit),
                    code,
                );
            }
            let _ = state.workspace.set_spawn_reserved(&project_id, false);
            if needs_topology {
                bump_topology(&mut state);
            }
            let published_pane = pane_id.clone();
            if is_launch {
                if matches!(process, crate::contract::Process::Exited) {
                    let latch_charge = match state
                        .events
                        .preclaim_exit_latch(&auth.shared.allocations, &run_id)
                    {
                        Ok(charge) => charge,
                        Err(code) => {
                            return spawn_fail(
                                auth,
                                &mut state,
                                request,
                                out,
                                Some(&run_id),
                                Some(&project_id),
                                Some(credit),
                                code,
                            );
                        }
                    };
                    let seq = state.events.publish(
                        &auth.shared.allocations,
                        credit,
                        EventData::RunStateChanged {
                            run: live_observation(
                                run_id.clone(),
                                published_pane,
                                process,
                                work,
                                exit_code,
                                true,
                            ),
                        },
                        now_or_epoch(),
                    );
                    state
                        .events
                        .commit_preclaimed_latch(&run_id, seq, latch_charge);
                } else {
                    let _ = state.events.publish(
                        &auth.shared.allocations,
                        credit,
                        EventData::RunStateChanged {
                            run: live_observation(
                                run_id.clone(),
                                published_pane,
                                process,
                                work,
                                exit_code,
                                true,
                            ),
                        },
                        now_or_epoch(),
                    );
                }
            } else {
                publish_topology_change(
                    &auth.shared.allocations,
                    &mut state,
                    credit,
                    Some(project_id.clone()),
                    Some(published_pane),
                );
            }
            let success = match &request.action {
                Action::ShellLaunch(_) => {
                    crate::contract::Success::ShellLaunch(crate::contract::LaunchData {
                        pane_id,
                        run_id: run_id.clone(),
                        phase: crate::contract::AcceptedPhase::Accepted,
                    })
                }
                Action::AgentLaunch(_) => {
                    crate::contract::Success::AgentLaunch(crate::contract::LaunchData {
                        pane_id,
                        run_id: run_id.clone(),
                        phase: crate::contract::AcceptedPhase::Accepted,
                    })
                }
                Action::PaneSplit(_) => {
                    crate::contract::Success::PaneSplit(crate::contract::PaneCreatedData {
                        pane_id,
                        run_id: run_id.clone(),
                    })
                }
                _ => crate::contract::Success::PaneCreate(crate::contract::PaneCreatedData {
                    pane_id,
                    run_id: run_id.clone(),
                }),
            };
            write_success_data(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                success,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            drop(state);
            if matches!(process, crate::contract::Process::Exited) {
                runtime.queue_cleanup(&run_id);
            }
            Some(owner_ok())
        }
        _ => spawn_fail(
            auth,
            &mut state,
            request,
            out,
            Some(&run_id),
            Some(&project_id),
            Some(credit),
            ErrorCode::RuntimeFailed,
        ),
    }
}

fn dispatch_public_project_select(
    auth: &Authorization,
    mut state: std::sync::MutexGuard<'_, State>,
    lease: &ConnectionLease,
    request: &Request,
    canonical: &[u8],
    out: &mut ChargedVec<u8>,
    target: Option<ProjectId>,
) -> Option<ClientDispatch> {
    let topology = state.topology_revision;
    let record = connection(&state, lease.connection_key())?;
    if record.state != RecordState::Granted || !record.granted_scopes.contains(&Scope::Control) {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::PermissionDenied,
        )?;
        return Some(ClientDispatch { observation: None });
    }
    let granted: Vec<[u8; 36]> = record.granted_project_ids.iter().copied().collect();
    let mut ticket_ids = Vec::new();
    match target.as_ref() {
        Some(id) => {
            if !state.workspace.contains(id) {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::TargetNotFound,
                )?;
                return Some(ClientDispatch { observation: None });
            }
            if !granted.iter().any(|key| *key == key_of(id)) {
                write_error(
                    out,
                    request,
                    &auth.shared.instance_id,
                    state.event_seq(),
                    topology,
                    ErrorCode::PermissionDenied,
                )?;
                return Some(ClientDispatch { observation: None });
            }
            ticket_ids.push(id.clone());
        }
        None => {
            if let Some(current) = state.workspace.selected().cloned() {
                if !granted.iter().any(|key| *key == key_of(&current)) {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::PermissionDenied,
                    )?;
                    return Some(ClientDispatch { observation: None });
                }
                ticket_ids.push(current);
            } else {
                for key in &granted {
                    if let Some(id) = project_from_key(key) {
                        if state.workspace.contains(&id) {
                            ticket_ids.push(id);
                        }
                    }
                }
                if ticket_ids.is_empty() {
                    write_error(
                        out,
                        request,
                        &auth.shared.instance_id,
                        state.event_seq(),
                        topology,
                        ErrorCode::PermissionDenied,
                    )?;
                    return Some(ClientDispatch { observation: None });
                }
            }
        }
    }
    let ticket_set = StringSet::new(ticket_ids).ok()?;
    let ticket_keys: Vec<[u8; 36]> = ticket_set
        .iter()
        .map(|id| validated_key(id.as_str()))
        .collect();
    {
        let record = connection_mut(&mut state, lease.connection_key())?;
        if grow_active_vec(
            &mut record.outbound_keys,
            &auth.shared.allocations,
            ticket_keys.len(),
        )
        .is_err()
        {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::ResourceExhausted,
            )?;
            return Some(ClientDispatch { observation: None });
        }
    }
    if admit_public_effect_with_projects(
        &mut state,
        &auth.shared.allocations,
        request,
        canonical,
        lease,
        &ticket_set,
    )
    .is_none()
    {
        write_error(
            out,
            request,
            &auth.shared.instance_id,
            state.event_seq(),
            topology,
            ErrorCode::ResourceExhausted,
        )?;
        return Some(ClientDispatch { observation: None });
    }
    let expected = expected_revision(request);
    let observe_target = target.as_ref().and_then(|id| {
        state
            .workspace
            .get(id)
            .and_then(|project| Some((project.path.clone()?, project.identity.clone()?)))
    });
    drop(state);
    let observed_state = observe_target.as_ref().map(|(path, identity)| {
        reobserve_state(
            path,
            identity,
            &auth.shared.allocations,
            AllocationPool::ActivePublic,
        )
    });
    let mut state = match relock_after_observe(auth, request, out, false, Some(lease), true) {
        Ok(state) => state,
        Err(Some(())) => return Some(ClientDispatch { observation: None }),
        Err(None) => return None,
    };
    let topology = state.topology_revision;
    if let Some(root) = observed_state {
        let code = match root {
            RootState::Verified => None,
            RootState::Unavailable => Some(ErrorCode::TargetNotFound),
            RootState::Changed => Some(ErrorCode::RootChanged),
            RootState::Unknown => Some(ErrorCode::PermissionDenied),
        };
        if let Some(code) = code {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            return Some(ClientDispatch { observation: None });
        }
    }
    match state
        .workspace
        .classify_select(target.as_ref(), expected, topology)
    {
        Err(code) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                code,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(ClientDispatch { observation: None })
        }
        Ok(SelectOutcome::Changed) if !can_layout_change(&state) => {
            write_error(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                topology,
                ErrorCode::ResourceExhausted,
            )?;
            seal_terminal(&mut state, request, out, false)?;
            Some(ClientDispatch { observation: None })
        }
        Ok(outcome) => {
            let credit = if matches!(outcome, SelectOutcome::Changed) {
                match state.events.try_reserve(&auth.shared.allocations, 1) {
                    Ok(credit) => Some(credit),
                    Err(_) => {
                        write_error(
                            out,
                            request,
                            &auth.shared.instance_id,
                            state.event_seq(),
                            topology,
                            ErrorCode::ResourceExhausted,
                        )?;
                        seal_terminal(&mut state, request, out, false)?;
                        return Some(ClientDispatch { observation: None });
                    }
                }
            } else {
                None
            };
            state.workspace.apply_select(target.as_ref());
            if let Some(credit) = credit {
                let _ = bump_topology(&mut state);
                publish_topology_change(
                    &auth.shared.allocations,
                    &mut state,
                    credit,
                    target.clone(),
                    None,
                );
            }
            let selected = state.workspace.selected().cloned();
            write_success(
                out,
                request,
                &auth.shared.instance_id,
                state.event_seq(),
                state.topology_revision,
                |sink| write_project_select(sink, selected.as_ref()),
            )?;
            seal_terminal(&mut state, request, out, false)?;
            if let Some(record) = connection_mut(&mut state, lease.connection_key()) {
                if queue_outbound(record, &auth.shared.allocations, &ticket_keys).is_err() {
                    record.outbound_phase = OutboundPhase::Refused;
                    record.outbound_keys.clear();
                }
            }
            Some(ClientDispatch { observation: None })
        }
    }
}

fn registered_contains(state: &State, project: &ProjectId) -> bool {
    state.workspace.contains(project)
}

fn empty_active_vec<T>(
    allocations: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ChargedVec<T>, ReplayStorageError> {
    ChargedVec::with_capacity(allocations, pool, 0, 0).map_err(|_| ReplayStorageError::Exhausted)
}

fn grow_active_vec<T>(
    values: &mut ChargedVec<T>,
    allocations: &AllocationAuthority,
    elements: usize,
) -> Result<(), ReplayStorageError> {
    if elements <= values.capacity_elements() {
        return Ok(());
    }
    let bytes = elements
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(ReplayStorageError::Exhausted)?;
    values
        .try_grow(allocations, elements, bytes)
        .map_err(|_| ReplayStorageError::Exhausted)
}

fn copy_project_keys(
    destination: &mut ChargedVec<[u8; 36]>,
    allocations: &AllocationAuthority,
    source: &StringSet<ProjectId>,
) -> Result<(), ReplayStorageError> {
    grow_active_vec(destination, allocations, source.len())?;
    destination.clear();
    for project in source.iter() {
        destination
            .try_push(validated_key(project.as_str()))
            .map_err(|_| ReplayStorageError::Capacity)?;
    }
    Ok(())
}

fn copy_scopes(
    destination: &mut ChargedVec<Scope>,
    allocations: &AllocationAuthority,
    source: &StringSet<Scope>,
) -> Result<(), ReplayStorageError> {
    grow_active_vec(destination, allocations, source.len())?;
    destination.clear();
    for scope in source.iter() {
        destination
            .try_push(*scope)
            .map_err(|_| ReplayStorageError::Capacity)?;
    }
    Ok(())
}

fn same_project_set(stored: &[[u8; 36]], source: &StringSet<ProjectId>) -> bool {
    stored.len() == source.len()
        && source
            .iter()
            .all(|project| stored.contains(&validated_key(project.as_str())))
}

fn same_scope_set(stored: &[Scope], source: &StringSet<Scope>) -> bool {
    stored.len() == source.len() && source.iter().all(|scope| stored.contains(scope))
}

fn ensure_connection_capacity(
    state: &mut State,
    allocations: &AllocationAuthority,
) -> Result<(), ReplayStorageError> {
    let needed = state
        .connections
        .len()
        .checked_add(1)
        .ok_or(ReplayStorageError::Exhausted)?;
    grow_active_vec(&mut state.connections, allocations, needed)?;
    grow_active_vec(&mut state.connection_index, allocations, needed)?;
    grow_active_vec(&mut state.cancel_drain, allocations, needed)?;
    Ok(())
}

fn remove_connection(state: &mut State, allocations: &AllocationAuthority, key: &[u8; 36]) -> bool {
    let Ok(index_position) = state
        .connection_index
        .binary_search_by_key(key, |entry| entry.connection_key)
    else {
        return false;
    };
    let slot = state.connection_index[index_position].slot;
    state.connection_index.remove(index_position);
    state.connections.remove(slot);
    for entry in state.connection_index.iter_mut() {
        if entry.slot > slot {
            entry.slot -= 1;
        }
    }
    if state.connections.is_empty() {
        state.connections = ChargedVec::empty(allocations, AllocationPool::ActivePublic);
        state.connection_index = ChargedVec::empty(allocations, AllocationPool::ActivePublic);
        state.cancel_drain = ChargedVec::empty(allocations, AllocationPool::ActivePublic);
    }
    true
}

fn lock_lifecycle(mutex: &Mutex<State>) -> std::sync::MutexGuard<'_, State> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn insert_connection(
    state: &mut State,
    allocations: &AllocationAuthority,
    connection_key: [u8; 36],
    executable_name: Option<ChargedValue<NonEmpty>>,
    record_state: RecordState,
    cancel: Arc<dyn CancelSignal>,
    worker: WorkerOwnership,
    recovery_credit: RecoveryCredit,
    stack_charge: Option<CapacityCharge>,
) -> Option<ConnectionLease> {
    debug_assert!(connection_index_of(state, &connection_key).is_none());
    ensure_connection_capacity(state, allocations).ok()?;
    let token = Arc::new(());
    let live = Arc::new(AtomicBool::new(true));
    let send_gate = Arc::new(Mutex::new(()));
    let insert_at = match state
        .connection_index
        .binary_search_by_key(&connection_key, |entry| entry.connection_key)
    {
        Ok(_) => return None,
        Err(index) => index,
    };
    let slot = state.connections.len();
    let requested_project_ids = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    let requested_scopes = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    let granted_project_ids = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    let granted_scopes = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    let observation =
        ObservationSlot::vacant(allocations, AllocationPool::ActivePublic, 4096).ok()?;
    let outbound_keys = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    let inflight = empty_active_vec(allocations, AllocationPool::ActivePublic).ok()?;
    state
        .connections
        .try_push(ConnectionRecord {
            connection_key,
            token: token.clone(),
            live: live.clone(),
            send_gate: send_gate.clone(),
            executable_name,
            observation,
            requested_project_ids,
            requested_scopes,
            granted_project_ids,
            granted_scopes,
            state: record_state,
            revoked_published: false,
            cancel,
            cancel_signaled: false,
            worker,
            recovery_credit,
            _stack_charge: stack_charge,
            outbound_phase: OutboundPhase::Idle,
            outbound_keys,
            inflight,
        })
        .ok()?;
    if state
        .connection_index
        .try_insert(
            insert_at,
            ConnectionIndexEntry {
                connection_key,
                slot,
            },
        )
        .is_err()
    {
        state.connections.remove(slot);
        return None;
    }
    Some(ConnectionLease {
        connection_key,
        token,
        live,
        send_gate,
    })
}

fn fail_generation_locked(allocations: &AllocationAuthority, state: &mut State) {
    state.generation = GenerationState::Failed;
    state.artifacts.invalidate_all();
    close_open_connections(allocations, state);
}

fn close_open_connections(allocations: &AllocationAuthority, state: &mut State) {
    for index in 0..state.connections.len() {
        if matches!(
            state.connections[index].state,
            RecordState::Closing | RecordState::Finished
        ) {
            continue;
        }
        let key = state.connections[index].connection_key;
        publish_revoked_if_needed(allocations, state, &key);
        let record = &mut state.connections[index];
        record.state = RecordState::Closing;
        record.granted_project_ids.clear();
        record.granted_scopes.clear();
        record.live.store(false, Ordering::SeqCst);
    }
    state.events.wake_all();
}

fn take_unsignaled_cancellations(
    state: &mut State,
    allocations: &AllocationAuthority,
) -> ChargedVec<GenerationCancel> {
    state.cancel_drain.clear();
    for record in state.connections.iter_mut() {
        if record.state == RecordState::Finished || record.cancel_signaled {
            continue;
        }
        record.cancel_signaled = true;
        if state
            .cancel_drain
            .try_push((record.cancel.clone(), record.send_gate.clone()))
            .is_err()
        {
            record.cancel.cancel();
        }
    }
    std::mem::replace(
        &mut state.cancel_drain,
        ChargedVec::empty(allocations, AllocationPool::ActivePublic),
    )
}

fn claim_worker(state: &mut State, finished_only: bool) -> Option<WorkerJoin> {
    let slot = state.connections.iter().position(|record| {
        let eligible = !finished_only || record.state == RecordState::Finished;
        eligible && matches!(record.worker, WorkerOwnership::Published(_))
    })?;
    let record = &mut state.connections[slot];
    let WorkerOwnership::Published(handle) =
        std::mem::replace(&mut record.worker, WorkerOwnership::Joining)
    else {
        unreachable!("selected worker was published")
    };
    Some(WorkerJoin {
        connection_key: record.connection_key,
        token: record.token.clone(),
        handle,
    })
}

fn lease_matches(state: &State, lease: &ConnectionLease) -> bool {
    if !lease.live.load(Ordering::SeqCst) {
        return false;
    }
    connection(state, lease.connection_key()).is_some_and(|record| {
        matches!(
            record.state,
            RecordState::Unpaired | RecordState::Pending | RecordState::Granted
        ) && Arc::ptr_eq(&record.token, &lease.token)
    })
}

#[cfg(test)]
mod pane_order_tests {
    use super::pane_rows_in_id_order;
    use crate::contract::{Axis, LayoutNode, NonEmpty, Nullable, PaneId, Ratio, RunId};
    use crate::runtime::topology::{PaneRecord, ProjectPanes};

    #[test]
    fn pane_projection_is_canonical_even_when_tree_and_live_vector_are_reversed() {
        let low = PaneId::new("40000000-0000-4000-8000-000000000001").unwrap();
        let high = PaneId::new("40000000-0000-4000-8000-000000000002").unwrap();
        let run_low = RunId::new("50000000-0000-4000-8000-000000000001").unwrap();
        let run_high = RunId::new("50000000-0000-4000-8000-000000000002").unwrap();
        let root = LayoutNode::split(
            Axis::Vertical,
            Ratio::new(0.5).unwrap(),
            LayoutNode::leaf(high.clone()),
            LayoutNode::leaf(low.clone()),
        )
        .unwrap();
        let pane = |id, run| PaneRecord {
            id,
            current_run: Some(run),
            previous_runs: Vec::new(),
            shell_profile_id: NonEmpty::new("pwsh").unwrap(),
            provider_profile: Nullable(None),
        };
        let panes = ProjectPanes {
            root: Some(root.clone()),
            selected_pane_id: Some(high.clone()),
            panes: vec![pane(high.clone(), run_high.clone()), pane(low.clone(), run_low.clone())],
        };
        assert_eq!(
            pane_rows_in_id_order(&panes),
            vec![(low, Some(run_low)), (high.clone(), Some(run_high))]
        );
        assert_eq!(panes.root, Some(root));
        assert_eq!(panes.selected_pane_id, Some(high));
    }
}

#[cfg(test)]
mod replay_storage_tests {
    use super::*;
    use crate::host::admission::PUBLIC_WORKER_STACK_BYTES;

    struct NoopCancel;

    impl CancelSignal for NoopCancel {
        fn cancel(&self) {}
    }

    fn connection_key() -> [u8; 36] {
        *b"10000000-0000-4000-8000-000000000000"
    }

    fn operation_id(value: u8) -> OperationId {
        OperationId::new(format!("{value:08x}-0000-4000-8000-000000000000")).expect("operation ID")
    }

    #[test]
    fn reservation_failure_schedule_is_default_deny_and_recoverable() {
        for successful_allocations in 0..4 {
            let authority = AllocationAuthority::host();
            let mut replay = ReplayStorage::new(&authority).expect("empty replay storage");
            authority.fail_after_allocations(successful_allocations);
            assert!(matches!(
                replay.reserve_recovery(&authority, &connection_key()),
                Err(ReplayStorageError::Exhausted)
            ));
            assert!(replay.slots.is_empty());
            assert!(replay.index.is_empty());
            assert_eq!(replay.reserved_indexes, 0);
            let snapshot = authority.snapshot();
            assert_eq!(snapshot.active_public, 0);
            assert_eq!(snapshot.active_owner, 0);
            drop(replay);
            assert_eq!(authority.snapshot().retained, 0);
        }

        let authority = AllocationAuthority::host();
        let mut replay = ReplayStorage::new(&authority).expect("empty replay storage");
        authority.fail_after_allocations(4);
        let credit = replay
            .reserve_recovery(&authority, &connection_key())
            .expect("reservation recovers after the failure schedule");
        assert_eq!(replay.slots.len(), 1);
        replay
            .release_unspawned(&credit)
            .expect("unused recovery credit releases");
        drop(replay);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn recovery_transition_retains_done_and_releases_only_unused_credit() {
        let authority = AllocationAuthority::host();
        let mut replay = ReplayStorage::new(&authority).expect("empty replay storage");
        let mut credit = replay
            .reserve_recovery(&authority, &connection_key())
            .expect("recovery reservation");
        let operation = operation_id(1);
        replay
            .begin_recovery(&mut credit, &operation, b"canonical")
            .expect("begin recovery");
        let preparing = replay.lookup(&operation).expect("preparing replay");
        assert_eq!(preparing.phase, ReplayPhaseView::Preparing);
        assert!(matches!(preparing.actor, ReplayActor::Owner));
        assert_eq!(preparing.canonical, b"canonical");
        assert!(preparing.terminal.is_empty());
        assert!(matches!(preparing.ticket, Some(SendPolicyTicket::Owner)));

        let oversized = vec![0u8; replay.slots[0].terminal.capacity_elements() + 1];
        assert_eq!(
            replay.finish_recovery(
                &operation,
                &oversized,
                ReplayCounters {
                    topology_revision: 1,
                    event_seq: 2,
                },
            ),
            Err(ReplayStorageError::InvalidReservation)
        );
        let unchanged = replay.lookup(&operation).expect("preparing replay remains");
        assert_eq!(unchanged.phase, ReplayPhaseView::Preparing);
        assert!(unchanged.terminal.is_empty());

        replay
            .finish_recovery(
                &operation,
                b"terminal",
                ReplayCounters {
                    topology_revision: 1,
                    event_seq: 2,
                },
            )
            .expect("finish recovery");
        let done = replay.lookup(&operation).expect("done replay");
        assert_eq!(done.phase, ReplayPhaseView::Done);
        assert_eq!(done.terminal, b"terminal");
        assert_eq!(
            done.counters,
            Some(ReplayCounters {
                topology_revision: 1,
                event_seq: 2,
            })
        );
        assert!(matches!(done.ticket, Some(SendPolicyTicket::Owner)));
        assert_eq!(replay.slots[0].terminal.capacity_bytes(), b"terminal".len());
        let retained_before = authority.snapshot().retained;
        assert_eq!(
            replay.release_unused_after_join(&credit),
            Ok(RecoveryRelease::RetainedDone)
        );
        assert_eq!(authority.snapshot().retained, retained_before);

        let second_connection = *b"20000000-0000-4000-8000-000000000000";
        let unused = replay
            .reserve_recovery(&authority, &second_connection)
            .expect("second recovery reservation");
        let retained_with_unused = authority.snapshot().retained;
        assert_eq!(
            replay.release_unused_after_join(&unused),
            Ok(RecoveryRelease::ReleasedUnused)
        );
        assert!(authority.snapshot().retained < retained_with_unused);
        assert!(replay.lookup(&operation).is_some());
        drop(replay);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn sealed_public_response_compaction_preserves_actor_ticket_and_failure_fallback() {
        for fail in [false, true] {
            let auth = Authorization::new(Vec::<ProjectId>::new());
            let authority = auth.allocations().clone();
            let lease = auth
                .attach_verified_fixture(
                    NonEmpty::new("retained-response-test").unwrap(),
                    Arc::new(NoopCancel),
                )
                .unwrap();
            let baseline = authority.snapshot();
            let mut replay = ReplayStorage::new(&authority).unwrap();
            let op = operation_id(81);
            let mut credit = replay
                .reserve_effect(
                    &authority,
                    AllocationPool::ActivePublic,
                    32,
                    MAX_MESSAGE_BYTES,
                )
                .unwrap();
            let ticket = SendPolicyTicket::public(
                &authority,
                lease.clone(),
                &StringSet::new(Vec::new()).unwrap(),
            )
            .unwrap();
            replay
                .begin_effect(
                    &mut credit,
                    &op,
                    ReplayActor::Public(lease.clone()),
                    ticket,
                    b"public-canonical",
                )
                .unwrap();
            assert_eq!(replay.slots[0].terminal.capacity_bytes(), MAX_MESSAGE_BYTES);
            if fail {
                authority.fail_after_allocations(0);
            }
            let counters = ReplayCounters {
                topology_revision: 5,
                event_seq: 6,
            };
            replay
                .finish_effect(&op, b"public-terminal", counters)
                .unwrap();
            let done = replay.lookup(&op).unwrap();
            assert_eq!(done.phase, ReplayPhaseView::Done);
            assert_eq!(done.canonical, b"public-canonical");
            assert_eq!(done.terminal, b"public-terminal");
            assert_eq!(done.counters, Some(counters));
            let ReplayActor::Public(actor) = done.actor else {
                panic!("public actor changed")
            };
            assert!(Arc::ptr_eq(&actor.token, &lease.token));
            let Some(SendPolicyTicket::Public {
                lease: ticket_lease,
                ..
            }) = done.ticket
            else {
                panic!("public ticket changed")
            };
            assert!(Arc::ptr_eq(&ticket_lease.token, &lease.token));
            assert_eq!(
                replay.slots[0].terminal.capacity_bytes(),
                if fail {
                    MAX_MESSAGE_BYTES
                } else {
                    b"public-terminal".len()
                }
            );
            assert_eq!(authority.snapshot().active_owner, baseline.active_owner);
            drop(replay);
            assert_eq!(authority.snapshot().retained, baseline.retained);
            drop(lease);
            drop(auth);
            assert_eq!(authority.snapshot().retained, 0);
            assert_eq!(authority.snapshot().active_owner, 0);
        }
    }

    #[test]
    fn sealed_response_compaction_keeps_preparing_and_done_replay_identity() {
        for fail in [false, true] {
            for terminal in [b"success".as_slice(), b"resource_exhausted".as_slice()] {
                let authority = AllocationAuthority::host();
                let mut replay = ReplayStorage::new(&authority).unwrap();
                let op = operation_id(80);
                let mut credit = replay
                    .reserve_effect(
                        &authority,
                        AllocationPool::ActiveOwner,
                        32,
                        MAX_MESSAGE_BYTES,
                    )
                    .unwrap();
                replay
                    .begin_effect(
                        &mut credit,
                        &op,
                        ReplayActor::Owner,
                        SendPolicyTicket::owner(),
                        b"canonical",
                    )
                    .unwrap();
                assert_eq!(replay.slots[0].terminal.capacity_bytes(), MAX_MESSAGE_BYTES);
                assert_eq!(
                    replay.lookup(&op).unwrap().phase,
                    ReplayPhaseView::Preparing
                );
                if fail {
                    authority.fail_after_allocations(0);
                }
                let counters = ReplayCounters {
                    topology_revision: 3,
                    event_seq: 4,
                };
                replay.finish_effect(&op, terminal, counters).unwrap();
                let done = replay.lookup(&op).unwrap();
                assert_eq!(done.phase, ReplayPhaseView::Done);
                assert_eq!(done.canonical, b"canonical");
                assert_eq!(done.terminal, terminal);
                assert_eq!(done.counters, Some(counters));
                assert!(matches!(done.actor, ReplayActor::Owner));
                assert!(matches!(done.ticket, Some(SendPolicyTicket::Owner)));
                assert_eq!(
                    replay.slots[0].terminal.capacity_bytes(),
                    if fail {
                        MAX_MESSAGE_BYTES
                    } else {
                        terminal.len()
                    }
                );
                assert_eq!(authority.snapshot().active_owner, 0);
                drop(replay);
                assert_eq!(authority.snapshot().retained, 0);
            }
        }
    }

    #[test]
    fn effect_conflict_and_cancellation_preserve_existing_record() {
        let authority = AllocationAuthority::host();
        let mut replay = ReplayStorage::new(&authority).expect("empty replay storage");
        let operation = operation_id(2);
        let mut first = replay
            .reserve_effect(&authority, AllocationPool::ActiveOwner, 16, 16)
            .expect("first effect reservation");
        replay
            .begin_effect(
                &mut first,
                &operation,
                ReplayActor::Owner,
                SendPolicyTicket::owner(),
                b"first",
            )
            .expect("begin first effect");
        let mut second = replay
            .reserve_effect(&authority, AllocationPool::ActiveOwner, 16, 16)
            .expect("second effect reservation");
        assert_eq!(
            replay.begin_effect(
                &mut second,
                &operation,
                ReplayActor::Owner,
                SendPolicyTicket::owner(),
                b"second"
            ),
            Err(ReplayStorageError::Conflict)
        );
        assert!(!second.consumed);
        assert_eq!(replay.lookup(&operation).unwrap().canonical, b"first");
        replay.cancel_effect(&second).expect("cancel unused effect");
        replay
            .finish_effect(
                &operation,
                b"done",
                ReplayCounters {
                    topology_revision: 3,
                    event_seq: 4,
                },
            )
            .expect("finish first effect");
        assert_eq!(replay.lookup(&operation).unwrap().terminal, b"done");
        drop(replay);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn connection_admission_releases_spawn_failure_and_unused_join_credit() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        authorization.allocations().fail_after_allocations(0);
        assert!(authorization
            .admit_worker(Arc::new(NoopCancel))
            .is_err());
        {
            let state = authorization
                .shared
                .inner
                .lock()
                .expect("authorization state");
            assert_eq!(state.event_seq(), 0);
            assert!(state.connections.is_empty());
            assert!(state.replay.slots.is_empty());
        }
        assert_eq!(authorization.allocations().snapshot().active_public, 0);

        let lease = authorization
            .admit_worker(Arc::new(NoopCancel))
            .expect("admit worker after failure")
            .expect("worker accepted");
        assert_eq!(authorization.record_count(), 1);
        assert!(matches!(
            authorization.publish_worker(&lease, std::thread::spawn(|| {}), || true, || true),
            WorkerPublish::Published
        ));
        assert!(authorization.finish_worker(&lease, || true));
        let join = authorization
            .claim_next_ready()
            .expect("claim finished worker");
        join.handle.join().expect("worker join");
        assert!(authorization.retire_worker(&join.connection_key, &join.token));
        assert_eq!(authorization.record_count(), 0);
        assert_eq!(authorization.allocations().snapshot().active_public, 0);
        let state = authorization
            .shared
            .inner
            .lock()
            .expect("authorization state");
        assert!(state.replay.slots.is_empty());
        assert_eq!(state.replay.reserved_indexes, 0);
    }
}

#[cfg(test)]
mod admission_transaction_tests {
    use super::*;
    struct NoopCancel;
    impl CancelSignal for NoopCancel {
        fn cancel(&self) {}
    }

    #[test]
    fn connection_admission_every_allocator_boundary_releases_unspawned_credit() {
        for fail_after in 0.. {
            let authorization = Authorization::new(Vec::<ProjectId>::new());
            authorization.allocations().fail_after_allocations(fail_after);
            let admitted = authorization.admit_worker(Arc::new(NoopCancel));
            match admitted {
                Err(WorkerAdmissionError::Exhausted) => {
                    let state = authorization.shared.inner.lock().unwrap();
                    assert!(state.connections.is_empty());
                    assert!(state.connection_index.is_empty());
                    assert!(state.replay.slots.is_empty(), "orphan recovery credit at allocator boundary {fail_after}");
                    assert_eq!(state.replay.reserved_indexes, 0);
                    assert_eq!(state.event_seq(), 0);
                    let tables = state.connections.capacity_bytes() + state.connection_index.capacity_bytes()
                        + state.cancel_drain.capacity_bytes();
                    assert_eq!(authorization.allocations().snapshot().active_public, tables,
                        "orphan worker-owned charge at allocator boundary {fail_after}");
                }
                Ok(Some(lease)) => {
                    assert!(matches!(authorization.publish_worker(&lease,
                        std::thread::spawn(|| {}), || true, || true), WorkerPublish::Published));
                    assert!(authorization.finish_worker(&lease, || true));
                    let join = authorization.claim_next_ready().unwrap();
                    join.handle.join().unwrap();
                    assert!(authorization.retire_worker(&join.connection_key, &join.token));
                    assert_eq!(authorization.allocations().snapshot().active_public, 0);
                    assert!(authorization.shared.inner.lock().unwrap().replay.slots.is_empty());
                    break;
                }
                _ => panic!("allocator failure changed into a normal refusal or state error"),
            }
        }
    }
}

#[cfg(test)]
mod event_accounting_authority_tests {
    use super::*;
    use crate::host::admission::PUBLIC_WORKER_STACK_BYTES;
    use std::sync::Arc;

    struct NoopCancel;

    impl CancelSignal for NoopCancel {
        fn cancel(&self) {}
    }

    #[test]
    fn event_credit_drop_while_inner_held_abandons_without_seq_or_lock() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let mut state = authorization
            .shared
            .inner
            .lock()
            .expect("authorization state");
        assert_eq!(state.event_seq(), 0);
        let credit = state
            .events
            .try_reserve(&authorization.shared.allocations, 1)
            .expect("reserve");
        assert_eq!(state.events.outstanding_credits(), 1);
        drop(credit);
        assert_eq!(state.event_seq(), 0);
        assert_eq!(state.events.log_len(), 0);
        assert_eq!(state.events.outstanding_credits(), 1);
        state.events.reap_abandoned();
        assert_eq!(state.events.outstanding_credits(), 0);
        assert_eq!(state.event_seq(), 0);
        assert_eq!(state.events.dropped_through(), 0);
    }

    #[test]
    fn publish_consumes_credit_and_release_does_not_increment() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let mut state = authorization
            .shared
            .inner
            .lock()
            .expect("authorization state");
        let credit = state
            .events
            .try_reserve(&authorization.shared.allocations, 1)
            .expect("reserve");
        let seq = state.events.publish(
            &authorization.shared.allocations,
            credit,
            EventData::TopologyChanged {
                topology_revision: U::new(1).expect("topology"),
                project_id: Nullable(None),
                pane_id: Nullable(None),
            },
            now_or_epoch(),
        );
        assert_eq!(seq, 1);
        assert_eq!(state.event_seq(), 1);
        assert_eq!(state.events.outstanding_credits(), 0);
        assert_eq!(state.events.log_len(), 1);
        let unused = state
            .events
            .try_reserve(&authorization.shared.allocations, 1)
            .expect("second reserve");
        state.events.release(unused);
        assert_eq!(state.event_seq(), 1);
        assert_eq!(state.events.outstanding_credits(), 0);
        assert_eq!(state.events.log_len(), 1);
    }

    #[test]
    fn close_generation_does_not_steal_live_credit_or_fabricate_seq() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let credit;
        {
            let mut state = authorization
                .shared
                .inner
                .lock()
                .expect("authorization state");
            credit = state
                .events
                .try_reserve(&authorization.shared.allocations, 1)
                .expect("reserve");
        }
        let closed = authorization.close_generation();
        closed.signal_cancellations();
        closed.reap_jobs();
        assert_eq!(authorization.testing_outstanding_credits(), 1);
        assert_eq!(authorization.event_seq(), 0);
        drop(credit);
        assert_eq!(authorization.testing_outstanding_credits(), 1);
        let mut state = authorization
            .shared
            .inner
            .lock()
            .expect("authorization state");
        state.events.reap_abandoned();
        assert_eq!(state.events.outstanding_credits(), 0);
        assert_eq!(state.event_seq(), 0);
        assert_eq!(state.events.log_len(), 0);
    }

    #[test]
    fn finish_worker_publishes_one_revoked_and_finished_does_not_take_second_seq() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let lease = authorization
            .admit_worker(Arc::new(NoopCancel))
            .expect("admit worker")
            .expect("worker accepted");
        assert_eq!(authorization.event_seq(), 0);
        assert!(matches!(
            authorization.publish_worker(&lease, std::thread::spawn(|| {}), || true, || true),
            WorkerPublish::Published
        ));
        assert!(authorization.finish_worker(&lease, || true));
        assert_eq!(authorization.event_seq(), 1);
        assert_eq!(authorization.testing_outstanding_credits(), 0);
        assert!(authorization.finish_worker(&lease, || true));
        assert_eq!(authorization.event_seq(), 1);
        let join = authorization
            .claim_next_ready()
            .expect("claim finished worker");
        join.handle.join().expect("worker join");
        assert!(authorization.retire_worker(&join.connection_key, &join.token));
    }

    #[test]
    fn mark_verified_publishes_unpaired_and_max_seq_fails_closed() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let lease = authorization
            .admit_worker(Arc::new(NoopCancel))
            .expect("admit worker")
            .expect("worker accepted");
        let charged = charge_executable_name(
            authorization.allocations(),
            NonEmpty::new("pwsh").expect("name"),
        )
        .expect("charge name");
        assert!(authorization.mark_verified(&lease, charged));
        assert_eq!(authorization.event_seq(), 1);
        assert_eq!(authorization.testing_outstanding_credits(), 0);

        authorization.set_event_seq_to_max();
        let lease = authorization
            .admit_worker(Arc::new(NoopCancel))
            .expect("admit worker at max seq")
            .expect("worker accepted");
        let charged = charge_executable_name(
            authorization.allocations(),
            NonEmpty::new("pwsh").expect("name"),
        )
        .expect("charge name");
        assert!(!authorization.mark_verified(&lease, charged));
        assert_eq!(authorization.event_seq(), MAX_SAFE_INTEGER);
        assert_eq!(authorization.testing_outstanding_credits(), 0);
    }

    #[test]
    fn exit_callback_without_session_does_not_fabricate_seq_or_latch() {
        let authorization = Authorization::new(Vec::<ProjectId>::new());
        let run = crate::contract::RunId::new("50000000-0000-4000-8000-000000000001")
            .expect("run");
        authorization.testing_fire_exit_callback(&run);
        assert_eq!(authorization.event_seq(), 0);
        assert_eq!(authorization.testing_exit_latch_charge(), 0);
        assert_eq!(authorization.testing_outstanding_credits(), 0);
    }
}

fn instance_text<'a>(request: &'a Request, current: &'a InstanceId) -> &'a str {
    request
        .instance_id
        .0
        .as_ref()
        .map_or(current.as_str(), InstanceId::as_str)
}

fn write_error(
    out: &mut ChargedVec<u8>,
    request: &Request,
    current: &InstanceId,
    event_seq: u64,
    topology: u64,
    code: ErrorCode,
) -> Option<()> {
    out.clear();
    write_error_response(
        &mut Output(out),
        instance_text(request, current),
        request.operation_id.as_str(),
        event_seq,
        topology,
        code,
    )
    .ok()
}

fn write_success(
    out: &mut ChargedVec<u8>,
    request: &Request,
    current: &InstanceId,
    event_seq: u64,
    topology: u64,
    write_result: impl FnOnce(&mut Output<'_>) -> Result<(), AllocationError>,
) -> Option<()> {
    out.clear();
    let mut sink = Output(out);
    write_success_prefix(
        &mut sink,
        instance_text(request, current),
        request.operation_id.as_str(),
        event_seq,
    )
    .ok()?;
    write_result(&mut sink).ok()?;
    write_success_suffix(&mut sink, topology).ok()
}

// Both public inventories describe the operations implemented by this host.
// Provider readiness changes only whether agent.launch can currently succeed.
fn write_implemented_operations(
    sink: &mut impl Sink,
    agent_ready: bool,
) -> Result<(), AllocationError> {
    sink.bytes(b"[")?;
    let mut previous: Option<&str> = None;
    while let Some(current) = OperationName::ALL
        .iter()
        .filter(|operation| {
            crate::service::replay::ledger_class(**operation)
                != crate::service::replay::LedgerClass::Unsupported
                && (agent_ready || **operation != OperationName::AgentLaunch)
        })
        .map(|operation| operation.wire())
        .filter(|wire| previous.is_none_or(|previous| *wire > previous))
        .min()
    {
        if previous.is_some() {
            sink.bytes(b",")?;
        }
        json_string(sink, current)?;
        previous = Some(current);
    }
    sink.bytes(b"]")
}

fn write_diagnostics(
    sink: &mut impl Sink,
    runtime: &crate::runtime::RuntimeService,
) -> Result<(), AllocationError> {
    let agent_ready = runtime.is_provider_ready(crate::contract::Provider::Codex)
        || runtime.is_provider_ready(crate::contract::Provider::Claude);
    sink.bytes(b"{\"data\":{\"capabilities\":")?;
    write_implemented_operations(sink, agent_ready)?;
    // This is the caller's diagnostic authority and the public error catalogue,
    // never a projection of other connections or recent private failures.
    sink.bytes(b",\"connection_state\":\"granted\",\"failure_codes\":[")?;
    let mut previous: Option<&str> = None;
    for _ in 0..ErrorCode::ALL.len() {
        let current = ErrorCode::ALL
            .iter()
            .map(|code| code.wire())
            .filter(|value| previous.is_none_or(|previous| *value > previous))
            .min()
            .ok_or(AllocationError::Exhausted)?;
        if previous.is_some() {
            sink.bytes(b",")?;
        }
        json_string(sink, current)?;
        previous = Some(current);
    }
    sink.bytes(b"],\"product_version\":")?;
    crate::contract::ProductVersion::V0380.write_canonical(sink)?;
    sink.bytes(b",\"protocol_version\":1},\"operation\":\"diagnostics.get\"}")
}

fn write_capabilities(
    sink: &mut impl Sink,
    rich: bool,
    runtime: &crate::runtime::RuntimeService,
) -> Result<(), AllocationError> {
    // Decide visibility before obtaining owned version/identity snapshots.
    // Public observation borrows readiness only; it never clones private metadata.
    let (codex, claude) = if rich {
        (runtime.ready_provider(crate::contract::Provider::Codex),
         runtime.ready_provider(crate::contract::Provider::Claude))
    } else {
        (None, None)
    };
    let agent_ready = if rich {
        codex.is_some() || claude.is_some()
    } else {
        runtime.is_provider_ready(crate::contract::Provider::Codex)
            || runtime.is_provider_ready(crate::contract::Provider::Claude)
    };
    sink.bytes(b"{\"data\":{\"max_message_bytes\":")?;
    crate::contract::MessageLimit::new(MAX_MESSAGE_BYTES as u64)
        .expect("wire limit")
        .write_canonical(sink)?;
    sink.bytes(b",\"operations\":")?;
    write_implemented_operations(sink, agent_ready)?;
    sink.bytes(b",\"providers\":")?;
    if rich {
        sink.bytes(b"[")?;
        if let Some(ready) = &claude {
            sink.bytes(b"{\"provider\":\"claude\",\"version\":")?;
            json_string(sink, &ready.version)?;
            sink.bytes(b"}")?;
        }
        if let Some(ready) = &codex {
            if claude.is_some() {
                sink.bytes(b",")?;
            }
            sink.bytes(b"{\"provider\":\"codex\",\"version\":")?;
            json_string(sink, &ready.version)?;
            sink.bytes(b"}")?;
        }
        sink.bytes(b"]")?;
    } else {
        sink.bytes(b"null")?;
    }
    sink.bytes(b",\"replay_capacity\":{\"active_bytes\":")?;
    crate::contract::P::new(ACTIVE_BYTES as u64)
        .expect("active capacity")
        .write_canonical(sink)?;
    sink.bytes(b",\"retained_bytes\":")?;
    crate::contract::P::new(RETAINED_BYTES as u64)
        .expect("retained capacity")
        .write_canonical(sink)?;
    sink.bytes(b"},\"schema_version\":1,\"shell_profile_ids\":")?;
    if rich {
        sink.bytes(b"[\"pwsh\"]")?;
    } else {
        sink.bytes(b"null")?;
    }
    sink.bytes(b"},\"operation\":\"capabilities.get\"}")
}

#[cfg(test)]
mod capability_visibility_tests {
    use super::*;
    use super::testing::Harness;
    use serde_json::{json, Value};

    const PROJECT: &str = "30000000-0000-4000-8000-000000000877";

    fn request(h: &Harness, operation: &str, params: Value) -> Request {
        crate::contract::parse_request(&serde_json::to_vec(&json!({
            "schema_version":1, "instance_id":h.instance_id(),
            "operation_id":uuid::Uuid::new_v4().to_string(),
            "expected_topology_revision":null, "operation":operation, "params":params
        })).unwrap()).unwrap()
    }

    fn fixture() -> (Harness, Arc<crate::runtime::RuntimeService>) {
        let h = Harness::new(vec![ProjectId::new(PROJECT).unwrap()]);
        let runtime = Arc::clone(&h.authorization().shared.inner.lock().unwrap().runtime);
        runtime.testing_install_ready_providers();
        assert!(runtime.is_provider_ready(crate::contract::Provider::Codex));
        assert!(runtime.is_provider_ready(crate::contract::Provider::Claude));
        assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
        (h, runtime)
    }

    fn value(response: &Response) -> Value {
        serde_json::to_value(response).unwrap()
    }

    #[test]
    fn ready_public_capabilities_never_read_details_or_enqueue_probes() {
        let (h, runtime) = fixture();
        for scope in [None, Some("metadata"), Some("control"), Some("read_output")] {
            let c = h.connect("private-observer");
            if let Some(scope) = scope {
                c.request(&request(&h, "connection.request",
                    json!({"project_ids":[PROJECT],"scopes":[scope]}))).unwrap();
                // Metadata remains pending; the other scopes are granted.
                if scope != "metadata" {
                    h.owner(&request(&h, "connection.decide", json!({
                        "connection_id":c.connection_id(),"decision":"allow",
                        "project_ids":[PROJECT],"scopes":[scope]
                    })));
                }
            }
            for params in [json!({}), json!({"refresh":false})] {
                let got = value(&c.request(&request(&h, "capabilities.get", params)).unwrap());
                assert_eq!(got["accepted"], true, "{got}");
                assert_eq!(got["result"]["data"]["providers"], Value::Null);
                assert_eq!(got["result"]["data"]["shell_profile_ids"], Value::Null);
                assert!(got["result"]["data"]["operations"].as_array().unwrap()
                    .iter().any(|operation| operation == "agent.launch"));
                assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
            }
            let denied = value(&c.request(&request(&h, "capabilities.get",
                json!({"refresh":true}))).unwrap());
            assert_eq!(denied["error"]["code"], "permission_denied");
            assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
        }
        // Denied and revoked connections cannot regain observation authority.
        for decision in ["deny", "revoke"] {
            let c = h.connect("private-observer");
            c.request(&request(&h, "connection.request",
                json!({"project_ids":[PROJECT],"scopes":["metadata"]}))).unwrap();
            if decision == "deny" {
                h.owner(&request(&h, "connection.decide", json!({
                    "connection_id":c.connection_id(),"decision":"deny",
                    "project_ids":[],"scopes":[]
                })));
            } else {
                h.owner(&request(&h, "connection.decide", json!({
                    "connection_id":c.connection_id(),"decision":"allow",
                    "project_ids":[PROJECT],"scopes":["metadata"]
                })));
                h.owner(&request(&h, "connection.revoke",
                    json!({"connection_id":c.connection_id()})));
            }
            assert!(c.request(&request(&h, "capabilities.get", json!({}))).is_none());
            assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
        }
        h.close_generation();
        assert!(h.try_owner(&request(&h, "capabilities.get", json!({}))).is_none());
        assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
    }

    #[test]
    fn ready_details_require_metadata_while_diagnostics_only_borrows() {
        let (h, runtime) = fixture();
        let c = h.connect("metadata-observer");
        c.request(&request(&h, "connection.request",
            json!({"project_ids":[PROJECT],"scopes":["metadata"]}))).unwrap();
        h.owner(&request(&h, "connection.decide", json!({
            "connection_id":c.connection_id(),"decision":"allow",
            "project_ids":[PROJECT],"scopes":["metadata"]
        })));
        let diagnostic = value(&c.request(&request(&h, "diagnostics.get", json!({}))).unwrap());
        assert_eq!(diagnostic["accepted"], true);
        assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
        for owner in [false, true] {
            let before = runtime.testing_provider_observation_counts();
            let q = request(&h, "capabilities.get", json!({"refresh":true}));
            let response = if owner { h.owner(&q) } else { c.request(&q).unwrap() };
            let got = value(&response);
            assert_eq!(got["accepted"], true, "{got}");
            assert_eq!(got["result"]["data"]["providers"], json!([
                {"provider":"claude","version":"9.999.0"},
                {"provider":"codex","version":"9.999.0"}
            ]));
            let after = runtime.testing_provider_observation_counts();
            assert!(after[0] > before[0] && after[1] > before[1]);
            assert_eq!(after[2], before[2] + 1);
            assert_eq!(after[3], before[3] + 1);
        }
    }

    #[test]
    fn public_projection_borrows_ready_and_closing_without_detail_reads() {
        let (_h, runtime) = fixture();
        let mut measure = crate::contract::ingress::Measure(0);
        write_capabilities(&mut measure, false, &runtime).unwrap();
        write_diagnostics(&mut measure, &runtime).unwrap();
        assert!(measure.0 > 0);
        assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
        assert!(runtime.drain_provider_probes());
        assert!(!runtime.is_provider_ready(crate::contract::Provider::Codex));
        let mut closing = crate::contract::ingress::Measure(0);
        write_capabilities(&mut closing, false, &runtime).unwrap();
        write_diagnostics(&mut closing, &runtime).unwrap();
        assert!(closing.0 < measure.0);
        assert_eq!(runtime.testing_provider_observation_counts(), [0; 4]);
    }
}

fn write_uuid_set(sink: &mut impl Sink, values: &[[u8; 36]]) -> Result<(), AllocationError> {
    sink.bytes(b"[")?;
    let mut previous: Option<[u8; 36]> = None;
    for _ in 0..values.len() {
        let current = values
            .iter()
            .copied()
            .filter(|value| previous.is_none_or(|previous| *value > previous))
            .min()
            .ok_or(AllocationError::Exhausted)?;
        if previous.is_some() {
            sink.bytes(b",")?;
        }
        write_uuid_bytes(sink, &current)?;
        previous = Some(current);
    }
    sink.bytes(b"]")
}

fn write_scope_set(sink: &mut impl Sink, values: &[Scope]) -> Result<(), AllocationError> {
    sink.bytes(b"[")?;
    let mut previous: Option<&str> = None;
    for _ in 0..values.len() {
        let current = values
            .iter()
            .map(|scope| scope.wire())
            .filter(|value| previous.is_none_or(|previous| *value > previous))
            .min()
            .ok_or(AllocationError::Exhausted)?;
        if previous.is_some() {
            sink.bytes(b",")?;
        }
        json_string(sink, current)?;
        previous = Some(current);
    }
    sink.bytes(b"]")
}

fn write_param_uuid_set(
    sink: &mut impl Sink,
    values: &StringSet<ProjectId>,
) -> Result<(), AllocationError> {
    sink.bytes(b"[")?;
    let mut previous: Option<&str> = None;
    for _ in 0..values.len() {
        let current = values
            .iter()
            .map(ProjectId::as_str)
            .filter(|value| previous.is_none_or(|previous| *value > previous))
            .min()
            .ok_or(AllocationError::Exhausted)?;
        if previous.is_some() {
            sink.bytes(b",")?;
        }
        json_string(sink, current)?;
        previous = Some(current);
    }
    sink.bytes(b"]")
}

fn write_param_scope_set(
    sink: &mut impl Sink,
    values: &StringSet<Scope>,
) -> Result<(), AllocationError> {
    write_scope_set(sink, values)
}

fn live_state(record: &ConnectionRecord) -> LiveConnectionState {
    match record.state {
        RecordState::Authenticating => LiveConnectionState::Authenticating,
        RecordState::Unpaired => LiveConnectionState::Unpaired,
        RecordState::Pending => LiveConnectionState::Pending,
        RecordState::Granted => LiveConnectionState::Granted,
        RecordState::Closing => LiveConnectionState::Closing,
        RecordState::Finished => LiveConnectionState::Finished,
    }
}

fn write_connection_info(
    sink: &mut impl Sink,
    record: &ConnectionRecord,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"connection_id\":")?;
    write_uuid_bytes(sink, &record.connection_key)?;
    sink.bytes(b",\"executable_name\":")?;
    match &record.executable_name {
        Some(name) => json_string(sink, name.as_str())?,
        None => sink.bytes(b"null")?,
    }
    sink.bytes(b",\"granted_project_ids\":")?;
    write_uuid_set(sink, &record.granted_project_ids)?;
    sink.bytes(b",\"granted_scopes\":")?;
    write_scope_set(sink, &record.granted_scopes)?;
    sink.bytes(b",\"requested_project_ids\":")?;
    write_uuid_set(sink, &record.requested_project_ids)?;
    sink.bytes(b",\"requested_scopes\":")?;
    write_scope_set(sink, &record.requested_scopes)?;
    sink.bytes(b",\"state\":")?;
    live_state(record).write_canonical(sink)?;
    sink.bytes(b"}")
}

fn write_connection_list(sink: &mut impl Sink, state: &State) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"connections\":[")?;
    for (index, entry) in state.connection_index.iter().enumerate() {
        if index != 0 {
            sink.bytes(b",")?;
        }
        write_connection_info(sink, &state.connections[entry.slot])?;
    }
    sink.bytes(b"]},\"operation\":\"connection.list\"}")
}

fn write_connection_request(
    sink: &mut impl Sink,
    connection_key: &[u8; 36],
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"connection_id\":")?;
    write_uuid_bytes(sink, connection_key)?;
    sink.bytes(b",\"state\":\"pending\"},\"operation\":\"connection.request\"}")
}

fn write_connection_decide(
    sink: &mut impl Sink,
    connection_key: &[u8; 36],
    granted: bool,
    params: &crate::contract::ConnectionDecideParams,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"connection_id\":")?;
    write_uuid_bytes(sink, connection_key)?;
    sink.bytes(b",\"project_ids\":")?;
    if granted {
        write_param_uuid_set(sink, &params.project_ids)?;
    } else {
        sink.bytes(b"[]")?;
    }
    sink.bytes(b",\"scopes\":")?;
    if granted {
        write_param_scope_set(sink, &params.scopes)?;
    } else {
        sink.bytes(b"[]")?;
    }
    sink.bytes(if granted {
        b",\"state\":\"granted\"},\"operation\":\"connection.decide\"}"
    } else {
        b",\"state\":\"revoked\"},\"operation\":\"connection.decide\"}"
    })
}

fn write_connection_revoke(
    sink: &mut impl Sink,
    connection_key: &[u8; 36],
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"connection_id\":")?;
    write_uuid_bytes(sink, connection_key)?;
    sink.bytes(b",\"state\":\"revoked\"},\"operation\":\"connection.revoke\"}")
}

fn owner_list_bytes(state: &State) -> Result<usize, AllocationError> {
    const SIZING: &str = "00000000-0000-4000-8000-000000000000";
    let mut measure = Measure(0);
    write_success_prefix(&mut measure, SIZING, SIZING, MAX_SAFE_INTEGER)?;
    write_connection_list(&mut measure, state)?;
    write_success_suffix(&mut measure, MAX_SAFE_INTEGER)?;
    Ok(measure.0)
}

fn required_scope(operation: OperationName) -> Option<Scope> {
    use OperationName::*;
    match operation {
        CapabilitiesGet | ConnectionRequest => None,
        ConnectionList | ConnectionDecide | ConnectionRevoke | HostStop | ProjectOpen
        | ProjectForget | LayoutSave | LayoutRestore => None,
        ProjectList | PaneList | RunGet | EventsWait | DiagnosticsGet => Some(Scope::Metadata),
        OutputRead | ArtifactRegister | ArtifactList | ArtifactRead | ArtifactDiff
        | ArtifactChoose | ArtifactChoiceList => {
            Some(Scope::ReadOutput)
        }
        ProjectSelect | PaneCreate | PaneSplit | PaneSelect | PaneClose | PaneResize
        | ShellLaunch | AgentLaunch | InputWrite | InputKey | RunInterrupt | OperationGet => {
            Some(Scope::Control)
        }
    }
}

#[allow(dead_code)]
fn response_instance(request: &Request, current: &InstanceId) -> InstanceId {
    request
        .instance_id
        .0
        .clone()
        .unwrap_or_else(|| current.clone())
}

#[allow(dead_code)]
fn success_response(
    request: &Request,
    current: &InstanceId,
    event_seq: u64,
    result: Success,
) -> Response {
    Response {
        schema_version: Version::new(1).expect("schema v1"),
        instance_id: response_instance(request, current),
        operation_id: request.operation_id.clone(),
        accepted: true,
        topology_revision: U::new(0).expect("initial topology revision"),
        event_seq: U::new(event_seq).expect("bounded event sequence"),
        result: Nullable(Some(result)),
        error: Nullable(None),
    }
}

#[allow(dead_code)]
fn error_response(
    request: &Request,
    current: &InstanceId,
    event_seq: u64,
    code: ErrorCode,
) -> Response {
    Response {
        schema_version: Version::new(1).expect("schema v1"),
        instance_id: response_instance(request, current),
        operation_id: request.operation_id.clone(),
        accepted: false,
        topology_revision: U::new(0).expect("initial topology revision"),
        event_seq: U::new(event_seq).expect("bounded event sequence"),
        result: Nullable(None),
        error: Nullable(Some(
            code.with_target(None)
                .expect("an absent target is legal for every error"),
        )),
    }
}

#[cfg(debug_assertions)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProductPhase {
    SendGate,
    OwnerPublication,
    EventWait,
    ProtocolSeal,
}

#[cfg(debug_assertions)]
#[derive(Clone)]
pub struct PhaseHold {
    phase: ProductPhase,
    connection_key: Option<[u8; 36]>,
    entered: Arc<(Mutex<bool>, Condvar)>,
    release: Arc<(Mutex<bool>, Condvar)>,
}

#[cfg(debug_assertions)]
static PHASE_HOLD: Mutex<Vec<PhaseHold>> = Mutex::new(Vec::new());

#[cfg(debug_assertions)]
impl PhaseHold {
    pub fn install(phase: ProductPhase) -> Self {
        Self::install_key(phase, None)
    }

    pub fn install_for(phase: ProductPhase, connection: &ConnectionId) -> Self {
        Self::install_key(phase, Some(validated_key(connection.as_str())))
    }

    fn install_key(phase: ProductPhase, connection_key: Option<[u8; 36]>) -> Self {
        let hold = Self {
            phase,
            connection_key,
            entered: Arc::new((Mutex::new(false), Condvar::new())),
            release: Arc::new((Mutex::new(false), Condvar::new())),
        };
        PHASE_HOLD.lock().expect("phase hold").push(hold.clone());
        hold
    }

    pub fn wait_entered(&self) {
        let (lock, cvar) = &*self.entered;
        let mut entered = lock.lock().expect("entered");
        let deadline = Instant::now() + Duration::from_secs(15);
        while !*entered {
            let now = Instant::now();
            if now >= deadline {
                panic!("product phase hold did not enter");
            }
            let (guard, timed) = cvar
                .wait_timeout(entered, deadline.saturating_duration_since(now))
                .expect("entered wait");
            entered = guard;
            if timed.timed_out() && !*entered {
                panic!("product phase hold did not enter");
            }
        }
    }

    pub fn release_waiters(&self) {
        let (lock, cvar) = &*self.release;
        *lock.lock().expect("release") = true;
        cvar.notify_all();
    }

    pub fn clear(&self) {
        let mut holds = PHASE_HOLD.lock().expect("phase hold");
        holds.retain(|hold| !Arc::ptr_eq(&hold.entered, &self.entered));
    }
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestingConnectionSnapshot {
    pub connection_id: String,
    pub state: &'static str,
    pub granted_project_ids: Vec<String>,
    pub granted_scopes: Vec<&'static str>,
}

#[cfg(debug_assertions)]
#[derive(Debug, Clone, Copy)]
pub struct TestingReplayReceipt {
    pub phase: &'static str,
    pub event_seq: Option<u64>,
    pub topology_revision: Option<u64>,
}

#[cfg(debug_assertions)]
pub(crate) fn wait_owner_publication() {
    wait_product_phase(ProductPhase::OwnerPublication, None);
}

#[cfg(debug_assertions)]
fn wait_product_phase(phase: ProductPhase, connection_key: Option<&[u8; 36]>) {
    let hold = PHASE_HOLD.lock().ok().and_then(|guard| {
        guard
            .iter()
            .find(|hold| {
                hold.phase == phase
                    && (hold.connection_key.is_none()
                        || connection_key
                            .is_some_and(|key| hold.connection_key.as_ref() == Some(key)))
            })
            .cloned()
    });
    let Some(hold) = hold else {
        return;
    };
    {
        let (lock, cvar) = &*hold.entered;
        *lock.lock().expect("entered") = true;
        cvar.notify_all();
    }
    let (lock, cvar) = &*hold.release;
    let mut released = lock.lock().expect("release");
    let deadline = Instant::now() + Duration::from_secs(15);
    while !*released {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let (guard, timed) = cvar
            .wait_timeout(released, deadline.saturating_duration_since(now))
            .expect("release wait");
        released = guard;
        if timed.timed_out() {
            break;
        }
    }
}

#[cfg(debug_assertions)]
pub use crate::runtime::{RetainedCleanupObservation, RetainedCleanupSnapshot};

#[cfg(debug_assertions)]
pub mod testing {
    use super::*;
    use crate::contract::canonical_request;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Condvar, Mutex};

    pub use super::{PhaseHold, ProductPhase, TestingConnectionSnapshot, TestingReplayReceipt};

    pub struct SendGateHold<'a> {
        _guard: std::sync::MutexGuard<'a, ()>,
    }

    struct TestCancel {
        cancelled: AtomicBool,
        count: AtomicUsize,
        observed: Mutex<bool>,
        changed: Condvar,
    }

    impl TestCancel {
        fn new() -> Self {
            Self {
                cancelled: AtomicBool::new(false),
                count: AtomicUsize::new(0),
                observed: Mutex::new(false),
                changed: Condvar::new(),
            }
        }

        fn wait(&self) {
            let mut observed = self.observed.lock().expect("test cancellation lock");
            while !*observed {
                observed = self.changed.wait(observed).expect("test cancellation wait");
            }
        }
    }

    impl CancelSignal for TestCancel {
        fn cancel(&self) {
            self.cancelled.store(true, Ordering::SeqCst);
            self.count.fetch_add(1, Ordering::SeqCst);
            if let Ok(mut observed) = self.observed.lock() {
                *observed = true;
                self.changed.notify_all();
            }
        }
    }

    #[derive(Clone)]
    pub struct Harness {
        auth: Arc<Authorization>,
    }

    #[derive(Clone)]
    pub struct Client {
        auth: Arc<Authorization>,
        lease: ConnectionLease,
        cancellation: Arc<TestCancel>,
    }

    pub struct ManagedClientGuard {
        client: Client,
        published: bool,
    }

    pub struct SpawnPreparedGuard {
        auth: Arc<Authorization>,
        hook: Arc<dyn Fn(&crate::contract::RunId) + Send + Sync>,
    }

    impl Drop for SpawnPreparedGuard {
        fn drop(&mut self) {
            if let Ok(mut state) = self.auth.shared.inner.lock() {
                if state
                    .testing_spawn_prepared_hook
                    .as_ref()
                    .is_some_and(|armed| Arc::ptr_eq(armed, &self.hook))
                {
                    state.testing_spawn_prepared_hook = None;
                }
            }
        }
    }

    pub struct SpawnExecutableGuard {
        auth: Arc<Authorization>,
    }

    impl Drop for SpawnExecutableGuard {
        fn drop(&mut self) {
            if let Ok(mut state) = self.auth.shared.inner.lock() {
                state.testing_spawn_executable = None;
            }
        }
    }

    impl ManagedClientGuard {
        pub fn client(&self) -> Client {
            self.client.clone()
        }
    }

    impl Drop for ManagedClientGuard {
        fn drop(&mut self) {
            let published = self.published;
            let client = &self.client;
            let cleanup = || {
                if !published {
                    assert!(
                        client.auth.abort_unspawned(&client.lease, || true),
                        "unpublished managed worker must abort_unspawned"
                    );
                    return;
                }
                assert!(
                    client.auth.finish_worker(&client.lease, || true),
                    "managed finish_worker must succeed during cleanup"
                );
                let join = client
                    .auth
                    .claim_next_ready()
                    .expect("claim_next_ready must return the managed worker");
                assert_eq!(
                    &join.connection_key,
                    client.lease.connection_key(),
                    "claimed worker connection_key must match managed lease"
                );
                assert!(
                    Arc::ptr_eq(&join.token, &client.lease.token),
                    "claimed worker token must match managed lease"
                );
                join.handle.join().expect("managed worker join");
                assert!(
                    client.auth.retire_worker(&join.connection_key, &join.token),
                    "managed retire_worker must succeed"
                );
            };
            if std::thread::panicking() {
                let _ = catch_unwind(AssertUnwindSafe(cleanup));
            } else {
                cleanup();
            }
        }
    }

    impl Harness {
        pub fn use_hook_for_next_prepared_spawn(
            &self,
            hook: Arc<dyn Fn(&crate::contract::RunId) + Send + Sync>,
        ) -> SpawnPreparedGuard {
            let mut state = self
                .auth
                .shared
                .inner
                .lock()
                .expect("test authorization lock");
            assert!(
                state.testing_spawn_prepared_hook.is_none(),
                "only one prepared hook may be armed"
            );
            state.testing_spawn_prepared_hook = Some(Arc::clone(&hook));
            drop(state);
            SpawnPreparedGuard {
                auth: Arc::clone(&self.auth),
                hook,
            }
        }

        pub fn use_executable_for_next_spawn(
            &self,
            executable: impl Into<String>,
        ) -> SpawnExecutableGuard {
            let mut state = self
                .auth
                .shared
                .inner
                .lock()
                .expect("test authorization lock");
            assert!(
                state.testing_spawn_executable.is_none(),
                "only one scoped spawn executable may be armed"
            );
            state.testing_spawn_executable = Some(executable.into());
            drop(state);
            SpawnExecutableGuard {
                auth: Arc::clone(&self.auth),
            }
        }

        pub fn connect_managed(&self, executable_name: &str) -> ManagedClientGuard {
            {
                let state = self
                    .auth
                    .shared
                    .inner
                    .lock()
                    .expect("managed actor precondition lock");
                assert!(
                    state
                        .connections
                        .iter()
                        .all(|record| matches!(record.worker, WorkerOwnership::Fixture)),
                    "connect_managed requires every existing worker ownership to be Fixture"
                );
            }
            let cancellation = Arc::new(TestCancel::new());
            let lease = self
                .auth
                .admit_worker(cancellation.clone())
                .expect("admit managed worker")
            .expect("worker accepted");
            let mut guard = ManagedClientGuard {
                client: Client {
                    auth: self.auth.clone(),
                    lease,
                    cancellation,
                },
                published: false,
            };
            let charged = charge_executable_name(
                self.auth.allocations(),
                NonEmpty::new(executable_name).expect("test executable name"),
            )
            .expect("charge name");
            assert!(
                self.auth.mark_verified(&guard.client.lease, charged),
                "managed worker mark_verified"
            );
            match self.auth.publish_worker(
                &guard.client.lease,
                std::thread::spawn(|| {}),
                || true,
                || true,
            ) {
                WorkerPublish::Published => {
                    guard.published = true;
                }
                WorkerPublish::GenerationFailed => {
                    guard.published = true;
                    panic!("publish_worker generation failed for managed worker");
                }
                WorkerPublish::Rejected(rejected) => {
                    let _ = rejected.join();
                    panic!("publish_worker rejected managed worker");
                }
            }
            guard
        }
    }

    impl Client {
        pub fn finish_worker_for_test(&self) -> bool {
            self.auth.finish_worker(&self.lease, || true)
        }
    }

    impl Harness {
        pub fn new(registered_projects: Vec<ProjectId>) -> Self {
            Self {
                auth: Arc::new(Authorization::new(registered_projects)),
            }
        }

        pub fn instance_id(&self) -> InstanceId {
            self.auth.instance_id().clone()
        }

        pub fn authorization(&self) -> Arc<Authorization> {
            self.auth.clone()
        }

        pub fn start_provider_probes(&self) {
            self.auth.start_provider_probes();
        }

        pub fn set_provider_revalidate_hook(
            &self,
            provider: crate::contract::Provider,
            hook: Arc<dyn Fn() + Send + Sync>,
        ) -> bool {
            let runtime = match self.auth.shared.inner.lock() {
                Ok(state) => Arc::clone(&state.runtime),
                Err(_) => return false,
            };
            runtime
                .ready_provider(provider)
                .is_some_and(|ready| ready.set_revalidate_hook(hook))
        }

        pub fn allocations(&self) -> &AllocationAuthority {
            self.auth.allocations()
        }

        pub fn fail_next_artifact_response_write(&self) {
            relock_state(&self.auth).testing_fail_artifact_response_write = true;
        }

        pub fn connect(&self, executable_name: &str) -> Client {
            self.try_connect(executable_name)
                .expect("test generation is open")
        }

        pub fn try_connect(&self, executable_name: &str) -> Option<Client> {
            let cancellation = Arc::new(TestCancel::new());
            let lease = self.auth.attach_verified_fixture(
                NonEmpty::new(executable_name).expect("test executable name"),
                cancellation.clone(),
            )?;
            Some(Client {
                auth: self.auth.clone(),
                lease,
                cancellation,
            })
        }

        fn reply_buffer(&self) -> ChargedVec<u8> {
            ChargedVec::with_capacity(
                self.auth.allocations(),
                AllocationPool::ActiveOwner,
                MAX_MESSAGE_BYTES,
                MAX_MESSAGE_BYTES,
            )
            .expect("test owner reply buffer")
        }

        fn prepared(
            &self,
            request: &Request,
            pool: AllocationPool,
        ) -> crate::contract::ingress::PreparedRequest {
            let bytes = canonical_request(request).expect("valid test request");
            let mut frame = crate::host::admission::OwnedFrame::allocate(
                self.auth.allocations(),
                pool,
                bytes.len(),
            )
            .expect("test frame");
            frame.copy_from_slice(&bytes);
            crate::contract::ingress::prepare_request(frame, self.auth.allocations(), pool)
                .expect("prepared test request")
        }

        pub fn owner(&self, request: &Request) -> Response {
            let prepared = self.prepared(request, AllocationPool::ActiveOwner);
            let mut body = self.reply_buffer();
            let mut dispatch = self
                .auth
                .dispatch_owner(prepared.request(), prepared.canonical(), &mut body)
                .expect("test authorization lock");
            dispatch.signal_cancellations();
            if let Some(hold) = dispatch.observation.take() {
                self.auth.release_observation(hold);
            }
            crate::contract::parse_response(prepared.request(), &body).expect("owner reply")
        }

        pub fn owner_after<G>(
            &self,
            request: &Request,
            after_prepare: impl FnOnce(&AllocationAuthority) -> G,
        ) -> Response {
            let prepared = self.prepared(request, AllocationPool::ActiveOwner);
            let mut body = self.reply_buffer();
            let _hold = after_prepare(self.auth.allocations());
            let mut dispatch = self
                .auth
                .dispatch_owner(prepared.request(), prepared.canonical(), &mut body)
                .expect("test authorization lock");
            dispatch.signal_cancellations();
            if let Some(hold) = dispatch.observation.take() {
                self.auth.release_observation(hold);
            }
            crate::contract::parse_response(prepared.request(), &body).expect("owner reply")
        }

        pub fn poison_event_waiters(&self) {
            let mutexes = {
                let state = self
                    .auth
                    .shared
                    .inner
                    .lock()
                    .expect("test authorization lock");
                state
                    .events
                    .waiters
                    .iter()
                    .map(|record| Arc::clone(&record.mutex))
                    .collect::<Vec<_>>()
            };
            for mutex in mutexes {
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    let _guard = mutex.lock().expect("waiter mutex");
                    panic!("intentional event waiter mutex poison");
                }));
            }
        }

        pub fn record_count(&self) -> usize {
            self.auth.record_count()
        }

        pub fn close_generation(&self) {
            let closed = self.auth.close_generation();
            closed.signal_cancellations();
            closed.reap_jobs();
        }

        pub fn authentication_permitted(&self) -> bool {
            self.auth.begin_authentication().is_some()
        }

        pub fn proof_send_permitted(&self) -> bool {
            self.auth.begin_proof_send().is_some()
        }

        pub fn generation_is_closed(&self) -> bool {
            self.auth
                .shared
                .inner
                .lock()
                .map(|state| state.generation != GenerationState::Open)
                .unwrap_or(false)
        }

        pub fn event_seq(&self) -> u64 {
            self.auth.event_seq()
        }

        pub fn set_event_seq_to_max(&self) {
            self.auth.set_event_seq_to_max();
        }

        pub fn record_states(&self) -> Vec<&'static str> {
            self.auth
                .shared
                .inner
                .lock()
                .map(|state| {
                    state
                        .connections
                        .iter()
                        .map(|record| match record.state {
                            RecordState::Authenticating => "authenticating",
                            RecordState::Unpaired => "unpaired",
                            RecordState::Pending => "pending",
                            RecordState::Granted => "granted",
                            RecordState::Closing => "closing",
                            RecordState::Finished => "finished",
                        })
                        .collect()
                })
                .unwrap_or_default()
        }

        pub fn poison(&self) {
            let auth = self.auth.clone();
            let _ = catch_unwind(AssertUnwindSafe(move || {
                let _state = auth.shared.inner.lock().expect("test authorization lock");
                panic!("intentional authorization poison");
            }));
        }

        pub fn try_owner(&self, request: &Request) -> Option<Response> {
            let prepared = self.prepared(request, AllocationPool::ActiveOwner);
            let mut body = self.reply_buffer();
            let mut dispatch =
                self.auth
                    .dispatch_owner(prepared.request(), prepared.canonical(), &mut body)?;
            dispatch.signal_cancellations();
            if let Some(hold) = dispatch.observation.take() {
                self.auth.release_observation(hold);
            }
            Some(crate::contract::parse_response(prepared.request(), &body).expect("owner reply"))
        }
    }

    impl Client {
        pub fn request(&self, request: &Request) -> Option<Response> {
            let prepared = Harness {
                auth: self.auth.clone(),
            }
            .prepared(request, AllocationPool::ActivePublic);
            let mut body = ChargedVec::with_capacity(
                self.auth.allocations(),
                AllocationPool::ActivePublic,
                MAX_MESSAGE_BYTES,
                MAX_MESSAGE_BYTES,
            )
            .expect("test public reply buffer");
            let dispatch = self.auth.dispatch_client(
                &self.lease,
                prepared.request(),
                prepared.canonical(),
                &mut body,
            )?;
            let response =
                crate::contract::parse_response(prepared.request(), &body).expect("client reply");
            let sent = self.auth.send_if_current(&self.lease, || response);
            if let Some(hold) = dispatch.observation {
                self.auth.release_observation(hold);
            }
            sent
        }

        pub fn connection_id(&self) -> ConnectionId {
            self.lease.connection_id().clone()
        }

        pub fn disconnect(&self) {
            self.auth.disconnect(&self.lease);
        }

        pub fn cancelled(&self) -> bool {
            self.cancellation.cancelled.load(Ordering::SeqCst)
        }

        pub fn cancellation_count(&self) -> usize {
            self.cancellation.count.load(Ordering::SeqCst)
        }

        pub fn send_if_current(&self) -> bool {
            self.auth.send_if_current(&self.lease, || ()).is_some()
        }

        pub fn hold_send_gate(&self) -> Option<SendGateHold<'_>> {
            Some(SendGateHold {
                _guard: self.lease.send_gate.lock().ok()?,
            })
        }

        pub fn wait_cancelled(&self) {
            self.cancellation.wait();
        }

        pub fn request_with_send<T>(
            &self,
            request: &Request,
            send: impl FnOnce(Response) -> T,
        ) -> Option<T> {
            let prepared = Harness {
                auth: self.auth.clone(),
            }
            .prepared(request, AllocationPool::ActivePublic);
            let mut body = ChargedVec::with_capacity(
                self.auth.allocations(),
                AllocationPool::ActivePublic,
                MAX_MESSAGE_BYTES,
                MAX_MESSAGE_BYTES,
            )
            .expect("test public reply buffer");
            let dispatch = self.auth.dispatch_client(
                &self.lease,
                prepared.request(),
                prepared.canonical(),
                &mut body,
            )?;
            let response =
                crate::contract::parse_response(prepared.request(), &body).expect("client reply");
            let sent = self.auth.send_if_current(&self.lease, || send(response));
            if let Some(hold) = dispatch.observation {
                self.auth.release_observation(hold);
            }
            sent
        }
    }
}
