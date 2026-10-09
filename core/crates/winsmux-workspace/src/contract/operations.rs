use super::types::{enumeration, object};
use super::*;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

// Each operation is declared once with its class, request and success payload.
// Rust enums and all generated projections derive from this inventory.
macro_rules! operations {
    ($($variant:ident => ($wire:literal,$class:ident,$params:ident,$result:ident)),+ $(,)?) => {
        enumeration!(OperationName { $($variant=>$wire),+ });
        #[derive(Debug,Clone,PartialEq,Serialize,Deserialize,JsonSchema)]
        #[serde(tag="operation",content="params",deny_unknown_fields)]
        pub enum Action { $(#[serde(rename=$wire)] $variant($params)),+ }
        #[derive(Debug,Clone,PartialEq,Serialize,Deserialize,JsonSchema)]
        #[serde(tag="operation",content="data",deny_unknown_fields)]
        pub enum Success { $(#[serde(rename=$wire)] $variant($result)),+ }
        impl Action {pub fn operation(&self)->OperationName {match self {$(Self::$variant(_)=>OperationName::$variant),+}}}
        impl Action {
            pub(crate) fn decode_host_params(
                context: &mut $crate::contract::ingress::DecodeContext<'_>,
                operation: OperationName,
                raw: $crate::contract::ingress::RawValue<'_>,
            ) -> Result<Self, $crate::contract::ingress::DecodeFailure> {
                match operation {
                    $(OperationName::$variant => Ok(Self::$variant(<$params as $crate::contract::ingress::DecodeOwned>::decode_owned(context, raw)?)),)+
                }
            }
            pub(crate) fn write_host_params(
                &self,
                sink: &mut impl $crate::contract::ingress::Sink,
            ) -> Result<(), $crate::host::admission::AllocationError> {
                match self {
                    $(Self::$variant(value) => <$params as $crate::contract::ingress::CanonicalValue>::write_canonical(value, sink),)+
                }
            }
            #[cfg(test)]
            pub(crate) fn host_codec_fixtures() -> Vec<Self> {
                vec![$(Self::$variant(<$params as $crate::contract::ingress::TestFixture>::test_fixture())),+]
            }
        }
        impl Success {pub fn operation(&self)->OperationName {match self {$(Self::$variant(_)=>OperationName::$variant),+}}}
        impl $crate::contract::ingress::CanonicalValue for Success {
            fn write_canonical(
                &self,
                sink: &mut impl $crate::contract::ingress::Sink,
            ) -> Result<(), $crate::host::admission::AllocationError> {
                sink.bytes(b"{\"data\":")?;
                match self {
                    $(Self::$variant(value) => <$result as $crate::contract::ingress::CanonicalValue>::write_canonical(value, sink),)+
                }?;
                sink.bytes(b",\"operation\":")?;
                <$crate::contract::OperationName as $crate::contract::ingress::CanonicalValue>::write_canonical(
                    &self.operation(),
                    sink,
                )?;
                sink.bytes(b"}")
            }
        }
        #[cfg(test)]
        impl Success {
            pub(crate) fn host_codec_fixtures() -> Vec<Self> {
                vec![$(Self::$variant(<$result as $crate::contract::ingress::TestFixture>::test_fixture())),+]
            }
        }
        #[cfg(test)]
        impl $crate::contract::ingress::TestFixture for Success {
            fn test_fixture() -> Self {
                Self::host_codec_fixtures()
                    .into_iter()
                    .next()
                    .expect("success fixture inventory")
            }
        }
        impl OwnedCapacity for Action {
            fn owned_capacity(&self)->usize { match self {$(Self::$variant(value)=>value.owned_capacity()),+} }
        }
        impl OwnedCapacity for Success {
            fn owned_capacity(&self)->usize { match self {$(Self::$variant(value)=>value.owned_capacity()),+} }
        }
        impl OperationName {pub fn class(self)->OperationClass {match self {$(Self::$variant=>OperationClass::$class),+}}}
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationClass {
    Q,
    T,
    R,
    A,
    S,
}
operations! {
 CapabilitiesGet=>("capabilities.get",Q,CapabilitiesGetParams,CapabilitiesData),
 ConnectionRequest=>("connection.request",A,ConnectionRequestParams,ConnectionRequestData),
 ConnectionList=>("connection.list",A,Empty,ConnectionListData),
 ConnectionDecide=>("connection.decide",A,ConnectionDecideParams,ConnectionDecideData),
 ConnectionRevoke=>("connection.revoke",A,ConnectionParams,ConnectionRevokeData),
 HostStop=>("host.stop",A,Empty,HostStopData),
 ProjectList=>("project.list",Q,Empty,ProjectListData),
 ProjectOpen=>("project.open",T,ProjectOpenParams,ProjectOpenData),
 ProjectSelect=>("project.select",T,ProjectSelectParams,ProjectSelectData),
 ProjectForget=>("project.forget",T,ProjectParams,ProjectForgetData),
 PaneList=>("pane.list",Q,ProjectParams,PaneListData),
 PaneCreate=>("pane.create",T,PaneCreateParams,PaneCreatedData),
 PaneSplit=>("pane.split",T,PaneSplitParams,PaneCreatedData),
 PaneSelect=>("pane.select",T,PaneSelectParams,Selection),
 PaneClose=>("pane.close",T,PaneCloseParams,PaneCloseData),
 PaneResize=>("pane.resize",R,PaneResizeParams,PaneResizeParams),
 ShellLaunch=>("shell.launch",R,ShellLaunchParams,LaunchData),
 AgentLaunch=>("agent.launch",R,AgentLaunchParams,LaunchData),
 InputWrite=>("input.write",R,InputWriteParams,InputWriteData),
 InputKey=>("input.key",R,InputKeyParams,InputKeyData),
 RunGet=>("run.get",Q,RunGetParams,RunGetData),
 RunInterrupt=>("run.interrupt",R,RunParams,RunInterruptData),
 OperationGet=>("operation.get",Q,OperationParams,OperationGetData),
 OutputRead=>("output.read",Q,OutputReadParams,OutputReadData),
 EventsWait=>("events.wait",Q,EventsWaitParams,EventsWaitData),
 LayoutSave=>("layout.save",S,Empty,LayoutSaveData),
 LayoutRestore=>("layout.restore",T,Empty,LayoutRestoreData),
 ArtifactRegister=>("artifact.register",S,ArtifactRegisterParams,ArtifactRegisterData),
 ArtifactList=>("artifact.list",Q,ProjectParams,ArtifactListData),
 ArtifactRead=>("artifact.read",Q,ArtifactReadParams,ArtifactReadData),
 ArtifactDiff=>("artifact.diff",Q,ArtifactReadParams,ArtifactDiffData),
 ArtifactChoose=>("artifact.choose",S,ArtifactChooseParams,ArtifactChoiceData),
 ArtifactChoiceList=>("artifact.choice.list",Q,ProjectParams,ArtifactChoiceListData),
 DiagnosticsGet=>("diagnostics.get",Q,Empty,DiagnosticsData),
}
object!(host_codec ConnectionRequestParams { project_ids:StringSet<ProjectId>, scopes:StringSet<Scope> });
object!(host_codec ConnectionDecideParams { connection_id:ConnectionId, decision:Decision, project_ids:StringSet<ProjectId>, scopes:StringSet<Scope> });
object!(host_codec ConnectionParams {
    connection_id: ConnectionId
});
object!(host_codec ProjectParams {
    project_id: ProjectId
});
object!(host_codec ProjectOpenParams { path: NonEmpty });
object!(host_codec ProjectSelectParams { project_id:Nullable<ProjectId> });
object!(host_codec PaneCreateParams {
    project_id: ProjectId,
    shell_profile_id: NonEmpty
});
object!(host_codec PaneSplitParams {
    axis: Axis,
    pane_id: PaneId
});
object!(host_codec PaneSelectParams { pane_id:Nullable<PaneId> });
object!(host_codec PaneParams { pane_id: PaneId });
object!(host_codec GuardedPaneCloseParams {
    expected_current_run_id: Nullable<RunId>,
    pane_id: PaneId
});

/// The wire has two closed shapes. Presence is distinct from an expected null.
/// Keep pane_id directly available to the existing response correlation rules.
#[derive(Debug, Clone, PartialEq)]
pub struct PaneCloseParams {
    pub pane_id: PaneId,
    pub expected_current_run_id: Option<Nullable<RunId>>,
}
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
enum PaneCloseShape {
    Legacy(PaneParams),
    Guarded(GuardedPaneCloseParams),
}
impl Serialize for PaneCloseParams {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(if self.expected_current_run_id.is_some() { 2 } else { 1 }))?;
        if let Some(expected) = &self.expected_current_run_id { map.serialize_entry("expected_current_run_id", expected)?; }
        map.serialize_entry("pane_id", &self.pane_id)?;
        map.end()
    }
}
impl<'de> Deserialize<'de> for PaneCloseParams {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = PaneCloseParams;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result { formatter.write_str("object") }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut pane_id = None;
                let mut expected = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "pane_id" => { if pane_id.is_some() { return Err(serde::de::Error::duplicate_field("pane_id")); } pane_id = Some(map.next_value::<PaneId>()?); }
                        "expected_current_run_id" => { if expected.is_some() { return Err(serde::de::Error::duplicate_field("expected_current_run_id")); } expected = Some(map.next_value::<Nullable<RunId>>()?); }
                        _ => return Err(serde::de::Error::unknown_field(&key, &["pane_id", "expected_current_run_id"])),
                    }
                }
                Ok(PaneCloseParams { pane_id: pane_id.ok_or_else(|| serde::de::Error::missing_field("pane_id"))?, expected_current_run_id: expected })
            }
        }
        deserializer.deserialize_map(Visitor)
    }
}
impl JsonSchema for PaneCloseParams {
    fn schema_name() -> String { "PaneCloseParams".into() }
    fn json_schema(generator: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        PaneCloseShape::json_schema(generator)
    }
}
impl OwnedCapacity for PaneCloseParams {
    fn owned_capacity(&self) -> usize {
        self.pane_id.owned_capacity() + self.expected_current_run_id.as_ref().map_or(0, OwnedCapacity::owned_capacity)
    }
}
impl super::ingress::DecodeOwned for PaneCloseParams {
    fn decode_owned(context: &mut super::ingress::DecodeContext<'_>, raw: super::ingress::RawValue<'_>) -> Result<Self, super::ingress::DecodeFailure> {
        let mut pane_id = None;
        let mut expected = None;
        let mut object = super::ingress::ObjectReader::new(raw)?;
        while let Some((key, value)) = object.next()? {
            if key.equals("pane_id") {
                pane_id = Some(<PaneId as super::ingress::DecodeOwned>::decode_owned(context, value)?);
            } else if key.equals("expected_current_run_id") {
                expected = Some(<Nullable<RunId> as super::ingress::DecodeOwned>::decode_owned(context, value)?);
            } else {
                return Err(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape));
            }
        }
        Ok(Self { pane_id: pane_id.ok_or(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape))?, expected_current_run_id: expected })
    }
}
impl super::ingress::CanonicalValue for PaneCloseParams {
    fn write_canonical(&self, sink: &mut impl super::ingress::Sink) -> Result<(), crate::host::admission::AllocationError> {
        sink.bytes(b"{")?;
        if let Some(expected) = &self.expected_current_run_id {
            sink.bytes(b"\"expected_current_run_id\":")?;
            super::ingress::CanonicalValue::write_canonical(expected, sink)?;
            sink.bytes(b",")?;
        }
        sink.bytes(b"\"pane_id\":")?;
        super::ingress::CanonicalValue::write_canonical(&self.pane_id, sink)?;
        sink.bytes(b"}")
    }
}
#[cfg(test)]
impl super::ingress::TestFixture for PaneCloseParams {
    fn test_fixture() -> Self {
        Self { pane_id: <PaneId as super::ingress::TestFixture>::test_fixture(), expected_current_run_id: None }
    }
}
object!(host_codec PaneResizeParams {
    cols: P,
    pane_id: PaneId,
    rows: P,
    run_id: RunId
});
// The optional guard has presence semantics: omission preserves the legacy
// contract, while a present null requires a pane with no current run.
macro_rules! guarded_launch {
    ($name:ident, $shape:ident, $legacy:ident, $guarded:ident,
     before { $($before:ident : $before_ty:ty),* },
     after { $($after:ident : $after_ty:ty),* }) => {
        object!(host_codec $legacy { $($before: $before_ty,)* $($after: $after_ty,)* });
        object!(host_codec $guarded {
            $($before: $before_ty,)*
            expected_current_run_id: Nullable<RunId>,
            $($after: $after_ty,)*
        });
        #[derive(Debug, Clone, PartialEq)]
        pub struct $name {
            $(pub $before: $before_ty,)*
            pub expected_current_run_id: Option<Nullable<RunId>>,
            $(pub $after: $after_ty,)*
        }
        #[derive(Serialize, Deserialize, JsonSchema)]
        #[serde(untagged)]
        enum $shape { Legacy($legacy), Guarded($guarded) }
        impl Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                use serde::ser::SerializeMap;
                let count = [$(stringify!($before),)* $(stringify!($after),)*].len()
                    + usize::from(self.expected_current_run_id.is_some());
                let mut map = serializer.serialize_map(Some(count))?;
                $(map.serialize_entry(stringify!($before), &self.$before)?;)*
                if let Some(expected) = &self.expected_current_run_id {
                    map.serialize_entry("expected_current_run_id", expected)?;
                }
                $(map.serialize_entry(stringify!($after), &self.$after)?;)*
                map.end()
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                struct Visitor;
                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;
                    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                        formatter.write_str("object")
                    }
                    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                        $(let mut $before = None;)*
                        $(let mut $after = None;)*
                        let mut expected = None;
                        while let Some(key) = map.next_key::<String>()? {
                            match key.as_str() {
                                $(stringify!($before) => {
                                    if $before.is_some() { return Err(serde::de::Error::duplicate_field(stringify!($before))); }
                                    $before = Some(map.next_value::<$before_ty>()?);
                                },)*
                                $(stringify!($after) => {
                                    if $after.is_some() { return Err(serde::de::Error::duplicate_field(stringify!($after))); }
                                    $after = Some(map.next_value::<$after_ty>()?);
                                },)*
                                "expected_current_run_id" => {
                                    if expected.is_some() { return Err(serde::de::Error::duplicate_field("expected_current_run_id")); }
                                    expected = Some(map.next_value::<Nullable<RunId>>()?);
                                }
                                _ => return Err(serde::de::Error::unknown_field(&key, &[
                                    $(stringify!($before),)* "expected_current_run_id", $(stringify!($after),)*
                                ])),
                            }
                        }
                        Ok($name {
                            $($before: $before.ok_or_else(|| serde::de::Error::missing_field(stringify!($before)))?,)*
                            expected_current_run_id: expected,
                            $($after: $after.ok_or_else(|| serde::de::Error::missing_field(stringify!($after)))?,)*
                        })
                    }
                }
                deserializer.deserialize_map(Visitor)
            }
        }
        impl JsonSchema for $name {
            fn schema_name() -> String { stringify!($name).into() }
            fn json_schema(generator: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
                $shape::json_schema(generator)
            }
        }
        impl OwnedCapacity for $name {
            fn owned_capacity(&self) -> usize {
                self.expected_current_run_id.as_ref().map_or(0, OwnedCapacity::owned_capacity)
                    $(.saturating_add(self.$before.owned_capacity()))*
                    $(.saturating_add(self.$after.owned_capacity()))*
            }
        }
        impl super::ingress::DecodeOwned for $name {
            fn decode_owned(context: &mut super::ingress::DecodeContext<'_>, raw: super::ingress::RawValue<'_>) -> Result<Self, super::ingress::DecodeFailure> {
                $(let mut $before = None;)*
                $(let mut $after = None;)*
                let mut expected = None;
                let mut object = super::ingress::ObjectReader::new(raw)?;
                while let Some((key, value)) = object.next()? {
                    match key {
                        $(key if key.equals(stringify!($before)) && $before.is_none() => {
                            $before = Some(<$before_ty as super::ingress::DecodeOwned>::decode_owned(context, value)?);
                        },)*
                        $(key if key.equals(stringify!($after)) && $after.is_none() => {
                            $after = Some(<$after_ty as super::ingress::DecodeOwned>::decode_owned(context, value)?);
                        },)*
                        key if key.equals("expected_current_run_id") && expected.is_none() => {
                            expected = Some(<Nullable<RunId> as super::ingress::DecodeOwned>::decode_owned(context, value)?);
                        }
                        _ => return Err(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape)),
                    }
                }
                Ok(Self {
                    $($before: $before.ok_or(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape))?,)*
                    expected_current_run_id: expected,
                    $($after: $after.ok_or(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape))?,)*
                })
            }
        }
        impl super::ingress::CanonicalValue for $name {
            fn write_canonical(&self, sink: &mut impl super::ingress::Sink) -> Result<(), crate::host::admission::AllocationError> {
                sink.bytes(b"{")?;
                $(super::ingress::json_string(sink, stringify!($before))?;
                  sink.bytes(b":")?;
                  super::ingress::CanonicalValue::write_canonical(&self.$before, sink)?;
                  sink.bytes(b",")?;)*
                if let Some(expected) = &self.expected_current_run_id {
                    sink.bytes(b"\"expected_current_run_id\":")?;
                    super::ingress::CanonicalValue::write_canonical(expected, sink)?;
                    sink.bytes(b",")?;
                }
                let mut first = true;
                $(if !first { sink.bytes(b",")?; }
                  first = false;
                  super::ingress::json_string(sink, stringify!($after))?;
                  sink.bytes(b":")?;
                  super::ingress::CanonicalValue::write_canonical(&self.$after, sink)?;)*
                let _ = first;
                sink.bytes(b"}")
            }
        }
        #[cfg(test)]
        impl super::ingress::TestFixture for $name {
            fn test_fixture() -> Self {
                Self {
                    $($before: <$before_ty as super::ingress::TestFixture>::test_fixture(),)*
                    expected_current_run_id: None,
                    $($after: <$after_ty as super::ingress::TestFixture>::test_fixture(),)*
                }
            }
        }
    }
}
guarded_launch!(
    ShellLaunchParams,
    ShellLaunchShape,
    LegacyShellLaunchParams,
    GuardedShellLaunchParams,
    before {},
    after {
        pane_id: PaneId,
        shell_profile_id: NonEmpty
    }
);
guarded_launch!(AgentLaunchParams, AgentLaunchShape, LegacyAgentLaunchParams, GuardedAgentLaunchParams,
    before { effort: Nullable<NonEmpty> }, after { model: Nullable<NonEmpty>, pane_id: PaneId, provider: Provider });

object!(host_codec InputWriteParams {
    pane_id: PaneId,
    run_id: RunId,
    text: String
});
object!(host_codec InputKeyParams {
    key: InputKey,
    pane_id: PaneId,
    run_id: RunId
});
object!(host_codec RunParams { run_id: RunId });

// The optional extension selects a closed wire shape. Absence preserves the
// legacy caller's bytes; explicit null is never treated as absence.
macro_rules! cleanup_read_shape {
    ($name:ident, $shape:ident, $legacy:ident, $extended:ident,
     $base:ident : $base_ty:ty, $extra:ident : $extra_ty:ty) => {
        object!($legacy { $base: $base_ty });
        object!($extended { $extra: $extra_ty, $base: $base_ty });
        #[derive(Debug, Clone, PartialEq)]
        pub struct $name { pub $base: $base_ty, pub $extra: Option<$extra_ty> }
        #[derive(Serialize, Deserialize, JsonSchema)]
        #[serde(untagged)]
        enum $shape { Legacy($legacy), Extended($extended) }
        impl Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                use serde::ser::SerializeMap;
                let mut map = serializer.serialize_map(Some(1 + usize::from(self.$extra.is_some())))?;
                if let Some(extra) = &self.$extra { map.serialize_entry(stringify!($extra), extra)?; }
                map.serialize_entry(stringify!($base), &self.$base)?;
                map.end()
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                struct Visitor;
                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;
                    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { f.write_str("object") }
                    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                        let mut base = None;
                        let mut extra = None;
                        while let Some(key) = map.next_key::<String>()? {
                            match key.as_str() {
                                stringify!($base) => {
                                    if base.is_some() { return Err(serde::de::Error::duplicate_field(stringify!($base))); }
                                    base = Some(map.next_value::<$base_ty>()?);
                                }
                                stringify!($extra) => {
                                    if extra.is_some() { return Err(serde::de::Error::duplicate_field(stringify!($extra))); }
                                    extra = Some(map.next_value::<$extra_ty>()?);
                                }
                                _ => return Err(serde::de::Error::unknown_field(&key, &[stringify!($base), stringify!($extra)])),
                            }
                        }
                        Ok($name { $base: base.ok_or_else(|| serde::de::Error::missing_field(stringify!($base)))?, $extra: extra })
                    }
                }
                deserializer.deserialize_map(Visitor)
            }
        }
        impl JsonSchema for $name {
            fn schema_name() -> String { stringify!($name).into() }
            fn json_schema(g: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema { $shape::json_schema(g) }
        }
        impl OwnedCapacity for $name {
            // Both extension scalars (literal true and bool) own no allocation.
            fn owned_capacity(&self) -> usize { self.$base.owned_capacity() }
        }
        impl super::ingress::CanonicalValue for $name {
            fn write_canonical(&self, sink: &mut impl super::ingress::Sink) -> Result<(), crate::host::admission::AllocationError> {
                sink.bytes(b"{")?;
                if let Some(extra) = &self.$extra {
                    super::ingress::json_string(sink, stringify!($extra))?;
                    sink.bytes(b":")?;
                    super::ingress::CanonicalValue::write_canonical(extra, sink)?;
                    sink.bytes(b",")?;
                }
                super::ingress::json_string(sink, stringify!($base))?;
                sink.bytes(b":")?;
                super::ingress::CanonicalValue::write_canonical(&self.$base, sink)?;
                sink.bytes(b"}")
            }
        }
        #[cfg(test)]
        impl super::ingress::TestFixture for $name {
            fn test_fixture() -> Self { Self { $base: <$base_ty as super::ingress::TestFixture>::test_fixture(), $extra: None } }
        }
    }
}
cleanup_read_shape!(RunGetParams, RunGetShape, LegacyRunGetParams, CleanupRunGetParams,
    run_id: RunId, include_cleanup: True);
impl super::ingress::DecodeOwned for RunGetParams {
    fn decode_owned(context: &mut super::ingress::DecodeContext<'_>, raw: super::ingress::RawValue<'_>) -> Result<Self, super::ingress::DecodeFailure> {
        let mut run_id = None;
        let mut include_cleanup = None;
        let mut object = super::ingress::ObjectReader::new(raw)?;
        while let Some((key, value)) = object.next()? {
            if key.equals("run_id") && run_id.is_none() {
                run_id = Some(<RunId as super::ingress::DecodeOwned>::decode_owned(context, value)?);
            } else if key.equals("include_cleanup") && include_cleanup.is_none() {
                include_cleanup = Some(<True as super::ingress::DecodeOwned>::decode_owned(context, value)?);
            } else { return Err(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape)); }
        }
        Ok(Self { run_id: run_id.ok_or(super::ingress::DecodeFailure::Contract(ContractError::InvalidShape))?, include_cleanup })
    }
}
object!(host_codec OperationParams {
    operation_id: OperationId
});
object!(host_codec OutputReadParams { cursor:Nullable<NonEmpty>, max_bytes:P, run_id:RunId });
object!(host_codec EventsWaitParams {
    after_event_seq: U,
    wait_ms: U
});
object!(host_codec ArtifactRegisterParams { project_id:ProjectId, relative_path:RelativePath, run_id:Nullable<RunId> });
object!(host_codec ArtifactReadParams {
    artifact_id: ArtifactId,
    max_bytes: P
});
object!(host_codec ArtifactChooseParams {
    project_id: ProjectId,
    left_artifact_id: ArtifactId,
    right_artifact_id: ArtifactId,
    kept_artifact_id: ArtifactId
});

impl Action {
    pub(crate) fn normalize_extension(&mut self) {
        if let Self::ArtifactChoose(params) = self {
            if params.left_artifact_id > params.right_artifact_id {
                std::mem::swap(&mut params.left_artifact_id, &mut params.right_artifact_id);
            }
        }
    }
}

/// Literal true, rather than a boolean whose false value could imply success.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "bool", into = "bool")]
pub struct True;
impl TryFrom<bool> for True {
    type Error = &'static str;
    fn try_from(v: bool) -> Result<Self, Self::Error> {
        if v {
            Ok(Self)
        } else {
            Err("__scalar")
        }
    }
}
impl From<True> for bool {
    fn from(_: True) -> bool {
        true
    }
}
impl OwnedCapacity for True {
    fn owned_capacity(&self) -> usize {
        0
    }
}
impl crate::contract::ingress::CanonicalValue for True {
    fn write_canonical(
        &self,
        sink: &mut impl crate::contract::ingress::Sink,
    ) -> Result<(), crate::host::admission::AllocationError> {
        sink.bytes(b"true")
    }
}
#[cfg(test)]
impl crate::contract::ingress::TestFixture for True {
    fn test_fixture() -> Self {
        Self
    }
}
impl JsonSchema for True {
    fn schema_name() -> String {
        "True".into()
    }
    fn json_schema(_: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
        serde_json::from_value(serde_json::json!({"type":"boolean","const":true})).unwrap()
    }
}
object!(ReplayCapacity { retained_bytes:P, active_bytes:P });
object!(CapabilitiesData { schema_version:Version, operations:StringSet<OperationName>, max_message_bytes:MessageLimit, providers:Nullable<Vec<ProviderCapability>>, replay_capacity:ReplayCapacity, shell_profile_ids:Nullable<StringSet<NonEmpty>> });
object!(ConnectionRequestData {
    connection_id: ConnectionId,
    state: PendingState
});
object!(ConnectionListData { connections:Vec<ConnectionInfo> });
object!(ConnectionDecideData { connection_id:ConnectionId, state:DecidedState, project_ids:StringSet<ProjectId>, scopes:StringSet<Scope> });
object!(ConnectionRevokeData {
    connection_id: ConnectionId,
    state: RevokedState
});
object!(HostStopData {
    stopped: True,
    saved_generation: U,
    saved_topology_revision: U
});
object!(ProjectListData { projects:Vec<ProjectSummary>, selected_project_id:Nullable<ProjectId> });
object!(ProjectOpenData {
    project_id: ProjectId,
    created: bool
});
object!(ProjectSelectData { selected_project_id:Nullable<ProjectId>, selected_pane_id:() });
object!(ProjectForgetData {
    project_id: ProjectId,
    removed: True
});
object!(PaneListData { project_id:ProjectId, panes:Vec<PaneSummary>, root:Nullable<LayoutNode>, selected_pane_id:Nullable<PaneId> });
object!(PaneCreatedData {
    pane_id: PaneId,
    run_id: RunId
});
object!(PaneCloseData { pane_id:PaneId, closed:True, selected_pane_id:Nullable<PaneId> });
object!(LaunchData {
    pane_id: PaneId,
    run_id: RunId,
    phase: AcceptedPhase
});
object!(InputWriteData {
    pane_id: PaneId,
    run_id: RunId,
    input_seq: P,
    written_bytes: U
});
object!(InputKeyData {
    pane_id: PaneId,
    run_id: RunId,
    input_seq: P,
    key: InputKey,
    sent: True,
    written_bytes: OneByte
});
cleanup_read_shape!(RunGetData, RunGetDataShape, LegacyRunGetData, CleanupRunGetData,
    run: RunObservation, cleanup_complete: bool);
object!(RunInterruptData {
    run_id: RunId,
    phase: AcceptedPhase
});
object!(OperationGetData {
    operation: OperationStatus
});
object!(OutputReadData {
    run_id: RunId,
    text: String,
    next_cursor: NonEmpty,
    gap: bool,
    truncated: bool
});
object!(EventsWaitData { status:WaitStatus, events:Vec<MetadataEvent>, next_event_seq:U });
object!(LayoutSaveData {
    generation: U,
    saved_topology_revision: U
});
object!(LayoutRestoreData {
    restored: True,
    generation: U
});
object!(ArtifactRegisterData {
    artifact: ArtifactRef
});
enumeration!(GitCandidatesError { ResourceExhausted=>"resource_exhausted", UnsupportedFile=>"unsupported_file" });
object!(ArtifactListData { registered:Vec<ArtifactRef>, git_candidates:StringSet<RelativePath>, git_candidates_error:Nullable<GitCandidatesError> });
object!(ArtifactReadData { artifact_id:ArtifactId, kind:FileKind, size_bytes:U, text:Nullable<String>, truncated:bool });
object!(ArtifactDiffData { artifact_id:ArtifactId, kind:FileKind, text:Nullable<String>, truncated:bool });
object!(ArtifactChoiceData { left_artifact_id:ArtifactId, right_artifact_id:ArtifactId, kept_artifact_id:ArtifactId });
object!(ArtifactChoiceListData { choices:Vec<ArtifactChoiceData> });
object!(DiagnosticsData { product_version:ProductVersion, protocol_version:Version, capabilities:StringSet<OperationName>, connection_state:ConnectionState, failure_codes:StringSet<ErrorCode> });

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub schema_version: Version,
    pub instance_id: Nullable<InstanceId>,
    pub operation_id: OperationId,
    pub expected_topology_revision: Nullable<U>,
    #[serde(flatten)]
    pub action: Action,
}
impl OwnedCapacity for Request {
    fn owned_capacity(&self) -> usize {
        self.instance_id
            .owned_capacity()
            .saturating_add(self.operation_id.owned_capacity())
            .saturating_add(self.action.owned_capacity())
    }
}
object!(Response { schema_version:Version, instance_id:InstanceId, operation_id:OperationId, accepted:bool, topology_revision:U, event_seq:U, result:Nullable<Success>, error:Nullable<WireError> });


#[cfg(test)]
mod launch_guard_codec_tests {
    use super::*;
    use crate::contract::ingress::prepare_request;
    use crate::host::admission::{AllocationAuthority, AllocationPool, OwnedFrame};
    use serde_json::{json, Value};

    #[test]
    fn launch_guard_owned_codec_matches_public_shapes_and_canonical_bytes() {
        let run = "50000000-0000-4000-8000-000000000000";
        let pane = "40000000-0000-4000-8000-000000000000";
        for (operation, params) in [
            (
                "shell.launch",
                json!({"pane_id":pane,"shell_profile_id":"pwsh"}),
            ),
            (
                "agent.launch",
                json!({"pane_id":pane,"provider":"codex","model":null,"effort":null}),
            ),
            (
                "agent.launch",
                json!({"pane_id":pane,"provider":"claude","model":"test-model","effort":"test-effort"}),
            ),
        ] {
            let envelope = |params: Value| {
                json!({"schema_version":1,
                "instance_id":"10000000-0000-4000-8000-000000000000",
                "operation_id":"20000000-0000-4000-8000-000000000000",
                "expected_topology_revision":null,"operation":operation,"params":params})
            };
            let mut forms = Vec::new();
            for expected in [None, Some(Value::Null), Some(json!(run))] {
                let mut p = params.clone();
                if let Some(expected) = expected {
                    p["expected_current_run_id"] = expected;
                }
                let bytes = serde_json::to_vec(&envelope(p.clone())).unwrap();
                let parsed = parse_request(&bytes).unwrap();
                let canonical = canonical_request(&parsed).unwrap();
                let authority = AllocationAuthority::host();
                let mut frame =
                    OwnedFrame::allocate(&authority, AllocationPool::ActivePublic, bytes.len())
                        .unwrap();
                frame.copy_from_slice(&bytes);
                let prepared =
                    prepare_request(frame, &authority, AllocationPool::ActivePublic).unwrap();
                assert_eq!(prepared.request(), &parsed);
                assert_eq!(prepared.canonical(), canonical);
                assert_eq!(parse_request(prepared.canonical()).unwrap(), parsed);
                assert_eq!(serde_json::to_value(&parsed).unwrap()["params"], p);
                assert_eq!(
                    serde_json::from_slice::<Value>(&canonical).unwrap()["params"],
                    p
                );
                assert!(!forms.contains(&canonical));
                forms.push(canonical);
                drop(prepared);
                assert_eq!(authority.snapshot().active_public, 0);
            }
            let mut negatives = Vec::new();
            for expected in [
                json!(false),
                json!(0),
                json!([]),
                json!({}),
                json!("invalid"),
                json!("50000000-0000-1000-8000-000000000000"),
                json!("50000000-0000-4000-7000-000000000000"),
            ] {
                let mut p = params.clone();
                p["expected_current_run_id"] = expected;
                negatives.push(p);
            }
            for field in params.as_object().unwrap().keys() {
                let mut p = params.clone();
                p.as_object_mut().unwrap().remove(field);
                negatives.push(p);
            }
            let mut p = params.clone();
            p["unknown"] = json!(true);
            negatives.push(p);
            for p in negatives {
                let bytes = serde_json::to_vec(&envelope(p)).unwrap();
                assert!(parse_request(&bytes).is_err());
                let authority = AllocationAuthority::host();
                let mut frame =
                    OwnedFrame::allocate(&authority, AllocationPool::ActivePublic, bytes.len())
                        .unwrap();
                frame.copy_from_slice(&bytes);
                assert!(prepare_request(frame, &authority, AllocationPool::ActivePublic).is_err());
                assert_eq!(authority.snapshot().active_public, 0);
            }
            for (field, value) in params
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.as_str(), v.clone()))
                .chain([("expected_current_run_id", Value::Null)])
            {
                let mut p = params.clone();
                p["expected_current_run_id"] = Value::Null;
                let mut bytes = serde_json::to_string(&envelope(p)).unwrap();
                let position = bytes.find("\"params\":{").unwrap() + "\"params\":{".len();
                bytes.insert_str(
                    position,
                    &format!("{}:{},", serde_json::to_string(field).unwrap(), value),
                );
                assert!(
                    parse_request(bytes.as_bytes()).is_err(),
                    "duplicate {field}"
                );
                let authority = AllocationAuthority::host();
                let mut frame =
                    OwnedFrame::allocate(&authority, AllocationPool::ActivePublic, bytes.len())
                        .unwrap();
                frame.copy_from_slice(bytes.as_bytes());
                assert!(
                    prepare_request(frame, &authority, AllocationPool::ActivePublic).is_err(),
                    "owned duplicate {field}"
                );
                assert_eq!(authority.snapshot().active_public, 0);
            }
        }
    }
}
