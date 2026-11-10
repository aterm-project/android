#!/usr/bin/env python3
"""Recover publication from a successful signed artifact, never rebuild/sign."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import daily_gate as gate


class RecoveryError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise RecoveryError(message)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def verify_run(run, jobs, repository, run_id):
    require(repository == 'aterm-project/android', 'unexpected repository')
    require(str(run['id']) == run_id and run['repository']['full_name'] == repository,
            'run belongs to another repository or id')
    require(run['path'] == '.github/workflows/daily-build.yml' and run['head_branch'] == 'main',
            'only the main daily workflow may be recovered')
    require(run['event'] in ('schedule', 'workflow_dispatch') and
            run['status'] == 'completed' and run['conclusion'] == 'failure',
            'source must be a completed failed daily run')
    require(bool(re.fullmatch('[0-9a-f]{40}', run['head_sha'])), 'invalid source SHA')
    expected = {
        'Gate (UTC quota, inputs, claim)': 'success',
        'Build APK (arm64-v8a + x86_64, RDP engine)': 'success',
        'Sign APK with the stable project key': 'success',
        'Publish release and advance baseline': 'failure',
    }
    require(len(jobs) == len(expected) and
            all(j['status'] == 'completed' and expected.get(j['name']) == j['conclusion'] for j in jobs) and
            {j['name'] for j in jobs} == set(expected),
            'original build and signing must pass; only publication may fail')


def verify_claim(record, run, repository):
    require(record.get('repository') == repository and record.get('branch') == 'main' and
            str(record.get('run_id')) == str(run['id']) and
            str(record.get('run_attempt')) == str(run['run_attempt']) and
            record.get('source_sha') == run['head_sha'], 'claim does not belong to the source run/attempt')


def receipt_path():
    return Path(os.environ['RUNNER_TEMP']) / 'publication-recovery.json'


def prepare():
    require(os.environ['GITHUB_REF'] == 'refs/heads/main', 'recovery must run on main')
    repository, run_id = os.environ['GITHUB_REPOSITORY'], os.environ['ATERMIUS_RECOVER_RUN_ID']
    require(bool(re.fullmatch('[0-9]+', run_id)), 'invalid original run id')
    prefix = f'repos/{repository}'
    run = api(f'{prefix}/actions/runs/{run_id}')
    attempt = str(run['run_attempt'])
    jobs = api(f'{prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100')['jobs']
    verify_run(run, jobs, repository, run_id)
    name = f'android-release-{attempt}'
    artifacts = [a for a in api(f'{prefix}/actions/runs/{run_id}/artifacts?per_page=100')['artifacts']
                 if a['name'] == name]
    require(len(artifacts) == 1 and not artifacts[0]['expired'], 'signed artifact missing or expired')
    artifact = artifacts[0]
    require(bool(re.fullmatch('sha256:[0-9a-f]{64}', artifact.get('digest', ''))), 'artifact digest missing')
    namespace, repo = os.environ['ATERMIUS_DAILY_NAMESPACE'], Path.cwd()
    # Allow a run created just before midnight whose gate claimed the next day.
    start = dt.date.fromisoformat(run['created_at'][:10])
    dates = [start.isoformat(), (start + dt.timedelta(days=1)).isoformat()]
    refs = gate.ls_remote(repo, 'origin', [f'{namespace}/quota/{day}/*' for day in dates])
    matches = []
    for ref, sha in refs.items():
        gate.fetch_shas(repo, 'origin', [sha])
        record = gate.read_record(repo, sha, 'quota')
        if str(record.get('run_id')) == run_id:
            verify_claim(record, run, repository)
            require(ref == f"{namespace}/quota/{record['quota_date']}/{record['slot']}", 'claim ref mismatch')
            matches.append((sha, record))
    require(len(matches) == 1, 'original quota claim missing or superseded')
    sha, claim = matches[0]
    day, slot, source = claim['quota_date'], str(claim['slot']), run['head_sha']
    require(day in dates and bool(re.fullmatch('[1-9]', slot)), 'invalid quota date/slot')
    tag = f"daily-{day.replace('-', '')}.{slot}-{source[:12]}"
    values = {
        'ATERMIUS_ARTIFACT_RUN_ID': run_id, 'ATERMIUS_ARTIFACT_RUN_ATTEMPT': attempt,
        'ATERMIUS_RECOVER_ARTIFACT': name, 'ATERMIUS_SOURCE_SHA': source,
        'ATERMIUS_QUOTA_DATE': day, 'ATERMIUS_QUOTA_SLOT': slot, 'ATERMIUS_CLAIM_RECORD': sha,
        'ATERMIUS_BASELINE_RECORD': claim.get('baseline_before') or 'none',
        'ATERMIUS_RELEASE_TAG': tag, 'ATERMIUS_PLATFORMS': 'android',
        'ATERMIUS_RELEASE_TITLE': f'Atermius Android daily {tag}',
    }
    with open(os.environ['GITHUB_ENV'], 'a') as stream:
        for key, value in values.items():
            require('\n' not in str(value) and '\r' not in str(value), 'invalid environment value')
            stream.write(f'{key}={value}\n')
    receipt = {'source_run_id': run_id, 'source_run_attempt': attempt, 'source_sha': source,
               'claim_record': sha, 'signed_artifact_id': artifact['id'], 'signed_artifact_digest': artifact['digest'],
               'recovery_run_id': os.environ['GITHUB_RUN_ID'], 'recovery_source_sha': os.environ['GITHUB_SHA'],
               'build_or_sign_performed': False}
    receipt_path().write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


def stage(directory, quarantine, context):
    require(not quarantine.exists(), 'sidecar quarantine already exists')
    paths = list(directory.iterdir())
    require(all(p.is_file() and not p.is_symlink() for p in paths), 'artifact contains directories or links')
    evidence = directory / 'evidence-android.json'
    data = json.loads(evidence.read_text())
    expected = {'source_sha': context['source_sha'], 'run_id': context['source_run_id'],
                'run_attempt': context['source_run_attempt']}
    require(all(str(data.get(k)) == str(v) for k, v in expected.items()), 'foreign artifact evidence')
    require(data.get('status') == 'built' and data.get('platform') == 'android', 'not a signed Android artifact')
    require(len(data['artifacts']) == 1, 'expected one signed APK')
    apk = data['artifacts'][0]
    name = apk['name']
    require(bool(re.fullmatch(r'[A-Za-z0-9_.-]+\.apk', name)), 'unsafe APK name')
    path = directory / name
    require(path.is_file() and path.stat().st_size == apk['size'] and
            hashlib.sha256(path.read_bytes()).hexdigest() == apk['sha256'], 'signed APK digest mismatch')
    extra = {p.name for p in paths} - {name, evidence.name}
    require(extra <= {name + '.idsig'}, 'unexpected files beyond the optional APK v4 sidecar')
    excluded = []
    if extra:
        sidecar = directory / (name + '.idsig')
        excluded.append({'name': sidecar.name, 'sha256': hashlib.sha256(sidecar.read_bytes()).hexdigest(),
                         'size': sidecar.stat().st_size})
        quarantine.mkdir()
        sidecar.rename(quarantine / sidecar.name)
    return {'apk': apk, 'quarantined_optional_v4_sidecars': excluded,
            'apk_and_original_evidence_bytes_unchanged': True}


def main():
    if sys.argv[1:] == ['prepare']:
        prepare()
    elif sys.argv[1:] == ['stage']:
        p = receipt_path()
        context = json.loads(p.read_text())
        context.update(stage(Path(os.environ['RUNNER_TEMP']) / 'release',
                             Path(os.environ['RUNNER_TEMP']) / 'v4-sidecars', context))
        p.write_text(json.dumps(context, indent=2) + '\n')
        print(json.dumps(context))
    else:
        raise RecoveryError('expected prepare or stage')


if __name__ == '__main__':
    try:
        main()
    except (RecoveryError, gate.GateError, KeyError, ValueError) as error:
        sys.exit(f'::error::publication recovery: {error}')
