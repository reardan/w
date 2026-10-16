# Negative fixture for --pac=ret (the arm64 default): scribbling on the
# saved, pacia-signed return address MUST kill the process at the
# epilogue's autia (FPAC hardware faults immediately -- qemu -cpu max
# and Apple Silicon alike; without FPAC the poisoned x30 is a
# non-canonical return target). A leaf's W-stack frame is
# [return slot][saved x29][x] (the prologue's stp x29,x30 frame), so two
# words above the sole local is the slot the prologue pushed.
# pac_corrupt_test_arm64 asserts death by signal.
#
# The corruption flips bit 54, which is inside the PAC field for every
# VA size up to 52 bits (see pac_corrupt_fnptr_test.w): the PAC is
# computed over the stripped address, so a flip inside the field can
# never re-authenticate. Moving the address itself (the old "+ 4096")
# changes the PAC's input instead, and qemu-user's 7-bit field let about
# 1 in 128 runs authenticate and return into unrelated code.
#
# Signing is checked first so that a process running with its keys
# disabled (pacia/autia as no-ops, where the bit-54 flip alone would
# still fault) fails the fixture: the same return address is signed at
# eight W-stack depths, i.e. under eight different modifiers, and at
# least one must carry bits above the 48-bit user address range.
import lib.lib


int pac_seen_bits = 0


void pac_probe():
	int x = 0
	int* p = &x
	pac_seen_bits = pac_seen_bits | (p[2] >> 48)


void pac_dive(int depth):
	if (depth > 0):
		pac_dive(depth - 1)
	pac_probe()


void pac_victim():
	int x = 0
	int* p = &x
	# Flip a PAC-field bit of the signed return address: the
	# signature can no longer match, so the autia before ret traps.
	p[2] = p[2] ^ (1 << 54)


int main(int argc, int argv):
	pac_dive(7)
	if (pac_seen_bits == 0):
		println(c"PAC inactive: no saved return address carries a PAC")
		return 3
	pac_victim()
	println(c"NOT REACHED: corrupted return address survived authentication")
	return 0
