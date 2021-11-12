# Version 1 archive format

This document defines the persistent bytes. All integer fields in binary
records are unsigned little-endian unless explicitly identified as JSON signed
integers. No structure is serialized with host ABI casts.

Readers must reject unsupported versions, unknown required fields, invalid
lengths, trailing bytes, duplicate shard positions, nonzero reserved flags,
inconsistent geometry, and failed integrity checks.

## Content identity

An object ID is 64 lowercase hexadecimal characters:

```text
data_id     = hex(SHA256("cairn:1:data\0"     || original_bytes))
manifest_id = hex(SHA256("cairn:1:manifest\0" || canonical_manifest_bytes))
```

The terminator in each prefix is one zero byte. The strings contain no implicit
newline. Domain separation prevents identical data and manifest bytes from
sharing an identity.

File digests are ordinary `hex(SHA256(complete_file_bytes))`, without the object
prefix. An empty file has the standard SHA-256 empty-message digest and zero
chunk references.

Packet payload digests are ordinary SHA-256 over the shard's raw payload.
Reference and plan checksums use SHA-256 over their canonical JSON payload
before the checksum field is appended.

## Packet envelope

The fixed header is 172 bytes. The variable payload follows immediately.

| Offset | Bytes | Meaning |
|---:|---:|---|
| 0 | 8 | ASCII `CAIRN001` |
| 8 | 2 | Version, exactly 1 |
| 10 | 1 | Kind: 1 data, 2 manifest |
| 11 | 1 | Codec: 0 raw, 1 run encoding |
| 12 | 1 | Number of data shards k |
| 13 | 1 | Number of parity shards m |
| 14 | 1 | Shard position, 0 through k+m-1 |
| 15 | 1 | Reserved flags, exactly zero |
| 16 | 8 | Original uncompressed byte length |
| 24 | 8 | Encoded byte length before erasure coding |
| 32 | 8 | Shard payload byte length |
| 40 | 64 | Lowercase hexadecimal object ID, ASCII |
| 104 | 64 | Lowercase hexadecimal shard SHA-256, ASCII |
| 168 | 4 | CRC32C over bytes 0 through 167 |
| 172 | variable | Shard payload |

The actual file length must equal `172 + shard_length`. The shard width is
`ceil(encoded_length / k)`. Empty raw objects have zero-width payloads.

CRC32C uses the reflected Castagnoli polynomial `0x82f63b78`, initial state
`0xffffffff`, and final bitwise complement. Its known answer for ASCII
`123456789` is `e3069283`. Header CRC is checked before untrusted lengths are
used. It complements the independent content hashes rather than replacing them.

Capsule decoding proceeds in this order:

1. Bound the physical file length
2. Check header CRC32C, magic, version, type, geometry, and flags
3. Bound every declared length before allocating or slicing
4. Check exact payload length and shard SHA-256
5. Match object ID, position, geometry, codec, and lengths across packets
6. Require at least k distinct positions
7. Reconstruct encoded bytes and require zero padding
8. Re-encode and compare every supplied shard, including surplus parity
9. Decompress to the exact original length
10. Check the domain-separated object ID

A packet has no repository ID. Data capsules are portable between repositories
with compatible geometry. Repository identity belongs to configuration and
snapshot roots. Import does not accept conflicting packets for one ID/position.

## Erasure code

The field is GF(256), using polynomial `0x11d` and primitive element `0x02`.
Addition is XOR. The implementation uses log/exp tables, while the independent
reader constructs products by polynomial reduction.

For `n = k + m`, define an n by k Vandermonde matrix:

```text
V[row, col] = field_power(row, col)
row in [0, n), col in [0, k), and 0^0 = 1
G = V * inverse(V[0:k, 0:k])
```

The first k rows of G are the identity. Split the encoded byte stream into k
contiguous slices of equal width, padding only the last slice with zero bytes.
Each remaining row of G produces one parity shard by applying its coefficients
independently at each byte offset.

Any k distinct generator rows are invertible. Decoding selects k validated
shards, inverts those rows, and reconstructs the systematic data shards.
The original encoded length removes padding after the zero check.

## Compression

Codec 0 stores original bytes unchanged. Its original and encoded lengths must
match. Codec 1 uses the following tokens:

| Token value | Following bytes | Decoded output |
|---|---|---|
| 0..127 | token+1 literal bytes | Those literal bytes |
| 128..255 | One byte | Repeat that byte token-125 times |

Runs therefore have lengths 3 through 130. Literals have lengths 1 through 128.
The encoder emits a run when at least three identical bytes are available.
Otherwise it accumulates literals until the next run or the literal limit.
If the complete run encoding is not strictly shorter than the original bytes,
the encoder selects raw storage.

The decoder never trusts compression expansion. Every token must fit both the
encoded input and the exact expected output length. A compressed object must
have `encoded_length < original_length`.

This codec favors inspectability and repeated-byte data. It is not intended to
compete with general-purpose compressors on arbitrary scientific binary data.

## Content-defined boundaries

The gear table consists of 256 64-bit SplitMix64 outputs with initial state
`0x636169726e2d7631`. For each output, increment state by
`0x9e3779b97f4a7c15`, then apply:

```text
z = state
z = (z xor (z >> 30)) * 0xbf58476d1ce4e5b9
z = (z xor (z >> 27)) * 0x94d049bb133111eb
gear_entry = z xor (z >> 31)
```

All operations wrap modulo 2^64. This table generator is deterministic format
machinery, not a cryptographic random-number generator.

The chunk accumulator resets for each file and after each boundary. For bytes
before the configured minimum, the rolling value remains zero. Starting with
the byte that makes the chunk length equal to the minimum:

```text
rolling = (rolling << 1) + gear[byte], modulo 2^64
bits = log2(average)
mask = 2^(bits+1)-1 when length < average
mask = 2^(bits-1)-1 when length >= average
cut when length == maximum or (rolling & mask) == 0
```

The average must be a power of two. At end of file, emit a nonempty remainder
even if it is shorter than the minimum. An empty file emits no chunks.
Read-buffer partitioning must not change boundaries.

## Canonical JSON

Persistent JSON is UTF-8, compact, and has a fixed field order defined by its
encoder. Decoders validate types and fields, reconstruct the canonical form,
and require exact byte equality. Consequently duplicate keys, unknown fields,
whitespace variants, alternate numeric spellings, and reordered fields reject.

Numbers representing sizes and times are JSON integers. Floating point and
boolean values are not accepted in integer fields. Strings must be valid UTF-8
and cannot contain NUL. JSON nesting is capped at 16 before parsing.

### Configuration

Field order:

```json
{"version":1,"repository_id":"64 lowercase hex characters","data_shards":4,"parity_shards":2,"chunk_min":16384,"chunk_avg":65536,"chunk_max":262144}
```

The repository ID is SHA-256 over 32 bytes obtained from the operating system's
random source at initialization. It is an identity token, not a secret key.

A volume record is `{"volume":INDEX,"config":CONFIGURATION}`. Each volume
record must identify the same configuration and its actual position.

### Manifest

Top-level order: `version`, `label`, `created_ns`, `source`, `entries`.
Each entry has fields in this order:

```json
{"path":"sub/data","kind":"file","mode":384,"mtime_ns":1700000000000000000,"size":3,"sha256":"file digest","target":"","chunks":[{"id":"data object ID","length":3}]}
```

`kind` is `directory`, `file`, or `symlink`. Directory and symlink entries have
size zero, an empty digest, and no chunks. Directories have empty targets.
Symlinks have a confined relative target. Files have an empty target.

The first entry must be the root directory `.`. All paths are unique and sorted
by UTF-8 byte order. Every non-root entry has an earlier directory parent.
Every file size equals the sum of its positive chunk lengths. The mode contains
only ordinary permission bits, 0 through octal 0777.

Creation times are nonnegative nanoseconds since the Unix epoch. Entry mtimes
are signed int64 nanoseconds. Source acquisition rejects filesystem timestamps
that cannot be represented safely. `source` is a display name rather than an
absolute source path.

### Snapshot root

Payload order: `version`, `label`, `manifest_id`, `repository_id`. Append a
`checksum` field containing SHA-256 of the compact payload bytes. The filename
is the validated label followed by `.json`.

One surviving valid copy is sufficient. Conflicting valid copies fail closed,
even if one value has more replicas. Root repair copies the one agreed value.

### Maintenance plans

Repair and GC plans append a checksum to a fixed-order canonical payload.
Their checksums detect accidental edits; they are not signatures. Application
independently validates current repository state before mutation.

Repair actions contain object ID, kind, volume, before digest or `missing`,
replacement digest, and replacement byte length. GC plans contain the exact
current snapshot set, a digest over configuration/roots/physical packets, and
the complete list of unreachable object IDs and byte counts.

## Bundle format

A bundle starts with ASCII `CAIRNB01`, then a sequence of frames. Every frame
has an 81-byte header:

| Offset | Bytes | Meaning |
|---:|---:|---|
| 0 | 8 | ASCII `CAIRNFR1` |
| 8 | 1 | Kind: 1 configuration, 2 packet, 3 reference, 4 end |
| 9 | 8 | Payload length |
| 17 | 64 | Hexadecimal payload SHA-256 |
| 81 | variable | Payload |

The first frame is exactly one configuration. Packet frames contain complete
172-byte-header packet files. Reference frames contain a one-byte volume index
followed by canonical reference bytes.

For every non-end frame, append the following descriptor to a streaming
SHA-256 transcript: one-byte kind, eight-byte payload length, and 64 ASCII bytes
of the payload digest. The end-frame payload is the eight-byte count of
non-end frames followed by the 64-byte transcript digest.

Import requires an end frame, an exact transcript match, no trailing bytes,
at least one root, and a complete verified file graph for every imported root.
It rejects duplicate packet positions and reference copies. A private repository
is published only after the entire bundle passes.

## Hard limits

| Quantity | Version 1 bound |
|---|---:|
| Original or encoded object | 64 MiB |
| Canonical manifest | 64 MiB |
| Manifest entries | 250,000 |
| Total chunk references in one manifest | 1,000,000 |
| Path bytes | 4,096 |
| Path components | 128 |
| Label bytes | 80 |
| Data shards | 1..16 |
| Total shards | At most 32, with at least one parity shard |
| JSON nesting | 16 |
| Symbolic link expansions | 40 |

Changing a persistent rule requires a new explicit format version or a
backward-compatible reader decision. Do not silently reinterpret existing
capsules or rewrite snapshot identities during an implementation cleanup.
