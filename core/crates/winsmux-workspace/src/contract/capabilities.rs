use super::ingress::{CanonicalValue, DecodeContext, DecodeFailure, DecodeOwned, ObjectReader, RawValue, Sink};
use super::{ContractError, OwnedCapacity};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

fn is_false(value: &bool) -> bool { !*value }

/// Empty parameters remain a passive observation; refresh explicitly retries
/// a failed version probe. False and omission share the original canonical {}.
#[derive(Debug, Clone, PartialEq, Default, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CapabilitiesGetParams {
    #[serde(default, skip_serializing_if="is_false")]
    pub refresh: bool,
}

impl<'de> Deserialize<'de> for CapabilitiesGetParams {
    fn deserialize<D:serde::Deserializer<'de>>(d:D)->Result<Self,D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Fields { #[serde(default)] refresh:bool }
        struct Object;
        impl<'de> serde::de::Visitor<'de> for Object {
            type Value=CapabilitiesGetParams;
            fn expecting(&self,f:&mut std::fmt::Formatter)->std::fmt::Result { f.write_str("object") }
            fn visit_map<A:serde::de::MapAccess<'de>>(self,map:A)->Result<Self::Value,A::Error> {
                let fields=Fields::deserialize(serde::de::value::MapAccessDeserializer::new(map))?;
                Ok(CapabilitiesGetParams { refresh:fields.refresh })
            }
        }
        d.deserialize_map(Object)
    }
}

impl OwnedCapacity for CapabilitiesGetParams {
    fn owned_capacity(&self) -> usize { 0 }
}

impl DecodeOwned for CapabilitiesGetParams {
    fn decode_owned(context: &mut DecodeContext<'_>, raw: RawValue<'_>) -> Result<Self, DecodeFailure> {
        let mut result=Self::default();
        let mut object=ObjectReader::new(raw)?;
        while let Some((key,value))=object.next()? {
            if !key.equals("refresh") { return Err(DecodeFailure::Contract(ContractError::InvalidShape)); }
            result.refresh=bool::decode_owned(context,value)?;
        }
        Ok(result)
    }
}

impl CanonicalValue for CapabilitiesGetParams {
    fn write_canonical(&self, sink: &mut impl Sink) -> Result<(), crate::host::admission::AllocationError> {
        sink.bytes(if self.refresh { b"{\"refresh\":true}" } else { b"{}" })
    }
}

#[cfg(test)]
impl super::ingress::TestFixture for CapabilitiesGetParams {
    fn test_fixture() -> Self { Self::default() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::{canonical_request,parse_request};
    fn request(params:&str)->Vec<u8> {
        format!(r#"{{"schema_version":1,"instance_id":null,"operation_id":"00000000-0000-4000-8000-000000000001","expected_topology_revision":null,"operation":"capabilities.get","params":{params}}}"#).into_bytes()
    }
    #[test]
    fn omitted_false_true_and_invalid_refresh_preserve_wire_identity() {
        let empty=canonical_request(&parse_request(&request("{}")).unwrap()).unwrap();
        let passive=canonical_request(&parse_request(&request(r#"{"refresh":false}"#)).unwrap()).unwrap();
        let active=canonical_request(&parse_request(&request(r#"{"refresh":true}"#)).unwrap()).unwrap();
        assert_eq!(empty,passive);assert_ne!(empty,active);
        assert!(String::from_utf8(active).unwrap().contains(r#""params":{"refresh":true}"#));
        for invalid in ["[]","[true]","null","true",r#"{"refresh":null}"#,r#"{"refresh":0}"#,r#"{"refresh":"true"}"#,r#"{"refresh":true,"extra":0}"#,r#"{"refresh":true,"refresh":false}"#] {
            assert!(parse_request(&request(invalid)).is_err(),"{invalid}");
        }
    }
}
