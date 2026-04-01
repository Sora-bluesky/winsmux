# Channel Security Rules

## Approval-Free Mode (ADR-032)

When `approval_free: true` in pipeline-config.json:

- All security decisions are delegated to hooks (no human approval dialogs)
- `permissions.deny` rules remain absolute — hooks cannot override them
- `permissions.ask` rules are promoted to `allow` at SessionStart
- All hook-based defenses (gate, injection-guard, permission) run at 100%

## Security Invariants

These guarantees hold regardless of approval_free setting:

1. **deny is absolute**: No hook, agent, or automation can override a deny rule
2. **fail-close**: If a hook cannot determine safety, it denies (exit 2)
3. **evidence required**: All allow/deny decisions are recorded in evidence-ledger
4. **no silent bypass**: Hook errors result in deny, not silent allow

## Claude Code Channels Security Harness (ADR-036 §D4)

Claude Code Channels (2026-03-20 公式リリース) は MCP ベースの Telegram/Discord 連携。
Shield Harness は独自のチャンネル実装を持たず、公式 Channels のセキュリティハーネスとして機能する。

### 対応方針

- 公式 Channels のみサポート（Telegram, Discord）
- 独自チャンネル実装は行わない（公式 Channels の `--channels` が唯一のプッシュ手段）
- VS Code パネルモードでの `--channels` 対応は公式の対応を待つ
- Shield Harness hooks はタグ検知方式で自動追従（環境固有コード不要）

### チャンネルイベント検知

Channel messages arrive as `<channel source="telegram|discord">` events.
Shield Harness hooks detect this tag automatically on any hook event:

- `UserPromptSubmit`: channel source tag detection → NFKC normalization → injection scan
- `PreToolUse`: normal gate/permission checks apply to channel-originated commands
- `PostToolUse`: evidence recording with `source: channel` metadata

### 自動適応保証

以下の理由により、Shield Harness は公式 Channels の環境拡大に自動追従する:

1. hooks は `<channel source="...">` タグの有無で判定（環境非依存）
2. settings.json の hook 登録は CLI / VS Code 共通
3. `--channels` が VS Code で有効化された瞬間から Shield Harness のセキュリティゲートが発火
4. チャンネル無効環境ではイベント自体が到着しないため、誤検知なし（fail-safe）

### チャンネル固有の脅威緩和

- **Injection via channel message**: NFKC normalization + injection-patterns.json scan
- **Unauthorized sender**: 公式 allowlist（第一防衛線）+ Shield Harness 二重検証
- **Privilege escalation**: channel messages cannot modify deny rules or hook configuration
- **Task creation via channel**: requires STG0 gate validation before acceptance

### Implementation Mapping

Hook implementations that handle channel-related security:

| Threat                | Hook                | Function                                                                | Spec       |
| --------------------- | ------------------- | ----------------------------------------------------------------------- | ---------- |
| Injection via channel | sh-user-prompt.js   | `scanPatterns()` with `isChannel` flag                                  | §5.4, §8.6 |
| Severity boost        | sh-user-prompt.js   | `boostSeverity()` — elevates severity by one level for channel messages | §8.6.2     |
| Channel detection     | sh-user-prompt.js   | `session.source === "channel"` check via `readSession()`                | §8.6.1     |
| Evidence metadata     | sh-evidence.js      | `is_channel` field in evidence-ledger.jsonl entries                     | §8.6.3     |
| Data boundary         | sh-data-boundary.js | Jurisdiction tracking applies to channel-originated commands            | §3.4       |
| Config protection     | sh-config-guard.js  | deny rules and hook config immutable regardless of source               | §5.3       |
| Task gate             | sh-pipeline.js      | STG0 validation required for channel-originated task creation           | §8.1       |

### Severity Boost Table

Channel messages automatically boost pattern severity by one level:

| Original | Boosted  | Action     |
| -------- | -------- | ---------- |
| low      | medium   | warn       |
| medium   | high     | deny       |
| high     | critical | deny       |
| critical | critical | deny (cap) |

### Phase 2 Migration

When `--channels` becomes available in VS Code panel mode:

1. `sh-session-start.js` version-check detects the new capability
2. additionalContext suggests migration via `npx shield-harness channels migrate`
3. No hook code changes required — tag-based detection is environment-agnostic
4. New channel providers (beyond Telegram/Discord) are automatically covered
