# Compiler assistance for the native execution checker. Requests are UD2
# instructions followed by a versioned payload, so running an assisted
# executable without the checker fails before application startup. The
# checker consumes the request without changing registers or flags.
#
# Layout (24 bytes, little endian): UD2, "WGRD", version, event, two u64
# payloads. Events: 0 handshake, 1 malloc entry, 2 free entry, 3 realloc
# entry, 4 allocator return, 5 source position, 6 uninitialized stack local,
# 7 unsupported allocator-hook registration (must fail before user callbacks).
# Allocation entries precede the prologue and use the W stack ABI. Return
# requests follow frame teardown, with the result still in RAX.
# Allocation payload1 identifies the corresponding allocator-hook cell;
# its value must be defined zero before the checker trusts the allocator.
import code_generator.code_emitter


int wgrind_generate_mode
int wgrind_allocator_kind

int sym_decl_file_index(int symbol);
char* debug_file_name(int index);
int sym_address(char* name);


void wgrind_emit_request(int event, int first, int second):
	if (wgrind_generate_mode == 0): return
	emit(7, c"\x0f\x0bWGRD\x01")
	emit_int8(event)
	emit_int64(first)
	emit_int64(second)


void wgrind_function_define(int symbol, char* name):
	wgrind_allocator_kind = 0
	if (wgrind_generate_mode == 0): return
	# Only the toolchain allocator has this modeled contract. A private or
	# imported function merely sharing its short name is ordinary code.
	char* source = debug_file_name(sym_decl_file_index(symbol))
	if ((strcmp(source, c"lib/memory.w") != 0) && (ends_with(source, c"/lib/memory.w") == 0)): return
	if (strcmp(name, c"malloc") == 0): wgrind_allocator_kind = 1
	elif (strcmp(name, c"free") == 0): wgrind_allocator_kind = 2
	elif (strcmp(name, c"realloc") == 0): wgrind_allocator_kind = 3
	elif (strcmp(name, c"malloc_hook_set") == 0): wgrind_allocator_kind = 7


void wgrind_function_enter():
	int hook = 0
	if (wgrind_allocator_kind == 1): hook = sym_address(c"malloc_hook_malloc")
	elif (wgrind_allocator_kind == 2): hook = sym_address(c"malloc_hook_free")
	elif (wgrind_allocator_kind == 3): hook = sym_address(c"malloc_hook_realloc")
	if (wgrind_allocator_kind): wgrind_emit_request(wgrind_allocator_kind, hook, 0)


void wgrind_function_return():
	if ((wgrind_allocator_kind > 0) && (wgrind_allocator_kind < 4)): wgrind_emit_request(4, wgrind_allocator_kind, 0)
