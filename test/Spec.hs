{-# LANGUAGE Arrows #-}
import Test.Hspec
import Juke.Internal
import Control.Arrow
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM


assertOutput :: (Eq o, Show o) => [o] -> i -> Juke () i o -> Expectation
assertOutput expectedOut i j = do
  q <- newTQueueIO
  run () i (atomically . writeTQueue q) j
  results <- atomically $ flushTQueue q
  results `shouldBe` expectedOut


main :: IO ()
main = hspec $ do
  describe "ArrowStrong" $ do
    it "should terminate when run" $ do
        assertOutput [('l', 'r')] () $ proc i -> do
          a <- returnA -< 'l'
          b <- returnA -< 'r'
          returnA -< (a, b)
