{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.RemoteControl.Discovery where

import Control.Logger.Simple
import Control.Monad
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.Default (def)
import Data.String (IsString)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Word (Word16)
import qualified Network.Socket as N
import qualified Network.TLS as TLS
import qualified Network.UDP as UDP
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding (Encoding (..))
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Transport (supportedParameters)
import qualified Simplex.Messaging.Transport as Transport
import Simplex.Messaging.Transport.Client (TransportHost (..), defaultTransportClientConfig, runTransportClient)
import Simplex.Messaging.Transport.Server (defaultTransportServerConfig, runTransportServerSocket, startTCPServer)
import Simplex.Messaging.Util (ifM, tshow)
import Simplex.Messaging.Version (VersionRange)
import Simplex.RemoteControl.Discovery.Multicast (setMembership)
import Simplex.RemoteControl.Types
import UnliftIO
import UnliftIO.Concurrent

-- | mDNS multicast group
pattern MULTICAST_ADDR_V4 :: (IsString a, Eq a) => a
pattern MULTICAST_ADDR_V4 = "224.0.0.251"

pattern ANY_ADDR_V4 :: (IsString a, Eq a) => a
pattern ANY_ADDR_V4 = "0.0.0.0"

pattern DISCOVERY_PORT :: (IsString a, Eq a) => a
pattern DISCOVERY_PORT = "5227"

getLocalAddress :: MonadIO m => TMVar Int -> m (Maybe N.HostAddress)
getLocalAddress subscribers = liftIO $ do
  probe <- mkIpProbe
  let bytes = smpEncode probe
  withListener subscribers $ \receiver ->
    withSender $ \sender -> do
      UDP.send sender bytes
      let expect = do
            UDP.recvFrom receiver >>= \case
              (p, _) | p /= bytes -> expect
              (_, UDP.ClientSockAddr (N.SockAddrInet _port host) _cmsg) -> pure host
              (_, UDP.ClientSockAddr _badAddr _) -> error "receiving from IPv4 socket"
      timeout 1000000 expect

mkIpProbe :: MonadIO m => m IpProbe
mkIpProbe = do
  randomNonce <- liftIO $ getRandomBytes 32
  pure IpProbe {versionRange = ipProbeVersionRange, randomNonce}

data CtrlCryptoHandle = CtrlCryptoHandle

-- TODO: add initial keys

-- | Announce tls server, wait for connection and attach http2 client to it.
--
-- Announcer is started when TLS server is started and stopped when a connection is made.
announceCtrl ::
  MonadUnliftIO m =>
  (MVar rc -> MVar () -> CtrlCryptoHandle -> Transport.TLS -> IO ()) ->
  Tasks ->
  TMVar (Maybe N.PortNumber) ->
  Maybe (Text, VersionRange) ->
  Maybe Text ->
  C.PrivateKeyEd25519 ->
  CtrlSessionKeys ->
  -- | Session address to announce
  TransportHost ->
  m () ->
  m rc
announceCtrl runCtrl tasks started app_ device_ idkey sk@CtrlSessionKeys {ca, credentials} host finishAction = do
  ctrlStarted <- newEmptyMVar
  ctrlFinished <- newEmptyMVar
  _ <- forkIO $ readMVar ctrlFinished >> finishAction -- attach external cleanup action to session lock
  announcer <-
    async . liftIO $
      atomically (readTMVar started) >>= \case
        Nothing -> pure () -- TLS server failed to start, skipping announcer
        Just givenPort -> do
          logInfo $ "Starting announcer for " <> ident <> " at " <> tshow (host, givenPort)
          runAnnouncer app_ device_ idkey sk (host, givenPort) -- (sigKey, announce {serviceAddress = (host, fromIntegral givenPort)})
  tasks `registerAsync` announcer
  tlsServer <- startTLSServer started credentials $ \tls -> do
    logInfo $ "Incoming connection for " <> ident
    cancel announcer
    let ctrlCryptoHandle = CtrlCryptoHandle -- TODO
    runCtrl ctrlStarted ctrlFinished ctrlCryptoHandle tls `catchAny` (logError . tshow)
    logInfo $ "Client finished for " <> ident
  _ <- forkIO $ waitCatch tlsServer >> void (tryPutMVar ctrlFinished ())
  tasks `registerAsync` tlsServer
  logInfo $ "Waiting for client for " <> ident
  readMVar ctrlStarted
  where
    ident = decodeUtf8 $ strEncode ca

runAnnouncer :: Maybe (Text, VersionRange) -> Maybe Text -> C.PrivateKeyEd25519 -> CtrlSessionKeys -> (TransportHost, N.PortNumber) -> IO ()
runAnnouncer app_ device_ idSigKey sk (host, port) = error "runAnnouncer: make invites, encrypt and send"

-- | Send replay-proof announce datagrams
-- runAnnouncer :: (C.PrivateKeyEd25519, Announce) -> IO ()
-- runAnnouncer (announceKey, initialAnnounce) = withSender $ loop initialAnnounce
--   where
--     loop announce sock = do
--       UDP.send sock $ smpEncode (signAnnounce announceKey announce)
--       threadDelay 1000000
--       loop announce {announceCounter = announceCounter announce + 1} sock
startTLSServer :: MonadUnliftIO m => TMVar (Maybe N.PortNumber) -> TLS.Credentials -> (Transport.TLS -> IO ()) -> m (Async ())
startTLSServer started credentials server = async . liftIO $ do
  startedOk <- newEmptyTMVarIO
  bracketOnError (startTCPServer startedOk "0") (\_e -> void . atomically $ tryPutTMVar started Nothing) $ \socket ->
    ifM
      (atomically $ readTMVar startedOk)
      do
        port <- N.socketPort socket
        logInfo $ "System-assigned port: " <> tshow port
        atomically $ putTMVar started (Just port)
        runTransportServerSocket startedOk (pure socket) "RCP TLS" serverParams defaultTransportServerConfig server
      (void . atomically $ tryPutTMVar started Nothing)
  where
    serverParams =
      def
        { TLS.serverWantClientCert = False,
          TLS.serverShared = def {TLS.sharedCredentials = credentials},
          TLS.serverHooks = def,
          TLS.serverSupported = supportedParameters
        }

withSender :: MonadUnliftIO m => (UDP.UDPSocket -> m a) -> m a
withSender = bracket (liftIO $ UDP.clientSocket MULTICAST_ADDR_V4 DISCOVERY_PORT False) (liftIO . UDP.close)

withListener :: MonadUnliftIO m => TMVar Int -> (UDP.ListenSocket -> m a) -> m a
withListener subscribers = bracket (openListener subscribers) (closeListener subscribers)

openListener :: MonadIO m => TMVar Int -> m UDP.ListenSocket
openListener subscribers = liftIO $ do
  sock <- UDP.serverSocket (MULTICAST_ADDR_V4, read DISCOVERY_PORT)
  logDebug $ "Discovery listener socket: " <> tshow sock
  let raw = UDP.listenSocket sock
  -- N.setSocketOption raw N.Broadcast 1
  joinMulticast subscribers raw (listenerHostAddr4 sock)
  pure sock

closeListener :: MonadIO m => TMVar Int -> UDP.ListenSocket -> m ()
closeListener subscribers sock =
  liftIO $
    partMulticast subscribers (UDP.listenSocket sock) (listenerHostAddr4 sock) `finally` UDP.stop sock

joinMulticast :: TMVar Int -> N.Socket -> N.HostAddress -> IO ()
joinMulticast subscribers sock group = do
  now <- atomically $ takeTMVar subscribers
  when (now == 0) $ do
    setMembership sock group True >>= \case
      Left e -> atomically (putTMVar subscribers now) >> logError ("setMembership failed " <> tshow e)
      Right () -> atomically $ putTMVar subscribers (now + 1)

partMulticast :: TMVar Int -> N.Socket -> N.HostAddress -> IO ()
partMulticast subscribers sock group = do
  now <- atomically $ takeTMVar subscribers
  when (now == 1) $
    setMembership sock group False >>= \case
      Left e -> atomically (putTMVar subscribers now) >> logError ("setMembership failed " <> tshow e)
      Right () -> atomically $ putTMVar subscribers (now - 1)

listenerHostAddr4 :: UDP.ListenSocket -> N.HostAddress
listenerHostAddr4 sock = case UDP.mySockAddr sock of
  N.SockAddrInet _port host -> host
  _ -> error "MULTICAST_ADDR_V4 is V4"

recvAnnounce :: MonadIO m => UDP.ListenSocket -> m (N.SockAddr, ByteString)
recvAnnounce sock = liftIO $ do
  (invite, UDP.ClientSockAddr source _cmsg) <- UDP.recvFrom sock
  pure (source, invite)

connectTLSClient :: MonadUnliftIO m => (TransportHost, Word16) -> C.KeyHash -> (Transport.TLS -> m a) -> m a
connectTLSClient (host, port) caFingerprint = runTransportClient defaultTransportClientConfig Nothing host (show port) (Just caFingerprint)
