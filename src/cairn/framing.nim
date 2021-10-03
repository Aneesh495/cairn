## Bounded streaming frames for archive transport. A frame carries its own
## payload digest. A final transcript digest detects valid-frame truncation,
## omission, duplication, and reordering during transport.
import std/posix
import cairn/[binary, durable, errors, limits, sha256]

type
  FrameKind* = enum
    fkConfig = 1, fkPacket = 2, fkReference = 3, fkEnd = 4
  Frame* = object
    kind*: FrameKind
    payload*: string
  FrameReader* = object
    fd: cint
    open: bool
    consumed*: int64
  Transcript* = object
    hash: Sha256
    count*: int

const
  BundleMagic* = "CAIRNB01"
  FrameMagic* = "CAIRNFR1"
  FrameHeaderBytes* = 81
  MaxFrameBytes* = MaxObjectBytes + 4096

proc openFrames*(path: string): FrameReader =
  let fd = posix.open(path.cstring, O_RDONLY or NoFollow or O_NONBLOCK)
  require(fd >= 0, ekIo, "cannot open archive bundle")
  var info: Stat
  if posix.fstat(fd, info) != 0 or not S_ISREG(info.st_mode):
    discard posix.close(fd)
    fail(ekUnsafe, "bundle input must be a regular file")
  FrameReader(fd: fd, open: true)

proc close*(reader: var FrameReader) =
  if reader.open:
    discard posix.close(reader.fd)
    reader.open = false

proc exact*(reader: var FrameReader; length: int): string =
  require(reader.open and length >= 0 and length <= MaxFrameBytes,
          ekLimit, "invalid bundle read length")
  result = newString(length)
  var at = 0
  while at < length:
    let count = posix.read(reader.fd, addr result[at], length-at)
    if count < 0:
      if errno == EINTR: continue
      fail(ekIo, "bundle read failed")
    require(count > 0, ekCorrupt, "truncated archive bundle")
    at += count
    reader.consumed += int64(count)

proc finish*(reader: var FrameReader) =
  var extra: char
  let count = posix.read(reader.fd, addr extra, 1)
  require(count == 0, ekCorrupt, "trailing bytes after bundle end")

proc serialize*(frame: Frame): string =
  require(frame.payload.len <= MaxFrameBytes, ekLimit, "bundle frame exceeds size limit")
  result = FrameMagic
  result.putU8(uint8(frame.kind))
  result.putU64(uint64(frame.payload.len))
  result.add sha256(frame.payload)
  result.add frame.payload

proc readFrame*(reader: var FrameReader): Frame =
  var header = Reader(data: reader.exact(FrameHeaderBytes))
  require(header.take(8) == FrameMagic, ekCorrupt, "bundle frame magic mismatch")
  let kind = header.u8
  require(kind in 1'u8..4'u8, ekCorrupt, "unsupported bundle frame kind")
  result.kind = FrameKind(kind)
  let length = header.boundedInt(MaxFrameBytes)
  let digest = header.take(64)
  header.finish
  result.payload = reader.exact(length)
  require(validId(digest) and sha256(result.payload) == digest,
          ekCorrupt, "bundle frame payload digest mismatch")

proc initTranscript*(): Transcript = Transcript(hash: initSha256())

proc record*(transcript: var Transcript; frame: Frame) =
  require(frame.kind != fkEnd, ekInvalid, "end frame cannot enter its own transcript")
  var descriptor = ""
  descriptor.putU8(uint8(frame.kind))
  descriptor.putU64(uint64(frame.payload.len))
  descriptor.add sha256(frame.payload)
  transcript.hash.update(descriptor)
  inc transcript.count

proc ending*(transcript: Transcript): Frame =
  var payload = ""
  payload.putU64(uint64(transcript.count))
  payload.add transcript.hash.digest
  Frame(kind: fkEnd, payload: payload)

proc verifyEnd*(transcript: Transcript; frame: Frame) =
  require(frame.kind == fkEnd and frame.payload == transcript.ending.payload,
          ekCorrupt, "bundle transcript checksum or record count mismatch")
