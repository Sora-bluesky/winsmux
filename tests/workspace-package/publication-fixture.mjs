import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { readIntegratedPublicationContract } from '../../scripts/integrated-publication-contract.mjs';
import { integratedAssetPaths, readIntegratedPublicationAssets } from '../../scripts/integrated-publication-assets.mjs';

export const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export function publicationFixture(operatorRoot) {
  const contract = readIntegratedPublicationContract(operatorRoot);
  const root = path.resolve('.evidence/workspace-package', `publication-evidence-${randomUUID()}`);
  const files = new Map(integratedAssetPaths(contract).map(name => [name, Buffer.from(`Synthetic evidence fixture: ${name}\n`)]));
  files.set('desktop/winsmux_0.38.0_x64-setup.exe.sig', Buffer.from('synthetic-signature\n'));
  files.set('desktop/latest.json', Buffer.from(JSON.stringify({ version: '0.38.0', notes: 'Synthetic',
    pub_date: '2026-10-03T00:00:00Z', platforms: { 'windows-x86_64': { signature: 'synthetic-signature',
      url: 'https://github.com/Sora-bluesky/winsmux/releases/download/v0.38.0/winsmux_0.38.0_x64-setup.exe' } } })));
  for (const [surface, checksum] of [['core', 'SHA256SUMS'], ['desktop', 'SHA256SUMS-desktop']]) files.set(`${surface}/${checksum}`,
    Buffer.from([...files].filter(([name]) => name.startsWith(`${surface}/`) && name !== `${surface}/${checksum}`)
      .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([name, bytes]) => `${sha(bytes)}  ${name.slice(surface.length + 1)}\n`).join('')));
  for (const [name, bytes] of files) {
    const target = path.join(root, 'bundle', name); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
  }
  const coordinate = { source_commit: '1'.repeat(40), source_tree: '2'.repeat(40) };
  const manifest = { schema: 'winsmux-integrated-publication-assets/v1', version: '0.38.0', ...coordinate,
    attempt: randomUUID(), producers: Object.fromEntries(['core', 'desktop', 'npm'].map(surface =>
      [surface, { ...coordinate, run: `${surface}-run-1` }])),
    assets: integratedAssetPaths(contract).map(name => ({ path: name, bytes: files.get(name).length, sha256: sha(files.get(name)),
      producer: `${name === 'release-body.md' ? 'core' : name.split('/')[0]}-run-1` })),
  };
  const bundle = readIntegratedPublicationAssets(contract, path.join(root, 'bundle'), Buffer.from(JSON.stringify(manifest)));
  return { contract, root, files, manifest, bundle };
}
