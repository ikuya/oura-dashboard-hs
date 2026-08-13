# 第 13 章 並行処理とリソース管理

> **この章で復習する文法**: `TVar` と STM（`atomically` / `modifyTVar'` / `readTVarIO`）、`forkIO`、`timeout`、`try` と `timeout` の入れ子で生まれる型、`ScopedTypeVariables`、`proc` による子プロセス起動、状態を表す ADT

アドバイス生成は `claude` CLI を呼ぶため、数十秒かかります。HTTP リクエストの中で待つわけにはいかないので、非同期ジョブにしています。

```
POST /api/advice      → ジョブ ID を発行して 202 を即返す。裏でワーカーが走る
GET  /api/advice/{id} → まだなら 202、完了なら 200、失敗なら 502
```

この仕組みを題材に、Haskell の並行処理の実務的な使い方を見ます。

## 13.1 共有状態は `TVar` に置く

```haskell
-- src/Advice.hs:60
data AdviceJob = AdviceJob
    { jobId     :: Text
    , jobStatus :: JobStatus
    , jobPeriod :: A.Value
    , jobAdvice :: Text
    , jobError  :: Maybe Text
    }

type AdviceJobs = TVar (M.Map Text AdviceJob)
```

`TVar`（Transactional Variable）は STM（Software Transactional Memory）の可変変数です。複数スレッドから安全に読み書きできます。

```haskell
-- src/Advice.hs:145
newAdviceJobs :: IO AdviceJobs
newAdviceJobs = newTVarIO M.empty

createAdviceJob :: AdviceJobs -> A.Value -> IO Text
createAdviceJob jobs period = do
    jid <- UUID.toText <$> UUID.nextRandom
    let job = AdviceJob jid Queued period "" Nothing
    atomically $ modifyTVar' jobs (M.insert jid job)
    return jid

getJob :: AdviceJobs -> Text -> IO (Maybe AdviceJob)
getJob jobs jid = M.lookup jid <$> readTVarIO jobs

setJob :: AdviceJobs -> Text -> (AdviceJob -> AdviceJob) -> IO ()
setJob jobs jid f = atomically $ modifyTVar' jobs (M.adjust f jid)
```

### 文法メモ: STM の型

```
modifyTVar' :: TVar a -> (a -> a) -> STM ()
atomically  :: STM a -> IO a
readTVarIO  :: MonadIO m => TVar a -> m a
```

**`STM` は `IO` とは別のモナドです。** `STM` の中では「トランザクション的に安全な操作」しかできません（ファイル書き込みも HTTP もできない）。だから GHC は、そのトランザクションを安全にやり直せます。`atomically` が `STM` を `IO` に変換する唯一の出口です。

「更新関数を渡す」形（`modifyTVar' v f`）になっているのは、第 4 章で見たレコード更新構文と噛み合います。

```haskell
setJob jobs jid (\j -> j { jobStatus = Running })
```

### なぜ `MVar` や `IORef` でなく `TVar` か

| 型 | 特徴 |
|---|---|
| `IORef` | 単純な可変参照。アトミックな更新は `atomicModifyIORef'` のみ |
| `MVar` | ロック的。取り出すと空になる。デッドロックしうる |
| `TVar` | STM。複数の変数への操作を 1 トランザクションに合成できる |

**STM の最大の利点は合成できること**です。「ジョブ A を完了にして、同時にジョブ B をキューに入れる」を 1 つの `atomically` にまとめれば、その間の中間状態を他のスレッドが観測できません。

現状のコードは単一の `TVar` しか使っていないので、`IORef` + `atomicModifyIORef'` でも同じことができます。しかし `TVar` を選んでおくと、将来「ジョブ数の上限を設けて超えたら古いものを消す」といった複合操作を追加するときに自然に書けます。**将来の合成に備えるコストがほぼゼロ**なので、共有状態には `TVar` を既定にしてよいでしょう。

読むだけなら `readTVarIO` の方が速い（トランザクションを開始しない）。`atomically (readTVar v)` と結果は同じですが、単発の読み取りには `readTVarIO` を使うのが慣例です。

### `modifyTVar'` の `'`

第 9 章で触れたとおり、`modifyTVar` は関数適用を遅延させ、サンクが溜まります。`modifyTVar'` は適用結果を WHNF まで評価します。**正格版があるなら既定でそちらを使う。**

ただし `modifyTVar' jobs (M.insert jid job)` が評価するのは `Map` の構造までで、`AdviceJob` の中身（`jobAdvice :: Text`）は遅延したままです。厳密にリークを避けたいならフィールドに `!` を付けます。アドバイス本文は数 KB なので実害はありませんが、**「正格版を使えば安心」ではない**ことは知っておくべきです。

## 13.2 ワーカーを起動する

```haskell
-- src/Handler/Advice.hs:44
-- Fork the worker; it saves to advice_history on success via runDB.
pool <- appConnPool <$> getYesod
liftIO $ void $ forkIO $
    Advice.runAdviceJob (appPlainLogger app) (appAdviceJobs app) jid prompt
        (saveAdviceIO pool)

sendStatusJSON status202 (A.object ["job_id" A..= jid, "status" A..= ("queued" :: Text)])
```

`forkIO :: IO () -> IO ThreadId` で軽量スレッドを起動し、戻り値を `void` で捨てて、すぐ 202 を返します。

**意識すべき点が 4 つあります。**

**(1) Handler の文脈から出る。** フォークされたスレッドは Handler ではなく素の `IO` です。だから `runDB` が使えず、コネクションプールを渡して `runSqlPool` を自分で呼ぶ形になっています（第 8 章）。ログも `MonadLogger` が使えないので `AppLog` を渡しています。

**「非同期にする」という決定が、ログと DB アクセスの設計まで波及している**——この因果関係を理解しておくと、`AppLog` が存在する理由が腑に落ちます。

**(2) 例外が握り潰される。** `forkIO` したスレッドで例外が飛ぶと、**そのスレッドが死ぬだけで、親には何も伝わりません**。

`runAdviceJob` は内部で `try` を使い、失敗をジョブ状態として記録するので、この経路では問題が表面化しません。しかし**もし `setJob` の前で例外が飛べば、ジョブは永久に `Queued` のまま**になり、ブラウザは 202 を返され続けます。

より堅牢にするなら、`async` パッケージの `withAsync` / `race` を使うか、フォークしたアクション全体を `finally` で包んで「まだ `Running` なら `Failed` にする」保険を入れます。

**(3) スレッドの寿命が管理されていない。** サーバーが停止するとき、走っているワーカーは中断されます。個人用アプリなので許容されていますが、業務システムなら `bracket` でクリーンアップを保証すべきところです。

**(4) `-threaded` が必要。** `package.yaml:77` で `-threaded -rtsopts -with-rtsopts=-N` が指定されています。これがないと OS スレッドが 1 つしかなく、外部プロセスの待ち合わせなどでブロックが発生しえます。並行処理を使うなら必須の設定です。

## 13.3 タイムアウトと子プロセス

```haskell
-- src/Advice.hs:171
runAdviceJob appLog jobs jid prompt saveAdvice' = do
    setJob jobs jid (\j -> j { jobStatus = Running })
    writeLog appLog LevelInfo ("advice job " <> jid <> " started")
    started <- getCurrentTime
    let cp = proc "claude"
            [ "-p", unpack prompt, "--max-turns", "1", "--model", "opus"
            , "--append-system-prompt", appendSystemPrompt ]
    result <- try (timeout (120 * 1000000) (readCreateProcessWithExitCode cp ""))
    case result of
        Left (_ :: IOException) ->
            fail' "claude コマンドが見つかりません。Claude Code がインストールされているか確認してください。"
        Right Nothing ->
            fail' "分析がタイムアウトしました。"
        Right (Just (ExitFailure _, _, err)) ->
            fail' (if null err then "Claude Code の実行に失敗しました。" else pack err)
        Right (Just (ExitSuccess, out, _)) -> do
            ...
```

### `proc` を使う（シェルを経由しない）

`proc :: FilePath -> [String] -> CreateProcess` は、**コマンドと引数を別々に渡します**。シェルを起動しないので、プロンプト内にどんな文字（`;`、`|`、`` ` ``、`$()`）が入っていてもコマンドとして解釈されません。

対して `shell :: String -> CreateProcess` は文字列をシェルに渡すため、コマンドインジェクションの温床です。

**外部コマンドを起動するときは常に `proc` を使う。** これは Haskell に限らず、あらゆる言語で同じ原則です（Python なら `subprocess.run([...], shell=False)`）。

### 失敗の種類が型に現れる

`try` と `timeout` を入れ子にすると、戻り値の型は

```haskell
Either IOException (Maybe (ExitCode, String, String))
```

になります。4 分岐がそれぞれ異なる失敗を表します。

| パターン | 意味 |
|---|---|
| `Left (_ :: IOException)` | プロセスを起動できなかった（コマンドが無い、実行権限が無い） |
| `Right Nothing` | 120 秒でタイムアウト |
| `Right (Just (ExitFailure _, _, err))` | 起動したが異常終了 |
| `Right (Just (ExitSuccess, out, _))` | 成功 |

**型を組み合わせるだけで失敗の分類ができています。** パターンマッチで全部を列挙しているので、抜けもありません。

`(_ :: IOException)` の型注釈のために `{-# LANGUAGE ScopedTypeVariables #-}` が必要です（`src/Advice.hs:4`）。**捕まえる例外の型を絞る**という第 7 章の原則が、拡張の必要性として現れています。

### どちらの `timeout` か

```haskell
-- src/Advice.hs:26
import ClassyPrelude hiding (timeout)
...
import System.Timeout (timeout)
```

ClassyPrelude は `UnliftIO.Timeout.timeout :: MonadUnliftIO m => Int -> m a -> m (Maybe a)` を export します。ここでは `System.Timeout.timeout :: Int -> IO a -> IO (Maybe a)` を使うために hiding しています。

この処理は素の `IO` で動くのでどちらでも動作しますが、`hiding` して標準版を明示することには **「この処理は素の IO である」を読み手に伝える**効果があります（第 9 章の `foldM` と同じ判断）。

**タイムアウトの実装原理も知っておく価値があります。** `timeout` は別スレッドから非同期例外を投げて中断させます。だから第 7 章で述べたとおり、`try @SomeException` で全例外を捕まえるコードがあると**タイムアウトが効かなくなります**。`UnliftIO` の `try` が非同期例外を通すのは、まさにこの事故を防ぐためです。

### 単位を間違えない

```haskell
timeout (120 * 1000000)     -- マイクロ秒 → 120 秒
```

```haskell
-- src/Oura.hs:55
apiTimeoutMicros :: Int
apiTimeoutMicros = 15 * 1000000
```

`Oura.hs` は名前に単位を入れています（`apiTimeoutMicros`）。`Advice.hs` はリテラル直書きです。**単位付きの名前を定数に付けるのは安いのに効果が大きい**ので、後者も倣うべきでしょう。徹底するなら `newtype Micros = Micros Int` や `DiffTime` を使う手もありますが、この規模では名前で十分です。

## 13.4 状態遷移を型で表す

```haskell
-- src/Advice.hs:49
data JobStatus = Queued | Running | Completed | Failed
    deriving (Eq, Show)

statusText :: JobStatus -> Text
statusText Queued    = "queued"
statusText Running   = "running"
statusText Completed = "completed"
statusText Failed    = "failed"
```

第 3 章と同じパターンです。状態を文字列でなく型で持ち、外に出すときだけ文字列にします。Handler 側の分岐も型で行われます。

```haskell
-- src/Handler/Advice.hs:70
case jobStatus job of
    Completed -> returnJson $ A.object (base ++ ["advice" A..= jobAdvice job])
    Failed    -> sendStatusJSON status502 $
        A.object (base ++ ["error" A..= fromMaybe "" (jobError job)])
    _         -> sendStatusJSON status202 (A.object base)
```

### 型で防げていないこと

現在の型は、次の不整合を許してしまいます。

- `jobStatus = Completed` なのに `jobAdvice = ""`
- `jobStatus = Failed` なのに `jobError = Nothing`
- `jobStatus = Queued` なのに `jobAdvice` に何か入っている

「不正な状態を表現できなくする（make illegal states unrepresentable）」を徹底するなら、**状態ごとに付随データを持たせます**。

```haskell
data JobState
    = Queued
    | Running
    | Completed Text        -- アドバイス本文
    | Failed Text           -- エラーメッセージ

data AdviceJob = AdviceJob
    { jobId     :: Text
    , jobPeriod :: A.Value
    , jobState  :: JobState
    }
```

こうすると「完了なのに本文が無い」が**書けなく**なります。Handler の分岐も自然になります。

```haskell
case jobState job of
    Completed advice -> returnJson $ A.object (base ++ ["advice" A..= advice])
    Failed err       -> sendStatusJSON status502 (A.object (base ++ ["error" A..= err]))
    _                -> sendStatusJSON status202 (A.object base)
```

**なぜ現状こうなっていないか**は、移植元の Python の dict 構造をそのまま写したためでしょう。移植の第一段階としては妥当ですが、**Haskell に落ち着いた後は型を締める**のが次のステップです（第 16 章）。

## 13.5 増え続けるコレクション

```haskell
-- src/Advice.hs:159
setJob jobs jid f = atomically $ modifyTVar' jobs (M.adjust f jid)
```

ジョブを**追加する**関数はありますが、**削除する**関数がありません。`TVar (Map Text AdviceJob)` は単調に増え続けます。

1 日 1 回アドバイスを生成する個人用アプリなら、1 年で 365 エントリ、各数 KB。実害はありません。しかし**設計としては欠陥**です。長時間稼働するプロセスで無制限に増えるコレクションは、いずれ問題になります。

対処は 3 つ。

1. **TTL 付き削除**: 完了から N 分経ったジョブを消す。「増える契機（ジョブ作成時）に掃除する」と、掃除の頻度が増加の頻度に自動的に比例します。
2. **件数上限**: 挿入時に古いものから捨てる（LRU 的）。
3. **永続化**: ジョブ状態も DB に置く。再起動で生き残る利点があるが、複雑になる。

具体的な実装案は第 16 章で示します。

なお、**ジョブがメモリ上にしかない**こと自体は意図的です。

```haskell
-- src/Advice.hs:6
-- Jobs live in an in-process 'TVar' map (mirroring the Lock-guarded _advice_jobs
-- dict) and run in a 'forkIO' worker that shells out to the @claude@ CLI. Jobs
-- are non-persistent: they vanish on restart, exactly like the Python app.
```

再起動でジョブが消えても、**生成済みのアドバイスは `advice_history` テーブルに残る**ので、ユーザーは履歴から読めます。「揮発してよいもの」と「永続すべきもの」が分けられているのは良い設計です。

## 13.6 この章のまとめ

- 共有可変状態は `TVar` に置く。将来の合成に備えられる。`modifyTVar'`（正格版）を既定にする。
- `STM` は `IO` とは別のモナド。`atomically` が唯一の出口。読み取りだけなら `readTVarIO`。
- `forkIO` は Handler の文脈から出る。DB とログの渡し方が設計に波及する。
- `forkIO` した例外は親に伝わらない。ジョブ状態を必ず確定させる仕組み（`finally` など）が要る。
- 並行処理を使うなら `-threaded`。
- 外部コマンドは `proc`（配列）で起動する。`shell`（文字列）は使わない。
- `try` と `timeout` の入れ子で、失敗の種類が型に現れる。全パターンを列挙する。
- タイムアウトは非同期例外で実装されている。`SomeException` を捕まえると壊れる。
- 時間の定数には単位を名前に入れる。
- 状態は文字列でなく ADT。さらに「状態ごとに付随データが違う」なら、コンストラクタに持たせる。
- 無制限に増えるコレクションは、規模が小さくても設計上の欠陥として認識しておく。

### 文法チェックリスト

| 構文 | 意味 | 本章での実例 |
|---|---|---|
| `TVar a` / `newTVarIO` | STM の可変変数 | `AdviceJobs` |
| `atomically $ modifyTVar' v f` | トランザクションとして更新（正格） | `setJob` |
| `readTVarIO v` | 単発読み取り（トランザクション不要） | `getJob` |
| `forkIO act` / `void` | 軽量スレッドの起動と戻り値の破棄 | `postAdviceR` |
| `timeout micros act` | マイクロ秒指定のタイムアウト | `runAdviceJob` |
| `try (timeout ...)` | 失敗を型で分類 | `Either IOException (Maybe ...)` |
| `(_ :: IOException)` | 捕まえる例外型の指定 | `ScopedTypeVariables` |
| `proc "cmd" [args]` | シェルを経由しない子プロセス起動 | `claude` CLI |
| `data S = A \| B Text` | 状態ごとに付随データを持つ ADT | `JobState`（改善案） |
