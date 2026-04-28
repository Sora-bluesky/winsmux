BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:PreflightScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\github-write-preflight.ps1'
}

Describe 'GitHub write preflight' {
    It 'selects gh only after api user, permission, and git probes pass' {
        $fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-gh-preflight-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            $log = Join-Path $fixture 'calls.log'
            $gh = Join-Path $fixture 'gh.cmd'
            $git = Join-Path $fixture 'git.cmd'

            Set-Content -LiteralPath $gh -Encoding ASCII -Value @"
@echo off
echo %*>>"$log"
if "%1 %2"=="api user" (
  echo test-user
  exit /b 0
)
if "%1 %2"=="api repos/Sora-bluesky/winsmux" (
  echo {"admin":false,"maintain":false,"push":true}
  exit /b 0
)
if "%1 %2"=="auth status" (
  exit /b 99
)
exit /b 2
"@
            Set-Content -LiteralPath $git -Encoding ASCII -Value @"
@echo off
echo git %*>>"$log"
if "%1 %2"=="ls-remote --exit-code" (
  echo abc HEAD
  exit /b 0
)
exit /b 2
"@

            $oldPath = $env:PATH
            $env:PATH = "$fixture;$oldPath"
            $json = & pwsh -NoProfile -File $script:PreflightScript -Repository 'Sora-bluesky/winsmux' -Json
            $exitCode = $LASTEXITCODE
            $result = $json | ConvertFrom-Json
            $calls = Get-Content -LiteralPath $log -Raw

            $exitCode | Should -Be 0
            $result.status | Should -Be 'ok'
            $result.selected_path | Should -Be 'gh'
            $result.gh_user | Should -Be 'test-user'
            $result.git_remote_probe | Should -Be 'ok'
            $calls | Should -Match 'api user'
            $calls | Should -Match 'api repos/Sora-bluesky/winsmux'
            $calls | Should -Not -Match 'auth status'
        } finally {
            $env:PATH = $oldPath
            if (Test-Path -LiteralPath $fixture) {
                Remove-Item -LiteralPath $fixture -Recurse -Force
            }
        }
    }

    It 'fails closed when gh api user fails even if auth status would pass' {
        $fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-gh-preflight-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            $gh = Join-Path $fixture 'gh.cmd'
            Set-Content -LiteralPath $gh -Encoding ASCII -Value @"
@echo off
if "%1 %2"=="api user" (
  echo HTTP 401: Requires authentication
  exit /b 1
)
if "%1 %2"=="auth status" (
  exit /b 0
)
exit /b 2
"@

            $oldPath = $env:PATH
            $env:PATH = "$fixture;$oldPath"
            $json = & pwsh -NoProfile -File $script:PreflightScript -Repository 'Sora-bluesky/winsmux' -Json 2>&1
            $exitCode = $LASTEXITCODE
            $result = ($json | Out-String) | ConvertFrom-Json

            $exitCode | Should -Be 1
            $result.status | Should -Be 'failed'
            $result.selected_path | Should -Be 'stop'
            $result.reason | Should -Match 'gh api user failed'
        } finally {
            $env:PATH = $oldPath
            if (Test-Path -LiteralPath $fixture) {
                Remove-Item -LiteralPath $fixture -Recurse -Force
            }
        }
    }

    It 'selects connector fallback only when gh is unhealthy and connector fallback is allowed' {
        $fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-gh-preflight-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            $gh = Join-Path $fixture 'gh.cmd'
            Set-Content -LiteralPath $gh -Encoding ASCII -Value @"
@echo off
if "%1 %2"=="api user" (
  echo HTTP 401: Requires authentication
  exit /b 1
)
exit /b 2
"@

            $oldPath = $env:PATH
            $env:PATH = "$fixture;$oldPath"
            $json = & pwsh -NoProfile -File $script:PreflightScript -Repository 'Sora-bluesky/winsmux' -ConnectorAvailable -Json
            $exitCode = $LASTEXITCODE
            $result = $json | ConvertFrom-Json

            $exitCode | Should -Be 0
            $result.status | Should -Be 'fallback'
            $result.selected_path | Should -Be 'github_connector'
        } finally {
            $env:PATH = $oldPath
            if (Test-Path -LiteralPath $fixture) {
                Remove-Item -LiteralPath $fixture -Recurse -Force
            }
        }
    }
}
