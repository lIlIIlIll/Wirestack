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
x['capture_attempts']=[{'kind':'paired_native_campaign','attempt':1,'retry':False,'samples_expected':528}]
x['sdk_environment_note']='Actual selected SDK environment is recorded in live_runtime_observation and native_runtime_observation; only STS1.1.3 selected.'
x['loaded_glibc_closure_verified']=all(v['read_only'] for v in x['native_runtime_observation']['closure'].values())
x['readonly_checkout_masks_observed']=all('CHECKOUT_MASK=PASS' in (BASE/'output'/Path(c['stdout']['path']).name).read_text() for c in x['commands'] if c['id'].endswith('-build'))
x['sampling_counts']={'processes':sum(len(rows) for rows in x['performance']['samples'].values()),'warmups':sum(r['warmup'] for rows in x['performance']['samples'].values() for r in rows),'measured':sum(not r['warmup'] for rows in x['performance']['samples'].values() for r in rows),'proc_observations':sum(len(c['process_samples']) for c in x['commands']),'commands':len(x['commands'])}
x['capture_controller']=json.loads((BASE/'output/controller.json').read_text())
x['input_manifest']=json.loads((BASE/'input/inputs.json').read_text())
x['readonly_checkout_mask_count']=sum('CHECKOUT_MASK=PASS' in (BASE/'output'/Path(c['stdout']['path']).name).read_text() for c in x['commands'] if c['id'].endswith('-build'))
x['native_command_exits']={c['id']:c['exit_code'] for c in x['commands'] if 'target/release/bin/main' in ' '.join(c['argv'])}
x['bootstrap_prerequisite_failure']={'report':json.loads((BASE/'bootstrap-failure/report.json').read_text()), 'artifacts':{p.name:{'domain':'artifact-bytes-v1','sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in (BASE/'bootstrap-failure').iterdir() if p.is_file()}}
x['bootstrap_recovery']={'kind':'metadata-only executable-mode restoration before first SDK/native execution','loader_mode_after':oct((BASE/'input/glibc244/ld-linux-x86-64.so.2').stat().st_mode & 0o777),'native_campaign_repeated':False}
declared=x['input_manifest']['prerequisite_environment_metadata']['glibc_file_modes']
actual={n:oct((BASE/'input/glibc244'/n).stat().st_mode & 0o777) for n in declared}
x['glibc_mode_after_receipt']={'declared_bundle_modes':declared,'actual_server_modes':actual,'extraction_umask':'077','explanation':'Private tar extraction masks group/other permissions; owner permissions preserved. Bundle metadata remains unchanged.'}
(BASE/'output/mode-after.json').write_text(json.dumps(x['glibc_mode_after_receipt'],indent=2)+'\n')
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
