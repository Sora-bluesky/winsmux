# winsmux 公開ドキュメント

このページは、winsmux の公開ドキュメントの目次です。

## まず読む

- [クイックスタート](quickstart.ja.md) - デスクトップアプリまたは CLI パッケージのインストール、プロジェクト設定、管理ワークスペース起動、最初のペイン操作までを進めます。
- [インストール](installation.ja.md) - 動作要件、デスクトップインストーラー、CLI プロファイル、更新、アンインストール、パッケージの扱いを説明します。
- [カスタマイズ](customization.ja.md) - 起動プリセット、ワークツリー方針、エージェントスロット、資格情報、デスクトップ設定を調整します。
- [Google Colab ワーカー](google-colab-workers.ja.md) - `H100` / `A100` での単発ワーカー実行、アップロード、ダウンロード、モデルメタデータを準備します。

## 仕組みを理解する

- [オペレーターモデル](operator-model.md) - オペレーター層、管理ペイン層、証跡契約、デスクトップ方針を説明します。
- [認証方針](authentication-support.ja.md) - 対応する認証方式と、同じ PC 上での対話利用に限る認証の境界を説明します。
- [プロバイダーとモデルの対応方針](provider-and-model-support.ja.md) - クラウド型エージェント CLI、Colab 上のモデル対象、将来のローカル LLM、モデルファミリーのメタデータを説明します。
- [外部コントロールプレーン API](external-control-plane.ja.md) - 外部自動化クライアント向けのローカル named pipe JSON-RPC 契約を説明します。
- [リポジトリの公開面ポリシー](repo-surface-policy.md) - 追跡対象ファイルの公開面、実行時契約面、コントリビューター向け面を分けます。

## 困った時

- [トラブルシューティング](TROUBLESHOOTING.ja.md) - 起動、PowerShell、ペイン、資格情報、リリースの問題を切り分けます。
- [ランタイム機能](../core/docs/features.md) - ターミナルランタイムの機能リファレンスです。
- [ランタイム設定](../core/docs/configuration.md) - tmux 互換ランタイムの設定です。
- [tmux 互換性](../core/docs/compatibility.md) - tmux 互換の実行時挙動と、削除済みの旧コマンド名を説明します。
