#!/usr/bin/env python3
"""Assemble existing cross-repository tests without changing either checkout."""
import argparse
from pathlib import Path
import shutil
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--web', type=Path, help='Web repository (default: sibling web)')
parser.add_argument('--output', type=Path, help='New disposable workspace directory')
args = parser.parse_args()
server = Path(__file__).resolve().parents[1]
web = (args.web or server.parent / 'web').resolve()
if not (web / 'apps/client/pubspec.yaml').is_file():
    parser.error('Web checkout missing; pass --web')
if args.output:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
else:
    output = Path(tempfile.mkdtemp(prefix='aterminal-integration-'))
# Tests calculate their root relative to __file__/__dirname, so copy the small
# test harness and deployment files rather than symlinking those directories.
for folder in ('integration', 'deploy', 'protocol'):
    shutil.copytree(server / folder, output / folder,
                    ignore=shutil.ignore_patterns('node_modules', '__pycache__', '.env', 'data', 'build'))
for folder, target in (('server', server / 'server'),
                       ('apps', web / 'apps'), ('packages', web / 'packages')):
    (output / folder).symlink_to(target, target_is_directory=True)
print(output)
