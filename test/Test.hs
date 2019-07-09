{-# LANGUAGE OverloadedStrings #-}

import Data.Foldable
import Data.IORef
import Data.Primitive.ByteArray
import Data.Primitive.Unlifted.Array
import Data.Word
import Test.Tasty
import Test.Tasty.Ingredients.ConsoleReporter
import Test.Tasty.Golden
import Test.Tasty.HUnit

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Kafka
import Varint

main :: IO ()
main = defaultMain (testGroup "Tests" [unitTests, goldenTests])

unitTests :: TestTree
unitTests = testGroup "unit tests"
  [ testCase
      "zigzag 0 is 0"
      (zigzag 0 @=? byteArrayFromList [0 :: Word8])
  , testCase
      "zigzag -1 is 1"
      (zigzag (-1) @=? byteArrayFromList [1 :: Word8])
  , testCase
      "zigzag 1 is 2"
      (zigzag 1 @=? byteArrayFromList [2 :: Word8])
  , testCase
      "zigzag -2 is 3"
      (zigzag (-2) @=? byteArrayFromList [3 :: Word8])
  , testCase
      "zigzag 100 is [200, 1]"
      (zigzag 100 @?= byteArrayFromList [200, 1 :: Word8])
  ]

goldenTests :: TestTree
goldenTests = testGroup "golden tests"
  [ goldenVsString
      "generate well-formed requests"
      "test/kafka-request-bytes"
      (BL.fromStrict <$> requestTest)
  , goldenVsString
      "handle multiple payloads in one request"
      "test/kafka-multiple-payload"
      (BL.fromStrict <$> multiplePayloadTest)
  ]

requestTest = do
  ref <- newIORef 0
  let payload = fromByteString $
        "\"im not owned! im not owned!!\", i continue to insist as i slowly" <>
        "shrink and transform into a corn cob"
  payloads <- newUnliftedArray 1 payload
  payloadsf <- freezeUnliftedArray payloads 0 1
  let topicName = fromByteString "test"
      topic = Topic topicName 1 ref
      req = toByteString $ produceRequest 30000 topic payloadsf
  pure req

multiplePayloadTest = do
  ref <- newIORef 0
  let payloads = unliftedArrayFromList
        [ fromByteString "i'm dying"
        , fromByteString "is it blissful?"
        , fromByteString "it's like a dream"
        , fromByteString "i want to dream"
        ]
  let topicName = fromByteString "test"
      topic = Topic topicName 1 ref
      req = toByteString $ produceRequest 30000 topic payloads
  pure req