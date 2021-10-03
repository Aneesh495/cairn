## Portable, streaming archive bundles. Import uses a private repository and
## publishes it only after every frame and the final transcript verify. The
## bundle is a transport, not an independent redundancy failure domain.
import std/[os, tempfiles, json, sets, times]
import cairn/[assemble, binary, capsule, config, damage, durable, erasure, errors,
  framing, fsmeta, limits, locking, manifest, paths, references, repository, restore,
  snapshot, store, streamio]

type BundleResult* = object
  packets*: int
  references*: int
  frames*: int
  bytes*: int64
  snapshots*: int

proc exportBundle*(repo: Repository; label, destination: string): BundleResult =
  withRepoLock(repo.root, lmShared):
    let snapshot = repo.loadSnapshot(label)
    let report = repo.assess(snapshot)
    require(report.lostObjects == 0, ekUnrecoverable, "cannot export a snapshot with lost capsules")
    let target = absolutePath(destination).normalizedPath
    require(not isWithin(target, repo.root) and dirExists(parentDir(target)),
            ekUnsafe, "bundle destination must be outside the repository with an existing parent")
    let output = beginFile(target)
    try:
      output.append(BundleMagic)
      var transcript = initTranscript()
      let config = Frame(kind: fkConfig, payload: repo.config.encodeConfig)
      output.append(config.serialize)
      transcript.record(config)
      for obj in report.objects:
        # Export every surviving validated shard, preserving available margin.
        let read = repo.readPackets(obj.id, obj.kind)
        for packet in read.packets:
          let frame = Frame(kind: fkPacket, payload: packet.serialize)
          output.append(frame.serialize)
          transcript.record(frame)
          inc result.packets
          result.bytes += int64(frame.serialize.len)
      let reference = repo.readReference(label).reference.encodeReference
      for index in 0..<repo.config.geometry.total:
        var payload = ""
        payload.putU8(uint8(index))
        payload.add reference
        let frame = Frame(kind: fkReference, payload: payload)
        output.append(frame.serialize)
        transcript.record(frame)
        inc result.references
      output.append(transcript.ending.serialize)
      result.frames = transcript.count + 1
      result.snapshots = 1
      output.finish(0o600, timeNs(getTime()))
      result.bytes = int64(getFileSize(target))
    finally: output.abort

proc importBundle*(bundle, destination: string): BundleResult =
  let target = absolutePath(destination).normalizedPath
  require(not existsAny(target) and dirExists(parentDir(target)), ekConflict,
          "bundle import destination must be new with an existing parent")
  var input = openFrames(bundle)
  defer: input.close
  require(input.exact(8) == BundleMagic, ekCorrupt, "archive bundle magic mismatch")
  var transcript = initTranscript()
  let first = input.readFrame
  require(first.kind == fkConfig, ekCorrupt, "bundle must begin with configuration")
  let config = decodeConfig(first.payload)
  transcript.record(first)
  let stage = createTempDir(".cairn-import-", "", expandFilename(parentDir(target)))
  defer: cleanupTree(stage)
  let repo = initializeWithConfig(stage / "archive", config)
  var roots = initHashSet[string]()
  while true:
    require(transcript.count <= MaxChunkRefs * MaxShards, ekLimit, "bundle contains too many frames")
    let frame = input.readFrame
    if frame.kind == fkEnd:
      transcript.verifyEnd(frame)
      input.finish
      break
    case frame.kind
    of fkConfig: fail(ekCorrupt, "duplicate bundle configuration")
    of fkPacket:
      require(repo.importPacket(frame.payload), ekCorrupt, "duplicate bundle packet")
      inc result.packets
    of fkReference:
      var payload = Reader(data: frame.payload)
      let index = int(payload.u8)
      require(index < config.geometry.total, ekCorrupt, "bundle reference volume exceeds geometry")
      let bytes = payload.take(payload.remaining)
      let reference = decodeReference(bytes)
      require(repo.importReference(bytes, index), ekCorrupt, "duplicate bundle reference")
      roots.incl reference.label
      inc result.references
    of fkEnd: discard
    transcript.record(frame)
  require(roots.len > 0, ekCorrupt, "bundle contains no snapshot roots")
  for label in roots:
    let report = repo.assess(repo.loadSnapshot(label))
    require(report.lostObjects == 0, ekUnrecoverable, "bundle content graph is incomplete")
  result.snapshots = roots.len
  result.frames = transcript.count + 1
  result.bytes = input.consumed
  require(not existsAny(target), ekConflict, "bundle destination appeared during import")
  require(renameNative(repo.root.cstring, target.cstring) == 0, ekIo, "cannot publish imported archive")
  syncDirectory(parentDir(target))

proc toJson*(bundle: BundleResult): JsonNode =
  %*{"packets": bundle.packets, "references": bundle.references,
    "frames": bundle.frames, "bytes": bundle.bytes, "snapshots": bundle.snapshots}
