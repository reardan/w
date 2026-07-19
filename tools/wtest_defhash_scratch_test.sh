#!/bin/sh
# Self-contained fixture for bin/wtest's --defhash refinement (wave plan C
# task 2g, tools/test_map.w). The '-f manifest.json' fixtures elsewhere in
# tests/wtest/ cover rule (a)/(c)/leaf-diff selection with synthetic
# "true"/"echo" steps and no real git history, but --defhash's own
# machinery shells out to 'git show HEAD:<path>' and 'bin/wv2 defhash',
# which only mean something against a real commit and a real compilable
# root -- hence a throwaway git repository instead of another -f fixture,
# per the wave plan's "self-contained git init-in-a-scratch-dir" note.
#
# The scratch repo gets its own symlinked copies of bin/wv2, bin/wtest,
# and the lib/ structures/ code_generator/ trees: link_impl unconditionally
# auto-imports structures.hash_table and structures.w_list before compiling
# any user file (compiler/compiler.w's cold-start auto-import block), and
# those transitively reach into lib/ and code_generator/integer.w, so even
# the two-function program below needs all three trees reachable at the
# scratch repo's own relative paths -- exactly like this repo's own
# build_relative_import_test (build.base.json) demonstrates a bare tmp dir
# with none of them fails with "cannot locate 'structures/hash_table.w'".
set -e

repo_root=$(pwd)
wv2="$repo_root/bin/wv2"
wtest="$repo_root/bin/wtest"
if [ ! -x "$wv2" ] || [ ! -x "$wtest" ]; then
	echo "wtest_defhash_scratch_test: bin/wv2 and bin/wtest must be built first" >&2
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

cd "$dir"
git init -q
git config user.email test@example.com
git config user.name test
git add -A
git commit -q -m "initial commit"

fail() {
	echo "wtest_defhash_scratch_test: FAIL: $1" >&2
	exit 1
}

# Sanity baseline: an unmodified file selects scratch_target under plain
# rule (b) closure selection -- this just proves the fixture itself (the
# manifest's compile step, the import from scratch_root.w) is wired up
# before trusting any skip/fallback assertion below. (An unmodified file
# is not a meaningful --defhash case on its own: HEAD and the worktree
# are byte-identical, so "unchanged" is the only correct answer, same as
# every other case below where the two are actually identical --
# comment-only edits included.)
out=$(bin/wtest changed scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "baseline (no --defhash) did not select scratch_target"

# Comment/formatting-only edit: --defhash must SKIP the import-closure
# target (defhash's own token-stream hash excludes comments/whitespace);
# without the flag, rule (b) keeps selecting it unconditionally -- the
# "default selection is byte-identical without the flag" property.
printf '\n# a trailing comment, no behavior change\n' >> scratch_lib.w
out=$(bin/wtest changed scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "comment-only edit: plain selection dropped scratch_target"
out=$(bin/wtest changed --defhash scratch_lib.w)
echo "$out" | grep -qx scratch_target && fail "comment-only edit: --defhash still selected scratch_target"

# Real edit: --defhash must fall back to full closure selection (the
# definition's own recorded hash actually changed).
git checkout -q -- scratch_lib.w
cat > scratch_lib.w <<'EOF'
int scratch_lib_add(int a, int b):
	return a + b + 1
EOF
out=$(bin/wtest changed --defhash scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "real edit: --defhash did not select scratch_target"

# Explicit-generics syntax ('T max[T](T a, T b):', docs/projects/
# generics.md): --defhash must fall back even on a comment-only edit,
# because a generic definition's body is invisible to 'bin/wv2 defhash'
# (compiler/compiler.w's defhash_main doc comment) -- a plain name/hash
# comparison of the OTHER (recorded) definitions would otherwise look
# "unchanged" no matter what changed inside the generic one.
git checkout -q -- scratch_lib.w
cat > scratch_lib.w <<'EOF'
int scratch_lib_add(int a, int b):
	return a + b


T scratch_lib_first[T](T a, T b):
	return a
EOF
git add scratch_lib.w
git commit -q -m "add an explicit-generics definition"
printf '\n# comment only, generics still present\n' >> scratch_lib.w
out=$(bin/wtest changed --defhash scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "generic-shaped content: --defhash skipped scratch_target on a comment-only edit"

# 'operator' overload syntax: same fallback, via the plain word check
# rather than the bracket check (wtest_defhash_risky_text, tools/test_map.w).
git checkout -q -- scratch_lib.w
cat > scratch_lib.w <<'EOF'
int scratch_lib_add(int a, int b):
	return a + b

# vec3 operator+(vec3 a, vec3 b): defined elsewhere in the real overload
EOF
git add scratch_lib.w
git commit -q -m "mention an operator overload"
printf '\n# another comment-only edit\n' >> scratch_lib.w
out=$(bin/wtest changed --defhash scratch_lib.w)
echo "$out" | grep -qx scratch_target || fail "operator-shaped content: --defhash skipped scratch_target on a comment-only edit"

echo "wtest_defhash_scratch_test: OK"
