{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE TypeApplications #-}
module Juke.React where

import Juke.Internal
import UnliftIO
import Control.Monad.Reader
import qualified Data.TMap as TM
import Control.Monad.Trans.Cont
import Data.Bifunctor
import Control.Category ((<<<), (>>>))
import Control.Arrow (returnA)
import UnliftIO.Concurrent
import Data.Profunctor

useState :: s -> Juke m () (s, (s -> s) -> IO s)
useState def = Juke $ do
  cVar <- newCVarIO def
  let updateState f = atomically $ do
                        prevS <- peekCVar cVar
                        let newS = f prevS
                        putCVar cVar newS
                        pure newS
  pure $ \x -> do
           s <- retriggerOn def (atomically $ waitCVar cVar)
           pure $ (s, updateState)


-- Runs the given effect asyncronously using the most recent input.
useEffectNoCache :: Juke m (IO x) ()
useEffectNoCache = Juke $ do
  pure $ \eff -> do
    asyncWithCleanup $ void $ eff

-- Runs the given effect asyncronously using the most recent input.
-- Only kills and re-runs the effect when the input changes.
useEffect :: Eq a => Juke m (IO x, a) ()
useEffect = cachedOn snd $ lmap fst useEffectNoCache

type Context = TM.TMap
type HasContext m = MonadReader Context m

useContext :: (Typeable a) => Juke Context x (Maybe a)
useContext = Juke $ do
  pure $ \_ -> do
    asks TM.lookup

withContext :: Typeable a => Juke Context i o -> Juke Context (a, i) o
withContext (Juke setup) = Juke $ do
  f <- setup
  pure $ \(a, i) -> do
    local (TM.insert a) $ f i

stateExample :: IO ()
stateExample = watch () () print $ proc inp -> do
  (n, updater) <- tap (print . fst) <<< useState 0 -< ()
  let eff = (forever $ print ("loop" <> show n) *> updater succ *> print "updated" *> threadDelay (n * 1000000))
  useEffect -< (eff, n)
  returnA -< n
