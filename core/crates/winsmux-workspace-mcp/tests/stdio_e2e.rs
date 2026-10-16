//! Executable stdio regression runner. Native lifetime classes are added here.
use std::process::{Command, Stdio};
#[cfg(all(windows, debug_assertions))]
#[path = "../../../tests-rs/support/conpty_json.rs"]
mod conpty_json;

fn main() {
    #[cfg(all(windows, debug_assertions))]
    if native::fixture_mode() { return; }
    let binary = env!("CARGO_BIN_EXE_winsmux-workspace-mcp");
    for arguments in [vec![], vec!["--fixture"], vec!["--discovery-json", "{}"],
        vec!["--discovery-json", "{\"schema_version\":1,\"schema_version\":1}"]] {
        let output = Command::new(binary).args(&arguments).stdin(Stdio::null()).output().expect("actual adapter");
        let expected = if arguments.first() == Some(&"--discovery-json") { 1 } else { 2 };
        assert_eq!(output.status.code(), Some(expected), "startup exit");
        assert!(output.stdout.is_empty(), "protocol stdout remains empty");
        let classification = if expected == 2 { "usage" } else { "protocol_failed" };
        assert_eq!(output.stderr, format!("winsmux workspace mcp: {classification}\n").as_bytes());
    }
    println!("actual stdio startup rejection cases passed; native lifetime class proof incomplete");
    #[cfg(all(windows, debug_assertions))]
    native::run(binary);
}

#[cfg(all(windows, debug_assertions))]
mod native {
    use super::*;
    use serde_json::{json, Value};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::{OsStrExt,OsStringExt};
    use std::os::windows::io::{FromRawHandle, OwnedHandle, AsRawHandle};
    use std::path::{Path, PathBuf};
    use std::ptr::{null, null_mut};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use std::thread::{self, JoinHandle};
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::Console::*;
    use windows_sys::Win32::System::IO::*;
    use windows_sys::Win32::System::Pipes::*;
    use windows_sys::Win32::System::Threading::*;
    use windows_sys::Win32::System::Diagnostics::ToolHelp::*;
    use windows_sys::Win32::Security::Cryptography::*;
    use sha2::{Digest, Sha256};
    use winsmux_workspace::host::testing::canonical_discovery_json;
    use winsmux_workspace_mcp::testing::{GatePoint, RuntimeGates};
    static NEXT: AtomicU64 = AtomicU64::new(1);

    use super::conpty_json;

    struct Handle(HANDLE);
    unsafe impl Send for Handle {}
    unsafe impl Sync for Handle {}
    impl Handle {
        fn raw(&self)->HANDLE {self.0}
        fn new(raw: HANDLE) -> Self { assert!(!raw.is_null() && raw != INVALID_HANDLE_VALUE, "native handle error {}", unsafe {GetLastError()}); Self(raw) }
        fn event() -> Self { Self::new(unsafe {CreateEventW(null(),1,0,null())}) }
        fn duplicate(&self, access: u32, same: bool) -> Self {
            let mut output = null_mut(); let process = unsafe {GetCurrentProcess()};
            assert_ne!(unsafe {DuplicateHandle(process,self.0,process,&mut output,access,0,if same {DUPLICATE_SAME_ACCESS} else {0})},0);
            Self::new(output)
        }
        fn stdio(self) -> Stdio {
            let raw = self.0; std::mem::forget(self);
            Stdio::from(unsafe {OwnedHandle::from_raw_handle(raw)})
        }
    }
    impl Drop for Handle { fn drop(&mut self) { unsafe {CloseHandle(self.0);} } }
    fn wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(Some(0)).collect() }
    fn execution(value:Value) {
        let path=std::env::var_os("TASK875_EXECUTION_RECEIPT").expect("owned execution receipt path");
        let mut file=std::fs::OpenOptions::new().append(true).open(path).unwrap();
        file.write_all(&serde_json::to_vec(&value).unwrap()).unwrap();file.write_all(b"\n").unwrap();file.flush().unwrap();
    }
    fn process_identity(process:HANDLE)->Value {
        let mut creation:FILETIME=unsafe {zeroed()};let mut exit:FILETIME=unsafe {zeroed()};let mut kernel:FILETIME=unsafe {zeroed()};let mut user:FILETIME=unsafe {zeroed()};
        assert_ne!(unsafe {GetProcessTimes(process,&mut creation,&mut exit,&mut kernel,&mut user)},0);
        json!({"pid":unsafe {GetProcessId(process)},"creation_filetime":((creation.dwHighDateTime as u64)<<32)|creation.dwLowDateTime as u64})
    }
    fn process_entries()->Vec<(u32,u32)> {
        let snapshot=Handle::new(unsafe {CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)});
        let mut entry:PROCESSENTRY32W=unsafe {zeroed()};entry.dwSize=size_of::<PROCESSENTRY32W>() as u32;
        let mut entries=Vec::new();let mut more=unsafe {Process32FirstW(snapshot.0,&mut entry)};
        while more!=0 {entries.push((entry.th32ProcessID,entry.th32ParentProcessID));more=unsafe {Process32NextW(snapshot.0,&mut entry)};}
        entries
    }
    fn owned_descendants(parent:u32)->Vec<Handle> {
        let entries=process_entries();let mut ids=vec![parent];let mut index=0;
        while index<ids.len() {let current=ids[index];for &(pid,ppid) in &entries {if ppid==current&&!ids.contains(&pid){ids.push(pid);}}index+=1;}
        ids.into_iter().skip(1).map(|pid|Handle::new(unsafe {OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,0,pid)})).collect()
    }
    fn process_image(handle:&Handle)->PathBuf {
        let mut path=vec![0u16;32768];let mut count=path.len() as u32;
        assert_ne!(unsafe {QueryFullProcessImageNameW(handle.0,0,path.as_mut_ptr(),&mut count)},0);
        PathBuf::from(std::ffi::OsString::from_wide(&path[..count as usize]))
    }
    fn fixture_conhosts()->Vec<Handle> {
        process_entries().into_iter().filter(|(_,parent)|*parent==std::process::id())
            .map(|(pid,_)|Handle::new(unsafe {OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,0,pid)}))
            .filter(|process|process_image(process).file_name().is_some_and(|name|name.to_string_lossy().eq_ignore_ascii_case("conhost.exe")))
            .collect()
    }
    fn new_fixture_conpty(baseline:&[Handle])->Handle {
        let before:Vec<_>=baseline.iter().map(|process|process_identity(process.0)).collect();
        let mut new:Vec<_>=fixture_conhosts().into_iter()
            .filter(|process|!before.contains(&process_identity(process.0))).collect();
        assert_eq!(new.len(),1,"one newly created fixture ConPTY, excluding preexisting child consoles");
        let console=new.pop().unwrap();
        assert!(process_entries().contains(&(unsafe {GetProcessId(console.0)},std::process::id())),"new ConPTY still belongs to fixture");
        execution(json!({"stage":"owned ConPTY classified","conpty":process_identity(console.0),"baseline":before,"proof":"direct parent, conhost image, creation FILETIME and held HANDLE"}));
        console
    }
    fn unique(label: &str) -> String { format!("task875-{label}-{}-{}",std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed)) }
    struct ProviderThreads { handles:Vec<(Handle,Value)>, complete:bool }
    impl ProviderThreads {
        fn merge(&mut self,other:Self) {self.complete&=other.complete;for pair in other.handles {if !self.handles.iter().any(|(_,identity)|*identity==pair.1){self.handles.push(pair);}}}
    }
    fn provider_threads(backend:&Handle)->ProviderThreads {
        let identity=process_identity(backend.raw());let image=process_image(backend);let image_sha=format!("{:x}",Sha256::digest(std::fs::read(&image).unwrap()));
        assert_eq!(image,PathBuf::from(std::env::var_os("TASK875_CLI_BIN").unwrap()));assert_eq!(image_sha,std::env::var("TASK875_CLI_SHA256").unwrap(),"provider snapshot exact original CLI/backend image");
        assert_eq!(unsafe {WaitForSingleObject(backend.raw(),0)},WAIT_TIMEOUT,"exact backend must remain alive while collecting provider threads");
        let snapshot=Handle::new(unsafe {CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,0)});
        let mut entry:THREADENTRY32=unsafe {zeroed()};entry.dwSize=size_of::<THREADENTRY32>() as u32;
        let mut more=unsafe {Thread32First(snapshot.raw(),&mut entry)};let mut result=ProviderThreads{handles:Vec::new(),complete:true};let mut rows=Vec::new();
        while more!=0 {
            if entry.th32OwnerProcessID==identity["pid"].as_u64().unwrap() as u32 {
                let raw=unsafe {OpenThread(THREAD_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,0,entry.th32ThreadID)};
                if raw.is_null() {result.complete=false;rows.push(json!({"thread_id":entry.th32ThreadID,"open_error":unsafe {GetLastError()},"completion":"unobserved"}));}
                else {
                    let handle=Handle::new(raw);let mut creation:FILETIME=unsafe {zeroed()};let mut exit:FILETIME=unsafe {zeroed()};let mut kernel:FILETIME=unsafe {zeroed()};let mut user:FILETIME=unsafe {zeroed()};let mut description=null_mut();
                    let owned=unsafe {GetProcessIdOfThread(handle.raw())}==identity["pid"].as_u64().unwrap() as u32;
                    let times=unsafe {GetThreadTimes(handle.raw(),&mut creation,&mut exit,&mut kernel,&mut user)}!=0;
                    let hresult=unsafe {GetThreadDescription(handle.raw(),&mut description)};
                    let name=if hresult>=0&&!description.is_null() {let mut length=0;unsafe {while *description.add(length)!=0 {length+=1;}}String::from_utf16(unsafe {std::slice::from_raw_parts(description,length)}).unwrap()}else{String::new()};
                    if !description.is_null() {unsafe {LocalFree(description.cast());}}
                    let named=matches!(name.as_str(),"winsmux-version-codex"|"winsmux-version-claude"|"winsmux-version-output");
                    let row=json!({"thread_id":entry.th32ThreadID,"creation_filetime":((creation.dwHighDateTime as u64)<<32)|creation.dwLowDateTime as u64,"name":name,"hresult":hresult,"same_backend":owned,"times_observed":times,"provider_named":named,"wait0":unsafe {WaitForSingleObject(handle.raw(),0)}});
                    if !owned||!times||hresult<0 {result.complete=false;}
                    if named&&owned&&times&&hresult>=0 {result.handles.push((handle,row.clone()));}
                    rows.push(row);
                }
            }
            more=unsafe {Thread32Next(snapshot.raw(),&mut entry)};
        }
        assert_eq!(unsafe {GetLastError()},ERROR_NO_MORE_FILES);assert_eq!(process_identity(backend.raw()),identity);assert_eq!(process_image(backend),image);
        execution(json!({"stage":"owned provider thread inventory","backend":identity,"binary_sha256":image_sha,"threads":rows,"observed_named_handles":result.handles.len(),"query_complete":result.complete,"empty_is_completion_proof":false,"public_stop_is_final_authority":true}));result
    }
    fn wait_providers_with_recovery(owner:&mut CliOwner,pipe:&Handle,name:&str,providers:ProviderThreads) {
        // Main serves the existing bounded recovery protocol while this observer
        // waits only actual named provider HANDLEs. Its self-owned status request
        // wakes main after completion; it never dispatches an owner request.
        let state=Arc::new(std::sync::atomic::AtomicU8::new(0));let worker_state=state.clone();let name=name.to_owned();
        let observer=thread::spawn(move || {
            let completed=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                for (handle,identity) in providers.handles {assert_eq!(unsafe {WaitForSingleObject(handle.raw(),INFINITE)},WAIT_OBJECT_0);execution(json!({"stage":"owned named provider thread actual completion","thread":identity}));}
            })).is_ok();worker_state.store(if completed{1}else{2},Ordering::SeqCst);
            let path=wide(&name);let client=loop {let raw=unsafe {CreateFileW(path.as_ptr(),GENERIC_READ|GENERIC_WRITE,0,null(),OPEN_EXISTING,0,null_mut())};if raw!=INVALID_HANDLE_VALUE {break Handle::new(raw);}assert_eq!(unsafe {GetLastError()},ERROR_PIPE_BUSY);assert_ne!(unsafe {WaitNamedPipeW(path.as_ptr(),NMPWAIT_WAIT_FOREVER)},0);};
            let mut server=0;assert_ne!(unsafe {GetNamedPipeServerProcessId(client.raw(),&mut server)},0);assert_eq!(server,std::process::id());write_bytes(&client,b"status\n");
            let mut reply=Vec::new();BufReader::new(PipeRead(client)).take(4097).read_until(b'\n',&mut reply).unwrap();assert!(reply.len()<=4096&&reply.last()==Some(&b'\n'));
            let response:Value=serde_json::from_slice(&reply).unwrap();assert_eq!(response["provider_observer_complete"],true);completed
        });
        owner.provider_progress=Some(state.clone());owner.provider_observer=Some(observer);
        while owner.provider_observer.is_some() {
            serve_provider_recovery(owner,pipe);
        }
    }
    fn serve_provider_recovery(owner:&mut CliOwner,pipe:&Handle) {
            let state=owner.provider_progress.as_ref().unwrap().clone();
            if unsafe {ConnectNamedPipe(pipe.raw(),null_mut())}==0 {assert_eq!(unsafe {GetLastError()},ERROR_PIPE_CONNECTED);}
            let mut client=0;assert_ne!(unsafe {GetNamedPipeClientProcessId(pipe.raw(),&mut client)},0);let mut command=[0u8;64];let mut count=0;
            let read=unsafe {ReadFile(pipe.raw(),command.as_mut_ptr(),64,&mut count,null_mut())};
            if read==0 {assert_eq!(unsafe {GetLastError()},ERROR_BROKEN_PIPE);unsafe {DisconnectNamedPipe(pipe.raw());}return;}
            let command=&command[..count as usize];assert!(command==b"status\n"||command==b"cleanup\n","bounded owned recovery command");
            let complete=state.load(Ordering::SeqCst)!=0;let self_notification=client==std::process::id()&&command==b"status\n"&&complete;
            let response=json!({"cleanup_complete":false,"owner":process_identity(owner.process.raw()),"only_owned_public_cleanup":true,"provider_wait_pending":!complete,"provider_observer_complete":complete,"public_stop_resend":false});let mut bytes=serde_json::to_vec(&response).unwrap();bytes.push(b'\n');write_bytes(pipe,&bytes);assert_ne!(unsafe {FlushFileBuffers(pipe.raw())},0);unsafe {DisconnectNamedPipe(pipe.raw());}
            execution(json!({"stage":"provider wait recovery response","response":response,"self_completion_notification":self_notification}));
            let finished=owner.provider_observer.as_ref().unwrap().is_finished();
            if self_notification||(complete&&finished) {
                let result=owner.provider_observer.take().unwrap().join();owner.provider_progress.take();
                execution(json!({"stage":"provider observer actual thread joined","observer_success":result.as_ref().ok(),"public_stop_reassessment_permitted":matches!(&result,Ok(true))}));
                assert!(matches!(result,Ok(true)),"actual provider observer failed; retain public recovery route");
            }
    }
    fn anonymous() -> (Handle,Handle) {
        let mut read = null_mut(); let mut write = null_mut();
        assert_ne!(unsafe {CreatePipe(&mut read,&mut write,null(),0)},0);
        (Handle::new(read),Handle::new(write))
    }
    fn write_bytes(handle: &Handle, bytes: &[u8]) {
        let mut done = 0;
        assert_ne!(unsafe {WriteFile(handle.0,bytes.as_ptr(),bytes.len() as u32,&mut done,null_mut())},0);
        assert_eq!(done as usize,bytes.len());
    }
    struct PipePair { input:Handle, writer:Handle }
    struct PipeRead(Handle);
    impl Read for PipeRead {
        fn read(&mut self,buffer:&mut [u8]) -> std::io::Result<usize> {
            let mut count=0;
            if unsafe {ReadFile(self.0.0,buffer.as_mut_ptr(),buffer.len() as u32,&mut count,null_mut())}!=0 {return Ok(count as usize);}
            let error=unsafe {GetLastError()};if error==ERROR_BROKEN_PIPE {Ok(0)}else{Err(std::io::Error::from_raw_os_error(error as i32))}
        }
    }
    // CLI owner, private host backend and fixture-owned ConPTY are distinct
    // roles. None of their processes may be waited before an accepted stop.
    // Provider workers are owned by the backend and joined by host.stop itself;
    // a process tree snapshot never proves provider worker completion.
    fn receive_owned_json(process:HANDLE,input:&mut Option<Handle>,pseudoconsole:&mut HPCON,output:&mut conpty_json::JsonOutput)->Result<Value,conpty_json::ChildExit> {
        match output.next_json_with_process(process) {
            Ok(value)=>Ok(value),
            Err(exit) if exit.signaled=>{
                // The final ConPTY chunk can arrive after the client exit signal.
                // Reuse the host/runtime fixture's drain, only after actual exit.
                execution(json!({"stage":"owned exited client final output drain","reason":exit.reason,"exit_code":exit.exit_code}));
                input.take();
                if *pseudoconsole!=0 {unsafe {ClosePseudoConsole(*pseudoconsole);}*pseudoconsole=0;}
                output.join_nonpanic();
                output.finish_json_after_reader_join().ok_or(exit)
            },
            Err(exit)=>Err(exit),
        }
    }
    struct CliOwner { process:Handle, backend:Handle, consoles:Vec<Handle>, canary:Option<Handle>, owned_projects:Vec<String>, owned_panes:Vec<String>, owned_directories:Vec<PathBuf>, pseudoconsole:HPCON, input:Option<Handle>, output:conpty_json::JsonOutput, discovery:Value, revision:u64, provider_observer:Option<JoinHandle<bool>>, provider_progress:Option<Arc<std::sync::atomic::AtomicU8>> }
    struct StartingCliOwner {
        baseline:Vec<Handle>,console:Option<Handle>,process:Option<Handle>,backend:Option<Handle>,
        pseudoconsole:HPCON,input:Option<Handle>,output:Option<conpty_json::JsonOutput>,discovery:Option<Value>,
        stop_attempted:bool,output_joined:bool,output_join_failed:bool,conpty_unproven:bool,
    }
    impl StartingCliOwner {
        fn new(baseline:Vec<Handle>,input:Handle)->Self {
            Self{baseline,console:None,process:None,backend:None,pseudoconsole:0,input:Some(input),output:None,discovery:None,stop_attempted:false,output_joined:false,output_join_failed:false,conpty_unproven:false}
        }
        fn into_owner(&mut self)->CliOwner {
            let baseline:Vec<_>=self.baseline.iter().map(|process|process_identity(process.0)).collect();
            execution(json!({"stage":"preexisting fixture consoles excluded","baseline":baseline,"owned_conpty":process_identity(self.console.as_ref().unwrap().0)}));
            let owner=CliOwner{process:self.process.take().unwrap(),backend:self.backend.take().unwrap(),consoles:vec![self.console.take().unwrap()],canary:None,owned_projects:Vec::new(),owned_panes:Vec::new(),owned_directories:Vec::new(),pseudoconsole:self.pseudoconsole,input:self.input.take(),output:self.output.take().unwrap(),discovery:self.discovery.take().unwrap(),revision:0,provider_observer:None,provider_progress:None};
            self.pseudoconsole=0;owner
        }
        fn close_console(&mut self) {
            self.input.take();
            if self.pseudoconsole!=0 {unsafe {ClosePseudoConsole(self.pseudoconsole);}self.pseudoconsole=0;}
        }
        fn request_stop_if_possible(&mut self) {
            if self.stop_attempted {return;}self.stop_attempted=true;
            let (Some(process),Some(discovery),Some(input))=(&self.process,&self.discovery,&self.input) else {return;};
            if self.output.is_none(){return;}
            let request=request(discovery["instance_id"].as_str(),Some(0),"host.stop",json!({}));
            let parsed=winsmux_workspace::contract::parse_request(&serde_json::to_vec(&request).unwrap()).unwrap();
            let mut bytes=winsmux_workspace::contract::canonical_request(&parsed).unwrap();bytes.extend_from_slice(b"\r\n");
            write_bytes(input,&bytes);
            let response=receive_owned_json(process.0,&mut self.input,&mut self.pseudoconsole,self.output.as_mut().unwrap());
            let accepted=response.as_ref().ok().is_some_and(|value|value["accepted"]==true && winsmux_workspace::contract::parse_response(&parsed,&serde_json::to_vec(value).unwrap()).is_ok());
            execution(json!({"stage":"partial owner canonical stop attempted","owner":process_identity(process.0),"accepted":accepted,"reply":response.as_ref().ok(),"read_failure":response.as_ref().err().map(|error|format!("{error:?}"))}));
        }
        fn all_owned_exited(&self)->bool {
            self.process.iter().chain(self.backend.iter()).chain(self.console.iter())
                .all(|process|unsafe {WaitForSingleObject(process.0,0)}==WAIT_OBJECT_0)
        }
        fn finish_if_exited(&mut self)->bool {
            if self.conpty_unproven {return false;}
            if !self.all_owned_exited(){return false;}
            if self.output_join_failed {return false;}
            if !self.output_joined {
                if let Some(output)=&mut self.output {
                    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(||output.join())).is_err() {
                        self.output_join_failed=true;return false;
                    }
                }
                self.output_joined=true;
            }
            let owner=self.process.as_ref().map(|process|process_identity(process.0));
            let backend=self.backend.as_ref().map(|process|process_identity(process.0));
            let console=self.console.as_ref().map(|process|process_identity(process.0));
            let baseline:Vec<_>=self.baseline.iter().map(|process|process_identity(process.0)).collect();
            execution(json!({"stage":"partial owner cleanup completed","owner":owner,"backend":backend,"conpty":console,"preexisting_untouched":baseline,"output_joined":true,"force_kill":false}));
            true
        }
        fn cleanup_or_recover(&mut self,recovery:&Handle,recovery_name:&str) {
            let stop=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||self.request_stop_if_possible()));
            if stop.is_err(){execution(json!({"stage":"partial owner stop path failed; closing owned console","recovery_pipe":recovery_name}));}
            self.close_console();
            if self.conpty_unproven && self.process.is_none() {
                execution(json!({"stage":"partial ConPTY attribution unproven; no unknown process stopped or awaited","recovery_pipe":recovery_name,"original_failure_preserved":true}));
                return;
            }
            if self.finish_if_exited(){return;}
            recover_startup(self,recovery,recovery_name);
        }
    }
    impl Drop for StartingCliOwner {
        fn drop(&mut self) {if self.pseudoconsole!=0 {eprintln!("TASK875 partial owner still holds ConPTY; use the recorded recovery pipe");}}
    }
    fn quoted(text:&str) -> String {
        let mut result=String::from("\"");let mut slashes=0;
        for character in text.chars() {
            if character=='\\' {slashes+=1;continue;}
            if character=='"' {result.extend(std::iter::repeat_n('\\',slashes*2+1));result.push('"');}
            else {result.extend(std::iter::repeat_n('\\',slashes));result.push(character);}slashes=0;
        }
        result.extend(std::iter::repeat_n('\\',slashes*2));result.push('"');result
    }
    impl CliOwner {
        fn start(binary:&Path,recovery:&Handle,recovery_name:&str) -> Self {
            let (console_input,parent_writer)=anonymous();let (parent_reader,console_output)=anonymous();
            let mut pending=StartingCliOwner::new(fixture_conhosts(),parent_writer);
            let started=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut pseudoconsole=0;
            assert_eq!(unsafe {CreatePseudoConsole(COORD{X:4096,Y:24},console_input.0,console_output.0,PSEUDOCONSOLE_INHERIT_CURSOR,&mut pseudoconsole)},0);
            pending.pseudoconsole=pseudoconsole;
            pending.conpty_unproven=true;
            drop(console_input);drop(console_output);
            pending.console=Some(new_fixture_conpty(&pending.baseline));
            pending.conpty_unproven=false;
            let mut attribute_bytes=0;
            unsafe {InitializeProcThreadAttributeList(null_mut(),1,0,&mut attribute_bytes);}
            let mut attributes=vec![0usize;attribute_bytes.div_ceil(size_of::<usize>())];
            let list=attributes.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
            assert_ne!(unsafe {InitializeProcThreadAttributeList(list,1,0,&mut attribute_bytes)},0);
            let updated=unsafe {UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                pseudoconsole as *const _,size_of::<HPCON>(),null_mut(),null())};
            if updated==0 {unsafe {DeleteProcThreadAttributeList(list);}panic!("ConPTY process attribute update failed");}
            let mut startup:STARTUPINFOEXW=unsafe {zeroed()};startup.StartupInfo.cb=size_of::<STARTUPINFOEXW>() as u32;startup.lpAttributeList=list;
            // Match the adopted ConPTY launcher: suppress inherited redirected
            // standard handles so the console supplies its own stdin/stdout.
            startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
            startup.StartupInfo.hStdInput=INVALID_HANDLE_VALUE;
            startup.StartupInfo.hStdOutput=INVALID_HANDLE_VALUE;
            startup.StartupInfo.hStdError=INVALID_HANDLE_VALUE;
            let mut information:PROCESS_INFORMATION=unsafe {zeroed()};
            let application:Vec<u16>=binary.as_os_str().encode_wide().chain(Some(0)).collect();
            let mut command=wide(&format!("{} workspace host",quoted(&binary.to_string_lossy())));
            let created=unsafe {CreateProcessW(application.as_ptr(),command.as_mut_ptr(),null(),null(),0,
                EXTENDED_STARTUPINFO_PRESENT,null(),null(),&startup.StartupInfo,&mut information)};
            unsafe {DeleteProcThreadAttributeList(list);}
            assert_ne!(created,0,"spawn actual CLI ConPTY owner");
            unsafe {CloseHandle(information.hThread);}
            pending.process=Some(Handle::new(information.hProcess));
            execution(json!({"stage":"owner process created","owner":process_identity(pending.process.as_ref().unwrap().0),"exe_sha256":std::env::var("TASK875_CLI_SHA256").unwrap()}));
            pending.output=Some(conpty_json::JsonOutput::start(Box::new(PipeRead(parent_reader))));
            write_bytes(pending.input.as_ref().unwrap(),b"\x1b[1;1R");
            let discovery=receive_owned_json(pending.process.as_ref().unwrap().0,&mut pending.input,&mut pending.pseudoconsole,pending.output.as_mut().unwrap())
                .unwrap_or_else(|exit|panic!("CLI discovery before process exit: {exit:?}"));
            assert_eq!(discovery["schema_version"],1);assert_eq!(discovery.as_object().unwrap().len(),3);
            pending.discovery=Some(discovery);
            execution(json!({"stage":"owner spawned","owner":process_identity(pending.process.as_ref().unwrap().0),"exe_sha256":std::env::var("TASK875_CLI_SHA256").unwrap(),"instance_id":pending.discovery.as_ref().unwrap()["instance_id"]}));
            let entries=process_entries();let owner_pid=unsafe {GetProcessId(pending.process.as_ref().unwrap().0)};
            let mut backends:Vec<_>=entries.iter().filter(|(_,parent)|*parent==owner_pid)
                .map(|(pid,_)|Handle::new(unsafe {OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,0,*pid)}))
                .filter(|h|process_image(h)==binary).collect();
            assert_eq!(backends.len(),1,"one private host backend from the known CLI spawn path");
            pending.backend=Some(backends.pop().unwrap());
            execution(json!({"stage":"owned owner roles registered","owner":process_identity(pending.process.as_ref().unwrap().0),"backend":process_identity(pending.backend.as_ref().unwrap().0),"consoles":[process_identity(pending.console.as_ref().unwrap().0)],"provider_worker_completion":"host.stop owns worker joins; not inferred from descendant PIDs"}));
            pending.into_owner()
            }));
            match started {Ok(owner)=>owner,Err(original)=>{
                execution(json!({"stage":"partial owner startup failed","owner":pending.process.as_ref().map(|p|process_identity(p.0)),"conpty":pending.console.as_ref().map(|p|process_identity(p.0)),"recovery_pipe":recovery_name,"original_failure_preserved":true}));
                pending.cleanup_or_recover(recovery,recovery_name);
                std::panic::resume_unwind(original);
            }}
        }
        fn transact(&mut self,operation:&str,params:Value) -> Value {
            let request=request(self.discovery["instance_id"].as_str(),Some(self.revision),operation,params);
            let parsed=winsmux_workspace::contract::parse_request(&serde_json::to_vec(&request).unwrap()).unwrap();
            let mut bytes=winsmux_workspace::contract::canonical_request(&parsed).unwrap();bytes.extend_from_slice(b"\r\n");
            write_bytes(self.input.as_ref().unwrap(),&bytes);
            let value=receive_owned_json(self.process.0,&mut self.input,&mut self.pseudoconsole,&mut self.output).expect("actual correlated owner reply");
            if operation=="host.stop" {execution(json!({"stage":"owner stop response observed","request":request,"response":value}));}
            if operation=="connection.decide"||operation=="connection.revoke" {execution(json!({"stage":"actual owner authority decision observed","request":request,"response":value,"normal_parsed_before_send":true}));}
            winsmux_workspace::contract::parse_response(&parsed,&serde_json::to_vec(&value).unwrap()).expect("owner response correlation");
            self.revision=value["topology_revision"].as_u64().unwrap();value
        }
        fn success(&mut self,operation:&str,params:Value) -> Value {
            if operation=="project.open" {assert!(Path::new(params["path"].as_str().unwrap()).starts_with(PathBuf::from(std::env::var_os("TASK875_NATIVE_PROJECT_PATH").unwrap())));}
            let value=self.transact(operation,params);assert_eq!(value["accepted"],true,"owner {operation}: {value}");
            if operation=="project.open" {let id=value["result"]["data"]["project_id"].as_str().unwrap().to_owned();if !self.owned_projects.contains(&id){self.owned_projects.push(id);}}
            if operation=="pane.create" {self.owned_panes.push(value["result"]["data"]["pane_id"].as_str().unwrap().to_owned());}
            value
        }
        fn snapshot(&mut self,project:&str,run:&str) -> Value {
            let projects=self.success("project.list",json!({}));
            let mut panes=self.success("pane.list",json!({"project_id":project}));
            // Observation timestamps/work evidence advance without topology changes.
            // Protect pane/project/run identity and process state, not sample time.
            for pane in panes["result"]["data"]["panes"].as_array_mut().unwrap() {
                if let Some(observation)=pane["observation"].as_object_mut() {
                    observation.remove("observed_at");observation.remove("work");observation.remove("evidence");
                }
            }
            let observed=self.success("run.get",json!({"run_id":run}));
            assert_eq!(observed["result"]["data"]["run"]["process"],"running");
            assert_eq!(unsafe {WaitForSingleObject(self.process.0,0)},WAIT_TIMEOUT,"owner alive");
            assert_eq!(unsafe {WaitForSingleObject(self.backend.0,0)},WAIT_TIMEOUT,"backend alive");
            if let Some(canary)=&self.canary {assert_eq!(unsafe {WaitForSingleObject(canary.0,0)},WAIT_TIMEOUT,"actual canary process alive");}
            json!({"instance":self.discovery["instance_id"],"revision":self.revision,"projects":projects["result"]["data"],"panes":panes["result"]["data"],"run_id":observed["result"]["data"]["run"]["run_id"],"process":observed["result"]["data"]["run"]["process"]})
        }
        fn register_canary(&mut self,pane:&str,run:&str) {
            // Observe the actual shell PID through the authorized owner input /
            // output path. An arbitrary owner descendant is not a canary PID.
            self.success("input.write",json!({"pane_id":pane,"run_id":run,"text":"Write-Output ('TASK875_PID_' + $PID)\r"}));
            let mut cursor=Value::Null;let mut text=String::new();
            let pid=loop {
                let reply=self.success("output.read",json!({"run_id":run,"cursor":cursor,"max_bytes":4096}));
                let data=&reply["result"]["data"];assert_eq!(data["gap"],false);assert_eq!(data["truncated"],false);
                text.push_str(data["text"].as_str().unwrap());cursor=data["next_cursor"].clone();
                let mut found=None;
                for part in text.split("TASK875_PID_").skip(1) {
                    let digits:String=part.chars().take_while(|c|c.is_ascii_digit()).collect();
                    if !digits.is_empty() {found=Some(digits.parse::<u32>().unwrap());break;}
                }
                if let Some(pid)=found {break pid;}
                let tail:String=text.chars().rev().take("TASK875_PID_".len()+u32::MAX.to_string().len()).collect();
                text=tail.chars().rev().collect();
                thread::yield_now();
            };
            let canary=Handle::new(unsafe {OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,0,pid)});
            assert!(process_image(&canary).file_name().is_some_and(|s|s.to_string_lossy().eq_ignore_ascii_case("pwsh.exe")));
            assert!(process_entries().contains(&(pid,unsafe {GetProcessId(self.backend.0)})),"canary shell belongs to this private backend");
            execution(json!({"stage":"actual canary process registered","canary":process_identity(canary.0),"backend":process_identity(self.backend.0),"pane_id":pane,"run_id":run,"observation":"authorized owner input/output PID marker plus actual parent/image/HANDLE identity"}));
            self.canary=Some(canary);
        }
        fn collect_terminated(&mut self) {
            assert_eq!(unsafe {WaitForSingleObject(self.process.0,INFINITE)},WAIT_OBJECT_0);
            let mut code=0;assert_ne!(unsafe {GetExitCodeProcess(self.process.0,&mut code)},0);
            // Close the retained console even for an already exited owner. Its
            // output reader cannot finish while the fixture owns the HPCON.
            self.input.take();if self.pseudoconsole!=0 {unsafe {ClosePseudoConsole(self.pseudoconsole);}self.pseudoconsole=0;}
            self.output.join();
            assert_eq!(unsafe {WaitForSingleObject(self.backend.0,INFINITE)},WAIT_OBJECT_0);
            for console in &self.consoles {assert_eq!(unsafe {WaitForSingleObject(console.0,INFINITE)},WAIT_OBJECT_0);}
            if let Some(canary)=&self.canary {assert_eq!(unsafe {WaitForSingleObject(canary.0,INFINITE)},WAIT_OBJECT_0);execution(json!({"stage":"actual canary process terminated","canary":process_identity(canary.0)}));}
            execution(json!({"stage":"owner terminated","owner":process_identity(self.process.0),"backend":process_identity(self.backend.0),"consoles":self.consoles.iter().map(|h|process_identity(h.0)).collect::<Vec<_>>(),"exit_code":code,"output_joined":true,"force_kill":false}));
            assert_eq!(code,0,"owner actual exit status");
        }
        fn finish(&mut self,recovery:&Handle,recovery_name:&str,serve_provider_wait:bool) {
            if unsafe {WaitForSingleObject(self.process.0,0)}==WAIT_OBJECT_0 {self.collect_terminated();return;}
            let mut providers=provider_threads(&self.backend);
            let first=self.transact("host.stop",json!({}));
            if first["accepted"]!=true {
                assert_eq!(first["error"]["code"],"operation_conflict","owner cleanup refusal: {first}");
                execution(json!({"stage":"owner stop provider cancellation not yet joined","response":first}));
                assert!(serve_provider_wait,"recovery stop refused; retain original reply without nested service or stop resend");
                providers.merge(provider_threads(&self.backend));
                assert!(providers.complete&&!providers.handles.is_empty(),"provider completion unobserved; preserve recovery route without stop resend");
                wait_providers_with_recovery(self,recovery,recovery_name,providers);
                provider_threads(&self.backend); // Record current inventory; public stop is authority.
                self.success("host.stop",json!({}));
            }
            self.collect_terminated();
            println!("{}",json!({"class":"CLI owner cleanup","actual_owner_exit":0,"output_reader_joined":true,"force_kill":false}));
        }
    }
    impl Drop for CliOwner {
        fn drop(&mut self) {if self.pseudoconsole!=0 { eprintln!("TASK875 failed fixture retains owner/ConPTY resources; no force cleanup"); }}
    }
    fn named(server_input: bool, asynchronous: bool, mode: u32) -> PipePair {
        let name = wide(&format!(r"\\.\pipe\{}",unique("stdin")));
        let server = Handle::new(unsafe {CreateNamedPipeW(name.as_ptr(),
            PIPE_ACCESS_DUPLEX | if server_input && asynchronous {FILE_FLAG_OVERLAPPED} else {0},
            mode,1,65536,65536,0,null())});
        let client = Handle::new(unsafe {CreateFileW(name.as_ptr(),GENERIC_READ|GENERIC_WRITE,0,null(),OPEN_EXISTING,
            if !server_input && asynchronous {FILE_FLAG_OVERLAPPED} else {0},null_mut())});
        let event = Handle::event(); let mut overlapped:OVERLAPPED = unsafe {zeroed()}; overlapped.hEvent=event.0;
        let connected = unsafe {ConnectNamedPipe(server.0,if server_input && asynchronous {&mut overlapped} else {null_mut()})};
        if connected == 0 { let error=unsafe {GetLastError()}; assert_eq!(error,ERROR_PIPE_CONNECTED); }
        if server_input {PipePair{input:server,writer:client}} else {PipePair{input:client,writer:server}}
    }
    fn metadata_success(handle: &Handle) -> bool {
        let mut flags=0; let mut state=0;
        unsafe {GetNamedPipeInfo(handle.0,&mut flags,null_mut(),null_mut(),null_mut())!=0
            && GetNamedPipeHandleStateW(handle.0,&mut state,null_mut(),null_mut(),null_mut(),null_mut(),0)!=0}
    }
    struct Adapter {
        child:std::process::Child,
        input:Option<Handle>,
        output:Option<BufReader<std::process::ChildStdout>>,
        stderr:Option<JoinHandle<Vec<u8>>>,
        captured:Vec<Value>,
        recovery_release:Option<Handle>,finished:bool,
    }
    impl Adapter {
        fn start(binary:&str,discovery:&Value,pair:PipePair, fixture:Option<&[String]>) -> Self {
            let mut command=Command::new(binary);
            if let Some(arguments)=fixture {command.args(arguments);} else {command.arg("--discovery-json").arg(discovery.to_string());}
            let executable=std::fs::read(binary).expect("exact executed adapter image");
            let executable_sha256:String=Sha256::digest(&executable).iter().map(|b|format!("{b:02x}")).collect();
            let mut child=command.stdin(pair.input.stdio()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().expect("spawn adapter");
            execution(json!({"stage":"adapter spawned","process":process_identity(child.as_raw_handle()),"binary":binary,"binary_bytes":executable.len(),"binary_sha256":executable_sha256,"fixture_arguments":fixture.map(|a|a.get(2..).unwrap_or(a)),"normal_binary":fixture.is_none()}));
            let output=BufReader::new(child.stdout.take().unwrap());
            let mut stderr=child.stderr.take().unwrap();
            let stderr=thread::spawn(move || {let mut bytes=Vec::new();stderr.read_to_end(&mut bytes).unwrap();bytes});
            Self{child,input:Some(pair.writer),output:Some(output),stderr:Some(stderr),captured:Vec::new(),recovery_release:None,finished:false}
        }
        fn send(&self, value:&Value) {let mut bytes=serde_json::to_vec(value).unwrap();bytes.push(b'\n');write_bytes(self.input.as_ref().unwrap(),&bytes);}
        fn reply(&mut self) -> Value {
            self.reply_after_prefix(Vec::new())
        }
        fn reply_after_prefix(&mut self,mut bytes:Vec<u8>) -> Value {
            assert_ne!(self.output.as_mut().unwrap().read_until(b'\n',&mut bytes).unwrap(),0,"complete MCP reply");
            assert_eq!(bytes.pop(),Some(b'\n')); assert!(!bytes.ends_with(b"\r"),"MCP writes LF");
            let value:Value=serde_json::from_slice(&bytes).expect("strict complete stdout JSON");
            assert_eq!(value["jsonrpc"],"2.0"); self.captured.push(value.clone()); value
        }
        fn initialize(&mut self) {
            self.send(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"TASK875","version":"1"}}}));
            assert_eq!(self.reply()["result"]["protocolVersion"],"2025-11-25");
            self.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));
        }
        fn finish(mut self,code:i32,diagnostic:Option<&str>) -> Vec<Value> {
            self.input.take();
            let status=self.child.wait().unwrap();
            execution(json!({"stage":"adapter terminated","process":process_identity(self.child.as_raw_handle()),"actual_exit_code":status.code(),"expected_exit_code":code,"expected_reply_count":self.captured.len()}));
            assert_eq!(status.code(),Some(code));
            let mut extra=Vec::new();if let Some(output)=self.output.as_mut(){output.read_to_end(&mut extra).unwrap();}assert!(extra.is_empty(),"unexpected protocol bytes after expected replies");
            let stderr=self.stderr.take().unwrap().join().unwrap();
            assert_eq!(stderr,diagnostic.map(|s|format!("winsmux workspace mcp: {s}\n").into_bytes()).unwrap_or_default());
            self.finished=true;std::mem::take(&mut self.captured)
        }
    }
    impl Drop for Adapter {
        fn drop(&mut self) {
            if self.finished{return;}
            self.input.take();if let Some(event)=&self.recovery_release {unsafe {SetEvent(event.0);}}
            // The fixture owns stdout's consumer. Release that resource before
            // waiting: a claimed finite reply may still be blocked in WriteFile.
            // Closing it makes real writer failure drive the ordinary drain path.
            let stdout_closed=self.output.take().is_some();let status=self.child.wait();
            let stderr_joined=self.stderr.take().map(|thread|thread.join().is_ok()).unwrap_or(true);
            execution(json!({"stage":"adapter failure cleanup","process":process_identity(self.child.as_raw_handle()),"actual_exit":status.ok().and_then(|s|s.code()),"owned_stdout_consumer_closed_before_wait":stdout_closed,"stderr_joined":stderr_joined,"force_kill":false,"original_failure_preserved":true}));
        }
    }
    fn request(instance:Option<&str>,revision:Option<u64>,operation:&str,params:Value) -> Value {
        let operation_name: winsmux_workspace::contract::OperationName=serde_json::from_value(json!(operation)).expect("normal fixture operation comes from authoritative inventory");
        let revision=if operation_name.class()==winsmux_workspace::contract::OperationClass::T {Some(revision.expect("normal topology request requires current owner revision"))}else{None};
        let sequence=NEXT.fetch_add(1,Ordering::Relaxed);
        let value=json!({"schema_version":1,"instance_id":instance,"operation_id":format!("87500000-0000-4000-8000-{sequence:012x}"),
            "expected_topology_revision":revision,"operation":operation,"params":params});
        winsmux_workspace::contract::parse_request(&serde_json::to_vec(&value).unwrap()).expect("normal fixture request must satisfy authoritative contract before send");value
    }
    fn call(adapter:&mut Adapter,id:u64,request:Value) -> Value {
        winsmux_workspace::contract::parse_request(&serde_json::to_vec(&request).unwrap()).expect("normal MCP call after mutation must satisfy authoritative contract before send");
        adapter.send(&json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request}}));
        let response=adapter.reply();assert_eq!(response["id"],id);
        let structured=&response["result"]["structuredContent"];
        if !structured.is_null() {assert_eq!(serde_json::from_str::<Value>(response["result"]["content"][0]["text"].as_str().unwrap()).unwrap(),*structured);}
        response
    }
    // Negative intent is finite and separate from every normal request path.
    // A rejected shape is a presend contract proof, not an owner refusal.
    #[derive(Clone,Copy,Debug)]
    enum ExplicitMalformed { DenyProject, DenyScope, DenyBoth, RequestDuplicateProject, RequestDuplicateScope, DecideDuplicateProject, DecideDuplicateScope, InnerPlusOne }
    impl ExplicitMalformed {
        const ALL:[Self;8]=[Self::DenyProject,Self::DenyScope,Self::DenyBoth,Self::RequestDuplicateProject,Self::RequestDuplicateScope,Self::DecideDuplicateProject,Self::DecideDuplicateScope,Self::InnerPlusOne];
        fn expected(self)->winsmux_workspace::contract::ContractError {
            use winsmux_workspace::contract::ContractError;
            match self {Self::InnerPlusOne=>ContractError::MessageTooLarge,_=>ContractError::InvariantViolation}
        }
        fn request(self,instance:&str)->Value {
            let mut value=match self {
                Self::RequestDuplicateProject|Self::RequestDuplicateScope=>request(None,None,"connection.request",json!({"project_ids":[instance],"scopes":["metadata"]})),
                Self::InnerPlusOne=>request(Some(instance),None,"input.write",json!({"pane_id":instance,"run_id":instance,"text":""})),
                Self::DecideDuplicateProject|Self::DecideDuplicateScope=>request(Some(instance),None,"connection.decide",json!({"connection_id":instance,"decision":"allow","project_ids":[instance],"scopes":["metadata"]})),
                _=>request(Some(instance),None,"connection.decide",json!({"connection_id":instance,"decision":"deny","project_ids":[],"scopes":[]}))
            };
            match self {
                Self::DenyProject=>value["params"]["project_ids"]=json!([instance]),
                Self::DenyScope=>value["params"]["scopes"]=json!(["metadata"]),
                Self::DenyBoth=>{value["params"]["project_ids"]=json!([instance]);value["params"]["scopes"]=json!(["metadata"]);},
                Self::RequestDuplicateProject|Self::DecideDuplicateProject=>value["params"]["project_ids"]=json!([instance,instance]),
                Self::RequestDuplicateScope|Self::DecideDuplicateScope=>value["params"]["scopes"]=json!(["metadata","metadata"]),
                Self::InnerPlusOne=>{let base=serde_json::to_vec(&value).unwrap().len();value["params"]["text"]="a".repeat(winsmux_workspace::contract::MAX_MESSAGE_BYTES+1-base).into();}
            }
            self.check(&value);value
        }
        fn check(self,value:&Value) {
            let bytes=serde_json::to_vec(value).unwrap();
            assert_eq!(winsmux_workspace::contract::parse_request(&bytes).unwrap_err(),self.expected(),"explicit malformed {self:?}");
            if matches!(self,Self::InnerPlusOne){assert_eq!(bytes.len(),winsmux_workspace::contract::MAX_MESSAGE_BYTES+1);}
        }
    }
    fn malformed_mcp_call(adapter:&mut Adapter,id:u64,intent:ExplicitMalformed,instance:&str)->Value {
        // Only this modeled intent reaches the actual public MCP ingress.
        // Other malformed classes prove the presend boundary without IO.
        assert!(matches!(intent,ExplicitMalformed::InnerPlusOne));let request=intent.request(instance);
        adapter.send(&json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request}}));
        let response=adapter.reply();
        execution(json!({"stage":"explicit malformed public MCP reply","intent":format!("{intent:?}"),"presend_error":intent.expected(),"response":response}));
        assert_eq!(response,json!({"jsonrpc":"2.0","id":id,"error":{"code":-32602,"message":"invalid_request_arguments"}}));response
    }
    fn malformed_request_classes() {
        let instance="87500000-0000-4000-8000-000000000000";
        for intent in ExplicitMalformed::ALL {let value=intent.request(instance);intent.check(&value);}
        for (operation,params) in [("connection.request",json!({"project_ids":[instance],"scopes":["metadata"]})),("connection.decide",json!({"connection_id":instance,"decision":"deny","project_ids":[],"scopes":[]})),("connection.decide",json!({"connection_id":instance,"decision":"allow","project_ids":[instance],"scopes":["metadata"]}))] {
            let value=request(if operation=="connection.request"{None}else{Some(instance)},None,operation,params);
            winsmux_workspace::contract::parse_request(&serde_json::to_vec(&value).unwrap()).unwrap();
        }
        let mut exact=request(Some(instance),None,"input.write",json!({"pane_id":instance,"run_id":instance,"text":""}));
        let base=serde_json::to_vec(&exact).unwrap().len();exact["params"]["text"]="a".repeat(winsmux_workspace::contract::MAX_MESSAGE_BYTES-base).into();
        let bytes=serde_json::to_vec(&exact).unwrap();assert_eq!(bytes.len(),winsmux_workspace::contract::MAX_MESSAGE_BYTES);winsmux_workspace::contract::parse_request(&bytes).unwrap();
        println!("{}",json!({"class":"fixture explicit malformed presend boundary","deny_nonempty_shapes":3,"duplicate_set_shapes":4,"inner_plus_one":1,"legal_siblings":4,"send_count":0,"host_processes":0,"known_folder_used":false,"public_negative_response_not_measured":true}));
    }
    #[derive(Clone,Copy,Debug)]
    enum ProductReply { LiveSuccess, LiveDenied(winsmux_workspace::contract::ErrorCode), CancelledWire }
    fn check_product_reply(request:&Value,id:u64,response:&Value,expected:ProductReply)->bool {
        if response["jsonrpc"]!="2.0"||response["id"]!=id {return false;}
        if matches!(expected,ProductReply::CancelledWire) {
            return *response==json!({"jsonrpc":"2.0","id":id,"error":{"code":-32603,"message":"transport_uncertain"}});
        }
        if response.as_object().map_or(true,|object|object.len()!=3)||response.get("error").is_some(){return false;}
        if response["result"].as_object().map_or(true,|object|object.len()!=3)||response["result"]["content"].as_array().map_or(true,|items|items.len()!=1)||response["result"]["content"][0]["type"]!="text" {return false;}
        let Some(structured)=response["result"].get("structuredContent")else{return false;};
        let Some(text)=response["result"]["content"][0]["text"].as_str()else{return false;};
        if serde_json::from_str::<Value>(text).ok().as_ref()!=Some(structured){return false;}
        let Ok(parsed)=winsmux_workspace::contract::parse_request(&serde_json::to_vec(request).unwrap())else{return false;};
        if winsmux_workspace::contract::parse_response(&parsed,&serde_json::to_vec(structured).unwrap()).is_err(){return false;}
        if response["result"]["isError"]!=json!(structured["accepted"]!=true){return false;}
        match expected {ProductReply::LiveSuccess=>structured["accepted"]==true,ProductReply::LiveDenied(code)=>structured["accepted"]==false&&structured["error"]["code"]==serde_json::to_value(code).unwrap(),ProductReply::CancelledWire=>unreachable!()}
    }
    fn product_call(adapter:&mut Adapter,id:u64,request:Value,phase:&str,expected:ProductReply)->Value {
        let response=call(adapter,id,request.clone());
        execution(json!({"stage":"actual ProductHost authority and wire decision observed","request":request,"response":response,"authority_phase":phase,"reply_contract":format!("{expected:?}")}));
        assert!(check_product_reply(&request,id,&response,expected),"ProductHost {phase}/{expected:?}: {response}");response
    }
    fn product_reply_classes() {
        use winsmux_workspace::contract::ErrorCode;
        let request=request(Some("87500000-0000-4000-8000-000000000000"),None,"run.get",json!({"run_id":"87500000-0000-4000-8000-000000000000"}));
        let typed=json!({"schema_version":1,"instance_id":request["instance_id"],"operation_id":request["operation_id"],"accepted":false,"topology_revision":0,"event_seq":0,"result":null,"error":ErrorCode::PermissionDenied.with_target(None).unwrap()});
        let live=json!({"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":serde_json::to_string(&typed).unwrap()}],"structuredContent":typed,"isError":true}});
        let terminal=json!({"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"transport_uncertain"}});
        assert!(check_product_reply(&request,1,&live,ProductReply::LiveDenied(ErrorCode::PermissionDenied)));
        assert!(!check_product_reply(&request,1,&live,ProductReply::CancelledWire));
        assert!(!check_product_reply(&request,1,&terminal,ProductReply::LiveDenied(ErrorCode::PermissionDenied)));
        assert!(check_product_reply(&request,1,&terminal,ProductReply::CancelledWire));
        let mut wrong=terminal.clone();wrong["id"]=json!(2);assert!(!check_product_reply(&request,1,&wrong,ProductReply::CancelledWire));
        let mut wrong=terminal.clone();wrong["jsonrpc"]=json!("1.0");assert!(!check_product_reply(&request,1,&wrong,ProductReply::CancelledWire));
        let mut wrong=terminal.clone();wrong["error"]["code"]=json!(-32602);assert!(!check_product_reply(&request,1,&wrong,ProductReply::CancelledWire));
        let mut wrong=terminal.clone();wrong["result"]=json!(null);assert!(!check_product_reply(&request,1,&wrong,ProductReply::CancelledWire));
        let mut wrong=terminal.clone();wrong["error"]["message"]=json!("permission_denied");assert!(!check_product_reply(&request,1,&wrong,ProductReply::CancelledWire));
        let mut wrong=live.clone();wrong["result"]["structuredContent"]=Value::Null;assert!(!check_product_reply(&request,1,&wrong,ProductReply::LiveDenied(ErrorCode::PermissionDenied)));
        let mut wrong=live.clone();wrong["result"]["content"][0]["text"]=json!("{}");assert!(!check_product_reply(&request,1,&wrong,ProductReply::LiveDenied(ErrorCode::PermissionDenied)));
        println!("{}",json!({"class":"ProductHost wire reply oracle pure proof","typed_and_terminal_are_disjoint":true,"fixed_transport_complete_object":true,"typed_null_and_wrong_text_rejected":true,"host_processes":0,"known_folder_used":false}));
    }
    fn check_owner_terminal_reply(connection:&str,deny:bool,response:&Value)->bool {
        let operation=if deny{"connection.decide"}else{"connection.revoke"};
        let expected=if deny{json!({"connection_id":connection,"state":"revoked","project_ids":[],"scopes":[]})}else{json!({"connection_id":connection,"state":"revoked"})};
        response["accepted"]==true&&response["error"].is_null()&&response["result"]["operation"]==operation&&response["result"]["data"]==expected
    }
    fn owner_terminal_reply_classes() {
        let instance="87500000-0000-4000-8000-000000000000";
        for deny in [false,true] {
            let operation=if deny{"connection.decide"}else{"connection.revoke"};
            let params=if deny{json!({"connection_id":instance,"decision":"deny","project_ids":[],"scopes":[]})}else{json!({"connection_id":instance})};
            let request=request(Some(instance),None,operation,params);let parsed=winsmux_workspace::contract::parse_request(&serde_json::to_vec(&request).unwrap()).unwrap();
            let data=if deny{json!({"connection_id":instance,"state":"revoked","project_ids":[],"scopes":[]})}else{json!({"connection_id":instance,"state":"revoked"})};
            let response=json!({"schema_version":1,"instance_id":instance,"operation_id":request["operation_id"],"accepted":true,"topology_revision":0,"event_seq":7,"error":null,"result":{"operation":operation,"data":data}});
            winsmux_workspace::contract::parse_response(&parsed,&serde_json::to_vec(&response).unwrap()).unwrap();assert!(check_owner_terminal_reply(instance,deny,&response));
            for (path,value) in [("accepted",json!(false)),("error",json!({})),("state",json!("granted")),("connection_id",json!("other")),("operation",json!("connection.list")),("extra",json!(true))] {
                let mut wrong=response.clone();match path{"accepted"|"error"=>wrong[path]=value,"operation"=>wrong["result"][path]=value,_=>wrong["result"]["data"][path]=value};assert!(!check_owner_terminal_reply(instance,deny,&wrong));
            }
            if deny {for field in ["project_ids","scopes"]{let mut wrong=response.clone();wrong["result"]["data"][field]=json!([instance]);assert!(!check_owner_terminal_reply(instance,deny,&wrong));}}
        }
        println!("{}",json!({"class":"owner terminal success reply pure proof","valid_operation_shapes":2,"wrong_common_shapes_rejected":12,"nonempty_deny_grants_rejected":2,"list_is_retire_barrier":false,"retire_point_not_observed":true,"host_processes":0,"known_folder_used":false}));
    }
    #[derive(Clone,Copy,Debug,PartialEq,Eq)]
    enum SelectionBaseline { None, ProjectOnly, CanaryPane }
    impl SelectionBaseline {
        const ALL:[Self;3]=[Self::None,Self::ProjectOnly,Self::CanaryPane];
        fn capture(snapshot:&Value,project:&str,pane:&str)->Option<Self> {
            if snapshot.get("panes")?.get("project_id")?!=project {return None;}
            let selected_project=snapshot.get("projects")?.get("selected_project_id")?;
            let selected_pane=snapshot.get("panes")?.get("selected_pane_id")?;
            match (selected_project,selected_pane) {
                (Value::Null,Value::Null)=>Some(Self::None),
                (selected_project,Value::Null) if selected_project==project=>Some(Self::ProjectOnly),
                (selected_project,selected_pane) if selected_project==project&&selected_pane==pane=>Some(Self::CanaryPane),
                _=>None
            }
        }
        fn operation(self,project:&str,pane:&str)->(&'static str,Value) {
            match self {Self::None=>("project.select",json!({"project_id":null})),Self::ProjectOnly=>("project.select",json!({"project_id":project})),Self::CanaryPane=>("pane.select",json!({"pane_id":pane}))}
        }
        fn selection(self,project:&str,pane:&str)->Value {
            match self {Self::None=>json!({"selected_project_id":null,"selected_pane_id":null}),Self::ProjectOnly=>json!({"selected_project_id":project,"selected_pane_id":null}),Self::CanaryPane=>json!({"selected_project_id":project,"selected_pane_id":pane})}
        }
    }
    fn restore_selection(owner:&mut CliOwner,baseline:SelectionBaseline,project:&str,pane:&str) {
        let (operation,params)=baseline.operation(project,pane);let response=owner.success(operation,params);
        execution(json!({"stage":"captured owned selection restored","baseline":format!("{baseline:?}"),"response":response,"unconditional_canary_select":false}));
        assert_eq!(response["result"]["data"],baseline.selection(project,pane));
    }
    fn selection_baseline_classes() {
        use winsmux_workspace::contract::{OperationClass,OperationName,parse_request};
        let project="87500000-0000-4000-8000-000000000000";let pane="87500000-0000-4000-8000-000000000001";
        for baseline in SelectionBaseline::ALL {
            let expected=baseline.selection(project,pane);let snapshot=json!({"projects":{"selected_project_id":expected["selected_project_id"]},"panes":{"project_id":project,"selected_pane_id":expected["selected_pane_id"]}});
            assert_eq!(SelectionBaseline::capture(&snapshot,project,pane),Some(baseline));
            let (operation,params)=baseline.operation(project,pane);let value=request(Some(project),Some(7),operation,params.clone());
            let parsed=parse_request(&serde_json::to_vec(&value).unwrap()).unwrap();let name:OperationName=serde_json::from_value(json!(operation)).unwrap();assert_eq!(name.class(),OperationClass::T);assert_eq!(value["expected_topology_revision"],7);assert_eq!(value["params"],params);assert_eq!(serde_json::to_value(parsed.action.operation()).unwrap(),json!(operation));
            let mut wrong=value;wrong["expected_topology_revision"]=Value::Null;assert!(parse_request(&serde_json::to_vec(&wrong).unwrap()).is_err());
        }
        for (selected_project,selected_pane) in [(Value::Null,json!(pane)),(json!("other-project"),Value::Null),(json!(project),json!("other-pane")),(json!(3),Value::Null),(json!(project),json!(false))] {
            let snapshot=json!({"projects":{"selected_project_id":selected_project},"panes":{"project_id":project,"selected_pane_id":selected_pane}});assert_eq!(SelectionBaseline::capture(&snapshot,project,pane),None);
        }
        for snapshot in [json!({"projects":{},"panes":{"project_id":project,"selected_pane_id":null}}),json!({"projects":{"selected_project_id":null},"panes":{"project_id":project}}),json!({"projects":{"selected_project_id":null},"panes":{"project_id":"other-project","selected_pane_id":null}})] {assert_eq!(SelectionBaseline::capture(&snapshot,project,pane),None);}
        println!("{}",json!({"class":"captured selection baseline pure proof","valid_states":3,"wrong_revision_shapes":3,"inconsistent_unknown_missing_rejected":8,"normal_parse_before_send":true,"unknown_baseline_send_count":0,"host_processes":0,"known_folder_used":false}));
    }
    fn request_shape_classes() {
        use winsmux_workspace::contract::{OperationName,OperationClass,parse_request,canonical_request};
        let instance="87500000-0000-4000-8000-000000000000";
        let mut classes=Vec::new();
        for operation in OperationName::ALL {let wire=serde_json::to_value(operation).unwrap();let decoded:OperationName=serde_json::from_value(wire).unwrap();assert_eq!(*operation,decoded);if !classes.contains(&decoded.class()){classes.push(decoded.class());}}
        assert_eq!(classes.len(),5);
        for (operation,params,nullable_instance) in [("capabilities.get",json!({}),true),("run.get",json!({"run_id":instance}),false),("pane.create",json!({"project_id":instance,"shell_profile_id":"pwsh"}),false),("pane.resize",json!({"pane_id":instance,"run_id":instance,"cols":100,"rows":28}),false),("connection.request",json!({"project_ids":[instance],"scopes":["metadata"]}),true),("layout.save",json!({}),false)] {
            let name:OperationName=serde_json::from_value(json!(operation)).unwrap();let value=request(if nullable_instance{None}else{Some(instance)},Some(7),operation,params);
            let parsed=parse_request(&serde_json::to_vec(&value).unwrap()).unwrap();let canonical=canonical_request(&parsed).unwrap();assert_eq!(parse_request(&canonical).unwrap(),parsed);
            assert_eq!(value["expected_topology_revision"],if name.class()==OperationClass::T{json!(7)}else{Value::Null});
            let mut wrong_revision=value.clone();wrong_revision["expected_topology_revision"]=if name.class()==OperationClass::T{Value::Null}else{json!(7)};assert!(parse_request(&serde_json::to_vec(&wrong_revision).unwrap()).is_err());
            let mut null_instance=value;null_instance["instance_id"]=Value::Null;assert_eq!(parse_request(&serde_json::to_vec(&null_instance).unwrap()).is_ok(),nullable_instance);
        }
        assert!(serde_json::from_value::<OperationName>(json!("fixture.unknown")).is_err());
        println!("{}",json!({"class":"fixture normal request centralized shape proof","operation_inventory":OperationName::ALL.len(),"classes":5,"valid_shapes":6,"wrong_revision_rejected":6,"instance_boundaries":6,"normal_parse_before_send":true,"host_processes":0,"known_folder_used":false}));
    }
    // Dedicated proof peer, not ProductHost. It uses the production transcript
    // format with an ephemeral, non-exported CNG private key. Its measurement is
    // successful real client authentication, one fully read ordinary frame and
    // peer EOF after cancellation. ProductHost ACL/token and authorization
    // proofs remain separate; this peer never grants or executes a request.
    struct ProofKey { algorithm:BCRYPT_ALG_HANDLE, key:BCRYPT_KEY_HANDLE, public:[u8;72] }
    unsafe impl Send for ProofKey {}
    impl Drop for ProofKey {
        fn drop(&mut self) {unsafe {if !self.key.is_null(){BCryptDestroyKey(self.key);}if !self.algorithm.is_null(){BCryptCloseAlgorithmProvider(self.algorithm,0);}}}
    }
    impl ProofKey {
        fn generate()->Self {
            let mut value=Self{algorithm:null_mut(),key:null_mut(),public:[0;72]};
            assert!(unsafe {BCryptOpenAlgorithmProvider(&mut value.algorithm,BCRYPT_ECDSA_P256_ALGORITHM,null(),0)}>=0);
            assert!(!value.algorithm.is_null());
            assert!(unsafe {BCryptGenerateKeyPair(value.algorithm,&mut value.key,256,0)}>=0);
            assert!(!value.key.is_null());assert!(unsafe {BCryptFinalizeKeyPair(value.key,0)}>=0);
            let mut required=0;
            assert!(unsafe {BCryptExportKey(value.key,null_mut(),BCRYPT_ECCPUBLIC_BLOB,null_mut(),0,&mut required,0)}>=0);
            assert_eq!(required,72);
            assert!(unsafe {BCryptExportKey(value.key,null_mut(),BCRYPT_ECCPUBLIC_BLOB,value.public.as_mut_ptr(),72,&mut required,0)}>=0);
            assert_eq!(required,72);assert_eq!(u32::from_le_bytes(value.public[..4].try_into().unwrap()),BCRYPT_ECDSA_PUBLIC_P256_MAGIC);
            assert_eq!(u32::from_le_bytes(value.public[4..8].try_into().unwrap()),32);value
        }
        fn reply(&self,discovery:&Value,challenge:&[u8],client:u32,server:u32)->[u8;148] {
            assert_eq!(challenge.len(),32);assert_ne!(client,0);assert_ne!(server,0);
            let instance=discovery["instance_id"].as_str().unwrap().replace('-',"");assert_eq!(instance.len(),32);
            let mut transcript=b"winsmux.workspace.server-proof.v1\0".to_vec();
            transcript.extend_from_slice(&1u32.to_le_bytes());
            for index in (0..32).step_by(2) {transcript.push(u8::from_str_radix(&instance[index..index+2],16).unwrap());}
            let pipe=discovery["pipe_name"].as_str().unwrap().as_bytes();
            transcript.extend_from_slice(&(pipe.len() as u32).to_le_bytes());transcript.extend_from_slice(pipe);
            transcript.extend_from_slice(challenge);transcript.extend_from_slice(&client.to_le_bytes());transcript.extend_from_slice(&server.to_le_bytes());
            let digest=Sha256::digest(&transcript);let mut reply=[0;148];let mut written=0;
            reply[..8].copy_from_slice(b"WSMXAUTH");reply[8..12].copy_from_slice(&1u32.to_le_bytes());reply[12..84].copy_from_slice(&self.public);
            assert!(unsafe {BCryptSignHash(self.key,null(),digest.as_ptr(),32,reply[84..].as_mut_ptr(),64,&mut written,0)}>=0);
            assert_eq!(written,64);reply
        }
    }
    fn ordinary_frame(reader:&mut PipeRead)->Vec<u8> {
        let mut length=[0;4];reader.read_exact(&mut length).unwrap();let length=u32::from_le_bytes(length) as usize;
        assert!(length>0&&length<=winsmux_workspace::contract::MAX_MESSAGE_BYTES);
        let mut body=vec![0;length];reader.read_exact(&mut body).unwrap();body
    }
    #[derive(Clone,Copy)]
    enum ProofPeerMode { HoldReply, AuthOnly, DenyRequests, ControlledRequests, CloseReply, LargeReply }
    fn large_output_response(wire:&Value)->Value {
        assert_eq!(wire["operation"],"output.read");
        let mut response=json!({"schema_version":1,"instance_id":wire["instance_id"],"operation_id":wire["operation_id"],"accepted":true,"topology_revision":0,"event_seq":0,"error":null,"result":{"operation":"output.read","data":{"run_id":wire["params"]["run_id"],"text":"","next_cursor":"fixture-next","gap":true,"truncated":true}}});
        let overhead=serde_json::to_vec(&response).unwrap().len();
        response["result"]["data"]["text"]="a".repeat(winsmux_workspace::contract::MAX_MESSAGE_BYTES-overhead).into();
        assert_eq!(serde_json::to_vec(&response).unwrap().len(),winsmux_workspace::contract::MAX_MESSAGE_BYTES);
        response
    }
    struct ValidProofServer { discovery:Value, ready:Arc<Handle>, reply_release:Arc<Handle>, thread:Option<JoinHandle<Value>> }
    impl ValidProofServer {
        fn start()->Self {Self::start_mode(ProofPeerMode::HoldReply)}
        fn start_mode(mode:ProofPeerMode)->Self {
            let key=ProofKey::generate();let fingerprint:String=Sha256::digest(key.public).iter().map(|b|format!("{b:02x}")).collect();
            let mut discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
            let old=discovery["pipe_name"].as_str().unwrap();assert_eq!(old.len()-old.rfind('-').unwrap()-1,64);
            discovery["pipe_name"]=format!("{}{}",&old[..old.len()-64],fingerprint).into();
            winsmux_workspace_mcp::parse_discovery(&serde_json::to_vec(&discovery).unwrap()).unwrap();
            let pipe=Handle::new(unsafe {CreateNamedPipeW(wide(discovery["pipe_name"].as_str().unwrap()).as_ptr(),PIPE_ACCESS_DUPLEX,PIPE_TYPE_BYTE|PIPE_WAIT,1,65536,65536,0,null())});
            let ready=Arc::new(Handle::event());let notify=ready.clone();let reply_release=Arc::new(Handle::event());let await_reply=reply_release.clone();let peer_discovery=discovery.clone();
            let thread=thread::spawn(move || {
                if unsafe {ConnectNamedPipe(pipe.0,null_mut())}==0 {assert_eq!(unsafe {GetLastError()},ERROR_PIPE_CONNECTED);}
                let mut client=0;let mut server=0;
                assert_ne!(unsafe {GetNamedPipeClientProcessId(pipe.0,&mut client)},0);
                assert_ne!(unsafe {GetNamedPipeServerProcessId(pipe.0,&mut server)},0);assert_eq!(server,std::process::id());
                let mut reader=PipeRead(pipe.duplicate(0,true));let auth=ordinary_frame(&mut reader);
                assert_eq!(auth.len(),44);assert_eq!(&auth[..8],b"WSMXAUTH");assert_eq!(&auth[8..12],&1u32.to_le_bytes());
                let reply=key.reply(&peer_discovery,&auth[12..],client,server);
                write_bytes(&pipe,&148u32.to_le_bytes());write_bytes(&pipe,&reply);
                if matches!(mode,ProofPeerMode::AuthOnly) {
                    assert_ne!(unsafe {SetEvent(notify.0)},0);let mut next=[0;4];assert_eq!(reader.read(&mut next).unwrap(),0,"codec refusal/local replies send no ordinary frame");
                    return json!({"client_pid":client,"server_pid":server,"auth_frames":1,"ordinary_frames":0,"ordinary_bytes":0,"peer_eof":true,"product_host":false});
                }
                if matches!(mode,ProofPeerMode::DenyRequests|ProofPeerMode::ControlledRequests|ProofPeerMode::LargeReply) {
                    if !matches!(mode,ProofPeerMode::ControlledRequests){assert_ne!(unsafe {SetEvent(notify.0)},0);}let mut frames=0;let mut largest=0;let mut total=0;let mut last_sha=String::new();
                    loop {
                        let mut length=[0;4];let first=reader.read(&mut length).unwrap();if first==0{break;}
                        reader.read_exact(&mut length[first..]).unwrap();let length=u32::from_le_bytes(length) as usize;
                        assert!(length>0&&length<=winsmux_workspace::contract::MAX_MESSAGE_BYTES);let mut body=vec![0;length];reader.read_exact(&mut body).unwrap();
                        let request=winsmux_workspace::contract::parse_request(&body).unwrap();
                        assert_eq!(winsmux_workspace::contract::canonical_request(&request).unwrap(),body,"ordinary actual canonical bytes");
                        let wire:Value=serde_json::from_slice(&body).unwrap();assert_eq!(wire["instance_id"],peer_discovery["instance_id"]);
                        if matches!(mode,ProofPeerMode::ControlledRequests)&&frames==0 {
                            execution(json!({"stage":"controlled proof peer read first actual ordinary frame","client_pid":client,"server_pid":server,"ordinary_bytes":body.len(),"reply_held":true,"product_host":false}));
                            assert_ne!(unsafe {SetEvent(notify.0)},0);
                            assert_eq!(unsafe {WaitForSingleObject(await_reply.0,INFINITE)},WAIT_OBJECT_0);
                        }
                        let response=if matches!(mode,ProofPeerMode::LargeReply){assert_eq!(frames,0,"one large fixture response, no replay");large_output_response(&wire)}else{json!({"schema_version":1,"instance_id":wire["instance_id"],"operation_id":wire["operation_id"],"accepted":false,"topology_revision":0,"event_seq":0,"result":null,"error":winsmux_workspace::contract::ErrorCode::PermissionDenied.with_target(None).unwrap()})};
                        let response=winsmux_workspace::contract::parse_response(&request,&serde_json::to_vec(&response).unwrap()).unwrap();
                        let bytes=winsmux_workspace::contract::serialize_response(&request,&response).unwrap();
                        write_bytes(&pipe,&(bytes.len() as u32).to_le_bytes());write_bytes(&pipe,&bytes);
                        frames+=1;largest=largest.max(length);total+=length;last_sha=Sha256::digest(&body).iter().map(|b|format!("{b:02x}")).collect();
                    }
                    return json!({"client_pid":client,"server_pid":server,"auth_frames":1,"ordinary_frames":frames,"ordinary_bytes":total,"largest_ordinary_bytes":largest,"last_ordinary_sha256":last_sha,"peer_eof":true,"product_host":false,"fixture_denial_only":matches!(mode,ProofPeerMode::DenyRequests|ProofPeerMode::ControlledRequests),"first_reply_explicitly_held":matches!(mode,ProofPeerMode::ControlledRequests),"fixture_response_only":true,"ProductHost_output_not_measured":true});
                }
                let body=ordinary_frame(&mut reader);let request:Value=serde_json::from_slice(&body).unwrap();
                assert_eq!(request["instance_id"],peer_discovery["instance_id"]);assert_eq!(request["operation"],"project.list");
                assert_eq!(request["schema_version"],1);assert_eq!(request["params"],json!({}));
                assert!(request["operation_id"].as_str().is_some());
                execution(json!({"stage":"valid proof peer read actual ordinary frame","client_pid":client,"server_pid":server,"auth_frames":1,"ordinary_frames":1,"ordinary_bytes":body.len(),"ordinary_reply_held":true,"product_host":false}));
                assert_ne!(unsafe {SetEvent(notify.0)},0);
                if matches!(mode,ProofPeerMode::CloseReply) {
                    return json!({"client_pid":client,"server_pid":server,"auth_frames":1,"ordinary_frames":1,"ordinary_bytes":body.len(),"ordinary_reply_sent":false,"owned_peer_closed":true,"product_host":false});
                }
                let mut next=[0;4];assert_eq!(reader.read(&mut next).unwrap(),0,"cancelled public connection actual peer EOF; no next frame or resend");
                json!({"client_pid":client,"server_pid":server,"auth_frames":1,"ordinary_frames":1,"ordinary_bytes":body.len(),"next_frame_bytes":0,"peer_eof":true,"ordinary_reply_sent":false,"private_key_exported":false,"product_host":false})
            });Self{discovery,ready,reply_release,thread:Some(thread)}
        }
        fn received(&self){assert_eq!(unsafe {WaitForSingleObject(self.ready.0,INFINITE)},WAIT_OBJECT_0);}
        fn release_reply(&self){assert_ne!(unsafe {SetEvent(self.reply_release.0)},0);}
        fn finish(mut self)->Value {let result=self.thread.take().unwrap().join().unwrap();execution(json!({"stage":"valid proof peer actual thread joined","peer":result}));result}
    }
    impl Drop for ValidProofServer {fn drop(&mut self){self.release_reply();if let Some(thread)=self.thread.take(){let joined=thread.join();execution(json!({"stage":"valid proof peer failure cleanup actual thread joined","peer":joined.as_ref().ok(),"original_failure_preserved":true}));assert!(joined.is_ok(),"owned proof peer thread exit");}}}
    fn sent_held_reply(binary:&str,pair:PipePair,class:&str,eof:bool) {
        let server=ValidProofServer::start();let mut adapter=Adapter::start(binary,&server.discovery,pair,None);
        adapter.initialize();adapter.send(&json!({"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request(server.discovery["instance_id"].as_str(),None,"project.list",json!({}))}}));
        server.received();
        if !eof {
            adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30}}));
            adapter.send(&json!({"jsonrpc":"2.0","id":31,"method":"ping"}));assert_eq!(adapter.reply()["id"],31);
            let unknown=call(&mut adapter,32,request(server.discovery["instance_id"].as_str(),None,"project.list",json!({})));
            assert_eq!(unknown["error"]["code"],-32603);
        }
        let replies=adapter.finish(0,None);assert!(replies.iter().all(|r|r["id"]!=30));let peer=server.finish();
        println!("{}",json!({"class":"Sent ordinary reply held cancellation/EOF","input_class":class,"eof":eof,"normal_binary":true,"actual_adapter_exit":0,"cancelled_response_count":0,"unknown_after_cancel":!eof,"peer":peer,"product_host_authorization_not_measured":true}));
    }
    fn codec_class(binary:&str,server_input:bool,asynchronous:bool) {
        let server=ValidProofServer::start_mode(ProofPeerMode::AuthOnly);let gate=FixtureGate::new();
        let mut adapter=gate.adapter(&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),"ReadComplete",false,0);
        let initialize=serde_json::to_vec(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"日本語😀","version":"1"}}})).unwrap();
        let split=initialize.iter().position(|b|*b>=0x80).unwrap()+1;
        write_bytes(adapter.input.as_ref().unwrap(),&initialize[..split]);gate.reached();
        // The first native read has physically completed before the remaining
        // UTF8 bytes exist in the pipe; the runtime cannot validate early.
        write_bytes(adapter.input.as_ref().unwrap(),&initialize[split..]);write_bytes(adapter.input.as_ref().unwrap(),b"\n");gate.release();
        assert_eq!(adapter.reply()["result"]["protocolVersion"],"2025-11-25");
        adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));adapter.send(&json!({"jsonrpc":"2.0","id":2,"method":"ping"}));assert_eq!(adapter.reply()["id"],2);
        adapter.finish(0,None);let observed=gate.result();drains(&observed,1,1,0);
        assert_eq!(observed["observations"]["first_read_bytes"],split);assert!(observed["observations"]["read_completions"].as_u64().unwrap()>=2);
        let peer=server.finish();assert_eq!(peer["ordinary_frames"],0);
        println!("{}",json!({"class":"actual native read completed inside UTF8 before remainder write","server_input":server_input,"asynchronous":asynchronous,"normal_binary":false,"native_result":observed,"peer":peer}));
        let server=ValidProofServer::start_mode(ProofPeerMode::AuthOnly);
        let mut adapter=Adapter::start(binary,&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),None);
        // Exact outer payload, split CRLF, and a zero-byte write followed by a
        // valid message use the real native reader, never a Cursor helper.
        let mut ping=serde_json::to_vec(&json!({"jsonrpc":"2.0","id":20,"method":"ping"})).unwrap();
        ping.resize(winsmux_workspace_mcp::MAX_MCP_MESSAGE_BYTES,b' ');write_bytes(adapter.input.as_ref().unwrap(),&ping);
        write_bytes(adapter.input.as_ref().unwrap(),b"\r");write_bytes(adapter.input.as_ref().unwrap(),b"\n");assert_eq!(adapter.reply()["id"],20);
        write_bytes(adapter.input.as_ref().unwrap(),b"");adapter.send(&json!({"jsonrpc":"2.0","id":21,"method":"ping"}));assert_eq!(adapter.reply()["id"],21);
        let initialize=serde_json::to_vec(&json!({"jsonrpc":"2.0","id":22,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"日本語😀","version":"1"}}})).unwrap();
        let split=initialize.iter().position(|b|*b>=0x80).unwrap()+1;
        write_bytes(adapter.input.as_ref().unwrap(),&initialize[..split]);write_bytes(adapter.input.as_ref().unwrap(),&initialize[split..]);write_bytes(adapter.input.as_ref().unwrap(),b"\n");
        assert_eq!(adapter.reply()["result"]["protocolVersion"],"2025-11-25");adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));
        for duplicate in [br#"{"jsonrpc":"2.0","id":23,"id":24,"method":"ping"}"#.as_slice(),br#"{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":{"schema_version":1,"schema_version":1}}}"#.as_slice()] {
            write_bytes(adapter.input.as_ref().unwrap(),duplicate);write_bytes(adapter.input.as_ref().unwrap(),b"\n");assert_eq!(adapter.reply()["error"]["code"],-32600);
        }
        let intent=ExplicitMalformed::InnerPlusOne;
        malformed_mcp_call(&mut adapter,25,intent,server.discovery["instance_id"].as_str().unwrap());
        adapter.send(&json!({"jsonrpc":"2.0","id":26,"method":"ping"}));assert_eq!(adapter.reply()["id"],26);
        adapter.finish(0,None);let peer=server.finish();assert_eq!(peer["ordinary_frames"],0);
        println!("{}",json!({"class":"actual codec exact outer CRLF zero write split UTF8 duplicate keys inner plus one","server_input":server_input,"asynchronous":asynchronous,"peer":peer,"normal_binary":true}));

        let server=ValidProofServer::start_mode(ProofPeerMode::DenyRequests);let mut adapter=Adapter::start(binary,&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
        let mut exact=request(server.discovery["instance_id"].as_str(),None,"input.write",json!({"pane_id":"40000000-0000-4000-8000-000000000000","run_id":"50000000-0000-4000-8000-000000000000","text":""}));
        let base=serde_json::to_vec(&exact).unwrap().len();exact["params"]["text"]="a".repeat(winsmux_workspace::contract::MAX_MESSAGE_BYTES-base).into();
        let typed=winsmux_workspace::contract::parse_request(&serde_json::to_vec(&exact).unwrap()).unwrap();assert_eq!(winsmux_workspace::contract::canonical_request(&typed).unwrap().len(),winsmux_workspace::contract::MAX_MESSAGE_BYTES);
        assert_eq!(call(&mut adapter,30,exact)["result"]["structuredContent"]["error"]["code"],"permission_denied");
        let japanese=request(server.discovery["instance_id"].as_str(),None,"input.write",json!({"pane_id":"40000000-0000-4000-8000-000000000000","run_id":"50000000-0000-4000-8000-000000000000","text":"日本語😀"}));
        let expected=winsmux_workspace::contract::canonical_request(&winsmux_workspace::contract::parse_request(&serde_json::to_vec(&japanese).unwrap()).unwrap()).unwrap();
        let envelope=serde_json::to_vec(&json!({"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":japanese}})).unwrap();
        for byte in &envelope{write_bytes(adapter.input.as_ref().unwrap(),std::slice::from_ref(byte));}write_bytes(adapter.input.as_ref().unwrap(),b"\n");
        assert_eq!(adapter.reply()["result"]["structuredContent"]["error"]["code"],"permission_denied");adapter.finish(0,None);let peer=server.finish();
        assert_eq!(peer["ordinary_frames"],2);assert_eq!(peer["largest_ordinary_bytes"],winsmux_workspace::contract::MAX_MESSAGE_BYTES);
        let expected_sha:String=Sha256::digest(&expected).iter().map(|b|format!("{b:02x}")).collect();assert_eq!(peer["last_ordinary_sha256"],expected_sha);
        println!("{}",json!({"class":"actual canonical inner exact and split UTF8 one frame","server_input":server_input,"asynchronous":asynchronous,"peer":peer,"normal_binary":true,"product_host_effects_not_measured":true}));

        for bad in [vec![b' ';winsmux_workspace_mcp::MAX_MCP_MESSAGE_BYTES+1],vec![0xff,b'\n'],b"{\"jsonrpc\":\"2.0\"".to_vec(),vec![0xe6,0x97]] {
            let server=ValidProofServer::start_mode(ProofPeerMode::AuthOnly);let adapter=Adapter::start(binary,&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),None);
            server.received();let mut written=0;
            let write_ok=unsafe {WriteFile(adapter.input.as_ref().unwrap().0,bad.as_ptr(),bad.len() as u32,&mut written,null_mut())}!=0;
            let write_error=if write_ok{0}else{unsafe {GetLastError()}};
            if write_ok{assert_eq!(written as usize,bad.len());}else{assert_eq!(write_error,ERROR_BROKEN_PIPE,"fatal input may close peer before an oversize write completes");}
            adapter.finish(1,Some("protocol_failed"));let peer=server.finish();assert_eq!(peer["ordinary_frames"],0);
            println!("{}",json!({"class":"actual fatal codec outer plus one invalid UTF8 partial EOF","input_bytes":bad.len(),"write_succeeded":write_ok,"write_bytes":written,"write_error":write_error,"server_input":server_input,"asynchronous":asynchronous,"stdout_bytes":0,"peer":peer,"normal_binary":true}));
        }
    }
    fn authentication_negative(binary:&str) {
        use winsmux_workspace::host::testing::{RogueProof,RogueServer};
        for kind in [RogueProof::KeySubstitution,RogueProof::SignatureMutation,RogueProof::ReplayNonce,RogueProof::InstanceMismatch,
            RogueProof::PipeNameMismatch,RogueProof::ClientPidMismatch,RogueProof::ServerPidMismatch,RogueProof::SameLogonRelay,RogueProof::WrongLength,RogueProof::WrongMagic] {
            for shape in 0..5 {
                let server=RogueServer::start(kind).unwrap();let discovery:Value=serde_json::from_slice(server.discovery()).unwrap();
                let pair=if shape==4{let(input,writer)=anonymous();PipePair{input,writer}}else{named(shape<2,shape%2==1,PIPE_TYPE_BYTE|PIPE_WAIT)};
                let mut adapter=Adapter::start(binary,&discovery,pair,None);
                // Keep all input write ends open through the rejected proof and
                // public EOF. The refusal cannot be manufactured by stdin EOF.
                let observed=server.finish().unwrap();assert_eq!(observed.authentication_request_bytes,44);assert_eq!(observed.request_bytes_after_proof,0);
                assert_eq!(adapter.child.wait().unwrap().code(),Some(1));adapter.finish(1,Some("protocol_failed"));
                execution(json!({"stage":"rogue proof actual server thread joined","kind":format!("{kind:?}"),"input_shape":shape,"authentication_request_bytes":44,"ordinary_bytes":0,"stdin_still_open_until_adapter_actual_exit":true}));
                println!("{}",json!({"class":"normal MCP native proof refusal","kind":format!("{kind:?}"),"input_shape":shape,"adapter_exit":1,"stdout_bytes":0,"ordinary_bytes":0,"actual_authentication_request_bytes":44,"server_thread_joined":true}));
            }
        }
        // Reuse the production DACL and header-first peer verifier's exact
        // public native probe. These local ephemeral token/pipes do not use a
        // workspace store or persist/change OS security settings.
        let os=winsmux_workspace::host::testing::run_os_authentication_probes().unwrap();
        assert!(os.anonymous_user_differs&&os.anonymous_has_no_logon&&os.anonymous_production_acl_denied);
        assert!(os.new_credentials_same_user&&os.new_credentials_has_logon&&os.new_credentials_logon_differs&&os.new_credentials_production_acl_allowed);
        assert!(os.new_credentials_current_logon_group_enabled&&!os.new_credentials_current_logon_group_deny_only);
        assert!(os.restricted_same_user&&os.restricted_logon_unchanged&&!os.restricted_current_logon_group_enabled&&os.restricted_current_logon_group_deny_only&&os.restricted_production_acl_denied);
        for peer in [&os.anonymous_peer,&os.new_credentials_peer] {
            assert!(peer.impersonated&&peer.user_checked&&peer.reverted&&peer.body_marker_unread);assert_eq!(peer.authorization_records,0);assert!(!peer.failure.is_empty());
        }
        assert_eq!(os.anonymous_peer.failure,"UserMismatch");assert!(!os.anonymous_peer.logon_checked);
        assert_eq!(os.new_credentials_peer.failure,"LogonMismatch");assert!(os.new_credentials_peer.logon_checked);
        let peer=|p:&winsmux_workspace::host::testing::PeerProbeEvidence|json!({"failure":p.failure,"impersonated":p.impersonated,"user_checked":p.user_checked,"logon_checked":p.logon_checked,"reverted":p.reverted,"body_marker_unread":p.body_marker_unread,"authorization_records":p.authorization_records});
        println!("{}",json!({"class":"actual production OS authentication probe","anonymous_acl_denied":os.anonymous_production_acl_denied,"anonymous_peer":peer(&os.anonymous_peer),"new_credentials_same_user_distinct_logon":os.new_credentials_same_user&&os.new_credentials_logon_differs,"new_credentials_outer_acl_allowed":os.new_credentials_production_acl_allowed,"new_credentials_peer":peer(&os.new_credentials_peer),"deny_only_logon_outer_acl_denied":os.restricted_production_acl_denied,"probe_entry":"existing host::testing::run_os_authentication_probes","normal_MCP_token_process_injection_not_measured":true,"known_folder_used":false}));
    }
    fn held_proof(binary:&str,initialize_line:bool,server_input:bool,asynchronous:bool) {
        held_proof_input(binary,initialize_line,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),&format!("named server={server_input} async={asynchronous}"));
    }
    fn held_proof_input(binary:&str,initialize_line:bool,pair:PipePair,input_class:&str) {
        let discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
        let name=wide(discovery["pipe_name"].as_str().unwrap());
        let pipe=Handle::new(unsafe {CreateNamedPipeW(name.as_ptr(),PIPE_ACCESS_DUPLEX,PIPE_TYPE_BYTE|PIPE_WAIT,1,65536,65536,0,null())});
        let ready=Arc::new(Handle::event());let server_ready=ready.clone();
        let server=thread::spawn(move || {
            let pipe=pipe;
            let connected=unsafe {ConnectNamedPipe(pipe.0,null_mut())};
            if connected==0 {assert_eq!(unsafe {GetLastError()},ERROR_PIPE_CONNECTED);}
            let mut header=[0u8;4]; let mut count=0;
            assert_ne!(unsafe {ReadFile(pipe.0,header.as_mut_ptr(),4,&mut count,null_mut())},0);assert_eq!(count,4);
            let length=u32::from_le_bytes(header) as usize;assert!(length>0&&length<=1048576);
            let mut body=vec![0;length];let mut offset=0;
            while offset<length {assert_ne!(unsafe {ReadFile(pipe.0,body[offset..].as_mut_ptr(),(length-offset) as u32,&mut count,null_mut())},0);assert!(count>0);offset+=count as usize;}
            unsafe {SetEvent(server_ready.0);}
            let mut ordinary=[0u8;4];count=0;
            assert_eq!(unsafe {ReadFile(pipe.0,ordinary.as_mut_ptr(),4,&mut count,null_mut())},0);
            assert_eq!(unsafe {GetLastError()},ERROR_BROKEN_PIPE);assert_eq!(count,0);
            json!({"auth_frames":1,"ordinary_bytes":0,"peer_eof":true,"reply_sent":false})
        });
        let adapter=Adapter::start(binary,&discovery,pair,None);
        assert_eq!(unsafe {WaitForSingleObject(ready.0,INFINITE)},WAIT_OBJECT_0);
        if initialize_line {adapter.send(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"TASK875","version":"1"}}}));}
        let replies=adapter.finish(0,None);assert!(replies.is_empty());
        let peer=server.join().unwrap();execution(json!({"stage":"held proof actual server thread joined","input_class":input_class,"initialize_line":initialize_line,"peer":peer}));
        println!("{}",json!({"class":"held-proof EOF","initialize_line":initialize_line,"input_class":input_class,"normal_binary":true,"adapter_exit":0,"stdout_bytes":0,"peer":peer}));
    }
    fn rejected_rights(binary:&str,access:u32,server_input:bool,asynchronous:bool) {
        let pair=named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT);
        let limited=pair.input.duplicate(access,false);
        let metadata=metadata_success(&limited);assert!(metadata,"metadata succeeds for original F2 sibling");
        let discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
        let name=wide(discovery["pipe_name"].as_str().unwrap());
        let server=Handle::new(unsafe {CreateNamedPipeW(name.as_ptr(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED,PIPE_TYPE_BYTE|PIPE_WAIT,1,65536,65536,0,null())});
        let event=Handle::event();let mut overlapped:OVERLAPPED=unsafe {zeroed()};overlapped.hEvent=event.0;
        assert_eq!(unsafe {ConnectNamedPipe(server.0,&mut overlapped)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_PENDING);
        let adapter=Adapter::start(binary,&discovery,PipePair{input:limited,writer:pair.writer},None);
        adapter.finish(1,Some("startup_failed"));
        let mut count=0;assert_eq!(unsafe {GetOverlappedResult(server.0,&overlapped,&mut count,0)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_INCOMPLETE);
        unsafe {CancelIoEx(server.0,&overlapped);}
        assert_eq!(unsafe {GetOverlappedResult(server.0,&overlapped,&mut count,1)},0);assert_eq!(unsafe {GetLastError()},ERROR_OPERATION_ABORTED);
        println!("{}",json!({"class":"metadata success no read right","access":access,"server_input":server_input,"asynchronous":asynchronous,"metadata_success":metadata,"normal_binary":true,"auth_connections":0,"ordinary_frames":0,"stdout_bytes":0,"adapter_exit":1,"listener_drained":true}));
        let pair=named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT);
        let limited=pair.input.duplicate(access,false);
        let gate=FixtureGate::new();
        let adapter=gate.adapter(&discovery,PipePair{input:limited,writer:pair.writer},"BeforeAuth",false,0);
        adapter.finish(1,None);let result=gate.result();drains(&result,0,0,0);
        assert_eq!(result["observations"]["read_capable"],false);assert_eq!(result["observations"]["mode_queries"],0);
        println!("{}",json!({"class":"rights refusal reader/auth observer","access":access,"server_input":server_input,"asynchronous":asynchronous,"normal_binary":false,"native_result":result}));
    }
    fn reject_input(binary:&str,pair:PipePair,class:&str) {
        let discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
        let name=wide(discovery["pipe_name"].as_str().unwrap());
        let listener=Handle::new(unsafe {CreateNamedPipeW(name.as_ptr(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED,PIPE_TYPE_BYTE|PIPE_WAIT,1,4096,4096,0,null())});
        let event=Handle::event();let mut overlapped:OVERLAPPED=unsafe {zeroed()};overlapped.hEvent=event.0;
        assert_eq!(unsafe {ConnectNamedPipe(listener.0,&mut overlapped)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_PENDING);
        Adapter::start(binary,&discovery,pair,None).finish(1,Some("startup_failed"));
        let mut count=0;assert_eq!(unsafe {GetOverlappedResult(listener.0,&overlapped,&mut count,0)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_INCOMPLETE);
        unsafe {CancelIoEx(listener.0,&overlapped);}
        assert_eq!(unsafe {GetOverlappedResult(listener.0,&overlapped,&mut count,1)},0);assert_eq!(unsafe {GetLastError()},ERROR_OPERATION_ABORTED);
        println!("{}",json!({"class":class,"normal_binary":true,"auth_connections":0,"stdout_bytes":0,"adapter_exit":1,"listener_drained":true}));
    }
    fn unsupported_inputs(binary:&str) {
        for server_input in [true,false] {for asynchronous in [false,true] {
            reject_input(binary,named(server_input,asynchronous,PIPE_TYPE_MESSAGE|PIPE_WAIT),"MESSAGE pipe refusal");
            let pair=named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT);let mode=PIPE_NOWAIT;
            assert_ne!(unsafe {SetNamedPipeHandleState(pair.input.0,&mode,null(),null())},0);
            reject_input(binary,pair,"NOWAIT pipe refusal");
            let pair=named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT);
            let not_waitable=pair.input.duplicate(FILE_READ_DATA|FILE_READ_ATTRIBUTES,false);
            reject_input(binary,PipePair{input:not_waitable,writer:pair.writer},"read rights without synchronize refusal");
        }}
        let path=std::env::temp_dir().join(unique("file-stdin"));std::fs::write(&path,b"").unwrap();
        let path_wide:Vec<u16>=path.as_os_str().encode_wide().chain(Some(0)).collect();
        let input=Handle::new(unsafe {CreateFileW(path_wide.as_ptr(),GENERIC_READ,FILE_SHARE_READ,null(),OPEN_EXISTING,0,null_mut())});
        let (_,writer)=anonymous();reject_input(binary,PipePair{input,writer},"file stdin refusal");std::fs::remove_file(path).unwrap();
        let input=Handle::new(unsafe {CreateFileW(wide("NUL").as_ptr(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,null(),OPEN_EXISTING,0,null_mut())});
        let (_,writer)=anonymous();reject_input(binary,PipePair{input,writer},"NUL character stdin refusal");
    }
    fn release_entry_negative() {
        let binary=std::env::var("TASK875_RELEASE_MCP_BIN").expect("formal release profile supplies exact actual normal MCP executable");
        for shape in 0..5 {
            let discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
            let listener=Handle::new(unsafe {CreateNamedPipeW(wide(discovery["pipe_name"].as_str().unwrap()).as_ptr(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED,PIPE_TYPE_BYTE|PIPE_WAIT,1,4096,4096,0,null())});
            let event=Handle::event();let mut overlapped:OVERLAPPED=unsafe {zeroed()};overlapped.hEvent=event.0;
            assert_eq!(unsafe {ConnectNamedPipe(listener.0,&mut overlapped)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_PENDING);
            let pair=if shape==4{let (input,writer)=anonymous();PipePair{input,writer}}else{named(shape<2,shape%2==1,PIPE_TYPE_BYTE|PIPE_WAIT)};
            let arguments=vec!["--fixture-runtime".to_owned(),discovery.to_string()];
            Adapter::start(&binary,&discovery,pair,Some(&arguments)).finish(2,Some("usage"));
            let mut transferred=0;assert_eq!(unsafe {GetOverlappedResult(listener.0,&overlapped,&mut transferred,0)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_INCOMPLETE);
            assert_ne!(unsafe {CancelIoEx(listener.0,&overlapped)},0);assert_eq!(unsafe {GetOverlappedResult(listener.0,&overlapped,&mut transferred,1)},0);assert_eq!(unsafe {GetLastError()},ERROR_OPERATION_ABORTED);
            println!("{}",json!({"class":"normal release executable rejects fixture argv before any host connection","input_shape":shape,"actual_exit":2,"stdout_bytes":0,"auth_connections":0,"actual_listener_cancel_completion":true,"normal_release_binary":true}));
        }
    }
    // Special stdin values are passed by the test-owned native STARTUPINFO,
    // never wrapped in OwnedHandle or installed into the parent's std handles.
    struct NativeAdmissionChild {process:Handle,stdout:Option<Handle>,stderr:Option<Handle>,release:Option<Handle>,finished:bool}
    impl NativeAdmissionChild {
        fn start(binary:&str,arguments:&[String],stdin:HANDLE,release:Option<Handle>)->Self {
            let bytes=std::fs::read(binary).unwrap();let sha:String=Sha256::digest(&bytes).iter().map(|b|format!("{b:02x}")).collect();
            let (stdout,stdout_write)=anonymous();let (stderr,stderr_write)=anonymous();
            let mut handles=vec![stdout_write.0,stderr_write.0];if !stdin.is_null()&&stdin!=INVALID_HANDLE_VALUE {handles.push(stdin);}
            for handle in &handles {assert_ne!(unsafe {SetHandleInformation(*handle,HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT)},0);}
            let mut size=0;unsafe {InitializeProcThreadAttributeList(null_mut(),1,0,&mut size);}
            let mut storage=vec![0usize;size.div_ceil(size_of::<usize>())];let attributes=storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
            assert_ne!(unsafe {InitializeProcThreadAttributeList(attributes,1,0,&mut size)},0);
            assert_ne!(unsafe {UpdateProcThreadAttribute(attributes,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,handles.as_ptr() as *const _,handles.len()*size_of::<HANDLE>(),null_mut(),null())},0);
            let mut startup:STARTUPINFOEXW=unsafe {zeroed()};startup.StartupInfo.cb=size_of::<STARTUPINFOEXW>() as u32;startup.lpAttributeList=attributes;
            startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;startup.StartupInfo.hStdInput=stdin;startup.StartupInfo.hStdOutput=stdout_write.0;startup.StartupInfo.hStdError=stderr_write.0;
            let mut command=wide(&std::iter::once(quoted(binary)).chain(arguments.iter().map(|a|quoted(a))).collect::<Vec<_>>().join(" "));
            let mut information:PROCESS_INFORMATION=unsafe {zeroed()};let ok=unsafe {CreateProcessW(wide(binary).as_ptr(),command.as_mut_ptr(),null(),null(),1,EXTENDED_STARTUPINFO_PRESENT,null(),null(),&startup.StartupInfo,&mut information)};
            let error=if ok==0{unsafe {GetLastError()}}else{0};unsafe {DeleteProcThreadAttributeList(attributes);}
            assert_ne!(ok,0,"special stdin native process creation: {error}");unsafe {CloseHandle(information.hThread);}
            let child=Self{process:Handle::new(information.hProcess),stdout:Some(stdout),stderr:Some(stderr),release,finished:false};
            execution(json!({"stage":"special stdin actual process created","process":process_identity(child.process.0),"binary_sha256":sha,"binary_bytes":bytes.len(),"handle_list_count":handles.len(),"null_stdin":stdin.is_null(),"invalid_stdin":stdin==INVALID_HANDLE_VALUE,"normal_binary":arguments.first().map(String::as_str)==Some("--discovery-json")}));
            for handle in &handles {assert_ne!(unsafe {SetHandleInformation(*handle,HANDLE_FLAG_INHERIT,0)},0);}
            drop(stdout_write);drop(stderr_write);child
        }
        fn finish(mut self,diagnostic:Option<&str>,ready:Option<HANDLE>) {
            if let Some(ready)=ready {
                let waited=unsafe {WaitForMultipleObjects(2,[self.process.0,ready].as_ptr(),0,INFINITE)};assert!(waited==WAIT_OBJECT_0||waited==WAIT_OBJECT_0+1);
                if waited==WAIT_OBJECT_0+1 {assert_ne!(unsafe {SetEvent(self.release.as_ref().unwrap().0)},0);execution(json!({"stage":"unexpected special stdin admission canceled before auth","process":process_identity(self.process.0),"original_failure_preserved":true}));}
            }
            assert_eq!(unsafe {WaitForSingleObject(self.process.0,INFINITE)},WAIT_OBJECT_0);let mut code=0;assert_ne!(unsafe {GetExitCodeProcess(self.process.0,&mut code)},0);
            let mut stdout=Vec::new();PipeRead(self.stdout.take().unwrap()).read_to_end(&mut stdout).unwrap();let mut stderr=Vec::new();PipeRead(self.stderr.take().unwrap()).read_to_end(&mut stderr).unwrap();self.finished=true;
            execution(json!({"stage":"special stdin actual process terminated","process":process_identity(self.process.0),"actual_exit":code,"stdout_bytes":stdout.len(),"stdout_stderr_actual_eof":true}));
            assert_eq!(code,1);assert!(stdout.is_empty());assert_eq!(stderr,diagnostic.map(|s|format!("winsmux workspace mcp: {s}\n").into_bytes()).unwrap_or_default());
        }
    }
    impl Drop for NativeAdmissionChild {fn drop(&mut self){if !self.finished {self.stdout.take();self.stderr.take();if let Some(event)=&self.release{unsafe {SetEvent(event.0);}}assert_eq!(unsafe {WaitForSingleObject(self.process.0,INFINITE)},WAIT_OBJECT_0);let mut code=0;assert_ne!(unsafe {GetExitCodeProcess(self.process.0,&mut code)},0);execution(json!({"stage":"special stdin failure actual process drain","process":process_identity(self.process.0),"actual_exit":code,"force_kill":false,"original_failure_preserved":true}));}}}
    fn special_stdin_refusal(binary:&str,stdin:HANDLE,class:&str) {
        let discovery:Value=serde_json::from_slice(&canonical_discovery_json().unwrap()).unwrap();
        let listener=Handle::new(unsafe {CreateNamedPipeW(wide(discovery["pipe_name"].as_str().unwrap()).as_ptr(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED,PIPE_TYPE_BYTE|PIPE_WAIT,1,4096,4096,0,null())});
        let event=Handle::event();let mut pending:OVERLAPPED=unsafe {zeroed()};pending.hEvent=event.0;
        assert_eq!(unsafe {ConnectNamedPipe(listener.0,&mut pending)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_PENDING);
        NativeAdmissionChild::start(binary,&["--discovery-json".into(),discovery.to_string()],stdin,None).finish(Some("startup_failed"),None);
        let mut transferred=0;assert_eq!(unsafe {GetOverlappedResult(listener.0,&pending,&mut transferred,0)},0);assert_eq!(unsafe {GetLastError()},ERROR_IO_INCOMPLETE);
        assert_ne!(unsafe {CancelIoEx(listener.0,&pending)},0);assert_eq!(unsafe {GetOverlappedResult(listener.0,&pending,&mut transferred,1)},0);assert_eq!(unsafe {GetLastError()},ERROR_OPERATION_ABORTED);
        let gate=FixtureGate::new();let arguments=vec!["--fixture-runtime".to_owned(),discovery.to_string(),"BeforeAuth".to_owned(),gate.result.to_string_lossy().into_owned(),gate.ready_name.clone(),gate.release_name.clone(),"cancel".to_owned(),"0".to_owned()];
        NativeAdmissionChild::start(std::env::current_exe().unwrap().to_str().unwrap(),&arguments,stdin,Some(gate.release.duplicate(0,true))).finish(None,Some(gate.ready.0));
        let observed=gate.result();drains(&observed,0,0,0);
        println!("{}",json!({"class":class,"normal_binary_refusal":true,"reader_auth_ordinary_zero":true,"actual_listener_unconnected_canceled_drained":true,"native_result":observed}));
        execution(json!({"stage":"special stdin default deny class completed","class":class,"normal_actual_exit":1,"stdout_bytes":0,"reader_starts":0,"auth_attempts":0,"actual_listener_unconnected_canceled_drained":true}));
    }
    struct SocketInput {socket:windows_sys::Win32::Networking::WinSock::SOCKET,started:bool}
    impl SocketInput {
        fn new()->Self {
            use windows_sys::Win32::Networking::WinSock::*;
            let mut owned=Self{socket:INVALID_SOCKET,started:false};let mut data:WSADATA=unsafe {zeroed()};assert_eq!(unsafe {WSAStartup(0x0202,&mut data)},0);owned.started=true;
            owned.socket=unsafe {WSASocketW(AF_INET as i32,SOCK_STREAM,IPPROTO_TCP,null(),0,WSA_FLAG_OVERLAPPED)};assert_ne!(owned.socket,INVALID_SOCKET);owned
        }
    }
    impl Drop for SocketInput {fn drop(&mut self){use windows_sys::Win32::Networking::WinSock::*;unsafe {if self.socket!=INVALID_SOCKET {assert_eq!(closesocket(self.socket),0);}if self.started {assert_eq!(WSACleanup(),0);}}}}
    fn console_stdin_proxy(binary:&str) {
        let console=Handle::new(unsafe {CreateFileW(wide("CONIN$").as_ptr(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,null(),OPEN_EXISTING,0,null_mut())});
        assert_eq!(unsafe {GetFileType(console.0)},FILE_TYPE_CHAR);let mut mode=0;assert_ne!(unsafe {GetConsoleMode(console.0,&mut mode)},0);
        let parent=std::process::id();let mut hosts=Vec::new();
        for (pid,ppid) in process_entries() {if ppid==parent {
            let raw=unsafe {OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,0,pid)};if raw.is_null(){continue;}let handle=Handle::new(raw);
            if process_image(&handle).file_name().is_some_and(|s|s.to_string_lossy().eq_ignore_ascii_case("conhost.exe")){execution(json!({"stage":"owned special console host registered","process":process_identity(handle.0)}));hosts.push(handle);}
        }}
        execution(json!({"stage":"actual owned console stdin verified","process":process_identity(unsafe {GetCurrentProcess()}),"file_type_char":true,"GetConsoleMode_success":true,"console_mode":mode,"owned_console_hosts":hosts.len()}));
        assert_eq!(hosts.len(),1,"one owned hidden console host for the dedicated console proxy");
        special_stdin_refusal(binary,console.0,"actual console stdin refusal");drop(console);assert_ne!(unsafe {FreeConsole()},0);
        for host in hosts {assert_eq!(unsafe {WaitForSingleObject(host.0,INFINITE)},WAIT_OBJECT_0);execution(json!({"stage":"owned special console host actual exit","process":process_identity(host.0)}));}
    }
    fn special_input_classes(binary:&str) {
        special_stdin_refusal(binary,null_mut(),"NULL stdin refusal");special_stdin_refusal(binary,INVALID_HANDLE_VALUE,"INVALID stdin refusal");
        {let socket=SocketInput::new();special_stdin_refusal(binary,socket.socket as HANDLE,"unconnected socket stdin refusal");}
        let executable=std::env::current_exe().unwrap();let mut command=wide(&format!("{} --fixture-console-rejection {}",quoted(&executable.to_string_lossy()),quoted(binary)));
        let mut startup:STARTUPINFOW=unsafe {zeroed()};startup.cb=size_of::<STARTUPINFOW>() as u32;startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=0;
        let mut information:PROCESS_INFORMATION=unsafe {zeroed()};let path:Vec<u16>=executable.as_os_str().encode_wide().chain(Some(0)).collect();
        assert_ne!(unsafe {CreateProcessW(path.as_ptr(),command.as_mut_ptr(),null(),null(),0,CREATE_NEW_CONSOLE,null(),null(),&startup,&mut information)},0);unsafe {CloseHandle(information.hThread);}
        let proxy=Handle::new(information.hProcess);execution(json!({"stage":"owned hidden console proxy created","process":process_identity(proxy.0),"inherited_handle_count":0,"known_folder_used":false}));
        assert_eq!(unsafe {WaitForSingleObject(proxy.0,INFINITE)},WAIT_OBJECT_0);let mut code=0;assert_ne!(unsafe {GetExitCodeProcess(proxy.0,&mut code)},0);execution(json!({"stage":"owned hidden console proxy actual exit","process":process_identity(proxy.0),"actual_exit":code}));assert_eq!(code,0);
        for initialize in [false,true] {let (input,writer)=anonymous();held_proof_input(binary,initialize,PipePair{input,writer},"inherited anonymous synchronous");}
    }
    fn gate_from_name(name:&str) -> GatePoint {
        match name {"AccessComplete"=>GatePoint::AccessComplete,"ModeComplete"=>GatePoint::ModeComplete,
            "BeforeReaderSpawn"=>GatePoint::BeforeReaderSpawn,"ReaderRegistered"=>GatePoint::ReaderRegistered,
            "BeforeAuth"=>GatePoint::BeforeAuth,"Authenticated"=>GatePoint::Authenticated,"BeforeRead"=>GatePoint::BeforeRead,
            "ReadComplete"=>GatePoint::ReadComplete,"BeforeDeposit"=>GatePoint::BeforeDeposit,"BeforeSend"=>GatePoint::BeforeSend,
            "BeforePublish"=>GatePoint::BeforePublish,"BeforeWrite"|"BeforeWriteCall"=>GatePoint::BeforeWrite,"AfterFlush"=>GatePoint::AfterFlush,_=>panic!("unknown fixture gate")}
    }
    struct FixtureGate { ready:Handle, release:Handle, ready_name:String, release_name:String, result:PathBuf }
    impl FixtureGate {
        fn new()->Self {
            let ready_name=unique("gate-ready");let release_name=unique("gate-release");
            let ready=Handle::new(unsafe {CreateEventW(null(),1,0,wide(&ready_name).as_ptr())});
            let release=Handle::new(unsafe {CreateEventW(null(),1,0,wide(&release_name).as_ptr())});
            Self{ready,release,ready_name,release_name,result:std::env::temp_dir().join(unique("gate-result.json"))}
        }
        fn adapter(&self,discovery:&Value,pair:PipePair,point:&str,cancel:bool,receipts:u64)->Adapter {
            let args=vec!["--fixture-runtime".to_owned(),discovery.to_string(),point.to_owned(),self.result.to_string_lossy().into_owned(),
                self.ready_name.clone(),self.release_name.clone(),if cancel {"cancel"}else{"release"}.to_owned(),receipts.to_string()];
            let mut adapter=Adapter::start(std::env::current_exe().unwrap().to_str().unwrap(),discovery,pair,Some(&args));
            adapter.recovery_release=Some(self.release.duplicate(0,true));adapter
        }
        fn reached(&self){assert_eq!(unsafe {WaitForSingleObject(self.ready.0,INFINITE)},WAIT_OBJECT_0);}
        fn release(&self){assert_ne!(unsafe {SetEvent(self.release.0)},0);}
        fn result(&self)->Value {
            let bytes=std::fs::read(&self.result).unwrap();let value=serde_json::from_slice(&bytes).unwrap();
            std::fs::remove_file(&self.result).unwrap();value
        }
    }
    fn drains(value:&Value,readers:u64,auth:u64,ordinary:u64) {
        let observed=&value["observations"];
        assert_eq!(observed["readers_started"],readers);assert_eq!(observed["reader_exited"],readers);
        assert_eq!(observed["auth_attempts"],auth);assert_eq!(observed["ordinary_attempts"],ordinary);
        assert_eq!(observed["worker_exited"],1);assert_eq!(observed["worker_joined"],true);assert_eq!(observed["writer_joined"],true);
        for kind in ["access","mode"] {
            if observed[format!("{kind}_queries")].as_u64().unwrap()!=0 {
                assert!(matches!(observed[format!("{kind}_returned_status")].as_i64(),Some(0)|Some(0x103)));
                assert_eq!(observed[format!("{kind}_final_status")],0);
                assert_eq!(observed[format!("{kind}_information")],4);
            }
        }
        if readers!=0 {assert_eq!(observed["reader_joined"],true);}
    }
    fn lifecycle_gates(owner:&mut CliOwner,server_input:bool,asynchronous:bool) {
        for point in ["AccessComplete","ModeComplete","BeforeReaderSpawn","ReaderRegistered","BeforeAuth","Authenticated","BeforeRead","ReadComplete","BeforeDeposit"] {
            let gate=FixtureGate::new();
            let adapter=gate.adapter(&owner.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),point,true,0);
            if matches!(point,"ReadComplete"|"BeforeDeposit") {adapter.send(&json!({"jsonrpc":"2.0","id":1,"method":"ping"}));}
            gate.reached();gate.release();adapter.finish(0,None);
            let result=gate.result();
            let readers=if matches!(point,"AccessComplete"|"ModeComplete"|"BeforeReaderSpawn"){0}else{1};
            // BeforeRead/line gates race authentication honestly; no fixed auth count is inferred.
            let auth=result["observations"]["auth_attempts"].as_u64().unwrap();assert!(auth<=1);
            if matches!(point,"AccessComplete"|"ModeComplete"|"BeforeReaderSpawn"|"ReaderRegistered"|"BeforeAuth") {assert_eq!(auth,0);}
            if point=="Authenticated" {assert_eq!(auth,1);assert_eq!(result["observations"]["auth_completed"],1);}
            drains(&result,readers,auth,0);
            if point=="AccessComplete" {assert_eq!(result["observations"]["mode_queries"],0);}
            println!("{}",json!({"class":"same production lifetime stop gate","point":point,"server_input":server_input,"asynchronous":asynchronous,"native_result":result,"normal_binary":false}));
        }
    }
    fn cancellation_gates(owner:&mut CliOwner,server_input:bool,asynchronous:bool) {
        for point in ["BeforeSend","BeforePublish"] {
            let gate=FixtureGate::new();
            let mut adapter=gate.adapter(&owner.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),point,false,4);
            adapter.initialize();
            adapter.send(&json!({"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request(owner.discovery["instance_id"].as_str(),None,"project.list",json!({}))}}));
            gate.reached();
            adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30}}));
            gate.release();
            adapter.send(&json!({"jsonrpc":"2.0","id":31,"method":"ping"}));
            let pong=adapter.reply();assert_eq!(pong["id"],31);assert_eq!(pong["result"],json!({}));
            if point=="BeforePublish" {
                let denied=call(&mut adapter,32,request(owner.discovery["instance_id"].as_str(),None,"project.list",json!({})));
                assert_eq!(denied["error"]["code"],-32603);
            } else {
                let accepted=call(&mut adapter,32,request(owner.discovery["instance_id"].as_str(),None,"project.list",json!({})));
                assert_eq!(accepted["result"]["structuredContent"]["error"]["code"],"permission_denied");
            }
            adapter.finish(0,None);let result=gate.result();drains(&result,1,1,1);
            println!("{}",json!({"class":"captured cancellation versus send/publication","point":point,"server_input":server_input,"asynchronous":asynchronous,"canceled_response_count":0,"native_result":result,"normal_binary":false}));
        }
    }
    fn publication_class(binary:&str,server_input:bool,asynchronous:bool) {
        for old_cancel in [false,true] {
            let server=ValidProofServer::start_mode(ProofPeerMode::DenyRequests);let gate=FixtureGate::new();
            let mut adapter=gate.adapter(&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),"BeforeWriteCall",false,4);
            adapter.initialize();let instance=server.discovery["instance_id"].as_str();
            adapter.send(&json!({"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request(instance,None,"project.list",json!({}))}}));gate.reached();
            if old_cancel {adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30}}));}
            else {adapter.send(&json!({"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request(instance,None,"project.list",json!({}))}}));}
            gate.release();let claimed=adapter.reply();assert_eq!(claimed["id"],30);assert_eq!(claimed["result"]["structuredContent"]["error"]["code"],"permission_denied");
            if !old_cancel {let busy=adapter.reply();assert_eq!(busy["id"],31);assert_eq!(busy["error"]["code"],-32000);}
            // The pong is processed after the prior publication's actual flush
            // marker and captured receipt. Reuse then belongs to a new ticket.
            adapter.send(&json!({"jsonrpc":"2.0","id":35,"method":"ping"}));assert_eq!(adapter.reply()["id"],35);
            let reused=call(&mut adapter,30,request(instance,None,"project.list",json!({})));assert_eq!(reused["result"]["structuredContent"]["error"]["code"],"permission_denied");
            adapter.finish(0,None);let observed=gate.result();drains(&observed,1,1,2);let peer=server.finish();assert_eq!(peer["ordinary_frames"],2);
            println!("{}",json!({"class":"Publishing busy/captured old cancel and post-flush ID reuse","server_input":server_input,"asynchronous":asynchronous,"old_cancel":old_cancel,"busy_distinct_call_frames":0,"new_ticket_after_flush":true,"normal_binary":false,"native_result":observed,"peer":peer,"product_host_authorization_not_measured":true}));
        }
        let _=binary;
    }
    // Same production runtime; dedicated authenticated peer only measures
    // input/cancellation/receipt/publication. No ProductHost grant is inferred.
    fn cancellation_notification_stage(pair:PipePair,input_class:&str,phase:&str,duplicate:bool) {
        let sent=phase=="Sent";
        let server=ValidProofServer::start_mode(if sent{ProofPeerMode::ControlledRequests}else{ProofPeerMode::DenyRequests});
        let gate=FixtureGate::new();
        let point=match phase {"Validated"|"Sent"=>"BeforeSend","Correlated"=>"BeforePublish","Publishing"=>"BeforeWriteCall",_=>panic!("fixed cancellation stage")};
        let mut adapter=gate.adapter(&server.discovery,pair,point,false,if sent{3}else{4});
        adapter.initialize();let instance=server.discovery["instance_id"].as_str();
        adapter.send(&json!({"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":request(instance,None,"project.list",json!({}))}}));
        gate.reached();
        if sent {gate.release();server.received();}
        let raw:&[u8]=if duplicate {
            br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30,"requestId":30}}
"#
        }else {
            br#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":30,"reason":7}}
"#
        };
        write_bytes(adapter.input.as_ref().unwrap(),raw);
        if sent {
            // Actual pong proves the malformed receipt was consumed while the
            // peer still holds the ordinary response. It is not a timing guess.
            adapter.send(&json!({"jsonrpc":"2.0","id":35,"method":"ping"}));
            assert_eq!(adapter.reply(),json!({"jsonrpc":"2.0","id":35,"result":{}}));
            server.release_reply();
        }else {gate.release();}
        let response=adapter.reply();assert_eq!(response["id"],30);
        assert_eq!(response["result"]["structuredContent"]["error"]["code"],"permission_denied");
        if !sent {
            adapter.send(&json!({"jsonrpc":"2.0","id":35,"method":"ping"}));
            assert_eq!(adapter.reply(),json!({"jsonrpc":"2.0","id":35,"result":{}}));
        }
        // Pong is after first reply flush and the invalid receipt; same-ID
        // reuse belongs to a new ticket and must still reach the same peer.
        let reused=call(&mut adapter,30,request(instance,None,"project.list",json!({})));
        assert_eq!(reused["result"]["structuredContent"]["error"]["code"],"permission_denied");
        let replies=adapter.finish(0,None);assert_eq!(replies.len(),4);
        assert_eq!(replies.iter().filter(|r|r["id"]==30).count(),2);
        assert!(replies.iter().all(|r|!r["id"].is_null()),"invalid notification stdout zero");
        let observed=gate.result();drains(&observed,1,1,2);
        assert!(observed["result"].is_null());assert_eq!(observed["observations"]["control_cancel_signals"],0);
        assert_eq!(observed["observations"]["replies_flushed"],4);
        let peer=server.finish();assert_eq!(peer["auth_frames"],1);assert_eq!(peer["ordinary_frames"],2);assert_eq!(peer["peer_eof"],true);
        println!("{}",json!({"class":"malformed cancellation all actual call stages","input_class":input_class,"phase":phase,"malformation":if duplicate{"duplicate requestId"}else{"reason number"},"malformed_notification_reply_count":0,"cancel_signal_count":0,"first_call_reply_count":1,"same_id_new_ticket_call":true,"ordinary_frames":2,"auth_frames":1,"no_reconnect_or_resend":true,"actual_adapter_exit":0,"native_result":observed,"peer":peer,"normal_binary":false,"known_folder_used":false,"product_host":false}));
    }
    fn cancellation_notification_family(first_only:bool) {
        if first_only {cancellation_notification_stage(named(true,false,PIPE_TYPE_BYTE|PIPE_WAIT),"named server=true async=false","Sent",false);return;}
        for phase in ["Validated","Sent","Correlated","Publishing"] {for duplicate in [false,true] {
            for server_input in [true,false] {for asynchronous in [false,true] {
                cancellation_notification_stage(named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),&format!("named server={server_input} async={asynchronous}"),phase,duplicate);
            }}
            let (input,writer)=anonymous();cancellation_notification_stage(PipePair{input,writer},"anonymous inherited synchronous",phase,duplicate);
        }}
    }
    fn output_lifetime_class(binary:&str,server_input:bool,asynchronous:bool) {
        // The dedicated peer returns an exactly bounded typed response solely
        // to exercise transport/formatting. This does not claim ProductHost
        // authorization, OutputRing data, or a grant/effect on a real run.
        for (debug,broken) in [(false,false),(false,true),(true,false)] {
            let server=ValidProofServer::start_mode(ProofPeerMode::LargeReply);
            let wire=request(server.discovery["instance_id"].as_str(),None,"output.read",json!({"run_id":"50000000-0000-4000-8000-000000000000","cursor":null,"max_bytes":winsmux_workspace::contract::MAX_MESSAGE_BYTES}));
            let typed=winsmux_workspace::contract::parse_request(&serde_json::to_vec(&wire).unwrap()).unwrap();
            let response=winsmux_workspace::contract::parse_response(&typed,&serde_json::to_vec(&large_output_response(&wire)).unwrap()).unwrap();
            let list=json!({"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"winsmux_workspace_request","arguments":wire}});
            let mut session=winsmux_workspace_mcp::Session::new();
            session.on_line(br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#);
            session.on_line(br#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#);
            assert!(matches!(session.on_line(&serde_json::to_vec(&list).unwrap()),winsmux_workspace_mcp::Effect::StartCall{..}));assert!(session.begin_send());
            assert!(matches!(session.complete(&response),winsmux_workspace_mcp::Effect::PublishCall));let expected=session.pending_reply().unwrap().to_vec();
            let mut gate=if debug{Some(FixtureGate::new())}else{None};
            let mut adapter=if let Some(gate)=gate.as_mut(){gate.adapter(&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),"ReadComplete",false,0)}else{Adapter::start(binary,&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),None)};
            if let Some(gate)=gate.as_ref(){
                adapter.send(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}));
                gate.reached();gate.release();assert_eq!(adapter.reply()["id"],1);adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));
            }else{adapter.initialize();}
            let stdout=adapter.output.as_ref().unwrap().get_ref().as_raw_handle();let mut inbound=0;let mut outbound=0;
            assert_ne!(unsafe {GetNamedPipeInfo(stdout,null_mut(),&mut outbound,&mut inbound,null_mut())},0);
            let capacity=inbound.max(outbound) as usize;assert!(capacity>0);assert!(expected.len()>capacity+1,"finite typed reply exceeds actual stdout pipe capacity");
            adapter.send(&list);let mut prefix=[0;1];adapter.output.as_mut().unwrap().get_mut().read_exact(&mut prefix).unwrap();assert_eq!(prefix[0],expected[0]);
            assert_eq!(unsafe {WaitForSingleObject(adapter.child.as_raw_handle(),0)},WAIT_TIMEOUT,"claimed finite reply still owns the live writer before consumer release");
            execution(json!({"stage":"actual stdout finite reply exceeds pipe capacity","process":process_identity(adapter.child.as_raw_handle()),"reply_bytes":expected.len(),"pipe_capacity":capacity,"physical_prefix_bytes":1,"consumer_release":if broken{"close"}else{"drain"},"debug_runtime":debug}));
            if broken {
                // Stdin stays open: actual broken stdout, rather than a later
                // manufactured EOF, must cancel the reader and terminate.
                adapter.output.take();let status=adapter.child.wait().unwrap();assert_eq!(status.code(),Some(1));
                adapter.finish(1,Some("transport_failed"));
            }else{
                adapter.input.take();let reply=adapter.reply_after_prefix(prefix.to_vec());assert_eq!(serde_json::to_vec(&reply).unwrap(),expected);
                adapter.finish(0,None);
            }
            if let Some(gate)=gate {let observed=gate.result();drains(&observed,1,1,1);assert_eq!(observed["observations"]["eof_observed"],true);println!("{}",json!({"class":"actual bounded stdout backpressure EOF consumer drain","native_result":observed}));}
            let peer=server.finish();assert_eq!(peer["ordinary_frames"],1);
            println!("{}",json!({"class":"actual bounded stdout consumer drain/broken pipe","server_input":server_input,"asynchronous":asynchronous,"normal_binary":!debug,"broken_stdout":broken,"partial_output_replayed":false,"peer":peer,"product_host_authorization_not_measured":true}));
        }
        let server=ValidProofServer::start_mode(ProofPeerMode::CloseReply);let mut adapter=Adapter::start(binary,&server.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
        let lost=call(&mut adapter,50,request(server.discovery["instance_id"].as_str(),None,"project.list",json!({})));assert_eq!(lost["error"]["code"],-32603);
        let next=call(&mut adapter,51,request(server.discovery["instance_id"].as_str(),None,"project.list",json!({})));assert_eq!(next["error"]["code"],-32603);
        adapter.finish(1,Some("transport_failed"));let peer=server.finish();assert_eq!(peer["ordinary_frames"],1);
        println!("{}",json!({"class":"actual authenticated peer loss after one ordinary frame","server_input":server_input,"asynchronous":asynchronous,"normal_binary":true,"future_call_frames":0,"reconnect":0,"peer":peer,"ProductHost_owner_exit_not_measured":true}));
    }
    fn initialization_marker_gates(owner:&mut CliOwner,server_input:bool,asynchronous:bool) {
        let gate=FixtureGate::new();
        let mut adapter=gate.adapter(&owner.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),"AfterFlush",false,2);
        adapter.send(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"TASK875","version":"1"}}}));
        gate.reached();assert_eq!(adapter.reply()["result"]["protocolVersion"],"2025-11-25");
        adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));gate.release();
        adapter.send(&json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}));
        assert_eq!(adapter.reply()["result"]["tools"].as_array().unwrap().len(),1);
        adapter.finish(0,None);let result=gate.result();drains(&result,1,1,0);
        println!("{}",json!({"class":"peer initialized before internal flush marker","server_input":server_input,"asynchronous":asynchronous,"native_result":result,"normal_binary":false}));
        for point in ["BeforeWrite","AfterFlush"] {
            let gate=FixtureGate::new();let mut adapter=gate.adapter(&owner.discovery,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),point,false,0);
            let initialize=json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"TASK875","version":"1"}}});
            adapter.send(&initialize);gate.reached();
            if point=="AfterFlush" {assert_eq!(adapter.reply()["id"],1);}
            adapter.send(&initialize);
            // The reserved-ID duplicate closes through reader, waking the writer gate.
            // The first flight already won publication; it may complete, never twice.
            if point=="BeforeWrite" {assert_eq!(adapter.reply()["id"],1);}
            adapter.finish(1,None);gate.release();let result=gate.result();drains(&result,1,1,0);
            assert_eq!(result["result"],"protocol_failed");
            assert_eq!(result["observations"]["replies_flushed"],1);
            println!("{}",json!({"class":"initialize reserved ID duplicate","point":point,"server_input":server_input,"asynchronous":asynchronous,"second_response":false,"native_result":result,"normal_binary":false}));
        }
    }
    fn store_root() -> PathBuf {
        use windows_sys::Win32::UI::Shell::{FOLDERID_LocalAppData,SHGetKnownFolderPath};
        let mut raw=null_mut();assert_eq!(unsafe {SHGetKnownFolderPath(&FOLDERID_LocalAppData,0,null_mut(),&mut raw)},0);
        let mut length=0;unsafe {while *raw.add(length)!=0 {length+=1;}}
        let text=String::from_utf16(unsafe {std::slice::from_raw_parts(raw,length)}).unwrap();
        unsafe {windows_sys::Win32::System::Com::CoTaskMemFree(raw as *const _);}
        PathBuf::from(text).join("winsmux/workspace/v1")
    }
    fn root_identity(root:&Path) -> (u32,u32,u32) {
        let path:Vec<u16>=root.as_os_str().encode_wide().chain(Some(0)).collect();
        let handle=Handle::new(unsafe {CreateFileW(path.as_ptr(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,null(),OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,null_mut())});
        let mut info:BY_HANDLE_FILE_INFORMATION=unsafe {zeroed()};assert_ne!(unsafe {GetFileInformationByHandle(handle.0,&mut info)},0);
        assert_eq!(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT,0);
        (info.dwVolumeSerialNumber,info.nFileIndexHigh,info.nFileIndexLow)
    }
    fn logical_empty(bytes:&[u8]) -> Value {
        let snapshot=winsmux_workspace::contract::parse_snapshot(bytes).unwrap();
        let mut value=serde_json::to_value(snapshot).unwrap();
        for key in ["projects","panes","layouts"] {assert!(value[key].as_array().unwrap().is_empty(),"default store is not the reserved empty fixture state");}
        assert!(value["selected_project_id"].is_null()&&value["selected_pane_id"].is_null());
        value.as_object_mut().unwrap().remove("generation");value.as_object_mut().unwrap().remove("topology_revision");value
    }
    fn normal_exchange(binary:&str,owner:&mut CliOwner,project:&str,run:&str,pair:PipePair) {
        let mut adapter=Adapter::start(binary,&owner.discovery,pair,None);
        adapter.send(&json!({"jsonrpc":"2.0","id":50,"method":"tools/list"}));assert_eq!(adapter.reply()["error"]["code"],-32600);
        adapter.initialize();
        adapter.send(&json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}));
        let tools=adapter.reply();assert_eq!(tools["result"]["tools"].as_array().unwrap().len(),1);
        let instance=owner.discovery["instance_id"].as_str().unwrap().to_owned();
        let denied=product_call(&mut adapter,3,request(Some(&instance),None,"project.list",json!({})),"normal_exchange/ Live",ProductReply::LiveDenied(winsmux_workspace::contract::ErrorCode::PermissionDenied));
        assert_eq!(denied["result"]["structuredContent"]["error"]["code"],"permission_denied");
        let pending=product_call(&mut adapter,4,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata","read_output","control"]})),"normal_exchange/ Live",ProductReply::LiveSuccess);
        let connection=pending["result"]["structuredContent"]["result"]["data"]["connection_id"].as_str().unwrap().to_owned();
        let connections=owner.success("connection.list",json!({}));
        assert!(connections["result"]["data"]["connections"].as_array().unwrap().iter().any(|r|r["connection_id"]==connection));
        owner.success("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata","read_output","control"]}));
        let listed=product_call(&mut adapter,5,request(Some(&instance),None,"project.list",json!({})),"normal_exchange/ Live",ProductReply::LiveSuccess);
        assert_eq!(listed["result"]["structuredContent"]["accepted"],true);
        let observed=product_call(&mut adapter,6,request(Some(&instance),None,"run.get",json!({"run_id":run})),"normal_exchange/ Live",ProductReply::LiveSuccess);
        assert_eq!(observed["result"]["structuredContent"]["result"]["data"]["run"]["run_id"],run);
        assert_eq!(observed["result"]["structuredContent"]["result"]["data"]["run"]["process"],"running");
        let output=product_call(&mut adapter,7,request(Some(&instance),None,"output.read",json!({"run_id":run,"cursor":null,"max_bytes":4096})),"normal_exchange/ Live",ProductReply::LiveSuccess);
        assert_eq!(output["result"]["structuredContent"]["accepted"],true);
        for (id,operation,params) in [(8,"connection.list",json!({})),(9,"host.stop",json!({})),
            (10,"connection.decide",json!({"connection_id":connection,"decision":"deny","project_ids":[],"scopes":[]}))] {
            let denied=product_call(&mut adapter,id,request(Some(&instance),None,operation,params),"normal_exchange/ Live",ProductReply::LiveDenied(winsmux_workspace::contract::ErrorCode::PermissionDenied));
            assert_eq!(denied["result"]["structuredContent"]["error"]["code"],"permission_denied");
        }
        adapter.send(&json!({"jsonrpc":"2.0","id":11,"method":"ping"}));assert_eq!(adapter.reply()["result"],json!({}));
        // Physical peer receipt precedes reuse; the runtime still owns marker ordering.
        adapter.send(&json!({"jsonrpc":"2.0","id":11,"method":"ping"}));assert_eq!(adapter.reply()["id"],11);
        adapter.finish(0,None);
    }
    fn scope_and_connection_classes(binary:&str,owner:&mut CliOwner,project:&str,pane:&str,run:&str,fixture:&Path) {
        use winsmux_workspace::contract::ErrorCode;
        let other_path=fixture.join("other-project");std::fs::create_dir(&other_path).unwrap();owner.owned_directories.push(other_path.clone());
        let opened=owner.success("project.open",json!({"path":other_path.to_string_lossy()}));let other=opened["result"]["data"]["project_id"].as_str().unwrap().to_owned();
        execution(json!({"stage":"owned negative sibling project registered","project_id":other,"path":other_path}));
        let protected=owner.snapshot(project,run);let instance=owner.discovery["instance_id"].as_str().unwrap().to_owned();
        for (case,phase,deny) in [(0,"Granted",false),(1,"Pending",false),(2,"Unpaired",false),(3,"Pending",true)] {
            let before=owner.success("connection.list",json!({}));let before_ids:Vec<_>=before["result"]["data"]["connections"].as_array().unwrap().iter().map(|r|r["connection_id"].clone()).collect();
            let mut adapter=Adapter::start(binary,&owner.discovery,named(case%2==0,case%2!=0,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
            product_call(&mut adapter,10,request(None,None,"capabilities.get",json!({})),"Unpaired/Live",ProductReply::LiveSuccess);
            let listed=owner.success("connection.list",json!({}));let new:Vec<_>=listed["result"]["data"]["connections"].as_array().unwrap().iter().filter(|r|!before_ids.contains(&r["connection_id"])).collect();assert_eq!(new.len(),1);
            let connection=new[0]["connection_id"].as_str().unwrap().to_owned();assert_eq!(new[0]["state"],"unpaired");
            let old_operation=request(Some(&instance),None,"run.get",json!({"run_id":run}));
            product_call(&mut adapter,11,old_operation.clone(),"Unpaired/Live",ProductReply::LiveDenied(ErrorCode::PermissionDenied));
            for (index,decision) in ["allow","deny"].into_iter().enumerate() {
                let refused=owner.transact("connection.decide",json!({"connection_id":connection,"decision":decision,"project_ids":[],"scopes":[]}));assert_eq!(refused["accepted"],false);assert_eq!(refused["error"]["code"],"invalid_request");
                product_call(&mut adapter,18+index as u64,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Unpaired/Live after refused owner decide",ProductReply::LiveDenied(ErrorCode::PermissionDenied));assert_eq!(owner.snapshot(project,run),protected);
                let listed=owner.success("connection.list",json!({}));let record=listed["result"]["data"]["connections"].as_array().unwrap().iter().find(|r|r["connection_id"]==connection).unwrap();assert_eq!(record["state"],"unpaired");assert_eq!(record["granted_project_ids"],json!([]));assert_eq!(record["granted_scopes"],json!([]));
            }
            if phase!="Unpaired" {
                let pending_request=request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]}));
                let pending=product_call(&mut adapter,12,pending_request,"Unpaired/Live",ProductReply::LiveSuccess);assert_eq!(pending["result"]["structuredContent"]["result"]["data"]["connection_id"],connection);
                let same=product_call(&mut adapter,13,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]})),"Pending/Live",ProductReply::LiveSuccess);assert_eq!(same["result"]["structuredContent"]["result"]["data"]["connection_id"],connection);
                product_call(&mut adapter,14,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata","control"]})),"Pending/Live",ProductReply::LiveDenied(ErrorCode::InvalidRequest));
                for (invalid_index,params) in [json!({"connection_id":connection,"decision":"allow","project_ids":[other],"scopes":["metadata"]}),json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["control"]})].into_iter().enumerate() {
                    let refused=owner.transact("connection.decide",params);assert_eq!(refused["accepted"],false);assert_eq!(refused["error"]["code"],"invalid_request");
                    product_call(&mut adapter,15+invalid_index as u64,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Pending/Live after refused owner decide",ProductReply::LiveDenied(ErrorCode::PermissionDenied));assert_eq!(owner.snapshot(project,run),protected);
                    let listed=owner.success("connection.list",json!({}));let record=listed["result"]["data"]["connections"].as_array().unwrap().iter().find(|r|r["connection_id"]==connection).unwrap();assert_eq!(record["state"],"pending");assert_eq!(record["granted_project_ids"],json!([]));assert_eq!(record["granted_scopes"],json!([]));
                }
            }
            if phase=="Granted" {
                owner.success("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata"]}));
                product_call(&mut adapter,20,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Granted/Live",ProductReply::LiveSuccess);
                for (id,operation,params,target,expected) in [(21,"output.read",json!({"run_id":run,"cursor":null,"max_bytes":4096}),"missing read_output scope",ErrorCode::PermissionDenied),
                    (22,"input.write",json!({"pane_id":pane,"run_id":run,"text":"Write-Output TASK875_REFUSED_INPUT\r"}),"missing control scope",ErrorCode::PermissionDenied),
                    (23,"pane.list",json!({"project_id":other}),"existing project outside grant",ErrorCode::TargetNotFound),
                    (24,"connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project,other],"scopes":["metadata","control"]}),"owner-only self scope expansion",ErrorCode::PermissionDenied),
                    (25,"pane.list",json!({"project_id":"87500000-0000-4000-8000-000000000000"}),"absent project",ErrorCode::TargetNotFound)] {
                    product_call(&mut adapter,id,request(Some(&instance),None,operation,params),target,ProductReply::LiveDenied(expected));assert_eq!(owner.snapshot(project,run),protected);
                }
                for decision in ["allow","deny"] {
                    let refused=owner.transact("connection.decide",json!({"connection_id":connection,"decision":decision,"project_ids":[],"scopes":[]}));assert_eq!(refused["accepted"],false);assert_eq!(refused["error"]["code"],"invalid_request");
                    product_call(&mut adapter,26,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Granted/Live after refused owner decide",ProductReply::LiveSuccess);assert_eq!(owner.snapshot(project,run),protected);
                    let listed=owner.success("connection.list",json!({}));let record=listed["result"]["data"]["connections"].as_array().unwrap().iter().find(|r|r["connection_id"]==connection).unwrap();assert_eq!(record["state"],"granted");assert_eq!(record["granted_project_ids"],json!([project]));assert_eq!(record["granted_scopes"],json!(["metadata"]));
                }
                product_call(&mut adapter,26,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Granted/Live after refused owner decide",ProductReply::LiveSuccess);
                product_call(&mut adapter,27,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]})),"Granted/Live",ProductReply::LiveDenied(ErrorCode::InvalidRequest));
            }
            let terminal_reply=if deny {owner.success("connection.decide",json!({"connection_id":connection,"decision":"deny","project_ids":[],"scopes":[]}))}
            else {owner.success("connection.revoke",json!({"connection_id":connection}))};
            assert!(check_owner_terminal_reply(&connection,deny,&terminal_reply));
            let terminal_phase=format!("{phase} -> {} / Cancelled after owner reply",if deny{"Deny"}else{"Revoke"});
            for (id,request) in [(30,request(Some(&instance),None,"run.get",json!({"run_id":run}))),(31,request(Some(&instance),None,"input.write",json!({"pane_id":pane,"run_id":run,"text":"Write-Output TASK875_CANCELLED_INPUT\r"}))),(32,old_operation),(33,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]})))] {
                product_call(&mut adapter,id,request,&terminal_phase,ProductReply::CancelledWire);assert_eq!(owner.snapshot(project,run),protected);
            }
            adapter.finish(1,Some("transport_failed"));assert_eq!(owner.snapshot(project,run),protected);
            for (operation,params) in [("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[],"scopes":[]})),("connection.decide",json!({"connection_id":connection,"decision":"deny","project_ids":[],"scopes":[]})),("connection.revoke",json!({"connection_id":connection}))] {
                let repeated=owner.transact(operation,params);assert_eq!(repeated["accepted"],false);assert_eq!(repeated["error"]["code"],"target_not_found");assert_eq!(owner.snapshot(project,run),protected);
            }
            let records=owner.success("connection.list",json!({}));
            execution(json!({"stage":"cancelled connection list observation only","connection_id":connection,"response":records,"public_retire_barrier":false,"retire_point_observed":false,"list_used_as_pass_criterion":false}));
            let mut fresh=Adapter::start(binary,&owner.discovery,named(false,true,PIPE_TYPE_BYTE|PIPE_WAIT),None);fresh.initialize();
            product_call(&mut fresh,40,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Fresh/Live former grant",ProductReply::LiveDenied(ErrorCode::PermissionDenied));
            let fresh_request=product_call(&mut fresh,41,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]})),"Fresh/Live",ProductReply::LiveSuccess);let fresh_id=fresh_request["result"]["structuredContent"]["result"]["data"]["connection_id"].as_str().unwrap();assert_ne!(fresh_id,connection);
            product_call(&mut fresh,42,request(Some(&instance),None,"run.get",json!({"run_id":run})),"Fresh Pending/Live grant not inherited",ProductReply::LiveDenied(ErrorCode::PermissionDenied));fresh.finish(0,None);assert_eq!(owner.snapshot(project,run),protected);
            execution(json!({"stage":"actual ProductHost authority wire terminal class completed","source_state":phase,"termination":if deny{"Deny"}else{"Revoke"},"post_owner_reply_fixed_error_calls":4,"actual_revoked_adapter_exit":1,"fresh_actual_exit":0,"fresh_grant_inheritance":false,"canary_snapshot_preserved":true}));
        }
        owner.success("project.forget",json!({"project_id":other}));
        println!("{}",json!({"class":"actual ProductHost authority and wire lifetime family","terminal_classes":4,"post_owner_reply_fixed_calls":16,"live_exact_scope_and_named_target_codes":true,"invalid_operator_decisions_preserve_live_state":true,"fresh_connections_without_grant":4,"self_scope_expansion":false,"actual_canary_alive":true}));
    }

    fn actual_output_entry(binary:&str,owner:&mut CliOwner,project:&str,pane:&str,run:&str) {
        use winsmux_workspace::memory_testing::{decode_cursor,encode_cursor};
        let instance=owner.discovery["instance_id"].as_str().unwrap().to_owned();
        let protected=owner.snapshot(project,run);
        let mut adapter=Adapter::start(binary,&owner.discovery,named(true,false,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
        let requested=product_call(&mut adapter,200,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata","read_output","control"]})),"actual_output_entry/ Live",ProductReply::LiveSuccess);
        let connection=requested["result"]["structuredContent"]["result"]["data"]["connection_id"].as_str().unwrap().to_owned();
        owner.success("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata","read_output","control"]}));
        let mut next_id=201u64;
        let mut exchange=|operation:&str,params:Value|{
            let value=product_call(&mut adapter,next_id,request(Some(&instance),None,operation,params),"actual_output_entry/ Live",ProductReply::LiveSuccess);next_id+=1;
            let structured=value["result"]["structuredContent"].clone();assert_eq!(structured["accepted"],true,"actual granted MCP {operation}");structured
        };
        let initial=exchange("output.read",json!({"run_id":run,"cursor":null,"max_bytes":4_000_000}));
        let mut cursor=initial["result"]["data"]["next_cursor"].clone();let old_cursor=cursor.clone();
        exchange("input.write",json!({"pane_id":pane,"run_id":run,"text":"[Console]::Write(('TASK875_'+'BEGIN_')+'日本語😀'); [Console]::WriteLine(('TASK875_'+'END_'))\r"}));
        let mut carry=String::new();let mut japanese_cursor=None;
        loop {
            let observed=exchange("output.read",json!({"run_id":run,"cursor":cursor,"max_bytes":4096}));let data=&observed["result"]["data"];
            assert_eq!(data["gap"],false,"small actual output does not lose bytes");
            let text=data["text"].as_str().unwrap();let next=decode_cursor(data["next_cursor"].as_str().unwrap()).unwrap();
            let origin=next.offset.checked_sub(text.len() as u64).unwrap();let carry_bytes=carry.len();carry.push_str(text);
            if let Some(index)=carry.find("日本語😀") {
                let offset=origin.checked_sub(carry_bytes as u64).unwrap()+index as u64;
                japanese_cursor=Some(encode_cursor(&next.instance_id,&next.run_id,offset).as_str().to_owned());
            }
            cursor=data["next_cursor"].clone();if carry.contains("TASK875_END_")&&japanese_cursor.is_some(){break;}
            let tail:String=carry.chars().rev().take("TASK875_BEGIN_日本語😀TASK875_END_".chars().count()).collect();carry=tail.chars().rev().collect();thread::yield_now();
        }
        let japanese_cursor=japanese_cursor.unwrap();
        for (budget,expected) in [(1,""),(3,"日"),(13,"日本語😀")] {
            let observed=exchange("output.read",json!({"run_id":run,"cursor":japanese_cursor,"max_bytes":budget}));let data=&observed["result"]["data"];
            assert_eq!(data["text"],expected);assert_eq!(data["gap"],false);assert_eq!(data["truncated"],true);
            let direct=owner.success("output.read",json!({"run_id":run,"cursor":japanese_cursor,"max_bytes":budget}));
            assert_eq!(direct["result"]["data"],*data,"owner and MCP preserve identical opaque cursor/UTF8 boundary/truncation");
        }
        for bad in ["not-a-cursor".to_owned(),format!("v1:10000000-0000-4000-8000-000000000000/{run}/0"),format!("v1:{instance}/50000000-0000-4000-8000-000000000000/0")] {
            let invalid=exchange("output.read",json!({"run_id":run,"cursor":bad,"max_bytes":4096}));let data=&invalid["result"]["data"];
            assert_eq!(data["text"],"");assert_eq!(data["gap"],true);assert_eq!(data["truncated"],false);let parsed=decode_cursor(data["next_cursor"].as_str().unwrap()).unwrap();assert_eq!(parsed.instance_id.as_str(),instance);assert_eq!(parsed.run_id.as_str(),run);
        }
        let count=winsmux_workspace::contract::MAX_MESSAGE_BYTES+65536;
        exchange("input.write",json!({"pane_id":pane,"run_id":run,"text":format!("[Console]::Write(('x' * {count})); [Console]::WriteLine(('TASK875_'+'LARGE_DONE'))\r")}));
        let mut tail=String::new();
        loop {
            let observed=exchange("output.read",json!({"run_id":run,"cursor":cursor,"max_bytes":65536}));let data=&observed["result"]["data"];
            tail.push_str(data["text"].as_str().unwrap());cursor=data["next_cursor"].clone();if tail.contains("TASK875_LARGE_DONE"){break;}
            let retained:String=tail.chars().rev().take("TASK875_LARGE_DONE".len()).collect();tail=retained.chars().rev().collect();thread::yield_now();
        }
        let expired=exchange("output.read",json!({"run_id":run,"cursor":old_cursor,"max_bytes":4_000_000}));let data=&expired["result"]["data"];
        assert_eq!(data["gap"],true,"actual retained ring expired the saved pre-output cursor");assert_eq!(data["truncated"],true,"actual finite response envelope reports truncation");assert!(data["text"].as_str().unwrap().len()>65536);
        assert!(serde_json::to_vec(&expired).unwrap().len()<=winsmux_workspace::contract::MAX_MESSAGE_BYTES);
        println!("{}",json!({"class":"normal MCP actual ProductHost granted control/output","actual_output_bytes":data["text"].as_str().unwrap().len(),"large_response_bytes":serde_json::to_vec(&expired).unwrap().len(),"opaque_cursor_owner_equivalence":true,"actual_utf8_boundary_budgets":[1,3,13],"ring_expired_gap":data["gap"],"truncated":data["truncated"],"malformed_foreign_cursor_gap":true,"structured_text_identical":true,"self_approval":false,"actual_canary_running":true}));
        drop(exchange);adapter.finish(0,None);assert_eq!(owner.snapshot(project,run),protected);
    }
    fn granted_actual_call(adapter:&mut Adapter,owner:&mut CliOwner,id:u64,operation:&str,params:Value)->Value {
        let value=product_call(adapter,id,request(owner.discovery["instance_id"].as_str(),Some(owner.revision),operation,params),"granted_actual_call/ Live",ProductReply::LiveSuccess);
        let response=value["result"]["structuredContent"].clone();assert_eq!(response["accepted"],true,"actual granted control {operation}: {response}");owner.revision=response["topology_revision"].as_u64().unwrap();response
    }
    fn actual_control_entry(binary:&str,owner:&mut CliOwner,project:&str,canary_pane:&str,canary_run:&str,owned_processes:&mut Vec<Handle>) {
        let mut protected=owner.snapshot(project,canary_run);let baseline=SelectionBaseline::capture(&protected,project,canary_pane).expect("owned fixture selection baseline modeled before mutation");protected.as_object_mut().unwrap().remove("revision");
        let before=owned_descendants(unsafe {GetProcessId(owner.backend.0)});let before_ids:Vec<_>=before.iter().map(|h|unsafe {GetProcessId(h.0)}).collect();
        let mut adapter=Adapter::start(binary,&owner.discovery,named(false,true,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
        let pending=product_call(&mut adapter,400,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata","read_output","control"]})),"actual_control_entry/ Live",ProductReply::LiveSuccess);
        let connection=pending["result"]["structuredContent"]["result"]["data"]["connection_id"].as_str().unwrap().to_owned();
        owner.success("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata","read_output","control"]}));
        let created=granted_actual_call(&mut adapter,owner,401,"pane.create",json!({"project_id":project,"shell_profile_id":"pwsh"}));
        let pane=created["result"]["data"]["pane_id"].as_str().unwrap().to_owned();let run=created["result"]["data"]["run_id"].as_str().unwrap().to_owned();owner.owned_panes.push(pane.clone());
        execution(json!({"stage":"actual MCP owned control pane run created","project_id":project,"pane_id":pane,"run_id":run,"connection_id":connection,"operator_exact_scope_decision":true}));
        let mut id=402;
        loop {let status=granted_actual_call(&mut adapter,owner,id,"run.get",json!({"run_id":run}));id+=1;match status["result"]["data"]["run"]["process"].as_str().unwrap(){"starting"=>thread::yield_now(),"running"=>break,other=>panic!("actual MCP control run did not start: {other}")}}
        let extras=owned_descendants(unsafe {GetProcessId(owner.backend.0)}).into_iter().filter(|h|!before_ids.contains(&unsafe {GetProcessId(h.0)})).collect::<Vec<_>>();
        let mut shell_ids=Vec::new();let mut consoles=0;let mut unknown=Vec::new();
        for handle in extras {
            let image=process_image(&handle);let name=image.file_name().unwrap().to_string_lossy();let pid=unsafe {GetProcessId(handle.0)};
            let role=if name.eq_ignore_ascii_case("pwsh.exe"){shell_ids.push(pid);"control shell candidate"}else if name.eq_ignore_ascii_case("conhost.exe"){consoles+=1;"host-owned control ConPTY"}else{unknown.push(name.to_string());"unclassified owned child"};
            execution(json!({"stage":"actual MCP owned control role registered","process":process_identity(handle.0),"pane_id":pane,"run_id":run,"role":role,"termination_order":"run.interrupt observes shell exit; host-owned ConPTY HANDLE wait after public host.stop/owner/backend actual exit"}));owned_processes.push(handle);
        }
        assert!(unknown.is_empty(),"unmodeled owned control role: {unknown:?}");assert_eq!(shell_ids.len(),1);assert_eq!(consoles,1);
        for expected in SelectionBaseline::ALL {
            let (operation,params)=expected.operation(project,canary_pane);
            let selected=granted_actual_call(&mut adapter,owner,id,operation,params);id+=1;assert_eq!(selected["result"]["data"],expected.selection(project,canary_pane));
            let snapshot=owner.snapshot(project,canary_run);let captured=SelectionBaseline::capture(&snapshot,project,canary_pane).unwrap();assert_eq!(captured,expected);
            let control_selected=granted_actual_call(&mut adapter,owner,id,"pane.select",json!({"pane_id":pane}));id+=1;assert_eq!(control_selected["result"]["data"],json!({"selected_project_id":project,"selected_pane_id":pane}));
            restore_selection(owner,captured,project,canary_pane);let restored=owner.snapshot(project,canary_run);assert_eq!(SelectionBaseline::capture(&restored,project,canary_pane),Some(captured));
            execution(json!({"stage":"actual MCP selection class restored from control selection","baseline":format!("{captured:?}"),"MCP_selected_reply":selected,"canary_process_unchanged":true}));
        }
        restore_selection(owner,baseline,project,canary_pane);
        let selected=granted_actual_call(&mut adapter,owner,id,"pane.select",json!({"pane_id":pane}));id+=1;assert_eq!(selected["result"]["data"],json!({"selected_project_id":project,"selected_pane_id":pane}));
        let resized=granted_actual_call(&mut adapter,owner,id,"pane.resize",json!({"pane_id":pane,"run_id":run,"cols":100,"rows":28}));id+=1;
        assert_eq!(resized["result"]["data"]["cols"],100);assert_eq!(resized["result"]["data"]["rows"],28);
        let command="[Console]::WriteLine(('TASK875_'+'CONTROL_PID_') + $PID); [Console]::WriteLine(('TASK875_'+'SIZE_') + [Console]::WindowWidth + 'x' + [Console]::WindowHeight)\r";
        let written=granted_actual_call(&mut adapter,owner,id,"input.write",json!({"pane_id":pane,"run_id":run,"text":command}));id+=1;assert_eq!(written["result"]["data"]["written_bytes"],command.len());
        let mut cursor=Value::Null;let mut carry=String::new();let mut observed_pid=None;let mut observed_size=false;
        loop {
            let output=granted_actual_call(&mut adapter,owner,id,"output.read",json!({"run_id":run,"cursor":cursor,"max_bytes":4096}));id+=1;let data=&output["result"]["data"];assert_eq!(data["gap"],false);carry.push_str(data["text"].as_str().unwrap());cursor=data["next_cursor"].clone();
            for part in carry.split("TASK875_CONTROL_PID_").skip(1) {let digits:String=part.chars().take_while(|c|c.is_ascii_digit()).collect();let suffix=&part[digits.len()..];if !digits.is_empty()&&(suffix.starts_with('\r')||suffix.starts_with('\n')){observed_pid=Some(digits.parse::<u32>().unwrap());}}
            observed_size|=carry.contains("TASK875_SIZE_100x28");if observed_pid.is_some()&&observed_size{break;}
            let tail:String=carry.chars().rev().take("TASK875_CONTROL_PID_4294967295TASK875_SIZE_100x28".len()).collect();carry=tail.chars().rev().collect();thread::yield_now();
        }
        assert_eq!(observed_pid,Some(shell_ids[0]),"actual MCP run ID maps to the exact owned shell process by console output/parent/image/generation");
        granted_actual_call(&mut adapter,owner,id,"run.interrupt",json!({"run_id":run}));id+=1;
        loop {let stopped=granted_actual_call(&mut adapter,owner,id,"run.get",json!({"run_id":run}));id+=1;if stopped["result"]["data"]["run"]["process"]=="exited"{break;}thread::yield_now();}
        let shell=owned_processes.iter().find(|h|unsafe {GetProcessId(h.0)}==shell_ids[0]).unwrap();assert_eq!(unsafe {WaitForSingleObject(shell.0,INFINITE)},WAIT_OBJECT_0);
        execution(json!({"stage":"actual MCP owned control shell actual exit","process":process_identity(shell.0),"run_id":run,"public_run_interrupt":true}));
        granted_actual_call(&mut adapter,owner,id,"pane.close",json!({"pane_id":pane}));adapter.finish(0,None);
        let closed=owner.snapshot(project,canary_run);assert_eq!(SelectionBaseline::capture(&closed,project,canary_pane),Some(SelectionBaseline::ProjectOnly));assert!(!closed["panes"]["panes"].as_array().unwrap().iter().any(|record|record["pane_id"]==pane));
        execution(json!({"stage":"selected owned control pane closed with project-only selection","closed_pane_id":pane,"selection":SelectionBaseline::ProjectOnly.selection(project,canary_pane),"canary_process_preserved":true}));
        restore_selection(owner,baseline,project,canary_pane);let mut after=owner.snapshot(project,canary_run);after.as_object_mut().unwrap().remove("revision");assert_eq!(after,protected);
        println!("{}",json!({"class":"normal MCP actual operator-granted pane run resize input output and cleanup","pane_id":pane,"run_id":run,"actual_shell_pid":observed_pid,"actual_console_cols":100,"actual_console_rows":28,"MCP_run_interrupt_actual_exit":true,"MCP_pane_close":true,"unrelated_canary_preserved":true,"monotonic_topology_revision_intentionally_advanced":true,"host_owned_control_console_wait_after_owner_exit":true,"self_approval":false}));
    }
    fn prepare_actual_owner_loss(binary:&str,owner:&mut CliOwner,project:&str,run:&str)->Adapter {
        let mut adapter=Adapter::start(binary,&owner.discovery,named(true,true,PIPE_TYPE_BYTE|PIPE_WAIT),None);adapter.initialize();
        let pending=product_call(&mut adapter,500,request(None,None,"connection.request",json!({"project_ids":[project],"scopes":["metadata"]})),"prepare_actual_owner_loss/ Live",ProductReply::LiveSuccess);
        let connection=pending["result"]["structuredContent"]["result"]["data"]["connection_id"].as_str().unwrap().to_owned();owner.success("connection.decide",json!({"connection_id":connection,"decision":"allow","project_ids":[project],"scopes":["metadata"]}));
        granted_actual_call(&mut adapter,owner,501,"run.get",json!({"run_id":run}));
        execution(json!({"stage":"actual ProductHost loss adapter retained before owned normal cleanup","process":process_identity(adapter.child.as_raw_handle()),"operator_metadata_granted":true,"actual_public_authenticated_request_succeeded":true}));adapter
    }
    fn observe_actual_owner_loss(mut adapter:Adapter,owner:&CliOwner) {
        assert_eq!(unsafe {WaitForSingleObject(owner.process.0,0)},WAIT_OBJECT_0);assert_eq!(unsafe {WaitForSingleObject(owner.backend.0,0)},WAIT_OBJECT_0);
        for id in [502,503] {let failed=product_call(&mut adapter,id,request(owner.discovery["instance_id"].as_str(),None,"project.list",json!({})),"observe_actual_owner_loss/ Cancelled",ProductReply::CancelledWire);assert_eq!(failed["error"]["code"],-32603);}
        adapter.finish(1,Some("transport_failed"));execution(json!({"stage":"actual ProductHost owner exit transport uncertainty class completed","owner":process_identity(owner.process.0),"backend":process_identity(owner.backend.0),"first_active_call_fixed_error":-32603,"future_unknown_fixed_error":-32603,"actual_adapter_exit":1,"EOF_does_not_erase_transport_diagnostic":true,"public_owner_stop_then_actual_exit":true,"no_owner_restart":true}));
    }

    pub fn fixture_mode() -> bool {
        let args:Vec<String>=std::env::args().skip(1).collect();
        if args.first().map(String::as_str)==Some("--fixture-console-rejection") {assert_eq!(args.len(),2);console_stdin_proxy(&args[1]);return true;}
        if args.first().map(String::as_str)!=Some("--fixture-runtime") {return false;}
        assert_eq!(args.len(),8);
        let discovery=winsmux_workspace_mcp::parse_discovery(args[1].as_bytes()).unwrap();
        let (gates,controller)=RuntimeGates::hold_nth(gate_from_name(&args[2]),if args[2]=="BeforeWriteCall"{2}else{1});
        let ready=Handle::new(unsafe {OpenEventW(EVENT_MODIFY_STATE,0,wide(&args[4]).as_ptr())});
        let release=Handle::new(unsafe {OpenEventW(SYNCHRONIZE|EVENT_MODIFY_STATE,0,wide(&args[5]).as_ptr())});
        let cancel=args[6]=="cancel";
        let receipts=args[7].parse::<u64>().unwrap();
        let release_on_return=release.duplicate(0,true);
        let control=thread::spawn(move || {if controller.wait_reached(){unsafe {SetEvent(ready.raw());}assert_eq!(unsafe {WaitForSingleObject(release.raw(),INFINITE)},WAIT_OBJECT_0);if cancel{controller.cancel();}else{assert!(controller.wait_receipts(receipts));controller.release();}}});
        let (result,observations)=winsmux_workspace_mcp::testing::run_stdio_fixture(discovery,gates);
        unsafe {SetEvent(release_on_return.0);}
        control.join().unwrap();
        let value=json!({"result":result.as_ref().err().map(|e|e.classification()),"observations":observations});
        let mut file=std::fs::OpenOptions::new().create_new(true).write(true).open(&args[3]).unwrap();
        file.write_all(&serde_json::to_vec(&value).unwrap()).unwrap();file.flush().unwrap();
        std::process::exit(if result.is_ok(){0}else{1});
    }
    fn cleanup_owner(owner:&mut CliOwner,project:Option<&str>,pane:Option<&str>,run:Option<&str>,recovery:&Handle,recovery_name:&str,serve_provider_wait:bool,persist_for_success:bool) {
        if unsafe {WaitForSingleObject(owner.process.0,0)}==WAIT_OBJECT_0 {owner.collect_terminated();return;}
        assert_ne!(owner.pseudoconsole,0,"live owner must retain its ConPTY until cleanup");
        if let Some(run)=run {
            let observed=owner.transact("run.get",json!({"run_id":run}));
            if observed["accepted"]==true && observed["result"]["data"]["run"]["process"]!="exited" {
                owner.success("run.interrupt",json!({"run_id":run}));
            } else if observed["accepted"]!=true {assert_eq!(observed["error"]["code"],"target_not_found");}
            loop {
                let observed=owner.transact("run.get",json!({"run_id":run}));
                if observed["accepted"]!=true {assert_eq!(observed["error"]["code"],"target_not_found");break;}
                if observed["result"]["data"]["run"]["process"]=="exited" {break;}
                thread::yield_now();
            }
        }
        let projects=owner.success("project.list",json!({}));
        let mut manifest=owner.owned_projects.clone();if let Some(id)=project {if !manifest.iter().any(|p|p==id){manifest.push(id.to_owned());}}
        for project in manifest {
            if !projects["result"]["data"]["projects"].as_array().unwrap().iter().any(|p|p["project_id"]==project){continue;}
            let panes=owner.success("pane.list",json!({"project_id":project}));
            for item in panes["result"]["data"]["panes"].as_array().unwrap() {
                let id=item["pane_id"].as_str().unwrap();
                assert!(owner.owned_panes.iter().any(|p|p==id)||pane==Some(id),"cleanup may close only a registered fixture pane");
                owner.success("pane.close",json!({"pane_id":id}));
            }
            owner.success("project.forget",json!({"project_id":project}));
        }
        let cleared=owner.success("project.list",json!({}));assert!(cleared["result"]["data"]["projects"].as_array().unwrap().is_empty());
        let store=std::path::PathBuf::from(std::env::var_os("TASK875_STORE_ROOT").expect("native store root"));
        if persist_for_success {
            execution(json!({"stage":"pre-stop layout save requested","successful_journey":true}));
            let saved=owner.success("layout.save",json!({}));
            assert_eq!(saved["result"]["data"]["generation"],0);
            assert!(saved["result"]["data"]["saved_topology_revision"].as_u64().is_some_and(|revision|revision>0));
            execution(json!({"stage":"pre-stop layout save accepted","generation":0,"topology_revision":saved["result"]["data"]["saved_topology_revision"]}));
        }
        let pre_stop_confirmed=std::fs::read(store.join("confirmed.json")).unwrap();
        logical_empty(&pre_stop_confirmed);
        owner.finish(recovery,recovery_name,serve_provider_wait);
        let post_stop_backup=std::fs::read(store.join("backup.json")).unwrap();
        assert_eq!(post_stop_backup,pre_stop_confirmed,"backup must contain exact pre-stop confirmed bytes");
        let post_stop_confirmed=std::fs::read(store.join("confirmed.json")).unwrap();
        logical_empty(&post_stop_confirmed);
        if persist_for_success {
            let previous:Value=serde_json::from_slice(&pre_stop_confirmed).unwrap();
            let confirmed:Value=serde_json::from_slice(&post_stop_confirmed).unwrap();
            let backup:Value=serde_json::from_slice(&post_stop_backup).unwrap();
            assert_eq!(previous["generation"],0);assert_eq!(confirmed["generation"],0);assert_eq!(backup["generation"],0);
            assert!(previous["topology_revision"].as_u64().is_some_and(|revision|revision>0));
            assert_eq!(confirmed["topology_revision"],previous["topology_revision"]);
            assert_eq!(backup["topology_revision"],previous["topology_revision"]);
        }
        println!("{}",json!({"class":"native store save","backup_matches_pre_stop_confirmed":true,"post_stop_confirmed_logical_empty":true,"positive_advanced_equal_revision":persist_for_success}));
    }
    fn recover_cleanup(owner:&mut CliOwner,pipe:&Handle,name:&str,project:Option<&str>,pane:Option<&str>,run:Option<&str>) {
        // The fixture keeps its ConPTY input/output ownership alive. Parent can send
        // only status or the same dedicated public cleanup, never arbitrary commands.
        loop {
            if owner.provider_observer.is_some(){serve_provider_recovery(owner,pipe);continue;}
            if unsafe {ConnectNamedPipe(pipe.0,null_mut())}==0 {assert_eq!(unsafe {GetLastError()},ERROR_PIPE_CONNECTED);}
            let mut command=[0u8;64];let mut count=0;
            if unsafe {ReadFile(pipe.0,command.as_mut_ptr(),64,&mut count,null_mut())}==0 {
                assert_eq!(unsafe {GetLastError()},ERROR_BROKEN_PIPE,"owned recovery pipe read failure");
                execution(json!({"stage":"owned recovery peer EOF","owner":process_identity(owner.process.0),"normal_cleanup_success":false}));
                unsafe {DisconnectNamedPipe(pipe.0);}
                if unsafe {WaitForSingleObject(owner.process.0,0)}==WAIT_OBJECT_0 {owner.collect_terminated();return;}
                // A disconnected operator cannot receive a reply. Preserve the
                // live owner and serve the same bounded cleanup route next.
                continue;
            }
            let clean=&command[..count as usize]==b"cleanup\n";
            let success=clean&&std::panic::catch_unwind(std::panic::AssertUnwindSafe(||cleanup_owner(owner,project,pane,run,pipe,name,false,false))).is_ok();
            let response=json!({"cleanup_complete":success,"owner":process_identity(owner.process.0),"project_id":project,"pane_id":pane,"run_id":run,"only_owned_public_cleanup":true});
            let mut bytes=serde_json::to_vec(&response).unwrap();bytes.push(b'\n');write_bytes(pipe,&bytes);assert_ne!(unsafe {FlushFileBuffers(pipe.raw())},0);
            unsafe {DisconnectNamedPipe(pipe.0);}
            if success{return;}
        }
    }
    fn recover_startup(owner:&mut StartingCliOwner,pipe:&Handle,name:&str) {
        // A failed startup cannot use CliOwner's public cleanup until Discovery and
        // the correlated output path exist. Keep this fixture alive for status and
        // cleanup; an owned-process exit wakes it without an operator poll.
        let waits:Vec<_>=owner.process.iter().chain(owner.backend.iter()).chain(owner.console.iter())
            .map(|process|process.duplicate(SYNCHRONIZE,false)).collect();
        let wake_name=name.to_owned();
        let wake=thread::spawn(move || {
            for process in &waits {assert_eq!(unsafe {WaitForSingleObject(process.0,INFINITE)},WAIT_OBJECT_0);}
            let path=wide(&wake_name);
            let client=loop {
                let raw=unsafe {CreateFileW(path.as_ptr(),GENERIC_READ|GENERIC_WRITE,0,null(),OPEN_EXISTING,0,null_mut())};
                if !raw.is_null() && raw!=INVALID_HANDLE_VALUE {break Handle::new(raw);}
                assert_ne!(unsafe {WaitNamedPipeW(path.as_ptr(),INFINITE)},0,"startup recovery pipe remains available");
            };
            write_bytes(&client,b"auto-cleanup\n");
            let mut response=[0u8;2048];let mut size=0;
            assert_ne!(unsafe {ReadFile(client.0,response.as_mut_ptr(),response.len() as u32,&mut size,null_mut())},0);
        });
        execution(json!({"stage":"partial owner recovery serving","recovery_pipe":name,"owner":owner.process.as_ref().map(|p|process_identity(p.0)),"discovery_available":owner.discovery.is_some(),"output_joined":owner.output_joined,"force_kill":false}));
        loop {
            if unsafe {ConnectNamedPipe(pipe.0,null_mut())}==0 {assert_eq!(unsafe {GetLastError()},ERROR_PIPE_CONNECTED);}
            let mut command=[0u8;64];let mut count=0;
            let received=unsafe {ReadFile(pipe.0,command.as_mut_ptr(),command.len() as u32,&mut count,null_mut())};
            let request=&command[..count as usize];
            let auto=received!=0&&request==b"auto-cleanup\n";
            let clean=received!=0&&(auto||request==b"cleanup\n");
            let success=clean&&owner.finish_if_exited();
            let response=json!({"cleanup_complete":success,"owner":owner.process.as_ref().map(|p|process_identity(p.0)),"conpty":owner.console.as_ref().map(|p|process_identity(p.0)),"output_joined":owner.output_joined,"discovery_available":owner.discovery.is_some(),"recovery_limited_to_owned_startup":true});
            let mut bytes=serde_json::to_vec(&response).unwrap();bytes.push(b'\n');
            if received!=0 {write_bytes(pipe,&bytes);let _=unsafe {FlushFileBuffers(pipe.0)};}
            unsafe {DisconnectNamedPipe(pipe.0);}
            if auto&&success {wake.join().expect("owned startup recovery wake thread");return;}
        }
    }
    pub fn run(binary:&str) {
        let cli=PathBuf::from(std::env::var_os("TASK875_CLI_BIN").expect("formal runner supplies actual winsmux.exe"));
        let only_p1=std::env::var("TASK875_NATIVE_CLASS").as_deref()==Ok("held-proof-eof");
        let execution_path=PathBuf::from(std::env::var_os("TASK875_EXECUTION_RECEIPT").expect("formal runner execution receipt"));
        std::fs::OpenOptions::new().create_new(true).write(true).open(&execution_path).unwrap();
        let isolated_scope=std::env::var("TASK875_NATIVE_CLASS").unwrap_or_default();
        if isolated_scope=="distribution-initialize" {
            let actual=PathBuf::from(std::env::var_os("TASK875_RELEASE_MCP_BIN").expect("exact distribution MCP binary"));
            let expected=std::env::var("TASK879_MCP_SHA256").expect("fixed distribution MCP SHA-256");
            assert!(actual.is_absolute());
            let sha:String=Sha256::digest(std::fs::read(&actual).unwrap()).iter().map(|b|format!("{b:02x}")).collect();
            assert_eq!(sha,expected);
            let server=ValidProofServer::start_mode(ProofPeerMode::AuthOnly);
            let (input,writer)=anonymous();
            let mut adapter=Adapter::start(actual.to_str().unwrap(),&server.discovery,PipePair{input,writer},None);
            adapter.send(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"distribution-version-proof","version":"1"}}}));
            let response=adapter.reply();
            assert_eq!(response["id"],1);
            assert_eq!(response["result"]["protocolVersion"],"2025-11-25");
            assert_eq!(response["result"]["serverInfo"],json!({"name":"winsmux-workspace-mcp","version":env!("CARGO_PKG_VERSION")}));
            adapter.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}));
            adapter.finish(0,None);let peer=server.finish();
            let after:String=Sha256::digest(std::fs::read(&actual).unwrap()).iter().map(|b|format!("{b:02x}")).collect();
            assert_eq!(sha,after);
            execution(json!({"stage":"distribution MCP initialization verified","sha256":sha,"server_info":response["result"]["serverInfo"],"peer":peer,"known_folder_used":false,"product_host":false,"whole_task_completed":false}));
            return;
        }
        request_shape_classes();
        malformed_request_classes();
        owner_terminal_reply_classes();
        selection_baseline_classes();
        product_reply_classes();
        if isolated_scope=="request-shape" {execution(json!({"stage":"isolated request shape proof terminated","fixture":process_identity(unsafe {GetCurrentProcess()}),"cases":6,"known_folder_used":false,"whole_task_completed":false}));return;}
        if matches!(isolated_scope.as_str(),"notification-admission"|"notification-admission-first") {
            let first=isolated_scope=="notification-admission-first";
            execution(json!({"stage":"isolated notification admission native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"product_host":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            cancellation_notification_family(first);
            execution(json!({"stage":"isolated notification admission native terminated","same_runtime_fixture_cases":if first{1}else{40},"cases":if first{1}else{40},"supported_input_classes":5,"call_phases":4,"original_malformations":2,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="special-input" {
            execution(json!({"stage":"isolated special input native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));special_input_classes(binary);
            execution(json!({"stage":"isolated special input native terminated","normal_admission_refusals":4,"same_runtime_refusals":4,"normal_anonymous_held_proof_eof":2,"cases":10,"owned_input_handle_query_reader_auth_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="release-entry" {
            execution(json!({"stage":"isolated release entry native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));release_entry_negative();
            execution(json!({"stage":"isolated release entry native terminated","normal_release_adapter_cases":5,"cases":5,"actual_pending_listeners_canceled_and_drained":5,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="output-lifetime" {
            execution(json!({"stage":"isolated output lifetime native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            for server_input in [true,false] {for asynchronous in [false,true] {output_lifetime_class(binary,server_input,asynchronous);}}
            execution(json!({"stage":"isolated output lifetime native terminated","normal_adapter_cases":12,"same_runtime_fixture_cases":4,"cases":16,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="publication" {
            execution(json!({"stage":"isolated publication native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            for server_input in [true,false] {for asynchronous in [false,true] {publication_class(binary,server_input,asynchronous);}}
            execution(json!({"stage":"isolated publication native terminated","same_runtime_fixture_cases":8,"cases":8,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="authentication-negative" {
            execution(json!({"stage":"isolated authentication native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            authentication_negative(binary);
            execution(json!({"stage":"isolated authentication native terminated","normal_adapter_cases":50,"existing_production_OS_probe":true,"cases":50,"owned_adapter_and_server_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if isolated_scope=="codec" {
            execution(json!({"stage":"isolated codec native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"product_host":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            for server_input in [true,false] {for asynchronous in [false,true] {codec_class(binary,server_input,asynchronous);}}
            execution(json!({"stage":"isolated codec native terminated","normal_adapter_cases":24,"same_runtime_fixture_cases":4,"cases":28,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        if matches!(isolated_scope.as_str(),"valid-proof-sent"|"valid-proof-sent-first") {
            execution(json!({"stage":"isolated valid proof native start","fixture":process_identity(unsafe {GetCurrentProcess()}),"known_folder_used":false,"product_host":false,"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
            if isolated_scope=="valid-proof-sent-first" {
                sent_held_reply(binary,named(true,false,PIPE_TYPE_BYTE|PIPE_WAIT),"named server=true async=false",false);
                execution(json!({"stage":"isolated valid proof native terminated","cases":1,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
            }
            for server_input in [true,false] {for asynchronous in [false,true] {for eof in [false,true] {
                sent_held_reply(binary,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),&format!("named server={server_input} async={asynchronous}"),eof);
            }}}
            for eof in [false,true] {let (input,writer)=anonymous();sent_held_reply(binary,PipePair{input,writer},"anonymous",eof);}
            execution(json!({"stage":"isolated valid proof native terminated","cases":10,"owned_adapter_and_peer_threads_drained":true,"known_folder_used":false,"whole_task_completed":false}));return;
        }
        let root=store_root();let identity=root_identity(&root);
        assert_eq!(root,PathBuf::from(std::env::var_os("TASK875_STORE_ROOT").unwrap()));
        let confirmed=std::fs::read(root.join("confirmed.json")).unwrap();let before=logical_empty(&confirmed);
        let backup=std::fs::read(root.join("backup.json")).ok();
        if let Some(bytes)=&backup {logical_empty(bytes);}
        let fixture=PathBuf::from(std::env::var_os("TASK875_NATIVE_PROJECT_PATH").expect("pre-notified owned project path"));
        assert!(fixture.starts_with(std::env::temp_dir()));std::fs::create_dir(&fixture).unwrap();
        let recovery_name=format!(r"\\.\pipe\{}",unique("owner-recovery"));
        let recovery=Handle::new(unsafe {CreateNamedPipeW(wide(&recovery_name).as_ptr(),PIPE_ACCESS_DUPLEX,PIPE_TYPE_BYTE|PIPE_WAIT,1,4096,4096,0,null())});
        execution(json!({"stage":"native start","scope":isolated_scope,"fixture":process_identity(unsafe {GetCurrentProcess()}),"root_identity":identity,"confirmed_bytes":confirmed.len(),"backup_bytes":backup.as_ref().map(Vec::len),"owned_project_path":fixture,"recovery_pipe":recovery_name,"recovery_commands":["status\\n","cleanup\\n"],"source_checkpoint":std::env::var("TASK875_CHECKPOINT_SHA256").unwrap()}));
        let mut owner=match std::panic::catch_unwind(std::panic::AssertUnwindSafe(||CliOwner::start(&cli,&recovery,&recovery_name))) {
            Ok(owner)=>owner,
            Err(original)=>{
                assert!(std::fs::read_dir(&fixture).unwrap().next().is_none(),"startup failure may remove only an empty fixture");
                std::fs::remove_dir(&fixture).unwrap();
                assert_eq!(std::fs::read(root.join("confirmed.json")).unwrap(),confirmed);
                assert_eq!(std::fs::read(root.join("backup.json")).ok(),backup);
                assert_eq!(root_identity(&root),identity);
                execution(json!({"stage":"failed startup fixture removed after owned resources drained","default_bytes_preserved":true,"root_identity_preserved":true,"force_kill":false}));
                std::panic::resume_unwind(original);
            }
        };
        let mut owned_project=None;let mut owned_pane=None;let mut owned_run=None;let mut owned_processes=Vec::new();let mut owner_loss_adapter=None;
        let outcome=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let initial=owner.success("project.list",json!({}));assert!(initial["result"]["data"]["projects"].as_array().unwrap().is_empty());
        if isolated_scope=="preopen-failure" {
            execution(json!({"stage":"pre-open failure injected","original_failure":"TASK875_PREOPEN_INJECTED","topology_mutated":false}));
            panic!("TASK875_PREOPEN_INJECTED");
        }
        let opened=owner.success("project.open",json!({"path":fixture.to_string_lossy()}));
        let project=opened["result"]["data"]["project_id"].as_str().unwrap().to_owned();
        owned_project=Some(project.clone());execution(json!({"stage":"owned project opened","project_id":project,"owner":process_identity(owner.process.0)}));
        let pane=owner.success("pane.create",json!({"project_id":project,"shell_profile_id":"pwsh"}));
        let pane_id=pane["result"]["data"]["pane_id"].as_str().unwrap().to_owned();
        let run=pane["result"]["data"]["run_id"].as_str().unwrap().to_owned();
        owned_pane=Some(pane_id.clone());owned_run=Some(run.clone());
        execution(json!({"stage":"owned pane run created","project_id":project,"pane_id":pane_id,"run_id":run,"owner":process_identity(owner.process.0)}));
        loop {
            let observed=owner.success("run.get",json!({"run_id":run}));
            match observed["result"]["data"]["run"]["process"].as_str().unwrap() {
                "starting"=>thread::yield_now(),"running"=>break,other=>panic!("owned canary failed to start: {other}"),
            }
        }
        owner.register_canary(&pane_id,&run);
        let protected=owner.snapshot(&project,&run);
        owned_processes=owned_descendants(unsafe {GetProcessId(owner.process.0)});assert!(!owned_processes.is_empty(),"actual owned backend/run process tree");
        execution(json!({"stage":"canary running","owned_owner_tree":owned_processes.iter().map(|h|process_identity(h.0)).collect::<Vec<_>>(),"canary_observation":protected["process"],"canary_run_id":run,"protected":protected,"tree_role_note":"contains backend, run and their ConPTY/provider descendants; PIDs alone do not identify a provider worker or canary"}));
        println!("{}",json!({"class":"actual CLI/ConPTY native start","root_identity":identity,"confirmed_bytes":confirmed.len(),"backup_bytes":backup.as_ref().map(Vec::len),"default_logical_empty":true,"owned_project":true,"canary_running":true}));
        if isolated_scope=="product-authorization" {
            scope_and_connection_classes(binary,&mut owner,&project,&pane_id,&run,&fixture);
            assert_eq!(std::fs::read(root.join("confirmed.json")).unwrap(),confirmed);assert_eq!(std::fs::read(root.join("backup.json")).ok(),backup);assert_eq!(root_identity(&root),identity);assert_eq!(unsafe {WaitForSingleObject(owner.canary.as_ref().unwrap().0,0)},WAIT_TIMEOUT);return;
        }
        if isolated_scope=="product-control" {
            actual_control_entry(binary,&mut owner,&project,&pane_id,&run,&mut owned_processes);
            owner_loss_adapter=Some(prepare_actual_owner_loss(binary,&mut owner,&project,&run));
            assert_eq!(std::fs::read(root.join("confirmed.json")).unwrap(),confirmed);assert_eq!(std::fs::read(root.join("backup.json")).ok(),backup);assert_eq!(root_identity(&root),identity);return;
        }
        for server_input in [true,false] {for asynchronous in [false,true] {
            for initialize_line in [false,true] {held_proof(binary,initialize_line,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);}
            if only_p1{continue;}
            codec_class(binary,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            publication_class(binary,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            for eof in [false,true] {sent_held_reply(binary,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT),&format!("named server={server_input} async={asynchronous}"),eof);assert_eq!(owner.snapshot(&project,&run),protected);}
            normal_exchange(binary,&mut owner,&project,&run,named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT));
            assert_eq!(owner.snapshot(&project,&run),protected);
            output_lifetime_class(binary,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            lifecycle_gates(&mut owner,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            cancellation_gates(&mut owner,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            initialization_marker_gates(&mut owner,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
        }}
        if !only_p1 {
        authentication_negative(binary);assert_eq!(owner.snapshot(&project,&run),protected);
        for eof in [false,true] {let (input,writer)=anonymous();sent_held_reply(binary,PipePair{input,writer},"anonymous",eof);assert_eq!(owner.snapshot(&project,&run),protected);}
        let (input,writer)=anonymous();normal_exchange(binary,&mut owner,&project,&run,PipePair{input,writer});
        for server_input in [true,false] {for asynchronous in [false,true] {
            for access in [SYNCHRONIZE|FILE_WRITE_DATA|FILE_APPEND_DATA|FILE_READ_ATTRIBUTES, SYNCHRONIZE|FILE_READ_ATTRIBUTES] {
                rejected_rights(binary,access,server_input,asynchronous);assert_eq!(owner.snapshot(&project,&run),protected);
            }
            let pair=named(server_input,asynchronous,PIPE_TYPE_BYTE|PIPE_WAIT);
            let read=pair.input.duplicate(SYNCHRONIZE|FILE_READ_DATA|FILE_READ_ATTRIBUTES,false);
            normal_exchange(binary,&mut owner,&project,&run,PipePair{input:read,writer:pair.writer});assert_eq!(owner.snapshot(&project,&run),protected);
        }}
        unsupported_inputs(binary);assert_eq!(owner.snapshot(&project,&run),protected);
        special_input_classes(binary);assert_eq!(owner.snapshot(&project,&run),protected);
        release_entry_negative();assert_eq!(owner.snapshot(&project,&run),protected);
        scope_and_connection_classes(binary,&mut owner,&project,&pane_id,&run,&fixture);
        actual_output_entry(binary,&mut owner,&project,&pane_id,&run);
        actual_control_entry(binary,&mut owner,&project,&pane_id,&run,&mut owned_processes);
        owner_loss_adapter=Some(prepare_actual_owner_loss(binary,&mut owner,&project,&run));
        }
        assert_eq!(std::fs::read(root.join("confirmed.json")).unwrap(),confirmed);
        assert_eq!(std::fs::read(root.join("backup.json")).ok(),backup);assert_eq!(root_identity(&root),identity);
        assert_eq!(unsafe {WaitForSingleObject(owner.canary.as_ref().unwrap().0,0)},WAIT_TIMEOUT);
        }));
        if outcome.is_err(){execution(json!({"stage":"native family failed","original_failure_preserved":true,"owner":process_identity(owner.process.0),"project_id":owned_project,"pane_id":owned_pane,"run_id":owned_run,"recovery_pipe":recovery_name}));}
        let cleanup=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||cleanup_owner(&mut owner,owned_project.as_deref(),owned_pane.as_deref(),owned_run.as_deref(),&recovery,&recovery_name,true,outcome.is_ok())));
        let cleanup_error=cleanup.err();
        if cleanup_error.is_some(){execution(json!({"stage":"owned cleanup failed; fixture retains owner and recovery route","owner":process_identity(owner.process.0),"recovery_pipe":recovery_name}));recover_cleanup(&mut owner,&recovery,&recovery_name,owned_project.as_deref(),owned_pane.as_deref(),owned_run.as_deref());}
        let owner_loss_outcome=std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if let Some(adapter)=owner_loss_adapter.take(){if outcome.is_ok()&&cleanup_error.is_none(){observe_actual_owner_loss(adapter,&owner);}else{adapter.finish(0,None);}}
        }));
        if owner_loss_outcome.is_err(){execution(json!({"stage":"actual owner loss proof failed after owned owner termination","original_failure_preserved":true,"continue_owned_handle_root_lease_folder_reclamation":true}));}
        for process in &owned_processes {assert_eq!(unsafe {WaitForSingleObject(process.0,INFINITE)},WAIT_OBJECT_0);execution(json!({"stage":"owned backend/run tree process terminated","process":process_identity(process.0)}));}
        assert_eq!(logical_empty(&std::fs::read(root.join("confirmed.json")).unwrap()),before);
        assert_eq!(root_identity(&root),identity);
        let lease_path:Vec<u16>=root.join("lease").as_os_str().encode_wide().chain(Some(0)).collect();
        let lease=Handle::new(unsafe {CreateFileW(lease_path.as_ptr(),GENERIC_READ|GENERIC_WRITE,0,null(),OPEN_EXISTING,0,null_mut())});drop(lease);
        for directory in &owner.owned_directories {
            assert!(directory.starts_with(&fixture)&&directory!=&fixture);
            assert!(std::fs::read_dir(directory).unwrap().next().is_none());std::fs::remove_dir(directory).unwrap();
        }
        std::fs::remove_dir(&fixture).unwrap();
        execution(json!({"stage":"owned family cleanup terminated","default_logical_preserved":true,"root_identity_preserved":true,"lease_released":true,"original_test_passed":outcome.is_ok()&&cleanup_error.is_none()&&owner_loss_outcome.is_ok(),"raw_restore":false,"force_kill":false}));
        if let Err(original)=outcome{std::panic::resume_unwind(original);}
        if let Some(original)=cleanup_error{std::panic::resume_unwind(original);}
        if let Err(original)=owner_loss_outcome{std::panic::resume_unwind(original);}
        println!("{}",json!({"class":"native family termination","owner_canary_preserved_during_adapter_cases":true,"confirmed_backup_exact_during_adapter_cases":true,"canary_owned_job_interrupted_and_exited":true,"owned_pane_project_removed":true,"default_logical_preserved":true,"root_identity_preserved":true,"lease_released":true,"owner_normal_exit":true,"raw_preimage_restore":false}));
    }
}
