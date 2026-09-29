use crate::contract::{InstanceId, Version};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Discovery {
    pub(crate) instance_id: InstanceId,
    pub(crate) pipe_name: String,
    pub(crate) schema_version: Version,
}

#[cfg(windows)]
impl Discovery {
    pub fn instance_id(&self) -> &InstanceId {
        &self.instance_id
    }
    pub fn pipe_name(&self) -> &str {
        &self.pipe_name
    }
    pub fn schema_version(&self) -> Version {
        self.schema_version
    }
    pub(crate) fn artifact_review_pipe_name(&self) -> String {
        format!(
            "{}-artifact-review-v1-{}",
            self.pipe_name,
            self.instance_id.as_str()
        )
    }

    pub(crate) fn for_server(
        identity: &security::Identity,
        instance_id: InstanceId,
        fingerprint: &str,
    ) -> Result<Self, HostError> {
        if !is_lower_hex_64(fingerprint) {
            return Err(HostError::Startup);
        }
        Ok(Self {
            instance_id,
            pipe_name: format!(
                r"\\.\pipe\winsmux-workspace-v1-{}-{fingerprint}",
                identity.logon_key()
            ),
            schema_version: Version::new(1).expect("schema v1"),
        })
    }

    pub(crate) fn validate_for<'a>(
        &'a self,
        identity: &security::Identity,
    ) -> Result<&'a str, HostError> {
        if self.schema_version != Version::new(1).expect("schema v1") {
            return Err(HostError::Protocol);
        }
        let prefix = format!(r"\\.\pipe\winsmux-workspace-v1-{}-", identity.logon_key());
        let fingerprint = self
            .pipe_name
            .strip_prefix(&prefix)
            .filter(|value| is_lower_hex_64(value))
            .ok_or(HostError::Protocol)?;
        if self.pipe_name.len() != prefix.len() + 64 {
            return Err(HostError::Protocol);
        }
        Ok(fingerprint)
    }
}

#[cfg(all(test, windows))]
mod artifact_review_name_tests {
    use super::*;

    #[test]
    fn derived_name_binds_the_verified_pipe_and_current_instance() {
        let discovery = Discovery {
            instance_id: InstanceId::new("12345678-1234-4234-8234-123456789abc").unwrap(),
            pipe_name: r"\\.\pipe\winsmux-workspace-v1-test-fingerprint".to_owned(),
            schema_version: Version::new(1).unwrap(),
        };
        assert_eq!(
            discovery.artifact_review_pipe_name(),
            r"\\.\pipe\winsmux-workspace-v1-test-fingerprint-artifact-review-v1-12345678-1234-4234-8234-123456789abc",
        );
    }
}

#[cfg(windows)]
fn is_lower_hex_64(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostError {
    Usage,
    InteractiveRequired,
    Startup,
    Transport,
    Protocol,
    Cancelled,
}

impl HostError {
    pub(crate) fn exit_code(self) -> i32 {
        match self {
            Self::Usage | Self::InteractiveRequired => 2,
            Self::Cancelled => 130,
            Self::Startup | Self::Transport | Self::Protocol => 1,
        }
    }

    pub fn classification(self) -> &'static str {
        match self {
            Self::Usage => "usage",
            Self::InteractiveRequired => "interactive_required",
            Self::Startup => "startup_failed",
            Self::Transport => "transport_failed",
            Self::Protocol => "protocol_failed",
            Self::Cancelled => "cancelled",
        }
    }
}

#[cfg(windows)]
pub(crate) mod admission;
#[cfg(windows)]
pub(crate) mod io;
#[cfg(windows)]
mod process;
#[cfg(windows)]
pub(crate) mod security;
#[cfg(windows)]
pub(crate) mod server_identity;
#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::{run_child, run_launcher, WorkspaceOwner, WorkspaceRequestError};
#[cfg(all(windows, debug_assertions, feature = "native-e2e-faults"))]
pub use windows::{run_child_stop_reply_loss, StopReplyLossGate, StopReplyLossRelease};
#[cfg(all(windows, debug_assertions))]
pub use windows::{ProductClient, ProductHost, SupervisedPreauth};

#[cfg(all(windows, debug_assertions))]
pub mod testing;

#[cfg(not(windows))]
pub fn run_launcher() -> Result<(), HostError> {
    Err(HostError::Startup)
}

#[cfg(not(windows))]
pub fn run_child(_argument: &str) -> Result<(), HostError> {
    Err(HostError::Startup)
}
