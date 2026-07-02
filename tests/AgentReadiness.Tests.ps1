$ErrorActionPreference = 'Stop'

Describe 'agent readiness prompt detection' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-readiness.ps1')
    }

    Context 'openai-compatible (api_llm) banner' {
        It 'accepts an unwrapped api_llm ready banner' {
            $text = @(
                'winsmux api_llm pane worker'
                'slot: worker-1'
                'provider: openrouter'
                'model: z-ai/glm-5.2'
                'project: C:\repo'
                'status: ready'
                'commands: exec <task-packet-path> [task-id] [run-id], status, help, quit'
                'api_llm[worker-1]> '
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeTrue
        }

        It 'accepts a banner whose prompt line is wrapped mid-token by a narrow pane' {
            # Reproduces the issue #1103 capture: `capture-pane -S -80` wraps the
            # prompt line so 'api_llm[worker-1]> ' is split across two physical
            # lines inside the pane id brackets.
            $text = @(
                'winsmux api_llm pane worker'
                'slot: worker-1'
                'provider: openrouter'
                'model: z-ai/glm-5.2'
                'project: C:\repo'
                'status: ready'
                'commands: exec <task-packet-path> [task-id] [run-id], status, hel'
                'p, quit'
                'api_llm[work'
                'er-1]> '
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeTrue
        }

        It 'accepts the banner via the status: ready anchor even if the prompt line is dropped entirely' {
            # Defense in depth: if pane capture truncates the trailing
            # no-newline prompt line, the fixed 'status: ready' line (emitted
            # with a real newline by api-llm-pane-worker.ps1) must still be
            # enough to flip readiness.
            $text = @(
                'winsmux api_llm pane worker'
                'slot: worker-1'
                'provider: openrouter'
                'model: z-ai/glm-5.2'
                'project: C:\repo'
                'status: ready'
                'commands: exec <task-packet-path> [task-id] [run-id], status, help, quit'
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeTrue
        }

        It 'still rejects a pane that is not ready yet (regression guard against false positives)' {
            $text = @(
                'winsmux api_llm pane worker'
                'slot: worker-1'
                'provider: openrouter'
                'model: z-ai/glm-5.2'
                'project: C:\repo'
                'status: starting'
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeFalse
        }

        It 'rejects blocked-pattern text even when status: ready appears earlier in scrollback' {
            $text = @(
                'status: ready'
                'unable to connect to openrouter'
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeFalse
        }

        It 'rejects a busy pane where the prompt is followed by an executing command' {
            # Codex review P1 on PR #1106: while a command runs, the pane
            # still contains the submitted `api_llm[worker-1]> exec ...` line
            # because api-llm-pane-worker.ps1 reads input after printing the
            # prompt and runs the command synchronously. A prompt that is not
            # at the end of the capture must not count as ready. Task output
            # has scrolled the startup banner out of the recent-line window.
            $text = @(
                'commands: exec <task-packet-path> [task-id] [run-id], status, help, quit'
                'api_llm[worker-1]> exec C:\packets\task-001.json'
                '[worker-1] loading packet task-001'
                '[worker-1] contacting provider openrouter'
                '[worker-1] streaming response tokens'
                '[worker-1] writing structured result'
                '[worker-1] run 1 of 1 in progress'
                '[worker-1] elapsed 00:12'
            ) -join "`n"

            Test-AgentPromptText -Text $text -Agent 'openai-compatible' | Should -BeFalse
        }
    }

    Context 'existing agent detection is unaffected (no cross-agent regression)' {
        It 'still detects a codex-ready banner' {
            $text = 'gpt-5.4-codex  73% context left'
            Test-AgentPromptText -Text $text -Agent 'codex' | Should -BeTrue
        }

        It 'still detects a claude-ready banner' {
            $text = 'Welcome to Claude Code!'
            Test-AgentPromptText -Text $text -Agent 'claude' | Should -BeTrue
        }

        It 'still detects a gemini-ready banner' {
            $text = 'Type your message or @path/to/file'
            Test-AgentPromptText -Text $text -Agent 'gemini' | Should -BeTrue
        }

        It 'does not let openai-compatible pattern leak into an unrelated agent name' {
            $text = 'api_llm[worker-1]> '
            Test-AgentPromptText -Text $text -Agent 'codex' | Should -BeFalse
        }
    }
}
