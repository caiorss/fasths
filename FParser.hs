-- |A FAST protocoll parser.
module FParser where 

import Prelude as P
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as U
import Data.ByteString.Internal (c2w, w2c)
import Data.Char (ord)
import qualified Data.Attoparsec.Char8 as A
import Control.Monad.State
import Control.Applicative 
import Data.Bits
import Data.Word (Word8)
import FAST


-- |Proviosonal state of the parser, will be changed according to reference.
data FState = FState {
    -- |bitmap
    pm  ::[Bool]
    } deriving (Show)

type FParser a = StateT FState A.Parser a

data FValue = I Int
              |S String
              |D Double
              |BS B.ByteString
              |Sq Int [[(NsName, Maybe FValue)]]
              |Gr [(NsName, Maybe FValue)]

p2FValue::Primitive -> FValue
p2FValue (Int32 i) = I i
p2FValue (UInt32 i) = I i
p2FValue (Int64 i) = I i
p2FValue (UInt64 i) = I i
p2FValue (Ascii s) = S s
p2FValue (Unicode s) = S s
p2FValue (Decimal (Int32 e) (Int64 m)) = D (10^e * fromIntegral m)
p2FValue (Bytevector bs) = BS bs

-- |Make StateT s m an instance of Applicative, such that FParser becomes an
-- instance of Applicative.
{-instance (Monad m) => Applicative (StateT s m) where-}
    {-pure = return-}
    {-(<*>) = ap-}

{--- |Make StateT s p an instance of Alternative, such that FParser becomes an -}
{--- instance of Alternative.-}
{-instance (Alternative p, MonadPlus p) => Alternative (StateT s p) where-}
    {-empty = lift $ empty-}
    {-(<|>) = mplus-}

-- |Parse PreseneceMap.
presenceMap::FParser ()
presenceMap = do
    bs <- anySBEEntity
    -- update state
    put FState {pm = bsToPm bs}

-- |Get a Stopbit encoded entity.
anySBEEntity::FParser B.ByteString
anySBEEntity = lift (takeTill' stopBitSet)

-- |Test wether the stop bit is set of a Char. (Note: Chars are converted to
-- Word8's. 
-- TODO: Is this unsafe?
stopBitSet::Char -> Bool
stopBitSet c = testBit (c2w c) 8

-- |Like takeTill, but takes the matching byte as well.
takeTill'::(Char -> Bool) -> A.Parser B.ByteString
takeTill' f = do
    str <- A.takeTill f
    c <- A.take 1
    return (str `B.append` c)

previousValue::NsName -> OpContext -> Primitive
previousValue = undefined

-- |Translates a template reference into the correct template.
tr2Template::Maybe TemplateReferenceContent -> Template
tr2Template = undefined

template2P::Template -> FParser (NsName, Maybe FValue)
template2P = undefined

-- |Maps an instruction to its corresponding parser.
instr2P::Instruction -> FParser (NsName, Maybe FValue)
instr2P (Instruction f) = fieldToParser f
instr2P (TemplateReference maybe_trc) =  template2P $ tr2Template maybe_trc

-- |Constructs a parser out of a field. The FParser monad has underlying type
-- Maybe Primitive, the Nothing constructor represents a field that was not
-- present in the stream.
fieldToParser::Field -> FParser (NsName, Maybe FValue)
fieldToParser (IntField f@(Int32Field (FieldInstrContent fname _ _))) = (fname, ) <$> (fmap p2FValue) <$> intF2P f
fieldToParser (IntField f@(Int64Field (FieldInstrContent fname _ _))) = (fname, ) <$> (fmap p2FValue) <$> intF2P f
fieldToParser (IntField f@(UInt32Field (FieldInstrContent fname _ _))) = (fname, ) <$> (fmap p2FValue) <$> intF2P f
fieldToParser (IntField f@(UInt64Field (FieldInstrContent fname _ _))) = (fname, ) <$> (fmap p2FValue) <$> intF2P f
fieldToParser (DecField f@(DecimalField fname _ _ )) = (fname, ) <$> (fmap p2FValue) <$> decF2P f
fieldToParser (AsciiStrField f@(AsciiStringField(FieldInstrContent fname _ _ ))) = (fname, ) <$> (fmap p2FValue) <$> asciiStrF2P f
fieldToParser (UnicodeStrField f@(UnicodeStringField (FieldInstrContent fname _ _ ) _ )) = (fname, ) <$> (fmap p2FValue) <$> unicodeF2P f
fieldToParser (ByteVecField f@(ByteVectorField (FieldInstrContent fname _ _ ) _ )) = (fname, ) <$> (fmap p2FValue) <$> bytevecF2P f
fieldToParser (Seq s) = seqF2P s
fieldToParser (Grp g) = groupF2P g

-- |Maps an integer field to its parser.
intF2P::IntegerField -> FParser (Maybe Primitive)
-- Delta operator needs delta parser!
intF2P (Int32Field fic@(FieldInstrContent _ _ (Just (Delta _)))) = intF2P'' fic int32Delta ivToUInt32 dfbUInt32
intF2P (Int32Field fic) = intF2P' fic int32 ivToInt32 dfbInt32
intF2P (UInt32Field fic@(FieldInstrContent _ _ (Just (Delta _)))) = intF2P'' fic int32Delta ivToUInt32 dfbUInt32
intF2P (UInt32Field fic) = intF2P' fic uint32 ivToUInt32 dfbUInt32
intF2P (Int64Field fic@(FieldInstrContent _ _ (Just (Delta _)))) = intF2P'' fic int64Delta ivToUInt32 dfbUInt32
intF2P (Int64Field fic) = intF2P' fic int64 ivToInt64 dfbInt64
intF2P (UInt64Field fic@(FieldInstrContent _ _ (Just (Delta _)))) = intF2P'' fic int64Delta ivToUInt32 dfbUInt32
intF2P (UInt64Field fic) = intF2P' fic uint64 ivToUInt64 dfbUInt64

-- |Maps an integer field to a parser, given the field instruction context, the 
-- raw integer parser,a function to convert initial values to the given 
-- primitive and a default base value for default operators.
intF2P'::FieldInstrContent
        -> FParser Primitive 
        -> (InitialValueAttr -> Primitive)  
        -> Primitive
        -> FParser (Maybe Primitive)

-- Every possible case for the Int32 field.

-- if the presence attribute is not specified, it is mandatory.
intF2P' (FieldInstrContent fname Nothing maybe_op) intParser ivToInt defaultBaseValue 
    = intF2P' (FieldInstrContent fname (Just Mandatory) maybe_op) intParser ivToInt defaultBaseValue
-- pm: No, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) Nothing) intParser ivToInt _
    = Just <$> intParser

-- pm: No, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) Nothing) intParser ivToInt _
    = nULL 
    <|> (Just . minusOne) <$> intParser

-- pm: No, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Constant iv))) intParser ivToInt _
    = return $ Just(ivToInt iv)

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Default (Just iv)))) intParser ivToInt _
    = (notPresent *> (return $ Just(ivToInt iv))) 
        <|> Just <$> intParser

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Default (Nothing)))) _ _ _
    = error "S5: No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent fname (Just Mandatory) (Just (Copy oc))) intParser ivToInt _
    =   (notPresent *>  
            (let 
                h (Assigned p) = Just p
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = Just (ivToInt iv)
                            h' (OpContext _ _ Nothing) = error "D5: No initial value in operator context\
                                                              \for mandatory copy operator with undefined dictionary\
                                                              \value."
                h (Empty) = error "D6: Previous value is empty in madatory copy operator."
            in 
                (prevValue fname oc) >>= return . h 
            )
        )
        <|> Just <$> ((Assigned <$> intParser) >>= updatePrevValue fname oc)
                            
-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent fname (Just Mandatory) (Just (Increment oc))) intParser ivToInt _
    = (notPresent *> 
        (let 
            h (Assigned p) = Just <$> (return (Assigned(inc p)) >>= (updatePrevValue fname oc))
            h (Undefined) = h' oc
                where   h' (OpContext _ _ (Just iv)) = Just <$> (return (Assigned(ivToInt iv)) >>= (updatePrevValue fname oc))
                        h' (OpContext _ _ Nothing) = error "D5: No initial value in operator context given for\
                                                        \mandatory increment operator with undefined dictionary\
                                                        \value."
            h (Empty) = error "D6: Previous value is empty in mandatory increment operator."
          in
            (prevValue fname oc) >>= h
        )
    )
    <|> Just <$> ((Assigned <$> (intParser)) >>= updatePrevValue fname oc)


    
-- pm: -, Nullable: -
intF2P' (FieldInstrContent _ (Just Mandatory) (Just (Tail iv))) _ _ _
    = error "S2: Tail operator can not be applied on an integer type field." 

-- pm: Yes, Nullable: No
intF2P' (FieldInstrContent _ (Just Optional) (Just (Constant iv))) _ ivToInt _
    = (notPresent *> (return $ Nothing))
    <|> (return $ Just(ivToInt iv))

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) (Just (Default (Just iv)))) intParser ivToInt _
    = (notPresent *> (return $ Just $ (ivToInt iv)))
    <|> nULL
    <|> (Just <$> intParser)

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent _ (Just Optional) (Just (Default Nothing))) intParser _ _
    = (notPresent *> return Nothing)
    <|> nULL
    <|> (Just <$> intParser)

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent fname (Just Optional) (Just (Copy oc))) intParser ivToInt _
    =   (notPresent *>  
            (let 
                h (Assigned p) = return $ Just p
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = return $ Just (ivToInt iv)
                            h' (OpContext _ _ Nothing) = updatePrevValue fname oc Empty >> (return $ Nothing)  
                h (Empty) = return $ Nothing
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> nULL <* updatePrevValue fname oc Empty
        <|> Just <$> (Assigned <$> intParser >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: Yes
intF2P' (FieldInstrContent fname (Just Optional) (Just (Increment oc))) intParser ivToInt _
    = (notPresent *> 
        (let 
            h (Assigned p) = Just <$> (return (Assigned(inc p)) >>= (updatePrevValue fname oc))
            h (Undefined) = h' oc
                where   h' (OpContext _ _ (Just iv)) = Just <$> (return (Assigned(ivToInt iv)) >>= (updatePrevValue fname oc))
                        h' (OpContext _ _ Nothing) = updatePrevValue fname oc Empty >> (return $ Nothing) 
            h (Empty) = return Nothing
         in
            (prevValue fname oc) >>= h
        )
    )
    <|> nULL <* updatePrevValue fname oc Empty
    <|> Just <$> ((Assigned <$> (intParser)) >>= updatePrevValue fname oc)


-- pm: -, Nullable: -
intF2P' (FieldInstrContent _ (Just Optional) (Just (Tail iv))) _ _ _
    = error "S2: Tail operator can not be applied on an integer type field." 

-- |Maps an integer field with delta operator to a parser, given the field instruction context, the 
-- integer delta parser,a function to convert initial values to the given 
-- primitive and a default base value for default operators.
intF2P''::FieldInstrContent
        -> FParser Delta
        -> (InitialValueAttr -> Primitive)  
        -> Primitive
        -> FParser (Maybe Primitive)

-- pm: No, Nullable: No
intF2P'' (FieldInstrContent fname (Just Mandatory) (Just (Delta oc))) deltaParser ivToInt defaultBaseValue
    = let   baseValue (Assigned p) = p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToInt iv
                        h (OpContext _ _ Nothing) = defaultBaseValue
            baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."

    in
        do 
            d <- deltaParser
            Just <$> (((flip  delta) d) <$> (baseValue <$> (prevValue fname oc)))

-- pm: No, Nullable: Yes
intF2P'' (FieldInstrContent fname (Just Optional) (Just (Delta oc))) deltaParser ivToInt defaultBaseValue
    = nULL
    <|> let     baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToInt iv
                            h (OpContext _ _ Nothing) = defaultBaseValue
                baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."

        in
            do 
                d <- deltaParser
                Just <$> (((flip  delta) d) <$> (baseValue <$> (prevValue fname oc)))

-- |Maps an decimal field to its parser.
decF2P::DecimalField -> FParser (Maybe Primitive)

-- If the presence attribute is not specified, the field is considered mandatory.
decF2P (DecimalField fname Nothing either_op) 
    = decF2P (DecimalField fname (Just Mandatory) either_op)

-- pm: No, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Left (Constant iv))) 
    = return $ Just(ivToDec iv)

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Left (Default Nothing))) 
    = error "S5: No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Mandatory) (Left (Default (Just iv)))) 
    = (notPresent *> (return $ Just(ivToDec iv)))
    <|> (Just <$> dec)

-- pm: Yes, Nullable: No
decF2P (DecimalField fname (Just Mandatory) (Left (Copy oc))) 
    =   (notPresent *>  
            (let 
                h (Assigned p) = Just p
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = Just (ivToDec iv)
                            h' (OpContext _ _ Nothing) = error "D5: No initial value in operator context\
                                                              \for mandatory copy operator with undefined dictionary\
                                                              \value."
                h (Empty) = error "D6: Previous value is empty in madatory copy operator."
            in 
                (prevValue fname oc) >>= return . h 
            )
        )
        <|> Just <$> ((Assigned <$> dec) >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: No
decF2P (DecimalField fname (Just Mandatory) (Left (Increment oc))) 
    = error "S2:Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
decF2P (DecimalField fname (Just Mandatory) (Left (Delta oc))) 
    = let   baseValue (Assigned p) = p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToDec iv
                        h (OpContext _ _ Nothing) = dfbDecimal
            baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."

    in
        do 
            d <- decDelta
            Just <$> (((flip  delta) d) <$> (baseValue <$> (prevValue fname oc)))

decF2P (DecimalField _ (Just Mandatory) (Left (Tail oc))) 
    = error "S2:Tail operator is only applicable to ascii, unicode and bytevector fields." 

-- pm: Yes, Nullable: No
decF2P (DecimalField _ (Just Optional) (Left (Constant iv))) 
    = (notPresent *> (return $ Nothing))
    <|> (return $ Just(ivToDec iv))

-- pm: Yes, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Left (Default Nothing))) 
    = (notPresent *> return Nothing)
    <|> nULL
    <|> (Just <$> dec)

-- pm: Yes, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Left (Default (Just iv)))) 
    = (notPresent *> (return $ Just $ (ivToDec iv)))
    <|> nULL
    <|> (Just <$> dec)

-- pm: Yes, Nullable: Yes
decF2P (DecimalField fname (Just Optional) (Left (Copy oc))) 
    =   (notPresent *>  
            (let 
                h (Assigned p) = return $ Just p
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = return $ Just (ivToDec iv)
                            h' (OpContext _ _ Nothing) = updatePrevValue fname oc Empty >> (return $ Nothing)  
                h (Empty) = return $ Nothing
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> nULL <* updatePrevValue fname oc Empty
        <|> Just <$> (Assigned <$> dec >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: Yes
decF2P (DecimalField fname (Just Optional) (Left (Increment oc))) 
    = error "S2: Increment operator is applicable only to integer fields."

-- pm: No, Nullable: Yes
decF2P (DecimalField fname (Just Optional) (Left (Delta oc))) 
    = nULL
    <|> let     baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToDec iv
                            h (OpContext _ _ Nothing) = dfbDecimal
                baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."

        in
            do 
                d <- decDelta
                Just <$> (((flip  delta) d) <$> (baseValue <$> (prevValue fname oc)))

-- pm: No, Nullable: Yes
decF2P (DecimalField _ (Just Optional) (Left (Tail oc))) 
    = error "S2:Tail operator is only applicable to ascii, unicode and bytevector fields." 

-- Both operators are handled individually as mandatory operators.
decF2P (DecimalField fname (Just Mandatory) (Right (DecFieldOp ex_op ma_op))) 
-- make fname unique for exponent and mantissa
    = let fname' = uniqueFName fname "e"
          fname'' = uniqueFName fname "m"
    in do 
        e <- (intF2P (Int32Field (FieldInstrContent (fname') (Just Mandatory) (Just ex_op))))
        m <- (intF2P (Int64Field (FieldInstrContent (fname'') (Just Mandatory) (Just ma_op))))
        return (h e m) where   
                        h Nothing _ = Nothing
                        h _ Nothing = Nothing
                        h (Just (Int32 e')) (Just m') = Just (Decimal (Int32 (checkRange decExpRange e')) m')


-- The exponent field is considered as an optional field, the mantissa field as a mandatory field.
decF2P (DecimalField fname (Just Optional) (Right (DecFieldOp ex_op ma_op)))
-- make fname unique for exponent and mantissa
    = let fname' = uniqueFName fname "e"
          fname'' = uniqueFName fname  "m"
    in do 
        e <- (intF2P (Int32Field (FieldInstrContent fname' (Just Optional) (Just ex_op))))
        m <- (intF2P (Int64Field (FieldInstrContent fname'' (Just Mandatory) (Just ma_op))))
        return (h e m) where   
                        h Nothing _ = Nothing
                        h _ Nothing = Nothing
                        h (Just (Int32 e')) (Just m') = Just (Decimal (Int32 (checkRange decExpRange e')) m')

-- |Maps an ascii field to its parser.
asciiStrF2P::AsciiStringField -> FParser (Maybe Primitive)
-- If the presence attribute is not specified, its a mandatory field.
asciiStrF2P (AsciiStringField(FieldInstrContent fname Nothing maybe_op))
    = asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) maybe_op))
-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) Nothing))
    = Just <$> asciiString
-- pm: No, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) Nothing))
    = nULL
    <|> do
        str <- asciiString'
        return $ Just str

-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Constant iv)))) 
    = return $ Just (ivToAscii iv)

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default Nothing))))
    = error "S5: No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default (Just iv)))))
    = notPresent *> (return $ Just (ivToAscii iv))
    <|> do
        str <- asciiString 
        return $ Just (rmPreamble str)

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Copy oc))))
    =   (notPresent *>  
            (let 
                h (Assigned p) = return (Just p)
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) =  Just <$> (updatePrevValue fname oc (Assigned (ivToAscii iv)))
                            h' (OpContext _ _ Nothing) = error "D5: No initial value in operator context\
                                                              \for mandatory copy operator with undefined dictionary\
                                                              \value."
                h (Empty) = error "D6: Previous value is empty in madatory copy operator."
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> Just <$> ((Assigned <$> byteVector) >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Increment oc))))
    = error "S2:Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Delta oc))))
    = let   baseValue (Assigned p) = p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToAscii iv
                        h (OpContext _ _ Nothing) = dfbAscii
            baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."
    in
        do 
            str <- asciiDelta
            Just <$> (((flip  delta) str) <$> (baseValue <$> (prevValue fname oc)))

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Mandatory) (Just (Tail oc))))
    = notPresent *> (let    baseValue (Assigned p) = return (Just p)
                            baseValue (Undefined) = h oc
                                where   h (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToAscii iv)))
                                        h (OpContext _ _ Nothing) = error "D6: No initial value in operator context\
                                                              \for mandatory tail operator with undefined dictionary\
                                                              \value."
                            baseValue (Empty) = error "D7: previous value in a mandatory tail operator can not be empty."
                    in
                        (prevValue fname oc) >>= baseValue)
    <|> (let    baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToAscii iv
                            h (OpContext _ _ Nothing) = dfbAscii

                baseValue (Empty) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToAscii iv
                            h (OpContext _ _ Nothing) = dfbAscii
        in
            do
                pv <- (prevValue fname oc)
                t <- asciiTail
                return (Just((baseValue pv) `FAST.tail` t)))

-- pm: Yes, Nullable: No
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Constant iv)))) 
    = (notPresent *> (return $ Nothing))
    <|> (return $ Just(ivToAscii iv))

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Default Nothing))))
    = (notPresent *> (return Nothing))
    <|> nULL
    <|> (Just <$> asciiString')

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Default (Just iv)))))
    = notPresent *> (return $ Just (ivToAscii iv))
    <|> nULL
    <|> Just <$> asciiString'

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Copy oc))))
    =   (notPresent *>  
            (let 
                h (Assigned p) = return (Just p)
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToAscii iv)))
                            h' (OpContext _ _ Nothing) = (updatePrevValue fname oc Empty) >> return Nothing
                h (Empty) = return Nothing
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> (nULL *> (updatePrevValue fname oc Empty >> return Nothing))
        <|> Just <$> ((Assigned <$> asciiString') >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Increment oc))))
    = error "S2:Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Delta oc))))
    = nULL 
    <|> (let    baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToAscii iv
                            h (OpContext _ _ Nothing) = dfbAscii
                baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."
        in
            do 
                str <- asciiDelta'
                Just <$> (((flip  delta) str) <$> (baseValue <$> (prevValue fname oc))))

-- pm: Yes, Nullable: Yes
asciiStrF2P (AsciiStringField(FieldInstrContent fname (Just Optional) (Just (Tail oc))))
    = notPresent *> (let    baseValue (Assigned p) = return (Just p)
                            baseValue (Undefined) = h oc
                                where   h (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToAscii iv)))
                                        h (OpContext _ _ Nothing) = (updatePrevValue fname oc Empty) >> return Nothing
                            baseValue (Empty) = return Nothing
                    in
                        (prevValue fname oc) >>= baseValue)
    <|> (nULL >> updatePrevValue fname oc Empty >> return Nothing)
    <|> let baseValue (Assigned p) = return p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToAscii iv)
                        h (OpContext _ _ Nothing) = return dfbAscii
            baseValue (Empty) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToAscii iv)
                        h (OpContext _ _ Nothing) = return dfbAscii
        in
            do
                bv <- (prevValue fname oc) >>= baseValue
                t <- asciiString'
                return (Just (bv `FAST.tail` (AsciiTail t)))

-- |Maps a bytevector field to its parser.
bytevecF2P::ByteVectorField -> FParser (Maybe Primitive)
bytevecF2P (ByteVectorField (FieldInstrContent fname Nothing maybe_op) length) 
    = bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) maybe_op) length)

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) Nothing ) length) 
    = Just <$> byteVector

-- pm: No, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) Nothing ) length) 
    = nULL
    <|> do
        bv <- byteVector
        return $ Just bv

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just (Constant iv))) length) 
    = return $ Just (ivToByteVector iv)

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Constant iv))) length) 
    = (notPresent *> (return $ Nothing))
    <|> (return $ Just(ivToByteVector iv))

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Default Nothing))) length) 
    = error "S5: No initial value given for mandatory default operator."

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Default (Just iv)))) length) 
    = notPresent *> (return $ Just (ivToByteVector iv))
    <|> do
        bv <- byteVector
        return $ Just (bv)

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Default Nothing))) length) 
    = (notPresent *> (return Nothing))
    <|> nULL
    <|> (Just <$> byteVector)

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Default (Just iv)))) length) 
    = notPresent *> (return $ Just (ivToByteVector iv))
    <|> nULL
    <|> Just <$> byteVector

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Copy oc))) length) 
    =   (notPresent *>  
            (let 
                h (Assigned p) = return (Just p)
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) =  Just <$> (updatePrevValue fname oc (Assigned (ivToByteVector iv)))
                            h' (OpContext _ _ Nothing) = error "D5: No initial value in operator context\
                                                              \for mandatory copy operator with undefined dictionary\
                                                              \value."
                h (Empty) = error "D6: Previous value is empty in madatory copy operator."
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> Just <$> ((Assigned <$> byteVector) >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Copy oc))) length) 
    =   (notPresent *>  
            (let 
                h (Assigned p) = return (Just p)
                h (Undefined) = h' oc
                    where   h' (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToByteVector iv)))
                            h' (OpContext _ _ Nothing) = (updatePrevValue fname oc Empty) >> return Nothing
                h (Empty) = return Nothing
            in 
                (prevValue fname oc) >>= h 
            )
        )
        <|> (nULL *> (updatePrevValue fname oc Empty >> return Nothing))
        <|> Just <$> ((Assigned <$> byteVector) >>= updatePrevValue fname oc)

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Increment oc))) length) 
    = error "S2:Increment operator is only applicable to integer fields." 
-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Increment oc))) length) 
    = error "S2:Increment operator is only applicable to integer fields." 

-- pm: No, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Delta oc))) length) 
    = let   baseValue (Assigned p) = p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = ivToByteVector iv
                        h (OpContext _ _ Nothing) = dfbByteVector
            baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."
    in
        do 
            bv <- byteVectorDelta
            Just <$> (((flip  delta) bv) <$> (baseValue <$> (prevValue fname oc)))

-- pm: No, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Delta oc))) length) 
    = nULL
    <|> (let    baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToByteVector iv
                            h (OpContext _ _ Nothing) = dfbByteVector
                baseValue (Empty) = error "D6: previous value in a delta operator can not be empty."
        in
            do 
                bv <- byteVectorDelta
                Just <$> (((flip  delta) bv) <$> (baseValue <$> (prevValue fname oc))))

-- pm: Yes, Nullable: No
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Mandatory) (Just(Tail oc))) length) 
    = notPresent *> (let    baseValue (Assigned p) = return (Just p)
                            baseValue (Undefined) = h oc
                                where   h (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToByteVector iv)))
                                        h (OpContext _ _ Nothing) = error "D6: No initial value in operator context\
                                                              \for mandatory tail operator with undefined dictionary\
                                                              \value."
                            baseValue (Empty) = error "D7: previous value in a mandatory tail operator can not be empty."
                    in
                        (prevValue fname oc) >>= baseValue)
    <|> (let    baseValue (Assigned p) = p
                baseValue (Undefined) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToByteVector iv
                            h (OpContext _ _ Nothing) = dfbByteVector

                baseValue (Empty) = h oc
                    where   h (OpContext _ _ (Just iv)) = ivToAscii iv
                            h (OpContext _ _ Nothing) = dfbByteVector
        in
            do
                pv <- prevValue fname oc
                t <- bytevectorTail
                return (Just((baseValue pv) `FAST.tail` t)))

-- pm: Yes, Nullable: Yes
bytevecF2P (ByteVectorField (FieldInstrContent fname (Just Optional) (Just(Tail oc))) length) 
    = notPresent *> (let    baseValue (Assigned p) = return (Just p)
                            baseValue (Undefined) = h oc
                                where   h (OpContext _ _ (Just iv)) = Just <$> (updatePrevValue fname oc (Assigned (ivToByteVector iv)))
                                        h (OpContext _ _ Nothing) = (updatePrevValue fname oc Empty) >> return Nothing
                            baseValue (Empty) = return Nothing
                    in
                        (prevValue fname oc) >>= baseValue)
    <|> (nULL >> updatePrevValue fname oc Empty >> return Nothing)
    <|> let baseValue (Assigned p) = return p
            baseValue (Undefined) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToByteVector iv)
                        h (OpContext _ _ Nothing) = return dfbByteVector
            baseValue (Empty) = h oc
                where   h (OpContext _ _ (Just iv)) = return (ivToByteVector iv)
                        h (OpContext _ _ Nothing) = return dfbByteVector
        in
            do
                bv <- (prevValue fname oc) >>= baseValue
                t <- bytevectorTail
                return (Just (bv `FAST.tail` t))

-- |Maps an unicode field to its parser.
unicodeF2P::UnicodeStringField -> FParser (Maybe Primitive)
unicodeF2P (UnicodeStringField (FieldInstrContent fname maybe_presence maybe_op) maybe_length)
    = h <$> bytevecF2P (ByteVectorField (FieldInstrContent fname maybe_presence maybe_op) maybe_length)
        where   h (Just (Bytevector bv)) = Just (Unicode (U.toString bv))
                h (Nothing) = Nothing

-- |Maps a sequence field to its parser.
seqF2P::Sequence -> FParser (NsName, Maybe FValue)
seqF2P (Sequence fname maybe_presence maybe_dict maybe_typeref maybe_length instrs) 
    = do 
        i <- (h maybe_presence maybe_length)
        g i
        where   g Nothing = return (fname, Nothing)
                g (Just (Int32 i')) = do
                                        s <- (A.count i' (sequence (map instr2P instrs)))
                                        return (fname, Just (Sq i' s))
                -- get the correct parser for the length field.
                fname' = uniqueFName fname "l" 
                h p Nothing = intF2P (Int32Field (FieldInstrContent fname' p Nothing))
                h p (Just (Length Nothing op)) = intF2P (Int32Field (FieldInstrContent fname' p op))
                h p (Just (Length (Just fn) op)) = intF2P (Int32Field (FieldInstrContent fn p op))
                
-- |Maps a group field to its parser.
groupF2P::Group -> FParser (NsName, Maybe FValue)
groupF2P (Group fname maybe_presence maybe_dict maybe_typeref instrs) 
    = (fname,) . Just . Gr <$> (sequence (map instr2P instrs))

-- *Previous value related functions.

-- |Get previous value.
prevValue::NsName -> OpContext -> FParser DictValue
prevValue = undefined

-- *Raw Parsers for basic FAST primitives
-- These parsers are unaware of nullability, presence map, deltas etc.

-- |Checks wether a field is NOT present according to presence map.
notPresent::FParser (Maybe Primitive)
notPresent = do
    s <- get
    put (FState (P.tail (pm s)))
    let pmap = pm s in
        case head pmap of
            True -> fail "Presence bit set."
            False -> return Nothing

-- |nULL parser.
nULL::FParser (Maybe Primitive)
nULL = lift nULL'
    where nULL' = do 
            A.char (w2c 0x80)
            return Nothing

-- |UInt32 field parser.
uint32::FParser Primitive
uint32 = do 
    x <- p
    return $ UInt32 x
    where p = checkBounds ui32Range uint

-- |UInt64 field parser.
uint64::FParser Primitive
uint64 = do
    x <- p
    return $ UInt64 x
    where p = checkBounds ui64Range uint

-- |Int32 field parser.
int32::FParser Primitive
int32 = do
    x <- p
    return $ Int32 x
    where p = checkBounds i32Range uint
    
exint32::FParser Primitive 
exint32 = do 
    x <- p
    return $ Int32 x
    where p = checkBounds decExpRange uint

-- |Int64 field parser.
int64::FParser Primitive
int64 = do
    x <- p
    return $ Int64 x
    where p = checkBounds i64Range uint
-- |Dec field parser.
dec::FParser Primitive
dec = do
        e <- exint32 
        m <- int64 
        return (Decimal e m)

-- |Unsigned integer parser, doesn't check for bounds.
-- TODO: should we check for R6 errors, i.e overlong fields?
uint::FParser Int
uint = do 
    bs <- anySBEEntity
    return (snd((B.foldl h (0,0) bs)))
    where
        h::(Int,Int) -> Word8 -> (Int,Int)
        h (c,r) w = (c + 1, r + fromEnum((clearBit w 8)) * 2^(7*c))
        
-- |Signed integer parser, doesn't check for bounds.
int::FParser Int
int = do
    bs <- anySBEEntity
    return $ snd(B.foldl h (0,0) bs)
    where 
        h::(Int,Int) -> Word8 -> (Int,Int)
        h (c,r) w = (c + 1, r') 
            where  r' = case (testBit w 8) of
                            True -> case testBit w 7 of
                                        True -> -1 * (r + fromEnum(w .&. 0xc0) * 2^(7*c)) 
                                        False -> r + fromEnum((clearBit w 8)) * 2^(7*c)
                            False -> r + (fromEnum w) * 2^(7*c)

-- |Check wether parsed integer is in given range.
checkBounds::(Int,Int) -> FParser Int -> FParser Int
checkBounds r p = do
    x <- p
    return (checkRange r x)

-- |ASCII string field parser, non-Nullable.
asciiString::FParser Primitive
asciiString = do
    bs <- anySBEEntity
    let bs' = (B.init bs) `B.append` B.singleton (clearBit (B.last bs) 8) in
        return (rmPreamble(Ascii (map w2c (B.unpack bs'))))

-- |ASCII string field parser, Nullable.
asciiString'::FParser Primitive
asciiString' = do
    bs <- anySBEEntity
    let bs' = (B.init bs) `B.append` B.singleton (clearBit (B.last bs) 8) in
        return (rmPreamble'(Ascii ((map w2c (B.unpack bs')))))
    
-- |Remove Preamble of an ascii string, non-Nullable situation.
rmPreamble::Primitive -> Primitive
rmPreamble (Ascii ['\0']) = Ascii []
rmPreamble (Ascii ['\0', '\0']) = Ascii ['\0']
-- overlong string.
rmPreamble (Ascii x) = Ascii (filter (\c -> (c /= '\0')) x)

-- |Remove preamble of an ascii string, NULLable situation.
rmPreamble'::Primitive -> Primitive
rmPreamble' (Ascii ['\0','\0']) = Ascii []
rmPreamble' (Ascii ['\0','\0','\0']) = Ascii ['\0']
-- overlong string.
rmPreamble' (Ascii x) = Ascii (filter (\c -> (c /= '\0')) x)

-- |Unicode string field parser. The first argument is the size of the string.
unicodeString::FParser Primitive
unicodeString = do
    bv <- byteVector
    let (Bytevector bs) = bv in
        return (Unicode (U.toString bs))
    
-- |Bytevector size preamble parser.
-- TODO: Is it a UInt32 or a UInt64?
byteVector::FParser Primitive
byteVector = do
    s <- uint32
    let (UInt32 s') = s in
            byteVector' s'

-- |Bytevector field parser. The first argument is the size of the bytevector.
byteVector'::Int -> FParser Primitive
byteVector' c = lift p
    where p = Bytevector <$> (A.take c)

-- * Delta parsers.
-- |Int32 delta parser.
int32Delta::FParser Delta
int32Delta = Int32Delta <$> int32

-- |Uint32 delta parser.
uint32Delta::FParser Delta
uint32Delta = UInt32Delta <$> int32

-- |Int64 delta parser.
int64Delta::FParser Delta
int64Delta = Int64Delta <$> int64

-- |UInt64 delta parser.
uint64Delta::FParser Delta
uint64Delta = UInt64Delta <$> int64

-- |Decimal delta parser.
decDelta::FParser Delta
decDelta = DecimalDelta <$> dec

-- |Ascii delta parser, non-Nullable.
asciiDelta::FParser Delta
asciiDelta = do
               l <- int32
               str <- asciiString
               return (AsciiDelta l str)
-- |Ascii delta parser, Nullable.
asciiDelta'::FParser Delta
asciiDelta' = do
               l <- int32
               str <- asciiString'
               return (AsciiDelta l str)

-- |Bytevector delta parser.
byteVectorDelta::FParser Delta
byteVectorDelta = do
                    l <- int32
                    bv <- byteVector
                    return (ByteVectorDelta l bv)

-- * Tail parsers.
-- | Ascii tail parser, non-nullable case.
asciiTail::FParser Tail
asciiTail = AsciiTail <$> asciiString

-- | Ascii tail parser, nullable case.
asciiTail'::FParser Tail
asciiTail' = AsciiTail <$> asciiString'

-- | Bytevector tail parser.
bytevectorTail::FParser Tail
bytevectorTail = ByteVectorTail <$> byteVector

-- *Helper functions.
--

-- |Create a unique fname out of a given one and a string.
uniqueFName::NsName -> String -> NsName
uniqueFName fname s = NsName (NameAttr(n ++ s)) ns id
    where (NsName (NameAttr n) ns id) = fname

-- |Update the previous value.
updatePrevValue::NsName -> OpContext -> DictValue -> FParser Primitive
updatePrevValue n oc p = undefined

-- |Modify underlying bits of a Char.
modBits::Char -> (Word8 -> Word8) -> Char
modBits c f = (w2c . f . c2w) c

-- |Decrement the value of an integer, when it is positive.
minusOne::Primitive -> Primitive
minusOne (Int32 x) | x > 0 = Int32(x - 1)
minusOne (Int64 x) | x > 0 = Int64(x - 1)
minusOne (UInt32 x)| x > 0 = UInt32(x - 1)
minusOne (UInt64 x)| x > 0 = UInt64(x - 1)
minusOne x = x

-- *Presence map related functions

-- |Convert a bytestring into a presence map.
bsToPm::B.ByteString -> [Bool]
bsToPm bs = concat (map h (B.unpack bs)) 
    where   h::Word8 -> [Bool]
            h w = map (testBit w) [1..7] 
            
