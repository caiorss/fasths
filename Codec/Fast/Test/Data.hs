{-# LANGUAGE FlexibleContexts, TupleSections, TypeFamilies #-}

module Codec.Fast.Test.Data 
(
arbitraryMsgForTemplate,
Bit7String (..),
Bit7Char (..),
NonOverlongString (..)
) 
where 

import Codec.Fast.Data
import Test.QuickCheck
import Data.ByteString.Char8 (unpack, pack) 
import Data.Bits
import Data.Int (Int32, Int64)
import Data.Word (Word32, Word64)
import qualified Data.ListLike as LL
import Control.Applicative 
import Control.Exception
import qualified Data.ByteString as B

newtype Bit7String = B7S String deriving Show
unwrapB7S :: Bit7String -> String
unwrapB7S (B7S s) = s

instance Arbitrary Bit7String where
    arbitrary = fmap (B7S . dropWhile (== '\0') . unpack  . B.map (\w -> clearBit w 7) . pack) (arbitrary :: Gen String)
    shrink = (map B7S) . (shrink :: String -> [String]) . unwrapB7S

newtype Bit7Char = B7C Char deriving (Show, Eq)
unwrapB7C :: Bit7Char -> Char
unwrapB7C (B7C c) = c

instance Arbitrary Bit7Char where
    arbitrary = ((B7C . toEnum . (\w -> clearBit w 7) . fromEnum) <$> (arbitrary :: Gen Char)) `suchThat` (/= B7C '\0')
    shrink = (map B7C) . (shrink :: Char -> [Char]) . unwrapB7C

newtype NormalizedDecimal = ND (Int32, Int64) deriving Show
unwrapND :: NormalizedDecimal -> (Int32 , Int64)
unwrapND (ND x) = x

instance Arbitrary NormalizedDecimal where
    arbitrary = fmap (ND . normalize) (arbitrary :: Gen (Int32, Int64))
        where   normalize (_, 0) = (0, 0)
                normalize (e, m) | m `mod` 10 == 0 = normalize (e + 1, m `div` 10)
                normalize (e, m) = (e, m)
    shrink = (map ND) . (shrink :: (Int32, Int64) -> [(Int32, Int64)]) . unwrapND

newtype NonOverlongString = NOS AsciiString deriving Show

instance Arbitrary NonOverlongString where
    arbitrary = fmap NOS ((arbitrary :: Gen AsciiString) `suchThat` (not . overlong))
        where 
            overlong :: AsciiString -> Bool
            overlong [] = False
            overlong "\0" = False
            overlong ('\0':_) = True
            overlong _ = False
    shrink = (map NOS) . (shrink :: String -> [String]) . (\(NOS s) -> s)

arbitraryMsgForTemplate :: Template -> Gen (NsName, Maybe Value)
arbitraryMsgForTemplate t = do 
                                vs <- sequence $ map arbitraryValueForInstruction (tInstructions t)
                                return (tname2fname $ tName t, Just $ Gr vs)

arbitraryValueForInstruction :: Instruction -> Gen (NsName, Maybe Value)
arbitraryValueForInstruction (Instruction f) = arbitraryValueForField f
arbitraryValueForInstruction (TemplateReference _) = error "Can't handle template references."

arbitraryValueForField :: Field -> Gen (NsName, Maybe Value)
arbitraryValueForField (IntField f@(Int32Field (FieldInstrContent fname _ _))) = (fname,) <$> fmap toValue <$> ((arbitraryValueForIntField f) :: Gen (Maybe Int32))
arbitraryValueForField (IntField f@(Int64Field (FieldInstrContent fname _ _))) = (fname,) <$> fmap toValue <$> ((arbitraryValueForIntField f) :: Gen (Maybe Int64))
arbitraryValueForField (IntField f@(UInt32Field (FieldInstrContent fname _ _))) = (fname,) <$> fmap toValue <$> ((arbitraryValueForIntField f) :: Gen (Maybe Word32))
arbitraryValueForField (IntField f@(UInt64Field (FieldInstrContent fname _ _))) = (fname,) <$> fmap toValue <$> ((arbitraryValueForIntField f) :: Gen (Maybe Word64))
arbitraryValueForField (DecField f@(DecimalField fname _ _ )) = (fname, ) <$> fmap toValue <$> arbitraryValueForDecField f 
arbitraryValueForField (AsciiStrField f@(AsciiStringField(FieldInstrContent fname _ _ ))) = (fname, ) <$> fmap toValue <$> arbitraryValueForAsciiField f
arbitraryValueForField (UnicodeStrField (UnicodeStringField f@(FieldInstrContent fname _ _ ) maybe_len )) = (fname, ) <$> fmap toValue <$> (arbitraryValueForByteVectorField f maybe_len :: Gen (Maybe UnicodeString))
arbitraryValueForField (ByteVecField (ByteVectorField f@(FieldInstrContent fname _ _ ) maybe_len )) = (fname, ) <$> fmap toValue <$> (arbitraryValueForByteVectorField f maybe_len :: Gen (Maybe B.ByteString))
arbitraryValueForField (Seq s) = arbitraryValueForSequence s
arbitraryValueForField (Grp g) = arbitraryValueForGroup g

arbitraryValueForIntField :: (Primitive a, Arbitrary a) => IntegerField -> Gen (Maybe a)
arbitraryValueForIntField (Int32Field fic) = arbitraryValueForIntField' fic 
arbitraryValueForIntField (UInt32Field fic) = arbitraryValueForIntField' fic 
arbitraryValueForIntField (Int64Field fic) = arbitraryValueForIntField' fic 
arbitraryValueForIntField (UInt64Field fic) = arbitraryValueForIntField' fic 

arbitraryValueForIntField' :: (Primitive a, Arbitrary a) => FieldInstrContent -> Gen (Maybe a)
arbitraryValueForIntField' (FieldInstrContent fname Nothing maybe_op) = arbitraryValueForIntField' (FieldInstrContent fname (Just Mandatory) maybe_op)
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) Nothing) = Just <$> arbitrary
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Constant iv))) = return $ Just $ ivToPrimitive iv
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Default Nothing)))
    = throw $ S5 "No initial value given for mandatory default operator."
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Default (Just _)))) = Just <$> arbitrary
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Copy _))) = Just <$> arbitrary
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Increment _))) = fmap Just arbitrary
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Tail _)))
    = throw $ S2 "Tail operator can not be applied on an integer type field." 
arbitraryValueForIntField' (FieldInstrContent _ (Just Optional) (Just (Tail _)))
    = throw $ S2 "Tail operator can not be applied on an integer type field." 
arbitraryValueForIntField' (FieldInstrContent _ (Just Optional) (Just (Constant iv))) = oneof [return $ Just (ivToPrimitive iv), return Nothing]
arbitraryValueForIntField' (FieldInstrContent _ (Just Mandatory) (Just (Delta _))) = Just <$> arbitrary
arbitraryValueForIntField' _ = arbitrary


arbitraryValueForDecField :: DecimalField -> Gen (Maybe (Int32, Int64))
arbitraryValueForDecField (DecimalField fname Nothing maybe_either_op) 
    = arbitraryValueForDecField (DecimalField fname (Just Mandatory) maybe_either_op)
arbitraryValueForDecField (DecimalField _ (Just Mandatory) Nothing) = Just <$> arbitrary
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Constant iv)))) = return $ Just $ ivToPrimitive iv
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Default Nothing))))
    = throw $ S5 "No initial value given for mandatory default operator."
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Default (Just _))))) = Just <$> arbitrary
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Copy _)))) = Just <$> arbitrary
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Increment _)))) 
    = throw $ S2 "Increment operator is only applicable to integer fields." 
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Delta _)))) = Just <$> arbitrary
arbitraryValueForDecField (DecimalField _ (Just Mandatory) (Just (Left (Tail _))))
    = throw $ S2 "Tail operator is only applicable to ascii, unicode and bytevector fields." 
arbitraryValueForDecField (DecimalField _ (Just Optional) (Just (Left (Constant iv)))) = oneof [return $ Just $ ivToPrimitive iv, return Nothing]
arbitraryValueForDecField (DecimalField _ (Just Optional) (Just (Left (Increment _)))) 
    = throw $ S2 "Increment operator is applicable only to integer fields."
arbitraryValueForDecField (DecimalField _ (Just Optional) (Just (Left (Tail _)))) 
    = throw $ S2 "Tail operator is only applicable to ascii, unicode and bytevector fields." 
arbitraryValueForDecField (DecimalField fname (Just Optional) (Just (Right (DecFieldOp maybe_exOp maybe_maOp)))) = 
    let fname' = uniqueFName fname "e"
        fname'' = uniqueFName fname "m"
    in
    do 
        e <- arbitraryValueForIntField (Int32Field (FieldInstrContent fname' (Just Optional) maybe_exOp))
        m <- arbitraryValueForIntField (Int64Field (FieldInstrContent fname'' (Just Mandatory) maybe_maOp))
        case (e, m) of
            (Nothing, Nothing) -> return Nothing
            ((Just e'), (Just m')) -> return (Just (e', m'))
            ((Just e'), Nothing) -> do 
                m' <- arbitrary
                return (Just (e', m'))
            (Nothing, Just m') -> do
                e' <- arbitrary
                return (Just (e', m'))
arbitraryValueForDecField (DecimalField fname (Just Mandatory) (Just (Right (DecFieldOp maybe_exOp maybe_maOp)))) = 
    let fname' = uniqueFName fname "e"
        fname'' = uniqueFName fname "m"
    in
    do 
        e <- arbitraryValueForIntField (Int32Field (FieldInstrContent fname' (Just Mandatory) maybe_exOp))
        m <- arbitraryValueForIntField (Int64Field (FieldInstrContent fname'' (Just Mandatory) maybe_maOp))
        case (e, m) of
            (Nothing, Nothing) -> return Nothing
            ((Just e'), (Just m')) -> return (Just (e', m'))
            ((Just e'), Nothing) -> do 
                m' <- arbitrary
                return (Just (e', m'))
            (Nothing, Just m') -> do
                e' <- arbitrary
                return (Just (e', m'))
arbitraryValueForDecField _ = arbitrary

arbitraryValueForAsciiField :: AsciiStringField -> Gen (Maybe AsciiString)
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent fname Nothing maybe_op))
    = arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent fname (Just Mandatory) maybe_op))
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) Nothing)) = (Just . unwrapB7S) <$> arbitrary
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Constant iv)))) = return $ Just $ ivToPrimitive iv
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default Nothing))))
    = throw $ S5 "No initial value given for mandatory default operator."
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Default (Just _))))) = (Just . unwrapB7S) <$> arbitrary
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Copy _)))) = (Just . unwrapB7S) <$> arbitrary
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Increment _))))
    = throw $ S2 "Increment operator is only applicable to integer fields." 
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Delta _)))) = (Just . unwrapB7S) <$> arbitrary
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Mandatory) (Just (Tail _)))) = (Just . (dropWhile (=='\0')) . (map unwrapB7C)) <$> vectorOf 10 arbitrary
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Constant iv))))  = oneof [return $ Just $ ivToPrimitive iv, return Nothing]
arbitraryValueForAsciiField (AsciiStringField(FieldInstrContent _ (Just Optional) (Just (Tail _)))) = oneof [return Nothing, (Just . (dropWhile (=='\0')) . (map unwrapB7C)) <$> vectorOf 10 arbitrary]
arbitraryValueForAsciiField _ = (fmap unwrapB7S) <$> arbitrary

arbitraryValueForByteVectorField :: (Primitive a, Arbitrary a, LL.ListLike a c, Arbitrary c) => FieldInstrContent -> Maybe ByteVectorLength -> Gen (Maybe a)
arbitraryValueForByteVectorField (FieldInstrContent fname Nothing maybe_op) len 
    = arbitraryValueForByteVectorField (FieldInstrContent fname (Just Mandatory) maybe_op) len
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) Nothing ) _ = Just <$> arbitrary
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just (Constant iv))) _  = return $ Just $ ivToPrimitive iv
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Optional) (Just(Constant iv))) _ = oneof [return $ Just $ ivToPrimitive iv, return Nothing]
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Default Nothing))) _  
    = throw $ S5 "No initial value given for mandatory default operator."
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Default (Just _)))) _ = Just <$> arbitrary
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Copy _ ))) _  = Just <$> arbitrary
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Increment _ ))) _  
    = throw $ S2 "Increment operator is only applicable to integer fields." 
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Optional) (Just(Increment _ ))) _ 
    = throw $ S2 "Increment operator is only applicable to integer fields." 
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Delta _ ))) _ = Just <$> arbitrary
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Mandatory) (Just(Tail _ ))) _ = (Just . LL.fromList) <$> vectorOf 10 arbitrary
arbitraryValueForByteVectorField (FieldInstrContent _ (Just Optional) (Just(Tail _ ))) _ = oneof [return Nothing, (Just . LL.fromList) <$> vectorOf 10 arbitrary]
arbitraryValueForByteVectorField _ _ = arbitrary

arbitraryValueForSequence :: Sequence -> Gen (NsName, Maybe Value)
arbitraryValueForSequence (Sequence fname pr _ _ m_length instrs) = do
    l <- h pr m_length
    g l
    where  
        g Nothing = return (fname, Nothing)
        g (Just i') = do 
                         sq <- (vectorOf (fromIntegral i') (mapM arbitraryValueForInstruction instrs))
                         return (fname, Just (Sq (fromIntegral i') sq))
        fname' = uniqueFName fname "l" 
        h p Nothing = arbitraryValueForIntField (UInt32Field (FieldInstrContent fname' p Nothing)) :: Gen (Maybe Word32)
        h p (Just (Length Nothing op)) = arbitraryValueForIntField (UInt32Field (FieldInstrContent fname' p op)) :: Gen (Maybe Word32)
        h p (Just (Length (Just fn) op)) = arbitraryValueForIntField (UInt32Field (FieldInstrContent fn p op)) :: Gen (Maybe Word32)

arbitraryValueForGroup :: Group -> Gen (NsName, Maybe Value)
arbitraryValueForGroup (Group fname Nothing maybe_dict maybe_typeref instrs)
    = arbitraryValueForGroup (Group fname (Just Mandatory) maybe_dict maybe_typeref instrs)
arbitraryValueForGroup (Group fname (Just Mandatory) _ _ instrs) = (fname,) <$> Just . Gr <$> (mapM arbitraryValueForInstruction instrs)
arbitraryValueForGroup (Group fname (Just Optional) _ _ instrs) = (fname,) <$> oneof [Just . Gr <$> (mapM arbitraryValueForInstruction instrs), return Nothing]