use crate::contract::{OperationClass, OperationName};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LedgerClass {
    CurrentObservation,
    RetainedEffect,
    Unsupported,
}

pub fn ledger_class(operation: OperationName) -> LedgerClass {
    match operation {
        OperationName::CapabilitiesGet
        | OperationName::ProjectList
        | OperationName::ConnectionList
        | OperationName::DiagnosticsGet => LedgerClass::CurrentObservation,
        OperationName::PaneList
        | OperationName::RunGet
        | OperationName::OutputRead
        | OperationName::EventsWait
        | OperationName::OperationGet => {
            LedgerClass::CurrentObservation
        }
        OperationName::ConnectionRequest
        | OperationName::ConnectionDecide
        | OperationName::ConnectionRevoke
        | OperationName::ProjectOpen
        | OperationName::ProjectSelect
        | OperationName::ProjectForget
        | OperationName::PaneCreate
        | OperationName::PaneSplit
        | OperationName::PaneSelect
        | OperationName::PaneClose
        | OperationName::PaneResize
        | OperationName::ShellLaunch
        | OperationName::AgentLaunch
        | OperationName::RunInterrupt
        | OperationName::InputWrite
        | OperationName::InputKey
        | OperationName::LayoutSave
        | OperationName::LayoutRestore
        | OperationName::HostStop => LedgerClass::RetainedEffect,
        OperationName::ArtifactRegister | OperationName::ArtifactChoose => LedgerClass::RetainedEffect,
        OperationName::ArtifactList
        | OperationName::ArtifactRead
        | OperationName::ArtifactDiff
        | OperationName::ArtifactChoiceList => LedgerClass::CurrentObservation,
        other => match other.class() {
            OperationClass::Q
            | OperationClass::T
            | OperationClass::R
            | OperationClass::A
            | OperationClass::S => LedgerClass::Unsupported,
        },
    }
}
