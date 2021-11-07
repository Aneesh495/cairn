import std/[unittest, json, os]
import cairn/[statistics, backup, repository]
import support

suite "archive storage accounting":
  test "logical and physical byte domains remain separate":
    let f = fixture()
    defer: f.cleanup
    let first = f.repo.repositoryStats
    check first["accounting_complete"].getBool
    check first["logical_bytes_readable_snapshots"].getBiggestInt == 28000
    check first["distinct_referenced_chunk_bytes"].getBiggestInt <= 16000
    check first["physical_packet_bytes_read"].getBiggestInt > 16000
    discard f.repo.backup(f.source, "second")
    let second = f.repo.repositoryStats
    check second["logical_bytes_readable_snapshots"].getBiggestInt == 56000
    check second["distinct_referenced_chunk_bytes"] == first["distinct_referenced_chunk_bytes"]
    check second["readable_snapshots"].getInt == 2
  test "missing volumes make physical accounting explicitly incomplete":
    let f = fixture()
    defer: f.cleanup
    removeDir(f.repo.volumePath(0))
    let stats = f.repo.repositoryStats
    check not stats["accounting_complete"].getBool
    check stats["absent_volumes"].len == 1
