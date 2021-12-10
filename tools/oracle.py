#!/usr/bin/env python3
"""Independent version-1 archive decoder using only Python's standard library.

This reader does not call Cairn and does not import generated Nim output. It
uses polynomial field arithmetic, independent matrix inversion, hashlib, and
its own capsule, compression, path, and chunk-boundary implementations.
"""
from __future__ import annotations
import argparse
import hashlib
import itertools
import json
import pathlib
import re
import struct
from collections import defaultdict
from functools import lru_cache

MAX_OBJECT = 64 * 1024 * 1024
HEADER = 172
ID = re.compile(r'[0-9a-f]{64}\Z')


def need(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def content_id(kind, data):
    return digest(b'cairn:1:' + kind.encode() + b'\0' + data)


def compact(node):
    return json.dumps(node, ensure_ascii=False, separators=(',', ':'))


def crc32c(data):
    value = 0xffffffff
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0x82f63b78 if value & 1 else 0)
    return value ^ 0xffffffff


def gf_mul(a, b):
    answer = 0
    while b:
        if b & 1:
            answer ^= a
        a <<= 1
        if a & 256:
            a ^= 0x11d
        b >>= 1
    return answer


MULT = tuple(bytes(gf_mul(a, b) for a in range(256)) for b in range(256))


def gf_power(a, n):
    answer = 1
    for _ in range(n):
        answer = gf_mul(answer, a)
    return answer


def inverse(matrix):
    n = len(matrix)
    rows = [list(row) + [int(i == j) for j in range(n)] for i, row in enumerate(matrix)]
    for pivot in range(n):
        chosen = next((r for r in range(pivot, n) if rows[r][pivot]), None)
        need(chosen is not None, 'singular coding matrix')
        rows[pivot], rows[chosen] = rows[chosen], rows[pivot]
        scale = gf_power(rows[pivot][pivot], 254)
        rows[pivot] = [gf_mul(v, scale) for v in rows[pivot]]
        for r in range(n):
            if r == pivot:
                continue
            coefficient = rows[r][pivot]
            rows[r] = [a ^ gf_mul(coefficient, b) for a, b in zip(rows[r], rows[pivot])]
    return [row[n:] for row in rows]


@lru_cache(maxsize=512)
def generator(k, m):
    vandermonde = [[gf_power(row, col) for col in range(k)] for row in range(k + m)]
    inv = inverse(vandermonde[:k])
    return [[xor_all(gf_mul(row[t], inv[t][c]) for t in range(k)) for c in range(k)] for row in vandermonde]


def xor_all(values):
    answer = 0
    for value in values:
        answer ^= value
    return answer


def parse_packet(raw):
    need(HEADER <= len(raw) <= HEADER + MAX_OBJECT, 'packet size')
    need(raw[:8] == b'CAIRN001', 'packet magic')
    version, kind, codec, k, m, index, flags = struct.unpack_from('<HBBBBBB', raw, 8)
    original, encoded, width = struct.unpack_from('<QQQ', raw, 16)
    oid = raw[40:104].decode('ascii')
    sha = raw[104:168].decode('ascii')
    checksum, = struct.unpack_from('<I', raw, 168)
    need(checksum == crc32c(raw[:168]), 'header CRC32C')
    need(version == 1 and kind in (1, 2) and codec in (0, 1) and flags == 0, 'packet type')
    need(1 <= k <= 16 and 1 <= m and k + m <= 32 and index < k + m, 'coding geometry')
    need(original <= MAX_OBJECT and encoded <= MAX_OBJECT, 'object bounds')
    need(width == (encoded + k - 1) // k and len(raw) == HEADER + width, 'packet width')
    need(ID.fullmatch(oid) and ID.fullmatch(sha), 'packet digest syntax')
    need(digest(raw[HEADER:]) == sha, 'packet payload SHA-256')
    need((codec == 0 and original == encoded) or (codec == 1 and encoded < original), 'codec lengths')
    return dict(id=oid, kind='data' if kind == 1 else 'manifest', codec=codec,
                k=k, m=m, index=index, original=original, encoded=encoded, payload=raw[HEADER:])


def decompress(codec, data, expected):
    if codec == 0:
        need(len(data) == expected, 'raw length')
        return data
    output = bytearray()
    at = 0
    while at < len(data):
        token = data[at]
        at += 1
        if token >= 128:
            count = token - 125
            need(at < len(data) and len(output) + count <= expected, 'compressed run')
            output.extend(data[at:at + 1] * count)
            at += 1
        else:
            count = token + 1
            need(at + count <= len(data) and len(output) + count <= expected, 'compressed literal')
            output.extend(data[at:at + count])
            at += count
    need(len(output) == expected, 'decompressed length')
    return bytes(output)


def recover(packets):
    first = packets[0]
    k, m = first['k'], first['m']
    need(len(packets) >= k, 'insufficient shards')
    chosen = packets[:k]
    need(len({p['index'] for p in chosen}) == k, 'duplicate shard')
    for packet in chosen:
        need(all(packet[key] == first[key] for key in ('id', 'kind', 'codec', 'k', 'm', 'original', 'encoded')), 'mixed object')
    matrix = generator(k, m)
    inv = inverse([matrix[p['index']] for p in chosen])
    width = len(first['payload'])
    decoded = []
    for coefficients in inv:
        # Translate performs field multiplication bytewise. Integer XOR is an
        # independent vector combine implemented by Python's own bigint code.
        value = 0
        for coefficient, packet in zip(coefficients, chosen):
            value ^= int.from_bytes(packet['payload'].translate(MULT[coefficient]), 'little')
        decoded.append(value.to_bytes(width, 'little'))
    padded = b''.join(decoded)
    need(not any(padded[first['encoded']:]), 'nonzero coding padding')
    data = decompress(first['codec'], padded[:first['encoded']], first['original'])
    need(content_id(first['kind'], data) == first['id'], 'decoded object identity')
    return data


def validate_path(path, root=False):
    if root and path == '.':
        return
    need(0 < len(path.encode('utf-8')) <= 4096, 'path size')
    need(not path.startswith('/') and '\\' not in path and ':' not in path and '\0' not in path, 'unsafe path')
    parts = path.split('/')
    need(len(parts) <= 128 and all(p not in ('', '.', '..') for p in parts), 'path components')


def decode_reference(raw, repository_id):
    node = json.loads(raw)
    checksum = node.pop('checksum')
    need(set(node) == {'version', 'label', 'manifest_id', 'repository_id'}, 'reference fields')
    need(node['version'] == 1 and node['repository_id'] == repository_id, 'reference identity')
    need(checksum == digest(compact(node).encode()), 'reference checksum')
    need(re.fullmatch(r'[A-Za-z0-9_-]{1,80}', node['label']), 'reference label')
    need(ID.fullmatch(node['manifest_id']), 'reference manifest digest')
    return node


@lru_cache(maxsize=1)
def gear_table():
    state = 0x636169726e2d7631
    mask = (1 << 64) - 1
    result = []
    for _ in range(256):
        state = (state + 0x9e3779b97f4a7c15) & mask
        z = state
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & mask
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & mask
        result.append(z ^ (z >> 31))
    return result


def chunk_bytes(data, config):
    minimum, average, maximum = (config['chunk_' + part] for part in ('min', 'avg', 'max'))
    bits = average.bit_length() - 1
    rolling = 0
    start = 0
    gear = gear_table()
    for at, byte in enumerate(data):
        length = at - start + 1
        if length < minimum:
            continue
        rolling = ((rolling << 1) + gear[byte]) & ((1 << 64) - 1)
        mask = (1 << (bits + 1 if length < average else bits - 1)) - 1
        if length == maximum or rolling & mask == 0:
            yield data[start:at + 1]
            start = at + 1
            rolling = 0
    if start < len(data):
        yield data[start:]


def inspect_archive(root, restored=None, label=None, exhaustive=False):
    root = pathlib.Path(root)
    config = json.loads((root / 'config.json').read_bytes())
    packets = defaultdict(dict)
    bad = []
    reference_copies = defaultdict(list)
    for volume in sorted((root / 'volumes').iterdir()):
        if not volume.is_dir() or volume.is_symlink():
            continue
        metadata = json.loads((volume / 'volume.json').read_bytes())
        need(metadata['config'] == config, 'volume configuration')
        index = metadata['volume']
        for path in sorted(volume.rglob('*.cap')):
            need(not path.is_symlink(), 'symlink packet')
            try:
                packet = parse_packet(path.read_bytes())
                need(packet['index'] == index, 'packet volume placement')
                need((packet['k'], packet['m']) == (config['data_shards'], config['parity_shards']), 'packet config geometry')
                need(path.stem == packet['id'] and path.parent.name == packet['id'][:2], 'packet path identity')
                packets[packet['id']][index] = packet
            except (ValueError, UnicodeError, struct.error) as error:
                bad.append({'path': str(path.relative_to(root)), 'error': str(error)})
        for path in sorted((volume / 'refs').glob('*.json')):
            reference = decode_reference(path.read_bytes(), config['repository_id'])
            need(path.stem == reference['label'], 'reference filename')
            reference_copies[reference['label']].append(reference)
    cache = {}
    subset_checks = 0
    def load(oid, kind):
        nonlocal subset_checks
        if oid in cache:
            need(content_id(kind, cache[oid]) == oid, 'object domain')
            return cache[oid]
        available = list(packets[oid].values())
        need(available, 'object has no packets: ' + oid)
        need(available[0]['kind'] == kind, 'object kind')
        k = available[0]['k']
        data = recover(available)
        subsets = itertools.combinations(available, k) if exhaustive else [available[-k:]]
        for selected in subsets:
            need(recover(list(selected)) == data, 'subset reconstruction disagreement')
            subset_checks += 1
        cache[oid] = data
        return data
    snapshots = {}
    file_versions = 0
    logical_bytes = 0
    chunk_boundary_checks = 0
    for name, copies in sorted(reference_copies.items()):
        need(all(copy == copies[0] for copy in copies), 'conflicting snapshot roots')
        if label is not None and name != label:
            continue
        manifest = json.loads(load(copies[0]['manifest_id'], 'manifest'))
        need(manifest['label'] == name and manifest['version'] == 1, 'manifest identity')
        paths = {}
        previous = ''
        files = {}
        for entry in manifest['entries']:
            path = entry['path']
            validate_path(path, root=True)
            need(path > previous, 'manifest ordering')
            previous = path
            if path != '.':
                parent = path.rsplit('/', 1)[0] if '/' in path else '.'
                need(paths.get(parent) == 'directory', 'manifest parent')
            paths[path] = entry['kind']
            if entry['kind'] != 'file':
                continue
            data = b''.join(load(chunk['id'], 'data') for chunk in entry['chunks'])
            need(len(data) == entry['size'] and digest(data) == entry['sha256'], 'file digest')
            expected = [(content_id('data', chunk), len(chunk)) for chunk in chunk_bytes(data, config)]
            actual = [(chunk['id'], chunk['length']) for chunk in entry['chunks']]
            need(expected == actual, 'independent content-defined boundaries')
            chunk_boundary_checks += 1
            file_versions += 1
            logical_bytes += len(data)
            files[path] = data
            if restored is not None:
                target = pathlib.Path(restored).joinpath(*path.split('/'))
                need(not target.is_symlink() and target.read_bytes() == data, 'restored file bytes')
                need(target.stat().st_mode & 0o777 == entry['mode'], 'restored permissions')
                need(target.stat().st_mtime_ns == entry['mtime_ns'], 'restored nanosecond mtime')
        snapshots[name] = {'manifest_id': copies[0]['manifest_id'], 'files': len(files), 'reference_copies': len(copies)}
    if label is not None:
        need(label in snapshots, 'requested snapshot not found')
    return {'snapshots': snapshots, 'decoded_objects': len(cache), 'subset_checks': subset_checks,
            'file_versions': file_versions, 'logical_bytes': logical_bytes,
            'independent_boundary_checks': chunk_boundary_checks, 'invalid_packets': bad}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository')
    parser.add_argument('--restored')
    parser.add_argument('--label')
    parser.add_argument('--exhaustive', action='store_true')
    args = parser.parse_args()
    print(json.dumps(inspect_archive(args.repository, args.restored, args.label, args.exhaustive), indent=2))


if __name__ == '__main__':
    main()
