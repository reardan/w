#!/bin/sh
# Regression fixture for timeout-shaped 'bin/wv2 deps' failures
# (tools/test_map.w; docs/projects/ai_tooling_next_steps.md 2026-07-29
# U4/U5): under parallel load a deps shell-out can exceed its
# process_run budget, and the timeout used to be persisted as an 'X'
# cache entry keyed to the root's content hash — silently disabling
# closure (and per-arch verify) selection until the stale line was
# hand-deleted. Now a timeout is retried once immediately, never
# persisted (only real nonzero compile exits are), and every failed
# shell-out prints one stderr line naming its root.
#
# Uses a scratch checkout with a FAKE bin/wv2 (a shell script keyed on
# the root path) and a small WTEST_DEPS_TIMEOUT_MS so the timeout path
# runs in under a second instead of 120s per attempt.
set -e

repo_root=$(pwd)
wtest="$repo_root/bin/wtest"
if [ ! -x "$wtest" ]; then
	echo "wtest_timeout_scratch_test: bin/wtest must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/bin"
ln -s "$wtest" "$dir/bin/wtest"

# The fake compiler: 'bin/wv2 deps <root>' behavior keyed on the root.
#   w.w      -> instant success (the seed closure; keeps the seed
#               residue rule quiet)
#   slow.w   -> sleeps past the budget on the FIRST call, succeeds on
#               the retry
#   hang.w   -> always sleeps past the budget (both attempts time out)
#   broken.w -> a real nonzero compile exit (the persistable flavor)
# Every call appends its root to calls.log so attempt counts are
# assertable.
cat > "$dir/bin/wv2" <<'EOF'
#!/bin/sh
root="$2"
echo "$root" >> calls.log
case "$root" in
	slow.w)
		if [ ! -f slow_seen ]; then
			touch slow_seen
			sleep 2
		fi
		echo "slow.w"
		echo "dep.w"
		;;
	hang.w)
		sleep 2
		;;
	broken.w)
		echo "broken.w:1:1: error: fixture compile failure" >&2
		exit 1
		;;
	*)
		echo "$root"
		;;
esac
EOF
chmod +x "$dir/bin/wv2"

printf 'int main():\n\treturn 0\n' > "$dir/w.w"
echo 'int dep = 1' > "$dir/dep.w"
echo 'import dep' > "$dir/slow.w"
echo 'import dep' > "$dir/hang.w"
echo 'import dep' > "$dir/broken.w"

cat > "$dir/build.json" <<'EOF'
{
	"targets": [
		{
			"name": "slow_t",
			"steps": [
				{"cmd": ["bin/wv2", "slow.w", "-o", "bin/slow"]}
			]
		},
		{
			"name": "hang_t",
			"steps": [
				{"cmd": ["bin/wv2", "hang.w", "-o", "bin/hang"]}
			]
		},
		{
			"name": "broken_t",
			"steps": [
				{"cmd": ["bin/wv2", "broken.w", "-o", "bin/broken"]}
			]
		}
	]
}
EOF

cd "$dir"
WTEST_DEPS_TIMEOUT_MS=500
export WTEST_DEPS_TIMEOUT_MS

fail() {
	echo "wtest_timeout_scratch_test: FAIL: $1" >&2
	exit 1
}

# 1) Cold run. slow.w times out once and succeeds on the retry (its
# closure selection survives within the same run); hang.w times out
# twice (falls back LOUDLY and is NOT persisted); broken.w really
# fails (persisted as an 'X' entry, exactly as before).
out=$(bin/wtest changed dep.w 2>err.txt)
echo "$out" | grep -qx slow_t || fail "retry did not recover slow.w's closure selection"
echo "$out" | grep -qx hang_t && fail "hang_t selected without a computable closure"
grep -q "wtest: warning: 'bin/wv2 deps' timed out for root 'x86 slow.w'; retrying once" err.txt || fail "no retry warning for slow.w"
grep -q "wtest: warning: 'bin/wv2 deps' timed out again for root 'x86 hang.w'; giving up for this run (timeouts are never cached)" err.txt || fail "no give-up warning for hang.w"
grep -q "wtest: warning: 'bin/wv2 deps' failed for root 'x86 broken.w'" err.txt || fail "no failure warning for broken.w"
grep -q "^R x86 slow.w$" bin/.wtest_deps_cache || fail "slow.w's retried closure was not cached"
grep -q "^X x86 broken.w$" bin/.wtest_deps_cache || fail "broken.w's real compile failure was not cached"
grep -q "x86 hang.w" bin/.wtest_deps_cache && fail "hang.w's timeout was persisted to the cache"
[ "$(grep -cx 'slow.w' calls.log)" = 2 ] || fail "expected exactly 2 slow.w attempts (timeout + retry)"
[ "$(grep -cx 'hang.w' calls.log)" = 2 ] || fail "expected exactly 2 hang.w attempts (timeout + retry)"

# 2) Next run: slow.w is warm (no new attempt), broken.w's persisted
# failure holds (no new attempt), and hang.w RETRIES because its
# timeout was never cached.
: > calls.log
out=$(bin/wtest changed dep.w 2>err.txt)
grep -qx 'slow.w' calls.log && fail "warm slow.w closure was recomputed"
grep -qx 'broken.w' calls.log && fail "persisted broken.w failure was retried without a content change"
[ "$(grep -cx 'hang.w' calls.log)" = 2 ] || fail "timed-out hang.w was not retried on the next run"
echo "$out" | grep -qx slow_t || fail "warm rerun lost slow_t"

# 3) Load lifts: hang.w stops sleeping and the VERY NEXT run computes
# its closure (a persisted 'X' entry would have blocked this until
# hang.w's content changed). The new bin/wv2 content also retries
# broken.w, per the X-entry validation.
cat > bin/wv2 <<'EOF'
#!/bin/sh
root="$2"
echo "$root" >> calls.log
echo "$root"
echo "dep.w"
EOF
chmod +x bin/wv2
out=$(bin/wtest changed dep.w 2>err.txt)
echo "$out" | grep -qx hang_t || fail "hang_t still unselected after the load lifted"
echo "$out" | grep -qx broken_t || fail "broken_t not retried after bin/wv2 changed"
grep -q "timed out" err.txt && fail "timeout warning still fired after the load lifted"

echo "wtest_timeout_scratch_test: OK"
