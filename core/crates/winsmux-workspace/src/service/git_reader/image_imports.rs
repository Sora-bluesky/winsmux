//! Bounded PE import inspection on the held executable handle, before launch.

use crate::contract::ErrorCode;
use crate::host::admission::ACTIVE_BYTES;
use std::io::Read;
use std::os::windows::io::FromRawHandle;
use windows_sys::Win32::Foundation::{DuplicateHandle, HANDLE, DUPLICATE_SAME_ACCESS};
use windows_sys::Win32::System::Threading::GetCurrentProcess;

fn u16_at(bytes: &[u8], at: usize) -> Result<u16, ErrorCode> {
    let end = at.checked_add(2).ok_or(ErrorCode::UnsupportedFile)?;
    Ok(u16::from_le_bytes(bytes.get(at..end).ok_or(ErrorCode::UnsupportedFile)?.try_into().unwrap()))
}

fn u32_at(bytes: &[u8], at: usize) -> Result<u32, ErrorCode> {
    let end = at.checked_add(4).ok_or(ErrorCode::UnsupportedFile)?;
    Ok(u32::from_le_bytes(bytes.get(at..end).ok_or(ErrorCode::UnsupportedFile)?.try_into().unwrap()))
}

fn file_offset(bytes: &[u8], sections: usize, count: usize, headers: usize, rva: u32) -> Result<usize, ErrorCode> {
    let rva = rva as usize;
    if rva < headers && rva < bytes.len() { return Ok(rva); }
    for index in 0..count {
        let at = sections.checked_add(index.checked_mul(40).ok_or(ErrorCode::UnsupportedFile)?)
            .ok_or(ErrorCode::UnsupportedFile)?;
        let virtual_size = u32_at(bytes, at + 8)? as usize;
        let start = u32_at(bytes, at + 12)? as usize;
        let raw_size = u32_at(bytes, at + 16)? as usize;
        let raw_start = u32_at(bytes, at + 20)? as usize;
        if rva >= start && rva < start.saturating_add(virtual_size.max(raw_size)) {
            let displacement = rva - start;
            if displacement >= raw_size { return Err(ErrorCode::UnsupportedFile); }
            let offset = raw_start.checked_add(displacement).ok_or(ErrorCode::UnsupportedFile)?;
            if offset >= bytes.len() { return Err(ErrorCode::UnsupportedFile); }
            return Ok(offset);
        }
    }
    Err(ErrorCode::UnsupportedFile)
}

fn module_name(bytes: &[u8], sections: usize, count: usize, headers: usize, rva: u32) -> Result<String, ErrorCode> {
    let offset = file_offset(bytes, sections, count, headers, rva)?;
    let tail = bytes.get(offset..).ok_or(ErrorCode::UnsupportedFile)?;
    let end = tail.iter().take(260).position(|byte| *byte == 0).ok_or(ErrorCode::UnsupportedFile)?;
    let name = std::str::from_utf8(&tail[..end]).map_err(|_| ErrorCode::UnsupportedFile)?;
    if !name.ends_with(".dll") || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')) {
        return Err(ErrorCode::UnsupportedFile);
    }
    let name = name.to_ascii_lowercase();
    let system = matches!(name.as_str(),
        "advapi32.dll" | "bcrypt.dll" | "bcryptprimitives.dll" | "combase.dll"
        | "kernel32.dll" | "msi.dll" | "ntdll.dll" | "ole32.dll"
        | "secur32.dll" | "shell32.dll" | "shlwapi.dll"
        | "user32.dll" | "userenv.dll" | "vcruntime140.dll" | "ws2_32.dll");
    if !system && !name.starts_with("api-ms-win-") && !name.starts_with("ext-ms-win-") {
        return Err(ErrorCode::UnsupportedFile);
    }
    Ok(name)
}

pub(super) fn inspect_image_bytes(bytes: &[u8]) -> Result<Vec<String>, ErrorCode> {
    if bytes.get(..2) != Some(b"MZ") { return Err(ErrorCode::UnsupportedFile); }
    let pe = u32_at(bytes, 0x3c)? as usize;
    if bytes.get(pe..pe.checked_add(4).ok_or(ErrorCode::UnsupportedFile)?) != Some(b"PE\0\0") {
        return Err(ErrorCode::UnsupportedFile);
    }
    if u16_at(bytes, pe + 4)? != 0x8664 { return Err(ErrorCode::UnsupportedFile); }
    let count = u16_at(bytes, pe + 6)? as usize;
    if count == 0 || count > 96 { return Err(ErrorCode::UnsupportedFile); }
    let optional_size = u16_at(bytes, pe + 20)? as usize;
    let optional = pe.checked_add(24).ok_or(ErrorCode::UnsupportedFile)?;
    let sections = optional.checked_add(optional_size).ok_or(ErrorCode::UnsupportedFile)?;
    if optional_size < 224 || sections.checked_add(count * 40).ok_or(ErrorCode::UnsupportedFile)? > bytes.len()
        || u16_at(bytes, optional)? != 0x20b || u32_at(bytes, optional + 108)? < 14 {
        return Err(ErrorCode::UnsupportedFile);
    }
    let headers = u32_at(bytes, optional + 60)? as usize;
    let mut names = Vec::new();
    for (directory, width, name_offset) in [(1usize, 20usize, 12usize), (13, 32, 4)] {
        let entry = optional + 112 + directory * 8;
        let rva = u32_at(bytes, entry)?;
        let size = u32_at(bytes, entry + 4)? as usize;
        if rva == 0 && size == 0 { continue; }
        if rva == 0 || size < width || size > 4096 { return Err(ErrorCode::UnsupportedFile); }
        let start = file_offset(bytes, sections, count, headers, rva)?;
        let mut terminated = false;
        for index in 0..(size / width) {
            let at = start.checked_add(index * width).ok_or(ErrorCode::UnsupportedFile)?;
            let descriptor = bytes.get(at..at + width).ok_or(ErrorCode::UnsupportedFile)?;
            if descriptor.iter().all(|byte| *byte == 0) { terminated = true; break; }
            if directory == 13 && u32_at(bytes, at)? != 1 { return Err(ErrorCode::UnsupportedFile); }
            names.push(module_name(bytes, sections, count, headers, u32_at(bytes, at + name_offset)?)?);
        }
        if !terminated { return Err(ErrorCode::UnsupportedFile); }
    }
    if names.is_empty() { return Err(ErrorCode::UnsupportedFile); }
    Ok(names)
}

pub(super) fn inspect_held_image(handle: HANDLE) -> Result<Vec<String>, ErrorCode> {
    let mut duplicate = std::ptr::null_mut();
    if unsafe { DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), &mut duplicate,
        0, 0, DUPLICATE_SAME_ACCESS) } == 0 { return Err(ErrorCode::RuntimeFailed); }
    let mut file = unsafe { std::fs::File::from_raw_handle(duplicate) };
    let size = file.metadata().map_err(|_| ErrorCode::RuntimeFailed)?.len();
    if size == 0 || size > ACTIVE_BYTES as u64 { return Err(ErrorCode::ResourceExhausted); }
    let size = size as usize;
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(size).map_err(|_| ErrorCode::ResourceExhausted)?;
    bytes.resize(size, 0);
    file.read_exact(&mut bytes).map_err(|_| ErrorCode::RuntimeFailed)?;
    inspect_image_bytes(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image_with_import(name: &str, delay: bool) -> Vec<u8> {
        let mut bytes = vec![0u8; 0x600];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[0x3c..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        bytes[0x80..0x84].copy_from_slice(b"PE\0\0");
        bytes[0x84..0x86].copy_from_slice(&0x8664u16.to_le_bytes());
        bytes[0x86..0x88].copy_from_slice(&1u16.to_le_bytes());
        bytes[0x94..0x96].copy_from_slice(&240u16.to_le_bytes());
        let optional = 0x98;
        bytes[optional..optional + 2].copy_from_slice(&0x20bu16.to_le_bytes());
        bytes[optional + 60..optional + 64].copy_from_slice(&0x200u32.to_le_bytes());
        bytes[optional + 108..optional + 112].copy_from_slice(&16u32.to_le_bytes());
        let section = optional + 240;
        for (offset, value) in [(8, 0x400u32), (12, 0x1000), (16, 0x400), (20, 0x200)] {
            bytes[section + offset..section + offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        let (directory, width, name_offset) = if delay { (13, 32, 4) } else { (1, 20, 12) };
        let entry = optional + 112 + directory * 8;
        bytes[entry..entry + 4].copy_from_slice(&0x1000u32.to_le_bytes());
        bytes[entry + 4..entry + 8].copy_from_slice(&((width * 2) as u32).to_le_bytes());
        if delay { bytes[0x200..0x204].copy_from_slice(&1u32.to_le_bytes()); }
        bytes[0x200 + name_offset..0x204 + name_offset].copy_from_slice(&0x1100u32.to_le_bytes());
        bytes[0x300..0x300 + name.len()].copy_from_slice(name.as_bytes());
        bytes
    }

    #[test]
    fn exact_system_imports_are_accepted_in_normal_and_delay_descriptors() {
        for delay in [false, true] {
            for name in ["ole32.dll", "shlwapi.dll", "msi.dll"] {
                assert_eq!(inspect_image_bytes(&image_with_import(name, delay)), Ok(vec![name.to_owned()]),
                    "name={name} delay={delay}");
            }
        }
    }

    #[test]
    fn unknown_and_path_imports_are_rejected_in_normal_and_delay_descriptors() {
        for delay in [false, true] {
            for name in ["unknown.dll", r"C:\outside\ole32.dll", "sub/ole32.dll", r"..\msi.dll"] {
                assert_eq!(inspect_image_bytes(&image_with_import(name, delay)).err(),
                    Some(ErrorCode::UnsupportedFile), "name={name} delay={delay}");
            }
        }
    }

    #[test]
    fn installed_image_has_only_expected_import_modules() {
        let target = std::env::current_exe().unwrap().parent().unwrap().parent().unwrap().parent().unwrap().to_owned();
        for configuration in ["debug", "release"] {
            let exe = target.join(configuration).join("winsmux.exe");
            if !exe.is_file() { continue; }
            let bytes = std::fs::read(exe).unwrap();
            let names = inspect_image_bytes(&bytes).unwrap();
            assert!(names.iter().any(|name| name == "kernel32.dll"));
            let mut malicious = bytes;
            let needle = b"bcryptprimitives.dll\0";
            let offset = malicious.windows(needle.len()).position(|window| window == needle).unwrap();
            malicious[offset..offset + 9].copy_from_slice(b"evil.dll\0");
            assert_eq!(inspect_image_bytes(&malicious).err(), Some(ErrorCode::UnsupportedFile));
        }
    }
}
