import std/[unittest, os, tempfiles]
import cairn/[references, repository, snapshot, errors, durable, sha256, store, capsule]
import test_manifest

suite "replicated snapshot roots":
  test "publishing an incomplete content graph must fail":
    let root = createTempDir("cairn-ref-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    expect CairnError: discard repo.publishSnapshot(tinyManifest())
  test "one valid reference and sufficient shards recover a snapshot":
    let root = createTempDir("cairn-ref-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    discard repo.storeObject(okData, "abc")
    let published = repo.publishSnapshot(tinyManifest())
    check repo.loadSnapshot("sample") == published
    for index in 0..<5: removeFile(repo.referencePath("sample", index))
    check repo.readReference("sample").validCopies == 1
    check repo.loadSnapshot("sample") == published
    check repo.repairReference("sample") == 5
    check repo.readReference("sample").validCopies == 6
    expect CairnError: discard repo.publishSnapshot(tinyManifest())
  test "corrupt references are reported and strict readers fail":
    let root = createTempDir("cairn-ref-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    discard repo.storeObject(okData, "abc")
    discard repo.publishSnapshot(tinyManifest())
    writeAtomic(repo.referencePath("sample", 0), "broken", replace = true)
    let read = repo.readReference("sample")
    check read.validCopies == 5
    check read.badCopies == @[0]
    expect CairnError: discard repo.readReference("sample", strict = true)
  test "conflicting valid references never elect a winner":
    let root = createTempDir("cairn-ref-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    discard repo.storeObject(okData, "abc")
    let published = repo.publishSnapshot(tinyManifest())
    var reference = published.reference
    reference.manifestId = sha256("different manifest")
    writeAtomic(repo.referencePath("sample", 0), reference.encodeReference, replace = true)
    expect CairnError: discard repo.readReference("sample")
