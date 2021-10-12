import std/[unittest, os]
import cairn/[survival, damage, manifest, repository]
import support

suite "correlated volume-loss envelopes":
  test "healthy three-plus-two archive survives every two-volume loss":
    let f = fixture()
    defer: f.cleanup
    let envelope = survivalEnvelope(f.snapshot, f.repo.assess(f.snapshot), 3)
    check envelope.complete
    check envelope.cases.len == 26
    check envelope.smallestDamagingLoss == 3
    check envelope.levels[0].cases == 1
    check envelope.levels[1].cases == 5
    check envelope.levels[2].cases == 10
    check envelope.levels[2].damagingCases == 0
    check envelope.levels[3].damagingCases == 10
  test "existing local damage reduces the additional failure margin":
    let f = fixture()
    defer: f.cleanup
    let id = f.snapshot.manifest.entries[1].chunks[0].id
    removeFile(f.repo.packetPath(id, 0))
    let envelope = survivalEnvelope(f.snapshot, f.repo.assess(f.snapshot), 2)
    check envelope.smallestDamagingLoss == 2
    check envelope.levels[2].damagingCases > 0
    check envelope.levels[2].damagingCases < envelope.levels[2].cases
    check envelope.levels[2].worstLostFiles == 2
  test "case budget is explicit and never called exhaustive":
    let f = fixture()
    defer: f.cleanup
    let envelope = survivalEnvelope(f.snapshot, f.repo.assess(f.snapshot), 3, maximumCases = 3)
    check not envelope.complete
    check envelope.cases.len == 3
