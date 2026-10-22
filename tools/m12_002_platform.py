#!/usr/bin/env python3
"""Exercise installed binaries and rebuilt consumers on an independent native Linux VM."""
from __future__ import annotations
import argparse
from contextlib import nullcontext
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

# Ubuntu 22.04's Python 3.10 uses its separately installed tomli package.
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib
    sys.modules['tomllib'] = tomllib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m11_004_installed_consumers as consumers
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

SUPPORT_FILES = ('tools/m12_002_platform.py', 'tools/m11_004_installed_consumers.py',
    'tools/m11_003_native_websocket.py', 'tools/m7_021_linux_release.py', 'tools/evidence_digest.py')
# The complete native command inventory: every claim below is re-derived from these logs.
COMMAND_IDS = frozenset({'kernel', 'glibc', 'virtualization', 'cpu', 'os-release', 'compiler',
    'cjpm', 'native-cc', 'native-ld',
    *{f'{stage}-{name}' for stage in ('same-binary', 'clean', 'build', 'rebuilt')
      for name in consumers.APP_NAMES}})
# Consumer sources travel to the VM under a different layout than in the repository.
SOURCE_LAYOUTS = (('examples/linux/m11_004/', 'consumers/'),
    ('examples/linux/m12_002/sdk/', 'consumers/trust/'))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def linux_sdk_files(files: dict) -> dict:
    return {name: digest for name, digest in files.items()
        if 'windows_' not in name and not name.endswith(('.dll', '.dll.a'))}


def transferred_path(key: str) -> str:
    """Map a repository source path onto the layout it takes inside the native VM tree."""
    for prefix, layout in SOURCE_LAYOUTS:
        if key.startswith(prefix):
            return layout + key[len(prefix):]
    raise ValueError('source qualification contains an unknown consumer source: ' + key)


def validate_transferred_sources(tree: Path, stable: dict) -> dict:
    """Verify the sources actually present in the VM before any of them is rebuilt."""
    recorded = {}
    for key, expected in stable['consumer_sources'].items():
        path = tree / transferred_path(key)
        require(path.is_file(), 'transferred consumer source is missing: ' + key)
        actual = text_evidence_digest(path).to_json()
        require(actual == expected, 'transferred consumer source changed: ' + key)
        recorded[key] = actual
    return recorded


def evidence_log(command: dict, evidence: Path, stream: str) -> Path:
    """A report may only read the log it retained for itself, named after its own command."""
    entry = command[stream]
    relative = entry.get('path')
    require(isinstance(relative, str) and relative and not Path(relative).is_absolute()
        and '..' not in Path(relative).parts,
        'native command evidence path escapes its evidence tree: ' + command['id'])
    require(Path(relative).name == f'{command["id"]}.{stream}.log',
        'native command evidence is not its own retained log: ' + command['id'])
    path = evidence / relative
    require(path.is_file(), 'native command evidence is missing: ' + command['id'])
    return path


def command_output(report: dict, evidence: Path, name: str) -> str:
    command = next((item for item in report['commands'] if item['id'] == name), None)
    require(command is not None, 'native command is missing: ' + name)
    return evidence_log(command, evidence, 'stdout').read_text()


FIXED_COMMANDS = {'kernel': ['uname', '-r'], 'glibc': ['getconf', 'GNU_LIBC_VERSION'],
    'virtualization': ['systemd-detect-virt'], 'cpu': ['lscpu', '-J'],
    'os-release': ['cat', '/etc/os-release'], 'compiler': ['<sdk>/bin/cjc', '--version'],
    'cjpm': ['<sdk>/tools/bin/cjpm', '--version'], 'native-cc': ['cc', '--version'],
    'native-ld': ['ld', '--version']}
FIXTURES = ('certificate.der', 'key.der', 'untrusted.der')
PORT = '[1-9][0-9]{0,4}'
SELF = '<self>/main'
INSTALLED = '<installed-tree>/consumers/{}/target/release/bin'
REBUILT_DIR = 'rebuilt-installed-tree/consumers/{}'
REBUILT = REBUILT_DIR + '/target/release/bin'


def command_contract(name: str) -> tuple[tuple[str, str], list[str]]:
    """The one invocation shape that can produce each recorded native scenario."""
    if name in FIXED_COMMANDS:
        return ('exact', '<evidence>'), FIXED_COMMANDS[name]
    for stage, template, match in (('same-binary', INSTALLED, 'exact'), ('rebuilt', REBUILT, 'endswith')):
        suffix = name.removeprefix(stage + '-')
        if name.startswith(stage + '-') and suffix in consumers.APP_NAMES:
            argv = [SELF, 'self-check', *(f'<support>/fixtures/{item}' for item in FIXTURES)]
            if suffix == 'cli':
                argv.append(PORT)
            return (match, template.format(suffix)), argv
    for stage in ('clean', 'build'):
        app = name.removeprefix(stage + '-')
        if name.startswith(stage + '-') and app in consumers.APP_NAMES:
            return ('endswith', REBUILT_DIR.format(app)), ['<sdk>/tools/bin/cjpm', stage]
    raise ValueError('native command has no declared contract: ' + name)


def matches(actual, expected, cwd: str) -> bool:
    if expected == SELF:
        return actual == cwd + '/main'
    if expected == PORT:
        return isinstance(actual, str) and re.fullmatch(PORT, actual) is not None
    return actual == expected


def verify_command_contract(command: dict) -> None:
    (match, cwd), argv = command_contract(command['id'])
    actual_cwd = command.get('cwd')
    conformant = isinstance(actual_cwd, str) and (actual_cwd == cwd if match == 'exact'
        else actual_cwd.endswith(cwd))
    require(conformant, 'native command working directory changed: ' + command['id'])
    recorded = command.get('argv')
    require(isinstance(recorded, list) and len(recorded) == len(argv)
        and all(matches(value, shape, actual_cwd) for value, shape in zip(recorded, argv)),
        'native command shape changed: ' + command['id'])


def observed_platform(report: dict, evidence: Path) -> dict:
    """Recompute every claimed platform attribute from the command that actually ran."""
    observed = {'kernel': command_output(report, evidence, 'kernel').strip(),
        'glibc': command_output(report, evidence, 'glibc').strip(),
        'virtualization': command_output(report, evidence, 'virtualization').strip()}
    inventory = json.loads(command_output(report, evidence, 'cpu'))
    rows = inventory.get('lscpu') if isinstance(inventory, dict) else None
    require(isinstance(rows, list) and rows, 'native CPU inventory is not a populated lscpu object')
    fields = {}
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get('field'), str)
            and isinstance(row.get('data'), str), 'native CPU inventory holds a malformed item')
        fields[row['field'].rstrip(':')] = row['data']
    require('Model name' in fields and 'Flags' in fields, 'native CPU inventory lacks a model or flags')
    observed['cpu_model'] = fields['Model name']
    observed['cpu_flags'] = fields['Flags'].split()
    return observed


def verify_commands(report: dict, evidence: Path) -> None:
    ids = [command['id'] for command in report['commands']]
    require(len(ids) == len(set(ids)), 'native command inventory contains duplicates')
    require(set(ids) == COMMAND_IDS,
        'native command inventory is incomplete; missing=' + repr(sorted(COMMAND_IDS - set(ids)))
        + ' extra=' + repr(sorted(set(ids) - COMMAND_IDS)))
    for command in report['commands']:
        require(command['exit_code'] == 0 and not command['timed_out'], 'native command failed: ' + command['id'])
        verify_command_contract(command)
        for stream in ('stdout', 'stderr'):
            item = command[stream]
            path = evidence_log(command, evidence, stream)
            require(text_evidence_digest(path).to_json() == item['digest'],
                'native raw log changed: ' + command['id'])


def verify_report(report: dict, evidence: Path, stable: dict) -> None:
    require(report['status'] == 'PASS', 'native VM acceptance did not pass')
    require(report['archive_digest'] == stable['archive_digest'], 'installed archive binding changed')
    verify_commands(report, evidence)
    observed = observed_platform(report, evidence)
    for field, value in observed.items():
        require(report[field] == value, 'native platform claim differs from its captured output: ' + field)
    require(report['host_kernel'] == stable['kernel'],
        'host identity is not the kernel observed by the source qualification')
    require(report['kernel'] != report['host_kernel'] and report['virtualization'] == 'kvm',
        'container/shared-kernel output is not independent native VM evidence')
    require(report['sdk_files'].keys() == linux_sdk_files(stable['sdk_files']).keys(),
        'native Linux SDK closure is incomplete')
    require('avx' not in report['cpu_flags'] and 'avx2' not in report['cpu_flags'], 'CPU boundary was not exercised')
    require(report['same_binary_check_count'] == report['rebuilt_check_count'] == 47, 'native scenarios missing')
    require(isinstance(report.get('support_sources'), dict) and report['support_sources'].keys() == set(SUPPORT_FILES),
        'platform support source inventory is incomplete')
    require(isinstance(report.get('transferred_sources'), dict)
        and report['transferred_sources'].keys() == stable['consumer_sources'].keys(),
        'transferred consumer source inventory is incomplete')
    for key, expected in stable['consumer_sources'].items():
        require(report['transferred_sources'][key] == expected,
            'transferred consumer source differs from source qualification: ' + key)
    for name in consumers.APP_NAMES:
        require(report['same_binary'][name]['digest'] == stable['consumers'][name]['binary_digest'],
            'same-binary proof accidentally substituted a rebuild')
        for stage in ('same-binary', 'rebuilt'):
            consumers.validate_checks(command_output(report, evidence, f'{stage}-{name}'), name)
    for name, entry in report['support_sources'].items():
        require(text_evidence_digest(ROOT / name).to_json() == entry, 'platform support source changed')
    for name, entry in report['sdk_files'].items():
        require(entry == stable['sdk_files'][name], 'native SDK closure differs from source qualification')


class Capture:
    def __init__(self, sdk: Path, tree: Path, output: Path):
        self.sdk, self.tree, self.output = sdk, tree, output
        self.commands: list[dict] = []
        self.env = dict(os.environ, CANGJIE_HOME=str(sdk), CANGJIE_SDK_ROOT=str(sdk),
            PATH=f'{sdk}/bin:{sdk}/tools/bin:' + os.environ['PATH'],
            LD_LIBRARY_PATH=f'{sdk}/runtime/lib/linux_x86_64_cjnative:{sdk}/tools/lib',
            TMPDIR=str(output), TMP=str(output), TEMP=str(output), DISABLE_ZOXIDE='1')
        self.env['CJ_SDK_LIBPATH'] = self.env['LD_LIBRARY_PATH']

    def normalize(self, value: str) -> str:
        for actual, replacement in sorted(((str(self.sdk), '<sdk>'), (str(self.tree), '<installed-tree>'),
            (str(self.output), '<evidence>'), (str(ROOT), '<support>'),
            (str(Path.home()), '$HOME')), key=lambda pair: -len(pair[0])):
            value = value.replace(actual, replacement)
        return value.replace(platform.node(), 'example-host').replace('127.0.0.1', '192.0.2.1')

    def run(self, name: str, argv: list[str], cwd: Path, timeout: int = 180) -> str:
        timed_out = False
        try:
            result = subprocess.run(argv, cwd=cwd, env=self.env, capture_output=True, timeout=timeout)
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr, timed_out = None, error.stdout or b'', error.stderr or b'', True
        record = {'id': name, 'argv': [self.normalize(value) for value in argv],
            'cwd': self.normalize(str(cwd)), 'exit_code': code, 'timed_out': timed_out}
        for stream, data in (('stdout', stdout), ('stderr', stderr)):
            path = self.output / f'{name}.{stream}.log'
            path.write_text(self.normalize(data.decode(errors='replace')))
            record[stream] = {'path': path.name, 'digest': text_evidence_digest(path).to_json()}
        self.commands.append(record)
        require(code == 0 and not timed_out, f'{name} failed; exact native diagnostics retained')
        return self.normalize(stdout.decode(errors='replace'))

    def acceptance(self, tree: Path, fixtures: Path, stage: str) -> dict:
        result = {}
        for name in consumers.APP_NAMES:
            binary = tree / f'consumers/{name}/target/release/bin/main'
            with consumers.SingleConnectProxy() if name == 'cli' else nullcontext() as proxy:
                argv = [str(binary), 'self-check', *(str(fixtures / item) for item in
                    ('certificate.der', 'key.der', 'untrusted.der'))]
                if proxy is not None:
                    argv.append(str(proxy.port))
                text = self.run(f'{stage}-{name}', argv, binary.parent)
                checks = consumers.validate_checks(text, name)
                if proxy is not None:
                    self.run_proxy_observations = proxy.validate()
            result[name] = {'digest': artifact_byte_digest(binary).to_json(), 'checks': checks}
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-root', type=Path)
    parser.add_argument('--tree', type=Path)
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--stable-report', type=Path, required=True)
    parser.add_argument('--host-kernel')
    parser.add_argument('--image-provenance', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    stable = json.loads(args.stable_report.read_text())
    if args.verify:
        verify_report(json.loads(args.verify.read_text()), args.verify.parent, stable)
        print('M12_002_NATIVE_PLATFORM_EVIDENCE_PASS')
        return 0
    require(all((args.sdk_root, args.tree, args.fixtures, args.host_kernel,
        args.image_provenance, args.output)), 'native capture requires all installed input paths')
    output = args.output.resolve()
    require(args.host_kernel == stable['kernel'],
        'host identity is not the kernel observed by the source qualification')
    output.mkdir(parents=True, exist_ok=False)
    capture = Capture(args.sdk_root.resolve(), args.tree.resolve(), output)
    report = {'schema_version': 1, 'task_id': 'M12-002', 'status': 'RUNNING',
        'archive_digest': stable['archive_digest'], 'host_kernel': args.host_kernel,
        'source_recompile_required_for_sdk_change': True, 'release_qualification': 'NOT_QUALIFIED',
        'commands': capture.commands,
        'support_sources': {name: text_evidence_digest(ROOT / name).to_json() for name in SUPPORT_FILES},
        'image': json.loads(args.image_provenance.read_text())}
    try:
        report['kernel'] = capture.run('kernel', ['uname', '-r'], output).strip()
        report['glibc'] = capture.run('glibc', ['getconf', 'GNU_LIBC_VERSION'], output).strip()
        report['virtualization'] = capture.run('virtualization', ['systemd-detect-virt'], output).strip()
        cpu = json.loads(capture.run('cpu', ['lscpu', '-J'], output))
        fields = {row['field'].rstrip(':'): row['data'] for row in cpu['lscpu']}
        report['cpu_model'], report['cpu_flags'] = fields['Model name'], fields['Flags'].split()
        require(report['virtualization'] == 'kvm' and report['kernel'] != args.host_kernel,
            'independent native KVM guest required')
        require('Westmere' in report['cpu_model'] and 'avx' not in report['cpu_flags'], 'Westmere CPU boundary required')
        report['os_release'] = capture.run('os-release', ['cat', '/etc/os-release'], output)
        for name, binary in (('compiler', capture.sdk / 'bin/cjc'), ('cjpm', capture.sdk / 'tools/bin/cjpm')):
            report[name] = capture.run(name, [str(binary), '--version'], output)
        report['native_cc'] = capture.run('native-cc', ['cc', '--version'], output)
        report['native_ld'] = capture.run('native-ld', ['ld', '--version'], output)
        report['sdk_files'] = {}
        for relative, expected in linux_sdk_files(stable['sdk_files']).items():
            path = capture.sdk / relative
            actual = artifact_byte_digest(path).to_json()
            require(actual == expected, 'transferred Linux SDK input changed: ' + relative)
            report['sdk_files'][relative] = actual
        consumers.validate_installed(capture.tree / 'install/wirestack', stable['installed_manifest'])
        report['transferred_sources'] = validate_transferred_sources(capture.tree, stable)
        report['installed_payload_verified'] = stable['installed_manifest']['artifactBuildFingerprint']
        report['native_tool_files'] = {name: artifact_byte_digest(Path(shutil.which(name))).to_json()
            for name in ('cc', 'ld')}
        for name in consumers.APP_NAMES:
            path = capture.tree / f'consumers/{name}/target/release/bin/main'
            require(artifact_byte_digest(path).to_json() == stable['consumers'][name]['binary_digest'],
                'transferred original consumer changed')
        report['same_binary'] = capture.acceptance(capture.tree, args.fixtures.resolve(), 'same-binary')
        report['same_binary_check_count'] = sum(len(item['checks']) for item in report['same_binary'].values())
        rebuilt = output.parent / 'rebuilt-installed-tree'
        require(not rebuilt.exists(), 'rebuild destination must not exist')
        shutil.copytree(capture.tree, rebuilt)
        for name in consumers.APP_NAMES:
            app = rebuilt / f'consumers/{name}'
            capture.run(f'clean-{name}', [str(capture.sdk / 'tools/bin/cjpm'), 'clean'], app)
            capture.run(f'build-{name}', [str(capture.sdk / 'tools/bin/cjpm'), 'build'], app, 600)
        report['rebuilt'] = capture.acceptance(rebuilt, args.fixtures.resolve(), 'rebuilt')
        report['rebuilt_check_count'] = sum(len(item['checks']) for item in report['rebuilt'].values())
        report['checkout_hidden'] = 'repository checkout was never transferred into this VM; only installed payload and support tools'
        report['status'] = 'PASS'
    except Exception as error:
        report['status'], report['error'] = 'FAIL', capture.normalize(type(error).__name__ + ': ' + str(error))
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if report['status'] == 'PASS':
        verify_report(report, output, stable)
        print('M12_002_NATIVE_PLATFORM_PASS same_binary=47 rebuilt=47')
        return 0
    print('M12_002_NATIVE_PLATFORM_FAIL: ' + report['error'], file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
