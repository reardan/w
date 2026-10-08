# Reproducible syscall services for single-threaded, capability-free cells.
# Same image/input/seed can be re-executed and its bounded transcript verified.
# This does not virtualize CPU instructions (RDTSC/RDRAND), wall deadlines,
# guest instruction counts, or guest faults. Random bytes are NOT cryptographic.
# The binary transcript is local/version-specific, not a portable snapshot.
import lib.vmm.memory

const int CELL_TRANSCRIPT_LIMIT = 4194304


void cell_deterministic_fail(vm_cell* cell, char* error):
	cell_fail(cell, error)
	cell.exited = 1
	cell.status = 125


int cell_deterministic_configure(vm_cell* cell, int seed):
	if (cell.started || seed < 0 || seed > 2147483646): return cell_fail(cell, c"seed must be 0..2147483646 before execution")
	if (cell.fs_state != 0 || cell.net_state != 0 || cell.region_state != 0):
		return cell_fail(cell, c"deterministic services disallow external capabilities")
	cell.deterministic = 1
	cell.deterministic_seed = seed
	cell.random_state = seed + 1
	cell.clock_ticks = 0
	cell.max_threads = 1
	string_clear(cell.transcript)
	return 1


# Verification owns a copy; callers may free the source transcript immediately.
# A mismatch, trailing/missing record, or transcript overflow fails the run.
int cell_replay_configure(vm_cell* cell, char* expected, int length):
	if (cell.started || cell.deterministic == 0 || cell.replay != 0): return cell_fail(cell, c"replay requires an unstarted deterministic cell")
	if (expected == 0 || length < 72 || length > CELL_TRANSCRIPT_LIMIT): return cell_fail(cell, c"invalid syscall transcript")
	cell.replay = cast(char*, malloc(length))
	mem_copy[char](cell.replay, expected, length)
	cell.replay_length = length
	cell.replay_pos = 0
	return 1


int cell_deterministic_clock(vm_cell* cell, int clock, int address):
	# Advance one millisecond per successful clock read. Both clocks share
	# the counter; realtime uses a fixed epoch and monotonic starts at zero.
	int seconds = cell.clock_ticks / 1000
	if (clock == 0): seconds = seconds + 1700000000
	save_int64(cell.ram + address, seconds)
	save_int64(cell.ram + address + 8, (cell.clock_ticks % 1000) * 1000000)
	cell.clock_ticks = cell.clock_ticks + 1
	return 0


int cell_deterministic_random(vm_cell* cell, int address, int length):
	# A 31-bit LCG: multiplication fits an x64 word, and the positive
	# decimal mask avoids sign-extending hexadecimal literals.
	for i in range(length):
		cell.random_state = (cell.random_state * 1103515245 + 12345) & 2147483647
		cell.ram[address + i] = cast(char, (cell.random_state >> 16) & 255)
	return length


int cell_transcript_bytes(vm_cell* cell, char* bytes, int length):
	if (length < 0 || length > CELL_TRANSCRIPT_LIMIT - cell.transcript.length):
		cell_deterministic_fail(cell, c"syscall transcript limit exceeded")
		return 0
	if (cell.replay != 0):
		if (length > cell.replay_length - cell.replay_pos):
			cell_deterministic_fail(cell, c"syscall replay mismatch")
			return 0
		for i in range(length):
			if (bytes[i] != cell.replay[cell.replay_pos + i]):
				cell_deterministic_fail(cell, c"syscall replay mismatch")
				return 0
		cell.replay_pos = cell.replay_pos + length
	string_append_bytes(cell.transcript, bytes, length)
	return 1


# Header: syscall number, six Linux argument registers, result, data length.
# Data includes bytes read/written, clock/random output and sigaltstack output.
void cell_transcript_record(vm_cell* cell, char* header, int result):
	int nr = load_int64(header)
	int address = 0
	int length = 0
	if (result > 0 && (nr == 0 || nr == 1)):
		address = load_int64(header + 16)
		length = result
	if (result > 0 && nr == 318):
		address = load_int64(header + 8)
		length = result
	if (result == 0 && nr == 228):
		address = load_int64(header + 16)
		length = 16
	if (result == 0 && nr == 158 && (load_int64(header + 8) == 4099 || load_int64(header + 8) == 4100)):
		address = load_int64(header + 16)
		length = 8
	if (result == 0 && nr == 131 && load_int64(header + 16) != 0):
		address = load_int64(header + 16)
		length = 24
	save_int64(header + 56, result)
	save_int64(header + 64, length)
	if (cell_transcript_bytes(cell, header, 72) == 0): return
	if (length > 0): cell_transcript_bytes(cell, cell.ram + address, length)
