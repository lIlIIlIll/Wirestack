import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
BASE = Path(__file__).resolve().parents[1]
output = BASE/'output'
output.mkdir(exist_ok=True)
(BASE/'runwork').mkdir(mode=0o700, exist_ok=True)
def sha(p): return {'domain': 'artifact-bytes-v1', 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
def host():
    oracle = json.loads((BASE/'sdk-before.json').read_text())
    sdk = Path.home()/'cangjie_sdk/sts1.1.3'
    actual = {n:sha(sdk/n) for n in oracle['sdk_files']}
    assert len(actual) == 392 and actual == oracle['sdk_files'] and oracle['status'] == 'PASS'
    provenance = json.loads((BASE/'input/glibc244/provenance.json').read_text())
    return {'sdk_files': actual, 'sdk_file_count':len(actual), 'sdk_status':'PASS', 'system_glibc': {n:{'resolved_path': str((Path('/lib/x86_64-linux-gnu')/n).resolve()), 'digest':sha((Path('/lib/x86_64-linux-gnu')/n).resolve())} for n in provenance['files']}, 'uid':os.getuid(), 'mount_namespace':os.readlink('/proc/self/ns/mnt')}
def save(p,x):
    p.write_text(json.dumps(x,indent=2).replace(str(Path.home()), '$HOME').replace(str(BASE), '<task>')+'\n')
before = host()
save(output/'host-before.json', before)
argv = ['taskset','-c','0-7','unshare','--user','--map-root-user','--mount','/usr/bin/python3',str(BASE/'capture/bootstrap.py'),'glibc']
with (BASE/'capture-raw.stdout').open('wb') as out, (BASE/'capture-raw.stderr').open('wb') as err:
    code = subprocess.call(argv,stdout=out,stderr=err)
after = host()
save(output/'host-after.json', after)
save(output/'launch.json', {'argv':argv,'exit_code':code,'host_original_unchanged':before==after,'sdk_392_before_exec_pass':True})
for kind in ('stdout','stderr'):
    text = (BASE/f'capture-raw.{kind}').read_text(errors='replace')
    text = text.replace(str(BASE/'runwork'), '<scratch>').replace(str(BASE/'input/repo'), '<repo>').replace(str(Path.home()/'cangjie_sdk/sts1.1.3'), '<sdk>').replace(str(BASE),'<task>').replace(str(Path.home()),'$HOME')
    (output/f'launch.{kind}.log').write_text(text)
report = output/'report.json'
if report.exists():
    x=json.loads(report.read_text())
    x['host_original_unchanged']=before==after
    x['environment_controls']['host_before']=json.loads((output/'host-before.json').read_text())
    x['environment_controls']['host_after']=json.loads((output/'host-after.json').read_text())
    save(report,x)
sys.exit(code)
