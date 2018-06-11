-- Copyright (C) 2018 Red Hat, Inc.
--
-- This file is part of bdcs-api.
--
-- bdcs-api is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- bdcs-api is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with bdcs-api.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-| BDCS API Compose-related types and functions
-}
module BDCS.API.Compose(ComposeInfo(..),
                        ComposeMsgAsk(..),
                        ComposeMsgResp(..),
                        ComposeStatus(..),
                        UuidStatus(..),
                        compose,
                        deleteCompose,
                        getComposesWithStatus,
                        mkComposeStatus)
  where

import           BDCS.API.Depsolve(PackageNEVRA(..), depsolveRecipe)
import           BDCS.API.Error(tryIO)
import           BDCS.API.QueueStatus(QueueStatus(..), queueStatusEnded, queueStatusText, queueStatusFromText)
import           BDCS.API.Recipe(Recipe(..), RecipeModule(..), parseRecipe)
import           BDCS.Export(exportAndCustomize)
import           BDCS.Export.Customize(Customization)
import           BDCS.Export.Types(ExportType(..))
import           BDCS.Utils.Either(maybeToEither)
import           Control.Conditional(ifM)
import qualified Control.Exception as CE
import           Control.Monad(filterM)
import           Control.Monad.Except(ExceptT(..), runExceptT)
import           Control.Monad.Logger(MonadLoggerIO, logErrorN, logInfoN)
import           Control.Monad.IO.Class(liftIO)
import           Control.Monad.Trans.Resource(MonadBaseControl, MonadThrow, runResourceT)
import           Data.Aeson((.:), (.=), FromJSON(..), ToJSON(..), object, withObject)
import           Data.Time.Clock(UTCTime, getCurrentTime)
import           Data.Either(rights)
import           Data.String.Conversions(cs)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Database.Persist.Sql(ConnectionPool, runSqlPool)
import           System.Directory(doesFileExist, getModificationTime, listDirectory, removePathForcibly)
import           System.FilePath.Posix((</>))

data ComposeInfo = ComposeInfo
  {  ciDest       :: FilePath                                   -- ^ Path to the compose artifact
  ,  ciId         :: T.Text                                     -- ^ Build UUID
  ,  ciRecipe     :: Recipe                                     -- ^ The recipe being built
  ,  ciResultsDir :: FilePath                                   -- ^ Directory containing the compose and other files
  ,  ciCustom     :: [Customization]                            -- ^ Customizations to perform on the items in the compose
  ,  ciType       :: ExportType                                 -- ^ Build type (tar, etc.)
  } deriving (Eq, Show)

data ComposeStatus = ComposeStatus {
    csBuildId       :: T.Text,
    csName          :: T.Text,
    csQueueStatus   :: QueueStatus,
    csTimestamp     :: UTCTime,
    csVersion       :: T.Text
} deriving (Show, Eq)

instance ToJSON ComposeStatus where
    toJSON ComposeStatus{..} = object [
        "id"            .= csBuildId
      , "blueprint"     .= csName
      , "queue_status"  .= csQueueStatus
      , "timestamp"     .= csTimestamp
      , "version"       .= csVersion ]

instance FromJSON ComposeStatus where
    parseJSON = withObject "compose type" $ \o ->
        ComposeStatus <$> o .: "id"
                      <*> o .: "blueprint"
                      <*> o .: "queue_status"
                      <*> o .: "timestamp"
                      <*> o .: "version"

data UuidStatus = UuidStatus {
    usStatus :: Bool,
    usUuid :: T.Text
} deriving (Show, Eq)

instance ToJSON UuidStatus where
    toJSON UuidStatus{..} = object [
        "status" .= usStatus,
        "uuid"   .= usUuid ]

instance FromJSON UuidStatus where
    parseJSON = withObject "UUID type" $ \o ->
        UuidStatus <$> o .: "status"
                   <*> o .: "uuid"

data ComposeMsgAsk = AskBuildsWaiting
                   | AskBuildsInProgress
                   | AskCancelBuild T.Text
                   | AskCompose ComposeInfo
                   | AskDequeueBuild T.Text

data ComposeMsgResp = RespBuildCancelled Bool
                    | RespBuildDequeued Bool
                    | RespBuildsWaiting [T.Text]
                    | RespBuildsInProgress [T.Text]

compose :: (MonadBaseControl IO m, MonadLoggerIO m, MonadThrow m) => FilePath -> ConnectionPool -> ComposeInfo -> m ()
compose bdcs pool ComposeInfo{..} = do
    logStatus QRunning "Compose started on"

    -- If these packages weren't in the recipe to begin with, the user doesn't really care
    -- about which version they get.  Add these required packages before depsolving and
    -- move on.
    let recipe = case ciType of
                     ExportOstree -> foldl addRequiredPkg ciRecipe ["dracut", "kernel"]
                     _            -> ciRecipe

    depsolveRecipe pool recipe >>= \case
        Left e            -> logErrorN (cs e) >> logStatus QFailed "Compose failed on"
        Right (nevras, _) -> do let things = map pkgString nevras
                                logInfoN $ "Exporting packages: " `T.append` T.intercalate " " things

                                runExceptT (runResourceT $ runSqlPool (exportAndCustomize bdcs ciDest ciType things ciCustom) pool) >>= \case
                                    Left e  -> logErrorN (cs e) >> logStatus QFailed "Compose failed on"
                                    Right _ -> do liftIO $ TIO.writeFile (ciResultsDir </> "ARTIFACT") (cs ciDest)
                                                  logStatus QFinished "Compose finished on"
 where
    addRequiredPkg :: Recipe -> String -> Recipe
    addRequiredPkg recipe pkg =
        if not (any (\x -> pkg == rmName x) (rModules recipe))
        then recipe { rModules=RecipeModule pkg "" : rModules recipe }
        else recipe

    -- This function needs to spit out strings that BDCS.RPM.Utils.splitFilename
    -- knows how to take apart.  Be especially careful with the epoch part.  Otherwise,
    -- we won't be able to find packages in the database and will get depsolving errors.
    pkgString :: PackageNEVRA -> T.Text
    pkgString PackageNEVRA{pnEpoch=Nothing, ..} = T.concat [pnName, "-",                   pnVersion, "-", pnRelease, ".", pnArch]
    pkgString PackageNEVRA{pnEpoch=Just e, ..}  = T.concat [pnName, "-", cs (show e), ":", pnVersion, "-", pnRelease, ".", pnArch]

    logStatus :: MonadLoggerIO m => QueueStatus -> T.Text -> m ()
    logStatus status msg = do
        time <- liftIO $ do
            TIO.writeFile (ciResultsDir </> "STATUS") (queueStatusText status)
            getCurrentTime

        logInfoN $ T.concat [msg, " ", cs (show time)]

deleteCompose :: FilePath -> T.Text -> IO (Either String UuidStatus)
deleteCompose dir uuid =
    liftIO (runExceptT $ mkComposeStatus dir uuid) >>= \case
        Left _                  -> return $ Left $ cs uuid ++ " is not a valid build uuid"
        Right ComposeStatus{..} ->
            if not (queueStatusEnded csQueueStatus)
            then return $ Left $ "Build " ++ cs uuid ++ " not in FINISHED or FAILED"
            else do
                let path = dir </> cs uuid
                CE.catch (do removePathForcibly path
                             return $ Right UuidStatus { usStatus=True, usUuid=uuid })
                         (\(e :: CE.IOException) -> return $ Left $ cs uuid ++ ": " ++ cs (show e))

getComposesWithStatus :: FilePath -> QueueStatus -> IO [ComposeStatus]
getComposesWithStatus resultsDir status = do
    -- First, gather up all the subdirectories of resultsDir.  Each of these is a UUID for
    -- some compose, wher that one has finished or is in progress or is in the queue.
    contents <- listDirectory resultsDir
    -- Next, filter that list down to just those that have a STATUS file containing the
    -- sought after status.
    uuids    <- filterM matches (map cs contents)
    -- Finally, convert those into ComposeStatus records.
    rights <$> mapM (runExceptT . mkComposeStatus resultsDir) uuids
 where
    matches :: T.Text -> IO Bool
    matches uuid = do
        let statusFile = resultsDir </> cs uuid </> "STATUS"
        ifM (doesFileExist statusFile)
            (do line <- CE.catch (TIO.readFile statusFile)
                                 (\(_ :: CE.IOException) -> return "")
                return $ queueStatusFromText line == Just status)
            (return False)

mkComposeStatus :: FilePath -> T.Text -> ExceptT String IO ComposeStatus
mkComposeStatus baseDir buildId = do
    let path = baseDir </> cs buildId

    contents   <- tryIO   $ TIO.readFile (path </> "blueprint.toml")
    Recipe{..} <- ExceptT $ return $ parseRecipe contents
    mtime      <- tryIO   $ getModificationTime (path </> "STATUS")
    status     <- tryIO   $ TIO.readFile (path </> "STATUS")

    status'    <- maybeToEither "Unknown queue status for compose" (queueStatusFromText status)

    return ComposeStatus { csBuildId = buildId,
                           csName = cs rName,
                           csQueueStatus = status',
                           csTimestamp = mtime,
                           csVersion = maybe "0.0.1" cs rVersion }
