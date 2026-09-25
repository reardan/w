#!/bin/sh
# GPU-less fixtures for cuda_cubin_embed_test (docs/projects/cuda.md
# "Execution notes (cubin embedding)"): write minimal stand-in cubins
# that satisfy (or deliberately fail) the compiler's --cubin-file checks
# without ptxas — a 64-byte ELF header (EM_CUDA = 190) followed by a
# string table holding a marker and the PTX dump's kernel names.
#
# usage: tools/cuda/fake_cubin.sh <module.ptx> <out-prefix>
#   <out-prefix>.good.cubin     every .entry name present
#   <out-prefix>.stale.cubin    last .entry name missing
#   <out-prefix>.notcuda.cubin  ELF with e_machine EM_X86_64 (62)
set -e
ptx=$1
out=$2
names=$(sed -n 's/.*\.entry \([A-Za-z0-9_]*\)(.*/\1/p' "$ptx")
if [ -z "$names" ]; then
	echo "$0: no .entry kernels in $ptx" >&2
	exit 1
fi
# header <e_machine octal escape>: ELF64 little-endian, zero-padded to 64
header() {
	printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000'
	printf '\002\000'"$1"'\000'
	i=0
	while [ $i -lt 44 ]; do
		printf '\000'
		i=$((i + 1))
	done
}
last=$(echo "$names" | tail -n 1)
{ header '\276'; printf '\000W_FAKE_CUBIN\000'; for n in $names; do printf '%s\000' "$n"; done; } > "$out.good.cubin"
{ header '\276'; printf '\000W_FAKE_CUBIN\000'; for n in $names; do [ "$n" = "$last" ] || printf '%s\000' "$n"; done; } > "$out.stale.cubin"
{ header '\076'; printf '\000W_FAKE_CUBIN\000'; for n in $names; do printf '%s\000' "$n"; done; } > "$out.notcuda.cubin"
