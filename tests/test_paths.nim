import std/[unittest, os, tempfiles]
import cairn/[paths, errors]

suite "portable archive paths":
  test "ordinary UTF-8 paths remain exact":
    for path in ["a", "a/b", ".hidden", "space name", "unicode/日本語", "line\nname"]:
      validatePath(path)
    validatePath(".", allowRoot = true)
  test "ambiguous and escaping names reject":
    for path in ["", ".", "..", "../a", "a/..", "a/../b", "/a", "a//b", "a/",
                 "a\\b", "C:file", "a\0b", "\xff"]:
      expect CairnError: validatePath(path)
  test "labels cannot become filenames outside references":
    for label in ["today", "run_01", "2026-10-17"]: validateLabel(label)
    for label in ["", "../x", "x.json", "a b", "x/y"]:
      expect CairnError: validateLabel(label)
  test "relative symlinks can ascend only within the tree":
    validateLink("sub/link", "../file")
    validateLink("link", "sub/file")
    for pair in [("link", "../file"), ("sub/link", "../../file"), ("link", "/tmp/file")]:
      expect CairnError: validateLink(pair[0], pair[1])
  test "managed paths reject existing symlink ancestors":
    let root = createTempDir("cairn-paths-", "")
    defer: removeDir(root)
    createDir(root / "real")
    createSymlink(root / "real", root / "link")
    expect CairnError: discard managedPath(root, "link/new")
    check managedPath(root, "real/new") == expandFilename(root) / "real/new"
  test "containment uses complete components":
    check isWithin("/tmp/a/b", "/tmp/a")
    check isWithin("/tmp/a", "/tmp/a")
    check not isWithin("/tmp/ab", "/tmp/a")
