from collections import Counter
import json
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
x=json.loads((BASE/'output/report.json').read_text())
p=x.get('performance',{})
natives=[c for c in x.get('commands',[]) if 'target/release/bin/main' in ' '.join(c['argv'])]
samples=[r for rows in p.get('samples',{}).values() for r in rows]
before=p.get('summaries',{}).get('baseline',{})
after=p.get('summaries',{}).get('candidate',{})
ratios={}
if before and after:
    ratios={'tls_bulk_throughput':after['tls_bulk']['successful_bytes_per_second']/before['tls_bulk']['successful_bytes_per_second'],'tls_full_p50':after['tls_full']['p50_ns']/before['tls_full']['p50_ns'],'tls_full_p95':after['tls_full']['p95_ns']/before['tls_full']['p95_ns']}
summary={'status':x['status'],'native_attempts':len(natives),'native_success':sum(c['exit_code']==0 and not c['timed_out'] for c in natives),'native_fail':sum(c['exit_code']!=0 or c['timed_out'] for c in natives),'native_timeouts':sum(c['timed_out'] for c in natives),'sampled_warmups':sum(r['warmup'] for r in samples),'sampled_measured':sum(not r['warmup'] for r in samples),'sample_failures':len(p.get('failures',[])),'classifier_counts':dict(Counter(v['status'] for v in p.get('comparisons',{}).values())),'tls_ratios':ratios,'tls_domain':p.get('m7_024_tls_thresholds'),'sampling_counts':x.get('sampling_counts'),'launcher_exit':x.get('capture_controller',{}).get('launcher_exit_code'),'controller_elapsed_ns':x.get('capture_controller',{}).get('elapsed_ns'),'bindings_unchanged':x.get('bindings_unchanged'),'compiled_consumers_unchanged':x.get('compiled_consumers_unchanged'),'host_original_unchanged':x.get('host_original_unchanged'),'mask_count':x.get('readonly_checkout_mask_count'),'own_process_cleanup_count':x.get('capture_controller',{}).get('own_process_cleanup_count')}
(BASE/'output/capture-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
