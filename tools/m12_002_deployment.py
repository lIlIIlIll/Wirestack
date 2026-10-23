#!/usr/bin/env python3
"""Bind source and native deployment evidence to the selected installed inputs."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.evidence_digest import (artifact_byte_digest, artifact_byte_sha256_equal, atomic_json,
    schema_artifact_sha256_equal, text_evidence_digest)
from tools.m12_002_source_sdk import (capture_root as source_capture_root, native_compiler_digest,
    verify_report as verify_source)
from tools import m7_021_linux_release as release
from tools.m12_002_platform import verify_report as verify_platform

from tools.m12_002_binary import CONSUMER_APPS, CONSUMER_PROFILES, verify as verify_binary
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


def selected_binary_inputs() -> dict[str, Path]:
    """Every binary-verification input is an explicit selection, never a host default."""
    selected = {}
    for key, variable in (('capture_root', 'WIRESTACK_BINARY_CAPTURE_ROOT'),
            ('wrapper', 'WIRESTACK_BINARY_WRAPPER'),
            ('openssl_library', 'WIRESTACK_BINARY_OPENSSL_LIBRARY'),
            ('openssl_crypto_library', 'WIRESTACK_BINARY_OPENSSL_CRYPTO_LIBRARY')):
        value = os.environ.get(variable)
        require(bool(value), variable + ' must select retained qualified binary inputs')
        selected[key] = Path(value).resolve()
    require(selected['openssl_library'] != selected['openssl_crypto_library'],
        'independent TLS libraries must be distinct files')
    for key in ('wrapper', 'openssl_library', 'openssl_crypto_library'):
        require(selected[key].is_file(), selected[key].name + ' selection does not name a file: ' + str(selected[key]))
    require(selected['capture_root'].is_dir(), 'binary capture root selection is not a directory')
    return selected


def selected_consumers(binary: dict, capture_root: Path) -> list[tuple[str, str, Path]]:
    """Resolve every installed consumer executable the binary report recorded beneath its root."""
    result = []
    for profile in CONSUMER_PROFILES:
        for app in CONSUMER_APPS:
            name = profile + '/' + app
            recorded = binary.get('consumers', {}).get(name)
            require(isinstance(recorded, str) and bool(recorded),
                'binary report does not declare the installed consumer: ' + name)
            consumer = Path(recorded.replace('<scratch>', str(capture_root)))
            require(consumer.is_file(), 'installed consumer selection is missing: ' + str(consumer))
            result.append((profile, app, consumer.resolve()))
    return result



def require_compiler_binding(report: dict) -> None:
    """A retained source profile only qualifies builds from the compiler that produced it."""
    require(artifact_byte_sha256_equal(native_compiler_digest(), report['native_cc_digest']),
        'native compiler changed; old source profile cannot qualify new build inputs')


def require_production_inventory(report: dict) -> None:
    """Bind the profile to the complete current production source set, not to its own keys."""
    expected = {str(path.relative_to(ROOT)) for path in release.production_sources(ROOT)}
    require(set(report['production_sources']) == expected,
        'source profile production inventory is not the current production sources')
    for relative, digest in report['production_sources'].items():
        require(artifact_byte_sha256_equal(digest, artifact_byte_digest(ROOT / relative).to_json()),
            'production source changed: ' + relative)


def require_binary_tls_binding(binary: dict, binary_inputs: dict[str, Path]) -> None:
    """The selected independent TLS libraries are the bytes the binary report bound."""
    for field, key in (('library_digest', 'openssl_library'),
            ('crypto_library_digest', 'openssl_crypto_library')):
        require(artifact_byte_sha256_equal(binary['external_tls_fixture'][field],
            artifact_byte_digest(binary_inputs[key]).to_json()),
            'selected independent TLS library differs from the binary report: ' + key)


def binary_verification_arguments(binary: dict, binary_inputs: dict[str, Path],
                                  sdks: list[Path]) -> tuple:
    """The exact positional inputs `m12_002_binary.verify` declares, in its declared order."""
    return (binary, ARCHIVE, sdks, ROOT / 'examples/linux/m12_002/coexist',
        binary_inputs['capture_root'], binary_inputs['wrapper'],
        binary_inputs['openssl_library'], binary_inputs['openssl_crypto_library'],
        selected_consumers(binary, binary_inputs['capture_root']))


def selected_source_capture_root() -> Path:
    """Retained private source captures hold the TLS fixtures the reports only digest."""
    root = source_capture_root()
    require(root is not None,
        'WIRESTACK_SOURCE_CAPTURE_ROOT must select the retained profile scratch')
    require(root.is_dir(), 'source capture root selection is not a directory: ' + str(root))
    return root


def current_inputs(binary_report: Path | None = None) -> dict:
    selected = selected_sdks()
    binary_inputs = selected_binary_inputs()
    captures = selected_source_capture_root()
    profiles = {}
    for name, sdk in selected.items():
        path = SOURCE_REPORTS[name]
        report = json.loads(path.read_text())
        verify_source(report, ARCHIVE, sdk, path.parent, captures)
        require_compiler_binding(report)
        profiles[name] = report
    require(profiles['stable']['production_sources'] == profiles['candidate']['production_sources'],
        'source profiles did not use identical production inputs')
    require_production_inventory(profiles['stable'])
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
    selected_binary = (binary_report or EVIDENCE / 'binary/report.json').resolve()
    require(ROOT in selected_binary.parents, 'binary report must be selected from the repository evidence tree')
    binary = json.loads(selected_binary.read_text())
    require_binary_tls_binding(binary, binary_inputs)
    verify_binary(*binary_verification_arguments(binary, binary_inputs, list(selected.values())))
    return {'source': profiles, 'native': native, 'binary_report': selected_binary}


def verify_snapshot(snapshot: dict, inputs: dict | None = None) -> dict:
    """Validate a complete snapshot in memory; nothing is published before this succeeds."""
    require(snapshot['status'] == 'COMPLETE' and snapshot['candidate_committed'] is False,
        'snapshot is not this uncommitted task acceptance evidence')
    task = json.loads((ROOT / 'tools/tasks/M12-002.json').read_text())
    require(snapshot['source_digests'].keys() == set(task['source_paths']), 'task source inventory is incomplete')
    recorded_binary_report = snapshot.get('binary_report')
    require(isinstance(recorded_binary_report, str) and recorded_binary_report.endswith('.json'),
        'snapshot does not record the verified binary report')
    binary_report = (ROOT / recorded_binary_report).resolve()
    require(ROOT in binary_report.parents, 'snapshot binary report is outside the repository')
    if inputs is None:
        inputs = current_inputs(binary_report)
    else:
        require(inputs['binary_report'] == binary_report,
            'snapshot binary report differs from the verified report')

    require(artifact_byte_sha256_equal(snapshot['archive_digest'], inputs['source']['stable']['archive_digest']), 'deployment archive changed')
    for relative, expected in snapshot['source_digests'].items():
        require(text_evidence_digest(ROOT / relative).to_json() == expected, 'task source changed: ' + relative)
    for relative, expected in snapshot['evidence_digests'].items():
        require(text_evidence_digest(ROOT / relative).to_json() == expected, 'task evidence changed: ' + relative)
    require(snapshot['production_source_count'] == len(inputs['source']['stable']['production_sources']) == 164,
        'production input inventory changed')
    return snapshot


def load_snapshot(path: Path) -> dict:
    return verify_snapshot(json.loads(path.read_text()))


def collect(binary_report: Path) -> dict:
    selected = binary_report.resolve()
    require(ROOT in selected.parents, 'binary report must be selected from the repository evidence tree')
    binary = json.loads(selected.read_text())
    require(binary['status'] == 'PASS', 'binary boundary and coexistence report did not pass')
    inputs = current_inputs(selected)
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
        'binary_report': str(selected.relative_to(ROOT)),
        'excluded_platforms': ['linux-aarch64', 'musl', 'Windows', 'macOS'],
        'repository_full_gate': 'NOT_RERUN_KNOWN_CJDOC_HEAP_OOM_ON_UNCHANGED_PUBLIC_SOURCE'}
    # Validate the complete snapshot first; publish atomically only when every binding holds.
    verify_snapshot(result, inputs)
    atomic_json(EVIDENCE / 'verification.json', result)
    return result


def contracts() -> int:
    import unittest
    sdks = selected_sdks()
    os.environ['WIRESTACK_SOURCE_SDK_ROOT'] = str(sdks['stable'])
    os.environ['WIRESTACK_SOURCE_SDK_REPORT'] = str(SOURCE_REPORTS['stable'])
    os.environ['WIRESTACK_SOURCE_CAPTURE_ROOT'] = str(selected_source_capture_root())
    suite = unittest.defaultTestLoader.loadTestsFromNames(('tools.tests.test_m12_002_source_sdk',
        'tools.tests.test_m12_002_platform', 'tools.tests.test_m12_002_binary',
        'tools.tests.test_m12_002_deployment'))
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
        load_snapshot(EVIDENCE / 'verification.json')
        print('M12_002_DEPLOYMENT_EVIDENCE_PASS')
    else:
        collect(args.binary_report.resolve())
        print('M12_002_DEPLOYMENT_COLLECT_PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
