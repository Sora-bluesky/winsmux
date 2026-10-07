use serde_json::Value;
use std::io::Read;
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, WAIT_FAILED, WAIT_OBJECT_0,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetExitCodeProcess, SetEvent, WaitForMultipleObjects, WaitForSingleObject,
    INFINITE,
};

enum StreamEvent {
    Chunk(Vec<u8>),
    Eof,
    Failed,
}

struct Event(HANDLE);

unsafe impl Send for Event {}
unsafe impl Sync for Event {}

impl Event {
    fn new() -> Self {
        let handle = unsafe { CreateEventW(std::ptr::null(), 0, 0, std::ptr::null()) };
        assert!(!handle.is_null(), "create output event: {}", unsafe {
            GetLastError()
        });
        Self(handle)
    }
}

impl Drop for Event {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

pub struct JsonOutput {
    receiver: mpsc::Receiver<StreamEvent>,
    capture: Arc<Mutex<Vec<u8>>>,
    pending: Mutex<Vec<u8>>,
    ready: Arc<Event>,
    thread: Option<JoinHandle<()>>,
}

#[derive(Debug)]
pub struct ChildExit {
    pub reason: &'static str,
    pub signaled: bool,
    pub exit_code: Option<u32>,
}

impl JsonOutput {
    pub fn start(reader: Box<dyn Read + Send>) -> Self {
        let (sender, receiver) = mpsc::channel();
        let ready = Arc::new(Event::new());
        let thread_ready = ready.clone();
        let capture = Arc::new(Mutex::new(Vec::new()));
        let thread_capture = capture.clone();
        let thread = std::thread::spawn(move || {
            let mut reader = reader;
            loop {
                let mut chunk = vec![0u8; 4096];
                let event = match reader.read(&mut chunk) {
                    Ok(0) => StreamEvent::Eof,
                    Ok(read) => {
                        chunk.truncate(read);
                        if let Ok(mut captured) = thread_capture.lock() {
                            captured.extend_from_slice(&chunk);
                        }
                        StreamEvent::Chunk(chunk)
                    }
                    Err(_) => StreamEvent::Failed,
                };
                let finished = !matches!(event, StreamEvent::Chunk(_));
                if sender.send(event).is_err() {
                    return;
                }
                unsafe { SetEvent(thread_ready.0) };
                if finished {
                    return;
                }
            }
        });
        Self {
            receiver,
            capture,
            pending: Mutex::new(Vec::new()),
            ready,
            thread: Some(thread),
        }
    }

    fn child_exit(process: HANDLE, reason: &'static str) -> ChildExit {
        let signaled = unsafe { WaitForSingleObject(process, 0) } == WAIT_OBJECT_0;
        let mut code = 0;
        let queried = unsafe { GetExitCodeProcess(process, &mut code) } != 0;
        ChildExit {
            reason,
            signaled,
            exit_code: queried.then_some(code),
        }
    }

    fn consume(&self, event: StreamEvent) {
        match event {
            StreamEvent::Chunk(chunk) => self.pending.lock().expect("pending output").extend(chunk),
            StreamEvent::Eof => panic!(
                "output ended before JSON response: output={}",
                String::from_utf8_lossy(&self.captured())
            ),
            StreamEvent::Failed => panic!(
                "failed to read process output: output={}",
                String::from_utf8_lossy(&self.captured())
            ),
        }
    }

    pub fn next_json(&self) -> Value {
        loop {
            if let Some(value) = extract_json(&mut self.pending.lock().expect("pending output")) {
                return value;
            }
            self.consume(self.receiver.recv().expect("output stream event"));
        }
    }

    pub fn next_json_with_process(&self, process: HANDLE) -> Result<Value, ChildExit> {
        loop {
            if let Some(value) = extract_json(&mut self.pending.lock().expect("pending output")) {
                return Ok(value);
            }
            match self.receiver.try_recv() {
                Ok(StreamEvent::Chunk(chunk)) => {
                    self.pending.lock().expect("pending output").extend(chunk);
                    continue;
                }
                Ok(StreamEvent::Eof) => return Err(Self::child_exit(process, "output_eof")),
                Ok(StreamEvent::Failed) => {
                    return Err(Self::child_exit(process, "output_read_failed"))
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(Self::child_exit(process, "output_reader_disconnected"));
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
            // Output wins a simultaneous signal. The queued chunk is checked
            // again after process exit before classifying an incomplete frame.
            let handles = [self.ready.0, process];
            match unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) } {
                WAIT_OBJECT_0 => {}
                value if value == WAIT_OBJECT_0 + 1 => {
                    while let Ok(event) = self.receiver.try_recv() {
                        match event {
                            StreamEvent::Chunk(chunk) => {
                                self.pending.lock().expect("pending output").extend(chunk);
                            }
                            StreamEvent::Eof => {
                                return Err(Self::child_exit(process, "output_eof"))
                            }
                            StreamEvent::Failed => {
                                return Err(Self::child_exit(process, "output_read_failed"));
                            }
                        }
                        if let Some(value) =
                            extract_json(&mut self.pending.lock().expect("pending output"))
                        {
                            return Ok(value);
                        }
                    }
                    return Err(Self::child_exit(process, "client_exited_before_json"));
                }
                WAIT_FAILED => panic!("wait for output or client failed: {}", unsafe {
                    GetLastError()
                }),
                other => panic!("unexpected output/client wait result: {other}"),
            }
        }
    }

    pub fn captured(&self) -> Vec<u8> {
        self.capture.lock().expect("output capture").clone()
    }

    pub fn finish_json_after_reader_join(&self) -> Option<Value> {
        assert!(self.thread.is_none(), "output reader must be joined first");
        if let Some(value) = extract_json(&mut self.pending.lock().expect("pending output")) {
            return Some(value);
        }
        while let Ok(event) = self.receiver.try_recv() {
            if let StreamEvent::Chunk(chunk) = event {
                self.pending.lock().expect("pending output").extend(chunk);
                if let Some(value) = extract_json(&mut self.pending.lock().expect("pending output"))
                {
                    return Some(value);
                }
            }
        }
        None
    }

    pub fn join(&mut self) {
        if let Some(thread) = self.thread.take() {
            thread.join().expect("output reader thread");
        }
    }

    pub fn join_nonpanic(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

pub fn extract_json(buffer: &mut Vec<u8>) -> Option<Value> {
    let start = buffer.iter().position(|byte| *byte == b'{')?;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for index in start..buffer.len() {
        let byte = buffer[index];
        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    let value = serde_json::from_slice(&buffer[start..=index]).ok()?;
                    buffer.drain(..=index);
                    return Some(value);
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, Cursor};
    use windows_sys::Win32::Foundation::GetHandleInformation;

    struct ChannelReader(mpsc::Receiver<Vec<u8>>);

    impl Read for ChannelReader {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            match self.0.recv() {
                Ok(chunk) => {
                    assert!(chunk.len() <= output.len());
                    output[..chunk.len()].copy_from_slice(&chunk);
                    Ok(chunk.len())
                }
                Err(_) => Ok(0),
            }
        }
    }

    struct FailedReader;

    impl Read for FailedReader {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("intentional read failure"))
        }
    }

    fn process_signal(signaled: bool) -> Event {
        let handle =
            unsafe { CreateEventW(std::ptr::null(), 1, signaled.into(), std::ptr::null()) };
        assert!(!handle.is_null());
        Event(handle)
    }

    #[test]
    fn valid_json_precedes_queued_eof_and_output_event_is_released() {
        let process = process_signal(false);
        let mut output = JsonOutput::start(Box::new(Cursor::new(b"prefix {\"ok\":true}".to_vec())));
        assert_eq!(
            output.next_json_with_process(process.0).unwrap(),
            serde_json::json!({"ok": true})
        );
        output.join();
        assert_eq!(output.captured(), b"prefix {\"ok\":true}");
        let ready = output.ready.0;
        drop(output);
        let mut flags = 0;
        assert_eq!(unsafe { GetHandleInformation(ready, &mut flags) }, 0);
    }

    #[test]
    fn final_json_after_child_exit_is_recovered_after_reader_join() {
        let process = process_signal(true);
        let (sender, receiver) = mpsc::channel();
        let mut output = JsonOutput::start(Box::new(ChannelReader(receiver)));
        let exit = output.next_json_with_process(process.0).unwrap_err();
        assert!(exit.signaled);
        sender.send(b"{\"final\":true}".to_vec()).unwrap();
        drop(sender);
        output.join();
        assert_eq!(
            output.finish_json_after_reader_join(),
            Some(serde_json::json!({"final": true}))
        );
    }

    #[test]
    fn partial_json_after_child_exit_remains_a_failure_with_captured_bytes() {
        let process = process_signal(true);
        let (sender, receiver) = mpsc::channel();
        let mut output = JsonOutput::start(Box::new(ChannelReader(receiver)));
        assert!(output.next_json_with_process(process.0).is_err());
        sender.send(b"{\"partial\":".to_vec()).unwrap();
        drop(sender);
        output.join();
        assert_eq!(output.finish_json_after_reader_join(), None);
        assert_eq!(output.captured(), b"{\"partial\":");
    }

    #[test]
    fn read_failure_is_reported_without_waiting_for_child_exit() {
        let process = process_signal(false);
        let mut output = JsonOutput::start(Box::new(FailedReader));
        let exit = output.next_json_with_process(process.0).unwrap_err();
        assert_eq!(exit.reason, "output_read_failed");
        assert!(!exit.signaled);
        output.join();
        assert_eq!(output.finish_json_after_reader_join(), None);
    }

    #[test]
    fn consecutive_chunks_do_not_lose_output_notifications() {
        let process = process_signal(false);
        let (sender, receiver) = mpsc::channel();
        let mut output = JsonOutput::start(Box::new(ChannelReader(receiver)));
        sender.send(b"{\"one\":1}".to_vec()).unwrap();
        sender.send(b"{\"two\":2}".to_vec()).unwrap();
        assert_eq!(
            output.next_json_with_process(process.0).unwrap(),
            serde_json::json!({"one": 1})
        );
        assert_eq!(
            output.next_json_with_process(process.0).unwrap(),
            serde_json::json!({"two": 2})
        );
        drop(sender);
        output.join();
    }

    #[test]
    fn eof_without_json_is_reported() {
        let process = process_signal(false);
        let mut output = JsonOutput::start(Box::new(Cursor::new(Vec::new())));
        let exit = output.next_json_with_process(process.0).unwrap_err();
        assert_eq!(exit.reason, "output_eof");
        output.join();
        assert_eq!(output.finish_json_after_reader_join(), None);
    }
}
