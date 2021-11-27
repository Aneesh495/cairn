import std/[unittest, os, tempfiles, json]
import cairn/[repository, config, chunker, erasure, errors]

suite "repository creation and volume identity":
  test "all lookup helpers reject positions outside configured volumes":
    let root = createTempDir("cairn-repo-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    for position in [-1, 6]:
      expect CairnError: discard repo.packetPath(repo.config.repositoryId, position)
      expect CairnError: discard repo.referencePath("sample", position)
  test "configuration is replicated and immutable":
    let root = createTempDir("cairn-repo-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    check openRepository(repo.root) == repo
    check repo.config.geometry == Geometry(data: 4, parity: 2)
    check repo.config.chunks == DefaultChunks
    for index in 0..<6:
      check repo.verifyVolume(index)
      let volume = decodeVolume(readFile(repo.volumePath(index) / "volume.json"))
      check volume.config == repo.config
      check volume.index == index
    expect CairnError: discard initialize(root / "archive")
  test "missing volumes are recognizable and can be initialized for repair":
    let root = createTempDir("cairn-repo-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive", Geometry(data: 2, parity: 1))
    removeDir(repo.volumePath(1))
    check not repo.verifyVolume(1)
    repo.ensureVolume(1)
    check repo.verifyVolume(1)
  test "a foreign volume is rejected":
    let root = createTempDir("cairn-repo-", "")
    defer: removeDir(root)
    let a = initialize(root / "a")
    let b = initialize(root / "b")
    writeFile(a.volumePath(0) / "volume.json", encodeVolume(b.config, 0))
    expect CairnError: discard a.verifyVolume(0)
  test "configuration schema rejects extra fields":
    let root = createTempDir("cairn-repo-", "")
    defer: removeDir(root)
    let repo = initialize(root / "archive")
    var node = repo.config.toJson
    node["unused"] = %1
    expect CairnError: discard decodeConfig($node)
