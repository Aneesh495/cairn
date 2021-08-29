## Snapshot roots are small, checksummed records replicated into each volume.
## One surviving valid record is enough to identify a manifest. Conflicting
## valid records fail closed; no majority vote silently chooses user data.
import std/[json, os, sets, algorithm, strutils]
import cairn/[durable, erasure, errors, paths, repository, schema, sha256]

type
  Reference* = object
    label*: string
    manifestId*: string
    repositoryId*: string
  ReferenceRead* = object
    reference*: Reference
    validCopies*: int
    badCopies*: seq[int]
    missingCopies*: seq[int]

proc payload(reference: Reference): JsonNode =
  %*{"version": 1, "label": reference.label, "manifest_id": reference.manifestId,
    "repository_id": reference.repositoryId}

proc encodeReference*(reference: Reference): string =
  reference.label.validateLabel
  require(validId(reference.manifestId) and validId(reference.repositoryId),
          ekInvalid, "invalid snapshot reference IDs")
  var node = reference.payload
  node["checksum"] = %sha256($node)
  $node

proc decodeReference*(bytes: string): Reference =
  let node = parseBounded(bytes, 4096)
  node.fields(["version", "label", "manifest_id", "repository_id", "checksum"])
  discard node.intField("version", 1, 1)
  result = Reference(label: node.stringField("label", 80),
    manifestId: node.stringField("manifest_id", 64),
    repositoryId: node.stringField("repository_id", 64))
  require(node.stringField("checksum", 64) == sha256($result.payload),
          ekCorrupt, "snapshot reference checksum mismatch")
  canonical(bytes, result.encodeReference)

proc referenceLabels*(repo: Repository): seq[string] =
  var labels = initHashSet[string]()
  for index in 0..<repo.config.geometry.total:
    if not repo.verifyVolume(index): continue
    let root = managedPath(repo.volumePath(index), "refs")
    for kind, path in walkDir(root):
      require(kind == pcFile, ekUnsafe, "non-file in snapshot reference directory")
      let name = extractFilename(path)
      if name.startsWith(".cairn-stage-"): continue
      require(name.endsWith(".json"), ekCorrupt, "unexpected snapshot reference filename")
      let label = name[0..<name.len-5]
      label.validateLabel
      labels.incl label
  for label in labels: result.add label
  result.sort

proc readReference*(repo: Repository; label: string; strict = false): ReferenceRead =
  label.validateLabel
  for index in 0..<repo.config.geometry.total:
    if not repo.verifyVolume(index):
      result.missingCopies.add index
      continue
    let path = repo.referencePath(label, index)
    if not existsAny(path):
      result.missingCopies.add index
      continue
    var reference: Reference
    try:
      reference = decodeReference(readBounded(path, 4096))
      require(reference.label == label and reference.repositoryId == repo.config.repositoryId,
              ekCorrupt, "snapshot reference identity mismatch")
    except CairnError:
      if strict: raise
      result.badCopies.add index
      continue
    if result.validCopies > 0:
      require(reference == result.reference, ekConflict,
              "conflicting valid references for snapshot " & label)
    result.reference = reference
    inc result.validCopies
  require(result.validCopies > 0, ekUnrecoverable,
          "no valid snapshot reference remains for " & label)

proc assertNewLabel*(repo: Repository; label: string) =
  label.validateLabel
  for index in 0..<repo.config.geometry.total:
    require(not existsAny(repo.referencePath(label, index)), ekConflict,
            "snapshot label already exists: " & label)

proc publishReference*(repo: Repository; reference: Reference) =
  repo.assertNewLabel(reference.label)
  require(reference.repositoryId == repo.config.repositoryId,
          ekInvalid, "cannot publish a foreign snapshot reference")
  let encoded = reference.encodeReference
  for index in 0..<repo.config.geometry.total:
    repo.ensureVolume(index)
    writeAtomic(repo.referencePath(reference.label, index), encoded)
    crashPoint("reference-published")

proc repairReference*(repo: Repository; label: string): int =
  let read = repo.readReference(label)
  let bytes = read.reference.encodeReference
  for index in read.badCopies & read.missingCopies:
    repo.ensureVolume(index)
    let path = repo.referencePath(label, index)
    writeAtomic(path, bytes, replace = existsAny(path))
    inc result
