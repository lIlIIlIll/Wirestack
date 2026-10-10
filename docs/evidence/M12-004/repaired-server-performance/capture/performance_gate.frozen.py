def performance_gate(runner, installations):
    binaries = {}
    result = {'status': 'INCOMPLETE', 'samples': {}, 'summaries': {}, 'comparisons': {}}
    environment = runner.environment()
    environment['TLS'] = 'Static archive-bound AWS-LC baseline 5.5.0 versus candidate 5.11.0'
    environment['optimization'] = 'Identical installed dependency flags; -O2 consumer'
    result['environment'] = environment
    runner.certificates()
    for label, installed in installations.items():
        binaries[label] = {}
        result['samples'][label] = []
        for layer in bench.CASES:
            consumer = runner.work / (label + '-' + layer)
            (consumer / 'src').mkdir(parents=True)
            (consumer / 'cjpm.toml').write_text(release.consumer_manifest(installed).replace('wirestack_release_smoke', 'wirestack_m12_001').replace('compile-option = ""', 'compile-option = "-O2"', 1))
            for source, name in ((bench.SOURCES / 'common.cj', 'common.cj'), (bench.SOURCES / f'{layer}.cj', 'main.cj')):
                shutil.copy2(source, consumer / 'src' / name)
            runner.run(label + '-' + layer + '-build', ['cjpm', 'build'], consumer, 600)
            binaries[label][layer] = consumer / 'target/release/bin/main'
            result.setdefault('binary_bindings', {}).setdefault(label, {})[layer] = d.artifact_byte_digest(binaries[label][layer]).to_json()
    order = [(layer, case) for layer, cases in bench.CASES.items() for case in cases]
    for round_number in range(-1, 7):
        for layer, case in order if round_number % 2 == 0 else reversed(order):
            labels = ('baseline', 'candidate') if round_number % 2 == 0 else ('candidate', 'baseline')
            for label in labels:
                temp = {'samples': result['samples'][label]}
                try:
                    runner.sample(temp, binaries[label][layer], layer, case, max(0, round_number), round_number < 0)
                except Exception as error:
                    result.setdefault('failures', []).append({'artifact': label, 'case': case,
                        'round': round_number, 'error': runner.redact(str(error))})
                (runner.output / 'performance-progress.json').write_text(runner.redact(json.dumps(result, indent=2)) + '\n')
    if result.get('failures'):
        result['status'] = 'FAIL'
        return result
    for label in installations:
        grouped = defaultdict(list)
        for row in result['samples'][label]:
            if not row['warmup']:
                grouped[row['scenario']].append(row)
        result['summaries'][label] = {case: bench.summarize(rows) for case, rows in grouped.items()}
    for case in result['summaries']['baseline']:
        baseline = result['summaries']['baseline'][case]
        candidate = result['summaries']['candidate'][case]
        result['comparisons'][case] = bench.classify(bench.freeze_reference(baseline), candidate)
    limits = json.loads((ROOT / 'tools/gates/campaigns/m7-024-linux-performance.json').read_text())['thresholds']['tls']
    domain = performance.DomainResult('candidate-tls-baseline-ratios')
    before, after = result['summaries']['baseline'], result['summaries']['candidate']
    domain.check('bulk throughput ratio', after['tls_bulk']['successful_bytes_per_second'] / before['tls_bulk']['successful_bytes_per_second'], 'ge', limits['minimum_bulk_throughput_ratio'])
    for percentile in ('p50', 'p95'):
        domain.check('full handshake ' + percentile, after['tls_full'][percentile + '_ns'] / before['tls_full'][percentile + '_ns'], 'le', limits['maximum_full_handshake_' + percentile + '_ratio'])
    result['m7_024_tls_thresholds'] = domain.report()
    statuses = {x['status'] for x in result['comparisons'].values()}
    result['status'] = 'FAIL' if 'FAIL' in statuses or domain.report()['decision'] == 'FAIL' else 'NOISY' if 'NOISY' in statuses else 'INCONCLUSIVE' if 'INCONCLUSIVE' in statuses else 'PASS'
    result['formal_m7_024'] = {'status': 'NOT_RUN', 'reason': 'Historical stdx/network/memory campaigns are not relabeled as this paired installed development campaign'}
    return result
