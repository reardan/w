#!/bin/sh
# 'wtest cache' pre-warm + cold-run progress/ETA fixture
# (tools/test_map.w; docs/projects/ai_tooling_next_steps.md 2026-07-29:
# cold bin/.wtest_deps_cache builds exceeded 20 minutes wall under
# parallel load — './wbuild wtest_cache' pays that cost deliberately,
# and the cold progress lines carry an extrapolated time-left
# estimate). A fake bin/wv2 keeps the fixture's deps runs instant; 22
# compile roots (+ the "x86 w.w" seed root wtest cache always warms)
# cross the 20-root progress-line threshold so the ETA line is
# observable.
set -e

repo_root=$(pwd)
wtest="$repo_root/bin/wtest"
if [ ! -x "$wtest" ]; then
	echo "wtest_cache_scratch_test: FAIL: bin/wtest must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/bin"
ln -s "$wtest" "$dir/bin/wtest"

printf 'int main():\n\treturn 0\n' > "$dir/w.w"
echo 'int dep = 1' > "$dir/dep.w"

# 22 conventional compile targets r01_t..r22_t rooted at r01.w..r22.w;
# every fake closure contains dep.w, so one changed path selects
# through all of them.
{
	printf '{\n\t"targets": [\n'
	i=1
	while [ "$i" -le 22 ]; do
		name=$(printf 'r%02d' "$i")
		printf '\t\t{"name": "%s_t", "steps": [{"cmd": ["bin/wv2", "%s.w", "-o", "bin/%s"]}]}' "$name" "$name" "$name"
		if [ "$i" -lt 22 ]; then
			printf ','
		fi
		printf '\n'
		echo 'import dep' > "$dir/$name.w"
		i=$((i + 1))
	done
	printf '\t]\n}\n'
} > "$dir/build.json"

cd "$dir"

fail() {
	echo "wtest_cache_scratch_test: FAIL: $1" >&2
	exit 1
}

# 0) No bin/wv2: warming is impossible and must say so, loudly.
bin/wtest cache > out.txt 2> err.txt && fail "wtest cache succeeded without bin/wv2"
grep -q "wtest: error: cannot warm the deps cache: bin/wv2 not found" err.txt || fail "no bin/wv2-missing error"

# A bad argument is a usage error, and the usage names the subcommand.
bin/wtest cache bogus > /dev/null 2> err.txt && fail "unexpected 'wtest cache' argument accepted"
grep -q "wtest cache \[-f manifest.json\]" err.txt || fail "usage does not document 'wtest cache'"

cat > bin/wv2 <<'EOF'
#!/bin/sh
root="$2"
echo "$root" >> calls.log
echo "$root"
echo "dep.w"
EOF
chmod +x bin/wv2

# 1) Cold pre-warm: banner + a 20/23 progress line with the elapsed /
# time-left estimate on stderr, a summary on stdout, one deps run per
# root (22 compile roots + the seed root).
bin/wtest cache > out.txt 2> err.txt || fail "cold wtest cache failed"
grep -q "wtest: deps cache ready (23 roots)" out.txt || fail "no ready summary on stdout"
grep -q "wtest: building import-closure cache, 23 roots to compute" err.txt || fail "no cold banner"
grep -q "wtest: import-closure cache: 20/23 roots computed, " err.txt || fail "no progress line"
grep -q "s elapsed, ~" err.txt || fail "no elapsed time on the progress line"
grep -q " left" err.txt || fail "no time-left estimate on the progress line"
[ "$(grep -c . calls.log)" = 23 ] || fail "expected 23 deps runs, got $(grep -c . calls.log)"
grep -q "^R x86 w.w$" bin/.wtest_deps_cache || fail "seed root not warmed"
grep -q "^R x86 r22.w$" bin/.wtest_deps_cache || fail "compile root not warmed"

# 2) Warm rerun: revalidates, computes nothing, same summary.
: > calls.log
bin/wtest cache > out.txt 2> err.txt || fail "warm wtest cache failed"
grep -q "wtest: deps cache ready (23 roots)" out.txt || fail "warm rerun lost the summary"
grep -q "building import-closure cache" err.txt && fail "warm rerun went cold"
[ ! -s calls.log ] || fail "warm rerun ran bin/wv2 deps"

# 3) A selection after the pre-warm is warm: no banner, no deps runs,
# closure selection intact (including through the pre-warmed seed
# root, which 'wtest changed' consults for every .w path).
out=$(bin/wtest changed dep.w 2>err.txt)
grep -q "building import-closure cache" err.txt && fail "changed run after pre-warm went cold"
[ ! -s calls.log ] || fail "changed run after pre-warm ran bin/wv2 deps"
echo "$out" | grep -qx r01_t || fail "closure selection missing r01_t after pre-warm"
echo "$out" | grep -qx r22_t || fail "closure selection missing r22_t after pre-warm"

echo "wtest_cache_scratch_test: OK"
