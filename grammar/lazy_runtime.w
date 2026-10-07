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

Chain encoding (addr_chain_link / addr_chain_patch, compiler/symbol_table.w)
matches the 'U'
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
	int* rel_chains  # direct-call rel32 chain heads (unit A4), 0 = none
	int needed     # set once any call site used the runtime


lazy_runtime* lazy_runtime_new(char* module, char* names):
	lazy_runtime* rt = new lazy_runtime()
	rt.module = module
	rt.needed = 0
	int count = 1
	int i = 0
	while (names[i]):
		if (names[i] == ' '): count = count + 1
		i = i + 1
	rt.count = count
	char** split = cast(char**, malloc(count * __word_size__))
	int* chains = malloc(count * __word_size__)
	int* rel_chains = malloc(count * __word_size__)
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
			rel_chains[n] = 0
			n = n + 1
			start = i + 1
		i = i + 1
	rt.names = split
	rt.chains = chains
	rt.rel_chains = rel_chains
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


# Begin a call of helper i under the runtime-call protocol of
# grammar/stack_slot.w: returns the call's stack base. A direct call
# (unit A4) records the helper -- by symbol when the module is already
# compiled, else as kind 3 (rt, i) for lazy_emit_call -- and parks no
# callee word; otherwise the address is materialized and pushed.
int lazy_call_begin(lazy_runtime* rt, int i):
	int s = stack_pos
	int t = sym_lookup(lazy_helper_name(rt, i))
	if (direct_callee_ok(t)):
		rt.needed = 1
		direct_call_record(s, 1, t)
		return s
	if ((t < 0) && direct_generic_ok()):
		rt.needed = 1
		direct_call_record_aux(s, 3, cast(int, rt), i)
		return s
	lazy_emit_helper(rt, i)
	push_slot()
	direct_call_record(s, 0, 0)
	return s


# The direct-call twin of lazy_emit_helper: `call rel32` linked onto
# helper i's rel32 chain, patched by lazy_finish_import.
void lazy_emit_call(int rt_address, int i):
	lazy_runtime* rt = cast(lazy_runtime*, rt_address)
	int* rel_chains = rt.rel_chains
	rel_chains[i] = call_direct_link(rel_chains[i])


# Import the runtime module when any call site used it and resolve the
# call sites emitted before the import. rt may be 0 (never used).
void lazy_finish_import(lazy_runtime* rt):
	if (cast(int, rt) == 0): return;
	if (rt.needed == 0): return;
	import_module(rt.module)
	int* chains = rt.chains
	int* rel_chains = rt.rel_chains
	int i = 0
	while (i < rt.count):
		if (chains[i]):
			addr_chain_patch(chains[i], sym_address(lazy_helper_name(rt, i)))
			chains[i] = 0
		if (rel_chains[i]):
			rel_chain_patch(rel_chains[i], sym_address(lazy_helper_name(rt, i)))
			rel_chains[i] = 0
		i = i + 1
