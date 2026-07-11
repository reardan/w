/*
WebAssembly module (container) writer — the wasm twin of the ELF/Mach-O/PE
writers (docs/projects/wasm_backend.md D4/D5), dispatched from
be_start/be_finish on target_os == 3.

Layout of the emitted module:

  header | type | import | function | table | memory | global | export |
  element | code (streamed function bodies) | data (streamed data buffer)

The code section streams into the ordinary `code` buffer during
compilation (each function body is a padded-size-prefixed unit, see
code_generator/wasm.w); globals, string literals and their descriptors
stream into the W^X `data` buffer. Everything else is tiny and assembled
here at finish time from the symbol table and the fixed import set, into
scratch space appended after the code bodies, then written out in order.

Linear memory layout (docs/projects/wasm_backend.md D4):

  [0, 4k)          reserved: address 0 stays out of circulation; bytes
                   256.. are scratch for the WASI wrappers
  [4k, 0x101000)   the W evaluation stack (1 MiB); $sp starts at the top
  [0x101000, ...)  the data segment (data_offset)
  above            heap, grown with memory.grow (wasi_memory_grow)

The OS surface is the fixed wasi_snapshot_preview1 import set below —
always emitted, like the kernel32 imports on win64 — wrapped by thin
W-callable [] -> [] stubs (wasm_define_asm_functions, the moral twin of
x86_asm.w's int-0x80 stubs). lib/__arch__/wasm/syscalls.w rebuilds the
Linux-shaped wrapper surface on top of them in plain W.

This file is compiled by the committed seed: seed-known syntax only.
*/

import code_generator.wasm

int sym_declare_global(char *s, int type, int symtype); /* symbol_table */
void sym_define_global_at(int current_symbol, int v);   /* symbol_table */
int sym_address(char* name);                            /* symbol_table */
void error(char *s);                                    /* tokenizer */

# Fixed import function indices (module "wasi_snapshot_preview1").
# Defined functions follow at index wasm_num_imports() + n.
int wasm_num_imports():
	return 10

# Buffer offset of the entry stub's callee address slot (patched in
# wasm_finish once the entry symbol's table index is known).
int wasm_entry_slot_pos

########################### W-callable import stubs ###########################

# Begin a W-callable stub: declare and define the symbol at its table
# index, then open the function unit (the prologue reserves the W-stack
# return slot, so argument i of n sits at [$sp + 4*(n-i)], the layout the
# x86 syscall stubs read).
void wasm_stub_begin(char* name):
	int t = sym_declare_global(name, 4, 2)
	wasm_function_begin()
	sym_define_global_at(t, wasm_func_count)
	wasm_func_name_note(wasm_func_count, name)

void wasm_stub_end():
	wasm_ret()
	wasm_function_end()

# Load W argument i (0-based of n) onto the wasm operand stack.
void wasm_stub_arg(int i, int n):
	wasm_global_get(0)
	wasm_load_op(0x28, 2, (n - i) << 2)

# call a fixed import and store its i32 result in $ax
void wasm_stub_call(int funcidx):
	emit_int8(0x10)
	wasm_leb(funcidx)
	wasm_set_ax()

# A thin all-i32 stub: load n args in order, call the import, result to $ax.
void wasm_stub_simple(char* name, int n, int funcidx):
	wasm_stub_begin(name)
	int i = 0
	while (i < n):
		wasm_stub_arg(i, n)
		i = i + 1
	wasm_stub_call(funcidx)
	wasm_stub_end()

# The W-callable OS stubs. Emitted at be_start, before any user code, so
# their table indices come first after the entry stub.
void wasm_define_asm_functions():
	# wasi_proc_exit(code): terminates; no result
	wasm_stub_begin(c"wasi_proc_exit")
	wasm_stub_arg(0, 1)
	emit_int8(0x10)
	wasm_leb(0)
	wasm_stub_end()

	wasm_stub_simple(c"wasi_fd_write", 4, 1)
	wasm_stub_simple(c"wasi_fd_read", 4, 2)
	wasm_stub_simple(c"wasi_fd_close", 1, 3)

	# wasi_path_open(dirfd, dirflags, path, path_len, oflags, rights,
	# fdflags, out_fd) -> errno. The two u64 rights arguments take the
	# same 32-bit rights word zero-extended (the defined WASI rights bits
	# all fit in 32; pass -1 for all rights).
	wasm_stub_begin(c"wasi_path_open")
	wasm_stub_arg(0, 8)
	wasm_stub_arg(1, 8)
	wasm_stub_arg(2, 8)
	wasm_stub_arg(3, 8)
	wasm_stub_arg(4, 8)
	wasm_stub_arg(5, 8)
	emit_int8(0xad)   # i64.extend_i32_u: fs_rights_base
	wasm_stub_arg(5, 8)
	emit_int8(0xad)   # i64.extend_i32_u: fs_rights_inheriting
	wasm_stub_arg(6, 8)
	wasm_stub_arg(7, 8)
	wasm_stub_call(4)
	wasm_stub_end()

	wasm_stub_simple(c"wasi_args_sizes_get", 2, 5)
	wasm_stub_simple(c"wasi_args_get", 2, 6)
	wasm_stub_simple(c"wasi_path_unlink_file", 3, 7)

	# wasi_clock_time_get(clock, out) -> errno; writes a timespec-shaped
	# {seconds, nanoseconds} pair of i32 words at out (the i64-ns
	# division happens here, where i64 arithmetic exists).
	wasm_stub_begin(c"wasi_clock_time_get")
	wasm_stub_arg(0, 2)
	emit_int8(0x42)   # i64.const 1000 (precision)
	wasm_leb(1000)
	wasm_i32_const(288)   # scratch: the raw i64 timestamp
	wasm_stub_call(8)
	# seconds = ns / 1e9; nanos = ns % 1e9 (the padded 5-byte encoding is
	# a valid non-minimal s64 LEB for 1e9: bit 31 is clear)
	wasm_stub_arg(1, 2)
	wasm_i32_const(288)
	wasm_load_op(0x29, 3, 0)   # i64.load
	emit_int8(0x42)
	wasm_leb5(1000000000)
	wasm_op(0x80)  # i64.div_u
	wasm_op(0xa7)  # i32.wrap
	wasm_load_op(0x36, 2, 0)   # [out] = seconds
	wasm_stub_arg(1, 2)
	wasm_i32_const(288)
	wasm_load_op(0x29, 3, 0)
	emit_int8(0x42)
	wasm_leb5(1000000000)
	wasm_op(0x82)  # i64.rem_u
	wasm_op(0xa7)
	wasm_load_op(0x36, 2, 4)   # [out+4] = nanoseconds
	wasm_stub_end()

	# wasi_fd_seek(fd, offset, whence, out) -> errno; offset sign-extends.
	wasm_stub_begin(c"wasi_fd_seek")
	wasm_stub_arg(0, 4)
	wasm_stub_arg(1, 4)
	emit_int8(0xac)   # i64.extend_i32_s
	wasm_stub_arg(2, 4)
	wasm_stub_arg(3, 4)
	wasm_stub_call(9)
	wasm_stub_end()

	# wasi_memory_grow(pages) -> previous size in pages, or -1
	wasm_stub_begin(c"wasi_memory_grow")
	wasm_stub_arg(0, 1)
	emit_int8(0x40)   # memory.grow
	emit_int8(0)
	wasm_set_ax()
	wasm_stub_end()

	# wasi_memory_size() -> current size in pages
	wasm_stub_begin(c"wasi_memory_size")
	emit_int8(0x3f)   # memory.size
	emit_int8(0)
	wasm_set_ax()
	wasm_stub_end()

	# swap_endian(v): 32-bit byte swap (lib/sha256.w and friends)
	wasm_stub_begin(c"swap_endian")
	wasm_stub_arg(0, 1)
	wasm_global_set(3)
	wasm_global_get(3)
	wasm_i32_const(24)
	wasm_op(0x76)   # >>u 24
	wasm_global_get(3)
	wasm_i32_const(8)
	wasm_op(0x76)
	wasm_i32_const(65280)   # 0xff00
	wasm_op(0x71)
	wasm_op(0x72)   # or
	wasm_global_get(3)
	wasm_i32_const(65280)
	wasm_op(0x71)
	wasm_i32_const(8)
	wasm_op(0x74)   # << 8
	wasm_op(0x72)
	wasm_global_get(3)
	wasm_i32_const(24)
	wasm_op(0x74)   # << 24
	wasm_op(0x72)
	wasm_set_ax()
	wasm_stub_end()

	# swap_endian16(v): 16-bit byte swap of the low half
	wasm_stub_begin(c"swap_endian16")
	wasm_stub_arg(0, 1)
	wasm_global_set(3)
	wasm_global_get(3)
	wasm_i32_const(8)
	wasm_op(0x76)
	wasm_i32_const(255)
	wasm_op(0x71)
	wasm_global_get(3)
	wasm_i32_const(255)
	wasm_op(0x71)
	wasm_i32_const(8)
	wasm_op(0x74)
	wasm_op(0x72)
	wasm_set_ax()
	wasm_stub_end()

	# Trap stubs: symbols the shared library/debugger trees reference but
	# whose operations cannot exist on wasm (raw syscalls, stack
	# switching, threads, sockets, longjmp). Defining them keeps the
	# import graph linking; executing one traps loudly (`unreachable`),
	# which is also the honest runtime answer.
	wasm_stub_begin(c"syscall")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"syscall7")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"repl_longjmp")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"gen_switch")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"function_call")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"thread_create")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"stack_create")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"socket_connect")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"socket_connect_new")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"socket")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"connect")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"setsockopt")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"bind")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"listen")
	emit_int8(0x00)
	wasm_stub_end()
	wasm_stub_begin(c"socket_accept")
	emit_int8(0x00)
	wasm_stub_end()

	# get_context/store_context: zero out a register_context-sized record
	# (one word on wasm, lib/__arch__/wasm/context.w) so inspection paths
	# read zeros instead of trapping.
	wasm_stub_begin(c"get_context")
	wasm_stub_arg(0, 1)
	wasm_i32_const(0)
	wasm_load_op(0x36, 2, 0)
	wasm_stub_end()
	wasm_stub_begin(c"store_context")
	wasm_stub_end()

	# repl_setjmp(buf): fills {pc=0, callers-sp, fp=0}; lib/stack_trace.w
	# probes the zero pc through sys_mincore (which reports unmapped on
	# wasm), so trace collection stays a silent no-op, like Mach-O/PE.
	wasm_stub_begin(c"repl_setjmp")
	wasm_stub_arg(0, 1)
	wasm_i32_const(0)
	wasm_load_op(0x36, 2, 0)
	wasm_stub_arg(0, 1)
	wasm_global_get(0)
	wasm_i32_const(8)
	wasm_op(0x6a)
	wasm_load_op(0x36, 2, 4)
	wasm_stub_arg(0, 1)
	wasm_i32_const(0)
	wasm_load_op(0x36, 2, 8)
	wasm_mov_eax_int(0)
	wasm_stub_end()

################################ entry stub ###################################

# The module's _start export (the first defined function, table index 1):
# push the W entry contract (argc, argv — zeros the runtime startup in
# lib/__arch__/wasm/syscalls.w replaces via WASI args_get), call the entry
# function through a patchable slot, and proc_exit with its result.
void wasm_emit_entry_stub():
	wasm_function_begin()
	wasm_func_name_note(wasm_func_count, c"_start")
	wasm_push_const(0)   # argc
	wasm_push_const(0)   # argv
	wasm_addr_slot_emit()
	wasm_entry_slot_pos = codepos - 4
	wasm_call_eax()
	wasm_get_ax()
	emit_int8(0x10)   # call proc_exit (fixed import index 0)
	wasm_leb(0)
	wasm_function_end()

void wasm_start():
	code_offset = 0
	data_offset = 1052672   # 0x101000: 4k reserved + 1 MiB W stack
	wasm_func_count = 0
	wasm_emit_entry_stub()
	wasm_define_asm_functions()

############################### finish: sections ##############################

void wasm_sec_name(char* s):
	wasm_leb(strlen(s))
	emit(strlen(s), s)

# One import entry: module "wasi_snapshot_preview1", the given name, kind
# func, the given type index.
void wasm_import_entry(char* name, int type_index):
	wasm_sec_name(c"wasi_snapshot_preview1")
	wasm_sec_name(name)
	emit_int8(0)
	wasm_leb(type_index)

# Begin section id with a padded size prefix; returns the size position.
int wasm_section_begin(int id):
	emit_int8(id)
	int pos = codepos
	wasm_leb5(0)
	return pos

void wasm_section_end(int size_pos):
	wasm_leb5_patch(size_pos, codepos - (size_pos + 5))

# emit a function type: n_params i32 params (with 1-bits in i64_mask
# marking i64 positions), and 0 or 1 i32 results
void wasm_type_entry(int n_params, int i64_mask, int n_results):
	emit_int8(0x60)
	wasm_leb(n_params)
	int i = 0
	while (i < n_params):
		if ((i64_mask >> i) & 1):
			emit_int8(0x7e)
		else:
			emit_int8(0x7f)
		i = i + 1
	wasm_leb(n_results)
	if (n_results):
		emit_int8(0x7f)

# one mutable global: value type vt, zero-or-constant init
void wasm_global_entry(int vt, int init):
	emit_int8(vt)
	emit_int8(1)   # mutable
	if (vt == 0x7e):
		emit_int8(0x42)   # i64.const
		wasm_leb(init)
	else if (vt == 0x7d):
		emit_int8(0x43)   # f32.const (4 raw bytes; init is the bit pattern)
		emit_int32(init)
	else:
		wasm_i32_const(init)
	emit_int8(0x0b)

void wasm_finish():
	# Entry selection, mirroring the PE writer: __w_wasm_start (the WASI
	# runtime startup, which rebuilds real argc/argv) when _main exists
	# for it to chain to; otherwise _main / main directly.
	int t = 0
	if (sym_address(c"_main") != 0):
		t = sym_address(c"__w_wasm_start")
	if (t == 0):
		t = sym_address(c"_main")
	if (t == 0):
		t = sym_address(c"main")
	if (t == 0):
		error(c"Failed to find a _main() function. Did you import lib/testing?")
	wasm_addr_slot_write(wasm_entry_slot_pos, t)

	int code_end = codepos

	# ---- everything before the code bodies, assembled into scratch ----
	int s1 = codepos
	emit(4, c"\x00asm")
	emit_int32(1)   # version

	# type section: 0 = the universal [] -> [] W type, then the import
	# signatures (i64 positions as a bitmask over the parameter list)
	int p = wasm_section_begin(1)
	wasm_leb(9)
	wasm_type_entry(0, 0, 0)                # 0: [] -> []
	wasm_type_entry(1, 0, 0)                # 1: proc_exit
	wasm_type_entry(4, 0, 1)                # 2: fd_write / fd_read
	wasm_type_entry(1, 0, 1)                # 3: fd_close
	wasm_type_entry(9, 32 | 64, 1)          # 4: path_open (i64 at 5, 6)
	wasm_type_entry(2, 0, 1)                # 5: args_*
	wasm_type_entry(3, 0, 1)                # 6: path_unlink_file
	wasm_type_entry(3, 2, 1)                # 7: clock_time_get (i64 at 1)
	wasm_type_entry(4, 2, 1)                # 8: fd_seek (i64 at 1)
	wasm_section_end(p)

	# import section: the fixed WASI set, function indices 0..9
	p = wasm_section_begin(2)
	wasm_leb(10)
	wasm_import_entry(c"proc_exit", 1)
	wasm_import_entry(c"fd_write", 2)
	wasm_import_entry(c"fd_read", 2)
	wasm_import_entry(c"fd_close", 3)
	wasm_import_entry(c"path_open", 4)
	wasm_import_entry(c"args_sizes_get", 5)
	wasm_import_entry(c"args_get", 5)
	wasm_import_entry(c"path_unlink_file", 6)
	wasm_import_entry(c"clock_time_get", 7)
	wasm_import_entry(c"fd_seek", 8)
	wasm_section_end(p)

	# function section: every defined function has type 0
	p = wasm_section_begin(3)
	wasm_leb(wasm_func_count)
	int i = 0
	while (i < wasm_func_count):
		wasm_leb(0)
		i = i + 1
	wasm_section_end(p)

	# table: funcref, index 0 reserved as the null function pointer
	p = wasm_section_begin(4)
	wasm_leb(1)
	emit_int8(0x70)
	emit_int8(0)
	wasm_leb(wasm_func_count + 1)
	wasm_section_end(p)

	# memory: enough pages for the reserved region, W stack, and data,
	# plus one page of heap headroom; the allocator grows the rest
	p = wasm_section_begin(5)
	wasm_leb(1)
	emit_int8(0)
	wasm_leb(((data_offset + datapos + 65535) >> 16) + 1)
	wasm_section_end(p)

	# globals: $sp (W stack top), $ax, $bx, $cx, $t64 (i64 scratch),
	# $f0, $f1 (the virtual xmm pair)
	p = wasm_section_begin(6)
	wasm_leb(7)
	wasm_global_entry(0x7f, data_offset)   # $sp: stack top == data base
	wasm_global_entry(0x7f, 0)
	wasm_global_entry(0x7f, 0)
	wasm_global_entry(0x7f, 0)
	wasm_global_entry(0x7e, 0)
	wasm_global_entry(0x7d, 0)
	wasm_global_entry(0x7d, 0)
	wasm_section_end(p)

	# exports: memory + _start (the entry stub, first defined function)
	p = wasm_section_begin(7)
	wasm_leb(2)
	wasm_sec_name(c"memory")
	emit_int8(2)
	wasm_leb(0)
	wasm_sec_name(c"_start")
	emit_int8(0)
	wasm_leb(wasm_num_imports())
	wasm_section_end(p)

	# element: table[1 + i] = defined function i (identity mapping)
	p = wasm_section_begin(9)
	wasm_leb(1)
	emit_int8(0)
	wasm_i32_const(1)
	emit_int8(0x0b)
	wasm_leb(wasm_func_count)
	i = 0
	while (i < wasm_func_count):
		wasm_leb(wasm_num_imports() + i)
		i = i + 1
	wasm_section_end(p)

	# code section header: id, payload size, count (bodies follow from
	# the streamed region)
	emit_int8(10)
	int count_len = 1
	int rest = wasm_func_count >> 7
	while (rest):
		count_len = count_len + 1
		rest = rest >> 7
	wasm_leb5(count_len + code_end)
	wasm_leb(wasm_func_count)
	int s1_end = codepos

	# ---- data section (skipped when empty) ----
	int s2 = codepos
	if (datapos):
		p = wasm_section_begin(11)
		wasm_leb(1)
		emit_int8(0)
		wasm_i32_const(data_offset)
		emit_int8(0x0b)
		wasm_leb(datapos)
		# the vector length above counts the data bytes written below,
		# so the recorded section size must include them too
		wasm_leb5_patch(p, (codepos - (p + 5)) + datapos)
	int s2_end = codepos

	# ---- "name" custom section: function names for engine traces ----
	# (assembled as its own region: it follows the data BYTES in the file,
	# which are written from the separate data buffer below)
	int s3 = codepos
	if (wasm_func_names_cap):
		p = wasm_section_begin(0)
		wasm_sec_name(c"name")
		emit_int8(1)   # function-names subsection
		int sub = codepos
		wasm_leb5(0)
		int named = 0
		i = 1
		while (i <= wasm_func_count):
			if (i < wasm_func_names_cap):
				if (wasm_func_names[i]):
					named = named + 1
			i = i + 1
		wasm_leb(named)
		i = 1
		while (i <= wasm_func_count):
			if (i < wasm_func_names_cap):
				if (wasm_func_names[i]):
					wasm_leb(wasm_num_imports() + i - 1)
					wasm_sec_name(wasm_func_names[i])
			i = i + 1
		wasm_leb5_patch(sub, codepos - (sub + 5))
		wasm_section_end(p)
	int s3_end = codepos

	write(output_fd, code + s1, s1_end - s1)
	write(output_fd, code, code_end)
	write(output_fd, code + s2, s2_end - s2)
	if (datapos):
		write(output_fd, data, datapos)
	write(output_fd, code + s3, s3_end - s3)
