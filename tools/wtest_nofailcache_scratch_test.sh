#!/bin/sh
# Regression fixture for the deps-failure caching bug (tools/test_map.w,
# docs/projects/ai_tooling_next_steps.md 2026-07-28 residue): the derived
# seed-graph rule caches 'bin/wv2 deps w.w' against w.w's content hash,
# and it used to cache FAILURES too — running bin/wtest while bin/wv2 was
# merely missing wrote an 'X' entry that silently pinned the rule to its
# coarse compiler-tree prefix floor until w.w itself changed, even after
# bin/wv2 reappeared. Failures are no longer cached: the fallback is
# announced on stderr and retried on the next run.
#
# Like tools/wtest_defhash_scratch_test.sh, this needs its own scratch
# checkout (a throwaway directory with a tiny w.w and a fixture
# build.json, plus symlinked lib/ structures/ code_generator/ trees for
# the auto-imported runtime) because the scenario is "bin/wv2 is
# missing, then comes back" — the real repo's bin/wv2 cannot be hidden
# while other targets run in parallel.
set -e

repo_root=$(pwd)
wv2="$repo_root/bin/wv2"
wtest="$repo_root/bin/wtest"
if [ ! -x "$wv2" ] || [ ! -x "$wtest" ]; then
	echo "wtest_nofailcache_scratch_test: bin/wv2 and bin/wtest must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/bin"
ln -s "$wtest" "$dir/bin/wtest"
ln -s "$repo_root/lib" "$dir/lib"
ln -s "$repo_root/structures" "$dir/structures"
ln -s "$repo_root/code_generator" "$dir/code_generator"
# bin/wv2 is deliberately NOT linked yet: the first runs below exercise
# the "compiler temporarily missing" failure path.

cat > "$dir/w.w" <<'EOF'
import lib.file

int main():
	return 0
EOF

# No step-less umbrella target here: this fixture is about the seed
# rule, not the large-selection collapse.
cat > "$dir/build.json" <<'EOF'
{
	"targets": [
		{
			"name": "verify",
			"steps": [
				{"cmd": ["true"]}
			]
		},
		{
			"name": "self_host_warning_test",
			"steps": [
				{"cmd": ["true"]}
			]
		},
		{
			"name": "parser_generator_w_test",
			"steps": [
				{"cmd": ["true"]}
			]
		},
		{
			"name": "metadata_check",
			"steps": [
				{"cmd": ["true"]}
			]
		},
		{
			"name": "probe_target",
			"steps": [
				{"cmd": ["true", "lib/file.w"]}
			]
		}
	]
}
EOF

cd "$dir"

fail() {
	echo "wtest_nofailcache_scratch_test: FAIL: $1" >&2
	exit 1
}

# 1) bin/wv2 missing: the seed-graph rule must fall back LOUDLY to the
# prefix floor (lib/file.w is in the tiny w.w's closure, but the
# closure cannot be computed), keep the literal selection, and NOT
# persist the failure.
out=$(bin/wtest changed lib/file.w 2>err.txt)
grep -q "wtest: warning: 'bin/wv2 deps' failed" err.txt || fail "no fallback warning while bin/wv2 was missing"
echo "$out" | grep -qx verify && fail "verify selected with no computable seed closure"
echo "$out" | grep -qx probe_target || fail "literal selection lost while bin/wv2 was missing"
if [ -f bin/.wtest_deps_cache ]; then
	grep -q "^X " bin/.wtest_deps_cache && fail "deps failure was persisted as an 'X' cache entry"
fi

# 2) A second run without bin/wv2 retries (and warns) instead of
# silently reusing a cached failure.
out=$(bin/wtest changed lib/file.w 2>err.txt)
grep -q "wtest: warning: 'bin/wv2 deps' failed" err.txt || fail "second run did not retry / warn"

# 3) bin/wv2 back: the VERY NEXT run must recover the derived seed
# graph (the old 'X' entry semantics kept the rule pinned to the
# prefix floor here until w.w itself changed).
ln -s "$wv2" bin/wv2
out=$(bin/wtest changed lib/file.w 2>err.txt)
echo "$out" | grep -qx verify || fail "seed rule still on the prefix floor after bin/wv2 reappeared"
echo "$out" | grep -qx self_host_warning_test || fail "self_host_warning_test missing after recovery"
grep -q "wtest: warning: 'bin/wv2 deps' failed" err.txt && fail "fallback warning still fired with bin/wv2 present"
grep -q "^R x86 w.w" bin/.wtest_deps_cache || fail "successful seed closure was not cached"

# 4) Warm rerun keeps the derived selection (cache hit, no recompute).
out=$(bin/wtest changed lib/file.w 2>err.txt)
echo "$out" | grep -qx verify || fail "warm rerun lost verify"

# 5) A stale 'X' failure entry written by an older bin/wtest build is
# ignored on load (never pins the rule), whatever its recorded hash.
printf 'X x86 w.w\nH 0123456789abcdef\n' > bin/.wtest_deps_cache
out=$(bin/wtest changed lib/file.w 2>err.txt)
echo "$out" | grep -qx verify || fail "a stale legacy 'X' entry pinned the seed rule"

echo "wtest_nofailcache_scratch_test: OK"
