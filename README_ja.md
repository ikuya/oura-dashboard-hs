# oura-dashboard-hs

Oura Ring の生体データをローカルで閲覧するための Web ダッシュボード。
Oura Ring API v2 から取得したデータをローカルの SQLite に保存し、
既存の静的フロントエンド (Chart.js) へJSON API 経由で配信します。

JSON API は Python/Flask 版とバイト単位で互換なので、`static/` 配下のフロントエンドは
一切変更せずそのまま動作します。

> English version: [README.md](README.md)

## 機能

- 総合ダッシュボード: 睡眠・コンディション・アクティビティ・ストレス・血中酸素 (SpO2)・
  体温・心拍数・レジリエンス・VO2 Max・心血管年齢
- 差分同期（ローカル未保存の日付のみを取得）
- **アドバイス** — 直近14日間を `claude` CLI で分析し、日本語の健康サマリーを表示。
  結果は DB に保存され、後から閲覧可能
- **パスワード保護** — セッションベース。パスワードは bcrypt ハッシュとして
  `APP_PASSWORD` に保存
- 完全ローカル動作: Oura API と Claude CLI 以外の外部サービスに依存しません

## セットアップ

[Stack](https://get.haskellstack.org/) が必要です。初回ビルドでは GHC 9.10.3
(`stack.yaml` の `lts-24.50` に対応) のダウンロードと依存ツリー全体のコンパイルが
走るため相当な時間がかかります。2回目以降は高速です。

```bash
stack build
```

プロジェクトディレクトリに `.env` を作成します:

```bash
echo "OURA_TOKEN=your_token_here" > .env
echo "SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >> .env
```

`APP_PASSWORD` にはパスワードの **bcrypt** ハッシュを設定します。同梱の依存パッケージで
生成できます:

```bash
stack runghc --package bcrypt -- - <<'EOF'
import Crypto.BCrypt
import Data.ByteString.Char8 (pack, unpack)
main = hashPasswordUsingPolicy slowerBcryptHashingPolicy (pack "your_password")
       >>= putStrLn . maybe "FAIL" unpack
EOF
```

生成した値は **シングルクォートで囲んで** `.env` に追記してください。bcrypt ハッシュには
`$` が含まれるため、クォートしないと dotenv パーサが変数展開とみなし、起動時に
クラッシュします:

```
APP_PASSWORD='$2y$14$....'
```

## Oura アクセストークンの取得

1. https://cloud.ouraring.com/personal-access-tokens にアクセス（ログインが必要）
2. Personal Access Token を新規作成し、`OURA_TOKEN` に設定します

> API の利用には有効な Oura Membership が必要です。

## 起動

```bash
stack exec oura-dashboard-hs
```

http://localhost:3000 を開きます（ポートは `YESOD_PORT` で変更可能）。DB のパスは
既定で `oura.db` です（`YESOD_SQLITE_DATABASE` で変更可能）。

開発時は `stack exec -- yesod devel` で自動リロードが有効になります。

## 日次自動同期

`oura-daily-sync` 実行ファイルは差分同期を行い、直近7日以内の欠損日を埋めます:

```bash
stack exec oura-daily-sync
```

`run_daily_sync.sh` を cron に登録して運用します（日中の心拍データを最新に保つため、
1日に数回実行する想定です）。

## ログ

`LOG_FILE` を設定するとファイルに出力します。未設定の場合は stdout に出力します
（既定値。開発時はこちらが便利です）:

```bash
LOG_FILE=$PWD/log/oura-dashboard.log stack exec oura-dashboard-hs
```

`run_oura_dashboard.sh` と `run_daily_sync.sh` では、それぞれ
`log/oura-dashboard.log` と `log/oura-daily-sync.log` が自動的に設定されます。
各プロセスは独自のバッファ付きハンドルを保持するため、2つのプロセスで同一ファイルを
共有してはいけません。アプリ自身が記録できない起動時のクラッシュ等は、対応する
`*.stdio.log` に出力されます。ログファイルを開けない場合は、stderr に警告を出して
stdout にフォールバックし、起動は継続します。

Info 以上が記録されます。Debug を出すには `YESOD_SHOULD_LOG_ALL=true` が必要です。
各行の先頭にはローカル時刻のタイムスタンプが付きます:

```
2026-07-20 00:59:30 [Info] sync start: through 2026-07-20, ...
2026-07-20 00:59:31 [Warn] GET /v2/usercollection/daily_sleep returned HTTP 401
```

リクエストログ行は wai-logger の Apache 形式のままで、独自のタイムスタンプを持ちます。

### ローテーション

ローテーションは `logrotate` に任せます。Yesod のロガーと WAI のリクエストロガーは
どちらも `LoggerSet` を要求するため、fast-logger のローテーション付きロガー型は
ここでは使えません。`/etc/logrotate.d/oura-dashboard` を作成します:

```
/home/YOUR_USER/work/oura-dashboard-hs/log/*.log {
    size 10M
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

`copytruncate` は必須です。アプリがファイルを開いたまま保持するため、logrotate は
リネームではなくその場で切り詰める必要があります。確認方法:

```bash
sudo logrotate -d /etc/logrotate.d/oura-dashboard   # ドライラン
sudo logrotate -f /etc/logrotate.d/oura-dashboard   # 強制ローテーション
```

## テスト

```bash
stack test
```

## ディレクトリ構成

```
config/models.persistentmodels   既存 oura.db スキーマに対応する Persistent モデル
config/routes.yesodroutes         ルート定義
config/settings.yml               設定（シークレットは .env から取得）
src/Db.hs                         SQLite のクエリ/upsert 層 (db.py の移植)
src/Oura.hs                       Oura Ring API v2 クライアント（取得関数のレコード）
src/Sync.hs                       差分同期ロジック (sync.py の移植)
src/Advice.hs                     アドバイスのジョブ状態管理 + claude CLI ワーカー
src/Logging.hs                    ログ出力先の設定 (LOG_FILE、stdout フォールバック)
src/Foundation.hs                 アプリ基盤、セッション認証 (bcrypt)
src/Handler/Api.hs                認証 + metrics/heartrate/sync ハンドラ
src/Handler/Advice.hs             アドバイス用エンドポイント
src/Handler/Home.hs               static/index.html の配信
app/main.hs                       Web サーバのエントリポイント
static/                           既存フロントエンド (index.html, *.js, style.css)
```
