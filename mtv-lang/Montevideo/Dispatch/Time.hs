module Montevideo.Dispatch.Time (
    arc -- ^ forall l a. Time -> Duration -> Time -> Time
        -- -> Museq l a -> [Event Time l a]
  , nextPhase0 -- ^ RealFrac a => a -> a -> a -> a
  , prevPhase0 -- ^ RealFrac a => a -> a -> a -> a

  -- | = Timing a Museq
  , supsToRepeat      -- ^ Museq l a -> RTime
  , dursToRepeat      -- ^ Museq l a -> RTime
  , longestDur -- ^ Museq l a -> RDuration
  , supsToPlayThrough -- ^ Museq l a -> RTime
  , dursToPlayThrough -- ^ Museq l a -> RTime
  , timeToRepeat      -- ^ Museq l a -> RTime
  , timeToPlayThrough -- ^ Museq l a -> RTime
  ) where

import Control.Lens hiding (to,from)
import Data.Fixed (div')
import qualified Data.Vector as V

import Montevideo.Dispatch.Types
import Montevideo.Util


-- | `arc time0 period from to m`
-- find the events of `m` that fall in `[from,to)` (a half-open interval).
arc :: forall l a.
    Time -- ^ a reference point in the past
  -> Duration -- ^ tempo period ("bar length")
  -> Time -- ^
  -> Time
  -> Museq l a
  -> [Event Time l a]
-- todo ? `arc` could be ~2x faster by using binarySearchRByBounds
-- instead of binarySearchR, to avoid searching the first part
-- of the vector again.

arc time0 tempoPeriod from to m = let
  period = tempoPeriod * tr (_sup m) :: Duration
  startVec = V.map (view evStart) $ _vec $ m :: V.Vector RTime
  latestPhase0 = prevPhase0 time0 period from :: Time
    -- It would be natural to start here, but long events from
    -- earlier cycles could carry into this one.
  earlierFrom = latestPhase0 - tr (longestDur m) * tempoPeriod :: Time
  oldestRelevantCycle = div' (earlierFrom - latestPhase0) period :: Int
  correctAbsoluteTimes :: (Time,Time) -> (Time,Time)
    -- HACK: The inputs ought to be RTimes,
    -- but then I'd be switching types, from Ev to AbsEv.
  correctAbsoluteTimes (a,b) = (f a, f b) where
    f rt = tr rt * tempoPeriod + latestPhase0
  chopStarts :: (Time,Time) -> (Time,Time)
  chopStarts = over _1 $ max from
  chopEnds :: (Time,Time) -> (Time,Time)
  chopEnds = over _2 $ min to
  dropImpossibles :: [Event Time l a] -> [Event Time l a]
    -- Because chopStarts can leave an old event starting after it ended.
  dropImpossibles = filter $ uncurry (<=) . view evArc
  futzTimes :: Event RTime l a -> Event Time l a
  futzTimes ev = over evArc f $ eventRTimeToEventTime ev
    where f = chopEnds . chopStarts . correctAbsoluteTimes
  in dropImpossibles $ map futzTimes $ _arcFold
     oldestRelevantCycle period startVec time0 earlierFrom to m

_arcFold :: forall l a. Int -> Duration -> V.Vector RTime
  -> Time -> Time -> Time -- ^ the same three `Time` arguments as in `arc`
  -> Museq l a -> [Ev l a]
_arcFold cycle period startVec time0 from to m =
  if null (m ^. vec) || from >= to
    -- TODO ? Be sure of `arc` boundary condition
  then [] else let
    pp0 = prevPhase0 time0 period from :: Time
    fromInCycles = fr $ (from - pp0) / period :: RTime
    toInCycles   = fr $ (to   - pp0) / period :: RTime
    startOrOOBIndex =
      firstIndexGTE compare startVec $ fromInCycles * _sup m :: Int
  in if startOrOOBIndex >= V.length startVec
--     then let nextFrom = if pp0 + period > from
-- -- todo ? delete
-- -- If `from = pp0 + period - epsilon`, maybe `pp0 + period <= from`.
-- -- Thus floating point error used to make this if-then statement necessary
-- -- Now that all times are Rational, it's probably unnecessary.
--                         then pp0 + period
--                         else pp0 + 2*period
--          in _arcFold (cycle+1) period startVec time0 nextFrom to m
     then _arcFold (cycle+1) period startVec time0 (pp0 + period) to m
     else
       let startIndex = startOrOOBIndex :: Int
           endIndex = lastIndexLTE compare' startVec
                      $ toInCycles * _sup m :: Int
             where compare' x y =
                     if x < y then LT else GT -- to omit the endpoint
           eventsThisCycle = V.toList
             $ V.map (over evEnd   (+(_sup m * fromIntegral cycle)))
             $ V.map (over evStart (+(_sup m * fromIntegral cycle)))
             $ V.slice startIndex (endIndex-startIndex) $ _vec m
       in eventsThisCycle
          ++ _arcFold (cycle+1) period startVec time0 (pp0 + period) to m

-- | `time0` is the first time that had phase 0
-- | TODO ? rewrite using div', mod' from Data.Fixed
nextPhase0 :: RealFrac a => a -> a -> a -> a
nextPhase0 time0 period now =
  fromIntegral x * period + time0
  where x :: Int = ceiling $ (now - time0) / period

-- | PITFALL ? if lastPhase0 or nextPhase0 was called precisely at phase0,
-- both would yield the same result. Since time is measured in microseconds
-- there is exactly a one in a million chance of that.
-- | TODO ? rewrite using div', mod' from Data.Fixed
prevPhase0 :: RealFrac a => a -> a -> a -> a
prevPhase0 time0 period now =
  fromIntegral x * period + time0
  where x :: Int = floor $ (now - time0) / period


-- | = Timing a Museq

-- | = Figuring out when a Museq will repeat.
-- There are two senses in which a Museq can repeat. One is that
-- it sounds like it's repeating. If _dur = 2 and _sup = 1, then
-- it sounds like it's repeating after a single _sup.
-- The *ToRepeat functions below use that sense.
--
-- The other sense is that the Museq has cycled through what it
-- "is supposed to cycle through". (This is useful when `append`ing Museqs.)
-- If _dur = 2 and _sup = 1, it won't have played all the way through
-- until _dur has gone by, even though a listener hears it start to repeat
-- halfway through that _dur.
-- The *ToPlayThrough functions below use that sense.
--
-- The results of the two families only differ when _sup divides _dur.
--
-- I could have used the *PlayThrough functions everywhere, but
-- in some situations that would waste space. For an example of one,
-- see in Tests.testStack the assertion labeled
-- "stack, where timeToRepeat differs from timeToPlayThrough".

supsToRepeat :: Museq l a -> RTime
supsToRepeat m = timeToRepeat m / _sup m

dursToRepeat :: Museq l a -> RTime
dursToRepeat m = timeToRepeat m / _dur m

longestDur :: Museq l a -> RDuration
longestDur m = let eventDur ev = (ev ^. evEnd) - (ev ^. evStart)
               in V.maximum $ V.map eventDur $ _vec m

supsToPlayThrough :: Museq l a -> RTime
supsToPlayThrough m = timeToPlayThrough m / (_sup m)

dursToPlayThrough :: Museq l a -> RTime
dursToPlayThrough m = timeToPlayThrough m / (_dur m)

-- | After `timeToRepeat`, the `Museq` *sounds* like it's repeating.
-- That doesn't mean it's played all the way through, though.
timeToRepeat :: Museq l a -> RTime
timeToRepeat m = let tp = timeToPlayThrough m
                 in if tp == _dur m -- implies `_dur m > _sup m`
                    then _sup m else tp

-- | A `Museq` has "played through" when it has played for a time
-- that is an integer multiple of both _dur and _sup.
-- Remember, if it is concatenated to another pattern,
-- the clock is paused, so to speak, while the other pattern plays.
timeToPlayThrough :: Museq l a -> RTime
timeToPlayThrough m = RTime $ lcmRatios (tr $ _sup m) (tr $ _dur m)
