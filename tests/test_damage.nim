import std/[unittest, os, sets, json]
import cairn/[damage, manifest, repository, store]
import support

suite "physical damage to logical loss maps":
  test "healthy archive verifies every capsule":
    let f = fixture()
    defer: f.cleanup
    let report = f.repo.assess(f.snapshot)
    check report.lostFiles == 0
    check report.recoverableFiles == 4
    check report.degradedObjects == 0
    check report.healthyObjects == report.objects.len
    check report.recoverableBytes == report.logicalBytes
    check report.toJson["files"].len == 4
    for obj in report.objects: check obj.decodeVerified
  test "one lost shared chunk identifies every dependent file":
    let f = fixture()
    defer: f.cleanup
    let chunk = f.snapshot.manifest.entries[1].chunks[0]
    for index in 0..<3: removeFile(f.repo.packetPath(chunk.id, index))
    let report = f.repo.assess(f.snapshot)
    check report.lostObjects == 1
    check report.lostFiles == 2
    check report.recoverableFiles == 2
    check report.recoverableBytes == report.logicalBytes - int64(chunk.length * 2)
    for obj in report.objects:
      if obj.id == chunk.id:
        check obj.state == rvLost
        check obj.dependents == @["a.bin", "b.bin"]
  test "volume failure simulation does not mutate storage":
    let f = fixture()
    defer: f.cleanup
    let before = f.repo.objectIds
    let degraded = f.repo.assess(f.snapshot, unavailable = toHashSet([0, 1]))
    check degraded.lostObjects == 0
    check degraded.degradedObjects == degraded.objects.len
    let lost = f.repo.assess(f.snapshot, unavailable = toHashSet([0, 1, 2]))
    check lost.lostObjects == lost.objects.len
    check lost.lostFiles == 4
    check f.repo.objectIds == before
