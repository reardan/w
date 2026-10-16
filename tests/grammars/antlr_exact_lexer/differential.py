#!/usr/bin/env python3
"""Optional bounded endpoint conformance test; ordinary W tests are offline."""
import argparse
import hashlib
import itertools
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
JAR_SHA256 = 'eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76'

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, timeout=60, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--antlr-jar', type=pathlib.Path, required=True)
    parser.add_argument('--java-home', type=pathlib.Path, required=True)
    args = parser.parse_args()
    jar = args.antlr_jar.resolve()
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JAR_SHA256:
        raise SystemExit('ANTLR jar hash mismatch')
    java = args.java_home.resolve() / 'bin/java'
    javac = args.java_home.resolve() / 'bin/javac'
    version = run([java, '-version'], capture_output=True, text=True).stderr
    if 'version "17.' not in version:
        raise SystemExit('reference requires Java 17')
    fixture = pathlib.Path(__file__).resolve().parent
    work = ROOT / 'bin/exact_endpoint_oracle'
    work.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    run(['bin/antlr_to_pg', '--strict', '--exact-lexer', fixture / 'Exact.g4', '-o', 'bin/at_exact.pg', '--parser-name', 'at_exact', '--matchers', 'bin/at_exact_matchers.w'])
    run(['bin/wv2', '--strict', fixture / 'endpoint_probe.w', '-o', work / 'probe'])
    run([java, '-jar', jar, '-Xexact-output-dir', '-o', work, fixture / 'Exact.g4'])
    run([javac, '-cp', jar, '-d', work, work / 'ExactLexer.java', fixture / 'OracleProbe.java'])
    cases = []
    for rule, alphabet in [('WORD', 'abx'), ('NG_SUFFIX', 'sab'), ('ORDERED', 'nab'), ('MIXED', 'mab'), ('NESTED', '[]a'), ('NG_OPTIONAL', 'ua'), ('NG_PLUS', 'pa'), ('FRAGMENT', 'fabx')]:
        bound = 5 if len(alphabet) == 4 else 6
        for length in range(bound + 1):
            cases.extend((rule, ''.join(chars)) for chars in itertools.product(alphabet, repeat=length))
    cases.extend(('REPEAT', 'a' * length) for length in range(20))
    failures = []
    for begin in range(0, len(cases), 300):
        chunk = cases[begin:begin + 300]
        arguments = [value for pair in chunk for value in pair]
        actual = run([work / 'probe', *arguments], capture_output=True, text=True).stdout.splitlines()
        expected = run([java, '-cp', str(work) + ':' + str(jar), 'OracleProbe', 'ExactLexer', *arguments], capture_output=True, text=True).stdout.splitlines()
        if len(actual) != len(chunk) or len(expected) != len(chunk):
            raise SystemExit('incomplete endpoint observations')
        failures.extend({'rule': case[0], 'input': case[1], 'w': got, 'antlr': want} for case, got, want in zip(chunk, actual, expected) if got != want)
    tools = {name: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
             for name, path in {'translator': 'bin/antlr_to_pg', 'compiler': 'bin/wv2',
                                'grammar': 'tests/grammars/antlr_exact_lexer/Exact.g4',
                                'reference_driver': 'tests/grammars/antlr_exact_lexer/OracleProbe.java'}.items()}
    report = {'antlr_jar_sha256': JAR_SHA256, 'java_version': version.strip(),
              'tools_and_inputs_sha256': tools, 'cases': len(cases), 'mismatches': failures,
              'seconds': round(time.monotonic() - started, 3)}
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'{len(cases)} endpoint cases, {len(failures)} mismatches')
    if failures: raise SystemExit(1)

if __name__ == '__main__': main()
