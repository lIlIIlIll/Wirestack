import hashlib
import json
import os
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
OUT=BASE/'output'
def digest(p,text=False):
    raw=p.read_bytes()
    if text:
        raw=raw.decode().replace('\r\n','\n').replace('\r','\n').encode()
    return {'domain':'text-utf8-lf-v1' if text else 'artifact-bytes-v1','sha256':hashlib.sha256(raw).hexdigest()}
manifest=json.loads((BASE/'input/inputs.json').read_text())
bindings={'source_inputs':{n:digest(BASE/'input/repo'/n,True) for n in manifest['source_inputs']},'artifacts':{n:digest(BASE/'input'/n) for n in manifest['artifacts']}}
assert bindings['source_inputs']==manifest['source_inputs'] and bindings['artifacts']==manifest['artifacts']
controller=json.loads((OUT/'controller.json').read_text())
launch=json.loads((OUT/'launch.json').read_text())
x={'schema_version':1,'task_id':'M12-004','scope':manifest['scope'],'qualification':'NOT_QUALIFIED','status':'ERROR','failure_phase':'PREEXEC_ISOLATION','error':'Fresh bash exec PermissionError13; copied glibc loader mode0600, preceding closure0755. No SDK command, build or native benchmark executed.','formal_m7_024':'NOT_RUN','formal_soak_86400':'NOT_RUN','input_manifest':manifest,'input_bindings_after':bindings,'capture_attempts':[{'kind':'namespace_bootstrap','attempt':1,'retry':False,'exit_code':launch['exit_code'],'native_attempts':0}],'capture_controller':controller,'sampling_counts':{'processes':0,'warmups':0,'measured':0,'proc_observations':0,'commands':0},'commands':[],'readonly_checkout_mask_count':0,'environment_controls':{'host_before':json.loads((OUT/'host-before.json').read_text()),'host_after':json.loads((OUT/'host-after.json').read_text())},'host_original_unchanged':launch['host_original_unchanged'],'loader_mode':oct((BASE/'input/glibc244/ld-linux-x86-64.so.2').stat().st_mode&0o777),'capture_adapters':{p.name:digest(p,True) for p in (BASE/'capture').glob('*.py')}}
def normalize(text):
    return text.replace(str(BASE/'runwork'),'<scratch>').replace(str(BASE/'input/repo'),'<repo>').replace(str(BASE),'<task>').replace(str(Path.home()),'$HOME').replace('/dev/mapper/storage_vg-storage_lv','<host-device>')
for p in OUT.iterdir():
    if p.suffix in ('.json','.log'):
        p.write_text(normalize(p.read_text()))
(OUT/'report.json').write_text(normalize(json.dumps(x,indent=2))+'\n')
print(json.dumps({'status':'ERROR','native_attempts':0,'launcher_exit_code':launch['exit_code'],'own_process_cleanup_count':controller['own_process_cleanup_count']}))
