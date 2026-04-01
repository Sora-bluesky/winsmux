# Pane Border Guide

psmux の pane border label を使うと、各ペインの上端または下端に `builder-1` や `reviewer` のような名前を表示できます。winsmux では `psmux-bridge name` と `select-pane -T` の両方でこのタイトルを設定できます。

この機能は、`pane-border-format` と `pane-border-status` を表示できる psmux ビルドが前提です。ラベルが見えない場合は、まず fork 版または対応済みビルドを使っているか確認してください。

## 1. `.psmux.conf` の設定

最小構成はこれです。

```tmux
set -g pane-border-status top
set -g pane-border-format " #{pane_title} "
```

見た目も含めて設定するなら、たとえば次のようにします。

```tmux
set -g pane-border-style "fg=colour240"
set -g pane-active-border-style "fg=colour4"
set -g pane-border-lines heavy
set -g pane-border-status top
set -g pane-border-format " #{pane_title} "
```

タイトルが空のときだけパス名にフォールバックしたいなら、条件式は次の形にしてください。

```tmux
set -g pane-border-format " #{?pane_title,#{pane_title},#{b:pane_current_path}} "
```

`#{?condition,then,else}` が tmux/psmux の条件式です。`#{?#{pane_title},...}` のような入れ子条件にはしないほうが安全です。

設定変更後は新しいセッションで確認するか、セッション内で再読み込みしてください。

```powershell
psmux source-file ~/.psmux.conf
```

## 2. `psmux-bridge name` で名前を付ける

winsmux で普段使う方法はこれです。

```powershell
psmux list-panes -a -F '#{pane_id} #{pane_title}'
psmux-bridge name %1 builder-1
psmux-bridge name %2 reviewer
```

`psmux-bridge name` は 2 つのことをします。

1. winsmux のラベルテーブルに `label -> pane_id` を保存する
2. ベストエフォートで `select-pane -T <label>` を実行して pane title も更新する

そのため、以後は `builder-1` のようなラベルで `psmux-bridge read/type/message` を呼びつつ、pane border にも同じ名前を出せます。

## 3. `select-pane -T` で直接タイトルを付ける

tmux 互換コマンドで直接タイトルだけ付けたい場合はこちらです。

```powershell
psmux select-pane -t %1 -T builder-1
psmux select-pane -t %2 -T reviewer
```

確認は次のコマンドでできます。

```powershell
psmux list-panes -a -F '#{pane_id} #{pane_title}'
psmux display-message -t %1 -p '#{pane_title}'
```

border 表示用に必要なのは `pane_title` が空でないことです。`pane-border-format` が `#{pane_title}` を参照していれば、タイトル更新後に border の表示内容も変わります。

## 4. Troubleshooting

### タイトルを設定したのに border に何も出ない

- `pane-border-status` が `top` または `bottom` になっているか確認してください。
- `pane-border-format` に `#{pane_title}` が入っているか確認してください。
- `psmux display-message -t %1 -p '#{pane_title}'` で本当にタイトルが入っているか確認してください。
- fork 前の psmux だと border text の描画自体が未対応のことがあります。対応済みビルドで再確認してください。

### `psmux-bridge name` は通るのに表示名が変わらない

- `psmux-bridge name` のラベル保存と `select-pane -T` は別物です。ラベルは保存されても、psmux 側タイトル更新が効いていないと border には出ません。
- `psmux list-panes -a -F '#{pane_id} #{pane_title}'` で `pane_title` が変わっていなければ、`select-pane -T` を直接試してください。

### フォールバック条件式が期待どおり動かない

- `#{?pane_title,#{pane_title},#{b:pane_current_path}}` の形を使ってください。
- `#{?#{pane_title},...}` は避けてください。

### 設定を変えたのに既存セッションに反映されない

- `psmux source-file ~/.psmux.conf` を実行してください。
- 反映が不安定なら新しいセッションを作って確認してください。

### どのペイン ID を使えばいいかわからない

- まず一覧を見ます。

```powershell
psmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_title}'
```

- そのあと `psmux-bridge name %3 builder-1` または `psmux select-pane -t %3 -T builder-1` を使います。
