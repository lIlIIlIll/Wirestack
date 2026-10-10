import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import time

BASE = Path(__file__).resolve().parent
REFERENCE = Path.home() / '.cache/agent-tmp/wirestack-m12-004-server.JFVwz8'
SDK = Path.home() / 'cangjie_sdk/sts1.1.3'
EXPECTED = json.loads((REFERENCE / 'input/sdk-oracle.json').read_text())['sdk_files']
assert len(EXPECTED) == 392
for name, digest in EXPECTED.items():
    assert hashlib.sha256((SDK / name).read_bytes()).hexdigest() == digest['sha256'], name
libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p]
def mount(source, target, flags):
    def byte(value): return None if value is None else str(value).encode()
    if libc.mount(byte(source), byte(target), None, flags, None):
        raise OSError(ctypes.get_errno(), 'mount failed', str(target))
mount(None, '/', 16384 | 262144)
provenance = json.loads((REFERENCE / 'input/glibc244/provenance.json').read_text())
closure = {}
for name, expected in provenance['files'].items():
    source = REFERENCE / 'input/glibc244' / name
    actual = hashlib.sha256(source.read_bytes()).hexdigest()
    assert actual == expected['sha256'], name
    target = (Path('/lib/x86_64-linux-gnu') / name).resolve()
    assert target.is_file(), name
    host_digest = hashlib.sha256(target.read_bytes()).hexdigest()
    mount(source, target, 4096)
    mount(None, target, 4096 | 32 | 1)
    closure[name] = {'sha256': actual, 'host_sha256': host_digest, 'read_only': True}
for label in ('baseline-http', 'candidate-http', 'installed-baseline', 'installed-candidate'):
    target = REFERENCE / 'runwork' / label
    mount(target, target, 4096)
    mount(None, target, 4096 | 32 | 1)
receipt = {'status': 'PASS', 'scope': 'STS_ONLY_RELEASE_LATCH_FIX_NOT_PERFORMANCE_ACCEPTANCE',
    'sdk_file_count': len(EXPECTED), 'sdk_files': EXPECTED, 'glibc': closure,
    'readonly_originals': True, 'affinity': sorted(os.sched_getaffinity(0))}
(BASE / 'receipts').mkdir(mode=0o700, exist_ok=True)
(BASE / 'receipts' / (str(time.monotonic_ns()) + '-namespace.json')).write_text(json.dumps(receipt, indent=2) + '\n')
(BASE / 'tmp').mkdir(mode=0o700, exist_ok=True)
os.environ.update(CANGJIE_HOME=str(SDK), CANGJIE_SDK_ROOT=str(SDK), TMPDIR=str(BASE/'tmp'), TMP=str(BASE/'tmp'), TEMP=str(BASE/'tmp'), DISABLE_ZOXIDE='1')
os.execv('/bin/bash', ['/bin/bash', '--noprofile', '--norc', '-c', 'source "$CANGJIE_HOME/envsetup.sh" && exec "$@"', 'sts-latch-fix', *sys.argv[1:]])
