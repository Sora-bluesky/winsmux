param(
    [string]$Repository = 'Sora-bluesky/winsmux',
    [switch]$Json,
    [switch]$ConnectorAvailable,
    [switch]$RequireGh,
    [switch]$SkipGitProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-GitHubWritePreflightResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$SelectedPath,
        [string]$GhUser = '',
        [string]$RepoPermission = 'unknown',
        [string]$GitRemoteProbe = 'skipped',
        [string]$Reason = '',
        [string]$NextAction = ''
    )

    [pscustomobject][ordered]@{
        status           = $Status
        selected_path    = $SelectedPath
        repository       = $Repository
        gh_user          = $GhUser
        repo_permission  = $RepoPermission
        git_remote_probe = $GitRemoteProbe
        reason           = $Reason
        next_action      = $NextAction
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
        Text     = (@($output) -join "`n").Trim()
    }
}

function Resolve-GitHubWriteFallback {
    param([Parameter(Mandatory = $true)][string]$Reason)

    if ($ConnectorAvailable -and -not $RequireGh) {
        return New-GitHubWritePreflightResult `
            -Status 'fallback' `
            -SelectedPath 'github_connector' `
            -Reason $Reason `
            -NextAction 'Use the GitHub connector write path for merge or release operations. Do not retry gh auth refresh repeatedly.'
    }

    return New-GitHubWritePreflightResult `
        -Status 'failed' `
        -SelectedPath 'stop' `
        -Reason $Reason `
        -NextAction 'Re-authenticate GitHub CLI in the browser, or switch to an explicit GitHub connector write path before merge or release automation.'
}

function Test-GitHubWritePreflight {
    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCommand) {
        return Resolve-GitHubWriteFallback -Reason 'gh CLI was not found.'
    }

    $userProbe = Invoke-NativeCommand -Command $ghCommand.Source -Arguments @('api', 'user', '--jq', '.login')
    if ($userProbe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($userProbe.Text)) {
        return Resolve-GitHubWriteFallback -Reason "gh api user failed. gh auth status is not sufficient for write automation. $($userProbe.Text)"
    }

    $permissionProbe = Invoke-NativeCommand -Command $ghCommand.Source -Arguments @('api', "repos/$Repository", '--jq', '.permissions')
    if ($permissionProbe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($permissionProbe.Text)) {
        return Resolve-GitHubWriteFallback -Reason "gh repository permission probe failed for $Repository. $($permissionProbe.Text)"
    }

    try {
        $permissions = $permissionProbe.Text | ConvertFrom-Json
    } catch {
        return Resolve-GitHubWriteFallback -Reason "gh repository permission probe returned invalid JSON for $Repository."
    }

    $hasWritePermission =
        ($permissions.PSObject.Properties.Name -contains 'admin' -and [bool]$permissions.admin) -or
        ($permissions.PSObject.Properties.Name -contains 'maintain' -and [bool]$permissions.maintain) -or
        ($permissions.PSObject.Properties.Name -contains 'push' -and [bool]$permissions.push)

    if (-not $hasWritePermission) {
        return Resolve-GitHubWriteFallback -Reason "gh user '$($userProbe.Text)' does not report write permission for $Repository."
    }

    $gitRemoteProbe = 'skipped'
    if (-not $SkipGitProbe) {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitCommand) {
            return Resolve-GitHubWriteFallback -Reason 'git CLI was not found for the remote credential probe.'
        }

        $gitProbe = Invoke-NativeCommand -Command $gitCommand.Source -Arguments @('ls-remote', '--exit-code', 'origin', 'HEAD')
        if ($gitProbe.ExitCode -ne 0) {
            return Resolve-GitHubWriteFallback -Reason "git remote credential probe failed. $($gitProbe.Text)"
        }

        $gitRemoteProbe = 'ok'
    }

    return New-GitHubWritePreflightResult `
        -Status 'ok' `
        -SelectedPath 'gh' `
        -GhUser $userProbe.Text `
        -RepoPermission 'write' `
        -GitRemoteProbe $gitRemoteProbe `
        -Reason 'gh api user, repository permission, and git remote probes passed.' `
        -NextAction 'Use gh for merge or release automation.'
}

$result = Test-GitHubWritePreflight

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Output "GitHub write path: $($result.selected_path)"
    Write-Output "status: $($result.status)"
    Write-Output "repository: $($result.repository)"
    if (-not [string]::IsNullOrWhiteSpace($result.gh_user)) {
        Write-Output "gh user: $($result.gh_user)"
    }
    Write-Output "repo permission: $($result.repo_permission)"
    Write-Output "git remote probe: $($result.git_remote_probe)"
    Write-Output "reason: $($result.reason)"
    Write-Output "next: $($result.next_action)"
}

if ($result.status -eq 'failed') {
    exit 1
}

exit 0
