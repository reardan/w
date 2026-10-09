#!/usr/bin/env bash
# Sweeps every top-level grammar directory in antlr/grammars-v4 through
# bin/antlr_to_pg, then tries to compile each result with bin/wv2.
# Produces sweep_results.csv (one row per grammar: translate exit code,
# report line count, wv2 compile exit code and last error line).
#
# Needs a local checkout of antlr/grammars-v4 -- it's too big to vendor
# wholesale (unlike testdata/antlr/), so fetch just the .g4 files:
#   git clone --filter=blob:none --sparse https://github.com/antlr/grammars-v4 /path/to/grammars-v4
#   cd /path/to/grammars-v4
#   git sparse-checkout init --no-cone
#   printf '/*.g4\n/*/*.g4\n/*/*/*.g4\n' > .git/info/sparse-checkout
#   git sparse-checkout reapply
#
# Build the translator first (`./wbuild antlr_to_pg`, from the repo root).
# Usage: GV4=/path/to/grammars-v4 libs/extras/grammars/antlr_to_pg/sweep_grammars_v4.sh
set -u

GV4=${GV4:?set GV4 to a antlr/grammars-v4 checkout (see script header)}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
TOOL="$REPO_ROOT/bin/antlr_to_pg"
PGEN="$REPO_ROOT/bin/parser_generator_grammars"
WV2="$REPO_ROOT/bin/wv2"
MATCHERS="$REPO_ROOT/libs/extras/grammars/matchers.w"
WORK=${WORK:-/tmp/sweep_work}
OUT_CSV=${OUT_CSV:-"$SCRIPT_DIR/sweep_results.csv"}
JOBS=${JOBS:-4}

if [ ! -x "$TOOL" ]; then
	echo "no $TOOL -- build it first (./wbuild antlr_to_pg)" >&2
	exit 1
fi

mkdir -p "$WORK/rows"
rm -f "$WORK"/rows/*.csv

# Prefer a single XLexer.g4 + XParser.g4 pair when a directory holds
# multiple independent grammars (e.g. eiffel, glsl, stringtemplate). Falls
# back to all top-level .g4 files when no such pair exists.
pick_g4_files() {
	d=$1
	dir="$GV4/$d"
	pair=""
	pair_stem=""
	for lexer in "$dir"/*Lexer.g4; do
		[ -f "$lexer" ] || continue
		stem=$(basename "$lexer" | sed 's/Lexer\.g4$//')
		parser="$dir/${stem}Parser.g4"
		if [ -f "$parser" ]; then
			# Prefer the shortest stem (usually the primary grammar over
			# NoSkip / Pre / Operator variants).
			if [ -z "$pair" ] || [ ${#stem} -lt ${#pair_stem} ]; then
				pair="$lexer $parser"
				pair_stem=$stem
			fi
		fi
	done
	if [ -n "$pair" ]; then
		echo "$pair"
		return
	fi
	# Prefer a single .g4 whose basename matches the directory (e.g.
	# cobol85/Cobol85.g4 over Cobol85Preprocessor.g4; caql/CaQL.g4 over
	# Metrics.g4) when several independent combined grammars share a dir.
	base=$(basename "$d")
	for f in "$dir"/*.g4; do
		[ -f "$f" ] || continue
		stem=$(basename "$f" .g4)
		stem_lc=$(echo "$stem" | tr '[:upper:]' '[:lower:]')
		base_lc=$(echo "$base" | tr '[:upper:]' '[:lower:]')
		if [ "$stem_lc" = "$base_lc" ]; then
			echo "$f"
			return
		fi
	done
	find "$dir" -maxdepth 1 -name "*.g4" 2>/dev/null | sort
}

run_one() {
	d=$1
	safe_name=$(echo "$d" | tr -c 'a-zA-Z0-9' '_')
	case "$safe_name" in
		[0-9]*) safe_name="g_$safe_name" ;;
	esac
	files=$(pick_g4_files "$d")
	nfiles=$(echo "$files" | wc -w | tr -d ' ')
	if [ "$nfiles" -eq 0 ]; then
		return
	fi

	out_pg="$WORK/$safe_name.pg"
	out_report="$WORK/$safe_name.report"
	out_w="$WORK/$safe_name.w"
	out_matchers="$WORK/$safe_name.matchers.w"

	file_args=""
	for f in $files; do
		file_args="$file_args $f"
	done

	"$TOOL" $file_args -o "$out_pg" --parser-name "$safe_name" --report "$out_report" --matchers "$out_matchers" >/dev/null 2>&1
	translate_exit=$?
	report_lines=0
	if [ -f "$out_report" ]; then
		report_lines=$(( $(wc -l < "$out_report") - 1 ))
	fi
	pg_summary=$(head -1 "$out_report" 2>/dev/null | tr ',' ';')

	wv2_exit=""
	wv2_error=""
	if [ "$translate_exit" -eq 0 ]; then
		gen_out=$("$PGEN" "$out_pg" -o "$out_w" 2>&1)
		gen_exit=$?
		if [ "$gen_exit" -eq 0 ]; then
			if [ -f "$out_matchers" ]; then
				cat "$MATCHERS" "$out_matchers" "$out_w" > "$WORK/$safe_name.compile.w"
			else
				cat "$MATCHERS" "$out_w" > "$WORK/$safe_name.compile.w"
			fi
			wv2_out=$(cd "$REPO_ROOT" && "$WV2" "$WORK/$safe_name.compile.w" -o "$WORK/$safe_name.bin" 2>&1)
			wv2_exit=$?
			if [ "$wv2_exit" -ne 0 ]; then
				wv2_error=$(echo "$wv2_out" | tail -1 | tr ',' ';' | tr '\n' ' ')
			fi
		else
			wv2_exit="pgen_fail"
			wv2_error=$(echo "$gen_out" | tail -1 | tr ',' ';')
		fi
	fi

	echo "$d,$nfiles,$translate_exit,$report_lines,\"$pg_summary\",$wv2_exit,\"$wv2_error\"" > "$WORK/rows/$safe_name.csv"
}

export -f run_one pick_g4_files
export GV4 REPO_ROOT TOOL PGEN WV2 MATCHERS WORK

cd "$GV4"
ls -d */ | sed 's#/$##' | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}

echo "name,files,translate_exit,report_lines,pg_names,wv2_exit,wv2_error" > "$OUT_CSV"
cat "$WORK"/rows/*.csv >> "$OUT_CSV" 2>/dev/null

echo "done -> $OUT_CSV"
