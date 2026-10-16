#!/usr/bin/env python3
"""Differentially check native Unicode 12.1 mappings against the configured Node.

Only characters with a mapping in the pinned UCD table are selected. Newer
Unicode additions are deliberately outside this versioned profile. Context and
UTF-16 edge cases have separate semantic tests in runtime_string_case_test.w.
"""
import json
import subprocess
import sys

probe = subprocess.run([sys.argv[1]], check=True, text=True, capture_output=True, timeout=60)
rows = [json.loads(line) for line in probe.stdout.splitlines()]
assert len(rows) == 2841, len(rows)
script = r'''
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(0, 'utf8'));
const units = text => Array.from({length: text.length}, (_, i) => text.charCodeAt(i));
for (const [cp, lower, upper] of rows) {
  const input = String.fromCodePoint(cp);
  const expected = [units(input.toLowerCase()), units(input.toUpperCase())];
  if (JSON.stringify([lower, upper]) !== JSON.stringify(expected)) {
    throw new Error(JSON.stringify({cp, lower, upper, expected}));
  }
}
console.log(JSON.stringify({status: 'PASS', checks: rows.length * 2, node: process.version}));
'''
result = subprocess.run(['node', '-e', script], input=json.dumps(rows), check=True,
                        text=True, capture_output=True, timeout=30)
print(result.stdout.strip())
