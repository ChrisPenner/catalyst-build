module Juke.Stream where

import Juke.Internal
import UnliftIO
import Control.Monad.Trans.Cont
import Data.Foldable

taking :: Int -> Juke ctx i i
taking startN = Juke $ do
  nVar <- newTVarIO startN
  pure $ \i -> do
    n <- readTVarIO nVar
    if n > 0 then atomically (modifyTVar nVar pred) *> pure i 
             else bail

folded :: Foldable f => Juke ctx (f i) i
folded = Juke $ do
  pure $ emit . toList






-- take' :: Int -> Juke ctx i i
-- take' = _
