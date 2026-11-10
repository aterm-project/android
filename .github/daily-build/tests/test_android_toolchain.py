#!/usr/bin/env python3
"""Exercise SDK-manager/NDK reuse without downloads or native compilation."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / '.github/daily-build/recipe/android_toolchain.sh'
NDK = '28.2.13676358'


class AndroidToolchainTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.sdk = self.base / 'sdk'
        self.requests = self.base / 'sdk-requests.txt'
        self.env_file = self.base / 'github-env'
        tools = self.base / 'tools'
        tools.mkdir()
        java = self.base / 'jdk/bin/java'
        self.executable(java, '#!/bin/sh\necho \'openjdk version "17.0.21"\' >&2\n')
        self.executable(tools / 'cmake', '#!/bin/sh\necho "cmake version 3.31.6"\n')
        self.executable(tools / 'ninja', '#!/bin/sh\necho "1.13.2"\n')
        self.executable(self.sdk / 'cmdline-tools/latest/bin/sdkmanager', '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
with open(os.environ['TEST_SDK_REQUESTS'], 'a') as f:
    f.write(' '.join(sys.argv[1:]) + '\\n')
if '--install' in sys.argv:
    for package in sys.argv[sys.argv.index('--install') + 1:]:
        if package.startswith('ndk;'):
            revision = package.split(';')[1]
            root = Path(os.environ['ANDROID_HOME']) / 'ndk' / revision
            root.mkdir(parents=True, exist_ok=True)
            (root / 'source.properties').write_text('Pkg.Revision = ' + revision + '\\n')
''')
        self.env = dict(os.environ,
                        ANDROID_HOME=str(self.sdk),
                        JAVA_HOME_17_X64=str(java.parent.parent),
                        RUNNER_TEMP=str(self.base / 'runner-temp'),
                        GITHUB_ENV=str(self.env_file),
                        GRADLE_USER_HOME=str(self.base / 'gradle'),
                        TEST_SDK_REQUESTS=str(self.requests),
                        PATH=str(tools) + os.pathsep + os.environ['PATH'])

    @staticmethod
    def executable(path: Path, source: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        path.chmod(0o700)

    def run_toolchain(self):
        return subprocess.run(['bash', str(SCRIPT)], cwd=ROOT, env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_engine_and_gradle_share_one_install_across_runs(self):
        for _ in range(2):
            result = self.run_toolchain()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        requests = self.requests.read_text().splitlines()
        self.assertEqual(requests.count('--install ndk;' + NDK), 1)
        self.assertFalse(any('--sdk_root=' in line for line in requests))
        shared_root = self.sdk / 'ndk' / NDK
        self.assertIn('ANDROID_NDK_ROOT=' + str(shared_root), self.env_file.read_text())
        self.assertTrue((shared_root / 'source.properties').is_file())
        self.assertFalse((self.base / 'runner-temp/android-ndk').exists())
        self.assertIn('org.gradle.workers.max=2', (self.base / 'gradle/gradle.properties').read_text())

    def test_wrong_cached_revision_is_rejected(self):
        root = self.sdk / 'ndk' / NDK
        root.mkdir(parents=True)
        (root / 'source.properties').write_text('Pkg.Revision = 27.0.0\n')
        result = self.run_toolchain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NDK revision 27.0.0 != pinned ' + NDK, result.stdout + result.stderr)
        self.assertFalse(self.env_file.exists())


if __name__ == '__main__':
    unittest.main()
