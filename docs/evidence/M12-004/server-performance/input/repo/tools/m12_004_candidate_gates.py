#!/usr/bin/env python3
"""Run immutable installed candidate development gates with the qualified STS SDK."""
from __future__ import annotations
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import shutil
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import evidence_digest as d
from tools import m7_021_linux_release as release
from tools import m8_006_native_tls as tls
from tools import m12_004_upgrade as upgrade
from tools.benchmarks import m12_001_end_to_end as bench
from tools.gates import m7_023_linux_fuzz as fuzz
from tools.gates import m7_024_linux_performance as performance

BASELINE_SHA = 'e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f'
TEST_FILES = ('src/internal/tls_engine/m3_028_fuzz_test.cj',
              'src/internal/tls_engine/tls_identity_fixture_test.cj',
              'src/internal/trust/m3_028_hostname_fuzz_test.cj',
              'src/internal/http1/smuggling_corpus_test.cj',
              'src/internal/http2/deterministic_fuzz_test.cj',
              'src/http/deterministic_fuzz_test.cj')


def inventory(installed, payload):
    return {name: d.artifact_byte_digest(installed / name).to_json() for name in sorted(payload)}


def assert_unchanged(installed, payload, before):
    if inventory(installed, payload) != before or (installed / 'build.cj').exists():
        raise ValueError('installed candidate production/native payload changed')


def overlay(root, installed, targets):
    copied = {}
    for name in TEST_FILES:
        source, destination = root / name, installed / name
        if destination.exists():
            raise ValueError('test overlay collides with installed payload')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied[name] = d.text_evidence_digest(source).to_json()
    for target in targets:
        name = target['corpus']
        destination = installed / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
        copied[name] = d.text_evidence_digest(destination).to_json()
    return copied


class Runner(bench.Campaign):
    def run(self, name, argv, cwd, timeout=90, sampled=False, check=True):
        if argv[0] == 'cjpm':
            argv = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/',
                    '--bind', str(self.work), str(self.work), '--tmpfs', str(ROOT),
                    '--chdir', str(cwd), '--', *argv]
        return super().run(name, argv, cwd, timeout, sampled, check)

    def artifact(self, path):
        return {'path': path.relative_to(ROOT).as_posix(),
                'digest': d.text_evidence_digest(path).to_json()}

    def tls_command(self, argv, cwd, output, name, timeout, records, expected_exit=0):
        text, record = self.run(name, list(argv), cwd, timeout, check=False)
        # Existing TLS helpers require their original deterministic filenames.
        for kind in ('stdout', 'stderr'):
            source = self.output / Path(record[kind]['path']).name
            destination = output / f'{name}.{kind}.log'
            shutil.copy2(source, destination)
        records.append(record)
        if record['timed_out'] or record['exit_code'] != expected_exit:
            raise RuntimeError(f'{name} failed')


def tls_gate(runner, installed):
    consumer = runner.work / 'tls-consumer'
    (consumer / 'src').mkdir(parents=True)
    (consumer / 'cjpm.toml').write_text(release.consumer_manifest(installed).replace('wirestack_release_smoke', 'wirestack_m8_006_native_tls'))
    shutil.copy2(tls.SOURCE, consumer / 'src/main.cj')
    runner.run('tls-build', ['cjpm', 'build'], consumer, 600)
    binary = consumer / 'target/release/bin/main'
    results, records = [], []
    with patch.object(tls, 'command', runner.tls_command), patch.object(tls, 'artifact', runner.artifact):
        identity = tls.create_identity(runner.work, runner.output, records)
        for mode in tls.RELEASE_MODES:
            try:
                if mode.startswith('decrypt-'):
                    item = tls.decrypt_peer(binary, mode, identity, runner.output, records)
                else:
                    selected = identity
                    if mode == 'reject-non-rsa':
                        ec = runner.work / 'elliptic'
                        ec.mkdir()
                        selected = tls.create_identity(ec, runner.output, records, elliptic=True)
                    runner.tls_command([str(binary), mode, *map(str, selected[:3])], binary.parent,
                                       runner.output, 'consumer-' + mode, 30, records)
                    tls.require_marker(runner.output / f'consumer-{mode}.stdout.log', mode)
                    item = {'mode': mode, 'status': 'PASS', 'marker': tls.marker(mode)}
                results.append(item)
            except Exception as error:
                results.append({'mode': mode, 'status': 'FAIL', 'error': runner.redact(str(error))})
    # decrypt_peer writes unnormalized output; normalize before binding final digests.
    for path in runner.output.glob('*.log'):
        path.write_text(runner.redact(path.read_text()))
    runner.commands.extend(record for record in records if record not in runner.commands)
    return {'status': 'PASS' if all(x['status'] == 'PASS' for x in results) else 'FAIL',
            'scenarios': results, 'binary': d.artifact_byte_digest(binary).to_json()}


def performance_gate(runner, installations):
    binaries = {}
    result = {'status': 'INCOMPLETE', 'samples': {}, 'summaries': {}, 'comparisons': {}}
    environment = runner.environment()
    environment['TLS'] = 'Static archive-bound AWS-LC baseline 5.5.0 versus candidate 5.11.0'
    environment['optimization'] = 'Identical installed dependency flags; -O2 consumer'
    result['environment'] = environment
    runner.certificates()
    for label, installed in installations.items():
        binaries[label] = {}
        result['samples'][label] = []
        for layer in bench.CASES:
            consumer = runner.work / (label + '-' + layer)
            (consumer / 'src').mkdir(parents=True)
            (consumer / 'cjpm.toml').write_text(release.consumer_manifest(installed).replace('wirestack_release_smoke', 'wirestack_m12_001').replace('compile-option = ""', 'compile-option = "-O2"', 1))
            for source, name in ((bench.SOURCES / 'common.cj', 'common.cj'), (bench.SOURCES / f'{layer}.cj', 'main.cj')):
                shutil.copy2(source, consumer / 'src' / name)
            runner.run(label + '-' + layer + '-build', ['cjpm', 'build'], consumer, 600)
            binaries[label][layer] = consumer / 'target/release/bin/main'
            result.setdefault('binary_bindings', {}).setdefault(label, {})[layer] = d.artifact_byte_digest(binaries[label][layer]).to_json()
    order = [(layer, case) for layer, cases in bench.CASES.items() for case in cases]
    for round_number in range(-1, 7):
        for layer, case in order if round_number % 2 == 0 else reversed(order):
            labels = ('baseline', 'candidate') if round_number % 2 == 0 else ('candidate', 'baseline')
            for label in labels:
                temp = {'samples': result['samples'][label]}
                try:
                    runner.sample(temp, binaries[label][layer], layer, case, max(0, round_number), round_number < 0)
                except Exception as error:
                    result.setdefault('failures', []).append({'artifact': label, 'case': case,
                        'round': round_number, 'error': runner.redact(str(error))})
                (runner.output / 'performance-progress.json').write_text(runner.redact(json.dumps(result, indent=2)) + '\n')
    if result.get('failures'):
        result['status'] = 'FAIL'
        return result
    for label in installations:
        grouped = defaultdict(list)
        for row in result['samples'][label]:
            if not row['warmup']:
                grouped[row['scenario']].append(row)
        result['summaries'][label] = {case: bench.summarize(rows) for case, rows in grouped.items()}
    for case in result['summaries']['baseline']:
        baseline = result['summaries']['baseline'][case]
        candidate = result['summaries']['candidate'][case]
        result['comparisons'][case] = bench.classify(bench.freeze_reference(baseline), candidate)
    limits = json.loads((ROOT / 'tools/gates/campaigns/m7-024-linux-performance.json').read_text())['thresholds']['tls']
    domain = performance.DomainResult('candidate-tls-baseline-ratios')
    before, after = result['summaries']['baseline'], result['summaries']['candidate']
    domain.check('bulk throughput ratio', after['tls_bulk']['successful_bytes_per_second'] / before['tls_bulk']['successful_bytes_per_second'], 'ge', limits['minimum_bulk_throughput_ratio'])
    for percentile in ('p50', 'p95'):
        domain.check('full handshake ' + percentile, after['tls_full'][percentile + '_ns'] / before['tls_full'][percentile + '_ns'], 'le', limits['maximum_full_handshake_' + percentile + '_ratio'])
    result['m7_024_tls_thresholds'] = domain.report()
    statuses = {x['status'] for x in result['comparisons'].values()}
    result['status'] = 'FAIL' if 'FAIL' in statuses or domain.report()['decision'] == 'FAIL' else 'NOISY' if 'NOISY' in statuses else 'INCONCLUSIVE' if 'INCONCLUSIVE' in statuses else 'PASS'
    result['formal_m7_024'] = {'status': 'NOT_RUN', 'reason': 'Historical stdx/network/memory campaigns are not relabeled as this paired installed development campaign'}
    return result


def execute(args):
    sdk = args.sdk_root.resolve()
    if Path(os.environ.get('CANGJIE_HOME', '')).resolve() != sdk:
        raise ValueError('invoke through codex_cangjie_env --sdk-root with selected STS')
    report = {'schema_version': 1, 'task_id': 'M12-004', 'family': 'candidate-gates',
              'status': 'INCOMPLETE', 'qualification': 'NOT_QUALIFIED', 'sdk_files': upgrade.validate_sdk(sdk),
              'soak': {'status': 'NOT_RUN', 'formal_seconds': 86400, 'reason': 'Formal source freeze and soak authorization missing'},
              'matrix': {'status': 'NOT_RUN', 'supported_executed': ['Linux x86_64 glibc STS 1.1.3 current host'], 'missing': ['Westmere minimum CPU / kernel 5.15 / glibc 2.44', 'independent namespace coexistence']},
              'qualification_prerequisites': ['formal source freeze', 'independent source-bound security review approval', '86400-second formal soak', 'release/signing authorization', 'full supported platform matrix']}
    report['formal_qualification'] = {
        'source_freeze': {'status': 'NOT_RUN'},
        'independent_review_approval': {'status': 'BLOCKED', 'reason': 'Requires approved disposition of current source-bound findings'},
        'release_signing_authorization': {'status': 'BLOCKED', 'reason': 'No release or signing authorization'}}
    if args.work_root.exists():
        raise ValueError('use a new task-owned scratch directory')
    runner = Runner(args.output, args.work_root)
    report['commands'] = runner.commands
    payload, manifest = release.read_verified_payload(args.artifact)
    upgrade_report = json.loads((ROOT / 'docs/evidence/M12-004/upgrade/report.json').read_text())
    expected = upgrade_report['candidate']['artifact']['digest']
    if d.artifact_byte_digest(args.artifact).to_json() != expected:
        raise ValueError('candidate differs from verified upgrade archive')
    if d.artifact_byte_digest(args.baseline).sha256 != BASELINE_SHA:
        raise ValueError('baseline is not exact previous archive')
    report['archive'] = d.artifact_byte_digest(args.artifact).to_json()
    report['baseline_archive'] = d.artifact_byte_digest(args.baseline).to_json()
    report['provider'] = manifest['provider']
    installed = release.extract_archive(args.artifact, runner.work / 'candidate-install')
    baseline_payload, _ = release.read_verified_payload(args.baseline)
    baseline = release.extract_archive(args.baseline, runner.work / 'baseline-install')
    before = inventory(installed, payload)
    baseline_before = inventory(baseline, baseline_payload)
    report['installed_payload_before'] = before
    production = {str(p.relative_to(ROOT)): d.artifact_byte_digest(p).to_json() for p in release.production_sources(ROOT)}
    for name, digest in production.items():
        if name not in before or digest != before[name]:
            raise ValueError('current production source differs from candidate: ' + name)
    report['production_sources'] = production
    inputs = [Path(__file__), tls.SOURCE, ROOT / 'tools/gates/campaigns/m7-023-linux-fuzz.json',
              ROOT / 'tools/gates/campaigns/m7-024-linux-performance.json', *bench.SOURCES.glob('*.cj'),
              *(ROOT / name for name in TEST_FILES), *(ROOT / 'fuzz/corpus/m7-023/v1').glob('*.hex')]
    report['gate_inputs'] = {p.relative_to(ROOT).as_posix(): d.text_evidence_digest(p).to_json() for p in inputs}
    for name, action in [('tls', lambda: tls_gate(runner, installed)),
                         ('fuzz', lambda: fuzz_gate(runner, installed, report)),
                         ('performance', lambda: performance_gate(runner, {'baseline': baseline, 'candidate': installed}))]:
        try:
            assert_unchanged(installed, payload, before)
            report[name] = action()
        except Exception as error:
            report[name] = {'status': 'FAIL', 'error': runner.redact(str(error))}
        finally:
            try:
                assert_unchanged(installed, payload, before)
                assert_unchanged(baseline, baseline_payload, baseline_before)
            except Exception as error:
                report['integrity'] = {'status': 'FAIL', 'error': runner.redact(str(error))}
                report['status'] = 'FAIL'
                write_report(args.output / 'report.json', report, runner)
                return 1
            write_report(args.output / 'report.json', report, runner)
    report['installed_payload_after'] = inventory(installed, payload)
    report['production_sources_unchanged'] = production == {str(p.relative_to(ROOT)): d.artifact_byte_digest(p).to_json() for p in release.production_sources(ROOT)}
    report['final_bindings'] = {'archive': d.artifact_byte_digest(args.artifact).to_json(),
        'baseline_archive': d.artifact_byte_digest(args.baseline).to_json(), 'sdk_files': upgrade.validate_sdk(sdk),
        'gate_inputs': {p.relative_to(ROOT).as_posix(): d.text_evidence_digest(p).to_json() for p in inputs}}
    report['bindings_unchanged'] = report['production_sources_unchanged'] and all(
        report[key] == value for key, value in report['final_bindings'].items())
    report['status'] = 'FAIL' if not report['bindings_unchanged'] or any(report[name]['status'] == 'FAIL' for name in ('tls', 'fuzz', 'performance')) else 'COMPLETE_NOT_QUALIFIED'
    write_report(args.output / 'report.json', report, runner)
    return 1 if report['status'] == 'FAIL' else 0


def fuzz_gate(runner, installed, report):
    manifest, targets = fuzz.load_manifest(ROOT, ROOT / 'tools/gates/campaigns/m7-023-linux-fuzz.json')
    report['test_overlay'] = overlay(ROOT, installed, targets)
    runner.run('fuzz-build', fuzz.build_command(), installed, 1200)
    with patch.dict(os.environ, runner.env):
        results = [fuzz.execute_target(installed, target, manifest['seed']) for target in targets]
    return {'status': 'PASS' if all(item['decision'] == 'PASS' for item in results) else 'FAIL',
            'manifest': d.text_evidence_digest(ROOT / 'tools/gates/campaigns/m7-023-linux-fuzz.json').to_json(), 'targets': results}


def write_report(path, report, runner):
    # Refresh digests after normalization by TLS helper; retain native raw logs only in private scratch.
    def refresh(value):
        if isinstance(value, dict):
            if 'path' in value and 'digest' in value:
                log = runner.output / Path(value['path']).name
                if log.is_file():
                    value['digest'] = d.text_evidence_digest(log).to_json()
            for child in value.values():
                refresh(child)
        elif isinstance(value, list):
            for child in value:
                refresh(child)
    refresh(report)
    path.write_text(runner.redact(json.dumps(report, indent=2, default=str)) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', dest='artifact', type=Path, default=ROOT / 'docs/evidence/M12-004/upgrade/candidate.tar.gz')
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--sdk-root', type=Path, required=True)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/evidence/M12-004/candidate-gates')
    return execute(parser.parse_args(argv))

if __name__ == '__main__':
    raise SystemExit(main())
