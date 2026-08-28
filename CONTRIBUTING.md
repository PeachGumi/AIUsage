# Contributing

IssueやPull Requestを歓迎します。AIUsageは認証済みセッションと非公開・非安定なProvider仕様を扱うため、機能追加だけでなく「失敗しても安全」「秘密情報を残さない」「他Providerへ影響させない」ことを重視します。

## 開発環境

- macOS 14以降
- Xcode 16.2以降
- XcodeGen（`project.yml`またはターゲット構成を変更するときだけ必要）

通常のビルドとCIは、リポジトリにコミットされている`AIUsage.xcodeproj`を使います。

## 開発手順

1. 変更前に、可能なら失敗するテストを既存のテストターゲットへ追加します。
2. 最小の実装でテストを通します。
3. 全テストとReleaseビルドを実行します。
4. compiler warningと`git diff --check`を確認します。
5. 認証情報、実APIレスポンス、workspace IDなどがdiffへ入っていないことを確認します。

```bash
xcodebuild test \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild build \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

git diff --check
```

## Xcodeプロジェクト

`project.yml`とコミット済み`AIUsage.xcodeproj`の両方を保持しています。ソースやテストの`.swift`ファイルを追加した場合、**そのファイルがXcode targetのSources build phaseへ登録されていることを必ず確認してください**。CIも登録漏れを検出します。

`project.yml`やターゲット構成を変更してXcodeGenを使う場合は、生成された`.xcodeproj`の差分を確認し、必要な変更を同じPull Requestへ含めてください。無関係なproject file差分を大量に混ぜないでください。

Version/BuildはXcode build settingの`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`を正とし、`Info.plist`へ別の固定値を追加しないでください。

## テストデータ

通常のfixtureは架空の値だけを使ってください。以下をfixture、ログ、Issue、Pull Requestへ含めないでください。

- OAuth access token / refresh token
- Cookie / Cookie header
- ChatGPT account ID
- OpenCode workspace ID
- 実利用率を含む実APIレスポンス全文
- 個人を特定できるアカウント情報

実アカウントテストは`README.md`記載のopt-in手順でローカル実行し、結果そのものをコミットしないでください。

## Provider登録モデル

対応可能なProviderと、ユーザーが実際に登録したProviderは別概念です。

- `ProviderID.implemented` が **+ メニューへ公開するProvider** のカタログです。実アカウント未検証の実装を公開する場合は`isExperimental`を必ず有効にし、UIとREADMEで明示します。
- `SettingsStore.registeredProviders` はユーザーが明示的に追加したProviderだけを保持します。
- `UsageCoordinator`は登録済みProviderだけを起動時・定期・手動の全更新対象にします。
- Removeは表示/更新対象から外す操作で、認証情報の削除とは分離します。

将来のProviderを試作する際は、IDや実装コードが存在していても、fixtureテスト、認証境界、fail-closedの失敗時挙動が整うまでは`ProviderID.implemented`へ追加しないでください。実アカウント検証前に公開する必要がある場合はExperimental扱いとし、公式dashboardとの照合結果やサニタイズ済み修正PRを募集してください。

## Providerを追加・変更するとき

新しいProviderを追加する場合は、少なくとも次を確認します。

1. `ProviderID`と表示名/短縮名を追加する。
2. `UsageProvider`実装をProvider専用ディレクトリへ置く。
3. AppDelegateのprovider implementation registryへ登録する。
4. 必要ならログインURL、dashboard URL、WebKit navigation許可範囲、Sign out動作、表示色を追加する。
5. parser/transport/authのfixtureテストを追加する。
6. 認証切れを表すProviderエラーでは`ProviderAuthenticationError`を実装し、通常のtimeout/429/5xxと認証要求を区別する。
7. 実アカウントで挙動を確認したあと、最後に`ProviderID.implemented`へ追加する。未検証のまま公開する場合は`isExperimental`、README、Issue Formを同時に更新する。

通信・認証・解析はProviderディレクトリへ閉じ込め、1サービスの失敗が他サービスへ波及しない設計を維持してください。また、次を満たすようにしてください。

- 認証付きHTTPリクエストのredirect先へ資格情報を持ち越さない。
- 明示的なCookie headerやBearer tokenをHTTPS以外へ送らない。
- Cookieやtokenをログへ出さない。
- 想定外レスポンスを成功扱いしない（fail closed）。
- parserは実アカウントではなくfixtureで境界値・欠損値・不正値をテストする。
- upstreamの仕様変更時にユーザーが次に取る行動を判断できるエラーメッセージにする。
- timeout/429/5xxなど一時的な失敗で、直前の認証済み状態や正常snapshotを不必要に破壊しない。
- 登録していないProviderへusage取得通信を開始しない。
- ProviderをRemoveした時点でin-flight取得が結果を書き戻せないことを確認する。

## UI変更

メニューバーアプリなので、通常ウインドウの感覚だけでなく次も確認してください。

- status itemからPopoverが正しい位置に開閉すること
- Provider 0件のempty stateと **+** 追加導線
- Provider追加/Remove/並び替え/メニューバー固定
- Provider数が少ない間はPopover自体が伸び、画面高を超える場合だけ一覧がスクロールすること
- ライト/ダークモード
- VoiceOverのラベルと操作
- ボタン操作中にカード全体のtap gestureが誤発火しないこと
- 取得中・エラー・stale状態が区別できること
- 一時的な通信エラーだけで`Sign out`が`Sign in`へ誤って切り替わらないこと

## セキュリティ問題

脆弱性や認証情報漏えいにつながる問題は公開Issueへ秘密情報を書かず、`SECURITY.md`の手順に従ってください。
