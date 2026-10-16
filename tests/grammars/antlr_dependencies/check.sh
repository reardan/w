#!/bin/sh
# Dependency closure, strict auditing, runtime behavior and output atomicity.
set -eu
translator=${1:-bin/antlr_to_pg}
generator=${2:-bin/parser_generator_grammars}
compiler=${3:-bin/wv2}
work=$(mktemp -d bin/antlr-dependency-cli.XXXXXX)
mkdir -p "$work/imports" "$work/explicit" "$work/cycle" "$work/override"
cat > "$work/imports/Front.g4" <<'EOF'
parser grammar Front;
options { tokenVocab = TokensLex; }
root: WORD EOF;
EOF
cat > "$work/explicit/Renamed.g4" <<'EOF'
lexer grammar TokensLex;
tokens { WORD }
T: 'a' -> type(WORD);
WS: [ \t\r\n]+ -> skip;
EOF
# A supplied token vocabulary need not use its grammar name as its filename.
"$translator" --strict "$work/imports/Front.g4" "$work/explicit/Renamed.g4" --parser-name dep -o "$work/front.pg" --matchers "$work/front.matchers.w" --dependencies "$work/explicit.inputs" 2> "$work/explicit.log"
grep -q 'Renamed.g4' "$work/explicit.inputs"
"$generator" "$work/front.pg" -o "$work/front.w"
cat libs/extras/grammars/matchers.w "$work/front.matchers.w" "$work/front.w" > "$work/run.w"
cat >> "$work/run.w" <<'EOF'

int main():
	pg_diagnostics* good = pg_diagnostics_new()
	pg_ast_node* root = dep_parse(c"a", c"good", good)
	if ((root == 0) || (pg_diagnostics_count(good) != 0)): return 1
	pg_diagnostics* bad = pg_diagnostics_new()
	root = dep_parse(c"b", c"bad", bad)
	if ((root != 0) && (pg_diagnostics_count(bad) == 0)): return 2
	return 0
EOF
"$compiler" "$work/run.w" -o "$work/run"
"$work/run"
# Same vocabulary supplied automatically; two transitive fragment imports.
cat > "$work/imports/TokensLex.g4" <<'EOF'
lexer grammar TokensLex;
import Base;
tokens { WORD }
T: Letter -> type(WORD);
WS: [ \t\r\n]+ -> skip;
EOF
cat > "$work/imports/Base.g4" <<'EOF'
lexer grammar Base;
import Core;
fragment Letter: CoreLetter;
EOF
cat > "$work/imports/Core.g4" <<'EOF'
lexer grammar Core;
fragment CoreLetter: 'a';
EOF
"$translator" --strict "$work/imports/Front.g4" --parser-name dep -o "$work/auto.pg" --matchers "$work/auto.matchers.w" --dependencies "$work/auto.inputs" 2> "$work/auto.log"
test "$(wc -l < "$work/auto.inputs")" -eq 4
grep -q 'Core.g4' "$work/auto.inputs"
"$generator" "$work/auto.pg" -o "$work/auto.w"
printf '%s\n' 'preserve parser' > "$work/out.pg"
printf '%s\n' 'preserve matcher' > "$work/out.w"
cp "$work/out.pg" "$work/expected.pg"
cp "$work/out.w" "$work/expected.w"
reject() {
    name=$1
    reason=$2
    shift 2
    if "$translator" "$@" -o "$work/out.pg" --matchers "$work/out.w" --audit "$work/$name.audit" 2> "$work/$name.log"; then
        echo "unexpected dependency acceptance: $name" >&2
        exit 1
    fi
    grep -q "$reason" "$work/$name.log"
    cmp "$work/out.pg" "$work/expected.pg"
    cmp "$work/out.w" "$work/expected.w"
}
reject ambiguity 'ambiguous dependency' "$work/imports/Front.g4" "$work/explicit/Renamed.g4"
cat > "$work/explicit/Other.g4" <<'EOF'
lexer grammar TokensLex;
T: 'b';
EOF
reject duplicate 'ambiguous grammar' "$work/explicit/Renamed.g4" "$work/explicit/Other.g4"
cat > "$work/Missing.g4" <<'EOF'
parser grammar Missing;
options { tokenVocab = Absent; }
root: A EOF;
EOF
reject missing 'could not read grammar file' "$work/Missing.g4"
cat > "$work/Absent.g4" <<'EOF'
lexer grammar Different;
A: 'a';
EOF
reject mismatch 'declares grammar Different' "$work/Missing.g4"
cat > "$work/Absent.g4" <<'EOF'
grammar Absent;
other: 'z' EOF;
A: 'a';
EOF
reject combined-vocabulary 'requires a lexer grammar' "$work/Missing.g4"
cat > "$work/cycle/A.g4" <<'EOF'
grammar A;
import B;
root: 'a' EOF;
EOF
cat > "$work/cycle/B.g4" <<'EOF'
grammar B;
import A;
other: 'b';
EOF
reject cycle 'dependency cycle' "$work/cycle/A.g4"
cat > "$work/override/Override.g4" <<'EOF'
grammar Override;
import Imported;
root: 'a' EOF;
EOF
cat > "$work/override/Imported.g4" <<'EOF'
grammar Imported;
root: 'b' EOF;
EOF
# Root wins even when its explicitly supplied imported grammar appears first.
"$translator" "$work/override/Imported.g4" "$work/override/Override.g4" --parser-name override -o "$work/override.pg" --matchers "$work/override.matchers.w"
"$generator" "$work/override.pg" -o "$work/override.w"
cat libs/extras/grammars/matchers.w "$work/override.matchers.w" "$work/override.w" > "$work/override_run.w"
cat >> "$work/override_run.w" <<'EOF'

int main():
	pg_diagnostics* good = pg_diagnostics_new()
	pg_ast_node* root = override_parse(c"a", c"good", good)
	if ((root == 0) || (pg_diagnostics_count(good) != 0)): return 1
	pg_diagnostics* bad = pg_diagnostics_new()
	root = override_parse(c"b", c"bad", bad)
	if ((root != 0) && (pg_diagnostics_count(bad) == 0)): return 2
	return 0
EOF
"$compiler" "$work/override_run.w" -o "$work/override_run"
"$work/override_run"
cat > "$work/imports/Host.g4" <<'EOF'
parser grammar Host;
options { tokenVocab = TokensLex; superClass = ForeignHost; }
root: WORD EOF;
EOF
reject host 'superClass = ForeignHost' --strict "$work/imports/Host.g4"
cat > "$work/BadTokens.g4" <<'EOF'
grammar BadTokens;
tokens { WORD = 1 }
root: 'a' EOF;
EOF
reject tokens 'unsupported tokens declaration' "$work/BadTokens.g4"
printf '%s\n' 'antlr grammar dependencies and token identities passed'
