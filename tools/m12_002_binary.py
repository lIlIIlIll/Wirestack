#!/usr/bin/env python3
"""Capture exact Linux ELF inputs and run installed, same-process TLS/ABI probes."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.evidence_digest import (artifact_byte_digest, text_evidence_digest,
    artifact_byte_sha256_equal, text_evidence_sha256_equal)
from tools import m7_021_linux_release as release

CHECKS = {'independent_cangjie_native', 'wirestack_verified_tls',
          'independent_verified_tls', 'wirestack_after_independent_cleanup', 'same_process_identity_preserved'}
VERSION = re.compile(r'\b(?:GLIBC|GLIBCXX|CXXABI)_[0-9]+(?:\.[0-9]+)*\b')

def sdk_files(sdk: Path) -> list[Path]:
    directories = ('runtime/lib/linux_x86_64_cjnative', 'lib/linux_x86_64_cjnative', 'tools/lib')
    return sorted(set([p for p in [sdk/'bin/cjc', sdk/'tools/bin/cjpm', sdk/'lib/libstdFFI.so',
        *[p for directory in directories for p in (sdk/directory).rglob('*')
          if p.is_file() and ('.so' in p.name or p.suffix == '.a')]] if p.exists()]))

def dynamic_fields(text: str) -> dict:
    fields = {name.lower(): re.findall(r'\(' + name + r'\).*?\[(.*?)\]', text)
              for name in ('NEEDED', 'SONAME', 'RPATH', 'RUNPATH')}
    fields['absolute_path_hazards'] = [value for name in ('needed', 'soname')
        for value in fields[name] if '/' in value]
    fields['absolute_path_hazards'] += [part for name in ('rpath', 'runpath')
        for value in fields[name] for part in value.split(':') if part.startswith('/')]
    fields['implicit_system_tls'] = any(re.match(r'lib(?:ssl|crypto)\.so', x) for x in fields['needed'])
    return fields


def versions(text: str) -> list[str]:
    return sorted(set(VERSION.findall(text)), key=lambda value: (value.split('_')[0],
        tuple(map(int, value.split('_')[1].split('.')))))


def validate_behavior(text: str) -> None:
    found = re.findall(r'^CHECK (\w+) PASS$', text, re.M)
    if set(found) != CHECKS or len(found) != len(CHECKS):
        raise ValueError('same-process behavior checks missing or duplicated')
    if not re.search(r'^IDENTITY wirestack aws-lc 5\.5\.0 [0-9a-f]+$', text, re.M):
        raise ValueError('Wirestack provider identity missing')
    if not re.search(r'^IDENTITY independent_tls OpenSSL 3\..* isolation=deepbind libc=shared verified_peer=example.test bytes=[1-9][0-9]*$', text, re.M):
        raise ValueError('independent verified TLS identity missing')
    if not re.search(r'^BOUNDARY symbols SSL_connect global=0x[0-9a-f]+ isolated=0x[0-9a-f]+ owners_distinct=1 .*independent_owner=.*libssl.so', text, re.M):
        raise ValueError('distinct TLS symbol/address/module binding missing')
    if not re.search(r'^BOUNDARY unisolated_openssl UNSUPPORTED resolved_identity=.*AWS-LC', text, re.M):
        raise ValueError('unisolated TLS symbol risk boundary missing')
    crypto = re.search(r'^BOUNDARY crypto OpenSSL_version global=(0x[0-9a-f]+) independent=(0x[0-9a-f]+) owners_distinct=1 independent_owner=\S+$', text, re.M)
    libc = re.search(r'^BOUNDARY libc pthread_getspecific global=(0x[0-9a-f]+) independent=(0x[0-9a-f]+) owner_shared=1 pthread_create_shared=1 pthread_key_create_shared=1$', text, re.M)
    if not crypto or crypto.group(1) == crypto.group(2) or not libc or libc.group(1) != libc.group(2):
        raise ValueError('independent crypto or shared libc/pthread ownership proof missing')


def validate_abi_matrix(rows: list[dict], sdk_count: int) -> None:
    """Reject an incomplete qualification matrix or any failed cross-SDK/runtime cell."""
    if len(rows) != sdk_count * sdk_count:
        raise ValueError('ABI matrix is incomplete')
    for row in rows:
        if row['abi_result'] != 'PASS' or row['semantic_result'] != 'PASS':
            raise ValueError('cross-SDK native behavior failed: built_sdk=' + str(row['built_sdk'])
                + ' runtime_sdk=' + str(row['runtime_sdk']))


class Capture:
    def __init__(self, output: Path, work: Path, sdks: list[Path]):
        self.output, self.work, self.sdks = output, work, sdks
        self.commands = []
        self.prefix = ''
        self.prior = {}
        self.env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE='1')
        self.replacements = sorted([(str(ROOT), '<repo>'), (str(work), '<scratch>'),
            *((str(sdk), f'<sdk-{i}>') for i, sdk in enumerate(sdks)),
            (str(Path.home()), '$HOME')], key=lambda x: -len(x[0]))
        self.replacements.append((str(work.parent), '<task-scratch>'))
        self.replacements.sort(key=lambda x: -len(x[0]))

    def normalize(self, text: str) -> str:
        for actual, label in self.replacements:
            text = text.replace(actual, label)
        text = text.replace(platform.node(), 'example-host').replace('127.0.0.1', '192.0.2.1')
        return text

    def run(self, label: str, argv: list[str], cwd: Path | None = None,
            *, hidden: bool = False, env: dict | None = None, allow_failure: bool = False, timeout=600) -> str:
        label = self.prefix + label
        cwd = cwd or self.work
        if hidden:
            argv = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', str(self.work), str(self.work),
                    '--tmpfs', str(ROOT), '--chdir', str(cwd), '--', *argv]
        record = {'id': label, 'argv': [self.normalize(x) for x in argv],
                  'cwd': self.normalize(str(cwd)), 'checkout_hidden': hidden}
        record['environment'] = {key: self.normalize(value) for key, value in (env or {}).items()}
        for key in ('stdout', 'stderr'):
            record[key] = {'path': f'docs/evidence/M12-002/binary/{label}.{key}.log'}
        raw = {key: self.work / f'{label}.{key}.raw' for key in ('stdout', 'stderr')}
        with raw['stdout'].open('wb') as out, raw['stderr'].open('wb') as err:
            try:
                result = subprocess.run(argv, cwd=cwd, env=self.env | (env or {}), stdout=out,
                                        stderr=err, timeout=timeout)
                record['exit_code'] = result.returncode
            except subprocess.TimeoutExpired:
                record['exit_code'] = None
                record['timed_out'] = True
        for key, path in raw.items():
            destination = self.output / f'{label}.{key}.log'
            with path.open(errors='replace') as source, destination.open('w') as target:
                for index, line in enumerate(source):
                    if '-disassembly' not in label or key != 'stdout' or index < 20:
                        target.write(self.normalize(line))
                if '-disassembly' in label and key == 'stdout':
                    target.write('Complete disassembly retained in private scratch; raw output binding: '+json.dumps(artifact_byte_digest(path).to_json())+'\n')
            record[key]['digest'] = text_evidence_digest(destination).to_json()
        self.commands.append(record)
        if record['exit_code'] != 0 and not allow_failure:
            raise RuntimeError(f'{label} failed, retained diagnostics')
        return (self.output / f'{label}.stdout.log').read_text()

    def scan(self, label: str, path: Path) -> dict:
        for old in self.prior.get('scans', {}).values():
            if old['path'] == self.normalize(str(path)) and artifact_byte_sha256_equal(old['digest'], artifact_byte_digest(path).to_json()):
                base = old['symbol_inventory_command'].removesuffix('-symbols')
                records = [r for r in self.prior['commands'] if r['id'].startswith(base+'-')]
                if records and all(r['exit_code'] == 0 or r['id'].endswith('-symbols') for r in records):
                    for record in records:
                        for key in ('stdout', 'stderr'):
                            if not text_evidence_sha256_equal(record[key]['digest'], text_evidence_digest(ROOT / record[key]['path']).to_json()):
                                raise ValueError('prior scan diagnostic changed')
                    self.commands.extend(r for r in records if r not in self.commands)
                    version_record = next(r for r in records if r['id'] == base+'-versions')
                    observed = (ROOT / version_record['stdout']['path']).read_text()
                    old = dict(old, required_symbol_versions=versions(observed.split('Version needs section', 1)[1]) if 'Version needs section' in observed else [],
                               symbol_versions_role='symbol_versions includes definitions; required_symbol_versions records loader requirements only')
                    return old
        header = self.run(label+'-headers', ['readelf', '-hW', str(path)])
        dynamic = self.run(label+'-dynamic', ['readelf', '-dW', str(path)])
        symbol_versions = self.run(label+'-versions', ['readelf', '-VW', str(path)])
        notes = self.run(label+'-notes', ['readelf', '-nW', str(path)])
        symbols = self.run(label+'-symbols', ['nm', '-g', '--defined-only', str(path)], allow_failure=True)
        self.run(label+'-disassembly', ['objdump', '-d', '--no-show-raw-insn', str(path)])
        isa_counts = {'avx_mnemonics': 0, 'aes_mnemonics': 0, 'pclmul_mnemonics': 0}
        with (self.work / f'{self.prefix}{label}-disassembly.stdout.raw').open() as stream:
            for line in stream:
                match = re.match(r'\s*[0-9a-f]+:\s+(\w+)', line)
                if match:
                    op = match[1]
                    isa_counts['avx_mnemonics'] += int(op.startswith('v') and op not in ('verr', 'verw'))
                    isa_counts['aes_mnemonics'] += int('aes' in op)
                    isa_counts['pclmul_mnemonics'] += int('pclmul' in op)
        machines = sorted(set(re.findall(r'Machine:\s+(.+)', header)))
        return {'path': self.normalize(str(path)), 'digest': artifact_byte_digest(path).to_json(),
                'machines': machines, 'elf_class': sorted(set(re.findall(r'Class:\s+(\S+)', header))),
                **dynamic_fields(dynamic), 'symbol_versions': versions(symbol_versions),
                'gnu_property_notes': [x.strip() for x in notes.splitlines() if 'x86' in x or 'ISA' in x],
                'required_symbol_versions': versions(symbol_versions.split('Version needs section', 1)[1]) if 'Version needs section' in symbol_versions else [],
                'symbol_versions_role': 'symbol_versions includes definitions; required_symbol_versions records loader requirements only',
                'raw_isa_presence': isa_counts, 'minimum_cpu': 'NOT_INFERRED_FROM_DISASSEMBLY',
                'unprefixed_tls_defined_symbols': sorted(set(re.findall(r'\b(?:SSL|OPENSSL|CRYPTO|EVP|X509)_[A-Za-z0-9_]+\b', symbols))),
                'symbol_inventory_command': self.prefix+label+'-symbols'}


def verify(report: dict, archive: Path, sdks: list[Path], fixture: Path, work: Path) -> None:
    if len(sdks) != len(report['sdk_inputs']) or report['status'] != 'PASS':
        raise ValueError('incomplete report or different SDK matrix')
    validate_abi_matrix(report['abi_matrix'], len(sdks))
    if not artifact_byte_sha256_equal(report['archive_digest'], artifact_byte_digest(archive).to_json()):
        raise ValueError('archive changed; recapture required')
    current = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in fixture.rglob('*')
               if p.is_file() and p.suffix in ('.cj', '.c', '.toml')}
    current['tools/m12_002_binary.py'] = text_evidence_digest(Path(__file__)).to_json()
    current['tools/tests/test_m12_002_binary.py'] = text_evidence_digest(ROOT / 'tools/tests/test_m12_002_binary.py').to_json()
    if current.keys() != report['fixture_inputs'].keys() or any(not text_evidence_sha256_equal(
            current[k], report['fixture_inputs'][k]) for k in current):
        raise ValueError('fixture or capture tool changed; recapture required')
    for i, sdk in enumerate(sdks):
        if {str(p.relative_to(sdk)) for p in sdk_files(sdk)} != set(report['sdk_inputs'][str(i)]):
            raise ValueError('SDK library inventory changed; recapture required')
        for relative, digest in report['sdk_inputs'][str(i)].items():
            if not artifact_byte_sha256_equal(digest, artifact_byte_digest(sdk / relative).to_json()):
                raise ValueError('SDK compiler/runtime/library changed; recapture required')
    for relative, digest in report['production_inputs'].items():
        if not text_evidence_sha256_equal(digest, text_evidence_digest(ROOT / relative).to_json()):
            raise ValueError('production source changed; recapture required')
    replacements = {'<repo>': ROOT, '<scratch>': work, '<task-scratch>': work.parent, '$HOME': Path.home(),
                    **{f'<sdk-{i}>': sdk for i, sdk in enumerate(sdks)}}
    for relative, digest in report['native_tool_inputs'].items():
        path = relative
        for label, replacement in replacements.items():
            path = path.replace(label, str(replacement))
        if not artifact_byte_sha256_equal(digest, artifact_byte_digest(Path(path)).to_json()):
            raise ValueError('native tool changed; recapture required')
    for scan in report['scans'].values():
        path = scan['path']
        for label, replacement in replacements.items():
            path = path.replace(label, str(replacement))
        if not artifact_byte_sha256_equal(scan['digest'], artifact_byte_digest(Path(path)).to_json()):
            raise ValueError('scanned binary/archive/library changed; recapture required')
    for record in report['commands']:
        for key in ('stdout', 'stderr'):
            path = ROOT / record[key]['path']
            if not text_evidence_sha256_equal(record[key]['digest'], text_evidence_digest(path).to_json()):
                raise ValueError('diagnostic log changed')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sdk', action='append', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--wrapper', type=Path, required=True)
    parser.add_argument('--openssl-library', type=Path, required=True)
    parser.add_argument('--openssl-crypto-library', type=Path, required=True)
    parser.add_argument('--consumer', action='append', type=Path, default=[])
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'docs/evidence/M12-002/binary'
    fixture = ROOT / 'examples/linux/m12_002/coexist'
    sdks = [sdk.resolve() for sdk in args.sdk]
    work = args.scratch.resolve()
    if args.verify:
        selected_report = json.loads((output / 'report.json').read_text())
        for argument, field in ((args.openssl_library, 'library_digest'), (args.openssl_crypto_library, 'crypto_library_digest')):
            if not artifact_byte_sha256_equal(selected_report['external_tls_fixture'][field], artifact_byte_digest(argument.resolve()).to_json()):
                raise ValueError('independent TLS fixture input changed; recapture required')
        verify(selected_report, args.archive, sdks, fixture, work)
        print('M12_002_BINARY_BINDING_PASS')
        return 0
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(work, 0o700)
    if shutil.disk_usage(work).free < 2 * 1024**3 or subprocess.check_output(
            ['findmnt', '-n', '-o', 'FSTYPE', '-T', str(work)], text=True).strip() == 'tmpfs':
        raise ValueError('need disk-backed scratch with 2 GiB free')
    output.mkdir(parents=True, exist_ok=True)
    capture = Capture(output, work, sdks)
    if (output / 'report.json').exists():
        previous = json.loads((output / 'report.json').read_text())
        attempt = len(list(output.glob('attempt-*.json'))) + 1
        (output / f'attempt-{attempt}.json').write_text(json.dumps(previous, indent=2)+'\n')
        capture.prefix = f'attempt-{attempt + 1}-'
        capture.prior = previous
        # Reuse input/tool-bound ELF observations only, never former runtime verdicts.
        for saved in sorted(output.glob('attempt-*.json'), key=lambda p: int(p.stem.split('-')[1]), reverse=True):
            snapshot = json.loads(saved.read_text())
            if not any(name.startswith('sdk-') for name in snapshot.get('scans', {})):
                continue
            same_tools = True
            for name in ('readelf', 'objdump', 'nm'):
                path = Path(shutil.which(name)).resolve()
                old = snapshot.get('native_tool_inputs', {}).get(capture.normalize(str(path)))
                same_tools = same_tools and bool(old) and artifact_byte_sha256_equal(old, artifact_byte_digest(path).to_json())
            if not same_tools:
                continue
            for name, row in snapshot['scans'].items():
                if name.startswith(('sdk-', 'installed-consumer-', 'optional-consumer-', 'system-dependency-', 'external-tls-')):
                    capture.prior['scans'].setdefault('cached-'+name, row)
            known = {record['id'] for record in capture.prior['commands']}
            capture.prior['commands'].extend(record for record in snapshot['commands'] if record['id'] not in known)
            break
    report = {'schema_version': 1, 'task_id': 'M12-002', 'status': 'INCOMPLETE',
        'release_qualification': 'NOT_QUALIFIED', 'archive_digest': artifact_byte_digest(args.archive).to_json(),
        'environment': {'os': platform.system(), 'architecture': platform.machine(),
                        'kernel': platform.release(), 'libc': platform.libc_ver()},
        'commands': capture.commands, 'scans': {}, 'sdk_inputs': {}, 'abi_matrix': [],
        'fixture_inputs': {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json()
            for p in fixture.rglob('*') if p.is_file() and p.suffix in ('.cj', '.c', '.toml')},
        'production_inputs': {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json()
                              for p in release.production_sources(ROOT)}, 'native_tool_inputs': {}}
    report['fixture_inputs']['tools/m12_002_binary.py'] = text_evidence_digest(Path(__file__)).to_json()
    report['fixture_inputs']['tools/tests/test_m12_002_binary.py'] = text_evidence_digest(ROOT / 'tools/tests/test_m12_002_binary.py').to_json()
    try:
        report['native_tool_inputs'][capture.normalize(str(args.wrapper.resolve()))] = artifact_byte_digest(args.wrapper.resolve()).to_json()
        for name in ('gcc', 'g++', 'ar', 'as', 'ld', 'readelf', 'objdump', 'nm', 'openssl'):
            binary = Path(shutil.which(name)).resolve()
            report['native_tool_inputs'][capture.normalize(str(binary))] = artifact_byte_digest(binary).to_json()
            capture.run('tool-'+name.replace('+', 'p'), [str(binary), 'version' if name == 'openssl' else '--version'])
        report['native_compiler_backends'] = {}
        for driver, program in (('gcc', 'cc1'), ('g++', 'cc1plus')):
            value = capture.run('backend-'+program, [driver, '-print-prog-name='+program]).strip()
            for path, token in capture.replacements:
                value = value.replace(token, path)
            backend = Path(shutil.which(value) or value).resolve()
            report['native_tool_inputs'][capture.normalize(str(backend))] = artifact_byte_digest(backend).to_json()
            report['native_compiler_backends'][program] = capture.normalize(str(backend))
        capture.run('boundary-tests', [sys.executable, '-m', 'unittest', 'tools.tests.test_m12_002_binary'], ROOT)
        extracted = release.extract_archive(args.archive.resolve(), work / 'install')
        installed = work / 'wirestack'
        if not installed.exists(): extracted.rename(installed)
        production = {str(p.relative_to(installed)): text_evidence_digest(p).to_json() for p in release.production_sources(installed)}
        if production.keys() != report['production_inputs'].keys() or any(not text_evidence_sha256_equal(production[k], report['production_inputs'][k]) for k in production):
            raise ValueError('selected archive source differs from current production inputs')
        manifest = json.loads((installed/'release-manifest.json').read_text())
        from tools.m11_004_installed_consumers import validate_installed
        validate_installed(installed, manifest)
        report['payload_sha256'] = manifest['payload_sha256']
        report['installed_native_manifests'] = {}
        for index, path in enumerate(sorted((installed / 'target/native').rglob('*.json'))):
            value = json.loads(path.read_text())
            report['installed_native_manifests'][str(path.relative_to(installed))] = {
                'digest': text_evidence_digest(path).to_json(), 'content': json.loads(capture.normalize(json.dumps(value)))}
            if '-march=native' in json.dumps(value) or '-mcpu=native' in json.dumps(value):
                raise ValueError('native ISA flags in shipped manifest')
        for i, path in enumerate(sorted(installed.rglob('*.a'))):
            report['scans'][f'archive-{i}'] = capture.scan(f'archive-{i}', path)
        report['optional_modules'] = {'gzip': 'pure Cangjie, no native compression archive',
            'sse': 'pure Cangjie', 'observability': 'pure Cangjie', 'websocket': 'in HTTP package'}
        capture.run('certificate', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=example.test', '-addext', 'subjectAltName=DNS:example.test',
            '-keyout', str(work/'key.pem'), '-out', str(work/'certificate.pem')])
        capture.run('certificate-der', ['openssl', 'x509', '-in', str(work/'certificate.pem'), '-outform', 'DER', '-out', str(work/'certificate.der')])
        capture.run('key-der', ['openssl', 'pkcs8', '-topk8', '-nocrypt', '-in', str(work/'key.pem'), '-outform', 'DER', '-out', str(work/'key.pk8')])
        report['external_tls_fixture'] = {'library_digest': artifact_byte_digest(args.openssl_library.resolve()).to_json(),
            'library': capture.normalize(str(args.openssl_library.resolve())), 'scope': 'TEST_FIXTURE_ONLY',
            'crypto_library': capture.normalize(str(args.openssl_crypto_library.resolve())),
            'crypto_library_digest': artifact_byte_digest(args.openssl_crypto_library.resolve()).to_json(),
            'isolation': 'test-only explicit dlopen RTLD_NOW|RTLD_LOCAL|RTLD_DEEPBIND; one shared libc/pthread key allocator; ordinary unisolated OpenSSL unsupported'}
        report['archive_native_compiler_binding'] = 'Shipped manifests bind build inputs, compiler versions and archive bytes. A missing historical compiler executable digest remains UNKNOWN; current compiler snapshots do not qualify the original build.'
        flags = ['-std=gnu11', '-O2', '-fPIC', '-Wall', '-Wextra', '-Werror', '-march=x86-64', '-mtune=generic']
        report['fixture_native_flags'] = flags
        builds = []
        for i, sdk in enumerate(sdks):
            selected_sdk_files = sdk_files(sdk)
            report['sdk_inputs'][str(i)] = {str(p.relative_to(sdk)): artifact_byte_digest(p).to_json() for p in selected_sdk_files}
            app = work / f'coexist-{i}'
            shutil.copytree(fixture, app)
            (app/'native/lib').mkdir()
            capture.run(f'fixture-{i}-compile', ['gcc', *flags, '-c', str(app/'native/independent_tls.c'), '-o', str(app/'native/fixture.o')], hidden=True)
            capture.run(f'fixture-{i}-archive', ['ar', 'rcs', str(app/'native/lib/libcoexist_fixture.a'), str(app/'native/fixture.o')], hidden=True)
            command = [str(args.wrapper), '--sdk-root', str(sdk), '--cwd', str(app)]
            capture.run(f'sdk-{i}-compiler-version', [*command, 'cjc', '--version'], hidden=True)
            capture.run(f'sdk-{i}-cjpm-version', [*command, 'cjpm', '--version'], hidden=True)
            capture.run(f'coexist-{i}-build', [*command, 'cjpm', 'build'], hidden=True)
            binary = app / 'target/release/bin/main'
            builds.append(binary)
            report['scans'][f'coexist-{i}'] = capture.scan(f'coexist-{i}', binary)
        for i, binary in enumerate(builds):
            for j, sdk in enumerate(sdks):
                label = f'abi-{i}-to-{j}'
                text = capture.run(label, [str(args.wrapper), '--sdk-root', str(sdk), '--cwd', str(work), str(binary),
                    str(work/'certificate.der'), str(work/'key.pk8')], hidden=True, allow_failure=True,
                    env={'WIRESTACK_FIXTURE_OPENSSL_LIBRARY': str(args.openssl_library.resolve()),
                         'WIRESTACK_FIXTURE_OPENSSL_CRYPTO_LIBRARY': str(args.openssl_crypto_library.resolve()),
                         'WIRESTACK_FIXTURE_CA_FILE': str(work/'certificate.pem'), 'LD_DEBUG': 'libs'}, timeout=60)
                record = capture.commands[-1]
                good = record['exit_code'] == 0
                if good: validate_behavior(text)
                loader_trace = (ROOT / record['stderr']['path']).read_text()
                expected_runtime = capture.normalize(str(sdk/'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'))
                runtime_loaded = expected_runtime in re.findall(r'calling init:\s+(\S+)', loader_trace)
                if good and not runtime_loaded:
                    raise ValueError('requested SDK runtime was not actually loaded; ABI cross is unproven')
                report['abi_matrix'].append({'built_sdk': i, 'runtime_sdk': j,
                    'binary_digest': artifact_byte_digest(binary).to_json(), 'command': record['id'],
                    'abi_result': 'PASS' if good else 'FAIL_RUNTIME_EXECUTION_REQUIRES_DIAGNOSIS',
                    'semantic_result': 'PASS' if good else 'NOT_EXECUTED_TO_COMPLETION',
                    'runtime_loaded_library': expected_runtime if runtime_loaded else None,
                    'runtime_loading_proof': record['stderr']})
                if not good:
                    raise RuntimeError('same-SDK native behavior failed' if i == j else 'cross-SDK native behavior failed')
        for i, sdk in enumerate(sdks):
            for j, path in enumerate(sdk_files(sdk)):
                with path.open('rb') as stream:
                    magic = stream.read(4)
                if magic == b'\x7fELF' or path.suffix == '.a':
                    report['scans'][f'sdk-{i}-{j}'] = capture.scan(f'sdk-{i}-{j}', path)
        for i, path in enumerate(args.consumer):
            report['scans'][f'installed-consumer-{i}'] = capture.scan(f'installed-consumer-{i}', path.resolve())
        report['compiled_optional_modules'] = {}
        for i, binary in enumerate(args.consumer):
            module_root = binary.resolve().parent.parent / 'wirestack'
            for module in ('gzip', 'sse', 'observability'):
                archive = module_root / f'libwirestack.{module}.a'
                if not archive.is_file():
                    raise ValueError(f'compiled optional module missing: {archive}')
                label = f'optional-consumer-{i}-{module}'
                report['scans'][label] = capture.scan(label, archive)
                report['compiled_optional_modules'][label] = capture.normalize(str(archive))
        report['sdk_upstream_build_flags'] = 'UNKNOWN: SDK compiler version and ELF notes do not bind upstream build flags'
        report['dynamic_dependency_closure'] = {}
        for i, sdk in enumerate(sdks):
            for name, binary in [('compiler', sdk/'bin/cjc'), ('runtime', sdk/'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'), ('coexist', builds[i])]:
                text = capture.run(f'closure-{i}-{name}', [str(args.wrapper), '--sdk-root', str(sdk), 'ldd', str(binary)])
                if 'not found' in text:
                    raise ValueError('unresolved installed dynamic dependency')
                dependencies = []
                for value in re.findall(r'=>\s+(\S+)\s+\(0x', text):
                    actual = value
                    for path, token in capture.replacements:
                        actual = actual.replace(token, path)
                    library = Path(actual).resolve()
                    dependencies.append(capture.normalize(str(library)))
                    if capture.normalize(str(library)) not in report['dynamic_dependency_closure']:
                        key = f'system-dependency-{len(report["dynamic_dependency_closure"])}'
                        report['dynamic_dependency_closure'][capture.normalize(str(library))] = key
                        report['scans'][key] = capture.scan(key, library)
                report.setdefault('resolved_dependencies', {})[f'{i}-{name}'] = dependencies
        report['scans']['external-tls-fixture'] = capture.scan('external-tls-fixture', args.openssl_library.resolve())
        external_closure = capture.run('external-tls-closure', ['ldd', str(args.openssl_library.resolve())])
        report['external_tls_fixture']['dynamic_dependencies'] = []
        for value in re.findall(r'=>\s+(\S+)\s+\(0x', external_closure):
            actual = value
            for path, token in capture.replacements:
                actual = actual.replace(token, path)
            library = Path(actual).resolve()
            label = f'external-tls-dependency-{len(report["external_tls_fixture"]["dynamic_dependencies"])}'
            report['scans'][label] = capture.scan(label, library)
            report['external_tls_fixture']['dynamic_dependencies'].append(label)
        if any(row['implicit_system_tls'] for name, row in report['scans'].items() if not name.startswith('external-tls-')):
            raise ValueError('implicit TLS dependency in shipped or built inputs')
        report.update(status='PASS', minimum_cpu='MAIN_OWNS_NATIVE_CPU_BOUNDARY',
            minimum_kernel='MAIN_OWNS_NATIVE_KERNEL_BOUNDARY', minimum_glibc='SYMBOL_REQUIREMENTS_ARE_NOT_NATIVE_MINIMUM_PROOF')
    except Exception as error:
        report.update(status='FAIL', failure=capture.normalize(str(error)))
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(report['status'])
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
