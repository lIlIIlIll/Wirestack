import ctypes
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = Path.home()/'.cache/agent-tmp/wirestack-m12-004-server.JFVwz8'
SDK = Path.home()/'cangjie_sdk/sts1.1.3'
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
oracle = json.loads((OLD/'input/sdk-oracle.json').read_text())['sdk_files']
assert len(oracle) == 392
assert all(sha(SDK/name) == item['sha256'] for name,item in oracle.items())
old_host = json.loads((OLD/'output/host-after.json').read_text())['system_glibc']
assert len(old_host) == 14
assert all(sha(Path(item['resolved_path'])) == item['digest']['sha256'] for item in old_host.values())
old_report = json.loads((OLD/'output/report.json').read_text())
old_binaries = old_report['performance']['binary_bindings']
assert set(old_binaries) == {'baseline','candidate'}
assert all(set(values) == {'transport_tls','http','streams'} for values in old_binaries.values())
for label, values in old_binaries.items():
    for layer, expected in values.items():
        assert sha(OLD/'runwork'/(label+'-'+layer)/'target/release/bin/main') == expected['sha256']
old_inputs = json.loads((OLD/'input/inputs.json').read_text())
assert all(sha(OLD/'input'/name) == item['sha256'] for name,item in old_inputs['artifacts'].items())
assert all(sha(OLD/'input/repo'/name) == item['sha256'] for name,item in old_inputs['source_inputs'].items())
new_inputs = json.loads((BASE/'input/inputs.json').read_text())
assert len(new_inputs['source_inputs']) == 10
assert all(sha(BASE/'input/repo'/name) == item['sha256'] for name,item in new_inputs['source_inputs'].items())
assert all(sha(BASE/'input'/name) == item['sha256'] for name,item in new_inputs['artifacts'].items())
libc = ctypes.CDLL(None)
libc.gnu_get_libc_version.restype = ctypes.c_char_p
host_glibc = libc.gnu_get_libc_version().decode()
assert host_glibc == '2.35'
owned = []
for process in Path('/proc').iterdir():
    if not process.name.isdigit() or int(process.name) == os.getpid():
        continue
    try:
        argv = (process/'cmdline').read_bytes()
    except (OSError, ProcessLookupError):
        continue
    if str(BASE).encode() in argv and b'check-originals.py' not in argv:
        owned.append(int(process.name))
assert not owned, owned
keys = [str(path.relative_to(BASE)) for path in (BASE/'runwork').rglob('*') if path.is_file() and path.name in ('key.pem','key.pk8')]
assert not keys, keys
result = {'status':'PASS','scope':'ORIGINAL_AND_NEW_CAMPAIGN_INPUT_PRESERVATION_ONLY','sdk392_unchanged':True,'host_original_glibc14_unchanged':True,'host_glibc':host_glibc,'all_six_original_binaries_unchanged':old_binaries,'old_and_new_archives_unchanged':True,'old_and_new10_source_inputs_unchanged':True,'owned_live_processes':owned,'fixture_private_keys_remaining':keys}
(BASE/'postflight.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
