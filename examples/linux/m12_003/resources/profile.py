#!/usr/bin/env python3
"""One owned cgroup scope, native child and bounded DNS fixture."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import socket
import struct
import subprocess
import threading
import time


def counters(path):
    return {key: int(value) for key, value in (line.split() for line in path.read_text().splitlines())}


def cgroup():
    entry = next(line for line in Path('/proc/self/cgroup').read_text().splitlines() if line.startswith('0::'))
    return Path('/sys/fs/cgroup') / entry[3:].lstrip('/')


def sample(pid):
    root = Path('/proc') / str(pid)
    try:
        rss = next(int(line.split()[1]) for line in (root / 'status').read_text().splitlines() if line.startswith('VmRSS:'))
        return {'fd': len(list((root / 'fd').iterdir())), 'tasks': len(list((root / 'task').iterdir())), 'rss_kib': rss}
    except (FileNotFoundError, StopIteration, ProcessLookupError):
        return None


def main():
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt('resource profile cancelled')
    signal.signal(signal.SIGTERM, interrupted)
    p = argparse.ArgumentParser()
    p.add_argument('--binary', required=True)
    p.add_argument('--scenario', required=True)
    p.add_argument('--certificate', required=True)
    p.add_argument('--key', required=True)
    p.add_argument('--result', type=Path, required=True)
    a = p.parse_args()
    group = cgroup()
    proof = {'cpu_max': (group / 'cpu.max').read_text().strip(), 'memory_max': (group / 'memory.max').read_text().strip(),
             'cpu_before': counters(group / 'cpu.stat'), 'memory_before': counters(group / 'memory.events')}
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 0)); udp.settimeout(.05)
    stop = threading.Event(); records = []
    def dns():
        while not stop.is_set():
            try: packet, peer = udp.recvfrom(4096)
            except socket.timeout: continue
            except OSError: break
            index = 12; labels = []
            while index < len(packet) and packet[index]:
                length = packet[index]; index += 1
                labels.append(packet[index:index+length].decode('ascii')); index += length
            name = '.'.join(labels); records.append({'name': name, 'received': True, 'answered': name.startswith('recover.')})
            if name.startswith('recover.'):
                question = packet[12:index+5]
                answer = struct.pack('!HHHIH', 0xc00c, 1, 1, 0, 4) + bytes((192, 0, 2, 1))
                udp.sendto(packet[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + question + answer, peer)
    thread = threading.Thread(target=dns); thread.start()
    argv = [a.binary, a.scenario]
    if a.scenario in ('streams', 'pool', 'requests'): argv += [a.certificate, a.key]
    if a.scenario == 'resolver': argv += [str(udp.getsockname()[1])]
    if a.scenario == 'low_fd': resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    child = None; samples = []; phases = {}; line_buffer = bytearray()
    streams = {'stdout': bytearray(), 'stderr': bytearray()}; timed_out = False
    started = time.monotonic()
    try:
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ, 'stdout'); selector.register(child.stderr, selectors.EVENT_READ, 'stderr')
        while selector.get_map():
            if time.monotonic()-started > 30:
                timed_out = True; os.killpg(child.pid, signal.SIGKILL)
            point = sample(child.pid)
            if point is not None: samples.append(dict(elapsed_ms=int((time.monotonic()-started)*1000), **point))
            for key, _ in selector.select(.02):
                data = os.read(key.fileobj.fileno(), 8192)
                if not data: selector.unregister(key.fileobj); continue
                streams[key.data].extend(data)
                if len(streams[key.data]) > 1024*1024: raise RuntimeError('bounded child output exceeded')
                if key.data == 'stdout':
                    line_buffer.extend(data)
                    while b'\n' in line_buffer:
                        line, _, remainder = line_buffer.partition(b'\n'); line_buffer[:] = remainder
                        fields = line.decode(errors='replace').split()
                        phase = fields[1] if len(fields) > 1 and fields[0] in ('MARK', 'LEDGER', 'DNS') else None
                        if fields[:2] == ['FAULT', 'emfile=true']: phase = 'during'
                        point = sample(child.pid) if phase is not None else None
                        if point is not None: phases[phase] = point
        child.wait(timeout=3); selector.close()
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=3)
        stop.set(); udp.close(); thread.join(2)
        proof.update(cpu_after=counters(group / 'cpu.stat'), memory_after=counters(group / 'memory.events'))
        result = {'exit_code': None if child is None else child.returncode, 'timed_out': timed_out,
                  'elapsed_ms': int((time.monotonic()-started)*1000), 'applied_fault_proof': proof,
                  'samples': samples, 'phase_samples': phases, 'dns_packets': records, 'cleanup': {'child_reaped': child is not None and child.poll() is not None, 'dns_thread_stopped': not thread.is_alive()},
                  **{key: value.decode(errors='replace') for key, value in streams.items()}}
        a.result.write_text(json.dumps(result, indent=2)+'\n')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
