{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
-- | Entry point for proxy pool
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Handlers

import Control.Monad (forever, mzero, when)
import Control.Exception hiding (handle)
import Control.Concurrent (forkIO, ThreadId, threadDelay)
import Control.Applicative ((<$>))

import System.Environment (getArgs)
import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (stdout, IOMode(..))
import System.Exit (exitFailure)

import System.Log.Logger
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple
import System.Log.Formatter

import Data.Word
import Data.Aeson

import Data.Text as T
import Data.Text.Encoding as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Network
import Network.Socket hiding (accept)

import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe

import qualified Database.Redis as R

-- | Manage incoming connections
listenDownstream :: GlobalState -> Word16 -> IO ThreadId
listenDownstream global port = do
    sock <- listenOn $ PortNumber $ fromIntegral port

    setSocketOption sock ReuseAddr 1
    setSocketOption sock NoDelay 1
    _ <- configureKeepAlive sock

    infoM "client" $ "Listening on localhost:" ++ show port
    -- listen for connections on separate thread
    forkIO . forever $ do
        (handle, host, remotePort) <- accept sock
        -- handle each incoming connection on a separate thread
        forkIO $ do
            infoM "client" $ "Accepted connection from " ++ host ++ ":" ++ show remotePort
            bracket
                (initaliseClient handle global)
                finaliseClient
                (handleClient global)
            `catch` \(e :: IOException) -> warningM "client" $ "IOException in client: " ++ show e

-- | Manages publication of shares to Redis
runShareLogger :: GlobalState -> String -> Maybe B.ByteString -> IO ThreadId
runShareLogger global host auth = forkIO $ forever $ do
    infoM "sharelogger" $ "Connecting to " ++  host
    conn <- R.connect $ R.defaultConnectInfo { R.connectHost = host, R.connectAuth = auth }
    handleShareLogging global conn `catches` [ Handler $ \(e :: IOException) -> warningM "sharelogger" $ "IOException in sharelogger: " ++ show e
                                             , Handler $ \(_ :: R.ConnectionLostException) -> warningM "sharelogger" "Redis connection lost"
                                             ]

    threadDelay $ 5000 * 10^(6 :: Int)

-- | Handles connection to upstream pool server
runUpstream :: GlobalState -> String -> Word16 -> IO ThreadId
runUpstream global url port = forkIO $ forever $ do
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just url)
                    (Just $ show port)

    case upstream of
        []  -> criticalM "server" "Could not resolve upstream server"
        x:_ -> bracket
                   (do
                        sock <- socket AF_INET Stream defaultProtocol
                        -- set up socket
                        setSocketOption sock NoDelay 1
                        _ <- configureKeepAlive sock

                        infoM "server" $ "Connecting to upstream: " ++ url ++ ":" ++ show port
                        connectTimeout sock (addrAddress x) 20

                        handle <- socketToHandle sock ReadWriteMode
                        initaliseServer handle
                   )
                   finaliseServer
                   (handleServer global)
               `catch` \(e :: IOException) -> warningM "server" $ "IOException in server: " ++ show e

    threadDelay $ 5000 * 10^(6 :: Int)

main :: IO ()
main = withSocketsDo $ do
    -- read configuration from arguments
    args <- getArgs
    configFilePath <- case args of
        -- try loading configuration file from current directory
        []  -> return "proxypool.json"
        [x] -> return x
        _   -> do
            putStrLn "Usage: proxypool [proxypool.json]\n\tIf the configuration file is not specified, `proxypool.json` in the current directory is used instead"
            exitFailure

    -- load config file
    configResult <- eitherDecode <$> BL.readFile configFilePath
    config <- case configResult of
        Right x -> return x
        Left xs -> do
            putStrLn $ "Error reading config file (" ++ configFilePath ++ "): " ++ xs
            exitFailure

    -- start the logger
    logger <- flip setFormatter (tfLogFormatter "%F %T" "[$time][$loggername][$prio] $msg") <$> streamHandler stdout DEBUG
    updateGlobalLogger rootLoggerName $ setLevel DEBUG . setHandlers [logger]

    -- don't let the process die from a broken pipe
    _ <- installHandler sigPIPE Ignore Nothing

    infoM "main" $ "Starting server with config: " ++ configFilePath

    -- create the global global
    global <- initaliseGlobal config

    _ <- listenDownstream global $ _localPort config
    _ <- runShareLogger global (T.unpack $ _redisHost config) (T.encodeUtf8 <$> _redisAuth config)
    _ <- runUpstream global (T.unpack $ _upstreamHost config) (_upstreamPort config)

    -- hack to get control-c working
    _ <- runMaybeT $ forever $ do
        xs <- liftIO getLine
        when (xs == "exit") mzero

    return ()