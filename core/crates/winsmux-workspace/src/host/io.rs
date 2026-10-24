use crate::auth::CancelSignal;
#[cfg(debug_assertions)]
use crate::contract::ConnectionId;
use crate::contract::MAX_MESSAGE_BYTES;
use crate::host::admission::{AllocationAuthority, AllocationPool, OwnedFrame};
use std::ptr::{null, null_mut};
#[cfg(debug_assertions)]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(debug_assertions)]
use std::sync::{Arc, Condvar, Mutex};
#[cfg(debug_assertions)]
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA,
    ERROR_OPERATION_ABORTED, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE, WAIT_FAILED,
    WAIT_OBJECT_0, WAIT_TIMEOUT,
};
#[cfg(debug_assertions)]
use windows_sys::Win32::Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::Pipes::ConnectNamedPipe;
use windows_sys::Win32::System::Threading::{
    CreateEventW, SetEvent, WaitForMultipleObjects, INFINITE,
};
#[cfg(debug_assertions)]
use windows_sys::Win32::System::Threading::GetCurrentProcess;
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IoError {
    Eof,
    Cancelled,
    Failed,
    Protocol,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum IoStart {
    Synchronous,
    Pending,
    Failed,
}

pub(crate) struct OwnedHandle(HANDLE);

unsafe impl Send for OwnedHandle {}
unsafe impl Sync for OwnedHandle {}

impl OwnedHandle {
    pub(crate) unsafe fn from_raw(handle: HANDLE) -> Result<Self, IoError> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            Err(IoError::Failed)
        } else {
            Ok(Self(handle))
        }
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

pub(crate) struct CancelEvent {
    handle: OwnedHandle,
}

impl CancelEvent {
    pub(crate) fn new() -> Result<Self, IoError> {
        let handle = unsafe { CreateEventW(null(), 1, 0, null()) };
        Ok(Self {
            handle: unsafe { OwnedHandle::from_raw(handle)? },
        })
    }

    pub(crate) fn signal(&self) {
        unsafe {
            SetEvent(self.handle.raw());
        }
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.handle.raw()
    }
}

impl CancelSignal for CancelEvent {
    fn cancel(&self) {
        self.signal();
    }
}

fn completion_event() -> Result<OwnedHandle, IoError> {
    let handle = unsafe { CreateEventW(null(), 1, 0, null()) };
    unsafe { OwnedHandle::from_raw(handle) }
}

fn check_cancellation(cancellations: &[HANDLE]) -> Result<(), IoError> {
    if cancellations.is_empty() {
        return Ok(());
    }
    let wait =
        unsafe { WaitForMultipleObjects(cancellations.len() as u32, cancellations.as_ptr(), 0, 0) };
    if wait == WAIT_TIMEOUT {
        Ok(())
    } else if wait >= WAIT_OBJECT_0 && wait - WAIT_OBJECT_0 < cancellations.len() as u32 {
        Err(IoError::Cancelled)
    } else {
        Err(IoError::Failed)
    }
}

const WAIT_HANDLE_CAP: usize = 8;

fn wait_pending(
    handle: HANDLE,
    overlapped: &OVERLAPPED,
    completion: HANDLE,
    cancellations: &[HANDLE],
) -> Result<u32, IoError> {
    if let Err(error) = check_cancellation(cancellations) {
        cancel_and_drain(handle, overlapped);
        return Err(error);
    }
    let count = cancellations
        .len()
        .checked_add(1)
        .filter(|count| *count <= WAIT_HANDLE_CAP)
        .ok_or(IoError::Failed)?;
    let mut handles = [null_mut(); WAIT_HANDLE_CAP];
    handles[0] = completion;
    handles[1..count].copy_from_slice(cancellations);
    let wait = unsafe { WaitForMultipleObjects(count as u32, handles.as_ptr(), 0, INFINITE) };
    if wait == WAIT_FAILED {
        cancel_and_drain(handle, overlapped);
        return Err(IoError::Failed);
    }
    if wait == WAIT_OBJECT_0 {
        if let Err(error) = check_cancellation(cancellations) {
            cancel_and_drain(handle, overlapped);
            return Err(error);
        }
        let mut transferred = 0;
        let completed = unsafe { GetOverlappedResult(handle, overlapped, &mut transferred, 0) };
        if completed == 0 {
            return match unsafe { GetLastError() } {
                ERROR_BROKEN_PIPE | ERROR_NO_DATA => Err(IoError::Eof),
                ERROR_OPERATION_ABORTED => Err(IoError::Cancelled),
                _ => Err(IoError::Failed),
            };
        }
        return Ok(transferred);
    }
    if wait > WAIT_OBJECT_0 && (wait - WAIT_OBJECT_0) < count as u32 {
        cancel_and_drain(handle, overlapped);
        return Err(IoError::Cancelled);
    }
    cancel_and_drain(handle, overlapped);
    Err(IoError::Failed)
}

/// Cancel an outstanding operation and synchronously collect its completion
/// before the OVERLAPPED, event, and caller buffer leave scope.
fn cancel_and_drain(handle: HANDLE, overlapped: &OVERLAPPED) {
    unsafe {
        CancelIoEx(handle, overlapped);
        let mut transferred = 0;
        GetOverlappedResult(handle, overlapped, &mut transferred, 1);
    }
}

fn read_once_with_checkpoint(
    handle: HANDLE,
    buffer: &mut [u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<usize, IoError> {
    check_cancellation(cancellations)?;
    let event = completion_event()?;
    let mut overlapped = OVERLAPPED::default();
    overlapped.hEvent = event.raw();
    let mut immediate = 0;
    let started = unsafe {
        ReadFile(
            handle,
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut immediate,
            &mut overlapped,
        )
    };
    let last_error = if started == 0 {
        Some(unsafe { GetLastError() })
    } else {
        None
    };
    checkpoint(if started != 0 {
        IoStart::Synchronous
    } else if last_error == Some(ERROR_IO_PENDING) {
        IoStart::Pending
    } else {
        IoStart::Failed
    });
    if let Err(error) = check_cancellation(cancellations) {
        if last_error == Some(ERROR_IO_PENDING) {
            cancel_and_drain(handle, &overlapped);
        }
        return Err(error);
    }
    let transferred = if started != 0 {
        immediate
    } else {
        match last_error.expect("failed ReadFile captured its error") {
            ERROR_IO_PENDING => wait_pending(handle, &overlapped, event.raw(), cancellations)?,
            ERROR_BROKEN_PIPE | ERROR_NO_DATA => return Err(IoError::Eof),
            ERROR_OPERATION_ABORTED => return Err(IoError::Cancelled),
            _ => return Err(IoError::Failed),
        }
    };
    if transferred == 0 {
        Err(IoError::Eof)
    } else {
        Ok(transferred as usize)
    }
}

fn write_once_with_checkpoint(
    handle: HANDLE,
    buffer: &[u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<usize, IoError> {
    check_cancellation(cancellations)?;
    let event = completion_event()?;
    let mut overlapped = OVERLAPPED::default();
    overlapped.hEvent = event.raw();
    let mut immediate = 0;
    let started = unsafe {
        WriteFile(
            handle,
            buffer.as_ptr(),
            buffer.len() as u32,
            &mut immediate,
            &mut overlapped,
        )
    };
    let last_error = if started == 0 {
        Some(unsafe { GetLastError() })
    } else {
        None
    };
    checkpoint(if started != 0 {
        IoStart::Synchronous
    } else if last_error == Some(ERROR_IO_PENDING) {
        IoStart::Pending
    } else {
        IoStart::Failed
    });
    if let Err(error) = check_cancellation(cancellations) {
        if last_error == Some(ERROR_IO_PENDING) {
            cancel_and_drain(handle, &overlapped);
        }
        return Err(error);
    }
    let transferred = if started != 0 {
        immediate
    } else {
        match last_error.expect("failed WriteFile captured its error") {
            ERROR_IO_PENDING => wait_pending(handle, &overlapped, event.raw(), cancellations)?,
            ERROR_BROKEN_PIPE | ERROR_NO_DATA => return Err(IoError::Eof),
            ERROR_OPERATION_ABORTED => return Err(IoError::Cancelled),
            _ => return Err(IoError::Failed),
        }
    };
    if transferred == 0 {
        Err(IoError::Failed)
    } else {
        Ok(transferred as usize)
    }
}

fn write_once(handle: HANDLE, buffer: &[u8], cancellations: &[HANDLE]) -> Result<usize, IoError> {
    write_once_with_checkpoint(handle, buffer, cancellations, |_| {})
}

pub(crate) fn read_exact(
    handle: HANDLE,
    buffer: &mut [u8],
    cancellations: &[HANDLE],
) -> Result<(), IoError> {
    read_exact_with_checkpoint(handle, buffer, cancellations, |_| {})
}

fn read_exact_with_checkpoint(
    handle: HANDLE,
    mut buffer: &mut [u8],
    cancellations: &[HANDLE],
    mut checkpoint: impl FnMut(IoStart),
) -> Result<(), IoError> {
    while !buffer.is_empty() {
        let read = read_once_with_checkpoint(handle, buffer, cancellations, &mut checkpoint)?;
        buffer = &mut buffer[read..];
    }
    Ok(())
}

pub(crate) fn write_all(
    handle: HANDLE,
    mut buffer: &[u8],
    cancellations: &[HANDLE],
) -> Result<(), IoError> {
    while !buffer.is_empty() {
        let written = write_once(handle, buffer, cancellations)?;
        buffer = &buffer[written..];
    }
    Ok(())
}

pub(crate) fn decode_length(header: [u8; 4]) -> Result<usize, IoError> {
    let length = u32::from_le_bytes(header) as usize;
    if (1..=MAX_MESSAGE_BYTES).contains(&length) {
        Ok(length)
    } else {
        Err(IoError::Protocol)
    }
}

pub(crate) fn read_frame(handle: HANDLE, cancellations: &[HANDLE]) -> Result<Vec<u8>, IoError> {
    let mut header = [0u8; 4];
    read_exact(handle, &mut header, cancellations)?;
    let length = decode_length(header)?;
    let mut body = vec![0u8; length];
    read_exact(handle, &mut body, cancellations)?;
    Ok(body)
}

pub(crate) fn read_frame_owned(
    handle: HANDLE,
    cancellations: &[HANDLE],
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<OwnedFrame, IoError> {
    let mut header = [0u8; 4];
    read_exact(handle, &mut header, cancellations)?;
    let length = decode_length(header)?;
    let mut body = OwnedFrame::allocate(authority, pool, length).map_err(|_| IoError::Failed)?;
    read_exact(handle, &mut body, cancellations)?;
    Ok(body)
}

pub(crate) fn write_frame(
    handle: HANDLE,
    body: &[u8],
    cancellations: &[HANDLE],
) -> Result<(), IoError> {
    write_frame_with_checkpoint(handle, body, cancellations, || {})
}

#[cfg(debug_assertions)]
pub(crate) fn write_public_frame(
    handle: HANDLE,
    body: &[u8],
    cancellations: &[HANDLE],
    connection: &ConnectionId,
) -> Result<(), IoError> {
    write_frame_with_checkpoint(handle, body, cancellations, || {
        wait_installed_write_body(connection, cancellations)
    })
}

#[cfg(debug_assertions)]
#[derive(Clone)]
pub struct WriteBodyHold {
    connection_key: [u8; 36],
    entered: Arc<(Mutex<bool>, Condvar)>,
    release: Arc<(Mutex<bool>, Condvar)>,
    live: Arc<AtomicBool>,
    cancel_handles: Arc<(Mutex<CancelPublication>, Condvar)>,
}

#[cfg(debug_assertions)]
struct CancelPublication {
    lease: Option<Arc<OwnedCancelLeaseInner>>,
    retired: bool,
}

#[cfg(debug_assertions)]
struct OwnedCancelLeaseInner {
    handles: Vec<OwnedHandle>,
}

#[cfg(debug_assertions)]
struct CancelWaitLease {
    inner: Arc<OwnedCancelLeaseInner>,
}

#[cfg(debug_assertions)]
fn duplicate_handle(source: HANDLE) -> Result<OwnedHandle, IoError> {
    if source.is_null() || source == INVALID_HANDLE_VALUE {
        return Err(IoError::Failed);
    }
    let mut target = null_mut();
    let process = unsafe { GetCurrentProcess() };
    let duplicated = unsafe {
        DuplicateHandle(
            process,
            source,
            process,
            &mut target,
            0,
            0,
            DUPLICATE_SAME_ACCESS,
        )
    };
    if duplicated == 0 {
        return Err(IoError::Failed);
    }
    match unsafe { OwnedHandle::from_raw(target) } {
        Ok(owned) => Ok(owned),
        Err(error) => {
            unsafe {
                CloseHandle(target);
            }
            Err(error)
        }
    }
}

#[cfg(debug_assertions)]
fn duplicate_cancel_handles(sources: &[HANDLE]) -> Result<Vec<OwnedHandle>, IoError> {
    if sources.is_empty() || sources.len() > WAIT_HANDLE_CAP {
        return Err(IoError::Failed);
    }
    let mut owned = Vec::with_capacity(sources.len());
    for source in sources {
        owned.push(duplicate_handle(*source)?);
    }
    Ok(owned)
}

#[cfg(debug_assertions)]
impl CancelWaitLease {
    fn wait_signalled(&self) {
        let count = self.inner.handles.len();
        if count == 0 || count > WAIT_HANDLE_CAP {
            panic!("write body hold cancel handle count exceeds wait cap");
        }
        let mut os_handles = [null_mut(); WAIT_HANDLE_CAP];
        for (index, handle) in self.inner.handles.iter().enumerate() {
            let raw = handle.raw();
            if raw.is_null() || raw == INVALID_HANDLE_VALUE {
                panic!("write body hold recorded an invalid cancel handle");
            }
            os_handles[index] = raw;
        }
        let timeout_ms = Duration::from_secs(15).as_millis() as u32;
        let wait = unsafe {
            WaitForMultipleObjects(count as u32, os_handles.as_ptr(), 0, timeout_ms)
        };
        if wait == WAIT_TIMEOUT {
            panic!("write body hold did not observe cancellation");
        }
        if wait >= WAIT_OBJECT_0 && (wait - WAIT_OBJECT_0) < count as u32 {
            return;
        }
        panic!("write body hold cancel wait failed");
    }
}

#[cfg(debug_assertions)]
static WRITE_BODY_HOLD: Mutex<Vec<WriteBodyHold>> = Mutex::new(Vec::new());

#[cfg(debug_assertions)]
fn connection_key(connection: &ConnectionId) -> [u8; 36] {
    connection
        .as_str()
        .as_bytes()
        .try_into()
        .expect("validated contract IDs are 36-byte UUIDs")
}

#[cfg(debug_assertions)]
impl WriteBodyHold {
    pub fn install_for(connection: &ConnectionId) -> Self {
        let hold = Self {
            connection_key: connection_key(connection),
            entered: Arc::new((Mutex::new(false), Condvar::new())),
            release: Arc::new((Mutex::new(false), Condvar::new())),
            live: Arc::new(AtomicBool::new(true)),
            cancel_handles: Arc::new((
                Mutex::new(CancelPublication {
                    lease: None,
                    retired: false,
                }),
                Condvar::new(),
            )),
        };
        WRITE_BODY_HOLD
            .lock()
            .expect("write body hold")
            .push(hold.clone());
        hold
    }

    pub fn wait_header_written(&self) {
        let (lock, cvar) = &*self.entered;
        let mut entered = lock.lock().expect("entered");
        let deadline = Instant::now() + Duration::from_secs(15);
        while !*entered {
            let now = Instant::now();
            if now >= deadline {
                panic!("write body hold did not enter");
            }
            let (guard, timed) = cvar
                .wait_timeout(entered, deadline.saturating_duration_since(now))
                .expect("entered wait");
            entered = guard;
            if timed.timed_out() && !*entered {
                panic!("write body hold did not enter");
            }
        }
    }

    pub fn wait_cancelled(&self) {
        let lease = self.wait_for_cancel_lease();
        lease.wait_signalled();
    }

    fn wait_for_cancel_lease(&self) -> CancelWaitLease {
        let (lock, cvar) = &*self.cancel_handles;
        let mut state = lock.lock().expect("cancel handles");
        let deadline = Instant::now() + Duration::from_secs(15);
        while state.lease.is_none() && !state.retired {
            let now = Instant::now();
            if now >= deadline {
                panic!("write body hold cancel handles were not published");
            }
            let (guard, timed) = cvar
                .wait_timeout(state, deadline.saturating_duration_since(now))
                .expect("cancel handle publication wait");
            state = guard;
            if timed.timed_out() && state.lease.is_none() && !state.retired {
                panic!("write body hold cancel handles were not published");
            }
        }
        if state.retired {
            panic!("write body hold cancel handles were retired before cancel wait");
        }
        let inner = state
            .lease
            .clone()
            .expect("write body hold cancel handles were not published");
        if inner.handles.is_empty() || inner.handles.len() > WAIT_HANDLE_CAP {
            panic!("write body hold cancel handle count exceeds wait cap");
        }
        if inner
            .handles
            .iter()
            .any(|handle| handle.raw().is_null() || handle.raw() == INVALID_HANDLE_VALUE)
        {
            panic!("write body hold recorded an invalid cancel handle");
        }
        CancelWaitLease { inner }
    }

    fn try_acquire_cancel_wait_lease(&self) -> Option<CancelWaitLease> {
        let (lock, _) = &*self.cancel_handles;
        let state = lock.lock().ok()?;
        if state.retired {
            return None;
        }
        Some(CancelWaitLease {
            inner: state.lease.clone()?,
        })
    }

    fn publish_cancel_handles(&self, cancellations: &[HANDLE]) -> Result<(), IoError> {
        if !self.live.load(Ordering::SeqCst) {
            return Err(IoError::Failed);
        }
        let duplicated = duplicate_cancel_handles(cancellations)?;
        let (lock, cvar) = &*self.cancel_handles;
        let mut state = lock.lock().expect("cancel handles");
        if state.retired || !self.live.load(Ordering::SeqCst) {
            return Err(IoError::Failed);
        }
        state.lease = Some(Arc::new(OwnedCancelLeaseInner {
            handles: duplicated,
        }));
        cvar.notify_all();
        Ok(())
    }

    pub fn release_body(&self) {
        self.retire_cancel_publication();
        let (lock, cvar) = &*self.release;
        *lock.lock().expect("release") = true;
        cvar.notify_all();
    }

    pub fn clear(&self) {
        self.live.store(false, Ordering::SeqCst);
        self.release_body();
        let mut holds = WRITE_BODY_HOLD.lock().expect("write body hold");
        holds.retain(|hold| !Arc::ptr_eq(&hold.entered, &self.entered));
    }

    fn retire_cancel_publication(&self) {
        let (lock, cvar) = &*self.cancel_handles;
        let mut state = match lock.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        };
        state.retired = true;
        state.lease = None;
        cvar.notify_all();
    }
}

#[cfg(debug_assertions)]
impl Drop for WriteBodyHold {
    fn drop(&mut self) {
        self.live.store(false, Ordering::SeqCst);
        self.retire_cancel_publication();
        let (lock, cvar) = &*self.release;
        match lock.lock() {
            Ok(mut released) => {
                *released = true;
                cvar.notify_all();
            }
            Err(poisoned) => {
                *poisoned.into_inner() = true;
                cvar.notify_all();
            }
        }
    }
}

#[cfg(debug_assertions)]
fn wait_installed_write_body(connection: &ConnectionId, cancellations: &[HANDLE]) {
    let key = connection_key(connection);
    let hold = WRITE_BODY_HOLD.lock().ok().and_then(|guard| {
        guard
            .iter()
            .find(|hold| {
                hold.live.load(Ordering::SeqCst) && hold.connection_key == key
            })
            .cloned()
    });
    let Some(hold) = hold else {
        return;
    };
    if cancellations.is_empty() || cancellations.len() > WAIT_HANDLE_CAP {
        panic!("write body hold requires a bounded actual cancellation signal");
    }
    for handle in cancellations {
        if handle.is_null() || *handle == INVALID_HANDLE_VALUE {
            panic!("write body hold received an invalid cancel handle");
        }
    }
    if hold.publish_cancel_handles(cancellations).is_err() {
        panic!("write body hold failed to publish owned cancellation leases");
    }
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

fn write_frame_with_checkpoint(
    handle: HANDLE,
    body: &[u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(),
) -> Result<(), IoError> {
    if body.is_empty() || body.len() > MAX_MESSAGE_BYTES {
        return Err(IoError::Protocol);
    }
    let header = (body.len() as u32).to_le_bytes();
    write_all(handle, &header, cancellations)?;
    checkpoint();
    write_all(handle, body, cancellations)
}

pub(crate) fn connect_overlapped(handle: HANDLE, cancellations: &[HANDLE]) -> Result<(), IoError> {
    connect_overlapped_with_checkpoint(handle, cancellations, |_| {})
}

pub(crate) fn connect_overlapped_with_wake(
    handle: HANDLE,
    cancellation: HANDLE,
    wake: HANDLE,
    mut on_wake: impl FnMut() -> Result<(), IoError>,
) -> Result<(), IoError> {
    let cancellations = [cancellation];
    check_cancellation(&cancellations)?;
    let event = completion_event()?;
    let mut overlapped = OVERLAPPED::default();
    overlapped.hEvent = event.raw();
    let connected = unsafe { ConnectNamedPipe(handle, &mut overlapped) };
    let last_error = if connected == 0 {
        Some(unsafe { GetLastError() })
    } else {
        None
    };
    if let Err(error) = check_cancellation(&cancellations) {
        if last_error == Some(ERROR_IO_PENDING) {
            cancel_and_drain(handle, &overlapped);
        }
        return Err(error);
    }
    if connected != 0 || last_error == Some(ERROR_PIPE_CONNECTED) {
        return Ok(());
    }
    if last_error != Some(ERROR_IO_PENDING) {
        return match last_error {
            Some(ERROR_OPERATION_ABORTED) => Err(IoError::Cancelled),
            _ => Err(IoError::Failed),
        };
    }

    let handles = [event.raw(), cancellation, wake];
    loop {
        let wait =
            unsafe { WaitForMultipleObjects(handles.len() as u32, handles.as_ptr(), 0, INFINITE) };
        if wait == WAIT_FAILED {
            cancel_and_drain(handle, &overlapped);
            return Err(IoError::Failed);
        }
        if wait == WAIT_OBJECT_0 {
            if let Err(error) = check_cancellation(&cancellations) {
                cancel_and_drain(handle, &overlapped);
                return Err(error);
            }
            let mut transferred = 0;
            let completed =
                unsafe { GetOverlappedResult(handle, &overlapped, &mut transferred, 0) };
            if completed != 0 {
                return Ok(());
            }
            return match unsafe { GetLastError() } {
                ERROR_BROKEN_PIPE | ERROR_NO_DATA => Err(IoError::Eof),
                ERROR_OPERATION_ABORTED => Err(IoError::Cancelled),
                _ => Err(IoError::Failed),
            };
        }
        if wait == WAIT_OBJECT_0 + 1 {
            cancel_and_drain(handle, &overlapped);
            return Err(IoError::Cancelled);
        }
        if wait == WAIT_OBJECT_0 + 2 {
            on_wake()?;
            continue;
        }
        cancel_and_drain(handle, &overlapped);
        return Err(IoError::Failed);
    }
}

fn connect_overlapped_with_checkpoint(
    handle: HANDLE,
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<(), IoError> {
    check_cancellation(cancellations)?;
    let event = completion_event()?;
    let mut overlapped = OVERLAPPED::default();
    overlapped.hEvent = event.raw();
    let connected = unsafe { ConnectNamedPipe(handle, &mut overlapped) };
    let last_error = if connected == 0 {
        Some(unsafe { GetLastError() })
    } else {
        None
    };
    checkpoint(
        if connected != 0 || last_error == Some(ERROR_PIPE_CONNECTED) {
            IoStart::Synchronous
        } else if last_error == Some(ERROR_IO_PENDING) {
            IoStart::Pending
        } else {
            IoStart::Failed
        },
    );
    if let Err(error) = check_cancellation(cancellations) {
        if last_error == Some(ERROR_IO_PENDING) {
            cancel_and_drain(handle, &overlapped);
        }
        return Err(error);
    }
    if connected != 0 {
        return Ok(());
    }
    match last_error.expect("failed ConnectNamedPipe captured its error") {
        ERROR_PIPE_CONNECTED => Ok(()),
        ERROR_IO_PENDING => {
            wait_pending(handle, &overlapped, event.raw(), cancellations).map(|_| ())
        }
        ERROR_OPERATION_ABORTED => Err(IoError::Cancelled),
        _ => Err(IoError::Failed),
    }
}

#[cfg(debug_assertions)]
pub(super) fn read_once_after_start(
    handle: HANDLE,
    buffer: &mut [u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<usize, IoError> {
    read_once_with_checkpoint(handle, buffer, cancellations, checkpoint)
}

#[cfg(debug_assertions)]
pub(super) fn read_exact_after_each_start(
    handle: HANDLE,
    buffer: &mut [u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnMut(IoStart),
) -> Result<(), IoError> {
    read_exact_with_checkpoint(handle, buffer, cancellations, checkpoint)
}

#[cfg(debug_assertions)]
pub(super) fn write_once_after_start(
    handle: HANDLE,
    buffer: &[u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<usize, IoError> {
    write_once_with_checkpoint(handle, buffer, cancellations, checkpoint)
}

#[cfg(debug_assertions)]
pub(super) fn write_frame_after_header(
    handle: HANDLE,
    body: &[u8],
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(),
) -> Result<(), IoError> {
    write_frame_with_checkpoint(handle, body, cancellations, checkpoint)
}

#[cfg(debug_assertions)]
pub(super) fn connect_after_start(
    handle: HANDLE,
    cancellations: &[HANDLE],
    checkpoint: impl FnOnce(IoStart),
) -> Result<(), IoError> {
    connect_overlapped_with_checkpoint(handle, cancellations, checkpoint)
}

#[cfg(test)]
mod tests {
    use super::{connect_overlapped_with_wake, CancelEvent, IoError, OwnedHandle};
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_OVERLAPPED, OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
        SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
    };
    use windows_sys::Win32::System::Pipes::{
        CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    };
    use windows_sys::Win32::System::Threading::{CreateEventW, ResetEvent};
    #[cfg(debug_assertions)]
    use super::{duplicate_cancel_handles, duplicate_handle, WriteBodyHold};
    #[cfg(debug_assertions)]
    use std::sync::{Arc, Condvar, Mutex};
    #[cfg(debug_assertions)]
    use std::thread;
    #[cfg(debug_assertions)]
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    #[cfg(debug_assertions)]
    use windows_sys::Win32::System::Threading::SetEvent;

    fn wide(value: &str) -> Vec<u16> {
        OsStr::new(value)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    #[test]
    fn connect_wake_is_serviced_before_pending_connection_completes() {
        let name = format!(
            r"\\.\pipe\winsmux-workspace-connect-wake-{}",
            uuid::Uuid::new_v4()
        );
        let wide_name = wide(&name);
        let server = unsafe {
            OwnedHandle::from_raw(CreateNamedPipeW(
                wide_name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                0,
                null(),
            ))
        }
        .expect("create named pipe");
        let cancel = CancelEvent::new().expect("create cancellation event");
        let wake = unsafe { OwnedHandle::from_raw(CreateEventW(null(), 1, 1, null())) }
            .expect("create initially-signalled wake event");
        let mut wake_calls = 0;
        let mut client = None;

        let connected =
            connect_overlapped_with_wake(server.raw(), cancel.raw(), wake.raw(), || {
                wake_calls += 1;
                if unsafe { ResetEvent(wake.raw()) } == 0 {
                    return Err(IoError::Failed);
                }
                let handle = unsafe {
                    CreateFileW(
                        wide_name.as_ptr(),
                        GENERIC_READ | GENERIC_WRITE,
                        0,
                        null_mut(),
                        OPEN_EXISTING,
                        SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                        null_mut(),
                    )
                };
                client = Some(unsafe { OwnedHandle::from_raw(handle)? });
                Ok(())
            });

        assert_eq!(connected, Ok(()));
        assert_eq!(wake_calls, 1);
        assert!(client.is_some());
    }

    #[cfg(debug_assertions)]
    fn test_connection_id() -> crate::contract::ConnectionId {
        crate::contract::ConnectionId::new(uuid::Uuid::new_v4().to_string()).expect("connection id")
    }

    #[cfg(debug_assertions)]
    #[test]
    fn owned_cancel_lease_survives_source_close_release_clear_and_drop() {
        let source = CancelEvent::new().expect("source");
        let signaler = duplicate_handle(source.raw()).expect("signaler");
        let hold = WriteBodyHold::install_for(&test_connection_id());
        hold.publish_cancel_handles(&[source.raw()])
            .expect("publish owned cancel leases");
        let lease = hold
            .try_acquire_cancel_wait_lease()
            .expect("lease before retire");
        let acquired = Arc::new((Mutex::new(false), Condvar::new()));
        let proceed = Arc::new((Mutex::new(false), Condvar::new()));
        let waiter_acquired = acquired.clone();
        let waiter_proceed = proceed.clone();
        let waiter = thread::spawn(move || {
            {
                let (lock, cvar) = &*waiter_acquired;
                *lock.lock().expect("acquired") = true;
                cvar.notify_all();
            }
            {
                let (lock, cvar) = &*waiter_proceed;
                let mut go = lock.lock().expect("proceed");
                while !*go {
                    go = cvar.wait(go).expect("proceed wait");
                }
            }
            lease.wait_signalled();
        });
        {
            let (lock, cvar) = &*acquired;
            let mut done = lock.lock().expect("acquired");
            while !*done {
                done = cvar.wait(done).expect("acquired wait");
            }
        }
        drop(source);
        hold.release_body();
        assert!(
            hold.try_acquire_cancel_wait_lease().is_none(),
            "release must refuse a new cancel observation"
        );
        hold.clear();
        drop(hold);
        assert_ne!(
            unsafe { SetEvent(signaler.raw()) },
            0,
            "duplicate signaler must remain valid"
        );
        {
            let (lock, cvar) = &*proceed;
            *lock.lock().expect("proceed") = true;
            cvar.notify_all();
        }
        waiter.join().expect("owned cancel waiter");
        drop(signaler);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn retired_hold_refuses_new_cancel_observation() {
        let source = CancelEvent::new().expect("source");
        let hold = WriteBodyHold::install_for(&test_connection_id());
        hold.publish_cancel_handles(&[source.raw()])
            .expect("publish");
        let lease = hold
            .try_acquire_cancel_wait_lease()
            .expect("existing waiter");
        hold.release_body();
        assert!(hold.try_acquire_cancel_wait_lease().is_none());
        drop(lease);
        drop(hold);
        drop(source);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn cleared_hold_does_not_resurrect_publication() {
        let source = CancelEvent::new().expect("source");
        let hold = WriteBodyHold::install_for(&test_connection_id());
        hold.clear();
        assert_eq!(
            hold.publish_cancel_handles(&[source.raw()]),
            Err(IoError::Failed)
        );
        assert!(hold.try_acquire_cancel_wait_lease().is_none());
        drop(source);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn invalid_and_partial_duplicate_fail_without_cancellation() {
        assert_eq!(duplicate_cancel_handles(&[]).map(|_| ()), Err(IoError::Failed));
        assert_eq!(duplicate_cancel_handles(&[null_mut()]).map(|_| ()), Err(IoError::Failed));
        assert_eq!(
            duplicate_cancel_handles(&[INVALID_HANDLE_VALUE]).map(|_| ()),
            Err(IoError::Failed)
        );
        let valid = CancelEvent::new().expect("valid");
        assert_eq!(
            duplicate_cancel_handles(&[valid.raw(), INVALID_HANDLE_VALUE]).map(|_| ()),
            Err(IoError::Failed)
        );
        valid.signal();
        drop(valid);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn hold_drop_with_outstanding_lease_does_not_panic() {
        let source = CancelEvent::new().expect("source");
        let hold = WriteBodyHold::install_for(&test_connection_id());
        hold.publish_cancel_handles(&[source.raw()])
            .expect("publish");
        let lease = hold
            .try_acquire_cancel_wait_lease()
            .expect("lease");
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(hold)))
            .expect("hold drop must not panic with an outstanding owned waiter");
        drop(lease);
        drop(source);
    }
}
