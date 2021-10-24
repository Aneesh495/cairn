import std/[unittest, os, tempfiles, strutils]
import cairn/[store, repository, capsule, errors, durable]

suite "content capsule storage":
  test "damaged volume metadata is an erasure, not an archive-wide failure":
    let root = createTempDir("cairn-store-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    let stored = repo.storeObject(okData, "metadata resilience")
    writeFile(repo.volumePath(0) / "volume.json", "damaged metadata")
    check repo.loadObject(stored.id, okData) == "metadata resilience"
    repo.ensureVolume(0)
    check repo.verifyVolume(0)
  test "deduplication and catalog discovery":
    let root = createTempDir("cairn-store-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    let stored = repo.storeObject(okData, "real content")
    check stored.writtenPackets == 6
    check stored.writtenBytes > 0
    let again = repo.storeObject(okData, "real content")
    check again.id == stored.id
    check again.writtenPackets == 0
    check again.reusedPackets == 6
    check repo.objectIds == @[stored.id]
    check repo.discoverKind(stored.id) == okData
    check repo.loadObject(stored.id, okData) == "real content"
  test "lost volumes and corrupt payloads become erasures":
    let root = createTempDir("cairn-store-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    let stored = repo.storeObject(okData, repeat("content", 100))
    removeDir(repo.volumePath(0))
    var bytes = readFile(repo.packetPath(stored.id, 1))
    bytes[^1] = char(uint8(bytes[^1]) xor 1)
    writeAtomic(repo.packetPath(stored.id, 1), bytes, replace = true)
    let read = repo.readPackets(stored.id, okData)
    check read.goodCount == 4
    check read.slots[0].state == psMissing
    check read.slots[1].state == psCorrupt
    check repo.loadObject(stored.id, okData) == repeat("content", 100)
    removeFile(repo.packetPath(stored.id, 2))
    expect CairnError: discard repo.loadObject(stored.id, okData)
  test "trusted source bytes heal damaged packets":
    let root = createTempDir("cairn-store-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    let stored = repo.storeObject(okData, "heal me")
    writeFile(repo.packetPath(stored.id, 0), "broken")
    let healed = repo.storeObject(okData, "heal me")
    check healed.writtenPackets == 1
    check healed.reusedPackets == 5
    check repo.readPackets(stored.id, okData).goodCount == 6
  test "wrong kind and invalid IDs reject":
    let root = createTempDir("cairn-store-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    let stored = repo.storeObject(okData, "data")
    expect CairnError: discard repo.loadObject(stored.id, okManifest)
    expect CairnError: discard repo.loadObject("../escape", okData)
