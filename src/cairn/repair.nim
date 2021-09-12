## Repair is an explicit, content-bound plan. Each action records the current
## packet digest (or absence) and the exact replacement digest. Application
## preflights the whole plan under the writer lock before changing any shard.
import std/[json, algorithm, tables]
import cairn/[capsule, damage, durable, erasure, errors, limits, locking, manifest, paths,
  references, repository, schema, sha256, snapshot, store]

type
  RepairAction* = object
    id*: string
    kind*: ObjectKind
    volume*: int
    before*: string
    after*: string
    bytes*: int
  RepairPlan* = object
    repositoryId*: string
    label*: string
    manifestId*: string
    actions*: seq[RepairAction]
    lostObjects*: seq[string]
    deferredPackets*: int
    bytes*: int64
  RepairResult* = object
    packets*: int
    bytes*: int64
    references*: int

proc packetFingerprint*(repo: Repository; id: string; volume: int): string =
  let path = repo.packetPath(id, volume)
  if not existsAny(path): return "missing"
  sha256(readBounded(path, HeaderBytes + MaxObjectBytes))

proc planRepair*(repo: Repository; snapshot: Snapshot; maxBytes = high(int64);
                 maxPackets = high(int)): RepairPlan =
  require(maxBytes >= 0 and maxPackets >= 0, ekInvalid, "repair budget must be nonnegative")
  let report = repo.assess(snapshot)
  result.repositoryId = repo.config.repositoryId
  result.label = snapshot.manifest.label
  result.manifestId = snapshot.reference.manifestId
  var objects = report.objects
  objects.sort(proc(a, b: ObjectDamage): int =
    result = cmp(a.good-a.required, b.good-b.required)
    if result == 0: result = cmp(b.dependents.len, a.dependents.len)
    if result == 0: result = cmp(a.id, b.id))
  for obj in objects:
    if obj.state == rvLost:
      result.lostObjects.add obj.id
      continue
    if obj.state == rvHealthy: continue
    let packets = makePackets(obj.kind, repo.loadObject(obj.id, obj.kind), repo.config.geometry)
    for slot in obj.slots:
      if slot.state == psGood: continue
      let serialized = packets[slot.index].serialize
      if result.actions.len >= maxPackets or int64(serialized.len) > maxBytes-result.bytes:
        inc result.deferredPackets
        continue
      result.actions.add RepairAction(id: obj.id, kind: obj.kind, volume: slot.index,
        before: repo.packetFingerprint(obj.id, slot.index), after: sha256(serialized), bytes: serialized.len)
      result.bytes += int64(serialized.len)

proc payload(plan: RepairPlan): JsonNode =
  result = %*{"version": 1, "repository_id": plan.repositoryId, "label": plan.label,
    "manifest_id": plan.manifestId, "bytes": plan.bytes, "deferred_packets": plan.deferredPackets,
    "lost_objects": plan.lostObjects, "actions": []}
  for action in plan.actions:
    result["actions"].add %*{"id": action.id, "kind": action.kind.domain,
      "volume": action.volume, "before": action.before, "after": action.after, "bytes": action.bytes}

proc encodeRepairPlan*(plan: RepairPlan): string =
  var node = plan.payload
  node["checksum"] = %sha256($node)
  $node

proc decodeRepairPlan*(bytes: string): RepairPlan =
  let node = parseBounded(bytes, MaxManifestBytes)
  node.fields(["version", "repository_id", "label", "manifest_id", "bytes",
               "deferred_packets", "lost_objects", "actions", "checksum"])
  discard node.intField("version", 1, 1)
  result.repositoryId = node.stringField("repository_id", 64)
  result.manifestId = node.stringField("manifest_id", 64)
  result.label = node.stringField("label", 80)
  result.label.validateLabel
  require(validId(result.repositoryId) and validId(result.manifestId), ekCorrupt, "invalid repair plan identity")
  result.bytes = node.intField("bytes", 0, high(int64))
  result.deferredPackets = int(node.intField("deferred_packets", 0, high(int32)))
  for id in node.arrayField("lost_objects", MaxChunkRefs):
    require(id.kind == JString and validId(id.getStr), ekCorrupt, "invalid lost object ID")
    result.lostObjects.add id.getStr
  var sum = 0'i64
  for action in node.arrayField("actions", MaxChunkRefs):
    action.fields(["id", "kind", "volume", "before", "after", "bytes"])
    var item = RepairAction(id: action.stringField("id", 64),
      volume: int(action.intField("volume", 0, MaxShards-1)),
      before: action.stringField("before", 64), after: action.stringField("after", 64),
      bytes: int(action.intField("bytes", HeaderBytes, HeaderBytes+MaxObjectBytes)))
    case action.stringField("kind", 16)
    of "data": item.kind = okData
    of "manifest": item.kind = okManifest
    else: fail(ekCorrupt, "invalid repair action kind")
    require(validId(item.id) and validId(item.after) and
            (item.before == "missing" or validId(item.before)), ekCorrupt, "invalid repair action digest")
    require(int64(item.bytes) <= high(int64)-sum, ekLimit, "repair size overflow")
    sum += int64(item.bytes)
    result.actions.add item
  require(sum == result.bytes and node.stringField("checksum", 64) == sha256($result.payload),
          ekCorrupt, "repair plan checksum or size mismatch")
  canonical(bytes, result.encodeRepairPlan)

proc applyRepair*(repo: Repository; plan: RepairPlan): RepairResult =
  withRepoLock(repo.root, lmExclusive):
    require(plan.repositoryId == repo.config.repositoryId, ekConflict, "repair plan belongs to another archive")
    let snapshot = repo.loadSnapshot(plan.label)
    require(snapshot.reference.manifestId == plan.manifestId, ekConflict, "repair snapshot changed")
    var cachedId = ""
    var cachedPackets: seq[Packet]
    var targets = initTable[string, bool]()
    for action in plan.actions:
      require(action.volume < repo.config.geometry.total, ekCorrupt, "repair volume exceeds geometry")
      let target = action.id & ":" & $action.volume
      require(not targets.hasKey(target), ekCorrupt, "duplicate repair target")
      targets[target] = true
      require(repo.packetFingerprint(action.id, action.volume) == action.before,
              ekConflict, "repair plan is stale for " & target)
      if cachedId != action.id:
        cachedPackets = makePackets(action.kind, repo.loadObject(action.id, action.kind), repo.config.geometry)
        cachedId = action.id
      let packet = cachedPackets[action.volume]
      require(packet.kind == action.kind and sha256(packet.serialize) == action.after and
              packet.serialize.len == action.bytes, ekCorrupt, "repair replacement differs from plan")
    # No storage mutation occurs before the entire preflight above succeeds.
    cachedId = ""
    for action in plan.actions:
      if cachedId != action.id:
        cachedPackets = makePackets(action.kind, repo.loadObject(action.id, action.kind), repo.config.geometry)
        cachedId = action.id
      let serialized = cachedPackets[action.volume].serialize
      repo.ensureVolume(action.volume)
      ensureDirectory(managedPath(repo.volumePath(action.volume), "objects/" & action.id[0..1]))
      writeAtomic(repo.packetPath(action.id, action.volume), serialized, replace = action.before != "missing")
      inc result.packets
      result.bytes += int64(serialized.len)
      crashPoint("repair-packet")
    result.references = repo.repairReference(plan.label)
