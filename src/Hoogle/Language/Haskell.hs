{-# LANGUAGE PatternGuards #-}

module Hoogle.Language.Haskell(parseInputHaskell) where

import General.Base
import General.Util
import Hoogle.Type.All
import Language.Haskell.Exts.Annotated hiding (TypeSig,Type)
import qualified Language.Haskell.Exts.Annotated as HSE
import Data.Generics.Uniplate.Data


type S = SrcSpanInfo


parseInputHaskell :: String -> ([ParseError], Input)
parseInputHaskell = join . f [] "" . zip [1..] . lines
    where
        f com url [] = []
        f com url ((i,s):is)
            | "-- | " `isPrefixOf` s = f [drop 5 s] url is
            | "--" `isPrefixOf` s = f ([dropWhile isSpace $ drop 2 s | com /= []] ++ com) url is
            | "@url " `isPrefixOf` s =  f com (drop 5 s) is
            | all isSpace s = f [] "" is
            | otherwise = (case parseLine i s of
                               Left y -> Left y
                               Right (as,bs) -> Right (as,[b{itemURL=if null url then itemURL b else url, itemDocs=unlines $ reverse com} | b <- bs]))
                          : f [] "" is

        join xs = (err, (concat as, ripple setPriority $ ripple setModuleURL $ concat bs))
            where (err,items) = unzipEithers xs
                  (as,bs) = unzip items


parseLine :: Int -> String -> Either ParseError ([Fact],[TextItem])
parseLine line x | "(##)" `isPrefixOf` x = Left $ parseErrorWith line 1 "Skipping due to HSE bug #206" "(##)"
parseLine line ('@':str) = case a of
        "keyword" -> Right $ itemKeyword $ dropWhile isSpace b
        "package" -> Right $ itemPackage $ dropWhile isSpace b
        _ -> Left $ parseErrorWith line 2 ("Unknown attribute: " ++ a) $ '@':str
    where (a,b) = break isSpace str
parseLine line x | a == "module" = Right $ itemModule $ split '.' $ dropWhile isSpace b
    where (a,b) = break isSpace x
parseLine line x
    | not continue = res
    | otherwise = fromMaybe res $ fmap Right $ parseTuple x `mappend` parseCtor x
    where (continue,res) = parseFunction line x

parseFunction line x = case parseDeclWithMode defaultParseMode{extensions=exts} $ x ++ ex of
    ParseOk y -> (,) False $ maybe (Left $ parseErrorWith line 1 "Can't translate" $ x ++ ex) Right $ transDecl x y
    ParseFailed pos msg -> (,) True $ Left $ parseErrorWith line (srcColumn pos) msg $ x ++ ex
    where ex = if "newtype " `isPrefixOf` x then " = N T" else " " -- space to work around HSE bug #205

parseTuple o@('(':xs) | ")" `isPrefixOf` rest
    , ParseOk y <- parseDeclWithMode defaultParseMode{extensions=exts} $ replicate (length com + 2) 'a' ++ drop 1 rest
    = transDecl o $ f y
    where
        (com,rest) = span (== ',') xs
        f (HSE.TypeSig sl [Ident sl2 _] ty) = HSE.TypeSig sl [Ident sl2 $ '(':com++")"] ty
parseTuple _ = Nothing

parseCtor x = case parseDeclWithMode defaultParseMode{extensions=exts} $ "data Data where " ++ x of
        ParseOk y -> transDecl x $ fmap (subtractCols 16) y
        _ -> Nothing

exts = [EmptyDataDecls,TypeOperators,ExplicitForall,GADTs,KindSignatures,MultiParamTypeClasses
       ,TypeFamilies,FlexibleContexts,FunctionalDependencies,ImplicitParams,MagicHash,UnboxedTuples]


subtractCols :: Int -> SrcSpanInfo -> SrcSpanInfo
subtractCols n (SrcSpanInfo x xs) = SrcSpanInfo (f x) (map f xs)
    where f x = x{srcSpanStartColumn=srcSpanStartColumn x - n, srcSpanEndColumn=srcSpanEndColumn x - n}


textItem = TextItem 2 "" "" Nothing (Str "") "" "" 0

fact x y = (x,[y])

itemPackage x = fact [] $ textItem{itemLevel=0, itemKey=x, itemName=x,
    itemURL="http://hackage.haskell.org/package/" ++ x ++ "/",
    itemDisp=Tags [emph "package",space,bold x]}

itemKeyword x = fact [] $ textItem{itemName=x, itemKey=x,
    itemDisp=Tags [emph "keyword",space,bold x]}

itemModule xs = fact [] $ textItem{itemLevel=1, itemKey=last xs, itemName=intercalate "." xs,
    itemURL="",
    itemDisp=Tags [emph "module",Str $ " " ++ concatMap (++".") (init xs),bold $ last xs]}


-- apply things that need to ripple down, priorities and module URL's
ripple :: (Maybe TextItem -> Maybe TextItem -> TextItem -> TextItem) -> [TextItem] -> [TextItem]
ripple f = fs Nothing Nothing
    where
        fs a b [] = []
        fs a b (x:xs) = f a2 b2 x : fs a2 b2 xs
            where a2 = if itemLevel x == 0 then Just x else a
                  b2 = if itemLevel x == 1 then Just x else b


-- base::Prelude is priority 0
-- base is priority 1
-- Everything else is priority 2
setPriority pkg mod x = x{itemPriority = pri}
    where pri = if base then (if prelude then 0 else 1) else 2
          prelude = maybe [] itemName mod == "Prelude"
          base = maybe [] itemName pkg == "base"


setModuleURL pkg _ x
    | isJust pkg && itemLevel x == 1 = x{itemURL=if null $ itemURL x then f $ itemName x else itemURL x}
    | otherwise = x
    where f = if "http:" `isPrefixOf` itemURL (fromJust pkg) then modHackage else modLocal
          modHackage xs = "http://hackage.haskell.org/packages/archive/" ++ itemName (fromJust pkg) ++ "/latest/doc/html/" ++ reps '.' '-' xs ++ ".html"
          modLocal xs = takeDirectory (itemURL $ fromJust pkg) ++ "/" ++ reps '.' '-' xs ++ ".html"


---------------------------------------------------------------------
-- TRANSLATE THINGS


transDecl :: String -> Decl S -> Maybe ([Fact],[TextItem])
transDecl x (GDataDecl s dat ctxt hd _ [] _) = transDecl x $ DataDecl s dat ctxt hd [] Nothing
transDecl x (GDataDecl _ _ _ _ _ [GadtDecl s name ty] _) = transDecl x $ HSE.TypeSig s [name] ty

transDecl x (HSE.TypeSig _ [name] tyy) = Just $ fact (ctr++kinds False typ) $ textItem{itemName=nam,itemKey=nam,
    itemType=Just typ,
    itemURL="#v:" ++ nam,
    itemDisp=formatTags x $ (cols snam,TagBold) : zipWith (\i a -> (cols a,TagColor i)) [1..] as ++ [(cols b,TagColor 0)]}
    where (snam,nam) = findName name
          (as,b) = initLast $ typeArgsPos tyy
          ctr = [FactCtorType nam y | ctorStart $ head nam, TLit y <- [fst $ fromTApp $ last $ fromTFun ty]]
          typ@(TypeSig _ ty) = transTypeSig tyy

          ctorStart x = isUpper x || x `elem` ":("

transDecl x (ClassDecl s ctxt hd _ _) = Just $ fact (kinds True $ transDeclHead ctxt hd) $ textItem
    {itemName=nam, itemKey=nam
    ,itemURL="#t:" ++ nam
    ,itemDisp=x `formatTags` [(cols $ head $ srcInfoPoints s, TagEmph),(cols snam,TagBold)]}
    where (snam,nam) = findName hd

transDecl x (TypeDecl s hd ty) = Just $ fact (FactAlias from to:kinds False from++kinds False to) $ textItem
    {itemName=nam, itemKey=nam
    ,itemURL="#t:" ++ nam
    ,itemDisp=x `formatTags` [(cols $ head $ srcInfoPoints s, TagEmph),(cols snam,TagBold)]}
    where (snam,nam) = findName hd
          from = transDeclHead Nothing hd
          to = transTypeSig ty

transDecl x (DataDecl _ dat ctxt hd _ _) = Just $ fact (kinds False $ transDeclHead ctxt hd) $ textItem
    {itemName=nam, itemKey=nam
    ,itemURL="#t:" ++ nam
    ,itemDisp=x `formatTags` [(cols $ srcInfoSpan $ ann dat, TagEmph),(cols snam,TagBold)]}
    where (snam,nam) = findName hd

transDecl x (InstDecl _ ctxt hd _) = Just (FactInstance t:kinds True t, [])
    where t = transInstHead ctxt hd

transDecl _ _ = Nothing


typeArgsPos :: HSE.Type S -> [SrcSpan]
typeArgsPos (TyForall _ _ _ x) = typeArgsPos x
typeArgsPos (TyFun _ x y) = srcInfoSpan (ann x) : typeArgsPos y
typeArgsPos (TyParen _ x) = typeArgsPos x
typeArgsPos x = [srcInfoSpan $ ann x]




cols :: SrcSpan -> (Int,Int)
cols x = (srcSpanStartColumn x - 1, srcSpanEndColumn x - 1)

findName :: Data a => a -> (SrcSpan,String)
findName x = case universeBi x of
        Ident s x : _ -> (srcInfoSpan s,x)
        Symbol s x : _ -> (srcInfoSpan s,x)

unbracket ('(':xs) | ")" `isSuffixOf` xs && nub ys `notElem` ["",","] = ys
    where ys = init xs
unbracket x = x


transType :: HSE.Type S -> Type
transType (TyForall _ _ _ x) = transType x
transType (TyFun _ x y) = TFun $ transType x : fromTFun (transType y)
transType (TyTuple _ x xs) = tApp (TLit $ "(" ++ h ++ replicate (length xs - 1) ',' ++ h ++ ")") $ map transType xs
    where h = ['#' | x == Unboxed]
transType (TyList _ x) = TApp (TLit "[]") [transType x]
transType (TyApp _ x y) = tApp a (b ++ [transType y])
    where (a,b) = fromTApp $ transType x
transType (TyVar _ x) = TVar $ prettyPrint x
transType (TyCon _ x) = TLit $ unbracket $ prettyPrint x
transType (TyParen _ x) = transType x
transType (TyInfix _ y1 x y2) = TApp (TLit $ unbracket $ prettyPrint x) [transType y1, transType y2]
transType (TyKind _ x _) = transType x


transContext :: Maybe (Context S) -> Constraint
transContext = maybe [] g
    where
        g (CxSingle _ x) = f x
        g (CxTuple _ xs) = concatMap f xs
        g (CxParen _ x) = g x
        g _ = []

        f (ClassA _ x ys) = [TApp (TLit $ unbracket $ prettyPrint x) $ map transType ys]
        f (InfixA s y1 x y2) = f $ ClassA s x [y1,y2]
        f _ = []


transTypeSig :: HSE.Type S -> TypeSig
transTypeSig (TyParen _ x) = transTypeSig x
transTypeSig (TyForall _ _ con ty) = TypeSig (transContext con) $ transType ty
transTypeSig x = TypeSig [] $ transType x


transDeclHead :: Maybe (Context S) -> DeclHead S -> TypeSig
transDeclHead x y = TypeSig (transContext x) $ f y
    where f (DHead _ name vars) = TApp (TLit $ unbracket $ prettyPrint name) $ map transVar vars
          f (DHParen _ x) = f x
          f (DHInfix s x y z) = f $ DHead s y [x,z]

transInstHead :: Maybe (Context S) -> InstHead S -> TypeSig
transInstHead x y = TypeSig (transContext x) $ f y
    where f (IHead _ name vars) = TApp (TLit $ unbracket $ prettyPrint name) $ map transType vars
          f (IHParen _ x) = f x
          f (IHInfix s x y z) = f $ IHead s y [x,z]


transVar :: TyVarBind S -> Type
transVar (KindedVar _ nam _) = TVar $ prettyPrint nam
transVar (UnkindedVar _ nam) = TVar $ prettyPrint nam





---------------------------------------------------------------------

emph = TagEmph . Str
bold = TagBold . Str
space = Str " "


-- collect the kind facts, True for the outer fact is about a class
kinds :: Bool -> TypeSig -> [Fact]
kinds cls (TypeSig x y) = concatMap (f True) x ++ f cls y
    where
        f cls (TApp (TLit c) ys) = add cls c (length ys) ++
                                   if cls then [] else concatMap (f False) ys
        f cls (TLit c) = add cls c 0
        f cls x = if cls then [] else concatMap (f False) $ children x

        add cls c i = [(if cls then FactClassKind else FactDataKind) c i | not $ isTLitTuple c]