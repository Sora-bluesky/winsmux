import fs from 'node:fs';
import path from 'node:path';
import { publicationFixture } from './publication-fixture.mjs';

if (!process.argv[2]) throw new Error('Canonical operator root required.');
const fixture = publicationFixture(path.resolve(process.argv[2]));
const identity = { fixture_root: fixture.root, bundle_root: fixture.bundle.root,
  names: fixture.manifest.assets.map(row => row.path), hashes: fixture.manifest.assets.map(row => row.sha256),
  candidate_identity: fixture.bundle.identity, synthetic: true, publication_admitted: false };
fs.writeFileSync(path.join(fixture.root, 'custody-fixture.json'), JSON.stringify(identity));
fs.writeFileSync(path.join(fixture.root, 'publication-assets.json'), JSON.stringify(fixture.manifest));
console.log(JSON.stringify(identity));
