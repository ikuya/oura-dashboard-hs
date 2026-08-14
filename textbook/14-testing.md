# 第 14 章 テストの書き方

← [第13章 並行処理とリソース管理](13-concurrency.md) | [目次](README.md) | [第15章 ClassyPrelude・言語拡張・ビルド運用](15-prelude-extensions-build.md) →

> **この章で復習する文法**: hspec の DSL が「ただの関数」であること、`shouldBe` / `shouldSatisfy` の型、型シグネチャを推論に任せる判断と単相性制限、`before` による環境構築、`>>` による連結

Haskell は「型が通れば動く」と言われますが、型が保証しないことは山ほどあります。SQL 文字列の中身、日付計算の境界、外部 API との契約、HTTP のステータスコード。**型で守れないものをテストで守る**のが実務です。

このプロジェクトのテストは `*Spec.hs` が 5 ファイル・約 770 行（`test/Handler/` 以下の 2 ファイルを含む）。3 つの層に分かれています。

| ファイル | 対象 | DB | HTTP |
|---|---|---|---|
| `test/SyncSpec.hs` | 同期ロジック | インメモリ | スタブ |
| `test/DbSpec.hs` | SQL クエリ | インメモリ | なし |
| `test/AppSpec.hs` | HTTP エンドポイント | ファイル（テスト用） | 実際に叩く |
| `test/Handler/CommonSpec.hs`, `test/Handler/HomeSpec.hs` | 静的ページ | ファイル | 実際に叩く |

## 目次

- [14.1 テストの発見は自動](#141-テストの発見は自動)
  - [文法メモ: hspec の DSL は普通の関数](#文法メモ-hspec-の-dsl-は普通の関数)
- [14.2 純粋関数のテストは 1 行](#142-純粋関数のテストは-1-行)
- [14.3 インメモリ SQLite で DB 層をテストする](#143-インメモリ-sqlite-で-db-層をテストする)
  - [文法メモ: 型シグネチャをあえて書かない](#文法メモ-型シグネチャをあえて書かない)
- [14.4 「呼び出し」を検証する](#144-呼び出しを検証する)
- [14.5 元のテストが間違っていたケース](#145-元のテストが間違っていたケース)
- [14.6 HTTP レベルのテスト](#146-http-レベルのテスト)
  - [テスト環境の構築](#テスト環境の構築)
  - [DB の全消去](#db-の全消去)
  - [内部状態を直接操作する](#内部状態を直接操作する)
- [14.7 このテストスイートに足りないもの](#147-このテストスイートに足りないもの)
- [14.8 この章のまとめ](#148-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 14.1 テストの発見は自動

```haskell
-- test/Spec.hs（全 1 行）
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
```

`hspec-discover` はプリプロセッサで、`test/` 以下の `*Spec.hs` を自動的に集めて `main` を生成します。**新しいテストファイルを足しても、どこにも登録しなくてよい。** 規約は「モジュール名が `*Spec` で、`spec :: Spec` を export する」ことだけです。

### 文法メモ: hspec の DSL は普通の関数

```haskell
-- test/SyncSpec.hs:71
spec :: Spec
spec = do
    describe "find_missing_range" $ do
        it "no history returns default start" $ do
            r <- runMem $ findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
            r `shouldBe` Just (DateRange defaultStart "2024-01-31")
```

特別な構文は 1 つもありません。

```
describe :: HasCallStack => String -> SpecWith a -> SpecWith a
it       :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
shouldBe :: (HasCallStack, Show a, Eq a) => a -> a -> Expectation
```

`describe`／`it` は「文字列と中身」を取る関数、`$` は括弧の代わり、`do` は `Spec` モナド（テストを積み上げるモナド）です。`` `shouldBe` `` はバッククォートで中置化した関数で、`shouldBe actual expected` と同じです。

**DSL に見えるものが、実は普通の関数適用である**——これは Haskell のライブラリを読むときに何度も出会うパターンです。特別扱いせず、型を見れば意味が分かります。

## 14.2 純粋関数のテストは 1 行

```haskell
-- test/SyncSpec.hs:106
describe "extract_score" $ do
    let n x = Just (A.Number x)
    it "sleep score" $ extractScore Sleep (obj ["score" .= (85 :: Int)]) `shouldBe` n 85
    it "stress high" $ extractScore Stress (obj ["stress_high" .= (5000 :: Int)]) `shouldBe` n 5000
    it "spo2 nested average" $
        extractScore Spo2 (obj ["spo2_percentage" .= obj ["average" .= (98.5 :: Double)]])
            `shouldBe` n 98.5
    it "spo2 scalar" $
        extractScore Spo2 (obj ["spo2_percentage" .= (97.0 :: Double)]) `shouldBe` n 97.0
    it "resilience unknown" $
        extractScore Resilience (obj ["level" .= ("unknown" :: Text)]) `shouldBe` Nothing
```

セットアップも後片付けもありません。`let n x = Just (A.Number x)` のような**ローカルの短縮記法**を `describe` の中で定義しているのも読みやすさに効いています（`Spec` モナドの `do` の中の `let` です）。

**第 6 章で「判断を純粋関数に切り出せ」と述べた見返りが、ここに現れています。** `spo2` がオブジェクトのこともスカラーのこともある、という厄介な仕様が 2 行のテストで固定されました。同じことを HTTP 経由でテストしようとしたら、スタブを作り、DB を用意し、リクエストを組み立てることになります。

## 14.3 インメモリ SQLite で DB 層をテストする

```haskell
-- test/DbSpec.hs:24-30
-- | Run a DB action against a fresh in-memory database with the schema
-- migrated. Each call gets an isolated database (like the mem_conn fixture).
-- Signature left to inference to avoid importing the ResourceT/NoLoggingT
-- stack that runSqlite fixes internally.
runMem action = runSqlite ":memory:" $ do
    _ <- runMigrationSilent migrateAll
    action
```

`runSqlite ":memory:"` で、**プロセス内に完結する一時 DB** を作ります。ファイルもサーバーも不要で、テストごとに完全に独立します。

```haskell
-- test/DbSpec.hs:40
it "upserts and gets a daily metric" $ do
    rows <- runMem $ do
        upsertDailyMetric Sleep "2024-01-01" (Just 85)
            (A.object ["score" .= (85 :: Int), "day" .= ("2024-01-01" :: Text)])
        getDailyMetrics Sleep (DateRange "2024-01-01" "2024-01-01")
    length rows `shouldBe` 1
    field "day" (headEx rows) `shouldBe` Just (A.String "2024-01-01")
```

**書き込みと読み出しを同じ `runMem` ブロックに入れる**のがポイントです。`ReaderT SqlBackend m` の計算が `do` でつながるので（第 8 章）、セットアップと検証対象が自然に 1 つの式になります。

この形式なら、**SQL 文字列のタイプミス、カラム名の間違い、`INSERT OR REPLACE` の挙動**がすべて検出されます。第 12 章で「型安全クエリを捨てた分をテストで埋める」と述べた、その埋め合わせがこれです。

### 文法メモ: 型シグネチャをあえて書かない

```haskell
runMem action = runSqlite ":memory:" $ do
```

コメントにあるとおり、`runSqlite` が内部で固定する `ResourceT`／`NoLoggingT` のスタックを import せずに済ませるため、シグネチャを推論に任せています。

**トップレベルには型を書くのが原則**（`-Wmissing-signatures` もそう言います）ですが、テストコードで、かつ理由がコメントに書かれているので許容範囲です。**原則を外れるときに理由を書く、という規律の方が重要**です。

なお、シグネチャを書かないと**単相性制限**（monomorphism restriction）で型が単相に固定されるのでは、と心配になるかもしれませんが、`runMem action = ...` は引数を持つ**関数束縛**なので制限の対象外です。推論された型はそのまま一般化され、`runSqlite :: MonadUnliftIO m => Text -> ReaderT SqlBackend (NoLoggingT (ResourceT m)) a -> m a` から `runMem :: MonadUnliftIO m => ReaderT SqlBackend (NoLoggingT (ResourceT m)) a -> m a` という多相型が付きます（`stack ghci` で `:t runMem` として確認できます）。制限が効くのは `runMem = runSqlite ":memory:" . (...)` のような**引数のない束縛**に書き換えた場合で、そのときは制約付きの型が一般化されず、曖昧型エラーや意図しない単相化が起きえます。

## 14.4 「呼び出し」を検証する

第 10 章で見たスタブクライアントを再掲します。

```haskell
-- test/SyncSpec.hs:35
stubClient :: IORef [(Text, DateRange)] -> [A.Value] -> [A.Value] -> OuraClient
stubClient ref daily heartrate = OuraClient
    { getDailySleep = rec "sleep" daily, ... }
  where
    rec metric records range = do
        modifyIORef' ref (++ [(metric, range)])
        return records
```

```haskell
-- test/SyncSpec.hs:65
callsFor :: Text -> [(Text, DateRange)] -> [DateRange]
callsFor metric calls = [ range | (m, range) <- calls, m == metric ]
```

これで「どの範囲を取りに行ったか」を検証できます。

```haskell
-- test/SyncSpec.hs:197
it "heartrate loops to cover full range" $ do
    calls <- runMem $ do
        ref <- newIORef []
        _ <- runSync "2024-03-31" (stubClient ref [] []) Nothing Nothing (Just [HeartrateSeries]) 0
        readIORef ref
    let hr = callsFor "heartrate" calls
    length hr `shouldSatisfy` (> 1)
    (rangeEnd <$> headMay hr) `shouldBe` Just "2024-03-31"
```

**戻り値だけでは検証できない性質**——「30 日窓で複数回に分けて取りに行く」「最初の窓は終了日から始まる」——が、呼び出し記録によって固定されています。

`shouldSatisfy :: (HasCallStack, Show a) => a -> (a -> Bool) -> Expectation` は、任意の述語で検証する関数です。厳密な値を固定できない（できても脆くなる）場合に使います。

```haskell
-- test/SyncSpec.hs:194 — 「29 日以内」という性質だけを固定
forM_ (callsFor "heartrate" calls) $ \(DateRange s e) ->
    diffDaysT e s `shouldSatisfy` (<= 29)
```

**性質で書けるものは性質で書く。** 具体的な窓の切り方が変わってもテストは壊れず、しかし「30 日を超えない」という本質は守られます。

## 14.5 元のテストが間違っていたケース

このプロジェクトで最も教育的なコメントがこれです。

```haskell
-- test/SyncSpec.hs:84
-- NOTE: The Python test_sync assertions for the following cases never
-- actually ran: the conftest mem_conn fixture builds sync_log without
-- last_synced_at, so update_sync_log raises before the assertion. These
-- expectations follow the real sync.py logic: fetch_start =
-- min(refetch_start, next_day), where refetch_start = today - 6.
it "returns Nothing when refetch window is past the capped end" $ do
    r <- runMem $ do
        updateSyncLog (Daily Sleep) "2024-01-31"
        findMissingRange "2024-01-31" (Daily Sleep) "2024-01-10"
    r `shouldBe` Nothing
```

移植元 Python のテストは、**フィクスチャの不備で assert に到達する前に例外を投げていました**。つまり「通っているように見えて何も検証していなかった」。

移植の際にこれが発覚し、**実コードの挙動を読んで正しい期待値を導出**しています。もう 1 箇所も同様です（`test/SyncSpec.hs:257`）。

**教訓が 3 つあります。**

1. **テストが「通っている」ことは、検証していることを意味しない。** 例外で早期に終わるテスト、assert に到達しないテストは、緑になるが無意味。
2. **移植は既存テストを検証する好機。** 別の言語で書き直すと、隠れていた前提が露出する。
3. **期待値の根拠をコメントに書く。** `fetch_start = min(refetch_start, next_day)` という導出過程が書いてあるので、将来テストが落ちたとき「テストが間違っているのか実装が壊れたのか」を判断できる。

## 14.6 HTTP レベルのテスト

```haskell
-- test/AppSpec.hs:36
describe "auth" $ withApp $ do
    it "login succeeds with correct password" $ do
        login
        statusIs 200

    it "login fails with wrong password" $ do
        request $ do
            setMethod "POST"
            setUrl LoginR
            setRequestBody "{\"password\":\"wrong\"}"
            addRequestHeader ("Content-Type", "application/json")
        statusIs 401
```

`yesod-test` は WAI アプリケーションを直接叩きます（実際に TCP ポートを開きません）。速く、確実です。

`setUrl LoginR` が**型安全なルート値**であることに注目してください（第 12 章）。URL 文字列を書いていないので、パスを変えてもテストは壊れません。

`request $ setMethod "POST" >> setUrl SyncR` のような `>>` の連結も出てきます。`RequestBuilder` モナドで、結果を使わない設定を並べているだけです（第 6 章の `do { m; rest }` の脱糖形）。

### テスト環境の構築

```haskell
-- test/TestImport.hs:45
withAppClient :: Maybe OuraClient -> SpecWith (TestApp App) -> Spec
withAppClient mclient = before $ do
    settings <- loadYamlSettings
        ["config/test-settings.yml", "config/settings.yml"]
        []
        useEnv
    foundation0 <- makeFoundation settings
    let foundation = foundation0 { appOuraClientOverride = mclient }
    wipeDB foundation
    logWare <- liftIO $ makeLogWare foundation
    return (foundation, logWare)
```

`before :: IO a -> SpecWith a -> Spec` は各テストの前に走ります。ポイントは 3 つ。

- **本番と同じ `makeFoundation` を使う。** 初期化ロジックをテスト用に書き直すと、そこがテストされない。
- **設定だけ差し替える。** `config/test-settings.yml` が `config/settings.yml` より優先される。
- **DB を毎回全消去する。** テスト間の独立性を確保。

設定ファイルには重要なコメントがあります。

```yaml
# config/test-settings.yml
database:
  # NOTE: By design, this setting prevents the SQLITE_DATABASE environment variable
  # from affecting test runs, so that we don't accidentally affect the
  # production database during testing.
  database: oura_test.sqlite3
```

**テストが本番 DB を壊さないよう、環境変数の上書きを意図的に無効化しています。** `oura.db` は実データなので、事故れば取り返しがつきません。この種の安全策は、コメントで「意図的」と明記しておかないと、後から「なぜ env が効かないのか」と外されかねません。

### DB の全消去

```haskell
-- test/TestImport.hs:60-77
wipeDB :: App -> IO ()
wipeDB app = do
    let logFunc = messageLoggerSource app (appLogger app)

    let dbName = sqlDatabase $ appDatabaseConf $ appSettings app
        connInfo = set fkEnabled False $ mkSqliteConnectionInfo dbName

    pool <- runLoggingT (createSqlitePoolFromInfo connInfo 1) logFunc

    flip runSqlPersistMPool pool $ do
        tables <- getTables
        sqlBackend <- ask
        let queries = map (\t -> "DELETE FROM " ++ getEscapedRawName t sqlBackend) tables
        forM_ queries (\q -> rawExecute q [])
```

テーブル一覧を `sqlite_master` から動的に取得して全部消しています。**テーブルを追加してもこの関数は直さなくてよい。**

`getEscapedRawName` でテーブル名をエスケープしているのは、テーブル名がプレースホルダにできない（`DELETE FROM ?` は書けない）ためです。文字列連結する以上、エスケープが要ります。

### 内部状態を直接操作する

```haskell
-- test/AppSpec.hs:213
-- | Insert a job directly into the foundation's TVar (mirrors the Python tests
-- setting _advice_jobs directly).
insertJob :: Text -> JobStatus -> Text -> Maybe Text -> YesodExample App ()
insertJob jid st advice merr = do
    app <- getTestYesod
    let period = A.object [...]
        job = AdviceJob jid st period advice merr
    liftIO $ atomically $ modifyTVar' (appAdviceJobs app) (M.insert jid job)
```

完了済み・失敗済みのジョブを**直接 `TVar` に注入**しています。実際に `claude` CLI を走らせずに、レスポンスの形（200 / 502 / 202）を検証できます。

```haskell
-- test/AppSpec.hs:181
it "failed job returns 502" $ do
    login
    insertJob "job-failed" Failed "" (Just "分析がタイムアウトしました。")
    get (AdviceJobR "job-failed")
    statusIs 502
```

**外部プロセスに依存する処理は、状態を直接作ってその後を検証する。**

## 14.7 このテストスイートに足りないもの

正直に評価します。

**(1) `runAdviceJob` のテストがない。** `claude` CLI が要るため書かれていません。しかし `readCreateProcessWithExitCode` を呼ぶ部分を引数化すれば（`OuraClient` と同じ発想）、成功・失敗・タイムアウトの各分岐をテストできます。

**(2) `Oura.realClient` のテストがない。** HTTP スタックが要るため。`next_token` ページネーションは自明でないロジックなので、テストの価値は高い。

**(3) 認証ガードの網羅テストがない。** `MetricsR` しか検証していません。

**(4) プロパティテストがない。** `collectGaps` や `findMissingRange` は QuickCheck / Hedgehog に向いた関数です。「返された範囲の日はすべて欠損」「欠損日はどれかの範囲に含まれる」「範囲は重ならない」といった性質を書けます。

**(5) 実行時間の管理がない。** `AppSpec` はファイル DB を使うので、テスト数が増えると遅くなります。

**この節の意図**: テストスイートを見たら「何がテストされているか」だけでなく「**何がテストされていないか**」を把握する習慣を持ってください。カバレッジの穴は、そのまま「壊しても気づけない場所」です。

## 14.8 この章のまとめ

- `hspec-discover` でテストの登録を自動化する。DSL に見えるものは普通の関数。
- 純粋関数のテストは 1 行。第 6 章の設計がここで報われる。
- DB 層はインメモリ SQLite で。書き込みと読み出しを同じブロックに書く。
- 型シグネチャを省く判断はありうるが、理由をコメントに書く。
- スタブに `IORef` を仕込めば「何を呼んだか」を検証できる。
- 具体値で固定できない性質は `shouldSatisfy` で述語として書く。
- テストが緑でも検証しているとは限らない。移植は既存テストを見直す好機。期待値の導出根拠を残す。
- HTTP テストでは型安全ルート値を使う。本番と同じ初期化関数を使い、設定だけ差し替える。
- テストが本番 DB に触れない仕掛けを入れ、意図をコメントに書く。
- 「テストされていないもの」を把握する。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` | プリプロセッサ指定 | `test/Spec.hs` |
| `describe "..." $ do` / `it "..." $ do` | ただの関数適用（`Spec` モナド） | 全テスト |
| `` a `shouldBe` b `` | 等価性の検証（中置化した関数） | `DbSpec` |
| `` a `shouldSatisfy` p `` | 述語による検証 | 心拍窓の 29 日以内 |
| `before act spec` | 各テスト前の環境構築 | `withAppClient` |
| `m >> n` | 結果を使わない連結 | `setMethod "POST" >> setUrl SyncR` |
| シグネチャ省略 | 推論に任せる（理由を書く） | `runMem` |
| `headEx` | 例外を投げる版（テストでは妥当） | `DbSpec` |

---

← [第13章 並行処理とリソース管理](13-concurrency.md) | [目次](README.md) | [第15章 ClassyPrelude・言語拡張・ビルド運用](15-prelude-extensions-build.md) →
