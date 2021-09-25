{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
module Juke.FileWatcher where
import System.FSNotify
import qualified StmContainers.Map as STMMap
import Data.Unique
import qualified Data.HashMap.Strict as HM
import UnliftIO
import Data.Functor

newtype FileWatcher = FileWatcher 
    { handlers :: STMMap.Map FilePath (HM.HashMap Unique (Event -> IO ()))
    }

withFileWatcher :: MonadUnliftIO m => (FileWatcher -> m a) -> m a
withFileWatcher f = do
    filewatchMap <- liftIO $ STMMap.newIO
    withManager' $ \wm -> do
        _cancel <- liftIO $ watchTree wm "." (const True) $ \evt -> do
            let pth = eventPath evt
            triggers <- atomically $ STMMap.lookup pth filewatchMap >>= \case
              Nothing -> pure mempty
              Just evtMap -> do
                  pure $ foldMap ($ evt) evtMap
            liftIO triggers
        f $ FileWatcher filewatchMap

withManager' :: MonadUnliftIO m => (WatchManager -> m a) -> m a
withManager' f = bracket (liftIO $ startManager) (liftIO . stopManager) f

type StopWatching = IO ()
watchFile :: FileWatcher -> FilePath -> (Event -> IO ()) -> IO StopWatching
watchFile (FileWatcher filewatchMap) path eHandler = do
    print $ "Adding watcher for: " <> path
    let evtHandler evt = do
          print $ path <> " Updated!"
          eHandler evt
    unq <- newUnique
    atomically $ do
      hm <- STMMap.lookup path filewatchMap <&> \case
              Just hm -> HM.insert unq evtHandler hm
              Nothing -> HM.singleton unq evtHandler
      STMMap.insert hm path filewatchMap
    pure $ do
      print $ "Deleting watcher for: " <> path
      atomically $ do
        STMMap.lookup path filewatchMap >>= \case
          Nothing -> pure ()
          Just hm' -> STMMap.insert (HM.delete unq hm') path filewatchMap
