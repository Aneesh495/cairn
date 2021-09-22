import std/[unittest, times, sets, tables]
import cairn/[retention, fsmeta, errors]

proc info(label, date: string): SnapshotInfo =
  SnapshotInfo(label: label, createdNs: timeNs(parse(date, "yyyy-MM-dd HH:mm", utc()).toTime))

suite "deterministic UTC retention planning":
  let snapshots = @[
    info("newest", "2026-10-17 20:00"), info("same-day", "2026-10-17 10:00"),
    info("yesterday", "2026-10-16 20:00"), info("last-week", "2026-10-09 20:00"),
    info("last-month", "2026-09-17 20:00"), info("old", "2025-01-01 00:00")]
  test "latest and unique calendar buckets compose":
    let policy = RetentionPolicy(last: 1, daily: 2, weekly: 2, monthly: 2)
    let decision = planRetention(snapshots, policy)
    check decision.keep == @["newest", "yesterday", "last-week", "last-month"]
    check decision.forget == @["same-day", "old"]
    check "daily" in decision.reasons["newest"]
  test "pins survive an otherwise empty policy":
    let decision = planRetention(snapshots, RetentionPolicy(pinned: toHashSet(["old"])))
    check decision.keep == @["old"]
    check decision.forget.len == 5
  test "ties use labels and invalid input fails":
    let a = SnapshotInfo(label: "a", createdNs: 1)
    let b = SnapshotInfo(label: "b", createdNs: 1)
    check planRetention(@[b, a], RetentionPolicy(last: 1)).keep == @["a"]
    expect CairnError: discard planRetention(@[a, a], RetentionPolicy(last: 1))
    expect CairnError: discard planRetention(@[a], RetentionPolicy(last: -1))
    expect CairnError: discard planRetention(@[a], RetentionPolicy(pinned: toHashSet(["missing"])))
