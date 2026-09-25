#!/bin/sh
# Build a W GPU program with an embedded pre-compiled cubin (opt-in; see
# docs/projects/cuda.md "Execution notes (cubin embedding)"). The W
# compiler never runs external tools, so this scripts the two-step flow:
#   1. compile once with --ptx=<out>.ptx to dump the kernel module,
#   2. ptxas -arch=<arch> <out>.ptx -o <out>.cubin,
#   3. recompile with --cubin-file=<out>.cubin (PTX stays embedded as the
#      fallback when the running GPU rejects the cubin).
#
# usage: tools/cuda/build_cubin.sh <arch|native> <src.w> <out> [wv2 flags...]
#   arch    sm_XX for ptxas, or "native" (nvidia-smi's compute capability
#           of GPU 0), or "wrong" (an arch GPU 0 cannot run — for tests)
# env: WV2 (default bin/wv2), PTXAS (default ptxas)
set -e
if [ $# -lt 3 ]; then
	echo "usage: $0 <arch|native|wrong> <src.w> <out> [wv2 flags...]" >&2
	exit 2
fi
arch=$1
src=$2
out=$3
shift 3
WV2=${WV2:-bin/wv2}
PTXAS=${PTXAS:-ptxas}
case "$arch" in
native|wrong)
	cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | tr -d ' .')
	if [ -z "$cap" ]; then
		echo "$0: cannot query the GPU compute capability" >&2
		exit 1
	fi
	if [ "$arch" = native ]; then
		arch=sm_$cap
	elif [ "${cap%?}" = 5 ]; then
		# SASS only runs on its own major version: pick another major.
		arch=sm_75
	else
		arch=sm_52
	fi
	;;
esac
"$WV2" x64 --quiet "$@" "$src" -o "$out" --ptx="$out.ptx"
"$PTXAS" -arch="$arch" "$out.ptx" -o "$out.cubin"
"$WV2" x64 --quiet "$@" "$src" -o "$out" --cubin-file="$out.cubin"
