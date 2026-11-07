# Section placement and symbol attributes in a freestanding object
# (tests/object_sections_test.w links it with main.c and sections.ld;
# docs/projects/object_files.md, "Sections and symbol attributes").
type unary = fn(int) -> int

extern void c_note(char* text, int value)
@weak
extern int c_optional(int x)
@weak
extern int c_optional_value
# Bounds of the initcall table sections.ld collects.
extern int __w_initcalls_start
extern int __w_initcalls_end

int w_counter = 7
# zero-initialized: .bss
int w_zero_counter
@align(64)
int w_cache_line
@align(4096)
int[512] w_page_table
@section(".rodata.w_consts")
int w_answer = 42
# a second global name for w_counter's storage
@alias("w_counter")
int w_counter_alias


@section(".init.text")
int w_init_helper(int x):
	return x + w_counter


# Plain .text between two .init.text functions: the call below crosses
# it inside one section.
int w_middle(int x):
	return w_init_helper(x) * 2


@section(".init.text") @align(64)
export int w_init_first():
	c_note(c"init first", w_init_helper(1))
	return w_middle(1)


@section(".init.text")
int w_init_second(int x):
	c_note("init second", x)
	return 2


# Initcall-style tables: entries land in .w_initcall.<level> and the
# linker script sorts the levels.
@section(".w_initcall.6")
unary* w_initcall_second = w_init_second
@section(".w_initcall.1")
unary* w_initcall_first = w_init_helper

@section(".w_table")
int w_table_a = 11
@section(".w_table")
int w_table_b = 31


# W calls through the table between the linker-defined bounds.
export int w_run_initcalls():
	unary** at = cast(unary**, &__w_initcalls_start)
	unary** end = cast(unary**, &__w_initcalls_end)
	int total = 0
	while (at < end):
		unary* f = *at
		total = total * 100 + f(total + 1)
		at = &at[1]
	return total


@weak
export int w_weak_hook():
	return 5


export int w_uses_hook():
	return w_weak_hook() + 100


export int w_real(int a):
	return a * 3


@alias("w_real")
int w_real_alias(int a);


export int w_call_alias(int a):
	return w_real_alias(a) + 1


export int w_has_optional():
	return cast(int, &c_optional_value)


export int w_cache_line_address():
	w_cache_line = 3
	return cast(int, &w_cache_line)


export int w_page_table_address():
	return cast(int, &w_page_table[0])


export int w_greeting_length():
	char* text = c"read-only literal"
	int n = 0
	while (text[n] != 0): n = n + 1
	return n
