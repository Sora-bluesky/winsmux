# 外部コントロールプレーン API

winsmux は、デスクトップアプリと同じ Windows マシンで動く外部自動化クライアント向けに、ローカルの named pipe JSON-RPC エンドポイントを公開します。

## 伝送方式

- パイプ: `\\.\pipe\winsmux-control`
- プロトコル: JSON-RPC 2.0
- ネットワーク伝送: なし。localhost HTTP や WebSocket エンドポイントはありません。
- リモートクライアントは、ユーザーが承認したローカルブリッジを経由する必要があります。デスクトップアプリは、この pipe をネットワークへ公開しません。

外部契約は次の呼び出しで取得します。

```json
{"jsonrpc":"2.0","id":"contract","method":"desktop.control_plane.contract"}
```

この要求を named pipe 経由で送ると、`methods` には pipe の許可リストが受け付けるメソッドだけが入ります。

## 公開メソッド

named pipe は、現時点で次のデスクトップメソッドを公開します。

- `desktop.control_plane.contract`
- `desktop.summary.snapshot`
- `desktop.run.explain`
- `desktop.run.compare`
- `desktop.run.promote`
- `desktop.run.pick_winner`
- `desktop.voice.capture_status`

同じ pipe は、ローカルペイン制御用に次の PTY メソッドも公開します。

- `pty.spawn`
- `pty.write`
- `pty.resize`
- `pty.capture`
- `pty.respawn`
- `pty.close`

## 内部専用メソッド

Tauri アプリは、より広い内部 `desktop_json_rpc` 面を使います。この内部面は Tauri `invoke` 経由でデスクトップ WebView から利用できますが、そのまま外部 pipe 契約になるわけではありません。

次のメソッドは、現時点では named pipe から公開しません。

- `desktop.workers.status`
- `desktop.workers.start`
- `desktop.runtime.roles.apply`
- `desktop.dogfood.event`
- `desktop.explorer.list`
- `desktop.editor.read`

たとえば `desktop.editor.read` と `desktop.explorer.list` はローカルプロジェクトファイルを読みます。外部向けの認可モデルを別途設計するまでは、Tauri デスクトップの内部コンテキストに限定します。

## クライアント互換性

OpenClaw 型のローカルクライアントは、同じ Windows ホスト上で動き、named pipe 上の JSON-RPC を実装していれば接続できます。最初に `desktop.control_plane.contract` を呼び、返された `methods` からクライアント機能を構成してください。

Codex と Claude Code も、ユーザーがローカルコマンド実行を許可した場合は、ローカルシェルやツール呼び出しから pipe を操作できます。専用の特権 API 面はありません。他のローカルクライアントと同じ外部契約だけを見ます。

ワーカー起動承認とローカルファイル読み取り UI 操作は、引き続きデスクトップアプリが必須の操作面です。外部クライアントは、pipe 契約に明記されていない内部 Tauri メソッドを利用できると仮定しないでください。
