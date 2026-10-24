import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { candidateArtifactMembers, validateGithubCandidateArtifactPayload, registerObservedGithubCandidateArtifacts, observeGithubDesktopPreparation, revalidateObservedGithubDesktopPreparation }
  from '../../scripts/observe-github-candidate-artifacts.mjs';
import { publicationFixture, sha } from './publication-fixture.mjs';

assert.ok(process.argv[2] && process.argv[3], 'Operator originals and actual Python executable required.');
const fixture = publicationFixture(process.argv[2]), python = path.resolve(process.argv[3]);
const root = fixture.root, parser = path.resolve('scripts/read-ci-artifact.py');
const sourceNames = ['scripts/observe-github-candidate-artifacts.mjs', 'scripts/read-ci-artifact.py',
  'tests/workspace-package/github-candidate-artifacts.test.mjs', 'scripts/integrated-publication-contract.mjs',
  'scripts/integrated-publication-assets.mjs', 'scripts/distribution-prelaunch.mjs',
  'scripts/assert-license-inputs.mjs', 'tests/workspace-package/publication-fixture.mjs'];
const source = Object.fromEntries(sourceNames.map(name => [name, sha(fs.readFileSync(name))]));
const environment = { PATH: process.env.PATH ?? path.dirname(python) };
for (const key of ['SystemRoot', 'WINDIR', 'COMSPEC']) if (process.env[key]) environment[key] = process.env[key];
let checks = 0, nativeCases = 0;
const check = action => { action(); checks++; };
const base = 'https://api.github.com/repos/Sora-bluesky/winsmux';
const sourceCommit = '1'.repeat(40), sourceTree = '2'.repeat(40);
const workflowBytes = Buffer.from('name: fixed producer\n'), workflowSha256 = sha(workflowBytes);
const gitBlobSha = (await import('node:crypto')).createHash('sha1').update(Buffer.concat([
  Buffer.from(`blob ${workflowBytes.length}\0`), workflowBytes])).digest('hex');
const maker = `import sys,json,zipfile,base64,stat,warnings
warnings.filterwarnings('ignore',message='Duplicate name:.*',category=UserWarning)
data=json.load(sys.stdin)
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
 for row in data:
  info=zipfile.ZipInfo(row['name']);info.compress_type=zipfile.ZIP_STORED if row.get('stored') else zipfile.ZIP_DEFLATED
  if row.get('symlink'): info.create_system=3;info.external_attr=(stat.S_IFLNK|0o777)<<16
  z.writestr(info,base64.b64decode(row['data']))
`;
const create = (name, rows) => {
  const file = path.join(root, name + '.zip');
  const generated = spawnSync(python, ['-I', '-B', '-c', maker, file], { env: environment, input: JSON.stringify(rows), windowsHide: true });
  assert.equal(generated.status, 0); assert.equal(generated.signal, null); assert.equal(generated.stderr.length, 0);
  return file;
};
const read = (name, file, members, expected = sha(fs.readFileSync(file))) => {
  const input = path.join(root, name + '-members.json'); fs.writeFileSync(input, JSON.stringify(members), { flag: 'wx' });
  const child = spawnSync(python, ['-I', '-B', parser, file, expected, input], { env: environment, windowsHide: true });
  fs.writeFileSync(path.join(root, name + '-stdout.json'), child.stdout ?? Buffer.alloc(0), { flag: 'wx' });
  fs.writeFileSync(path.join(root, name + '-stderr.txt'), child.stderr ?? Buffer.alloc(0), { flag: 'wx' });
  nativeCases++; return child;
};
const metadata = surface => ({ surface, sourceCommit, sourceTree, runId: 11, runAttempt: 2, workflowSha256, archiveSha256: '3'.repeat(64),
  commit: { sha: sourceCommit, tree: { sha: sourceTree } },
  workflow: { type: 'file', path: '.github/workflows/release-' + surface + '.yml', encoding: 'base64',
    content: workflowBytes.toString('base64'), sha: gitBlobSha },
  run: { id: 11, run_attempt: 2, head_sha: sourceCommit, path: '.github/workflows/release-' + surface + '.yml',
    repository: { id: 9, full_name: 'Sora-bluesky/winsmux' }, head_repository: { id: 9, full_name: 'Sora-bluesky/winsmux' },
    url: base + '/actions/runs/11', status: 'completed', conclusion: 'success',
    run_started_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-03T00:02:00Z' },
  artifact: { id: 12, name: (surface === 'npm' ? 'npm-candidate-' : 'integrated-' + surface + '-') + sourceCommit + '-11-2',
    expired: false, digest: 'sha256:' + '3'.repeat(64), url: base + '/actions/artifacts/12',
    archive_download_url: base + '/actions/artifacts/12/zip', created_at: '2026-10-03T00:01:00Z',
    workflow_run: { id: 11, head_sha: sourceCommit, repository_id: 9, head_repository_id: 9 } } });
for (const surface of ['core', 'desktop', 'npm']) {
  const value = metadata(surface);
  check(() => { const valid = validateGithubCandidateArtifactPayload(value); assert.equal(valid.surface, surface); assert.equal(valid.publication_admitted, false); });
  for (const mutate of [x => { x.sourceCommit = ''; }, x => { x.sourceTree = '0'.repeat(40); },
    x => { x.commit.sha = '0'.repeat(40); }, x => { x.workflow.path = '.github/workflows/test.yml'; },
    x => { x.workflow.encoding = 'raw'; }, x => { x.workflow.content += '!'; }, x => { x.workflow.sha = '0'.repeat(40); },
    x => { x.workflowSha256 = '0'.repeat(64); }, x => { x.run.id++; }, x => { x.run.run_attempt--; },
    x => { x.run.head_sha = '0'.repeat(40); }, x => { x.run.path += '-other'; },
    x => { x.run.repository.full_name = 'fork/winsmux'; }, x => { x.run.head_repository.id++; },
    x => { x.run.url += '/other'; }, x => { x.run.status = 'in_progress'; }, x => { x.run.conclusion = 'failure'; },
    x => { x.run.run_started_at = 'invalid'; }, x => { x.artifact.created_at = '2026-10-02T00:00:00Z'; },
    x => { x.artifact.created_at = '2026-10-03T00:03:00Z'; }, x => { x.artifact.id = 0; },
    x => { x.artifact.name = x.artifact.name.slice(0, -1) + '1'; }, x => { x.artifact.expired = true; },
    x => { x.artifact.digest = 'sha256:' + '0'.repeat(64); }, x => { x.artifact.url += '/else'; },
    x => { x.artifact.archive_download_url += '/else'; }, x => { x.artifact.workflow_run.id++; },
    x => { x.artifact.workflow_run.head_sha = '0'.repeat(40); }, x => { x.artifact.workflow_run.repository_id++; },
    x => { x.artifact.workflow_run.head_repository_id++; }]) {
    const changed = structuredClone(value); mutate(changed); check(() => assert.throws(() => validateGithubCandidateArtifactPayload(changed)));
  }
  for (const forged of [validateGithubCandidateArtifactPayload(value), JSON.parse(JSON.stringify(value)),
    { passed: true, native: [{ exit_code: 0 }, { exit_code: 0 }, { exit_code: 0 }], publication_admitted: true }])
    check(() => assert.throws(() => registerObservedGithubCandidateArtifacts({}, forged), /actual producer artifact observation/u));
  const members = candidateArtifactMembers(fixture.bundle, surface);
  const rows = members.map(member => ({ name: member.name, data: (member.sha256 === null ? Buffer.alloc(0)
    : fixture.files.get(member.name === 'release-body.md' ? member.name : surface + '/' + member.name)).toString('base64') }));
  const file = create(surface + '-valid', rows), valid = read(surface + '-valid', file, members);
  check(() => { assert.equal(valid.status, 0); assert.equal(valid.stderr.length, 0); assert.equal(valid.signal, null);
    const receipt = JSON.parse(valid.stdout); assert.equal(receipt.members.length, members.length);
    assert.equal(receipt.publication_admitted, false); assert.equal(receipt.archive_sha256, sha(fs.readFileSync(file))); });
  for (const [name, altered] of [
    ['extra', [...rows, { name: 'unrelated.txt', data: '' }]], ['missing', rows.slice(1)],
    ['duplicate', [...rows, rows[0]]], ['traversal', [{ ...rows[0], name: '../' + rows[0].name }, ...rows.slice(1)]],
    ['directory', [{ ...rows[0], name: rows[0].name + '/' }, ...rows.slice(1)]],
    ['link', [{ ...rows[0], symlink: true }, ...rows.slice(1)]],
    ['different-bytes', [{ ...rows[0], data: Buffer.from('modified').toString('base64') }, ...rows.slice(1)]]]) {
    // Auxiliary npm logs are not bundle bytes. Mutate a real bundle member.
    if (name === 'different-bytes' && members[0].sha256 === null) {
      const index = members.findIndex(member => member.sha256 !== null);
      altered[0] = rows[0]; altered[index] = { ...rows[index], data: Buffer.from('modified').toString('base64') };
    }
    const archive = create(surface + '-' + name, altered), result = read(surface + '-' + name, archive, members);
    check(() => { assert.equal(result.status, 1); assert.equal(result.stdout.length, 0); assert.ok(result.stderr.length > 0); });
  }
  const wrongDigest = read(surface + '-wrong-digest', file, members, '0'.repeat(64));
  check(() => { assert.equal(wrongDigest.status, 1); assert.match(wrongDigest.stderr.toString('utf8'), /GitHub artifact digest/u); });
  const broken = path.join(root, surface + '-broken.zip'); fs.writeFileSync(broken, Buffer.from('not zip'), { flag: 'wx' });
  const failed = read(surface + '-broken', broken, members);
  check(() => { assert.equal(failed.status, 1); assert.equal(failed.stdout.length, 0); });
  for (let index = 0; index < members.length; index++) if (members[index].sha256 !== null) {
    const changed = structuredClone(rows); changed[index].data = Buffer.from('different final bytes').toString('base64');
    const archive = create(surface + '-member-' + index, changed), result = read(surface + '-member-' + index, archive, members);
    check(() => { assert.equal(result.status, 1); assert.equal(result.stdout.length, 0); });
  }
  const stored = create(surface + '-stored', rows.map(row => ({ ...row, stored: true })));
  const storedResult = read(surface + '-stored', stored, members);
  check(() => { assert.equal(storedResult.status, 0); assert.equal(storedResult.stderr.length, 0); });
  const corruptMetadata = `import sys,zipfile,struct
with zipfile.ZipFile(sys.argv[1]) as z:
 info=z.getinfo(sys.argv[3]);central=z.start_dir;count=len(z.infolist())
with open(sys.argv[1],'r+b') as f:
 offset=info.header_offset+(6 if sys.argv[2]=='encrypted' else 14)
 f.seek(offset);old=struct.unpack('<H' if sys.argv[2]=='encrypted' else '<I',f.read(2 if sys.argv[2]=='encrypted' else 4))[0]
 f.seek(offset);f.write(struct.pack('<H' if sys.argv[2]=='encrypted' else '<I',old|1 if sys.argv[2]=='encrypted' else old^1))
 for i in range(count):
  f.seek(central);header=f.read(46);assert header[:4]==b'PK\\x01\\x02'
  length,extra,comment=struct.unpack_from('<HHH',header,28)
  name=f.read(length).decode('utf-8')
  if name==sys.argv[3]:
   offset=central+(8 if sys.argv[2]=='encrypted' else 16)
   f.seek(offset);old=struct.unpack('<H' if sys.argv[2]=='encrypted' else '<I',f.read(2 if sys.argv[2]=='encrypted' else 4))[0]
   f.seek(offset);f.write(struct.pack('<H' if sys.argv[2]=='encrypted' else '<I',old|1 if sys.argv[2]=='encrypted' else old^1));break
  central+=46+length+extra+comment
 else: raise ValueError('Fixed fixture member not found')
`;
  for (const mode of ['encrypted', 'crc']) {
    const corrupted = path.join(root, surface + '-' + mode + '.zip'); fs.copyFileSync(stored, corrupted, fs.constants.COPYFILE_EXCL);
    const member = members.find(row => row.sha256 !== null).name;
    const altered = spawnSync(python, ['-I', '-B', '-c', corruptMetadata, corrupted, mode, member], { env: environment, windowsHide: true });
    assert.equal(altered.status, 0); assert.equal(altered.stderr.length, 0);
    const refused = read(surface + '-' + mode, corrupted, members);
    check(() => { assert.equal(refused.status, 1); assert.equal(refused.stdout.length, 0);
      assert.match(refused.stderr.toString('utf8'), mode === 'crc' ? /CRC/u : /unencrypted/u); });
  }
}
check(() => assert.throws(() => candidateArtifactMembers(JSON.parse(JSON.stringify(fixture.bundle)), 'core'), /observed by this validator/u));
check(() => assert.throws(() => candidateArtifactMembers(fixture.bundle, 'elsewhere'), /surface/u));

// Exercise the real Desktop prebundle orchestration with synthetic HTTP bodies.
// No network is performed: the built-in transport is restored after each case.
let desktopPreparationCases=0;
const httpsModule=(await import('node:https')).default;
const {EventEmitter}=await import('node:events');
const desktopNames=fixture.bundle.assets.filter(row=>row.path.startsWith('desktop/')).map(row=>row.path);
const desktopInput = name => {
  const dir=path.join(root,'desktop-input-'+name);fs.mkdirSync(dir);
  const files=desktopNames.map(relative=>{const bytes=fixture.files.get(relative),file=path.join(dir,path.posix.basename(relative));fs.writeFileSync(file,bytes,{flag:'wx'});return {path:relative,source_file:file,bytes:bytes.length,sha256:sha(bytes)};});
  const workflowFile=path.join(dir,'release-desktop.yml');fs.writeFileSync(workflowFile,workflowBytes,{flag:'wx'});
  const archiveFile=create('desktop-preparation-'+name,files.map(row=>({name:path.posix.basename(row.path),data:fs.readFileSync(row.source_file).toString('base64')})));
  return {namespaceRoot:dir,parentSession:'synthetic-desktop-session',pythonImage:python,observedPythonSha256:sha(fs.readFileSync(python)),
    parserFile:parser,observedParserSha256:sha(fs.readFileSync(parser)),sourceCommit,sourceTree,runId:11,runAttempt:2,
    workflow:{file:workflowFile,observed_sha256:workflowSha256},archive:{file:archiveFile,observed_sha256:sha(fs.readFileSync(archiveFile))},files};
};
const mockedDesktop = async (options,alter=(_endpoint,value)=>value) => {
  const previous=httpsModule.get, calls=[], data=metadata('desktop');data.run.event='workflow_dispatch';data.artifact.digest='sha256:'+options.archive.observed_sha256;
  httpsModule.get=(url,_options,callback)=>{
    assert.ok(url.startsWith(base+'/'));calls.push(url);
    const endpoint=url.slice(base.length), request=new EventEmitter();
    let value;
    if(endpoint==='/git/commits/'+sourceCommit)value=data.commit;
    else if(endpoint==='/contents/.github/workflows/release-desktop.yml?ref='+sourceCommit)value=data.workflow;
    else if(endpoint==='/actions/runs/11')value=data.run;
    else if(endpoint==='/actions/runs/11/artifacts?per_page=100&page=1')value={total_count:1,artifacts:[data.artifact]};
    else if(endpoint==='/actions/artifacts/12')value=data.artifact;
    else throw Error('Unexpected synthetic transport endpoint');
    value=alter(endpoint,structuredClone(value),calls);
    queueMicrotask(()=>{const response=new EventEmitter();response.statusCode=200;response.headers={date:'Sat, 03 Oct 2026 00:02:00 GMT'};callback(response);response.emit('data',Buffer.from(JSON.stringify(value)));response.emit('end');});
    return request;
  };
  try{return await observeGithubDesktopPreparation(fixture.contract,options);}finally{httpsModule.get=previous;desktopPreparationCases++;}
};
const desktopOptions=desktopInput('positive');
const desktopReceipt=await mockedDesktop(desktopOptions);
check(()=>{assert.equal(desktopReceipt.passed,true);assert.equal(desktopReceipt.assets.length,6);assert.equal(desktopReceipt.run,'11.2');assert.equal(desktopReceipt.source_commit,sourceCommit);assert.equal(desktopReceipt.publication_admitted,false);});
const desktopReceiptPin=revalidateObservedGithubDesktopPreparation(fixture.contract,desktopReceipt);
check(()=>{assert.equal(sha(fs.readFileSync(desktopReceiptPin.path)),desktopReceiptPin.sha256);assert.equal(fs.statSync(desktopReceiptPin.path).size,desktopReceiptPin.bytes);});
check(()=>assert.throws(()=>revalidateObservedGithubDesktopPreparation(fixture.contract,structuredClone(desktopReceipt)),/capability/));
await assert.rejects(()=>observeGithubDesktopPreparation(structuredClone(fixture.contract),desktopOptions));checks++;
const foreignContract=publicationFixture(process.argv[2]).contract;
check(()=>assert.throws(()=>revalidateObservedGithubDesktopPreparation(foreignContract,desktopReceipt),/capability/));
for(const [name,change] of [
  ['missing',x=>x.files.pop()],['duplicate',x=>{x.files[0]=x.files[1];}],
  ['extra',x=>x.files.push({...x.files[0],path:'desktop/extra'})],['case',x=>{x.files[0].path=x.files[0].path.toUpperCase();}],
  ['foreign-selector',x=>{x.repository='fork/winsmux';}],['callback',x=>{x.fetch=()=>{};}],
  ['wrong-source',x=>{x.sourceCommit='bad';}],['wrong-tree',x=>{x.sourceTree='bad';}],['wrong-run',x=>{x.runId=0;}],
  ['wrong-pin',x=>{x.files[0].sha256='0'.repeat(64);}],
  ['wrong-archive-pin',x=>{x.archive.observed_sha256='0'.repeat(64);}],
  ['aliased-physical',x=>{Object.assign(x.files[0],{source_file:x.files[1].source_file,bytes:x.files[1].bytes,sha256:x.files[1].sha256});}]
]) {const value=structuredClone(desktopOptions);change(value);await assert.rejects(()=>observeGithubDesktopPreparation(fixture.contract,value));checks++;}
for(const [name,change] of [
  ['commit',(_e,x)=>{if(x.tree)x.sha='0'.repeat(40);return x;}],
  ['workflow',(_e,x)=>{if(x.encoding)x.content+='!';return x;}],
  ['attempt',(_e,x)=>{if(x.run_attempt)x.run_attempt=1;return x;}],
  ['event',(_e,x)=>{if(x.run_attempt)x.event='push';return x;}],
  ['event-after',(e,x,calls)=>{if(e==='/actions/runs/11'&&calls.filter(url=>url.endsWith(e)).length===2)x.event='push';return x;}],
  ['artifact-name',(_e,x)=>{if(x.artifacts)x.artifacts[0].name+='-other';return x;}],
  ['artifact-digest',(_e,x)=>{if(x.artifacts)x.artifacts[0].digest='sha256:'+'0'.repeat(64);return x;}],
  ['pagination',(_e,x)=>{if(x.artifacts){x.total_count=2;x.artifacts=[];}return x;}],
  ['duplicate-artifact',(_e,x)=>{if(x.artifacts){x.total_count=2;x.artifacts.push({...x.artifacts[0]});}return x;}],
  ['changed-after',(e,x)=>{if(e==='/actions/artifacts/12')x.updated_at='2026-10-03T00:03:00Z';return x;}]
]) {const value=desktopInput(name),seen=await mockedDesktop(value,change);check(()=>{assert.equal(seen.passed,false);assert.throws(()=>revalidateObservedGithubDesktopPreparation(fixture.contract,seen),/capability/);});}
const during=desktopInput('physical-during');
await assert.rejects(()=>mockedDesktop(during,(e,x)=>{if(e==='/actions/artifacts/12')fs.appendFileSync(during.files[0].source_file,'changed');return x;}),/Artifact input|changed/);checks++;
for(const [name,select] of [['physical-after',(_r,o)=>o.files[0].source_file],['original-after',r=>r.originals[0].path],['receipt-after',(_r,_o,p)=>p.path]]){
 const value=desktopInput(name),seen=await mockedDesktop(value),pin=revalidateObservedGithubDesktopPreparation(fixture.contract,seen);
 fs.appendFileSync(select(seen,value,pin),'changed');check(()=>assert.throws(()=>revalidateObservedGithubDesktopPreparation(fixture.contract,seen),/Artifact input|changed/));
}

for (const name of sourceNames) check(() => assert.equal(sha(fs.readFileSync(name)), source[name]));
const result = { observed_at: new Date().toISOString(), passed: true, checks, native_cases: nativeCases, desktop_preparation_cases: desktopPreparationCases,
  python_sha256: sha(fs.readFileSync(python)), source_sha256: source, publication_admitted: false,
  scope: 'Three producer original-body validation plus Desktop prebundle orchestration over mocked HTTP and actual isolated Python closed ZIP inspection over synthetic distribution bytes. No hosted producer artifacts, actual distribution provenance, Windows verification, native permission or parent adoption claim.' };
const resultFile = path.join(root, 'candidate-artifacts-target-result.json'); fs.writeFileSync(resultFile, JSON.stringify(result), { flag: 'wx' });
console.log(JSON.stringify({ ...result, original_result_path: resultFile }));
