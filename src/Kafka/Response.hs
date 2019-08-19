{-# LANGUAGE LambdaCase #-}

module Kafka.Response
  ( ErrorCode(..)
  , fromKafkaResponse
  , getKafkaResponse
  , getResponseSizeHeader
  ) where

import Data.Attoparsec.ByteString (Parser, parseOnly)
import Data.Bifunctor
import Data.ByteString
import Data.Bytes.Types
import Data.Int
import Data.Primitive.ByteArray
import Data.Word
import GHC.Conc
import Socket.Stream.Interruptible.MutableBytes

import Kafka.Common

getKafkaResponse ::
     Kafka
  -> TVar Bool
  -> IO (Either KafkaException ByteString)
getKafkaResponse kafka interrupt = do
  getResponseSizeHeader kafka interrupt >>= \case
    Right responseByteCount -> do
      responseBuffer <- newByteArray responseByteCount
      let responseBufferSlice = MutableBytes responseBuffer 0 responseByteCount
      responseStatus <- first KafkaReceiveException <$>
        receiveExactly
          interrupt
          (getKafka kafka)
          responseBufferSlice
      responseBytes <- toByteString <$> unsafeFreezeByteArray responseBuffer
      pure $ responseBytes <$ responseStatus
    Left e -> pure $ Left e

getResponseSizeHeader ::
     Kafka
  -> TVar Bool
  -> IO (Either KafkaException Int)
getResponseSizeHeader kafka interrupt = do
  responseSizeBuf <- newByteArray 4
  responseStatus <- first KafkaReceiveException <$>
    receiveExactly
      interrupt
      (getKafka kafka)
      (MutableBytes responseSizeBuf 0 4)
  byteCount <- fromIntegral . byteSwap32 <$> readByteArray responseSizeBuf 0
  pure $ byteCount <$ responseStatus

fromKafkaResponse ::
     Parser a
  -> Kafka
  -> TVar Bool
  -> IO (Either KafkaException (Either String a))
fromKafkaResponse parser kafka interrupt =
  (fmap . fmap)
    (parseOnly parser)
    (getKafkaResponse kafka interrupt)

class ErrorCode a where
  errorCode :: a -> Int16
