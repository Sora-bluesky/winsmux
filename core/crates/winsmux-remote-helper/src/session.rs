//! Linux-only on-demand broker for persistent remote PTY sessions.

use crate::{
    decode_base64, decode_payload, encode_base64, encode_payload, negotiate, read_frame,
    write_frame, Message, RejectCode, MAX_PTY_IO_CHUNK, PREFIX_LEN,
};
use std::collections::HashMap;
use std::env;
use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::mem::{self, MaybeUninit};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);
const HANDSHAKE_ATTEMPTS: usize = 3;
const BROKER_SOCKET_NAME: &str = "broker.sock";
const BROKER_LOCK_NAME: &str = "broker.lock";
const TEST_BROKER_EVENT_FD: &str = "WINSMUX_TEST_BROKER_EVENT_FD";
const TEST_FRONTEND_GATE_FD: &str = "WINSMUX_TEST_FRONTEND_GATE_FD";

/// Keep the public process invocation as `serve --stdio`; on Linux this process is
/// a transparent frontend for the per-euid broker.
pub fn serve_brokered_stdio() -> io::Result<()> {
    let first_payload = {
        let mut input = io::stdin().lock();
        match read_frame(&mut input)? {
            Ok(payload) => payload,
            Err(reject) => {
                write_frame(&mut io::stdout().lock(), &reject)?;
                return Ok(());
            }
        }
    };
    let preflight = match decode_payload(&first_payload) {
        Ok(message) => negotiate(&message),
        Err(reject) => reject,
    };
    if !matches!(preflight, Message::Welcome { .. }) {
        write_frame(&mut io::stdout().lock(), &preflight)?;
        return Ok(());
    }
    let first_frame = frame_from_payload(&first_payload);
    let paths = RuntimePaths::discover()?;
    let mut spawn_attempted = false;
    let mut last_retry_error = None;
    let mut test_barrier = FrontendTestBarrier::from_environment();

    for _ in 0..HANDSHAKE_ATTEMPTS {
        let lock = paths.open_lock()?;
        lock_exclusive(lock.as_raw_fd())?;
        test_barrier.wait_after_lock()?;

        let connection = match connect_under_lock(&paths)? {
            Some(stream) => FrontendConnection {
                stream,
                originator: false,
            },
            None if !spawn_attempted => {
                spawn_attempted = true;
                match spawn_broker(&paths, lock.as_raw_fd()) {
                    Ok(stream) => FrontendConnection {
                        stream,
                        originator: true,
                    },
                    Err(error) => {
                        unlock(lock.as_raw_fd())?;
                        return Err(error);
                    }
                }
            }
            None => {
                unlock(lock.as_raw_fd())?;
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    "broker disappeared after the single spawn attempt",
                ));
            }
        };

        let FrontendConnection {
            mut stream,
            originator,
        } = connection;
        if originator {
            // The ack proves the socketpair frontend was registered before the broker
            // could observe a zero-frontend state.
            unlock(lock.as_raw_fd())?;
        }

        let handshake = perform_handshake(&mut stream, &first_frame);
        match handshake {
            Ok(reply) => {
                if !originator {
                    unlock(lock.as_raw_fd())?;
                }
                stream.set_read_timeout(None)?;
                write_payload_frame(&mut io::stdout().lock(), &reply)?;
                if matches!(decode_payload(&reply), Ok(Message::Welcome { .. })) {
                    return relay_stdio(stream);
                }
                return Ok(());
            }
            Err(error) if retryable_handshake_error(&error) => {
                // The failed stream must be closed before named admission is unlocked.
                drop(stream);
                if !originator {
                    unlock(lock.as_raw_fd())?;
                }
                last_retry_error = Some(error);
            }
            Err(error) => {
                drop(stream);
                if !originator {
                    unlock(lock.as_raw_fd())?;
                }
                return Err(error);
            }
        }
    }

    Err(last_retry_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            "broker handshake failed after three lock-acquisition attempts",
        )
    }))
}

struct FrontendConnection {
    stream: UnixStream,
    originator: bool,
}

fn perform_handshake(stream: &mut UnixStream, first_frame: &[u8]) -> io::Result<Vec<u8>> {
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    stream.write_all(first_frame)?;
    stream.flush()?;
    match read_frame(stream)? {
        Ok(payload) => Ok(payload),
        Err(reject) => encode_payload(&reject)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
    }
}

fn retryable_handshake_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::TimedOut
            | io::ErrorKind::WouldBlock
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::BrokenPipe
    )
}

fn frame_from_payload(payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(PREFIX_LEN + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    frame
}

fn write_payload_frame<W: Write>(writer: &mut W, payload: &[u8]) -> io::Result<()> {
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()
}

fn relay_stdio(mut stream: UnixStream) -> io::Result<()> {
    let mut upstream = stream.try_clone()?;
    thread::Builder::new()
        .name("winsmux-remote-helper-stdin".to_string())
        .spawn(move || {
            let _ = io::copy(&mut io::stdin().lock(), &mut upstream);
            let _ = upstream.shutdown(std::net::Shutdown::Write);
        })?;
    io::copy(&mut stream, &mut io::stdout().lock())?;
    Ok(())
}

struct RuntimePaths {
    directory: File,
    socket_path: PathBuf,
}

impl RuntimePaths {
    fn discover() -> io::Result<Self> {
        let runtime = env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "XDG_RUNTIME_DIR is required",
            )
        })?;
        let runtime = PathBuf::from(runtime);
        if !runtime.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "XDG_RUNTIME_DIR must be absolute",
            ));
        }
        let metadata = fs::symlink_metadata(&runtime)?;
        let euid = unsafe { libc::geteuid() };
        if !metadata.file_type().is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != euid
            || metadata.mode() & 0o022 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "XDG_RUNTIME_DIR is not a secure euid-owned directory",
            ));
        }

        let runtime_fd = open_directory_path(&runtime)?;
        validate_directory(runtime_fd.as_raw_fd(), false)?;
        let winsmux = ensure_private_directory(runtime_fd.as_raw_fd(), "winsmux")?;
        let helper = ensure_private_directory(winsmux.as_raw_fd(), "remote-helper")?;
        let socket_path = runtime
            .join("winsmux")
            .join("remote-helper")
            .join(BROKER_SOCKET_NAME);
        Ok(Self {
            directory: helper,
            socket_path,
        })
    }

    fn open_lock(&self) -> io::Result<File> {
        let name = CString::new(BROKER_LOCK_NAME).expect("static lock name");
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let stat = fstat(file.as_raw_fd())?;
        if stat.st_uid != unsafe { libc::geteuid() }
            || stat.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat.st_mode & 0o777 != 0o600
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "broker.lock is not a private euid-owned regular file",
            ));
        }
        Ok(file)
    }
}

fn open_directory_path(path: &Path) -> io::Result<File> {
    let path = cstring(path.as_os_str())?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn ensure_private_directory(parent: RawFd, name: &str) -> io::Result<File> {
    let name = CString::new(name).expect("static directory name");
    let created = match unsafe { libc::mkdirat(parent, name.as_ptr(), 0o700) } {
        0 => true,
        _ if io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST) => false,
        _ => return Err(io::Error::last_os_error()),
    };
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    if created && unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) } != 0 {
        return Err(io::Error::last_os_error());
    }
    validate_directory(directory.as_raw_fd(), true)?;
    Ok(directory)
}

fn validate_directory(fd: RawFd, exact_private_mode: bool) -> io::Result<()> {
    let stat = fstat(fd)?;
    let mode_is_valid = if exact_private_mode {
        stat.st_mode & 0o777 == 0o700
    } else {
        stat.st_mode & 0o022 == 0
    };
    if stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || !mode_is_valid
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "runtime directory failed fd-based ownership or mode validation",
        ));
    }
    Ok(())
}

fn fstat(fd: RawFd) -> io::Result<libc::stat> {
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

fn cstring(value: &OsStr) -> io::Result<CString> {
    CString::new(value.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains a NUL byte"))
}

fn lock_exclusive(fd: RawFd) -> io::Result<()> {
    flock(fd, libc::LOCK_EX)
}

fn unlock(fd: RawFd) -> io::Result<()> {
    flock(fd, libc::LOCK_UN)
}

fn flock(fd: RawFd, operation: libc::c_int) -> io::Result<()> {
    loop {
        if unsafe { libc::flock(fd, operation) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn try_lock_exclusive(fd: RawFd) -> io::Result<bool> {
    match flock(fd, libc::LOCK_EX | libc::LOCK_NB) {
        Ok(()) => Ok(true),
        Err(error)
            if error.raw_os_error() == Some(libc::EAGAIN)
                || error.raw_os_error() == Some(libc::EWOULDBLOCK) =>
        {
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn connect_under_lock(paths: &RuntimePaths) -> io::Result<Option<UnixStream>> {
    match UnixStream::connect(&paths.socket_path) {
        Ok(stream) => {
            verify_peer_euid(&stream)?;
            Ok(Some(stream))
        }
        Err(error) if error.raw_os_error() == Some(libc::ENOENT) => Ok(None),
        Err(error) if error.raw_os_error() == Some(libc::ECONNREFUSED) => {
            validate_stale_socket(&paths.socket_path)?;
            fs::remove_file(&paths.socket_path)?;
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

fn validate_stale_socket(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refused broker path is not an euid-owned socket",
        ));
    }
    Ok(())
}

fn verify_peer_euid(stream: &UnixStream) -> io::Result<libc::ucred> {
    let mut credential = MaybeUninit::<libc::ucred>::uninit();
    let mut length = mem::size_of::<libc::ucred>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            credential.as_mut_ptr().cast(),
            &mut length,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if length as usize != mem::size_of::<libc::ucred>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "SO_PEERCRED returned an invalid credential size",
        ));
    }
    let credential = unsafe { credential.assume_init() };
    if credential.uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "broker peer uid does not match the effective uid",
        ));
    }
    Ok(credential)
}

fn spawn_broker(paths: &RuntimePaths, originator_lock_fd: RawFd) -> io::Result<UnixStream> {
    let mut pair = [-1; 2];
    if unsafe {
        libc::socketpair(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC,
            0,
            pair.as_mut_ptr(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut ack = [-1; 2];
    if unsafe { libc::pipe2(ack.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        close_fd(pair[0]);
        close_fd(pair[1]);
        return Err(io::Error::last_os_error());
    }

    let pid = unsafe { libc::fork() };
    if pid < 0 {
        close_fd(pair[0]);
        close_fd(pair[1]);
        close_fd(ack[0]);
        close_fd(ack[1]);
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        close_fd(pair[0]);
        close_fd(ack[0]);
        // This inherited originator FD is never the broker's named lock FD.
        close_fd(originator_lock_fd);
        if unsafe { libc::setsid() } < 0 || redirect_stdio_to_dev_null().is_err() {
            let _ = write_ack(ack[1], 1);
            unsafe { libc::_exit(1) };
        }
        let initial = unsafe { UnixStream::from_raw_fd(pair[1]) };
        if broker_main(paths, initial, ack[1]).is_err() {
            let _ = write_ack(ack[1], 1);
            unsafe { libc::_exit(1) };
        }
        unsafe { libc::_exit(0) };
    }

    close_fd(pair[1]);
    close_fd(ack[1]);
    let stream = unsafe { UnixStream::from_raw_fd(pair[0]) };
    let ack_result = read_ack(ack[0]);
    close_fd(ack[0]);
    match ack_result {
        Ok(0) => Ok(stream),
        Ok(_) => {
            drop(stream);
            wait_pid(pid)?;
            Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "broker failed before listen acknowledgement",
            ))
        }
        Err(error) => {
            drop(stream);
            wait_pid(pid)?;
            Err(error)
        }
    }
}

fn read_ack(fd: RawFd) -> io::Result<u8> {
    read_one_byte(fd).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "broker closed ack pipe before readiness",
            )
        } else {
            error
        }
    })
}

fn read_one_byte(fd: RawFd) -> io::Result<u8> {
    let mut byte = 0u8;
    loop {
        match unsafe { libc::read(fd, (&mut byte as *mut u8).cast(), 1) } {
            1 => return Ok(byte),
            0 => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "pipe closed before a byte was available",
                ))
            }
            _ => {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }
}

fn write_ack(fd: RawFd, byte: u8) -> io::Result<()> {
    write_all_fd(fd, &[byte])
}

fn redirect_stdio_to_dev_null() -> io::Result<()> {
    let path = CString::new("/dev/null").expect("static path");
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        if unsafe { libc::dup2(fd, target) } < 0 {
            let error = io::Error::last_os_error();
            close_fd(fd);
            return Err(error);
        }
    }
    if fd > libc::STDERR_FILENO {
        close_fd(fd);
    }
    Ok(())
}

fn close_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

fn wait_pid(pid: libc::pid_t) -> io::Result<()> {
    loop {
        if unsafe { libc::waitpid(pid, ptr::null_mut(), 0) } == pid {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn broker_main(paths: &RuntimePaths, initial: UnixStream, ack_fd: RawFd) -> io::Result<()> {
    if unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let listener = UnixListener::bind(&paths.socket_path)?;
    fs::set_permissions(&paths.socket_path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;

    let mut wake = [-1; 2];
    if unsafe { libc::pipe2(wake.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        let error = io::Error::last_os_error();
        let _ = fs::remove_file(&paths.socket_path);
        return Err(error);
    }
    let state = Arc::new(BrokerState::new(wake[1]));
    let hooks = TestHooks::from_environment();
    hooks.emit(b'R');
    write_ack(ack_fd, 0)?;
    close_fd(ack_fd);
    spawn_frontend(initial, state.clone(), state.initial_frontend_id())?;

    loop {
        let mut poll_fds = [
            libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake[0],
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        if unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, -1) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll_fds[1].revents & libc::POLLIN != 0 {
            drain_fd(wake[0])?;
        }
        if poll_fds[0].revents & libc::POLLIN != 0 {
            accept_available(&listener, &state, hooks)?;
        }
        if state.is_idle() {
            attempt_shutdown(paths, &listener, &state, hooks)?;
        }
    }
}

#[derive(Clone, Copy)]
struct TestHooks {
    fd: Option<RawFd>,
}

struct FrontendTestBarrier {
    gate_fd: Option<RawFd>,
    hooks: TestHooks,
}

impl FrontendTestBarrier {
    fn from_environment() -> Self {
        #[cfg(debug_assertions)]
        {
            let gate_fd = env::var(TEST_FRONTEND_GATE_FD)
                .ok()
                .and_then(|value| value.parse::<RawFd>().ok())
                .filter(|fd| unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0);
            if let Some(fd) = gate_fd {
                let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
                if flags >= 0 {
                    unsafe {
                        libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
                    }
                }
            }
            return Self {
                gate_fd,
                hooks: TestHooks::from_environment(),
            };
        }
        #[cfg(not(debug_assertions))]
        Self {
            gate_fd: None,
            hooks: TestHooks { fd: None },
        }
    }

    fn wait_after_lock(&mut self) -> io::Result<()> {
        let Some(fd) = self.gate_fd.take() else {
            return Ok(());
        };
        self.hooks.emit(b'L');
        let result = read_one_byte(fd);
        close_fd(fd);
        result.map(|_| ())
    }
}

impl TestHooks {
    fn from_environment() -> Self {
        #[cfg(debug_assertions)]
        {
            let fd = env::var(TEST_BROKER_EVENT_FD)
                .ok()
                .and_then(|value| value.parse::<RawFd>().ok())
                .filter(|fd| unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0);
            if let Some(fd) = fd {
                let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
                if flags >= 0 {
                    unsafe {
                        libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
                    }
                }
            }
            return Self { fd };
        }
        #[cfg(not(debug_assertions))]
        Self { fd: None }
    }

    fn emit(self, code: u8) {
        if let Some(fd) = self.fd {
            let mut record = [0u8; 5];
            record[0] = code;
            record[1..].copy_from_slice(&unsafe { libc::getpid() }.to_ne_bytes());
            let _ = write_all_fd(fd, &record);
        }
    }
}

struct BrokerState {
    inner: Mutex<BrokerInner>,
    wake_write: RawFd,
}

struct BrokerInner {
    frontends: usize,
    next_frontend_id: u64,
    sessions: HashMap<String, Session>,
    shutdown_lock_waiter: bool,
}

struct Session {
    child_pid: u32,
    pgid: libc::pid_t,
    master: Arc<Mutex<File>>,
    controller: Option<Controller>,
    agent_exited: bool,
    _guardian: Arc<ProcessGroupGuardian>,
    completion: Arc<Completion>,
}

struct ProcessGroupGuardian {
    pid: libc::pid_t,
    // Keeping this write end open is the broker's process-group ownership
    // lease. EOF tells the guardian to kill the Agent group.
    _liveness: File,
}

struct Controller {
    frontend_id: u64,
    writer: Arc<Mutex<UnixStream>>,
    active: bool,
    peer_frame_limit: u32,
}

impl BrokerState {
    fn new(wake_write: RawFd) -> Self {
        Self {
            inner: Mutex::new(BrokerInner {
                frontends: 1,
                next_frontend_id: 2,
                sessions: HashMap::new(),
                shutdown_lock_waiter: false,
            }),
            wake_write,
        }
    }

    fn initial_frontend_id(&self) -> u64 {
        1
    }

    fn register_frontend(&self) -> u64 {
        let mut inner = lock_mutex(&self.inner);
        let id = inner.next_frontend_id;
        inner.next_frontend_id = inner.next_frontend_id.wrapping_add(1).max(2);
        inner.frontends += 1;
        id
    }

    fn disconnect_frontend(&self, frontend_id: u64) {
        let mut inner = lock_mutex(&self.inner);
        inner.frontends = inner.frontends.saturating_sub(1);
        for session in inner.sessions.values_mut() {
            if session
                .controller
                .as_ref()
                .is_some_and(|controller| controller.frontend_id == frontend_id)
            {
                session.controller = None;
            }
        }
        drop(inner);
        self.wake();
    }

    fn mark_agent_exited(&self, session_id: &str) {
        let mut inner = lock_mutex(&self.inner);
        if let Some(session) = inner.sessions.get_mut(session_id) {
            session.agent_exited = true;
            session.controller = None;
        }
        drop(inner);
        self.wake();
    }

    fn is_idle(&self) -> bool {
        let inner = lock_mutex(&self.inner);
        inner.frontends == 0 && inner.sessions.is_empty()
    }

    fn wake(&self) {
        let byte = b'w';
        unsafe {
            libc::write(self.wake_write, (&byte as *const u8).cast(), 1);
        }
    }

    fn arm_shutdown_lock_release_waiter(self: &Arc<Self>, lock: File) -> io::Result<()> {
        let should_wait = {
            let mut inner = lock_mutex(&self.inner);
            if inner.frontends != 0 || !inner.sessions.is_empty() || inner.shutdown_lock_waiter {
                false
            } else {
                inner.shutdown_lock_waiter = true;
                true
            }
        };
        if !should_wait {
            return Ok(());
        }

        let state = self.clone();
        match thread::Builder::new()
            .name("winsmux-broker-lock-release".to_string())
            .spawn(move || {
                // The accept loop never waits on the admission lock. This
                // notifier only turns a later unlock into the existing wake
                // event; it does not make the shutdown decision itself.
                if lock_exclusive(lock.as_raw_fd()).is_ok() {
                    let _ = unlock(lock.as_raw_fd());
                }
                state.finish_shutdown_lock_release_waiter();
            }) {
            Ok(_) => Ok(()),
            Err(error) => {
                self.finish_shutdown_lock_release_waiter();
                Err(error)
            }
        }
    }

    fn finish_shutdown_lock_release_waiter(&self) {
        lock_mutex(&self.inner).shutdown_lock_waiter = false;
        self.wake();
    }
}

struct FrontendGuard {
    state: Arc<BrokerState>,
    frontend_id: u64,
}

impl Drop for FrontendGuard {
    fn drop(&mut self) {
        self.state.disconnect_frontend(self.frontend_id);
    }
}

struct Completion {
    result: Mutex<Option<Result<(), String>>>,
    ready: Condvar,
}

impl Completion {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
            ready: Condvar::new(),
        }
    }

    fn finish(&self, result: Result<(), String>) {
        *lock_mutex(&self.result) = Some(result);
        self.ready.notify_all();
    }

    fn wait(&self) -> Result<(), String> {
        let mut result = lock_mutex(&self.result);
        while result.is_none() {
            result = match self.ready.wait(result) {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
        }
        result.clone().expect("completion checked above")
    }
}

fn lock_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn drain_fd(fd: RawFd) -> io::Result<()> {
    let mut buffer = [0u8; 64];
    loop {
        let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if read > 0 {
            continue;
        }
        if read == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            return Ok(());
        }
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn accept_available(
    listener: &UnixListener,
    state: &Arc<BrokerState>,
    hooks: TestHooks,
) -> io::Result<usize> {
    let mut accepted = 0;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                if verify_peer_euid(&stream).is_err() {
                    drop(stream);
                    continue;
                }
                let frontend_id = state.register_frontend();
                hooks.emit(b'A');
                if let Err(error) = spawn_frontend(stream, state.clone(), frontend_id) {
                    state.disconnect_frontend(frontend_id);
                    return Err(error);
                }
                accepted += 1;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(accepted),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

fn attempt_shutdown(
    paths: &RuntimePaths,
    listener: &UnixListener,
    state: &Arc<BrokerState>,
    hooks: TestHooks,
) -> io::Result<()> {
    let lock = paths.open_lock()?;
    if !try_lock_exclusive(lock.as_raw_fd())? {
        hooks.emit(b'B');
        state.arm_shutdown_lock_release_waiter(lock)?;
        return Ok(());
    }
    if accept_available(listener, state, hooks)? > 0 || !state.is_idle() {
        unlock(lock.as_raw_fd())?;
        return Ok(());
    }
    match fs::remove_file(&paths.socket_path) {
        Ok(()) => {
            hooks.emit(b'S');
            unsafe { libc::_exit(0) }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            hooks.emit(b'S');
            unsafe { libc::_exit(0) }
        }
        Err(error) => {
            unlock(lock.as_raw_fd())?;
            Err(error)
        }
    }
}

fn spawn_frontend(stream: UnixStream, state: Arc<BrokerState>, frontend_id: u64) -> io::Result<()> {
    thread::Builder::new()
        .name(format!("winsmux-remote-frontend-{frontend_id}"))
        .spawn(move || {
            let _guard = FrontendGuard {
                state: state.clone(),
                frontend_id,
            };
            let _ = handle_frontend(stream, state, frontend_id);
        })?;
    Ok(())
}

fn handle_frontend(
    mut reader: UnixStream,
    state: Arc<BrokerState>,
    frontend_id: u64,
) -> io::Result<()> {
    let writer = Arc::new(Mutex::new(reader.try_clone()?));
    let first = match read_frame(&mut reader)? {
        Ok(payload) => payload,
        Err(reject) => {
            send_message(&writer, &reject)?;
            return Ok(());
        }
    };
    let hello = match decode_payload(&first) {
        Ok(message) => message,
        Err(reject) => {
            send_message(&writer, &reject)?;
            return Ok(());
        }
    };
    let peer_frame_limit = match &hello {
        Message::Hello {
            peer_frame_limit, ..
        } => *peer_frame_limit,
        _ => 0,
    };
    let reply = negotiate(&hello);
    send_message(&writer, &reply)?;
    if !matches!(reply, Message::Welcome { .. }) {
        return Ok(());
    }

    let mut controlled_session = None;
    loop {
        let payload = match read_frame(&mut reader) {
            Ok(Ok(payload)) => payload,
            Ok(Err(reject)) => {
                send_message(&writer, &reject)?;
                if matches!(
                    reject,
                    Message::Reject {
                        code: RejectCode::Oversized,
                        ..
                    }
                ) {
                    return Ok(());
                }
                continue;
            }
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        };
        let message = match decode_payload(&payload) {
            Ok(message) => message,
            Err(reject) => {
                send_message(&writer, &reject)?;
                continue;
            }
        };
        dispatch_message(
            message,
            &state,
            frontend_id,
            &writer,
            peer_frame_limit,
            &mut controlled_session,
        )?;
    }
}

fn dispatch_message(
    message: Message,
    state: &Arc<BrokerState>,
    frontend_id: u64,
    writer: &Arc<Mutex<UnixStream>>,
    peer_frame_limit: u32,
    controlled_session: &mut Option<String>,
) -> io::Result<()> {
    match message {
        Message::PtyStart {
            executable,
            argv,
            cols,
            rows,
        } => {
            if controlled_session.is_some() {
                return send_reject(
                    writer,
                    RejectCode::ControllerBusy,
                    "frontend already controls a session",
                );
            }
            start_session(
                state,
                frontend_id,
                writer,
                peer_frame_limit,
                controlled_session,
                executable,
                argv,
                cols,
                rows,
            )
        }
        Message::PtyAttach { session_id } => {
            if controlled_session.is_some() {
                return send_reject(
                    writer,
                    RejectCode::ControllerBusy,
                    "frontend already controls a session",
                );
            }
            let attach_result = {
                let mut inner = lock_mutex(&state.inner);
                match inner.sessions.get_mut(&session_id) {
                    None => Err((RejectCode::SessionNotFound, "session does not exist")),
                    Some(session) if session.agent_exited => {
                        Err((RejectCode::SessionNotFound, "Agent has exited"))
                    }
                    Some(session) if session.controller.is_some() => Err((
                        RejectCode::ControllerBusy,
                        "session already has a controller",
                    )),
                    Some(session) => {
                        session.controller = Some(Controller {
                            frontend_id,
                            writer: writer.clone(),
                            active: false,
                            peer_frame_limit,
                        });
                        Ok(session.child_pid)
                    }
                }
            };
            let child_pid = match attach_result {
                Ok(child_pid) => child_pid,
                Err((code, detail)) => return send_reject(writer, code, detail),
            };
            *controlled_session = Some(session_id.clone());
            send_message(
                writer,
                &Message::PtyAttached {
                    session_id: session_id.clone(),
                    child_pid,
                },
            )?;
            activate_controller(state, &session_id, frontend_id);
            Ok(())
        }
        Message::PtyDetach => {
            let Some(session_id) = controlled_session.take() else {
                return send_reject(
                    writer,
                    RejectCode::NotController,
                    "frontend has no controller lease",
                );
            };
            let mut inner = lock_mutex(&state.inner);
            if let Some(session) = inner.sessions.get_mut(&session_id) {
                if session
                    .controller
                    .as_ref()
                    .is_some_and(|controller| controller.frontend_id == frontend_id)
                {
                    session.controller = None;
                }
            }
            drop(inner);
            send_message(writer, &Message::PtyDetached)
        }
        Message::PtyStop { session_id } => {
            if controlled_session.as_deref() != Some(session_id.as_str()) {
                return send_reject(
                    writer,
                    RejectCode::NotController,
                    "pty-stop requires the controller lease",
                );
            }
            let stop_result = {
                let mut inner = lock_mutex(&state.inner);
                match inner.sessions.get_mut(&session_id) {
                    None => Err((RejectCode::SessionNotFound, "session does not exist")),
                    Some(session) if session.agent_exited => {
                        Err((RejectCode::SessionNotFound, "Agent has exited"))
                    }
                    Some(session)
                        if !session
                            .controller
                            .as_ref()
                            .is_some_and(|controller| controller.frontend_id == frontend_id) =>
                    {
                        Err((
                            RejectCode::NotController,
                            "frontend does not own the controller lease",
                        ))
                    }
                    Some(session) => {
                        if let Some(controller) = session.controller.as_mut() {
                            controller.active = false;
                        }
                        Ok((session.pgid, session.completion.clone()))
                    }
                }
            };
            let (pgid, completion) = match stop_result {
                Ok(result) => result,
                Err((code, detail)) => {
                    *controlled_session = None;
                    return send_reject(writer, code, detail);
                }
            };
            request_process_group_stop(pgid)?;
            let result = completion.wait();
            *controlled_session = None;
            match result {
                Ok(()) => send_message(writer, &Message::PtyStopped),
                Err(detail) => send_reject(writer, RejectCode::SpawnFailed, detail),
            }
        }
        Message::PtyInput { data_b64 } => {
            let Some(session_id) = controlled_session.as_ref() else {
                return send_reject(
                    writer,
                    RejectCode::NotController,
                    "pty-input requires the controller lease",
                );
            };
            match controller_master(state, session_id, frontend_id) {
                Ok(master) => {
                    let data = decode_base64(&data_b64).expect("decode_payload validated base64");
                    write_pty_input(lock_mutex(&master).as_raw_fd(), &data)
                }
                Err((code, detail)) => send_reject(writer, code, detail),
            }
        }
        Message::PtyResize { cols, rows } => {
            let Some(session_id) = controlled_session.as_ref() else {
                return send_reject(
                    writer,
                    RejectCode::NotController,
                    "pty-resize requires the controller lease",
                );
            };
            match controller_master(state, session_id, frontend_id) {
                Ok(master) => resize_pty(lock_mutex(&master).as_raw_fd(), cols, rows),
                Err((code, detail)) => send_reject(writer, code, detail),
            }
        }
        Message::Hello { .. } | Message::Welcome { .. } | Message::Reject { .. } => send_reject(
            writer,
            RejectCode::UnknownType,
            "handshake message is not accepted after Welcome",
        ),
        Message::PtyStarted { .. }
        | Message::PtyAttached { .. }
        | Message::PtyDetached
        | Message::PtyStopped
        | Message::PtyOutput { .. } => send_reject(
            writer,
            RejectCode::UnknownType,
            "server-only message is not accepted from the peer",
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn start_session(
    state: &Arc<BrokerState>,
    frontend_id: u64,
    writer: &Arc<Mutex<UnixStream>>,
    peer_frame_limit: u32,
    controlled_session: &mut Option<String>,
    executable: String,
    argv: Vec<String>,
    cols: u16,
    rows: u16,
) -> io::Result<()> {
    let agent = match spawn_agent(&executable, &argv, cols, rows) {
        Ok(agent) => agent,
        Err(error) => return send_reject(writer, RejectCode::SpawnFailed, error.to_string()),
    };
    let SpawnedAgent {
        pid,
        pgid,
        master,
        reader,
        guardian,
    } = agent;
    let child_pid = pid as u32;
    let guardian_pid = guardian.pid;
    let session_id = unique_session_id(state)?;
    let completion = Arc::new(Completion::new());
    {
        let mut inner = lock_mutex(&state.inner);
        inner.sessions.insert(
            session_id.clone(),
            Session {
                child_pid,
                pgid,
                master: master.clone(),
                controller: Some(Controller {
                    frontend_id,
                    writer: writer.clone(),
                    active: false,
                    peer_frame_limit,
                }),
                agent_exited: false,
                _guardian: guardian.clone(),
                completion: completion.clone(),
            },
        );
    }

    let watcher = spawn_agent_watcher(
        state.clone(),
        session_id.clone(),
        pid,
        pgid,
        guardian,
        completion.clone(),
    );
    if let Err(error) = watcher {
        let cleanup =
            stop_and_reap_without_watcher(pid, pgid).map_err(|cleanup| cleanup.to_string());
        lock_mutex(&state.inner).sessions.remove(&session_id);
        let guardian_cleanup = wait_pid(guardian_pid).map_err(|cleanup| cleanup.to_string());
        completion.finish(cleanup.and(guardian_cleanup));
        return send_reject(writer, RejectCode::SpawnFailed, error.to_string());
    }

    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    if let Err(error) = spawn_output_reader(state.clone(), session_id.clone(), reader, gate.clone())
    {
        request_process_group_stop(pgid)?;
        let _ = completion.wait();
        return send_reject(writer, RejectCode::SpawnFailed, error.to_string());
    }

    *controlled_session = Some(session_id.clone());
    let response = send_message(
        writer,
        &Message::PtyStarted {
            session_id: session_id.clone(),
            child_pid,
        },
    );
    {
        let (open, ready) = &*gate;
        *lock_mutex(open) = true;
        ready.notify_all();
    }
    response?;
    activate_controller(state, &session_id, frontend_id);
    Ok(())
}

fn activate_controller(state: &BrokerState, session_id: &str, frontend_id: u64) {
    let mut inner = lock_mutex(&state.inner);
    if let Some(controller) = inner
        .sessions
        .get_mut(session_id)
        .and_then(|session| session.controller.as_mut())
        .filter(|controller| controller.frontend_id == frontend_id)
    {
        controller.active = true;
    }
}

fn controller_master(
    state: &BrokerState,
    session_id: &str,
    frontend_id: u64,
) -> Result<Arc<Mutex<File>>, (RejectCode, &'static str)> {
    let inner = lock_mutex(&state.inner);
    let Some(session) = inner.sessions.get(session_id) else {
        return Err((RejectCode::SessionNotFound, "session does not exist"));
    };
    if session.agent_exited {
        return Err((RejectCode::SessionNotFound, "Agent has exited"));
    }
    if !session
        .controller
        .as_ref()
        .is_some_and(|controller| controller.frontend_id == frontend_id)
    {
        return Err((
            RejectCode::NotController,
            "frontend does not own the controller lease",
        ));
    }
    Ok(session.master.clone())
}

fn send_message(writer: &Arc<Mutex<UnixStream>>, message: &Message) -> io::Result<()> {
    write_frame(&mut *lock_mutex(writer), message)
}

fn send_reject(
    writer: &Arc<Mutex<UnixStream>>,
    code: RejectCode,
    detail: impl Into<String>,
) -> io::Result<()> {
    send_message(writer, &Message::reject(code, detail))
}

fn unique_session_id(state: &BrokerState) -> io::Result<String> {
    loop {
        let mut bytes = [0u8; 16];
        fill_random(&mut bytes)?;
        let mut id = String::with_capacity(32);
        const HEX: &[u8; 16] = b"0123456789abcdef";
        for byte in bytes {
            id.push(HEX[(byte >> 4) as usize] as char);
            id.push(HEX[(byte & 0x0f) as usize] as char);
        }
        if !lock_mutex(&state.inner).sessions.contains_key(&id) {
            return Ok(id);
        }
    }
}

fn fill_random(bytes: &mut [u8]) -> io::Result<()> {
    let mut filled = 0;
    while filled < bytes.len() {
        let result = unsafe {
            libc::getrandom(bytes[filled..].as_mut_ptr().cast(), bytes.len() - filled, 0)
        };
        if result > 0 {
            filled += result as usize;
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    Ok(())
}

struct SpawnedAgent {
    pid: libc::pid_t,
    pgid: libc::pid_t,
    master: Arc<Mutex<File>>,
    reader: File,
    guardian: Arc<ProcessGroupGuardian>,
}

fn spawn_agent(
    executable: &str,
    argv: &[String],
    cols: u16,
    rows: u16,
) -> io::Result<SpawnedAgent> {
    let executable = CString::new(executable.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "executable contains NUL"))?;
    let mut arguments = Vec::with_capacity(argv.len() + 1);
    arguments.push(executable.clone());
    for argument in argv {
        arguments.push(
            CString::new(argument.as_bytes())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "argv contains NUL"))?,
        );
    }
    let mut argument_pointers: Vec<*const libc::c_char> =
        arguments.iter().map(|argument| argument.as_ptr()).collect();
    argument_pointers.push(ptr::null());

    let environment = process_environment()?;
    let mut environment_pointers: Vec<*const libc::c_char> =
        environment.iter().map(|entry| entry.as_ptr()).collect();
    environment_pointers.push(ptr::null());

    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let mut master = -1;
    let mut slave = -1;
    if unsafe { libc::openpty(&mut master, &mut slave, ptr::null_mut(), ptr::null(), &size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    set_cloexec(master)?;
    set_cloexec(slave)?;
    set_nonblocking(master)?;
    let mut exec_status = [-1; 2];
    let mut agent_release = [-1; 2];
    let mut guardian_liveness = [-1; 2];
    let mut guardian_ack = [-1; 2];
    if unsafe { libc::pipe2(exec_status.as_mut_ptr(), libc::O_CLOEXEC) } != 0
        || unsafe { libc::pipe2(agent_release.as_mut_ptr(), libc::O_CLOEXEC) } != 0
        || unsafe { libc::pipe2(guardian_liveness.as_mut_ptr(), libc::O_CLOEXEC) } != 0
        || unsafe { libc::pipe2(guardian_ack.as_mut_ptr(), libc::O_CLOEXEC) } != 0
    {
        let error = io::Error::last_os_error();
        close_fd(master);
        close_fd(slave);
        for fd in exec_status
            .into_iter()
            .chain(agent_release)
            .chain(guardian_liveness)
            .chain(guardian_ack)
        {
            close_fd(fd);
        }
        return Err(error);
    }

    let broker_pid = unsafe { libc::getpid() };
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        let error = io::Error::last_os_error();
        close_fd(master);
        close_fd(slave);
        for fd in exec_status
            .into_iter()
            .chain(agent_release)
            .chain(guardian_liveness)
            .chain(guardian_ack)
        {
            close_fd(fd);
        }
        return Err(error);
    }
    if pid == 0 {
        close_fd(master);
        close_fd(exec_status[0]);
        close_fd(agent_release[1]);
        close_fd(guardian_liveness[0]);
        close_fd(guardian_liveness[1]);
        close_fd(guardian_ack[0]);
        close_fd(guardian_ack[1]);
        let mut failed = unsafe {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) != 0
                || libc::getppid() != broker_pid
                || libc::setpgid(0, 0) != 0
        };
        for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
            if unsafe { libc::dup2(slave, target) } < 0 {
                failed = true;
            }
        }
        if slave > libc::STDERR_FILENO {
            close_fd(slave);
        }
        if !failed && read_one_byte(agent_release[0]).is_err() {
            failed = true;
        }
        close_fd(agent_release[0]);
        if failed {
            unsafe {
                libc::write(exec_status[1], [1u8].as_ptr().cast(), 1);
            }
            unsafe { libc::_exit(127) };
        }
        unsafe {
            libc::execve(
                executable.as_ptr(),
                argument_pointers.as_ptr(),
                environment_pointers.as_ptr(),
            );
        }
        unsafe {
            libc::write(exec_status[1], [1u8].as_ptr().cast(), 1);
        }
        unsafe { libc::_exit(127) };
    }

    close_fd(slave);
    close_fd(exec_status[1]);
    close_fd(agent_release[0]);
    let set_group = unsafe { libc::setpgid(pid, pid) };
    if set_group != 0 {
        let error = io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::EACCES) | Some(libc::ESRCH)) {
            close_fd(agent_release[1]);
            close_fd(guardian_liveness[0]);
            close_fd(guardian_liveness[1]);
            close_fd(guardian_ack[0]);
            close_fd(guardian_ack[1]);
            close_fd(exec_status[0]);
            close_fd(master);
            let _ = wait_pid(pid);
            return Err(error);
        }
    }

    let guardian_pid = unsafe { libc::fork() };
    if guardian_pid < 0 {
        let error = io::Error::last_os_error();
        close_fd(agent_release[1]);
        close_fd(guardian_liveness[0]);
        close_fd(guardian_liveness[1]);
        close_fd(guardian_ack[0]);
        close_fd(guardian_ack[1]);
        close_fd(exec_status[0]);
        close_fd(master);
        let _ = wait_pid(pid);
        return Err(error);
    }
    if guardian_pid == 0 {
        close_fd(master);
        close_fd(exec_status[0]);
        close_fd(agent_release[1]);
        close_fd(guardian_liveness[1]);
        close_fd(guardian_ack[0]);
        let result = run_process_group_guardian(guardian_liveness[0], pid, guardian_ack[1]);
        close_fd(guardian_liveness[0]);
        close_fd(guardian_ack[1]);
        unsafe { libc::_exit(if result.is_ok() { 0 } else { 1 }) };
    }

    close_fd(guardian_liveness[0]);
    close_fd(guardian_ack[1]);
    let guardian_ready = read_ack(guardian_ack[0]);
    close_fd(guardian_ack[0]);
    if !matches!(guardian_ready, Ok(0)) {
        close_fd(agent_release[1]);
        close_fd(guardian_liveness[1]);
        close_fd(exec_status[0]);
        close_fd(master);
        let _ = wait_pid(pid);
        let _ = wait_pid(guardian_pid);
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "process-group guardian failed before Agent execve",
        ));
    }
    if let Err(error) = write_ack(agent_release[1], 0) {
        close_fd(agent_release[1]);
        close_fd(guardian_liveness[1]);
        close_fd(exec_status[0]);
        close_fd(master);
        let _ = wait_pid(pid);
        let _ = wait_pid(guardian_pid);
        return Err(error);
    }
    close_fd(agent_release[1]);
    let guardian = ProcessGroupGuardian {
        pid: guardian_pid,
        _liveness: unsafe { File::from_raw_fd(guardian_liveness[1]) },
    };

    let mut status = [0u8; 1];
    let status_read = loop {
        let result = unsafe { libc::read(exec_status[0], status.as_mut_ptr().cast(), 1) };
        if result >= 0 {
            break result;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            close_fd(exec_status[0]);
            close_fd(master);
            cleanup_guarded_agent(pid, pid, guardian);
            return Err(error);
        }
    };
    close_fd(exec_status[0]);
    if status_read != 0 {
        close_fd(master);
        cleanup_guarded_agent(pid, pid, guardian);
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Agent execve failed",
        ));
    }

    let reader_fd = unsafe { libc::fcntl(master, libc::F_DUPFD_CLOEXEC, 3) };
    if reader_fd < 0 {
        let error = io::Error::last_os_error();
        close_fd(master);
        cleanup_guarded_agent(pid, pid, guardian);
        return Err(error);
    }
    Ok(SpawnedAgent {
        pid,
        pgid: pid,
        master: Arc::new(Mutex::new(unsafe { File::from_raw_fd(master) })),
        reader: unsafe { File::from_raw_fd(reader_fd) },
        guardian: Arc::new(guardian),
    })
}

fn run_process_group_guardian(
    liveness_fd: RawFd,
    agent_pgid: libc::pid_t,
    ack_fd: RawFd,
) -> io::Result<()> {
    write_ack(ack_fd, 0)?;
    loop {
        let mut byte = 0u8;
        let read = unsafe { libc::read(liveness_fd, (&mut byte as *mut u8).cast(), 1) };
        if read == 0 {
            break;
        }
        if read > 0 {
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    signal_process_group(agent_pgid, libc::SIGKILL)
}

fn cleanup_guarded_agent(pid: libc::pid_t, pgid: libc::pid_t, guardian: ProcessGroupGuardian) {
    let guardian_pid = guardian.pid;
    drop(guardian);
    let _ = request_process_group_stop(pgid);
    let _ = wait_pid(pid);
    let _ = wait_pid(guardian_pid);
}

fn process_environment() -> io::Result<Vec<CString>> {
    env::vars_os()
        .map(|(key, value)| {
            let mut entry = key.into_vec();
            entry.push(b'=');
            entry.extend_from_slice(value.as_bytes());
            CString::new(entry).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "environment contains NUL")
            })
        })
        .collect()
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn spawn_agent_watcher(
    state: Arc<BrokerState>,
    session_id: String,
    pid: libc::pid_t,
    pgid: libc::pid_t,
    guardian: Arc<ProcessGroupGuardian>,
    completion: Arc<Completion>,
) -> io::Result<()> {
    thread::Builder::new()
        .name(format!("winsmux-agent-wait-{pid}"))
        .spawn(move || {
            let exited_state = state.clone();
            let exited_session_id = session_id.clone();
            let result = wait_for_agent_group(pid, pgid, move || {
                exited_state.mark_agent_exited(&exited_session_id);
            })
            .map_err(|error| error.to_string());
            lock_mutex(&state.inner).sessions.remove(&session_id);
            let guardian_pid = guardian.pid;
            drop(guardian);
            let guardian_result = wait_pid(guardian_pid).map_err(|error| error.to_string());
            completion.finish(result.and(guardian_result));
            state.wake();
        })?;
    Ok(())
}

fn spawn_output_reader(
    state: Arc<BrokerState>,
    session_id: String,
    mut reader: File,
    gate: Arc<(Mutex<bool>, Condvar)>,
) -> io::Result<()> {
    thread::Builder::new()
        .name("winsmux-pty-output".to_string())
        .spawn(move || {
            let (open, ready) = &*gate;
            let mut open = lock_mutex(open);
            while !*open {
                open = match ready.wait(open) {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
            }
            drop(open);

            let mut buffer = [0u8; MAX_PTY_IO_CHUNK];
            loop {
                let count = match reader.read(&mut buffer) {
                    Ok(0) => return,
                    Ok(count) => count,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        if wait_for_pty_readable(reader.as_raw_fd()).is_err() {
                            return;
                        }
                        continue;
                    }
                    Err(error) if error.raw_os_error() == Some(libc::EIO) => return,
                    Err(_) => return,
                };
                let controller = {
                    let inner = lock_mutex(&state.inner);
                    inner
                        .sessions
                        .get(&session_id)
                        .and_then(|session| session.controller.as_ref())
                        .filter(|controller| controller.active)
                        .map(|controller| {
                            (
                                controller.writer.clone(),
                                controller.frontend_id,
                                controller.peer_frame_limit,
                            )
                        })
                };
                if let Some((controller, frontend_id, peer_frame_limit)) = controller {
                    let message = Message::PtyOutput {
                        data_b64: encode_base64(&buffer[..count]),
                    };
                    let mut controller = lock_mutex(&controller);
                    let still_active = {
                        let inner = lock_mutex(&state.inner);
                        inner
                            .sessions
                            .get(&session_id)
                            .and_then(|session| session.controller.as_ref())
                            .is_some_and(|current| {
                                current.frontend_id == frontend_id && current.active
                            })
                    };
                    if still_active
                        && encode_payload(&message)
                            .is_ok_and(|payload| payload.len() <= peer_frame_limit as usize)
                    {
                        let _ = write_frame(&mut *controller, &message);
                    }
                }
            }
        })?;
    Ok(())
}

fn request_process_group_stop(pgid: libc::pid_t) -> io::Result<()> {
    signal_process_group(pgid, libc::SIGTERM)?;
    signal_process_group(pgid, libc::SIGKILL)
}

fn signal_process_group(pgid: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    if unsafe { libc::kill(-pgid, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}

fn wait_for_agent_group<F>(pid: libc::pid_t, pgid: libc::pid_t, agent_exited: F) -> io::Result<()>
where
    F: FnOnce(),
{
    wait_pid(pid)?;
    agent_exited();
    request_process_group_stop(pgid)?;
    reap_process_group(pgid)?;
    prove_process_group_gone(pgid)
}

fn stop_and_reap_without_watcher(pid: libc::pid_t, pgid: libc::pid_t) -> io::Result<()> {
    request_process_group_stop(pgid)?;
    wait_pid(pid)?;
    reap_process_group(pgid)?;
    prove_process_group_gone(pgid)
}

fn reap_process_group(pgid: libc::pid_t) -> io::Result<()> {
    loop {
        let result = unsafe { libc::waitpid(-pgid, ptr::null_mut(), 0) };
        if result > 0 {
            continue;
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::ECHILD) => return Ok(()),
            _ => return Err(error),
        }
    }
}

fn prove_process_group_gone(pgid: libc::pid_t) -> io::Result<()> {
    if unsafe { libc::kill(-pgid, 0) } == -1 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(error);
    }
    Err(io::Error::new(
        io::ErrorKind::Other,
        "Agent process group still exists after SIGKILL and reap",
    ))
}

fn resize_pty(fd: RawFd, cols: u16, rows: u16) -> io::Result<()> {
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &size as *const libc::winsize) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn wait_for_pty_readable(fd: RawFd) -> io::Result<()> {
    let mut poll_fd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    loop {
        let result = unsafe { libc::poll(&mut poll_fd, 1, -1) };
        if result > 0 {
            return Ok(());
        }
        if result == 0 {
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn write_pty_input(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written > 0 {
            bytes = &bytes[written as usize..];
            continue;
        }
        if written == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "PTY accepted no input bytes",
            ));
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() == io::ErrorKind::WouldBlock {
            // The protocol has no durable input queue or replay contract.
            // Drop the remainder rather than holding the controller thread
            // indefinitely while an Agent does not read its stdin.
            return Ok(());
        }
        return Err(error);
    }
    Ok(())
}

fn write_all_fd(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written > 0 {
            bytes = &bytes[written as usize..];
            continue;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    Ok(())
}
