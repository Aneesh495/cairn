## Directory-tree acquisition. Enumerate identities before reading content,
## read each regular file through a no-follow descriptor, then revalidate every
## captured path before publishing a snapshot root. This detects ordinary
## source mutation; applications needing atomic database snapshots must quiesce
## their writers or supply a filesystem snapshot as the source directory.
import std/[os, posix, algorithm, sets, times]
import cairn/[capsule, chunker, durable, erasure, errors, fsmeta, limits,
  locking, manifest, paths, repository, references, sha256, snapshot, store, glob]

type
  SourceItem* = object
    relative*: string
    absolute*: string
    identity*: SourceStamp
  BackupStats* = object
    files*: int
    directories*: int
    symlinks*: int
    logicalBytes*: int64
    chunks*: int
    uniqueObjects*: int
    packetsWritten*: int
    packetsReused*: int
    physicalBytesWritten*: int64
  BackupResult* = object
    snapshot*: Snapshot
    stats*: BackupStats

proc enumerateSource*(source: string; rules: seq[IgnoreRule] = @[]): seq[SourceItem] =
  let root = expandFilename(source)
  require(stamp(root).kind == pcDir, ekInvalid, "backup source must be a directory")
  var items: seq[SourceItem]
  proc visit(absolute, relative: string; depth: int) =
    require(depth <= MaxDepth and items.len < MaxEntries, ekLimit, "source tree exceeds manifest limits")
    validatePath(relative, allowRoot = true)
    let identity = stamp(absolute)
    if relative != "." and rules.excluded(relative, identity.kind == pcDir): return
    items.add SourceItem(relative: relative, absolute: absolute, identity: identity)
    if identity.kind == pcDir:
      var children: seq[string]
      for kind, child in walkDir(absolute):
        discard kind
        children.add child
      children.sort
      for child in children:
        let name = extractFilename(child)
        visit(child, if relative == ".": name else: relative & "/" & name, depth+1)
  visit(root, ".", 0)
  items.sort(proc(a, b: SourceItem): int = cmp(a.relative, b.relative))
  items

proc readSourceFile*(item: SourceItem; config: ChunkConfig;
                     consume: ChunkConsumer): tuple[digest: string, size: int64] =
  let fd = posix.open(item.absolute.cstring, O_RDONLY or NoFollow or O_NONBLOCK)
  require(fd >= 0, ekIo, "cannot open source file: " & item.relative)
  defer: discard posix.close(fd)
  var info: Stat
  require(posix.fstat(fd, info) == 0 and stamp(info) == item.identity,
          ekConflict, "source changed before reading: " & item.relative)
  var chunker = initChunker(config)
  var hash = initSha256()
  var buffer = newString(128 * 1024)
  var total = 0'i64
  while true:
    let count = posix.read(fd, addr buffer[0], buffer.len)
    if count < 0:
      if errno == EINTR: continue
      fail(ekIo, "cannot read source file: " & item.relative)
    if count == 0: break
    require(int64(count) <= item.identity.size - total, ekConflict,
            "source grew during backup: " & item.relative)
    let bytes = buffer[0..<count]
    hash.update(bytes)
    chunker.feed(bytes, consume)
    total += int64(count)
  chunker.finish(consume)
  require(posix.fstat(fd, info) == 0 and stamp(info) == item.identity and
          stamp(item.absolute) == item.identity and total == item.identity.size,
          ekConflict, "source changed while reading: " & item.relative)
  (hash.digest, total)

proc backupUnlocked(repo: Repository; source, label: string; exclusions: seq[string]): BackupResult =
  label.validateLabel
  repo.assertNewLabel(label)
  require(dirExists(source) and not symlinkExists(source), ekInvalid,
          "backup source must be a directory, not a symbolic link")
  let root = expandFilename(source)
  require(not isWithin(repo.root, root) and not isWithin(root, repo.root),
          ekUnsafe, "source and repository trees must be disjoint")
  for index in 0..<repo.config.geometry.total:
    require(repo.verifyVolume(index), ekMissing, "restore or repair missing volumes before backup")
  let items = enumerateSource(root, parseRules(exclusions))
  var manifest = Manifest(label: label, createdNs: timeNs(getTime()), source: extractFilename(root))
  var stats: BackupStats
  var seen = initHashSet[string]()
  for item in items:
    var entry = Entry(path: item.relative, mode: item.identity.mode,
      mtimeNs: item.identity.mtimeNs)
    case item.identity.kind
    of pcDir:
      entry.kind = enDirectory
      inc stats.directories
    of pcFile:
      entry.kind = enFile
      inc stats.files
      var refs: seq[ChunkRef]
      let consume = proc(bytes: string) =
        let id = objectId("data", bytes)
        refs.add ChunkRef(id: id, length: bytes.len)
        inc stats.chunks
        require(stats.chunks <= MaxChunkRefs, ekLimit, "source exceeds chunk reference limit")
        if id notin seen:
          let stored = repo.storeObject(okData, bytes)
          seen.incl id
          inc stats.uniqueObjects
          stats.packetsWritten += stored.writtenPackets
          stats.packetsReused += stored.reusedPackets
          stats.physicalBytesWritten += stored.writtenBytes
      let content = readSourceFile(item, repo.config.chunks, consume)
      entry.digest = content.digest
      entry.size = content.size
      entry.chunks = refs
      require(entry.size <= high(int64) - stats.logicalBytes, ekLimit, "source byte count overflow")
      stats.logicalBytes += entry.size
    of pcLinkToFile, pcLinkToDir:
      entry.kind = enSymlink
      entry.target = expandSymlink(item.absolute)
      validateLink(entry.path, entry.target)
      inc stats.symlinks
    manifest.entries.add entry
  for item in items:
    require(stamp(item.absolute) == item.identity, ekConflict,
            "source changed before snapshot publication: " & item.relative)
  crashPoint("source-validated")
  let published = repo.publishSnapshot(manifest)
  BackupResult(snapshot: published, stats: stats)

proc backup*(repo: Repository; source, label: string; exclusions: seq[string] = @[]): BackupResult =
  withRepoLock(repo.root, lmExclusive):
    result = backupUnlocked(repo, source, label, exclusions)
