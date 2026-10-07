using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Diagnostics;
using System.IO.Pipes;
using System.Globalization;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

// Parent-owned custody and child lifetime only. This does not confer publication
// authority or perform publication, forced termination or product-data access.
public sealed class IntegratedPublicationCustody : IDisposable {
    static readonly string[] Names = new[] {
        "core/SHA256SUMS", "core/winsmux-arm64.exe", "core/winsmux-arm64.exe.licenses.zip",
        "core/winsmux-remote-helper-linux-x64", "core/winsmux-x64.exe", "core/winsmux-x64.exe.licenses.zip",
        "desktop/SHA256SUMS-desktop", "desktop/latest.json", "desktop/winsmux_0.38.0_x64-setup.exe",
        "desktop/winsmux_0.38.0_x64-setup.exe.sig", "desktop/winsmux_0.38.0_x64-setup.inventory.json",
        "desktop/winsmux_0.38.0_x64_en-US.msi",
        "npm/winsmux-0.38.0.tgz", "release-body.md"
    }.OrderBy(x => x, StringComparer.Ordinal).ToArray();
    [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct FileInformation {
        public uint Attributes; public FileTime Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFileAttributesW(string name);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public uint Size; public string Reserved, Desktop, Title;
        public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedSize; public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation { public IntPtr Process, Thread; public uint Pid, Tid; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr security, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes security, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref UIntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, UIntPtr attribute, IntPtr value, UIntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
        bool inherit, uint flags, IntPtr environment, string directory, ref StartupEx startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool contained);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr buffer, uint bytes, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr process, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool PeekNamedPipe(SafePipeHandle pipe, IntPtr buffer, uint length, IntPtr read, IntPtr available, IntPtr left);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref uint length);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DuplicateHandle(IntPtr from, IntPtr source, IntPtr to, out IntPtr copy, uint access, bool inherit, uint options);
    [DllImport("kernelbase.dll", SetLastError = true)] static extern bool CompareObjectHandles(IntPtr first, IntPtr second);
    readonly string root;
    readonly Dictionary<string, FileStream> files = new Dictionary<string, FileStream>(StringComparer.Ordinal);
    readonly Dictionary<string, string> expected = new Dictionary<string, string>(StringComparer.Ordinal);
    readonly Dictionary<string, string> identities = new Dictionary<string, string>(StringComparer.Ordinal);
    readonly List<SafeFileHandle> directories = new List<SafeFileHandle>();
    readonly HashSet<string> directoryPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    readonly object gate = new object();
    readonly List<Child> children = new List<Child>();
    IntPtr job;
    string jobName;
    bool sealedLaunches;
    bool released;
    Process keeperProcess;
    IntPtr keeperNativeProcess, keeperNativeThread;
    bool keeperResumed;
    KeeperIdentity keeper;
    readonly List<FileStream> keeperInputs = new List<FileStream>();
    FileStream npmCliInput;
    AuthorityConnection authority;
    bool authorityDisconnected;
    Dictionary<string, PublicationOperation> fixedOperations;
    string runtimeTemp;
    string sourceManifest, sourceManifestHash, sourceGuard;
    readonly Dictionary<string, string[]> sourceDirectories = new Dictionary<string, string[]>(StringComparer.Ordinal);
    readonly Dictionary<string, FileStream> sourceFiles = new Dictionary<string, FileStream>(StringComparer.Ordinal);
    readonly Dictionary<string, string> sourceHashes = new Dictionary<string, string>(StringComparer.Ordinal);
    PublicationRuntimeProfile publicationRuntime;
    public string RuntimeSourceSha256 { get { return sourceManifestHash; } }
    public sealed class PublicationRuntimeProfile {
        public string SourceManifest { get; internal set; }
        public string SourceManifestSha256 { get; internal set; }
        public string GuardFile { get; internal set; }
        public string GuardSha256 { get; internal set; }
        public string TemporaryDirectory { get; internal set; }
        public string UserConfig { get; internal set; }
        public string GlobalConfig { get; internal set; }
        public string NpmCache { get; internal set; }
        public bool PublicationAdmitted { get { return false; } }
    }
    int observationTimeout;
    public int HeldFileCount { get { return files.Count; } }
    public bool Released { get { return released; } }
    public string JobName { get { lock (gate) { return jobName; } } }
    public int NativeCreateCalls { get; private set; }
    public int KeeperNativeCreateCalls { get; private set; }
    public KeeperIdentity Keeper { get { lock (gate) { return keeper; } } }
    public bool NpmCliHeld { get { lock (gate) { return npmCliInput != null && !released; } } }
    public bool AuthorityDisconnected { get { lock (gate) { return authorityDisconnected || (authority != null && !authority.IsLive()); } } }
    public sealed class ActorIdentity {
        public uint Pid { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public string EnvironmentSha256 { get; internal set; }
        public string SourceManifestSha256 { get; internal set; }
    }
    public static ActorIdentity CurrentOwnerIdentity() {
        return new ActorIdentity { Pid = (uint)Environment.ProcessId, CreationFileTime = CreationTime(GetCurrentProcess()) };
    }
    // The owner creates this actor and retains the original creation HANDLEs.
    // Neither a caller PID nor a wire approval can reconstruct this connection.
    // Public decisions remain in the Node actor; the owner is a native adapter.
    public sealed class AuthorityConnection {
        IntPtr actorProcess;
        IntPtr actorThread;
        readonly NamedPipeServerStream pipe;
        readonly int timeout;
        StreamReader reader;
        StreamWriter writer;
        bool accepted, disconnected, resumed;
        public ActorIdentity Actor { get; private set; }
        public ActorIdentity Owner { get; private set; }
        public bool ActorExited { get { return WaitForSingleObject(actorProcess, 0) == 0; } }
        public uint ActorExitCode {
            get { if (!ActorExited) throw new InvalidOperationException("Actor exit not observed"); uint code; Check(GetExitCodeProcess(actorProcess, out code)); return code; }
        }
        internal AuthorityConnection(string pipeName, int observationTimeout) {
            if (!Guid.TryParseExact(pipeName, "D", out _) || observationTimeout <= 0)
                throw new ArgumentException("Exact one-attempt pipe and host observation timeout required");
            timeout = observationTimeout;
            Owner = new ActorIdentity { Pid = (uint)Environment.ProcessId, CreationFileTime = CreationTime(GetCurrentProcess()) };
            pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        }
        internal void BindCreated(ProcessInformation process, string environmentHash, string sourceHash, Action<ActorIdentity> persistActor) {
            if (actorProcess != IntPtr.Zero || disconnected || persistActor == null) throw new InvalidOperationException("Actor creation already bound");
            actorProcess = process.Process; actorThread = process.Thread;
            Actor = new ActorIdentity { Pid = process.Pid, CreationFileTime = CreationTime(actorProcess), EnvironmentSha256 = environmentHash, SourceManifestSha256 = sourceHash };
            persistActor(Actor);
        }
        internal void Resume() {
            if (actorProcess == IntPtr.Zero || Actor == null || resumed || disconnected) throw new InvalidOperationException("Actor bootstrap resume closed");
            if (CreationTime(actorProcess) != Actor.CreationFileTime || WaitForSingleObject(actorProcess, 0) != 258)
                throw new InvalidOperationException("Original suspended actor differs or exited");
            uint previous = ResumeThread(actorThread);
            if (previous == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (previous != 1) throw new InvalidOperationException("Unexpected actor suspend count");
            resumed = true;
        }
        public void Accept() {
            if (!resumed || accepted || disconnected) throw new InvalidOperationException("Authority connection cannot reconnect");
            try {
                var connection = pipe.WaitForConnectionAsync();
                if (!connection.Wait(timeout)) throw new TimeoutException("Authority connection incomplete");
                connection.GetAwaiter().GetResult();
                uint peer; Check(GetNamedPipeClientProcessId(pipe.SafePipeHandle, out peer));
                if (peer != Actor.Pid || CreationTime(actorProcess) != Actor.CreationFileTime || WaitForSingleObject(actorProcess, 0) != 258)
                    throw new InvalidOperationException("Authority pipe peer differs from original created actor");
                reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, true);
                writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
                accepted = true; RequireLive();
            } catch { disconnected = true; throw; }
        }
        internal bool IsLive() {
            if (disconnected) return false;
            if (actorProcess == IntPtr.Zero || WaitForSingleObject(actorProcess, 0) != 258 || (accepted && (!pipe.IsConnected || !PeekNamedPipe(pipe.SafePipeHandle, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero))))
                disconnected = true;
            return accepted && !disconnected;
        }
        internal void RequireLive() {
            if (!IsLive()) throw new InvalidOperationException("Authority disconnected; retain frozen custody and keeper");
        }
        internal void RequireDecision(string phase, string binding, string operationId = null) {
            RequireLive(); Digest(binding);
            string nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            try {
                string[] fields = operationId == null ? new[] { phase, binding, nonce } : new[] { operationId, phase, binding, nonce };
                writer.WriteLine("DECIDE|" + String.Join("|", fields));
                if (ReadLine(reader, timeout) != "PROCEED|" + String.Join("|", fields))
                    throw new InvalidOperationException("Exact live one-operation decision missing");
                RequireLive();
            } catch { disconnected = true; throw; }
        }
        // Closing the authority transport is itself a permanent disconnect.
        // It cannot be used as a normal custody release or reconnect path.
        public void Disconnect() { disconnected = true; pipe.Dispose(); }
        internal void ReleaseAfterNormalCustody() {
            writer.Dispose(); reader.Dispose(); pipe.Dispose(); CloseHandle(actorThread); CloseHandle(actorProcess); disconnected = true;
        }
    }
    public AuthorityConnection StartAuthorityActor(string pipeName, string actorImage, string imageHash, string actorScript, string scriptHash,
        string[] bootstrapArguments, string workingDirectory, int observationTimeout, Action<ActorIdentity> persistActor) {
        lock (gate) {
            if (released || authority != null || keeper != null || children.Count != 0 || sealedLaunches || persistActor == null)
                throw new InvalidOperationException("Authority binding must precede keeper and every publication child");
            if (!Guid.TryParseExact(pipeName, "D", out _) || observationTimeout <= 0 || bootstrapArguments == null || bootstrapArguments.Any(x => x == null))
                throw new ArgumentException("Fixed bootstrap and one-attempt pipe required");
            actorImage = Path.GetFullPath(actorImage); actorScript = Path.GetFullPath(actorScript);
            workingDirectory = Path.GetFullPath(workingDirectory); HoldAncestors(workingDirectory);
            HoldKeeperInput(actorImage, imageHash); HoldKeeperInput(actorScript, scriptHash); VerifyUnsafe(); EnsureJob();
            if (sourceManifest != null && !sourceFiles.ContainsKey(actorScript)) throw new InvalidOperationException("Authority bootstrap is outside fixed runtime sources");
            string[] prefix = sourceManifest == null ? new[] { actorScript } : new[] { "--no-addons", "--import", new Uri(sourceGuard).AbsoluteUri, actorScript };
            string command = QuoteArgument(actorImage) + " " + String.Join(" ", prefix.Concat(bootstrapArguments).Select(QuoteArgument));
            if (command.Length >= 32767) throw new ArgumentException("Actor bootstrap command too long");
            var startup = new StartupEx(); startup.Startup.Size = (uint)Marshal.SizeOf(typeof(Startup));
            // Prepare the receive endpoint before creating any actor. Allocation
            // failure must not leave an unrecorded stopped process behind.
            authority = new AuthorityConnection(pipeName, observationTimeout);
            ProcessInformation process; string environmentHash;
            using (var environment = IntegratedPublicationEnvironment.Create(sourceManifest == null ? "fixture" : "authority", RuntimeTemp(), actorImage, sourceManifest, sourceManifestHash)) {
                environmentHash = environment.Sha256;
                Check(CreateProcessW(actorImage, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                    0x08000004u | IntegratedPublicationEnvironment.UnicodeFlag, environment.Block, workingDirectory, ref startup, out process));
            }
            // Retain the actual stopped process even if persistence or membership
            // verification fails. Never create a replacement, resume or terminate it.
            authority.BindCreated(process, environmentHash, sourceManifestHash, persistActor);
            var actualImage = new StringBuilder(32768); uint imageLength = (uint)actualImage.Capacity;
            Check(QueryFullProcessImageNameW(process.Process, 0, actualImage, ref imageLength));
            if (!String.Equals(actualImage.ToString(), actorImage, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Created authority actor image differs from held image");
            bool contained; Check(IsProcessInJob(process.Process, job, out contained));
            if (contained) throw new InvalidOperationException("Authority actor unexpectedly belongs to publication Job");
            VerifyUnsafe(); authority.Resume(); VerifyUnsafe();
            return authority;
        }
    }
    void RequireAuthorityLive() {
        if (authority == null) return; // Existing single-native-parent route has no wire adapter.
        if (authorityDisconnected || !authority.IsLive()) {
            authorityDisconnected = true; sealedLaunches = true;
            throw new InvalidOperationException("Authority disconnected; retain frozen custody and keeper");
        }
    }
    public sealed class KeeperIdentity {
        public uint Pid { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public uint OwnerPid { get; internal set; }
        public long OwnerCreationFileTime { get; internal set; }
        public string JobName { get; internal set; }
        public string PipeName { get; internal set; }
        public string Attempt { get; internal set; }
        public string CandidateSha256 { get; internal set; }
        public string ImplementationSha256 { get; internal set; }
        public string ScriptSha256 { get; internal set; }
        public string EnvironmentSha256 { get; internal set; }
    }
    public sealed class Child {
        internal readonly IntegratedPublicationCustody Owner;
        internal readonly IntPtr Process, Thread;
        internal readonly FileStream Image;
        internal bool Resumed;
        internal string OperationBinding;
        internal PublicationOperation Operation;
        public uint Pid { get; private set; }
        public long CreationFileTime { get; internal set; }
        public string EnvironmentSha256 { get; internal set; }
        internal ChildOutput Output;
        internal Child(IntegratedPublicationCustody owner, ProcessInformation process, FileStream image) {
            Owner = owner; Process = process.Process; Thread = process.Thread; Pid = process.Pid; Image = image;
        }
    }
    public sealed class StreamOutputObservation {
        public long Bytes { get; internal set; }
        public string Sha256 { get; internal set; }
        public bool Complete { get; internal set; }
        public string FailureKind { get; internal set; }
    }
    public sealed class ChildOutputObservation {
        public uint Pid { get; internal set; }
        public long CreationFileTime { get; internal set; }
        public uint ExitCode { get; internal set; }
        public string EnvironmentSha256 { get; internal set; }
        public string OperationBindingSha256 { get; internal set; }
        public StreamOutputObservation Stdout { get; internal set; }
        public StreamOutputObservation Stderr { get; internal set; }
        public bool PublicationAdmitted { get { return false; } }
    }
    internal sealed class ChildOutput : IDisposable {
        internal IntPtr Input, OutWrite, ErrorWrite;
        IntPtr outRead, errorRead;
        Task<StreamOutputObservation> stdout, stderr;
        internal ChildOutput() {
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Inherit = true };
            IntPtr securityPointer = Marshal.AllocHGlobal(security.Length);
            try {
                Marshal.StructureToPtr(security, securityPointer, false);
                Check(CreatePipe(out outRead, out OutWrite, ref security, 0)); Check(SetHandleInformation(outRead, 1, 0));
                Check(CreatePipe(out errorRead, out ErrorWrite, ref security, 0)); Check(SetHandleInformation(errorRead, 1, 0));
                var input = CreateFileW("NUL", 0x80000000u, 3, securityPointer, 3, 0, IntPtr.Zero);
                if (input.IsInvalid) { input.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                // The native creation receives this exact handle through the
                // explicit handle list. SafeHandle ownership moves to this object.
                Input = input.DangerousGetHandle(); input.SetHandleAsInvalid(); input.Dispose();
            } catch { Dispose(); throw; } finally { Marshal.FreeHGlobal(securityPointer); }
        }
        static Task<StreamOutputObservation> Drain(IntPtr handle) {
            return Task.Run(() => {
                var result = new StreamOutputObservation(); byte[] buffer = new byte[16384];
                using (var stream = new FileStream(new SafeFileHandle(handle, true), FileAccess.Read, buffer.Length, false))
                using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
                    try {
                        for (;;) { int read = stream.Read(buffer, 0, buffer.Length); if (read == 0) break;
                            result.Bytes = checked(result.Bytes + read); hash.AppendData(buffer, 0, read); Array.Clear(buffer, 0, read);
                        }
                        result.Complete = true;
                    } catch (Exception error) { result.FailureKind = error.GetType().Name; }
                    finally { Array.Clear(buffer, 0, buffer.Length); result.Sha256 = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(); }
                }
                return result;
            });
        }
        internal void Created() {
            CloseWrites(); IntPtr first = outRead, second = errorRead; outRead = errorRead = IntPtr.Zero;
            stdout = Drain(first); stderr = Drain(second); // Concurrent; neither pipe can block the other.
        }
        void CloseWrites() {
            if (Input != IntPtr.Zero) { CloseHandle(Input); Input = IntPtr.Zero; }
            if (OutWrite != IntPtr.Zero) { CloseHandle(OutWrite); OutWrite = IntPtr.Zero; }
            if (ErrorWrite != IntPtr.Zero) { CloseHandle(ErrorWrite); ErrorWrite = IntPtr.Zero; }
        }
        internal bool Complete { get { return stdout != null && stderr != null && stdout.IsCompleted && stderr.IsCompleted; } }
        internal StreamOutputObservation OutResult { get { return stdout.GetAwaiter().GetResult(); } }
        internal StreamOutputObservation ErrorResult { get { return stderr.GetAwaiter().GetResult(); } }
        public void Dispose() {
            CloseWrites();
            if (outRead != IntPtr.Zero) { CloseHandle(outRead); outRead = IntPtr.Zero; }
            if (errorRead != IntPtr.Zero) { CloseHandle(errorRead); errorRead = IntPtr.Zero; }
            // Started reader tasks own their read HANDLEs until actual EOF.
            // No cancellation may convert an incomplete capture into success.
        }
    }
    public sealed class PublicationOperation {
        internal readonly IntegratedPublicationCustody Owner;
        internal readonly string Executable, ImageHash, Directory;
        internal readonly string[] Arguments;
        internal Child CreatedChild;
        public string Id { get; private set; }
        public string BindingSha256 { get; private set; }
        internal PublicationOperation(IntegratedPublicationCustody owner, string id, string binding,
            string executable, string hash, string[] arguments, string directory) {
            Owner = owner; Id = id; BindingSha256 = binding; Executable = executable;
            ImageHash = hash; Arguments = arguments.ToArray(); Directory = directory;
        }
    }
    static void JsonKeys(JsonElement value, params string[] names) {
        if (value.ValueKind != JsonValueKind.Object || !value.EnumerateObject().Select(x => x.Name).OrderBy(x => x, StringComparer.Ordinal)
            .SequenceEqual(names.OrderBy(x => x, StringComparer.Ordinal))) throw new InvalidOperationException("Fixed operation JSON keys differ");
    }
    static string JsonText(JsonElement value, string key) {
        var item = value.GetProperty(key);
        if (item.ValueKind != JsonValueKind.String || item.GetString() == null) throw new InvalidOperationException("Fixed operation string missing");
        return item.GetString();
    }
    static void FalseFlag(JsonElement value, string key) {
        if (value.GetProperty(key).ValueKind != JsonValueKind.False) throw new InvalidOperationException("Operation table cannot confer publication authority");
    }
    // Install immutable command bytes observed by the Node actor. This table
    // conveys no authority: each creation and resume still needs a live nonce
    // response from the original actor. Wire requests select an ID, never argv.
    public int FixPublicationOperations(string tableFile, string tableHash, string parentSession) {
        lock (gate) {
            RequireAuthorityLive();
            if (authority == null || fixedOperations != null || keeper != null || children.Count != 0 || sealedLaunches || released)
                throw new InvalidOperationException("Fixed native operation table setup closed");
            if (String.IsNullOrEmpty(parentSession)) throw new ArgumentException("Exact parent session required");
            VerifyUnsafe(); var input = HoldKeeperInput(tableFile, tableHash);
            input.Position = 0;
            using (var document = JsonDocument.Parse(input, new JsonDocumentOptions { AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow })) {
                var table = document.RootElement;
                bool runtimeTable = JsonText(table, "schema") == "winsmux-native-publication-operation-table/v2";
                string[] tableKeys = new[] { "schema", "candidate_identity", "bundle_root", "parent_session", "entries", "action_time_authority_verified", "native_custody_verified", "publication_admitted" };
                JsonKeys(table, runtimeTable ? tableKeys.Concat(new[] { "runtime_inputs" }).ToArray() : tableKeys);
                if (!runtimeTable && JsonText(table, "schema") != "winsmux-native-publication-operation-table/v1" || JsonText(table, "parent_session") != parentSession ||
                    !String.Equals(JsonText(table, "bundle_root"), root, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Fixed table parent or held bundle differs");
                if (runtimeTable) {
                    if (publicationRuntime == null) throw new InvalidOperationException("Original prepared native runtime missing");
                    var runtime = table.GetProperty("runtime_inputs");
                    JsonKeys(runtime, "source_manifest", "source_manifest_sha256", "guard_file", "guard_sha256", "temp_directory", "user_config", "global_config", "npm_cache");
                    var values = new[] { Tuple.Create("source_manifest", publicationRuntime.SourceManifest), Tuple.Create("source_manifest_sha256", publicationRuntime.SourceManifestSha256),
                        Tuple.Create("guard_file", publicationRuntime.GuardFile), Tuple.Create("guard_sha256", publicationRuntime.GuardSha256), Tuple.Create("temp_directory", publicationRuntime.TemporaryDirectory),
                        Tuple.Create("user_config", publicationRuntime.UserConfig), Tuple.Create("global_config", publicationRuntime.GlobalConfig), Tuple.Create("npm_cache", publicationRuntime.NpmCache) };
                    if (values.Any(value => JsonText(runtime, value.Item1) != value.Item2)) throw new InvalidOperationException("Table runtime differs from original held native profile");
                }
                FalseFlag(table, "action_time_authority_verified"); FalseFlag(table, "native_custody_verified"); FalseFlag(table, "publication_admitted");
                var candidate = table.GetProperty("candidate_identity");
                JsonKeys(candidate, "version", "source_commit", "source_tree", "attempt", "assets_sha256", "manifest_sha256");
                if (JsonText(candidate, "version") != "0.38.0" || !Guid.TryParseExact(JsonText(candidate, "attempt"), "D", out _))
                    throw new InvalidOperationException("Fixed candidate version or attempt differs");
                string commit = JsonText(candidate, "source_commit"), tree = JsonText(candidate, "source_tree");
                if (commit.Length != 40 || tree.Length != 40 || (commit + tree).Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')))
                    throw new InvalidOperationException("Fixed candidate Git identity missing");
                Digest(JsonText(candidate, "assets_sha256")); Digest(JsonText(candidate, "manifest_sha256"));
                var entries = table.GetProperty("entries");
                if (entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() > 3) throw new InvalidOperationException("Closed publication operation inventory required");
                var parsed = new Dictionary<string, PublicationOperation>(StringComparer.Ordinal);
                var usedAssets = new HashSet<string>(StringComparer.Ordinal);
                foreach (var entry in entries.EnumerateArray()) {
                    JsonKeys(entry, "operation_id", "binding_sha256", "destination", "assets", "kind", "executable",
                        "executable_sha256", "arguments", "additional_read_inputs", "working_directory", "publication_admitted");
                    FalseFlag(entry, "publication_admitted");
                    string id = JsonText(entry, "operation_id"), binding = JsonText(entry, "binding_sha256"); Digest(binding);
                    if (parsed.Values.Any(operation => operation.BindingSha256 == binding)) throw new InvalidOperationException("Duplicate fixed operation binding");
                    string image = JsonText(entry, "executable"), imageHash = JsonText(entry, "executable_sha256");
                    string directory = JsonText(entry, "working_directory");
                    if (!String.Equals(directory, root, StringComparison.OrdinalIgnoreCase) || !Path.IsPathFullyQualified(image) || image.StartsWith("\\\\", StringComparison.Ordinal))
                        throw new InvalidOperationException("Fixed local image or held working directory differs");
                    var assets = entry.GetProperty("assets");
                    if (assets.ValueKind != JsonValueKind.Array || assets.GetArrayLength() == 0) throw new InvalidOperationException("Operation assets missing");
                    var selected = new List<string>();
                    foreach (var asset in assets.EnumerateArray()) {
                        JsonKeys(asset, "path", "bytes", "sha256", "producer");
                        string relative = JsonText(asset, "path");
                        if (!expected.ContainsKey(relative) || !usedAssets.Add(relative) || JsonText(asset, "sha256") != expected[relative] ||
                            !asset.GetProperty("bytes").TryGetInt64(out long bytes) || bytes != files[relative].Length)
                            throw new InvalidOperationException("Operation assets differ from held bytes");
                        selected.Add(relative);
                    }
                    var argv = entry.GetProperty("arguments");
                    if (argv.ValueKind != JsonValueKind.Array || argv.EnumerateArray().Any(x => x.ValueKind != JsonValueKind.String))
                        throw new InvalidOperationException("Fixed argv required");
                    string[] arguments = argv.EnumerateArray().Select(x => x.GetString()).ToArray();
                    var additional = entry.GetProperty("additional_read_inputs");
                    if (additional.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("Fixed additional input inventory required");
                    string[] exact;
                    if (id == "github-release") {
                        if (JsonText(entry, "kind") != "github_release_create" || !selected.SequenceEqual(new[] { "release-body.md" }))
                            throw new InvalidOperationException("Fixed release creation differs");
                        exact = new[] { "release", "create", "v0.38.0", "--repo", "github.com/Sora-bluesky/winsmux", "--target", commit,
                            "--title", "v0.38.0", "--notes-file", Path.Combine(root, "release-body.md") };
                    } else if (id == "github-assets") {
                        if (JsonText(entry, "kind") != "github_release_upload" || selected.Any(x => !x.StartsWith("core/", StringComparison.Ordinal) && !x.StartsWith("desktop/", StringComparison.Ordinal)))
                            throw new InvalidOperationException("Fixed release assets differ");
                        exact = new[] { "release", "upload", "v0.38.0", "--repo", "github.com/Sora-bluesky/winsmux" }
                            .Concat(selected.Select(x => Path.Combine(root, x.Replace('/', Path.DirectorySeparatorChar)))).ToArray();
                    } else if (id == "npm-archive") {
                        if (JsonText(entry, "kind") != "npm_publish" || JsonText(entry, "destination") != "https://registry.npmjs.org/winsmux" ||
                            !selected.SequenceEqual(new[] { "npm/winsmux-0.38.0.tgz" }) || Path.GetFileName(image) != "node.exe" || additional.GetArrayLength() != 1)
                            throw new InvalidOperationException("Fixed npm publication differs");
                        var cli = additional[0]; JsonKeys(cli, "path", "bytes", "sha256", "identity");
                        string cliPath = JsonText(cli, "path");
                        if (!Path.IsPathFullyQualified(cliPath) || cliPath.StartsWith("\\\\", StringComparison.Ordinal) || Path.GetFileName(cliPath) != "npm-cli.js")
                            throw new InvalidOperationException("Fixed npm interpreter source required");
                        var cliInput = HoldKeeperInput(cliPath, JsonText(cli, "sha256"));
                        if (!cli.GetProperty("bytes").TryGetInt64(out long cliBytes) || cliBytes != cliInput.Length) throw new InvalidOperationException("Fixed npm source size differs");
                        exact = new[] { cliPath, "publish", Path.Combine(root, "npm", "winsmux-0.38.0.tgz"), "--ignore-scripts", "--registry=https://registry.npmjs.org", "--tag", "latest" };
                        if (runtimeTable) {
                            if (!sourceFiles.ContainsKey(cliPath)) throw new InvalidOperationException("npm entry outside original held source closure");
                            exact = new[] { "--no-addons", "--import", new Uri(sourceGuard).AbsoluteUri }.Concat(exact).Concat(new[] {
                                "--userconfig=" + publicationRuntime.UserConfig, "--globalconfig=" + publicationRuntime.GlobalConfig, "--cache=" + publicationRuntime.NpmCache,
                                "--prefix=" + root, "--logs-max=0", "--loglevel=silent", "--update-notifier=false", "--audit=false", "--fund=false", "--provenance=false" }).ToArray();
                        }
                    } else throw new InvalidOperationException("Unknown fixed publication operation");
                    if (id.StartsWith("github-", StringComparison.Ordinal) && (JsonText(entry, "destination") != "https://github.com/Sora-bluesky/winsmux/releases/tag/v0.38.0" ||
                        Path.GetFileName(image) != "gh.exe" || additional.GetArrayLength() != 0)) throw new InvalidOperationException("Fixed GitHub destination or image differs");
                    if (!arguments.SequenceEqual(exact)) throw new InvalidOperationException("Fixed publication argv differs");
                    HoldKeeperInput(image, imageHash);
                    if (!parsed.TryAdd(id, new PublicationOperation(this, id, binding, image, imageHash, arguments, root)))
                        throw new InvalidOperationException("Duplicate publication operation ID");
                }
                VerifyUnsafe(); RequireAuthorityLive(); fixedOperations = parsed;
                return parsed.Count;
            }
        }
    }
    public PublicationOperation SelectPublicationOperation(string id) {
        lock (gate) {
            RequireAuthorityLive();
            if (released || sealedLaunches || fixedOperations == null || id == null || !fixedOperations.TryGetValue(id, out var operation))
                throw new InvalidOperationException("Original fixed publication operation missing");
            return operation;
        }
    }
    public Child CreatePublicationOperation(PublicationOperation operation, Action<string> persistInFlight, Action<uint, long, string> persistStopped) {
        lock (gate) {
            RequireAuthorityLive();
            if (operation == null || operation.Owner != this || fixedOperations == null || !fixedOperations.TryGetValue(operation.Id, out var original) ||
                !Object.ReferenceEquals(original, operation) || operation.CreatedChild != null)
                throw new InvalidOperationException("Original unused fixed operation required");
            return CreateChildCore(operation.Executable, operation.ImageHash, operation.Arguments, operation.Directory,
                persistInFlight, operation.BindingSha256, persistStopped, operation);
        }
    }
    public sealed class RecoveryObservation {
        public bool ActorGone { get; internal set; }
        public bool OwnerGone { get; internal set; }
        public bool RootsGone { get; internal set; }
        public bool JobFound { get; internal set; }
        public int ActiveMembers { get; internal set; }
        public string JobName { get; internal set; }
        public bool Idle { get { return ActorGone && OwnerGone && RootsGone && JobFound && ActiveMembers == 0; } }
    }
    static bool OriginalProcessGone(uint pid, long creationFileTime) {
        if (pid == 0 || creationFileTime <= 0) throw new ArgumentException("Measured original process identity required");
        IntPtr process = OpenProcess(0x00101000, false, pid); int error = Marshal.GetLastWin32Error();
        if (process == IntPtr.Zero) {
            if (error == 87) return true; // PID no longer allocated. Access denial is not exit.
            throw new Win32Exception(error);
        }
        try {
            FileTime creation, exit, kernel, user;
            Check(GetProcessTimes(process, out creation, out exit, out kernel, out user));
            long actual = unchecked((long)(((ulong)creation.High << 32) | creation.Low));
            if (actual != creationFileTime) return true; // PID reused; original identity is gone.
            uint state = WaitForSingleObject(process, 0);
            if (state == 0) return true;
            if (state == 258) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { CloseHandle(process); }
    }
    static long CreationTime(IntPtr process) {
        FileTime creation, exit, kernel, user;
        Check(GetProcessTimes(process, out creation, out exit, out kernel, out user));
        return unchecked((long)(((ulong)creation.High << 32) | creation.Low));
    }
    static uint[] MemberPids(IntPtr handle) {
        IntPtr buffer = Marshal.AllocHGlobal(4096);
        try {
            Check(QueryInformationJobObject(handle, 3, buffer, 4096, IntPtr.Zero));
            int assigned = Marshal.ReadInt32(buffer, 0), listed = Marshal.ReadInt32(buffer, 4);
            if (listed < 0 || assigned != listed || listed > (4096 - 8) / IntPtr.Size)
                throw new InvalidOperationException("Incomplete publication descendant observation");
            var pids = new uint[listed];
            for (int index = 0; index < listed; index++) {
                long pid = Marshal.ReadIntPtr(buffer, 8 + index * IntPtr.Size).ToInt64();
                if (pid <= 0 || pid > uint.MaxValue) throw new InvalidOperationException("Invalid publication member identity");
                pids[index] = (uint)pid;
            }
            if (pids.Distinct().Count() != pids.Length) throw new InvalidOperationException("Duplicate publication member identity");
            return pids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    static int Members(IntPtr handle) { return MemberPids(handle).Length; }
    static void JobIdentity(string name) {
        const string prefix = "Local\\winsmux-integrated-publication-";
        if (name == null || !name.StartsWith(prefix, StringComparison.Ordinal) || name.Length != prefix.Length + 32 ||
            name.Substring(prefix.Length).Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')))
            throw new ArgumentException("Exact original publication Job required");
    }
    static void Digest(string value) {
        if (value == null || value.Length != 64 || value.Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')))
            throw new ArgumentException("Exact observed SHA256 required");
    }
    // Only opens an existing Job with QUERY access. Never creates/replaces it,
    // assigns processes, changes limits, publishes or terminates a process.
    public sealed class QueryLease : IDisposable {
        internal IntPtr Handle;
        public string JobName { get; private set; }
        public QueryLease(string name) {
            JobIdentity(name); JobName = name;
            Handle = OpenJobObjectW(4, false, name);
            if (Handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { Members(Handle); } catch { CloseHandle(Handle); Handle = IntPtr.Zero; throw; }
        }
        public int ActiveMembers() {
            if (Handle == IntPtr.Zero) throw new InvalidOperationException("Released query lease");
            return Members(Handle);
        }
        public uint[] ActiveMemberPids() {
            if (Handle == IntPtr.Zero) throw new InvalidOperationException("Released query lease");
            return MemberPids(Handle);
        }
        public RecoveryObservation Observe(uint ownerPid, long ownerTime, uint[] pids, long[] times) {
            return Observe(ownerPid, ownerTime, ownerPid, ownerTime, pids, times);
        }
        public RecoveryObservation Observe(uint actorPid, long actorTime, uint ownerPid, long ownerTime, uint[] pids, long[] times) {
            if (pids == null || times == null || pids.Length != times.Length || pids.Distinct().Count() != pids.Length)
                throw new ArgumentException("Exact root identities required");
            return new RecoveryObservation { JobName = JobName, JobFound = true,
                ActorGone = OriginalProcessGone(actorPid, actorTime),
                OwnerGone = OriginalProcessGone(ownerPid, ownerTime),
                RootsGone = pids.Select((pid, i) => OriginalProcessGone(pid, times[i])).All(x => x), ActiveMembers = ActiveMembers() };
        }
        public void Dispose() { if (Handle != IntPtr.Zero) { Check(CloseHandle(Handle)); Handle = IntPtr.Zero; } }
    }
    static string ReadLine(StreamReader reader, int timeout) {
        var task = reader.ReadLineAsync();
        bool complete;
        try { complete = task.Wait(timeout); }
        catch (AggregateException) {
            // Surface the original transport failure so the keeper's refusal
            // boundary retains its lease after a disconnected claimant.
            task.GetAwaiter().GetResult(); throw;
        }
        if (!complete) throw new TimeoutException("Keeper observation incomplete");
        string line = task.GetAwaiter().GetResult();
        if (line == null || line.Length > 4096) throw new InvalidOperationException("Keeper response incomplete");
        return line;
    }
    static IntPtr DuplicatePeerJob(uint peerPid, long peerTime, long handleValue, IntPtr expectedJob) {
        IntPtr peer = OpenProcess(0x00101040, false, peerPid);
        if (peer == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr copy = IntPtr.Zero;
        try {
            if (CreationTime(peer) != peerTime || WaitForSingleObject(peer, 0) != 258)
                throw new InvalidOperationException("Keeper peer identity changed or exited");
            Check(DuplicateHandle(peer, new IntPtr(handleValue), GetCurrentProcess(), out copy, 4, false, 0));
            if (!CompareObjectHandles(copy, expectedJob)) throw new InvalidOperationException("Keeper holds another kernel object");
            Members(copy); return copy;
        } catch { if (copy != IntPtr.Zero) CloseHandle(copy); throw; }
        finally { CloseHandle(peer); }
    }
    static void ValidateKeeper(KeeperIdentity identity) {
        if (identity == null || identity.Pid == 0 || identity.CreationFileTime <= 0 || identity.OwnerPid == 0 || identity.OwnerCreationFileTime <= 0)
            throw new ArgumentException("Measured keeper identity required");
        JobIdentity(identity.JobName); Digest(identity.CandidateSha256); Digest(identity.ImplementationSha256); Digest(identity.ScriptSha256);
        if (!Guid.TryParseExact(identity.Attempt, "D", out _) || identity.PipeName != "winsmux-publication-keeper-" + identity.JobName.Substring(identity.JobName.Length - 32))
            throw new ArgumentException("Keeper attempt and pipe identity differ");
    }
    static string Exchange(KeeperIdentity identity, IntPtr actualJob, string command, int timeout) {
        ValidateKeeper(identity);
        if (timeout <= 0) throw new ArgumentException("Host observation timeout required");
        using (var pipe = new NamedPipeClientStream(".", identity.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly)) {
            pipe.Connect(timeout); uint server;
            Check(GetNamedPipeServerProcessId(pipe.SafePipeHandle, out server));
            if (server != identity.Pid || OriginalProcessGone(server, identity.CreationFileTime))
                throw new InvalidOperationException("Keeper pipe server identity differs");
            using (var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, true))
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true }) {
                string[] hello = ReadLine(reader, timeout).Split('|');
                if (hello.Length != 8 || hello[0] != "HOLD" || hello[1] != identity.JobName || hello[2] != identity.OwnerPid.ToString(CultureInfo.InvariantCulture) ||
                    hello[3] != identity.OwnerCreationFileTime.ToString(CultureInfo.InvariantCulture) || hello[4] != identity.Attempt || hello[5] != identity.CandidateSha256 ||
                    hello[6] != identity.ImplementationSha256 || hello[7] != identity.ScriptSha256)
                    throw new InvalidOperationException("Keeper binding differs");
                writer.WriteLine("QUERY");
                string[] held = ReadLine(reader, timeout).Split('|');
                if (held.Length != 2 || held[0] != "HANDLE" || !long.TryParse(held[1], NumberStyles.None, CultureInfo.InvariantCulture, out long value))
                    throw new InvalidOperationException("Keeper native handle missing");
                IntPtr copy = DuplicatePeerJob(server, identity.CreationFileTime, value, actualJob);
                try {
                    bool contained;
                    IntPtr process = OpenProcess(0x00101000, false, server);
                    if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                    try { Check(IsProcessInJob(process, actualJob, out contained)); } finally { CloseHandle(process); }
                    if (contained) throw new InvalidOperationException("Keeper belongs to publication Job");
                    writer.WriteLine(command); return ReadLine(reader, timeout);
                } finally { CloseHandle(copy); }
            }
        }
    }
    // Runs in a separate, hidden process, outside the publication Job. The
    // original owner may die and the Job may reach zero: neither releases this
    // lease. Only a native-verified normal release or continuous handoff does.
    public static void RunKeeper(string jobName, uint ownerPid, long ownerTime, string attempt, string candidate,
        string implementationHash, string scriptHash, int timeout) {
        var identity = new KeeperIdentity { Pid = (uint)Environment.ProcessId, CreationFileTime = CreationTime(GetCurrentProcess()),
            OwnerPid = ownerPid, OwnerCreationFileTime = ownerTime, JobName = jobName,
            PipeName = "winsmux-publication-keeper-" + jobName.Substring(jobName.Length - 32), Attempt = attempt,
            CandidateSha256 = candidate, ImplementationSha256 = implementationHash, ScriptSha256 = scriptHash };
        ValidateKeeper(identity);
        if (timeout <= 0 || OriginalProcessGone(ownerPid, ownerTime)) throw new InvalidOperationException("Keeper owner unavailable before ready");
        using (var lease = new QueryLease(jobName)) {
            bool contained; Check(IsProcessInJob(GetCurrentProcess(), lease.Handle, out contained));
            if (contained) throw new InvalidOperationException("Keeper belongs to publication Job");
            while (true) {
                using (var pipe = new NamedPipeServerStream(identity.PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly)) {
                    pipe.WaitForConnection();
                    // One refusal boundary owns the entire connected claim,
                    // including a client that disconnects before peer lookup,
                    // malformed reads, writes and stream disposal. None of
                    // those paths may unwind the retained Job lease.
                    try {
                        uint client; Check(GetNamedPipeClientProcessId(pipe.SafePipeHandle, out client));
                        using (var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, true))
                        using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true }) {
                            writer.WriteLine(String.Join("|", "HOLD", jobName, ownerPid.ToString(CultureInfo.InvariantCulture), ownerTime.ToString(CultureInfo.InvariantCulture),
                                attempt, candidate, implementationHash, scriptHash));
                            if (ReadLine(reader, timeout) != "QUERY") { writer.WriteLine("REFUSE"); continue; }
                            writer.WriteLine("HANDLE|" + lease.Handle.ToInt64().ToString(CultureInfo.InvariantCulture));
                            string[] command = ReadLine(reader, timeout).Split('|');
                            if (command.Length == 1 && command[0] == "OBSERVE") { lease.ActiveMembers(); writer.WriteLine("HELD"); continue; }
                            if (command.Length != 2 || (command[0] != "NORMAL" && command[0] != "HANDOFF") ||
                                !long.TryParse(command[1], NumberStyles.None, CultureInfo.InvariantCulture, out long value)) { writer.WriteLine("REFUSE"); continue; }
                            bool gone = OriginalProcessGone(ownerPid, ownerTime);
                            bool original = client == ownerPid && !OriginalProcessGone(client, ownerTime);
                            if ((command[0] == "NORMAL" && (!original || gone)) || (command[0] == "HANDOFF" && !gone) || lease.ActiveMembers() != 0) {
                                writer.WriteLine("REFUSE"); continue;
                            }
                            IntPtr peer = OpenProcess(0x00101000, false, client);
                            if (peer == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                            long peerTime; try { peerTime = CreationTime(peer); } finally { CloseHandle(peer); }
                            IntPtr transferred = DuplicatePeerJob(client, peerTime, value, lease.Handle);
                            try { if (Members(transferred) != 0) { writer.WriteLine("REFUSE"); continue; } writer.WriteLine("TRANSFERRED"); return; }
                            finally { CloseHandle(transferred); }
                        }
                    } catch (Exception error) when (error is IOException || error is TimeoutException || error is InvalidOperationException || error is Win32Exception || error is ArgumentException) {
                        // A disconnected/invalid claimant never releases the retained Job.
                    }
                }
            }
        }
    }
    FileStream HoldKeeperInput(string file, string hash) {
        Digest(hash); file = Path.GetFullPath(file);
        if (file.StartsWith("\\\\", StringComparison.Ordinal)) throw new ArgumentException("Local fixed keeper input required");
        HoldAncestors(Path.GetDirectoryName(file)); Plain(file, false);
        var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        try { Identity(stream.SafeFileHandle, true); if (Hash(stream) != hash) throw new InvalidOperationException("Keeper input hash differs"); }
        catch { stream.Dispose(); throw; }
        keeperInputs.Add(stream); return stream;
    }
    public int FixRuntimeSources(string manifest, string manifestHash, string guardFile, string guardHash) {
        lock (gate) {
            if (released || sealedLaunches || authority != null || keeper != null || children.Count != 0 || sourceManifest != null)
                throw new InvalidOperationException("Runtime source setup must precede actor and keeper");
            VerifyUnsafe();
            manifest = Path.GetFullPath(manifest); guardFile = Path.GetFullPath(guardFile);
            var input = HoldKeeperInput(manifest, manifestHash); HoldKeeperInput(guardFile, guardHash); input.Position = 0;
            // A JSON inventory pins bytes; it never confers parent authority.
            using (var document = JsonDocument.Parse(input)) {
                var value = document.RootElement; JsonKeys(value, "files", "directories", "publication_admitted"); FalseFlag(value, "publication_admitted");
                var dirs = value.GetProperty("directories"); var rows = value.GetProperty("files");
                if (dirs.ValueKind != JsonValueKind.Array || rows.ValueKind != JsonValueKind.Array || dirs.GetArrayLength() == 0 || rows.GetArrayLength() == 0)
                    throw new InvalidOperationException("Nonempty runtime source inventory required");
                var fixedDirs = new Dictionary<string, string[]>(StringComparer.Ordinal);
                foreach (var directory in dirs.EnumerateArray()) {
                    JsonKeys(directory, "path", "names", "identity"); string target = JsonText(directory, "path");
                    if (!Path.IsPathFullyQualified(target) || target != Path.GetFullPath(target) || target.StartsWith("\\\\", StringComparison.Ordinal))
                        throw new InvalidOperationException("Exact local source directory required");
                    var names = directory.GetProperty("names");
                    if (names.ValueKind != JsonValueKind.Array || names.EnumerateArray().Any(x => x.ValueKind != JsonValueKind.String)) throw new InvalidOperationException("Fixed source namespace missing");
                    string[] closed = names.EnumerateArray().Select(x => x.GetString()).ToArray();
                    if (closed.Any(x => String.IsNullOrEmpty(x) || x == "." || x == ".." || x != Path.GetFileName(x)) || closed.Distinct(StringComparer.OrdinalIgnoreCase).Count() != closed.Length ||
                        !closed.SequenceEqual(closed.OrderBy(x => x, StringComparer.Ordinal)) || !fixedDirs.TryAdd(target, closed))
                        throw new InvalidOperationException("Malformed or duplicate source namespace");
                    HoldAncestors(target);
                }
                var fixedFiles = new Dictionary<string, FileStream>(StringComparer.Ordinal);
                var fixedHashes = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var row in rows.EnumerateArray()) {
                    JsonKeys(row, "path", "bytes", "sha256", "identity"); string target = JsonText(row, "path"), hash = JsonText(row, "sha256");
                    if (!Path.IsPathFullyQualified(target) || target != Path.GetFullPath(target) || !fixedDirs.ContainsKey(Path.GetDirectoryName(target)) || fixedFiles.ContainsKey(target))
                        throw new InvalidOperationException("Malformed or duplicate source path");
                    var held = HoldKeeperInput(target, hash);
                    if (!row.GetProperty("bytes").TryGetInt64(out long bytes) || bytes != held.Length) throw new InvalidOperationException("Source size differs");
                    fixedFiles.Add(target, held); fixedHashes.Add(target, hash);
                }
                foreach (var directory in fixedDirs) {
                    if (!Directory.GetFileSystemEntries(directory.Key).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).SequenceEqual(directory.Value))
                        throw new InvalidOperationException("Runtime namespace differs");
                }
                foreach (var entry in fixedDirs) sourceDirectories.Add(entry.Key, entry.Value);
                foreach (var entry in fixedFiles) sourceFiles.Add(entry.Key, entry.Value);
                foreach (var entry in fixedHashes) sourceHashes.Add(entry.Key, entry.Value);
                sourceManifest = manifest; sourceManifestHash = manifestHash; sourceGuard = guardFile;
                VerifyUnsafe(); return sourceFiles.Count;
            }
        }
    }
    // Freeze only non-secret execution configuration before the authority actor
    // starts. A provider credential is supplied later for one original operation.
    public PublicationRuntimeProfile PreparePublicationRuntime() {
        lock (gate) {
            if (released || authority != null || keeper != null || children.Count != 0 || sourceManifest == null || publicationRuntime != null)
                throw new InvalidOperationException("Publication runtime preparation closed or sources missing");
            VerifyUnsafe(); string temporary = RuntimeTemp();
            string user = Path.Combine(temporary, "publication-user.npmrc"), global = Path.Combine(temporary, "publication-global.npmrc");
            byte[] userBytes = Encoding.UTF8.GetBytes("//registry.npmjs.org/:_authToken=${WINSMUX_NPM_TOKEN}\n"), empty = Array.Empty<byte>();
            foreach (var item in new[] { Tuple.Create(user, userBytes), Tuple.Create(global, empty) }) {
                using (var file = new FileStream(item.Item1, FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { file.Write(item.Item2); file.Flush(true); }
                HoldKeeperInput(item.Item1, Convert.ToHexString(SHA256.HashData(item.Item2)).ToLowerInvariant());
            }
            publicationRuntime = new PublicationRuntimeProfile { SourceManifest = sourceManifest, SourceManifestSha256 = sourceManifestHash,
                GuardFile = sourceGuard, GuardSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(sourceGuard))).ToLowerInvariant(),
                TemporaryDirectory = temporary, UserConfig = user, GlobalConfig = global, NpmCache = Path.Combine(temporary, "npm-cache") };
            VerifyUnsafe(); return publicationRuntime;
        }
    }
    // Pin the exact npm interpreter source before keeper/child creation. It is
    // released by the same Job-idle Dispose path as the candidate and images.
    // This adds no launch authority or npm dependency-closure claim.
    public void HoldNpmCli(string file, string hash) {
        lock (gate) {
            if (released || sealedLaunches || keeper != null || children.Count != 0 || npmCliInput != null)
                throw new InvalidOperationException("npm source custody already fixed or launch started");
            if (!String.Equals(Path.GetFileName(file), "npm-cli.js", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Exact npm-cli.js source required");
            VerifyUnsafe();
            npmCliInput = HoldKeeperInput(file, hash);
            VerifyUnsafe();
        }
    }
    void EnsureJob() {
        if (job != IntPtr.Zero) return;
        jobName = "Local\\winsmux-integrated-publication-" + Guid.NewGuid().ToString("N");
        job = CreateJobObjectW(IntPtr.Zero, jobName); int error = Marshal.GetLastWin32Error();
        if (job == IntPtr.Zero) throw new Win32Exception(error);
        if (error == 183) { CloseHandle(job); job = IntPtr.Zero; throw new InvalidOperationException("Publication job collision"); }
    }
    public void StartKeeper(string executable, string executableHash, string script, string scriptHash, string implementation, string implementationHash,
        string attempt, string candidateHash, int timeout, Action<KeeperIdentity> persistKeeper) {
        lock (gate) {
            RequireAuthorityLive();
            if (released || sealedLaunches || keeper != null || children.Count != 0 || persistKeeper == null) throw new InvalidOperationException("Keeper startup closed or persistence missing");
            if (!Guid.TryParseExact(attempt, "D", out _) || timeout <= 0) throw new ArgumentException("Fixed attempt and host observation timeout required");
            Digest(candidateHash); VerifyUnsafe();
            HoldKeeperInput(executable, executableHash); HoldKeeperInput(script, scriptHash); HoldKeeperInput(implementation, implementationHash);
            EnsureJob(); observationTimeout = timeout;
            string[] arguments = new[] { "-NoLogo", "-NoProfile", "-File", Path.GetFullPath(script), "-Implementation", Path.GetFullPath(implementation),
                "-ImplementationHash", implementationHash, "-ScriptHash", scriptHash, "-JobName", jobName,
                "-OwnerPid", Environment.ProcessId.ToString(CultureInfo.InvariantCulture), "-OwnerCreationTime", CreationTime(GetCurrentProcess()).ToString(CultureInfo.InvariantCulture),
                "-Attempt", attempt, "-CandidateHash", candidateHash, "-ObservationTimeout", timeout.ToString(CultureInfo.InvariantCulture) };
            string command = QuoteArgument(Path.GetFullPath(executable)) + " " + String.Join(" ", arguments.Select(QuoteArgument));
            if (command.Length >= 32767) throw new ArgumentException("Keeper command too long");
            var startup = new StartupEx(); startup.Startup.Size = (uint)Marshal.SizeOf(typeof(Startup));
            ProcessInformation process; string environmentHash; KeeperNativeCreateCalls++;
            // A keeper is not a publication Job member. Its measured identity
            // is persisted while suspended, before it can retain any Job.
            using (var environment = IntegratedPublicationEnvironment.Create("keeper", RuntimeTemp(), Path.GetFullPath(executable), null, null)) {
                environmentHash = environment.Sha256;
                Check(CreateProcessW(Path.GetFullPath(executable), new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                    0x08000004u | IntegratedPublicationEnvironment.UnicodeFlag, environment.Block, Path.GetDirectoryName(Path.GetFullPath(script)), ref startup, out process));
            }
            keeperNativeProcess = process.Process; keeperNativeThread = process.Thread;
            keeper = new KeeperIdentity { Pid = process.Pid, CreationFileTime = CreationTime(process.Process),
                OwnerPid = (uint)Environment.ProcessId, OwnerCreationFileTime = CreationTime(GetCurrentProcess()), JobName = jobName,
                PipeName = "winsmux-publication-keeper-" + jobName.Substring(jobName.Length - 32), Attempt = attempt, CandidateSha256 = candidateHash,
                ImplementationSha256 = implementationHash, ScriptSha256 = scriptHash, EnvironmentSha256 = environmentHash };
            ResumeKeeper(persistKeeper);
        }
    }
    // Retry only persistence/resume of this exact suspended keeper. Never
    // replace it or spawn another keeper when the original write failed.
    public void ResumeKeeper(Action<KeeperIdentity> persistKeeper) {
        lock (gate) {
            RequireAuthorityLive();
            if (released || sealedLaunches || keeper == null || keeperResumed || persistKeeper == null)
                throw new InvalidOperationException("Keeper resume closed or persistence missing");
            VerifyUnsafe(); persistKeeper(keeper); VerifyUnsafe();
            if (CreationTime(keeperNativeProcess) != keeper.CreationFileTime || WaitForSingleObject(keeperNativeProcess, 0) != 258)
                throw new InvalidOperationException("Suspended keeper identity changed or exited");
            RequireAuthorityLive();
            uint previous = ResumeThread(keeperNativeThread);
            if (previous == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (previous != 1) throw new InvalidOperationException("Unexpected keeper suspend count");
            keeperResumed = true;
            keeperProcess = Process.GetProcessById((int)keeper.Pid); _ = keeperProcess.SafeHandle;
            RequireKeeper();
        }
    }
    void RequireKeeper() {
        if (keeper == null || Exchange(keeper, job, "OBSERVE", observationTimeout) != "HELD")
            throw new InvalidOperationException("Keeper native ready missing");
    }
    public static void HandoffKeeper(KeeperIdentity identity, QueryLease successorLease, uint[] rootPids, long[] rootTimes, int timeout) {
        ValidateKeeper(identity);
        if (successorLease == null || successorLease.JobName != identity.JobName ||
            !successorLease.Observe(identity.OwnerPid, identity.OwnerCreationFileTime, rootPids, rootTimes).Idle)
            throw new InvalidOperationException("Keeper recovery is not idle");
        IntPtr process = OpenProcess(0x00101000, false, identity.Pid);
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            if (CreationTime(process) != identity.CreationFileTime) throw new InvalidOperationException("Keeper identity changed");
            if (Exchange(identity, successorLease.Handle, "HANDOFF|" + successorLease.Handle.ToInt64().ToString(CultureInfo.InvariantCulture), timeout) != "TRANSFERRED")
                throw new InvalidOperationException("Keeper native handoff refused");
            uint code;
            if (WaitForSingleObject(process, checked((uint)timeout)) != 0 || !GetExitCodeProcess(process, out code) || code != 0)
                throw new InvalidOperationException("Keeper normal exit unproven");
        } finally { CloseHandle(process); }
        successorLease.ActiveMembers(); // Successor still holds the same Job after keeper exit.
    }
    public static void HandoffKeeperAfterActorExit(KeeperIdentity identity, QueryLease successorLease, uint actorPid, long actorTime,
        uint[] rootPids, long[] rootTimes, int timeout) {
        if (successorLease == null || !successorLease.Observe(actorPid, actorTime, identity.OwnerPid, identity.OwnerCreationFileTime, rootPids, rootTimes).Idle)
            throw new InvalidOperationException("Original authority actor, owner and descendants are not proven idle");
        HandoffKeeper(identity, successorLease, rootPids, rootTimes, timeout);
    }
    // Recorded identity is a locator, never a ready/exit verdict. Every use
    // must query the actual process, pipe peer and same underlying Job HANDLE.
    public static KeeperIdentity LocateKeeper(uint pid, long time, uint ownerPid, long ownerTime, string jobName,
        string attempt, string candidate, string implementationHash, string scriptHash) {
        var identity = new KeeperIdentity { Pid = pid, CreationFileTime = time, OwnerPid = ownerPid, OwnerCreationFileTime = ownerTime,
            JobName = jobName, PipeName = "winsmux-publication-keeper-" + jobName.Substring(jobName.Length - 32),
            Attempt = attempt, CandidateSha256 = candidate, ImplementationSha256 = implementationHash, ScriptSha256 = scriptHash };
        ValidateKeeper(identity); return identity;
    }
    public static void ObserveKeeper(KeeperIdentity identity, QueryLease lease, int timeout) {
        if (lease == null || lease.JobName != identity.JobName || Exchange(identity, lease.Handle, "OBSERVE", timeout) != "HELD")
            throw new InvalidOperationException("Keeper native ready missing");
    }
    // Read-only recovery observation. A file's owner_gone/pass fields cannot
    // replace these native observations, which confer no publication authority.
    public static RecoveryObservation ObserveRecovery(uint ownerPid, long ownerCreationFileTime, string priorJobName, uint[] rootPids, long[] rootCreationTimes) {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Native recovery observation requires Windows");
        const string prefix = "Local\\winsmux-integrated-publication-";
        if (priorJobName == null || !priorJobName.StartsWith(prefix, StringComparison.Ordinal) ||
            priorJobName.Length != prefix.Length + 32 || priorJobName.Substring(prefix.Length).Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f')) ||
            rootPids == null || rootCreationTimes == null || rootPids.Length != rootCreationTimes.Length ||
            rootPids.Distinct().Count() != rootPids.Length)
            throw new ArgumentException("Exact original publication job and root identities required");
        bool ownerGone = OriginalProcessGone(ownerPid, ownerCreationFileTime);
        var observation = new RecoveryObservation { JobName = priorJobName, ActorGone = ownerGone, OwnerGone = ownerGone, RootsGone = true };
        for (int i = 0; i < rootPids.Length; i++)
            if (!OriginalProcessGone(rootPids[i], rootCreationTimes[i])) observation.RootsGone = false;
        IntPtr priorJob = OpenJobObjectW(4, false, priorJobName); int error = Marshal.GetLastWin32Error();
        if (priorJob == IntPtr.Zero) {
            if (error != 2) throw new Win32Exception(error);
            // On real Windows, the Job name can disappear after its final user
            // handle closes while associated descendants still survive. Missing
            // Job is UNKNOWN, even when the original owner/roots have exited.
            return observation;
        }
        observation.JobFound = true;
        try {
            observation.ActiveMembers = Members(priorJob); return observation;
        } finally { CloseHandle(priorJob); }
    }
    static void Check(bool value) { if (!value) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static void Plain(string target, bool directory) {
        uint attrs = GetFileAttributesW(target);
        if (attrs == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
        if ((attrs & 0x400) != 0 || ((attrs & 0x10) != 0) != directory)
            throw new InvalidOperationException("Linked or incorrectly typed custody path");
    }
    static string Identity(SafeFileHandle handle, bool file) {
        FileInformation info; Check(GetFileInformationByHandle(handle, out info));
        if ((info.Attributes & 0x400) != 0 || (file && info.Links != 1))
            throw new InvalidOperationException("Reparse or multiple-link custody object");
        return info.Volume.ToString("x8") + ":" + info.IndexHigh.ToString("x8") + info.IndexLow.ToString("x8");
    }
    string Target(string name) { return Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)); }
    static string Hash(FileStream stream) {
        stream.Position = 0;
        string result = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        stream.Position = 0;
        return result;
    }
    void HoldDirectory(string directory) {
        if (directoryPaths.Contains(directory)) return;
        Plain(directory, true);
        var handle = CreateFileW(directory, 0, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(error); }
        try { Identity(handle, false); } catch { handle.Dispose(); throw; }
        directories.Add(handle); directoryPaths.Add(directory);
    }
    void HoldAncestors(string directory) {
        var paths = new List<string>();
        for (string current = directory; current != null; current = Path.GetDirectoryName(current)) paths.Add(current);
        paths.Reverse(); foreach (string path in paths) HoldDirectory(path);
    }
    void ClosedInventory() {
        Plain(root, true);
        string[] children = Directory.GetDirectories(root).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).ToArray();
        if (!children.SequenceEqual(new[] { "core", "desktop", "npm" }))
            throw new InvalidOperationException("Unexpected custody directories");
        var actual = new List<string>();
        actual.AddRange(Directory.GetFiles(root).Select(Path.GetFileName));
        foreach (string directory in children) {
            string target = Target(directory); Plain(target, true);
            if (Directory.GetDirectories(target).Length != 0) throw new InvalidOperationException("Nested custody directory");
            actual.AddRange(Directory.GetFiles(target).Select(file => directory + "/" + Path.GetFileName(file)));
        }
        if (!actual.OrderBy(x => x, StringComparer.Ordinal).SequenceEqual(Names))
            throw new InvalidOperationException("Missing, differently cased or additional custody assets");
    }
    public IntegratedPublicationCustody(string bundleRoot, string[] names, string[] hashes) {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows custody required");
        root = Path.GetFullPath(bundleRoot);
        if (root.StartsWith("\\\\", StringComparison.Ordinal) || names == null || hashes == null ||
            !names.SequenceEqual(Names) || hashes.Length != Names.Length ||
            hashes.Any(hash => hash == null || hash.Length != 64 || hash.Any(c => !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f'))))
            throw new ArgumentException("Exact integrated asset paths and SHA256 required");
        try {
            // Retain ancestors too: held files must not acquire a different
            // pathname through a parent-directory rename during custody.
            HoldAncestors(root);
            foreach (string directory in new[] { Target("core"), Target("desktop"), Target("npm") }) HoldDirectory(directory);
            ClosedInventory();
            for (int index = 0; index < Names.Length; index++) {
                string name = Names[index], target = Target(name); Plain(target, false);
                var stream = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read);
                files.Add(name, stream); expected.Add(name, hashes[index]);
                identities.Add(name, Identity(stream.SafeFileHandle, true));
                if (Hash(stream) != hashes[index]) throw new InvalidOperationException("Custody asset hash differs");
            }
            Verify();
        } catch { Dispose(); throw; }
    }
    string RuntimeTemp() {
        if (runtimeTemp != null) return runtimeTemp;
        // Attempt-owned scratch is beside the immutable fixed-asset bundle.
        // Never reuse a global/user temp or put mutable output in the source tree.
        string target = root + ".runtime-" + Guid.NewGuid().ToString("N");
        if (Directory.Exists(target) || File.Exists(target)) throw new InvalidOperationException("Runtime temp already exists");
        Directory.CreateDirectory(target); HoldAncestors(target); runtimeTemp = target; return target;
    }
    void VerifyUnsafe() {
        if (released) throw new InvalidOperationException("Custody has been released");
        ClosedInventory();
        foreach (var directory in sourceDirectories) {
            Plain(directory.Key, true);
            if (!Directory.GetFileSystemEntries(directory.Key).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).SequenceEqual(directory.Value))
                throw new InvalidOperationException("Held runtime source namespace changed");
        }
        foreach (var source in sourceFiles) {
            if (Hash(source.Value) != sourceHashes[source.Key]) throw new InvalidOperationException("Held runtime source bytes changed");
            using (var named = new FileStream(source.Key, FileMode.Open, FileAccess.Read, FileShare.Read))
                if (Identity(named.SafeFileHandle, true) != Identity(source.Value.SafeFileHandle, true)) throw new InvalidOperationException("Named source differs from held input");
        }
        foreach (string name in Names) {
            FileStream stream = files[name];
            if (Identity(stream.SafeFileHandle, true) != identities[name] || Hash(stream) != expected[name])
                throw new InvalidOperationException("Held custody identity or bytes changed");
            using (var named = new FileStream(Target(name), FileMode.Open, FileAccess.Read, FileShare.Read))
                if (Identity(named.SafeFileHandle, true) != identities[name])
                    throw new InvalidOperationException("Named asset differs from held file");
        }
    }
    public void Verify() { lock (gate) { VerifyUnsafe(); } }
    static string QuoteArgument(string argument) {
        if (argument == null || argument.IndexOf('\0') >= 0) throw new ArgumentException("Invalid child argument");
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char character in argument) {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(character); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    void RequireChild(Child child) {
        if (released || child == null || !Object.ReferenceEquals(child.Owner, this) || !children.Contains(child))
            throw new InvalidOperationException("Foreign or released custody child");
    }
    // Both callbacks are trusted parent-host operations. They must durably write
    // and read back the in-flight barrier and actual child identity, respectively.
    // Input JSON or a successful callback does not establish public authority.
    public Child CreateChild(string executable, string imageHash, string[] arguments, string directory, Action<string> persistInFlight) {
        return CreateChild(executable, imageHash, arguments, directory, persistInFlight, null, null);
    }
    public Child CreateChild(string executable, string imageHash, string[] arguments, string directory, Action<string> persistInFlight, string operationBinding) {
        return CreateChild(executable, imageHash, arguments, directory, persistInFlight, operationBinding, null);
    }
    public Child CreateChild(string executable, string imageHash, string[] arguments, string directory, Action<string> persistInFlight, string operationBinding,
        Action<uint, long, string> persistStopped) {
        return CreateChildCore(executable, imageHash, arguments, directory, persistInFlight, operationBinding, persistStopped, null);
    }
    Child CreateChildCore(string executable, string imageHash, string[] arguments, string directory, Action<string> persistInFlight, string operationBinding,
        Action<uint, long, string> persistStopped, PublicationOperation operation) {
        lock (gate) {
            RequireAuthorityLive();
            // Auth, transitive source custody, runtime binding and output
            // receipt are one unfinished admission contract. An observed table
            // must not reach a real public root before that contract is connected.
            if (operation != null) throw new InvalidOperationException("Public runtime source, authentication and output binding incomplete");
            if (fixedOperations != null && operation == null) throw new InvalidOperationException("Arbitrary native argv is closed after fixed table binding");
            if (authority != null && persistStopped == null) throw new InvalidOperationException("Native stopped-child persistence missing");
            if (released || sealedLaunches || persistInFlight == null) throw new InvalidOperationException("Child launch closed or parent persistence missing");
            VerifyUnsafe();
            executable = Path.GetFullPath(executable); directory = Path.GetFullPath(directory);
            if (executable.StartsWith("\\\\", StringComparison.Ordinal) || directory.StartsWith("\\\\", StringComparison.Ordinal) || arguments == null) throw new ArgumentException("Local exact image and arguments required");
            bool guardedNode = sourceManifest != null && Path.GetFileName(executable) == "node.exe";
            if (guardedNode) {
                if (arguments.Length == 0 || !Path.IsPathFullyQualified(arguments[0]) || !sourceFiles.ContainsKey(Path.GetFullPath(arguments[0])))
                    throw new InvalidOperationException("Node child entry is outside held runtime source inventory");
                arguments = arguments.ToArray(); arguments[0] = Path.GetFullPath(arguments[0]);
                arguments = new[] { "--no-addons", "--import", new Uri(sourceGuard).AbsoluteUri }.Concat(arguments).ToArray();
            }
            HoldAncestors(Path.GetDirectoryName(executable)); HoldAncestors(directory);
            Plain(executable, false); Plain(directory, true);
            string command = QuoteArgument(executable) + " " + String.Join(" ", arguments.Select(QuoteArgument));
            if (command.Length >= 32767) throw new ArgumentException("Child command too long");
            var image = new FileStream(executable, FileMode.Open, FileAccess.Read, FileShare.Read);
            bool retained = false;
            try {
                Identity(image.SafeFileHandle, true);
                if (Hash(image) != imageHash) throw new InvalidOperationException("Child image hash differs");
                RequireKeeper(); // Native same-object HOLD, before the first publication child.
                persistInFlight(jobName); // Before every possible native creation.
                VerifyUnsafe();
                RequireKeeper();
                UIntPtr size = UIntPtr.Zero; IntPtr list = IntPtr.Zero, jobs = IntPtr.Zero, handles = IntPtr.Zero; bool initialized = false;
                ChildOutput output = null;
                try {
                    output = new ChildOutput();
                    InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
                    list = Marshal.AllocHGlobal(checked((int)size.ToUInt64()));
                    Check(InitializeProcThreadAttributeList(list, 2, 0, ref size)); initialized = true;
                    jobs = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs, job);
                    Check(UpdateProcThreadAttribute(list, 0, new UIntPtr(0x0002000D), jobs, new UIntPtr((uint)IntPtr.Size), IntPtr.Zero, IntPtr.Zero));
                    handles = Marshal.AllocHGlobal(IntPtr.Size * 3); Marshal.WriteIntPtr(handles, 0, output.Input);
                    Marshal.WriteIntPtr(handles, IntPtr.Size, output.OutWrite); Marshal.WriteIntPtr(handles, IntPtr.Size * 2, output.ErrorWrite);
                    Check(UpdateProcThreadAttribute(list, 0, new UIntPtr(0x00020002), handles, new UIntPtr((uint)(IntPtr.Size * 3)), IntPtr.Zero, IntPtr.Zero));
                    var startup = new StartupEx(); startup.Startup.Size = (uint)Marshal.SizeOf(typeof(StartupEx)); startup.Attributes = list;
                    startup.Startup.Flags = 0x100; startup.Startup.Input = output.Input; startup.Startup.Output = output.OutWrite; startup.Startup.Error = output.ErrorWrite;
                    if (authority != null) authority.RequireDecision("create", operationBinding, operation == null ? null : operation.Id);
                    RequireAuthorityLive();
                    ProcessInformation process; string environmentHash; NativeCreateCalls++;
                    using (var environment = IntegratedPublicationEnvironment.Create(guardedNode ? "npm" : "fixture", RuntimeTemp(), executable,
                        guardedNode ? sourceManifest : null, guardedNode ? sourceManifestHash : null)) {
                        environmentHash = environment.Sha256;
                        Check(CreateProcessW(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true,
                            0x08080004u | IntegratedPublicationEnvironment.UnicodeFlag, environment.Block, directory, ref startup, out process));
                    }
                    var child = new Child(this, process, image); children.Add(child); retained = true;
                    child.EnvironmentSha256 = environmentHash;
                    child.Output = output; output.Created();
                    child.Operation = operation;
                    if (operation != null) operation.CreatedChild = child;
                    child.OperationBinding = operationBinding;
                    bool contained; Check(IsProcessInJob(child.Process, job, out contained));
                    if (!contained) throw new InvalidOperationException("Atomic publication job membership missing");
                    FileTime creation, exit, kernel, user;
                    Check(GetProcessTimes(child.Process, out creation, out exit, out kernel, out user));
                    child.CreationFileTime = unchecked((long)(((ulong)creation.High << 32) | creation.Low));
                    if (persistStopped != null) persistStopped(child.Pid, child.CreationFileTime, jobName);
                    return child;
                } finally {
                    if (initialized) DeleteProcThreadAttributeList(list);
                    if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
                    if (jobs != IntPtr.Zero) Marshal.FreeHGlobal(jobs);
                    if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                    if (!retained && output != null) output.Dispose();
                }
            } finally { if (!retained) image.Dispose(); }
        }
    }
    public Child[] ObserveCreatedChildren() {
        lock (gate) {
            if (released) throw new InvalidOperationException("Released custody children");
            return children.ToArray(); // Same held native objects, not reconstructed PID flags.
        }
    }
    public void ResumeChild(Child child, Action<uint, long, string> persistCreated) {
        lock (gate) {
            RequireAuthorityLive();
            RequireChild(child);
            if (sealedLaunches || child.Resumed || persistCreated == null) throw new InvalidOperationException("Resume closed or persistence missing");
            RequireKeeper(); VerifyUnsafe(); persistCreated(child.Pid, child.CreationFileTime, jobName); VerifyUnsafe(); RequireKeeper();
            if (authority != null) authority.RequireDecision("resume", child.OperationBinding, child.Operation == null ? null : child.Operation.Id);
            RequireAuthorityLive();
            uint previous = ResumeThread(child.Thread);
            if (previous == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (previous != 1) throw new InvalidOperationException("Unexpected publication suspend count");
            child.Resumed = true;
        }
    }
    public bool HasExited(Child child) {
        lock (gate) {
            RequireChild(child); uint result = WaitForSingleObject(child.Process, 0);
            if (result == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (result != 0 && result != 258) throw new InvalidOperationException("Unknown child wait result");
            return result == 0;
        }
    }
    public uint ExitCode(Child child) {
        lock (gate) {
            RequireChild(child);
            if (!child.Resumed || !HasExited(child)) throw new InvalidOperationException("Publication root exit unproven");
            uint code; Check(GetExitCodeProcess(child.Process, out code)); return code;
        }
    }
    public bool OutputComplete(Child child) { lock (gate) { RequireChild(child); return child.Output != null && child.Output.Complete; } }
    public ChildOutputObservation ObserveChildOutput(Child child) {
        lock (gate) {
            RequireChild(child);
            if (!child.Resumed || !HasExited(child) || !OutputComplete(child)) throw new InvalidOperationException("Original root exit or output capture incomplete");
            return new ChildOutputObservation { Pid = child.Pid, CreationFileTime = child.CreationFileTime, ExitCode = ExitCode(child),
                EnvironmentSha256 = child.EnvironmentSha256, OperationBindingSha256 = child.OperationBinding,
                Stdout = child.Output.OutResult, Stderr = child.Output.ErrorResult };
        }
    }
    public int ActiveMembers() {
        lock (gate) {
            if (released) throw new InvalidOperationException("Released publication job");
            if (job == IntPtr.Zero) return 0;
            return Members(job);
        }
    }
    public uint[] ActiveMemberPids() {
        lock (gate) {
            if (released) throw new InvalidOperationException("Released publication job");
            return job == IntPtr.Zero ? Array.Empty<uint>() : MemberPids(job);
        }
    }
    public void SealLaunches() {
        lock (gate) {
            if (released || children.Any(child => !child.Resumed)) throw new InvalidOperationException("Released custody or pending suspended child");
            sealedLaunches = true;
        }
    }
    public void Dispose() {
        lock (gate) {
        if (released) return;
        RequireAuthorityLive(); // Never send NORMAL after actor EOF/death, even at Job0.
        if (keeper != null && !keeperResumed && !OriginalProcessGone(keeper.Pid, keeper.CreationFileTime))
            throw new InvalidOperationException("Keep custody until suspended keeper persistence is recovered");
        if (children.Count != 0 && (!sealedLaunches || children.Any(child => !child.Resumed || !HasExited(child)) || ActiveMembers() != 0))
            throw new InvalidOperationException("Keep custody until launches sealed and every root and descendant exits");
        if (children.Any(child => !OutputComplete(child))) throw new InvalidOperationException("Original output capture incomplete; retain custody");
        if (children.Any(child => !child.Output.OutResult.Complete || !child.Output.ErrorResult.Complete))
            throw new InvalidOperationException("Original output capture failed; retain custody");
        if (keeper != null && !OriginalProcessGone(keeper.Pid, keeper.CreationFileTime)) {
            sealedLaunches = true;
            RequireAuthorityLive();
            if (ActiveMembers() != 0 || Exchange(keeper, job, "NORMAL|" + job.ToInt64().ToString(CultureInfo.InvariantCulture), observationTimeout) != "TRANSFERRED" ||
                !keeperProcess.WaitForExit(observationTimeout) || keeperProcess.ExitCode != 0)
                throw new InvalidOperationException("Keeper normal release unproven");
        } else if (children.Count != 0 && keeper != null) {
            throw new InvalidOperationException("Keeper missing; retain unknown publication attempt");
        }
        if (keeperProcess != null) { keeperProcess.Dispose(); keeperProcess = null; }
        if (keeperNativeThread != IntPtr.Zero) { Check(CloseHandle(keeperNativeThread)); keeperNativeThread = IntPtr.Zero; }
        if (keeperNativeProcess != IntPtr.Zero) { Check(CloseHandle(keeperNativeProcess)); keeperNativeProcess = IntPtr.Zero; }
        foreach (Child child in children) { child.Output.Dispose(); child.Image.Dispose(); CloseHandle(child.Thread); CloseHandle(child.Process); }
        children.Clear();
        if (job != IntPtr.Zero) { Check(CloseHandle(job)); job = IntPtr.Zero; }
        foreach (FileStream stream in files.Values) stream.Dispose();
        files.Clear();
        foreach (FileStream stream in keeperInputs) stream.Dispose();
        keeperInputs.Clear();
        foreach (SafeFileHandle handle in directories) handle.Dispose();
        directories.Clear(); directoryPaths.Clear(); released = true;
        if (authority != null) authority.ReleaseAfterNormalCustody();
        }
    }
}

// Mechanical explicit Unicode environment. Installed Windows/vendor runtime
// components remain the trust boundary. No inherited configuration or auth is
// copied, and this object cannot admit a public operation.
public sealed class IntegratedPublicationEnvironment : IDisposable {
    readonly string[] entries;
    IntPtr block;
    int blockBytes;
    public IntPtr Block { get { if (block == IntPtr.Zero) throw new ObjectDisposedException("Environment"); return block; } }
    public string Sha256 { get; private set; }
    public string Role { get; private set; }
    public string AuthenticationVariable { get; private set; }
    public bool PublicationAdmitted { get { return false; } }
    public string[] Entries { get { return entries.ToArray(); } }
    public const uint UnicodeFlag = 0x00000400;
    static void LocalPlain(string value, bool directory) {
        if (String.IsNullOrEmpty(value) || value.IndexOf('\0') >= 0 || !Path.IsPathFullyQualified(value) || value.StartsWith("\\\\", StringComparison.Ordinal))
            throw new ArgumentException("Exact local runtime path required");
        if (directory ? !Directory.Exists(value) : !File.Exists(value)) throw new ArgumentException("Runtime input does not exist");
        for (string current=Path.GetFullPath(value);current!=null;current=Path.GetDirectoryName(current))
            if ((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0) throw new ArgumentException("Runtime reparse path refused");
    }
    // Testable canonicalization of an explicit list, not an environment import.
    // The host factory below is the only production source of that list.
    public static string Canonicalize(string[] supplied) {
        if (supplied==null || supplied.Length==0) throw new ArgumentException("Explicit environment required");
        var selected=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (string entry in supplied) {
            int split=entry==null ? -1 : entry.IndexOf('=');
            if (split<=0 || entry.IndexOf('\0')>=0) throw new ArgumentException("Malformed environment entry");
            string name=entry.Substring(0,split),value=entry.Substring(split+1);
            if (name.Any(c=>!(c>='A'&&c<='Z'||c>='a'&&c<='z'||c>='0'&&c<='9'||c=='_')) || !selected.TryAdd(name.ToUpperInvariant(),value))
                throw new ArgumentException("Invalid or case-duplicate environment name");
        }
        return String.Join("\0",selected.Select(pair=>pair.Key+"="+pair.Value))+"\0\0";
    }
    IntegratedPublicationEnvironment(string role,string[] supplied,string authenticationName=null,string authenticationValue=null) {
        Role=role;string canonical=Canonicalize(supplied);entries=canonical.Split('\0',StringSplitOptions.RemoveEmptyEntries);
        Sha256=Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(canonical))).ToLowerInvariant();
        if (authenticationName!=null) {
            if (String.IsNullOrEmpty(authenticationValue) || authenticationValue.Any(c=>c<' '||c>126)) throw new ArgumentException("One scoped printable authentication value required");
            AuthenticationVariable=authenticationName;
            canonical=Canonicalize(supplied.Concat(new[]{authenticationName+"="+authenticationValue}).ToArray());
        }
        byte[] bytes=Encoding.Unicode.GetBytes(canonical);blockBytes=bytes.Length;
        try {block=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,block,bytes.Length);}
        finally {Array.Clear(bytes,0,bytes.Length);}
    }
    public static IntegratedPublicationEnvironment Create(string role,string privateTemp,string executable,string manifest,string manifestHash) {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows environment required");
        if (role!="authority" && role!="keeper" && role!="github" && role!="npm" && role!="fixture") throw new ArgumentException("Unknown runtime role");
        LocalPlain(privateTemp,true);LocalPlain(executable,false);
        string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);LocalPlain(windows,true);
        string system=Path.Combine(windows,"System32"),imageDirectory=Path.GetDirectoryName(Path.GetFullPath(executable));LocalPlain(system,true);
        var values=new List<string>{"SYSTEMROOT="+windows,"WINDIR="+windows,"COMSPEC="+Path.Combine(system,"cmd.exe"),
            "PATH="+system,"TEMP="+Path.GetFullPath(privateTemp),"TMP="+Path.GetFullPath(privateTemp)};
        if (role=="authority" || role=="npm") {
            if (Path.GetFileName(executable)!="node.exe") throw new ArgumentException("Fixed Node image required");
            LocalPlain(manifest,false);
            if (manifestHash==null || manifestHash.Length!=64 || manifestHash.Any(c=>!(c>='0'&&c<='9'||c>='a'&&c<='f')))
                throw new ArgumentException("Fixed source manifest hash required");
            values.Add("NODE_DISABLE_COMPILE_CACHE=1");
            values.Add("WINSMUX_PUBLICATION_SOURCE_MANIFEST="+Path.GetFullPath(manifest));
            values.Add("WINSMUX_PUBLICATION_SOURCE_SHA256="+manifestHash);
        } else if (!String.IsNullOrEmpty(manifest) || !String.IsNullOrEmpty(manifestHash)) throw new ArgumentException("Unexpected source manifest");
        if (role=="keeper" || role=="fixture" && Path.GetFileName(executable)=="pwsh.exe") {
            if (Path.GetFileName(executable)!="pwsh.exe") throw new ArgumentException("Fixed PowerShell image required");
            string modules=Path.Combine(imageDirectory,"Modules");LocalPlain(modules,true);
            values.Add("PSMODULEPATH="+modules);
            values.Add("POWERSHELL_TELEMETRY_OPTOUT=1");
        }
        if (role=="github") {
            if (Path.GetFileName(executable)!="gh.exe") throw new ArgumentException("Fixed GitHub CLI image required");
            // Authentication is not yet bound. This profile is observable, but
            // public dispatch stays closed until the separate auth contract is met.
            values.Add("GH_HOST=github.com");values.Add("GH_PROMPT_DISABLED=1");
            values.Add("GH_CONFIG_DIR="+Path.GetFullPath(privateTemp));
        }
        return new IntegratedPublicationEnvironment(role,values.ToArray());
    }
    // Called only by the trusted host for one exact provider. It adds no argv,
    // loader, proxy, CA or arbitrary environment key. Public action-time
    // authority and the original operation binding remain mandatory elsewhere.
    public static IntegratedPublicationEnvironment CreateAuthenticated(string role,string privateTemp,string executable,string manifest,string manifestHash,string value) {
        string name=role=="github" ? "GH_TOKEN" : role=="npm" ? "WINSMUX_NPM_TOKEN" : throw new ArgumentException("Authentication provider role refused");
        using(var profile=Create(role,privateTemp,executable,manifest,manifestHash))
            return new IntegratedPublicationEnvironment(role,profile.entries,name,value);
    }
    public void Dispose() {
        if (block!=IntPtr.Zero) { Marshal.Copy(new byte[blockBytes],0,block,blockBytes);Marshal.FreeHGlobal(block);block=IntPtr.Zero; }
    }
}
