import std/[unittest, sequtils]
import cairn/[diff, manifest, snapshot, sha256]

proc version(label: string; files: seq[tuple[path, bytes: string]]): Snapshot =
  result.manifest = Manifest(label: label, entries: @[Entry(path: ".", kind: enDirectory, mode: 0o755)])
  for (path, bytes) in files:
    result.manifest.entries.add Entry(path: path, kind: enFile, mode: 0o644,
      size: int64(bytes.len), digest: sha256(bytes))

suite "content-aware snapshot differences":
  test "content, metadata, additions, and removals are distinct":
    let a = version("a", @[("edit", "old"), ("gone", "gone"), ("mode", "same")])
    var b = version("b", @[("edit", "new"), ("mode", "same"), ("new", "new")])
    b.manifest.entries[2].mode = 0o600
    let changes = compareSnapshots(a, b).changes
    check changes.mapIt(it.kind) == @[chContent, chRemoved, chMetadata, chAdded]
    check changes.mapIt(it.path) == @["edit", "gone", "mode", "new"]
  test "unique content pairs become moves":
    let a = version("a", @[("before", "payload")])
    let b = version("b", @[("after", "payload")])
    let changes = compareSnapshots(a, b).changes
    check changes.len == 1
    check changes[0].kind == chMoved
    check changes[0].oldPath == "before"
    check changes[0].path == "after"
    check compareSnapshots(a, b, detectMoves = false).changes.len == 2
  test "duplicate content does not invent a rename pairing":
    let a = version("a", @[("one", "same"), ("two", "same")])
    let b = version("b", @[("three", "same")])
    let changes = compareSnapshots(a, b).changes
    check changes.len == 3
    check changes.allIt(it.kind != chMoved)
