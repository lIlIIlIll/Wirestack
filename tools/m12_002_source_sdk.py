#!/usr/bin/env python3
"""Capture installed-source SDK compatibility, relocation and isolated CA behavior."""
from __future__ import annotations
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import re
import select
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools import m11_004_installed_consumers as consumers
from tools.evidence_digest import (artifact_byte_digest, text_evidence_digest,
    artifact_byte_sha256_equal, text_evidence_sha256_equal)

# Implementation closure: the runner plus every imported helper that shapes the captured
# verdict. Their bytes are part of the binding, so a changed helper invalidates old evidence.
HELPER_SOURCES = ('tools/m12_002_source_sdk.py', 'tools/m7_021_linux_release.py',
    'tools/m11_004_installed_consumers.py', 'tools/m11_003_native_websocket.py',
    'tools/evidence_digest.py')
# The complete source-compatibility command inventory. A report that omits, duplicates or
# reclassifies any of these cannot describe the accepted contract.
EXPECTED_COMMANDS = {
    'cjc': 0, 'cjpm': 0, 'native-cc': 0, 'fixture-openssl': 0, 'checkout-hidden': 0,
    'cli-build': 0, 'decoded-build': 0, 'streams-build': 0, 'service-build': 0, 'trust-build': 0,
    'certificate': 0, 'certificate-der': 0, 'untrusted': 0, 'untrusted-der': 0, 'key-der': 0,
    'cli-help': 0, 'cli-dependencies': 0, 'cli-acceptance': 0,
    'decoded-help': 0, 'decoded-dependencies': 0, 'decoded-acceptance': 0,
    'streams-help': 0, 'streams-dependencies': 0, 'streams-acceptance': 0,
    'service-help': 0, 'service-dependencies': 0, 'service-acceptance': 0,
    'service-operational': 0, 'cli-download': 0, 'decoded-download': 0,
    'explicit-ca': 0, 'missing-explicit-ca': 1, 'incorrect-explicit-ca': 1,
    'system-ca-installed': 0, 'system-ca-missing': 1, 'system-ca-incorrect': 1,
    'streams-operational': 0, 'sse-operational': 0, 'wss-operational': 0}
CA_CHECKS = ('explicit-ca', 'missing-explicit-ca', 'incorrect-explicit-ca',
    'system-ca-installed', 'system-ca-missing', 'system-ca-incorrect')
# The exact terminal diagnostic each CA scenario must reproduce. The capture refuses to
# record a scenario until it prints this; verification re-reads it from the retained log.
CA_DIAGNOSTICS = {'explicit-ca': 'TRUST_DOWNLOAD_PASS bytes=8',
    'missing-explicit-ca': 'ERROR ca_file_missing',
    'incorrect-explicit-ca': 'ERROR certificate_untrusted phase=tls_handshake',
    'system-ca-installed': 'TRUST_DOWNLOAD_PASS bytes=8',
    'system-ca-missing': 'ERROR trust_unavailable',
    'system-ca-incorrect': 'ERROR certificate_untrusted phase=tls_handshake'}
TLS_FIXTURE_FILES = ('certificate.key', 'certificate.pem', 'certificate.der',
    'untrusted.key', 'untrusted.pem', 'untrusted.der', 'key.der')
# Every command is bound to the exact wrapper mount set, working directory and argument vector it
# must have had. A report cannot move one scenario's retained output onto another command, and a
# negative TLS scenario cannot be credited from a process that ran something else.
MOUNT_PREFIX = ('bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', '<scratch>',
    '<scratch>', '--tmpfs', '<repo>')
RELOCATED_MOUNT = ('--tmpfs', '<scratch>/original')
# A host that has /etc/pki additionally hides it. That mount is host-conditional, so verification
# accepts and strips it rather than pinning a host property into portable evidence.
HOST_CA_MOUNT = ('--tmpfs', '/etc/pki')
CA_MOUNTS = {'ca-installed': ('--tmpfs', '/etc/ssl', '--dir', '/etc/ssl/certs', '--ro-bind',
        '<scratch>/certificate.pem', '/etc/ssl/certs/ca-certificates.crt'),
    'ca-missing': ('--tmpfs', '/etc/ssl', '--dir', '/etc/ssl/certs'),
    'ca-incorrect': ('--tmpfs', '/etc/ssl', '--dir', '/etc/ssl/certs', '--ro-bind',
        '<scratch>/untrusted.pem', '/etc/ssl/certs/ca-certificates.crt')}
PORT = '{port}'
CERTIFICATES = ('<scratch>/certificate.der', '<scratch>/key.der', '<scratch>/untrusted.der')
CONSUMER_DIRECTORY = '<scratch>/relocated/consumers/'
CONSUMER_BINARY = '/target/release/bin/main'


def consumer(app: str, *arguments: str) -> list[str]:
    """The relocated installed consumer binary for one M11-004 application."""
    return [CONSUMER_DIRECTORY + app + CONSUMER_BINARY, *arguments]


def _wrapped(cwd: str, mount: tuple[str, ...], argv: list[str]) -> tuple[str, list[str]]:
    return cwd, [*MOUNT_PREFIX, *mount, '--chdir', cwd, '--', *argv]


def _contracts() -> dict[str, tuple[tuple[str, list[str]], ...]]:
    """Every accepted (cwd, argv) shape for each source-compatibility command."""
    table: dict[str, tuple[tuple[str, list[str]], ...]] = {}
    relocated = RELOCATED_MOUNT

    def fixed(name: str, shape: tuple[str, list[str]]) -> None:
        table[name] = (shape,)

    for probe, inner in (('cjc', ['cjc', '--version']), ('cjpm', ['cjpm', '--version']),
                         ('native-cc', ['cc', '--version']), ('fixture-openssl', ['openssl', 'version'])):
        fixed(probe, _wrapped('<scratch>', (), inner))
    fixed('checkout-hidden', _wrapped('<scratch>', (), ['python3', '-c',
        "from pathlib import Path; assert not any(Path('<repo>').iterdir()); print('CHECKOUT_HIDDEN_PASS')"]))
    for app in ('cli', 'decoded', 'streams', 'service'):
        fixed(app + '-build', _wrapped('<scratch>/original/consumers/' + app, (), ['cjpm', 'build']))
    fixed('trust-build', _wrapped(CONSUMER_DIRECTORY + 'trust', relocated, ['cjpm', 'build']))
    table['trust-build'] += (_wrapped('<scratch>/original/consumers/trust', (), ['cjpm', 'build']),)
    fixed('certificate', ('<scratch>', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-days', '2', '-subj', '/CN=example.test', '-keyout', '<scratch>/certificate.key',
        '-out', '<scratch>/certificate.pem', '-addext', 'subjectAltName=DNS:example.test,IP:192.0.2.1']))
    fixed('untrusted', ('<scratch>', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-days', '2', '-subj', '/CN=other.test', '-keyout', '<scratch>/untrusted.key',
        '-out', '<scratch>/untrusted.pem']))
    for name, source, target in (('certificate-der', 'certificate.pem', 'certificate.der'),
                                 ('untrusted-der', 'untrusted.pem', 'untrusted.der')):
        fixed(name, ('<scratch>', ['openssl', 'x509', '-in', '<scratch>/' + source,
            '-outform', 'DER', '-out', '<scratch>/' + target]))
    fixed('key-der', ('<scratch>', ['openssl', 'pkcs8', '-topk8', '-nocrypt', '-in',
        '<scratch>/certificate.key', '-outform', 'DER', '-out', '<scratch>/key.der']))
    for app in ('cli', 'decoded', 'streams', 'service'):
        directory = CONSUMER_DIRECTORY + app
        fixed(app + '-help', _wrapped(directory, relocated, consumer(app, '--help')))
        fixed(app + '-dependencies', _wrapped(directory, relocated,
            ['readelf', '-d', directory + CONSUMER_BINARY]))
        fixed(app + '-acceptance', _wrapped(directory, relocated, consumer(app, 'self-check', *CERTIFICATES)))
    table['cli-acceptance'] = (_wrapped(CONSUMER_DIRECTORY + 'cli', relocated,
        consumer('cli', 'self-check', *CERTIFICATES, PORT)),)
    for app in ('cli', 'decoded'):
        # A resumed capture downloads into a differently named file; both spellings are accepted.
        table[app + '-download'] = tuple(_wrapped(CONSUMER_DIRECTORY + app, relocated,
            consumer(app, 'download', '--url', 'https://192.0.2.1:' + PORT + '/download',
                '--output', '<scratch>/' + app + suffix, '--trust', CERTIFICATES[0]))
            for suffix in ('-download.bin', '-resumed-download.bin'))
    for name, mode, certificate, mount in (
            ('explicit-ca', 'explicit', CERTIFICATES[0], relocated),
            ('missing-explicit-ca', 'explicit', '<scratch>/missing.der', relocated),
            ('incorrect-explicit-ca', 'explicit', CERTIFICATES[2], relocated),
            ('system-ca-installed', 'system', None, (*relocated, *CA_MOUNTS['ca-installed'])),
            ('system-ca-missing', 'system', None, (*relocated, *CA_MOUNTS['ca-missing'])),
            ('system-ca-incorrect', 'system', None, (*relocated, *CA_MOUNTS['ca-incorrect']))):
        argv = consumer('trust', mode, 'https://192.0.2.1:' + PORT + '/download')
        argv += [certificate] if certificate else []
        shape = _wrapped(CONSUMER_DIRECTORY + 'trust', mount, argv)
        fixed(name, shape)
        if name.startswith('system-ca-'):
            table[name] += (_wrapped(CONSUMER_DIRECTORY + 'trust', (*mount, *HOST_CA_MOUNT), argv),)
    fixed('service-operational', _wrapped(CONSUMER_DIRECTORY + 'service', relocated,
        consumer('service', 'serve', '--port', '0', '--certificate', CERTIFICATES[0],
            '--key', CERTIFICATES[1], '--budget-ms', '60000')))
    fixed('streams-operational', _wrapped(CONSUMER_DIRECTORY + 'streams', relocated,
        consumer('streams', 'fixture', *CERTIFICATES[:2])))
    fixed('sse-operational', _wrapped(CONSUMER_DIRECTORY + 'streams', relocated,
        consumer('streams', 'sse', 'https://192.0.2.1:' + PORT + '/stream', '--trust',
            CERTIFICATES[0], '--max-events', '1', '--recover', '0')))
    fixed('wss-operational', _wrapped(CONSUMER_DIRECTORY + 'streams', relocated,
        consumer('streams', 'websocket', 'wss://192.0.2.1:' + PORT + '/socket', '--trust',
            CERTIFICATES[0], '--max-frames', '1', '--recover', '0', '--command', 'echo')))
    return table


COMMAND_CONTRACTS = _contracts()


def helper_sources() -> dict:
    """Bind the capture runner and every imported helper implementation by typed digest."""
    return {name: text_evidence_digest(ROOT / name).to_json() for name in HELPER_SOURCES}


def native_compiler() -> Path:
    """Resolve the host C compiler without fabricating a path for a missing tool."""
    selected = shutil.which('cc')
    if not selected:
        raise ValueError('native C compiler cc is unavailable; the capture cannot bind build inputs')
    return Path(selected).resolve()


def native_compiler_digest() -> dict:
    return artifact_byte_digest(native_compiler()).to_json()


def sdk_binding(sdk: Path) -> dict:
    """Bind the compiler, CJPM, runtime, tool libraries, standard archives and import metadata."""
    files = {str(path.relative_to(sdk)): artifact_byte_digest(path).to_json()
        for folder in ('bin', 'tools/bin', 'runtime', 'lib', 'modules', 'tools/lib')
        for path in sorted((sdk / folder).rglob('*'))
        if path.is_file() and (folder in ('runtime', 'modules', 'tools/lib') or path.name in ('cjc', 'cjpm') or path.suffix in ('.a', '.so'))}
    for name, folder in (('cjc', 'bin'), ('cjpm', 'tools/bin')):
        if not (sdk / folder / name).is_file():
            raise ValueError('SDK is missing compiler or CJPM')
    if not any('libcangjie-runtime.so' in path for path in files):
        raise ValueError('SDK runtime binding is missing')
    return files


def consumer_source_digests() -> dict:
    """Complete consumer-source inventory: every application file plus the task-owned SDK fixture."""
    sources = {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json()
        for name in consumers.APP_NAMES for path in consumers.app_files(consumers.APPS / name)}
    sources.update({str(path.relative_to(ROOT)): text_evidence_digest(path).to_json()
        for path in [ROOT / 'examples/linux/m12_002/sdk/cjpm.toml', ROOT / 'examples/linux/m12_002/sdk/src/main.cj']})
    return sources


def verify_consumer_sources(report: dict) -> None:
    expected = consumer_source_digests()
    recorded = report.get('consumer_sources')
    if not isinstance(recorded, dict) or recorded.keys() != expected.keys():
        raise ValueError('consumer source inventory changed; recompile and rerun consumers')
    for relative, digest in expected.items():
        if not text_evidence_sha256_equal(recorded[relative], digest):
            raise ValueError('consumer source changed')


def verify_tls_fixtures(report: dict) -> None:
    """The TLS material every acceptance run consumed must be inventoried by the report."""
    recorded = report.get('tls_fixtures')
    if not isinstance(recorded, dict) or recorded.keys() != set(TLS_FIXTURE_FILES):
        raise ValueError('retained TLS fixture inventory is incomplete')
    for name, digest in recorded.items():
        if not isinstance(digest, dict) or digest.get('domain') != 'artifact-bytes-v1' \
                or not artifact_byte_sha256_equal(digest, digest):
            raise ValueError('retained TLS fixture is not byte-bound: ' + name)
    if recorded['certificate.der'] == recorded['untrusted.der'] or recorded['certificate.der'] == recorded['key.der']:
        raise ValueError('retained TLS fixtures are not distinct')


def verify_helper_sources(report: dict) -> None:
    expected = helper_sources()
    recorded = report.get('helper_sources')
    if not isinstance(recorded, dict) or recorded.keys() != expected.keys():
        raise ValueError('evidence helper inventory changed; recapture required')
    for name, digest in expected.items():
        if not text_evidence_sha256_equal(recorded[name], digest):
            raise ValueError('evidence helper changed: ' + name)


def _evidence_path(entry: dict, evidence: Path, command_id: str, failure: str) -> Path:
    """Resolve evidence beneath its root, including symlink targets."""
    relative = entry['path']
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise ValueError(failure + ': ' + command_id)
    try:
        evidence_root = evidence.resolve()
        path = (evidence / relative).resolve()
        path.relative_to(evidence_root)
    except (OSError, RuntimeError, ValueError):
        raise ValueError(failure + ': ' + command_id) from None
    return path


def evidence_log(entry: dict, evidence: Path, command_id: str) -> Path:
    """Resolve a retained log inside the evidence tree only; a report may not point elsewhere."""
    path = _evidence_path(entry, evidence, command_id, 'command evidence path escapes its evidence tree')
    if not path.is_file():
        raise ValueError('command evidence is missing: ' + command_id)
    if not text_evidence_sha256_equal(entry['digest'], text_evidence_digest(path).to_json()):
        raise ValueError('command evidence changed: ' + command_id)
    return path


def evidence_payload(entry: dict, evidence: Path, command_id: str, failure: str) -> Path:
    """The retained log of a command that is being re-read, with a resume-specific failure."""
    path = _evidence_path(entry, evidence, command_id, failure)
    if not path.is_file() or not text_evidence_sha256_equal(entry['digest'], text_evidence_digest(path).to_json()):
        raise ValueError(failure + ': ' + command_id)
    return path


def verify_command_argv(command: dict, shape: tuple[str, list[str]]) -> None:
    """Replay one declared (cwd, argv) shape; only the scenario's own ephemeral port may vary."""
    cwd, argv = shape
    actual_cwd, actual_argv = command.get('cwd'), command.get('argv')
    if actual_cwd != cwd or not isinstance(actual_argv, list) or len(actual_argv) != len(argv):
        raise ValueError('command shape changed: ' + command['id'])
    for expected, actual in zip(argv, actual_argv):
        pattern = re.escape(expected).replace(re.escape(PORT), r'[1-9][0-9]{0,4}')
        if not isinstance(actual, str) or re.fullmatch(pattern, actual) is None:
            raise ValueError('command shape changed: ' + command['id'])


def verify_command_contract(command: dict) -> None:
    """Require the command's own recorded invocation to be one declared, reproducible shape."""
    shapes = COMMAND_CONTRACTS.get(command['id'])
    if not shapes:
        raise ValueError('command has no declared contract: ' + command['id'])
    for shape in shapes:
        try:
            verify_command_argv(command, shape)
            return
        except ValueError:
            continue
    raise ValueError('command shape changed: ' + command['id'])


def verify_ca_checks(report: dict, evidence: Path) -> None:
    """Re-derive every CA scenario from its own retained output instead of trusting its claim."""
    recorded = report.get('ca_checks')
    if not isinstance(recorded, dict) or recorded.keys() != set(CA_CHECKS):
        raise ValueError('CA evidence inventory is incomplete')
    commands = {command['id']: command for command in report['commands']}
    for name in CA_CHECKS:
        entry = recorded[name]
        command = commands[name]
        expected = EXPECTED_COMMANDS[name]
        if not isinstance(entry, dict) or entry.get('status') != 'PASS':
            raise ValueError('CA scenario is not recorded as passed: ' + name)
        if entry.get('expected_exit') != expected or command['expected_exit_code'] != expected:
            raise ValueError('CA scenario expectation changed: ' + name)
        if entry.get('diagnostic') != CA_DIAGNOSTICS[name]:
            raise ValueError('CA scenario diagnostic changed: ' + name)
        output = evidence_log(command['stdout'], evidence, name).read_text()
        if output.strip() != CA_DIAGNOSTICS[name]:
            raise ValueError('CA scenario output does not match its diagnostic: ' + name)
        if evidence_log(command['stderr'], evidence, name).read_text().strip():
            raise ValueError('CA scenario reported diagnostics on stderr: ' + name)
        verify_command_contract(command)


def verify_command_inventory(commands: list[dict], evidence: Path) -> None:
    """Require the complete, unique source-compatibility command set with its native outcome."""
    ids = [command['id'] for command in commands]
    if len(ids) != len(set(ids)):
        raise ValueError('source compatibility command inventory contains duplicates')
    if set(ids) != set(EXPECTED_COMMANDS):
        missing = sorted(set(EXPECTED_COMMANDS) - set(ids))
        extra = sorted(set(ids) - set(EXPECTED_COMMANDS))
        raise ValueError('source compatibility command inventory is incomplete; missing=' + repr(missing) + ' extra=' + repr(extra))
    for command in commands:
        expected = EXPECTED_COMMANDS[command['id']]
        if command.get('timed_out'):
            raise ValueError('command timed out: ' + command['id'])
        if command['expected_exit_code'] != expected:
            raise ValueError('command expectation reclassified: ' + command['id'])
        if command['exit_code'] != expected:
            raise ValueError('command did not satisfy its native outcome: ' + command['id'])
        verify_command_contract(command)
        for stream in ('stdout', 'stderr'):
            if evidence_log(command[stream], evidence, command['id']).name != command['id'] + '.' + stream + '.log':
                raise ValueError('command evidence path changed: ' + command['id'])


def verify_report(report: dict, archive: Path, sdk: Path, evidence: Path) -> None:
    if report.get('status') != 'PASS' or report.get('binary_cross_sdk') != 'NOT_CLAIMED':
        raise ValueError('report is not a successful source-only compatibility proof')
    if not artifact_byte_sha256_equal(report['archive_digest'], artifact_byte_digest(archive).to_json()):
        raise ValueError('archive binding changed')
    actual = sdk_binding(sdk)
    recorded = report['sdk_files']
    if actual.keys() != recorded.keys() or any(not artifact_byte_sha256_equal(recorded[k], actual[k]) for k in actual):
        raise ValueError('SDK compiler/runtime/import binding changed; recompile and rerun consumers')
    if not text_evidence_sha256_equal(report['runner_digest'], text_evidence_digest(Path(__file__)).to_json()):
        raise ValueError('capture runner changed')
    verify_helper_sources(report)
    verify_tls_fixtures(report)
    verify_command_inventory(report['commands'], evidence)
    verify_ca_checks(report, evidence)
    commands = {command['id']: command for command in report['commands']}
    for name in consumers.APP_NAMES:
        command_id = name + '-acceptance'
        consumers.validate_checks(evidence_log(commands[command_id]['stdout'], evidence, command_id).read_text(), name)
    verify_consumer_sources(report)


def verify_retained_commands(commands: list[dict], evidence: Path) -> None:
    """Reject retained results whose recorded invocation or logs no longer stand."""
    for command in commands:
        if command.get('timed_out') or command['exit_code'] != command['expected_exit_code']:
            raise ValueError('retained command is not a success: ' + command['id'])
        for stream in ('stdout', 'stderr'):
            evidence_payload(command[stream], evidence, command['id'], 'retained command log changed')
        verify_command_contract(command)


def verify_retained_binary(recorded: dict, binary: Path) -> None:
    """A retained consumer result only stands while its installed executable is unchanged."""
    if not binary.is_file():
        raise ValueError('retained consumer binary is missing; rerun the capture')
    if not artifact_byte_sha256_equal(recorded.get('binary_digest'), artifact_byte_digest(binary).to_json()):
        raise ValueError('retained consumer binary changed; rerun the capture')


def validate_resume(previous: dict, report: dict) -> None:
    """Reject retained results whose captured inputs do not match this resume attempt."""
    if not text_evidence_sha256_equal(previous.get('runner_digest'), report['runner_digest']):
        raise ValueError('cannot resume a changed capture runner')
    retained_helpers = previous.get('helper_sources')
    current_helpers = report['helper_sources']
    if not isinstance(retained_helpers, dict) or retained_helpers.keys() != current_helpers.keys() or any(
            not text_evidence_sha256_equal(retained_helpers[name], current_helpers[name])
            for name in current_helpers):
        raise ValueError('cannot resume a changed evidence helper closure')
    retained_fixtures = previous.get('tls_fixtures')
    current_fixtures = report['tls_fixtures']
    if not isinstance(retained_fixtures, dict) or retained_fixtures.keys() != current_fixtures.keys() or any(
            not artifact_byte_sha256_equal(retained_fixtures[name], current_fixtures[name])
            for name in current_fixtures):
        raise ValueError('cannot resume changed retained TLS fixture material')
    previous_cc = previous.get('native_cc_digest')
    if not isinstance(previous_cc, dict) or not artifact_byte_sha256_equal(previous_cc, report['native_cc_digest']):
        raise ValueError('cannot resume a changed or unbound native compiler')
    if previous.get('build_options') != report.get('build_options'):
        raise ValueError('cannot resume changed native build options')
    previous_sources = previous.get('consumer_sources', {})
    current_sources = report['consumer_sources']
    if previous_sources.keys() != current_sources.keys() or any(
            not text_evidence_sha256_equal(previous_sources[key], current_sources[key])
            for key in current_sources):
        raise ValueError('cannot resume changed consumer sources')


class Capture:
    def __init__(self, work: Path, output: Path, sdk: Path):
        self.work, self.output, self.sdk = work, output, sdk
        self.env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE='1')
        self.env['PATH'] = os.pathsep.join((str(sdk / 'bin'), str(sdk / 'tools/bin'), os.environ['PATH']))
        self.env['CANGJIE_HOME'] = self.env['CANGJIE_SDK_ROOT'] = str(sdk)
        self.env['LD_LIBRARY_PATH'] = ':'.join((str(sdk / 'runtime/lib/linux_x86_64_cjnative'), str(sdk / 'tools/lib')))
        self.env['CJ_SDK_LIBPATH'] = self.env['LD_LIBRARY_PATH']
        self.commands = []

    def normalize(self, text: str) -> str:
        for actual, replacement in sorted(((str(self.work), '<scratch>'), (str(ROOT), '<repo>'),
            (str(self.sdk), '<sdk>'), (str(Path.home()), '$HOME')), key=lambda p: -len(p[0])):
            text = text.replace(actual, replacement)
        text = text.replace(platform.node(), 'example-host').replace('127.0.0.1', '192.0.2.1')
        return text

    def hidden(self, argv: list[str], cwd: Path, ca: Path | None = None, old: Path | None = None) -> list[str]:
        command = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', str(self.work), str(self.work), '--tmpfs', str(ROOT)]
        if old is not None:
            command += ['--tmpfs', str(old)]
        if ca is not None:
            command += ['--tmpfs', '/etc/ssl', '--dir', '/etc/ssl/certs']
            if Path('/etc/pki').exists():
                command += list(HOST_CA_MOUNT)
            if ca.is_file():
                command += ['--ro-bind', str(ca), '/etc/ssl/certs/ca-certificates.crt']
        return command + ['--chdir', str(cwd), '--', *argv]

    def record(self, name: str, argv: list[str], cwd: Path, code: int | None, expected: int, out: bytes, err: bytes, timed_out: bool = False):
        entry = {'id': name, 'argv': [self.normalize(value) for value in argv], 'cwd': self.normalize(str(cwd)),
            'exit_code': code, 'expected_exit_code': expected, 'timed_out': timed_out}
        for stream, raw in (('stdout', out), ('stderr', err)):
            path = self.output / f'{name}.{stream}.log'
            path.write_text(self.normalize(raw.decode(errors='replace')))
            entry[stream] = {'path': path.name, 'digest': text_evidence_digest(path).to_json()}
        self.commands.append(entry)

    def run(self, name: str, argv: list[str], cwd: Path, *, expected: int = 0, timeout: int = 60,
            ca: Path | None = None, old: Path | None = None, hidden: bool = True) -> str:
        command = self.hidden(argv, cwd, ca, old) if hidden else argv
        try:
            done = subprocess.run(command, cwd=cwd, env=self.env, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            self.record(name, command, cwd, None, expected, error.stdout or b'', error.stderr or b'', True)
            raise RuntimeError(f'{name} timed out') from error
        self.record(name, command, cwd, done.returncode, expected, done.stdout, done.stderr)
        if done.returncode != expected:
            raise RuntimeError(f'{name} failed with exit {done.returncode}')
        return self.normalize(done.stdout.decode(errors='replace'))

    @contextmanager
    def endpoint(self, name: str, argv: list[str], cwd: Path, ready: str, stopped: str, old: Path):
        command = self.hidden(argv, cwd, old=old)
        process = subprocess.Popen(command, cwd=cwd, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        captured = bytearray()
        try:
            expires = time.monotonic() + 10
            port = None
            while port is None:
                if time.monotonic() >= expires or process.poll() is not None:
                    raise RuntimeError('endpoint readiness failed')
                if select.select([process.stdout], [], [], .1)[0]:
                    captured.extend(os.read(process.stdout.fileno(), 8192))
                    if len(captured) > 16384:
                        raise ValueError('endpoint readiness exceeded bound')
                    match = re.search(rb'^' + ready.encode() + rb' port=(\d+)\r?$', captured, re.MULTILINE)
                    if match:
                        port = int(match[1])
            yield port
            process.stdin.write(b'stop\n'); process.stdin.flush()
            out, err = process.communicate(timeout=15)
            captured.extend(out)
            if process.returncode != 0 or captured.decode().splitlines().count(stopped) != 1:
                raise RuntimeError('endpoint shutdown failed')
        finally:
            if process.poll() is None:
                process.kill()
                out, err = process.communicate(timeout=5)
                captured.extend(out)
            elif 'err' not in locals():
                out, err = process.communicate(timeout=5)
                captured.extend(out)
            self.record(name, command, cwd, process.returncode, 0, bytes(captured), err)


def capture(args) -> dict:
    sdk = args.sdk_root.resolve()
    if (sdk / 'cangjie').is_dir():
        sdk = sdk / 'cangjie'
    parent = args.scratch.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if subprocess.check_output(['findmnt', '-n', '-o', 'FSTYPE', '-T', str(parent)], text=True).strip() == 'tmpfs' or shutil.disk_usage(parent).free < 2 * 1024**3:
        raise ValueError('need disk-backed scratch with 2 GiB free')
    work = parent / args.profile
    work.mkdir(mode=0o700, exist_ok=args.resume)
    output = args.output.resolve() / args.profile
    output.mkdir(parents=True, exist_ok=args.resume)
    run = Capture(work, output, sdk)
    report = {'schema_version': 1, 'task_id': 'M12-002', 'profile': args.profile, 'status': 'FAIL',
        'release_qualification': 'NOT_QUALIFIED', 'binary_cross_sdk': 'NOT_CLAIMED',
        'consumer_recompile_required': True, 'runner_digest': text_evidence_digest(Path(__file__)).to_json(),
        'archive_digest': artifact_byte_digest(args.archive).to_json(), 'commands': run.commands,
        'platform': release.platform_identity(), 'kernel': platform.release(), 'consumers': {},
        'consumer_sources': consumer_source_digests()}
    previous = None
    try:
        report['sdk_files'] = sdk_binding(sdk)
        report['native_cc_digest'] = native_compiler_digest()
        report['helper_sources'] = helper_sources()
        report['build_options'] = {'command': ['cjpm', 'build'], 'consumer_compile_option': '', 'consumer_link_option': '', 'cpu_override': 'none',
            'environment': {key: run.normalize(run.env.get(key, '')) for key in ('CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CJC_FLAGS')}}
        historical = json.loads(args.qualification.read_text())
        if historical.get('status') != 'PASS' or not artifact_byte_sha256_equal(historical['toolchain']['compiler_binary_digest'], artifact_byte_digest(sdk / 'bin/cjc').to_json()):
            raise ValueError('available SDK does not match its accepted installed-consumer compiler binding')
        report['prior_installed_qualification'] = {'path': str(args.qualification.relative_to(ROOT)), 'digest': text_evidence_digest(args.qualification).to_json(),
            'scope': 'compiler matched; runtime and imports newly fingerprinted and exercised here'}
        if args.resume:
            previous = json.loads((output / "report.json").read_text())
            if not artifact_byte_sha256_equal(previous["archive_digest"], report["archive_digest"]):
                raise ValueError("cannot resume a changed archive")
            missing = [name for name in TLS_FIXTURE_FILES if not (work / name).is_file()]
            if missing:
                raise ValueError('retained TLS fixture material is missing; rerun the capture: ' + ', '.join(missing))
            report['tls_fixtures'] = {name: artifact_byte_digest(work / name).to_json() for name in TLS_FIXTURE_FILES}
            validate_resume(previous, report)
            if not previous.get('relocation', {}).get('whole_tree_moved'):
                raise ValueError('cannot resume a capture that did not complete relocation')
            # A retained success only stands while its own evidence and installed binaries
            # are still exactly what they claimed; otherwise the capture must not reuse it.
            verify_retained_commands(previous['commands'], output)
            for key in ("toolchain", "production_sources", "native_archives", "payload_sha256", "installed_manifest", "relocation", "consumers", "proxy_observations"):
                if key in previous:
                    report[key] = previous[key]
            for name, record in report['consumers'].items():
                verify_retained_binary(record, work / 'relocated/consumers' / name / 'target/release/bin/main')
            retained = [c for c in previous["commands"] if c["id"] != "service-operational" and c["exit_code"] == c["expected_exit_code"]]
            run.commands.extend(retained)
            report["resumed_from"] = text_evidence_digest(output / "report.json").to_json()
            backup = output / ("prior-report-" + str(time.time_ns()) + ".json")
            shutil.copyfile(output / "report.json", backup)
        if previous is None:
            report['toolchain'] = {name: run.run(name, [name, '--version'], work).strip() for name in ('cjc', 'cjpm')}
            report['toolchain']['native_cc'] = run.run('native-cc', ['cc', '--version'], work).splitlines()[0]
            report['toolchain']['openssl_fixture_only'] = run.run('fixture-openssl', ['openssl', 'version'], work).strip()
        payload, manifest = release.read_verified_payload(args.archive)
        old, relocated = work / 'original', work / 'relocated'
        if previous is None:
            installed = release.extract_archive(args.archive, old / 'install')
            installed.rename(old / 'install/wirestack')
            installed = old / 'install/wirestack'
            consumers.validate_installed(installed, manifest)
            report['production_sources'] = {str(p.relative_to(installed)): artifact_byte_digest(p).to_json() for p in release.production_sources(installed)}
            for relative, digest in report['production_sources'].items():
                if not artifact_byte_sha256_equal(digest, artifact_byte_digest(ROOT / relative).to_json()):
                    raise ValueError('accepted archive source differs from current production source')
            report['native_archives'] = {name: artifact_byte_digest(installed / name).to_json() for name in consumers.NATIVE_ARCHIVES}
            report['payload_sha256'], report['installed_manifest'] = manifest['payload_sha256'], manifest
            run.run('checkout-hidden', ['python3', '-c', f"from pathlib import Path; assert not any(Path({str(ROOT)!r}).iterdir()); print('CHECKOUT_HIDDEN_PASS')"], work)
            for name in (*consumers.APP_NAMES, 'trust'):
                source = consumers.APPS / name if name != 'trust' else ROOT / 'examples/linux/m12_002/sdk'
                destination = old / 'consumers' / name
                shutil.copytree(source, destination, ignore=shutil.ignore_patterns('target', 'cjpm.lock'))
                run.run(f'{name}-build', ['cjpm', 'build'], destination, timeout=600)
            old.rename(relocated)
            old.mkdir()
        else:
            current = sdk_binding(sdk)
            if current != previous['sdk_files']:
                raise ValueError('cannot resume changed SDK bits')
            destination = relocated / 'consumers/trust'
            if not text_evidence_sha256_equal(text_evidence_digest(destination / 'src/main.cj').to_json(), text_evidence_digest(ROOT / 'examples/linux/m12_002/sdk/src/main.cj').to_json()):
                run.commands[:] = [c for c in run.commands if c['id'] != 'trust-build']
                shutil.copyfile(ROOT / 'examples/linux/m12_002/sdk/src/main.cj', destination / 'src/main.cj')
                run.run('trust-build', ['cjpm', 'build'], destination, timeout=600, old=old)
        installed = relocated / 'install/wirestack'
        consumers.validate_installed(installed, manifest)
        report['relocation'] = {'status': 'PASS', 'old_tree_hidden': True, 'whole_tree_moved': True, 'relative_dependency': '../../install/wirestack', 'build_checkout_hidden': True}
        for label, subject in ([] if previous else [('certificate', 'example.test'), ('untrusted', 'other.test')]):
            command = ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', f'/CN={subject}', '-keyout', str(work / f'{label}.key'), '-out', str(work / f'{label}.pem')]
            if label == 'certificate':
                command += ['-addext', 'subjectAltName=DNS:example.test,IP:127.0.0.1']
            run.run(label, command, work, hidden=False)
            run.run(label + '-der', ['openssl', 'x509', '-in', str(work / f'{label}.pem'), '-outform', 'DER', '-out', str(work / f'{label}.der')], work, hidden=False)
        if previous is None:
            run.run('key-der', ['openssl', 'pkcs8', '-topk8', '-nocrypt', '-in', str(work / 'certificate.key'), '-outform', 'DER', '-out', str(work / 'key.der')], work, hidden=False)
            report['tls_fixtures'] = {name: artifact_byte_digest(work / name).to_json() for name in TLS_FIXTURE_FILES}
        certs = [str(work / p) for p in ('certificate.der', 'key.der', 'untrusted.der')]
        for name in consumers.APP_NAMES:
            if name in report['consumers']:
                continue
            cwd = relocated / 'consumers' / name
            binary = cwd / 'target/release/bin/main'
            run.run(name + '-help', [str(binary), '--help'], cwd, old=old)
            needed = sorted(re.findall(r'\(NEEDED\).*?\[(.*?)\]', run.run(name + '-dependencies', ['readelf', '-d', str(binary)], cwd, old=old)))
            consumers.validate_needed(needed)
            if name == 'cli':
                with consumers.SingleConnectProxy() as proxy:
                    text = run.run(name + '-acceptance', [str(binary), 'self-check', *certs, str(proxy.port)], cwd, timeout=180, old=old)
                    report['proxy_observations'] = proxy.validate()
            else:
                text = run.run(name + '-acceptance', [str(binary), 'self-check', *certs], cwd, timeout=180, old=old)
            report['consumers'][name] = {'binary_digest': artifact_byte_digest(binary).to_json(), 'pass_checks': consumers.validate_checks(text, name), 'needed': needed}
        if 'cli' in report['consumers'] and 'proxy_observations' not in report:
            raise ValueError('resumed capture lacks the CLI proxy observations; rerun the capture')
        service = relocated / 'consumers/service'
        trust = relocated / 'consumers/trust'
        report['ca_checks'] = {}
        with run.endpoint('service-operational', [str(service / 'target/release/bin/main'), 'serve', '--port', '0', '--certificate', certs[0], '--key', certs[1], '--budget-ms', '60000'], service, 'SERVICE_READY', 'SERVICE_STOPPED', old) as port:
            url = f'https://127.0.0.1:{port}/download'
            for name in ('cli', 'decoded'):
                cwd = relocated / 'consumers' / name
                if previous and any(c['id'] == name + '-download' for c in run.commands):
                    retained = work / (name + '-download.bin')
                    if retained.read_bytes() != b'download':
                        raise ValueError('retained installed output changed')
                    continue
                target = work / (name + ('-resumed-download.bin' if previous else '-download.bin'))
                run.run(name + '-download', [str(cwd / 'target/release/bin/main'), 'download', '--url', url, '--output', str(target), '--trust', certs[0]], cwd, old=old)
                if target.read_bytes() != b'download':
                    raise ValueError('installed download bytes differ')
            for name, mode, ca, explicit in [
                ('explicit-ca', 'explicit', None, certs[0]),
                ('missing-explicit-ca', 'explicit', None, str(work / 'missing.der')),
                ('incorrect-explicit-ca', 'explicit', None, certs[2]),
                ('system-ca-installed', 'system', work / 'certificate.pem', None),
                ('system-ca-missing', 'system', work / 'missing.pem', None),
                ('system-ca-incorrect', 'system', work / 'untrusted.pem', None)]:
                expected, diagnostic = EXPECTED_COMMANDS[name], CA_DIAGNOSTICS[name]
                if previous and previous.get('ca_checks', {}).get(name, {}).get('status') == 'PASS':
                    # A retained CA scenario only stands if its own recorded output still prints
                    # the diagnostic that made it a pass in the first place.
                    retained = next(c for c in run.commands if c['id'] == name)
                    if evidence_payload(retained['stdout'], output, name, 'retained CA scenario changed').read_text().strip() != diagnostic:
                        raise ValueError('retained CA scenario no longer reproduces its diagnostic: ' + name)
                    report['ca_checks'][name] = {'status': 'PASS', 'expected_exit': expected, 'diagnostic': diagnostic}
                    continue
                command = [str(trust / 'target/release/bin/main'), mode, url] + ([explicit] if explicit else [])
                text = run.run(name, command, trust, expected=expected, ca=ca, old=old)
                if text.strip() != diagnostic:
                    raise ValueError(name + ' stable diagnostic differs: ' + text.strip())
                report['ca_checks'][name] = {'status': 'PASS', 'expected_exit': expected, 'diagnostic': diagnostic}
        stream = relocated / 'consumers/streams'
        binary = stream / 'target/release/bin/main'
        with run.endpoint('streams-operational', [str(binary), 'fixture', *certs[:2]], stream, 'STREAM_READY', 'STREAM_STOPPED', old) as port:
            run.run('sse-operational', [str(binary), 'sse', f'https://127.0.0.1:{port}/stream', '--trust', certs[0], '--max-events', '1', '--recover', '0'], stream, old=old)
            run.run('wss-operational', [str(binary), 'websocket', f'wss://127.0.0.1:{port}/socket', '--trust', certs[0], '--max-frames', '1', '--recover', '0', '--command', 'echo'], stream, old=old)
        report['status'] = 'PASS'
        report['semantic_outcome'] = 'same complete M11-004 checks and public operational outputs; no observed semantic difference'
        report['ca_installation'] = {'path': '/etc/ssl/certs/ca-certificates.crt', 'format': 'PEM', 'mechanism': 'read-only bind in private mount namespace; host CA unchanged'}
        report['pass_check_count'] = sum(len(c['pass_checks']) for c in report['consumers'].values())
        report['relocated_binaries'] = {name: str((relocated / 'consumers' / name / 'target/release/bin/main').relative_to(work)) for name in (*consumers.APP_NAMES, 'trust')}
    except Exception as error:
        report['error'] = run.normalize(str(error))
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-root', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--qualification', type=Path)
    parser.add_argument('--profile', default='stable')
    parser.add_argument('--scratch', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/evidence/M12-002/source-sdk')
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--resume', action='store_true', help='Resume a retained post-relocation failure without rebuilding unchanged consumers.')
    args = parser.parse_args()
    args.archive = args.archive.resolve()
    if args.qualification:
        args.qualification = args.qualification.resolve()
    if args.verify:
        sdk = args.sdk_root.resolve()
        if (sdk / 'cangjie').is_dir(): sdk /= 'cangjie'
        verify_report(json.loads(args.verify.read_text()), args.archive, sdk, args.verify.parent)
        print('M12_002_SOURCE_SDK_VERIFY_PASS')
        return 0
    if not args.scratch or not args.qualification or re.fullmatch(r'[a-z0-9-]+', args.profile) is None:
        parser.error('capture requires --scratch, --qualification and a simple profile name')
    report = capture(args)
    print(json.dumps({'profile': args.profile, 'status': report['status'], 'error': report.get('error')}))
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
