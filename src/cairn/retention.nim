## Pure retention decisions over UTC creation times. Calendar buckets retain
## the newest snapshot in each selected day, week, or month. The decision is a
## plan only; deleting roots and reclaiming objects are separate operations.
import std/[algorithm, sets, tables, times, json]
import cairn/[errors, fsmeta, references, repository, snapshot]

type
  SnapshotInfo* = object
    label*: string
    createdNs*: int64
    manifestId*: string
  RetentionPolicy* = object
    last*: int
    daily*: int
    weekly*: int
    monthly*: int
    pinned*: HashSet[string]
  RetentionDecision* = object
    keep*: seq[string]
    forget*: seq[string]
    reasons*: Table[string, seq[string]]

proc listSnapshots*(repo: Repository): seq[SnapshotInfo] =
  for label in repo.referenceLabels:
    let snapshot = repo.loadSnapshot(label)
    result.add SnapshotInfo(label: label, createdNs: snapshot.manifest.createdNs,
      manifestId: snapshot.reference.manifestId)
  result.sort(proc(a, b: SnapshotInfo): int =
    result = cmp(b.createdNs, a.createdNs)
    if result == 0: result = cmp(a.label, b.label))

proc planRetention*(snapshots: seq[SnapshotInfo]; policy: RetentionPolicy): RetentionDecision =
  for count in [policy.last, policy.daily, policy.weekly, policy.monthly]:
    require(count >= 0, ekInvalid, "retention counts must be nonnegative")
  var ordered = snapshots
  ordered.sort(proc(a, b: SnapshotInfo): int =
    result = cmp(b.createdNs, a.createdNs)
    if result == 0: result = cmp(a.label, b.label))
  var seenLabels = initHashSet[string]()
  for snapshot in ordered:
    require(snapshot.createdNs >= 0 and snapshot.label notin seenLabels, ekInvalid,
            "retention input contains invalid times or duplicate labels")
    seenLabels.incl snapshot.label
  for label in policy.pinned:
    require(label in seenLabels, ekInvalid, "pinned snapshot does not exist: " & label)
  result.reasons = initTable[string, seq[string]]()
  var days = initHashSet[int64]()
  var weeks = initHashSet[int64]()
  var months = initHashSet[int]()
  for i, snapshot in ordered:
    var reasons: seq[string]
    if snapshot.label in policy.pinned: reasons.add "pinned"
    if i < policy.last: reasons.add "latest"
    let seconds = snapshot.createdNs div 1_000_000_000
    let day = seconds div 86400
    let week = (day+3) div 7 # Epoch Thursday belongs to Monday-based UTC week.
    let date = fromNs(snapshot.createdNs).utc
    let month = date.year * 12 + ord(date.month)-1
    if day notin days and days.len < policy.daily:
      days.incl day
      reasons.add "daily"
    if week notin weeks and weeks.len < policy.weekly:
      weeks.incl week
      reasons.add "weekly"
    if month notin months and months.len < policy.monthly:
      months.incl month
      reasons.add "monthly"
    if reasons.len > 0:
      result.keep.add snapshot.label
      result.reasons[snapshot.label] = reasons
    else: result.forget.add snapshot.label

proc toJson*(decision: RetentionDecision): JsonNode =
  result = %*{"keep": decision.keep, "forget": decision.forget, "reasons": {}}
  for label in decision.keep: result["reasons"][label] = %decision.reasons[label]
