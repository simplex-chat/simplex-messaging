{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import ChatOptions
import ChatTerminal
import Control.Applicative ((<|>))
import Control.Concurrent.STM
import Control.Logger.Simple
-- import Control.Monad (when)
import Control.Monad.Reader
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Numeric.Natural
import Simplex.Messaging.Agent (getSMPAgentClient, runSMPAgentClient)
import Simplex.Messaging.Agent.Client (AgentClient (..))
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (smpDefaultConfig)
import Simplex.Messaging.Util (bshow, raceAny_)
-- import System.IO (BufferMode (..), hReady, hSetBuffering, hSetEcho, stdin, stdout)
import Types

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = undefined, -- TODO maybe take it out of config
      rsaKeySize = 2048 `div` 8,
      connIdBytes = 12,
      tbqSize = 16,
      dbFile = "smp-chat.db",
      smpCfg = smpDefaultConfig
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

data ChatClient = ChatClient
  { inQ :: TBQueue ChatCommand,
    outQ :: TBQueue ChatResponse,
    smpServer :: SMPServer,
    username :: TVar (Maybe Contact)
  }

-- | GroupMessage ChatGroup ByteString
-- | AddToGroup Contact
data ChatCommand
  = ChatHelp
  | AddContact Contact
  | AcceptContact Contact SMPQueueInfo
  | ChatWith Contact
  | SetName Contact
  | SendMessage Contact ByteString

chatCommandP :: Parser ChatCommand
chatCommandP =
  "/help" $> ChatHelp
    <|> "/add " *> (AddContact <$> contact)
    <|> "/accept " *> acceptContact
    <|> "/chat " *> chatWith
    <|> "/name " *> setName
    <|> "@" *> sendMessage
  where
    acceptContact = AcceptContact <$> contact <* A.space <*> smpQueueInfoP
    chatWith = ChatWith <$> contact
    setName = SetName <$> contact
    sendMessage = SendMessage <$> contact <* A.space <*> A.takeByteString
    contact = Contact <$> A.takeTill (== ' ')

data ChatResponse
  = ChatHelpInfo
  | Invitation SMPQueueInfo
  | Connected Contact
  | ReceivedMessage Contact ByteString
  | Disconnected Contact
  | YesYes
  | ErrorInput ByteString
  | ChatError AgentErrorType
  | NoChatResponse

serializeChatResponse :: Maybe Contact -> ChatResponse -> ByteString
serializeChatResponse name = \case
  ChatHelpInfo -> chatHelpInfo
  Invitation qInfo -> "ask your contact to enter: /accept " <> showName name <> " " <> serializeSmpQueueInfo qInfo
  Connected c -> ttyContact c <> " connected"
  ReceivedMessage c t -> ttyFromContact c <> " " <> t
  Disconnected c -> "disconnected from " <> ttyContact c <> " - try \"/chat " <> toBs c <> "\""
  YesYes -> "you got it!"
  ErrorInput t -> "invalid input: " <> t
  ChatError e -> "chat error: " <> bshow e
  NoChatResponse -> ""
  where
    showName Nothing = "<your name>"
    showName (Just (Contact a)) = a

chatHelpInfo :: ByteString
chatHelpInfo =
  "Using chat:\n\
  \/add <name>       - create invitation to send out-of-band\n\
  \                    to your contact <name>\n\
  \                    (any unique string without spaces)\n\
  \/accept <name> <invitation> - accept <invitation>\n\
  \                    (a string that starts from \"smp::\")\n\
  \                    from your contact <name>\n\
  \/chat <name>      - resume chat with <name>\n\
  \/name <name>      - set <name> to use in invitations\n\
  \@<name> <message> - send <message> (any string) to contact <name>\n\
  \                    @<name> can be omitted to send to previous"

-- Simple menu controller

-- main :: IO ()
-- main = do
--   hSetBuffering stdin NoBuffering
--   hSetBuffering stdout NoBuffering
--   hSetEcho stdin False
--   key <- getKey
--   when (key /= "\ESC") $ do
--     case key of
--       -- "\ESC[A" -> print "↑"
--       -- "\ESC[B" -> print "↓"
--       -- "\ESC[C" -> print "→"
--       -- "\ESC[D" -> print "←"
--       "\n" -> print "⎆"
--       "\DEL" -> print "⎋"
--       ch -> print ch >> print (length ch)
--     main

-- getKey :: IO [Char]
-- getKey = reverse <$> keyChars ""
--   where
--     -- charsToKey = \case
--     --   "\ESC" -> KeyEsc
--     --   "\ESC[A" -> KeyUp
--     --   "\ESC[B" -> KeyDown
--     --   "\ESC[C" -> KeyRight
--     --   "\ESC[D" -> KeyLeft
--     --   "\n" -> KeyEnter
--     --   "\DEL" -> KeyDel
--     --   [c] -> KeyChar c
--     --   cs -> KeyUnknown cs

--     keyChars cs = do
--       c <- getChar
--       more <- hReady stdin
--       (if more then keyChars else return) (c : cs)

main :: IO ()
main = do
  ChatOpts {dbFileName, smpServer, name} <- getChatOpts
  putStrLn "simpleX chat prototype (no encryption), \"/help\" for usage information"
  t <- getChatClient smpServer (Contact <$> name)
  ct <- newChatTerminal (tbqSize cfg)
  -- setLogLevel LogInfo -- LogError
  -- withGlobalLogging logCfg $
  env <- newSMPAgentEnv cfg {dbFile = dbFileName}
  dogFoodChat t ct env

dogFoodChat :: ChatClient -> ChatTerminal -> Env -> IO ()
dogFoodChat t ct env = do
  c <- runReaderT getSMPAgentClient env
  raceAny_
    [ runReaderT (runSMPAgentClient c) env,
      sendToAgent t ct c,
      sendToChatTerm t ct,
      receiveFromAgent t ct c,
      receiveFromChatTerm t ct,
      chatTerminal ct
    ]

getChatClient :: SMPServer -> Maybe Contact -> IO ChatClient
getChatClient srv name = atomically $ newChatClient (tbqSize cfg) srv name

newChatClient :: Natural -> SMPServer -> Maybe Contact -> STM ChatClient
newChatClient qSize smpServer name = do
  inQ <- newTBQueue qSize
  outQ <- newTBQueue qSize
  username <- newTVar name
  return ChatClient {inQ, outQ, smpServer, username}

receiveFromChatTerm :: ChatClient -> ChatTerminal -> IO ()
receiveFromChatTerm t ChatTerminal {inputQ} = forever $ do
  atomically (readTBQueue inputQ)
    >>= processOrError . A.parseOnly (chatCommandP <* A.endOfInput)
  where
    processOrError = \case
      Left err -> atomically . writeTBQueue (outQ t) . ErrorInput $ B.pack err
      Right ChatHelp -> atomically . writeTBQueue (outQ t) $ ChatHelpInfo
      Right (SetName a) -> atomically $ do
        writeTVar (username t) $ Just a
        writeTBQueue (outQ t) YesYes
      Right cmd -> atomically $ writeTBQueue (inQ t) cmd

sendToChatTerm :: ChatClient -> ChatTerminal -> IO ()
sendToChatTerm ChatClient {outQ, username} ChatTerminal {outputQ} = forever $ do
  atomically (readTBQueue outQ) >>= \case
    NoChatResponse -> return ()
    resp -> do
      name <- readTVarIO username
      atomically . writeTBQueue outputQ $ serializeChatResponse name resp

sendToAgent :: ChatClient -> ChatTerminal -> AgentClient -> IO ()
sendToAgent ChatClient {inQ, smpServer} ct AgentClient {rcvQ} =
  forever . atomically $ do
    cmd <- readTBQueue inQ
    writeTBQueue rcvQ `mapM_` agentTransmission cmd
    setActiveContact cmd
  where
    setActiveContact :: ChatCommand -> STM ()
    setActiveContact cmd =
      writeTVar (activeContact ct) $ case cmd of
        ChatWith a -> Just a
        SendMessage a _ -> Just a
        _ -> Nothing
    agentTransmission :: ChatCommand -> Maybe (ATransmission 'Client)
    agentTransmission = \case
      AddContact a -> transmission a $ NEW smpServer
      AcceptContact a qInfo -> transmission a $ JOIN qInfo $ ReplyVia smpServer
      ChatWith a -> transmission a SUB
      SendMessage a msg -> transmission a $ SEND msg
      ChatHelp -> Nothing
      SetName _ -> Nothing
    transmission :: Contact -> ACommand 'Client -> Maybe (ATransmission 'Client)
    transmission (Contact a) cmd = Just ("1", a, cmd)

receiveFromAgent :: ChatClient -> ChatTerminal -> AgentClient -> IO ()
receiveFromAgent t ct c = forever . atomically $ do
  resp <- chatResponse <$> readTBQueue (sndQ c)
  writeTBQueue (outQ t) resp
  setActiveContact resp
  where
    chatResponse :: ATransmission 'Agent -> ChatResponse
    chatResponse (_, a, resp) = case resp of
      INV qInfo -> Invitation qInfo
      CON -> Connected $ Contact a
      END -> Disconnected $ Contact a
      MSG {m_body} -> ReceivedMessage (Contact a) m_body
      SENT _ -> NoChatResponse
      OK -> YesYes
      ERR e -> ChatError e
    setActiveContact :: ChatResponse -> STM ()
    setActiveContact = \case
      Connected a -> set $ Just a
      ReceivedMessage a _ -> set $ Just a
      Disconnected _ -> set Nothing
      _ -> return ()
      where
        set a = writeTVar (activeContact ct) a
