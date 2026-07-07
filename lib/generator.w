/*
Generator runtime (docs/projects/iteration.md, stackful coroutines,
model A). A generator function's call site allocates one of these
objects plus a private 64KB mmap'd stack; gen_next context-switches
into the body and yield switches back. The compiler lowers:

	generator int counter(int n): ...   ->  body compiled with a hidden
	                                        trailing generator* parameter
	counter(5)                          ->  __w_gen_create(counter, argv, argc)
	yield expr                          ->  __w_gen_yield(self, expr)
	return / falling off the end        ->  __w_gen_return(self)

The 64KB stack (vs the 4MB thread stack) keeps hundreds of live
generators viable; it is munmap'd automatically when the body finishes
(observed by gen_next) or by gen_free when a generator is abandoned
early. gen_free also releases the object itself.

gen_switch is an asm stub emitted by code_generator/x86_asm.w /
x64_asm.w: it saves the callee-saved registers and esp on the current
stack, stores esp through arg1, loads arg2 into esp and returns on the
other stack.
*/
import lib.memory


struct generator:
	int resume_esp     # suspended stack pointer (generator side)
	int caller_esp     # stack pointer to switch back to (consumer side)
	int value          # last yielded word
	int done           # 1 once the body returned / fell off the end
	int stack_base     # mmap base, 0 once the stack was released


int __w_gen_stack_size():
	return 65536


# Words gen_switch pushes before saving the stack pointer: 4 callee-saved
# registers on x86 (ebx, esi, edi, ebp), 6 on x64 (rbx, rbp, r12-r15), and
# 0 on arm64 — the A64 gen_switch (code_generator/arm64_asm.w) only saves
# the resume address (x30), since W keeps no live values in callee-saved
# registers across calls.
int __w_gen_switch_regs():
	if (__target_isa__ == 1):
		return 0
	if (__word_size__ == 8):
		return 6
	return 4


# Called by the compiler's generator-call lowering. fn is the body's
# entry address; argv points at the last declared argument on the
# caller's stack (argv[argc - 1] is the first argument). Builds the
# object plus a trampoline frame on a fresh stack so that the first
# gen_next "returns" into the body's entry with the copied arguments
# and the hidden self pointer addressed like normal parameters.
generator* __w_gen_create(int fn, int* argv, int argc):
	generator* g = new generator
	g.caller_esp = 0
	g.value = 0
	g.done = 0
	int size = __w_gen_stack_size()
	# mmap(addr=0, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS)
	int base = mmap(0, size, 3, 34)
	g.stack_base = base
	int* top = cast(int*, base + size)

	# Highest addresses first: the declared arguments in call order
	# (argument 1 at the highest address), exactly like a real call.
	int j = 1
	while (j <= argc):
		top[0 - j] = argv[argc - j]
		j = j + 1
	# The hidden self parameter (declared last in the body's signature)
	top[0 - (argc + 1)] = cast(int, g)
	# Return-address slot: unreachable. Generator bodies never execute a
	# plain ret; return and falling off the end both go through
	# __w_gen_return, which switches back to the consumer permanently.
	top[0 - (argc + 2)] = 0
	# gen_switch's ret target on first resume: the body's entry point
	top[0 - (argc + 3)] = fn
	# Junk callee-saved registers for gen_switch to pop
	int regs = __w_gen_switch_regs()
	j = 0
	while (j < regs):
		top[0 - (argc + 4 + j)] = 0
		j = j + 1
	g.resume_esp = base + size - ((argc + 3 + regs) * __word_size__)
	return g


# Called by the compiler's yield lowering, on the generator's stack.
void __w_gen_yield(generator* g, int value):
	g.value = value
	gen_switch(&g.resume_esp, g.caller_esp)


# Called by the compiler for return / falling off the end of a
# generator body, on the generator's stack. Never returns; the stack
# cannot munmap itself, so gen_next releases it after switching back.
void __w_gen_return(generator* g):
	g.done = 1
	gen_switch(&g.resume_esp, g.caller_esp)


# Switch into the body until the next yield. Returns 1 when a value
# was yielded (read it with gen_value), 0 once the body finished.
# Safe to keep calling after exhaustion.
int gen_next(generator* g):
	if (g.done):
		return 0
	gen_switch(&g.caller_esp, g.resume_esp)
	if (g.done):
		# The body just finished: release its stack now (it could not
		# munmap the stack it was running on).
		if (g.stack_base != 0):
			munmap(g.stack_base, __w_gen_stack_size())
			g.stack_base = 0
		return 0
	return 1


int gen_value(generator* g):
	return g.value


int gen_done(generator* g):
	return g.done


# Release a generator: munmap the stack (if still live, i.e. abandoned
# before exhaustion) and free the object. Do not resume it afterwards.
void gen_free(generator* g):
	if (g == 0):
		return;
	if (g.stack_base != 0):
		munmap(g.stack_base, __w_gen_stack_size())
		g.stack_base = 0
	free(cast(void*, g))


/*
Cursor protocol adapters (docs/projects/iteration.md): the generator
struct is a named struct type, so these four functions let
"for int x in counter(5):" compile through the existing cursor
lowering in grammar/for_statement.w. The cursor word carries
gen_next's result (1 while a value is available).
*/
int generator_iter_begin(generator* g):
	return gen_next(g)


int generator_iter_done(generator* g, int cur):
	return cur == 0


int generator_iter_next(generator* g, int cur):
	return gen_next(g)


int generator_iter_value(generator* g, int cur):
	return gen_value(g)
