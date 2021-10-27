import std/[unittest, posix]
import cairn/[fsmeta, errors]

suite "filesystem metadata range checks":
  test "filesystem timestamps beyond the int64 nanosecond range reject safely":
    var info: Stat
    info.st_mode = Mode(S_IFREG)
    info.st_mtim.tv_sec = posix.Time(20_000_000_000'i64)
    info.st_ctim.tv_sec = posix.Time(20_000_000_000'i64)
    expect CairnError: discard stamp(info)
