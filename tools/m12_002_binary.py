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
    artifact_byte_sha256_equal, schema_text_sha256_equal, text_evidence_sha256_equal)
from tools import m7_021_linux_release as release

CHECKS = {'independent_cangjie_native', 'wirestack_verified_tls',
          'independent_verified_tls', 'wirestack_after_independent_cleanup', 'same_process_identity_preserved'}
VERSION = re.compile(r'\b(?:GLIBC|GLIBCXX|CXXABI)_[0-9]+(?:\.[0-9]+)*\b')
SCANNER = Path(__file__).resolve()
HELPER_SOURCES = ('tools/m12_002_binary.py', 'tools/tests/test_m12_002_binary.py',
    'tools/m7_021_linux_release.py', 'tools/m11_004_installed_consumers.py',
    'tools/m11_003_native_websocket.py', 'tools/evidence_digest.py')
CONSUMER_PROFILES = ('stable-native', 'candidate-native')
CONSUMER_APPS = ('cli', 'decoded', 'streams', 'service', 'trust')
OPTIONAL_MODULES = ('gzip', 'sse', 'observability')
TRUNCATED = 'Complete disassembly retained in private scratch; raw output binding: '
TRUNCATED_ISA = 'UNAVAILABLE_TRUNCATED_DISASSEMBLY'


def sdk_files(sdk: Path) -> list[Path]:
    directories = ('runtime/lib/linux_x86_64_cjnative', 'lib/linux_x86_64_cjnative', 'tools/lib', 'modules')
    return sorted(set([p for p in [sdk/'bin/cjc', sdk/'tools/bin/cjpm', sdk/'lib/libstdFFI.so',
        *[p for directory in directories for p in (sdk/directory).rglob('*')
          if p.is_file() and ('.so' in p.name or p.suffix in ('.a', '.cjo', '.bc'))]] if p.exists()]))


def scanner_digest() -> dict:
    return text_evidence_digest(SCANNER).to_json()


def helper_sources() -> dict:
    return {name: text_evidence_digest(ROOT / name).to_json() for name in HELPER_SOURCES}


def consumer_identity(value: str) -> tuple[str, str, Path]:
    """Parse the strict `<profile>/<app>=<installed executable>` consumer declaration."""
    identity, separator, path = value.partition('=')
    profile, slash, app = identity.partition('/')
    if not separator or not slash or not path or profile not in CONSUMER_PROFILES or app not in CONSUMER_APPS:
        raise ValueError('consumer must be <profile>/<app>=<path> with a declared profile and app: ' + value)
    return profile, app, Path(path)

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
        for field in ('built_sdk', 'runtime_sdk'):
            # JSON booleans are ints in Python; an SDK index is a real integer or nothing.
            if type(row.get(field)) is not int:
                raise ValueError('ABI matrix cell is not an SDK index: ' + field)
    coordinates = [(row['built_sdk'], row['runtime_sdk']) for row in rows]
    expected = {(built, runtime) for built in range(sdk_count) for runtime in range(sdk_count)}
    if len(set(coordinates)) != len(coordinates) or set(coordinates) != expected:
        raise ValueError('ABI matrix does not cover each built/runtime coordinate exactly once')
    for row in rows:
        if row['abi_result'] != 'PASS' or row['semantic_result'] != 'PASS':
            raise ValueError('cross-SDK native behavior failed: built_sdk=' + str(row['built_sdk'])
                + ' runtime_sdk=' + str(row['runtime_sdk']))


def isa_presence(disassembly: str) -> dict | str:
    """ISA mnemonics are only observable from a complete disassembly that is still retained."""
    if TRUNCATED in disassembly:
        return TRUNCATED_ISA
    return count_mnemonics(disassembly)


def count_mnemonics(disassembly: str) -> dict[str, int]:
    counts = {'avx_mnemonics': 0, 'aes_mnemonics': 0, 'pclmul_mnemonics': 0}
    for line in disassembly.splitlines():
        match = re.match(r'\s*[0-9a-f]+:\s+(\w+)', line)
        if match:
            op = match[1]
            counts['avx_mnemonics'] += int(op.startswith('v') and op not in ('verr', 'verw'))
            counts['aes_mnemonics'] += int('aes' in op)
            counts['pclmul_mnemonics'] += int('pclmul' in op)
    return counts


def truncated_digest(published: str) -> dict | None:
    """The raw-output binding a truncated published log carries, or None when it is complete."""
    markers = [line for line in published.splitlines() if line.startswith(TRUNCATED)]
    if not markers:
        return None
    if len(markers) != 1:
        raise ValueError('truncated disassembly carries more than one raw output binding')
    try:
        digest = json.loads(markers[0][len(TRUNCATED):])
    except json.JSONDecodeError:
        raise ValueError('truncated disassembly raw output binding is not JSON') from None
    if not isinstance(digest, dict) or digest.get('domain') != 'artifact-bytes-v1' \
            or not isinstance(digest.get('sha256'), str):
        raise ValueError('truncated disassembly raw output binding is not an artifact digest')
    return digest


def disassembly_binding(command: dict) -> dict:
    """The scan's own declaration of the complete raw output and whether it was published whole."""
    declared = command.get('disassembly_raw')
    if not isinstance(declared, dict) or not isinstance(declared.get('truncated'), bool) \
            or not isinstance(declared.get('digest'), dict):
        raise ValueError('raw disassembly binding is missing: ' + command['id'])
    return declared


def raw_disassembly_isa(published: str, declared: dict, scratch: Path, command_id: str) -> dict:
    """Re-derive mnemonic counts from the complete raw output the capture retained."""
    bound = truncated_digest(published)
    if (bound is not None) != declared['truncated']:
        raise ValueError('published disassembly truncation differs from its binding: ' + command_id)
    raw = scratch / f'{command_id}.stdout.raw'
    if not raw.is_file():
        raise ValueError('complete raw disassembly is unavailable: ' + command_id)
    actual = artifact_byte_digest(raw).to_json()
    if not artifact_byte_sha256_equal(declared['digest'], actual):
        raise ValueError('complete raw disassembly changed: ' + command_id)
    if bound is not None and not artifact_byte_sha256_equal(bound, actual):
        raise ValueError('published raw output binding differs from the retained output: ' + command_id)
    return count_mnemonics(raw.read_text(errors='replace'))


def scan_fields(header: str, dynamic: str, symbol_versions: str, notes: str, symbols: str,
                isa_counts: dict | str) -> dict:
    """The single derivation of every ELF verdict, shared by capture and verification."""
    return {'machines': sorted(set(re.findall(r'Machine:\s+(.+)', header))),
            'elf_class': sorted(set(re.findall(r'Class:\s+(\S+)', header))),
            **dynamic_fields(dynamic), 'symbol_versions': versions(symbol_versions),
            'gnu_property_notes': [x.strip() for x in notes.splitlines() if 'x86' in x or 'ISA' in x],
            'required_symbol_versions': versions(symbol_versions.split('Version needs section', 1)[1])
                if 'Version needs section' in symbol_versions else [],
            'symbol_versions_role': 'symbol_versions includes definitions; '
                'required_symbol_versions records loader requirements only',
            'raw_isa_presence': isa_counts, 'minimum_cpu': 'NOT_INFERRED_FROM_DISASSEMBLY',
            'unprefixed_tls_defined_symbols': sorted(set(
                re.findall(r'\b(?:SSL|OPENSSL|CRYPTO|EVP|X509)_[A-Za-z0-9_]+\b', symbols)))}


SCAN_SUFFIXES = ('headers', 'dynamic', 'versions', 'notes', 'symbols', 'disassembly')
SCAN_ARGV = {'headers': ['readelf', '-hW'], 'dynamic': ['readelf', '-dW'],
             'versions': ['readelf', '-VW'], 'notes': ['readelf', '-nW'],
             'symbols': ['nm', '-g', '--defined-only'],
             'disassembly': ['objdump', '-d', '--no-show-raw-insn']}
TOOL_PROGRAMS = ('gcc', 'g++', 'ar', 'as', 'ld', 'readelf', 'objdump', 'nm', 'openssl')


def evidence_path(entry: dict, root: Path, command_id: str) -> Path:
    """Resolve a retained log beneath the evidence root, including symlink targets."""
    relative = entry.get('path')
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute() \
            or '..' in Path(relative).parts:
        raise ValueError('command evidence path escapes its evidence tree: ' + command_id)
    try:
        evidence_root = root.resolve()
        path = (root / relative).resolve()
        path.relative_to(evidence_root)
    except (OSError, RuntimeError, ValueError):
        raise ValueError('command evidence path escapes its evidence tree: ' + command_id) from None
    return path


def bound_command(report: dict, command_id: str, root: Path = ROOT) -> tuple[dict, dict]:
    matches = [command for command in report['commands'] if command['id'] == command_id]
    if len(matches) != 1:
        raise ValueError('native command is not recorded exactly once: ' + command_id)
    command = matches[0]
    text = {}
    for stream in ('stdout', 'stderr'):
        entry = command[stream]
        path = evidence_path(entry, root, command_id)
        if not path.is_file():
            raise ValueError('command evidence is missing: ' + command_id)
        if not text_evidence_sha256_equal(entry['digest'], text_evidence_digest(path).to_json()):
            raise ValueError('scan diagnostic log changed: ' + command_id)
        text[stream] = path.read_text()
    return command, text


def _capture_replacements(root: Path, work: Path, sdks: list[Path]) -> list[tuple[str, str]]:
    replacements = [(str(root), '<repo>'), (str(work), '<scratch>'),
        *((str(sdk), f'<sdk-{i}>') for i, sdk in enumerate(sdks)),
        (str(Path.home()), '$HOME'), (str(work.parent), '<task-scratch>')]
    return sorted(replacements, key=lambda item: -len(item[0]))


def _normalize_capture_path(value: str, root: Path, work: Path, sdks: list[Path]) -> str:
    for actual, label in _capture_replacements(root, work, sdks):
        value = value.replace(actual, label)
    return value.replace(platform.node(), 'example-host').replace('127.0.0.1', '192.0.2.1')


def _resolve_capture_path(value: str, root: Path, work: Path, sdks: list[Path]) -> Path:
    replacements = [(label, Path(actual)) for actual, label in _capture_replacements(root, work, sdks)]
    for label, actual in sorted(replacements, key=lambda item: -len(item[0])):
        value = value.replace(label, str(actual))
    return Path(value).resolve()


def command_prefix(report: dict) -> str:
    """Read the current capture prefix from its required compiler probe."""
    matches = [command['id'] for command in report.get('commands', [])
        if isinstance(command.get('id'), str) and command['id'].endswith('tool-gcc')]
    if len(matches) != 1:
        raise ValueError('native command inventory does not identify one compiler probe')
    return matches[0][:-len('tool-gcc')]


def expected_scan_inputs(report: dict, archive_scans: list[str], sdks: list[Path],
                         consumers: list[tuple[str, str, Path]], work: Path, wrapper: Path,
                         openssl_library: Path, root: Path = ROOT) -> dict[str, Path]:
    """Derive every scan label and exact artifact path from independent inputs."""
    prefix = command_prefix(report)
    scan_inputs = {f'coexist-{i}': work / f'coexist-{i}/target/release/bin/main'
        for i in range(len(sdks))}
    for i, sdk in enumerate(sdks):
        for j, path in enumerate(sdk_files(sdk)):
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic == b'\x7fELF' or path.suffix == '.a':
                scan_inputs[f'sdk-{i}-{j}'] = path
    scan_inputs.update({f'archive-{i}': work / 'wirestack' / path
        for i, path in enumerate(archive_scans)})
    expected_consumers = {(profile, app) for profile in CONSUMER_PROFILES for app in CONSUMER_APPS}
    declared_consumers = [(profile, app) for profile, app, _ in consumers]
    if len(declared_consumers) != len(expected_consumers) or set(declared_consumers) != expected_consumers:
        raise ValueError('binary verification requires every declared profile/app installed consumer exactly once')
    for i, (profile, app, binary) in enumerate(sorted(consumers, key=lambda item: (item[0], item[1]))):
        resolved_binary = binary.resolve()
        scan_inputs[f'installed-consumer-{i}'] = resolved_binary
        module_root = resolved_binary.parent.parent / 'wirestack'
        for module in OPTIONAL_MODULES:
            scan_inputs[f'optional-{profile}-{app}-{module}'] = module_root / f'libwirestack.{module}.a'
    scan_inputs['external-tls-fixture'] = openssl_library.resolve()

    dynamic_dependencies = {}
    for i, sdk in enumerate(sdks):
        for name in ('compiler', 'runtime', 'coexist'):
            command_id = prefix + f'closure-{i}-{name}'
            command, text = bound_command(report, command_id, root)
            binaries = {'compiler': sdk / 'bin/cjc',
                'runtime': sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so',
                'coexist': work / f'coexist-{i}/target/release/bin/main'}
            expected_argv = [_normalize_capture_path(str(wrapper), root, work, sdks),
                '--sdk-root', _normalize_capture_path(str(sdk), root, work, sdks),
                'ldd', _normalize_capture_path(str(binaries[name]), root, work, sdks)]
            expected_cwd = _normalize_capture_path(str(work), root, work, sdks)
            if command.get('cwd') != expected_cwd or command.get('argv') != expected_argv:
                raise ValueError('dynamic dependency closure invocation changed: ' + command_id)
            if command.get('timed_out') or command.get('exit_code') != 0 or 'not found' in text['stdout']:
                raise ValueError('dynamic dependency closure command is incomplete: ' + command_id)
            for value in re.findall(r'=>\s+(\S+)\s+\(0x', text['stdout']):
                path = _resolve_capture_path(value, root, work, sdks)
                normalized = _normalize_capture_path(str(path), root, work, sdks)
                if normalized not in dynamic_dependencies:
                    label = f'system-dependency-{len(dynamic_dependencies)}'
                    dynamic_dependencies[normalized] = label
                    scan_inputs[label] = path
    if report.get('dynamic_dependency_closure') != dynamic_dependencies:
        raise ValueError('system dependency inventory differs from the retained closure commands')

    command_id = prefix + 'external-tls-closure'
    command, text = bound_command(report, command_id, root)
    expected_argv = ['ldd', _normalize_capture_path(str(openssl_library.resolve()), root, work, sdks)]
    expected_cwd = _normalize_capture_path(str(work), root, work, sdks)
    if command.get('cwd') != expected_cwd or command.get('argv') != expected_argv:
        raise ValueError('external TLS dependency closure invocation changed')
    if command.get('timed_out') or command.get('exit_code') != 0 or 'not found' in text['stdout']:
        raise ValueError('external TLS dependency closure is incomplete')
    external_dependencies = []
    for i, value in enumerate(re.findall(r'=>\s+(\S+)\s+\(0x', text['stdout'])):
        label = f'external-tls-dependency-{i}'
        external_dependencies.append(label)
        scan_inputs[label] = _resolve_capture_path(value, root, work, sdks)
    external_fixture = report.get('external_tls_fixture')
    if not isinstance(external_fixture, dict) or external_fixture.get('dynamic_dependencies') != external_dependencies:
        raise ValueError('external TLS dependency inventory differs from its retained closure')
    return scan_inputs


def gating_command_ids(report: dict, sdk_count: int, scan_inputs: dict[str, Path]) -> set[str]:
    """Derive required commands from fixed inputs and an independently derived scan inventory."""
    prefix = command_prefix(report)
    ids = {prefix + 'tool-' + name.replace('+', 'p') for name in TOOL_PROGRAMS}
    ids |= {prefix + 'backend-' + program for program in ('cc1', 'cc1plus')}
    ids |= {prefix + name for name in ('boundary-tests', 'certificate', 'certificate-der',
        'key-der', 'external-tls-closure')}
    for index in range(sdk_count):
        ids |= {prefix + f'fixture-{index}-compile', prefix + f'fixture-{index}-archive',
                prefix + f'sdk-{index}-compiler-version', prefix + f'sdk-{index}-cjpm-version',
                prefix + f'coexist-{index}-build', prefix + f'closure-{index}-compiler',
                prefix + f'closure-{index}-runtime', prefix + f'closure-{index}-coexist'}
        ids |= {prefix + f'abi-{index}-to-{runtime}' for runtime in range(sdk_count)}
    for base in scan_inputs:
        scan = report['scans'].get(base)
        symbol_command = scan.get('symbol_inventory_command') if isinstance(scan, dict) else None
        expected_symbol_command = prefix + base + '-symbols'
        if symbol_command != expected_symbol_command:
            raise ValueError('scanner command does not match independent scan inventory: ' + base)
        command_base = prefix + base
        ids |= {command_base + '-' + suffix for suffix in SCAN_SUFFIXES}
    return ids


def verify_command_inventory(report: dict, sdk_count: int, scan_inputs: dict[str, Path]) -> None:
    """Every gating step is recorded exactly once, with each scan bound to its declared artifact."""
    scans = report.get('scans')
    expected = set(scan_inputs)
    if not isinstance(scans, dict) or set(scans) != expected:
        actual = set(scans) if isinstance(scans, dict) else set()
        raise ValueError('binary scan inventory is incomplete; missing='
            + repr(sorted(expected - actual)) + ' extra=' + repr(sorted(actual - expected)))
    ids = [command['id'] for command in report['commands']]
    if len(ids) != len(set(ids)):
        raise ValueError('native command inventory contains duplicates')
    required = gating_command_ids(report, sdk_count, scan_inputs)
    if set(ids) != required:
        raise ValueError('native command inventory is incomplete; missing='
            + repr(sorted(required - set(ids))) + ' extra=' + repr(sorted(set(ids) - required)))


def verify_scan_inputs(report: dict, scan_inputs: dict[str, Path], root: Path,
                       work: Path, sdks: list[Path]) -> None:
    """Require each scan label to identify its independently selected artifact."""
    for label, path in scan_inputs.items():
        scan = report['scans'].get(label)
        expected_path = _normalize_capture_path(str(path), root, work, sdks)
        if not isinstance(scan, dict) or scan.get('path') != expected_path:
            raise ValueError('scan path differs from its declared artifact: ' + label)




def verify_scan_verdicts(report: dict, root: Path = ROOT, scratch: Path | None = None) -> None:
    """Recompute every derived ELF/loader verdict from the bound scanner output."""
    for name, scan in report['scans'].items():
        base = scan['symbol_inventory_command'].removesuffix('-symbols')
        chain = {}
        for suffix in SCAN_SUFFIXES:
            command, text = bound_command(report, base + '-' + suffix, root)
            # The recorded invocation must be the scanner on the very input the verdict describes.
            if command.get('argv') != [*SCAN_ARGV[suffix], scan['path']]:
                raise ValueError('scan command does not scan its recorded input: ' + base + '-' + suffix)
            if command.get('timed_out'):
                raise ValueError('scan diagnostic timed out: ' + name + '-' + suffix)
            allowed = (0, 1) if suffix == 'symbols' else (0,)
            if command['exit_code'] not in allowed:
                raise ValueError('scan command did not complete: ' + name + '-' + suffix)
            chain[suffix] = text
        # A published log may truncate the disassembly, but only the complete raw output it binds
        # can prove mnemonic counts; without that raw output this verdict is unavailable.
        command = next(record for record in report['commands']
            if record['id'] == base + '-disassembly')
        if scratch is None:
            raise ValueError('complete disassembly is not selected: ' + name)
        counted = raw_disassembly_isa(chain['disassembly']['stdout'],
            disassembly_binding(command), scratch, base + '-disassembly')
        expected = scan_fields(chain['headers']['stdout'], chain['dynamic']['stdout'],
            chain['versions']['stdout'], chain['notes']['stdout'], chain['symbols']['stdout'], counted)
        if scan.get('raw_isa_presence') != counted:
            raise ValueError('scan ISA observation is not backed by a complete disassembly: ' + name)
        for field, value in expected.items():
            if scan.get(field) != value:
                raise ValueError('scan verdict differs from its captured output: ' + name + '/' + field)
        if scan['absolute_path_hazards'] and not name.startswith('external-tls-'):
            raise ValueError('deployment-bearing scan has an absolute loader path: ' + name)


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
        digest = artifact_byte_digest(path).to_json()
        for old in self.prior.get('scans', {}).values():
            # Reuse prior observations only when their inputs, tools and scanner logic are identical.
            if old['path'] != self.normalize(str(path)) or not artifact_byte_sha256_equal(old['digest'], digest):
                continue
            if not text_evidence_sha256_equal(old.get('scanner'), scanner_digest()):
                continue
            old_base = old['symbol_inventory_command'].removesuffix('-symbols')
            old_ids = {old_base + '-' + suffix for suffix in SCAN_SUFFIXES}
            records = [record for record in self.prior['commands'] if record.get('id') in old_ids]
            if len(records) != len(SCAN_SUFFIXES) or {record['id'] for record in records} != old_ids:
                continue
            try:
                for record in records:
                    for key in ('stdout', 'stderr'):
                        log = evidence_path(record[key], ROOT, record['id'])
                        if not text_evidence_sha256_equal(record[key]['digest'], text_evidence_digest(log).to_json()):
                            raise ValueError('prior scan diagnostic changed')
                disassembly = next(record for record in records
                    if record['id'] == old_base + '-disassembly')
                # A reused observation still needs the complete raw output its verdict was derived from.
                raw_disassembly_isa(evidence_path(disassembly['stdout'], ROOT,
                    disassembly['id']).read_text(), disassembly_binding(disassembly),
                    self.work, disassembly['id'])
            except (KeyError, TypeError, ValueError, StopIteration):
                continue
            current_base = self.prefix + label
            for record in records:
                suffix = record['id'][len(old_base) + 1:]
                self.commands.append({**record, 'id': current_base + '-' + suffix} if suffix != 'disassembly'
                else {**record, 'id': current_base + '-' + suffix,
                    'disassembly_raw': disassembly_binding(record)})
            shutil.copyfile(self.work / (old_base + '-disassembly.stdout.raw'),
                self.work / (current_base + '-disassembly.stdout.raw'))
            rebound = dict(old)
            rebound['symbol_inventory_command'] = current_base + '-symbols'
            return rebound
        header = self.run(label+'-headers', ['readelf', '-hW', str(path)])
        dynamic = self.run(label+'-dynamic', ['readelf', '-dW', str(path)])
        symbol_versions = self.run(label+'-versions', ['readelf', '-VW', str(path)])
        notes = self.run(label+'-notes', ['readelf', '-nW', str(path)])
        symbols = self.run(label+'-symbols', ['nm', '-g', '--defined-only', str(path)], allow_failure=True)
        self.run(label+'-disassembly', ['objdump', '-d', '--no-show-raw-insn', str(path)])
        disassembly = self.commands[-1]
        raw = self.work / f"{disassembly['id']}.stdout.raw"
        disassembly['disassembly_raw'] = {
            'truncated': truncated_digest((self.output / f"{disassembly['id']}.stdout.log").read_text()) is not None,
            'digest': artifact_byte_digest(raw).to_json()}
        isa_counts = count_mnemonics(raw.read_text(errors='replace'))
        return {'path': self.normalize(str(path)), 'digest': digest,
                'scanner': scanner_digest(), **scan_fields(header, dynamic, symbol_versions,
                    notes, symbols, isa_counts),
                'symbol_inventory_command': self.prefix+label+'-symbols'}


def install_selected_archive(archive: Path, work: Path) -> Path:
    """Install the selected archive, never letting a previous attempt's tree stand in for it."""
    installed = work / 'wirestack'
    for stale in (work / 'install', installed):
        if stale.is_symlink() or stale.is_file():
            stale.unlink()
        elif stale.exists():
            shutil.rmtree(stale)
    release.extract_archive(archive.resolve(), work / 'install').rename(installed)
    return installed


def bind_installed_payload(report: dict, archive: Path) -> list[str]:
    """Bind the selected archive and return every native archive input in its payload."""
    payload, manifest = release.read_verified_payload(archive)
    if not schema_text_sha256_equal(report.get('payload_sha256'), manifest['payload_sha256']):
        raise ValueError('installed payload is not the selected archive; recapture required')
    return sorted(path for path in payload if path.endswith('.a'))

def verify_consumers(report: dict, consumers: list[tuple[str, str, Path]],
                     replacements: dict) -> None:
    """Require the complete profile/app identity set and its compiled optional archives."""
    def normalize(text: str) -> str:
        for label, value in replacements.items():
            text = text.replace(str(value), label)
        return text

    expected = {(profile, app) for profile in CONSUMER_PROFILES for app in CONSUMER_APPS}
    declared = [(profile, app) for profile, app, _ in consumers]
    if len(declared) != len(expected) or set(declared) != expected:
        raise ValueError('binary verification requires every declared profile/app installed consumer exactly once')
    captured = report.get('consumers', {})
    if set(captured) != {profile + '/' + app for profile, app in expected}:
        raise ValueError('installed consumer inventory changed; recapture required')
    for profile, app, path in consumers:
        label = normalize(str(path.resolve()))
        if captured[profile + '/' + app] != label:
            raise ValueError('installed consumer differs from its capture: ' + profile + '/' + app)
    scans = {}
    for name, scan in report['scans'].items():
        if name.startswith('installed-consumer-'):
            if scan['path'] in scans:
                raise ValueError('installed consumer ELF scans repeat a path')
            scans[scan['path']] = scan
    if set(scans) != set(captured.values()):
        raise ValueError('installed consumer ELF scans do not cover every declared consumer')
    for profile, app, path in consumers:
        scan = scans[normalize(str(path.resolve()))]
        if not artifact_byte_sha256_equal(scan['digest'], artifact_byte_digest(path.resolve()).to_json()):
            raise ValueError('installed consumer changed: ' + profile + '/' + app)
    archives = report.get('compiled_optional_modules', {})
    expected_archives = {}
    for profile, app, binary in consumers:
        module_root = binary.resolve().parent.parent / 'wirestack'
        for module in OPTIONAL_MODULES:
            label = f'optional-{profile}-{app}-{module}'
            expected_archives[label] = normalize(str(module_root / f'libwirestack.{module}.a'))
    if archives != expected_archives:
        raise ValueError('compiled optional archive inventory is incomplete or misbound to its installed consumers')
    for label, path in archives.items():
        resolved = path
        for token, value in replacements.items():
            resolved = resolved.replace(token, str(value))
        if not Path(resolved).is_file():
            raise ValueError('compiled optional archive is missing: ' + label)
        scan = report['scans'].get(label)
        if scan is None or not artifact_byte_sha256_equal(scan['digest'], artifact_byte_digest(Path(resolved)).to_json()):
            raise ValueError('compiled optional archive changed: ' + label)



def verify_abi_matrix(report: dict, root: Path, work: Path, sdks: list[Path], wrapper: Path,
                      openssl_library: Path, openssl_crypto_library: Path) -> None:
    """Bind every cross-SDK row to the command for its declared binary and runtime SDK."""
    prefix = command_prefix(report)
    rows = {row['command']: row for row in report['abi_matrix']}
    if len(rows) != len(report['abi_matrix']):
        raise ValueError('ABI matrix rows do not name distinct commands')
    recorded = [command['id'] for command in report['commands']
        if command['id'].startswith(prefix + 'abi-')]
    if len(recorded) != len(set(recorded)) or set(recorded) != set(rows):
        raise ValueError('ABI command inventory does not match the recorded matrix')
    for command_id, row in rows.items():
        expected_id = prefix + f'abi-{row["built_sdk"]}-to-{row["runtime_sdk"]}'
        if command_id != expected_id:
            raise ValueError('ABI row is not bound to its own command: ' + command_id)
        command, text = bound_command(report, command_id, root)
        if command['exit_code'] != 0 or command.get('timed_out'):
            raise ValueError('ABI qualification command did not succeed: ' + command_id)
        binary = work / f'coexist-{row["built_sdk"]}/target/release/bin/main'
        sdk = sdks[row['runtime_sdk']]
        invocation = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', str(work),
            str(work), '--tmpfs', str(root), '--chdir', str(work), '--', str(wrapper),
            '--sdk-root', str(sdk), '--cwd', str(work), str(binary),
            str(work / 'certificate.der'), str(work / 'key.pk8')]
        expected_argv = [_normalize_capture_path(value, root, work, sdks) for value in invocation]
        expected_cwd = _normalize_capture_path(str(work), root, work, sdks)
        if command.get('cwd') != expected_cwd or command.get('argv') != expected_argv:
            raise ValueError('ABI command invocation differs from its built binary and runtime SDK: ' + command_id)
        expected_environment = {
            'WIRESTACK_FIXTURE_OPENSSL_LIBRARY': _normalize_capture_path(
                str(openssl_library.resolve()), root, work, sdks),
            'WIRESTACK_FIXTURE_OPENSSL_CRYPTO_LIBRARY': _normalize_capture_path(
                str(openssl_crypto_library.resolve()), root, work, sdks),
            'WIRESTACK_FIXTURE_CA_FILE': _normalize_capture_path(str(work / 'certificate.pem'),
                root, work, sdks),
            'LD_DEBUG': 'libs'}
        if command.get('environment') != expected_environment:
            raise ValueError('ABI command environment differs from its declared TLS fixtures: ' + command_id)
        # The behavior proof is re-derived from retained stdout, never from the verdict field.
        validate_behavior(text['stdout'])
        if row.get('runtime_loading_proof') != command['stderr']:
            raise ValueError('ABI row loading proof is not its own command log: ' + command_id)
        library = _normalize_capture_path(str(sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'),
            root, work, sdks)
        if row.get('runtime_loaded_library') != library or library not in re.findall(
                r'calling init:\s+(\S+)', text['stderr']):
            raise ValueError('ABI row did not load its recorded runtime: ' + command_id)
        built = report['scans'].get('coexist-' + str(row['built_sdk']))
        expected_binary = _normalize_capture_path(str(binary), root, work, sdks)
        if built is None or built.get('path') != expected_binary \
                or not artifact_byte_sha256_equal(row['binary_digest'], built['digest']):
            raise ValueError('ABI row executed a binary other than its built artifact: ' + command_id)


def verify(report: dict, archive: Path, sdks: list[Path], fixture: Path, work: Path,
           wrapper: Path, openssl_library: Path, openssl_crypto_library: Path,
           consumers: list[tuple[str, str, Path]] = ()) -> None:
    if len(sdks) != len(report['sdk_inputs']) or report['status'] != 'PASS':
        raise ValueError('incomplete report or different SDK matrix')
    validate_abi_matrix(report['abi_matrix'], len(sdks))
    if not artifact_byte_sha256_equal(report['archive_digest'], artifact_byte_digest(archive).to_json()):
        raise ValueError('archive changed; recapture required')
    archive_scans = bind_installed_payload(report, archive)
    current = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in fixture.rglob('*')
               if p.is_file() and p.suffix in ('.cj', '.c', '.toml')}
    current['tools/m12_002_binary.py'] = text_evidence_digest(Path(__file__)).to_json()
    current['tools/tests/test_m12_002_binary.py'] = text_evidence_digest(ROOT / 'tools/tests/test_m12_002_binary.py').to_json()
    if current.keys() != report['fixture_inputs'].keys() or any(not text_evidence_sha256_equal(
            current[k], report['fixture_inputs'][k]) for k in current):
        raise ValueError('fixture or capture tool changed; recapture required')
    if report.get('helper_sources', {}).keys() != set(HELPER_SOURCES):
        raise ValueError('binary verification helper inventory changed; recapture required')
    for name, digest in helper_sources().items():
        if not text_evidence_sha256_equal(report['helper_sources'][name], digest):
            raise ValueError('binary verification helper changed: ' + name)
    expected_sources = {str(p.relative_to(ROOT)) for p in release.production_sources(ROOT)}
    if set(report['production_inputs']) != expected_sources:
        raise ValueError('production source inventory changed; recapture required')
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
    scan_inputs = expected_scan_inputs(report, archive_scans, sdks, list(consumers), work,
        wrapper, openssl_library)
    verify_command_inventory(report, len(sdks), scan_inputs)
    verify_scan_inputs(report, scan_inputs, ROOT, work, sdks)
    for name, scan in report['scans'].items():
        path = scan['path']
        for label, replacement in replacements.items():
            path = path.replace(label, str(replacement))
        if not artifact_byte_sha256_equal(scan['digest'], artifact_byte_digest(Path(path)).to_json()):
            raise ValueError('scanned binary/archive/library changed; recapture required')
        if not text_evidence_sha256_equal(scan.get('scanner', {}), scanner_digest()):
            raise ValueError('scan verdicts predate the current scanner; recapture required')
    abi_prefix = command_prefix(report) + 'abi-'
    for record in report['commands']:
        for key in ('stdout', 'stderr'):
            path = evidence_path(record[key], ROOT, record['id'])
            if not path.is_file() or not text_evidence_sha256_equal(
                    record[key]['digest'], text_evidence_digest(path).to_json()):
                raise ValueError('diagnostic log changed')
        if record.get('timed_out'):
            raise ValueError('gating command timed out: ' + record['id'])
        expected_failure = record['id'].startswith(abi_prefix)
        if not expected_failure and record['exit_code'] != 0:
            raise ValueError('gating command failed: ' + record['id'])
    verify_scan_verdicts(report, ROOT, work)
    verify_abi_matrix(report, ROOT, work, sdks, wrapper, openssl_library, openssl_crypto_library)
    verify_consumers(report, list(consumers), replacements)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sdk', action='append', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--wrapper', type=Path, required=True)
    parser.add_argument('--openssl-library', type=Path, required=True)
    parser.add_argument('--openssl-crypto-library', type=Path, required=True)
    parser.add_argument('--consumer', action='append', default=[],
        help='<profile>/<app>=<installed executable> for every stable-native and candidate-native app')
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
        consumers = [consumer_identity(value) for value in args.consumer]
        verify(selected_report, args.archive, sdks, fixture, work, args.wrapper,
            args.openssl_library, args.openssl_crypto_library, consumers)
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
                              for p in release.production_sources(ROOT)}, 'native_tool_inputs': {},
        'helper_sources': helper_sources()}
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
        installed = install_selected_archive(args.archive, work)
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
        archive_paths = sorted(installed.rglob('*.a'),
            key=lambda path: path.relative_to(installed).as_posix())
        for i, path in enumerate(archive_paths):
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
        installed_consumers = sorted((consumer_identity(value) for value in args.consumer),
            key=lambda item: (item[0], item[1]))
        report['consumers'] = {}
        for profile, app, binary in installed_consumers:
            if profile + '/' + app in report['consumers']:
                raise ValueError('consumer declarations repeat a profile/app identity')
            report['consumers'][profile + '/' + app] = capture.normalize(str(binary.resolve()))
        if set(report['consumers']) != {profile + '/' + app for profile in CONSUMER_PROFILES
                for app in CONSUMER_APPS}:
            raise ValueError('capture requires every declared profile/app installed consumer exactly once')
        for i, (profile, app, binary) in enumerate(installed_consumers):
            report['scans'][f'installed-consumer-{i}'] = capture.scan(f'installed-consumer-{i}', binary.resolve())
        report['compiled_optional_modules'] = {}
        for profile, app, binary in installed_consumers:
            module_root = binary.resolve().parent.parent / 'wirestack'
            for module in OPTIONAL_MODULES:
                archive = module_root / f'libwirestack.{module}.a'
                if not archive.is_file():
                    raise ValueError(f'compiled optional module missing: {archive}')
                label = f'optional-{profile}-{app}-{module}'
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
