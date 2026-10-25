# wbuild: x64
# wbuild: tool=tools/wprof.w
# wbuild: step="bin/wv2 --inline tests/thread_wait_reload_test.w -o bin/thread_wait_reload_inline"
# wbuild: step="bin/thread_wait_reload_inline"
# wbuild: step="bin/wv2 x64 --inline tests/thread_wait_reload_test.w -o bin/thread_wait_reload_inline64"
# wbuild: step="bin/thread_wait_reload_inline64"
# wbuild: step="bin/wv2 --profile-generate tests/thread_wait_reload_test.w -o bin/thread_wait_reload_gen"
# wbuild: step="bin/thread_wait_reload_gen" env="W_PROFILE_OUT=bin/thread_wait_reload_gen.wprofraw"
# wbuild: step="bin/wprof merge -o bin/thread_wait_reload.wprof bin/thread_wait_reload_gen.wprofmap bin/thread_wait_reload_gen.wprofraw"
# wbuild: step="bin/wv2 --profile-use=bin/thread_wait_reload.wprof tests/thread_wait_reload_test.w -o bin/thread_wait_reload_pgo"
# wbuild: step="bin/thread_wait_reload_pgo"
# wbuild: step="bin/wv2 x64 --profile-generate tests/thread_wait_reload_test.w -o bin/thread_wait_reload_gen64"
# wbuild: step="bin/thread_wait_reload_gen64" env="W_PROFILE_OUT=bin/thread_wait_reload_gen64.wprofraw"
# wbuild: step="bin/wprof merge -o bin/thread_wait_reload64.wprof bin/thread_wait_reload_gen64.wprofmap bin/thread_wait_reload_gen64.wprofraw"
# wbuild: step="bin/wv2 x64 --profile-use=bin/thread_wait_reload64.wprof tests/thread_wait_reload_test.w -o bin/thread_wait_reload_pgo64"
# wbuild: step="bin/thread_wait_reload_pgo64"
/*
lib/thread.w's futex wait loops must re-read their word from memory on
every iteration (lib/thread.w header, "Synchronization words"): an
optimizer that kept the first load in a register across iterations
would make a joiner spin on a stale 0. This binary inspects its own
machine code. It decodes thread_wait_word, thread_wait_word_clear and
thread_pool_worker as compiled into it, finds every loop (a backward
branch) whose body calls sys_futex, and requires each such loop body
to read memory that is not the stack frame (a load through a pointer or
from a global). The steps above repeat the check under --inline and
--profile-use (with a profile of this program's own run) on x86 and
x64; the plain x86 run and its x64 twin cover the default options, and
the --profile-generate runs check the instrumented code as well.

hoisted_wait is the negative control: its load sits before the loop,
so the check must report its futex loop as not reloading. It is never
called (it would sleep forever).
*/
import lib.testing
import lib.thread
import libs.asm.insn
import libs.asm.x86_decode


type wait_fn = fn(int*) -> void
type worker_fn = fn(void*) -> void
type futex_fn = fn(int, int, int, int) -> int


int reload_futex_loops      # futex loops found by the last scan
int reload_stale_loops      # of those, loops with no memory reload


void hoisted_wait(int* word):
	int seen = *word
	while (seen == 0): sys_futex(cast(int, word), thread_futex_wait_op, 0, 0)


# An instruction that reads memory outside the stack frame: a load or
# compare whose memory operand is based on neither esp/rsp nor
# ebp/rbp (register 4 or 5), i.e. a dereference or a global.
# --profile-generate's counter bumps (`inc [counter]`, or add/adc of an
# immediate into a 64-bit counter on x86) are not reads of program
# state, so a read-modify-write of memory does not count.
int reload_reads_shared(asm_insn* insn):
	if (strcmp(insn.mnemonic, c"lea") == 0): return 0
	if (insn.op1.kind == ASM_OP_MEM):
		if (strcmp(insn.mnemonic, c"inc") == 0): return 0
		if (strcmp(insn.mnemonic, c"add") == 0): return 0
		if (strcmp(insn.mnemonic, c"adc") == 0): return 0
	if (insn.op2.kind == ASM_OP_MEM):
		if ((insn.op2.base != 4) && (insn.op2.base != 5)): return 1
	if ((insn.op1.kind == ASM_OP_MEM) && (strcmp(insn.mnemonic, c"mov") != 0)):
		if ((insn.op1.base != 4) && (insn.op1.base != 5)): return 1
	return 0


# Decode the function at addr and count its futex loops (into the two
# globals above). Fails the test on an undecodable byte, so a decoder
# gap cannot pass silently.
void reload_scan(char* name, int addr, int futex):
	int mode = sizeof(int)
	list[int] where = new list[int]
	list[int] target = new list[int]
	list[int] reads = new list[int]
	list[int] calls = new list[int]
	list[int] jumps = new list[int]
	int pos = addr
	int furthest = addr
	while (1):
		asm_insn insn
		int n = asm_x86_decode(cast(char*, pos), 16, pos, mode, &insn)
		if (strcmp(insn.mnemonic, c".byte") == 0):
			print2(name)
			println2(c": undecodable instruction")
			assert1(0)
		where.push(pos)
		target.push(insn.branch_target)
		reads.push(reload_reads_shared(&insn))
		int is_futex_call = 0
		if ((strcmp(insn.mnemonic, c"call") == 0) && (insn.branch_target == futex)): is_futex_call = 1
		calls.push(is_futex_call)
		int is_jump = 0
		if (insn.mnemonic[0] == 'j'): is_jump = 1
		jumps.push(is_jump)
		if (is_jump && (insn.branch_target > furthest)): furthest = insn.branch_target
		pos = pos + n
		if ((strcmp(insn.mnemonic, c"ret") == 0) && (pos > furthest)): break
		asserts(c"function end found", pos < addr + 4096)
	reload_futex_loops = 0
	reload_stale_loops = 0
	for i in range(where.length):
		int to = target[i]
		if ((to >= addr) && (to <= where[i]) && (jumps[i] != 0)):
			int futex_calls = 0
			int shared_reads = 0
			for j in range(where.length):
				if ((where[j] >= to) && (where[j] <= where[i])):
					futex_calls = futex_calls + calls[j]
					shared_reads = shared_reads + reads[j]
			if (futex_calls > 0):
				reload_futex_loops = reload_futex_loops + 1
				if (shared_reads == 0): reload_stale_loops = reload_stale_loops + 1
	__w_list_free(cast(__w_list*, where))
	__w_list_free(cast(__w_list*, target))
	__w_list_free(cast(__w_list*, reads))
	__w_list_free(cast(__w_list*, calls))
	__w_list_free(cast(__w_list*, jumps))


void check_reloads(char* name, int addr, int futex):
	reload_scan(name, addr, futex)
	asserts(name, reload_futex_loops > 0)
	if (reload_stale_loops != 0):
		print2(name)
		println2(c": a futex wait loop does not re-read memory")
	assert_equal(0, reload_stale_loops)


void reload_worker(void* arg):
	int* cell = cast(int*, arg)
	*cell = 42


void reload_chunk(int chunk_start, int chunk_end, void* arg):
	int* cells = cast(int*, arg)
	for i in range(chunk_start, chunk_end): cells[i] = i


void test_wait_loops_reread_memory():
	futex_fn* futex = sys_futex
	wait_fn* wait = thread_wait_word
	wait_fn* wait_clear = thread_wait_word_clear
	worker_fn* pool_worker = thread_pool_worker
	check_reloads(c"thread_wait_word", cast(int, wait), cast(int, futex))
	check_reloads(c"thread_wait_word_clear", cast(int, wait_clear), cast(int, futex))
	check_reloads(c"thread_pool_worker", cast(int, pool_worker), cast(int, futex))


void test_hoisted_load_is_detected():
	futex_fn* futex = sys_futex
	wait_fn* hoisted = hoisted_wait
	reload_scan(c"hoisted_wait", cast(int, hoisted), cast(int, futex))
	assert_equal(1, reload_futex_loops)
	assert_equal(1, reload_stale_loops)


# Run the waits for real too, so the --profile-generate run records
# them (spawn + join, and a pooled parallel_for).
void test_waits_run():
	int cell = 0
	wthread* t = thread_spawn(reload_worker, cast(void*, &cell))
	asserts(c"spawn", t != 0)
	assert_equal(0, thread_join(t))
	assert_equal(42, cell)
	int* cells = cast(int*, malloc(64 * sizeof(int)))
	for round in range(8): parallel_for(0, 64, 4, reload_chunk, cast(void*, cells))
	for i in range(64): assert_equal(i, cells[i])
	free(cast(void*, cells))
	thread_pool_shutdown()
