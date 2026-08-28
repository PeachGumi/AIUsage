# Contributing

IssueやPull Requestを歓迎します。AIUsageは認証済みセッションと非公開・非安定なProvider仕様を扱うため、機能追加だけでなく「失敗しても安全」「秘密情報を残さない」「他Provider・他アカウントへ影響させない」ことを重視します。

## 開発環境

- macOS 14以降
- Xcode 16.2以降
- XcodeGen（`project.yml`またはターゲット構成を変更するときだけ必要）

通常のビルドとCIはコミット済み`AIUsage.xcodeproj`を使います。

## 基本手順

1. 可能なら変更前に失敗するテストを追加する。
2. 最小の実装でテストを通す。
3. Unit TestsとRelease buildを実行する。
4. compiler warningと`git diff --check`を確認する。
5. token、Cookie、実APIレスポンス、workspace IDなどがdiffへ入っていないことを確認する。

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

## ProviderInstanceモデル

- `ProviderID`は統合種別です。同じProviderIDを持つカードが複数存在してよい前提で実装します。
- `ProviderInstance`は固有UUIDを持つ1アカウント / 1カードです。
- snapshot、error、auth state、refresh state、menu-bar selection、remove、rebuildはUUIDで識別します。
- 各Providerの最初のカードは`ProviderInstance.legacyID(for:)`を使うstable **default slot**です。旧one-card-per-provider設定の移行IDと共通にすることで、既存ユーザーとfresh installで同じcredential境界を使います。
- 外部CLI / アプリのambient credentialを利用できるのは原則default slotだけです。
- 追加カードはカード固有credentialを明示的に設定し、未設定・読み取り失敗時に兄弟カードのambient credentialへfallbackしてはいけません。
- `SettingsStore`と`UsageCoordinator`の両方でduplicate UUIDをfatalにしない防御を維持します。

## Provider公開ルール

`ProviderID.implemented`が **+** メニューへ公開する統合です。新しいProviderは実装しただけでは追加しません。

最低限、次を満たしてください。

1. parser / transport / authentication failureのfixture test
2. credentialの保存先・送信先・ownershipの明文化
3. unexpected responseを成功扱いしないfail-closed behavior
4. default slotとduplicate slotのcredential sourceの明確化
5. 同一Providerの2カードでrefresh / failure / remove / rebuildが相互汚染しないテスト
6. duplicate cardがambient credentialへ黙ってfallbackしないテストまたは構造上の保証
7. 実アカウント検証前に公開する場合はExperimental表示とREADME記載

## Removeの境界

Removeは現在のカードUUIDに属する**AIUsage所有データを掃除**し、外部クライアント所有データは触りません。

削除するもの:

- UUID別Keychain secret
- UUID別credential file path（ファイル本体は削除・変更しない）
- 新規OpenCode / Qwen instanceの専用WebKit data / workspace情報
- 削除カードのin-flight runtime state

削除しないもの:

- 旧バージョンから移行した共有default WebKit profile
- Codex CLI / Claude Code / GitHub CLI / Cursor.app / Kimi Code / Antigravityなど外部クライアント所有credential

Remove経路で、すでにdictionaryから取り出したinstance storeをcache accessor経由で再生成・再挿入しないよう注意してください。

## Antigravity

Antigravityは現在**1つのlocal sessionだけ**を公開します。複数カードはSettingsStoreで禁止します。

AIUsageへ以下の方式を追加しないでください。

- AntigravityのGoogle OAuth client metadataを別アプリartifactから抽出して第三者OAuthを開始する
- Antigravityのrefresh token / access tokenをAIUsage所有credentialとして保存する
- そのtokenでGoogleのremote Antigravity / Cloud Code quota endpointへ直接アクセスする

複数アカウントを実装する場合は、公式Antigravity CLIがcustom status-line scriptへ提供するdocumented local JSON payload（quota / email / plan tier等）を優先してください。AIUsage自身がGoogle account credentialを保持しないpassive ingestionを目標にします。

現行のExperimental Antigravity providerは実行中local processを検出します。将来status-line方式へ置き換える際も、未知payloadはfail closedし、実tokenや生status payloadをログへ残さないでください。

## WebKit Provider

OpenCode Go / Qwenではduplicate cardごとにpersistent `WKWebsiteDataStore`を分離します。

- default slotだけが旧WebKit profile / legacy migration sourceを利用可能
- 追加カードでlegacy Cookie / workspace IDを再利用しない
- Sign out / Removeは対象カードだけに作用する
- Qwen CookieはHTTPS / domain / path / expiryを検証する

## File / token Provider

Codex / Claudeのduplicate cardは別credential fileを明示選択します。AIUsageはpathだけを設定へ保存し、ファイルは読み取り専用です。

Copilot / Cursor / Kimiのduplicate cardはUUID別Keychain secretを利用します。Keychain read errorを`try?`で握りつぶしてambient loginへfallbackしないでください。

Z.AIはUUID別API keyを使い、legacy key / environment fallbackはdefault slotだけに限定します。

## 通信とエラー処理

- credential付きHTTP redirectへ資格情報を持ち越さない。
- 明示Cookie / bearer tokenをHTTPへ送らない。
- token / Cookie / account ID / workspace IDをログへ出さない。
- timeout / 429 / 5xxだけで認証済みstateやlast-good snapshotを破壊しない。
- authentication errorとtransient failureを区別する。
- 未登録Providerへusage取得通信を開始しない。
- card Remove / Sign out後に古い非同期結果を書き戻さない。

## Xcode project

`.swift`ファイルを追加した場合、コミット済みXcode projectのSources build phaseへ登録してください。CIが登録漏れを検出します。

Version / Buildは`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`を正とし、`Info.plist`へ別固定値を追加しません。

## テストデータ

fixture / log / Issue / PRへ以下を含めないでください。

- OAuth access / refresh token
- API key / bearer token
- Cookie / Cookie header
- account ID / workspace ID
- 実利用率を含む認証済みAPIレスポンス全文
- 個人を特定できるアカウント情報

Live TestsはREADMEのopt-in手順だけで実行し、結果をコミットしないでください。

## UI変更

- Provider 0件のempty state
- duplicate cardの追加 / Rename / drag / menu-bar selection
- Account…のcredential ownership説明
- transient error時にSign outが誤ってSign inへ変わらないこと
- Remove helpが実際の削除範囲と一致すること
- ライト / ダークモード
- VoiceOver label
- multi-displayでpopover位置・scroll上限

## セキュリティ問題

脆弱性や認証情報漏えいにつながる問題は公開Issueへ秘密情報を書かず、`SECURITY.md`の手順に従ってください。
