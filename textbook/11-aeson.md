# 第 11 章 aeson で緩い JSON を扱う

> **この章で復習する文法**: `Value` の 6 コンストラクタ、`A.object` と `.=`、`FromJSON` の手書き（`withObject`、`.:`、`.:?`、`.!=`）、`RecordWildCards` による構築、`CPP`、型注釈が必要になる場面

Haskell の JSON といえば「型を定義して `deriving (FromJSON, ToJSON)`」が定番です。しかしこのプロジェクトはほとんどそれをしません。**外部 API のペイロードを、型付けせずに `Value` のまま扱っています。**

これは怠慢でしょうか。それとも合理的な判断でしょうか。理由を検討しながら、aeson の実践的な使い方を見ていきます。

## 11.1 なぜ型を作らないのか

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

`data_json` カラムに丸ごと入れ、API 応答時にはそれをそのまま返します。つまり **アプリはペイロードの全構造を理解する必要がない**。理解するのは「スコアがどのフィールドか」だけです（`extractScore`）。

この状況で全フィールドの型を定義すると、

- Oura がフィールドを追加するたびに型を更新する必要がある
- 使わないフィールドの型定義を保守するコストがかかる
- 型 → JSON の往復で情報が変わりうる（バイト互換が壊れる）

**「自分が使うフィールドだけを取り出し、残りは触らない」** という方針が、この場合は正しい判断です。

> **一般則**: 自分が所有するデータ（設定、内部 API、DB スキーマ）は型を作る。他人が所有し、変化しうるデータ（外部 API のペイロード）は必要な部分だけ取り出す。

## 11.2 `Value` の形とアクセサの集約

### 文法メモ: `Value` の 6 コンストラクタ

```haskell
data Value
    = Object Object      -- KeyMap Value（aeson 2.x）
    | Array  Array       -- Vector Value
    | String Text
    | Number Scientific  -- 任意精度。Double とは限らない
    | Bool   Bool
    | Null
```

**JSON の値は 6 通りしかありません。** だからパターンマッチで完全に扱えます。

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

### 数値は `Scientific`

`Number` の中身は `Scientific`（任意精度）です。`Double` ではありません。だから使う側で意味に応じて変換します。

- `realToFrac n` → `Double`（スコア）
- `round n` → 整数（心拍数）

`jsonInt :: Integral a => Value -> Maybe a` の戻り値が多相なのは第 5 章で見たとおりで、呼び出し側の文脈で `Int` にも `Integer` にもなります。

## 11.3 JSON を組み立てる

読み取りは `Value` のままですが、**書き出しは型付きの API を使います**。

```haskell
-- src/Db.hs:134
return [ A.object ["timestamp" A..= (ts :: Text), "bpm" A..= (bpm :: Int)]
       | (Single ts, Single bpm) <- rows ]
```

### 文法メモ: `object` と `.=`

```
object :: [Pair] -> Value
(.=)   :: (KeyValue e kv, ToJSON v) => Key -> v -> kv
```

`"bpm" A..= bpm` は「キーと、`ToJSON` できる値」からペアを作ります。`A.object` がそれらをオブジェクトにまとめます。

`(ts :: Text)` という型注釈は、`rawSql` の結果型を確定させるために必要です（`Single a` の `a` が他から決まらない）。**型が決まらないというコンパイルエラーが出たら、まず `rawSql` の結果を疑う**のが定石です（第 12 章）。

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

### `Map` はそのまま JSON になる

```haskell
-- src/Handler/Api.hs:68
byMetric <- runDB $ M.fromList <$>
    forM metrics (\m ->
        (,) (dailyMetricName m) <$> Db.getDailyMetrics m range)
returnJson byMetric
```

`Map Text [Value]` は `ToJSON` のインスタンスを持ち、JSON オブジェクトになります。わざわざ `A.object` を組み立てる必要はありません。

同じ手が sync 結果でも使われています。

```haskell
-- src/Handler/Api.hs:124
syncResultToJson :: Sync.SyncResult -> Value
syncResultToJson r = A.object
    [ "synced" A..= M.mapKeys metricName (Sync.syncedCounts r)
    , "errors" A..= M.mapKeys metricName (Sync.syncErrors r)
    ]
```

内部は `Map Metric Int` ですが、**JSON に出す直前に `M.mapKeys metricName` でキーを文字列に変換**しています。ここが型の世界と外部契約の境界です。第 3 章で「文字列を型にする」と言いましたが、**外に出る瞬間には文字列に戻す**——その変換点を 1 箇所に集めるのが要点でした。

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

`KM.insert` は上書きします。Python の `{**data, "day": ..., "score": ...}` と同じ「後勝ち」を再現しており、**コメントで対応関係を明記**しています。移植プロジェクトでは、こう書いておくと後から挙動を照合できます。

ここで `A.toJSON day` が `DayText` を JSON にしています。第 4 章で `deriving newtype (ToJSON)` を選んだ効果です。`ToJSON` は GHC の stock 導出（`Eq`/`Show`/`Generic` などの組み込み一覧）には含まれないクラスなので、もし代わりに `anyclass`（`DeriveAnyClass`、aeson の `Generic` ベースのデフォルト実装）で導出していたら `{"unDayText": "2024-01-01"}` という余計な入れ子になり、**API のバイト互換が壊れていました**。

## 11.4 人間・LLM に見せる JSON

```haskell
-- src/Advice.hs:136
buildAdvicePrompt :: A.Value -> Text
buildAdvicePrompt healthData =
    adviceSystemPrompt <> "\n\n```json\n" <> prettyJson <> "\n```"
  where
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }
```

API 応答には `A.encode`（コンパクト）、人間や LLM が読むものには `aeson-pretty` の `encodePretty'`、と使い分けています。

`decodeUtf8` の後に `TL.toStrict` があるのは、`encodePretty'` が遅延 `ByteString` を返すためです。**`ByteString`／`Text` の遅延・正格が絡む典型的な場面**で、ClassyPrelude の `decodeUtf8` が多相なのでこの連鎖が素直に書けています。

## 11.5 自分の構造には型を書く — `FromJSON` の手書き

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

### 文法メモ: パーサの演算子

| 演算子 | 意味 |
|---|---|
| `withObject "名前" $ \o -> ...` | オブジェクトであることを要求し、失敗時のメッセージに名前を使う |
| `o .: "k"` | 必須フィールド。無ければパース失敗 |
| `o .:? "k"` | 省略可能。無ければ `Nothing` |
| `.!=` | `Maybe` に既定値を与える |

`parseJSON` の中の `do` は `Parser` モナドです（`IO` ではありません。第 6 章の「`do` は IO 専用ではない」の実例です）。

**なぜ `Generic` による自動導出でなく手書きなのか。** 次の 1 行が答えです。

```haskell
appShouldLogAll <- o .:? "should-log-all" .!= dev
```

「明示指定があればそれ、無ければ開発モードかどうかで決まる」という**条件付きの既定値**は、自動導出では表現できません。

### 文法メモ: `CPP`

```haskell
let defaultDev =
#ifdef DEVELOPMENT
        True
#else
        False
#endif
```

C プリプロセッサです（`{-# LANGUAGE CPP #-}` が必要）。`package.yaml:65` で、dev フラグ時に `cpp-options: -DDEVELOPMENT` が渡されます。**ビルド構成で挙動を変える**ための仕組みですが、多用すると読みにくくなります。ここでは 1 箇所だけに限定されており、妥当な使い方です。

### `RecordWildCards` による組み立て

```haskell
return AppSettings {..}
```

第 4 章で見た `{..}` です。フィールドが 20 個あるとき、`AppSettings { appStaticDir = appStaticDir, ... }` と書くのは苦行です。**大きな設定レコードで特に効きます。**

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

## 11.6 パース結果を値で受け取る

第 7 章でも見た `jsonBodyOrEmpty` は、aeson の `Result` 型の使い方の例でもあります。

```haskell
-- src/Handler/Api.hs:145
jsonBodyOrEmpty :: Handler Value
jsonBodyOrEmpty = do
    result <- parseCheckJsonBody
    return $ case result of
        A.Success v -> v
        A.Error _   -> A.object []
```

`parseCheckJsonBody :: (MonadHandler m, FromJSON a) => m (Result a)` の `a` は、ここでは `Value` に決まります（戻り値が `Handler Value` なので）。**`Value` を要求すれば「JSON として妥当なら何でも受ける」**という意味になります。型で「どこまで信用するか」を選んでいるわけです。

## 11.7 この章のまとめ

- 他人が所有する JSON（外部 API）は、必要なフィールドだけ `Value` から取り出す。全構造の型定義は保守負債になる。
- 自分が所有する構造（設定、内部 API 応答）は型を作る。条件付き既定値が要るなら `FromJSON` を手書きする。
- `Value` を掘るアクセサは 1 モジュールに集約する（`Json.hs`）。ライブラリの都合（aeson 2.x の `Key`）もそこに閉じる。
- 書き出しは `A.object` と `.=`。`Map` は `ToJSON` があるのでそのまま渡せる。
- 内部の型を外に出す瞬間に文字列へ変換する（`M.mapKeys metricName`）。変換点を集約する。
- `newtype` の `ToJSON` は `deriving newtype` にしないと JSON の形が壊れる。
- `RecordWildCards` は大きなレコードの組み立てで有効。`CPP` はビルド構成による分岐を 1 箇所に閉じ込めて使う。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `Object` / `Array` / `String` / `Number` / `Bool` / `Null` | `Value` の全コンストラクタ | `Json.hs` |
| `A.object [k .= v]` | オブジェクトの構築 | `Db.hs`, `Handler/*.hs` |
| `withObject "T" $ \o -> ...` | オブジェクトを要求するパーサ | `FromJSON AppSettings` |
| `o .: "k"` / `o .:? "k"` / `.!=` | 必須／省略可／既定値 | `Settings.hs` |
| `Parser` モナドの `do` | IO でない `do` | `parseJSON` |
| `R {..}` | `RecordWildCards` による構築 | `AppSettings {..}` |
| `#ifdef` / `#else` / `#endif` | `CPP` による分岐 | `defaultDev` |
| `(x :: Text)` | 型が決まらないときの注釈 | `rawSql` の結果 |
