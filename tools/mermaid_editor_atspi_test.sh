#!/bin/sh
# Opt-in qualification of the Mermaid editor against real AT-SPI 2 and,
# with --orca, the Orca screen reader, all headless:
#   Xvfb + a private session bus + at-spi-bus-launcher (+ speech-dispatcher's
#   dummy module and `orca --debug-file`).
# Needs: xvfb at-spi2-core python3-pyatspi gir1.2-atspi-2.0 libxtst6 (and orca
# speech-dispatcher for --orca). Run from the repository root after
# `./wbuild wmermaid_editor`; `./wbuild mermaid_editor_atspi_test` does both.
# Fails when anything is missing: a skipped run is never counted as a pass.
set -eu
ORCA=0
if [ "${1:-}" = "--orca" ]; then ORCA=1; fi
PYTHON=${PYTHON:-python3.12}
command -v "$PYTHON" >/dev/null || PYTHON=python3
for tool in Xvfb dbus-daemon /usr/libexec/at-spi-bus-launcher; do
	command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
"$PYTHON" -c 'import gi; gi.require_version("Atspi", "2.0")' || { echo "missing gir1.2-atspi-2.0 for $PYTHON" >&2; exit 1; }
ROOT=$(pwd)
# Short paths: AT-SPI and speech-dispatcher sockets live under these.
WORK=$(mktemp -d /tmp/wma.XXXXXX)
export HOME="$WORK" XDG_RUNTIME_DIR="$WORK/r" XDG_CONFIG_HOME="$WORK/c"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME"
PIDS=""
cleanup() {
	for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
	if [ -n "${DBUS_SESSION_BUS_PID:-}" ]; then kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true; fi
	if [ -z "${KEEP:-}" ]; then rm -rf "$WORK"; else echo "kept $WORK" >&2; fi
}
trap cleanup EXIT INT TERM
DISPLAY_NUMBER=$((90 + $$ % 100))
Xvfb ":$DISPLAY_NUMBER" -screen 0 1280x800x24 -nolisten tcp >"$WORK/xvfb.log" 2>&1 &
PIDS="$PIDS $!"
export DISPLAY=":$DISPLAY_NUMBER"
eval "$(dbus-launch --sh-syntax)"
export NO_AT_BRIDGE=0 GTK_MODULES=gail:atk-bridge
/usr/libexec/at-spi-bus-launcher --launch-immediately >"$WORK/atspi.log" 2>&1 &
PIDS="$PIDS $!"
sleep 1
ORCA_LOG=""
if [ "$ORCA" = 1 ]; then
	command -v orca >/dev/null || { echo "missing orca" >&2; exit 1; }
	mkdir -p "$XDG_CONFIG_HOME/speech-dispatcher"
	printf 'DefaultModule dummy\nAddModule "dummy" "sd_dummy" ""\nAudioOutputMethod "libao"\n' >"$XDG_CONFIG_HOME/speech-dispatcher/speechd.conf"
	ORCA_LOG="$WORK/orca.log"
	# Orca block-buffers its debug file; line-buffer it so speech can be
	# checked as it happens.
	"$PYTHON" -c 'import builtins, runpy, sys
real = builtins.open
def line_open(name, mode="r", buffering=-1, *rest, **named):
	if "w" in mode and "b" not in mode: buffering = 1
	return real(name, mode, buffering, *rest, **named)
builtins.open = line_open
path = sys.argv[1]
sys.argv = [path] + sys.argv[2:]
runpy.run_path(path, run_name="__main__")' "$(command -v orca)" --replace --debug-file="$ORCA_LOG" >"$WORK/orca.out" 2>&1 &
	PIDS="$PIDS $!"
	sleep 4
fi
cd "$ROOT"
if [ "$ORCA" = 1 ]; then
	"$PYTHON" -I tools/mermaid_editor_atspi_check.py "$ROOT/bin/wmermaid_editor" "$WORK/diagram.mmd" --orca "$ORCA_LOG"
else
	"$PYTHON" -I ${CHECK:-tools/mermaid_editor_atspi_check.py} "$ROOT/bin/wmermaid_editor" "$WORK/diagram.mmd"
fi
