# Claude Code、Codex、Antigravity CLI の比較テスト

このページは、winsmux 上で Claude Code、Codex、Antigravity CLI を比較するための
公開テスト計画です。

状態: `v1.0.2` で実施予定。

目的は、全用途での万能な勝者を決めることではありません。慎重なレビュー、コード編集、
高速な分担、並列サブエージェント、非同期の端末作業について、どの CLI がどの作業に強いかを
winsmux の証跡で比較できるようにします。

## 評価原則

このテストでは、モデル名から用途を決めません。特定モデルを速度だけ、別モデルを品質だけに
固定するような前提は、仮説として扱います。最終判断は、同じ条件で集めた
winsmux の証跡、テスト結果、匿名レビュー、資源使用量から出します。

外部ベンチマークは候補選定と事前仮説にだけ使います。公開ベンチマークの数値は、
winsmux のタスク、ローカル PC、CLI の権限設定、サブエージェント機能、端末待ちの条件とは
一致しません。そのため、最終点には直接足し込みません。

モデル適性は、単語のラベルではなく能力ベクトルとして出します。

- 品質: 要件充足、テスト通過、レビュー後の重大指摘の少なさ。
- 速度: 最初の有用な返答、最初の正しい計画、レビュー可能な成果物までの時間。
- 自律性: 指示の少なさ、承認待ちの扱い、失敗後の立て直し。
- 並列性: 独立タスクをどれだけ重複なく進められるか。
- 端末運用: 長時間コマンド、待ち状態、子プロセス、メモリを正しく扱えるか。
- 証跡: 第三者が後から判断できる粒度で、理由、コマンド、失敗、差分を残せるか。
- 安全性: 秘密情報、公開不可情報、危険コマンド、過剰な差分を避けられるか。
- 継続性: 長い文脈、再開、修正依頼、レビュー後の再実装に耐えられるか。

この能力ベクトルを、タスク分類ごとの重みにかけて、モデル別の適性を出します。

## HarnessBench を方法論の参照元にする

winsmux は、nyosegawa HarnessBench を CLI とモデル比較の外部方法論として参照します。
ローカルの参照 checkout は `.references/nyosegawa/harness-bench` です。
このディレクトリは `.gitignore` の対象なので、上流 repo のコードを winsmux の公開差分へ
混ぜずに検証できます。HarnessBench 側の runner や schema に起因する問題が見つかった場合は、
この checkout で最小再現を作り、`nyosegawa/harness-bench` へ issue または PR を送る方針です。

ただし、そのまま複製するわけではありません。winsmux は、ワーカーペイン、desktop app、
証跡契約を維持します。その上で、正式な比較設計では次の考え方を採用します。

- 合成プロンプトや別々のタスクパケットではなく、同じ実リポジトリのデバッグタスクで比較する。
- hidden な決定的テストで採点する。core test と regression test を、正しさの主な根拠にする。
- LLM レビューと `gpt-5.5` レビューは、失敗分析と品質確認の補助として使う。
  不具合、テスト不足、危険な変更を説明するために使い、決定的テストの代わりにはしない。
- 上流の誘導や不要な設定を外した、清潔な 1 commit の作業領域で各候補を走らせる。
- 正式な agent run のタイムアウトは 60 分にする。例外は、タスクごとの公開メモに明記する。
- 採点対象の run では、バージョン、設定、成果物、集計レポートを残す。
- 小さいサンプルは慎重に読む。HarnessBench は 27 タスク設計なので、winsmux でも
  `n=27` 程度の結果は、十分な反復と分類別の確認が終わるまで方向性として扱う。

HarnessBench の Antigravity 記事は外部参照であり、winsmux の最終点ではありません。
同記事は、Antigravity CLI / `Gemini 3.5 Flash (High)` について、同じ 27 タスクで
`17/27`、中央値 `14.3` 分、タイムアウト `1` 件と報告しています。winsmux はこの数値を
ローカル run の事前期待に使えますが、最終判断は winsmux の証跡と下の採点ルールで出します。

## HarnessBench 型パック

モデル適性ランキングを出す段階では、読み取り専用の診断や単発のデモ run では不足します。
winsmux では、次の条件を満たすケースだけを正式な比較パックに入れます。

- 実リポジトリの修正タスクである。
- 比較する全ワーカーに同じタスクパケットを渡す。
- 作業者向けパケットには、hidden test のコマンドや期待値を含めない。
- 採点者専用の `*.hidden-checks.json` に、core test と regression test を分けて保存する。
- 各候補は同じ `base_ref` の隔離 worktree で作業する。
- `runs_per_case` を使い、同じ条件を複数回実行してからランキングに入れる。

上流 HarnessBench のケースを使う場合は、まず上流の YAML と condition JSON から
winsmux 用の `cases.json` を作ります。最初は 1 ケース、1 条件、`RunsPerCase 1` で
smoke run を通し、その後に `n=5`、さらにタスク数を増やします。

```powershell
pwsh -NoLogo -NoProfile -File scripts\import-cli-bakeoff-harnessbench-reference.ps1 `
  -ReferenceDir .references\nyosegawa\harness-bench `
  -CasePath benchmark/cases/sharkdp__bat/low.yaml `
  -ConditionPath benchmark/conditions/antigravity-gemini-3.5-flash-high.json `
  -OutputPath .winsmux\private\cli-bakeoff\harnessbench-upstream\cases.json `
  -SuiteId harnessbench-upstream
```

この取り込みでは、上流の `core_tests` と `regression_tests` は採点者専用の
`hidden_checks` に写します。ワーカー向けの `*.md` には hidden test のパスや
実行コマンドを出しません。

ケース定義から比較パックを作るには、次のスクリプトを使います。

```powershell
pwsh -NoLogo -NoProfile -File scripts\new-cli-bakeoff-harnessbench-pack.ps1 `
  -CasesPath .winsmux\private\cli-bakeoff\harnessbench-upstream\cases.json `
  -OutputDir .winsmux\private\cli-bakeoff\harnessbench-upstream\pack `
  -RunsPerCase 5 `
  -ReviewModel gpt-5.5
```

このスクリプトは、`benchmark-pack.json`、作業者向けの `*.md`、採点者専用の
`*.hidden-checks.json`、反復実行用の `run-matrix.csv`、採点ルーブリックを生成します。
`benchmark-pack.json` は `scripts\new-cli-bakeoff-benchmark-run.ps1` に渡せます。

`run-matrix.csv` から反復 run の証跡ディレクトリをまとめて作る場合は、次を使います。

```powershell
pwsh -NoLogo -NoProfile -File scripts\new-cli-bakeoff-harnessbench-run-matrix.ps1 `
  -PackPath .winsmux\private\cli-bakeoff\harnessbench-upstream\pack\benchmark-pack.json `
  -AllowMissingRecording
```

録画前の準備段階では `-AllowMissingRecording` を付けます。正式な収録 run では、
画面収録を開始してから `operator-start.ps1` と `run-worker-*.ps1` をデスクトップアプリ上で実行します。

## GLM-5.2 とクラウド上位モデルのE2E比較

GLM-5.2 の評価は2段階に分けます。Phase 0 では、GLM-5.2 が winsmux の
`colab_llm` worker として実際に動くかを確認します。Phase 1 では、すべての worker に
同じ HarnessBench 型タスクを渡し、クラウドLLMの上位モデルと比較します。

| Phase | Worker | 候補 | 目的 | 必須証跡 |
| --- | --- | --- | --- | --- |
| 0 | `worker-1` | Colab H100/A100 上の `colab_llm` 経由 `zai-org/GLM-5.2` | ロード、生成、成果物回収、失敗分類、Colab費用境界を確認する。 | Colab runtime log、model cache location、GPU RAM、load time、generation time、伏せ字化済み worker result |
| 1 | `worker-1` | `colab_llm` 経由 `zai-org/GLM-5.2` | 同じ実リポジトリタスクで、オープンウェイトColab基準として測る。 | hidden core/regression test、scorecard、resource metrics |
| 1 | `worker-2` | Claude Code の現行上位モデル。例: Fable 5 または Opus 4.8 | Claude系クラウドLLMのコーディング基準。実行前にローカルで選べるモデルと工数を記録する。 | model picker または CLI 証跡、工数設定、transcript、hidden test、review packet |
| 1 | `worker-3` | Codex の現行上位モデル。例: `gpt-5.5` | OpenAI系クラウドLLMのコーディング基準。`gpt-5.5` をworkerにする場合、そのrunの唯一の第三者レビュー担当にはしない。 | Codex model evidence、effort setting、transcript、hidden test、review packet |
| 1 optional | `worker-4` | Antigravity CLI の Gemini 3.5 Flash High、またはローカルで確認済みのGemini上位条件 | Gemini/Antigravity基準。速度、サブエージェント、非同期terminal挙動を重点的に見る。 | `agy --help`、model setting evidence、transcript、hidden test、review packet |

各 worker に違うタスク文、違う hidden test、追加の誘導を渡した場合、その比較runは無効です。
Phase 1 は low difficulty の HarnessBench 1ケースを `n=1` で確認し、安定後に `n=5`、
その後に27タスク構成へ広げます。Phase 0 は容量不足やruntime未対応で失敗してもよいですが、
失敗分類と再利用できる証跡を必ず残します。

最初に使う候補ケース:

1. `sharkdp__bat/low.yaml`: 小さいRust CLIタスク。worker起動と hidden test の確認に使う。
2. `axios__axios/low.yaml`: JavaScript/TypeScriptタスク。コード編集とテストループを見る。
3. `fastapi__fastapi/low.yaml`: Python web frameworkタスク。依存関係とテスト環境の扱いを見る。

Design Arena、Code Arena、ベンダー公開ベンチの図表は、GLM-5.2 を試す理由の説明には使えます。
ただし winsmux の点数には直接使いません。winsmux の評価は、ローカルrunの成果物と
決定的な hidden test から出します。

`cases.json` の最小構成は次の形です。

```json
{
  "version": 1,
  "suite_id": "harnessbench-local",
  "default_workers": [
    {
      "pane": "worker-1",
      "role": "solver",
      "cli": "Claude Code",
      "model": "sonnet",
      "effort": "high",
      "display_model": "Claude Sonnet 4.7"
    }
  ],
  "cases": [
    {
      "case_id": "HB-001",
      "title": "Fix parser newline handling",
      "repo": "https://github.com/example/parser",
      "base_ref": "abc1234",
      "difficulty": "mid",
      "public_prompt": "Fix the parser so trailing newlines are accepted without changing valid token handling.",
      "allowed_paths": ["src/parser.ts", "tests/parser.public.test.ts"],
      "public_checks": ["npm test -- parser.public"],
      "hidden_checks": [
        { "id": "core", "command": "npm test -- hidden/core", "weight": 0.7 },
        { "id": "regression", "command": "npm test -- hidden/regression", "weight": 0.3 }
      ],
      "success_criteria": [
        "trailing_newline_is_accepted",
        "existing_valid_tokens_still_parse"
      ]
    }
  ]
}
```

この段階での `n=5` は、録画デモ用の最低ラインです。ランキングに使う結果では、
タスク分類と難度を増やし、成功率、中央値、タイムアウト、レビュー指摘、分散を合わせて読みます。
小さい差は、上位、中位、下位の大まかな位置として扱います。

## テスト前に固定する外部事実

- Google は 2026-05-19 に、Gemini CLI から Antigravity CLI への移行を発表しました。
- Gemini CLI は残りますが、`@google/gemini-cli` は重大な不具合修正とセキュリティ修正に限られます。
- 個人向けの Gemini CLI request は 2026-06-18 に終了します。
- 企業向けの Gemini CLI 利用は、Gemini Code Assist Standard、Gemini Code Assist Enterprise、
  Google Cloud 経由の GitHub 連携、有料 Gemini、Gemini Enterprise Agent Platform API key では、
  Google の移行告知上は変更なしとされています。
- Gemini 3.5 Flash は Google Antigravity から利用でき、Google は高速なエージェント型コーディング作業向けと説明しています。
- 各テスト前に、ローカルの `agy --help` を確認します。2026-05-24 時点では
  `agy 1.0.2` が利用でき、Antigravity のモデル選択画面では
  `Gemini 3.5 Flash (High)` が現在のモデルとして表示されていました。
  ただし `agy --help` には `--model` が表示されないため、Gemini 3.5 Flash の証跡として扱うには、
  Antigravity 側の model picker、`/model`、または設定ファイルでモデル選択を確認する必要があります。
- Antigravity CLI への移行は Gemini CLI と完全一致ではありません。ただし公式の移行経路では、
  プラグイン、Agent Skills、MCP サーバー、フック、サブエージェントが対象です。Gemini CLI の既存拡張を
  比較対象にする場合は、`agy plugin import gemini` を実行してから、移行テストとして記録します。

## テストロール

| ロール | CLI | 何を検証するか |
| --- | --- | --- |
| オペレーター | Claude Code | タスクの切り出し、承認、最終判断、証跡の採否を担当します。 |
| レビューワーカー | Claude Code | 設計レビュー、リスク整理、判断を要する指摘の質を見ます。 |
| 実装ワーカー | Codex | 限定的なパッチ、テスト実行、変更ファイルの報告精度を見ます。 |
| Antigravity ワーカー | `agy` with Gemini 3.5 Flash | 速度、品質、並列サブエージェント、非同期端末を同じ条件で見ます。 |

## 実施環境

本テストは winsmux desktop app 上で実施します。CLI だけを直接起動して完結する run は、
参考値として残しても、desktop app の正式な比較結果には含めません。

すべての run は画面収録を必須にします。収録は、タスクパケットをワーカーペインへ渡す前に開始し、
`scorecard.md` と必須証跡が揃った後に終了します。収録対象には、winsmux desktop app、
オペレーターペイン、ワーカーペイン、Agent Vault、状態バー、承認待ち表示、テスト結果表示を含めます。

秘密情報、アカウント固有の quota、非公開運用情報が画面に出た場合、その raw 録画は公開しません。
その run は private evidence として扱い、公開資料には redacted note と集計値だけを載せます。

## ワーカー起動の妥当性

ワーカーのタイムアウトは、ただちにモデルの失敗とは扱いません。比較対象から外す前に、
ワーカーペインが妥当な方法で起動していることと、テスト用の実行器が子プロセスを
止めていないことを確認します。

Claude Code、Codex、Antigravity CLI、custom runner の比較 run では、次のどちらかを使います。

- ワーカーペイン内で CLI を直接起動する。
- `scripts/invoke-cli-bakeoff-worker.ps1` を使う。このスクリプトは、プロセス終了を待つ前に
  stdout と stderr を読み始め、stdin への書き込みもタイムアウト可能な裏側の処理で行います。

stdout や stderr をリダイレクトしたまま、先に `WaitForExit` を呼ぶ補助スクリプトは使いません。
また、タイムアウト処理に入る前に、stdin へ同期的に大きな入力を書き込む形も使いません。
どちらもパイプが詰まると、子プロセスが終了できなくなるためです。この形の補助スクリプトが含まれる
run は、モデルの失敗ではなく、実行器の証跡不備として扱います。実行器を修正し、同じタスクを再実行します。
安全な起動経路で失敗したと確認できるまで、その候補を比較対象から外しません。

## 候補モデル

CLI 名だけで比較しません。各 run は、実際に選ばれているモデル、推論強度、権限設定、
サンドボックス設定を `manifest.json` に記録します。

初期候補:

| CLI | 候補モデル | effort / mode | 目的 |
| --- | --- | --- | --- |
| Claude Code | Claude Sonnet 4.7 | デモ run では `high` | 設計、レビュー、タスク分解、文章化の実測値を取ります。 |
| Codex | `gpt-5.3-codex-spark` | デモ run では `medium` | 採点担当の `gpt-5.5` をワーカーに入れず、実装、レビュー、長い文脈、再修正の実測値を取ります。 |
| Antigravity CLI | Gemini 3.5 Flash (High) | モデル側の High | 高速応答、品質、レビュー耐性、並列処理、資源使用の実測値を取ります。 |
| Antigravity CLI | Gemini 3.5 Flash (Medium) | モデル側の Medium | High との差を、速度、品質、指摘量、資源使用で見ます。 |
| Codex 拡張条件 | `gpt-5.5` | `medium` / `high` / `xhigh` | 採点担当モデルをワーカーにも入れる場合の HarnessBench 型の条件です。 |
| Claude Code 拡張条件 | Claude Opus 4.7 | `high` / `xhigh` / `max` | 高 effort の Claude 条件を比較する場合に使います。 |

外部ベンチマークは、候補モデルを選ぶための参考情報として使います。Google のモデルカードや
Artificial Analysis の速度指標は、同じ条件の winsmux 実測ではありません。そのため、
最終点には直接足し込みません。

## 作業負荷

| 作業負荷 | 目的 | 期待する証跡 |
| --- | --- | --- |
| 共通の読み取り専用診断 | 3 つの CLI に同じリポジトリ情報を渡し、上位リスクと修正計画を出させます。 | 最初の有用な返答までの時間、事実精度、制約の見落とし、参照の質。 |
| 限定的なコード変更 | 各 CLI に同じ難度の小さな修正を、隔離された worktree で実施させます。 | 差分サイズ、テスト結果、介入回数、マージ可能性。 |
| 並列分担 | 1 つの機能を 3 つの独立作業に分け、同時に進めます。 | 1 分あたりの完了数、競合率、統合しやすさ。 |
| 非同期端末待ち | 長いテストを走らせたまま、別の作業を割り当てます。 | オペレーターを止めずに有用な進捗を返せるか。 |
| 証跡の受け渡し | 各 CLI に、レビュー用の最終結果パケットを作らせます。 | 長いログを読まなくても winsmux が比較できるか。 |
| 移行互換性 | `agy plugin import gemini` 後に、Gemini CLI で使っていた作業を Antigravity CLI で動かします。 | スキル、プラグイン、MCP サーバー、フック、設定のどこが移行できなかったか。 |

## タスク分類

最終的に知りたいのは、ワーカーペインの各モデルをどのタスクへ割り当てるべきかです。
そのため、各 run は必ず次の分類を 1 つ以上付けます。

| 分類 | 例 | 重視する評価軸 |
| --- | --- | --- |
| 限定的な修正 | 1 ファイルから数ファイルの不具合修正、設定修正、型エラー修正。 | 正確さ、テスト、差分の小ささ、レビュー後の指摘量。 |
| 横断的な実装 | 複数モジュールにまたがる機能追加、契約変更、移行作業。 | 計画精度、競合回避、テスト範囲、証跡品質。 |
| 調査と設計 | 原因調査、仕様整理、リスク洗い出し、設計案比較。 | 事実精度、参照の質、見落としの少なさ。 |
| コードレビュー | バグ、セキュリティ、仕様漏れ、テスト不足の検出。 | 重大指摘の検出率、誤検出率、再現性。 |
| ドキュメント | 公開 README、手順書、リリース文、移行ガイド。 | 正確さ、読みやすさ、公開してよい情報だけを使うこと。 |
| UI / E2E | desktop app、ブラウザ、インストーラー、スクリーンショット確認。 | 実画面の証跡、再現性、待ち状態の扱い。 |
| 並列分担 | 互いに独立した調査、修正、検証を同時に進める作業。 | 並列処理、重複の少なさ、統合しやすさ。 |
| 長時間コマンド | ビルド、E2E、監査、重いテストを走らせる作業。 | 非同期端末、プロセス管理、途中経過の報告。 |
| リリース作業 | version、release note、CI、issue、docs、成果物の同期。 | 手順遵守、抜け漏れ、証跡品質、公開資料の安全性。 |

各タスクには、次の属性も付けます。これにより、単なる分類名ではなく、難しさの違いを評価できます。

| 属性 | 値の例 | 何を分離するか |
| --- | --- | --- |
| 範囲 | 1 ファイル、複数ファイル、複数サブシステム | 小さな修正と横断変更を分けます。 |
| 曖昧さ | 明確、やや曖昧、要件探索が必要 | 指示理解と確認能力を分けます。 |
| 文脈量 | 短い、長い、過去経緯が必要 | 長い文脈への耐性を分けます。 |
| 検証方法 | 単体テスト、E2E、手動確認、レビューのみ | 実行可能な正解があるかを分けます。 |
| 並列可能性 | 低、中、高 | サブエージェント能力を測る意味があるかを分けます。 |
| リスク | 低、中、高 | セキュリティ、公開資料、リリースの重さを分けます。 |
| 成果物 | diff、レビュー、計画、ドキュメント、実行ログ | 文章が得意なだけの結果と、採用できる変更を分けます。 |

## モデル適性表

最終成果物は、次のようなモデル別の適性表にします。これは事前の仮説ではなく、
各 run の `result.json` から生成します。

| モデル | タスク分類 | 適性 | 信頼度 | 注意点 | 根拠 |
| --- | --- | --- | --- | --- | --- |
| Gemini 3.5 Flash (High) |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| Gemini 3.5 Flash (Medium) |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| Gemini 3.1 Pro 系 |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| `gpt-5.5` |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| `gpt-5.3-codex-spark` |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| Claude Sonnet 4.7 |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |
| Claude Opus 系 |  | 最適 / 有力 / 条件付き / 避ける | 高 / 中 / 低 |  |  |

各セルには、点数だけではなく「なぜその割り当てにしたか」を残します。
たとえば「速い」という一語では不十分です。「範囲が明確な調査では高得点だが、横断変更では
`P1` 指摘が増えたため、実装採用前に別モデルのレビューを必須にする」のように、
winsmux の運用判断へ直結する文章にします。

信頼度は run 数、タスクの多様性、レビュー一致率、点数のばらつきから決めます。
1 回だけ良かった結果は「最適」ではなく「仮説」として残します。

## 採点設計

最終結果は、1 つの勝者だけに集約しません。作業負荷ごとに点を出し、用途別の勝者を残します。

hidden な決定的テストを、採点の主な根拠にします。比較対象のワーカー成果物は、同じ hidden core test と
regression test で評価します。LLM レビューと `gpt-5.5` レビューは、失敗分析と品質確認の補助です。
再現できる不具合を見つけた場合に run へ上限や注記を付けることはできますが、必須の決定的テストに
失敗した run を合格扱いにはできません。

| 評価軸 | 点数 | 測り方 |
| --- | ---: | --- |
| 正確さ | 30 | 要件を満たすか、テストが通るか、実在しないファイルや API を前提にしていないか。 |
| レビュー後の指摘量 | 20 | 独立レビューで出た指摘を重大度で重み付けします。 |
| 速度 | 15 | 最初の有用な返答、最初の正しい計画、テスト開始、完了までの実時間。 |
| 並列処理 | 15 | 有効なサブタスク数、並列稼働率、重複作業、競合率、統合しやすさ。 |
| 非同期端末 | 10 | 長いコマンド中に別作業を進められるか、待ち状態を正しく扱うか。 |
| 証跡品質 | 10 | 変更理由、実行コマンド、失敗、判断理由が第三者に読める形で残るか。 |

重大な問題がある run は、合計点に上限をかけます。

| 条件 | 上限 |
| --- | ---: |
| テストが起動しない、または主要機能が動かない | 40 |
| `P0` 指摘が 1 件以上ある | 50 |
| `P1` 指摘が 2 件以上ある | 70 |
| 証跡が欠けて再現できない | 60 |

レビュー後の指摘量は、次の式で点数化します。

```text
review_score = max(0, 100 - P0*45 - P1*20 - P2*6 - P3*2)
```

`P0` は採用不可、`P1` は修正必須、`P2` は品質リスク、`P3` は改善提案として扱います。

点数は、総合点だけでなく次の形でも出します。

- 品質効率: `accepted_quality_score / elapsed_minutes`
- 操作者効率: `accepted_quality_score / operator_blocked_minutes`
- レビュー耐性: `review_score` と修正後の再レビュー改善幅
- 資源効率: `accepted_quality_score / peak_memory_mb`
- 安定性: 同じ分類で複数 run を行った時の点数のばらつき

これにより、「総合点は高いが遅い」「速いがレビュー後の修正が多い」
「平均点は高いが失敗時の落ち方が大きい」といった差を分けて見ます。

## 第三者レビュー

タスクの正確さは、候補 CLI 自身の自己申告では判定しません。各 run の成果物を匿名化し、
CLI 名とモデル名を伏せた review packet として評価します。

必須レビュー:

- ルールベース確認: 指定テスト、公開資料監査、差分サイズ、変更ファイル、禁止情報の混入を機械的に確認します。
- Codex レビュー: `codex review` を使い、バグ、仕様漏れ、テスト不足、セキュリティリスクを findings-first で出します。
- 別系統レビュー: Claude Code または別モデルに同じ匿名 packet を見せ、Codex レビューとの一致と差分を記録します。

候補モデルと同じモデルファミリーをレビュー担当にした場合、そのレビュー点は最終点に直接入れません。
たとえば `gpt-5.5` の成果物を `gpt-5.5` で採点した場合は、参考所見として残し、
採点には別系統レビューとルールベース確認を使います。

レビューは「指摘が少ないほど良い」だけでは判断しません。重要なのは、指摘の重大度、修正しやすさ、
テストで再現できるか、成果物が採用できるかです。

品質確認ルール: 比較対象の全ワーカーには、同じタスクパケットを渡し、同じ決定的テストで評価します。
どれか 1 つでも、別のタスク、追加の誘導、別の hidden test、同等でない作業領域を使った場合、
その比較 run は無効とし、再実行します。

## 速度、並列サブエージェント、非同期端末の評価

速度は、単なる出力速度ではなく、作業が前に進むまでの時間で測ります。

- `time_to_first_output`: 最初の応答まで。
- `time_to_first_useful_plan`: repo の事実に合った計画が出るまで。
- `time_to_first_test`: テストまたは静的確認を開始するまで。
- `time_to_accepted_result`: レビューに回せる成果物が揃うまで。
- `operator_blocked_seconds`: オペレーターが待たされた時間。

並列サブエージェントは、数だけを評価しません。

- `useful_parallel_tasks`: 採用できる独立タスクの数。
- `parallel_overlap_ratio`: 実時間の中で複数作業が同時に進んだ割合。
- `duplicate_work_ratio`: 同じ調査や同じ修正を重複した割合。
- `merge_conflict_count`: 統合時の衝突数。
- `subagent_trace_quality`: 子タスクの会話、コマンド、判断理由が追えるか。

非同期端末は、長いコマンドを実行している間の振る舞いで見ます。

- 長いテスト中に別タスクへ進めるか。
- 端末の確認、承認待ち、失敗を見落とさないか。
- 終了後にプロセスを残さないか。
- メモリと子プロセスが増え続けないか。
- 最終報告に、待っていたコマンドの結果が反映されているか。

## 証跡契約

### ベンチマークパックと録画準備

最初の正式な winsmux パックは次の場所に置きます。

```text
tasks/cli-bakeoff/v1/benchmark-pack.json
```

このパイロットパックには 9 つのタスク分類を入れています。単発の簡単なプロンプトから
結論を出さないための最小単位です。ただし、まだパイロットです。27 タスク目標で反復 run が
揃うまでは、結果を方向性として扱います。

パックから録画用 run を作るには、次を実行します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\new-cli-bakeoff-benchmark-run.ps1 `
  -TaskId WB-001 `
  -DesktopAppVersion "v1.0.2" `
  -AllowMissingRecording `
  -Json
```

このスクリプトは、共有の `task-packet.md`、`worker-spec.json`、`operator-start.ps1`、
`run-worker-*.ps1`、`scorecard.md`、`recording-ready-checklist.md` を 1 つの run
ディレクトリに書きます。`operator-start.ps1` は、オペレーターが同じタスクを各ワーカーへ
割り当てたことを録画で見えるようにするためのものです。

録画を始める前に、次を実行します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-preflight.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\<run-id> `
  -TimeoutSeconds 120 `
  -Json

pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-recording-ready.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\<run-id> `
  -RequirePreflight `
  -Json
```

2 つ目のコマンドで `all_pass=true` が出るまで、録画は開始しません。

各 run は、次の場所に run ディレクトリを作ります。

```text
.winsmux/evidence/cli-bakeoff/<run-id>/
```

run ディレクトリは、次のスクリプトで作成します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\new-cli-bakeoff-run.ps1 `
  -Cli "Antigravity CLI" `
  -Model "Gemini 3.5 Flash (High)" `
  -TaskClass "bounded_fix" `
  -TaskPacketPath .\tasks\example-task.md `
  -DesktopAppVersion "v1.0.2" `
  -RecordingPath .\recordings\example.mp4 `
  -Json
```

正式な run では `-RecordingPath` が必須です。録画なしの雛形作成は、テストや準備用に
`-AllowMissingRecording` を明示した時だけ許可します。

必須ファイル:

- `manifest.json`: CLI、バージョン、モデル、タスクパケットのハッシュ、worktree、開始時刻、終了時刻、オペレーター。
- `pane-transcript.txt`: 範囲を切った端末ログ。
- `commands.jsonl`: コマンド、終了コード、所要時間、オペレーター承認の有無。
- `resource-samples.jsonl`: プロセス数、CPU、メモリ、子プロセス。
- `screen-recording.mp4`: desktop app 上の run 全体を収録した動画。
- `screen-recording.json`: 収録開始、収録終了、解像度、対象ウィンドウ、公開可否、redaction の有無。
- `review-findings.jsonl`: 匿名レビューで出た指摘、重大度、再現性、採点に使ったかどうか。
- `result.json`: 正規化した点数項目。
- `scorecard.md`: 1 ページで読める結果。

Antigravity CLI の run では、追加で証跡を残します。ローカルの Antigravity version `v1.0.2`、
選択モデル表示、コマンド形、隔離した home と設定パス、全ログ、
標準出力または回収した会話ログ、タイムアウトを記録します。ローカルの `agy --print` が
終了コード `0` で標準出力を出さない場合でも、隔離した Antigravity の `transcript.jsonl` に
一致するモデル応答と終了マーカーが残っていれば採点できます。それ以外は
`blocked_empty_stdout` として扱います。

## 繰り返した失敗と恒久対策

今回の録画テストでは、次の失敗を繰り返しました。

| 失敗 | 原因 | 恒久対策 |
| --- | --- | --- |
| 録画中に CLI 引数を直した | 事前確認なしでワーカーへ長い1行コマンドを流した | `preflight.json` が `all_pass=true` になるまで run を開始しない |
| Claude Code が応答しない | リポジトリ直下で起動し、短い確認でも巨大な初期文脈を読んだ | run ディレクトリから起動し、リポジトリは `--add-dir` で追加する |
| Claude Code が別経路へ通知した | グローバルに入っている Claude Code プラグインが、チャネルではないワーカー run でも Telegram 系ツールを露出した | worker spec で明示しない限り `--channels` を渡さず、チャネル返信ツールを既定で禁止する |
| Claude Code のモデル指定が失敗した | 表示名の `Claude Sonnet 4.7` を CLI 引数として渡した | `display_model` と `model` を分け、CLI には `sonnet` を渡す |
| Codex が起動できない | `WindowsApps` 側の `codex.exe` を拾い、`Process.Start()` が拒否された | Windows では `.cmd` を `.exe` より優先して解決する |
| Antigravity CLI の結果を採点したくなった | `agy --print` が終了コード `0` でも標準出力を出さない | 空出力は `blocked_empty_stdout` とし、機械採点へ入れない |

この表に該当する失敗が出た場合、録画中に継続しません。原因を直してから
`preflight` を再実行します。

## ワーカー実行の採否ゲート

正式な run では、録画を開始する前に必ず preflight を通します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-preflight.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\example-run `
  -TimeoutSeconds 120 `
  -Json
```

`preflight.json` の `all_pass` が `true` でない場合、オペレーターは run を開始しません。
録画中にモデルを差し替えたり、CLI の引数を試行錯誤したりしません。Claude Code、Codex、
Antigravity CLI のいずれかで短い事前確認マーカーを返せない場合は、その run は準備失敗として止めます。
事前確認で見るのは起動と接続性です。タスクの終了マーカーは、実際のワーカー run で要求します。

`preflight.json` には `manifest.json`、`task-packet.md`、`run-worker-*.ps1` のハッシュを保存します。
録画開始スクリプトは、開始直前にこれらを再計算します。1つでも変わっていた場合は、
古い `preflight.json` を使わず、開始を止めます。

モデルの表示名と CLI に渡す値が違う場合は、`manifest.json` に `display_model` と
`model` を分けて書きます。たとえば Claude Code は画面上では `Claude Sonnet 4.7` と表示しても、
CLI には `--model sonnet` を渡します。表示名をそのまま渡して失敗した run は無効です。

Claude Code はリポジトリ直下ではなく run ディレクトリを作業ディレクトリにし、
必要なリポジトリだけを `--add-dir` で追加します。これにより、事前確認の短いプロンプトで
ワークスペース全体を初期文脈として読み、トークン上限で止まる問題を防ぎます。

Claude Code Channels は、セッションごとに明示して有効にする機能です。公式の契約では、
チャネルサーバーが存在するだけでは不十分で、セッションを `--channels` 付きで起動する必要があります。
そのため、winsmux の比較ワーカーは既定では `--channels` を渡しません。worker spec に
`claude_channels` がない場合、保護付き実行器は Telegram 返信などのチャネル返信ツールも禁止します。
Claude Code Channels 自体を検証する場合は、worker spec に対象プラグインを明示し、
モデル品質の比較 run とは分けます。

正式な run では、ワーカーのタスクを次の保護付き実行器で起動します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\invoke-cli-bakeoff-worker.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\example-run `
  -PaneId worker-1 `
  -Cli "Codex" `
  -Model "gpt-5.3-codex-spark" `
  -PromptPath .\.winsmux\evidence\cli-bakeoff\example-run\task-packet.md `
  -Json
```

## レポートとグラフ出力

`summarize-cli-bakeoff.ps1` は、機械処理用データと記事用レポートを同時に出します。

- `article-report.md`: 条件、結果、実行時間、タイムアウト、品質管理メモ、控えめな読み方、参照元を含むレポート。
- `chart-data.json`: 完了率または成功率、中央値の実行時間、速度と品質の散布図、能力ベクトル、タスク分類ヒートマップ用の正規化データ。
- `gpt-image-2-chart-prompts.md`: GPT image 2.0 を明示した高品質グラフ生成用プロンプト。

サンプル数が少ない段階では、順位を強く言い切りません。完了した run、採点済みの pass、
タイムアウト、レビュー指摘を分けて表示します。hidden test や決定的な採点がない場合は、
pass rate ではなく completion rate として扱います。

この実行器は、`*-stdout.txt`、`*-stderr.txt`、`*-pane-transcript.txt`、
`*-result.json` を分けて書きます。標準エラーは証跡として保存しますが、
画面に見せるペイン用ログには混ぜません。これにより、プロバイダーの警告が
モデルの回答に見える状態を防ぎます。

`status` が `completed` の run だけを採点します。それ以外は採点対象外です。
実行器は、次の状態を blocked として記録します。

- `blocked_empty_stdout`: 終了コードは `0` だが、標準出力が空。
- `blocked_missing_end_marker`: 期待する `BAKEOFF_ROUND_A_END` が出ていない。
- `blocked_timeout`: タイムアウトした。
- `blocked_nonzero_exit`: CLI が `0` 以外で終了した。
- `blocked_start_failure`、`blocked_command_line_too_long`、
  `blocked_stream_read_timeout`、`blocked_stdin_write_timeout`: 機械採点に使える証跡を安全に作れなかった。

特に Antigravity CLI では重要です。`agy --print` の標準出力が空の場合、実行器は
隔離した Antigravity の `transcript.jsonl` からモデル応答を回収できます。ただし、
期待マーカー、終了マーカー、モデル証跡、生成テキスト証跡が揃う場合だけ採点します。
対話 TUI の画面は録画証跡として残せますが、機械採点できる比較結果としては扱いません。

録画用のオペレーターは、CLI 本体の長い1行コマンドを直接ワーカーペインへ流しません。
`run-worker-1.ps1` のような事前確認済みスクリプトだけを実行します。これにより、引用符、
改行、PowerShell の継続入力、CLI 固有の引数解釈が録画中に崩れる問題を防ぎます。

## 一目で分かる結果表

`scorecard.md` は次の形にします。

| CLI | モデル | 作業負荷 | 正確さ | レビュー後の指摘量 | 速度 | 並列処理 | 非同期端末 | 証跡 | 総合 | 判定 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Claude Code | プロバイダー側で選択 |  |  |  |  |  |  |  |  |  |
| Codex | プロバイダー側で選択 |  |  |  |  |  |  |  |  |  |
| Antigravity CLI | Gemini 3.5 Flash |  |  |  |  |  |  |  |  |  |

判定は作業種別ごとに出します。たとえば、Antigravity が並列分担で勝ち、
Codex が限定的なコード変更で勝つ、という結果を許容します。

## 最終レポート

全 run の後に、次の成果物を出します。

- `model-task-fit.md`: モデルごとの最適タスク、注意点、避けるべき作業をまとめた表。
- `assignment-policy.md`: winsmux のワーカーペインへ、どのモデルをどの役割で割り当てるかの推奨。
- `raw-score-matrix.csv`: モデル、CLI、作業分類、評価軸、点数、レビュー指摘数、所要時間を機械処理できる表。
- `model-evidence-profile.json`: モデルごとの能力ベクトル、信頼度、根拠 run の一覧。
- `benchmark-report.html`: SWE-bench Pro のようにモデル条件を横軸、作業分類を縦軸にしたスコア行列、速度と品質の散布図、能力レーダー、作業分類ヒートマップを含む、リッチな静的HTMLレポート。
- `.references/benchmark-reports/cli-bakeoff-benchmark-report.html`: 最新リッチレポートのローカル参照コピー。gitignore対象であり、ローカル確認、録画、記事下書き用です。

集計は次のスクリプトで生成します。

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\summarize-cli-bakeoff.ps1 -Json
```

推奨は、必ず条件付きで書きます。

- タスク分類。
- タスク属性。
- 推奨モデル。
- 併用すべきレビュー担当。
- 避ける条件。
- 根拠 run。
- 信頼度。

この分類により、「単に `gpt-5.5` が強い」や単純な速度用途ラベルのような
粗い結論で止めず、ワーカーペインの割り当てとして再利用できる結果にします。

## ガードレール

- 異なるタスクパケットで CLI を比較しない。
- 全ワーカーが同じタスクパケットと同じ決定的テストを使っていない比較は採点しない。
- Antigravity 自体がモデル選択を表示または保存していない run は、Gemini 3.5 Flash の証跡として数えない。
- 端末ログ、コマンドログ、変更ファイルの要約がない結果は採用しない。
- desktop app の画面収録がない run は、正式な比較結果として採用しない。
- 非公開アクセスの詳細、トークン、アカウント固有の quota 情報を公開資料に出さない。
