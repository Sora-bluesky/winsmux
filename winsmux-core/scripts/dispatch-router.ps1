[CmdletBinding()]
param(
    [string]$Text,
    [string[]]$AvailableTargets = @(),
    [ValidateSet('Worker', 'Builder', 'Reviewer', 'Researcher', 'Commander')]
    [string]$DefaultRole = 'Worker',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-DispatchRouterKeywordMap {
    return [ordered]@{
        Worker = @('worker', 'worker-1', 'worker-2', 'worker-3', 'worker-4', 'worker-5', 'worker-6')
        Builder = @(
            'implement', 'implementation', 'build', 'builder', 'fix', 'bug', 'patch',
            'code', 'coding', 'refactor', 'write', 'edit', 'change', 'feature',
            'script', 'function', 'test', 'tests',
            '実装', '作って', '書いて', '修正', 'バグ', 'ビルド', 'コード', 'リファクタ', '機能'
        )
        Reviewer = @(
            'review', 'reviewer', 'audit', 'verify', 'verification', 'regression',
            'security review', 'inspect', 'check', 'qa',
            'レビュー', '確認', 'チェック', '検査', '監査'
        )
        Researcher = @(
            'research', 'researcher', 'investigate', 'investigation', 'analyze',
            'analysis', 'summarize', 'summary', 'explore', 'compare', 'find',
            'lookup', 'document', 'docs',
            '調査', 'リサーチ', '分析', '探して', '比較', '要約', '検索'
        )
        Commander = @(
            'plan', 'planner', 'backlog', 'triage', 'coordinate', 'orchestrate',
            'dispatch', 'assign', 'commit', 'merge', 'branch', 'release', 'session',
            'マージ', 'デプロイ', 'リリース', '承認', '計画'
        )
    }
}

function Get-DispatchRouterCanonicalRole {
    param([Parameter(Mandatory = $true)][string]$RoleOrLabel)

    switch -Regex ($RoleOrLabel) {
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)commander(?:$|[-_:/\s])' { return 'Commander' }
        default { return $null }
    }
}

function Get-DispatchRouterKeywordMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Keywords
    )

    $foundKeywords = [System.Collections.Generic.List[string]]::new()
    foreach ($keyword in $Keywords) {
        $escaped = [regex]::Escape($keyword)
        $pattern = if ($keyword.Contains(' ') -or $keyword -match '[^\x00-\x7F]') {
            $escaped
        } else {
            '\b' + $escaped + '\b'
        }

        if ([regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $foundKeywords.Add($keyword) | Out-Null
        }
    }

    return @($foundKeywords)
}

function Get-DispatchRouterPreferredLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [string[]]$AvailableTargets
    )

    $targets = @($AvailableTargets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targets.Count -eq 0) {
        return $null
    }

    $matching = @(
        $targets |
            Where-Object { (Get-DispatchRouterCanonicalRole $_) -eq $Role } |
            ForEach-Object {
                [PSCustomObject]@{
                    Label = $_
                    Index = if ($_ -match '(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue }
                }
            } |
            Sort-Object -Property Index, Label |
            ForEach-Object { $_.Label }
    )

    if ($matching.Count -gt 0) {
        return $matching[0]
    }

    return $null
}

function Get-DispatchRoute {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string[]]$AvailableTargets = @(),
        [ValidateSet('Worker', 'Builder', 'Reviewer', 'Researcher', 'Commander')]
        [string]$DefaultRole = 'Worker'
    )

    $keywordMap = Get-DispatchRouterKeywordMap
    $scoreTable = [ordered]@{}
    $bestRole = $DefaultRole
    $bestScore = -1
    $bestMatches = @()

    foreach ($role in $keywordMap.Keys) {
        $matches = @(Get-DispatchRouterKeywordMatches -Text $Text -Keywords $keywordMap[$role])
        $score = $matches.Count
        $scoreTable[$role] = [PSCustomObject]@{
            Score = $score
            Matches = @($matches)
        }

        if ($score -gt $bestScore) {
            $bestRole = $role
            $bestScore = $score
            $bestMatches = @($matches)
            continue
        }

        if ($score -eq $bestScore -and $score -gt 0) {
            $currentTarget = Get-DispatchRouterPreferredLabel -Role $bestRole -AvailableTargets $AvailableTargets
            $candidateTarget = Get-DispatchRouterPreferredLabel -Role $role -AvailableTargets $AvailableTargets
            if ($null -eq $currentTarget -and $null -ne $candidateTarget) {
                $bestRole = $role
                $bestMatches = @($matches)
            }
        }
    }

    $selectedTarget = Get-DispatchRouterPreferredLabel -Role $bestRole -AvailableTargets $AvailableTargets
    if ($bestRole -ne 'Commander' -and $null -eq $selectedTarget) {
        $selectedTarget = Get-DispatchRouterPreferredLabel -Role 'Worker' -AvailableTargets $AvailableTargets
    }

    $handleLocally = $bestRole -eq 'Commander' -or $null -eq $selectedTarget

    $reason = if ($bestScore -gt 0) {
        "Matched role '$bestRole' via: $($bestMatches -join ', ')"
    } else {
        "No routing keywords matched. Defaulted to '$bestRole'."
    }

    if ($bestRole -ne 'Commander' -and $null -eq $selectedTarget) {
        $reason = "$reason No '$bestRole' target is available."
    } elseif ($bestRole -ne 'Commander' -and $null -ne $selectedTarget -and (Get-DispatchRouterCanonicalRole $selectedTarget) -eq 'Worker') {
        $reason = "$reason Routed to generic worker target '$selectedTarget'."
    }

    if ($bestRole -eq 'Commander') {
        $reason = "$reason Handle this task locally as Commander."
    }

    return [PSCustomObject]@{
        Text = $Text
        SelectedRole = $bestRole
        SelectedTarget = $selectedTarget
        HandleLocally = $handleLocally
        MatchedKeywords = @($bestMatches)
        Scores = $scoreTable
        Reason = $reason
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Get-DispatchRoute -Text $Text -AvailableTargets $AvailableTargets -DefaultRole $DefaultRole
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 8
    } else {
        $result
    }
}
