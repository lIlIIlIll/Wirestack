"""Private independent checks; no compiler, benchmark, or native execution."""
import tarfile
from pathlib import Path
import check as c

PREVIOUS = c.BASE.parent/'server-performance'

def static_extra(inputs, oracle, payloads, manifests):
    c.require(inputs == c.load(c.BASE/'input-manifest.json'), 'prepared input manifest differs')
    c.require(len(inputs['source_inputs']) == 10, 'same-source binding count differs')
    old = c.load(PREVIOUS/'input/inputs.json')
    changes = [n for n in inputs['source_inputs'] if inputs['source_inputs'][n] != old['source_inputs'][n]]
    c.require(changes == ['examples/linux/m12_001/http.cj'], 'more than one HTTP consumer source changed')
    c.require(inputs['source_changes'] == {changes[0]:{'before':old['source_inputs'][changes[0]],'after':inputs['source_inputs'][changes[0]]}}, 'HTTP source delta binding differs')
    c.require(inputs['artifacts'] == old['artifacts'] and inputs['sdk_oracle'] == old['sdk_oracle'], 'archives or external SDK qualification changed')
    closure = c.load(c.INPUT/'glibc244/provenance.json')['files']
    c.require(len(closure) == 14, 'glibc provenance count differs')
    for name,item in closure.items():
        c.require(c.d.artifact_byte_digest(c.INPUT/'glibc244'/name).sha256 == item['sha256'], 'glibc input binding differs')
    modes=inputs['prerequisite_environment_metadata']['glibc_file_modes']
    c.require(set(modes)==set(closure), 'glibc mode metadata incomplete')
    c.require({name:(c.INPUT/'glibc244'/name).stat().st_mode & 0o777 for name in closure}==modes, 'frozen glibc stat modes differ from manifest')
    c.require(modes['ld-linux-x86-64.so.2'] & 0o100, 'frozen loader owner execute permission missing')
    raw = {}
    for label in ('baseline','candidate'):
        with tarfile.open(c.INPUT/(label+'.tar.gz')) as t:
            raw[label] = {m.name.split('/',1)[1]:t.extractfile(m).read() for m in t.getmembers() if m.isfile() and m.name.endswith('.cj')}
    c.require(len(raw['baseline']) == 164 and raw['baseline'] == raw['candidate'], '164 production Cangjie files differ')
    c.require({n:c.d.artifact_byte_digest_bytes(b).to_json() for n,b in raw['baseline'].items()} == oracle['production_sources'], 'production source bytes differ from qualified oracle')
    c.require(manifests['baseline']['httpFiles'] == manifests['candidate']['httpFiles'], 'HTTP native ABI manifest differs')
    return {'status':'PASS','same_source_files':10,'production_cangjie_identical_bytes':164,'source_changes':changes,'thresholds_and_measurement':'UNCHANGED','sdk_oracle_files':392,'glibc_input_files':14,'archive_payloads':'PASS','http_native_abi_manifest':'IDENTICAL','glibc_modes':modes,'loader_executable_metadata':'PASS'}

def failed_reconstruction(report,root):
    # Called only after all raw attempts and sample accounting pass verify_logs.
    result = report['performance']
    summaries = {}
    classifiers = {}
    missing = {}
    for label in ('baseline','candidate'):
        grouped = {}
        for row in result['samples'][label]:
            if not row['warmup']:
                grouped.setdefault(row['scenario'],[]).append(row)
        summaries[label] = {}
        for layer,cases in c.bench.CASES.items():
            for case in cases:
                rows = grouped.get(case,[])
                if len(rows) == 7:
                    summaries[label][case] = c.bench.summarize(rows)
                else:
                    missing.setdefault(case,{})[label] = {'healthy_measured_rounds':len(rows),'required':7}
    for cases in c.bench.CASES.values():
        for case in cases:
            classifiers[case] = ({'status':'FAIL','reason':'native campaign has missing/failed rounds','rounds':missing[case]} if case in missing else c.bench.classify(c.bench.freeze_reference(summaries['baseline'][case]),summaries['candidate'][case]))
    limits = c.load(c.INPUT/'repo/tools/gates/campaigns/m7-024-linux-performance.json')['thresholds']['tls']
    if all(case in summaries[label] for label in summaries for case in ('tls_bulk','tls_full')):
        domain = c.perf.DomainResult('candidate-tls-baseline-ratios')
        b,a = summaries['baseline'],summaries['candidate']
        domain.check('bulk throughput ratio',a['tls_bulk']['successful_bytes_per_second']/b['tls_bulk']['successful_bytes_per_second'],'ge',limits['minimum_bulk_throughput_ratio'])
        for p in ('p50','p95'):
            domain.check('full handshake '+p,a['tls_full'][p+'_ns']/b['tls_full'][p+'_ns'],'le',limits['maximum_full_handshake_'+p+'_ratio'])
        tls = domain.report()
    else:
        tls = {'decision':'UNAVAILABLE','reason':'seven healthy TLS rounds unavailable'}
    c.require(result['status'] == 'FAIL', 'failed campaign strengthened')
    c.require(not result['summaries'] and not result['comparisons'], 'failed campaign reported full measured classifier results')
    return {'technical_verification':'PASS','performance_status':'FAIL','scope':'FULL33_FAILURE_ACCOUNTING_WITH_HEALTHY_CASE_DIAGNOSTICS_NOT_PASS','classifiers':classifiers,'summaries':summaries,'tls':tls,'failed_samples':result['failures'],'missing_healthy_rounds':missing}

def integrity_extra(report,root):
    commands = report['commands']
    for command in commands:
        c.require(type(command['wall_ns']) is int and command['wall_ns'] > 0, 'invalid command monotonic duration')
        c.require(type(command['exit_code']) is int and type(command['timed_out']) is bool,'invalid command outcome')
    rows = [r for leg in report['performance']['samples'].values() for r in leg]
    c.require(len({r['command_id'] for r in rows}) == len(rows), 'duplicate report native sample')
    for label,leg in report['performance']['samples'].items():
        for row in leg:
            cmd=next(cmd for cmd in commands if cmd['id']==row['command_id'])
            c.require('/'+label+'-'+row['layer']+'/target/release/bin/main' in cmd['argv'][0], 'report sample placed in wrong artifact leg')
    for failure in report['performance'].get('failures',[]):
        c.require(isinstance(failure.get('error'),str) and failure['error'], 'sample failure detail absent')
    observed_counts={'processes':len(rows),'warmups':sum(row['warmup'] for row in rows),'measured':sum(not row['warmup'] for row in rows),'proc_observations':sum(len(cmd['process_samples']) for cmd in commands),'commands':len(commands)}
    c.require(report['sampling_counts']==observed_counts, 'reported sampling counts differ from raw inventory')
    controls = report['environment_controls']
    old = c.load(PREVIOUS/'capture/report.json')
    c.require(controls['host_before']['system_glibc'] == old['environment_controls']['host_before']['system_glibc'], 'host glibc binding differs from preceding campaign')
    env = report['performance']['environment']
    c.require(env['kernel'] == old['performance']['environment']['kernel'] and env['platform'] == old['performance']['environment']['platform'], 'native host kernel/platform changed')
    oracle = c.load(c.INPUT/'sdk-oracle.json')
    cjpm_version_lines=[line for line in env['cjpm'].splitlines() if line.startswith('Cangjie Project Manager:')]
    c.require(env['cjc']==oracle['toolchain']['cjc'] and cjpm_version_lines==[oracle['toolchain']['cjpm']], 'selected STS toolchain version differs')
    c.require(env['compiler_digest']==oracle['sdk_files']['bin/cjc'], 'selected STS compiler digest differs')
    for name,digest in env['runtime_binaries'].items():
        c.require(digest==oracle['sdk_files']['runtime/lib/linux_x86_64_cjnative/'+name], 'selected STS runtime digest differs')
    identity_fields={'Architecture:','Vendor ID:','Model name:','CPU family:','Model:','Thread(s) per core:','Core(s) per socket:','Socket(s):','CPU(s):','On-line CPU(s) list:'}
    cpu=lambda e:{x['field']:x['data'] for x in e['cpu']['lscpu'] if x['field'] in identity_fields}
    c.require(cpu(env)==cpu(old['performance']['environment']),'native CPU identity/topology changed')
    runtime=report['native_runtime_observation']['runtime_environment']
    c.require(runtime['CANGJIE_HOME']=='<sdk>' and runtime['PATH'].split(':')[:2]==['<sdk>/bin','<sdk>/tools/bin'], 'native SDK root/path selection differs')
    c.require(runtime['LD_LIBRARY_PATH'].split(':')[:2]==['<sdk>/runtime/lib/linux_x86_64_cjnative','<sdk>/tools/lib'], 'native STS runtime library selection differs')
    c.require(report['compiled_consumers_unchanged'] is True, 'compiled consumers changed')
    loaded = controls['before']['controller_loaded_glibc']
    provenance = c.load(c.INPUT/'glibc244/provenance.json')['files']
    for phase in ('before','after'):
        loaded = controls[phase]['controller_loaded_glibc']
        for name in ('libc.so.6','ld-linux-x86-64.so.2'):
            c.require(any(Path(p).name == name and digest == {'domain':'artifact-bytes-v1','sha256':provenance[name]['sha256']} for p,digest in loaded.items()), 'fresh controller loaded libc/loader binding differs')
    attempts = report['capture_attempts']
    c.require(sum(a['kind']=='paired_native_campaign' for a in attempts)==1,'extra native campaign attempt')
    c.require(all(not a.get('retry',False) for a in attempts),'retry for green')
    c.require(set(report['capture_adapters']) == set(c.load(c.BASE/'checker/adapter-review.json')['reviewed_private_adapter']), 'unreviewed capture adapter')
    c.require(report['performance'].get('formal_m7_024',{'status':'NOT_RUN'})['status']=='NOT_RUN','nested formal status strengthened')
    controller = report['capture_controller']
    c.require(controller == c.load(root/'controller.json'), 'controller record differs')
    c.require(controller['attempt']==1 and controller['retry'] is False, 'controller retried campaign')
    start,end = controller['started_monotonic_ns'],controller['ended_monotonic_ns']
    c.require(type(start) is int and type(end) is int and end > start and controller['elapsed_ns']==end-start, 'controller monotonic elapsed differs')
    c.require(controller['launcher_exit_code']==c.load(root/'launch.json')['exit_code'], 'controller launcher outcome differs')
    for key, stem in (('native_observer_exit_code','observer'),('live_observer_exit_code','live-observer')):
        code = controller[key]
        c.require(type(code) is int, 'observer actual exit absent')
        c.require((root/(stem+'.stdout.log')).is_file() and (root/(stem+'.stderr.log')).is_file(), 'observer raw logs absent')
        c.require(code==0, 'observer failed; prerequisite evidence unavailable')
    c.require(controller['remaining_own_native_sdk_processes']==[] and controller['own_process_cleanup_count']==0 and controller['fixture_keys_removed'] is True, 'own process/key cleanup incomplete')
    native = report['native_runtime_observation']
    c.require(start <= controller['observer_start_monotonic_ns'] <= native['observer_started_monotonic_ns'] <= native['observed_monotonic_ns'] <= end, 'native observation monotonic schedule differs')
    c.require(native['mount_namespace']==controls['before']['mount_namespace'], 'native/controller mount namespace differs')
    c.require(report['input_manifest']==c.load(c.INPUT/'inputs.json'), 'report frozen input manifest differs')
    expected_exits={cmd['id']:cmd['exit_code'] for cmd in commands if cmd['argv'][0].endswith('/target/release/bin/main')}
    c.require(report['native_command_exits']==expected_exits, 'native exit inventory differs')
    c.require(report['readonly_checkout_mask_count']==6,'six readonly masks not observed')
    return {'status':'PASS','host_glibc_unchanged_from_prior':True,'controller_fresh_loaded_libc_loader':'PASS','compiled_consumers_unchanged':True,'no_retry_no_discard':'PASS'}

def postflight_receipt():
    path=c.BASE/'postflight.json'
    receipt=c.load(path)
    c.require(receipt['status']=='PASS' and receipt['scope']=='ORIGINAL_AND_NEW_CAMPAIGN_INPUT_PRESERVATION_ONLY', 'parent postflight receipt not PASS/scoped')
    for field in ('sdk392_unchanged','host_original_glibc14_unchanged','old_and_new_archives_unchanged','old_and_new10_source_inputs_unchanged'):
        c.require(receipt[field] is True, 'parent postflight preservation failed: '+field)
    original=c.load(PREVIOUS/'capture/report.json')
    c.require(receipt['all_six_original_binaries_unchanged']==original['performance']['binary_bindings'], 'parent original binary receipt differs from historical bound bytes')
    c.require(receipt['host_glibc']=='2.35' and receipt['owned_live_processes']==[] and receipt['fixture_private_keys_remaining']==[], 'parent host/cleanup receipt differs')
    return {'status':'PASS','provenance':'MAIN_EXECUTED_POSTFLIGHT_RECEIPT_NOT_CHECKER_NATIVE_RUN','receipt':receipt,'digest':c.d.text_evidence_digest(path).to_json()}
