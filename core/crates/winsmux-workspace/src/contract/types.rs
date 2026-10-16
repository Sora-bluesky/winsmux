use super::ingress::CanonicalValue;
use super::*;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;

macro_rules! enumeration {
    ($name:ident { $($variant:ident => $wire:literal),+ $(,)? }) => {
        #[derive(Debug,Clone,Copy,PartialEq,Eq,PartialOrd,Ord,Hash,Serialize,Deserialize,JsonSchema)]
        pub enum $name { $(#[serde(rename=$wire)] $variant),+ }
        impl $name {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];
            pub(crate) fn wire(self) -> &'static str {
                match self { $(Self::$variant => $wire),+ }
            }
        }
        impl OwnedCapacity for $name { fn owned_capacity(&self)->usize { 0 } }
        impl $crate::contract::ingress::DecodeOwned for $name {
            fn decode_owned(
                _context: &mut $crate::contract::ingress::DecodeContext<'_>,
                raw: $crate::contract::ingress::RawValue<'_>,
            ) -> Result<Self, $crate::contract::ingress::DecodeFailure> {
                $(if raw.equals($wire) { return Ok(Self::$variant); })+
                Err($crate::contract::ingress::DecodeFailure::Contract(ContractError::InvalidShape))
            }
        }
        impl $crate::contract::ingress::WireText for $name {
            fn wire_text(&self) -> &str { self.wire() }
        }
        impl $crate::contract::ingress::CanonicalValue for $name {
            fn write_canonical(
                &self,
                sink: &mut impl $crate::contract::ingress::Sink,
            ) -> Result<(), $crate::host::admission::AllocationError> {
                $crate::contract::ingress::json_string(sink, self.wire())
            }
        }
        #[cfg(test)]
        impl $crate::contract::ingress::TestFixture for $name {
            fn test_fixture() -> Self { Self::ALL[0] }
        }
    }
}
pub(crate) use enumeration;
enumeration!(Provider { Codex=>"codex", Claude=>"claude" });
enumeration!(Scope { Metadata=>"metadata", ReadOutput=>"read_output", Control=>"control" });
enumeration!(Axis { Horizontal=>"horizontal", Vertical=>"vertical" });
enumeration!(InputKey { Enter=>"enter", Interrupt=>"interrupt", Tab=>"tab", Escape=>"escape" });
enumeration!(ConnectionState { Unpaired=>"unpaired", Pending=>"pending", Granted=>"granted", Revoked=>"revoked" });
enumeration!(Process { Starting=>"starting", Running=>"running", Exited=>"exited", Unknown=>"unknown" });
enumeration!(Work { Unknown=>"unknown", Running=>"running", AwaitingInput=>"awaiting_input", Succeeded=>"succeeded", Failed=>"failed", Interrupted=>"interrupted" });
enumeration!(Evidence { ProcessExit=>"process_exit", ProviderEvent=>"provider_event", Unavailable=>"unavailable" });
enumeration!(OperationPhase { Accepted=>"accepted", InProgress=>"in_progress", Completed=>"completed", Unknown=>"unknown" });
enumeration!(RootState { Verified=>"verified", Unavailable=>"unavailable", Changed=>"changed", Unknown=>"unknown" });
enumeration!(LiveConnectionState {
    Authenticating=>"authenticating",
    Unpaired=>"unpaired",
    Pending=>"pending",
    Granted=>"granted",
    Closing=>"closing",
    Finished=>"finished"
});
enumeration!(Decision { Allow=>"allow", Deny=>"deny" });
enumeration!(DecidedState { Granted=>"granted", Revoked=>"revoked" });
enumeration!(PendingState { Pending=>"pending" });
enumeration!(RevokedState { Revoked=>"revoked" });
enumeration!(AcceptedPhase { Accepted=>"accepted" });
enumeration!(Outcome { Succeeded=>"succeeded", Failed=>"failed" });
enumeration!(Association { CallerSelected=>"caller_selected" });
enumeration!(WaitStatus { Events=>"events", NoChange=>"no_change", Gap=>"gap" });
enumeration!(FileKind { Text=>"text", Binary=>"binary" });
enumeration!(ProductVersion { V0380=>"0.38.0" });

macro_rules! object {
    (host_codec $name:ident { $($field:ident : $ty:ty),* $(,)? }) => {
        object!($name { $($field:$ty),* });
        impl $crate::contract::ingress::DecodeOwned for $name {
            #[allow(unused_variables)]
            fn decode_owned(
                context: &mut $crate::contract::ingress::DecodeContext<'_>,
                raw: $crate::contract::ingress::RawValue<'_>,
            ) -> Result<Self, $crate::contract::ingress::DecodeFailure> {
                $(let mut $field: Option<$ty> = None;)*
                let mut object = $crate::contract::ingress::ObjectReader::new(raw)?;
                while let Some((key, value)) = object.next()? {
                    match key {
                        $(key if key.equals(stringify!($field)) => {
                            $field = Some(<$ty as $crate::contract::ingress::DecodeOwned>::decode_owned(context, value)?);
                        })*
                        _ => return Err($crate::contract::ingress::DecodeFailure::Contract(ContractError::InvalidShape)),
                    }
                }
                Ok(Self {
                    $($field: $field.ok_or($crate::contract::ingress::DecodeFailure::Contract(ContractError::InvalidShape))?,)*
                })
            }
        }
    };
    ($name:ident { $($field:ident : $ty:ty),* $(,)? }) => {
        #[derive(Debug,Clone,PartialEq,Serialize,JsonSchema)]
        #[serde(deny_unknown_fields)]
        pub struct $name { $(pub $field: $ty),* }
        impl OwnedCapacity for $name {
            fn owned_capacity(&self)->usize {
                0usize $(.saturating_add(self.$field.owned_capacity()))*
            }
        }
        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D:serde::Deserializer<'de>>(d:D)->Result<Self,D::Error> {
                #[derive(serde::Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Fields {$($field:$ty),*}
                struct ObjectVisitor;
                impl<'de> serde::de::Visitor<'de> for ObjectVisitor {
                    type Value=$name;
                    fn expecting(&self,f:&mut std::fmt::Formatter)->std::fmt::Result {f.write_str("object")}
                    fn visit_map<A:serde::de::MapAccess<'de>>(self,map:A)->Result<Self::Value,A::Error> {
                        let fields=Fields::deserialize(serde::de::value::MapAccessDeserializer::new(map))?;
                        let Fields{$($field),*}=fields;
                        Ok($name{$($field),*})
                    }
                }
                d.deserialize_map(ObjectVisitor)
            }
        }
        impl $crate::contract::ingress::CanonicalValue for $name {
            fn write_canonical(
                &self,
                sink: &mut impl $crate::contract::ingress::Sink,
            ) -> Result<(), $crate::host::admission::AllocationError> {
                const FIELDS: &[&str] = &[$(stringify!($field)),*];
                sink.bytes(b"{")?;
                let mut previous: Option<&str> = None;
                for index in 0..FIELDS.len() {
                    let current = FIELDS
                        .iter()
                        .copied()
                        .filter(|field| previous.is_none_or(|previous| *field > previous))
                        .min()
                        .ok_or($crate::host::admission::AllocationError::Allocator)?;
                    if index != 0 {
                        sink.bytes(b",")?;
                    }
                    $crate::contract::ingress::json_string(sink, current)?;
                    sink.bytes(b":")?;
                    #[allow(unused_mut)]
                    let mut wrote = false;
                    $(
                        if current == stringify!($field) {
                            <$ty as $crate::contract::ingress::CanonicalValue>::write_canonical(&self.$field, sink)?;
                            wrote = true;
                        }
                    )*
                    if !wrote {
                        return Err($crate::host::admission::AllocationError::Allocator);
                    }
                    previous = Some(current);
                }
                sink.bytes(b"}")
            }
        }
        #[cfg(test)]
        impl $crate::contract::ingress::TestFixture for $name {
            fn test_fixture() -> Self {
                Self {
                    $($field: <$ty as $crate::contract::ingress::TestFixture>::test_fixture(),)*
                }
            }
        }
    }
}
pub(crate) use object;
object!(host_codec Empty {});
object!(ProviderProfile { provider:Provider, model:Nullable<NonEmpty>, effort:Nullable<NonEmpty> });
object!(ProviderCapability {
    provider: Provider,
    version: NonEmpty
});
object!(RootIdentity {
    volume_serial: Hex16,
    file_id: Hex32
});
object!(Selection { selected_project_id:Nullable<ProjectId>, selected_pane_id:Nullable<PaneId> });
object!(RunObservation { run_id:RunId, pane_id:PaneId, process:Process, work:Work, evidence:Evidence, observed_at:Timestamp, current:bool, exit_code:Nullable<ExitCode> });
object!(ProjectSummary { project_id:ProjectId, root_state:RootState, display_name:Nullable<String>, path:Nullable<String> });
object!(PaneSummary { pane_id:PaneId, project_id:ProjectId, current_run_id:Nullable<RunId>, observation:Nullable<RunObservation>, display_name:Nullable<String>, path:Nullable<String> });
object!(ConnectionInfo { connection_id:ConnectionId, executable_name:Nullable<NonEmpty>, requested_project_ids:StringSet<ProjectId>, requested_scopes:StringSet<Scope>, granted_project_ids:StringSet<ProjectId>, granted_scopes:StringSet<Scope>, state:LiveConnectionState });
object!(OperationStatus { operation_id:OperationId, phase:OperationPhase, outcome:Nullable<Outcome>, error_code:Nullable<ErrorCode> });
object!(ArtifactRef { artifact_id:ArtifactId, project_id:ProjectId, relative_path:RelativePath, run_id:Nullable<RunId>, association:Nullable<Association> });

macro_rules! error_codes {
    ($($variant:ident => ($wire:literal,$retry:literal,$message:literal)),+ $(,)?) => {
        enumeration!(ErrorCode { $($variant=>$wire),+ });
        impl ErrorCode {
            pub fn retryable(self)->bool { match self {$(Self::$variant=>$retry),+} }
            pub fn message(self)->&'static str { match self {$(Self::$variant=>$message),+} }
            /// UnsupportedVersion is reserved; v1 adapters must not synthesize a response to a parse failure.
            pub fn is_reserved(self)->bool { self==Self::UnsupportedVersion }
            pub fn allows_target(self)->bool { !matches!(self,Self::InvalidRequest|Self::UnsupportedVersion|Self::ResourceExhausted) }
            pub fn with_target(self,target:Option<TargetId>)->Result<WireError,ContractError> {
                if target.is_some() && !self.allows_target() { return Err(ContractError::InvariantViolation); }
                Ok(WireError{code:self,retryable:self.retryable(),message:Cow::Borrowed(self.message()),target_id:Nullable(target)})
            }
        }
    }
}
error_codes! {
 InvalidRequest=>("invalid_request",false,"Invalid request."),
 UnsupportedVersion=>("unsupported_version",false,"Unsupported protocol version."),
 PermissionDenied=>("permission_denied",false,"Permission denied."),
 TargetNotFound=>("target_not_found",false,"Target not found."),
 StaleTopology=>("stale_topology",true,"Topology changed."),
 OperationConflict=>("operation_conflict",false,"Operation identifier conflict."),
 InProgress=>("in_progress",true,"Operation is in progress."),
 NotRunning=>("not_running",false,"Run is not running."),
 AlreadyRunning=>("already_running",false,"Run is already running."),
 UnsupportedCapability=>("unsupported_capability",false,"Capability is unavailable."),
 OutputGap=>("output_gap",false,"Output history is incomplete."),
 PersistenceFailed=>("persistence_failed",false,"Persistence failed."),
 RuntimeFailed=>("runtime_failed",true,"Runtime operation failed."),
 StateUnknown=>("state_unknown",false,"Operation state is unknown."),
 ResourceExhausted=>("resource_exhausted",false,"Resource limit reached."),
 RootChanged=>("root_changed",false,"Root identity changed."),
 UnsupportedFile=>("unsupported_file",false,"File type is unsupported."),
 NotARepository=>("not_a_repository",false,"Git repository is unavailable."),
}
#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WireError {
    pub(crate) code: ErrorCode,
    pub(crate) retryable: bool,
    pub(crate) message: Cow<'static, str>,
    pub(crate) target_id: Nullable<TargetId>,
}
impl<'de> Deserialize<'de> for WireError {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Fields {
            code: ErrorCode,
            retryable: bool,
            message: String,
            target_id: Nullable<TargetId>,
        }
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = WireError;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("object")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<Self::Value, A::Error> {
                let f = Fields::deserialize(serde::de::value::MapAccessDeserializer::new(map))?;
                Ok(WireError {
                    code: f.code,
                    retryable: f.retryable,
                    message: Cow::Owned(f.message),
                    target_id: f.target_id,
                })
            }
        }
        d.deserialize_map(V)
    }
}
impl WireError {
    pub fn code(&self) -> ErrorCode {
        self.code
    }
    pub fn retryable(&self) -> bool {
        self.retryable
    }
    pub fn message(&self) -> &str {
        self.message.as_ref()
    }
    pub fn target_id(&self) -> Option<&TargetId> {
        self.target_id.0.as_ref()
    }
}
impl OwnedCapacity for WireError {
    fn owned_capacity(&self) -> usize {
        let message = match &self.message {
            Cow::Borrowed(_) => 0,
            Cow::Owned(message) => message.owned_capacity(),
        };
        message.saturating_add(self.target_id.owned_capacity())
    }
}
impl crate::contract::ingress::CanonicalValue for WireError {
    fn write_canonical(
        &self,
        sink: &mut impl crate::contract::ingress::Sink,
    ) -> Result<(), crate::host::admission::AllocationError> {
        sink.bytes(b"{\"code\":")?;
        self.code.write_canonical(sink)?;
        sink.bytes(b",\"message\":")?;
        crate::contract::ingress::json_string(sink, self.message.as_ref())?;
        sink.bytes(b",\"retryable\":")?;
        self.retryable.write_canonical(sink)?;
        sink.bytes(b",\"target_id\":")?;
        self.target_id.write_canonical(sink)?;
        sink.bytes(b"}")
    }
}
#[cfg(test)]
impl crate::contract::ingress::TestFixture for WireError {
    fn test_fixture() -> Self {
        ErrorCode::InvalidRequest
            .with_target(None)
            .expect("fixture error")
    }
}
object!(MetadataEvent {
    event_seq: U,
    observed_at: Timestamp,
    data: EventData
});
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum EventData {
    TopologyChanged {
        topology_revision: U,
        project_id: Nullable<ProjectId>,
        pane_id: Nullable<PaneId>,
    },
    RunStateChanged {
        run: RunObservation,
    },
    OperationStateChanged {
        operation: OperationStatus,
    },
    ConnectionStateChanged {
        connection_id: ConnectionId,
        state: ConnectionState,
    },
}
impl OwnedCapacity for EventData {
    fn owned_capacity(&self) -> usize {
        match self {
            Self::TopologyChanged {
                project_id,
                pane_id,
                ..
            } => project_id
                .owned_capacity()
                .saturating_add(pane_id.owned_capacity()),
            Self::RunStateChanged { run } => run.owned_capacity(),
            Self::OperationStateChanged { operation } => operation.owned_capacity(),
            Self::ConnectionStateChanged { connection_id, .. } => connection_id.owned_capacity(),
        }
    }
}
impl crate::contract::ingress::CanonicalValue for EventData {
    fn write_canonical(
        &self,
        sink: &mut impl crate::contract::ingress::Sink,
    ) -> Result<(), crate::host::admission::AllocationError> {
        match self {
            Self::TopologyChanged {
                topology_revision,
                project_id,
                pane_id,
            } => {
                sink.bytes(b"{\"kind\":\"topology_changed\",\"pane_id\":")?;
                pane_id.write_canonical(sink)?;
                sink.bytes(b",\"project_id\":")?;
                project_id.write_canonical(sink)?;
                sink.bytes(b",\"topology_revision\":")?;
                topology_revision.write_canonical(sink)?;
                sink.bytes(b"}")
            }
            Self::RunStateChanged { run } => {
                sink.bytes(b"{\"kind\":\"run_state_changed\",\"run\":")?;
                run.write_canonical(sink)?;
                sink.bytes(b"}")
            }
            Self::OperationStateChanged { operation } => {
                sink.bytes(b"{\"kind\":\"operation_state_changed\",\"operation\":")?;
                operation.write_canonical(sink)?;
                sink.bytes(b"}")
            }
            Self::ConnectionStateChanged {
                connection_id,
                state,
            } => {
                sink.bytes(b"{\"connection_id\":")?;
                connection_id.write_canonical(sink)?;
                sink.bytes(b",\"kind\":\"connection_state_changed\",\"state\":")?;
                state.write_canonical(sink)?;
                sink.bytes(b"}")
            }
        }
    }
}
#[cfg(test)]
impl crate::contract::ingress::TestFixture for EventData {
    fn test_fixture() -> Self {
        Self::TopologyChanged {
            topology_revision: crate::contract::ingress::TestFixture::test_fixture(),
            project_id: crate::contract::ingress::TestFixture::test_fixture(),
            pane_id: crate::contract::ingress::TestFixture::test_fixture(),
        }
    }
}

// Recursive storage is private. Drop detaches children iteratively, including
// malformed trees manufactured by module tests, so rejection cannot overflow a stack.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(transparent)]
pub struct LayoutNode {
    pub(crate) node: Box<Node>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Node {
    Leaf {
        pane_id: PaneId,
    },
    Split {
        axis: Axis,
        ratio: Ratio,
        first: LayoutNode,
        second: LayoutNode,
    },
}
impl OwnedCapacity for LayoutNode {
    fn owned_capacity(&self) -> usize {
        self.node.owned_capacity()
    }
}
impl OwnedCapacity for Node {
    fn owned_capacity(&self) -> usize {
        match self {
            Self::Leaf { pane_id } => pane_id.owned_capacity(),
            Self::Split { first, second, .. } => first
                .owned_capacity()
                .saturating_add(second.owned_capacity()),
        }
    }
}
impl CanonicalValue for LayoutNode {
    fn write_canonical(
        &self,
        sink: &mut impl crate::contract::ingress::Sink,
    ) -> Result<(), crate::host::admission::AllocationError> {
        self.node.write_canonical(sink)
    }
}
impl CanonicalValue for Node {
    fn write_canonical(
        &self,
        sink: &mut impl crate::contract::ingress::Sink,
    ) -> Result<(), crate::host::admission::AllocationError> {
        match self {
            Self::Leaf { pane_id } => {
                sink.bytes(b"{\"kind\":\"leaf\",\"pane_id\":")?;
                pane_id.write_canonical(sink)?;
                sink.bytes(b"}")
            }
            Self::Split {
                axis,
                ratio,
                first,
                second,
            } => {
                sink.bytes(b"{\"axis\":")?;
                axis.write_canonical(sink)?;
                sink.bytes(b",\"first\":")?;
                first.write_canonical(sink)?;
                sink.bytes(b",\"kind\":\"split\",\"ratio\":")?;
                ratio.write_canonical(sink)?;
                sink.bytes(b",\"second\":")?;
                second.write_canonical(sink)?;
                sink.bytes(b"}")
            }
        }
    }
}
#[cfg(test)]
impl crate::contract::ingress::TestFixture for LayoutNode {
    fn test_fixture() -> Self {
        Self::leaf(crate::contract::ingress::TestFixture::test_fixture())
    }
}
impl LayoutNode {
    pub fn leaf(pane_id: PaneId) -> Self {
        Self {
            node: Box::new(Node::Leaf { pane_id }),
        }
    }
    pub fn split(
        axis: Axis,
        ratio: Ratio,
        first: Self,
        second: Self,
    ) -> Result<Self, ContractError> {
        let result = Self {
            node: Box::new(Node::Split {
                axis,
                ratio,
                first,
                second,
            }),
        };
        result.check_depth(1)?;
        Ok(result)
    }
    pub(crate) fn check_depth(&self, start: usize) -> Result<(), ContractError> {
        self.leaf_counts(start, None).map(|_| ())
    }
    pub(crate) fn leaf_counts(
        &self,
        start: usize,
        target: Option<&PaneId>,
    ) -> Result<(usize, usize), ContractError> {
        let mut stack: [Option<(&LayoutNode, usize)>; super::JSON_DEPTH + 1] =
            [None; super::JSON_DEPTH + 1];
        let mut stack_len = 1usize;
        stack[0] = Some((self, start));
        let mut leaves = 0usize;
        let mut matches = 0usize;
        while stack_len != 0 {
            stack_len -= 1;
            let (n, d) = stack[stack_len].take().ok_or(ContractError::NestingLimit)?;
            if d > super::JSON_DEPTH {
                return Err(ContractError::NestingLimit);
            }
            match &*n.node {
                Node::Leaf { pane_id } => {
                    leaves = leaves.checked_add(1).ok_or(ContractError::NestingLimit)?;
                    if target.is_some_and(|target| target == pane_id) {
                        matches = matches.checked_add(1).ok_or(ContractError::NestingLimit)?;
                    }
                }
                Node::Split { first, second, .. } => {
                    if stack_len + 2 > stack.len() {
                        return Err(ContractError::NestingLimit);
                    }
                    stack[stack_len] = Some((second, d + 1));
                    stack[stack_len + 1] = Some((first, d + 1));
                    stack_len += 2;
                }
            }
        }
        Ok((leaves, matches))
    }
}
impl Drop for LayoutNode {
    fn drop(&mut self) {
        // Replace with a nonrecursive leaf; the original ID is irrelevant and stays private.
        fn detach(n: &mut LayoutNode) -> Option<(LayoutNode, LayoutNode)> {
            if matches!(*n.node, Node::Leaf { .. }) {
                return None;
            }
            let replacement = Node::Leaf {
                pane_id: PaneId::new("00000000-0000-4000-8000-000000000000").unwrap(),
            };
            match std::mem::replace(&mut *n.node, replacement) {
                Node::Split { first, second, .. } => Some((first, second)),
                Node::Leaf { .. } => None,
            }
        }
        let mut stack = Vec::new();
        if let Some((a, b)) = detach(self) {
            stack.push(a);
            stack.push(b);
        }
        while let Some(mut n) = stack.pop() {
            if let Some((a, b)) = detach(&mut n) {
                stack.push(a);
                stack.push(b);
            }
        }
    }
}
object!(SavedProject {
    project_id: ProjectId,
    path: NonEmpty,
    display_name: String,
    root_identity: RootIdentity
});
object!(SavedPane { pane_id:PaneId, project_id:ProjectId, shell_profile_id:NonEmpty, provider_profile:Nullable<ProviderProfile> });
object!(SavedLayout { project_id:ProjectId, root:Nullable<LayoutNode> });
object!(Snapshot { schema_version:Version, generation:U, topology_revision:U, projects:Vec<SavedProject>, panes:Vec<SavedPane>, layouts:Vec<SavedLayout>, selected_project_id:Nullable<ProjectId>, selected_pane_id:Nullable<PaneId> });

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn private_deep_layout_drop() {
        if std::env::var_os("WINSMUX_PRIVATE_LAYOUT_CHILD").is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "contract::types::tests::private_deep_layout_drop",
                    "--nocapture",
                ])
                .env("WINSMUX_PRIVATE_LAYOUT_CHILD", "1")
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }
        let pane = PaneId::new("40000000-0000-4000-8000-000000000000").unwrap();
        let project = ProjectId::new("30000000-0000-4000-8000-000000000000").unwrap();
        let mut node = LayoutNode::leaf(pane.clone());
        for _ in 0..10_000 {
            node = LayoutNode {
                node: Box::new(Node::Split {
                    axis: Axis::Vertical,
                    ratio: Ratio::new(0.5).unwrap(),
                    first: node,
                    second: LayoutNode::leaf(pane.clone()),
                }),
            };
        }
        let snapshot = Snapshot {
            schema_version: Version::new(1).unwrap(),
            generation: U::new(0).unwrap(),
            topology_revision: U::new(0).unwrap(),
            projects: vec![SavedProject {
                project_id: project.clone(),
                path: NonEmpty::new("C:/workspace").unwrap(),
                display_name: String::new(),
                root_identity: RootIdentity {
                    volume_serial: Hex16::new("0000000000000000").unwrap(),
                    file_id: Hex32::new("00000000000000000000000000000000").unwrap(),
                },
            }],
            panes: vec![SavedPane {
                pane_id: pane,
                project_id: project.clone(),
                shell_profile_id: NonEmpty::new("pwsh").unwrap(),
                provider_profile: Nullable(None),
            }],
            layouts: vec![SavedLayout {
                project_id: project,
                root: Nullable(Some(node)),
            }],
            selected_project_id: Nullable(None),
            selected_pane_id: Nullable(None),
        };
        assert_eq!(
            serialize_snapshot(&snapshot),
            Err(ContractError::NestingLimit)
        );
        drop(snapshot);
    }
}
