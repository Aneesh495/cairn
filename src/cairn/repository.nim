## Repository layout and creation. Config publication is the initialization
## commit point. No object or reference name comes from unchecked input.
import std/[os, strutils, sysrand]
import cairn/[config, chunker, durable, erasure, errors, paths, sha256]

type Repository* = object
  root*: string
  config*: Config

proc volumeRelative*(index: int): string = "volumes/" & align($index, 2, '0')

proc volumePath*(repo: Repository; index: int): string =
  require(index >= 0 and index < repo.config.geometry.total,
          ekInvalid, "invalid repository volume index")
  managedPath(repo.root, volumeRelative(index))

proc packetPath*(repo: Repository; id: string; index: int): string =
  require(validId(id), ekInvalid, "invalid object lookup ID")
  managedPath(repo.root, volumeRelative(index) & "/objects/" & id[0..1] & "/" & id & ".cap")

proc referencePath*(repo: Repository; label: string; index: int): string =
  label.validateLabel
  managedPath(repo.root, volumeRelative(index) & "/refs/" & label & ".json")

proc openRepository*(root: string): Repository =
  require(dirExists(root), ekMissing, "repository directory does not exist: " & root)
  result.root = expandFilename(root)
  result.config = decodeConfig(readBounded(managedPath(result.root, "config.json"), 4096))
  require(fileExists(managedPath(result.root, ".lock")), ekCorrupt, "repository lock file is missing")

proc initializeWithConfig*(root: string; config: Config): Repository =
  config.validate
  let absolute = absolutePath(root).normalizedPath
  require(not existsAny(absolute), ekConflict, "repository destination already exists: " & absolute)
  require(dirExists(parentDir(absolute)), ekMissing, "repository parent must exist")
  ensureDirectory(absolute)
  result.root = expandFilename(absolute)
  result.config = config
  writeAtomic(result.root / ".lock", "")
  ensureDirectory(result.root / "volumes")
  for index in 0..<config.geometry.total:
    let volume = result.volumePath(index)
    ensureDirectory(volume)
    ensureDirectory(volume / "objects")
    ensureDirectory(volume / "refs")
    writeAtomic(volume / "volume.json", encodeVolume(result.config, index))
  crashPoint("init-volumes")
  writeAtomic(result.root / "config.json", result.config.encodeConfig)
  crashPoint("init-published")

proc initialize*(root: string; geometry = Geometry(data: 4, parity: 2);
                 chunks = DefaultChunks): Repository =
  geometry.validate
  chunks.validate
  var entropy = ""
  for byte in urandom(32): entropy.add char(byte)
  initializeWithConfig(root, Config(repositoryId: sha256(entropy), geometry: geometry, chunks: chunks))

proc verifyVolume*(repo: Repository; index: int): bool =
  let volume = repo.volumePath(index)
  if not dirExists(volume): return false
  let metadata = decodeVolume(readBounded(managedPath(repo.root,
    volumeRelative(index) & "/volume.json"), 4096))
  require(metadata.config == repo.config and metadata.index == index,
          ekCorrupt, "volume belongs to a different repository or position")
  true

proc ensureVolume*(repo: Repository; index: int) =
  if repo.verifyVolume(index): return
  let volume = repo.volumePath(index)
  ensureDirectory(volume)
  ensureDirectory(volume / "objects")
  ensureDirectory(volume / "refs")
  writeAtomic(volume / "volume.json", encodeVolume(repo.config, index))
