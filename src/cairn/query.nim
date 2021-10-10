## Read-only snapshot queries and single-file extraction. All public functions
## hold a reader lock while resolving manifests and content dependencies.
import std/[os, json]
import cairn/[capsule, errors, glob, locking, manifest, paths, repository,
  retention, sha256, snapshot, store, streamio]

proc lookup*(manifest: Manifest; path: string): tuple[found: bool, entry: Entry] =
  validatePath(path, allowRoot = true)
  var low = 0
  var high = manifest.entries.len
  while low < high:
    let middle = low + (high-low) div 2
    if manifest.entries[middle].path < path: low = middle+1
    else: high = middle
  if low < manifest.entries.len and manifest.entries[low].path == path:
    (true, manifest.entries[low])
  else: (false, default(Entry))

proc findPaths*(repo: Repository; label, pattern: string): JsonNode =
  withRepoLock(repo.root, lmShared):
    let snapshot = repo.loadSnapshot(label)
    result = newJArray()
    for entry in snapshot.manifest.entries:
      if globMatch(pattern, entry.path):
        result.add %*{"path": entry.path, "kind": entry.kind.kindName,
          "size": entry.size, "sha256": entry.digest, "target": entry.target}

proc fileHistory*(repo: Repository; path: string): JsonNode =
  validatePath(path, allowRoot = true)
  withRepoLock(repo.root, lmShared):
    result = newJArray()
    for info in repo.listSnapshots:
      let snapshot = repo.loadSnapshot(info.label)
      let found = snapshot.manifest.lookup(path)
      var node = %*{"label": info.label, "created_ns": info.createdNs, "present": found.found}
      if found.found:
        node["kind"] = %found.entry.kind.kindName
        node["size"] = %found.entry.size
        node["sha256"] = %found.entry.digest
        node["target"] = %found.entry.target
      result.add node

proc extractFile*(repo: Repository; label, path, destination: string): int64 =
  withRepoLock(repo.root, lmShared):
    let snapshot = repo.loadSnapshot(label)
    let found = snapshot.manifest.lookup(path)
    require(found.found and found.entry.kind == enFile, ekMissing, "snapshot path is not a regular file")
    let absolute = absolutePath(destination).normalizedPath
    require(dirExists(parentDir(absolute)), ekMissing, "extraction parent must exist")
    let target = expandFilename(parentDir(absolute)) / extractFilename(absolute)
    require(not isWithin(target, repo.root), ekUnsafe, "cannot extract inside the repository")
    let file = beginFile(target)
    try:
      var hash = initSha256()
      for chunk in found.entry.chunks:
        let bytes = repo.loadObject(chunk.id, okData)
        require(bytes.len == chunk.length, ekCorrupt, "extracted chunk length mismatch")
        hash.update(bytes)
        file.append(bytes)
        result += int64(bytes.len)
      require(result == found.entry.size and hash.digest == found.entry.digest,
              ekCorrupt, "extracted file digest mismatch")
      file.finish(found.entry.mode, found.entry.mtimeNs)
    finally: file.abort
