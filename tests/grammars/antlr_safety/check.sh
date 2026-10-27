#!/bin/sh
# End-to-end structural refusals preserve existing output files.
set -eu
translator=${1:-bin/antlr_to_pg}
fixtures=tests/grammars/antlr_safety
work=bin/antlr-safety-cli
mkdir -p "$work"
printf '%s\n' 'keep parser' > "$work/expected.pg"
printf '%s\n' 'keep matcher' > "$work/expected.w"
cp "$work/expected.pg" "$work/out.pg"
cp "$work/expected.w" "$work/matchers.w"
for fixture in nullable_token nullable_loop expression; do
    if "$translator" "$fixtures/$fixture.g4" -o "$work/out.pg" --matchers "$work/matchers.w" 2> "$work/$fixture.stderr"; then
        exit 1
    fi
    cmp "$work/out.pg" "$work/expected.pg"
    cmp "$work/matchers.w" "$work/expected.w"
done
"$translator" --strict "$fixtures/nullable.g4" -o "$work/nullable.pg" --matchers "$work/nullable.w" 2> "$work/nullable.stderr"
"$translator" --strict "$fixtures/lists.g4" -o "$work/lists.pg" --matchers "$work/lists.w" 2> "$work/lists.stderr"
"$translator" --strict --stateful "$fixtures/precedence.g4" -o "$work/precedence.pg" --matchers "$work/precedence.w" 2> "$work/precedence.stderr"
# --start selects the generated start rule; an unknown rule is refused
# before any output is written.
"$translator" "$fixtures/lists.g4" -o "$work/start.pg" --start item 2> "$work/start.stderr"
grep -qx 'start item' "$work/start.pg"
if "$translator" "$fixtures/lists.g4" -o "$work/out.pg" --matchers "$work/matchers.w" --start Missing 2> "$work/start_missing.stderr"; then
    exit 1
fi
grep -q -- '--start Missing is not a parser rule' "$work/start_missing.stderr"
cmp "$work/out.pg" "$work/expected.pg"
cmp "$work/matchers.w" "$work/expected.w"
printf '%s\n' 'antlr structural CLI and output preservation passed'
