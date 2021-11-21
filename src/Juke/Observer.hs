{-# LANGUAGE DataKinds #-}
{-# LANGUAGE Arrows #-}
module Juke.Observer where

import Juke.Internal
import Juke.React (useState)

-- subject :: Juke Reactive ctx i i 
-- subject = proc inp -> do
--   (v, updater) <- useState Nothing -< ()
--   folded -< v
