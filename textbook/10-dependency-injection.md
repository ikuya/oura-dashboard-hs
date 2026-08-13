# 第 10 章 関数のレコードによる依存性注入

> **この章で復習する文法**: 高階関数（関数を引数・戻り値・フィールドに持つ）、クロージャ、部分適用によるインスタンス化、レコード更新によるオーバーライド、型クラス DI との比較

外部サービス（HTTP API、ファイルシステム、別プロセス）に依存するコードを、どうやってテスト可能にするか。オブジェクト指向言語ならインターフェースとモックですが、Haskell には複数の流儀があります。

このプロジェクトは **「関数を持つレコード」** を採用しました。理由と、他の選択肢との比較を見ていきます。

## 10.1 インターフェースはただのレコード

```haskell
-- src/Oura.hs:38
-- | The set of fetch operations the sync layer needs. Each takes an inclusive
-- date range and returns the concatenated @data@ array.
data OuraClient = OuraClient
    { getDailySleep             :: DateRange -> IO [Value]
    , getDailyReadiness         :: DateRange -> IO [Value]
    , getDailyActivity          :: DateRange -> IO [Value]
    , getDailyStress            :: DateRange -> IO [Value]
    , getDailySpo2              :: DateRange -> IO [Value]
    , getDailyResilience        :: DateRange -> IO [Value]
    , getDailyCardiovascularAge :: DateRange -> IO [Value]
    , getVO2Max                 :: DateRange -> IO [Value]
    , getHeartrate              :: DateRange -> IO [Value]
    }
```

これは **インターフェース定義そのもの**です。「日付範囲を渡すと JSON の配列が返る操作が 9 つある」。実装は含まれていません。

Java や TypeScript の `interface` に相当しますが、Haskell では**ただのレコード型**です。特別な言語機能を使っていません。値なので、変数に入れ、引数で渡し、フィールドを差し替えられます。

### 文法メモ: 高階関数

Haskell では関数が第一級の値です。したがって、

- 関数を**引数**に取れる（`foldRanges :: (DateRange -> m RangeResult) -> ...`）
- 関数を**返せる**（`fetchFn :: OuraClient -> DailyMetric -> Maybe (DateRange -> IO [Value])`）
- 関数を**データ構造に入れられる**（`OuraClient`、`AppLog`）

3 つ目が、この章のテーマです。「オブジェクト = 状態 + メソッド」の代わりに「レコード = 関数の束」を使う、と考えると分かりやすいでしょう。

## 10.2 本番の実装 — 部分適用とクロージャ

```haskell
-- src/Oura.hs:58
-- | Build the real client bound to a bearer token. Fetches run in plain IO,
-- so the log destination is passed in rather than looked up.
realClient :: AppLog -> Text -> OuraClient
realClient appLog token = OuraClient
    { getDailySleep             = getDated "/v2/usercollection/daily_sleep"
    , getDailyReadiness         = getDated "/v2/usercollection/daily_readiness"
    ...
    , getHeartrate              = \range -> getPaged
        "/v2/usercollection/heartrate"
        [ ("start_datetime", dateToDatetime (rangeStart range) False)
        , ("end_datetime",   dateToDatetime (rangeEnd range) True) ]
    }
  where
    getDated path range = getPaged path
        [ ("start_date", unDayText (rangeStart range))
        , ("end_date",   unDayText (rangeEnd range)) ]

    getPaged :: Text -> [(Text, Text)] -> IO [Value]
    getPaged path params = go Nothing []
      where ...
```

注目すべき点が 3 つあります。

**(1) 部分適用でクライアントを組み立てている。** `getDated "/v2/usercollection/daily_sleep"` は、`getDated :: Text -> DateRange -> IO [Value]` に第 1 引数だけ与えた**関数**です。9 フィールドのうち 8 つ（`getDailySleep` 〜 `getVO2Max`）はこの `getDated` にパスだけ変えて束ねられています。継承もテンプレートメソッドも使っていません。残る `getHeartrate` だけは上の抜粋にあるとおり別実装で、`start_date`/`end_date` ではなく `start_datetime`/`end_datetime` を要求する Oura API のエンドポイントに合わせて `getPaged` を直接呼んでいます。

**(2) 設定（トークン、ログ出力先）はクロージャに閉じ込められている。** `realClient appLog token` を呼んだ時点で、返ってくる `OuraClient` はトークンを内部に保持しています。`where` 内の `httpGet` が引数リストに `token` を持たないのは、外側の引数を捕まえているからです。

使う側（`Sync.hs`）はトークンの存在を知りません。

```haskell
-- src/Sync.hs:111 — トークンもログ出力先も見えない
records <- liftIO $ maybe (return []) ($ range) (fetchFn client metric)
```

**(3) `where` に実装を隠している。** `getPaged`、`httpGet`、`mkHttpError` は `realClient` の `where` にあり、モジュール外どころか同じモジュールの他の関数からも見えません。export リストにも当然ありません。**スコープを最小にする**のは、Haskell でも他の言語でも変わらない原則です。

## 10.3 テストではレコードを差し替える

```haskell
-- test/SyncSpec.hs:35
-- | A stub client that returns fixed daily/heartrate records and records the
-- (metric, range) of each call into the given IORef.
stubClient :: IORef [(Text, DateRange)] -> [A.Value] -> [A.Value] -> OuraClient
stubClient ref daily heartrate = OuraClient
    { getDailySleep             = rec "sleep" daily
    , getDailyReadiness         = rec "readiness" daily
    ...
    , getHeartrate              = rec "heartrate" heartrate
    }
  where
    rec metric records range = do
        modifyIORef' ref (++ [(metric, range)])
        return records
```

モックライブラリは使っていません。**同じ型の別の値を作っただけ**です。しかもこのスタブは「何が呼ばれたか」を `IORef` に記録するので、スパイ（呼び出し記録）としても働きます。

```haskell
-- test/SyncSpec.hs:173
it "requested_start overrides incremental" $ do
    calls <- runMem $ do
        updateSyncLog (Daily Sleep) "2024-01-20"
        ref <- newIORef []
        _ <- runSync "2024-01-31" (stubClient ref [...]) (Just "2024-01-10") Nothing (Just [Daily Sleep]) 0
        readIORef ref
    callsFor "sleep" calls `shouldBe` [DateRange "2024-01-10" "2024-01-31"]
```

「`requested_start` を渡したら、増分同期の範囲ではなくその日付から取りに行くこと」を、**実際に呼ばれた範囲**で検証しています。戻り値だけでなく「どう呼んだか」を検証できるのがスパイの利点です。

### レコード更新構文で 1 フィールドだけ差し替える

```haskell
-- test/SyncSpec.hs:53
erroringSleepClient :: OuraClient
erroringSleepClient =
    let base = stubClientPure
    in base { getDailySleep = \_ -> throwIO (OuraError (Just 401) "Unauthorized") }
```

**「sleep だけ失敗するクライアント」**が 3 行で作れます。モックフレームワークの `when(...).thenThrow(...)` に相当することが、言語機能だけでできています。

このスタブを使ったテストが、第 7 章で見た部分的失敗の検証です。

```haskell
-- test/SyncSpec.hs:183
it "captures API errors" $ do
    result <- runMem $
        runSync "2024-01-31" erroringSleepClient Nothing Nothing (Just [Daily Sleep]) 0
    M.member (Daily Sleep) (syncErrors result) `shouldBe` True
    M.findWithDefault 0 (Daily Sleep) (syncedCounts result) `shouldBe` 0
```

## 10.4 テスト用の差し込み口（test seam）

ドメイン層は引数でクライアントを受け取るので差し替えが簡単ですが、**Handler は引数を取れません**。HTTP リクエストから呼ばれるからです。

そこで Foundation にフィールドを用意しています。

```haskell
-- src/Foundation.hs:44
, appOuraClientOverride :: Maybe OuraClient
  -- ^ Test seam: when set, the sync handler uses this client instead of
  -- building a real one from OURA_TOKEN (mirrors the Python test mocking
  -- run_sync). 'Nothing' in production.
```

```haskell
-- src/Handler/Api.hs:112
app <- getYesod
client <- case appOuraClientOverride app of
    Just c  -> return c
    Nothing -> do
        let token = appOuraToken (appSettings app)
        when (null token) $
            sendStatusJSON status500 (A.object ["error" A..= ("OURA_TOKEN not set" :: Text)])
        return (realClient (appPlainLogger app) token)
```

```haskell
-- test/TestImport.hs:45
withAppClient :: Maybe OuraClient -> SpecWith (TestApp App) -> Spec
withAppClient mclient = before $ do
    settings <- loadYamlSettings [...]
    foundation0 <- makeFoundation settings
    let foundation = foundation0 { appOuraClientOverride = mclient }
    ...
```

**評価**: これは「テストのために本番コードに分岐を入れる」パターンで、一般には歓迎されません。ただし、

- 型が `Maybe OuraClient` なので、本番では常に `Nothing` であることがコードから明白
- コメントで test seam であると明記されている
- 代替案（Foundation を組み立てる関数を差し替え可能にする、`OuraClient` を必ず外から注入する）はいずれも本番側の記述量を増やす

という事情から、**実務的な妥協として許容範囲**です。より良い設計は、`App` が `appOuraClient :: OuraClient` を常に持ち（`Maybe` でなく）、`makeFoundation` が本番用を作り、テストが差し替える形でしょう（第 16 章）。

## 10.5 依存が関数 1 個なら、レコードすら要らない

```haskell
-- src/Advice.hs:164
runAdviceJob
    :: AppLog
    -> AdviceJobs
    -> Text                                   -- ^ job id
    -> Text                                   -- ^ prompt
    -> (DayText -> DayText -> Text -> IO ())  -- ^ save action: start end content
    -> IO ()
```

第 5 引数が「アドバイスを保存する方法」です。`Advice.hs` は**保存方法を知りません**。DB かもしれないし、ファイルかもしれないし、何もしないかもしれない。

呼び出し側が決めます。

```haskell
-- src/Handler/Advice.hs:46
liftIO $ void $ forkIO $
    Advice.runAdviceJob (appPlainLogger app) (appAdviceJobs app) jid prompt
        (saveAdviceIO pool)
```

この設計の効果は、ワーカー本体が DB の型に一切触れないことです。テストで `runAdviceJob` を検証したければ、`\_ _ _ -> return ()` や `IORef` に書くだけの関数を渡せます。

**判断基準**:

| 依存の数 | 推奨 |
|---|---|
| 1〜2 個の関数 | そのまま引数で渡す |
| 3 個以上、まとまった概念 | レコードにまとめる |
| モナド全体の能力として抽象化したい | 型クラス（次節） |

## 10.6 型クラスによる DI との比較

Haskell の教科書では、依存性注入に型クラスを使う方法（mtl スタイル）もよく紹介されます。

```haskell
-- 型クラス版（このプロジェクトでは採用していない）
class Monad m => MonadOura m where
    getDailySleep     :: DateRange -> m [Value]
    getDailyReadiness :: DateRange -> m [Value]
    ...

instance MonadOura AppM  where ...
instance MonadOura TestM where ...
```

比較します。

| | レコード（採用） | 型クラス |
|---|---|---|
| 渡し方 | 明示的な引数 | 暗黙（制約経由） |
| 同じ型の別実装を同時に使う | できる（値だから） | できない（インスタンスは型ごとに 1 つ） |
| 実装の差し替え | レコード更新構文で 1 行 | 新しいモナドと全インスタンスが必要 |
| 部分的な差し替え | `base { field = ... }` | 難しい |
| 引数の数 | 増える | 増えない |
| 実装の切り替えを型で強制 | されない | される |

このプロジェクトが**レコードを選んだ理由**は、`test/SyncSpec.hs` を見れば明らかです。テストごとに違う挙動のクライアント（正常・エラー・記録付き）を作り、`erroringSleepClient` のように 1 フィールドだけ変える。型クラスでこれをやるには、テストごとに newtype とインスタンスを定義することになります。

さらに、`appOuraClientOverride` のように **実行時に実装を選ぶ**必要がある場合、値である方が素直です。型クラスは型で決まるので、実行時分岐と相性が良くありません。

> **一般則**: 「実装が実行時に決まる」「複数の実装を同時に使う」「部分的に差し替える」なら値（レコード）。「モナドの能力として全体に効かせたい」「実装を型で強制したい」なら型クラス。

このプロジェクトは実際に両方使っています。ログは `MonadLogger`（型クラス）と `AppLog`（値）の併用でした（第 8 章）。**どちらか一方に統一するのが正しいのではなく、場面で選ぶ**というのが実務の答えです。

## 10.7 レコード DI の弱点

正直に弱点も書いておきます。

**(1) フィールドが増えると全実装の更新が必要。** `OuraClient` に 10 個目のメトリックを足すと、`realClient`、`stubClient`、`stubClientPure`（`test/SyncSpec.hs:58`）、`syncStubClient`（`test/AppSpec.hs:25`）の 4 箇所を直すことになります。

これは「レコードのフィールドを網羅する」ための構文がないためです。緩和策として、既定値を持つクライアントを 1 つ用意する手があります。

```haskell
-- 改善案: 全フィールドが空を返すクライアントを用意し、必要な分だけ上書きする
emptyClient :: OuraClient
emptyClient = OuraClient { getDailySleep = c, ... } where c _ = return []

myClient = emptyClient { getDailySleep = \_ -> return [record] }
```

`test/AppSpec.hs:25` の `syncStubClient` は実質これを手書きしています。共通化の余地があります。

**(2) フィールドの型が固定される。** `DateRange -> IO [Value]` なので、`MonadIO m => DateRange -> m [Value]` にしたければレコード自体を多相にする必要があり、扱いが面倒になります。だからこそ第 8 章で見たとおり、ログを `AppLog` として別途渡す設計になっています。

**(3) 引数として持ち回る手間。** `runSync` は `client` を引数で受け取り、内部の `syncDailyMetric`、`syncHeartrateRange` へ渡し続けます。依存が増えると引数が膨らみます。その場合は環境レコードを `ReaderT` で持ち回る形に移行するのが定石です。このアプリの規模では引数渡しで十分、という判断です。

## 10.8 この章のまとめ

- 外部依存は「関数を持つレコード」で表現する。特別な言語機能は要らない。
- 本番実装は部分適用と `where` で組み立て、設定はクロージャに閉じ込める。
- テストは同じ型の別の値を作るだけ。レコード更新構文で 1 フィールドだけ差し替えられる。
- `IORef` を仕込めばスパイになる。「何を呼んだか」を検証できる。
- 依存が関数 1 個なら、レコードにせず引数で渡す（`runAdviceJob` の保存関数）。
- 型クラス DI との使い分け: 実行時に選ぶ・複数同時・部分差し替え → 値。型で強制したい → 型クラス。
- Handler のように引数を取れない場所には test seam を置くことになる。置くなら型とコメントで意図を明示する。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `data R = R { f :: A -> IO B }` | 関数をフィールドに持つレコード | `OuraClient` |
| `f x` の部分適用 | 共通実装＋パラメータ | `getDated "/v2/..."` |
| `where` によるクロージャ | 外側の引数を捕まえる | `realClient` の `httpGet` |
| `r { f = g }` | 1 フィールドだけ差し替え | `erroringSleepClient` |
| `(A -> B -> IO ())` を引数に | 依存 1 個の注入 | `runAdviceJob` の保存関数 |
| `Maybe Impl` フィールド | test seam（本番は `Nothing`） | `appOuraClientOverride` |
