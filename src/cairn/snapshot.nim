## Snapshot publication orders immutable content before replicated roots. A
## crash before root publication leaves collectible orphans; a crash after the
## first root publication leaves a complete, readable snapshot.
import cairn/[capsule, durable, errors, manifest, references, repository, sha256, store]

type Snapshot* = object
  reference*: Reference
  manifest*: Manifest

proc loadSnapshot*(repo: Repository; label: string): Snapshot =
  let read = repo.readReference(label)
  result.reference = read.reference
  result.manifest = decodeManifest(repo.loadObject(read.reference.manifestId, okManifest))
  require(result.manifest.label == label, ekCorrupt, "snapshot manifest label differs from root")

proc verifyContent*(repo: Repository; manifest: Manifest) =
  manifest.validate
  for entry in manifest.entries:
    if entry.kind != enFile: continue
    var digest = initSha256()
    for chunk in entry.chunks:
      let bytes = repo.loadObject(chunk.id, okData)
      require(bytes.len == chunk.length, ekCorrupt, "chunk reference length mismatch")
      digest.update(bytes)
    require(digest.digest == entry.digest, ekCorrupt,
            "file digest does not match the content graph: " & entry.path)

proc publishSnapshot*(repo: Repository; manifest: Manifest): Snapshot =
  repo.assertNewLabel(manifest.label)
  repo.verifyContent(manifest)
  let stored = repo.storeObject(okManifest, manifest.encodeManifest)
  crashPoint("manifest-stored")
  let reference = Reference(label: manifest.label, manifestId: stored.id,
    repositoryId: repo.config.repositoryId)
  repo.publishReference(reference)
  Snapshot(reference: reference, manifest: manifest)
