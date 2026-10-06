import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { checkedPowerShellEnvironment, physicalPath } from '../../../scripts/distribution-prelaunch.mjs';
import { assertCanonicalBundledDistribution } from '../../../scripts/stage-bundled-distribution.mjs';
import { assertWindowsBuildEnvironment } from '../../../scripts/windows-distribution-build.mjs';

// The same beforeBundleCommand is used by `tauri build` and direct `tauri bundle`.
try {
  const signed = process.argv.length === 3 && process.argv[2] === '--signed-companions';
  if (process.argv.length !== 2 && !signed) throw new Error('Unsupported bundling input option.');
  const repoRoot = physicalPath(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..'));
  const env = checkedPowerShellEnvironment(repoRoot);
  assertWindowsBuildEnvironment(env);
  const gate = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-File',
    path.join(repoRoot, 'scripts/assert-distribution-version.ps1'), '-RepoRoot', repoRoot, '-AsJson'],
  { cwd: repoRoot, env, encoding: 'utf8', windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
  if (gate.error || gate.signal || gate.status !== 0) throw new Error('Distribution read set failed.');
  const verified = JSON.parse(gate.stdout);
  const rustc = spawnSync('rustc', ['-Vv'], { cwd: repoRoot, env, encoding: 'utf8', windowsHide: true });
  if (rustc.error || rustc.signal || rustc.status !== 0) throw new Error('Rust compiler identity is unavailable.');
  const host = /^host: ([A-Za-z0-9_-]+)$/mu.exec(rustc.stdout)?.[1];
  const rustcCommit = /^commit-hash: ([a-f0-9]{40})$/mu.exec(rustc.stdout)?.[1];
  if (!host || !rustcCommit) throw new Error('Rust compiler identity is incomplete.');
  const options = { repoRoot, host, rustcCommit, version: verified.version };
  for (const output of [path.join(verified.build_target_root, 'release'), path.join(verified.build_target_root, host, 'release')]) {
    assertCanonicalBundledDistribution({ ...options, projectOutput: output });
  }
  if (signed) {
    for (const name of ['winsmux', 'winsmux-workspace-mcp']) {
      const signature = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-File',
        path.join(repoRoot, 'winsmux-app/src-tauri/scripts/sign-windows-bundle.ps1'),
        '-AssetPath', path.join(repoRoot, 'winsmux-app/src-tauri/binaries', `${name}-${host}.exe`), '-VerifyOnly'],
      { cwd: repoRoot, env, encoding: 'utf8', windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
      if (signature.error || signature.signal || signature.status !== 0) throw new Error('Signed companion validation failed.');
    }
  }
  console.log(JSON.stringify({ status: 'bundling_inputs_verified', version: verified.version,
    compiler_launched: false, installation_complete: false }));
} catch {
  console.log(JSON.stringify({ status: 'refused', compiler_launched: false }));
  process.exitCode = 1;
}
