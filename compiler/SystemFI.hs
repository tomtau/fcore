{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wall #-}

module SystemFI
  ( Type(..)
  , Expr(..)
  , Constructor(..)
  , Alt(..)
--, TypeContext
--, ValueContext
--, Index
--, alphaEq
--, mapTVar
--, mapVar
  , fsubstTT
  , fsubstTT'
  , fsubstTE
  , fsubstEE
  , joinType
  , prettyType
  , uglyType
  , prettyExpr
  , uglyExpr
  , genName
  ) where

import qualified Src

import JavaUtils
import PrettyUtils

import Text.PrettyPrint.ANSI.Leijen
import qualified Language.Java.Pretty      (prettyPrint)

import           Data.List (intersperse)
import qualified Data.Map as Map
import qualified Data.Set as Set

data Type t
  = TVar Src.ReaderId t                 -- a
  | JClass ClassName                    -- C
  | Fun (Type t) (Type t)               -- t1 -> t2
  | Forall Src.ReaderId (t -> Type t)   -- forall a. t
  | Product [Type t]                    -- (t1, ..., tn)
  | Unit

  | And (Type t) (Type t)               -- t1 & t2
  | Record (Src.Label, Type t)
  | Datatype Src.ReaderId [Src.ReaderId]
  | ListOf (Type t)
    -- Warning: If you ever add a case to this, you *must* also define the
    -- binary relations on your new case. Namely, add cases for your data
    -- constructor in `alphaEq' (below) and `coerce' (in Simplify.hs). Consult
    -- George if you're not sure.

data Expr t e
  = Var Src.ReaderId e
  | Lit Src.Lit

  -- Binders we have: λ, fix, letrec, and Λ
  | Lam Src.ReaderId (Type t) (e -> Expr t e)
  | Fix Src.ReaderId Src.ReaderId
        (e -> e -> Expr t e)
        (Type t)  -- t1
        (Type t)  -- t
      -- fix x (x1 : t1) : t. e     Syntax in the tal-toplas paper
      -- fix (x : t1 -> t). \x1. e  Alternative syntax, which is arguably clear
      -- <name>: Fix funcName paraName func paraType returnType
  | Let Src.ReaderId (Expr t e) (e -> Expr t e)
  | LetRec [Src.ReaderId]           -- Names
           [Type t]                 -- Signatures
           ([e] -> [Expr t e])      -- Bindings
           ([e] -> Expr t e)        -- Body
  | BLam Src.ReaderId (t -> Expr t e)

  | App  (Expr t e) (Expr t e)
  | TApp (Expr t e) (Type t)

  | If (Expr t e) (Expr t e) (Expr t e)
  | PrimOp (Expr t e) Src.Operator (Expr t e)
      -- SystemF extension from:
      -- https://www.cs.princeton.edu/~dpw/papers/tal-toplas.pdf
      -- (no int restriction)

  | Tuple [Expr t e]     -- Tuple introduction
  | Proj Int (Expr t e)  -- Tuple elimination

  -- Java
  | JNew ClassName [Expr t e]
  | JMethod (Src.JCallee (Expr t e)) MethodName [Expr t e] ClassName
  | JField  (Src.JCallee (Expr t e)) FieldName ClassName
  | PolyList [Expr t e] (Type t)
  | JProxyCall (Expr t e) (Type t)

  | Seq [Expr t e]

  | Merge (Expr t e) (Expr t e)  -- e1 ,, e2
  | RecordIntro    (Src.Label, Expr t e)
  | RecordElim   (Expr t e) Src.Label
  | RecordUpdate (Expr t e) (Src.Label, Expr t e)

  | Constr (Constructor t) [Expr t e]
  | Case (Expr t e) [Alt t e]

data Alt t e = ConstrAlt (Constructor t) [Src.ReaderId] ([e] -> Expr t e)
            -- | Default (Expr t e)

data Constructor t = Constructor {constrName :: Src.ReaderId, constrParams :: [Type t]}
-- newtype Typ = HideTyp { revealTyp :: forall t. Type t } -- type of closed types

-- newtype Exp = HideExp { revealExp :: forall t e. Expr t e }

type TypeContext t    = Set.Set t
type ValueContext t e = Map.Map e (Type t)

type Index = Int

alphaEq :: Int -> Type Index -> Type Index -> Bool
alphaEq _ (TVar _ a)   (TVar _ b)   = a == b
alphaEq _ (JClass c)   (JClass d)   = c == d
alphaEq i (Fun s1 s2)  (Fun t1 t2)  = alphaEq i s1 t1 && alphaEq i s2 t2
alphaEq i (Forall _ f) (Forall _ g) = alphaEq (succ i) (f i) (g i)
alphaEq i (Product ss) (Product ts) = length ss == length ts && uncurry (alphaEq i) `all` zip ss ts
alphaEq _  Unit     Unit            = True
alphaEq i (And s1 s2)  (And t1 t2)  = alphaEq i s1 t1 && alphaEq i s2 t2
alphaEq i (ListOf t1) (ListOf t2)   = alphaEq i t1 t2
alphaEq _ _            _            = False

mapTVar :: (Src.ReaderId -> t -> Type t) -> Type t -> Type t
mapTVar g (TVar n a)     = g n a
mapTVar _ (JClass c)     = JClass c
mapTVar g (Fun t1 t2)    = Fun (mapTVar g t1) (mapTVar g t2)
mapTVar g (Forall n f)   = Forall n (mapTVar g . f)
mapTVar g (Product ts)   = Product (map (mapTVar g) ts)
mapTVar _  Unit          = Unit
mapTVar g (ListOf t)     = ListOf (mapTVar g t)
mapTVar g (And t1 t2)    = And (mapTVar g t1) (mapTVar g t2)
mapTVar g (Record (l,t)) = Record (l, mapTVar g t)
mapTVar _ t@(Datatype _ _)  = t

mapVar :: (Src.ReaderId -> e -> Expr t e) -> (Type t -> Type t) -> Expr t e -> Expr t e
mapVar g _ (Var n a)                 = g n a
mapVar _ _ (Lit n)                   = Lit n
mapVar g h (Lam n t f)               = Lam n (h t) (mapVar g h . f)
mapVar g h (BLam n f)                = BLam n (mapVar g h . f)
mapVar g h (Fix n1 n2 f t1 t)        = Fix n1 n2 (\x x1 -> mapVar g h (f x x1)) (h t1) (h t)
mapVar g h (Let n b e)               = Let n (mapVar g h b) (mapVar g h . e)
mapVar g h (LetRec ns ts bs e)       = LetRec ns (map h ts) (map (mapVar g h) . bs) (mapVar g h . e)
mapVar g h (Constr (Constructor n ts) es) = Constr c' (map (mapVar g h) es)
    where c' = Constructor n (map h ts)
mapVar g h (Case e alts)             = Case (mapVar g h e) (map mapAlt alts)
    where mapAlt (ConstrAlt (Constructor n ts) ns f) = ConstrAlt (Constructor n (map h ts)) ns ((mapVar g h) . f)
mapVar g h (App f e)                 = App (mapVar g h f) (mapVar g h e)
mapVar g h (TApp f t)                = TApp (mapVar g h f) (h t)
mapVar g h (If p b1 b2)              = If (mapVar g h p) (mapVar g h b1) (mapVar g h b2)
mapVar g h (PrimOp e1 op e2)         = PrimOp (mapVar g h e1) op (mapVar g h e2)
mapVar g h (Tuple es)                = Tuple (map (mapVar g h) es)
mapVar g h (Proj i e)                = Proj i (mapVar g h e)
mapVar g h (JNew c args)             = JNew c (map (mapVar g h) args)
mapVar g h (JMethod callee m args c) = JMethod (fmap (mapVar g h) callee) m (map (mapVar g h) args) c
mapVar g h (JField  callee f c)      = JField (fmap (mapVar g h) callee) f c
mapVar g h (PolyList es t)           = PolyList (map (mapVar g h) es) (h t)
mapVar g h (JProxyCall jmethod t)    = JProxyCall (mapVar g h jmethod) (h t)
mapVar g h (Seq es)                  = Seq (map (mapVar g h) es)
mapVar g h (Merge e1 e2)             = Merge (mapVar g h e1) (mapVar g h e2)
mapVar g h (RecordIntro (l, e))      = RecordIntro (l, mapVar g h e)
mapVar g h (RecordElim e l)          = RecordElim (mapVar g h e) l
mapVar g h (RecordUpdate e (l1,e1))  = RecordUpdate (mapVar g h e) (l1, mapVar g h e1)

fsubstTT :: Eq a => a -> Type a -> Type a -> Type a
fsubstTT x r = mapTVar (\n a -> if a == x then r else TVar n a)

-- Warning. Temporary solution. Should be replaced.
-- It checks the propagated names to distinguish variables.
fsubstTT' :: (Index, Src.ReaderId) -> Type Index -> Type Index -> Type Index
fsubstTT' (x, name) r = mapTVar (\n a -> if a == x && n == name then r else TVar n a) 
-- Here: Should remove redundant "#"s in name.


fsubstTE :: Eq t => t -> Type t -> Expr t e -> Expr t e
fsubstTE x r = mapVar Var (fsubstTT x r)

fsubstEE :: Eq a => a -> Expr t a -> Expr t a -> Expr t a
fsubstEE x r = mapVar (\n a -> if a == x then r else Var n a) id


joinType :: Type (Type t) -> Type t
joinType (TVar n a)       = a
joinType (JClass c)       = JClass c
joinType (Fun t1 t2)      = Fun (joinType t1) (joinType t2)
joinType (Forall n g)     = Forall n (joinType . g . TVar n)
joinType (Product ts)     = Product (map joinType ts)
joinType  Unit            = Unit
joinType (And t1 t2)      = And (joinType t1) (joinType t2)
joinType (Record (l,t))   = Record (l, joinType t)
joinType (Datatype n ns)  = Datatype n ns
joinType (ListOf t)       = ListOf (joinType t)

-- instance Show (Type Index) where
--   show = show . pretty

-- instance Pretty (Type Index) where
--   pretty = prettyType

prettyType :: Type Index -> Doc
prettyType = prettyType' basePrec 0

prettyType' :: Prec -> Index -> Type Index -> Doc

prettyType' _ _ (TVar n a)   = text n

prettyType' _ _ (Datatype n _) = text n

prettyType' p i (Fun t1 t2)  =
  parensIf p 2
    (prettyType' (2,PrecPlus) i t1 <+> arrow <+> prettyType' (2,PrecMinus) i t2)

prettyType' p i (Forall n f)   =
  parensIf p 1
    (forall <+> text n <> dot <+>
     prettyType' (1,PrecMinus) (succ i) (f i))

prettyType' _ i (Product ts) = parens $ hcat (intersperse comma (map (prettyType' basePrec i) ts))

prettyType' _ _  Unit = text "Unit"

prettyType' _ _ (JClass "java.lang.Integer")   = text "Int"
prettyType' _ _ (JClass "java.lang.String")    = text "String"
prettyType' _ _ (JClass "java.lang.Boolean")   = text "Bool"
prettyType' _ _ (JClass "java.lang.Character") = text "Char"
prettyType' _ _ (JClass c)                     = text c
prettyType' p i (ListOf t)                     = text "List" <+> prettyType' p i t

prettyType' p i (And t1 t2) =
  parensIf p 2
    (prettyType' (2,PrecMinus) i t1 <+>
     ampersand  <+>
     prettyType' (2,PrecPlus) i t2)

prettyType' _ i (Record (l,t)) = lbrace <+> text l <+> colon <+> prettyType' basePrec i t <+> rbrace

-- instance Show (Expr Index Index) where
--   show = show . pretty

-- instance Pretty (Expr Index Index) where
--   pretty = prettyExpr

prettyExpr :: Expr Index Index -> Doc
prettyExpr = prettyExpr' basePrec (0, 0)

prettyExpr' :: Prec -> (Index, Index) -> Expr Index Index -> Doc

prettyExpr' _ _ (Var n _) = text n

prettyExpr' p (i,j) (Lam n t f)
  = parensIf p 2 $ group $ hang 2 $
      lambda <+> parens (text n <+> colon <+> prettyType' basePrec i t) <> dot <$>
      prettyExpr' (2,PrecMinus) (i, j + 1) (f j)

prettyExpr' p (i,j) (App e1 e2)
  = parensIf p 4 $
      group $ hang 2 $ prettyExpr' (4,PrecMinus) (i,j) e1 <$> prettyExpr' (4,PrecPlus) (i,j) e2

prettyExpr' p (i,j) (BLam n f) =
  parensIf p 2
    (biglambda <+> text n <> dot <+>
     prettyExpr' (2,PrecMinus) (succ i, j) (f i))

prettyExpr' p (i,j) (TApp e t) =
  parensIf p 4
    (group $ hang 2 $ prettyExpr' (4,PrecMinus) (i,j) e <$> prettyType' (4,PrecPlus) i t)

prettyExpr' _ _ (Lit (Src.Int n))    = integer n
prettyExpr' _ _ (Lit (Src.String s)) = dquotes (string s)
prettyExpr' _ _ (Lit (Src.Bool b))   = bool b
prettyExpr' _ _ (Lit (Src.Char c))   = char c
prettyExpr' _ _ (Lit Src.UnitLit)    = unit

prettyExpr' p (i,j) (If e1 e2 e3)
  = parensIf p prec
      (hang 3 (text "if"   <+> prettyExpr' (prec,PrecMinus) (i,j) e1 <+>
               text "then" <+> prettyExpr' (prec,PrecMinus) (i,j) e2 <+>
               text "else" <+> prettyExpr' (prec,PrecMinus) (i,j) e3))
  where prec = 3

prettyExpr' p (i,j) (PrimOp e1 op e2)
  = parens (prettyExpr' p (i,j) e1 <+> pretty_op <+> prettyExpr' p (i,j) e2)
  where
    pretty_op = text (Language.Java.Pretty.prettyPrint java_op)
    java_op   = case op of
                  Src.Arith   op' -> op'
                  Src.Compare op' -> op'
                  Src.Logic   op' -> op'

prettyExpr' _ (i,j) (Tuple es) = tupled (map (prettyExpr' basePrec (i,j)) es)

prettyExpr' p i (Proj n e) =
  parensIf p 5
    (prettyExpr' (5,PrecMinus) i e <> dot <> char '_' <> int n)

prettyExpr' _ (i,j) (JNew c args) =
  parens (text "new" <+> text c <> tupled (map (prettyExpr' basePrec (i,j)) args))

prettyExpr' _ i (JMethod name m args _) = methodStr name <> dot <> text m <> tupled (map (prettyExpr' basePrec i) args)
  where
    methodStr (Src.Static x) = text x
    methodStr (Src.NonStatic x) = prettyExpr' (6,PrecMinus) i x

prettyExpr' _ i (JField name f _) = fieldStr name <> dot <> text f
  where
    fieldStr (Src.Static x) = text x
    fieldStr (Src.NonStatic x) = prettyExpr' (6,PrecMinus) i x

prettyExpr' p (i,j) (Seq es) = semiBraces (map (prettyExpr' p (i,j)) es)
prettyExpr' p i (PolyList es t) = brackets. hcat . intersperse comma . map (prettyExpr' p i ) $ es
prettyExpr' p i (JProxyCall jmethod t) = prettyExpr' p i jmethod

prettyExpr' p (i,j) (Fix n1 n2 f t1 t)
  = parens $ group $ hang 2 $
      text "fix" <+> text n1 <+>
      parens (text n2 <+> colon <+> prettyType' p i t1) <+>
      colon <+> prettyType' p i t <> dot <$>
      prettyExpr' p (i, j + 2) (f j (j + 1))

prettyExpr' p (i,j) (Let n b e) =
  parensIf p 2 (text "let" <+> text n <+> equals <+> prettyExpr' basePrec (i, j + 1) b <$> text "in" <$>
  prettyExpr' basePrec (i, j + 1) (e j))

prettyExpr' p (i,j) (LetRec names sigs binds body)
  = text "let" <+> text "rec" <$>
    vcat (intersperse (text "and") (map (indent 2) pretty_binds)) <$>
    text "in" <$>
    pretty_body
  where
    n   = length sigs
    ids = [i..(i+n-1)]
    pretty_ids   = map text names
    pretty_sigs  = map (prettyType' p i) sigs
    pretty_defs  = map (prettyExpr' p (i, j + n)) (binds ids)
    pretty_binds = zipWith3 (\pretty_id pretty_sig pretty_def ->
                  pretty_id <+> colon <+> pretty_sig <$> indent 2 (equals <+> pretty_def))
                  pretty_ids pretty_sigs pretty_defs
    pretty_body  = prettyExpr' p (i, j + n) (body ids)

prettyExpr' p (i,j) (Merge e1 e2) =
  parens $ prettyExpr' p (i,j) e1 <+> dcomma <+> prettyExpr' p (i,j) e2

prettyExpr' _ (i,j) (RecordIntro (l, e))       = lbrace <+> text l <+> equals <+> prettyExpr' basePrec (i,j) e <+> rbrace
prettyExpr' p (i,j) (RecordElim e l)         = prettyExpr' p (i,j) e <> dot <> text l
prettyExpr' p (i,j) (RecordUpdate e (l, e1)) = prettyExpr' p (i,j) e <+> text "with" <+> prettyExpr' p (i,j) (RecordIntro (l, e1))

prettyExpr' p (i,j) (Constr c es)            = braces $ intersperseSpace $ text (constrName c) : map (prettyExpr' p (i,j)) es

prettyExpr' p (i,j) (Case e alts) =
    hang 2 $ text "case" <+> prettyExpr' p (i,j) e <+> text "of" <$> text " " <+> Src.intersperseBar (map pretty_alt alts)
    where pretty_alt (ConstrAlt c ns es) =
              let n = length ns
                  ids = [j..j+n-1]
              in intersperseSpace (text (constrName c) : map prettyVar ids) <+> arrow <+> prettyExpr' p (i, j+n) (es ids)


catSpace :: [String] -> String -> String
catSpace []     _ = ""
catSpace [x]    _ = x
catSpace (x:xs) s = x ++ s ++ catSpace xs s

-- Ugly printer.

enc :: [String] -> [String] -> String
enc a b = "[" ++ (catSpace a " ") ++ "|" ++ (catSpace b " ") ++ "]"

enc2 :: [String] -> [String] -> String
enc2 a b = "[" ++ (catSpace a " ") ++ "|" ++ (catSpace b ",") ++ "]"

uglyType :: Type Index -> Doc
uglyType = text . printType 0

printType :: Int -> Type Int -> String
printType _ (TVar n a) = enc ["TVar"] [n]
printType _ (Datatype n _) = enc ["Datatype"] [n]
printType i (Fun t1 t2) = enc ["Fun"] [printType i t1, "->", printType i t2]
printType i (Forall n f) = enc ["Forall", n] [printType (succ i) (f i)]
printType i (Product ts) = enc2 ["Product"] $ map (printType i) ts
printType _  Unit = "Unit"
printType _ (JClass "java.lang.Integer") = "Int"
printType _ (JClass "java.lang.String") = "String"
printType _ (JClass "java.lang.Boolean") = "Bool"
printType _ (JClass "java.lang.Character") = "Char"
printType _ (JClass c) = enc ["JClass"] [c]
printType i (And t1 t2) = enc ["And"] [printType i t1, ",,", printType i t2]
printType i (Record (l,t)) = enc ["Record", l] [printType i t]

uglyExpr :: Expr Int Int -> Doc
uglyExpr = text . printExpr 0 0

printExpr :: Int -> Int -> Expr Int Int -> String
printExpr i j (Var n _) = enc ["Var"] [n] 
printExpr i j (Lam n t f) = enc ["Lam", n, ":", printType i t] [printExpr i (succ j) (f j)]
printExpr i j (App e1 e2) = enc ["App"]  [printExpr i j e1, "apply", printExpr i j e2]
printExpr i j (BLam n f) = enc ["BLam", n] [printExpr (succ i) j (f i)]
printExpr i j (TApp e t) = enc ["TApp"] [printExpr i j e, "apply", printType i t]
printExpr i j all@(Lit _) = show . prettyExpr' basePrec (i, j) $ all
printExpr i j (If e1 e2 e3) = enc ["If"] ["if", printExpr i j e1, "then", printExpr i j e2, "else", printExpr i j  e3]
printExpr i j (PrimOp e1 op e2) = "(" ++ printExpr i j e1 ++ " " ++ print_op ++ " "  ++ ")"
  where
    print_op = Language.Java.Pretty.prettyPrint java_op
    java_op  = case op of
                 Src.Arith   op' -> op'
                 Src.Compare op' -> op'
                 Src.Logic   op' -> op'
printExpr i j (Tuple es) = enc2 ["Tuple"] $ map (printExpr i j) es 
printExpr i j (Proj n e) = enc ["Proj", printExpr i j e] ["._", show n]
printExpr i j (Seq es) = enc2 ["Seq"] $ map (printExpr i j) es
printExpr i j (Let n b e) = enc ["Let",n,"="] [printExpr i (succ j) b, "\nin", printExpr i (succ j) (e j)] 
printExpr i j (Merge e1 e2) = enc ["Merge"] [printExpr i j e1, ",,", printExpr i j e2]
printExpr i j (RecordIntro (l, e)) = enc ["RecordIntro"] [show (lbrace <+> text l <+> equals <+> text (printExpr i j e) <+> rbrace)]
printExpr i j (RecordElim e l) = enc ["RecordElim"] [printExpr i j e ++ "." ++ l]
printExpr i j (RecordUpdate e (l, e1)) = enc ["RecordUpdate"] [show (text (printExpr i j e) <+> text "with" <+> text (printExpr i j (RecordIntro (l, e1))))]
printExpr i j _ = "Oops"


genNameType :: Index -> String -> (Int -> String) -> Type Index -> Type Index
genNameType i info h = mapTVar (\n a -> TVar (n ++ h a) a)

genName :: Index -> String -> (Int -> String) -> Expr Index Index -> Expr Index Index
genName i info h all@(Var n a) = all
genName i info h all@(Lit n) = all
genName i info h (Lam n t f) = Lam n (genNameType i info h t) (genName i info h . f) 
genName i info h (BLam n f) = BLam (n ++ info ++ show i) (genName (succ i) info (\x -> if x == i then info ++ show i else h x) . f) 
genName i info h (Fix n1 n2 f t1 t) = Fix n1 n2 (\x x1 -> genName i info h (f x x1)) (genNameType i info h t1) (genNameType i info h t) 
genName i info h (Let n b e) = Let n (genName i ('a':info) h b) (genName i ('b':info) h . e)
genName i info h (LetRec ns ts bs e) = LetRec ns (map (genNameType i info h) ts) bs' e'
  where
    bs' args = zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] (bs args) where n = length (bs args)
    e' = (genName i ("<0>" ++ info) h . e) 
genName i info h (Constr (Constructor name ts) es) = Constr (Constructor name (map (genNameType i info h) ts)) (zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] es) where n = length es
-- Bug?! Names in datatype can be equal to info.
genName i info h (Case e alts) = Case (genName i ("<0>" ++ info) h e) alts'
  where
    alts' = zipWith (\a b -> mapAlt a b) [1..n] alts
    mapAlt a (ConstrAlt (Constructor n0 ts0) names0 f0) = ConstrAlt (Constructor n0 (map (genNameType i info h) ts0)) names0 (genName i ("<" ++ show a ++ ">" ++ info) h . f0)
    n     = length alts
genName i info h (App f e) = App (genName i ('a':info) h f) (genName i ('b':info) h e) 
genName i info h (TApp f t) = TApp (genName i info h f) (genNameType i info h t) 
genName i info h (If p b1 b2) = If (genName i ('a':info) h p) (genName i ('b':info) h b1) (genName i ('c':info) h b2)
genName i info h (PrimOp e1 op e2) = PrimOp (genName i ('a':info) h e1) op (genName i ('b':info) h e2)
genName i info h (Tuple es) = Tuple $ zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] es where n = length es
genName i info h (Proj n e) = Proj n (genName i info h e)
genName i info h (JNew c args) = JNew c $ zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] args where n = length args
genName i info h (JMethod callee m args c) = JMethod (fmap (genName i ("<0>" ++ info) h) callee) m args' c
  where
    args' = zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] args 
    n     = length args
genName i info h (JField callee f c) = JField (fmap (genName i info h) callee) f c
genName i info h (Seq es) = Seq $ zipWith (\a b -> genName i ("<" ++ show a ++ ">" ++ info) h b) [1..n] es where n = length es
genName i info h (Merge e1 e2) = Merge (genName i ('a':info) h e1) (genName i ('b':info) h e2)
genName i info h (RecordIntro (l,e)) = RecordIntro (l, genName i info h e)
genName i info h (RecordElim e l) =  RecordElim (genName i info h e) l
genName i info h (RecordUpdate e (l1,e1)) = RecordUpdate (genName i ('a':info) h e) (l1, genName i ('b':info) h e1)

