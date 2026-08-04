# 第 5 章 モナドと型クラス制約の実務

入門書の「モナド」は `IO` と `Maybe` で終わりますが、実務のコードには `ReaderT SqlBackend m`、`MonadUnliftIO m`、`LoggingT IO`、`Handler` といった型が並びます。この章では、それらを**「能力の宣言」として読む**方法を身につけます。

## 5.1 制約は「この関数に必要な能力」の一覧

まず 4 つの関数のシグネチャを並べてみます。

```haskell
-- src/Sync.hs:83
findMissingRange
    :: (MonadIO m)
    => DayText -> Metric -> DayText
    -> ReaderT SqlBackend m (Maybe DateRange)

-- src/Sync.hs:106
syncDailyMetric
    :: (MonadIO m, MonadLogger m)
    => OuraClient -> DailyMetric -> DateRange
    -> ReaderT SqlBackend m Int

-- src/Sync.hs:215
runSync
    :: (MonadUnliftIO m, MonadLogger m)
    => DayText -> OuraClient -> Maybe DayText -> Maybe DayText
    -> Maybe [Metric] -> Int
    -> ReaderT SqlBackend m SyncResult

-- src/Sync.hs:199
foldRanges :: (Monad m) => (DateRange -> m RangeResult) -> [DateRange] -> m RangeResult
```

制約の違いをそのまま日本語にするとこうなります。

| 関数 | 宣言している能力 |
|---|---|
| `foldRanges` | 順に実行できる（それだけ） |
| `findMissingRange` | IO を実行できる + SQL 接続を使える |
| `syncDailyMetric` | IO + SQL接続 + ログを書ける |
| `runSync` | IO + SQL接続 + ログ + **例外を捕まえられる** |

`runSync` だけが `MonadUnliftIO` である理由は、内部で `tryOura`（`try` を使う）を呼ぶからです。`try :: (MonadUnliftIO m, Exception e) => m a -> m (Either e a)` が `MonadUnliftIO` を要求するので、その制約が呼び出し元まで伝播します。

**これが Haskell の型の使い方の核心です。** 「この関数は何をしうるか」がシグネチャに現れます。`findMissingRange` を読むとき、「ログは出さない」「例外処理はしない」ことがシグネチャから分かる。実装を読まなくても、です。

### なぜ `IO` と直接書かないのか

`syncDailyMetric :: OuraClient -> DailyMetric -> DateRange -> ReaderT SqlBackend IO Int` と書いても動きます。しかし、そうすると次ができなくなります。

```haskell
-- src/DailySync.hs:78 — LoggingT IO の上で動かす
result <- flip runSqlPool pool $
    runSync today client Nothing Nothing Nothing backfillDays
```

```haskell
-- src/Handler/Api.hs:120 — Yesod の Handler の上で動かす
result <- runDB $ Sync.runSync today client requestedStart (Just requestedEnd) requestedMetrics 0
```

前者の `m` は `LoggingT IO`、後者の `m` は `HandlerFor App` です。`m` を多相のままにしてあるから、**同じ `runSync` が 2 つの世界で動きます**。第 1 章で見た「ドメイン層が Web フレームワークを知らない」は、この多相性で実現されています。

**指針**: 関数のモナドは、必要な制約だけを列挙した多相型で書く。具体型（`IO`、`Handler`）に固定するのは、その型でしか意味をなさない関数（Handler など）だけ。

## 5.2 `ReaderT SqlBackend m` の読み方

persistent のクエリ関数はすべてこの形をしています。

```
rawSql :: (RawSql a, MonadIO m, BackendCompatible SqlBackend backend)
       => Text -> [PersistValue] -> ReaderT backend m [a]
```

`ReaderT r m a` は「`r` を読める環境で動く、`m` の計算で、結果は `a`」です。つまり `ReaderT SqlBackend m a` は **「SQL 接続を必要とする計算」**。

重要なのは、`ReaderT SqlBackend m` の中では `ask` で接続を取り出せますが、**アプリケーションコードは接続を直接触らない**ことです。`rawSql` や `rawExecute` が内部でやってくれます。私たちにとっての意味は「この関数を呼ぶには DB 接続の文脈が要る」という制約だけです。

```haskell
-- src/Db.hs:86
getLastSyncedDay :: (MonadIO m) => Metric -> ReaderT SqlBackend m (Maybe DayText)
getLastSyncedDay metric = do
    rows <- rawSql
        "SELECT last_synced_day FROM sync_log WHERE metric = ?"
        [toPersistValue (metricName metric)]
    return $ unSingle <$> headMay rows
```

`ReaderT SqlBackend m` の計算どうしは `do` でそのままつながります。トランザクション境界や接続の取り回しは、最後に一度だけ「走らせる」ところで決まります。

### 走らせる 3 つの方法

```haskell
-- (1) プールから 1 接続借りて走らせる（Web / CLI 共通）
--     src/DailySync.hs:78
result <- flip runSqlPool pool $ runSync ...

-- (2) Yesod の runDB（内部で runSqlPool を呼ぶ）
--     src/Foundation.hs:144
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB :: SqlPersistT Handler a -> Handler a
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master

-- (3) テストでインメモリ DB を開いて走らせる
--     test/SyncSpec.hs:29
runMem action = runSqlite ":memory:" $ do
    _ <- runMigrationSilent migrateAll
    action
```

`runSqlPool` は 1 つの `ReaderT SqlBackend` アクション全体を **1 トランザクション**で包みます。これは意識しておく価値があります。`runSync` 全体が 1 トランザクションなので、途中で例外が飛べば（`tryOura` で捕まえていなければ）全部ロールバックされます。逆に、細かくコミットしたければ `runSqlPool` を複数回呼ぶ必要があります。

`Advice` の保存はまさにその形です。フォークされたワーカーは Handler の外にいるので、プールを渡して自分で走らせます。

```haskell
-- src/Handler/Advice.hs:109
saveAdviceIO :: ConnectionPool -> DayText -> DayText -> Text -> IO ()
saveAdviceIO pool start end content =
    runSqlPool (Db.saveAdvice start end content) pool
```

## 5.3 `liftIO` はいつ必要か

```haskell
-- src/Sync.hs:111
records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
```

`fetchFn` が返すのは `DateRange -> IO [Value]` なので、実行結果は `IO [Value]`。しかし今いる文脈は `ReaderT SqlBackend m` です。型が合わないので `liftIO` で持ち上げます。

`liftIO :: MonadIO m => IO a -> m a` は、「素の `IO` アクションを、`IO` の上に積んだ任意のモナドに持ち上げる」関数です。`MonadIO` 制約はこのためにあります。

初学者がつまずくのは「いつ `liftIO` が要るか」ですが、判定は簡単です。

- その式の型が `IO a` そのもの → `liftIO` が要る
- その式の型が `MonadIO m => m a` のような多相 → 要らない（すでに合う）

たとえば `Db.nowIso` は `MonadIO m => m Text` なので、どこで呼んでも `liftIO` は不要です。

```haskell
-- src/Db.hs:26
nowIso :: MonadIO m => m Text
nowIso = formatUtc <$> liftIO getCurrentTime
```

**自作の IO ヘルパーは `MonadIO m => m a` で書いておくと、呼び出し側の `liftIO` が消えます。** `DateText.todayIn`、`todayUtc` も同じ方針です。

```haskell
-- src/DateText.hs:71
todayIn :: MonadIO m => TimeZone -> m DayText
todayIn tz =
    formatDay . localDay . zonedTimeToLocalTime . utcToZonedTime tz
        <$> liftIO getCurrentTime
```

一方、`Oura.OuraClient` のフィールドは意図的に素の `IO` です（理由は第 6 章）。だから呼び出し側に `liftIO` が現れます。**`liftIO` が出てくる箇所は「異なる世界の境界」だと読める**ので、むしろ情報になります。

## 5.4 `MonadUnliftIO` — 「IO に戻せる」能力

`MonadIO` は `IO a` を `m a` にする（持ち上げる）能力でした。`MonadUnliftIO` はその逆、**`m a` を `IO a` に戻す**能力です。

```
class MonadIO m => MonadUnliftIO m where
  withRunInIO :: ((forall a. m a -> IO a) -> IO b) -> m b
```

なぜこれが要るのか。`try`、`catch`、`bracket`、`timeout`、`forkIO` のような関数は `IO` のコールバックを受け取ります。`m` の計算をその中で走らせるには、いったん `IO` に戻さなければなりません。

```haskell
-- src/Sync.hs:303 — try が MonadUnliftIO を要求する
tryOura metric action = do
    r <- try action
```

`ReaderT r m` は `MonadUnliftIO m` なら `MonadUnliftIO` です（環境 `r` を保持したまま `IO` に戻せる）。一方、状態を持つモナド（`StateT`）は `MonadUnliftIO` にできません——`IO` に戻して並行実行したとき、状態をどう合流させるか決められないからです。

**実務での意味**: `StateT` を使い始めると例外処理や並行処理で詰まります。可変状態が要るなら、`StateT` ではなく `ReaderT` に `TVar` / `IORef` を持たせる **ReaderT パターン** が主流です。このプロジェクトはまさにその形で、`App` レコードに `appAdviceJobs :: TVar (Map Text AdviceJob)` を持たせています（第 10 章）。

## 5.5 `MonadLogger` と、それが使えない場所

ログは型クラス `MonadLogger` で抽象化されています。

```haskell
-- src/Sync.hs:119
$logInfo ("sync " <> dailyMetricName metric
    <> " " <> unDayText start <> ".." <> unDayText end
    <> ": " <> tshow count <> " rows")
```

`$logInfo` は Template Haskell のスプライスで、**呼び出し元のファイル名と行番号を埋め込む**ためにこの形になっています（だから `{-# LANGUAGE TemplateHaskell #-}` が要る）。

しかし、このプロジェクトには `MonadLogger` を使えない場所が 2 つあります。

1. `OuraClient` のフィールドは素の `IO`（レコードの型を単純に保つため）
2. `forkIO` で起動されるアドバイスワーカー（Handler の文脈から出ている）

そこで、**ログの出口を値として渡す**設計が採られました。

```haskell
-- src/Logging.hs:55
-- | How a plain-'IO' code path writes a log line.
--
-- Some code that needs to log has no 'MonadLogger' in scope: the
-- 'Oura.OuraClient' record is nine @IO@ functions, and advice jobs are forked
-- with 'forkIO'. Those paths take this handle from whoever built them, so the
-- log destination stays an ordinary value rather than process-wide state.
newtype AppLog = AppLog { writeLog :: LogLevel -> Text -> IO () }
```

```haskell
-- src/Oura.hs:60
realClient :: AppLog -> Text -> OuraClient
realClient appLog token = OuraClient { ... }
  where
    ...
    writeLog appLog LevelDebug ("GET " <> path <> ": " <> tshow (length page) <> " records...")
```

これは **型クラスによる抽象化（`MonadLogger`）と、レコードによる抽象化（`AppLog`）の使い分け**の実例です。

| | 型クラス（`MonadLogger`） | 値（`AppLog`） |
|---|---|---|
| 渡し方 | 暗黙（制約として伝播） | 明示（引数） |
| 記述量 | 少ない | 引数が増える |
| 複数の実装を同時に使う | 難しい | 簡単 |
| モナドの外（素の IO、forkIO） | 使えない | 使える |

このプロジェクトは「モナドの文脈に乗れる場所は型クラス、乗れない場所は値」と割り切りました。実務的な折衷案です。

なお、この設計以前は**グローバルなロガー**（`unsafePerformIO` で作った `IORef` など）を使っていました。それをやめた理由は、Web アプリと cron CLI が**別プロセスで別ファイルに書く**必要があるからです。グローバル変数だと「どちらのプロセスのロガーか」を型で区別できません。

```haskell
-- src/Logging.hs:5
-- | Log destination setup, shared by the web app and the daily sync CLI.
--
-- Both entry points write to their own file under @log@ (they must not share
-- one, since each process holds its own buffered handle).
```

**暗黙のグローバル状態を、明示的な値の受け渡しに置き換える**——これは Haskell に限らない設計改善ですが、Haskell では型がそれを強制できます。

## 5.6 型シノニムで長い型に名前を付ける

```haskell
-- src/Foundation.hs:74
-- | A convenient synonym for database access functions.
type DB a = forall (m :: Type -> Type).
    (MonadUnliftIO m) => ReaderT SqlBackend m a
```

`RankNTypes` を使った型シノニムです。`DB [Text]` と書けば `forall m. MonadUnliftIO m => ReaderT SqlBackend m [Text]` を意味します。

```haskell
-- test/TestImport.hs:83
getTables :: DB [Text]
getTables = do
    tables <- rawSql "SELECT name FROM sqlite_master WHERE type = 'table';" []
    return (fmap unSingle tables)
```

長い型を繰り返し書くくらいなら名前を付ける、という判断です。ただし `forall` を含む型シノニムは、使う場所によっては型推論を難しくすることがあります。**ドメイン層（`Db.hs`、`Sync.hs`）ではあえて使わず、素直に書いている**のは妥当な選択でしょう。

## 5.7 Yesod の `Handler` は何者か

`Foundation.hs` のコメントにあるとおり、`mkYesodData` が型シノニムを生成します。

```haskell
-- src/Foundation.hs:66（コメント）
-- type Handler = HandlerFor App
-- type Widget = WidgetFor App ()
```

`HandlerFor App` は `MonadIO`、`MonadUnliftIO`、`MonadLogger`、`MonadHandler` のインスタンスです。つまり Handler の中では、

- `liftIO` で IO が呼べる
- `runDB` で DB アクセスできる
- `$logInfo` が使える
- `getYesod` で `App`（Foundation）が取れる

これらが全部できます。逆に言えば **Handler は「何でもできる」モナド**なので、ドメインロジックを Handler に書き始めると、第 1 章で見た層の分離が崩れます。Handler が薄いことは良い設計の指標です。

このプロジェクトの Handler を見ると、実際に薄い。

```haskell
-- src/Handler/Api.hs:86
getHeartrateR :: Handler Value
getHeartrateR = do
    requireAuth              -- 認可
    range <- parseRange      -- 入力解析
    rows <- runDB $ Db.getHeartrate range   -- ドメイン呼び出し
    returnJson rows          -- 出力整形
```

**認可 → 入力解析 → ドメイン呼び出し → 出力整形。** Handler の理想形です。判断が入っていません。

## 5.8 この章のまとめ

- 型クラス制約は「この関数に必要な能力」の宣言。少ないほど関数の意味が明確になる。
- `MonadIO` = IO を持ち上げられる、`MonadUnliftIO` = IO に戻せる（例外処理・並行処理に必要）。
- `ReaderT SqlBackend m a` は「DB 接続を要求する計算」。走らせるのは `runSqlPool` / `runDB` / `runSqlite`。
- 自作の IO ヘルパーは `MonadIO m => m a` で書くと呼び出し側が楽になる。
- モナドの文脈に乗れないコード（素の IO、`forkIO`）には、能力を**値として**渡す（`AppLog`）。
- グローバル変数を型で置き換える。
- Handler は何でもできるモナドだからこそ、薄く保つ。

## 演習

1. `findMissingRange` の制約は `MonadIO m` です。`MonadLogger m` を足してログを 1 行入れると、呼び出し側にどんな影響が出ますか。`test/SyncSpec.hs:75` の `runMem` はそのまま動きますか（`runSqlite` が返すモナドは何か、GHCi で確認してください）。

2. `runSync` を `ReaderT SqlBackend IO SyncResult` に固定すると、どのファイルがコンパイルできなくなりますか。予想してから実際に変更して確かめてください。

3. `AppLog` を型クラス（`class Monad m => HasAppLog m where writeLog' :: LogLevel -> Text -> m ()`）にする設計と、現在の newtype 設計を比較してください。`OuraClient` のフィールド型はどう変わりますか。テストでのスタブ差し替えはどちらが簡単ですか。
