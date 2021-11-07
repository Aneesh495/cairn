## CLI boundary. Commands emit JSON documents on stdout and diagnostics on
## stderr. The library retains typed errors; this module assigns exit statuses
## and makes destructive maintenance plans explicit and reviewable.
import std/[os, json, sets, strutils]
import cairn/[arguments, assemble, backup, bundle, capsule, chunker, damage, demo,
  diff, durable, erasure, errors, gc, htmlreport, limits, locking, manifest,
  paths, planner, query, references, repair, repository, rescue, restore,
  retention, salvage, scan, snapshot, statistics, survival]

const Version* = "0.1.0"
const Usage* = """cairn 0.1.0 / damage-aware archives

Usage:
  cairn init REPO [--data N --parity N --chunk-min N --chunk-avg N --chunk-max N]
  cairn backup REPO SOURCE LABEL [--exclude PATTERN ...]
  cairn snapshots REPO
  cairn inspect REPO LABEL
  cairn check REPO LABEL [--fast]
  cairn restore REPO LABEL DESTINATION
  cairn extract REPO LABEL PATH DESTINATION
  cairn salvage REPO LABEL DESTINATION
  cairn find REPO LABEL GLOB
  cairn history REPO PATH
  cairn diff REPO BEFORE AFTER [--no-moves]
  cairn stats REPO
  cairn simulate REPO LABEL --unavailable 0,1
  cairn plan REPO LABEL [--costs 1,1,1,1,1,1 --max-states N]
  cairn envelope REPO LABEL [--max-loss N --max-cases N]
  cairn report REPO LABEL OUTPUT.html [--max-loss N --max-cases N --costs LIST]
  cairn repair REPO LABEL [--max-bytes N --max-packets N --apply]
  cairn apply-repair REPO PLAN.json
  cairn retention REPO [--last N --daily N --weekly N --monthly N --pin LABEL ...]
  cairn forget REPO LABEL [--apply]
  cairn gc REPO [--apply PLAN.json]
  cairn scan DIRECTORY
  cairn inspect-packet FILE
  cairn assemble NEW_REPO VOLUME_DIRECTORY ...
  cairn discover-snapshots REPO
  cairn recover-root REPO MANIFEST_ID
  cairn export REPO LABEL BUNDLE.cairn
  cairn import BUNDLE.cairn NEW_REPO
  cairn demo NEW_DIRECTORY

Output is JSON except help and version. Use -- to separate literal operands.
Exit statuses: 0 success, 1 I/O, 2 invalid input, 3 unrecoverable,
4 corruption or degraded check, 5 repository busy.
"""

proc emit(node: JsonNode) = stdout.writeLine(node.pretty)

proc costsFor(args: Arguments; total: int): seq[int64] =
  if not args.has("costs"):
    for i in 0..<total: result.add 1'i64
    return
  for value in args.get("costs").split(','):
    let parsed = parseArguments(@["--cost=" & value], @[option("cost")])
    result.add parsed.integer("cost", 1, 0, 1_000_000_000)
  require(result.len == total, ekInvalid, "cost list must name every volume")

proc unavailableFor(args: Arguments; total: int): HashSet[int] =
  require(args.has("unavailable"), ekInvalid, "--unavailable is required")
  for value in args.get("unavailable").split(','):
    let parsed = parseArguments(@["--volume=" & value], @[option("volume")])
    let index = int(parsed.integer("volume", 0, 0, total-1))
    require(index notin result, ekInvalid, "duplicate unavailable volume")
    result.incl index

proc statsJson(stats: BackupStats): JsonNode =
  %*{"files": stats.files, "directories": stats.directories, "symlinks": stats.symlinks,
    "logical_bytes": stats.logicalBytes, "chunk_references": stats.chunks,
    "distinct_data_objects": stats.uniqueObjects, "data_packets_written": stats.packetsWritten,
    "data_packets_reused": stats.packetsReused, "data_packet_bytes_written": stats.physicalBytesWritten}

proc execute*(argv: seq[string]): int =
  if argv.len == 0 or argv[0] in ["help", "--help", "-h"] or "--help" in argv:
    stdout.write(Usage)
    return 0
  if argv == @["--version"] or argv == @["version"]:
    stdout.writeLine("cairn " & Version)
    return 0
  let command = argv[0]
  let tail = argv[1..^1]
  case command
  of "init":
    let args = parseArguments(tail, @[option("data"), option("parity"), option("chunk-min"),
      option("chunk-avg"), option("chunk-max")])
    args.arity(1)
    let g = Geometry(data: int(args.integer("data", 4, 1, MaxDataShards)),
      parity: int(args.integer("parity", 2, 1, MaxShards-1)))
    let chunks = ChunkConfig(minimum: int(args.integer("chunk-min", DefaultMinChunk, 64,
        MaxObjectBytes)),
      average: int(args.integer("chunk-avg", DefaultAvgChunk, 64, MaxObjectBytes)),
      maximum: int(args.integer("chunk-max", DefaultMaxChunk, 64, MaxObjectBytes)))
    let repo = initialize(args.operands[0], g, chunks)
    emit(%*{"repository": repo.root, "repository_id": repo.config.repositoryId,
      "data_shards": g.data, "parity_shards": g.parity})
  of "backup":
    let args = parseArguments(tail, @[option("exclude", repeatable = true)])
    args.arity(3)
    let repo = openRepository(args.operands[0])
    let backed = repo.backup(args.operands[1], args.operands[2], args.all("exclude"))
    var node = statsJson(backed.stats)
    node["label"] = %backed.snapshot.manifest.label
    node["manifest_id"] = %backed.snapshot.reference.manifestId
    emit(node)
  of "snapshots":
    let args = parseArguments(tail, @[])
    args.arity(1)
    let repo = openRepository(args.operands[0])
    withRepoLock(repo.root, lmShared):
      var node = newJArray()
      for info in repo.listSnapshots:
        node.add %*{"label": info.label, "created_ns": info.createdNs,
            "manifest_id": info.manifestId}
      emit(node)
  of "inspect":
    let args = parseArguments(tail, @[])
    args.arity(2)
    let repo = openRepository(args.operands[0])
    withRepoLock(repo.root, lmShared): emit(repo.loadSnapshot(args.operands[1]).manifest.toJson)
  of "check":
    let args = parseArguments(tail, @[flag("fast")])
    args.arity(2)
    let repo = openRepository(args.operands[0])
    withRepoLock(repo.root, lmShared):
      let snapshot = repo.loadSnapshot(args.operands[1])
      let report = repo.assess(snapshot, verify = not args.has("fast"))
      let reference = repo.readReference(args.operands[1])
      var node = report.toJson
      node["valid_reference_copies"] = %reference.validCopies
      node["bad_reference_copies"] = %reference.badCopies
      node["missing_reference_copies"] = %reference.missingCopies
      node["file_digests_verified"] = %false
      if not args.has("fast") and report.lostObjects == 0:
        repo.verifyContent(snapshot.manifest)
        node["file_digests_verified"] = %true
      emit(node)
      if report.lostObjects > 0: return 3
      if report.degradedObjects > 0 or reference.badCopies.len > 0 or reference.missingCopies.len > 0: return 4
  of "restore", "salvage", "extract":
    let args = parseArguments(tail, @[])
    args.arity(if command == "extract": 4 else: 3)
    let repo = openRepository(args.operands[0])
    if command == "restore":
      let restored = repo.restore(args.operands[1], args.operands[2])
      emit(%*{"files": restored.files, "directories": restored.directories,
        "symlinks": restored.symlinks, "bytes": restored.bytes})
    elif command == "extract":
      emit(%*{"bytes": repo.extractFile(args.operands[1], args.operands[2], args.operands[3])})
    else: emit(repo.salvage(args.operands[1], args.operands[2]).map)
  of "find", "history":
    let args = parseArguments(tail, @[])
    args.arity(if command == "find": 3 else: 2)
    let repo = openRepository(args.operands[0])
    if command == "find": emit(repo.findPaths(args.operands[1], args.operands[2]))
    else: emit(repo.fileHistory(args.operands[1]))
  of "diff":
    let args = parseArguments(tail, @[flag("no-moves")])
    args.arity(3)
    let repo = openRepository(args.operands[0])
    withRepoLock(repo.root, lmShared):
      emit(compareSnapshots(repo.loadSnapshot(args.operands[1]), repo.loadSnapshot(args.operands[2]),
        detectMoves = not args.has("no-moves")).toJson)
  of "stats":
    let args = parseArguments(tail, @[])
    args.arity(1)
    emit(openRepository(args.operands[0]).repositoryStats)
  of "simulate", "plan", "envelope", "report":
    var specs: seq[OptionSpec]
    if command == "simulate": specs = @[option("unavailable")]
    elif command == "plan": specs = @[option("costs"), option("max-states")]
    elif command == "envelope": specs = @[option("max-loss"), option("max-cases")]
    else: specs = @[option("max-loss"), option("max-cases"), option("costs")]
    let args = parseArguments(tail, specs)
    args.arity(if command == "report": 3 else: 2)
    let repo = openRepository(args.operands[0])
    withRepoLock(repo.root, lmShared):
      let snapshot = repo.loadSnapshot(args.operands[1])
      if command == "simulate":
        emit(repo.assess(snapshot, unavailable = unavailableFor(args,
            repo.config.geometry.total)).toJson)
      else:
        let report = repo.assess(snapshot)
        if command == "plan":
          emit(planRecovery(report, costsFor(args, repo.config.geometry.total),
            maxStates = int(args.integer("max-states", 1_000_000, 1, 100_000_000))).toJson)
        else:
          let envelope = survivalEnvelope(snapshot, report,
            int(args.integer("max-loss", repo.config.geometry.parity, 0,
                repo.config.geometry.total)),
            int(args.integer("max-cases", 10000, 1, 1_000_000)))
          if command == "envelope": emit(envelope.toJson)
          else:
            let destination = absolutePath(args.operands[2]).normalizedPath
            require(not isWithin(destination, repo.root), ekUnsafe, "report must be outside the repository")
            let plan = planRecovery(report, costsFor(args, repo.config.geometry.total))
            writeAtomic(destination, reportHtml(snapshot, report, plan, envelope))
            emit(%*{"report": destination, "objects": report.objects.len,
                "files": report.files.len})
  of "repair":
    let args = parseArguments(tail, @[option("max-bytes"), option("max-packets"), flag("apply")])
    args.arity(2)
    let repo = openRepository(args.operands[0])
    var plan: RepairPlan
    withRepoLock(repo.root, lmShared):
      plan = repo.planRepair(repo.loadSnapshot(args.operands[1]),
        maxBytes = args.integer("max-bytes", high(int64), 0, high(int64)),
        maxPackets = int(args.integer("max-packets", high(int32), 0, high(int32))))
    if args.has("apply"):
      let repaired = repo.applyRepair(plan)
      emit(%*{"packets_repaired": repaired.packets, "bytes_written": repaired.bytes,
        "references_repaired": repaired.references, "deferred_packets": plan.deferredPackets,
        "lost_objects": plan.lostObjects})
      if plan.lostObjects.len > 0: return 3
      if plan.deferredPackets > 0: return 4
    else: stdout.writeLine(plan.encodeRepairPlan)
  of "apply-repair":
    let args = parseArguments(tail, @[])
    args.arity(2)
    let repo = openRepository(args.operands[0])
    let plan = decodeRepairPlan(readBounded(args.operands[1], MaxManifestBytes))
    let repaired = repo.applyRepair(plan)
    emit(%*{"packets_repaired": repaired.packets, "bytes_written": repaired.bytes,
      "references_repaired": repaired.references, "deferred_packets": plan.deferredPackets,
      "lost_objects": plan.lostObjects})
    if plan.lostObjects.len > 0: return 3
    if plan.deferredPackets > 0: return 4
  of "retention":
    let args = parseArguments(tail, @[option("last"), option("daily"), option("weekly"), option(
        "monthly"),
      option("pin", repeatable = true)])
    args.arity(1)
    let repo = openRepository(args.operands[0])
    let policy = RetentionPolicy(last: int(args.integer("last", 7, 0, MaxEntries)),
      daily: int(args.integer("daily", 0, 0, MaxEntries)), weekly: int(args.integer("weekly", 0, 0,
          MaxEntries)),
      monthly: int(args.integer("monthly", 0, 0, MaxEntries)), pinned: args.all("pin").toHashSet)
    withRepoLock(repo.root, lmShared): emit(planRetention(repo.listSnapshots, policy).toJson)
  of "forget":
    let args = parseArguments(tail, @[flag("apply")])
    args.arity(2)
    let repo = openRepository(args.operands[0])
    if args.has("apply"): repo.forgetSnapshot(args.operands[1])
    else:
      withRepoLock(repo.root, lmShared): discard repo.readReference(args.operands[1])
    emit(%*{"label": args.operands[1], "forgotten": args.has("apply")})
  of "gc":
    let args = parseArguments(tail, @[option("apply")])
    args.arity(1)
    let repo = openRepository(args.operands[0])
    if args.has("apply"):
      let plan = decodeGcPlan(readBounded(args.get("apply"), MaxManifestBytes))
      emit(%*{"bytes_reclaimed": repo.applyGc(plan)})
    else: stdout.writeLine(repo.planGc.encodeGcPlan)
  of "scan":
    let args = parseArguments(tail, @[])
    args.arity(1)
    emit(scanCapsules(args.operands[0]).toJson)
  of "inspect-packet":
    let args = parseArguments(tail, @[])
    args.arity(1)
    let packet = parsePacket(readBounded(args.operands[0], HeaderBytes + MaxObjectBytes))
    emit(%*{"id": packet.id, "kind": packet.kind.domain, "codec": $packet.codec,
      "volume": packet.index, "data_shards": packet.geometry.data,
      "parity_shards": packet.geometry.parity,
      "original_bytes": packet.originalLength, "encoded_bytes": packet.encodedLength,
      "shard_bytes": packet.payload.len})
  of "assemble":
    let args = parseArguments(tail, @[])
    require(args.operands.len >= 2, ekInvalid, "assemble needs a new destination and at least one volume")
    emit(assemble(args.operands[0], args.operands[1..^1]).toJson)
  of "discover-snapshots":
    let args = parseArguments(tail, @[])
    args.arity(1)
    emit(openRepository(args.operands[0]).discoverSnapshots)
  of "recover-root":
    let args = parseArguments(tail, @[])
    args.arity(2)
    let rescued = openRepository(args.operands[0]).recoverRoot(args.operands[1])
    emit(%*{"label": rescued.manifest.label, "manifest_id": rescued.reference.manifestId})
  of "export", "import":
    let args = parseArguments(tail, @[])
    args.arity(if command == "export": 3 else: 2)
    if command == "export": emit(openRepository(args.operands[0]).exportBundle(args.operands[1],
        args.operands[2]).toJson)
    else: emit(importBundle(args.operands[0], args.operands[1]).toJson)
  of "demo":
    let args = parseArguments(tail, @[])
    args.arity(1)
    emit(runDemo(args.operands[0]))
  else: fail(ekInvalid, "unknown command: " & command & "; use cairn help")
  0

proc run*(argv: seq[string]): int =
  try: result = execute(argv)
  except CairnError as error:
    stderr.writeLine("cairn: " & $error.kind & ": " & error.msg)
    case error.kind
    of ekInvalid, ekUnsafe, ekLimit: result = 2
    of ekUnrecoverable, ekMissing: result = 3
    of ekCorrupt, ekConflict: result = 4
    of ekLocked: result = 5
    of ekIo: result = 1
  except CatchableError as error:
    stderr.writeLine("cairn: I/O failure: " & error.msg)
    result = 1
