# 第 4 章 newtype とレコード

← [第3章 代数的データ型と網羅性](03-adt-and-exhaustiveness.md) | [目次](README.md) | [第5章 型クラスと制約](05-typeclasses.md) →

> **この章で復習する文法**: `newtype` と `data` と `type` の違い、レコード構文とフィールドアクセサ、レコード更新構文、`deriving stock` / `newtype` / `anyclass`（`DerivingStrategies`）、`RecordWildCards`

第 3 章では「種類が違うもの」を型で分けました。この章では、**同じ `Text` なのに意味が違うもの**を分ける方法と、複数の値をまとめる方法を扱います。

## 目次

- [4.1 `newtype` — コスト 0 で別の型を作る](#41-newtype-コスト-0-で別の型を作る)
  - [文法メモ: `newtype` / `data` / `type` の違い](#文法メモ-newtype-data-type-の違い)
- [4.2 `deriving` 戦略を明示する](#42-deriving-戦略を明示する)
  - [`Ord` に意味を持たせる](#ord-に意味を持たせる)
  - [`IsString` を導出する意味](#isstring-を導出する意味)
- [4.3 レコード — 名前でフィールドを区別する](#43-レコード-名前でフィールドを区別する)
  - [文法メモ: レコード構文](#文法メモ-レコード構文)
  - [フィールドが関数でもよい](#フィールドが関数でもよい)
- [4.4 レコード更新構文](#44-レコード更新構文)
- [4.5 大きなレコードと `RecordWildCards`](#45-大きなレコードと-recordwildcards)
- [4.6 型で守れないところを見極める](#46-型で守れないところを見極める)
- [4.7 この章のまとめ](#47-この章のまとめ)
  - [文法チェックリスト](#文法チェックリスト)

## 4.1 `newtype` — コスト 0 で別の型を作る

日付も、型化前は生の `Text` でした。`YYYY-MM-DD` 形式の文字列です。

```haskell
-- src/DateText.hs:29
-- | A calendar day as the @YYYY-MM-DD@ string the DB and both APIs speak.
--
-- 'Ord' is the underlying text order, which for this format is chronological —
-- the sync layer compares and takes @min@/@max@ of days throughout.
newtype DayText = DayText { unDayText :: Text }
    deriving stock   (Show)
    deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)
```

### 文法メモ: `newtype` / `data` / `type` の違い

| 宣言 | 実行時の表現 | 型検査上 |
|---|---|---|
| `type A = Text` | `Text` そのもの | **同じ型**（ただの別名） |
| `newtype A = A Text` | `Text` そのもの（ラッパは消える） | **別の型** |
| `data A = A Text` | ボックス 1 段分のオーバーヘッド | 別の型 |

`newtype` は「フィールドが 1 つだけの `data`」に制限される代わりに、コンパイル後は中身の型と同一表現になります。**実行時コスト 0 で型検査だけを厳しくできる**ので、こういう用途には常に `newtype` を選びます。

`type` では効果がありません。`type DayText = Text` と書いても、`Text` を要求する場所に何でも渡せてしまいます。

```haskell
-- newtype なら型エラーになる（DayText が要求される箇所に生の Text を渡した）
findMissingRange "2024-01-31" (Daily Sleep) someRandomText
```

`{ unDayText :: Text }` はレコード構文で、**取り出す関数 `unDayText :: DayText -> Text` が自動で定義されます**。`un〜` という命名は「包みを開ける関数」の慣習です。

## 4.2 `deriving` 戦略を明示する

```haskell
    deriving stock   (Show)
    deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)
```

`DerivingStrategies` 拡張で、インスタンスの導出方法を選べます。

| 戦略 | 意味 |
|---|---|
| `stock` | GHC 組み込みの導出（`Show`、`Eq`、`Ord`、`Enum` などの決まった一覧のみ） |
| `newtype` | 中身の型のインスタンスをそのまま流用（`GeneralizedNewtypeDeriving`） |
| `anyclass` | 空のインスタンスを生成し、クラスの既定実装（`Generic` ベースなど）に任せる（`DeriveAnyClass`） |

ここでの選択は意図的です。

- `Show` は **stock**。`DayText {unDayText = "2024-01-01"}` と表示され、テストの失敗メッセージで newtype であることが分かります（`newtype` 戦略にすると `"2024-01-01"` としか出ず、生の `Text` と区別がつきません）。
- `Eq`、`Ord`、`ToJSON`、`PersistField` は **newtype**。`Text` としての振る舞いをそのまま使いたい。特に JSON に出るときは `"2024-01-01"` という裸の文字列であってほしい。

なお `ToJSON` は stock では導出**できません**（`deriving stock (ToJSON)` は「`ToJSON` is not a stock derivable class」というコンパイルエラーになります。stock は上の表のとおり組み込み一覧限定です）。危険なのは `anyclass` 側です。`deriving anyclass (ToJSON)` は aeson の `Generic` ベースの既定実装による空インスタンスを作り、レコードのフィールド名がそのまま出て `{"unDayText": "2024-01-01"}` という出力になります——**JSON API のバイト互換が壊れます**。しかも `GeneralizedNewtypeDeriving` と `DeriveAnyClass` が両方有効なモジュールで戦略を書かずに `deriving (ToJSON)` とすると、**GHC は anyclass を優先します**（`-Wderiving-defaults` の警告付き）。この `DateText.hs` は `DeriveAnyClass` を有効にしていないので今すぐ事故が起きるわけではありませんが、拡張を 1 つ足しただけで導出結果が静かに変わる余地は残ります。newtype に何をどう導出させるかは外部との契約（JSON の形、DB の値）に直結するので、その余地を塞ぐためにも戦略を明示する価値があります。

### `Ord` に意味を持たせる

`YYYY-MM-DD` は**辞書順＝日付順**になる形式なので、`Text` の `Ord` をそのまま流用すれば日付比較になります。おかげで同期ロジックが `Day` への変換なしで書けます。

```haskell
-- src/Sync.hs:91 付近
let end = min requestedEnd today
...
    fetchStart = min refetchStart nextDay
in return $ if fetchStart > end then Nothing else Just (DateRange fetchStart end)
```

**この判断はコメントで根拠を残すべき類のものです。** 形式が変われば（例: `2024/1/5`）静かに壊れるからです。実際、型定義の Haddock に明記されています（4.1 の引用部）。

### `IsString` を導出する意味

```haskell
deriving newtype (..., IsString, ...)
```

`OverloadedStrings` 拡張下で、`IsString` のインスタンスがある型は文字列リテラルから直接作れます。だからテストがこう書けます。

```haskell
-- test/SyncSpec.hs:75
r <- runMem $ findMissingRange "2024-01-31" (Daily Sleep) "2024-01-31"
r `shouldBe` Just (DateRange defaultStart "2024-01-31")
```

`DayText "2024-01-31"` と書かずに済むので、テストが読みやすくなります。**代償は「検証を通さずに `DayText` を作れる」ことで**、それが第 16 章で扱う既知の弱点につながります。型の厳しさと記述量のトレードオフを、このプロジェクトは記述量側に倒したわけです。

## 4.3 レコード — 名前でフィールドを区別する

```haskell
-- src/DateText.hs:37
-- | An inclusive day range. Every fetch window and backfill gap is one; as a
-- record rather than a pair, the ends cannot be swapped by accident.
data DateRange = DateRange
    { rangeStart :: DayText
    , rangeEnd   :: DayText
    } deriving (Eq, Show)
```

### 文法メモ: レコード構文

`data T = T { f1 :: A, f2 :: B }` と書くと、次が同時に定義されます。

- コンストラクタ `T :: A -> B -> T`（位置引数でも作れる）
- アクセサ関数 `f1 :: T -> A`、`f2 :: T -> B`
- 構築時のフィールド指定 `T { f1 = x, f2 = y }`
- パターンマッチ `T { f1 = x }`（一部だけ書ける）
- 更新構文 `t { f1 = x }`

このコードベースは、同じ型を場面によって使い分けています。

```haskell
-- 位置引数で構築（短い）
--   src/Sync.hs:93
return $ Just (DateRange defaultStart end)

-- パターンで分解
--   src/Db.hs:96
getDailyMetrics metric (DateRange start end) = do ...

-- アクセサで取り出す
--   src/Sync.hs:259
let covered r = any (\b -> rangeStart b <= rangeStart r
                        && rangeEnd b >= rangeEnd r) backfill
```

`(DayText, DayText)` というタプルでも動きますが、`fetch (end, start)` と書いても型が合ってしまいます。**名前付きレコードなら、少なくともアクセサを使う場面で取り違えが目に見えます。**

さらに `DateRange` が独立した型であることで、こういうシグネチャが書けます。

```haskell
-- src/Oura.hs:41
data OuraClient = OuraClient
    { getDailySleep     :: DateRange -> IO [Value]
    , getDailyReadiness :: DateRange -> IO [Value]
    ...
```

タプルだったら `(DayText, DayText) -> IO [Value]` になり、読み手に意味が伝わりません。**型は名前でもある**、というのがこの節の要点です。

### フィールドが関数でもよい

`OuraClient` は「9 個の関数を持つレコード」です。Haskell では関数も値なので、フィールドに置けます。これが第 10 章で扱う依存性注入の土台になります。

```haskell
-- src/Logging.hs:61
newtype AppLog = AppLog { writeLog :: LogLevel -> Text -> IO () }
```

`AppLog` に至っては、フィールドが 1 つの関数だけです。「ログの書き出し口」という**能力を値として持ち回る**ために newtype で包んでいます。生の `LogLevel -> Text -> IO ()` のままでも動きますが、型名が付いていることで引数リストでの意味が明らかになります。

## 4.4 レコード更新構文

```haskell
-- test/SyncSpec.hs:53
-- | A client whose sleep fetch raises an OuraError.
erroringSleepClient :: OuraClient
erroringSleepClient =
    let base = stubClientPure
    in base { getDailySleep = \_ -> throwIO (OuraError (Just 401) "Unauthorized") }
```

`base { field = value }` は、指定フィールドだけ差し替えた**新しい値**を作ります（元の値は不変です）。「sleep の取得だけが失敗するクライアント」が 3 行で作れました。モックフレームワークの `when(...).thenThrow(...)` に相当することが、言語機能だけでできています。

同じ構文は、状態遷移の表現にも使われます。

```haskell
-- src/Advice.hs:172
setJob jobs jid (\j -> j { jobStatus = Running })

-- src/Advice.hs:188
setJob jobs jid (\j -> j { jobStatus = Completed, jobAdvice = adviceOut, jobError = Nothing })
```

`\j -> j { ... }` は「ジョブを受け取って、一部を書き換えたジョブを返す関数」です。**可変オブジェクトを書き換えるのではなく、更新関数を作って渡す**——この形が、次章以降で見る `modifyTVar'` や `M.adjust` と自然に噛み合います。

テストの環境構築にも出てきます。

```haskell
-- test/TestImport.hs:52
foundation0 <- makeFoundation settings
let foundation = foundation0 { appOuraClientOverride = mclient }
```

**本番と同じ初期化関数を通してから、1 フィールドだけ差し替える。** 初期化ロジックをテスト用に書き直さずに済むので、初期化そのものもテストの対象に入ります。

## 4.5 大きなレコードと `RecordWildCards`

フィールドが 19 個ある設定レコードを、逐一書くのは苦行です。

```haskell
-- src/Settings.hs:29
data AppSettings = AppSettings
    { appStaticDir              :: String
    , appDatabaseConf           :: SqliteConf
    , appRoot                   :: Maybe Text
    ...
    , appLogFile                :: Maybe FilePath
    , appAccessLogFile          :: Maybe FilePath
    }
```

```haskell
-- src/Settings.hs:122
        return AppSettings {..}
```

`RecordWildCards` 拡張の `{..}` は、**スコープにある同名の変数からレコードを組み立てます**。直前で `appStaticDir <- o .: "static-dir"` のように束縛した変数が、そのまま同名フィールドに入ります。

`Application.hs` にも同じ形があります。

```haskell
-- src/Application.hs:100
let mkFoundation appConnPool = App {..}
    -- The App {..} syntax is an example of record wild cards. For more
    -- information, see:
    -- https://ocharles.org.uk/blog/posts/2014-12-04-record-wildcards.html
```

`appHttpManager`、`appLogger`、`appStatic` などを `do` の中で順に作り、最後に `App {..}` でまとめています。フィールド 9 個分の `appLogger = appLogger,` を書かずに済みます。

**注意点**: `{..}` は変数名とフィールド名の一致に依存します。名前を変えると静かに壊れる（スコープに同名の別変数があれば、そちらが使われる）ので、**設定やファウンデーションの組み立てのような、閉じた場面で使うのが安全**です。逆方向（`f App{..} = ...` で全フィールドを一気に束縛する）はスコープが汚れやすいため、このプロジェクトでは使われていません。

## 4.6 型で守れないところを見極める

型化した後でも、次は防げていません。

- `DayText` はコンストラクタが公開されているので `DayText "banana"` と書ける。形式の保証は型ではなく `parseDayText` を呼ぶ規律に依存している。
- `DateRange` は `rangeStart <= rangeEnd` を保証しない。空範囲や逆転範囲を作れる。
- `AdviceJob` は「`Completed` なのに本文が空」という不整合を許す（第 13 章）。

**「どこまで型で守り、どこから規律に頼るか」は常にトレードオフです。** すべてを型で縛る（`DayText` を smart constructor 限定にする、`DateRange` を検証付き構築関数のみにする）と、テストコードでリテラルが書けなくなり、記述量が跳ね上がります。

このプロジェクトの選択は「基礎型は緩く、入口で検証する」でした。その規律が実際には守られていない箇所があり、それが既知のバグになっています（第 16 章）。**緩く作るなら、緩さの前提（＝入口が全部検証されていること）を明示的に管理しなければならない**、というのがここでの教訓です。

## 4.7 この章のまとめ

- 同じ `Text` でも意味が違うものは `newtype` で分ける。実行時コストは 0。
- `type` は別名にすぎず、型検査の役には立たない。
- `deriving stock` / `deriving newtype` を明示する。`ToJSON` や `PersistField` の導出方法は外部との契約に直結する。
- `Ord` を newtype で流用するときは、その順序が意味的に正しい根拠をコメントに書く。
- 2 つ以上の同型の値を渡すなら、タプルよりレコード。型名とフィールド名が読み手への説明になる。
- レコードのフィールドには関数を置ける。差し替え可能な「能力」の表現になる。
- レコード更新構文 `x { f = v }` は、テストのスタブ作成と状態遷移の両方で効く。
- 大きなレコードの組み立ては `RecordWildCards` が有効。ただし名前一致に依存する点に注意。
- 型で守れない不変条件は、どこで守っているかを明示する。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `newtype N = N T` | コスト 0 の別型 | `DayText`, `AppLog` |
| `type A = T` | 単なる別名（型検査の助けにならない） | `type AdviceJobs = TVar (...)` |
| `newtype N = N { unN :: T }` | 取り出し関数付き | `unDayText` |
| `data R = R { f :: A, g :: B }` | レコード構文（コンストラクタ＋アクセサ） | `DateRange`, `OuraClient` |
| `R { f = x }` | フィールド指定の構築 | `OuraClient { getDailySleep = ... }` |
| `r { f = x }` | レコード更新（新しい値を返す） | `base { getDailySleep = ... }` |
| `deriving stock (..)` | 組み込み導出 | `Show` |
| `deriving newtype (..)` | 中身の型のインスタンスを流用 | `Eq, Ord, ToJSON, PersistField` |
| `R {..}` | `RecordWildCards` による構築 | `AppSettings {..}`, `App {..}` |

---

← [第3章 代数的データ型と網羅性](03-adt-and-exhaustiveness.md) | [目次](README.md) | [第5章 型クラスと制約](05-typeclasses.md) →
