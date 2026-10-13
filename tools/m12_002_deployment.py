#!/usr/bin/env python3
"""Bind source and native deployment evidence to the selected installed inputs."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.evidence_digest import artifact_byte_digest, artifact_byte_sha256_equal, schema_artifact_sha256_equal, text_evidence_digest
from tools.m12_002_source_sdk import verify_report as verify_source
from tools.m12_002_platform import verify_report as verify_platform

from tools.m12_002_binary import verify as verify_binary
EVIDENCE = ROOT / 'docs/evidence/M12-002'
ARCHIVE = ROOT / 'docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz'
SOURCE_REPORTS = {'stable': EVIDENCE / 'source-sdk/stable-native/report.json',
    'candidate': EVIDENCE / 'source-sdk/candidate-native/report.json'}
PLATFORM_REPORT = EVIDENCE / 'platform/westmere-glibc244/report.json'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def selected_sdks() -> dict[str, Path]:
    result = {}
    for name in SOURCE_REPORTS:
        value = os.environ.get(f'WIRESTACK_{name.upper()}_SDK_ROOT')
        require(bool(value), f'WIRESTACK_{name.upper()}_SDK_ROOT must select the exact SDK to verify')
        result[name] = Path(value).resolve()
    return result


def current_inputs() -> dict:
    profiles = {}
    for name, sdk in selected_sdks().items():
        path = SOURCE_REPORTS[name]
        report = json.loads(path.read_text())
        verify_source(report, ARCHIVE, sdk, path.parent)
        require(artifact_byte_digest(Path(shutil.which('cc'))).to_json() == report['native_cc_digest'],
            'native compiler changed; old source profile cannot qualify new build inputs')
        profiles[name] = report
    require(profiles['stable']['production_sources'] == profiles['candidate']['production_sources'],
        'source profiles did not use identical production inputs')
    for relative, expected in profiles['stable']['production_sources'].items():
        require(artifact_byte_digest(ROOT / relative).to_json() == expected, 'production source changed: ' + relative)
    for relative, expected in profiles['stable']['native_archives'].items():
        require(artifact_byte_digest(ROOT / relative).to_json() == expected, 'native archive changed: ' + relative)
    native = json.loads(PLATFORM_REPORT.read_text())
    verify_platform(native, PLATFORM_REPORT.parent, profiles['stable'])
    require(native['glibc'] == 'glibc 2.44' and native['kernel'] == '5.15.0-198-generic',
        'minimum profile changed; select and execute a new deployment cell')
    require(schema_artifact_sha256_equal(native['installed_payload_verified'], profiles['stable']['payload_sha256']),
        'native VM did not validate the selected installed payload')
    require(native['image']['selected_glibc']['namespace_runner_digest'] ==
        text_evidence_digest(ROOT / 'tools/m12_002_glibc_namespace.py').to_json(), 'runtime namespace runner changed')
    capture_root = os.environ.get('WIRESTACK_BINARY_CAPTURE_ROOT')
    require(bool(capture_root), 'WIRESTACK_BINARY_CAPTURE_ROOT must select retained qualified binary inputs')
    verify_binary(json.loads((EVIDENCE / 'binary/report.json').read_text()), ARCHIVE, list(selected_sdks().values()),
        ROOT / 'examples/linux/m12_002/coexist', Path(capture_root).resolve())
    return {'source': profiles, 'native': native}


def verify_snapshot(path: Path) -> dict:
    snapshot = json.loads(path.read_text())
    require(snapshot['status'] == 'COMPLETE' and snapshot['candidate_committed'] is False,
        'snapshot is not this uncommitted task acceptance evidence')
    task = json.loads((ROOT / 'tools/tasks/M12-002.json').read_text())
    require(snapshot['source_digests'].keys() == set(task['source_paths']), 'task source inventory is incomplete')
    inputs = current_inputs()
    require(artifact_byte_sha256_equal(snapshot['archive_digest'], inputs['source']['stable']['archive_digest']), 'deployment archive changed')
    for relative, expected in snapshot['source_digests'].items():
        require(text_evidence_digest(ROOT / relative).to_json() == expected, 'task source changed: ' + relative)
    for relative, expected in snapshot['evidence_digests'].items():
        require(text_evidence_digest(ROOT / relative).to_json() == expected, 'task evidence changed: ' + relative)
    require(snapshot['production_source_count'] == len(inputs['source']['stable']['production_sources']) == 164,
        'production input inventory changed')
    return snapshot


def collect(binary_report: Path) -> dict:
    inputs = current_inputs()
    binary = json.loads(binary_report.read_text())
    require(binary['status'] == 'PASS', 'binary boundary and coexistence report did not pass')
    task = json.loads((ROOT / 'tools/tasks/M12-002.json').read_text())
    paths = sorted(path for path in EVIDENCE.rglob('*') if path.is_file() and path.suffix in ('.json', '.log', '.md')
        and path not in (EVIDENCE / 'verification.json', EVIDENCE / 'task-gate.json'))
    result = {'schema_version': 1, 'task_id': 'M12-002', 'status': 'COMPLETE',
        'candidate_committed': False, 'committed_source_seal': 'NOT_REQUESTED', 'release_qualification': 'NOT_QUALIFIED',
        'archive_digest': inputs['source']['stable']['archive_digest'], 'production_source_count': 164,
        'source_digests': {name: text_evidence_digest(ROOT / name).to_json() for name in task['source_paths']},
        'evidence_digests': {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json() for path in paths},
        'native_minimum_profile': {'cpu': inputs['native']['cpu_model'], 'glibc': inputs['native']['glibc'],
            'kernel': inputs['native']['kernel'], 'same_binary_checks': 47, 'rebuilt_checks': 47},
        'binary_report': str(binary_report.relative_to(ROOT)),
        'excluded_platforms': ['linux-aarch64', 'musl', 'Windows', 'macOS'],
        'repository_full_gate': 'NOT_RERUN_KNOWN_CJDOC_HEAP_OOM_ON_UNCHANGED_PUBLIC_SOURCE'}
    (EVIDENCE / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    verify_snapshot(EVIDENCE / 'verification.json')
    return result


def contracts() -> int:
    import unittest
    os.environ['WIRESTACK_SOURCE_SDK_ROOT'] = str(selected_sdks()['stable'])
    os.environ['WIRESTACK_SOURCE_SDK_REPORT'] = str(SOURCE_REPORTS['stable'])
    suite = unittest.defaultTestLoader.loadTestsFromNames(('tools.tests.test_m12_002_source_sdk',
        'tools.tests.test_m12_002_platform', 'tools.tests.test_m12_002_binary'))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('verify')
    sub.add_parser('contracts')
    capture = sub.add_parser('collect')
    capture.add_argument('--binary-report', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'contracts':
        return contracts()
    if args.action == 'verify':
        verify_snapshot(EVIDENCE / 'verification.json')
        print('M12_002_DEPLOYMENT_EVIDENCE_PASS')
    else:
        collect(args.binary_report.resolve())
        print('M12_002_DEPLOYMENT_COLLECT_PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
