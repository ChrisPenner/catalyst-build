{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedStrings #-}
module Catalyst.Build where
import Control.Arrow
import Control.Category ( Category )
import Control.Monad
import Control.Applicative
import Data.Profunctor (Profunctor, Choice, Closed)
import qualified Data.ByteString.Char8 as BS
import Control.Category.Product
import Control.Category.Mon
import Control.Monad.IO.Class
import Data.Profunctor.Cayley
import Data.IORef (newIORef, readIORef, writeIORef, IORef)
import System.Posix.Files
import Prelude hiding (readFile)
import Control.Monad.State
import System.Posix (EpochTime, getWorkingDirectory)
import Control.Concurrent
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import Data.Profunctor.Strong
import Data.Profunctor.Traversing
import qualified Data.IntMap as IM
import qualified Data.Bifunctor as BF
import Data.Function
import Data.Traversable

newtype Build (m :: * -> *) i o =
    Build (IO (IO Status, i -> m o))
    deriving (Category, Arrow, Profunctor, Choice, Strong, Closed) via (Cayley IO (CatProd (Mon (Tracker IO)) (Kleisli m)))

-- The instance derived via Cayley only runs setup once, whereas we need to run it for each value
instance MonadIO m => Traversing (Build m) where
  traverse' (Build setup) = Build $ do
      stashRef <- newIORef IM.empty
      let envCheck = do
            readIORef stashRef >>= foldMap fst
      pure . (envCheck,) $ \xs -> do
          funcMap <- liftIO $ readIORef stashRef
          (os, (resultMap, splitPoint)) <- flip runStateT (funcMap, 0) . for xs $ \x -> do
              (innerMap, i) <- get
              modify (second succ)
              IM.lookup i innerMap & \case
                Nothing -> liftIO setup >>= \r@(_, f) -> modify (BF.first (IM.insert i r)) *> liftIO (putStrLn $ "initializing: " <> show i) *> lift (f x)
                Just (_, f) -> lift $ f x
          let (prunedMap, _) = IM.split splitPoint resultMap
          liftIO $ writeIORef stashRef prunedMap
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
    watch (pure "deps.txt") (traverse printFile) $ proc inp -> do
        deps <- (cached (tap <<< readFile)) -< inp
        traverse' readFile -< BS.unpack <$> BS.lines deps
  where
    printFile = \f -> do
        BS.putStrLn "==================="
        BS.putStrLn f
    markdownify = arrM $ \fp -> do
        Prelude.putStrLn $ "***" <> fp
        pure $ fp <> ".md"
