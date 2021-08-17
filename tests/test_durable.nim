import std/[unittest, os, tempfiles]
import cairn/[durable, errors]

suite "durable immutable publication":
  test "publish, reject overwrite, explicitly replace":
    let root = createTempDir("cairn-io-", "")
    defer: removeDir(root)
    ensureDirectory(root / "objects")
    let path = root / "objects" / "sample"
    writeAtomic(path, "first\0bytes")
    check readBounded(path, 100) == "first\0bytes"
    expect CairnError: writeAtomic(path, "second")
    check readBounded(path, 100) == "first\0bytes"
    writeAtomic(path, "second", replace = true)
    check readBounded(path, 100) == "second"
    expect CairnError: discard readBounded(path, 2)
    for kind, file in walkDir(root / "objects"):
      discard kind
      check extractFilename(file) == "sample"
    removeDurable(path)
    check not fileExists(path)
  test "managed symlinks cannot redirect reads or writes":
    let root = createTempDir("cairn-io-", "")
    defer: removeDir(root)
    writeFile(root / "victim", "keep")
    createSymlink(root / "victim", root / "link")
    expect CairnError: writeAtomic(root / "link", "damage", replace = true)
    expect CairnError: discard readBounded(root / "link", 100)
    check readFile(root / "victim") == "keep"
  test "directories are not managed files":
    let root = createTempDir("cairn-io-", "")
    defer: removeDir(root)
    expect CairnError: discard readBounded(root, 100)
