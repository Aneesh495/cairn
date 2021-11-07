## Deterministic randomized campaigns, separate from example-based suites.
## Counts describe actual executed cases and are emitted as machine-readable
## evidence. No workload is shortened when a phase is slow or fails.
import std/[json, times]
import cairn/[capsule, compression, erasure, errors, manifest, prng, sha256]

type Counters = object
  erasureCases: int
  erasureBytes: int64
  packetCorruptions: int
  packetFuzzInputs: int
  compressionRoundTrips: int
  compressionFuzzInputs: int
  metadataMutations: int
  acceptedMetadataMutations: int

proc expectRejected(body: proc() {.closure.}) =
  var rejected = false
  try: body()
  except CairnError: rejected = true
  doAssert rejected, "a malformed input was unexpectedly accepted"

proc main() =
  let started = cpuTime()
  var rng = Prng(state: 0xca17ca17'u64)
  var counters: Counters
  for trial in 0..<3000:
    let k = rng.bounded(16)+1
    let m = rng.bounded(min(8, 32-k))+1
    let code = initCode(Geometry(data: k, parity: m))
    let bytes = rng.bytes(rng.bounded(8193))
    var shards = code.encode(bytes)
    rng.shuffle(shards)
    shards.setLen(k)
    doAssert code.decode(shards, bytes.len) == bytes
    inc counters.erasureCases
    counters.erasureBytes += int64(bytes.len)
  for trial in 0..<10000:
    let bytes = if trial mod 3 == 0: rng.bytes(32) & newString(rng.bounded(1000))
                else: rng.bytes(rng.bounded(2049))
    let compressed = compress(bytes)
    doAssert decompress(compressed.codec, compressed.bytes, bytes.len) == bytes
    doAssert decodeRuns(encodeRuns(bytes), bytes.len) == bytes
    inc counters.compressionRoundTrips
  for trial in 0..<10000:
    let data = rng.bytes(rng.bounded(1024))
    try:
      let expected = rng.bounded(2048)
      let decoded = decodeRuns(data, expected)
      doAssert decoded.len == expected
    except CairnError: discard
    inc counters.compressionFuzzInputs
  for trial in 0..<5000:
    let packets = makePackets(okData, rng.bytes(rng.bounded(2048)+1), Geometry(data: 3, parity: 2))
    var bytes = packets[rng.bounded(packets.len)].serialize
    let at = rng.bounded(bytes.len)
    bytes[at] = char(uint8(bytes[at]) xor (1'u8 shl rng.bounded(8)))
    expectRejected(proc() = discard parsePacket(bytes))
    inc counters.packetCorruptions
  for trial in 0..<10000:
    let input = rng.bytes(rng.bounded(2048))
    try:
      let parsed = parsePacket(input)
      doAssert parsePacket(parsed.serialize) == parsed
    except CairnError: discard
    inc counters.packetFuzzInputs
  let model = Manifest(label: "campaign", createdNs: 1, source: "fixture", entries: @[
    Entry(path: ".", kind: enDirectory, mode: 0o700),
    Entry(path: "empty", kind: enFile, mode: 0o600, digest: sha256(""))])
  let canonical = model.encodeManifest
  for trial in 0..<10000:
    var mutation = canonical
    let at = rng.bounded(mutation.len)
    mutation[at] = char(rng.bounded(256))
    try:
      let parsed = decodeManifest(mutation)
      doAssert parsed.encodeManifest == mutation
      inc counters.acceptedMetadataMutations
    except CairnError: discard
    inc counters.metadataMutations
  echo $(%*{"seed": "ca17ca17", "erasure_cases": counters.erasureCases,
    "erasure_payload_bytes": counters.erasureBytes,
    "packet_single_bit_corruptions": counters.packetCorruptions,
    "packet_fuzz_inputs": counters.packetFuzzInputs,
    "compression_round_trips": counters.compressionRoundTrips,
    "compression_fuzz_inputs": counters.compressionFuzzInputs,
    "metadata_mutations": counters.metadataMutations,
    "valid_canonical_metadata_mutations": counters.acceptedMetadataMutations,
    "cpu_seconds": cpuTime()-started})

when isMainModule: main()
