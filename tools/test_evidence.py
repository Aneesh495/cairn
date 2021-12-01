#!/usr/bin/env python3
"""Negative controls for the saved-evidence verifier, run after freezing."""
import io
import json
import pathlib
import shutil
import tarfile
import tempfile
import unittest
from evidence import ROOT, verify, unpacked
from source_state import source_manifest, sha


class EvidenceRejectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cairn-evidence-negative-')
        self.root = pathlib.Path(self.temporary.name)
        for relative in source_manifest(ROOT):
            target = self.root/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/relative, target)
        shutil.copytree(ROOT/'evidence', self.root/'evidence')
        self.saved = self.root/'evidence'/'local'

    def tearDown(self):
        self.temporary.cleanup()

    def rebind_artifact(self, name):
        path = self.saved/'binding.json'
        binding = json.loads(path.read_text())
        binding['files'][name] = sha((self.saved/name).read_bytes())
        path.write_text(json.dumps(binding))

    def test_source_edit_rejects(self):
        source = self.root/'src'/'cairn'/'errors.nim'
        source.write_bytes(source.read_bytes()+b'\n')
        with self.assertRaisesRegex(ValueError, 'source binding is stale'):
            verify(self.root)

    def test_artifact_edit_rejects(self):
        path = self.saved/'campaign.json'
        path.write_bytes(path.read_bytes()+b' ')
        with self.assertRaisesRegex(ValueError, 'artifact checksum mismatch'):
            verify(self.root)

    def test_missing_raw_evidence_rejects(self):
        (self.saved/'commands.tar.gz').unlink()
        with self.assertRaises((ValueError,OSError)):
            verify(self.root)

    def test_rechecksummed_false_count_rejects(self):
        path = self.saved/'acceptance.json'
        report = json.loads(path.read_text())
        report['counts']['independent_decodes'] += 1
        path.write_text(json.dumps(report))
        self.rebind_artifact('acceptance.json')
        with self.assertRaisesRegex(ValueError, 'oracle decode count mismatch'):
            verify(self.root)

    def test_rechecksummed_smaller_workload_rejects(self):
        path = self.saved/'campaign.json'
        campaign = json.loads(path.read_text())
        campaign['erasure_cases'] -= 1
        path.write_text(json.dumps(campaign))
        self.rebind_artifact('campaign.json')
        with self.assertRaisesRegex(ValueError, 'campaign workload differs'):
            verify(self.root)

    def test_rechecksummed_raw_output_edit_rejects(self):
        path = self.saved/'commands.tar.gz'
        raw = unpacked(path)
        first = sorted(raw)[0]
        raw[first] += b'changed'
        with tarfile.open(path,'w:gz') as tar:
            for name, data in sorted(raw.items()):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info,io.BytesIO(data))
        self.rebind_artifact('commands.tar.gz')
        with self.assertRaisesRegex(ValueError, 'raw command digest mismatch'):
            verify(self.root)

    def test_rechecksummed_crash_count_edit_rejects(self):
        path = self.saved/'commands.json'
        commands = json.loads(path.read_text())
        next(command for command in commands if command['exit']==-9)['exit'] = 0
        path.write_text(json.dumps(commands))
        self.rebind_artifact('commands.json')
        with self.assertRaisesRegex(ValueError, 'SIGKILL case count mismatch'):
            verify(self.root)

    def test_disagreeing_debug_release_logs_reject(self):
        path = self.saved/'unit-debug.log'
        lines = path.read_text().splitlines(keepends=True)
        position = next(i for i,line in enumerate(lines) if '[OK]' in line)
        del lines[position]
        path.write_text(''.join(lines))
        self.rebind_artifact('unit-debug.log')
        with self.assertRaisesRegex(ValueError, 'debug/release suite count disagreement'):
            verify(self.root)


if __name__=='__main__':
    unittest.main()
