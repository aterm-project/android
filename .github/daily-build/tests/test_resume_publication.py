#!/usr/bin/env python3
"""Provenance and cached-artifact guards for publication-only recovery."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('resume_publication', HERE.parent / 'resume_publication.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / 'release'
        self.release.mkdir()
        self.context = {'source_sha': 'a' * 40, 'source_run_id': '42', 'source_run_attempt': '1'}
        apk = b'original signed APK bytes'
        self.apk_name = 'atermius-signed.apk'
        self.evidence = {'status': 'built', 'platform': 'android', 'source_sha': 'a' * 40,
                         'run_id': '42', 'run_attempt': '1',
                         'artifacts': [{'name': self.apk_name, 'size': len(apk),
                                        'sha256': hashlib.sha256(apk).hexdigest()}]}
        (self.release / self.apk_name).write_bytes(apk)
        (self.release / 'evidence-android.json').write_text(json.dumps(self.evidence))
        self.run = {'id': 42, 'repository': {'full_name': 'aterm-project/android'},
                    'path': '.github/workflows/daily-build.yml', 'head_branch': 'main',
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'failure',
                    'head_sha': 'a' * 40, 'run_attempt': 1}
        self.jobs = [{'name': name, 'status': 'completed', 'conclusion': conclusion} for name, conclusion in [
            ('Gate (UTC quota, inputs, claim)', 'success'),
            ('Build APK (arm64-v8a + x86_64, RDP engine)', 'success'),
            ('Sign APK with the stable project key', 'success'),
            ('Publish release and advance baseline', 'failure')]]

    def stage(self):
        return recovery.stage(self.release, self.root / 'sidecars', self.context)

    def test_original_run_and_claim_accepted(self):
        recovery.verify_run(self.run, self.jobs, 'aterm-project/android', '42')
        claim = {'repository': 'aterm-project/android', 'branch': 'main', 'run_id': '42',
                 'run_attempt': '1', 'source_sha': 'a' * 40}
        recovery.verify_claim(claim, self.run, 'aterm-project/android')
        for key, value in [('run_id', '43'), ('run_attempt', '2'), ('source_sha', 'b' * 40)]:
            with self.subTest(key=key), self.assertRaises(recovery.RecoveryError):
                recovery.verify_claim({**claim, key: value}, self.run, 'aterm-project/android')

    def test_foreign_branch_or_workflow_rejected(self):
        for key, value in [('head_branch', 'feature'), ('event', 'pull_request'),
                           ('path', '.github/workflows/other.yml'), ('conclusion', 'success')]:
            with self.subTest(key=key), self.assertRaises(recovery.RecoveryError):
                recovery.verify_run({**self.run, key: value}, self.jobs, 'aterm-project/android', '42')

    def test_failed_build_or_signing_cannot_be_published(self):
        for index in [0, 1, 2]:
            jobs = copy.deepcopy(self.jobs)
            jobs[index]['conclusion'] = 'failure'
            with self.subTest(index=index), self.assertRaises(recovery.RecoveryError):
                recovery.verify_run(self.run, jobs, 'aterm-project/android', '42')

    def test_sidecar_quarantined_without_changing_apk_or_evidence(self):
        before = {p.name: p.read_bytes() for p in self.release.iterdir()}
        (self.release / (self.apk_name + '.idsig')).write_bytes(b'optional v4')
        result = self.stage()
        self.assertEqual({p.name: p.read_bytes() for p in self.release.iterdir()}, before)
        self.assertEqual((self.root / 'sidecars' / (self.apk_name + '.idsig')).read_bytes(), b'optional v4')
        self.assertTrue(result['apk_and_original_evidence_bytes_unchanged'])

    def test_no_sidecar_accepted_without_creating_quarantine(self):
        self.assertEqual(self.stage()['quarantined_optional_v4_sidecars'], [])
        self.assertFalse((self.root / 'sidecars').exists())

    def test_unrelated_extra_file_rejected(self):
        (self.release / 'unexpected.bin').write_bytes(b'x')
        with self.assertRaises(recovery.RecoveryError):
            self.stage()

    def test_tampered_apk_rejected_before_sidecar_moves(self):
        (self.release / self.apk_name).write_bytes(b'tampered')
        sidecar = self.release / (self.apk_name + '.idsig')
        sidecar.write_bytes(b'v4')
        with self.assertRaises(recovery.RecoveryError):
            self.stage()
        self.assertTrue(sidecar.exists())

    def test_foreign_evidence_or_symlink_rejected(self):
        with self.assertRaises(recovery.RecoveryError):
            recovery.stage(self.release, self.root / 'sidecars', {**self.context, 'source_run_attempt': '2'})
        target = self.release / self.apk_name
        target.unlink()
        target.symlink_to('/etc/hosts')
        with self.assertRaises(recovery.RecoveryError):
            self.stage()


if __name__ == '__main__':
    unittest.main()
