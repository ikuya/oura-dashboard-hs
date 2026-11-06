# oura-dashboard-hs コード全体の解説

> 最終更新: 2026-11-06（`582fbca` 時点）

## 1. これは何をするコードか

Oura Ring が計測した生体データ（睡眠・準備度・活動量・ストレス・SpO2・体温・心拍・レジリエンス・VO2 Max・心血管年齢）と、ユーザー自身の記録（タグ・ワークアウト・セッション）を、Oura API v2 からローカルの SQLite に取り込み、Chart.js 製の静的フロントエンドに JSON API で配信する、**ローカル完結型の Yesod (Haskell) Web アプリ**です。

Python/Flask 版 `oura-dashboard` からの移植で、**Python 版から引き継いだ JSON API はバイト単位で互換**に保たれています。その上で、睡眠段階（`/api/sleep_periods`）・月平均（`/api/monthly`）・タグ等のイベント（`/api/events`）の各 API は Haskell 版で追加したもので、`static/` 配下のフロントエンドもこれらを使う形で Python 版から大きく拡張されています。

加えて、`claude` CLI を子プロセスとして起動し、直近 14 日分のデータから日本語のヘルスアドバイスを生成する機能を持ちます。Web からの非同期ジョブと、cron から定期実行する CLI（`oura-advice`）の 2 経路があり、どちらも直前のアドバイスを踏まえて「前回からの変化」を書かせます。cron の日次同期（`oura-daily-sync`）は同期後に DB のバックアップも取ります。

### たとえるなら

このアプリは **「自宅にある個人用の健康カルテ棚」** です。

- **Oura API** = 病院の検査機関。問い合わせれば結果をくれるが、毎回聞くのは遅いし失礼
- **SQLite (`oura.db`)** = 手元のカルテ棚。一度もらった検査結果はここに綴じておく
- **`Sync.hs`** = カルテ係。棚を見て「この日の分がまだ無い」と気づいたところだけ検査機関に取りに行く（＝増分同期）
- **Handler 層** = 受付窓口。閲覧者の身分証（セッション）を確認してから棚の中身を出す
- **`Advice.hs`** = 顧問医。カルテと前回の所見を読んで新しい所見を書くが、時間がかかるので「後で取りに来てください」と整理券（ジョブ ID）を渡す。週に何度かは頼まれなくても往診に来る（`ScheduledAdvice`）
- **`Backup.hs`** = 毎晩カルテ棚の写しを取って倉庫にしまう係。検査結果は再発行してもらえるが、顧問医の所見は二度と手に入らないため
- **`Metric.hs` / `DateText.hs`** = カルテ棚のラベル規格。「メトリック名」「日付」はどこでも同じ書式・同じ語彙で扱う、という約束事をコンパイラに守らせる係

### 主要コンポーネント

| ファイル | 行数 | 役割 |
|---|---|---|
| `src/Oura.hs` | 151 | Oura API v2 クライアント。**fetch 関数を持つレコード型** (`OuraClient`) にすることで、テスト時にスタブへ差し替え可能。next_token ページネーション、15 秒タイムアウト、HTTP ステータスと例外を `OuraError` に正規化 |
| `src/Db.hs` | 469 | SQLite クエリ層。既存 Python スキーマとの 1:1 互換を保つため raw SQL 中心（`INSERT OR REPLACE` / `INSERT OR IGNORE`、`substr`、`json_extract`、`GROUP BY`）。イベントの置き換え保存、月平均の集計もここ。export リストなしで `module Db where` |
| `src/Sync.hs` | 364 | 増分同期の中核。`findMissingRange` / `backfillRanges` / `runSync`。心拍のみ 30 日窓で逆方向にループ |
| `src/Advice.hs` | 425 | アドバイス生成。ペイロード構築・プロンプト・`claude` CLI 実行（`generateAdvice`、120 秒タイムアウト）と、TVar 上のインメモリ Map + `forkIO` ワーカーによる Web 用ジョブ |
| `src/Metric.hs` | 121 | `DailyMetric` / `EventKind` / `Metric` 型。メトリック名を `dailyMetricName` / `eventKindName` に一元化。`allDailyMetrics = [minBound..maxBound]` で総当たりを保証 |
| `src/DateText.hs` | 87 | `DayText`（`YYYY-MM-DD` の newtype）と `DateRange`。`parseDayText` は外部入力向けの検証付き `Maybe` 版、`parseDay` は `Day` への変換で失敗時 `error`。`todayIn` / `todayUtc` |
| `src/Json.hs` | 42 | `Value` に対する `jsonLookup`/`jsonText`/`jsonDouble`/`jsonInt`/`jsonArray`。Oura API のペイロードと `data_json` を読むための共通ヘルパー |
| `src/KeyedCache.hs` | 33 | 「キー付きの 1 値キャッシュ」。キーが同じ間は前回の計算結果を再利用する（`/api/monthly` 用） |
| `src/Logging.hs` | 97 | `AppLog`（`LogLevel -> Text -> IO ()` を包んだ newtype）でプレーン `IO` から書けるログ出口を明示的に受け渡す |
| `src/Settings.hs` | 188 | `AppSettings`。`config/settings.yml` と環境変数（`BACKUP_DIR`/`BACKUP_KEEP` など）から読む |
| `src/Foundation.hs` | 239 | `App` 型、`isAuthorized` によるルート単位の認可（`routeAccess`）、CSRF、セッション Cookie |
| `src/LoginThrottle.hs` | 68 | ログイン失敗の IP 単位カウント（15 分で 5 回 → 拒否）。純粋な核と TVar の殻 |
| `src/Handler/Auth.hs` | 74 | ログイン画面（HTML フォーム）とログアウト |
| `src/Handler/Api.hs` | 172 | metrics、monthly、heartrate、sleep_periods、events、sync |
| `src/Handler/Advice.hs` | 113 | advice の POST / ポーリング / 履歴（同じ日に保存された複数件の切り替えを含む） |
| `src/DailySync.hs` | 82 | cron 用 CLI（`oura-daily-sync`）。JST の今日、7 日分 backfill、同期後に DB バックアップ、エラー時 exit 1 |
| `src/ScheduledAdvice.hs` | 76 | cron 用 CLI（`oura-advice`）。前景でアドバイスを生成して `advice_history` に保存、失敗時 exit 1 |
| `src/Backup.hs` | 59 | `VACUUM INTO` による日次バックアップと世代管理 |
| `src/Application.hs` | 254 | `.env` ロード → 設定 → コネクションプール作成 → migrate → Warp 起動 |
| `static/*.js` + `static/charts/*.js` | 約 3,200 | フロントエンド（main / charts / helpers / api / export と、ダッシュボードのセクションごとの `charts/` モジュール） |

### データモデル（`config/models.persistentmodels`）

- `daily_metrics` — `(metric, day)` を主キーとし、`score` と生 JSON (`data_json`)、`synced_at` を保持
- `heartrate` — `(timestamp, bpm, day)`。`day` は集計用の非正規化カラム
- `sync_log` — メトリックごとの `last_synced_day`/`last_synced_at`。増分同期の起点
- `advice_history` — 生成済みアドバイスの保存先。Oura から取り直せない唯一のデータで、バックアップの主目的
- `sleep_periods` — 睡眠期間ドキュメント。1 日に複数行（本睡＋仮眠）あるため、
  `(metric, day)` ではなく Oura の document id が主キー。`sleep_phase_5_min`
  を含む生 JSON を `data_json` に保持（Haskell 版で新設）
- `oura_events` — タグ・ワークアウト・セッション（`Metric.EventKind`）。`(kind, id)` が主キーで、
  `day` は開始日（タグなら `start_day`）。1 日に任意件数あり得る（Haskell 版で新設）

### ルート（`config/routes.yesodroutes`）

```
/                          ダッシュボード（静的 HTML。未認証は /login へ）
/login  /logout            ログイン画面（HTML フォーム）とログアウト
/api/metrics  /api/metrics/#Text
/api/monthly               全期間の月平均（期間指定なし）
/api/heartrate
/api/sleep_periods         睡眠段階チャート用（必要フィールドのみ返す）
/api/events                タグ・ワークアウト・セッション（kind ごと）
/api/sync  /api/sync/status
/api/advice/history/#Text  ?at=<saved_at> でその日の特定の 1 件（順序上 advice/#Text より先に定義）
/api/advice                POST でジョブ投入
/api/advice/#Text          "history" とジョブ ID を同一ハンドラで文字列分岐
```

### 実行形態

| バイナリ | 起動元 | 役割 |
|---|---|---|
| `oura-dashboard-hs` | systemd（`systemd/`、`run_oura_dashboard.sh`） | Web サーバ |
| `oura-daily-sync` | cron（`run_daily_sync.sh`、1 日 3 回） | 増分同期 + 7 日 backfill + DB バックアップ（`BACKUP_DIR=backup/`） |
| `oura-advice` | cron（`run_advice.sh`、週 3 回） | 定期アドバイス生成 |

---

## 2. 図解

### 図 A: システム全体構成

```mermaid
flowchart TB
    subgraph Client["ブラウザ"]
        JS["static/main.js<br/>charts.js + charts/*.js (Chart.js)"]
    end

    subgraph Server["Warp + Yesod (App)"]
        Auth["Foundation.isAuthorized<br/>bcrypt セッション認証"]
        HApi["Handler/Api.hs<br/>metrics / monthly / heartrate<br/>sleep_periods / events / sync"]
        HAdv["Handler/Advice.hs<br/>advice 投入・ポーリング"]
    end

    subgraph Core["ドメイン層"]
        Sync["Sync.hs<br/>増分同期"]
        Db["Db.hs<br/>raw SQL クエリ"]
        Adv["Advice.hs<br/>ペイロード・CLI 実行<br/>TVar Map + forkIO"]
        Oura["Oura.hs<br/>API クライアント"]
        Bak["Backup.hs<br/>VACUUM INTO"]
    end

    subgraph Types["共通型"]
        Metric["Metric.hs<br/>DailyMetric / EventKind / Metric"]
        DateT["DateText.hs<br/>DayText / DateRange"]
        Json["Json.hs<br/>Value アクセサ"]
        Log["Logging.hs<br/>AppLog"]
    end

    DB[("SQLite<br/>oura.db")]
    BakDir[("backup/<br/>oura-YYYY-MM-DD.db")]
    API["Oura API v2"]
    CLI["claude CLI<br/>(子プロセス)"]
    Cron["cron: oura-daily-sync<br/>DailySync.hs"]
    CronAdv["cron: oura-advice<br/>ScheduledAdvice.hs"]

    JS -->|JSON| Auth --> HApi & HAdv
    HApi --> Sync & Db
    HAdv --> Adv
    Sync --> Oura --> API
    Sync --> Db --> DB
    Adv --> Db
    Adv --> CLI
    Cron --> Sync
    Cron --> Bak --> BakDir
    Bak --> DB
    CronAdv --> Adv
    Sync -.uses.-> Metric & DateT & Json
    Oura -.uses.-> Metric & DateT & Json & Log
    Db -.uses.-> Metric & DateT & Json
    Adv -.uses.-> Metric & DateT & Json & Log
```

### 図 B: 増分同期のシーケンス

```mermaid
sequenceDiagram
    participant B as ブラウザ
    participant H as Handler/Api
    participant S as Sync.runSync
    participant D as Db (SQLite)
    participant O as Oura API

    B->>H: POST /api/sync
    H->>H: isAuthorized（未認証なら 401 JSON）
    H->>S: runSync (backfillDays = 0 固定)

    loop メトリックごと
        S->>D: sync_log の last_synced_day を取得
        D-->>S: 最終同期日
        S->>S: findMissingRange<br/>（直近 7 日は常に再取得）
        alt 取得範囲あり
            S->>O: fetch (next_token でページング)
            O-->>S: JSON
            alt 日次メトリック
                S->>S: extractScore で score 抽出
                S->>D: INSERT OR REPLACE daily_metrics
                Note over S,D: readiness 同期時は<br/>temperature を派生生成
            else タグ・ワークアウト・セッション
                S->>D: 範囲内を DELETE してから INSERT<br/>（アプリ側で消した記録も消える）
            end
            S->>D: sync_log を更新
        else 範囲なし
            S->>S: スキップ
        end
    end

    S-->>H: SyncResult（成功件数 / エラー）
    H-->>B: 202 JSON
```

### 図 C: アドバイス生成の 2 経路

```mermaid
stateDiagram-v2
    state "Web ジョブ" as web {
        [*] --> queued: POST /api/advice<br/>ジョブ ID 発行・202 返却
        queued --> running: forkIO ワーカーが拾う
        running --> completed: claude CLI 正常終了
        running --> failed: 非ゼロ終了 / 120 秒タイムアウト / コマンド不在
        completed --> [*]: advice_history に保存<br/>GET で 200 返却
        failed --> [*]: GET で 502 返却
    }

    state "cron: oura-advice" as cron {
        [*] --> generating: buildHealthPayload<br/>+ getAdviceBefore
        generating --> saved: generateAdvice 成功<br/>advice_history に保存・exit 0
        generating --> error: データ皆無 / CLI 失敗<br/>exit 1
    }

    note right of web
        ブラウザは GET /api/advice/{id} を
        ポーリング。未完了なら 202。
        状態は TVar 上のインメモリ Map で、
        プロセス再起動で消える。
    end note
```

### 図 D: 心拍取得の 30 日窓ループ

心拍だけは他のメトリックと異なり、Oura API がサンプル単位（1 日数百件）で返すため、期間を 30 日ずつに区切って**新しい方から古い方へ**遡ります（`Sync.syncHeartrateRange`）。

```mermaid
flowchart LR
    Start([開始日・終了日]) --> W["窓 = 終了日から遡って 30 日<br/>(addDaysT -29)"]
    W --> F["fetch heartrate<br/>（窓の範囲）"]
    F --> I["INSERT OR IGNORE<br/>timestamp 重複を無視"]
    I --> C{"窓の先頭 ≤<br/>開始日?"}
    C -->|No| Shift["終了日 = 窓の先頭 - 1 日"] --> W
    C -->|Yes| Done([完了])
```

---

## 3. 各モジュール・関数のつながりと役割

### 型の基盤

- **`Metric.hs`** — `DailyMetric`（`Sleep`〜`VO2Max` の 9 種）、`EventKind`（`Tags`/`Workouts`/`Sessions`）、`Metric`（`Daily DailyMetric | HeartrateSeries | SleepPeriodSeries | EventSeries EventKind`）。`dailyMetricName`/`eventKindName`/`metricName` が DB・JSON API で共有する唯一の文字列表現を作る。`allDailyMetrics`/`allEventKinds` は `[minBound..maxBound]` で、新しい種類を追加すると `case` の非網羅で**コンパイルが落ちる**設計（`extractScore`, `fetchFn`, `eventDay`, `eventSummary` など）。日次テーブル以外の同期対象は `seriesMetrics` に集約され、`syncStatusMetrics`/`dashboardMetrics`/sync 本文のメトリック名解決がこれを共有する。
- **`DateText.hs`** — `DayText`（`Text` の newtype、`Ord` はテキスト順＝この書式ではそのまま日付順）と `DateRange { rangeStart, rangeEnd }`。`parseDayText` は外部入力（URL セグメント・クエリパラメータ・リクエスト本文）向けの検証で、形状（`\d{4}-\d{2}-\d{2}`、テキスト順＝日付順を保つため）と暦としての妥当性（`1999-13-45` を弾く）の両方を見る。`parseDay` は `Day` への実変換で、失敗時は `error`。外部入力は必ず `parseDayText` を通るため、`parseDay` に届く日付は DB・`formatDay`・検証済み入力のいずれかに限られる。
- **`Json.hs`** — Oura API のペイロードと `data_json` を読む共通アクセサ。`Sync`/`Db`/`Advice`/`Handler.*` が利用。
- **`Logging.hs`** — `AppLog`（`LogLevel -> Text -> IO ()` の newtype）。`Oura.OuraClient` の fetch 関数や `Advice.runAdviceJob` のような `forkIO`/プレーン `IO` の経路は `MonadLogger` を持てないため、ログ出口を値として明示的に受け渡す。Web サーバ・`DailySync`・`ScheduledAdvice` はそれぞれ自分の `LoggerSet` を作る（プロセスごとに別ファイルへ書くため、共有はしない）。

### ドメイン層

- **`Oura.hs`** — `OuraClient` は日次メトリックごとの `DateRange -> IO [Value]` フィールドに加え、`getHeartrate`/`getSleepPeriods`/`getEvents :: EventKind -> DateRange -> IO [Value]` を持つレコード。`realClient` が http-conduit で実装し、`next_token` を追って全ページを結合する。イベント系エンドポイント（`enhanced_tag`/`workout`/`session`）は `end_date` を排他的に扱う（1 日範囲だと空が返る）ため、終了日の翌日を渡している。非 2xx や通信失敗は `OuraError` として投げ、`Sync.tryOura` が捕捉する。テストではこのレコードをスタブに差し替える。
- **`Db.hs`** — Python 版 `db.py` の raw SQL を 1:1 移植した部分に、Haskell 版の追加分が乗っている。
  - `mergeRow` が `data_json` に `day`/`score` を上書きマージする（DB の `score` 列が優先、Python の `{**data, "day":..., "score":...}` と同じ）。`getDailyMetricsBulk` は `M.fromListWith (flip (++))` で (metric, day) 順の行を集約。
  - `mainSleepPeriod`（その日の本睡眠の選択：`long_sleep` 優先、なければ `late_nap` を除いた中で就床時間最長。`static/helpers.js` の `mainPeriod` と同じ規則）は、月平均でも使うため `Advice` からここへ移った。
  - **イベント**：`replaceEvents` は範囲内の同種イベントを `DELETE` してから `INSERT OR REPLACE` する。Oura アプリでタグを消すと次の取得結果から単に消えるだけなので、upsert だけでは残り続けてしまうため。`getEvents` は範囲に掛かるもの（タグは `start_day`〜`end_day` のどこかが範囲に入れば対象）を開始順に返し、セッションの 5 秒間隔系列（`heart_rate` など）は落とす。`getAllEvents` が kind 名をキーにまとめる。
  - **アドバイス履歴**：`getAdviceDates` は保存日（`saved_at` の UTC 日付）ごとに最新 1 件を一覧用に返し、`getAdviceForDate` はその日に保存された全件を古い順に返す（同じ日にボタンを押し直しても前の分は上書きされない）。
  - **月平均**：`getMonthlyMeans` は全期間を対象に、日次メトリックのスコア・歩数・高ストレス時間（`monthlyDailySeries`）と、本睡眠の平均 HRV・最低心拍（`mainSleepPeriods` → `monthlySleepFields`）の月ごとの平均と日数を返す。`sleep_periods` の行は 5 分系列を含んで大きいため、必要なフィールドだけ SQL の `json_object`/`json_extract` で抜き出してからデコードする。全履歴の走査で重い（6 年分で約 0.6 秒）ため、Handler 側でキャッシュしている（後述）。
  - **同期の版**：`getSyncStamps` は `sync_log` の `(metric, last_synced_at)` を返す。同期のどの経路も行の書き込みと同じトランザクションで `sync_log` を更新するので、同期対象テーブルが変わったことの安価な指紋になる（cron の別プロセスによる同期も拾える）。
- **`Sync.hs`** — `findMissingRange`（増分範囲の決定）、`backfillRanges`（欠損日の穴埋め範囲。日次メトリックは `score IS NOT NULL` で判定し、系列系は日ごとの「埋まっている」概念がない（タグの無い日が普通）ので窓全体を取り直す）、`syncDailyMetric`（フェッチ→`extractScore`→upsert、readiness 同期時は温度を派生生成）、`syncEvents`（フェッチ→`replaceEvents`）、`runSync`（メトリックごとに `foldRanges` で順にフェッチしつつ、`OuraError` はそのメトリックのエラーとして記録し次のメトリックへ進む）。心拍だけ `syncHeartrateRange` が 30 日窓で逆順ループ。
- **`Advice.hs`** — 生成の核と Web ジョブ管理の両方を持つ。
  - `buildHealthPayload`（`advicePeriod` = 直近 `adviceDays`（14）日分を `getDailyMetricsBulk` で取得し `extractKeyFields` でメトリックごとに必要フィールドだけ抜粋。睡眠は段階時間の日次合計・本睡眠の時刻とバイタル・仮眠数、イベントは `eventSummary` で時刻を `HH:MM`、長さを分に整形して付ける。タグ名は `custom_name` が null・空なら `tag_type_code` を使い、空のコメントは送らない）
  - `buildAdvicePrompt`（日本語システムプロンプト＋JSON。`getAdviceBefore` で得た直前のアドバイスがあれば、それを踏まえて「前回からの変化」の節を書かせる）
  - `adviceComparison`（レポート上部に出す主要スコアの「今回期間 vs 前回期間」の平均）、`hasHealthData`（データ皆無の判定）
  - `generateAdvice`（`claude -p ... --model opus` を `proc` + `readCreateProcessWithExitCode` で実行、120 秒 `timeout`。Web ジョブと `ScheduledAdvice` で共有）
  - `createAdviceJob`（UUID 発行、`TVar (Map Text AdviceJob)` に `Queued` で登録）→`runAdviceJob`（`forkIO` 済みの別スレッドで `generateAdvice` を呼び、成功時は `advice_history` に保存）
- **`Backup.hs`** — `backupDatabase` は `VACUUM INTO` で `oura-YYYY-MM-DD.db.partial` に書き出してからリネームする（クラッシュしても途中までのファイルが `oura-*.db` として残らない）。SQLite 自身が一貫したスナップショットを書くので、Web サーバやアドバイスジョブが書き込み中でも安全。`VACUUM` はトランザクション内では失敗するため `runSqlPoolNoTransaction` を使う。同じ日の再実行は上書きし、`staleBackups` で新しい `backup-keep`（既定 14）世代だけ残す。`backup-dir` が空（既定）ならバックアップしない（複製 DB での開発実行が本物のバックアップを上書きしないように）。

### Handler 層

- **`Foundation.hs`** — `App` レコード（DB プール、静的ファイル設定、`OuraClient` のテスト用差し替え口、advice ジョブ状態、`AppLog`、ログイン制限、月平均のキャッシュなど）。`isAuthorized` が `routeAccess` でルートを分類し、未認証なら `/` は `/login` へリダイレクト、`/static/*` は 404、`/api/*` は 401 JSON を返す（`routeAccess` はワイルドカードなしで、新ルートは分類を強制される）。セッション Cookie は `SameSite=Lax`、`defaultCsrfMiddleware` で CSRF トークンを照合する。`checkPassword` は bcrypt 検証。
- **`Handler/Auth.hs`** — `getLoginR`/`postLoginR`/`postLogoutR`。ログイン画面は `templates/login.hamlet` を `withUrlRenderer` で直接描画する（`defaultLayout` は CSS を `/static/tmp` に書き出し、未認証では読めないため使わない）。失敗回数は `LoginThrottle` で IP ごとに数える。
- **`Handler/Api.hs`** — `getMetricsR`/`getMetricR`（`parseRange` でクエリパラメータから `DateRange` を組み立て、`Db.getDailyMetrics(Bulk)` を呼ぶ。既定は直近 30 日）、`getMonthlyR`（期間指定なしで `Db.getMonthlyMeans`。結果は `appMonthlyCache`（`KeyedCache`）に `Db.getSyncStamps` をキーとして保持し、同期が走るまで再利用する。キーの読み取りと集計は同じトランザクションなので、キャッシュ値は常にそのキーの時点のデータと一致する）、`getHeartrateR`、`getSleepPeriodsR`、`getEventsR`（`Db.getAllEvents`）、`getSyncStatusR`、`postSyncR`（`appOuraClientOverride` があればそれを使い、なければ `OURA_TOKEN` から `realClient` を構築して `Sync.runSync` を実行、`backfillDays = 0` 固定）。日付を受け取る入口（`parseRange` のクエリパラメータ、sync 本文の `start`/`end`）はいずれも `requireDayText` を通し、不正な日付は 400 で弾く。`jsonBodyOrEmpty` は `parseCheckJsonBody` の結果を見て、パース失敗時だけ空オブジェクトにフォールバックする。
- **`Handler/Advice.hs`** — `postAdviceR`（14 日分のペイロードと直前のアドバイスを取り、データが皆無なら 400、そうでなければ `adviceComparison` 付きのジョブを作って `forkIO` で起動し 202 を返す）、`getAdviceJobR`（`seg == "history"` かジョブ ID かを文字列で分岐）、`adviceJobStatus`（ジョブの状態に応じて 200/502/202）、`getAdviceEntryR`（`parseDayText` で日付形式を検証してから履歴を引く。`?at=` があればその `saved_at` の 1 件、なければその日の最新を返し、`saved_ats` にその日の全件の保存時刻を添える）。
- **`Handler/Home.hs`** / **`Handler/Common.hs`** — 静的な `index.html`・favicon・robots.txt の配信。

### エントリポイント

- **`Application.hs`** — `.env` ロード→`AppSettings` 読み込み→`SECRET_KEY` 必須チェック→ロガー2系統（アプリ用 `appLogger`/`appPlainLogger`、アクセスログ用 `appAccessLoggerSet`）の初期化→DB プール作成→`migrateAll`→Warp 起動。`static/*` と `index.html` は `revalidating` で `Cache-Control: no-cache` 配信。`app/main.hs`（本番）と `app/devel.hs`/`DevelMain.hs`（開発）から呼ばれる。
- **`DailySync.hs`** — cron から `app-daily-sync/main.hs` 経由で実行される CLI。JST の「今日」（`todayIn (hoursToTimeZone 9)`）を基準に 7 日分の backfill 付きで `runSync` を呼び、続けて `backupDatabase` を実行する。バックアップは同期が失敗しても行う（守りたいのは同期と無関係な `advice_history` のため）。同期エラーかバックアップ失敗のいずれかがあれば `exitWith (ExitFailure 1)`。
- **`ScheduledAdvice.hs`** — cron から `app-advice/main.hs` 経由で実行される CLI。JST の今日を終端に Web のボタンと同じ 14 日分でアドバイスを生成し、`advice_history` に保存する（履歴一覧に並ぶ）。ジョブ機構は使わず前景で実行し、データ皆無や CLI 失敗は exit 1。cron が `LANG` なしで起動しても `claude` の日本語入出力を扱えるよう、冒頭でエンコーディングを UTF-8 に固定する。日次同期の後に走らせる前提。

### フロントエンド

- `static/main.js` — 画面制御（期間プリセット・カスタム期間、同期、アドバイス、チャートの全画面表示など）。アドバイス履歴では同じ日に複数件あれば保存時刻のボタン（`advice-versions`）を並べて切り替えられる
- `static/charts.js` — Chart.js 描画の入口。`renderAll` が `charts/` 配下のモジュールを呼ぶ
  - `common.js`（共通部品・色・日付ヘルパー。`makeChart` は全チャートに、狭い画面で長い折れ線の点を消す処理（マーカーだけの系列は除く）と、ツールチップ内のタップでそれを閉じるプラグイン `dismissTooltipOnTap` を被せる）、`baseline.js`（7 日移動平均・28 日ベースライン）、`cards.js`
  - `scores.js`（スコア推移と内訳ヒートマップ）、`sleep.js`、`vitals.js`、`stress.js`、`activity.js`
  - `correlation.js` — 就床時刻×睡眠スコアの散布図、曜日平均に加え、「その日の歩数・中高強度活動・高ストレス時間・就床時刻」と「翌朝の Readiness・HRV」を突き合わせる翌日相関（`nextDayPoints`）
  - `events.js` — タグ・ワークアウト・セッションの一覧と、タグ（およびワークアウト）ごとの翌朝のスコア・HRV の平均（`tagLabel` がタグコードを表示名に変換）
  - `longterm.js` — `/api/monthly` による全期間の月平均。選択期間とは無関係で、日数の少ない月は中抜きの点で描く
- `static/helpers.js`（共通関数、`mainPeriod` など）・`api.js`（`apiFetch` ラッパー、401 時にログインモーダルを出す）・`export.js`（表示中期間の CSV 生成）
- Chart.js と markdown ライブラリは `static/vendor/` から配信（CDN 非依存）

---

## 4. 潜在的な改善点

実害が大きいと思われる順に挙げます。**静的読解による判断で、再現テストは未実施です。**

### a) 中: 「今日」の基準がモジュール間で不一致

`Handler.Api` の `parseRange`/`postSyncR` と `Handler.Advice.postAdviceR` は `DateText.todayUtc` を、`DailySync`/`ScheduledAdvice` は JST（`todayIn (hoursToTimeZone 9)`）を使う。JST 深夜帯（0:00〜9:00）では両者が指す日付が 1 日ずれるため、Web からの同期と cron からの同期で対象範囲が食い違うほか、Web のアドバイスボタンと定期アドバイスで分析期間（14 日窓）の終端が変わる。アドバイス履歴の「保存日」も `saved_at` の UTC 日付なので、JST 0:00〜9:00 に保存したものは前日の分として並ぶ。どちらかに統一すべき。

海外滞在中（例：米国東部、UTC-5）も、データの取りこぼしは起きない。日次メトリック・睡眠期間・イベントの `day` は Oura が記録地の現地日付で付けたものをそのまま保存しており、現地の日付は UTC・JST と同じかそれ以前になる。同期の終端は現地の最新日以降を指し、直近 7 日は毎回取り直す。影響が出るのは、アドバイスの 14 日窓の終端がまだ存在しない日を含んで実質 13 日分になることと、現地の夕方以降に保存したアドバイスが履歴で翌日の分として並ぶことくらい。時差をまたぐ移動日（日付が重なる、または飛ぶ）の日次データの扱いは Oura 側に依存し、実データでは未確認。日付が飛んで欠損になった日は、cron の backfill が 7 日間取り直しに行くが、害はない。

### b) 中: 心拍の「1 日」が UTC の日付で区切られている

Oura の心拍 API はタイムスタンプを UTC（`...Z`）で返し、`Db.upsertHeartrateBatch` は `day = take 10 ts` で `day` を付けるので、`heartrate.day` は UTC の日付になる（`oura.db` の行もすべて `Z` 付きであることを確認済み）。一方、フロントの 1 日表示は、ブラウザの現地日付（`state.hrDate`）を `start`/`end` に入れて `/api/heartrate` を問い合わせる。そのため日本にいても「11/6」を選ぶと、11/6 9:00 から 11/7 8:59 まで（JST）が表示される（米国東部なら前日 19:00 から当日 19:00 まで（現地時刻））。グラフの横軸はブラウザ時刻なので点の時刻は正しく、切り出す範囲だけがずれる。7 日表示でも両端が同じだけずれる。直し方は、取り込み時に `day` を JST で付ける方法と、1 日表示を時刻の範囲で問い合わせる方法がある。

### c) 中: アドバイスジョブが無制限に蓄積する

`Advice.AdviceJobs`（`TVar (Map Text AdviceJob)`）から完了・失敗ジョブを回収する仕組みがない。長時間稼働でメモリが単調増加する（定期アドバイスはこの Map を使わないので影響しない）。Python 版も同じ構造だが、移植先で TTL 付き削除を入れられる。

### d) 低: `getDailyMetricsBulk` の集約が O(n²) になりうる

`Db.getDailyMetricsBulk` は `M.fromListWith (flip (++))` で行を集約するが、`flip (++) new old = old ++ new` は毎回 `old` 全体をたどるため、1 メトリックあたりの行数の二乗に比例する。14〜30 日分なら無害だが、カスタム期間で数年分を指定すると劣化する。逆順に積んで最後に `reverse` するか `Data.Sequence` を使えば線形になる。（同じ書き方の `mainSleepPeriods` はキーが日なので 1 キーあたり数行で、問題にならない。）

### e) 低: 睡眠の時刻表示が画面ごとに異なるタイムゾーン基準

就床時刻の散布図・中央値（`charts/sleep.js` の `wallClockHours`）、AI に送る時刻（`Advice.clockAt`）、イベント一覧（`charts/events.js` の `clockOf`）は、タイムスタンプのオフセットを無視して**記録地の時刻**を使う。一方、睡眠段階チャートの横軸と、期間タブ・範囲ラベル（`main.js` の `startTimeLabel`/`fullClockLabel`）は `Date` 経由で**ブラウザのタイムゾーン**に換算する。現地で見ている間は両者が一致するが、帰国後に海外の夜を見返すと、散布図では 23:06 就床、睡眠段階では 13:06 就床（JST 換算）のように食い違う（`oura.db` には `-05:00`・`+02:00` の睡眠期間が実在する）。

### f) 低: advice ルートが URL の文字列比較で分岐している

`/api/advice/#Text`（`AdviceJobR`）が `"history"` かジョブ ID かを `Handler.Advice.getAdviceJobR` 内の文字列比較で判定している。ジョブ ID は UUID なので実害はないが、ルート定義を分けたほうが堅牢。

### g) 低: Web 経由の sync だけ backfill が働かない

`Handler.Api.postSyncR` は `Sync.runSync ... 0`（`backfillDays = 0` 固定）で、欠損日のバックフィルは `DailySync`（cron、`backfillDays = 7`）のみが担う。意図的な設計と思われるが、非対称なので挙動を把握していないと「Web から同期したのに古い欠損が埋まらない」と混乱する。

### h) 低: `src/Db.hs` に export リストがない

`module Db where` なので内部ヘルパーも全公開。イベント・月平均の追加で 460 行になり、他モジュールとの契約がさらに見えにくくなっている。

### i) 低: ログ言語が層によって混在

`Sync.hs`/`Oura.hs`/`Advice.hs` のログ行自体は英語だが、`Advice.generateAdvice` が返す失敗メッセージはユーザー向け日本語文言で、`runAdviceJob` の `fail'` と `ScheduledAdvice` の `"scheduled advice failed: "` がそれをそのままログにも書いている。ユーザー向け応答と内部ログを同じ文字列で兼用しているため、ログを追う際に言語が混在する。

### 確認済み・問題なし

- `/api/monthly` の月平均は `sync_log` の更新時刻をキーにキャッシュしており、2 回目以降は全履歴を走査しない。ただし同期以外の手段（手作業の SQL、バックアップからの復元など）で DB を書き換えた場合は `sync_log` が変わらないため、Web サーバを再起動するまで古い値が返る。

- `oura.db` / `*.sqlite3` / `config/client_session_key.aes` / `.env` / `backup/` はいずれも `.gitignore` 済みで、リポジトリには含まれていない。
- `generateAdvice` は `proc` で `claude` CLI を起動しており（シェル経由ではない）、コマンドインジェクションの余地はない。プロンプト内容は DB 由来（タグの自由入力名・コメントもユーザー本人の入力）。
- バックアップの `VACUUM INTO ?` はパスをプレースホルダで渡しており、ディレクトリ名に記号が含まれても SQL として解釈されない。
