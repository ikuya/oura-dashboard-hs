# 第 5 章 型クラスと制約

← [第4章 newtype とレコード](04-newtype-and-records.md) | [目次](README.md) | [第6章 純粋な芯と効果の殻](06-pure-core-effect-shell.md) →

> **この章で復習する文法**: `class` / `instance` 宣言、既定実装、制約付きインスタンス、`InstanceSigs`、関連型（`type` インスタンス）、戻り値多相、`mempty` / `<>`、孤児インスタンスと `OPTIONS_GHC`

型クラスは「共通の操作を持つ型の集まり」を表します。Java の interface に似ていますが、**既存の型に後から付けられる**点と、**値ではなく型で実装が選ばれる**点が決定的に違います。

この章では、このプロジェクトに実在するインスタンス宣言を読みながら、型クラスの文法と実務的な使いどころを確認します。

## 目次

- [5.1 いちばん小さなインスタンス](#51-いちばん小さなインスタンス)
  - [文法メモ: `class` と `instance`](#文法メモ-class-と-instance)
- [5.2 メソッドで振る舞いを設定する — Yesod の流儀](#52-メソッドで振る舞いを設定する-yesod-の流儀)
  - [文法メモ: `InstanceSigs`](#文法メモ-instancesigs)
  - [関連型（associated type）](#関連型associated-type)
- [5.3 制約は「必要な能力」の宣言](#53-制約は必要な能力の宣言)
  - [戻り値の側が多相になることもある](#戻り値の側が多相になることもある)
- [5.4 インスタンスは「型」で選ばれる](#54-インスタンスは型で選ばれる)
- [5.5 よく出る型クラスの地図](#55-よく出る型クラスの地図)
  - [`mempty` の実例](#mempty-の実例)
- [5.6 孤児インスタンス](#56-孤児インスタンス)
  - [文法メモ: `OPTIONS_GHC` プラグマ](#文法メモ-options_ghc-プラグマ)
- [5.7 型クラスを自分で定義するか](#57-型クラスを自分で定義するか)
- [5.8 この章のまとめ](#58-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 5.1 いちばん小さなインスタンス

```haskell
-- src/Oura.hs:31
data OuraError = OuraError
    { ouraErrorStatus  :: Maybe Int
    , ouraErrorMessage :: Text
    } deriving (Show)

instance Exception OuraError
```

`instance Exception OuraError` は本体が空です。`Exception` クラスのメソッド（`toException` / `fromException` / `displayException`）はすべて**既定実装**を持っているので、`Show` と `Typeable` さえあれば何も書かずにインスタンスになれます。

この 1 行で `OuraError` は `throwIO` / `try` / `catch` に渡せるようになります。**型クラスは「この型はこの役割を果たせる」という宣言であり、宣言自体に実装が要るとは限りません。**

### 文法メモ: `class` と `instance`

```haskell
class Monad m => MonadLogger m where
    monadLoggerLog :: ToLogStr msg => Loc -> LogSource -> LogLevel -> msg -> m ()
```

- `class 制約 => クラス名 型変数 where` — 制約は「このクラスのインスタンスであるためには、まず `Monad` でなければならない」（スーパークラス）
- メソッドの型には自動的に `クラス名 型変数 =>` が付きます
- `where` 以下に既定実装を書けます

```haskell
instance FromJSON AppSettings where
    parseJSON = withObject "AppSettings" $ \o -> do
        ...
```

- `instance クラス名 具体型 where` — メソッドを定義します
- 定義しなかったメソッドは既定実装が使われます（既定がなければ実行時エラーになるので、`{-# MINIMAL #-}` プラグマで最低限の組を示すのが作法です）

## 5.2 メソッドで振る舞いを設定する — Yesod の流儀

Yesod は「フレームワークの設定を型クラスのメソッドで与える」設計です。

```haskell
-- src/Foundation.hs:79
instance Yesod App where
    approot :: Approot App
    approot = ApprootRequest $ \app req ->
        case appRoot $ appSettings app of
            Nothing   -> getApprootText guessApproot app req
            Just root -> root

    makeSessionBackend :: App -> IO (Maybe SessionBackend)
    makeSessionBackend _ = Just <$> defaultClientSessionBackend
        (7 * 24 * 60)    -- timeout in minutes (7 days)
        "config/client_session_key.aes"

    shouldLogIO :: App -> LogSource -> LogLevel -> IO Bool
    shouldLogIO app _source level =
        return $ appShouldLogAll (appSettings app) || level >= LevelInfo
```

`Yesod` クラスには数十のメソッドがあり、ほとんどに既定実装があります。**変えたいものだけ書く**わけです。設定ファイルではなく型クラスで与えるので、設定値が型検査を受けます（`makeSessionBackend` が `IO (Maybe SessionBackend)` を返さなければコンパイルが通りません）。

### 文法メモ: `InstanceSigs`

インスタンス定義のメソッドには、本来は型を書けません（クラス宣言で決まっているからです）。`{-# LANGUAGE InstanceSigs #-}`（`src/Foundation.hs:9`）を有効にすると書けるようになります。

上のコードで `approot :: Approot App` と明記しているのがそれです。**書く義務はないが、書くと読み手が助かります。** 既定メソッドが数十あるクラスでは、「このメソッドは何を受け取って何を返すのか」をいちいちドキュメントで調べずに済むからです。実務では有効化しておくことを勧めます。

### 関連型（associated type）

```haskell
-- src/Foundation.hs:142
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB :: SqlPersistT Handler a -> Handler a
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master
```

`type YesodPersistBackend App = SqlBackend` は**型族**（type family）のインスタンスです。「`App` に紐づく DB バックエンドは `SqlBackend` である」という**型レベルの対応表**を書いています。

これがあるおかげで、`runDB` の引数型 `SqlPersistT Handler a` がアプリごとに決まります。PostgreSQL を使うアプリなら別の型になります。`{-# LANGUAGE TypeFamilies #-}` が必要で、Yesod/persistent を使うモジュールにこの拡張が並ぶのはこのためです。

型族を自分で設計する機会は多くありませんが、**「フレームワークがなぜ `TypeFamilies` を要求するのか」を知っておくと、エラーメッセージが読めます。**

## 5.3 制約は「必要な能力」の宣言

```haskell
-- src/Db.hs:26
nowIso :: MonadIO m => m Text
nowIso = formatUtc <$> liftIO getCurrentTime
```

「`m` が何であれ、IO を実行できる（`MonadIO`）なら、この関数が使える」という意味です。`IO Text` と書くよりも使える場所が広くなります。この設計方針は第 8 章で詳しく扱います。

制約は複数書けます。

```haskell
-- src/Sync.hs:106
syncDailyMetric
    :: (MonadIO m, MonadLogger m)
    => OuraClient -> DailyMetric -> DateRange
    -> ReaderT SqlBackend m Int
```

「IO ができて、かつログが書ける」。**制約の一覧はその関数が何をしうるかの目録です。** `syncDailyMetric` を読むとき、実装を見なくても「例外処理はしていない」（`MonadUnliftIO` がない）と分かります。

### 戻り値の側が多相になることもある

```haskell
-- src/Json.hs:36
-- | A JSON number rounded to an integral type (bpm and friends).
jsonInt :: Integral a => Value -> Maybe a
jsonInt (Number n) = Just (round n)
jsonInt _          = Nothing
```

`a` は**呼び出し側の文脈で決まります**。心拍数を扱う箇所では `Maybe Int` として使われています。

```haskell
-- src/Sync.hs:290
toHrPair v =
    ( fromMaybe "" (jsonText =<< jsonLookup "timestamp" v)
    , jsonInt =<< jsonLookup "bpm" v      -- ここでは Maybe Int
    )
```

**戻り値が多相な関数は、型注釈が必要になる場面が増えます。** どこからも型が決まらないと「曖昧である」というエラーになります。`rawSql` がその典型で、第 12 章で扱います。

## 5.4 インスタンスは「型」で選ばれる

型クラスの解決は**型に対して**行われます。同じ型に 2 つの実装を与えることはできません（インスタンスは型ごとに 1 つ）。

これは長所でもあり制約でもあります。

```haskell
-- src/Db.hs:134 — Text と Int で .= の実装が自動的に選ばれる
A.object ["timestamp" A..= (ts :: Text), "bpm" A..= (bpm :: Int)]
```

「`Text` をどう JSON にするか」を毎回指定しなくてよいのは、`ToJSON Text` インスタンスが一意だからです。

一方、**「同じ型に対して別の振る舞いを使い分けたい」場合、型クラスは向きません。** 例えば「本番の Oura クライアント」と「テスト用スタブ」は同じ操作の別実装ですが、型クラスで表すとテストごとに新しい型を定義することになります。このプロジェクトが `OuraClient` を型クラスではなく**レコード**にしたのはそのためです（第 10 章で比較します）。

判断の目安:

| 状況 | 向いているもの |
|---|---|
| 型ごとに 1 つの自然な実装がある（`ToJSON`、`Ord`） | 型クラス |
| モナドの能力として全体に効かせたい（`MonadLogger`） | 型クラス |
| 実行時に実装を選ぶ／複数実装を同時に使う／一部だけ差し替える | 値（レコード） |

## 5.5 よく出る型クラスの地図

このコードベースに出てくるものだけを整理します。

| クラス | 主なメソッド | 実例 |
|---|---|---|
| `Eq` / `Ord` | `==`, `compare` | `Map Metric Int` のキー |
| `Show` | `show`（`tshow`） | ログ、テスト失敗表示 |
| `Semigroup` / `Monoid` | `<>`, `mempty` | 文字列連結、`return mempty` |
| `Functor` / `Applicative` / `Monad` | `<$>`, `<*>`, `>>=` | 第 2 章・第 6 章 |
| `Foldable`（ClassyPrelude では `MonoFoldable`） | `null`, `length`, `headMay` | `Text` にも `Map` にも効く |
| `IsString` | `fromString` | `"2024-01-31" :: DayText` |
| `Exception` | （既定実装） | `OuraError` |
| `ToJSON` / `FromJSON` | `toJSON`, `parseJSON` | 第 11 章 |
| `PersistField` / `PersistFieldSql` | DB 値との変換 | `DayText` を SQL パラメータに渡す |
| `MonadIO` / `MonadUnliftIO` / `MonadLogger` | `liftIO`, `withRunInIO` | 第 8 章 |

### `mempty` の実例

```haskell
-- src/Db.hs:108
getDailyMetricsBulk metrics (DateRange start end)
    | null metrics = return mempty
    | otherwise = do ...
```

戻り値は `Map DailyMetric [A.Value]` なので、`mempty` は空の `Map` です。`M.empty` と書いても同じですが、`mempty` なら**戻り値の型が変わっても書き換え不要**です。「単位元」という抽象で書けるところは抽象で書く、という小さな判断です。

## 5.6 孤児インスタンス

インスタンス宣言は本来、**クラスを定義したモジュールか、型を定義したモジュール**のどちらかに置きます。どちらでもない場所に書いたものを孤児インスタンス（orphan instance）と呼び、GHC が警告します。

```haskell
-- src/Application.hs:8
{-# OPTIONS_GHC -fno-warn-orphans #-}
```

`Application.hs` は `mkYesodDispatch "App" resourcesApp` によって `YesodDispatch App` インスタンスを生成しますが、`App` 型は `Foundation.hs` で定義されているため孤児になります。これは Yesod の scaffolding が意図的に選んだ構造（第 12 章で理由を説明します）なので、警告を抑制しています。

**孤児インスタンスの何が問題か。** 同じインスタンスが 2 つのモジュールで定義されると、どちらを import したかで挙動が変わり、しかも型検査では検出されません。だから通常は避けます。

**抑制してよい条件**は、(a) そのインスタンスが 1 箇所にしかないと言い切れる、(b) 理由がコード中に説明されている、の 2 つです。`{-# OPTIONS_GHC -fno-warn-orphans #-}` を書くときは、なぜ孤児になるのかをコメントで残してください。

### 文法メモ: `OPTIONS_GHC` プラグマ

`{-# LANGUAGE ... #-}` が言語拡張なのに対し、`{-# OPTIONS_GHC ... #-}` はコンパイラオプションをファイル単位で指定します。警告の抑制のほか、`-F -pgmF hspec-discover`（プリプロセッサ指定）もこの形です。

```haskell
-- test/Spec.hs（全 1 行）
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
```

## 5.7 型クラスを自分で定義するか

このプロジェクトは、**自前の型クラスを 1 つも定義していません**。すべて既存クラス（`Exception`、`FromJSON`、`Yesod`…）のインスタンスを書いているだけです。

これは規模相応の妥当な判断です。型クラスを自分で作る価値が出るのは、

- 同じ操作を複数の型に対して一様に呼びたい（`dailyMetricName` は 1 つの型にしか使わない）
- 呼び出し側に実装を明示的に渡したくない（このアプリは渡す方が素直だった）

といった場合です。**「抽象化のためにまず型クラスを作る」は、Haskell 初中級者が最も陥りやすい過剰設計**です。値（関数・レコード）で足りるなら値で書く。第 10 章で、その判断を具体的に検討します。

## 5.8 この章のまとめ

- 型クラスは「この型はこの役割を果たせる」の宣言。既定実装があるクラスなら本体は空でよい（`instance Exception OuraError`）。
- フレームワークの設定を型クラスのメソッドで与えるのが Yesod の流儀。`InstanceSigs` でメソッドに型を書くと読みやすい。
- 関連型（`type F A = B`）は型レベルの対応表。`TypeFamilies` が要求される理由。
- 制約は「必要な能力」の目録。少ないほど関数の意味が明確になる。
- インスタンスは型ごとに 1 つ。実行時に実装を選びたいなら型クラスではなく値を使う。
- 孤児インスタンスは避ける。抑制するなら理由を書く。
- 自前の型クラスを作る前に、値で足りないかを検討する。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `class C a where` | 型クラス宣言 | （既存クラスを使用） |
| `class D a => C a where` | スーパークラス制約 | `Monad m => MonadLogger m` |
| `instance C T` | 既定実装だけのインスタンス | `instance Exception OuraError` |
| `instance C T where ...` | メソッドを定義 | `instance Yesod App` |
| `InstanceSigs` | インスタンス内でメソッドの型を書く | `approot :: Approot App` |
| `type F T = U` | 関連型（型族）のインスタンス | `type YesodPersistBackend App = SqlBackend` |
| `f :: C a => ...` | 制約付きシグネチャ | `jsonInt :: Integral a => ...` |
| `mempty` / `<>` | `Monoid` の単位元と結合 | `return mempty` |
| `{-# OPTIONS_GHC -fno-warn-orphans #-}` | 孤児インスタンス警告の抑制 | `Application.hs` |

---

← [第4章 newtype とレコード](04-newtype-and-records.md) | [目次](README.md) | [第6章 純粋な芯と効果の殻](06-pure-core-effect-shell.md) →
