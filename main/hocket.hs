{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
#if __GLASGOW_HASKELL__ >= 710

import           Control.Monad.Except (runExceptT)
import           Data.Foldable (traverse_, for_, foldr', find)
import           Data.Time.Format (defaultTimeLocale)
import           Data.Traversable (for)

#else

import           Control.Applicative ((<*>), pure)
import           Control.Monad.Error (runErrorT)
import           Data.Foldable (traverse_, for_, Foldable, foldr', find)
import           Data.Traversable (Traversable, for)
import           System.Locale (defaultTimeLocale)

#endif

import           Control.Concurrent (forkIO, MVar, takeMVar, readMVar, putMVar, newMVar, swapMVar, modifyMVar_)
import           Control.Concurrent.Async (async, Async, poll, cancel)
import           Control.Exception (try)
import           Control.Lens (_Right, non, preview, view, folded, toListOf)
import           Control.Lens.Action (perform, act, (^!))
import           Control.Lens.Operators
import           Control.Lens.TH
import           Control.Monad (join, void, when)
import           Control.Monad.IO.Class (liftIO)
import           Data.ConfigFile
import           Data.Default
import qualified Data.Function as F
import           Data.Functor ((<$>))
import           Data.List (deleteFirstsBy, partition)
import           Data.Maybe (isNothing, catMaybes)
import           Data.Monoid ((<>))
import           Data.Table (Table)
import qualified Data.Table as TB
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time.Clock.POSIX (POSIXTime, posixSecondsToUTCTime)
import           Data.Time.Format (formatTime)
import           Data.Time.LocalTime (LocalTime(..), utcToLocalTime, getCurrentTimeZone)
import           Graphics.Vty
import           Graphics.Vty.Widgets.All hiding (Table)
import           Network.HTTP.Client (HttpException)
import           System.Environment (getArgs)
import           System.Exit (exitSuccess, exitWith, ExitCode(ExitFailure))
import           System.Process
import           Text.Printf (printf)
import qualified Text.Trans.Tokenize as TT

import           GUI
import           Network.Pocket
import           Network.Pocket.Retrieve ( RetrieveConfig
                                         , retrieveCount
                                         , RetrieveCount(Count, NoLimit)
                                         , retrieveSort
                                         , RetrieveSort(NewestFirst)
                                         , retrieveSince
                                         , RetrieveState(All)
                                         , retrieveState
                                         , RetrieveDetailType(Complete)
                                         , retrieveDetailType
                                         )
import           Printing

makeLensesFor [("std_err", "stdErr"), ("std_out", "stdOut")] ''CreateProcess

newtype ShellCommand = Cmd String

data HocketData = HocketData { _dataTime :: Maybe POSIXTime
                             , _dataItems :: Table PocketItem
                             }
makeLenses ''HocketData

consumeBatch :: HocketData -> PocketItemBatch -> HocketData
consumeBatch bt1@(HocketData maybeTs1 tb1) (PocketItemBatch ts2 tb2) =
  case maybeTs1 of
    Nothing -> HocketData (Just ts2) (tb1 `TB.union` view TB.table tb2)
    Just ts1 -> if ts1 >= ts2
                then bt1
                else HocketData (Just ts2) (withoutArchived `TB.union` TB.fromList unreadItems)
  where (unreadItems, archivedOrDeleted) = partition ((== Normal) . view status) tb2
        withoutArchived = tb1 `TB.difference` TB.fromList archivedOrDeleted

data HocketGUI = HocketGUI { _unreadLst :: Widget (List PocketItem FormattedText)
                           , _toArchiveLst :: Widget (List PocketItem FormattedText)
                           , _helpBar :: Widget FormattedText
                           , _statusBar :: Widget FormattedText
                           , _timeStamp :: Widget FormattedText
                           , _guiCreds :: PocketCredentials
                           , _launchCommand :: ShellCommand
                           , _mainFocusGroup :: Widget FocusGroup
                           , _titleText :: Widget FormattedText
                           , _asyncAction :: MVar (Async ())
                           , _hocketData :: MVar HocketData
                           }
makeLenses ''HocketGUI

modifyData :: HocketGUI -> (HocketData -> HocketData) -> IO ()
modifyData (view hocketData -> m) f = modifyMVar_ m (return . f)

main :: IO ()
main = do
  Just (creds,cmd) <- readFromConfig "hocket.cfg"
  args <- (fmap . fmap ) T.pack getArgs
  when (null args) $ do
    putStrLn "Invalid args, has to be one of [get <n>, add <url>..., gui]"
    exitWith (ExitFailure 1)
  let (dispatch,rest) = (head args, tail args)
  runHocket (creds,def) $ case dispatch of
    "get" -> do
      let c = read . T.unpack . head $ rest
          retCfg = defaultRetrieval & retrieveCount .~ Count c
      liftIO . newestFirst =<< view batchItems <$> pocket (RetrieveItems retCfg)
    "add" -> traverse_ (pocket . AddItem) rest
    "gui" -> liftIO . vty cmd creds $ []
    _ -> fail "Invalid args."

readFromConfig :: FilePath -> IO (Maybe (PocketCredentials, ShellCommand))
readFromConfig path = do
#if __GLASGOW_HASKELL__ >= 710
  eitherErrorTuple <- runExceptT $ do
#else
  eitherErrorTuple <- runErrorT $ do
#endif
    cp <- join $ liftIO $ readfile emptyCP path
    consumerKey <- get cp "Credentials" "consumer_key"
    accessToken <- get cp "Credentials" "access_token"
    cmd <- get cp "Launch" "launch_cmd"
    return ( PocketCredentials (ConsumerKey consumerKey)
                               (AccessToken accessToken)
           , Cmd cmd
           )
  return . preview _Right $ eitherErrorTuple

browseItem :: ShellCommand -> URL -> IO ()
browseItem (Cmd shellCmd) (URL url) = do
  let spec = shell $ printf shellCmd url
  void . createProcess $ spec & stdOut .~ CreatePipe
                              & stdErr .~ CreatePipe

-- used to right align urls in gui using vty-ui formatter 'alignRightAfter' (defined here)
magicMarker :: Text
magicMarker = "<!>"

tryStripPrefix :: Text -> Text -> Text
tryStripPrefix p t = view (non t) $ T.stripPrefix p t

shortenUrl :: URL -> Text
shortenUrl (URL (T.pack -> t)) = T.take 60 . cleanUrl $ t
  where cleanUrl :: Text -> Text
        cleanUrl = tryStripPrefix "www." . tryStripPrefix "http://" . tryStripPrefix "https://"

displayText :: PocketItem -> Text
displayText i = T.concat [formatTags (view itemTags i)
                         ,bestTitle i
                         ," "
                         ,magicMarker
                         ,shortenUrl (view resolvedUrl i)]

formatTags :: [Tag] -> Text
formatTags tags = if null tags
  then ""
  else "" <> (T.intercalate "," $ toListOf (folded . tagName) tags) <> " | "

alignRightAfter :: Text -> Formatter
alignRightAfter marker = Formatter $ \(w, _) ts -> do
  let currentText = TT.serialize ts
      parts = T.splitOn marker currentText
      neededSpaces = 0 `max` (w - fromIntegral (T.length currentText - T.length marker))
      sp = T.replicate (fromIntegral neededSpaces) " "
      newText = flip TT.tokenize defAttr $ T.intercalate sp parts
  return newText

sortedAddLstItem :: Widget (List PocketItem FormattedText) -> PocketItem -> IO ()
sortedAddLstItem = addToListSortedBy lt (textWidget (alignRightAfter magicMarker) . displayText)
  where
    lt :: PocketItem -> PocketItem -> Ordering
    lt = flip compare `F.on` view timeAdded

bestTitle :: PocketItem -> Text
bestTitle itm =
  view (if view givenTitle itm /= "" then givenTitle else resolvedTitle) itm

abortAsync :: HocketGUI -> IO ()
abortAsync gui@(view asyncAction -> m) = do
  v <- readMVar m
  stat <- poll v
  case stat of
    Nothing -> cancel v >> updateStatusBar gui "Aborted"
    Just _ -> return ()

tryAsync :: HocketGUI -> IO () -> IO ()
tryAsync (view asyncAction -> m) a = do
  finished <- poll =<< readMVar m
  case finished of
    Nothing -> return ()
    Just _ -> takeMVar m >> (putMVar m =<< async a)

insertPocketItems :: Traversable f =>
                     Widget (List PocketItem FormattedText)
                     -> f PocketItem -> IO ()
insertPocketItems lst = traverse_ (sortedAddLstItem lst)

extractAndClear :: Widget (List a b) -> IO [a]
extractAndClear lst = do
  itms <- listItems lst
  clearList lst
  return itms

updateStatusBar :: HocketGUI -> T.Text -> IO ()
updateStatusBar gui txt = schedule $ setText (view statusBar gui) txt

posixToLocalTime :: POSIXTime -> IO LocalTime
posixToLocalTime p = utcToLocalTime
                 <$> getCurrentTimeZone
                 <*> pure (posixSecondsToUTCTime p)

formatPosix :: POSIXTime -> IO String
formatPosix = fmap (formatTime defaultTimeLocale "%T") . posixToLocalTime

lastRetrieval :: HocketGUI -> IO (Maybe POSIXTime)
lastRetrieval = perform (hocketData . act readMVar . dataTime)

updateTimeStamp :: HocketGUI -> IO ()
updateTimeStamp gui = do
  currentTS <- lastRetrieval gui
  case currentTS of
    Nothing -> return ()
    Just ts -> schedule $ setText (view timeStamp gui) =<< (T.pack <$> formatPosix ts)

defaultRetrieval :: RetrieveConfig
defaultRetrieval = def & retrieveSort ?~ NewestFirst
                       & retrieveCount .~ NoLimit
                       & retrieveDetailType ?~ Complete

retrievalConfig :: HocketGUI -> IO RetrieveConfig
retrievalConfig gui = do
  isFirstRetrieval <- isNothing <$> lastRetrieval gui
  return (if isFirstRetrieval
             then defaultRetrieval
             else defaultRetrieval & retrieveState .~ All)

retrieveNewItems :: HocketGUI -> IO ()
retrieveNewItems gui = tryAsync gui $ do
  lastRetrieved <- lastRetrieval gui
  retCfg <- retrievalConfig gui <&> retrieveSince .~ lastRetrieved
  updateStatusBar gui "Updating"
  oldPIs <- (++) <$> listItems (view unreadLst gui)
                 <*> listItems (view toArchiveLst gui)
  eitherErrorPIs <- tryHttpException
                    . runHocket (view guiCreds gui, def) $ pocket $ RetrieveItems retCfg
  case eitherErrorPIs of
    Right batch -> do
      modifyData gui (`consumeBatch` batch)
      updateTimeStamp gui
      let (unreadPis, archivedOrDeleted) =
            partition ((== Normal) . view status) $ view batchItems batch
      schedule $ do
        traverse_ (removeItemFromLstBy idEq (view unreadLst gui)) archivedOrDeleted
        traverse_ (removeItemFromLstBy idEq (view toArchiveLst gui)) archivedOrDeleted
        traverse_ (sortedAddLstItem (view unreadLst gui)) $ unreadPis \\\ oldPIs
      updateStatusBar gui ""
    Left _ -> updateStatusBar gui "Updating failed"
  where (\\\) = deleteFirstsBy idEq

removeItemFromLstBy :: (a -> a -> Bool) -> Widget (List a b) -> a -> IO ()
removeItemFromLstBy eq w e = do
  maybePos <- Main.listFindFirstBy eq w e
  traverse_ (removeFromList w) maybePos

listFindFirstBy :: (a -> a -> Bool) -> Widget (List a b) -> a -> IO (Maybe Int)
listFindFirstBy eq w e = do size <- getListSize w
                            itms <- catMaybes <$> for [0..size-1] (\i -> fmap (i,) <$> getListItem w i)
                            return $ fst <$> find (eq e . fst . snd) itms

removeItemFromLst :: Eq a => Widget (List a b) -> a -> IO ()
removeItemFromLst = removeItemFromLstBy (==)

executeRenameSelected :: HocketGUI -> Widget (List PocketItem b) -> Text -> IO ()
executeRenameSelected gui w newTxt = withSelection w $ \_ sel -> tryAsync gui $ do
    updateStatusBar gui "Renaming"
    res <- tryHttpException $ runHocket (view guiCreds gui, def) $
      pocket $ RenameItem (view itemId sel) newTxt
    case res of
      Left _ -> sigFail
      Right b -> if b then do
                      removeItemFromLst w sel
                      modifyData gui (dataItems %~ TB.delete sel)
                      sigSucc
                 else sigFail
  where sigFail = updateStatusBar gui "Renaming failed"
        sigSucc = updateStatusBar gui ""

executeArchiveAction :: HocketGUI -> IO ()
executeArchiveAction gui = tryAsync gui $ do
    updateStatusBar gui "Archiving"
    let archiveLst = view toArchiveLst gui
    itms <- listItems archiveLst
    res <- performArchive gui archiveLst itms
    updateStatusBar gui . maybe "" (const "Archieving failed") $ res

performArchive :: HocketGUI
               -> Widget (List PocketItem b)
               -> [PocketItem]
               -> IO (Maybe HttpException)
performArchive gui archiveLst itms = do
  res <- tryHttpException $ runHocket (view guiCreds gui, def) $ do
    bs <- pocket $ Batch (map (Archive . view itemId) itms)
    return [i | (i,success) <- zip itms bs, success]
  case res of
    Left e -> return $ Just e
    Right archivedItms -> do
      modifyData gui (dataItems %~ deleteAll archivedItms)
      schedule . traverse_ (removeItemFromLst archiveLst) $ archivedItms
      return Nothing

deleteAll :: Foldable f => f t -> TB.Table t -> TB.Table t
deleteAll ts table = foldr' TB.delete table ts

createGUI :: ShellCommand -> PocketCredentials -> IO (HocketGUI, Collection)
createGUI shCmd cred = do
  let focusedAttr = boldBlackOnOrange
  gui <- HocketGUI <$> newList' focusedAttr defAttr
                   <*> newList' focusedAttr defAttr
                   <*> (plainText . T.intercalate " | " $ [ "q:Quit"
                                                          , "Q:Force Quit"
                                                          , "d:Shift item"
                                                          , "D:Shift all"
                                                          , "u:Update"
                                                          , "U:Clear & update"
                                                          , "A:Archive pending"
                                                          , "C:Cancel"
                                                          , "SPC:Launch"
                                                          , "Enter:Launch & Shift"
                                                          ])
                   <*> plainText ""
                   <*> plainText "<never>"
                   <*> pure cred
                   <*> pure shCmd
                   <*> newFocusGroup
                   <*> plainText "Hocket"
                   <*> (newMVar =<< async (return ()))
                   <*> newMVar (HocketData Nothing TB.empty)

  bottomBar <- pure (view helpBar gui) <++>
               hFill ' ' 1 <++>
               pure (view statusBar gui) <++>
               plainText " " <++>
               pure (view timeStamp gui)
  topBar <- pure (view titleText gui) <++> hFill ' ' 1

  setNormalAttribute bottomBar $ Attr KeepCurrent KeepCurrent (SetTo black)
  setNormalAttribute topBar $ Attr KeepCurrent KeepCurrent (SetTo black)
  setNormalAttribute (view statusBar gui) $ Attr (SetTo bold) KeepCurrent KeepCurrent

  for_ [helpBar, statusBar] $ \selector ->
    setNormalAttribute (view selector gui) $ Attr KeepCurrent (SetTo white) KeepCurrent

  ui <- centered =<< pure topBar
                <--> pure (view unreadLst gui)
                <--> hBorder
                <--> vFixed 10 (view toArchiveLst gui)
                <--> pure bottomBar

  let fg = view mainFocusGroup gui
  void $ addToFocusGroup fg (view unreadLst gui)
  void $ addToFocusGroup fg (view toArchiveLst gui)

  c <- newCollection

  edlg <- newEditDialog
  displayMainGui <- addToCollection c ui fg
  displayEditDialog <- addToCollection c
    (edlg ^. editDlgDialog & dialogWidget)
    (edlg ^. editDlgFocusGroup)

  setUpEditHandler edlg (view unreadLst gui) displayEditDialog

  view editDlgDialog edlg `onDialogCancel` \_ -> do
    edlg ^! editDlgFocusGroup . act focusNext
    displayMainGui
  view editDlgDialog edlg `onDialogAccept` \_ -> do
    edlgSrc <- edlg ^! editVar . act readMVar
    if isNothing edlgSrc
      then updateStatusBar gui "Renaming failed"
      else do
        newName <- getEditText (view editDlgWidget edlg)
        Just src <- edlg ^! editVar . act readMVar
        executeRenameSelected gui src newName
    edlg ^! editDlgFocusGroup . act focusPrevious
    displayMainGui

  fg `onKeyPressed` \_ k _ -> case k of
    (KChar 'q') -> do
      size <- gui ^. toArchiveLst & getListSize
      when (size == 0) exitSuccess
      return True
    (KChar 'Q') -> exitSuccess
    (KChar 'u') -> retrieveNewItems gui >> return True
    (KChar 'U') -> do
      clearList (view unreadLst gui)
      clearList (view toArchiveLst gui)
      modifyData gui (dataTime .~ Nothing)
      retrieveNewItems gui >> return True
    (KChar 'A') -> executeArchiveAction gui >> return True
    _ -> return False

  return (gui,c)

vty :: ShellCommand -> PocketCredentials -> [PocketItem] -> IO ()
vty cmd cred pis = do
  (gui,c) <- createGUI cmd cred
  insertPocketItems (view unreadLst gui) pis

  for_ [view unreadLst gui, view toArchiveLst gui] $ \x -> do
    x `onItemActivated` lstItemActivatedHandler gui x
    x `onKeyPressed` lstKeyPressedHandler gui

  view unreadLst gui `onKeyPressed` \this key _ -> case key of
    (KChar 'd') -> shiftSelected this (view toArchiveLst gui) >> return True
    (KChar 'D') -> do
      insertPocketItems (view toArchiveLst gui) =<< extractAndClear this
      focusNext (view mainFocusGroup gui)
      return True
    _ -> return False

  view toArchiveLst gui `onKeyPressed` \this key _ -> case key of
    (KChar 'd') -> shiftSelected this (view unreadLst gui) >> return True
    (KChar 'D') -> do
      traverse_ (sortedAddLstItem (view unreadLst gui)) =<< extractAndClear this
      focusNext (view mainFocusGroup gui)
      return True

    _ -> return False

  retrieveNewItems gui
  runUi c defaultContext

lstKeyPressedHandler :: HocketGUI
                     -> Widget (List PocketItem FormattedText)
                     -> Key
                     -> t
                     -> IO Bool
lstKeyPressedHandler gui this key _ = case key of
  (KChar 'C') -> abortAsync gui >> return True
  (KChar ' ') -> do
    void . forkIO $ do
      maybeSel <- getSelected this
      traverse_ (browseItem (view launchCommand gui) . view givenUrl . fst . snd) maybeSel
    return True
  _ -> return False

lstItemActivatedHandler :: HocketGUI
                        -> Widget (List PocketItem FormattedText)
                        -> ActivateItemEvent PocketItem t
                        -> IO ()
lstItemActivatedHandler gui src (ActivateItemEvent _ v _) = do
  shiftSelected src (view toArchiveLst gui)
  browseItem (view launchCommand gui) . view givenUrl $ v

shiftSelected :: Widget (List PocketItem FormattedText)
              -> Widget (List PocketItem FormattedText)
              -> IO ()
shiftSelected this target = withSelection this $ \pos val -> do
  void $ removeFromList this pos
  sortedAddLstItem target val

withSelection :: Widget (List a b) -> (Int -> a -> IO c) -> IO ()
withSelection w k = do
  getSelected w >>= traverse_ (\(i, (x, _)) -> k i x)
  return ()

tryHttpException :: IO a -> IO (Either HttpException a)
tryHttpException = try

setUpEditHandler :: EditDialog FormattedText
                 -> Widget (List PocketItem FormattedText)
                 -> IO a
                 -> IO ()
setUpEditHandler e l switch = l `onKeyPressed` \_ k _  -> case k of
  (KChar 'e') -> do
    withSelection l $ \_ sel -> do
      let edit = e ^. editDlgWidget
      setEditText edit (bestTitle sel)
      void $ e ^! editVar . act (\x -> swapMVar x (Just l))
      switch
    return True
  _ -> return False
