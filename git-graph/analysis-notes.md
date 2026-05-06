# 検証結果

## 確認対象

- Repository: upstream source-control implementation
- Branch: `main`
- File: `src/vs/workbench/contrib/scm/browser/scmHistory.ts`
- Source: retained in local research notes only

## 質問1: レーンモデル

- 確認: 区間モデルに近い行単位の `svg` 描画
- 根拠: `renderSCMHistoryItemGraph` は `inputSwimlanes` と `outputSwimlanes` を受け取り、1 行分の `svg` に縦線、曲線、コミット円を描いている。
- 本指示書への影響: 上流の構造を移植せず、指示書どおり `LaneSpan` による柱モデルを維持する。描画の考え方だけ参考にする。

## 質問2: LANE_W

- 確認値: `SWIMLANE_WIDTH = 11`
- 根拠: `src/vs/workbench/contrib/scm/browser/scmHistory.ts`
- 本指示書 §6.1 への反映: 指示書の `LANE_W = 8.0` はより圧縮された値として維持する。

## 質問3: コミット円の半径と種類

- 確認値: `CIRCLE_RADIUS = 4`, `CIRCLE_STROKE_WIDTH = 2`
- 根拠: `drawCircle`, `renderSCMHistoryItemGraph`
- 種類:
  - `HEAD`: 外円と内円を描画
  - incoming/outgoing: 外円、内円、破線円を描画
  - multi-parent: 外円と小さい内円を描画
  - normal: 単円を描画
- 本指示書 §7.5 への反映: 指示書どおり `Head`, `Merge`, `Normal` の 3 種類に簡略化する。

## 質問4: 曲線の描画方法

- 確認: 上流実装は `A` path command の円弧を使う。
- 根拠: `renderSCMHistoryItemGraph` 内の lane shift と parent path の `A ...` path command。
- 本指示書への影響: 指示書は cubic Bezier を要求しているため、円弧は移植しない。`CURVE_ZONE` で縦線区間を残す cubic Bezier を使う。

## 質問5: マージマーカーの存在と色規則

- 確認: 第二親以降の親は `outputSwimlanes[parentOutputIndex].color` を使って描画される。
- 根拠: `renderSCMHistoryItemGraph` の `for (let i = 1; i < historyItem.parentIds.length; i++)` ブロック。
- 本指示書 §7.6 への反映: 吸収される枝の色でマージマーカーを描く。

## 質問6: HEAD コミットの判定と強調表示

- 確認: `historyItem.id === currentHistoryItemRef?.revision` の場合に `kind = 'HEAD'`。
- 根拠: `toISCMHistoryItemViewModelArray`
- 本指示書への影響: CLI では先頭コミットを HEAD として扱う。`--repo` でも `--from-stdin` でも同じ規則を使う。
