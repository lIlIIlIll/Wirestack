import hashlib
import json
from pathlib import Path
import runpy
import sys
BASE=Path(__file__).resolve().parents[1]
sys.argv=["observe.py", "finish"]
runpy.run_path(str(BASE/"capture/observe.py"),run_name="__main__")
report=BASE/'output/report.json'
x=json.loads(report.read_text())
x['native_runtime_observation']=json.loads((BASE/'output/native-runtime-observation.json').read_text())
raw=x['native_runtime_observation'].pop('loaded_maps')
x['native_runtime_observation']['loaded_paths']=sorted(set(line.split()[-1] for line in raw.splitlines() if line.split()[-1].startswith('/')))
x['capture_adapters']={p.name:{'domain':'text-utf8-lf-v1','sha256':hashlib.sha256(p.read_text().replace('\r\n','\n').encode()).hexdigest()} for p in sorted((BASE/'capture').glob('*.py'))}
x['capture_attempts']=[{'kind':'paired_native_campaign','attempt':1,'retry':False,'samples_expected':528}, {'kind':'observer_prerequisite','command':'python3 <task>/capture/observe.py native','exit_code':1,'error':'FileNotFoundError final report not yet present; wrong observer entrypoint. Corrected with standalone native_observe.py before observation; native campaign not restarted.'}]
x['sdk_environment_note']='Live driver PATH selects STS1.1.3/bin then tools/bin. envsetup LD_LIBRARY_PATH selects STS runtime and tools/lib, trailing empty component permits current directory; no inherited non-STS path. Cjpm compiler children prepend installed native archive dirs. Profile unchanged during campaign.'
x['loaded_glibc_closure_verified']=all(v['read_only'] for v in x['native_runtime_observation']['closure'].values())
x['readonly_checkout_masks_observed']=all('CHECKOUT_MASK=PASS' in (BASE/'output'/Path(c['stdout']['path']).name).read_text() for c in x['commands'] if c['id'].endswith('-build'))
x['sampling_counts']={'processes':sum(len(rows) for rows in x['performance']['samples'].values()),'warmups':sum(r['warmup'] for rows in x['performance']['samples'].values() for r in rows),'measured':sum(not r['warmup'] for rows in x['performance']['samples'].values() for r in rows),'proc_observations':sum(len(c['process_samples']) for c in x['commands']),'commands':len(x['commands'])}
report.write_text(json.dumps(x,indent=2)+'\n')
def normalize(text):
    text=text.replace(str(BASE/'runwork'),'<scratch>').replace(str(BASE/'input/repo'),'<repo>').replace(str(Path.home()/'cangjie_sdk/sts1.1.3'),'<sdk>').replace(str(BASE),'<task>').replace(str(Path.home()),'$HOME')
    text=text.replace('/'+Path.home().name+'/', '/<user>/')
    text=text.replace('/dev/mapper/storage_vg-storage_lv','<host-device>')
    return text
for p in (BASE/'output').iterdir():
    if p.suffix in ('.json','.log','.py'):
        p.write_text(normalize(p.read_text()))
x=json.loads(report.read_text())
for c in x['commands']:
    for kind in ('stdout','stderr'):
        p=BASE/'output'/Path(c[kind]['path']).name
        c[kind]['digest']={'domain':'text-utf8-lf-v1','sha256':hashlib.sha256(p.read_text().replace('\r\n','\n').encode()).hexdigest()}
report.write_text(json.dumps(x,indent=2)+'\n')
print(json.dumps({'status':x['status'],'counts':x['sampling_counts'],'bindings_unchanged':x['bindings_unchanged'],'compiled_consumers_unchanged':x['compiled_consumers_unchanged'],'host_original_unchanged':x['host_original_unchanged'],'readonly_checkout_masks_observed':x['readonly_checkout_masks_observed']}))
