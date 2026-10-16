use super::*;
use serde::{
    de::{DeserializeOwned, Error, MapAccess, SeqAccess, Visitor},
    Deserialize, Deserializer, Serialize,
};
use serde_json::{Map, Value};

// Private staging DOM: rejects duplicates before any lossy map insertion.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Unique;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("JSON")
            }
            fn visit_bool<E: Error>(self, v: bool) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_i64<E: Error>(self, v: i64) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_u64<E: Error>(self, v: u64) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_f64<E: Error>(self, v: f64) -> Result<Unique, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("__scalar"))
            }
            fn visit_str<E: Error>(self, v: &str) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_string<E: Error>(self, v: String) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_unit<E: Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut v = Vec::new();
                while let Some(Unique(x)) = a.next_element()? {
                    v.push(x);
                }
                Ok(Unique(Value::Array(v)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut m = Map::new();
                while let Some(k) = a.next_key::<String>()? {
                    if m.contains_key(&k) {
                        return Err(A::Error::custom("__duplicate"));
                    }
                    m.insert(k, a.next_value::<Unique>()?.0);
                }
                Ok(Unique(Value::Object(m)))
            }
        }
        d.deserialize_any(V)
    }
}
fn raw(bytes: &[u8]) -> Result<Value, ContractError> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(ContractError::MessageTooLarge);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| ContractError::InvalidUtf8)?;
    if text.starts_with('\u{feff}') {
        return Err(ContractError::BomForbidden);
    }
    let mut d = serde_json::Deserializer::from_str(text);
    let value = Unique::deserialize(&mut d)
        .map_err(|e| {
            let s = e.to_string();
            if s.starts_with("__duplicate at line ") {
                ContractError::DuplicateKey
            } else if s.contains("recursion limit exceeded") {
                ContractError::NestingLimit
            } else if s.contains("number out of range") {
                ContractError::InvalidScalar
            } else {
                ContractError::InvalidJson
            }
        })?
        .0;
    d.end().map_err(|_| ContractError::InvalidJson)?;
    if let Some(version) = value.get("schema_version") {
        if version.is_u64() && version.as_u64() != Some(1) {
            return Err(ContractError::UnsupportedSchema);
        }
    }
    Ok(value)
}
fn typed<T: DeserializeOwned>(value: Value) -> Result<T, ContractError> {
    serde_json::from_value(value).map_err(|e| {
        if e.to_string() == "__scalar" {
            ContractError::InvalidScalar
        } else if e.to_string() == "__invariant" {
            ContractError::InvariantViolation
        } else {
            ContractError::InvalidShape
        }
    })
}
pub fn parse_request(bytes: &[u8]) -> Result<Request, ContractError> {
    let mut v: Request = typed(raw(bytes)?)?;
    v.action.normalize_extension();
    v.validate()?;
    Ok(v)
}
pub fn parse_response(request: &Request, bytes: &[u8]) -> Result<Response, ContractError> {
    let v: Response = typed(raw(bytes)?)?;
    v.validate(request)?;
    Ok(v)
}
pub fn parse_snapshot(bytes: &[u8]) -> Result<Snapshot, ContractError> {
    let v: Snapshot = typed(raw(bytes)?)?;
    v.validate()?;
    Ok(v)
}

// serde_json may have preserve_order enabled by another workspace member, so
// explicitly rebuild maps rather than relying on the selected Map backend.
fn canonical(value: Value) -> Value {
    match value {
        Value::Object(m) => {
            let mut pairs: Vec<_> = m.into_iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(pairs.into_iter().map(|(k, v)| (k, canonical(v))).collect())
        }
        Value::Array(a) => Value::Array(a.into_iter().map(canonical).collect()),
        v => v,
    }
}
pub(super) fn encoded<T: Serialize>(v: &T) -> Result<Vec<u8>, ContractError> {
    let value = serde_json::to_value(v).map_err(|_| ContractError::InvalidScalar)?;
    let bytes = serde_json::to_vec(&canonical(value)).map_err(|_| ContractError::InvalidScalar)?;
    // Raw parser enforces the identical total-container depth and byte limit.
    raw(&bytes)?;
    Ok(bytes)
}
pub fn canonical_request(request: &Request) -> Result<Vec<u8>, ContractError> {
    request.validate()?;
    let mut normalized = request.clone();
    normalized.action.normalize_extension();
    let bytes = encoded(&normalized)?;
    parse_request(&bytes)?;
    Ok(bytes)
}
pub fn serialize_response(
    request: &Request,
    response: &Response,
) -> Result<Vec<u8>, ContractError> {
    response.validate(request)?;
    let bytes = encoded(response)?;
    parse_response(request, &bytes)?;
    Ok(bytes)
}
pub fn serialize_snapshot(snapshot: &Snapshot) -> Result<Vec<u8>, ContractError> {
    snapshot.validate()?;
    let mut s = snapshot.clone();
    s.projects.sort_by(|a, b| a.project_id.cmp(&b.project_id));
    s.panes.sort_by(|a, b| a.pane_id.cmp(&b.pane_id));
    s.layouts.sort_by(|a, b| a.project_id.cmp(&b.project_id));
    let bytes = encoded(&s)?;
    parse_snapshot(&bytes)?;
    Ok(bytes)
}
