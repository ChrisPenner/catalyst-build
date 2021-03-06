{-# LANGUAGE DataKinds #-}
module Juke.Stream where

import Juke.Internal
import UnliftIO
import Control.Monad.Trans.Cont
import Data.Foldable

taking :: Int -> Juke Stream ctx i i
taking startN = Juke $ do
  nVar <- newTVarIO startN
  pure $ \i -> do
    n <- readTVarIO nVar
    if n > 0 then atomically (modifyTVar nVar pred) *> pure i 
             else bail

folded :: Foldable f => Juke Stream ctx (f i) i
folded = Juke $ do
  pure $ emit . toList

filtered :: (i -> Bool) -> Juke Stream ctx i i
filtered p = Juke $ do
  pure $ \i -> do
    if p i then pure i
           else bail












-- take' :: Int -> Juke ctx i i
-- take' = _
