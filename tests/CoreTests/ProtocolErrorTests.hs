{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.ProtocolErrorTests where

import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Agent.Protocol as Agent
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CommandError (..), ErrorType (..), ProxyError (..))
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (HandshakeError (..), TransportError (..))
import Simplex.RemoteControl.Types (RCErrorType (..))
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

protocolErrorTests :: Spec
protocolErrorTests = modifyMaxSuccess (const 1000) $ do
  describe "errors parsing / serializing" $ do
    it "should parse SMP protocol errors" . property $ \(err :: ErrorType) ->
      smpDecode (smpEncode err) == Right err
    it "should parse SMP agent errors" . property . forAll possible $ \err ->
      strDecode (strEncode err) == Right err
  where
    possible :: Gen AgentErrorType
    possible =
      arbitrary >>= \case
        BROKER srv (Agent.RESPONSE e) | hasSpaces srv || hasSpaces e -> discard
        BROKER srv _ | hasSpaces srv -> discard
        SMP (PROXY (SMP.UNEXPECTED s)) | hasUnicode s -> discard
        NTF (PROXY (SMP.UNEXPECTED s)) | hasUnicode s -> discard
        ok -> pure ok
    hasSpaces s = ' ' `B.elem` encodeUtf8 (T.pack s)
    hasUnicode = any (>= '\255')

deriving instance Generic AgentErrorType

deriving instance Generic CommandErrorType

deriving instance Generic ConnectionErrorType

deriving instance Generic BrokerErrorType

deriving instance Generic SMPAgentError

deriving instance Generic AgentCryptoError

deriving instance Generic ErrorType

deriving instance Generic CommandError

deriving instance Generic ProxyError

deriving instance Generic TransportError

deriving instance Generic HandshakeError

deriving instance Generic XFTPErrorType

deriving instance Generic RCErrorType

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

instance Arbitrary AgentCryptoError where arbitrary = genericArbitraryU

instance Arbitrary ErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandError where arbitrary = genericArbitraryU

instance Arbitrary ProxyError where arbitrary = genericArbitraryU

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

instance Arbitrary XFTPErrorType where arbitrary = genericArbitraryU

instance Arbitrary RCErrorType where arbitrary = genericArbitraryU
