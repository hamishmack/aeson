{-# LANGUAGE CPP, DefaultSignatures, EmptyDataDecls, FlexibleInstances,
    FunctionalDependencies, KindSignatures, OverlappingInstances,
    ScopedTypeVariables, TypeOperators, UndecidableInstances,
    ViewPatterns, NamedFieldPuns, FlexibleContexts, PatternGuards,
    RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Module:      Data.Aeson.Types.Generic
-- Copyright:   (c) 2012 Bryan O'Sullivan
--              (c) 2011, 2012 Bas Van Dijk
--              (c) 2011 MailRank, Inc.
-- License:     Apache
-- Maintainer:  Bryan O'Sullivan <bos@serpentine.com>
-- Stability:   experimental
-- Portability: portable
--
-- Types for working with JSON data.

module Data.Aeson.Types.Generic ( ) where

import Control.Applicative ((<*>), (<$>), (<|>), pure)
import Control.Monad ((<=<))
import Control.Monad.ST (ST)
import Data.Aeson.Types.Class
import Data.Aeson.Types.Internal
import Data.Bits
import Data.DList (DList, toList, empty)
import Data.Maybe (fromMaybe)
import Data.Monoid (mappend)
import Data.Text (Text, pack, unpack)
import GHC.Generics
import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM

--------------------------------------------------------------------------------
-- Generic toJSON

instance (GToJSON a) => GToJSON (M1 i c a) where
    -- Meta-information, which is not handled elsewhere, is ignored:
    gToJSON opts = gToJSON opts . unM1
    {-# INLINE gToJSON #-}

instance (ToJSON a) => GToJSON (K1 i a) where
    -- Constant values are encoded using their ToJSON instance:
    gToJSON _opts = toJSON . unK1
    {-# INLINE gToJSON #-}

instance GToJSON U1 where
    -- Empty constructors are encoded to an empty array:
    gToJSON _opts _ = emptyArray
    {-# INLINE gToJSON #-}

instance (ConsToJSON a) => GToJSON (C1 c a) where
    -- Constructors need to be encoded differently depending on whether they're
    -- a record or not. This distinction is made by 'constToJSON':
    gToJSON opts = consToJSON opts . unM1
    {-# INLINE gToJSON #-}

instance ( WriteProduct a, WriteProduct b
         , ProductSize  a, ProductSize  b ) => GToJSON (a :*: b) where
    -- Products are encoded to an array. Here we allocate a mutable vector of
    -- the same size as the product and write the product's elements to it using
    -- 'writeProduct':
    gToJSON opts p =
        Array $ V.create $ do
          mv <- VM.unsafeNew lenProduct
          writeProduct opts mv 0 lenProduct p
          return mv
        where
          lenProduct = (unTagged2 :: Tagged2 (a :*: b) Int -> Int)
                       productSize
    {-# INLINE gToJSON #-}

instance ( AllNullary (a :+: b) allNullary
         , SumToJSON  (a :+: b) allNullary ) => GToJSON (a :+: b) where
    -- If all constructors of a sum datatype are nullary and the
    -- 'nullaryToString' option is set they are encoded to strings.
    -- This distinction is made by 'sumToJSON':
    gToJSON opts = (unTagged :: Tagged allNullary Value -> Value)
                 . sumToJSON opts
    {-# INLINE gToJSON #-}

--------------------------------------------------------------------------------

class SumToJSON f allNullary where
    sumToJSON :: Options -> f a -> Tagged allNullary Value

instance ( GetConName            f
         , ObjectWithType        f
         , ObjectWithSingleField f
         , TwoElemArray          f ) => SumToJSON f True where
    sumToJSON opts
        | nullaryToString opts = Tagged . String . pack
                               . constructorNameModifier opts . getConName
        | otherwise = Tagged . nonAllNullarySumToJSON opts
    {-# INLINE sumToJSON #-}

instance ( TwoElemArray          f
         , ObjectWithType        f
         , ObjectWithSingleField f ) => SumToJSON f False where
    sumToJSON opts = Tagged . nonAllNullarySumToJSON opts
    {-# INLINE sumToJSON #-}

nonAllNullarySumToJSON :: ( TwoElemArray          f
                          , ObjectWithType        f
                          , ObjectWithSingleField f
                          ) => Options -> f a -> Value
nonAllNullarySumToJSON opts =
    case sumEncoding opts of
      ObjectWithType{..}    -> object . objectWithType opts typeFieldName
                                                            valueFieldName
      ObjectWithSingleField -> Object . objectWithSingleField opts
      TwoElemArray          -> Array  . twoElemArray opts
{-# INLINE nonAllNullarySumToJSON #-}

--------------------------------------------------------------------------------

class ObjectWithType f where
    objectWithType :: Options -> String -> String -> f a -> [Pair]

instance ( ObjectWithType a
         , ObjectWithType b ) => ObjectWithType (a :+: b) where
    objectWithType     opts typeFieldName valueFieldName (L1 x) =
        objectWithType opts typeFieldName valueFieldName     x
    objectWithType     opts typeFieldName valueFieldName (R1 x) =
        objectWithType opts typeFieldName valueFieldName     x
    {-# INLINE objectWithType #-}

instance ( IsRecord        a isRecord
         , ObjectWithType' a isRecord
         , Constructor c ) => ObjectWithType (C1 c a) where
    objectWithType opts typeFieldName valueFieldName =
        (pack typeFieldName .= constructorNameModifier opts
                                 (conName (undefined :: t c a p)) :) .
        (unTagged :: Tagged isRecord [Pair] -> [Pair]) .
          objectWithType' opts valueFieldName . unM1
    {-# INLINE objectWithType #-}

class ObjectWithType' f isRecord where
    objectWithType' :: Options -> String -> f a -> Tagged isRecord [Pair]

instance (RecordToPairs f) => ObjectWithType' f True where
    objectWithType' opts _ = Tagged . toList . recordToPairs opts
    {-# INLINE objectWithType' #-}

instance (GToJSON f) => ObjectWithType' f False where
    objectWithType' opts valueFieldName =
        Tagged . (:[]) . (pack valueFieldName .=) . gToJSON opts
    {-# INLINE objectWithType' #-}

--------------------------------------------------------------------------------

-- | Get the name of the constructor of a sum datatype.
class GetConName f where
    getConName :: f a -> String

instance (GetConName a, GetConName b) => GetConName (a :+: b) where
    getConName (L1 x) = getConName x
    getConName (R1 x) = getConName x
    {-# INLINE getConName #-}

instance (Constructor c, GToJSON a, ConsToJSON a) => GetConName (C1 c a) where
    getConName = conName
    {-# INLINE getConName #-}

--------------------------------------------------------------------------------

class TwoElemArray f where
    twoElemArray :: Options -> f a -> V.Vector Value

instance (TwoElemArray a, TwoElemArray b) => TwoElemArray (a :+: b) where
    twoElemArray opts (L1 x) = twoElemArray opts x
    twoElemArray opts (R1 x) = twoElemArray opts x
    {-# INLINE twoElemArray #-}

instance ( GToJSON a, ConsToJSON a
         , Constructor c ) => TwoElemArray (C1 c a) where
    twoElemArray opts x = V.create $ do
      mv <- VM.unsafeNew 2
      VM.unsafeWrite mv 0 $ String $ pack $ constructorNameModifier opts
                                   $ conName (undefined :: t c a p)
      VM.unsafeWrite mv 1 $ gToJSON opts x
      return mv
    {-# INLINE twoElemArray #-}

--------------------------------------------------------------------------------

class ConsToJSON f where
    consToJSON  :: Options -> f a -> Value

class ConsToJSON' f isRecord where
    consToJSON' :: Options -> f a -> Tagged isRecord Value

instance ( IsRecord    f isRecord
         , ConsToJSON' f isRecord ) => ConsToJSON f where
    consToJSON opts = (unTagged :: Tagged isRecord Value -> Value)
                    . consToJSON' opts
    {-# INLINE consToJSON #-}

instance (RecordToPairs f) => ConsToJSON' f True where
    consToJSON' opts = Tagged . object . toList . recordToPairs opts
    {-# INLINE consToJSON' #-}

instance GToJSON f => ConsToJSON' f False where
    consToJSON' opts = Tagged . gToJSON opts
    {-# INLINE consToJSON' #-}

--------------------------------------------------------------------------------

class RecordToPairs f where
    recordToPairs :: Options -> f a -> DList Pair

instance (RecordToPairs a, RecordToPairs b) => RecordToPairs (a :*: b) where
    recordToPairs opts (a :*: b) = recordToPairs opts a `mappend`
                                   recordToPairs opts b
    {-# INLINE recordToPairs #-}

instance (Selector s, GToJSON a) => RecordToPairs (S1 s a) where
    recordToPairs = fieldToPair
    {-# INLINE recordToPairs #-}

instance (Selector s, ToJSON a) => RecordToPairs (S1 s (K1 i (Maybe a))) where
    recordToPairs opts (M1 k1) | omitNothingFields opts
                               , K1 Nothing <- k1 = empty
    recordToPairs opts m1 = fieldToPair opts m1
    {-# INLINE recordToPairs #-}

fieldToPair :: (Selector s, GToJSON a) => Options -> S1 s a p -> DList Pair
fieldToPair opts m1 = pure ( pack $ fieldNameModifier opts $ selName m1
                           , gToJSON opts (unM1 m1)
                           )
{-# INLINE fieldToPair #-}

--------------------------------------------------------------------------------

class WriteProduct f where
    writeProduct :: Options
                 -> VM.MVector s Value
                 -> Int -- ^ index
                 -> Int -- ^ length
                 -> f a
                 -> ST s ()

instance ( WriteProduct a
         , WriteProduct b ) => WriteProduct (a :*: b) where
    writeProduct opts mv ix len (a :*: b) = do
      writeProduct opts mv ix  lenL a
      writeProduct opts mv ixR lenR b
        where
#if MIN_VERSION_base(4,5,0)
          lenL = len `unsafeShiftR` 1
#else
          lenL = len `shiftR` 1
#endif
          lenR = len - lenL
          ixR  = ix  + lenL
    {-# INLINE writeProduct #-}

instance (GToJSON a) => WriteProduct a where
    writeProduct opts mv ix _ = VM.unsafeWrite mv ix . gToJSON opts
    {-# INLINE writeProduct #-}

--------------------------------------------------------------------------------

class ObjectWithSingleField f where
    objectWithSingleField :: Options -> f a -> Object

instance ( ObjectWithSingleField a
         , ObjectWithSingleField b ) => ObjectWithSingleField (a :+: b) where
    objectWithSingleField opts (L1 x) = objectWithSingleField opts x
    objectWithSingleField opts (R1 x) = objectWithSingleField opts x
    {-# INLINE objectWithSingleField #-}

instance ( GToJSON a, ConsToJSON a
         , Constructor c ) => ObjectWithSingleField (C1 c a) where
    objectWithSingleField opts = H.singleton typ . gToJSON opts
        where
          typ = pack $ constructorNameModifier opts $
                         conName (undefined :: t c a p)
    {-# INLINE objectWithSingleField #-}

--------------------------------------------------------------------------------
-- Generic parseJSON

instance (GFromJSON a) => GFromJSON (M1 i c a) where
    -- Meta-information, which is not handled elsewhere, is just added to the
    -- parsed value:
    gParseJSON opts = fmap M1 . gParseJSON opts
    {-# INLINE gParseJSON #-}

instance (FromJSON a) => GFromJSON (K1 i a) where
    -- Constant values are decoded using their FromJSON instance:
    gParseJSON _opts = fmap K1 . parseJSON
    {-# INLINE gParseJSON #-}

instance GFromJSON U1 where
    -- Empty constructors are expected to be encoded as an empty array:
    gParseJSON _opts v
        | isEmptyArray v = pure U1
        | otherwise      = typeMismatch "unit constructor (U1)" v
    {-# INLINE gParseJSON #-}

instance (ConsFromJSON a) => GFromJSON (C1 c a) where
    -- Constructors need to be decoded differently depending on whether they're
    -- a record or not. This distinction is made by consParseJSON:
    gParseJSON opts = fmap M1 . consParseJSON opts
    {-# INLINE gParseJSON #-}

instance ( FromProduct a, FromProduct b
         , ProductSize a, ProductSize b ) => GFromJSON (a :*: b) where
    -- Products are expected to be encoded to an array. Here we check whether we
    -- got an array of the same size as the product, then parse each of the
    -- product's elements using parseProduct:
    gParseJSON opts = withArray "product (:*:)" $ \arr ->
      let lenArray = V.length arr
          lenProduct = (unTagged2 :: Tagged2 (a :*: b) Int -> Int)
                       productSize in
      if lenArray == lenProduct
      then parseProduct opts arr 0 lenProduct
      else fail $ "When expecting a product of " ++ show lenProduct ++
                  " values, encountered an Array of " ++ show lenArray ++
                  " elements instead"
    {-# INLINE gParseJSON #-}

instance ( AllNullary (a :+: b) allNullary
         , ParseSum   (a :+: b) allNullary ) => GFromJSON   (a :+: b) where
    -- If all constructors of a sum datatype are nullary and the
    -- 'nullaryToString' option is set they are expected to be encoded as
    -- strings.  This distinction is made by 'parseSum':
    gParseJSON opts = (unTagged :: Tagged allNullary (Parser ((a :+: b) d)) ->
                                                     (Parser ((a :+: b) d)))
                    . parseSum opts
    {-# INLINE gParseJSON #-}

--------------------------------------------------------------------------------

class ParseSum f allNullary where
    parseSum :: Options -> Value -> Tagged allNullary (Parser (f a))

instance ( SumFromString      (a :+: b)
         , FromPair           (a :+: b)
         , FromObjectWithType (a :+: b) ) => ParseSum (a :+: b) True where
    parseSum opts
        | nullaryToString opts = Tagged . parseAllNullarySum    opts
        | otherwise            = Tagged . parseNonAllNullarySum opts
    {-# INLINE parseSum #-}

instance ( FromPair           (a :+: b)
         , FromObjectWithType (a :+: b) ) => ParseSum (a :+: b) False where
    parseSum opts = Tagged . parseNonAllNullarySum opts
    {-# INLINE parseSum #-}

--------------------------------------------------------------------------------

parseAllNullarySum :: SumFromString f => Options -> Value -> Parser (f a)
parseAllNullarySum opts = withText "Text" $ \key ->
                            maybe (notFound $ unpack key) return $
                              parseSumFromString opts key
{-# INLINE parseAllNullarySum #-}

class SumFromString f where
    parseSumFromString :: Options -> Text -> Maybe (f a)

instance (SumFromString a, SumFromString b) => SumFromString (a :+: b) where
    parseSumFromString opts key = (L1 <$> parseSumFromString opts key) <|>
                                  (R1 <$> parseSumFromString opts key)
    {-# INLINE parseSumFromString #-}

instance (Constructor c) => SumFromString (C1 c U1) where
    parseSumFromString opts key | key == name = Just $ M1 U1
                                | otherwise   = Nothing
        where
          name = pack $ constructorNameModifier opts $
                          conName (undefined :: t c U1 p)
    {-# INLINE parseSumFromString #-}

--------------------------------------------------------------------------------

parseNonAllNullarySum :: ( FromPair                       (a :+: b)
                         , FromObjectWithType             (a :+: b)
                         ) => Options -> Value -> Parser ((a :+: b) c)
parseNonAllNullarySum opts =
    case sumEncoding opts of
      ObjectWithType{..}    ->
          withObject "Object" $ \obj -> do
            key <- obj .: pack typeFieldName
            fromMaybe (notFound $ unpack key) $
              parseFromObjectWithType opts valueFieldName obj key

      ObjectWithSingleField ->
          withObject "Object" $ \obj ->
            case H.toList obj of
              [keyVal@(key, _)] -> fromMaybe (notFound $ unpack key) $
                                     parsePair opts keyVal
              _ -> fail "Object doesn't have a single field"

      TwoElemArray ->
          withArray "Array" $ \arr ->
            if V.length arr == 2
            then case V.unsafeIndex arr 0 of
                   String key -> fromMaybe (notFound $ unpack key) $
                                   parsePair opts (key, V.unsafeIndex arr 1)
                   _ -> fail "First element is not a String"
            else fail "Array doesn't have 2 elements"
{-# INLINE parseNonAllNullarySum #-}

--------------------------------------------------------------------------------

class FromObjectWithType f where
    parseFromObjectWithType :: Options -> String -> Object -> Text
                            -> Maybe (Parser (f a))

instance (FromObjectWithType a, FromObjectWithType b) =>
    FromObjectWithType (a :+: b) where
        parseFromObjectWithType opts valueFieldName obj key =
            (fmap L1 <$> parseFromObjectWithType opts valueFieldName obj key) <|>
            (fmap R1 <$> parseFromObjectWithType opts valueFieldName obj key)
        {-# INLINE parseFromObjectWithType #-}

instance ( FromObjectWithType' f
         , Constructor c ) => FromObjectWithType (C1 c f) where
    parseFromObjectWithType opts valueFieldName obj key
        | key == name = Just $ M1 <$> parseFromObjectWithType'
                                        opts valueFieldName obj
        | otherwise = Nothing
        where
          name = pack $ constructorNameModifier opts $
                          conName (undefined :: t c f p)
    {-# INLINE parseFromObjectWithType #-}

--------------------------------------------------------------------------------

class FromObjectWithType' f where
    parseFromObjectWithType' :: Options -> String -> Object -> Parser (f a)

class FromObjectWithType'' f isRecord where
    parseFromObjectWithType'' :: Options -> String -> Object
                              -> Tagged isRecord (Parser (f a))

instance ( IsRecord               f isRecord
         , FromObjectWithType''   f isRecord
         ) => FromObjectWithType' f where
    parseFromObjectWithType' opts valueFieldName =
        (unTagged :: Tagged isRecord (Parser (f a)) -> Parser (f a)) .
        parseFromObjectWithType'' opts valueFieldName
    {-# INLINE parseFromObjectWithType' #-}

instance (FromRecord f) => FromObjectWithType'' f True where
    parseFromObjectWithType'' opts _ = Tagged . parseRecord opts
    {-# INLINE parseFromObjectWithType'' #-}

instance (GFromJSON f) => FromObjectWithType'' f False where
    parseFromObjectWithType'' opts valueFieldName = Tagged .
      (gParseJSON opts <=< (.: pack valueFieldName))
    {-# INLINE parseFromObjectWithType'' #-}

--------------------------------------------------------------------------------

class ConsFromJSON f where
    consParseJSON  :: Options -> Value -> Parser (f a)

class ConsFromJSON' f isRecord where
    consParseJSON' :: Options -> Value -> Tagged isRecord (Parser (f a))

instance ( IsRecord        f isRecord
         , ConsFromJSON'   f isRecord
         ) => ConsFromJSON f where
    consParseJSON opts = (unTagged :: Tagged isRecord (Parser (f a)) -> Parser (f a))
                       . consParseJSON' opts
    {-# INLINE consParseJSON #-}

instance (FromRecord f) => ConsFromJSON' f True where
    consParseJSON' opts = Tagged . (withObject "record (:*:)" $ parseRecord opts)
    {-# INLINE consParseJSON' #-}

instance (GFromJSON f) => ConsFromJSON' f False where
    consParseJSON' opts = Tagged . gParseJSON opts
    {-# INLINE consParseJSON' #-}

--------------------------------------------------------------------------------

class FromRecord f where
    parseRecord :: Options -> Object -> Parser (f a)

instance (FromRecord a, FromRecord b) => FromRecord (a :*: b) where
    parseRecord opts obj = (:*:) <$> parseRecord opts obj
                                 <*> parseRecord opts obj
    {-# INLINE parseRecord #-}

instance (Selector s, GFromJSON a) => FromRecord (S1 s a) where
    parseRecord opts = maybe (notFound key) (gParseJSON opts)
                      . H.lookup (pack key)
        where
          key = fieldNameModifier opts $ selName (undefined :: t s a p)
    {-# INLINE parseRecord #-}

instance (Selector s, FromJSON a) => FromRecord (S1 s (K1 i (Maybe a))) where
    parseRecord opts obj = (M1 . K1) <$> obj .:? pack key
        where
          key = fieldNameModifier opts $
                  selName (undefined :: t s (K1 i (Maybe a)) p)
    {-# INLINE parseRecord #-}

--------------------------------------------------------------------------------

class ProductSize f where
    productSize :: Tagged2 f Int

instance (ProductSize a, ProductSize b) => ProductSize (a :*: b) where
    productSize = Tagged2 $ unTagged2 (productSize :: Tagged2 a Int) +
                            unTagged2 (productSize :: Tagged2 b Int)
    {-# INLINE productSize #-}

instance ProductSize (S1 s a) where
    productSize = Tagged2 1
    {-# INLINE productSize #-}

--------------------------------------------------------------------------------

class FromProduct f where
    parseProduct :: Options -> Array -> Int -> Int -> Parser (f a)

instance (FromProduct a, FromProduct b) => FromProduct (a :*: b) where
    parseProduct opts arr ix len =
        (:*:) <$> parseProduct opts arr ix  lenL
              <*> parseProduct opts arr ixR lenR
        where
#if MIN_VERSION_base(4,5,0)
          lenL = len `unsafeShiftR` 1
#else
          lenL = len `shiftR` 1
#endif
          ixR  = ix + lenL
          lenR = len - lenL
    {-# INLINE parseProduct #-}

instance (GFromJSON a) => FromProduct (S1 s a) where
    parseProduct opts arr ix _ = gParseJSON opts $ V.unsafeIndex arr ix
    {-# INLINE parseProduct #-}

--------------------------------------------------------------------------------

class FromPair f where
    parsePair :: Options -> Pair -> Maybe (Parser (f a))

instance (FromPair a, FromPair b) => FromPair (a :+: b) where
    parsePair opts keyVal = (fmap L1 <$> parsePair opts keyVal) <|>
                            (fmap R1 <$> parsePair opts keyVal)
    {-# INLINE parsePair #-}

instance (Constructor c, GFromJSON a, ConsFromJSON a) => FromPair (C1 c a) where
    parsePair opts (key, value)
        | key == name = Just $ gParseJSON opts value
        | otherwise   = Nothing
        where
          name = pack $ constructorNameModifier opts $
                          conName (undefined :: t c a p)
    {-# INLINE parsePair #-}

--------------------------------------------------------------------------------

class IsRecord (f :: * -> *) isRecord | f -> isRecord

instance (IsRecord f isRecord) => IsRecord (f :*: g) isRecord
instance IsRecord (M1 S NoSelector f) False
instance (IsRecord f isRecord) => IsRecord (M1 S c f) isRecord
instance IsRecord (K1 i c) True
instance IsRecord U1 False

--------------------------------------------------------------------------------

class AllNullary (f :: * -> *) allNullary | f -> allNullary

instance ( AllNullary a allNullaryL
         , AllNullary b allNullaryR
         , And allNullaryL allNullaryR allNullary
         ) => AllNullary (a :+: b) allNullary
instance AllNullary a allNullary => AllNullary (M1 i c a) allNullary
instance AllNullary (a :*: b) False
instance AllNullary (K1 i c) False
instance AllNullary U1 True

--------------------------------------------------------------------------------

data True
data False

class    And bool1 bool2 bool3 | bool1 bool2 -> bool3

instance And True  True  True
instance And False False False
instance And False True  False
instance And True  False False

--------------------------------------------------------------------------------

newtype Tagged s b = Tagged {unTagged :: b}

newtype Tagged2 (s :: * -> *) b = Tagged2 {unTagged2 :: b}

--------------------------------------------------------------------------------

notFound :: String -> Parser a
notFound key = fail $ "The key \"" ++ key ++ "\" was not found"
{-# INLINE notFound #-}
