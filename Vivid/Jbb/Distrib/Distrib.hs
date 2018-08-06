module Vivid.Jbb.Distrib.Distrib where

import Control.Concurrent (forkIO, ThreadId)
import Control.Concurrent.MVar
import qualified Data.Map as M

import Vivid
import Vivid.Jbb.Distrib.Act
import Vivid.Jbb.Distrib.Msg
import Vivid.Jbb.Distrib.Museq
import Vivid.Jbb.Distrib.Types


-- | todo : this blocks if any MVar is empty
showDist :: Distrib -> IO String
showDist dist = do timeMuseqs <- readMVar $ mTimeMuseqs dist
                   reg' <- showSynthRegister $ reg dist
                   time0 <- readMVar $ mTime0 dist
                   period <- readMVar $ mPeriod dist
                   return $ "(Time,Museq)s: " ++ show timeMuseqs ++ "\n"
                     ++ "SynthRegister: " ++ show reg' ++ "\n"
                     ++ "Time 0: " ++ show time0
                     ++ "Period: " ++ show period

allWaiting :: Distrib -> IO (Bool)
allWaiting dist = do
  timeMuseqs <- readMVar $ mTimeMuseqs dist
  let times = map fst $ M.elems $ timeMuseqs
  now <- unTimestamp <$> getTime
  return $ and $ map (> now) times

--chPeriod :: Distrib -> IO () -- TODO
--chPeriod = do
--  waitingUntil <- readMVar mWaitingUntil
--  now <- unTimestamp <$> getTime

startDistribLoop :: Distrib -> IO ThreadId
startDistribLoop dist = do
  tryTakeMVar $ mTime0 dist -- empty it, just in case
  (+(-0.05)) . unTimestamp <$> getTime >>= putMVar (mTime0 dist)
    -- subtract .1 so music starts in .05 seconds, not frameDur seconds
  forkIO $ distribLoop dist

distribLoop :: Distrib -> IO ()
distribLoop dist = do
  putStrLn =<< showDist dist
  time0  <- readMVar $ mTime0  dist
  period <- readMVar $ mPeriod dist
  timeMuseqs <- readMVar $ mTimeMuseqs dist
  now <- unTimestamp <$> getTime -- get time ALAP

  -- TODO ? delete
  putStrLn $ "\n" ++ show now
  putStrLn =<< showDist dist

  -- find what comes next in each Museq
  let nextPlus :: M.Map String (Duration, [Action])
        -- some of these are immediately next, but maybe not all
      nextPlus = M.map (findNextEvents time0 period now . snd) timeMuseqs

  -- record (ASAP) in each Museq the time until its next Action(s)
  swapMVar (mTimeMuseqs dist) $ M.mapWithKey
    (\name (_,vec) -> (fst $ (M.!) nextPlus name, vec))
    timeMuseqs

  -- TODO : if the sequence is empty, this errs
  let leastWait = minimum $ M.elems $ M.map fst nextPlus
      nextActions = concatMap snd
                    $ filter ((== leastWait) . fst)
                    $ M.elems nextPlus

  wait leastWait
  mapM_ (act $ reg dist) nextActions

  distribLoop dist
