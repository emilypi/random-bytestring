{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE BangPatterns #-}

-- -------------------------------------------------------------------------- --
-- |
-- Module: Implementations
-- Copyright: (c) Lars Kuhtz <lakuhtz@gmail.com> 2017
-- License: MIT
-- Maintainer: lakuhtz@gmail.com
-- Stability: experimental
--
-- -------------------------------------------------------------------------- --

module Implementations
( allImplementations

, random
, entropy
, mwcUnfoldr
, mwcUnfoldrIO

--
, mwcMalloc8
, mwcMalloc32
, mwcMalloc64
) where

import Control.Exception (bracketOnError)
import Control.Monad.Primitive

import Data.ByteString (ByteString, pack, unfoldrN)
import Data.ByteString.Unsafe (unsafePackAddressLen)
import Data.Word (Word8, Word32, Word64)

import Foreign (mallocBytes, poke, plusPtr, free, castPtr)

import GHC.Prim
import GHC.Ptr (Ptr(..))

import Numeric.Natural

import System.Entropy (getEntropy)
import System.Random (randoms, getStdGen)
import System.Random.MWC (uniform, create, Gen)

import Benchmarks

-- -------------------------------------------------------------------------- --
-- All Implemenations

allImplementations ∷ [Impl]
allImplementations =
    [ Impl "random" random
    , Impl "entropy" entropy
    , Impl "mwc-unfoldr" mwcUnfoldr
    , Impl "mwc-unfoldr-io" mwcUnfoldrIO
    , Impl "mwc-malloc-8" mwcMalloc8
    , Impl "mwc-malloc-32" mwcMalloc32
    , Impl "mwc-malloc-64" mwcMalloc64
    ]

-- -------------------------------------------------------------------------- --
-- Basic

random ∷ Natural → IO ByteString
random n = fmap (pack . take (fromIntegral n) . randoms) getStdGen

-- -------------------------------------------------------------------------- --
-- entropy

entropy ∷ Natural → IO ByteString
entropy n = getEntropy (fromIntegral n)

-- -------------------------------------------------------------------------- --
-- Malloc8

mwcMalloc8 ∷ Natural → IO ByteString
mwcMalloc8 n = do
    !gen ← create
    bracketOnError (mallocBytes len) free $ \ptr@(Ptr !addr) → do
        go gen ptr
        unsafePackAddressLen len addr

  where
    len ∷ Int
    !len = fromIntegral n

    go !gen !ptr = loop 0
      where
        loop !i
            | i == pred len = return ()
            | otherwise = do
                !b ← uniform gen ∷ IO Word8
                poke (ptr `plusPtr` i) b
                loop (succ i)

-- -------------------------------------------------------------------------- --
-- Malloc32

mwcMalloc32 ∷ Natural → IO ByteString
mwcMalloc32 n = do
    !gen ← create
    bracketOnError (mallocBytes len8) free $ \ptr@(Ptr !addr) → do
        go gen ptr
        unsafePackAddressLen len8 addr
  where
    len8, len32 ∷ Int
    !len8 = fromIntegral n
    !len32 = len8 `div` 4

    go !gen !startPtr = loop32 startPtr
      where
        !fin32Ptr = startPtr `plusPtr` (len32 * 4)
        loop32 !curPtr
            | curPtr < fin32Ptr = do
                !b ← uniform gen ∷ IO Word32
                poke curPtr b
                loop32 $ curPtr `plusPtr` 4
            | otherwise = loop8 $ castPtr curPtr

        !fin8Ptr = startPtr `plusPtr` len8
        loop8 !curPtr
            | curPtr < fin8Ptr = do
                !b ← uniform gen ∷ IO Word8
                poke curPtr b
                loop8 $ curPtr `plusPtr` 1
            | otherwise = return ()


-- -------------------------------------------------------------------------- --
-- Malloc64

mwcMalloc64 ∷ Natural → IO ByteString
mwcMalloc64 n = do
    !gen ← create
    bracketOnError (mallocBytes len8) free $ \ptr@(Ptr !addr) → do
        go gen ptr
        unsafePackAddressLen len8 addr
  where
    len8, len64 ∷ Int
    !len8 = fromIntegral n
    !len64 = len8 `div` 8

    go ∷ Gen (PrimState IO) → Ptr Word64 → IO ()
    go !gen !startPtr = loop64 startPtr
      where
        fin64Ptr ∷ Ptr Word64
        !fin64Ptr = startPtr `plusPtr` (len64 * 8)

        loop64 ∷ Ptr Word64 → IO ()
        loop64 !curPtr
            | curPtr < fin64Ptr = do
                !b ← uniform gen ∷ IO Word64
                poke curPtr b
                loop64 $ curPtr `plusPtr` 8
            | otherwise = loop8 $ castPtr curPtr

        fin8Ptr ∷ Ptr Word8
        !fin8Ptr = startPtr `plusPtr` len8

        loop8 ∷ Ptr Word8 → IO ()
        loop8 !curPtr
            | curPtr < fin8Ptr = do
                !b ← uniform gen ∷ IO Word8
                poke curPtr b
                loop8 $ curPtr `plusPtr` 1
            | otherwise = return ()

-- -------------------------------------------------------------------------- --
-- unfoldrN, PrimMonad

data Box m = Box !(State# (PrimState m))

mwcUnfoldr ∷ ∀ m . (PrimMonad m, PrimBase m) ⇒ Natural → m ByteString
mwcUnfoldr n = do
    !gen ← create
    primitive $ go gen
  where
    go
        ∷ Gen (PrimState m)
        → State# (PrimState m)
        → (# State# (PrimState m), ByteString #)
    go !gen !st =
        let !(!b, Just (Box !st')) = unfoldrN (fromIntegral n) (step gen) (Box st)
        in (# st', b #)

    step
        ∷ Gen (PrimState m)
        → Box m
        → Maybe (Word8, Box m)
    step !gen (Box !s) =
        let !(# !s', !b #) = internal (uniform gen ∷ m Word8) s
        in Just (b, Box s')

-- -------------------------------------------------------------------------- --
-- unfoldrN, IO

mwcUnfoldrIO ∷ Natural → IO ByteString
mwcUnfoldrIO n = do
    !gen ← create
    primitive $ go gen
  where
    go
        ∷ Gen (PrimState IO)
        → State# (PrimState IO)
        → (# State# (PrimState IO), ByteString #)
    go !gen !st =
        let !(!b, Just (Box !st')) = unfoldrN (fromIntegral n) (step gen) (Box st)
        in (# st', b #)

    step
        ∷ Gen (PrimState IO)
        → Box IO
        → Maybe (Word8, Box IO)
    step !gen (Box !s) =
        let !(# !s', !b #) = internal (uniform gen ∷ IO Word8) s
        in Just (b, Box s')

