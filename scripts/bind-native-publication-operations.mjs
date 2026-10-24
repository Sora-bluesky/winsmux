import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkParentPublicationPrerequisites } from './check-parent-publication-prerequisites.mjs';
import { observedPublicationInvocations } from './observe-publication-tools.mjs';
import { revalidatePublicationRuntimeSources } from './observe-publication-runtime-sources.mjs';

// A fixed command table for the parent's mechanical native adapter, not a
// launcher or permission token. Wire requests may select an ID/stage only.
// Exact native custody and each live action-time decision remain separate.
const issued = new WeakMap();
const sha = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const freeze = value => {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
};
const demand = (value, reason) => { if (!value) throw new Error(reason); };

function runtimeInputs(runtime) {
  revalidatePublicationRuntimeSources(runtime.sources);
  const profile=runtime.profile;
  demand(profile && JSON.stringify(Object.keys(profile).sort())===JSON.stringify(['source_manifest','source_manifest_sha256','guard_file','guard_sha256','temp_directory','user_config','global_config','npm_cache'].sort()),'Closed native runtime profile required.');
  demand(profile.source_manifest_sha256===runtime.sources.manifest_sha256 && profile.guard_file===runtime.sources.guard.path && profile.guard_sha256===runtime.sources.guard.sha256,'Native runtime sources differ from original observation.');
  for(const key of ['source_manifest','guard_file','temp_directory','user_config','global_config']) {
    const file=profile[key];demand(typeof file==='string'&&path.isAbsolute(file)&&!file.startsWith('\\\\')&&fs.realpathSync.native(file)===file&&!fs.lstatSync(file).isSymbolicLink(),'Exact plain native runtime input required.');
  }
  demand(createHash('sha256').update(fs.readFileSync(profile.source_manifest)).digest('hex')===profile.source_manifest_sha256,'Native source manifest bytes differ.');
  demand(profile.user_config===path.join(profile.temp_directory,'publication-user.npmrc')&&profile.global_config===path.join(profile.temp_directory,'publication-global.npmrc')&&
    profile.npm_cache===path.join(profile.temp_directory,'npm-cache'),'Native fixed configuration paths differ.');
  demand(fs.readFileSync(profile.user_config,'utf8')==='//registry.npmjs.org/:_authToken=${WINSMUX_NPM_TOKEN}\n'&&fs.readFileSync(profile.global_config).length===0,'Execution configuration must contain only the fixed scoped authentication substitution.');
  return {...profile};
}
function fixedTable(contract, bundle, registry, plan, tools, parentSession, runtime=null) {
  checkParentPublicationPrerequisites(contract, bundle, registry, plan, parentSession);
  const input=runtime===null?null:runtimeInputs(runtime);
  const invocations = observedPublicationInvocations(contract, bundle, plan, tools).map(invocation=> {
    if(input===null||invocation.kind!=='npm_publish')return invocation;
    return {...invocation,arguments:['--no-addons','--import',pathToFileURL(input.guard_file).href,...invocation.arguments,
      '--userconfig='+input.user_config,'--globalconfig='+input.global_config,'--cache='+input.npm_cache,
      '--prefix='+bundle.root,'--logs-max=0','--loglevel=silent','--update-notifier=false','--audit=false','--fund=false','--provenance=false']};
  });
  const entries = invocations.map(invocation => {
    const operation = plan.operations.find(row => row.id === invocation.operation_id);
    const binding = { candidate_identity: bundle.identity, bundle_root: bundle.root,
      bundle_root_identity: bundle.root_identity, contract_inventory_sha256: contract.inventory_sha256,
      contract_controls_sha256: contract.controls_sha256, parent_session: parentSession,
      destination: operation.destination, assets: operation.assets, invocation, ...(input===null?{}:{runtime_inputs:input}) };
    return { operation_id: invocation.operation_id, binding_sha256: sha(binding),
      destination: operation.destination, assets: operation.assets, ...invocation };
  });
  demand(new Set(entries.map(row => row.operation_id)).size === entries.length, 'Duplicate fixed operation ID.');
  return { schema: input===null?'winsmux-native-publication-operation-table/v1':'winsmux-native-publication-operation-table/v2', candidate_identity: bundle.identity,
    bundle_root: bundle.root, parent_session: parentSession, entries,
    ...(input===null?{}:{runtime_inputs:input}),
    action_time_authority_verified: false, native_custody_verified: false, publication_admitted: false };
}

export function bindNativePublicationOperations(contract, bundle, registry, plan, tools, parentSession) {
  const table = freeze(fixedTable(contract, bundle, registry, plan, tools, parentSession));
  issued.set(table, { contract, bundle, registry, plan, tools, parentSession });
  return table;
}
export function bindNativeRuntimePublicationOperations(contract,bundle,registry,plan,tools,parentSession,sources,profile) {
  const runtime={sources,profile:{...profile}};
  const table=freeze(fixedTable(contract,bundle,registry,plan,tools,parentSession,runtime));
  issued.set(table,{contract,bundle,registry,plan,tools,parentSession,runtime});return table;
}

export function revalidateNativePublicationOperations(table) {
  const source = issued.get(table);
  demand(source, 'Original process-local fixed operation table required.');
  demand(JSON.stringify(table) === JSON.stringify(fixedTable(source.contract, source.bundle, source.registry,
    source.plan, source.tools, source.parentSession, source.runtime??null)), 'Fixed native operation table changed.');
  return Object.freeze({ operation_table_integrity_verified: true,
    action_time_authority_verified: false, native_custody_verified: false, publication_admitted: false });
}

export function readNativePublicationOperation(table, operationId, observedBindingSha256, phase) {
  revalidateNativePublicationOperations(table);
  demand(phase === 'create' || phase === 'resume', 'Only fixed native create/resume phases are supported.');
  demand(typeof operationId === 'string' && typeof observedBindingSha256 === 'string', 'Exact operation ID and binding required.');
  const entry = table.entries.find(row => row.operation_id === operationId);
  demand(entry && entry.binding_sha256 === observedBindingSha256, 'Requested native operation differs from parent binding.');
  // Reading a fixed entry does not consume a challenge, approve an operation,
  // create a root, or resume one. The original parent owns those live decisions.
  return entry;
}

export function readNativePublicationChallenge(table, line) {
  demand(typeof line==='string' && !/[\r\n\0]/u.test(line),'One exact native decision line required.');
  const [kind,id,phase,binding,nonce,...extra]=line.split('|');
  demand(kind==='DECIDE'&&extra.length===0&&typeof nonce==='string'&&/^[a-f0-9]{64}$/u.test(nonce),
    'Exact fixed operation ID, phase, binding and native nonce required.');
  const operation=readNativePublicationOperation(table,id,binding,phase);
  return Object.freeze({operation,phase,nonce,action_time_authority_verified:false,native_custody_verified:false,publication_admitted:false});
}
