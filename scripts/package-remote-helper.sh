#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: scripts/package-remote-helper.sh <output-path> [x64|arm64]" >&2
  exit 2
fi

expected_arch="${2:-x64}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "winsmux remote helper packaging supports Linux hosts only" >&2
  exit 1
fi

host_arch="$(uname -m)"
case "$host_arch" in
  x86_64) host_artifact_arch="x64";;
  aarch64|arm64) host_artifact_arch="arm64";;
  *)
    echo "winsmux remote helper packaging supports Linux x86_64 and aarch64 hosts only" >&2
    exit 1
    ;;
esac

case "$expected_arch" in
  x64)
    expected_file_arch="x86-64"
    expected_machine="Advanced Micro Devices X86-64"
    ;;
  arm64)
    expected_file_arch="ARM aarch64"
    expected_machine="AArch64"
    ;;
  *)
    echo "winsmux remote helper packaging requires expected architecture x64 or arm64" >&2
    exit 2
    ;;
esac

if [[ "$host_artifact_arch" != "$expected_arch" ]]; then
  echo "winsmux remote helper packaging expected $expected_arch but native host is $host_artifact_arch" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
output_path="$1"

if [[ "$output_path" != /* ]]; then
  output_path="$repo_root/$output_path"
fi

cargo build --release --locked \
  --manifest-path "$repo_root/core/crates/winsmux-remote-helper/Cargo.toml" \
  --bin winsmux-remote-helper

built_path="$repo_root/target/release/winsmux-remote-helper"
test -f "$built_path"
mkdir -p -- "$(dirname -- "$output_path")"
cp -- "$built_path" "$output_path"
chmod 0755 "$output_path"

test -x "$output_path"
file_output="$(file -b -- "$output_path")"
[[ "$file_output" == *"ELF 64-bit LSB"* ]]
[[ "$file_output" == *"$expected_file_arch"* ]]
readelf -h -- "$output_path" | grep -Eq "^  Machine:[[:space:]]+$expected_machine$"

printf '%s\n' "$output_path"
