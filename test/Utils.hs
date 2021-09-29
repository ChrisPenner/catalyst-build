{-# LANGUAGE LambdaCase #-}
module Utils where

import Juke.Internal
import UnliftIO (withAsync, MonadIO (liftIO))
import Control.Monad
import Control.Concurrent.STM
import Control.Applicative


sequenced :: (CVar Int -> Juke s ctx i i -> IO ()) -> IO ()
sequenced cc = do
  var <- newCVarIO 0
  -- let seqLoop = forever . atomically $ do
  --       waitForEmpty var
  --       optional (peekCVar var) >>= \case
  --         Just n -> putCVar var (succ n)
  --         Nothing -> putCVar var 0
  let stepper = Juke $ do
        pure $ \i -> do
          liftIO . atomically $ do
                       peekCVar var >>= putCVar var . succ
          pure i
  cc var stepper

-- Accepts a set of outputs to be emitted only on the appropriate step
steps :: CVar Int -> [(Int, o)] -> Juke strat ctx i o
steps v os = Juke $ do
  pure $ \_ -> do
    triggerOn $ \emit -> do
      flip foldMap os $ \(n, o) -> do
        atomically $ do
          nextN <- waitCVar v
          guard (nextN == n)
        emit o
