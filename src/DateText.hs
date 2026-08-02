{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | @YYYY-MM-DD@ text is the app's date currency: it is what the Oura API
-- takes, what the DB stores and what the JSON API returns. Keeping the format
-- string and the conversions here means every layer agrees on them.
module DateText
    ( DayText (..)
    , DateRange (..)
    , parseDayText
    , parseDay
    , formatDay
    , addDaysT
    , todayIn
    , todayUtc
    ) where

import ClassyPrelude
import Data.Aeson          (ToJSON)
import Data.Char           (isDigit)
import qualified Data.Text as T
import Data.Time.Calendar  (addDays)
import Data.Time.LocalTime (TimeZone, localDay, utc, utcToZonedTime,
                            zonedTimeToLocalTime)
import Database.Persist.Sql (PersistField, PersistFieldSql)

-- | A calendar day as the @YYYY-MM-DD@ string the DB and both APIs speak.
--
-- 'Ord' is the underlying text order, which for this format is chronological —
-- the sync layer compares and takes @min@/@max@ of days throughout.
newtype DayText = DayText { unDayText :: Text }
    deriving stock   (Show)
    deriving newtype (Eq, Ord, IsString, ToJSON, PersistField, PersistFieldSql)

-- | An inclusive day range. Every fetch window and backfill gap is one; as a
-- record rather than a pair, the ends cannot be swapped by accident.
data DateRange = DateRange
    { rangeStart :: DayText
    , rangeEnd   :: DayText
    } deriving (Eq, Show)

dayFormat :: String
dayFormat = "%Y-%m-%d"

-- | Accept a @YYYY-MM-DD@ string from outside the app (a URL segment, a query
-- parameter). Shape-only, matching the @re.fullmatch@ the Python app used.
parseDayText :: Text -> Maybe DayText
parseDayText t = case T.splitOn "-" t of
    [y, m, d] | T.length y == 4 && T.length m == 2 && T.length d == 2
              , all (T.all isDigit) [y, m, d] -> Just (DayText t)
    _ -> Nothing

-- | Parse to a 'Day' for calendar arithmetic. Every date reaching this point
-- is either read back from the DB or produced by 'formatDay', so a parse
-- failure is a bug rather than untrusted input.
parseDay :: DayText -> Day
parseDay (DayText t) =
    fromMaybe (error ("invalid date: " <> unpack t))
              (parseTimeM True defaultTimeLocale dayFormat (unpack t))

formatDay :: Day -> DayText
formatDay = DayText . pack . formatTime defaultTimeLocale dayFormat

-- | Shift a day by a number of days.
addDaysT :: Integer -> DayText -> DayText
addDaysT n = formatDay . addDays n . parseDay

-- | The current date in the given time zone.
todayIn :: MonadIO m => TimeZone -> m DayText
todayIn tz =
    formatDay . localDay . zonedTimeToLocalTime . utcToZonedTime tz
        <$> liftIO getCurrentTime

todayUtc :: MonadIO m => m DayText
todayUtc = todayIn utc
