## Content-addressed capsule storage. Reads never trust filenames as evidence:
## the header ID, geometry, kind, payload hash, and reconstructed object hash
## are checked independently. A directory scan can rebuild the catalog.
import std/[os, sets, algorithm, strutils]
import cairn/[capsule, durable, erasure, errors, limits, paths, repository, sha256]

type
  PacketState* = enum
    psGood, psMissing, psCorrupt
  PacketStatus* = object
    index*: int
    state*: PacketState
    reason*: string
    bytes*: int64
  ObjectRead* = object
    id*: string
    packets*: seq[Packet]
    slots*: seq[PacketStatus]
  StoreResult* = object
    id*: string
    writtenPackets*: int
    writtenBytes*: int64
    reusedPackets*: int

proc goodCount*(read: ObjectRead): int = read.packets.len
proc recoverable*(read: ObjectRead; repo: Repository): bool =
  read.goodCount >= repo.config.geometry.data

proc readPackets*(repo: Repository; id: string; expected: ObjectKind): ObjectRead =
  ## Collect evidence for every configured position without hiding erasures.
  ## A caller doing a multi-step read must already hold a shared or writer lock.
  require(validId(id), ekInvalid, "invalid content ID")
  result.id = id
  for index in 0..<repo.config.geometry.total:
    var status = PacketStatus(index: index, state: psMissing, reason: "packet absent")
    if not repo.verifyVolume(index):
      status.reason = "volume absent"
      result.slots.add status
      continue
    let path = repo.packetPath(id, index)
    if existsAny(path):
      try:
        let bytes = readBounded(path, HeaderBytes + MaxObjectBytes)
        status.bytes = int64(bytes.len)
        let packet = parsePacket(bytes)
        require(packet.id == id and packet.kind == expected and
                packet.index == index and packet.geometry == repo.config.geometry,
                ekCorrupt, "packet identity or placement mismatch")
        if result.packets.len > 0:
          require(compatible(result.packets[0], packet), ekCorrupt, "conflicting capsule metadata")
        result.packets.add packet
        status.state = psGood
        status.reason = "validated"
      except CairnError as error:
        status.state = psCorrupt
        status.reason = error.msg
    result.slots.add status

proc loadObject*(repo: Repository; id: string; kind: ObjectKind): string =
  let read = repo.readPackets(id, kind)
  require(read.recoverable(repo), ekUnrecoverable,
    "object " & id & " has " & $read.goodCount & "/" & $repo.config.geometry.data & " required shards")
  recover(read.packets)

proc storeObject*(repo: Repository; kind: ObjectKind; bytes: string): StoreResult =
  ## Store all positions, compare existing packets exactly, and heal damaged
  ## copies from these trusted source bytes. The caller holds the writer lock.
  let packets = makePackets(kind, bytes, repo.config.geometry)
  result.id = packets[0].id
  for packet in packets:
    repo.ensureVolume(packet.index)
    let volume = repo.volumePath(packet.index)
    let bucket = managedPath(volume, "objects/" & result.id[0..1])
    ensureDirectory(bucket)
    let path = repo.packetPath(result.id, packet.index)
    let serialized = packet.serialize
    var replace = false
    if existsAny(path):
      # Equality also enforces deterministic compression and canonical headers.
      # A damaged shard may be healed from the newly supplied source bytes.
      let existing = readBounded(path, HeaderBytes + MaxObjectBytes)
      if existing == serialized:
        inc result.reusedPackets
        continue
      try:
        let parsed = parsePacket(existing)
        require(parsed.id != result.id, ekConflict,
                "valid packet differs from canonical encoding for its ID")
      except CairnError as error:
        if error.kind == ekConflict: raise
      replace = true
    writeAtomic(path, serialized, replace = replace)
    inc result.writtenPackets
    result.writtenBytes += int64(serialized.len)
    crashPoint("object-packet")
  crashPoint("object-complete")

proc objectIds*(repo: Repository): seq[string] =
  var ids = initHashSet[string]()
  for index in 0..<repo.config.geometry.total:
    if not repo.verifyVolume(index): continue
    let root = managedPath(repo.volumePath(index), "objects")
    for bucketKind, bucketPath in walkDir(root):
      require(bucketKind == pcDir, ekUnsafe, "unexpected entry in object bucket root")
      let bucket = extractFilename(bucketPath)
      require(bucket.len == 2, ekCorrupt, "invalid object bucket name")
      discard managedPath(root, bucket)
      for fileKind, path in walkDir(bucketPath):
        require(fileKind == pcFile, ekUnsafe, "non-file entry in object bucket")
        let name = extractFilename(path)
        if name.len > 0 and name[0] == '.': continue # Unpublished crash stages.
        require(name.len == 68 and name.endsWith(".cap"), ekCorrupt, "invalid capsule filename")
        let id = name[0..<64]
        require(validId(id) and id[0..1] == bucket, ekCorrupt, "misplaced capsule filename")
        ids.incl id
  for id in ids: result.add id
  result.sort

proc discoverKind*(repo: Repository; id: string): ObjectKind =
  for index in 0..<repo.config.geometry.total:
    if not repo.verifyVolume(index): continue
    let path = repo.packetPath(id, index)
    if not fileExists(path): continue
    try:
      let packet = parsePacket(readBounded(path, HeaderBytes + MaxObjectBytes))
      require(packet.id == id and packet.index == index and
              packet.geometry == repo.config.geometry, ekCorrupt, "invalid object placement")
      return packet.kind
    except CairnError: discard
  fail(ekUnrecoverable, "no valid header identifies object " & id)
