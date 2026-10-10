import hashlib
import io
import json
from pathlib import Path
import tarfile
import sys

BASE, OLD, REPO = map(Path, sys.argv[1:4])
INPUT = OLD/'input'
def digest(raw, domain='artifact-bytes-v1'):
    if domain == 'text-utf8-lf-v1':
        raw = raw.decode().replace('\r\n','\n').replace('\r','\n').encode()
    return {'domain':domain,'sha256':hashlib.sha256(raw).hexdigest()}
old = json.loads((INPUT/'inputs.json').read_text())
new = json.loads(json.dumps(old))
new['scope'] = 'SERVER_REPAIRED_SOURCE_PAIRED_PERFORMANCE_FOLLOWUP_ONLY'
new['previous_scope'] = old['scope']
new['source_changes'] = {}
for name, expected in old['source_inputs'].items():
    raw = (REPO/name).read_bytes()
    current = digest(raw, 'text-utf8-lf-v1')
    if current != expected:
        assert name == 'examples/linux/m12_001/http.cj', name
        assert current['sha256'] == '1c6a4942dfc97ff6b7b5a765ff19501b6239e73fe4e310c91da107feb6441ba7'
        new['source_changes'][name] = {'before':expected,'after':current}
    new['source_inputs'][name] = current
assert len(new['source_changes']) == 1
assert len(new['source_inputs']) == 10
for name, expected in old['artifacts'].items():
    assert digest((INPUT/name).read_bytes()) == expected
assert digest((INPUT/'sdk-oracle.json').read_bytes(), 'text-utf8-lf-v1') == old['sdk_oracle']
new['policy'] = {'capture_attempts':1,'retry_for_green':False,'native_commands':528,'archives':2,'cases':33,'warmups_per_archive':1,'measured_rounds_per_archive':7,'source_repair':'http-round-release','sdk_scope':'STS1.1.3_ONLY','formal_m7_024':'NOT_RUN','soak86400':'NOT_RUN'}
new['prerequisite_environment_metadata'] = {'glibc_file_modes':{name:(INPUT/'glibc244'/name).stat().st_mode & 0o777 for name in json.loads((INPUT/'glibc244/provenance.json').read_text())['files']},'mode_source':'Original qualified closure input metadata, not chmod-guessed modes'}
(BASE/'input-manifest.json').write_text(json.dumps(new,indent=2)+'\n')
with tarfile.open(BASE/'inputs.tar.gz','w:gz') as archive:
    count = 0
    for path in sorted(INPUT.rglob('*')):
        if not path.is_file() or '__pycache__' in path.parts:
            continue
        relative = path.relative_to(INPUT)
        if relative == Path('inputs.json'):
            raw = (BASE/'input-manifest.json').read_bytes()
        elif relative.parts[0] == 'repo' and str(Path(*relative.parts[1:])) in new['source_inputs']:
            raw = (REPO/Path(*relative.parts[1:])).read_bytes()
        else:
            raw = path.read_bytes()
        entry = tarfile.TarInfo(str(Path('input')/relative))
        entry.mode = path.stat().st_mode & 0o777
        entry.size = len(raw)
        archive.addfile(entry, io.BytesIO(raw))
        count += 1
    path = OLD/'sdk-before.json'
    entry = tarfile.TarInfo('sdk-before.json')
    raw = path.read_bytes()
    entry.mode, entry.size = 0o600, len(raw)
    archive.addfile(entry,io.BytesIO(raw))
print(json.dumps({'status':'PASS','changed_sources':list(new['source_changes']),'source_inputs':10,'sdk_oracle_inputs':len(json.loads((INPUT/'sdk-oracle.json').read_text())['sdk_files']),'files':count+1,'bundle_sha256':digest((BASE/'inputs.tar.gz').read_bytes())['sha256']}))
