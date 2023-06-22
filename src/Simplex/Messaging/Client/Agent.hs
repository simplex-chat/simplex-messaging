{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Client.Agent where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List (find, partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import Data.Text.Encoding
import Data.Tuple (swap)
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BrokerMsg, ProtocolServer (..), QueueId, SMPServer, NtfPrivateSignKey, NotifierId, RcvPrivateSignKey, RecipientId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (catchAll_, tryE, ($>>=))
import System.Timeout (timeout)
import UnliftIO (async)
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM
import Data.Either (isLeft)

type SMPClientVar = TMVar (Either SMPClientError SMPClient)

data SMPClientAgentEvent
  = CAConnected SMPServer
  | CADisconnected SMPServer (Set SMPSub)
  | CAReconnected SMPServer
  | CAResubscribed SMPServer SMPSub
  | CASubError SMPServer SMPSub SMPClientError

data SMPSubParty = SPRecipient | SPNotifier
  deriving (Eq, Ord, Show)

type SMPSub = (SMPSubParty, QueueId)

-- type SMPServerSub = (SMPServer, SMPSub)

data SMPClientAgentConfig = SMPClientAgentConfig
  { smpCfg :: ProtocolClientConfig,
    reconnectInterval :: RetryInterval,
    msgQSize :: Natural,
    agentQSize :: Natural
  }

defaultSMPClientAgentConfig :: SMPClientAgentConfig
defaultSMPClientAgentConfig =
  SMPClientAgentConfig
    { smpCfg = defaultClientConfig {defaultTransport = ("5223", transport @TLS)},
      reconnectInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * second
          },
      msgQSize = 64,
      agentQSize = 64
    }
  where
    second = 1000000

data SMPClientAgent = SMPClientAgent
  { agentCfg :: SMPClientAgentConfig,
    msgQ :: TBQueue (ServerTransmission BrokerMsg),
    agentQ :: TBQueue SMPClientAgentEvent,
    smpClients :: TMap SMPServer SMPClientVar,
    srvSubs :: TMap SMPServer (TMap SMPSub C.APrivateSignKey),
    pendingSrvSubs :: TMap SMPServer (TMap SMPSub C.APrivateSignKey),
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()]
  }

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO :: ((forall a. ExceptT e m a -> IO a) -> IO b) -> ExceptT e m b
  withRunInIO exceptToIO =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        exceptToIO $ run . (either (E.throwIO . InternalException) return <=< runExceptT)

newSMPClientAgent :: SMPClientAgentConfig -> STM SMPClientAgent
newSMPClientAgent agentCfg@SMPClientAgentConfig {msgQSize, agentQSize} = do
  msgQ <- newTBQueue msgQSize
  agentQ <- newTBQueue agentQSize
  smpClients <- TM.empty
  srvSubs <- TM.empty
  pendingSrvSubs <- TM.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  pure SMPClientAgent {agentCfg, msgQ, agentQ, smpClients, srvSubs, pendingSrvSubs, reconnections, asyncClients}

getSMPServerClient' :: SMPClientAgent -> SMPServer -> ExceptT SMPClientError IO SMPClient
getSMPServerClient' ca@SMPClientAgent {agentCfg, smpClients, msgQ} srv =
  atomically getClientVar >>= either newSMPClient waitForSMPClient
  where
    getClientVar :: STM (Either SMPClientVar SMPClientVar)
    getClientVar = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup srv smpClients

    newClientVar :: STM SMPClientVar
    newClientVar = do
      smpVar <- newEmptyTMVar
      TM.insert srv smpVar smpClients
      pure smpVar

    waitForSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    waitForSMPClient smpVar = do
      let ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
      smpClient_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar smpVar)
      liftEither $ case smpClient_ of
        Just (Right smpClient) -> Right smpClient
        Just (Left e) -> Left e
        Nothing -> Left PCEResponseTimeout

    newSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    newSMPClient smpVar = tryConnectClient pure tryConnectAsync
      where
        tryConnectClient :: (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO () -> ExceptT SMPClientError IO a
        tryConnectClient successAction retryAction =
          tryE connectClient >>= \r -> case r of
            Right smp -> do
              logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
              atomically $ putTMVar smpVar r
              successAction smp
            Left e -> do
              if e == PCENetworkError || e == PCEResponseTimeout
                then retryAction
                else atomically $ do
                  putTMVar smpVar (Left e)
                  TM.delete srv smpClients
              throwE e
        tryConnectAsync :: ExceptT SMPClientError IO ()
        tryConnectAsync = do
          a <- async connectAsync
          atomically $ modifyTVar' (asyncClients ca) (a :)
        connectAsync :: ExceptT SMPClientError IO ()
        connectAsync =
          withRetryInterval (reconnectInterval agentCfg) $ \_ loop ->
            void $ tryConnectClient (const reconnectClient) loop

    connectClient :: ExceptT SMPClientError IO SMPClient
    connectClient = ExceptT $ getProtocolClient (1, srv, Nothing) (smpCfg agentCfg) (Just msgQ) clientDisconnected

    clientDisconnected :: SMPClient -> IO ()
    clientDisconnected _ = do
      removeClientAndSubs >>= (`forM_` serverDown)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: IO (Maybe (Map SMPSub C.APrivateSignKey))
    removeClientAndSubs = atomically $ do
      TM.delete srv smpClients
      TM.lookupDelete srv (srvSubs ca) >>= mapM updateSubs
      where
        updateSubs sVar = do
          ss <- readTVar sVar
          addPendingSubs sVar ss
          pure ss

        addPendingSubs sVar ss = do
          let ps = pendingSrvSubs ca
          TM.lookup srv ps >>= \case
            Just v -> TM.union ss v
            _ -> TM.insert srv sVar ps

    serverDown :: Map SMPSub C.APrivateSignKey -> IO ()
    serverDown ss = unless (M.null ss) $ do
      notify . CADisconnected srv $ M.keysSet ss
      void $ runExceptT reconnectServer

    reconnectServer :: ExceptT SMPClientError IO ()
    reconnectServer = do
      a <- async tryReconnectClient
      atomically $ modifyTVar' (reconnections ca) (a :)

    tryReconnectClient :: ExceptT SMPClientError IO ()
    tryReconnectClient = do
      withRetryInterval (reconnectInterval agentCfg) $ \_ loop ->
        reconnectClient `catchE` const loop

    reconnectClient :: ExceptT SMPClientError IO ()
    reconnectClient = do
      withSMP ca srv $ \smp -> do
        liftIO . notify $ CAReconnected srv
        cs_ <- atomically $ mapM readTVar =<< TM.lookup srv (pendingSrvSubs ca)
        forM_ cs_ $ \cs -> do
          let (nSubs, rSubs) = partition (isNotifier . fst . fst) $ M.assocs cs
          nRs <- liftIO $ subscribe_ smp SPNotifier nSubs
          rRs <- liftIO $ subscribe_ smp SPRecipient rSubs
          case find isLeft $ nRs <> rRs of
            Just (Left e) -> throwE e
            _ -> pure ()
      where
        isNotifier = \case
          SPNotifier -> True
          SPRecipient -> False

        subscribe_ :: SMPClient -> SMPSubParty -> [(SMPSub, C.APrivateSignKey)] -> IO [Either SMPClientError ()]
        subscribe_ smp party subs = do
          subs' <- filterM (atomically . hasSub (srvSubs ca) srv . fst) subs
          case L.nonEmpty subs' of
            Just subs'' -> do
              let subs3 = L.map (first snd) subs''
              rs <- L.zip subs3 <$> smpSubscribeQueues party ca smp srv subs3
              rs' <- forM rs $ \(sub, r) -> do
                let sub' = first (party,) sub
                    s = fst sub'
                case snd r of
                  Right () -> do
                    atomically $ addSubscription ca srv sub'
                    notify $ CAResubscribed srv s
                    pure $ Right ()
                  Left e -> do
                    case e of
                      PCEResponseTimeout -> pure $ Left e
                      PCENetworkError -> pure $ Left e
                      _ -> do
                        notify $ CASubError srv s e
                        atomically $ removePendingSubscription ca srv s
                        pure $ Right ()
              pure $ L.toList rs'
            _ -> pure []

    notify :: SMPClientAgentEvent -> IO ()
    notify evt = atomically $ writeTBQueue (agentQ ca) evt

closeSMPClientAgent :: MonadUnliftIO m => SMPClientAgent -> m ()
closeSMPClientAgent c = liftIO $ do
  closeSMPServerClients c
  cancelActions $ reconnections c
  cancelActions $ asyncClients c

closeSMPServerClients :: SMPClientAgent -> IO ()
closeSMPServerClients c = readTVarIO (smpClients c) >>= mapM_ (forkIO . closeClient)
  where
    closeClient smpVar =
      atomically (readTMVar smpVar) >>= \case
        Right smp -> closeProtocolClient smp `catchAll_` pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withSMP :: SMPClientAgent -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO a
withSMP ca srv action = (getSMPServerClient' ca srv >>= action) `catchE` logSMPError
  where
    logSMPError :: SMPClientError -> ExceptT SMPClientError IO a
    logSMPError e = do
      liftIO $ putStrLn $ "SMP error (" <> show srv <> "): " <> show e
      throwE e

subscribeQueue :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateSignKey) -> ExceptT SMPClientError IO ()
subscribeQueue ca srv sub = do
  atomically $ addPendingSubscription ca srv sub
  withSMP ca srv $ \smp -> subscribe_ smp `catchE` handleError
  where
    subscribe_ smp = do
      smpSubscribe smp sub
      atomically $ addSubscription ca srv sub

    handleError e = do
      atomically . when (e /= PCENetworkError && e /= PCEResponseTimeout) $
        removePendingSubscription ca srv $ fst sub
      throwE e

subscribeQueuesSMP :: SMPClientAgent -> SMPServer -> NonEmpty (RecipientId, RcvPrivateSignKey) -> IO (NonEmpty (RecipientId, Either SMPClientError ()))
subscribeQueuesSMP = subscribeQueues_ SPRecipient

subscribeQueuesNtfs :: SMPClientAgent -> SMPServer -> NonEmpty (NotifierId, NtfPrivateSignKey) -> IO (NonEmpty (NotifierId, Either SMPClientError ()))
subscribeQueuesNtfs = subscribeQueues_ SPNotifier

subscribeQueues_ :: SMPSubParty -> SMPClientAgent -> SMPServer -> NonEmpty (QueueId, C.APrivateSignKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
subscribeQueues_ party ca srv subs = do
  atomically $ forM_ subs $ addPendingSubscription ca srv . first (party,)
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Left e -> pure $ L.map ((,Left e) . fst) subs
    Right smp -> smpSubscribeQueues party ca smp srv subs

smpSubscribeQueues :: SMPSubParty -> SMPClientAgent -> SMPClient -> SMPServer -> NonEmpty (QueueId, C.APrivateSignKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
smpSubscribeQueues party ca smp srv subs = do
  rs <- L.zip subs <$> subscribe smp (L.map swap subs)
  atomically $ forM rs $ \(sub, r) -> (fst sub,) <$> case r of
    Right () -> do
      addSubscription ca srv $ first (party,) sub
      pure $ Right ()
    Left e -> do
      when (e /= PCENetworkError && e /= PCEResponseTimeout) $
        removePendingSubscription ca srv $ (party,) $ fst sub
      pure $ Left e
  where
    subscribe = case party of
      SPRecipient -> subscribeSMPQueues
      SPNotifier -> subscribeSMPQueuesNtfs

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

smpSubscribe :: SMPClient -> (SMPSub, C.APrivateSignKey) -> ExceptT SMPClientError IO ()
smpSubscribe smp ((party, queueId), privKey) = subscribe_ smp privKey queueId
  where
    subscribe_ = case party of
      SPRecipient -> subscribeSMPQueue
      SPNotifier -> subscribeSMPQueueNotifications

addSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateSignKey) -> STM ()
addSubscription ca srv sub = do
  addSub_ (srvSubs ca) srv sub
  removePendingSubscription ca srv $ fst sub

addPendingSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateSignKey) -> STM ()
addPendingSubscription = addSub_ . pendingSrvSubs

addSub_ :: TMap SMPServer (TMap SMPSub C.APrivateSignKey) -> SMPServer -> (SMPSub, C.APrivateSignKey) -> STM ()
addSub_ subs srv (s, key) =
  TM.lookup srv subs >>= \case
    Just m -> TM.insert s key m
    _ -> TM.singleton s key >>= \v -> TM.insert srv v subs

removeSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removeSubscription = removeSub_ . srvSubs

removePendingSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removePendingSubscription = removeSub_ . pendingSrvSubs

removeSub_ :: TMap SMPServer (TMap SMPSub C.APrivateSignKey) -> SMPServer -> SMPSub -> STM ()
removeSub_ subs srv s = TM.lookup srv subs >>= mapM_ (TM.delete s)

getSubKey :: TMap SMPServer (TMap SMPSub C.APrivateSignKey) -> SMPServer -> SMPSub -> STM (Maybe C.APrivateSignKey)
getSubKey subs srv s = TM.lookup srv subs $>>= TM.lookup s

hasSub :: TMap SMPServer (TMap SMPSub C.APrivateSignKey) -> SMPServer -> SMPSub -> STM Bool
hasSub subs srv s = maybe (pure False) (TM.member s) =<< TM.lookup srv subs
