#!/bin/sh
set -eu
work=bin/antlr-exact-refusals
mkdir -p "$work"
printf '%s\n' 'keep parser' > "$work/output.pg"
printf '%s\n' 'keep matcher' > "$work/matchers.w"
cp "$work/output.pg" "$work/parser.before"
cp "$work/matchers.w" "$work/matchers.before"
cat > "$work/property.g4" <<'GRAMMAR'
grammar Property;
root: TOKEN EOF;
TOKEN: [\p{Not_A_Unicode_Property}]+;
GRAMMAR
cat > "$work/nonproductive.g4" <<'GRAMMAR'
grammar Nonproductive;
root: TOKEN EOF;
TOKEN: 'a' TOKEN;
GRAMMAR
cat > "$work/host.g4" <<'GRAMMAR'
grammar Host;
options { caseInsensitive=true; superClass=ForeignBase; }
root: TOKEN EOF;
TOKEN: 'a';
GRAMMAR
cat > "$work/implicit.g4" <<'GRAMMAR'
grammar Implicit;
options { caseInsensitive=true; }
root: ('a' | 'b') EOF;
GRAMMAR
cat > "$work/escape.g4" <<'GRAMMAR'
grammar Escape;
root: TOKEN EOF;
TOKEN: '\q';
GRAMMAR
cat > "$work/nul.g4" <<'GRAMMAR'
grammar Nul;
root: TOKEN EOF;
TOKEN: '\u0000';
GRAMMAR
for name in property nonproductive host implicit escape nul; do
    if bin/antlr_to_pg --strict --exact-lexer "$work/$name.g4" -o "$work/output.pg" --matchers "$work/matchers.w" 2> "$work/$name.stderr"; then
        echo "expected exact strict refusal: $name" >&2
        exit 1
    fi
    cmp "$work/parser.before" "$work/output.pg"
    cmp "$work/matchers.before" "$work/matchers.w"
done
printf '%s\n' 'exact lexer refusal and output atomicity passed'
