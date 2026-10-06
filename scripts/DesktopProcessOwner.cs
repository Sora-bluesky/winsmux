using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Winsmux.DesktopNative {
    // One launch, one retained native root identity and one non-breakaway Job.
    // A PID or an ancestry snapshot is never termination authority.
    public sealed class Capture {
        public long TotalBytes { get; internal set; }
        public byte[] RetainedBytes { get; internal set; }
        public bool Truncated { get { return TotalBytes > RetainedBytes.LongLength; } }
    }
    public sealed class DesktopProcessOwner : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Security { public int Size; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
            public uint Size; public string Reserved, Desktop, Title;
            public uint X,Y,Width,Height,XChars,YChars,Fill,Flags;
            public ushort Show, ReservedSize; public IntPtr ReservedBytes,Input,Output,Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process,Thread; public uint Pid,Tid; }
        [StructLayout(LayoutKind.Sequential)] struct Accounting { public long User,Kernel,PeriodUser,PeriodKernel; public uint Faults,Total,Active,Terminated; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr security,string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security security,uint size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref UIntPtr size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,UIntPtr attribute,IntPtr value,UIntPtr size,IntPtr previous,IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupEx startup,out ProcessInfo process);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool contained);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int type,out Accounting accounting,uint size,IntPtr returned);
        delegate bool WindowCallback(IntPtr window,IntPtr parameter);
        [DllImport("user32.dll",SetLastError=true)] static extern bool EnumWindows(WindowCallback callback,IntPtr parameter);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window,uint command);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessageW(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);

        IntPtr root, job, thread, proofOutputHold;
        bool disposed, closeAttempted;
        readonly object closeGate=new object();
        Task<string> pendingLine;
        int resumeCount;
        FileStream input, output, error;
        public int Id { get; private set; }
        public bool Forced { get; private set; }
        public bool CloseAccepted { get; private set; }
        public int ResumeCount { get { return resumeCount; } }
        public StreamWriter StandardInput { get; private set; }
        public StreamReader StandardOutput { get; private set; }
        public Task<Capture> StdoutTask { get; private set; }
        public Task<Capture> StderrTask { get; private set; }
        public bool Interactive { get; private set; }
        public bool CaptureCompleted { get { return StdoutTask!=null && StderrTask!=null && StdoutTask.IsCompleted && StderrTask.IsCompleted; } }
        DesktopProcessOwner() { }
        static void Check(bool okay,string reason) { if (!okay) throw new InvalidOperationException(reason+":"+Marshal.GetLastWin32Error()); }
        void Live() { if (disposed || root==IntPtr.Zero || job==IntPtr.Zero) throw new InvalidOperationException("desktop_owner_released"); }
        static void Close(ref IntPtr handle) { if (handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
        static string Quote(string value) {
            if (value==null || value.IndexOf('\0')>=0) throw new ArgumentException("desktop_owner_argument_invalid");
            var result=new StringBuilder("\""); int slashes=0;
            foreach(char c in value) { if(c=='\\') { slashes++; continue; } result.Append('\\',c=='"'?slashes*2+1:slashes); result.Append(c); slashes=0; }
            return result.Append('\\',slashes*2).Append('"').ToString();
        }
        static IntPtr EnvironmentBlock(IDictionary overlay) {
            var values=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach(DictionaryEntry item in Environment.GetEnvironmentVariables()) values[(string)item.Key]=(string)item.Value;
            if(overlay!=null) foreach(DictionaryEntry item in overlay) {
                string key=Convert.ToString(item.Key), value=Convert.ToString(item.Value);
                if(String.IsNullOrEmpty(key) || key.IndexOf('=')>=0 || key.IndexOf('\0')>=0 || value.IndexOf('\0')>=0) throw new ArgumentException("desktop_owner_environment_invalid");
                values[key]=value;
            }
            return Marshal.StringToHGlobalUni(String.Join("\0",values.Select(pair=>pair.Key+"="+pair.Value))+"\0\0");
        }
        static FileStream Stream(ref IntPtr handle,FileAccess access) {
            var safe=new SafeFileHandle(handle,true); handle=IntPtr.Zero;
            try { return new FileStream(safe,access,4096,false); } catch { safe.Dispose(); throw; }
        }
        static Task<Capture> Drain(Stream stream,int limit) {
            // Pipe reads run independently before resume; capture retains only the existing byte bound.
            return Task.Run(()=> { using(var retained=new MemoryStream()) {
                byte[] buffer=new byte[4096]; long total=0; int count;
                while((count=stream.Read(buffer,0,buffer.Length))!=0) { total=checked(total+count); int keep=Math.Min(count,Math.Max(0,limit-(int)retained.Length)); if(keep>0) retained.Write(buffer,0,keep); }
                return new Capture { TotalBytes=total,RetainedBytes=retained.ToArray() };
            }});
        }
        public static DesktopProcessOwner Start(string executable,string[] arguments,IDictionary overlay,bool interactive,int retainLimit,int cleanupMilliseconds) {
            return Create(executable,arguments,overlay,interactive,retainLimit,cleanupMilliseconds,null);
        }
        // Deterministic pre-resume fault injection for the executable native class proof only.
        public static DesktopProcessOwner StartForProof(string executable,string[] arguments,IDictionary overlay,bool interactive,int retainLimit,int cleanupMilliseconds,string fault) {
            if(fault!="assignment" && fault!="membership" && fault!="resume" && fault!="eof") throw new ArgumentException("desktop_owner_proof_fault_invalid");
            return Create(executable,arguments,overlay,interactive,retainLimit,cleanupMilliseconds,fault);
        }
        static DesktopProcessOwner Create(string executable,string[] arguments,IDictionary overlay,bool interactive,int retainLimit,int cleanupMilliseconds,string fault) {
            if(retainLimit<0 || cleanupMilliseconds<0 || arguments==null) throw new ArgumentException("desktop_owner_configuration_invalid");
            executable=Path.GetFullPath(executable);
            string command=Quote(executable)+" "+String.Join(" ",arguments.Select(Quote));
            if(command.Length>=32767) throw new ArgumentException("desktop_owner_command_too_long");
            var owner=new DesktopProcessOwner { Interactive=interactive };
            IntPtr inRead=IntPtr.Zero,inWrite=IntPtr.Zero,outRead=IntPtr.Zero,outWrite=IntPtr.Zero,errRead=IntPtr.Zero,errWrite=IntPtr.Zero;
            IntPtr list=IntPtr.Zero,jobs=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero; bool initialized=false;
            try {
                owner.job=CreateJobObjectW(IntPtr.Zero,null); Check(owner.job!=IntPtr.Zero,"desktop_owner_job_create_failed");
                // A new Job has no breakaway flags. Descendants cannot opt out of this owner.
                var security=new Security { Size=Marshal.SizeOf(typeof(Security)),Inherit=true };
                Check(CreatePipe(out inRead,out inWrite,ref security,0),"desktop_owner_pipe_failed"); Check(SetHandleInformation(inWrite,1,0),"desktop_owner_pipe_failed");
                Check(CreatePipe(out outRead,out outWrite,ref security,0),"desktop_owner_pipe_failed"); Check(SetHandleInformation(outRead,1,0),"desktop_owner_pipe_failed");
                Check(CreatePipe(out errRead,out errWrite,ref security,0),"desktop_owner_pipe_failed"); Check(SetHandleInformation(errRead,1,0),"desktop_owner_pipe_failed");
                UIntPtr size=UIntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref size);
                list=Marshal.AllocHGlobal(checked((int)size.ToUInt64())); Check(InitializeProcThreadAttributeList(list,2,0,ref size),"desktop_owner_attributes_failed"); initialized=true;
                jobs=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs,fault=="assignment"?IntPtr.Zero:owner.job);
                Check(UpdateProcThreadAttribute(list,0,new UIntPtr(0x0002000D),jobs,new UIntPtr((uint)IntPtr.Size),IntPtr.Zero,IntPtr.Zero),"desktop_owner_job_assignment_failed");
                handles=Marshal.AllocHGlobal(IntPtr.Size*3); Marshal.WriteIntPtr(handles,0,inRead); Marshal.WriteIntPtr(handles,IntPtr.Size,outWrite); Marshal.WriteIntPtr(handles,IntPtr.Size*2,errWrite);
                Check(UpdateProcThreadAttribute(list,0,new UIntPtr(0x00020002),handles,new UIntPtr((uint)(IntPtr.Size*3)),IntPtr.Zero,IntPtr.Zero),"desktop_owner_handle_assignment_failed");
                var startup=new StartupEx(); startup.Startup.Size=(uint)Marshal.SizeOf(typeof(StartupEx)); startup.Attributes=list; startup.Startup.Flags=0x100;
                startup.Startup.Input=inRead; startup.Startup.Output=outWrite; startup.Startup.Error=errWrite;
                environment=EnvironmentBlock(overlay); ProcessInfo info;
                Check(CreateProcessW(executable,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08080404,environment,null,ref startup,out info),"desktop_owner_create_failed");
                owner.root=info.Process; owner.thread=info.Thread; owner.Id=checked((int)info.Pid);
                bool contained; Check(IsProcessInJob(owner.root,owner.job,out contained),"desktop_owner_membership_observation_failed");
                if(!contained || fault=="membership") throw new InvalidOperationException("desktop_owner_membership_unconfirmed");
                owner.input=Stream(ref inWrite,FileAccess.Write); owner.output=Stream(ref outRead,FileAccess.Read); owner.error=Stream(ref errRead,FileAccess.Read);
                owner.StderrTask=Drain(owner.error,retainLimit);
                if(interactive) {
                    owner.StandardInput=new StreamWriter(owner.input,new UTF8Encoding(false,true),4096,true);
                    owner.StandardOutput=new StreamReader(owner.output,new UTF8Encoding(false,true),false,4096,true);
                } else { owner.input.Dispose(); owner.StdoutTask=Drain(owner.output,retainLimit); }
                Close(ref inRead);
                if(fault=="eof") { owner.proofOutputHold=outWrite; outWrite=IntPtr.Zero; }
                Close(ref outWrite); Close(ref errWrite);
                if(fault=="resume") Close(ref owner.thread); // Native ResumeThread failure while root remains suspended.
                uint previous=ResumeThread(owner.thread); Check(previous!=UInt32.MaxValue,"desktop_owner_resume_failed");
                if(previous!=1) throw new InvalidOperationException("desktop_owner_resume_count_invalid");
                owner.resumeCount=1; Close(ref owner.thread); return owner;
            } catch(Exception failure) {
                bool created=owner.root!=IntPtr.Zero, recovered=!created;
                if(created) {
                    // Recovery uses retained handles even when assignment observation failed.
                    bool jobTerminated=TerminateJobObject(owner.job,1);
                    if(WaitForSingleObject(owner.root,0)!=0) TerminateProcess(owner.root,1);
                    recovered=WaitForSingleObject(owner.root,(uint)cleanupMilliseconds)==0;
                    if(recovered && jobTerminated) recovered=owner.WaitMembers(cleanupMilliseconds);
                }
                failure.Data["desktop_owner_created"]=created; failure.Data["desktop_owner_resumed"]=owner.resumeCount;
                failure.Data["desktop_owner_recovered"]=recovered;
                // Release parent copies before disposing pipe readers, including
                // faults halfway through reader preparation before normal close.
                Close(ref inRead); Close(ref outWrite); Close(ref errWrite);
                if(recovered) owner.Release();
                else failure.Data["desktop_owner_recovery_owner"]=owner;
                throw;
            } finally {
                Close(ref inRead); Close(ref inWrite); Close(ref outRead); Close(ref outWrite); Close(ref errRead); Close(ref errWrite);
                if(initialized) DeleteProcThreadAttributeList(list);
                foreach(IntPtr pointer in new[]{list,jobs,handles,environment}) if(pointer!=IntPtr.Zero) Marshal.FreeHGlobal(pointer);
            }
        }
        public bool HasExited { get { Live(); uint result=WaitForSingleObject(root,0); if(result==0) return true; if(result==258) return false; throw new InvalidOperationException("desktop_owner_root_observation_failed"); } }
        public int ExitCode { get { if(!HasExited) throw new InvalidOperationException("desktop_owner_root_not_terminal"); uint code; Check(GetExitCodeProcess(root,out code),"desktop_owner_exit_observation_failed"); return unchecked((int)code); } }
        public uint ActiveMembers { get { Live(); Accounting value; Check(QueryInformationJobObject(job,1,out value,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero),"desktop_owner_job_observation_failed"); return value.Active; } }
        public void Refresh() { Live(); }
        public bool WaitForExit(int milliseconds) { Live(); if(milliseconds<0) throw new ArgumentOutOfRangeException(); uint result=WaitForSingleObject(root,(uint)milliseconds); if(result==0) return true; if(result==258) return false; throw new InvalidOperationException("desktop_owner_root_observation_failed"); }
        bool WaitMembers(int milliseconds) { var timer=Stopwatch.StartNew(); do { if(ActiveMembers==0) return true; Thread.Sleep(1); } while(timer.ElapsedMilliseconds<milliseconds); return ActiveMembers==0; }
        public bool CloseMainWindow() {
            lock(closeGate) {
            Live(); if(closeAttempted || Forced) throw new InvalidOperationException("desktop_normal_close_reentrant_or_forced"); closeAttempted=true;
            if(HasExited) throw new InvalidOperationException("desktop_normal_close_app_already_exited");
            IntPtr selected=IntPtr.Zero;
            EnumWindows((window,unused)=> { uint pid; GetWindowThreadProcessId(window,out pid); if(pid==(uint)Id && IsWindowVisible(window) && GetWindow(window,4)==IntPtr.Zero) { selected=window; return false; } return true; },IntPtr.Zero);
            if(selected==IntPtr.Zero || HasExited) return false;
            uint current; GetWindowThreadProcessId(selected,out current);
            if(current!=(uint)Id) return false;
            CloseAccepted=PostMessageW(selected,0x10,IntPtr.Zero,IntPtr.Zero); return CloseAccepted;
            }
        }
        public Task<string> ReadLineAsync(int limit) {
            Live(); if(!Interactive || StdoutTask!=null || limit<0 || (pendingLine!=null && !pendingLine.IsCompleted)) throw new InvalidOperationException("desktop_owner_read_transition_invalid");
            pendingLine=ReadLineCore(limit); return pendingLine;
        }
        async Task<string> ReadLineCore(int limit) {
            var text=new StringBuilder(); var one=new char[1];
            while(true) {
                int count=await StandardOutput.ReadAsync(one,0,1).ConfigureAwait(false);
                if(count==0) return text.Length==0?null:text.ToString();
                if(one[0]=='\n') return text.ToString();
                if(text.Length>=limit) throw new InvalidDataException("desktop_mcp_response_oversized");
                text.Append(one[0]);
            }
        }
        public void FinishInputAndDrain() {
            Live(); if(!Interactive || StdoutTask!=null) throw new InvalidOperationException("desktop_owner_stdin_transition_invalid");
            Exception closeFailure=null;
            try { StandardInput.Dispose(); } catch(IOException failure) { closeFailure=failure; }
            finally { StandardInput=null; input.Dispose(); }
            // Serialize a timed-out protocol read and the tail drain. Killing the
            // owned Job releases inherited pipe writers; the caller's terminal
            // deadline still bounds awaiting both reads, including fault completion.
            Task<string> prior=pendingLine;
            StdoutTask=Task.Run(async()=> { if(prior!=null) await prior.ConfigureAwait(false); long total=0; char[] buffer=new char[4096]; int count; while((count=await StandardOutput.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false))!=0) total=checked(total+count); return new Capture { TotalBytes=total,RetainedBytes=Array.Empty<byte>() }; });
            if(closeFailure!=null) throw new InvalidOperationException("desktop_owner_stdin_close_failed",closeFailure);
        }
        public bool WaitTerminal(int milliseconds,int pollMilliseconds) {
            Live(); if(milliseconds<0 || pollMilliseconds<=0) throw new ArgumentOutOfRangeException();
            var timer=Stopwatch.StartNew();
            do {
                if(HasExited && ActiveMembers==0 && StdoutTask!=null && StdoutTask.IsCompleted && StderrTask.IsCompleted) {
                    // GetResult is reached only after completion, including fault completion.
                    StdoutTask.GetAwaiter().GetResult(); StderrTask.GetAwaiter().GetResult(); return true;
                }
                int remaining=milliseconds-(int)Math.Min(Int32.MaxValue,timer.ElapsedMilliseconds);
                if(remaining<=0) break; Thread.Sleep(Math.Min(pollMilliseconds,remaining));
            } while(true);
            return false;
        }
        public void RequireNormalCompletion(int milliseconds,int pollMilliseconds) {
            if(Forced || !closeAttempted || !CloseAccepted) throw new InvalidOperationException("desktop_normal_close_unconfirmed");
            if(!WaitTerminal(milliseconds,pollMilliseconds)) throw new InvalidOperationException("desktop_normal_close_incomplete");
            if(Forced || ExitCode!=0) throw new InvalidOperationException("desktop_normal_close_exit_nonzero_or_forced");
        }
        // Call only after the operation failure is established. This cannot earn a normal receipt.
        public void ForceFailureCleanup(int milliseconds,int pollMilliseconds) {
            Live(); lock(closeGate) { Forced=true; } Check(TerminateJobObject(job,1),"desktop_owner_failure_cleanup_failed");
            if(Interactive && StdoutTask==null) {
                try { FinishInputAndDrain(); }
                catch(InvalidOperationException) { if(StdoutTask==null) throw; }
            }
            if(!WaitTerminal(milliseconds,pollMilliseconds)) throw new InvalidOperationException("desktop_owner_failure_cleanup_incomplete");
        }
        public void ReleaseProofOutputHold() { Live(); if(proofOutputHold==IntPtr.Zero) throw new InvalidOperationException("desktop_owner_proof_hold_missing"); Close(ref proofOutputHold); }
        void Release() {
            disposed=true; Close(ref proofOutputHold);
            if(StandardInput!=null) StandardInput.Dispose(); if(StandardOutput!=null) StandardOutput.Dispose();
            if(input!=null) input.Dispose(); if(output!=null) output.Dispose(); if(error!=null) error.Dispose();
            Close(ref thread); Close(ref root); Close(ref job);
        }
        public void Dispose() {
            if(disposed) return;
            if(root!=IntPtr.Zero && (!HasExited || ActiveMembers!=0)) throw new InvalidOperationException("desktop_owner_release_nonterminal");
            if(!CaptureCompleted) throw new InvalidOperationException("desktop_owner_release_capture_unconfirmed");
            Release();
        }
    }
}
