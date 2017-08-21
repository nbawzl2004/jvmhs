{-# LANGUAGE TemplateHaskell   #-}
module Language.JVM.Class
  ( Class (..)

  , name
  , fields
  , interfaces
  , methods
  , super

  , fromBinary
  , decodeClassFrom
  , decodeClassOrFail
  , decodeClassOrFailFrom
  ) where

import qualified Data.Set                      as S
import qualified Data.Vector                   as V
import qualified Data.ByteString.Lazy          as BL

import           Data.Aeson
import           Data.Aeson.TH

import qualified Language.JVM.Binary.ClassFile as B
import qualified Language.JVM.Binary.Constant  as C
import           Language.JVM.ClassName
import qualified Language.JVM.Field            as Field
import qualified Language.JVM.Method           as Method

import Control.Lens

data Class = Class
  { _name       :: ClassName
  , _super      :: ClassName
  , _interfaces :: S.Set ClassName
  , _fields     :: [ Field.Field ]
  , _methods    :: [ Method.Method ]
  } deriving (Eq, Show)

fromBinary :: B.ClassFile -> Maybe Class
fromBinary clsf = do
  let cp = B.constantPool clsf
  _name <- C.lookupClassName (B.thisClass clsf) cp
  _super <- C.lookupClassName (B.superClass clsf) cp

  _interfaces <- S.fromList . V.toList <$>
    V.forM (B.interfaces clsf) (flip C.lookupClassName cp)

  _fields <- V.forM (B.fields clsf) $ Field.fromBinary cp

  _methods <- V.forM (B.methods clsf) $ Method.fromBinary cp

  return $ Class _name _super _interfaces (V.toList _fields) (V.toList _methods)

makeLenses ''Class

decodeClassFrom :: FilePath -> IO Class
decodeClassFrom fp = do
  cf <- B.decodeClassFileFrom fp
  let Just cls = fromBinary cf
  return cls

decodeClassOrFailFrom :: FilePath -> IO (Either String Class)
decodeClassOrFailFrom fp = do
  res <- B.decodeClassFileOrFailFrom fp
  return $ case res of
    Right cf ->
      case fromBinary cf of
        Just cl -> Right cl
        Nothing -> Left "Broken class-file format"
    Left msg -> Left $ "Could not decode class-file: " ++ msg

decodeClassOrFail :: BL.ByteString -> Either String Class
decodeClassOrFail bs = do
  case B.decodeClassFileOrFail bs of
    Right cf ->
      case fromBinary cf of
        Just cl -> Right cl
        Nothing -> Left "Broken class-file format"
    Left msg ->
      Left $ "Could not decode class-file: " ++ msg

deriveJSON (defaultOptions { fieldLabelModifier = drop 1}) ''Class