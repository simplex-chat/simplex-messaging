{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Types
  ( NtfServer,
    NtfTknAction (..),
    NtfToken (..),
    newNtfToken,
    NtfSubAction (..),
    NtfSubActionData (..),
    NtfSubNTFActionData (..),
    NtfSubNTFAction (..),
    NtfSubSMPActionData (..),
    NtfSubSMPAction (..),
    NtfAgentSubStatus (..),
    NtfSubscription (..),
    newNtfSubscription,
  )
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time (UTCTime)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Protocol (ConnId, NotificationsMode (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Parsers (blobFieldDecoder, fromTextField_)
import Simplex.Messaging.Protocol (NotifierId, ProtocolServer, SMPServer)

type NtfServer = ProtocolServer

data NtfTknAction
  = NTARegister
  | NTAVerify NtfRegCode -- code to verify token
  | NTACheck
  | NTADelete
  deriving (Show)

instance Encoding NtfTknAction where
  smpEncode = \case
    NTARegister -> "R"
    NTAVerify code -> smpEncode ('V', code)
    NTACheck -> "C"
    NTADelete -> "D"
  smpP =
    A.anyChar >>= \case
      'R' -> pure NTARegister
      'V' -> NTAVerify <$> smpP
      'C' -> pure NTACheck
      'D' -> pure NTADelete
      _ -> fail "bad NtfTknAction"

instance FromField NtfTknAction where fromField = blobFieldDecoder smpDecode

instance ToField NtfTknAction where toField = toField . smpEncode

data NtfToken = NtfToken
  { deviceToken :: DeviceToken,
    ntfServer :: NtfServer,
    ntfTokenId :: Maybe NtfTokenId,
    -- | key used by the ntf server to verify transmissions
    ntfPubKey :: C.APublicVerifyKey,
    -- | key used by the ntf client to sign transmissions
    ntfPrivKey :: C.APrivateSignKey,
    -- | client's DH keys (to repeat registration if necessary)
    ntfDhKeys :: C.KeyPair 'C.X25519,
    -- | shared DH secret used to encrypt/decrypt notifications e2e
    ntfDhSecret :: Maybe C.DhSecretX25519,
    -- | token status
    ntfTknStatus :: NtfTknStatus,
    -- | pending token action and the earliest time
    ntfTknAction :: Maybe NtfTknAction,
    ntfMode :: NotificationsMode
  }
  deriving (Show)

newNtfToken :: DeviceToken -> NtfServer -> C.ASignatureKeyPair -> C.KeyPair 'C.X25519 -> NotificationsMode -> NtfToken
newNtfToken deviceToken ntfServer (ntfPubKey, ntfPrivKey) ntfDhKeys ntfMode =
  NtfToken
    { deviceToken,
      ntfServer,
      ntfTokenId = Nothing,
      ntfPubKey,
      ntfPrivKey,
      ntfDhKeys,
      ntfDhSecret = Nothing,
      ntfTknStatus = NTNew,
      ntfTknAction = Just NTARegister,
      ntfMode
    }

data NtfSubAction = NtfSubNTFAction NtfSubNTFAction | NtfSubSMPAction NtfSubSMPAction

data NtfSubActionData = NtfSubActionData
  { action :: NtfSubAction,
    actionTs :: UTCTime,
    ntfSubscription :: NtfSubscription
  }

data NtfSubNTFActionData = NtfSubNTFActionData
  { ntfAction :: NtfSubNTFAction,
    actionTs :: UTCTime,
    ntfSubscription :: NtfSubscription
  }

data NtfSubNTFAction
  = NSACreate
  | NSACheck
  | NSADelete
  deriving (Show)

instance Encoding NtfSubNTFAction where
  smpEncode = \case
    NSACreate -> "N"
    NSACheck -> "C"
    NSADelete -> "D"
  smpP =
    A.anyChar >>= \case
      'N' -> pure NSACreate
      'C' -> pure NSACheck
      'D' -> pure NSADelete
      _ -> fail "bad NtfSubNTFAction"

instance FromField NtfSubNTFAction where fromField = blobFieldDecoder smpDecode

instance ToField NtfSubNTFAction where toField = toField . smpEncode

data NtfSubSMPActionData = NtfSubSMPActionData
  { smpAction :: NtfSubSMPAction,
    actionTs :: UTCTime,
    ntfSubscription :: NtfSubscription
  }

data NtfSubSMPAction
  = NSASmpKey
  | NSASmpDelete
  deriving (Show)

instance Encoding NtfSubSMPAction where
  smpEncode = \case
    NSASmpKey -> "K"
    NSASmpDelete -> "D"
  smpP =
    A.anyChar >>= \case
      'K' -> pure NSASmpKey
      'D' -> pure NSASmpDelete
      _ -> fail "bad NtfSubSMPAction"

instance FromField NtfSubSMPAction where fromField = blobFieldDecoder smpDecode

instance ToField NtfSubSMPAction where toField = toField . smpEncode

data NtfAgentSubStatus
  = -- | subscription started
    NASNew
  | -- | state after NKEY - notifier ID is assigned to queue on SMP server
    NASKey
  | -- | state after SNEW - subscription created on notification server
    NASCreated NtfSubStatus
  | -- | state after SDEL (subscription is deleted on notification server)
    NASOff
  | -- | state after NDEL (notifier credentials are deleted on SMP server)
    -- Can only exist transiently - if subscription record was updated by notification supervisor mid worker operation,
    -- and hence got updated instead of being fully deleted in the database post operation by worker
    NASDeleted
  deriving (Eq, Show)

instance Encoding NtfAgentSubStatus where
  smpEncode = \case
    NASNew -> "NEW"
    NASKey -> "KEY"
    NASCreated status -> "CREATED " <> smpEncode status
    NASOff -> "OFF"
    NASDeleted -> "DELETED"
  smpP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> pure NASNew
      "KEY" -> pure NASKey
      "CREATED" -> do
        _ <- A.space
        NASCreated <$> smpP
      "OFF" -> pure NASOff
      "DELETED" -> pure NASDeleted
      _ -> fail "bad NtfAgentSubStatus"

instance FromField NtfAgentSubStatus where fromField = fromTextField_ $ either (const Nothing) Just . smpDecode . encodeUtf8

instance ToField NtfAgentSubStatus where toField = toField . decodeLatin1 . smpEncode

data NtfSubscription = NtfSubscription
  { connId :: ConnId,
    smpServer :: SMPServer,
    ntfQueueId :: Maybe NotifierId,
    ntfServer :: NtfServer,
    ntfSubId :: Maybe NtfSubscriptionId,
    ntfSubStatus :: NtfAgentSubStatus
  }
  deriving (Show)

newNtfSubscription :: ConnId -> SMPServer -> Maybe NotifierId -> NtfServer -> NtfAgentSubStatus -> NtfSubscription
newNtfSubscription connId smpServer ntfQueueId ntfServer ntfSubStatus =
  NtfSubscription
    { connId,
      smpServer,
      ntfQueueId,
      ntfServer,
      ntfSubId = Nothing,
      ntfSubStatus
    }