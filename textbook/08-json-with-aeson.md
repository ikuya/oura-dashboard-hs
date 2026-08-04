# 第 8 章 aeson で緩い JSON を扱う

Haskell の JSON といえば「型を定義して `deriving (FromJSON, ToJSON)`」が定番です。しかしこのプロジェクトはほとんどそれをしません。**外部 API のペイロードを、型付けせずに `Value` のまま扱っています。**

これは怠慢でしょうか。それとも合理的な判断でしょうか。理由を検討しながら、aeson の実践的な使い方を見ていきます。

## 8.1 なぜ型を作らないのか

Oura API のレスポンスは、メトリックごとに構造が違います。`sleep` には `contributors` が入り、`spo2` には `spo2_percentage`（オブジェクトのこともスカラーのこともある）が入り、`resilience` には `level` という文字列が入る。しかもこのアプリが使うのは各レコードの**ごく一部のフィールドだけ**です。

さらに決定的なのは、**DB にレコード全体を JSON のまま保存している**ことです。

```haskell
-- src/Db.hs:47
upsertDailyMetric
    :: (MonadIO m)
    => DailyMetric -> DayText -> Maybe Double -> A.Value -> ReaderT SqlBackend m ()
upsertDailyMetric metric day score dataObj = do
    now <- nowIso
    let dataText = decodeUtf8 (toStrict (A.encode dataObj))
    rawExecute
        "INSERT OR REPLACE INTO daily_metrics (metric, day, score, data_json, synced_at) VALUES (?, ?, ?, ?, ?)"
        [...]
```

`data_json` カラムに丸ごと入れ、API 応答時にはそれをそのまま返します。つまり **アプリはペイロードの全構造を理解する必要がない**。理解する必要があるのは「スコアがどのフィールドか」だけです（`extractScore`）。

この状況で全フィールドの型を定義すると、

- Oura がフィールドを追加するたびに型を更新する必要がある（しないとデコードで落ちるか、情報が失われる）
- 使わないフィールドの型定義を保守するコストがかかる
- `data_json` に保存するとき、型 → JSON の往復で情報が変わりうる（バイト互換が壊れる）

**「自分が使うフィールドだけを取り出し、残りは触らない」** という方針が、この場合は正しい判断です。

一方、**自分が定義する構造**には型を使っています。`Settings.hs` の `AppSettings` がそれです（8.5 節）。

> 一般則: 自分が所有するデータ（設定、内部 API、DB スキーマ）は型を作る。他人が所有し、変化しうるデータ（外部 API のペイロード）は必要な部分だけ取り出す。

## 8.2 アクセサを 1 箇所にまとめる

方針が決まったら、`Value` を掘る道具を用意します。

```haskell
-- src/Json.hs:4
-- | Accessors for the loosely-typed JSON that flows through the app: Oura API
-- payloads and the @data_json@ blobs stored per row. The sync, advice and
-- handler layers all reach into those values, so the lookups live here once
-- instead of being re-spelled as nested @case@ expressions in every module.
module Json
    ( jsonLookup
    , jsonText
    , jsonDouble
    , jsonInt
    , jsonArray
    ) where
```

```haskell
-- src/Json.hs:22
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup k (Object o) = KM.lookup (K.fromText k) o
jsonLookup _ _          = Nothing

jsonText :: Value -> Maybe Text
jsonText (String t) = Just t
jsonText _          = Nothing

jsonDouble :: Value -> Maybe Double
jsonDouble (Number n) = Just (realToFrac n)
jsonDouble _          = Nothing

-- | A JSON number rounded to an integral type (bpm and friends).
jsonInt :: Integral a => Value -> Maybe a
jsonInt (Number n) = Just (round n)
jsonInt _          = Nothing

jsonArray :: Value -> Maybe [Value]
jsonArray (Array a) = Just (V.toList a)
jsonArray _         = Nothing
```

**42 行のモジュールですが、これがあるかないかで全体の読みやすさが変わります。** これがないと、各モジュールで次のような `case` が繰り返されます。

```haskell
-- Json.hs がない場合の惨状
case record of
    Object o -> case KM.lookup "day" o of
        Just (String t) -> Just t
        _               -> Nothing
    _ -> Nothing
```

`Json.hs` があれば 1 行です。

```haskell
-- src/Sync.hs:78
recordDay r = DayText <$> (jsonText =<< jsonLookup "day" r)
```

### aeson 2.x の `Key` / `KeyMap`

aeson 2.0 で、オブジェクトの表現が `HashMap Text Value` から `KeyMap Value` に変わりました（ハッシュ衝突 DoS 対策）。そのため `Text` のキーを使うには変換が要ります。

```haskell
KM.lookup (K.fromText k) o    -- Text -> Key
```

`jsonLookup` がこの変換を吸収しているので、**呼び出し側は `Key` の存在を知らずに済みます**。ライブラリの都合を 1 箇所に閉じ込める、という点でもこのモジュールは効いています。

### `jsonInt` の型に注目

```haskell
jsonInt :: Integral a => Value -> Maybe a
jsonInt (Number n) = Just (round n)
```

戻り値が多相です。呼び出し側の文脈で `Int` にも `Integer` にもなります。

```haskell
-- src/Sync.hs:290
toHrPair v =
    ( fromMaybe "" (jsonText =<< jsonLookup "timestamp" v)
    , jsonInt =<< jsonLookup "bpm" v      -- Maybe Int として使われる
    )
```

`Number` は `Scientific` 型（任意精度）なので、`round` で整数に落としています。**JSON の数値は浮動小数点とは限らない**というのが aeson の設計で、`realToFrac` / `round` / `floor` のどれを使うかは意味に応じて選びます。心拍数なら `round` が妥当です。

## 8.3 JSON を組み立てる

読み取りは `Value` のままですが、**書き出しは型付きの API を使います**。

```haskell
-- src/Db.hs:134
return [ A.object ["timestamp" A..= (ts :: Text), "bpm" A..= (bpm :: Int)]
       | (Single ts, Single bpm) <- rows ]
```

`A.object :: [Pair] -> Value` と `(.=) :: (KeyValue kv, ToJSON v) => Key -> v -> kv` の組み合わせが定番です。`(ts :: Text)` という型注釈は、`rawSql` の結果型を確定させるために必要です（`Single a` の `a` が何か、他から決まらない）。

`Handler` 層でも同じ形です。

```haskell
-- src/Handler/Advice.hs:94
Just entry -> returnJson $ A.object
    [ "advice"   A..= fromMaybe A.Null (jsonLookup "content" entry)
    , "period"   A..= A.object
        [ "start" A..= fromMaybe A.Null (jsonLookup "period_start" entry)
        , "end"   A..= fromMaybe A.Null (jsonLookup "period_end" entry) ]
    , "saved_at" A..= fromMaybe A.Null (jsonLookup "saved_at" entry)
    ]
```

`fromMaybe A.Null` で「無ければ `null`」にしています。JSON API の契約として「キーは常に存在し、値が `null` になりうる」形を選んだわけです。キー自体を落とす設計もありえますが、**フロントエンドが `data.period.start` を無条件に読める**方が扱いやすい。移植元の Python 版と互換を保つ意図もあります。

### `Map` をそのまま JSON にする

```haskell
-- src/Handler/Api.hs:68
byMetric <- runDB $ M.fromList <$>
    forM metrics (\m ->
        (,) (dailyMetricName m) <$> Db.getDailyMetrics m range)
returnJson byMetric
```

`Map Text [Value]` は `ToJSON` のインスタンスがあり、JSON オブジェクトになります。わざわざ `A.object` を組み立てる必要はありません。

同じ手が sync 結果でも使われています。

```haskell
-- src/Handler/Api.hs:124
syncResultToJson :: Sync.SyncResult -> Value
syncResultToJson r = A.object
    [ "synced" A..= M.mapKeys metricName (Sync.syncedCounts r)
    , "errors" A..= M.mapKeys metricName (Sync.syncErrors r)
    ]
```

内部は `Map Metric Int` ですが、**JSON に出す直前に `M.mapKeys metricName` でキーを文字列に変換**しています。ここが型の世界と外部契約の境界です。第 2 章で「文字列を型にする」と言いましたが、**外に出る瞬間には文字列に戻す**——その変換点を 1 箇所に集めるのが要点でした。

### 既存 JSON にフィールドを足す

```haskell
-- src/Db.hs:38
-- | Merge day/score onto the parsed data_json object. The DB @score@ column
-- takes precedence over any @score@ inside data_json (mirrors db.py's
-- @{**data, "day": ..., "score": ...}@).
mergeRow :: DayText -> Maybe Double -> A.Object -> A.Value
mergeRow day mscore o =
    A.Object $ KM.insert "score" (maybe A.Null A.toJSON mscore)
             $ KM.insert "day" (A.toJSON day) o
```

`KM.insert` は上書きします。Python の `{**data, "day": ..., "score": ...}` と同じ「後勝ち」を再現しており、**コメントで対応関係を明記**しています。移植プロジェクトでは、このように「元コードのどの行に対応するか」を書いておくと、後から挙動を照合できます。

ここで `A.toJSON day` が `DayText` を JSON にしています。第 2 章で `deriving newtype (ToJSON)` を選んだ効果です。もし `stock` で導出していたら、`{"unDayText": "2024-01-01"}` という余計な入れ子になり、**API のバイト互換が壊れていました**。

## 8.4 プリティプリント（LLM に渡す JSON）

```haskell
-- src/Advice.hs:136
buildAdvicePrompt :: A.Value -> Text
buildAdvicePrompt healthData =
    adviceSystemPrompt <> "\n\n```json\n" <> prettyJson <> "\n```"
  where
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }
```

`aeson-pretty` の `encodePretty'` で整形しています。API 応答には `A.encode`（コンパクト）、人間や LLM が読むものには `encodePretty'`、と使い分けています。

`decodeUtf8` の後に `TL.toStrict` があるのは、`encodePretty'` が `Lazy ByteString` を返すためです。`ByteString` → `Text` の変換で、遅延と正格が絡む典型的な場面です。ClassyPrelude の `decodeUtf8` は多相なので、この連鎖が素直に書けています。

## 8.5 自分の構造には型を書く — `FromJSON` の手書き

設定ファイルは自分が所有する構造なので、型を定義します。

```haskell
-- src/Settings.hs:81
instance FromJSON AppSettings where
    parseJSON = withObject "AppSettings" $ \o -> do
        let defaultDev =
#ifdef DEVELOPMENT
                True
#else
                False
#endif
        appStaticDir              <- o .: "static-dir"
        appDatabaseConf           <- o .: "database"
        appRoot                   <- o .:? "approot"
        ...
        dev                       <- o .:? "development"      .!= defaultDev
        appDetailedRequestLogging <- o .:? "detailed-logging" .!= dev
        ...
        return AppSettings {..}
```

`Generic` による自動導出ではなく手書きなのは、次の要求があるからです。

| 演算子 | 意味 |
|---|---|
| `.:` | 必須フィールド。無ければパース失敗 |
| `.:?` | 省略可能。無ければ `Nothing` |
| `.!=` | `Maybe` に既定値を与える |

自動導出では「開発モードなら既定値を変える」といった**条件付きの既定値**が書けません。

```haskell
appShouldLogAll <- o .:? "should-log-all" .!= dev
```

「明示指定があればそれ、無ければ開発モードかどうかで決まる」。この 1 行が自動導出では表現できないので、手書きを選んでいます。

### `RecordWildCards` による組み立て

```haskell
return AppSettings {..}
```

`RecordWildCards` 拡張で、**スコープにある同名の変数からレコードを組み立てます**。`appStaticDir <- ...` で束縛した変数が、そのままフィールドに入ります。

フィールドが 20 個あるとき、`AppSettings { appStaticDir = appStaticDir, appDatabaseConf = appDatabaseConf, ... }` と書くのは苦行です。この拡張は**大きな設定レコードで特に効きます**。

同じ拡張が `Application.hs` でも使われています。

```haskell
-- src/Application.hs:100
let mkFoundation appConnPool = App {..}
    -- The App {..} syntax is an example of record wild cards. For more
    -- information, see:
    -- https://ocharles.org.uk/blog/posts/2014-12-04-record-wildcards.html
```

**注意点**: `RecordWildCards` は変数名とフィールド名の一致に依存するため、名前を変えると静かに壊れる可能性があります（スコープに同名の別変数があると、そちらが使われる）。設定の組み立てのような限定的な場面で使うのが安全です。

### 「空文字列は未設定」の扱い

```haskell
-- src/Settings.hs:113
-- An unset LOG_FILE arrives as "", which means stdout.
logFile <- o .:? "log-file" .!= ""
let appLogFile = if null logFile then Nothing else Just logFile
```

環境変数経由だと「未設定」と「空文字列」の区別がつきません。そこで**パースの段階で `Maybe` に正規化**しています。この処理を後段（`Logging.newAppLoggerSet`）に押し付けず、境界で片付けているのが良い設計です。

もっとも `newAppLoggerSet` 側にも空文字列チェックが残っています。

```haskell
-- src/Logging.hs:37
newAppLoggerSet mpath = case mpath of
    Just path | not (null path) -> do ...
    _ -> stdoutSet
```

これは防御的な二重化です。「呼び出し側が正規化しているはず」に依存せず、自分でも確認する。ライブラリ的なモジュールでは妥当な判断です。

## 8.6 パース結果を値で受け取る

第 4 章でも見た `jsonBodyOrEmpty` は、aeson の `Result` 型の使い方の例でもあります。

```haskell
-- src/Handler/Api.hs:145
jsonBodyOrEmpty :: Handler Value
jsonBodyOrEmpty = do
    result <- parseCheckJsonBody
    return $ case result of
        A.Success v -> v
        A.Error _   -> A.object []
```

`Result a = Error String | Success a` は `Either String a` と同型です。aeson が独自の型を持っているのは歴史的経緯ですが、扱いは同じで、`case` で開けます。

`parseCheckJsonBody :: (MonadHandler m, FromJSON a) => m (Result a)` の `a` は、ここでは `Value` に決まります（戻り値が `Handler Value` なので）。**`Value` を要求すれば「JSON として妥当なら何でも受ける」**という意味になります。

## 8.7 この章のまとめ

- 他人が所有する JSON（外部 API）は、必要なフィールドだけ `Value` から取り出す。全構造の型定義は保守負債になる。
- 自分が所有する構造（設定、内部 API 応答）は型を作る。条件付き既定値が要るなら `FromJSON` を手書きする。
- `Value` を掘るアクセサは 1 モジュールに集約する（`Json.hs`）。ライブラリの都合（aeson 2.x の `Key`）もそこに閉じる。
- 書き出しは `A.object` と `.=`。`Map` は `ToJSON` があるのでそのまま渡せる。
- 内部の型を外に出す瞬間に文字列へ変換する（`M.mapKeys metricName`）。変換点を集約する。
- `newtype` の `ToJSON` は `deriving newtype` にしないと JSON の形が壊れる。
- `RecordWildCards` は大きなレコードの組み立てで有効。ただし名前一致に依存する点に注意。

## 演習

1. `Json.hs` に `jsonBool :: Value -> Maybe Bool` と `jsonObject :: Value -> Maybe A.Object` を追加してください。どちらか一方は「実際には使われないので追加すべきでない」という判断もありえます。YAGNI の観点から論じてください。

2. `extractScore` は `Maybe Value` を返し、呼び出し側で `jsonDouble =<< extractScore metric r` としています（`src/Sync.hs:115`）。`extractScore :: DailyMetric -> Value -> Maybe Double` に変えるとどうなりますか。`Resilience` の実装（`A.Number . fromIntegral <$> ...`）はどう変わりますか。どちらが良いですか。

3. Oura API の `daily_sleep` レコードに対して、**使っているフィールドだけ**の型 `data SleepRecord = SleepRecord { srDay :: DayText, srScore :: Maybe Double }` と `FromJSON` インスタンスを書いてください。`data_json` にレコード全体を保存するという要件と両立させるには、どういう構造にする必要がありますか。
