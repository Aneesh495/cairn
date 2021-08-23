## Configuration is replicated into every volume. An archive can be assembled
## after losing its top-level directory, provided enough volume content and a
## valid snapshot reference survive.
import std/json
import cairn/[chunker, erasure, errors, limits, schema, sha256]

type Config* = object
  repositoryId*: string
  geometry*: Geometry
  chunks*: ChunkConfig

proc validate*(config: Config) =
  require(validId(config.repositoryId), ekCorrupt, "invalid repository ID")
  config.geometry.validate
  config.chunks.validate

proc toJson*(config: Config): JsonNode =
  %*{"version": FormatVersion, "repository_id": config.repositoryId,
    "data_shards": config.geometry.data, "parity_shards": config.geometry.parity,
    "chunk_min": config.chunks.minimum, "chunk_avg": config.chunks.average,
    "chunk_max": config.chunks.maximum}

proc encodeConfig*(config: Config): string =
  config.validate
  $config.toJson

proc decodeConfig*(bytes: string): Config =
  let node = parseBounded(bytes, 4096)
  node.fields(["version", "repository_id", "data_shards", "parity_shards",
               "chunk_min", "chunk_avg", "chunk_max"])
  discard node.intField("version", FormatVersion, FormatVersion)
  result = Config(repositoryId: node.stringField("repository_id", 64),
    geometry: Geometry(data: int(node.intField("data_shards", 1, MaxDataShards)),
      parity: int(node.intField("parity_shards", 1, MaxShards))),
    chunks: ChunkConfig(minimum: int(node.intField("chunk_min", 64, MaxObjectBytes)),
      average: int(node.intField("chunk_avg", 64, MaxObjectBytes)),
      maximum: int(node.intField("chunk_max", 64, MaxObjectBytes))))
  result.validate
  canonical(bytes, result.encodeConfig)

proc encodeVolume*(config: Config; index: int): string =
  config.validate
  require(index >= 0 and index < config.geometry.total, ekInvalid, "invalid volume number")
  $(%*{"volume": index, "config": config.toJson})

proc decodeVolume*(bytes: string): tuple[config: Config, index: int] =
  let node = parseBounded(bytes, 4096)
  node.fields(["volume", "config"])
  result.config = decodeConfig($node["config"])
  result.index = int(node.intField("volume", 0, result.config.geometry.total-1))
  canonical(bytes, encodeVolume(result.config, result.index))
