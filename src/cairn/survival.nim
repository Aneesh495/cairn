## Exhaustive, bounded volume-loss envelopes over a frozen damage map. This
## models correlated loss by physical volume rather than assuming independent
## shard failures. Results describe the inspected state, not disk lifetimes.
import std/[bitops, tables, json]
import cairn/[damage, errors, manifest, snapshot, store]

type
  FailureCase* = object
    unavailable*: seq[int]
    lostObjects*: int
    lostFiles*: int
    completeFileBytes*: int64
    recoverableChunkBytes*: int64
    manifestLost*: bool
  FailureLevel* = object
    losses*: int
    cases*: int
    damagingCases*: int
    worstLostFiles*: int
    minimumCompleteBytes*: int64
  SurvivalEnvelope* = object
    label*: string
    complete*: bool
    cases*: seq[FailureCase]
    levels*: seq[FailureLevel]
    smallestDamagingLoss*: int
    logicalBytes*: int64

proc survivalEnvelope*(snapshot: Snapshot; report: DamageReport; maximumLosses: int;
                       maximumCases = 10000): SurvivalEnvelope =
  require(report.label == snapshot.manifest.label and report.manifestId == snapshot.reference.manifestId,
          ekInvalid, "damage evidence belongs to another snapshot")
  require(report.objects.len > 0, ekInvalid, "damage evidence contains no manifest")
  let total = report.objects[0].total
  let required = report.objects[0].required
  require(maximumLosses >= 0 and maximumLosses <= total and maximumCases > 0,
          ekInvalid, "invalid survival envelope bounds")
  var masks = initTable[string, uint64]()
  for obj in report.objects:
    require(obj.total == total and obj.required == required, ekInvalid, "mixed coding geometry in evidence")
    var mask = 0'u64
    if obj.decodeError.len == 0:
      for slot in obj.slots:
        if slot.state == psGood: mask = mask or (1'u64 shl slot.index)
    masks[obj.id] = mask
  result.label = report.label
  result.smallestDamagingLoss = -1
  result.logicalBytes = snapshot.manifest.logicalBytes
  var cases: seq[FailureCase]
  var complete = true
  var current: seq[int]
  proc evaluate(failed: uint64) =
    var item = FailureCase(unavailable: current)
    var lost = initTable[string, bool]()
    for id, mask in masks:
      let absent = countSetBits(mask and not failed) < required
      lost[id] = absent
      if absent: inc item.lostObjects
    item.manifestLost = lost[snapshot.reference.manifestId]
    for entry in snapshot.manifest.entries:
      if entry.kind != enFile: continue
      var fileLost = item.manifestLost
      for chunk in entry.chunks:
        if lost[chunk.id]: fileLost = true
        else: item.recoverableChunkBytes += int64(chunk.length)
      if fileLost: inc item.lostFiles
      else: item.completeFileBytes += entry.size
    cases.add item
  proc enumerate(start, remaining: int; mask: uint64) =
    if cases.len >= maximumCases:
      complete = false
      return
    if remaining == 0:
      evaluate(mask)
      return
    for index in start..total-remaining:
      current.add index
      enumerate(index+1, remaining-1, mask or (1'u64 shl index))
      current.setLen(current.len-1)
      if not complete: return
  for losses in 0..maximumLosses:
    let first = cases.len
    enumerate(0, losses, 0)
    var level = FailureLevel(losses: losses, minimumCompleteBytes: result.logicalBytes)
    for i in first..<cases.len:
      inc level.cases
      if cases[i].lostObjects > 0:
        inc level.damagingCases
        if result.smallestDamagingLoss < 0: result.smallestDamagingLoss = losses
      level.worstLostFiles = max(level.worstLostFiles, cases[i].lostFiles)
      level.minimumCompleteBytes = min(level.minimumCompleteBytes, cases[i].completeFileBytes)
    result.levels.add level
    if not complete: break
  result.cases = cases
  result.complete = complete

proc toJson*(envelope: SurvivalEnvelope): JsonNode =
  result = %*{"label": envelope.label, "enumeration_complete": envelope.complete,
    "smallest_observed_damaging_loss": envelope.smallestDamagingLoss,
    "logical_bytes": envelope.logicalBytes, "levels": [], "cases": []}
  for level in envelope.levels:
    result["levels"].add %*{"unavailable_volumes": level.losses, "cases": level.cases,
      "damaging_cases": level.damagingCases, "worst_lost_files": level.worstLostFiles,
      "minimum_complete_file_bytes": level.minimumCompleteBytes}
  for item in envelope.cases:
    result["cases"].add %*{"unavailable": item.unavailable, "lost_objects": item.lostObjects,
      "lost_files": item.lostFiles, "complete_file_bytes": item.completeFileBytes,
      "recoverable_chunk_bytes": item.recoverableChunkBytes, "manifest_lost": item.manifestLost}
