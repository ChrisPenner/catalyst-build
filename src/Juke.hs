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
{-# LANGUAGE FlexibleInstances #-}
module Juke (Juke(..), Builder, retriggerOn, newEmptyCVarIO, waitCVar, putCVar, peekCVar, cachedEq, asyncWithCleanup) where

import Control.Arrow
import qualified Control.Category as C
import Control.Monad
import Control.Applicative hiding (WrappedArrow)
import Data.Profunctor.Cayley
import Prelude hiding (readFile, log)
import Control.Monad.State
import UnliftIO
import UnliftIO.Concurrent
import Control.Monad.Trans.Cont
import Control.Monad.Reader
import qualified Juke.FileWatcher as FW
import System.FSNotify
import qualified Data.HashMap.Strict as HM
import System.Directory
import Data.Traversable
import Data.Function
import Data.Foldable
import qualified Data.ByteString.Char8 as BS
import Data.Profunctor
import Data.Traversable.WithIndex
import qualified StmContainers.Map as StmMap
import Data.Hashable
import Data.Functor.WithIndex

newtype Juke ctx i o =
    Juke (IO (i -> Builder ctx o))
    deriving (Profunctor, C.Category, ArrowChoice) via (Cayley IO (Kleisli (Builder ctx)))
    deriving (Strong, Choice) via WrappedArrow (Juke ctx)

newtype Builder ctx a = Builder {runBuilder ::  (ContT () (Inner ctx)) a}
  deriving (Functor, Applicative, Monad, MonadIO)

type Inner ctx = (ReaderT (FW.FileWatcher, ctx) IO)

instance MonadReader (ctx) (Builder ctx) where
  ask = Builder $ asks snd
  local f (Builder m) = Builder (local (second f)$ m)

newtype ParBuild ctx a = ParBuild { runParBuild :: Builder ctx a}
  deriving Functor

instance Applicative (ParBuild ctx) where
  pure = ParBuild . pure
  liftA2 f (ParBuild a) (ParBuild b) = ParBuild $ par2 f a b

data BuildInvalidated = BuildInvalidated
  deriving Show
instance Exception BuildInvalidated where

instance Arrow (Juke ctx) where
  arr f = Juke $ pure (pure . f)
  Juke setupL *** Juke setupR = Juke $ do
    (lf, rf) <- concurrently setupL setupR
    pure $ \(l, r) -> do
      par2 (,) (lf l) (rf r)

par2 :: forall ctx a b c. (a -> b -> c) -> Builder ctx a -> Builder ctx b -> Builder ctx c
par2 f (Builder l) (Builder r) = Builder $ do
  lVar <- newEmptyCVarIO
  rVar <- newEmptyCVarIO
  let ioL :: Inner ctx () = flip runContT (atomically . putCVar lVar) $ l
  let ioR :: Inner ctx () = flip runContT (atomically . putCVar rVar) $ r
  -- This blocks until we have a new result from EITHER side
  let waitNext :: Inner ctx c
      waitNext = atomically $ do
                   liftA2 f (waitCVar lVar) (waitCVar rVar)
                     <|> liftA2 f (waitCVar lVar) (peekCVar rVar)
                     <|> liftA2 f (peekCVar lVar) (waitCVar rVar)
  -- capture downstream continuation
  shiftT $ \cc -> do
    -- Kick off each side of the computation
    lift $ withAsync ioL . const . withAsync ioR . const $ do
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

-- It's possible to write version of this with only an Ord constraint, just haven't done it yet.
-- It would add more lock contention
itraversed :: (Hashable i, TraversableWithIndex i t, Eq i) => Juke ctx a b -> Juke ctx (t a) (t b)
itraversed f = lmap (imap (,)) (traversedWithKey fst (lmap snd f))

-- It's possible to write version of this with only an Ord constraint, just haven't done it yet.
-- It would add more lock contention
traversedWithKey :: (Hashable k, Eq k, Traversable t) => (a -> k) -> Juke ctx a b -> Juke ctx (t a) (t b)
traversedWithKey getKey (Juke setup) = Juke $ do
    stashRef <- StmMap.newIO
    pure $ \xs -> do
         -- Initialize and run all setups concurrently
         runParBuild . for xs $ \x -> ParBuild $ do
           let key = getKey x
           atomically (StmMap.lookup key stashRef) >>= \case
             Nothing -> do
               f <- liftIO setup
               atomically (StmMap.insert f key stashRef)
               f x
             Just f -> do
               f x

-- -- TODO: properly accept input OR check env changes
watch :: ctx -> IO i -> (o -> IO ()) -> Juke ctx i o -> IO a
watch ctx readInput handler (Juke setup) = do
    FW.withFileWatcher $ \fw -> do
      f <- setup
      forever $ do
        i <- readInput
        flip runReaderT (fw, ctx) . flip runContT (liftIO . handler) . runBuilder $ f i

arrIO :: (i -> IO o) -> Juke ctx i o
arrIO f = Juke (pure (liftIO . f))

-- readFile :: Juke ctx FilePath BS.ByteString
-- readFile = cacheEq (fileModified >>> (arrIO BS.readFile))

trace :: (Show a) => Juke ctx a a
trace = tap print

log :: String -> Juke ctx a a
log s = tap (const $ putStrLn s)

tap :: (a -> IO b) -> Juke ctx a a
tap f = arrIO $ \a -> f a *> pure a

cachedEq :: Eq i => Juke ctx i o -> Juke ctx i o
cachedEq = cachedOn id

cachedOn :: Eq a => (i -> a) -> Juke ctx i o -> Juke ctx i o
cachedOn project = cachedBy (eq `on` project)

cachedBy :: (i -> i -> Status) -> Juke ctx i o -> Juke ctx i o
cachedBy comp (Juke setup) = Juke $ do
  go <- setup
  lastRunInput <- newTVarIO Nothing
  lastRunOutput <- newTVarIO Nothing
  let rerun i = do
        o <- go i
        liftIO $ atomically $ do
          writeTVar lastRunInput (Just i)
          writeTVar lastRunOutput (Just o)
        pure o
  pure $ \i -> do
    readTVarIO lastRunInput >>= \case
      Nothing -> do
        rerun i
      Just lastI -> do
        mo <- readTVarIO lastRunOutput
        case (comp lastI i, mo) of
          (Clean, Just o) -> pure o
          _ -> rerun i

cutEq :: Eq i => Juke ctx i i
cutEq = cutOn id

cutOn :: Eq a => (i -> a) -> Juke ctx i i
cutOn project = cutBy (eq `on` project)

-- Don't retrigger the continuation unless the input has meaningfully changed.
-- Leaves the old continuation running in the background.
cutBy :: (i -> i -> Status) -> Juke ctx i i
cutBy comp = Juke $ do
  lastRunInput <- newTVarIO Nothing
  lastRunRef <- newTVarIO Nothing
  let rerun i = Builder $ do
        atomically $ writeTVar lastRunInput (Just i)
        -- Cancel any existing run
        readTVarIO lastRunRef >>= maybe (pure ()) cancel
        shiftT $ \cc -> do
          -- TODO: add some masked sections here for exception safety.
          ref <- lift $ async (cc i)
          atomically $ writeTVar lastRunRef (Just ref)
  pure $ \i -> do
    readTVarIO lastRunInput >>= \case
      Nothing -> do
        rerun i
      Just lastI -> do
        case comp lastI i of
          Clean -> bail
          _ -> rerun i

  -- left' (Tester f) = Tester $ \case
  --   Nothing -> Left <$> f Nothing
  --   Just (Left a) -> Left <$> f (Just a)
  --   Just (Right b) -> pure $ Right b



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

eq :: Eq a => a -> a -> Status
eq a b = if a == b then Clean else Dirty

watchFileHelper :: FilePath -> (Event -> IO ()) -> Builder ctx FW.StopWatching
watchFileHelper fp handler = Builder $ do
  asks fst >>= \fw -> liftIO (FW.watchFile fw fp handler)

watchFiles :: Juke ctx [FilePath] [FilePath]
watchFiles = Juke $ do
  lastFilesRef <- newTVarIO HM.empty
  (trigger, waiter) <- newTrigger
  pure $ \fs -> do
        lastFilesMap <- readTVarIO lastFilesRef
        currentFilesMap <- flip execStateT HM.empty $ for fs $ \path -> do
            absPath <- liftIO $ makeAbsolute path
            HM.lookup absPath lastFilesMap & \case
              Nothing -> do
                  cancelWatch <- lift . watchFileHelper absPath . const $ trigger
                  modify (HM.insert absPath cancelWatch)
              Just canceller -> modify (HM.insert absPath canceller)
        let newlyRemoved = HM.difference lastFilesMap currentFilesMap
        -- Stop watching all files we no longer care about.
        liftIO . print $ "Current files to watch: " <> show (HM.keys currentFilesMap)
        liftIO $ fold newlyRemoved
        atomically $ writeTVar lastFilesRef currentFilesMap
        retriggerOn () waiter
        pure fs

waitJust :: TVar (Maybe a) -> STM a
waitJust var = readTVar var >>= \case
  Nothing -> retrySTM
  Just a -> pure a

type Millis = Int
ticker :: Millis -> Juke ctx i i
ticker millis = Juke $ do
  pure $ \i -> retriggerOn () (threadDelay (millis * 1000)) *> pure i

-- |  After an initial run of a full build, this combinator will trigger a re-build
-- of all downstream dependents each time the given a trigger resolves.
-- The trigger should *block* until its condition has been fulfilled.
retriggerOn :: a -> IO a -> Builder ctx a
retriggerOn fstA waiter = Builder $ shiftT $ \cc -> do
  let looper a = do
         nextA <- lift $ withAsync (cc a) $ const (liftIO waiter)
         looper nextA
  looper fstA

-- Never is a build-step which NEVER calls its continuation, and never completes
never :: Juke ctx i x
never = Juke $ do
  pure $ \_ -> forever $ threadDelay 1000000000

-- | counter keeps track of how many times it has been retriggered.
counter :: Juke ctx i Int
counter = Juke $ do
    nRef <- newTVarIO 0
    pure $ \_ -> do
        atomically $ do
            modifyTVar nRef succ
            readTVar nRef

exampleFileWatch :: IO ()
exampleFileWatch = do
  watch () (pure ["deps.txt"]) (print) $ proc inp -> do
    deps <- arrIO (BS.readFile . head) <<< log "reading deps" <<< clever "*** Shallow" <<< watchFiles -< inp
    let depFiles = BS.unpack <$> BS.lines deps
    -- if length depFiles > 2 then readFile -< "README.md"
    --                        else ticker 1000 <<< readFile -< "Changelog.md"
    log "DEPS:" <<< ticker 1000 <<< clever "*** Deepest" <<< watchFiles <<< clever "*** Deep" -< depFiles

clever :: String -> Juke ctx i i
clever s = Juke $ do
  pure $ \i -> do
    liftIO $ bracketOnError (pure ()) (const $ print s) $ (const $ threadDelay 10000000)
    pure i

-- bracketInterrupts :: IO a -> (a -> IO b) -> (a -> IO c) -> Builder ctx c
-- bracketInterrupts initialize cleanup go = Builder $ do
--   lift . shiftT $ \cc -> do
--     lift $ bracket initialize cleanup (go >=> cc)

bracketInterrupts' :: ReaderT (FW.FileWatcher, ctx) IO a -> (a -> ReaderT (FW.FileWatcher, ctx) IO b) -> Builder ctx a
bracketInterrupts' initialize cleanup = Builder $ do
  shiftT $ lift . bracket initialize cleanup

-- bracketInterrupts_ :: IO a -> IO b -> IO c -> Builder ctx c
-- bracketInterrupts_ initialize cleanup go =
--   bracketInterrupts initialize (const cleanup) (const go)

-- onInterrupts :: IO a -> IO b -> Builder ctx a
-- onInterrupts go cleanup = do
--   bracketInterrupts_ (pure ()) cleanup go

exampleTickerCache :: IO ()
exampleTickerCache = do
  watch () (pure ()) (print) $ proc inp -> do
      cachedEq (counter <<< log "inside cache") <<< ticker 300 <<< counter <<< ticker 2000 -< inp

exampleTickerCut :: IO ()
exampleTickerCut = do
  watch () (pure ()) (print) $ proc inp -> do
      log "after cache" <<< cutEq <<< ticker 100 <<< counter <<< ticker 3000 -< inp

exampleStrong :: IO ()
exampleStrong = do
  watch () (pure ((),())) (print) $ proc inp -> do
    counter <<< never <<< log "JOIN" <<< (log "LEFT" <<< watchFiles <<< arr (const ["ChangeLog.md"])) *** (log "RIGHT" <<< watchFiles <<< arr (const ["README.md"])) -< inp

exampleTraversed :: IO ()
exampleTraversed = do
  watch () (pure [1, 2, 3, 4]) (print) $ proc inp -> do
    itraversed trace <<< arr (\x -> replicate x x) <<< counter <<< ticker 1000 -< inp

example :: IO ()
example = exampleTickerCut

bail :: Builder ctx a
bail = Builder $ shiftT $ \_cc -> pure ()

asyncWithCleanup :: Inner ctx () -> Builder ctx ()
asyncWithCleanup eff = Builder $ do
  shiftT $ \cc -> do
    lift $ withAsync eff $ \_ -> do
      cc ()

-- example :: IO ()
-- example = do
--     -- watch (pure "README.md") (BS.putStrLn) (readFile)
--     watch (pure "deps.txt") (BS.putStrLn) $ proc inp -> do
--         deps <- (cacheEq (tap <<< readFile)) -< inp
--         let depFiles = BS.unpack <$> BS.lines deps
--         if length depFiles > 2 then readFile -< "README.md"
--                                else ticker 1000 <<< readFile -< "Changelog.md"
--         -- itraverse' readFile -< Map.fromList ((\x -> (x, x)) <$> depFiles)
