import std/[unittest, json]
import cairn/[statistics, backup]
import support

suite "archive storage accounting":
  test "logical and physical byte domains remain separate":
    let f = fixture()
    defer: f.cleanup
    let first = f.repo.repositoryStats
    check first["accounting_complete"].getBool
    check first["logical_bytes_readable_snapshots"].getBiggestInt == 28000
    check first["distinct_referenced_chunk_bytes"].getBiggestInt <= 16000
    check first["validated_packet_bytes"].getBiggestInt > 16000
    discard f.repo.backup(f.source, "second")
    let second = f.repo.repositoryStats
    check second["logical_bytes_readable_snapshots"].getBiggestInt == 56000
    check second["distinct_referenced_chunk_bytes"] == first["distinct_referenced_chunk_bytes"]
    check second["readable_snapshots"].getInt == 2
