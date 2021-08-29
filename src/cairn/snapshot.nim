## Snapshot publication orders immutable content before replicated roots. A
## crash before root publication leaves collectible orphans; a crash after the
## first root publication leaves a complete, readable snapshot.
import cairn/[capsule, durable, errors, manifest, references, repository, store]

type Snapshot* = object
  reference*: Reference
  manifest*: Manifest

proc loadSnapshot*(repo: Repository; label: string): Snapshot =
  let read = repo.readReference(label)
  result.reference = read.reference
  result.manifest = decodeManifest(repo.loadObject(read.reference.manifestId, okManifest))
  require(result.manifest.label == label, ekCorrupt, "snapshot manifest label differs from root")

proc publishSnapshot*(repo: Repository; manifest: Manifest): Snapshot =
  repo.assertNewLabel(manifest.label)
  let stored = repo.storeObject(okManifest, manifest.encodeManifest)
  crashPoint("manifest-stored")
  let reference = Reference(label: manifest.label, manifestId: stored.id,
    repositoryId: repo.config.repositoryId)
  repo.publishReference(reference)
  Snapshot(reference: reference, manifest: manifest)
