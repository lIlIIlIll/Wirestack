import json
import os
from pathlib import Path
import select
BASE=Path(__file__).resolve().parents[1]
observed=json.loads((BASE/'output/live-runtime-observation.json').read_text())
launcher=next(p['pid'] for p in observed['processes'] if p['command'].startswith('python3 <task>/capture/launch.py'))
try:
    fd=os.pidfd_open(launcher)
    select.select([fd],[],[])
    os.close(fd)
except ProcessLookupError:
    pass
report=BASE/'output/report.json'
if not report.exists(): raise RuntimeError('original launcher exited without final report; no retry performed')
print('ORIGINAL_CAMPAIGN_COMPLETE')
