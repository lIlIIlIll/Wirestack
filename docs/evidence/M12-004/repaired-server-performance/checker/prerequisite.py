"""Independent verification of retained pre-driver failure and authorized recovery."""
import check as c

def verify(report,root):
    wrapper=report['bootstrap_prerequisite_failure']
    directory=c.BASE/'bootstrap-failure'
    prior=c.load(directory/'report.json')
    c.require(wrapper['report']==prior, 'bootstrap prerequisite report altered or omitted')
    actual={p.name:c.d.artifact_byte_digest(p).to_json() for p in directory.iterdir() if p.is_file()}
    c.require(wrapper['artifacts']==actual, 'bootstrap prerequisite raw artifact binding differs')
    launch=c.load(directory/'launch.json')
    controller=c.load(directory/'controller.json')
    c.require(type(launch['exit_code']) is int and launch['exit_code']!=0, 'bootstrap failure exit hidden')
    c.require(prior['status']=='ERROR' and prior['failure_phase']=='PREEXEC_ISOLATION','pre-driver failure mislabeled')
    c.require(prior['commands']==[] and all(value==0 for value in prior['sampling_counts'].values()), 'bootstrap failure contained SDK/native execution')
    c.require(prior['capture_attempts']==[{'kind':'namespace_bootstrap','attempt':1,'retry':False,'exit_code':launch['exit_code'],'native_attempts':0}], 'bootstrap prerequisite attempt hidden or strengthened')
    c.require(controller==prior['capture_controller'] and controller['launcher_exit_code']==launch['exit_code'], 'bootstrap actual controller outcome differs')
    c.require(controller['native_observer_exit_code']!=0 and controller['remaining_own_native_sdk_processes']==[] and controller['own_process_cleanup_count']==0, 'bootstrap failed observer outcome or cleanup hidden')
    c.require(controller['ended_monotonic_ns']-controller['started_monotonic_ns']==controller['elapsed_ns'] and controller['elapsed_ns']>0, 'bootstrap monotonic record invalid')
    c.require(controller['ended_monotonic_ns']<report['capture_controller']['started_monotonic_ns'], 'native campaign started before bootstrap cleanup')
    c.require((directory/'launch.stderr.log').read_text() and (directory/'launch.stdout.log').read_text()=='', 'bootstrap raw failure missing')
    c.require(launch['sdk_392_before_exec_pass'] is True and launch['host_original_unchanged'] is True,'bootstrap prerequisites or host preservation failed')
    controls=prior['environment_controls']
    c.require(controls['host_before']==controls['host_after']==report['environment_controls']['host_before'],'bootstrap/native host or SDK changed')
    oracle=c.load(c.INPUT/'sdk-oracle.json')
    c.require_sdk(controls['host_before']['sdk_files'],oracle)
    inputs=c.load(c.INPUT/'inputs.json')
    c.require(prior['input_bindings_after']['source_inputs']==inputs['source_inputs'] and prior['input_bindings_after']['artifacts']==inputs['artifacts'],'bootstrap source/archive bytes changed')
    recovery=report['bootstrap_recovery']
    c.require(recovery['native_campaign_repeated'] is False, 'metadata restoration repeated native campaign')
    expected={name:mode & ~0o077 for name,mode in inputs['prerequisite_environment_metadata']['glibc_file_modes'].items()}
    c.require(int(recovery['loader_mode_after'],8)==expected['ld-linux-x86-64.so.2'] and expected['ld-linux-x86-64.so.2'] & 0o100, 'recovered private loader mode differs')
    receipt=report['glibc_mode_after_receipt']
    c.require(receipt==c.load(root/'mode-after.json') and receipt['declared_bundle_modes']==inputs['prerequisite_environment_metadata']['glibc_file_modes'] and receipt['extraction_umask']=='077', 'glibc mode receipt differs')
    modes=receipt['actual_server_modes']
    # Report modes may be octal strings or integer stat permission bits.
    actual_modes={name:int(mode,8) if isinstance(mode,str) else mode for name,mode in modes.items()}
    c.require(actual_modes==expected, 'effective private glibc modes differ from declared metadata with umask077')
    return {'technical_verification':'PASS','first_exec_viability':'FAIL','failure_phase':'PREEXEC_ISOLATION','launcher_exit_code':launch['exit_code'],'native_observer_exit_code':controller['native_observer_exit_code'],'sdk_byte_binding':'PASS_FULL392','sdk_native_executions_in_prerequisite':0,'recovery_authorization':'MAIN_AUTHORIZED_METADATA_ONLY_RECOVERY','bundle_declared_modes':inputs['prerequisite_environment_metadata']['glibc_file_modes'],'private_effective_modes':actual_modes,'private_extraction_umask':'077','recovered_loader_owner_execute':True,'native_campaigns_authorized':1,'report_digest':c.d.text_evidence_digest(directory/'report.json').to_json(),'launch_stderr_digest':c.d.text_evidence_digest(directory/'launch.stderr.log').to_json()}
