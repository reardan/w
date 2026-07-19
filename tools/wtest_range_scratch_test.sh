#!/bin/sh
# Self-contained fixture for bin/wtest's commit-ranged selection (wave
# plan C task 4b, tools/test_map.w, issue #251 direction 4b: 'wtest
# changed A..B'). Mirrors tools/wtest_defhash_scratch_test.sh's
# throwaway-git-repo pattern for the same reason: this feature's own
# machinery shells out to real git plumbing (git diff, git show, git
# merge-base, git rev-parse, git cat-file) that only means something
# against real commits and a real compilable root, not another
# tests/wtest/ '-f manifest.json' fixture.
#
# The scratch repo gets its own symlinked copies of bin/wv2, bin/wtest,
# and the lib/ structures/ code_generator/ trees for the same reason
# wtest_defhash_scratch_test.sh does: compiling even a two-function
# program needs all three reachable at the scratch repo's own relative
# paths (compiler/compiler.w's cold-start auto-import of
# structures.hash_table / structures.w_list).
set -e

repo_root=$(pwd)
wv2="$repo_root/bin/wv2"
wtest="$repo_root/bin/wtest"
if [ ! -x "$wv2" ] || [ ! -x "$wtest" ]; then
	echo "wtest_range_scratch_test: bin/wv2 and bin/wtest must be built first" >&2
	exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

mkdir -p "$dir/bin"
ln -s "$wv2" "$dir/bin/wv2"
ln -s "$wtest" "$dir/bin/wtest"
ln -s "$repo_root/lib" "$dir/lib"
ln -s "$repo_root/structures" "$dir/structures"
ln -s "$repo_root/code_generator" "$dir/code_generator"

cat > "$dir/build.json" <<'EOF'
{
	"targets": [
		{
			"name": "scratch_target",
			"steps": [
				{"cmd": ["bin/wv2", "scratch_root.w", "-o", "bin/scratch_out"]}
			]
		}
	]
}
EOF

cat > "$dir/scratch_root.w" <<'EOF'
import scratch_lib

int main():
	return scratch_lib_add(1, 2)
EOF

cat > "$dir/scratch_lib.w" <<'EOF'
int scratch_lib_add(int a, int b):
	return a + b
EOF

# A second .w file present from the first commit, deleted partway
# through the history below -- exercises "a file deleted across the
# range" (task item 2) without ever touching scratch_lib.w, whose own
# closure-membership assertions must stay independent of it.
cat > "$dir/bystander.w" <<'EOF'
int bystander_unused():
	return 0
EOF

cd "$dir"
git init -q
git config user.email test@example.com
git config user.name test
git add -A
git commit -q -m "c0: initial commit"
c0=$(git rev-parse HEAD)

fail() {
	echo "wtest_range_scratch_test: FAIL: $1" >&2
	exit 1
}

# --- c1: comment-only edit to scratch_lib.w ---------------------------
printf '\n# a trailing comment, no behavior change\n' >> scratch_lib.w
git commit -qam "c1: comment-only edit"
c1=$(git rev-parse HEAD)

# --- c2: a real definition change to scratch_lib.w --------------------
cat > scratch_lib.w <<'EOF'
int scratch_lib_add(int a, int b):
	return a + b + 1


# a trailing comment, no behavior change
EOF
git commit -qam "c2: real edit"
c2=$(git rev-parse HEAD)

# --- c3: delete bystander.w (present since c0, untouched until now) ---
git rm -q bystander.w
git commit -qam "c3: delete bystander.w"
c3=$(git rev-parse HEAD)

# ===== Two-dot range c0..c1 (comment-only): plain selection still ====
# picks up scratch_target (rule (b), unrefined); --defhash skips it (its
# recorded definitions are provably identical at both ends of the
# range) -- the same "plain selects, --defhash skips" contrast
# wtest_defhash_scratch_test.sh proves for HEAD-vs-worktree, now proven
# rev-vs-rev via an explicit closed range.
out=$(bin/wtest changed "$c0..$c1")
echo "$out" | grep -qx scratch_target || fail "c0..c1 (comment-only): plain selection dropped scratch_target"
out=$(bin/wtest changed --defhash "$c0..$c1")
echo "$out" | grep -qx scratch_target && fail "c0..c1 (comment-only): --defhash still selected scratch_target"

# ===== Two-dot range c1..c2 (real edit): --defhash must NOT skip =====
out=$(bin/wtest changed "$c1..$c2")
echo "$out" | grep -qx scratch_target || fail "c1..c2 (real edit): plain selection dropped scratch_target"
out=$(bin/wtest changed --defhash "$c1..$c2")
echo "$out" | grep -qx scratch_target || fail "c1..c2 (real edit): --defhash did not select scratch_target"

# ===== Three-dot range c0...c2 (linear history, so merge-base(c0,c2) =
# c0 -- same comparison as the two-dot c0..c2 form): a real edit lives
# in the range, so --defhash must not skip it.
out=$(bin/wtest changed --defhash "$c0...$c2")
echo "$out" | grep -qx scratch_target || fail "c0...c2 (three-dot, real edit inside): --defhash did not select scratch_target"

# ===== Deleted file across a range: falls back to the documented ====
# residue rule (metadata_check + tests) exactly like an ordinary
# deleted-file path does today -- not a closure scan, and not a crash.
# The scratch manifest defines neither target, so wtest_add's own
# "target not in this manifest" fallback swallows the actual printed
# selection (0 targets, same as wtest_defhash_scratch_test.sh's own
# baseline note about unmodified files) -- --verbose's notes are the
# only way to observe the rule firing in this minimal fixture.
out=$(bin/wtest changed --verbose "$c2..$c3" 2>&1 >/dev/null)
echo "$out" | grep -qF "bystander.w -> metadata_check" || fail "deleted file in range: metadata_check residue rule did not fire"
echo "$out" | grep -qF "bystander.w -> tests" || fail "deleted file in range: tests residue rule did not fire"

# ===== Open range 'A..' (single revision versus the worktree, task ===
# item 1's "single rev meaning rev..worktree"): an uncommitted,
# comment-only worktree edit on top of c3 must select plainly and be
# skipped under --defhash, exactly like the closed comment-only case
# above -- proving the worktree-as-right-side path (wtest_range_right
# left at 0) instead of an explicit commit.
printf '\n# another comment-only edit, uncommitted\n' >> scratch_lib.w
out=$(bin/wtest changed "$c3..")
echo "$out" | grep -qx scratch_target || fail "c3.. (open range, comment-only worktree edit): plain selection dropped scratch_target"
out=$(bin/wtest changed --defhash "$c3..")
echo "$out" | grep -qx scratch_target && fail "c3.. (open range, comment-only worktree edit): --defhash still selected scratch_target"
git checkout -q -- scratch_lib.w

# ===== No range argument: byte-identical to a plain path list =======
# ("commit-ranged selection is opt-in via a positional '..' argument,
# ordinary paths are untouched" -- scratch_lib.w never contains ".." so
# it can never be mistaken for one).
out=$(bin/wtest changed scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "no-range baseline: plain path selection dropped scratch_target"

# ===== Invalid revision: a hard error, not a silent fallback ========
err=$(bin/wtest changed "not_a_real_rev..$c3" 2>&1 >/dev/null) && fail "invalid range: wtest exited 0"
echo "$err" | grep -qF "invalid revision in range" || fail "invalid range: wrong/missing error message"

echo "wtest_range_scratch_test: OK"
