{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Advice job logic, ported from app.py.
--
-- Jobs live in an in-process 'TVar' map (mirroring the Lock-guarded _advice_jobs
-- dict) and run in a 'forkIO' worker that shells out to the @claude@ CLI. Jobs
-- are non-persistent: they vanish on restart, exactly like the Python app.
module Advice
    ( AdviceJob (..)
    , JobStatus (..)
    , statusText
    , AdviceJobs
    , adviceSystemPrompt
    , dailyMetricsForAdvice
    , extractKeyFields
    , buildHealthPayload
    , buildAdvicePrompt
    , newAdviceJobs
    , createAdviceJob
    , getJob
    , runAdviceJob
    ) where

import ClassyPrelude hiding (timeout)
import qualified Data.Aeson          as A
import qualified Data.Aeson.Encode.Pretty as AP
import qualified Data.Aeson.Key      as K
import qualified Data.Aeson.KeyMap   as KM
import qualified Data.Map.Strict     as M
import qualified Data.Text.Lazy      as TL
import Data.Time.Calendar         (addDays)
import Database.Persist.Sql       (SqlBackend)
import System.Exit                (ExitCode (..))
import System.Process             (readCreateProcessWithExitCode, proc)
import System.Timeout             (timeout)
import qualified Data.UUID         as UUID
import qualified Data.UUID.V4      as UUID
import Control.Monad.Logger       (LogLevel (..))
import Data.Time.Clock            (diffUTCTime)

import Db
import Logging                    (logGlobal)

-- | Job lifecycle states.
data JobStatus = Queued | Running | Completed | Failed
    deriving (Eq, Show)

statusText :: JobStatus -> Text
statusText Queued    = "queued"
statusText Running   = "running"
statusText Completed = "completed"
statusText Failed    = "failed"

-- | A single advice job. @period@ is the {start,end,days} object.
data AdviceJob = AdviceJob
    { jobId     :: Text
    , jobStatus :: JobStatus
    , jobPeriod :: A.Value
    , jobAdvice :: Text
    , jobError  :: Maybe Text
    }

type AdviceJobs = TVar (M.Map Text AdviceJob)

-- | The metrics included in the advice payload (app.py DAILY_METRICS).
dailyMetricsForAdvice :: [Text]
dailyMetricsForAdvice =
    [ "sleep", "readiness", "activity", "stress", "spo2"
    , "resilience", "cardiovascular_age", "temperature" ]

adviceSystemPrompt :: Text
adviceSystemPrompt = intercalate "\n"
    [ "あなたはOura Ringの健康データを解析する専門家アシスタントです。"
    , "ユーザーから過去14日間のOura Ringデータ（睡眠、準備度、活動量、ストレス、血中酸素濃度、体温偏差、回復力、VO2 Max、心血管年齢）が提供されます。"
    , ""
    , "## 役割"
    , "1. データを客観的に分析し、現在の健康状態を簡潔に要約する"
    , "2. トレンドや注目すべき変化点を特定する"
    , "3. 実践的かつ具体的なアドバイスを提供する"
    , ""
    , "## 出力フォーマット"
    , "以下の構成で回答してください："
    , ""
    , "### 📊 現在の健康状態"
    , "（各メトリクスの直近の数値とトレンドを2〜3文でまとめる）"
    , ""
    , "### ⚠️ 注目ポイント"
    , "（気になる変化・改善が必要な項目を箇条書きで列挙。良い場合は「特になし」と記載）"
    , ""
    , "### 💡 アドバイス"
    , "（データに基づいた具体的な行動提案を3〜5項目の箇条書きで記載）"
    , ""
    , "---"
    , "- すべての回答は日本語で行うこと"
    , "- スコアの良し悪しの判断基準：80以上=良好（緑）、60〜79=普通（黄）、60未満=要注意（赤）"
    , "- 体温偏差は±0.5°C以内が正常範囲"
    , "- 医療的な診断は行わないこと"
    , ""
    ]

appendSystemPrompt :: String
appendSystemPrompt =
    "You are a health data analysis assistant. Output only the analysis report. No preamble, no self-explanation, no meta-commentary about the task."

-- | Extract the key fields from a metric row for the advice payload.
extractKeyFields :: Text -> A.Value -> A.Value
extractKeyFields metric row =
    let g k = fromMaybe A.Null (lookupJson k row)
        base = [("day", g "day"), ("score", g "score")]
        extra = case metric of
            "sleep"     -> [("contributors", g "contributors")]
            "readiness" -> [("contributors", g "contributors")]
            "activity"  -> [("active_calories", g "active_calories"), ("steps", g "steps")]
            "stress"    -> [("stress_high", g "stress_high"), ("recovery_high", g "recovery_high")]
            "spo2"      -> [("spo2_percentage", g "spo2_percentage")]
            "temperature" ->
                [ ("temperature_deviation", g "temperature_deviation")
                , ("temperature_trend_deviation", g "temperature_trend_deviation") ]
            "resilience" -> [("level", g "level")]
            "cardiovascular_age" -> [("vascular_age", g "vascular_age")]
            _ -> []
    in A.Object (KM.fromList (base ++ extra))

lookupJson :: Text -> A.Value -> Maybe A.Value
lookupJson k (A.Object o) = KM.lookup (K.fromText k) o
lookupJson _ _            = Nothing

-- | Build the 14-day health payload (period + per-metric key fields).
buildHealthPayload :: (MonadIO m) => Text -> Int -> ReaderT SqlBackend m A.Value
buildHealthPayload today days = do
    let start = tshowDay (addDays (negate (fromIntegral days - 1)) (parseDayT today))
    bulk <- getDailyMetricsBulk dailyMetricsForAdvice start today
    let metricsObj = KM.fromList
            [ (K.fromText m, A.toJSON (map (extractKeyFields m) (M.findWithDefault [] m bulk)))
            | m <- dailyMetricsForAdvice ]
        period = A.object ["start" A..= start, "end" A..= today, "days" A..= days]
    return $ A.object ["period" A..= period, "metrics" A..= A.Object metricsObj]

-- | Build the prompt string (system prompt + JSON code block).
buildAdvicePrompt :: A.Value -> Text
buildAdvicePrompt healthData =
    adviceSystemPrompt <> "\n\n```json\n" <> prettyJson <> "\n```"
  where
    prettyJson = TL.toStrict $ decodeUtf8 $ AP.encodePretty' cfg healthData
    cfg = AP.defConfig { AP.confIndent = AP.Spaces 2, AP.confTrailingNewline = False }

-- TVar job map -----------------------------------------------------------

newAdviceJobs :: IO AdviceJobs
newAdviceJobs = newTVarIO M.empty

-- | Create a queued job with a fresh UUID and return its id.
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

-- | Worker: run the claude CLI, update job state, and save advice on success.
-- @saveOnSuccess@ persists the advice to advice_history (period start/end).
runAdviceJob
    :: AdviceJobs
    -> Text                                   -- ^ job id
    -> Text                                   -- ^ prompt
    -> (Text -> Text -> Text -> IO ())        -- ^ save action: start end content
    -> IO ()
runAdviceJob jobs jid prompt saveAdvice' = do
    setJob jobs jid (\j -> j { jobStatus = Running })
    logGlobal LevelInfo ("advice job " <> jid <> " started")
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
            let adviceOut = pack out
            setJob jobs jid (\j -> j { jobStatus = Completed, jobAdvice = adviceOut, jobError = Nothing })
            elapsed <- elapsedSince started
            logGlobal LevelInfo
                ("advice job " <> jid <> " completed in " <> elapsed)
            -- Save to advice_history using the job's period.
            mjob <- getJob jobs jid
            case mjob >>= periodBounds . jobPeriod of
                Just (start, end) -> saveAdvice' start end adviceOut
                Nothing           -> return ()
  where
    -- The job state is only kept in a TVar, so without this a failed job is
    -- invisible outside the browser session that polled for it.
    fail' msg = do
        setJob jobs jid (\j -> j { jobStatus = Failed, jobError = Just msg })
        logGlobal LevelError ("advice job " <> jid <> " failed: " <> msg)

    elapsedSince t0 = do
        now <- getCurrentTime
        return (tshow (diffUTCTime now t0))
    periodBounds (A.Object o) = do
        A.String s <- KM.lookup "start" o
        A.String e <- KM.lookup "end" o
        return (s, e)
    periodBounds _ = Nothing

-- Date helpers -----------------------------------------------------------

parseDayT :: Text -> Day
parseDayT t = case parseTimeM True defaultTimeLocale "%Y-%m-%d" (unpack t) of
    Just d -> d; Nothing -> error ("bad date: " <> unpack t)

tshowDay :: Day -> Text
tshowDay = pack . formatTime defaultTimeLocale "%Y-%m-%d"
