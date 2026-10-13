import json
import os
from pathlib import Path
import subprocess
import time
BASE=Path(__file__).resolve().parents[1]
OUT=BASE/'output'
OUT.mkdir(mode=0o700, exist_ok=True)
assert not (OUT/'report.json').exists(), 'No repeated campaigns permitted'
started=time.monotonic_ns()
with (OUT/'controller-launch.stdout.log').open('wb') as out, (OUT/'controller-launch.stderr.log').open('wb') as err:
    launcher=subprocess.Popen(['python3',str(BASE/'capture/launch.py')], stdout=out, stderr=err)
    while not (OUT/'namespace-targets.json').exists() and launcher.poll() is None:
        time.sleep(.05)
    observer=None
    observer_start=None
    if (OUT/'namespace-targets.json').exists():
        observer_start=time.monotonic_ns()
        with (OUT/'observer.stdout.log').open('wb') as oo, (OUT/'observer.stderr.log').open('wb') as oe:
            observer=subprocess.Popen(['python3',str(BASE/'capture/native_observe.py')],stdout=oo,stderr=oe)
        time.sleep(.5)
        with (OUT/'live-observer.stdout.log').open('wb') as lo, (OUT/'live-observer.stderr.log').open('wb') as le:
            live_code=subprocess.call(['python3',str(BASE/'capture/observe.py'),'live'],stdout=lo,stderr=le)
    else:
        live_code=None
    launch_code=launcher.wait()
    observer_code=observer.wait() if observer else None
ended=time.monotonic_ns()
remaining=[]
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit() or int(proc.name)==os.getpid():
        continue
    try:
        cmd=(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
        if str(BASE/'runwork') in cmd and (proc/'exe').resolve().name in ('main','cjc','cjpm'):
            remaining.append({'pid':int(proc.name),'command':cmd.replace(str(BASE),'<task>')})
    except (OSError,ProcessLookupError):
        pass
keys=list((BASE/'runwork').rglob('key.pem'))+list((BASE/'runwork').rglob('key.pk8'))
for key in keys:
    key.unlink()
record={'attempt':1,'retry':False,'started_monotonic_ns':started,'ended_monotonic_ns':ended,'elapsed_ns':ended-started,'observer_start_monotonic_ns':observer_start,'launcher_exit_code':launch_code,'native_observer_exit_code':observer_code,'live_observer_exit_code':live_code,'remaining_own_native_sdk_processes':remaining,'own_process_cleanup_count':len(remaining),'fixture_keys_removed':True}
(OUT/'controller.json').write_text(json.dumps(record,indent=2)+'\n')
if (OUT/'report.json').exists():
    with (OUT/'finish.stdout.log').open('wb') as fo, (OUT/'finish.stderr.log').open('wb') as fe:
        finish_code=subprocess.call(['python3',str(BASE/'capture/finish.py')],stdout=fo,stderr=fe)
    print(json.dumps({'launcher_exit_code':launch_code,'finish_exit_code':finish_code,'elapsed_ns':ended-started}))
else:
    print(json.dumps({'launcher_exit_code':launch_code,'error':'No report produced; original failures retained; no retry'}))
