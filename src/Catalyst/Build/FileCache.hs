{-# LANGUAGE ScopedTypeVariables #-}
module Catalyst.Build.FileWatcher where
import System.FSNotify
import qualified StmContainers.Map as STMMap
import Data.Unique
import qualified Data.HashMap.Strict as HM
import UnliftIO
import Data.Functor

newtype FileWatcher = FileWatcher 
    { handlers :: STMMap.Map FilePath (HM.HashMap Unique (Event -> IO ()))
    }

withFileWatcher :: (FileWatcher -> IO a) -> IO a
withFileWatcher f = do
    filewatchMap <- STMMap.newIO
    withManager $ \wm -> do
        _cancel <- watchTree wm "." (const True) $ \evt -> do
            let pth = eventPath evt
            triggers <- atomically $ STMMap.lookup pth filewatchMap >>= \case
              Nothing -> pure mempty
              Just evtMap -> do
                  pure $ foldMap ($ evt) evtMap
            triggers
        f $ FileWatcher filewatchMap

type StopWatching = IO ()
watchFile :: FileWatcher -> FilePath -> (Event -> IO ()) -> IO StopWatching
watchFile (FileWatcher filewatchMap) path evtHandler = do
    unq <- newUnique
    atomically $ do
      hm <- STMMap.lookup path filewatchMap <&> \case
              Just hm -> HM.insert unq evtHandler hm
              Nothing -> HM.singleton unq evtHandler
      STMMap.insert hm path filewatchMap
    pure . atomically $ do
        STMMap.lookup path filewatchMap >>= \case
          Nothing -> pure ()
          Just hm' -> STMMap.insert (HM.delete unq hm') path filewatchMap
