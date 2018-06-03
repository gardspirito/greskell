{-# LANGUAGE OverloadedStrings, DeriveGeneric, TypeFamilies #-}
-- |
-- Module: Data.Greskell.GraphSON
-- Description: Encoding and decoding GraphSON
-- Maintainer: Toshio Ito <debug.ito@gmail.com>
--
-- 
module Data.Greskell.GraphSON
       ( -- * GraphSON
         GraphSON(..),
         GraphSONTyped(..),
         -- ** constructors
         nonTypedGraphSON,
         typedGraphSON,
         typedGraphSON',
         -- ** parser support
         parseTypedGraphSON,
         -- * GValue
         GValue(..),
         GValueBody(..),
         -- ** constructors
         nonTypedGValue,
         typedGValue',
         -- ** deconstructors
         gValueBody,
         gValueType,
         unwrapAll,
         unwrapOne,
         -- * FromGraphSON
         FromGraphSON(..),
         -- ** parser support
         parseUnwrapAll,
         parseUnwrapList,
         (.:),
         parseEither
       ) where

import Control.Applicative ((<$>), (<*>), (<|>))
import Control.Monad (when)
import Data.Aeson
  ( ToJSON(toJSON), FromJSON(parseJSON), FromJSONKey,
    object, (.=), Value(..)
  )
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Types as Aeson (parseEither)
import Data.Foldable (Foldable(foldr), foldl')
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import qualified Data.HashMap.Lazy as L (HashMap)
import Data.HashSet (HashSet)
import Data.Hashable (Hashable(..))
import Data.Int (Int8, Int16, Int32, Int64)
import qualified Data.IntMap.Lazy as L (IntMap)
import qualified Data.IntMap.Lazy as LIntMap
import Data.IntSet (IntSet)
import qualified Data.Map.Lazy as L (Map)
import qualified Data.Map.Lazy as LMap
import Data.Monoid (mempty)
import Data.Ratio (Ratio)
import Data.Scientific (Scientific)
import Data.Sequence (Seq)
import Data.Set (Set)
import Data.Text (Text, unpack)
import qualified Data.Text.Lazy as TL
import Data.Traversable (Traversable(traverse))
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.Vector (Vector)
import Data.Word (Word8, Word16, Word32, Word64)
import Numeric.Natural (Natural)
import GHC.Exts (IsList(Item))
import qualified GHC.Exts as List (fromList, toList)
import GHC.Generics (Generic)

import Data.Greskell.GraphSON.GraphSONTyped (GraphSONTyped(..))
import Data.Greskell.GMap
  ( GMap, GMapEntry, unGMap,
    FlattenedMap, parseToFlattenedMap, parseToGMap, parseToGMapEntry
  )

-- $
-- >>> :set -XOverloadedStrings

-- | Wrapper for \"typed JSON object\" introduced in GraphSON version
-- 2. See http://tinkerpop.apache.org/docs/current/dev/io/#graphson
--
-- This data type is useful for encoding/decoding GraphSON text.
-- 
-- >>> Aeson.decode "1000" :: Maybe (GraphSON Int32)
-- Just (GraphSON {gsonType = Nothing, gsonValue = 1000})
-- >>> Aeson.decode "{\"@type\": \"g:Int32\", \"@value\": 1000}" :: Maybe (GraphSON Int32)
-- Just (GraphSON {gsonType = Just "g:Int32", gsonValue = 1000})
--
-- Note that encoding of the \"g:Map\" type is inconsistent between
-- GraphSON v1, v2 and v3. To handle the encoding, use
-- "Data.Greskell.GMap".
data GraphSON v =
  GraphSON
  { gsonType :: Maybe Text,
    -- ^ Type ID, corresponding to @\@type@ field.
    gsonValue :: v
    -- ^ Value, correspoding to @\@value@ field.
  }
  deriving (Show,Eq,Ord,Generic)

instance Functor GraphSON where
  fmap f gs = gs { gsonValue = f $ gsonValue gs }

instance Foldable GraphSON where
  foldr f start gs = f (gsonValue gs) start

instance Traversable GraphSON where
  traverse f gs = fmap (\v -> gs { gsonValue = v }) $ f $ gsonValue gs

instance Hashable v => Hashable (GraphSON v)

-- | Create a 'GraphSON' without 'gsonType'.
--
-- >>> nonTypedGraphSON (10 :: Int)
-- GraphSON {gsonType = Nothing, gsonValue = 10}
nonTypedGraphSON :: v -> GraphSON v
nonTypedGraphSON = GraphSON Nothing

-- | Create a 'GraphSON' with its type ID.
--
-- >>> typedGraphSON (10 :: Int32)
-- GraphSON {gsonType = Just "g:Int32", gsonValue = 10}
typedGraphSON :: GraphSONTyped v => v -> GraphSON v
typedGraphSON v = GraphSON (Just $ gsonTypeFor v) v

-- | Create a 'GraphSON' with the given type ID.
--
-- >>> typedGraphSON' "g:Int32" (10 :: Int)
-- GraphSON {gsonType = Just "g:Int32", gsonValue = 10}
typedGraphSON' :: Text -> v -> GraphSON v
typedGraphSON' t = GraphSON (Just t)

-- | If 'gsonType' is 'Just', the 'GraphSON' is encoded as a typed
-- JSON object. If 'gsonType' is 'Nothing', the 'gsonValue' is
-- directly encoded.
instance ToJSON v => ToJSON (GraphSON v) where
  toJSON gson = case gsonType gson of
    Nothing -> toJSON $ gsonValue gson
    Just t -> object [ "@type" .= t,
                       "@value" .= gsonValue gson
                     ]

-- | If the given 'Value' is a typed JSON object, 'gsonType' field of
-- the result is 'Just'. Otherwise, the given 'Value' is directly
-- parsed into 'gsonValue', and 'gsonType' is 'Nothing'.
instance FromJSON v => FromJSON (GraphSON v) where
  parseJSON v@(Object o) = do
    if length o /= 2
      then parseDirect v
      else do
      mtype <- o Aeson..:! "@type"
      mvalue <- o Aeson..:! "@value"
      maybe (parseDirect v) return $ typedGraphSON' <$> mtype <*> mvalue
  parseJSON v = parseDirect v
    
parseDirect :: FromJSON v => Value -> Parser (GraphSON v)
parseDirect v = GraphSON Nothing <$> parseJSON v

-- | Parse @GraphSON v@, but it checks 'gsonType'. If 'gsonType' is
-- 'Nothing' or it's not equal to 'gsonTypeFor', the 'Parser' fails.
parseTypedGraphSON :: (GraphSONTyped v, FromJSON v) => Value -> Parser (GraphSON v)
parseTypedGraphSON v = either fail return =<< parseTypedGraphSON' v

-- | Note: this function is not exported because I don't need it for
-- now. If you need this function, just open an issue.
--
-- Like 'parseTypedGraphSON', but this handles parse errors in a finer
-- granularity.
--
-- - If the given 'Value' is not a typed JSON object, it returns
--   'Left'.
-- - If the given 'Value' is a typed JSON object but it fails to parse
--   the \"\@value\" field, the 'Parser' fails.
-- - If the given 'Value' is a typed JSON object but the \"\@type\"
--   field is not equal to the 'gsonTypeFor' of type @v@, the 'Parser'
--   fails.
-- - Otherwise (if the given 'Value' is a typed JSON object with valid
--   \"\@type\" and \"\@value\" fields,) it returns 'Right'.
parseTypedGraphSON' :: (GraphSONTyped v, FromJSON v) => Value -> Parser (Either String (GraphSON v))
parseTypedGraphSON' v = do
  graphsonv <- parseGraphSONPlain v
  case gsonType graphsonv of
   Nothing -> return $ Left ("Not a valid typed JSON object.")
   Just got_type -> do
     goal <- parseJSON $ gsonValue graphsonv
     let exp_type = gsonTypeFor goal 
     when (got_type /= exp_type) $ do
       fail ("Expected @type of " ++ show exp_type ++ ", but got " ++ show got_type)
     return $ Right $ graphsonv { gsonValue = goal }
  where
    parseGraphSONPlain :: Value -> Parser (GraphSON Value)
    parseGraphSONPlain = parseJSON



-- | An Aeson 'Value' wrapped in 'GraphSON' wrapper type. Basically
-- this type is the Haskell representaiton of a GraphSON-encoded
-- document.
--
-- This type is used to parse GraphSON documents. See also
-- 'FromGraphSON' class.
newtype GValue = GValue { unGValue :: GraphSON GValueBody }
                 deriving (Show,Eq,Generic)

instance Hashable GValue

data GValueBody =
    GObject !(HashMap Text GValue)
  | GArray !(Vector GValue)
  | GString !Text
  | GNumber !Scientific
  | GBool !Bool
  | GNull
  deriving (Show,Eq,Generic)

instance Hashable GValueBody where
-- See Data.Aeson.Types.Internal
  hashWithSalt s (GObject o) = s `hashWithSalt` (0::Int) `hashWithSalt` o
  hashWithSalt s (GArray a) = foldl' hashWithSalt (s `hashWithSalt` (1::Int)) a
  hashWithSalt s (GString str) = s `hashWithSalt` (2::Int) `hashWithSalt` str
  hashWithSalt s (GNumber n) = s `hashWithSalt` (3::Int) `hashWithSalt` n
  hashWithSalt s (GBool b) = s `hashWithSalt` (4::Int) `hashWithSalt` b
  hashWithSalt s GNull = s `hashWithSalt` (5::Int)

-- | Parse 'GraphSON' wrappers recursively in 'Value', making it into
-- 'GValue'.
instance FromJSON GValue where
  parseJSON input = do
    gv <- parseJSON input
    recursed_value <- recurse $ gsonValue gv
    return $ GValue $ gv { gsonValue = recursed_value }
    where
      recurse :: Value -> Parser GValueBody
      recurse (Object o) = GObject <$> traverse parseJSON o
      recurse (Array a) = GArray <$> traverse parseJSON a
      recurse (String s) = return $ GString s
      recurse (Number n) = return $ GNumber n
      recurse (Bool b) = return $ GBool b
      recurse Null = return GNull

-- | Reconstruct 'Value' from 'GValue'.
instance ToJSON GValue where
  toJSON (GValue gson_body) = toJSON $ fmap toJSON gson_body

instance ToJSON GValueBody where
  toJSON (GObject o) = toJSON o
  toJSON (GArray a) = toJSON a
  toJSON (GString s) = String s
  toJSON (GNumber n) = Number n
  toJSON (GBool b) = Bool b
  toJSON GNull = Null

-- | Create a 'GValue' without \"@type\" field.
nonTypedGValue :: GValueBody -> GValue
nonTypedGValue = GValue . nonTypedGraphSON

-- | Create a 'GValue' with the given \"@type\" field.
typedGValue' :: Text -- ^ \"@type\" field.
             -> GValueBody -> GValue
typedGValue' t b = GValue $ typedGraphSON' t b

-- | Remove all 'GraphSON' wrappers recursively from 'GValue'.
unwrapAll :: GValue -> Value
unwrapAll = unwrapBase unwrapAll

-- | Remove the top-level 'GraphSON' wrapper, but leave other wrappers
-- as-is. The remaining wrappers are reconstructed by 'toJSON' to make
-- them into 'Value'.
unwrapOne :: GValue -> Value
unwrapOne = unwrapBase toJSON

unwrapBase :: (GValue -> Value) -> GValue -> Value
unwrapBase mapChild (GValue gson_body) = unwrapBody $ gsonValue gson_body
  where
    unwrapBody GNull = Null
    unwrapBody (GBool b) = Bool b
    unwrapBody (GNumber n) = Number n
    unwrapBody (GString s) = String s
    unwrapBody (GArray a) = Array $ fmap mapChild a
    unwrapBody (GObject o) = Object $ fmap mapChild o

-- | Get the 'GValueBody' from 'GValue'.
gValueBody :: GValue -> GValueBody
gValueBody = gsonValue . unGValue

-- | Get the 'gsonType' field from 'GValue'.
gValueType :: GValue -> Maybe Text
gValueType = gsonType . unGValue

-- | Types that can be constructed from 'GValue'. This is analogous to
-- 'FromJSON' class.
--
-- Instances of basic types are implemented based on the following
-- rule.
--
-- - Simple scalar types (e.g. 'Int' and 'Text'): use 'parseUnwrapAll'.
-- - List-like types (e.g. '[]', 'Vector' and 'Set'): use
--   'parseUnwrapList'.
-- - Map-like types (e.g. 'L.HashMap' and 'L.Map'): parse into 'GMap'
--   first, then unwrap the 'GMap' wrapper. That way, all versions of
--   GraphSON formats are handled properly.
-- - Other types: see the individual instance documentation.
--
-- Note that 'Char' does not have 'FromGraphSON' instance. This is
-- intentional. As stated in the document of
-- 'Data.Greskell.AsIterator.AsIterator', using 'String' in greskell
-- is an error in most cases. To prevent you from using 'String',
-- 'Char' (and thus 'String') don't have 'FromGraphSON' instances.
class FromGraphSON a where
  parseGraphSON :: GValue -> Parser a

-- | Unwrap the given 'GValue' with 'unwrapAll', and just parse the
-- result with 'parseJSON'.
--
-- Useful to implement 'FromGraphSON' instances for scalar types.
parseUnwrapAll :: FromJSON a => GValue -> Parser a
parseUnwrapAll gv = parseJSON $ unwrapAll gv

---- Looks like we don't need this.

-- -- | Unwrap the given 'GValue' with 'unwrapOne', parse the result to
-- -- @(t GValue)@, and recursively parse the children with
-- -- 'parseGraphSON'.
-- --
-- -- Useful to implement 'FromGraphSON' instances for 'Traversable'
-- -- types.
-- parseUnwrapTraversable :: (Traversable t, FromJSON (t GValue), FromGraphSON a)
--                        => GValue -> Parser (t a)
-- parseUnwrapTraversable gv = traverse parseGraphSON =<< (parseJSON $ unwrapOne gv)

-- | Extract 'GArray' from the given 'GValue', parse the items in the
-- array, and gather them by 'List.fromList'.
--
-- Useful to implement 'FromGraphSON' instances for 'IsList' types.
parseUnwrapList :: (IsList a, i ~ Item a, FromGraphSON i) => GValue -> Parser a
parseUnwrapList (GValue (GraphSON _ (GArray v))) = fmap List.fromList $ traverse parseGraphSON $ List.toList v
parseUnwrapList (GValue (GraphSON _ body)) = fail ("Expects GArray, but got " ++ show body)

-- | Parse 'GValue' into 'FromGraphSON'.
parseEither :: FromGraphSON a => GValue -> Either String a
parseEither = Aeson.parseEither parseGraphSON

-- | Like Aeson's 'Aeson..:', but for 'FromGraphSON'.
(.:) :: FromGraphSON a => HashMap Text GValue -> Text -> Parser a
go .: label = maybe failure parseGraphSON $ HM.lookup label go
  where
    failure = fail ("Cannot find field " ++ unpack label)

---- Trivial instances

instance FromGraphSON GValue where
  parseGraphSON = return
instance FromGraphSON Int where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Text where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON TL.Text where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Bool where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Double where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Float where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Int8 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Int16 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Int32 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Int64 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Integer where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Natural where
  parseGraphSON = parseUnwrapAll
instance (FromJSON a, Integral a) => FromGraphSON (Ratio a) where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Word where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Word8 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Word16 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Word32 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Word64 where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON Scientific where
  parseGraphSON = parseUnwrapAll
instance FromGraphSON IntSet where
  parseGraphSON = parseUnwrapAll

---- List instances

instance FromGraphSON a => FromGraphSON [a] where
  parseGraphSON = parseUnwrapList
instance FromGraphSON a => FromGraphSON (Vector a) where
  parseGraphSON = parseUnwrapList
instance FromGraphSON a => FromGraphSON (Seq a) where
  parseGraphSON = parseUnwrapList

---- Set instances

instance (FromGraphSON a, Ord a) => FromGraphSON (Set a) where
  parseGraphSON = parseUnwrapList
instance (FromGraphSON a, Eq a, Hashable a) => FromGraphSON (HashSet a) where
  parseGraphSON = parseUnwrapList


---- GMap and others

-- | Use 'parseToFlattenedMap'.
instance (FromGraphSON k, FromGraphSON v, IsList (c k v), Item (c k v) ~ (k,v)) => FromGraphSON (FlattenedMap c k v) where
  parseGraphSON gv = case gValueBody gv of
    GArray a -> parseToFlattenedMap parseGraphSON parseGraphSON a
    b -> fail ("Expects GArray, but got " ++ show b)

parseGObjectToTraversal :: (Traversable t, FromJSON (t GValue), FromGraphSON v)
                        => HashMap Text GValue
                        -> Parser (t v)
parseGObjectToTraversal o = traverse parseGraphSON =<< (parseJSON $ Object $ fmap toJSON o)

-- | Use 'parseToGMap'.
instance (FromGraphSON k, FromGraphSON v, IsList (c k v), Item (c k v) ~ (k,v), Traversable (c k), FromJSON (c k GValue))
         => FromGraphSON (GMap c k v) where
  parseGraphSON gv = case gValueBody gv of
    GObject o -> parse $ Left o
    GArray a -> parse $ Right a
    other -> fail ("Expects GObject or GArray, but got " ++ show other)
    where
      parse = parseToGMap parseGraphSON parseGraphSON parseObject
      -- parseObject = parseUnwrapTraversable . GValue . nonTypedGraphSON . GObject  --- Too many wrapping and unwrappings!!!
      parseObject = parseGObjectToTraversal

-- | Use 'parseToGMapEntry'.
instance (FromGraphSON k, FromGraphSON v, FromJSONKey k) => FromGraphSON (GMapEntry k v) where
  parseGraphSON val = case gValueBody val of
    GObject o -> parse $ Left o
    GArray a -> parse $ Right a
    other -> fail ("Expects GObject or GArray, but got " ++ show other)
    where
      parse = parseToGMapEntry parseGraphSON parseGraphSON


---- Map instances

instance (FromGraphSON v, Eq k, Hashable k, FromJSONKey k, FromGraphSON k) => FromGraphSON (L.HashMap k v) where
  parseGraphSON = fmap unGMap . parseGraphSON
instance (FromGraphSON v, Ord k, FromJSONKey k, FromGraphSON k) => FromGraphSON (L.Map k v) where
  parseGraphSON = fmap unGMap . parseGraphSON
-- IntMap cannot be used with GMap directly..
instance FromGraphSON v => FromGraphSON (L.IntMap v) where
  parseGraphSON = fmap (mapToIntMap . unGMap) . parseGraphSON
    where
      mapToIntMap :: L.Map Int v -> L.IntMap v
      mapToIntMap = LMap.foldrWithKey LIntMap.insert mempty

---- Maybe and Either

-- | Parse 'GNull' into 'Nothing'.
instance FromGraphSON a => FromGraphSON (Maybe a) where
  parseGraphSON (GValue (GraphSON _ GNull)) = return Nothing
  parseGraphSON gv = fmap Just $ parseGraphSON gv

-- | Try 'Left', then 'Right'.
instance (FromGraphSON a, FromGraphSON b) => FromGraphSON (Either a b) where
  parseGraphSON gv = (fmap Left $ parseGraphSON gv) <|> (fmap Right $ parseGraphSON gv)


---- Others

-- | Call 'unwrapAll' to remove all GraphSON wrappers.
instance FromGraphSON Value where
  parseGraphSON = return . unwrapAll

instance FromGraphSON UUID where
  parseGraphSON gv = case gValueBody gv of
    GString t -> maybe failure return $ UUID.fromText t
      where
        failure = fail ("Failed to parse into UUID: " ++ unpack t)
    b -> fail ("Expected GString, but got " ++ show b)

-- | For any input 'GValue', 'parseGraphSON' returns @()@. For
-- example, you can use it to ignore data you get from the Gremlin
-- server.
instance FromGraphSON () where
  parseGraphSON _ = return ()
