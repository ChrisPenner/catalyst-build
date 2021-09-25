{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
module Juke.React where

import Juke
import UnliftIO
import Control.Monad.Reader
import qualified Data.TMap as TM

useState :: s -> Juke m () (s, (s -> s) -> IO s)
useState def = Juke $ do
  cVar <- newEmptyCVarIO
  let updateState f = atomically $ do
                        prevS <- peekCVar cVar 
                        let newS = f prevS
                        putCVar cVar newS
                        pure newS
  pure $ \x -> do
           s <- retriggerOn def (atomically $ waitCVar cVar)
           pure $ (s, updateState)


-- Runs the given effect asyncronously using the most recent input.
useEffectNoCache :: (a -> IO ()) -> Juke m a ()
useEffectNoCache buildEff = Juke $ do
  pure $ \a -> do
    asyncWithCleanup $ buildEff a

-- Runs the given effect asyncronously using the most recent input.
-- Only kills and re-runs the effect when the input changes.
useEffect :: Eq a => (a -> IO ()) -> Juke m a ()
useEffect buildEff = cachedEq $ useEffect buildEff

newtype Context = Context {getContext :: TM.TMap}

type HasContext m = MonadReader Context m

useContext :: (Typeable a) => Juke Context () (Maybe a)
useContext = Juke $ do
  pure $ \_ -> do
    asks (TM.lookup . getContext)

withContext :: Typeable a => Juke Context a ()
