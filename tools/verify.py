#!/usr/bin/env python3
"""Real-process acceptance, physical damage, crash recovery, and independent decoding.

All fixtures are synthetic. Only paths owned by this process are modified.
Raw command outputs and a machine-readable report land in build/evidence.
A failed command or invariant stops acceptance and preserves its evidence.
"""
from __future__ import annotations
import fcntl
import hashlib
import itertools
import json
import os
import pathlib
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tarfile
from source_state import source_manifest as bound_source_manifest
from oracle import inspect_archive, parse_packet, crc32c

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / 'bin' / 'cairn'
EVIDENCE = ROOT / 'build' / 'evidence'
EVIDENCE.mkdir(parents=True, exist_ok=True)
COMMANDS = EVIDENCE / 'commands'
COMMANDS.mkdir(exist_ok=True)
LOG = []
COUNTS = dict(commands=0, volume_loss_cases=0, crash_cases=0, independent_decodes=0,
              independent_subset_checks=0, negative_controls=0)
START = time.monotonic()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def need(condition, message):
    if not condition:
        raise AssertionError(message)


def source_manifest():
    return bound_source_manifest(ROOT)


def invoke(*args, expected=0, env=None, timeout=60, cwd=None):
    command = [str(BIN), *map(str, args)]
    started = time.monotonic()
    process = subprocess.run(command, capture_output=True, env=env, timeout=timeout, cwd=cwd)
    index = len(LOG)
    (COMMANDS / f'{index:04d}.stdout').write_bytes(process.stdout)
    (COMMANDS / f'{index:04d}.stderr').write_bytes(process.stderr)
    entry = dict(command=command[1:], cwd=str(cwd) if cwd is not None else None, exit=process.returncode,
                 seconds=time.monotonic()-started, stdout_sha256=sha(process.stdout),
                 stderr_sha256=sha(process.stderr))
    LOG.append(entry)
    COUNTS['commands'] += 1
    (EVIDENCE / 'commands.json').write_text(json.dumps(LOG, indent=2))
    allowed = (expected,) if isinstance(expected, int) else expected
    need(process.returncode in allowed,
         f'{args[0]} exited {process.returncode}, expected {allowed}: {process.stderr.decode(errors="replace")}')
    if process.stdout:
        return json.loads(process.stdout)
    return None


def independent(repo, label, restored=None, exhaustive=False):
    report = inspect_archive(repo, restored, label, exhaustive)
    COUNTS['independent_decodes'] += report['decoded_objects']
    COUNTS['independent_subset_checks'] += report['subset_checks']
    oracle_dir = EVIDENCE / 'oracles'
    oracle_dir.mkdir(exist_ok=True)
    (oracle_dir / f'{len(list(oracle_dir.glob("*.json"))):04d}.json').write_text(json.dumps(report, indent=2))
    return report


def clone(repo, destination):
    shutil.copytree(repo, destination)
    return destination


def fixture(root):
    source = root / 'source'
    (source / 'nested').mkdir(parents=True)
    (source / 'empty-dir').mkdir()
    rng = random.Random(0xca17)
    data = rng.randbytes(192 * 1024)
    (source / 'a.bin').write_bytes(data)
    (source / 'copy.bin').write_bytes(data)
    (source / 'nested' / 'unicode-日本語').write_bytes(rng.randbytes(8193))
    (source / 'empty').write_bytes(b'')
    (source / 'link').symlink_to('nested/unicode-日本語')
    os.chmod(source / 'a.bin', 0o700)
    os.utime(source / 'a.bin', ns=(1_700_000_000_123_456_789, 1_700_000_000_123_456_789))
    repo = root / 'archive'
    invoke('init', repo, '--chunk-min', 1024, '--chunk-avg', 4096, '--chunk-max', 16384)
    first = invoke('backup', repo, source, 'first')
    need(first['files'] == 4 and first['symlinks'] == 1, 'fixture acquisition counts')
    invoke('backup', repo, source, 'first', expected=4)
    return source, repo


def command_surface(root, source, repo):
    inspection = invoke('inspect', repo, 'first')
    first_id = invoke('snapshots', repo)[0]['manifest_id']
    check = invoke('check', repo, 'first')
    need(check['file_digests_verified'], 'deep check must hash complete files')
    need(invoke('find', repo, 'first', '**/*.bin'), 'path search')
    invoke('history', repo, 'a.bin')
    stats = invoke('stats', repo)
    need(stats['logical_to_distinct_ratio'] > 1.5, 'deduplicated logical byte accounting')
    invoke('extract', repo, 'first', 'a.bin', root / 'extracted')
    need((root / 'extracted').read_bytes() == (source / 'a.bin').read_bytes(), 'single-file extraction')
    invoke('restore', repo, 'first', root / 'restored')
    independent(repo, 'first', root / 'restored', exhaustive=True)
    need((root / 'restored' / 'link').readlink() == pathlib.Path('nested/unicode-日本語'), 'link preservation')
    invoke('restore', repo, 'first', root / 'restored', expected=4)
    (source / 'a.bin').write_bytes(b'inserted header\n' + (source / 'a.bin').read_bytes())
    second = invoke('backup', repo, source, 'second', '--exclude', '*.tmp')
    need(second['data_packets_reused'] > second['data_packets_written'], 'prefix insertion should retain most chunks')
    need(invoke('diff', repo, 'first', 'second')['changes'], 'revision diff')
    retention = invoke('retention', repo, '--last', 1, '--pin', 'first')
    need(set(retention['keep']) == {'first', 'second'}, 'retention pin')
    plan = invoke('plan', repo, 'second', '--costs', '7,5,3,2,1,9')
    need(plan['optimal'] and plan['feasible'] and plan['cost'] == 11, 'weighted media selection')
    simulated = invoke('simulate', repo, 'second', '--unavailable', '0,1')
    need(simulated['lost_objects'] == 0 and simulated['degraded_objects'] > 0, 'simulated media loss')
    envelope = invoke('envelope', repo, 'second', '--max-loss', 3)
    need(envelope['enumeration_complete'] and envelope['smallest_observed_damaging_loss'] == 3, 'full loss envelope')
    invoke('report', repo, 'second', root / 'report.html')
    need(b'connect-src' in (root / 'report.html').read_bytes(), 'offline report policy')
    packet = next(repo.glob('volumes/00/objects/*/*.cap'))
    need(invoke('inspect-packet', packet)['volume'] == 0, 'packet inspection')
    need(invoke('scan', repo)['valid_packets'] > 0, 'index-free discovery')
    invoke('backup', repo, source, 'bad-option', '--exlude', '*.tmp', expected=2)
    invoke('extract', repo, 'first', '../escape', root / 'escape', expected=2)
    COUNTS['negative_controls'] += 4
    return first_id, inspection


def transport(root, repo):
    path = root / 'snapshot.cairn'
    exported = invoke('export', repo, 'second', path)
    imported = invoke('import', path, root / 'imported')
    need(imported['packets'] == exported['packets'] and imported['bytes'] == path.stat().st_size, 'bundle accounting')
    invoke('restore', root / 'imported', 'second', root / 'import-restored')
    independent(root / 'imported', 'second', root / 'import-restored')
    raw = bytearray(path.read_bytes())
    raw[len(raw)//2] ^= 1
    (root / 'bad.cairn').write_bytes(raw)
    invoke('import', root / 'bad.cairn', root / 'bad-import', expected=4)
    need(not (root / 'bad-import').exists(), 'corrupt bundle publication')
    (root / 'bad.cairn').write_bytes(path.read_bytes()[:-1])
    invoke('import', root / 'bad.cairn', root / 'bad-import', expected=4)
    COUNTS['negative_controls'] += 2


def physical_damage(root, source, repo):
    for count in range(3):
        for unavailable in itertools.combinations(range(6), count):
            case = root / ('loss-' + '-'.join(map(str, unavailable)))
            damaged = clone(repo, case / 'archive')
            for volume in unavailable:
                shutil.rmtree(damaged / 'volumes' / f'{volume:02d}')
            check = invoke('check', damaged, 'second', expected=0 if count == 0 else 4)
            need(check['lost_objects'] == 0 and check['file_digests_verified'], 'recoverable volume-loss check')
            invoke('restore', damaged, 'second', case / 'restored')
            independent(damaged, 'second', case / 'restored')
            COUNTS['volume_loss_cases'] += 1
    case = root / 'local-corruption'
    damaged = clone(repo, case / 'archive')
    manifest = invoke('inspect', damaged, 'second')
    entry = next(e for e in manifest['entries'] if e['kind'] == 'file' and e['chunks'])
    oid = entry['chunks'][0]['id']
    for index in (0, 1):
        packet = damaged / 'volumes' / f'{index:02d}' / 'objects' / oid[:2] / (oid + '.cap')
        raw = bytearray(packet.read_bytes())
        raw[-1] ^= 1
        packet.write_bytes(raw)
    check = invoke('check', damaged, 'second', expected=4)
    need(check['lost_objects'] == 0, 'two corrupt shards are erasures')
    limited = invoke('repair', damaged, 'second', '--max-packets', 0, '--apply', expected=4)
    need(limited['deferred_packets'] == 2, 'budget-limited repair must disclose remaining damage')
    COUNTS['negative_controls'] += 1
    plan = invoke('repair', damaged, 'second')
    need(len(plan['actions']) == 2, 'physical repair target count')
    (case / 'repair.json').write_text(json.dumps(plan, separators=(',', ':')))
    repaired = invoke('apply-repair', damaged, case / 'repair.json')
    need(repaired['packets_repaired'] == 2, 'applied repair target count')
    invoke('apply-repair', damaged, case / 'repair.json', expected=4)
    invoke('check', damaged, 'second')
    for index in range(3):
        packet = damaged / 'volumes' / f'{index:02d}' / 'objects' / oid[:2] / (oid + '.cap')
        packet.unlink()
    invoke('restore', damaged, 'second', case / 'impossible', expected=3)
    need(not (case / 'impossible').exists(), 'failed restore destination isolation')
    salvage = invoke('salvage', damaged, 'second', case / 'salvaged')
    need(salvage['partial_files'] > 0 and salvage['missing_bytes'] > 0, 'partial salvage accounting')
    for file in salvage['files']:
        if file['state'] != 'complete':
            need(not (case / 'salvaged' / 'complete' / file['path']).exists(), 'partial file disguised as complete')
    COUNTS['negative_controls'] += 3


def algebraic_negative(root, repo):
    damaged = clone(repo, root / 'surplus-parity')
    manifest = invoke('inspect', damaged, 'second')
    entry = next(e for e in manifest['entries'] if e['chunks'])
    oid = entry['chunks'][0]['id']
    path = damaged / 'volumes' / '05' / 'objects' / oid[:2] / (oid + '.cap')
    raw = bytearray(path.read_bytes())
    raw[-1] ^= 1
    raw[104:168] = sha(raw[172:]).encode()
    raw[168:172] = crc32c(raw[:168]).to_bytes(4, 'little')
    path.write_bytes(raw)
    parse_packet(raw)  # All local checksums are valid by construction.
    check = invoke('check', damaged, 'second', expected=3)
    need(check['lost_objects'] > 0, 'surplus equations must catch rechecksummed bad parity')
    rejected = False
    try:
        inspect_archive(damaged, label='second', exhaustive=True)
    except ValueError:
        rejected = True
    need(rejected, 'independent oracle must reject the same algebraic negative')
    COUNTS['negative_controls'] += 1


def maintenance_and_rescue(root, source, repo, first_id):
    case = root / 'maintenance'
    maintained = clone(repo, case / 'archive')
    forgotten = invoke('forget', maintained, 'second')
    need(not forgotten['forgotten'] and len(invoke('snapshots', maintained)) == 2, 'forget is an explicit plan by default')
    invoke('forget', maintained, 'second', '--apply')
    plan = invoke('gc', maintained)
    need(plan['garbage'], 'forgotten snapshot leaves collectible objects')
    (case / 'gc.json').write_text(json.dumps(plan, separators=(',', ':')))
    invoke('backup', maintained, source, 'third')
    invoke('gc', maintained, '--apply', case / 'gc.json', expected=4)
    plan = invoke('gc', maintained)
    (case / 'gc.json').write_text(json.dumps(plan, separators=(',', ':')))
    invoke('gc', maintained, '--apply', case / 'gc.json')
    invoke('check', maintained, 'first')
    rescue = clone(repo, root / 'lost-roots')
    for path in rescue.glob('volumes/*/refs/*.json'):
        path.unlink()
    discovered = invoke('discover-snapshots', rescue)
    need(len(discovered['candidates']) == 2, 'manifest discovery after complete root loss')
    invoke('recover-root', rescue, first_id)
    independent(rescue, 'first')
    assembly_source = clone(repo, root / 'lost-top-level')
    (assembly_source / 'config.json').unlink()
    (assembly_source / '.lock').unlink()
    inputs = [assembly_source / 'volumes' / f'{i:02d}' for i in (2, 3, 4, 5)]
    assembled = invoke('assemble', root / 'assembled', *inputs)
    need(assembled['recoverable_snapshots'] == 2, 'detached assembly should recover both roots')
    independent(root / 'assembled', 'second')


def locking_and_special_files(root, source, repo):
    with open(repo / '.lock', 'r+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        invoke('stats', repo, expected=5)
        invoke('backup', repo, source, 'locked', expected=5)
        fcntl.flock(lock, fcntl.LOCK_UN)
    with open(repo / '.lock', 'r+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        invoke('check', repo, 'first')
        invoke('backup', repo, source, 'locked', expected=5)
    special = root / 'special-source'
    special.mkdir()
    os.mkfifo(special / 'fifo')
    invoke('backup', repo, special, 'fifo', expected=2, timeout=5)
    COUNTS['negative_controls'] += 4


def crash_environment(point):
    return {**os.environ, 'CAIRN_CRASH_AT': point}


def crash_cases(root, source, repo):
    (source / 'crash-only').write_bytes(random.Random(31337).randbytes(48000))
    backup_points = ['file-written', 'file-synced', 'file-published', 'directory-synced',
                     'object-packet', 'object-complete', 'source-validated',
                     'manifest-stored', 'reference-published']
    for point in backup_points:
        case = root / ('crash-' + point)
        crashed = clone(repo, case / 'archive')
        invoke('backup', crashed, source, 'crashed', expected=-signal.SIGKILL, env=crash_environment(point))
        invoke('check', crashed, 'first')
        labels = {s['label'] for s in invoke('snapshots', crashed)}
        if 'crashed' in labels:
            checked = invoke('check', crashed, 'crashed', expected=(0, 4))
            need(checked['file_digests_verified'] and checked['lost_objects'] == 0, 'visible crash snapshot must be complete')
        gc_plan = invoke('gc', crashed)
        (case / 'gc.json').write_text(json.dumps(gc_plan, separators=(',', ':')))
        invoke('gc', crashed, '--apply', case / 'gc.json')
        invoke('check', crashed, 'first')
        COUNTS['crash_cases'] += 1
    for point in ('restore-tree-synced', 'restore-published'):
        case = root / ('crash-' + point)
        case.mkdir()
        target = case / 'restored'
        invoke('restore', repo, 'second', target, expected=-signal.SIGKILL, env=crash_environment(point))
        if target.exists():
            independent(repo, 'second', target)
        else:
            invoke('restore', repo, 'second', target)
            independent(repo, 'second', target)
        COUNTS['crash_cases'] += 1
    case = root / 'crash-repair'
    damaged = clone(repo, case / 'archive')
    shutil.rmtree(damaged / 'volumes' / '00')
    invoke('repair', damaged, 'second', '--apply', expected=-signal.SIGKILL, env=crash_environment('repair-packet'))
    invoke('repair', damaged, 'second', '--apply')
    invoke('check', damaged, 'second')
    COUNTS['crash_cases'] += 1
    case = root / 'crash-forget'
    maintained = clone(repo, case / 'archive')
    invoke('forget', maintained, 'second', '--apply', expected=-signal.SIGKILL, env=crash_environment('forget-reference'))
    invoke('forget', maintained, 'second', '--apply')
    plan = invoke('gc', maintained)
    (case / 'gc.json').write_text(json.dumps(plan, separators=(',', ':')))
    invoke('gc', maintained, '--apply', case / 'gc.json', expected=-signal.SIGKILL, env=crash_environment('gc-packet'))
    plan = invoke('gc', maintained)
    (case / 'gc.json').write_text(json.dumps(plan, separators=(',', ':')))
    invoke('gc', maintained, '--apply', case / 'gc.json')
    invoke('check', maintained, 'first')
    COUNTS['crash_cases'] += 2


def main():
    for directory in ('commands', 'oracles'):
        path = EVIDENCE / directory
        if path.exists():
            shutil.rmtree(path)
        path.mkdir()
    failure = EVIDENCE / 'failure.json'
    if failure.exists():
        failure.unlink()
    environment = dict(platform=sys.platform, python=sys.version.split()[0],
                       compiler=subprocess.check_output([str(ROOT/'tools'/'nim'),'--version'],text=True),
                       c_compiler=subprocess.check_output(['cc','--version'],text=True).splitlines()[0])
    (EVIDENCE/'environment.json').write_text(json.dumps(environment,indent=2))
    frozen = source_manifest()
    (EVIDENCE / 'source-manifest.json').write_text(json.dumps(frozen, indent=2, sort_keys=True))
    with tempfile.TemporaryDirectory(prefix='cairn-acceptance-') as temporary:
        root = pathlib.Path(temporary)
        source, repo = fixture(root)
        print('acceptance: command surface and independent decoding', flush=True)
        first_id, _ = command_surface(root, source, repo)
        with tarfile.open(EVIDENCE/'fixture.tar.gz','w:gz') as archive:
            for path in [repo,*sorted(repo.rglob('*'))]:
                info = archive.gettarinfo(str(path), arcname=str(path.relative_to(repo.parent)))
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mtime = 0
                if info.isfile():
                    with path.open('rb') as data:
                        archive.addfile(info,data)
                else:
                    archive.addfile(info)
        print('acceptance: streaming transport and corruption controls', flush=True)
        transport(root, repo)
        first_demo = invoke('demo', cwd=root)
        second_demo = invoke('demo', cwd=root)
        need(first_demo['root'] != second_demo['root'] and second_demo['byte_comparison']=='passed', 'repeated default demos must choose distinct owned outputs')
        print('acceptance: all zero-, one-, and two-volume loss subsets', flush=True)
        physical_damage(root, source, repo)
        algebraic_negative(root, repo)
        print('acceptance: maintenance, root rescue, locks, and special files', flush=True)
        maintenance_and_rescue(root, source, repo, first_id)
        locking_and_special_files(root, source, repo)
        print('acceptance: actual SIGKILL publication boundaries', flush=True)
        crash_cases(root, source, repo)
    process = subprocess.run([sys.executable, str(ROOT / 'tools' / 'regression_io.py')], capture_output=True, text=True)
    (EVIDENCE / 'io-regression.log').write_text(process.stdout + process.stderr)
    need(process.returncode == 0, 'real destination-I/O regression')
    need(source_manifest() == frozen, 'source changed during acceptance')
    report = dict(status='passed', counts=COUNTS, wall_seconds=time.monotonic()-START,
                  source_manifest_sha256=sha((EVIDENCE / 'source-manifest.json').read_bytes()),
                  platform=sys.platform, python=sys.version.split()[0],
                  scope='process crashes and real filesystem damage; no power-loss or hardware durability claim')
    (EVIDENCE / 'acceptance.json').write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        (EVIDENCE / 'failure.json').write_text(json.dumps({'status':'failed','error':str(error),'counts':COUNTS}, indent=2))
        raise
