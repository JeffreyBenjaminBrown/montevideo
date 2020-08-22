{-# OPTIONS_GHC -fno-warn-missing-fields #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# LANGUAGE FlexibleContexts #-}

module Montevideo.Monome.Test.Data where

import           Control.Lens
import qualified Data.Map as M
import qualified Data.Set as S

import Montevideo.Monome.EdoMath
import Montevideo.Monome.Types


config31, config22_stretch :: EdoConfig
config31 = EdoConfig
  { _edo = 31
  , _spacing = 6
  , _skip = 1
  , _octaveStretchInCents = 0
  , _gridVectors = Nothing
  }

config22_stretch = EdoConfig
  { _edo = 22
  , _spacing = 5
  , _skip = 1
  , _octaveStretchInCents = -1.106
  , _gridVectors = Nothing
  }

meh :: a
meh = error "not relevant to this test"

(=^=) :: (Eq app, Eq (Pitch app)) => St app -> St app -> Bool
(=^=) x y = and [
    _stPending_Monome x == _stPending_Monome y
  , _stPending_Vivid x  == _stPending_Vivid y
  , _stApp x            == _stApp y ]

v0     :: VoiceId    = VoiceId 0
v1     :: VoiceId    = VoiceId 1
xy0    :: (X,Y)      = (0,0)
xy1    :: (X,Y)      = (0,1)
pitch0 :: Int        = xyToEdo_app (st0 ^. stApp) xy0
pitch1 :: Int        = xyToEdo_app (st0 ^. stApp) xy1
pc0    :: PitchClass EdoApp = mod pitch0 31
pc1    :: PitchClass EdoApp = mod pitch1 31

st0 :: St EdoApp
st0 = St {
    _stVoices = let v = Voice
                        { _voiceSynth = Nothing
                        , _voicePitch = error "replaced below"
                        , _voiceParams = mempty }
      in M.fromList
         [ (v0, v { _voicePitch = pitch0 } )
         , (v1, v { _voicePitch = pitch1 } ) ]
  , _stPending_Monome = []
  , _stPending_Vivid = []
  , _stApp = EdoApp { _edoConfig = config31
                    , _edoXyShift = (3,5)
                    , _edoFingers = mempty
                    , _edoLit = mempty
                    , _edoSustaineded = mempty
                    }
  }

st_0a = -- 0 is the anchor pitch
  st0 & stApp . edoLit %~ M.insert pc0 (S.singleton LedBecauseAnchor)

st_0f = -- fingering key 0 only
  st0 & stApp . edoFingers .~ M.fromList [ (xy0, v0) ]
      & stApp . edoLit .~  M.fromList
        [ ( pc0, S.singleton $ LedBecauseSwitch xy0) ]

st_0s = -- sustaining key 0 only
  st0
  & stApp . edoLit .~  M.singleton pc0
    (S.singleton LedBecauseSustain)
  & stApp . edoSustaineded .~ S.singleton v0

st_01f = -- fingering keys 0 and 1
  st0 & stApp . edoFingers .~ M.fromList [ (xy0, v0)
                                         , (xy1, v1) ]
  & stApp . edoLit .~ M.fromList
    [ ( pc0, S.singleton $ LedBecauseSwitch xy0)
    , ( pc1, S.singleton $ LedBecauseSwitch xy1) ]

st_0fs = -- 0 is both fingered and sustained
  st0
  & stApp . edoFingers .~ M.fromList [ (xy0, v0) ]
  & stApp . edoSustaineded .~ S.singleton v0
  & stApp . edoLit .~ ( M.singleton pc0
                        $ S.fromList [ LedBecauseSwitch xy0
                                     , LedBecauseSustain ] )

st_0af = -- 0 is both fingered and the anchor pitch
  st_0f & stApp . edoLit . at pc0 . _Just
          %~ S.insert LedBecauseAnchor

st_0fs_1s = -- 0 is both fingered and sustained, 1 is sustained
  st_0fs & stApp . edoSustaineded %~ S.insert v1
         & stApp . edoLit %~ M.insert pc1 (S.singleton LedBecauseSustain)
