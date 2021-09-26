{-# LANGUAGE Arrows #-}
import Test.Hspec
import Juke.Internal
import Control.Arrow
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM
import Juke.Stream


assertOutput :: (Eq o, Show o) => [o] -> i -> Juke () i o -> Expectation
assertOutput expectedOut i j = do
  q <- newTQueueIO
  run () i (atomically . writeTQueue q) j
  results <- atomically $ flushTQueue q
  results `shouldBe` expectedOut


main :: IO ()
main = hspec $ do
  describe "run - termination" $ do
    it "should terminate when ArrowStrong is used" $ do
        assertOutput [('l', 'r')] () $ proc inp -> do
          a <- returnA -< 'l'
          b <- returnA -< 'r'
          returnA -< (a, b)

    it "should terminate when Choice is used" $ do
        assertOutput ["true"] True $ proc inp -> do
          if inp then returnA -< "true"
                 else returnA -< "false"

  describe "Stream" $ do
    describe "folded" $ do
      it "should fold all items" $ do
        assertOutput [1 :: Int, 2, 3] [1 :: Int, 2, 3] $ folded
    describe "take" $ do
      it "should take n then stop" $ do
        assertOutput [1, 2, 3] [1, 2, 3, 4, 5] $ folded >>> taking 3

