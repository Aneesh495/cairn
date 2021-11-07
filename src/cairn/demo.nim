## A complete local walkthrough over deterministic synthetic files. Every
## destructive step is restricted to the newly created demonstration tree.
import std/[os, strutils, json]
import cairn/[backup, damage, diff, durable, errors, htmlreport,
  paths, planner, prng, repair, repository, restore, sha256, survival]

proc runDemo*(destination: string): JsonNode =
  let root = absolutePath(destination).normalizedPath
  require(not existsAny(root) and dirExists(parentDir(root)), ekConflict,
          "demo destination must be new with an existing parent")
  ensureDirectory(root)
  ensureDirectory(root / "source")
  ensureDirectory(root / "source" / "measurements")
  ensureDirectory(root / "source" / "notes")
  ensureDirectory(root / "source" / "empty")
  var rng = Prng(state: 0x636169726e'u64)
  let measurements = rng.bytes(2*1024*1024)
  writeFile(root / "source" / "measurements" / "run-a.bin", measurements)
  writeFile(root / "source" / "measurements" / "run-b.bin", measurements)
  writeFile(root / "source" / "notes" / "readme.txt", "Local instrument run. Preserve the bytes and the recovery path.\n")
  writeFile(root / "source" / "notes" / "events.log", repeat("steady state; sensor healthy\n", 8000))
  createSymlink("measurements/run-a.bin", root / "source" / "latest")
  let repo = initialize(root / "archive")
  let first = repo.backup(root / "source", "baseline")
  writeFile(root / "source" / "measurements" / "run-a.bin", "new calibration header\n" & measurements)
  writeFile(root / "source" / "notes" / "readme.txt", "Calibration header added. Original payload is unchanged.\n")
  let second = repo.backup(root / "source", "revision")
  writeAtomic(root / "diff.json", $compareSnapshots(first.snapshot, second.snapshot).toJson)
  removeDir(repo.volumePath(0))
  removeDir(repo.volumePath(1))
  let damage = repo.assess(second.snapshot)
  let plan = planRecovery(damage, @[1'i64, 1, 1, 1, 1, 1])
  let envelope = survivalEnvelope(second.snapshot, damage, 1)
  writeAtomic(root / "damage.json", $damage.toJson)
  writeAtomic(root / "report.html", reportHtml(second.snapshot, damage, plan, envelope))
  let repair = repo.planRepair(second.snapshot)
  writeAtomic(root / "repair.json", repair.encodeRepairPlan)
  let repaired = repo.applyRepair(repair)
  let restored = repo.restore("revision", root / "restored")
  for relative in ["measurements/run-a.bin", "measurements/run-b.bin", "notes/readme.txt",
      "notes/events.log"]:
    require(sha256(readFile(root / "source" / relative)) == sha256(readFile(root / "restored" / relative)),
            ekCorrupt, "demo restored byte comparison failed")
  result = %*{"root": root, "snapshots": ["baseline", "revision"],
    "baseline_data_packets_written": first.stats.packetsWritten,
    "revision_data_packets_written": second.stats.packetsWritten,
    "revision_data_packets_reused": second.stats.packetsReused,
    "removed_volumes": [0, 1], "degraded_capsules_before_repair": damage.degradedObjects,
    "lost_capsules_before_repair": damage.lostObjects, "repaired_packets": repaired.packets,
    "restored_files": restored.files, "restored_bytes": restored.bytes,
    "byte_comparison": "passed", "report": root / "report.html"}
  writeAtomic(root / "result.json", $result)
