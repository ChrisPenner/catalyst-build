{-# LANGUAGE Arrows #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
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
import Control.Monad


assertOutputExact :: (Eq o, Show o) => [o] -> i -> Juke Stream Context i o -> Expectation
assertOutputExact expectedOut i j = do
  q <- newTQueueIO
  run mempty i (atomically . writeTQueue q) j
  results <- atomically $ flushTQueue q
  results `shouldBe` expectedOut

assertOutputPrefix :: (Eq o, Show o) => [o] -> i -> Juke Reactive Context i o -> Expectation
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
  describe "Stream" $ do
    -- it "should terminate when ArrowStrong is used" $ do
    --     assertOutputExact [('l', 'r')] () $ proc inp -> do
    --       a <- returnA -< 'l'
    --       b <- returnA -< 'r'
    --       returnA -< (a, b)

    -- it "takes cartesian product w/r to Strong" $ do
    --   assertOutputExact [(1,'a'),(1,'b'),(2,'a'),(2,'b')] () $ proc inp -> do
    --       l <- folded -< [1, 2]
    --       r <- folded -< ['a', 'b']
    --       returnA -< (l, r)

    it "should terminate when Choice is used" $ do
        assertOutputExact ["true"] True $ proc inp -> do
          if inp then returnA -< "true"
                 else returnA -< "false"

    describe "folded" $ do
      it "should fold all items" $ do
        assertOutputExact [1 :: Int, 2, 3] [1 :: Int, 2, 3] $ folded
    describe "take" $ do
      it "should take n then stop" $ do
        assertOutputExact [1, 2, 3] [1, 2, 3, 4, 5] $ folded >>> taking 3
    describe "filtered" $ do
      it "should take n then stop" $ do
        assertOutputExact [1, 3, 5] [1, 2, 3, 4, 5] $ folded >>> filtered odd

    -- describe "Strong" $ do
      -- Strong is absolutely not necessary here, it's weird Arrow syntax uses it.
      -- it "Should not use Strong unless necessary" $ do
      --   assertOutputExact [1, 3, 5] [1, 2, 3, 4, 5] $ proc inp -> do
      --       x <- folded -< inp
      --       filtered odd -< x

  describe "Reactive" $ do
    it "should run Strong products in parallel, updating for change in either side" $ do
        assertOutputPrefix [(1, 10), (1, 20), (2, 20)] () $ proc inp -> do
          (l, r) <- (counter <<< ticker 100) *** (counter <<< ticker 70) -< ((),())
          returnA -< (l, r * 10)


  describe "React" $ do
    describe "useContext" $ do
      it "should pick up on altered context" $ do
        assertOutputExact [Just "newCtx"] () $ proc inp -> do
          withContext (useContext) -< ("newCtx", ())

    describe "useState" $ do
      it "should pick up on altered state" $ do
        assertOutputPrefix ["initial", "one", "two"] () $ proc inp -> do
          (s, updater) <- useState "initial" -< ()
          x <- useEffect -< (threadDelay 1000 *> updater (const "one") *> threadDelay 1000 *> updater (const "two"), ())
          returnA <<< arr fst -< (s, x)

    describe "useEffect" $ do
      it "should re-run the computation on a changed sentinel" $ do
        assertOutputPrefix ["initial", "one", "one", "one"] () $ proc inp -> do
          (s, updater) <- useState "initial" -< ()
          x <- useEffect -< (forever $ updater (const "one") *> threadDelay 1000, s)
          returnA <<< arr fst -< (s, x)

