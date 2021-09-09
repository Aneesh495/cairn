## The damage map joins physical shard evidence to logical file dependencies.
## It distinguishes recoverability from verified recovery: enough shard counts
## are necessary, but a decoded content hash is the final authority.
import std/[tables, sets, algorithm, json]
import cairn/[capsule, erasure, errors, manifest, repository, snapshot, store]

type
  Recoverability* = enum
    rvHealthy, rvDegraded, rvLost
  ObjectDamage* = object
    id*: string
    kind*: ObjectKind
    state*: Recoverability
    good*: int
    required*: int
    total*: int
    originalBytes*: int
    packetBytes*: int64
    slots*: seq[PacketStatus]
    decodeVerified*: bool
    decodeError*: string
    dependents*: seq[string]
  FileDamage* = object
    path*: string
    size*: int64
    recoverableBytes*: int64
    state*: Recoverability
    lostChunks*: seq[string]
    degradedChunks*: seq[string]
  DamageReport* = object
    label*: string
    manifestId*: string
    objects*: seq[ObjectDamage]
    files*: seq[FileDamage]
    healthyObjects*: int
    degradedObjects*: int
    lostObjects*: int
    recoverableFiles*: int
    lostFiles*: int
    logicalBytes*: int64
    recoverableBytes*: int64
    verified*: bool

proc stateName*(state: Recoverability): string =
  case state
  of rvHealthy: "healthy"
  of rvDegraded: "degraded"
  of rvLost: "lost"

proc assessObject*(repo: Repository; id: string; kind: ObjectKind;
                   verify = true; unavailable: HashSet[int] = initHashSet[int]()): ObjectDamage =
  let read = repo.readPackets(id, kind)
  result.id = id
  result.kind = kind
  result.required = repo.config.geometry.data
  result.total = repo.config.geometry.total
  result.slots = read.slots
  var packets: seq[Packet]
  for packet in read.packets:
    if packet.index notin unavailable: packets.add packet
  for slot in result.slots.mitems:
    if slot.index in unavailable:
      slot.state = psMissing
      slot.reason = "simulated unavailable volume"
    if slot.state == psGood: result.packetBytes += slot.bytes
  result.good = packets.len
  if packets.len > 0: result.originalBytes = packets[0].originalLength
  if result.good < result.required: result.state = rvLost
  elif result.good < result.total: result.state = rvDegraded
  else: result.state = rvHealthy
  if verify and result.state != rvLost:
    try:
      discard recover(packets)
      result.decodeVerified = true
    except CairnError as e:
      result.state = rvLost
      result.decodeError = e.msg

proc assess*(repo: Repository; snapshot: Snapshot; verify = true;
             unavailable: HashSet[int] = initHashSet[int]()): DamageReport =
  result.label = snapshot.manifest.label
  result.manifestId = snapshot.reference.manifestId
  result.verified = verify
  var kinds = initTable[string, ObjectKind]()
  var dependencies = initTable[string, HashSet[string]]()
  kinds[result.manifestId] = okManifest
  for entry in snapshot.manifest.entries:
    if entry.kind != enFile: continue
    for chunk in entry.chunks:
      kinds[chunk.id] = okData
      if not dependencies.hasKey(chunk.id): dependencies[chunk.id] = initHashSet[string]()
      dependencies[chunk.id].incl entry.path
  var ids: seq[string]
  for id in kinds.keys: ids.add id
  ids.sort
  var states = initTable[string, Recoverability]()
  for id in ids:
    var damage = repo.assessObject(id, kinds[id], verify, unavailable)
    if dependencies.hasKey(id):
      for path in dependencies[id]: damage.dependents.add path
      damage.dependents.sort
    states[id] = damage.state
    case damage.state
    of rvHealthy: inc result.healthyObjects
    of rvDegraded: inc result.degradedObjects
    of rvLost: inc result.lostObjects
    result.objects.add damage
  for entry in snapshot.manifest.entries:
    if entry.kind != enFile: continue
    var file = FileDamage(path: entry.path, size: entry.size, state: rvHealthy)
    for chunk in entry.chunks:
      case states[chunk.id]
      of rvLost:
        file.state = rvLost
        file.lostChunks.add chunk.id
      of rvDegraded:
        if file.state != rvLost: file.state = rvDegraded
        file.degradedChunks.add chunk.id
        file.recoverableBytes += int64(chunk.length)
      of rvHealthy: file.recoverableBytes += int64(chunk.length)
    # The manifest itself is a dependency of every pathname and file layout.
    if states[result.manifestId] == rvLost: file.state = rvLost
    elif states[result.manifestId] == rvDegraded and file.state == rvHealthy:
      file.state = rvDegraded
    result.logicalBytes += entry.size
    result.recoverableBytes += file.recoverableBytes
    if file.state == rvLost: inc result.lostFiles
    else: inc result.recoverableFiles
    result.files.add file

proc toJson*(report: DamageReport): JsonNode =
  result = %*{"label": report.label, "manifest_id": report.manifestId,
    "decode_verification": report.verified, "healthy_objects": report.healthyObjects,
    "degraded_objects": report.degradedObjects, "lost_objects": report.lostObjects,
    "recoverable_files": report.recoverableFiles, "lost_files": report.lostFiles,
    "logical_bytes": report.logicalBytes, "recoverable_chunk_bytes": report.recoverableBytes,
    "objects": [], "files": []}
  for obj in report.objects:
    var node = %*{"id": obj.id, "kind": obj.kind.domain, "state": obj.state.stateName,
      "good": obj.good, "required": obj.required, "total": obj.total,
      "original_bytes": obj.originalBytes, "validated_packet_bytes": obj.packetBytes,
      "decode_verified": obj.decodeVerified, "decode_error": obj.decodeError,
      "dependents": obj.dependents, "slots": []}
    for slot in obj.slots:
      node["slots"].add %*{"volume": slot.index, "state": $slot.state,
        "reason": slot.reason, "bytes": slot.bytes}
    result["objects"].add node
  for file in report.files:
    result["files"].add %*{"path": file.path, "size": file.size,
      "recoverable_chunk_bytes": file.recoverableBytes, "state": file.state.stateName,
      "lost_chunks": file.lostChunks, "degraded_chunks": file.degradedChunks}
