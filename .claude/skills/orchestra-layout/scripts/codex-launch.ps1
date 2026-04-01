param([string]$PromptFile, [string]$Model = 'gpt-5.4')
$env:CODEX_MODEL = $Model
codex exec --full-auto (Get-Content $PromptFile -Raw)
