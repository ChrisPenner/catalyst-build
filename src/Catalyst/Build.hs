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
import qualified Data.ByteString.Char8 as BS
import Control.Category.Product
import Control.Category.Mon
import Data.Profunctor.Cayley
import System.Posix.Files
import Prelude hiding (readFile)
import Control.Monad.State
import Data.Function
import Data.Traversable.WithIndex
import qualified Data.Map as Map
import Data.Maybe
import UnliftIO
import UnliftIO.Concurrent

newtype Build (m :: * -> *) i o =
    Build (IO (StatusTracker, i -> m o))
    deriving (Category, Arrow, Profunctor, Strong, Closed) via (Cayley IO (CatProd (Mon StatusTracker) (Kleisli m)))

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

-- The derived version is too greedy with regard to the Status check.
instance MonadIO m => Choice (Build m) where
  left' (Build setup) = Build $ do
      (ST envCheck, f) <- setup
      dirRef <- newTVarIO L
      let go = \case
                 Left a -> do
                     atomically . writeTVar dirRef $ L
                     Left <$> f a
                 Right x -> do
                     atomically $ writeTVar dirRef R
                     pure $ Right x
      let newCheck = do
            readTVar dirRef >>= \case
              L -> envCheck
              R -> retrySTM
      pure $ (ST newCheck, go)

instance MonadIO m => ArrowChoice (Build m) where
  left = left'

-- The instance derived via Cayley only runs setup once, whereas we need to run it for each value
itraverse' :: (Show i, Ord i, MonadIO m, TraversableWithIndex i t) => Build m a b -> Build m (t a) (t b)
itraverse' (Build setup) = Build $ do
    stashRef <- newTVarIO Map.empty
    let envCheck = ST $ do
          readTVar stashRef >>= runStatusTracker . foldMap fst
    pure . (envCheck,) $ \xs -> do
        funcMap <- readTVarIO stashRef
        (os, resultMap) <- flip runStateT Map.empty . ifor xs $ \i x -> do
            Map.lookup i funcMap & \case
              Nothing -> liftIO setup >>= \r@(_, f) -> modify (Map.insert i r) *> liftIO (putStrLn $ "initializing: " <> show i) *> lift (f x)
              Just r@(_, f) -> modify (Map.insert i r) *> lift (f x)
        atomically $ writeTVar stashRef resultMap
        pure os

build :: MonadIO m => m i -> (o -> m r) -> Build m i o -> m r
build readInput handler (Build setup) = do
    (_, f) <- liftIO setup
    i <- readInput
    o <- f i
    handler o

-- TODO: properly accept input OR check env changes
watch :: (MonadIO m) => STM i -> (o -> m r) -> Build m i o -> m a
watch readInput handler (Build setup) = do
    (ST envCheck, f) <- liftIO setup
    void (atomically readInput >>= f >>= handler)
    forever $ do
          threadDelay 500000
          atomically envCheck -- wait for env changes
          void (atomically readInput >>= f >>= handler)

arrM :: (i -> m o) -> Build m i o
arrM f = Build (pure (mempty, f))

arrIO :: MonadIO m => (i -> IO o) -> Build m i o
arrIO f = Build (pure (mempty, liftIO . f))

readFile :: MonadIO m => Build m FilePath BS.ByteString
readFile = cached (fileModified >>> (arrIO BS.readFile))

tap :: (MonadIO m, Show a) => Build m a a
tap = arrIO $ \a -> print a *> pure a

fileModified :: MonadIO m => Build m FilePath FilePath
fileModified = Build $ do
    (trigger, st) <- newTrigger
    (fpRef, tRef, go) <- trackInput 0 $ \fp -> do
        t <- modificationTime <$> liftIO (getFileStatus fp)
        pure (t, fp)
    void . forkIO . forever $ do
        threadDelay 500000
        fp <- atomically $ readTVar fpRef >>= maybe retrySTM pure
        lastT <- readTVarIO tRef
        currentT <- modificationTime <$> liftIO (getFileStatus fp)
        if currentT > lastT then atomically (writeTVar tRef currentT >> trigger)
                            else pure ()
    pure $ (st, go)

newTrigger :: IO (STM (), StatusTracker)
newTrigger = do
    var <- newTVarIO False
    pure (writeTVar var True, ST ((readTVar var >>= guard) <* writeTVar var False))

waitForChange :: Eq a => a -> TVar a -> STM ()
waitForChange a var = do
    a' <- readTVar var
    guard (a /= a')

-- fileWatch :: 

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

cached :: (Eq i, MonadIO m) => Build m i o -> Build m i o
cached = cached' eq

eq :: Eq a => a -> a -> Status
eq a b = if a == b then Clean else Dirty

cached' :: MonadIO m => (i -> i -> Status) -> Build m i o -> Build m i o
cached' inputDiff (Build setup) = Build $ do
    (ST checker, f) <- setup
    (dirtify, ST checkDirty) <- newTrigger
    lastRunRef <- newTVarIO Nothing
    let inner i = do
          let rerun = do o <- f i
                         atomically $ writeTVar lastRunRef (Just (i, o))
                         pure o
          atomically (optional checkDirty) >>= \case
            Just _ -> rerun
            Nothing -> do
              readTVarIO lastRunRef >>= \case
                Just (lastInput, o)
                  | inputDiff lastInput i == Clean -> pure o
                _ -> rerun
    pure (ST (checker *> dirtify), inner)

waitJust :: TVar (Maybe a) -> STM a
waitJust var = readTVar var >>= \case
  Nothing -> retrySTM
  Just a -> pure a

static :: Applicative m => Build IO i o -> i -> Build m () o
static (Build setup) i = Build $ do
    (checker, f) <- setup
    o <- f i
    pure $ (checker, const $ pure o)

type Millis = Int
debounced :: Applicative m => Millis -> Build m i i
debounced millis = Build $ do
    (trigger, st) <- newTrigger
    void . forkIO . forever $ atomically trigger *> threadDelay (millis * 1000)
    pure $ (st, pure)

example :: IO ()
example = do
    -- watch (pure "README.md") (BS.putStrLn) (readFile)
    watch (pure "deps.txt") (BS.putStrLn) $ proc inp -> do
        deps <- (cached (tap <<< readFile)) -< inp
        let depFiles = BS.unpack <$> BS.lines deps
        if length depFiles > 2 then readFile -< "README.md"
                               else debounced 1000 <<< readFile -< "Changelog.md"
        -- itraverse' readFile -< Map.fromList ((\x -> (x, x)) <$> depFiles)
  where
    printFile = \name f -> do
        BS.putStrLn (BS.pack name <> "===================")
        BS.putStrLn f
