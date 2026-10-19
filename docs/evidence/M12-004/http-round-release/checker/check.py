#!/usr/bin/env python3
"""Independent repaired HTTP evidence checker. Does not execute native workloads."""
import argparse
import copy
import hashlib
import json
import math
import pathlib
import tempfile

CASES = ('h1_short_reuse','h1_new_connection','h1_bulk_4096','h1_bulk_32768','h1_concurrent','h1_early_close','h2_streams_1','h2_streams_10','h2_streams_100','h2_slow_consumer','h2_stream_cancel','http_overload','http_observed','http_unobserved')
SOURCES = {'http.cj':'1c6a4942dfc97ff6b7b5a765ff19501b6239e73fe4e310c91da107feb6441ba7','common.cj':'877b4f985d16c990c43ebfca9627d85aa94460ccfcc043c228448e0703153129'}
BAD_BINARY = 'd132fe407098689cab5115c10d520486906fbf651b25dd3306f0d8910b29add1'
ARCHIVES = {"baseline":"e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f", "candidate":"bb12abafb87ffe60b3e3adbdf4c1ac6ea7f8da47a7a5ad8a2df58b9e8981556d"}
OLD_BINARIES = {BAD_BINARY,"538e4c728db27d17db8d171a790fd8357fed0c62e3f668e87b1c835eb0992557"}

def require(ok, message):
    if not ok:
        raise ValueError(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def expected(case):
    n, rejected, size, checksum, regime = 200, 0, 1400, 149200, 'normal'
    if case.startswith('h1_bulk'):
        n, size, checksum = 1, 8388608, 8388608*97
    elif case in ('h1_concurrent','h2_streams_10'):
        n, size, checksum = 100, 700, 74600
    elif case == 'h2_streams_100':
        n, size, checksum = 1000, 7000, 746000
    elif case == 'h1_early_close':
        size, checksum, regime = 200, 19400, 'cleanup'
    elif case == 'h2_slow_consumer':
        n, size, checksum, regime = 13, 8388608+77, 8388608*97+11*746, 'slow'
    elif case == 'h2_stream_cancel':
        n, rejected, size, checksum, regime = 3, 1, 14, 1492, 'cleanup'
    elif case == 'http_overload':
        n, rejected, size, checksum, regime = 6, 2, 28, 2984, 'overload'
    return dict(operations=n, successes=n-rejected, failures=0, expected_rejections=rejected, bytes=size, checksum=checksum, regime=regime)

def sample_check(row, case, argv):
    native = 'http_observed' if case == 'http_unobserved' else case
    require(row.get('scenario') == native, 'native scenario alias mismatch')
    require(len(argv) in (4,5) and argv[1] == native, 'wrong native workload argv')
    require(argv[4:] == (['disabled'] if case == 'http_unobserved' else []), 'wrong observer argv')
    for field, value in expected(case).items():
        require(row.get(field) == value and (field == 'regime' or type(row[field]) is int), 'wrong fixed work: '+field)
    require(type(row.get('duration_ns')) is int and row['duration_ns'] > 0, 'missing duration')
    values = row.get('latencies_ns')
    require(isinstance(values,list) and len(values) == row['operations'] and all(type(v) is int and v > 0 for v in values), 'missing latency')
    metrics = row.get('metrics', {})
    require(type(metrics.get('cleanup_owners')) is int and metrics['cleanup_owners'] == 0, 'leaked terminal owner')
    require(metrics.get('observation_enabled') is (case == 'http_observed'), 'wrong observation flag')
    h2 = case.startswith('h2_')
    require(metrics.get('tls_enabled') is h2 and metrics.get('native_protocol') == (2 if h2 else 1), 'wrong native protocol')
    require(all(not isinstance(v,float) or math.isfinite(v) for v in metrics.values()), 'nonfinite metric')
    require(type(metrics.get('close_latency_ns')) is int and metrics['close_latency_ns'] > 0, 'missing close latency')
    if h2 or case in ('h1_short_reuse','http_observed','http_unobserved') or case.startswith('h1_bulk'):
        require(metrics.get('native_connections') == 1, 'connection reuse mismatch')
    if case == 'h1_new_connection':
        require(metrics.get('native_connections') == 210, 'new connection mismatch')
    if case == 'h2_stream_cancel':
        require(metrics.get('expected_cancellations') == 1 and metrics.get('cancel_latency_ns',0) > 0 and metrics.get('completed_cancellations',0) >= 1, 'missing actual cancellation')
    else:
        require(metrics.get('expected_cancellations') == 0, 'unexpected cancellation')
    if case in ('h2_slow_consumer','h2_stream_cancel'):
        require(metrics.get('flow_stall_events',0) > 0, 'missing actual flow stall')
    if case == 'h2_slow_consumer':
        require(metrics.get('slow_prefix_bytes') == 4096 and metrics.get('initial_read_latency_ns',0) > 0, 'missing partial-read evidence')
    if case == 'http_overload':
        require(metrics.get("client_rejected_capacity") == 1 and metrics.get("queue_wait_count") == 1 and metrics.get("queue_wait_ns",0) > 0 and metrics.get("queue_high_water") == 1, "missing overload rejection or wait")
    if case == 'http_observed':
        require(metrics.get('event_count',0) > 0 and metrics.get('attributed_e2e_count',0) >= 200, 'missing observer attribution')

def raw_sample(stdout):
    lines = stdout.splitlines()
    require(len(lines) == 1, 'hidden failure or duplicate sample in raw stdout')
    return json.loads(lines[0])

def artifact(root, item):
    path = (root / item["path"]).resolve()
    require(path.is_relative_to(root.resolve()), "raw artifact escapes evidence directory")
    require(path.is_file() and digest(path) == item["sha256"], "modified raw artifact")
    require(path.stat().st_size == item["size_bytes"], "raw artifact size mismatch")
    return path

def command_check(root, command):
    require(type(command.get("exit_code")) is int and command["exit_code"] == 0, "nonzero native/build exit")
    require(command.get("controller_timeout") is False, "controller timeout or missing timeout evidence")
    argv = command["argv"]
    require(not any(pathlib.Path(a).name in ("gdb", "strace") for a in argv), "debugger intervention")
    for stream in ("stdout", "stderr"):
        artifact(root, command[stream])
    return argv

def verify(report, root):
    require(report.get("source_inputs") == SOURCES and report.get("source_inputs_after") == SOURCES, "stale source inputs")
    require(set(report["archives"]) == set(ARCHIVES) and report.get("archives_after") == ARCHIVES, "wrong selected archives")
    require(report.get("cases") == list(CASES), "wrong logical case enumeration")
    require(report["cleanup"].get("owned_processes_remaining") == [] and report["cleanup"].get("keys_absent") is True, "incomplete runtime cleanup")
    seen = set()
    require(not any(pathlib.Path(a).name in ("gdb","strace") for command in report["commands"] for a in command["argv"]), "debugger intervention in campaign")
    require(sum(command["argv"][0] == build["binary"] for command in report["commands"] for build in report["builds"].values()) == 28, "wrong native execution count")
    require(set(report["results"]) == {"baseline", "candidate"}, "missing selected archive leg")
    for label in ("baseline", "candidate"):
        require(set(report["results"][label]) == set(CASES), "missing or extra logical case")
        build = report["builds"][label]
        command_check(root, build["command"])
        require(report["archives"][label]["sha256"] == ARCHIVES[label], "wrong archive binding")
        require(build["build_exit"] == 0 and build["command"]["argv"] == ["cjpm", "build"], "missing actual new build")
        require(build["binary_sha256"] not in OLD_BINARIES and isinstance(build["binary_sha256"], str) and len(build["binary_sha256"]) == 64, "old binary reuse")
        require(set(build["sources_before_after"]) == {"before","after","input_after"}, "missing source build binding")
        inputs = build["command"]["input_digests"]
        require(inputs["archive_sha256"] == ARCHIVES[label] and inputs["sources"] == SOURCES, "build input mismatch")
        manifest = root / (label+"-http") / "cjpm.toml"
        manifest_hash = digest(manifest)
        require(manifest_hash == build["consumer_manifest_sha256"] == inputs["manifest_sha256"], "manifest digest mismatch")
        require('compile-option = "-O2"' in manifest.read_text(), "missing actual optimized compile flags")
        require(digest(root / (label+"-http") / "target/release/bin/main") == build["binary_sha256"], "built binary artifact mismatch")
        require("-O2" in build["consumer_manifest"], "missing optimized build flags")
        for hashes in build["sources_before_after"].values():
            require(hashes == SOURCES, "stale source in build")
        for case, result in report["results"][label].items():
            command = result["command"]
            argv = command_check(root, command)
            require(command["label"] == label+"-"+case and command["stdout"]["path"] not in seen, "duplicate native case")
            seen.add(command["stdout"]["path"])
            require(sum(c["label"] == command["label"] for c in report["commands"]) == 1, "case not executed exactly once")
            require(argv[0] == build["binary"], "wrong executable path")
            inputs = command["input_digests"]
            require(inputs["binary_sha256"] == build["binary_sha256"] and inputs["archive_sha256"] == ARCHIVES[label] and inputs["sources"] == SOURCES, "native source/archive/binary binding mismatch")
            require(inputs["fixtures"] == report["fixture_digests"], "wrong fixture binding")
            require(command["stderr"]["size_bytes"] == 0, "hidden runtime stderr failure")
            require(command["owned_process_cleanup"]["remaining_before_cleanup"] == [] and command["owned_process_cleanup"]["remaining_after_cleanup"] == [], "native owned process leak")
            row = raw_sample(artifact(root, command["stdout"]).read_text())
            require(row == result["sample"], "report sample differs from raw stdout")
            sample_check(row, case, argv)
    return {"logical_cases":28,"labels":["baseline","candidate"],"source_hashes":SOURCES,"archives":ARCHIVES,"new_binaries":{label:report["builds"][label]["binary_sha256"] for label in ARCHIVES},"raw_stdout_sha256":{label:{case:result["command"]["stdout"]["sha256"] for case,result in report["results"][label].items()} for label in ARCHIVES}}

def negative_controls(report, root):
    import shutil
    outcomes = []
    expected_reasons = {"nonzero_exit":"nonzero native/build exit", "missing_case":"missing or extra logical case", "wrong_operations":"wrong fixed work: operations", "wrong_bytes":"wrong fixed work: bytes", "wrong_checksum":"wrong fixed work: checksum", "hidden_failure":"hidden failure", "missing_latency":"missing latency", "leaked_owner":"leaked terminal owner", "wrong_observer_argv":"wrong observer argv", "stale_source":"stale source in build", "modified_raw_stdout":"modified raw artifact"}
    names = ("nonzero_exit", "missing_case", "wrong_operations", "wrong_bytes", "wrong_checksum", "hidden_failure", "missing_latency", "leaked_owner", "wrong_observer_argv", "stale_source", "modified_raw_stdout")
    with tempfile.TemporaryDirectory(prefix="negative-", dir=pathlib.Path(__file__).parent) as temporary:
        private = pathlib.Path(temporary)
        for name in names:
            trial = copy.deepcopy(report)
            item = trial["results"]["baseline"]["http_unobserved"]
            command = item["command"]
            for original in root.iterdir():
                if original.is_dir():
                    shutil.copytree(original, private / original.name, dirs_exist_ok=True)
                elif original.is_file():
                    shutil.copyfile(original, private / original.name)
            path = private / command["stdout"]["path"]
            row = json.loads(path.read_text())
            if name == "nonzero_exit":
                command["exit_code"] = 1
            elif name == "missing_case":
                del trial["results"]["candidate"]["h1_bulk_4096"]
            elif name == "wrong_observer_argv":
                command["argv"][-1] = "enabled"
            elif name == "stale_source":
                trial["builds"]["baseline"]["sources_before_after"]["before"]["http.cj"] = "9b1ad91a850538af9a07c46571a561e2570873c8102a7d059947813f103ffb68"
            else:
                if name == "wrong_operations":
                    row["operations"] += 1
                    row["successes"] += 1
                    row["latencies_ns"].append(row["latencies_ns"][-1])
                elif name == "wrong_bytes":
                    row["bytes"] += 7
                elif name == "wrong_checksum":
                    row["checksum"] += 746
                elif name == "missing_latency":
                    row["latencies_ns"].pop()
                elif name == "leaked_owner":
                    row["metrics"]["cleanup_owners"] = 1
                text = json.dumps(row)+"\n"
                if name in ("hidden_failure", "modified_raw_stdout"):
                    text += "FAIL hidden native failure\n"
                path.write_text(text)
                if name != "modified_raw_stdout":
                    command["stdout"].update(sha256=digest(path), size_bytes=path.stat().st_size)
                    item["sample"] = row
            try:
                verify(trial, private)
            except (ValueError, KeyError, OSError, TypeError) as error:
                require(expected_reasons[name] in str(error), "negative control failed for unrelated reason: "+name)
                outcomes.append(dict(name=name, status="REJECTED", reason=str(error)))
            else:
                outcomes.append(dict(name=name, status="ACCEPTED"))
    return outcomes

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    options = parser.parse_args()
    report = json.loads(options.report.read_text())
    result = dict(task_id="M12-004", parent_status="BLOCKED", existing_full_33_campaign="FAIL", report_sha256=digest(options.report), checker_sha256=digest(pathlib.Path(__file__)))
    try:
        result["bindings"] = verify(report, options.report.parent)
        result["negative_controls"] = negative_controls(report, options.report.parent)
        result["negative_rejected"] = sum(x["status"] == "REJECTED" for x in result["negative_controls"])
        result["negative_total"] = len(result["negative_controls"])
        require(result["negative_rejected"] == result["negative_total"], "negative control accepted")
        result.update(status="PASS", exit_code=0)
    except (ValueError, KeyError, OSError, TypeError) as error:
        result.update(status="FAIL", exit_code=1, error=str(error))
    options.output.write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(dict(status=result["status"], exit_code=result["exit_code"], negative_rejected=result.get("negative_rejected",0), negative_total=result.get("negative_total",0))))
    return result["exit_code"]

if __name__ == "__main__":
    raise SystemExit(main())
