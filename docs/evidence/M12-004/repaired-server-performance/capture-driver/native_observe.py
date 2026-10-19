import hashlib
import json
import os
from pathlib import Path
import time
BASE=Path(__file__).resolve().parents[1]
started_monotonic_ns=time.monotonic_ns()
targets=json.loads((BASE/'output/namespace-targets.json').read_text())
found=None
while found is None:
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            cmd=(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode()
            if str(BASE/'runwork') not in cmd or 'target/release/bin/main' not in cmd: continue
            if (proc/'exe').resolve().name != 'main': continue
            maps=(proc/'maps').read_text()
            mountinfo=(proc/'mountinfo').read_text()
            env=dict(x.split('=',1) for x in (proc/'environ').read_bytes().decode().split('\0') if '=' in x)
            closure={}
            for name,item in targets.items():
                target=item['target']
                rows=[r for r in mountinfo.splitlines() if r.split()[4]==target]
                actual={'domain':'artifact-bytes-v1','sha256':hashlib.sha256((proc/'root'/target.lstrip('/')).read_bytes()).hexdigest()}
                assert actual['sha256']==item['sha256'] and rows and 'ro' in rows[-1].split()[5].split(',')
                closure[name]={'digest':actual,'read_only':True,'loaded':target in maps,'mountinfo':rows[-1]}
            found={'command':cmd,'affinity':sorted(os.sched_getaffinity(int(proc.name))),'closure':closure,'loaded_maps':maps,'runtime_environment':{k:v for k,v in env.items() if k in ('PATH','LD_LIBRARY_PATH','CANGJIE_HOME') or k.startswith('CJ_')},'note':'Independent outside-namespace live native observation; hashes through /proc/PID/root; observer scans every0.2s until first captured native then exits.'}
            found.update(pid=int(proc.name), mount_namespace=os.readlink(proc/'ns/mnt'), observer_started_monotonic_ns=started_monotonic_ns, observed_monotonic_ns=time.monotonic_ns())
            break
        except (OSError,ProcessLookupError): pass
    if found is None:
        if (BASE/'output/report.json').exists(): raise RuntimeError('campaign finished without live native observation')
        time.sleep(.2)
text=json.dumps(found,indent=2).replace(str(BASE/'runwork'),'<scratch>').replace(str(BASE/'input/repo'),'<repo>').replace(str(Path.home()/'cangjie_sdk/sts1.1.3'),'<sdk>').replace(str(BASE),'<task>').replace(str(Path.home()),'$HOME')
(BASE/'output/native-runtime-observation.json').write_text(text+'\n')
