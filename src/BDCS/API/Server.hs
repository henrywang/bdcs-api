-- Copyright (C) 2017 Red Hat, Inc.
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
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

{-| BDCS API Server

    This starts a server and answers the API requests.
-}
module BDCS.API.Server(mkApp,
                       proxyAPI,
                       runServer,
                       ServerStatus(..))
  where

import           BDCS.API.Recipes(openOrCreateRepo, commitRecipeDirectory)
import           BDCS.API.Utils(GitLock(..))
import           BDCS.API.V0(V0API, v0ApiServer)
import qualified Control.Concurrent.ReadWriteLock as RWL
import           Control.Monad(void)
import           Control.Monad.Logger(runStderrLoggingT)
import           Data.Aeson
import           Data.String.Conversions(cs)
import           Database.Persist.Sql
import           Database.Persist.Sqlite
import qualified GI.Ggit as Git
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Middleware.Cors
import           Network.Wai.Middleware.Servant.Options
import           Servant

-- | The status of the server, the database, and the API.
data ServerStatus = ServerStatus
  {  srvVersion   :: String                                     -- ^ Server version
  ,  srvSchema    :: String                                     -- ^ Supported Database Schema version
  ,  srvDb        :: String                                     -- ^ Database version
  ,  srvSupported :: Bool                                       -- ^ True if the Database is supported by the Server
  } deriving (Eq, Show)

instance ToJSON ServerStatus where
  toJSON ServerStatus{..} = object [
      "version"   .= srvVersion
    , "schema"    .= srvSchema
    , "db"        .= srvDb
    , "supported" .= srvSupported ]

instance FromJSON ServerStatus where
  parseJSON = withObject "server status" $ \o -> do
    srvVersion   <- o .: "version"
    srvSchema    <- o .: "schema"
    srvDb        <- o .: "db"
    srvSupported <- o .: "supported"
    return ServerStatus{..}

-- | The /status route
type CommonAPI = "status" :> Get '[JSON] ServerStatus


serverStatus :: Handler ServerStatus
serverStatus = return (ServerStatus "0.0.0" "0" "0" False)

commonServer :: Server CommonAPI
commonServer = serverStatus

-- | The combined API routes, /status and /api/v0/*
type CombinedAPI = CommonAPI
              :<|> "api" :> "v0" :> V0API

combinedServer :: GitLock -> ConnectionPool -> Server CombinedAPI
combinedServer repoLock pool = commonServer
                          :<|> v0ApiServer repoLock pool

-- | CORS policy
appCors :: Middleware
appCors = cors (const $ Just policy)
  where
    policy = simpleCorsResourcePolicy
             { corsRequestHeaders = ["Content-Type"]
             , corsMethods = "PUT" : simpleMethods }

-- | Servant 'Proxy'
--
-- This connects the API to everything else
proxyAPI :: Proxy CombinedAPI
proxyAPI = Proxy

app :: GitLock -> ConnectionPool -> Application
app gitRepo pool = appCors
                 $ provideOptions proxyAPI
                 $ serve proxyAPI
                 $ combinedServer gitRepo pool

-- | Create the server app
--
-- Create a SQLite connection pool, open/create the Git repo, and return the app
mkApp :: FilePath -> FilePath -> IO Application
mkApp gitRepoPath sqliteDbPath = do
    pool <- runStderrLoggingT $ createSqlitePool (cs sqliteDbPath) 5
--    runSqlPool (runMigration migrateAll) pool

    Git.init
    repo <- openOrCreateRepo gitRepoPath
    void $ commitRecipeDirectory repo "master" gitRepoPath
    lock <- RWL.new

    let repoLock = GitLock lock repo

    return $ app repoLock pool

-- | Run the API server
runServer :: Int -> FilePath -> FilePath -> IO ()
runServer port gitRepoPath sqliteDbPath = run port =<< mkApp gitRepoPath sqliteDbPath
