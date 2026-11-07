# wbuild: x64
# W has no 'volatile' qualifier because it needs none: the code generator
# performs every memory access the source names, once, in source order,
# at the declared width (docs/projects/object_files.md, "Memory
# accesses"). C translations rely on that for volatile objects,
# READ_ONCE/WRITE_ONCE and device registers. These tests pin the
# observable halves of it:
#
# - a read whose value is discarded ('*p', 'g', 'p[i]', 's.f' as a
#   statement) still happens: on a PROT_NONE page it faults;
# - a loop condition re-reads a global and a pointer target on every
#   iteration: another thread's store ends the spin;
# - narrow stores stay narrow: the neighbouring bytes survive.
import lib.testing
import lib.thread
import lib.time


struct mao_pair:
	int first
	int second


int mao_flag
int mao_global
int[4] mao_cells
int* mao_shared


# Runs body(page) in a forked child; the child exits 0 when body returns.
# Returns the child's terminating signal, or 0 when it exited normally.
type mao_body = fn(char*) -> void


int mao_child_signal(mao_body* body, char* page):
	int pid = fork()
	if (pid == 0):
		# the expected fault's crash report is noise here
		int null_fd = open(c"/dev/null", 1, 0)
		if (null_fd >= 0): dup2(null_fd, 2)
		body(page)
		exit(0)
	int status = 0
	wait4(pid, &status, 0, 0)
	return status & 0x7f


char* mao_guard_page():
	# PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS
	int page = mmap(0, 4096, 0, 0x22)
	assert1((page > 0) || (page < -4096))
	return cast(char*, page)


void mao_read_deref(char* page):
	int* p = cast(int*, page)
	*p


void mao_read_index(char* page):
	int* p = cast(int*, page)
	p[3]


void mao_read_byte(char* page):
	page[17]


void mao_read_field(char* page):
	mao_pair* q = cast(mao_pair*, page)
	q.second


void mao_read_cast(char* page):
	int* p = cast(int*, page)
	cast(void, *p)


void mao_nothing(char* page):
	int* p = cast(int*, page)
	int* q = p + 8


# Protect the page holding a global, then name the global alone.
void mao_read_global(char* page):
	int at = cast(int, &mao_global) & (0 - 4096)
	assert_equal(0, mprotect(at, 4096, 0))
	mao_global


void mao_read_fixed_array(char* page):
	int at = cast(int, &mao_cells[2]) & (0 - 4096)
	assert_equal(0, mprotect(at, 4096, 0))
	mao_cells[2]


void test_discarded_reads_happen():
	char* page = mao_guard_page()
	assert_equal(11, mao_child_signal(mao_read_deref, page))
	assert_equal(11, mao_child_signal(mao_read_index, page))
	assert_equal(11, mao_child_signal(mao_read_byte, page))
	assert_equal(11, mao_child_signal(mao_read_field, page))
	assert_equal(11, mao_child_signal(mao_read_cast, page))
	assert_equal(11, mao_child_signal(mao_read_global, page))
	assert_equal(11, mao_child_signal(mao_read_fixed_array, page))
	# address arithmetic alone touches nothing
	assert_equal(0, mao_child_signal(mao_nothing, page))
	munmap(cast(int, page), 4096)


void mao_set_flag(void* arg):
	sleep_ms(20)
	mao_flag = 1
	sleep_ms(20)
	*mao_shared = 7


void test_spin_loops_reread():
	mao_flag = 0
	mao_shared = cast(int*, malloc(__word_size__))
	*mao_shared = 0
	wthread* t = thread_spawn(mao_set_flag, cast(void*, 0))
	assert1(t != 0)
	int spins = 0
	while (mao_flag == 0): spins = spins + 1
	int* p = mao_shared
	while (*p == 0): pass
	assert_equal(7, *p)
	thread_join(t)
	assert1(spins > 0)
	free(cast(void*, mao_shared))


void test_narrow_stores_stay_narrow():
	char* bytes = cast(char*, malloc(16))
	for i in range(16): bytes[i] = cast(char, 0xee)
	bytes[3] = cast(char, 1)
	int16* halves = cast(int16*, bytes + 6)
	halves[0] = cast(int16, 0x0202)
	int32* words = cast(int32*, bytes + 10)
	words[0] = cast(int32, 0x03030303)
	assert_equal(0xee, bytes[2] & 255)
	assert_equal(1, bytes[3])
	assert_equal(0xee, bytes[4] & 255)
	assert_equal(0xee, bytes[5] & 255)
	assert_equal(2, bytes[6])
	assert_equal(2, bytes[7])
	assert_equal(0xee, bytes[8] & 255)
	assert_equal(0xee, bytes[9] & 255)
	assert_equal(3, bytes[13])
	assert_equal(0xee, bytes[14] & 255)
	free(bytes)
