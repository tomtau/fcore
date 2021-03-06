{-# LANGUAGE ViewPatterns #-}

module PrettyPrint (showExpr) where

import           Data.List (intersperse)
import qualified Language.Java.Pretty (prettyPrint)
import           Text.PrettyPrint.ANSI.Leijen (Doc, (<+>), (<>), text, dot, colon)
import qualified Text.PrettyPrint.ANSI.Leijen as PP
import           Unbound.Generics.LocallyNameless


import qualified Src as S
import           Syntax


class Pretty p where
  ppr :: (Applicative m, LFresh m) => p -> m Doc

instance Pretty Expr where
  ppr (Var x) = return . text . show $ x
  ppr (App e es) = PP.parens <$> ((<+>) <$> ppr e <*> (ppr es))
  ppr (Lam bnd) = lunbind bnd $ \(delta, b) -> do
    delta' <- ppr delta
    b' <- ppr b
    return (PP.parens $ text "λ" <> delta' <+> dot <+> b')
  ppr (Star) = return $ PP.char '★'
  ppr (Pi bnd) = lunbind bnd $ \(delta, b) -> do
    let Cons bb = delta
    let ((x, Embed t), bb') = unrebind bb
    b' <- ppr b
    if (head (show x) == '_' && isEmpty bb')
      then do
        t' <- ppr t
        return (PP.parens $ t' <+> text "→" <+> b')
      else do
        delta' <- ppr delta
        return (PP.parens $ text "Π" <> delta' <+> dot <+> b')
  ppr (Mu b) = lunbind b $ \((x, Embed t), e) -> do
    t' <- ppr t
    e' <- ppr e
    return (PP.parens $ text "μ" <+> (text . show $ x) <+> colon <+> t' <+> dot <+> e')
  ppr (F t e) = do
    e' <- ppr e
    t' <- ppr t
    return (text "cast↑" <> PP.brackets t' <+> e')
  ppr (U e) = (text "cast↓" <+>) <$> ppr e
  ppr (Let bnd) = lunbind bnd $ \((x, Embed e1), e2) -> do
    e1' <- ppr e1
    e2' <- ppr e2
    return (text "let" <+> (text . show $ x) <+> PP.equals <+> e1' PP.<$> text "in" PP.<$> e2')
  ppr (LetRec bnd) = lunbind bnd $ \((unrec -> binds, body)) -> do
    binds' <- mapM
                (\(n, Embed t, Embed e) -> do
                   e' <- ppr e
                   t' <- ppr t
                   return (text (show n) <+> PP.colon <+> t' PP.<$> (PP.indent 2 (PP.equals <+> e'))))
                binds
    body' <- ppr body
    return $ text "let" <+> text "rec" PP.<$>
                            PP.vcat (intersperse (text "and") (map (PP.indent 2) binds')) PP.<$>
                            text "in" PP.<$>
                            body'
  ppr (If g e1 e2) = do
    g' <- ppr g
    e1' <- ppr e1
    e2' <- ppr e2
    return (text "if" <+> g' <+> text "then" <+> e1' <+> text "else" <+> e2')
  ppr (Lit (S.Int n)) = return $ PP.integer n
  ppr (Lit (S.String s)) = return $ PP.dquotes (PP.string s)
  ppr (Lit (S.Bool b)) = return $ PP.bool b
  ppr (Lit (S.Char c)) = return $ PP.char c
  ppr (Lit (S.UnitLit)) = return $ text "()"
  ppr (PrimOp op e1 e2) = do
    e1' <- ppr e1
    e2' <- ppr e2
    return $ PP.parens (e1' <+> op' <+> e2')

    where
      op' = text (Language.Java.Pretty.prettyPrint java_op)
      java_op =
        case op of
          S.Arith op'   -> op'
          S.Compare op' -> op'
          S.Logic op'   -> op'
  ppr Unit = return $ text "Unit"
  ppr (JClass "java.lang.Integer")   = return $ text "Int"
  ppr (JClass "java.lang.String")    = return $ text "String"
  ppr (JClass "java.lang.Boolean")   = return $ text "Bool"
  ppr (JClass "java.lang.Character") = return $ text "Char"
  ppr (JClass c)                     = return $ text c
  ppr (JNew c args)                  = do
    args' <- mapM ppr args
    return (text "new" <+> text c <> PP.parens (PP.cat $ PP.punctuate PP.comma args'))
  ppr (JMethod rcv mname args _)     = do
    args' <- mapM ppr args
    c <- case rcv of Left cn -> return $ text cn
                     Right e -> ppr e
    return (c <> dot <> text mname <> PP.parens (PP.cat $ PP.punctuate PP.comma args'))
  ppr (JField rcv fname _)           = do
    c <- case rcv of Left cn -> return $ text cn
                     Right e -> ppr e
    return (c <> dot <> text fname)
  ppr (Tuple t)                      = do
    t' <- mapM ppr t
    return $ PP.parens $ PP.cat $ PP.punctuate PP.comma t'
  ppr (Proj i t)                     = do
    t' <- ppr t
    return $ t' <> dot <> text (show i)
  ppr (Seq es)                       = do
    es' <- mapM ppr es
    return $ PP.vcat es'
  ppr (Product ts)                   = do
    ts' <- mapM ppr ts
    return $ PP.parens $ PP.cat $ PP.punctuate PP.comma ts'

  ppr (Sum bnd) = lunbind bnd $ \((x, Embed t), e) -> do
    t' <- ppr t
    e' <- ppr e
    return (PP.parens $ text "Σ" <+> (text . show $ x) <+> colon <+> t' <+> dot <+> e')

  ppr (Pack (e1, e2) t) = do
    e1' <- ppr e1
    e2' <- ppr e2
    t' <- ppr t
    return $ text "pack" <+> (PP.parens $ e1' <+> PP.comma <+> e2') <+> text "as" <+> t'

  ppr (UnPack (e1, e2) e3 e4) = do
    e1' <- ppr e1
    e2' <- ppr e2
    e3' <- ppr e3
    e4' <- ppr e4
    return $ text "unpack" <+>
             (PP.parens e1' <+> PP.comma <+> e2') <+>
             PP.equals <+>
             e3' <+>
             text "in" <+>
             e4'

instance Pretty Tele where
  ppr Empty = return PP.empty
  ppr (Cons bnd) = do
    t' <- ppr t
    bnd' <- ppr b'
    return ((PP.parens $ (text . show $ x) <+> colon <+> t') <> bnd')

    where
      ((x, Embed t), b') = unrebind bnd

showExpr :: Expr -> String
showExpr = show . runLFreshM . ppr

isEmpty :: Tele -> Bool
isEmpty Empty = True
isEmpty _ = False
