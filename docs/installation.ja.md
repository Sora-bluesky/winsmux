# インストール

`winsmux` は Windows 向けに 2 つの経路で配布します。

- GitHub Release から入手するデスクトップアプリのインストーラー
- CLI 中心の利用やスクリプト導入に使う npm パッケージ

## 動作要件

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- npm 経路で入れる場合は Node.js と `npm`

Rust は、ランタイムをソースからビルドする時だけ必要です。

Colab 対応のモデルワーカーを使う場合は、`H100` または `A100` へ接続した
Colab ノートブック、またはアダプターが管理する同等の実行環境も用意します。
この経路では、Windows PC 側にローカル LLM ランタイムは不要です。

## クイックインストール

デスクトップアプリ:

1. 対象の GitHub Release から `winsmux_<version>_x64-setup.exe` を取得します。
2. Windows が発行元または SmartScreen の警告を出した場合は、`SHA256SUMS-desktop` と照合します。
3. インストーラーを実行し、起動後にプロジェクトフォルダーを選びます。

CLI パッケージ:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

## デスクトップアプリのインストーラー

デスクトップアプリを使う場合は、対象の GitHub Release から Windows 用インストーラーを取得します。

- `winsmux_<version>_x64-setup.exe`: 通常の対話式インストーラー
- `winsmux_<version>_x64_en-US.msi`: MSI 配布用
- `SHA256SUMS-desktop`: チェックサム確認用

通常の 1 台利用では setup 形式の実行ファイルを使います。配布ツールが MSI を前提にしている場合は MSI を使います。

Windows が発行元または SmartScreen の警告を出した場合は、同じ GitHub Release の `SHA256SUMS-desktop` と照合してから実行してください。各リリースの署名方針はリリースノートに記載します。

`v1.0.0` のデスクトップ配布方針は次の通りです。

- 主な配布物: `winsmux_<version>_x64-setup.exe`
- 配布ツール向けの配布物: `winsmux_<version>_x64_en-US.msi`
- 確認用の配布物: `SHA256SUMS-desktop`
- 署名方針: 安定した署名証明書を用意するまではリリースごとに明記
- 更新方法: 新しいデスクトップ版インストーラーを既存インストールの上から実行
- ポータブル版の扱い: 既定ではデスクトップアプリのポータブル版は公開しません。必要な場合は release の `winsmux-x64.exe` または npm パッケージを使います。

## CLI パッケージでのインストール

```powershell
npm install -g winsmux
winsmux install --profile full
```

npm コマンドは同梱されたインストーラーに処理を渡します。インストーラーは npm パッケージと同じ Git tag に固定されます。

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

デスクトップアプリを更新する場合は、新しい GitHub Release のインストーラーを取得し、既存インストールの上から実行します。プロジェクトリポジトリ、エージェント CLI、それぞれの認証保存先は削除しません。

## アンインストール

```powershell
winsmux uninstall
```

アンインストールは winsmux の支援ファイルを削除します。エージェント CLI 本体や、それぞれの認証保存先は削除しません。

デスクトップアプリは Windows Settings または MSI 配布ツールから `winsmux` をアンインストールしてください。プロジェクトリポジトリ、エージェント CLI、それぞれの認証保存先は削除しません。

## 確認

```powershell
winsmux version
winsmux doctor
```

インストール後または更新後は `winsmux doctor` を実行してください。PowerShell の起動、リポジトリ設定、プロセス数、ワークスペースの前提条件を確認できます。

Colab 対応ワーカースロットでは、次も実行します。

```powershell
winsmux workers doctor
```

Colab の診断では、アダプターコマンドの不在、認証不足、`H100` / `A100`
ランタイム不一致をワーカー状態として表示します。ローカル LLM ランタイムへ
黙って切り替えることはしません。
