# GUARDRAILS.md — Signs

> Operational safeguards documented as Trigger → Instruction → Reason.
> Keep the safeguards aligned with the active workflow and its verification gates.

## Signs

### 1. git rm without --cached
- **Trigger**: Need to untrack a file from git
- **Instruction**: Always use `git rm --cached`. Never bare `git rm`.
- **Reason**: Bare `git rm` deletes working files as well as removing them from the index; untracking must preserve local bytes.

### 2. send-keys without -l flag
- **Trigger**: Sending commands to winsmux panes via send-keys
- **Instruction**: Always include `-l` (literal mode) flag.
- **Reason**: Without `-l`, commands silently vanish. No error, no feedback — just lost work.

### 3. Operator writing code directly
- **Trigger**: Operator tempted to "quickly fix" a file
- **Instruction**: Dispatch all code changes to Builder panes via worktree.
- **Reason**: sh-orchestra-gate.js enforces this. Operator is read-only; separation prevents unreviewed changes.

### 4. Builder without worktree isolation
- **Trigger**: Dispatching implementation tasks to Builder
- **Instruction**: Always create a git worktree first. Never let Builder work in main repo.
- **Reason**: Worktree isolation prevents an implementation task from overwriting another task's files.

### 5. Merging without test verification
- **Trigger**: Builder reports "done" or PR looks clean
- **Instruction**: Run Pester tests + runtime verification before merge. done = test passed.
- **Reason**: A completion report alone does not prove that the changed behavior works or that regressions are absent.

### 6. Mocking database in integration tests
- **Trigger**: Writing integration tests that touch external systems
- **Instruction**: Use real connections, not mocks.
- **Reason**: Mock behavior can diverge from the real integration and conceal migration failures.

### 7. ROADMAP.md committed to public repo
- **Trigger**: Running git add on docs/ directory
- **Instruction**: Planning files are external/local-only. Never commit backlog or ROADMAP; use sync-roadmap.ps1 against the external planning paths.
- **Reason**: Development plans belong in local or external planning storage, outside the public repository.

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
- **Reason**: Labels make issues discoverable in the team's filtered views.

### 13. Backlog update without ROADMAP sync
- **Trigger**: Editing the planning backlog source of truth
- **Instruction**: Always run sync-roadmap.ps1 immediately after backlog changes so the external ROADMAP and internal planning docs under docs/internal stay in sync.
- **Reason**: ROADMAP.md or the internal verification docs become stale, causing planning and test errors.

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
- **Instruction**: Builder edits only. Git operations delegated to Researcher (Sonnet) or Operator.
- **Reason**: Git writes require an authorized execution route with access to the worktree's Git metadata; sandbox restrictions must remain enabled.

### 17. Git-Guard gate
- **Trigger**: Preparing a commit, push, PR, merge, or release.
- **Instruction**: Run repository git-guard through the managed hooks or `scripts/git-guard.ps1`. Do not bypass failures.
- **Reason**: Git-guard keeps secrets, local-only material, and generated runtime artifacts out of the public repository.
