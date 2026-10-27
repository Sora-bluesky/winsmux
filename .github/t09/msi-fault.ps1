Set-StrictMode -Version 3.0

if (-not ('T09.Msi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace T09 {
public static class Msi {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiOpenDatabaseW(string path, IntPtr persist, out IntPtr db);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiDatabaseOpenViewW(IntPtr db, string query, out IntPtr view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(IntPtr view, IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiViewFetch(IntPtr view, out IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiViewModify(IntPtr view, int mode, IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiDatabaseCommit(IntPtr db);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(IntPtr handle);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordGetStringW(IntPtr record, uint field, StringBuilder value, ref uint size);
    [DllImport("msi.dll")] static extern uint MsiRecordDataSize(IntPtr record, uint field);
    [DllImport("msi.dll")] static extern uint MsiRecordReadStream(IntPtr record, uint field, byte[] buffer, ref uint size);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordSetStreamW(IntPtr record, uint field, string path);
    const int ModifyUpdate = 2;
    const uint NoMoreItems = 259;

    static void Ok(uint code, string what) { if (code != 0) throw new InvalidOperationException(what + " failed with " + code); }
    static IntPtr Open(string path, bool write) {
        IntPtr db; Ok(MsiOpenDatabaseW(path, write ? (IntPtr)1 : IntPtr.Zero, out db), "MsiOpenDatabase"); return db;
    }
    static string Text(IntPtr record, uint field) {
        uint size = 0; var probe = new StringBuilder(1);
        uint code = MsiRecordGetStringW(record, field, probe, ref size);
        if (code != 234 && code != 0) throw new InvalidOperationException("MsiRecordGetString failed with " + code);
        size += 1; var value = new StringBuilder((int)size);
        Ok(MsiRecordGetStringW(record, field, value, ref size), "MsiRecordGetString"); return value.ToString();
    }
    static byte[] Stream(IntPtr record, uint field) {
        uint total = MsiRecordDataSize(record, field); var data = new byte[total]; uint offset = 0;
        var chunk = new byte[1 << 20];
        while (offset < total) {
            uint size = (uint)Math.Min(chunk.Length, total - offset);
            Ok(MsiRecordReadStream(record, field, chunk, ref size), "MsiRecordReadStream");
            if (size == 0) throw new InvalidOperationException("Stream ended early.");
            Buffer.BlockCopy(chunk, 0, data, (int)offset, (int)size); offset += size;
        }
        return data;
    }
    public static List<string[]> Query(string path, string sql, int columns) {
        var rows = new List<string[]>(); IntPtr db = Open(path, false), view = IntPtr.Zero;
        try {
            Ok(MsiDatabaseOpenViewW(db, sql, out view), "MsiDatabaseOpenView"); Ok(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute");
            while (true) {
                IntPtr record; uint code = MsiViewFetch(view, out record);
                if (code == NoMoreItems) break; Ok(code, "MsiViewFetch");
                try { var row = new string[columns]; for (uint i = 0; i < columns; i++) row[i] = Text(record, i + 1); rows.Add(row); }
                finally { MsiCloseHandle(record); }
            }
        } finally { if (view != IntPtr.Zero) MsiCloseHandle(view); MsiCloseHandle(db); }
        return rows;
    }
    // Returns the stream bytes, or null when the _Streams table has no row of that name.
    public static byte[] ReadStream(string path, string name) {
        IntPtr db = Open(path, false), view = IntPtr.Zero;
        try {
            Ok(MsiDatabaseOpenViewW(db, "SELECT `Name`, `Data` FROM `_Streams`", out view), "MsiDatabaseOpenView"); Ok(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute");
            while (true) {
                IntPtr record; uint code = MsiViewFetch(view, out record);
                if (code == NoMoreItems) return null; Ok(code, "MsiViewFetch");
                try { if (Text(record, 1) == name) return Stream(record, 2); } finally { MsiCloseHandle(record); }
            }
        } finally { if (view != IntPtr.Zero) MsiCloseHandle(view); MsiCloseHandle(db); }
    }
    public static void ReplaceStream(string path, string name, string dataFile) {
        IntPtr db = Open(path, true), view = IntPtr.Zero, record = IntPtr.Zero;
        try {
            Ok(MsiDatabaseOpenViewW(db, "SELECT `Name`, `Data` FROM `_Streams` WHERE `Name`='" + name + "'", out view), "MsiDatabaseOpenView");
            Ok(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute"); Ok(MsiViewFetch(view, out record), "MsiViewFetch");
            Ok(MsiRecordSetStreamW(record, 2, dataFile), "MsiRecordSetStream"); Ok(MsiViewModify(view, ModifyUpdate, record), "MsiViewModify");
            MsiCloseHandle(record); record = IntPtr.Zero; MsiCloseHandle(view); view = IntPtr.Zero;
            Ok(MsiDatabaseCommit(db), "MsiDatabaseCommit");
        } finally { if (record != IntPtr.Zero) MsiCloseHandle(record); if (view != IntPtr.Zero) MsiCloseHandle(view); MsiCloseHandle(db); }
    }
    public static int[] Diff(byte[] a, byte[] b) {
        var at = new List<int>(); int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++) if (a[i] != b[i]) at.Add(i);
        return at.ToArray();
    }
    public static void DeleteStream(string path, string name) {
        IntPtr db = Open(path, true), view = IntPtr.Zero;
        try {
            Ok(MsiDatabaseOpenViewW(db, "DELETE FROM `_Streams` WHERE `Name`='" + name + "'", out view), "MsiDatabaseOpenView");
            Ok(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute"); MsiCloseHandle(view); view = IntPtr.Zero;
            Ok(MsiDatabaseCommit(db), "MsiDatabaseCommit");
        } finally { if (view != IntPtr.Zero) MsiCloseHandle(view); MsiCloseHandle(db); }
    }
}
}
'@
}

function Get-T09Sha256([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-T09MsiFacts([Parameter(Mandatory)][string]$Path) {
    $properties = [ordered]@{}
    foreach ($row in [T09.Msi]::Query($Path, 'SELECT `Property`, `Value` FROM `Property`', 2)) {
        if ($row[0] -cin @('ProductCode', 'UpgradeCode', 'ProductVersion', 'ProductLanguage', 'ProductName', 'Manufacturer', 'ALLUSERS', 'MSIINSTALLPERUSER', 'INSTALLDIR')) { $properties[$row[0]] = $row[1] }
    }
    $media = @([T09.Msi]::Query($Path, 'SELECT `DiskId`, `Cabinet` FROM `Media`', 2) | ForEach-Object { [ordered]@{ disk_id = $_[0]; cabinet = $_[1] } })
    $embedded = @($media | Where-Object { $_.cabinet.StartsWith('#') } | ForEach-Object { $_.cabinet.Substring(1) })
    if ($embedded.Count -ne 1) { throw "Expected one embedded cabinet, found $($embedded.Count)." }
    $stream = [T09.Msi]::ReadStream($Path, $embedded[0])
    return [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $Path).Length
        properties = $properties
        media = $media
        cabinet_stream = $embedded[0]
        cabinet_present = ($null -ne $stream)
        cabinet_bytes = if ($null -ne $stream) { $stream.Length } else { $null }
        cabinet_sha256 = if ($null -ne $stream) { Get-T09Sha256 $stream } else { $null }
    }
}

# Byte offset inside the compressed payload of the first CFDATA block of the first folder.
function Get-T09CabPayloadOffset([byte[]]$Cab) {
    if ($Cab.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($Cab, 0, 4) -cne 'MSCF') { throw 'Embedded stream is not a cabinet.' }
    $flags = [BitConverter]::ToUInt16($Cab, 30)
    $header = 36; $folderReserve = 0; $dataReserve = 0
    if ($flags -band 0x4) {
        $headerReserve = [BitConverter]::ToUInt16($Cab, 36); $folderReserve = $Cab[38]; $dataReserve = $Cab[39]
        $header = 40 + $headerReserve
    }
    if ($flags -band 0x3) { throw 'Chained cabinets are out of scope.' }
    $dataStart = [BitConverter]::ToUInt32($Cab, $header)
    $blocks = [BitConverter]::ToUInt16($Cab, $header + 4)
    $checksum = [BitConverter]::ToUInt32($Cab, $dataStart)
    $compressed = [BitConverter]::ToUInt16($Cab, $dataStart + 4)
    $payload = $dataStart + 8 + $dataReserve
    if ($blocks -lt 1 -or $compressed -lt 2 -or $payload + $compressed -gt $Cab.Length) { throw 'Cabinet data block is malformed.' }
    return [ordered]@{ offset = [int]($payload + [Math]::Floor($compressed / 2)); data_start = $dataStart; data_blocks = $blocks; block_checksum = $checksum; block_bytes = $compressed; folder_reserve = $folderReserve }
}

# Writes a faulted copy of an MSI: tamper flips one byte of the embedded cabinet payload,
# missing deletes the cabinet stream while the Media table still declares it.
function New-T09MsiFault {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][ValidateSet('tamper', 'missing')][string]$Kind)
    if (Test-Path -LiteralPath $Destination) { throw "Fault destination exists: $Destination" }
    $before = Get-T09MsiFacts $Source
    if (-not $before.cabinet_present) { throw 'Source MSI has no embedded cabinet stream.' }
    [IO.File]::Copy($Source, $Destination, $false)
    $receipt = [ordered]@{ kind = $Kind; source_sha256 = $before.sha256; cabinet_stream = $before.cabinet_stream; source_cabinet_sha256 = $before.cabinet_sha256 }
    if ($Kind -ceq 'tamper') {
        $cab = [T09.Msi]::ReadStream($Destination, $before.cabinet_stream)
        $at = Get-T09CabPayloadOffset $cab
        $receipt.cab = $at
        $receipt.original_byte = $cab[$at.offset]
        $cab[$at.offset] = $cab[$at.offset] -bxor 0x01
        $receipt.faulted_byte = $cab[$at.offset]
        $temp = $Destination + '.cab'
        [IO.File]::WriteAllBytes($temp, $cab)
        try { [T09.Msi]::ReplaceStream($Destination, $before.cabinet_stream, $temp) } finally { [IO.File]::Delete($temp) }
        $written = [T09.Msi]::ReadStream($Destination, $before.cabinet_stream)
        $original = [T09.Msi]::ReadStream($Source, $before.cabinet_stream)
        $diff = @([T09.Msi]::Diff($original, $written))
        if ($written.Length -ne $original.Length -or $diff.Count -ne 1 -or $diff[0] -ne $at.offset) { throw 'Tampered cabinet does not differ in exactly the chosen byte.' }
        $receipt.differing_offsets = $diff
    } else {
        [T09.Msi]::DeleteStream($Destination, $before.cabinet_stream)
    }
    $after = Get-T09MsiFacts $Destination
    if ($Kind -ceq 'missing' -and ($after.cabinet_present -or @($after.media | Where-Object { $_.cabinet -ceq ('#' + $before.cabinet_stream) }).Count -ne 1)) { throw 'Missing fault did not remove only the declared stream.' }
    if (($after.properties | ConvertTo-Json -Compress) -cne ($before.properties | ConvertTo-Json -Compress)) { throw 'Fault changed MSI properties.' }
    $receipt.faulted = $after
    return $receipt
}
