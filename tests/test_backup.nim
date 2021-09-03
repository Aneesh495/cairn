import std/[unittest, os, tempfiles, strutils]
import cairn/[backup, repository, snapshot, manifest, errors, store, capsule, fsmeta, chunker]

suite "directory acquisition and snapshot publication":
  test "archive files, empty directories, UTF-8 names, and relative links":
    let root = createTempDir("cairn-backup-", "")
    defer: removeDir(root)
    let source = root / "source"
    createDir(source / "empty-dir")
    createDir(source / "nested")
    writeFile(source / "empty", "")
    writeFile(source / "nested" / "日本語", repeat("payload", 2000))
    createSymlink("nested/日本語", source / "link")
    let repo = initialize(root / "archive")
    let first = repo.backup(source, "first")
    check first.stats.files == 2
    check first.stats.directories == 3
    check first.stats.symlinks == 1
    check first.stats.logicalBytes == 14000
    check first.stats.packetsWritten > 0
    let second = repo.backup(source, "second")
    check second.stats.packetsWritten == 0
    check second.stats.packetsReused == first.stats.uniqueObjects * 6
    let loaded = repo.loadSnapshot("first")
    check loaded.manifest == first.snapshot.manifest
    for entry in loaded.manifest.entries:
      if entry.kind == enFile and entry.chunks.len > 0:
        check repo.loadObject(entry.chunks[0].id, okData).len == entry.chunks[0].length
  test "source identity detects replacement after enumeration":
    let root = createTempDir("cairn-backup-", "")
    defer: removeDir(root)
    writeFile(root / "file", "before")
    let items = enumerateSource(root)
    removeFile(root / "file")
    writeFile(root / "file", "after!")
    let consume = proc(bytes: string) = discard bytes
    expect CairnError: discard readSourceFile(items[1], DefaultChunks, consume)
  test "escaping symlink and nested archive reject":
    let root = createTempDir("cairn-backup-", "")
    defer: removeDir(root)
    createDir(root / "source")
    createSymlink("../../outside", root / "source" / "link")
    let repo = initialize(root / "archive")
    expect CairnError: discard repo.backup(root / "source", "bad")
    let nested = initialize(root / "source" / "nested")
    expect CairnError: discard nested.backup(root / "source", "bad")
  test "nanosecond timestamps round trip including negative values":
    for ns in [-1'i64, 0, 1, 999_999_999, 1_000_000_001, 1_700_000_000_123_456_789]:
      check timeNs(fromNs(ns)) == ns
