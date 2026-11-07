#!/bin/sh
# Opt-in native host regression: generators, freshness, fixpoint and cache inputs.
set -eu
case "$(uname -s)-$(uname -m)" in Linux-x86_64) ;; *) exit 0 ;; esac
original=$(sha256sum bin/wv2 | cut -d' ' -f1)
WBUILD_HOST=linux-x64 ./wbuild verify --no-cache grapheme_data >/dev/null
file bin/wv2_native bin/wexec_native bin/generate_grapheme_data_native | awk '/ELF 64-bit/{n++} END {exit n != 3}'
[ "$original" = "$(sha256sum bin/wv2 | cut -d' ' -f1)" ]
fixture=$(mktemp -d bin/native-cache-XXXXXX)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
printf first > "$fixture/input"
cat > "$fixture/manifest.json" <<JSON
{"targets":[{"name":"probe","inputs":["$fixture/input","bin/wv2_native"],"outputs":["$fixture/output"],"steps":[{"cmd":["cp","$fixture/input","$fixture/output"]}]}]}
JSON
WBUILD_HOST=linux-x64 bin/wexec_native -f "$fixture/manifest.json" probe >/dev/null
[ "$(cat "$fixture/output")" = first ]
printf second > "$fixture/input"
WBUILD_HOST=linux-x64 bin/wexec_native -f "$fixture/manifest.json" probe >/dev/null
[ "$(cat "$fixture/output")" = second ]
python3 tests/linux_native_signal_test.py
printf 'native Linux host qualification OK\n'
