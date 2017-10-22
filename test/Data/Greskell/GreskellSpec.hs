{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Data.Greskell.GreskellSpec (main,spec) where

import qualified Data.Aeson as Aeson
import Data.String (fromString)
import Data.Text (Text, pack)
import Test.Hspec
import Test.QuickCheck (property, Arbitrary(..))

import Data.Greskell.Greskell
  ( unsafeGreskell, toGremlin,
    unsafePlaceHolder, toPlaceHolderVariable,
    unsafeFunCall,
    string, list, true, false, value,
    Greskell
  )

-- TODO: move this into a single support module.
instance Arbitrary Text where
  arbitrary = fmap pack arbitrary

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  spec_literals
  spec_other

spec_other :: Spec
spec_other = do
  describe "unsafeGreskell" $ it "should be just a raw script text" $ property $ \t ->
    (toGremlin $ unsafeGreskell t) `shouldBe` t
  describe "Num" $ do
    specify "integer" $ do
      let x = 123 :: Greskell Int
      toGremlin x `shouldBe` "123"
    specify "negative integer" $ do
      let x = -56 :: Greskell Int
      toGremlin x `shouldBe` "-(56)"
    specify "operations" $ do
      let x = (30 + 15 * 20 - 10) :: Greskell Int
      toGremlin x `shouldBe` "((30)+((15)*(20)))-(10)"
    specify "abs, signum" $ do
      let x = (signum $ abs (-100)) :: Greskell Int
      toGremlin x  `shouldBe` "java.lang.Long.signum(java.lang.Math.abs(-(100)))"
  describe "Fractional" $ do
    specify "floating point literal" $ do
      let x = 92.12 :: Greskell Double
      (toGremlin x) `shouldBe` "(2303.0/25)"
    specify "operations" $ do
      let x = (100.5 * recip 30.0 / 20.2) :: Greskell Double
      toGremlin x `shouldBe` "(((201.0/2))*(1.0/((30.0/1))))/((101.0/5))"
  describe "Monoid" $ do
    specify "mempty" $ do
      let got = mempty :: Greskell Text
      toGremlin got `shouldBe` "\"\""
    specify "mappend" $ do
      let got = (mappend "foo" "bar") :: Greskell Text
      toGremlin got `shouldBe` "(\"foo\")+(\"bar\")"
  describe "placeHolder" $ it "should create a placeholder variable" $ property $ \i ->
    (toGremlin $ unsafePlaceHolder i) `shouldBe` toPlaceHolderVariable i
  describe "unsafeFunCall" $ do
    it "should make function call" $ do
      (toGremlin $ unsafeFunCall "fun" ["foo", "bar"]) `shouldBe` "fun(foo,bar)"

spec_literals :: Spec
spec_literals = do
  describe "string and fromString" $ do
    specify "empty" $ checkStringLiteral "" "\"\""
    specify "words" $ checkStringLiteral "hoge foo bar"  "\"hoge foo bar\""
    specify "escaped" $ checkStringLiteral "foo 'aaa \n \t \\ \"bar\"" "\"foo 'aaa \\n \\t \\\\ \\\"bar\\\"\""
  describe "list" $ do
    specify "empty" $ do
      toGremlin (list []) `shouldBe` "[]"
    specify "num" $ do
      toGremlin (list $ [(10 :: Greskell Int), 20, 30]) `shouldBe` "[10,20,30]"
    specify "list of lists" $ do
      toGremlin (list $ map list $ [[("" :: Greskell Text)], ["foo", "bar"], ["buzz"]])
        `shouldBe` "[[\"\"],[\"foo\",\"bar\"],[\"buzz\"]]"
  describe "boolean" $ do
    specify "true" $ do
      toGremlin true `shouldBe` "true"
    specify "false" $ do
      toGremlin false `shouldBe` "false"
  describe "value" $ do
    specify "null" $ do
      toGremlin (value Aeson.Null) `shouldBe` "null"
    specify "bool" $ do
      toGremlin (value $ Aeson.Bool False) `shouldBe` "false"
    specify "integer" $ do
      toGremlin (value $ Aeson.Number 100) `shouldBe` "100"
    specify "floating-point number" $ do
      toGremlin (value $ Aeson.Number 10.23) `shouldBe` "10.23"
    specify "String" $ do
      toGremlin (value $ Aeson.String "foobar") `shouldBe` "\"foobar\""
    specify "empty Array" $ do
      toGremlin (value $ Aeson.toJSON ([] :: [Int])) `shouldBe` "[]"
    specify "non-empty Array" $ do
      toGremlin (value $ Aeson.toJSON [(5 :: Int), 6, 7]) `shouldBe` "[5,6,7]"
    specify "empty Object" $ do
      toGremlin (value $ Aeson.object []) `shouldBe` "[:]"
    -- TODO: Do this test with the real Gremlin Server. String representation cannot preserve the order of pairs.
    -- specify "non-empty Object" $ do
    --   toGremlin (value $ Aeson.object [("foo", Aeson.String "hoge"), ("bar", Aeson.Number 20)])
    --     `shouldBe` "[\"foo\":\"hoge\",\"bar\":20]"
    -- specify "Object of Arrays" $ do
    --   toGremlin (value $ Aeson.object [("foo", Aeson.toJSON [(3 :: Int), 2, 1]), ("hoge", Aeson.toJSON [("a" :: Text), "b", "c"])])
    --     `shouldBe` "[\"foo\":[3,2,1],\"hoge\":[\"a\",\"b\",\"c\"]]"
  

checkStringLiteral :: String -> Text -> Expectation
checkStringLiteral input expected = do
  let input' = fromString input :: Greskell Text
  (toGremlin $ input') `shouldBe` expected
  (toGremlin $ string $ pack input) `shouldBe` expected
