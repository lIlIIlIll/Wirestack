#!/usr/bin/env python3
"""M12-003 installed STS consumer under owned Linux user/network namespaces."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools.gates.m2_015_native_network import ProcessTreeSampler, process_tree_snapshot, reset_impairment, configure_namespace, configure_drop, tc_stats
from tools.m12_002_source_sdk import sdk_binding

PROFILES = ('dns_no_response', 'dns_late_result', 'ipv6_blackhole', 'multicandidate_cancel',
            'delay_loss', 'rst', 'silent_disconnect', 'peer_no_read', 'peer_no_write', 'http_rst', 'http_no_write', 'system_resolver_boundary')

COVERAGE = {
    'dns_no_response': ['dns_no_response'], 'dns_late_result': ['dns_late'],
    'ipv6_blackhole': ['ipv6_blackhole_ipv4_reachable'], 'multicandidate_cancel': ['multi_candidate_cancel'],
    'delay_loss': ['delay', 'packet_loss', 'transient_recovery'], 'rst': ['rst'],
    'silent_disconnect': ['silent_disconnect', 'transient_recovery'], 'peer_no_read': ['peer_not_reading'],
    'peer_no_write': ['peer_not_writing'], 'http_rst': ['rst', 'transient_recovery'],
    'http_no_write': ['peer_not_writing', 'transient_recovery'], 'system_resolver_boundary': []}

def normalize(text):
    return str(text).replace(str(ROOT), '<repo>').replace(str(Path.home()), '$HOME')


def command(argv, env=None, cwd=None, timeout=600):
    p = subprocess.run([str(x) for x in argv], env=env, cwd=cwd, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    record = {'command': [normalize(x) for x in argv], 'exit_code': p.returncode, 'output': normalize(p.stdout)}
    if p.returncode:
        raise RuntimeError(json.dumps(record))
    return record


def drop_all():
    command(['tc', 'qdisc', 'add', 'dev', 'lo', 'clsact'])
    command(['tc', 'filter', 'add', 'dev', 'lo', 'egress', 'protocol', 'ip', 'flower',
             'dst_ip', '192.0.2.2', 'ip_proto', 'tcp', 'action', 'drop'])


class Fixture:
    """A bounded native UDP/TCP peer. Events, not sleeps, trigger socket faults."""
    def __init__(self, mode):
        self.mode = mode
        self.stop = threading.Event()
        self.fault_complete = threading.Event()
        self.observations = []
        self.errors = []
        self.sockets = []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if mode.startswith('dns_') else socket.SOCK_STREAM)
        self.sock.settimeout(.1)
        self.sock.bind(('192.0.2.2', 0))
        self.port = self.sock.getsockname()[1]
        self.sockets.append(self.sock)
        if not mode.startswith('dns_'):
            self.sock.listen(8)
        self.worker = threading.Thread(target=self.run)
        self.worker.start()

    def run(self):
        try:
            if self.mode.startswith('dns_'):
                self.dns()
            else:
                self.tcp()
        except OSError as e:
            if not self.stop.is_set(): self.errors.append(str(e))
        except Exception as e:
            self.errors.append(str(e))

    def dns(self):
        pending = None
        while not self.stop.is_set():
            try: data, address = self.sock.recvfrom(2048)
            except socket.timeout: continue
            self.observations.append({'event': 'query_received', 'bytes': len(data), 'id': int.from_bytes(data[:2], 'big')})
            if pending is None:
                pending = (data, address)
                if self.mode == 'dns_no_response': continue
                if not self.fault_complete.wait(3): raise RuntimeError('native DNS deadline event missing')
                late = dns_answer(data)[:-4] + socket.inet_aton('192.0.2.99')
                self.sock.sendto(late, address)
                self.observations.append({'event': 'late_answer_sent_after_caller_deadline', 'bytes': len(late), 'stale_address': '192.0.2.99'})
                continue
            answer = dns_answer(data)
            self.sock.sendto(answer, address)
            self.observations.append({'event': 'recovery_answer_sent', 'bytes': len(answer)})

    def tcp(self):
        index = 0
        while not self.stop.is_set():
            try: peer, _ = self.sock.accept()
            except socket.timeout: continue
            self.sockets.append(peer)
            peer.settimeout(.1)
            index += 1
            self.observations.append({'event': 'accepted', 'connection': index})
            try:
                if self.mode == 'peer_no_read':
                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                    self.observations.append({'event': 'receive_disabled', 'effective_receive_buffer': peer.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)})
                    self.stop.wait(3)
                    continue
                if self.mode == 'delay_loss':
                    first = True
                    while not self.stop.is_set():
                        try: part = peer.recv(1)
                        except socket.timeout: continue
                        if not part: break
                        self.observations.append({'event': 'echo_request', 'bytes': len(part)})
                        if first:
                            command(['tc', 'qdisc', 'change', 'dev', 'lo', 'root', 'netem', 'delay', '20ms', 'loss', '100%'])
                            before = tc_stats('qdisc')
                            peer.sendall(part)
                            expires = time.monotonic() + 1
                            while True:
                                affected = tc_stats('qdisc')
                                if affected['dropped'] > before['dropped']: break
                                if self.stop.is_set() or time.monotonic() >= expires: raise RuntimeError('loss phase did not drop original response')
                                time.sleep(.01)
                            self.observations.append({'event': 'original_response_dropped', 'tc': affected, 'automatic_retry': False})
                            command(['tc', 'qdisc', 'change', 'dev', 'lo', 'root', 'netem', 'delay', '20ms', 'loss', '0%'])
                            self.observations.append({'event': 'packet_fault_removed_before_kernel_retransmit'})
                            first = False
                        else:
                            peer.sendall(part)
                    continue
                data = bytearray()
                while not self.stop.is_set():
                    try: part = peer.recv(4096)
                    except socket.timeout: continue
                    if not part: break
                    data.extend(part)
                    if not self.mode.startswith('http') and self.mode not in ('ipv6_blackhole', 'multicandidate_cancel'): break
                    if b'\r\n\r\n' in data: break
                self.observations.append({'event': 'request_received', 'bytes': len(data), 'connection': index})
                if self.mode in ('rst', 'http_rst') and index == 1:
                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                    self.observations.append({'event': 'abortive_close', 'linger_seconds': 0})
                    continue
                if self.mode == 'silent_disconnect':
                    drop_all()
                    self.observations.append({'event': 'packet_drop_installed_after_request'})
                    peer.sendall(bytes(data))
                    self.observations.append({'event': 'response_submitted_into_packet_drop', 'bytes': len(data)})
                    self.stop.wait(3)
                    continue
                if self.mode in ('peer_no_write', 'http_no_write') and index == 1:
                    self.observations.append({'event': 'response_disabled'})
                    self.fault_complete.wait(3)
                    continue
                if self.mode.startswith('http') or self.mode == 'ipv6_blackhole':
                    peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
                elif self.mode != 'multicandidate_cancel':
                    peer.sendall(bytes(data))
                self.observations.append({'event': 'reply_sent', 'connection': index})
            finally:
                peer.close()

    def close(self):
        self.stop.set()
        self.fault_complete.set()
        for sock in self.sockets:
            sock.close()
        self.worker.join(4)
        if self.worker.is_alive(): raise RuntimeError('fixture thread failed to stop')


def dns_answer(query):
    if len(query) < 17 or query[2] & 0x80:
        raise ValueError('invalid DNS query')
    # Copy exactly one bounded question; query parser belongs to the real consumer.
    end = 12
    while end < len(query) and query[end]:
        size = query[end]
        if size > 63: raise ValueError('invalid DNS label')
        end += 1 + size
    end += 5
    if end != len(query): raise ValueError('unexpected DNS query tail')
    return query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:end] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x01\x00\x04\xc0\x00\x02\x02'


def run_native(args, mode, fixture, apply_fault=None):
    env = os.environ.copy()
    env.update(WIRESTACK_NETWORK_MODE=mode, WIRESTACK_NETWORK_PORT=str(fixture.port))
    env['WIRESTACK_NETWORK_BYTE'] = str(args.seed % 251 + 1)
    if mode == 'system_resolver_boundary':
        env.update(LD_PRELOAD=str(args.scratch / 'gai_delay.so'), WIRESTACK_GAI_DELAY_MS='800', WIRESTACK_GAI_LOG=str(args.scratch / 'gai.log'))
    wrapper = Path.home() / '.codex/scripts/codex_cangjie_env'
    argv = ['setpriv', '--pdeathsig', 'KILL', str(wrapper), '--sdk-root', str(args.sdk_root), '--cwd', str(args.scratch), str(args.scratch / 'consumers/network/target/release/bin/main')]
    p = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    sampler = ProcessTreeSampler()
    sampler.start(p.pid)
    lines = []
    boundaries = {}
    output_bytes = 0
    timed_out = threading.Event()
    def expire():
        timed_out.set()
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    timer = threading.Timer(12, expire)
    timer.start()
    try:
        for line in p.stdout:
            lines.append(line)
            output_bytes += len(line.encode())
            if output_bytes > 1048576:
                expire()
                raise RuntimeError('native output exceeded 1 MiB bound')
            if line.strip() in ('BASELINE', 'RECLAIMED'):
                boundaries[line.strip()] = process_tree_snapshot(p.pid, 0)
                kinds = {}
                for fd in Path(f'/proc/{p.pid}/fd').iterdir():
                    try: target = os.readlink(fd)
                    except FileNotFoundError: continue
                    kind = target.split(':', 1)[0] if target.startswith(('socket:', 'pipe:')) else target if target.startswith('anon_inode:') else 'file'
                    kinds[kind] = kinds.get(kind, 0) + 1
                boundaries[line.strip()]['descriptor_kinds'] = kinds
            if line.strip() == 'BASELINE':
                if apply_fault: apply_fault()
                p.stdin.write('continue\n'); p.stdin.flush()
            elif line.strip() == 'RECLAIMED':
                p.stdin.write('finish\n'); p.stdin.flush()
            if line.strip() == 'FAULT_COMPLETE': fixture.fault_complete.set()
        p.wait(timeout=2)
    finally:
        timer.cancel()
        timer.join()
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        sampler.stop()
        p.stdout.close()
        p.stdin.close()
    text = ''.join(lines)
    results = [json.loads(x[7:]) for x in text.splitlines() if x.startswith('RESULT ')]
    cleanup = [json.loads(x[8:]) for x in text.splitlines() if x.startswith('CLEANUP ')]
    return {'command': [normalize(x) for x in argv], 'exit_code': p.returncode, 'timed_out': timed_out.is_set(),
            'output': normalize(text), 'result': results[0] if len(results) == 1 else None,
            'native_cleanup': cleanup[0] if len(cleanup) == 1 else None,
            'process_resource_samples': sampler.samples,
            'resource_boundaries': boundaries,
            'registrations': 'UNAVAILABLE: public socket/resolver API exposes no registration counter',
            'process_reclaimed': not Path(f'/proc/{p.pid}').exists()}


def evaluate(profile):
    native = profile['consumer']
    proof = profile['applied_fault_proof']
    events = proof['fixture_events']
    names = {e['event'] for e in events}
    checks = {'native_semantics': native['exit_code'] == 0 and native['result'] is not None,
              'native_cleanup': native['native_cleanup'] is not None,
              'process_reclaimed': native['process_reclaimed'], 'fixture_clean': not proof['fixture_errors']}
    baseline = native.get('resource_boundaries', {}).get('BASELINE')
    reclaimed = native.get('resource_boundaries', {}).get('RECLAIMED')
    checks['live_reclamation_sample'] = bool(baseline and reclaimed and baseline['process_count'] > 0 and reclaimed['process_count'] > 0)
    checks['socket_reclaimed_before_exit'] = bool(baseline and reclaimed and reclaimed['socket_count'] <= baseline['socket_count'])
    checks['fd_reclaimed_before_exit'] = bool(baseline and reclaimed and reclaimed['fd_count'] <= baseline['fd_count'])
    mode = profile['id']
    if mode == 'system_resolver_boundary':
        log = proof.get('system_operation_log', '')
        checks['native_system_boundary'] = 'phase=enter' in log and 'phase=exit' in log
        checks['bounded_admission'] = native['result'] is not None and native['result'].get('rejected_queries', 0) > 0
    elif mode.startswith('dns_'):
        checks['actual_dns_traffic'] = 'query_received' in names and 'recovery_answer_sent' in names
        if mode == 'dns_late_result': checks['late_result_after_deadline'] = 'late_answer_sent_after_caller_deadline' in names
    elif mode == 'delay_loss':
        stats = proof['tc']
        checks['netem_delay_effective'] = 'delay 20ms' in stats['raw']
        losses = [e['tc'] for e in events if e['event'] == 'original_response_dropped']
        checks['packets_affected'] = bool(losses and losses[0]['dropped'] > 0 and 'loss 100%' in losses[0]['raw'])
        checks['event_controlled_removal'] = 'packet_fault_removed_before_kernel_retransmit' in names
    elif mode in ('ipv6_blackhole', 'multicandidate_cancel', 'silent_disconnect'):
        checks['filter_dropped_real_packets'] = proof['tc']['dropped'] > 0
    elif mode in ('rst', 'http_rst'): checks['rst_applied'] = 'abortive_close' in names
    elif mode == 'peer_no_read': checks['backpressure_applied'] = 'receive_disabled' in names
    else: checks['peer_response_disabled'] = 'response_disabled' in names
    cleanup = profile.get('cleanup', {})
    checks['fixture_threads_joined'] = isinstance(cleanup, dict) and cleanup.get('fixture_threads_joined') is True
    checks['impairments_removed'] = isinstance(cleanup, dict) and cleanup.get('impairments_removed') is True
    profile['semantic_criteria'] = checks
    profile['status'] = 'PASS' if all(checks.values()) else 'FAIL'
    return profile

def passing(profile):
    """A PASS verdict requires strictly true semantics and proven cleanup predicates."""
    criteria = profile.get('semantic_criteria')
    cleanup = profile.get('cleanup')
    return (isinstance(criteria, dict) and bool(criteria)
            and all(value is True for value in criteria.values())
            and isinstance(cleanup, dict)
            and cleanup.get('fixture_threads_joined') is True
            and cleanup.get('impairments_removed') is True)

def impairments_removed(qdisc_raw, filter_raw):
    task_qdisc_kinds = {line.split()[1] for line in qdisc_raw.splitlines()
                        if line.startswith('qdisc ') and len(line.split()) > 1}
    return not task_qdisc_kinds.intersection({'netem', 'clsact'}) and not filter_raw.strip()



def inside(args):
    def interrupted(signum, frame):
        raise KeyboardInterrupt('network campaign cancelled')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    profiles = []
    configure_namespace()
    for mode in args.profile or PROFILES:
        reset_impairment()
        fixture = Fixture(mode)
        profile = {'id': mode, 'seed': args.seed, 'status': 'FAIL', 'coverage_keys': COVERAGE[mode]}
        fault_setup_ready = False
        try:
            def apply_fault():
                nonlocal fault_setup_ready
                if mode == 'delay_loss':
                    command(['tc', 'qdisc', 'add', 'dev', 'lo', 'root', 'netem', 'delay', '20ms'])
                elif mode == 'ipv6_blackhole': configure_drop('ipv6')
                elif mode == 'multicandidate_cancel':
                    command(['tc', 'qdisc', 'add', 'dev', 'lo', 'clsact'])
                    for protocol, dest in [('ip', '192.0.2.2'), ('ipv6', '2001:db8::2')]:
                        command(['tc', 'filter', 'add', 'dev', 'lo', 'egress', 'protocol', protocol, 'flower', 'dst_ip', dest, 'ip_proto', 'tcp', 'action', 'drop'])
                elif mode == 'silent_disconnect':
                    command(['tc', 'qdisc', 'add', 'dev', 'lo', 'clsact'])
                    reset_impairment()
                fault_setup_ready = True
            profile['consumer'] = run_native(args, mode, fixture, apply_fault)
            stats = tc_stats('qdisc' if mode == 'delay_loss' else 'filter')
            fixture.close()
            profile['applied_fault_proof'] = {'scope': 'actual isolated packet/netem' if mode in ('delay_loss','ipv6_blackhole','multicandidate_cancel','silent_disconnect') else 'native socket fixture',
                'tc': stats, 'fixture_events': fixture.observations, 'fixture_errors': fixture.errors}
            if mode == 'system_resolver_boundary':
                profile['applied_fault_proof']['scope'] = 'TEST ONLY getaddrinfo operation delay; not a packet fault or production hook'
                profile['applied_fault_proof']['system_operation_log'] = normalize((args.scratch / 'gai.log').read_text())
            reset_impairment()
            # Recovery uses a new physical native connection after removal. No retry of a failed profile.
            recovery = Fixture('echo')
            try: profile['recovery'] = run_native(args, 'echo', recovery)
            finally: recovery.close()
            post_removal_qdisc = tc_stats('qdisc')
            post_removal_filter = tc_stats('filter')
            profile['cleanup'] = {'fixture_threads_joined': not fixture.worker.is_alive(),
                'impairments_removed': impairments_removed(post_removal_qdisc['raw'], post_removal_filter['raw']),
                'post_removal_qdisc': post_removal_qdisc['raw'], 'post_removal_filter': post_removal_filter['raw']}
            evaluate(profile)
            profile['semantic_criteria']['new_connection_after_removal'] = profile['recovery']['exit_code'] == 0
            profile['status'] = 'PASS' if passing(profile) else 'FAIL'
        except Exception as e:
            profile['error'] = normalize(e)
            if mode in ('delay_loss', 'ipv6_blackhole', 'multicandidate_cancel', 'silent_disconnect') and not fault_setup_ready:
                profile['status'] = 'BLOCKED'
                profile['missing_prerequisite'] = 'owned packet fault setup did not complete; raw command evidence distinguishes kernel, privilege and harness causes'
                profile['applied_fault_proof'] = {'applied': False, 'stage': 'packet_setup', 'command_failure': normalize(e)}
        finally:
            fixture.close()
            reset_impairment()
        profiles.append(profile)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'profiles.json').write_text(json.dumps({'profiles': profiles}, indent=2) + '\n')
    return 0 if all(p['status'] == 'PASS' for p in profiles) else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('sdk-root', 'archive', 'scratch', 'output'): parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--seed', type=int, default=12003)
    parser.add_argument('--profile', action='append', choices=PROFILES)
    parser.add_argument('--reuse-build', action='store_true', help='Replay an exact source/archive/STS binding from the supplied scratch')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    if argv is None: argv = sys.argv[1:]
    args = parser.parse_args(argv)
    for name in ('sdk_root', 'archive', 'scratch', 'output'): setattr(args, name, getattr(args, name).resolve())
    if args.inside:
        if not os.environ.get('WIRESTACK_PARENT_NETNS') or os.readlink('/proc/self/ns/net') == os.environ['WIRESTACK_PARENT_NETNS']:
            raise RuntimeError('refusing network changes outside owned namespace')
        return inside(args)
    sdk = args.sdk_root.resolve()
    if not sdk.name.startswith('sts') or sdk != (Path.home() / 'cangjie_sdk' / sdk.name).resolve():
        parser.error('an explicitly selected installed STS SDK is required')
    args.scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    if subprocess.check_output(['findmnt', '-n', '-o', 'FSTYPE', '-T', str(args.scratch)], text=True).strip() == 'tmpfs' or shutil.disk_usage(args.scratch).free < 1073741824:
        parser.error('scratch must have at least 1 GiB free on disk, not tmpfs')
    args.output.mkdir(parents=True, exist_ok=True)
    for key in ('TMPDIR','TMP','TEMP'): os.environ[key] = str(args.scratch)
    report = {'schema_version': 1, 'task_id': 'M12-003', 'family': 'network', 'status': 'BLOCKED', 'seed': args.seed,
              'qualification': 'NOT_QUALIFIED', 'commands': [], 'profiles': []}
    report['environment'] = {'kernel': platform.release(), 'architecture': platform.machine(), 'libc': list(platform.libc_ver())}
    try:
        payload, manifest = release.read_verified_payload(args.archive)
        report['archive'] = artifact_byte_digest(args.archive).to_json()
        report['payload_sha256'] = manifest['payload_sha256']
        report['sdk'] = {'policy':'STS-only', 'compiler': artifact_byte_digest(sdk / 'bin/cjc').to_json(), 'cjpm': artifact_byte_digest(sdk / 'tools/bin/cjpm').to_json()}
        report['source_digests'] = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in
            [Path(__file__), ROOT / 'tools/gates/m2_015_native_network.py', ROOT / 'tools/gates/native/gai_delay.c',
             ROOT / 'examples/linux/m12_003/network/src/main.cj', ROOT / 'examples/linux/m12_003/network/cjpm.toml',
             ROOT / 'tools/gates/tests/test_m12_003_network.py', ROOT / 'docs/guides/linux-network-fault-profiles.md']}
        report['sdk_files'] = sdk_binding(sdk)
        binding = {key: report[key] for key in ('archive', 'sdk_files', 'source_digests')}
        app = args.scratch / 'consumers/network'
        if args.reuse_build:
            existing = json.loads((args.scratch / 'build-binding.json').read_text())
            if existing['inputs'] != binding or existing['binary'] != artifact_byte_digest(app / 'target/release/bin/main').to_json():
                raise ValueError('replay source, archive, SDK or native binary binding changed')
        else:
            installed = release.extract_archive(args.archive, args.scratch / 'install')
            installed.rename(args.scratch / 'install/wirestack')
            shutil.copytree(ROOT / 'examples/linux/m12_003/network', app)
            wrapper = Path.home() / '.codex/scripts/codex_cangjie_env'
            report['commands'].append(command(['cc', '-shared', '-fPIC', '-O2', ROOT / 'tools/gates/native/gai_delay.c', '-o', args.scratch / 'gai_delay.so', '-ldl', '-pthread']))
            report['commands'].append(command([wrapper, '--sdk-root', sdk, '--cwd', app, 'cjpm', 'build', '-j', '1']))
            (args.scratch / 'build-binding.json').write_text(json.dumps({'inputs': binding, 'binary': artifact_byte_digest(app / 'target/release/bin/main').to_json()}, indent=2) + '\n')
        report['production_sources'] = {str(p.relative_to(args.scratch / 'install/wirestack')): artifact_byte_digest(p).to_json() for p in release.production_sources(args.scratch / 'install/wirestack')}
        report['provider_binding'] = {str(p.relative_to(args.scratch / 'install/wirestack')): artifact_byte_digest(p).to_json() for p in (args.scratch / 'install/wirestack').rglob('*.a')}
        installed = args.scratch / 'install/wirestack'
        for relative in [*report['production_sources'], *report['provider_binding']]:
            if (installed / relative).read_bytes() != payload[relative] or (ROOT / relative).read_bytes() != payload[relative]:
                raise ValueError('archive, current production and installed inputs differ: ' + relative)
        report['interposer'] = {'test_only': True, 'source': text_evidence_digest(ROOT / 'tools/gates/native/gai_delay.c').to_json(), 'binary': artifact_byte_digest(args.scratch / 'gai_delay.so').to_json()}
        report['consumer_binary'] = artifact_byte_digest(app / 'target/release/bin/main').to_json()
        report['isolation'] = {'user_namespace': True, 'network_namespace': True, 'host_network_modified': False}
        child = ['setpriv', '--pdeathsig', 'KILL', 'unshare', '--user', '--map-root-user', '--net', sys.executable, str(Path(__file__)), *argv, '--inside']
        env = os.environ.copy()
        env['WIRESTACK_PARENT_NETNS'] = os.readlink('/proc/self/ns/net')
        p = subprocess.run(child, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        report['commands'].append({'command': [normalize(x) for x in child], 'exit_code': p.returncode, 'output': normalize(p.stdout)})
        profile_file = args.output / 'profiles.json'
        if profile_file.exists(): report['profiles'] = json.loads(profile_file.read_text())['profiles']
        statuses = {p['status'] for p in report['profiles']}
        report['status'] = 'FAIL' if 'FAIL' in statuses else 'BLOCKED' if 'BLOCKED' in statuses or not statuses else 'PASS' if p.returncode == 0 else 'FAIL'
    except Exception as e:
        report['blocker'] = normalize(e)
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'profiles': len(report['profiles'])}))
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__': raise SystemExit(main())
