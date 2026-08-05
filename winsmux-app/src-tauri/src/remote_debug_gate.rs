//! Pure two-variable gate for injecting `--remote-debugging-port` into WebView2 args.

use std::env;
use std::ffi::OsStr;

pub(crate) const WINSMUX_DESKTOP_TEST_PROFILE_ENV: &str = "WINSMUX_DESKTOP_TEST_PROFILE";
pub(crate) const WINSMUX_DESKTOP_REMOTE_DEBUG_PORT_ENV: &str = "WINSMUX_DESKTOP_REMOTE_DEBUG_PORT";
/// Manual copy of the wry 0.55.1 WebView2 defaults (wry/src/webview2/mod.rs:294-322).
/// Re-verify on every wry upgrade; a contract test pins the wry version in Cargo.lock.
pub(crate) const WRY_DEFAULT_BROWSER_ARGS: &str =
    "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required";

const PROFILE_PUBLIC_SMOKE: &str = "public-smoke";
const PORT_POLICY_FLOOR: u16 = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteDebugGateReason {
    ProfileUnrecognized,
    PortEmpty,
    PortNotNumeric,
    PortOutOfRange,
    PortOutOfPolicy,
}

impl RemoteDebugGateReason {
    pub(crate) fn diagnostic_token(self) -> &'static str {
        match self {
            Self::ProfileUnrecognized => "profile_unrecognized",
            Self::PortEmpty => "port_empty",
            Self::PortNotNumeric => "port_not_numeric",
            Self::PortOutOfRange => "port_out_of_range",
            Self::PortOutOfPolicy => "port_out_of_policy",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteDebugGate {
    Disabled,
    Rejected(RemoteDebugGateReason),
    Enabled { port: u16 },
}

pub(crate) fn evaluate(profile: Option<&OsStr>, port: Option<&OsStr>) -> RemoteDebugGate {
    // R1: absent profile — never inspect the port argument.
    let Some(profile) = profile else {
        return RemoteDebugGate::Disabled;
    };

    // R2: profile must be exactly the UTF-8 token `public-smoke`.
    let Some(profile_str) = profile.to_str() else {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::ProfileUnrecognized);
    };
    if profile_str != PROFILE_PUBLIC_SMOKE {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::ProfileUnrecognized);
    }

    // R3: recognized profile without a port is a quiet disable.
    let Some(port) = port else {
        return RemoteDebugGate::Disabled;
    };

    // R4 / R5: classify the port.
    classify_port(port)
}

fn classify_port(port: &OsStr) -> RemoteDebugGate {
    let Some(port_str) = port.to_str() else {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::PortNotNumeric);
    };

    if port_str.is_empty() {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::PortEmpty);
    }

    if !port_str.bytes().all(|b| b.is_ascii_digit()) {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::PortNotNumeric);
    }

    // Accumulate with u128; values above u16::MAX are out of range without overflow.
    let mut value: u128 = 0;
    for b in port_str.bytes() {
        value = value
            .saturating_mul(10)
            .saturating_add(u128::from(b - b'0'));
        if value > u128::from(u16::MAX) {
            return RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfRange);
        }
    }

    // value is in 0..=65535 here.
    let port_u16 = value as u16;
    if port_u16 < PORT_POLICY_FLOOR {
        return RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfPolicy);
    }

    RemoteDebugGate::Enabled { port: port_u16 }
}

pub(crate) fn compose_browser_args(port: u16) -> String {
    format!("{WRY_DEFAULT_BROWSER_ARGS} --remote-debugging-port={port}")
}

pub(crate) fn resolve_from_env() -> RemoteDebugGate {
    let profile = env::var_os(WINSMUX_DESKTOP_TEST_PROFILE_ENV);
    let port = env::var_os(WINSMUX_DESKTOP_REMOTE_DEBUG_PORT_ENV);
    let profile_present = profile.is_some();
    let gate = evaluate(profile.as_deref(), port.as_deref());
    if matches!(gate, RemoteDebugGate::Disabled) && profile_present {
        eprintln!("winsmux-desktop: desktop test profile declared without debug port");
    }
    gate
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;

    // Decision-table rows 17 (duplicate same-name env entries) and 18
    // (case-differing variable names) are resolved by the OS/std before the
    // pure `evaluate` function and are intentionally untestable here.

    #[test]
    fn gate_disabled_when_profile_absent() {
        assert_eq!(evaluate(None, None), RemoteDebugGate::Disabled);
    }

    #[test]
    fn stray_port_without_profile_is_ignored() {
        assert_eq!(
            evaluate(None, Some(OsStr::new("49871"))),
            RemoteDebugGate::Disabled
        );
    }

    #[test]
    fn stray_invalid_ports_without_profile_are_ignored() {
        for d in ["", "   ", "abc", "0", "70000"] {
            assert_eq!(
                evaluate(None, Some(OsStr::new(d))),
                RemoteDebugGate::Disabled,
                "port={d:?}"
            );
        }
    }

    #[test]
    fn profile_without_port_is_disabled() {
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), None),
            RemoteDebugGate::Disabled
        );
    }

    #[test]
    fn rejects_empty_port() {
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new(""))),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::PortEmpty)
        );
    }

    #[test]
    fn rejects_whitespace_padded_port() {
        for d in ["   ", " 49871", "49871 "] {
            assert_eq!(
                evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new(d))),
                RemoteDebugGate::Rejected(RemoteDebugGateReason::PortNotNumeric),
                "port={d:?}"
            );
        }
    }

    #[test]
    fn rejects_non_numeric_port() {
        for d in ["abc", "49871x", "0x1234"] {
            assert_eq!(
                evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new(d))),
                RemoteDebugGate::Rejected(RemoteDebugGateReason::PortNotNumeric),
                "port={d:?}"
            );
        }
    }

    #[test]
    fn rejects_port_zero() {
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new("0"))),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfPolicy)
        );
    }

    #[test]
    fn rejects_port_out_of_range() {
        for d in ["65536", "99999", "4294967296"] {
            assert_eq!(
                evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new(d))),
                RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfRange),
                "port={d:?}"
            );
        }
    }

    #[test]
    fn rejects_below_policy_floor() {
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new("1"))),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfPolicy)
        );
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new("1023"))),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::PortOutOfPolicy)
        );
        assert_eq!(
            evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new("1024"))),
            RemoteDebugGate::Enabled { port: 1024 }
        );
    }

    #[test]
    fn accepts_policy_range_boundaries() {
        for (d, expected) in [("1024", 1024u16), ("49871", 49871), ("65535", 65535)] {
            assert_eq!(
                evaluate(Some(OsStr::new("public-smoke")), Some(OsStr::new(d))),
                RemoteDebugGate::Enabled { port: expected },
                "port={d:?}"
            );
        }
    }

    #[test]
    fn rejects_unrecognized_profile_tokens() {
        for p in ["Public-Smoke", "public_smoke", "1", "true"] {
            assert_eq!(
                evaluate(Some(OsStr::new(p)), Some(OsStr::new("49871"))),
                RemoteDebugGate::Rejected(RemoteDebugGateReason::ProfileUnrecognized),
                "profile={p:?}"
            );
        }
    }

    #[test]
    fn rejects_empty_or_whitespace_profile() {
        for p in ["", "   "] {
            assert_eq!(
                evaluate(Some(OsStr::new(p)), Some(OsStr::new("49871"))),
                RemoteDebugGate::Rejected(RemoteDebugGateReason::ProfileUnrecognized),
                "profile={p:?}"
            );
        }
    }

    #[test]
    #[cfg(windows)]
    fn rejects_non_utf8_profile() {
        use std::ffi::OsString;
        use std::os::windows::ffi::OsStringExt;

        let profile = OsString::from_wide(&[0xD800]);
        assert_eq!(
            evaluate(Some(profile.as_os_str()), Some(OsStr::new("49871"))),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::ProfileUnrecognized)
        );
    }

    #[test]
    #[cfg(windows)]
    fn rejects_non_utf8_port() {
        use std::ffi::OsString;
        use std::os::windows::ffi::OsStringExt;

        let port = OsString::from_wide(&[0xD800]);
        assert_eq!(
            evaluate(
                Some(OsStr::new("public-smoke")),
                Some(port.as_os_str())
            ),
            RemoteDebugGate::Rejected(RemoteDebugGateReason::PortNotNumeric)
        );
    }

    #[test]
    fn compose_browser_args_appends_debug_port_last() {
        assert_eq!(
            compose_browser_args(49871),
            "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required --remote-debugging-port=49871"
        );
    }

    #[test]
    fn compose_browser_args_never_adds_address_or_origin_switches() {
        let args = compose_browser_args(1024);
        assert!(!args.contains("--remote-debugging-address"));
        assert!(!args.contains("--remote-allow-origins"));
    }

    #[test]
    fn diagnostic_tokens_are_stable() {
        assert_eq!(
            RemoteDebugGateReason::ProfileUnrecognized.diagnostic_token(),
            "profile_unrecognized"
        );
        assert_eq!(
            RemoteDebugGateReason::PortEmpty.diagnostic_token(),
            "port_empty"
        );
        assert_eq!(
            RemoteDebugGateReason::PortNotNumeric.diagnostic_token(),
            "port_not_numeric"
        );
        assert_eq!(
            RemoteDebugGateReason::PortOutOfRange.diagnostic_token(),
            "port_out_of_range"
        );
        assert_eq!(
            RemoteDebugGateReason::PortOutOfPolicy.diagnostic_token(),
            "port_out_of_policy"
        );
    }
}
