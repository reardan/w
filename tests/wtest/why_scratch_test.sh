#!/bin/sh
# Fixture for the NAMED deps-failure aggregate warning and the
# 'wtest why <root>' explainer (tools/test_map.w;
# docs/projects/ai_tooling_next_steps.md 2026-08-05: the aggregate
# warning was anonymous -- "'bin/wv2 deps' failed for 72 roots" named
# no root and no reason, so an agent could not tell whether the
# fallback lost selection coverage for its diff or which roots needed
# fixing). Now the aggregate names the first few failing roots plus a
# count and one representative stderr line, persistable failures carry
# their stderr detail into bin/.wtest_deps_cache ('E ' line), and
# 'wtest why [<arch>] <file.w>' explains one root's cache/live/
# selection story.
#
# Uses a scratch checkout with a FAKE bin/wv2 keyed on the root path
# (the tests/wtest/timeout_scratch_test.sh pattern) so every failure
# flavor is deterministic and instant; WTEST_DEPS_TIMEOUT_MS shrinks
# the timeout budget so the hang.w path runs in under a second.
set -e

repo_root=$(pwd)
wtest="$repo_root/bin/wtest"
if [ ! -x "$wtest" ]; then
	echo "wtest_why_scratch_test: bin/wtest must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/bin"
ln -s "$wtest" "$dir/bin/wtest"

# The fake compiler: 'bin/wv2 deps [x64] <root>' keyed on the root.
#   ok.w           -> success; closure ok.w + dep.w
#   bad1.w         -> "cannot locate 'gen/missing1.w'" until that file
#                     appears, then success (the M-line retry story)
#   bad2.w-bad6.w  -> a plain compile error, distinct per root
#   hang.w         -> always sleeps past the budget (never cached)
#   anything else  -> success; closure is just the root itself
cat > "$dir/bin/wv2" <<'EOF'
#!/bin/sh
root="$2"
if [ "$2" = "x64" ]; then
	root="$3"
fi
case "$root" in
	ok.w)
		echo "ok.w"
		echo "dep.w"
		;;
	bad1.w)
		if [ -f gen/missing1.w ]; then
			echo "bad1.w"
			echo "gen/missing1.w"
			echo "dep.w"
		else
			echo "bad1.w:2:1: error: cannot locate 'gen/missing1.w'" >&2
			exit 1
		fi
		;;
	bad*.w)
		echo "$root:1:1: error: fixture failure in $root" >&2
		exit 1
		;;
	hang.w)
		sleep 2
		;;
	*)
		echo "$root"
		;;
esac
EOF
chmod +x "$dir/bin/wv2"

printf 'int main():\n\treturn 0\n' > "$dir/w.w"
echo 'int dep = 1' > "$dir/dep.w"
for f in ok bad1 bad2 bad3 bad4 bad5 bad6 hang; do
	echo 'import dep' > "$dir/$f.w"
done

# One conventional compile target per root, in manifest order, so the
# failing-root list in the aggregate warning is deterministic.
{
	printf '{\n\t"targets": [\n'
	first=1
	for f in ok bad1 bad2 bad3 bad4 bad5 bad6 hang; do
		if [ "$first" = 0 ]; then
			printf ',\n'
		fi
		first=0
		printf '\t\t{"name": "%s_t", "steps": [{"cmd": ["bin/wv2", "%s.w", "-o", "bin/%s"]}]}' "$f" "$f" "$f"
	done
	printf '\n\t]\n}\n'
} > "$dir/build.json"

cd "$dir"
WTEST_DEPS_TIMEOUT_MS=400
export WTEST_DEPS_TIMEOUT_MS

fail() {
	echo "wtest_why_scratch_test: FAIL: $1" >&2
	exit 1
}

# 1) Cold run: the aggregate warning NAMES the failing roots (first
# five plus a count), gives one representative stderr line, and points
# at 'wtest why'. Selection through computable closures is unaffected,
# and the failed roots stay unselected (literal fallback has nothing
# to match for dep.w).
out=$(bin/wtest changed dep.w 2>err.txt)
grep -q "wtest: warning: 'bin/wv2 deps' failed for 7 roots; falling back to literal matching for them: x86 bad1.w, x86 bad2.w, x86 bad3.w, x86 bad4.w, x86 bad5.w (and 2 more)" err.txt || fail "aggregate warning does not name the failing roots"
grep -q "wtest: warning: e.g. root 'x86 bad1.w': bad1.w:2:1: error: cannot locate 'gen/missing1.w'" err.txt || fail "no representative failure reason"
grep -q "wtest: note: 'wtest why \[<arch>\] <file.w>' explains any root's selection story" err.txt || fail "no wtest-why pointer"
echo "$out" | grep -qx ok_t || fail "closure selection lost ok_t"
echo "$out" | grep -qx bad1_t && fail "bad1_t selected without a closure"

# 2) Persistable failures carry their stderr detail ('E ') and
# successes the computing compiler's hash ('V ', informational) in
# bin/.wtest_deps_cache; timeouts are still never persisted.
grep -q "^X x86 bad1.w$" bin/.wtest_deps_cache || fail "bad1.w failure not cached"
grep -q "^E bad1.w:2:1: error: cannot locate 'gen/missing1.w'$" bin/.wtest_deps_cache || fail "no E detail line for bad1.w"
grep -q "^M gen/missing1.w$" bin/.wtest_deps_cache || fail "no M line for bad1.w"
grep -A2 "^R x86 ok.w$" bin/.wtest_deps_cache | grep -q "^V " || fail "no informational V line on ok.w's success entry"
grep -q "x86 hang.w" bin/.wtest_deps_cache && fail "hang.w's timeout was persisted"

# 3) 'wtest why' on a failed root, in a FRESH process: the story (the
# recorded stderr included) comes off the cache, not run memory.
bin/wtest why bad1.w > why.txt 2>/dev/null || fail "wtest why exited nonzero"
grep -q "^wtest: why root 'x86 bad1.w'$" why.txt || fail "why: no header"
grep -q "^root file: present$" why.txt || fail "why: no root-file line"
grep -q "^compile root of: bad1_t$" why.txt || fail "why: no owning target"
grep -q "^cache: failure entry (the last 'bin/wv2 deps' run exited nonzero)$" why.txt || fail "why: no failure-entry line"
grep -q "^  root content: unchanged since the failure$" why.txt || fail "why: no root-content line"
grep -q "^  missing import: gen/missing1.w (still absent)$" why.txt || fail "why: no missing-import line"
grep -q "^  deps stderr: bad1.w:2:1: error: cannot locate 'gen/missing1.w'$" why.txt || fail "why: no recorded stderr"
grep -q "^  status: valid -- rule (b) is disabled for this root; its targets select via literal/residue rules only$" why.txt || fail "why: no status verdict"
grep -q "^closure: unavailable (the cached failure above still holds)$" why.txt || fail "why: no closure line"
grep -q "^  bad1_t (literal step reference)$" why.txt || fail "why: selection attribution missing"

# 4) The missing import appearing flips the story: the cache entry
# reads stale, the live re-run succeeds and warms the cache, and the
# selection attribution switches to closure + literal.
mkdir -p gen
echo 'int missing1 = 1' > gen/missing1.w
bin/wtest why bad1.w > why2.txt 2>/dev/null || fail "wtest why (recovered) exited nonzero"
grep -q "missing import: gen/missing1.w (now present -> retried on the next selection)" why2.txt || fail "why: missing-import reappearance not reported"
grep -q "^  status: stale -- 'bin/wv2 deps' re-runs on the next selection$" why2.txt || fail "why: stale verdict missing"
grep -q "^closure: computed now (3 files; cache updated)$" why2.txt || fail "why: live recompute missing"
grep -q "^  bad1_t (closure of root 'x86 bad1.w'; literal step reference)$" why2.txt || fail "why: closure attribution missing after recovery"
grep -q "^R x86 bad1.w$" bin/.wtest_deps_cache || fail "why's live recompute did not warm the cache"

# 5) 'why' on a timed-out root: never cached, so the story is "no
# entry" plus the live run's timeout marker -- and still no cache
# entry afterwards.
bin/wtest why hang.w > why3.txt 2>/dev/null || fail "wtest why hang.w exited nonzero"
grep -q "^cache: no entry for this root" why3.txt || fail "why: hang.w cache line wrong"
grep -q "^closure: unavailable -- live 'bin/wv2 deps' run failed: timed out twice (budget 400ms; timeouts are never cached)$" why3.txt || fail "why: timeout marker missing"
grep -q "x86 hang.w" bin/.wtest_deps_cache && fail "why persisted a timeout"

# 6) An arch-prefixed root id, and the usage line documenting 'why'.
bin/wtest why x64 ok.w > why4.txt 2>/dev/null || fail "wtest why x64 exited nonzero"
grep -q "^wtest: why root 'x64 ok.w'$" why4.txt || fail "why: arch-prefixed header wrong"
grep -q "^compile root of: no target in this manifest compiles this (arch, file) pair -- rule (b) never consults it$" why4.txt || fail "why: unknown-pair line missing"
bin/wtest why > /dev/null 2>usage.txt && fail "bare 'wtest why' succeeded"
grep -q "wtest why \[<arch>\] <file.w> \[-f manifest.json\]" usage.txt || fail "usage does not document 'wtest why'"

echo "wtest_why_scratch_test: OK"
