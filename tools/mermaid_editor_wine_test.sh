#!/bin/sh
# Opt-in qualification of the Windows Mermaid editor (bin/wmermaid_editor_win.exe)
# under wine's X11 driver on Xvfb, driven by real XTest pointer and key
# events (tools/mermaid_editor_ui_driver.w --wine). wine turns them into
# Win32 input messages, so this exercises the win32 window backend, WGL,
# the wide-character file API and the editor's save guard as a Windows
# build. It is not a native Windows run: no DWM, Explorer, real IME or
# screen reader (docs/projects/mermaid_desktop_qualification.md).
#
#   tools/mermaid_editor_wine_test.sh [--dpi N] [--only WORKFLOW]
#
# --dpi N runs at N dots per inch (144 = 150%, 192 = 200%) in a prefix of
# its own: the editor is per-monitor DPI aware, so its window, input and
# screenshot are N/96 times the logical size, and the driver scales its
# pointer coordinates to match. With no --dpi, both 96 and 144 run.
# Needs: wine (64-bit), Xvfb, libX11 and libXtst. Run from the repository
# root; `./wbuild mermaid_editor_wine_test` builds the inputs first.
# Fails when anything is missing: a skipped run is never counted as a pass.
set -eu
for tool in wine wineserver Xvfb; do
	command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
DPIS="96 144"
if [ "${1:-}" = "--dpi" ]; then DPIS=$2; shift 2; fi
ROOT=$(pwd)
WORK=$(mktemp -d /tmp/wmw.XXXXXX)
PIDS=""
cleanup() {
	for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
	for dpi in $DPIS; do WINEPREFIX="$ROOT/bin/mermaid-wine-prefix-$dpi" wineserver -k 2>/dev/null || true; done
	if [ -z "${KEEP:-}" ]; then rm -rf "$WORK"; else echo "kept $WORK" >&2; fi
}
trap cleanup EXIT INT TERM
DISPLAY_NUMBER=$((190 + $$ % 100))
# Room for a 200% window (2560x1600 client area).
Xvfb ":$DISPLAY_NUMBER" -screen 0 2800x1800x24 -nolisten tcp >"$WORK/xvfb.log" 2>&1 &
PIDS="$PIDS $!"
export DISPLAY=":$DISPLAY_NUMBER"
export WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
# wine converts argv with the Unix locale: keep it UTF-8 for non-ASCII paths.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
cd "$ROOT"
for dpi in $DPIS; do
	# A private prefix per DPI: the user's ~/.wine is never touched, and a
	# stale or half-initialised shared prefix cannot break the run.
	export WINEPREFIX="$ROOT/bin/mermaid-wine-prefix-$dpi"
	wineboot -i >"$WORK/wineboot-$dpi.log" 2>&1 || { cat "$WORK/wineboot-$dpi.log" >&2; exit 1; }
	# The display scale wine reports (winecfg's "Screen resolution").
	wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1
	wine reg add 'HKCC\Software\Fonts' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1
	wineserver -w
	scale=$(awk "BEGIN { print $dpi / 96 }")
	echo "wine at $dpi DPI (scale $scale)"
	bin/mermaid_editor_ui_driver --wine --scale "$scale" "$@"
	wineserver -k 2>/dev/null || true
done
