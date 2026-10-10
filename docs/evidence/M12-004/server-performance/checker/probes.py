#!/usr/bin/env python3
"""Task-private negative probes. Synthetic records are never campaign evidence."""
import copy, json, tempfile
from pathlib import Path
import check
BASE = Path(__file__).resolve().parent
results = []

def reject(name, callback, expected):
    try:
        callback()
    except (ValueError, KeyError) as error:
        if expected not in str(error):
            raise AssertionError(name + ': wrong rejection ' + str(error))
        results.append({'probe':name, 'decision':'REJECTED', 'reason':str(error)})
    else:
        raise AssertionError(name + ': accepted corrupted input')

with tempfile.TemporaryDirectory(prefix='negative-', dir=BASE) as work:
    work = Path(work)
    # Exercise the production checker guard without inventing positive campaign rows.
    reject('missing-case', lambda: check.verify_samples({'commands':[], 'performance':{'samples':{'baseline':[], 'candidate':[]}}}, work), 'missing native case or round')
    log = work / 'native.stdout.log'
    log.write_text('{"scenario":"tcp_bulk"}\n')
    descriptor = {'path':log.name, 'digest':check.d.text_evidence_digest(log).to_json()}
    log.write_text('{"scenario":"tls_bulk"}\n')
    reject('tampered-log', lambda:check.check_log(work, descriptor), 'text log digest mismatch')
    bad = {'scenario':'tcp_bulk', 'regime':'normal', 'duration_ns':1, 'operations':1, 'successes':1, 'failures':0, 'expected_rejections':0, 'bytes':1, 'checksum':1, 'latencies_ns':[1], 'metrics':{'cleanup_owners':1}}
    reject('cleanup-owner', lambda:check.bench.validate_sample(bad, 'tcp_bulk'), 'owners were not reclaimed')
    oracle = check.load(check.INPUT / 'sdk-oracle.json')
    drifted = copy.deepcopy(oracle['sdk_files'])
    drifted['bin/cjc']['sha256'] = '0' * 64
    reject('SDK-binding-drift', lambda:check.require_sdk(drifted, oracle), 'SDK full392 binding differs')
    if (check.BASE / 'capture/report.json').exists():
        report = check.load(check.BASE / 'capture/report.json')
        omitted = copy.deepcopy(report)
        omitted['performance']['samples']['candidate'].pop(0)
        reject('real-report-missing-native-sample', lambda:check.verify_logs(omitted,check.BASE / 'capture'), 'successful command missing native sample')
        claim = check.diagnostic_tls(report,check.BASE / 'capture')
        bad = copy.deepcopy(claim)
        bad['tls_ratios']['checks'][0]['actual'] = -1
        reject('bad-ratio', lambda:check.require(bad == check.diagnostic_tls(report,check.BASE / 'capture'), 'recomputed TLS ratio claim differs'), 'TLS ratio claim differs')
        inputs, oracle, payloads, manifests = check.static()
        bad = copy.deepcopy(report)
        bad['input_bindings_before']['sdk_files']['bin/cjc']['sha256'] = '0' * 64
        reject('binding-drift', lambda:check.verify_bindings(bad, inputs, oracle, payloads, manifests, check.BASE / 'capture'), 'binding drift')
(BASE / 'rejection-probes.json').write_text(json.dumps({'synthetic_is_not_campaign_success':True, 'probes':results}, indent=2) + '\n')
print(json.dumps(results))
