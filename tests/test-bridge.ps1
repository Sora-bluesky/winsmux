# test-bridge.ps1 — psmux-bridge manual test runner
# Usage: Run inside a psmux session with 2+ panes
#   psmux new-session -d -s test
#   psmux split-window -h -t test
#   pwsh tests/test-bridge.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$BRIDGE = Join-Path $PSScriptRoot "..\scripts\psmux-bridge.ps1"
$passed = 0
$failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "[FAIL] $Name — $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}

# Get pane list to find targets
$panes = & pwsh $BRIDGE list
$allPanes = $panes -split "`n" | Where-Object { $_ -match '^%\d+' } | ForEach-Object { ($_ -split ' ')[0] }
if ($allPanes.Count -lt 2) {
    Write-Error "Need at least 2 panes. Run: psmux split-window -h"
    exit 1
}
$pane1 = $allPanes[0]
$pane2 = $allPanes[1]
Write-Host "Testing with panes: $pane1, $pane2`n"

# --- Test 1: version ---
Test-Case "version command" {
    $out = & pwsh $BRIDGE version
    if ($out -notmatch 'psmux-bridge') { throw "unexpected output: $out" }
}

# --- Test 2: list ---
Test-Case "list shows panes" {
    $out = & pwsh $BRIDGE list
    if ($out -notmatch '%\d+') { throw "no pane IDs in output" }
}

# --- Test 3: id ---
Test-Case "id returns pane ID" {
    $out = & pwsh $BRIDGE id
    if ($out -notmatch '%?\d+') { throw "unexpected id: $out" }
}

# --- Test 4: read ---
Test-Case "read captures pane content" {
    $out = & pwsh $BRIDGE read $pane1 5
    # read should succeed (may return empty lines for new pane)
}

# --- Test 5: Read Guard blocks type without read ---
Test-Case "Read Guard blocks type without prior read" {
    # Clear any existing read marks
    $markDir = Join-Path $env:TEMP "winsmux\read_marks"
    if (Test-Path $markDir) { Remove-Item "$markDir\*" -Force -ErrorAction SilentlyContinue }

    try {
        & pwsh $BRIDGE type $pane1 "should fail" 2>&1
        throw "type should have been blocked"
    } catch {
        if ($_.Exception.Message -notmatch 'must read') {
            # If it's our "should have been blocked" error, re-throw
            if ($_.Exception.Message -match 'should have been blocked') { throw }
            # Otherwise the error message is about read guard - that's expected
        }
    }
}

# --- Test 6: read → type → keys flow ---
Test-Case "read-type-keys normal flow" {
    & pwsh $BRIDGE read $pane1 10 | Out-Null
    & pwsh $BRIDGE type $pane1 "echo winsmux-test"
    & pwsh $BRIDGE read $pane1 10 | Out-Null
    & pwsh $BRIDGE keys $pane1 Enter
}

# --- Test 7: name and resolve ---
Test-Case "name and resolve label" {
    & pwsh $BRIDGE name $pane1 "testpane"
    $resolved = & pwsh $BRIDGE resolve "testpane"
    $resolved = $resolved.Trim()
    if ($resolved -ne $pane1) { throw "resolve returned '$resolved', expected '$pane1'" }
}

# --- Test 8: label-based operations ---
Test-Case "operations via label" {
    & pwsh $BRIDGE read "testpane" 5 | Out-Null
    & pwsh $BRIDGE type "testpane" "echo via-label"
    & pwsh $BRIDGE read "testpane" 5 | Out-Null
    & pwsh $BRIDGE keys "testpane" Enter
}

# --- Test 9: message with header ---
Test-Case "message sends with header" {
    $env:WINSMUX_AGENT_NAME = "test-agent"
    & pwsh $BRIDGE read $pane2 10 | Out-Null
    & pwsh $BRIDGE message $pane2 "hello from test"
    # Verify by reading the pane - should contain the header
    Start-Sleep -Milliseconds 500
    $content = & pwsh $BRIDGE read $pane2 10
    $env:WINSMUX_AGENT_NAME = $null
    if ($content -notmatch 'psmux-bridge from:test-agent') {
        throw "message header not found in pane content"
    }
}

# --- Test 10: doctor ---
Test-Case "doctor runs without error" {
    $out = & pwsh $BRIDGE doctor
    if ($out -notmatch 'psmux') { throw "doctor output missing psmux info" }
}

# --- Cleanup ---
$labelFile = Join-Path $env:APPDATA "winsmux\labels.json"
if (Test-Path $labelFile) {
    $labels = Get-Content $labelFile | ConvertFrom-Json
    $labels.PSObject.Properties.Remove("testpane")
    $labels | ConvertTo-Json | Set-Content $labelFile -Encoding UTF8
}
$markDir = Join-Path $env:TEMP "winsmux\read_marks"
if (Test-Path $markDir) { Remove-Item "$markDir\*" -Force -ErrorAction SilentlyContinue }

# --- Summary ---
Write-Host "`n========================"
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "========================"
exit $failed
