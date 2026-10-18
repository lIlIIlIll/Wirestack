#!/usr/bin/env python3
"""Select a fingerprinted glibc runtime inside a private native-VM mount namespace."""
from __future__ import annotations
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools.evidence_digest import artifact_byte_digest

RUNTIME_NAMES = frozenset(('ld-linux-x86-64.so.2', 'libc.so.6', 'libm.so.6', 'libmvec.so.1',
    'libanl.so.1', 'libBrokenLocale.so.1', 'libdl.so.2', 'libnss_compat.so.2',
    'libnss_dns.so.2', 'libnss_files.so.2', 'libpthread.so.0', 'libresolv.so.2',
    'librt.so.1', 'libutil.so.1'))
REQUIRED_NAMES = frozenset(('ld-linux-x86-64.so.2', 'libc.so.6', 'libm.so.6'))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--provenance', type=Path, required=True)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--gid', type=int, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if os.geteuid() != 0 or args.uid <= 0 or args.gid <= 0 or not command:
        raise ValueError('root setup must execute a specified command as an unprivileged user')
    if subprocess.check_output(['systemd-detect-virt'], text=True).strip() != 'kvm':
        raise ValueError('only an owned native KVM guest is eligible')
    if os.readlink('/proc/self/ns/mnt') == os.readlink('/proc/1/ns/mnt'):
        raise ValueError('unshare --mount --propagation private is required')
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        if any(field.startswith('shared:') for field in line.split()[6:line.split().index('-')]):
            raise ValueError('shared mount propagation is forbidden')
    provenance = json.loads(args.provenance.read_text())
    files = provenance['files']
    if not REQUIRED_NAMES <= files.keys() or files.keys() - RUNTIME_NAMES:
        raise ValueError('glibc runtime closure is incomplete or contains unrelated files')
    pairs = []
    for name, digest in files.items():
        source = args.runtime / name
        target = Path('/lib/x86_64-linux-gnu') / name
        if not target.is_file() or artifact_byte_digest(source).to_json() != digest:
            raise ValueError('glibc runtime input or guest destination changed: ' + name)
        pairs.append((source.resolve(), target.resolve()))
    # All mount syscalls use the already mapped old libc. No child executes until
    # the loader and every selected runtime file have been installed coherently.
    libc = ctypes.CDLL(None, use_errno=True)
    mount = libc.mount
    mount.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_ulong, ctypes.c_void_p)
    mount.restype = ctypes.c_int
    for source, target in pairs:
        if mount(os.fsencode(source), os.fsencode(target), None, 4096, None) != 0:
            raise OSError(ctypes.get_errno(), 'private glibc bind mount failed')
        if mount(None, os.fsencode(target), None, 4096 | 32 | 1, None) != 0:
            raise OSError(ctypes.get_errno(), 'private glibc mount was not read-only')
    os.setgroups([args.gid])
    os.setgid(args.gid)
    os.setuid(args.uid)
    os.execvp(command[0], command)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
