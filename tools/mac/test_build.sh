#!/bin/sh
# Native discovery, transitive selection, host compiler and cross-target checks.
set -eu
cd "$(dirname "$0")/../.."
fixture=bin/mac_build_dir
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/a" "$fixture/empty"
printf 'nested\n' > "$fixture/a/nested.w"
printf 'file\n' > "$fixture/b.txt"
ln -s a "$fixture/link"
bin/build_host_test_darwin
bin/wexec_darwin --list > "$fixture/targets"
grep -qx wprof "$fixture/targets"
grep -qx wtest "$fixture/targets"
grep -qx build_host_test_darwin "$fixture/targets"
# A small explicit manifest keeps this gate fast; no literal step names leaf.w.
cat > "$fixture/manifest.json" <<'JSON'
{"targets":[
 {"name":"transitive_native","steps":[{"cmd":["bin/wv2","arm64_darwin","tests/wtest/host/root.w","-o","bin/mac_host_transitive"]},{"cmd":["bin/mac_host_transitive"]}]},
 {"name":"cross_x86","steps":[{"cmd":["bin/wv2","tests/wtest/host/root.w","-o","bin/mac_host_x86"]}]},
 {"name":"cross_x64","steps":[{"cmd":["bin/wv2","x64","tests/wtest/host/root.w","-o","bin/mac_host_x64"]}]},
 {"name":"cross_arm64","steps":[{"cmd":["bin/wv2","arm64","tests/wtest/host/root.w","-o","bin/mac_host_arm64"]}]},
 {"name":"cross_win64","steps":[{"cmd":["bin/wv2","win64","tests/wtest/host/root.w","-o","bin/mac_host_win64"]}]},
 {"name":"cross_wasm","steps":[{"cmd":["bin/wv2","wasm","tests/wtest/host/root.w","-o","bin/mac_host_wasm"]}]}
]}
JSON
bin/wtest changed -f "$fixture/manifest.json" tests/wtest/host/leaf.w > "$fixture/selected"
grep -qx transitive_native "$fixture/selected"
bin/wtest archs -f "$fixture/manifest.json" tests/wtest/host/leaf.w --check > "$fixture/checks"
for arch in x86 x64 arm64 arm64_darwin win64 wasm; do
	grep -q "$arch tests/wtest/host/root.w" "$fixture/checks"
done
bin/wtest changed -f "$fixture/manifest.json" tests/wtest/host/leaf.w --run > "$fixture/run"
grep -q 'host transitive OK' "$fixture/run"
# Unsupported default-platform execution fails during planning, not exec(ELF).
if bin/wexec_darwin lib_test > "$fixture/unavailable" 2>&1; then
	echo 'mac build: Linux runtime target unexpectedly accepted' >&2
	exit 1
fi
grep -q 'outside the qualified native macOS suite' "$fixture/unavailable"
# Ad-hoc compilation uses the same host compiler and target selector.
bin/wexec_darwin arm64_darwin tests/wtest/host/root.w > "$fixture/direct"
bin/root_arm64_darwin > "$fixture/direct-run"
grep -q 'host transitive OK' "$fixture/direct-run"
cp tests/wtest/host/root.w "$fixture/rejected_test.w"
if bin/wexec_darwin "$fixture/rejected_test.w" > "$fixture/rejected" 2>&1; then
	echo 'mac build: ad-hoc Linux runtime test unexpectedly accepted' >&2
	exit 1
fi
grep -q 'test runtime is not native macOS' "$fixture/rejected"
# Directory content participates in cache keys on Darwin.
cat > "$fixture/cache.json" <<'JSON'
{"targets":[{"name":"directory_hash","inputs":["bin/mac_build_dir/a/"],"steps":[{"cmd":["echo","directory hashed"]}]}]}
JSON
bin/wexec_darwin -f "$fixture/cache.json" directory_hash > "$fixture/cache-first"
bin/wexec_darwin -f "$fixture/cache.json" directory_hash > "$fixture/cache-second"
grep -q 'directory_hash (cached)' "$fixture/cache-second"
printf 'changed\n' >> "$fixture/a/nested.w"
bin/wexec_darwin -f "$fixture/cache.json" directory_hash > "$fixture/cache-third"
if grep -q 'directory_hash (cached)' "$fixture/cache-third"; then
	echo 'mac build: directory change did not invalidate cache' >&2
	exit 1
fi
echo 'mac build tooling OK'
