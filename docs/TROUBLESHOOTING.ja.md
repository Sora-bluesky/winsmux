# トラブルシューティング

winsmux のインストール、起動、ペイン、資格情報、リリース確認が期待どおりに動かない時に使います。

## 起動時の問題

この章の `winsmux launch` は npm/CLI パッケージ経路のコマンドです。管理対象の
Windows Terminal ワークスペースを起動します。デスクトップアプリは開きません。
画面上の管制面を確認する場合は、インストール済みのデスクトップアプリを直接開きます。

### デスクトップアプリが localhost 接続エラー、空白画面、またはフリーズになる

通常のグラフィカルな入口はデスクトップアプリです。[最新リリース](https://github.com/Sora-bluesky/winsmux/releases/latest) の
Assets から `winsmux_..._x64-setup.exe` をインストールし、スタートメニューまたは
デスクトップショートカットから `winsmux` アプリを開きます。`winsmux launch` は
CLI の入口であり、デスクトップアプリは開きません。

インストール後は、Windows 検索で `winsmux` というアプリ名が見つかれば十分です。
Windows 検索にバージョン番号が出る必要はありません。インストール情報を確認する場合は、
Windows の「設定」>「アプリ」>「インストールされているアプリ」を確認します。

デスクトップアプリが localhost 接続エラー、空白画面、または応答なしになる場合:

1. `winsmux` デスクトップウィンドウを閉じます。
2. 古いデスクトッププロセスが残っていないか確認します。

   ```powershell
   Get-Process winsmux-app -ErrorAction SilentlyContinue |
     Select-Object Id,ProcessName,Path,StartTime
   ```

3. 表示されたプロセスが、いま開いたインストール済みの winsmux デスクトップアプリであると確認できる場合だけ、Windows タスク マネージャーから終了して、もう一度 winsmux を開きます。
4. デスクトップアプリと一緒に黒い PowerShell、Windows Terminal、または WebView2 のコンソールウィンドウが出る場合は、winsmux を閉じて Issue を作成してください。通常のデスクトップ起動で見えるウィンドウは winsmux 本体だけです。
5. Windows 再起動後も再現する場合、通常の復旧では [最新リリース](https://github.com/Sora-bluesky/winsmux/releases/latest) のデスクトップインストーラーを再インストールします。特定バージョンの不具合を再現している場合は、その対象リリースのインストーラーを使います。`.winsmux/startup-journal.log`、`.winsmux/manifest.yaml`、インストーラーのバージョン、スクリーンショットを添えて報告してください。

### `Orchestra already starting (lock exists)`

原因: 前回の起動がロックファイルを消す前に終了しました。

対処:

```powershell
winsmux list
Get-Process winsmux-app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path,StartTime
```

このプロジェクトの winsmux セッションが生きておらず、同じプロジェクトを使っているデスクトップアプリも起動していないと確認できた場合だけ、ロックを削除します。

```powershell
Remove-Item .winsmux/orchestra.lock -Force
```

その後、CLI ワークスペースを再起動します。

```powershell
winsmux launch
```

### ペインが空、またはエージェントが起動しない

原因: ペインの shell が準備できる前に、エージェントの起動コマンドを送った可能性があります。

対処:

```powershell
winsmux doctor
winsmux launch
```

特定のペインだけが怪しい場合は、次の指示を送る前に出力を確認します。

```powershell
winsmux read <pane> 60
```

### `pwsh.exe` が `0xc0000142` で失敗する

これは Windows status `STATUS_DLL_INIT_FAILED` です。`pwsh.exe` が必要とする DLL を Windows が初期化できなかったことを示します。単体の PowerShell は動くのに winsmux の起動だけ失敗する場合、特定の起動経路、親プロセス、プロファイル、環境変数、Windows Terminal のペイン起動コマンドが原因になっている可能性があります。

まず単体の PowerShell を確認します。

```powershell
where.exe pwsh
pwsh -NoProfile -NoLogo -Command "Write-Output `$PSVersionTable.PSVersion"
```

winsmux の診断を確認します。

```powershell
winsmux doctor
```

直近の Windows application error を確認します。

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-6)} |
  Where-Object { $_.Message -match 'pwsh.exe|0xc0000142' -or $_.ProviderName -match 'Application Error|Windows Error Reporting' } |
  Select-Object -First 20 TimeCreated,ProviderName,Id,LevelDisplayName,Message
```

単体の PowerShell も失敗する場合は、PowerShell 7 の修復または再インストールを行い、Windows を再起動してください。単体では動く場合は、Windows Terminal プロファイルのコマンドラインと、winsmux のペイン起動ログを確認してください。

## ペインとサンドボックスの問題

### Codex が毎回承認を求める

原因: Codex が権限の強い Windows サンドボックスに設定されている可能性があります。

対処:

```toml
[windows]
sandbox = "unelevated"
```

### Codex ペイン内でファイル書き込みや git コマンドが失敗する

症状:

- `.git/worktrees/*/index.lock` を作れず、`git add` や `git commit` が失敗する。
- PowerShell が Constrained Language Mode になっている。
- `Set-Content`、`Out-File`、`[IO.File]::*` が失敗する。

対処:

- ペイン内では編集と限定的な確認に留める。
- リポジトリ単位の `git add`、`git commit`、`git push` は通常のシェルから実行する。
- ペイン内でのファイル書き込みは `apply_patch` または `cmd /c` を使う。

### デスクトップの子プロセス回収を確認する

デスクトップアプリを閉じると、winsmux はサマリーストリームを止め、実行中のネイティブ音声キャプチャを止めます。さらに、PTY ペイン登録を空にし、ワーカーペインの子プロセスを終了させ、短時間だけ終了完了を待ちます。終了が重く見える場合は、数秒待ってからプロセス状態を確認してください。

漏れを調べる場合は、停止する前に winsmux が起動したプロセスだけを確認してください。

```powershell
Get-Process winsmux-app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,Path,StartTime
```

現在の winsmux デスクトップセッションだと判断できるプロセスだけを停止してください。無関係なターミナル、パッケージマネージャー、他プロジェクトの開発ツールは停止しないでください。

## 資格情報の問題

### vault のキーが見つからない

原因: Windows Credential Manager にキーが保存されていません。

対処:

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux は他の CLI からトークンを取り出しません。詳しくは [認証方針](authentication-support.ja.md) を参照してください。

## 診断コマンド

```powershell
winsmux doctor
winsmux version
winsmux list
winsmux read <pane> 60
```

`winsmux read` の最後の数値は、読み取る末尾行数です。

主なローカルログ:

| ファイル | 用途 |
| ---- | ------- |
| `.winsmux/startup-journal.log` | 起動失敗の履歴 |
| `.winsmux/manifest.yaml` | 現在のワークスペース状態 |
