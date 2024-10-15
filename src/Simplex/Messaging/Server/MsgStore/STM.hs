{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore (msgQueues),
    STMMsgQueue (msgQueue),
    STMStoreConfig (..),
    newMsgStore,
  )
where

import Control.Concurrent.STM
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

data STMMsgQueue = STMMsgQueue
  { msgQueue :: TQueue Message,
    quota :: Int,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

data STMMsgStore = STMMsgStore
  { config :: STMStoreConfig,
    msgQueues :: TMap RecipientId STMMsgQueue
  }

data STMStoreConfig = STMStoreConfig
  { quota :: Int
  }

instance MsgStoreClass STMMsgStore where
  type MsgQueue STMMsgStore = STMMsgQueue
  type MsgStoreConfig STMMsgStore = STMStoreConfig

  newMsgStore :: STMStoreConfig -> IO STMMsgStore
  newMsgStore config = do
    msgQueues <- TM.emptyIO
    pure STMMsgStore {config, msgQueues}

  getMsgQueueIds :: STMMsgStore -> IO (Set RecipientId)
  getMsgQueueIds = fmap M.keysSet . readTVarIO . msgQueues

  -- The reason for double lookup is that majority of messaging queues exist,
  -- because multiple messages are sent to the same queue,
  -- so the first lookup without STM transaction will return the queue faster.
  -- In case the queue does not exist, it needs to be looked-up again inside transaction.
  getMsgQueue :: STMMsgStore -> RecipientId -> IO STMMsgQueue
  getMsgQueue STMMsgStore {msgQueues = qs, config = STMStoreConfig {quota}} rId =
    TM.lookupIO rId qs >>= maybe (atomically maybeNewQ) pure
    where
      maybeNewQ = TM.lookup rId qs >>= maybe newQ pure
      newQ = do
        msgQueue <- newTQueue
        canWrite <- newTVar True
        size <- newTVar 0
        let q = STMMsgQueue {msgQueue, quota, canWrite, size}
        TM.insert rId q qs
        pure q

  delMsgQueue :: STMMsgStore -> RecipientId -> IO ()
  delMsgQueue st rId = atomically $ TM.delete rId $ msgQueues st

  delMsgQueueSize :: STMMsgStore -> RecipientId -> IO Int
  delMsgQueueSize st rId = atomically (TM.lookupDelete rId $ msgQueues st) >>= maybe (pure 0) (\STMMsgQueue {size} -> readTVarIO size)

  writeMsg :: STMMsgQueue -> Message -> IO (Maybe (Message, Bool))
  writeMsg STMMsgQueue {msgQueue = q, quota, canWrite, size} !msg = atomically $ do
    canWrt <- readTVar canWrite
    empty <- isEmptyTQueue q
    if canWrt || empty
      then do
        canWrt' <- (quota >) <$> readTVar size
        writeTVar canWrite $! canWrt'
        modifyTVar' size (+ 1)
        if canWrt'
          then writeTQueue q msg $> Just (msg, empty)
          else (writeTQueue q $! msgQuota) $> Nothing
      else pure Nothing
    where
      msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}

  tryPeekMsg :: STMMsgQueue -> IO (Maybe Message)
  tryPeekMsg = atomically . tryPeekTQueue . msgQueue
  {-# INLINE tryPeekMsg #-}

  tryDelMsg :: STMMsgQueue -> MsgId -> IO (Maybe Message)
  tryDelMsg mq msgId' = atomically $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg) | msgId msg == msgId' || B.null msgId' ->
        tryDeleteMsg_ mq >> pure msg_
      _ -> pure Nothing

  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: STMMsgQueue -> MsgId -> IO (Maybe Message, Maybe Message)
  tryDelPeekMsg mq msgId' = atomically $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' || B.null msgId' -> (msg_,) <$> (tryDeleteMsg_ mq >> tryPeekMsg_ mq)
        | otherwise -> pure (Nothing, msg_)
      _ -> pure (Nothing, Nothing)

  deleteExpiredMsgs :: STMMsgQueue -> Int64 -> IO Int
  deleteExpiredMsgs mq old = atomically $ loop 0
    where
      loop dc =
        tryPeekMsg_ mq >>= \case
          Just Message {msgTs}
            | systemSeconds msgTs < old ->
                tryDeleteMsg_ mq >> loop (dc + 1)
          _ -> pure dc

  getQueueSize :: STMMsgQueue -> IO Int
  getQueueSize STMMsgQueue {size} = readTVarIO size

tryPeekMsg_ :: STMMsgQueue -> STM (Maybe Message)
tryPeekMsg_ = tryPeekTQueue . msgQueue
{-# INLINE tryPeekMsg_ #-}

tryDeleteMsg_ :: STMMsgQueue -> STM ()
tryDeleteMsg_ STMMsgQueue {msgQueue = q, size} =
  tryReadTQueue q >>= \case
    Just _ -> modifyTVar' size (subtract 1)
    _ -> pure ()
