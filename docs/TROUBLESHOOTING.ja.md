# トラブルシューティング

winsmux のインストール、起動、ペイン、資格情報、リリース確認が期待どおりに動かない時に使います。

## 起動時の問題

### `Orchestra already starting (lock exists)`

原因: 前回の起動がロックファイルを消す前に終了しました。

対処:

```powershell
Remove-Item .winsmux/orchestra.lock -Force
```

その後、再起動します。

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

### Codex pane 内で file write や git command が失敗する

症状:

- `.git/worktrees/*/index.lock` を作れず、`git add` や `git commit` が失敗する。
- PowerShell が Constrained Language Mode になっている。
- `Set-Content`、`Out-File`、`[IO.File]::*` が失敗する。

対処:

- pane 内では編集と限定的な確認を続ける
- repository-level の `git add`、`git commit`、`git push` は通常の shell から実行する
- pane 内の file write は `apply_patch` または `cmd /c` を使う

## 資格情報の問題

### vault key が見つからない

原因: Windows Credential Manager に key が保存されていません。

対処:

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux は他の CLI から token を取り出しません。詳しくは [認証方針](authentication-support.ja.md) を参照してください。

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
