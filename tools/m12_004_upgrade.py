#!/usr/bin/env python3
"""Build and exercise an isolated dependency candidate; never promote or sign it."""
from __future__ import annotations
import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import build_linux_tls_provider as builder
from tools import evidence_digest as d
from tools import m7_021_linux_release as release
from tools import m7_025_linux_supply_chain as supply
from tools import m7_030_linux_release as signing
from tools.m12_002_source_sdk import sdk_binding
from tools.gates.m12_003_supervision import run_owned

PIN = ROOT / 'docs/references/m12-004-aws-lc-upgrade.json'
SDK_ORACLE = ROOT / 'docs/evidence/M12-002/source-sdk/stable-native/report.json'
INPUTS = ('tools/m12_004_upgrade.py', 'tools/build_linux_tls_provider.py',
    'tools/m7_021_linux_release.py', 'tools/m7_025_linux_supply_chain.py',
    'tools/gates/m12_003_supervision.py', 'native/tls/aws_lc/provider.json',
    'native/tls/aws_lc/wirestack_tls_provider.c', 'native/tls/aws_lc/wirestack_tls_provider.h',
    'tools/tls_provider/abi-v1.json', 'tools/release_smoke/main.cj',
    'docs/references/m12-004-aws-lc-upgrade.json')


def require(condition, code, detail):
    if not condition:
        raise signing.ReleaseError(code, detail)


def selected_manifest(pin):
    baseline = builder.load_provider_manifest(ROOT / 'native/tls/aws_lc/provider.json')
    require(pin.get('scope') == 'NON_PRODUCTION_UPGRADE_REHEARSAL_ONLY' and
        pin.get('qualification') == 'NOT_QUALIFIED' and
        pin.get('production_pin_changed') is False and pin.get('patches') == [],
        'CANDIDATE_SCOPE', 'a reviewed non-production exact pin is required')
    require(pin['baseline']['commit'] == baseline['source']['commit'],
        'BASELINE_PIN_CHANGED', 'reselect and review the upgrade from the current baseline')
    require(pin['source']['url'] == baseline['source']['url'] and pin['provider_id'] == baseline['provider_id'],
        'UPSTREAM_SOURCE', 'candidate upstream must be the accepted provider repository')
    manifest = copy.deepcopy(baseline)
    manifest['provider_version'] = pin['provider_version']
    manifest['source'] = dict(pin['source'])
    return manifest


def validate_sdk(sdk):
    sdk = sdk.resolve()
    require(sdk.name.startswith('sts'), 'STS_REQUIRED', 'select an explicit installed STS SDK root')
    current = sdk_binding(sdk)
    prior = json.loads(SDK_ORACLE.read_text())
    require(prior.get('status') == 'PASS' and current == prior.get('sdk_files'),
        'SDK_NOT_QUALIFIED', 'SDK compiler/runtime/import closure differs from accepted STS qualification')
    return current


class Capture:
    def __init__(self, work, output, sdk):
        self.work, self.output, self.sdk = work, output, sdk
        self.commands = []
        self.environment = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work))
        self.replacements = sorted(((str(ROOT), '<repo>'), (str(work), '<scratch>'),
            (str(sdk), '<sts-sdk>'), (str(Path.home()), '$HOME')),
            key=lambda pair: -len(pair[0]))

    def normalize(self, text):
        for actual, label in self.replacements:
            text = text.replace(actual, label)
        return text.replace('127.0.0.1', '192.0.2.1')

    def run(self, label, argv, cwd, timeout=600, hidden=False):
        if hidden:
            argv = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', str(self.work), str(self.work),
                '--tmpfs', str(ROOT), '--chdir', str(cwd), '--', *map(str, argv)]
        raw = self.work / ('command-' + label)
        record = run_owned(list(map(str, argv)), cwd=cwd, environment=self.environment,
            timeout_seconds=timeout, output=raw)
        for name in ('stdout', 'stderr'):
            path = self.output / (label + '.' + name + '.log')
            path.write_text(self.normalize((raw / (name + '.raw')).read_text(errors='replace')))
            record[name] = {'path': path.relative_to(ROOT).as_posix(), 'digest': d.text_evidence_digest(path).to_json()}
        record.update(id=label, argv=[self.normalize(str(value)) for value in argv],
            cwd=self.normalize(str(cwd)), checkout_hidden=hidden)
        self.commands.append(record)
        require(record['status'] == 'PASS',
            'UPGRADE_COMMAND_FAILED', label + ' failed; retained diagnostics')
        return (self.output / (label + '.stdout.log')).read_text()


def build_candidate(args, report):
    work, output, sdk = args.work_root.resolve(), args.output.resolve(), args.sdk_root.resolve()
    require(work != ROOT and ROOT not in work.parents, 'WORKSPACE_ISOLATION', 'work root must be outside the repository')
    require(not work.exists(), 'WORKSPACE_EXISTS', 'use a new task-owned work directory')
    report['sdk_files'] = validate_sdk(sdk)
    work.mkdir(parents=True, mode=0o700)
    output.mkdir(parents=True, exist_ok=True)
    capture = Capture(work, output, sdk)
    report['commands'] = capture.commands
    wrapper = Path.home() / '.codex/scripts/codex_cangjie_env'
    invoke = [str(wrapper), '--sdk-root', str(sdk), '--']
    toolchain = {name: capture.run(name + '-version', [*invoke, name, '--version'], work, 30).splitlines()
        for name in ('cjc', 'cjpm')}
    pin = json.loads(PIN.read_text())
    manifest = selected_manifest(pin)
    identity = builder.verify_source(args.source_dir.resolve(), manifest)
    before_payload, before_manifest = release.collect_payload(ROOT)
    baseline = work / 'before.tar.gz'
    release.write_reproducible_archive(baseline, before_payload)
    report['before'] = {'archive': d.artifact_byte_digest(baseline).to_json(),
        'payload_digest': d.ArtifactByteDigest(before_manifest['payload_sha256']).to_json(),
        'provider': before_manifest['provider']}
    package = release.extract_archive(baseline, work / 'package')
    tools = {name: builder.resolve_tool(None, preferred, fallback) for name, preferred, fallback in
        [('cc', '/usr/lib/llvm15/bin/clang', 'clang'), ('cxx', '/usr/lib/llvm15/bin/clang++', 'clang++'),
         ('cmake', '/usr/bin/cmake', 'cmake'), ('ar', '/usr/lib/llvm15/bin/llvm-ar', 'llvm-ar'),
         ('ranlib', '/usr/lib/llvm15/bin/llvm-ranlib', 'llvm-ranlib')]}
    tools.update({name + '_version': builder.tool_version(path) for name, path in list(tools.items())})
    native, produced = builder.build_provider(ROOT, args.source_dir.resolve(), identity, manifest,
        ROOT / 'tools/tls_provider/abi-v1.json', work / 'native', tools, builder.platform_identity())
    shutil.copytree(native, package / 'target/native/current', dirs_exist_ok=True)
    shutil.copyfile(args.source_dir / 'LICENSE', package / 'third_party/aws-lc/LICENSE')
    baseline_pin = builder.load_provider_manifest(ROOT / 'native/tls/aws_lc/provider.json')
    notices = package / 'THIRD_PARTY_NOTICES.md'
    text = notices.read_text()
    old_identity = ('Wirestack release artifacts include AWS-LC ' + baseline_pin['provider_version'] +
        ' as a statically linked TLS\nprovider. The provider source is pinned to commit\n' + chr(96) +
        baseline_pin['source']['commit'] + chr(96) + '.\n')
    new_identity = old_identity.replace(baseline_pin['provider_version'], manifest['provider_version']).replace(
        baseline_pin['source']['commit'], manifest['source']['commit'])
    require(text.count(old_identity) == 1, 'NOTICES_IDENTITY', 'baseline provider notice identity changed')
    notices.write_text(text.replace(old_identity, new_identity))
    payload, embedded = release.collect_payload(package)
    artifact = output / 'candidate.tar.gz'
    release.write_reproducible_archive(artifact, payload)
    installed = release.extract_archive(artifact, work / 'install')
    report['candidate'] = {'artifact': {'path': artifact.relative_to(ROOT).as_posix(),
        'digest': d.artifact_byte_digest(artifact).to_json(), 'bytes': artifact.stat().st_size},
        'payload_digest': d.ArtifactByteDigest(embedded['payload_sha256']).to_json(),
        'provider': produced, 'source_identity': identity,
        'package_source_digest': d.TextEvidenceDigest(release.source_tree_sha256(installed)).to_json(),
        'production_source_files': embedded['production_source_files'], 'pin': manifest}
    consumer = work / 'consumer'
    (consumer / 'src').mkdir(parents=True)
    (consumer / 'cjpm.toml').write_text(release.consumer_manifest(installed))
    shutil.copyfile(release.SMOKE_FIXTURE, consumer / 'src/main.cj')
    capture.run('consumer-build', [*invoke, 'cjpm', 'build'], consumer, hidden=True)
    binary = consumer / 'target/release/bin/main'
    observed = capture.run('consumer-https-http2', [*invoke, str(binary)], consumer, 60, hidden=True)
    release.validate_smoke_output(observed, provider_version=manifest['provider_version'])
    dependency_text = capture.run('consumer-needed', ['readelf', '-d', str(binary)], consumer, 30)
    needed = release.parse_needed(dependency_text)
    release.reject_openssl_dependencies(needed)
    report['consumer'] = {'status': 'PASS', 'binary': d.artifact_byte_digest(binary).to_json(),
        'checkout_hidden': True, 'provider_version': manifest['provider_version'], 'needed': needed}
    qualification = {'artifact': {'name': artifact.name, 'sha256': d.artifact_byte_sha256(artifact),
            'bytes': artifact.stat().st_size, 'payload_sha256': embedded['payload_sha256']},
        'platform': embedded['target'], 'runtime': {'providerBuildFingerprint': produced['build_fingerprint']},
        'toolchain': toolchain, 'dependency_scan': {'needed': needed}}
    documents = supply.build_documents(artifact, qualification, manifest,
        generator_sha256=d.text_evidence_sha256(ROOT / 'tools/m7_025_linux_supply_chain.py'),
        task_id='M12-004', created_utc=datetime.now(timezone.utc).isoformat())
    supply.write_documents(documents, output / 'supply-chain')
    report['supply_chain'] = {name: d.text_evidence_digest(output / 'supply-chain' / name).to_json() for name in documents}
    report['toolchain'] = toolchain
    require(report['source_digests'] == {name: d.text_evidence_digest(ROOT / name).to_json() for name in INPUTS},
        'SOURCE_CHANGED', 'rehearsal inputs changed during execution')
    require(report['sdk_files'] == sdk_binding(sdk), 'SDK_CHANGED', 'SDK changed during execution')
    report['status'] = 'PASS'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', required=True, type=Path)
    parser.add_argument('--sdk-root', required=True, type=Path)
    parser.add_argument('--work-root', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/evidence/M12-004/upgrade')
    args = parser.parse_args()
    report = {'schema_version': 1, 'task_id': 'M12-004', 'family': 'upgrade', 'status': 'FAIL',
        'sdk_policy': 'STS_ONLY', 'qualification': 'NOT_QUALIFIED', 'production_pin_changed': False,
        'source_committed': False, 'signing_authorized': False,
        'source_digests': {name: d.text_evidence_digest(ROOT / name).to_json() for name in INPUTS},
        'scope': 'Fresh isolated native dependency rebuild, clean installed HTTPS/HTTP2 consumer and regenerated SPDX; not formal qualification.'}
    try:
        build_candidate(args, report)
    except (OSError, ValueError, RuntimeError) as error:
        report.update(error=getattr(error, 'code', type(error).__name__),
            detail=str(error).replace(str(ROOT), '<repo>').replace(str(args.work_root), '<scratch>').replace(str(Path.home()), '$HOME'))
    args.output.mkdir(parents=True, exist_ok=True)
    signing.atomic_json(args.output / 'report.json', report)
    print(json.dumps({'task_id': 'M12-004', 'family': 'upgrade', 'status': report['status'],
        'qualification': report['qualification'], 'error': report.get('error')}, sort_keys=True))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
