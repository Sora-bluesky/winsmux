# v0.36.22 コンテキスト継続性と信頼できる非同期連携

v0.36.22 は、複数ペインの作業を再開・ルーティング・レビューするために必要な文脈だけを残すための契約を定義します。生の会話ログ、プロンプト本文、秘密情報、ローカルの個人パスは保存しません。

この版は正式な 6 ペインベンチマーク版ではありません。正式ベンチマークは、ここで整えた連携契約を使う後続の版で測定します。

## 契約

| 契約 | 目的 | 公開できる境界 |
|---|---|---|
| Context Capsule v1 | ルーティング、レビュー、引き継ぎに使う短い実行要約。 | 状態、次の具体的な作業、証跡参照、変更・検証 digest、主張レベル、source SHA、プライバシーフラグだけを持ちます。 |
| Reliable Mailbox v2 | ワーカーからオペレーターへの非同期メッセージを監査可能にする。 | message/correlation/causation/idempotency、TTL、状態、送信者、宛先、内容メタデータを持ちます。コマンド終了コードだけでは配信成功にしません。 |
| Checkpoint package v1 | 再起動後に安全に再開するためのパケット。 | 目的、フェーズ、次の一手、主張レベル、resume handle、source SHA、公開可能な変更ファイル、検証状態、未処理メッセージ、未解決質問を持ちます。 |
| Restore candidate v1 | セッションとrunを再起動後に見つけるためのLayer 1情報。 | pane/session ID、割り当てメタデータ、transcript ring要約、Context Capsule参照、Checkpoint参照だけを持ちます。列挙専用で、自動復元は行いません。生ログ、プロンプト本文、秘密情報、個人パスは保存しません。 |
| Context pressure status | 文脈破綻前に checkpoint / handoff を促す表示材料。 | usage、source、confidence、capsule age、checkpoint age、pending mailbox、未解決質問、状態、推奨アクションを分けます。不明な値は不明として出します。 |
| Summary quality gate | 要約を自動化に渡してよいかを決める決定的チェック。 | 状態、次の一手、証跡参照、鮮度、SHA 一致、検証矛盾なし、リスク/質問の分離、redaction を確認します。 |
| Split-worthiness policy | 作業を分割すべきかを提案する。 | 提案だけです。最終判断は常にオペレーターが持ちます。 |

## 必須の挙動

- 無効または古い capsule は router / operator automation に渡しません。
- mailbox は at-least-once と idempotency を前提にし、重複副作用を拒否します。
- checkpoint は provider 固有の compact hook に依存せず、再起動後の再開に使えます。
- restore candidate は SessionRegistry metadata と `winsmux runs --json` から列挙でき、生のterminal transcriptをコピーしません。不完全なrestore metadataは暗黙補完せず、候補から外します。
- context pressure は、根拠のない正確な数値を表示しません。
- summary quality が不合格の場合は、再要約またはオペレーターへのエスカレーションにします。
- split 提案は worker pane の自動作成や自動開始を行いません。

## リリース証跡

リリースゲートでは、schema test、mailbox v2 conversion test、checkpoint package test、privacy check、public-surface check、release/post-release smoke を確認します。

## Phase 0 の軽量baseline

v0.36.22 で残すのは、正式6ペインベンチマーク前の軽量baselineです。モデルの順位表や正式な測定結果は公開しません。

| 項目 | v0.36.22 のbaseline | 境界 |
|---|---|---|
| オペレーターへ渡す要約量 | Context Capsule の項目に収まる形へ制限します。 | ワーカーの生ログやプロンプト本文は capsule へコピーしません。 |
| ワーカー出力量 | ルーティング用artifactとして永続化しません。 | ワーカーごとの出力byte数は GA-readiness bench レーン(v0.36.43。2026-07-05 に v0.36.23 から再スコープ)の正式ベンチマークへ移します。 |
| 手作業のペイン間転送 | Reliable Mailbox v2 のメタデータで監査可能なメッセージへ置き換えます。 | message write 成功だけでは delivery 成功とみなしません。 |
| 引き継ぎと再開 | Checkpoint package v1 に resume handle、次の一手、source SHA、未処理メッセージ、未解決質問を残します。 | provider固有のcompact hookへ依存しません。 |
| タスク分割判断 | split-worthiness は提案に限定し、retry cost、context pressure、write conflict risk、unhealthy scope を根拠にします。 | 自動でペインを作成したり、オペレーター判断を迂回したりしません。 |
| 今回の検証コスト | `ledger_contract` 80件、mailbox/runs/explain対象Pester 5件、planning sync互換Pester 3件、desktop production buildが通過済みです。 | これは契約とbuildの確認であり、live providerや正式ベンチマークの測定ではありません。 |

正式ベンチマークは、これらの連携契約がデスクトップの標準経路で使えることを公開前ゲートで確認した後、GA-readiness bench レーン(v0.36.43。v0.36.39 の Harness Bench 製品化レーン完了後。決定記録: `docs/incidents/v03623-session-readiness/04-benchmark-readiness-gate.md`)で実行します。
