-- |
-- Module      :  Codec.Fast.Parser
-- Copyright   :  Robin S. Krom 2011
-- License     :  BSD3
-- 
-- Maintainer  :  Robin S. Krom
-- Stability   :  experimental
-- Portability :  unknown
--
{-# LANGUAGE FlexibleContexts, GADTs, TupleSections, MultiParamTypeClasses, TypeFamilies #-}

module Codec.Fast.Parser 
(
Context (..),
initEnv,
segment',
template2P
)
where 

import Prelude hiding (dropWhile)
import qualified Data.ByteString as B
import Data.ByteString.UTF8 (toString)
import qualified Data.Attoparsec as A
import Control.Monad.State
import Control.Monad.Reader
import Control.Applicative 
import Data.Int
import Data.Word 
import qualified Data.Map as M
import Codec.Fast.Data as F
import Control.Exception


-- |Environment of the parser.
data Env = Env {
    -- |All known templates.
    templates   ::M.Map TemplateNsName Template,
    -- |The application needs to define how uint32 values are mapped to template names.
    tid2temp   ::Word32 -> TemplateNsName
    }

-- |The environment of the parser depending on the templates and
-- the tid2temp function provided by the application.
initEnv::Templates -> (Word32 -> TemplateNsName) -> Env
initEnv ts = Env (M.fromList [(tName t,t) | t <- tsTemplates ts])

type FParser a = ReaderT Env (StateT Context A.Parser) a

-- |Parses the beginning of a new segment.
segment::FParser ()
segment = presenceMap

-- |Parses presence map and template identifier.
segment'::FParser (NsName, Maybe Value)
segment' = presenceMap >> templateIdentifier

-- |Parses template identifier and returns the corresponding parser.
-- template identifier is considered a mandatory copy operator UIn32 field.
-- TODO: Check wether mandatory is right.
-- TODO: Which token should this key have, define a policy?
templateIdentifier::FParser (NsName, Maybe Value)
templateIdentifier = do
    (_ , maybe_i) <- p
    case maybe_i of
        (Just (UI32 i')) -> do 
            env <- ask
            template2P (templates env M.! tid2temp env i')
        (Just _) ->  throw $ OtherException "Coding error: templateId field must be of type I."
        Nothing -> throw $ OtherException "Failed to parse template identifier."

    where p = field2Parser (IntField (UInt32Field (FieldInstrContent 
                            (NsName (NameAttr "templateId") Nothing Nothing) 
                            (Just Mandatory) 
                            (Just (Copy (OpContext (Just (DictionaryAttr "global")) (Just (NsKey(KeyAttr (Token "tid")) Nothing)) Nothing)))
                            )))

-- |Parse PreseneceMap.
presenceMap::FParser ()
presenceMap = do
    bs <- l2 anySBEEntity
    -- update state
    st <- get
    put (Context (bsToPm bs) (dict st))

-- |Maps a template to its corresponding parser.
-- We treat a template as a group with NsName equal the TemplateNsName.
template2P :: Template -> FParser (NsName, Maybe Value)
template2P t = (tname2fname (tName t), ) <$> Just . Gr <$> mapM instr2P (tInstructions t)


-- |Maps an instruction to its corresponding parser.
instr2P :: Instruction -> FParser (NsName, Maybe Value)
instr2P (Instruction f) = field2Parser f
-- Static template reference.
instr2P (TemplateReference (Just trc)) = do
    env <- ask
    template2P (templates env M.! tempRefCont2TempNsName trc) 
-- Dynamic template reference.  
instr2P (TemplateReference Nothing) = segment'

-- |Constructs a parser out of a field. The FParser monad has underlying type
-- Maybe Primitive, the Nothing constructor represents a field that was not
-- present in the stream.
field2Parser :: Field -> FParser (NsName, Maybe Value)
field2Parser (IntField f@(Int32Field (FieldInstrContent fname _ _))) = (fname, ) <$> fmap toValue <$> (intF2P f :: FParser (Maybe Int32))
field2Parser (IntField f@(Int64Field (FieldInstrContent fname _ _))) = (fname, ) <$> fmap toValue <$> (intF2P f :: FParser (Maybe Int64))
field2Parser (IntField f@(UInt32Field (FieldInstrContent fname _ _))) = (fname, ) <$> fmap toValue <$> (intF2P f :: FParser (Maybe Word32))
field2Parser (IntField f@(UInt64Field (FieldInstrContent fname _ _))) = (fname, ) <$> fmap toValue <$> (intF2P f :: FParser (Maybe Word64))
field2Parser (DecField f@(DecimalField fname _ _ )) = (fname, ) <$> fmap toValue <$> decF2P f
field2Parser (AsciiStrField f@(AsciiStringField(FieldInstrContent fname _ _ ))) = (fname, ) <$> fmap toValue <$> asciiStrF2P f
field2Parser (UnicodeStrField f@(UnicodeStringField (FieldInstrContent fname _ _ ) _ )) = (fname, ) <$> fmap U <$> unicodeF2P f
field2Parser (ByteVecField f@(ByteVectorField (FieldInstrContent fname _ _ ) _ )) = (fname, ) <$> fmap toValue <$> bytevecF2P f
field2Parser (Seq s) = seqF2P s
field2Parser (Grp g) = groupF2P g

-- |Maps an integer field to its parser.
intF2P :: (Primitive a, Num a, Ord a,  Ord (Delta a), Num (Delta a)) => IntegerField -> FParser (Maybe a)
intF2P (Int32Field fic) = intF2P' fic 
intF2P (UInt32Field fic) = intF2P' fic 
intF2P (Int64Field fic) = intF2P' fic 
intF2P (UInt64Field fic) = intF2P' fic 

intF2P' :: (Primitive a, Num a, Ord a, Ord (Delta a), Num (Delta a)) => FieldInstrContent -> FParser (Maybe a)

-- if the presence attribute is not specified, it is mandatory.
intF2P' (FieldInstrContent fname Nothing maybe_op) = intF2P' (FieldInstrContent fname (Just Mandatory) maybe_op)
-- pm: No, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) Nothing)
    = Just <$> l2 decodeP

-- pm: No, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) Nothing)
    = nULL 
    <|> (Just . minusOne) <$> l2 decodeP

-- pm: No, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Constant iv)))
    = return $ Just(ivToPrimitive iv)

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Default (Just iv))))
    = ifPresentElse (Just <$> l2 decodeP) (return (Just(ivToPrimitive iv)))

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Default Nothing)))
    = throw $ S5 "No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent fname (Just Mandatory) (Just (Copy oc)))
    = ifPresentElse   
    (do 
        i <- l2 decodeP
        lift $ updatePrevValue fname oc (Assigned (witnessType i))
        return (Just i)
    )
    ( 
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = return (Just (ivToPrimitive iv))
                        h' (OpContext _ _ Nothing) = throw $ D5 "No initial value in operator context\
                                                          \for mandatory copy operator with undefined dictionary\
                                                          \value."
            Empty -> throw $ D6 "Previous value is empty in madatory copy operator."
    )
                            
-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent fname (Just Mandatory) (Just (Increment oc)))
    = ifPresentElse
    (
    do 
        i <- l2 decodeP
        lift $ updatePrevValue fname oc (Assigned (witnessType i))
        return (Just i)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> lift $ updatePrevValue fname oc (Assigned (witnessType v')) >> return (Just v') where v' = assertType v + 1 
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i) where i =ivToPrimitive iv
                        h' (OpContext _ _ Nothing) = throw $ D5 "No initial value in operator context given for\
                                                        \mandatory increment operator with undefined dictionary\
                                                        \value."
            Empty -> throw $ D6 "Previous value is empty in mandatory increment operator."
    )
    
-- pm: -, Nullable: -
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Tail _)))
    = throw $ S2 "Tail operator can not be applied on an integer type field." 

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Optional) (Just (Constant iv)))
    = ifPresentElse (return (Just(ivToPrimitive iv))) (return Nothing)

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) (Just (Default (Just iv))))
    = ifPresentElse (nULL <|> ((Just . minusOne) <$> l2 decodeP)) (return (Just $ ivToPrimitive iv))

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) (Just (Default Nothing)))
    = ifPresentElse (nULL <|> ((Just . minusOne) <$> l2 decodeP)) (return Nothing)

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent fname (Just Optional) (Just (Copy oc)))
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> do 
        i <- l2 decodeP
        lift $ updatePrevValue fname oc (Assigned (witnessType i))
        return (Just $ minusOne i)
    )
    (
    do
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = return $ Just (ivToPrimitive iv)
                        h' (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent fname (Just Optional) (Just (Increment oc)))
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> do 
        i <- l2 decodeP
        lift $ updatePrevValue fname oc (Assigned (witnessType i))
        return (Just $ minusOne i)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> lift $ updatePrevValue fname oc (Assigned (witnessType v')) >> Just <$> return v' where v' = assertType v + 1
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> (Just <$> return i) where i = ivToPrimitive iv
                        h' (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )


-- pm: -, Nullable: -
intF2P' (FieldInstrContent _ (Just Optional) (Just (Tail _)))
    = throw $ S2 "Tail operator can not be applied on an integer type field." 

-- pm: No, Nullable: No
intF2P' (FieldInstrContent fname (Just Mandatory) (Just (Delta oc)))
    = let   baseValue (Assigned p) = assertType p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = defaultBaseValue
            baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."

    in
        do 
            d <- l2 decodeD
            i <- flip  delta d <$> (baseValue <$> lift (prevValue fname oc))
            lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i)

-- pm: No, Nullable: Yes
intF2P' (FieldInstrContent fname (Just Optional) (Just (Delta oc)))
    = nULL
    <|> let     baseValue (Assigned p) = assertType p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                            h (OpContext _ _ Nothing) = defaultBaseValue
                baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."

        in
            do 
                d <- l2 decodeD
                i <- flip delta (minusOne d) <$> (baseValue <$> lift (prevValue fname oc))
                lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i)

-- |Maps an decimal field to its parser.
decF2P::DecimalField -> FParser (Maybe Decimal)

-- If the presence attribute is not specified, the field is considered mandatory.
decF2P (DecimalField fname Nothing maybe_either_op) 
    = decF2P (DecimalField fname (Just Mandatory) maybe_either_op)

-- pm: Np, Nullable: No
decF2P (DecimalField _ (Just Mandatory) Nothing)
    = Just <$> l2 decodeP

-- om: No, Nullable: Yes
decF2P (DecimalField _ (Just Optional) Nothing)
    = nULL
    <|> do 
            (e, m) <- l2 decodeP
            return (Just (minusOne e, m))

-- pm: No, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Just (Left (Constant iv)))) 
    = return $ Just(ivToPrimitive iv)

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Just (Left (Default Nothing))))
    = throw $ S5 "No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Just (Left (Default (Just iv)))))
    = ifPresentElse (Just <$> l2 decodeP) (return(Just(ivToPrimitive iv)))

-- pm: Yes, Nullable: No
decF2P (DecimalField fname (Just Mandatory) (Just (Left (Copy oc)))) 
    = ifPresentElse
    (
    do
        d <- l2 decodeP
        lift $ updatePrevValue fname oc (Assigned (witnessType d))
        return (Just d)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = return (Just (ivToPrimitive iv))
                        h' (OpContext _ _ Nothing) = throw $ D5 "No initial value in operator context\
                                                          \for mandatory copy operator with undefined dictionary\
                                                          \value."
            Empty -> throw $ D6 "Previous value is empty in madatory copy operator."
    )

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Just (Left (Increment _)))) 
    = throw $ S2 "Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
decF2P (DecimalField fname (Just Mandatory) (Just (Left (Delta oc)))) 
    = let   baseValue (Assigned p) = assertType p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = defaultBaseValue
            baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."

    in
        do 
            d <- l2 decodeD
            d' <- flip  delta d <$> (baseValue <$> lift (prevValue fname oc))
            lift $ updatePrevValue fname oc (Assigned (witnessType d')) >> return (Just d')

decF2P (DecimalField _ (Just Mandatory) (Just (Left (Tail _))))
    = throw $ S2 "Tail operator is only applicable to ascii, unicode and bytevector fields." 

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Optional) (Just (Left (Constant iv)))) 
    = ifPresentElse (return(Just(ivToPrimitive iv))) (return Nothing)

-- pm: Yes, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Just (Left (Default Nothing)))) 
    = ifPresentElse (nULL <|> (Just <$> l2 decodeP)) (return Nothing)

-- pm: Yes, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Just (Left (Default (Just iv))))) 
    = ifPresentElse (nULL <|> (Just <$> l2 decodeP)) (return (Just $ ivToPrimitive iv))

-- pm: Yes, Nullable: Yes
decF2P (DecimalField fname (Just Optional) (Just (Left (Copy oc)))) 
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> do
            d <- l2 decodeP
            lift $ updatePrevValue fname oc (Assigned (witnessType d))
            return (Just d)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = return $ Just (ivToPrimitive iv)
                        h' (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- pm: Yes, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Just (Left (Increment _)))) 
    = throw $ S2 "Increment operator is applicable only to integer fields."

-- pm: No, Nullable: Yes
decF2P (DecimalField fname (Just Optional) (Just (Left (Delta oc)))) 
    = nULL
    <|> let     baseValue (Assigned p) = assertType p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                            h (OpContext _ _ Nothing) = defaultBaseValue
                baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."

        in
            do 
                d <- l2 decodeD
                d' <- flip delta d <$> (baseValue <$> lift (prevValue fname oc))
                lift $ updatePrevValue fname oc (Assigned (witnessType d')) >> return (Just d')

-- pm: No, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Just (Left (Tail _)))) 
    = throw $ S2 "Tail operator is only applicable to ascii, unicode and bytevector fields." 

-- Both operators are handled individually as mandatory operators.
decF2P (DecimalField fname (Just Mandatory) (Just (Right (DecFieldOp maybe_exOp maybe_maOp)))) 
-- make fname unique for exponent and mantissa
    = let fname' = uniqueFName fname "e"
          fname'' = uniqueFName fname "m"
    in do 
        e <- intF2P (Int32Field (FieldInstrContent fname' (Just Mandatory) maybe_exOp))
        m <- intF2P (Int64Field (FieldInstrContent fname'' (Just Mandatory) maybe_maOp))
        return (h e m) where   
                        h Nothing _ = Nothing
                        h _ Nothing = Nothing
                        h (Just e') (Just m') = Just (e', m')


-- The exponent field is considered as an optional field, the mantissa field as a mandatory field.
decF2P (DecimalField fname (Just Optional) (Just (Right (DecFieldOp maybe_exOp maybe_maOp))))
-- make fname unique for exponent and mantissa
    = let fname' = uniqueFName fname "e"
          fname'' = uniqueFName fname  "m"
    in do 
        e <- intF2P (Int32Field (FieldInstrContent fname' (Just Optional) maybe_exOp))
        m <- intF2P (Int64Field (FieldInstrContent fname'' (Just Mandatory) maybe_maOp))
        return (h e m) where   
                        h Nothing _ = Nothing
                        h _ Nothing = Nothing
                        h (Just e') (Just m') = Just (e', m')

-- |Maps an ascii field to its parser.
asciiStrF2P::AsciiStringField -> FParser (Maybe AsciiString)
-- If the presence attribute is not specified, its a mandatory field.
asciiStrF2P (AsciiStringField(FieldInstrContent fname Nothing maybe_op))
    = asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) maybe_op))
-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) Nothing))
    = Just <$> l2 decodeP
-- pm: No, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) Nothing))
    = nULL
    <|> do
        str <- l2 decodeP
        return (Just (rmPreamble' str))

-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Constant iv)))) 
    = return $ Just (ivToPrimitive iv)

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default Nothing))))
    = throw $ S5 "No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default (Just iv)))))
    = ifPresentElse
    (
    do
        str <- l2 decodeP
        return $ Just (rmPreamble str)
    )
    (
     return (Just (ivToPrimitive iv))
    )

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Copy oc))))
    = ifPresentElse
    (
    do
            s <- l2 decodeP
            lift $ updatePrevValue fname oc (Assigned (witnessType s))
            return (Just (rmPreamble s))
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) =  lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i) where i = ivToPrimitive iv
                        h' (OpContext _ _ Nothing) = throw $ D5 "No initial value in operator context\
                                                          \for mandatory copy operator with undefined dictionary\
                                                          \value."
            Empty -> throw $ D6 "Previous value is empty in madatory copy operator."
    )

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Increment _))))
    = throw $ S2 "Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Delta oc))))
    = let   baseValue (Assigned p) = assertType p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = defaultBaseValue 
            baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."
    in
        do 
            str <- l2 decodeD
            str' <- flip delta str <$> (baseValue <$> lift (prevValue fname oc))
            lift $ updatePrevValue fname oc (Assigned (witnessType str')) >> return (Just str')

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Tail oc))))
    = ifPresentElse
    (
    let baseValue (Assigned p) = assertType p
        baseValue (Undefined) = h oc
            where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                    h (OpContext _ _ Nothing) = defaultBaseValue

        baseValue (Empty) = h oc
            where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                    h (OpContext _ _ Nothing) = defaultBaseValue
    in
        do
            pva <- lift $ prevValue fname oc
            t <- l2 decodeT
            return (Just (baseValue pva `ftail` t))
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h oc
                where   h (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i) where i = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = throw $ D6 "No initial value in operator context\
                                                                  \for mandatory tail operator with undefined dictionary\
                                                                  \value."
            Empty -> throw $ D7 "previous value in a mandatory tail operator can not be empty."
    )

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Constant iv)))) 
    = ifPresentElse ( return (Just (ivToPrimitive iv))) (return Nothing)

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Default Nothing))))
    = ifPresentElse (nULL <|> (Just . rmPreamble' <$> l2 decodeP)) (return Nothing)
-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Default (Just iv)))))
    = ifPresentElse (nULL <|> (Just . rmPreamble' <$> l2 decodeP)) (return (Just (ivToPrimitive iv)))

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Copy oc))))
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|>
        do 
            s <- rmPreamble' <$> l2 decodeP
            lift $ updatePrevValue fname oc (Assigned (witnessType s))
            return (Just s)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i) where i =ivToPrimitive iv
                        h' (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Increment _ ))))
    = throw $ S2 "Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Delta oc))))
    = nULL 
    <|> (let    baseValue (Assigned p) = assertType p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                            h (OpContext _ _ Nothing) = defaultBaseValue
                baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."
        in
            do 
                (Dascii d) <- l2 decodeD
                str <- flip delta (Dascii (fst d, rmPreamble' (snd d))) <$> (baseValue <$> lift (prevValue fname oc)) 
                lift $ updatePrevValue fname oc (Assigned (witnessType str)) >> return (Just str))

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Tail oc))))
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> let baseValue (Assigned p) = return (assertType p)
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToPrimitive iv)
                        h (OpContext _ _ Nothing) = return defaultBaseValue
            baseValue (Empty) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToPrimitive iv)
                        h (OpContext _ _ Nothing) = return defaultBaseValue
        in
            do
                bv <- lift $ prevValue fname oc >>= baseValue
                t <- rmPreamble' <$> l2 decodeT
                return (Just (bv `ftail` t))
    )
    (
    do
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h oc
                where   h (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType i)) >> return (Just i) where i = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- |Maps a bytevector field to its parser.
bytevecF2P::ByteVectorField -> FParser (Maybe B.ByteString)
bytevecF2P (ByteVectorField (FieldInstrContent fname Nothing maybe_op) len) 
    = bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) maybe_op) len)

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Mandatory) Nothing ) _ ) 
    = Just <$> l2 decodeP

-- pm: No, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Optional) Nothing ) _ ) 
    = nULL
    <|> do
        bv <- l2 decodeP
        return $ Just bv

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Mandatory) (Just (Constant iv))) _ ) 
    = return $ Just (ivToPrimitive iv)

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Optional) (Just(Constant iv))) _ ) 
    = ifPresentElse (return (Just (ivToPrimitive iv))) (return Nothing)
-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Default Nothing))) _ ) 
    = throw $ S5 "No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Default (Just iv)))) _ ) 
    = ifPresentElse
    (
    do
        bv <- l2 decodeP
        return (Just bv)
    )
    (
    return (Just (ivToPrimitive iv))
    )

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Optional) (Just(Default Nothing))) _ ) 
    = ifPresentElse (nULL <|> (Just <$> l2 decodeP)) (return Nothing)
-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Optional) (Just(Default (Just iv)))) _ ) 
    = ifPresentElse (nULL <|> Just <$> l2 decodeP) (return (Just (ivToPrimitive iv)))
-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Copy oc))) _ ) 
    = ifPresentElse   
    (
    do
        bv <- l2 decodeP 
        lift $ updatePrevValue fname oc (Assigned (witnessType bv))
        return (Just bv)
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v)) 
            Undefined ->  h' oc
                where   h' (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType bv)) >> return (Just bv) where bv = ivToPrimitive iv 
                        h' (OpContext _ _ Nothing) = throw $ D5 "No initial value in operator context\
                                                          \for mandatory copy operator with undefined dictionary\
                                                          \value."
            Empty -> throw $ D6 "Previous value is empty in madatory copy operator."
    )
-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Copy oc))) _ ) 
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> do
            bv <- l2 decodeP
            lift $ updatePrevValue fname oc (Assigned (witnessType bv))
            return (Just bv)
    )
    (
    do
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v)) 
            Undefined -> h' oc
                where   h' (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType bv)) >> return (Just bv) where bv = ivToPrimitive iv
                        h' (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Increment _ ))) _ ) 
    = throw $ S2 "Increment operator is only applicable to integer fields." 
-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent _ (Just Optional) (Just(Increment _ ))) _ ) 
    = throw $ S2 "Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Delta oc))) _ ) 
    = let   baseValue (Assigned p) = assertType p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = defaultBaseValue
            baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."
    in
        do 
            bv <- l2 decodeD
            Just <$> (flip delta bv <$> (baseValue <$> lift (prevValue fname oc)))

-- pm: No, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Delta oc))) _ ) 
    = nULL
    <|> (let    baseValue (Assigned p) = assertType p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                            h (OpContext _ _ Nothing) = defaultBaseValue
                baseValue (Empty) = throw $ D6 "previous value in a delta operator can not be empty."
        in
            do 
                bv <- l2 decodeD
                bv' <- flip delta bv <$> (baseValue <$> lift (prevValue fname oc))
                lift $ updatePrevValue fname oc (Assigned (witnessType bv')) >> return (Just bv'))


-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Tail oc))) _ ) 
    = ifPresentElse
    (
    let baseValue (Assigned p) = assertType p
        baseValue (Undefined) = h oc
            where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                    h (OpContext _ _ Nothing) = defaultBaseValue

        baseValue (Empty) = h oc
            where   h (OpContext _ _ (Just iv)) = ivToPrimitive iv
                    h (OpContext _ _ Nothing) = defaultBaseValue
    in
        do
            pva <- lift $ prevValue fname oc
            t <- l2 decodeT
            return (Just(baseValue pva `ftail` t))
    )
    (
    do
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h oc
                where   h (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType bv)) >> return (Just bv) where bv = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = throw $ D6 "No initial value in operator context\
                                                  \for mandatory tail operator with undefined dictionary\
                                                  \value."
            Empty -> throw $ D7 "previous value in a mandatory tail operator can not be empty."
    )

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Tail oc))) _ ) 
    = ifPresentElse
    (
    nULL *> lift (updatePrevValue fname oc Empty >> return Nothing)
    <|> let baseValue (Assigned p) = return (assertType p)
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToPrimitive iv)
                        h (OpContext _ _ Nothing) = return defaultBaseValue
            baseValue (Empty) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToPrimitive iv)
                        h (OpContext _ _ Nothing) = return defaultBaseValue
        in
            do
                bv <- lift $ prevValue fname oc >>= baseValue
                t <- l2 decodeT
                return (Just (bv `ftail` t))
    )
    (
    do 
        p <- lift $ prevValue fname oc
        case p of
            (Assigned v) -> return (Just (assertType v))
            Undefined -> h oc
                where   h (OpContext _ _ (Just iv)) = lift $ updatePrevValue fname oc (Assigned (witnessType bv)) >> return (Just bv) where bv = ivToPrimitive iv
                        h (OpContext _ _ Nothing) = lift $ updatePrevValue fname oc Empty >> return Nothing
            Empty -> return Nothing
    )

-- |Maps an unicode field to its parser.
unicodeF2P::UnicodeStringField -> FParser (Maybe UnicodeString)
unicodeF2P (UnicodeStringField (FieldInstrContent fname maybe_presence maybe_op) maybe_length)
    = do 
        m_bv <- bytevecF2P (ByteVectorField (FieldInstrContent fname maybe_presence maybe_op) maybe_length)
        return (fmap toString m_bv) -- Maybe is itself a monad.

-- |Maps a sequence field to its parser.
seqF2P::Sequence -> FParser (NsName, Maybe Value)
seqF2P (Sequence fname maybe_presence _ _ maybe_length instrs) 
    = do 
        i <- h maybe_presence maybe_length
        g i
        where   g Nothing = return (fname, Nothing)
                g (Just i') = do
                                    env <- ask
                                    s <- A.count (fromEnum i') (when (needsSegment instrs (templates env)) segment >> mapM instr2P instrs) 
                                    return (fname, Just (Sq i' s))
                -- get the correct parser for the length field.
                fname' = uniqueFName fname "l" 
                h p Nothing = intF2P (UInt32Field (FieldInstrContent fname' p Nothing))
                h p (Just (Length Nothing op)) = intF2P (UInt32Field (FieldInstrContent fname' p op))
                h p (Just (Length (Just fn) op)) = intF2P (UInt32Field (FieldInstrContent fn p op))
                
-- |Maps a group field to its parser.
groupF2P::Group -> FParser (NsName, Maybe Value)
groupF2P (Group fname Nothing maybe_dict maybe_typeref instrs)
    = groupF2P (Group fname (Just Mandatory) maybe_dict maybe_typeref instrs)

groupF2P (Group fname (Just Mandatory) _ _ instrs) 
    = ask >>= \env -> (fname,) . Just . Gr <$> (when (any (needsPm (templates env)) instrs) segment >> mapM instr2P instrs)

groupF2P (Group fname (Just Optional) _ _ instrs) 
    = ifPresentElse 
    (ask >>= \env -> (fname,) . Just . Gr <$> (when (any (needsPm (templates env)) instrs) segment >> mapM instr2P instrs)) 
    (return (fname, Nothing))

-- |nULL parser.
nULL :: FParser (Maybe a)
nULL = l2 nULL'
    where nULL' = do 
            -- discard result.
            _ <- A.word8 0x80
            return Nothing
    

ifPresentElse::FParser a -> FParser a -> FParser a
ifPresentElse p1 p2 = do 
                        s <- get
                        put (Context (tail (pm s)) (dict s))
                        let pmap = pm s in
                            if head pmap 
                            then p1
                            else p2

-- |Decrement the value of an integer, when it is positive.
minusOne::(Ord a, Num a) => a -> a
minusOne x | x > 0 = x - 1
minusOne x = x

l2 :: A.Parser a -> FParser a
l2 = lift . lift
