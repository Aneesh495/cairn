import std/[unittest, os, json]
import cairn/[repair, damage, manifest, repository, errors, durable, references]
import support

suite "evidence-bound repair plans":
  test "lost volume and corrupt shard are reconstructed exactly":
    let f = fixture()
    defer: f.cleanup
    let id = f.snapshot.manifest.entries[1].chunks[0].id
    removeDir(f.repo.volumePath(0))
    writeAtomic(f.repo.packetPath(id, 1), "corrupt", replace = true)
    let plan = f.repo.planRepair(f.snapshot)
    check plan.actions.len > 1
    check plan.lostObjects.len == 0
    check decodeRepairPlan(plan.encodeRepairPlan) == plan
    let result = f.repo.applyRepair(plan)
    check result.packets == plan.actions.len
    check result.bytes == plan.bytes
    check result.references == 1
    check f.repo.assess(f.snapshot).degradedObjects == 0
    expect CairnError: discard f.repo.applyRepair(plan)
  test "stale preconditions reject the whole plan before mutation":
    let f = fixture()
    defer: f.cleanup
    let id = f.snapshot.manifest.entries[1].chunks[0].id
    let first = f.repo.packetPath(id, 0)
    let second = f.repo.packetPath(id, 1)
    removeFile(first)
    removeFile(second)
    let plan = f.repo.planRepair(f.snapshot)
    writeFile(second, "concurrent change")
    expect CairnError: discard f.repo.applyRepair(plan)
    check not fileExists(first)
    check readFile(second) == "concurrent change"
  test "packet and byte budgets defer work without overstating completion":
    let f = fixture()
    defer: f.cleanup
    removeDir(f.repo.volumePath(0))
    let none = f.repo.planRepair(f.snapshot, maxBytes = 0)
    check none.actions.len == 0
    check none.deferredPackets > 0
    let one = f.repo.planRepair(f.snapshot, maxPackets = 1)
    check one.actions.len == 1
    check one.deferredPackets > 0
    discard f.repo.applyRepair(one)
    check f.repo.assess(f.snapshot).degradedObjects > 0
  test "plan checksum rejects edits":
    let f = fixture()
    defer: f.cleanup
    removeDir(f.repo.volumePath(0))
    var node = parseJson(f.repo.planRepair(f.snapshot).encodeRepairPlan)
    node["bytes"] = %0
    expect CairnError: discard decodeRepairPlan($node)
    check f.repo.readReference("first").validCopies == 4
