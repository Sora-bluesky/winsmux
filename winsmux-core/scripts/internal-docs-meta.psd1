@{
    FeatureInventoryEntries = @(
        @{
            Order = 10
            Category = '画面での操作'
            Title = 'Tauri デスクトップアプリを、生の端末出力ではなく整理済みデータで動かす'
            UserValue = 'Tauri デスクトップアプリがターミナルの流れを直接読むのではなく、ダッシュボード、受信箱、要点整理、詳細説明などの整理済みデータから状態を描くようになります。これにより、表示の一貫性が上がり、後続の機能追加もしやすくなります。'
            UseCase = 'Tauri デスクトップアプリで見えている情報と、実際の運用状態をずらさずに扱いたいときに使います。'
            ImplementationVersion = 'v0.22.0'
            TaskIds = @('TASK-105', 'TASK-289', 'TASK-291')
            AppendixName = 'Tauri デスクトップアプリの整理済みデータ化'
            TestFocus = '画面表示が整理済みデータで動くか'
        }
        @{
            Order = 20
            Category = '拡張と今後の強化'
            Title = '内部運用として、外部の生成支援道具の変化を見張り、自己進化の候補を作る'
            UserValue = 'OpenAI、Anthropic、Google など外部の生成支援道具の変化を見張り、その内容を winsmux に取り込む候補と、見直すべき機能候補に分けられるようにします。自動化は下書き提案までで止め、最終判断は人が行います。'
            UseCase = '外部の変化を追い続けながら、winsmux 自体の改善や整理を継続したいときに使います。'
            ImplementationVersion = 'v0.22.0'
            TaskIds = @('TASK-315')
            AppendixName = '内部運用の自己進化'
            TestFocus = '外部変化の収集、影響判断、見直し候補'
        }
        @{
            Order = 30
            Category = '拡張と今後の強化'
            Title = 'Tauri デスクトップアプリと CLI のつなぎ方を整理し、後から差し替えやすくする'
            UserValue = 'Tauri デスクトップアプリ、CLI、裏側の制御処理の役割分担を整理し、通信方式や実装を後から入れ替えやすくします。'
            UseCase = '今は PowerShell ベースの処理と Tauri デスクトップアプリが混在していても、将来の移行で大きく作り直さずに進めたいときに使います。'
            ImplementationVersion = 'v0.22.0'
            TaskIds = @('TASK-217a', 'TASK-217b', 'TASK-217c', 'TASK-217d', 'TASK-217e', 'TASK-226')
            AppendixName = 'Tauri デスクトップアプリと CLI の接続整理'
            TestFocus = '通信経路と役割分担の整理'
        }
        @{
            Order = 40
            Category = '画面での操作'
            Title = 'Tauri デスクトップアプリの詳細表示を、日々の運用で判断しやすくする'
            UserValue = '変更ファイル、確認結果、判定、ブランチや先頭位置、作業役の属性などを、詳細表示で読みやすく確認できるようになります。並べ替えや複数ウィンドウ表示も強化されます。'
            UseCase = 'Tauri デスクトップアプリだけで「何が変わったか」「確認は通ったか」を追いたいときに使います。'
            ImplementationVersion = 'v0.22.1'
            TaskIds = @('TASK-107', 'TASK-108', 'TASK-290', 'TASK-305', 'TASK-308', 'TASK-078')
            AppendixName = 'Tauri デスクトップアプリの詳細強化'
            TestFocus = '詳細表示、複数画面、表示確認'
        }
        @{
            Order = 50
            Category = '基本操作と拡張'
            Title = '遠隔の区画や外部のプロバイダーも、同じ操作画面で扱えるようにする'
            UserValue = '遠隔の区画、外部の連携口、プロバイダーの切り替え、手元のマシンの読み取り専用利用などを、同じ枠組みで扱えるようになります。'
            UseCase = '手元だけでなく、別の場所や別のプロバイダーも含めて運用したいときに使います。'
            ImplementationVersion = 'v0.22.2'
            TaskIds = @('TASK-106', 'TASK-147', 'TASK-313', 'TASK-314', 'TASK-258')
            AppendixName = '遠隔区画とプロバイダー拡張'
            TestFocus = '遠隔、プロバイダー切り替え、手元マシン連携'
        }
        @{
            Order = 60
            Category = '基本操作と拡張'
            Title = '機能の追加方法を整理し、並列処理も広げる'
            UserValue = '拡張用の読み込み口を整え、命令構造を一元化し、通知や並列処理も増やしやすくします。'
            UseCase = '後から機能を足しても全体が散らかりにくい形にしたいときに使います。'
            ImplementationVersion = 'v0.22.0'
            TaskIds = @('TASK-168', 'TASK-144', 'TASK-306', 'TASK-307', 'TASK-192')
            AppendixName = '拡張口と並列処理の整理'
            TestFocus = '拡張しやすい命令構造'
        }
        @{
            Order = 70
            Category = '作業環境の管理'
            Title = '作業状態の元データを Rust 側へ移していく'
            UserValue = '作業状態、履歴、ダッシュボード、要点整理、詳細説明などの元になる情報を、徐々に Rust 側の型付きデータへ寄せていきます。PowerShell は起動や互換のための薄い役割へ縮めていきます。'
            UseCase = '運用の信頼性を上げつつ、将来の保守をしやすくしたいときに使います。'
            ImplementationVersion = 'v0.24.0 から v0.24.4'
            TaskIds = @('TASK-277', 'TASK-278', 'TASK-265', 'TASK-275', 'TASK-280', 'TASK-266', 'TASK-269', 'TASK-281', 'TASK-267', 'TASK-268', 'TASK-284', 'TASK-270', 'TASK-276', 'TASK-282')
            AppendixName = 'Rust 側への元データ移行'
            TestFocus = '状態、履歴、一覧の移行'
        }
        @{
            Order = 80
            Category = '作業環境の管理'
            Title = '途中再開、退避コピー、証跡強化を進める'
            UserValue = '途中からの再開、作業場所の退避コピー、改ざん検知つきの証跡などを強められるようになります。'
            UseCase = '長期運用や、失敗時の巻き戻し、後日の説明責任をより強くしたいときに使います。'
            ImplementationVersion = 'v0.24.1 から v0.24.3'
            TaskIds = @('TASK-143', 'TASK-154', 'TASK-169', 'TASK-310')
            AppendixName = '再開・退避コピー・改ざん検知'
            TestFocus = '途中再開、退避コピー、証跡強化'
        }
        @{
            Order = 90
            Category = '公開に向けた最終強化'
            Title = 'PowerShell 依存を縮め、Rust 中心の配布形へ移る'
            UserValue = '最終的には Rust を中心にした配布形へ寄せ、PowerShell は導入や互換の補助にとどめる予定です。Windows 向け配布、試験導入、本番移行の流れも整います。'
            UseCase = '公開版として安定した配布と更新を行いたいときに使います。'
            ImplementationVersion = 'v0.24.5 から v1.0.0'
            TaskIds = @('TASK-296', 'TASK-283', 'TASK-115', 'TASK-220', 'TASK-316')
            AppendixName = 'Rust 中心の配布移行'
            TestFocus = 'Windows 向け配布、互換終了、試験導入、本公開'
        }
        @{
            Order = 100
            Category = '公開に向けた最終強化'
            Title = '公開後に向けた設計書と、より細かな承認制御を整える'
            UserValue = '要件、脅威、設計書の整備に加えて、命令単位の承認やネットワーク遅延承認のような後続機能を準備します。'
            UseCase = '公開後に運用や説明責任をさらに強くしたいときに使います。'
            ImplementationVersion = 'v1.6.0'
            TaskIds = @('TASK-045', 'TASK-046', 'TASK-047', 'TASK-048', 'TASK-050', 'TASK-073', 'TASK-076')
            AppendixName = '公開後の設計書と細かな承認制御'
            TestFocus = '説明資料、承認の細分化'
        }
        @{
            Order = 110
            Category = '拡張と今後の強化'
            Title = '自律 run を、下書き PR 手前まで管理された形で進める'
            UserValue = 'Claude Code を司令塔にしたまま、計画、実装、確認、引き継ぎの流れを小さな run 単位で回し、最後は必ず下書き PR か判断待ちで止まるようにします。'
            UseCase = '利用者が細かな指示を出し続けなくても、自律 run に 85〜95% を進めさせ、最後だけ人が判断したいときに使います。'
            ImplementationVersion = 'v1.1.0'
            TaskIds = @('TASK-311', 'TASK-317', 'TASK-318', 'TASK-319')
            AppendixName = '管理された自律 run の基盤'
            TestFocus = 'plan から draft PR までの無人完走'
        }
        @{
            Order = 120
            Category = '拡張と今後の強化'
            Title = '自律 run に、試験先行と自己確認を標準で持たせる'
            UserValue = 'バグ修正や中核変更では先に失敗する試験を書き、実装後は build、test、browser、screenshot、recording まで自分で確認する流れを標準にします。'
            UseCase = '自律 run がコードを書くだけでなく、自分で確かめたうえで人へ返してほしいときに使います。'
            ImplementationVersion = 'v1.2.0'
            TaskIds = @('TASK-320', 'TASK-321', 'TASK-322')
            AppendixName = '自律 run の TDD と自己確認'
            TestFocus = 'TDD gate、自己確認、run insights'
        }
        @{
            Order = 130
            Category = '拡張と今後の強化'
            Title = '知識、手順書、並列子 run を使い回しながら、自律 run を伸ばす'
            UserValue = 'repo 固有の知識、繰り返し手順、並列で動く子 run、最後の判断を助ける画面をそろえ、自律 run が同じ失敗を繰り返しにくい形へ育てます。'
            UseCase = '長い案件でも、司令塔が複数の run を束ね、人は最後の 5〜15% に集中したいときに使います。'
            ImplementationVersion = 'v1.3.0'
            TaskIds = @('TASK-312', 'TASK-323', 'TASK-324', 'TASK-325', 'TASK-326')
            AppendixName = '知識・手順書・並列自律 run'
            TestFocus = 'Knowledge、Playbook、並列子 run、handoff 画面'
        }
        @{
            Order = 140
            Category = '画面での操作'
            Title = 'Windows 以外でも使える下地を、v1.0.0 の後で整える'
            UserValue = '将来、Windows 以外でも同じ操作感で使えるように、確認の組み合わせ、保管庫、PowerShell 依存を整理します。'
            UseCase = '将来、Windows 以外の環境でも同じ運用をしたいときに使います。'
            ImplementationVersion = 'pending'
            TaskIds = @('TASK-249', 'TASK-250', 'TASK-251', 'TASK-252', 'TASK-267', 'TASK-268', 'TASK-271')
            AppendixName = 'Windows 以外への展開'
            TestFocus = 'Windows 以外への拡張を始められるか'
        }
    )
    ManualChecklistEntries = @(
        @{
            Order = 10
            Version = 'v0.22.0'
            TaskIds = @('TASK-105', 'TASK-289', 'TASK-291')
            Focus = 'Tauri デスクトップアプリが生の端末出力ではなく整理済みデータで動く'
            Example = 'ダッシュボード、受信箱、要点整理、詳細説明が画面で一貫して見える'
            Memo = ''
        }
        @{
            Order = 20
            Version = 'v1.6.1'
            TaskIds = @('TASK-315')
            Focus = '自己進化'
            Example = '外部変化の収集、影響判断、見直し候補の出力'
            Memo = ''
        }
        @{
            Order = 30
            Version = 'v0.22.0'
            TaskIds = @('TASK-217a', 'TASK-217b', 'TASK-217c', 'TASK-217d', 'TASK-217e', 'TASK-226')
            Focus = 'Tauri デスクトップアプリと CLI の接続整理'
            Example = '通信経路と役割分担が整理され、差し替え後も同じ見え方を保てる'
            Memo = ''
        }
        @{
            Order = 40
            Version = 'v0.22.1'
            TaskIds = @('TASK-107', 'TASK-108', 'TASK-290', 'TASK-305', 'TASK-308', 'TASK-078')
            Focus = '詳細表示を運用判断しやすくする'
            Example = '変更ファイル、確認結果、判定、ブランチ情報が見やすい'
            Memo = ''
        }
        @{
            Order = 50
            Version = 'v0.22.2'
            TaskIds = @('TASK-106', 'TASK-147', 'TASK-313', 'TASK-314', 'TASK-258')
            Focus = '遠隔区画とプロバイダー切り替え'
            Example = '遠隔接続、プロバイダー切り替え、手元マシンの読み取り専用連携'
            Memo = ''
        }
        @{
            Order = 60
            Version = 'v0.24.0-v0.24.4'
            TaskIds = @('TASK-277', 'TASK-278', 'TASK-265', 'TASK-275', 'TASK-280', 'TASK-266', 'TASK-269', 'TASK-281', 'TASK-284', 'TASK-270', 'TASK-276', 'TASK-282')
            Focus = 'Rust 側への元データ移行'
            Example = 'ダッシュボード、受信箱、要点整理、詳細説明の元データが移っている'
            Memo = ''
        }
        @{
            Order = 70
            Version = 'v0.24.1-v0.24.3'
            TaskIds = @('TASK-143', 'TASK-154', 'TASK-169', 'TASK-310')
            Focus = '再開、退避コピー、証跡強化'
            Example = '再開、退避コピー、改ざん検知の観点を確認'
            Memo = ''
        }
        @{
            Order = 80
            Version = 'v0.24.5'
            TaskIds = @('TASK-296', 'TASK-283', 'TASK-115', 'TASK-220', 'TASK-316')
            Focus = '公開前の総合確認'
            Example = '互換終了、試験導入、Windows 向け導入案内をまとめて確認'
            Memo = 'TASK-316 を使う'
        }
        @{
            Order = 90
            Version = 'v1.0.0'
            TaskIds = @('TASK-220')
            Focus = '公開ゲート'
            Example = '公開資料、配布物、署名、最終説明に抜けがない'
            Memo = ''
        }
        @{
            Order = 100
            Version = 'v1.1.0'
            TaskIds = @('TASK-311', 'TASK-317', 'TASK-318', 'TASK-319')
            Focus = '管理された自律 run の基盤'
            Example = 'plan から draft PR まで、止まるべき地点で fail-closed に止まる'
            Memo = ''
        }
        @{
            Order = 110
            Version = 'v1.2.0'
            TaskIds = @('TASK-320', 'TASK-321', 'TASK-322')
            Focus = '自律 run の TDD と自己確認'
            Example = '失敗する試験追加、自己確認、screenshot や recording の証跡が残る'
            Memo = ''
        }
        @{
            Order = 120
            Version = 'v1.3.0'
            TaskIds = @('TASK-312', 'TASK-323', 'TASK-324', 'TASK-325', 'TASK-326')
            Focus = '知識、手順書、並列子 run、handoff 画面'
            Example = 'Knowledge と Playbook を再利用し、並列 run の結果を一画面で判断できる'
            Memo = ''
        }
        @{
            Order = 130
            Version = 'pending'
            TaskIds = @('TASK-249', 'TASK-250', 'TASK-251', 'TASK-252', 'TASK-267', 'TASK-268', 'TASK-271')
            Focus = 'Windows 以外への展開'
            Example = 'Windows 以外で起動、保管庫、PowerShell 依存が崩れない'
            Memo = ''
        }
        @{
            Order = 140
            Version = 'v1.6.0'
            TaskIds = @('TASK-045', 'TASK-046', 'TASK-047', 'TASK-048', 'TASK-050', 'TASK-073', 'TASK-076')
            Focus = '公開後の設計書と細かな承認制御'
            Example = '要件、脅威、設計、承認制御の説明責任を後追いせず整理できる'
            Memo = ''
        }
    )
}
