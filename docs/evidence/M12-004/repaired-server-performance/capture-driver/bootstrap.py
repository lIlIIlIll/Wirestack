import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parents[1]
libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p]
def mount(source, target, filesystem, flags, data=None):
    def b(s): return None if s is None else str(s).encode()
    if libc.mount(b(source), b(target), b(filesystem), flags, b(data)):
        raise OSError(ctypes.get_errno(), 'mount failed', str(target))

mount(None, '/', None, 16384 | 262144)
if sys.argv[1] == 'hide':
    repo = BASE / 'input/repo'
    mount('tmpfs', repo, 'tmpfs', 1 | 2 | 4 | 8, 'size=4096')
    assert not list(repo.iterdir())
    print('CHECKOUT_MASK=PASS; entire snapshot repository hidden by readonly child mount', flush=True)
    os.execvp(sys.argv[2], sys.argv[2:])
else:
    provenance = json.loads((BASE / 'input/glibc244/provenance.json').read_text())
    bindings = {}
    for name, expected in provenance['files'].items():
        source = BASE / 'input/glibc244' / name
        actual = hashlib.sha256(source.read_bytes()).hexdigest()
        assert actual == expected['sha256'], name
        target = (Path('/lib/x86_64-linux-gnu') / name).resolve()
        assert target.is_file(), name
        bindings[name] = {'target': str(target), 'sha256': actual}
    (BASE / 'output/namespace-targets.json').write_text(json.dumps(bindings, indent=2)+'\n')
    for name, item in bindings.items():
        mount(BASE / 'input/glibc244' / name, item['target'], None, 4096)
        mount(None, item['target'], None, 4096 | 32 | 1)
    # The controller still maps host libc. Fresh exec is required before any SDK process.
    sdk = Path.home() / 'cangjie_sdk/sts1.1.3'
    os.environ.update(CANGJIE_HOME=str(sdk), TMPDIR=str(BASE / 'runwork'), TMP=str(BASE / 'runwork'), TEMP=str(BASE / 'runwork'))
    os.execv('/bin/bash', ['/bin/bash', '--noprofile', '--norc', '-c', 'source "$CANGJIE_HOME/envsetup.sh" && exec /usr/bin/python3 "$1"', 'namespace-sdk-shell', str(BASE / 'capture/driver.py')])
