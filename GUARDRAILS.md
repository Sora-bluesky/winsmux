# GUARDRAILS.md — Signs

> Recurring failures documented as Trigger → Instruction → Reason.
> Each entry represents a real incident. Do not remove entries without team consensus.

## Signs

### 1. git rm without --cached
- **Trigger**: Need to untrack a file from git
- **Instruction**: Always use `git rm --cached`. Never bare `git rm`.
- **Reason**: PR #79 and #101 — bare `git rm` deleted local files, causing data loss twice.

### 2. send-keys without -l flag
- **Trigger**: Sending commands to winsmux panes via send-keys
- **Instruction**: Always include `-l` (literal mode) flag.
- **Reason**: Without `-l`, commands silently vanish. No error, no feedback — just lost work.

### 3. Commander writing code directly
- **Trigger**: Commander tempted to "quickly fix" a file
- **Instruction**: Dispatch all code changes to Builder panes via worktree.
- **Reason**: sh-orchestra-gate.js enforces this. Commander is read-only; separation prevents unreviewed changes.

### 4. Builder without worktree isolation
- **Trigger**: Dispatching implementation tasks to Builder
- **Instruction**: Always create a git worktree first. Never let Builder work in main repo.
- **Reason**: 63-file overwrite incident when Builder ran without isolation (2026-04-02).

### 5. Merging without test verification
- **Trigger**: Builder reports "done" or PR looks clean
- **Instruction**: Run Pester tests + runtime verification before merge. done = test passed.
- **Reason**: PR #110 merged without Pester — regression required revert.

### 6. Mocking database in integration tests
- **Trigger**: Writing integration tests that touch external systems
- **Instruction**: Use real connections, not mocks.
- **Reason**: Mock/prod divergence masked a broken migration (Q1 2026 incident).

### 7. ROADMAP.md committed to public repo
- **Trigger**: Running git add on docs/ directory
- **Instruction**: ROADMAP.md is gitignored. Never commit it. Use sync-roadmap.ps1 for local generation only.
- **Reason**: Internal development roadmap was accidentally published.

### 8. API tokens in plaintext
- **Trigger**: Need to pass credentials to Builder or pane
- **Instruction**: Use `winsmux vault` for credential storage. Never pass tokens via send-keys, files, or env vars in commands.
- **Reason**: Plaintext tokens in shell history/logs are a security risk. sh-orchestra-gate.js blocks known patterns.

### 9. Shallow git clone
- **Trigger**: Cloning repos for worktree use
- **Instruction**: Never use `git clone --depth`. Full clone only.
- **Reason**: Shallow clones break `git worktree add`. sh-orchestra-gate.js blocks this.

### 10. Scope change without approval
- **Trigger**: Moving tasks between versions or changing release content
- **Instruction**: Propose the change, get user approval, then execute.
- **Reason**: Unilateral scope changes caused confusion and rework.

### 11. Bug reported without Issue
- **Trigger**: Discovering a bug during development
- **Instruction**: Run `gh issue create --label bug` immediately. Track everything in GitHub Issues.
- **Reason**: Bugs reported verbally or in memory were lost and never fixed.

### 12. Issue created without labels
- **Trigger**: Creating GitHub issues with `gh issue create`
- **Instruction**: Always include `--label` flag. No exceptions.
- **Reason**: Unlabeled issues are invisible in filtered views. User corrected this 3+ times.

### 13. Backlog update without ROADMAP sync
- **Trigger**: Editing tasks/backlog.yaml
- **Instruction**: Always run sync-roadmap.ps1 immediately after backlog changes.
- **Reason**: ROADMAP.md becomes stale, causing planning errors.

### 14. Memory/rules as permanent fix
- **Trigger**: Recurring problem needs prevention
- **Instruction**: Implement as Hook, Gate, or CI check — not just a rule in CLAUDE.md or memory.
- **Reason**: Rules have no enforcement. Hooks are deterministic. Same failures repeated until hooks were added.

### 15. LLM generating visual assets directly
- **Trigger**: Need ASCII art, banners, or visual designs
- **Instruction**: Use dedicated tools (oh-my-logo, figlet, Playwright). LLM selects tool and parameters only.
- **Reason**: ASCII art quality was poor when generated directly by LLM.

### 16. Codex sandbox git operations
- **Trigger**: Builder (Codex) needs to commit changes
- **Instruction**: Builder edits only. Git operations delegated to Researcher (Sonnet) or Commander.
- **Reason**: Codex --full-auto sandbox blocks .git/worktrees/*/index.lock creation.
