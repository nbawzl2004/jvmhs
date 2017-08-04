module Language.JVM.Binary.ClassFile
  ( ClassFile(..)
  , decodeClassFile
  ) where

-- Information from http://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.4
-- And from https://en.wikipedia.org/wiki/Java_class_file#cite_note-jvms-4.4-4


import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Put
import           Data.Bits
import           Data.List                     (foldl')
import qualified Data.Set                      as S
import qualified Data.Vector                   as V

import           Language.JVM.Binary.Attribute (Attribute)
import           Language.JVM.Binary.Constant  ( ConstantRef
                                               , getConstantRef
                                               , putConstantRef
                                               , ConstantPool
                                               )
import           Language.JVM.Binary.Helpers
import           Language.JVM.Binary.Field     (Field)
import           Language.JVM.Binary.Method    (Method)

data ClassFile = ClassFile
  { magicNumber       :: !Word32

  , minorVersion      :: !Word16
  , majorVersion      :: !Word16

  -- , constantPoolCount :: !Word16
  , constantPool      :: ConstantPool

  , accessFlags       :: AccessFlags

  , thisClass         :: ConstantRef
  , superClass        :: ConstantRef

  -- , interfacesCount   :: !Word16
  , interfaces        :: V.Vector ConstantRef

  -- , fieldsCount       :: !Word16
  , fields            :: V.Vector Field

  -- , methodsCount      :: !Word16
  , methods           :: V.Vector Method

  -- , attributeCount    :: !Word16
  , attributes        :: V.Vector Attribute
  } deriving (Show, Eq)

instance Binary ClassFile where
  get = ClassFile
    <$> getWord32be

    <*> getWord16be
    <*> getWord16be

    -- ConstantPool
    <*> get

    <*> get

    <*> getConstantRef
    <*> getConstantRef

    <*> getVector
    <*> getVector
    <*> getVector
    <*> getVector

  put clfile = sequence_ $
    [ put . magicNumber
    , put . minorVersion
    , put . majorVersion
    , put . constantPool
    , put . accessFlags
    , putConstantRef . thisClass
    , putConstantRef . superClass
    , putVector . interfaces
    , putVector . fields
    , putVector . methods
    , putVector . attributes
    ] <*> [ clfile ]

decodeClassFile :: FilePath -> IO ClassFile
decodeClassFile = decodeFile

data AccessFlag
  = Public
  | Unused2
  | Unused3
  | Unused4
  | Final
  | Super
  | Unused7
  | Unused8
  | Unused9
  | Unused10
  | Abstract
  | Unused12
  | Synthetic
  | Annotation
  | Enum
  deriving (Ord, Show, Eq, Enum)


newtype AccessFlags = AccessFlags (S.Set AccessFlag)
  deriving (Ord, Show, Eq)

instance Binary AccessFlags where
  get = do
    word <- getWord16be
    return . AccessFlags $ S.fromList [ toEnum x | x <- [0..15], testBit word x ]

  put (AccessFlags f) = do
    let word = foldl' setBit zeroBits (map fromEnum $ S.toList f)
    putWord16be word