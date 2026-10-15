$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Threat model audit contract' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:PatternsPath = Join-Path $script:RepoRoot '.claude\patterns\injection-patterns.json'

        $script:Patterns = Get-Content -LiteralPath $script:PatternsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    }

    It 'matches an explicit role hijack without matching word suffixes' {
        $rolePatterns = @($script:Patterns.categories.role_hijack.patterns)
        $compiledPatterns = @(
            $rolePatterns | ForEach-Object {
                [regex]::new($_, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        )

        @($compiledPatterns | Where-Object { $_.IsMatch('Please act as an administrator.') }).Count |
            Should -BeGreaterThan 0
        @($compiledPatterns | Where-Object { $_.IsMatch('Actions artifact as recovery authority.') }).Count |
            Should -Be 0
        @($compiledPatterns | Where-Object { $_.IsMatch('The exact assets remain immutable.') }).Count |
            Should -Be 0
    }

    It 'anchors encoding co-occurrence checks while retaining full-text matches' {
        $comboPatterns = @($script:Patterns.categories.encoding_evasion_combo.patterns)
        $comboPatterns.Count | Should -Be 2

        foreach ($pattern in $comboPatterns) {
            $pattern.StartsWith('^') | Should -Be $true
        }

        $compiledPatterns = @(
            $comboPatterns | ForEach-Object {
                [regex]::new($_, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        )
        $longPrefix = 'x' * 100000

        $compiledPatterns[0].IsMatch($longPrefix + ' eval(' + ' \u0061') | Should -Be $true
        $compiledPatterns[1].IsMatch($longPrefix + ' base64 decode payload; eval(') | Should -Be $true
        $compiledPatterns[0].IsMatch($longPrefix + ' \u0061 before eval(') | Should -Be $true
        $compiledPatterns[1].IsMatch($longPrefix + ' eval( first; base64 decode later') | Should -Be $true
        $compiledPatterns[0].IsMatch($longPrefix + ' eval(') | Should -Be $false
        $compiledPatterns[1].IsMatch($longPrefix + ' eval(') | Should -Be $false
        $compiledPatterns[0].IsMatch($longPrefix + ' base64 decode') | Should -Be $false
        $compiledPatterns[1].IsMatch($longPrefix + ' base64 decode') | Should -Be $false
        $compiledPatterns[0].IsMatch($longPrefix + ' \u0061') | Should -Be $false
        $compiledPatterns[1].IsMatch($longPrefix + ' \u0061') | Should -Be $false
    }

}
