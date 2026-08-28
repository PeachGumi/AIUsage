# Contributing

IssueやPull Requestを歓迎します。AIUsageは認証済みセッションと非公開・非安定なProvider仕様を扱うため、機能追加だけでなく「失敗しても安全」「秘密情報を残さない」「他Provider・他アカウントへ影響させない」ことを重視します。

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
- API key / bearer token
- Cookie / Cookie header
- ChatGPT account ID
- OpenCode workspace ID
- 実利用率を含む実APIレスポンス全文
- 個人を特定できるアカウント情報

実アカウントテストは`README.md`記載のopt-in手順でローカル実行し、結果そのものをコミットしないでください。

## Provider登録モデル

Providerの統合種別と、ユーザーが登録する1アカウントは別概念です。

- `ProviderID` は統合種別です。同じ`ProviderID`のカードが複数存在してよい前提で実装してください。
- `ProviderInstance` は固有UUIDを持つ1アカウント/1カードです。永続設定、snapshot、error、auth state、refresh state、menu-bar selectionはUUIDで識別します。
- `ProviderID.implemented` が **+ メニューへ公開するProvider** のカタログです。実アカウント未検証の実装を公開する場合は`isExperimental`を必ず有効にし、UIとREADMEで明示します。
- `SettingsStore.registeredProviders` はユーザーが明示的に追加した`ProviderInstance`だけを保持します。重複`ProviderID`をdeduplicateしてはいけません。
- `UsageCoordinator`は登録済みinstanceだけを起動時・定期・手動の全更新対象にします。
- 旧one-card-per-provider設定から移行する最初のinstanceにはstable legacy UUIDを使い、既存sessionを壊さない互換経路を限定的に許可します。

### Removeのルール

Removeは単に一覧から隠すだけではありません。現在のカードUUIDに属する**AIUsage所有データを掃除**し、外部クライアント所有データは触らない境界を維持してください。

- UUID別Keychain secret / OAuth credentialは削除する。
- UUID別credential file pathは削除するが、参照先ファイル自体は削除・変更しない。
- 新規OpenCode / Qwen instanceの専用WebKit profile / workspace情報は削除する。
- 旧バージョンから移行した共有legacy profileは、他の既存利用を壊さないため破壊的に削除しない。
- Codex CLI / Claude Code / GitHub CLI / Cursor.app / Kimi Codeなど外部クライアント所有credentialは削除しない。
- Remove時点でin-flight取得を無効化し、古い結果が削除済みカードへ書き戻らないことを保証する。

将来のProviderを試作する際は、IDや実装コードが存在していても、fixtureテスト、認証境界、fail-closedの失敗時挙動、**同一Providerの複数instance間の分離**が整うまでは`ProviderID.implemented`へ追加しないでください。実アカウント検証前に公開する必要がある場合はExperimental扱いとし、公式dashboardとの照合結果やサニタイズ済み修正PRを募集してください。

## Providerを追加・変更するとき

新しいProviderを追加する場合は、少なくとも次を確認します。

1. `ProviderID`と表示名/短縮名を追加する。
2. `UsageProvider`実装をProvider専用ディレクトリへ置く。
3. AppDelegateのinstance-aware runtime factoryへ登録する。
4. 同一Providerを2枚以上追加したときのcredential sourceを決める。ambient credentialしか使えない実装を「複数アカウント対応」と誤表現しない。
5. 必要ならログインURL、dashboard URL、WebKit navigation許可範囲、Sign out / Disconnect動作、表示色を追加する。
6. parser/transport/authのfixtureテストを追加する。
7. 認証切れを表すProviderエラーでは`ProviderAuthenticationError`相当の扱いを実装し、通常のtimeout/429/5xxと認証要求を区別する。
8. 2つの同一Provider instanceについて、refresh / failure / remove / rebuild / sign-outが兄弟instanceへ影響しないことをテストする。
9. 実アカウントで挙動を確認したあと、最後に`ProviderID.implemented`へ追加する。未検証のまま公開する場合は`isExperimental`、README、Issue Formを同時に更新する。

通信・認証・解析はProviderディレクトリへ閉じ込め、1サービス・1アカウントの失敗が他へ波及しない設計を維持してください。また、次を満たすようにしてください。

- 認証付きHTTPリクエストのredirect先へ資格情報を持ち越さない。
- 明示的なCookie headerやBearer tokenをHTTPS以外へ送らない。
- Cookieやtokenをログへ出さない。
- 想定外レスポンスを成功扱いしない（fail closed）。
- parserは実アカウントではなくfixtureで境界値・欠損値・不正値をテストする。
- upstreamの仕様変更時にユーザーが次に取る行動を判断できるエラーメッセージにする。
- timeout/429/5xxなど一時的な失敗で、直前の認証済み状態や正常snapshotを不必要に破壊しない。
- 登録していないProviderへusage取得通信を開始しない。
- instance Aのcredentialをinstance Bへ黙ってフォールバックしない。互換目的のambient sourceを使う場合は対象instanceと条件を明示する。
- Provider cardをRemoveした時点でin-flight取得が結果を書き戻せないことを確認する。

## Antigravity固有ルール

新規Antigravity instanceは、別カードやambient Antigravity local sessionへ黙ってフォールバックさせないでください。各カードのGoogle OAuth token / refresh tokenはUUID別Keychain itemへ保存し、そのカードのremote quota取得にだけ使用します。

旧バージョンから移行した最初のAntigravity instanceのみ、専用OAuth credentialが未設定の間は互換性のため従来local integrationを利用できます。

OAuth client metadataや実tokenをfixture / sourceへコミットしないでください。client metadataはruntime discoveryまたは開発者向け環境変数で与え、実tokenはKeychain外へ永続化しません。

## UI変更

メニューバーアプリなので、通常ウインドウの感覚だけでなく次も確認してください。

- status itemからPopoverが正しい位置に開閉すること
- Provider 0件のempty stateと **+** 追加導線
- 同じProviderを複数回追加でき、カードを区別できること
- Provider追加/Remove/Rename/並び替え/メニューバー固定
- Provider数が少ない間はPopover自体が伸び、画面高を超える場合だけ一覧がスクロールすること
- ライト/ダークモード
- VoiceOverのラベルと操作
- ボタン操作中にカード全体のtap gestureが誤発火しないこと
- 取得中・エラー・stale状態が区別できること
- 一時的な通信エラーだけで`Sign out`が`Sign in`へ誤って切り替わらないこと
- Remove / Sign out / Account…の説明が実際のcredential ownershipと一致していること

## セキュリティ問題

脆弱性や認証情報漏えいにつながる問題は公開Issueへ秘密情報を書かず、`SECURITY.md`の手順に従ってください。
