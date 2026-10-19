#!/usr/bin/env python3
"""M12-003 source-bound STS resource profiles; not release qualification."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import time
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools.m12_002_source_sdk import sdk_binding

SOURCE = ROOT / 'examples/linux/m12_003/resources'
SCENARIOS = ('buffers', 'requests', 'pool', 'streams', 'resolver', 'low_fd', 'cpu', 'memory', 'memory_pressure')
CHECKS = {'buffers': 'buffers_waiters_owners', 'cpu': 'low_cpu', 'memory': 'low_memory', **{x: x for x in ('requests', 'pool', 'streams', 'resolver', 'low_fd')}}
FEATURES = {'buffers': ['M10 resource buffer/owner/waiter budgets'], 'requests': ['M10 request admission'],
            'pool': ['M10 connection-pool budget'], 'streams': ['M10 HTTP/2 stream budget'],
            'resolver': ['M8 bounded DNS admission', 'M10 resolver observation'], 'low_fd': ['M9 native socket refusal/recovery'],
            'cpu': ['M10 bounded deadline/cancellation under throttling'], 'memory': ['M10 logical buffer admission under memory cap'],
            'memory_pressure': ['STS runtime/kernel OOM classification']}
COVERAGE = {'buffers': ['buffer_quota'], 'requests': [], 'pool': ['pool_quota'],
             'streams': ['stream_quota'], 'resolver': ['resolver_quota'], 'low_fd': ['low_fd'],
             'cpu': ['low_cpu'], 'memory': ['low_memory'], 'memory_pressure': []}


def classify_memory(result):
    proof = result['applied_fault_proof']
    killed = proof['memory_after'].get('oom_kill', 0)-proof['memory_before'].get('oom_kill', 0)
    if killed > 0:
        return 'kernel_oom'
    if result['exit_code'] == 23 and result.get('stdout', '').splitlines().count('RUNTIME_ERROR code=out_of_memory') == 1:
        return 'runtime_oom'
    if result['exit_code'] == 0:
        return 'supported'
    if result.get('classification') == 'library_refusal' and 'RESULT resource_exhausted' in result.get('stdout', ''):
        return 'library_refusal'
    if result['exit_code'] is not None and result['exit_code'] < 0:
        return 'runtime_or_native_signal'
    return 'runtime_or_native_failure'


def validate_profile(scenario, result):
    """Fail closed on missing limits, missing native behavior or OOM-as-success."""
    proof = result['applied_fault_proof']
    if result['timed_out'] or not all(result['cleanup'].values()):
        raise ValueError('profile timeout or incomplete cleanup')
    if int(proof['memory_max']) != (100663296 if scenario == 'memory_pressure' else 536870912):
        raise ValueError('effective memory cgroup ceiling differs')
    quota, period = map(int, proof['cpu_max'].split())
    ratio = 1 if scenario == 'memory_pressure' else 4
    if quota <= 0 or quota*ratio != period:
        raise ValueError('effective CPU quota differs from the isolated profile')
    outcome = classify_memory(result)
    if scenario == 'memory_pressure':
        limited = proof['memory_after'].get('max', 0) > proof['memory_before'].get('max', 0)
        if outcome not in ('kernel_oom', 'runtime_oom', 'runtime_or_native_failure', 'runtime_or_native_signal') or result['exit_code'] == 0 or 'ALLOC bytes=' not in result['stdout'] or not limited:
            raise ValueError('pressure profile did not prove allocation, effective ceiling and process failure')
        return {'classification': outcome, 'supported_configuration': False, 'fault_proven': True,
                'typed_runtime_oom': outcome == 'runtime_oom', 'library_refusal': False}
    if outcome != 'supported' or result['exit_code'] != 0:
        raise ValueError('supported profile encountered OOM, runtime or native failure')
    if result['stdout'].splitlines().count('CHECK '+CHECKS[scenario]+' PASS') != 1:
        raise ValueError('missing or duplicated native semantic completion')
    if not result['samples'] or any(set(x) != {'elapsed_ms', 'fd', 'tasks', 'rss_kib'} for x in result['samples']):
        raise ValueError('native FD/task/RSS measurements unavailable')
    if scenario == 'cpu':
        if proof['cpu_after'].get('nr_throttled', 0) <= proof['cpu_before'].get('nr_throttled', 0):
            raise ValueError('CPU throttling not observed')
        if proof['cpu_after'].get('throttled_usec', 0) <= proof['cpu_before'].get('throttled_usec', 0):
            raise ValueError('CPU throttled time not observed')
    if scenario == 'low_fd' and ('LIMIT nofile=64' not in result['stdout'] or 'FAULT emfile=true held=' not in result['stdout']):
        raise ValueError('effective lowFD or actual EMFILE not proven')
    if scenario == 'resolver':
        if not any(x['name'] == 'hold.example.test' and not x['answered'] for x in result['dns_packets']):
            raise ValueError('DNS active fault did not reach native UDP fixture')
        if not any(x['name'] == 'recover.example.test' and x['answered'] for x in result['dns_packets']):
            raise ValueError('DNS recovery not answered')
    for elapsed, budget in re.findall(r'^DEADLINE elapsed_ns=(\d+) budget_ns=(\d+)$', result['stdout'], re.M):
        if int(elapsed) > int(budget)+1000000000:
            raise ValueError('deadline overshoot exceeded 1 second under quota')
    ledgers = {}
    for phase, values in re.findall(r'^LEDGER (\w+) (.*)$', result['stdout'], re.M):
        row = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', values)}
        if phase in ledgers:
            raise ValueError('duplicated ledger phase')
        ledgers[phase] = row
    if scenario in ('buffers', 'requests', 'pool', 'streams', 'cpu', 'memory'):
        keys = {'connections', 'reserved_connections', 'requests', 'streams', 'reserved_streams', 'buffers', 'owners', 'waiters', 'pool_waiters', 'rejected'}
        if set(ledgers.get('after', {})) != keys or any(value != 0 for key, value in ledgers['after'].items() if key != 'rejected'):
            raise ValueError('public ledger did not return to zero')
        if 'queued' not in ledgers or ledgers['queued']['waiters'] + ledgers['queued']['pool_waiters'] != 1:
            raise ValueError('bounded admission waiter not observed')
        if 'RESULT cancelled' not in result['stdout'] or 'RESULT deadline' not in result['stdout']:
            raise ValueError('deadline/cancellation semantic result missing')
        if scenario == 'streams' and ledgers['during']['streams'] != 1:
            raise ValueError('HTTP/2 stream quota not occupied')
        if scenario == 'pool' and ledgers['during']['connections'] != 1:
            raise ValueError('connection quota not occupied')
        if scenario in ('buffers', 'cpu', 'memory') and (ledgers['during']['buffers'] != 131072 or ledgers['during']['owners'] != 1 or ledgers['after']['rejected'] != 2):
            raise ValueError('buffer/owner/waiter exhaustion not accounted')
    cancellation = [int(e) for e in re.findall(r'^CANCELLATION elapsed_ns=(\d+)$', result['stdout'], re.M)]
    if any(elapsed > 1000000000 for elapsed in cancellation):
        raise ValueError('cancellation completion exceeded one second under quota')
    return {'classification': outcome, 'supported_configuration': True, 'public_ledgers': ledgers,
            'unavailable_counters': ['reserved_requests', 'cancellation_registrations']}


def semantic_criteria(scenario, details):
    """Normalize emitted criteria to strict booleans; detailed evidence stays in semantic_details."""
    if scenario == 'memory_pressure':
        return {'native_fault_classification_validated': details['classification'] in ('runtime_oom', 'kernel_oom')}
    return {'native_profile_validated': details.get('supported_configuration') is True}


def include_retained_diagnostics(report):
    root = ROOT / 'docs/evidence/M12-003/resources'
    diagnostics = []
    path = root / 'mixed-pressure-failure.json'
    if path.is_file():
        original = json.loads(path.read_text())
        failed = next(x for x in original['profiles'] if x['id'] == 'resource_memory_pressure')
        if failed['status'] != 'FAIL' or not failed['timed_out']:
            raise ValueError('retained combined-pressure failure changed')
        diagnostics.append({'id': 'resource_memory_pressure_combined_cpu25', 'status': 'FAIL',
                            'classification': 'supervision_timeout', 'seed': failed['seed'],
                            'exit_code': failed['exit_code'], 'elapsed_ms': failed['elapsed_ms'],
                            'applied_fault_proof': failed['applied_fault_proof'], 'cleanup': failed['cleanup'],
                            'evidence': str(path.relative_to(ROOT)), 'digest': text_evidence_digest(path).to_json()})
    observation = root / 'earlier-runtime-oom.json'
    if observation.is_file():
        report['retained_observations'] = [{'id': 'resource_memory_pressure_earlier_runtime_oom', 'evidence': str(observation.relative_to(ROOT)),
                                             'digest': text_evidence_digest(observation).to_json()}]
    supported = [x for x in report['profiles'] if x['id'] != 'resource_memory_pressure']
    report['supported_tier_status'] = 'PASS' if supported and all(x['status'] == 'PASS' for x in supported) else 'FAIL'
    report['diagnostics'] = diagnostics
    report['status'] = 'PASS' if report['profiles'] and all(x['status'] == 'PASS' for x in report['profiles']) else 'FAIL'
    report['historical_diagnostic_status'] = 'FAIL' if diagnostics else 'NOT_RUN'


def main():
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt('resource campaign cancelled')
    signal.signal(signal.SIGTERM, interrupted)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk-root', type=Path, required=True)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--scratch', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seed', type=int, default=184003)
    p.add_argument('--profile', choices=('all', *SCENARIOS), default='all')
    args = p.parse_args()
    parent = args.scratch.resolve(); output = args.output.resolve(); sdk = args.sdk_root.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True); output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    report = {'schema_version': 1, 'task_id': 'M12-003', 'family': 'resources', 'status': 'FAIL', 'seed': args.seed,
              'release_qualification': 'NOT_QUALIFIED', 'commands': [], 'profiles': [], 'source_digests': {}, 'platform': release.platform_identity()}
    env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work))
    wrapper = Path.home() / '.codex/scripts/codex_cangjie_env'
    def normalize(text):
        for actual, replacement in ((str(work), '<scratch>'), (str(ROOT), '<repo>'), (str(sdk), '<sdk>'), (str(Path.home()), '$HOME')):
            text = text.replace(actual, replacement)
        return text.replace('127.0.0.1', '192.0.2.1')
    def run(name, argv, cwd=work, timeout=600, hidden=False):
        argv = [str(x) for x in argv]
        command = [str(wrapper), '--sdk-root', str(sdk), '--', *argv]
        if hidden:
            command = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--dev-bind', '/dev', '/dev', '--bind', str(work), str(work), '--tmpfs', str(ROOT), '--chdir', str(cwd), '--', *command]
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False; exceeded = False; captured = {'stdout': bytearray(), 'stderr': bytearray()}
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, 'stdout'); selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
        expires = time.monotonic() + timeout
        try:
            while selector.get_map():
                if time.monotonic() >= expires:
                    timed_out = True; break
                for key, _ in selector.select(.05):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk: selector.unregister(key.fileobj); continue
                    room = 1024*1024-len(captured[key.data])
                    captured[key.data].extend(chunk[:room])
                    if len(chunk) > room: exceeded = True; break
                if exceeded: break
            if not timed_out and not exceeded: process.wait(timeout=5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
            selector.close(); process.stdout.close(); process.stderr.close()
        stdout = bytes(captured['stdout']); stderr = bytes(captured['stderr'])
        for kind, stream in [('stdout', stdout), ('stderr', stderr)]:
            (work / (name+'.'+kind+'.raw')).write_bytes(stream)
            (output / (name+'.'+kind+'.log')).write_text(normalize(stream.decode(errors='replace')))
        report['commands'].append({'id': name, 'argv': [normalize(x) for x in command], 'exit_code': process.returncode, 'timed_out': timed_out, 'checkout_hidden': hidden})
        if timed_out or exceeded or process.returncode != 0:
            raise RuntimeError(name+' failed; exact command/logs retained')
        return stdout.decode(errors='replace')
    try:
        if not sdk.name.startswith('sts'):
            raise ValueError('only explicitly selected STS SDKs are permitted')
        if shutil.disk_usage(work).free < 1024**3 or run('scratch-filesystem', ['findmnt', '-n', '-o', 'FSTYPE', '-T', work]).strip() == 'tmpfs':
            raise ValueError('scratch must be disk-backed with at least 1 GiB free')
        report['sdk'] = {'root': '<sdk>', 'compiler': run('compiler', ['cjc', '--version']).strip(),
                         'cjpm': run('cjpm', ['cjpm', '--version']).strip(), 'compiler_digest': artifact_byte_digest(sdk / 'bin/cjc').to_json(),
                         'runtime_digest': artifact_byte_digest(sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so').to_json(),
                         'std_net_digest': artifact_byte_digest(sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so').to_json()}
        # Bind the same complete SDK closure the network campaign records, not just three files.
        report['sdk_files'] = sdk_binding(sdk)
        payload, manifest = release.read_verified_payload(args.archive)
        installed = release.extract_archive(args.archive, work / 'installation')
        _, current = release.collect_payload(ROOT)
        production = {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json() for path in release.production_sources(ROOT)}
        installed_production = {name: text_evidence_digest(installed / name).to_json() for name in production}
        if production != installed_production:
            raise ValueError('archive production sources differ from checkout')
        report['bindings'] = {'archive_digest': artifact_byte_digest(args.archive).to_json(), 'payload_sha256': manifest['payload_sha256'],
                              'production_sources': installed_production, 'source_digest_equality': True,
                              'provider_manifests': {name: json.loads(data) for name, data in payload.items() if name.endswith('provider-manifest.json')}}
        consumer = work / 'consumer'; (consumer / 'src').mkdir(parents=True, exist_ok=True)
        for name in ('main.cj', 'faults.c', 'profile.py'):
            report['source_digests'][str((SOURCE / name).relative_to(ROOT))] = text_evidence_digest(SOURCE / name).to_json()
            shutil.copy2(SOURCE / name, work / name)
        shutil.copy2(SOURCE / 'main.cj', consumer / 'src/main.cj')
        run('native-helper', ['cc', '-O2', '-c', work / 'faults.c', '-o', work / 'faults.o'])
        run('native-helper-archive', ['ar', 'rcs', work / 'libresourcefaults.a', work / 'faults.o'])
        (consumer / 'cjpm.toml').write_text(release.consumer_manifest(installed).replace('wirestack_release_smoke', 'wirestack_m12_003_resources').replace('link-option = ""', 'link-option = "-L'+str(work)+' -lresourcefaults"'))
        run('consumer-build', ['cjpm', 'build'], cwd=consumer, hidden=True)
        binary = consumer / 'target/release/bin/main'
        report['consumer_digest'] = artifact_byte_digest(binary).to_json()
        dependencies = run('consumer-runtime-bindings', ['ldd', binary], hidden=True)
        runtime = re.search(r'libcangjie-runtime\.so\s+=>\s+(\S+)', dependencies)
        if runtime is None or Path(runtime.group(1)).resolve() != (sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so').resolve():
            raise ValueError('consumer runtime is not the selected STS runtime')
        report['sdk']['consumer_runtime_binding'] = normalize(runtime.group(1))
        run('certificate', ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=example.test', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', work / 'key.pem', '-out', work / 'certificate.pem'])
        run('certificate-der', ['openssl', 'x509', '-in', work / 'certificate.pem', '-outform', 'DER', '-out', work / 'certificate.der'])
        run('key-der', ['openssl', 'pkcs8', '-topk8', '-nocrypt', '-in', work / 'key.pem', '-outform', 'DER', '-out', work / 'key.pk8'])
        scenarios = SCENARIOS if args.profile == 'all' else (args.profile,)
        for scenario in scenarios:
            entry = {'id': 'resource_'+scenario, 'status': 'FAIL', 'feature_mappings': FEATURES[scenario],
                     'scenario_path': 'examples/linux/m12_003/resources/main.cj#'+scenario, 'seed': args.seed, 'coverage_keys': COVERAGE[scenario]}
            report['profiles'].append(entry)
            try:
                result_path = work / (scenario+'.json')
                scope = 'wirestack-m12-003-'+uuid.uuid4().hex[:12]
                cpu_quota = '100%' if scenario == 'memory_pressure' else '25%'
                argv = ['systemd-run', '--user', '--scope', '--quiet', '--unit='+scope, '-p', 'CPUQuota='+cpu_quota, '-p', 'MemoryMax='+('96M' if scenario == 'memory_pressure' else '512M'),
                        'bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--dev-bind', '/dev', '/dev', '--bind', str(work), str(work), '--tmpfs', str(ROOT), '--',
                        'python3', work / 'profile.py', '--binary', binary, '--scenario', scenario, '--certificate', work / 'certificate.der', '--key', work / 'key.pk8', '--result', result_path]
                try:
                    run('profile-'+scenario, argv, timeout=45)
                finally:
                    # Stop only this unique owned scope, including descendants after a launcher timeout.
                    subprocess.run(['systemctl', '--user', 'stop', scope+'.scope'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                result = json.loads(result_path.read_text())
                entry.update(result)
                details = validate_profile(scenario, result)
                entry['semantic_details'] = details
                entry['semantic_criteria'] = semantic_criteria(scenario, details)
                entry['measurements'] = {'before': result['phase_samples'].get('before'),
                                         'during_peak': {key: max(x[key] for x in result['samples']) for key in ('fd', 'tasks', 'rss_kib')} if result['samples'] else None,
                                         'after': result['phase_samples'].get('after'),
                                         'during': result['phase_samples'].get('during'),
                                         'rss_is_logical_liveness': False,
                                         'deadline_overshoot_ns': [int(e)-int(b) for e,b in re.findall(r'DEADLINE elapsed_ns=(\d+) budget_ns=(\d+)', result['stdout'])],
                                         'cancellation_completion_ns': [int(e) for e in re.findall(r'CANCELLATION elapsed_ns=(\d+)', result['stdout'])]}
                entry['recovery'] = {'proven': scenario != 'memory_pressure', 'meaning': 'post-release public admission or complete native response' if scenario != 'memory_pressure' else 'failed pressure process has no in-process recovery'}
                if scenario == 'memory_pressure':
                    entry['native_status'] = 'FAIL'
                    entry['library_acceptance'] = 'NOT_APPLICABLE_UNSUPPORTED_CONFIGURATION'
                    entry['diagnostic_validation_status'] = 'PASS' if details['classification'] in ('runtime_oom', 'kernel_oom') else 'FAIL'
                    entry['status'] = entry['diagnostic_validation_status']
                else:
                    entry['status'] = 'PASS'
            except Exception as error:
                entry['failure'] = normalize(str(error))
        include_retained_diagnostics(report)
    except Exception as error:
        report['failure'] = normalize(str(error))
    finally:
        for source in (Path(__file__), ROOT / 'tools/gates/tests/test_m12_003_resources.py', ROOT / 'docs/guides/linux-resource-fault-profiles.md'):
            report['source_digests'][str(source.relative_to(ROOT))] = text_evidence_digest(source).to_json()
        (output / 'report.json').write_text(normalize(json.dumps(report, indent=2))+'\n')
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
