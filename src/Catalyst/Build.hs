{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE KindSignatures #-}
module Catalyst.Build where
import Control.Arrow
import Control.Category ( Category )
import Control.Monad
import Control.Applicative
import Data.Profunctor ()
import qualified Data.ByteString.Char8 as BS
import Control.Category.Product
import Control.Category.Mon
import Control.Monad.IO.Class
import Data.Profunctor.Cayley
import Data.IORef (newIORef, readIORef, writeIORef, IORef)
import System.Posix.Files
import Prelude hiding (readFile)
import Control.Monad.State
import System.Posix (EpochTime)
import Control.Concurrent
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM

newtype Build (m :: * -> *) i o =
    Build (IO (IO Status, i -> m o))
    deriving (Category, Arrow) via (Cayley IO (CatProd (Mon (Tracker IO)) (Kleisli m)))

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
    let looper = forever $ do
          liftIO envCheck >>= \case
            Dirty -> void (readInput >>= f >>= handle)
            Clean -> pure ()
    looper

arrM :: (i -> m o) -> Build m i o
arrM f = Build (pure (mempty, f))

readFile :: MonadIO m => Build m FilePath BS.ByteString
readFile = cached (fileModified >>> arrM (liftIO . BS.readFile))

fileModified :: MonadIO m => Build m FilePath FilePath
fileModified = Build $ do
    (fpRef, go) <- trackInput $ pure
    let check' :: StateT (Maybe EpochTime) IO Status
        check' = do
            liftIO (readIORef fpRef) >>= \case
              Nothing -> pure Dirty
              Just fp -> do
                t <- modificationTime <$> liftIO (getFileStatus fp)
                get >>= \case
                  Just oldT
                    | oldT >= t -> pure Clean
                  _ -> put (Just t) *> pure Dirty
    checker <- ambient Nothing check'
    pure $ (checker, go)

trackInput :: MonadIO m => (i -> m o) -> IO (IORef (Maybe i), i -> m o)
trackInput f = do
    ref <- newIORef Nothing
    pure $ (ref,) $ \i -> do
        liftIO $ writeIORef ref (Just i)
        f i

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
          liftIO (readIORef lastRunRef) >>= \case
            Just (lastInput, o)
              | inputDiff lastInput i == Clean -> pure o
            _ -> do o <- f i
                    liftIO $ writeIORef lastRunRef (Just (i, o))
                    pure o
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
    watch (pure "README") (BS.putStrLn) (cached (debounced 1000) >>> markdownify >>> arrM BS.readFile)
  where
    markdownify = arrM $ \fp -> do
        Prelude.putStrLn $ "***" <> fp
        pure $ fp <> ".md"
