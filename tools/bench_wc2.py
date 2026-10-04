#!/usr/bin/env python3
"""Reproducible #488 leaf-compiler comparison; Python standard library only.

Build with ./wbuild wc2 first. This is an opt-in measurement, not a timing
assertion in the test suite. Generated programs stay in wc2's supported subset.
"""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def distribution(samples):
    return {
        "median_ms": round(statistics.median(samples), 3),
        "min_ms": round(min(samples), 3),
        "max_ms": round(max(samples), 3),
    }


def measured(call, repeats):
    samples = []
    for _ in range(repeats):
        start = time.perf_counter_ns()
        call()
        samples.append((time.perf_counter_ns() - start) / 1_000_000)
    return distribution(samples)


def compile_once(compiler, source, output):
    subprocess.run(
        [str(ROOT / "bin" / compiler), str(source), "-o", str(output)],
        cwd=ROOT, check=True, capture_output=True, timeout=60,
    )


class Resident:
    def __init__(self):
        self.process = subprocess.Popen(
            [str(ROOT / "bin/wc2"), "serve"], cwd=ROOT,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )

    def request(self, method, source=None, output=None):
        request = {"method": method}
        if source is not None:
            request["file"] = str(source)
        if output is not None:
            request["output"] = str(output)
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        if not response["ok"]:
            raise RuntimeError(response)
        return response

    def memory(self):
        status = Path(f"/proc/{self.process.pid}/status").read_text()
        return {
            key: int(next(line.split()[1] for line in status.splitlines()
                          if line.startswith(key + ":")))
            for key in ("VmRSS", "VmHWM")
        }

    def close(self):
        try:
            if self.process.poll() is None:
                self.request("shutdown")
                self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()


def workload(directory, modules, functions):
    prefix = ".".join(directory.relative_to(ROOT).parts)
    common = directory / "common.w"
    common.write_text("int shared(int x): return x + 1\n")
    imports = []
    calls = []
    for module in range(modules):
        name = f"part_{module}"
        text = f"import {prefix}.common\n"
        for number in range(functions):
            text += (
                f"int f_{module}_{number}(int x):\n"
                "\tint total = shared(x)\n\tint j = 0\n"
                "\twhile j < 3:\n\t\ttotal += j\n\t\tj += 1\n"
                f"\tif total > 0: return total + {number}\n\treturn 0\n"
            )
        (directory / (name + ".w")).write_text(text)
        imports.append(f"import {prefix}.{name}\n")
        calls.append(f"f_{module}_{functions - 1}(20)")
    source = directory / "main.w"
    expected = modules * (24 + functions - 1)
    source.write_text("".join(imports) + "int main(): return (" +
                      " + ".join(calls) + f") != {expected}\n")
    return source, common


def benchmark(modules, functions, repeats):
    with tempfile.TemporaryDirectory(prefix="wc2_bench_", dir=ROOT / "bin") as temp:
        directory = Path(temp)
        source, common = workload(directory, modules, functions)
        output = directory / "output"
        reference = directory / "reference"
        resident = Resident()
        try:
            files = list(directory.glob("*.w"))
            result = {
                "modules": len(files),
                "functions_per_part": functions,
                "source_bytes": sum(p.stat().st_size for p in files),
                "source_lines": sum(len(p.read_text().splitlines()) for p in files),
                "repeats": repeats,
            }
            result["wv2_cold_process"] = measured(
                lambda: compile_once("wv2", source, reference), repeats)
            result["wc2_cold_process"] = measured(
                lambda: compile_once("wc2", source, output), repeats)
            assert subprocess.run([str(reference)], check=False).returncode == 0
            assert subprocess.run([str(output)], check=False).returncode == 0
            expected_image = output.read_bytes()
            result["wv2_image_bytes"] = reference.stat().st_size
            result["wc2_image_bytes"] = len(expected_image)
            cold = []
            for _ in range(repeats):
                resident.request("clear")
                start = time.perf_counter_ns()
                resident.request("build", source, output)
                cold.append((time.perf_counter_ns() - start) / 1_000_000)
            result["resident_cold_build"] = distribution(cold)
            assert output.read_bytes() == expected_image
            before = resident.request("stats")["stats"]
            for method in ("check", "symbols", "deps", "build"):
                result["resident_warm_" + method] = measured(
                    lambda m=method: resident.request(m, source, output), repeats)
            after = resident.request("stats")["stats"]
            result["warm_work"] = {
                name: after[name] - before[name]
                for name in ("reads", "parses", "analyses", "emissions")
            }
            assert result["warm_work"]["parses"] == 0
            assert result["warm_work"]["analyses"] == 0
            assert result["warm_work"]["emissions"] == 0
            changed = []
            for index in range(repeats):
                value = 2 if index % 2 == 0 else 1
                common.write_text(f"int shared(int x): return x + {value}\n")
                before = resident.request("stats")["stats"]
                start = time.perf_counter_ns()
                response = resident.request("build", source, output)
                changed.append((time.perf_counter_ns() - start) / 1_000_000)
                assert response["stats"]["parses"] - before["parses"] == 1
                assert response["stats"]["analyses"] - before["analyses"] == 1
                assert subprocess.run([str(output)], check=False).returncode == (value != 1)
            result["resident_changed_leaf_build"] = distribution(changed)
            result["resident_memory_kib"] = resident.memory()
            result["retained"] = resident.request("stats")["stats"]
            return result
        finally:
            resident.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=7)
    args = parser.parse_args()
    if args.repeats < 2:
        parser.error("--repeats must be at least 2")
    report = {
        "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "cpu": next((line.split(":", 1)[1].strip() for line in
                     Path("/proc/cpuinfo").read_text().splitlines()
                     if line.startswith("model name")), "unknown"),
        "compiler_sha256": {
            name: hashlib.sha256((ROOT / "bin" / name).read_bytes()).hexdigest()
            for name in ("wc2", "wv2")
        },
        "note": "Wall time, warm OS filesystem cache, process startup included only in cold_process;"
                " wv2 also compiles its implicit runtime. Resident memory is process RSS, not AST-only.",
        "workloads": [benchmark(1, 2, args.repeats), benchmark(4, 25, args.repeats)],
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
