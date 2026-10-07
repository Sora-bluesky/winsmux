import path from 'node:path';
import { createHash } from 'node:crypto';
import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';
import { readObservedPublicationRows } from './observe-publication-destinations.mjs';

// Plans only fixed missing effects. No dispatch, native custody, authority,
// registry mutation or marker removal. The parent actor must still establish
// adopt, action-time direct authority and actual native custody before effects.
const issued = new WeakMap();
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const demand = (value, reason) => { if (!value) throw new Error(reason); };
const freeze = value => { if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
const repository='Sora-bluesky/winsmux';

/** Pure operation graph builder; synthetic rows cannot become host plans. */
export function publicationOperations(bundle, rows) {
  assertIssuedPublicationBundle(bundle);
  demand(Array.isArray(rows) && rows.length===bundle.assets.length && same(rows.map(row=>row.path).sort(),bundle.assets.map(row=>row.path).sort()),
    'All fixed public rows required before planning.');
  const missing=[];
  for(const row of rows) {
    const expected=bundle.assets.find(asset=>asset.path===row.path);
    demand(same(Object.keys(row).sort(),['path','sha256','state']), 'Exact public row required.');
    if(row.state==='absent' && row.sha256===null)missing.push(expected);
    else demand(row.state==='matching' && row.sha256===expected.sha256,'Unknown or conflicting public destination refuses a plan.');
  }
  const bodyMissing=missing.some(row=>row.path==='release-body.md');
  const releaseAssets=missing.filter(row=>/^(core|desktop)\//u.test(row.path));
  if(bodyMissing)demand(releaseAssets.length===bundle.assets.filter(row=>/^(core|desktop)\//u.test(row.path)).length,
    'Absent release must have all fixed release assets absent.');
  const file=relative=>path.join(bundle.root,relative);
  const effects=[];
  if(bodyMissing)effects.push({id:'github-release',kind:'github_release_create',program:'gh',
    arguments:['release','create','v0.38.0','--repo','github.com/'+repository,'--target',bundle.identity.source_commit,
      '--title','v0.38.0','--notes-file',file('release-body.md')],
    destination:'https://github.com/'+repository+'/releases/tag/v0.38.0',
    assets:[bundle.assets.find(row=>row.path==='release-body.md')]});
  if(releaseAssets.length)effects.push({id:'github-assets',kind:'github_release_upload',program:'gh',
    arguments:['release','upload','v0.38.0','--repo','github.com/'+repository,...releaseAssets.map(row=>file(row.path))],
    destination:'https://github.com/'+repository+'/releases/tag/v0.38.0',assets:releaseAssets});
  const npm=missing.find(row=>row.path==='npm/winsmux-0.38.0.tgz');
  if(npm)effects.push({id:'npm-archive',kind:'npm_publish',program:'npm',
    arguments:['publish',file(npm.path),'--ignore-scripts','--registry=https://registry.npmjs.org','--tag','latest'],
    destination:'https://registry.npmjs.org/winsmux',assets:[npm]});
  return freeze({candidate_identity:bundle.identity,operations:effects,missing_assets:missing.map(row=>row.path).sort(),
    matched_assets:bundle.assets.length-missing.length,publication_admitted:false});
}

/** Actual-origin branded plan for a parent actor. Caller JSON cannot mint it. */
export function planObservedIntegratedPublication(contract,bundle,observation) {
  assertIssuedIntegratedContract(contract);assertIssuedPublicationBundle(bundle);revalidatePublicationBundle(bundle);
  const rows=readObservedPublicationRows(contract,bundle,observation);
  const plan=publicationOperations(bundle,rows);
  issued.set(plan,{contract,bundle,observation,rows_sha256:sha(Buffer.from(JSON.stringify(rows)))});
  return plan;
}
export function revalidateObservedPublicationPlan(contract,bundle,plan) {
  assertIssuedIntegratedContract(contract);assertIssuedPublicationBundle(bundle);revalidatePublicationBundle(bundle);
  const original=issued.get(plan);
  demand(original?.contract===contract && original.bundle===bundle,'Actual parent-observed publication plan required.');
  const rows=readObservedPublicationRows(contract,bundle,original.observation);
  demand(original.rows_sha256===sha(Buffer.from(JSON.stringify(rows))) && same(plan,publicationOperations(bundle,rows)),
    'Observed publication plan changed.');
  return freeze({plan_integrity_verified:true,publication_admitted:false});
}
