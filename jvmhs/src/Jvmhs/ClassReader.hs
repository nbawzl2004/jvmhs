{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Jvmhs.ClassReader
  (
    ClassReadError (..)

  , ClassReader (..)
  , readClass

  , CFolder
  , toFilePath

  , CJar
  , jarArchive
  , jarPath

  , ClassLoader (..)
  , fromClassPath
  , fromJreFolder
  , paths

  , ClassPreloader (..)
  , classMap
  , preload
  , preloadClassPath
  ) where

import           System.Directory
import           System.FilePath
import           System.Process

import           Control.Lens
import           Data.Monoid

import           Data.Maybe             (catMaybes)

import qualified Data.ByteString.Lazy   as BL
import qualified Data.Text as Text

import           Codec.Archive.Zip
import           Jvmhs.Data.Class
import qualified Language.JVM as B

import qualified Data.Map as Map

-- % Utils

-- | Get the path of a class.
pathOfClass :: FilePath -> ClassName -> FilePath
pathOfClass fp cn =
  fp ++ "/" ++ Text.unpack (classNameAsText cn) ++ ".class"

-- | Return all the jars from in a folder.
jarsFromFolder :: FilePath -> IO [ FilePath ]
jarsFromFolder fp =
  filter isJar <$> folderContents fp

-- | Read a zip file
readZipFile :: FilePath -> IO (Either String Archive)
readZipFile fp = do
  toArchiveOrFail <$> BL.readFile fp

-- | The content of a folder represented as a absolute path
folderContents :: FilePath -> IO [ FilePath ]
folderContents fp =
  map (fp </>) <$> listDirectory fp

-- | Check if the extension of the file is ".jar"
isJar :: FilePath -> Bool
isJar path =
  takeExtension path == ".jar"

-- | Check if the extension of the file is ".class"
isClassFile :: FilePath -> Bool
isClassFile path =
  takeExtension path == ".class"

-- | Takes a relative file path from the main package to the
-- class file and returns a class name.
asClassName :: FilePath -> Maybe ClassName
asClassName path
  | isClassFile path =
    return . strCls $ dropExtension path
  | otherwise =
    Nothing

-- | Get all the files of under a folder.
recursiveContents :: FilePath -> IO [ FilePath ]
recursiveContents fp = do
  test <- doesDirectoryExist fp
  (fp:) <$> if test then do
    content <- folderContents fp
    concat <$> mapM recursiveContents content
  else return []

-- % Utils done

-- | Reading a class can return one of two kinds of errors
data ClassReadError
 = ClassNotFound
 -- ^ Class was not found
 | MalformedClass B.ClassFileError
 -- ^ An error happened while reading the class.
 deriving (Show, Eq)

-- | A class reader can read a class using a class name.
class ClassReader m where
  -- | Reads a class file from the reader
  readClassFile
    :: m
    -> ClassName
    -> IO (Either ClassReadError (B.ClassFile B.High))

  -- | Returns a list of `ClassName` and the containers they are in.
  classes
    :: m
    -> IO [ (ClassName, ClassContainer) ]

-- | Read a checked class from a class reader.
readClass
  :: (ClassReader m)
  => m
  -> ClassName
  -> IO (Either ClassReadError Class)
readClass m cn = do
  cls <- readClassFile m cn
  return (cls & _Right %~ view isoBinary)

-- | Classes can be in a folder
newtype CFolder = CFolder
  { _toFilePath :: FilePath
  } deriving (Show)

-- | Check if a filepath is a folder and return it if it is
asFolder :: FilePath -> IO (Maybe CFolder)
asFolder fp = do
  test <- doesDirectoryExist fp
  return $ if test
    then Just (CFolder fp)
    else Nothing

instance ClassReader CFolder where
  readClassFile (CFolder fp) cn = do
    let cls = pathOfClass fp cn
    x <- doesFileExist cls
    if x
      then do
        file <- BL.readFile cls
        return $ B.readClassFile file & _Left %~ MalformedClass
      else return $ Left ClassNotFound

  classes this@(CFolder fp) = do
     fls <- catMaybes
       . map asClassName
       . map (makeRelative fp)
       <$> recursiveContents fp
     return $ map (,CCFolder this) fls

-- | Classes can also be in a Jar
data CJar = CJar
  { _jarPath :: FilePath
  , _jarArchive :: Archive
  } deriving (Show)

-- | Check if a filepath is a jar and load it into memory if
-- it is.
asJar :: FilePath -> IO (Maybe CJar)
asJar fp
  | isJar fp = do
      arch <- readZipFile fp
      return $ CJar fp <$> (arch ^? _Right)
  | otherwise =
      return Nothing

instance ClassReader CJar where
  readClassFile (CJar _ arch) cn =
    case findEntryByPath (pathOfClass "" cn) arch of
      Just f ->
        return $ B.readClassFile (fromEntry f) & _Left %~ MalformedClass
      Nothing ->
        return $ Left ClassNotFound

  classes this@(CJar _ arch) = do
     let fls = catMaybes . map (asClassName . eRelativePath) $ zEntries arch
     return $ map (,CCJar this) fls

-- | Return a class container from a file path. It might return
-- `Nothing` if it's not a folder or a jar.
container :: FilePath -> IO (Maybe ClassContainer)
container fp = do
  jar <- (fmap CCJar <$> asJar fp)
  case jar of
    Just _ ->
      return jar
    Nothing ->
      fmap CCFolder <$> asFolder fp

instance ClassReader FilePath where
  readClassFile fp cn = do
    x <- container fp
    case x of
      Just s ->
        readClassFile s cn
      Nothing ->
        return $ Left ClassNotFound

  classes fp = do
    x <- container fp
    maybe (pure []) classes x

-- | A ClassContainer is either a Jar or a folder.
data ClassContainer
  = CCFolder CFolder
  | CCJar CJar
  deriving (Show)

instance ClassReader (ClassContainer) where
  readClassFile (CCFolder x) = readClassFile x
  readClassFile (CCJar x) = readClassFile x

  classes (CCFolder x) = classes x
  classes (CCJar x) = classes x


makeLenses ''CFolder
makeLenses ''CJar

-- | ClassLoader contains all the paths used by the class loader.
data ClassLoader = ClassLoader
  { _lib       :: [ FilePath ]
  , _ext       :: [ FilePath ]
  , _classpath :: [ FilePath ]
  } deriving (Show, Eq)

makeLenses ''ClassLoader

-- | Creates a 'ClassLoader' from a class path, automatically predicts
-- the java version used using the 'which' command.
fromClassPath :: [ FilePath ] -> IO ClassLoader
fromClassPath fps = do
  java <- readProcess "which" ["java"] ""
  fromJreFolder fps $
    takeDirectory (takeDirectory java) </> "jre"

-- | Creates a 'ClassLoader' from a classpath and the jre folder
fromJreFolder :: [ FilePath ] -> FilePath -> IO ClassLoader
fromJreFolder clspath jre =
  ClassLoader
    <$> (jarsFromFolder $ jre </> "lib")
    <*> (jarsFromFolder $ jre </> "lib/ext")
    <*> pure clspath

-- | Returns the paths in the order they should be checked for classes
paths
  :: (Functor f, Monoid (f ClassLoader))
  => ([FilePath] -> f [FilePath])
  -> ClassLoader
  -> f ClassLoader
paths = lib <> ext <> classpath


-- | Get all the containers in a class loader
containers :: ClassLoader -> IO [ ClassContainer ]
containers cl = do
  c <- mapM container $ cl ^.. paths . traverse
  return $ catMaybes c

instance ClassReader ClassLoader where
  readClassFile cl cn =
    go =<< containers cl
    where
      go (p:ps) = do
        rcf <- readClassFile p cn
        case rcf of
          Right cls ->
            return $ Right cls
          Left (MalformedClass _) ->
            return rcf
          Left ClassNotFound ->
            go ps
      go [] =
        return $ Left ClassNotFound

  classes cl = do
     cls <- mapM classes =<< containers cl
     return $ concat cls

-- | A class preloader is just a map from all class names to all containers
-- they reside in. This can vastly improve the speed of looking up classes to load
-- them
newtype ClassPreloader = ClassPreloader
  { _classMap :: Map.Map ClassName [ ClassContainer ]
  } deriving (Show)

-- | Create a class preloader from any 'ClassReader'.
preload
  :: ClassReader r
  => r
  -> IO ClassPreloader
preload r = do
  cls <- classes r
  return
    . ClassPreloader
    . Map.fromListWith (++)
    $ map (_2 %~ (:[])) cls

-- | Creates a 'ClassPreloader' from a class path, automatically predicts
-- the java version used using the 'which' command.
preloadClassPath :: [ FilePath ] -> IO ClassPreloader
preloadClassPath cp = do
  ld <- fromClassPath cp
  preload ld

makeLenses ''ClassPreloader

instance ClassReader ClassPreloader where
  readClassFile (ClassPreloader cm) cn =
    case Map.lookup cn cm of
      Just (con:_) ->
        -- ^ Needs to be at least one container, we choose the first.
        readClassFile con cn
      _ ->
        return $ Left ClassNotFound

  classes (ClassPreloader cm) =
    return . concatMap (\(cn, cns) -> map (cn,) cns) $ Map.toList cm