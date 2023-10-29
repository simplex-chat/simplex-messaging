{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG
  ( RNG (..),
    dummyRNG,
    withHaskellRNG,
    startHaskellRNG,
    stopHaskellRNG,
    RNGContext,
    RNGFunc,
    mkRNGFunc,
  ) where

import Foreign
import Foreign.C

import Crypto.Random (drgNew, randomBytesGenerate)
import Data.ByteArray (ByteArrayAccess (copyByteArrayToPtr), Bytes)
import Data.IORef (atomicModifyIORef', newIORef)
import UnliftIO (bracket)

data RNG = RNG
  { rngContext :: RNGContext,
    rngFunc :: FunPtr RNGFunc
  }

dummyRNG :: RNG
dummyRNG = RNG {rngContext = nullPtr, rngFunc = randomDummy}

withHaskellRNG :: (RNG -> IO c) -> IO c
withHaskellRNG = bracket startHaskellRNG stopHaskellRNG

startHaskellRNG :: IO RNG
startHaskellRNG = do
  chachaState <- drgNew >>= newIORef -- XXX: ctxPtr could be used to store drg state, but cryptonite doesn't provide ByteAccess for ChaChaDRG
  rngFunc <- mkRNGFunc $ \_ctxPtr sz buf -> do
    bs <- atomicModifyIORef' chachaState $ swap . randomBytesGenerate (fromIntegral sz) :: IO Bytes
    copyByteArrayToPtr bs buf
  pure RNG {rngContext = nullPtr, rngFunc}
  where
    swap (a, b) = (b, a)

stopHaskellRNG :: RNG -> IO ()
stopHaskellRNG RNG {rngFunc} = freeHaskellFunPtr rngFunc

type RNGContext = Ptr RNG

-- typedef void random_func (void *ctx, size_t length, uint8_t *dst);
type RNGFunc = Ptr RNGContext -> CSize -> Ptr Word8 -> IO ()

foreign import ccall "&sxcrandom_dummy"
  randomDummy :: FunPtr RNGFunc

foreign import ccall "wrapper"
  mkRNGFunc :: RNGFunc -> IO (FunPtr RNGFunc)
