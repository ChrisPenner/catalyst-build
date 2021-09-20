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
import Control.Monad.IO.Class
import Data.Profunctor.Cayley
import Data.IORef (newIORef, readIORef, writeIORef, IORef)
import System.Posix.Files
import Prelude hiding (readFile)
import Control.Monad.State
import Control.Concurrent
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import Data.Function
import Data.Traversable.WithIndex
import qualified Data.Map as Map

newtype Build (m :: * -> *) i o =
    Build (IO (IO Status, i -> m o))
    deriving (Category, Arrow, Profunctor, Strong, Closed) via (Cayley IO (CatProd (Mon (Tracker IO)) (Kleisli m)))

data LR = L | R
  deriving (Eq)

-- The derived version is too greedy with regard to the Status check.
instance MonadIO m => Choice (Build m) where
  left' (Build setup) = Build $ do
      (envCheck, f) <- setup
      dirRef <- newIORef L
      let go = \case
                 Left a -> do
                     liftIO $ writeIORef dirRef L
                     Left <$> f a
                 Right x -> do
                     liftIO $ writeIORef dirRef R
                     pure $ Right x
      let newCheck = do
            readIORef dirRef >>= \case
              L -> envCheck
              R -> pure Clean
      pure $ (newCheck, go)

instance MonadIO m => ArrowChoice (Build m) where
  left = left'

-- The instance derived via Cayley only runs setup once, whereas we need to run it for each value
itraverse' :: (Show i, Ord i, MonadIO m, TraversableWithIndex i t) => Build m a b -> Build m (t a) (t b)
itraverse' (Build setup) = Build $ do
    stashRef <- newIORef Map.empty
    let envCheck = do
          readIORef stashRef >>= foldMap fst
    pure . (envCheck,) $ \xs -> do
        funcMap <- liftIO $ readIORef stashRef
        (os, resultMap) <- flip runStateT Map.empty . ifor xs $ \i x -> do
            Map.lookup i funcMap & \case
              Nothing -> liftIO setup >>= \r@(_, f) -> modify (Map.insert i r) *> liftIO (putStrLn $ "initializing: " <> show i) *> lift (f x)
              Just r@(_, f) -> modify (Map.insert i r) *> lift (f x)
        liftIO $ writeIORef stashRef resultMap
        pure os

newtype Tracker checkM =
    Tracker (checkM Status)

instance Applicative checkM => Semigroup (Tracker checkM) where
  Tracker l <> Tracker r = Tracker $ liftA2 (<>) l r

instance Applicative checkM => Monoid (Tracker checkM) where
  mempty = Tracker $ pure Clean

build :: MonadIO m => m i -> (o -> m r) -> Build m i o -> m r
build readInput handle (Build setup) = do
    (_, f) <- liftIO setup
    i <- readInput
    o <- f i
    handle o

watch :: (MonadIO m) => m i -> (o -> m r) -> Build m i o -> m a
watch readInput handle (Build setup) = do
    (envCheck, f) <- liftIO setup
    void (readInput >>= f >>= handle)
    let looper = forever $ do
          liftIO $ threadDelay 500000
          liftIO envCheck >>= \case
            Dirty -> void (readInput >>= f >>= handle)
            Clean -> pure ()
    looper

arrM :: (i -> m o) -> Build m i o
arrM f = Build (pure (mempty, f))

readFile :: MonadIO m => Build m FilePath BS.ByteString
readFile = cached (fileModified >>> (arrM (liftIO . BS.readFile)))

tap :: (MonadIO m, Show a) => Build m a a
tap = arrM $ \a -> liftIO (print a) *> pure a

fileModified :: MonadIO m => Build m FilePath FilePath
fileModified = Build $ do
    (fpRef, tRef, go) <- trackInput 0 $ \fp -> do
        t <- modificationTime <$> liftIO (getFileStatus fp)
        pure (t, fp)
    let check' :: IO Status
        check' = do
            liftIO (readIORef fpRef) >>= \case
              Nothing -> pure Dirty
              Just fp -> do
                -- liftIO getWorkingDirectory >>= liftIO . print
                lastT <- readIORef tRef
                currentT <- modificationTime <$> liftIO (getFileStatus fp)
                if lastT >= currentT
                     then pure Clean
                     else pure Dirty
    pure $ (check', go)

trackInput :: MonadIO m => s -> (i -> m (s, o)) -> IO (IORef (Maybe i), IORef s, i -> m o)
trackInput def f = do
    inpRef <- newIORef Nothing
    stateRef <- newIORef def
    pure $ (inpRef,stateRef,) $ \i -> do
        liftIO $ writeIORef inpRef (Just i)
        (s, o) <- f i
        liftIO $ writeIORef stateRef s
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
    (checker, f) <- setup
    lastRunRef <- newIORef Nothing
    let inner i = do
          let rerun = do o <- f i
                         liftIO $ writeIORef lastRunRef (Just (i, o))
                         pure o
          liftIO checker >>= \case
            Dirty -> rerun
            Clean -> do
              liftIO (readIORef lastRunRef) >>= \case
                Just (lastInput, o)
                  | inputDiff lastInput i == Clean -> pure o
                _ -> rerun
    pure (checker, inner)

ambient :: s -> StateT s IO Status -> IO (IO Status)
ambient initial next = do
    stateRef <- newIORef initial
    pure $ do
        (dirty, nextS) <- readIORef stateRef >>= runStateT next
        writeIORef stateRef nextS
        pure dirty

static :: Applicative m => Build IO i o -> i -> Build m () o
static (Build setup) i = Build $ do
    (checker, f) <- setup
    o <- f i
    pure $ (checker, const $ pure o)

type Millis = Int
debounced :: Applicative m => Millis -> Build m i i
debounced millis = Build $ do
    var <- newTVarIO Clean
    void . forkIO . forever $ atomically (writeTVar var Dirty) *> threadDelay (millis * 1000)
    pure $ (atomically (readTVar var <* writeTVar var Clean), pure)

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
