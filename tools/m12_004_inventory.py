#!/usr/bin/env python3
"""Inventory an existing release payload without qualifying or signing it."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import evidence_digest as d
from tools import m7_021_linux_release as release
from tools import m7_025_linux_supply_chain as supply
from tools.m12_002_source_sdk import sdk_binding


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalized(value):
    return str(value).replace(str(ROOT), '<repo>').replace(str(Path.home()), '$HOME')


def validate_symbols(header, symbols, prefix):
    declared = set(re.findall(r'\b(' + re.escape(prefix) + r'\w+)\s*\(', header))
    require(declared and declared == set(symbols), 'public symbol declaration drift')


def validate_components(metadata, payload, source_root):
    """Reuse the supply-chain consistency rules, not historical qualification."""
    provider = metadata['provider']
    manifest = metadata['release']
    consistency = {'artifact': {'sha256': metadata['artifact_sha256'],
        'bytes': metadata['artifact_bytes'], 'payload_sha256': manifest['payload_sha256']},
        'platform': manifest['target'],
        'runtime': {'providerBuildFingerprint': provider['build_fingerprint']}}
    supply.validate_artifact_inputs(metadata, consistency, provider['build_inputs']['provider'])
    require(provider.get('test_only_key_log') is False and
        provider['build_inputs'].get('test_only_key_log') is False, 'keylog artifact rejected')
    sources = {
        'native/tls/aws_lc/wirestack_tls_provider.c': provider['build_inputs']['shim']['source_sha256'],
        'native/tls/aws_lc/wirestack_tls_provider.h': provider['build_inputs']['shim']['header_sha256'],
        'native/resolver/linux/wirestack_resolver.c': metadata['resolver']['inputs']['source_sha256'],
        'native/resolver/linux/wirestack_resolver.h': metadata['resolver']['inputs']['header_sha256'],
        **metadata['http_files']['inputs']['sources']}
    for name, sha in sources.items():
        require(d.text_evidence_digest(source_root / name).sha256 == sha, 'native source drift: ' + name)
    gzip = next((x for x in manifest.get('optionalModules', []) if x.get('package') == 'wirestack.gzip'), None)
    require(gzip is not None and gzip.get('nativeDependencies') == [] and
        gzip.get('implementation') == 'wirestack-cangjie-rfc1951-rfc1952' and
        gzip.get('selection') == 'explicit-package-import', 'gzip native dependency or selection drift')
    actual = sorted(x for x in payload if x.startswith('src/gzip/') and x.endswith('.cj'))
    require(actual == sorted(x['path'] for x in gzip['sources']), 'gzip source inventory drift')
    for item in gzip['sources']:
        require(d.text_evidence_sha256_equal(item['sha256'],
            d.text_evidence_digest_bytes(payload[item['path']]).to_json()), 'gzip source digest drift')
    return sources, gzip


def intake(output, versions):
    channels = {'latest': 'https://api.github.com/repos/aws/aws-lc/releases/latest',
        'repository-advisories': 'https://api.github.com/repos/aws/aws-lc/security-advisories',
        'security-policy': 'https://raw.githubusercontent.com/aws/aws-lc/main/SECURITY.md',
        'aws-security-bulletins': 'https://aws.amazon.com/security/security-bulletins/'}
    for version in sorted(set(versions)):
        channels['release-' + version] = 'https://api.github.com/repos/aws/aws-lc/releases/tags/v' + version
    records = []
    for name, url in channels.items():
        row = {'channel': name, 'url': url, 'intake_utc': datetime.now(timezone.utc).isoformat(),
            'assessment': 'NOT_ASSESSED', 'completeness': 'UNKNOWN'}
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'Wirestack-dependency-inventory', 'Accept': 'application/vnd.github+json' if 'api.github.com' in url else '*/*'})
            with urllib.request.urlopen(request, timeout=25) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
                require(len(raw) <= 2 * 1024 * 1024, 'channel response exceeds bound')
                row.update(status='AVAILABLE', http_status=response.status)
            # Preserve the official response, including an empty advisory list.
            filename = 'advisory-' + name + '.txt'
            (output / filename).write_bytes(raw)
            row.update(response=filename, digest=d.text_evidence_digest_bytes(raw).to_json())
            if 'release' in name or name == 'latest':
                value = json.loads(raw)
                row['release'] = {k: value.get(k) for k in ('tag_name', 'target_commitish', 'published_at', 'prerelease', 'html_url', 'body')}
            if name == 'repository-advisories':
                value = json.loads(raw)
                row['advisory_count'] = len(value)
                row['assessment'] = 'REQUIRES_VERSION_RANGE_REVIEW' if value else 'NO_PUBLIC_ENTRIES_RETURNED_NOT_PROOF_OF_SAFETY'
                row['pagination'] = 'FIRST_PAGE_ONLY'
                row['advisories'] = [{'ghsa_id': advisory.get('ghsa_id'),
                    'cve_id': advisory.get('cve_id'), 'summary': advisory.get('summary'),
                    'published_at': advisory.get('published_at'),
                    'vulnerabilities': advisory.get('vulnerabilities'),
                    'version_assessments': {version: 'UNKNOWN_REQUIRES_VERSION_LINEAGE_AND_RANGE_REVIEW' for version in versions}}
                    for advisory in value]
        except (OSError, ValueError) as error:
            row.update(status='UNAVAILABLE', error=normalized(error), assessment='UNKNOWN_NOT_SAFE')
        records.append(row)
    return {'channels': records, 'uncertainty': 'Public intake is bounded and may omit private, unpublished or paginated advisories. Release notes are not a vulnerability clearance. Baseline and selected versions require human applicability review.', 'qualification': 'NOT_QUALIFIED'}


def collect(artifact, sdk, output, work, source_root=ROOT, selected_version='5.11.0'):
    require('sts' in sdk.name.lower(), 'STS SDK root required')
    if (sdk / 'cangjie').is_dir():
        sdk = sdk / 'cangjie'
    output.mkdir(parents=True, exist_ok=True)
    commands = []
    def run(command):
        result = subprocess.run([str(x) for x in command], cwd=work, capture_output=True, timeout=90)
        record = {'command': [normalized(x) for x in command], 'returncode': result.returncode,
            'stdout': normalized(result.stdout.decode(errors='replace')), 'stderr': normalized(result.stderr.decode(errors='replace'))}
        commands.append(record)
        require(result.returncode == 0, 'command failed: ' + record['command'][0])
        return result.stdout.decode()
    metadata = supply.artifact_metadata(artifact)
    payload, manifest = release.read_verified_payload(artifact)
    sources, gzip = validate_components(metadata, payload, source_root)
    dependencies = []
    configs = [('provider', 'SPDXRef-Package-TlsProvider-aws-lc', 'target/native/current', 'libwirestack_tls_provider.a', 'wirestack_tls_'),
        ('resolver', 'SPDXRef-Package-Wirestack-Resolver', 'target/native/resolver/current', 'libwirestack_resolver.a', 'wirestack_resolver_'),
        ('http_files', supply.HTTP_FILES_SPDX_ID, 'target/native/http_files/current', 'libwirestack_http_files.a', 'wirestack_http_files_')]
    archives = []
    for key, spdx, base, name, prefix in configs:
        path = work / name
        raw = payload[base + '/lib/' + name]
        path.write_bytes(raw)
        archives.append(path)
        nm = run(['nm', '-g', '--defined-only', path])
        symbols = sorted(set(line.split()[-1] for line in nm.splitlines() if len(line.split()) >= 3 and line.split()[-1].startswith(prefix)))
        require(symbols, 'missing public symbols: ' + key)
        header_name = name.removeprefix('lib').removesuffix('.a') + '.h'
        validate_symbols(payload[base + '/include/' + header_name].decode(), symbols, prefix)
        undefined = run(['nm', '-u', path])
        require(re.search(r'\b(?:inflate|deflate|gzopen|BZ2_|ZSTD_)\w*\b', undefined) is None, 'native compression dependency rejected')
        dependencies.append({'name': key, 'spdx_id': spdx, 'archive': {'path': base + '/lib/' + name, 'digest': d.artifact_byte_digest_bytes(raw).to_json(), 'bytes': len(raw)},
            'manifest': metadata[key], 'public_symbols': symbols, 'symbols_digest': d.text_evidence_digest_bytes(('\n'.join(symbols)+'\n').encode()).to_json()})
    provider = metadata['provider']
    dependencies[0].update(source=provider['build_inputs']['provider']['source'], patches=provider['build_inputs']['provider']['patches'], patch_level=provider['patchLevel'], license=provider['build_inputs']['provider']['license_expression'])
    for item in dependencies[1:]:
        item['license'] = supply.PROJECT_LICENSE_EXPRESSION
    licenses = {name: d.text_evidence_digest_bytes(payload[name]).to_json() for name in supply.LICENSE_MEMBERS}
    psl = metadata['public_suffix']
    dependencies.append({'name': 'public_suffix', 'spdx_id': supply.PUBLIC_SUFFIX_SPDX_ID, 'source': psl,
        'files': {name: d.artifact_byte_digest_bytes(payload[name]).to_json() for name in supply.PUBLIC_SUFFIX_FILES}})
    dependencies.append({'name': 'gzip', 'spdx_id': supply.GZIP_SPDX_ID, **gzip})
    headers = [('target/native/current/include/wirestack_tls_provider.h', 'wirestack_tls_provider.h'),
        ('target/native/resolver/current/include/wirestack_resolver.h', 'wirestack_resolver.h'),
        ('target/native/http_files/current/include/wirestack_http_files.h', 'wirestack_http_files.h')]
    for source, name in headers:
        (work / name).write_bytes(payload[source])
    smoke = '''#include <string.h>
#include "wirestack_tls_provider.h"
#include "wirestack_resolver.h"
#include "wirestack_http_files.h"
int main(void) {
 uint64_t h=0,p=0; int64_t code=0; unsigned char random[32];
 if(wirestack_tls_provider_abi_version()!=1 || wirestack_http_files_abi_version()!=1) return 1;
 if(wirestack_tls_provider_create(&h)!=0) return 2;
 if(strcmp(wirestack_tls_provider_version(h),"VERSION") || wirestack_tls_provider_external_openssl_dependency(h) || (wirestack_tls_provider_capabilities(h)&WIRESTACK_TLS_CAP_KEY_LOG)) return 3;
 if(wirestack_tls_provider_random(h,random,32)!=0) return 4;
 wirestack_tls_provider_destroy(h);
 if(wirestack_resolver_pool_create(1,1,&p,&code)!=0) return 5;
 if(wirestack_resolver_pool_destroy(p)!=0) return 6;
 if(wirestack_http_files_root_open(0,0,&p,&code)!=WIRESTACK_HTTP_FILES_INVALID_ARGUMENT) return 7;
 return 0;
}
'''.replace('VERSION', provider['providerVersion'])
    (work / 'smoke.c').write_text(smoke)
    run(['cc', '-I', work, work / 'smoke.c', *archives, '-pthread', '-ldl', '-lm', '-o', work / 'smoke'])
    run([work / 'smoke'])
    wrapper = Path.home() / '.codex/scripts/codex_cangjie_env'
    versions = {name: run([wrapper, '--sdk-root', sdk.parent if sdk.name == 'cangjie' else sdk, '--', name, '--version']) for name in ('cjc', 'cjpm')}
    bindings = sdk_binding(sdk)
    report = {'schema_version': 1, 'task_id': 'M12-004', 'family': 'inventory', 'status': 'PASS', 'sdk_policy': 'STS_ONLY', 'qualification': 'NOT_QUALIFIED',
        'created_utc': datetime.now(timezone.utc).isoformat(), 'artifact': {'digest': d.artifact_byte_digest(artifact).to_json(), 'bytes': artifact.stat().st_size, 'payload_digest': d.ArtifactByteDigest(manifest['payload_sha256']).to_json()},
        'package': {'name': manifest['package'], 'version': manifest['version'], 'production_source_files': manifest['production_source_files'], 'build_fingerprint': manifest['artifactBuildFingerprint']},
        'dependencies': dependencies, 'licenses_and_notices': licenses,
        'source_digests': {name: d.text_evidence_digest(source_root / name).to_json() for name in sources},
        'inventory_tool_digests': {name: d.text_evidence_digest(ROOT / name).to_json() for name in ('tools/m12_004_inventory.py', 'tools/tests/test_m12_004_inventory.py', 'tools/m7_025_linux_supply_chain.py')},
        'package_source_digests': {name: d.text_evidence_digest_bytes(raw).to_json() for name, raw in payload.items() if name.startswith('src/') and name.endswith('.cj')},
        'sdk': {'root': normalized(sdk), 'versions': versions, 'files': bindings, 'binding_scope': 'ACTUALLY_EXECUTED_INVENTORY_SDK_NOT_ORIGINAL_PACKAGE_BUILD_PROOF'},
        'commands': commands, 'advisory_intake': intake(output, [provider['providerVersion'], selected_version])}
    # Strip machine-local paths present in embedded historical manifests.
    return json.loads(normalized(json.dumps(report)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--sdk-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--selected-version', default='5.11.0')
    args = parser.parse_args()
    scratch = Path(os.environ.get('TMPDIR', Path.home() / '.cache/agent-tmp'))
    scratch.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='inventory-', dir=scratch) as folder:
            report = collect(args.artifact.resolve(), args.sdk_root.resolve(), args.output, Path(folder), args.source_root, args.selected_version)
    except (ValueError, OSError, subprocess.TimeoutExpired, supply.SupplyChainError, release.ReleaseError) as error:
        report = {'schema_version': 1, 'task_id': 'M12-004', 'family': 'inventory', 'status': 'FAIL', 'sdk_policy': 'STS_ONLY', 'qualification': 'NOT_QUALIFIED', 'error': normalized(error)}
    (args.output / 'inventory.json').write_bytes(supply.canonical_json(report))
    print(json.dumps({'status': report['status'], 'qualification': report['qualification']}))
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
