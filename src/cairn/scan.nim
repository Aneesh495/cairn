## Index-free capsule discovery. Only regular .cap files are interpreted as
## packets, and payload validation is mandatory. Filenames and bucket paths
## have no authority here, so detached or renamed packets can be identified.
import std/[os, strutils, algorithm, json]
import cairn/[capsule, durable, errors, limits]

type
  LocatedPacket* = object
    path*: string
    id*: string
    kind*: ObjectKind
    index*: int
    dataShards*: int
    parityShards*: int
    originalBytes*: int
    fileBytes*: int
  ScanError* = object
    path*: string
    reason*: string
  ScanReport* = object
    packets*: seq[LocatedPacket]
    errors*: seq[ScanError]
    visitedFiles*: int

proc scanCapsules*(root: string; maximumFiles = 1_000_000): ScanReport =
  require(dirExists(root) and not symlinkExists(root), ekInvalid, "scan root must be a real directory")
  require(maximumFiles > 0, ekInvalid, "scan file limit must be positive")
  var report: ScanReport
  proc visit(path: string; depth: int) =
    require(depth <= MaxDepth, ekLimit, "capsule scan exceeds directory depth limit")
    var children: seq[tuple[kind: PathComponent, path: string]]
    for kind, child in walkDir(path): children.add (kind, child)
    children.sort(proc(a, b: tuple[kind: PathComponent, path: string]): int = cmp(a.path, b.path))
    for (kind, child) in children:
      case kind
      of pcDir: visit(child, depth+1)
      of pcFile:
        inc report.visitedFiles
        require(report.visitedFiles <= maximumFiles, ekLimit, "capsule scan exceeds file limit")
        if not child.endsWith(".cap"): continue
        try:
          let bytes = readBounded(child, HeaderBytes + MaxObjectBytes)
          let packet = parsePacket(bytes)
          report.packets.add LocatedPacket(path: child, id: packet.id, kind: packet.kind,
            index: packet.index, dataShards: packet.geometry.data, parityShards: packet.geometry.parity,
            originalBytes: packet.originalLength, fileBytes: bytes.len)
        except CairnError as error:
          report.errors.add ScanError(path: child, reason: error.msg)
      of pcLinkToFile, pcLinkToDir:
        report.errors.add ScanError(path: child, reason: "symbolic link skipped")
  visit(expandFilename(root), 0)
  report

proc toJson*(report: ScanReport): JsonNode =
  result = %*{"visited_files": report.visitedFiles, "valid_packets": report.packets.len,
    "packets": [], "errors": []}
  for packet in report.packets:
    result["packets"].add %*{"path": packet.path, "id": packet.id, "kind": packet.kind.domain,
      "volume": packet.index, "data_shards": packet.dataShards, "parity_shards": packet.parityShards,
      "original_bytes": packet.originalBytes, "file_bytes": packet.fileBytes}
  for error in report.errors: result["errors"].add %*{"path": error.path, "reason": error.reason}
