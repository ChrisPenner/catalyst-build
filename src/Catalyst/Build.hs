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
{-# LANGUAGE ScopedTypeVariables #-}
module Catalyst.Build where
import Control.Arrow
import Control.Category ( Category )
import Control.Monad
import Control.Applicative
import Data.Profunctor
import Data.Profunctor.Cayley
import Prelude hiding (readFile, log)
import Control.Monad.State
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
    Build (IO (i -> BuildM o))
    deriving (Category, Profunctor, Strong, Choice, ArrowChoice) via (Cayley IO (Kleisli BuildM))

type BuildM = (ReaderT FW.FileWatcher (ContT () IO))

data BuildInvalidated = BuildInvalidated
  deriving Show
instance Exception BuildInvalidated where

instance Arrow Build where
  arr f = Build $ pure (pure . f)
  Build setupL *** Build setupR = Build $ do
    (lf, rf) <- concurrently setupL setupR
    pure $ \(l, r) -> do
      par2 (,) (lf l) (rf r)

par2 :: forall a b c. (a -> b -> c) -> BuildM a -> BuildM b -> BuildM c
par2 f l r = do
  lVar <- newEmptyCVarIO
  rVar <- newEmptyCVarIO
  fm <- ask
  let ioL :: IO () = flip runContT (atomically . putCVar lVar) . flip runReaderT fm $ l
  let ioR :: IO () = flip runContT (atomically . putCVar rVar) . flip runReaderT fm $ r
  -- This blocks until we have a new result from EITHER side
  let waitNext = atomically $ do
                   liftA2 f (waitCVar lVar) (waitCVar rVar)
                     <|> liftA2 f (waitCVar lVar) (peekCVar rVar)
                     <|> liftA2 f (peekCVar lVar) (waitCVar rVar)
  -- capture downstream continuation
  lift . shiftT $ \cc -> do
    -- Kick off each side of the computation
    liftIO $ withAsync ioL . const . withAsync ioR . const $ do
        -- This runs the continuatin until a change is detected on one of our sides
        let looper res = do
              nextRes <- withAsync (cc res) $ \_ -> waitNext
              looper nextRes
        -- Wait for a first result from both sides before we can start the loop.
        waitNext >>= looper

newtype CVar a = CVar (TVar (Maybe (a, Bool)))

newEmptyCVarIO :: MonadIO m => m (CVar a)
newEmptyCVarIO = CVar <$> newTVarIO Nothing

putCVar :: CVar a -> a -> STM ()
putCVar (CVar v) a = writeTVar v $ Just (a, True)

-- Only ONE listener will consume each change to a CVar.
waitCVar :: CVar a -> STM a
waitCVar (CVar v) = do
  readTVar v >>= \case
    Just (a, True) -> writeTVar v (Just (a, False)) *> pure a
    _ -> retrySTM

-- | peek at the value in a CVar regardless of changes, don't consume changes if they exist.
peekCVar :: CVar a -> STM a
peekCVar (CVar v) = do
  readTVar v >>= \case
    Just (a, _) -> pure a
    _ -> retrySTM

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
  pure $ \fs -> do
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
        retriggerOn waiter
        pure fs

cached' :: (i -> i -> Status) -> Build i i
cached' inputDiff = Build $ do
    lastRunRef <- newTVarIO Nothing
    let rerun i = lift . shiftT $ \cc -> do
                    ccAsync <- liftIO . async $ cc i
                    atomically $ writeTVar lastRunRef $ Just (i, ccAsync)
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
  pure $ \i -> retriggerOn (threadDelay (millis * 1000)) *> pure i

-- |  After an initial run of a full build, this combinator will trigger a re-build
-- of all downstream dependents each time the given a trigger resolves.
-- The trigger should *block* until its condition has been fulfilled.
retriggerOn :: IO a -> BuildM ()
retriggerOn waiter = lift . shiftT $ \cc ->
    liftIO . forever $ do
      -- ccA <- async (cc i)
      -- void waiter
      -- cancel ccA
      withAsync (cc ()) $ \_ -> do
        void waiter

-- Never is a build-step which NEVER calls its continuation, and never completes
never :: Build i x
never = Build $ do
  pure $ \_ -> forever $ threadDelay 1000000000

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
    deps <- arrIO (BS.readFile . head) <<< log "reading deps" <<< clever "*** Shallow" <<< watchFiles -< inp
    let depFiles = BS.unpack <$> BS.lines deps
    -- if length depFiles > 2 then readFile -< "README.md"
    --                        else ticker 1000 <<< readFile -< "Changelog.md"
    log "DEPS:" <<< ticker 1000 <<< clever "*** Deepest" <<< watchFiles <<< clever "*** Deep" -< depFiles

clever :: String -> Build i i
clever s = Build $ do
  pure $ \i -> do
    liftIO $ bracketOnError (pure ()) (const $ print s) $ (const $ threadDelay 10000000)
    pure i

bracketInterrupts :: IO a -> (a -> IO b) -> (a -> IO c) -> BuildM c
bracketInterrupts initialize cleanup go = do
  lift . shiftT $ \cc -> do
    lift $ bracket initialize cleanup (go >=> cc)

bracketInterrupts' :: IO a -> (a -> IO b) -> ContT () IO a
bracketInterrupts' initialize cleanup = do
  shiftT $ lift . bracket initialize cleanup

bracketInterrupts_ :: IO a -> IO b -> IO c -> BuildM c
bracketInterrupts_ initialize cleanup go =
  bracketInterrupts initialize (const cleanup) (const go)

onInterrupts :: IO a -> IO b -> BuildM a
onInterrupts go cleanup = do
  bracketInterrupts_ (pure ()) cleanup go

exampleTickerCache :: IO ()
exampleTickerCache = do
  watch (pure ()) (putStrLn) $ proc inp -> do
      cnt <- counter <<< (ticker 500) <<< log "after cache" <<< cacheEq <<< counter <<< ticker 2000 -< inp
      r <- if even cnt
                     then ticker 500 -< cnt
                     else returnA -< cnt
      arr show -< r

exampleStrong :: IO ()
exampleStrong = do
  watch (pure ((),())) (print) $ proc inp -> do
    counter <<< never <<< log "JOIN" <<< (log "LEFT" <<< watchFiles <<< arr (const ["ChangeLog.md"])) *** (log "RIGHT" <<< watchFiles <<< arr (const ["README.md"])) -< inp


example :: IO ()
example = exampleStrong

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
