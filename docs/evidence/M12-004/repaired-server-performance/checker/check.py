#!/usr/bin/env python3
"""Independent read-only Server evidence verification. Never performs measurements."""
import argparse, ast, json, sys, tarfile
from pathlib import Path
BASE = Path(__file__).resolve().parent.parent
INPUT = BASE / 'checker/recovered-input/input'
sys.dont_write_bytecode = True
sys.path.insert(0, str(INPUT / 'repo'))
from tools import evidence_digest as d
from tools.benchmarks import m12_001_end_to_end as bench
from tools.gates import m7_024_linux_performance as perf

def require(value, message):
    if not value:
        raise ValueError(message)

def load(path):
    return json.loads(path.read_text(), parse_constant=lambda x: (_ for _ in ()).throw(ValueError('nonfinite JSON')))

def require_sdk(actual, oracle):
    require(actual == oracle['sdk_files'] and len(actual) == 392, 'SDK full392 binding differs from external qualified oracle')

def static():
    inputs = load(INPUT / 'inputs.json')
    for name, digest in inputs['source_inputs'].items():
        require(d.text_evidence_digest(INPUT / 'repo' / name).to_json() == digest, 'source binding drift: ' + name)
    for name, digest in inputs['artifacts'].items():
        require(d.artifact_byte_digest(INPUT / name).to_json() == digest, 'archive binding drift: ' + name)
    require(d.text_evidence_digest(INPUT / 'sdk-oracle.json').to_json() == inputs['sdk_oracle'], 'external SDK oracle drift')
    oracle = load(INPUT / 'sdk-oracle.json')
    require(oracle['status'] == 'PASS' and len(oracle['sdk_files']) == 392, 'qualified SDK oracle is not PASS/full392')
    payloads = {}
    manifests = {}
    for label in ('baseline', 'candidate'):
        with tarfile.open(INPUT / (label + '.tar.gz')) as archive:
            files = {m.name.split('/', 1)[1]: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}
        manifest = json.loads(files['release-manifest.json'])
        entries = manifest['payload']
        require(len({e['path'] for e in entries}) == len(entries), 'duplicate archive payload')
        for entry in entries:
            raw = files[entry['path']]
            require(len(raw) == entry['bytes'] and d.artifact_bytes_sha256(raw) == entry['sha256'], 'archive manifest payload mismatch')
        from tools.m7_021_linux_release import canonical_json
        require(d.text_evidence_bytes_sha256(canonical_json(entries)) == manifest['payload_sha256'], 'manifest aggregate mismatch')
        payloads[label] = {e['path']: {'domain': 'artifact-bytes-v1', 'sha256': e['sha256']} for e in entries}
        require(set(files) == set(payloads[label]) | {'release-manifest.json'}, 'archive has undeclared files')
        payloads[label]['release-manifest.json'] = d.artifact_byte_digest_bytes(files['release-manifest.json']).to_json()
        manifests[label] = manifest
    return inputs, oracle, payloads, manifests

def check_log(root, descriptor):
    path = root / Path(descriptor['path']).name
    require(path.is_file(), 'missing referenced log: ' + path.name)
    require(d.text_evidence_digest(path).to_json() == descriptor['digest'], 'text log digest mismatch: ' + path.name)
    return path.read_text()

def verify_samples(report, root):
    result = report['performance']
    require(not result.get('failures'), 'campaign reports sample failures')
    commands = report['commands']
    ids = {c['id']: c for c in commands}
    require(len(ids) == len(commands), 'duplicate command identity')
    for command in commands:
        require(type(command['wall_ns']) is int and command['wall_ns'] > 0, 'invalid command monotonic duration')
        for stream in ('stdout', 'stderr'):
            check_log(root, command[stream])
    expected = [(layer, case) for layer, cases in bench.CASES.items() for case in cases]
    schedule = []
    for number in range(-1, 7):
        for layer, case in expected if number % 2 == 0 else reversed(expected):
            for label in ('baseline', 'candidate') if number % 2 == 0 else ('candidate', 'baseline'):
                schedule.append((label, layer, case, max(0, number), number < 0))
    actual = []
    used = set()
    summaries = {}
    for label in ('baseline', 'candidate'):
        rows = result['samples'][label]
        require(len(rows) == 264, 'missing native case or round: ' + label)
        grouped = {}
        for row in rows:
            command = ids[row['command_id']]
            require(command['exit_code'] == 0 and command['timed_out'] is False, 'native sample command failed or timed out: ' + command['id'])
            require(row['command_id'] not in used, 'native command reused')
            used.add(row['command_id'])
            identity = (label, row['layer'], row['scenario'], row['round'], row['warmup'])
            require(identity in schedule, 'unknown native case/round')
            actual.append((commands.index(command), identity))
            native_case = 'http_observed' if row['scenario'] == 'http_unobserved' else row['scenario']
            argv = command['argv']
            require(argv == bench.workload_arguments(Path(argv[0]), row['scenario'], Path('<scratch>')), 'native workload arguments differ')
            require('/' + label + '-' + row['layer'] + '/target/release/bin/main' in argv[0], 'native binary leg/layer mismatch')
            require(row['native_scenario'] == native_case, 'native scenario mismatch')
            text = check_log(root, command['stdout'])
            lines = [line for line in text.splitlines() if line.startswith('{"scenario":')]
            require(len(lines) == 1, 'missing unique raw native JSON')
            native = json.loads(lines[0])
            bench.validate_sample(native, native_case)
            require(all(row.get(k) == v for k,v in native.items() if k != 'scenario'), 'native stdout differs from report sample')
            require(native['scenario'] == native_case, 'wrong raw scenario')
            samples = command['process_samples']
            require(samples, 'missing native process samples')
            previous = -1
            for sample in samples:
                require(all(type(sample[k]) is int and sample[k] >= 0 for k in ('elapsed_ns','rss_kib','threads','fds')), 'invalid process sample')
                require(previous < sample['elapsed_ns'] <= command['wall_ns'], 'nonmonotonic process samples')
                previous = sample['elapsed_ns']
            for target, field in (('process_peak_rss_kib','rss_kib'), ('process_peak_fds','fds'), ('process_peak_threads','threads')):
                require(row[target] == max(s[field] for s in samples), 'process peak mismatch')
            if not row['warmup']:
                grouped.setdefault(row['scenario'], []).append(row)
        require(len(grouped) == 33, 'missing native case')
        summaries[label] = {case: bench.summarize(rows) for case, rows in grouped.items()}
    require([x[1] for x in sorted(actual)] == schedule, 'balanced alternating native command order differs')
    require(len(used) == 528, 'native process sample count differs')
    require(summaries == result['summaries'], 'recomputed summaries/noise differ')
    comparisons = {case: bench.classify(bench.freeze_reference(summaries['baseline'][case]), summaries['candidate'][case]) for _, case in expected}
    require(comparisons == result['comparisons'], 'recomputed classifier differs')
    limits = load(INPUT / 'repo/tools/gates/campaigns/m7-024-linux-performance.json')['thresholds']['tls']
    domain = perf.DomainResult('candidate-tls-baseline-ratios')
    before, after = summaries['baseline'], summaries['candidate']
    domain.check('bulk throughput ratio', after['tls_bulk']['successful_bytes_per_second'] / before['tls_bulk']['successful_bytes_per_second'], 'ge', limits['minimum_bulk_throughput_ratio'])
    for percentile in ('p50','p95'):
        domain.check('full handshake ' + percentile, after['tls_full'][percentile + '_ns'] / before['tls_full'][percentile + '_ns'], 'le', limits['maximum_full_handshake_' + percentile + '_ratio'])
    require(domain.report() == result['m7_024_tls_thresholds'], 'recomputed TLS ratios or thresholds differ')
    statuses = {x['status'] for x in comparisons.values()}
    status = 'FAIL' if 'FAIL' in statuses or domain.report()['decision'] == 'FAIL' else 'NOISY' if 'NOISY' in statuses else 'INCONCLUSIVE' if 'INCONCLUSIVE' in statuses else 'PASS'
    require(status == result['status'], 'recomputed campaign decision differs')
    require(result['formal_m7_024']['status'] == 'NOT_RUN', 'formal campaign qualification strengthened')
    return {'native_commands': len(used), 'cases': 33, 'measured_rounds_per_leg': 7, 'warmups_per_case_per_leg': 1, 'performance_status': status, 'tls': domain.report(), 'classifiers': comparisons, 'summaries': summaries}

def verify_bindings(report, inputs, oracle, payloads, manifests, root):
    require(report['qualification'] == 'NOT_QUALIFIED' and report['scope'] == inputs['scope'], 'qualification or scope strengthened')
    require(report['formal_m7_024'] == 'NOT_RUN' and report['formal_soak_86400'] == 'NOT_RUN', 'formal gates strengthened')
    before, after = report['input_bindings_before'], report['input_bindings_after']
    require(before == after and report['bindings_unchanged'], 'producer/input binding drift')
    for actual in (before, after):
        require(actual['source_inputs'] == inputs['source_inputs'], 'source binding differs')
        require(actual['artifacts'] == inputs['artifacts'], 'archive binding differs')
        require_sdk(actual['sdk_files'], oracle)
        for label in ('baseline','candidate'):
            item = actual['installations'][label]
            require(item['manifest'] == manifests[label] and item['payload'] == payloads[label], 'installed archive manifest/payload differs')
            require(item['source_build_script_absent'] is True, 'installed source build script present')
    binaries = report['performance']['binary_bindings']
    require(report['binary_bindings_after'] == binaries and set(binaries) == {'baseline','candidate'}, 'compiled consumer binary binding drift')
    for label in binaries:
        require(set(binaries[label]) == set(bench.CASES), 'missing compiled binary binding')
        for digest in binaries[label].values():
            require(digest['domain'] == 'artifact-bytes-v1', 'binary digest domain differs')
    controls = report['environment_controls']
    require(controls['host_before'] == controls['host_after'] and report['host_original_unchanged'], 'host system/SDK modified')
    require_sdk(controls['host_before']['sdk_files'], oracle)
    provenance = load(INPUT / 'glibc244/provenance.json')
    for phase in ('before','after'):
        item = controls[phase]
        require(item['affinity'] == list(range(8)) and item['physical_cores'] == 8 and item['numa_node'] == 0, 'affinity differs from selected cores')
        require(item['exclusive_cpu_claim'] is False and item['glibc_version'] == '2.44' and item['user_namespace_uid'] == 0, 'namespace limits not disclosed')
        require(item['context'] and item['clock'], 'private libc/clock disclosure missing')
        closure = item['glibc_readonly_closure']
        require(set(closure) == set(provenance['files']) and len(closure) == 14, 'glibc closure incomplete')
        for name, target in closure.items():
            require(target['read_only'] is True and 'ro' in target['mountinfo'].split()[5].split(','), 'glibc mount is not readonly')
            require(target['digest']['domain'] == 'artifact-bytes-v1' and target['digest']['sha256'] == provenance['files'][name]['sha256'], 'glibc digest differs')
        require(item['controller_loaded_glibc'], 'fresh controller loaded libc proof missing')
    source = INPUT / 'repo/tools/m12_004_candidate_gates.py'
    node = next(n for n in ast.parse(source.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == 'performance_gate')
    frozen = root / 'performance_gate.frozen.py'
    require(ast.dump(ast.parse(frozen.read_text()).body[0], include_attributes=False) == ast.dump(node, include_attributes=False), 'performance_gate AST modified')
    proof = report['performance_source_proof']
    import hashlib
    require(proof['file'] == d.text_evidence_digest(source).to_json() and proof['extracted_function'] == d.text_evidence_digest(frozen).to_json(), 'performance source digest differs')
    # Server Python3.10 always dumps empty fields; Python3.13+ defaults to omitting them.
    try:
        server_dump = ast.dump(node, include_attributes=False, show_empty=True).replace(', type_params=[]', '')
    except TypeError:
        server_dump = ast.dump(node, include_attributes=False).replace(', type_params=[]', '')
    require(proof['ast_sha256'] == hashlib.sha256(server_dump.encode()).hexdigest() and proof['measurement_logic_modified'] is False, 'performance AST proof differs')
    reviewed = load(BASE / 'checker/adapter-review.json')['reviewed_private_adapter']
    require(all(report['capture_adapters'][name] == digest for name,digest in reviewed.items()), 'reviewed capture adapter identity differs')
    for name,digest in report['capture_adapters'].items():
        require(d.text_evidence_digest(BASE / 'capture-driver' / name).to_json() == digest, 'auxiliary source adapter binding differs')
    require(report['ephemeral_fixture_private_keys_removed'] is True, 'ephemeral fixture private keys retained')
    native = report['native_runtime_observation']
    require(native['affinity'] == list(range(8)) and set(native['closure']) == set(provenance['files']), 'live native closure or affinity differs')
    for name,item in native['closure'].items():
        require(item['read_only'] is True and 'ro' in item['mountinfo'].split()[5].split(',') and item['digest'] == {'domain':'artifact-bytes-v1','sha256':provenance['files'][name]['sha256']}, 'live native readonly glibc binding differs')
    require(native['closure']['libc.so.6']['loaded'] is True and native['closure']['ld-linux-x86-64.so.2']['loaded'] is True, 'native loader/libc not observed loaded')
    require(native['runtime_environment']['CANGJIE_HOME'] == '<sdk>', 'native selected SDK root differs')
    builds = [c for c in report['commands'] if c['id'].endswith('-build')]
    require(len(builds) == 6 and all('CHECKOUT_MASK=PASS' in check_log(root,c['stdout']) for c in builds), 'readonly checkout mask proof missing')
    require(report['capture_attempts'][0] == {'kind':'paired_native_campaign','attempt':1,'retry':False,'samples_expected':528}, 'measurement campaign retried')
    launch = load(root / 'launch.json')
    require(report['status'] == report['performance']['status'], 'top-level campaign decision differs')
    expected_exit = 1 if report['status'] in ('FAIL','ERROR') else 0
    require(launch['exit_code'] == expected_exit and launch['host_original_unchanged'] is True and launch['sdk_392_before_exec_pass'] is True, 'launch exit disagrees with decision or prerequisite SDK binding absent')
    return {'bindings': 'PASS', 'sdk_files_checked': 392, 'archive_manifest_payloads': 'PASS', 'consumer_binaries_before_after': 'PASS', 'performance_gate_source_ast': 'UNCHANGED', 'namespace_limits': 'PRIVATE_GLIBC244_UNPRIVILEGED_HOST_UID_NONEXCLUSIVE_8CORE_NUMA0', 'adapter_review':'cjpm only child mount checkout masking; frozen measurement function; fresh exec after readonly14 libc files; no production modification'}

def verify_logs(report, root):
    commands = report['commands']
    require(len({c['id'] for c in commands}) == len(commands), 'duplicate command identity')
    for command in commands:
        for stream in ('stdout','stderr'):
            check_log(root, command[stream])
    native_commands = [c for c in commands if c['argv'][0].endswith('/target/release/bin/main')]
    order = [(layer,case) for layer,cases in bench.CASES.items() for case in cases]
    schedule = [(label,layer,case,n) for n in range(-1,7) for layer,case in (order if n%2 == 0 else reversed(order)) for label in (('baseline','candidate') if n%2 == 0 else ('candidate','baseline'))]
    require(len(native_commands) == len(schedule) == 528, 'missing native attempted command')
    failed = []
    rows = {r['command_id']:r for leg in report['performance']['samples'].values() for r in leg}
    for command, (label,layer,case,n) in zip(native_commands,schedule):
        argv = command['argv']
        require('/'+label+'-'+layer+'/target/release/bin/main' in argv[0], 'native attempted leg order differs')
        require(argv == bench.workload_arguments(Path(argv[0]),case,Path('<scratch>')), 'native attempted workload differs')
        require(command['id'].endswith(case+('-warmup-' if n<0 else '-round-')+str(max(0,n))), 'native attempted round order differs')
        native_case = 'http_observed' if case == 'http_unobserved' else case
        validation_error = None
        try:
            raw = [json.loads(line) for line in check_log(root,command['stdout']).splitlines() if line.startswith('{"scenario":')]
            require(len(raw) == 1, 'successful command missing unique raw JSON')
            bench.validate_sample(raw[0],native_case)
        except (ValueError, KeyError) as error:
            validation_error = str(error)
        if command['exit_code'] != 0 or command['timed_out'] or validation_error is not None:
            failed.append((label,case,n))
            require(command['id'] not in rows, 'failed native command reported successful sample')
        else:
            require(command['id'] in rows, 'successful command missing native sample')
            row = rows[command['id']]
            require(all(row.get(k) == v for k,v in raw[0].items() if k!='scenario') and row['native_scenario'] == native_case, 'native raw/sample metadata differ')
            require((row['layer'],row['scenario'],row['warmup'],row['round']) == (layer,case,n<0,max(0,n)), 'native sample identity differs')
        ps = command['process_samples']
        require((ps or command['id'] not in rows) and all(all(type(s[k]) is int and s[k] >= 0 for k in ('elapsed_ns','rss_kib','threads','fds')) for s in ps), 'missing or invalid process samples')
        require(all(a['elapsed_ns'] < b['elapsed_ns'] for a,b in zip(ps,ps[1:])) and (not ps or ps[-1]['elapsed_ns'] <= command['wall_ns']), 'process samples not monotonic')
        if command['id'] in rows:
            for target, field in (('process_peak_rss_kib','rss_kib'), ('process_peak_fds','fds'), ('process_peak_threads','threads')):
                require(rows[command['id']][target] == max(s[field] for s in ps), 'process sample peak mismatch')
    failures = [(f['artifact'],f['case'],f['round']) for f in report['performance'].get('failures',[])]
    require(failed == failures, 'raw native failures differ from report failures')
    return {'status':'PASS', 'commands':len(commands), 'log_files':len(commands)*2, 'native_attempts':528, 'successful_native_samples':len(rows), 'balanced_order':'PASS', 'failed_commands':[{'id':c['id'], 'exit_code':c['exit_code'], 'timed_out':c['timed_out']} for c in commands if c['exit_code'] != 0 or c['timed_out']]}


def main():
    import supplement, prerequisite
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = {'schema_version':1, 'scope':'SERVER_REPAIRED_SOURCE_PAIRED_PERFORMANCE_FOLLOWUP_ONLY', 'release_qualification':'NOT_QUALIFIED', 'formal_m7_024':'NOT_RUN', 'formal_soak_86400':'NOT_RUN'}
    errors = {}
    performance_status = None
    try:
        inputs, oracle, payloads, manifests = static()
        result['static_input_validation'] = supplement.static_extra(inputs,oracle,payloads,manifests)
        if args.report:
            report = load(args.report)
            root = args.report.parent
            for name, action in (('raw_log_integrity',lambda:verify_logs(report,root)), ('binding_integrity',lambda:verify_bindings(report,inputs,oracle,payloads,manifests,root)), ('extended_integrity',lambda:supplement.integrity_extra(report,root)), ('bootstrap_prerequisite_verification',lambda:prerequisite.verify(report,root)), ('main_postflight_receipt',supplement.postflight_receipt)):
                try:
                    result[name] = action()
                except Exception as error:
                    result[name] = {'status':'FAIL','error':str(error)}
                    errors[name] = str(error)
            if not errors:
                result['full_campaign_reconstruction'] = (supplement.failed_reconstruction(report,root) if report['performance'].get('failures') else verify_samples(report,root))
                performance_status = result['full_campaign_reconstruction']['performance_status']
            result['report_digest'] = d.text_evidence_digest(args.report).to_json()
        result['technical_verification_status'] = 'FAIL' if errors else 'PASS'
        result['performance_status'] = performance_status if performance_status else 'NOT_VERIFIED'
        result['verification_status'] = result['technical_verification_status']
        code = 1 if errors or performance_status == 'FAIL' else 0
    except Exception as error:
        result['technical_verification_status'] = result['verification_status'] = 'FAIL'
        result['error'] = str(error).replace(str(BASE), '<task>')
        code = 1
    result['errors'] = errors
    result['exit_code'] = code
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, sort_keys=True))
    return code

if __name__ == '__main__':
    sys.exit(main())
