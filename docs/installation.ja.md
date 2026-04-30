# インストール

`winsmux` は Windows を主対象にした npm package として配布します。

## 動作要件

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- Node.js と `npm`

Rust は、ランタイムをソースからビルドする時だけ必要です。

## インストール

```powershell
npm install -g winsmux
winsmux install --profile full
```

npm コマンドは同梱されたインストーラーに処理を渡します。インストーラーは npm package と同じ release tag に固定されます。

## インストールプロファイル

| プロファイル | 入るもの | 向いている用途 |
| ------- | -------- | ----------- |
| `core` | ランタイム、ラッパースクリプト、`PATH` 設定、基本設定 | Windows native のターミナルランタイムだけが必要 |
| `orchestra` | `core` と、オーケストレーション用スクリプト、Windows Terminal プロファイル | 1 人のオペレーターが管理ペインを動かす |
| `security` | `core` と、vault、監査用スクリプト | フルのオーケストレーションなしで資格情報を扱う |
| `full` | `core`、`orchestra`、`security` | 標準的な winsmux 設定で始める |

## 更新

```powershell
winsmux update
winsmux update --profile orchestra
```

プロファイルを指定しない場合、`winsmux update` は前回記録したプロファイルを使います。プロファイルを変更した場合、選択対象外になった支援スクリプトはインストール先から削除されます。

## アンインストール

```powershell
winsmux uninstall
```

アンインストールは winsmux の支援ファイルを削除します。エージェント CLI 本体や、それぞれの認証保存先は削除しません。

## 確認

```powershell
winsmux version
winsmux doctor
```

インストール後または更新後は `winsmux doctor` を実行してください。PowerShell の起動、リポジトリ設定、プロセス数、ワークスペースの前提条件を確認できます。
