import std/[unittest, json, strutils]
import cairn/[manifest, sha256, errors, schema]

proc tinyManifest*(): Manifest =
  Manifest(label: "sample", createdNs: 1, source: "fixture", entries: @[
    Entry(path: ".", kind: enDirectory, mode: 0o755),
    Entry(path: "empty", kind: enFile, mode: 0o644, digest: sha256("")),
    Entry(path: "link", kind: enSymlink, mode: 0o777, target: "empty"),
    Entry(path: "sub", kind: enDirectory, mode: 0o755),
    Entry(path: "sub/data", kind: enFile, mode: 0o600, size: 3,
      digest: sha256("abc"), chunks: @[ChunkRef(id: objectId("data", "abc"), length: 3)])])

suite "strict snapshot manifests":
  test "symbolic link chains cannot escape through an intermediate parent":
    let m = Manifest(label: "links", createdNs: 1, source: "fixture", entries: @[
      Entry(path: ".", kind: enDirectory, mode: 0o755),
      Entry(path: "link", kind: enSymlink, mode: 0o777, target: "sub/up/.."),
      Entry(path: "sub", kind: enDirectory, mode: 0o755),
      Entry(path: "sub/up", kind: enSymlink, mode: 0o777, target: "..")])
    expect CairnError: discard m.encodeManifest
  test "canonical metadata round trip":
    let m = tinyManifest()
    check decodeManifest(encodeManifest(m)) == m
    check m.logicalBytes == 3
    check m.fileCount == 2
  test "cyclic symbolic links reject":
    var m = tinyManifest()
    m.entries[2].target = "link"
    expect CairnError: discard m.encodeManifest
  test "unknown fields, duplicates, noncanonical whitespace, and types reject":
    let original = tinyManifest().encodeManifest
    expect CairnError: discard decodeManifest(" " & original)
    expect CairnError: discard decodeManifest(original.replace("\"version\":1", "\"version\":1,\"version\":1"))
    var node = parseJson(original)
    node["extra"] = %true
    expect CairnError: discard decodeManifest($node)
    node.delete("extra")
    node["created_ns"] = %1.0
    expect CairnError: discard decodeManifest($node)
  test "traversal, missing parent, and child of symlink reject":
    for path in ["../escape", "missing/child", "link/child"]:
      var m = tinyManifest()
      m.entries[^1].path = path
      expect CairnError: discard m.encodeManifest
  test "wrong content lengths and duplicate paths reject":
    var m = tinyManifest()
    m.entries[^1].size = 4
    expect CairnError: discard m.encodeManifest
    m = tinyManifest()
    m.entries.add m.entries[^1]
    expect CairnError: discard m.encodeManifest
  test "deep, invalid UTF-8, and malformed JSON reject":
    expect CairnError: discard parseBounded(repeat('[', 17) & repeat(']', 17), 100)
    expect CairnError: discard parseBounded("\xff", 100)
    for value in ["{", "[] trailing", "\"unterminated", "}"]:
      expect CairnError: discard decodeManifest(value)
