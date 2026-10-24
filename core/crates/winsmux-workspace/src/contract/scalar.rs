use super::ContractError;
use schemars::{gen::SchemaGenerator, schema::Schema, JsonSchema};
use serde::{de::Error, Deserialize, Deserializer, Serialize};

pub(crate) trait OwnedCapacity {
    fn owned_capacity(&self) -> usize;
}

macro_rules! zero_capacity {
    ($($ty:ty),+ $(,)?) => {$ (
        impl OwnedCapacity for $ty {
            fn owned_capacity(&self) -> usize { 0 }
        }
    )+};
}

zero_capacity!(bool, u64, i32, f64, ());

impl OwnedCapacity for String {
    fn owned_capacity(&self) -> usize {
        self.capacity()
    }
}

impl<T: OwnedCapacity> OwnedCapacity for Vec<T> {
    fn owned_capacity(&self) -> usize {
        self.capacity()
            .saturating_mul(std::mem::size_of::<T>())
            .saturating_add(
                self.iter()
                    .map(OwnedCapacity::owned_capacity)
                    .fold(0usize, usize::saturating_add),
            )
    }
}

impl<T: OwnedCapacity> OwnedCapacity for Box<T> {
    fn owned_capacity(&self) -> usize {
        std::mem::size_of::<T>().saturating_add((**self).owned_capacity())
    }
}

pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub(crate) const UUID_PATTERN: &str =
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$";
// v1 explicitly supports seconds 00..59. No leap-second table or external lookup.
pub(crate) const TIMESTAMP_PATTERN: &str = r"^(?:[0-9]{4}-(?:(?:01|03|05|07|08|10|12)-(?:0[1-9]|[12][0-9]|3[01])|(?:04|06|09|11)-(?:0[1-9]|[12][0-9]|30)|02-(?:0[1-9]|1[0-9]|2[0-8]))|(?:[0-9]{2}(?:0[48]|[2468][048]|[13579][26])|(?:[02468][048]|[13579][26])00)-02-29)T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?Z$";
pub(crate) const RELATIVE_PATH_PATTERN: &str = r"^(?![\s\S]*[\\:\u0000-\u001f\u007f-\u009f])(?!(?:[Cc][Oo][Nn]|[Pp][Rr][Nn]|[Aa][Uu][Xx]|[Nn][Uu][Ll]|[Cc][Oo][Nn][Ii][Nn]\$|[Cc][Oo][Nn][Oo][Uu][Tt]\$|[Cc][Oo][Mm][1-9¹²³]|[Ll][Pp][Tt][1-9¹²³])(?:\.|/|$))[^/]*[^/ .](?:/(?!(?:[Cc][Oo][Nn]|[Pp][Rr][Nn]|[Aa][Uu][Xx]|[Nn][Uu][Ll]|[Cc][Oo][Nn][Ii][Nn]\$|[Cc][Oo][Nn][Oo][Uu][Tt]\$|[Cc][Oo][Mm][1-9¹²³]|[Ll][Pp][Tt][1-9¹²³])(?:\.|/|$))[^/]*[^/ .])*$";

/// An explicit nullable value. Unlike Option, a missing object field is invalid.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Nullable<T>(pub Option<T>);
impl<T: OwnedCapacity> OwnedCapacity for Nullable<T> {
    fn owned_capacity(&self) -> usize {
        self.0.as_ref().map_or(0, OwnedCapacity::owned_capacity)
    }
}
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Nullable<T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        // A newtype boundary preserves missing versus null without an untyped field.
        d.deserialize_newtype_struct(
            "RequiredNullable",
            NullableVisitor::<T>(std::marker::PhantomData),
        )
    }
}
struct NullableVisitor<T>(std::marker::PhantomData<T>);
impl<'de, T: Deserialize<'de>> serde::de::Visitor<'de> for NullableVisitor<T> {
    type Value = Nullable<T>;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("required nullable value")
    }
    fn visit_newtype_struct<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
        Option::<T>::deserialize(d).map(Nullable)
    }
}
impl<T: JsonSchema> JsonSchema for Nullable<T> {
    fn schema_name() -> String {
        format!("Nullable_{}", T::schema_name())
    }
    fn is_referenceable() -> bool {
        false
    }
    fn json_schema(g: &mut SchemaGenerator) -> Schema {
        <Option<T>>::json_schema(g)
    }
}

/// A collection with set semantics. Ordering on the wire is by the unchanged
/// string value, rather than enum declaration order or JSON escape bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StringSet<T>(Vec<T>);
impl<T: Ord> StringSet<T> {
    pub fn new(values: Vec<T>) -> Result<Self, ContractError> {
        if values
            .iter()
            .enumerate()
            .any(|(index, value)| values[index + 1..].contains(value))
        {
            return Err(ContractError::InvariantViolation);
        }
        Ok(Self(values))
    }
}
impl<T: OwnedCapacity> OwnedCapacity for StringSet<T> {
    fn owned_capacity(&self) -> usize {
        self.0.owned_capacity()
    }
}
impl<T> std::ops::Deref for StringSet<T> {
    type Target = [T];
    fn deref(&self) -> &[T] {
        &self.0
    }
}
impl<'de, T: Deserialize<'de> + Ord> Deserialize<'de> for StringSet<T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Self::new(Vec::<T>::deserialize(d)?).map_err(|_| D::Error::custom("__invariant"))
    }
}
impl<T: Serialize> Serialize for StringSet<T> {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::Error;
        let mut values = Vec::with_capacity(self.0.len());
        for v in &self.0 {
            let string = serde_json::to_value(v)
                .map_err(|_| S::Error::custom("__scalar"))?
                .as_str()
                .ok_or_else(|| S::Error::custom("__shape"))?
                .to_owned();
            values.push((string, v));
        }
        values.sort_by(|a, b| a.0.cmp(&b.0));
        values
            .into_iter()
            .map(|(_, v)| v)
            .collect::<Vec<_>>()
            .serialize(s)
    }
}
impl<T: JsonSchema> JsonSchema for StringSet<T> {
    fn schema_name() -> String {
        format!("StringSet_{}", T::schema_name())
    }
    fn json_schema(g: &mut SchemaGenerator) -> Schema {
        let mut schema = Vec::<T>::json_schema(g).into_object();
        schema.array.as_mut().unwrap().unique_items = Some(true);
        Schema::Object(schema)
    }
}

fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            14 => b == b'4',
            19 => matches!(b, b'8' | b'9' | b'a' | b'b'),
            _ => b.is_ascii_digit() || (b'a'..=b'f').contains(&b),
        })
}
pub(crate) fn string_schema(pattern: Option<&str>, min: Option<u32>) -> Schema {
    let mut s = schemars::schema::SchemaObject {
        instance_type: Some(schemars::schema::InstanceType::String.into()),
        ..Default::default()
    };
    // `$` alone also matches before a final newline in ECMAScript/Python.
    s.string = Some(Box::new(schemars::schema::StringValidation {
        pattern: pattern.map(|p| format!("(?:{p})(?![\\s\\S])")),
        min_length: min,
        ..Default::default()
    }));
    Schema::Object(s)
}
macro_rules! strings {
    ($($name:ident => $check:expr, $pattern:expr, $min:expr;)*) => {$ (
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
        #[serde(transparent)] pub struct $name(String);
        impl $name {
            pub fn new(value: impl Into<String>) -> Result<Self, ContractError> {
                let value = value.into(); if ($check)(&value) { Ok(Self(value)) } else { Err(ContractError::InvalidScalar) }
            }
            pub fn as_str(&self) -> &str { &self.0 }
        }
        impl OwnedCapacity for $name {
            fn owned_capacity(&self) -> usize { self.0.capacity() }
        }
        impl $crate::contract::ingress::DecodeOwned for $name {
            fn decode_owned(
                context: &mut $crate::contract::ingress::DecodeContext<'_>,
                raw: $crate::contract::ingress::RawValue<'_>,
            ) -> Result<Self, $crate::contract::ingress::DecodeFailure> {
                let value = <String as $crate::contract::ingress::DecodeOwned>::decode_owned(context, raw)?;
                Self::new(value).map_err($crate::contract::ingress::DecodeFailure::Contract)
            }
        }
        impl $crate::contract::ingress::WireText for $name {
            fn wire_text(&self) -> &str { self.as_str() }
        }
        impl $crate::contract::ingress::CanonicalValue for $name {
            fn write_canonical(
                &self,
                sink: &mut impl $crate::contract::ingress::Sink,
            ) -> Result<(), $crate::host::admission::AllocationError> {
                $crate::contract::ingress::json_string(sink, self.as_str())
            }
        }
        #[cfg(test)]
        impl $crate::contract::ingress::TestFixture for $name {
            fn test_fixture() -> Self {
                Self::new($crate::contract::ingress::fixture_string(stringify!($name)))
                    .expect("host codec scalar fixture")
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = String::deserialize(d)?; Self::new(s).map_err(|_| D::Error::custom("__scalar"))
            }
        }
        impl JsonSchema for $name {
            fn schema_name() -> String { stringify!($name).into() }
            fn json_schema(_: &mut SchemaGenerator) -> Schema { string_schema($pattern, $min) }
        }
    )*};
}
strings! {
    ProjectId => uuid, Some(UUID_PATTERN), None;
    PaneId => uuid, Some(UUID_PATTERN), None;
    RunId => uuid, Some(UUID_PATTERN), None;
    OperationId => uuid, Some(UUID_PATTERN), None;
    InstanceId => uuid, Some(UUID_PATTERN), None;
    ConnectionId => uuid, Some(UUID_PATTERN), None;
    ArtifactId => uuid, Some(UUID_PATTERN), None;
    TargetId => uuid, Some(UUID_PATTERN), None;
    NonEmpty => |s: &str| !s.is_empty(), None, Some(1);
    Hex16 => |s: &str| hex(s,16), Some("^[0-9a-f]{16}$"), None;
    Hex32 => |s: &str| hex(s,32), Some("^[0-9a-f]{32}$"), None;
    Timestamp => timestamp, Some(TIMESTAMP_PATTERN), None;
    RelativePath => relative_path, Some(RELATIVE_PATH_PATTERN), Some(1);
}
fn hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn timestamp(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b.last() == Some(&b'Z')
        && b[..19]
            .iter()
            .enumerate()
            .all(|(i, c)| matches!(i, 4 | 7 | 10 | 13 | 16) || c.is_ascii_digit())
        && (b.len() == 20
            || (b[19] == b'.' && b.len() > 21 && b[20..b.len() - 1].iter().all(u8::is_ascii_digit)))
        && b[17] <= b'5'
        && chrono::DateTime::parse_from_rfc3339(s).is_ok()
}
pub(crate) fn relative_path(s: &str) -> bool {
    !s.is_empty()
        && !s.chars().any(|c| c.is_control() || matches!(c, '\\' | ':'))
        && s.split('/').all(|p| {
            if p.is_empty() || p == "." || p == ".." || p.ends_with(['.', ' ']) {
                return false;
            }
            let base = p.split('.').next().unwrap_or("");
            !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
                .iter()
                .any(|reserved| base.eq_ignore_ascii_case(reserved))
                && !["COM", "LPT"].iter().any(|prefix| {
                    base.get(..3)
                        .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
                        && base.get(3..).is_some_and(|n| {
                            matches!(
                                n,
                                "1" | "2"
                                    | "3"
                                    | "4"
                                    | "5"
                                    | "6"
                                    | "7"
                                    | "8"
                                    | "9"
                                    | "¹"
                                    | "²"
                                    | "³"
                            )
                        })
                })
        })
}

macro_rules! integer {
    ($name:ident, $inner:ty, $min:expr, $max:expr) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
        #[serde(transparent)]
        pub struct $name($inner);
        impl $name {
            pub fn new(value: $inner) -> Result<Self, ContractError> {
                if ($min..=$max).contains(&value) {
                    Ok(Self(value))
                } else {
                    Err(ContractError::InvalidScalar)
                }
            }
            pub fn get(self) -> $inner {
                self.0
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                struct V;
                impl<'de> serde::de::Visitor<'de> for V {
                    type Value = $name;
                    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                        f.write_str("integer")
                    }
                    fn visit_u64<E: Error>(self, n: u64) -> Result<$name, E> {
                        <$inner>::try_from(n)
                            .ok()
                            .and_then(|v| $name::new(v).ok())
                            .ok_or_else(|| E::custom("__scalar"))
                    }
                    fn visit_i64<E: Error>(self, n: i64) -> Result<$name, E> {
                        <$inner>::try_from(n)
                            .ok()
                            .and_then(|v| $name::new(v).ok())
                            .ok_or_else(|| E::custom("__scalar"))
                    }
                    fn visit_f64<E: Error>(self, _: f64) -> Result<$name, E> {
                        Err(E::custom("__scalar"))
                    }
                }
                d.deserialize_any(V)
            }
        }
        impl OwnedCapacity for $name {
            fn owned_capacity(&self) -> usize {
                0
            }
        }
        impl $crate::contract::ingress::DecodeOwned for $name {
            fn decode_owned(
                _context: &mut $crate::contract::ingress::DecodeContext<'_>,
                raw: $crate::contract::ingress::RawValue<'_>,
            ) -> Result<Self, $crate::contract::ingress::DecodeFailure> {
                let value: $inner = $crate::contract::ingress::decode_integer(raw)?;
                Self::new(value).map_err($crate::contract::ingress::DecodeFailure::Contract)
            }
        }
        #[cfg(test)]
        impl $crate::contract::ingress::TestFixture for $name {
            fn test_fixture() -> Self {
                Self::new($min).expect("host codec integer fixture")
            }
        }
        impl JsonSchema for $name {
            fn schema_name() -> String {
                stringify!($name).into()
            }
            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                let mut s = schemars::schema::SchemaObject {
                    instance_type: Some(schemars::schema::InstanceType::Integer.into()),
                    ..Default::default()
                };
                s.number = Some(Box::new(schemars::schema::NumberValidation {
                    minimum: Some($min as f64),
                    maximum: Some($max as f64),
                    ..Default::default()
                }));
                Schema::Object(s)
            }
        }
    };
}
integer!(U, u64, 0, MAX_SAFE_INTEGER);
integer!(P, u64, 1, MAX_SAFE_INTEGER);
integer!(ExitCode, i32, i32::MIN, i32::MAX);
integer!(Version, u64, 1, 1);
integer!(MessageLimit, u64, 1_048_576, 1_048_576);
integer!(OneByte, u64, 1, 1);

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Ratio(f64);
impl Ratio {
    pub fn new(v: f64) -> Result<Self, ContractError> {
        if v.is_finite() && v > 0.0 && v < 1.0 {
            Ok(Self(v))
        } else {
            Err(ContractError::InvalidScalar)
        }
    }
    pub fn get(self) -> f64 {
        self.0
    }
}
impl<'de> Deserialize<'de> for Ratio {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Self::new(f64::deserialize(d)?).map_err(|_| D::Error::custom("__scalar"))
    }
}
impl JsonSchema for Ratio {
    fn schema_name() -> String {
        "Ratio".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        serde_json::from_value(
            serde_json::json!({"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1}),
        )
        .unwrap()
    }
}
impl OwnedCapacity for Ratio {
    fn owned_capacity(&self) -> usize {
        0
    }
}
#[cfg(test)]
impl crate::contract::ingress::TestFixture for Ratio {
    fn test_fixture() -> Self {
        Self::new(0.5).expect("fixture ratio")
    }
}
