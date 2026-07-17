# oura-dashboard Haskell/Yesod 移植 計画書

Python/Flask 版 `oura-dashboard` を Haskell + Yesod に移植する。以下は grill インタビューで合意した設計判断の記録。

## スコープ

- **バックエンドのみ移植**（スコープ A）。既存の静的フロントエンド（`static/` 配下の `index.html` / `main.js` / `charts.js` / `helpers.js` / `api.js` / `style.css`）は**無改変**でそのまま配信する。
- **JSON API の契約をバイト互換で維持**することが絶対条件。フロントの `main.js` / `charts.js` は既存のレスポンス形状に依存しているため、レスポンスの形・ステータスコード・エラー JSON 形（`{"error": ...}`）を Python 版に一致させる。
- フロントの Yesod テンプレート化（Hamlet/Julius/Cassius）は**行わない**。必要なら別フェーズとして後回し。

## 技術選定

| 項目 | 選定 | 備考 |
|---|---|---|
| ビルドツール | **Stack** | `stack new oura-dashboard-hs yesod-sqlite` scaffold をベースにする。`yesod devel` のホットリロードを移植中の反復に使う。 |
| DB 層 | **Persistent + 既存スキーマ踏襲** | 既存 `oura.db` を維持。Persistent モデルに `sql=` アノテーションで既存のテーブル名・カラム名・複合ユニーク制約を合わせ込む。Python 版と同じ DB ファイルを指し、新旧の出力差分を同一データで検証する。 |
| API レスポンス JSON | **aeson `Value` で動的合成** | `data_json` は不透明な `Value`（`Object`）のまま扱う。型付き構造体は作らない。`day` / `score` を最後に `insert` して Python の `{**data, ...}` の上書き順序に一致させる。 |
| HTTP クライアント | **http-conduit（`Network.HTTP.Simple`）** | `httpJSON` でレスポンスを `Value` にデコード。`next_token` ページネーションループ、15秒タイムアウト、401 のヒント付きエラー、heartrate のみ `start_datetime`/`end_datetime` を写経。 |
| 認証機構 | **Yesod 標準クライアントセッション + 自前の最小パスワード照合** | `yesod-auth` は使わない。`setSession`/`lookupSession` で Flask のセッション使用感を再現。`isAuthorized` で「`/api/login` と `/` 以外は認証必須」を一括表現する（実装時に詰める）。 |
| パスワードハッシュ | **bcrypt で再生成** | werkzeug の pbkdf2 フォーマットは写経せず、Haskell の `bcrypt` パッケージで照合。`.env` の `APP_PASSWORD` を一度だけ bcrypt ハッシュに再設定し、README も更新する。 |
| エラーハンドリング | **Python の分岐を素直に写経** | `sendResponseStatus statusN (object ["error" .= msg])` で明示。`OuraAPIError` は例外にせず `Either` で捕捉し、`result.errors` 相当に文字列で詰める（一部メトリクス失敗でも他は継続する耐障害性を維持）。 |
| advice 非同期ジョブ | **プロセス内 `TVar` + `forkIO` で写経** | Foundation の App に `TVar (Map JobId AdviceJob)` を追加、`makeFoundation` で初期化。`forkIO` でワーカー起動、`System.Process` で `claude` CLI 実行、`System.Timeout.timeout` で 120 秒制限。3分岐（コマンド無し / タイムアウト / `exitCode /= 0`）を写経。成功時のみ `advice_history` に保存。ジョブは**非永続**（プロセス再起動で消える現行仕様を維持）。 |
| 設定・`.env` | **`Configuration.Dotenv` で読込 + `AppSettings` に型付き集約** | `.env` をプロジェクトに置けば効く運用を維持（`onMissingFile` で `.env` 不在でも壊れない）。`SECRET_KEY` 必須チェックは `makeFoundation` で一箇所に。 |
| 実行ファイル構成 | **1 ライブラリ + 2 実行ファイル** | 共通ロジック（settings / DB / oura client / sync）を `library` に。`oura-dashboard-hs`（Web / Warp 起動）と `oura-daily-sync`（cron 用 CLI）の 2 executable。`run_daily_sync.sh` は後者を呼ぶ形に更新。 |
| 静的配信 | **`yesod-static` 実行時ディレクトリ配信** | `static "static"`（開発時 `staticDevel`）で `/static/<path>` にマッピング。フロントは `/static/style.css` `/static/main.js` を固定パス参照しており、scaffold の `/static` サブサイト URL 規約と一致。TH 埋め込み（`staticFiles`）はハッシュ付き URL で固定参照と非互換のため不採用。`GET /`（Home ハンドラ）は `static/index.html` を返すだけに差し替え。CDN 参照（Chart.js/luxon/marked）は配信対象外。 |
| テスト | **Hspec 移植（主軸）+ 差分検証（補助）** | 下記参照。 |

## 移植で維持する既存挙動（写経対象の要注意点）

- `daily_metrics.data_json` に Oura 生レスポンス全体を JSON 文字列で保持し、`score` だけカラム分離。読み出し時に `data_json` をパースして `day`/`score` をマージして返す。**DB の `score` カラムが `data_json` 内の score を上書き**する precedence。
- `sync_log` の後付けカラム `last_synced_at`（Python 版は `ALTER TABLE ... ADD COLUMN`）を Persistent マイグレーション / `sql=` でどう表現するかは実装時に詰める。
- temperature は独立エンドポイントを持たず、**readiness から派生**して `daily_metrics` に別途保存。
- heartrate は API の 30 日窓制限を、`window_end` から遡るループで回避。5 分解像度で別テーブルに保存。`INSERT OR IGNORE` 相当（Persistent では衝突無視の upsert）で部分日ギャップを埋める。
- `find_missing_range`: 直近 `REFETCH_DAYS`(=7) 日は Oura のスコア遡及更新のため常に再取得。
- `_backfill_ranges`: `score IS NOT NULL` の日のみ「存在」とみなし、null スコア日は再取得対象。heartrate はウィンドウ全体を常に返す。
- `daily_sync` CLI: JST タイムスタンプ付きログ、`backfill_days=7`、エラー時 exit code 1。
- resilience の categorical level（limited/adequate/solid/strong/exceptional）→ 序数マッピング。
- advice のエラーメッセージ（「claude コマンドが見つかりません…」等）は Python 版の日本語文字列を踏襲。

## テスト方針

- **主軸（A）**: `hspec` + `yesod-test`（scaffold 標準）で既存の約 60 ケースを 1 対 1 移植。3 層構成を踏襲。
  - db 層 → in-memory SQLite（`:memory:`）に Persistent を走らせる単体テスト。
  - sync 層 → `OuraClient` を「record of functions」または型クラスで抽象化し、テスト用スタブを差し込む。30 日窓ループ / backfill ギャップ検出 / temperature 派生 / score=null 再取得などのエッジケースを移植。
  - app 層 → `yesod-test` で HTTP レベルにハンドラを叩きステータス・JSON を検証。advice のサブプロセス実行部分はモック/注入で差し替え。
- **補助（B）**: 移植完了時の受け入れ検証として、同一 `oura.db` に対し Python 版と Haskell 版の実レスポンスを diff する使い捨てスクリプト。キー順序 / 数値フォーマット（`80.0` vs `80`）/ 日本語の非 ASCII エスケープ差を炙り出す。CI 常設はしない。

## 実装順序（ボトムアップ 8 フェーズ）

各フェーズは既存テストの層構造に成功基準を一致させる。

1. Stack scaffold 生成 + `AppSettings` / `.env` 読み込み → **verify:** ビルド＆起動
2. Persistent モデル（既存スキーマ合わせ込み）+ DB クエリ関数 → **verify:** `test_db` 相当が通る
3. Oura クライアント + sync ロジック → **verify:** `test_sync` 相当が通る（スタブ使用）
4. 認証 + metrics / heartrate / sync API ハンドラ → **verify:** `test_app` の該当分が通る
5. advice 非同期ジョブ → **verify:** `test_app` の advice 分が通る
6. 静的配信 + `GET /` → **verify:** ブラウザで実データ表示
7. daily-sync 実行ファイル → **verify:** CLI 実行して DB 更新
8. 差分検証スクリプト（B）で新旧 JSON を diff → **verify:** 契約一致

## 移植に伴う許容済みの挙動変更

- パスワードハッシュ形式変更に伴い `.env` の `APP_PASSWORD` を bcrypt で再設定（README 更新）。**bcrypt ハッシュ（`$2y$...`）はシングルクォートで囲む**こと（dotenv が `$` を変数展開と誤解釈して起動クラッシュするため）。
- Flask と Yesod のセッションクッキー非互換により、移植後は既存ログインセッションが無効化され再ログインが必要（個人用ローカルアプリのため許容）。
- **`score` の数値表現**: DB の `score` カラムは SQLite REAL。Python は `84.0` と出力するが、Haskell/aeson は `Value` 経由で whole number を `84` に正規化する。**数値としては同一**で、フロント（`charts.js`）は JS の Number として扱うため描画は完全に同じ。差分検証（Phase 8）は数値正規化した上で全エンドポイント一致を確認済み。厳密なバイト一致より、フロント透過性を優先して許容。

## Phase 8 差分検証の結果

`scripts/diff_verify.sh` で Python版と Haskell版を同一 `oura.db` コピーに対して起動し、5エンドポイント（sync/status, metrics 複数, metrics/sleep, heartrate, advice/history）の JSON を `jq -S` + 数値正規化で比較 → **全て一致（exit 0）**。キー・構造・値が意味的に完全一致することを実データで確認。
