{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Apps.Juno.Parser (
  HopperLiteAdminCommand (..)
  ,SwiftBlob(..)
  ,readHopper
  ) where

import Control.Monad
import Control.Applicative
import qualified Data.Attoparsec.ByteString.Char8 as Atto
import Text.Parser.Char
import Text.Parser.Token
import Text.Parser.Combinators
import qualified Data.ByteString.Char8 as BSC
import Data.Aeson
import GHC.Generics
import Data.Text (Text)
import qualified Data.Text as T
import Data.Ratio

import Schwifty.Swift.M105.Types
import Schwifty.Swift.M105.Parser
import Apps.Juno.Ledger

import Language.Hopper.Internal.Core.TermDemoWare (DemoTerm(..))
import Language.Hopper.Internal.Core.Literal (Literal(..))
import Language.Hopper.Transmatic

-- sample for reference: "{\"_swiftCommand\":\"bar\",\"_swiftText\":\"foo\"}"
data SwiftBlob = SwiftBlob {
  _swiftText :: Text       -- unparsed swift text
  ,_swiftCommand :: String -- this should be a transfer(..) as a string
  } deriving (Show, Eq, Generic, ToJSON, FromJSON)

data HopperLiteAdminCommand
  = Program DemoTerm
  | CreateAccount Text
  | AdjustAccount Text Rational
  | ObserveAccount Text
  | ObserveAccounts
  | SwiftPayment SWIFT DemoTerm
  | LedgerQueryCmd LedgerQuery
  deriving (Eq, Show)

hopperliteParser :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
hopperliteParser = createAccount
                   <|> adjustAccount
                   <|> observeAccounts
                   <|> observeAccount
                   <|> getPrimOps
                   <|> transmatic
                   <|> try swiftPayment
                   <|> try ledgerQueryCmd

ledgerQueryCmd :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
ledgerQueryCmd = do
  c <- some anyChar
  case eitherDecodeStrict' (BSC.pack c) of
    Left e -> unexpected e
    Right v -> return $ Right $ LedgerQueryCmd v

swiftPayment :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
swiftPayment = do
  c <- some anyChar
  case eitherDecodeStrict' (BSC.pack c) of
    Left e -> unexpected e
    Right v -> return $ convertBlob v

convertBlob :: SwiftBlob -> Either String HopperLiteAdminCommand
convertBlob (SwiftBlob t c) =
  case Atto.parseOnly getPrimOps (BSC.pack c) of
    Left e -> Left $ "Syntax Error: " ++ e
    Right (Left e) -> Left $ "Language Error: " ++ e
    Right (Right (Program v)) -> case parseSwift t of
      Left e -> Left $ "Swift Parsing Error: " ++ e
      Right s -> Right $ SwiftPayment s v
    Right o -> Left $ "Invariant Failure: expected Program but got " ++ show o

transmatic :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
transmatic = either Left (Right . Program) . compile <$> expr

readHopper :: BSC.ByteString -> Either String HopperLiteAdminCommand
readHopper m = case Atto.parseOnly hopperliteParser m of
  Left e -> Left $ "Syntax Error: " ++ e
  Right (Left e) -> Left $ "Language Error: " ++ e
  Right (Right v) -> Right v

getPrimOps :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
getPrimOps = fmap (fmap Program . hopperify) primOps

createAccount :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
createAccount = (Right . CreateAccount . T.pack) <$ ssString "CreateAccount" <*> some anyChar

adjustAccount :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
adjustAccount = do
  _ <- ssString "AdjustAccount"
  a <- manyTill anyChar space
  _ <- skipSpace
  amt <- myRational
  return $ Right $ AdjustAccount (T.pack a) amt

observeAccount :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
observeAccount = (Right . ObserveAccount . T.pack) <$ ssString "ObserveAccount" <*> some anyChar

observeAccounts :: (Monad m, TokenParsing m) => m (Either String HopperLiteAdminCommand)
observeAccounts = do
  _ <- ssString "ObserveAccounts"
  return $ Right ObserveAccounts

myRational :: (Monad m, TokenParsing m) => m Rational
myRational = do
  n <- decimal
  _ <- ssChar '%'
  d <- decimal
  return (n % d)


skipSpace :: TokenParsing m => m ()
skipSpace = skipMany space

ssChar :: (Monad m, TokenParsing m) => Char -> m ()
ssChar a = skipSpace >> char a >> skipSpace

ssString :: (Monad m, TokenParsing m) => String -> m ()
ssString a = skipSpace >> string a >> skipSpace

data Transfer = Transfer {_tRoute :: [Text], _tAmt :: Rational}
              deriving (Eq, Show)

class Hopperify a where
  hopperify :: a -> Either String DemoTerm

instance Hopperify Transfer where
  hopperify (Transfer [] _) = Left "Error: No Route Specified!"
  hopperify (Transfer [_] _) = Left "Error: No Endpoint Account Specified!"
  hopperify (Transfer [f,t] a) = Right $ Let "t" (PrimApp "transfer" [ELit (LText f),ELit (LText t),ELit (LRational a),ELit (LText "cryptSig")]) (V "t")
  hopperify (Transfer [f,i,t] a) = Right $ Let "t" (PrimApp "transfer" [ELit (LText f),ELit (LText i),ELit (LRational a),ELit (LText "cryptSig")]) (PrimApp "transfer" [ELit (LText i),ELit (LText t),ELit (LRational a),ELit (LText "cryptSig")])
  hopperify (Transfer (f:t:rest) a) = Right $ Let "t" (PrimApp "transfer" [ELit (LText f),ELit (LText t),ELit (LRational a),ELit (LText "cryptoSig")]) (go $ Transfer (t:rest) a)
    where
      -- we only want to start recurring down when we have a > 2 step transfer as a 2 step transfer is the base case (1 step has a different form)
      go :: Transfer -> DemoTerm
      go (Transfer [] _) = error "Invariant error, you shouldn't be able to hit this part of hopperify"
      go (Transfer [_] _) = error "Invariant error, you shouldn't be able to hit this part of hopperify"
      go (Transfer [_,_] _) = error "Invariant error, you shouldn't be able to hit this part of hopperify"
      go (Transfer [f',i',t'] a') = Let "t" (PrimApp "transfer" [ELit (LText f'),ELit (LText i'),ELit (LRational a'),ELit (LText "cryptSig")]) (PrimApp "transfer" [ELit (LText i'),ELit (LText t'),ELit (LRational a'),ELit (LText "cryptSig")])
      go (Transfer (f':t':rest') a') = Let "t" (PrimApp "transfer" [ELit (LText f'),ELit (LText t'),ELit (LRational a'),ELit (LText "cryptSig")]) (go $ Transfer (t':rest') a')

primOps :: (Monad m, TokenParsing m) => m Transfer
primOps = liftM (uncurry Transfer) transfer

transfer :: (Monad m, TokenParsing m) => m ([Text], Rational)
transfer = do
  _ <- ssString "transfer("
  ts <- routeText
  _ <- ssChar ','
  n <- decimal
  _ <- ssChar '%'
  d <- decimal
  _ <- char ')'
  return (ts, n % d)

routeText :: (Monad m, TokenParsing m) => m [Text]
routeText = do
  ts <- sepBy (some (noneOf "->,")) (string "->")
  return $ T.pack <$> ts
