# Contributing

IssueやPull Requestを歓迎します。

## 開発手順

1. XcodeGenでプロジェクトを生成します。
2. 変更前に失敗するテストを追加します。
3. 最小の実装でテストを通します。
4. 全テストとReleaseビルドを実行します。
5. 認証情報がdiffへ入っていないことを確認します。

```bash
xcodegen generate
xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project AIUsage.xcodeproj -scheme AIUsage -configuration Release CODE_SIGNING_ALLOWED=NO
git diff --check
```

通常のテストfixtureは架空の値だけを使ってください。実APIレスポンスやローカル認証ファイルをコミットしないでください。

Provider追加時は、通信・認証・解析をProviderディレクトリへ閉じ込め、1サービスの失敗が他サービスへ波及しない設計を維持してください。
