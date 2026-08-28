#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/package-remote-helper.sh <output-path>" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "winsmux remote helper packaging supports Linux x86_64 only" >&2
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
[[ "$file_output" == *"x86-64"* ]]
readelf -h -- "$output_path" | grep -Eq '^  Machine:[[:space:]]+Advanced Micro Devices X86-64$'

printf '%s\n' "$output_path"
