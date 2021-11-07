## Salvage never presents an incomplete byte stream as a restored file. Whole
## verified files live under complete/. Surviving chunks of damaged files live
## under fragments/ with an explicit offset map. Missing ranges are named in
## salvage.json rather than silently filled with zeros or guessed data.
import std/[os, json, tempfiles, strutils]
import cairn/[capsule, durable, errors, locking, manifest, paths, repository,
  restore, sha256, snapshot, store, streamio]

type SalvageResult* = object
  completeFiles*: int
  partialFiles*: int
  lostFiles*: int
  recoveredBytes*: int64
  missingBytes*: int64
  map*: JsonNode

proc createParents(root, relative: string) =
  validatePath(relative)
  let components = relative.split('/')
  var prefix = ""
  for i in 0..<components.high:
    prefix = if prefix.len == 0: components[i] else: prefix & "/" & components[i]
    ensureDirectory(managedPath(root, prefix))

proc salvage*(repo: Repository; label, destination: string): SalvageResult =
  withRepoLock(repo.root, lmShared):
    let snapshot = repo.loadSnapshot(label)
    let absolute = absolutePath(destination).normalizedPath
    require(not existsAny(absolute), ekConflict, "salvage destination already exists")
    require(dirExists(parentDir(absolute)), ekMissing, "salvage parent must exist")
    let parent = expandFilename(parentDir(absolute))
    let target = parent / extractFilename(absolute)
    require(not isWithin(target, repo.root), ekUnsafe, "cannot salvage inside the repository")
    let stage = createTempDir(".cairn-salvage-", "", parent)
    var published = false
    defer:
      if not published: cleanupTree(stage)
    ensureDirectory(stage / "complete")
    ensureDirectory(stage / "fragments")
    result.map = %*{"version": 1, "label": label, "manifest_id": snapshot.reference.manifestId,
      "warning": "Incomplete files are fragments with offsets, never reconstructed placeholders",
      "files": [], "links": []}
    for entry in snapshot.manifest.entries:
      if entry.kind == enSymlink:
        result.map["links"].add %*{"path": entry.path, "target": entry.target}
      if entry.kind != enFile: continue
      var node = %*{"path": entry.path, "size": entry.size, "sha256": entry.digest,
        "state": "", "complete_path": "", "ranges": []}
      var offset = 0'i64
      var recovered = 0'i64
      var hash = initSha256()
      var complete = true
      let fileKey = sha256(entry.path)
      let fragmentRoot = "fragments/" & fileKey
      ensureDirectory(managedPath(stage, fragmentRoot))
      for chunk in entry.chunks:
        var range = %*{"offset": offset, "length": chunk.length, "id": chunk.id,
          "fragment": "", "error": ""}
        var bytes: string
        var readable = false
        try:
          bytes = repo.loadObject(chunk.id, okData)
          require(bytes.len == chunk.length, ekCorrupt, "chunk length mismatch")
          readable = true
        except CairnError as error:
          complete = false
          range["error"] = %error.msg
        if readable:
          # Destination failures must escape the recovery classification path.
          # Otherwise ENOSPC/EFBIG would masquerade as missing source content.
          let fragment = fragmentRoot & "/" & $offset & ".part"
          writeAtomic(managedPath(stage, fragment), bytes)
          range["fragment"] = %fragment
          hash.update(bytes)
          recovered += int64(bytes.len)
        node["ranges"].add range
        offset += int64(chunk.length)
      if complete:
        require(hash.digest == entry.digest, ekCorrupt, "salvage file digest mismatch")
        let relative = "complete/" & entry.path
        createParents(stage, relative)
        let file = beginFile(managedPath(stage, relative))
        try:
          for range in node["ranges"]:
            let path = managedPath(stage, range["fragment"].getStr)
            file.append(readBounded(path, 64*1024*1024))
          file.finish(entry.mode, entry.mtimeNs)
        finally: file.abort
        # Fully verified files do not need duplicate fragment storage.
        for range in node["ranges"]:
          removeDurable(managedPath(stage, range["fragment"].getStr))
          range["fragment"] = %""
        removeDir(managedPath(stage, fragmentRoot))
        node["state"] = %"complete"
        node["complete_path"] = %relative
        inc result.completeFiles
      elif recovered > 0:
        node["state"] = %"partial"
        inc result.partialFiles
      else:
        node["state"] = %"lost"
        inc result.lostFiles
      result.recoveredBytes += recovered
      result.missingBytes += entry.size - recovered
      result.map["files"].add node
    result.map["complete_files"] = %result.completeFiles
    result.map["partial_files"] = %result.partialFiles
    result.map["lost_files"] = %result.lostFiles
    result.map["recovered_bytes"] = %result.recoveredBytes
    result.map["missing_bytes"] = %result.missingBytes
    writeAtomic(stage / "salvage.json", $result.map)
    syncDirectory(stage / "complete")
    syncDirectory(stage / "fragments")
    syncDirectory(stage)
    require(not existsAny(target), ekConflict, "salvage destination appeared")
    require(renameNative(stage.cstring, target.cstring) == 0, ekIo, "cannot publish salvage directory")
    published = true
    syncDirectory(parent)
