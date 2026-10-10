import hashlib
import json
import os
from pathlib import Path
import sys
BASE=Path(__file__).resolve().parents[1]
def digest(p): return {'domain':'artifact-bytes-v1','sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
def save(n,x):
    text=json.dumps(x,indent=2).replace(str(BASE/'runwork'),'<scratch>').replace(str(BASE/'input/repo'),'<repo>').replace(str(Path.home()/'cangjie_sdk/sts1.1.3'),'<sdk>').replace(str(BASE),'<task>').replace(str(Path.home()),'$HOME')
    (BASE/'output'/n).write_text(text+'\n')
if sys.argv[1]=='live':
    processes=[]
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit(): continue
        try:
            cmd=(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
            if str(BASE) not in cmd or proc.name==str(os.getpid()): continue
            item={'pid':int(proc.name),'command':cmd}
            try:
                env=dict(x.split('=',1) for x in (proc/'environ').read_bytes().decode().split('\0') if '=' in x)
                item['runtime_environment']={k:v for k,v in env.items() if k in ('PATH','LD_LIBRARY_PATH','CANGJIE_HOME') or k.startswith('CJ_')}
                item['affinity']=sorted(os.sched_getaffinity(int(proc.name)))
                paths=set(line.split()[-1] for line in (proc/'maps').read_text().splitlines() if line.split()[-1].startswith('/'))
                item['loaded_runtime_paths']=sorted(p for p in paths if ('cangjie' in p or Path(p).name in ('libc.so.6','libm.so.6','libpthread.so.0','ld-linux-x86-64.so.2')))
            except Exception as error: item['observation_limit']=str(error)
            processes.append(item)
        except (OSError,ProcessLookupError): pass
    save('live-runtime-observation.json',{'processes':processes,'observer':'outside private namespace; paths are observed mappings, host path hashes would not prove private mounted bytes'})
else:
    p=BASE/'output/report.json'
    x=json.loads(p.read_text())
    binaries={label:{layer:digest(BASE/'runwork'/f'{label}-{layer}'/'target/release/bin/main') for layer in ('transport_tls','http','streams')} for label in ('baseline','candidate')}
    x['binary_bindings_after']=binaries
    x['compiled_consumers_unchanged']=binaries==x['performance']['binary_bindings']
    x['live_runtime_observation']=json.loads((BASE/'output/live-runtime-observation.json').read_text())
    save('report.json',x)
