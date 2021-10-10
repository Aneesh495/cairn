## Last-resort root discovery. This is intentionally explicit: scanning can
## find manifests belonging to snapshots whose roots were deliberately
## forgotten. Discovery does not silently resurrect them.
import std/json
import cairn/[capsule, damage, errors, locking, manifest, references,
  repository, snapshot, store]

proc discoverSnapshots*(repo: Repository): JsonNode =
  withRepoLock(repo.root, lmShared):
    result = %*{"candidates": [], "unidentified_objects": []}
    for id in repo.objectIds:
      var kind: ObjectKind
      try: kind = repo.discoverKind(id)
      except CairnError:
        result["unidentified_objects"].add %id
        continue
      if kind != okManifest: continue
      var node = %*{"manifest_id": id, "readable": false, "label": "", "error": ""}
      try:
        let manifest = decodeManifest(repo.loadObject(id, okManifest))
        let reference = Reference(label: manifest.label, manifestId: id,
          repositoryId: repo.config.repositoryId)
        let report = repo.assess(Snapshot(reference: reference, manifest: manifest))
        node["readable"] = %true
        node["label"] = %manifest.label
        node["created_ns"] = %manifest.createdNs
        node["files"] = %manifest.fileCount
        node["lost_objects"] = %report.lostObjects
      except CairnError as error: node["error"] = %error.msg
      result["candidates"].add node

proc recoverRoot*(repo: Repository; id: string): Snapshot =
  withRepoLock(repo.root, lmExclusive):
    let manifest = decodeManifest(repo.loadObject(id, okManifest))
    result = repo.publishSnapshot(manifest)
    require(result.reference.manifestId == id, ekCorrupt, "recovered root changed manifest identity")
