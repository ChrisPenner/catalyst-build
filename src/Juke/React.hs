{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
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

useState :: s -> Juke Reactive ctx () (s, (s -> s) -> IO s)
useState def = Juke $ do
  cVar <- newCVarIO def
  let updateState f = atomically $ do
                        prevS <- peekCVar cVar
                        let newS = f prevS
                        putCVar cVar newS
                        pure newS
  pure $ \x -> do
           s <- triggerOn $ \emit -> do
                  emit def
                  forever $ do
                    o <- atomically $ waitCVar cVar
                    emit o
           pure $ (s, updateState)


-- Runs the given effect asyncronously using the most recent input.
-- useEffectNoCache :: Juke Reactive ctx (IO x) ()
-- useEffectNoCache = Juke $ do
--   effRef <- newTVarIO $ Nothing
--   pure $ \eff -> do
--     asyncWithCleanup $ void $ eff

useEffect :: Eq a => Juke Reactive ctx (IO x, a) ()
useEffect = Juke $ do
  effRef <- newTVarIO $ Nothing
  let saveRef eff sentinel = do
        r <- async eff 
        atomically $ writeTVar effRef (Just (r, sentinel))
  pure $ \(eff, sentinel) -> Builder . liftIO $ do
    readTVarIO effRef >>= \case
      Nothing -> saveRef eff sentinel
      Just (ref, lastSent) 
        | lastSent /= sentinel -> (cancel ref *> saveRef eff sentinel)
        | otherwise -> pure ()

-- Runs the given effect asyncronously using the most recent input.
-- Only kills and re-runs the effect when the input changes.
-- useEffect :: Eq a => Juke Reactive ctx (IO x, a) ()
-- useEffect = cutOn snd >>> lmap fst useEffectNoCache

type Context = TM.TMap
type HasContext m = MonadReader Context m

useContext :: (Typeable a) => Juke strat Context x (Maybe a)
useContext = Juke $ do
  pure $ \_ -> do
    asks TM.lookup

withContext :: Typeable a => Juke strat Context i o -> Juke strat Context (a, i) o
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
