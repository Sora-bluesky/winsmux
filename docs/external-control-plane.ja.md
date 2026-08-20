# 外部コントロールプレーン API

winsmux は、デスクトップアプリと同じ Windows マシンで動く外部自動化クライアント向けに、ローカルの named pipe JSON-RPC エンドポイントを公開します。

すでに起動しているデスクトップ、または通常起動の新規インストール（起動前に `WINSMUX_CONTROL_PIPE_TOKEN` をセットしない）から、ソースを読まずに `desktop.operator.snapshot` まで到達できます。

## 伝送方式

- パイプ: `\\.\pipe\winsmux-control`
- プロトコル: JSON-RPC 2.0
- ネットワーク伝送: なし。localhost HTTP や WebSocket エンドポイントはありません。
- リモートクライアントは、ユーザーが承認したローカルブリッジを経由する必要があります。デスクトップアプリは、この pipe をネットワークへ公開しません。

## 起動モード

通常のデスクトップ起動では、プロセス環境に `WINSMUX_CONTROL_PIPE_TOKEN` は不要です。起動時、デスクトップアプリは `%LOCALAPPDATA%\winsmux\control-pipe\token` をユーザー専用 DACL（Windows における `0600` 相当）で作り、新しい現行トークンを書き、直前のトークンはプロセスメモリにだけ残します。直前値は、新しいトークンでの初回成功認証まで、またはプロセス時間 60 秒まで受け付け、その後破棄します。ログに出してよい印は `control-pipe token: rotated` だけです。トークン値も、展開済みファイルパスも書いてはいけません。

一部のランチャーは、いまもデスクトッププロセスに `WINSMUX_CONTROL_PIPE_TOKEN` をセットします。その明示 env は引き続き有効で、デスクトップ pipe と CLI の両方でトークンファイルより優先します。

## トークンの用意

保護対象は control-pipe トークンのバイト列です。信頼境界はローカルユーザープロファイルであり、git リポジトリでもプロジェクトの `.winsmux` でもありません。

発見経路はこの正確なパスだけです。

`%LOCALAPPDATA%\winsmux\control-pipe\token`

リポジトリ、プロジェクト `.winsmux`、`TEMP`、別ファイル名へ置いたファイルは勝ってはいけません。

デスクトップ pipe と `winsmux control-rpc` のトークン取得順:

1. 空でないプロセス環境変数 `WINSMUX_CONTROL_PIPE_TOKEN`（既存テストと明示ランチャーを維持）
2. それ以外は上記の正確なトークンファイル
3. どちらも無ければ安全側で失敗

トークン値を印刷しないでください。例の秘密スロットは `<token-file>` です。

## 認可

`desktop.control_plane.contract` だけはトークンなしで取得できます。それ以外のメソッドは `auth.token` を要求します。通常は `winsmux control-rpc` を使います。env 上書きがあればそれを、無ければ正確なトークンファイルを読んで `auth.token` を注入します。

外部契約は次の呼び出しで取得します。

```json
{"jsonrpc":"2.0","id":"contract","method":"desktop.control_plane.contract"}
```

この要求を named pipe 経由で送ると、`methods` には pipe の許可リストが受け付けるメソッドだけが入ります。契約の `auth.token_env` は `WINSMUX_CONTROL_PIPE_TOKEN`、`auth.token_file` は `%LOCALAPPDATA%\winsmux\control-pipe\token` です。

`desktop.control_plane.contract` 以外のメソッドでは、`params` の外側にローカル制御トークンを含めます。

```json
{"jsonrpc":"2.0","id":"capture","method":"pty.capture","params":{"paneId":"pane-1"},"auth":{"token":"<token-file>"}}
```

トークン値をシェル履歴に直接書かないでください。

## ゼロから operator-snapshot まで

残っているトークンファイルは生存証明ではありません。認証が必要なメソッドの前に、一度 `winsmux automation-pair` で所持証明してください。トークン値は印刷しないでください。

### 新規インストール

1. winsmux を入れ、デスクトップアプリを通常起動します。起動前に `WINSMUX_CONTROL_PIPE_TOKEN` をセットしないでください。
2. 発見します。

```powershell
winsmux automation-discover
```

`desktop_running` が true、`auth_source` が `"file"`、`connect_ready` が true であることを期待します。

3. 一度 pairing します。

```powershell
winsmux automation-pair
```

`paired` が true であることを期待します。

4. operator 出力を取得します。CLI は正確なトークンファイルを使います。

```powershell
winsmux operator-snapshot --lines 80
```

### すでに起動しているデスクトップ

デスクトップがすでに動いているかもしれないときは、まず `winsmux automation-discover` から始めます。`desktop_running` は named pipe が応答しているときだけ true です。

1. 発見します（上と同じコマンド）。
2. 一度 pairing します（`winsmux automation-pair`）。
3. operator 出力を取得します（`winsmux operator-snapshot --lines 80`）。

一部のランチャーは、いまも `WINSMUX_CONTROL_PIPE_TOKEN` をセットします。その env は引き続き有効で、トークンファイルより優先します。

同等の生 JSON-RPC:

```json
{"jsonrpc":"2.0","id":"operator-snapshot","method":"desktop.operator.snapshot","params":{"lines":80},"auth":{"token":"<token-file>"}}
```

## エラー意味論

非契約呼び出しは、使えるトークンが無い（env が空で正確なファイルも無い／空）、`auth.token` が無い、またはトークンが一致しないときに安全側で失敗します。pipe は既存の JSON-RPC 失敗閉のままです。エラーコードは `-32600`（Invalid Request）で、メッセージは `WINSMUX_CONTROL_PIPE_TOKEN` を名前で示します。CLI ヘルパーは `control-rpc requires WINSMUX_CONTROL_PIPE_TOKEN for non-contract methods` で失敗します。新しい公開エラーコードは追加しません。

## 公開メソッド

named pipe は、現時点で次のデスクトップメソッドを公開します。
このページのメソッド一覧は `docs/control-plane-contract.v2.json` と CI で照合されます。
v2 は、ハンドラが消費する同じ serde 型から導出したメソッドごとのパラメータ／結果スキーマを追加します。

- `desktop.control_plane.contract`
- `desktop.pairing.confirm`
- `desktop.summary.snapshot`
- `desktop.run.explain`
- `desktop.run.compare`
- `desktop.run.promote`
- `desktop.run.pick_winner`
- `desktop.operator.snapshot`
- `desktop.operator.submit`
- `desktop.voice.capture_status`
- `desktop.provider.capabilities`

operator メソッドは、外部エージェントが operator と会話するための専用経路です。

- `desktop.operator.snapshot` は operator ペインの直近出力を取得します。
- `desktop.operator.submit` は operator composer に 1 件のメッセージを書き込み、送信します。この API は常に operator ペインだけを対象にし、`paneId` / `pane_id` の上書きを拒否します。外部エージェントが operator を迂回して worker ペインへ直接書き込む用途には使えません。

外部エージェントは、通常は専用 CLI ヘルパーを使います。

```powershell
winsmux operator-snapshot --lines 80
winsmux operator-submit --text "Restore the six-pane orchestra and report can_dispatch."
```

このヘルパーは同じトークン優先順（env 上書き、無ければ正確なトークンファイル）を使い、
`desktop.operator.snapshot` / `desktop.operator.submit` だけを呼びます。
worker ペインの指定は受け付けません。独自の named pipe クライアントを実装する場合は、次の JSON-RPC を直接送れます。

```json
{"jsonrpc":"2.0","id":"operator-snapshot","method":"desktop.operator.snapshot","params":{"lines":80},"auth":{"token":"<token-file>"}}
```

```json
{"jsonrpc":"2.0","id":"operator-submit","method":"desktop.operator.submit","params":{"message":"Restore the six-pane orchestra and report can_dispatch."},"auth":{"token":"<token-file>"}}
```

同じ pipe は、ローカルペイン制御用に次の PTY メソッドも公開します。

- `pty.spawn`
- `pty.write`
- `pty.resize`
- `pty.capture`
- `pty.respawn`
- `pty.close`

## Surface 互換マトリクス

この surface 互換マトリクスは、チェックイン済み v2 契約成果物に対して CI でゲートします。
契約行はトークンなしで発見できます。どの行も汎用 CLI JSON-RPC ヘルパーから到達できます。discover コマンドは生存確認であり、行ではありません。

| Method | Pipe | CLI | MCP |
| --- | --- | --- | --- |
| desktop.control_plane.contract | yes | automation-contract | winsmux_automation_contract |
| desktop.summary.snapshot | yes | control-rpc only | — |
| desktop.run.explain | yes | control-rpc only | — |
| desktop.run.compare | yes | control-rpc only | — |
| desktop.run.promote | yes | control-rpc only | — |
| desktop.run.pick_winner | yes | control-rpc only | — |
| desktop.voice.capture_status | yes | control-rpc only | — |
| desktop.provider.capabilities | yes | control-rpc only | — |
| pty.spawn | yes | control-rpc only | — |
| pty.write | yes | control-rpc only | — |
| pty.resize | yes | control-rpc only | — |
| pty.capture | yes | control-rpc only | — |
| pty.respawn | yes | control-rpc only | — |
| pty.close | yes | control-rpc only | — |
| desktop.operator.snapshot | yes | operator-snapshot (ps1) | — |
| desktop.operator.submit | yes | operator-submit (ps1) | — |
| desktop.pairing.confirm | yes | automation-pair | winsmux_automation_pair |

## 内部専用メソッド

Tauri アプリは、より広い内部 `desktop_json_rpc` 面を使います。この内部面は Tauri `invoke` 経由でデスクトップ WebView から利用できますが、そのまま外部 pipe 契約になるわけではありません。

次のメソッドは、現時点では named pipe から公開しません。

- `desktop.workers.status`
- `desktop.workers.start`
- `desktop.runtime.roles.apply`
- `desktop.dogfood.event`
- `desktop.explorer.list`
- `desktop.editor.read`
- Agent Vault、セッション検索、再開メタデータ、ドラッグ復元に関するメソッド
- Feed、通知、View メニュー状態に関するメソッド

たとえば `desktop.editor.read` と `desktop.explorer.list` はローカルプロジェクトファイルを読みます。外部向けの認可モデルを別途設計するまでは、Tauri デスクトップの内部コンテキストに限定します。

`v0.36.8` で追加された Agent Vault、セッション検索と絞り込み、再開メタデータ、ドラッグ復元、Feed、通知連携、ワーカーステータス表示の切り替えは、現時点ではデスクトップ内部の UI 面です。外部認可モデルを明示するまでは、named pipe JSON-RPC メソッドとして公開しません。

## 企業向けワーカーポリシー

外部クライアントは、プロンプトの指示だけでネットワーク、書き込み、プロバイダー利用を許可しません。準備済みの `isolated-enterprise` 実行では、ブローカー契約と有効なブローカートークンを用意した後、オペレーターが `winsmux workers policy baseline` でアクセス範囲を定義します。このポリシー成果物は、必須チェックとロールごとの証跡をプロンプトの外側に記録し、`winsmux workers status --json` の `policy` として最新状態を出します。

このコマンドは実行前に安全側で失敗します。実行が `isolated-enterprise` ではない場合、ブローカー契約がない場合、ブローカートークンがない場合や期限切れの場合、不正なポリシー値を渡した場合、または実行境界の内側にリパースポイントがある場合は、ポリシーを書きません。外部ブリッジは、プロンプト指示を広げて再試行するのではなく、その停止理由を表示する必要があります。

## MCP アダプター境界

同梱の MCP サーバーは、上流の MCP JSON-RPC 形状と stdio 伝送に薄く重ねるローカルアダプターです。winsmux 固有のコードは、引数配列でのコマンド実行、入力検証、ローカル安全方針に限定します。上流プロトコルクライアントや公式伝送の動作で扱える場合は、ローカル互換コードを増やす前にそちらを優先します。

MCP クライアントは `winsmux_automation_contract`、`winsmux_automation_discover`、`winsmux_automation_pair` で同じ named-pipe 契約に届きます。各ツールは対応するネイティブサブコマンド（`winsmux automation-contract` / `automation-discover` / `automation-pair`）を実行し、JSON を返します。PowerShell は通しません。

## クライアント互換性

ローカル自動化クライアントは、同じ Windows ホスト上で動き、named pipe 上の JSON-RPC を実装していれば接続できます。最初に `desktop.control_plane.contract` を呼び、返された `methods` からクライアント機能を構成してください。同じ文書の CI 検査済みコピーが `docs/control-plane-contract.v2.json` にあります。`control_pipe_contract()` の pretty-print で、ライブの pipe 応答と一致し続けます。

空でない `WINSMUX_CONTROL_PIPE_TOKEN` も正確なトークンファイルも認証に使えない場合、または要求に `auth.token` がない場合、契約取得以外の呼び出しは安全側で失敗します。

エージェント CLI も、ユーザーがローカルコマンド実行を許可した場合は、ローカルシェルやツール呼び出しから pipe を操作できます。専用の特権 API 面はありません。他のローカルクライアントと同じ外部契約だけを見ます。

ワーカー起動承認とローカルファイル読み取り UI 操作は、引き続きデスクトップアプリが必須の操作面です。外部クライアントは、pipe 契約に明記されていない内部 Tauri メソッドを利用できると仮定しないでください。

## 終了時の動作

デスクトップアプリの終了時、winsmux はサマリーストリームの停止を要求し、実行中のネイティブ音声キャプチャを止めます。さらに、登録済みの PTY ペインをすべて取り出し、ワーカーペインの子プロセスを終了させ、短時間だけ終了完了を待ちます。

外部クライアントは、切断前に `pty.close` で個別ペインを明示的に閉じることもできます。デスクトップアプリを閉じる操作は、そのデスクトップセッションが作成した PTY ペインの最終的な片付け経路です。
