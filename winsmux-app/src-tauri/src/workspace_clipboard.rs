//! Private Windows writer. The only caller supplies validated live Discovery JSON.
//! No clipboard reading, arbitrary-text IPC, focus changes, or retry loop.

#[cfg(windows)]
pub(crate) fn write_discovery(hwnd: usize, text: &str) -> Result<(), &'static str> {
    use windows_sys::Win32::{
        Foundation::{GlobalFree, HGLOBAL, HWND},
        System::{
            DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData},
            Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE},
            Ole::CF_UNICODETEXT,
        },
    };

    struct Memory(HGLOBAL);
    impl Drop for Memory {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // Ownership transfers to Windows only after SetClipboardData succeeds.
                unsafe { GlobalFree(self.0); }
            }
        }
    }
    struct Clipboard;
    impl Drop for Clipboard {
        fn drop(&mut self) { unsafe { CloseClipboard(); } }
    }

    if hwnd == 0 { return Err("clipboard_unavailable"); }
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let bytes = wide.len().checked_mul(std::mem::size_of::<u16>()).ok_or("clipboard_write_failed")?;
    // Finish allocation and encoding before any operation that clears the old clipboard.
    let mut memory = Memory(unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) });
    if memory.0.is_null() { return Err("clipboard_write_failed"); }
    let destination = unsafe { GlobalLock(memory.0) };
    if destination.is_null() { return Err("clipboard_write_failed"); }
    unsafe {
        std::ptr::copy_nonoverlapping(wide.as_ptr(), destination.cast::<u16>(), wide.len());
        GlobalUnlock(memory.0);
    }
    // A real main HWND is required: a null owner makes SetClipboardData fail.
    if unsafe { OpenClipboard(hwnd as HWND) } == 0 { return Err("clipboard_unavailable"); }
    let _clipboard = Clipboard;
    if unsafe { EmptyClipboard() } == 0 { return Err("clipboard_write_failed"); }
    if unsafe { SetClipboardData(CF_UNICODETEXT as u32, memory.0) }.is_null() {
        return Err("clipboard_write_failed");
    }
    memory.0 = std::ptr::null_mut();
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn write_discovery(_hwnd: usize, _text: &str) -> Result<(), &'static str> {
    Err("clipboard_unavailable")
}
