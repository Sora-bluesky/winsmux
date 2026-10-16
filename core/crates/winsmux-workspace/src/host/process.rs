use super::io::{IoError, OwnedHandle};
use std::ffi::c_void;
use std::mem::size_of;
use std::path::Path;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    CloseHandle, SetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE,
    WAIT_OBJECT_0,
};
#[cfg(debug_assertions)]
use windows_sys::Win32::System::Threading::STARTUPINFOW;
use windows_sys::Win32::System::Threading::{
    CreateProcessW, DeleteProcThreadAttributeList, GetExitCodeProcess,
    InitializeProcThreadAttributeList, UpdateProcThreadAttribute, WaitForSingleObject,
    CREATE_NO_WINDOW, EXTENDED_STARTUPINFO_PRESENT, INFINITE, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROCESS_INFORMATION, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, STARTF_USESTDHANDLES, STARTUPINFOEXW,
};

struct AttributeList {
    storage: Vec<usize>,
    _handles: Box<[HANDLE]>,
}

impl AttributeList {
    fn for_handles(handles: &[HANDLE]) -> Result<Self, IoError> {
        let mut required = 0usize;
        unsafe {
            InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut required);
        }
        if required == 0 {
            return Err(IoError::Failed);
        }
        let mut storage = vec![0usize; required.div_ceil(size_of::<usize>())];
        let list = storage.as_mut_ptr().cast::<c_void>();
        if unsafe { InitializeProcThreadAttributeList(list, 1, 0, &mut required) } == 0 {
            return Err(IoError::Failed);
        }
        let mut attributes = Self {
            storage,
            _handles: handles.to_vec().into_boxed_slice(),
        };
        let handles_ptr = attributes._handles.as_ptr().cast::<c_void>();
        let handles_size = std::mem::size_of_val(attributes._handles.as_ref());
        let updated = unsafe {
            UpdateProcThreadAttribute(
                attributes.raw(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles_ptr,
                handles_size,
                null_mut(),
                null(),
            )
        };
        if updated == 0 {
            return Err(IoError::Failed);
        }
        Ok(attributes)
    }

    fn raw(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_mut_ptr().cast::<c_void>()
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.raw());
        }
    }
}

pub(crate) struct ChildProcess {
    process: OwnedHandle,
}

impl ChildProcess {
    #[cfg(all(test, windows, debug_assertions, feature = "native-e2e-faults"))]
    pub(crate) fn raw(&self) -> HANDLE {
        self.process.raw()
    }
    pub(crate) fn wait(&self) -> Result<u32, IoError> {
        if unsafe { WaitForSingleObject(self.process.raw(), INFINITE) } != WAIT_OBJECT_0 {
            return Err(IoError::Failed);
        }
        let mut code = 0u32;
        if unsafe { GetExitCodeProcess(self.process.raw(), &mut code) } == 0 {
            return Err(IoError::Failed);
        }
        Ok(code)
    }
}

pub(crate) fn spawn_host(owner_handle: HANDLE) -> Result<ChildProcess, IoError> {
    let executable = std::env::current_exe().map_err(|_| IoError::Failed)?;
    spawn_host_at(owner_handle, &executable)
}

pub(crate) fn spawn_host_at(
    owner_handle: HANDLE,
    executable: &Path,
) -> Result<ChildProcess, IoError> {
    spawn_selected(
        executable,
        &[owner_handle],
        &format!("__host-child {:x}", owner_handle as usize),
    )
}

#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
pub(crate) fn spawn_stop_reply_loss(
    executable: &Path,
    handles: &[HANDLE; 4],
) -> Result<ChildProcess, IoError> {
    spawn_selected(
        executable,
        handles,
        &format!(
            "__task870-host-stop-reply-loss {:x} {:x} {:x} {:x}",
            handles[0] as usize, handles[1] as usize, handles[2] as usize, handles[3] as usize
        ),
    )
}

fn spawn_selected(
    executable: &Path,
    handles: &[HANDLE],
    arguments: &str,
) -> Result<ChildProcess, IoError> {
    // Restore every flag even if a later handle or CreateProcess fails.
    struct InheritanceReset<'a>(&'a [HANDLE]);
    impl Drop for InheritanceReset<'_> {
        fn drop(&mut self) {
            for handle in self.0 {
                unsafe {
                    SetHandleInformation(*handle, HANDLE_FLAG_INHERIT, 0);
                }
            }
        }
    }
    let _reset = InheritanceReset(handles);
    for handle in handles {
        if unsafe { SetHandleInformation(*handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) } == 0 {
            return Err(IoError::Failed);
        }
    }

    let result = (|| {
        let mut attributes = AttributeList::for_handles(handles)?;
        let executable_text = executable.to_str().ok_or(IoError::Failed)?;
        let command_line = format!(
            "{} workspace {}",
            quote_windows_argument(executable_text),
            arguments
        );
        let executable_wide: Vec<u16> = executable_text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut command_wide: Vec<u16> = command_line
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();

        let mut startup = STARTUPINFOEXW::default();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
        startup.lpAttributeList = attributes.raw();

        let mut information = PROCESS_INFORMATION::default();
        let created = unsafe {
            CreateProcessW(
                executable_wide.as_ptr(),
                command_wide.as_mut_ptr(),
                null(),
                null(),
                1,
                CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                null(),
                null(),
                &startup.StartupInfo,
                &mut information,
            )
        };
        if created == 0 {
            return Err(IoError::Failed);
        }
        unsafe {
            CloseHandle(information.hThread);
        }
        let process = unsafe { OwnedHandle::from_raw(information.hProcess)? };
        Ok(ChildProcess { process })
    })();

    result
}

#[cfg(debug_assertions)]
pub(crate) fn spawn_inheritance_helper(
    owner_handle: HANDLE,
    report_handle: HANDLE,
    release_handle: HANDLE,
    launcher_pid: u32,
) -> Result<ChildProcess, IoError> {
    for handle in [report_handle, release_handle] {
        if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) } == 0 {
            return Err(IoError::Failed);
        }
    }

    let result = (|| {
        let executable = std::env::current_exe().map_err(|_| IoError::Failed)?;
        let executable_text = executable.to_str().ok_or(IoError::Failed)?;
        let command_line = format!(
            "{} workspace __test-inherit-helper {:x} {:x} {:x} {}",
            quote_windows_argument(executable_text),
            owner_handle as usize,
            report_handle as usize,
            release_handle as usize,
            launcher_pid
        );
        let executable_wide: Vec<u16> = executable_text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut command_wide: Vec<u16> = command_line
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();

        let mut startup = STARTUPINFOW::default();
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = INVALID_HANDLE_VALUE;
        startup.hStdOutput = INVALID_HANDLE_VALUE;
        startup.hStdError = INVALID_HANDLE_VALUE;
        let mut information = PROCESS_INFORMATION::default();
        let created = unsafe {
            CreateProcessW(
                executable_wide.as_ptr(),
                command_wide.as_mut_ptr(),
                null(),
                null(),
                1,
                CREATE_NO_WINDOW,
                null(),
                null(),
                &startup,
                &mut information,
            )
        };
        if created == 0 {
            return Err(IoError::Failed);
        }
        unsafe {
            CloseHandle(information.hThread);
        }
        let process = unsafe { OwnedHandle::from_raw(information.hProcess)? };
        Ok(ChildProcess { process })
    })();

    for handle in [report_handle, release_handle] {
        unsafe {
            SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
        }
    }
    result
}

pub(crate) fn quote_windows_argument(argument: &str) -> String {
    if !argument.is_empty()
        && !argument
            .chars()
            .any(|character| character.is_whitespace() || character == '"')
    {
        return argument.to_owned();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for character in argument.chars() {
        if character == '\\' {
            backslashes += 1;
            continue;
        }
        if character == '"' {
            quoted.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
            quoted.push('"');
        } else {
            quoted.extend(std::iter::repeat_n('\\', backslashes));
            quoted.push(character);
        }
        backslashes = 0;
    }
    quoted.extend(std::iter::repeat_n('\\', backslashes * 2));
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::quote_windows_argument;

    #[test]
    fn quotes_windows_arguments_without_changing_backslashes() {
        assert_eq!(quote_windows_argument("plain.exe"), "plain.exe");
        assert_eq!(
            quote_windows_argument(r"C:\Program Files\winsmux.exe"),
            r#""C:\Program Files\winsmux.exe""#
        );
        assert_eq!(quote_windows_argument(r#"a\"b"#), r#""a\\\"b""#);
    }
}
