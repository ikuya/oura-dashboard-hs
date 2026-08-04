# 第 4 章 失敗の表現を選ぶ — Maybe / Either / 例外

Haskell には失敗を表す手段が複数あります。初心者は「`Maybe` を使えばいい」と思いがちですが、実務では **状況ごとに使い分ける** ことが求められます。この章では、このプロジェクトの実際の選択とその理由、そして 1 度失敗して直した例を見ます。

## 4.1 4 つの選択肢と使い分けの原則

| 手段 | 意味 | 使うべき場面 |
|---|---|---|
| `Maybe a` | 失敗の理由はどうでもいい | 「無い」で説明がつく。呼び出し側が理由を使わない |
| `Either e a` | 失敗の理由を返す | 呼び出し側が理由で分岐する／ユーザーに見せる |
| 例外（`throwIO` / `Exception`） | 深い場所で起き、遠くで捕まえる | IO の途中で起き、途中の層が扱えない |
| `error` | プログラマのバグ | 起きたらプログラムが間違っている（外部入力では**使わない**） |

原則は **「呼び出し側がその情報を使うか」** です。理由を使わないなら `Maybe`、使うなら `Either`、途中の層を素通りさせたいなら例外。

## 4.2 `Maybe` — 理由が要らない失敗

```haskell
-- src/Json.hs:23
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup k (Object o) = KM.lookup (K.fromText k) o
jsonLookup _ _          = Nothing
```

「キーが無い」のか「そもそもオブジェクトじゃない」のかを区別していません。呼び出し側はどちらでも同じ扱い（既定値にする、スキップする）をするからです。区別できる `Either` にしても、誰も理由を見ないなら記述が増えるだけです。

```haskell
-- src/Metric.hs:66
parseDailyMetric :: Text -> Maybe DailyMetric
```

同様に、未知のメトリック名は「知らない名前だった」以上の情報がありません。呼び出し側でメッセージを作ります。

```haskell
-- src/Handler/Api.hs:76
metric <- case parseDailyMetric name of
    Just m | m `elem` dashboardMetrics -> return m
    _ -> sendStatusJSON status400
            (A.object ["error" A..= ("Unknown metric: " <> name)])
```

ここで `Maybe` の値が消費され、HTTP のエラー応答という「その層にふさわしい形」に変換されています。**失敗の表現は層をまたぐたびに翻訳される** ——これが実務コードの基本形です。

### `Maybe` を連鎖させる

`Maybe` の真価は合成にあります。

```haskell
-- src/Advice.hs:207
periodBounds v = (,) <$> field "start" <*> field "end"
  where
    field k = DayText <$> (jsonText =<< jsonLookup k v)
```

「`start` と `end` の両方が取れたらペアにする、片方でも欠けたら `Nothing`」を 1 行で書いています。`<$>` と `<*>`（Applicative スタイル）は、**複数の `Maybe` を集めて 1 つの値を作る**ときの定型です。

同じことを `do` で書いてもよく、実際 `extractScore` の `Resilience` 節ではそうしています（第 3 章）。使い分けの目安は、**後の計算が前の結果に依存するなら `do`、独立して集めるだけなら `<$>`/`<*>`** です。

## 4.3 例外 — 遠くまで飛ばす失敗

HTTP クライアントの失敗は例外にしています。

```haskell
-- src/Oura.hs:31
data OuraError = OuraError
    { ouraErrorStatus  :: Maybe Int
    , ouraErrorMessage :: Text
    } deriving (Show)

instance Exception OuraError
```

なぜ `Either OuraError [Value]` ではないのか。`OuraClient` の型を見ると分かります。

```haskell
-- src/Oura.hs:41
data OuraClient = OuraClient
    { getDailySleep :: DateRange -> IO [Value]
    , ...
```

もし `IO (Either OuraError [Value])` にすると、9 個のフィールドすべてに `Either` が付き、ページネーションのループ（`getPaged` の再帰）でも毎回 `case` で開く必要が出ます。さらに `Sync` 側の呼び出しも全部 `Either` の面倒を見ることになります。

`IO` の中では、**「失敗したら以降を実行しない」を例外に任せた方が全体の記述が減ります**。その代わり、**捕まえる場所を 1 箇所に決める**のが条件です。

```haskell
-- src/Sync.hs:298
-- | Run a DB+client action, catching OuraError and returning its message.
-- The failure is logged here: callers only fold it into 'syncErrors', so
-- without this an errored metric leaves no trace in the log.
tryOura
    :: (MonadUnliftIO m, MonadLogger m)
    => Metric
    -> ReaderT SqlBackend m a
    -> ReaderT SqlBackend m (Either Text a)
tryOura metric action = do
    r <- try action
    case r of
        Left (OuraError _ msg) -> do
            $logError $ "sync failed for " <> metricName metric <> ": " <> msg
            return (Left msg)
        Right a                -> return (Right a)
```

この関数が **例外と `Either` の境界** です。ここから内側は例外で飛び、ここから外側は `Either Text a` として扱われます。境界が 1 つに固定されているので、「どこで例外が消えるか」を読み手が探さずに済みます。

そして境界を通過した後は、値として集計されます。

```haskell
-- src/Sync.hs:188
data SyncResult = SyncResult
    { syncedCounts :: M.Map Metric Int
    , syncErrors   :: M.Map Metric Text
    } deriving (Show, Eq)
```

「sleep は成功して 30 行、readiness は 401 で失敗」という**部分的失敗**を表現しています。1 つのメトリックが失敗しても他は続行するのが仕様なので、例外を最後まで飛ばすわけにはいきません。`runSync` は例外を投げず、必ず `SyncResult` を返します。

呼び出し側はそれを使って終了コードを決めます。

```haskell
-- src/DailySync.hs:83
return $ if M.null (syncErrors result)
         then ExitSuccess
         else ExitFailure 1
```

### `try` の重要な性質

ClassyPrelude が re-export する `try` は `UnliftIO.Exception` のものです。

```
try :: (MonadUnliftIO m, Exception e) => m a -> m (Either e a)
```

標準の `Control.Exception.try` との違いは、**非同期例外を捕まえない**ことです。タイムアウトやスレッドのキャンセルは通り抜けます。これは実務上とても重要な性質で、「`try` したせいでタイムアウトが効かなくなる」事故を防ぎます。

`tryOura` の `try` は型注釈がありませんが、直後の `case` で `OuraError` のパターンにマッチさせているため、GHC が `e ~ OuraError` と推論します。**捕まえる例外の型を絞る**ことも重要です。`SomeException` で捕まえると、次節の事故が起きます。

## 4.4 実例: `SomeException` を握り潰していたバグ

移植当初、リクエストボディの JSON パースはこう書かれていました。

```haskell
-- Before（コミット 1d698e2 以前）
-- | Run a handler that may fail JSON parsing, falling back to a default
-- (mirrors Python's @request.get_json(silent=True) or {}@).
parseBodyOr :: Handler a -> a -> Handler a
parseBodyOr action def = action `catch` (\(_ :: SomeException) -> return def)
```

Python の `request.get_json(silent=True) or {}` を素直に移したものです。動きます。テストも通ります。しかし **`SomeException` はすべての例外を含みます**。

- ボディが壊れている → 捕まえたい（意図どおり）
- DB のコネクションが切れた → 捕まえたくない
- タイムアウトでスレッドが中断された → **絶対に捕まえてはいけない**
- Yesod が内部制御に使う例外（`sendStatusJSON` の脱出など） → 捕まえたら動作が壊れる

修正後はこうなりました。

```haskell
-- src/Handler/Api.hs:145
-- | The request body decoded as JSON, or an empty object when it is missing,
-- not JSON, or malformed (Python's @request.get_json(silent=True) or {}@).
--
-- 'parseCheckJsonBody' reports those failures in its result, so "silent" stays
-- scoped to a parse failure. The @catch \@SomeException@ this replaces also
-- swallowed unrelated exceptions, including async ones.
jsonBodyOrEmpty :: Handler Value
jsonBodyOrEmpty = do
    result <- parseCheckJsonBody
    return $ case result of
        A.Success v -> v
        A.Error _   -> A.object []
```

`parseCheckJsonBody :: (MonadHandler m, FromJSON a) => m (Result a)` は、失敗を例外ではなく **戻り値の `Result`** で返します。つまり例外処理そのものが不要になりました。

**教訓は 3 つ。**

1. `catch`/`try` で `SomeException` を指定するのは、ほぼ常に誤り。捕まえたい例外の型を書く。
2. 例外を捕まえる前に、**そもそも例外を投げない API がないか**を探す。あればそちらが正しい。
3. 他言語からの移植では「例外の粒度」が一致しないことが多い。Python の `except Exception` と Haskell の `SomeException` は、含まれる範囲が違う（Haskell の方が広く、非同期例外まで含む）。

この修正のテストも一緒に入っています。「壊れた JSON」「ボディ無し」「Content-Type が違う」の 3 ケースで、変更前と同じ 401 が返ることを固定しました。

```haskell
-- test/AppSpec.hs:51
-- A body that cannot be parsed is treated as {} (no password), the way
-- Flask's get_json(silent=True) did, rather than surfacing as a 500.
it "login with malformed JSON returns 401" $ do
    request $ do
        setMethod "POST"
        setUrl LoginR
        setRequestBody "{not json"
        addRequestHeader ("Content-Type", "application/json")
    statusIs 401
```

**振る舞いを変えないリファクタリングでは、変えないことをテストで固定してから直す。** これは Haskell に限らない話ですが、型が変わらないリファクタリング（例外処理の書き換え）ではコンパイラが助けてくれないので、特に重要です。

## 4.5 `error` を使ってよい場所・いけない場所

`DateText.hs` には対照的な 2 つの関数があります。

```haskell
-- src/DateText.hs:47
-- | Accept a @YYYY-MM-DD@ string from outside the app (a URL segment, a query
-- parameter). Shape-only, matching the @re.fullmatch@ the Python app used.
parseDayText :: Text -> Maybe DayText
parseDayText t = case T.splitOn "-" t of
    [y, m, d] | T.length y == 4 && T.length m == 2 && T.length d == 2
              , all (T.all isDigit) [y, m, d] -> Just (DayText t)
    _ -> Nothing
```

```haskell
-- src/DateText.hs:55
-- | Parse to a 'Day' for calendar arithmetic. Every date reaching this point
-- is either read back from the DB or produced by 'formatDay', so a parse
-- failure is a bug rather than untrusted input.
parseDay :: DayText -> Day
parseDay (DayText t) =
    fromMaybe (error ("invalid date: " <> unpack t))
              (parseTimeM True defaultTimeLocale dayFormat (unpack t))
```

- `parseDayText` は **外部入力用**。失敗は正常な事象なので `Maybe`。
- `parseDay` は **内部用**。「ここに届く日付は DB か `formatDay` 由来だから、壊れていたらプログラムのバグ」という前提で `error`。

この使い分け自体は正しい設計です。`parseDay` を `Maybe Day` にすると、暦計算のたびに `Maybe` を開く羽目になり、本質的でないノイズが増えます。

**ただし、この前提は守られなければ意味がありません。** 実際には `postSyncR` に穴があります。

```haskell
-- src/Handler/Api.hs:105
let field k = DayText <$> (jsonText =<< jsonLookup k body)
```

リクエストボディの `"end"` を、`parseDayText` の検証を通さずに `DayText` へ包んでいます。この値は心拍同期の経路で `addDaysT` → `parseDay` に届くため、`{"end": "1999-13-45"}`（形は正しいが暦として無効）を送ると `error` で 500 になります。

つまり **「内部用だから `error` でよい」は、内部に入る入口をすべて検証している場合にのみ成立する** ということです。`DayText` のコンストラクタが公開されている（第 2 章 2.6）ため、検証を飛ばして作れてしまうのが根本原因です。これは第 13 章の演習 1 で直します。

### `error` を書くときのチェックリスト

- [ ] この値の出どころを全部列挙できるか
- [ ] そのすべてで検証済みだと言えるか
- [ ] 言えないなら `Maybe`/`Either` にするか、入口に検証を足す
- [ ] `error` のメッセージに、原因を特定できる情報（実際の値）が入っているか

`parseDay` は最後の項目は満たしています（`"invalid date: " <> unpack t`）。落ちたときにログを見れば原因が分かる、というのは最低限の礼儀です。

## 4.6 Yesod ハンドラでの脱出

Handler 層では、失敗はしばしば「途中で応答を返して終わる」形になります。

```haskell
-- src/Foundation.hs:179
requireAuth :: Handler ()
requireAuth = do
    authed <- isAuthenticated
    unless authed $
        sendStatusJSON status401 (A.object ["error" A..= ("Unauthorized" :: Text)])
```

`sendStatusJSON` の型は次のとおりです。

```
sendStatusJSON :: (MonadHandler m, ToJSON c) => Status -> c -> m a
```

戻り値が `m a`（任意の型）であることに注目してください。「何にでもなれる」型は、**この関数から戻ってこない**ことを意味します（内部で制御用の例外を投げて Yesod のフレームワークが捕まえる）。だから次のような書き方ができます。

```haskell
-- src/Handler/Advice.hs:86
day <- maybe (sendStatusJSON status400
                (A.object ["error" A..= ("Invalid date format" :: Text)]))
             return
             (parseDayText raw)
-- ここに来た時点で day :: DayText は検証済み
```

`maybe` の「失敗時」の分岐が `Handler DayText` として型が合うのは、`sendStatusJSON` が `m a` を返すからです。**返り値の型が `m a` の関数を見たら「脱出する」と読む** ——これは Haskell のコードを読むときの重要なサインです。

同じ形は `postLoginR` の設定不備チェックにも使われています。

```haskell
-- src/Handler/Api.hs:41
when (null stored) $
    sendStatusJSON status500 (A.object ["error" A..= ("APP_PASSWORD not configured" :: Text)])
```

## 4.7 起動時失敗は潔く落とす

設定不備は、リクエストを待たずに起動時に落とすのが正解です。

```haskell
-- src/Application.hs:64
-- SECRET_KEY is mandatory (mirrors the Python app raising at startup).
when (null $ appSecretKey appSettings) $
    error "SECRET_KEY environment variable is not set"
```

ここでは `error` が適切です。「セッション鍵が無い状態で起動したサーバー」は存在してはいけないので、`Maybe App` を返して呼び出し側に判断させる意味がありません。**フェイルファスト**（早く、大きく失敗する）は、静かな誤動作よりずっと良い。

一方、ログファイルが開けない場合は落としません。

```haskell
-- src/Logging.hs:31
-- Logging must never take the process down: if the directory or file cannot be
-- opened we report the reason on stderr once and fall back to stdout, rather
-- than failing startup.
```

「ログが書けないこと」はアプリの本質的機能を止める理由になりません。**何が致命的で何がそうでないかは、機能の重要度で決める**という判断が、コメント付きで残されています。

## 4.8 この章のまとめ

| 状況 | このプロジェクトの選択 |
|---|---|
| JSON のキーが無い | `Maybe`（`Json.hs`） |
| 未知のメトリック名 | `Maybe` → Handler で 400 に翻訳 |
| 外部から来た日付文字列 | `Maybe`（`parseDayText`） |
| 内部で持ち回る日付の暦変換 | `error`（前提付き。穴あり） |
| HTTP API の失敗 | 例外 `OuraError` → `tryOura` で `Either` に変換 |
| メトリック単位の部分失敗 | `SyncResult` に値として集計 |
| リクエストボディのパース失敗 | `Result` を見て既定値（例外を使わない） |
| 認証失敗・不正な引数 | `sendStatusJSON`（`m a` で脱出） |
| 起動時の設定不備 | `error` で即死 |
| ログファイルが開けない | stderr に警告して stdout へフォールバック |

- 失敗表現は層をまたぐたびに翻訳する。境界を 1 箇所に固定する（`tryOura`）。
- `SomeException` を捕まえない。捕まえる型を書く。
- 例外を捕まえる前に、例外を投げない API を探す。
- `error` は「入口を全部検証している」と言い切れるときだけ。

## 演習

1. `Oura.httpGet`（`src/Oura.hs:95`）は `try (httpJSON req)` で `HttpException` を捕まえ、`OuraError` に変換しています。なぜ `HttpException` をそのまま上に投げないのでしょうか。`Sync.tryOura` の実装を踏まえて説明してください。

2. `getPaged`（`src/Oura.hs:81`）で HTTP 失敗が起きたとき、それまでに取得したページ（`acc`）はどうなりますか。この挙動は望ましいですか。望ましくないとしたら、どう直しますか。

3. `runAdviceJob`（`src/Advice.hs:171`）は `try` で `IOException` だけを捕まえています。`claude` コマンドが存在しない場合以外に、この `try` が捕まえる可能性のある状況を挙げてください。捕まえ損ねる失敗はありますか。
