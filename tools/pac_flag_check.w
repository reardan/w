/*
pac_flag_check: W replacement for tools/pac_flag_check.sh (issue: bucket E
script retirement, docs/projects/sonnet_wave_plan_2026_07c.md task 2f).

Asserts the --pac=off|ret|full arm64 code-generation flag (docs/projects/
arm64.md) by inspecting compiled binaries: x86 hosts have no aarch64
objdump, so instead of disassembling we look for the exact little-endian
A64 instruction encodings pac_full_test.w's build must (or must not)
contain:

	pacia x30,x28 = 9e 03 c1 da   autia x30,x28 = 9e 13 c1 da
	paciza x0     = e0 23 c1 da   blraaz x0     = 1f 08 3f d6

and, for arm64_darwin, the Mach-O header's cpusubtype field (offset 8,
4 bytes) which the compiler marks CPU_SUBTYPE_ARM64E (0x81000002) only
under --pac=full.

Note on scope: despite the name, this is not a general ELF/Mach-O
reader. The original shell script never parsed section/program headers
or notes either -- it hex-dumped the whole file (od -An -v -tx1) and
grepped for byte substrings, plus one raw fixed-offset read for the
Mach-O binaries. That is all pac_flag_test actually needs, so that is
all this tool does: whole-file byte-pattern search, reusing
libs/asm/binary_reader.w's file-read and byte-pattern helpers (the same module the
disassembler tests use to pull a binary off disk) rather than adding a
new file reader. libs/asm/binary_reader.w's ELF section-header walk
(asm_binary_open) is not used here -- these assertions never needed
section awareness, only raw bytes.

Usage: pac_flag_check <ret-elf> <off-elf> <full-elf> <arm64e-macho> <plain-macho>
       (see the pac_flag_test target in build.base.json for the fixture
       binaries each argument expects)
*/
import lib.lib
import lib.stream
import libs.asm.binary_reader


int pac_failures


void pac_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: pac_flag_check <ret-elf> <off-elf> <full-elf> <arm64e-macho> <plain-macho>")
	stream_flush(err)


int pac_has_pacia_x30_x28(char* data, int length):
	return asm_find_bytes4(data, length, 0x9e, 0x03, 0xc1, 0xda)


int pac_has_autia_x30_x28(char* data, int length):
	return asm_find_bytes4(data, length, 0x9e, 0x13, 0xc1, 0xda)


int pac_has_paciza_x0(char* data, int length):
	return asm_find_bytes4(data, length, 0xe0, 0x23, 0xc1, 0xda)


int pac_has_blraaz_x0(char* data, int length):
	return asm_find_bytes4(data, length, 0x1f, 0x08, 0x3f, 0xd6)


# CPU_SUBTYPE_ARM64E (0x81000002), little-endian file bytes at offset 8.
int pac_is_arm64e_subtype(char* data, int length):
	return asm_bytes_match4_at(data, length, 8, 2, 0, 0, 0x81)


# Plain (non-arm64e) ARM64_ALL subtype: zero at offset 8.
int pac_is_plain_arm64_subtype(char* data, int length):
	return asm_bytes_match4_at(data, length, 8, 0, 0, 0, 0)


void pac_assert(int ok, char* path, char* what):
	if (ok == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"pac_flag_check: FAIL: ")
		stream_write_cstr(err, path)
		stream_write_cstr(err, c": ")
		stream_write_line(err, what)
		stream_flush(err)
		pac_failures = pac_failures + 1


char* pac_load(char* path, int* length_out):
	char* data = asm_binary_read_file(path, length_out)
	if (cast(int, data) == 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"pac_flag_check: cannot read ")
		stream_write_line(err, path)
		stream_flush(err)
		exit(1)
	return data


int main(int argc, int argv):
	if (argc != 6):
		pac_usage()
		return 1
	char** arg1 = argv + __word_size__
	char** arg2 = argv + 2 * __word_size__
	char** arg3 = argv + 3 * __word_size__
	char** arg4 = argv + 4 * __word_size__
	char** arg5 = argv + 5 * __word_size__
	char* ret_path = *arg1
	char* off_path = *arg2
	char* full_path = *arg3
	char* arm64e_path = *arg4
	char* darwin_path = *arg5

	pac_failures = 0
	int length = 0
	char* data = 0

	# default: pac=ret -- return addresses signed, no code-pointer signing
	length = 0
	data = pac_load(ret_path, &length)
	pac_assert(asm_is_elf(data, length), ret_path, c"not an ELF file")
	pac_assert(pac_has_pacia_x30_x28(data, length), ret_path, c"missing pacia x30,x28 (9e03c1da)")
	pac_assert(pac_has_autia_x30_x28(data, length), ret_path, c"missing autia x30,x28 (9e13c1da)")
	pac_assert(pac_has_paciza_x0(data, length) == 0, ret_path, c"unexpected paciza x0 (e023c1da) at pac=ret")
	pac_assert(pac_has_blraaz_x0(data, length) == 0, ret_path, c"unexpected blraaz x0 (1f083fd6) at pac=ret")

	# --pac=off: no pointer authentication at all
	length = 0
	data = pac_load(off_path, &length)
	pac_assert(asm_is_elf(data, length), off_path, c"not an ELF file")
	pac_assert(pac_has_pacia_x30_x28(data, length) == 0, off_path, c"unexpected pacia x30,x28 (9e03c1da) at pac=off")
	pac_assert(pac_has_autia_x30_x28(data, length) == 0, off_path, c"unexpected autia x30,x28 (9e13c1da) at pac=off")

	# --pac=full: ret signing plus paciza/blraaz code-pointer signing
	length = 0
	data = pac_load(full_path, &length)
	pac_assert(asm_is_elf(data, length), full_path, c"not an ELF file")
	pac_assert(pac_has_pacia_x30_x28(data, length), full_path, c"missing pacia x30,x28 (9e03c1da) at pac=full")
	pac_assert(pac_has_paciza_x0(data, length), full_path, c"missing paciza x0 (e023c1da) at pac=full")
	pac_assert(pac_has_blraaz_x0(data, length), full_path, c"missing blraaz x0 (1f083fd6) at pac=full")

	# arm64_darwin --pac=full marks the slice arm64e; plain stays ARM64_ALL
	length = 0
	data = pac_load(arm64e_path, &length)
	pac_assert(asm_is_macho64(data, length), arm64e_path, c"not a Mach-O 64 file")
	pac_assert(pac_is_arm64e_subtype(data, length), arm64e_path, c"cpusubtype is not CPU_SUBTYPE_ARM64E (0x81000002)")

	length = 0
	data = pac_load(darwin_path, &length)
	pac_assert(asm_is_macho64(data, length), darwin_path, c"not a Mach-O 64 file")
	pac_assert(pac_is_plain_arm64_subtype(data, length), darwin_path, c"cpusubtype is not the plain ARM64_ALL (0)")

	if (pac_failures > 0):
		wstream* err = stderr_writer()
		stream_write_cstr(err, c"pac_flag_check: ")
		stream_write_cstr(err, itoa(pac_failures))
		stream_write_line(err, c" assertion(s) failed")
		stream_flush(err)
		return 1

	wstream* out = stdout_writer()
	stream_write_line(out, c"pac flag test OK")
	stream_flush(out)
	return 0
