import std/[unittest, os]
import cairn/[bundle, framing, repository, restore, errors]
import support

suite "verified streaming archive transport":
  test "bundle import reconstructs a complete independent archive":
    let f = fixture()
    defer: f.cleanup
    let path = f.root / "first.cairn"
    let exported = f.repo.exportBundle("first", path)
    check exported.packets > 0
    let imported = importBundle(path, f.root / "imported")
    check imported.packets == exported.packets
    check imported.references == exported.references
    check imported.snapshots == 1
    let repo = openRepository(f.root / "imported")
    discard repo.restore("first", f.root / "restored")
    check readFile(f.root / "restored" / "a.bin") == readFile(f.source / "a.bin")
  test "truncation and payload corruption never publish a destination":
    let f = fixture()
    defer: f.cleanup
    let path = f.root / "first.cairn"
    discard f.repo.exportBundle("first", path)
    let bytes = readFile(path)
    for cut in [0, 7, 8, 40, bytes.len div 2, bytes.len-1]:
      writeFile(f.root / "bad.cairn", bytes[0..<cut])
      expect CairnError: discard importBundle(f.root / "bad.cairn", f.root / "bad-import")
      check not dirExists(f.root / "bad-import")
    var corrupt = bytes
    corrupt[bytes.len div 2] = char(uint8(corrupt[bytes.len div 2]) xor 1)
    writeFile(f.root / "bad.cairn", corrupt)
    expect CairnError: discard importBundle(f.root / "bad.cairn", f.root / "bad-import")
    check not dirExists(f.root / "bad-import")
  test "transcript detects valid-frame omission and reordering":
    let a = Frame(kind: fkPacket, payload: "a")
    let b = Frame(kind: fkPacket, payload: "b")
    var expected = initTranscript()
    expected.record(a)
    expected.record(b)
    var reversed = initTranscript()
    reversed.record(b)
    reversed.record(a)
    expect CairnError: reversed.verifyEnd(expected.ending)
    var missing = initTranscript()
    missing.record(a)
    expect CairnError: missing.verifyEnd(expected.ending)
