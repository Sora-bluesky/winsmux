# 認証サポート方針

winsmux は、複数の CLI エージェントを安全に運用するための統制基盤です。  
この前提では、winsmux 自身が OAuth ログインを代行したり、認証情報を抽出・中継したりする設計は採りません。

## 基本方針

- winsmux が正式にサポートするのは、**認証方式ごとの利用形態**です
- CLI 自体がその認証方式を持っていても、その認証方式を winsmux が正式に支えるとは限りません
- winsmux は CLI を起動し、状態を確認し、比較し、統制します
- winsmux 自身は OAuth の仲介役にはなりません

## 対応マトリクス

| ツール | 認証方式 | winsmux での扱い |
| ------- | ------- | ------- |
| Claude Code | API key / 公式の企業向け認証 | 正式サポート |
| Claude Code | Pro / Max OAuth | サポート対象外 |
| Codex CLI | API key | 正式サポート |
| Codex CLI | ChatGPT OAuth | 当該 PC での対話利用のみ |
| Gemini CLI | Gemini API key | 正式サポート |
| Gemini CLI | Vertex AI | 正式サポート |
| Gemini CLI | Google OAuth | サポート対象外 |

## 用語の意味

### 正式サポート

winsmux の標準の使い方として案内する認証方式です。

- pane 実行に使えます
- 比較や複数エージェント運用に使えます
- 起動前の確認でも許可されます

### 当該 PC での対話利用のみ

その CLI 自身が、その PC 上で、公式のログイン手順を完了している場合に限って使えます。

これは次を意味します。

- 許されること
  - ユーザーが自分の PC で公式 CLI を起動する
  - その CLI 自身が公式のログイン手順を行う
  - ログイン済みの同じ CLI を winsmux が起動・監視する
- 許されないこと
  - winsmux がログイン画面を肩代わりする
  - winsmux が認証完了を受け取る URL を受信する
  - winsmux が認証情報の保存場所から token を取り出す
  - winsmux が token を他のペインや他のユーザーに共有する

### サポート対象外

winsmux の標準の使い方としては案内しない認証方式です。

- 起動前の確認で止める対象です
- 標準の使い方には載せません
- 比較や複数エージェント運用の既定導線には含めません

## winsmux がやらないこと

winsmux は次を行いません。

- OAuth ログインの代行
- 認証完了を受け取る URL の受信
- 認証情報の保存場所からの token 抽出
- token の中継や共有
- consumer OAuth を複数ペイン運用の共有資格情報として扱うこと

## 起動前の確認での扱い

起動前の確認では、CLI 名だけでなく認証方式も見ます。

例:

- `gemini-api-key` は許可
- `gemini-vertex` は許可
- `gemini-google-oauth` は正式サポート外として停止
- `codex-chatgpt-local` はその PC 上での対話利用のみ
- `claude-pro-max-oauth` は正式サポート外

## 用語統一

この文書と `README.ja.md` では、次の日本語に統一します。

- control plane → 統制基盤
- orchestration → 複数エージェント運用
- launcher → 起動導線
- preflight → 起動前の確認
- dispatch → 実行の振り分け
- operator docs → オペレーター向け説明
- credential store → 認証情報の保存場所
- callback URL / localhost redirect → 認証完了を受け取る URL
- local interactive only → 当該 PC での対話利用のみ
- fail-closed → 条件を満たさない場合は停止
