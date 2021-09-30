import std/[unittest, os, tempfiles, sequtils]
import cairn/[glob, backup, repository, errors]

suite "bounded exclusion globs":
  test "stars distinguish components and directory prefixes":
    for pair in [("*.txt", "a.txt"), ("a?c", "abc"), ("**/*.txt", "a.txt"),
                 ("**/*.txt", "deep/tree/a.txt"), ("a/**/b", "a/b"),
                 ("a/**/b", "a/x/y/b"), ("a/*/b", "a/x/b")]:
      check globMatch(pair[0], pair[1])
    for pair in [("*.txt", "sub/a.txt"), ("a/*/b", "a/x/y/b"), ("a?c", "a/c"),
                 ("a/**/b", "a/xb"), ("abc", "abcd")]:
      check not globMatch(pair[0], pair[1])
  test "ordered include rules and directory-only exclusions":
    let rules = parseRules(@["*.tmp", "!keep.tmp", "/root.log", "cache/"])
    check rules.excluded("sub/data.tmp", false)
    check not rules.excluded("sub/keep.tmp", false)
    check rules.excluded("root.log", false)
    check not rules.excluded("sub/root.log", false)
    check rules.excluded("sub/cache", true)
    check not rules.excluded("sub/cache", false)
  test "archive traversal prunes excluded directories":
    let root = createTempDir("cairn-glob-", "")
    defer: removeDir(root)
    createDir(root / "source" / "cache")
    writeFile(root / "source" / "cache" / "large", "excluded")
    writeFile(root / "source" / "keep", "included")
    writeFile(root / "source" / "drop.tmp", "excluded")
    let repo = initialize(root / "archive")
    let backed = repo.backup(root / "source", "filtered", @["cache/", "*.tmp"])
    check backed.snapshot.manifest.entries.mapIt(it.path) == @[".", "keep"]
    check backed.stats.logicalBytes == 8
  test "invalid patterns reject":
    for pattern in ["", "!", "/", "../x", "a//b", "a\\b", "a\0b"]:
      expect CairnError: discard parseRules(@[pattern])
