#!/usr/bin/env python3
"""Private corruptions of real evidence. Never executes native programs."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import check

HERE=Path(__file__).resolve().parent
CAPTURE=check.BASE/'capture'

if len(sys.argv)>1 and sys.argv[1]=='worker':
    check.INPUT=Path(sys.argv[2])
    sys.argv=[str(HERE/'check.py'),'--report',sys.argv[3],'--output',sys.argv[4]]
    sys.exit(check.main())

report=check.load(CAPTURE/'report.json')
results=[]
failures=[]
native_indices=[i for i,c in enumerate(report['commands']) if c['argv'][0].endswith('/target/release/bin/main')]

def native(r):
    return r['commands'][native_indices[0]]

def drift_binding(r,field,name):
    for phase in ('before','after'):
        r['input_bindings_'+phase][field][name]['sha256']='0'*64

def probe(name,expect,mutate=None,input_file=None,raw=False):
    with tempfile.TemporaryDirectory(prefix='probe-'+name+'-',dir=HERE) as work:
        work=Path(work)
        root=work/'capture'
        root.mkdir()
        for p in CAPTURE.iterdir():
            if p.is_file() and p.name!='report.json':
                (root/p.name).symlink_to(p)
        r=copy.deepcopy(report)
        if mutate:
            mutate(r)
        if raw:
            p=root/Path(native(r)['stdout']['path']).name
            original=p.read_bytes()
            p.unlink()
            p.write_bytes(original+b'corrupted-real-raw-stdout\n')
        inp=check.INPUT
        if input_file:
            inp=work/'input'
            shutil.copytree(check.INPUT,inp)
            p=inp/input_file
            p.write_bytes(p.read_bytes()+b'\ncorrupted-input\n')
        (root/'report.json').write_text(json.dumps(r)+'\n')
        output=work/'result.json'
        cmd=[sys.executable,str(HERE/'probes.py'),'worker',str(inp),str(root/'report.json'),str(output)]
        process=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'TMPDIR':str(HERE),'TMP':str(HERE),'TEMP':str(HERE)})
        value=check.load(output) if output.exists() else {}
        reasons=json.dumps(value.get('errors',{}))+' '+str(value.get('error',''))
        rejected=process.returncode==1 and value.get('technical_verification_status')=='FAIL' and expect in reasons
        row={'probe':name,'exit_code':process.returncode,'expected_rejection':expect,'decision':'REJECTED' if rejected else 'UNEXPECTED','technical_verification_status':value.get('technical_verification_status'),'reason':reasons.replace(str(work),'<probe>'),'stderr':process.stderr.replace(str(work),'<probe>')}
        results.append(row)
        if not rejected:failures.append(name)

probe('wrong-http-source','source binding drift',input_file='repo/examples/linux/m12_001/http.cj')
probe('wrong-archive-bytes','archive binding drift',input_file='candidate.tar.gz')
probe('wrong-external-sdk392-oracle','external SDK oracle drift',input_file='sdk-oracle.json')
probe('changed-threshold-input','source binding drift',input_file='repo/tools/gates/campaigns/m7-024-linux-performance.json')
probe('wrong-source-report-binding','source binding differs',lambda r:drift_binding(r,'source_inputs','examples/linux/m12_001/http.cj'))
probe('wrong-archive-report-binding','archive binding differs',lambda r:drift_binding(r,'artifacts','candidate.tar.gz'))
probe('wrong-sdk392-report-binding','SDK full392 binding differs',lambda r:drift_binding(r,'sdk_files','bin/cjc'))
probe('missing-native-round','missing native attempted command',lambda r:r['commands'].pop(native_indices[0]))
first_case=native(report)['argv'][1]
probe('missing-native-case','missing native attempted command',lambda r:r.__setitem__('commands',[c for c in r['commands'] if not(c['argv'][0].endswith('/target/release/bin/main') and c['argv'][1]==first_case)]))
probe('missing-healthy-sample','successful command missing native sample',lambda r:r['performance']['samples']['candidate'].pop(0))
probe('modified-real-raw-stdout','text log digest mismatch',raw=True)
def reorder(r):
    a,b=native_indices[:2]
    r['commands'][a],r['commands'][b]=r['commands'][b],r['commands'][a]
probe('reordered-native-command','native attempted leg order differs',reorder)
def hidden(r):
    if r['performance'].get('failures'):
        r['performance']['failures'].pop(0)
    else:
        native(r)['exit_code']=17
probe('hidden-native-failure','failed native command reported successful sample' if not report['performance'].get('failures') else 'raw native failures differ',hidden)
probe('modified-native-workload','native attempted workload differs',lambda r:native(r)['argv'].append('extra-workload'))
probe('changed-host-binding','host system/SDK modified',lambda r:r['environment_controls']['host_after']['system_glibc']['libc.so.6']['digest'].__setitem__('sha256','0'*64))
probe('wrong-readonly-glibc-binding','glibc digest differs',lambda r:r['environment_controls']['before']['glibc_readonly_closure']['libc.so.6']['digest'].__setitem__('sha256','0'*64))
probe('writable-native-glibc','live native readonly glibc binding differs',lambda r:r['native_runtime_observation']['closure']['libc.so.6'].__setitem__('read_only',False))
probe('wrong-selected-sdk-root','native selected SDK root differs',lambda r:r['native_runtime_observation']['runtime_environment'].__setitem__('CANGJIE_HOME','<other-sdk>'))
probe('strengthened-formal-status','formal gates strengthened',lambda r:r.__setitem__('formal_m7_024','PASS'))
probe('strengthened-qualification','qualification or scope strengthened',lambda r:r.__setitem__('qualification','QUALIFIED'))
probe('strengthened-soak-status','formal gates strengthened',lambda r:r.__setitem__('formal_soak_86400','PASS'))
probe('unreviewed-adapter','reviewed capture adapter identity differs',lambda r:r['capture_adapters']['driver.py'].__setitem__('sha256','0'*64))
probe('modified-binary-binding','compiled consumer binary binding drift',lambda r:r['binary_bindings_after']['candidate']['http'].__setitem__('sha256','0'*64))
if report['performance'].get('m7_024_tls_thresholds'):
    probe('modified-tls-ratio','recomputed TLS ratios or thresholds differ',lambda r:r['performance']['m7_024_tls_thresholds']['checks'][0].__setitem__('actual',-1))
if report['performance'].get('comparisons'):
    probe('modified-classifier','recomputed classifier differs',lambda r:r['performance']['comparisons'][next(iter(r['performance']['comparisons']))].__setitem__('status','UNTRUSTED'))
    if report['performance']['status'] != 'PASS':
        def strengthen(r):
            r['performance']['status']=r['status']='PASS'
        probe('strengthened-performance-status','launch exit disagrees' if report['status']=='FAIL' else 'recomputed campaign decision differs',strengthen)
def incomplete_sdk(r):
    for phase in ('before','after'):
        r['input_bindings_'+phase]['sdk_files'].pop('bin/cjc')
probe('missing-sdk392-file','SDK full392 binding differs',incomplete_sdk)
probe('strengthened-nested-formal-status','nested formal status strengthened',lambda r:r['performance'].__setitem__('formal_m7_024',{'status':'PASS'}))
probe('controller-monotonic-tampering','controller record differs',lambda r:r['capture_controller'].__setitem__('elapsed_ns',1))
probe('hidden-bootstrap-failure','bootstrap_prerequisite_failure',lambda r:r.pop('bootstrap_prerequisite_failure'))
probe('bootstrap-exit-strengthened','bootstrap prerequisite report altered or omitted',lambda r:r['bootstrap_prerequisite_failure']['report']['capture_attempts'][0].__setitem__('exit_code',0))
probe('bootstrap-raw-hash-tampered','bootstrap prerequisite raw artifact binding differs',lambda r:r['bootstrap_prerequisite_failure']['artifacts']['launch.stderr.log'].__setitem__('sha256','0'*64))
probe('recovered-loader-xbit-removed','recovered private loader mode differs',lambda r:r['bootstrap_recovery'].__setitem__('loader_mode_after','0o600'))
probe('private-mode-receipt-tampered','glibc mode receipt differs',lambda r:r['glibc_mode_after_receipt']['actual_server_modes'].__setitem__('ld-linux-x86-64.so.2','0o600'))
code=1 if failures else 0
result={'schema_version':1,'scope':report['scope'],'evidence':'PRIVATE_CLONES_OF_REAL_NEW_REPORT_AND_RAW_LOGS','report_digest':check.d.text_evidence_digest(CAPTURE/'report.json').to_json(),'probe_count':len(results),'rejected_count':sum(r['decision']=='REJECTED' for r in results),'exit_code':code,'unexpected':failures,'probes':results,'native_executions':0}
(HERE/'rejection-probes.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps({'probe_count':len(results),'rejected_count':result['rejected_count'],'exit_code':code,'unexpected':failures}))
sys.exit(code)
