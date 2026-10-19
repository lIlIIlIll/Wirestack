import ast
from collections import defaultdict
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import traceback

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE / 'input/repo'
sys.path.insert(0, str(ROOT))
from tools import evidence_digest as d
from tools import m7_021_linux_release as release
from tools.benchmarks import m12_001_end_to_end as bench
from tools.gates import m7_024_linux_performance as performance

class Runner(bench.Campaign):
    def run(self, name, argv, cwd, timeout=90, sampled=False, check=True):
        if argv[0] == 'cjpm':
            argv = ['unshare', '--mount', '/usr/bin/python3', str(BASE / 'capture/bootstrap.py'), 'hide', *argv]
        return super().run(name, argv, cwd, timeout, sampled, check)
    def redact(self, text):
        return super().redact(text).replace(str(BASE), '<task>')

runner = Runner(BASE / 'output', BASE / 'runwork')
def save(name, value):
    (runner.output / name).write_text(runner.redact(json.dumps(value, indent=2))+'\n')
def inventory():
    expected = json.loads((BASE / 'input/inputs.json').read_text())
    sdk = Path(os.environ['CANGJIE_HOME'])
    oracle = json.loads((BASE / 'sdk-before.json').read_text())['sdk_files']
    result = {'source_inputs': {n: d.text_evidence_digest(ROOT/n).to_json() for n in expected['source_inputs']},
              'artifacts': {n: d.artifact_byte_digest(BASE/'input'/n).to_json() for n in expected['artifacts']},
              'sdk_files': {n: d.artifact_byte_digest(sdk/n).to_json() for n in oracle},
              'sdk_file_count': len(oracle), 'installations': {}}
    for label, installed in installations.items():
        result['installations'][label] = {'manifest': manifests[label], 'payload': {n: d.artifact_byte_digest(installed/n).to_json() for n in payloads[label]},
            'installed_manifest': (installed/'cjpm.toml').read_text(), 'source_build_script_absent': not (installed/'build.cj').exists()}
    assert result['source_inputs'] == expected['source_inputs']
    assert result['artifacts'] == expected['artifacts']
    assert result['sdk_files'] == oracle and len(oracle) == 392
    return result

def controls():
    targets = json.loads((runner.output/'namespace-targets.json').read_text())
    mounts = Path('/proc/self/mountinfo').read_text().splitlines()
    closure = {}
    for name, item in targets.items():
        target = item['target']
        rows = [r for r in mounts if r.split()[4] == target]
        assert rows and 'ro' in rows[-1].split()[5].split(',')
        digest = d.artifact_byte_digest(Path(target)).to_json()
        assert digest['sha256'] == item['sha256']
        closure[name] = {'resolved_target': target, 'digest': digest, 'read_only': True, 'mountinfo': rows[-1]}
    loaded = {}
    for line in Path('/proc/self/maps').read_text().splitlines():
        p = line.split()[-1]
        if p.startswith('/') and Path(p).name in targets:
            loaded[p] = d.artifact_byte_digest(Path(p)).to_json()
    libc = ctypes.CDLL(None)
    libc.gnu_get_libc_version.restype = ctypes.c_char_p
    version = libc.gnu_get_libc_version().decode()
    assert version == '2.44'
    assert set(os.sched_getaffinity(0)) == set(range(8))
    return {'host': 'example-host', 'affinity': sorted(os.sched_getaffinity(0)), 'physical_cores': 8, 'numa_node': 0,
        'exclusive_cpu_claim': False, 'load_average': os.getloadavg(),
        'governors': {str(c): (Path(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_governor').read_text().strip() if Path(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_governor').exists() else 'UNAVAILABLE') for c in range(8)},
        'frequency_khz': {str(c): (Path(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq').read_text().strip() if Path(f'/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq').exists() else 'UNAVAILABLE') for c in range(8)},
        'glibc_version': version, 'glibc_readonly_closure': closure, 'controller_loaded_glibc': loaded,
        'user_namespace_uid': os.getuid(), 'uid_map': Path('/proc/self/uid_map').read_text(), 'mount_namespace': os.readlink('/proc/self/ns/mnt'),
        'context': 'Real Server CPU/kernel; private readonly glibc2.44 closure, not stock glibc2.35 support. Unprivileged host UID mapped to namespace root. SDK envsetup sourced only after 392-file binding PASS. No host governor/sysctl changes.',
        'clock': 'Unchanged measurement monotonic_ns; no wall-clock offset asserted for this capture.'}

report = {'schema_version': 1, 'task_id': 'M12-004', 'scope': 'SERVER_REPAIRED_SOURCE_PAIRED_PERFORMANCE_FOLLOWUP_ONLY', 'qualification': 'NOT_QUALIFIED', 'commands': runner.commands, 'status': 'INCOMPLETE', 'formal_m7_024': 'NOT_RUN', 'formal_soak_86400': 'NOT_RUN'}
installations, payloads, manifests = {}, {}, {}
try:
    for label in ('baseline', 'candidate'):
        archive = BASE/'input'/f'{label}.tar.gz'
        payloads[label], manifests[label] = release.read_verified_payload(archive)
        installations[label] = release.extract_archive(archive, runner.work / ('installed-'+label))
    report['input_bindings_before'] = inventory()
    report['environment_controls'] = {'before': controls()}
    source = ROOT/'tools/m12_004_candidate_gates.py'
    tree = ast.parse(source.read_text())
    node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'performance_gate')
    extracted = ast.get_source_segment(source.read_text(), node)
    (runner.output/'performance_gate.frozen.py').write_text(extracted+'\n')
    report['performance_source_proof'] = {'file': d.text_evidence_digest(source).to_json(), 'extracted_function': d.text_evidence_digest(runner.output/'performance_gate.frozen.py').to_json(), 'ast_sha256': hashlib.sha256(ast.dump(node, include_attributes=False).encode()).hexdigest(), 'explicit_globals': ['ROOT','bench','release','performance','d','json','shutil','defaultdict'], 'measurement_logic_modified': False}
    namespace = dict(ROOT=ROOT, bench=bench, release=release, performance=performance, d=d, json=json, shutil=shutil, defaultdict=defaultdict)
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), namespace)
    report['performance'] = namespace['performance_gate'](runner, installations)
    report['status'] = report['performance']['status']
except Exception as error:
    report['status'] = 'ERROR'
    report['error'] = runner.redact(str(error))
    save('exception.json', {'traceback': traceback.format_exc()})
finally:
    try:
        report['input_bindings_after'] = inventory()
        report['bindings_unchanged'] = report.get('input_bindings_before') == report['input_bindings_after']
        report.setdefault('environment_controls', {})['after'] = controls()
    except Exception as error:
        report['bindings_unchanged'] = False
        report['integrity_error'] = str(error)
    for key in ('key.pem', 'key.pk8'):
        (runner.work/key).unlink(missing_ok=True)
    report['ephemeral_fixture_private_keys_removed'] = True
    save('report.json', report)
sys.exit(1 if report['status'] in ('ERROR', 'FAIL') else 0)
