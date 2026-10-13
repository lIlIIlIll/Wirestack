#!/usr/bin/env python3
"""Reject private mutations of the real frozen input bundle before capture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import check
HERE=Path(__file__).resolve().parent
if len(sys.argv)>1:
    check.INPUT=Path(sys.argv[1])
    sys.argv=[str(HERE/'check.py'),'--output',sys.argv[2]]
    sys.exit(check.main())
results=[]
for name,relative,reason in [('wrong-http-source','repo/examples/linux/m12_001/http.cj','source binding drift'),('wrong-archive','candidate.tar.gz','archive binding drift'),('wrong-sdk392-oracle','sdk-oracle.json','external SDK oracle drift'),('wrong-thresholds','repo/tools/gates/campaigns/m7-024-linux-performance.json','source binding drift')]:
    with tempfile.TemporaryDirectory(prefix='static-control-',dir=HERE) as work:
        work=Path(work)
        inp=work/'input'
        shutil.copytree(check.INPUT,inp)
        p=inp/relative
        p.write_bytes(p.read_bytes()+b'\ncorrupted-real-input\n')
        out=work/'result.json'
        process=subprocess.run([sys.executable,str(Path(__file__).resolve()),str(inp),str(out)],capture_output=True,text=True,env={**os.environ,'TMPDIR':str(HERE),'TMP':str(HERE),'TEMP':str(HERE)})
        value=check.load(out)
        rejected=process.returncode==1 and value.get('technical_verification_status')=='FAIL' and reason in value.get('error','')
        results.append({'probe':name,'exit_code':process.returncode,'decision':'REJECTED' if rejected else 'UNEXPECTED','reason':value.get('error'),'stderr':process.stderr.replace(str(work),'<probe>')})
code=0 if all(r['decision']=='REJECTED' for r in results) else 1
(HERE/'static-rejection-probes.json').write_text(json.dumps({'scope':'REAL_FROZEN_INPUT_NEGATIVE_CONTROLS_ONLY_NOT_CAMPAIGN_ACCEPTANCE','probe_count':len(results),'rejected_count':sum(r['decision']=='REJECTED' for r in results),'exit_code':code,'native_executions':0,'probes':results},indent=2)+'\n')
print(json.dumps({'probe_count':len(results),'exit_code':code}))
sys.exit(code)
