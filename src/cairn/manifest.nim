## A snapshot manifest is immutable and content addressed as a single capsule.
## It contains a complete tree, so restoring a snapshot never needs another
## snapshot's manifest or a chain of incremental updates.
import std/[json, tables, os]
import cairn/[errors, limits, paths, schema, sha256]

type
  EntryKind* = enum
    enDirectory, enFile, enSymlink
  ChunkRef* = object
    id*: string
    length*: int
  Entry* = object
    path*: string
    kind*: EntryKind
    mode*: int
    mtimeNs*: int64
    size*: int64
    digest*: string
    target*: string
    chunks*: seq[ChunkRef]
  Manifest* = object
    label*: string
    createdNs*: int64
    source*: string
    entries*: seq[Entry]

const MaxChunkRefs* = 1_000_000

proc kindName*(kind: EntryKind): string =
  case kind
  of enDirectory: "directory"
  of enFile: "file"
  of enSymlink: "symlink"

proc validate*(manifest: Manifest) =
  manifest.label.validateLabel
  require(manifest.createdNs >= 0 and validText(manifest.source, MaxPathBytes),
          ekCorrupt, "invalid snapshot identity metadata")
  require(manifest.entries.len in 1..MaxEntries, ekLimit, "invalid manifest entry count")
  require(manifest.entries[0].path == "." and manifest.entries[0].kind == enDirectory,
          ekCorrupt, "manifest must start with its root directory")
  var parents = initTable[string, EntryKind]()
  var previous = ""
  var refs = 0
  for entry in manifest.entries:
    validatePath(entry.path, allowRoot = true)
    require(entry.path > previous, ekCorrupt, "manifest paths must be unique and sorted")
    previous = entry.path
    if entry.path != ".":
      let parent = if parentDir(entry.path).len == 0: "." else: parentDir(entry.path)
      require(parents.hasKey(parent) and parents[parent] == enDirectory,
              ekCorrupt, "manifest entry lacks a directory parent: " & entry.path)
    parents[entry.path] = entry.kind
    require(entry.mode >= 0 and entry.mode <= 0o777 and entry.size >= 0,
            ekCorrupt, "invalid file mode or size")
    require(entry.chunks.len <= MaxChunkRefs - refs, ekLimit, "too many chunk references")
    refs += entry.chunks.len
    case entry.kind
    of enFile:
      require(validId(entry.digest) and entry.target.len == 0,
              ekCorrupt, "invalid file digest or symlink target")
      var size = 0'i64
      for chunk in entry.chunks:
        require(validId(chunk.id) and chunk.length in 1..MaxObjectBytes,
                ekCorrupt, "invalid chunk reference")
        require(int64(chunk.length) <= high(int64) - size, ekLimit, "file size overflow")
        size += int64(chunk.length)
      require(size == entry.size, ekCorrupt, "file size differs from chunk references")
      if entry.size == 0:
        require(entry.digest == sha256(""), ekCorrupt, "invalid empty-file digest")
    of enDirectory, enSymlink:
      require(entry.chunks.len == 0 and entry.size == 0 and entry.digest.len == 0,
              ekCorrupt, "non-file entry contains file content")
      if entry.kind == enSymlink: validateLink(entry.path, entry.target)
      else: require(entry.target.len == 0, ekCorrupt, "directory contains symlink target")

proc toJson*(manifest: Manifest): JsonNode =
  result = %*{"version": FormatVersion, "label": manifest.label,
    "created_ns": manifest.createdNs, "source": manifest.source, "entries": []}
  for entry in manifest.entries:
    var node = %*{"path": entry.path, "kind": entry.kind.kindName,
      "mode": entry.mode, "mtime_ns": entry.mtimeNs, "size": entry.size,
      "sha256": entry.digest, "target": entry.target, "chunks": []}
    for chunk in entry.chunks:
      node["chunks"].add %*{"id": chunk.id, "length": chunk.length}
    result["entries"].add node

proc encodeManifest*(manifest: Manifest): string =
  manifest.validate
  result = $manifest.toJson
  require(result.len <= MaxManifestBytes, ekLimit, "manifest exceeds format limit")

proc decodeManifest*(bytes: string): Manifest =
  let node = parseBounded(bytes, MaxManifestBytes)
  node.fields(["version", "label", "created_ns", "source", "entries"])
  discard node.intField("version", FormatVersion, FormatVersion)
  result.label = node.stringField("label", MaxLabelBytes)
  result.createdNs = node.intField("created_ns", 0, high(int64))
  result.source = node.stringField("source", MaxPathBytes)
  for item in node.arrayField("entries", MaxEntries):
    item.fields(["path", "kind", "mode", "mtime_ns", "size", "sha256", "target", "chunks"])
    var entry = Entry(path: item.stringField("path", MaxPathBytes),
      mode: int(item.intField("mode", 0, 0o777)),
      mtimeNs: item.intField("mtime_ns", low(int64), high(int64)),
      size: item.intField("size", 0, high(int64)),
      digest: item.stringField("sha256", 64), target: item.stringField("target", MaxPathBytes))
    case item.stringField("kind", 16)
    of "directory": entry.kind = enDirectory
    of "file": entry.kind = enFile
    of "symlink": entry.kind = enSymlink
    else: fail(ekCorrupt, "unknown manifest entry kind")
    for chunk in item.arrayField("chunks", MaxChunkRefs):
      chunk.fields(["id", "length"])
      entry.chunks.add ChunkRef(id: chunk.stringField("id", 64),
        length: int(chunk.intField("length", 1, MaxObjectBytes)))
    result.entries.add entry
  result.validate
  canonical(bytes, result.encodeManifest)

proc logicalBytes*(manifest: Manifest): int64 =
  for entry in manifest.entries:
    require(entry.size <= high(int64) - result, ekLimit, "snapshot byte count overflow")
    result += entry.size

proc fileCount*(manifest: Manifest): int =
  for entry in manifest.entries:
    if entry.kind == enFile: inc result
