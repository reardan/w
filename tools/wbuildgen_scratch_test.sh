#!/bin/sh
# Regression fixture for bin/wbuildgen's manifest write/check pair
# (docs/projects/ai_tooling_next_steps.md, 2026-07-25 manifest-race
# entry):
#   1. 'wbuildgen' (no --check) rewrites the manifest atomically via a
#      sibling '<out>.tmp' + rename(2), so a concurrent reader — the
#      manifest_check byte-compare, or bin/wexec parsing the manifest —
#      never sees a torn file;
#   2. a committed manifest that fails to parse gets its own distinct
#      --check message instead of the misleading "manifests differ in
#      formatting only".
# Mirrors tools/wtest_range_scratch_test.sh's throwaway-dir pattern:
# everything runs against a scratch --base/--out pair under mktemp,
# never the real build.json. The scratch dir has none of wbuildgen's
# scan directories (tests/, lib/, ...), so nothing is generated and the
# rendered output is deterministic.
set -e

repo_root=$(pwd)
wbuildgen="$repo_root/bin/wbuildgen"
if [ ! -x "$wbuildgen" ]; then
	echo "wbuildgen_scratch_test: bin/wbuildgen must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

fail() {
	echo "wbuildgen_scratch_test: FAIL: $1" >&2
	exit 1
}

cat > "$dir/base.json" <<'EOF'
{
	"targets": [
	]
}
EOF

cd "$dir"

# ===== Atomic rewrite: temp file + rename, sibling to --out. A stale =
# '<out>.tmp' sentinel must be overwritten and renamed away; were
# wbuildgen still writing out.json directly, the sentinel would
# survive the run untouched.
echo "sentinel" > out.json.tmp
"$wbuildgen" --base base.json --out out.json >/dev/null || fail "initial manifest write failed"
[ -f out.json ] || fail "manifest write produced no out.json"
[ -e out.json.tmp ] && fail "out.json.tmp left behind (write is not temp-file + rename)"

# ===== No reader ever sees a torn manifest: rewrite in a loop while ==
# --check (the manifest_check byte-compare) runs concurrently. The
# content never changes, so under an atomic rename every check must
# pass; the old in-place rewrite (open + truncate + write) let a
# concurrent check read a prefix of the file and fail spuriously.
(
	i=0
	while [ $i -lt 40 ]; do
		"$wbuildgen" --base base.json --out out.json >/dev/null || exit 1
		i=$((i + 1))
	done
) &
writer=$!
while kill -0 "$writer" 2>/dev/null; do
	"$wbuildgen" --check --base base.json --out out.json >/dev/null 2>check_err || {
		cat check_err >&2
		fail "concurrent --check saw a torn manifest mid-rewrite"
	}
done
wait "$writer" || fail "background manifest writer failed"

# ===== Distinct --check message for an unparseable committed manifest =
printf '{"targets": [' > out.json
err=$("$wbuildgen" --check --base base.json --out out.json 2>&1 >/dev/null) && fail "--check exited 0 on an unparseable manifest"
echo "$err" | grep -qF "committed manifest failed to parse: out.json" || fail "missing 'committed manifest failed to parse' message"
echo "$err" | grep -qF "manifests differ in formatting only" && fail "unparseable manifest still reported as formatting-only drift"

# ===== The formatting-only message still covers real formatting drift =
# (same parsed structure, different bytes), pinning the triage split.
printf '{"targets": []}' > out.json
err=$("$wbuildgen" --check --base base.json --out out.json 2>&1 >/dev/null) && fail "--check exited 0 on formatting drift"
echo "$err" | grep -qF "manifests differ in formatting only" || fail "missing formatting-only drift message"

echo "wbuildgen_scratch_test: OK"
