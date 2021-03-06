{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Verifier.SAW.Simulator.Prims
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Simulator.Prims where

import Prelude hiding (sequence, mapM)

import Control.Monad (foldM, liftM)
import qualified Data.Map as Map
import Data.Bits
import Data.Traversable
import qualified Data.Vector as V

import Verifier.SAW.Simulator.Value
import Verifier.SAW.Prim

------------------------------------------------------------
-- Value accessors and constructors

vNat :: Nat -> Value m b w e
vNat n = VNat (fromIntegral n)

natFromValue :: Num a => Value m b w e -> a
natFromValue (VNat n) = fromInteger n
natFromValue _ = error "natFromValue"

natFun'' :: (Monad m, Show e) => String -> (Nat -> m (Value m b w e)) -> Value m b w e
natFun'' s f = strictFun g
  where g (VNat n) = f (fromInteger n)
        g v = fail $ "expected Nat (" ++ s ++ "): " ++ show v

natFun' :: Monad m => String -> (Nat -> m (Value m b w e)) -> Value m b w e
natFun' s f = strictFun g
  where g (VNat n) = f (fromInteger n)
        g _ = fail $ "expected Nat: " ++ s

natFun :: Monad m => (Nat -> m (Value m b w e)) -> Value m b w e
natFun f = strictFun g
  where g (VNat n) = f (fromInteger n)
        g _ = fail "expected Nat"

intFun :: Monad m => String -> (Integer -> m (Value m b w e)) -> Value m b w e
intFun msg f = strictFun g
  where g (VInt i) = f i
        g _ = fail $ "expected Integer "++ msg

toBool :: Show e => Value m b w e -> b
toBool (VBool b) = b
toBool x = error $ unwords ["Verifier.SAW.Simulator.toBool", show x]

toWord :: (Monad m, Show e) => (V.Vector b -> w) -> Value m b w e -> m w
toWord _ (VWord w) = return w
toWord pack (VVector vv) = liftM pack $ V.mapM (liftM toBool . force) vv
toWord _ x = fail $ unwords ["Verifier.SAW.Simulator.toWord", show x]

toBits :: (Monad m, Show e) => (w -> V.Vector b) -> Value m b w e -> m (V.Vector b)
toBits unpack (VWord w) = return (unpack w)
toBits _ (VVector v) = V.mapM (liftM toBool . force) v
toBits _ x = fail $ unwords ["Verifier.SAW.Simulator.toBits", show x]

toVector :: (Monad m, Show e) => (w -> V.Vector b)
         -> Value m b w e -> V.Vector (Thunk m b w e)
toVector _ (VVector v) = v
toVector unpack (VWord w) = fmap (ready . VBool) (unpack w)
toVector _ x = fail $ unwords ["Verifier.SAW.Simulator.toVector", show x]

wordFun :: (Monad m, Show e) => (V.Vector b -> w) -> (w -> m (Value m b w e)) -> Value m b w e
wordFun pack f = strictFun (\x -> toWord pack x >>= f)

bitsFun :: (Monad m, Show e) => (w -> V.Vector b)
        -> (V.Vector b -> m (Value m b w e)) -> Value m b w e
bitsFun unpack f = strictFun (\x -> toBits unpack x >>= f)

vectorFun :: (Monad m, Show e) => (w -> V.Vector b)
          -> (V.Vector (Thunk m b w e) -> m (Value m b w e)) -> Value m b w e
vectorFun unpack f = strictFun (\x -> f (toVector unpack x))

vecIdx :: String -> V.Vector a -> Int -> a
vecIdx name v n =
  case (V.!?) v n of
    Just a -> a
    Nothing -> error $ "vecIdx ("  ++ name ++ ") out of bounds (" ++
                       show n ++ " out of " ++ show (V.length v) ++ ")"

------------------------------------------------------------
-- Utility functions

-- @selectV mux maxValue valueFn v@ treats the vector @v@ as an
-- index, represented as a big-endian list of bits. It does a binary
-- lookup, using @mux@ as an if-then-else operator. If the index is
-- greater than @maxValue@, then it returns @valueFn maxValue@.
selectV :: (b -> a -> a -> a) -> Int -> (Int -> a) -> V.Vector b -> a
selectV mux maxValue valueFn v = impl len 0
  where
    len = V.length v
    impl _ x | x >= maxValue || x < 0 = valueFn maxValue
    impl 0 x = valueFn x
    impl i x = mux (vecIdx "selectV" v (len - i)) (impl j (x `setBit` j)) (impl j x) where j = i - 1

------------------------------------------------------------
-- Values for common primitives

-- bvToNat :: (n :: Nat) -> bitvector n -> Nat;
bvToNatOp :: Monad m => Value m b w e
bvToNatOp = constFun $ pureFun VToNat

-- coerce :: (a b :: sort 0) -> Eq (sort 0) a b -> a -> b;
coerceOp :: Monad m => Value m b w e
coerceOp =
  constFun $
  constFun $
  constFun $
  VFun force

-- Succ :: Nat -> Nat;
succOp :: Monad m => Value m b w e
succOp =
  natFun' "Succ" $ \n -> return $
  vNat (succ n)

-- addNat :: Nat -> Nat -> Nat;
addNatOp :: Monad m => Value m b w e
addNatOp =
  natFun' "addNat1" $ \m -> return $
  natFun' "addNat2" $ \n -> return $
  vNat (m + n)

-- subNat :: Nat -> Nat -> Nat;
subNatOp :: Monad m => Value m b w e
subNatOp =
  natFun' "subNat1" $ \m -> return $
  natFun' "subNat2" $ \n -> return $
  vNat (if m < n then 0 else m - n)

-- mulNat :: Nat -> Nat -> Nat;
mulNatOp :: Monad m => Value m b w e
mulNatOp =
  natFun' "mulNat1" $ \m -> return $
  natFun' "mulNat2" $ \n -> return $
  vNat (m * n)

-- minNat :: Nat -> Nat -> Nat;
minNatOp :: Monad m => Value m b w e
minNatOp =
  natFun' "minNat1" $ \m -> return $
  natFun' "minNat2" $ \n -> return $
  vNat (min m n)

-- maxNat :: Nat -> Nat -> Nat;
maxNatOp :: Monad m => Value m b w e
maxNatOp =
  natFun' "maxNat1" $ \m -> return $
  natFun' "maxNat2" $ \n -> return $
  vNat (max m n)

-- equalNat :: Nat -> Nat -> Bool;
equalNat :: Monad m => (Bool -> m b) -> Value m b w e
equalNat lit =
  natFun' "equalNat1" $ \m -> return $
  natFun' "equalNat2" $ \n ->
  lit (m == n) >>= return . VBool

-- equalNat :: Nat -> Nat -> Bool;
ltNat :: Monad m => (Bool -> m b) -> Value m b w e
ltNat lit =
  natFun' "ltNat1" $ \m -> return $
  natFun' "ltNat2" $ \n ->
  lit (m < n) >>= return . VBool

-- divModNat :: Nat -> Nat -> #(Nat, Nat);
divModNatOp :: Monad m => Value m b w e
divModNatOp =
  natFun' "divModNat1" $ \m -> return $
  natFun' "divModNat2" $ \n -> return $
    let (q,r) = divMod m n in
    vTuple [ready $ vNat q, ready $ vNat r]

-- expNat :: Nat -> Nat -> Nat;
expNatOp :: Monad m => Value m b w e
expNatOp =
  natFun' "expNat1" $ \m -> return $
  natFun' "expNat2" $ \n -> return $
  vNat (m ^ n)

-- widthNat :: Nat -> Nat;
widthNatOp :: Monad m => Value m b w e
widthNatOp =
  natFun' "widthNat1" $ \n -> return $
  vNat (widthNat n)

-- natCase :: (p :: Nat -> sort 0) -> p Zero -> ((n :: Nat) -> p (Succ n)) -> (n :: Nat) -> p n;
natCaseOp :: Monad m => Value m b w e
natCaseOp =
  constFun $
  VFun $ \z -> return $
  VFun $ \s -> return $
  natFun' "natCase" $ \n ->
    if n == 0
    then force z
    else do s' <- force s
            apply s' (ready (VNat (fromIntegral n - 1)))

-- gen :: (n :: Nat) -> (a :: sort 0) -> (Nat -> a) -> Vec n a;
genOp :: MonadLazy m => Value m b w e
genOp =
  natFun' "gen1" $ \n -> return $
  constFun $
  strictFun $ \f -> do
    let g i = delay $ apply f (ready (VNat (fromIntegral i)))
    liftM VVector $ V.generateM (fromIntegral n) g

-- zero :: (a :: sort 0) -> a;
zeroOp :: (MonadLazy m, Show e) => (Integer -> m (Value m b w e))
       -> m (Value m b w e) -> Value m b w e -> Value m b w e
zeroOp bvZ boolZ mkStream = strictFun go
  where
    go t =
      case t of
        VPiType _ f -> return $ VFun $ \x -> f x >>= go
        VUnitType -> return VUnit
        VPairType t1 t2 -> do z1 <- delay (go t1)
                              z2 <- delay (go t2)
                              return (VPair z1 z2)
        VRecordType tm -> liftM VRecord $ mapM (delay . go) tm
        VDataType "Prelude.Bool" [] -> boolZ
        VDataType "Prelude.Vec" [VNat n, VDataType "Prelude.Bool" []] -> bvZ n
        VDataType "Prelude.Vec" [VNat n, t'] -> do
          liftM (VVector . V.replicate (fromInteger n)) $ delay (go t')
        VDataType "Prelude.Stream" [t'] -> do
          thunk <- delay (go t')
          applyAll mkStream [ready t', ready (VFun (\_ -> force thunk))]
        _ -> fail $ "zero: invalid type instance: " ++ show t

--unary :: ((n :: Nat) -> bitvector n -> bitvector n)
--       -> (Bool -> Bool)
--       -> (a :: sort 0) -> a -> a;
unaryOp :: (MonadLazy m, Show e) => Value m b w e -> Value m b w e -> Value m b w e
unaryOp mkStream streamGet =
  VFun $ \bvOp' -> return $
  VFun $ \boolOp' -> return $
  let go (VPiType _ f) v =
        return $ VFun $ \x -> do
          y <- apply v x
          u <- f x
          go u y
      go VUnitType VUnit = return VUnit
      go (VPairType t1 t2) (VPair v1 v2) = do
        x1 <- go' t1 v1
        x2 <- go' t2 v2
        return (VPair x1 x2)
      go (VRecordType tm) (VRecord vm)
        | Map.keys tm == Map.keys vm =
          liftM VRecord $ sequence (Map.intersectionWith go' tm vm)
      go (VDataType "Prelude.Vec" [n, VDataType "Prelude.Bool" []]) v = do
        bvOp <- force bvOp'
        applyAll bvOp [ready n, ready v]
      go (VDataType "Prelude.Vec" [_, t']) (VVector vv) =
        liftM VVector $ mapM (go' t') vv
      go (VDataType "Prelude.Bool" []) v = do
        boolOp <- force boolOp'
        apply boolOp (ready v)
      go (VDataType "Prelude.Stream" [t']) v =
        applyAll mkStream [ready t', ready (VFun f)]
        where
          f n = do
            x <- applyAll streamGet [ready t', ready v, n]
            go t' x
      go t _ =
        fail $ "unary: invalid type instance: " ++ show t

      go' t thunk = delay (force thunk >>= go t)

  in pureFun $ \t -> strictFun $ \v -> go t v

--binary :: ((n :: Nat) -> bitvector n -> bitvector n -> bitvector n)
--       -> (Bool -> Bool -> Bool)
--       -> (a :: sort 0) -> a -> a -> a;
binaryOp :: (MonadLazy m, Show e) => Value m b w e -> Value m b w e -> Value m b w e
binaryOp mkStream streamGet =
  VFun $ \bvOp' -> return $
  VFun $ \boolOp' -> return $
  let bin (VPiType _ f) v1 v2 =
        return $ VFun $ \x -> do
          y1 <- apply v1 x
          y2 <- apply v2 x
          u <- f x
          bin u y1 y2
      bin VUnitType VUnit VUnit = return VUnit
      bin (VPairType t1 t2) (VPair x1 x2) (VPair y1 y2) = do
        z1 <- bin' t1 x1 y1
        z2 <- bin' t2 x2 y2
        return (VPair z1 z2)
      bin (VRecordType tm) (VRecord vm1) (VRecord vm2)
        | Map.keys tm == Map.keys vm1 && Map.keys tm == Map.keys vm2 =
          liftM VRecord $ sequence
          (Map.intersectionWith ($) (Map.intersectionWith bin' tm vm1) vm2)
      bin (VDataType "Prelude.Bool" []) v1 v2 = do
        boolOp <- force boolOp'
        applyAll boolOp [ready v1, ready v2]
      bin (VDataType "Prelude.Vec" [n, VDataType "Prelude.Bool" []]) v1 v2 = do
        bvOp <- force bvOp'
        applyAll bvOp [ready n, ready v1, ready v2]
      bin (VDataType "Prelude.Vec" [_, t']) (VVector vv1) (VVector vv2) =
        liftM VVector $ sequence (V.zipWith (bin' t') vv1 vv2)
      bin (VDataType "Prelude.Stream" [t']) v1 v2 =
        applyAll mkStream [ready t', ready (VFun f)]
        where
          f n = do
            x1 <- applyAll streamGet [ready t', ready v1, n]
            x2 <- applyAll streamGet [ready t', ready v2, n]
            bin t' x1 x2
      bin t _ _ =
        fail $ "binary: invalid type instance: " ++ show t

      bin' t th1 th2 = delay $ do
        v1 <- force th1
        v2 <- force th2
        bin t v1 v2

  in pureFun $ \t -> pureFun $ \v1 -> strictFun $ \v2 -> bin t v1 v2

-- eq :: (a :: sort 0) -> a -> a -> Bool
eqOp :: (MonadLazy m, Show e) => Value m b w e
     -> (Value m b w e -> Value m b w e -> m (Value m b w e))
     -> (Value m b w e -> Value m b w e -> m (Value m b w e))
     -> (Integer -> Value m b w e -> Value m b w e -> m (Value m b w e))
     -> Value m b w e
eqOp trueOp andOp boolOp bvOp =
  pureFun $ \t -> pureFun $ \v1 -> strictFun $ \v2 -> go t v1 v2
  where
    go VUnitType VUnit VUnit = return trueOp
    go (VPairType t1 t2) (VPair x1 x2) (VPair y1 y2) = do
      b1 <- go' t1 x1 y1
      b2 <- go' t2 x2 y2
      andOp b1 b2
    go (VRecordType tm) (VRecord vm1) (VRecord vm2)
      | Map.keys tm == Map.keys vm1 && Map.keys tm == Map.keys vm2 = do
        bs <- sequence $ zipWith3 go' (Map.elems tm) (Map.elems vm1) (Map.elems vm2)
        foldM andOp trueOp bs
    go (VDataType "Prelude.Vec" [VNat n, VDataType "Prelude.Bool" []]) v1 v2 = bvOp n v1 v2
    go (VDataType "Prelude.Vec" [_, t']) (VVector vv1) (VVector vv2) = do
      bs <- sequence $ zipWith (go' t') (V.toList vv1) (V.toList vv2)
      foldM andOp trueOp bs
    go (VDataType "Prelude.Bool" []) v1 v2 = boolOp v1 v2
    go t _ _ = fail $ "binary: invalid arguments: " ++ show t

    go' t thunk1 thunk2 = do
      v1 <- force thunk1
      v2 <- force thunk2
      go t v1 v2

-- comparison :: (b :: sort 0)
--            -> ((n :: Nat) -> bitvector n -> bitvector n -> b -> b)
--            -> (Bool -> Bool -> b -> b)
--            -> b
--            -> (a :: sort 0) -> a -> a -> b;
comparisonOp :: (MonadLazy m, Show e) => Value m b w e
comparisonOp =
  constFun $
  pureFun $ \bvOp ->
  pureFun $ \boolOp ->
  let go VUnitType VUnit VUnit k = return k
      go (VPairType t1 t2) (VPair x1 x2) (VPair y1 y2) k = go' t1 x1 y1 =<< go' t2 x2 y2 k
      go (VRecordType tm) (VRecord vm1) (VRecord vm2) k
        | Map.keys tm == Map.keys vm1 && Map.keys tm == Map.keys vm2 =
          foldr (=<<) (return k) (zipWith3 go' (Map.elems tm) (Map.elems vm1) (Map.elems vm2))
      go (VDataType "Prelude.Bool" []) v1 v2 k = do
        applyAll boolOp [ready v1, ready v2, ready k]
      go (VDataType "Prelude.Vec" [n, VDataType "Prelude.Bool" []]) v1 v2 k = do
        applyAll bvOp [ready n, ready v1, ready v2, ready k]
      go (VDataType "Prelude.Vec" [_, t']) (VVector vv1) (VVector vv2) k = do
        foldr (=<<) (return k) (zipWith (go' t') (V.toList vv1) (V.toList vv2))
      go t _ _ _ = fail $ "comparison: invalid arguments: " ++ show t

      go' t thunk1 thunk2 k = do
        v1 <- force thunk1
        v2 <- force thunk2
        go t v1 v2 k

  in pureFun $ \k -> pureFun $ \t -> pureFun $ \v1 -> strictFun $ \v2 -> go t v1 v2 k

-- at :: (n :: Nat) -> (a :: sort 0) -> Vec n a -> Nat -> a;
atOp :: (Monad m, Show e) => (w -> V.Vector b) -> (w -> Int -> b)
     -> (b -> m (Value m b w e) -> m (Value m b w e) -> m (Value m b w e))
     -> Value m b w e
atOp unpack bvOp mux =
  natFun $ \n -> return $
  constFun $
  strictFun $ \x -> return $
  strictFun $ \idx ->
    case idx of
      VNat i ->
        case x of
          VVector xv -> force (vecIdx "atOp[Nat]" xv (fromIntegral i))
          VWord xw -> return $ VBool $ bvOp xw (fromIntegral i)
          _ -> fail "atOp: expected vector"
      VToNat i -> do
        iv <- toBits unpack i
        case x of
          VVector xv ->
            selectV mux (fromIntegral n - 1) (force . vecIdx "atOp[ToNat]" xv) iv
          VWord xw ->
            selectV mux (fromIntegral n - 1) (return . VBool . bvOp xw) iv
          _ -> fail "atOp: expected vector"
      _ -> fail $ "atOp: expected Nat, got " ++ show idx

-- upd :: (n :: Nat) -> (a :: sort 0) -> Vec n a -> Nat -> a -> Vec n a;
updOp :: (MonadLazy m, Show e) => (w -> V.Vector b)
      -> (w -> w -> m b) -> (Int -> Integer -> w) -> (w -> Int)
      -> (b -> m (Value m b w e) -> m (Value m b w e) -> m (Value m b w e))
      -> Value m b w e
updOp unpack eq lit bitsize mux =
  natFun $ \n -> return $
  constFun $
  vectorFun unpack $ \xv -> return $
  strictFun $ \idx -> return $
  VFun $ \y ->
    case idx of
      VNat i -> return (VVector (xv V.// [(fromIntegral i, y)]))
      VToNat (VWord w) -> do
        let f i = do b <- eq w (lit (bitsize w) (toInteger i))
                     delay (mux b (force y) (force (vecIdx "updOp" xv i)))
        yv <- V.generateM (V.length xv) f
        return (VVector yv)
      VToNat val -> do
        let update i = return (VVector (xv V.// [(i, y)]))
        iv <- toBits unpack val
        selectV mux (fromIntegral n - 1) update iv
      _ -> fail $ "updOp: expected Nat, got " ++ show idx



-- primitive EmptyVec :: (a :: sort 0) -> Vec 0 a;
emptyVec :: Monad m => Value m b w e
emptyVec = constFun $ VVector V.empty


-- append :: (m n :: Nat) -> (a :: sort 0) -> Vec m a -> Vec n a -> Vec (addNat m n) a;
appendOp :: Monad m => (w -> V.Vector b) -> (w -> w -> w) -> Value m b w e
appendOp unpack app =
  constFun $
  constFun $
  constFun $
  strictFun $ \xs -> return $
  strictFun $ \ys -> return $
  appV unpack app xs ys

appV :: Monad m => (w -> V.Vector b) -> (w -> w -> w)
     -> Value m b w e -> Value m b w e -> Value m b w e
appV unpack app xs ys =
  case (xs, ys) of
    (VVector xv, _) | V.null xv -> ys
    (_, VVector yv) | V.null yv -> xs
    (VVector xv, VVector yv) -> VVector ((V.++) xv yv)
    (VVector xv, VWord yw) -> VVector ((V.++) xv (fmap (ready . VBool) (unpack yw)))
    (VWord xw, VVector yv) -> VVector ((V.++) (fmap (ready . VBool) (unpack xw)) yv)
    (VWord xw, VWord yw) -> VWord (app xw yw)
    _ -> error "Verifier.SAW.Simulator.Prims.appendOp"

-- join  :: (m n :: Nat) -> (a :: sort 0) -> Vec m (Vec n a) -> Vec (mulNat m n) a;
joinOp :: Monad m => (w -> V.Vector b) -> (w -> w -> w) -> Value m b w e
joinOp unpack app =
  constFun $
  constFun $
  constFun $
  strictFun $ \x ->
  case x of
    VVector xv -> do
      vv <- V.mapM force xv
      return (V.foldr (appV unpack app) (VVector V.empty) vv)
    _ -> error "Verifier.SAW.Simulator.Prims.joinOp"


intBinOp :: Monad m => String -> (Integer -> Integer -> Integer) -> Value m b w e
intBinOp nm f =
  intFun (nm++" x") $ \x -> return $
  intFun (nm++" y") $ \y -> return $
    VInt (f x y)

intBinCmp :: Monad m => String -> (Integer -> Integer -> Bool) -> (Bool -> b) -> Value m b w e
intBinCmp nm f boolLit =
  intFun (nm++" x") $ \x -> return $
  intFun (nm++" y") $ \y -> return $
    VBool $ boolLit (f x y)

-- primitive intAdd :: Integer -> Integer -> Integer;
intAddOp :: Monad m => Value m b w e
intAddOp = intBinOp "intAdd" (+)

-- primitive intSub :: Integer -> Integer -> Integer;
intSubOp :: Monad m => Value m b w e
intSubOp = intBinOp "intSub" (-)

-- primitive intMul :: Integer -> Integer -> Integer;
intMulOp :: Monad m => Value m b w e
intMulOp = intBinOp "intMul" (*)

-- primitive intDiv :: Integer -> Integer -> Integer;
intDivOp :: Monad m => Value m b w e
intDivOp = intBinOp "intDiv" div

-- primitive intMod :: Integer -> Integer -> Integer;
intModOp :: Monad m => Value m b w e
intModOp = intBinOp "intMod" mod

-- primitive intMin :: Integer -> Integer -> Integer;
intMinOp :: Monad m => Value m b w e
intMinOp = intBinOp "intMin" min

-- primitive intMax :: Integer -> Integer -> Integer;
intMaxOp :: Monad m => Value m b w e
intMaxOp = intBinOp "intMax" max

-- primitive intNeg :: Integer -> Integer;
intNegOp :: Monad m => Value m b w e
intNegOp = intFun "intNeg x" $ \x -> return $ VInt (negate x)

-- primitive intEq  :: Integer -> Integer -> Bool;
intEqOp :: Monad m => (Bool -> b) -> Value m b w e
intEqOp = intBinCmp "intEq" (==)

-- primitive intLe  :: Integer -> Integer -> Bool;
intLeOp :: Monad m => (Bool -> b) -> Value m b w e
intLeOp = intBinCmp "intLe" (<=)

-- primitive intLt  :: Integer -> Integer -> Bool;
intLtOp :: Monad m => (Bool -> b) -> Value m b w e
intLtOp = intBinCmp "intLt" (<)

-- primitive intToNat :: Integer -> Nat;
intToNatOp :: Monad m => Value m b w e
intToNatOp =
  intFun "intToNat" $ \x -> return $!
    if x >= 0 then VNat x else VNat 0

--primitive natToInt :: Nat -> Integer;
natToIntOp :: Monad m => Value m b w e
natToIntOp = natFun' "natToInt" $ \x -> return $ VNat (fromIntegral x)
