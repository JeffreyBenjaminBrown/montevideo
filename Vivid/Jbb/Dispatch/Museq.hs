{-# LANGUAGE ScopedTypeVariables #-}

-- | = Mostly analysis

module Vivid.Jbb.Dispatch.Museq (
    timeToPlayThrough
  , supsToPlayThrough
  , dursToPlayThrough
  , timeToRepeat
  , supsToRepeat
  , dursToRepeat

  , museqSynths
  , museqsDiff

  , sortMuseq
  , museqIsValid

  , arc
  , arc'
  ) where

import Control.Lens ((^.),(.~),(%~),_1,_2,over,view)
import Control.Monad.ST
import Data.List ((\\))
import qualified Data.Map as M
import qualified Data.Vector as V
import           Data.Vector ((!))
import Data.Vector.Algorithms.Intro (sortBy)

import Vivid.Jbb.Dispatch.Types
import Vivid.Jbb.Dispatch.HasStart
import Vivid.Jbb.Util
import Vivid.Jbb.Synths (SynthDefEnum(Boop))


-- | = Figuring out when a Museq will repeat.
-- There are two senses in which a Museq can repeat. One is that
-- it sounds like it's repeating. If _dur = 2 and _sup = 1, then
-- it sounds like it's repeating after a single _sup.
-- The *ToRepeat functions below use that sense.
--
-- The other sense is that the Museq has cycled through what it
-- "is supposed to cycle through". (This is useful when `append`ing Museqs.)
-- If _dur = 2 and _sup = 1, it won't have played all the way through
-- until _dur has gone by, even though a listener hears it doing the same
-- thing halfway through that _dur.
-- The *ToPlayThrough functions below use that sense.
--
-- The results of the two families only differ when _sup divides _dur.
--
-- I could have used the *PlayThrough functions everywhere, but
-- in some situations that would waste space. For an example of one,
-- see in Tests.testStack the assertion labeled
-- "stack, where timeToRepeat differs from timeToPlayThrough".

timeToPlayThrough :: Museq a -> Rational
timeToPlayThrough m = lcmRatios (_sup m) (_dur m)

supsToPlayThrough :: Museq a -> Rational
supsToPlayThrough m = timeToPlayThrough m / _sup m

dursToPlayThrough :: Museq a -> Rational
dursToPlayThrough m = timeToPlayThrough m / _dur m

timeToRepeat :: Museq a -> Rational
timeToRepeat m = let x = lcmRatios (_sup m) (_dur m)
  in if x == _dur m then _sup m else x

supsToRepeat :: Museq a -> Rational
supsToRepeat m = timeToRepeat m / _sup m

dursToRepeat :: Museq a -> Rational
dursToRepeat m = timeToRepeat m / _dur m


-- | Given a Museq, find the synths it uses.
museqSynths :: Museq Action -> [(SynthDefEnum, SynthName)]
museqSynths = map (actionSynth . snd) . V.toList . _vec

-- | Given an old set of Museqs and a new one, figure out
-- which synths need to be created, and which destroyed.
-- PITFALL: Both resulting lists are ordered on the first element,
-- likely differing from either of the input maps.
museqsDiff :: M.Map MuseqName (Museq Action)
           -> M.Map MuseqName (Museq Action)
           -> ([(SynthDefEnum, SynthName)],
               [(SynthDefEnum, SynthName)])
museqsDiff old new = (toFree,toCreate) where
  oldMuseqs = M.elems old :: [Museq Action]
  newMuseqs = M.elems new :: [Museq Action]
  oldSynths = unique $ concatMap museqSynths oldMuseqs
  newSynths = unique $ concatMap museqSynths newMuseqs
  toCreate = newSynths \\ oldSynths
  toFree = oldSynths \\ newSynths


-- | = Sort a Museq
sortMuseq :: Museq a -> Museq a
sortMuseq = vec %~
  \v -> runST $ do v' <- V.thaw v
                   let compare' ve ve' = compare (fst ve) (fst ve')
                   sortBy compare' v'
                   V.freeze v'

-- | A valid Museq m is sorted on start time, has (relative) duration > 0,
-- and all actions at time < _sup m.
museqIsValid :: Eq a => Museq a -> Bool
museqIsValid mu = and [a,b,c,d] where
  a = if V.length (_vec mu) == 0 then True
      else fst (V.last $ _vec mu) < _sup mu
  b = mu == sortMuseq mu
  c = _dur mu > 0
  d = _sup mu > 0

-- todo ? `arc` could be ~2x faster by using binarySearchRByBounds
-- instead of binarySearchR, to avoid searching the first part
-- of the vector again.
-- | Finds the events in [from,to), and when they should start,
-- in relative time units.
arc :: Time -> Duration -> Time -> Time
    -> Museq a -> [(Time, a)]
arc time0 tempoPeriod from to m =
  let period = tempoPeriod * fromRational (_sup m)
      rdv = V.map fst $ _vec $ const () <$> m :: V.Vector RelDuration
      firstPhase0 = prevPhase0 time0 period from
      toAbsoluteTime :: RTime -> Time
      toAbsoluteTime rt = fromRational rt * tempoPeriod + firstPhase0
   in map (over _1 toAbsoluteTime) $ arcFold 0 period rdv time0 from to m

arcFold :: Int -> Duration -> V.Vector RelDuration
  -> Time -> Time -> Time -- ^ the same three `Time` arguments as in `arc`
  -> Museq a -> [(RTime, a)]
arcFold cycle period rdv time0 from to m = 
  if from >= to
  then [] -- todo ? Be sure of boundary condition
  else let
    pp0 = prevPhase0 time0 period from
    relFrom = toRational $ (from - pp0) / period
    relTo   = toRational $ (to   - pp0) / period
    startOrOOB = firstIndexGTE compare rdv (relFrom * _sup m)
  in if startOrOOB >= V.length rdv
     then let nextFrom = if pp0 + period > from
                         then pp0 + period
                         else pp0 + 2*period
  -- todo ? I know `nextFrom` (above) fixes the following bug,
    -- but why is it needed?
    -- The bug: Evaluate the following two statements. The second hangs.
      -- m = Museq {_dur = 1 % 6, _sup = 1 % 6, _vec = V.fromList [(1 % 24,Send Boop "3" ("amp",0.0)),(1 % 8,Send Boop "3" ("freq",600.0)),(1 % 8,Send Boop "3" ("amp",0.4))]}
      -- arc 0 1 8 9 m
          in arcFold (cycle+1) period rdv time0 nextFrom to m
     else let start = startOrOOB
              end = lastIndexLTE compare' rdv (relTo * _sup m) where
                compare' x y
                  = if x < y then LT else GT -- to omit the endpoint
              eventsThisCycle = V.toList
                $ V.map (over _1 (+(_sup m * fromIntegral cycle)))
                $ V.slice start (end-start) $ _vec m
          in eventsThisCycle
             ++ arcFold (cycle+1) period rdv time0 (pp0 + period) to m

-- TODO : for polymorphic Museq t n, will another version of arcFold:
-- this for things with only a start, the other for things with a start and
-- an end. That's because the other will need to take the minimum
-- of each event's end and the end of the arc being asked for.
arc' :: forall t s a. (HasStart t s, Real s, Fractional s)
     => Time -> Duration -> Time -> Time
     -> Museq' t a -> [(t, a)]
arc' time0 tempoPeriod from to m =
  let period = tempoPeriod * fromRational (_sup' m)
      rdv = V.map (view start . fst)
        $ _vec' $ const () <$> m :: V.Vector s
      firstPhase0 = prevPhase0 time0 period from
      toAbsoluteTime :: s -> s
      toAbsoluteTime t = t * realToFrac tempoPeriod
                         + realToFrac firstPhase0
   in map (over (_1.start) toAbsoluteTime)
      $ arcFold' 0 period rdv time0 from to m

arcFold' :: forall t s a. (HasStart t s, Fractional s, Ord s)
  => Int -> Duration -> V.Vector s
  -> Time -> Time -> Time -- ^ the same three `Time` arguments as in `arc`
  -> Museq' t a -> [(t, a)]
arcFold' cycle period rdv time0 from to m =
  if from >= to
  then [] -- todo ? Be sure of boundary condition
  else let
    pp0 = prevPhase0 time0 period from
    relFrom = toRational $ (from - pp0) / period
    relTo   = toRational $ (to   - pp0) / period
    startOrOOB = firstIndexGTE compare rdv $ fromRational (relFrom * _sup' m)
  in if startOrOOB >= V.length rdv
     then let nextFrom = if pp0 + period > from
                         then pp0 + period
                         else pp0 + 2*period
  -- todo ? I know `nextFrom` (above) fixes the following bug,
    -- but why is it needed?
    -- The bug: Evaluate the following two statements. The second hangs.
      -- m = Museq {_dur = 1 % 6, _sup = 1 % 6, _vec = V.fromList [(1 % 24,Send Boop "3" ("amp",0.0)),(1 % 8,Send Boop "3" ("freq",600.0)),(1 % 8,Send Boop "3" ("amp",0.4))]}
      -- arc 0 1 8 9 m
          in arcFold' (cycle+1) period rdv time0 nextFrom to m
     else let startIndex = startOrOOB
              endIndex = lastIndexLTE compare' rdv
                    (fromRational $ relTo * _sup' m) where
                compare' x y
                  = if x < y then LT else GT -- to omit the endpoint
              eventsThisCycle = V.toList
                $ V.map (over (_1 . start)
                         (+(fromRational $ _sup' m * fromIntegral cycle)))
                $ V.slice startIndex (endIndex-startIndex)
                $ _vec' m
          in eventsThisCycle
             ++ arcFold' (cycle+1) period rdv time0 (pp0 + period) to m
