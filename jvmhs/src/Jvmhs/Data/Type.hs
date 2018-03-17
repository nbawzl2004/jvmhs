{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-|
Module : Jvmhs.Data.Type
Copyright : (c) Christian Gram Kalhauge, 2018
License  : MIT
Maintainer : kalhauge@cs.ucla.edu

This module reexports the Types from the `jvm-binary` packages, and creates
lenses and toJSON instances for them.

This *will* create orhpaned instances, so do not import without

-}
module Jvmhs.Data.Type
  ( ClassName
  , dotCls
  , strCls
  , splitClassName
  , fullyQualifiedName
  , package
  , shorthand

  , MethodDescriptor (..)
  , methodDArguments
  , methodDReturnType

  , FieldDescriptor (..)
  , fieldDType

  , JType (..)
  , JValue (..)
  , valueFromConstant

  , MAccessFlag (..)
  , FAccessFlag (..)
  , CAccessFlag (..)
  ) where

import           Control.Lens
import           Data.Aeson
import           Data.Int
import           Data.Aeson.TH
import qualified Data.Text               as Text

import           Language.JVM.AccessFlag
import           Language.JVM.Constant
import           Language.JVM.Utils
import           Language.JVM.Type

-- * ClassName

type Package = [ Text.Text ]

makeWrapped ''ClassName

-- | Create a class from a list of dots "java.lang.Object" returns
-- (ClassName "java/lang/Object")
dotCls :: String -> ClassName
dotCls s = (Text.splitOn "." $ Text.pack s)^.from splitClassName

fullyQualifiedName :: Iso' ClassName Text.Text
fullyQualifiedName = _Wrapped

-- | Splits a ClassName in it's components
splitClassName :: Iso' ClassName [Text.Text]
splitClassName =
  fullyQualifiedName . split
  where
    split = iso (Text.splitOn "/") (Text.intercalate "/")

-- | The package name of the class name
package :: Traversal' ClassName Package
package =
  splitClassName . _init

-- | The shorthand name of the class name
shorthand :: Traversal' ClassName Text.Text
shorthand =
  splitClassName . _last

-- * MethodDescriptor

-- | Get a the argument types from a method descriptor
methodDArguments :: Lens' MethodDescriptor [JType]
methodDArguments =
  lens
    methodDescriptorArguments
    (\md a -> md { methodDescriptorArguments = a })

-- | Get a the return type from a method descriptor
methodDReturnType :: Lens' MethodDescriptor (Maybe JType)
methodDReturnType =
  lens methodDescriptorReturnType
    (\md a -> md { methodDescriptorReturnType = a})


-- * FieldDescriptor

-- | Get the type from a field descriptor
fieldDType :: Iso' FieldDescriptor JType
fieldDType =
  coerced
{-# INLINE fieldDType #-}

-- fromText :: Iso' (Maybe Text.Text) (Maybe FieldDescriptor)
-- fromText =
--   iso B.fieldDescriptorFromText B.fieldDescriptorToText

-- * JType

-- * Value

-- | A simple value in java
data JValue
  = VInt Int32
  | VLong Int64
  | VFloat Float
  | VDouble Double
  | VString Text.Text
  deriving (Show, Eq)

valueFromConstant :: Prism' (Constant High) JValue
valueFromConstant =
  prism' fromValue toValue
  where
    fromValue v =
      case v of
        VInt i -> CInteger i
        VLong i -> CLong i
        VFloat i -> CFloat i
        VDouble i -> CDouble i
        VString i -> CString (sizedByteStringFromText i)
    toValue v =
      case v of
        CInteger i -> Just $ VInt i
        CLong i ->    Just $ VLong i
        CFloat i ->   Just $ VFloat i
        CDouble i ->  Just $ VDouble i
        CString i ->  VString <$> (sizedByteStringToText i ^? _Right)
        _ -> Nothing



-- * Instances

instance ToJSON ClassName where
  toJSON = String . view fullyQualifiedName

instance ToJSON FieldDescriptor where
  toJSON = String . fieldDescriptorToText

instance ToJSON MethodDescriptor where
  toJSON = String . methodDescriptorToText

$(deriveToJSON (defaultOptions { constructorTagModifier = drop 1 }) ''CAccessFlag)
$(deriveToJSON (defaultOptions { constructorTagModifier = drop 1 }) ''FAccessFlag)
$(deriveToJSON (defaultOptions { constructorTagModifier = drop 1 }) ''MAccessFlag)

$(deriveToJSON (defaultOptions { constructorTagModifier = drop 1 }) ''JValue)
