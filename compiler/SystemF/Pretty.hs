{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
module SystemF.Pretty where

import qualified Language.Java.Syntax as JS
import qualified Language.Java.Pretty as JP (prettyPrint)
import Text.PrettyPrint
import Data.Char        (chr, ord)
import Data.List        (intersperse)

import SystemF.Syntax


prettyPrint :: Pretty a => a -> String
prettyPrint = show . pretty

parenPrec :: Int -> Int -> Doc -> Doc
parenPrec inheritedPrec currentPrec t
    | inheritedPrec <= 0          = t
    | inheritedPrec < currentPrec = parens t
    | otherwise                   = t

class Pretty a where
    pretty :: a -> Doc
    pretty = prettyPrec 0 (0, 0)
  
    prettyPrec :: Int -> (Int, Int) -> a -> Doc
    prettyPrec _ _ = pretty

instance Pretty (PFTyp Int) where
    prettyPrec p l@(ltvar, lvar) t = case t of
        FTVar a    -> text (name a)
        FForall f  -> text ("forall " ++ name ltvar ++ ".") <+> prettyPrec p (ltvar+1,  lvar) (f ltvar)
        FFun t1 t2 -> parenPrec p 2 $ prettyPrec 1 l t1 <+> text "->" <+> prettyPrec p l t2
        PFInt      -> text "Int"

instance Pretty (PFExp Int Int) where
    prettyPrec p l@(ltvar, lvar) e = case e of
        FVar x           -> text (name x)
        FLit n           -> integer n
        FTuple es        -> parens $ hcat $ intersperse comma $ map (prettyPrec p l) es

        FProj i e        -> parenPrec p 1 $ prettyPrec 1 l e <> text ("._" ++ show i)

        FApp e1 e2       -> parenPrec p 2 $ prettyPrec 2 l e1 <+> prettyPrec 1 l e2 
        FTApp e t        -> parenPrec p 2 $ prettyPrec 2 l e  <+> prettyPrec 1 l t

        FBLam f          -> parenPrec p 3 $ 
                                text ("/\\" ++ name ltvar ++ ".") 
                                <+> prettyPrec 0 (ltvar+1, lvar) (f ltvar)
        FLam t f         -> parenPrec p 3 $ 
                                text ("\\(" ++ name lvar ++ " : " ++ show (prettyPrec p (ltvar, lvar+1) t) ++ ").")
                                <+> prettyPrec 0 (ltvar, lvar+1) (f lvar)
        FFix t1 f t2     -> parenPrec p 3 $ 
                                text ("fix " ++ name lvar ++ ".")
                                <+> text ("\\(" ++ (name (lvar+1) ++ " : " ++ show (prettyPrec p (ltvar, lvar+2) t1)) ++ ").")
                                <+> prettyPrec 0 (ltvar, lvar+2) (f lvar (lvar+1)) <+> colon <+> prettyPrec 0 (ltvar, lvar+2) t2

        FPrimOp e1 op e2 -> parenPrec p q $ prettyPrec q l e1 <+> text (JP.prettyPrint op) <+> prettyPrec (q-1) l e2 
                                where q = opPrec op 

        Fif0 e1 e2 e3    -> text "if0" <+> prettyPrec p l e1 <+> text "then" <+> prettyPrec p l e2 <+> text "else" <+> prettyPrec p l e3

name :: Int -> String
name n
    | n < 0     = error "`name` called with n < 0"
    | n < 26    = [chr (ord 'a' + n)]
    | otherwise = "a" ++ show (n - 25)

-- Precedence of operators based on the table in:
-- http://en.wikipedia.org/wiki/Order_of_operations#Programming_languages
opPrec JS.Mult    = 30
opPrec JS.Div     = 30
opPrec JS.Rem     = 30
opPrec JS.Add     = 40
opPrec JS.Sub     = 40
opPrec JS.LThan   = 60
opPrec JS.GThan   = 60
opPrec JS.LThanE  = 60
opPrec JS.GThanE  = 60
opPrec JS.Equal   = 70
opPrec JS.NotEq   = 70
opPrec JS.CAnd    = 110
opPrec JS.COr     = 120
opPrec op         = error $ "Something impossible happens! The operator '" 
                            ++ JP.prettyPrint op ++ "' is not part of the language."
