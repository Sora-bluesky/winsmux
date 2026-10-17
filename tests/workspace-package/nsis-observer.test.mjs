import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { admitDiagnostic, projectReturn, retainedOutputLimit, events, instrumentNsis, collectPrivate,
  assertPublicSummary, projectWitness, projectProcess, rebindCompilerText, projectNssGui, auditCompilerReferences, extractTransportModule, selectTransportLicenseRows, bindUiLicense, decodeCompilerText } from '../../scripts/desktop-native-nsis-observer.mjs';
const digest = x => createHash('sha256').update(x).digest('hex');
const sourceCommit='a'.repeat(40), sha='b'.repeat(64), fact={bytes:3,sha256:sha,identity:'1:2:3'};
const env={GITHUB_ACTIONS:'true',RUNNER_OS:'Windows',GITHUB_REPOSITORY:'Sora-bluesky/winsmux',
  GITHUB_REF:'refs/heads/codex/task880-native-lifecycle',GITHUB_SHA:sourceCommit,GITHUB_RUN_ID:'1',GITHUB_RUN_ATTEMPT:'1'};
const source=['OutFile "${OUTFILE}"',
  '  Call WinsmuxWriteInstallContext\n  nsExec::ExecToStack $WinsmuxCommand\n  Pop $0\n  Pop $1',
  '  Call un.WinsmuxWriteUninstallContext\n  nsExec::ExecToStack $WinsmuxCommand\n  Pop $0\n  Pop $1',
  '    SetErrorLevel 2\n    Abort "$(WINSMUX_TRANSACTION_FAILED)"\n  ${EndIf}\nFunctionEnd\n!macroend\n!insertmacro WINSMUX_WORKSPACE_FUNCTION',
  '    SetErrorLevel $2\n    Abort "$(WINSMUX_TRANSACTION_FAILED)"\n  ${EndIf}\nFunctionEnd\n!macroend\n!insertmacro WINSMUX_CONTEXT_FUNCTION'].join('\n');
const options={outputFile:'D:\\private\\diagnostic.exe',captureRoot:'D:\\private\\capture'};
function withCapture(fn){const parent=path.resolve(os.tmpdir()),root=fs.mkdtempSync(path.join(parent,'winsmux-nsis-observer-test-'));try{return fn(root)}finally{const resolved=path.resolve(root),stat=fs.lstatSync(resolved);assert.equal(path.dirname(resolved),parent);assert.ok(path.basename(resolved).startsWith('winsmux-nsis-observer-test-'));assert.ok(stat.isDirectory()&&!stat.isSymbolicLink());fs.rmSync(resolved,{recursive:true})}}
function eventFiles(root,event,exit='2',combined='winsmux installer: context_refused\n'){
  const dir=path.join(root,event);fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir,'exit.utf16'),Buffer.from(exit,'utf16le'));
  fs.writeFileSync(path.join(dir,'combined.utf16'),Buffer.from(combined,'utf16le'));return dir;
}
test('exact CI NSIS admission and every sibling refusal',()=>{
  assert.doesNotThrow(()=>admitDiagnostic(env,sourceCommit,'NSIS'));
  for(const [key,value] of Object.entries({GITHUB_ACTIONS:'false',RUNNER_OS:'Linux',GITHUB_REPOSITORY:'other/repo',GITHUB_REF:'refs/heads/main',GITHUB_SHA:'c'.repeat(40),GITHUB_RUN_ID:'0',GITHUB_RUN_ATTEMPT:'01'}))assert.throws(()=>admitDiagnostic({...env,[key]:value},sourceCommit,'NSIS'));
  for(const format of ['MSI','','nsis'])assert.throws(()=>admitDiagnostic(env,sourceCommit,format));
});
test('numeric error timeout unknown and bounded combined output',()=>{
  for(const value of ['0','2','201','4294967295'])assert.deepEqual([projectReturn(value,'').kind,projectReturn(value,'').code],['number',Number(value)]);
  for(const value of ['error','timeout'])assert.equal(projectReturn(value,'').kind,value);
  for(const value of ['-1','4294967296','01',' 2','2\n','','ERROR'])assert.equal(projectReturn(value,'').kind,'unobserved');
  assert.equal(projectReturn('2','winsmux installer: context_refused\n').reason,'context_refused');
  for(const value of ['private-path','winsmux installer: unknown\n','winsmux installer: context_refused\nextra']){const p=projectReturn('2',value);assert.equal(p.output,'rejected');assert.ok(!JSON.stringify(p).includes(value));}
  for(const n of [retainedOutputLimit-1,retainedOutputLimit,retainedOutputLimit+1]){const p=projectReturn('2','x'.repeat(n));assert.equal(p.held_utf16_units,Math.min(n,retainedOutputLimit));assert.equal(p.truncation,n>=retainedOutputLimit?'possible_at_limit':'not_at_limit');assert.equal(p.separate_streams_observed,false);}
  assert.throws(()=>projectReturn(2,''));
});
test('LF CRLF transform is exactly reversible and calls follow Pop',()=>{
  for(const eol of ['\n','\r\n']){const input=source.replaceAll('\n',eol),result=instrumentNsis(input,options);let inverse=result.source.replaceAll('\r\n','\n');assert.ok(inverse.endsWith(result.addition));inverse=inverse.slice(0,-result.addition.length);for(const c of result.changes.slice().reverse())inverse=inverse.replace(c.after,c.before);assert.equal(inverse.replaceAll('\n',eol),input);assert.equal(result.original_sha256,digest(Buffer.from(input)));assert.equal(result.changes.length,5);assert.equal(result.release_admissible,false);
    for(const prefix of ['','un.'])assert.ok(result.source.includes(['  nsExec::ExecToStack $WinsmuxCommand','  Pop $0','  Pop $1','  Call '+prefix+'WinsmuxObserve'].join(eol)));assert.equal(result.source.match(/Abort /gu).length,2);}
});
test('missing duplicate changed mixed EOL and repeated source refused',()=>{
  for(const input of [source.replace('  Pop $1','  Pop $2'),source+'\nOutFile "${OUTFILE}"',source.replace('    SetErrorLevel 2','    SetErrorLevel 3'),source+'\rX'])assert.throws(()=>instrumentNsis(input,options));
  assert.throws(()=>instrumentNsis(instrumentNsis(source,options).source,options));
  for(const value of ['','bad\npath','bad\0path'])assert.throws(()=>instrumentNsis(source,{...options,outputFile:value}));
});
test('all savers balance every register and restore flags after all best effort writes',()=>{
  const functions=[...instrumentNsis(source,options).addition.matchAll(/Function ([^\n]+)\n([\s\S]*?)\nFunctionEnd/gu)];assert.equal(functions.length,events.length);
  const regs=[...Array.from({length:10},(_,n)=>'$'+n),...Array.from({length:10},(_,n)=>'$R'+n)];
  for(const [,,body]of functions){assert.deepEqual([...body.matchAll(/^  Push (.+)$/gmu)].map(x=>x[1]),regs);assert.deepEqual([...body.matchAll(/^  Pop (.+)$/gmu)].map(x=>x[1]),regs.slice().reverse());assert.ok(body.includes('  GetErrorLevel $R9\n  IfErrors 0 +3'));assert.ok(body.includes('  SetErrorLevel $R9\n  ClearErrors\n  StrCmp $R8 0 +2 0\n  SetErrors\n  Pop $R9'));assert.ok(body.lastIndexOf('CopyFiles')<body.lastIndexOf('  SetErrorLevel $R9'));assert.ok(!/\b(?:Abort|Quit|Sleep|ExecWait|ExecToStack)\b/u.test(body));}
});
test('missing observations remain missing and refusal captures never claim callee return',()=>withCapture(root=>{
  assert.ok(collectPrivate(root,sourceCommit).observations.every(x=>x.status==='unobserved'&&x.returned===null));
  eventFiles(root,'uninstall-context-failure','201');const result=collectPrivate(root,sourceCommit);assert.equal(result.observations.find(x=>x.event==='uninstall-context-failure').returned,null);assert.equal(result.original_journey_passed,false);
}));
test('exact private-byte hashes with strict schema and no raw export',()=>withCapture(root=>{
  const dir=eventFiles(root,'uninstall-return','timeout','private-output'),bytes=Buffer.from('private-context-path');
  for(const name of ['context.bin','helper.exe','source-plan.bin','executable.exe'])fs.writeFileSync(path.join(dir,name),bytes);
  const result=collectPrivate(root,sourceCommit),row=result.observations.find(x=>x.event==='uninstall-return');assert.equal(row.status,'observed');assert.equal(row.returned.kind,'timeout');assert.deepEqual(row.context,{bytes:bytes.length,sha256:digest(bytes)});assert.ok(!JSON.stringify(result).includes('private-'));assert.doesNotThrow(()=>assertPublicSummary(result));
  for(const mutate of [x=>{x.secret='x'},x=>{x.release_admissible=true},x=>{x.original_journey_passed=true},x=>{x.observations[0].context={bytes:1,sha256:sha,path:'private'}}]){const bad=structuredClone(result);mutate(bad);assert.throws(()=>assertPublicSummary(bad));}
}));
test('partial save malformed UTF16 and hardlink cannot create successful observation',()=>withCapture(root=>{
  const dir=eventFiles(root,'install-return');fs.unlinkSync(path.join(dir,'combined.utf16'));assert.equal(collectPrivate(root,sourceCommit).observations[0].status,'unobserved');fs.writeFileSync(path.join(dir,'combined.utf16'),Buffer.from([1]));assert.equal(collectPrivate(root,sourceCommit).observations[0].status,'rejected');fs.unlinkSync(path.join(dir,'combined.utf16'));fs.linkSync(path.join(dir,'exit.utf16'),path.join(dir,'combined.utf16'));assert.equal(collectPrivate(root,sourceCommit).observations[0].status,'rejected');
}));
test('witness process projections discard roots actors registry and unknown member paths',()=>{
  const raw={root:'private-root',root_identity:'1:2:3',files:[{path:'winsmux.exe',...fact},{path:'private-name',...fact}],registration:[null,{private:'registry'}],shortcuts:[{private:'shortcut'},null],user_sentinel:fact};const p=projectWitness(raw,new Set(['winsmux.exe']));assert.equal(p.files.length,1);assert.equal(p.unlisted_files,1);assert.ok(!JSON.stringify(p).includes('private'));
  for(const value of ['../private','C:/private','/private','a//b'])assert.throws(()=>projectWitness(raw,new Set([value])));
  const receipt={purpose:'nsis-uninstall',exit_code:0,process:{pid:12,active_members:0,terminal:true,image_sha256:sha,image:'private-image',actor:{sid:'private-actor'}}},projected=projectProcess(receipt);assert.equal(projected.exit_code_scope,'retained_root_process');assert.equal(projected.helper_exit_observed,false);assert.ok(!JSON.stringify(projected).includes('private'));assert.throws(()=>projectProcess({...receipt,purpose:'msi-uninstall'}));
});


test('compiler reference rebinding is exact for empty/nonempty license and rejects siblings before execution',()=>{
  const maps=[{from:'C:\\source\\hooks.nsh',to:'D:\\private\\hooks.nsh'},
    {from:'C:\\source\\terms.txt',to:'D:\\private\\terms.txt'},
    {from:'C:\\build\\gui.exe',to:'D:\\private\\gui.exe'}];
  for(const license of ['', 'C:\\source\\terms.txt']){
    const input=['!include "C:\\source\\hooks.nsh"','!define MAINBINARYSRCPATH "C:\\build\\gui.exe"',
      '!define LICENSE "'+license+'"','!define UNINSTALLERSIGNCOMMAND "node --sign-asset %1 --unsigned"',
      '!if "${UNINSTALLERSIGNCOMMAND}" != ""',"  !uninstfinalize '${UNINSTALLERSIGNCOMMAND}'",'!endif'].join('\n');
    const result=rebindCompilerText(input,maps,{unsigned:true});
    assert.ok(!result.source.includes('C:\\source'));assert.ok(!result.source.includes('C:\\build'));assert.ok(result.source.includes('!define UNINSTALLERSIGNCOMMAND ""'));
    let inverse=result.source;for(const change of result.changes.slice().reverse()){const at=inverse.lastIndexOf(change.after);inverse=inverse.slice(0,at)+change.before+inverse.slice(at+change.after.length)}assert.equal(inverse,input);
    for(const suffix of ['\n!include "C:\\other\\unknown.nsh"','\n!include C:\\other\\unknown.nsh','\n!system "external"','\n!execute "external"','\n!packhdr "external"','\n!finalize "external"','\n!searchparse /file secret','\n!uninstfinalize "extra"'])assert.throws(()=>rebindCompilerText(input+suffix,maps,{unsigned:true}));
  }
  assert.throws(()=>rebindCompilerText('!include "C:\\source\\hooks.nsh"',[...maps,{from:maps[0].from.toUpperCase(),to:'D:\\other'}]));
});
test('NSS GUI projection changes only the single marker tag and matches canonical phase/plan hash',()=>{
  const raw=Buffer.from('prefix__TAURI_BUNDLE_TYPE_VAR_UNKsuffix'), projected=Buffer.from(raw);projected.write('NSS',raw.indexOf('UNK'),3,'ascii');
  const result=projectNssGui(raw,digest(raw),digest(projected),{bytes:raw.length,sha256:digest(projected)});
  assert.deepEqual(result,projected);assert.equal(raw.toString(),'prefix__TAURI_BUNDLE_TYPE_VAR_UNKsuffix');
  for(const input of [Buffer.from('missing'),Buffer.concat([raw,raw]),projected])assert.throws(()=>projectNssGui(input,digest(input),digest(projected),{bytes:raw.length,sha256:digest(projected)}));
  assert.throws(()=>projectNssGui(raw,digest(raw),'c'.repeat(64),{bytes:raw.length,sha256:digest(projected)}));
  assert.throws(()=>projectNssGui(raw,digest(raw),digest(projected),{bytes:raw.length+1,sha256:digest(projected)}));
});


test('compiler path spellings and reference domain reject escapes aliases ADS unknown macros and relative payloads',()=>{
  for(const value of ['D:\\private\\..\\escape','D:/private/file','D:\\private\\name:stream','\\\\server\\share\\file','D:\\private\\trailing.','D:\\private\\CON'])assert.throws(()=>rebindCompilerText('!include "C:\\source\\hooks.nsh"',[{from:'C:\\source\\hooks.nsh',to:value}]));
  const absolute=new Set(['D:\\private\\hooks.nsh','D:\\private\\payload.exe']),sdk=new Set(['mui2.nsh','win/com.nsh']);
  for(const line of ['!include MUI2.nsh','!include "Win\\COM.nsh"','!include "D:\\private\\hooks.nsh"','!include "${WINSMUX_NSIS_INPUTS}\\winsmux-utils.nsh"','  File /a "/oname=winsmux.exe" "D:\\private\\payload.exe"','  File "${WINSMUX_NSIS_HELPER_PATH}"'])assert.equal(auditCompilerReferences(line,absolute,sdk),true);
  for(const line of ['!include "../outside.nsh"','!include "${UNKNOWN}"','!include /NONFATAL "missing.nsh"','File "relative.txt"','File "${UNKNOWN}"','File /r "D:\\private\\payload.exe"','ReserveFile "private"'])assert.throws(()=>auditCompilerReferences(line,absolute,sdk));
});



test('every literal replacement entry preserves dollar template syntax and quote code units',()=>{
  const table=[["$","$$"],["$&","$$&"],["$'","$$'"],["$`","$$`"],["$$","$$$$"],["\"","$\\\""]];
  for(const [raw,encoded] of table){
    const output='D:\\private\\'+raw+'name.exe',capture='D:\\private\\'+raw+'capture';
    const result=instrumentNsis(source,{outputFile:output,captureRoot:capture});
    assert.ok(result.source.includes('OutFile "D:\\private\\'+encoded+'name.exe"'));
    assert.ok(result.addition.includes('D:\\private\\'+encoded+'capture\\install-return'));
    let inverse=result.source.slice(0,-result.addition.length);for(const c of result.changes.slice().reverse())inverse=inverse.replace(c.after,()=>c.before);assert.equal(inverse,source);
    const from='C:\\source\\'+raw+'payload.exe',to='D:\\private\\'+raw+'payload.exe',input='!define MAINBINARYSRCPATH "C:\\source\\'+encoded+'payload.exe"';
    if(raw==='"'){assert.throws(()=>rebindCompilerText(input,[{from,to}]));continue;}
    const rebound=rebindCompilerText(input,[{from,to}]);assert.equal(rebound.source,'!define MAINBINARYSRCPATH "D:\\private\\'+encoded+'payload.exe"');
    let back=rebound.source;for(const change of rebound.changes.slice().reverse()){const at=back.lastIndexOf(change.after);back=back.slice(0,at)+change.before+back.slice(at+change.after.length)}assert.equal(back,input);
  }
});


test('transport extraction reaches the actual candidate PowerShell here-string without executing it',()=>{
  const actual=fs.readFileSync(new URL('../../scripts/test-public-release.ps1',import.meta.url),'utf8');
  const normalized=actual.replaceAll('\r\n','\n'),opening="function Get-DesktopNativeTransportModule {\n    return @'\n",closing="\n'@\n}";
  const start=normalized.indexOf(opening);assert.ok(start>=0);assert.equal(normalized.indexOf(opening,start+1),-1);
  const end=normalized.indexOf(closing,start+opening.length);assert.ok(end>start);
  const expected=normalized.slice(start+opening.length,end),extracted=extractTransportModule(actual);
  assert.equal(extracted.replaceAll('\r\n','\n'),expected);
  assert.ok(extracted.startsWith("import fs from 'node:fs';"));
  assert.ok(extracted.includes("'native_transport_caller_refused'"));
  assert.ok(extracted.includes("'native_transport_source_or_copy_changed'"));
  assert.ok(extracted.includes("schema:'winsmux-desktop-native-transport-check/v1'"));
  assert.throws(()=>extractTransportModule(actual.replace(opening,()=>opening.replace("@'",()=>"$'"))));
  assert.throws(()=>extractTransportModule(actual+'\n'+opening+expected+closing));
});


test('license projection has no historical count and UI binds only to canonical content identity plus generated BOM file',()=>{
  const ui=Buffer.from('specific UI terms'),identity=digest(ui),textPath='licenses/texts/'+identity;
  const generation={files:[{path:'licenses/manifest.json',bytes:1,sha256:sha},{path:'licenses/THIRD_PARTY_NOTICES.txt',bytes:1,sha256:sha},{path:textPath,bytes:ui.length,sha256:identity}]};
  const rows=selectTransportLicenseRows(generation),plan={files:rows},rendered=Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),ui]);
  assert.equal(rows.length,generation.files.length);assert.deepEqual(bindUiLicense(ui,generation,plan,ui,rendered),{path:textPath,bytes:ui.length,sha256:identity});
  for(const bad of [{files:generation.files.slice(1)},{files:[...generation.files,generation.files[2]]}])assert.throws(()=>selectTransportLicenseRows(bad));
  for(const [source,canonical,generated]of [[Buffer.from('changed'),ui,rendered],[ui,Buffer.from('changed'),rendered],[ui,ui,ui],[ui,ui,Buffer.concat([Buffer.from([0xef,0xbb,0xbf]),rendered])]])assert.throws(()=>bindUiLicense(source,generation,plan,canonical,generated));
  for(const files of [[],rows.slice(0,2),[...rows,rows[2]],rows.map(row=>row.path===textPath?{...row,sha256:sha}:row),rows.map(row=>row.path===textPath?{...row,path:'licenses/MICROSOFT-COMPONENT-TERMS.txt'}:row)])assert.throws(()=>bindUiLicense(ui,generation,{files},ui,rendered));
});
test('compiler bytes keep BOM absence or presence with LF and CRLF across forward and inverse transform',()=>{
  for(const prefix of ['', '\ufeff'])for(const eol of ['\n','\r\n']){
    const original=Buffer.from(prefix+source.replaceAll('\n',eol)),decoded=decodeCompilerText(original);assert.deepEqual(Buffer.from(decoded),original);
    const instrumented=instrumentNsis(decoded,options);let inverse=instrumented.source.replaceAll('\r\n','\n');inverse=inverse.slice(0,-instrumented.addition.length);for(const change of instrumented.changes.slice().reverse())inverse=inverse.replace(change.after,()=>change.before);assert.deepEqual(Buffer.from(inverse.replaceAll('\n',eol)),original);
    const header=Buffer.from(prefix+'!define LICENSE "C:\\source\\license_file"'+eol),rebound=rebindCompilerText(decodeCompilerText(header),[{from:'C:\\source\\license_file',to:'D:\\private\\license_file'}]);let back=rebound.source;for(const change of rebound.changes.slice().reverse())back=back.replace(change.after,()=>change.before);assert.deepEqual(Buffer.from(back),header);
  }
  assert.throws(()=>decodeCompilerText(Buffer.from([0xff])));
});
