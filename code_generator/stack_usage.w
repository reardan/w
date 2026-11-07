# --stack-usage: a per-function stack report in the format of gcc's
# -fstack-usage, written next to the output as <output minus .o>.su:
#
#   file.w:LINE:COL:function<TAB>bytes<TAB>static
#
# bytes is the most the function itself takes below its caller's stack
# pointer: the return address, the frame pointer, saved registers and
# every word the function pushes (locals, temporaries, outgoing
# arguments), but not its callees' frames. W has no dynamically sized
# stack allocation, so every entry is "static". Export adapters and FFI
# shims (C-call conversions) get entries of their own, named
# "name [adapter]" and "name [c-call]", and so do --c-abi adapters,
# "name [c-abi]". x86 and x64 only;
# docs/projects/object_files.md ("Stack usage") describes how the
# numbers are derived and checked.
#
# This file is compiled by the committed seed: only seed-understood
# syntax here.
import code_generator.code_emitter
import compiler.symbol_table
import structures.string

char* debug_file_name(int index);
char* sym_record_name(int t);

list[char*] stack_usage_lines
int stack_usage_symbol    # the function being emitted
int stack_usage_base      # stack_pos at its prologue
int stack_usage_max       # the deepest stack_pos seen since
# stack_usage_last_symbol (compiler/symbol_table.w): the symbol
# sym_define_global defined last, an FFI shim's entry


void stack_usage_add(int symbol, char* suffix, int bytes):
	if (cast(int, stack_usage_lines) == 0): stack_usage_lines = new list[char*]
	char* name = sym_record_name(symbol)
	char* file_name = debug_file_name(load_int(table + symbol + 66))
	if (file_name == 0): file_name = c"?"
	string_builder* line = string_new()
	string_append(line, file_name)
	string_append_char(line, ':')
	string_append_int(line, load_int(table + symbol + 70))
	string_append_char(line, ':')
	string_append_int(line, load_int(table + symbol + 74))
	string_append_char(line, ':')
	string_append(line, name)
	if (suffix != 0): string_append(line, suffix)
	string_append_char(line, 9)
	string_append_int(line, bytes)
	string_append(line, c"\x09static")
	stack_usage_lines.push(line.data)
	free(line)


# be_function_define: the function whose prologue comes next.
void stack_usage_define(int symbol):
	stack_usage_symbol = symbol


# be_function_prologue: start measuring. The words a call's return
# address and the prologue push are counted in stack_pos from here on.
void stack_usage_begin():
	stack_usage_base = stack_pos
	stack_usage_max = stack_pos
	stack_usage_active = 1


# emit() while a body is open: the deepest point so far.
void stack_usage_sample():
	if (stack_pos > stack_usage_max): stack_usage_max = stack_pos


# Stack the emitter uses beyond what stack_pos tracks (the inline C-call
# frame of a variadic extern call), words below the current stack_pos.
void stack_usage_extra(int words):
	if (stack_usage_active == 0): return;
	if (stack_pos + words > stack_usage_max): stack_usage_max = stack_pos + words


# be_function_epilogue: the body is complete.
void stack_usage_end():
	if (stack_usage_active == 0): return;
	stack_usage_active = 0
	# + 1: the caller's call pushed the return address
	stack_usage_add(stack_usage_symbol, 0, (stack_usage_max - stack_usage_base + 1) * word_size)


# An FFI shim was emitted for the extern just defined: return address,
# saved frame pointer, up to two alignment words, the stack arguments.
void stack_usage_shim(int stack_words):
	stack_usage_add(stack_usage_last_symbol, c" [c-call]", (4 + stack_words) * word_size)


# An export adapter: return address, rbp, rbx and r12-r15, the W
# arguments it pushes; the W body it calls has its own entry.
void stack_usage_adapter(int symbol, int words):
	stack_usage_add(symbol, c" [adapter]", (7 + words) * word_size)


# A --c-abi adapter (code_generator/c_abi.w): the same frame as an
# export adapter; its 5-byte entry stub only jumps to it.
void stack_usage_c_abi_adapter(int symbol, int words):
	stack_usage_add(symbol, c" [c-abi]", (7 + words) * word_size)


void stack_usage_write(char* output_path):
	if (output_path == 0): error(c"--stack-usage needs an output file (-o)")
	string_builder* path = string_new()
	int n = strlen(output_path)
	if ((n > 2) && (output_path[n - 2] == '.') && (output_path[n - 1] == 'o')): n = n - 2
	for i in range(n): string_append_char(path, output_path[i])
	string_append(path, c".su")
	string_builder* text = string_new()
	if (cast(int, stack_usage_lines) != 0):
		for char* line in stack_usage_lines:
			string_append(text, line)
			string_append_char(text, 10)
	int fd = open(path.data, 577, 420)
	if (fd < 0): error3(c"could not write '", path.data, c"'")
	if (text.length > 0): write(fd, text.data, text.length)
	close(fd)
