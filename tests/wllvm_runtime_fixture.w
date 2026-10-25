# Differential fixture for tests/wllvm_test.w: the runtime pieces native
# backends write in assembly (setjmp/longjmp, thread_create) and the
# stack-trace reader, plus compound shifts and float16/bfloat16 storage,
# built by the native x64 backend and by bin/wllvm must print the same
# text and exit with the same status. Not a standalone test (no wbuild
# directive). Frames print without file names: native line tables hold
# the full path, LLVM's DWARF 2 table only the file's base name.
import lib.lib
import lib.setjmp
import lib.stack_trace
import lib.thread


jmp_buf env
int trail


void unwind_to(int depth, int value):
	if (depth == 0): longjmp(&env, value)
	unwind_to(depth - 1, value)


# Locals keep their latest value across longjmp, as natively.
int jumps():
	int attempts = 0
	int r = setjmp(&env)
	attempts = attempts + 1
	if (attempts < 4): unwind_to(3, attempts * 10)
	trail = r
	return attempts


char* frames
int frame_count


void trace_leaf():
	frame_count = stack_trace_collect(frames, 8)


void trace_middle():
	trace_leaf()


void trace_outer():
	trace_middle()


void print_frames():
	for i in range(frame_count):
		int pc = load_word(frames + i * __word_size__)
		print(stack_trace_symbol(pc))
		print(c" ")
		println(stack_trace_line(pc))


int shared_cell


void worker(void* arg):
	shared_cell = cast(int, arg) * 3


int half_bits(float16 x):
	return load_int16(cast(char*, &x))


float16 half_twice(float16 x):
	return x + x


bfloat16 brain_round(float32 x):
	return x


int main():
	int attempts = jumps()
	println(f"setjmp {attempts} {trail}")
	int shifted = 5
	shifted <<= 4
	shifted >>= 2
	uint wide = 0 - 1
	wide >>= 60
	println(f"shifts {shifted} {wide}")
	float16 h = 1.0006
	float16 doubled = half_twice(h)
	bfloat16 b = brain_round(1.00390625)
	float32 back = b
	println(f"narrow {half_bits(h)} {half_bits(doubled)} {load_int16(cast(char*, &b))} {back}")
	frames = cast(char*, malloc(8 * __word_size__))
	trace_outer()
	print_frames()
	wthread* t = thread_spawn(worker, cast(void*, 7))
	thread_join(t)
	println(f"thread {shared_cell}")
	return frame_count + 17
