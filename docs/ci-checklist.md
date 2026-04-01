# CI Checklist

CI スクリプト作成時のチェックリスト。

1. PowerShell 7 では `$ErrorActionPreference = 'Continue'` を設定する。
2. ネイティブコマンド実行後は `$LASTEXITCODE` を即キャプチャする。
3. 成功時は明示的に `exit 0` を返す。
4. GitHub Actions の `actions/checkout@v4` は `fetch-depth: 1` なので `HEAD~1` は使えない。
5. `git grep` の exit code `1` は「マッチなし」で成功扱いにする。
6. ローカルテストは `pwsh -Command` で実行する。`pwsh -File` は使わない。
