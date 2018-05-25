
module Handler.Utils where

import Import
import TimeUtils
import qualified Data.Aeson.Parser as AP
import qualified Data.Conduit.Zlib as Zlib
import Data.Streaming.Zlib (ZlibException(..))
import qualified Data.Conduit.Attoparsec as Attoparsec
import Web.Cookie (setCookieName, setCookieValue, setCookieMaxAge)
import System.Directory (createDirectoryIfMissing, removeFile,
                        getDirectoryContents, getModificationTime)
import System.FilePath (takeDirectory)

badRequest :: Text -> Handler a
badRequest = sendResponseStatus badRequest400

internalServerError :: Handler a
internalServerError = sendResponseStatus internalServerError500 ("" :: Text)

getDataDir :: Handler String
getDataDir = appDataDir . appSettings <$> getYesod

writeFileWithParents :: MonadIO m => FilePath -> ByteString -> m ()
writeFileWithParents file contents = liftIO $ do
  createDirectoryIfMissing True (takeDirectory file)
  writeFile file contents

deleteFilesOlderThan :: forall m.
  (MonadIO m, MonadCatch m, MonadLogger m, MonadBaseControl IO m) =>
  NominalDiffTime -> FilePath -> m ()
deleteFilesOlderThan maxAge dir = do
  files <- getDirectoryContents' dir
  filesWithTimes <- liftIO $ traverse (\f -> (f,) <$> getAge f) files
  otraverse_ (\(f, age) -> when (age > maxAge) (tryRemoveFile f)) filesWithTimes
  where
  getAge f = getModificationTime f >>= getElapsedTimeSince

  tryRemoveFile = flip catch logIOException . liftIO . removeFile

  logIOException :: IOException -> m ()
  logIOException e = $logError (tshow e)

-- | Like getDirectoryContents, except that:
--  * It includes the directory that you supplied, so that you can safely pass
--    the results to readFile etc
--  * It removes "." and ".." from the results
--  * It works for any MonadIO
getDirectoryContents' :: forall m. MonadIO m => FilePath -> m [FilePath]
getDirectoryContents' dir =
  liftIO $
    map (dir ++) . filter (`onotElem` [".", ".."]) <$> getDirectoryContents dir

-- | Sets a message which is displayed just once, at the next time the user's
-- browser renders a page.
setCookieMessage :: ByteString -> Handler ()
setCookieMessage msg =
  setCookie def { setCookieName = "message"
                , setCookieValue = msg
                , setCookieMaxAge = Just $ secondsToDiffTime 3600
                }

-- | Like Yesod's parseJsonBody, but this version first checks for a
-- Content-Encoding: gzip header and unzips the body if that is found.
parseJsonBodyPotentiallyGzipped :: Handler (Either String Value)
parseJsonBodyPotentiallyGzipped = do
  unzipping <- shouldUnzip <$> lookupHeader hContentEncoding
  let ungzip = if unzipping then Zlib.ungzip else mapC id
  let parser = ungzip .| Attoparsec.sinkParser AP.value'
  eValue <- runConduit $ rawRequestBody .| catchEither parser

  return $ bimap display id eValue

  where
  shouldUnzip = maybe False (== "gzip")

  display e =
    case fromException e of
      Just (ZlibException (-3)) ->
        "Invalid gzip data in request body"
      _ ->
        case fromException e of
          Just err ->
            Attoparsec.errorMessage err
          _ ->
            show e

catchEither :: MonadCatch m => m a -> m (Either SomeException a)
catchEither m = catch (map Right m) (pure . Left)
