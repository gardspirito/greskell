{-# LANGUAGE OverloadedStrings, DuplicateRecordFields, PartialTypeSignatures, FlexibleContexts, DeriveGeneric #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}
-- |
-- Module: Data.Greskell.WebSocket.Request
-- Description: Request to Gremlin Server
-- Maintainer: Toshio Ito <debug.ito@gmail.com>
--
-- 
module Data.Greskell.WebSocket.Request
       ( -- * RequestMessage
         RequestMessage(..),
         -- * Operations
         Operation(..),
         OpAuthentication(..),
         SASLMechanism(..),
         OpEval(..),
         OpSessionEval(..),
         SessionID,
         OpClose(..)
       ) where

import Data.Aeson (Object, ToJSON(..), (.=), Value(Object))
import qualified Data.Aeson as A
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as Base64
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Greskell.Greskell (ToGreskell, toGremlin)

-- | RequestMessage to a Gremlin Server.
data RequestMessage q =
  RequestMessage
  { requestId :: !UUID,
    -- ^ \"requestId\" field.
    requestOperation :: !q
    -- ^ 'Operation' object.
  }
  deriving (Show,Eq,Ord)

instance Operation q => ToJSON (RequestMessage q) where
  toJSON (RequestMessage { requestId = rid, requestOperation = rop }) =
    A.object [ "requestId" .= rid,
               "processor" .= opProcessor rop,
               "op" .= opName rop,
               "args" .= opArgs rop
             ]

-- | Class of operation objects.
class Operation o where
  opProcessor :: o -> Text
  -- ^ \"processor\" field.
  opName :: o -> Text
  -- ^ \"op\" field.
  opArgs :: o -> Object
  -- ^ \"args\" field.

instance (Operation a, Operation b) => Operation (Either a b) where
  opProcessor e = either opProcessor opProcessor e
  opName e = either opName opName e
  opArgs e = either opArgs opArgs e

-- | \"authentication\" operation.
data OpAuthentication =
  OpAuthentication
  { processor :: !Text,
    -- ^ \"processor\" field.
    batchSize :: !(Maybe Int),
    sasl :: !ByteString,
    -- ^ SASL response. It must be a raw 'ByteString' (NOT a
    -- base64-encoded one.)
    saslMechanism :: !SASLMechanism
  }
  deriving (Show,Eq,Ord)


-- Support encoders

type MPair = Maybe (Text, Value)

(.=?) :: (ToJSON a) => Text -> Maybe a -> MPair
label .=? mv = fmap (label .=) mv

(.=!) :: (ToJSON a) => Text -> a -> MPair
label .=! v = Just (label .= v)

mobject :: [MPair] -> Object
mobject = HM.fromList . catMaybes

toObject :: _ => a -> Object
toObject = expectObject . A.genericToJSON opt
  where
    opt = A.defaultOptions { A.omitNothingFields = True
                           }
    expectObject (Object o) = o
    expectObject _ = error "Expect Object, but got something else"


instance Operation OpAuthentication where
  opProcessor = processor
  opName _ = "authentication"
  opArgs o = mobject
             [ "batchSize" .=? batchSize (o :: OpAuthentication),
               "sasl" .=! (encodeBase64 $ sasl o),
               "saslMechanism" .=! (saslMechanismToText $ saslMechanism o)
             ]

encodeBase64 :: ByteString -> Text
encodeBase64 = decodeUtf8 . Base64.encode

-- | Possible SASL mechanisms.
data SASLMechanism = SASLPlain -- ^ \"PLAIN\" SASL
                   | SASLGSSAPI -- ^ \"GSSAPI\" SASL
                   deriving (Show,Eq,Ord,Enum,Bounded)

saslMechanismToText :: SASLMechanism -> Text
saslMechanismToText SASLPlain = "PLAIN"
saslMechanismToText SASLGSSAPI = "GSSAPI"

-- | Sessionless \"eval\" operation.
--
-- Type @g@ should be an instance of 'ToGreskell'.
data OpEval g =
  OpEval
  { batchSize :: !(Maybe Int),
    gremlin :: !g,
    bindings :: !(Maybe Object),
    language :: !(Maybe Text),
    aliases :: !(Maybe (HashMap Text Text)),
    scriptEvaluationTimeout :: !(Maybe Int)
  }
  deriving (Show,Eq,Generic)

instance (ToGreskell g) => Operation (OpEval g) where
  opProcessor _ = ""
  opName _ = "eval"
  opArgs orig = toObject $ orig { gremlin = toGremlin $ gremlin orig }

-- | Session ID.
type SessionID = UUID

-- | \"eval\" operation in session.
-- 
-- Type @g@ should be an instance of 'ToGreskell'.
data OpSessionEval g =
  OpSessionEval
  { eval :: !(OpEval g),
    session :: !SessionID,
    manageTransaction :: !(Maybe Bool)
  }
  deriving (Show,Eq)

instance (ToGreskell g) => Operation (OpSessionEval g) where
  opProcessor _ = "session"
  opName _ = "eval"
  opArgs op@(OpSessionEval { session = op_session }) = eval_args <> session_args
    where
      eval_args = opArgs $ eval $ op
      session_args = mobject
                     [ "session" .=! op_session,
                       "manageTransaction" .=? (manageTransaction $ op)
                     ]

-- | Session \"close\" operation.
data OpClose =
  OpClose
  { batchSize :: !(Maybe Int),
    session :: !SessionID,
    force :: !(Maybe Bool)
  }
  deriving (Show,Eq,Ord)
