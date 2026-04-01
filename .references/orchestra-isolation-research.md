# Orchestra Isolation Research Report

> Date: 2026-04-02
> Source: Claude Code source code, official docs (llms.txt), Codex CLI sandbox analysis

## 1. Claude Code の公式隔離メカニズム

### 1.1 Agent Worktree（ソースコード分析）

**ファイル**: `src/utils/worktree.ts`

Claude Code は `createAgentWorktree()` でサブエージェント用の git worktree を作成する。
この関数は以下のグローバル状態に**一切触れない**:
- `currentWorktreeSession`（モジュールレベル変数）
- `process.chdir`（CWD）
- プロジェクト設定

これにより、複数エージェントが並列で worktree を作成しても干渉しない。

**作成コマンド**:
```bash
git worktree add -B <branch> <path> <base-branch>
```

**変更検出** (`hasWorktreeChanges()`):
```
1. git status --porcelain → 未コミット変更を検出
2. git rev-list --count <baseline>..HEAD → 新コミットを検出
3. git コマンド失敗時 → true を返す（fail-closed）
```

**クリーンアップ**:
```bash
git worktree remove --force <path>
git branch -D <worktree-branch>
```

### 1.2 Fork Subagent パターン

**ファイル**: `src/tools/AgentTool/forkSubagent.ts`

Fork 子エージェントのルール（ソースから抜粋）:
1. サブエージェントを生成しない。直接実行する
2. 対話しない。質問しない
3. ツールを直接使用する（Bash, Read, Write）
4. ファイルを変更した場合、報告前にコミットする（ハッシュを含める）
5. ツール呼び出しの間にテキストを出力しない
6. スコープ内に留まる
7. レポートは500語以内
8. 出力は必ず「Scope:」で始める

**Worktree 通知**:
```
"You are operating in an isolated git worktree at ${worktreeCwd}.
 Paths in inherited context refer to parent's directory; translate to your root.
 Re-read files before editing. Your changes stay in this worktree."
```

### 1.3 Team システム

**ファイル**: `src/tools/TeamCreateTool/`, `src/utils/swarm/`

- リーダー + メンバー構成（1チーム = 1タスクリスト）
- ファイルベースメールボックス（`~/.claude/teams/{team}/mailbox/{agent}/`）
- パーミッション同期: ワーカーの権限要求 → リーダー経由でユーザーに表示
- シャットダウンプロトコル: request → response → abort

**重要な不在機能**:
- **マージゲートなし**: worktree の変更を検証してからマージする仕組みは内蔵されていない
- **ファイル排他なし**: 同一ファイルの同時編集を防ぐ仕組みは内蔵されていない
- これらはオーケストレーター（Commander）の責任

### 1.4 Permission 継承

**ファイル**: `src/utils/swarm/spawnUtils.ts`

```
plan モード > bypass permissions（plan が優先）
```

- `bypassPermissions` 継承時でも `planModeRequired` が true なら bypass しない
- サブエージェントは親のパーミッションコンテキストを継承 + 追加制限可能

## 2. Codex CLI のサンドボックス

### 2.1 Sandbox ポリシー

**ソース**: `.codex/.sandbox/requests/request-*.json`

```json
{
  "type": "workspace-write",
  "writable_roots": ["C:\\path\\to\\project"],
  "network_access": false
}
```

- **Windows ACL 強制**: `SetNamedSecurityInfoW` でディレクトリ単位の書込み制御
- **sandbox ユーザー**: `CodexSandboxOffline` / `CodexSandboxOnline`（セッションごと）
- **capability SID**: 実行ごとに固有の ACL スコープ

### 2.2 `--full-auto` とサンドボックスの関係

- `--full-auto` はツール呼び出しの承認をスキップするだけ
- **サンドボックスは無効化されない** — ACL は常に有効
- `writable_roots` 外への書き込みは OS レベルでブロック

### 2.3 並列実行の安全性

- 各 Codex 呼び出しは固有の request UUID + capability SID を持つ
- 異なるディレクトリで実行すれば ACL が独立
- **git worktree でディレクトリを分離すれば、Codex 間の干渉は OS レベルで不可能**

## 3. 設計パターンの比較

| パターン | 競合防止 | 暴走防止 | マージ制御 | 実装済み |
|----------|---------|---------|-----------|---------|
| プロンプト指示のみ | なし | なし | なし | 今回失敗した方式 |
| sandbox read-only | なし | あり | N/A | Codex CLI の機能 |
| git worktree 隔離 | **物理的に不可能** | worktree 内に限定 | diff ゲートで検証 | Claude Code に内蔵 |
| worktree + sandbox | **物理的に不可能** | **OS レベルで強制** | diff ゲート | **推奨構成** |

## 4. 推奨アーキテクチャ

### 4.1 ロール別制約

| 制約 | Commander | Builder | Researcher | Reviewer |
|------|-----------|---------|------------|----------|
| ファイルシステム | read-only | worktree 内 write | read-only | read-only |
| git commit | 禁止 | worktree 内のみ | 禁止 | 禁止 |
| git merge | 検証後に実施 | 禁止 | 禁止 | 禁止 |
| sandbox | — | workspace-write (worktree限定) | read-only | read-only |
| スコープ | 全体管理 | 割当ファイルのみ | 調査対象 | レビュー対象 |
| 出力形式 | タスク指示 | コード + コミット | レポート | APPROVE/REJECT |

### 4.2 ワークフロー

```
Commander
  ├── git worktree add .worktrees/builder-1 -B task-001 HEAD
  ├── git worktree add .worktrees/builder-2 -B task-002 HEAD
  ├── dispatch: codex → .worktrees/builder-1/
  ├── dispatch: codex → .worktrees/builder-2/
  ├── dispatch: codex (read-only) → researcher
  ├── dispatch: codex (read-only) → reviewer
  │
  ├── [完了検知]
  ├── diff gate: git -C .worktrees/builder-1 diff --name-only
  │   ├── 想定内 → format-patch → main に適用
  │   └── 想定外 → 自動リバート + アラート
  │
  └── cleanup: git worktree remove .worktrees/builder-1
```

### 4.3 diff ゲート

```bash
# 許可ファイルリスト
ALLOWED="src/main.rs src/server/mod.rs"

# 実際の変更ファイル
CHANGED=$(git -C $WORKTREE diff --name-only HEAD~1)

# ゲート判定
for f in $CHANGED; do
  if ! echo "$ALLOWED" | grep -q "$f"; then
    echo "REJECTED: $f is outside scope"
    git -C $WORKTREE reset --hard HEAD~1
    exit 1
  fi
done
```

## 5. Claude Code ソースからの教訓

1. **`createAgentWorktree()` はグローバル状態に触れない** — 並列安全の鍵
2. **`hasWorktreeChanges()` は fail-closed** — git 失敗時は「変更あり」と仮定
3. **ExitWorktree は変更がある worktree の削除を拒否** — 明示的確認が必要
4. **Fork 子エージェントにはスコープ・出力形式の厳格なルール** — 自由度を制限
5. **ファイル排他とマージゲートは内蔵されていない** — Commander の責任
6. **Plan モードは bypass permissions より優先** — 安全性の階層構造
