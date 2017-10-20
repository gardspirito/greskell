{-# LANGUAGE OverloadedStrings, TypeFamilies #-}
-- |
-- Module: Data.Greskell.Gremlin
-- Description: Basic Gremlin (Groovy/Java) data types
-- Maintainer: Toshio Ito <debug.ito@gmail.com>
--
-- 
module Data.Greskell.Gremlin
       ( -- * Predicate
         Predicate(..),
         P,
         pEq,
         -- * Comparator
         Comparator(..),
         -- ** org.apache.tinkerpop.gremlin.process.traversal.Order
         Order,
         oDecr,
         oIncr,
         oShuffle,
       ) where

import Data.Aeson (Value)
import Data.Monoid ((<>))
import Data.Greskell.Greskell
  ( Greskell, unsafeGreskellLazy,
    toGremlin, toGremlinLazy, unsafeMethodCall, unsafeFunCall
  )

-- | @java.util.function.Predicate@ interface.
class Predicate p where
  type PredicateArg p
  pAnd :: Greskell p -> Greskell p -> Greskell p
  pAnd p1 p2 = unsafeMethodCall p1 "and" [toGremlin p2]
  pOr :: Greskell p -> Greskell p -> Greskell p
  pOr o1 o2 = unsafeMethodCall o1 "or" [toGremlin o2]
  pTest :: Greskell p -> Greskell (PredicateArg p) -> Greskell Bool
  pTest p arg = unsafeMethodCall p "test" [toGremlin arg]
  pNegate :: Greskell p -> Greskell p
  pNegate p = unsafeMethodCall p "negate" []

-- | @org.apache.tinkerpop.gremlin.process.traversal.P@ class.
--
-- @P a@ keeps data of type @a@ and compare it with data of type @a@
-- given as the Predicate argument.
data P a

instance Predicate (P a) where
  type PredicateArg (P a) = a

-- | @P.eq@ static method.
pEq :: Greskell a -> Greskell (P a)
pEq arg = unsafeFunCall "eq" [toGremlin arg]

-- TODO: other P methods.

-- | @java.util.Comparator@ interface.
class Comparator c where
  type CompareArg c
  cCompare :: Greskell c -> Greskell (CompareArg c) -> Greskell (CompareArg c) -> Greskell Int
  cCompare cmp a b = unsafeMethodCall cmp "compare" $ map toGremlin [a, b]
                     
-- | org.apache.tinkerpop.gremlin.process.traversal.Order enum.
data Order a

-- | @Order a@ compares the type @a@.
instance Comparator (Order a) where
  type CompareArg (Order a) = a

-- | @decr@ order.
oDecr :: Greskell (Order a)
oDecr = unsafeGreskellLazy "decr"

-- | @incr@ order.
oIncr :: Greskell (Order a)
oIncr = unsafeGreskellLazy "incr"

-- | @shuffle@ order.
oShuffle :: Greskell (Order a)
oShuffle = unsafeGreskellLazy "shuffle"
