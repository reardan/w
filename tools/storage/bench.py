"""Repeatable native LSM baseline; no thresholds or unmeasured optimization.
Run: ./wbuild storage_probe && python3 tools/storage/bench.py --count 1000
The JSON distinguishes OS-cache eviction requests from guaranteed cold media.
"""
import argparse
import concurrent.futures
import json
import math
import os
import pathlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", default="bin/storage_probe")
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--durability", choices=["each", "end"], default="each")
parser.add_argument("--output", type=pathlib.Path)
args = parser.parse_args()
assert 1 <= args.count <= 100000
binary = str(pathlib.Path(args.binary).resolve())

def size(prefix):
    return sum(p.stat().st_size for p in prefix.parent.glob(prefix.name + ".*"))

def run(mode, prefix, label=None):
    before = size(prefix)
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
        begin = time.monotonic_ns()
        process = subprocess.Popen([binary, mode, str(prefix), str(args.count),
                                    str(int(args.durability == "each"))], stdout=output, stderr=error)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = (time.monotonic_ns() - begin) / 1e9
        error.seek(0)
        assert process.returncode == 0, error.read().decode()
        output.seek(0)
        samples, counters = [], {}
        for line in output.read().decode().splitlines():
            name, value = line.split()
            if name == "latency_us": samples.append(int(value))
            else: counters[name] = int(value)
    samples.sort()
    percentile = lambda p: samples[max(0, math.ceil(len(samples) * p) - 1)] if samples else None
    after = size(prefix)
    logical = args.count * 32 if mode == "write" else None
    return dict(phase=label or mode, operations=len(samples), elapsed_s=elapsed,
                throughput_ops_s=len(samples) / elapsed, latency_p50_us=percentile(.5),
                latency_p95_us=percentile(.95), latency_p99_us=percentile(.99),
                peak_rss_kib=usage.ru_maxrss, user_cpu_s=usage.ru_utime,
                system_cpu_s=usage.ru_stime, voluntary_switches=usage.ru_nvcsw,
                involuntary_switches=usage.ru_nivcsw, disk_bytes=after,
                disk_growth_bytes=after - before,
                write_amplification=(counters.get("write_bytes", 0) / logical if logical else None),
                **counters)

with tempfile.TemporaryDirectory(prefix="w-storage-bench-") as directory:
    prefix = pathlib.Path(directory) / "store"
    results = [run("write", prefix, "initial_load"), run("compact", prefix)]
    # Per-file cache eviction request, never privileged global drop_caches.
    evicted = hasattr(os, "posix_fadvise")
    if evicted:
        for path in prefix.parent.glob("store.*"):
            with path.open("rb") as stream:
                os.posix_fadvise(stream.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
    results += [run("read", prefix, "cold_requested_read"),
                run("read", prefix, "warm_read"), run("scan", prefix),
                run("checksum", prefix, "checksum_32k"), run("decode", prefix, "table_index_decode"),
                run("write", prefix, "sustained_update"), run("recover", prefix)]
    # Separate process/store owners avoid claiming that LSM itself allows
    # concurrent mutation. Two independent workloads contend on the disk.
    other = pathlib.Path(directory) / "other"
    results.append(run("write", other, "second_store_load"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run, "read", prefix, "concurrent_read"),
                   pool.submit(run, "write", other, "concurrent_update")]
        results.extend(f.result() for f in futures)
    report = dict(count=args.count, durability=args.durability,
                  cold_cache_eviction_requested=evicted,
                  notes=["Latency samples exclude stdout formatting; throughput includes process startup and reporting.",
                         "Peak RSS is per child from wait4; allocated_bytes is cumulative, not live heap.",
                         "write_amplification counts bytes passed to successful file writes, not physical device writes.",
                         "Queue bytes are zero for this synchronous driver; executor tests qualify bounded queues.",
                         "Cold means POSIX_FADV_DONTNEED requested, not guaranteed cold hardware.",
                         "No page cache, buffer reuse or checksum algorithm optimization is enabled."],
                  results=results)
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output: args.output.write_text(encoded)
    print(encoded, end="")
