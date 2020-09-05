{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase
, OverloadedStrings
, DataKinds
, ScopedTypeVariables #-}

module Montevideo.Monome.Main (
  -- ** The apps
    edoMonome
  , jiMonome

  -- ** Utilities they use
  , renameMonomes -- ^ IO ()
  , initAllWindows -- ^ MVar St -> [Window] -> IO ()
  , handleSwitch -- ^ MVar (St app) -> ((X,Y), Switch)
                 -- -> IO (Either String ())

  -- * No need so far to export these. (No way to test them.)
  --  , doScAction    -- ^ St -> ScAction VoiceId -> IO ()
  --  , doLedMessage  -- ^ St -> [Window] -> LedMsg -> IO ()
  ) where

import           Control.Concurrent (forkIO, killThread)
import           Control.Concurrent.MVar
import           Control.Lens hiding (set, set')
import           Data.ByteString.Char8 (pack, unpack)
import           Data.Either.Combinators
import qualified Data.List as L
import qualified Data.Map as M
import           Data.Map (Map)

import Vivid
import Vivid.OSC

import           Montevideo.Dispatch.Types.Many
import           Montevideo.Dispatch.Types.Time (unTimestamp)
import           Montevideo.Monome.Config.Monome
import qualified Montevideo.Monome.Config.Mtv as Config
import           Montevideo.Monome.Network.Util
import           Montevideo.Monome.Types
import           Montevideo.Monome.Util.OSC
import           Montevideo.Monome.Window.JI
import           Montevideo.Monome.Window.Keyboard
import           Montevideo.Monome.Window.ParamGroup
import           Montevideo.Monome.Window.ParamVal
import           Montevideo.Monome.Window.Shift
import           Montevideo.Monome.Window.Sustain
import           Montevideo.Monome.Window.Util
import           Montevideo.Synth
import           Montevideo.Synth.Msg


-- ** The apps

-- | For usage, see Montevideo.Monome.Interactive.hs
edoMonome :: EdoConfig -> IO ( MVar (St EdoApp)
                             , IO (St EdoApp) )
edoMonome edoCfg = do
  toMonomes <- renameMonomes
  inbox :: Socket <- receivesAt "127.0.0.1" 8000
    -- I don't know why it's port 8000, or why it used to be 11111.

  mst :: MVar (St EdoApp) <- newMVar $ St {
      _stWindowLayers = M.fromList
        [ ( Monome_256
          , [sustainWindow, shiftWindow, keyboardWindow] )
        , ( Monome_128
          , [paramGroupWindow, paramValWindow, keyboardWindow] ) ]
    , _stToMonome = toMonomes
    , _stVoices = mempty
    , _stPending_Vivid = []
    , _stPending_Monome = []
    , _stPending_String = []
    , _stZotDefaults = mempty
    , _stZotRanges = zotDefaultRanges

    , _stApp = EdoApp
        { _edoConfig = edoCfg
        , _edoXyShift = (0,0)
        , _edoFingers = mempty
        , _edoLit = mempty
          -- M.singleton (2 :: PitchClass) $ S.singleton LedBecauseAnchor
        , _edoSustaineded = mempty
        , _edoParamGroup = PG_FM
        }
    }

  initAllWindows mst

  responder <- forkIO $ forever $ do
    decodeOSC <$> recv inbox 4096 >>= \case
      Left text -> putStrLn . show $ text
      Right osc -> do
        case readOSC_asSwitch osc of
          Left s -> putStrLn s
          Right (monome,switch) ->
            handleSwitch mst monome switch >>=
            either putStrLn return

  let quit :: IO (St EdoApp) = do
        close inbox
        killThread responder
        st <- readMVar mst
        let f = maybe (putStrLn "voice with no synth") free
          in mapM_ (f . (^. voiceSynth)) (M.elems $ _stVoices st)
        darkAllMonomes st
        return st
  return (mst, quit)

-- | One way to make a major scale it to use
-- the generators [1,4/3,3/2] and [1,5/4,3/2].
-- (Another would be to use the generators [1] and
-- [1,9/8,5/4,4/3,3/2,5/3,15/8], but that's harder to play,
-- and its geometry gives no insight into the scale.)
jiMonome :: [Rational] -- ^ The horizontal grid generator.
         -> [Rational] -- ^ The vertical grid generator.
         -> IO (St JiApp)
jiMonome scale shifts = do
  -- PITFALL: Every comment written in edoMonome also applies here.

  toMonomes <- renameMonomes
  inbox :: Socket <- receivesAt "127.0.0.1" 8000

  mst <- newMVar $ St {
      _stWindowLayers = M.singleton Monome_256 [jiWindow]
    , _stToMonome     = toMonomes
    , _stVoices = mempty
    , _stPending_Vivid = []
    , _stPending_Monome = []
    , _stPending_String = []
    , _stZotDefaults = mempty
    , _stZotRanges = mempty

    , _stApp = JiApp { _jiGenerator = scale
                     , _jiShifts = shifts
                     , _jiFingers = mempty }
    }
  initAllWindows mst

  responder <- forkIO $ forever $ do
    decodeOSC <$> recv inbox 4096 >>= \case
      Left text -> putStrLn . show $ text
      Right osc -> do
        case readOSC_asSwitch osc of
          Left s -> putStrLn s
          Right (monome,switch) ->
            handleSwitch mst monome switch >>=
            either putStrLn return

  let loop :: IO (St JiApp) =
        getChar >>= \case
        'q' -> do -- quit
          close inbox
          killThread responder
          st <- readMVar mst
          let f = maybe (putStrLn "voice with no synth") free
            in mapM_ (f . (^. voiceSynth)) (M.elems $ _stVoices st)
          darkAllMonomes st
          return st
        _   -> loop
    in putStrLn "press 'q' to quit"
       >> loop


-- ** Utilities they use

-- | Every time serialosc is restarted, the prefix that a monome uses
-- to filter messages (i.e. to decide which ones to respond to) is reset,
-- to "monome". I don't want them to all respond to the same messages,
-- so I have to give them different prefixes initially.
-- (Alternatively I could have them listen to different ports, I think,
-- but this is easy and that might not be.)
renameMonomes :: IO (Map MonomeId Socket)
renameMonomes = do
  let f :: MonomeId -> IO (MonomeId, Socket)
      f m = do
        toMonome <- sendsTo (unpack localhost) $ monomePort m
        _ <- send toMonome $ encodeOSC $ OSC "/sys/prefix"
          [ OSC_S $ pack $ show m ]
        return (m, toMonome)
  fmap M.fromList $ mapM f allMonomeIds

initAllWindows :: forall app. MVar (St app) -> IO ()
initAllWindows mst = do
  st <- readMVar mst
  let runWindowInit :: (MonomeId, Window app) -> IO ()
      runWindowInit (mi, w) = let
        st' :: St app = st & stPending_Monome %~ flip (++)
                             (windowInitLeds w st mi)
        in mapM_ (either putStrLn id) $
           doLedMessage st' <$> _stPending_Monome st'
      mws :: [(MonomeId, Window app)] =
        concatMap (\(m,ws) -> map (m,) ws) $
        M.toList $ _stWindowLayers st
  mapM_ runWindowInit mws

-- | Called every time a monome button is pressed or released.
-- Does two kinds of IO:
  -- stHandlePending: send to SuperCollider, the monome, and the console
  -- Change the MVar.
-- TODO : instead of MVar IO, return an St -> St.
-- (That way I could test it.)
handleSwitch :: forall app.
                MVar (St app) -> MonomeId -> ((X,Y), Switch)
             -> IO (Either String ())
-- PITFALL: The order of execution in `handleSwitch` is complex.
-- `windowHandler` runs before `doScAction` and `doLedMessage`.
-- Thus some updates to the St (everything but voice parameters,
-- the `voiceSynth` field, and voice deletion)
-- happen before SC has been informed.

handleSwitch mst mi sw@ (btn,_) = do
  st0 <- takeMVar mst
  let
    go :: [Window app] -> IO (Either String ())
    go ws = case L.find (\w -> windowContains w btn) ws of
      Nothing -> return $ Left $ "Switch " ++ show sw ++
                 " claimed by no Window."
      Just w -> case windowHandler w st0 (mi,sw) of
        Left s -> return $ Left s
        Right st1 -> do
          est :: Either String (St app) <-
            stHandlePending st1
          case est of
            Left  s   -> return $ Left s
            Right st2 -> do putMVar mst st2
                            return $ Right ()

  case M.lookup mi $ _stWindowLayers st0 of
    Nothing -> return $ Left $ "WIndows for " ++ show mi ++ " not found."
    Just ws ->
      fmap (mapLeft ("Monome.Main.handleSwitch: " ++)) $
        go ws

-- | `stHandlePending st` does two things:
--   (1) Act on the pending messages in `_stPending_Monome`,
--       `_stPending_Vivid` and `_stPending_String`.
--   (2) Empty those fields in `st`.
stHandlePending :: forall app. St app -> IO (Either String (St app))
stHandlePending st1 = do
  mapM_ putStrLn $ _stPending_String st1
  mapM_ (either putStrLn id) $
    doLedMessage st1 <$> _stPending_Monome st1
  case mapM (doScAction st1) (_stPending_Vivid st1) of
    Left s -> return $ Left s
    Right ( iofs :: [IO (St app -> St app ) ] ) -> do

      fs :: [St app -> St app] <-
        mapM id iofs
      return $ Right $ (foldl (.) id fs st1)
        { _stPending_Monome = []
        , _stPending_Vivid = []
        , _stPending_String = [] }

-- | `doScAction st sca` sends the instructions described by `sca` to Vivid,
-- and if necessary, returns how to update `st` to reflect the creation
-- or deletion of a voice.
doScAction :: St app -> ScAction VoiceId
           -> Either String (IO (St a -> St a))
doScAction    st        sca =
  mapLeft ("doScAction: " ++) $
  let setVivid :: Synth ZotParams -> (ParamName, Float) -> IO ()
      setVivid s (param, f) =
        mapM_ (set' s) $ zotScMsg $ M.singleton param f
  in
  case sca of

    ScAction_Send _ _ _ -> do
      let vid :: VoiceId = _actionSynthName sca
      s :: Synth ZotParams <-
        maybe (Left $ "VoiceId " ++ show vid ++ " has no assigned synth.")
        Right $ (_stVoices st M.! vid) ^. voiceSynth
      let ios :: [IO ()] = -- Send each (key,val) from `sca` separately.
            map (setVivid s) $ M.toList $ _actionScMsg sca
      Right $ mapM_ id ios >> return id

    ScAction_New _ _ _ -> do
      let vid :: VoiceId = _actionSynthName sca
      _ <- maybe (Left $ "VoiceId " ++ show vid ++ " should be present "
                  ++ " (but not yet with a synth) in _stVoices.")
           Right $ M.lookup vid $ _stVoices st
      Right $ do
        s <- synth zot () -- TODO change zot to `_actionSynthDefEnum sca`
        let ios :: [IO ()] = map (setVivid s) $ M.toList $ _actionScMsg sca
        mapM_ id ios
        return $ stVoices . at vid . _Just . voiceSynth .~ Just s

    -- PITFALL: If a voice is deleted right away,
    -- there's usually an audible pop.
    -- (It depends on how far the waveform is displaced from 0.)
    -- To avoid that, this first sends an `amp=0` message,
    -- and then waits for a duration defined in Monome.Config.
    -- That smooths the click because amp messages are responded to
    -- sluggishly, per the "lag" in the synth's definition.

    ScAction_Free _ _ -> do
      let vid :: VoiceId = _actionSynthName sca
      v :: Voice a <- maybe
        (Left $ "VoiceId " ++ show vid ++ " absent from _stVoices.")
        Right $ M.lookup vid $ _stVoices st
      s :: Synth ZotParams <- maybe
        (Left $ "Voice " ++ show vid ++ " has no assigned synth.")
        Right $ _voiceSynth v
      Right $ do
        now <- unTimestamp <$> getTime
        set s (0 :: I "amp")
        doScheduledAt ( Timestamp $ fromRational now
                        + realToFrac Config.freeDelay ) $
          free s
        return $ stVoices . at vid .~ Nothing

doLedMessage :: St app -> LedMsg -> Either String (IO ())
doLedMessage st ((mi, wi), (xy, b)) =
  mapLeft ("doLedMessage: " ++) $
  case relayToWindow st mi wi of
    Left s         -> Left s
    Right toWindow -> Right $ toWindow (xy,b)

darkAllMonomes :: St app -> IO ()
darkAllMonomes st =
  mapM_ (\mid -> off (receiver mid) mid) allMonomeIds
  where
    off socket name = send socket $ allLedOsc name False
    receiver monomeId = (M.!) (_stToMonome st) monomeId
