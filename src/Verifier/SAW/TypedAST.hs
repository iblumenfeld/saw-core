{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE RankNTypes #-}

{-# LANGUAGE ViewPatterns #-}
module Verifier.SAW.TypedAST
 ( -- * Module operations.
   Module
 , emptyModule
 , ModuleName, mkModuleName
 , moduleName
 , ModuleDecl(..)
 , moduleDecls
 , TypedDataType
 , moduleDataTypes
 , findDataType
 , TypedCtor
 , moduleCtors
 , findCtor
 , findExportedCtor
 , TypedDef
 , TypedDefEqn
 , moduleDefs
 , findDef
 , findExportedDef
 , insDataType
 , insDef
   -- * Data types and defintiions.
 , DataType(..)
 , Ctor(..)
 , Def(..)
 , LocalDef(..)
 , localVarNames
 , DefEqn(..)
 , Pat(..)
 , patBoundVarCount
   -- * Terms and associated operations.
 , Term(..)
 , incVars
 , piArgCount
 , TermF(..)
 , FlatTermF(..)
 , zipWithFlatTermF
 , ppTerm
 , ppFlatTermF
 , ppRecordF
   -- * Primitive types.
 , Sort, mkSort, sortOf, maxSort
 , Ident(identModule, identName), mkIdent
 , isIdent
 , ppIdent
 , DeBruijnIndex
 , FieldName
 , instantiateVarList
   -- * Utility functions
 , Prec
 , commaSepList
 , semiTermList
 , ppParens
 , emptyLocalVarDoc
 ) where

import Control.Applicative hiding (empty)
import Control.Exception (assert)
import Control.Monad.Identity (runIdentity)
import Data.Char
import Data.Foldable
import Data.List (intercalate)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector (Vector)
import qualified Data.Vector as V
import Text.PrettyPrint.HughesPJ
import Data.Traversable (Traversable, traverse)

import Prelude hiding (all, concatMap, foldr, sum)

import Verifier.SAW.Utils

data ModuleName = ModuleName [String]
  deriving (Eq, Ord)

instance Show ModuleName where
   show (ModuleName s) = intercalate "." (reverse s)

isIdent :: String -> Bool
isIdent (c:l) = isAlpha c && all isIdChar l
isIdent [] = False

isCtor :: String -> Bool
isCtor (c:l) = isUpper c && all isIdChar l
isCtor [] = False

-- | Returns true if character can appear in identifier.
isIdChar :: Char -> Bool
isIdChar c = isAlphaNum c || (c == '_') || (c == '\'')

-- | Crete a module name given a list of strings with the top-most
-- module name given first.
mkModuleName :: [String] -> ModuleName
mkModuleName [] = error "internal: Unexpected empty module name"
mkModuleName nms = assert (all isCtor nms) $ ModuleName nms

data Ident = Ident { identModule :: ModuleName
                   , identName :: String
                   }
  deriving (Eq, Ord)

instance Show Ident where
  show (Ident m s) = shows m ('.' : s)

mkIdent :: ModuleName -> String -> Ident
mkIdent = Ident

newtype Sort = SortCtor { _sortIndex :: Integer }
  deriving (Eq, Ord)

instance Show Sort where
  showsPrec p (SortCtor i) = showParen (p >= 10) (showString "sort " . shows i)

-- | Create sort for given integer.
mkSort :: Integer -> Sort
mkSort i | 0 <= i = SortCtor i
         | otherwise = error "Negative index given to sort."

-- | Returns sort of the given sort.
sortOf :: Sort -> Sort
sortOf (SortCtor i) = SortCtor (i + 1)

-- | Returns the larger of the two sorts.
maxSort :: Sort -> Sort -> Sort
maxSort (SortCtor x) (SortCtor y) = SortCtor (max x y)

type DeBruijnIndex = Int

type FieldName = String

-- Patterns are used to match equations.
data Pat e = -- | Variable bound by pattern.
             -- Variables may be bound in context in a different order than
             -- a left-to-right traversal.  The DeBruijnIndex indicates the order.
             PVar String DeBruijnIndex e
           | PUnused
           | PTuple [Pat e]
           | PRecord (Map FieldName (Pat e))
             -- An arbitrary term that matches anything, but needs to be later
             -- verified to be equivalent.
           | PCtor Ident [Pat e]
  deriving (Eq,Ord, Show, Functor, Foldable, Traversable)

patBoundVarCount :: Pat e -> DeBruijnIndex
patBoundVarCount p =
  case p of
    PVar{} -> 1
    PCtor _ l -> sumBy patBoundVarCount l
    PTuple l  -> sumBy patBoundVarCount l
    PRecord m -> sumBy patBoundVarCount m
    _ -> 0

patBoundVars :: Pat e -> [String]
patBoundVars p =
  case p of
    PVar s _ _ -> [s]
    PCtor _ l -> concatMap patBoundVars l
    PTuple l -> concatMap patBoundVars l
    PRecord m -> concatMap patBoundVars m
    _ -> []

lift2 :: (a -> b) -> (b -> b -> c) -> a -> a -> c
lift2 f h x y = h (f x) (f y) 

data LocalDef e
   = LocalFnDef String e [DefEqn e]
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

localVarNames :: LocalDef e -> [String]
localVarNames (LocalFnDef nm _ _) = [nm]

-- A Definition contains an identifier, the type of the definition, and a list of equations.
data Def e = Def { defIdent :: Ident
                 , defType :: e
                 , defEqs :: [DefEqn e]
                 }

instance Eq (Def e) where
  (==) = lift2 defIdent (==)

instance Ord (Def e) where
  compare = lift2 defIdent compare  

instance Show (Def e) where
  show = show . defIdent

data DefEqn e
  = DefEqn [Pat e]  -- ^ List of patterns
           e -- ^ Right hand side.
  deriving (Functor, Foldable, Traversable)

instance (Eq e) => Eq (DefEqn e) where
  DefEqn xp xr == DefEqn yp yr = xp == yp && xr == yr

instance (Ord e) => Ord (DefEqn e) where
  compare (DefEqn xp xr) (DefEqn yp yr) = compare (xp,xr) (yp,yr)

instance (Show e) => Show (DefEqn e) where
  showsPrec p t = showParen (p >= 10) $ ("DefEqn "++) . showsPrec 10 p . showsPrec 10 t

data Ctor n tp = Ctor { ctorName :: !n
                        -- | The type of the constructor (should contain no free variables).
                      , ctorType :: tp
                      }
  deriving (Functor, Foldable, Traversable)

instance Eq n => Eq (Ctor n tp) where
  (==) = lift2 ctorName (==)

instance Ord n => Ord (Ctor n tp) where
  compare = lift2 ctorName compare

instance Show n => Show (Ctor n tp) where
  show = show . ctorName

ppCtor :: TermPrinter e -> Ctor Ident e -> Doc
ppCtor f c = ppIdent (ctorName c) <+> doublecolon <+> tp
  where lcls = emptyLocalVarDoc
        tp = f lcls 1 (ctorType c)

data DataType n t = DataType { dtName :: n
                             , dtType :: t
                             , dtCtors :: [Ctor n t]
                             }
  deriving (Functor, Foldable, Traversable)

instance Eq n => Eq (DataType n t) where
  (==) = lift2 dtName (==)

instance Ord n => Ord (DataType n t) where
  compare = lift2 dtName compare

instance Show n => Show (DataType n t) where
  show = show . dtName

ppDataType :: TermPrinter e -> DataType Ident e -> Doc
ppDataType f dt = text "data" <+> tc <+> text "where" <+> lbrace $$
                    nest 4 (vcat (ppc <$> dtCtors dt)) $$
                    nest 2 rbrace
  where lcls = emptyLocalVarDoc
        sym = ppIdent (dtName dt)
        tc = ppTypeConstraint f lcls sym (dtType dt)
        ppc c = ppCtor f c <> semi

data FlatTermF e
  = GlobalDef Ident  -- ^ Global variables are referenced by label.

  | App !e !e

    -- Tuples may be 0 or 2+ elements. 
    -- A tuple of a single element is not allowed in well-formed expressions.
  | TupleValue [e]
  | TupleType [e]
  | TupleSelector e Int

  | RecordValue (Map FieldName e)
  | RecordSelector e FieldName
  | RecordType (Map FieldName e)

  | CtorApp Ident [e]
  | DataTypeApp Ident [e]

  | Sort Sort

    -- Primitive builtin values
  | NatLit Integer
    -- | Array value includes type of elements followed by elements.
  | ArrayValue e (Vector e)
  deriving (Eq, Ord, Functor, Foldable, Traversable)

zipWithFlatTermF :: (x -> y -> z) -> FlatTermF x -> FlatTermF y -> Maybe (FlatTermF z)
zipWithFlatTermF f = go
  where go (GlobalDef x) (GlobalDef y) | x == y = Just $ GlobalDef x
        go (App fx vx) (App fy vy) = Just $ App (f fx fy) (f vx vy)

        go (TupleValue lx) (TupleValue ly)
          | length lx == length ly = Just $ TupleValue (zipWith f lx ly)
        go (TupleType lx) (TupleType ly)
          | length lx == length ly = Just $ TupleType (zipWith f lx ly)

        go (RecordValue mx) (RecordValue my)
          | Map.keys mx == Map.keys my = 
              Just $ RecordValue $ Map.intersectionWith f mx my 
        go (RecordSelector x fx) (RecordSelector y fy)
          | fx == fy = Just $ RecordSelector (f x y) fx
        go (RecordType mx) (RecordType my)
          | Map.keys mx == Map.keys my = 
              Just $ RecordType (Map.intersectionWith f mx my) 

        go (CtorApp cx lx) (CtorApp cy ly)
          | cx == cy = Just $ CtorApp cx (zipWith f lx ly)
        go (DataTypeApp dx lx) (DataTypeApp dy ly)
          | dx == dy = Just $ DataTypeApp dx (zipWith f lx ly)
        go (Sort sx) (Sort sy) | sx == sy = Just (Sort sx)
        go (NatLit ix) (NatLit iy) | ix == iy = Just (NatLit ix)
        go (ArrayValue tx vx) (ArrayValue ty vy)
          | V.length vx == V.length vy = Just $ ArrayValue (f tx ty) (V.zipWith f vx vy)

        go _ _ = Nothing

data TermF e
    = FTermF !(FlatTermF e)  -- ^ Global variables are referenced by label.
    | Lambda !(Pat e) !e !e
    | Pi !String !e !e
       -- | List of bindings and the let expression itself.
      -- Let expressions introduce variables for each identifier.
    | Let [LocalDef e] !e
      -- | Local variables are referenced by deBruijn index.
      -- The type of the var is in the context of when the variable was bound.
    | LocalVar !DeBruijnIndex !e
      -- | @EqType x y@ is a type representing the equality proposition @x = y@
  deriving (Eq, Ord, Functor, Foldable, Traversable)

ppIdent :: Ident -> Doc
ppIdent i = text (show i)

doublecolon :: Doc
doublecolon = colon <> colon

ppTypeConstraint :: TermPrinter e -> LocalVarDoc -> Doc -> e -> Doc
ppTypeConstraint f lcls sym tp = sym <+> doublecolon <+> f lcls 1 tp

ppDef :: LocalVarDoc -> Def Term -> Doc
ppDef lcls d = vcat (tpd : (ppDefEqn ppTerm lcls sym <$> defEqs d))
  where sym = ppIdent (defIdent d)
        tpd = ppTypeConstraint ppTerm lcls sym (defType d)

ppLocalDef :: TermPrinter e -> LocalVarDoc -> LocalDef e -> Doc
ppLocalDef f lcls (LocalFnDef nm tp eqs) = tpd $$ vcat (ppDefEqn f lcls sym <$> eqs)
  where sym = text nm
        tpd = sym <+> doublecolon <+> f lcls 1 tp

ppDefEqn :: TermPrinter e -> LocalVarDoc -> Doc -> DefEqn e -> Doc
ppDefEqn f lcls sym (DefEqn pats rhs) = lhs <+> equals <+> f lcls' 1 rhs
  where lcls' = foldl' consBinding lcls (concatMap patBoundVars pats) 
        lhs = sym <+> hsep (ppPat f lcls' 10 <$> pats)

-- | Print a list of items separated by semicolons
semiTermList :: [Doc] -> Doc
semiTermList = hsep . fmap (<> semi)

type Prec = Int

-- | Add parenthesis around a document if condition is true.
ppParens :: Bool -> Doc -> Doc
ppParens True  d = parens d
ppParens False d = d

ppPat :: TermPrinter e -> TermPrinter (Pat e)
ppPat f lcls p pat = 
  case pat of
    PVar i _ _ -> text i
    PUnused{} -> char '_'
    PCtor c pl -> ppParens (p >= 10) $
      ppIdent c <+> hsep (ppPat f lcls 10 <$> pl)
    PTuple pl -> parens $ commaSepList $ ppPat f lcls 1 <$> pl
    PRecord m -> braces $ semiTermList $ ppFld <$> Map.toList m
      where ppFld (fld,v) = text fld <+> equals <+> ppPat f lcls 1 v

commaSepList :: [Doc] -> Doc
commaSepList [] = empty
commaSepList [d] = d
commaSepList (d:l) = d <> comma <+> commaSepList l

data LocalVarDoc = LVD { docMap :: !(Map DeBruijnIndex Doc)
                       , docLvl :: !DeBruijnIndex
                       , docUsedMap :: Map String DeBruijnIndex
                       }

emptyLocalVarDoc :: LocalVarDoc
emptyLocalVarDoc = LVD { docMap = Map.empty
                       , docLvl = 0
                       , docUsedMap = Map.empty
                       }

consBinding :: LocalVarDoc -> String -> LocalVarDoc
consBinding lvd i = LVD { docMap = Map.insert lvl (text i) m          
                        , docLvl = lvl + 1
                        , docUsedMap = Map.insert i lvl (docUsedMap lvd)
                        }
 where lvl = docLvl lvd
       m = case Map.lookup i (docUsedMap lvd) of
             Just pl -> Map.delete pl (docMap lvd)
             Nothing -> docMap lvd

lookupDoc :: LocalVarDoc -> DeBruijnIndex -> Doc
lookupDoc lvd i =
  let lvl = docLvl lvd - i - 1
   in case Map.lookup lvl (docMap lvd) of
        Just d -> d
        Nothing -> char '!' <> integer (toInteger (i - docLvl lvd))

type TermPrinter e = LocalVarDoc -> Prec -> e -> Doc

{-
ppPi :: TermPrinter e -> TermPrinter r -> TermPrinter (Pat e, e, r)
ppPi ftp frhs lcls p (pat,tp,rhs) = 
    ppParens (p >= 2) $ lhs <+> text "->" <+> frhs lcls' 1 rhs
  where lcls' = foldl' consBinding lcls (patBoundVars pat)
        lhs = case pat of
                PUnused -> ftp lcls 2 tp
                _ -> parens (ppPat ftp lcls' 1 pat <> doublecolon <> ftp lcls 1 tp)
-}

ppPi :: TermPrinter e -> TermPrinter r -> TermPrinter (String, e, r)
ppPi ftp frhs lcls p (i,tp,rhs) = 
    ppParens (p >= 2) $ lhs <+> text "->" <+> frhs lcls' 1 rhs
  where lcls' = consBinding lcls i
        lhs | i == "_"  = ftp lcls 2 tp
            | otherwise = parens (text i <> doublecolon <> ftp lcls 1 tp)

ppRecordF :: Applicative f => (t -> f Doc) -> Map String t -> f Doc
ppRecordF pp m = braces . semiTermList <$> traverse ppFld (Map.toList m)
  where ppFld (fld,v) = (text fld <+> equals <+>) <$> pp v

ppFlatTermF :: Applicative f => (Prec -> t -> f Doc) -> Prec -> FlatTermF t -> f Doc
ppFlatTermF pp prec tf =
  case tf of
    GlobalDef i -> pure $ ppIdent i
    App l r -> ppParens (prec >= 10) <$> liftA2 (<+>) (pp 10 l) (pp 10 r)
    TupleValue l -> parens . commaSepList <$> traverse (pp 1) l
    TupleType l -> (char '#' <>) . parens . commaSepList <$> traverse (pp 1) l
    TupleSelector t i -> ppParens (prec >= 10) . (<> (char '.' <> int i)) <$> pp 11 t
    RecordValue m -> ppRecordF (pp 1) m
    RecordSelector t f -> ppParens (prec >= 10) . (<> (char '.' <> text f)) <$> pp 11 t
    RecordType m -> (char '#' <>) <$> ppRecordF (pp 1) m
    CtorApp c l
      | null l -> pure (ppIdent c)
      | otherwise -> ppParens (prec >= 10) . hsep . (ppIdent c :) <$> traverse (pp 10) l
    DataTypeApp dt l 
      | null l -> pure (ppIdent dt)
      | otherwise -> ppParens (prec >= 10) . hsep . (ppIdent dt :) <$> traverse (pp 10) l
    Sort s -> pure $ text (show s)
    NatLit i -> pure $ integer i
    ArrayValue _ vl -> brackets . commaSepList <$> traverse (pp 1) (V.toList vl)

newtype Term = Term (TermF Term)
  deriving (Eq)

asApp :: Term -> (Term, [Term])
asApp = go []
  where go l (Term (FTermF (App t u))) = go (u:l) t
        go l t = (t,l)

-- | Returns the number of nested pi expressions.
piArgCount :: Term -> Int
piArgCount = go 0
  where go i (Term (Pi _ _ rhs)) = go (i+1) rhs
        go i _ = i

-- | @instantiateVars f l t@ substitutes each dangling bound variable
-- @LocalVar j t@ with the term @f i j t@, where @i@ is the number of
-- binders surrounding @LocalVar j t@.
instantiateVars :: (DeBruijnIndex -> DeBruijnIndex -> Term -> Term)
                -> DeBruijnIndex -> Term -> Term
instantiateVars f initialLevel = go initialLevel 
  where goList :: DeBruijnIndex -> [Term] -> [Term]
        goList _ []  = []
        goList l (e:r) = go l e : goList (l+1) r

        gof l ftf = 
          case ftf of
            App x y -> App (go l x) (go l y) 
            TupleValue ll -> TupleValue $ go l <$> ll
            TupleType ll  -> TupleType $ go l <$> ll
            RecordValue m -> RecordValue $ go l <$> m
            RecordSelector x fld -> RecordSelector (go l x) fld
            RecordType m      -> RecordType $ go l <$> m
            CtorApp c ll      -> CtorApp c (goList l ll)
            DataTypeApp dt ll -> DataTypeApp dt (goList l ll)
            _ -> ftf
        go :: DeBruijnIndex -> Term -> Term
        go l (Term tf) =
          case tf of
            FTermF ftf ->  Term $ FTermF $ gof l ftf
            Lambda i tp rhs -> Term $ Lambda i (go l tp) (go (l+1) rhs)
            Pi i lhs rhs    -> Term $ Pi i (go l lhs) (go (l+1) rhs)
            Let defs r      -> Term $ Let (procDef <$> defs) (go l' r)
              where l' = l + length defs
                    procDef (LocalFnDef sym tp eqs) = LocalFnDef sym tp' eqs'
                      where tp' = go l tp
                            eqs' = procEq <$> eqs
                    procEq (DefEqn pats rhs) = DefEqn pats (go eql rhs)
                      where eql = l' + sum (patBoundVarCount <$> pats)
            LocalVar i tp
              | i < l -> Term $ LocalVar i (go l tp)
              | otherwise -> f l i (go l tp)
--            EqType lhs rhs -> Term $ EqType (go l lhs) (go l rhs)
--            Oracle s prop  -> Term $ Oracle s (go l prop)

-- | @incVars j k t@ increments free variables at least @j@ by @k@.
-- e.g., incVars 1 2 (C ?0 ?1) = C ?0 ?3
incVars :: DeBruijnIndex -> DeBruijnIndex -> Term -> Term
incVars _ 0 = id
incVars initialLevel j = assert (j > 0) $ instantiateVars fn initialLevel
  where fn _ i t = Term $ LocalVar (i+j) t

-- | Substitute @t@ for variable @k@ and decrement all higher dangling
-- variables.
instantiateVar :: DeBruijnIndex -> Term -> Term -> Term
instantiateVar k u = instantiateVars fn 0
  where -- Use terms to memoize instantiated versions of t.
        terms = [ incVars 0 i u | i <- [0..] ] 
        -- Instantiate variable 0.
        fn i j t | j - k == i = terms !! i
                 | j - i > k  = Term $ LocalVar (j - 1) t                 
                 | otherwise  = Term $ LocalVar j t

-- | Substitute @ts@ for variables @[k .. k + length ts - 1]@ and
-- decrement all higher loose variables by @length ts@.
instantiateVarList :: DeBruijnIndex -> [Term] -> Term -> Term
instantiateVarList _ [] = id
instantiateVarList k ts = instantiateVars fn 0
  where
    l = length ts
    -- Use terms to memoize instantiated versions of ts.
    terms = [ [ incVars 0 i t | i <- [0..] ] | t <- ts ]
    -- Instantiate variables [k .. k+l-1].
    fn i j t | j >= i + k + l = Term $ LocalVar (j - l) t
             | j >= i + k     = (terms !! (j - i - k)) !! i
             | otherwise      = Term $ LocalVar j t
-- ^ Specification in terms of @instantiateVar@ (by example):
-- @instantiateVarList 0 [x,y,z] t@ is the beta-reduced form of @Lam
-- (Lam (Lam t)) `App` z `App` y `App` x@, i.e. @instantiateVarList 0
-- [x,y,z] t == instantiateVar 0 x (instantiateVar 1 (incVars 0 1 y)
-- (instantiateVar 2 (incVars 0 2 z) t))@.


-- | Substitute @t@ for variable 0 in @s@ and decrement all remaining
-- variables.
betaReduce :: Term -> Term -> Term
betaReduce s t = instantiateVar 0 t s

-- | Pretty print a term with the given outer precedence.
ppTerm :: TermPrinter Term
ppTerm lcls p0 t =
  case asApp t of
    (Term u,[]) -> ppTermF p0 u
    (Term u,l) -> ppParens (p0 >= 10) $ hsep $ ppTermF 10 u : fmap (ppTerm lcls 10) l
 where ppTermF p (FTermF tf) = runIdentity $ ppFlatTermF (\p' -> pure . ppTerm lcls p') p tf
       ppTermF p (Lambda pat tp rhs) = ppParens (p >= 1) $
           text "\\" <> lhs <+> text "->" <+> ppTerm lcls' 2 rhs
         where lcls' = foldl' consBinding lcls (patBoundVars pat)
               lhs = parens (ppPat ppTerm lcls' 1 pat <> doublecolon <> ppTerm lcls 1 tp)
       ppTermF p (Pi pat tp rhs) = ppPi ppTerm ppTerm lcls p (pat,tp,rhs)
       ppTermF p (Let dl u) = ppParens (p >= 2) $
           text "let" <+> vcat (ppLocalDef ppTerm lcls' <$> dl) $$
           text " in" <+> ppTerm lcls' 0 u
         where nms = concatMap localVarNames dl
               lcls' = foldl' consBinding lcls nms
       ppTermF _ (LocalVar i _) = lookupDoc lcls i
--       ppTermF _ (EqType lhs rhs) = ppTerm lcls 1 lhs <+> equals <+> ppTerm lcls 1 rhs
--       ppTermF _ (Oracle s prop) = quotes (text s) <> parens (ppTerm lcls 0 prop)


instance Show Term where
  showsPrec p t = shows $ ppTerm emptyLocalVarDoc p t

type TypedDataType = DataType Ident Term
type TypedCtor = Ctor Ident Term
type TypedDef = Def Term
type TypedDefEqn = DefEqn Term

data ModuleDecl = TypeDecl TypedDataType
                | DefDecl TypedDef
 
data Module = Module {
          moduleName    :: ModuleName
        , moduleTypeMap :: !(Map Ident TypedDataType)
        , moduleCtorMap :: !(Map Ident TypedCtor)
        , moduleDefMap  :: !(Map Ident TypedDef)
        , moduleRDecls   :: [ModuleDecl] -- ^ All declarations in reverse order they were added. 
        }

instance Show Module where
  show m = render $ vcat $ ppdecl <$> moduleDecls m
    where ppdecl (TypeDecl d) = ppDataType ppTerm d
          ppdecl (DefDecl d) = ppDef emptyLocalVarDoc d <> char '\n'

emptyModule :: ModuleName -> Module
emptyModule nm =
  Module { moduleName = nm
         , moduleTypeMap = Map.empty
         , moduleCtorMap = Map.empty
         , moduleDefMap  = Map.empty
         , moduleRDecls = []
         }

findDataType :: Module -> Ident -> Maybe TypedDataType
findDataType m i = Map.lookup i (moduleTypeMap m)

insDataType :: Module -> TypedDataType -> Module
insDataType m dt = m { moduleTypeMap = Map.insert (dtName dt) dt (moduleTypeMap m)
                     , moduleCtorMap = foldl' insCtor (moduleCtorMap m) (dtCtors dt)
                     , moduleRDecls = TypeDecl dt : moduleRDecls m
                     }
  where insCtor m' c = Map.insert (ctorName c) c m' 

-- | Data types defined in module.
moduleDataTypes :: Module -> [TypedDataType]
moduleDataTypes = Map.elems . moduleTypeMap

-- | Ctors defined in module.
moduleCtors :: Module -> [TypedCtor]
moduleCtors = Map.elems . moduleCtorMap

findCtor :: Module -> Ident -> Maybe TypedCtor
findCtor m i = Map.lookup i (moduleCtorMap m)

findExportedCtor :: Module -> String -> Maybe TypedCtor
findExportedCtor _ _ = undefined

moduleDefs :: Module -> [TypedDef]
moduleDefs = Map.elems . moduleDefMap

findDef :: Module -> Ident -> Maybe TypedDef
findDef m i = Map.lookup i (moduleDefMap m)

findExportedDef :: Module -> String -> Maybe TypedDef
findExportedDef _ _ = undefined

insDef :: Module -> Def Term -> Module
insDef m d = m { moduleDefMap = Map.insert (defIdent d) d (moduleDefMap m)
               , moduleRDecls = DefDecl d : moduleRDecls m
               }

moduleDecls :: Module -> [ModuleDecl]
moduleDecls = reverse . moduleRDecls
