# Privacy

AIUsageはローカルで動作するメニューバーアプリです。分析SDK、広告SDK、クラッシュ収集サービス、独自サーバーは使用しません。

## ローカルで扱う情報

- OpenCode Go: WKWebViewのログインセッションとworkspace ID
- Qwen Cloud: WKWebView Cookie、または旧QwenUsageの移行用Cookieヘッダー
- OpenAI Codex: `~/.codex/auth.json`内の既存OAuthアクセストークンと任意のアカウントID
- 表示設定: 選択Providerと残量／使用量の選択

認証情報はProviderの公式Webサイトまたはusage endpointへの通信にだけ使用します。AIUsageの独自サーバーへ送信されることはありません。

## 保存

- 設定とOpenCode workspace IDは`UserDefaults`へ保存します。
- OpenCodeとQwenのWebログイン情報はmacOS WebKitの標準データストアが管理します。
- AIUsageはQwen Cookieの平文コピーを新規作成しません。
- 旧QwenUsageの平文Cookieは移行フォールバックとして`https://home.qwencloud.com`に対してのみ読み取り可能です。AIUsageで新しいQwenログインが成功した後、またはSign outした後は再利用しません。
- Codexの認証ファイルは読み取りのみで、変更しません。

## ログ

OAuthトークン、Cookie、アカウントID、workspace ID、APIレスポンス本文、実使用率をアプリのログへ出力しません。

## 通信

- CodexのBearer付きリクエストはHTTPリダイレクトを拒否します。
- QwenのCookie付きリクエストもHTTPリダイレクトを拒否します。
- URLSessionはephemeral設定を使い、共有Cookie・資格情報・URLキャッシュを無効化します。
- Qwen Cookieは送信先のscheme/domain/path/expiryを確認し、旧Cookie移行フォールバックは`home.qwencloud.com`以外へ送信しません。

## データ削除

アプリ内のSign outで、AIUsageのWebKitデータストアにある対象サービスのWebデータを削除できます。旧QwenUsageの移行元ファイルはロールバックを壊さないため削除しませんが、AIUsage側ではSign out後のフォールバック利用を無効化します。
