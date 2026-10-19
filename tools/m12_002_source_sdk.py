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


def sdk_binding(sdk: Path) -> dict:
    """Bind the compiler, CJPM, runtime, standard archives and import metadata."""
    files = {str(path.relative_to(sdk)): artifact_byte_digest(path).to_json()
        for folder in ('bin', 'tools/bin', 'runtime', 'lib', 'modules')
        for path in sorted((sdk / folder).rglob('*'))
        if path.is_file() and (folder in ('runtime', 'modules') or path.name in ('cjc', 'cjpm') or path.suffix in ('.a', '.so'))}
    for name, folder in (('cjc', 'bin'), ('cjpm', 'tools/bin')):
        if not (sdk / folder / name).is_file():
            raise ValueError('SDK is missing compiler or CJPM')
    if not any('libcangjie-runtime.so' in path for path in files):
        raise ValueError('SDK runtime binding is missing')
    return files


def expected_consumer_sources() -> set[str]:
    """Complete M11-004 application and M12-002 fixture source inventory."""
    expected = {path.relative_to(ROOT).as_posix() for name in consumers.APP_NAMES
                for path in consumers.app_files(consumers.APPS / name)}
    expected |= {path.relative_to(ROOT).as_posix() for path in
                 (ROOT / 'examples/linux/m12_002/sdk/cjpm.toml', ROOT / 'examples/linux/m12_002/sdk/src/main.cj')}
    return expected


def verify_consumer_sources(report: dict) -> None:
    """Reject omitted or changed consumer/fixture sources against the complete inventory."""
    recorded = report.get('consumer_sources')
    expected = expected_consumer_sources()
    if not isinstance(recorded, dict) or set(recorded) != expected:
        raise ValueError('consumer source inventory changed')
    for relative in sorted(expected):
        if not text_evidence_sha256_equal(recorded[relative], text_evidence_digest(ROOT / relative).to_json()):
            raise ValueError('consumer source changed: ' + relative)


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
    for command in report['commands']:
        if command['exit_code'] != command['expected_exit_code'] or command['timed_out']:
            raise ValueError('command did not satisfy its native outcome')
        for stream in ('stdout', 'stderr'):
            entry = command[stream]
            if not text_evidence_sha256_equal(entry['digest'], text_evidence_digest(evidence / entry['path']).to_json()):
                raise ValueError('command evidence changed')
    for name in consumers.APP_NAMES:
        consumers.validate_checks((evidence / f'{name}-acceptance.stdout.log').read_text(), name)
    verify_consumer_sources(report)


def validate_resume(previous: dict, report: dict) -> None:
    """Reject retained results whose captured inputs do not match this resume attempt."""
    if not text_evidence_sha256_equal(previous.get('runner_digest'), report['runner_digest']):
        raise ValueError('cannot resume a changed capture runner')
    if not artifact_byte_sha256_equal(previous.get('native_cc_digest'), report['native_cc_digest']):
        raise ValueError('cannot resume a changed native compiler')
    if previous.get('build_options') != report['build_options']:
        raise ValueError('cannot resume changed build options')
    previous_sources = previous.get('consumer_sources', {})
    current_sources = report['consumer_sources']
    if previous_sources.keys() != current_sources.keys() or any(
            not text_evidence_sha256_equal(previous_sources[key], current_sources[key])
            for key in current_sources):
        raise ValueError('cannot resume changed consumer sources')


def consumer_retained(previous: dict | None, commands: list[dict], name: str, binary: Path) -> bool:
    """A retained consumer is reusable only with a successful acceptance command and matching binary bytes."""
    if not isinstance(previous, dict) or name not in previous.get('consumers', {}):
        return False
    if not any(command['id'] == name + '-acceptance' and command['exit_code'] == 0 for command in commands):
        return False
    if not binary.is_file():
        return False
    return artifact_byte_sha256_equal(previous['consumers'][name].get('binary_digest'),
                                      artifact_byte_digest(binary).to_json())


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
                command += ['--tmpfs', '/etc/pki']
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
        'consumer_sources': {relative: text_evidence_digest(ROOT / relative).to_json()
                             for relative in sorted(expected_consumer_sources())}}
    native_cc = shutil.which('cc')
    if native_cc is None:
        raise ValueError('native compiler is unavailable')
    report['native_cc_digest'] = artifact_byte_digest(Path(native_cc)).to_json()
    report['build_options'] = {'command': ['cjpm', 'build'], 'consumer_compile_option': '', 'consumer_link_option': '', 'cpu_override': 'none',
        'environment': {key: run.normalize(run.env.get(key, '')) for key in ('CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CJC_FLAGS')}}
    previous = None
    try:
        report['sdk_files'] = sdk_binding(sdk)
        historical = json.loads(args.qualification.read_text())
        if historical.get('status') != 'PASS' or not artifact_byte_sha256_equal(historical['toolchain']['compiler_binary_digest'], artifact_byte_digest(sdk / 'bin/cjc').to_json()):
            raise ValueError('available SDK does not match its accepted installed-consumer compiler binding')
        report['prior_installed_qualification'] = {'path': str(args.qualification.relative_to(ROOT)), 'digest': text_evidence_digest(args.qualification).to_json(),
            'scope': 'compiler matched; runtime and imports newly fingerprinted and exercised here'}
        if args.resume:
            previous = json.loads((output / "report.json").read_text())
            if not artifact_byte_sha256_equal(previous["archive_digest"], report["archive_digest"]):
                raise ValueError("cannot resume a changed archive")
            validate_resume(previous, report)
            if not previous.get('relocation', {}).get('whole_tree_moved'):
                raise ValueError('cannot resume a capture that did not complete relocation')
            for key in ("toolchain", "production_sources", "native_archives", "payload_sha256", "installed_manifest", "relocation", "consumers", "proxy_observations"):
                if key in previous:
                    report[key] = previous[key]
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
        certs = [str(work / p) for p in ('certificate.der', 'key.der', 'untrusted.der')]
        for name in consumers.APP_NAMES:
            cwd = relocated / 'consumers' / name
            binary = cwd / 'target/release/bin/main'
            if consumer_retained(previous, run.commands, name, binary):
                continue
            run.commands[:] = [command for command in run.commands
                               if command['id'] not in {name + '-help', name + '-dependencies', name + '-acceptance'}]
            report['consumers'].pop(name, None)
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
        missing = sorted(set(consumers.APP_NAMES) - set(report['consumers']))
        if missing:
            raise ValueError('consumer acceptance incomplete: ' + ', '.join(missing))
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
            for name, mode, ca, expected, diagnostic, explicit in [
                ('explicit-ca', 'explicit', None, 0, 'TRUST_DOWNLOAD_PASS bytes=8', certs[0]),
                ('missing-explicit-ca', 'explicit', None, 1, 'ERROR ca_file_missing', str(work / 'missing.der')),
                ('incorrect-explicit-ca', 'explicit', None, 1, 'ERROR certificate_untrusted phase=tls_handshake', certs[2]),
                ('system-ca-installed', 'system', work / 'certificate.pem', 0, 'TRUST_DOWNLOAD_PASS bytes=8', None),
                ('system-ca-missing', 'system', work / 'missing.pem', 1, 'ERROR trust_unavailable', None),
                ('system-ca-incorrect', 'system', work / 'untrusted.pem', 1, 'ERROR certificate_untrusted phase=tls_handshake', None)]:
                if previous and previous.get('ca_checks', {}).get(name, {}).get('status') == 'PASS':
                    report['ca_checks'][name] = previous['ca_checks'][name]
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
