#!/usr/bin/env python3
"""Bound M12-003 profile processes and clean their process groups on every exit."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time


def group_members(group: int) -> list[int]:
    result = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            raw = (path / 'stat').read_text()
            fields = raw[raw.rindex(')') + 2:].split()
            if int(fields[2]) == group and fields[0] != 'Z':
                result.append(int(path.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    return result


def terminate_group(process: subprocess.Popen, grace_seconds: float) -> list[int]:
    """TERM allows fixture cleanup; KILL bounds unresponsive native children."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    stop = time.monotonic() + grace_seconds
    while group_members(process.pid) and time.monotonic() < stop:
        time.sleep(.01)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=max(1.0, grace_seconds))
    stop = time.monotonic() + max(1.0, grace_seconds)
    remaining = group_members(process.pid)
    while remaining and time.monotonic() < stop:
        time.sleep(.01)
        remaining = group_members(process.pid)
    return remaining


def run_owned(argv: list[str], *, cwd: Path, environment: dict[str, str], output: Path,
              timeout_seconds: float, cancellation: threading.Event | None = None,
              maximum_log_bytes: int = 64 * 1024 * 1024, grace_seconds: float = 2.0) -> dict:
    if not argv or timeout_seconds <= 0 or maximum_log_bytes <= 0 or grace_seconds < 0:
        raise ValueError('argv and positive execution/log bounds are required')
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    reason = 'EXIT'
    process = None
    remaining = []
    try:
        with (output / 'stdout.raw').open('wb') as stdout, (output / 'stderr.raw').open('wb') as stderr, selectors.DefaultSelector() as streams:
            process = subprocess.Popen(argv, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True)
            for pipe, destination in ((process.stdout, stdout), (process.stderr, stderr)):
                os.set_blocking(pipe.fileno(), False)
                streams.register(pipe, selectors.EVENT_READ, [destination, 0])
            while True:
                if cancellation is not None and cancellation.is_set():
                    reason = 'CANCELLED'
                    break
                if time.monotonic() - started >= timeout_seconds:
                    reason = 'TIMEOUT'
                    break
                exited = process.poll() is not None
                events = streams.select(0 if exited else .02)
                if exited and not events:
                    break
                for key, _mask in events:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        streams.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    destination, count = key.data
                    accepted = min(len(chunk), maximum_log_bytes - count)
                    destination.write(chunk[:accepted])
                    key.data[1] += accepted
                    if accepted != len(chunk):
                        reason = 'OUTPUT_LIMIT'
                        break
                if reason != 'EXIT':
                    break
    finally:
        if process is not None:
            remaining = terminate_group(process, grace_seconds)
            for pipe in (process.stdout, process.stderr):
                pipe.close()
    elapsed = time.monotonic() - started
    exit_code = process.returncode if process is not None else None
    result = {'status': 'PASS' if reason == 'EXIT' and exit_code == 0 and not remaining else 'FAIL',
        'completion': reason, 'exit_code': exit_code, 'elapsed_ms': round(elapsed * 1000, 3),
        'timeout_seconds': timeout_seconds, 'termination_grace_seconds': grace_seconds,
        'deadline_overshoot_ms': round(max(0, elapsed - timeout_seconds) * 1000, 3) if reason == 'TIMEOUT' else 0,
        'maximum_log_bytes': maximum_log_bytes, 'remaining_live_owned_processes': len(remaining),
        'stdout_bytes': (output / 'stdout.raw').stat().st_size,
        'stderr_bytes': (output / 'stderr.raw').stat().st_size}
    (output / 'supervision.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=float, required=True)
    parser.add_argument('--maximum-log-bytes', type=int, default=64 * 1024 * 1024)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    cancellation = threading.Event()
    old = {signum: signal.signal(signum, lambda _signal, _frame: cancellation.set())
           for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        result = run_owned(command, cwd=Path.cwd(), environment=dict(os.environ), output=args.output,
            timeout_seconds=args.timeout_seconds, cancellation=cancellation,
            maximum_log_bytes=args.maximum_log_bytes)
        print(json.dumps(result, sort_keys=True))
        return 0 if result['status'] == 'PASS' else 1
    finally:
        for signum, handler in old.items():
            signal.signal(signum, handler)


if __name__ == '__main__':
    raise SystemExit(main())
