## Assemble a new repository from surviving detached volumes. Source data is
## read and validated, never moved. Damaged packets are reported and skipped.
## Snapshot roots remain explicit even when their content is unrecoverable.
import std/[os, tempfiles, json, strutils]
import cairn/[capsule, config, damage, durable, erasure, errors, limits, paths,
  references, repository, restore, scan, snapshot]

type AssemblyResult* = object
  repository*: Repository
  copiedPackets*: int
  duplicatePackets*: int
  copiedReferences*: int
  recoverableSnapshots*: int
  incompleteSnapshots*: int
  warnings*: seq[string]

proc importPacket*(repo: Repository; bytes: string): bool =
  let packet = parsePacket(bytes)
  require(packet.geometry == repo.config.geometry, ekInvalid, "imported capsule uses another coding geometry")
  repo.ensureVolume(packet.index)
  ensureDirectory(managedPath(repo.volumePath(packet.index), "objects/" & packet.id[0..1]))
  let destination = repo.packetPath(packet.id, packet.index)
  if existsAny(destination):
    require(readBounded(destination, HeaderBytes + MaxObjectBytes) == bytes,
            ekConflict, "conflicting packets during archive assembly")
    return false
  writeAtomic(destination, bytes)
  true

proc importReference*(repo: Repository; bytes: string; index: int): bool =
  let reference = decodeReference(bytes)
  require(reference.repositoryId == repo.config.repositoryId, ekConflict, "foreign reference during assembly")
  let destination = repo.referencePath(reference.label, index)
  if existsAny(destination):
    require(readBounded(destination, 4096) == bytes, ekConflict, "conflicting reference during assembly")
    return false
  # Check other surviving copies too. A conflict cannot be hidden by placing
  # each branch of the disagreement in a different volume.
  for other in 0..<repo.config.geometry.total:
    let path = repo.referencePath(reference.label, other)
    if existsAny(path):
      require(readBounded(path, 4096) == bytes, ekConflict, "divergent snapshot references during assembly")
  writeAtomic(destination, bytes)
  true

proc assemble*(destination: string; volumes: seq[string]): AssemblyResult =
  require(volumes.len > 0 and volumes.len <= MaxShards*4, ekInvalid, "assembly needs 1..128 input volumes")
  let target = absolutePath(destination).normalizedPath
  require(not existsAny(target) and dirExists(parentDir(target)), ekConflict,
          "assembly destination must be new with an existing parent")
  var config: Config
  var metadata: seq[tuple[root: string, index: int]]
  for volume in volumes:
    require(dirExists(volume) and not symlinkExists(volume), ekUnsafe, "assembly input must be a real directory")
    let root = expandFilename(volume)
    let identity = decodeVolume(readBounded(managedPath(root, "volume.json"), 4096))
    if metadata.len == 0: config = identity.config
    else: require(identity.config == config, ekConflict, "assembly inputs belong to different repositories")
    metadata.add (root, identity.index)
  let stage = createTempDir(".cairn-assemble-", "", expandFilename(parentDir(target)))
  defer: cleanupTree(stage)
  let repo = initializeWithConfig(stage / "archive", config)
  for (root, index) in metadata:
    let scan = scanCapsules(root)
    for warning in scan.errors: result.warnings.add warning.path & ": " & warning.reason
    for located in scan.packets:
      require(located.index == index, ekConflict, "packet stored in the wrong detached volume")
      if repo.importPacket(readBounded(located.path, HeaderBytes + MaxObjectBytes)): inc result.copiedPackets
      else: inc result.duplicatePackets
    let refs = managedPath(root, "refs")
    if dirExists(refs):
      for kind, path in walkDir(refs):
        require(kind == pcFile, ekUnsafe, "non-file in detached reference directory")
        if not path.endsWith(".json"): continue
        var bytes: string
        try:
          bytes = readBounded(path, 4096)
          discard decodeReference(bytes)
        except CairnError as error:
          result.warnings.add path & ": " & error.msg
          continue
        if repo.importReference(bytes, index): inc result.copiedReferences
  for label in repo.referenceLabels:
    try:
      let snapshot = repo.loadSnapshot(label)
      let report = repo.assess(snapshot)
      if report.lostObjects == 0: inc result.recoverableSnapshots
      else: inc result.incompleteSnapshots
    except CairnError: inc result.incompleteSnapshots
  require(renameNative(repo.root.cstring, target.cstring) == 0, ekIo, "cannot publish assembled archive")
  syncDirectory(parentDir(target))
  result.repository = openRepository(target)

proc toJson*(assembly: AssemblyResult): JsonNode =
  %*{"repository": assembly.repository.root, "copied_packets": assembly.copiedPackets,
    "duplicate_packets": assembly.duplicatePackets, "copied_references": assembly.copiedReferences,
    "recoverable_snapshots": assembly.recoverableSnapshots,
    "incomplete_snapshots": assembly.incompleteSnapshots, "warnings": assembly.warnings}
