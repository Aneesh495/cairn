## Storage accounting distinguishes logical bytes, uniqueBytes referenced chunk
## bytes, and physical packet bytes, including redundancy and header overhead.
## Unreadable manifests are reported instead of contributing invented zeros.
import std/[tables, json]
import cairn/[capsule, erasure, errors, locking, manifest, references,
  repository, snapshot, store]

proc repositoryStats*(repo: Repository): JsonNode =
  withRepoLock(repo.root, lmShared):
    var logical = 0'i64
    var files = 0
    var readable = 0
    var chunks = initTable[string, int]()
    var unreadable: seq[string]
    var roots = newJArray()
    for label in repo.referenceLabels:
      try:
        let read = repo.readReference(label)
        let snapshot = repo.loadSnapshot(label)
        logical += snapshot.manifest.logicalBytes
        files += snapshot.manifest.fileCount
        for entry in snapshot.manifest.entries:
          for chunk in entry.chunks:
            if chunks.hasKey(chunk.id):
              require(chunks[chunk.id] == chunk.length, ekCorrupt, "conflicting chunk length across snapshots")
            chunks[chunk.id] = chunk.length
        roots.add %*{"label": label, "manifest_id": read.reference.manifestId,
          "valid_copies": read.validCopies, "bad_copies": read.badCopies,
          "missing_copies": read.missingCopies}
        inc readable
      except CairnError as error:
        unreadable.add label
        roots.add %*{"label": label, "error": error.msg}
    var uniqueBytes = 0'i64
    for length in chunks.values: uniqueBytes += int64(length)
    let ids = repo.objectIds
    var physical = 0'i64
    var good = 0
    var missing = 0
    var corrupt = 0
    var unidentified: seq[string]
    for id in ids:
      var kind: ObjectKind
      try: kind = repo.discoverKind(id)
      except CairnError:
        unidentified.add id
        continue
      let read = repo.readPackets(id, kind)
      for slot in read.slots:
        physical += slot.bytes
        case slot.state
        of psGood: inc good
        of psMissing: inc missing
        of psCorrupt: inc corrupt
    var present: seq[int]
    var absent: seq[int]
    for index in 0..<repo.config.geometry.total:
      if repo.verifyVolume(index): present.add index
      else: absent.add index
    result = %*{"repository_id": repo.config.repositoryId, "readable_snapshots": readable,
      "unreadable_snapshots": unreadable, "accounting_complete": unreadable.len == 0 and unidentified.len == 0,
      "logical_bytes_readable_snapshots": logical, "file_versions": files,
      "distinct_referenced_chunk_bytes": uniqueBytes, "distinct_referenced_chunks": chunks.len,
      "discovered_objects": ids.len, "validated_packet_bytes": physical,
      "good_packets": good, "missing_packets": missing, "corrupt_packets": corrupt,
      "unidentified_objects": unidentified, "present_volumes": present, "absent_volumes": absent,
      "references": roots}
    result["logical_to_distinct_ratio"] = if uniqueBytes > 0: %(float64(logical)/float64(uniqueBytes)) else: newJNull()
