use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::mem::{align_of, size_of};
use std::ops::{Deref, DerefMut};
use std::ptr::{null, null_mut, NonNull};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows_sys::Win32::System::Threading::{
    CreateEventW, ResetEvent, SetEvent, WaitForSingleObject, INFINITE,
};

use crate::auth::{
    CancelSignal, ClosingWorkerStep, ConnectionLease, WorkerLifecycleError, WorkerPublish,
    WorkerAdmissionError,
};

pub const RETAINED_BYTES: usize = 128 * 1024 * 1024;
pub const ACTIVE_PUBLIC_BYTES: usize = 128 * 1024 * 1024;
pub const ACTIVE_OWNER_BYTES: usize = 128 * 1024 * 1024;
pub const ACTIVE_BYTES: usize = ACTIVE_PUBLIC_BYTES + ACTIVE_OWNER_BYTES;
pub const PUBLIC_WORKER_STACK_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AllocationPool {
    ActivePublic,
    ActiveOwner,
    Retained,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AllocationError {
    Exhausted,
    Layout,
    Allocator,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AllocationSnapshot {
    pub active_public: usize,
    pub active_owner: usize,
    pub retained: usize,
}

struct Ledger {
    active_public: AtomicUsize,
    active_owner: AtomicUsize,
    retained: AtomicUsize,
    #[cfg(debug_assertions)]
    fail_allocations: AtomicUsize,
    #[cfg(test)]
    drop_events: std::sync::Mutex<Vec<&'static str>>,
}

/// The process-wide authority for all memory whose lifetime belongs to the host.
///
/// Claims use atomics so frame allocation never adds a second state mutex or
/// changes the authorization/send-gate lock order.
#[derive(Clone)]
pub struct AllocationAuthority {
    ledger: Arc<Ledger>,
}

impl AllocationAuthority {
    pub fn host() -> Self {
        Self::new()
    }

    fn new() -> Self {
        Self {
            ledger: Arc::new(Ledger {
                active_public: AtomicUsize::new(0),
                active_owner: AtomicUsize::new(0),
                retained: AtomicUsize::new(0),
                #[cfg(debug_assertions)]
                fail_allocations: AtomicUsize::new(0),
                #[cfg(test)]
                drop_events: std::sync::Mutex::new(Vec::new()),
            }),
        }
    }

    pub fn claim(
        &self,
        pool: AllocationPool,
        bytes: usize,
    ) -> Result<CapacityCharge, AllocationError> {
        let (counter, limit) = self.counter_and_limit(pool);
        let mut current = counter.load(Ordering::Acquire);
        loop {
            let next = current
                .checked_add(bytes)
                .ok_or(AllocationError::Exhausted)?;
            if next > limit {
                return Err(AllocationError::Exhausted);
            }
            match counter.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => {
                    return Ok(CapacityCharge {
                        ledger: self.ledger.clone(),
                        pool,
                        bytes,
                    })
                }
                Err(observed) => current = observed,
            }
        }
    }

    pub fn snapshot(&self) -> AllocationSnapshot {
        AllocationSnapshot {
            active_public: self.ledger.active_public.load(Ordering::Acquire),
            active_owner: self.ledger.active_owner.load(Ordering::Acquire),
            retained: self.ledger.retained.load(Ordering::Acquire),
        }
    }

    fn counter_and_limit(&self, pool: AllocationPool) -> (&AtomicUsize, usize) {
        match pool {
            AllocationPool::ActivePublic => (&self.ledger.active_public, ACTIVE_PUBLIC_BYTES),
            AllocationPool::ActiveOwner => (&self.ledger.active_owner, ACTIVE_OWNER_BYTES),
            AllocationPool::Retained => (&self.ledger.retained, RETAINED_BYTES),
        }
    }

    pub(crate) fn allocation_is_forced_to_fail(&self) -> bool {
        #[cfg(debug_assertions)]
        {
            return self
                .ledger
                .fail_allocations
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| {
                    remaining.checked_sub(1)
                })
                .is_ok_and(|remaining| remaining == 1);
        }
        #[cfg(not(debug_assertions))]
        {
            false
        }
    }

    #[cfg(test)]
    fn fail_next_allocation(&self) {
        self.fail_after_allocations(0);
    }

    #[cfg(debug_assertions)]
    pub(crate) fn fail_after_allocations(&self, successful_allocations: usize) {
        self.ledger
            .fail_allocations
            .store(successful_allocations.saturating_add(1), Ordering::Release);
    }

    #[cfg(test)]
    fn drop_events(&self) -> Vec<&'static str> {
        self.ledger
            .drop_events
            .lock()
            .expect("allocation drop event lock")
            .clone()
    }
}

pub struct CapacityCharge {
    ledger: Arc<Ledger>,
    pool: AllocationPool,
    bytes: usize,
}

/// A heap-owning value paired with the exact active-memory charge for its
/// backing allocation. The value is destroyed before its charge is returned.
pub(crate) struct ChargedValue<T> {
    value: Option<T>,
    charge: Option<CapacityCharge>,
}

impl<T> ChargedValue<T> {
    pub(crate) fn from_parts(value: T, charge: CapacityCharge) -> Self {
        Self {
            value: Some(value),
            charge: Some(charge),
        }
    }

    pub(crate) fn charged_bytes(&self) -> usize {
        self.charge.as_ref().map_or(0, CapacityCharge::bytes)
    }

    #[cfg(debug_assertions)]
    pub(crate) fn into_inner(mut self) -> T {
        let value = self.value.take().expect("charged value is live");
        drop(self.charge.take());
        value
    }
}

impl<T> Deref for ChargedValue<T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        self.value.as_ref().expect("charged value is live")
    }
}

impl<T> Drop for ChargedValue<T> {
    fn drop(&mut self) {
        drop(self.value.take());
        drop(self.charge.take());
    }
}

impl CapacityCharge {
    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }

    pub(crate) fn reduce_to(&mut self, bytes: usize) {
        assert!(bytes <= self.bytes, "capacity charge can only shrink");
        let released = self.bytes - bytes;
        self.bytes = bytes;
        if released != 0 {
            release(&self.ledger, self.pool, released);
        }
    }
}

impl Drop for CapacityCharge {
    fn drop(&mut self) {
        if self.bytes != 0 {
            release(&self.ledger, self.pool, self.bytes);
            self.bytes = 0;
        }
        #[cfg(test)]
        self.ledger
            .drop_events
            .lock()
            .expect("allocation drop event lock")
            .push("charge");
    }
}
fn release(ledger: &Ledger, pool: AllocationPool, bytes: usize) {
    let counter = match pool {
        AllocationPool::ActivePublic => &ledger.active_public,
        AllocationPool::ActiveOwner => &ledger.active_owner,
        AllocationPool::Retained => &ledger.retained,
    };
    let previous = counter.fetch_sub(bytes, Ordering::AcqRel);
    assert!(previous >= bytes, "allocation charge underflow");
}

/// A frame body and its exact active-memory charge.
///
/// This uses an exact `Layout` rather than `Vec`, so the complete allocation is
/// claimed before calling the allocator and the charged byte count cannot differ
/// from a hidden capacity.
pub struct OwnedFrame {
    pointer: NonNull<u8>,
    length: usize,
    charge: Option<CapacityCharge>,
}

unsafe impl Send for OwnedFrame {}

impl OwnedFrame {
    pub fn allocate(
        authority: &AllocationAuthority,
        pool: AllocationPool,
        length: usize,
    ) -> Result<Self, AllocationError> {
        if length == 0 {
            return Err(AllocationError::Layout);
        }
        let layout = Layout::from_size_align(length, align_of::<u8>())
            .map_err(|_| AllocationError::Layout)?;
        let charge = authority.claim(pool, layout.size())?;
        if authority.allocation_is_forced_to_fail() {
            drop(charge);
            return Err(AllocationError::Allocator);
        }
        let pointer = NonNull::new(unsafe { alloc_zeroed(layout) });
        match pointer {
            Some(pointer) => Ok(Self {
                pointer,
                length,
                charge: Some(charge),
            }),
            None => {
                drop(charge);
                Err(AllocationError::Allocator)
            }
        }
    }

    pub fn charged_bytes(&self) -> usize {
        self.charge.as_ref().map_or(0, CapacityCharge::bytes)
    }
}

impl Deref for OwnedFrame {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        unsafe { std::slice::from_raw_parts(self.pointer.as_ptr(), self.length) }
    }
}

impl DerefMut for OwnedFrame {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { std::slice::from_raw_parts_mut(self.pointer.as_ptr(), self.length) }
    }
}

impl Drop for OwnedFrame {
    fn drop(&mut self) {
        let layout = Layout::from_size_align(self.length, align_of::<u8>())
            .expect("OwnedFrame stored a valid layout");
        unsafe { dealloc(self.pointer.as_ptr(), layout) };
        #[cfg(test)]
        if let Some(charge) = self.charge.as_ref() {
            charge
                .ledger
                .drop_events
                .lock()
                .expect("allocation drop event lock")
                .push("allocation");
        }
        drop(self.charge.take());
    }
}

/// A fallibly allocated `Vec` whose actual capacity remains charged for its
/// complete lifetime. `capacity_upper_bound_bytes` is the fixed-toolchain bound
/// proved by the caller and is claimed before the allocator is entered.
pub struct ChargedVec<T> {
    values: Option<Vec<T>>,
    charge: Option<CapacityCharge>,
}

impl<T> ChargedVec<T> {
    pub fn with_capacity(
        authority: &AllocationAuthority,
        pool: AllocationPool,
        elements: usize,
        capacity_upper_bound_bytes: usize,
    ) -> Result<Self, AllocationError> {
        if size_of::<T>() == 0 {
            return Err(AllocationError::Layout);
        }
        let minimum = elements
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if capacity_upper_bound_bytes < minimum {
            return Err(AllocationError::Layout);
        }
        let mut charge = authority.claim(pool, capacity_upper_bound_bytes)?;
        if authority.allocation_is_forced_to_fail() {
            drop(charge);
            return Err(AllocationError::Allocator);
        }
        let mut values = Vec::new();
        values
            .try_reserve_exact(elements)
            .map_err(|_| AllocationError::Allocator)?;
        let actual = values
            .capacity()
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if actual > capacity_upper_bound_bytes {
            drop(values);
            drop(charge);
            return Err(AllocationError::Allocator);
        }
        charge.reduce_to(actual);
        Ok(Self {
            values: Some(values),
            charge: Some(charge),
        })
    }

    pub fn capacity_bytes(&self) -> usize {
        self.charge.as_ref().map_or(0, CapacityCharge::bytes)
    }

    pub(crate) fn empty(authority: &AllocationAuthority, pool: AllocationPool) -> Self {
        Self {
            values: Some(Vec::new()),
            charge: Some(CapacityCharge {
                ledger: authority.ledger.clone(),
                pool,
                bytes: 0,
            }),
        }
    }

    pub(crate) fn capacity_elements(&self) -> usize {
        self.values
            .as_ref()
            .expect("charged vector is live")
            .capacity()
    }

    /// Replaces a retained table buffer while charging the complete replacement
    /// to an active pool for the period in which both allocations are live.
    ///
    /// The caller supplies the fixed-toolchain upper bound for the replacement.
    /// No element is moved and no existing charge changes until every claim and
    /// the replacement allocation have succeeded.
    pub fn try_grow_retained(
        &mut self,
        authority: &AllocationAuthority,
        transient_pool: AllocationPool,
        new_capacity_elements: usize,
        new_capacity_upper_bound_bytes: usize,
    ) -> Result<(), AllocationError> {
        if transient_pool == AllocationPool::Retained {
            return Err(AllocationError::Layout);
        }
        let old_values = self.values.as_ref().expect("charged vector is live");
        let old_charge = self.charge.as_ref().expect("charged vector is charged");
        if old_charge.pool != AllocationPool::Retained
            || !Arc::ptr_eq(&old_charge.ledger, &authority.ledger)
        {
            return Err(AllocationError::Layout);
        }
        if new_capacity_elements <= old_values.capacity() {
            return Ok(());
        }
        let minimum = new_capacity_elements
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        let old_capacity_bytes = old_charge.bytes;
        if new_capacity_upper_bound_bytes < minimum
            || new_capacity_upper_bound_bytes <= old_capacity_bytes
        {
            return Err(AllocationError::Layout);
        }
        let retained_increment_upper_bound = new_capacity_upper_bound_bytes
            .checked_sub(old_capacity_bytes)
            .ok_or(AllocationError::Layout)?;
        let mut retained_increment =
            authority.claim(AllocationPool::Retained, retained_increment_upper_bound)?;
        let mut transient = authority.claim(transient_pool, new_capacity_upper_bound_bytes)?;
        if authority.allocation_is_forced_to_fail() {
            return Err(AllocationError::Allocator);
        }

        let mut replacement = Vec::new();
        replacement
            .try_reserve_exact(new_capacity_elements)
            .map_err(|_| AllocationError::Allocator)?;
        let actual_capacity_bytes = replacement
            .capacity()
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if actual_capacity_bytes > new_capacity_upper_bound_bytes
            || actual_capacity_bytes <= old_capacity_bytes
            || replacement.capacity() < old_values.len()
        {
            return Err(AllocationError::Allocator);
        }
        let retained_increment_bytes = actual_capacity_bytes
            .checked_sub(old_capacity_bytes)
            .ok_or(AllocationError::Layout)?;
        let combined_retained_bytes = old_capacity_bytes
            .checked_add(retained_increment_bytes)
            .ok_or(AllocationError::Layout)?;
        transient.reduce_to(actual_capacity_bytes);
        retained_increment.reduce_to(retained_increment_bytes);

        let mut previous = self.values.take().expect("charged vector is live");
        replacement.append(&mut previous);
        drop(previous);
        let mut retained = self.charge.take().expect("charged vector is charged");
        retained.bytes = combined_retained_bytes;
        retained_increment.bytes = 0;
        self.values = Some(replacement);
        self.charge = Some(retained);
        drop(transient);
        Ok(())
    }

    /// Best-effort post-seal compaction. The old retained allocation and the
    /// complete active replacement are charged until the old backing is freed.
    /// A failed claim/allocation leaves bytes, capacity, and charges untouched.
    pub(crate) fn try_compact_retained(
        &mut self,
        transient_pool: AllocationPool,
    ) -> Result<(), AllocationError> {
        let old_values = self.values.as_ref().expect("charged vector is live");
        let old_charge = self.charge.as_ref().expect("charged vector is charged");
        if old_charge.pool != AllocationPool::Retained || transient_pool == AllocationPool::Retained
        {
            return Err(AllocationError::Layout);
        }
        if old_values.len() == old_values.capacity() {
            return Ok(());
        }
        let elements = old_values.len();
        let upper = elements
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        let authority = AllocationAuthority {
            ledger: old_charge.ledger.clone(),
        };
        let mut transient = authority.claim(transient_pool, upper)?;
        if authority.allocation_is_forced_to_fail() {
            return Err(AllocationError::Allocator);
        }
        let mut replacement = Vec::new();
        replacement
            .try_reserve_exact(elements)
            .map_err(|_| AllocationError::Allocator)?;
        let actual = replacement
            .capacity()
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if actual > upper || actual > old_charge.bytes || replacement.capacity() < elements {
            return Err(AllocationError::Allocator);
        }
        transient.reduce_to(actual);
        let mut previous = self.values.take().expect("charged vector is live");
        replacement.append(&mut previous);
        drop(previous);
        // Releasing retained credit before freeing the old allocation would
        // undercount the period with both allocations live.
        self.values = Some(replacement);
        self.charge
            .as_mut()
            .expect("charged vector is charged")
            .reduce_to(actual);
        drop(transient);
        Ok(())
    }

    pub(crate) fn try_grow(
        &mut self,
        authority: &AllocationAuthority,
        new_capacity_elements: usize,
        new_capacity_upper_bound_bytes: usize,
    ) -> Result<(), AllocationError> {
        let old_values = self.values.as_ref().expect("charged vector is live");
        let old_charge = self.charge.as_ref().expect("charged vector is charged");
        if !Arc::ptr_eq(&old_charge.ledger, &authority.ledger)
            || old_charge.pool == AllocationPool::Retained
        {
            return Err(AllocationError::Layout);
        }
        if new_capacity_elements <= old_values.capacity() {
            return Ok(());
        }
        let minimum = new_capacity_elements
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if new_capacity_upper_bound_bytes < minimum {
            return Err(AllocationError::Layout);
        }
        let pool = old_charge.pool;
        let mut grown = authority.claim(pool, new_capacity_upper_bound_bytes)?;
        if authority.allocation_is_forced_to_fail() {
            return Err(AllocationError::Allocator);
        }
        let mut replacement = Vec::new();
        replacement
            .try_reserve_exact(new_capacity_elements)
            .map_err(|_| AllocationError::Allocator)?;
        let actual_capacity_bytes = replacement
            .capacity()
            .checked_mul(size_of::<T>())
            .ok_or(AllocationError::Layout)?;
        if actual_capacity_bytes > new_capacity_upper_bound_bytes
            || replacement.capacity() < old_values.len()
        {
            return Err(AllocationError::Allocator);
        }
        grown.reduce_to(actual_capacity_bytes);
        let mut previous = self.values.take().expect("charged vector is live");
        replacement.append(&mut previous);
        drop(previous);
        drop(self.charge.take());
        self.values = Some(replacement);
        self.charge = Some(grown);
        Ok(())
    }

    pub fn try_push(&mut self, value: T) -> Result<(), AllocationError> {
        let values = self.values.as_mut().expect("charged vector is live");
        if values.len() == values.capacity() {
            return Err(AllocationError::Exhausted);
        }
        values.push(value);
        Ok(())
    }

    pub(crate) fn try_insert(
        &mut self,
        index: usize,
        value: T,
    ) -> Result<(), AllocationError> {
        let values = self.values.as_mut().expect("charged vector is live");
        if index > values.len() || values.len() == values.capacity() {
            return Err(AllocationError::Exhausted);
        }
        values.insert(index, value);
        Ok(())
    }

    pub(crate) fn remove(&mut self, index: usize) -> Option<T> {
        let values = self.values.as_mut().expect("charged vector is live");
        (index < values.len()).then(|| values.remove(index))
    }

    pub(crate) fn clear(&mut self) {
        self.values
            .as_mut()
            .expect("charged vector is live")
            .clear();
    }

    pub(crate) fn try_extend_from_slice(&mut self, values: &[T]) -> Result<(), AllocationError>
    where
        T: Copy,
    {
        let target = self.values.as_mut().expect("charged vector is live");
        let final_length = target
            .len()
            .checked_add(values.len())
            .ok_or(AllocationError::Exhausted)?;
        if final_length > target.capacity() {
            return Err(AllocationError::Exhausted);
        }
        target.extend_from_slice(values);
        Ok(())
    }

    pub(crate) fn try_resize(&mut self, length: usize, value: T) -> Result<(), AllocationError>
    where
        T: Clone,
    {
        let target = self.values.as_mut().expect("charged vector is live");
        if length > target.capacity() {
            return Err(AllocationError::Exhausted);
        }
        target.resize(length, value);
        Ok(())
    }
}

impl<T> Deref for ChargedVec<T> {
    type Target = [T];

    fn deref(&self) -> &Self::Target {
        self.values.as_deref().expect("charged vector is live")
    }
}

impl<T> DerefMut for ChargedVec<T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.values.as_deref_mut().expect("charged vector is live")
    }
}

impl<T> Drop for ChargedVec<T> {
    fn drop(&mut self) {
        drop(self.values.take());
        #[cfg(test)]
        if let Some(charge) = self.charge.as_ref() {
            charge
                .ledger
                .drop_events
                .lock()
                .expect("allocation drop event lock")
                .push("allocation");
        }
        drop(self.charge.take());
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionSupervisorError {
    Exhausted,
    Spawn,
    Signal,
    Wait,
    Join,
    State,
}

/// A normal admission refusal never enters the fatal supervisor error path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionAdmission {
    Spawned,
    Refused,
}

struct ManualResetEvent {
    handle: HANDLE,
    #[cfg(test)]
    fail_set: AtomicBool,
    #[cfg(test)]
    fail_reset: AtomicBool,
}

unsafe impl Send for ManualResetEvent {}
unsafe impl Sync for ManualResetEvent {}

impl ManualResetEvent {
    fn new() -> Result<Self, ConnectionSupervisorError> {
        let handle = unsafe { CreateEventW(null(), 1, 0, null()) };
        if handle.is_null() {
            Err(ConnectionSupervisorError::Signal)
        } else {
            Ok(Self {
                handle,
                #[cfg(test)]
                fail_set: AtomicBool::new(false),
                #[cfg(test)]
                fail_reset: AtomicBool::new(false),
            })
        }
    }

    fn set(&self) -> bool {
        #[cfg(test)]
        if self.fail_set.swap(false, Ordering::SeqCst) {
            return false;
        }
        unsafe { SetEvent(self.handle) != 0 }
    }

    fn reset(&self) -> bool {
        #[cfg(test)]
        if self.fail_reset.swap(false, Ordering::SeqCst) {
            return false;
        }
        unsafe { ResetEvent(self.handle) != 0 }
    }

    fn wait(&self) -> bool {
        unsafe { WaitForSingleObject(self.handle, INFINITE) == WAIT_OBJECT_0 }
    }

    fn raw(&self) -> HANDLE {
        self.handle
    }
}

impl Drop for ManualResetEvent {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                CloseHandle(self.handle);
            }
            self.handle = null_mut();
        }
    }
}

struct SupervisorInner {
    authorization: Arc<crate::auth::Authorization>,
    generation_cancel: Arc<dyn CancelSignal>,
    completion: ManualResetEvent,
    progress: ManualResetEvent,
}

#[derive(Clone)]
pub struct ConnectionSupervisor(Arc<SupervisorInner>);

struct WorkerCompletion {
    supervisor: ConnectionSupervisor,
    lease: ConnectionLease,
}

impl Drop for WorkerCompletion {
    fn drop(&mut self) {
        if !self
            .supervisor
            .0
            .authorization
            .finish_worker(&self.lease, || self.supervisor.0.completion.set())
        {
            self.supervisor.fail_generation();
        }
    }
}

impl ConnectionSupervisor {
    pub fn new(
        authorization: Arc<crate::auth::Authorization>,
        generation_cancel: Arc<dyn CancelSignal>,
    ) -> Result<Self, ConnectionSupervisorError> {
        Ok(Self(Arc::new(SupervisorInner {
            authorization,
            generation_cancel,
            completion: ManualResetEvent::new()?,
            progress: ManualResetEvent::new()?,
        })))
    }

    pub(crate) fn completion_raw(&self) -> HANDLE {
        self.0.completion.raw()
    }

    pub fn spawn(
        &self,
        cancel: Arc<dyn CancelSignal>,
        body: impl FnOnce(ConnectionLease) + Send + 'static,
    ) -> Result<ConnectionAdmission, ConnectionSupervisorError> {
        self.spawn_before_publish(cancel, body, || {})
    }

    fn spawn_before_publish(
        &self,
        cancel: Arc<dyn CancelSignal>,
        body: impl FnOnce(ConnectionLease) + Send + 'static,
        before_publish: impl FnOnce(),
    ) -> Result<ConnectionAdmission, ConnectionSupervisorError> {
        let admission = self
            .0
            .authorization
            .admit_worker(cancel.clone())
            .map_err(|error| match error {
                WorkerAdmissionError::Exhausted => ConnectionSupervisorError::Exhausted,
                WorkerAdmissionError::State => ConnectionSupervisorError::State,
            })?;
        let Some(lease) = admission else {
            // Dropping the unused body also drops its newly accepted pipe.
            return Ok(ConnectionAdmission::Refused);
        };
        let worker_lease = lease.clone();
        let worker_supervisor = self.clone();
        let handle = match std::thread::Builder::new()
            .name("winsmux-workspace-connection".to_owned())
            .stack_size(PUBLIC_WORKER_STACK_BYTES)
            .spawn(move || {
                let _completion = WorkerCompletion {
                    supervisor: worker_supervisor,
                    lease: worker_lease.clone(),
                };
                body(worker_lease);
            }) {
            Ok(handle) => handle,
            Err(_) => {
                if !self
                    .0
                    .authorization
                    .abort_unspawned(&lease, || self.0.progress.set())
                {
                    self.fail_generation();
                }
                return Err(ConnectionSupervisorError::Spawn);
            }
        };
        before_publish();
        match self.0.authorization.publish_worker(
            &lease,
            handle,
            || self.0.completion.set(),
            || self.0.progress.set(),
        ) {
            WorkerPublish::Published => Ok(ConnectionAdmission::Spawned),
            WorkerPublish::GenerationFailed => {
                self.fail_generation();
                Err(ConnectionSupervisorError::Signal)
            }
            WorkerPublish::Rejected(handle) => {
                cancel.cancel();
                let _ = handle.join();
                self.fail_generation();
                Err(ConnectionSupervisorError::State)
            }
        }
    }

    pub fn reap_completed(&self) -> Result<usize, ConnectionSupervisorError> {
        let first = self
            .0
            .authorization
            .claim_ready_after_reset(|| self.0.completion.reset())
            .map_err(|_| {
                self.fail_generation();
                ConnectionSupervisorError::Signal
            })?;
        let mut count = 0;
        let mut first_error = None;
        if let Some(worker) = first {
            self.join_and_retire(worker, &mut first_error);
            count += 1;
            while let Some(worker) = self.0.authorization.claim_next_ready() {
                self.join_and_retire(worker, &mut first_error);
                count += 1;
            }
        }
        first_error.map_or(Ok(count), Err)
    }

    pub fn close_and_reap(&self) -> Result<usize, ConnectionSupervisorError> {
        self.0.generation_cancel.cancel();
        self.0
            .authorization
            .close_generation()
            .signal_cancellations();
        let mut count = 0;
        let mut first_error = None;
        loop {
            match self
                .0
                .authorization
                .closing_worker_step(|| self.0.progress.reset())
            {
                Ok(ClosingWorkerStep::Join(worker)) => {
                    self.join_and_retire(worker, &mut first_error);
                    count += 1;
                }
                Ok(ClosingWorkerStep::WaitForPublication) => {
                    if !self.0.progress.wait() {
                        first_error.get_or_insert(ConnectionSupervisorError::Wait);
                        break;
                    }
                }
                Ok(ClosingWorkerStep::Done) => break,
                Err(WorkerLifecycleError::ProgressSignal) => {
                    first_error.get_or_insert(ConnectionSupervisorError::Signal);
                    break;
                }
                Err(_) => {
                    first_error.get_or_insert(ConnectionSupervisorError::State);
                    break;
                }
            }
        }
        first_error.map_or(Ok(count), Err)
    }

    fn join_and_retire(
        &self,
        worker: crate::auth::WorkerJoin,
        first_error: &mut Option<ConnectionSupervisorError>,
    ) {
        let crate::auth::WorkerJoin {
            connection_key,
            token,
            handle,
        } = worker;
        if handle.join().is_err() {
            first_error.get_or_insert(ConnectionSupervisorError::Join);
        }
        if !self.0.authorization.retire_worker(&connection_key, &token) {
            first_error.get_or_insert(ConnectionSupervisorError::State);
        }
    }

    fn fail_generation(&self) {
        self.0.generation_cancel.cancel();
        self.0
            .authorization
            .fail_generation()
            .signal_cancellations();
    }

    #[cfg(test)]
    fn inject_completion_reset_failure(&self) {
        self.0.completion.fail_reset.store(true, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Condvar, Mutex};

    struct TestCancel {
        signaled: AtomicBool,
        gate: Mutex<bool>,
        changed: Condvar,
    }

    impl TestCancel {
        fn new() -> Self {
            Self {
                signaled: AtomicBool::new(false),
                gate: Mutex::new(false),
                changed: Condvar::new(),
            }
        }

        fn wait(&self) {
            let mut signaled = self.gate.lock().expect("test cancellation lock");
            while !*signaled {
                signaled = self.changed.wait(signaled).expect("test cancellation wait");
            }
        }
    }

    impl CancelSignal for TestCancel {
        fn cancel(&self) {
            self.signaled.store(true, Ordering::SeqCst);
            let mut signaled = self.gate.lock().expect("test cancellation lock");
            *signaled = true;
            self.changed.notify_all();
        }
    }

    fn supervisor() -> (
        Arc<crate::auth::Authorization>,
        ConnectionSupervisor,
        Arc<TestCancel>,
    ) {
        let authorization = Arc::new(crate::auth::Authorization::new(Vec::new()));
        let generation_cancel = Arc::new(TestCancel::new());
        let supervisor =
            ConnectionSupervisor::new(authorization.clone(), generation_cancel.clone())
                .expect("supervisor events");
        (authorization, supervisor, generation_cancel)
    }

    #[test]
    fn owned_frame_claims_exact_capacity_and_releases_allocation_first() {
        let authority = AllocationAuthority::new();
        {
            let frame = OwnedFrame::allocate(&authority, AllocationPool::ActivePublic, 37)
                .expect("frame allocation");
            assert_eq!(frame.len(), 37);
            assert_eq!(frame.charged_bytes(), 37);
            assert_eq!(authority.snapshot().active_public, 37);
        }
        assert_eq!(authority.snapshot().active_public, 0);
        assert_eq!(authority.drop_events(), ["allocation", "charge"]);
    }

    #[test]
    fn allocation_failure_returns_the_preclaim_without_exposing_a_buffer() {
        let authority = AllocationAuthority::new();
        authority.fail_next_allocation();
        assert!(matches!(
            OwnedFrame::allocate(&authority, AllocationPool::ActiveOwner, 19),
            Err(AllocationError::Allocator)
        ));
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    #[test]
    fn pool_limit_denies_before_entering_the_allocator() {
        let authority = AllocationAuthority::new();
        let retained = authority
            .claim(AllocationPool::ActivePublic, ACTIVE_PUBLIC_BYTES)
            .expect("fill public pool");
        authority.fail_next_allocation();
        assert!(matches!(
            OwnedFrame::allocate(&authority, AllocationPool::ActivePublic, 1),
            Err(AllocationError::Exhausted)
        ));
        assert_eq!(
            authority.ledger.fail_allocations.load(Ordering::Acquire),
            1,
            "the allocator fault remains unused because admission denied first"
        );
        drop(retained);
        assert_eq!(authority.snapshot().active_public, 0);
    }

    #[test]
    fn charged_vec_accounts_actual_capacity_and_never_grows_implicitly() {
        let authority = AllocationAuthority::new();
        let mut values = ChargedVec::<u64>::with_capacity(
            &authority,
            AllocationPool::Retained,
            4,
            4 * size_of::<u64>(),
        )
        .expect("fixed-toolchain exact capacity");
        assert_eq!(
            values
                .values
                .as_ref()
                .expect("charged vector is live")
                .capacity(),
            4
        );
        assert_eq!(values.capacity_bytes(), 4 * size_of::<u64>());
        for value in 0..4 {
            values.try_push(value).expect("pre-reserved push");
        }
        assert_eq!(values.try_push(4), Err(AllocationError::Exhausted));
        drop(values);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn charged_vec_exposes_only_capacity_preserving_mutation() {
        let authority = AllocationAuthority::new();
        let mut values =
            ChargedVec::<u8>::with_capacity(&authority, AllocationPool::ActiveOwner, 4, 4)
                .expect("fixed-toolchain exact capacity");
        let exposed: &mut [u8] = DerefMut::deref_mut(&mut values);
        assert!(exposed.is_empty());

        values.try_push(1).expect("reserved push");
        values
            .try_extend_from_slice(&[2, 3, 4])
            .expect("reserved extend");
        values[0] = 9;
        assert_eq!(&*values, &[9, 2, 3, 4]);
        assert_eq!(values.capacity_bytes(), 4);
        assert_eq!(authority.snapshot().active_owner, 4);

        assert_eq!(
            values.try_extend_from_slice(&[5]),
            Err(AllocationError::Exhausted)
        );
        assert_eq!(&*values, &[9, 2, 3, 4]);
        assert_eq!(values.capacity_bytes(), 4);
        drop(values);
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    #[test]
    fn retained_compaction_preserves_elements_and_releases_capacity() {
        let authority = AllocationAuthority::new();
        let mut values = ChargedVec::<u64>::with_capacity(
            &authority,
            AllocationPool::Retained,
            128,
            128 * size_of::<u64>(),
        )
        .unwrap();
        for value in [7, 11, 13] {
            values.try_push(value).unwrap();
        }
        values
            .try_compact_retained(AllocationPool::ActiveOwner)
            .unwrap();
        assert_eq!(&*values, &[7, 11, 13]);
        assert_eq!(values.capacity_bytes(), 3 * size_of::<u64>());
        assert_eq!(authority.snapshot().retained, values.capacity_bytes());
        assert_eq!(authority.snapshot().active_owner, 0);
        drop(values);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn retained_compaction_failures_preserve_payload_and_all_charges() {
        let authority = AllocationAuthority::new();
        let mut values =
            ChargedVec::<u8>::with_capacity(&authority, AllocationPool::Retained, 4096, 4096)
                .unwrap();
        values.try_extend_from_slice(&[1, 2, 3]).unwrap();
        let fill = authority
            .claim(AllocationPool::ActiveOwner, ACTIVE_OWNER_BYTES)
            .unwrap();
        let before = authority.snapshot();
        assert_eq!(
            values.try_compact_retained(AllocationPool::ActiveOwner),
            Err(AllocationError::Exhausted)
        );
        assert_eq!(authority.snapshot(), before);
        assert_eq!(&*values, &[1, 2, 3]);
        assert_eq!(values.capacity_bytes(), 4096);
        drop(fill);
        let before = authority.snapshot();
        authority.fail_next_allocation();
        assert_eq!(
            values.try_compact_retained(AllocationPool::ActiveOwner),
            Err(AllocationError::Allocator)
        );
        assert_eq!(authority.snapshot(), before);
        assert_eq!(&*values, &[1, 2, 3]);
        assert_eq!(values.capacity_bytes(), 4096);
        assert_eq!(
            values.try_compact_retained(AllocationPool::Retained),
            Err(AllocationError::Layout)
        );
        assert_eq!(authority.snapshot(), before);
        let mut active =
            ChargedVec::<u8>::with_capacity(&authority, AllocationPool::ActiveOwner, 16, 16)
                .unwrap();
        let before = authority.snapshot();
        assert_eq!(
            active.try_compact_retained(AllocationPool::ActivePublic),
            Err(AllocationError::Layout)
        );
        assert_eq!(authority.snapshot(), before);
        drop(active);
        drop(values);
        assert_eq!(authority.snapshot().active_owner, 0);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn retained_compaction_handles_empty_tight_and_public_transient() {
        let authority = AllocationAuthority::new();
        let mut values =
            ChargedVec::<u8>::with_capacity(&authority, AllocationPool::Retained, 16, 16).unwrap();
        values
            .try_compact_retained(AllocationPool::ActivePublic)
            .unwrap();
        assert!(values.is_empty());
        assert_eq!(values.capacity_bytes(), 0);
        assert_eq!(authority.snapshot().retained, 0);
        assert_eq!(authority.snapshot().active_public, 0);
        drop(values);
        let mut tight =
            ChargedVec::<u8>::with_capacity(&authority, AllocationPool::Retained, 3, 3).unwrap();
        tight.try_extend_from_slice(&[4, 5, 6]).unwrap();
        let before = authority.snapshot();
        authority.fail_next_allocation();
        tight
            .try_compact_retained(AllocationPool::ActiveOwner)
            .unwrap();
        assert_eq!(&*tight, &[4, 5, 6]);
        assert_eq!(authority.snapshot(), before);
        assert!(matches!(
            OwnedFrame::allocate(&authority, AllocationPool::ActiveOwner, 1),
            Err(AllocationError::Allocator)
        ));
        drop(tight);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn retained_table_growth_moves_actual_capacity_after_releasing_old_backing() {
        let authority = AllocationAuthority::new();
        let mut values = ChargedVec::<u64>::with_capacity(
            &authority,
            AllocationPool::Retained,
            2,
            2 * size_of::<u64>(),
        )
        .expect("initial retained table");
        values.try_push(7).expect("first value");
        values.try_push(11).expect("second value");

        values
            .try_grow_retained(
                &authority,
                AllocationPool::ActiveOwner,
                4,
                4 * size_of::<u64>(),
            )
            .expect("grow retained table");

        assert_eq!(&*values, &[7, 11]);
        assert_eq!(values.capacity_bytes(), 4 * size_of::<u64>());
        assert_eq!(authority.snapshot().active_owner, 0);
        assert_eq!(authority.snapshot().retained, 4 * size_of::<u64>());
        values.try_push(13).expect("grown capacity remains usable");
        drop(values);
        assert_eq!(authority.snapshot().retained, 0);
    }

    #[test]
    fn retained_table_growth_failures_preserve_state_capacity_and_charges() {
        let authority = AllocationAuthority::new();
        let mut values = ChargedVec::<u64>::with_capacity(
            &authority,
            AllocationPool::Retained,
            2,
            2 * size_of::<u64>(),
        )
        .expect("initial retained table");
        values.try_push(7).expect("first value");
        let original_capacity = values.capacity_bytes();

        let active_fill = authority
            .claim(AllocationPool::ActiveOwner, ACTIVE_OWNER_BYTES)
            .expect("fill owner active pool");
        assert_eq!(
            values.try_grow_retained(
                &authority,
                AllocationPool::ActiveOwner,
                4,
                4 * size_of::<u64>(),
            ),
            Err(AllocationError::Exhausted)
        );
        assert_eq!(&*values, &[7]);
        assert_eq!(values.capacity_bytes(), original_capacity);
        assert_eq!(authority.snapshot().retained, original_capacity);
        drop(active_fill);

        authority.fail_next_allocation();
        assert_eq!(
            values.try_grow_retained(
                &authority,
                AllocationPool::ActiveOwner,
                4,
                4 * size_of::<u64>(),
            ),
            Err(AllocationError::Allocator)
        );
        assert_eq!(&*values, &[7]);
        assert_eq!(values.capacity_bytes(), original_capacity);
        assert_eq!(authority.snapshot().active_owner, 0);
        assert_eq!(authority.snapshot().retained, original_capacity);
    }

    #[test]
    fn preauth_worker_is_cancelled_and_retired_on_generation_close() {
        let (authorization, supervisor, generation_cancel) = supervisor();
        let connection_cancel = Arc::new(TestCancel::new());
        let worker_cancel = connection_cancel.clone();
        let worker_authorization = authorization.clone();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(0);
        supervisor
            .spawn(connection_cancel.clone(), move |lease| {
                assert!(worker_authorization
                    .begin_worker_authentication(&lease)
                    .is_some());
                started_tx.send(()).expect("authentication start receiver");
                worker_cancel.wait();
            })
            .expect("preauth worker");
        started_rx.recv().expect("authentication started");

        assert_eq!(authorization.record_count(), 1);
        let live_public = authorization.allocations().snapshot().active_public;
        assert!(live_public >= PUBLIC_WORKER_STACK_BYTES);
        assert_eq!(supervisor.close_and_reap(), Ok(1));
        assert!(generation_cancel.signaled.load(Ordering::SeqCst));
        assert!(connection_cancel.signaled.load(Ordering::SeqCst));
        assert_eq!(authorization.record_count(), 0);
        assert_eq!(authorization.allocations().snapshot().active_public, 0);
    }

    #[test]
    fn finished_before_publication_keeps_stack_reserved_until_join() {
        let (authorization, supervisor, _) = supervisor();
        let connection_cancel = Arc::new(TestCancel::new());
        let completion = supervisor.clone();
        supervisor
            .spawn_before_publish(
                connection_cancel,
                |_| {},
                move || assert!(completion.0.completion.wait()),
            )
            .expect("worker completes before handle publication");

        assert_eq!(authorization.record_count(), 1);
        let used = authorization.allocations().snapshot().active_public;
        assert!(used >= PUBLIC_WORKER_STACK_BYTES);
        let remaining = authorization
            .allocations()
            .claim(AllocationPool::ActivePublic, ACTIVE_PUBLIC_BYTES - used)
            .expect("fill remaining public pool");
        assert_eq!(
            supervisor.spawn(Arc::new(TestCancel::new()), |_| {}),
            Err(ConnectionSupervisorError::Exhausted)
        );
        assert_eq!(supervisor.reap_completed(), Ok(1));
        assert_eq!(authorization.record_count(), 0);
        assert_eq!(
            authorization.allocations().snapshot().active_public,
            ACTIVE_PUBLIC_BYTES - used
        );
        drop(remaining);
        assert_eq!(authorization.allocations().snapshot().active_public, 0);
    }

    #[test]
    fn panicking_worker_is_joined_once_and_releases_its_record() {
        let (authorization, supervisor, _) = supervisor();
        let completion = supervisor.clone();
        supervisor
            .spawn_before_publish(
                Arc::new(TestCancel::new()),
                |_| panic!("intentional connection worker panic"),
                move || assert!(completion.0.completion.wait()),
            )
            .expect("panicking worker is still published");

        assert_eq!(
            supervisor.reap_completed(),
            Err(ConnectionSupervisorError::Join)
        );
        assert_eq!(authorization.record_count(), 0);
        assert_eq!(authorization.allocations().snapshot().active_public, 0);
        assert_eq!(supervisor.reap_completed(), Ok(0));
    }

    #[test]
    fn reservation_does_not_reject_finished_worker_handle_publication() {
        let h = crate::auth::testing::Harness::new(Vec::new());
        let auth = h.authorization();
        let root = std::env::temp_dir().join(format!("winsmux-close-publication-{}", uuid::Uuid::new_v4()));
        assert!(auth.testing_install_isolated_layout(&root));
        let release = auth.testing_install_stop_join_gate(false);
        let supervisor = ConnectionSupervisor::new(auth.clone(), Arc::new(TestCancel::new())).unwrap();
        let (resume, wait) = std::sync::mpsc::channel();
        let body_auth = auth.clone();
        let completion = supervisor.clone();
        let command = crate::contract::parse_request(&serde_json::to_vec(&serde_json::json!({
            "schema_version":1,"instance_id":h.instance_id(),"operation_id":uuid::Uuid::new_v4().to_string(),
            "expected_topology_revision":null,"operation":"host.stop","params":{}
        })).unwrap()).unwrap();
        let mut stopping = None;
        assert_eq!(supervisor.spawn_before_publish(Arc::new(TestCancel::new()), move |lease| {
            wait.recv_timeout(std::time::Duration::from_secs(30)).unwrap();
            assert!(body_auth.begin_worker_authentication(&lease).is_none());
        }, || {
            stopping = Some(std::thread::spawn(move || h.owner(&command)));
            let start = std::time::Instant::now();
            while !auth.testing_stop_is_reserved() {
                assert!(start.elapsed() < std::time::Duration::from_secs(30));
                std::thread::yield_now();
            }
            resume.send(()).unwrap();
            assert!(completion.0.completion.wait());
        }), Ok(ConnectionAdmission::Spawned));
        assert_eq!(supervisor.reap_completed(), Ok(1));
        assert_eq!(supervisor.reap_completed(), Ok(0));
        assert_eq!(auth.record_count(), 0);
        assert_eq!(auth.allocations().snapshot().active_public, 0);
        release.send(()).unwrap();
        assert!(stopping.unwrap().join().unwrap().accepted);
        assert_eq!(supervisor.close_and_reap(), Ok(0));
    }

    #[test]
    fn completion_reset_failure_closes_generation_and_reaps_without_rewaiting_it() {
        let (authorization, supervisor, generation_cancel) = supervisor();
        let completion = supervisor.clone();
        supervisor
            .spawn_before_publish(
                Arc::new(TestCancel::new()),
                |_| {},
                move || assert!(completion.0.completion.wait()),
            )
            .expect("completed worker");
        supervisor.inject_completion_reset_failure();

        assert_eq!(
            supervisor.reap_completed(),
            Err(ConnectionSupervisorError::Signal)
        );
        assert!(generation_cancel.signaled.load(Ordering::SeqCst));
        assert_eq!(
            supervisor.spawn(Arc::new(TestCancel::new()), |_| {}),
            Ok(ConnectionAdmission::Refused)
        );
        assert_eq!(supervisor.close_and_reap(), Ok(1));
        assert_eq!(authorization.record_count(), 0);
        assert_eq!(authorization.allocations().snapshot().active_public, 0);
    }
}
