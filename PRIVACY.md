# Privacy

AIUsageはローカルで動作するmacOSメニューバーアプリです。分析SDK、広告SDK、クラッシュ収集サービス、独自サーバーは使用しません。

AIUsageは初回起動時にProviderを自動登録しません。ユーザーがPopoverの **+** から明示的に追加したProviderアカウントだけが、起動時・定期更新・手動更新のusage取得対象になります。同じProviderを複数回追加した場合も、各カードは固有のUUIDを持つ独立したアカウントスロットとして扱います。

## ローカルで扱う情報

- OpenCode Go: アカウントごとのWKWebViewログインセッションとworkspace ID。旧バージョンから移行した最初のカードだけは既存のdefault WebKit profileを継承します。
- Qwen Cloud: アカウントごとのWKWebView Cookie。旧バージョンから移行した最初のカードだけは既存profileと旧QwenUsageの一度限りのCookie移行経路を利用できます。
- OpenAI Codex: 通常は`~/.codex/auth.json`内の既存OAuth認証を読み取り専用で利用します。別アカウント用カードでは、ユーザーが選択した別の`auth.json`へのパスをローカル設定へ保存できます。
- Claude: 通常はClaude Codeの既存認証情報を読み取り専用で利用します。別アカウント用カードでは、ユーザーが選択したcredential fileへのパスをローカル設定へ保存できます。
- Antigravity: 新規アカウントカードではGoogle OAuthのaccess token / refresh tokenなどをカードUUIDごとにmacOS Keychainへ保存します。旧バージョンから移行した最初のカードは、専用OAuthを接続するまでは従来のローカルAntigravityセッションを利用できます。
- GitHub Copilot: 通常は`GH_TOKEN` / `GITHUB_TOKEN`またはGitHub CLIの既存tokenを利用します。カード固有tokenを設定した場合はmacOS Keychainへ保存します。
- Cursor: 通常はCursor.appの既存認証情報を読み取り専用で利用します。カード固有tokenを設定した場合はmacOS Keychainへ保存します。
- Z.AI: カードUUIDごとのCoding Plan API keyをmacOS Keychainへ保存します。旧バージョンから移行した最初のカードでは既存のlegacy keyも互換用途で利用できます。
- Kimi Code: 通常はKimi Code CLI認証または環境変数を利用します。カード固有API keyを設定した場合はmacOS Keychainへ保存します。
- 表示設定: 登録アカウント、カードUUID、任意のローカル表示名、選択中カード、並び順、残量／使用量の選択。

認証情報は対象Providerの公式Webサイト、OAuth endpoint、usage endpointへの通信にだけ使用します。AIUsage独自のサーバーへ送信されることはありません。

## ProviderのRemoveとSign out

**Remove** は、そのカードをAIUsageの表示・更新対象から外し、そのUUIDにだけ属するAIUsage所有データを削除する操作です。

- UUID別のKeychain credential / Antigravity OAuth credentialを削除します。
- Codex / Claudeで選択したUUID別credential file pathを削除します。参照先のファイル自体は削除・変更しません。
- 新規作成したOpenCode / Qwenカードでは、そのカード専用WebKitデータとworkspace情報を削除します。
- 旧バージョンから移行した最初のカードが共有するlegacy WebKit profileや外部クライアントの認証状態は、破壊的な移行を避けるためRemoveでは削除しません。
- Codex CLI、Claude Code、GitHub CLI、Cursor.app、Kimi Codeなど、外部クライアント側が所有する認証情報は削除しません。

**Sign out / Disconnect** は、対応しているProviderについて現在のカードのAIUsage所有認証状態を明示的に切断する操作です。外部クライアントの認証まで消したい場合は、各公式クライアント側でログアウトしてください。

## 保存

- Provider一覧、カードUUID、ラベル、並び順、選択中カード、credential file pathなどの非秘密設定は`UserDefaults`へ保存します。
- OpenCode workspace IDはカードごとのnamespaceで`UserDefaults`へ保存します。
- OpenCodeとQwenのWebログイン情報はmacOS WebKitのpersistent data storeでカードごとに分離します。
- AIUsageはQwen Cookieの平文コピーを新規作成しません。
- 旧QwenUsageの平文Cookieは、移行済み最初のQwenカードについて`https://home.qwencloud.com`への一度限りの移行用途に限定します。AIUsageで新しいQwenログインが成功した後、またはSign out後は再利用しません。
- 旧GoUsageのworkspace IDも、移行済み最初のOpenCodeカードについて一度限りの移行元として扱います。
- AIUsage所有のAPI key、カード固有token、Antigravity OAuth tokenはmacOS Keychainへ保存します。
- 外部クライアントのcredential fileや認証DBを利用する場合、それらは読み取り専用で扱い、AIUsageから変更しません。

## ログ

OAuth access token / refresh token、Cookie、API key、アカウントID、workspace ID、実APIレスポンス本文、実使用率をアプリのログへ出力しません。

## 通信

- 登録されていないProviderへusage取得通信を開始しません。
- 同一Providerを複数登録していても、カードごとの認証情報・snapshot・error・refresh stateをUUIDで分離します。
- ProviderカードをRemoveするとin-flight取得を無効化し、古い結果が画面へ復活しないようにします。
- 資格情報付きProviderリクエストはHTTPリダイレクトを拒否します。
- URLSessionはephemeral設定を使い、共有Cookie・資格情報・URLキャッシュを無効化します。
- Qwen Cookieは送信先のscheme/domain/path/expiryを確認し、旧Cookie移行フォールバックは`home.qwencloud.com`以外へ送信しません。
- Antigravityの新規カードは、そのカード専用Google OAuth tokenでGoogleのquota endpointへ問い合わせます。専用credentialがない新規カードが別カードのambient Antigravityセッションへ黙ってフォールバックすることはありません。

## データ削除

カードの **Remove** で、そのUUIDに属するAIUsage所有credential・設定・専用Webセッションを削除できます。対応Providerでは **Sign out / Disconnect** でも現在のカードのAIUsage所有認証を削除できます。

AIUsageは外部クライアントが所有する認証ファイル・認証DB・Keychain項目を削除しません。また、旧バージョンから移行した共有profileについては、他の既存利用を壊さないため破壊的な自動削除を行いません。
