use super::*;
use crate::host::admission::{
    AllocationAuthority, AllocationError, AllocationPool, CapacityCharge, ChargedVec, OwnedFrame,
};

// Every request-owned String byte is represented in the frame. The only wider
// request container is Vec<ProjectId>: 24 bytes of element storage plus a
// 36-byte UUID allocation per at least 39 encoded bytes, so two wire bytes are
// a conservative fixed-toolchain bound for all request-owned capacity.
const REQUEST_OWNED_MULTIPLIER: usize = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostCodecPhase {
    Decode,
    Canonical,
}

#[derive(Debug, Eq, PartialEq)]
pub enum HostCodecError {
    Contract(ContractError),
    Exhausted {
        phase: HostCodecPhase,
        correlation: Option<WireCorrelation>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WireCorrelation {
    pub operation: OperationName,
    pub has_instance: bool,
    pub operation_id: OperationId,
    pub instance_id: Option<InstanceId>,
}

pub struct PreparedRequest {
    request: Option<Request>,
    canonical: Option<ChargedVec<u8>>,
    request_charge: Option<CapacityCharge>,
    correlation: WireCorrelation,
}

pub(crate) struct OwnedReply {
    bytes: ChargedVec<u8>,
}

impl OwnedReply {
    #[cfg(test)]
    fn charged_bytes(&self) -> usize {
        self.bytes.capacity_bytes()
    }
}

impl std::ops::Deref for OwnedReply {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.bytes
    }
}

impl PreparedRequest {
    pub fn request(&self) -> &Request {
        self.request.as_ref().expect("prepared request is live")
    }

    pub fn canonical(&self) -> &[u8] {
        self.canonical.as_deref().expect("prepared request is live")
    }

    pub fn correlation(&self) -> &WireCorrelation {
        &self.correlation
    }
}

impl Drop for PreparedRequest {
    fn drop(&mut self) {
        drop(self.canonical.take());
        drop(self.request.take());
        drop(self.request_charge.take());
    }
}

#[derive(Clone, Copy)]
struct Span {
    start: usize,
    end: usize,
}

#[derive(Clone, Copy)]
struct MemberSpan {
    object_id: u32,
    key: Span,
}

#[derive(Default)]
struct RootSlots {
    schema_version: Option<Span>,
    instance_id: Option<Span>,
    operation_id: Option<Span>,
    expected_topology_revision: Option<Span>,
    operation: Option<Span>,
    params: Option<Span>,
    unknown: bool,
}

struct Scanner<'a> {
    bytes: &'a [u8],
    cursor: usize,
    next_object_id: u32,
}

impl<'a> Scanner<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            cursor: 0,
            next_object_id: 0,
        }
    }

    fn scan(&mut self, members: &mut ChargedVec<MemberSpan>) -> Result<RootSlots, ContractError> {
        self.ws();
        if self.peek() != Some(b'{') {
            return Err(ContractError::InvalidShape);
        }
        let mut root = RootSlots::default();
        self.object(1, true, members, &mut root)?;
        self.ws();
        if self.cursor != self.bytes.len() {
            return Err(ContractError::InvalidJson);
        }
        Ok(root)
    }

    fn value(
        &mut self,
        depth: usize,
        members: &mut ChargedVec<MemberSpan>,
        root: &mut RootSlots,
    ) -> Result<(), ContractError> {
        match self.peek() {
            Some(b'{') => self.object(depth, false, members, root),
            Some(b'[') => self.array(depth, members, root),
            Some(b'"') => self.string().map(|_| ()),
            Some(b't') => self.literal(b"true"),
            Some(b'f') => self.literal(b"false"),
            Some(b'n') => self.literal(b"null"),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(ContractError::InvalidJson),
        }
    }

    fn object(
        &mut self,
        depth: usize,
        is_root: bool,
        members: &mut ChargedVec<MemberSpan>,
        root: &mut RootSlots,
    ) -> Result<(), ContractError> {
        if depth > JSON_DEPTH {
            return Err(ContractError::NestingLimit);
        }
        self.take(b'{')?;
        let object_id = self.next_object_id;
        self.next_object_id = self
            .next_object_id
            .checked_add(1)
            .ok_or(ContractError::NestingLimit)?;
        self.ws();
        if self.peek() == Some(b'}') {
            self.cursor += 1;
            return Ok(());
        }
        loop {
            let key = self.string()?;
            if members
                .iter()
                .filter(|member| member.object_id == object_id)
                .any(|member| decoded_equal(self.bytes, member.key, key))
            {
                return Err(ContractError::DuplicateKey);
            }
            members
                .try_push(MemberSpan { object_id, key })
                .map_err(|_| ContractError::MessageTooLarge)?;
            self.ws();
            self.take(b':')?;
            self.ws();
            let start = self.cursor;
            self.value(depth + 1, members, root)?;
            let value = Span {
                start,
                end: self.cursor,
            };
            if is_root {
                match key {
                    key if decoded_equals_text(self.bytes, key, "schema_version") => {
                        root.schema_version = Some(value)
                    }
                    key if decoded_equals_text(self.bytes, key, "instance_id") => {
                        root.instance_id = Some(value)
                    }
                    key if decoded_equals_text(self.bytes, key, "operation_id") => {
                        root.operation_id = Some(value)
                    }
                    key if decoded_equals_text(self.bytes, key, "expected_topology_revision") => {
                        root.expected_topology_revision = Some(value)
                    }
                    key if decoded_equals_text(self.bytes, key, "operation") => {
                        root.operation = Some(value)
                    }
                    key if decoded_equals_text(self.bytes, key, "params") => {
                        root.params = Some(value)
                    }
                    _ => root.unknown = true,
                }
            }
            self.ws();
            match self.peek() {
                Some(b',') => {
                    self.cursor += 1;
                    self.ws();
                }
                Some(b'}') => {
                    self.cursor += 1;
                    return Ok(());
                }
                _ => return Err(ContractError::InvalidJson),
            }
        }
    }

    fn array(
        &mut self,
        depth: usize,
        members: &mut ChargedVec<MemberSpan>,
        root: &mut RootSlots,
    ) -> Result<(), ContractError> {
        if depth > JSON_DEPTH {
            return Err(ContractError::NestingLimit);
        }
        self.take(b'[')?;
        self.ws();
        if self.peek() == Some(b']') {
            self.cursor += 1;
            return Ok(());
        }
        loop {
            self.value(depth + 1, members, root)?;
            self.ws();
            match self.peek() {
                Some(b',') => {
                    self.cursor += 1;
                    self.ws();
                }
                Some(b']') => {
                    self.cursor += 1;
                    return Ok(());
                }
                _ => return Err(ContractError::InvalidJson),
            }
        }
    }

    fn string(&mut self) -> Result<Span, ContractError> {
        self.take(b'"')?;
        let start = self.cursor;
        loop {
            let byte = self.peek().ok_or(ContractError::InvalidJson)?;
            match byte {
                b'"' => {
                    let end = self.cursor;
                    self.cursor += 1;
                    return Ok(Span { start, end });
                }
                0..=0x1f => return Err(ContractError::InvalidJson),
                b'\\' => {
                    self.cursor += 1;
                    match self.peek().ok_or(ContractError::InvalidJson)? {
                        b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => self.cursor += 1,
                        b'u' => {
                            self.cursor += 1;
                            let first = self.hex4()?;
                            if (0xd800..=0xdbff).contains(&first) {
                                if self.bytes.get(self.cursor..self.cursor + 2) != Some(b"\\u") {
                                    return Err(ContractError::InvalidJson);
                                }
                                self.cursor += 2;
                                if !(0xdc00..=0xdfff).contains(&self.hex4()?) {
                                    return Err(ContractError::InvalidJson);
                                }
                            } else if (0xdc00..=0xdfff).contains(&first) {
                                return Err(ContractError::InvalidJson);
                            }
                        }
                        _ => return Err(ContractError::InvalidJson),
                    }
                }
                _ => self.cursor += 1,
            }
        }
    }

    fn hex4(&mut self) -> Result<u16, ContractError> {
        let mut value = 0u16;
        for _ in 0..4 {
            let byte = self.peek().ok_or(ContractError::InvalidJson)?;
            let digit = hex(byte)?;
            value = value
                .checked_mul(16)
                .and_then(|n| n.checked_add(digit))
                .ok_or(ContractError::InvalidJson)?;
            self.cursor += 1;
        }
        Ok(value)
    }

    fn literal(&mut self, literal: &[u8]) -> Result<(), ContractError> {
        if self.bytes.get(self.cursor..self.cursor + literal.len()) == Some(literal) {
            self.cursor += literal.len();
            Ok(())
        } else {
            Err(ContractError::InvalidJson)
        }
    }

    fn number(&mut self) -> Result<(), ContractError> {
        let start = self.cursor;
        if self.peek() == Some(b'-') {
            self.cursor += 1;
        }
        match self.peek() {
            Some(b'0') => self.cursor += 1,
            Some(b'1'..=b'9') => {
                self.cursor += 1;
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.cursor += 1;
                }
            }
            _ => return Err(ContractError::InvalidJson),
        }
        if self.peek() == Some(b'.') {
            self.cursor += 1;
            self.digits()?;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.cursor += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.cursor += 1;
            }
            self.digits()?;
        }
        classify_json_number(&self.bytes[start..self.cursor])
    }

    fn digits(&mut self) -> Result<(), ContractError> {
        if !matches!(self.peek(), Some(b'0'..=b'9')) {
            return Err(ContractError::InvalidJson);
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.cursor += 1;
        }
        Ok(())
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.cursor += 1;
        }
    }

    fn take(&mut self, expected: u8) -> Result<(), ContractError> {
        if self.peek() == Some(expected) {
            self.cursor += 1;
            Ok(())
        } else {
            Err(ContractError::InvalidJson)
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.cursor).copied()
    }
}

fn classify_json_number(bytes: &[u8]) -> Result<(), ContractError> {
    let text = std::str::from_utf8(bytes).map_err(|_| ContractError::InvalidJson)?;
    if text.is_empty() {
        return Err(ContractError::InvalidJson);
    }
    if text.as_bytes().iter().any(|byte| matches!(byte, b'.' | b'e' | b'E')) {
        let value: f64 = text.parse().map_err(|_| ContractError::InvalidScalar)?;
        if !value.is_finite() {
            return Err(ContractError::InvalidScalar);
        }
        return Ok(());
    }
    if text.starts_with('-') {
        if text.parse::<i64>().is_ok() {
            return Ok(());
        }
        let value: f64 = text.parse().map_err(|_| ContractError::InvalidScalar)?;
        if !value.is_finite() {
            return Err(ContractError::InvalidScalar);
        }
        return Ok(());
    }
    if text.parse::<u64>().is_ok() {
        return Ok(());
    }
    let value: f64 = text.parse().map_err(|_| ContractError::InvalidScalar)?;
    if !value.is_finite() {
        return Err(ContractError::InvalidScalar);
    }
    Ok(())
}

fn hex(byte: u8) -> Result<u16, ContractError> {
    match byte {
        b'0'..=b'9' => Ok((byte - b'0') as u16),
        b'a'..=b'f' => Ok((byte - b'a' + 10) as u16),
        b'A'..=b'F' => Ok((byte - b'A' + 10) as u16),
        _ => Err(ContractError::InvalidJson),
    }
}

struct Decoded<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> Decoded<'a> {
    fn next(&mut self) -> Option<char> {
        let byte = *self.bytes.get(self.cursor)?;
        if byte != b'\\' {
            let text = std::str::from_utf8(&self.bytes[self.cursor..]).ok()?;
            let value = text.chars().next()?;
            self.cursor += value.len_utf8();
            return Some(value);
        }
        self.cursor += 1;
        let escaped = *self.bytes.get(self.cursor)?;
        self.cursor += 1;
        Some(match escaped {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{0008}',
            b'f' => '\u{000c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => {
                let first = decode_hex4(self.bytes, &mut self.cursor)?;
                if (0xd800..=0xdbff).contains(&first) {
                    self.cursor += 2;
                    let second = decode_hex4(self.bytes, &mut self.cursor)?;
                    char::from_u32(
                        0x10000 + (((first as u32 - 0xd800) << 10) | (second as u32 - 0xdc00)),
                    )?
                } else {
                    char::from_u32(first as u32)?
                }
            }
            _ => return None,
        })
    }
}

fn decode_hex4(bytes: &[u8], cursor: &mut usize) -> Option<u16> {
    let mut value = 0u16;
    for _ in 0..4 {
        let byte = *bytes.get(*cursor)?;
        value = value.checked_mul(16)?.checked_add(hex(byte).ok()?)?;
        *cursor += 1;
    }
    Some(value)
}

fn decoded_equal(bytes: &[u8], left: Span, right: Span) -> bool {
    let mut left = Decoded {
        bytes: &bytes[left.start..left.end],
        cursor: 0,
    };
    let mut right = Decoded {
        bytes: &bytes[right.start..right.end],
        cursor: 0,
    };
    loop {
        match (left.next(), right.next()) {
            (Some(a), Some(b)) if a == b => {}
            (None, None) => return true,
            _ => return false,
        }
    }
}

fn decoded_equals_text(bytes: &[u8], span: Span, expected: &str) -> bool {
    let mut decoded = Decoded {
        bytes: &bytes[span.start..span.end],
        cursor: 0,
    };
    let mut expected = expected.chars();
    loop {
        match (decoded.next(), expected.next()) {
            (Some(left), Some(right)) if left == right => {}
            (None, None) => return decoded.cursor == span.end - span.start,
            _ => return false,
        }
    }
}

fn slice(bytes: &[u8], span: Span) -> &[u8] {
    &bytes[span.start..span.end]
}

#[derive(Clone, Copy)]
pub(crate) struct RawValue<'a> {
    bytes: &'a [u8],
}

impl DecodeOwned for bool {
    fn decode_owned(_context: &mut DecodeContext<'_>, raw: RawValue<'_>) -> Result<Self, DecodeFailure> {
        match raw.bytes {
            b"true" => Ok(true),
            b"false" => Ok(false),
            _ => Err(DecodeFailure::Contract(ContractError::InvalidShape)),
        }
    }
}

impl<'a> RawValue<'a> {
    fn from_span(bytes: &'a [u8], span: Span) -> Self {
        Self {
            bytes: slice(bytes, span),
        }
    }

    fn is_null(self) -> bool {
        self.bytes == b"null"
    }

    fn string_inner(self) -> Result<&'a [u8], DecodeFailure> {
        if self.bytes.len() >= 2
            && self.bytes.first() == Some(&b'"')
            && self.bytes.last() == Some(&b'"')
        {
            Ok(&self.bytes[1..self.bytes.len() - 1])
        } else {
            Err(DecodeFailure::Contract(ContractError::InvalidShape))
        }
    }

    pub(crate) fn equals(self, expected: &str) -> bool {
        let Ok(bytes) = self.string_inner() else {
            return false;
        };
        let mut decoded = Decoded { bytes, cursor: 0 };
        let mut expected = expected.chars();
        loop {
            match (decoded.next(), expected.next()) {
                (Some(left), Some(right)) if left == right => {}
                (None, None) => return decoded.cursor == bytes.len(),
                _ => return false,
            }
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum DecodeFailure {
    Contract(ContractError),
    Exhausted,
}

pub(crate) struct DecodeContext<'a> {
    authority: &'a AllocationAuthority,
    limit: usize,
    allocated: usize,
}

impl DecodeContext<'_> {
    fn ensure_remaining(&self, bytes: usize) -> Result<(), DecodeFailure> {
        let remaining = self
            .limit
            .checked_sub(self.allocated)
            .ok_or(DecodeFailure::Exhausted)?;
        if bytes > remaining {
            return Err(DecodeFailure::Exhausted);
        }
        Ok(())
    }

    fn account(&mut self, bytes: usize) -> Result<(), DecodeFailure> {
        let next = self
            .allocated
            .checked_add(bytes)
            .ok_or(DecodeFailure::Exhausted)?;
        if next > self.limit {
            return Err(DecodeFailure::Exhausted);
        }
        self.allocated = next;
        Ok(())
    }

    fn allocate_string(&mut self, raw: RawValue<'_>) -> Result<String, DecodeFailure> {
        let source = raw.string_inner()?;
        let mut decoded = Decoded {
            bytes: source,
            cursor: 0,
        };
        let mut length = 0usize;
        while decoded.cursor < source.len() {
            let character = decoded
                .next()
                .ok_or(DecodeFailure::Contract(ContractError::InvalidJson))?;
            length = length
                .checked_add(character.len_utf8())
                .ok_or(DecodeFailure::Exhausted)?;
        }
        self.ensure_remaining(length)?;
        if self.authority.allocation_is_forced_to_fail() {
            return Err(DecodeFailure::Exhausted);
        }
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(length)
            .map_err(|_| DecodeFailure::Exhausted)?;
        let capacity = bytes.capacity();
        if let Err(error) = self.account(capacity) {
            drop(bytes);
            return Err(error);
        }
        decoded.cursor = 0;
        while decoded.cursor < source.len() {
            let character = decoded
                .next()
                .ok_or(DecodeFailure::Contract(ContractError::InvalidJson))?;
            let mut encoded = [0u8; 4];
            bytes.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
        }
        debug_assert_eq!(bytes.len(), length);
        Ok(unsafe { String::from_utf8_unchecked(bytes) })
    }

    fn allocate_vec<T>(&mut self, elements: usize) -> Result<Vec<T>, DecodeFailure> {
        if elements == 0 || std::mem::size_of::<T>() == 0 {
            return Ok(Vec::new());
        }
        let minimum = elements
            .checked_mul(std::mem::size_of::<T>())
            .ok_or(DecodeFailure::Exhausted)?;
        self.ensure_remaining(minimum)?;
        if self.authority.allocation_is_forced_to_fail() {
            return Err(DecodeFailure::Exhausted);
        }
        let mut values = Vec::new();
        values
            .try_reserve_exact(elements)
            .map_err(|_| DecodeFailure::Exhausted)?;
        let bytes = values
            .capacity()
            .checked_mul(std::mem::size_of::<T>())
            .ok_or(DecodeFailure::Exhausted)?;
        if let Err(error) = self.account(bytes) {
            drop(values);
            return Err(error);
        }
        Ok(values)
    }
}

pub(crate) trait DecodeOwned: Sized {
    fn decode_owned(
        context: &mut DecodeContext<'_>,
        raw: RawValue<'_>,
    ) -> Result<Self, DecodeFailure>;
}

#[cfg(test)]
pub(crate) trait TestFixture: Sized {
    fn test_fixture() -> Self;
}

#[cfg(test)]
pub(crate) fn fixture_string(type_name: &str) -> &'static str {
    match type_name {
        "ProjectId" | "PaneId" | "RunId" | "OperationId" | "InstanceId" | "ConnectionId"
        | "ArtifactId" | "TargetId" => "00000000-0000-4000-8000-000000000001",
        "Hex16" => "0000000000000000",
        "Hex32" => "00000000000000000000000000000000",
        "Timestamp" => "2026-09-09T00:00:00Z",
        _ => "x",
    }
}

impl DecodeOwned for String {
    fn decode_owned(
        context: &mut DecodeContext<'_>,
        raw: RawValue<'_>,
    ) -> Result<Self, DecodeFailure> {
        context.allocate_string(raw)
    }
}

impl DecodeOwned for True {
    fn decode_owned(
        _context: &mut DecodeContext<'_>,
        raw: RawValue<'_>,
    ) -> Result<Self, DecodeFailure> {
        match raw.bytes {
            b"true" => Ok(Self),
            b"false" => Err(DecodeFailure::Contract(ContractError::InvalidScalar)),
            _ => Err(DecodeFailure::Contract(ContractError::InvalidShape)),
        }
    }
}

#[cfg(test)]
impl TestFixture for String {
    fn test_fixture() -> Self {
        "x".to_owned()
    }
}

#[cfg(test)]
impl TestFixture for bool {
    fn test_fixture() -> Self {
        false
    }
}

#[cfg(test)]
impl TestFixture for () {
    fn test_fixture() -> Self {}
}

#[cfg(test)]
impl<T: TestFixture> TestFixture for Vec<T> {
    fn test_fixture() -> Self {
        vec![T::test_fixture()]
    }
}

#[cfg(test)]
impl<T: TestFixture> TestFixture for Box<T> {
    fn test_fixture() -> Self {
        Box::new(T::test_fixture())
    }
}

impl<T: DecodeOwned> DecodeOwned for Nullable<T> {
    fn decode_owned(
        context: &mut DecodeContext<'_>,
        raw: RawValue<'_>,
    ) -> Result<Self, DecodeFailure> {
        if raw.is_null() {
            Ok(Self(None))
        } else {
            T::decode_owned(context, raw).map(|value| Self(Some(value)))
        }
    }
}

#[cfg(test)]
impl<T: TestFixture> TestFixture for Nullable<T> {
    fn test_fixture() -> Self {
        Self(Some(T::test_fixture()))
    }
}

impl<T: DecodeOwned + Ord> DecodeOwned for StringSet<T> {
    fn decode_owned(
        context: &mut DecodeContext<'_>,
        raw: RawValue<'_>,
    ) -> Result<Self, DecodeFailure> {
        let count = ArrayReader::new(raw)?.count()?;
        let mut values = context.allocate_vec(count)?;
        let mut array = ArrayReader::new(raw)?;
        while let Some(value) = array.next()? {
            values.push(T::decode_owned(context, value)?);
        }
        StringSet::new(values).map_err(DecodeFailure::Contract)
    }
}

#[cfg(test)]
impl<T: Ord> TestFixture for StringSet<T> {
    fn test_fixture() -> Self {
        StringSet::new(Vec::new()).expect("empty set is unique")
    }
}

pub(crate) trait IntegerValue: Sized {
    fn decode_integer(bytes: &[u8]) -> Option<Self>;
}

impl IntegerValue for u64 {
    fn decode_integer(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty() || (bytes.len() > 1 && bytes[0] == b'0') {
            return None;
        }
        let mut value = 0u64;
        for byte in bytes {
            if !byte.is_ascii_digit() {
                return None;
            }
            value = value.checked_mul(10)?.checked_add((byte - b'0') as u64)?;
        }
        Some(value)
    }
}

impl IntegerValue for i32 {
    fn decode_integer(bytes: &[u8]) -> Option<Self> {
        let text = std::str::from_utf8(bytes).ok()?;
        if text.starts_with('+')
            || text.contains(['.', 'e', 'E'])
            || (text.starts_with('0') && text.len() > 1)
            || (text.starts_with("-0") && text.len() > 2)
        {
            return None;
        }
        text.parse().ok()
    }
}

pub(crate) fn decode_integer<T: IntegerValue>(raw: RawValue<'_>) -> Result<T, DecodeFailure> {
    T::decode_integer(raw.bytes).ok_or(DecodeFailure::Contract(ContractError::InvalidScalar))
}

#[derive(Clone, Copy)]
struct ValueCursor<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> ValueCursor<'a> {
    fn ws(&mut self) {
        while matches!(
            self.bytes.get(self.cursor),
            Some(b' ' | b'\n' | b'\r' | b'\t')
        ) {
            self.cursor += 1;
        }
    }

    fn string(&mut self) -> Result<Span, DecodeFailure> {
        if self.bytes.get(self.cursor) != Some(&b'"') {
            return Err(DecodeFailure::Contract(ContractError::InvalidShape));
        }
        self.cursor += 1;
        let start = self.cursor;
        while let Some(byte) = self.bytes.get(self.cursor).copied() {
            match byte {
                b'"' => {
                    let end = self.cursor;
                    self.cursor += 1;
                    return Ok(Span { start, end });
                }
                b'\\' => {
                    self.cursor += 1;
                    match self.bytes.get(self.cursor).copied() {
                        Some(b'u') => self.cursor += 5,
                        Some(_) => self.cursor += 1,
                        None => return Err(DecodeFailure::Contract(ContractError::InvalidJson)),
                    }
                }
                _ => self.cursor += 1,
            }
        }
        Err(DecodeFailure::Contract(ContractError::InvalidJson))
    }

    fn skip_value(&mut self) -> Result<(), DecodeFailure> {
        self.ws();
        match self.bytes.get(self.cursor).copied() {
            Some(b'"') => self.string().map(|_| ()),
            Some(b'{') => {
                self.cursor += 1;
                self.ws();
                if self.bytes.get(self.cursor) == Some(&b'}') {
                    self.cursor += 1;
                    return Ok(());
                }
                loop {
                    self.string()?;
                    self.ws();
                    if self.bytes.get(self.cursor) != Some(&b':') {
                        return Err(DecodeFailure::Contract(ContractError::InvalidJson));
                    }
                    self.cursor += 1;
                    self.skip_value()?;
                    self.ws();
                    match self.bytes.get(self.cursor) {
                        Some(b',') => self.cursor += 1,
                        Some(b'}') => {
                            self.cursor += 1;
                            return Ok(());
                        }
                        _ => return Err(DecodeFailure::Contract(ContractError::InvalidJson)),
                    }
                    self.ws();
                }
            }
            Some(b'[') => {
                self.cursor += 1;
                self.ws();
                if self.bytes.get(self.cursor) == Some(&b']') {
                    self.cursor += 1;
                    return Ok(());
                }
                loop {
                    self.skip_value()?;
                    self.ws();
                    match self.bytes.get(self.cursor) {
                        Some(b',') => self.cursor += 1,
                        Some(b']') => {
                            self.cursor += 1;
                            return Ok(());
                        }
                        _ => return Err(DecodeFailure::Contract(ContractError::InvalidJson)),
                    }
                    self.ws();
                }
            }
            Some(b't') if self.bytes.get(self.cursor..self.cursor + 4) == Some(b"true") => {
                self.cursor += 4;
                Ok(())
            }
            Some(b'f') if self.bytes.get(self.cursor..self.cursor + 5) == Some(b"false") => {
                self.cursor += 5;
                Ok(())
            }
            Some(b'n') if self.bytes.get(self.cursor..self.cursor + 4) == Some(b"null") => {
                self.cursor += 4;
                Ok(())
            }
            Some(b'-' | b'0'..=b'9') => {
                while matches!(
                    self.bytes.get(self.cursor),
                    Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                ) {
                    self.cursor += 1;
                }
                Ok(())
            }
            _ => Err(DecodeFailure::Contract(ContractError::InvalidJson)),
        }
    }
}

pub(crate) struct ObjectReader<'a> {
    cursor: ValueCursor<'a>,
    finished: bool,
}

impl<'a> ObjectReader<'a> {
    pub(crate) fn new(raw: RawValue<'a>) -> Result<Self, DecodeFailure> {
        if raw.bytes.first() != Some(&b'{') {
            return Err(DecodeFailure::Contract(ContractError::InvalidShape));
        }
        Ok(Self {
            cursor: ValueCursor {
                bytes: raw.bytes,
                cursor: 1,
            },
            finished: false,
        })
    }

    pub(crate) fn next(&mut self) -> Result<Option<(RawValue<'a>, RawValue<'a>)>, DecodeFailure> {
        if self.finished {
            return Ok(None);
        }
        self.cursor.ws();
        if self.cursor.bytes.get(self.cursor.cursor) == Some(&b'}') {
            self.cursor.cursor += 1;
            self.finished = true;
            return Ok(None);
        }
        let key = self.cursor.string()?;
        self.cursor.ws();
        if self.cursor.bytes.get(self.cursor.cursor) != Some(&b':') {
            return Err(DecodeFailure::Contract(ContractError::InvalidJson));
        }
        self.cursor.cursor += 1;
        self.cursor.ws();
        let start = self.cursor.cursor;
        self.cursor.skip_value()?;
        let value = RawValue {
            bytes: &self.cursor.bytes[start..self.cursor.cursor],
        };
        self.cursor.ws();
        match self.cursor.bytes.get(self.cursor.cursor) {
            Some(b',') => self.cursor.cursor += 1,
            Some(b'}') => {
                self.cursor.cursor += 1;
                self.finished = true;
            }
            _ => return Err(DecodeFailure::Contract(ContractError::InvalidJson)),
        }
        Ok(Some((
            RawValue {
                bytes: &self.cursor.bytes[key.start - 1..key.end + 1],
            },
            value,
        )))
    }
}

struct ArrayReader<'a> {
    cursor: ValueCursor<'a>,
    finished: bool,
}

impl<'a> ArrayReader<'a> {
    fn new(raw: RawValue<'a>) -> Result<Self, DecodeFailure> {
        if raw.bytes.first() != Some(&b'[') {
            return Err(DecodeFailure::Contract(ContractError::InvalidShape));
        }
        Ok(Self {
            cursor: ValueCursor {
                bytes: raw.bytes,
                cursor: 1,
            },
            finished: false,
        })
    }

    fn next(&mut self) -> Result<Option<RawValue<'a>>, DecodeFailure> {
        if self.finished {
            return Ok(None);
        }
        self.cursor.ws();
        if self.cursor.bytes.get(self.cursor.cursor) == Some(&b']') {
            self.cursor.cursor += 1;
            self.finished = true;
            return Ok(None);
        }
        let start = self.cursor.cursor;
        self.cursor.skip_value()?;
        let value = RawValue {
            bytes: &self.cursor.bytes[start..self.cursor.cursor],
        };
        self.cursor.ws();
        match self.cursor.bytes.get(self.cursor.cursor) {
            Some(b',') => self.cursor.cursor += 1,
            Some(b']') => {
                self.cursor.cursor += 1;
                self.finished = true;
            }
            _ => return Err(DecodeFailure::Contract(ContractError::InvalidJson)),
        }
        Ok(Some(value))
    }

    fn count(mut self) -> Result<usize, DecodeFailure> {
        let mut count = 0usize;
        while self.next()?.is_some() {
            count = count.checked_add(1).ok_or(DecodeFailure::Exhausted)?;
        }
        Ok(count)
    }
}

pub(crate) trait Sink {
    fn bytes(&mut self, bytes: &[u8]) -> Result<(), AllocationError>;
}

pub(crate) struct Measure(pub(crate) usize);

impl Sink for Measure {
    fn bytes(&mut self, bytes: &[u8]) -> Result<(), AllocationError> {
        self.0 = self
            .0
            .checked_add(bytes.len())
            .ok_or(AllocationError::Exhausted)?;
        Ok(())
    }
}

pub(crate) struct Output<'a>(pub(crate) &'a mut ChargedVec<u8>);

impl Sink for Output<'_> {
    fn bytes(&mut self, bytes: &[u8]) -> Result<(), AllocationError> {
        self.0.try_extend_from_slice(bytes)
    }
}

pub(crate) trait WireText {
    fn wire_text(&self) -> &str;
}

impl WireText for String {
    fn wire_text(&self) -> &str {
        self
    }
}

pub(crate) trait CanonicalValue {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError>;
}

impl CanonicalValue for String {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        json_string(sink, self)
    }
}

impl<T: CanonicalValue> CanonicalValue for Nullable<T> {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        match self.0.as_ref() {
            Some(value) => value.write_canonical(sink),
            None => sink.bytes(b"null"),
        }
    }
}

impl<T: CanonicalValue> CanonicalValue for Vec<T> {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        sink.bytes(b"[")?;
        for (index, value) in self.iter().enumerate() {
            if index != 0 {
                sink.bytes(b",")?;
            }
            value.write_canonical(sink)?;
        }
        sink.bytes(b"]")
    }
}

impl<T: CanonicalValue> CanonicalValue for Box<T> {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        (**self).write_canonical(sink)
    }
}

impl CanonicalValue for bool {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        sink.bytes(if *self { b"true" } else { b"false" })
    }
}

impl CanonicalValue for () {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        sink.bytes(b"null")
    }
}

impl<T: WireText> CanonicalValue for StringSet<T> {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        sink.bytes(b"[")?;
        let mut previous: Option<&str> = None;
        for index in 0..self.len() {
            let current = self
                .iter()
                .map(WireText::wire_text)
                .filter(|value| previous.is_none_or(|previous| *value > previous))
                .min()
                .ok_or(AllocationError::Exhausted)?;
            if index != 0 {
                sink.bytes(b",")?;
            }
            json_string(sink, current)?;
            previous = Some(current);
        }
        sink.bytes(b"]")
    }
}

pub(crate) fn json_string(sink: &mut impl Sink, value: &str) -> Result<(), AllocationError> {
    sink.bytes(b"\"")?;
    for character in value.chars() {
        match character {
            '"' => sink.bytes(b"\\\"")?,
            '\\' => sink.bytes(b"\\\\")?,
            '\u{0008}' => sink.bytes(b"\\b")?,
            '\u{000c}' => sink.bytes(b"\\f")?,
            '\n' => sink.bytes(b"\\n")?,
            '\r' => sink.bytes(b"\\r")?,
            '\t' => sink.bytes(b"\\t")?,
            '\u{0000}'..='\u{001f}' => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                let value = character as usize;
                sink.bytes(&[
                    b'\\',
                    b'u',
                    b'0',
                    b'0',
                    HEX[(value >> 4) & 0xf],
                    HEX[value & 0xf],
                ])?;
            }
            _ => {
                let mut buffer = [0u8; 4];
                sink.bytes(character.encode_utf8(&mut buffer).as_bytes())?;
            }
        }
    }
    sink.bytes(b"\"")
}

pub(crate) fn number(sink: &mut impl Sink, mut value: u64) -> Result<(), AllocationError> {
    let mut digits = [0u8; 20];
    let mut cursor = digits.len();
    loop {
        cursor -= 1;
        digits[cursor] = b'0' + (value % 10) as u8;
        value /= 10;
        if value == 0 {
            return sink.bytes(&digits[cursor..]);
        }
    }
}

pub(crate) fn signed_number(sink: &mut impl Sink, value: i32) -> Result<(), AllocationError> {
    if value < 0 {
        sink.bytes(b"-")?;
        number(sink, i64::from(value).unsigned_abs())
    } else {
        number(sink, value as u64)
    }
}

struct SinkWriter<'a, S> {
    sink: &'a mut S,
    failed: Option<AllocationError>,
}

impl<S: Sink> std::io::Write for SinkWriter<'_, S> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        match self.sink.bytes(bytes) {
            Ok(()) => Ok(bytes.len()),
            Err(error) => {
                self.failed = Some(error);
                Err(std::io::ErrorKind::Other.into())
            }
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

pub(crate) fn finite_number(sink: &mut impl Sink, value: f64) -> Result<(), AllocationError> {
    let mut writer = SinkWriter { sink, failed: None };
    match serde_json::to_writer(&mut writer, &value) {
        Ok(()) => Ok(()),
        Err(_) => Err(writer.failed.unwrap_or(AllocationError::Allocator)),
    }
}

impl CanonicalValue for U {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        number(sink, self.get())
    }
}

impl CanonicalValue for P {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        number(sink, self.get())
    }
}

impl CanonicalValue for Version {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        number(sink, self.get())
    }
}

impl CanonicalValue for MessageLimit {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        number(sink, self.get())
    }
}

impl CanonicalValue for OneByte {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        number(sink, self.get())
    }
}

impl CanonicalValue for ExitCode {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        signed_number(sink, self.get())
    }
}

impl CanonicalValue for Ratio {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), AllocationError> {
        finite_number(sink, self.get())
    }
}

fn map_decode(error: DecodeFailure, correlation: Option<WireCorrelation>) -> HostCodecError {
    match error {
        DecodeFailure::Contract(error) => HostCodecError::Contract(error),
        DecodeFailure::Exhausted => HostCodecError::Exhausted {
            phase: HostCodecPhase::Decode,
            correlation,
        },
    }
}

pub fn prepare_request(
    frame: OwnedFrame,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<PreparedRequest, HostCodecError> {
    if frame.len() > MAX_MESSAGE_BYTES {
        return Err(HostCodecError::Contract(ContractError::MessageTooLarge));
    }
    let text = std::str::from_utf8(&frame)
        .map_err(|_| HostCodecError::Contract(ContractError::InvalidUtf8))?;
    if text.starts_with('\u{feff}') {
        return Err(HostCodecError::Contract(ContractError::BomForbidden));
    }
    let request_limit =
        frame
            .len()
            .checked_mul(REQUEST_OWNED_MULTIPLIER)
            .ok_or(HostCodecError::Exhausted {
                phase: HostCodecPhase::Decode,
                correlation: None,
            })?;
    let mut request_charge =
        authority
            .claim(pool, request_limit)
            .map_err(|_| HostCodecError::Exhausted {
                phase: HostCodecPhase::Decode,
                correlation: None,
            })?;
    let member_capacity = frame.len() / 4 + 1;
    let member_bytes = member_capacity
        .checked_mul(std::mem::size_of::<MemberSpan>())
        .ok_or(HostCodecError::Exhausted {
            phase: HostCodecPhase::Decode,
            correlation: None,
        })?;
    let mut members = ChargedVec::with_capacity(authority, pool, member_capacity, member_bytes)
        .map_err(|_| HostCodecError::Exhausted {
            phase: HostCodecPhase::Decode,
            correlation: None,
        })?;
    let slots = Scanner::new(&frame)
        .scan(&mut members)
        .map_err(HostCodecError::Contract)?;
    if let Some(version) = slots.schema_version {
        if <u64 as IntegerValue>::decode_integer(slice(&frame, version))
            .is_some_and(|version| version != 1)
        {
            return Err(HostCodecError::Contract(ContractError::UnsupportedSchema));
        }
    }
    if slots.unknown {
        return Err(HostCodecError::Contract(ContractError::InvalidShape));
    }
    let (
        Some(schema_version),
        Some(instance_id),
        Some(operation_id),
        Some(expected_topology_revision),
        Some(operation),
        Some(params),
    ) = (
        slots.schema_version,
        slots.instance_id,
        slots.operation_id,
        slots.expected_topology_revision,
        slots.operation,
        slots.params,
    )
    else {
        return Err(HostCodecError::Contract(ContractError::InvalidShape));
    };
    let mut context = DecodeContext {
        authority,
        limit: request_limit,
        allocated: 0,
    };
    let operation =
        OperationName::decode_owned(&mut context, RawValue::from_span(&frame, operation))
            .map_err(|error| map_decode(error, None))?;
    let decoded_operation_id = OperationId::decode_owned(
        &mut context,
        RawValue::from_span(&frame, operation_id),
    )
    .map_err(|error| map_decode(error, None))?;
    let decoded_instance_id = Nullable::<InstanceId>::decode_owned(
        &mut context,
        RawValue::from_span(&frame, instance_id),
    )
    .map_err(|error| map_decode(error, None))?;
    let correlation = WireCorrelation {
        operation,
        has_instance: decoded_instance_id.0.is_some(),
        operation_id: decoded_operation_id.clone(),
        instance_id: decoded_instance_id.0.clone(),
    };
    let action = Action::decode_host_params(
        &mut context,
        operation,
        RawValue::from_span(&frame, params),
    )
    .map_err(|error| map_decode(error, Some(correlation.clone())))?;
    let mut request = Request {
        schema_version: Version::decode_owned(
            &mut context,
            RawValue::from_span(&frame, schema_version),
        )
        .map_err(|error| map_decode(error, Some(correlation.clone())))?,
        instance_id: decoded_instance_id,
        operation_id: decoded_operation_id,
        expected_topology_revision: Nullable::<U>::decode_owned(
            &mut context,
            RawValue::from_span(&frame, expected_topology_revision),
        )
        .map_err(|error| map_decode(error, Some(correlation.clone())))?,
        action,
    };
    request.action.normalize_extension();
    request.validate().map_err(HostCodecError::Contract)?;
    let request_bytes = request.owned_capacity();
    if request_bytes != context.allocated {
        return Err(HostCodecError::Exhausted {
            phase: HostCodecPhase::Decode,
            correlation: Some(correlation),
        });
    }
    drop(members);
    request_charge.reduce_to(request_bytes);
    let canonical = canonical_request_owned(&request, authority, pool).map_err(|_| {
        HostCodecError::Exhausted {
            phase: HostCodecPhase::Canonical,
            correlation: Some(correlation.clone()),
        }
    })?;
    drop(frame);
    Ok(PreparedRequest {
        request: Some(request),
        canonical: Some(canonical),
        request_charge: Some(request_charge),
        correlation,
    })
}

fn write_request(sink: &mut impl Sink, request: &Request) -> Result<(), AllocationError> {
    sink.bytes(b"{\"expected_topology_revision\":")?;
    request.expected_topology_revision.write_canonical(sink)?;
    sink.bytes(b",\"instance_id\":")?;
    request.instance_id.write_canonical(sink)?;
    sink.bytes(b",\"operation\":")?;
    request.action.operation().write_canonical(sink)?;
    sink.bytes(b",\"operation_id\":")?;
    request.operation_id.write_canonical(sink)?;
    sink.bytes(b",\"params\":")?;
    request.action.write_host_params(sink)?;
    sink.bytes(b",\"schema_version\":")?;
    request.schema_version.write_canonical(sink)?;
    sink.bytes(b"}")
}

fn canonical_request_owned(
    request: &Request,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ChargedVec<u8>, AllocationError> {
    let mut measure = Measure(0);
    write_request(&mut measure, request)?;
    if measure.0 > MAX_MESSAGE_BYTES {
        return Err(AllocationError::Exhausted);
    }
    let mut bytes = ChargedVec::with_capacity(authority, pool, measure.0, measure.0)?;
    write_request(&mut Output(&mut bytes), request)?;
    if bytes.len() != measure.0 {
        return Err(AllocationError::Allocator);
    }
    Ok(bytes)
}

pub(crate) fn serialize_response_owned(
    request: &Request,
    response: &Response,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<OwnedReply, HostCodecError> {
    response
        .validate(request)
        .map_err(HostCodecError::Contract)?;
    let correlation = Some(WireCorrelation {
        operation: request.action.operation(),
        has_instance: request.instance_id.0.is_some(),
        operation_id: request.operation_id.clone(),
        instance_id: request.instance_id.0.clone(),
    });
    response_body_owned(response, authority, pool).map_err(|_| HostCodecError::Exhausted {
        phase: HostCodecPhase::Canonical,
        correlation,
    })
}

fn response_body_owned(
    response: &Response,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<OwnedReply, AllocationError> {
    let mut measure = Measure(0);
    response.write_canonical(&mut measure)?;
    if measure.0 > MAX_MESSAGE_BYTES {
        return Err(AllocationError::Exhausted);
    }
    let mut bytes = ChargedVec::with_capacity(authority, pool, measure.0, measure.0)?;
    response.write_canonical(&mut Output(&mut bytes))?;
    if bytes.len() != measure.0 {
        return Err(AllocationError::Allocator);
    }
    Ok(OwnedReply { bytes })
}

const SIZING_UUID: &str = "00000000-0000-4000-8000-000000000000";

fn write_recovery_decide_request(sink: &mut impl Sink) -> Result<(), AllocationError> {
    sink.bytes(b"{\"expected_topology_revision\":null,\"instance_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"operation\":\"connection.decide\",\"operation_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"params\":{\"connection_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"decision\":\"deny\",\"project_ids\":[],\"scopes\":[]},\"schema_version\":1}")
}

fn write_recovery_success(
    sink: &mut impl Sink,
    decide: bool,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"accepted\":true,\"error\":null,\"event_seq\":")?;
    number(sink, MAX_SAFE_INTEGER)?;
    sink.bytes(b",\"instance_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"operation_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"result\":{\"data\":{\"connection_id\":")?;
    json_string(sink, SIZING_UUID)?;
    if decide {
        sink.bytes(b",\"project_ids\":[],\"scopes\":[],\"state\":\"revoked\"},\"operation\":\"connection.decide\"}")?;
    } else {
        sink.bytes(b",\"state\":\"revoked\"},\"operation\":\"connection.revoke\"}")?;
    }
    sink.bytes(b",\"schema_version\":1,\"topology_revision\":")?;
    number(sink, MAX_SAFE_INTEGER)?;
    sink.bytes(b"}")
}

fn write_recovery_error(
    sink: &mut impl Sink,
    code: ErrorCode,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"accepted\":false,\"error\":{\"code\":")?;
    json_string(sink, code.wire())?;
    sink.bytes(b",\"message\":")?;
    json_string(sink, code.message())?;
    sink.bytes(b",\"retryable\":")?;
    code.retryable().write_canonical(sink)?;
    sink.bytes(b",\"target_id\":")?;
    if code.allows_target() {
        json_string(sink, SIZING_UUID)?;
    } else {
        sink.bytes(b"null")?;
    }
    sink.bytes(b"},\"event_seq\":")?;
    number(sink, MAX_SAFE_INTEGER)?;
    sink.bytes(b",\"instance_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"operation_id\":")?;
    json_string(sink, SIZING_UUID)?;
    sink.bytes(b",\"result\":null,\"schema_version\":1,\"topology_revision\":")?;
    number(sink, MAX_SAFE_INTEGER)?;
    sink.bytes(b"}")
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct RecoveryBufferCapacities {
    pub(crate) canonical: usize,
    pub(crate) terminal: usize,
}

pub(crate) fn recovery_buffer_capacities(
) -> Result<RecoveryBufferCapacities, AllocationError> {
    let mut canonical = Measure(0);
    write_recovery_decide_request(&mut canonical)?;

    let mut terminal = 0usize;
    for decide in [false, true] {
        let mut measured = Measure(0);
        write_recovery_success(&mut measured, decide)?;
        terminal = terminal.max(measured.0);
    }
    for code in ErrorCode::ALL {
        let mut measured = Measure(0);
        write_recovery_error(&mut measured, *code)?;
        terminal = terminal.max(measured.0);
    }
    Ok(RecoveryBufferCapacities {
        canonical: canonical.0,
        terminal,
    })
}

pub(crate) fn write_uuid_bytes(
    sink: &mut impl Sink,
    uuid: &[u8; 36],
) -> Result<(), AllocationError> {
    sink.bytes(b"\"")?;
    sink.bytes(uuid)?;
    sink.bytes(b"\"")
}

pub(crate) fn write_error_response(
    sink: &mut impl Sink,
    instance_id: &str,
    operation_id: &str,
    event_seq: u64,
    topology_revision: u64,
    code: ErrorCode,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"accepted\":false,\"error\":{\"code\":")?;
    json_string(sink, code.wire())?;
    sink.bytes(b",\"message\":")?;
    json_string(sink, code.message())?;
    sink.bytes(b",\"retryable\":")?;
    code.retryable().write_canonical(sink)?;
    sink.bytes(b",\"target_id\":null},\"event_seq\":")?;
    number(sink, event_seq)?;
    sink.bytes(b",\"instance_id\":")?;
    json_string(sink, instance_id)?;
    sink.bytes(b",\"operation_id\":")?;
    json_string(sink, operation_id)?;
    sink.bytes(b",\"result\":null,\"schema_version\":1,\"topology_revision\":")?;
    number(sink, topology_revision)?;
    sink.bytes(b"}")
}

pub(crate) fn write_success_prefix(
    sink: &mut impl Sink,
    instance_id: &str,
    operation_id: &str,
    event_seq: u64,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"accepted\":true,\"error\":null,\"event_seq\":")?;
    number(sink, event_seq)?;
    sink.bytes(b",\"instance_id\":")?;
    json_string(sink, instance_id)?;
    sink.bytes(b",\"operation_id\":")?;
    json_string(sink, operation_id)?;
    sink.bytes(b",\"result\":")
}

pub(crate) fn write_success_suffix(
    sink: &mut impl Sink,
    topology_revision: u64,
) -> Result<(), AllocationError> {
    sink.bytes(b",\"schema_version\":1,\"topology_revision\":")?;
    number(sink, topology_revision)?;
    sink.bytes(b"}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned_frame(
        authority: &AllocationAuthority,
        pool: AllocationPool,
        bytes: &[u8],
    ) -> OwnedFrame {
        let mut frame =
            OwnedFrame::allocate(authority, pool, bytes.len()).expect("test frame allocation");
        frame.copy_from_slice(bytes);
        frame
    }

    fn request(action: Action) -> Request {
        let operation = action.operation();
        Request {
            schema_version: Version::new(1).expect("schema version"),
            instance_id: Nullable(
                (!matches!(
                    operation,
                    OperationName::CapabilitiesGet | OperationName::ConnectionRequest
                ))
                .then(|| InstanceId::test_fixture()),
            ),
            operation_id: OperationId::test_fixture(),
            expected_topology_revision: Nullable(
                (operation.class() == OperationClass::T)
                    .then(|| U::new(0).expect("topology revision")),
            ),
            action,
        }
    }

    fn assert_public_host_parity(bytes: &[u8]) {
        let public = parse_request(bytes);
        let authority = AllocationAuthority::host();
        let host = prepare_request(
            owned_frame(&authority, AllocationPool::ActivePublic, bytes),
            &authority,
            AllocationPool::ActivePublic,
        );
        match (public, host) {
            (Ok(expected), Ok(prepared)) => {
                assert_eq!(prepared.request(), &expected);
                assert_eq!(
                    prepared.canonical(),
                    canonical_request(&expected).expect("public canonical request")
                );
                drop(prepared);
            }
            (Err(expected), Err(HostCodecError::Contract(actual))) => {
                assert_eq!(actual, expected);
            }
            (Ok(_), Err(error)) => panic!("host rejected public request: {error:?}"),
            (Err(error), Ok(prepared)) => {
                drop(prepared);
                panic!("host accepted public rejection: {error:?}");
            }
            (Err(expected), Err(actual)) => {
                panic!("host allocation failure replaced {expected:?}: {actual:?}");
            }
        }
        assert_eq!(authority.snapshot().active_public, 0);
    }

    #[test]
    fn cleanup_read_owned_decoder_parity_and_allocation_release() {
        let action = Action::host_codec_fixtures().into_iter()
            .find(|action| matches!(action, Action::RunGet(_))).unwrap();
        let legacy = request(action);
        let legacy_bytes = canonical_request(&legacy).unwrap();
        assert_public_host_parity(&legacy_bytes);
        let mut value = serde_json::to_value(&legacy).unwrap();
        for flag in [serde_json::json!(true), serde_json::json!(false), serde_json::json!(null),
            serde_json::json!(0), serde_json::json!("true"), serde_json::json!([]), serde_json::json!({})] {
            value["params"]["include_cleanup"] = flag.clone();
            let bytes = serde_json::to_vec(&value).unwrap();
            assert_public_host_parity(&bytes);
            if flag == serde_json::json!(true) {
                let extended = parse_request(&bytes).unwrap();
                assert_eq!(extended.owned_capacity(), legacy.owned_capacity());
                let canonical = canonical_request(&extended).unwrap();
                let escaped = String::from_utf8(canonical.clone()).unwrap()
                    .replace("\"include_cleanup\":true", "\"include\\u005fcleanup\" : true");
                assert_eq!(parse_request(escaped.as_bytes()).unwrap(), extended);
                assert_public_host_parity(escaped.as_bytes());
                let duplicate = String::from_utf8(canonical).unwrap()
                    .replace("\"include_cleanup\":true", "\"include_cleanup\":true,\"include_cleanup\":true");
                assert_eq!(parse_request(duplicate.as_bytes()), Err(ContractError::DuplicateKey));
                assert_public_host_parity(duplicate.as_bytes());
            } else {
                let expected = if flag == serde_json::json!(false) { ContractError::InvalidScalar } else { ContractError::InvalidShape };
                assert_eq!(parse_request(&bytes), Err(expected));
            }
        }
        value["params"]["include_cleanup"] = serde_json::json!(true);
        value["params"]["extra"] = serde_json::json!(true);
        let bytes = serde_json::to_vec(&value).unwrap();
        assert_eq!(parse_request(&bytes), Err(ContractError::InvalidShape));
        assert_public_host_parity(&bytes);
    }

    #[test]
    fn every_declared_operation_uses_owned_decode_and_the_same_canonical_bytes() {
        let actions = Action::host_codec_fixtures();
        assert_eq!(actions.len(), OperationName::ALL.len());
        for mut action in actions {
            if let Action::ArtifactChoose(params) = &mut action {
                params.right_artifact_id = ArtifactId::new(
                    "00000000-0000-4000-8000-000000000002",
                ).expect("distinct choice fixture");
                params.kept_artifact_id = params.left_artifact_id.clone();
            }
            let request = request(action);
            let expected = canonical_request(&request).unwrap_or_else(|error| {
                panic!("public canonical request for {:?}: {error:?}", request.action.operation())
            });
            let authority = AllocationAuthority::host();
            let prepared = prepare_request(
                owned_frame(&authority, AllocationPool::ActivePublic, &expected),
                &authority,
                AllocationPool::ActivePublic,
            )
            .expect("host-owned request");
            assert_eq!(prepared.request(), &request);
            assert_eq!(prepared.canonical(), expected);
            assert_eq!(prepared.correlation().operation, request.action.operation());
            let snapshot = authority.snapshot();
            assert_eq!(
                snapshot.active_public,
                prepared.request().owned_capacity() + prepared.canonical().len()
            );
            drop(prepared);
            assert_eq!(authority.snapshot().active_public, 0);
        }
    }

    #[test]
    fn close_guard_presence_parity_and_allocation_release() {
        for expected in [None, Some(Nullable(None)), Some(Nullable(Some(RunId::new("50000000-0000-4000-8000-000000000001").unwrap())))] {
            let parsed = request(Action::PaneClose(PaneCloseParams {
                pane_id: PaneId::new("40000000-0000-4000-8000-000000000001").unwrap(),
                expected_current_run_id: expected,
            }));
            let canonical = canonical_request(&parsed).unwrap();
            assert_eq!(parse_request(&canonical).unwrap(), parsed);
            let authority = AllocationAuthority::host();
            let prepared = prepare_request(owned_frame(&authority, AllocationPool::ActivePublic, &canonical), &authority, AllocationPool::ActivePublic).unwrap();
            assert_eq!(prepared.request(), &parsed);
            assert_eq!(prepared.canonical(), canonical);
            assert_eq!(authority.snapshot().active_public, prepared.request().owned_capacity() + prepared.canonical().len());
            drop(prepared);
            assert_eq!(authority.snapshot().active_public, 0);
        }
    }

    #[test]
    fn fixed_contract_failures_are_default_deny_and_release_every_charge() {
        let cases: &[(&[u8], ContractError)] = &[
            (
                br#"{"expected_topology_revision":null,"instance_id":null,"operation":"unknown","operation_id":"00000000-0000-4000-8000-000000000001","params":{},"schema_version":1}"#,
                ContractError::InvalidShape,
            ),
            (
                br#"{"expected_topology_revision":null,"instance_id":null,"operation":"capabilities.get","operation":"capabilities.get","operation_id":"00000000-0000-4000-8000-000000000001","params":{},"schema_version":1}"#,
                ContractError::DuplicateKey,
            ),
            (
                br#"{"expected_topology_revision":null,"instance_id":null,"operation":"capabilities.get","operation_id":"00000000-0000-4000-8000-000000000001","params":{},"schema_version":2}"#,
                ContractError::UnsupportedSchema,
            ),
            (
                br#"{"expected_topology_revision":null,"instance_id":null,"operation":"capabilities.get","operation_id":"00000000-0000-4000-8000-000000000001","params":{"extra":0},"schema_version":1}"#,
                ContractError::InvalidShape,
            ),
        ];
        for (bytes, expected) in cases {
            let authority = AllocationAuthority::host();
            let result = prepare_request(
                owned_frame(&authority, AllocationPool::ActiveOwner, bytes),
                &authority,
                AllocationPool::ActiveOwner,
            );
            let error = match result {
                Err(error) => error,
                Ok(_) => panic!("invalid request was accepted"),
            };
            assert_eq!(error, HostCodecError::Contract(*expected));
            assert_eq!(authority.snapshot().active_owner, 0);
        }
    }

    #[test]
    fn host_codec_matches_public_codec_for_escaped_keys_depth_numbers_and_sets() {
        let ordered_and_escaped = br#"{"schema_version":1,"params":{},"operation_id":"00000000-0000-4000-8000-000000000001","oper\u0061tion":"capabilit\u0069es.get","instance_id":null,"expected_topology_revision":null}"#;
        assert_public_host_parity(ordered_and_escaped);

        let escaped_duplicate = br#"{"expected_topology_revision":null,"instance_id":null,"operation":"capabilities.get","oper\u0061tion":"capabilities.get","operation_id":"00000000-0000-4000-8000-000000000001","params":{},"schema_version":1}"#;
        assert_public_host_parity(escaped_duplicate);

        let mut legal_depth = "[".repeat(JSON_DEPTH - 2);
        legal_depth.push('0');
        legal_depth.push_str(&"]".repeat(JSON_DEPTH - 2));
        let legal_depth = format!(
            "{{\"expected_topology_revision\":null,\"instance_id\":null,\"operation\":\"capabilities.get\",\"operation_id\":\"00000000-0000-4000-8000-000000000001\",\"params\":{{\"extra\":{legal_depth}}},\"schema_version\":1}}"
        );
        assert_public_host_parity(legal_depth.as_bytes());

        let mut excessive_depth = "[".repeat(JSON_DEPTH - 1);
        excessive_depth.push('0');
        excessive_depth.push_str(&"]".repeat(JSON_DEPTH - 1));
        let excessive_depth = format!(
            "{{\"expected_topology_revision\":null,\"instance_id\":null,\"operation\":\"capabilities.get\",\"operation_id\":\"00000000-0000-4000-8000-000000000001\",\"params\":{{\"extra\":{excessive_depth}}},\"schema_version\":1}}"
        );
        assert_public_host_parity(excessive_depth.as_bytes());

        for schema_version in ["1.0", "1e0", "-0", "01", "18446744073709551616"] {
            let bytes = format!(
                "{{\"expected_topology_revision\":null,\"instance_id\":null,\"operation\":\"capabilities.get\",\"operation_id\":\"00000000-0000-4000-8000-000000000001\",\"params\":{{}},\"schema_version\":{schema_version}}}"
            );
            assert_public_host_parity(bytes.as_bytes());
        }

        let duplicate_set = br#"{"expected_topology_revision":null,"instance_id":null,"operation":"connection.request","operation_id":"00000000-0000-4000-8000-000000000001","params":{"project_ids":["00000000-0000-4000-8000-000000000002","00000000-0000-4000-8000-000000000002"],"scopes":[]},"schema_version":1}"#;
        assert_public_host_parity(duplicate_set);

        let empty_nonempty = br#"{"expected_topology_revision":0,"instance_id":"00000000-0000-4000-8000-000000000003","operation":"project.open","operation_id":"00000000-0000-4000-8000-000000000001","params":{"path":""},"schema_version":1}"#;
        assert_public_host_parity(empty_nonempty);
    }

    #[test]
    fn aggregate_preclaim_denies_before_final_string_or_vec_allocation() {
        let authority = AllocationAuthority::host();
        authority.fail_after_allocations(0);
        let mut context = DecodeContext {
            authority: &authority,
            limit: 1,
            allocated: 0,
        };
        assert_eq!(
            context.allocate_string(RawValue { bytes: br#""ab""# }),
            Err(DecodeFailure::Exhausted)
        );
        assert!(
            authority.allocation_is_forced_to_fail(),
            "aggregate admission must run before entering the allocator"
        );

        authority.fail_after_allocations(0);
        let mut context = DecodeContext {
            authority: &authority,
            limit: std::mem::size_of::<u64>(),
            allocated: 0,
        };
        assert_eq!(
            context.allocate_vec::<u64>(2),
            Err(DecodeFailure::Exhausted)
        );
        assert!(
            authority.allocation_is_forced_to_fail(),
            "aggregate admission must run before entering the allocator"
        );
        assert_eq!(authority.snapshot().active_public, 0);
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    #[test]
    fn every_decode_and_canonical_allocator_boundary_fails_closed_without_a_leak() {
        let action = Action::InputWrite(InputWriteParams {
            pane_id: PaneId::test_fixture(),
            run_id: RunId::test_fixture(),
            text: "line\n日".to_owned(),
        });
        let expected = canonical_request(&request(action)).expect("canonical input request");
        let mut first_success = None;
        for successful_allocations in 0..16 {
            let authority = AllocationAuthority::host();
            let frame = owned_frame(&authority, AllocationPool::ActivePublic, &expected);
            authority.fail_after_allocations(successful_allocations);
            match prepare_request(frame, &authority, AllocationPool::ActivePublic) {
                Err(HostCodecError::Exhausted { .. }) => {
                    assert_eq!(authority.snapshot().active_public, 0);
                }
                Ok(prepared) => {
                    first_success = Some(successful_allocations);
                    drop(prepared);
                    assert_eq!(authority.snapshot().active_public, 0);
                    break;
                }
                Err(other) => panic!("allocator fault changed contract classification: {other:?}"),
            }
        }
        assert_eq!(first_success, Some(7));
    }

    #[test]
    fn exact_message_boundary_keeps_final_string_and_canonical_capacity_owned() {
        let empty = request(Action::InputWrite(InputWriteParams {
            pane_id: PaneId::test_fixture(),
            run_id: RunId::test_fixture(),
            text: String::new(),
        }));
        let overhead = canonical_request(&empty)
            .expect("empty canonical request")
            .len();
        let boundary = request(Action::InputWrite(InputWriteParams {
            pane_id: PaneId::test_fixture(),
            run_id: RunId::test_fixture(),
            text: "x".repeat(MAX_MESSAGE_BYTES - overhead),
        }));
        let bytes = canonical_request(&boundary).expect("exact boundary request");
        assert_eq!(bytes.len(), MAX_MESSAGE_BYTES);
        let authority = AllocationAuthority::host();
        let prepared = prepare_request(
            owned_frame(&authority, AllocationPool::ActiveOwner, &bytes),
            &authority,
            AllocationPool::ActiveOwner,
        )
        .expect("boundary request");
        assert_eq!(prepared.canonical().len(), MAX_MESSAGE_BYTES);
        assert_eq!(
            authority.snapshot().active_owner,
            prepared.request().owned_capacity() + MAX_MESSAGE_BYTES
        );
        drop(prepared);
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    fn response_with(result: Option<Success>, error: Option<WireError>) -> Response {
        Response {
            schema_version: Version::new(1).expect("schema version"),
            instance_id: InstanceId::test_fixture(),
            operation_id: OperationId::test_fixture(),
            accepted: result.is_some(),
            topology_revision: U::new(0).expect("topology revision"),
            event_seq: U::new(0).expect("event sequence"),
            result: Nullable(result),
            error: Nullable(error),
        }
    }

    #[test]
    fn every_declared_response_variant_matches_public_canonical_encoding() {
        let fixtures = Success::host_codec_fixtures();
        assert_eq!(fixtures.len(), OperationName::ALL.len());
        for success in fixtures {
            let response = response_with(Some(success), None);
            let expected =
                crate::contract::wire::encoded(&response).expect("public canonical response");
            let authority = AllocationAuthority::host();
            let actual = response_body_owned(&response, &authority, AllocationPool::ActiveOwner)
                .expect("owned canonical response");
            assert_eq!(&*actual, expected);
            assert_eq!(actual.charged_bytes(), actual.len());
            assert_eq!(authority.snapshot().active_owner, actual.len());
            drop(actual);
            assert_eq!(authority.snapshot().active_owner, 0);
        }

        let error = ErrorCode::ResourceExhausted
            .with_target(None)
            .expect("fixed error");
        assert_eq!(error.owned_capacity(), 0);
        let response = response_with(None, Some(error));
        let expected = crate::contract::wire::encoded(&response).expect("public canonical error");
        let authority = AllocationAuthority::host();
        let actual = response_body_owned(&response, &authority, AllocationPool::ActivePublic)
            .expect("owned canonical error");
        assert_eq!(&*actual, expected);
        drop(actual);
        assert_eq!(authority.snapshot().active_public, 0);
    }

    #[test]
    fn response_allocator_failure_is_closed_and_releases_the_claim() {
        let request = request(Action::CapabilitiesGet(CapabilitiesGetParams::default()));
        let response = response_with(
            Some(Success::CapabilitiesGet(CapabilitiesData {
                schema_version: Version::new(1).expect("schema version"),
                operations: StringSet::new(Vec::new()).expect("empty operation set"),
                max_message_bytes: MessageLimit::new(MAX_MESSAGE_BYTES as u64)
                    .expect("message limit"),
                providers: Nullable(None),
                replay_capacity: ReplayCapacity {
                    retained_bytes: P::new(crate::host::admission::RETAINED_BYTES as u64)
                        .expect("retained capacity"),
                    active_bytes: P::new(crate::host::admission::ACTIVE_BYTES as u64)
                        .expect("active capacity"),
                },
                shell_profile_ids: Nullable(None),
            })),
            None,
        );
        let authority = AllocationAuthority::host();
        authority.fail_after_allocations(0);
        let error = match serialize_response_owned(
            &request,
            &response,
            &authority,
            AllocationPool::ActivePublic,
        ) {
            Err(error) => error,
            Ok(_) => panic!("forced allocation failure produced a reply"),
        };
        assert_eq!(
            error,
            HostCodecError::Exhausted {
                phase: HostCodecPhase::Canonical,
                correlation: Some(WireCorrelation {
                    operation: OperationName::CapabilitiesGet,
                    has_instance: false,
                    operation_id: request.operation_id.clone(),
                    instance_id: request.instance_id.0.clone(),
                }),
            }
        );
        assert_eq!(authority.snapshot().active_public, 0);

        let reply = serialize_response_owned(
            &request,
            &response,
            &authority,
            AllocationPool::ActivePublic,
        )
        .expect("allocation recovers after a failed attempt");
        assert_eq!(reply.charged_bytes(), reply.len());
        drop(reply);
        assert_eq!(authority.snapshot().active_public, 0);
    }

    fn assert_tagged_value_parity<T: CanonicalValue + serde::Serialize>(value: &T) {
        let expected = crate::contract::wire::encoded(value).expect("public canonical value");
        let mut measured = Measure(0);
        value
            .write_canonical(&mut measured)
            .expect("measure canonical value");
        let authority = AllocationAuthority::host();
        let mut actual = ChargedVec::with_capacity(
            &authority,
            AllocationPool::ActiveOwner,
            measured.0,
            measured.0,
        )
        .expect("allocate canonical value");
        value
            .write_canonical(&mut Output(&mut actual))
            .expect("write canonical value");
        assert_eq!(&*actual, expected);
        drop(actual);
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    #[test]
    fn tagged_response_subvariants_match_public_canonical_encoding() {
        let events = [
            EventData::TopologyChanged {
                topology_revision: U::test_fixture(),
                project_id: Nullable::test_fixture(),
                pane_id: Nullable::test_fixture(),
            },
            EventData::RunStateChanged {
                run: RunObservation::test_fixture(),
            },
            EventData::OperationStateChanged {
                operation: OperationStatus::test_fixture(),
            },
            EventData::ConnectionStateChanged {
                connection_id: ConnectionId::test_fixture(),
                state: ConnectionState::test_fixture(),
            },
        ];
        for event in events {
            assert_tagged_value_parity(&event);
        }

        for ratio in [0.5, f64::MIN_POSITIVE, 0.999_999_999_999_999_9] {
            let layout = LayoutNode::split(
                Axis::Horizontal,
                Ratio::new(ratio).expect("legal ratio"),
                LayoutNode::leaf(PaneId::test_fixture()),
                LayoutNode::leaf(PaneId::test_fixture()),
            )
            .expect("legal layout depth");
            assert_tagged_value_parity(&layout);
        }
    }

    fn output_exchange(text: String) -> (Request, Response) {
        let run_id = RunId::test_fixture();
        let request = request(Action::OutputRead(OutputReadParams {
            cursor: Nullable(None),
            max_bytes: P::new(MAX_MESSAGE_BYTES as u64).expect("maximum output request"),
            run_id: run_id.clone(),
        }));
        let response = response_with(
            Some(Success::OutputRead(OutputReadData {
                run_id,
                text,
                next_cursor: NonEmpty::new("x").expect("cursor"),
                gap: false,
                truncated: false,
            })),
            None,
        );
        (request, response)
    }

    #[test]
    fn exact_response_boundary_is_charged_and_overflow_is_default_deny() {
        let (request, empty) = output_exchange(String::new());
        let overhead = crate::contract::serialize_response(&request, &empty)
            .expect("empty public response")
            .len();
        let (request, boundary) = output_exchange("x".repeat(MAX_MESSAGE_BYTES - overhead));
        let expected = crate::contract::serialize_response(&request, &boundary)
            .expect("exact public response boundary");
        assert_eq!(expected.len(), MAX_MESSAGE_BYTES);
        let authority = AllocationAuthority::host();
        let reply =
            serialize_response_owned(&request, &boundary, &authority, AllocationPool::ActiveOwner)
                .expect("exact owned response boundary");
        assert_eq!(&*reply, expected);
        assert_eq!(reply.charged_bytes(), MAX_MESSAGE_BYTES);
        assert_eq!(authority.snapshot().active_owner, MAX_MESSAGE_BYTES);
        drop(reply);
        assert_eq!(authority.snapshot().active_owner, 0);

        let (request, oversized) = output_exchange("x".repeat(MAX_MESSAGE_BYTES - overhead + 1));
        let error = match serialize_response_owned(
            &request,
            &oversized,
            &authority,
            AllocationPool::ActiveOwner,
        ) {
            Err(error) => error,
            Ok(_) => panic!("oversized response was accepted"),
        };
        assert_eq!(
            error,
            HostCodecError::Exhausted {
                phase: HostCodecPhase::Canonical,
                correlation: Some(WireCorrelation {
                    operation: OperationName::OutputRead,
                    has_instance: true,
                    operation_id: request.operation_id.clone(),
                    instance_id: request.instance_id.0.clone(),
                }),
            }
        );
        assert_eq!(authority.snapshot().active_owner, 0);
    }

    #[test]
    fn recovery_capacities_cover_every_public_terminal_and_match_canonical_request() {
        let empty_projects = StringSet::new(Vec::new()).expect("empty project set");
        let empty_scopes = StringSet::new(Vec::new()).expect("empty scope set");
        let recovery_request = Request {
            schema_version: Version::new(1).expect("schema version"),
            instance_id: Nullable(Some(
                InstanceId::new(SIZING_UUID).expect("sizing instance ID"),
            )),
            operation_id: OperationId::new(SIZING_UUID).expect("sizing operation ID"),
            expected_topology_revision: Nullable(None),
            action: Action::ConnectionDecide(ConnectionDecideParams {
                connection_id: ConnectionId::new(SIZING_UUID).expect("sizing connection ID"),
                decision: Decision::Deny,
                project_ids: empty_projects.clone(),
                scopes: empty_scopes.clone(),
            }),
        };
        let capacities = recovery_buffer_capacities().expect("measure recovery buffers");
        let canonical = canonical_request(&recovery_request).expect("public canonical request");
        assert_eq!(capacities.canonical, canonical.len());

        let max_counter = U::new(MAX_SAFE_INTEGER).expect("maximum safe counter");
        let instance_id = InstanceId::new(SIZING_UUID).expect("sizing instance ID");
        let operation_id = OperationId::new(SIZING_UUID).expect("sizing operation ID");
        let connection_id = ConnectionId::new(SIZING_UUID).expect("sizing connection ID");
        let revoke_request = Request {
            schema_version: Version::new(1).expect("schema version"),
            instance_id: Nullable(Some(instance_id.clone())),
            operation_id: operation_id.clone(),
            expected_topology_revision: Nullable(None),
            action: Action::ConnectionRevoke(ConnectionParams {
                connection_id: connection_id.clone(),
            }),
        };
        let successes = [
            (
                &recovery_request,
                Success::ConnectionDecide(ConnectionDecideData {
                    connection_id: connection_id.clone(),
                    state: DecidedState::Revoked,
                    project_ids: empty_projects,
                    scopes: empty_scopes,
                }),
            ),
            (
                &revoke_request,
                Success::ConnectionRevoke(ConnectionRevokeData {
                    connection_id,
                    state: RevokedState::Revoked,
                }),
            ),
        ];
        let mut observed_max = 0usize;
        for (request, success) in successes {
            let response = Response {
                schema_version: Version::new(1).expect("schema version"),
                instance_id: instance_id.clone(),
                operation_id: operation_id.clone(),
                accepted: true,
                topology_revision: max_counter,
                event_seq: max_counter,
                result: Nullable(Some(success)),
                error: Nullable(None),
            };
            let terminal = serialize_response(request, &response)
                .expect("public recovery success terminal");
            observed_max = observed_max.max(terminal.len());
            assert!(terminal.len() <= capacities.terminal);
        }
        for code in ErrorCode::ALL {
            let target = code
                .allows_target()
                .then(|| TargetId::new(SIZING_UUID).expect("sizing target ID"));
            let response = Response {
                schema_version: Version::new(1).expect("schema version"),
                instance_id: instance_id.clone(),
                operation_id: operation_id.clone(),
                accepted: false,
                topology_revision: max_counter,
                event_seq: max_counter,
                result: Nullable(None),
                error: Nullable(Some(code.with_target(target).expect("legal error target"))),
            };
            let terminal = serialize_response(&recovery_request, &response)
                .expect("public recovery error terminal");
            observed_max = observed_max.max(terminal.len());
            assert!(terminal.len() <= capacities.terminal, "{}", code.wire());
        }
        assert_eq!(observed_max, capacities.terminal);
    }
}
