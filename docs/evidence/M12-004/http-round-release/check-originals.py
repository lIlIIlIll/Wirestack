import ctypes
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent
REFERENCE = Path.home() / '.cache/agent-tmp/wirestack-m12-004-server.JFVwz8'
SDK = Path.home() / 'cangjie_sdk/sts1.1.3'
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
oracle = json.loads((REFERENCE/'input/sdk-oracle.json').read_text())['sdk_files']
assert len(oracle) == 392
assert all(sha(SDK/name) == value['sha256'] for name, value in oracle.items())
host = json.loads((REFERENCE/'output/host-after.json').read_text())['system_glibc']
assert len(host) == 14
assert all(sha(Path(item['resolved_path'])) == item['digest']['sha256'] for item in host.values())
old_binaries = {'baseline': 'd132fe407098689cab5115c10d520486906fbf651b25dd3306f0d8910b29add1', 'candidate': '538e4c728db27d17db8d171a790fd8357fed0c62e3f668e87b1c835eb0992557'}
for label, digest in old_binaries.items():
    assert sha(REFERENCE/'runwork'/(label+'-http')/'target/release/bin/main') == digest
inputs = json.loads((REFERENCE/'input/inputs.json').read_text())
assert all(sha(REFERENCE/'input'/name) == value['sha256'] for name, value in inputs['artifacts'].items())
assert all(sha(REFERENCE/'input/repo'/name) == value['sha256'] for name, value in inputs['source_inputs'].items())
fixed_inputs = {'http.cj': '1c6a4942dfc97ff6b7b5a765ff19501b6239e73fe4e310c91da107feb6441ba7', 'common.cj': '877b4f985d16c990c43ebfca9627d85aa94460ccfcc043c228448e0703153129'}
assert all(sha(BASE/'input'/name) == digest for name, digest in fixed_inputs.items())
libc = ctypes.CDLL(None)
libc.gnu_get_libc_version.restype = ctypes.c_char_p
host_version = libc.gnu_get_libc_version().decode()
assert host_version == '2.35'
owned = []
for entry in Path('/proc').iterdir():
    if not entry.name.isdigit() or int(entry.name) == os.getpid():
        continue
    try:
        cmd = (entry/'cmdline').read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
    if str(BASE).encode() in cmd and b'check-originals.py' not in cmd:
        owned.append(int(entry.name))
assert not owned, owned
keys = sorted(str(path.relative_to(BASE)) for path in (BASE/'native').rglob('*') if path.is_file() and path.name in ('key.pem', 'key.pk8'))
assert not keys, keys
result = {'status': 'PASS', 'scope': 'REPAIR_INPUT_AND_OWNED_PROCESS_INTEGRITY_ONLY', 'sdk392_unchanged': True, 'host_original_glibc14_unchanged': True, 'host_glibc': host_version, 'both_original_http_binaries_unchanged': old_binaries, 'original_source_inputs_unchanged': len(inputs['source_inputs']), 'original_archives_unchanged': inputs['artifacts'], 'fixed_consumer_inputs_unchanged': fixed_inputs, 'owned_live_processes': owned, 'fixture_private_keys_remaining': keys}
(BASE/'originals-after.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
