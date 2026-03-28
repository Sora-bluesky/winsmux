---
name: winsmux
description: |
  Control psmux panes and communicate between AI agents on Windows.
  Use this skill whenever the user mentions pane control, cross-pane communication,
  sending messages to other agents, reading other panes, or managing psmux sessions on Windows.
---

# winsmux

Psmux pane control and cross-pane agent communication on Windows. Use `psmux-bridge` (the high-level CLI) for all cross-pane interactions. Fall back to raw psmux commands only when you need low-level control.

## psmux-bridge — Cross-Pane Communication

A CLI that lets any AI agent interact with any other psmux pane. Works via PowerShell. Every command is **atomic**: `type` types text (no Enter), `keys` sends special keys, `read` captures pane content.

### Communication Modes

Panes fall into two categories. **Identify the mode before communicating.**

| Mode | Condition | Rule |
|------|-----------|------|
| **Agent Mode** | Peer has winsmux skill installed (Claude Code, skill-enabled Codex) | DO NOT POLL. Reply arrives in YOUR pane via `[psmux-bridge from:...]` |
| **Non-Agent Mode** | Codex CLI (no skill), plain shell, dev server | POLL REQUIRED. Commander must `read` periodically to check status |

**Agent Mode** — do not sleep, poll, or loop. Send your message, press Enter, and move on. The reply appears directly in your pane.

**Non-Agent Mode** — after sending a task, enter the POLL loop (see Commander Workflow below). Read the target pane at intervals to detect completion, approval prompts, or errors.

The ONLY time you read a target pane in Agent Mode is:
- **Before** interacting with it (enforced by the read guard)
- **After typing** to verify your text landed before pressing Enter

### Read Guard

The CLI enforces read-before-act. You cannot `type` or `keys` to a pane unless you have read it first.

1. `psmux-bridge read <target>` marks the pane as "read"
2. `psmux-bridge type/keys <target>` checks for that mark — errors if you haven't read
3. After a successful `type`/`keys`, the mark is cleared — you must read again before the next interaction

Read marks are stored in `$env:TEMP\winsmux\read_marks\`.

```
PS> psmux-bridge type codex "hello"
error: must read the pane before interacting. Run: psmux-bridge read codex
```

### Command Reference

| Command | Description | Example |
|---|---|---|
| `psmux-bridge list` | Show all panes with target, pid, command, size, label | `psmux-bridge list` |
| `psmux-bridge type <target> <text>` | Type text without pressing Enter | `psmux-bridge type codex "hello"` |
| `psmux-bridge message <target> <text>` | Type text with auto sender info and reply target | `psmux-bridge message codex "review src/auth.ts"` |
| `psmux-bridge read <target> [lines]` | Read last N lines (default 50) | `psmux-bridge read codex 100` |
| `psmux-bridge keys <target> <key>...` | Send special keys | `psmux-bridge keys codex Enter` |
| `psmux-bridge name <target> <label>` | Label a pane | `psmux-bridge name %3 codex` |
| `psmux-bridge resolve <label>` | Print pane target for a label | `psmux-bridge resolve codex` |
| `psmux-bridge id` | Print this pane's ID | `psmux-bridge id` |

### Target Resolution

Targets can be:
- **psmux native**: pane ID (`%3`), or window index (`0`)
- **label**: Any string set via `psmux-bridge name` — resolved automatically

Labels are stored in `$env:APPDATA\winsmux\labels.json`.

### Read-Act-Read Cycle

Every interaction follows **read → act → read**. The CLI enforces this.

**Sending a message to an agent:**
```powershell
psmux-bridge read codex 20                    # 1. READ — satisfy read guard
psmux-bridge message codex 'Please review src/auth.ts'
                                              # 2. MESSAGE — auto-prepends sender info, no Enter
psmux-bridge read codex 20                    # 3. READ — verify text landed
psmux-bridge keys codex Enter                 # 4. KEYS — submit
# STOP. Do NOT read codex for a reply. The agent replies into YOUR pane.
```

**Approving a prompt (non-agent pane):**
```powershell
psmux-bridge read worker 10                   # 1. READ — see the prompt
psmux-bridge type worker "y"                  # 2. TYPE
psmux-bridge read worker 10                   # 3. READ — verify
psmux-bridge keys worker Enter                # 4. KEYS — submit
psmux-bridge read worker 20                   # 5. READ — see the result
```

### Messaging Convention

The `message` command auto-prepends sender info and location:

```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply]
```

The receiver gets: who sent it (`from`), the exact pane to reply to (`pane`), and the session/window location (`at`). When you see this header, reply using psmux-bridge to the pane ID from the header.

### Agent-to-Agent Workflow

```powershell
# 1. Label yourself
psmux-bridge name (psmux-bridge id) claude

# 2. Discover other panes
psmux-bridge list

# 3. Send a message (read-act-read)
psmux-bridge read codex 20
psmux-bridge message codex 'Please review the changes in src/auth.ts'
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

### Example Conversation

**Agent A (claude) sends:**
```powershell
psmux-bridge read codex 20
psmux-bridge message codex 'What is the test coverage for src/auth.ts?'
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

**Agent B (codex) sees in their prompt:**
```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply] What is the test coverage for src/auth.ts?
```

**Agent B replies using the pane ID from the header:**
```powershell
psmux-bridge read %4 20
psmux-bridge message %4 '87% line coverage. Missing the OAuth refresh token path (lines 142-168).'
psmux-bridge read %4 20
psmux-bridge keys %4 Enter
```

---

## Commander Orchestration Workflow

When you are the **commander** (Claude Code orchestrating builder/reviewer Codex panes), follow this workflow. Builder and reviewer are **Non-Agent Mode** (Codex CLI without winsmux skill).

### Roles — Strict Separation (CRITICAL)

| Pane | Role | Responsibility | Prohibited |
|------|------|---------------|------------|
| commander | 指揮・設計・コミット | タスク分解、指示送信、結果判断、git 操作 | **コードを直接書く・修正する** |
| builder | 実装・修正 | コード実装、reviewer 指摘への修正対応 | レビュー、コミット |
| reviewer | コードレビュー | 品質・セキュリティ・アーキテクチャ観点のレビュー | 修正、コミット |
| monitor | テスト実行・ログ監視 | dev server、pytest、ビルドログ | エージェントは走らない |

**Commander はコードを書かない。** reviewer が指摘を出したら、commander はその指摘を読んで **builder に修正指示を送る**。commander 自身が修正してはならない。

### Workflow Cycle

```
1. PLAN    — ロードマップ/タスクを読み、実装方針を決める
2. BUILD   — builder に実装指示を送る
3. POLL    — builder の完了を待つ（POLL 必須。省略禁止）
4. REVIEW  — reviewer にレビュー依頼を送る
5. POLL    — reviewer の完了を待つ（POLL 必須。省略禁止）
6. JUDGE   — レビュー結果を判断
             OK → COMMIT へ
             NG → builder に修正指示（Step 2 に戻る）
7. COMMIT  — commander 自身でコミットする
8. NEXT    — 次のタスクへ（Step 1 に戻る）
```

### Step 2: BUILD — builder に実装指示を送る

```powershell
psmux-bridge read builder 20
psmux-bridge message builder '○○を実装してください。要件: ...'
psmux-bridge read builder 20
psmux-bridge keys builder Enter
# → 直ちに Step 3 (POLL) に遷移する。他の作業に移らない。
```

### Step 3: POLL & AUTO-APPROVE

builder/reviewer は Non-Agent Mode。**指示送信後、必ずこの POLL ループに入る。省略禁止。**

10秒間隔で read → 状態判断 → 対応。最大12回（約120秒）で打ち切る。

#### 状態判断パターン

| 出力に含まれる文字列 | 状態 | commander の対応 |
|---------------------|------|-----------------|
| `Do you want to proceed?` / `1. Yes` | **承認待ち** | 自動承認（下記手順） |
| `2. Yes, and don't ask again` | **承認待ち（永続選択肢あり）** | `type "2"` で以降の同種承認をスキップ |
| `> Implement` / `> Write` / `> Improve` | **完了（プロンプト待ち）** | POLL 終了 → 次ステップ |
| `gpt-5.4 high · 100% left` | **完了（アイドル状態）** | POLL 終了 → 次ステップ |
| `Editing...` / `Running...` / `Reading...` | **作業中** | 何もしない → 次 POLL |
| `"type": "error"` / `API error` / `rate limit` | **API エラー** | ユーザーに報告。モデル変更を提案 |
| `error` / `failed` / `Error` | **実行エラー** | エラー内容を読み取り対処判断 |
| `Esc to cancel` | **承認待ち** | 内容確認後 `keys Enter` で承認 |
| `[Y/n]` / `[y/N]` | **シェル確認** | `type "y"` + `keys Enter` |
| `Sandbox` | **サンドボックス承認** | `type "1"` + `keys Enter` |

#### 自動承認の手順

```powershell
# 通常の承認
psmux-bridge read builder 10
psmux-bridge type builder "1"
psmux-bridge read builder 5
psmux-bridge keys builder Enter

# 永続承認（初回のみ、以降の同種承認をスキップ）
psmux-bridge read builder 10
psmux-bridge type builder "2"
psmux-bridge read builder 5
psmux-bridge keys builder Enter
```

#### 危険コマンドの自動承認禁止

以下のパターンが承認内容に含まれる場合は**自動承認せず、ユーザーに報告する**:
- `rm -rf` / `Remove-Item -Recurse -Force`
- `git push --force` / `git reset --hard`
- `DROP TABLE` / `DELETE FROM`
- 不明な外部スクリプトの実行

#### POLL 打ち切り

12回（約120秒）で完了しない場合:
- builder/reviewer の最後の20行を読み取って提示
- 「承認待ち / 作業中 / エラー」の状態判断をユーザーに報告
- ユーザーの指示を待つ

### Step 4: REVIEW — reviewer にレビュー依頼を送る

```powershell
psmux-bridge read reviewer 20
psmux-bridge message reviewer 'git diff HEAD で未コミット変更を確認し、コードレビューしてください。観点: (1) セキュリティ (2) アーキテクチャ (3) テスト'
psmux-bridge read reviewer 20
psmux-bridge keys reviewer Enter
# → 直ちに Step 5 (POLL) に遷移する
```

### Step 5: POLL — reviewer の完了を待つ

Step 3 と同じ POLL ループを reviewer に対して実行する。

### Step 6: JUDGE — レビュー結果の判断

reviewer の出力を `psmux-bridge read reviewer 50` で読み取り判断:

- **LGTM / APPROVE / 問題なし** → Step 7 (COMMIT) に進む
- **REQUEST_CHANGES / 指摘あり**:
  1. 指摘内容を読み取る
  2. **builder に修正指示を送る（Step 2 に戻る）**
  3. ❌ commander が自分で修正してはならない
- **重大な問題** → ユーザーに報告して判断を仰ぐ

### Step 7: COMMIT

commander 自身で git 操作を行う:
```powershell
git add <files>
git commit -m "feat: ..."
```

### Monitor ペインの使い方

monitor は Non-Agent のプレーンシェル。テスト実行やログ監視に使う。

```powershell
# テスト実行
psmux-bridge read monitor 3
psmux-bridge type monitor "pytest tests/ -q"
psmux-bridge read monitor 3
psmux-bridge keys monitor Enter

# 10秒後に結果確認
Start-Sleep 10
psmux-bridge read monitor 30
# → "passed" / "failed" を判断
```

### Commander の禁止事項

1. **コードを直接書かない・修正しない** — 実装は builder に任せる。reviewer の指摘も builder に修正指示を送る
2. **POLL を省略しない** — BUILD/REVIEW 指示後は必ず POLL ループに遷移する
3. **reviewer を飛ばしてコミットしない** — 必ずレビューを通す
4. **複数ペインに同時に指示を送らない** — 1つずつ順番に
5. **危険コマンドを自動承認しない** — rm -rf, force push 等はユーザーに報告
6. **POLL を120秒以上続けない** — 12回で打ち切りユーザーに報告

---

## Raw psmux Commands

Use these when you need direct psmux control beyond what psmux-bridge provides — session management, window navigation, creating panes, or low-level scripting.

### Capture Output

```powershell
psmux capture-pane -t shared | Select-Object -Last 20    # Last 20 lines
psmux capture-pane -t shared                              # Entire scrollback
psmux capture-pane -t 'shared:0.0'                        # Specific pane
```

### Send Keys

```powershell
psmux send-keys -t shared -l "text here"     # Type text (literal mode)
psmux send-keys -t shared Enter              # Press Enter
psmux send-keys -t shared Escape             # Press Escape
psmux send-keys -t shared C-c                # Ctrl+C
psmux send-keys -t shared C-d               # Ctrl+D (EOF)
```

For interactive TUIs, split text and Enter into separate sends:
```powershell
psmux send-keys -t shared -l "Please apply the patch"
Start-Sleep -Milliseconds 100
psmux send-keys -t shared Enter
```

### Panes and Windows

```powershell
# Create panes (prefer over new windows)
psmux split-window -h -t SESSION              # Horizontal split
psmux split-window -v -t SESSION              # Vertical split
psmux select-layout -t SESSION tiled          # Re-balance

# Navigate
psmux select-window -t shared:0
psmux select-pane -t 'shared:0.1'
psmux list-windows -t shared
```

### Session Management

```powershell
psmux list-sessions
psmux new-session -d -s newsession
psmux kill-session -t sessionname
psmux rename-session -t old new
```

### Claude Code Patterns

```powershell
# Check if session needs input
psmux capture-pane -t worker-3 | Select-Object -Last 10 |
  Select-String -Pattern '❯|Yes.*No|proceed|permission'

# Approve a prompt
psmux send-keys -t worker-3 -l 'y'
psmux send-keys -t worker-3 Enter

# Check all sessions
foreach ($s in @('shared','worker-2','worker-3','worker-4')) {
    Write-Host "=== $s ==="
    psmux capture-pane -t $s 2>$null | Select-Object -Last 5
}
```

## Tips

- **Read guard is enforced** — you MUST read before every `type`/`keys`
- **Every action clears the read mark** — after `type`, read again before `keys`
- **Agent Mode: never poll** — skill-enabled agents reply via psmux-bridge into YOUR pane
- **Non-Agent Mode: always poll** — Codex CLI and plain shells require periodic `read` to check status
- **Label panes early** — easier than using `%N` IDs
- **`type` uses literal mode** — special characters are typed as-is
- **`read` defaults to 50 lines** — pass a higher number for more context
- **Non-agent panes** are the exception — you DO need to read them to see output
- **Labels** are stored in `$env:APPDATA\winsmux\labels.json` — persistent across sessions
- **Read marks** are stored in `$env:TEMP\winsmux\read_marks\` — cleared on reboot
- Use `capture-pane` to get output as strings (essential for scripting)
- Use **Alt** key combinations for psmux shortcuts (e.g., `Alt+1` to select window 1)
