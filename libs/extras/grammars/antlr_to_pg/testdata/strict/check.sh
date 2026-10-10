#!/bin/sh
# CLI validation and failure atomicity; no network or external parser needed.
set -eu
translator=${1:-bin/antlr_to_pg}
fixtures=libs/extras/grammars/antlr_to_pg/testdata/strict
work=bin/antlr-strict-cli
mkdir -p "$work"
printf '%s\n' 'keep parser' > "$work/out.pg"
printf '%s\n' 'keep matcher' > "$work/matchers.w"
cp "$work/out.pg" "$work/expected.pg"
cp "$work/matchers.w" "$work/expected.w"
if "$translator" --strict "$fixtures/semantic.g4" -o "$work/out.pg" --matchers "$work/matchers.w" --audit "$work/audit" 2> "$work/stderr"; then
    exit 1
fi
cmp "$work/out.pg" "$work/expected.pg"
cmp "$work/matchers.w" "$work/expected.w"
grep -q 'unsupported command type(A)' "$work/audit"
grep -q 'unsupported command popMode()' "$work/audit"
grep -q 'unmapped predicate at atom position 1' "$work/audit"
grep -q 'assoc=right' "$work/audit"
if "$translator" --strict "$fixtures/semantic.g4" -o "$work/out.pg" --audit "$work/audit-again" 2> "$work/stderr-again"; then
    exit 1
fi
cmp "$work/audit" "$work/audit-again"
for fixture in cycle malformed; do
    if "$translator" "$fixtures/$fixture.g4" -o "$work/out.pg" 2> "$work/$fixture.stderr"; then
        exit 1
    fi
    cmp "$work/out.pg" "$work/expected.pg"
done
"$translator" --strict "$fixtures/plain.g4" -o "$work/plain.pg" 2> "$work/plain.stderr"
grep -q 'rule root' "$work/plain.pg"
printf '%s\n' 'antlr strict CLI and output preservation passed'
upstream=libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript
if "$translator" --strict "$upstream/JavaScriptLexer.g4" "$upstream/JavaScriptParser.g4" -o "$work/out.pg" --audit "$work/javascript.audit" 2> "$work/javascript.stderr"; then
    exit 1
fi
cmp "$work/javascript.audit" "$upstream/BLOCKERS.txt"
cmp "$work/out.pg" "$work/expected.pg"
