{-# LANGUAGE OverloadedStrings, DuplicateRecordFields #-}
module Data.Greskell.WebSocket.Codec.JSONSpec (main,spec) where

import Control.Applicative ((<$>))
import Control.Monad (forM_)
import Data.Aeson (Value(Null, Number), (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BSL
import Data.Greskell.GraphSON (GraphSON, nonTypedGraphSON, typedGraphSON, typedGraphSON')
import qualified Data.HashMap.Strict as HM
import Data.Maybe (fromJust)
import Data.Monoid (mempty)
import qualified Data.UUID as UUID
import Test.Hspec

import Data.Greskell.WebSocket.Request
  (RequestMessage(..), OpEval(..), OpAuthentication(..), SASLMechanism(..))
import Data.Greskell.WebSocket.Response
  (ResponseMessage(..), ResponseStatus(..), ResponseResult(..), ResponseCode(..))
import Data.Greskell.WebSocket.Codec (Codec(..))
import Data.Greskell.WebSocket.Codec.JSON (jsonCodec)

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  decode_spec
  encode_spec

loadSample :: FilePath -> IO BSL.ByteString
loadSample filename = BSL.readFile ("test/samples/" ++ filename)

loadSampleValue :: FilePath -> IO Value
loadSampleValue filename = do
  json_text <- loadSample filename
  case A.eitherDecode' json_text of
   Left e -> error e
   Right v -> return v

decode_spec :: Spec
decode_spec = describe "decodeWith" $ do
  describe "authentication challenge" $ do
    let codec :: Codec OpEval Value
        codec = jsonCodec
        exp_msg = ResponseMessage { requestId = fromJust $ UUID.fromString "41d2e28a-20a4-4ab0-b379-d810dede3786",
                                    status = exp_status,
                                    result = exp_result
                                  }
        exp_status = ResponseStatus { code = Authenticate,
                                      message = "",
                                      attributes = mempty
                                    }
        exp_result = ResponseResult { resultData = Null,
                                      meta = mempty
                                    }
    forM_ ["v1", "v2", "v3"] $ \graphson_ver -> specify graphson_ver $ do
      got <- decodeWith codec <$> loadSample ("response_auth_" ++ graphson_ver ++ ".json")
      got `shouldBe` Right exp_msg

  describe "standard response" $ do
    let codec :: Codec OpEval (GraphSON [GraphSON Value])
        codec = jsonCodec
        expMsg d = ResponseMessage { requestId = fromJust $ UUID.fromString "41d2e28a-20a4-4ab0-b379-d810dede3786",
                                     status = exp_status,
                                     result = expResult d
                                   }
        exp_status = ResponseStatus { code = Success,
                                      message = "",
                                      attributes = mempty
                                    }
        expResult d = ResponseResult { resultData = d,
                                       meta = mempty
                                     }
        exp_v1 = A.object
                 [ "id" .= A.Number 1,
                   "label" .= A.String "person",
                   "type" .= A.String "vertex"
                 ]
        exp_v2 = A.object
                 [ "id" .= A.object ["@type" .= A.String "g:Int32", "@value" .= A.Number 1],
                   "label" .= A.String "person"
                 ]
        exp_v3 = exp_v2
        sampleFile v = "response_standard_" ++ v ++ ".json"
    specify "v1" $ do
      got <- decodeWith codec <$> loadSample (sampleFile "v1")
      got `shouldBe` Right (expMsg $ nonTypedGraphSON [nonTypedGraphSON exp_v1])
    specify "v2" $ do
      got <- decodeWith codec <$> loadSample (sampleFile "v2")
      got `shouldBe` Right (expMsg $ nonTypedGraphSON [typedGraphSON' "g:Vertex" exp_v2])
    specify "v3" $ do
      got <- decodeWith codec <$> loadSample (sampleFile "v3")
      got `shouldBe` Right (expMsg $ typedGraphSON [typedGraphSON' "g:Vertex" exp_v3])

encodedValue :: Codec q s -> RequestMessage q -> Value
encodedValue c req = case A.eitherDecode $ encodeWith c req of
  Left e -> error e
  Right v -> v

encode_spec :: Spec
encode_spec = describe "encodeWith" $ do
  let codec :: Codec q Value
      codec = jsonCodec
      encodedValue' = encodedValue codec
  specify "auth" $ do
    let input = RequestMessage
                { requestId = fromJust $ UUID.fromString "cb682578-9d92-4499-9ebc-5c6aa73c5397",
                  requestOperation = OpAuthentication
                                     { processor = "",
                                       batchSize = Nothing,
                                       sasl = "AHN0ZXBocGhlbgBwYXNzd29yZA==",
                                       saslMechanism = SASLPlain
                                     }
                }
    expected <- loadSampleValue "request_auth_v1.json"
    encodedValue' input `shouldBe` expected
  specify "sessionless eval" $ do
    let input = RequestMessage
                { requestId = fromJust $ UUID.fromString "cb682578-9d92-4499-9ebc-5c6aa73c5397",
                  requestOperation = OpEval
                                     { batchSize = Nothing,
                                       gremlin = "g.V(x)",
                                       binding = Just $ HM.fromList [("x", Number 1)],
                                       language = Just "gremlin-groovy",
                                       aliases = Nothing,
                                       scriptEvaluationTimeout = Nothing
                                     }
                }
    expected <- loadSampleValue "request_sessionless_eval_v1.json"
    encodedValue' input `shouldBe` expected

-- TODO: other cases.    
