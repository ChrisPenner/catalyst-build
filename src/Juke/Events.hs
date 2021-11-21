{-# LANGUAGE DataKinds #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE TypeApplications #-}
module Juke.Events where

import Juke.Internal
import Juke.React
import Control.Monad
import Control.Arrow

keys :: Juke Reactive ctx i String
keys = Juke $ do
  pure $ \i -> do
    triggerOn $ \h -> forever $ do
      getLine >>= h
-- keys = Juke

keyExample :: IO ()
keyExample = watch () () (print) $ proc inp -> do
  (s, updater) <- useState "start" -< inp
  useEffect -< (forever (getLine >>= updater . const), ())
  returnA -< s
