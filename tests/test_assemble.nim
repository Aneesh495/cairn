import std/[unittest, os]
import cairn/[assemble, scan, repository, restore, errors]
import support

suite "index-free detached volume assembly":
  test "surviving volumes rebuild an archive without its top-level metadata":
    let f = fixture()
    defer: f.cleanup
    let volumes = @[f.repo.volumePath(1), f.repo.volumePath(3), f.repo.volumePath(4)]
    removeFile(f.repo.root / "config.json")
    removeFile(f.repo.root / ".lock")
    let result = assemble(f.root / "rescued", volumes)
    check result.recoverableSnapshots == 1
    check result.incompleteSnapshots == 0
    check result.warnings.len == 0
    check result.repository.config == f.repo.config
    discard result.repository.restore("first", f.root / "restored")
    check readFile(f.root / "restored" / "a.bin") == readFile(f.source / "a.bin")
  test "renamed capsule files remain discoverable":
    let f = fixture()
    defer: f.cleanup
    let volume = f.repo.volumePath(0)
    let before = scanCapsules(volume)
    moveFile(before.packets[0].path, volume / "detached.cap")
    let after = scanCapsules(volume)
    check after.packets.len == before.packets.len
    check after.errors.len == 0
  test "insufficient volumes produce an explicit incomplete result":
    let f = fixture()
    defer: f.cleanup
    let result = assemble(f.root / "rescued", @[f.repo.volumePath(0)])
    check result.recoverableSnapshots == 0
    check result.incompleteSnapshots == 1
    expect CairnError: discard result.repository.restore("first", f.root / "restored")
  test "foreign volumes cannot be combined":
    let f = fixture()
    defer: f.cleanup
    let foreign = initialize(f.root / "foreign")
    expect CairnError:
      discard assemble(f.root / "rescued", @[f.repo.volumePath(0), foreign.volumePath(1)])
    check not dirExists(f.root / "rescued")
