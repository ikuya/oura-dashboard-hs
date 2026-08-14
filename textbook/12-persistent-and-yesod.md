# 第 12 章 persistent と Yesod

← [第11章 aeson で緩い JSON を扱う](11-aeson.md) | [目次](README.md) | [第13章 並行処理とリソース管理](13-concurrency.md) →

> **この章で復習する文法**: Template Haskell スプライス `$(...)` と生成コードの調べ方、`rawSql` の結果型と `Single`、型注釈が必要になる理由、型安全ルーティング（生成される `Route App`）、遅延評価を使った初期化

Yesod は「型安全な Web フレームワーク」と呼ばれます。何が型で守られていて、何が守られていないのか。そして、フレームワークが用意した型安全機構を**あえて使わない**判断がどこでなされているのか。実物で確認します。

## 目次

- [12.1 スキーマ定義とコード生成](#121-スキーマ定義とコード生成)
  - [文法メモ: Template Haskell で生成されたコードを見る](#文法メモ-template-haskell-で生成されたコードを見る)
  - [Haskell の型名と DB の名前の衝突](#haskell-の型名と-db-の名前の衝突)
- [12.2 型安全クエリを使わない判断](#122-型安全クエリを使わない判断)
  - [文法メモ: `rawSql` の結果型と `Single`](#文法メモ-rawsql-の結果型と-single)
- [12.3 マイグレーション](#123-マイグレーション)
- [12.4 ルートの型安全](#124-ルートの型安全)
  - [生成が 2 段階に分かれている理由](#生成が-2-段階に分かれている理由)
  - [型安全が届かないところ](#型安全が届かないところ)
- [12.5 Foundation — アプリの状態を 1 つの型に](#125-foundation-アプリの状態を-1-つの型に)
- [12.6 認証をハンドラの外に出す](#126-認証をハンドラの外に出す)
  - [パスワード検証](#パスワード検証)
- [12.7 起動シーケンスと遅延評価](#127-起動シーケンスと遅延評価)
- [12.8 この章のまとめ](#128-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 12.1 スキーマ定義とコード生成

```haskell
-- src/Model.hs:24
share [mkPersist sqlSettings, mkMigrate "migrateAll"]
    $(persistFileWith lowerCaseSettings "config/models.persistentmodels")
```

この 2 行が、外部ファイルを読んでエンティティ型・型安全なフィールドアクセサ・マイグレーション関数を生成します。

```
-- config/models.persistentmodels
DailyMetric sql=daily_metrics
    metric    Text
    day       Text
    score     Double Maybe
    dataJson  Text        sql=data_json
    syncedAt  Text        sql=synced_at
    UniqueDailyMetric metric day sql=sqlite_autoindex_daily_metrics_1
    deriving Show
```

生成されるもの:

- 型 `DailyMetric`（レコード型）と `DailyMetricId`
- フィールドアクセサ `dailyMetricMetric`, `dailyMetricDay`, ...
- 型安全クエリ用の `EntityField` 値（`DailyMetricDay` など）
- `migrateAll :: Migration`

`sql=` に注目してください。これは **既存の Python 版が作った SQLite スキーマにそのまま乗せる**ための指定です。

```
-- config/models.persistentmodels:1（コメント）
-- Persistent models mapped onto the existing Python oura.db schema.
-- Table and column names are pinned with sql= / explicit primary keys so
-- Persistent reads and writes the same database the Flask app created.
```

persistent の既定の命名規則に従わず、既存の DB に合わせています。**移植プロジェクトでは、フレームワークの規約より既存資産との互換を優先する**のが普通です。

### 文法メモ: Template Haskell で生成されたコードを見る

`$( ... )` はコンパイル時に評価され、Haskell の宣言や式を生成して埋め込みます。したがって、**生成された名前は grep しても定義が見つかりません**。

見る方法は 2 つあります。

```sh
# 1. 生成されたコードをコンパイル時にダンプする
stack build --ghc-options=-ddump-splices

# 2. GHCi でモジュールの中身を列挙する
stack ghci oura-dashboard-hs:lib
> :browse Model
```

**「定義が見つからない名前が出てきたら TH を疑う」**——これは Yesod / persistent を読むときの必須の勘です。

### Haskell の型名と DB の名前の衝突

生成される型 `DailyMetric` は、第 3 章で作ったドメイン型 `Metric.DailyMetric` と名前が衝突します。ところが `Db.hs` は `Model`（生成型の宿るモジュール）を **import していません**。

```haskell
-- src/Db.hs:12-19（抜粋）
import ClassyPrelude.Yesod
...
import DateText
import Metric
```

```haskell
-- src/Db.hs:94
getDailyMetrics
    :: (MonadIO m) => DailyMetric -> DateRange -> ReaderT SqlBackend m [A.Value]
```

ここでの `DailyMetric` は `Metric.hs` の方です。persistent 側のエンティティ型はスコープに入っておらず、raw SQL の結果を直接 `A.Value` にしています。だから `Db.hs` の中では衝突が起きようがありません。これは偶然ではなく、次節の設計判断（型安全クエリを使わない）の帰結です。

実際に衝突が**起きうる**のは、両方の `DailyMetric` がスコープに入るモジュール、つまり `Handler/Api.hs` です。ここは `import Import`（`Model` の `DailyMetric` を再輸出）と `import Metric (...)` を両方行っていますが、後者の import リストから `DailyMetric` を明示的に外しています。

```haskell
-- src/Handler/Api.hs:11,19-20
import Import                                    -- Model.DailyMetric を再輸出
...
import Metric (Metric (..), dailyMetricName, dashboardMetrics,
               metricName, parseDailyMetric)     -- DailyMetric 自体は挙げていない
```

明示 import リストで名前を絞ることで、`DailyMetric` は `Model`（persistent エンティティ）側だけを指すようにしてあります。第 1 章で見た「明示 import で衝突を解く」判断が、ここでも使われています。

## 12.2 型安全クエリを使わない判断

persistent の売りは型安全クエリです。

```haskell
-- persistent の型安全クエリ（このプロジェクトでは使っていない）
rows <- selectList
    [ DailyMetricMetric ==. "sleep"
    , DailyMetricDay >=. start
    , DailyMetricDay <=. end ] [Asc DailyMetricDay]
```

しかしこのプロジェクトは raw SQL を使います。

```haskell
-- src/Db.hs:96
getDailyMetrics metric (DateRange start end) = do
    rows <- rawSql
        "SELECT day, score, data_json FROM daily_metrics WHERE metric = ? AND day >= ? AND day <= ? ORDER BY day"
        [toPersistValue (dailyMetricName metric), toPersistValue start, toPersistValue end]
    return [ mergeRow day score (parseDataJson dj)
           | (Single day, Single score, Single dj) <- rows ]
```

理由はモジュールヘッダに書かれています。

```haskell
-- src/Db.hs:5
-- | Database layer, ported from the Python app's db.py.
--
-- Query functions that merge the opaque @data_json@ blob with the @day@/@score@
-- columns return aeson 'Value's (matching the Python dicts), so the JSON API
-- contract stays byte-compatible. Raw SQL is used where the Python code relies
-- on @INSERT OR REPLACE@, @INSERT OR IGNORE@, @substr()@ or @GROUP BY@, keeping
-- those queries 1:1 with the original.
```

**判断の根拠を分解すると:**

1. `INSERT OR REPLACE` / `INSERT OR IGNORE` は SQLite 固有。persistent の `upsert` は意味が微妙に違う。
2. `substr(saved_at, 1, 10)` による `GROUP BY`（`src/Db.hs:154`）は型安全 API では表現できない。
3. JSON API のバイト互換が要件。クエリを 1:1 で移せば、出力の食い違いを検証しやすい。

**評価**: 妥当な判断です。ただし代償があります。

- SQL 文字列にタイプミスがあってもコンパイルは通る（実行時エラー）
- カラム名を変えたとき、SQL 文字列は追従しない
- プレースホルダの数と引数の数が合っているかを型が検査しない

だから **テストで補償する必要があります**。実際 `test/DbSpec.hs` が 206 行あり、各クエリをインメモリ SQLite に対して検証しています。

> **一般則**: 型安全機構を外す判断をしたら、外した分をテストで埋める。「型で守れないなら、テストで守る」を明示的にトレードする。

### 文法メモ: `rawSql` の結果型と `Single`

```
rawSql :: (RawSql a, MonadIO m, BackendCompatible SqlBackend backend)
       => Text -> [PersistValue] -> ReaderT backend m [a]
newtype Single a = Single { unSingle :: a }
```

結果型 `a` は多相です。1 カラムなら `Single a`、複数カラムならタプルになります。

```haskell
-- src/Db.hs:88 — 1 カラム
rows <- rawSql "SELECT last_synced_day FROM sync_log WHERE metric = ?" [...]
return $ unSingle <$> headMay rows

-- src/Db.hs:98 — 3 カラム（タプルのリスト）
rows <- rawSql "SELECT day, score, data_json FROM daily_metrics ..." [...]
return [ ... | (Single day, Single score, Single dj) <- rows ]
```

**型注釈が必要になる場面が多い**のが raw SQL の面倒なところです。

```haskell
-- src/Db.hs:173-174 — where 節で型を明示している
entryJson
    :: (Single Text, Single Text, Single Text, Single Text) -> A.Value
entryJson (Single savedAt, Single ps, Single pe, Single content) = A.object [...]
```

`rawSql` の結果が何型か、他のどこからも決まらないためです。**「型が決まらない」というコンパイルエラーが出たら、まず `rawSql` の結果を疑う**のが定石です。

`toPersistValue` はパラメータを `PersistValue` に変換します。`DayText` が `PersistField` を導出していた（第 4 章）おかげで、日付をそのまま渡せます。

```haskell
-- src/DateText.hs:35
deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)
```

**newtype に `PersistField` を持たせておくと、DB 層で `unDayText` を呼ばずに済みます**——これが「型を作ると境界が増えて面倒になる」を避けるコツです。

## 12.3 マイグレーション

```haskell
-- src/Application.hs:112
-- Perform database migration using our application's logging settings.
runLoggingT (runSqlPool (runMigration migrateAll) pool) logFunc
```

```haskell
-- src/DailySync.hs:75
-- Apply migrations first (mirrors daily_sync.py calling db.init_db(),
-- which adds the sync_log.last_synced_at column if missing).
_ <- runSqlPool (runMigrationSilent migrateAll) pool
```

**DB を開く実行ファイルは全部、起動時にマイグレーションを走らせています。** Web アプリと cron CLI の両方です。片方だけだと、cron が先に走ったときにカラムが無くて落ちます。

`runMigration`（SQL を標準出力に出す）と `runMigrationSilent`（出さない）の使い分けも実務的です。cron ジョブは静かに動くべきなので後者。

## 12.4 ルートの型安全

```
-- config/routes.yesodroutes
/api/metrics          MetricsR      GET
/api/metrics/#Text    MetricR       GET
/api/heartrate        HeartrateR    GET
```

```haskell
-- src/Foundation.hs:68
mkYesodData "App" $(parseRoutesFile "config/routes.yesodroutes")
```

これで `Route App` 型が生成され、`MetricsR`、`MetricR :: Text -> Route App` といったコンストラクタが使えるようになります。**ルートが値になる**わけです。

効果はテストコードで一番よく分かります。

```haskell
-- test/AppSpec.hs:109
request $ setMethod "GET" >> setUrl (MetricR "readiness")
    >> addGetParam "start" "2024-01-01" >> addGetParam "end" "2024-01-31"
```

URL を文字列で書いていません。パスを変えてもこの行は直す必要がなく、存在しないルートを書けばコンパイルエラーです。

ハンドラ名の対応も型で強制されます。ルート `MetricsR` に `GET` を宣言したら、`getMetricsR :: Handler ...` を定義しなければコンパイルが通りません（`mkYesodDispatch` が要求します）。**「ルートを足したがハンドラを書き忘れた」が起きない**のが Yesod の大きな利点です。

### 生成が 2 段階に分かれている理由

```haskell
-- src/Foundation.hs:68
mkYesodData "App" $(parseRoutesFile "config/routes.yesodroutes")

-- src/Application.hs:56
-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs.
mkYesodDispatch "App" resourcesApp
```

`Foundation.hs` で**型だけ**を作り、`Application.hs` で**ディスパッチ**を作ります。分ける理由は、ハンドラモジュール（`Handler/Api.hs` など）が `Foundation` を import する一方、ディスパッチはそのハンドラたちを知っている必要があるからです。1 箇所でやると循環 import になります。

第 5 章で見た `{-# OPTIONS_GHC -fno-warn-orphans #-}` は、この分割の副作用（`App` 型と別モジュールでインスタンスを定義する）を許容するためのものです。**Template Haskell を使う設計では、生成の順序が import 構造に影響します。**

### 型安全が届かないところ

ルート定義にはコメントで制約が書かれています。

```
-- config/routes.yesodroutes:25
-- Yesod cannot have a literal and a dynamic segment share a position, so
-- /api/advice/history and /api/advice/<job_id> are both served by AdviceJobR,
-- which dispatches on the segment value (matching the Python URL contract).
/api/advice/history/#Text   AdviceEntryR   GET
/api/advice                 AdviceR        POST
/api/advice/#Text           AdviceJobR     GET
```

（コメントの「cannot」は正確には、Yesod の**重複ルート検査**が既定でリテラルと動的セグメントの重なりを拒否する、という意味です。ルート片に `!` を付けて検査を無効化する手もありますが、その場合は定義順でのマッチになります。第 16 章 16.6 で検討します。）

```haskell
-- src/Handler/Advice.hs:53
getAdviceJobR :: Text -> Handler Value
getAdviceJobR seg = do
    requireAuth
    if seg == "history"
        then adviceHistoryList
        else adviceJobStatus seg
```

**ここだけ文字列比較でルーティングしています。** 型安全ルーティングの外側です。ジョブ ID が UUID なので実害はありませんが、「`history` という ID のジョブは作れない」という暗黙の制約が生まれています。

より良い設計はルートを分けることですが、**JSON API の URL 契約を Python 版と同じに保つ**要件があるためこの形になっています（第 16 章）。

> **教訓**: フレームワークの型安全機構には守備範囲があります。範囲外に出るときは、(a) なぜ出るのか、(b) 代わりに何で守るのか、をコメントに残す。このプロジェクトはそれをしています。

## 12.5 Foundation — アプリの状態を 1 つの型に

```haskell
-- src/Foundation.hs:34
data App = App
    { appSettings    :: AppSettings
    , appStatic      :: Static
    , appConnPool    :: ConnectionPool
    , appHttpManager :: Manager
    , appLogger      :: Logger
    , appAccessLoggerSet :: LoggerSet
    , appOuraClientOverride :: Maybe OuraClient
    , appAdviceJobs  :: AdviceJobs
    , appPlainLogger :: AppLog
    }
```

**このアプリのグローバル状態がすべてここにあります。** グローバル変数も `unsafePerformIO` もありません。すべてのハンドラは `getYesod :: Handler App` でこれを取得します。

第 8 章で見た ReaderT パターンの実例です。Yesod の `Handler` は内部に `App` を持つ `ReaderT` 的な構造で、可変状態は `TVar`（`appAdviceJobs`）として保持されます。

## 12.6 認証をハンドラの外に出す

```haskell
-- src/Foundation.hs:169
sessionAuthKey :: Text
sessionAuthKey = "authenticated"

isAuthenticated :: Handler Bool
isAuthenticated = isJust <$> lookupSession sessionAuthKey

-- | Guard for protected endpoints: mirrors the Python @login_required@
-- decorator, returning @401 {"error": "Unauthorized"}@ when not authenticated.
requireAuth :: Handler ()
requireAuth = do
    authed <- isAuthenticated
    unless authed $
        sendStatusJSON status401 (A.object ["error" A..= ("Unauthorized" :: Text)])
```

Python のデコレータ `@login_required` に相当するものを、**ハンドラの先頭で呼ぶ関数**として実装しています。Haskell にはデコレータ構文がないので、この形が素直です。

**弱点は「書き忘れても動いてしまう」こと。** 型で強制するには、認証済みを表す型（`AuthenticatedHandler a` のような newtype）を作って全ハンドラをそれに乗せる方法がありますが、記述量が跳ね上がります。このプロジェクトは**テストで補償**しています。

```haskell
-- test/AppSpec.hs:78
it "protected endpoint requires auth" $ do
    get MetricsR
    statusIs 401
```

「型で守れないならテストで守る」の 2 例目です。ただし現状は `MetricsR` しか検証していません（第 16 章）。

### パスワード検証

```haskell
-- src/Foundation.hs:185
checkPassword :: Text -> Handler Bool
checkPassword plain = do
    stored <- appPassword . appSettings <$> getYesod
    return $ validatePassword (encodeUtf8 stored) (encodeUtf8 plain)
```

bcrypt のハッシュ検証です。**平文パスワードは保存も比較もしていません**。自前でハッシュを計算して `==` で比較するのではなく、ライブラリの検証関数を使うのが正解です。

運用上の注意として、`.env` に書く bcrypt ハッシュ（`$2y$...`）はシングルクォートで囲む必要があります。`$` がシェル変数展開として解釈されるとハッシュが壊れ、起動時にクラッシュします。**セキュリティ関連の設定はフォーマットのミスが静かな障害になりやすい**ので、こうした落とし穴はドキュメント化する価値があります。

## 12.7 起動シーケンスと遅延評価

`makeFoundation`（`src/Application.hs:62`）は、実務でよくある「初期化の依存が循環する」問題を解いています。

```haskell
-- src/Application.hs:95
-- We need a log function to create a connection pool. We need a connection
-- pool to create our foundation. And we need our foundation to get a
-- logging function. To get out of this loop, we initially create a
-- temporary foundation without a real connection pool, get a log function
-- from there, and then create the real foundation.
let mkFoundation appConnPool = App {..}
    tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
    logFunc = messageLoggerSource tempFoundation appLogger
```

**遅延評価を使った解法です。** `tempFoundation` の `appConnPool` フィールドには `error` が入っていますが、`messageLoggerSource` はそのフィールドを触らないので評価されません。

これは Haskell 特有のテクニックで、正しく動く一方で**危険でもあります**。将来 `messageLoggerSource` が `appConnPool` を見るようになったら、実行時に落ちます。だからこそ `error` のメッセージが `"connPool forced in tempFoundation"` と具体的に書かれています。落ちたときに何が起きたか即座に分かる。

> 遅延評価に依存するコードを書くときは、前提が破れたときのメッセージを丁寧に書く。

## 12.8 この章のまとめ

- persistent のスキーマは外部ファイル + TH で生成。既存 DB に合わせるときは `sql=` でマッピングを固定する。
- TH の生成物は grep では見つからない。`-ddump-splices` か `:browse` で確認する。
- 型安全クエリを使わない判断はありうる（DB 固有機能、移植の 1:1 対応）。外した分はテストで埋める。
- `rawSql` は結果型が決まらないことが多い。型注釈で明示する。
- newtype に `PersistField` を導出させると、DB 層で開梱せずに済む。
- ルートは値。テストが URL 文字列に依存しなくなる。ハンドラの書き忘れはコンパイルエラー。
- 型安全ルーティングの守備範囲外に出るときは、理由と代替の防御をコメントに書く。
- Foundation にアプリ状態を集約する。グローバル変数を使わない。
- 認証ガードは関数として先頭で呼ぶ。書き忘れはテストで守る。
- 初期化の循環は遅延評価で解けるが、`error` メッセージを具体的に書く。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `$(f "path")` | TH スプライス（コンパイル時にコード生成） | `Model.hs`, `Foundation.hs` |
| `share [mkPersist ..., mkMigrate "..."] $(...)` | エンティティとマイグレーションの生成 | `Model.hs` |
| `-ddump-splices` / `:browse` | 生成コードを見る | 12.1 |
| `rawSql sql params` | 生 SQL（結果型は多相） | `Db.hs` |
| `Single a` / `unSingle` | 1 カラムの結果 | `getLastSyncedDay` |
| `toPersistValue x` | SQL パラメータへの変換 | 全クエリ |
| `mkYesodData` / `mkYesodDispatch` | ルート型の生成／ディスパッチの生成 | `Foundation.hs` / `Application.hs` |
| `MetricR "readiness"` | 値としてのルート | `test/AppSpec.hs` |
| `error "..."` を遅延に頼って埋める | 初期化の循環を解く | `tempFoundation` |

---

← [第11章 aeson で緩い JSON を扱う](11-aeson.md) | [目次](README.md) | [第13章 並行処理とリソース管理](13-concurrency.md) →
