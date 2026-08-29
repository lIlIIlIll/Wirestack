#!/usr/bin/env python3
"""Record utilization for one benchmark CPU and its sibling."""

import csv
import pathlib
import signal
import sys
import time


cpus = [int(value) for value in sys.argv[1].split(",")]
output = pathlib.Path(sys.argv[2])
running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def read_times():
    wanted = {f"cpu{cpu}": cpu for cpu in cpus}
    result = {}
    for line in pathlib.Path("/proc/stat").read_text().splitlines():
        fields = line.split()
        if fields and fields[0] in wanted:
            values = [int(value) for value in fields[1:]]
            result[wanted[fields[0]]] = (sum(values), values[3] + values[4])
    return result


with output.open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["unix_time", "cpu", "utilization_percent"])
    before = read_times()
    while running:
        time.sleep(1)
        after = read_times()
        now = time.time()
        for cpu in cpus:
            delta_total = after[cpu][0] - before[cpu][0]
            delta_idle = after[cpu][1] - before[cpu][1]
            utilization = 100.0 if not delta_total else 100.0 * (delta_total - delta_idle) / delta_total
            writer.writerow([f"{now:.3f}", cpu, f"{utilization:.3f}"])
        stream.flush()
        before = after
