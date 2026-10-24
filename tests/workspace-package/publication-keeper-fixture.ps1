# Real native fixture setup, not a ready flag or public authority adapter.
function Persist-FixtureKeeper([IntegratedPublicationCustody+KeeperIdentity]$Identity, [object]$Fixture) {
    $record = $Identity | Select-Object *
    $record | Add-Member -NotePropertyName creation_filetime_exact -NotePropertyValue $Identity.CreationFileTime.ToString()
    $target = Join-Path $Fixture.fixture_root 'keeper.json'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 6 -Compress))
    $file = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
    if ([IO.File]::ReadAllText($target) -cne [Text.Encoding]::UTF8.GetString($bytes)) { throw 'Keeper persistence readback differs.' }
}
function Start-FixtureKeeper([IntegratedPublicationCustody]$Custody, [object]$Fixture, [string]$RepoRoot, [Action[IntegratedPublicationCustody+KeeperIdentity]]$PersistOverride = $null) {
    $pwshImage = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $keeperScript = Join-Path $RepoRoot 'scripts/hold-publication-job.ps1'
    $implementation = Join-Path $RepoRoot 'scripts/IntegratedPublicationCustody.cs'
    $candidateManifest = Join-Path $Fixture.fixture_root 'publication-assets.json'
    $persist = [Action[IntegratedPublicationCustody+KeeperIdentity]]{ param($identity) Persist-FixtureKeeper $identity $Fixture }
    if ($PersistOverride) { $persist = $PersistOverride }
    $Custody.StartKeeper($pwshImage, (Get-FileHash -LiteralPath $pwshImage -Algorithm SHA256).Hash.ToLowerInvariant(),
        $keeperScript, (Get-FileHash -LiteralPath $keeperScript -Algorithm SHA256).Hash.ToLowerInvariant(),
        $implementation, (Get-FileHash -LiteralPath $implementation -Algorithm SHA256).Hash.ToLowerInvariant(),
        $Fixture.candidate_identity.attempt, (Get-FileHash -LiteralPath $candidateManifest -Algorithm SHA256).Hash.ToLowerInvariant(), 15000, $persist)
}
