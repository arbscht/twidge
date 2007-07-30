{- hpodder component
Copyright (C) 2006-2007 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

module Commands.Download(cmd, cmd_worker) where
import Utils
import System.Log.Logger
import DB
import Download
import DownloadQueue
import FeedParser
import Types
import Text.Printf
import Config
import Database.HDBC
import Control.Monad hiding(forM_)
import Utils
import Data.Hash.MD5
import System.FilePath
import System.IO
import System.Directory
import System.Cmd.Utils
import System.Posix.Process
import Data.ConfigFile
import Data.String
import Data.Either.Utils
import Data.List
import System.Exit
import Control.Exception
import Data.Progress.Tracker
import Data.Progress.Meter
import Control.Concurrent.MVar
import Control.Concurrent
import Data.Foldable(forM_)
import Network.URI(unEscapeString)
import System.Posix.IO(
                       OpenMode(..),
                       closeFd,
                       defaultFileFlags,
                       dupTo,
                       openFd,
                       stdOutput
                      )

d = debugM "download"
i = infoM "download"
w = warningM "download"

cmd = simpleCmd "download" 
      "Downloads all pending podcast episodes (run update first)" helptext 
      [] cmd_worker

cmd_worker gi ([], casts) = lock $
    do podcastlist_raw <- getSelectedPodcasts (gdbh gi) casts
       let podcastlist = filter_disabled podcastlist_raw
       episodelist <- mapM (getEpisodes (gdbh gi)) podcastlist
       let episodes = filter (\x -> epstatus x == Pending) . concat $ episodelist

       -- Now force the DB to be read so that we don't maintain a lock
       evaluate (length episodes)
       i $ printf "%d episode(s) to consider from %d podcast(s)"
         (length episodes) (length podcastlist)
       downloadEpisodes gi episodes
       cleanupDirectory gi episodes

cmd_worker _ _ =
    fail $ "Invalid arguments to download; please see hpodder download --help"

cleanupDirectory gi episodes =
    do base <- getEnclTmp
       files <- getDirectoryContents base
       mapM_ (removeold base) files
    where epmd5s = map (getdlfname . epurl) episodes
          epmsgs = map (\e -> e ++ ".msg") epmd5s
          eps = epmd5s ++ epmsgs
          removeold base file =
            when (not (file `elem` eps)) $
                removeFile (base ++ "/" ++ file)

downloadEpisodes gi episodes =
    do progressinterval <- getProgressInterval

       watchFiles <- newMVar []
       wfthread <- forkIO (watchTheFiles progressinterval watchFiles)

       easyDownloads "download" getEnclTmp True
                     (\pt -> mapM (ep2dlentry pt) episodes)
                     (procStart watchFiles)
                     (callback watchFiles)

    where nameofep e = printf "%d.%d" (castid . podcast $ e) (epid e)
          ep2dlentry pt episode =
              do cpt <- newProgress (nameofep episode)
                        (eplength episode)
                 addParent cpt pt
                 return $ DownloadEntry {dlurl = epurl episode,
                                         usertok = episode,
                                         dlname = nameofep episode,
                                         dlprogress = cpt}
          procStart watchFilesMV pt meter dlentry dltok =
              do writeMeterString stdout meter $
                  "Get: " ++ nameofep (usertok dlentry) ++ " "
                   ++ (take 60 . eptitle . usertok $ dlentry) ++ "\n"
                 modifyMVar_ watchFilesMV $ \wf ->
                     return $ (dltok, dlprogress dlentry) : wf

          callback watchFilesMV pt meter dlentry dltok status result =
              modifyMVar_ watchFilesMV $ \wf ->
                  do size <- checkDownloadSize dltok
                     setP (dlprogress dlentry) (case size of
                                                  Nothing -> 0
                                                  Just x -> toInteger x)
                     procEpisode gi meter dltok 
                                     (usertok dlentry) (dlname dlentry)
                                     (result, status)
                     return $ filter (\(x, _) -> x /= dltok) wf

-- FIXME: this never terminates, but at present, that may not hurt anything

watchTheFiles progressinterval watchFilesMV = 
    do withMVar watchFilesMV $ \wf -> mapM_ examineFile wf
       threadDelay (progressinterval * 1000000)
       watchTheFiles progressinterval watchFilesMV

    where examineFile (dltok, cpt) =
              do size <- checkDownloadSize dltok
                 setP cpt (case size of
                             Nothing -> 0
                             Just x -> toInteger x)

procEpisode gi meter dltok ep name r =
       case r of
         (Success, _) -> procSuccess gi ep (tokpath dltok)
         (Failure, Terminated sigINT) -> 
             do i "Ctrl-C hit; aborting!"
                -- Do not consider Ctrl-C a trackable error
                exitFailure
         _ -> do curtime <- now
                 let newep = considerDisable gi $
                       updateAttempt curtime $
                       (ep {eplastattempt = Just curtime,
                            epfailedattempts = epfailedattempts ep + 1})
                 updateEpisode (gdbh gi) newep
                 commit (gdbh gi)
                 writeMeterString stderr meter $ " *** " ++ name ++ 
                                      ": Error downloading\n"
                 when (epstatus newep == Error) $
                    writeMeterString stderr meter $ " *** " ++ name ++ 
                             ": Disabled due to errors.\n"
considerDisable gi ep = forceEither $
    do faildays <- get (gcp gi) cast "epfaildays"
       failattempts <- get (gcp gi) cast "epfailattempts"
       let lupdate = case epfirstattempt ep of
                        Nothing -> 0
                        Just x -> x
       let timepermitsdel = case eplastattempt ep of
                                Nothing -> True
                                Just x -> x - lupdate > faildays * 60 * 60 * 24
       case epstatus ep of
         Pending -> return $ ep {epstatus =
            if (epfailedattempts ep > failattempts) && timepermitsdel
                then Error
                else Pending}
         _ -> return ep 
                        
    where cast = show . castid . podcast $ ep
                  
updateAttempt curtime ep =
    ep {epfirstattempt =
        case epfirstattempt ep of
            Nothing -> Just curtime
            Just x -> Just x
       }


procSuccess gi ep tmpfp =
    do cp <- getCP ep idstr fnpart
       let cfg = get cp idstr
       let newfn = (strip $ forceEither $ cfg "downloaddir") ++ "/" ++
                   (strip $ forceEither $ cfg "namingpatt")
       createDirectoryIfMissing True (fst . splitFileName $ newfn)
       finalfn <- if ((eptype ep) `elem` ["audio/mpeg", "audio/mp3", 
                                          "x-audio/mp3"]) && 
                     not (isSuffixOf ".mp3" newfn)
                  then movefile tmpfp (newfn ++ ".mp3")
                  else movefile tmpfp newfn
       when (isSuffixOf ".mp3" finalfn) $ 
            do d "   Setting ID3 tags..."
               --posixRawSystem "id3v2" ["-C", finalfn] >>= id3result
               --posixRawSystem "id3v2" ["-s", finalfn] >>= id3result
               posixRawSystem "id3v2" ["-A", castname . podcast $ ep,
                                       "-t", eptitle ep,
                                       "--WOAF", epurl ep,
                                       "--WOAS", feedurl . podcast $ ep,
                                        -- "--WXXX", feedurl . podcast $ ep,
                                       finalfn] >>= id3result
       cp <- getCP ep idstr fnpart
       let cfg = get cp (show . castid . podcast $ ep)
       forM_ (either (const Nothing) Just $ cfg "posthook")
             (runHook finalfn)
       curtime <- now
       updateEpisode (gdbh gi) $ 
           updateAttempt curtime $ (ep {epstatus = Downloaded})
       commit (gdbh gi)
       
    where idstr = show . castid . podcast $ ep
          fnpart = snd . splitFileName $ epurl ep
          id3result res = 
               case res of
                 Exited (ExitSuccess) -> d $ "   id3v2 was successful."
                 Exited (ExitFailure y) -> w $ "\n   id3v2 returned: " ++ show y
                 Terminated y -> w $ "\n   id3v2 terminated by signal " ++ show y
                 _ -> fail "Stopped unexpected"

-- | Runs a hook script.
runHook :: String -- ^ The name of the file to pass as an argument to the script.
        -> String -- ^ The name of the script to invoke.
        -> IO ()
runHook fn script =
    do child <- forkProcess runScript
       status <- getProcessStatus True False child
       case status of
         Nothing -> fail "No status unexpected."
         Just (Stopped _) -> fail "Stopped process unexpected."
         Just (Terminated sig) -> fail (printf "Post-hook \"%s\" terminated by signal %s" script (show sig))
         Just (Exited (ExitFailure code)) -> fail (printf "Post-hook \"%s\" failed with exit code %s" script (show code))
         Just (Exited ExitSuccess) -> return ()
    where runScript =
              -- Open /dev/null, duplicate it to stdout, and close it.
              do bracket (openFd "/dev/null" ReadOnly
                                 Nothing defaultFileFlags)
                         closeFd
                         (\devNull ->
                              do dupTo devNull stdOutput)
                 executeFile script False [fn] Nothing

getCP :: Episode -> String -> String -> IO ConfigParser
getCP ep idstr fnpart =
    do cp <- loadCP
       return $ forceEither $
              do cp <- if has_section cp idstr
                          then return cp
                          else add_section cp idstr
                 cp <- set cp idstr "safecasttitle" 
                       (sanitize_fn . castname . podcast $ ep)
                 cp <- set cp idstr "epid" (show . epid $ ep)
                 cp <- set cp idstr "castid" idstr
                 cp <- set cp idstr "safefilename" 
                       (sanitize_fn (unEscapeString fnpart))
                 cp <- set cp idstr "safeeptitle" (sanitize_fn . eptitle $ ep)
                 return cp

movefile old new =
    do realnew <- findNonExisting new
       copyFile old (realnew ++ ".partial")
       renameFile (realnew ++ ".partial") realnew
       removeFile old
       return realnew

findNonExisting template =
    do dfe <- doesFileExist template
       if (not dfe)
          then return template
          else do let (dirname, fn) = splitFileName template
                  (fp, h) <- openTempFile dirname fn
                  hClose h
                  return fp

helptext = "Usage: hpodder download [castid [castid...]]\n\n" ++ 
           genericIdHelp ++
 "\nThe download command will cause hpodder to download any podcasts\n\
 \episodes that are marked Pending.  Such episodes are usually generated\n\
 \by a prior call to \"hpodder update\".  If you want to combine an update\n\
 \with a download, as is normally the case, you may want \"hpodder fetch\".\n"
