{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPProxyTests where

import AgentTests.EqInstances ()
import AgentTests.FunctionalAPITests
import Control.Logger.Simple
import Control.Monad (forM, forM_, forever)
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import SMPAgentClient
import SMPClient
import ServerTests (decryptMsgV3, sendRecv)
import Simplex.Messaging.Agent hiding (createConnection, joinConnection, sendMessage)
import qualified Simplex.Messaging.Agent as A
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers (..))
import Simplex.Messaging.Agent.Protocol hiding (CON, CONF, INFO, REQ)
import qualified Simplex.Messaging.Agent.Protocol as A
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (pattern PQSupportOn)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (bshow, tshow)
import Simplex.Messaging.Version (mkVersionRange)
import System.FilePath (splitExtensions)
import Test.Hspec
import UnliftIO
import Util

smpProxyTests :: Spec
smpProxyTests = do
  describe "server configuration" $ do
    it "refuses proxy handshake unless enabled" testNoProxy
    it "checks basic auth in proxy requests" testProxyAuth
  describe "proxy requests" $ do
    describe "bad relay URIs" $ do
      xit "host not resolved" todo
      xit "when SMP port blackholed" todo
      xit "no SMP service at host/port" todo
      xit "bad SMP fingerprint" todo
    xit "batching proxy requests" todo
  describe "deliver message via SMP proxy" $ do
    let srv1 = SMPServer testHost testPort testKeyHash
        srv2 = SMPServer testHost testPort2 testKeyHash
    describe "client API" $ do
      let maxLen = maxMessageLength sendingProxySMPVersion
      describe "one server" $ do
        it "deliver via proxy" . oneServer $ do
          deliverMessageViaProxy srv1 srv1 C.SEd448 "hello 1" "hello 2"
      describe "two servers" $ do
        let proxyServ = srv1
            relayServ = srv2
        (msg1, msg2) <- runIO $ do
          g <- C.newRandom
          atomically $ (,) <$> C.randomBytes maxLen g <*> C.randomBytes maxLen g
        it "deliver via proxy" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd448 "hello 1" "hello 2"
        it "max message size, Ed448 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd448 msg1 msg2
        it "max message size, Ed25519 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd25519 msg1 msg2
        it "max message size, X25519 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SX25519 msg1 msg2
      describe "stress test 1k" $ do
        let deliver n = deliverMessagesViaProxy srv1 srv2 C.SEd448 [] (map bshow [1 :: Int .. n])
        it "1x1000" . twoServersFirstProxy $ deliver 1000
        it "5x200" . twoServersFirstProxy $ 5 `inParrallel` deliver 200
        it "10x100" . twoServersFirstProxy $ 10 `inParrallel` deliver 100
      xdescribe "stress test 10k" $ do
        let deliver n = deliverMessagesViaProxy srv1 srv2 C.SEd448 [] (map bshow [1 :: Int .. n])
        it "1x10000" . twoServersFirstProxy $ deliver 10000
        it "5x2000" . twoServersFirstProxy $ 5 `inParrallel` deliver 2000
        it "10x1000" . twoServersFirstProxy $ 10 `inParrallel` deliver 1000
        it "100x100 N1" . twoServersFirstProxy $ withNumCapabilities 1 $ 100 `inParrallel` deliver 100
        it "100x100 N4 C1" . twoServersNoConc $ withNumCapabilities 4 $ 100 `inParrallel` deliver 100
        it "100x100 N4 C2" . twoServersFirstProxy $ withNumCapabilities 4 $ 100 `inParrallel` deliver 100
        it "100x100 N4 C16" . twoServersMoreConc $ withNumCapabilities 4 $ 100 `inParrallel` deliver 100
        it "100x100 N" . twoServersFirstProxy $ withNCPUCapabilities $ 100 `inParrallel` deliver 100
        it "500x20" . twoServersFirstProxy $ 500 `inParrallel` deliver 20
    describe "agent API" $ do
      describe "one server" $ do
        it "always via proxy" . oneServer $
          agentDeliverMessageViaProxy ([srv1], SPMAlways, True) ([srv1], SPMAlways, True) C.SEd448 "hello 1" "hello 2"
        it "without proxy" . oneServer $
          agentDeliverMessageViaProxy ([srv1], SPMNever, False) ([srv1], SPMNever, False) C.SEd448 "hello 1" "hello 2"
      describe "two servers" $ do
        it "always via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMAlways, True) ([srv2], SPMAlways, True) C.SEd448 "hello 1" "hello 2"
        it "both via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv2], SPMUnknown, True) C.SEd448 "hello 1" "hello 2"
        it "first via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv2], SPMNever, False) C.SEd448 "hello 1" "hello 2"
        it "without proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMNever, False) ([srv2], SPMNever, False) C.SEd448 "hello 1" "hello 2"
        it "first via proxy for unknown" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv1, srv2], SPMUnknown, False) C.SEd448 "hello 1" "hello 2"
        it "without proxy with fallback" . twoServers_ proxyCfg cfgV7 $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, False) ([srv2], SPMUnknown, False) C.SEd448 "hello 1" "hello 2"
        it "fails when fallback is prohibited" . twoServers_ proxyCfg cfgV7 $
          agentViaProxyVersionError
      describe "stress test 1k" $ do
        let deliver nAgents nMsgs = agentDeliverMessagesViaProxyConc (replicate nAgents [srv1]) (map bshow [1 :: Int .. nMsgs])
        it "2 agents, 250 messages" . oneServer $ deliver 2 250
        it "5 agents, 10 pairs, 50 messages, N1" . oneServer . withNumCapabilities 1 $ deliver 5 50
        it "5 agents, 10 pairs, 50 messages. N4" . oneServer . withNumCapabilities 4 $ deliver 5 50
      xdescribe "stress test 10k" $ do
        let deliver nAgents nMsgs = agentDeliverMessagesViaProxyConc (replicate nAgents [srv1]) (map bshow [1 :: Int .. nMsgs])
        it "25 agents, 300 pairs, 17 messages" . oneServer . withNumCapabilities 4 $ deliver 25 17
  where
    oneServer = withSmpServerConfigOn (transport @TLS) proxyCfg {msgQueueQuota = 128} testPort . const
    twoServers = twoServers_ proxyCfg proxyCfg
    twoServersFirstProxy = twoServers_ proxyCfg cfgV8 {msgQueueQuota = 128}
    twoServersMoreConc = twoServers_ proxyCfg {serverClientConcurrency = 128} cfgV8 {msgQueueQuota = 128}
    twoServersNoConc = twoServers_ proxyCfg {serverClientConcurrency = 1} cfgV8 {msgQueueQuota = 128}
    twoServers_ cfg1 cfg2 runTest =
      withSmpServerConfigOn (transport @TLS) cfg1 testPort $ \_ ->
        withSmpServerConfigOn (transport @TLS) cfg2 testPort2 $ const runTest

deliverMessageViaProxy :: (C.AlgorithmI a, C.AuthAlgorithm a) => SMPServer -> SMPServer -> C.SAlgorithm a -> ByteString -> ByteString -> IO ()
deliverMessageViaProxy proxyServ relayServ alg msg msg' = deliverMessagesViaProxy proxyServ relayServ alg [msg] [msg']

deliverMessagesViaProxy :: (C.AlgorithmI a, C.AuthAlgorithm a) => SMPServer -> SMPServer -> C.SAlgorithm a -> [ByteString] -> [ByteString] -> IO ()
deliverMessagesViaProxy proxyServ relayServ alg unsecuredMsgs securedMsgs = do
  g <- C.newRandom
  -- set up proxy
  pc' <- getProtocolClient g (1, proxyServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion} Nothing (\_ -> pure ())
  pc <- either (fail . show) pure pc'
  THAuthClient {} <- maybe (fail "getProtocolClient returned no thAuth") pure $ thAuth $ thParams pc
  -- set up relay
  msgQ <- newTBQueueIO 1024
  rc' <- getProtocolClient g (2, relayServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion authCmdsSMPVersion} (Just msgQ) (\_ -> pure ())
  rc <- either (fail . show) pure rc'
  -- prepare receiving queue
  (rPub, rPriv) <- atomically $ C.generateAuthKeyPair alg g
  (rdhPub, rdhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  QIK {rcvId, sndId, rcvPublicDhKey = srvDh} <- runExceptT' $ createSMPQueue rc (rPub, rPriv) rdhPub (Just "correct") SMSubscribe
  let dec = decryptMsgV3 $ C.dh' srvDh rdhPriv
  -- get proxy session
  sess0 <- runExceptT' $ connectSMPProxiedRelay pc relayServ (Just "correct")
  sess <- runExceptT' $ connectSMPProxiedRelay pc relayServ (Just "correct")
  sess0 `shouldBe` sess
  -- send via proxy to unsecured queue
  forM_ unsecuredMsgs $ \msg -> do
    runExceptT' (proxySMPMessage pc sess Nothing sndId noMsgFlags msg) `shouldReturn` Right ()
    runExceptT' (proxySMPMessage pc sess {prSessionId = "bad session"} Nothing sndId noMsgFlags msg) `shouldReturn` Left (ProxyProtocolError $ SMP.PROXY SMP.NO_SESSION)
    -- receive 1
    (_tSess, _v, _sid, [(_entId, STEvent (Right (SMP.MSG RcvMessage {msgId, msgBody = EncRcvMsgBody encBody})))]) <- atomically $ readTBQueue msgQ
    dec msgId encBody `shouldBe` Right msg
    runExceptT' $ ackSMPMessage rc rPriv rcvId msgId
  -- secure queue
  (sPub, sPriv) <- atomically $ C.generateAuthKeyPair alg g
  runExceptT' $ secureSMPQueue rc rPriv rcvId sPub
  -- send via proxy to secured queue
  waitSendRecv
    ( forM_ securedMsgs $ \msg' ->
        runExceptT' (proxySMPMessage pc sess (Just sPriv) sndId noMsgFlags msg') `shouldReturn` Right ()
    )
    ( forM_ securedMsgs $ \msg' -> do
        (_tSess, _v, _sid, [(_entId, STEvent (Right (SMP.MSG RcvMessage {msgId = msgId', msgBody = EncRcvMsgBody encBody'})))]) <- atomically $ readTBQueue msgQ
        dec msgId' encBody' `shouldBe` Right msg'
        runExceptT' $ ackSMPMessage rc rPriv rcvId msgId'
    )

agentDeliverMessageViaProxy :: (C.AlgorithmI a, C.AuthAlgorithm a) => (NonEmpty SMPServer, SMPProxyMode, Bool) -> (NonEmpty SMPServer, SMPProxyMode, Bool) -> C.SAlgorithm a -> ByteString -> ByteString -> IO ()
agentDeliverMessageViaProxy aTestCfg@(aSrvs, _, aViaProxy) bTestCfg@(bSrvs, _, bViaProxy) alg msg1 msg2 =
  withAgent 1 aCfg (servers aTestCfg) testDB $ \alice ->
    withAgent 2 aCfg (servers bTestCfg) testDB2 $ \bob -> runRight_ $ do
      (bobId, qInfo) <- A.createConnection alice 1 True SCMInvitation Nothing (CR.IKNoPQ PQSupportOn) SMSubscribe
      aliceId <- A.joinConnection bob 1 Nothing True qInfo "bob's connInfo" PQSupportOn SMSubscribe
      ("", _, A.CONF confId pqSup' _ "bob's connInfo") <- get alice
      liftIO $ pqSup' `shouldBe` PQSupportOn
      allowConnection alice bobId confId "alice's connInfo"
      let pqEnc = CR.PQEncOn
      get alice ##> ("", bobId, A.CON pqEnc)
      get bob ##> ("", aliceId, A.INFO PQSupportOn "alice's connInfo")
      get bob ##> ("", aliceId, A.CON pqEnc)
      -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
      let aProxySrv = if aViaProxy then Just $ L.head aSrvs else Nothing
      1 <- msgId <$> A.sendMessage alice bobId pqEnc noMsgFlags msg1
      get alice ##> ("", bobId, A.SENT (baseId + 1) aProxySrv)
      2 <- msgId <$> A.sendMessage alice bobId pqEnc noMsgFlags msg2
      get alice ##> ("", bobId, A.SENT (baseId + 2) aProxySrv)
      get bob =##> \case ("", c, Msg' _ pq msg1') -> c == aliceId && pq == pqEnc && msg1 == msg1'; _ -> False
      ackMessage bob aliceId (baseId + 1) Nothing
      get bob =##> \case ("", c, Msg' _ pq msg2') -> c == aliceId && pq == pqEnc && msg2 == msg2'; _ -> False
      ackMessage bob aliceId (baseId + 2) Nothing
      let bProxySrv = if bViaProxy then Just $ L.head bSrvs else Nothing
      3 <- msgId <$> A.sendMessage bob aliceId pqEnc noMsgFlags msg1
      get bob ##> ("", aliceId, A.SENT (baseId + 3) bProxySrv)
      4 <- msgId <$> A.sendMessage bob aliceId pqEnc noMsgFlags msg2
      get bob ##> ("", aliceId, A.SENT (baseId + 4) bProxySrv)
      get alice =##> \case ("", c, Msg' _ pq msg1') -> c == bobId && pq == pqEnc && msg1 == msg1'; _ -> False
      ackMessage alice bobId (baseId + 3) Nothing
      get alice =##> \case ("", c, Msg' _ pq msg2') -> c == bobId && pq == pqEnc && msg2 == msg2'; _ -> False
      ackMessage alice bobId (baseId + 4) Nothing
  where
    baseId = 3
    msgId = subtract baseId . fst
    aCfg = agentProxyCfg {sndAuthAlg = C.AuthAlg alg, rcvAuthAlg = C.AuthAlg alg}
    servers (srvs, smpProxyMode, _) = (initAgentServersProxy smpProxyMode SPFAllow) {smp = userServers $ L.map noAuthSrv srvs}

agentDeliverMessagesViaProxyConc :: [NonEmpty SMPServer] -> [MsgBody] -> IO ()
agentDeliverMessagesViaProxyConc agentServers msgs =
  withAgents $ \agents -> do
    let pairs = combinations 2 agents
    logNote $ "Pairing " <> tshow (length agents) <> " agents into " <> tshow (length pairs) <> " connections"
    connections <- forM pairs $ \case
      [a, b] -> prePair a b
      _ -> error "agents must be paired"
    logNote "Running..."
    mapConcurrently_ run connections
  where
    withAgents :: ([AgentClient] -> IO ()) -> IO ()
    withAgents action = go [] (zip [1 :: Int ..] agentServers)
      where
        go agents = \case
          [] -> action agents
          (aId, aSrvs) : next -> withAgent aId aCfg (servers aSrvs) (dbPrefix <> show aId <> dbSuffix) $ \a -> (a : agents) `go` next
        (dbPrefix, dbSuffix) = splitExtensions testDB
    -- agent connections have to be set up in advance
    -- otherwise the CONF messages would get mixed with MSG
    prePair alice bob = do
      (bobId, qInfo) <- runExceptT' $ A.createConnection alice 1 True SCMInvitation Nothing (CR.IKNoPQ PQSupportOn) SMSubscribe
      aliceId <- runExceptT' $ A.joinConnection bob 1 Nothing True qInfo "bob's connInfo" PQSupportOn SMSubscribe
      confId <-
        get alice >>= \case
          ("", _, A.CONF confId pqSup' _ "bob's connInfo") -> do
            pqSup' `shouldBe` PQSupportOn
            pure confId
          huh -> fail $ show huh
      runExceptT' $ allowConnection alice bobId confId "alice's connInfo"
      get alice ##> ("", bobId, A.CON pqEnc)
      get bob ##> ("", aliceId, A.INFO PQSupportOn "alice's connInfo")
      get bob ##> ("", aliceId, A.CON pqEnc)
      pure (alice, bobId, bob, aliceId)
    -- stream messages in opposite directions, while getting deliveries and sending ACKs
    run (alice, bobId, bob, aliceId) = do
      aSender <- async $ forM_ msgs $ runExceptT' . A.sendMessage alice bobId pqEnc noMsgFlags
      bRecipient <-
        async $
          forever $
            get bob >>= \case
              ("", _, A.SENT _ _) -> pure ()
              ("", _, Msg' mId' _ _) -> runExceptT' $ ackMessage alice bobId mId' Nothing
              huh -> fail (show huh)
      bSender <- async $ forM_ msgs $ runExceptT' . A.sendMessage bob aliceId pqEnc noMsgFlags
      aRecipient <-
        async $
          forever $
            get alice >>= \case
              ("", _, A.SENT _ _) -> pure ()
              ("", _, Msg' mId' _ _) -> runExceptT' $ ackMessage alice bobId mId' Nothing
              huh -> fail (show huh)
      logDebug "run waiting..."
      a2b <- async $ (waitCatch aSender >>= either throwIO pure) `finally` cancel bRecipient -- stopped sender cancels paired recipient loop
      b2a <- async $ (waitCatch bSender >>= either throwIO pure) `finally` cancel aRecipient
      waitEitherCatch a2b b2a >>= \case
        Right (Right ()) -> wait b2a
        Right (Left e) -> cancel bSender >> throwIO e
        Left (Right ()) -> wait a2b
        Left (Left e) -> cancel aSender >> throwIO e
      logDebug "run finished"
    pqEnc = CR.PQEncOn
    aCfg = agentProxyCfg {sndAuthAlg = C.AuthAlg C.SEd448, rcvAuthAlg = C.AuthAlg C.SEd448}
    servers srvs = (initAgentServersProxy SPMAlways SPFAllow) {smp = userServers $ L.map noAuthSrv srvs}

agentViaProxyVersionError :: IO ()
agentViaProxyVersionError =
  withAgent 1 agentProxyCfg (servers [SMPServer testHost testPort testKeyHash]) testDB $ \alice -> do
    Left (A.BROKER _ (TRANSPORT TEVersion)) <-
      withAgent 2 agentProxyCfg (servers [SMPServer testHost testPort2 testKeyHash]) testDB2 $ \bob -> runExceptT $ do
        (_bobId, qInfo) <- A.createConnection alice 1 True SCMInvitation Nothing (CR.IKNoPQ PQSupportOn) SMSubscribe
        A.joinConnection bob 1 Nothing True qInfo "bob's connInfo" PQSupportOn SMSubscribe
    pure ()
  where
    servers srvs = (initAgentServersProxy SPMUnknown SPFProhibit) {smp = userServers $ L.map noAuthSrv srvs}

testNoProxy :: IO ()
testNoProxy = do
  withSmpServerConfigOn (transport @TLS) cfg testPort2 $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort2 proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer Nothing)
      reply `shouldBe` Right (SMP.ERR $ SMP.PROXY SMP.BASIC_AUTH)

testProxyAuth :: IO ()
testProxyAuth = do
  withSmpServerConfigOn (transport @TLS) proxyCfgAuth testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _s, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 $ Just "wrong")
      reply `shouldBe` Right (SMP.ERR $ SMP.PROXY SMP.BASIC_AUTH)
  where
    proxyCfgAuth = proxyCfg {newQueueBasicAuth = Just "correct"}

todo :: IO ()
todo = do
  fail "TODO"

runExceptT' :: Exception e => ExceptT e IO a -> IO a
runExceptT' a = runExceptT a >>= either throwIO pure

waitSendRecv :: IO () -> IO () -> IO ()
waitSendRecv s r = do
  s' <- async s
  r' <- async r
  waitCatch s' >>= either (\e -> cancel r' >> fail (show e)) pure
  waitCatch r' >>= either (\e -> cancel s' >> fail (show e)) pure
