use crate::desktop_backend::{
    apply_desktop_winsmux_child_env, hide_subprocess_window, resolve_companion_winsmux_cli,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use winsmux_remote_helper::{
    decode_payload, read_frame, write_frame, AgentResolution, Message, RejectCode, MAX_FRAME_LEN,
    MAX_PTY_COLS, MAX_PTY_ROWS, PROTOCOL_VERSION, SUPPORTED_CAPABILITIES,
};

type SessionResult<T> = Result<T, &'static str>;

static NONCE_COUNTER: AtomicU64 = AtomicU64::new(1);

#[cfg(test)]
type TestHook = Arc<dyn Fn() + Send + Sync>;

#[cfg(test)]
#[derive(Default)]
struct RemoteSessionTestHooks {
    before_start_ack: Mutex<Option<TestHook>>,
    after_start_ack: Mutex<Option<TestHook>>,
    before_shutdown_stop: Mutex<Option<TestHook>>,
}

#[cfg(test)]
impl RemoteSessionTestHooks {
    fn set_before_start_ack(&self, hook: TestHook) {
        *self.before_start_ack.lock().expect("test hook lock") = Some(hook);
    }

    fn set_after_start_ack(&self, hook: TestHook) {
        *self.after_start_ack.lock().expect("test hook lock") = Some(hook);
    }

    fn set_before_shutdown_stop(&self, hook: TestHook) {
        *self.before_shutdown_stop.lock().expect("test hook lock") = Some(hook);
    }

    fn run(hook: &Mutex<Option<TestHook>>) {
        let hook = hook.lock().expect("test hook lock").clone();
        if let Some(hook) = hook {
            hook();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ControllerState {
    Attached,
    Detached,
    Unreachable,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteSessionSnapshot {
    pub(crate) session_id: String,
    pub(crate) host_alias: String,
    pub(crate) controller_state: ControllerState,
    pub(crate) last_hello_welcome_rtt_ms: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum RemoteAgent {
    Claude,
    Codex,
}

impl RemoteAgent {
    fn executable(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

trait CompanionChild: Send {
    fn try_wait(&mut self) -> io::Result<bool>;
    fn kill(&mut self) -> io::Result<()>;
    fn wait(&mut self) -> io::Result<()>;
}

struct NativeCompanionChild(Child);

impl CompanionChild for NativeCompanionChild {
    fn try_wait(&mut self) -> io::Result<bool> {
        self.0.try_wait().map(|status| status.is_some())
    }

    fn kill(&mut self) -> io::Result<()> {
        self.0.kill()
    }

    fn wait(&mut self) -> io::Result<()> {
        self.0.wait().map(|_| ())
    }
}

struct SpawnedCompanion {
    writer: Box<dyn Write + Send>,
    reader: Box<dyn Read + Send>,
    child: Box<dyn CompanionChild>,
}

trait CompanionSpawner: Send + Sync {
    fn spawn(&self, args: &[String]) -> SessionResult<SpawnedCompanion>;
}

struct NativeCompanionSpawner;

impl CompanionSpawner for NativeCompanionSpawner {
    fn spawn(&self, args: &[String]) -> SessionResult<SpawnedCompanion> {
        let companion =
            resolve_companion_winsmux_cli().ok_or("remote_session_companion_unavailable")?;
        let mut command = Command::new(&companion);
        command
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        apply_desktop_winsmux_child_env(&mut command, Some(&companion), std::process::id());
        hide_subprocess_window(&mut command);
        let mut child = command
            .spawn()
            .map_err(|_| "remote_session_companion_spawn_failed")?;
        let Some(writer) = child.stdin.take() else {
            reap_native_child(&mut child);
            return Err("remote_session_companion_stdin_missing");
        };
        let Some(reader) = child.stdout.take() else {
            drop(writer);
            reap_native_child(&mut child);
            return Err("remote_session_companion_stdout_missing");
        };
        Ok(SpawnedCompanion {
            writer: Box::new(writer),
            reader: Box::new(reader),
            child: Box::new(NativeCompanionChild(child)),
        })
    }
}

fn reap_native_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct SessionKey {
    host_alias: String,
    session_id: String,
}

impl SessionKey {
    fn new(host_alias: String, session_id: String) -> Self {
        Self {
            host_alias,
            session_id,
        }
    }
}

#[derive(Debug)]
enum SessionRecord {
    Pending {
        transport_id: u64,
        last_hello_welcome_rtt_ms: u64,
        tombstoned: bool,
    },
    Published {
        controller_state: ControllerState,
        last_hello_welcome_rtt_ms: u64,
        transport_id: Option<u64>,
        transition_id: Option<u64>,
    },
}

#[derive(Default)]
struct ManagerState {
    records: BTreeMap<SessionKey, SessionRecord>,
    shutting_down: bool,
}

impl ManagerState {
    fn insert_pending(
        &mut self,
        key: SessionKey,
        transport_id: u64,
        last_hello_welcome_rtt_ms: u64,
    ) -> bool {
        if self.shutting_down || self.records.contains_key(&key) {
            return false;
        }
        self.records.insert(
            key,
            SessionRecord::Pending {
                transport_id,
                last_hello_welcome_rtt_ms,
                tombstoned: false,
            },
        );
        true
    }

    fn tombstone_pending(&mut self, key: &SessionKey, transport_id: u64) -> bool {
        let Some(SessionRecord::Pending {
            transport_id: current_id,
            tombstoned,
            ..
        }) = self.records.get_mut(key)
        else {
            return false;
        };
        if *current_id != transport_id {
            return false;
        }
        *tombstoned = true;
        true
    }

    fn publish_pending(&mut self, key: &SessionKey, transport_id: u64) -> bool {
        let Some(SessionRecord::Pending {
            transport_id: current_id,
            last_hello_welcome_rtt_ms,
            tombstoned: false,
        }) = self.records.get(key)
        else {
            return false;
        };
        if *current_id != transport_id {
            return false;
        }
        let last_hello_welcome_rtt_ms = *last_hello_welcome_rtt_ms;
        self.records.insert(
            key.clone(),
            SessionRecord::Published {
                controller_state: ControllerState::Attached,
                last_hello_welcome_rtt_ms,
                transport_id: Some(transport_id),
                transition_id: None,
            },
        );
        true
    }

    fn snapshots(&self) -> Vec<RemoteSessionSnapshot> {
        self.records
            .iter()
            .filter_map(|(key, record)| {
                let SessionRecord::Published {
                    controller_state,
                    last_hello_welcome_rtt_ms,
                    ..
                } = record
                else {
                    return None;
                };
                Some(RemoteSessionSnapshot {
                    session_id: key.session_id.clone(),
                    host_alias: key.host_alias.clone(),
                    controller_state: *controller_state,
                    last_hello_welcome_rtt_ms: *last_hello_welcome_rtt_ms,
                })
            })
            .collect()
    }

    fn snapshot(&self, key: &SessionKey) -> Option<RemoteSessionSnapshot> {
        let SessionRecord::Published {
            controller_state,
            last_hello_welcome_rtt_ms,
            ..
        } = self.records.get(key)?
        else {
            return None;
        };
        Some(RemoteSessionSnapshot {
            session_id: key.session_id.clone(),
            host_alias: key.host_alias.clone(),
            controller_state: *controller_state,
            last_hello_welcome_rtt_ms: *last_hello_welcome_rtt_ms,
        })
    }

    fn discard_pending(&mut self, key: &SessionKey, transport_id: u64) {
        if matches!(
            self.records.get(key),
            Some(SessionRecord::Pending {
                transport_id: current_id,
                ..
            }) if *current_id == transport_id
        ) {
            self.records.remove(key);
        }
    }

    fn mark_unreachable(&mut self, key: &SessionKey, transport_id: u64) {
        let Some(SessionRecord::Published {
            controller_state,
            transport_id: current_id,
            transition_id,
            ..
        }) = self.records.get_mut(key)
        else {
            return;
        };
        if *current_id == Some(transport_id) || *transition_id == Some(transport_id) {
            *controller_state = ControllerState::Unreachable;
            *current_id = None;
            *transition_id = None;
        }
    }

    fn remove_published(&mut self, key: &SessionKey, transport_id: u64) {
        if matches!(
            self.records.get(key),
            Some(SessionRecord::Published {
                transport_id: current_id,
                transition_id,
                ..
            }) if *current_id == Some(transport_id) || *transition_id == Some(transport_id)
        ) {
            self.records.remove(key);
        }
    }

    fn attached_transport_id(&self, key: &SessionKey) -> Option<u64> {
        let Some(SessionRecord::Published {
            controller_state: ControllerState::Attached,
            transport_id: Some(transport_id),
            transition_id: None,
            ..
        }) = self.records.get(key)
        else {
            return None;
        };
        Some(*transport_id)
    }

    fn can_reattach(&self, key: &SessionKey) -> bool {
        matches!(
            self.records.get(key),
            Some(SessionRecord::Published {
                controller_state: ControllerState::Detached | ControllerState::Unreachable,
                transport_id: None,
                transition_id: None,
                ..
            })
        )
    }

    fn reserve_reattach(&mut self, key: &SessionKey, transport_id: u64) -> bool {
        let Some(SessionRecord::Published {
            controller_state: ControllerState::Detached | ControllerState::Unreachable,
            transport_id: current_id,
            transition_id,
            ..
        }) = self.records.get_mut(key)
        else {
            return false;
        };
        if self.shutting_down || current_id.is_some() || transition_id.is_some() {
            return false;
        }
        *transition_id = Some(transport_id);
        true
    }

    fn record_reattach_handshake(
        &mut self,
        key: &SessionKey,
        transport_id: u64,
        last_hello_welcome_rtt_ms: u64,
    ) -> bool {
        let Some(SessionRecord::Published {
            last_hello_welcome_rtt_ms: current_rtt,
            transition_id: Some(current_id),
            ..
        }) = self.records.get_mut(key)
        else {
            return false;
        };
        if *current_id != transport_id {
            return false;
        }
        *current_rtt = last_hello_welcome_rtt_ms;
        true
    }

    fn complete_reattach(&mut self, key: &SessionKey, transport_id: u64) -> bool {
        let Some(SessionRecord::Published {
            controller_state,
            transport_id: current_id,
            transition_id,
            ..
        }) = self.records.get_mut(key)
        else {
            return false;
        };
        if *transition_id != Some(transport_id) || current_id.is_some() {
            return false;
        }
        *controller_state = ControllerState::Attached;
        *current_id = Some(transport_id);
        *transition_id = None;
        true
    }

    fn fail_reattach(&mut self, key: &SessionKey, transport_id: u64) {
        let Some(SessionRecord::Published {
            controller_state,
            transport_id: current_id,
            transition_id,
            ..
        }) = self.records.get_mut(key)
        else {
            return;
        };
        if *transition_id == Some(transport_id) {
            *controller_state = ControllerState::Unreachable;
            *current_id = None;
            *transition_id = None;
        }
    }

    fn mark_detached(&mut self, key: &SessionKey, transport_id: u64) -> bool {
        let Some(SessionRecord::Published {
            controller_state,
            transport_id: current_id,
            transition_id,
            ..
        }) = self.records.get_mut(key)
        else {
            return false;
        };
        if *controller_state != ControllerState::Attached
            || *current_id != Some(transport_id)
            || transition_id.is_some()
        {
            return false;
        }
        *controller_state = ControllerState::Detached;
        *current_id = None;
        true
    }

    fn begin_shutdown(&mut self) -> Vec<(SessionKey, SessionRecord)> {
        if self.shutting_down {
            return Vec::new();
        }
        self.shutting_down = true;
        std::mem::take(&mut self.records).into_iter().collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ReaderBinding {
    AwaitingStart { host_alias: String },
    Pending(SessionKey),
    ConfirmedPending(SessionKey),
    AwaitingAttach(SessionKey),
    Attaching(SessionKey),
    Attached(SessionKey),
    Detaching(SessionKey),
    Stopping(SessionKey),
    Closed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ReaderEvent {
    Started(SessionKey),
    Attached,
    Detached,
    Stopped,
    Removed,
    Lost,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PublishPendingOutcome {
    Published,
    ShuttingDown,
    Rejected,
}

enum ShutdownTransportAction {
    Close,
    Stop { key: SessionKey, attach_first: bool },
    StopDetached(SessionKey),
}

struct Transport {
    id: u64,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    child: Mutex<Option<Box<dyn CompanionChild>>>,
    binding: Mutex<ReaderBinding>,
    event_sender: Mutex<Option<Sender<ReaderEvent>>>,
    reap_state: Mutex<ReapState>,
    reap_complete: Condvar,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReapState {
    Live,
    Reaping,
    Reaped,
}

impl Transport {
    fn new(
        id: u64,
        writer: Box<dyn Write + Send>,
        child: Box<dyn CompanionChild>,
        binding: ReaderBinding,
    ) -> Self {
        Self {
            id,
            writer: Mutex::new(Some(writer)),
            child: Mutex::new(Some(child)),
            binding: Mutex::new(binding),
            event_sender: Mutex::new(None),
            reap_state: Mutex::new(ReapState::Live),
            reap_complete: Condvar::new(),
        }
    }

    fn write_message(&self, message: &Message) -> SessionResult<()> {
        if self
            .reap_state
            .lock()
            .map_err(|_| "remote_session_transport_closed")?
            .ne(&ReapState::Live)
        {
            return Err("remote_session_transport_closed");
        }
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| "remote_session_transport_write_failed")?;
        let writer = writer.as_mut().ok_or("remote_session_transport_closed")?;
        write_frame(writer, message).map_err(|_| "remote_session_transport_write_failed")
    }

    fn set_event_sender(&self, sender: Sender<ReaderEvent>) -> SessionResult<()> {
        *self
            .event_sender
            .lock()
            .map_err(|_| "remote_session_state_unavailable")? = Some(sender);
        Ok(())
    }

    fn emit(&self, event: ReaderEvent) {
        if let Ok(sender) = self.event_sender.lock() {
            if let Some(sender) = sender.as_ref() {
                let _ = sender.send(event);
            }
        }
    }

    fn reap(&self) {
        let mut reap_state = match self.reap_state.lock() {
            Ok(reap_state) => reap_state,
            Err(poisoned) => poisoned.into_inner(),
        };
        loop {
            match *reap_state {
                ReapState::Reaped => return,
                ReapState::Reaping => {
                    reap_state = match self.reap_complete.wait(reap_state) {
                        Ok(reap_state) => reap_state,
                        Err(poisoned) => poisoned.into_inner(),
                    };
                }
                ReapState::Live => {
                    *reap_state = ReapState::Reaping;
                    break;
                }
            }
        }
        drop(reap_state);
        if let Ok(mut writer) = self.writer.lock() {
            writer.take();
        }
        if let Ok(mut child_slot) = self.child.lock() {
            if let Some(mut child) = child_slot.take() {
                match child.try_wait() {
                    Ok(true) => {}
                    Ok(false) | Err(_) => {
                        let _ = child.kill();
                    }
                }
                let _ = child.wait();
            }
        }
        let mut reap_state = match self.reap_state.lock() {
            Ok(reap_state) => reap_state,
            Err(poisoned) => poisoned.into_inner(),
        };
        *reap_state = ReapState::Reaped;
        self.reap_complete.notify_all();
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        self.reap();
    }
}

struct ManagerInner {
    state: Mutex<ManagerState>,
    transports: Mutex<BTreeMap<u64, Arc<Transport>>>,
    next_transport_id: AtomicU64,
    #[cfg(test)]
    test_hooks: RemoteSessionTestHooks,
}

impl ManagerInner {
    fn new() -> Self {
        Self {
            state: Mutex::new(ManagerState::default()),
            transports: Mutex::new(BTreeMap::new()),
            next_transport_id: AtomicU64::new(1),
            #[cfg(test)]
            test_hooks: RemoteSessionTestHooks::default(),
        }
    }

    fn next_transport_id(&self) -> u64 {
        self.next_transport_id.fetch_add(1, Ordering::SeqCst)
    }

    fn register_transport(
        &self,
        transport: Arc<Transport>,
        allow_during_shutdown: bool,
    ) -> SessionResult<()> {
        let state = self
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?;
        if state.shutting_down && !allow_during_shutdown {
            return Err("remote_session_shutting_down");
        }
        self.transports
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .insert(transport.id, transport);
        drop(state);
        Ok(())
    }

    fn transport(&self, transport_id: u64) -> Option<Arc<Transport>> {
        self.transports.lock().ok()?.get(&transport_id).cloned()
    }

    fn is_shutting_down(&self) -> bool {
        self.state
            .lock()
            .map(|state| state.shutting_down)
            .unwrap_or(true)
    }

    fn finish_transport(&self, transport_id: u64) {
        let transport = self
            .transports
            .lock()
            .ok()
            .and_then(|mut transports| transports.remove(&transport_id));
        if let Some(transport) = transport {
            transport.reap();
        }
    }

    fn confirm_pending(&self, transport: &Arc<Transport>, key: &SessionKey) -> SessionResult<()> {
        let mut binding = transport
            .binding
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?;
        if *binding != ReaderBinding::Pending(key.clone()) {
            return Err("remote_session_start_ack_failed");
        }
        transport.write_message(&Message::PtyStartAck {
            session_id: key.session_id.clone(),
        })?;
        *binding = ReaderBinding::ConfirmedPending(key.clone());
        Ok(())
    }

    fn publish_pending(
        &self,
        transport: &Arc<Transport>,
        key: &SessionKey,
    ) -> SessionResult<PublishPendingOutcome> {
        let mut binding = transport
            .binding
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?;
        if *binding != ReaderBinding::ConfirmedPending(key.clone()) {
            return Ok(PublishPendingOutcome::Rejected);
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?;
        if state.shutting_down {
            return Ok(PublishPendingOutcome::ShuttingDown);
        }
        if !state.publish_pending(key, transport.id) {
            return Ok(PublishPendingOutcome::Rejected);
        }
        *binding = ReaderBinding::Attached(key.clone());
        Ok(PublishPendingOutcome::Published)
    }

    fn discard_pending(&self, transport: &Arc<Transport>, key: &SessionKey) {
        if let Ok(mut binding) = transport.binding.lock() {
            if matches!(
                &*binding,
                ReaderBinding::Pending(current_key)
                    | ReaderBinding::ConfirmedPending(current_key)
                    if current_key == key
            ) {
                *binding = ReaderBinding::Closed;
            }
        }
        if let Ok(mut state) = self.state.lock() {
            state.discard_pending(key, transport.id);
        }
        self.finish_transport(transport.id);
        transport.reap();
    }
}

#[derive(Clone)]
struct RemoteSessionHandle {
    inner: Arc<ManagerInner>,
    spawner: Arc<dyn CompanionSpawner>,
}

pub(crate) struct RemoteSessionManager {
    handle: RemoteSessionHandle,
}

impl RemoteSessionManager {
    pub(crate) fn new() -> Self {
        Self::with_spawner(Arc::new(NativeCompanionSpawner))
    }

    fn with_spawner(spawner: Arc<dyn CompanionSpawner>) -> Self {
        Self {
            handle: RemoteSessionHandle {
                inner: Arc::new(ManagerInner::new()),
                spawner,
            },
        }
    }

    #[cfg(test)]
    fn start(
        &self,
        host_alias: String,
        agent: RemoteAgent,
        cols: u16,
        rows: u16,
    ) -> SessionResult<RemoteSessionSnapshot> {
        self.handle.start(host_alias, agent, cols, rows)
    }

    fn snapshots(&self) -> Vec<RemoteSessionSnapshot> {
        self.handle.snapshots()
    }

    #[cfg(test)]
    fn detach(&self, host_alias: &str, session_id: &str) -> SessionResult<RemoteSessionSnapshot> {
        self.handle.detach(host_alias, session_id)
    }

    #[cfg(test)]
    fn reattach(&self, host_alias: &str, session_id: &str) -> SessionResult<RemoteSessionSnapshot> {
        self.handle.reattach(host_alias, session_id)
    }

    pub(crate) fn shutdown(&self, timeout: Duration) {
        self.handle.shutdown(timeout);
    }
}

impl Drop for RemoteSessionManager {
    fn drop(&mut self) {
        self.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));
    }
}

impl RemoteSessionHandle {
    fn start(
        &self,
        host_alias: String,
        agent: RemoteAgent,
        cols: u16,
        rows: u16,
    ) -> SessionResult<RemoteSessionSnapshot> {
        validate_alias(&host_alias)?;
        validate_dimensions(cols, rows)?;
        if self
            .inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .shutting_down
        {
            return Err("remote_session_shutting_down");
        }

        let transport_id = self.inner.next_transport_id();
        let (transport, reader, rtt_ms) = self.connect(
            &host_alias,
            transport_id,
            ReaderBinding::AwaitingStart {
                host_alias: host_alias.clone(),
            },
            None,
        )?;
        let (event_sender, event_receiver) = mpsc::channel();
        transport.set_event_sender(event_sender)?;
        start_reader(
            Arc::downgrade(&self.inner),
            transport.clone(),
            reader,
            rtt_ms,
        );

        let start = Message::PtyStart {
            executable: agent.executable().to_string(),
            resolution: Some(AgentResolution {
                absolute_path: None,
                user_candidates: Vec::new(),
            }),
            argv: Vec::new(),
            cols,
            rows,
        };
        if let Err(error) = transport.write_message(&start) {
            self.inner.finish_transport(transport.id);
            return Err(error);
        }

        let key = match event_receiver.recv() {
            Ok(ReaderEvent::Started(key)) => key,
            _ => {
                self.inner.finish_transport(transport.id);
                return Err("remote_session_start_failed");
            }
        };
        #[cfg(test)]
        RemoteSessionTestHooks::run(&self.inner.test_hooks.before_start_ack);
        if self.inner.confirm_pending(&transport, &key).is_err() {
            self.inner.discard_pending(&transport, &key);
            return Err("remote_session_start_ack_failed");
        }
        #[cfg(test)]
        RemoteSessionTestHooks::run(&self.inner.test_hooks.after_start_ack);
        match self.inner.publish_pending(&transport, &key)? {
            PublishPendingOutcome::Published => {}
            PublishPendingOutcome::ShuttingDown => {
                return Err("remote_session_start_not_published");
            }
            PublishPendingOutcome::Rejected => {
                self.inner.discard_pending(&transport, &key);
                return Err("remote_session_start_not_published");
            }
        }
        self.inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .snapshot(&key)
            .ok_or("remote_session_start_not_published")
    }

    fn connect(
        &self,
        host_alias: &str,
        transport_id: u64,
        initial_binding: ReaderBinding,
        cancelled: Option<&AtomicBool>,
    ) -> SessionResult<(Arc<Transport>, Box<dyn Read + Send>, u64)> {
        let args = companion_args(host_alias);
        let spawned = self.spawner.spawn(&args)?;
        let transport = Arc::new(Transport::new(
            transport_id,
            spawned.writer,
            spawned.child,
            initial_binding,
        ));
        self.inner
            .register_transport(transport.clone(), cancelled.is_some())?;
        if cancelled.is_some_and(|cancelled| cancelled.load(Ordering::SeqCst)) {
            self.inner.finish_transport(transport.id);
            transport.reap();
            return Err("remote_session_shutdown_cancelled");
        }
        let mut reader = spawned.reader;
        let nonce = handshake_nonce();
        let hello = Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_version: env!("CARGO_PKG_VERSION").to_string(),
            nonce: nonce.clone(),
            capabilities: required_capabilities(),
            peer_frame_limit: MAX_FRAME_LEN,
        };
        let handshake_started = Instant::now();
        if transport.write_message(&hello).is_err() {
            self.inner.finish_transport(transport.id);
            return Err("remote_session_handshake_write_failed");
        }
        let welcome = match read_typed_message(&mut reader) {
            Ok(message) => message,
            Err(error) => {
                self.inner.finish_transport(transport.id);
                return Err(error);
            }
        };
        if !welcome_is_valid(&welcome, &nonce) {
            self.inner.finish_transport(transport.id);
            return Err("remote_session_handshake_rejected");
        }
        let rtt_ms = handshake_started
            .elapsed()
            .as_millis()
            .min(u64::MAX as u128) as u64;
        Ok((transport, reader, rtt_ms))
    }

    fn snapshots(&self) -> Vec<RemoteSessionSnapshot> {
        self.inner
            .state
            .lock()
            .map(|state| state.snapshots())
            .unwrap_or_default()
    }

    fn detach(&self, host_alias: &str, session_id: &str) -> SessionResult<RemoteSessionSnapshot> {
        validate_alias(host_alias)?;
        validate_session_id(session_id)?;
        let key = SessionKey::new(host_alias.to_string(), session_id.to_string());
        let transport_id = self
            .inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .attached_transport_id(&key)
            .ok_or("remote_session_not_attached")?;
        let transport = self
            .inner
            .transport(transport_id)
            .ok_or("remote_session_transport_unavailable")?;
        let (sender, receiver) = mpsc::channel();
        transport.set_event_sender(sender)?;
        {
            let mut binding = transport
                .binding
                .lock()
                .map_err(|_| "remote_session_state_unavailable")?;
            if *binding != ReaderBinding::Attached(key.clone()) {
                return Err("remote_session_not_attached");
            }
            if self
                .inner
                .state
                .lock()
                .map_err(|_| "remote_session_state_unavailable")?
                .shutting_down
            {
                return Err("remote_session_shutting_down");
            }
            if transport.write_message(&Message::PtyDetach).is_ok() {
                *binding = ReaderBinding::Detaching(key.clone());
            } else {
                drop(binding);
                if !self.inner.is_shutting_down() {
                    handle_transport_loss(&Arc::downgrade(&self.inner), &transport);
                    self.inner.finish_transport(transport_id);
                    transport.reap();
                }
                return Err("remote_session_detach_failed");
            }
        }
        let detached = matches!(receiver.recv(), Ok(ReaderEvent::Detached));
        if !self.inner.is_shutting_down() {
            self.inner.finish_transport(transport_id);
            transport.reap();
        }
        if !detached {
            return Err("remote_session_detach_failed");
        }
        self.inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .snapshot(&key)
            .ok_or("remote_session_detach_failed")
    }

    fn reattach(&self, host_alias: &str, session_id: &str) -> SessionResult<RemoteSessionSnapshot> {
        validate_alias(host_alias)?;
        validate_session_id(session_id)?;
        let key = SessionKey::new(host_alias.to_string(), session_id.to_string());
        if !self
            .inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .can_reattach(&key)
        {
            return Err("remote_session_unknown");
        }
        let transport_id = self.inner.next_transport_id();
        if !self
            .inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .reserve_reattach(&key, transport_id)
        {
            return Err("remote_session_not_reattachable");
        }
        let (transport, reader, rtt_ms) = match self.connect(
            host_alias,
            transport_id,
            ReaderBinding::AwaitingAttach(key.clone()),
            None,
        ) {
            Ok(connected) => connected,
            Err(error) => {
                if let Ok(mut state) = self.inner.state.lock() {
                    state.fail_reattach(&key, transport_id);
                }
                return Err(error);
            }
        };
        let handshake_recorded = self
            .inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .record_reattach_handshake(&key, transport_id, rtt_ms);
        if !handshake_recorded {
            if !self.inner.is_shutting_down() {
                self.inner.finish_transport(transport_id);
            }
            return Err("remote_session_reattach_failed");
        }
        let (sender, receiver) = mpsc::channel();
        transport.set_event_sender(sender)?;
        start_reader(
            Arc::downgrade(&self.inner),
            transport.clone(),
            reader,
            rtt_ms,
        );
        let attach_written = {
            let mut binding = transport
                .binding
                .lock()
                .map_err(|_| "remote_session_state_unavailable")?;
            if *binding != ReaderBinding::AwaitingAttach(key.clone())
                || self
                    .inner
                    .state
                    .lock()
                    .map_err(|_| "remote_session_state_unavailable")?
                    .shutting_down
            {
                false
            } else if transport
                .write_message(&Message::PtyAttach {
                    session_id: session_id.to_string(),
                })
                .is_ok()
            {
                *binding = ReaderBinding::Attaching(key.clone());
                true
            } else {
                false
            }
        };
        if !attach_written {
            if !self.inner.is_shutting_down() {
                handle_transport_loss(&Arc::downgrade(&self.inner), &transport);
                self.inner.finish_transport(transport_id);
                transport.reap();
            }
            return Err("remote_session_reattach_failed");
        }
        if !matches!(receiver.recv(), Ok(ReaderEvent::Attached)) {
            if !self.inner.is_shutting_down() {
                self.inner.finish_transport(transport_id);
                transport.reap();
            }
            return Err("remote_session_reattach_failed");
        }
        self.inner
            .state
            .lock()
            .map_err(|_| "remote_session_state_unavailable")?
            .snapshot(&key)
            .ok_or("remote_session_reattach_failed")
    }

    fn shutdown(&self, timeout: Duration) {
        let (records, transports) = {
            let mut state = match self.inner.state.lock() {
                Ok(state) => state,
                Err(poisoned) => poisoned.into_inner(),
            };
            let records = state.begin_shutdown();
            let transports = match self.inner.transports.lock() {
                Ok(transports) => transports.values().cloned().collect::<Vec<_>>(),
                Err(poisoned) => poisoned.into_inner().values().cloned().collect(),
            };
            drop(state);
            (records, transports)
        };
        let active_transport_ids = transports
            .iter()
            .map(|transport| transport.id)
            .collect::<BTreeSet<_>>();
        let mut fallback_by_transport = BTreeMap::new();
        let mut detached_to_stop = BTreeSet::new();
        for (key, record) in &records {
            let SessionRecord::Published {
                controller_state,
                transport_id,
                transition_id,
                ..
            } = record
            else {
                continue;
            };
            for transport_id in [*transport_id, *transition_id].into_iter().flatten() {
                fallback_by_transport.insert(transport_id, key.clone());
                if !active_transport_ids.contains(&transport_id) {
                    detached_to_stop.insert(key.clone());
                }
            }
            if *controller_state == ControllerState::Detached
                && transport_id.is_none()
                && transition_id.is_none()
            {
                detached_to_stop.insert(key.clone());
            }
        }
        for transport in transports {
            let fallback_key = fallback_by_transport.get(&transport.id).cloned();
            if let Some(key) = self.quiesce_transport(&transport, fallback_key, timeout) {
                detached_to_stop.insert(key);
            }
        }
        for key in detached_to_stop {
            self.stop_detached_bounded(key, timeout);
        }
    }

    fn stop_detached_bounded(&self, key: SessionKey, timeout: Duration) {
        let transport_id = self.inner.next_transport_id();
        let handle = self.clone();
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = cancelled.clone();
        let (finished_sender, finished_receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            handle.stop_detached_now(&key, transport_id, &worker_cancelled);
            let _ = finished_sender.send(());
        });
        match finished_receiver.recv_timeout(timeout) {
            Ok(()) => {
                let _ = worker.join();
            }
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
                cancelled.store(true, Ordering::SeqCst);
                self.inner.finish_transport(transport_id);
            }
        }
    }

    fn stop_detached_now(&self, key: &SessionKey, transport_id: u64, cancelled: &AtomicBool) {
        if cancelled.load(Ordering::SeqCst) {
            return;
        }
        let Ok((transport, mut reader, _)) = self.connect(
            &key.host_alias,
            transport_id,
            ReaderBinding::Closed,
            Some(cancelled),
        ) else {
            return;
        };
        let outcome = (|| -> SessionResult<()> {
            transport.write_message(&Message::PtyAttach {
                session_id: key.session_id.clone(),
            })?;
            loop {
                match read_typed_message(&mut reader)? {
                    Message::PtyOutput { .. } => {}
                    Message::PtyAttached { session_id, .. } if session_id == key.session_id => {
                        break;
                    }
                    Message::PtyExited { session_id } if session_id == key.session_id => {
                        return Ok(());
                    }
                    Message::Reject {
                        code: RejectCode::SessionNotFound,
                        ..
                    } => return Ok(()),
                    _ => return Err("remote_session_shutdown_attach_failed"),
                }
            }
            transport.write_message(&Message::PtyStop {
                session_id: key.session_id.clone(),
            })?;
            loop {
                match read_typed_message(&mut reader)? {
                    Message::PtyOutput { .. } => {}
                    Message::PtyStopped => return Ok(()),
                    Message::PtyExited { session_id } if session_id == key.session_id => {
                        return Ok(());
                    }
                    Message::Reject {
                        code: RejectCode::SessionNotFound,
                        ..
                    } => return Ok(()),
                    _ => return Err("remote_session_shutdown_stop_failed"),
                }
            }
        })();
        let _ = outcome;
        self.inner.finish_transport(transport_id);
        transport.reap();
    }

    fn quiesce_transport(
        &self,
        transport: &Arc<Transport>,
        fallback_key: Option<SessionKey>,
        timeout: Duration,
    ) -> Option<SessionKey> {
        let (sender, receiver) = mpsc::channel();
        let action = match transport.binding.lock() {
            Ok(mut binding) => match binding.clone() {
                ReaderBinding::AwaitingStart { .. } | ReaderBinding::Pending(_) => {
                    *binding = ReaderBinding::Closed;
                    ShutdownTransportAction::Close
                }
                ReaderBinding::ConfirmedPending(key)
                | ReaderBinding::Attaching(key)
                | ReaderBinding::Attached(key) => {
                    if transport.set_event_sender(sender).is_err() {
                        *binding = ReaderBinding::Closed;
                        fallback_key
                            .map(ShutdownTransportAction::StopDetached)
                            .unwrap_or(ShutdownTransportAction::Close)
                    } else {
                        *binding = ReaderBinding::Stopping(key.clone());
                        ShutdownTransportAction::Stop {
                            key,
                            attach_first: false,
                        }
                    }
                }
                ReaderBinding::Detaching(key) => {
                    if transport.set_event_sender(sender).is_err() {
                        *binding = ReaderBinding::Closed;
                        ShutdownTransportAction::StopDetached(key)
                    } else {
                        *binding = ReaderBinding::Stopping(key.clone());
                        ShutdownTransportAction::Stop {
                            key,
                            attach_first: true,
                        }
                    }
                }
                ReaderBinding::AwaitingAttach(key) => {
                    *binding = ReaderBinding::Closed;
                    ShutdownTransportAction::StopDetached(key)
                }
                ReaderBinding::Stopping(key) => {
                    if transport.set_event_sender(sender).is_err() {
                        *binding = ReaderBinding::Closed;
                        ShutdownTransportAction::StopDetached(key)
                    } else {
                        ShutdownTransportAction::Stop {
                            key,
                            attach_first: false,
                        }
                    }
                }
                ReaderBinding::Closed => fallback_key
                    .map(ShutdownTransportAction::StopDetached)
                    .unwrap_or(ShutdownTransportAction::Close),
            },
            Err(_) => fallback_key
                .map(ShutdownTransportAction::StopDetached)
                .unwrap_or(ShutdownTransportAction::Close),
        };
        let stop_detached = match action {
            ShutdownTransportAction::Close => None,
            ShutdownTransportAction::StopDetached(key) => Some(key),
            ShutdownTransportAction::Stop { key, attach_first } => {
                #[cfg(test)]
                RemoteSessionTestHooks::run(&self.inner.test_hooks.before_shutdown_stop);
                let attach_written = !attach_first
                    || transport
                        .write_message(&Message::PtyAttach {
                            session_id: key.session_id.clone(),
                        })
                        .is_ok();
                if attach_written
                    && transport
                        .write_message(&Message::PtyStop {
                            session_id: key.session_id.clone(),
                        })
                        .is_ok()
                {
                    wait_for_stop(&receiver, timeout);
                }
                None
            }
        };
        self.inner.finish_transport(transport.id);
        transport.reap();
        stop_detached
    }
}

fn companion_args(host_alias: &str) -> Vec<String> {
    vec![
        "ssh-helper-stdio".to_string(),
        "--".to_string(),
        host_alias.to_string(),
    ]
}

fn validate_alias(host_alias: &str) -> SessionResult<()> {
    let mut characters = host_alias.chars();
    if !characters
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        || !characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
    {
        return Err("remote_session_alias_invalid");
    }
    Ok(())
}

fn validate_dimensions(cols: u16, rows: u16) -> SessionResult<()> {
    if cols == 0 || cols > MAX_PTY_COLS || rows == 0 || rows > MAX_PTY_ROWS {
        return Err("remote_session_dimensions_invalid");
    }
    Ok(())
}

fn validate_session_id(session_id: &str) -> SessionResult<()> {
    if session_id.len() != 32
        || !session_id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("remote_session_id_invalid");
    }
    Ok(())
}

fn required_capabilities() -> Vec<String> {
    SUPPORTED_CAPABILITIES
        .iter()
        .map(|capability| (*capability).to_string())
        .collect()
}

fn handshake_nonce() -> String {
    let counter = NONCE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hasher = Sha256::new();
    hasher.update(std::process::id().to_le_bytes());
    hasher.update(counter.to_le_bytes());
    hasher.update(timestamp.to_le_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn welcome_is_valid(message: &Message, nonce: &str) -> bool {
    matches!(
        message,
        Message::Welcome {
            protocol_version,
            nonce: returned_nonce,
            capabilities,
            peer_frame_limit,
        } if *protocol_version == PROTOCOL_VERSION
            && returned_nonce == nonce
            && capabilities == &required_capabilities()
            && *peer_frame_limit >= MAX_FRAME_LEN
    )
}

fn read_typed_message<R: Read>(reader: &mut R) -> SessionResult<Message> {
    let payload = read_frame(reader)
        .map_err(|_| "remote_session_transport_read_failed")?
        .map_err(|_| "remote_session_protocol_rejected")?;
    decode_payload(&payload).map_err(|_| "remote_session_protocol_rejected")
}

fn start_reader(
    inner: Weak<ManagerInner>,
    transport: Arc<Transport>,
    mut reader: Box<dyn Read + Send>,
    last_hello_welcome_rtt_ms: u64,
) {
    thread::spawn(move || {
        loop {
            let message = match read_typed_message(&mut reader) {
                Ok(message) => message,
                Err(_) => {
                    handle_transport_loss(&inner, &transport);
                    break;
                }
            };
            if !handle_reader_message(&inner, &transport, message, last_hello_welcome_rtt_ms) {
                break;
            }
        }
        if let Some(inner) = inner.upgrade() {
            inner.finish_transport(transport.id);
        } else {
            transport.reap();
        }
    });
}

fn handle_reader_message(
    inner: &Weak<ManagerInner>,
    transport: &Arc<Transport>,
    message: Message,
    last_hello_welcome_rtt_ms: u64,
) -> bool {
    if matches!(message, Message::PtyOutput { .. }) {
        return true;
    }
    let Some(inner) = inner.upgrade() else {
        return false;
    };
    let Ok(mut binding) = transport.binding.lock() else {
        transport.emit(ReaderEvent::Lost);
        return false;
    };
    match (&*binding, message) {
        (ReaderBinding::AwaitingStart { host_alias }, Message::PtyStarted { session_id, .. }) => {
            let key = SessionKey::new(host_alias.clone(), session_id);
            let inserted = inner.state.lock().ok().is_some_and(|mut state| {
                state.insert_pending(key.clone(), transport.id, last_hello_welcome_rtt_ms)
            });
            if !inserted {
                *binding = ReaderBinding::Closed;
                transport.emit(ReaderEvent::Lost);
                return false;
            }
            *binding = ReaderBinding::Pending(key.clone());
            transport.emit(ReaderEvent::Started(key));
            true
        }
        (
            ReaderBinding::Pending(key) | ReaderBinding::ConfirmedPending(key),
            Message::PtyExited { session_id },
        ) if key.session_id == session_id => {
            if let Ok(mut state) = inner.state.lock() {
                state.tombstone_pending(key, transport.id);
            }
            *binding = ReaderBinding::Closed;
            transport.emit(ReaderEvent::Removed);
            false
        }
        (ReaderBinding::Attaching(key), Message::PtyAttached { session_id, .. })
            if key.session_id == session_id =>
        {
            let attached = inner
                .state
                .lock()
                .ok()
                .is_some_and(|mut state| state.complete_reattach(key, transport.id));
            if !attached {
                *binding = ReaderBinding::Closed;
                transport.emit(ReaderEvent::Lost);
                return false;
            }
            *binding = ReaderBinding::Attached(key.clone());
            transport.emit(ReaderEvent::Attached);
            true
        }
        (
            ReaderBinding::Attaching(key)
            | ReaderBinding::Attached(key)
            | ReaderBinding::Detaching(key)
            | ReaderBinding::Stopping(key),
            Message::PtyExited { session_id },
        ) if key.session_id == session_id => {
            if let Ok(mut state) = inner.state.lock() {
                state.remove_published(key, transport.id);
            }
            *binding = ReaderBinding::Closed;
            transport.emit(ReaderEvent::Removed);
            false
        }
        (ReaderBinding::Detaching(key), Message::PtyDetached) => {
            let detached = inner
                .state
                .lock()
                .ok()
                .is_some_and(|mut state| state.mark_detached(key, transport.id));
            *binding = ReaderBinding::Closed;
            transport.emit(if detached {
                ReaderEvent::Detached
            } else {
                ReaderEvent::Lost
            });
            false
        }
        (ReaderBinding::Stopping(key), Message::PtyAttached { session_id, .. })
            if key.session_id == session_id =>
        {
            true
        }
        (ReaderBinding::Stopping(_), Message::PtyDetached) => true,
        (ReaderBinding::Stopping(_), Message::PtyStopped) => {
            *binding = ReaderBinding::Closed;
            transport.emit(ReaderEvent::Stopped);
            false
        }
        (
            ReaderBinding::Pending(key) | ReaderBinding::ConfirmedPending(key),
            Message::Reject {
                code: RejectCode::SessionNotFound,
                ..
            },
        ) => {
            if let Ok(mut state) = inner.state.lock() {
                state.tombstone_pending(key, transport.id);
            }
            *binding = ReaderBinding::Closed;
            transport.emit(ReaderEvent::Removed);
            false
        }
        (
            ReaderBinding::Attaching(key)
            | ReaderBinding::Attached(key)
            | ReaderBinding::Detaching(key)
            | ReaderBinding::Stopping(key),
            Message::Reject {
                code: RejectCode::SessionNotFound,
                ..
            },
        ) => {
            if let Ok(mut state) = inner.state.lock() {
                state.remove_published(key, transport.id);
            }
            *binding = ReaderBinding::Closed;
            transport.emit(ReaderEvent::Removed);
            false
        }
        _ => {
            drop(binding);
            handle_transport_loss(&Arc::downgrade(&inner), transport);
            false
        }
    }
}

fn handle_transport_loss(inner: &Weak<ManagerInner>, transport: &Arc<Transport>) {
    let Some(inner) = inner.upgrade() else {
        transport.reap();
        return;
    };
    if let Ok(mut binding) = transport.binding.lock() {
        match &*binding {
            ReaderBinding::Pending(key) | ReaderBinding::ConfirmedPending(key) => {
                if let Ok(mut state) = inner.state.lock() {
                    state.tombstone_pending(key, transport.id);
                }
            }
            ReaderBinding::AwaitingAttach(key) | ReaderBinding::Attaching(key) => {
                if let Ok(mut state) = inner.state.lock() {
                    state.fail_reattach(key, transport.id);
                }
            }
            ReaderBinding::Attached(key) | ReaderBinding::Detaching(key) => {
                if let Ok(mut state) = inner.state.lock() {
                    state.mark_unreachable(key, transport.id);
                }
            }
            ReaderBinding::AwaitingStart { .. }
            | ReaderBinding::Stopping(_)
            | ReaderBinding::Closed => {}
        }
        *binding = ReaderBinding::Closed;
    }
    transport.emit(ReaderEvent::Lost);
}

fn wait_for_stop(receiver: &Receiver<ReaderEvent>, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match receiver.recv_timeout(remaining) {
            Ok(
                ReaderEvent::Stopped
                | ReaderEvent::Removed
                | ReaderEvent::Lost
                | ReaderEvent::Attached
                | ReaderEvent::Detached,
            ) => return,
            Ok(ReaderEvent::Started(_)) => {}
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return,
        }
    }
}

#[tauri::command]
pub(crate) async fn remote_session_start(
    manager: tauri::State<'_, RemoteSessionManager>,
    alias: String,
    agent: RemoteAgent,
    cols: u16,
    rows: u16,
) -> Result<RemoteSessionSnapshot, String> {
    let handle = manager.handle.clone();
    tauri::async_runtime::spawn_blocking(move || handle.start(alias, agent, cols, rows))
        .await
        .map_err(|_| "remote_session_worker_failed".to_string())?
        .map_err(str::to_string)
}

#[tauri::command]
pub(crate) async fn remote_session_reattach(
    manager: tauri::State<'_, RemoteSessionManager>,
    alias: String,
    session_id: String,
) -> Result<RemoteSessionSnapshot, String> {
    let handle = manager.handle.clone();
    tauri::async_runtime::spawn_blocking(move || handle.reattach(&alias, &session_id))
        .await
        .map_err(|_| "remote_session_worker_failed".to_string())?
        .map_err(str::to_string)
}

#[tauri::command]
pub(crate) async fn remote_session_detach(
    manager: tauri::State<'_, RemoteSessionManager>,
    alias: String,
    session_id: String,
) -> Result<RemoteSessionSnapshot, String> {
    let handle = manager.handle.clone();
    tauri::async_runtime::spawn_blocking(move || handle.detach(&alias, &session_id))
        .await
        .map_err(|_| "remote_session_worker_failed".to_string())?
        .map_err(str::to_string)
}

#[tauri::command]
pub(crate) fn remote_session_snapshots(
    manager: tauri::State<'_, RemoteSessionManager>,
) -> Vec<RemoteSessionSnapshot> {
    manager.snapshots()
}

#[cfg(test)]
mod tests {
    use super::{
        CompanionChild, CompanionSpawner, ControllerState, ManagerState, RemoteAgent,
        RemoteSessionManager, RemoteSessionSnapshot, SessionKey, SessionResult, SpawnedCompanion,
    };
    use std::collections::VecDeque;
    use std::io::{self, Read, Write};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{self, Receiver, SyncSender};
    use std::sync::{Arc, Condvar, Mutex};
    use std::thread::{self, JoinHandle};
    use std::time::Duration;
    use winsmux_remote_helper::{
        decode_payload, read_frame, write_frame, AgentResolution, Message, MAX_FRAME_LEN,
        PROTOCOL_VERSION, SUPPORTED_CAPABILITIES,
    };

    enum PipeChunk {
        Bytes(Vec<u8>),
        Close,
    }

    #[derive(Clone)]
    struct PipeWriter {
        sender: SyncSender<PipeChunk>,
    }

    impl Write for PipeWriter {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.sender
                .send(PipeChunk::Bytes(buffer.to_vec()))
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "pipe reader closed"))?;
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl Drop for PipeWriter {
        fn drop(&mut self) {
            let _ = self.sender.send(PipeChunk::Close);
        }
    }

    struct PipeReader {
        receiver: Receiver<PipeChunk>,
        buffered: VecDeque<u8>,
        closed: bool,
    }

    impl Read for PipeReader {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            while self.buffered.is_empty() && !self.closed {
                match self.receiver.recv() {
                    Ok(PipeChunk::Bytes(bytes)) => self.buffered.extend(bytes),
                    Ok(PipeChunk::Close) | Err(_) => self.closed = true,
                }
            }
            let count = output.len().min(self.buffered.len());
            for slot in output.iter_mut().take(count) {
                *slot = self
                    .buffered
                    .pop_front()
                    .expect("buffer length was checked");
            }
            Ok(count)
        }
    }

    fn pipe(capacity: usize) -> (PipeWriter, PipeReader) {
        let (sender, receiver) = mpsc::sync_channel(capacity);
        (
            PipeWriter { sender },
            PipeReader {
                receiver,
                buffered: VecDeque::new(),
                closed: false,
            },
        )
    }

    #[derive(Default)]
    struct FakeRunLog {
        args: Vec<String>,
        received: Mutex<Vec<Message>>,
        reaped: AtomicBool,
        reaped_wait: (Mutex<bool>, Condvar),
    }

    #[derive(Default)]
    struct TestGate {
        state: Mutex<TestGateState>,
        changed: Condvar,
    }

    #[derive(Default)]
    struct TestGateState {
        reached: bool,
        released: bool,
        cancelled: bool,
    }

    impl TestGate {
        fn pause(&self) -> bool {
            let mut state = self.state.lock().expect("test gate lock");
            state.reached = true;
            self.changed.notify_all();
            while !state.released && !state.cancelled {
                state = self.changed.wait(state).expect("test gate wait");
            }
            !state.cancelled
        }

        fn wait_until_reached(&self) {
            let mut state = self.state.lock().expect("test gate lock");
            while !state.reached {
                state = self.changed.wait(state).expect("test gate wait");
            }
        }

        fn release(&self) {
            let mut state = self.state.lock().expect("test gate lock");
            state.released = true;
            self.changed.notify_all();
        }

        fn cancel(&self) {
            let mut state = self.state.lock().expect("test gate lock");
            state.cancelled = true;
            self.changed.notify_all();
        }
    }

    enum WelcomeMode {
        Valid,
        MissingCapability,
        NonceMismatch,
        InsufficientPeerLimit,
        Malformed,
        RejectDetail,
    }

    enum ScriptStep {
        Expect(Message),
        Send(Message),
        SendManyOutput(usize),
        WaitForSignal(Arc<(Mutex<bool>, Condvar)>),
        Pause(Arc<TestGate>),
        StallUntilEof,
    }

    struct FakeScript {
        welcome: WelcomeMode,
        steps: Vec<ScriptStep>,
    }

    struct FakeChild {
        join: Option<JoinHandle<()>>,
        stop_sender: SyncSender<PipeChunk>,
        log: Arc<FakeRunLog>,
        pause_gates: Vec<Arc<TestGate>>,
    }

    impl CompanionChild for FakeChild {
        fn try_wait(&mut self) -> io::Result<bool> {
            Ok(self.join.as_ref().is_none_or(JoinHandle::is_finished))
        }

        fn kill(&mut self) -> io::Result<()> {
            for gate in &self.pause_gates {
                gate.cancel();
            }
            let _ = self.stop_sender.send(PipeChunk::Close);
            Ok(())
        }

        fn wait(&mut self) -> io::Result<()> {
            let join_result = self.join.take().map_or(Ok(()), |join| {
                join.join()
                    .map_err(|_| io::Error::other("fake helper thread panicked"))
            });
            self.log.reaped.store(true, Ordering::SeqCst);
            if let Ok(mut reaped) = self.log.reaped_wait.0.lock() {
                *reaped = true;
                self.log.reaped_wait.1.notify_all();
            }
            join_result
        }
    }

    struct FakeSpawner {
        scripts: Mutex<VecDeque<FakeScript>>,
        logs: Mutex<Vec<Arc<FakeRunLog>>>,
    }

    impl FakeSpawner {
        fn new(scripts: Vec<FakeScript>) -> Self {
            Self {
                scripts: Mutex::new(scripts.into()),
                logs: Mutex::new(Vec::new()),
            }
        }

        fn logs(&self) -> Vec<Arc<FakeRunLog>> {
            self.logs.lock().expect("fake logs lock").clone()
        }
    }

    impl CompanionSpawner for FakeSpawner {
        fn spawn(&self, args: &[String]) -> SessionResult<SpawnedCompanion> {
            let script = self
                .scripts
                .lock()
                .map_err(|_| "remote_session_test_spawner_failed")?
                .pop_front()
                .ok_or("remote_session_test_script_missing")?;
            let log = Arc::new(FakeRunLog {
                args: args.to_vec(),
                ..FakeRunLog::default()
            });
            let pause_gates = script
                .steps
                .iter()
                .filter_map(|step| match step {
                    ScriptStep::Pause(gate) => Some(gate.clone()),
                    _ => None,
                })
                .collect();
            self.logs
                .lock()
                .map_err(|_| "remote_session_test_spawner_failed")?
                .push(log.clone());

            let (client_writer, server_reader) = pipe(1);
            let (server_writer, client_reader) = pipe(1);
            let stop_sender = client_writer.sender.clone();
            let thread_log = log.clone();
            let join = thread::spawn(move || {
                run_fake_script(server_reader, server_writer, script, thread_log)
            });

            Ok(SpawnedCompanion {
                writer: Box::new(client_writer),
                reader: Box::new(client_reader),
                child: Box::new(FakeChild {
                    join: Some(join),
                    stop_sender,
                    log,
                    pause_gates,
                }),
            })
        }
    }

    fn read_typed(reader: &mut impl Read) -> io::Result<Message> {
        let payload = read_frame(reader)?.map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "fake helper received invalid frame",
            )
        })?;
        decode_payload(&payload).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "fake helper received invalid payload",
            )
        })
    }

    fn run_fake_script(
        mut reader: PipeReader,
        mut writer: PipeWriter,
        script: FakeScript,
        log: Arc<FakeRunLog>,
    ) {
        let hello = read_typed(&mut reader).expect("fake helper should receive Hello");
        log.received
            .lock()
            .expect("fake received lock")
            .push(hello.clone());
        let Message::Hello { nonce, .. } = hello else {
            panic!("first message must be Hello");
        };
        match script.welcome {
            WelcomeMode::Valid => write_frame(
                &mut writer,
                &Message::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    nonce,
                    capabilities: SUPPORTED_CAPABILITIES
                        .iter()
                        .map(|capability| (*capability).to_string())
                        .collect(),
                    peer_frame_limit: MAX_FRAME_LEN,
                },
            )
            .expect("fake helper should write Welcome"),
            WelcomeMode::MissingCapability => write_frame(
                &mut writer,
                &Message::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    nonce,
                    capabilities: ["frame-v1", "pty-v1", "agent-path-v1"]
                        .iter()
                        .map(|capability| (*capability).to_string())
                        .collect(),
                    peer_frame_limit: MAX_FRAME_LEN,
                },
            )
            .expect("fake helper should write incomplete Welcome"),
            WelcomeMode::NonceMismatch => write_frame(
                &mut writer,
                &Message::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    nonce: "ff".repeat(32),
                    capabilities: SUPPORTED_CAPABILITIES
                        .iter()
                        .map(|capability| (*capability).to_string())
                        .collect(),
                    peer_frame_limit: MAX_FRAME_LEN,
                },
            )
            .expect("fake helper should write mismatched Welcome"),
            WelcomeMode::InsufficientPeerLimit => write_frame(
                &mut writer,
                &Message::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    nonce,
                    capabilities: SUPPORTED_CAPABILITIES
                        .iter()
                        .map(|capability| (*capability).to_string())
                        .collect(),
                    peer_frame_limit: MAX_FRAME_LEN - 1,
                },
            )
            .expect("fake helper should write insufficient Welcome"),
            WelcomeMode::Malformed => {
                writer
                    .write_all(&1u32.to_be_bytes())
                    .expect("fake helper should write malformed prefix");
                writer
                    .write_all(b"{")
                    .expect("fake helper should write malformed payload");
                writer
                    .flush()
                    .expect("fake helper should flush malformed frame");
            }
            WelcomeMode::RejectDetail => write_frame(
                &mut writer,
                &Message::Reject {
                    code: winsmux_remote_helper::RejectCode::Unsupported,
                    detail: "sensitive-host-and-path".to_string(),
                },
            )
            .expect("fake helper should write Reject"),
        }

        for step in script.steps {
            match step {
                ScriptStep::Expect(expected) => {
                    let actual = read_typed(&mut reader).expect("fake helper expected a message");
                    log.received
                        .lock()
                        .expect("fake received lock")
                        .push(actual.clone());
                    assert_eq!(actual, expected);
                }
                ScriptStep::Send(message) => {
                    write_frame(&mut writer, &message).expect("fake helper should write message");
                }
                ScriptStep::SendManyOutput(count) => {
                    for _ in 0..count {
                        write_frame(
                            &mut writer,
                            &Message::PtyOutput {
                                data_b64: "eA==".to_string(),
                            },
                        )
                        .expect("fake helper should stream PTY output");
                    }
                }
                ScriptStep::WaitForSignal(signal) => {
                    let mut ready = signal.0.lock().expect("fake signal lock");
                    while !*ready {
                        ready = signal.1.wait(ready).expect("fake signal wait");
                    }
                }
                ScriptStep::Pause(gate) => {
                    if !gate.pause() {
                        return;
                    }
                }
                ScriptStep::StallUntilEof => {
                    while let Ok(message) = read_typed(&mut reader) {
                        log.received
                            .lock()
                            .expect("fake received lock")
                            .push(message);
                    }
                    return;
                }
            }
        }
    }

    fn signal(control: &Arc<(Mutex<bool>, Condvar)>) {
        let mut ready = control.0.lock().expect("fake signal lock");
        *ready = true;
        control.1.notify_all();
    }

    fn wait_until_reaped(log: &FakeRunLog) {
        let reaped = log.reaped_wait.0.lock().expect("fake reaped lock");
        let (reaped, _) = log
            .reaped_wait
            .1
            .wait_timeout_while(
                reaped,
                Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS),
                |reaped| !*reaped,
            )
            .expect("fake reaped wait");
        assert!(*reaped, "fake companion should be reaped");
    }

    fn controlled_end_script(
        session_id: &str,
        host_agent: RemoteAgent,
        control: Arc<(Mutex<bool>, Condvar)>,
        output_frames: usize,
        exit: bool,
    ) -> FakeScript {
        let executable = host_agent.executable();
        let mut steps = vec![
            ScriptStep::Expect(Message::PtyStart {
                executable: executable.to_string(),
                resolution: Some(AgentResolution {
                    absolute_path: None,
                    user_candidates: Vec::new(),
                }),
                argv: Vec::new(),
                cols: 120,
                rows: 40,
            }),
            ScriptStep::Send(Message::PtyStarted {
                session_id: session_id.to_string(),
                child_pid: 8484,
                resolved_executable: Some(format!("/usr/bin/{executable}")),
            }),
            ScriptStep::Expect(Message::PtyStartAck {
                session_id: session_id.to_string(),
            }),
            ScriptStep::WaitForSignal(control),
        ];
        if output_frames > 0 {
            steps.push(ScriptStep::SendManyOutput(output_frames));
        }
        if exit {
            steps.push(ScriptStep::Send(Message::PtyExited {
                session_id: session_id.to_string(),
            }));
        }
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps,
        }
    }

    fn start_script(session_id: &str, alias_agent: RemoteAgent) -> FakeScript {
        let executable = match alias_agent {
            RemoteAgent::Claude => "claude",
            RemoteAgent::Codex => "codex",
        };
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: executable.to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 4242,
                    resolved_executable: Some(format!("/usr/bin/{executable}")),
                }),
                ScriptStep::Expect(Message::PtyStartAck {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn detach_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "codex".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 4242,
                    resolved_executable: Some("/usr/bin/codex".to_string()),
                }),
                ScriptStep::Expect(Message::PtyStartAck {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Expect(Message::PtyDetach),
                ScriptStep::Send(Message::PtyDetached),
            ],
        }
    }

    fn reattach_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyAttached {
                    session_id: session_id.to_string(),
                    child_pid: 5252,
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn shutdown_detached_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyAttached {
                    session_id: session_id.to_string(),
                    child_pid: 6262,
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn stalled_shutdown_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyAttached {
                    session_id: session_id.to_string(),
                    child_pid: 6363,
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::StallUntilEof,
            ],
        }
    }

    fn failed_ack_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "claude".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 7373,
                    resolved_executable: Some("/usr/bin/claude".to_string()),
                }),
            ],
        }
    }

    fn pre_id_shutdown_script(session_id: &str, gate: Arc<TestGate>) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "claude".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Pause(gate),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 7474,
                    resolved_executable: Some("/usr/bin/claude".to_string()),
                }),
                ScriptStep::StallUntilEof,
            ],
        }
    }

    fn pending_shutdown_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "claude".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 7575,
                    resolved_executable: Some("/usr/bin/claude".to_string()),
                }),
                ScriptStep::StallUntilEof,
            ],
        }
    }

    fn confirmed_pending_shutdown_script(session_id: &str) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "claude".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 7676,
                    resolved_executable: Some("/usr/bin/claude".to_string()),
                }),
                ScriptStep::Expect(Message::PtyStartAck {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn attaching_shutdown_script(session_id: &str, gate: Arc<TestGate>) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Pause(gate),
                ScriptStep::Send(Message::PtyAttached {
                    session_id: session_id.to_string(),
                    child_pid: 7777,
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn detaching_shutdown_script(session_id: &str, gate: Arc<TestGate>) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyStart {
                    executable: "codex".to_string(),
                    resolution: Some(AgentResolution {
                        absolute_path: None,
                        user_candidates: Vec::new(),
                    }),
                    argv: Vec::new(),
                    cols: 120,
                    rows: 40,
                }),
                ScriptStep::Send(Message::PtyStarted {
                    session_id: session_id.to_string(),
                    child_pid: 7878,
                    resolved_executable: Some("/usr/bin/codex".to_string()),
                }),
                ScriptStep::Expect(Message::PtyStartAck {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Expect(Message::PtyDetach),
                ScriptStep::Pause(gate),
                ScriptStep::Send(Message::PtyDetached),
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyAttached {
                    session_id: session_id.to_string(),
                    child_pid: 7878,
                }),
                ScriptStep::Expect(Message::PtyStop {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(Message::PtyStopped),
            ],
        }
    }

    fn reattach_response_script(session_id: &str, response: Message) -> FakeScript {
        FakeScript {
            welcome: WelcomeMode::Valid,
            steps: vec![
                ScriptStep::Expect(Message::PtyAttach {
                    session_id: session_id.to_string(),
                }),
                ScriptStep::Send(response),
            ],
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    enum ShutdownProgress {
        StopAttempted,
        Finished,
    }

    #[test]
    fn snapshot_serialization_contains_only_the_four_frozen_fields() {
        let snapshot = RemoteSessionSnapshot {
            session_id: "0123456789abcdef0123456789abcdef".to_string(),
            host_alias: "build-host".to_string(),
            controller_state: ControllerState::Attached,
            last_hello_welcome_rtt_ms: 17,
        };

        assert_eq!(
            serde_json::to_value(snapshot).expect("snapshot should serialize"),
            serde_json::json!({
                "sessionId": "0123456789abcdef0123456789abcdef",
                "hostAlias": "build-host",
                "controllerState": "attached",
                "lastHelloWelcomeRttMs": 17,
            })
        );
    }

    #[test]
    fn pending_exit_tombstone_blocks_late_ack_publication() {
        let key = SessionKey::new(
            "build-host".to_string(),
            "0123456789abcdef0123456789abcdef".to_string(),
        );
        let mut state = ManagerState::default();

        assert!(state.insert_pending(key.clone(), 41, 7));
        assert!(state.snapshots().is_empty());
        assert!(state.tombstone_pending(&key, 41));
        assert!(!state.publish_pending(&key, 41));
        assert!(state.snapshots().is_empty());
    }

    #[test]
    fn shutdown_before_pty_started_reaps_registered_pre_id_transport() {
        let session_id = "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";
        let gate = Arc::new(TestGate::default());
        let spawner = Arc::new(FakeSpawner::new(vec![pre_id_shutdown_script(
            session_id,
            gate.clone(),
        )]));
        let manager = Arc::new(RemoteSessionManager::with_spawner(spawner.clone()));
        let start_manager = manager.clone();
        let start = thread::spawn(move || {
            start_manager.start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
        });
        gate.wait_until_reached();

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        let logs = spawner.logs();
        let reaped_during_shutdown = logs[0].reaped.load(Ordering::SeqCst);
        gate.release();
        assert!(start.join().expect("start thread should join").is_err());
        assert!(
            reaped_during_shutdown,
            "shutdown must reap a registered transport before PtyStarted"
        );
        let received = logs[0].received.lock().expect("fake received lock");
        assert!(!received.iter().any(|message| matches!(
            message,
            Message::PtyStartAck { .. } | Message::PtyStop { .. }
        )));
    }

    #[test]
    fn shutdown_closes_unacked_pending_without_pty_stop() {
        let session_id = "1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d";
        let gate = Arc::new(TestGate::default());
        let spawner = Arc::new(FakeSpawner::new(vec![pending_shutdown_script(session_id)]));
        let manager = Arc::new(RemoteSessionManager::with_spawner(spawner.clone()));
        let hook_gate = gate.clone();
        manager
            .handle
            .inner
            .test_hooks
            .set_before_start_ack(Arc::new(move || {
                assert!(hook_gate.pause());
            }));
        let start_manager = manager.clone();
        let start = thread::spawn(move || {
            start_manager.start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
        });
        gate.wait_until_reached();

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        let logs = spawner.logs();
        assert!(logs[0].reaped.load(Ordering::SeqCst));
        gate.release();
        assert!(start.join().expect("start thread should join").is_err());
        let received = logs[0].received.lock().expect("fake received lock");
        assert!(!received.iter().any(|message| matches!(
            message,
            Message::PtyStartAck { .. } | Message::PtyStop { .. }
        )));
    }

    #[test]
    fn shutdown_after_start_ack_before_publish_stops_then_reaps() {
        let session_id = "2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d";
        let gate = Arc::new(TestGate::default());
        let spawner = Arc::new(FakeSpawner::new(vec![confirmed_pending_shutdown_script(
            session_id,
        )]));
        let manager = Arc::new(RemoteSessionManager::with_spawner(spawner.clone()));
        let hook_gate = gate.clone();
        manager
            .handle
            .inner
            .test_hooks
            .set_after_start_ack(Arc::new(move || {
                assert!(hook_gate.pause());
            }));
        let start_manager = manager.clone();
        let start = thread::spawn(move || {
            start_manager.start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
        });
        gate.wait_until_reached();

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        gate.release();
        assert!(start.join().expect("start thread should join").is_err());
        let logs = spawner.logs();
        assert!(logs[0].reaped.load(Ordering::SeqCst));
        let received = logs[0].received.lock().expect("fake received lock");
        assert!(received.iter().any(|message| {
            matches!(message, Message::PtyStartAck { session_id: id } if id == session_id)
        }));
        assert!(received.iter().any(|message| {
            matches!(message, Message::PtyStop { session_id: id } if id == session_id)
        }));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn shutdown_while_attaching_stops_before_local_reap() {
        let session_id = "3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d";
        let gate = Arc::new(TestGate::default());
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            attaching_shutdown_script(session_id, gate.clone()),
        ]));
        let manager = Arc::new(RemoteSessionManager::with_spawner(spawner.clone()));
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");
        let reattach_manager = manager.clone();
        let reattach = thread::spawn(move || reattach_manager.reattach("gpu-host", session_id));
        gate.wait_until_reached();
        let (progress_sender, progress_receiver) = mpsc::channel();
        let stop_sender = progress_sender.clone();
        manager
            .handle
            .inner
            .test_hooks
            .set_before_shutdown_stop(Arc::new(move || {
                let _ = stop_sender.send(ShutdownProgress::StopAttempted);
            }));
        let shutdown_manager = manager.clone();
        let shutdown = thread::spawn(move || {
            shutdown_manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));
            let _ = progress_sender.send(ShutdownProgress::Finished);
        });

        let first_progress = progress_receiver
            .recv()
            .expect("shutdown should report progress");
        gate.release();
        shutdown.join().expect("shutdown thread should join");
        let _ = reattach.join().expect("reattach thread should join");

        assert_eq!(first_progress, ShutdownProgress::StopAttempted);
        let logs = spawner.logs();
        assert!(logs[1].reaped.load(Ordering::SeqCst));
        let received = logs[1].received.lock().expect("fake received lock");
        assert!(received.iter().any(|message| {
            matches!(message, Message::PtyStop { session_id: id } if id == session_id)
        }));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn shutdown_while_detaching_reattaches_stops_before_local_reap() {
        let session_id = "4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d";
        let gate = Arc::new(TestGate::default());
        let spawner = Arc::new(FakeSpawner::new(vec![detaching_shutdown_script(
            session_id,
            gate.clone(),
        )]));
        let manager = Arc::new(RemoteSessionManager::with_spawner(spawner.clone()));
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        let detach_manager = manager.clone();
        let detach = thread::spawn(move || detach_manager.detach("gpu-host", session_id));
        gate.wait_until_reached();
        let (progress_sender, progress_receiver) = mpsc::channel();
        let stop_sender = progress_sender.clone();
        manager
            .handle
            .inner
            .test_hooks
            .set_before_shutdown_stop(Arc::new(move || {
                let _ = stop_sender.send(ShutdownProgress::StopAttempted);
            }));
        let shutdown_manager = manager.clone();
        let shutdown = thread::spawn(move || {
            shutdown_manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));
            let _ = progress_sender.send(ShutdownProgress::Finished);
        });

        let first_progress = progress_receiver
            .recv()
            .expect("shutdown should report progress");
        gate.release();
        shutdown.join().expect("shutdown thread should join");
        let _ = detach.join().expect("detach thread should join");

        assert_eq!(first_progress, ShutdownProgress::StopAttempted);
        let logs = spawner.logs();
        assert!(logs[0].reaped.load(Ordering::SeqCst));
        let received = logs[0].received.lock().expect("fake received lock");
        assert!(received.iter().any(|message| {
            matches!(message, Message::PtyAttach { session_id: id } if id == session_id)
        }));
        assert!(received.iter().any(|message| {
            matches!(message, Message::PtyStop { session_id: id } if id == session_id)
        }));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn start_uses_exact_companion_argv_and_typed_path_only_message() {
        let session_id = "0123456789abcdef0123456789abcdef";
        let spawner = Arc::new(FakeSpawner::new(vec![start_script(
            session_id,
            RemoteAgent::Claude,
        )]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());

        let snapshot = manager
            .start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
            .expect("start should publish an attached session");

        assert_eq!(snapshot.session_id, session_id);
        assert_eq!(snapshot.host_alias, "build-host");
        assert_eq!(snapshot.controller_state, ControllerState::Attached);
        assert_eq!(manager.snapshots(), vec![snapshot]);

        let logs = spawner.logs();
        assert_eq!(logs.len(), 1);
        assert_eq!(logs[0].args, ["ssh-helper-stdio", "--", "build-host"]);
        let received = logs[0].received.lock().expect("fake received lock");
        let Message::Hello {
            protocol_version,
            capabilities,
            peer_frame_limit,
            ..
        } = &received[0]
        else {
            panic!("first message must be Hello");
        };
        assert_eq!(*protocol_version, PROTOCOL_VERSION);
        assert_eq!(
            capabilities,
            &SUPPORTED_CAPABILITIES
                .iter()
                .map(|capability| (*capability).to_string())
                .collect::<Vec<_>>()
        );
        assert_eq!(*peer_frame_limit, MAX_FRAME_LEN);
        drop(received);

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));
        assert!(logs[0].reaped.load(Ordering::SeqCst));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn user_detach_keeps_row_reaps_child_and_never_sends_stop() {
        let session_id = "abcdef0123456789abcdef0123456789";
        let spawner = Arc::new(FakeSpawner::new(vec![detach_script(session_id)]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");

        let detached = manager
            .detach("gpu-host", session_id)
            .expect("detach should retain the tuple");

        assert_eq!(detached.controller_state, ControllerState::Detached);
        assert_eq!(manager.snapshots(), vec![detached]);
        let logs = spawner.logs();
        assert!(logs[0].reaped.load(Ordering::SeqCst));
        let received = logs[0].received.lock().expect("fake received lock");
        assert!(received
            .iter()
            .any(|message| matches!(message, Message::PtyDetach)));
        assert!(!received
            .iter()
            .any(|message| matches!(message, Message::PtyStop { .. })));
    }

    #[test]
    fn unknown_tuple_reattach_fails_before_companion_spawn() {
        let spawner = Arc::new(FakeSpawner::new(Vec::new()));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());

        assert_eq!(
            manager.reattach("gpu-host", "11111111111111111111111111111111"),
            Err("remote_session_unknown")
        );
        assert!(spawner.logs().is_empty());
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn known_detached_tuple_publishes_only_after_matching_attached() {
        let session_id = "22222222222222222222222222222222";
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            reattach_script(session_id),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");

        let attached = manager
            .reattach("gpu-host", session_id)
            .expect("known tuple should reattach");

        assert_eq!(attached.controller_state, ControllerState::Attached);
        assert_eq!(manager.snapshots(), vec![attached]);
        assert_eq!(spawner.logs().len(), 2);
        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));
    }

    #[test]
    fn orderly_shutdown_attaches_then_stops_detached_row() {
        let session_id = "33333333333333333333333333333333";
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            shutdown_detached_script(session_id),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        let logs = spawner.logs();
        assert_eq!(logs.len(), 2);
        assert!(logs[1].reaped.load(Ordering::SeqCst));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn handshake_rejections_leave_no_row_or_child() {
        for welcome in [
            WelcomeMode::MissingCapability,
            WelcomeMode::NonceMismatch,
            WelcomeMode::InsufficientPeerLimit,
            WelcomeMode::Malformed,
            WelcomeMode::RejectDetail,
        ] {
            let spawner = Arc::new(FakeSpawner::new(vec![FakeScript {
                welcome,
                steps: Vec::new(),
            }]));
            let manager = RemoteSessionManager::with_spawner(spawner.clone());

            let error = manager
                .start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
                .expect_err("invalid Welcome must fail before PtyStart");

            assert!(matches!(
                error,
                "remote_session_handshake_rejected" | "remote_session_protocol_rejected"
            ));
            assert!(!error.contains("sensitive"));
            assert!(manager.snapshots().is_empty());
            let logs = spawner.logs();
            assert_eq!(logs.len(), 1);
            assert!(logs[0].reaped.load(Ordering::SeqCst));
            assert_eq!(
                logs[0].received.lock().expect("fake received lock").len(),
                1
            );
        }
    }

    #[test]
    fn failed_start_ack_write_publishes_no_ownership() {
        let session_id = "44444444444444444444444444444444";
        let spawner = Arc::new(FakeSpawner::new(vec![failed_ack_script(session_id)]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());

        assert!(manager
            .start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
            .is_err());
        assert!(manager.snapshots().is_empty());
        let logs = spawner.logs();
        assert!(logs[0].reaped.load(Ordering::SeqCst));
    }

    #[test]
    fn transport_loss_retains_exactly_one_unreachable_row() {
        let session_id = "55555555555555555555555555555555";
        let control = Arc::new((Mutex::new(false), Condvar::new()));
        let spawner = Arc::new(FakeSpawner::new(vec![controlled_end_script(
            session_id,
            RemoteAgent::Claude,
            control.clone(),
            0,
            false,
        )]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
            .expect("start should attach");

        signal(&control);
        let logs = spawner.logs();
        wait_until_reaped(&logs[0]);

        let snapshots = manager.snapshots();
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].controller_state, ControllerState::Unreachable);
    }

    #[test]
    fn exited_alias_removes_only_its_row_when_helper_ids_match() {
        let session_id = "66666666666666666666666666666666";
        let first_control = Arc::new((Mutex::new(false), Condvar::new()));
        let second_control = Arc::new((Mutex::new(false), Condvar::new()));
        let spawner = Arc::new(FakeSpawner::new(vec![
            controlled_end_script(
                session_id,
                RemoteAgent::Claude,
                first_control.clone(),
                0,
                true,
            ),
            controlled_end_script(
                session_id,
                RemoteAgent::Codex,
                second_control.clone(),
                0,
                true,
            ),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("z-host".to_string(), RemoteAgent::Claude, 120, 40)
            .expect("first alias should attach");
        manager
            .start("a-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("second alias should attach");
        assert_eq!(
            manager
                .snapshots()
                .iter()
                .map(|snapshot| snapshot.host_alias.as_str())
                .collect::<Vec<_>>(),
            ["a-host", "z-host"]
        );

        signal(&first_control);
        let logs = spawner.logs();
        wait_until_reaped(&logs[0]);
        let remaining = manager.snapshots();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].host_alias, "a-host");

        signal(&second_control);
        wait_until_reaped(&logs[1]);
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn output_beyond_pipe_capacity_is_drained_before_exit() {
        let session_id = "77777777777777777777777777777777";
        let control = Arc::new((Mutex::new(false), Condvar::new()));
        let spawner = Arc::new(FakeSpawner::new(vec![controlled_end_script(
            session_id,
            RemoteAgent::Codex,
            control.clone(),
            64,
            true,
        )]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");

        signal(&control);
        let logs = spawner.logs();
        wait_until_reaped(&logs[0]);

        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn shutdown_timeout_reaps_stalled_detached_companion_and_returns() {
        let session_id = "88888888888888888888888888888888";
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            stalled_shutdown_script(session_id),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        let logs = spawner.logs();
        assert_eq!(logs.len(), 2);
        assert!(logs[1].reaped.load(Ordering::SeqCst));
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn shutdown_drops_unreachable_row_without_spawning() {
        let session_id = "99999999999999999999999999999999";
        let control = Arc::new((Mutex::new(false), Condvar::new()));
        let spawner = Arc::new(FakeSpawner::new(vec![controlled_end_script(
            session_id,
            RemoteAgent::Claude,
            control.clone(),
            0,
            false,
        )]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("build-host".to_string(), RemoteAgent::Claude, 120, 40)
            .expect("start should attach");
        signal(&control);
        let logs = spawner.logs();
        wait_until_reaped(&logs[0]);
        assert_eq!(
            manager.snapshots()[0].controller_state,
            ControllerState::Unreachable
        );

        manager.shutdown(Duration::from_millis(crate::DESKTOP_SHUTDOWN_PTY_WAIT_MS));

        assert_eq!(spawner.logs().len(), 1);
        assert!(manager.snapshots().is_empty());
    }

    #[test]
    fn mismatched_attached_response_keeps_known_tuple_unreachable() {
        let session_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            reattach_response_script(
                session_id,
                Message::PtyAttached {
                    session_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_string(),
                    child_pid: 9494,
                },
            ),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");

        assert!(manager.reattach("gpu-host", session_id).is_err());

        let snapshots = manager.snapshots();
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].controller_state, ControllerState::Unreachable);
        let logs = spawner.logs();
        assert!(logs[1].reaped.load(Ordering::SeqCst));
    }

    #[test]
    fn session_not_found_on_reattach_removes_known_tuple() {
        let session_id = "cccccccccccccccccccccccccccccccc";
        let spawner = Arc::new(FakeSpawner::new(vec![
            detach_script(session_id),
            reattach_response_script(
                session_id,
                Message::Reject {
                    code: winsmux_remote_helper::RejectCode::SessionNotFound,
                    detail: "sensitive-broker-detail".to_string(),
                },
            ),
        ]));
        let manager = RemoteSessionManager::with_spawner(spawner.clone());
        manager
            .start("gpu-host".to_string(), RemoteAgent::Codex, 120, 40)
            .expect("start should attach");
        manager
            .detach("gpu-host", session_id)
            .expect("detach should retain tuple");

        let error = manager
            .reattach("gpu-host", session_id)
            .expect_err("SessionNotFound must remove tuple");

        assert!(!error.contains("sensitive"));
        assert!(manager.snapshots().is_empty());
        let logs = spawner.logs();
        assert!(logs[1].reaped.load(Ordering::SeqCst));
    }
}
