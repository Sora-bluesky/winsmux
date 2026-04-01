# Shield Harness Implementation Context

> Shield Harness = Claude Code の `.claude/` ディレクトリ構造によるセキュリティハーネス（hooks + rules + skills + settings.json）

## Design Documents（実装時に必ず参照）

| #   | ドキュメント       | 層        | パス                                               | 用途                                     |
| --- | ------------------ | --------- | -------------------------------------------------- | ---------------------------------------- |
| ①   | REQUIREMENTS.md    | Why       | docs/REQUIREMENTS.md                               | 機能要件・受入基準                       |
| ②   | THREAT_MODEL.md    | Why→What  | docs/THREAT_MODEL.md                               | 脅威 ID・攻撃ベクトル                    |
| ③   | ARCHITECTURE.md    | What      | docs/ARCHITECTURE.md                               | 22 フック一覧・ディレクトリ構造          |
| ④   | CLAUDE_MD_SPEC.md  | What      | docs/CLAUDE_MD_SPEC.md                             | 28 ルール仕様・トレーサビリティ          |
| ⑤   | DETAILED_DESIGN.md | How       | docs/DETAILED_DESIGN.md                            | 各フックの入出力・正規表現・分岐ロジック |
| ADR | ADR 設計提案       | Reference | .reference/SHIELD_HARNESS_ADR_REDESIGN_PROPOSAL.md | 35 ADR の設計判断根拠                    |

## Implementation Order（依存関係グラフに基づく）

```
Phase A（基盤 — 最初に実装）:
  ADR-033: backlog.yaml スキーマ + sync-project-views.ps1
  ↓ 他 ADR の前提

Phase B（パイプライン）:
  ADR-031: sh-pipeline.js（STG ゲート駆動）
  ADR-032: 承認レスモード（approval_free） ← 並列可
  ADR-035: バイリンガル README + sync-readme.ps1 ← 並列可
  ↓

Phase C（自律ループ）:
  ADR-034: auto-pickup + チャンネル連携 + ブロック通知
```

## Technical Constraints

- **Hook language**: Node.js CommonJS（ミリ秒応答必須）。共通ユーティリティは lib/sh-utils.js
- **Hook protocol**: exit 0 = allow, exit 2 = deny（stdout に JSON）。deny() は sh-utils.js 経由
- **Target**: 23 hook scripts (22 sh-\* + lint-on-save) + lib/sh-utils.js + injection-patterns.json
- **External deps**: node 18+ (CommonJS hooks), pwsh (sync scripts, bash fallback あり), gh (optional)
- **OS**: Windows ネイティブファースト（Git Bash 環境）。WSL2/Linux 互換
- **Trusted Operation**: pipeline の git 操作は bash 子プロセスとして直接実行（フックエンジン非経由）
- **fail-close**: 安全条件を確認できない場合は exit 2 で停止

## Directory Structure（生成対象の全量）

```
.claude/
├─ settings.json
├─ settings.local.json
├─ agents/
│   └─ general-purpose.md
├─ hooks/
│   ├─ sh-permission.js
│   ├─ sh-permission-learn.js
│   ├─ sh-gate.js
│   ├─ sh-injection-guard.js
│   ├─ sh-user-prompt.js
│   ├─ sh-evidence.js
│   ├─ sh-output-control.js
│   ├─ sh-quiet-inject.js
│   ├─ sh-circuit-breaker.js
│   ├─ sh-task-gate.js
│   ├─ sh-precompact.js
│   ├─ sh-postcompact.js
│   ├─ sh-instructions.js
│   ├─ sh-session-start.js
│   ├─ sh-session-end.js
│   ├─ sh-config-guard.js
│   ├─ sh-subagent.js
│   ├─ sh-dep-audit.js
│   ├─ sh-elicitation.js
│   ├─ sh-worktree.js
│   ├─ sh-data-boundary.js
│   ├─ sh-pipeline.js
│   ├─ lint-on-save.js
│   └─ lib/
│       └─ sh-utils.js
├─ patterns/
│   └─ injection-patterns.json
├─ rules/
│   ├─ binding-governance.md
│   ├─ channel-security.md
│   ├─ coding-principles.md
│   ├─ dev-environment.md
│   ├─ implementation-context.md
│   ├─ language.md
│   ├─ security.md
│   └─ testing.md
├─ skills/
│   ├─ checkpointing/
│   ├─ docs-sync/
│   ├─ handoff/
│   ├─ init/
│   ├─ plan/
│   ├─ simplify/
│   ├─ startproject/
│   ├─ tdd/
│   ├─ team-implement/
│   ├─ team-review/
│   └─ test-coverage-improver/
└─ logs/
    ├─ evidence-ledger.jsonl
    └─ instructions-hashes.json

.shield-harness/
├─ session.json
├─ config/
│   └─ pipeline-config.json
└─ logs/

tasks/
└─ backlog.yaml

docs/project/
├─ ROADMAP.md
├─ WBS.md
├─ GANTT.md
└─ MILESTONES.md

scripts/
├─ sync-project-views.ps1
└─ sync-readme.ps1
```

## Coding Rules for Hook Scripts

- **DETAILED_DESIGN.md が唯一の実装仕様書** — 各フックの §番号を参照して実装すること
- deny() は stdout に JSON を出力 + exit 2（stderr ではない）
- NFKC 正規化: Node.js 不在時は fail-close（deny）
- Hash chain: flock ベースロック（Windows Git Bash では mkdir フォールバック）
- READONLY_PATTERNS から sed を除外（sed -i は書込操作）
- permissions.allow: standard プロファイルで 40 操作
- Circuit breaker: stop_hook_active フラグは allow 後にリセット
