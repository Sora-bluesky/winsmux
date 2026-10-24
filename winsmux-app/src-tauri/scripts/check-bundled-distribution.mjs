import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { checkedPowerShellEnvironment, physicalPath } from '../../../scripts/distribution-prelaunch.mjs';
import { assertCanonicalBundledDistribution } from '../../../scripts/stage-bundled-distribution.mjs';
import { beginDesktopBundle, readDesktopDistributionVersion } from '../../../scripts/stage-desktop-msi-plan.mjs';
import { assertWindowsBuildEnvironment } from '../../../scripts/windows-distribution-build.mjs';

let refusalStage = 'arguments';
// The same beforeBundleCommand is used by `tauri build` and direct `tauri bundle`.
try {
  const signed = process.argv.length === 3 && process.argv[2] === '--signed-companions';
  if (process.argv.length !== 2 && !signed) throw new Error('Unsupported bundling input option.');
  refusalStage = 'source';
  const repoRoot = physicalPath(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..'));
  refusalStage = 'environment';
  const env = checkedPowerShellEnvironment(repoRoot);
  refusalStage = 'build_environment';
  assertWindowsBuildEnvironment(env);
  refusalStage = 'distribution_read_set';
  const verified = readDesktopDistributionVersion(repoRoot, env);
  refusalStage = 'compiler_identity';
  const rustc = spawnSync('rustc', ['-Vv'], { cwd: repoRoot, env, encoding: 'utf8', windowsHide: true });
  if (rustc.error || rustc.signal || rustc.status !== 0) throw new Error('Rust compiler identity is unavailable.');
  const host = /^host: ([A-Za-z0-9_-]+)$/mu.exec(rustc.stdout)?.[1];
  const rustcCommit = /^commit-hash: ([a-f0-9]{40})$/mu.exec(rustc.stdout)?.[1];
  if (!host || !rustcCommit) throw new Error('Rust compiler identity is incomplete.');
  const options = { repoRoot, host, rustcCommit, version: verified.version };
  for (const output of [path.join(verified.build_target_root, 'release'), path.join(verified.build_target_root, host, 'release')]) {
    refusalStage = output === path.join(verified.build_target_root, 'release') ? 'canonical_default' : 'canonical_host';
    assertCanonicalBundledDistribution({ ...options, projectOutput: output });
  }
  if (signed) {
    refusalStage = 'signed_companions';
    for (const name of ['winsmux', 'winsmux-workspace-mcp']) {
      const signature = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-File',
        path.join(repoRoot, 'winsmux-app/src-tauri/scripts/sign-windows-bundle.ps1'),
        '-AssetPath', path.join(repoRoot, 'winsmux-app/src-tauri/binaries', `${name}-${host}.exe`), '-VerifyOnly'],
      { cwd: repoRoot, env, encoding: 'utf8', windowsHide: true, maxBuffer: 8 * 1024 * 1024 });
      if (signature.error || signature.signal || signature.status !== 0) throw new Error('Signed companion validation failed.');
    }
  }
  const projectOutput = path.join(verified.build_target_root, 'release');
  refusalStage = 'bundle_admission';
  beginDesktopBundle({ ...options, srcTauri: path.join(repoRoot, 'winsmux-app/src-tauri'),
    projectOutput, guiPath: path.join(projectOutput, 'winsmux-app.exe'), signed });
  console.log(JSON.stringify({ status: 'bundling_inputs_verified', version: verified.version,
    compiler_launched: false, installation_complete: false }));
} catch {
  console.error('desktop_bundle_refused:' + refusalStage);
  console.log(JSON.stringify({ status: 'refused', compiler_launched: false }));
  process.exitCode = 1;
}
