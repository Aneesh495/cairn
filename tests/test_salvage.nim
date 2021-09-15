import std/[unittest, os, json]
import cairn/[salvage, manifest, repository, errors]
import support

suite "honest partial recovery":
  test "missing chunks become offset fragments, never fabricated files":
    let f = fixture()
    defer: f.cleanup
    let lost = f.snapshot.manifest.entries[1].chunks[0]
    for index in 0..<3: removeFile(f.repo.packetPath(lost.id, index))
    let dest = f.root / "salvaged"
    let result = f.repo.salvage("first", dest)
    check result.partialFiles == 2
    check result.completeFiles == 2
    check result.missingBytes == int64(lost.length * 2)
    check not fileExists(dest / "complete" / "a.bin")
    check not fileExists(dest / "complete" / "b.bin")
    check readFile(dest / "complete" / "nested" / "other") == readFile(f.source / "nested" / "other")
    check fileExists(dest / "complete" / "empty")
    let persisted = parseJson(readFile(dest / "salvage.json"))
    check persisted == result.map
    let original = readFile(f.source / "a.bin")
    for file in persisted["files"]:
      if file["path"].getStr != "a.bin": continue
      for range in file["ranges"]:
        let offset = int(range["offset"].getBiggestInt)
        let length = range["length"].getInt
        let fragment = range["fragment"].getStr
        if fragment.len > 0:
          check readFile(dest / fragment) == original[offset..<offset+length]
        else: check range["id"].getStr == lost.id
  test "healthy salvage emits only verified complete files":
    let f = fixture()
    defer: f.cleanup
    let result = f.repo.salvage("first", f.root / "salvaged")
    check result.completeFiles == 4
    check result.partialFiles == 0
    check result.missingBytes == 0
    expect CairnError: discard f.repo.salvage("first", f.root / "salvaged")
