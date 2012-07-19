module EVE (
EVECred(..),
runEVE,
getCharacters,
CorpID,
CharID,
coidInner,
chidInner
) where

import Data.String
import Data.Maybe
import Control.Monad.Reader
import Data.Conduit
import Network.HTTP.Conduit
import Text.XML
import Data.Map ((!))
import Control.Monad.Error
import Data.Typeable
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS

data EVECred = EC { userID :: Int
                  , apiKey :: String
		  }

data EVEParam = EInt Int
              | EStr String

data CorpID = CoID {coidInner :: Int} deriving Show
data CharID = ChID {chidInner :: Int} deriving Show

data EVEError = StructError
              | AuthError
              | APIErrorCode Int
              | ValueParseError
              | APIVersionError
              | OtherError String deriving (Show, Typeable)

instance Error EVEError where
  strMsg = OtherError

type EVE = ErrorT EVEError (ReaderT EVECred IO)

runEVE :: EVECred -> EVE a -> IO (Either EVEError a)
runEVE c m = runReaderT (runErrorT m) c

baseURL :: String
baseURL = "https://api.eveonline.com/"

eveQuery :: String         -- ^ Category
         -> String         -- ^ Operation
	 -> [(String, EVEParam)] -- ^ Parameters
	 -> EVE Element          -- ^ Resultant XML
eveQuery cat op params = do
  creds <- ask
  let params' = ("keyID", EInt $ userID creds):
                ("vCode", EStr $ apiKey creds):
		params
  let url = baseURL ++ cat ++ "/" ++ op ++ ".xml.aspx"
  req <- parseUrl url
  let req' = urlEncodedBody (map format params') req
  doc <- withManager $ \m -> do xml <- fmap responseBody $ http req' m
                                xml $$ sinkDoc def
  elm  <- apiCheck doc
  elm' <- checkError elm
  --TODO Actually extract and use cache information
  return elm'
  where format (s, v) = let
          v' = case v of
                 EInt n -> show n
                 EStr n -> n
          in (BS.pack s, BS.pack v')

isElement (NodeElement _) = True
isElement _ = False

toElement (NodeElement x) = x

(!?) :: EVE Element -> String -> EVE Element
e' !? n = do
  e <- e'
  case filter ((== (show n)) . show . nameLocalName . elementName)
               (map toElement $ filter isElement $ elementNodes e) of
    x:_ -> return x
    _ -> throwError StructError

(!*) :: EVE Element -> String -> EVE String
e' !* n = do
  e <- e'
  case lookup (name n) (elementAttributes e) of
    Just x -> return $ T.unpack x
    _ -> throwError StructError

readE :: (Read a) => String -> EVE a
readE s =
  case reads s of
    [(x,"")] -> return x
    _ -> throwError ValueParseError

name s = Name (T.pack s) Nothing Nothing

assertError :: EVEError -> Bool -> EVE ()
assertError e b = if b then return () else throwError e

apiCheck :: Document -> EVE Element
apiCheck doc = do
  let root = documentRoot doc
  assertError StructError $ (elementName root) == (name "eveapi")
  assertError APIVersionError $
    case lookup (name "version") (elementAttributes root) of
      Just v  -> (T.unpack v) == "2"
      Nothing -> False
  return $ root

errorCode :: Int -> EVEError
errorCode 203 = AuthError
errorCode n = APIErrorCode n

checkError :: Element -> EVE Element
checkError doc = do
  e <- catchError (fmap Just $ readE =<< (return doc) !? "error" !* "code")
                  (\_ -> return Nothing)
  case e of
    Just n  -> throwError $ errorCode n
    Nothing -> return ()
  (return doc) !? "result"

extractRowset f elm = do
  rows <- fmap (map toElement . filter isElement . elementNodes) $ elm !? "rowset"
  mapM (f . return) rows

getCharacters :: EVE [( String -- ^ Character name
                      , CharID -- ^ Character ID
                      , String -- ^ Corp name
                      , CorpID -- ^ Corp ID
                      )
                     ]
getCharacters = extractRowset charExtract $ eveQuery "account" "characters" []
   where charExtract row = do
           name <- row !* "name"
           chid <- fmap ChID $ readE =<< row !* "characterID"
           corp <- row !* "corporationName"
           coid <- fmap CoID $ readE =<< row !* "corporationID"
           return (name, chid, corp, coid)
