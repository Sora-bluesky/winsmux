import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { physicalPath } from './distribution-prelaunch.mjs';

const targets = new Set(['x86_64-pc-windows-msvc', 'i686-pc-windows-msvc', 'aarch64-pc-windows-msvc']);
const packages = new Set(['winsmux', 'winsmux-workspace-mcp']);
function requireValue(value, reason) { if (!value) throw new Error(reason); }

// Cargo selects these by presence, including an explicitly empty rustflags value.
// Aliases and cc's host/target/compiler spellings use this same admission gate.
export function assertWindowsBuildEnvironment(env = process.env) {
  for (const key of Object.keys(env)) {
    if (/^(?:RUSTFLAGS|CARGO_ENCODED_RUSTFLAGS|CARGO_BUILD_RUSTFLAGS|RUSTC|CARGO_BUILD_RUSTC|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|CARGO_BUILD_RUSTC_WRAPPER|CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER|CL|_CL_|LINK|_LINK_|CC|CXX|AR|CFLAGS|CXXFLAGS|CPPFLAGS|ARFLAGS|CROSS_COMPILE|RUSTC_LINKER|CRATE_CC_NO_DEFAULTS|CC_KNOWN_WRAPPER_CUSTOM)$/iu.test(key)
      || /^CARGO_TARGET_.*_(?:RUSTFLAGS|LINKER)$/iu.test(key)
      || /^(?:(?:HOST|TARGET)_)?(?:CC|CXX|AR|CFLAGS|CXXFLAGS|CPPFLAGS|ARFLAGS)(?:_[a-z0-9_-]+)?$/iu.test(key)) {
      throw new Error(`Distribution build override is unsupported: ${key}`);
    }
  }
}

/** One Cargo invocation policy for public CLI and Desktop companion processes.
 * Explicit --target keeps target CRT flags out of host build scripts/proc macros.
 * Tauri and the no_std NSIS DLL retain their own existing build contracts.
 */
export function windowsDistributionBuildPlan({ repoRoot, target, targetRoot, intermediateRoot,
  companions = false, release = true }, env = process.env) {
  requireValue(targets.has(target), 'Unsupported Windows distribution target.');
  requireValue(typeof companions === 'boolean' && typeof release === 'boolean', 'Explicit build mode required.');
  assertWindowsBuildEnvironment(env);
  const repo = physicalPath(repoRoot), config = path.join(repo, 'core/.cargo/config.toml');
  requireValue(fs.statSync(physicalPath(config)).isFile(), 'Core static CRT configuration missing.');
  const configText = fs.readFileSync(config, 'utf8').replaceAll('\r\n', '\n');
  for (const triple of targets) {
    const heading = `[target.${triple}]`;
    const section = configText.split(heading)[1]?.split('\n[')[0];
    requireValue(section && /^rustflags = \["-C", "target-feature=\+crt-static"\]$/mu.test(section),
      'Core static CRT configuration differs from the supported build policy.');
  }
  const out = physicalPath(targetRoot), intermediate = physicalPath(intermediateRoot);
  requireValue(path.isAbsolute(targetRoot) && path.isAbsolute(intermediateRoot), 'Absolute validated build outputs required.');
  const toml = 'build.build-dir=' + JSON.stringify(intermediate.replaceAll('\\', '/'));
  const selected = companions ? [...packages] : ['winsmux'];
  const args = ['build', '--locked', '--manifest-path', path.join(repo, 'Cargo.toml'),
    '--target-dir', out, '--target', target, '--config', config, '--config', toml,
    '--message-format', 'json-render-diagnostics'];
  for (const name of selected) args.push('-p', name, '--bin', name);
  if (release) args.push('--release');
  return { schema: 'windows-distribution-build/v1', cwd: repo, target, packages: selected,
    profile: release ? 'release' : 'debug', args, runtime_policy: 'static-crt-os-imports' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    requireValue(process.argv.length === 3, 'Usage: windows-distribution-build.mjs <request.json>');
    if (process.argv[2] === '--check-environment') {
      assertWindowsBuildEnvironment(); console.log(JSON.stringify({ schema: 'windows-build-environment/v1', accepted: true }));
    } else console.log(JSON.stringify(windowsDistributionBuildPlan(JSON.parse(fs.readFileSync(process.argv[2], 'utf8')))));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
