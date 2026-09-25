/*
Deferred runtime helpers: one facility for the compiler builtins whose
runtime lives in a module the program did not import (f-strings ->
structures/string.w, print/prelude -> structures/prelude.w, var ->
structures/w_dynamic.w, to_json/from_json -> structures/json_codec.w).

A lazy_runtime record names the module and its helpers (a
space-separated list; callers refer to helpers by index). A call site
materializes helper i's address with lazy_emit_helper: directly when
the helper is already defined (the program imported the module
itself), otherwise through the helper's backpatch chain. The drivers
call the builtins' *_finish_import() at a top-level boundary once the
user's files are compiled; lazy_finish_import imports the module
(import_module de-duplicates) and patches every chain. A symbol-table
forward declaration would not survive function_definition's scope
truncation (table_pos = n), so the chains live here.

Chain encoding (addr_chain_link / addr_chain_patch) matches the 'U'
symbol chains: each address slot holds the previous slot's absolute
address and code_offset ends the chain. Every chain slot materializes
a callee, so under arm64 --pac=full it is signed exactly like
sym_get_value's (be_code_ptr_sign, emitted after the slot so the
recorded cell stays the slot's own instruction).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int import_module(char* dotted);


struct lazy_runtime:
	char* module   # dotted import path of the runtime module
	int count      # number of helpers
	char** names   # helper names, indexed like the chains
	int* chains    # backpatch chain heads (0 = no pending site)
	int needed     # set once any call site used the runtime


# Emit an address slot linked onto the chain whose head is `head`
# (0 = empty) and return the new head. The slot is signed for pac=full.
int addr_chain_link(int head):
	if (head == 0):
		head = code_offset
	be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
	be_addr_slot_write(codepos - 4, head)
	int slot = codepos + code_offset - 4
	be_code_ptr_sign()
	return slot


# Write `value` into every slot of the chain whose head is `head`.
void addr_chain_patch(int head, int value):
	if (head == 0):
		return;
	int p = head - code_offset
	while (p):
		int next = be_addr_slot_read(p) - code_offset
		be_addr_slot_write(p, value)
		p = next


lazy_runtime* lazy_runtime_new(char* module, char* names):
	lazy_runtime* rt = new lazy_runtime()
	rt.module = module
	rt.needed = 0
	int count = 1
	int i = 0
	while (names[i]):
		if (names[i] == ' '):
			count = count + 1
		i = i + 1
	rt.count = count
	char** split = cast(char**, malloc(count * __word_size__))
	int* chains = malloc(count * __word_size__)
	int n = 0
	int start = 0
	i = 0
	while (n < count):
		if ((names[i] == ' ') || (names[i] == 0)):
			char* name = malloc(i - start + 1)
			int k = 0
			while (k < i - start):
				name[k] = names[start + k]
				k = k + 1
			name[k] = 0
			split[n] = name
			chains[n] = 0
			n = n + 1
			start = i + 1
		i = i + 1
	rt.names = split
	rt.chains = chains
	return rt


char* lazy_helper_name(lazy_runtime* rt, int i):
	char** names = rt.names
	return names[i]


# Leave helper i's address in eax: directly when the runtime module is
# already compiled, through the helper's backpatch chain otherwise.
void lazy_emit_helper(lazy_runtime* rt, int i):
	rt.needed = 1
	char* name = lazy_helper_name(rt, i)
	if (sym_lookup(name) >= 0):
		sym_get_value(name)
		return;
	int* chains = rt.chains
	chains[i] = addr_chain_link(chains[i])


# Import the runtime module when any call site used it and resolve the
# call sites emitted before the import. rt may be 0 (never used).
void lazy_finish_import(lazy_runtime* rt):
	if (cast(int, rt) == 0):
		return;
	if (rt.needed == 0):
		return;
	import_module(rt.module)
	int* chains = rt.chains
	int i = 0
	while (i < rt.count):
		if (chains[i]):
			addr_chain_patch(chains[i], sym_address(lazy_helper_name(rt, i)))
			chains[i] = 0
		i = i + 1
