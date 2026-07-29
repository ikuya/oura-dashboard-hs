{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | @YYYY-MM-DD@ text is the app's date currency: it is what the Oura API
-- takes, what the DB stores and what the JSON API returns. Keeping the format
-- string and the conversions here means every layer agrees on them.
module DateText
    ( parseDay
    , formatDay
    , addDaysT
    , todayIn
    , todayUtc
    ) where

import ClassyPrelude
import Data.Time.Calendar  (addDays)
import Data.Time.LocalTime (TimeZone, localDay, utc, utcToZonedTime,
                            zonedTimeToLocalTime)

dayFormat :: String
dayFormat = "%Y-%m-%d"

-- | Parse a @YYYY-MM-DD@ string. Every date reaching this point is either read
-- back from the DB or produced by 'formatDay', so a parse failure is a bug
-- rather than untrusted input.
parseDay :: Text -> Day
parseDay t =
    fromMaybe (error ("invalid date: " <> unpack t))
              (parseTimeM True defaultTimeLocale dayFormat (unpack t))

formatDay :: Day -> Text
formatDay = pack . formatTime defaultTimeLocale dayFormat

-- | Shift a @YYYY-MM-DD@ string by a number of days.
addDaysT :: Integer -> Text -> Text
addDaysT n = formatDay . addDays n . parseDay

-- | The current date in the given time zone.
todayIn :: MonadIO m => TimeZone -> m Text
todayIn tz =
    formatDay . localDay . zonedTimeToLocalTime . utcToZonedTime tz
        <$> liftIO getCurrentTime

todayUtc :: MonadIO m => m Text
todayUtc = todayIn utc
