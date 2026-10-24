//! Bounded newline-delimited input for the MCP stdio process.

use crate::MAX_MCP_MESSAGE_BYTES;
use std::io::BufRead;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineError {
    TooLarge,
    InvalidUtf8,
    IncompleteLine,
    Io,
}

/// Reads one LF or CRLF terminated message. UTF-8 is validated only after the
/// complete line has arrived, so a code point split between OS reads is legal.
/// At most `MAX_MCP_MESSAGE_BYTES` payload bytes enter the returned buffer.
pub fn read_line(reader: &mut impl BufRead) -> Result<Option<Vec<u8>>, LineError> {
    let mut line = Vec::new();
    let mut pending_cr = false;
    loop {
        let available = reader.fill_buf().map_err(|_| LineError::Io)?;
        if available.is_empty() {
            return if line.is_empty() && !pending_cr {
                Ok(None)
            } else {
                Err(LineError::IncompleteLine)
            };
        }
        if pending_cr {
            if available[0] == b'\n' {
                reader.consume(1);
                std::str::from_utf8(&line).map_err(|_| LineError::InvalidUtf8)?;
                return Ok(Some(line));
            }
            push(&mut line, b"\r")?;
            pending_cr = false;
        }
        let available = reader.fill_buf().map_err(|_| LineError::Io)?;
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            let mut payload_end = newline;
            if payload_end > 0 && available[payload_end - 1] == b'\r' {
                payload_end -= 1;
            }
            push(&mut line, &available[..payload_end])?;
            reader.consume(newline + 1);
            std::str::from_utf8(&line).map_err(|_| LineError::InvalidUtf8)?;
            return Ok(Some(line));
        }
        let available_len = available.len();
        let mut payload_end = available_len;
        if available[payload_end - 1] == b'\r' {
            payload_end -= 1;
            pending_cr = true;
        }
        push(&mut line, &available[..payload_end])?;
        reader.consume(available_len);
    }
}

fn push(line: &mut Vec<u8>, bytes: &[u8]) -> Result<(), LineError> {
    if line.len().saturating_add(bytes.len()) > MAX_MCP_MESSAGE_BYTES {
        return Err(LineError::TooLarge);
    }
    line.try_reserve_exact(bytes.len()).map_err(|_| LineError::Io)?;
    line.extend_from_slice(bytes);
    Ok(())
}
