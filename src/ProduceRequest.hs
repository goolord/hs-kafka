{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UnboxedTuples #-}

module ProduceRequest
  ( produceRequest
  , sendProduceRequest
  ) where

import Control.Monad.ST
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Monad.Primitive
import Control.Monad.Primitive.Convenience
import Data.ByteString (ByteString)
import Data.Bytes.Types
import Data.Foldable
import Data.Int
import Data.Primitive (Prim(..), alignment)
import Data.Primitive.Unlifted.Array
import Data.Primitive.ByteArray
import Data.Primitive.ByteArray.Unaligned
import Data.Primitive.Slice (UnliftedVector(UnliftedVector))
import Data.Word
import GHC.Conc
import Socket.Stream.Uninterruptible.Bytes
import Socket.Stream.IPv4

import qualified Crc32c as CRC
import qualified Data.ByteString as BS

import Common
import Varint

produceApiVersion :: Int16
produceApiVersion = 7

produceApiKey :: Int16
produceApiKey = 0

clientId :: ByteString
clientId = "ruko"

clientIdLength :: Int
clientIdLength = BS.length clientId

correlationId :: Int32
correlationId = 0xbeef

magic :: Int8
magic = 2

newtype KafkaWriter s m a = KafkaWriter
  { runKafkaWriter :: ReaderT (MutableByteArray s) (StateT Int m) a }
  deriving
    ( Functor, Applicative, Monad
    , MonadReader (MutableByteArray s)
    , MonadState Int
    , PrimMonad
    )

withCtx :: Monad m => (Int -> MutableByteArray s -> KafkaWriter s m a) -> KafkaWriter s m a
withCtx f = do
  index <- get
  arr <- ask
  f index arr

writeNum :: (MonadPrim s m, Prim a, PrimUnaligned a)
  => a -> KafkaWriter s m ()
writeNum n = withCtx $ \index arr -> do
  writeUnalignedByteArray arr index n
  modify' (+ (alignment n))
{-# inlineable writeNum #-}

write8 :: (MonadPrim s m) => Int8 -> KafkaWriter s m ()
write8 = writeNum

writeBE16 :: (MonadPrim s m) => Int16 -> KafkaWriter s m ()
writeBE16 = writeNum . toBE16

writeBE32 :: (MonadPrim s m) => Int32 -> KafkaWriter s m ()
writeBE32 = writeNum . toBE32

writeBE64 :: (MonadPrim s m) => Int64 -> KafkaWriter s m ()
writeBE64 = writeNum . toBE64

writeArray ::
     (MonadPrim s m)
  => ByteArray
  -> Int
  -> KafkaWriter s m ()
writeArray src len = withCtx $ \index arr -> do
  copyByteArray arr index src 0 len
  modify' (+len)

makeRecordMetadata :: Int -> ByteArray -> ByteArray
makeRecordMetadata index content =
  let
    -- plus one is for the trailing null byte
    recordLength = zigzag (sizeofByteArray metadataContent + sizeofByteArray content + 1)
    metadataContent = fold
      [ byteArrayFromList [0 :: Word8]
      , zigzag 0 -- timestampDelta
      , zigzag index -- offsetDelta
      , zigzag (-1) -- keyLength
      , zigzag (sizeofByteArray content) -- valueLen
      ]
  in
    recordLength <> metadataContent

sumSizes :: UnliftedArray ByteArray -> Int
sumSizes = foldrUnliftedArray (\e acc -> acc + sizeofByteArray e) 0

evaluateWriter :: Int -> (forall s. KafkaWriter s (ST s) a) -> ByteArray
evaluateWriter n kw = runST $ do
  arr <- newByteArray n
  _ <- runStateT (runReaderT (runKafkaWriter kw) arr) 0
  unsafeFreezeByteArray arr

produceRequestRecordBatchMetadata ::
     UnliftedArray ByteArray
  -> Int
  -> Int
  -> ByteArray
produceRequestRecordBatchMetadata payloadsSectionChunks payloadCount payloadsSectionSize =
  let
    crc =
      CRC.chunks
        (CRC.bytes 0 (Bytes postCrc 0 40))
        (UnliftedVector payloadsSectionChunks 0 (3*payloadCount))
    batchLength = 9 + 40 + fromIntegral payloadsSectionSize
    preCrc = evaluateWriter 21 $ do
      writeBE64 0
      writeBE32 batchLength
      writeBE32 0
      write8 magic
      writeBE32 (fromIntegral crc)
    postCrc = evaluateWriter 40 $ do
      writeBE16 0
      writeBE32 (fromIntegral (payloadCount - 1))
      writeBE64 0
      writeBE64 0
      writeBE64 (-1)
      writeBE16 (-1)
      writeBE32 (-1)
      writeBE32 $ fromIntegral payloadCount
  in
    preCrc <> postCrc

makeRequestMetadata ::
     Int
  -> Int
  -> Topic
  -> ByteArray
makeRequestMetadata recordBatchSectionSize timeout topic =
  evaluateWriter (40 + clientIdLength + topicNameSize) $ do
    writeBE32 (fromIntegral $ 36 + clientIdLength + topicNameSize + recordBatchSectionSize)
    writeBE16 produceApiKey
    writeBE16 produceApiVersion
    writeBE32 correlationId
    writeBE16 (fromIntegral clientIdLength)
    writeArray (fromByteString clientId) clientIdLength
    writeBE16 (-1) -- transactional_id length
    writeBE16 1 -- acks
    writeBE32 (fromIntegral timeout) -- timeout in ms
    writeBE32 1 -- following array length
    writeBE16 (size16 topicName) -- following string length
    writeArray topicName topicNameSize -- topic_data topic
    writeBE32 1 -- following array [data] length
    writeBE32 0 -- partition
    writeBE32 (fromIntegral recordBatchSectionSize) -- record_set length
  where
    Topic topicName _ _ = topic
    topicNameSize = sizeofByteArray topicName

produceRequest ::
     Int
  -> Topic
  -> UnliftedArray ByteArray
  -> UnliftedArray ByteArray
produceRequest timeout topic payloads =
  let
    payloadCount = sizeofUnliftedArray payloads
    zero = runST $ do
      ba <- newByteArray 1
      writeByteArray ba 0 (0 :: Word8)
      unsafeFreezeByteArray ba
    recordBatchSectionSize =
        sumSizes payloadsSectionChunks
      + sizeofByteArray recordBatchMetadata
    requestMetadata = makeRequestMetadata
      recordBatchSectionSize
      timeout
      topic
    recordBatchMetadata =
      produceRequestRecordBatchMetadata
        payloadsSectionChunks
        payloadCount
        (sumSizes payloadsSectionChunks)
    payloadsSectionChunks = runUnliftedArray $ do
      arr <- newUnliftedArray (3 * payloadCount) zero
      itraverseUnliftedArray_
        (\i payload -> do
          writeUnliftedArray arr (i * 3)     (makeRecordMetadata i payload)
          writeUnliftedArray arr (i * 3 + 1) payload
          writeUnliftedArray arr (i * 3 + 2) zero)
        payloads
      pure arr
  in
    runUnliftedArray $ do
      arr <- newUnliftedArray (3 * payloadCount + 2) zero
      writeUnliftedArray arr 0 requestMetadata
      writeUnliftedArray arr 1 recordBatchMetadata
      copyUnliftedArray arr 2 payloadsSectionChunks 0 (3 * payloadCount)
      pure arr

sendProduceRequest ::
     Kafka
  -> TVar Bool
  -> UnliftedArray ByteArray
  -> IO (Either (SendException 'Uninterruptible) ())
sendProduceRequest kafka _ message = do
  sendMany
    (getKafka kafka)
    message
