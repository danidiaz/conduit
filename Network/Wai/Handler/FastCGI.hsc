{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE EmptyDataDecls #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Wai.Handler.FastCGI
-- Copyright   :  (c) Bjorn Bringert 2004-2005, (c) Lemmih 2006
-- License     :  BSD-style (see the file libraries/network/LICENSE)
-- 
-- Maintainer  :  michael@snoyman.com
-- Stability   :  experimental
-- Portability :  non-portable (uses FFI)
--
-- Interface for FastCGI <http://fastcgi.com/>, using the fcgiapp API.
-- Totally ripped off by Michael Snoyman to work with Hack, then WAI.
--
-----------------------------------------------------------------------------
module Network.Wai.Handler.FastCGI
    (
    -- * Single-threaded interface
      runFastCGIorCGI
    , runOneFastCGIorCGI
    , runFastCGI
    , runOneFastCGI
    -- * Concurrent interface
    , runFastCGIConcurrent
    , runFastCGIConcurrent'
    ) where

import Data.Maybe
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Control.Concurrent ( forkOS )
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception as Exception (catch, finally)
import Control.Monad    ( liftM )
import Data.Word (Word8)
import Foreign          ( Ptr, castPtr, nullPtr, peekArray0 
                        , alloca, mallocBytes, free, throwIfNeg_)
import Foreign.C        ( CInt, CString, CStringLen
                        , peekCString )
import Foreign.Storable ( Storable (..) )
import System.IO.Unsafe (unsafeInterleaveIO,unsafePerformIO)

import qualified Network.Wai as W
import qualified Network.Wai.Enumerator as WE
import qualified Network.Wai.Source as WS
import qualified Network.Wai.Handler.CGI as CGI

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy.Char8 as Lazy
#if __GLASGOW_HASKELL__ >= 608
import qualified Data.ByteString.Internal as BSB
import qualified Data.ByteString.Unsafe   as BSB
#else
import qualified Data.ByteString.Base as BSB
#endif

-- For debugging
import Control.Concurrent ( myThreadId )
import Prelude hiding     ( log, catch )
import System.IO          ( hPutStrLn, stderr )
import qualified System.IO
import Control.Arrow ((***))
import Data.Char (toLower)

#include <fcgiapp.h>

------------------------------------------------------------------------

data FCGX_Stream
type StreamPtr = Ptr FCGX_Stream
type Environ = Ptr CString

------------------------------------------------------------------------

foreign import ccall unsafe "fcgiapp.h FCGX_IsCGI" fcgx_isCGI
    :: IO CInt

foreign import ccall unsafe "fcgiapp.h FCGX_GetStr" fcgx_getStr
    :: CString -> CInt -> StreamPtr -> IO CInt

foreign import ccall unsafe "fcgiapp.h FCGX_PutStr" fcgx_putStr
    :: CString -> CInt -> StreamPtr -> IO CInt

foreign import ccall threadsafe "fcgiapp.h FCGX_Accept" fcgx_accept
    :: Ptr StreamPtr -> Ptr StreamPtr -> Ptr StreamPtr -> Ptr Environ -> IO CInt
foreign import ccall unsafe "fcgiapp.h FCGX_Finish" fcgx_finish
    :: IO ()

------------------------------------------------------------------------

-- | Handle a single CGI request, or FastCGI requests in an infinite loop.
--   This function only returns normally if it was a CGI request.
--   This lets you use the same program
--   as either a FastCGI or CGI program, depending on what the server 
--   treats it as.
runFastCGIorCGI :: W.Application -> IO ()
runFastCGIorCGI f = do fcgi <- runOneFastCGIorCGI f
                       if fcgi then runFastCGIorCGI f
                               else return ()

-- | Handle a single FastCGI or CGI request. This lets you use the same program
--   as either a FastCGI or CGI program, depending on what the server 
--   treats it as.
runOneFastCGIorCGI :: W.Application
                   -> IO Bool -- ^ True if it was a FastCGI request, 
                              --   False if CGI.
runOneFastCGIorCGI f =
    do x <- fcgx_isCGI
       if x /= 0 then CGI.run f >> return False
                 else runOneFastCGI f >> return True

-- | Handle FastCGI requests in an infinite loop.
runFastCGI :: W.Application -> IO ()
runFastCGI f = runOneFastCGI f >> runFastCGI f

-- | Handle a single FastCGI request.
runOneFastCGI :: W.Application -> IO ()
runOneFastCGI f = do
    alloca (\inp ->
            alloca (\outp ->
                    alloca (\errp ->
                            alloca (\envp ->
                                    oneRequest f inp outp errp envp))))

oneRequest :: W.Application
           -> Ptr StreamPtr
           -> Ptr StreamPtr
           -> Ptr StreamPtr
           -> Ptr Environ
           -> IO ()
oneRequest f inp outp errp envp =
    do
    testReturn "FCGX_Accept" $ fcgx_accept inp outp errp envp
    ins  <- peek inp
    outs <- peek outp
    errs <- peek errp
    env  <- peek envp
    handleRequest f ins outs errs env
    fcgx_finish

handleRequest :: W.Application
              -> StreamPtr
              -> StreamPtr
              -> StreamPtr
              -> Environ
              -> IO ()
handleRequest f ins outs _errs env =
    do
    vars <- environToTable env
    input <- sRead ins
    let hPut = sPutStr' outs
    run' vars input hPut f



data FCGX_Request

foreign import ccall unsafe "fcgiapp.h FCGX_Init" fcgx_init
    :: IO CInt

foreign import ccall unsafe "fcgiapp.h FCGX_InitRequest" fcgx_initrequest
    :: Ptr FCGX_Request -> CInt -> CInt -> IO CInt

foreign import ccall threadsafe "fcgiapp.h FCGX_Accept_r" fcgx_accept_r
    :: Ptr FCGX_Request -> IO CInt

foreign import ccall unsafe "fcgiapp.h FCGX_Finish_r" fcgx_finish_r
    :: Ptr FCGX_Request -> IO ()

-- | Like 'Network.CGI.runCGI', but uses the FastCGI interface
--   and forks off a new thread (using 'forkOS') for every request.
runFastCGIConcurrent :: Int -- ^ Max number of concurrent threads.
                     -> W.Application -> IO ()
runFastCGIConcurrent = runFastCGIConcurrent' forkOS

runFastCGIConcurrent' :: (IO () -> IO a) -- ^ How to fork a request.
                      -> Int             -- ^ Max number of concurrent threads.
                      -> W.Application -> IO ()

runFastCGIConcurrent' fork m f
    = do qsem <- newQSem m
         testReturn "FCGX_Init" $ fcgx_init
         let loop = do waitQSem qsem
                       reqp <- acceptRequest
                       fork (oneRequestMT f reqp
                             `finally`
                            (finishRequest reqp >> signalQSem qsem))
                       loop
         loop -- FIXME `catch` \e -> log (show e)

oneRequestMT :: W.Application -> Ptr FCGX_Request -> IO ()
oneRequestMT app r = do
     env    <- peekEnvp r
     vars   <- environToTable env
     ins    <- peekIn r
     input  <- sRead ins
     outs   <- peekOut r
     let hPut = sPutStr' outs
     run' vars input hPut app
--
-- * FCGX_Reqest struct
--

acceptRequest :: IO (Ptr FCGX_Request)
acceptRequest = do
    reqp <- mallocBytes (#size FCGX_Request)
    initAndAccept reqp
    return reqp
  where initAndAccept reqp = do
          testReturn "FCGX_InitRequest" $ fcgx_initrequest reqp 0 0
          testReturn "FCGX_Accept_r" $ fcgx_accept_r reqp

finishRequest :: Ptr FCGX_Request -> IO ()
finishRequest reqp = do
                     fcgx_finish_r reqp
                     free reqp

peekIn, peekOut, _peekErr :: Ptr FCGX_Request -> IO (Ptr FCGX_Stream)
peekIn  = (#peek FCGX_Request, in)
peekOut = (#peek FCGX_Request, out)
_peekErr = (#peek FCGX_Request, err)

peekEnvp :: Ptr FCGX_Request -> IO Environ
peekEnvp = (#peek FCGX_Request, envp)


--
-- * Stream IO
--

sPutStr' :: StreamPtr -> BS.ByteString -> IO ()
sPutStr' h str =
    BSB.unsafeUseAsCStringLen str $ fcgxPutCStringLen h

sPutStr :: StreamPtr -> Lazy.ByteString -> IO ()
sPutStr h str =
    mapM_ (flip BSB.unsafeUseAsCStringLen (fcgxPutCStringLen h)) (Lazy.toChunks str)

fcgxPutCStringLen :: StreamPtr -> CStringLen -> IO ()
fcgxPutCStringLen h (cs,len) =
    testReturn "FCGX_PutStr" $ fcgx_putStr cs (fromIntegral len) h

sRead :: StreamPtr -> IO Lazy.ByteString
sRead h = buildByteString (fcgxGetBuf h) 4096

fcgxGetBuf :: StreamPtr -> Ptr a -> Int -> IO Int
fcgxGetBuf h p c =
    liftM fromIntegral $ fcgx_getStr (castPtr p) (fromIntegral c) h

--
-- * ByteString utilities
--

-- | Data.ByteString.Lazy.hGetContentsN generalized to arbitrary 
--   reading functions.
buildByteString :: (Ptr Word8 -> Int -> IO Int) -> Int -> IO Lazy.ByteString
buildByteString f k = lazyRead >>= return . Lazy.fromChunks
  where
    lazyRead = unsafeInterleaveIO $ do
        ps <- BSB.createAndTrim k $ \p -> f p k
        case BS.length ps of
            0         -> return []
            n | n < k -> return [ps]
            _         -> do pss <- lazyRead
                            return (ps : pss)

--
-- * Utilities
--

testReturn :: String -> IO CInt -> IO ()
testReturn e = throwIfNeg_ (\n -> e ++ " failed with error code: "++ show n)

environToTable :: Environ -> IO [(String,String)]
environToTable arr =
    do css <- peekArray0 nullPtr arr
       ss <- mapM peekCString css
       return $ map (splitBy '=') ss

-- | Split a list at the first occurence of a marker.
--   Do not include the marker in any of the resulting lists.
--   If the marker does not occur in the list, the entire
--   input with be in the first list.
splitBy :: Eq a => a -> [a] -> ([a],[a])
splitBy x xs = (y, drop 1 z)
    where (y,z) = break (==x) xs

--
-- * Debugging
--

{-# NOINLINE logMutex #-}
logMutex :: MVar ()
logMutex = unsafePerformIO (newMVar ())

log :: String -> IO ()
log msg = do
          t <- myThreadId
          withMVar logMutex (const $ hPutStrLn stderr (show t ++ ": " ++ msg))

run' :: [(String, String)] -- ^ all variables
     -> Lazy.ByteString -- ^ responseBody of input
     -> (BS.ByteString -> IO ()) -- ^ destination for output
     -> W.Application
     -> IO ()
run' vars inputH hPut app = do
    let rmethod = safeRead W.GET $ lookup' "REQUEST_METHOD" vars
        pinfo = lookup' "PATH_INFO" vars
        qstring = lookup' "QUERY_STRING" vars
        servername = lookup' "SERVER_NAME" vars
        serverport = safeRead 80 $ lookup' "SERVER_PORT" vars
        contentLength = safeRead 0 $ lookup' "CONTENT_LENGTH" vars
        remoteHost' =
            case lookup "REMOTE_HOST" vars of
                Just x -> x
                Nothing ->
                    case lookup "REMOTE_ADDR" vars of
                        Just x -> x
                        Nothing -> ""
        urlScheme' =
            case map toLower $ lookup' "SERVER_PROTOCOL" vars of
                "https" -> W.HTTPS
                _ -> W.HTTP
    let env = W.Request
            { W.requestMethod = rmethod
            , W.pathInfo = B8.pack pinfo
            , W.queryString = B8.pack qstring
            , W.serverName = B8.pack servername
            , W.serverPort = serverport
            , W.requestHeaders = map (cleanupVarName *** B8.pack) vars
            , W.urlScheme = urlScheme'
            , W.requestBody = requestBodyLBS inputH contentLength
            , W.errorHandler = System.IO.hPutStr System.IO.stderr
            , W.remoteHost = B8.pack remoteHost'
            , W.httpVersion = W.HttpVersion BS.empty
            }
    res <- app env
    let h = W.responseHeaders res
    let h' = case lookup W.ContentType h of
                Nothing -> (W.ContentType, B8.pack "text/html; charset=utf-8")
                         : h
                Just _ -> h
    hPut $ B8.pack $ "Status: " ++ (show $ W.statusCode $ W.status res) ++ " "
    hPut $ W.statusMessage $ W.status res
    hPut $ B8.singleton '\n'
    mapM_ (printHeader hPut) h'
    hPut $ B8.singleton '\n'
    _ <- W.runEnumerator (WE.fromEitherFile (W.responseBody res)) (myPut hPut) ()
    return ()

myPut :: (BS.ByteString -> IO ()) -> () -> BS.ByteString -> IO (Either () ())
myPut output () bs = output bs >> return (Right ())

printHeader :: (BS.ByteString -> IO ())
            -> (W.ResponseHeader, BS.ByteString)
            -> IO ()
printHeader f (x, y) = do
    f $ W.responseHeaderToBS x
    f $ B8.pack ": "
    f y
    f $ B8.singleton '\n'

cleanupVarName :: String -> W.RequestHeader
cleanupVarName ('H':'T':'T':'P':'_':a:as) =
  W.requestHeaderFromBS $ B8.pack $ a : helper' as where
    helper' ('_':x:rest) = '-' : x : helper' rest
    helper' (x:rest) = toLower x : helper' rest
    helper' [] = []
cleanupVarName "CONTENT_TYPE" = W.ReqContentType
cleanupVarName "CONTENT_LENGTH" = W.ReqContentLength
cleanupVarName "SCRIPT_NAME" = W.requestHeaderFromBS $ B8.pack "CGI-Script-Name"
cleanupVarName x = W.requestHeaderFromBS $ B8.pack x -- FIXME remove?

requestBodyLBS :: Lazy.ByteString -> Int -> W.Source
requestBodyLBS l len = go (Lazy.toChunks l) len
  where
    go _ 0 = W.Source $ return Nothing
    go (l:ls) len =
        let len' = len - BS.length l
            len'' = if len' < 0 then 0 else len'
         in W.Source $ return $ Just (l, go ls len'')

lookup' :: String -> [(String, String)] -> String
lookup' key pairs = fromMaybe "" $ lookup key pairs

safeRead :: Read a => a -> String -> a
safeRead d s =
  case reads s of
    ((x, _):_) -> x
    [] -> d
