import std/[unittest, os, json]
import cairn/[query, rescue, repository, references, backup, errors]
import support

suite "snapshot navigation and explicit root rescue":
  test "find, history, and targeted extraction":
    let f = fixture()
    defer: f.cleanup
    check f.repo.findPaths("first", "*.bin").len == 2
    check f.repo.findPaths("first", "**/other").len == 1
    writeFile(f.source / "a.bin", "changed")
    discard f.repo.backup(f.source, "second")
    let history = f.repo.fileHistory("a.bin")
    check history.len == 2
    check history[0]["label"].getStr == "second"
    check history[0]["sha256"] != history[1]["sha256"]
    discard f.repo.extractFile("first", "a.bin", f.root / "extracted")
    check readFile(f.root / "extracted") == readFile(f.source / "b.bin")
    expect CairnError: discard f.repo.extractFile("first", "../escape", f.root / "escape")
  test "manifests survive complete reference-directory loss":
    let f = fixture()
    defer: f.cleanup
    for index in 0..<5: removeFile(f.repo.referencePath("first", index))
    check f.repo.referenceLabels.len == 0
    let candidates = f.repo.discoverSnapshots
    check candidates["candidates"].len == 1
    check candidates["candidates"][0]["readable"].getBool
    let rescued = f.repo.recoverRoot(f.snapshot.reference.manifestId)
    check rescued.reference == f.snapshot.reference
    check f.repo.referenceLabels == @["first"]
    expect CairnError: discard f.repo.recoverRoot(f.snapshot.reference.manifestId)
