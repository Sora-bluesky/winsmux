import fs from 'node:fs';
import path from 'node:path';
import { readIntegratedPublicationContract } from '../../scripts/integrated-publication-contract.mjs';
import { readIntegratedPublicationAssets } from '../../scripts/integrated-publication-assets.mjs';
import { freezePublicationAttempt, assertPublicationPreparationAllowed } from '../../scripts/integrated-publication-attempt.mjs';

// Test host adapter only: owner.json was emitted by the actual fixture owner.
// No public actor or permission token exists in this fixture.
const [mode, operatorRoot, fixtureRoot] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'custody-fixture.json'), 'utf8'));
if (!fixture.synthetic || fixture.publication_admitted !== false) throw new Error('Synthetic input required');
if (mode === 'guard') {
  assertPublicationPreparationAllowed(fixtureRoot, '0.38.0');
  throw new Error('Frozen fixture was accepted for preparation');
} else if (mode === 'freeze') {
  const contract = readIntegratedPublicationContract(operatorRoot);
  const bundle = readIntegratedPublicationAssets(contract, fixture.bundle_root, fs.readFileSync(path.join(fixtureRoot, 'publication-assets.json')));
  const actualOwner = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'owner.json'), 'utf8'));
  const keeper = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'keeper.json'), 'utf8'));
  // Native owner starts and verifies this exact keeper before writing the
  // original record. This test adapter is not a production JSON verifier.
  actualOwner.keeper = { pid: keeper.Pid, creation_filetime: String(keeper.creation_filetime_exact), pipe_name: keeper.PipeName,
    attempt: keeper.Attempt, candidate_manifest_sha256: keeper.CandidateSha256,
    implementation_sha256: keeper.ImplementationSha256, script_sha256: keeper.ScriptSha256 };
  // This earlier single-native-actor fixture uses the measured owner as actor.
  // It cannot stand in for the new two-process Node/native binding proof.
  const snapshot = freezePublicationAttempt(contract, bundle, fixtureRoot, () => actualOwner,
    () => ({ pid: actualOwner.pid, creation_filetime: actualOwner.creation_filetime }));
  const result = { file: snapshot.file, original_sha256: snapshot.original_sha256, publication_admitted: false };
  fs.writeFileSync(path.join(fixtureRoot, 'freeze-result.json'), JSON.stringify(result), { flag: 'wx' });
} else throw new Error('Unknown test host mode');
