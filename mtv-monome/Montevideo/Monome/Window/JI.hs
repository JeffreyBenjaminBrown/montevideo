{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE DataKinds
, TupleSections
, ScopedTypeVariables
#-}

module Montevideo.Monome.Window.JI (
    handler
  , jiWindow
  , label

  , jiKey_SoundMsg -- ^ JiApp -> ((X,Y), Switch) -> [SoundMsg]
  , jiFreq         -- ^ JiApp -> (X,Y) -> Either String Float
  ) where

import           Prelude hiding (pred)
import           Control.Lens
import           Data.Either.Combinators
import qualified Data.Map as M

import qualified Montevideo.Monome.Config as Config
import Montevideo.Monome.Types.Button
import Montevideo.Monome.Types.Initial
import Montevideo.Util
import Montevideo.Monome.Window.Common


label :: WindowId
label = "ji window"

jiWindow :: Window JiApp
jiWindow =  Window {
    windowLabel = label
  , windowContains = \(x,y) -> let pred = numBetween 0 15
                               in pred x && pred y
  , windowInit = id
  , windowHandler = handler }

-- TODO untested
-- TODO ! duplicative of `Keyboard.handler`
handler :: St JiApp
        -> ((X,Y), Switch)
        -> Either String (St JiApp)
handler st press@ (xy,sw) =
  mapLeft ("JI handler: " ++) $ let
  fingers' = st ^. stApp . jiFingers
             & case sw of
                 True  -> M.insert xy xy
                 False -> M.delete xy
  soundMsgs :: [SoundMsg JiApp] = jiKey_SoundMsg (st ^. stApp) press
  st1 :: St JiApp = st
    & stApp . jiFingers .~ fingers'
    & stPending_Vivid   %~ (++ soundMsgs)
  in Right $ foldr updateVoice st1 soundMsgs

-- TODO ! duplicative of `etKey_SoundMsg`
jiKey_SoundMsg :: JiApp -> ((X,Y), Switch) -> [SoundMsg JiApp]
jiKey_SoundMsg ja (xy,switch) = let
  doIfKeyFound :: Rational -> [SoundMsg JiApp]
  doIfKeyFound freq =
    if switch
      then let msg = SoundMsg
                     { _soundMsgVoiceId = xy
                     , _soundMsgPitch = Just freq
                     , _soundMsgVal = error "this gets set below"
                     , _soundMsgParam = error "this gets set below" }
           in [ msg & soundMsgVal .~ Config.freq * fr freq
                    & soundMsgParam .~ "freq"
              , msg & soundMsgVal .~ Config.amp
                    & soundMsgParam .~ "amp" ]
      else [silenceMsg xy]
  in either (const []) doIfKeyFound $ jiFreq ja xy
     -- [] if key out of range; key corresponds to no pitch

jiFreq :: JiApp -> (X,Y) -> Either String Rational
jiFreq ja (x,y) =
  mapLeft ("jiFreq: " ++) $ do
  let (yOctave :: Int, yShift :: Int) =
        divMod y $ length $ ja ^. jiShifts
      (xOctave :: Int, xGen :: Int) =
        divMod x $ length $ ja ^. jiGenerator
      f0 :: Rational =
        (ja ^. jiGenerator) !! xGen
        -- !! is safe here, because of the divMod that defines xGen
  Right $ f0
    * ((ja ^. jiShifts) !! yShift)
    -- (!!) is safe here, because of the divMod that defines yShift
    * (2 ^^ (yOctave + xOctave))
    -- Rational exponentiation (^^) because `yOctave + xOctave` could be < 0.
    -- THey are always an integer, though, so this could be more efficient
    -- by using integer exponentiation (^) and writing a little more code.
