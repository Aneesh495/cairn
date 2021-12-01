#!/usr/bin/env python3
"""Freeze, verify, or independently replay source-bound local acceptance evidence."""
from __future__ import annotations
import argparse
import json
import pathlib
import re
import shutil
import tarfile
import tempfile
from oracle import inspect_archive
from source_state import source_manifest, sha

ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED = ['acceptance.json','source-manifest.json','campaign.json','unit-debug.log',
            'unit-release.log','fixture.tar.gz','commands.json','environment.json','io-regression.log']


def need(condition, message):
    if not condition:
        raise ValueError(message)


def packed(directory, destination):
    with tarfile.open(destination, 'w:gz') as tar:
        for path in sorted(directory.iterdir()):
            need(path.is_file() and not path.is_symlink(), 'unexpected raw evidence entry')
            info = tar.gettarinfo(str(path), arcname=path.name)
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            info.mtime = 0
            with path.open('rb') as stream:
                tar.addfile(info, stream)


def unpacked(path):
    result = {}
    with tarfile.open(path) as tar:
        for member in tar.getmembers():
            need(member.isfile() and '/' not in member.name and member.name not in result,
                 'unsafe or duplicate raw evidence member')
            need(member.size <= 64*1024*1024, 'raw evidence member exceeds bound')
            result[member.name] = tar.extractfile(member).read()
    return result


def freeze(root=ROOT):
    built = root / 'build' / 'evidence'
    need(not (built/'failure.json').exists(), 'the last acceptance run failed')
    expected = json.loads((built/'source-manifest.json').read_text())
    need(expected == source_manifest(root), 'source changed since acceptance; run make verify again')
    destination = root / 'evidence' / 'local'
    destination.mkdir(parents=True, exist_ok=True)
    for name in REQUIRED:
        need((built/name).is_file(), 'missing acceptance artifact: '+name)
        shutil.copyfile(built/name, destination/name)
    packed(built/'commands', destination/'commands.tar.gz')
    packed(built/'oracles', destination/'oracles.tar.gz')
    hashes = {path.name:sha(path.read_bytes()) for path in sorted(destination.iterdir())
              if path.is_file() and path.name != 'binding.json'}
    (destination/'binding.json').write_text(json.dumps({'version':1,'files':hashes},indent=2,sort_keys=True))
    return verify(root)


def verify(root=ROOT):
    destination = root / 'evidence' / 'local'
    binding = json.loads((destination/'binding.json').read_text())
    need(binding['version']==1, 'unsupported evidence binding')
    need(set(binding['files'])==set(REQUIRED)|{'commands.tar.gz','oracles.tar.gz'}, 'evidence artifact set mismatch')
    for name, digest in binding['files'].items():
        need('/' not in name and name not in ('.','..'), 'unsafe evidence filename')
        need(sha((destination/name).read_bytes())==digest, 'artifact checksum mismatch: '+name)
    expected = json.loads((destination/'source-manifest.json').read_text())
    actual = source_manifest(root)
    if expected != actual:
        changed = sorted(set(expected)^set(actual) | {p for p in expected.keys() & actual.keys() if expected[p]!=actual[p]})
        raise ValueError('source binding is stale: '+', '.join(changed[:12]))
    report = json.loads((destination/'acceptance.json').read_text())
    need(report['status']=='passed', 'acceptance status is not passed')
    need(report['source_manifest_sha256']==sha((destination/'source-manifest.json').read_bytes()), 'report source binding mismatch')
    commands = json.loads((destination/'commands.json').read_text())
    raw = unpacked(destination/'commands.tar.gz')
    need(len(raw)==len(commands)*2, 'raw command output count mismatch')
    for index, command in enumerate(commands):
        for stream in ('stdout','stderr'):
            name = f'{index:04d}.{stream}'
            need(sha(raw[name])==command[stream+'_sha256'], 'raw command digest mismatch')
    need(len(commands)==report['counts']['commands'], 'executed command count mismatch')
    need(sum(c['exit']==-9 for c in commands)==report['counts']['crash_cases'], 'SIGKILL case count mismatch')
    oracles = [json.loads(data) for data in unpacked(destination/'oracles.tar.gz').values()]
    need(sum(x['decoded_objects'] for x in oracles)==report['counts']['independent_decodes'], 'oracle decode count mismatch')
    need(sum(x['subset_checks'] for x in oracles)==report['counts']['independent_subset_checks'], 'oracle subset count mismatch')
    campaign = json.loads((destination/'campaign.json').read_text())
    for key, value in dict(erasure_cases=3000,packet_single_bit_corruptions=5000,packet_fuzz_inputs=10000,
                          compression_round_trips=10000,compression_fuzz_inputs=10000,metadata_mutations=10000).items():
        need(campaign[key]==value, 'campaign workload differs from the declared workload: '+key)
    suites = {}
    for name in ('unit-debug.log','unit-release.log'):
        text = (destination/name).read_text()
        need('[FAILED]' not in text and 'Unhandled exception' not in text, 'failed unit evidence')
        suites[name] = len(re.findall(r'\[OK\]',text))
        need(suites[name]>0, 'empty unit evidence')
    need(suites['unit-debug.log']==suites['unit-release.log'], 'debug/release suite count disagreement')
    return dict(status='passed',bound_source_files=len(expected),unit_tests=suites['unit-debug.log'],
                counts=report['counts'],campaign=campaign)


def replay(root=ROOT):
    verify(root)
    artifact = root/'evidence'/'local'/'fixture.tar.gz'
    with tempfile.TemporaryDirectory(prefix='cairn-evidence-replay-') as temporary:
        with tarfile.open(artifact) as tar:
            for member in tar.getmembers():
                path = pathlib.PurePosixPath(member.name)
                need(not path.is_absolute() and '..' not in path.parts and
                     (member.isfile() or member.isdir()), 'unsafe replay fixture member')
                need(member.size<=64*1024*1024, 'oversized fixture member')
            tar.extractall(temporary, filter='data')
        return inspect_archive(pathlib.Path(temporary)/'archive', exhaustive=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['freeze','verify','replay'])
    args=parser.parse_args()
    print(json.dumps({'freeze':freeze,'verify':verify,'replay':replay}[args.mode](),indent=2))


if __name__=='__main__':
    main()
