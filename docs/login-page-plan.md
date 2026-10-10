# ログイン専用画面 設計記録

未認証アクセスでダッシュボードの中身が露出しないよう、ログイン専用画面を設ける。
以下は grill インタビューで合意した設計判断の記録。

## 前提

従来の認証は HTTP BASIC 認証ではなく、`GET /` が `static/index.html` を認証なしで返し、
`/api/*` が 401 を返したときに JS がログインモーダルを重ねる方式だった。
守られていたのは `/api/*` のデータだけで、Censys / Shodan 等には
`<title>Oura Dashboard</title>`、カード名、ボタン、`/static/*.js` のソースまで見えていた。
`static/index.html` は static ディレクトリ内にあるため `/static/index.html` でも取得できた。

## スコープ

- 未認証には中立的なログインページ以外を返さない
- 未認証 `/api/*` の応答や Warp の `Server` ヘッダ等のフィンガープリント対策はしない
- HTTPS 化は別タスク。現状の平文 HTTP ではパスワードとセッション Cookie は経路上で読める

## ルートと未認証時の応答

認可は `Foundation.hs` の `isAuthorized` に集約する。

| ルート | 未認証時 |
|---|---|
| `/` (HomeR) | `303 → /login` |
| `/login` GET/POST | 公開。ログイン済みの GET は `303 → /` |
| `/logout` POST | 公開（セッションを消して `303 → /login`） |
| `/static/*` | 404（存在を明かさない） |
| `/api/*` | `401 {"error":"Unauthorized"}`（JS がセッション切れを検知して `/login` へ遷移） |
| `/favicon.ico`, `/robots.txt` | 公開 |

## ログイン方式

JS を使わない素の HTML フォーム。`POST /login` は `password` と `_token` を受け取り、
成功で `303 → /`、失敗で `/login` を再表示して "Invalid password" を出す。
ブラウザのパスワードマネージャが確実に効く。

ページは `templates/login.hamlet` を `withUrlRenderer` で直接描画し、CSS はインライン。
`defaultLayout` は `addStaticContent` が `/static/tmp/` に CSS を書き出し、
未認証では 404 になるため使わない。

表示は中立的にする: title と見出しは "Sign in"、アプリ名・Oura・日本語文言は出さない。
配色は `style.css` の値を手で写したダーク系。

## CSRF

- `laxSameSiteSessions` で別サイトからの POST にセッション Cookie を送らせない
- `defaultCsrfMiddleware` でトークン照合。`api.js` の POST は `XSRF-TOKEN` Cookie を
  `X-XSRF-TOKEN` ヘッダに載せ、ログイン / ログアウトのフォームは hidden `_token` を持つ

`jsonBodyOrEmpty` はパース失敗を空オブジェクト扱いするため、従来は別サイトの
`text/plain` フォームから `/api/sync` や `/api/advice` を起動できる余地があった。

## Secure Cookie

`settings.yml` に `secure-cookies: "_env:YESOD_SECURE_COOKIES:false"` を追加。
true のときのみ `sslOnlySessions` で包み、HSTS ヘッダを付ける。
HTTP で有効にすると Cookie が送られずログインできなくなるので常時オンにはしない。

## ブルートフォース対策

`App` に IP ごとの失敗記録（`TVar`）を持たせる。15 分以内に 5 回失敗した IP は、
その窓が明けるまで `POST /login` を 429 で拒否する。失敗は `$logWarn` で IP を記録し、
成功でその IP の記録を消す。再起動で消えるのは許容。

## 既存部品の整理

- `POST /api/login` は削除（レート制限の抜け道になるため）
- `POST /api/logout` は `POST /logout` に置き換え。ヘッダの Logout ボタンは `apiFetch` で
  POST してから `/login` へ遷移する（`index.html` は静的ファイルでトークンを埋め込めないため、
  フォーム化はせず CSRF ヘッダで送る）
- `index.html` の `#login-overlay` と `main.js` のログインモーダルは削除
- `api.js` の 401 処理は `location.href = "/login"`
- `test/AppSpec.hs` の `login` ヘルパーとログイン系テストはフォーム + CSRF 前提に書き直す
