#!/bin/sh
# bench_vs_c.sh: W codegen against gcc -O2 / clang -O2 on the benchmark
# corpus (docs/testing.md "Performance", docs/projects/register_allocation_pgo.md §5).
#
#   tools/bench_vs_c.sh [-c <w compiler>] [-n <runs>] [-o <name>] [-V] [-q]
#
# For every program of tests/bench/ that has a C twin in tests/bench/c/
# (every one but `self`), builds it for x86 and x64 with the W compiler
# (default bin/wv2), and its twin with gcc -O2, clang -O2 and -- when the
# toolchain has 32-bit multilib -- gcc -O2 -m32; checks that every build
# prints the same checksum line; then prints a markdown table of best-of-N
# wall times (default 3 runs) and, when valgrind is on PATH (-V skips it),
# a second table of callgrind instruction counts. A missing compiler is
# reported as "n/a" in its column rather than failing the run; a checksum
# mismatch or a failed build/run is "FAIL" and makes the script exit 1.
# -o restricts the run to one program, -q skips the valgrind pass for the
# W x86/x64 rows only (they are already in bin/bench.txt).
#
# Run from the repository root. Outputs go to bin/bench_vs_c/.
set -u

W=bin/wv2
RUNS=3
ONLY=
NO_VALGRIND=0
PROGRAMS="sum sieve sha256_1m siphash_keys inflate_corpus regex_backtrack matmul_256 strcmp_sort"
while [ $# -gt 0 ]; do
	case "$1" in
		-c) W=$2; shift 2 ;;
		-n) RUNS=$2; shift 2 ;;
		-o) ONLY=$2; shift 2 ;;
		-V) NO_VALGRIND=1; shift ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "bench_vs_c.sh: unknown argument $1" >&2; exit 2 ;;
	esac
done
[ -n "$ONLY" ] && PROGRAMS=$ONLY
OUT=bin/bench_vs_c
mkdir -p "$OUT"
STATUS=0

have() { command -v "$1" >/dev/null 2>&1; }

# Column availability, probed once.
HAVE_GCC=0; have gcc && HAVE_GCC=1
HAVE_CLANG=0; have clang && HAVE_CLANG=1
HAVE_M32=0
if [ $HAVE_GCC = 1 ]; then
	printf 'int main(void){return 0;}\n' > "$OUT/m32_probe.c"
	gcc -O2 -m32 -o "$OUT/m32_probe" "$OUT/m32_probe.c" >/dev/null 2>&1 && "$OUT/m32_probe" && HAVE_M32=1
fi
HAVE_VALGRIND=0
[ $NO_VALGRIND = 0 ] && have valgrind && HAVE_VALGRIND=1
[ -x "$W" ] || { echo "bench_vs_c.sh: no W compiler at $W (./wbuild build, or -c)" >&2; exit 2; }

COLUMNS="w_x86 w_x64 gcc clang gcc_m32"
label() {
	case "$1" in
		w_x86) echo "W x86" ;; w_x64) echo "W x64" ;; gcc) echo "gcc -O2" ;;
		clang) echo "clang -O2" ;; gcc_m32) echo "gcc -O2 -m32" ;;
	esac
}

# build <program> <column> -> 0 and $OUT/<program>.<column> exists, 1 when
# the column's compiler is absent, 2 on a build failure.
build() {
	p=$1; col=$2; bin="$OUT/$p.$col"; log="$OUT/$p.$col.log"
	case "$col" in
		w_x86) "$W" --quiet "tests/bench/$p.w" -o "$bin" >"$log" 2>&1 ;;
		w_x64) "$W" x64 --quiet "tests/bench/$p.w" -o "$bin" >"$log" 2>&1 ;;
		gcc) [ $HAVE_GCC = 1 ] || return 1; gcc -O2 -o "$bin" "tests/bench/c/$p.c" >"$log" 2>&1 ;;
		clang) [ $HAVE_CLANG = 1 ] || return 1; clang -O2 -o "$bin" "tests/bench/c/$p.c" >"$log" 2>&1 ;;
		gcc_m32) [ $HAVE_M32 = 1 ] || return 1; gcc -O2 -m32 -o "$bin" "tests/bench/c/$p.c" >"$log" 2>&1 ;;
	esac
	[ $? = 0 ] && [ -x "$bin" ] || return 2
	return 0
}

now_ms() {
	# date +%s%N is GNU; fall back to whole seconds elsewhere.
	n=$(date +%s%N 2>/dev/null)
	case "$n" in
		*N|'') echo $(( $(date +%s) * 1000 )) ;;
		*) echo $(( n / 1000000 )) ;;
	esac
}

# time_best <binary> -> best wall ms of $RUNS runs on stdout, "" on failure.
time_best() {
	best=
	i=0
	while [ $i -lt "$RUNS" ]; do
		t0=$(now_ms)
		"$1" >/dev/null 2>&1 || { echo ""; return; }
		t1=$(now_ms)
		d=$(( t1 - t0 ))
		[ -z "$best" ] || [ "$d" -lt "$best" ] && best=$d
		i=$(( i + 1 ))
	done
	echo "$best"
}

# ir_of <binary> -> callgrind Ir on stdout, "" when unavailable.
ir_of() {
	[ $HAVE_VALGRIND = 1 ] || { echo ""; return; }
	valgrind --tool=callgrind --callgrind-out-file="$1.callgrind" "$1" 2>"$1.valgrind.log" >/dev/null || { echo ""; return; }
	sed -n 's/.*Collected : \([0-9]*\).*/\1/p' "$1.valgrind.log" | head -1
}

TABLE_MS="$OUT/table_ms.md"
TABLE_IR="$OUT/table_ir.md"
hdr="| program |"; sep="| --- |"
for col in $COLUMNS; do hdr="$hdr $(label "$col") |"; sep="$sep ---: |"; done
printf '%s\n%s\n' "$hdr" "$sep" > "$TABLE_MS"
printf '%s\n%s\n' "$hdr" "$sep" > "$TABLE_IR"

for p in $PROGRAMS; do
	[ -f "tests/bench/c/$p.c" ] || { echo "bench_vs_c.sh: no C twin for $p, skipped" >&2; continue; }
	row_ms="| $p |"; row_ir="| $p |"
	expected=
	for col in $COLUMNS; do
		build "$p" "$col"; rc=$?
		if [ $rc = 1 ]; then row_ms="$row_ms n/a |"; row_ir="$row_ir n/a |"; continue; fi
		if [ $rc = 2 ]; then
			echo "bench_vs_c.sh: $p [$col] failed to build (see $OUT/$p.$col.log)" >&2
			row_ms="$row_ms FAIL |"; row_ir="$row_ir FAIL |"; STATUS=1; continue
		fi
		bin="$OUT/$p.$col"
		out=$("$bin" 2>&1)
		if [ -z "$expected" ]; then expected=$out; fi
		if [ "$out" != "$expected" ]; then
			echo "bench_vs_c.sh: $p [$col] printed '$out', expected '$expected'" >&2
			row_ms="$row_ms FAIL |"; row_ir="$row_ir FAIL |"; STATUS=1; continue
		fi
		ms=$(time_best "$bin")
		[ -n "$ms" ] || { row_ms="$row_ms FAIL |"; row_ir="$row_ir FAIL |"; STATUS=1; continue; }
		row_ms="$row_ms $ms |"
		ir=$(ir_of "$bin")
		if [ -n "$ir" ]; then row_ir="$row_ir $ir |"; else row_ir="$row_ir - |"; fi
	done
	echo "$p: $expected"
	echo "$row_ms" >> "$TABLE_MS"
	echo "$row_ir" >> "$TABLE_IR"
done

echo
echo "Best wall time of $RUNS runs, ms (W compiler: $W):"
echo
cat "$TABLE_MS"
if [ $HAVE_VALGRIND = 1 ]; then
	echo
	echo "callgrind instructions (Ir):"
	echo
	cat "$TABLE_IR"
else
	echo
	echo "(valgrind not on PATH: no instruction counts)"
fi
[ $HAVE_M32 = 1 ] || echo "(gcc -m32: no 32-bit multilib, column skipped)"
exit $STATUS
