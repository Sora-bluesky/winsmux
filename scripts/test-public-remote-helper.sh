#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: scripts/test-public-remote-helper.sh <packaged-helper> [x64|arm64]" >&2
  exit 2
fi

expected_arch="${2:-x64}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "winsmux packaged remote helper tests support Linux hosts only" >&2
  exit 1
fi

host_arch="$(uname -m)"
case "$host_arch" in
  x86_64) host_artifact_arch="x64";;
  aarch64|arm64) host_artifact_arch="arm64";;
  *)
    echo "winsmux packaged remote helper tests support Linux x86_64 and aarch64 hosts only" >&2
    exit 1
    ;;
esac

case "$expected_arch" in
  x64|arm64) ;;
  *)
    echo "winsmux packaged remote helper tests require expected architecture x64 or arm64" >&2
    exit 2
    ;;
esac

if [[ "$host_artifact_arch" != "$expected_arch" ]]; then
  echo "winsmux packaged remote helper tests expected $expected_arch but native host is $host_artifact_arch" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source_path="$1"
if [[ "$source_path" != /* ]]; then
  source_path="$repo_root/$source_path"
fi
test -f "$source_path"
test -x "$source_path"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
test_home="$test_root/home"
install_path="$test_home/.local/bin/winsmux-remote-helper"
mkdir -p -- "$(dirname -- "$install_path")"
install -m 0755 -- "$source_path" "$install_path"
cmp -s -- "$source_path" "$install_path"

pushd "$test_home" >/dev/null
set +e
HOME="$test_home" ./.local/bin/winsmux-remote-helper >"$test_root/usage.stdout" 2>"$test_root/usage.stderr"
usage_status=$?
set -e
popd >/dev/null
[[ $usage_status -eq 2 ]]
grep -Fxq 'usage: winsmux-remote-helper serve --stdio' "$test_root/usage.stderr"

export WINSMUX_REMOTE_HELPER_UNDER_TEST="$install_path"
manifest="$repo_root/core/crates/winsmux-remote-helper/Cargo.toml"

cargo test \
  --manifest-path "$manifest" \
  --test protocol \
  --test session_lifecycle \
  --no-run

run_exact() {
  local suite="$1"
  local selector="$2"
  timeout --kill-after=5s 20s cargo test \
    --manifest-path "$manifest" \
    --test "$suite" \
    "$selector" \
    -- \
    --exact \
    --nocapture \
    --test-threads=1
}

run_exact protocol argv_without_serve_stdio_exits_2
run_exact protocol argv_extra_token_exits_2
run_exact protocol black_box_binary_hello_welcome
run_exact session_lifecycle packaged_release_detach_close_reattach_io_and_stop_is_protocol_visible
