# Negative fixture for --pac=ret (the arm64 default): scribbling on the
# saved, pacia-signed return address MUST kill the process at the
# epilogue's autia (FPAC hardware faults immediately — qemu -cpu max
# and Apple Silicon alike). The victim's W-stack frame is
# [return slot][x], so one word above the sole local is the slot the
# prologue pushed. The Makefile asserts this process dies by signal.
import lib.lib


void pac_victim():
	int x = 0
	int* p = &x
	# Move the signed return address by an address-bit's worth: the
	# signature no longer matches, so the autia before ret traps.
	p[1] = p[1] + 4096


int main(int argc, int argv):
	pac_victim()
	println(c"NOT REACHED: corrupted return address survived authentication")
	return 0
