import std/[unittest, os, tempfiles]
import cairn/[framing, binary, errors, sha256]

suite "bounded streaming frame parser":
  test "all frame truncations reject":
    let root = createTempDir("cairn-frame-", "")
    defer: removeDir(root)
    let bytes = Frame(kind: fkPacket, payload: "binary\0payload").serialize
    for length in 0..<bytes.len:
      writeFile(root / "frame", bytes[0..<length])
      var reader = openFrames(root / "frame")
      try:
        expect CairnError: discard reader.readFrame
      finally: reader.close
  test "maximum unsigned lengths reject without allocation":
    let root = createTempDir("cairn-frame-", "")
    defer: removeDir(root)
    var bytes = FrameMagic
    bytes.putU8(uint8(fkPacket))
    bytes.putU64(high(uint64))
    bytes.add sha256("")
    writeFile(root / "frame", bytes)
    var reader = openFrames(root / "frame")
    defer: reader.close
    expect CairnError: discard reader.readFrame
  test "frame digest, type, magic, and trailing bytes reject":
    let root = createTempDir("cairn-frame-", "")
    defer: removeDir(root)
    let original = Frame(kind: fkPacket, payload: "data").serialize
    for offset in [0, 8, 17, original.high]:
      var bytes = original
      bytes[offset] = '\xff'
      writeFile(root / "frame", bytes)
      var reader = openFrames(root / "frame")
      try:
        expect CairnError: discard reader.readFrame
      finally: reader.close
    writeFile(root / "frame", original & "trailing")
    var reader = openFrames(root / "frame")
    discard reader.readFrame
    expect CairnError: reader.finish
    reader.close
    reader.close
