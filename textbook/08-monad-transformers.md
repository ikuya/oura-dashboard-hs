# 第 8 章 モナド変換子と制約の実務

> **この章で復習する文法**: モナド変換子（`ReaderT`）の型の読み方、`lift` と `liftIO`、`MonadIO` / `MonadUnliftIO` / `MonadLogger` 制約、`type` シノニムと `RankNTypes`（`forall`）、`$logInfo` のような TH スプライス

入門書の「モナド」は `IO` と `Maybe` で終わりますが、実務のコードには `ReaderT SqlBackend m`、`MonadUnliftIO m`、`LoggingT IO`、`Handler` といった型が並びます。この章では、それらを**「能力の宣言」として読む**方法を身につけます。

## 8.1 制約は「この関数に必要な能力」の一覧

まず 4 つのシグネチャを並べてみます。

```haskell
-- src/Sync.hs:199
foldRanges :: (Monad m) => (DateRange -> m RangeResult) -> [DateRange] -> m RangeResult

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
```

制約の違いをそのまま日本語にするとこうなります。

| 関数 | 宣言している能力 |
|---|---|
| `foldRanges` | 順に実行できる（それだけ） |
| `findMissingRange` | IO を実行できる ＋ SQL 接続を使える |
| `syncDailyMetric` | IO ＋ SQL 接続 ＋ ログを書ける |
| `runSync` | IO ＋ SQL 接続 ＋ ログ ＋ **例外を捕まえられる** |

`runSync` だけが `MonadUnliftIO` である理由は、内部で `tryOura`（`try` を使う）を呼ぶからです。`try :: (MonadUnliftIO m, Exception e) => m a -> m (Either e a)` が `MonadUnliftIO` を要求するので、その制約が呼び出し元まで伝播します。

**これが Haskell の型の使い方の核心です。** 「この関数は何をしうるか」がシグネチャに現れます。`findMissingRange` を読むとき、「ログは出さない」「例外処理はしない」ことが実装を見ずに分かります。

### なぜ `IO` と直接書かないのか

`syncDailyMetric :: ... -> ReaderT SqlBackend IO Int` と書いても動きます。しかし、そうすると次ができなくなります。

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

> **指針**: 関数のモナドは、必要な制約だけを列挙した多相型で書く。具体型（`IO`、`Handler`）に固定するのは、その型でしか意味をなさない関数（ハンドラなど）だけ。

## 8.2 モナド変換子と `ReaderT SqlBackend m`

### 文法メモ: 変換子の型の形

モナド変換子は「既存のモナド `m` に能力を 1 段積む」型です。

| 変換子 | 積む能力 | 型 |
|---|---|---|
| `ReaderT r m a` | 読み取り専用の環境 `r` | 環境を渡して `m a` を得る |
| `LoggingT m a` | ログ出力先 | 同上（`DailySync.hs` で使用） |
| `StateT s m a` | 可変状態 | （このプロジェクトでは不使用。理由は 8.4） |

`ReaderT SqlBackend m a` は **「SQL 接続を必要とする、`m` の計算で、結果は `a`」** と読みます。persistent のクエリ関数はすべてこの形です。

```
rawSql :: (RawSql a, MonadIO m, BackendCompatible SqlBackend backend)
       => Text -> [PersistValue] -> ReaderT backend m [a]
```

重要なのは、`ReaderT SqlBackend m` の中では `ask` で接続を取り出せるものの、**アプリケーションコードは接続を直接触らない**ことです。`rawSql` や `rawExecute` が内部でやってくれます。私たちにとっての意味は「この関数を呼ぶには DB 接続の文脈が要る」という制約だけです。

```haskell
-- src/Db.hs:86
getLastSyncedDay :: (MonadIO m) => Metric -> ReaderT SqlBackend m (Maybe DayText)
getLastSyncedDay metric = do
    rows <- rawSql
        "SELECT last_synced_day FROM sync_log WHERE metric = ?"
        [toPersistValue (metricName metric)]
    return $ unSingle <$> headMay rows
```

`ReaderT SqlBackend m` の計算どうしは `do` でそのままつながります。第 6 章の `syncDailyMetric` が `upsertDailyMetric` を何度も呼べるのはこのためです。

### 走らせる 3 つの方法

積んだ層は、いつか「剥がして」実行しなければなりません。

```haskell
-- (1) プールから 1 接続借りて走らせる（CLI）
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

アドバイスの保存はまさにその形です。フォークされたワーカーは Handler の外にいるので、プールを渡して自分で走らせます。

```haskell
-- src/Handler/Advice.hs:109
saveAdviceIO :: ConnectionPool -> DayText -> DayText -> Text -> IO ()
saveAdviceIO pool start end content =
    runSqlPool (Db.saveAdvice start end content) pool
```

## 8.3 `liftIO` はいつ必要か

```haskell
-- src/Sync.hs:111
records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
```

`fetchFn` が返すのは `DateRange -> IO [Value]` なので、実行結果は `IO [Value]`。しかし今いる文脈は `ReaderT SqlBackend m` です。型が合わないので `liftIO` で持ち上げます。

```
liftIO :: MonadIO m => IO a -> m a
```

判定は簡単です。

- その式の型が `IO a` そのもの → `liftIO` が要る
- その式の型が `MonadIO m => m a` のような多相 → 要らない（すでに合う）

**自作の IO ヘルパーは `MonadIO m => m a` で書いておくと、呼び出し側の `liftIO` が消えます。**

```haskell
-- src/Db.hs:26
nowIso :: MonadIO m => m Text
nowIso = formatUtc <$> liftIO getCurrentTime

-- src/DateText.hs:71
todayIn :: MonadIO m => TimeZone -> m DayText
todayIn tz =
    formatDay . localDay . zonedTimeToLocalTime . utcToZonedTime tz
        <$> liftIO getCurrentTime
```

一方、`OuraClient` のフィールドは意図的に素の `IO` です（理由は第 10 章）。だから呼び出し側に `liftIO` が現れます。**`liftIO` が出てくる箇所は「異なる世界の境界」だと読める**ので、むしろ情報になります。

> `lift` は「1 段だけ持ち上げる」汎用の関数ですが、実務では `liftIO`（何段でも `IO` まで持ち上げる）を使う方が圧倒的に多く、このコードベースには `lift` の直接使用はありません。

## 8.4 `MonadUnliftIO` — 「IO に戻せる」能力

`MonadIO` は `IO a` を `m a` にする（持ち上げる）能力でした。`MonadUnliftIO` はその逆、**`m a` を `IO a` に戻す**能力です。

```
class MonadIO m => MonadUnliftIO m where
  withRunInIO :: ((forall a. m a -> IO a) -> IO b) -> m b
```

なぜこれが要るのか。`try`、`catch`、`bracket`、`timeout`、`forkIO` のような関数は `IO` のコールバックを受け取ります。`m` の計算をその中で走らせるには、いったん `IO` に戻さなければなりません。

GHCi で確かめると、インスタンスは限られていることが分かります。

```
instance MonadUnliftIO IO
instance MonadUnliftIO m => MonadUnliftIO (ReaderT r m)
```

`ReaderT r m` は（`m` がそうなら）`MonadUnliftIO` です。環境 `r` を保持したまま `IO` に戻せるからです。一方、**状態を持つモナド（`StateT`）は `MonadUnliftIO` にできません**。`IO` に戻して並行実行したとき、状態をどう合流させるか決められないからです。

**実務での意味**: `StateT` を使い始めると例外処理や並行処理で詰まります。可変状態が要るなら、`StateT` ではなく `ReaderT` に `TVar` / `IORef` を持たせる **ReaderT パターン**が主流です。このプロジェクトはまさにその形で、`App` レコードに `appAdviceJobs :: TVar (Map Text AdviceJob)` を持たせています（第 13 章）。

## 8.5 `MonadLogger` と、それが使えない場所

ログは型クラス `MonadLogger` で抽象化されています。

```haskell
-- src/Sync.hs:119
$logInfo ("sync " <> dailyMetricName metric
    <> " " <> unDayText start <> ".." <> unDayText end
    <> ": " <> tshow count <> " rows")
```

`$logInfo` は Template Haskell のスプライスで、**呼び出し元のファイル名と行番号を埋め込む**ためにこの形になっています。だから `{-# LANGUAGE TemplateHaskell #-}` が要ります。**無いと `$` が関数適用演算子として解釈され、原因の分かりにくいエラーになります。**

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
-- src/Oura.hs:89
writeLog appLog LevelDebug
    ("GET " <> path <> ": " <> tshow (length page) <> " records, ...")
```

これは **型クラスによる抽象化と、レコードによる抽象化の使い分け**の実例です。

| | 型クラス（`MonadLogger`） | 値（`AppLog`） |
|---|---|---|
| 渡し方 | 暗黙（制約として伝播） | 明示（引数） |
| 記述量 | 少ない | 引数が増える |
| 複数の実装を同時に使う | 難しい | 簡単 |
| モナドの外（素の IO、`forkIO`） | 使えない | 使える |

このプロジェクトは「モナドの文脈に乗れる場所は型クラス、乗れない場所は値」と割り切りました。実務的な折衷案です。

なお、この設計以前は**グローバルなロガー**を使っていました。やめた理由は、Web アプリと cron CLI が**別プロセスで別ファイルに書く**必要があるからです。

```haskell
-- src/Logging.hs:5
-- | Log destination setup, shared by the web app and the daily sync CLI.
--
-- Both entry points write to their own file under @log@ (they must not share
-- one, since each process holds its own buffered handle).
```

**暗黙のグローバル状態を、明示的な値の受け渡しに置き換える**——Haskell に限らない設計改善ですが、Haskell では型がそれを強制できます。

## 8.6 型シノニムで長い型に名前を付ける

```haskell
-- src/Foundation.hs:74
-- | A convenient synonym for database access functions.
type DB a = forall (m :: Type -> Type).
    (MonadUnliftIO m) => ReaderT SqlBackend m a
```

`RankNTypes` を使った型シノニムです。`DB [Text]` と書けば `forall m. MonadUnliftIO m => ReaderT SqlBackend m [Text]` を意味します。

### 文法メモ: `forall` と RankNTypes

通常、シグネチャの型変数には暗黙の `forall` が付いています（`f :: a -> a` は `f :: forall a. a -> a`）。`RankNTypes` は、その `forall` を**型の内側**に書けるようにする拡張です。上の例では「シノニムを展開した先で `m` が全称量化される」ことを表しています。

`(m :: Type -> Type)` は**カインド注釈**です。`m` が「型を取って型を返す」種類の型変数であることを明示しています（`ExplicitForAll` と `KindSignatures` が必要で、`Foundation.hs:7` で有効化されています）。

```haskell
-- test/TestImport.hs:83
getTables :: DB [Text]
getTables = do
    tables <- rawSql "SELECT name FROM sqlite_master WHERE type = 'table';" []
    return (fmap unSingle tables)
```

長い型を繰り返し書くくらいなら名前を付ける、という判断です。ただし `forall` を含む型シノニムは、使う場所によっては型推論を難しくします。**ドメイン層（`Db.hs`、`Sync.hs`）ではあえて使わず、素直に書いている**のは妥当な選択でしょう。

## 8.7 Yesod の `Handler` は何者か

`mkYesodData` が生成する型シノニムです。

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

これらが全部できます。逆に言えば **Handler は「何でもできる」モナド**なので、ドメインロジックを Handler に書き始めると、第 1 章で見た層の分離が崩れます。**Handler が薄いことは良い設計の指標です。**

このプロジェクトの Handler は実際に薄い。

```haskell
-- src/Handler/Api.hs:86
getHeartrateR :: Handler Value
getHeartrateR = do
    requireAuth                              -- 認可
    range <- parseRange                      -- 入力解析
    rows <- runDB $ Db.getHeartrate range    -- ドメイン呼び出し
    returnJson rows                          -- 出力整形
```

**認可 → 入力解析 → ドメイン呼び出し → 出力整形。** 判断が入っていません。ハンドラの理想形です。

## 8.8 この章のまとめ

- 型クラス制約は「この関数に必要な能力」の宣言。少ないほど関数の意味が明確になる。
- 具体型（`IO`）に固定せず多相にしておくと、Web と CLI の 2 つの世界で同じ関数が動く。
- `ReaderT SqlBackend m a` は「DB 接続を要求する計算」。走らせるのは `runSqlPool` / `runDB` / `runSqlite`。`runSqlPool` の 1 回が 1 トランザクション。
- `MonadIO` = IO を持ち上げられる、`MonadUnliftIO` = IO に戻せる（例外処理・並行処理に必要）。
- 自作の IO ヘルパーは `MonadIO m => m a` で書くと呼び出し側が楽になる。
- 可変状態は `StateT` ではなく `ReaderT` + `TVar`。`StateT` は `MonadUnliftIO` になれない。
- モナドの文脈に乗れないコード（素の IO、`forkIO`）には、能力を**値として**渡す（`AppLog`）。
- 長い型は `type` シノニムに。`forall` を含むものは推論に影響するので用途を限る。
- Handler は何でもできるモナドだからこそ、薄く保つ。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `ReaderT r m a` | 環境 `r` を要求する `m` の計算 | `ReaderT SqlBackend m Int` |
| `MonadIO m =>` | `liftIO` が使える | `nowIso`, `todayIn` |
| `MonadUnliftIO m =>` | `try` / `timeout` / `bracket` が使える | `runSync`, `tryOura` |
| `MonadLogger m =>` | `$logInfo` などが使える | `syncDailyMetric` |
| `liftIO act` | `IO a` を `m a` に持ち上げる | `liftIO $ Oura.getHeartrate ...` |
| `runSqlPool act pool` | `ReaderT SqlBackend` を走らせる（1 トランザクション） | `DailySync.hs`, `saveAdviceIO` |
| `$logInfo "..."` | TH スプライス（要 `TemplateHaskell`） | `Sync.hs` |
| `type T a = forall m. C m => ...` | `RankNTypes` を使った型シノニム | `type DB a` |
| `(m :: Type -> Type)` | カインド注釈 | `Foundation.hs:74` |
