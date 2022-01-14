{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.MsgStore where

import Data.Time.Clock.System (SystemTime)
import Numeric.Natural
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (MsgBody, MsgId, RecipientId)

data Message = Message
  { msgId :: MsgId,
    ts :: SystemTime,
    msgBody :: MsgBody
  }

instance StrEncoding Message where
  strEncode Message {msgId, ts, msgBody} = strEncode (msgId, ts, msgBody)
  strP = do
    (msgId, ts, msgBody) <- strP
    pure Message {msgId, ts, msgBody}

class MonadMsgStore s q m | s -> q where
  getMsgQueue :: s -> RecipientId -> Natural -> m q
  delMsgQueue :: s -> RecipientId -> m ()

class MonadMsgQueue q m where
  isFull :: q -> m Bool
  writeMsg :: q -> Message -> m () -- non blocking
  tryPeekMsg :: q -> m (Maybe Message) -- non blocking
  peekMsg :: q -> m Message -- blocking
  tryDelPeekMsg :: q -> m (Maybe Message) -- atomic delete (== read) last and peek next message, if available
