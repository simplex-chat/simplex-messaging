{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.ConnectionRequestTests where

import Data.ByteString (ByteString)
import Network.HTTP.Types (urlEncode)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parseAll)
import Test.Hspec

uri :: String
uri = "smp.simplex.im"

srv :: SMPServer
srv =
  SMPServer
    { host = "smp.simplex.im",
      port = Just "5223",
      keyHash = Just (C.KeyHash "\215m\248\251")
    }

queue :: SMPQueueUri
queue =
  SMPQueueUri
    { smpServer = srv,
      senderId = "\223\142z\251",
      dhPublicKey = testDhKey
    }

testDhKey :: C.PublicKeyX25519
testDhKey = "MCowBQYDK2VuAyEAjiswwI3O/NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

testDhKeyStr :: ByteString
testDhKeyStr = C.serializePubKeyUri' testDhKey

testDhKeyStrUri :: ByteString
testDhKeyStrUri = urlEncode True testDhKeyStr

appServer :: ConnReqScheme
appServer = CRSAppServer "simplex.chat" Nothing

connectionRequest :: AConnectionRequest
connectionRequest =
  ACR SCMInvitation . CRInvitation $
    ConnReqData
      { crScheme = appServer,
        crSmpQueues = [queue],
        crEncryption = ConnectionEncryption
      }

connectionRequestTests :: Spec
connectionRequestTests =
  describe "connection request parsing / serializing" $ do
    it "should serialize SMP queue URIs" $ do
      serializeSMPQueueUri queue {smpServer = srv {port = Nothing}}
        `shouldBe` "smp://1234-w==@smp.simplex.im/3456-w==#" <> testDhKeyStr
      serializeSMPQueueUri queue
        `shouldBe` "smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr
    it "should parse SMP queue URIs" $ do
      parseAll smpQueueUriP ("smp://1234-w==@smp.simplex.im/3456-w==#" <> testDhKeyStr)
        `shouldBe` Right queue {smpServer = srv {port = Nothing}}
      parseAll smpQueueUriP ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr)
        `shouldBe` Right queue
    it "should serialize connection requests" $ do
      serializeConnReq connectionRequest
        `shouldBe` "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
        <> testDhKeyStrUri
        <> "&e2e="
    it "should parse connection requests" $ do
      parseAll
        connReqP
        ( "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
            <> testDhKeyStrUri
            <> "&e2e="
        )
        `shouldBe` Right connectionRequest
