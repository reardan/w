# Input image for tests/elf_wx_segment_test.w (never run by that test,
# only parsed): a mutable global that must land in the RW data segment
# under the W^X split, plus dynamic imports -- functions (GOT slots) and
# data objects (COPY space) -- whose loader-written slots the structural
# test asserts lie in the RW load, never in the read-execute one.
import lib.lib

c_lib "libc.so.6"

extern int puts(char* s)
extern void* stdout
extern int optind

int wx_input_global


int main():
	wx_input_global = 42
	if (stdout == 0):
		return 1
	return wx_input_global - 42 + optind - 1
