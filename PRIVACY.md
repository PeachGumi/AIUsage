# Privacy

AIUsageはローカルで動作するメニューバーアプリです。分析SDK、広告SDK、クラッシュ収集サービス、独自サーバーは使用しません。

AIUsageは初回起動時にProviderを自動登録しません。ユーザーがPopoverの **+** から明示的に追加したProviderだけが、起動時・定期更新・手動更新のusage取得対象になります。

## ローカルで扱う情報

- OpenCode Go: WKWebViewのログインセッションとworkspace ID
- Qwen Cloud: WKWebView Cookie、または旧QwenUsageの移行用Cookieヘッダー
- OpenAI Codex: `~/.codex/auth.json`内の既存OAuthアクセストークンと任意のアカウントID
- 表示設定: 登録Provider、選択Provider、並び順、残量／使用量の選択

認証情報はProviderの公式Webサイトまたはusage endpointへの通信にだけ使用します。AIUsageの独自サーバーへ送信されることはありません。

## ProviderのRemoveとSign out

**Remove** は、そのProviderをAIUsageの表示とusage更新対象から外します。RemoveだけではWebKitログイン情報、OpenCode workspace ID、Codex CLIの認証ファイルなどを削除しません。再追加したときに既存セッションを利用できるよう、登録状態と認証状態は分離しています。

認証状態まで削除したい場合は、対応Providerの **Sign out** を使用してください。Codexの認証ファイルはAIUsageが変更しないため、Codex CLI側でログアウトします。

## 保存

- 設定とOpenCode workspace IDは`UserDefaults`へ保存します。
- 旧GoUsageのworkspace IDが存在する場合は初回移行にだけ利用します。AIUsageで保存後、またはOpenCodeからSign outした後は旧ファイルから再移行しません。
- OpenCodeとQwenのWebログイン情報はmacOS WebKitの標準データストアが管理します。
- AIUsageはQwen Cookieの平文コピーを新規作成しません。
- 旧QwenUsageの平文Cookieは移行フォールバックとして`https://home.qwencloud.com`に対してのみ読み取り可能です。AIUsageで新しいQwenログインが成功した後、またはSign outした後は再利用しません。
- Codexの認証ファイルは読み取りのみで、変更しません。

## ログ

OAuthトークン、Cookie、アカウントID、workspace ID、APIレスポンス本文、実使用率をアプリのログへ出力しません。

## 通信

- 登録されていないProviderへusage取得通信を開始しません。
- ProviderをRemoveするとin-flight取得を無効化し、古い結果が画面へ復活しないようにします。
- CodexのBearer付きリクエストはHTTPリダイレクトを拒否します。
- QwenのCookie付きリクエストもHTTPリダイレクトを拒否します。
- URLSessionはephemeral設定を使い、共有Cookie・資格情報・URLキャッシュを無効化します。
- Qwen Cookieは送信先のscheme/domain/path/expiryを確認し、旧Cookie移行フォールバックは`home.qwencloud.com`以外へ送信しません。

## データ削除

アプリ内のSign outで、AIUsageのWebKitデータストアにある対象サービスのWebデータを削除できます。OpenCodeの保存済みworkspace IDもSign out時に削除します。旧GoUsageのworkspace IDファイルや旧QwenUsageのCookieファイル自体は変更・削除しませんが、AIUsage側ではSign out後の再移行・フォールバック利用を無効化します。
