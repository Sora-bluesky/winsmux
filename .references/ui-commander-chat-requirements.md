# Commander チャット UI 要件

> 作成: 2026-04-05
> ユーザー要望に基づく

## 課題（CLI の制約）

1. **日本語入力が困難**: CLI では長文日本語入力に Ctrl+G で Notepad を起動する必要がある
2. **画像貼り付け不可**: スクリーンショット等を直接貼れない。ファイルパスで指定が必要
3. **スクロール問題**: 長時間セッションでスクロールが効かなくなる (#218)
4. **テキストコピー不能**: 出力テキストの選択・コピーができなくなる (#218)

## 要件

### 日本語入力
- Tauri の WebView でネイティブテキスト入力（IME 完全対応）
- textarea ベースの入力欄（複数行対応）
- Enter で送信、Shift+Enter で改行
- 入力履歴（↑↓キー）

### 画像入力
- ドラッグ&ドロップで画像添付
- クリップボードから Ctrl+V で画像ペースト
- 添付画像のプレビュー表示
- Claude Code の画像入力 API と連携

### テキスト出力
- 仮想スクロール（大量出力でもパフォーマンス維持）
- テキスト選択・コピー対応
- Markdown レンダリング（コードブロック、テーブル等）
- 折りたたみ可能なツール呼び出し結果

## 実装方針

Commander ペインを xterm.js ターミナルではなく、専用チャット UI コンポーネントにする。
他のペイン（Builder, Reviewer 等）は従来通り xterm.js ターミナル。

### 技術スタック
- Tauri WebView（フロントエンド）
- textarea + contenteditable for input
- Clipboard API for image paste
- Drag and Drop API for image attach
- Virtual scrolling (intersection observer) for output

## 対応バージョン

v0.19.0〜v0.20.0 のスコープに含める予定。
