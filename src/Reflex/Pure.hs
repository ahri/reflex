{-# LANGUAGE CPP #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
#ifdef USE_REFLEX_OPTIMIZER
{-# OPTIONS_GHC -fplugin=Reflex.Optimizer #-}
#endif

-- There are two expected orphan instances in this module:
--   * MonadSample (Pure t) ((->) t)
--   * MonadHold (Pure t) ((->) t)
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This module provides a pure implementation of Reflex, which is intended to
-- serve as a reference for the semantics of the Reflex class.  All
-- implementations of Reflex should produce the same results as this
-- implementation, although performance and laziness/strictness may differ.
module Reflex.Pure
  ( Pure
  , Behavior (..)
  , Event (..)
  , Dynamic (..)
  , Incremental (..)
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Monad.ST.Lazy
import Data.Dependent.Map (DMap, GCompare)
import qualified Data.Dependent.Map as DMap
import Data.Functor.Identity
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Maybe
import Data.MemoTrie
import Data.Monoid
import Data.Type.Coercion
import Data.Unique.Tag
import Reflex.Class

-- | A completely pure-functional 'Reflex' timeline, identifying moments in time
-- with the type @t@.
data Pure t

newtype CellOut t x = CellOut (forall a. Tag x a -> Event (Pure t) a)

-- | The Enum instance of t must be dense: for all x :: t, there must not exist
-- any y :: t such that pred x < y < x. The HasTrie instance will be used
-- exclusively to memoize functions of t, not for any of its other capabilities.
instance (Enum t, HasTrie t, Ord t) => Reflex (Pure t) where

  newtype Behavior (Pure t) a = Behavior { unBehavior :: t -> a }
  newtype Event (Pure t) a = Event { unEvent :: t -> Maybe a }
  newtype Dynamic (Pure t) a = Dynamic { unDynamic :: t -> (a, Maybe a) }
  newtype Incremental (Pure t) p = Incremental { unIncremental :: t -> (PatchTarget p, Maybe p) }
  data Cell (Pure t) f = forall x. Cell (f x)
  newtype CellBuilderM (Pure t) x a = CellBuilderM { unCellBuilderM :: ReaderT (CellOut t x) (ST x) a }
    deriving (Functor, Applicative, Monad)
  newtype CellM (Pure t) x a = CellM { unCellM :: StateT (DMap (Tag x) Identity) (CellBuilderM (Pure t) x) a }
    deriving (Functor, Applicative, Monad)
  newtype CellTrigger (Pure t) a x = CellTrigger (Tag x a)

  type PushM (Pure t) = (->) t
  type PullM (Pure t) = (->) t

  never :: Event (Pure t) a
  never = Event $ \_ -> Nothing

  constant :: a -> Behavior (Pure t) a
  constant x = Behavior $ \_ -> x

  push :: (a -> PushM (Pure t) (Maybe b)) -> Event (Pure t) a -> Event (Pure t) b
  push f e = Event $ memo $ \t -> unEvent e t >>= \o -> f o t

  pushCheap :: (a -> PushM (Pure t) (Maybe b)) -> Event (Pure t) a -> Event (Pure t) b
  pushCheap = push

  pull :: PullM (Pure t) a -> Behavior (Pure t) a
  pull = Behavior . memo

  -- [UNUSED_CONSTRAINT]: The following type signature for merge will produce a
  -- warning because the GCompare instance is not used; however, removing the
  -- GCompare instance produces a different warning, due to that constraint
  -- being present in the original class definition

  --merge :: GCompare k => DMap k (Event (Pure t)) -> Event (Pure t) (DMap k Identity)
  merge events = Event $ memo $ \t ->
    let currentOccurrences = DMap.mapMaybeWithKey (\_ (Event a) -> Identity <$> a t) events
    in if DMap.null currentOccurrences
       then Nothing
       else Just currentOccurrences

  fan :: GCompare k => Event (Pure t) (DMap k Identity) -> EventSelector (Pure t) k
  fan e = EventSelector $ \k -> Event $ \t -> unEvent e t >>= fmap runIdentity . DMap.lookup k

  switch :: Behavior (Pure t) (Event (Pure t) a) -> Event (Pure t) a
  switch b = Event $ memo $ \t -> unEvent (unBehavior b t) t

  coincidence :: Event (Pure t) (Event (Pure t) a) -> Event (Pure t) a
  coincidence e = Event $ memo $ \t -> unEvent e t >>= \o -> unEvent o t

  current :: Dynamic (Pure t) a -> Behavior (Pure t) a
  current d = Behavior $ \t -> fst $ unDynamic d t

  updated :: Dynamic (Pure t) a -> Event (Pure t) a
  updated d = Event $ \t -> snd $ unDynamic d t

  unsafeBuildDynamic :: PullM (Pure t) a -> Event (Pure t) a -> Dynamic (Pure t) a
  unsafeBuildDynamic readV0 v' = Dynamic $ \t -> (readV0 t, unEvent v' t)

  -- See UNUSED_CONSTRAINT, above.

  --unsafeBuildIncremental :: Patch p => PullM (Pure t) a -> Event (Pure t) (p
  --a) -> Incremental (Pure t) p a
  unsafeBuildIncremental readV0 p = Incremental $ \t -> (readV0 t, unEvent p t)

  mergeIncremental = mergeIncrementalImpl
  mergeIncrementalWithMove = mergeIncrementalImpl

  currentIncremental i = Behavior $ \t -> fst $ unIncremental i t

  updatedIncremental i = Event $ \t -> snd $ unIncremental i t

  incrementalToDynamic i = Dynamic $ \t ->
    let (old, mPatch) = unIncremental i t
        e = case mPatch of
          Nothing -> Nothing
          Just patch -> apply patch old
    in (old, e)
  behaviorCoercion Coercion = Coercion
  eventCoercion Coercion = Coercion
  dynamicCoercion Coercion = Coercion

  fanInt e = EventSelectorInt $ \k -> Event $ \t -> unEvent e t >>= IntMap.lookup k

  mergeIntIncremental = mergeIntIncrementalImpl

instance CreateCellEvent (Pure t) (CellBuilderM (Pure t)) where
  newCellEvent = CellBuilderM $ do
    t <- lift $ strictToLazyST newTag
    CellOut getEvent <- ask
    pure (CellTrigger t, getEvent t)

instance CreateCellEvent (Pure t) (CellM (Pure t)) where
  newCellEvent = CellM $ lift newCellEvent

instance FireCellEvent (Pure t) (CellM (Pure t)) where
  fireCellEvent (CellTrigger t) o = CellM $ modify $ DMap.insertWith' (\_ old -> old) t (Identity o)

mergeIncrementalImpl :: (PatchTarget p ~ DMap k (Event (Pure t)), GCompare k) => Incremental (Pure t) p -> Event (Pure t) (DMap k Identity)
mergeIncrementalImpl i = Event $ \t ->
  let results = DMap.mapMaybeWithKey (\_ (Event e) -> Identity <$> e t) $ fst $ unIncremental i t
  in if DMap.null results
     then Nothing
     else Just results

mergeIntIncrementalImpl :: (PatchTarget p ~ IntMap (Event (Pure t) a)) => Incremental (Pure t) p -> Event (Pure t) (IntMap a)
mergeIntIncrementalImpl i = Event $ \t ->
  let results = IntMap.mapMaybeWithKey (\_ (Event e) -> e t) $ fst $ unIncremental i t
  in if IntMap.null results
     then Nothing
     else Just results

instance Functor (Dynamic (Pure t)) where
  fmap f d = Dynamic $ \t -> let (cur, upd) = unDynamic d t
                             in (f cur, fmap f upd)

instance Applicative (Dynamic (Pure t)) where
  pure a = Dynamic $ \_ -> (a, Nothing)
  (<*>) = ap

instance Monad (Dynamic (Pure t)) where
  return = pure
  (x :: Dynamic (Pure t) a) >>= (f :: a -> Dynamic (Pure t) b) = Dynamic $ \t ->
    let (curX :: a, updX :: Maybe a) = unDynamic x t
        (cur :: b, updOuter :: Maybe b) = unDynamic (f curX) t
        (updInner :: Maybe b, updBoth :: Maybe b) = case updX of
          Nothing -> (Nothing, Nothing)
          Just nextX -> let (c, u) = unDynamic (f nextX) t
                        in (Just c, u)
    in (cur, getFirst $ mconcat $ map First [updBoth, updOuter, updInner])

instance MonadSample (Pure t) ((->) t) where

  sample :: Behavior (Pure t) a -> (t -> a)
  sample = unBehavior

instance (Enum t, HasTrie t, Ord t) => MonadHold (Pure t) ((->) t) where

  hold :: a -> Event (Pure t) a -> t -> Behavior (Pure t) a
  hold initialValue e initialTime = Behavior f
    where f = memo $ \sampleTime ->
            -- Really, the sampleTime should never be prior to the initialTime,
            -- because that would mean the Behavior is being sampled before
            -- being created.
            if sampleTime <= initialTime
            then initialValue
            else let lastTime = pred sampleTime
                 in fromMaybe (f lastTime) $ unEvent e lastTime

  holdDyn v0 = buildDynamic (return v0)

  buildDynamic :: (t -> a) -> Event (Pure t) a -> t -> Dynamic (Pure t) a
  buildDynamic initialValue e initialTime =
    let Behavior f = hold (initialValue initialTime) e initialTime
    in Dynamic $ \t -> (f t, unEvent e t)

  holdIncremental :: Patch p => PatchTarget p -> Event (Pure t) p -> t -> Incremental (Pure t) p
  holdIncremental initialValue e initialTime = Incremental $ \t -> (f t, unEvent e t)
    where f = memo $ \sampleTime ->
            -- Really, the sampleTime should never be prior to the initialTime,
            -- because that would mean the Behavior is being sampled before
            -- being created.
            if sampleTime <= initialTime
            then initialValue
            else let lastTime = pred sampleTime
                     lastValue = f lastTime
                 in case unEvent e lastTime of
                   Nothing -> lastValue
                   Just x -> fromMaybe lastValue $ apply x lastValue

  headE = slowHeadE

  holdPushCell e build update initialTime = runST $ do
    rec (f, result) <- runCellBuilder firings build
        firings :: [(t, DMap (Tag x) Identity)] <- forM [initialTime..] $ \t -> (,) t <$> case unEvent e t of
          Nothing -> pure mempty
          Just o -> runCellBuilder firings $ execStateT (unCellM $ update f o) mempty
    pure (Cell f, result)

--TODO: Use a better datastructure than a sorted list
runCellBuilder :: Eq t => [(t, DMap (Tag x) Identity)] -> CellBuilderM (Pure t) x a -> ST x a
runCellBuilder firings b = runReaderT (unCellBuilderM b) $ CellOut $ \eventId -> Event $ \t ->
  runIdentity <$> (DMap.lookup eventId =<< Prelude.lookup t firings)

test :: IO ()
test = do
  let e1 :: Event (Pure Int) Char = Event $ \t -> Prelude.lookup t [(1, 'a'), (2, 'b')]
      (_, e2) = holdPushCell e1 newCellEvent fireCellEvent 0
  forM_ [0..5] $ \t -> print (t, unEvent e2 t)
