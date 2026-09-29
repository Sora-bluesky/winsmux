#[cfg(windows)]
mod windows {
    use crate::contract::{
        canonical_request, parse_request, parse_response, serialize_response, MAX_MESSAGE_BYTES,
    };
    use crate::host::io::{read_frame, write_frame, CancelEvent, IoError, OwnedHandle};
    use crate::host::security::{Identity, PIPE_DATA_ACCESS};
    use crate::host::server_identity::{
        encode_request, random_challenge, verify_response, AUTH_REQUEST_BYTES,
    };
    use crate::host::{Discovery, HostError};
    use std::io::{BufRead, IsTerminal, Write};
    use std::ptr::null_mut;
    use std::sync::{mpsc, Arc, Mutex, MutexGuard};
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_OVERLAPPED, OPEN_EXISTING, SECURITY_IDENTIFICATION,
        SECURITY_SQOS_PRESENT,
    };
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, SetConsoleCtrlHandler, SetConsoleMode, CTRL_C_EVENT,
        ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT, STD_INPUT_HANDLE,
    };
    use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcessId, ResetEvent, WaitForMultipleObjects, INFINITE,
    };
    #[cfg(debug_assertions)]
    use windows_sys::Win32::System::Threading::{OpenEventW, SetEvent, EVENT_MODIFY_STATE};

    static CONSOLE_SESSION_CANCEL: Mutex<Option<Arc<CancelEvent>>> = Mutex::new(None);
    #[cfg(debug_assertions)]
    const CONNECT_READY_EVENT_ENV: &str = "WINSMUX_TASK862_CONNECT_READY_EVENT";
    #[cfg(debug_assertions)]
    const CONNECT_READY_EVENT_PREFIX: &str = r"Local\winsmux-task862-connect-ready-";

    fn lock_cancel_target(
        registry: &Mutex<Option<Arc<CancelEvent>>>,
    ) -> MutexGuard<'_, Option<Arc<CancelEvent>>> {
        match registry.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn dispatch_ctrl_event_with(
        control: u32,
        registry: &Mutex<Option<Arc<CancelEvent>>>,
        signal: impl FnOnce(Arc<CancelEvent>),
    ) -> i32 {
        if control != CTRL_C_EVENT {
            return 0;
        }
        let cancel = {
            let owner = lock_cancel_target(registry);
            owner.clone()
        };
        match cancel {
            Some(cancel) => {
                signal(cancel);
                1
            }
            None => 0,
        }
    }

    unsafe extern "system" fn console_session_ctrl_handler(control: u32) -> i32 {
        dispatch_ctrl_event_with(control, &CONSOLE_SESSION_CANCEL, |cancel| cancel.signal())
    }

    trait ConsoleOperations {
        fn add_handler(&self) -> bool;
        fn clear_inherited_ignore(&self) -> bool;
        fn remove_handler(&self) -> bool;
        fn input_handle(&self) -> HANDLE;
        fn get_mode(&self, handle: HANDLE) -> Option<u32>;
        fn set_mode(&self, handle: HANDLE, mode: u32) -> bool;
    }

    #[derive(Clone, Copy)]
    struct SystemConsoleOperations;

    impl ConsoleOperations for SystemConsoleOperations {
        fn add_handler(&self) -> bool {
            unsafe { SetConsoleCtrlHandler(Some(console_session_ctrl_handler), 1) != 0 }
        }

        fn clear_inherited_ignore(&self) -> bool {
            unsafe { SetConsoleCtrlHandler(None, 0) != 0 }
        }

        fn remove_handler(&self) -> bool {
            unsafe { SetConsoleCtrlHandler(Some(console_session_ctrl_handler), 0) != 0 }
        }

        fn input_handle(&self) -> HANDLE {
            unsafe { GetStdHandle(STD_INPUT_HANDLE) }
        }

        fn get_mode(&self, handle: HANDLE) -> Option<u32> {
            let mut mode = 0u32;
            (unsafe { GetConsoleMode(handle, &mut mode) } != 0).then_some(mode)
        }

        fn set_mode(&self, handle: HANDLE, mode: u32) -> bool {
            unsafe { SetConsoleMode(handle, mode) != 0 }
        }
    }

    #[derive(Clone, Copy)]
    struct ConsoleInputState {
        handle: HANDLE,
        original_mode: u32,
    }

    fn managed_console_mode(original_mode: u32) -> u32 {
        (original_mode | ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT) & !ENABLE_ECHO_INPUT
    }

    struct ConsoleSessionState<'a, O: ConsoleOperations> {
        registry: &'a Mutex<Option<Arc<CancelEvent>>>,
        operations: O,
        cancel: Option<Arc<CancelEvent>>,
        reservation_owned: bool,
        handler_registered: bool,
        handler_ready: bool,
        input_mode: Option<ConsoleInputState>,
        terminal_input: bool,
        finished: bool,
    }

    impl<'a, O: ConsoleOperations> ConsoleSessionState<'a, O> {
        fn start_with(
            cancel: Arc<CancelEvent>,
            terminal_input: bool,
            registry: &'a Mutex<Option<Arc<CancelEvent>>>,
            operations: O,
        ) -> Result<Self, HostError> {
            let mut session = Self {
                registry,
                operations,
                cancel: Some(cancel),
                reservation_owned: false,
                handler_registered: false,
                handler_ready: false,
                input_mode: None,
                terminal_input,
                finished: false,
            };
            {
                let mut owner = lock_cancel_target(registry);
                if owner.is_some() {
                    return Err(HostError::Startup);
                }
                *owner = session.cancel.clone();
                session.reservation_owned = true;
            }

            session.handler_ready = session.install_handler();
            if terminal_input && !session.handler_ready {
                return Err(session
                    .finish(Err(HostError::Startup))
                    .err()
                    .unwrap_or(HostError::Startup));
            }
            if terminal_input {
                let handle = session.operations.input_handle();
                if handle.is_null() || handle == INVALID_HANDLE_VALUE {
                    return Err(session
                        .finish(Err(HostError::Startup))
                        .err()
                        .unwrap_or(HostError::Startup));
                }
                let Some(original_mode) = session.operations.get_mode(handle) else {
                    return Err(session
                        .finish(Err(HostError::Startup))
                        .err()
                        .unwrap_or(HostError::Startup));
                };
                if !session
                    .operations
                    .set_mode(handle, managed_console_mode(original_mode))
                {
                    return Err(session
                        .finish(Err(HostError::Startup))
                        .err()
                        .unwrap_or(HostError::Startup));
                }
                session.input_mode = Some(ConsoleInputState {
                    handle,
                    original_mode,
                });
            }
            Ok(session)
        }

        fn install_handler(&mut self) -> bool {
            if !self.operations.add_handler() {
                return false;
            }
            self.handler_registered = true;
            if !self.operations.clear_inherited_ignore() {
                if self.operations.remove_handler() {
                    self.handler_registered = false;
                }
                return false;
            }
            true
        }

        fn finish(&mut self, primary: Result<(), HostError>) -> Result<(), HostError> {
            let cleanup_failed = self.cleanup();
            if cleanup_failed && matches!(primary, Ok(()) | Err(HostError::Cancelled)) {
                Err(HostError::Transport)
            } else {
                primary
            }
        }

        fn cleanup(&mut self) -> bool {
            if self.finished {
                return false;
            }
            let restore_failed = self
                .input_mode
                .take()
                .is_some_and(|state| !self.operations.set_mode(state.handle, state.original_mode));
            let unregister_failed = if self.handler_registered {
                let failed = !self.operations.remove_handler();
                self.handler_registered = false;
                failed
            } else {
                false
            };
            self.handler_ready = false;

            let registry_failed = if self.reservation_owned {
                let mut owner = lock_cancel_target(self.registry);
                let matches_owner = match (owner.as_ref(), self.cancel.as_ref()) {
                    (Some(current), Some(cancel)) => Arc::ptr_eq(current, cancel),
                    _ => false,
                };
                if matches_owner {
                    *owner = None;
                }
                self.reservation_owned = false;
                !matches_owner
            } else {
                false
            };
            self.cancel.take();
            self.finished = true;
            restore_failed || unregister_failed || registry_failed
        }
    }

    impl<O: ConsoleOperations> Drop for ConsoleSessionState<'_, O> {
        fn drop(&mut self) {
            let _ = self.cleanup();
        }
    }

    pub(crate) struct ConsoleSession {
        state: ConsoleSessionState<'static, SystemConsoleOperations>,
    }

    impl ConsoleSession {
        pub(crate) fn start() -> Result<Self, HostError> {
            let cancel = Arc::new(CancelEvent::new().map_err(map_io)?);
            ConsoleSessionState::start_with(
                cancel,
                std::io::stdin().is_terminal(),
                &CONSOLE_SESSION_CANCEL,
                SystemConsoleOperations,
            )
            .map(|state| Self { state })
        }

        pub(crate) fn cancel(&self) -> &CancelEvent {
            self.state
                .cancel
                .as_deref()
                .expect("unfinished console session owns cancellation")
        }

        pub(crate) fn finish(mut self, primary: Result<(), HostError>) -> Result<(), HostError> {
            self.state.finish(primary)
        }

        fn terminal_input(&self) -> bool {
            self.state.terminal_input
        }

        fn handler_ready(&self) -> bool {
            self.state.handler_ready
        }

        fn console_mode_held(&self) -> bool {
            self.state.input_mode.is_some()
        }
    }

    #[cfg(debug_assertions)]
    fn parse_connect_ready_event_name(name: &str) -> Option<(u32, u64)> {
        let suffix = name.strip_prefix(CONNECT_READY_EVENT_PREFIX)?;
        let (pid, counter) = suffix.split_once('-')?;
        Some((
            parse_canonical_positive_decimal(pid)?,
            parse_canonical_positive_decimal(counter)?,
        ))
    }

    #[cfg(debug_assertions)]
    fn parse_canonical_positive_decimal<T>(text: &str) -> Option<T>
    where
        T: std::str::FromStr + ToString,
    {
        if text.is_empty()
            || text.starts_with('0')
            || !text.bytes().all(|byte| byte.is_ascii_digit())
        {
            return None;
        }
        let value = text.parse::<T>().ok()?;
        (value.to_string() == text).then_some(value)
    }

    #[cfg(debug_assertions)]
    fn signal_connect_ready_with(
        configured_name: Result<String, std::env::VarError>,
        stdin_is_terminal: bool,
        ctrl_handler_installed: bool,
        console_mode_held: bool,
        open_and_signal: impl FnOnce(&str) -> Result<(), HostError>,
    ) -> Result<(), HostError> {
        let name = match configured_name {
            Ok(name) => name,
            Err(std::env::VarError::NotPresent) => return Ok(()),
            Err(std::env::VarError::NotUnicode(_)) => return Err(HostError::Transport),
        };
        parse_connect_ready_event_name(&name).ok_or(HostError::Transport)?;
        if !stdin_is_terminal || !ctrl_handler_installed || !console_mode_held {
            return Err(HostError::Transport);
        }
        open_and_signal(&name)
    }

    #[cfg(debug_assertions)]
    fn signal_connect_ready(session: &ConsoleSession) -> Result<(), HostError> {
        signal_connect_ready_with(
            std::env::var(CONNECT_READY_EVENT_ENV),
            session.terminal_input(),
            session.handler_ready(),
            session.console_mode_held(),
            |name| {
                let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
                let event = unsafe {
                    OwnedHandle::from_raw(OpenEventW(EVENT_MODIFY_STATE, 0, wide.as_ptr()))
                }
                .map_err(map_io)?;
                if unsafe { SetEvent(event.raw()) } == 0 {
                    return Err(HostError::Transport);
                }
                Ok(())
            },
        )
    }

    enum InputMessage {
        Line(Vec<u8>),
        Eof,
        Failed,
        TooLarge,
    }

    struct InputPump {
        receiver: mpsc::Receiver<InputMessage>,
        ready: Arc<CancelEvent>,
    }

    impl InputPump {
        fn start() -> Result<Self, HostError> {
            let ready = Arc::new(CancelEvent::new().map_err(map_io)?);
            let signal = ready.clone();
            let (sender, receiver) = mpsc::sync_channel(0);
            std::thread::spawn(move || {
                let stdin = std::io::stdin();
                let mut input = stdin.lock();
                loop {
                    let message = match read_bounded_line(&mut input) {
                        Ok(Some(line)) => InputMessage::Line(line),
                        Ok(None) => InputMessage::Eof,
                        Err(LineError::TooLarge) => InputMessage::TooLarge,
                        Err(LineError::Io) => InputMessage::Failed,
                    };
                    let terminal = !matches!(message, InputMessage::Line(_));
                    signal.signal();
                    if sender.send(message).is_err() {
                        return;
                    }
                    if terminal {
                        return;
                    }
                }
            });
            Ok(Self { receiver, ready })
        }

        fn next(&self, cancel: &CancelEvent) -> Result<Option<Vec<u8>>, HostError> {
            let handles = [cancel.raw(), self.ready.raw()];
            let wait = unsafe {
                WaitForMultipleObjects(handles.len() as u32, handles.as_ptr(), 0, INFINITE)
            };
            if wait == 0 {
                return Err(HostError::Cancelled);
            }
            if wait != 1 || unsafe { ResetEvent(self.ready.raw()) } == 0 {
                return Err(HostError::Transport);
            }
            match self.receiver.recv() {
                Ok(InputMessage::Line(line)) => Ok(Some(line)),
                Ok(InputMessage::Eof) => Ok(None),
                Ok(InputMessage::TooLarge) => Err(HostError::Protocol),
                Ok(InputMessage::Failed) | Err(_) => Err(HostError::Transport),
            }
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum LineError {
        Io,
        TooLarge,
    }

    fn read_bounded_line(reader: &mut impl BufRead) -> Result<Option<Vec<u8>>, LineError> {
        let mut line = Vec::new();
        loop {
            let available = reader.fill_buf().map_err(|_| LineError::Io)?;
            if available.is_empty() {
                return if line.is_empty() {
                    Ok(None)
                } else if line.len() <= MAX_MESSAGE_BYTES {
                    Ok(Some(line))
                } else {
                    Err(LineError::TooLarge)
                };
            }

            if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
                let payload = &available[..newline];
                if line.len().saturating_add(payload.len()) > MAX_MESSAGE_BYTES + 1 {
                    return Err(LineError::TooLarge);
                }
                line.extend_from_slice(payload);
                reader.consume(newline + 1);
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return if line.len() <= MAX_MESSAGE_BYTES {
                    Ok(Some(line))
                } else {
                    Err(LineError::TooLarge)
                };
            }

            if line.len().saturating_add(available.len()) > MAX_MESSAGE_BYTES + 1 {
                return Err(LineError::TooLarge);
            }
            let consumed = available.len();
            line.extend_from_slice(available);
            reader.consume(consumed);
        }
    }

    pub(crate) fn drive_requests(
        handle: OwnedHandle,
        cancel: &CancelEvent,
        extension_discovery: Option<(&Discovery, &str)>,
    ) -> Result<(), HostError> {
        let pump = InputPump::start()?;
        drive_requests_with_pump(handle, cancel, pump, extension_discovery)
    }

    fn drive_requests_with_pump(
        handle: OwnedHandle,
        cancel: &CancelEvent,
        pump: InputPump,
        extension_discovery: Option<(&Discovery, &str)>,
    ) -> Result<(), HostError> {
        let mut stdout = std::io::stdout().lock();
        let mut stderr = std::io::stderr().lock();
        drive_requests_with_io_guarded(
            cancel,
            |cancel| pump.next(cancel),
            |payload, cancel| {
                write_frame(handle.raw(), payload, &[cancel.raw()]).map_err(map_io)?;
                read_frame(handle.raw(), &[cancel.raw()]).map_err(map_io)
            },
            &mut stdout,
            &mut stderr,
            extension_discovery,
        )
    }

    fn drive_requests_with_io(
        cancel: &CancelEvent,
        next_line: impl FnMut(&CancelEvent) -> Result<Option<Vec<u8>>, HostError>,
        roundtrip: impl FnMut(&[u8], &CancelEvent) -> Result<Vec<u8>, HostError>,
        stdout: &mut impl Write,
    ) -> Result<(), HostError> {
        drive_requests_with_io_guarded(cancel, next_line, roundtrip, stdout, &mut std::io::sink(), None)
    }

    fn drive_requests_with_io_guarded(
        cancel: &CancelEvent,
        mut next_line: impl FnMut(&CancelEvent) -> Result<Option<Vec<u8>>, HostError>,
        mut roundtrip: impl FnMut(&[u8], &CancelEvent) -> Result<Vec<u8>, HostError>,
        stdout: &mut impl Write,
        diagnostics: &mut impl Write,
        extension_discovery: Option<(&Discovery, &str)>,
    ) -> Result<(), HostError> {
        let mut extension_available = None;
        while let Some(line) = next_line(cancel)? {
            let request = parse_request(&line).map_err(|_| HostError::Protocol)?;
            if !artifact_request_admitted(&request, extension_discovery, cancel, &mut extension_available) {
                // Discovery is optional. Report the unavailable extension
                // locally without consuming or closing the owner channel.
                diagnostics.write_all(b"winsmux workspace: protocol_failed\n")
                    .and_then(|_| diagnostics.flush())
                    .map_err(|_| HostError::Transport)?;
                continue;
            }
            let payload = canonical_request(&request).map_err(|_| HostError::Protocol)?;
            let response_bytes = roundtrip(&payload, cancel)?;
            let response =
                parse_response(&request, &response_bytes).map_err(|_| HostError::Protocol)?;
            let output =
                serialize_response(&request, &response).map_err(|_| HostError::Protocol)?;
            stdout
                .write_all(&output)
                .map_err(|_| HostError::Transport)?;
            stdout
                .write_all(b"\n")
                .and_then(|_| stdout.flush())
                .map_err(|_| HostError::Transport)?;
            if matches!(
                (&request.action, response.accepted, response.result.0.as_ref()),
                (
                    crate::contract::Action::HostStop(_),
                    true,
                    Some(crate::contract::Success::HostStop(_)),
                ),
            ) {
                return Ok(());
            }
        }
        Ok(())
    }

    pub(crate) fn artifact_request_admitted(
        request: &crate::contract::Request,
        extension_discovery: Option<(&Discovery, &str)>,
        cancel: &CancelEvent,
        cached_availability: &mut Option<bool>,
    ) -> bool {
        if !matches!(
            request.action,
            crate::contract::Action::ArtifactChoose(_)
                | crate::contract::Action::ArtifactChoiceList(_)
        ) {
            return true;
        }
        *cached_availability.get_or_insert_with(|| {
            extension_discovery.is_some_and(|(discovery, fingerprint)| {
                probe_artifact_review(discovery, fingerprint, cancel)
            })
        })
    }

    #[cfg(test)]
    mod drive_request_stop_tests {
        use super::{
            canonical_request, drive_requests_with_io, drive_requests_with_io_guarded,
            parse_response, serialize_response,
            CancelEvent, HostError,
        };
        use crate::contract::ingress::TestFixture;
        use crate::contract::{
            Action, Empty, ErrorCode, HostStopData, InstanceId, LayoutSaveData, Nullable,
            OperationId, ProjectId, ProjectParams, Request, Response, Success, True, U, Version,
        };
        use std::cell::Cell;
        use std::collections::VecDeque;
        use std::io::{self, Write};

        #[derive(Debug, Clone, Copy)]
        enum OutputFault {
            WriteOutput,
            PartialOutput,
            WriteNewline,
            Flush,
        }

        struct FaultingWriter {
            captured: Vec<u8>,
            fault: OutputFault,
            write_calls: usize,
            flushed: bool,
        }

        impl Write for FaultingWriter {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.write_calls += 1;
                match (self.fault, self.write_calls) {
                    (OutputFault::WriteOutput, 1) => {
                        Err(io::Error::new(io::ErrorKind::Other, "output write"))
                    }
                    (OutputFault::PartialOutput, 1) => {
                        let n = 1.min(buf.len());
                        self.captured.extend_from_slice(&buf[..n]);
                        Ok(n)
                    }
                    (OutputFault::PartialOutput, _) => {
                        Err(io::Error::new(io::ErrorKind::Other, "partial output"))
                    }
                    (OutputFault::WriteNewline, 2) => {
                        Err(io::Error::new(io::ErrorKind::Other, "newline write"))
                    }
                    _ => {
                        self.captured.extend_from_slice(buf);
                        Ok(buf.len())
                    }
                }
            }

            fn flush(&mut self) -> io::Result<()> {
                if matches!(self.fault, OutputFault::Flush) {
                    return Err(io::Error::new(io::ErrorKind::Other, "flush"));
                }
                self.flushed = true;
                Ok(())
            }
        }

        fn owner_request(action: Action) -> Request {
            Request {
                schema_version: Version::new(1).expect("schema version 1"),
                instance_id: Nullable(Some(InstanceId::test_fixture())),
                operation_id: OperationId::test_fixture(),
                expected_topology_revision: Nullable(None),
                action,
            }
        }

        fn correlated_success(request: &Request, result: Success) -> Response {
            Response {
                schema_version: request.schema_version.clone(),
                instance_id: request
                    .instance_id
                    .0
                    .clone()
                    .expect("owner instance id"),
                operation_id: request.operation_id.clone(),
                accepted: true,
                topology_revision: U::test_fixture(),
                event_seq: U::test_fixture(),
                result: Nullable(Some(result)),
                error: Nullable(None),
            }
        }

        fn correlated_error(request: &Request, code: ErrorCode) -> Response {
            Response {
                schema_version: request.schema_version.clone(),
                instance_id: request
                    .instance_id
                    .0
                    .clone()
                    .expect("owner instance id"),
                operation_id: request.operation_id.clone(),
                accepted: false,
                topology_revision: U::test_fixture(),
                event_seq: U::test_fixture(),
                result: Nullable(None),
                error: Nullable(Some(code.with_target(None).expect("wire error"))),
            }
        }

        fn host_stop_success(request: &Request) -> Response {
            correlated_success(
                request,
                Success::HostStop(HostStopData {
                    stopped: True,
                    saved_generation: U::test_fixture(),
                    saved_topology_revision: U::test_fixture(),
                }),
            )
        }

        fn layout_save_success(request: &Request) -> Response {
            correlated_success(
                request,
                Success::LayoutSave(LayoutSaveData {
                    generation: U::test_fixture(),
                    saved_topology_revision: U::test_fixture(),
                }),
            )
        }

        fn drive_script(
            mut inputs: VecDeque<Result<Option<Vec<u8>>, HostError>>,
            mut roundtrips: VecDeque<Result<Vec<u8>, HostError>>,
            stdout: &mut impl Write,
        ) -> (Result<(), HostError>, usize) {
            let cancel = CancelEvent::new().expect("test cancel event");
            let reads = Cell::new(0usize);
            let result = drive_requests_with_io(
                &cancel,
                |_| {
                    reads.set(reads.get() + 1);
                    inputs
                        .pop_front()
                        .expect("unexpected additional stdin read")
                },
                |_, _| {
                    roundtrips
                        .pop_front()
                        .expect("missing scripted roundtrip")
                },
                stdout,
            );
            (result, reads.get())
        }

        fn framed(payload: &[u8]) -> Vec<u8> {
            let mut line = payload.to_vec();
            line.push(b'\n');
            line
        }

        #[test]
        fn unavailable_extension_never_enters_the_v1_roundtrip() {
            let extension = owner_request(Action::ArtifactChoiceList(ProjectParams {
                project_id: ProjectId::test_fixture(),
            }));
            let stop = owner_request(Action::HostStop(Empty {}));
            let stop_line = canonical_request(&stop).unwrap();
            let stop_bytes = serialize_response(&stop, &host_stop_success(&stop)).unwrap();
            let mut inputs = VecDeque::from([
                Some(canonical_request(&extension).unwrap()), Some(stop_line.clone()),
            ]);
            let cancel = CancelEvent::new().unwrap();
            let reads = Cell::new(0);
            let roundtrips = Cell::new(0);
            let mut output = Vec::new();
            let mut diagnostics = Vec::new();
            let result = drive_requests_with_io_guarded(
                &cancel,
                |_| { reads.set(reads.get() + 1); Ok(inputs.pop_front().expect("input")) },
                |payload, _| {
                    roundtrips.set(roundtrips.get() + 1);
                    assert_eq!(payload, stop_line);
                    Ok(stop_bytes.clone())
                },
                &mut output, &mut diagnostics, None,
            );
            assert_eq!(result, Ok(()));
            assert_eq!(reads.get(), 2);
            assert_eq!(roundtrips.get(), 1);
            assert_eq!(output, framed(&stop_bytes));
            assert_eq!(diagnostics, b"winsmux workspace: protocol_failed\n");
        }

        #[test]
        fn host_stop_success_returns_after_flush_without_another_input() {
            let request = owner_request(Action::HostStop(Empty {}));
            let line = canonical_request(&request).expect("host.stop request");
            let response_bytes = serialize_response(&request, &host_stop_success(&request))
                .expect("host.stop success");
            let mut stdout = Vec::new();
            let (result, reads) = drive_script(
                VecDeque::from([Ok(Some(line))]),
                VecDeque::from([Ok(response_bytes.clone())]),
                &mut stdout,
            );
            assert_eq!(result, Ok(()));
            assert_eq!(reads, 1);
            assert_eq!(stdout, framed(&response_bytes));
        }

        #[test]
        fn failed_host_stop_and_other_success_keep_reading() {
            let failed_request = owner_request(Action::HostStop(Empty {}));
            let failed_line = canonical_request(&failed_request).expect("host.stop request");
            let failed_bytes = serialize_response(
                &failed_request,
                &correlated_error(&failed_request, ErrorCode::PersistenceFailed),
            )
            .expect("failed host.stop");

            let save_request = owner_request(Action::LayoutSave(Empty {}));
            let save_line = canonical_request(&save_request).expect("layout.save request");
            let save_bytes =
                serialize_response(&save_request, &layout_save_success(&save_request))
                    .expect("layout.save success");

            let stop_request = owner_request(Action::HostStop(Empty {}));
            let stop_line = canonical_request(&stop_request).expect("host.stop request");
            let stop_bytes = serialize_response(&stop_request, &host_stop_success(&stop_request))
                .expect("host.stop success");

            let mut stdout = Vec::new();
            let (result, reads) = drive_script(
                VecDeque::from([
                    Ok(Some(failed_line)),
                    Ok(Some(save_line)),
                    Ok(Some(stop_line)),
                ]),
                VecDeque::from([
                    Ok(failed_bytes.clone()),
                    Ok(save_bytes.clone()),
                    Ok(stop_bytes.clone()),
                ]),
                &mut stdout,
            );
            assert_eq!(result, Ok(()));
            assert_eq!(reads, 3);
            let mut expected = framed(&failed_bytes);
            expected.extend_from_slice(&framed(&save_bytes));
            expected.extend_from_slice(&framed(&stop_bytes));
            assert_eq!(stdout, expected);
        }

        #[test]
        fn stopped_false_malformed_and_mismatched_responses_are_protocol() {
            let request = owner_request(Action::HostStop(Empty {}));
            let line = canonical_request(&request).expect("host.stop request");
            let success_bytes = serialize_response(&request, &host_stop_success(&request))
                .expect("host.stop success");

            let mut stdout = Vec::new();
            let (result, reads) = drive_script(
                VecDeque::from([Ok(Some(b"{".to_vec()))]),
                VecDeque::new(),
                &mut stdout,
            );
            assert_eq!(result, Err(HostError::Protocol));
            assert_eq!(reads, 1);
            assert!(stdout.is_empty());

            let mut stopped_false: serde_json::Value =
                serde_json::from_slice(&success_bytes).expect("json");
            stopped_false["result"]["data"]["stopped"] = serde_json::Value::Bool(false);
            let stopped_false_bytes =
                serde_json::to_vec(&stopped_false).expect("stopped false json");
            assert!(
                parse_response(&request, &stopped_false_bytes).is_err(),
                "codec must reject stopped:false"
            );

            let mut mismatched: serde_json::Value =
                serde_json::from_slice(&success_bytes).expect("json");
            let mut operation_id = mismatched["operation_id"]
                .as_str()
                .expect("operation_id")
                .to_owned();
            let last = operation_id.pop().expect("operation_id char");
            operation_id.push(if last == '0' { '1' } else { '0' });
            mismatched["operation_id"] = serde_json::Value::String(operation_id);
            let mismatched_bytes = serde_json::to_vec(&mismatched).expect("mismatched json");
            assert!(parse_response(&request, &mismatched_bytes).is_err());

            let operation_mismatch =
                serde_json::to_vec(&layout_save_success(&request)).expect("operation mismatch");
            assert!(parse_response(&request, &operation_mismatch).is_err());

            for response_bytes in [
                &b"not-json"[..],
                stopped_false_bytes.as_slice(),
                mismatched_bytes.as_slice(),
                operation_mismatch.as_slice(),
            ] {
                let mut stdout = Vec::new();
                let (result, reads) = drive_script(
                    VecDeque::from([Ok(Some(line.clone()))]),
                    VecDeque::from([Ok(response_bytes.to_vec())]),
                    &mut stdout,
                );
                assert_eq!(result, Err(HostError::Protocol));
                assert_eq!(reads, 1);
                assert!(stdout.is_empty());
            }
        }

        #[test]
        fn partial_output_newline_and_flush_failures_are_transport() {
            let request = owner_request(Action::HostStop(Empty {}));
            let line = canonical_request(&request).expect("host.stop request");
            let response_bytes = serialize_response(&request, &host_stop_success(&request))
                .expect("host.stop success");
            for fault in [
                OutputFault::WriteOutput,
                OutputFault::PartialOutput,
                OutputFault::WriteNewline,
                OutputFault::Flush,
            ] {
                let mut stdout = FaultingWriter {
                    captured: Vec::new(),
                    fault,
                    write_calls: 0,
                    flushed: false,
                };
                let (result, reads) = drive_script(
                    VecDeque::from([Ok(Some(line.clone()))]),
                    VecDeque::from([Ok(response_bytes.clone())]),
                    &mut stdout,
                );
                assert_eq!(result, Err(HostError::Transport), "{fault:?}");
                assert_eq!(reads, 1, "{fault:?}");
                assert!(!stdout.flushed, "{fault:?}");
                match fault {
                    OutputFault::WriteOutput => {
                        assert!(stdout.captured.is_empty(), "{fault:?}")
                    }
                    OutputFault::PartialOutput => {
                        assert_eq!(stdout.captured.len(), 1, "{fault:?}")
                    }
                    OutputFault::WriteNewline => {
                        assert_eq!(stdout.captured, response_bytes, "{fault:?}")
                    }
                    OutputFault::Flush => {
                        assert_eq!(stdout.captured, framed(&response_bytes), "{fault:?}")
                    }
                }
            }
        }

        #[test]
        fn cancelled_and_roundtrip_transport_do_not_claim_stop() {
            let request = owner_request(Action::HostStop(Empty {}));
            let line = canonical_request(&request).expect("host.stop request");
            let response_bytes = serialize_response(&request, &host_stop_success(&request))
                .expect("host.stop success");

            let mut stdout = Vec::new();
            let (result, reads) = drive_script(
                VecDeque::from([Err(HostError::Cancelled)]),
                VecDeque::from([Ok(response_bytes.clone())]),
                &mut stdout,
            );
            assert_eq!(result, Err(HostError::Cancelled));
            assert_eq!(reads, 1);
            assert!(stdout.is_empty());

            let mut stdout = Vec::new();
            let (result, reads) = drive_script(
                VecDeque::from([Ok(Some(line))]),
                VecDeque::from([Err(HostError::Transport)]),
                &mut stdout,
            );
            assert_eq!(result, Err(HostError::Transport));
            assert_eq!(reads, 1);
            assert!(stdout.is_empty());
        }
    }

    pub fn run_connect() -> Result<(), HostError> {
        let session = ConsoleSession::start()?;
        let result = (|| {
            let pump = InputPump::start()?;
            #[cfg(debug_assertions)]
            signal_connect_ready(&session)?;
            let Some(discovery_line) = pump.next(session.cancel())? else {
                return Ok(());
            };
            let discovery: Discovery =
                serde_json::from_slice(&discovery_line).map_err(|_| HostError::Protocol)?;
            let mut client = PublicClient::connect_event(&discovery, session.cancel())?;
            let mut stdout = std::io::stdout().lock();
            let mut stderr = std::io::stderr().lock();
            while let Some(line) = pump.next(session.cancel())? {
                let request = parse_request(&line).map_err(|_| HostError::Protocol)?;
                let response = match client.request_event(&request, session.cancel()) {
                    Ok(response) => response,
                    Err(PublicRequestError::ProtocolFailed) => {
                        stderr.write_all(b"winsmux workspace: protocol_failed\n")
                            .and_then(|_| stderr.flush()).map_err(|_| HostError::Transport)?;
                        continue;
                    }
                    Err(PublicRequestError::TransportUncertain(error)) => return Err(error),
                };
                let output = serialize_response(&request, &response).map_err(|_| HostError::Protocol)?;
                stdout.write_all(&output).and_then(|_| stdout.write_all(b"\n"))
                    .and_then(|_| stdout.flush()).map_err(|_| HostError::Transport)?;
                if matches!((&request.action, response.accepted, response.result.0.as_ref()),
                    (crate::contract::Action::HostStop(_), true, Some(crate::contract::Success::HostStop(_)))) {
                    return Ok(());
                }
            }
            Ok(())
        })();
        session.finish(result)
    }

    /// A monotonic signal. It cannot expose a pipe or restore a cancelled call.
    #[derive(Clone)]
    pub struct PublicCancellation(Arc<CancelEvent>);

    impl PublicCancellation {
        pub fn new() -> Result<Self, HostError> {
            Ok(Self(Arc::new(CancelEvent::new().map_err(map_io)?)))
        }
        pub fn cancel(&self) { self.0.signal(); }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum PublicRequestError {
        ProtocolFailed,
        TransportUncertain(HostError),
    }

    /// One authenticated public connection and one frame producer. Never cloned.
    pub struct PublicClient {
        handle: OwnedHandle,
        discovery: Discovery,
        fingerprint: String,
        extension_available: Option<bool>,
        poisoned: bool,
    }

    impl PublicClient {
        pub fn connect(discovery: &Discovery, cancel: &PublicCancellation) -> Result<Self, HostError> {
            Self::connect_event(discovery, &cancel.0)
        }
        fn connect_event(discovery: &Discovery, cancel: &CancelEvent) -> Result<Self, HostError> {
            if unsafe { windows_sys::Win32::System::Threading::WaitForSingleObject(cancel.raw(), 0) }
                != windows_sys::Win32::Foundation::WAIT_TIMEOUT { return Err(HostError::Cancelled); }
            let identity = Identity::current().map_err(map_io)?;
            let fingerprint = discovery.validate_for(&identity)?.to_owned();
            let handle = connect(&discovery.pipe_name)?;
            authenticate_server(&handle, discovery, &fingerprint, cancel)?;
            if unsafe { windows_sys::Win32::System::Threading::WaitForSingleObject(cancel.raw(), 0) }
                != windows_sys::Win32::Foundation::WAIT_TIMEOUT { return Err(HostError::Cancelled); }
            Ok(Self { handle, discovery: discovery.clone(), fingerprint, extension_available: None, poisoned: false })
        }
        pub fn request(&mut self, request: &crate::contract::Request, cancel: &PublicCancellation)
            -> Result<crate::contract::Response, PublicRequestError> {
            self.request_event(request, &cancel.0)
        }
        fn request_event(&mut self, request: &crate::contract::Request, cancel: &CancelEvent)
            -> Result<crate::contract::Response, PublicRequestError> {
            if self.poisoned { return Err(PublicRequestError::TransportUncertain(HostError::Transport)); }
            let payload = canonical_request(request).map_err(|_| PublicRequestError::ProtocolFailed)?;
            if !artifact_request_admitted(request, Some((&self.discovery, &self.fingerprint)), cancel,
                &mut self.extension_available) { return Err(PublicRequestError::ProtocolFailed); }
            let result = (|| {
                write_frame(self.handle.raw(), &payload, &[cancel.raw()]).map_err(map_io)?;
                let bytes = read_frame(self.handle.raw(), &[cancel.raw()]).map_err(map_io)?;
                parse_response(request, &bytes).map_err(|_| HostError::Protocol)
            })();
            result.map_err(|error| { self.poisoned = true; PublicRequestError::TransportUncertain(error) })
        }
    }

    pub(crate) fn connect(pipe_name: &str) -> Result<OwnedHandle, HostError> {
        let wide: Vec<u16> = pipe_name.encode_utf16().chain(std::iter::once(0)).collect();
        let handle = unsafe {
            CreateFileW(
                wide.as_ptr(),
                PIPE_DATA_ACCESS,
                0,
                null_mut(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(HostError::Transport);
        }
        unsafe { OwnedHandle::from_raw(handle) }.map_err(map_io)
    }

    fn authenticate_server(
        handle: &OwnedHandle,
        discovery: &Discovery,
        expected_fingerprint: &str,
        cancel: &CancelEvent,
    ) -> Result<(), HostError> {
        let mut server_pid = 0u32;
        if unsafe { GetNamedPipeServerProcessId(handle.raw(), &mut server_pid) } == 0
            || server_pid == 0
        {
            return Err(HostError::Transport);
        }
        let challenge = random_challenge().map_err(map_io)?;
        let request = encode_request(&challenge);
        debug_assert_eq!(request.len(), AUTH_REQUEST_BYTES);
        write_frame(handle.raw(), &request, &[cancel.raw()]).map_err(map_io)?;
        let response = read_frame(handle.raw(), &[cancel.raw()]).map_err(map_io)?;
        verify_response(
            &response,
            expected_fingerprint,
            &discovery.instance_id,
            &discovery.pipe_name,
            &challenge,
            unsafe { GetCurrentProcessId() },
            server_pid,
        )
        .map_err(map_io)
    }

    pub(crate) fn probe_artifact_review(
        discovery: &Discovery,
        expected_fingerprint: &str,
        cancel: &CancelEvent,
    ) -> bool {
        let mut sidecar = discovery.clone();
        sidecar.pipe_name = discovery.artifact_review_pipe_name();
        let Ok(handle) = connect(&sidecar.pipe_name) else { return false };
        if authenticate_server(&handle, &sidecar, expected_fingerprint, cancel).is_err() {
            return false;
        }

        matches!(read_frame(handle.raw(), &[cancel.raw()]), Ok(frame) if frame == b"artifact_review_v1")
    }

    pub(crate) fn map_io(error: IoError) -> HostError {
        match error {
            IoError::Cancelled => HostError::Cancelled,
            IoError::Protocol => HostError::Protocol,
            IoError::Eof | IoError::Failed => HostError::Transport,
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::cell::Cell;
        use std::collections::VecDeque;
        #[cfg(debug_assertions)]
        use std::ffi::OsString;
        use std::io::Cursor;
        #[cfg(debug_assertions)]
        use std::os::windows::ffi::OsStringExt;

        #[derive(Debug, Clone, PartialEq, Eq)]
        enum ConsoleCall {
            AddHandler,
            ClearInheritedIgnore,
            RemoveHandler,
            InputHandle,
            GetMode,
            SetMode(u32),
        }

        struct FakeConsoleState {
            calls: Vec<ConsoleCall>,
            add_handler: VecDeque<bool>,
            clear_inherited_ignore: VecDeque<bool>,
            remove_handler: VecDeque<bool>,
            input_handle: usize,
            get_mode: VecDeque<Option<u32>>,
            set_mode: VecDeque<bool>,
        }

        impl Default for FakeConsoleState {
            fn default() -> Self {
                Self {
                    calls: Vec::new(),
                    add_handler: VecDeque::new(),
                    clear_inherited_ignore: VecDeque::new(),
                    remove_handler: VecDeque::new(),
                    input_handle: 1,
                    get_mode: VecDeque::from([Some(0x4000 | ENABLE_ECHO_INPUT)]),
                    set_mode: VecDeque::new(),
                }
            }
        }

        #[derive(Clone)]
        struct FakeConsoleOperations {
            state: Arc<Mutex<FakeConsoleState>>,
        }

        impl FakeConsoleOperations {
            fn new(
                configure: impl FnOnce(&mut FakeConsoleState),
            ) -> (Self, Arc<Mutex<FakeConsoleState>>) {
                let mut state = FakeConsoleState::default();
                configure(&mut state);
                let state = Arc::new(Mutex::new(state));
                (
                    Self {
                        state: state.clone(),
                    },
                    state,
                )
            }

            fn with_state<T>(&self, action: impl FnOnce(&mut FakeConsoleState) -> T) -> T {
                let mut state = match self.state.lock() {
                    Ok(state) => state,
                    Err(poisoned) => poisoned.into_inner(),
                };
                action(&mut state)
            }
        }

        impl ConsoleOperations for FakeConsoleOperations {
            fn add_handler(&self) -> bool {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::AddHandler);
                    state.add_handler.pop_front().unwrap_or(true)
                })
            }

            fn clear_inherited_ignore(&self) -> bool {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::ClearInheritedIgnore);
                    state.clear_inherited_ignore.pop_front().unwrap_or(true)
                })
            }

            fn remove_handler(&self) -> bool {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::RemoveHandler);
                    state.remove_handler.pop_front().unwrap_or(true)
                })
            }

            fn input_handle(&self) -> HANDLE {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::InputHandle);
                    state.input_handle as HANDLE
                })
            }

            fn get_mode(&self, _handle: HANDLE) -> Option<u32> {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::GetMode);
                    state.get_mode.pop_front().unwrap_or(Some(0))
                })
            }

            fn set_mode(&self, _handle: HANDLE, mode: u32) -> bool {
                self.with_state(|state| {
                    state.calls.push(ConsoleCall::SetMode(mode));
                    state.set_mode.pop_front().unwrap_or(true)
                })
            }
        }

        fn cancel_event() -> Arc<CancelEvent> {
            Arc::new(CancelEvent::new().expect("create test cancellation event"))
        }

        fn calls(state: &Arc<Mutex<FakeConsoleState>>) -> Vec<ConsoleCall> {
            match state.lock() {
                Ok(state) => state.calls.clone(),
                Err(poisoned) => poisoned.into_inner().calls.clone(),
            }
        }

        #[test]
        fn bounded_lines_accept_lf_crlf_and_exact_limit() {
            let mut lf = Cursor::new(b"{}\nnext".to_vec());
            assert_eq!(read_bounded_line(&mut lf), Ok(Some(b"{}".to_vec())));
            assert_eq!(read_bounded_line(&mut lf), Ok(Some(b"next".to_vec())));
            assert_eq!(read_bounded_line(&mut lf), Ok(None));

            let mut crlf = Cursor::new(b"{}\r\n".to_vec());
            assert_eq!(read_bounded_line(&mut crlf), Ok(Some(b"{}".to_vec())));

            let mut exact = Cursor::new(
                std::iter::repeat_n(b'x', MAX_MESSAGE_BYTES)
                    .chain([b'\r', b'\n'])
                    .collect::<Vec<_>>(),
            );
            assert_eq!(
                read_bounded_line(&mut exact).map(|line| line.unwrap().len()),
                Ok(MAX_MESSAGE_BYTES)
            );
        }

        #[test]
        fn bounded_lines_reject_payload_over_limit() {
            let mut input = Cursor::new(
                std::iter::repeat_n(b'x', MAX_MESSAGE_BYTES + 1)
                    .chain([b'\n'])
                    .collect::<Vec<_>>(),
            );
            assert_eq!(read_bounded_line(&mut input), Err(LineError::TooLarge));
        }

        #[test]
        fn redirected_input_does_not_touch_console_mode() {
            let registry = Mutex::new(None);
            let (operations, state) = FakeConsoleOperations::new(|_| {});
            let cancel = cancel_event();
            let mut session =
                ConsoleSessionState::start_with(cancel.clone(), false, &registry, operations)
                    .expect("redirected session");
            assert_eq!(
                calls(&state),
                vec![ConsoleCall::AddHandler, ConsoleCall::ClearInheritedIgnore]
            );
            assert!(lock_cancel_target(&registry)
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, &cancel)));
            assert_eq!(
                dispatch_ctrl_event_with(CTRL_C_EVENT, &registry, |target| {
                    assert!(Arc::ptr_eq(&target, &cancel));
                }),
                1
            );
            assert_eq!(session.finish(Ok(())), Ok(()));
            assert_eq!(
                calls(&state),
                vec![
                    ConsoleCall::AddHandler,
                    ConsoleCall::ClearInheritedIgnore,
                    ConsoleCall::RemoveHandler,
                ]
            );
            assert!(lock_cancel_target(&registry).is_none());
        }

        #[test]
        fn console_mode_formula_covers_processed_line_and_echo_boundaries() {
            let unrelated = 0x4000_0000;
            for processed in [false, true] {
                for line in [false, true] {
                    for echo in [false, true] {
                        let mut original = unrelated;
                        if processed {
                            original |= ENABLE_PROCESSED_INPUT;
                        }
                        if line {
                            original |= ENABLE_LINE_INPUT;
                        }
                        if echo {
                            original |= ENABLE_ECHO_INPUT;
                        }
                        assert_eq!(
                            managed_console_mode(original),
                            unrelated | ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT,
                            "processed={processed} line={line} echo={echo}"
                        );
                    }
                }
            }
        }

        #[test]
        fn console_session_applies_every_mode_combination_and_restores_exactly() {
            let unrelated = 0x2000_0000;
            for processed in [false, true] {
                for line in [false, true] {
                    for echo in [false, true] {
                        let mut original = unrelated;
                        if processed {
                            original |= ENABLE_PROCESSED_INPUT;
                        }
                        if line {
                            original |= ENABLE_LINE_INPUT;
                        }
                        if echo {
                            original |= ENABLE_ECHO_INPUT;
                        }
                        let registry = Mutex::new(None);
                        let (operations, state) = FakeConsoleOperations::new(|state| {
                            state.get_mode = VecDeque::from([Some(original)]);
                        });
                        let mut session = ConsoleSessionState::start_with(
                            cancel_event(),
                            true,
                            &registry,
                            operations,
                        )
                        .expect("terminal session");
                        assert_eq!(session.finish(Ok(())), Ok(()));
                        let set_modes = calls(&state)
                            .into_iter()
                            .filter_map(|call| match call {
                                ConsoleCall::SetMode(mode) => Some(mode),
                                _ => None,
                            })
                            .collect::<Vec<_>>();
                        assert_eq!(
                            set_modes,
                            vec![managed_console_mode(original), original],
                            "processed={processed} line={line} echo={echo}"
                        );
                        assert!(lock_cancel_target(&registry).is_none());
                    }
                }
            }
        }

        #[test]
        fn terminal_registration_and_mode_failures_finish_partial_state() {
            let registry = Mutex::new(None);
            let (operations, state) = FakeConsoleOperations::new(|state| {
                state.add_handler = VecDeque::from([false]);
            });
            assert_eq!(
                ConsoleSessionState::start_with(cancel_event(), true, &registry, operations,).err(),
                Some(HostError::Startup)
            );
            assert_eq!(calls(&state), vec![ConsoleCall::AddHandler]);
            assert!(lock_cancel_target(&registry).is_none());

            for (remove_results, expected_remove_calls) in
                [(vec![true], 1usize), (vec![false, false], 2usize)]
            {
                let registry = Mutex::new(None);
                let (operations, state) = FakeConsoleOperations::new(|state| {
                    state.clear_inherited_ignore = VecDeque::from([false]);
                    state.remove_handler = remove_results.into();
                });
                assert_eq!(
                    ConsoleSessionState::start_with(cancel_event(), true, &registry, operations,)
                        .err(),
                    Some(HostError::Startup)
                );
                assert_eq!(
                    calls(&state),
                    [ConsoleCall::AddHandler, ConsoleCall::ClearInheritedIgnore,]
                        .into_iter()
                        .chain(std::iter::repeat_n(
                            ConsoleCall::RemoveHandler,
                            expected_remove_calls,
                        ))
                        .collect::<Vec<_>>()
                );
                assert!(lock_cancel_target(&registry).is_none());
            }

            for input_handle in [0usize, usize::MAX] {
                let registry = Mutex::new(None);
                let (operations, state) = FakeConsoleOperations::new(|state| {
                    state.input_handle = input_handle;
                });
                assert_eq!(
                    ConsoleSessionState::start_with(cancel_event(), true, &registry, operations,)
                        .err(),
                    Some(HostError::Startup)
                );
                assert!(!calls(&state).contains(&ConsoleCall::GetMode));
                assert!(!calls(&state)
                    .iter()
                    .any(|call| matches!(call, ConsoleCall::SetMode(_))));
                assert_eq!(calls(&state).last(), Some(&ConsoleCall::RemoveHandler));
                assert!(lock_cancel_target(&registry).is_none());
            }

            let registry = Mutex::new(None);
            let (operations, state) = FakeConsoleOperations::new(|state| {
                state.get_mode = VecDeque::from([None]);
            });
            assert_eq!(
                ConsoleSessionState::start_with(cancel_event(), true, &registry, operations,).err(),
                Some(HostError::Startup)
            );
            assert!(!calls(&state)
                .iter()
                .any(|call| matches!(call, ConsoleCall::SetMode(_))));
            assert_eq!(calls(&state).last(), Some(&ConsoleCall::RemoveHandler));
            assert!(lock_cancel_target(&registry).is_none());

            let registry = Mutex::new(None);
            let original = 0x1234;
            let (operations, state) = FakeConsoleOperations::new(|state| {
                state.get_mode = VecDeque::from([Some(original)]);
                state.set_mode = VecDeque::from([false]);
            });
            assert_eq!(
                ConsoleSessionState::start_with(cancel_event(), true, &registry, operations,).err(),
                Some(HostError::Startup)
            );
            assert!(calls(&state).contains(&ConsoleCall::SetMode(managed_console_mode(original))));
            assert_eq!(calls(&state).last(), Some(&ConsoleCall::RemoveHandler));
            assert!(lock_cancel_target(&registry).is_none());
        }

        #[test]
        fn redirected_registration_failure_reserves_owner_until_finish() {
            let registry = Mutex::new(None);
            let (operations, first_state) = FakeConsoleOperations::new(|state| {
                state.add_handler = VecDeque::from([false]);
            });
            let mut first =
                ConsoleSessionState::start_with(cancel_event(), false, &registry, operations)
                    .expect("redirected registration is best effort");
            let first_cancel = first.cancel.as_ref().expect("first cancel");
            assert!(lock_cancel_target(&registry)
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, first_cancel)));

            let (second_operations, second_state) = FakeConsoleOperations::new(|_| {});
            assert_eq!(
                ConsoleSessionState::start_with(
                    cancel_event(),
                    false,
                    &registry,
                    second_operations,
                )
                .err(),
                Some(HostError::Startup)
            );
            assert!(calls(&second_state).is_empty());
            assert!(lock_cancel_target(&registry)
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, first_cancel)));
            assert_eq!(first.finish(Ok(())), Ok(()));
            assert_eq!(calls(&first_state), vec![ConsoleCall::AddHandler]);
            assert!(lock_cancel_target(&registry).is_none());
        }

        #[test]
        fn redirected_partial_registration_retries_cleanup_and_reports_failure() {
            for (remove_results, expected_remove_calls, expected_finish) in [
                (vec![true], 1usize, Ok(())),
                (vec![false, true], 2usize, Ok(())),
                (vec![false, false], 2usize, Err(HostError::Transport)),
            ] {
                let registry = Mutex::new(None);
                let (operations, state) = FakeConsoleOperations::new(|state| {
                    state.clear_inherited_ignore = VecDeque::from([false]);
                    state.remove_handler = remove_results.into();
                });
                let cancel = cancel_event();
                let mut session =
                    ConsoleSessionState::start_with(cancel.clone(), false, &registry, operations)
                        .expect("redirected session continues after registration failure");
                assert!(lock_cancel_target(&registry)
                    .as_ref()
                    .is_some_and(|owner| Arc::ptr_eq(owner, &cancel)));
                assert!(!calls(&state).iter().any(|call| matches!(
                    call,
                    ConsoleCall::InputHandle | ConsoleCall::GetMode | ConsoleCall::SetMode(_)
                )));
                assert_eq!(session.finish(Ok(())), expected_finish);
                assert_eq!(
                    calls(&state),
                    [ConsoleCall::AddHandler, ConsoleCall::ClearInheritedIgnore,]
                        .into_iter()
                        .chain(std::iter::repeat_n(
                            ConsoleCall::RemoveHandler,
                            expected_remove_calls,
                        ))
                        .collect::<Vec<_>>()
                );
                assert!(lock_cancel_target(&registry).is_none());
            }
        }

        #[test]
        fn finish_attempts_restore_and_unregister_with_declared_error_precedence() {
            let primaries = [
                Ok(()),
                Err(HostError::Cancelled),
                Err(HostError::Startup),
                Err(HostError::Protocol),
                Err(HostError::Transport),
            ];
            for primary in primaries {
                for restore_ok in [true, false] {
                    for unregister_ok in [true, false] {
                        let registry = Mutex::new(None);
                        let original = 0x4567 | ENABLE_ECHO_INPUT;
                        let (operations, state) = FakeConsoleOperations::new(|state| {
                            state.get_mode = VecDeque::from([Some(original)]);
                            state.set_mode = VecDeque::from([true, restore_ok]);
                            state.remove_handler = VecDeque::from([unregister_ok]);
                        });
                        let mut session = ConsoleSessionState::start_with(
                            cancel_event(),
                            true,
                            &registry,
                            operations,
                        )
                        .expect("terminal session");
                        let expected = if (!restore_ok || !unregister_ok)
                            && matches!(primary, Ok(()) | Err(HostError::Cancelled))
                        {
                            Err(HostError::Transport)
                        } else {
                            primary
                        };
                        assert_eq!(session.finish(primary), expected);
                        let after_first_finish = calls(&state);
                        assert_eq!(
                            after_first_finish
                                .iter()
                                .filter(|call| matches!(call, ConsoleCall::SetMode(_)))
                                .count(),
                            2
                        );
                        assert_eq!(
                            after_first_finish
                                .iter()
                                .filter(|call| **call == ConsoleCall::RemoveHandler)
                                .count(),
                            1
                        );
                        assert_eq!(session.finish(Ok(())), Ok(()));
                        assert_eq!(calls(&state), after_first_finish);
                        assert!(lock_cancel_target(&registry).is_none());
                    }
                }
            }
        }

        #[test]
        fn callback_clone_keeps_event_alive_across_session_finish() {
            let registry = Arc::new(Mutex::new(None));
            let (operations, _) = FakeConsoleOperations::new(|_| {});
            let mut session = ConsoleSessionState::start_with(
                cancel_event(),
                false,
                registry.as_ref(),
                operations,
            )
            .expect("redirected session");
            let weak = Arc::downgrade(session.cancel.as_ref().expect("session cancel"));
            let callback_registry = registry.clone();
            let (acquired_sender, acquired_receiver) = std::sync::mpsc::channel();
            let (resume_sender, resume_receiver) = std::sync::mpsc::channel();
            let (signal_sender, signal_receiver) = std::sync::mpsc::channel();
            let callback = std::thread::spawn(move || {
                dispatch_ctrl_event_with(CTRL_C_EVENT, callback_registry.as_ref(), |cancel| {
                    acquired_sender.send(()).expect("report callback clone");
                    resume_receiver.recv().expect("resume callback");
                    let signalled = unsafe {
                        windows_sys::Win32::System::Threading::SetEvent(cancel.raw()) != 0
                    };
                    signal_sender.send(signalled).expect("report signal result");
                })
            });
            acquired_receiver.recv().expect("callback acquired Arc");
            assert_eq!(session.finish(Ok(())), Ok(()));
            assert!(lock_cancel_target(registry.as_ref()).is_none());
            assert!(
                weak.upgrade().is_some(),
                "callback clone must keep event alive"
            );
            resume_sender.send(()).expect("resume callback");
            assert!(signal_receiver.recv().expect("callback signal result"));
            assert_eq!(callback.join().expect("callback thread"), 1);
            assert!(weak.upgrade().is_none(), "callback was final event owner");
            assert_eq!(
                dispatch_ctrl_event_with(CTRL_C_EVENT + 1, registry.as_ref(), |_| {
                    panic!("non-Ctrl event must not signal")
                }),
                0
            );
            assert_eq!(
                dispatch_ctrl_event_with(CTRL_C_EVENT, registry.as_ref(), |_| {
                    panic!("cleared registry must not signal")
                }),
                0
            );
        }

        #[test]
        fn unfinished_session_drop_cleans_each_owned_state_once() {
            let registry = Mutex::new(None);
            let original = 0x7788 | ENABLE_ECHO_INPUT;
            let (operations, state) = FakeConsoleOperations::new(|state| {
                state.get_mode = VecDeque::from([Some(original)]);
            });
            let session =
                ConsoleSessionState::start_with(cancel_event(), true, &registry, operations)
                    .expect("terminal session");
            drop(session);
            assert_eq!(
                calls(&state)
                    .iter()
                    .filter(|call| matches!(call, ConsoleCall::SetMode(_)))
                    .count(),
                2
            );
            assert_eq!(
                calls(&state)
                    .iter()
                    .filter(|call| **call == ConsoleCall::RemoveHandler)
                    .count(),
                1
            );
            assert!(lock_cancel_target(&registry).is_none());
        }

        #[cfg(debug_assertions)]
        #[test]
        fn connect_ready_event_name_accepts_canonical_numeric_boundaries() {
            assert_eq!(
                parse_connect_ready_event_name(r"Local\winsmux-task862-connect-ready-1-1"),
                Some((1, 1))
            );
            assert_eq!(
                parse_connect_ready_event_name(&format!(
                    r"Local\winsmux-task862-connect-ready-{}-{}",
                    u32::MAX,
                    u64::MAX
                )),
                Some((u32::MAX, u64::MAX))
            );
        }

        #[cfg(debug_assertions)]
        #[test]
        fn connect_ready_event_name_rejects_every_noncanonical_component() {
            for name in [
                "",
                r"Global\winsmux-task862-connect-ready-1-1",
                r"local\winsmux-task862-connect-ready-1-1",
                r"Local\\winsmux-task862-connect-ready-1-1",
                r"Local\winsmux-task862-connect-ready-0-1",
                r"Local\winsmux-task862-connect-ready-1-0",
                r"Local\winsmux-task862-connect-ready-01-1",
                r"Local\winsmux-task862-connect-ready-1-01",
                r"Local\winsmux-task862-connect-ready-+1-1",
                r"Local\winsmux-task862-connect-ready-1- 1",
                r"Local\winsmux-task862-connect-ready-4294967296-1",
                r"Local\winsmux-task862-connect-ready-1-18446744073709551616",
                r"Local\winsmux-task862-connect-ready-1-1-extra",
                "Local\\winsmux-task862-connect-ready-1-1\0ignored",
            ] {
                assert_eq!(
                    parse_connect_ready_event_name(name),
                    None,
                    "accepted invalid event name: {name:?}"
                );
            }
        }

        #[cfg(debug_assertions)]
        #[test]
        fn connect_ready_signal_is_optional_and_rejects_before_event_access() {
            let event_accesses = Cell::new(0usize);
            let absent = signal_connect_ready_with(
                Err(std::env::VarError::NotPresent),
                false,
                false,
                false,
                |_| {
                    event_accesses.set(event_accesses.get() + 1);
                    Err(HostError::Transport)
                },
            );
            assert_eq!(absent.err(), None);
            assert_eq!(event_accesses.get(), 0);

            let invalid_settings = [
                Ok(r"Local\winsmux-task862-connect-ready-01-1".to_owned()),
                Err(std::env::VarError::NotUnicode(OsString::from_wide(&[
                    0xd800,
                ]))),
            ];
            for setting in invalid_settings {
                let result = signal_connect_ready_with(setting, true, true, true, |_| {
                    event_accesses.set(event_accesses.get() + 1);
                    Ok(())
                });
                assert_eq!(result.err(), Some(HostError::Transport));
            }
            for (terminal, control, mode) in [
                (false, true, true),
                (true, false, true),
                (true, true, false),
            ] {
                let result = signal_connect_ready_with(
                    Ok(r"Local\winsmux-task862-connect-ready-1-1".to_owned()),
                    terminal,
                    control,
                    mode,
                    |_| {
                        event_accesses.set(event_accesses.get() + 1);
                        Ok(())
                    },
                );
                assert_eq!(result.err(), Some(HostError::Transport));
            }
            assert_eq!(event_accesses.get(), 0);

            let valid_name = r"Local\winsmux-task862-connect-ready-1-1";
            signal_connect_ready_with(Ok(valid_name.to_owned()), true, true, true, |name| {
                event_accesses.set(event_accesses.get() + 1);
                assert_eq!(name, valid_name);
                Ok(())
            })
            .expect("signal canonical ready event");
            assert_eq!(event_accesses.get(), 1);

            assert_eq!(
                signal_connect_ready_with(Ok(valid_name.to_owned()), true, true, true, |_| Err(
                    HostError::Transport
                ),)
                .err(),
                Some(HostError::Transport)
            );
        }
    }
}

#[cfg(windows)]
pub(crate) use windows::artifact_request_admitted;
#[cfg(windows)]
pub use windows::run_connect;
#[cfg(windows)]
pub use windows::{PublicCancellation, PublicClient, PublicRequestError};
#[cfg(windows)]
pub(crate) use windows::{drive_requests, map_io, ConsoleSession};
#[cfg(all(windows, debug_assertions))]
pub(crate) use windows::probe_artifact_review;

#[cfg(not(windows))]
pub fn run_connect() -> Result<(), crate::host::HostError> {
    Err(crate::host::HostError::Startup)
}
