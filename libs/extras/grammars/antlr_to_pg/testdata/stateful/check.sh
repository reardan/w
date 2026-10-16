#!/bin/sh
set -eu
translator=${1:-bin/antlr_to_pg}
work=bin/antlr-stateful-cli
mkdir -p "$work"
printf '%s\n' 'keep parser' > "$work/out.pg"
printf '%s\n' 'keep matcher' > "$work/matchers.w"
cp "$work/out.pg" "$work/expected.pg"
cp "$work/matchers.w" "$work/expected.w"
cat > "$work/conflict.g4" <<'EOF'
grammar Conflict;
root: A EOF;
A: 'a' -> more, type(B);
B: 'b';
EOF
cat > "$work/greedy.g4" <<'EOF'
grammar Greedy;
root: A EOF;
A: [a-z]+ 'x';
EOF
cat > "$work/repetition.g4" <<'EOF'
grammar Repetition;
root: A EOF;
A: ('aa' | 'aaa')+;
EOF
cat > "$work/missing-mode.g4" <<'EOF'
grammar MissingMode;
root: A EOF;
A: 'a' -> pushMode(UNKNOWN);
EOF
cat > "$work/custom-channel.g4" <<'EOF'
grammar CustomChannel;
root: A EOF;
A: 'a' -> channel(CUSTOM);
EOF
cat > "$work/ambiguous.g4" <<'EOF'
lexer grammar Ambiguous;
root: 'a' EOF;
A: 'a';
mode OTHER;
B: 'a';
EOF
for fixture in conflict greedy repetition missing-mode custom-channel ambiguous; do
    if "$translator" --strict --stateful "$work/$fixture.g4" -o "$work/out.pg" --matchers "$work/matchers.w" --audit "$work/$fixture.audit" 2> "$work/$fixture.stderr"; then
        echo "expected strict rejection: $fixture" >&2
        exit 1
    fi
    cmp "$work/out.pg" "$work/expected.pg"
    cmp "$work/matchers.w" "$work/expected.w"
done
grep -q 'conflicting or repeated lexer commands' "$work/conflict.audit"
grep -q 'requires a backtracking proof' "$work/greedy.audit"
grep -q 'requires a prefix-free body proof' "$work/repetition.audit"
grep -q 'unsupported command pushMode(UNKNOWN)' "$work/missing-mode.audit"
grep -q 'unsupported command channel(CUSTOM)' "$work/custom-channel.audit"
grep -q 'ambiguous lexer token identities' "$work/ambiguous.audit"
cat > "$work/delimited.g4" <<'EOF'
grammar Delimited;
root: STRING EOF;
STRING: '"' ('\\' . | ~["\\])* '"';
EOF
"$translator" --strict --stateful "$work/delimited.g4" -o "$work/delimited.pg" --matchers "$work/delimited.w" 2> "$work/delimited.stderr"
printf '%s\n' 'antlr stateful audit and failure atomicity passed'
