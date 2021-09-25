import std/[unittest, os]
import cairn/[gc, repository, store, capsule, errors, references, backup, restore]
import support

suite "fail-closed archive garbage collection":
  test "only unreachable objects are reclaimed":
    let f = fixture()
    defer: f.cleanup
    let orphan = f.repo.storeObject(okData, "orphan payload")
    let plan = f.repo.planGc
    check plan.garbage.len == 1
    check plan.garbage[0].id == orphan.id
    check plan.bytes == orphan.writtenBytes
    check decodeGcPlan(plan.encodeGcPlan) == plan
    check f.repo.applyGc(plan) == orphan.writtenBytes
    check f.repo.planGc.garbage.len == 0
    discard f.repo.restore("first", f.root / "restored")
    check readFile(f.root / "restored" / "a.bin") == readFile(f.source / "a.bin")
  test "new snapshot invalidates a previously generated plan":
    let f = fixture()
    defer: f.cleanup
    let orphan = f.repo.storeObject(okData, "orphan")
    let plan = f.repo.planGc
    discard f.repo.backup(f.source, "second")
    expect CairnError: discard f.repo.applyGc(plan)
    check fileExists(f.repo.packetPath(orphan.id, 0))
  test "missing volume or damaged root disables collection":
    let f = fixture()
    defer: f.cleanup
    removeDir(f.repo.volumePath(0))
    expect CairnError: discard f.repo.planGc
    expect CairnError: f.repo.forgetSnapshot("first")
  test "forget removes roots before later collection":
    let f = fixture()
    defer: f.cleanup
    f.repo.forgetSnapshot("first")
    check f.repo.referenceLabels.len == 0
    let plan = f.repo.planGc
    check plan.garbage.len > 0
    discard f.repo.applyGc(plan)
    check f.repo.objectIds.len == 0
  test "edited deletion list cannot pass application preflight":
    let f = fixture()
    defer: f.cleanup
    var plan = f.repo.planGc
    plan.garbage.add GarbageObject(id: f.snapshot.reference.manifestId)
    expect CairnError: discard f.repo.applyGc(plan)
