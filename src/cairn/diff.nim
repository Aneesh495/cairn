## Snapshot comparison separates byte changes from metadata changes. A rename
## is inferred only for a unique removed/added content pair; ambiguous duplicate
## content stays explicit as additions and removals.
import std/[tables, algorithm, json]
import cairn/[manifest, snapshot]

type
  ChangeKind* = enum
    chAdded, chRemoved, chContent, chMetadata, chMoved
  Change* = object
    kind*: ChangeKind
    path*: string
    oldPath*: string
    beforeBytes*: int64
    afterBytes*: int64
  SnapshotDiff* = object
    before*: string
    after*: string
    changes*: seq[Change]

proc contentKey(entry: Entry): string =
  case entry.kind
  of enFile: "file:" & entry.digest & ":" & $entry.size
  of enSymlink: "link:" & entry.target
  of enDirectory: "directory"

proc contentEqual*(a, b: Entry): bool =
  a.kind == b.kind and a.contentKey == b.contentKey

proc compareSnapshots*(before, after: Snapshot; detectMoves = true): SnapshotDiff =
  result.before = before.manifest.label
  result.after = after.manifest.label
  var old = initTable[string, Entry]()
  var new = initTable[string, Entry]()
  for entry in before.manifest.entries: old[entry.path] = entry
  for entry in after.manifest.entries: new[entry.path] = entry
  var removed = initTable[string, seq[Entry]]()
  var added = initTable[string, seq[Entry]]()
  for entry in before.manifest.entries:
    if not new.hasKey(entry.path):
      removed.mgetOrPut(entry.contentKey, @[]).add entry
    else:
      let current = new[entry.path]
      if not contentEqual(entry, current):
        result.changes.add Change(kind: chContent, path: entry.path,
          beforeBytes: entry.size, afterBytes: current.size)
      elif entry.mode != current.mode or entry.mtimeNs != current.mtimeNs:
        result.changes.add Change(kind: chMetadata, path: entry.path,
          beforeBytes: entry.size, afterBytes: current.size)
  for entry in after.manifest.entries:
    if not old.hasKey(entry.path): added.mgetOrPut(entry.contentKey, @[]).add entry
  for key, entries in removed:
    if detectMoves and entries.len == 1 and entries[0].kind != enDirectory and
       added.hasKey(key) and added[key].len == 1:
      result.changes.add Change(kind: chMoved, path: added[key][0].path,
        oldPath: entries[0].path, beforeBytes: entries[0].size, afterBytes: added[key][0].size)
      added.del key
    else:
      for entry in entries:
        result.changes.add Change(kind: chRemoved, path: entry.path, beforeBytes: entry.size)
  for key, entries in added:
    discard key
    for entry in entries:
      result.changes.add Change(kind: chAdded, path: entry.path, afterBytes: entry.size)
  result.changes.sort(proc(a, b: Change): int =
    result = cmp(a.path, b.path)
    if result == 0: result = cmp(ord(a.kind), ord(b.kind)))

proc toJson*(diff: SnapshotDiff): JsonNode =
  result = %*{"before": diff.before, "after": diff.after, "changes": []}
  for change in diff.changes:
    result["changes"].add %*{"kind": $change.kind, "path": change.path,
      "old_path": change.oldPath, "before_bytes": change.beforeBytes,
      "after_bytes": change.afterBytes}
