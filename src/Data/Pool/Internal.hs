{-# OPTIONS_HADDOCK not-home #-}

-- | Internal implementation details for "Data.Pool".
--
-- This module is intended for internal use only, and may change without warning
-- in subsequent releases.
module Data.Pool.Internal where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Hashable (hash)
import Data.IORef
import qualified Data.List as L
import Data.Primitive.SmallArray
import GHC.Clock

-- | Striped resource pool based on "Control.Concurrent.QSem".
data Pool a = Pool
  { poolConfig :: !(PoolConfig a)
  , localPools :: !(SmallArray (LocalPool a))
  , reaperRef :: !(IORef ())
  }

-- | A single, local pool.
data LocalPool a = LocalPool
  { stripeId :: !Int
  , stripeVar :: !(MVar (Stripe a))
  , cleanerRef :: !(IORef ())
  }

-- | Stripe of a resource pool. If @available@ is 0, the list of threads waiting
-- for a resource (each with an associated 'MVar') is @queue ++ reverse queueR@.
data Stripe a = Stripe
  { available :: !Int
  , cache :: ![Entry a]
  , queue :: !(Queue a)
  , queueR :: !(Queue a)
  }

-- | An existing resource currently sitting in a pool.
data Entry a = Entry
  { entry :: a
  , lastUsed :: !Double
  }

-- | A queue of MVarS corresponding to threads waiting for resources.
--
-- Basically a monomorphic list to save two pointer indirections.
data Queue a = Queue !(MVar (Maybe a)) (Queue a) | Empty

-- | Configuration of a 'Pool'.
data PoolConfig a = PoolConfig
  { createResource :: !(IO a)
  , freeResource :: !(a -> IO ())
  , poolCacheTTL :: !Double
  , poolMaxResources :: !Int
  , poolNumStripes :: !(Maybe Int)
  }

-- | Create a 'PoolConfig' with optional parameters having default values.
--
-- For setting optional parameters have a look at:
--
-- - 'setNumStripes'
--
-- @since 0.4.0.0
defaultPoolConfig
  :: IO a
  -- ^ The action that creates a new resource.
  -> (a -> IO ())
  -- ^ The action that destroys an existing resource.
  -> Double
  -- ^ The amount of seconds for which an unused resource is kept around. The
  -- smallest acceptable value is @0.5@.
  --
  -- /Note:/ the elapsed time before destroying a resource may be a little
  -- longer than requested, as the collector thread wakes at 1-second intervals.
  -> Int
  -- ^ The maximum number of resources to keep open __across all stripes__. The
  -- smallest acceptable value is @1@.
  --
  -- /Note:/ for each stripe the number of resources is divided by the number of
  -- stripes and rounded up, hence the pool might end up creating up to @N - 1@
  -- resources more in total than specified, where @N@ is the number of stripes.
  -> PoolConfig a
defaultPoolConfig create free cacheTTL maxResources =
  PoolConfig
    { createResource = create
    , freeResource = free
    , poolCacheTTL = cacheTTL
    , poolMaxResources = maxResources
    , poolNumStripes = Nothing
    }

-- | Set the number of stripes in the pool.
--
-- If set to 'Nothing' (the default value), the pool will create the amount of
-- stripes equal to the number of capabilities. This ensures that threads never
-- compete over access to the same stripe and results in a very good performance
-- in a multi-threaded environment.
--
-- @since 0.4.0.0
setNumStripes :: Maybe Int -> PoolConfig a -> PoolConfig a
setNumStripes numStripes pc = pc {poolNumStripes = numStripes}

-- | Create a new striped resource pool.
--
-- /Note:/ although the runtime system will destroy all idle resources when the
-- pool is garbage collected, it's recommended to manually call
-- 'destroyAllResources' when you're done with the pool so that the resources
-- are freed up as soon as possible.
newPool :: PoolConfig a -> IO (Pool a)
newPool pc = do
  when (poolCacheTTL pc < 0.5) $ do
    error "poolCacheTTL must be at least 0.5"
  when (poolMaxResources pc < 1) $ do
    error "poolMaxResources must be at least 1"
  numStripesRequested <- maybe getNumCapabilities pure (poolNumStripes pc)
  when (numStripesRequested < 1) $ do
    error "numStripes must be at least 1"

  let stripeResourceAllocation =
        howManyStripes Input
          { inputMaxResources = poolMaxResources pc
          , inputStripes = numStripesRequested
          }
      stripeAllocations =
        robin stripeResourceAllocation
      indexedAllocations =
        zip [1..] stripeAllocations
      numStripes =
        allowedStripes stripeResourceAllocation

  when (poolMaxResources pc < numStripes) $ do
    error "poolMaxResources must not be smaller than numStripes"
  pools <- fmap (smallArrayFromListN numStripes) . forM indexedAllocations $ \(index, allocation) -> do
    ref <- newIORef ()
    stripe <-
      newMVar
        Stripe
          { available = allocation
          , cache = []
          , queue = Empty
          , queueR = Empty
          }
    -- When the local pool goes out of scope, free its resources.
    void . mkWeakIORef ref $ cleanStripe (const True) (freeResource pc) stripe
    pure
      LocalPool
        { stripeId = index
        , stripeVar = stripe
        , cleanerRef = ref
        }
  mask_ $ do
    ref <- newIORef ()
    collectorA <- forkIOWithUnmask $ \unmask -> unmask $ collector pools
    void . mkWeakIORef ref $ do
      -- When the pool goes out of scope, stop the collector. Resources existing
      -- in stripes will be taken care by their cleaners.
      killThread collectorA
    pure
      Pool
        { poolConfig = pc
        , localPools = pools
        , reaperRef = ref
        }
  where
    -- Collect stale resources from the pool once per second.
    collector pools = forever $ do
      threadDelay 1000000
      now <- getMonotonicTime
      let isStale e = now - lastUsed e > poolCacheTTL pc
      mapM_ (cleanStripe isStale (freeResource pc) . stripeVar) pools

-- | A datatype representing the requested maximum resources and count of
-- stripes. We don't use these figures directly, but instead calculate
-- a 'StripeResourceAllocation' using 'howManyStripes'.
data Input = Input
  { inputMaxResources :: !Int
  -- ^ How many resources the user requested as an upper limit.
  , inputStripes :: !Int
  -- ^ How many stripes the user requested.
  }
  deriving Show

-- | How many stripes to create, respecting the 'inputMaxResources' on the
-- 'poolInput' field. To create one, use 'howManyStripes'.
data StripeResourceAllocation = StripeResourceAllocation
  { poolInput :: !Input
  -- ^ The original input for the calculation.
  , allowedStripes :: !Int
  -- ^ The amount of stripes to actually create.
  }
  deriving Show

-- | Determine how many resources should be allocated to each stripe.
--
-- The output list contains a single `Int` per stripe, with the 'Int'
-- representing the amount of resources available to that stripe.
robin :: StripeResourceAllocation -> [Int]
robin stripeResourceAllocation =
  let
    numStripes =
      allowedStripes stripeResourceAllocation
    (baseCount, remainder) =
      inputMaxResources (poolInput stripeResourceAllocation)
        `divMod` numStripes
  in
    replicate remainder (baseCount + 1) ++ replicate (numStripes - remainder) baseCount

-- | A stripe must have at least one resource. If the user requested more
-- stripes than total resources, then we cannot create that many stripes
-- without exceeding the maximum resource limit.
howManyStripes :: Input -> StripeResourceAllocation
howManyStripes inp = StripeResourceAllocation
  { allowedStripes =
      if inputStripes inp > inputMaxResources inp
      then inputMaxResources inp
      else inputStripes inp
  , poolInput = inp
  }

-- | Destroy a resource.
--
-- Note that this will ignore any exceptions in the destroy function.
destroyResource :: Pool a -> LocalPool a -> a -> IO ()
destroyResource pool lp a = do
  uninterruptibleMask_ $ do
    -- Note [signal uninterruptible]
    stripe <- takeMVar (stripeVar lp)
    newStripe <- signal stripe Nothing
    putMVar (stripeVar lp) newStripe
    void . try @SomeException $ freeResource (poolConfig pool) a

-- | Return a resource to the given 'LocalPool'.
putResource :: LocalPool a -> a -> IO ()
putResource lp a = do
  uninterruptibleMask_ $ do
    -- Note [signal uninterruptible]
    stripe <- takeMVar (stripeVar lp)
    newStripe <- signal stripe (Just a)
    putMVar (stripeVar lp) newStripe

-- | Destroy all resources in all stripes in the pool.
--
-- Note that this will ignore any exceptions in the destroy function.
--
-- This function is useful when you detect that all resources in the pool are
-- broken. For example after a database has been restarted all connections
-- opened before the restart will be broken. In that case it's better to close
-- those connections so that 'takeResource' won't take a broken connection from
-- the pool but will open a new connection instead.
--
-- Another use-case for this function is that when you know you are done with
-- the pool you can destroy all idle resources immediately instead of waiting on
-- the garbage collector to destroy them, thus freeing up those resources
-- sooner.
destroyAllResources :: Pool a -> IO ()
destroyAllResources pool = forM_ (localPools pool) $ \lp -> do
  cleanStripe (const True) (freeResource (poolConfig pool)) (stripeVar lp)

----------------------------------------
-- Helpers

-- | Get a local pool.
getLocalPool :: SmallArray (LocalPool a) -> IO (LocalPool a)
getLocalPool pools = do
  sid <-
    if stripes == 1
      then -- If there is just one stripe, there is no choice.
        pure 0
      else do
        capabilities <- getNumCapabilities
        -- If the number of stripes is smaller than the number of capabilities and
        -- doesn't divide it, selecting a stripe by a capability the current
        -- thread runs on wouldn't give equal load distribution across all stripes
        -- (e.g. if there are 2 stripes and 3 capabilities, stripe 0 would be used
        -- by capability 0 and 2, while stripe 1 would only be used by capability
        -- 1, a 100% load difference). In such case we select based on the id of a
        -- thread.
        if stripes < capabilities && capabilities `rem` stripes /= 0
          then hash <$> myThreadId
          else fmap fst . threadCapability =<< myThreadId
  pure $ pools `indexSmallArray` (sid `rem` stripes)
  where
    stripes = sizeofSmallArray pools

-- | Wait for the resource to be put into a given 'MVar'.
waitForResource :: MVar (Stripe a) -> MVar (Maybe a) -> IO (Maybe a)
waitForResource mstripe q = takeMVar q `onException` cleanup
  where
    cleanup = uninterruptibleMask_ $ do
      -- Note [signal uninterruptible]
      stripe <- takeMVar mstripe
      newStripe <-
        tryTakeMVar q >>= \case
          Just ma -> do
            -- Between entering the exception handler and taking ownership of
            -- the stripe we got the resource we wanted. We don't need it
            -- anymore though, so pass it to someone else.
            signal stripe ma
          Nothing -> do
            -- If we're still waiting, fill up the MVar with an undefined value
            -- so that 'signal' can discard our MVar from the queue.
            putMVar q $ error "unreachable"
            pure stripe
      putMVar mstripe newStripe

-- | If an exception is received while a resource is being created, restore the
-- original size of the stripe.
restoreSize :: MVar (Stripe a) -> IO ()
restoreSize mstripe = uninterruptibleMask_ $ do
  -- 'uninterruptibleMask_' is used since 'takeMVar' might block.
  stripe <- takeMVar mstripe
  putMVar mstripe $! stripe {available = available stripe + 1}

-- | Free resource entries in the stripes that fulfil a given condition.
cleanStripe
  :: (Entry a -> Bool)
  -> (a -> IO ())
  -> MVar (Stripe a)
  -> IO ()
cleanStripe isStale free mstripe = mask $ \unmask -> do
  -- Asynchronous exceptions need to be masked here to prevent leaking of
  -- 'stale' resources before they're freed.
  stale <- modifyMVar mstripe $ \stripe -> unmask $ do
    let (stale, fresh) = L.partition isStale (cache stripe)
        -- There's no need to update 'available' here because it only tracks
        -- the number of resources taken from the pool.
        newStripe = stripe {cache = fresh}
    newStripe `seq` pure (newStripe, map entry stale)
  -- We need to ignore exceptions in the 'free' function, otherwise if an
  -- exception is thrown half-way, we leak the rest of the resources. Also,
  -- asynchronous exceptions need to be hard masked here since freeing a
  -- resource might in theory block.
  uninterruptibleMask_ . forM_ stale $ try @SomeException . free

-- Note [signal uninterruptible]
--
--   If we have
--
--      bracket takeResource putResource (...)
--
--   and an exception arrives at the putResource, then we must not lose the
--   resource. The putResource is masked by bracket, but taking the MVar might
--   block, and so it would be interruptible. Hence we need an uninterruptible
--   variant of mask here.
signal :: Stripe a -> Maybe a -> IO (Stripe a)
signal stripe ma =
  if available stripe == 0
    then loop (queue stripe) (queueR stripe)
    else do
      newCache <- case ma of
        Just a -> do
          now <- getMonotonicTime
          pure $ Entry a now : cache stripe
        Nothing -> pure $ cache stripe
      pure $!
        stripe
          { available = available stripe + 1
          , cache = newCache
          }
  where
    loop Empty Empty = do
      newCache <- case ma of
        Just a -> do
          now <- getMonotonicTime
          pure [Entry a now]
        Nothing -> pure []
      pure $!
        Stripe
          { available = 1
          , cache = newCache
          , queue = Empty
          , queueR = Empty
          }
    loop Empty qR = loop (reverseQueue qR) Empty
    loop (Queue q qs) qR =
      tryPutMVar q ma >>= \case
        -- This fails when 'waitForResource' went into the exception handler and
        -- filled the MVar (with an undefined value) itself. In such case we
        -- simply ignore it.
        False -> loop qs qR
        True ->
          pure $!
            stripe
              { available = 0
              , queue = qs
              , queueR = qR
              }

reverseQueue :: Queue a -> Queue a
reverseQueue = go Empty
  where
    go acc = \case
      Empty -> acc
      Queue x xs -> go (Queue x acc) xs
