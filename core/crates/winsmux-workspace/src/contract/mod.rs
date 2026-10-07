pub(crate) mod ingress;
mod capabilities;
pub use capabilities::CapabilitiesGetParams;
mod operations;
pub mod projection;
mod scalar;
mod types;
mod validate;
mod wire;
pub use operations::*;
pub use scalar::*;
pub use types::*;
pub use wire::*;

/// Fixed classifications only; never contains input, paths or OS diagnostics.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum ContractError {
    MessageTooLarge,
    InvalidUtf8,
    BomForbidden,
    InvalidJson,
    DuplicateKey,
    NestingLimit,
    UnsupportedSchema,
    InvalidShape,
    InvalidScalar,
    InvariantViolation,
    ResponseCorrelation,
}
impl std::fmt::Display for ContractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ContractError {}
pub const MAX_MESSAGE_BYTES: usize = 1_048_576;
/// serde_json's existing container recursion guard; not a runtime operation limit.
pub(crate) const JSON_DEPTH: usize = 127;
