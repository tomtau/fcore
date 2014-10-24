{-# OPTIONS -XRankNTypes -XFlexibleInstances -XFlexibleContexts -XTypeOperators -XMultiParamTypeClasses -XKindSignatures -XConstraintKinds -XScopedTypeVariables #-}

module UnboxTransCFJava where

import Prelude hiding (init, last)

-- import qualified Data.Set as Set

import qualified Language.Java.Syntax as J
import ClosureF
import Inheritance
import BaseTransCFJava
import StringPrefixes
import MonadLib
import JavaUtils
import JavaEDSL
import Panic
import qualified Src

data UnboxTranslate m = UT {toUT :: Translate m}

instance (:<) (UnboxTranslate m) (Translate m) where
   up              = up . toUT

instance (:<) (UnboxTranslate m) (UnboxTranslate m) where
   up              = id

getClassType :: (Monad m) => Translate m -> Type t -> Type t -> m ClassName
getClassType this t1 t2 = do
  closureClass <- liftM2 (++) (getPrefix this) (return "Closure")
  case (t1, t2) of
   (CFInt, CFInt) -> return (closureClass ++ "IntInt")
   (CFInt, _) -> return (closureClass ++ "IntBox")
   (_, CFInt) -> return (closureClass ++ "BoxInt")
   (_, _) -> return (closureClass ++ "BoxBox")

getFunType :: Type t -> (Type t, Type t)
getFunType (Forall (Type b f)) = (b, scope2ctyp (f ()))
getFunType _ = panic "UnboxTranslate.getFunType: expect Forall construcr"

--TODO: generate wrappers when types T1~T2
-- wrap :: J.Exp -> Type t -> Type t -> ([J.BlockStmt], J.Exp)
-- wrap e t1 t2 = ([], e)

transUnbox :: (MonadState Int m, selfType :< UnboxTranslate m, selfType :< Translate m) => Mixin selfType (Translate m) (UnboxTranslate m)
transUnbox this super =
  UT {toUT =
        super {translateM =
                 \e ->
                   case e of
                     TApp expr CFInt ->
                       do n <- get
                          (s,je,Forall (Kind f)) <- translateM (up this) expr
                          return (s,je,scope2ctyp (substScope n CFInteger (f n)))
                     App e1 e2 ->
                       translateApply (up this) (translateM (up this) e1) (translateM (up this) e2)
                     Lit lit ->
                       case lit of
                         (Src.Integer i) -> return ([] ,J.Lit $ J.Int i ,CFInt)
                         _ -> translateM super e
                     PrimOp e1 op e2 ->
                       do (s1,j1,_) <- translateM (up this) e1
                          (s2,j2,_) <- translateM (up this) e2
                          let (je,typ) =
                                case op of
                                  (Src.Arith realOp) -> (J.BinOp j1 realOp j2,CFInt)
                                  (Src.Compare realOp) -> (J.BinOp j1 realOp j2,JClass "java.lang.Boolean")
                                  (Src.Logic realOp) -> (J.BinOp j1 realOp j2,JClass "java.lang.Boolean")
                          newVarName <- getNewVarName (up this)
                          aType <- javaType (up this) typ
                          return (s1 ++ s2 ++ [localVar aType (varDecl newVarName je)],var newVarName,typ)
                     LetRec t xs body ->
                       do (n :: Int) <- get
                          let needed = length (xs (zip [n ..] t))
                          put (n + 2 + needed)
                          mfuns <- return (\defs -> forM (xs defs) (translateM (up this)))
                          let vars = (liftM (map (\(_,b,c) -> (b,c)))) (mfuns (zip [n ..] t))
                          let (bindings :: [Var]) = [n + 2 .. n + 1 + needed]
                          newvars <- ((liftM (pairUp bindings)) vars)
                          cNames <- mapM (\(_, typ) ->
                                           let (t1, t2) = getFunType typ
                                           in getClassType (up this) t1 t2)
                                    newvars
                          let varTypes = zip bindings cNames
                          let mDecls = map (\(x, typ) ->
                                              memberDecl (fieldDecl (classTy typ)
                                                                    (varDeclNoInit (localvarstr ++ show x))))
                                           varTypes
                          let finalFuns = mfuns newvars
                          let appliedBody = body newvars
                          let varnums = map fst newvars
                          (bindStmts,bindExprs,_) <- (liftM unzip3 finalFuns)
                          (bodyStmts,bodyExpr,t') <- translateM (up this) appliedBody
                          typ <- javaType (up this) t'
                          -- assign new created closures bindings to variables
                          let assm = map (\(i,jz) -> assign (name [localvarstr ++ show i]) jz)
                                         (varnums `zip` bindExprs)
                          let stasm = (concatMap (\(a,b) -> a ++ [b]) (bindStmts `zip` assm)) ++ bodyStmts ++ [assign (name ["out"]) bodyExpr]
                          let letClass =
                                [localClass ("Let" ++ show n)
                                             (classBody (memberDecl (fieldDecl objClassTy (varDeclNoInit "out")) :
                                                         mDecls ++ [J.InitDecl False (J.Block stasm)]))
                                ,localVar (classTy ("Let" ++ show n))
                                          (varDecl (localvarstr ++ show n)
                                                   (instCreat (classTyp ("Let" ++ show n)) []))
                                ,localVar typ (varDecl (localvarstr ++ show (n + 1))
                                                       (cast typ (J.ExpName (name [(localvarstr ++ show n), "out"]))))]
                          return (letClass,var (localvarstr ++ show (n + 1)),t')
                     _ -> translateM super e
              ,translateScopeM = \e m -> case e of
                   Type t g ->
                     do  n <- get
                         let (v,n')  = maybe (n+1,n+2) (\(i,_) -> (i,n+1)) m -- decide whether we have found the fixpoint closure or not
                         put (n' + 1)
                         let nextInClosure = g (n',t)

                         aType <- javaType (up this) t
                         let accessField = fieldAccess (var (localvarstr ++ show v)) closureInput
                         let js = localFinalVar aType (varDecl (localvarstr ++ show n') (cast aType accessField))

                         let ostmts = translateScopeM (up this) nextInClosure Nothing
                         (_,_,tt) <- ostmts
                         cName <- getClassType (up this) t (scope2ctyp tt)

                         (cvar,t1) <- translateScopeTyp (up this) v n [js] nextInClosure ostmts cName
                         return (cvar,var (localvarstr ++ show n), Type t (\_ -> t1) )

                   _ -> translateScopeM super e m
              ,translateApply = \m1 m2 ->
                    do  (n :: Int) <- get
                        put (n+1)
                        (s1,j1, Forall (Type t1 g)) <- m1
                        (s2,j2,_) <- m2
                        let retTyp = g ()
                        cName <- getClassType (up this) t1 (scope2ctyp retTyp)
                        -- let (wrapS, jS) = wrap j2 t1 t2
                        let fname = (localvarstr ++ show n) -- use a fresh variable
                        let closureVars = [localVar (classTy cName) (varDecl fname j1)
                                          ,assignField (fieldAccExp (var fname) closureInput) j2]
                        let fout = fieldAccess (var fname) "out"
                        (s3, nje3) <- getS3 (up this) (J.Ident fname) retTyp fout closureVars (classTy cName)
                        return (s1 ++ s2 ++ s3, nje3, scope2ctyp retTyp)
              ,translateIf =
                 \m1 m2 m3 ->
                   do n <- get
                      put (n + 1)
                      (s1,j1,_) <- m1 {- translateM this e1 -}
                      -- let j1' = J.BinOp j1 J.Equal (J.Lit (J.Int 0))
                      -- genIfBody this m2 m3 j1' s1 n,
                      genIfBody (up this) m2 m3 (s1,j1) n
              ,javaType = \typ ->
                            case typ of
                              CFInt -> return $ J.PrimType J.IntT
                              (Forall (Type t1 f)) -> case (f ()) of
                                                        (Body t2) -> liftM classTy (getClassType (up this) t1 t2)
                                                        _ -> liftM classTy (getClassType (up this) t1 CFInteger)
                              x -> javaType super x
              ,getPrefix = return (namespace ++ "unbox.")
              ,chooseCastBox = \typ ->
                                 case typ of
                                   CFInt -> return (\s n e -> localFinalVar (J.PrimType J.IntT)
                                                                            (varDecl (s ++ show n) (cast (J.PrimType J.IntT) e))
                                                   ,J.PrimType J.IntT)
                                   (Forall (Type t1 f)) ->
                                     case (f ()) of
                                       (Body t2) -> do
                                         typ1 <- (getClassType (up this) t1 t2)
                                         return (initClass typ1,classTy typ1)
                                       _ -> do
                                         typ1 <- (getClassType (up this) t1 CFInteger)
                                         return (initClass typ1,classTy typ1)
                                   t -> chooseCastBox super t
             }}