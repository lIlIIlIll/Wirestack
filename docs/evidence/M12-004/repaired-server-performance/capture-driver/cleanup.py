import json
import os
from pathlib import Path
import signal
BASE=Path(__file__).resolve().parents[1]
stopped=[]
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        argv=(proc/'cmdline').read_bytes().split(b'\0')
        if str(BASE/'capture/native_observe.py').encode() in argv:
            os.kill(int(proc.name),signal.SIGTERM)
            stopped.append(int(proc.name))
    except (OSError,ProcessLookupError):
        pass
(BASE/'output/prerequisite-cleanup.json').write_text(json.dumps({'stopped_own_observer_pids':stopped,'reason':'Launcher exited before fresh SDK shell; no report will be created; observer otherwise waits forever'},indent=2)+'\n')
print(json.dumps({'stopped_observers':len(stopped)}))
