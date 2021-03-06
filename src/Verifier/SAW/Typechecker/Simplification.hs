{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Verifier.SAW.Typechecker.Simplification
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Typechecker.Simplification
  (     -- * Standard prelude names used during typechecking.
    preludeNatIdent
  , preludeZeroIdent
  , preludeSuccIdent
  , preludeVecIdent
  , preludeFloatIdent
  , preludeDoubleIdent
  , tryMatchPat
  , Subst
  , extendPatContext
  , reduce
  , reduceToPiExpr
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
import Data.Traversable
#endif
import Control.Arrow (second)
import Control.Lens
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.State (StateT(..), modify)
import Control.Monad.Trans
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Vector as V
import Data.Vector (Vector)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Verifier.SAW.Position
import Verifier.SAW.Prelude.Constants
import Verifier.SAW.Typechecker.Context
import Verifier.SAW.Typechecker.Monad
import Verifier.SAW.TypedAST

extendPatContext :: TermContext s -> TCPat -> TermContext s
extendPatContext tc0 pat = V.foldl (flip $ uncurry consBoundVar) tc0 (patBoundVars pat)

type Subst = Vector TCTerm

type Matcher s = StateT (Map Int TCTerm) (ExceptT String (TC s))

runMatcher :: Matcher s a -> TC s (Maybe (a, Subst))
runMatcher m = fmap finish $ runExceptT $ runStateT m Map.empty
  where finish Left{} = Nothing
        finish (Right p) = Just (second (V.fromList . Map.elems) p)

-- | Attempt to match term against a pat, returns reduced term that matches.
attemptMatch :: TermContext s -> TCPat -> TCTerm -> Matcher s TCTerm
attemptMatch _ (TCPVar _ (i,_)) t = t <$ modify (Map.insert i t)
attemptMatch _ TCPUnused{} t = return t
attemptMatch tc (TCPatF pf) t = do
  let go = attemptMatch tc
  rt <- lift $ lift $ reduce tc t
  case (pf, rt) of
    (UPUnit, TCF UnitValue) -> pure $ TCF UnitValue
    (UPPair p1 p2, TCF (PairValue t1 t2)) ->
      TCF <$> (PairValue <$> go p1 t1 <*> go p2 t2)
    (UPRecord pm, TCF (RecordValue tm)) | Map.keys pm == Map.keys tm ->
      TCF . RecordValue <$> sequenceA (Map.intersectionWith go pm tm)
    (UPCtor cp pl, TCF (CtorApp ct tl)) | cp == ct ->
      TCF . CtorApp ct <$> sequenceA (zipWith go pl tl)

    (UPCtor c [], TCF (NatLit 0)) | c == preludeZeroIdent ->
      return rt
    (UPCtor c [p], TCF (NatLit n))
      | c == preludeSuccIdent && n > 0 ->
      go p (TCF (NatLit (n-1)))

    _ -> lift $ throwE "Pattern match failed."

-- | Match untyped term against pattern, returning variables in reverse order.
-- so that last-bound variable is first.  Also returns the term after it was matched.
-- This may differ to the input term due to the use of reduction during matching.
-- All terms are relative to the initial context.
tryMatchPat :: TermContext s
            -> TCPat -> TCTerm -> TC s (Maybe (Subst, TCTerm))
tryMatchPat tc pat t = do
    fmap (fmap finish) $ runMatcher (attemptMatch tc pat t)
  where finish (r,args) = (args, r)

-- | Match untyped term against pattern, returning variables in reverse order.
-- so that last-bound variable is first.  Also returns the term after it was matched.
-- This may differ to the input term due to the use of reduction during matching.
tryMatchPatList :: TermContext s
                -> [TCPat]
                -> [TCTerm]
                -> TC s (Maybe ( TermContext s
                               , Subst
                               , [TCTerm]))
tryMatchPatList tc pats terms =
    fmap (fmap finish) $ runMatcher (go pats terms)
  where go (pat:pl) (term:tl) =
          attemptMatch tc pat term >> go pl tl
        go [] tl = return tl
        go _ [] = fail "Insufficient number of terms"
        finish (tl,args) = (tc', args, tl)
          where bindings = patBoundVarsOf folded pats
                tc' = V.foldl (flip $ uncurry consBoundVar) tc bindings

reduce :: TermContext s -> TCTerm -> TC s TCTerm
reduce tc t =
  case tcAsApp t of
    (TCF (RecordSelector r f), a) -> do
      r' <- reduce tc r
      case r' of
        TCF (RecordValue m) ->
          case Map.lookup f m of
            Just v -> reduce tc (tcMkApp v a)
            Nothing -> fail "Missing record field in reduce"
        _ -> return t
    (TCLambda pat _ rhs, a0:al) -> do
      r <- tryMatchPat tc pat a0
      case r of
        Nothing -> return t
        Just (sub,_) -> reduce tc (tcMkApp t' al)
          where tc' = extendPatContext tc pat
                t' = tcApply tc (tc',rhs) (tc,sub)
    (TCF (GlobalDef g), al) -> do
        -- Get global equations.
        m <- tryEval (globalDefEqns g tc)
        case m of
          Nothing -> return t
          Just eqs -> procEqs eqs
      where procEqs [] = return t
            procEqs (DefEqnGen pats rhs:eql) = do
              m <- tryMatchPatList tc pats al
              case m of
                Nothing -> procEqs eql
                Just (tc', sub, rest) -> reduce tc (tcMkApp g' rest)
                  where g' = tcApply tc (tc',rhs) (tc,V.reverse sub)
    _ -> return t

-- | Attempt to reduce a term to a  pi expression, returning the pattern, type
-- of the pattern and the right-hand side.
-- Reports error if htis fails.
reduceToPiExpr :: TermContext s -> Pos -> TCTerm -> TC s (TCPat, TCTerm, TCTerm)
reduceToPiExpr tc p tp = do
  rtp <- reduce tc tp
  case rtp of
    TCPi pat l r -> return (pat,l,r)
    _ -> tcFailD p $ text "Unexpected argument to term with type:" <$$>
                         nest 2 (ppTCTerm tc PrecNone rtp)
