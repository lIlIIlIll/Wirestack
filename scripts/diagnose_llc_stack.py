#!/usr/bin/env python3
"""Replay a failing llc invocation with different native stack limits."""
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tempfile


def main():
    binary, *args = sys.argv[1:]
    root = Path(os.environ['YJSON_LLC_STACK_DIAGNOSTICS'])
    root.mkdir(parents=True, exist_ok=True)
    case = Path(tempfile.mkdtemp(prefix='case-', dir=root))
    inputs = []
    for arg in args:
        p = Path(arg)
        if p.suffix == '.bc' and p.is_file():
            target = case / p.name
            shutil.copy2(p, target)
            inputs.append({'original': arg, 'saved': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
    soft, hard = resource.getrlimit(resource.RLIMIT_STACK)
    metadata = {'binary': binary, 'args': args, 'inputs': inputs, 'stack_soft': soft, 'stack_hard': hard}
    (case / 'invocation.json').write_text(json.dumps(metadata, indent=2))
    # The compiler is waiting for this wrapper, so original input paths remain valid.
    # Reuse exactly the same argv; no optimization, hwcaps, or output-format changes.
    results = []
    for label, size in [('128MiB', 128*1024*1024), ('512MiB', 512*1024*1024), ('unlimited', resource.RLIM_INFINITY), ('128MiB-repeat', 128*1024*1024)]:
        if hard != resource.RLIM_INFINITY and (size == resource.RLIM_INFINITY or size > hard):
            result = {'setting': label, 'status': 'unavailable', 'hard': hard}
        else:
            def limit():
                resource.setrlimit(resource.RLIMIT_STACK, (size, hard))
                resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            with (case / (label + '.log')).open('w') as log:
                try:
                    p = subprocess.run([binary, *args], stdout=log, stderr=subprocess.STDOUT, preexec_fn=limit, timeout=180)
                    result = {'setting': label, 'exit': p.returncode}
                except subprocess.TimeoutExpired:
                    result = {'setting': label, 'status': 'timeout'}
        results.append(result)
        print('LLC_STACK_COMPARISON ' + json.dumps(result), flush=True)
    (case / 'results.json').write_text(json.dumps(results, indent=2))
    if shutil.which('gdb'):
        def debug_limit():
            resource.setrlimit(resource.RLIMIT_STACK, (128*1024*1024, hard))
        with (case / 'gdb.log').open('w') as log:
            try:
                subprocess.run(['gdb', '-q', '-batch', '-ex', 'set pagination off', '-ex', 'set disable-randomization off', '-ex', 'run', '-ex', 'thread apply all bt 80', '-ex', 'info registers', '-ex', 'info proc mappings', '--args', binary, *args], stdout=log, stderr=subprocess.STDOUT, preexec_fn=debug_limit, timeout=180)
            except subprocess.TimeoutExpired:
                print('LLC_STACK_GDB timeout', flush=True)
        print((case / 'gdb.log').read_text(), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
