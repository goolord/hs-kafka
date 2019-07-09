{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kafka where

import Data.ByteString (ByteString)
import Data.IORef
import Data.Primitive
import Data.Primitive.Unlifted.Array
import GHC.Conc
import Net.IPv4 (IPv4(..))
import Socket.Stream.IPv4

import Common
import ProduceRequest
import ProduceResponse

produce ::
     Kafka
  -> Topic
  -> Int -- number of microseconds to wait for response
  -> UnliftedArray ByteArray -- payloads
  -> IO (Either KafkaException (Either String ProduceResponse))
produce kafka topic waitTime payloads = do
  interrupt <- registerDelay waitTime
  let message = produceRequest (waitTime `div` 1000) topic payloads
  _ <- sendProduceRequest kafka interrupt message
  getProduceResponse kafka interrupt

produce' :: UnliftedArray ByteArray -> ByteString -> IO ()
produce' bytes topicName = do
  topic <- Topic (fromByteString topicName) 0 <$> newIORef 0
  Right k <- newKafka (Peer (IPv4 0) 9092)
  _ <- produce k topic 30000000 bytes
  pure ()

