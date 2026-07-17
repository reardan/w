#!/bin/sh
# merge_manifest.sh: resolve a build.json merge conflict by regeneration.
#
# build.json is GENERATED (tools/wbuildgen.w merges build.base.json with
# the conventional test targets derived from the tree); hand-merging its
# hunks is never correct. During a conflicted merge/rebase, run this
# script instead of resolving hunks: it regenerates build.json via
# './wbuild manifest' from the already-merged build.base.json and tree,
# then stages the result. If build.base.json itself is conflicted,
# resolve it first — the generator reads it.
#
# Optional local wiring as a git merge driver, so 'git merge' resolves
# build.json automatically. This is LOCAL configuration — .git/config and
# .git/info/attributes are never committed; do not add it to tracked
# .gitattributes, because a merge driver is a config-side trust decision:
#   git config merge.wmanifest.name "regenerate build.json via wbuildgen"
#   git config merge.wmanifest.driver "tools/merge_manifest.sh %A"
#   echo 'build.json merge=wmanifest' >> .git/info/attributes
# When git invokes the driver, $1 is the temp file the resolved content
# must land in, so the freshly generated build.json is copied there;
# when run by hand (no argument), the result is staged instead.
set -e
cd "$(dirname "$0")/.."
./wbuild manifest
if [ -n "$1" ]; then
	cp build.json "$1"
else
	git add build.json
fi
