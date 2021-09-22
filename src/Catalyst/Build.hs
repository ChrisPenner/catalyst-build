{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Catalyst.Build where
import Control.Arrow
import Control.Category ( Category )
import Control.Monad
import Control.Applicative
import Data.Profunctor
import Data.Profunctor.Cayley
import Prelude hiding (readFile, log)
import Control.Monad.State
import Data.Maybe
import UnliftIO
import UnliftIO.Concurrent
import Control.Monad.Trans.Cont
import Control.Monad.Reader
import qualified Catalyst.Build.FileWatcher as FW
import System.FSNotify
import qualified Data.HashMap.Strict as HM
import System.Directory
import Data.Traversable
import Data.Function
import Data.Foldable
import qualified Data.ByteString.Char8 as BS

newtype Build i o =
    Build (IO (i -> ReaderT FW.FileWatcher (ContT () IO) o))
    deriving (Category, Arrow, Profunctor, Strong, Choice) via (Cayley IO (Kleisli (ReaderT FW.FileWatcher (ContT () IO))))

-- StatusTracker always tries to run each STM block,
-- but will only succeed if at least one contained block succeeds.
-- This allows arrows to "clear" their own status variables when they succeed
-- and prevents multiple redundant re-runs.
newtype StatusTracker = ST { runStatusTracker :: STM () }
instance Semigroup StatusTracker where
  ST l <> ST r = ST $ do
    l' <- optional l
    r' <- optional r
    if isNothing l' && isNothing r' then retrySTM
                                    else pure ()

instance Monoid StatusTracker where
  mempty = ST retrySTM

data LR = L | R
  deriving (Eq)

-- -- The derived version is too greedy with regard to the Status check.
-- instance Choice (Build) where
--   left' (Build setup) = Build $ do
--       f <- setup
--       let go = \case
--                  Left a -> do
--                      Left <$> f a
--                  Right x -> do
--                      pure $ Right x
--       pure $ go

instance ArrowChoice (Build) where
  left = left'

-- -- The instance derived via Cayley only runs setup once, whereas we need to run it for each value
-- itraverse' :: (Show i, Ord i, TraversableWithIndex i t) => Build a b -> Build (t a) (t b)
-- itraverse' (Build setup) = Build $ do
--     stashRef <- newTVarIO Map.empty
--     let envCheck = ST $ do
--           readTVar stashRef >>= runStatusTracker . foldMap fst
--     pure . (envCheck,) $ \xs -> do
--         funcMap <- readTVarIO stashRef
--         (os, resultMap) <- flip runStateT Map.empty . ifor xs $ \i x -> do
--             Map.lookup i funcMap & \case
--               Nothing -> liftIO setup >>= \r@(_, f) -> modify (Map.insert i r) *> liftIO (putStrLn $ "initializing: " <> show i) *> lift (f x)
--               Just r@(_, f) -> modify (Map.insert i r) *> lift (f x)
--         atomically $ writeTVar stashRef resultMap
--         pure os

-- build :: MonadIO m => m i -> (o -> m r) -> Build i o -> m r
-- build readInput handler (Build setup) = do
--     (_, f) <- liftIO setup
--     i <- readInput
--     o <- f i
--     handler o

-- -- TODO: properly accept input OR check env changes
watch :: IO i -> (o -> IO ()) -> Build i o -> IO a
watch readInput handler (Build setup) = do
    FW.withFileWatcher $ \fw -> do
      f <- setup
      forever $ do
        i <- readInput
        flip runContT handler . flip runReaderT fw $ f i

arrIO :: (i -> IO o) -> Build i o
arrIO f = Build (pure (liftIO . f))

-- readFile :: Build FilePath BS.ByteString
-- readFile = cacheEq (fileModified >>> (arrIO BS.readFile))

trace :: (Show a) => Build a a
trace = tap print

log :: String -> Build a a
log s = tap (const $ putStrLn s)

tap :: (a -> IO b) -> Build a a
tap f = arrIO $ \a -> f a *> pure a

-- fileModified :: Build FilePath FilePath
-- fileModified = Build $ do
--     (trigger, st) <- newTrigger
--     (fpRef, tRef, go) <- trackInput 0 $ \fp -> do
--         t <- modificationTime <$> liftIO (getFileStatus fp)
--         pure (t, fp)
--     void . forkIO . forever $ do
--         threadDelay 500000
--         fp <- atomically $ readTVar fpRef >>= maybe retrySTM pure
--         lastT <- readTVarIO tRef
--         currentT <- modificationTime <$> liftIO (getFileStatus fp)
--         if currentT > lastT then atomically (writeTVar tRef currentT >> trigger)
--                             else pure ()
--     pure $ (st, go)

-- Returns a new (trigger, waiter) pair.
-- The waiter will block until the trigger is executed.
-- The waiter should be called only once at a time.
newTrigger :: IO (IO (), IO ())
newTrigger = do
    var <- newTVarIO False
    pure (atomically $ writeTVar var True, atomically ((readTVar var >>= guard) <* writeTVar var False))

waitForChange :: Eq a => a -> TVar a -> STM ()
waitForChange a var = do
    a' <- readTVar var
    guard (a /= a')

trackInput :: MonadIO m => s -> (i -> m (s, o)) -> IO (TVar (Maybe i), TVar s, i -> m o)
trackInput def f = do
    inpRef <- newTVarIO Nothing
    stateRef <- newTVarIO def
    pure $ (inpRef,stateRef,) $ \i -> do
        atomically $ writeTVar inpRef (Just i)
        (s, o) <- f i
        atomically $ writeTVar stateRef s
        pure o

data Status = Dirty | Clean
  deriving (Eq, Ord, Show)

instance Semigroup Status where
  Clean <> Clean = Clean
  _ <> _ = Dirty

instance Monoid Status where
  mempty = Clean

cacheEq :: (Eq i) => Build i i
cacheEq = cached' eq

eq :: Eq a => a -> a -> Status
eq a b = if a == b then Clean else Dirty

watchFileHelper :: (MonadReader FW.FileWatcher m, MonadIO m) => FilePath -> (Event -> IO ()) -> m FW.StopWatching
watchFileHelper fp handler = ask >>= \fw -> liftIO (FW.watchFile fw fp handler)

-- watchFiles :: Build [FilePath] [FilePath]
-- watchFiles = Build $ do
--   lastFilesRef <- newTVarIO HM.empty
--   pure $ \fs -> do
--       lastFilesMap <- readTVarIO lastFilesRef
--       newLastFilesMap <- flip execStateT HM.empty $ for fs $ \path -> do
--           absPath <- liftIO $ makeAbsolute path
--           HM.lookup absPath lastFilesMap & \case
--             Nothing -> do
--                 cancelWatch <- watchFileHelper path . const $ _forceRerun
--                 modify (HM.insert absPath cancelWatch)
--             Just _ -> pure ()
--       let newlyRemoved = HM.difference lastFilesMap newLastFilesMap
--       -- Stop watching all files we no longer care about.
--       liftIO $ fold newlyRemoved
--       atomically $ writeTVar lastFilesRef newLastFilesMap
--       pure fs

watchFiles :: Build [FilePath] [FilePath]
watchFiles = Build $ do
  lastFilesRef <- newTVarIO HM.empty
  (trigger, waiter) <- newTrigger
  let inner = \fs -> do
        lastFilesMap <- readTVarIO lastFilesRef
        currentFilesMap <- flip execStateT HM.empty $ for fs $ \path -> do
            absPath <- liftIO $ makeAbsolute path
            HM.lookup absPath lastFilesMap & \case
              Nothing -> do
                  cancelWatch <- watchFileHelper absPath . const $ trigger
                  modify (HM.insert absPath cancelWatch)
              Just canceller -> modify (HM.insert absPath canceller)
        let newlyRemoved = HM.difference lastFilesMap currentFilesMap
        -- Stop watching all files we no longer care about.
        liftIO . print $ "Current files to watch: " <> show (HM.keys currentFilesMap)
        liftIO $ fold newlyRemoved
        atomically $ writeTVar lastFilesRef currentFilesMap
        pure fs
  pure (inner >=> retriggerOn waiter)

cached' :: (i -> i -> Status) -> Build i i
cached' inputDiff = Build $ do
    lastRunRef <- newTVarIO Nothing
    let rerun i = lift . shiftT $ \cc -> do
                    ccAsync <- liftIO . async $ cc i
                    atomically $ writeTVar lastRunRef $ Just (i, ccAsync)
                    pure ()
    pure $ \i -> do
        readTVarIO lastRunRef >>= \case
          Just (lastInput, lastCC)
            | inputDiff lastInput i == Clean -> do
                -- We can leave the previous continuation running in the async
                bail
            | otherwise -> do
                cancel lastCC
                rerun i
          Nothing -> rerun i

waitJust :: TVar (Maybe a) -> STM a
waitJust var = readTVar var >>= \case
  Nothing -> retrySTM
  Just a -> pure a

type Millis = Int
ticker :: Millis -> Build i i
ticker millis = Build $ do
  pure $ retriggerOn (threadDelay (millis * 1000))

-- |  After an initial run of a full build, this combinator will trigger a re-build
-- of all downstream dependents each time the given a trigger resolves.
-- The trigger should *block* until its condition has been fulfilled.
retriggerOn :: IO a -> (i -> t (ContT () IO) i)
retriggerOn waiter i = lift . shiftT $ \cc ->
    liftIO . forever $ do
      withAsync (cc i) $ \_ -> do
        waiter

-- | counter keeps track of how many times it has been retriggered.
counter :: Build i Int
counter = Build $ do
    nRef <- newTVarIO 0
    pure $ \_ -> do
        atomically $ do
            modifyTVar nRef succ
            readTVar nRef

exampleFileWatch :: IO ()
exampleFileWatch = do
  watch (pure ["deps.txt"]) (print) $ proc inp -> do
    deps <- arrIO (BS.readFile . head) <<< log "reading deps" <<< watchFiles -< inp
    let depFiles = BS.unpack <$> BS.lines deps
    -- if length depFiles > 2 then readFile -< "README.md"
    --                        else ticker 1000 <<< readFile -< "Changelog.md"
    log "DEPS:" <<< watchFiles -< depFiles

exampleTickerCache :: IO ()
exampleTickerCache = do
  watch (pure ()) (putStrLn) $ proc inp -> do
      cnt <- counter  <<< (ticker 500) <<< log "after cache" <<< cacheEq <<< counter <<< ticker 2000 -< inp
      r <- if even cnt
                     then ticker 500 -< cnt
                     else returnA -< cnt
      arr show -< r

example :: IO ()
example = exampleFileWatch

bail :: MonadTrans t => t (ContT () IO) a
bail = lift . shiftT $ \_cc -> pure ()

-- example :: IO ()
-- example = do
--     -- watch (pure "README.md") (BS.putStrLn) (readFile)
--     watch (pure "deps.txt") (BS.putStrLn) $ proc inp -> do
--         deps <- (cacheEq (tap <<< readFile)) -< inp
--         let depFiles = BS.unpack <$> BS.lines deps
--         if length depFiles > 2 then readFile -< "README.md"
--                                else ticker 1000 <<< readFile -< "Changelog.md"
--         -- itraverse' readFile -< Map.fromList ((\x -> (x, x)) <$> depFiles)
