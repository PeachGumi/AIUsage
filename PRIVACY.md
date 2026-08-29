# Privacy

AIUsageはローカルで動作するmacOSメニューバーアプリです。分析SDK、広告SDK、クラッシュ収集サービス、独自サーバーは使用しません。

初回起動時にProviderを自動登録しません。ユーザーがPopoverの **+** から明示的に追加したカードだけが、起動時・定期更新・手動更新の対象です。

## アカウント分離

各カードは`ProviderInstance` UUIDで識別します。snapshot、error、refresh state、authentication state、表示順、メニューバー選択はUUID単位で分離します。

各Providerの最初のカードはstable default slotです。このカードだけが、必要に応じて外部CLI / アプリの通常のambient credentialを利用できます。追加カードは兄弟カードのambient credentialへ黙ってfallbackせず、カード専用credentialが必要です。

Antigravityは現在1枚だけ登録できます。AIUsageはAntigravity用Google OAuth tokenを作成・保存せず、Googleのremote quota endpointへ直接アクセスしません。

## ローカルで扱う情報

- **OpenCode Go** — カードごとのWKWebView login sessionとworkspace ID。default cardは旧GoUsage workspace IDの一度限りの移行元を利用できます。
- **Qwen Cloud** — カードごとのWKWebView Cookie。default cardは旧QwenUsage Cookieの一度限りの移行元を利用できます。
- **OpenAI Codex** — default cardは通常のCodex OAuth credentialを読み取り専用で利用します。追加カードではユーザーが選択した別`auth.json`へのpathだけをAIUsage設定へ保存します。
- **Claude** — default cardは通常のClaude Code credentialを読み取り専用で利用します。追加カードでは選択したcredential fileへのpathだけを保存します。
- **Antigravity** — 実行中の公式Antigravity local processを検出し、localhost上のusage interfaceへ問い合わせます。Google OAuth credentialはAIUsageへ保存しません。
- **GitHub Copilot** — default cardは`GH_TOKEN` / `GITHUB_TOKEN` / GitHub CLI loginを利用できます。追加カードのtokenはUUID別にmacOS Keychainへ保存します。
- **Cursor** — default cardはCursor.appの既存loginを読み取り専用で利用できます。追加カードのtokenはUUID別にmacOS Keychainへ保存します。
- **Z.AI** — UUID別Coding Plan API keyをmacOS Keychainへ保存します。default cardは旧AIUsage key / environmentを互換利用できます。
- **Kimi Code** — default cardはKimi Code CLI / environmentを利用できます。追加カードのAPI keyはUUID別にmacOS Keychainへ保存します。
- **表示設定** — 登録カード、UUID、任意のローカル表示名、選択中カード、並び順、Remaining / Used設定。

## 保存先

- 非秘密設定、credential file path、OpenCode workspace ID: `UserDefaults`
- OpenCode / Qwen Web login: macOS WebKit persistent data store
- AIUsage所有API key / token: macOS Keychain
- 外部CLI / アプリのcredential file / DB / Keychain item: 読み取り専用。AIUsageから変更しません

AIUsageは新しいQwen Cookieの平文コピーを作成しません。旧QwenUsageの平文Cookieはdefault cardの一度限りの移行用途だけに限定し、AIUsageで新しいloginが成功した後やSign out後は再利用しません。

## Remove / Sign out

**Remove** はカードを一覧から外すだけでなく、そのUUIDに属するAIUsage所有データを削除します。

- UUID別Keychain secretを削除
- UUID別credential file pathを削除（参照先ファイル本体は削除・変更しない）
- 新規OpenCode / Qwenカードの専用WebKit data / workspace情報を削除
- in-flight取得を無効化し、削除後に古い結果が戻らないようにする

旧バージョンから移行したdefault WebKit profileや、Codex CLI / Claude Code / GitHub CLI / Cursor.app / Kimi Code / Antigravityなど外部クライアント所有credentialは削除しません。

対応Providerの **Sign out** は現在のカードについてAIUsageが所有するWeb login / API keyだけを削除します。外部クライアントそのものからlogoutしたい場合は公式クライアント側で操作してください。

## 通信

- 未登録Providerへusage取得通信を開始しません。
- URLSessionによるProvider HTTP通信はephemeral設定を基本とし、共有Cookie / URL cache / credential storageを使いません。
- credential付きHTTP redirectは拒否します。
- Qwen CookieはHTTPS・domain・path・expiryを確認してから明示headerを構築します。
- Antigravityはremote Google OAuth経路を持たず、現在はlocal process integrationだけです。
- duplicate cardのcredentialが未設定・読み取り失敗の場合、default cardのcredentialへfallbackせず認証エラーとしてfail closedします。

## ログ

OAuth token、API key、Cookie、Cookie header、account ID、workspace ID、実APIレスポンス本文、実使用率をアプリログへ出力しません。

## データ削除

カードの **Remove** で、そのUUIDに属するAIUsage所有credential / setting / dedicated Web sessionを削除できます。外部クライアント所有データと共有legacy profileは破壊的に自動削除しません。
