# コンテキスト継続性と信頼できる非同期連携

winsmuxは、複数ペインの作業を再開・ルーティング・レビューするために必要な文脈だけを残すための契約を定義します。生の会話ログ、プロンプト本文、秘密情報、ローカルの個人パスは保存しません。


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

詳しい操作は[オペレーターモデル](../operator-model.md)を参照してください。
