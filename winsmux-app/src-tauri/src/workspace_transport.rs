//! Coordinated ownership and completion for the private workspace transport.
use sha2::{Digest, Sha256};
use std::sync::{Arc, Condvar, Mutex};
use tauri::{ipc, Emitter, Manager, WebviewWindow};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
use crate::workspace_input_guard::{GuardFence, GuardStatus, GuardWake};
use winsmux_workspace::{
    contract::{Action, Empty, Nullable, OperationId, Request, Response},
    host::{WorkspaceOwner, WorkspaceRequestError},
};
include!(concat!(env!("OUT_DIR"), "/workspace_companion_hash.rs"));

#[derive(serde::Serialize)]
pub struct WorkspaceSession {
    instance_id: String,
    schema_version: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceDiscovery {
    instance_id: String,
    pipe_name: String,
    schema_version: u64,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryCopyRequest {
    owner_generation: String,
    discovery: WorkspaceDiscovery,
}
#[derive(serde::Serialize)]
pub struct DiscoveryCopyReceipt {
    owner_generation: String,
    discovery: WorkspaceDiscovery,
}
#[derive(Debug, PartialEq, Eq, serde::Serialize)]
pub struct WorkspaceHostStatus {
    instance_id: Option<String>,
    generation: String,
    revision: String,
    phase: &'static str,
}
struct Session {
    owner: WorkspaceOwner,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Empty,
    Opening,
    Ready,
    Busy,
    Stopping,
    Unknown,
    ForcePrompt,
    Finishing,
    FailedClosed,
    MainClosed,
    ExitReleased,
}
#[derive(Clone)]
enum Intent {
    SessionOnly,
    CloseMain,
    ExitApp(Option<i32>),
    Update(crate::PreparedDesktopUpdate),
    ForceExit,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum IoKind {
    Opening,
    Ordinary,
    Stop,
    Force,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Outcome {
    Known,
    StartupFailed,
    Collected,
    Refused(String),
    PrewireProtocol,
    Unknown,
}
// Only the producer owns IO. Consumers hold this immutable result, never an owner lease.
struct Flight {
    id: u64,
    generation: u64,
    kind: IoKind,
    operation_id: Option<OperationId>,
    terminal: Mutex<Option<Outcome>>,
}
struct CompletionReservation {
    id: u64,
    terminal: Mutex<Option<Result<(), String>>>,
}
struct Completion {
    ticket: Arc<CompletionReservation>,
    intent: Intent,
    dependency: Option<Arc<Flight>>,
    worker: bool,
    abandoned: bool,
    stopped: bool,
    helper_started: bool,
    input_key: Option<InputKey>,
}
struct Lifecycle {
    phase: Phase,
    generation: u64,
    sequence: u64,
    last_reservation: u64,
    session: Option<Session>,
    discovery: Option<winsmux_workspace::host::Discovery>,
    flight: Option<Arc<Flight>>,
    completion: Option<Completion>,
    cleanup_done: bool,
    main_close_released: bool,
    confirmed_exit_code: Option<i32>,
    input_lease: Option<u64>,
    input_binding: Option<String>,
    input_fence: Option<InputFence>,
}
impl Default for Lifecycle {
    fn default() -> Self {
        Self {
            phase: Phase::Empty,
            generation: 0,
            sequence: 0,
            last_reservation: 0,
            session: None,
            discovery: None,
            flight: None,
            completion: None,
            cleanup_done: false,
            main_close_released: false,
            confirmed_exit_code: None,
            input_lease: None,
            input_binding: None,
            input_fence: None,
        }
    }
}
enum Advance {
    AwaitInput(InputKey),
    Await(Arc<Flight>),
    StartStop {
        flight: Arc<Flight>,
        session: Session,
        request: Request,
    },
    Stopped,
    Terminal(Result<(), String>),
}
enum Admission {
    Await(Arc<Flight>),
    Start {
        flight: Arc<Flight>,
        session: Session,
        request: Request,
    },
}
enum OpenAdmission {
    Await(Arc<Flight>),
    Start(Arc<Flight>),
    Existing(WorkspaceSession),
}
impl Lifecycle {
    fn host_status(&self) -> WorkspaceHostStatus {
        let phase = match self.phase {
            Phase::Empty => "Empty", Phase::Opening => "Opening", Phase::Ready => "Ready",
            Phase::Busy => "Busy", Phase::Stopping => "Stopping", Phase::Unknown => "Unknown",
            Phase::ForcePrompt => "ForcePrompt", Phase::Finishing => "Finishing",
            Phase::FailedClosed => "FailedClosed", Phase::MainClosed => "MainClosed",
            Phase::ExitReleased => "ExitReleased",
        };
        WorkspaceHostStatus {
            instance_id: self.discovery.as_ref().map(|d| d.instance_id().as_str().to_owned()),
            generation: self.generation.to_string(),
            revision: self.sequence.to_string(), phase,
        }
    }
    fn next_id(&mut self) -> u64 {
        self.sequence = self
            .sequence
            .checked_add(1)
            .expect("workspace identity exhausted");
        self.sequence
    }
    fn new_flight(&mut self, kind: IoKind, operation_id: Option<OperationId>) -> Arc<Flight> {
        let flight = Arc::new(Flight {
            id: self.next_id(),
            generation: self.generation,
            kind,
            operation_id,
            terminal: Mutex::new(None),
        });
        self.flight = Some(flight.clone());
        self.phase = match kind {
            IoKind::Opening => Phase::Opening,
            IoKind::Ordinary => Phase::Busy,
            _ => Phase::Stopping,
        };
        flight
    }
    fn new_completion(
        &mut self,
        intent: Intent,
        worker: bool,
        stopped: bool,
    ) -> Arc<CompletionReservation> {
        let ticket = Arc::new(CompletionReservation {
            id: self.next_id(),
            terminal: Mutex::new(None),
        });
        let input_key = self.bind_input_fence(ticket.id, &intent);
        self.last_reservation = ticket.id;
        self.completion = Some(Completion {
            ticket: ticket.clone(),
            intent,
            dependency: self.flight.clone(),
            worker,
            abandoned: false,
            stopped,
            helper_started: false,
            input_key,
        });
        ticket
    }
    fn current(&self, ticket: &CompletionReservation) -> bool {
        self.completion
            .as_ref()
            .is_some_and(|c| c.ticket.id == ticket.id)
    }
    fn seal_ticket(ticket: &CompletionReservation, result: Result<(), String>) {
        let mut terminal = ticket.terminal.lock().unwrap_or_else(|e| e.into_inner());
        if terminal.is_none() {
            *terminal = Some(result);
        }
    }
    fn admission(&self) -> Result<(), &'static str> {
        if matches!(self.phase, Phase::Unknown | Phase::ForcePrompt) {
            return Err("transport_uncertain");
        }
        if self.phase == Phase::FailedClosed {
            return Err("shutdown_failed");
        }
        if self.completion.is_some()
            || matches!(
                self.phase,
                Phase::Finishing | Phase::MainClosed | Phase::ExitReleased | Phase::Stopping
            )
        {
            return Err("shutdown_in_progress");
        }
        Ok(())
    }
    fn cancel_attached(&mut self, flight: &Flight, error: &str, known: bool) {
        if self
            .completion
            .as_ref()
            .is_some_and(|c| c.dependency.as_ref().is_some_and(|f| f.id == flight.id))
        {
            let completion = self.completion.take().expect("attached completion");
            if known { self.permit_input_resume(&completion); }
            Self::seal_ticket(&completion.ticket, Err(error.to_owned()));
        }
    }
    // State -> terminal is the only lock order. Result waiters use the coordinator condvar.
    // Returns a stale producer's owner for destruction outside the state lock.
    fn publish(
        &mut self,
        flight: &Arc<Flight>,
        session: Option<Session>,
        outcome: Outcome,
    ) -> Option<Session> {
        if !self
            .flight
            .as_ref()
            .is_some_and(|f| f.id == flight.id && f.generation == flight.generation)
        {
            return session;
        }
        self.next_id();
        let abandoned = self.completion.as_ref().is_some_and(|c| {
            c.abandoned && c.dependency.as_ref().is_some_and(|f| f.id == flight.id)
        });
        self.session = session;
        if let Some(session) = &self.session {
            self.discovery = Some(session.owner.discovery().clone());
        }
        if matches!(outcome, Outcome::Collected | Outcome::StartupFailed) {
            self.discovery = None;
        }
        self.flight = None;
        match &outcome {
            Outcome::Collected => {
                if let Some(c) = self.completion.as_mut() {
                    c.stopped = true;
                    if abandoned {
                        c.worker = false;
                        self.phase = Phase::FailedClosed;
                    } else if matches!(c.intent, Intent::SessionOnly) {
                        Self::seal_ticket(&c.ticket, Ok(()));
                        self.completion = None;
                        self.phase = Phase::Empty;
                    } else {
                        self.phase = Phase::Finishing;
                    }
                } else {
                    self.phase = Phase::Empty;
                }
            }
            Outcome::Unknown => {
                self.cancel_attached(flight, "transport_uncertain", false);
                self.phase = Phase::Unknown;
            }
            Outcome::Refused(error) => {
                self.cancel_attached(flight, error, true);
                self.phase = if abandoned {
                    Phase::Unknown
                } else {
                    Phase::Ready
                };
            }
            Outcome::PrewireProtocol => {
                self.cancel_attached(flight, "protocol_failed", true);
                self.phase = if abandoned {
                    Phase::Unknown
                } else {
                    Phase::Ready
                };
            }
            Outcome::Known | Outcome::StartupFailed => {
                if abandoned {
                    self.phase = if self.session.is_some() {
                        Phase::Unknown
                    } else {
                        Phase::FailedClosed
                    };
                } else {
                    self.phase = if self.session.is_some() {
                        Phase::Ready
                    } else {
                        Phase::Empty
                    };
                }
            }
        }
        *flight.terminal.lock().unwrap_or_else(|e| e.into_inner()) = Some(outcome);
        None
    }
    fn reserve(
        &mut self,
        incoming: Intent,
    ) -> Result<(Arc<CompletionReservation>, bool), &'static str> {
        if matches!(self.phase, Phase::Unknown | Phase::ForcePrompt) {
            return Err("transport_uncertain");
        }
        if self.completion.as_ref().is_some_and(|c| c.abandoned) && self.flight.is_some() {
            return Err("transport_uncertain");
        }
        if self.phase == Phase::FailedClosed {
            match (self.completion.as_ref(), &incoming) {
                (_, Intent::ExitApp(_) | Intent::CloseMain) => {}
                (Some(c), Intent::Update(new))
                    if matches!(&c.intent,Intent::Update(old) if old.same_prepared(new))
                        && !c.helper_started => {}
                _ => return Err("shutdown_conflict"),
            }
            let ticket = self.new_completion(incoming, true, true);
            self.phase = Phase::Finishing;
            return Ok((ticket, true));
        }
        if self.phase == Phase::MainClosed {
            if let Some(c) = self.completion.as_ref() {
                if matches!(incoming, Intent::CloseMain) {
                    return Ok((c.ticket.clone(), false));
                }
            }
            let ticket = self.new_completion(incoming, true, true);
            self.phase = Phase::Finishing;
            return Ok((ticket, true));
        }
        let promotion_fence = self.completion.as_ref().and_then(|c| {
            (c.input_key.is_none() && matches!((&c.intent, &incoming), (Intent::SessionOnly, Intent::CloseMain | Intent::ExitApp(_))))
                .then_some((c.ticket.id, incoming.clone()))
        });
        if let Some(c) = self.completion.as_mut() {
            let same = matches!(
                (&c.intent, &incoming),
                (Intent::CloseMain, Intent::CloseMain) | (Intent::ForceExit, Intent::ForceExit)
            ) || matches!((&c.intent,&incoming),(Intent::ExitApp(a),Intent::ExitApp(b)) if a==b)
                || matches!((&c.intent,&incoming),(Intent::Update(a),Intent::Update(b)) if a.same_prepared(b));
            let promotes = matches!(
                (&c.intent, &incoming),
                (Intent::SessionOnly, Intent::CloseMain | Intent::ExitApp(_))
                    | (Intent::CloseMain, Intent::ExitApp(_))
            );
            if promotes {
                c.intent = incoming;
            } else if !same {
                return Err("shutdown_conflict");
            }
            if self.phase == Phase::ExitReleased {
                return Ok((c.ticket.clone(), false));
            }
            let start = !c.worker;
            c.worker = true;
            let ticket = c.ticket.clone();
            if let Some((id, purpose)) = promotion_fence {
                let key = self.bind_input_fence(id, &purpose);
                self.completion.as_mut().expect("accepted promotion").input_key = key;
                self.next_id();
            }
            return Ok((ticket, start));
        }
        let ticket = self.new_completion(incoming, true, false);
        Ok((ticket, true))
    }
    fn stop_request(session: &Session) -> Request {
        Request {
            schema_version: winsmux_workspace::contract::Version::new(1).expect("v1"),
            instance_id: Nullable(Some(session.owner.discovery().instance_id().clone())),
            operation_id: OperationId::new(uuid::Uuid::new_v4().to_string()).expect("UUID"),
            expected_topology_revision: Nullable(None),
            action: Action::HostStop(Empty {}),
        }
    }
    fn admit_stop(&mut self, request: Option<Request>) -> Result<Admission, &'static str> {
        self.admission()?;
        if let Some(f) = &self.flight {
            return Ok(Admission::Await(f.clone()));
        }
        let session = self.session.take().ok_or("session_closed")?;
        let request = request.unwrap_or_else(|| Self::stop_request(&session));
        let flight = self.new_flight(IoKind::Stop, Some(request.operation_id.clone()));
        self.new_completion(Intent::SessionOnly, false, false);
        Ok(Admission::Start {
            flight,
            session,
            request,
        })
    }
    fn admit_open(&mut self) -> Result<OpenAdmission, &'static str> {
        self.admission()?;
        if let Some(f) = &self.flight {
            return Ok(OpenAdmission::Await(f.clone()));
        }
        if self.phase == Phase::Empty {
            self.generation = self
                .generation
                .checked_add(1)
                .expect("owner generation exhausted");
            // A new owner also invalidates projections from the preceding closed attempt.
            self.last_reservation = self.next_id();
            return Ok(OpenAdmission::Start(self.new_flight(IoKind::Opening, None)));
        }
        let discovery = self
            .session
            .as_ref()
            .ok_or("session_closed")?
            .owner
            .discovery();
        Ok(OpenAdmission::Existing(WorkspaceSession {
            instance_id: discovery.instance_id().as_str().to_owned(),
            schema_version: discovery.schema_version().get(),
        }))
    }
    fn advance(&mut self, ticket: &Arc<CompletionReservation>) -> Advance {
        if let Some(result) = ticket
            .terminal
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
        {
            return Advance::Terminal(result);
        }
        if !self.current(ticket) {
            return Advance::Terminal(Err("shutdown_failed".into()));
        }
        let c = self.completion.as_ref().expect("current completion");
        if c.abandoned {
            return Advance::Terminal(Err("transport_uncertain".into()));
        }
        if let Some(key) = c.input_key {
            match self.input_fence {
                Some(fence) if fence.key == key && self.input_lease == Some(key.lease) => {
                    match fence.state {
                        InputState::Pending => return Advance::AwaitInput(key),
                        InputState::Approved => {},
                        InputState::Released => return Advance::Terminal(Err("input_guard_stale".into())),
                    }
                },
                _ => return Advance::Terminal(Err("input_guard_stale".into())),
            }
        }
        if c.stopped {
            return Advance::Stopped;
        }
        if let Some(dependency) = &c.dependency {
            let terminal = dependency
                .terminal
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            match terminal {
                None => return Advance::Await(dependency.clone()),
                Some(Outcome::Known | Outcome::StartupFailed)
                    if matches!(dependency.kind, IoKind::Opening | IoKind::Ordinary) => {}
                Some(Outcome::Collected) => return Advance::Stopped,
                Some(Outcome::Refused(error)) => return Advance::Terminal(Err(error)),
                Some(Outcome::PrewireProtocol) => {
                    return Advance::Terminal(Err("protocol_failed".into()))
                }
                _ => return Advance::Terminal(Err("transport_uncertain".into())),
            }
        }
        if let Some(f) = &self.flight {
            return Advance::Await(f.clone());
        }
        let Some(session) = self.session.take() else {
            self.next_id();
            let c = self.completion.as_mut().expect("current");
            c.stopped = true;
            self.phase = Phase::Finishing;
            return Advance::Stopped;
        };
        let request = Self::stop_request(&session);
        let flight = self.new_flight(IoKind::Stop, Some(request.operation_id.clone()));
        self.completion.as_mut().expect("current").dependency = Some(flight.clone());
        Advance::StartStop {
            flight,
            session,
            request,
        }
    }
    fn abandon(&mut self, ticket: &CompletionReservation) {
        if !self.current(ticket) {
            return;
        }
        self.next_id();
        let c = self.completion.as_mut().expect("current");
        c.worker = false;
        c.abandoned = true;
        Self::seal_ticket(ticket, Err("transport_uncertain".into()));
        if self.flight.is_none() {
            self.phase = if self.session.is_some() {
                Phase::Unknown
            } else {
                Phase::FailedClosed
            };
        }
    }
    fn failed_effect(&mut self, ticket: &CompletionReservation, known_unstarted: bool) {
        if !self.current(ticket) {
            return;
        }
        self.next_id();
        let c = self.completion.as_mut().expect("current");
        c.worker = false;
        if known_unstarted {
            c.helper_started = false;
        }
        Self::seal_ticket(ticket, Err("shutdown_failed".into()));
        self.phase = Phase::FailedClosed;
    }
    fn effect_intent(&mut self, ticket: &CompletionReservation) -> Result<Intent, &'static str> {
        if !self.current(ticket) {
            return Err("shutdown_failed");
        }
        let c = self.completion.as_ref().expect("current");
        if c.abandoned || !c.stopped || self.phase != Phase::Finishing || !self.input_gate_allows_effect(c) {
            return Err("shutdown_failed");
        }
        let intent = c.intent.clone();
        if matches!(intent, Intent::CloseMain) {
            self.next_id();
            self.main_close_released = true;
            self.phase = Phase::MainClosed;
        }
        Ok(intent)
    }
    fn cleanup_permit(&mut self, ticket: &CompletionReservation) -> Result<bool, &'static str> {
        if !self.current(ticket) || self.phase != Phase::Finishing {
            return Err("shutdown_failed");
        }
        let c = self.completion.as_ref().expect("current");
        if !c.stopped || c.abandoned || !self.input_gate_allows_effect(c) {
            return Err("shutdown_failed");
        }
        let needed = !self.cleanup_done;
        self.cleanup_done = true;
        Ok(needed)
    }
    fn helper_permit(&mut self, ticket: &CompletionReservation) -> Result<(), &'static str> {
        if !self.current(ticket) || !self.cleanup_done || self.phase != Phase::Finishing {
            return Err("shutdown_failed");
        }
        if !self.input_gate_allows_effect(self.completion.as_ref().expect("current")) { return Err("shutdown_failed"); }
        let c = self.completion.as_mut().expect("current");
        if c.abandoned || !c.stopped || c.helper_started || !matches!(c.intent, Intent::Update(_)) {
            return Err("shutdown_failed");
        }
        c.helper_started = true;
        Ok(())
    }
    fn release_effect(
        &mut self,
        ticket: &CompletionReservation,
        exit: bool,
    ) -> Result<(), &'static str> {
        if !self.current(ticket) {
            return Err("shutdown_failed");
        }
        if !self.input_gate_allows_effect(self.completion.as_ref().expect("current")) { return Err("shutdown_failed"); }
        let c = self.completion.as_mut().expect("current");
        if !c.stopped || c.abandoned {
            return Err("shutdown_failed");
        }
        c.worker = false;
        if exit {
            self.phase = Phase::ExitReleased;
        }
        Self::seal_ticket(ticket, Ok(()));
        self.next_id();
        Ok(())
    }
    fn begin_force(&mut self) -> Result<Arc<CompletionReservation>, &'static str> {
        if self.phase != Phase::Unknown || self.flight.is_some() {
            return Err("force_exit_unavailable");
        }
        let ticket = self.new_completion(Intent::ForceExit, false, false);
        self.phase = Phase::ForcePrompt;
        Ok(ticket)
    }
    fn cancel_force(&mut self, ticket: &CompletionReservation) {
        if self.current(ticket) && self.phase == Phase::ForcePrompt {
            self.next_id();
            self.completion = None;
            self.phase = Phase::Unknown;
            Self::seal_ticket(ticket, Err("force_exit_cancelled".into()));
        }
    }
    fn force_permit(
        &mut self,
        ticket: &CompletionReservation,
    ) -> Result<(Arc<Flight>, Session), &'static str> {
        if !self.current(ticket) || self.phase != Phase::ForcePrompt {
            return Err("transport_uncertain");
        }
        let session = self.session.take().ok_or("transport_uncertain")?;
        let flight = self.new_flight(IoKind::Force, None);
        let c = self.completion.as_mut().expect("current");
        c.dependency = Some(flight.clone());
        c.worker = true;
        Ok((flight, session))
    }
    fn record_actual_exit(&mut self) {
        let Some(c) = self.completion.as_ref() else {
            return;
        };
        if self.phase != Phase::ExitReleased
            || self.session.is_some()
            || self.discovery.is_some()
            || !self.cleanup_done
            || c.worker
            || c.abandoned
            || !c.stopped
        {
            return;
        }
        let code = match c.intent {
            Intent::ExitApp(code) => code.unwrap_or(0),
            Intent::Update(_) | Intent::ForceExit => 0,
            _ => return,
        };
        if code != tauri::RESTART_EXIT_CODE && self.confirmed_exit_code.is_none() {
            self.confirmed_exit_code = Some(code);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct InputKey { ticket: u64, lease: u64 }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum InputState { Pending, Approved, Released }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct InputFence { key: InputKey, state: InputState }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct InputProjection { lease: u64, revision: u64, fence: Option<InputFence>, resume_allowed: bool }

impl Lifecycle {
    fn register_input(&mut self, binding: &str) -> Result<u64, &'static str> {
        self.admission()?;
        if let Some(lease) = self.input_lease {
            return if self.input_binding.as_deref() == Some(binding) { Ok(lease) } else { Err("input_guard_owned") };
        }
        let lease = self.next_id();
        self.input_lease = Some(lease);
        self.input_binding = Some(binding.to_owned());
        Ok(lease)
    }
    fn bind_input_fence(&mut self, ticket: u64, intent: &Intent) -> Option<InputKey> {
        if matches!(intent, Intent::SessionOnly | Intent::ForceExit) { return None; }
        let lease = self.input_lease?;
        // Only an existing approved fence can be inherited by a new Completion.
        // MainClosed/recovery must not need a second reply from a destroyed root.
        if let Some(fence) = self.input_fence {
            if fence.key.lease == lease && fence.state == InputState::Approved { return Some(fence.key); }
        }
        let key = InputKey { ticket, lease };
        self.input_fence = Some(InputFence { key, state: InputState::Pending });
        Some(key)
    }
    fn input_gate_allows_effect(&self, c: &Completion) -> bool {
        match c.input_key {
            None => true,
            Some(key) => self.input_lease == Some(key.lease)
                && self.input_fence == Some(InputFence { key, state: InputState::Approved }),
        }
    }
    fn input_key_is_pending(&self, key: InputKey) -> bool {
        self.input_lease == Some(key.lease)
            && self.input_fence == Some(InputFence { key, state: InputState::Pending })
            && self.completion.as_ref().is_some_and(|c| c.input_key == Some(key) && !c.abandoned)
            && !matches!(self.phase, Phase::Unknown | Phase::ForcePrompt | Phase::FailedClosed)
    }
    fn input_reply(&mut self, key: InputKey, safe: bool) -> Result<(), &'static str> {
        if !self.input_key_is_pending(key) { return Err("input_guard_stale"); }
        if safe {
            self.input_fence = Some(InputFence { key, state: InputState::Approved });
        } else {
            let c = self.completion.take().expect("current fenced completion");
            Self::seal_ticket(&c.ticket, Err("input_pending".into()));
            self.permit_input_resume(&c);
            if self.flight.is_none() { self.phase = if self.session.is_some() { Phase::Ready } else { Phase::Empty }; }
        }
        self.next_id(); // existing identity sequence also orders private projections
        Ok(())
    }
    fn permit_input_resume(&mut self, c: &Completion) {
        // An unrelated native reservation or stale producer cannot own release.
        let Some(key) = c.input_key else { return; };
        if !c.abandoned && self.input_lease == Some(key.lease)
            && self.input_fence.is_some_and(|f| f.key == key) {
            self.input_fence = Some(InputFence { key, state: InputState::Released });
        }
    }
    fn input_resume_key(&self) -> Option<InputKey> {
        let fence = self.input_fence?;
        // Unknown/abandon/failed effect is still independently fail-closed.
        // SessionOnly/new owner may temporarily deny admission but never erase proof.
        (fence.state == InputState::Released && self.input_lease == Some(fence.key.lease)
            && self.admission().is_ok()).then_some(fence.key)
    }
    fn input_projection(&self, lease: u64) -> Result<InputProjection, &'static str> {
        if self.input_lease != Some(lease) { return Err("input_guard_owned"); }
        Ok(InputProjection { lease, revision:self.sequence, fence:self.input_fence,
            resume_allowed:self.input_resume_key().is_some() })
    }
}

#[derive(Default)]
pub struct WorkspaceManager {
    state: Mutex<Lifecycle>,
    changed: Condvar,
    input_notifier: Mutex<Option<Arc<InputNotifier>>>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    stop_reply_loss_gate: Option<Arc<winsmux_workspace::host::StopReplyLossGate>>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    native_checkpoint: Option<Arc<dyn Fn(NativeLifecyclePoint) + Send + Sync>>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    native_responses: Mutex<Vec<serde_json::Value>>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    native_consumers: Mutex<Vec<serde_json::Value>>,
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    native_companion_sha256: Option<String>,
}
type InputNotifier = dyn Fn(GuardWake, Option<InputKey>) -> Result<(), ()> + Send + Sync;
#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeLifecyclePoint {
    Opening,
    Busy,
    Stopping,
    Finishing,
    CleanupComplete,
    BeforeHelper,
    HelperStarted,
    Response,
    ConsumerTerminal,
}
struct OwnerLease {
    manager: Arc<WorkspaceManager>,
    flight: Arc<Flight>,
    session: Option<Session>,
    armed: bool,
}
impl OwnerLease {
    fn publish(mut self, outcome: Outcome) {
        if outcome == Outcome::Collected {
            drop(self.session.take());
        }
        let rejected = {
            let mut state = self.manager.state.lock().unwrap_or_else(|e| e.into_inner());
            state.publish(&self.flight, self.session.take(), outcome)
        };
        self.armed = false;
        self.manager.notify_changed();
        drop(rejected);
    }
}
impl Drop for OwnerLease {
    fn drop(&mut self) {
        if self.armed {
            let rejected = {
                let mut state = self.manager.state.lock().unwrap_or_else(|e| e.into_inner());
                state.publish(&self.flight, self.session.take(), Outcome::Unknown)
            };
            self.manager.notify_changed();
            drop(rejected);
        }
    }
}
struct OpeningLease {
    manager: Arc<WorkspaceManager>,
    flight: Arc<Flight>,
    completed: bool,
}
impl Drop for OpeningLease {
    fn drop(&mut self) {
        if !self.completed {
            let mut state = self.manager.state.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(c) = state.completion.as_mut() {
                if c.dependency
                    .as_ref()
                    .is_some_and(|f| f.id == self.flight.id)
                {
                    c.abandoned = true;
                    c.worker = false;
                }
            }
            state.publish(&self.flight, None, Outcome::StartupFailed);
            drop(state);
            self.manager.notify_changed();
        }
    }
}
impl WorkspaceManager {
    pub(crate) fn host_status(&self) -> Result<WorkspaceHostStatus, &'static str> {
        let state = self.state.lock().map_err(|_| "transport_uncertain")?;
        Ok(state.host_status())
    }
    fn guard_status(state: &Lifecycle, lease: u64) -> Result<GuardStatus, &'static str> {
        let projection = state.input_projection(lease)?;
        Ok(GuardStatus {
            lease: projection.lease.to_string(),
            revision: projection.revision.to_string(),
            fence: projection.fence.map(|f| GuardFence {
                nonce: f.key.ticket.to_string(),
                state: match f.state {
                    InputState::Pending => "pending",
                    InputState::Approved => "approved",
                    InputState::Released => "released",
                },
            }),
            resume_allowed: projection.resume_allowed,
            admission_error: state.admission().err().map(str::to_owned),
        })
    }
    pub(crate) fn input_guard_status(&self, lease: u64) -> Result<GuardStatus, &'static str> {
        let state = self.state.lock().map_err(|_| "transport_uncertain")?;
        Self::guard_status(&state, lease)
    }
    pub(crate) fn register_input_guard(
        self: &Arc<Self>, binding: &str, app: &tauri::AppHandle,
    ) -> Result<GuardStatus, &'static str> {
        let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
        let lease = state.register_input(binding)?;
        let mut notifier = self.input_notifier.lock().map_err(|_| "transport_uncertain")?;
        if notifier.is_none() {
            let app = app.clone();
            let manager = Arc::downgrade(self);
            *notifier = Some(Arc::new(move |wake, key| {
                let emitter = app.clone();
                let manager = manager.clone();
                app.run_on_main_thread(move || {
                    let sent = emitter.get_webview_window("main")
                        .ok_or(())
                        .and_then(|window| window.emit("workspace-input-guard-changed", wake).map_err(|_| ()));
                    if sent.is_err() {
                        if let (Some(manager), Some(key)) = (manager.upgrade(), key) {
                            manager.reject_input_notification(key);
                        }
                    }
                }).map_err(|_| ())
            }));
        }
        Self::guard_status(&state, lease)
    }
    pub(crate) fn reply_input_guard(
        &self, lease: u64, nonce: u64, safe: bool,
    ) -> Result<GuardStatus, &'static str> {
        let status = {
            let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
            state.input_reply(InputKey { ticket: nonce, lease }, safe)?;
            Self::guard_status(&state, lease)?
        };
        self.notify_changed();
        Ok(status)
    }
    fn reject_input_notification(&self, key: InputKey) {
        let changed = self.state.lock().map(|mut state| state.input_reply(key, false).is_ok()).unwrap_or(false);
        if changed { self.notify_changed(); }
    }
    fn input_wake(&self, pending: Option<InputKey>) -> Result<(), ()> {
        let wake = {
            let state = self.state.lock().map_err(|_| ())?;
            let Some(lease) = state.input_lease else { return Ok(()) };
            if let Some(key) = pending {
                if !state.input_key_is_pending(key) { return Ok(()) }
            } else if state.input_fence.is_some_and(|f| f.state == InputState::Pending) {
                // Only the current completion worker announces a Pending challenge.
                return Ok(());
            }
            GuardWake { lease:lease.to_string(), revision:state.sequence.to_string() }
        };
        let notifier = self.input_notifier.lock().map_err(|_| ())?.clone().ok_or(())?;
        notifier(wake, pending)
    }
    fn notify_changed(&self) {
        self.changed.notify_all();
        // All UI delivery is outside the Lifecycle mutex; payload contains no input.
        let _ = self.input_wake(None);
    }
    fn wait_input(&self, ticket: &CompletionReservation, key: InputKey) -> Result<(), &'static str> {
        let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
        while state.current(ticket) && state.input_key_is_pending(key) {
            state = self.changed.wait(state).map_err(|_| "transport_uncertain")?;
        }
        Ok(())
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    pub fn for_stop_reply_loss(gate: Arc<winsmux_workspace::host::StopReplyLossGate>) -> Self {
        Self {
            stop_reply_loss_gate: Some(gate),
            ..Self::default()
        }
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    pub fn for_native_lifecycle(
        checkpoint: Arc<dyn Fn(NativeLifecyclePoint) + Send + Sync>,
        gate: Option<Arc<winsmux_workspace::host::StopReplyLossGate>>,
    ) -> Self {
        Self {
            native_checkpoint: Some(checkpoint),
            stop_reply_loss_gate: gate,
            ..Self::default()
        }
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    pub fn with_native_companion_sha256(mut self, digest: String) -> Self {
        assert!(digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit()));
        self.native_companion_sha256 = Some(digest);
        self
    }
    fn expected_companion_sha256(&self) -> &str {
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        if let Some(digest) = self.native_companion_sha256.as_deref() {
            return digest;
        }
        WORKSPACE_COMPANION_SHA256
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    fn checkpoint(&self, point: NativeLifecyclePoint) {
        if let Some(checkpoint) = &self.native_checkpoint {
            checkpoint(point);
        }
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    pub fn native_lifecycle_snapshot(&self) -> serde_json::Value {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        serde_json::json!({"phase":format!("{:?}",state.phase),"generation":state.generation,
            "attempt":state.flight.as_ref().map(|f|f.id),"reservation":state.completion.as_ref().map(|c|c.ticket.id),
            "pending":state.completion.is_some(),"worker":state.completion.as_ref().is_some_and(|c|c.worker),
            "cleanup_done":state.cleanup_done,"helper_started_or_uncertain":state.completion.as_ref().is_some_and(|c|c.helper_started),
            "responses":self.native_responses.lock().unwrap_or_else(|e|e.into_inner()).clone(),
            "consumers":self.native_consumers.lock().unwrap_or_else(|e|e.into_inner()).clone()})
    }
    fn record_actual_exit(&self) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .record_actual_exit();
    }
    #[cfg(windows)]
    pub(crate) fn confirmed_exit_code(&self) -> Option<i32> {
        self.state.lock().ok().and_then(|s| s.confirmed_exit_code)
    }
    pub fn discovery(&self) -> Option<winsmux_workspace::host::Discovery> {
        self.state.lock().ok()?.discovery.clone()
    }
    fn discovery_for_gui(&self) -> Result<WorkspaceDiscovery, &'static str> {
        let state = self.state.lock().map_err(|_| "transport_uncertain")?;
        Self::live_discovery(&state)
    }
    fn live_discovery(state: &Lifecycle) -> Result<WorkspaceDiscovery, &'static str> {
        state.admission()?;
        if state.phase != Phase::Ready || state.flight.is_some() || state.completion.is_some() {
            return Err("session_closed");
        }
        let live = state.session.as_ref().ok_or("session_closed")?.owner.discovery();
        if state.discovery.as_ref() != Some(live) {
            return Err("transport_uncertain");
        }
        Ok(WorkspaceDiscovery {
            instance_id: live.instance_id().as_str().to_owned(),
            pipe_name: live.pipe_name().to_owned(),
            schema_version: live.schema_version().get(),
        })
    }
    // Validation and the non-waiting owner reservation share one lifecycle lock.
    // This is the copy acceptance point; a later close waits for this ordinary flight.
    fn discovery_copy_lease(self: &Arc<Self>, expected: &DiscoveryCopyRequest)
        -> Result<(OwnerLease, DiscoveryCopyReceipt), &'static str>
    {
        let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
        let live = Self::live_discovery(&state)?;
        validate_discovery_copy(state.generation, &live, expected)?;
        let session = state.session.take().ok_or("session_closed")?;
        let flight = state.new_flight(IoKind::Ordinary, None);
        let receipt = DiscoveryCopyReceipt { owner_generation: state.generation.to_string(), discovery: live };
        Ok((OwnerLease { manager: self.clone(), flight, session: Some(session), armed: true }, receipt))
    }
    pub fn has_session(&self) -> bool {
        self.state
            .lock()
            .map(|s| s.session.is_some() || s.flight.is_some() || s.phase == Phase::ForcePrompt)
            .unwrap_or(true)
    }
    pub(crate) fn is_unknown(&self) -> bool {
        self.state.lock().is_ok_and(|s| s.phase == Phase::Unknown)
    }
    fn wait_flight(&self, flight: &Flight) -> Result<(), &'static str> {
        let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
        while flight
            .terminal
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_none()
        {
            state = self
                .changed
                .wait(state)
                .map_err(|_| "transport_uncertain")?;
        }
        Ok(())
    }
    fn start_owner(&self) -> Result<Session, &'static str> {
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        self.checkpoint(NativeLifecyclePoint::Opening);
        let executable = crate::desktop_backend::resolve_companion_winsmux_cli()
            .ok_or("companion_unavailable")?;
        verify_companion(&executable, self.expected_companion_sha256())?;
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        let owner = match self.stop_reply_loss_gate.as_ref() {
            Some(g) => WorkspaceOwner::start_with_stop_reply_loss_gate(&executable, g),
            None => WorkspaceOwner::start(&executable),
        }
        .map_err(|e| e.classification())?;
        #[cfg(not(all(windows, debug_assertions, feature = "native-e2e-faults")))]
        let owner = WorkspaceOwner::start(&executable).map_err(|e| e.classification())?;
        if let Err(error) = verify_companion(&executable, self.expected_companion_sha256()) {
            drop(owner);
            return Err(error);
        }
        Ok(Session { owner })
    }
    fn ordinary_lease(self: &Arc<Self>) -> Result<OwnerLease, &'static str> {
        let mut state = self.state.lock().map_err(|_| "transport_uncertain")?;
        loop {
            state.admission()?;
            if let Some(flight) = state.flight.clone() {
                drop(state);
                self.wait_flight(&flight)?;
                state = self.state.lock().map_err(|_| "transport_uncertain")?;
            } else {
                break;
            }
        }
        let session = state.session.take().ok_or("session_closed")?;
        let flight = state.new_flight(IoKind::Ordinary, None);
        Ok(OwnerLease {
            manager: self.clone(),
            flight,
            session: Some(session),
            armed: true,
        })
    }
    fn execute(&self, mut lease: OwnerLease, request: &Request) -> Result<Response, &'static str> {
        let stop = lease.flight.kind == IoKind::Stop;
        if stop && lease.flight.operation_id.as_ref() != Some(&request.operation_id) {
            lease.publish(Outcome::PrewireProtocol);
            return Err("protocol_failed");
        }
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        self.checkpoint(if stop {
            NativeLifecyclePoint::Stopping
        } else {
            NativeLifecyclePoint::Busy
        });
        let session = lease.session.as_mut().expect("owner IO permit");
        let response = match session.owner.request(request) {
            Ok(response) => response,
            Err(WorkspaceRequestError::ProtocolFailed) => {
                lease.publish(if stop {
                    Outcome::PrewireProtocol
                } else {
                    Outcome::Known
                });
                return Err("protocol_failed");
            }
            Err(WorkspaceRequestError::TransportUncertain) => {
                lease.publish(Outcome::Unknown);
                return Err("transport_uncertain");
            }
        };
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        if self.native_checkpoint.is_some() {
            self.native_responses.lock().unwrap_or_else(|e|e.into_inner()).push(serde_json::json!({"request":request,"response":response,
                "owner_instance":session.owner.discovery().instance_id(),"generation":lease.flight.generation,"attempt":lease.flight.id}));
            self.checkpoint(NativeLifecyclePoint::Response);
        }
        if stop && response.accepted {
            if !matches!(
                response.result.0.as_ref(),
                Some(winsmux_workspace::contract::Success::HostStop(_))
            ) || session.owner.collect().is_err()
            {
                lease.publish(Outcome::Unknown);
                return Err("transport_uncertain");
            }
            lease.publish(Outcome::Collected);
        } else if stop {
            lease.publish(Outcome::Refused(response_error(&response)));
        } else {
            lease.publish(Outcome::Known);
        }
        Ok(response)
    }
    fn reserve(self: &Arc<Self>, intent: Intent) -> Result<CompletionAdmission, &'static str> {
        let result = self
            .state
            .lock()
            .map_err(|_| "transport_uncertain")?
            .reserve(intent);
        self.notify_changed();
        result.map(|(ticket, start)| {
            if start {
                CompletionAdmission::Started(CompletionWorker {
                    manager: self.clone(),
                    ticket,
                    completed: false,
                })
            } else {
                CompletionAdmission::Coalesced
            }
        })
    }
    fn finish_stop(self: &Arc<Self>, ticket: &Arc<CompletionReservation>) -> Result<(), String> {
        let mut announced = None;
        loop {
            let advance = self
                .state
                .lock()
                .map_err(|_| "transport_uncertain")?
                .advance(ticket);
            match advance {
                Advance::AwaitInput(key) => {
                    if announced != Some(key) {
                        announced = Some(key);
                        if self.input_wake(Some(key)).is_err() {
                            self.reject_input_notification(key);
                        }
                    }
                    self.wait_input(ticket, key).map_err(str::to_owned)?;
                }
                Advance::Await(flight) => self.wait_flight(&flight).map_err(str::to_owned)?,
                Advance::StartStop {
                    flight,
                    session,
                    request,
                } => {
                    let lease = OwnerLease {
                        manager: self.clone(),
                        flight,
                        session: Some(session),
                        armed: true,
                    };
                    // Publication, including exact refusal, resolves this same reservation.
                    let _ = self.execute(lease, &request);
                }
                Advance::Stopped => return Ok(()),
                Advance::Terminal(result) => return result,
            }
        }
    }
    fn abandon(&self, ticket: &CompletionReservation) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .abandon(ticket);
        self.notify_changed();
    }
    fn failed_effect(&self, ticket: &CompletionReservation, known_unstarted: bool) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .failed_effect(ticket, known_unstarted);
        self.notify_changed();
    }
}
fn response_error(response: &Response) -> String {
    response
        .error
        .0
        .as_ref()
        .and_then(|e| serde_json::to_value(e.code()).ok())
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_else(|| "transport_uncertain".into())
}
fn verify_companion(executable: &std::path::Path, expected_sha256: &str) -> Result<(), &'static str> {
    if expected_sha256.is_empty() {
        return Err("companion_unavailable");
    }
    let bytes = std::fs::read(executable).map_err(|_| "companion_unavailable")?;
    if bytes.is_empty() {
        return Err("companion_unavailable");
    }
    let actual = format!("{:x}", Sha256::digest(bytes));
    if actual != expected_sha256 {
        return Err("companion_mismatch");
    }
    Ok(())
}

pub(crate) fn main_local_webview(window: &WebviewWindow, invocation: &ipc::Request<'_>) -> bool {
    let Some(origin) = invocation.headers().get("origin").and_then(|value| value.to_str().ok()) else {
        return false;
    };
    main_local_webview_origin(window, origin)
}
fn main_local_webview_origin(window: &WebviewWindow, origin: &str) -> bool {
    let Ok(page) = window.url() else { return false };
    main_local_origin(window.label(), &page, origin, cfg!(debug_assertions))
}
fn main_local_origin(label: &str, page: &tauri::Url, origin: &str, development: bool) -> bool {
    if label != "main" { return false; }
    let local = matches!(
        (page.scheme(), page.host_str(), page.port()),
        ("http", Some("tauri.localhost"), None) | ("tauri", Some("localhost"), None)
    ) || (development
        && matches!(
            (page.scheme(), page.host_str(), page.port()),
            ("http", Some("localhost"), Some(1420))
        ));
    if !local {
        return false;
    }
    origin == page.origin().ascii_serialization()
}

fn validate_discovery_copy(generation: u64, live: &WorkspaceDiscovery, expected: &DiscoveryCopyRequest)
    -> Result<(), &'static str>
{
    if expected.owner_generation != generation.to_string() || &expected.discovery != live {
        return Err("protocol_failed");
    }
    Ok(())
}

fn execute_discovery_copy(
    lease: OwnerLease,
    receipt: DiscoveryCopyReceipt,
    writer: impl FnOnce(&str) -> Result<(), &'static str>,
) -> Result<DiscoveryCopyReceipt, &'static str> {
    let result = serde_json::to_string(&receipt.discovery)
        .map_err(|_| "protocol_failed")
        .and_then(|text| writer(&text));
    // Clipboard failures are known local outcomes, never uncertain host IO.
    lease.publish(Outcome::Known);
    result.map(|()| receipt)
}

async fn main_lane<T: Send + 'static>(
    app: &tauri::AppHandle,
    action: impl FnOnce() -> T + Send + 'static,
) -> Result<T, &'static str> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let _ = sender.send(action());
    })
    .map_err(|_| "transport_uncertain")?;
    tauri::async_runtime::spawn_blocking(move || receiver.recv())
        .await
        .map_err(|_| "transport_uncertain")?
        .map_err(|_| "transport_uncertain")
}
// Called only by the blocking opening producer, never an event callback.
fn main_lane_blocking<T: Send + 'static>(
    app: &tauri::AppHandle,
    action: impl FnOnce() -> T + Send + 'static,
) -> Result<T, &'static str> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let _ = sender.send(action());
    })
    .map_err(|_| "transport_uncertain")?;
    receiver.recv().map_err(|_| "transport_uncertain")
}
async fn execute_stop(
    app: &tauri::AppHandle,
    manager: Arc<WorkspaceManager>,
    request: Option<Request>,
) -> Result<Response, &'static str> {
    loop {
        let admission_manager = manager.clone();
        let request_copy = request.clone();
        let admission = main_lane(app, move || {
            let admission = admission_manager
                .state
                .lock()
                .map_err(|_| "transport_uncertain")?
                .admit_stop(request_copy)?;
            Ok::<_, &'static str>(match admission {
                Admission::Await(flight) => StopWork::Await(flight),
                Admission::Start {
                    flight,
                    session,
                    request,
                } => StopWork::Start {
                    lease: OwnerLease {
                        manager: admission_manager,
                        flight,
                        session: Some(session),
                        armed: true,
                    },
                    request,
                },
            })
        })
        .await??;
        match admission {
            StopWork::Await(flight) => {
                let wait_manager = manager.clone();
                tauri::async_runtime::spawn_blocking(move || wait_manager.wait_flight(&flight))
                    .await
                    .map_err(|_| "transport_uncertain")??;
            }
            StopWork::Start { lease, request } => {
                return tauri::async_runtime::spawn_blocking(move || {
                    manager.execute(lease, &request)
                })
                .await
                .map_err(|_| "transport_uncertain")?;
            }
        }
    }
}
#[tauri::command]
pub async fn workspace_session_open(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
) -> Result<WorkspaceSession, &'static str> {
    if !main_local_webview(&window, &invocation) {
        return Err("wrong_window");
    }
    let manager = Arc::clone(manager.inner());
    loop {
        let admission_manager = manager.clone();
        let admission = main_lane(window.app_handle(), move || {
            let admitted = admission_manager
                .state
                .lock()
                .map_err(|_| "transport_uncertain")?
                .admit_open()?;
            Ok::<_, &'static str>(match admitted {
                OpenAdmission::Await(flight) => OpenWork::Await(flight),
                OpenAdmission::Existing(session) => OpenWork::Existing(session),
                OpenAdmission::Start(flight) => OpenWork::Start(OpeningLease {
                    manager: admission_manager,
                    flight,
                    completed: false,
                }),
            })
        })
        .await??;
        match admission {
            OpenWork::Existing(session) => return Ok(session),
            OpenWork::Await(flight) => {
                let wait_manager = manager.clone();
                tauri::async_runtime::spawn_blocking(move || wait_manager.wait_flight(&flight))
                    .await
                    .map_err(|_| "transport_uncertain")??;
            }
            OpenWork::Start(mut opening) => {
                let app = window.app_handle().clone();
                return tauri::async_runtime::spawn_blocking(move || {
                    // The producer owns its guard before scheduling, and publishes even
                    // if the original IPC future has disappeared. UI only publishes state.
                    let producer = opening.manager.clone();
                    let started = producer.start_owner();
                    let error = started.as_ref().err().copied();
                    let flight = opening.flight.clone();
                    let publication_manager = producer.clone();
                    let (result, rejected) = main_lane_blocking(&app, move || {
                        let (session, outcome) = match started {
                            Ok(session) => (Some(session), Outcome::Known),
                            Err(_) => (None, Outcome::StartupFailed),
                        };
                        let mut state = publication_manager
                            .state
                            .lock()
                            .unwrap_or_else(|e| e.into_inner());
                        let rejected = state.publish(&flight, session, outcome);
                        let result = if let Some(error) = error {
                            Err(error)
                        } else {
                            state.admission().and_then(|_| {
                                let discovery = state
                                    .session
                                    .as_ref()
                                    .ok_or("session_closed")?
                                    .owner
                                    .discovery();
                                Ok(WorkspaceSession {
                                    instance_id: discovery.instance_id().as_str().to_owned(),
                                    schema_version: discovery.schema_version().get(),
                                })
                            })
                        };
                        drop(state);
                        publication_manager.notify_changed();
                        (result, rejected)
                    })?;
                    opening.completed = true;
                    drop(rejected);
                    result
                })
                .await
                .map_err(|_| "transport_uncertain")?;
            }
        }
    }
}
#[tauri::command]
pub async fn workspace_request(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
    request_json: String,
) -> Result<Response, &'static str> {
    if !main_local_webview(&window, &invocation) {
        return Err("wrong_window");
    }
    let request =
        winsmux_workspace::parse_request(request_json.as_bytes()).map_err(|_| "protocol_failed")?;
    let manager = Arc::clone(manager.inner());
    if matches!(request.action, Action::HostStop(_)) {
        execute_stop(window.app_handle(), manager, Some(request)).await
    } else {
        tauri::async_runtime::spawn_blocking(move || {
            let lease = manager.ordinary_lease()?;
            manager.execute(lease, &request)
        })
        .await
        .map_err(|_| "transport_uncertain")?
    }
}
#[tauri::command]
pub fn workspace_discovery_get(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
) -> Result<WorkspaceDiscovery, &'static str> {
    if !main_local_webview(&window, &invocation) {
        return Err("wrong_window");
    }
    manager.discovery_for_gui()
}
#[tauri::command]
pub async fn workspace_discovery_copy(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
    request_json: String,
) -> Result<DiscoveryCopyReceipt, &'static str> {
    if !main_local_webview(&window, &invocation) { return Err("wrong_window"); }
    let origin = invocation.headers().get("origin").and_then(|value| value.to_str().ok())
        .ok_or("wrong_window")?.to_owned();
    let expected: DiscoveryCopyRequest = serde_json::from_str(&request_json).map_err(|_| "protocol_failed")?;
    let manager = Arc::clone(manager.inner());
    let app = window.app_handle().clone();
    let (hwnd, lease, receipt) = main_lane(&app, move || {
        // Recheck the page after queuing, before creating any owner permit.
        if !main_local_webview_origin(&window, &origin) { return Err("wrong_window"); }
        #[cfg(windows)]
        let hwnd = window.hwnd().map_err(|_| "clipboard_unavailable")?.0 as usize;
        #[cfg(not(windows))]
        let hwnd = 0;
        if hwnd == 0 { return Err("clipboard_unavailable"); }
        let (lease, receipt) = manager.discovery_copy_lease(&expected)?;
        Ok((hwnd, lease, receipt))
    }).await??;
    tauri::async_runtime::spawn_blocking(move || {
        execute_discovery_copy(lease, receipt, |text| crate::workspace_clipboard::write_discovery(hwnd, text))
    }).await.map_err(|_| "transport_uncertain")?
}
#[tauri::command]
pub fn workspace_host_status(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
) -> Result<WorkspaceHostStatus, &'static str> {
    if !main_local_webview(&window, &invocation) { return Err("wrong_window"); }
    manager.host_status()
}
#[tauri::command]
pub async fn workspace_session_close(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
) -> Result<Response, &'static str> {
    if !main_local_webview(&window, &invocation) {
        return Err("wrong_window");
    }
    execute_stop(window.app_handle(), Arc::clone(manager.inner()), None).await
}
struct CompletionWorker {
    manager: Arc<WorkspaceManager>,
    ticket: Arc<CompletionReservation>,
    completed: bool,
}
enum CompletionAdmission {
    Started(CompletionWorker),
    Coalesced,
}
enum StopWork {
    Await(Arc<Flight>),
    Start { lease: OwnerLease, request: Request },
}
enum OpenWork {
    Await(Arc<Flight>),
    Start(OpeningLease),
    Existing(WorkspaceSession),
}
impl Drop for CompletionWorker {
    fn drop(&mut self) {
        if !self.completed {
            self.manager.abandon(&self.ticket);
        }
    }
}
struct ForcePromptLease {
    manager: Arc<WorkspaceManager>,
    ticket: Arc<CompletionReservation>,
    completed: bool,
}
impl Drop for ForcePromptLease {
    fn drop(&mut self) {
        if !self.completed {
            let mut state = self.manager.state.lock().unwrap_or_else(|e| e.into_inner());
            if state.current(&self.ticket) && state.phase == Phase::ForcePrompt {
                state.cancel_force(&self.ticket);
            } else {
                state.abandon(&self.ticket);
            }
            drop(state);
            self.manager.notify_changed();
        }
    }
}
// All reservation creators and error projection use the UI acceptance lane. The
// coordinator remains authoritative; no IO or wait runs on this lane or under its lock.
fn show_completion_error(
    app: &tauri::AppHandle,
    manager: &Arc<WorkspaceManager>,
    origin: u64,
    error: &str,
) {
    let app_copy = app.clone();
    let manager = manager.clone();
    let error = error.to_owned();
    let _ = app.run_on_main_thread(move || {
        if !manager
            .state
            .lock()
            .is_ok_and(|state| state.last_reservation == origin)
        {
            return;
        }
        if let Some(window) = app_copy.get_webview_window("main") {
            if crate::webview_accelerators::show_if_ready(&window).is_err() {
                #[cfg(windows)]
                crate::webview_accelerators::report_hidden_completion_error(&app_copy);
                return;
            }
            let title = if error == "transport_uncertain" {
                "winsmux — workspace close uncertain".to_owned()
            } else {
                format!("winsmux — workspace close refused: {error}")
            };
            let _ = window.set_title(&title);
            let _ = window.emit("workspace-close-refused", error);
        } else {
            #[cfg(windows)]
            crate::webview_accelerators::report_hidden_completion_error(&app_copy);
        }
    });
}
async fn complete_reserved(
    app: tauri::AppHandle,
    mut worker: CompletionWorker,
) -> Result<(), String> {
    let manager = worker.manager.clone();
    let ticket = worker.ticket.clone();
    let stop_manager = manager.clone();
    let stop_ticket = ticket.clone();
    let stopped =
        tauri::async_runtime::spawn_blocking(move || stop_manager.finish_stop(&stop_ticket))
            .await
            .map_err(|_| "transport_uncertain".to_owned())?;
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    {
        manager
            .native_consumers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(serde_json::json!({"reservation":ticket.id,"result":stopped}));
        let observer = manager.clone();
        tauri::async_runtime::spawn_blocking(move || {
            observer.checkpoint(NativeLifecyclePoint::ConsumerTerminal)
        })
        .await
        .map_err(|_| "shutdown_failed")?;
    }
    if let Err(error) = stopped {
        worker.completed = true;
        show_completion_error(&app, &manager, ticket.id, &error);
        return Err(error);
    }
    #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
    {
        let observer = manager.clone();
        tauri::async_runtime::spawn_blocking(move || {
            observer.checkpoint(NativeLifecyclePoint::Finishing)
        })
        .await
        .map_err(|_| "shutdown_failed")?;
    }
    let intent = manager
        .state
        .lock()
        .map_err(|_| "transport_uncertain")?
        .effect_intent(&ticket)?;
    if matches!(intent, Intent::CloseMain) {
        let window = app.get_webview_window("main").ok_or("shutdown_failed")?;
        if window.close().is_err() {
            manager.failed_effect(&ticket, false);
            worker.completed = true;
            show_completion_error(&app, &manager, ticket.id, "shutdown_failed");
            return Err("shutdown_failed".into());
        }
        manager
            .state
            .lock()
            .map_err(|_| "transport_uncertain")?
            .release_effect(&ticket, false)?;
        worker.completed = true;
        return Ok(());
    }
    let cleanup_needed = manager
        .state
        .lock()
        .map_err(|_| "transport_uncertain")?
        .cleanup_permit(&ticket)?;
    if cleanup_needed {
        crate::request_desktop_runtime_shutdown_for_app(&app);
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        manager.checkpoint(NativeLifecyclePoint::CleanupComplete);
    }
    if let Intent::Update(prepared) = &intent {
        let update = prepared.clone();
        let app_copy = app.clone();
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        manager.checkpoint(NativeLifecyclePoint::BeforeHelper);
        let effect_manager = manager.clone();
        let effect_ticket = ticket.clone();
        let launched = tauri::async_runtime::spawn_blocking(move || {
            crate::launch_prepared_desktop_update(&app_copy, &update, move || {
                effect_manager
                    .state
                    .lock()
                    .map_err(|_| "transport_uncertain".to_owned())?
                    .helper_permit(&effect_ticket)
                    .map_err(str::to_owned)
            })
        })
        .await
        .map_err(|_| "shutdown_failed".to_owned())?;
        if let Err(error) = launched {
            manager.failed_effect(&ticket, true);
            worker.completed = true;
            show_completion_error(&app, &manager, ticket.id, "shutdown_failed");
            return Err(error);
        }
        #[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
        manager.checkpoint(NativeLifecyclePoint::HelperStarted);
    }
    let code = match intent {
        Intent::ExitApp(code) => code.unwrap_or(0),
        _ => 0,
    };
    manager
        .state
        .lock()
        .map_err(|_| "transport_uncertain")?
        .release_effect(&ticket, true)?;
    worker.completed = true;
    app.exit(code);
    Ok(())
}
fn begin_completion(app: tauri::AppHandle, intent: Intent) {
    let manager = Arc::clone(app.state::<Arc<WorkspaceManager>>().inner());
    match manager.reserve(intent) {
        Ok(CompletionAdmission::Started(worker)) => {
            tauri::async_runtime::spawn(async move {
                let _ = complete_reserved(app, worker).await;
            });
        }
        Ok(CompletionAdmission::Coalesced) => {}
        Err(error) => {
            let origin = manager
                .state
                .lock()
                .map(|s| s.last_reservation)
                .unwrap_or(0);
            show_completion_error(&app, &manager, origin, error);
        }
    }
}
pub fn begin_normal_close(window: WebviewWindow) {
    begin_completion(window.app_handle().clone(), Intent::CloseMain);
}
pub(crate) async fn install_prepared_update(
    app: tauri::AppHandle,
    prepared: crate::PreparedDesktopUpdate,
) -> Result<(), String> {
    let manager = Arc::clone(app.state::<Arc<WorkspaceManager>>().inner());
    let admission_manager = manager.clone();
    let acceptance = main_lane(&app, move || {
        admission_manager.reserve(Intent::Update(prepared))
    })
    .await
    .map_err(str::to_owned)?
    .map_err(str::to_owned)?;
    match acceptance {
        CompletionAdmission::Coalesced => Err("shutdown_in_progress".into()),
        CompletionAdmission::Started(worker) => complete_reserved(app, worker).await,
    }
}
pub fn dispatch_desktop_event(app: &tauri::AppHandle, event: &tauri::RunEvent) {
    let manager = app.state::<Arc<WorkspaceManager>>();
    match event {
        tauri::RunEvent::WindowEvent {
            label,
            event: tauri::WindowEvent::CloseRequested { api, .. },
            ..
        } if label == "main" => {
            if !manager.state.lock().is_ok_and(|s| s.main_close_released) {
                api.prevent_close();
                begin_completion(app.clone(), Intent::CloseMain);
            }
        }
        tauri::RunEvent::ExitRequested { api, code, .. } => {
            if *code == Some(tauri::RESTART_EXIT_CODE) {
                return;
            }
            let allow = manager.state.lock().is_ok_and(|s| {
                s.phase == Phase::ExitReleased
                    && s.completion.as_ref().is_some_and(|c| match &c.intent {
                        Intent::ExitApp(retained) => retained.unwrap_or(0) == code.unwrap_or(0),
                        Intent::Update(_) | Intent::ForceExit => code.unwrap_or(0) == 0,
                        _ => false,
                    })
            });
            if !allow {
                api.prevent_exit();
                begin_completion(app.clone(), Intent::ExitApp(*code));
            }
        }
        tauri::RunEvent::Exit => {
            crate::request_desktop_runtime_shutdown_for_app(app);
            manager.record_actual_exit();
        }
        _ => {}
    }
}
#[tauri::command]
pub async fn workspace_force_exit(
    window: WebviewWindow,
    invocation: ipc::Request<'_>,
    manager: tauri::State<'_, Arc<WorkspaceManager>>,
) -> Result<(), &'static str> {
    if !main_local_webview(&window, &invocation) {
        return Err("wrong_window");
    }
    let manager = Arc::clone(manager.inner());
    let app = window.app_handle().clone();
    let admission_manager = manager.clone();
    let mut prompt = main_lane(&app, move || {
        let ticket = admission_manager
            .state
            .lock()
            .map_err(|_| "transport_uncertain")?
            .begin_force()?;
        Ok::<_, &'static str>(ForcePromptLease {
            manager: admission_manager,
            ticket,
            completed: false,
        })
    })
    .await??;
    let ticket = prompt.ticket.clone();
    let dialog_app = app.clone();
    let confirmed=tauri::async_runtime::spawn_blocking(move||dialog_app.dialog().message("Saving could not be confirmed. The last durable snapshot may be older. Active runs will stop. Text still being composed or held before sending may be lost. Text whose delivery is unknown may already have reached a run. Force exit and stop this app's workspace host?").title("Workspace state is uncertain").kind(MessageDialogKind::Warning).buttons(MessageDialogButtons::YesNo).blocking_show()).await.map_err(|_|"transport_uncertain")?;
    if !confirmed {
        manager
            .state
            .lock()
            .map_err(|_| "transport_uncertain")?
            .cancel_force(&ticket);
        manager.notify_changed();
        prompt.completed = true;
        return Err("force_exit_cancelled");
    }
    let force_manager = manager.clone();
    let force_ticket = ticket.clone();
    let collected = tauri::async_runtime::spawn_blocking(move || {
        let (flight, session) = force_manager
            .state
            .lock()
            .map_err(|_| "transport_uncertain")?
            .force_permit(&force_ticket)?;
        let mut lease = OwnerLease {
            manager: force_manager.clone(),
            flight,
            session: Some(session),
            armed: true,
        };
        if lease
            .session
            .as_mut()
            .expect("owned force permit")
            .owner
            .force_collect()
            .is_err()
        {
            lease.publish(Outcome::Unknown);
            return Err("transport_uncertain");
        }
        lease.publish(Outcome::Collected);
        Ok(())
    })
    .await
    .map_err(|_| "transport_uncertain")?;
    collected?;
    prompt.completed = true;
    complete_reserved(
        app,
        CompletionWorker {
            manager,
            ticket,
            completed: false,
        },
    )
    .await
    .map_err(|_| "shutdown_failed")
}

#[cfg(test)]
mod input_guard_tests {
    use super::*;
    #[test]
    fn private_host_status_is_exhaustive_decimal_read_only_and_secret_free() {
        let manager = WorkspaceManager::default();
        let phases = [
            (Phase::Empty, "Empty"), (Phase::Opening, "Opening"), (Phase::Ready, "Ready"),
            (Phase::Busy, "Busy"), (Phase::Stopping, "Stopping"), (Phase::Unknown, "Unknown"),
            (Phase::ForcePrompt, "ForcePrompt"), (Phase::Finishing, "Finishing"),
            (Phase::FailedClosed, "FailedClosed"), (Phase::MainClosed, "MainClosed"),
            (Phase::ExitReleased, "ExitReleased"),
        ];
        for (phase, label) in phases {
            let mut state = manager.state.lock().unwrap();
            state.phase = phase;
            state.generation = u64::MAX;
            state.sequence = u64::MAX;
            let before = (state.generation, state.sequence, state.phase, state.input_lease);
            drop(state);
            let first = manager.host_status().unwrap();
            let second = manager.host_status().unwrap();
            assert_eq!(first, second);
            assert_eq!(first.phase, label);
            assert_eq!(first.generation, u64::MAX.to_string());
            assert_eq!(first.revision, u64::MAX.to_string());
            assert_eq!(first.instance_id, None);
            let encoded = serde_json::to_value(&first).unwrap();
            assert_eq!(encoded.as_object().unwrap().len(), 4);
            for prohibited in ["pipe_name", "grant", "input", "secret", "lease"] {
                assert!(!encoded.as_object().unwrap().contains_key(prohibited));
            }
            let state = manager.state.lock().unwrap();
            assert_eq!((state.generation, state.sequence, state.phase, state.input_lease), before);
        }
    }
    #[test]
    fn discovery_requires_a_ready_live_owner_and_denies_unknown() {
        let manager = WorkspaceManager::default();
        assert_eq!(manager.discovery_for_gui().err(), Some("session_closed"));
        {
            let mut state = manager.state.lock().unwrap();
            state.phase = Phase::Busy;
        }
        assert_eq!(manager.discovery_for_gui().err(), Some("session_closed"));
        {
            let mut state = manager.state.lock().unwrap();
            state.phase = Phase::Unknown;
        }
        assert_eq!(manager.discovery_for_gui().err(), Some("transport_uncertain"));
    }
    fn copy_request() -> DiscoveryCopyRequest {
        DiscoveryCopyRequest { owner_generation: "7".into(), discovery: WorkspaceDiscovery {
            instance_id: "11111111-1111-4111-8111-111111111111".into(),
            pipe_name: r"\\.\pipe\winsmux-workspace-v1-fixture".into(), schema_version: 1,
        } }
    }
    #[test]
    fn copy_request_denies_arbitrary_payload_and_noncanonical_owner() {
        let request = copy_request();
        let live = request.discovery.clone();
        assert_eq!(validate_discovery_copy(7, &live, &request), Ok(()));
        for generation in ["6", "8", "07", "7.0", "", "18446744073709551616"] {
            let wrong = DiscoveryCopyRequest { owner_generation: generation.into(), discovery: live.clone() };
            assert_eq!(validate_discovery_copy(7, &live, &wrong), Err("protocol_failed"));
        }
        for field in ["instance_id", "pipe_name", "schema_version"] {
            let mut value = serde_json::to_value(&live).unwrap();
            value[field] = if field == "schema_version" { serde_json::json!(2) } else { serde_json::json!("other") };
            let wrong = DiscoveryCopyRequest { owner_generation: "7".into(), discovery: serde_json::from_value(value).unwrap() };
            assert_eq!(validate_discovery_copy(7, &live, &wrong), Err("protocol_failed"));
        }
        let base = serde_json::json!({"owner_generation":"7","discovery":live});
        for at_root in [false, true] {
            for key in ["text", "grant", "path", "secret", "extra"] {
                let mut value = base.clone();
                if at_root { value[key] = serde_json::json!("arbitrary"); }
                else { value["discovery"][key] = serde_json::json!("arbitrary"); }
                assert!(serde_json::from_value::<DiscoveryCopyRequest>(value).is_err());
            }
        }
    }
    #[test]
    fn discovery_copy_origin_is_main_local_and_exact_without_external_or_secondary_fallback() {
        for (page, origin, development, expected) in [
            ("http://tauri.localhost/", "http://tauri.localhost", false, true),
            // url::Origin keeps the existing custom-scheme origin opaque.
            ("tauri://localhost/", "null", false, true),
            ("tauri://localhost/", "tauri://localhost", false, false),
            ("http://localhost:1420/", "http://localhost:1420", true, true),
            ("http://localhost:1420/", "http://localhost:1420", false, false),
            ("http://tauri.localhost:1420/", "http://tauri.localhost:1420", false, false),
            ("http://tauri.localhost/", "", false, false),
            ("http://tauri.localhost/", "null", false, false),
            ("http://tauri.localhost/", "https://example.com", false, false),
            ("http://tauri.localhost/", "http://tauri.localhost/", false, false),
            ("https://example.com/", "https://example.com", true, false),
            ("http://127.0.0.1:1420/", "http://127.0.0.1:1420", true, false),
        ] {
            let page = tauri::Url::parse(page).unwrap();
            assert_eq!(main_local_origin("main", &page, origin, development), expected, "{page} / {origin}");
            for label in ["secondary", "", "main-other"] {
                assert!(!main_local_origin(label, &page, origin, development));
            }
        }
    }
    #[test]
    fn copy_without_a_ready_live_owner_never_reserves_or_waits() {
        let manager = Arc::new(WorkspaceManager::default());
        for phase in [Phase::Empty, Phase::Opening, Phase::Ready, Phase::Busy, Phase::Stopping,
            Phase::Unknown, Phase::ForcePrompt, Phase::Finishing, Phase::FailedClosed, Phase::MainClosed, Phase::ExitReleased] {
            let mut state = manager.state.lock().unwrap();
            state.phase = phase; state.generation = 7;
            let before = (state.sequence, state.phase, state.generation);
            drop(state);
            assert!(manager.discovery_copy_lease(&copy_request()).is_err());
            let state = manager.state.lock().unwrap();
            assert_eq!((state.sequence, state.phase, state.generation), before);
            assert!(state.session.is_none() && state.flight.is_none());
        }
    }
    #[test]
    fn copy_receipt_requires_writer_success_and_known_failures_release_the_flight() {
        for error in [None, Some("clipboard_unavailable"), Some("clipboard_write_failed")] {
            let manager = Arc::new(WorkspaceManager::default());
            let flight = manager.state.lock().unwrap().new_flight(IoKind::Ordinary, None);
            let lease = OwnerLease { manager: manager.clone(), flight: flight.clone(), session: None, armed: true };
            let request = copy_request();
            let result = execute_discovery_copy(lease, DiscoveryCopyReceipt {
                owner_generation: request.owner_generation, discovery: request.discovery.clone(),
            }, |text| {
                let value: serde_json::Value = serde_json::from_str(text).unwrap();
                assert_eq!(value.as_object().unwrap().len(), 3);
                assert_eq!(serde_json::from_value::<WorkspaceDiscovery>(value).unwrap(), request.discovery);
                error.map_or(Ok(()), Err)
            });
            assert_eq!(result.is_ok(), error.is_none());
            let state = manager.state.lock().unwrap();
            // A coordinator-only fixture has no live Session; Known returns it to
            // Empty rather than inventing a Ready owner. The live path is verified in GUI E2E.
            assert_eq!(state.phase, Phase::Empty);
            assert!(state.flight.is_none());
            assert_eq!(*flight.terminal.lock().unwrap(), Some(Outcome::Known));
        }
    }
    #[test]
    fn close_waits_for_accepted_copy_but_close_first_denies_copy() {
        let manager = Arc::new(WorkspaceManager::default());
        let mut state = manager.state.lock().unwrap();
        let flight = state.new_flight(IoKind::Ordinary, None);
        let (ticket, _) = state.reserve(Intent::CloseMain).unwrap();
        assert!(matches!(state.advance(&ticket), Advance::Await(f) if Arc::ptr_eq(&f, &flight)));
        let before = state.sequence;
        drop(state);
        assert!(manager.discovery_copy_lease(&copy_request()).is_err());
        assert_eq!(manager.state.lock().unwrap().sequence, before);
        let lease = OwnerLease { manager: manager.clone(), flight, session: None, armed: true };
        let request = copy_request();
        execute_discovery_copy(lease, DiscoveryCopyReceipt {
            owner_generation: request.owner_generation, discovery: request.discovery,
        }, |_| Ok(())).unwrap();
        let mut state = manager.state.lock().unwrap();
        assert!(matches!(state.advance(&ticket), Advance::Stopped));
        assert_eq!(state.phase, Phase::Finishing);
    }
    fn intent_update(path: &str) -> Intent {
        Intent::Update(crate::PreparedDesktopUpdate { installer_path:path.into(), expected_sha256:"a".repeat(64) })
    }
    fn purposes() -> Vec<Intent> {
        vec![Intent::CloseMain, Intent::ExitApp(None), Intent::ExitApp(Some(23)), intent_update("first.exe")]
    }
    fn challenge(state: &mut Lifecycle, purpose: Intent) -> (Arc<CompletionReservation>, InputKey) {
        let (ticket, _) = state.reserve(purpose).unwrap();
        let Advance::AwaitInput(key) = state.advance(&ticket) else { panic!("input gate") };
        (ticket,key)
    }
    #[test]
    fn every_destructive_intent_requires_quiescence_before_any_effect() {
        for purpose in purposes() {
            let mut state=Lifecycle::default(); let lease=state.register_input("main").unwrap();
            let (ticket,key)=challenge(&mut state,purpose);
            assert_eq!(key.lease,lease);
            assert_eq!(state.admission(),Err("shutdown_in_progress"));
            assert!(state.effect_intent(&ticket).is_err());
            assert!(state.cleanup_permit(&ticket).is_err());
            assert!(state.helper_permit(&ticket).is_err());
            assert!(state.release_effect(&ticket,true).is_err());
            assert!(state.session.is_none() && state.flight.is_none());
            state.input_reply(key,false).unwrap();
            assert_eq!(state.input_resume_key(),Some(key));
            assert!(!state.cleanup_done && !state.main_close_released);
            assert!(matches!(state.advance(&ticket),Advance::Terminal(Err(e)) if e=="input_pending"));
        }
    }
    #[test]
    fn current_projection_recovers_whole_unreceived_challenge_and_rejects_old_reply() {
        let mut state=Lifecycle::default(); let lease=state.register_input("main").unwrap();
        let (a,old)=challenge(&mut state,Intent::CloseMain); state.input_reply(old,false).unwrap();
        let first=state.input_projection(lease).unwrap();
        let (b,new)=challenge(&mut state,Intent::ExitApp(Some(23)));
        let pending=state.input_projection(lease).unwrap();
        assert!(pending.revision>first.revision && !pending.resume_allowed);
        let before=state.sequence;
        assert_eq!(state.input_reply(old,true),Err("input_guard_stale"));
        state.abandon(&a); state.failed_effect(&a,true); state.cancel_force(&a);
        assert_eq!(state.sequence,before);
        assert!(state.current(&b));
        state.input_reply(new,false).unwrap();
        let current=state.input_projection(lease).unwrap();
        assert!(current.revision>pending.revision && current.resume_allowed);
        assert_eq!(current.fence.unwrap().key,new);
        assert!(current.revision>first.revision);
    }
    #[test]
    fn open_and_ordinary_publish_preserve_release_but_unknown_never_resumes() {
        for kind in [IoKind::Opening,IoKind::Ordinary] {
            for outcome in [Outcome::Known,Outcome::StartupFailed,Outcome::Unknown] {
                let mut state=Lifecycle::default(); state.register_input("main").unwrap();
                let (_,key)=challenge(&mut state,Intent::CloseMain); state.input_reply(key,false).unwrap();
                let flight=state.new_flight(kind,None); let before=state.sequence;
                state.publish(&flight,None,outcome.clone());
                assert_eq!(state.input_fence,Some(InputFence {key,state:InputState::Released}));
                assert!(state.sequence>before);
                assert_eq!(state.input_resume_key(),if outcome==Outcome::Unknown {None} else {Some(key)});
            }
        }
    }
    #[test]
    fn pending_promotions_coalesce_and_conflicts_do_not_replace_fence() {
        let mut state=Lifecycle::default(); state.register_input("main").unwrap();
        let (a,key)=challenge(&mut state,Intent::CloseMain);
        let (b,start)=state.reserve(Intent::ExitApp(Some(23))).unwrap();
        assert!(Arc::ptr_eq(&a,&b)); assert!(!start);
        assert_eq!(state.completion.as_ref().unwrap().input_key,Some(key));
        let sequence=state.sequence;
        assert!(state.reserve(Intent::ExitApp(Some(24))).is_err());
        assert!(state.reserve(intent_update("other.exe")).is_err());
        assert_eq!(state.sequence,sequence);
        state.input_reply(key,true).unwrap(); assert!(matches!(state.advance(&b),Advance::Stopped));
        assert!(matches!(state.effect_intent(&b),Ok(Intent::ExitApp(Some(23)))));
    }
    #[test]
    fn main_closed_exit_and_known_update_recovery_inherit_one_approved_key() {
        let mut state=Lifecycle::default(); state.register_input("main").unwrap();
        let (close,key)=challenge(&mut state,Intent::CloseMain); state.input_reply(key,true).unwrap();
        assert!(matches!(state.advance(&close),Advance::Stopped));
        assert!(matches!(state.effect_intent(&close),Ok(Intent::CloseMain)));
        state.release_effect(&close,false).unwrap();
        let (exit,_)=state.reserve(Intent::ExitApp(Some(23))).unwrap();
        assert_eq!(state.completion.as_ref().unwrap().input_key,Some(key));
        assert!(matches!(state.advance(&exit),Advance::Stopped));
        assert!(state.cleanup_permit(&exit).unwrap());
        assert!(!state.cleanup_permit(&exit).unwrap());
        state.release_effect(&exit,true).unwrap(); state.record_actual_exit();
        assert_eq!(state.confirmed_exit_code,Some(23));
        assert!(!state.input_projection(key.lease).unwrap().resume_allowed);
        let mut state=Lifecycle::default(); state.register_input("main").unwrap();
        let (update,key)=challenge(&mut state,intent_update("first.exe")); state.input_reply(key,true).unwrap();
        assert!(matches!(state.advance(&update),Advance::Stopped)); state.cleanup_permit(&update).unwrap();
        state.failed_effect(&update,true);
        assert!(state.reserve(intent_update("second.exe")).is_err());
        let (retry,_)=state.reserve(intent_update("first.exe")).unwrap();
        assert_eq!(state.completion.as_ref().unwrap().input_key,Some(key));
        assert!(matches!(state.advance(&retry),Advance::Stopped));
        assert!(!state.cleanup_permit(&retry).unwrap());
        state.helper_permit(&retry).unwrap(); assert!(state.helper_permit(&retry).is_err());
    }
    #[test]
    fn pending_abandon_needs_new_guard_and_old_approved_recovery_stays_frozen() {
        for approved in [false,true] {
            let mut state=Lifecycle::default(); state.register_input("main").unwrap();
            let (a,key)=challenge(&mut state,Intent::ExitApp(Some(23)));
            if approved { state.input_reply(key,true).unwrap(); assert!(matches!(state.advance(&a),Advance::Stopped)); }
            state.abandon(&a);
            assert!(state.input_resume_key().is_none());
            let (b,_)=state.reserve(Intent::ExitApp(Some(23))).unwrap();
            let new=state.completion.as_ref().unwrap().input_key.unwrap();
            assert_eq!(new==key,approved);
            if approved { assert!(matches!(state.advance(&b),Advance::Stopped)); }
            else { assert!(matches!(state.advance(&b),Advance::AwaitInput(k) if k==new)); }
            assert_eq!(state.input_reply(key,true),Err("input_guard_stale"));
        }
    }
    #[test]
    fn same_binding_retains_lease_status_is_read_only_and_foreign_lease_is_rejected() {
        let mut state=Lifecycle::default(); let lease=state.register_input("main").unwrap();
        assert_eq!(state.register_input("main"),Ok(lease));
        assert_eq!(state.register_input("replacement"),Err("input_guard_owned"));
        let revision=state.sequence;
        assert!(state.input_projection(lease).is_ok());
        assert_eq!(state.input_projection(lease+1),Err("input_guard_owned"));
        assert_eq!(state.sequence,revision);
    }
    #[test]
    fn completion_worker_notifies_once_waits_without_mutex_and_reply_releases_wait() {
        let manager=Arc::new(WorkspaceManager::default());
        let lease=manager.state.lock().unwrap().register_input("main").unwrap();
        let (sender,receiver)=std::sync::mpsc::channel();
        *manager.input_notifier.lock().unwrap()=Some(Arc::new(move |wake,key| {
            // Taking this lock in the test proves callback delivery is outside it.
            sender.send((wake,key)).unwrap(); Ok(())
        }));
        let CompletionAdmission::Started(mut worker)=manager.reserve(Intent::CloseMain).unwrap() else {panic!("worker")};
        let runner=manager.clone(); let ticket=worker.ticket.clone();
        let thread=std::thread::spawn(move || runner.finish_stop(&ticket));
        let (wake,key)=receiver.recv().unwrap(); let key=key.unwrap();
        assert_eq!(wake.lease,lease.to_string());
        assert_eq!(manager.input_guard_status(lease).unwrap().fence.unwrap().state,"pending");
        manager.reply_input_guard(lease,key.ticket,true).unwrap();
        assert_eq!(thread.join().unwrap(),Ok(())); worker.completed=true;
        let extra:Vec<_>=receiver.try_iter().collect();
        assert!(extra.iter().all(|(_,key)|key.is_none()));
        assert_eq!(manager.state.lock().unwrap().phase,Phase::Finishing);
    }
    #[test]
    fn notification_failure_is_known_refusal_and_stale_failure_cannot_cancel_next_guard() {
        let manager=Arc::new(WorkspaceManager::default());
        let lease=manager.state.lock().unwrap().register_input("main").unwrap();
        *manager.input_notifier.lock().unwrap()=Some(Arc::new(|_,_|Err(())));
        let CompletionAdmission::Started(mut a)=manager.reserve(Intent::CloseMain).unwrap() else {panic!("worker")};
        let key=manager.state.lock().unwrap().input_fence.unwrap().key;
        assert_eq!(manager.finish_stop(&a.ticket),Err("input_pending".into())); a.completed=true;
        assert!(manager.input_guard_status(lease).unwrap().resume_allowed);
        let CompletionAdmission::Started(mut b)=manager.reserve(Intent::ExitApp(Some(23))).unwrap() else {panic!("worker")};
        let next=manager.state.lock().unwrap().input_fence.unwrap().key;
        assert_ne!(next,key); manager.reject_input_notification(key);
        assert_eq!(manager.input_guard_status(lease).unwrap().fence.unwrap().state,"pending");
        manager.reply_input_guard(lease,next.ticket,false).unwrap(); b.completed=true;
    }
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;
    #[test]
    fn undelivered_admission_and_unpolled_worker_already_own_abandonment() {
        let manager = Arc::new(WorkspaceManager::default());
        let acceptance = manager.reserve(Intent::ExitApp(Some(23))).unwrap();
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        drop(receiver);
        drop(sender.send(acceptance));
        assert_eq!(manager.state.lock().unwrap().phase, Phase::FailedClosed);
        assert!(
            !manager
                .state
                .lock()
                .unwrap()
                .completion
                .as_ref()
                .unwrap()
                .worker
        );
        let acceptance = manager.reserve(Intent::ExitApp(Some(0))).unwrap();
        let future = async move {
            drop(acceptance);
        };
        drop(future);
        assert_eq!(manager.state.lock().unwrap().phase, Phase::FailedClosed);
        assert!(
            manager
                .state
                .lock()
                .unwrap()
                .completion
                .as_ref()
                .unwrap()
                .abandoned
        );
    }
    #[test]
    fn actual_old_worker_and_prompt_drops_cannot_cancel_a_new_reservation() {
        let manager = Arc::new(WorkspaceManager::default());
        let flight = {
            let mut state = manager.state.lock().unwrap();
            state.new_flight(IoKind::Stop, None)
        };
        let CompletionAdmission::Started(a) = manager.reserve(Intent::ExitApp(Some(23))).unwrap()
        else {
            panic!("new worker");
        };
        manager.state.lock().unwrap().publish(
            &flight,
            None,
            Outcome::Refused("operation_conflict".into()),
        );
        let CompletionAdmission::Started(b) = manager.reserve(update("first.exe")).unwrap() else {
            panic!("new retry");
        };
        let b_id = b.ticket.id;
        drop(a);
        {
            let state = manager.state.lock().unwrap();
            assert_eq!(state.completion.as_ref().unwrap().ticket.id, b_id);
            assert!(state.completion.as_ref().unwrap().worker);
        }
        drop(b);
        manager.state.lock().unwrap().phase = Phase::Unknown;
        let a_ticket = manager.state.lock().unwrap().begin_force().unwrap();
        manager.state.lock().unwrap().cancel_force(&a_ticket);
        let b_ticket = manager.state.lock().unwrap().begin_force().unwrap();
        drop(ForcePromptLease {
            manager: manager.clone(),
            ticket: a_ticket,
            completed: false,
        });
        assert_eq!(manager.state.lock().unwrap().phase, Phase::ForcePrompt);
        assert_eq!(
            manager
                .state
                .lock()
                .unwrap()
                .completion
                .as_ref()
                .unwrap()
                .ticket
                .id,
            b_ticket.id
        );
        drop(ForcePromptLease {
            manager: manager.clone(),
            ticket: b_ticket,
            completed: false,
        });
        assert_eq!(manager.state.lock().unwrap().phase, Phase::Unknown);
    }
    #[test]
    fn undelivered_open_and_stop_permits_seal_their_own_flight_without_io() {
        let manager = Arc::new(WorkspaceManager::default());
        let flight = {
            let mut state = manager.state.lock().unwrap();
            state.new_flight(IoKind::Opening, None)
        };
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        drop(receiver);
        drop(sender.send(OpenWork::Start(OpeningLease {
            manager: manager.clone(),
            flight: flight.clone(),
            completed: false,
        })));
        assert_eq!(
            flight.terminal.lock().unwrap().as_ref(),
            Some(&Outcome::StartupFailed)
        );
        assert_eq!(manager.state.lock().unwrap().phase, Phase::Empty);
        let flight = {
            let mut state = manager.state.lock().unwrap();
            let flight = state.new_flight(IoKind::Stop, None);
            state.new_completion(Intent::SessionOnly, false, false);
            flight
        };
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        drop(receiver);
        drop(sender.send(OwnerLease {
            manager: manager.clone(),
            flight: flight.clone(),
            session: None,
            armed: true,
        }));
        assert_eq!(
            flight.terminal.lock().unwrap().as_ref(),
            Some(&Outcome::Unknown)
        );
        let state = manager.state.lock().unwrap();
        assert_eq!(state.phase, Phase::Unknown);
        assert!(state.flight.is_none());
        assert!(state.completion.is_none());
        assert_eq!(state.admission(), Err("transport_uncertain"));
    }
    fn update(path: &str) -> Intent {
        Intent::Update(crate::PreparedDesktopUpdate {
            installer_path: path.into(),
            expected_sha256: "a".repeat(64),
        })
    }
    fn pending(
        kind: IoKind,
        intent: Intent,
    ) -> (Lifecycle, Arc<Flight>, Arc<CompletionReservation>) {
        let mut state = Lifecycle {
            generation: 7,
            ..Lifecycle::default()
        };
        let flight = state.new_flight(kind, None);
        let ticket = state.new_completion(intent, false, false);
        (state, flight, ticket)
    }
    #[test]
    fn every_attached_stop_consumer_receives_one_sealed_result_without_a_new_permit() {
        for purpose in [Intent::CloseMain, Intent::ExitApp(Some(23))] {
            for outcome in [
                Outcome::Collected,
                Outcome::Refused("operation_conflict".into()),
                Outcome::PrewireProtocol,
                Outcome::Unknown,
            ] {
                let (mut state, flight, ticket) = pending(IoKind::Stop, Intent::SessionOnly);
                let (attached, start) = state.reserve(purpose.clone()).unwrap();
                assert!(Arc::ptr_eq(&ticket, &attached));
                assert!(start);
                assert!(
                    matches!(state.advance(&ticket),Advance::Await(f) if Arc::ptr_eq(&f,&flight))
                );
                assert!(state.publish(&flight, None, outcome.clone()).is_none());
                assert_eq!(flight.terminal.lock().unwrap().as_ref(), Some(&outcome));
                let sequence = state.sequence;
                match outcome {
                    Outcome::Collected => {
                        assert!(matches!(state.advance(&ticket), Advance::Stopped));
                        assert_eq!(state.phase, Phase::Finishing);
                    }
                    Outcome::Refused(_) => {
                        assert!(
                            matches!(state.advance(&ticket),Advance::Terminal(Err(e)) if e=="operation_conflict")
                        );
                        assert_eq!(state.phase, Phase::Ready);
                        assert!(state.completion.is_none());
                    }
                    Outcome::PrewireProtocol => {
                        assert!(
                            matches!(state.advance(&ticket),Advance::Terminal(Err(e)) if e=="protocol_failed")
                        );
                        assert_eq!(state.phase, Phase::Ready);
                    }
                    Outcome::Unknown => {
                        assert!(
                            matches!(state.advance(&ticket),Advance::Terminal(Err(e)) if e=="transport_uncertain")
                        );
                        assert_eq!(state.phase, Phase::Unknown);
                        assert_eq!(state.admission(), Err("transport_uncertain"));
                    }
                    _ => unreachable!(),
                }
                assert_eq!(
                    state.sequence, sequence,
                    "a stop consumer cannot issue another attempt"
                );
                assert!(!state.cleanup_done);
                assert!(!state.main_close_released);
                assert_eq!(state.confirmed_exit_code, None);
            }
        }
    }
    #[test]
    fn session_only_is_not_an_update_or_healthy_force_authority() {
        let (mut state, _, _) = pending(IoKind::Stop, Intent::SessionOnly);
        assert_eq!(
            state.reserve(update("first.exe")).err(),
            Some("shutdown_conflict")
        );
        assert_eq!(state.begin_force().err(), Some("force_exit_unavailable"));
        assert_eq!(state.admit_stop(None).err(), Some("shutdown_in_progress"));
        state.reserve(Intent::CloseMain).unwrap();
        state.reserve(Intent::ExitApp(Some(23))).unwrap();
        assert_eq!(
            state.reserve(Intent::ExitApp(Some(24))).err(),
            Some("shutdown_conflict")
        );
        assert_eq!(
            state.reserve(Intent::CloseMain).err(),
            Some("shutdown_conflict")
        );
    }
    #[test]
    fn old_refusal_drop_effect_and_projection_cannot_change_same_generation_retry() {
        for replacement in [Intent::ExitApp(Some(23)), update("first.exe")] {
            let (mut state, flight, a) = pending(IoKind::Stop, Intent::ExitApp(Some(1)));
            state.completion.as_mut().unwrap().worker = true;
            state.publish(&flight, None, Outcome::Refused("operation_conflict".into()));
            let (b, start) = state.reserve(replacement).unwrap();
            assert!(start);
            assert_ne!(a.id, b.id);
            let before = (
                state.phase,
                state.generation,
                state.last_reservation,
                state.sequence,
            );
            state.abandon(&a);
            state.failed_effect(&a, true);
            state.cancel_force(&a);
            assert_eq!(
                before,
                (
                    state.phase,
                    state.generation,
                    state.last_reservation,
                    state.sequence
                )
            );
            assert!(state.current(&b));
            assert!(state.completion.as_ref().unwrap().worker);
            assert!(
                matches!(state.advance(&a),Advance::Terminal(Err(e)) if e=="operation_conflict")
            );
            assert_eq!(state.last_reservation, b.id);
        }
        let (mut state, flight, a) = pending(IoKind::Stop, Intent::ExitApp(Some(1)));
        state.publish(&flight, None, Outcome::Unknown);
        let b = state.begin_force().unwrap();
        state.abandon(&a);
        state.failed_effect(&a, true);
        state.cancel_force(&a);
        assert_eq!(state.phase, Phase::ForcePrompt);
        assert!(state.current(&b));
        state.cancel_force(&b);
        assert_eq!(state.phase, Phase::Unknown);
    }
    #[test]
    fn opening_and_ordinary_safe_results_advance_but_uncertainty_or_abandon_do_not() {
        for kind in [IoKind::Opening, IoKind::Ordinary] {
            for outcome in [Outcome::Known, Outcome::StartupFailed, Outcome::Unknown] {
                let (mut state, flight, ticket) = pending(kind, Intent::ExitApp(Some(23)));
                assert!(matches!(state.advance(&ticket), Advance::Await(_)));
                state.publish(&flight, None, outcome.clone());
                match outcome {
                    Outcome::Known | Outcome::StartupFailed => {
                        assert!(matches!(state.advance(&ticket), Advance::Stopped));
                        assert!(state.completion.as_ref().unwrap().stopped);
                    }
                    Outcome::Unknown => {
                        assert!(matches!(state.advance(&ticket), Advance::Terminal(Err(_))))
                    }
                    _ => unreachable!(),
                }
            }
            let (mut state, flight, ticket) = pending(kind, Intent::ExitApp(Some(23)));
            state.abandon(&ticket);
            state.publish(&flight, None, Outcome::Known);
            assert_eq!(state.phase, Phase::FailedClosed);
            assert!(matches!(state.advance(&ticket), Advance::Terminal(Err(_))));
            assert!(!state.cleanup_done);
        }
    }
    #[test]
    fn late_actual_collection_after_abandon_is_closed_without_effects_or_owner_resurrection() {
        let (mut state, flight, a) = pending(IoKind::Stop, Intent::ExitApp(Some(23)));
        state.abandon(&a);
        state.publish(&flight, None, Outcome::Collected);
        assert_eq!(state.phase, Phase::FailedClosed);
        assert!(state.session.is_none());
        assert!(!state.cleanup_done);
        assert_eq!(state.admission(), Err("shutdown_failed"));
        let (b, _) = state.reserve(Intent::ExitApp(Some(0))).unwrap();
        state.abandon(&a);
        assert!(state.current(&b));
        assert!(matches!(state.advance(&b), Advance::Stopped));
    }
    #[test]
    fn update_recovery_preserves_prepared_identity_and_started_uncertainty() {
        let (mut state, flight, a) = pending(IoKind::Stop, update("first.exe"));
        state.publish(&flight, None, Outcome::Collected);
        state.failed_effect(&a, true);
        assert_eq!(
            state.reserve(update("other.exe")).err(),
            Some("shutdown_conflict")
        );
        let (b, _) = state.reserve(update("first.exe")).unwrap();
        assert_eq!(state.cleanup_permit(&b), Ok(true));
        assert_eq!(state.helper_permit(&b), Ok(()));
        state.abandon(&b);
        assert_eq!(
            state.reserve(update("first.exe")).err(),
            Some("shutdown_conflict")
        );
        let (c, _) = state.reserve(Intent::ExitApp(Some(0))).unwrap();
        state.failed_effect(&b, true);
        assert!(state.current(&c));
        assert!(matches!(
            state.completion.as_ref().unwrap().intent,
            Intent::ExitApp(Some(0))
        ));
    }
    #[test]
    fn main_only_close_keeps_old_runtime_and_later_app_exit_owns_cleanup_once() {
        let (mut state, flight, a) = pending(IoKind::Stop, Intent::CloseMain);
        state.publish(&flight, None, Outcome::Collected);
        assert!(matches!(state.effect_intent(&a), Ok(Intent::CloseMain)));
        state.release_effect(&a, false).unwrap();
        assert!(state.main_close_released);
        assert!(!state.cleanup_done);
        let (b, _) = state.reserve(Intent::ExitApp(Some(23))).unwrap();
        assert_eq!(state.cleanup_permit(&b), Ok(true));
        assert_eq!(state.cleanup_permit(&b), Ok(false));
        state.abandon(&a);
        assert!(state.current(&b));
        state.release_effect(&b, true).unwrap();
        state.record_actual_exit();
        assert_eq!(state.confirmed_exit_code, Some(23));
    }
    #[test]
    fn os_completion_requires_actual_exit_confirmed_collection_and_old_cleanup() {
        for purpose in [
            Intent::ExitApp(Some(23)),
            Intent::ExitApp(None),
            Intent::ForceExit,
            update("first.exe"),
        ] {
            let (mut state, flight, ticket) = pending(IoKind::Stop, purpose.clone());
            state.publish(&flight, None, Outcome::Collected);
            assert_eq!(state.confirmed_exit_code, None);
            state.release_effect(&ticket, true).unwrap();
            state.record_actual_exit();
            assert_eq!(state.confirmed_exit_code, None);
            state.cleanup_done = true;
            state.record_actual_exit();
            assert_eq!(
                state.confirmed_exit_code,
                Some(if matches!(purpose, Intent::ExitApp(Some(23))) {
                    23
                } else {
                    0
                })
            );
        }
        let (mut state, flight, ticket) = pending(
            IoKind::Stop,
            Intent::ExitApp(Some(tauri::RESTART_EXIT_CODE)),
        );
        state.publish(&flight, None, Outcome::Collected);
        state.cleanup_done = true;
        state.release_effect(&ticket, true).unwrap();
        state.record_actual_exit();
        assert_eq!(state.confirmed_exit_code, None);
    }
}

#[cfg(test)]
mod release_lifetime_tests {
    use super::*;
    fn released_close() -> (Lifecycle, InputKey) {
        let mut s = Lifecycle::default();
        s.register_input("one-main-binding").unwrap();
        let (a, _) = s.reserve(Intent::CloseMain).unwrap();
        let Advance::AwaitInput(k) = s.advance(&a) else { panic!("challenge") };
        s.input_reply(k, false).unwrap();
        assert_eq!(s.input_resume_key(), Some(k));
        (s, k)
    }
    #[test]
    fn undelivered_release_survives_session_only_collection() {
        let (mut s, k) = released_close();
        let (b, _) = s.reserve(Intent::SessionOnly).unwrap();
        assert!(matches!(s.advance(&b), Advance::Stopped));
        // Standalone reserve/finish SessionOnly's empty state has no main effect.
        let c = s.completion.take().unwrap();
        Lifecycle::seal_ticket(&c.ticket, Ok(())); s.phase = Phase::Empty;
        assert_eq!(s.input_resume_key(), Some(k), "root still frozen under A must recover release after B");
    }
    #[test]
    fn undelivered_release_survives_new_owner_open_generation() {
        let (mut s, k) = released_close();
        let OpenAdmission::Start(f) = s.admit_open().unwrap() else { panic!("open") };
        s.publish(&f, None, Outcome::StartupFailed);
        assert_eq!(s.input_resume_key(), Some(k), "opening reservation is not input-fence authority");
    }
}
