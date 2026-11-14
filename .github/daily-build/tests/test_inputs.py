#!/usr/bin/env python3
"""Which platform does a path belong to? Checks the monorepo routing tables.

* inputs/<platform>.txt (daily builds): shared client code rebuilds every client
  platform, a runner / engine recipe / daily workflow only its own platform(s);
  tests, docs, server and CI scripts rebuild nothing.
* checks-*.yml path filters (push / pull request), evaluated like GitHub does
  (ordered globs, the last matching pattern wins, "!" excludes).

  python3 -I .github/daily-build/tests/test_inputs.py -v
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
WORKFLOWS = TOOLS.parent / "workflows"
spec = importlib.util.spec_from_file_location("daily_gate", TOOLS / "daily_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

ALL = {"android", "desktop", "ios", "web"}
NATIVE = {"android", "desktop", "ios"}
NONE: set[str] = set()

DAILY = {
    # shared client code
    "apps/client/lib/main.dart": ALL,
    "apps/client/lib/l10n/app_en.arb": ALL,
    "apps/client/pubspec.yaml": ALL,
    "apps/client/pubspec.lock": ALL,
    "apps/client/l10n.yaml": ALL,
    "apps/client/.gitignore": ALL,
    "packages/xterm/lib/xterm.dart": ALL,
    "packages/sqlite3/hook/build.dart": ALL,
    "tools/install_flutter_linux.sh": ALL,
    ".github/daily-build/recipe/flutter_sdk.py": ALL,
    # platform runners
    "apps/client/android/app/build.gradle.kts": {"android"},
    "apps/client/ios/Runner/Info.plist": {"ios"},
    "apps/client/macos/Runner/Release.entitlements": {"desktop"},
    "apps/client/windows/runner/main.cpp": {"desktop"},
    "apps/client/linux/runner/my_application.cc": {"desktop"},
    "apps/client/web/index.html": {"web"},
    # RDP engine: shared sources vs per-platform recipes
    "apps/client/native/desktop/atermius_rdp.c": NATIVE,
    "apps/client/native/desktop/CMakeLists.txt": NATIVE,
    "apps/client/native/desktop/camera_mf.c": NATIVE,
    "apps/client/native/desktop/android/build_engine.sh": {"android"},
    "apps/client/native/desktop/android/deps.lock": {"android"},
    "apps/client/native/desktop/apple/build_engine.sh": {"desktop", "ios"},
    "integration/native/build_rdp_windows.ps1": {"desktop"},
    "deploy/nginx.conf": {"web"},
    # build recipes and daily workflows
    ".github/daily-build/recipe/android_build.sh": {"android"},
    ".github/daily-build/recipe/android_sign.sh": {"android"},
    ".github/daily-build/recipe/desktop_windows.ps1": {"desktop"},
    ".github/daily-build/recipe/desktop_macos.sh": {"desktop"},
    ".github/daily-build/recipe/ios_build.sh": {"ios"},
    ".github/daily-build/recipe/web_build.sh": {"web"},
    ".github/workflows/daily-android.yml": {"android"},
    ".github/workflows/daily-desktop.yml": {"desktop"},
    ".github/workflows/daily-ios.yml": {"ios"},
    ".github/workflows/daily-web.yml": {"web"},
    # never build inputs
    "apps/client/test/widget_test.dart": NONE,
    "apps/client/integration/native/local_resume_probe.dart": NONE,
    "apps/client/tool/process_lock_probe.dart": NONE,
    "apps/client/analysis_options.yaml": NONE,
    "apps/client/README.md": NONE,
    "apps/client/lib/notes.md": NONE,
    "packages/xterm/test/xterm_test.dart": NONE,
    "protocol/test-vectors/share-gateway-v1.json": NONE,
    "server/src/main.rs": NONE,
    "deploy/compose.yaml": NONE,
    "integration/native/android_apk_abi_check.py": NONE,
    "integration/web/admin_jobs.cjs": NONE,
    "scripts/build_ios.sh": NONE,
    "tools/verify_cloud_proxy.py": NONE,
    "Dockerfile": NONE,
    "docs/INSTALLATION.md": NONE,
    ".github/daily-build/daily_gate.py": NONE,
    ".github/daily-build/publish.sh": NONE,
    ".github/daily-build/inputs/android.txt": NONE,  # the rules enter the fingerprint in canonical form
    ".github/workflows/checks-android.yml": NONE,
    ".github/workflows/release-android.yml": NONE,
}

CHECKS = {
    "apps/client/lib/main.dart": ALL,
    "apps/client/test/desktop_protocol_test.dart": ALL,
    "apps/client/pubspec.lock": ALL,
    "packages/xterm/lib/xterm.dart": ALL,
    "tools/install_flutter_linux.sh": ALL,
    "protocol/test-vectors/share-gateway-v1.json": ALL | {"server"},
    "apps/client/android/app/build.gradle.kts": {"android"},
    "apps/client/ios/Runner/Info.plist": {"ios"},
    "apps/client/windows/runner/main.cpp": {"desktop"},
    "apps/client/macos/Runner/Info.plist": {"desktop"},
    "apps/client/linux/runner/main.cc": {"desktop"},
    "apps/client/web/index.html": {"web"},
    "apps/client/native/desktop/atermius_rdp.c": NATIVE,
    "apps/client/native/desktop/android/build_engine.sh": {"android", "ci"},  # NDK pin read by the toolkit test
    "apps/client/native/desktop/apple/build_engine.sh": {"desktop", "ios"},
    "integration/native/android_apk_abi_check.py": {"android"},
    "integration/native/windows_console_probe.dart": {"desktop"},
    "integration/native/build_rdp_windows.ps1": {"desktop"},
    "deploy/nginx.conf": {"web", "server"},
    "tools/verify_cloud_proxy.py": {"web"},
    "server/src/main.rs": {"server"},
    "server/Cargo.lock": {"server"},
    "deploy/compose.yaml": {"server"},
    ".github/daily-build/daily_gate.py": {"ci"},
    ".github/workflows/daily-web.yml": {"ci"},
    ".github/workflows/checks-ios.yml": {"ios", "ci"},
    "docs/INSTALLATION.md": NONE,
    "README.md": NONE,
    "integration/web/admin_jobs.cjs": NONE,
}


def github_paths_match(patterns: list[str], path: str) -> bool:
    selected = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        if gate.glob_regex(pattern[1:] if negated else pattern).match(path):
            selected = not negated
    return selected


class InputRulesTests(unittest.TestCase):
    def setUp(self):
        self.rules = {p: gate.Rules((TOOLS / "inputs" / f"{p}.txt").read_text()) for p in gate.PLATFORMS}

    def test_every_platform_has_rules_and_a_daily_workflow(self):
        self.assertEqual(sorted(x.stem for x in (TOOLS / "inputs").glob("*.txt")), sorted(gate.PLATFORMS))
        for platform in gate.PLATFORMS:
            self.assertTrue((WORKFLOWS / f"daily-{platform}.yml").is_file(), platform)
            self.assertEqual(gate.platform_rules(platform), f".github/daily-build/inputs/{platform}.txt")

    def test_paths_rebuild_exactly_their_platforms(self):
        for path, expected in DAILY.items():
            with self.subTest(path=path):
                self.assertEqual({p for p, rules in self.rules.items() if rules.match(path)}, expected)

    def test_every_recipe_file_is_an_input_of_some_platform(self):
        for recipe in sorted((TOOLS / "recipe").iterdir()):
            path = f".github/daily-build/recipe/{recipe.name}"
            owners = {p for p, rules in self.rules.items() if rules.match(path)}
            with self.subTest(recipe=recipe.name):
                self.assertTrue(owners)
                prefix = recipe.name.split("_", 1)[0]
                self.assertEqual(owners, {prefix} if prefix in gate.PLATFORMS else ALL)


class CheckPathFilterTests(unittest.TestCase):
    def setUp(self):
        self.filters = {}
        for path in WORKFLOWS.glob("checks-*.yml"):
            doc = yaml.safe_load(path.read_text())
            on = doc.get("on", doc.get(True))
            self.filters[path.stem.removeprefix("checks-")] = on["push"]["paths"]

    def test_check_workflows(self):
        self.assertEqual(sorted(self.filters), sorted(ALL | {"server", "ci"}))

    def test_paths_run_exactly_their_checks(self):
        for path, expected in CHECKS.items():
            with self.subTest(path=path):
                self.assertEqual({k for k, patterns in self.filters.items() if github_paths_match(patterns, path)},
                                 expected)


if __name__ == "__main__":
    unittest.main()
