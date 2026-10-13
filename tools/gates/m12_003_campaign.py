#!/usr/bin/env python3
"""Bind M12-003 STS fault evidence and require every named campaign scenario."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import signal
import sys
import threading

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest, parse_artifact_digest, parse_text_digest, schema_artifact_sha256_equal
from tools import m7_021_linux_release as release
from tools.m12_002_source_sdk import sdk_binding
from tools.gates.m12_003_supervision import run_owned

CAMPAIGN = ROOT / 'tools/gates/campaigns/m12-003-linux-faults.json'
EVIDENCE = ROOT / 'docs/evidence/M12-003'


def require(value, message):
    if not value:
        raise ValueError(message)


def repository_path(value):
    path = (ROOT / value).resolve()
    require(path.is_relative_to(ROOT), 'evidence/source path escapes repository')
    return path


def archive_inputs(tarball):
    require(tarball.name.endswith('.tar.gz'), 'selected installed payload must be a tar.gz artifact')
    payload, manifest = release.read_verified_payload(tarball)
    return payload, manifest, artifact_byte_digest(tarball)


def bind_sdk(sdk):
    sdk = sdk.expanduser().resolve()
    require(sdk.name.startswith('sts') and sdk == (Path.home() / 'cangjie_sdk' / sdk.name).resolve(),
            'only an explicitly selected installed STS SDK is eligible')
    actual = sdk_binding(sdk)
    stable = json.loads((ROOT / 'docs/evidence/M12-002/source-sdk/stable-native/report.json').read_text())
    require(actual == stable['sdk_files'], 'STS SDK compiler, CJPM, runtime or std/import bytes differ from qualification')
    return actual


def coverage(campaign, reports):
    result = {}
    for family, specification in campaign['families'].items():
        entries = reports.get(family, [])
        seen, passed, failed = {}, {}, []
        for path, report in entries:
            require(report.get('task_id') == 'M12-003' and report.get('family') == family, 'wrong task/family evidence')
            require(type(report.get('seed')) is int, 'native fault seed is missing')
            require(report.get('status') in ('PASS', 'FAIL', 'BLOCKED'), 'unknown native verdict')
            if report['status'] != 'PASS':
                failed.append({'report': path, 'status': report['status']})
            identities = set()
            for profile in report.get('profiles', []):
                name = profile.get('id', profile.get('profile_id'))
                identity = (name, profile.get('round', 0))
                require(name and identity not in identities, 'duplicate/missing profile identity in one native report')
                identities.add(identity)
                keys = profile.get('coverage_keys', [])
                require(isinstance(keys, list) and all(key in specification['required_coverage'] for key in keys),
                        'unknown fault coverage key')
                for key in keys:
                    reference = {'report': path, 'profile': name, 'round': identity[1], 'status': profile['status']}
                    seen.setdefault(key, []).append(reference)
                    if profile['status'] == 'PASS':
                        require(profile.get('semantic_criteria') and all(value is True for value in profile['semantic_criteria'].values()),
                                'passing profile lacks strictly true semantic criteria')
                        cleanup = profile.get('cleanup')
                        require(isinstance(cleanup, dict) and cleanup,
                                'passing profile lacks cleanup proof')
                        if family == 'network':
                            require(cleanup.get('fixture_threads_joined') is True
                                    and cleanup.get('impairments_removed') is True,
                                    'passing network profile lacks successful cleanup predicates')
                        proof = profile.get('applied_fault_proof', profile.get('wire_observation', profile.get('native')))
                        require(proof is not None or profile.get('measurement') is not None, 'passing profile lacks actual native observations')
                        passed.setdefault(key, []).append(reference)
                    else:
                        failed.append(reference)
        missing = sorted(set(specification['required_coverage']) - passed.keys())
        result[family] = {'status': 'PASS' if entries and not missing and not failed else 'FAIL',
                          'required': specification['required_coverage'], 'passing': passed,
                          'missing': missing, 'failures': failed, 'observed': seen}
    return result


def validate_bindings(family, report, sdk_files, archive_digest, payload_fingerprint):
    if family == 'resources':
        archive = report['bindings']['archive_digest']
        fingerprint = report['bindings']['payload_sha256']
        selected = report['sdk']
        require(selected['std_net_digest'] == sdk_files['runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so'], 'resource std.net differs')
        require(selected['compiler_digest'] == sdk_files['bin/cjc'], 'resource compiler differs')
        require(selected['runtime_digest'] == sdk_files['runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'], 'resource runtime differs')
    elif family == 'network':
        archive, fingerprint = report['archive'], report['payload_sha256']
        require(report['sdk_files'] == sdk_files, 'network SDK closure differs')
    else:
        archive, fingerprint = report['archive']['digest'], report['archive']['payload_sha256']
        selected = report['sdk']
        require(selected['compiler_digest'] == sdk_files['bin/cjc'], 'lifecycle compiler differs')
        for name, digest in selected['runtime_file_digests'].items():
            require(digest == sdk_files['runtime/lib/linux_x86_64_cjnative/' + name], 'lifecycle std/runtime differs')
    require(parse_artifact_digest(archive, 'native archive') == parse_artifact_digest(archive_digest, 'selected archive') and schema_artifact_sha256_equal(fingerprint, payload_fingerprint), 'native installed archive differs')
    for field in ('source_digests', 'probe_source_digests', 'execution_source_digests'):
        for name, digest in report.get(field, {}).items():
            require(text_evidence_digest(repository_path(name)) == parse_text_digest(digest, name), 'native execution source changed: ' + name)


def collect(report_paths, retained, sdk, output):
    specification = json.loads(CAMPAIGN.read_text())
    sdk_files = bind_sdk(sdk)
    selected_tarball = repository_path(specification['selected_archive'])
    payload, manifest, tarball_digest = archive_inputs(selected_tarball)
    current, _ = release.collect_payload(ROOT)
    require(payload == current, 'installed archive no longer matches current production/native payload')
    archive_digest = tarball_digest.to_json()
    reports = {}
    for item in report_paths:
        family, name = item.split('=', 1)
        require(family in specification['families'], 'unknown campaign family')
        path = repository_path(name)
        report = json.loads(path.read_text())
        validate_bindings(family, report, sdk_files, archive_digest, manifest['payload_sha256'])
        reports.setdefault(family, []).append((path.relative_to(ROOT).as_posix(), report))
    matrix = coverage(specification, reports)
    task_manifest = json.loads((ROOT / 'tools/tasks/M12-003.json').read_text())
    sources = {name: text_evidence_digest(repository_path(name)).to_json() for name in task_manifest['source_paths'] if name != 'docs/planning/status.md'}
    evidence = {path.relative_to(ROOT).as_posix(): text_evidence_digest(path).to_json()
                for path in sorted(EVIDENCE.rglob('*')) if path.is_file() and path.suffix in ('.json', '.log', '.md')
                and path.resolve() not in (output.resolve(), (EVIDENCE / 'verification.json').resolve())}
    diagnostics = []
    for name in retained:
        path = repository_path(name)
        item = json.loads(path.read_text())
        diagnostics.append({'path': path.relative_to(ROOT).as_posix(), 'status': item.get('status'),
                            'digest': text_evidence_digest(path).to_json()})
    result = {'schema_version': 1, 'task_id': 'M12-003', 'status': 'PASS' if all(item['status'] == 'PASS' for item in matrix.values()) else 'FAIL',
              'sdk_policy': 'STS_ONLY', 'sdk_selection': '$HOME/cangjie_sdk/' + sdk.name,
              'sdk_files': sdk_files, 'archive': archive_digest, 'payload_sha256': manifest['payload_sha256'],
              'provider': manifest['provider'], 'production_source_count': manifest['production_source_files'],
              'families': matrix, 'selected_reports': report_paths, 'retained_diagnostics': diagnostics,
              'source_digests': sources, 'evidence_digests': evidence,
              'formal_release_qualification': 'NOT_QUALIFIED', 'formal_86400': 'NOT_EXECUTED_BY_M12-003'}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
    return result


def verify(path, sdk):
    result = json.loads(path.read_text())
    require(result['task_id'] == 'M12-003' and result['sdk_policy'] == 'STS_ONLY', 'wrong task/SDK policy')
    require(result['status'] == 'PASS', 'required fault campaign did not pass')
    require(result['sdk_files'] == bind_sdk(sdk), 'selected STS closure changed')
    task = json.loads((ROOT / 'tools/tasks/M12-003.json').read_text())
    expected_sources = set(task['source_paths']) - {'docs/planning/status.md'}
    require(set(result['source_digests']) == expected_sources, 'source binding closure is incomplete')
    for field in ('source_digests', 'evidence_digests'):
        for name, digest in result[field].items():
            require(text_evidence_digest(repository_path(name)) == parse_text_digest(digest, name), 'bound input changed: ' + name)
    campaign = json.loads(CAMPAIGN.read_text())
    selected_tarball = repository_path(campaign['selected_archive'])
    payload, manifest, tarball_digest = archive_inputs(selected_tarball)
    current, _ = release.collect_payload(ROOT)
    require(payload == current and parse_artifact_digest(result['archive'], 'selected archive') == tarball_digest, 'production/archive drift')
    reports = {}
    for entry in result['selected_reports']:
        family, name = entry.split('=', 1)
        require(family in campaign['families'], 'unknown campaign family')
        require(name in result['evidence_digests'], 'selected report is absent from evidence closure')
        report = json.loads(repository_path(name).read_text())
        validate_bindings(family, report, result['sdk_files'], result['archive'], result['payload_sha256'])
        reports.setdefault(family, []).append((name, report))
    require(coverage(campaign, reports) == result['families'], 'campaign coverage/verdict changed')
    require(result['formal_release_qualification'] == 'NOT_QUALIFIED' and result['formal_86400'] == 'NOT_EXECUTED_BY_M12-003',
            'short profiles cannot confer formal 86400-second release qualification')
    return {'task_id': 'M12-003', 'status': 'PASS', 'families': len(reports),
            'required_coverage_keys': sum(len(x['required']) for x in result['families'].values()),
            'formal_release_qualification': 'NOT_QUALIFIED'}


def run_campaign(args):
    bind_sdk(args.sdk_root)
    specification = json.loads(CAMPAIGN.read_text())
    rounds = args.rounds if args.rounds is not None else (1 if args.mode == 'smoke' else 3)
    require(1 <= rounds <= 100, 'round count must be between 1 and 100')
    parent = args.scratch.parent.resolve()
    parent.mkdir(parents=True, exist_ok=True)
    filesystem = subprocess.run(['findmnt', '-n', '-T', str(parent), '-o', 'FSTYPE'], check=True, text=True, capture_output=True).stdout.strip()
    require(filesystem not in ('tmpfs', 'ramfs') and shutil.disk_usage(parent).free >= 2 * 1024**3, 'campaign needs disk-backed scratch with at least 2 GiB free')
    args.scratch.mkdir(parents=True, exist_ok=False, mode=0o700)
    args.output.mkdir(parents=True, exist_ok=False)
    cancellation = threading.Event()
    previous = {sig: signal.signal(sig, lambda *_: cancellation.set()) for sig in (signal.SIGINT, signal.SIGTERM)}
    records = []
    try:
        # Stop on the first failed batch; subsequent rounds are not automatic retries.
        for index in range(rounds):
            def execute(family):
                scratch = args.scratch / f'{index}-{family}'
                evidence = args.output / f'{index}-{family}'
                command = [sys.executable, str(repository_path(specification['families'][family]['runner'])),
                           '--sdk-root', str(args.sdk_root), '--archive', str(repository_path(specification['selected_archive'])),
                           '--scratch', str(scratch), '--output', str(evidence), '--seed', str(args.seed + index)]
                if family == 'lifecycle':
                    command += ['--mode', args.mode, '--rounds', '1']
                supervision = run_owned(command, cwd=ROOT, environment=dict(os.environ, TMPDIR=str(args.scratch), TMP=str(args.scratch), TEMP=str(args.scratch)),
                    output=args.scratch / f'{index}-{family}-supervision', timeout_seconds=1200, cancellation=cancellation, grace_seconds=10)
                return {'round': index, 'family': family, 'supervision': supervision, 'report': str(evidence / 'report.json').replace(str(ROOT), '<repo>').replace(str(Path.home()), '$HOME')}
            with ThreadPoolExecutor(max_workers=3) as pool:
                batch = list(pool.map(execute, specification['families']))
            records.extend(batch)
            if cancellation.is_set() or any(item['supervision']['status'] != 'PASS' for item in batch):
                break
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    result = {'task_id': 'M12-003', 'mode': args.mode, 'seed': args.seed, 'auto_retry': False,
              'status': 'PASS' if records and len(records) == rounds * 3 and all(x['supervision']['status'] == 'PASS' for x in records) else 'FAIL',
              'families': records, 'formal_release_qualification': 'NOT_QUALIFIED'}
    (args.output / 'campaign.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('collect', 'verify', 'run'))
    parser.add_argument('--sdk-root', type=Path, default=Path.home() / 'cangjie_sdk/sts1.1.3')
    parser.add_argument('--report', action='append', default=[])
    parser.add_argument('--retained', action='append', default=[])
    parser.add_argument('--output', type=Path, default=EVIDENCE / 'acceptance.json')
    parser.add_argument('--scratch', type=Path)
    parser.add_argument('--mode', choices=('smoke', 'stress'), default='smoke')
    parser.add_argument('--rounds', type=int)
    parser.add_argument('--seed', type=int, default=120003)
    args = parser.parse_args()
    if args.command == 'collect':
        result = collect(args.report, args.retained, args.sdk_root, args.output)
    elif args.command == 'verify':
        result = verify(args.output, args.sdk_root)
        (EVIDENCE / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    else:
        require(args.scratch is not None, 'native campaign requires an explicit disk-backed scratch directory')
        result = run_campaign(args)
    print(json.dumps(result if args.command == 'verify' else {'status': result['status'], 'task_id': 'M12-003'}))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
