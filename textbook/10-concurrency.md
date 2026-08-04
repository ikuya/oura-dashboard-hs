# 第 10 章 並行処理とリソース管理

アドバイス生成は `claude` CLI を呼ぶため、数十秒かかります。HTTP リクエストの中で待つわけにはいかないので、非同期ジョブにしています。

```
POST /api/advice   → ジョブ ID を発行して 202 を即返す
                     裏でワーカーが走る
GET  /api/advice/{id} → まだなら 202、完了なら 200、失敗なら 502
```

この仕組みを題材に、Haskell の並行処理の実務的な使い方を見ます。

## 10.1 共有状態は `TVar` に置く

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

-- src/Advice.hs:149
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

### なぜ `MVar` や `IORef` でなく `TVar` か

| 型 | 特徴 |
|---|---|
| `IORef` | 単純な可変参照。アトミックな更新は `atomicModifyIORef'` のみ |
| `MVar` | ロック的。取り出すと空になる。デッドロックしうる |
| `TVar` | STM。複数の変数への操作を 1 トランザクションに合成できる |

**STM の最大の利点は合成できること**です。「ジョブ A を完了にして、同時にジョブ B をキューに入れる」を 1 つの `atomically` にまとめれば、その間の中間状態を他のスレッドが観測できません。

現状のコードは単一の `TVar` しか使っていないので、`IORef` + `atomicModifyIORef'` でも同じことができます。しかし `TVar` を選んでおくと、将来「ジョブ数の上限を設けて、超えたら古いものを消す」といった複合操作を追加するときに自然に書けます。**将来の合成に備えるコストがほぼゼロ**なので、共有状態には `TVar` を既定にしてよいでしょう。

### `modifyTVar'` の `'`（正格版）

`modifyTVar` は関数適用を遅延させます。更新が積み重なると**サンクが溜まってメモリを食う**（スペースリーク）。`modifyTVar'` は適用結果を WHNF まで評価するので、その心配がありません。

**実務ルール**: `modifyTVar`、`atomicModifyIORef`、`foldl` などに正格版（`'` 付き）があるなら、既定でそちらを使う。遅延が欲しい理由が明確なときだけ非正格版にする。

なお `modifyTVar' jobs (M.insert jid job)` が評価するのは `Map` の構造までで、`AdviceJob` の中身（`jobAdvice :: Text` など）は遅延したままです。厳密にリークを避けたいならフィールドに `!` を付けます（`data AdviceJob = AdviceJob { jobAdvice :: !Text, ... }`）。アドバイス本文は数 KB なので実害はありませんが、**「正格版を使えば安心」ではない**ことは知っておくべきです。

### `atomically` と `readTVarIO`

```haskell
getJob jobs jid = M.lookup jid <$> readTVarIO jobs
```

読むだけなら `readTVarIO` の方が速い（トランザクションを開始しない）。`atomically (readTVar v)` と結果は同じですが、単発の読み取りには `readTVarIO` を使うのが慣例です。

## 10.2 ワーカーを起動する

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

**ここには意識すべき点が 4 つあります。**

**(1) Handler の文脈から出る。** フォークされたスレッドは Handler ではなく素の `IO` です。だから `runDB` が使えず、コネクションプールを渡して `runSqlPool` を自分で呼ぶ形になっています（第 5 章）。ログも `MonadLogger` が使えないので `AppLog` を渡しています（第 5 章）。

**「非同期にする」という決定が、ログと DB アクセスの設計まで波及している**——この因果関係を理解しておくと、`AppLog` が存在する理由が腑に落ちます。

**(2) 例外が握り潰される。** `forkIO` したスレッドで例外が飛ぶと、**そのスレッドが死ぬだけで、親には何も伝わりません**。デフォルトでは stderr にメッセージが出ますが、それだけです。

`runAdviceJob` は内部で `try` を使い、失敗をジョブ状態として記録するので、この経路では問題が表面化しません。しかし**もし `setJob` の前で例外が飛べば、ジョブは永久に `Queued` のまま**になります。ブラウザは 202 を返され続けます。

より堅牢にするには `async` パッケージの `withAsync` / `race` を使うか、`forkIO` したアクション全体を `try` で包んで最終的に必ずジョブ状態を確定させる（`finally` で「まだ Running なら Failed にする」）設計にします。

**(3) スレッドの寿命が管理されていない。** サーバーが停止するとき、走っているワーカーは中断されます。`claude` の子プロセスがどうなるかは環境依存です。個人用アプリなので許容されていますが、業務システムなら `bracket` でクリーンアップを保証すべきところです。

**(4) `-threaded` が必要。** `package.yaml:77` で `-threaded -rtsopts -with-rtsopts=-N` が指定されています。これがないと、`forkIO` したスレッドはあっても**同時に走る OS スレッドが 1 つ**しかなく、外部プロセスの待ち合わせなどでブロックが発生しえます。並行処理を使うなら必須の設定です。

## 10.3 タイムアウトと子プロセス

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

```haskell
proc "claude" [ "-p", unpack prompt, ... ]
```

`proc :: FilePath -> [String] -> CreateProcess` は、**コマンドと引数を別々に渡します**。シェルを起動しないので、プロンプト内にどんな文字（`;`、`|`、`` ` ``、`$()`）が入っていてもコマンドとして解釈されません。

対して `shell :: String -> CreateProcess` は文字列をシェルに渡すため、コマンドインジェクションの温床です。

**外部コマンドを起動するときは常に `proc` を使う。** これは Haskell に限らず、あらゆる言語で同じ原則です（Python なら `subprocess.run([...], shell=False)`）。

### 3 つの失敗パターンを網羅する

`case` の 4 分岐が、それぞれ異なる失敗を表しています。

| パターン | 意味 |
|---|---|
| `Left (_ :: IOException)` | プロセスを起動できなかった（コマンドが無い、実行権限が無い） |
| `Right Nothing` | 120 秒でタイムアウト |
| `Right (Just (ExitFailure _, _, err))` | 起動したが異常終了 |
| `Right (Just (ExitSuccess, out, _))` | 成功 |

`try` と `timeout` を入れ子にすることで、**戻り値の型が `Either IOException (Maybe (ExitCode, String, String))`** になり、失敗の種類が型で表現されています。パターンマッチで全部を列挙しているので、抜けがありません。

`(_ :: IOException)` の型注釈が必要なので、このモジュールには `{-# LANGUAGE ScopedTypeVariables #-}` が付いています（`src/Advice.hs:4`）。**捕まえる例外の型を絞る**という第 4 章の原則が、拡張の必要性として現れています。

### `timeout` はどちらの `timeout` か

```haskell
-- src/Advice.hs:26
import ClassyPrelude hiding (timeout)
...
import System.Timeout (timeout)
```

ClassyPrelude は `UnliftIO.Timeout.timeout :: MonadUnliftIO m => Int -> m a -> m (Maybe a)` を export します。ここでは `System.Timeout.timeout :: Int -> IO a -> IO (Maybe a)` を使うために hiding しています。

この関数は素の `IO` で動くので、どちらでも動作します。`hiding` して標準版を明示するのは、**「この処理は素の IO である」を読み手に伝える**効果もあります（第 7 章の `foldM` と同じ判断）。

**タイムアウトの実装原理も知っておく価値があります。** `timeout` は別スレッドから非同期例外を投げて中断させます。だから第 4 章で述べたとおり、`try @SomeException` で全例外を捕まえるコードがあると**タイムアウトが効かなくなります**。`UnliftIO` の `try` が非同期例外を通すのは、まさにこの事故を防ぐためです。

### 単位を間違えない

```haskell
timeout (120 * 1000000)     -- マイクロ秒 → 120 秒
```

```haskell
-- src/Oura.hs:55
apiTimeoutMicros :: Int
apiTimeoutMicros = 15 * 1000000
```

`Oura.hs` は名前に単位を入れています（`apiTimeoutMicros`）。`Advice.hs` はリテラル直書きです。**単位付きの名前を定数に付けるのは安いのに効果が大きい**ので、後者も倣うべきでしょう。

さらに徹底するなら `newtype Micros = Micros Int` や `Data.Time` の `DiffTime` を使う手もありますが、この規模では名前で十分です。

## 10.4 状態遷移を型で表す

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

第 2 章と同じパターンです。状態を文字列でなく型で持ち、外に出すときだけ文字列にします。

Handler 側の分岐も型で網羅されます。

```haskell
-- src/Handler/Advice.hs:70
case jobStatus job of
    Completed -> returnJson $ A.object (base ++ ["advice" A..= jobAdvice job])
    Failed    -> sendStatusJSON status502 $
        A.object (base ++ ["error" A..= fromMaybe "" (jobError job)])
    _         -> sendStatusJSON status202 (A.object base)
```

ここでは `_` で `Queued` と `Running` をまとめています。第 2 章では「ADT にワイルドカードを使うな」と述べましたが、**この `_` は妥当**です。理由は「完了・失敗以外はすべて『まだ処理中』として 202 を返す」という規則が、状態が増えても変わらないから。**規則が状態に依存しない場合は `_` でよい**、という判断です。

### 型で防げていないこと

現在の型は、次の不整合を許してしまいます。

- `jobStatus = Completed` なのに `jobAdvice = ""`
- `jobStatus = Failed` なのに `jobError = Nothing`
- `jobStatus = Queued` なのに `jobAdvice` に何か入っている

「illegal states unrepresentable（不正な状態を表現できなくする）」を徹底するなら、こう書きます。

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

**なぜ現状こうなっていないか**は、移植元の Python の dict 構造をそのまま写したためでしょう。移植の第一段階としては妥当ですが、**Haskell に落ち着いた後は型を締める**のが次のステップです（第 13 章の演習）。

## 10.5 メモリが増え続ける問題

```haskell
-- src/Advice.hs:159
setJob jobs jid f = atomically $ modifyTVar' jobs (M.adjust f jid)
```

ジョブを**追加する**関数はありますが、**削除する**関数がありません。`TVar (Map Text AdviceJob)` は単調に増え続けます。

1 日 1 回アドバイスを生成する個人用アプリなら、1 年で 365 エントリ、各数 KB。実害はありません。しかし**設計としては欠陥**です。長時間稼働するプロセスで無制限に増えるコレクションは、いずれ問題になります。

対処法は 3 つ。

1. **TTL 付き削除**: 完了から N 分経ったジョブを消す。読み取り時（`getJob`）か、定期タスクで掃除する。
2. **件数上限**: 挿入時に古いものから捨てる（LRU 的）。
3. **永続化**: ジョブ状態も DB に置く。プロセス再起動でも生き残る利点があるが、複雑になる。

このアプリなら 1 が妥当です。第 13 章の演習 3 で実装します。

なお、**ジョブがメモリ上にしかない**こと自体は意図的です。

```haskell
-- src/Advice.hs:6
-- Jobs live in an in-process 'TVar' map (mirroring the Lock-guarded _advice_jobs
-- dict) and run in a 'forkIO' worker that shells out to the @claude@ CLI. Jobs
-- are non-persistent: they vanish on restart, exactly like the Python app.
```

再起動でジョブが消えても、**生成済みのアドバイスは `advice_history` テーブルに残る**ので、ユーザーは履歴から読めます。「揮発してよいもの」と「永続すべきもの」が分けられているのは良い設計です。

## 10.6 この章のまとめ

- 共有可変状態は `TVar` に置く。将来の合成に備えられる。`modifyTVar'`（正格版）を既定にする。
- 読み取りだけなら `readTVarIO`。
- `forkIO` は Handler の文脈から出る。DB とログの渡し方が設計に波及する。
- `forkIO` した例外は親に伝わらない。ジョブ状態を必ず確定させる仕組みが要る。
- 並行処理を使うなら `-threaded`。
- 外部コマンドは `proc`（配列）で起動する。`shell`（文字列）は使わない。
- `try` と `timeout` の入れ子で、失敗の種類が型に現れる。全パターンを列挙する。
- タイムアウトは非同期例外で実装されている。`SomeException` を捕まえると壊れる。
- 時間の定数には単位を名前に入れる。
- 状態は文字列でなく ADT。さらに「状態ごとに付随データが違う」なら、コンストラクタに持たせる。
- 無制限に増えるコレクションは、規模が小さくても設計上の欠陥として認識しておく。

## 演習

1. `runAdviceJob` を `finally` で包み、「関数を抜けるときにジョブが `Running` のままなら `Failed` にする」という保険を追加してください。どの例外経路がこれで救われますか。`UnliftIO.Exception.finally` と `Control.Exception.finally` のどちらを使いますか。

2. `AdviceJob` を 10.4 節の `JobState` 版に書き換えてください。`Handler/Advice.hs` と `test/AppSpec.hs:215`（`insertJob`）はどう変わりますか。書き換え中にコンパイラが指摘した箇所を列挙し、それぞれが本当にバグの温床だったかを判定してください。

3. `claude` CLI が 120 秒以上かかった場合、`timeout` が中断した後、子プロセスはどうなりますか。GHCi または小さなテストプログラムで確認してください（`sleep 300` を起動して 2 秒でタイムアウトさせ、`ps` で確認）。ゾンビプロセスが残るなら、どう対処しますか。
