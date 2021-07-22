## Format limits are checked before allocation. A manifest can describe many
## files, while a capsule intentionally stays small enough for bounded decode.
const
  FormatVersion* = 1
  MaxObjectBytes* = 64 * 1024 * 1024
  MaxManifestBytes* = 64 * 1024 * 1024
  MaxEntries* = 250_000
  MaxPathBytes* = 4096
  MaxDepth* = 128
  MaxShards* = 32
  MaxDataShards* = 16
  MaxLabelBytes* = 80
  DefaultMinChunk* = 16 * 1024
  DefaultAvgChunk* = 64 * 1024
  DefaultMaxChunk* = 256 * 1024
