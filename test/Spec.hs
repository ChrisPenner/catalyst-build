{-# LANGUAGE Arrows #-}
{-# LANGUAGE LambdaCase #-}
import Test.Hspec
import Juke.Internal
import Control.Arrow
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM
import Juke.Stream
import Juke.React
import UnliftIO.Async
import Control.Concurrent
import Control.Monad.IO.Class


assertOutputExact :: (Eq o, Show o) => [o] -> i -> Juke Context i o -> Expectation
assertOutputExact expectedOut i j = do
  q <- newTQueueIO
  run mempty i (atomically . writeTQueue q) j
  results <- atomically $ flushTQueue q
  results `shouldBe` expectedOut

assertOutputPrefix :: (Eq o, Show o) => [o] -> i -> Juke Context i o -> Expectation
assertOutputPrefix expectedOut i j = do
  q <- newTQueueIO
  let lenOutput = length expectedOut
  let checkOutput = atomically $ do
        os <- flushTQueue q
        if length os >= lenOutput then pure (take lenOutput os)
                                  else retry

  actualOutput <- race (watch mempty i (atomically . writeTQueue q) j) checkOutput >>= \case
    Left _ -> atomically $ flushTQueue q
    Right os -> pure os
  actualOutput `shouldBe` expectedOut

main :: IO ()
main = hspec $ do
  describe "run - termination" $ do
    it "should terminate when ArrowStrong is used" $ do
        assertOutputExact [('l', 'r')] () $ proc inp -> do
          a <- returnA -< 'l'
          b <- returnA -< 'r'
          returnA -< (a, b)

    it "should terminate when Choice is used" $ do
        assertOutputExact ["true"] True $ proc inp -> do
          if inp then returnA -< "true"
                 else returnA -< "false"

  describe "watch - concurrency" $ do
    it "should emit from Strong pairings when EITHER side changes (after first emisison)" $ do
      assertOutputExact [(1, 'r'), (2, 'r'), (3, 'r')] () $ proc inp -> do
          l <- folded -< [1, 2, 3]
          r <- returnA -< 'r'
          returnA -< (l, r)

  describe "Stream" $ do
    describe "folded" $ do
      it "should fold all items" $ do
        assertOutputExact [1 :: Int, 2, 3] [1 :: Int, 2, 3] $ folded
    describe "take" $ do
      it "should take n then stop" $ do
        assertOutputExact [1, 2, 3] [1, 2, 3, 4, 5] $ folded >>> taking 3

  describe "React" $ do
    describe "useContext" $ do
      it "should pick up on altered context" $ do
        assertOutputExact [Just "newCtx"] () $ proc inp -> do
          withContext (useContext) -< ("newCtx", ())

    describe "useEffect" $ do
      it "should pick up on altered state" $ do
        assertOutputExact [()] () $ proc inp -> do
          useEffect -< (print "one", ())

    -- describe "useState" $ do
    --   it "should pick up on altered state" $ do
    --     assertOutputPrefix ["one", "two"] () $ proc inp -> do
    --       (s, updater) <- useState "initial" -< ()
    --       useEffect -< (threadDelay 100000 *> updater (const "one") *> threadDelay 100000 *> updater (const "two"), ())
    --       returnA -< s

