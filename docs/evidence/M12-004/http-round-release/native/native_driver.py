#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import traceback

BASE = Path(__file__).resolve().parent
ORIGINAL = Path.home() / '.cache/agent-tmp/wirestack-m12-004-server.JFVwz8'
WORK = BASE / 'native'
sys.path.insert(0, str(ORIGINAL / 'input/repo'))
from tools import m7_021_linux_release as release
from tools.benchmarks import m12_001_end_to_end as bench
EXPECTED = {'baseline': 'e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f', 'candidate': 'bb12abafb87ffe60b3e3adbdf4c1ac6ea7f8da47a7a5ad8a2df58b9e8981556d'}
SOURCES = {'http.cj': '1c6a4942dfc97ff6b7b5a765ff19501b6239e73fe4e310c91da107feb6441ba7', 'common.cj': '877b4f985d16c990c43ebfca9627d85aa94460ccfcc043c228448e0703153129'}
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def redact(value):
    if isinstance(value, str):
        return value.replace(str(BASE), '<repair>').replace(str(ORIGINAL), '<original>').replace(str(Path.home()), '$HOME')
    if isinstance(value, dict): return {k: redact(v) for k, v in value.items()}
    if isinstance(value, list): return [redact(v) for v in value]
    return value
WORK.mkdir(mode=0o700)
report = {'scope': 'CORRECTNESS_SMOKE_NOT_PERFORMANCE_ACCEPTANCE', 'status': 'FAIL', 'cases': list(bench.CASES['http']), 'source_inputs': SOURCES, 'archives': {}, 'builds': {}, 'commands': [], 'results': {}, 'cleanup': {}}
def save():
    (WORK / 'report.json').write_text(json.dumps(redact(report), indent=2) + '\n')
def group_members(pgid):
    members = []
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            text = path.read_text(); fields = text[text.rfind(')')+2:].split()
            if int(fields[2]) == pgid: members.append(int(path.parent.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError): pass
    return members

def command(label, argv, cwd, timeout=95, inputs=None):
    argv = [str(x) for x in argv]
    out, err = WORK / (label + '.stdout'), WORK / (label + '.stderr')
    record = {'label': label, 'argv': argv, 'cwd': str(cwd), 'exit_code': None, 'controller_timeout': False, 'controller_timeout_seconds': timeout, 'input_digests': inputs or {}}
    start = time.monotonic()
    with out.open('wb') as stdout, err.open('wb') as stderr:
        try:
            child = subprocess.Popen(argv, cwd=cwd, stdout=stdout, stderr=stderr, start_new_session=True)
            record['pid'] = child.pid
            try: record['exit_code'] = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record['controller_timeout'] = True
                os.killpg(child.pid, signal.SIGKILL)
                record['exit_code'] = child.wait()
            residual = group_members(child.pid)
            record['owned_process_cleanup'] = {'remaining_before_cleanup': residual}
            if residual:
                os.killpg(child.pid, signal.SIGKILL)
                time.sleep(0.05)
            record['owned_process_cleanup']['remaining_after_cleanup'] = group_members(child.pid)
        except OSError as error:
            stderr.write(str(error).encode())
            record['execution_error'] = str(error)
    record['elapsed_seconds'] = time.monotonic() - start
    for name, path in [('stdout', out), ('stderr', err)]:
        record[name] = {'path': path.name, 'sha256': digest(path), 'size_bytes': path.stat().st_size}
    report['commands'].append(record)
    save()
    print(json.dumps(redact(record)), flush=True)
    return record

def source_state(consumer):
    return {name: digest(consumer / 'src' / ('main.cj' if name == 'http.cj' else name)) for name in SOURCES}
try:
    assert sorted(os.sched_getaffinity(0)) == list(range(8))
    assert os.environ['CANGJIE_HOME'] == str(Path.home() / 'cangjie_sdk/sts1.1.3')
    for name, expected in SOURCES.items(): assert digest(BASE / 'input' / name) == expected, name
    report['namespace_receipts'] = [str(x.relative_to(BASE)) for x in sorted((BASE / 'receipts').glob('*-namespace.json'))]
    report['driver_sha256'] = digest(Path(__file__))
    for label, expected in EXPECTED.items():
        archive = ORIGINAL / 'input' / (label + '.tar.gz')
        if not archive.is_file():
            archive = next(p for p in (ORIGINAL / 'input').glob('*.tar.gz') if digest(p) == expected)
        assert digest(archive) == expected
        installed = release.extract_archive(archive, WORK / ('installed-' + label))
        report['archives'][label] = {'path': str(archive), 'sha256': digest(archive), 'installed': str(installed)}
        consumer = WORK / (label + '-http')
        (consumer / 'src').mkdir(parents=True)
        manifest = release.consumer_manifest(installed).replace('wirestack_release_smoke', 'wirestack_m12_001').replace('compile-option = ""', 'compile-option = "-O2"', 1)
        (consumer / 'cjpm.toml').write_text(manifest)
        for name in SOURCES: shutil.copyfile(BASE / 'input' / name, consumer / 'src' / ('main.cj' if name == 'http.cj' else name))
        before = source_state(consumer)
        cmd = command(label + '-build', ['cjpm', 'build'], consumer, 600, {'archive_sha256': expected, 'sources': before, 'manifest_sha256': digest(consumer / 'cjpm.toml')})
        binary = consumer / 'target/release/bin/main'
        after = source_state(consumer)
        report['builds'][label] = {'build_exit': cmd['exit_code'], 'binary_sha256': digest(binary) if binary.is_file() else None, 'binary': str(binary), 'consumer_manifest': manifest, 'consumer_manifest_sha256': digest(consumer / 'cjpm.toml'), 'sources_before_after': {'before': before, 'after': after, 'input_after': {n: digest(BASE / 'input' / n) for n in SOURCES}}, 'command': cmd}
        report['results'][label] = {}
        save()
        if binary.is_file() and cmd['exit_code'] == 0:
            nm = subprocess.run(['nm', '--defined-only', str(binary)], capture_output=True, text=True)
            symbols = [line.split()[-1] for line in nm.stdout.splitlines() if len(line.split()) >= 3 and (line.split()[-1] == 'main' or ('main' in line.split()[-1] and line.split()[-1].endswith('mainHv')))]
            report['builds'][label]['main_symbols'] = symbols
            for index, symbol in enumerate(symbols):
                command(label + '-main-disassembly-' + str(index), ['objdump', '-d', '--disassemble=' + symbol, str(binary)], consumer)
    fixtures = [
        ('certificate', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=example.test', '-addext', 'subjectAltName=DNS:example.test,IP:127.0.0.1', '-keyout', WORK/'key.pem', '-out', WORK/'certificate.pem']),
        ('certificate-der', ['openssl', 'x509', '-in', WORK/'certificate.pem', '-outform', 'DER', '-out', WORK/'certificate.der']),
        ('key-der', ['openssl', 'pkcs8', '-topk8', '-nocrypt', '-in', WORK/'key.pem', '-outform', 'DER', '-out', WORK/'key.pk8'])]
    report['fixture_commands'] = [command(label, argv, WORK) for label, argv in fixtures]
    fixtures_ok = all(c['exit_code'] == 0 for c in report['fixture_commands'])
    if fixtures_ok:
        fixture_digests = {n: digest(WORK/n) for n in ('certificate.der', 'key.pk8')}
        report['fixture_digests'] = fixture_digests
        for label, build in report['builds'].items():
            if build['build_exit'] != 0 or build['binary_sha256'] is None: continue
            for case in bench.CASES['http']:
                binary = Path(build['binary'])
                cmd = command(label + '-' + case, bench.workload_arguments(binary, case, WORK), binary.parents[3], 95, {'binary_sha256': digest(binary), 'archive_sha256': EXPECTED[label], 'sources': SOURCES, 'fixtures': fixture_digests})
                result = {'sample': None, 'command': cmd, 'validation_valid': False, 'native_scenario': 'http_observed' if case == 'http_unobserved' else case}
                try:
                    lines = (WORK / cmd['stdout']['path']).read_text().splitlines()
                    rows = [json.loads(line) for line in lines if line.strip().startswith('{')]
                    assert len(rows) == 1, 'expected exactly one native JSON row'
                    result['sample'] = rows[0]
                    bench.validate_sample(rows[0], result['native_scenario'])
                    result['validation_valid'] = True
                except Exception as error: result['validation_error'] = str(error)
                report['results'][label][case] = result
                save()
    report['source_inputs_after'] = {n: digest(BASE/'input'/n) for n in SOURCES}
    report['archives_after'] = {label: digest(Path(item['path'])) for label, item in report['archives'].items()}
    passed = len(report['builds']) == 2 and all(b['build_exit'] == 0 and b['sources_before_after']['before'] == SOURCES and b['sources_before_after']['after'] == SOURCES and b['sources_before_after']['input_after'] == SOURCES for b in report['builds'].values())
    passed = passed and all(len(report['results'].get(label, {})) == 14 and all(r['command']['exit_code'] == 0 and not r['command']['controller_timeout'] and r['validation_valid'] for r in report['results'][label].values()) for label in EXPECTED)
    report['status'] = 'PASS' if passed and report['source_inputs_after'] == SOURCES and report['archives_after'] == EXPECTED else 'FAIL'
except Exception:
    report['driver_error'] = traceback.format_exc()
finally:
    removed = []
    for name in ('key.pem', 'key.pk8'):
        path = WORK/name
        if path.exists(): path.unlink(); removed.append(name)
    report['cleanup']['keys_removed'] = removed
    report['cleanup']['keys_absent'] = all(not (WORK/n).exists() for n in ('key.pem', 'key.pk8'))
    report['cleanup']['owned_processes_remaining'] = [c['label'] for c in report['commands'] if c.get('owned_process_cleanup', {}).get('remaining_after_cleanup')]
    save()
    print(json.dumps(redact({'status': report['status'], 'cleanup': report['cleanup'], 'driver_error': report.get('driver_error')})), flush=True)
