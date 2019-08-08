{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Concurrent
import Control.Monad
import Data.ByteString (ByteString)
import Data.IORef
import Data.Maybe
import Data.Primitive.ByteArray (ByteArray)
import Data.Foldable
import GHC.Conc
import System.IO.Unsafe (unsafePerformIO)

import Kafka.Common
import Kafka.Consumer
import Kafka.Fetch.Response (FetchResponse)

import qualified Kafka.Fetch.Response as F

groupName :: ByteArray
groupName = fromByteString "example-consumer-group"

children :: MVar [MVar ()]
children = unsafePerformIO (newMVar [])

waitForChildren :: IO ()
waitForChildren = do
  cs <- takeMVar children
  case cs of
    [] -> pure ()
    m:ms -> do
      putMVar children ms
      takeMVar m
      waitForChildren

main :: IO ()
main = do
  fork consumer "C1"
  fork consumer "C2"
  fork consumer "C3"
  threadDelay 5000000
  fork consumer "C4"
  waitForChildren

fork :: (String -> IO ()) -> String -> IO ()
fork f name = do
  mvar <- newEmptyMVar
  childs <- takeMVar children
  putMVar children (mvar:childs)
  void $ forkFinally (f name) (\_ -> putMVar mvar ())

consumer :: String -> IO ()
consumer name = do
  (t, kafka) <- setup groupName 8
  case kafka of
    Nothing -> putStrLn "Failed to connect to kafka"
    Just k -> do
      let member = GroupMember groupName Nothing
      interrupt <- registerDelay 10000000
      consumerSession k t member (callback name) interrupt >>= \case
        Left err -> print err
        Right () -> pure ()

callback :: String -> FetchResponse -> IO ()
callback name response = 
  putStrLn (name <> ": got " <> show (length (fetchResponseContents response)) <> " messages")
--  traverse_
--    (\message -> putStrLn (name <> ": " <> show message))
--    (fetchResponseContents response)

fetchResponseContents :: FetchResponse -> [ByteString]
fetchResponseContents fetchResponse =
    mapMaybe F.recordValue
  . concatMap F.records
  . concat
  . mapMaybe F.recordSet
  . concatMap F.partitionResponses
  . F.responses
  $ fetchResponse

setup :: ByteArray -> Int -> IO (Topic, Maybe Kafka)
setup topicName partitionCount = do
  currentPartition <- newIORef 0
  let t = Topic topicName partitionCount currentPartition
  k <- newKafka defaultKafka
  pure (t, either (const Nothing) Just k)

thirtySeconds :: Int
thirtySeconds = 30000000
