{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
module Language.JVM.Hierarchy
  ( Hierarchy

  , tryGetClass
  , getClass
  , putText

  , runHierarchy
  , runHierarchyClassPath
  , runHierarchyClassLoader
  , runHierarchyClassPreloader

  , allInterfaces
  , indirectInterfaces
  , directInterfaces

  , implementedMethods
  , interfaceMethods

  , hview
  ) where

import           Language.JVM.Class
import           Language.JVM.ClassLoader
import           Language.JVM.ClassName
import qualified Language.JVM.Method as Method

import           Control.Monad.Free
import           Data.Maybe (catMaybes)

import           Control.Lens

import qualified Data.Set as S

import qualified Data.Map as M

import qualified Data.Text as T
import qualified Data.Text.IO as TIO

data HierarchyLang a
  = GetClass ClassName (Class -> a)
  | TryGetClass ClassName (Either String Class -> a)
  | PutText T.Text (() -> a)
  deriving (Functor)

type Hierarchy = Free HierarchyLang

getClass :: ClassName -> Hierarchy Class
getClass classname =
  Free $ GetClass classname Pure

tryGetClass :: ClassName -> Hierarchy (Either String Class)
tryGetClass classname =
  Free $ TryGetClass classname Pure

putText :: T.Text -> Hierarchy ()
putText text =
  Free $ PutText text Pure

data HierarchyState a = HierarchyState
  { classes :: M.Map ClassName Class }

runHierarchy
  :: (ClassName -> IO [(FilePath,Either String Class)])
  -> Hierarchy a
  -> IO a
runHierarchy clf h =
  go M.empty h
  where
    go m (Free h) =
      case h of
        GetClass cn f -> do
          case M.lookup cn m of
            Just clz -> go m (f clz)
            Nothing -> do
              clzes <- clf cn
              case clzes of
                (_, Right clz) : _ -> go (M.insert cn clz m) (f clz)
                (_, Left msg) : _ -> fail msg
                [] -> fail $ "Couldn't find " ++ show cn
        PutText t f -> do
          go m . f =<< TIO.putStrLn t
        TryGetClass cn f ->
          case M.lookup cn m of
            Just clz -> go m (f (Right clz))
            Nothing -> do
              clzes <- clf cn
              case clzes of
                (_, Right clz) : _ -> go (M.insert cn clz m) (f $ Right clz)
                (_, Left msg) : _ -> go m (f $ Left msg)
                [] -> go m (f . Left $ "Couldn't find " ++ show cn)
    go m (Pure a) =
      return a


runHierarchyClassPreloader :: ClassPreloader -> Hierarchy a -> IO a
runHierarchyClassPreloader cl h = do
  runHierarchy (flip loadClassFromPreloader cl) h

runHierarchyClassLoader :: ClassLoader -> Hierarchy a -> IO a
runHierarchyClassLoader cl h = do
  runHierarchy (flip loadClass cl) h

runHierarchyClassPath :: [FilePath] -> Hierarchy a -> IO a
runHierarchyClassPath classpath h = do
  cl <- fromClassPath classpath
  runHierarchyClassLoader cl h

hview :: Getter Class a -> ClassName -> Hierarchy a
hview lens cn = view lens <$> getClass cn

directInterfaces :: ClassName -> Hierarchy (S.Set ClassName)
directInterfaces =
  hview interfaces

indirectInterfaces :: ClassName -> Hierarchy (S.Set ClassName)
indirectInterfaces cn = do
  inter <- directInterfaces cn
  S.unions <$> mapM allInterfaces (S.toList inter)

allInterfaces :: ClassName -> Hierarchy (S.Set ClassName)
allInterfaces cn = do
  inter <- directInterfaces cn
  S.unions . (inter:) <$> mapM allInterfaces (S.toList inter)

interfaceMethods :: ClassName -> Hierarchy (M.Map Method.MethodId ClassName)
interfaceMethods cn = do
  inter <- S.toList <$> allInterfaces cn
  M.unions <$> mapM (\cn -> hview (toMap cn) cn) inter

  where
    toMap :: ClassName -> Getter Class (M.Map Method.MethodId ClassName)
    toMap cn =
      methods
      . to (map (view $ Method.identifier . to (,cn)))
      . to M.fromList

implementedMethods :: ClassName -> Hierarchy [ (ClassName, Method.Method) ]
implementedMethods cn = do
  methodMap <- interfaceMethods cn
  clz_methods <- hview methods cn

  return . flip map clz_methods $ \m ->
    (maybe cn id $ M.lookup (m ^. Method.identifier) methodMap, m)
