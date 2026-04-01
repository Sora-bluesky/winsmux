param(
    [Parameter(Mandatory)][string]$PaneId,
    [Parameter(Mandatory)][string]$PromptFile,
    [string]$Model = 'gpt-5.4'
)

if (-not (Test-Path $PromptFile)) {
    Write-Error "Prompt file not found: $PromptFile"
    exit 1
}

$launcher = (Join-Path $PSScriptRoot 'codex-launch.ps1') -replace '\\', '/'
$absPrompt = (Resolve-Path $PromptFile).Path -replace '\\', '/'

# Short, simple command with no special chars for send-keys
$cmd = "pwsh -File $launcher $absPrompt $Model"

psmux send-keys -t $PaneId $cmd Enter
Write-Host "$PaneId <- $PromptFile (model: $Model)"
