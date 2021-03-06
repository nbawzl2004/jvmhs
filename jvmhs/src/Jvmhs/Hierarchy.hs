{-
Module      : Jvmhs.Hierarchy
Copyright   : (c) Christian Gram Kalhauge, 2017
License     : MIT
Maintainer  : kalhuage@cs.ucla.edu

This module defines a class Hierarchy. The class hierarchy, contains
every class loaded by the program.
-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
module Jvmhs.Hierarchy
  ( MonadHierarchy (..)

  , HierarchyError (..)
  , heClassName
  , heClassReadError

   -- * Hierarchy implementation
  , Hierarchy
  , runHierarchy
  , runHierarchy'
  , runHierarchyInClassPath
  , runHierarchyInClassPathOnly

  , HierarchyState (..)
  , saveHierarchyState
  , savePartialHierarchyState
  , emptyState

  -- * Helpers
  , load
  , load'
  , (^!!)
  , (^!)
  ) where

-- import           Control.Monad          (foldM)
import           Control.Monad.Except
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.State.Class
import           Control.Monad.State    (StateT, runStateT)

import           Control.Lens
import           Control.Lens.Action

import           Data.Map               as Map
-- import           Data.Set               as Set

import           Jvmhs.ClassReader
import           Jvmhs.Data.Class
import           Jvmhs.Data.Type

data HierarchyState r = HierarchyState
  { _loadedClasses :: Map.Map ClassName Class
  , _classReader   :: r
  }
  deriving (Show, Eq)

makeLenses ''HierarchyState

data HierarchyError
  = ErrorWhileReadingClass
  { _heClassName :: ClassName
  , _heClassReadError :: ClassReadError
  } deriving (Show, Eq)

makeLenses ''HierarchyError

newtype Hierarchy r a =
  Hierarchy (StateT (HierarchyState r) (ExceptT HierarchyError IO) a)
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadError HierarchyError
    , MonadState (HierarchyState r)
    , MonadIO
    )

class (MonadError HierarchyError m, Monad m) => MonadHierarchy m where
  loadClass :: ClassName -> m Class
  saveClass :: Class -> m ()
  -- | Behavior for changing classname in class is undefined.
  modifyClass :: ClassName -> (Class -> Class) -> m ()

saveHierarchyState :: FilePath -> HierarchyState r -> IO ()
saveHierarchyState fp s =
  writeClasses fp (s^.loadedClasses)

savePartialHierarchyState ::
     Foldable f
  => FilePath
  -> f ClassName
  -> HierarchyState r
  -> IO ()
savePartialHierarchyState fp fs s =
  writeClasses fp (fs^..folded.to (flip Map.lookup cl)._Just)
  where
    cl = s^.loadedClasses

runHierarchy
  :: ClassReader r
  => r
  -> Hierarchy r a
  -> IO (Either HierarchyError a)
runHierarchy r h =
  fmap fst <$> runHierarchy' h (emptyState r)

emptyState :: r -> HierarchyState r
emptyState r = (HierarchyState Map.empty r)

runHierarchy'
  :: ClassReader r
  => Hierarchy r a
  -> HierarchyState r
  -> IO (Either HierarchyError (a, HierarchyState r))
runHierarchy' (Hierarchy h) =
  runExceptT . runStateT h

runHierarchyInClassPathOnly
  :: [ FilePath ]
  -> Hierarchy ClassPreloader a
  -> IO (Either HierarchyError a)
runHierarchyInClassPathOnly cp hc = do
  p <- preload $ fromClassPathOnly cp
  fmap fst <$> runHierarchy' hc (emptyState p)

runHierarchyInClassPath
  :: [ FilePath ]
  -> Hierarchy ClassPreloader a
  -> IO (Either HierarchyError a)
runHierarchyInClassPath cp hc = do
  ld <- fromClassPath cp
  p <- preload ld
  fmap fst <$> runHierarchy' hc (emptyState p)

instance ClassReader r => MonadHierarchy (Hierarchy r) where
  loadClass cn = do
    x <- use $ loadedClasses . at cn
    case x of
      Just l ->
        return l
      Nothing -> do
        r <- use classReader
        l <- liftIO $ readClass r cn
        case l of
          Left err ->
            throwError $ ErrorWhileReadingClass cn err
          Right cls -> do
            loadedClasses . at cn .= Just cls
            return cls

  saveClass cls = do
    loadedClasses . at (cls^.className) .= Just cls

  modifyClass cn f = do
    cls <- loadClass cn
    saveClass (f cls)

-- | An load action can be used as part of a lens to load a
-- class.
load
  :: MonadHierarchy m
  => Action m ClassName Class
load = act loadClass

-- | Loads a 'Class' but does not fail if the class was not loaded
-- instead it returns a HierarchyError.
load' ::
     MonadHierarchy m
  => Action m ClassName (Either HierarchyError Class)
load' = act (\cn -> catchError (Right <$> loadClass cn) (return . Left))
