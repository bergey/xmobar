{-# LANGUAGE CPP #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Plugins.Monitors.Weather
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Jose A. Ortega Ruiz <jao@gnu.org>
-- Stability   :  unstable
-- Portability :  unportable
--
-- A weather monitor for Xmobar
--
-----------------------------------------------------------------------------

module Plugins.Monitors.Weather where

import Plugins.Monitors.Common

import qualified Control.Exception as CE

#ifdef HTTP_CONDUIT
import Network.HTTP.Conduit
import Network.HTTP.Types.Status
import Network.HTTP.Types.Method
import qualified Data.ByteString.Lazy.Char8 as B
#else
import Network.HTTP
#endif

import Text.ParserCombinators.Parsec

weatherConfig :: IO MConfig
weatherConfig = mkMConfig
       "<station>: <tempC>C, rh <rh>% (<hour>)" -- template
       ["station"                               -- available replacements
       , "stationState"
       , "year"
       , "month"
       , "day"
       , "hour"
       , "windCardinal"
       , "windAzimuth"
       , "windMph"
       , "windKnots"
       , "windKmh"
       , "windMs"
       , "visibility"
       , "skyCondition"
       , "tempC"
       , "tempF"
       , "dewPointC"
       , "dewPointF"
       , "rh"
       , "pressure"
       ]

data WindInfo =
    WindInfo {
         windCardinal :: String -- cardinal direction
       , windAzimuth  :: String -- azimuth direction
       , windMph      :: String -- speed (MPH)
       , windKnots    :: String -- speed (knot)
       , windKmh      :: String -- speed (km/h)
       , windMs       :: String -- speed (m/s)
    } deriving (Show)

data WeatherInfo =
    WI { stationPlace :: String
       , stationState :: String
       , year         :: String
       , month        :: String
       , day          :: String
       , hour         :: String
       , windInfo     :: WindInfo
       , visibility   :: String
       , skyCondition :: String
       , tempC        :: Int
       , tempF        :: Int
       , dewPointC    :: Int
       , dewPointF    :: Int
       , humidity     :: Int
       , pressure     :: Int
       } deriving (Show)

pTime :: Parser (String, String, String, String)
pTime = do y <- getNumbersAsString
           char '.'
           m <- getNumbersAsString
           char '.'
           d <- getNumbersAsString
           char ' '
           (h:hh:mi:mimi) <- getNumbersAsString
           char ' '
           return (y, m, d ,h:hh:":"++mi:mimi)

noWind :: WindInfo
noWind = WindInfo "μ" "μ" "0" "0" "0" "0"

pWind :: Parser WindInfo
pWind =
  let tospace = manyTill anyChar (char ' ')
      toKmh knots = knots $* 1.852
      toMs knots  = knots $* 0.514
      ($*) :: String -> Double -> String
      op1 $* op2 = show (round ((read op1::Double) * op2)::Integer)

      -- Occasionally there is no wind and a METAR report gives simply, "Wind: Calm:0"
      wind0 = do manyTill skipRestOfLine (string "Wind: Calm:0")
                 return noWind
      windVar = do manyTill skipRestOfLine (string "Wind: Variable at ")
                   mph <- tospace
                   string "MPH ("
                   knot <- tospace
                   manyTill anyChar newline
                   return $ WindInfo "μ" "μ" mph knot (toKmh knot) (toMs knot)
      wind = do manyTill skipRestOfLine (string "Wind: from the ")
                cardinal <- tospace
                char '('
                azimuth <- tospace
                string "degrees) at "
                mph <- tospace
                string "MPH ("
                knot <- tospace
                manyTill anyChar newline
                return $ WindInfo cardinal azimuth mph knot (toKmh knot) (toMs knot)
  in try wind0 <|> try windVar <|> try wind <|> return noWind

pTemp :: Parser (Int, Int)
pTemp = do let num = digit <|> char '-' <|> char '.'
           f <- manyTill num $ char ' '
           manyTill anyChar $ char '('
           c <- manyTill num $ char ' '
           skipRestOfLine
           return (floor (read c :: Double), floor (read f :: Double))

pRh :: Parser Int
pRh = do s <- manyTill digit (char '%' <|> char '.')
         return $ read s

pPressure :: Parser Int
pPressure = do manyTill anyChar $ char '('
               s <- manyTill digit $ char ' '
               skipRestOfLine
               return $ read s

{-
    example of 'http://weather.noaa.gov/pub/data/observations/metar/decoded/VTUD.TXT':
        Station name not available
        Aug 11, 2013 - 10:00 AM EDT / 2013.08.11 1400 UTC
        Wind: from the N (350 degrees) at 1 MPH (1 KT):0
        Visibility: 4 mile(s):0
        Sky conditions: mostly clear
        Temperature: 77 F (25 C)
        Dew Point: 73 F (23 C)
        Relative Humidity: 88%
        Pressure (altimeter): 29.77 in. Hg (1008 hPa)
        ob: VTUD 111400Z 35001KT 8000 FEW030 25/23 Q1008 A2977 INFO R RWY30
        cycle: 14
-}
parseData :: Parser [WeatherInfo]
parseData =
    do (st, ss) <- try (string "Station name not available" >> return ("??", "??")) <|>
                   (do st <- getAllBut ","
                       space
                       ss <- getAllBut "("
                       return (st, ss)
                   )
       skipRestOfLine >> getAllBut "/"
       (y,m,d,h) <- pTime
       w <- pWind
       v <- getAfterString "Visibility: "
       sk <- getAfterString "Sky conditions: "
       skipTillString "Temperature: "
       (tC,tF) <- pTemp
       skipTillString "Dew Point: "
       (dC, dF) <- pTemp
       skipTillString "Relative Humidity: "
       rh <- pRh
       skipTillString "Pressure (altimeter): "
       p <- pPressure
       manyTill skipRestOfLine eof
       return [WI st ss y m d h w v sk tC tF dC dF rh p]

defUrl :: String
defUrl = "http://weather.noaa.gov/pub/data/observations/metar/decoded/"

stationUrl :: String -> String
stationUrl station = defUrl ++ station ++ ".TXT"

getData :: String -> IO String
#ifdef HTTP_CONDUIT
getData station = CE.catch (do
    manager <- newManager tlsManagerSettings 
    request <- parseUrl $ stationUrl station
    res <- httpLbs request manager
    return $  B.unpack $ responseBody res
    ) errHandler
    where errHandler :: CE.SomeException -> IO String
          errHandler _ = return "<Could not retrieve data>"
#else
getData station = do
    let request = getRequest (stationUrl station)
    CE.catch (simpleHTTP request >>= getResponseBody) errHandler
    where errHandler :: CE.IOException -> IO String
          errHandler _ = return "<Could not retrieve data>"
#endif

formatWeather :: [WeatherInfo] -> Monitor String
formatWeather [WI st ss y m d h (WindInfo wc wa wm wk wkh wms) v sk tC tF dC dF r p] =
    do cel <- showWithColors show tC
       far <- showWithColors show tF
       parseTemplate [st, ss, y, m, d, h, wc, wa, wm, wk, wkh, wms, v, sk, cel, far, show dC, show dF, show r , show p ]
formatWeather _ = getConfigValue naString

runWeather :: [String] -> Monitor String
runWeather str =
    do d <- io $ getData $ head str
       i <- io $ runP parseData d
       formatWeather i

weatherReady :: [String] -> Monitor Bool
#ifdef HTTP_CONDUIT
weatherReady str = do
    initRequest <- parseUrl $ stationUrl $ head str
    let request = initRequest{method = methodHead}
    io $ CE.catch ( do
        manager <- newManager tlsManagerSettings
        res     <- httpLbs request manager
        return $ checkResult $responseStatus res ) errHandler
    where errHandler :: CE.SomeException -> IO Bool
          errHandler _ = return False
          checkResult status
            | statusIsServerError status = False
            | statusIsClientError status = False
            | otherwise = True
#else
weatherReady str = do
    let station = head str
        request = headRequest (stationUrl station)
    io $ CE.catch (simpleHTTP request >>= checkResult) errHandler
    where errHandler :: CE.IOException -> IO Bool
          errHandler _ = return False
          checkResult result =
            case result of
                Left _ -> return False
                Right response ->
                    case rspCode response of
                        -- Permission or network errors are failures; anything
                        -- else is recoverable.
                        (4, _, _) -> return False
                        (5, _, _) -> return False
                        (_, _, _) -> return True
#endif
