$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Public runtime reference policy' {
    BeforeAll {
        $repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $auditPublicSurface = Join-Path $repoRoot 'scripts/audit-public-surface.ps1'
        $auditStagedPublicSurface = Join-Path $repoRoot 'scripts/audit-staged-public-surface.ps1'
        $newPublicRuntimeReferenceFixtureRepo = {
            param(
                [Parameter(Mandatory)]
                [string]$FixtureRoot,

                [Parameter(Mandatory)]
                [string]$AuditPublicSurface
            )

            $fixtureRepo = Join-Path $FixtureRoot ('public-runtime-reference-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $fixtureRepo '.githooks') -Force | Out-Null
            Copy-Item -LiteralPath $AuditPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-public-surface.ps1')
            Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/source-access.md') -Value '# Fixture public document' -Encoding UTF8
            & git -C $fixtureRepo init | Out-Null
            & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
            & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null
            & git -C $fixtureRepo config core.hooksPath .githooks | Out-Null
            & git -C $fixtureRepo add docs/source-access.md scripts/audit-public-surface.ps1 | Out-Null

            return [PSCustomObject]@{
                Root         = $fixtureRepo
                Audit        = Join-Path $fixtureRepo 'scripts/audit-public-surface.ps1'
                SourceAccess = Join-Path $fixtureRepo 'docs/source-access.md'
            }
        }
    }

    It 'blocks Google Drive URLs in public materials without printing the URL' {
        $fixture = & $newPublicRuntimeReferenceFixtureRepo -FixtureRoot $TestDrive -AuditPublicSurface $auditPublicSurface
        $linkedPublicDoc = $fixture.SourceAccess
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $blockedUrl = 'https://drive.google.com/file/d/1Z2Y3X4W5V6U7T8S9R0Q/view'
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nColab cache: $blockedUrl`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            Push-Location -LiteralPath $fixture.Root
            try {
                $output = @(& pwsh -NoProfile -File $fixture.Audit 2>&1)
            } finally {
                Pop-Location
            }

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public material contains a Google Drive document or folder URL'
            ($output -join "`n") | Should -Match 'docs/source-access\.md'
            ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedUrl))
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks non-reserved email addresses in public materials without printing the address' {
        $fixture = & $newPublicRuntimeReferenceFixtureRepo -FixtureRoot $TestDrive -AuditPublicSurface $auditPublicSurface
        $linkedPublicDoc = $fixture.SourceAccess
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $blockedAddress = 'sample.operator' + '@' + ('gmail' + '.com')
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nContact: $blockedAddress`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            Push-Location -LiteralPath $fixture.Root
            try {
                $output = @(& pwsh -NoProfile -File $fixture.Audit 2>&1)
            } finally {
                Pop-Location
            }

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public material contains non-reserved email address'
            ($output -join "`n") | Should -Match 'docs/source-access\.md'
            ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedAddress))
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'allows reserved example email addresses in public materials and release notes' {
        $fixture = & $newPublicRuntimeReferenceFixtureRepo -FixtureRoot $TestDrive -AuditPublicSurface $auditPublicSurface
        $linkedPublicDoc = $fixture.SourceAccess
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $releaseBody = Join-Path $TestDrive 'reserved-email-release-body.md'
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nContact: winsmux-test@example.invalid`n",
                [System.Text.UTF8Encoding]::new($false)
            )
            Set-Content -LiteralPath $releaseBody -Value 'Release contact: winsmux-test@example.invalid' -Encoding UTF8

            Push-Location -LiteralPath $fixture.Root
            try {
                $output = @(& pwsh -NoProfile -File $fixture.Audit -ReleaseNotesPath $releaseBody 2>&1)
            } finally {
                Pop-Location
            }

            $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
            ($output -join "`n") | Should -Match 'audit-public-surface passed'
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks local absolute paths in generated release notes without printing the path' {
        $fixture = & $newPublicRuntimeReferenceFixtureRepo -FixtureRoot $TestDrive -AuditPublicSurface $auditPublicSurface
        $releaseBody = Join-Path $TestDrive 'private-path-release-body.md'
        $blockedPath = 'D:\work\repo\private-models'
        Set-Content -LiteralPath $releaseBody -Value "Model cache: $blockedPath" -Encoding UTF8

        Push-Location -LiteralPath $fixture.Root
        try {
            $output = @(& pwsh -NoProfile -File $fixture.Audit -ReleaseNotesPath $releaseBody 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'release notes contains a local absolute path'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedPath))
    }

    It 'blocks non-reserved email addresses staged for public materials without printing the address' {
        $fixtureRepo = Join-Path $TestDrive 'staged-personal-email-repo'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
        Copy-Item -LiteralPath $auditStagedPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1')
        & git -C $fixtureRepo init | Out-Null
        & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
        & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null

        $blockedAddress = 'sample.operator' + '@' + ('gmail' + '.com')
        Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/release-notes.md') -Value "Maintainer contact: $blockedAddress" -Encoding UTF8
        & git -C $fixtureRepo add docs/release-notes.md scripts/audit-staged-public-surface.ps1 | Out-Null

        Push-Location -LiteralPath $fixtureRepo
        try {
            $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1') 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'staged public material contains non-reserved email address'
        ($output -join "`n") | Should -Match 'docs/release-notes\.md'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedAddress))
    }

    It 'blocks staged Google Drive URLs and local absolute paths without printing the values' {
        $fixtureRepo = Join-Path $TestDrive 'staged-private-runtime-reference-repo'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
        Copy-Item -LiteralPath $auditStagedPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1')
        & git -C $fixtureRepo init | Out-Null
        & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
        & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null

        $blockedUrl = 'https://drive.google.com/file/d/1Z2Y3X4W5V6U7T8S9R0Q/view'
        $blockedPath = 'E:\private\colab-cache'
        Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/release-notes.md') -Value "Cache: $blockedUrl`nMirror: $blockedPath" -Encoding UTF8
        & git -C $fixtureRepo add docs/release-notes.md scripts/audit-staged-public-surface.ps1 | Out-Null

        Push-Location -LiteralPath $fixtureRepo
        try {
            $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1') 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'staged public material contains a Google Drive document or folder URL'
        ($output -join "`n") | Should -Match 'staged public material contains a local absolute path'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedUrl))
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedPath))
    }
}
