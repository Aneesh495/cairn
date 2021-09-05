import std/[unittest, os, tempfiles, strutils, times]
import cairn/[backup, repository, restore, manifest, errors, fsmeta]

suite "verified transactional restore":
  test "complete tree restores with bytes, permissions, and mtime":
    let root = createTempDir("cairn-restore-", "")
    defer: cleanupTree(root)
    let source = root / "source"
    createDir(source / "sub")
    writeFile(source / "sub" / "data", repeat("actual bytes\0", 10000))
    writeFile(source / "empty", "")
    createSymlink("sub/data", source / "link")
    setFilePermissions(source / "sub" / "data", {fpUserRead, fpUserWrite, fpUserExec})
    setLastModificationTime(source / "sub" / "data", fromUnix(1_700_000_000))
    let repo = initialize(root / "archive")
    let backed = repo.backup(source, "first")
    removeDir(repo.volumePath(0))
    removeDir(repo.volumePath(1))
    let restored = repo.restore("first", root / "restored")
    check restored.files == 2
    check restored.symlinks == 1
    check restored.bytes == backed.stats.logicalBytes
    check readFile(root / "restored" / "sub" / "data") == readFile(source / "sub" / "data")
    check readFile(root / "restored" / "empty") == ""
    check expandSymlink(root / "restored" / "link") == "sub/data"
    check stamp(root / "restored" / "sub" / "data").mode == 0o700
    check stamp(root / "restored" / "sub" / "data").mtimeNs == 1_700_000_000_000_000_000
    expect CairnError: discard repo.restore("first", root / "restored")
  test "unrecoverable content leaves no destination or private stage":
    let root = createTempDir("cairn-restore-", "")
    defer: removeDir(root)
    createDir(root / "source")
    writeFile(root / "source" / "data", "sensitive payload")
    let repo = initialize(root / "archive")
    let backed = repo.backup(root / "source", "first")
    let id = backed.snapshot.manifest.entries[1].chunks[0].id
    for index in 0..<3: removeFile(repo.packetPath(id, index))
    expect CairnError: discard repo.restore("first", root / "restored")
    check not dirExists(root / "restored")
    for kind, path in walkDir(root):
      discard kind
      check not extractFilename(path).startsWith(".cairn-restore-")
  test "restore cannot overwrite a symlink or target the repository":
    let root = createTempDir("cairn-restore-", "")
    defer: removeDir(root)
    createDir(root / "source")
    let repo = initialize(root / "archive")
    discard repo.backup(root / "source", "first")
    createSymlink("missing", root / "target")
    expect CairnError: discard repo.restore("first", root / "target")
    expect CairnError: discard repo.restore("first", repo.root / "inside")
