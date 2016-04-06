{- adjusted branch
 -
 - Copyright 2016 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns #-}

module Annex.AdjustedBranch (
	Adjustment(..),
	OrigBranch,
	AdjBranch,
	originalToAdjusted,
	adjustedToOriginal,
	fromAdjustedBranch,
	getAdjustment,
	enterAdjustedBranch,
	adjustBranch,
	adjustToCrippledFileSystem,
	updateAdjustedBranch,
	propigateAdjustedCommits,
	checkAdjustedClone,
) where

import Annex.Common
import qualified Annex
import Git
import Git.Types
import qualified Git.Branch
import qualified Git.Ref
import qualified Git.Command
import qualified Git.Tree
import qualified Git.DiffTree
import Git.Tree (TreeItem(..))
import Git.Sha
import Git.Env
import Git.Index
import Git.FilePath
import qualified Git.LockFile
import Annex.CatFile
import Annex.Link
import Annex.AutoMerge
import Annex.Content
import Annex.Perms
import Annex.GitOverlay
import Utility.Tmp
import qualified Database.Keys

import qualified Data.Map as M

data Adjustment
	= UnlockAdjustment
	| LockAdjustment
	| HideMissingAdjustment
	| ShowMissingAdjustment
	deriving (Show, Eq)

reverseAdjustment :: Adjustment -> Adjustment
reverseAdjustment UnlockAdjustment = LockAdjustment
reverseAdjustment LockAdjustment = UnlockAdjustment
reverseAdjustment HideMissingAdjustment = ShowMissingAdjustment
reverseAdjustment ShowMissingAdjustment = HideMissingAdjustment

{- How to perform various adjustments to a TreeItem. -}
adjustTreeItem :: Adjustment -> TreeItem -> Annex (Maybe TreeItem)
adjustTreeItem UnlockAdjustment ti@(TreeItem f m s)
	| toBlobType m == Just SymlinkBlob = do
		mk <- catKey s
		case mk of
			Just k -> do
				Database.Keys.addAssociatedFile k f
				Just . TreeItem f (fromBlobType FileBlob)
					<$> hashPointerFile k
			Nothing -> return (Just ti)
	| otherwise = return (Just ti)
adjustTreeItem LockAdjustment ti@(TreeItem f m s)
	| toBlobType m /= Just SymlinkBlob = do
		mk <- catKey s
		case mk of
			Just k -> do
				absf <- inRepo $ \r -> absPath $
					fromTopFilePath f r
				linktarget <- calcRepo $ gitAnnexLink absf k
				Just . TreeItem f (fromBlobType SymlinkBlob)
					<$> hashSymlink linktarget
			Nothing -> return (Just ti)
	| otherwise = return (Just ti)
adjustTreeItem HideMissingAdjustment ti@(TreeItem _ _ s) = do
	mk <- catKey s
	case mk of
		Just k -> ifM (inAnnex k)
			( return (Just ti)
			, return Nothing
			)
		Nothing -> return (Just ti)
adjustTreeItem ShowMissingAdjustment ti = return (Just ti)

type OrigBranch = Branch
type AdjBranch = Branch

adjustedBranchPrefix :: String
adjustedBranchPrefix = "refs/heads/adjusted/"

serialize :: Adjustment -> String
serialize UnlockAdjustment = "unlocked"
serialize LockAdjustment = "locked"
serialize HideMissingAdjustment = "present"
serialize ShowMissingAdjustment = "showmissing"

deserialize :: String -> Maybe Adjustment
deserialize "unlocked" = Just UnlockAdjustment
deserialize "locked" = Just UnlockAdjustment
deserialize "present" = Just HideMissingAdjustment
deserialize _ = Nothing

originalToAdjusted :: OrigBranch -> Adjustment -> AdjBranch
originalToAdjusted orig adj = Ref $
	adjustedBranchPrefix ++ base ++ '(' : serialize adj ++ ")"
  where
	base = fromRef (Git.Ref.basename orig)

adjustedToOriginal :: AdjBranch -> Maybe (Adjustment, OrigBranch)
adjustedToOriginal b
	| adjustedBranchPrefix `isPrefixOf` bs = do
		let (base, as) = separate (== '(') (drop prefixlen bs)
		adj <- deserialize (takeWhile (/= ')') as)
		Just (adj, Git.Ref.under "refs/heads" (Ref base))
	| otherwise = Nothing
  where
	bs = fromRef b
	prefixlen = length adjustedBranchPrefix

getAdjustment :: Branch -> Maybe Adjustment
getAdjustment = fmap fst . adjustedToOriginal

fromAdjustedBranch :: Branch -> OrigBranch
fromAdjustedBranch b = maybe b snd (adjustedToOriginal b)

originalBranch :: Annex (Maybe OrigBranch)
originalBranch = fmap fromAdjustedBranch <$> inRepo Git.Branch.current

{- Enter an adjusted version of current branch (or, if already in an
 - adjusted version of a branch, changes the adjustment of the original
 t a- branch).
 -
 - Can fail, if no branch is checked out, or perhaps if staged changes
 - conflict with the adjusted branch.
 -}
enterAdjustedBranch :: Adjustment -> Annex ()
enterAdjustedBranch adj = go =<< originalBranch
  where
	go (Just origbranch) = do
		adjbranch <- preventCommits $ const $ 
			adjustBranch adj origbranch
		showOutput -- checkout can have output in large repos
		inRepo $ Git.Command.run
			[ Param "checkout"
			, Param $ fromRef $ Git.Ref.base $ adjbranch
			]
	go Nothing = error "not on any branch!"

adjustToCrippledFileSystem :: Annex ()
adjustToCrippledFileSystem = do
	warning "Entering an adjusted branch where files are unlocked as this filesystem does not support locked files."
	whenM (isNothing <$> originalBranch) $
		void $ inRepo $ Git.Branch.commitCommand Git.Branch.AutomaticCommit
			[ Param "--quiet"
			, Param "--allow-empty"
			, Param "-m"
			, Param "commit before entering adjusted unlocked branch"
			]
	enterAdjustedBranch UnlockAdjustment

adjustBranch :: Adjustment -> OrigBranch -> Annex AdjBranch
adjustBranch adj origbranch = do
	sha <- adjust adj origbranch
	inRepo $ Git.Branch.update "entering adjusted branch" adjbranch sha
	return adjbranch
  where
	adjbranch = originalToAdjusted origbranch adj

adjust :: Adjustment -> Ref -> Annex Sha
adjust adj orig = do
	treesha <- adjustTree adj orig
	commitAdjustedTree treesha orig

adjustTree :: Adjustment -> Ref -> Annex Sha
adjustTree adj orig = do
	let toadj = adjustTreeItem adj
	treesha <- Git.Tree.adjustTree toadj [] [] orig =<< Annex.gitRepo
	return treesha

type CommitsPrevented = Git.LockFile.LockHandle

{- Locks git's index file, preventing git from making a commit, merge, 
 - or otherwise changing the HEAD ref while the action is run.
 -
 - Throws an IO exception if the index file is already locked.
 -}
preventCommits :: (CommitsPrevented -> Annex a) -> Annex a
preventCommits = bracket setup cleanup
  where
	setup = do
		lck <- fromRepo indexFileLock
		liftIO $ Git.LockFile.openLock lck
	cleanup = liftIO . Git.LockFile.closeLock

{- Commits a given adjusted tree, with the provided parent ref.
 -
 - This should always yield the same value, even if performed in different 
 - clones of a repo, at different times. The commit message and other
 - metadata is based on the parent.
 -}
commitAdjustedTree :: Sha -> Ref -> Annex Sha
commitAdjustedTree treesha parent = commitAdjustedTree' treesha parent [parent]

commitAdjustedTree' :: Sha -> Ref -> [Ref] -> Annex Sha
commitAdjustedTree' treesha basis parents = go =<< catCommit basis
  where
	go Nothing = inRepo mkcommit
	go (Just basiscommit) = inRepo $ commitWithMetaData
		(commitAuthorMetaData basiscommit)
		(commitCommitterMetaData basiscommit)
		mkcommit
	mkcommit = Git.Branch.commitTree Git.Branch.AutomaticCommit
		adjustedBranchCommitMessage parents treesha

adjustedBranchCommitMessage :: String
adjustedBranchCommitMessage = "git-annex adjusted branch"

{- Update the currently checked out adjusted branch, merging the provided
 - branch into it. Note that the provided branch should be a non-adjusted
 - branch. -}
updateAdjustedBranch :: Branch -> (OrigBranch, Adjustment) -> Git.Branch.CommitMode -> Annex Bool
updateAdjustedBranch tomerge (origbranch, adj) commitmode = catchBoolIO $
	join $ preventCommits $ \commitsprevented ->
		go commitsprevented =<< inRepo Git.Branch.current
  where
	go commitsprevented (Just currbranch) =
		ifM (inRepo $ Git.Branch.changed currbranch tomerge)
			( do
				(updatedorig, _) <- propigateAdjustedCommits' origbranch (adj, currbranch) commitsprevented
				changestomerge updatedorig currbranch
			, nochangestomerge
			)
	go _ _ = return $ return False

	nochangestomerge = return $ return True

	{- Since the adjusted branch changes files, merging tomerge
	 - directly into it would likely result in unncessary merge
	 - conflicts. To avoid those conflicts, instead merge tomerge into
	 - updatedorig. The result of the merge can the be
	 - adjusted to yield the final adjusted branch.
	 -
	 - In order to do a merge into a branch that is not checked out,
	 - set the work tree to a temp directory, and set GIT_DIR
	 - to another temp directory, in which HEAD contains the
	 - updatedorig sha. GIT_COMMON_DIR is set to point to the real
	 - git directory, and so git can read and write objects from there,
	 - but will use GIT_DIR for HEAD and index.
	 -
	 - (Doing the merge this way also lets it run even though the main
	 - index file is currently locked.)
	 -}
	changestomerge (Just updatedorig) currbranch = do
		misctmpdir <- fromRepo gitAnnexTmpMiscDir
		void $ createAnnexDirectory misctmpdir
		tmpwt <- fromRepo gitAnnexMergeDir
		withTmpDirIn misctmpdir "git" $ \tmpgit -> withWorkTreeRelated tmpgit $
			withemptydir tmpwt $ withWorkTree tmpwt $ do
				liftIO $ writeFile (tmpgit </> "HEAD") (fromRef updatedorig)
				showAction $ "Merging into " ++ fromRef (Git.Ref.base origbranch)
				ifM (autoMergeFrom tomerge (Just origbranch) True commitmode)
					( do
						!mergecommit <- liftIO $ extractSha <$> readFile (tmpgit </> "HEAD")
						-- This is run after the commit lock is dropped.
						return $ postmerge currbranch mergecommit
					, return $ return False
					)
	changestomerge Nothing _ = return $ return False
	
	withemptydir d a = bracketIO setup cleanup (const a)
	  where
		setup = do
			whenM (doesDirectoryExist d) $
				removeDirectoryRecursive d
			createDirectoryIfMissing True d
		cleanup _ = removeDirectoryRecursive d

	{- A merge commit has been made between the origbranch and 
	 - tomerge. Update origbranch to point to that commit, adjust
	 - it to get the new adjusted branch, and check it out.
	 -
	 - But, there may be unstaged work tree changes that conflict, 
	 - so the check out is done by making a normal merge of
	 - the new adjusted branch.
	 -}
	postmerge currbranch (Just mergecommit) = do
		inRepo $ Git.Branch.update "updating original branch" origbranch mergecommit
		adjtree <- adjustTree adj mergecommit
		-- Make currbranch be a parent, so that merging
		-- this commit will be a fast-forward.
		adjmergecommit <- commitAdjustedTree' adjtree mergecommit
			[mergecommit, currbranch]
		showAction "Merging into adjusted branch"
		ifM (autoMergeFrom adjmergecommit (Just currbranch) False commitmode)
			-- The adjusted branch has a merge commit on top;
			-- clean that up and propigate any changes made
			-- in that merge to the origbranch.
			( do
				propigateAdjustedCommits origbranch (adj, currbranch)
				return True
			, return False
			)
	postmerge _ Nothing = return False

{- Check for any commits present on the adjusted branch that have not yet
 - been propigated to the orig branch, and propigate them.
 -
 - After propigating the commits back to the orig banch,
 - rebase the adjusted branch on top of the updated orig branch.
 -}
propigateAdjustedCommits :: OrigBranch -> (Adjustment, AdjBranch) -> Annex ()
propigateAdjustedCommits origbranch (adj, currbranch) = 
	preventCommits $ \commitsprevented ->
		join $ snd <$> propigateAdjustedCommits' origbranch (adj, currbranch) commitsprevented
		
{- Returns sha of updated orig branch, and action which will rebase
 - the adjusted branch on top of the updated orig branch. -}
propigateAdjustedCommits'
	:: OrigBranch
	-> (Adjustment, AdjBranch)
	-> CommitsPrevented
	-> Annex (Maybe Sha, Annex ())
propigateAdjustedCommits' origbranch (adj, currbranch) _commitsprevented = do
	ov <- inRepo $ Git.Ref.sha (Git.Ref.under "refs/heads" origbranch)
	case ov of
		Just origsha -> do
			cv <- catCommit currbranch
			case cv of
				Just currcommit -> do
					v <- newcommits >>= go origsha False
					case v of
						Left e -> do
							warning e
							return (Nothing, return ())
						Right newparent -> return
							( Just newparent
							, rebase currcommit newparent
							)
				Nothing -> return (Nothing, return ())
		Nothing -> return (Nothing, return ())
  where
	newcommits = inRepo $ Git.Branch.changedCommits origbranch currbranch
		-- Get commits oldest first, so they can be processed
		-- in order made.
		[Param "--reverse"]
	go parent _ [] = do
		inRepo $ Git.Branch.update "updating adjusted branch" origbranch parent
		return (Right parent)
	go parent pastadjcommit (sha:l) = do
		mc <- catCommit sha
		case mc of
			Just c
				| commitMessage c == adjustedBranchCommitMessage ->
					go parent True l
				| pastadjcommit -> do
					v <- reverseAdjustedCommit parent adj (sha, c) origbranch
					case v of
						Left e -> return (Left e)
						Right commit -> go commit pastadjcommit l
			_ -> go parent pastadjcommit l
	rebase currcommit newparent = do
		-- Reuse the current adjusted tree,
		-- and reparent it on top of the new
		-- version of the origbranch.
		commitAdjustedTree (commitTree currcommit) newparent
			>>= inRepo . Git.Branch.update rebaseOnTopMsg currbranch

rebaseOnTopMsg :: String
rebaseOnTopMsg = "rebasing adjusted branch on top of updated original branch"

{- Reverses an adjusted commit, and commit with provided commitparent,
 - yielding a commit sha.
 -
 - Adjusts the tree of the commitparent, changing only the files that the
 - commit changed, and reverse adjusting those changes.
 -
 - The commit message, and the author and committer metadata are
 - copied over from the basiscommit. However, any gpg signature
 - will be lost, and any other headers are not copied either. -}
reverseAdjustedCommit :: Sha -> Adjustment -> (Sha, Commit) -> OrigBranch -> Annex (Either String Sha)
reverseAdjustedCommit commitparent adj (csha, basiscommit) origbranch
	| length (commitParent basiscommit) > 1 = return $
		Left $ "unable to propigate merge commit " ++ show csha ++ " back to " ++ show origbranch
	| otherwise = do
		treesha <- reverseAdjustedTree commitparent adj csha
		revadjcommit <- inRepo $ commitWithMetaData
			(commitAuthorMetaData basiscommit)
			(commitCommitterMetaData basiscommit) $
				Git.Branch.commitTree Git.Branch.AutomaticCommit
					(commitMessage basiscommit) [commitparent] treesha
		return (Right revadjcommit)

{- Adjusts the tree of the basis, changing only the files that the
 - commit changed, and reverse adjusting those changes.
 -
 - commitDiff does not support merge commits, so the csha must not be a
 - merge commit. -}
reverseAdjustedTree :: Sha -> Adjustment -> Sha -> Annex Sha
reverseAdjustedTree basis adj csha = do
	(diff, cleanup) <- inRepo (Git.DiffTree.commitDiff csha)
	let (adds, others) = partition (\dti -> Git.DiffTree.srcsha dti == nullSha) diff
	let (removes, changes) = partition (\dti -> Git.DiffTree.dstsha dti == nullSha) others
	adds' <- catMaybes <$>
		mapM (adjustTreeItem reverseadj) (map diffTreeToTreeItem adds)
	treesha <- Git.Tree.adjustTree
		(propchanges changes)
		adds'
		(map Git.DiffTree.file removes)
		basis
		=<< Annex.gitRepo
	void $ liftIO cleanup
	return treesha
  where
	reverseadj = reverseAdjustment adj
	propchanges changes ti@(TreeItem f _ _) =
		case M.lookup f m of
			Nothing -> return (Just ti) -- not changed
			Just change -> adjustTreeItem reverseadj change
	  where
		m = M.fromList $ map (\i@(TreeItem f' _ _) -> (f', i)) $
			map diffTreeToTreeItem changes

diffTreeToTreeItem :: Git.DiffTree.DiffTreeItem -> TreeItem
diffTreeToTreeItem dti = TreeItem
	(Git.DiffTree.file dti)
	(Git.DiffTree.dstmode dti)
	(Git.DiffTree.dstsha dti)

{- Cloning a repository that has an adjusted branch checked out will
 - result in the clone having the same adjusted branch checked out -- but
 - the origbranch won't exist in the clone. Create the origbranch. -}
checkAdjustedClone :: Annex ()
checkAdjustedClone = go =<< inRepo Git.Branch.current
  where
	go Nothing = return ()
	go (Just currbranch) = case adjustedToOriginal currbranch of
		Nothing -> return ()
		Just (_adj, origbranch) -> 
			unlessM (inRepo $ Git.Ref.exists origbranch) $ do
				let remotebranch = Git.Ref.underBase "refs/remotes/origin" origbranch
				inRepo $ Git.Branch.update' origbranch remotebranch
