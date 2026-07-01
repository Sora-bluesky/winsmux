# インストール

`winsmux` は Windows 向けに 2 つの経路で配布します。通常の画面操作でオペレーターとワーカーを扱う場合は、デスクトップアプリのインストーラーを使います。CLI 中心、スクリプト実行、ヘッドレス運用では npm パッケージを使います。

- 推奨経路: GitHub Release から入手するデスクトップアプリのインストーラー
- 別経路: CLI 中心の利用やスクリプト導入に使う Windows 向け npm パッケージ

| 用途 | インストール経路 | 起動経路 |
| --- | --- | --- |
| 通常の画面操作でオペレーターとワーカーを使う | [最新リリース](https://github.com/Sora-bluesky/winsmux/releases/latest) の `winsmux_..._x64-setup.exe` を実行 | インストール済みの `winsmux` デスクトップアプリを開き、プロジェクトフォルダーを選択 |
| CLI 中心、ヘッドレス、スクリプト運用 | `npm install -g winsmux` の後に `winsmux install --profile full` | プロジェクトディレクトリで `winsmux init` と `winsmux launch` を実行 |
| デスクトップオペレーターを外部自動化から使う | 先にデスクトップアプリをインストールして起動 | デスクトップオペレーターが表示された後、ローカル control pipe に接続 |

`winsmux launch` は管理対象の Windows Terminal ワークスペースを起動します。デスクトップアプリは開きません。

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

1. [最新リリース](https://github.com/Sora-bluesky/winsmux/releases/latest) を開きます。
2. Assets から `winsmux_..._x64-setup.exe` という名前のインストーラーを取得します。
3. Windows が発行元または SmartScreen の警告を出した場合は、同じリリースの `SHA256SUMS-desktop` と照合します。
4. インストーラーを実行し、インストール済みの winsmux アプリを開いて、起動後にプロジェクトフォルダーを選びます。

デスクトップアプリは、通常の Windows アプリとしてインストールされていることを確認します。

- Windows 検索で `winsmux` というアプリ名が見つかることを確認します。
- Windows の「設定」>「アプリ」>「インストールされているアプリ」に `winsmux` が表示されることを確認します。
- Windows 検索にバージョン番号が出る必要はありません。バージョン確認が必要な場合は、アプリ、インストーラー名、または「インストールされているアプリ」の詳細を確認します。
- インストール済みアプリを開いたとき、localhost 接続エラーや別のコンソールウィンドウではなく、winsmux のデスクトップ画面が表示されることを確認します。

CLI パッケージ:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

その後、エージェントに作業させたいプロジェクトへ移動し、その場所から
CLI で管理するワークスペースを起動します。この経路ではデスクトップアプリは開きません。

```powershell
cd <project>
winsmux init
winsmux launch
```

## デスクトップアプリのインストーラー

推奨するデスクトップアプリ経路では、[最新リリース](https://github.com/Sora-bluesky/winsmux/releases/latest) から Windows 用インストーラーを取得します。過去版が必要な場合は [Releases 一覧](https://github.com/Sora-bluesky/winsmux/releases) から対象の版を開きます。

- `winsmux_..._x64-setup.exe`: 通常の対話式インストーラー
- `winsmux_..._x64_en-US.msi`: MSI 配布用
- `SHA256SUMS-desktop`: チェックサム確認用

通常の 1 台利用では setup 形式の実行ファイルを使います。配布ツールが MSI を前提にしている場合は MSI を使います。

setup 形式の実行ファイルは、英語と日本語のインストーラー画面に対応します。
インストール画面またはアンインストール画面を開く前に、言語選択を表示します。

Windows が発行元または SmartScreen の警告を出した場合は、同じ GitHub Release の `SHA256SUMS-desktop` と照合してから実行してください。各リリースの署名方針はリリースノートに記載します。

`v1.0.0` 系で有効なデスクトップ配布方針は次の通りです。

- 主な配布物: `winsmux_..._x64-setup.exe`
- 配布ツール向けの配布物: `winsmux_..._x64_en-US.msi`
- 確認用の配布物: `SHA256SUMS-desktop`
- setup 形式の実行ファイルの言語: 英語と日本語。言語選択を有効にします。
- 署名方針: 安定した署名証明書を用意するまではリリースごとに明記
- 更新方法: 新しいデスクトップ版インストーラーを既存インストールの上から実行
- ポータブル版の扱い: 既定ではデスクトップアプリのポータブル版は公開しません。必要な場合は release の `winsmux-x64.exe` または `winsmux-arm64.exe` の core binary、または npm パッケージを使います。

`v1.0.0` 以降の公開配布は、インストーラーを主経路にします。完全な実装ソース一式は、公開リリース面には含めません。公開配布と再配布の境界は [公開配布の境界](source-access.ja.md) を参照してください。

## CLI パッケージでのインストール

```powershell
npm install -g winsmux
winsmux install --profile full
```

npm コマンドは同梱されたインストーラーに処理を渡します。インストーラーは npm パッケージと同じ Git tag に固定されます。リポジトリ内の `packages/winsmux` ディレクトリを直接 publish するのではなく、リリース時に `scripts/stage-npm-release.mjs` が npm 用 tarball を作成し、その段階で release tag に固定した `install.ps1` を追加します。

インストール後は、作業対象のプロジェクトディレクトリへ移動して、管理対象
ワークスペースを起動します。

```powershell
cd <project>
winsmux init
winsmux launch
```

`winsmux launch` が CLI 経路の公開起動コマンドです。初回確認を行い、
管理された Windows Terminal ワークスペースを起動します。デスクトップアプリは
別経路です。GitHub Release からデスクトップアプリを入れた場合は、アプリを開き、
同じプロジェクトフォルダーを選択して画面上の管制面を使います。

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

デスクトップアプリは、`v0.36.23` 以降で GitHub Releases にある新しい Windows セットアップインストーラーを確認します。更新がある場合は、アプリ下部に小さな更新アクションを表示し、確認ダイアログを開き、進捗を表示しながらインストーラーをダウンロードします。リリースメタデータにチェックサムがある場合は検証し、インストーラーを起動して、実行中のアプリを置き換えられるように winsmux を終了します。`v0.36.23` より前の公開済みビルドは、新しいインストーラーを既存インストールの上から実行して更新します。

この更新フローは、プロジェクトリポジトリ、エージェント CLI、それぞれの認証保存先を削除しません。

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
