-- | Utilities for constructing and covnerting conduits. Please see
-- "Data.Conduit.Types.Conduit" for more information on the base types.
module Data.Conduit.Util.Conduit
    ( haveMore
    , conduitState
    , ConduitStateResult (..)
    , conduitIO
    , ConduitIOResult (..)
      -- *** Sequencing
    , SequencedSink
    , sequenceSink
    , SequencedSinkResponse (..)
    ) where

import Prelude hiding (sequence)
import Control.Monad.Trans.Resource
import Data.Conduit.Internal hiding (leftover)
import Control.Monad (liftM)

-- | A helper function for returning a list of values from a @Conduit@.
--
-- Since 0.3.0
haveMore :: Conduit a m b -- ^ The next @Conduit@ to return after the list has been exhausted.
         -> m () -- ^ A close action for early termination.
         -> [b] -- ^ The values to send down the stream.
         -> Conduit a m b
haveMore res _ [] = res
haveMore res close (x:xs) = HaveOutput (haveMore res close xs) close x

-- | A helper type for @conduitState@, indicating the result of being pushed
-- to.  It can either indicate that processing is done, or to continue with the
-- updated state.
--
-- Since 0.3.0
data ConduitStateResult state input output =
    StateFinished (Maybe input) [output]
  | StateProducing state [output]

instance Functor (ConduitStateResult state input) where
    fmap f (StateFinished a b) = StateFinished a (map f b)
    fmap f (StateProducing a b) = StateProducing a (map f b)

-- | Construct a 'Conduit' with some stateful functions. This function addresses
-- threading the state value for you.
--
-- Since 0.3.0
conduitState
    :: Monad m
    => state -- ^ initial state
    -> (state -> input -> m (ConduitStateResult state input output)) -- ^ Push function.
    -> (state -> m [output]) -- ^ Close function. The state need not be returned, since it will not be used again.
    -> Conduit input m output
conduitState state0 push0 close0 =
    NeedInput (push state0) (\() -> close state0)
  where
    push state input = PipeM (liftM goRes' $ state `seq` push0 state input)

    close state = PipeM (do
        os <- close0 state
        return $ sourceList os)

    goRes' (StateFinished leftover output) = maybe id pipePush leftover $ haveMore
        (Done (return ()) ())
        (return ())
        output
    goRes' (StateProducing state output) = haveMore
        (NeedInput (push state) (\() -> close state))
        (return ())
        output

-- | A helper type for @conduitIO@, indicating the result of being pushed to.
-- It can either indicate that processing is done, or to continue.
--
-- Since 0.3.0
data ConduitIOResult input output =
    IOFinished (Maybe input) [output]
  | IOProducing [output]

instance Functor (ConduitIOResult input) where
    fmap f (IOFinished a b) = IOFinished a (map f b)
    fmap f (IOProducing b) = IOProducing (map f b)

-- | Construct a 'Conduit'.
--
-- Since 0.3.0
conduitIO :: MonadResource m
           => IO state -- ^ resource and/or state allocation
           -> (state -> IO ()) -- ^ resource and/or state cleanup
           -> (state -> input -> m (ConduitIOResult input output)) -- ^ Push function. Note that this need not explicitly perform any cleanup.
           -> (state -> m [output]) -- ^ Close function. Note that this need not explicitly perform any cleanup.
           -> Conduit input m output
conduitIO alloc cleanup push0 close0 = NeedInput
    (\input -> PipeM $ do
        (key, state) <- allocate alloc cleanup
        push key state input)
    (\() -> PipeM $ do
        (key, state) <- allocate alloc cleanup
        os <- close0 state
        release key
        return $ sourceList os)
  where
    push key state input = do
        res <- push0 state input
        case res of
            IOProducing output -> return $ haveMore
                (NeedInput (PipeM . push key state) (\() -> close key state))
                (release key)
                output
            IOFinished leftover output -> do
                release key
                return $ maybe id pipePush leftover $ haveMore
                    (Done (return ()) ())
                    (return ())
                    output

    close key state = PipeM $ do
        output <- close0 state
        release key
        return $ sourceList output

-- | Return value from a 'SequencedSink'.
--
-- Since 0.3.0
data SequencedSinkResponse state input m output =
    Emit state [output] -- ^ Set a new state, and emit some new output.
  | Stop -- ^ End the conduit.
  | StartConduit (Conduit input m output) -- ^ Pass control to a new conduit.

-- | Helper type for constructing a @Conduit@ based on @Sink@s. This allows you
-- to write higher-level code that takes advantage of existing conduits and
-- sinks, and leverages a sink's monadic interface.
--
-- Since 0.3.0
type SequencedSink state input m output =
    state -> Sink input m (SequencedSinkResponse state input m output)

-- | Convert a 'SequencedSink' into a 'Conduit'.
--
-- Since 0.3.0
sequenceSink
    :: Monad m
    => state -- ^ initial state
    -> SequencedSink state input m output
    -> Conduit input m output
sequenceSink state0 fsink = do
    x <- hasInput
    if x
        then do
            res <- sinkToPipe $ fsink state0
            case res of
                Emit state os -> do
                    sourceList os
                    sequenceSink state fsink
                Stop -> return ()
                StartConduit c -> c
        else return ()

pipePush :: Monad m => i -> Pipe i i o u m r -> Pipe i i o u m r
pipePush i (HaveOutput p c o) = HaveOutput (pipePush i p) c o
pipePush i (NeedInput p _) =
    case p i of
        Leftover p' i' -> pipePush i' p'
        p' -> p'
pipePush i (Done c r) = Leftover (Done c r) i
pipePush i (PipeM mp) = PipeM (pipePush i `liftM` mp)
pipePush i (Leftover p i') =
    case pipePush i' p of
        Leftover p'' i'' -> Leftover (Leftover p'' i'') i
        p' -> pipePush i p'

-- | Check if input is available from upstream. Will not remove the data from
-- the stream.
--
-- Since 0.4.0
hasInput :: Monad m => Pipe i i o u m Bool -- FIXME consider removing
hasInput = NeedInput (Leftover (Done (return ()) True)) (const $ Done (return ()) False)
