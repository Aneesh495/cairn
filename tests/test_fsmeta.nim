import std/[unittest, posix, os, tempfiles]
import cairn/[fsmeta, errors]

suite "filesystem metadata range checks":
  test "the complete representable int64 nanosecond domain round trips":
    for ns in [low(int64), low(int64)+1, -1'i64, 0'i64, 1'i64, high(int64)-1, high(int64)]:
      check timeNs(fromNs(ns)) == ns
  test "restored modification time preserves sub-microsecond precision":
    let root = createTempDir("cairn-mtime-", "")
    defer: removeDir(root)
    let path = root / "file"
    writeFile(path, "content")
    let expected = 1_700_000_000_123_456_789'i64
    applyMetadata(path, 0o600, expected)
    check stamp(path).mtimeNs == expected
  test "filesystem timestamps beyond the int64 nanosecond range reject safely":
    var info: Stat
    info.st_mode = Mode(S_IFREG)
    info.st_mtim.tv_sec = posix.Time(20_000_000_000'i64)
    info.st_ctim.tv_sec = posix.Time(20_000_000_000'i64)
    expect CairnError: discard stamp(info)
