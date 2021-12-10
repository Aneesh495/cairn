## Restore is transactional at the destination-tree boundary. Build privately
## beside the requested destination, verify every file digest, flush the tree,
## then rename it into place. Existing destinations are never merged or erased.
import std/[os, posix, tempfiles]
import cairn/[capsule, durable, errors, fsmeta, locking, manifest, paths,
  repository, sha256, snapshot, store, streamio]

type RestoreStats* = object
  files*: int
  directories*: int
  symlinks*: int
  bytes*: int64

proc applyDirectory(path: string; entry: Entry) =
  let fd = posix.open(path.cstring, O_RDONLY or NoFollow)
  require(fd >= 0, ekIo, "cannot open restored directory")
  defer: discard posix.close(fd)
  applyMetadata(fd, entry.mode, entry.mtimeNs)
  syncFd(fd, path)

proc cleanupTree*(root: string) =
  ## Only called for a private, owned staging directory. Make directories
  ## traversable again if a late failure happened after mode restoration.
  if not dirExists(root): return
  setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  for kind, path in walkDir(root):
    if kind == pcDir: cleanupTree(path)
  removeDir(root)

proc restoreUnlocked(repo: Repository; label, destination: string): RestoreStats =
  let snapshot = repo.loadSnapshot(label)
  let absolute = absolutePath(destination).normalizedPath
  require(not existsAny(absolute), ekConflict, "restore destination already exists: " & absolute)
  require(dirExists(parentDir(absolute)), ekMissing, "restore parent must already exist")
  let parent = expandFilename(parentDir(absolute))
  let target = parent / extractFilename(absolute)
  require(not isWithin(target, repo.root), ekUnsafe, "cannot restore inside the repository")
  let stage = createTempDir(".cairn-restore-", "", parent)
  var published = false
  defer:
    if not published: cleanupTree(stage)
  for entry in snapshot.manifest.entries:
    if entry.path == ".":
      inc result.directories
      continue
    let path = managedPath(stage, entry.path)
    case entry.kind
    of enDirectory:
      ensureDirectory(path)
      inc result.directories
    of enFile:
      let file = beginFile(path)
      try:
        var hash = initSha256()
        var bytes = 0'i64
        for chunk in entry.chunks:
          let data = repo.loadObject(chunk.id, okData)
          require(data.len == chunk.length, ekCorrupt, "restored chunk length mismatch")
          hash.update(data)
          file.append(data)
          bytes += int64(data.len)
        require(bytes == entry.size and hash.digest == entry.digest,
                ekCorrupt, "restored file digest mismatch: " & entry.path)
        file.finish(entry.mode, entry.mtimeNs)
        result.bytes += bytes
        inc result.files
      finally: file.abort
    of enSymlink: discard # Install links only after all regular writes finish.
  for entry in snapshot.manifest.entries:
    if entry.kind == enSymlink:
      validateLink(entry.path, entry.target)
      createSymlink(entry.target, managedPath(stage, entry.path))
      inc result.symlinks
  for i in countdown(snapshot.manifest.entries.high, 0):
    let entry = snapshot.manifest.entries[i]
    if entry.kind == enDirectory:
      let path = if entry.path == ".": stage else: stage / entry.path
      applyDirectory(path, entry)
  crashPoint("restore-tree-synced")
  require(not existsAny(target), ekConflict, "restore destination appeared during restore")
  require(renameNative(stage.cstring, target.cstring) == 0, ekIo, "cannot publish restored tree")
  published = true
  crashPoint("restore-published")
  syncDirectory(parent)

proc restore*(repo: Repository; label, destination: string): RestoreStats =
  ## Hold a reader lock through verified tree publication. The destination
  ## must be new; this function never merges with or erases an existing tree.
  withRepoLock(repo.root, lmShared):
    result = restoreUnlocked(repo, label, destination)
