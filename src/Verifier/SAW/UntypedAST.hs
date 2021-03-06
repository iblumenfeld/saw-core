{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}

{- |
Module      : Verifier.SAW.UntypedAST
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.UntypedAST
  ( Module(..)
  , ModuleName, mkModuleName
  , Import(..)
  , Decl(..)
  , DeclQualifier(..)
  , ImportConstraint(..)
  , ImportName(..)
  , CtorDecl(..)
  , Term(..)
  , asApp
  , mkTupleValue
  , mkTupleType
  , mkTupleSelector
  , ParamType(..)
  , Pat(..), ppPat
  , mkPTuple
  , SimplePat(..)
  , FieldName
  , Ident, localIdent, asLocalIdent, mkIdent, identModule, setIdentModule
  , Sort, mkSort, sortOf
  , badTerm
  , module Verifier.SAW.Position
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Exception (assert)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Verifier.SAW.Position
import Verifier.SAW.TypedAST
  ( ModuleName, mkModuleName
  , Sort, mkSort, sortOf
  , FieldName
  , isIdent
  , Prec(..), ppAppParens
  , commaSepList, semiTermList
  )

-- | Identifiers represent a compound name (e.g., Prelude.add).
data Ident = LocalIdent String
           | Ident ModuleName String
  deriving (Eq, Ord)

instance Show Ident where
  show (LocalIdent s) = s
  show (Ident m s) = shows m ('.':s)

mkIdent :: Maybe ModuleName -> String -> Ident
mkIdent mnm nm = assert (isIdent nm) $
  case mnm of
    Nothing -> LocalIdent nm
    Just m -> Ident m nm

localIdent :: String -> Ident
localIdent = mkIdent Nothing

asLocalIdent :: Ident -> Maybe String
asLocalIdent (LocalIdent s) = Just s
asLocalIdent _ = Nothing

identModule :: Ident -> Maybe ModuleName
identModule (Ident m _) = Just m
identModule (LocalIdent _) = Nothing

setIdentModule :: Ident -> ModuleName -> Ident
setIdentModule (LocalIdent nm) m = Ident m nm
setIdentModule (Ident _ nm) m = Ident m nm

-- | Parameter type
data ParamType
  = NormalParam
  | ImplicitParam
  | InstanceParam
  | ProofParam
  deriving (Eq, Ord, Show)

data Term
  = Var (PosPair Ident)
  | Unused (PosPair String)
    -- | References a constructor.
  | Con (PosPair Ident)
  | Sort Pos Sort
  | Lambda Pos [(ParamType,[Pat],Term)] Term
  | App Term ParamType Term
    -- | Pi is the type of a lambda expression.
--  | Pi ParamType [Pat] Term Pos Term
  | Pi ParamType [SimplePat] Term Pos Term
    -- | Tuple expressions and their type.
  | UnitValue Pos
  | UnitType Pos
  | PairValue Pos Term Term
  | PairType Pos Term Term
  | PairLeft Pos Term
  | PairRight Pos Term
    -- | A record value.
  | RecordValue Pos [(PosPair FieldName, Term)]
    -- | The value stored in a record.
  | RecordSelector Term (PosPair FieldName)
    -- | Type of a record value.
  | RecordType  Pos [(PosPair FieldName, Term)]
    -- | Identifies a type constraint on the term.
  | TypeConstraint Term Pos Term
    -- | Arguments to an array constructor.
  | Paren Pos Term
  | LetTerm Pos [Decl] Term
  | NatLit Pos Integer
  | StringLit Pos String
    -- | Vector literal.
  | VecLit Pos [Term]
  | BadTerm Pos
 deriving (Show)

-- | A pattern used for matching a variable.
data SimplePat
  = PVar (PosPair String)
  | PUnused (PosPair String)
  deriving (Eq, Ord, Show)

-- | A pattern used for matching a variable.
data Pat
  = PSimple SimplePat
  | PUnit Pos
  | PPair Pos Pat Pat
  | PRecord Pos [(PosPair FieldName, Pat)]
  | PCtor (PosPair Ident) [Pat]
  deriving (Eq, Ord, Show)

mkPTuple :: Pos -> [Pat] -> Pat
mkPTuple p = foldr (PPair p) (PUnit p)

asPTuple :: Pat -> Maybe [Pat]
asPTuple (PUnit _)     = Just []
asPTuple (PPair _ x y) = (x :) <$> asPTuple y
asPTuple _             = Nothing

ppPat :: Prec -> Pat -> Doc
ppPat _ (asPTuple -> Just l) = parens $ commaSepList (ppPat PrecNone <$> l)
ppPat _ (PSimple (PVar pnm)) = text (val pnm)
ppPat _ (PSimple (PUnused pnm)) = text (val pnm)
ppPat _ (PUnit _) = text "()"
ppPat _ (PPair _ x y) = parens $ ppPat PrecNone x <+> text "#" <+> ppPat PrecNone y
ppPat _ (PRecord _ fl) = braces $ semiTermList (ppFld <$> fl)
  where ppFld (fld,v) = text (val fld) <+> equals <+> ppPat PrecNone v
ppPat prec (PCtor pnm l) = ppAppParens prec $
  hsep (text (show (val pnm)) : fmap (ppPat PrecArg) l)

instance Positioned Term where
  pos t =
    case t of
      Var i                -> pos i
      Unused i             -> pos i
      Con i                -> pos i
      Sort p _             -> p
      Lambda p _ _         -> p
      App x _ _            -> pos x
      Pi _ _ _ p _         -> p
      UnitValue p          -> p
      UnitType p           -> p
      PairValue p _ _      -> p
      PairType p _ _       -> p
      PairLeft p _         -> p
      PairRight p _        -> p
      RecordValue p _      -> p
      RecordSelector _ i   -> pos i
      RecordType p _       -> p
      TypeConstraint _ p _ -> p
      Paren p _            -> p
      LetTerm p _ _        -> p
      NatLit p _           -> p
      StringLit p _        -> p
      VecLit p _           -> p
      BadTerm p            -> p

instance Positioned SimplePat where
  pos pat =
    case pat of
      PVar i      -> pos i
      PUnused i   -> pos i

instance Positioned Pat where
  pos pat =
    case pat of
      PSimple i   -> pos i
      PUnit p     -> p
      PPair p _ _ -> p
      PRecord p _ -> p
      PCtor i _   -> pos i

badTerm :: Pos -> Term
badTerm = BadTerm

-- | Constructor declaration.
data CtorDecl = Ctor (PosPair String) Term
  deriving (Show)

data Module = Module (PosPair ModuleName) [Import] [Decl]

data Import = Import Bool
                     (PosPair ModuleName)
                     (Maybe (PosPair String))
                     (Maybe ImportConstraint)

data DeclQualifier
  = NoQualifier
  | PrimitiveQualifier
  | AxiomQualifier
 deriving (Eq, Show)

-- Data declarations introduce an operator for each constructor, and an operator for the type.
data Decl
   = TypeDecl DeclQualifier [(PosPair String)] Term
   | DataDecl (PosPair String) Term [CtorDecl]
   | PrimDataDecl (PosPair String) Term
   | TermDef (PosPair String) [(ParamType, Pat)] Term
  deriving (Show)

data ImportConstraint
  = SpecificImports [ImportName]
  | HidingImports [ImportName]
 deriving (Eq, Ord, Show)

data ImportName
  = SingleImport (PosPair String)
  | AllImport    (PosPair String)
  | SelectiveImport (PosPair String) [PosPair String]
  deriving (Eq, Ord, Show)

asApp :: Term -> (Term,[Term])
asApp = go []
  where go l (Paren _ t) = go l t
        go l (App t _ u) = go (u:l) t
        go l t = (t,l)

mkTupleValue :: Pos -> [Term] -> Term
mkTupleValue p = foldr (PairValue p) (UnitValue p)

mkTupleType :: Pos -> [Term] -> Term
mkTupleType p = foldr (PairType p) (UnitType p)

mkTupleSelector :: Term -> PosPair Integer -> Term
mkTupleSelector t i =
  case compare (val i) 1 of
    LT -> error "mkTupleSelector: non-positive index"
    EQ -> PairLeft (_pos i) t
    GT -> mkTupleSelector (PairRight (_pos i) t) i{ val = val i - 1 }
