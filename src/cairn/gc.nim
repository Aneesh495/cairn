## Mark-and-sweep maintenance with an exact preimage check. A GC plan binds
## every reference and physical packet digest. Application recomputes the plan
## under the writer lock and refuses stale or edited plans before unlinking.
## Missing volumes and unreadable roots prevent collection.
import std/[sets, json]
import cairn/[capsule, config, durable, erasure, errors, limits, locking, manifest,
  paths, references, repository, schema, sha256, snapshot, store]

type
  GarbageObject* = object
    id*: string
    bytes*: int64
    packets*: int
  GcPlan* = object
    repositoryId*: string
    fingerprint*: string
    snapshots*: seq[string]
    reachableObjects*: int
    garbage*: seq[GarbageObject]
    bytes*: int64

proc requireAllVolumes(repo: Repository) =
  for index in 0..<repo.config.geometry.total:
    require(repo.verifyVolume(index), ekMissing,
            "all volumes must be present for destructive maintenance")

proc planGcUnlocked(repo: Repository): GcPlan =
  repo.requireAllVolumes
  result.repositoryId = repo.config.repositoryId
  result.snapshots = repo.referenceLabels
  var reachable = initHashSet[string]()
  var digest = initSha256()
  digest.update(repo.config.encodeConfig)
  for label in result.snapshots:
    discard repo.readReference(label, strict = true)
    let snapshot = repo.loadSnapshot(label)
    reachable.incl snapshot.reference.manifestId
    for entry in snapshot.manifest.entries:
      for chunk in entry.chunks: reachable.incl chunk.id
    for index in 0..<repo.config.geometry.total:
      let path = repo.referencePath(label, index)
      digest.update(label & ":" & $index & ":")
      if existsAny(path): digest.update(sha256(readBounded(path, 4096)))
      else: digest.update("missing")
  result.reachableObjects = reachable.len
  for id in repo.objectIds:
    var garbage = GarbageObject(id: id)
    digest.update(id)
    for index in 0..<repo.config.geometry.total:
      let path = repo.packetPath(id, index)
      digest.update(":" & $index & ":")
      if existsAny(path):
        let bytes = readBounded(path, HeaderBytes + MaxObjectBytes)
        digest.update(sha256(bytes))
        garbage.bytes += int64(bytes.len)
        inc garbage.packets
      else: digest.update("missing")
    if id notin reachable:
      result.garbage.add garbage
      result.bytes += garbage.bytes
  result.fingerprint = digest.digest

proc planGc*(repo: Repository): GcPlan =
  withRepoLock(repo.root, lmShared): result = planGcUnlocked(repo)

proc payload(plan: GcPlan): JsonNode =
  result = %*{"version": 1, "repository_id": plan.repositoryId,
    "fingerprint": plan.fingerprint, "snapshots": plan.snapshots,
    "reachable_objects": plan.reachableObjects, "bytes": plan.bytes, "garbage": []}
  for garbage in plan.garbage:
    result["garbage"].add %*{"id": garbage.id, "bytes": garbage.bytes, "packets": garbage.packets}

proc encodeGcPlan*(plan: GcPlan): string =
  var node = plan.payload
  node["checksum"] = %sha256($node)
  $node

proc decodeGcPlan*(bytes: string): GcPlan =
  let node = parseBounded(bytes, MaxManifestBytes)
  node.fields(["version", "repository_id", "fingerprint", "snapshots",
               "reachable_objects", "bytes", "garbage", "checksum"])
  discard node.intField("version", 1, 1)
  result.repositoryId = node.stringField("repository_id", 64)
  result.fingerprint = node.stringField("fingerprint", 64)
  require(validId(result.repositoryId) and validId(result.fingerprint), ekCorrupt, "invalid GC identity")
  result.reachableObjects = int(node.intField("reachable_objects", 0, MaxChunkRefs+MaxEntries))
  result.bytes = node.intField("bytes", 0, high(int64))
  for label in node.arrayField("snapshots", MaxEntries):
    require(label.kind == JString, ekCorrupt, "invalid GC snapshot label")
    label.getStr.validateLabel
    result.snapshots.add label.getStr
  for garbage in node.arrayField("garbage", MaxChunkRefs+MaxEntries):
    garbage.fields(["id", "bytes", "packets"])
    let item = GarbageObject(id: garbage.stringField("id", 64),
      bytes: garbage.intField("bytes", 0, high(int64)),
      packets: int(garbage.intField("packets", 0, MaxShards)))
    require(validId(item.id), ekCorrupt, "invalid GC object ID")
    result.garbage.add item
  require(node.stringField("checksum", 64) == sha256($result.payload), ekCorrupt, "GC plan checksum mismatch")
  canonical(bytes, result.encodeGcPlan)

proc applyGc*(repo: Repository; plan: GcPlan): int64 =
  withRepoLock(repo.root, lmExclusive):
    let expected = planGcUnlocked(repo)
    require(plan.encodeGcPlan == expected.encodeGcPlan, ekConflict,
            "GC plan is stale, edited, or belongs to another repository")
    for garbage in plan.garbage:
      for index in 0..<repo.config.geometry.total:
        let path = repo.packetPath(garbage.id, index)
        if existsAny(path):
          let size = readBounded(path, HeaderBytes + MaxObjectBytes).len
          removeDurable(path)
          result += int64(size)
          crashPoint("gc-packet")

proc forgetSnapshot*(repo: Repository; label: string) =
  withRepoLock(repo.root, lmExclusive):
    repo.requireAllVolumes
    discard repo.readReference(label, strict = true)
    for index in 0..<repo.config.geometry.total:
      let path = repo.referencePath(label, index)
      if existsAny(path): removeDurable(path)
      crashPoint("forget-reference")
