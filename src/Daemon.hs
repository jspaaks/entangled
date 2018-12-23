module Daemon
    ( runSession ) where

import System.Directory ( canonicalizePath
                        , doesFileExist
                        , removeFile
                        , createDirectoryIfMissing
                        , makeRelativeToCurrentDirectory)
import Control.Concurrent.Chan
import Control.Concurrent
import System.FilePath (takeDirectory, equalFilePath)
import System.IO

import qualified System.FSNotify as FSNotify
import Data.Function (on)

import qualified Data.Text as T
import qualified Data.Text.IO as T.IO

import qualified Data.Map as M
import Data.List
import Data.Either
import Data.Maybe
import System.Random

import Control.Monad.Reader
import Control.Monad.State

import Lens.Micro.Platform

import Model (TangleError, toTangleError)
import Config
import Tangle
import Untangle
import Markdown
import Document

type Message = String

data FileType = SourceFile | TargetFile deriving (Show, Eq, Ord)
data DaemonState = Idle | Tangling | Untangling deriving (Show, Eq)
data Event = WriteEvent FileType FilePath
           | DebugEvent Message
           deriving (Show)

-- ========================================================================= --
-- Session                                                                   --
-- ========================================================================= --

data Session = Session
    { _sourceData     :: M.Map FilePath [Content]
    , _referenceMap   :: ReferenceMap
    , _watches        :: [FSNotify.StopListening]
    , fsNotifyManager :: FSNotify.WatchManager
    , _eventChannel   :: Chan Event
    , _daemonState    :: MVar DaemonState
    , _randomGen      :: StdGen
    }

type TangleM = StateT Session (ReaderT Config IO)

sourceData :: Lens' Session (M.Map FilePath [Content])
sourceData = lens _sourceData (\s n -> s { _sourceData = n })

referenceMap :: Lens' Session ReferenceMap
referenceMap = lens _referenceMap (\s n -> s { _referenceMap = n })

watches :: Lens' Session [FSNotify.StopListening]
watches = lens _watches (\s n -> s { _watches = n })

eventChannel :: Lens' Session (Chan Event)
eventChannel = lens _eventChannel (\s n -> s { _eventChannel = n })

daemonState :: Lens' Session (MVar DaemonState)
daemonState = lens _daemonState (\s n -> s { _daemonState = n })

randomGen :: Lens' Session StdGen
randomGen = lens _randomGen (\s n -> s { _randomGen = n })

instance RandomGen Session where
    next s  = (s ^. randomGen ^. to next) 
            & _2 %~ (\ x -> s & randomGen .~ x)
    split s = (s ^. randomGen ^. to split)
            & _1 %~ (\ x -> s & randomGen .~ x)
            & _2 %~ (\ x -> s & randomGen .~ x)

setReferenceMap :: Monad m => ReferenceMap -> StateT Session m ()
setReferenceMap r = modify (set referenceMap r)

addFileContent :: Monad m => FilePath -> [Content] -> StateT Session m ()
addFileContent f c = modify (over sourceData (M.insert f c))

updateReferenceMap :: Monad m => (ReferenceMap -> ReferenceMap) -> StateT Session m ()
updateReferenceMap f = modify (over referenceMap f)

getDocument :: Monad m => FilePath -> StateT Session m (Maybe Document)
getDocument p = do
    content <- use $ sourceData . to (M.lookup p)
    refs    <- use referenceMap
    return $ Document refs <$> content

listAllTargetFiles :: Monad m => StateT Session m [FilePath]
listAllTargetFiles = map referenceName . filter isFileReference . M.keys <$> use referenceMap

listAllSourceFiles :: Monad m => StateT Session m [FilePath]
listAllSourceFiles = use $ sourceData . to M.keys

-- ========================================================================= --
-- Tangling                                                                  --
-- ========================================================================= --

tryReadFile :: FilePath -> IO (Maybe T.Text)
tryReadFile f = do
    exists <- doesFileExist f
    if exists
        then Just <$> T.IO.readFile f
        else return Nothing

changeFile :: FilePath -> T.Text -> IO ()
changeFile filename text = do
    createDirectoryIfMissing True (takeDirectory filename)
    oldText <- tryReadFile filename
    case oldText of
        Just ot -> when (ot /= text) $ do
            putStrLn $ "\027[32m    ~ overwriting '" ++ filename ++ "'\027[m"
            T.IO.writeFile filename text
        Nothing -> do
            putStrLn $ "\027[32m    ~ creating '" ++ filename ++ "'\027[m"
            T.IO.writeFile filename text

removeIfExists :: FilePath -> IO ()
removeIfExists f = do
    putStrLn $ "\027[31m    ~ removing '" ++ f ++ "'\027[m"
    fileExists <- doesFileExist f
    when fileExists (removeFile f)

removeFiles :: [FilePath] -> IO ()
removeFiles = mapM_ removeIfExists

writeFileOrWarn :: Show a => FilePath -> Either a T.Text -> IO ()
writeFileOrWarn filename (Left error)
    = putStrLn $ "Error tangling '" ++ filename ++ "': " ++ show error
writeFileOrWarn filename (Right text) =
    changeFile filename text

tangleTargets :: TangleM ()
tangleTargets = do
    refs <- use referenceMap
    fileMap <- lift $ tangleAnnotated refs
    liftIO $ mapM_ (uncurry writeFileOrWarn) (M.toList fileMap)

-- ========================================================================= --
-- Loading                                                                   --
-- ========================================================================= --

loadSourceFile :: FilePath -> TangleM (Either TangleError Document)
loadSourceFile f = do
    source  <- liftIO $ T.IO.readFile f
    parseMarkdown f source

addSourceFile :: FilePath -> TangleM ()
addSourceFile f = do
    source  <- liftIO $ T.IO.readFile f
    refs    <- use referenceMap
    doc'    <- parseMarkdown' refs f source
    case doc' of
        Left err -> liftIO $ putStrLn $ "Error loading '" ++ f ++ "': "
                        ++ show err
        Right (Document r c) -> do
            setReferenceMap r
            addFileContent f c

removeActiveReferences :: Document -> TangleM ()
removeActiveReferences doc = do
    let rs = listActiveReferences doc
    mapM_ (modifying referenceMap . M.delete) rs

updateFromSource :: FilePath -> TangleM ()
updateFromSource fp = do
    doc' <- loadSourceFile fp
    case doc' of
        Left err -> liftIO $ putStrLn $ "Error loading '" ++ fp ++ "': " ++ show err
        Right (Document r c) -> do
            modifying referenceMap (M.union r)
            modifying sourceData (M.insert fp c)

-- ========================================================================= --
-- Untangle                                                                  --
-- ========================================================================= --

untangleTarget :: FilePath -> ReaderT Config IO (Either TangleError ReferenceMap)
untangleTarget f = liftIO (readFile f) >>= untangle f

getCodeBlock :: Monad m => ReferenceId -> StateT Session m (Maybe CodeBlock)
getCodeBlock id = use $ referenceMap . to (M.lookup id)

updateCodeBlock :: ReferenceId -> CodeBlock -> TangleM ()
updateCodeBlock r c = do
    old' <- getCodeBlock r
    case old' of
        Nothing -> liftIO $ putStrLn $ "  Error: code block " ++ show r ++ " not present."
        Just old -> when (old /= c) $ do
            liftIO $ putStrLn $ "    ~ updating " ++ show r
            updateReferenceMap $ M.insert r c

updateFromTarget :: FilePath -> TangleM ()
updateFromTarget f = do
    refs' <- lift $ untangleTarget f
    case refs' of
        Left err -> liftIO $ putStrLn $ "Error updating from '" ++ f ++ "': "
                        ++ show err
        Right refs -> do
            liftIO $ putStrLn $ "  -- updating from '" ++ f ++ "':"
            mapM_ (uncurry updateCodeBlock) (M.toList refs)

-- ========================================================================= --
-- Stitching                                                                 --
-- ========================================================================= --

stitchSourceFile :: FilePath -> TangleM ()
stitchSourceFile f = do
    doc' <- getDocument f
    case doc' of
        Nothing  -> return ()
        Just doc -> liftIO $ changeFile f (stitchText doc)

stitchSources :: TangleM ()
stitchSources = do
    srcs <- listAllSourceFiles
    mapM_ stitchSourceFile srcs

-- ========================================================================= --
-- Watching                                                                  --
-- ========================================================================= --

passEvent :: MVar DaemonState -> Chan Event -> [FilePath] -> [FilePath] -> FSNotify.Event -> IO ()
passEvent _  _       _    _    FSNotify.Removed {} = return ()
passEvent ds channel srcs tgts fsEvent = do
    path <- canonicalizePath $ FSNotify.eventPath fsEvent
    relpath <- makeRelativeToCurrentDirectory path
    ds' <- readMVar ds
    let isSourceFile = any (equalFilePath path) srcs
        isTargetFile = any (equalFilePath path) tgts
        pass = case ds' of
                    Idle -> isSourceFile || isTargetFile
                    Tangling -> isSourceFile
                    Untangling -> isTargetFile
    when pass $ do
        let filetype = if isSourceFile then SourceFile else TargetFile
            event = WriteEvent filetype path
        putStrLn $ "\027[33m----- :state: " ++ show ds' ++ " :event: " ++ show event ++ " -----\027[m"
        writeChan channel event

setWatch :: TangleM ()
setWatch = do
    srcs <- listAllSourceFiles >>= (liftIO . mapM canonicalizePath)
    tgts <- listAllTargetFiles >>= (liftIO . mapM canonicalizePath)

    fsnotify <- gets fsNotifyManager
    channel  <- use eventChannel

    let dirs = nub $ map takeDirectory (srcs ++ tgts)
    reldirs <- liftIO $ mapM makeRelativeToCurrentDirectory dirs
    liftIO $ putStrLn $ "    ~ Setting watch on: "
        ++ show reldirs
    ds <- use daemonState
    stopActions <- liftIO $ mapM
        (\dir -> FSNotify.watchDir fsnotify dir (const True)
                                   (passEvent ds channel srcs tgts))
        dirs
    assign watches stopActions

removeWatch :: TangleM ()
removeWatch = do
    liftIO $ putStrLn "    ~ Removing watches."
    w <- use watches
    liftIO $ sequence_ w

-- ========================================================================= --
-- Main interface                                                            --
-- ========================================================================= --

setDaemonState :: DaemonState -> TangleM ()
setDaemonState s = do
    ds <- use daemonState
    liftIO $ modifyMVar_ ds (const $ return s)

wait :: TangleM ()
wait = liftIO $ threadDelay 100000

mainLoop :: [Event] -> TangleM ()

mainLoop [] = return ()

mainLoop (WriteEvent SourceFile fp : xs) = do
    liftIO $ putStrLn $ "Tangling " ++ fp
    wait
    setDaemonState Tangling
    doc <- fromJust <$> getDocument fp  -- TODO: do proper error handling here
    oldTgtFiles <- listAllTargetFiles
    removeActiveReferences doc
    updateFromSource fp
    tangleTargets
    newTgtFiles <- listAllTargetFiles
    liftIO $ removeFiles (oldTgtFiles \\ newTgtFiles)
    wait
    removeWatch
    setWatch
    setDaemonState Idle
    liftIO $ putStrLn "  -- done tangling "
    mainLoop xs

mainLoop (WriteEvent TargetFile fp : xs) = do
    liftIO $ putStrLn $ "Untangling " ++ fp
    setDaemonState Untangling
    updateFromTarget fp
    stitchSources
    wait
    setDaemonState Idle
    liftIO $ putStrLn "  -- done untangling"
    mainLoop xs

mainLoop (DebugEvent msg : xs)   = do
    liftIO $ putStrLn $ "Debug: " ++ msg
    mainLoop xs

startSession :: [FilePath] -> TangleM ()
startSession fs = do
    mapM_ addSourceFile fs
    tangleTargets
    setWatch
    eventList' <- use $ eventChannel . to getChanContents
    eventList  <- liftIO eventList'
    mainLoop eventList

runSession :: Config -> [FilePath] -> IO ()
runSession cfg fs = do
    hSetBuffering stdout LineBuffering
    fs' <- mapM canonicalizePath fs
    fsnotify <- liftIO FSNotify.startManager
    channel <- newChan
    ds <- newMVar Idle
    rnd <- getStdGen
    let session = Session M.empty M.empty [] fsnotify channel ds rnd
    runReaderT (runStateT (startSession fs') session) cfg
    liftIO $ FSNotify.stopManager fsnotify