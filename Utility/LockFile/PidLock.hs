{- pid-based lock files
 -
 - Copyright 2015 Joey Hess <id@joeyh.name>
 -
 - License: BSD-2-clause
 -}

module Utility.LockFile.PidLock (
	LockHandle,
	tryLock,
	waitLock,
	dropLock,
	LockStatus(..),
	getLockStatus,
	checkLocked,
	checkSaneLock,
) where

import Utility.PartialPrelude
import Utility.Exception
import Utility.Applicative
import Utility.Directory
import Utility.Monad
import Utility.Path
import Utility.FileMode
import Utility.LockFile.LockStatus
import Utility.ThreadScheduler
import qualified Utility.LockFile.Posix as Posix

import System.IO
import System.Posix
import Data.Maybe
import Data.List
import Control.Applicative
import Network.BSD
import System.FilePath
import Data.Hash.MD5
import System.Directory

type LockFile = FilePath

data LockHandle = LockHandle FilePath Fd SideLockHandle

type SideLockHandle = Maybe Posix.LockHandle

data PidLock = PidLock
	{ lockingPid :: ProcessID
	, lockingHost :: HostName
	}
	deriving (Eq, Read, Show)

mkPidLock :: IO PidLock
mkPidLock = PidLock
	<$> getProcessID
	<*> getHostName

readPidLock :: LockFile -> IO (Maybe PidLock)
readPidLock lockfile = (readish =<<) <$> catchMaybeIO (readFile lockfile)

-- To avoid races when taking over a stale pid lock, a side lock is used.
-- This is a regular posix exclusive lock. The side lock is put in
-- /dev/shm. This will work on most any Linux system, even if its whole
-- root filesystem doesn't support posix locks.
trySideLock :: LockFile -> (SideLockHandle -> IO a) -> IO a
trySideLock lockfile a = do
	sidelock <- sideLockFile lockfile
	mlck <- catchDefaultIO Nothing $ 
		withUmask nullFileMode $
			Posix.tryLockExclusive (Just mode) sidelock
	a mlck
  where
	-- Let all users write to the lock file in /dev/shm or /tmp,
	-- so that other users can reuse it to take the lock.
	-- Since /dev/shm and /tmp are sticky dirs, a user cannot
	-- delete another user's lock file there, so could not
	-- delete a stale lock.
	mode = combineModes (readModes ++ writeModes)

sideLockFile :: LockFile -> IO LockFile
sideLockFile lockfile = do
	f <- absPath lockfile
	let base = intercalate "_" (splitDirectories (makeRelative "/" f))
	let shortbase = reverse $ take 32 $ reverse base
	let md5sum = if base == shortbase then "" else md5s (Str base)
	dir <- ifM (doesDirectoryExist "/dev/shm")
		( return "/dev/shm"
		, return "/tmp"
		)
	return $ dir </> md5sum ++ shortbase ++ ".lck"

-- | Tries to take a lock; does not block when the lock is already held.
--
-- Note that stale locks are automatically detected and broken.
-- However, if the lock file is on a networked file system, and was
-- created on a different host than the current host (determined by hostname),
-- this can't be done and stale locks may persist.
tryLock :: LockFile -> IO (Maybe LockHandle)
tryLock lockfile = trySideLock lockfile $ \sidelock -> do
	(tmp, h) <- openTempFile (takeDirectory lockfile) "locktmp"
	setFileMode tmp (combineModes readModes)
	hPutStr h . show =<< mkPidLock
	hClose h
	let failedlock = do
		nukeFile tmp
		maybe noop Posix.dropLock sidelock
		return Nothing
	let tooklock fd = return $ Just $ LockHandle lockfile fd sidelock
	mfd <- linkToLock sidelock tmp lockfile
	case mfd of
		Just fd -> do
			nukeFile tmp
			tooklock fd
		Nothing -> do
			v <- readPidLock lockfile
			hn <- getHostName
			case v of
				Just pl | isJust sidelock && hn == lockingHost pl -> do
					-- Since we have the sidelock,
					-- and are on the same host that
					-- the pidlock was taken on,
					-- we know that the pidlock is
					-- stale, and can take it over.
					rename tmp lockfile
					fd <- openFd lockfile ReadOnly Nothing defaultFileFlags
					tooklock fd
				_ -> failedlock

-- Linux's open(2) man page recommends linking a pid lock into place,
-- as the most portable atomic operation that will fail if
-- it already exists. 
--
-- open(2) suggests that link can sometimes appear to fail
-- on NFS but have actually succeeded, and the way to find out is to stat
-- the file and check its link count etc.
--
-- On a Lustre filesystem, link has been observed to incorrectly *succeed*,
-- despite the dest already existing. A subsequent stat of the dest
-- looked like it had been replaced with the src. The process proceeded to
-- run and then deleted the dest, and after the process was done, the
-- original file was observed to still be in place. This is horrible and we
-- can't do anything about such a lying filesystem.
-- At least the side lock file will prevent git-annex's running on the same
-- host from running concurrently even on such a lying filesystem.
linkToLock :: SideLockHandle -> FilePath -> FilePath -> IO (Maybe Fd)
linkToLock Nothing _ _ = return Nothing
linkToLock (Just _) src dest = do
	_ <- tryIO $ createLink src dest
	ifM (catchDefaultIO False checklink)
		( catchDefaultIO Nothing $ do
			srccontent <- readFile src
			h <- openFile dest ReadMode
			destcontent <- hGetContents h
			if srccontent /= destcontent
				then do
					hClose h
					return Nothing
				else Just <$> handleToFd h
		, return Nothing
		)
  where
	checklink = do
		x <- getSymbolicLinkStatus src
		y <- getSymbolicLinkStatus dest
		return $ and
			[ deviceID x == deviceID y
			, fileID x == fileID y
			, fileMode x == fileMode y
			, fileOwner x == fileOwner y
			, fileGroup x == fileGroup y
			, specialDeviceID x == specialDeviceID y
			, fileSize x == fileSize y
			, modificationTime x == modificationTime y
			, isRegularFile x == isRegularFile y
			, linkCount x == linkCount y
			, linkCount x == 2
			]

-- | Waits as necessary to take a lock.
--
-- Uses a 1 second wait-loop.
--
-- May wait untie timeout if the lock file is stale and is on a network file
-- system, or on a system where the side lock cannot be taken.
waitLock :: Seconds -> LockFile -> IO LockHandle
waitLock (Seconds timeout) lockfile = go timeout
  where
	go n
		| n > 0 = maybe (threadDelaySeconds (Seconds 1) >> go (pred n)) return
			=<< tryLock lockfile
		| otherwise = do
			hPutStrLn stderr $ show timeout ++ " second timeout exceeded while waiting for pid lock file " ++ lockfile
			error $ "Gave up waiting for possibly stale pid lock file " ++ lockfile

dropLock :: LockHandle -> IO ()
dropLock (LockHandle lockfile fd sidelock) = do
	-- Drop side lock first, at which point the pid lock will be
	-- considered stale.
	-- The side lock file cannot be deleted because another process may
	-- have it open and be waiting to lock it.
	maybe noop Posix.dropLock sidelock
	closeFd fd
	nukeFile lockfile

getLockStatus :: LockFile -> IO LockStatus
getLockStatus = maybe StatusUnLocked (StatusLockedBy . lockingPid) <$$> readPidLock

checkLocked :: LockFile -> IO (Maybe Bool)
checkLocked lockfile = conv <$> getLockStatus lockfile
  where
	conv (StatusLockedBy _) = Just True
	conv _ = Just False

-- Checks that the lock file still exists, and is the same file that was
-- locked to get the LockHandle.
checkSaneLock :: LockFile -> LockHandle -> IO Bool
checkSaneLock lockfile (LockHandle _ fd _) =
	go =<< catchMaybeIO (getFileStatus lockfile)
  where
	go Nothing = return False
	go (Just st) = do
		fdst <- getFdStatus fd
		return $ deviceID fdst == deviceID st && fileID fdst == fileID st
