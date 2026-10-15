# Checked owners use the ordinary pointer ABI. A transferred owner leaves
# a null slot; exit cleanup skips that slot. No runtime ownership table is
# needed, and these semantics apply independently of --safe.

# The symbol's home is a stack_pos anchor. Arguments live below the
# function's local stack and therefore have non-positive anchors.
int safe_owner_slot(int symbol):
	int slot = load_int(table + symbol + 2) + 1
	if (table[symbol + 1] == 'A'): slot = slot - number_of_args - 2
	return slot


int safe_owner_binding(int symbol):
	if (symbol < 0): return 0
	int scope = table[symbol + 1]
	if ((scope != 'L') && (scope != 'A')): return 0
	return type_safe_kind(load_int(table + symbol + 6)) == 1


void safe_owner_clear_slot(int slot):
	push_slot()
	mov_eax_int(0)
	store_stack_var((stack_pos - slot) << word_size_log2)
	pop_eax_slot()


# Drop only live owners, so allocator hooks also observe exactly one free
# per allocation. Every admitted owner currently owns one plain allocation;
# reference-bearing aggregates are rejected by the checker.
void safe_owner_drop_slot(int slot):
	load_slot(slot)
	int done = be_ctrl_block()
	be_br_zero(done)
	int call_stack = rt_call_begin(c"free")
	push_slot_copy(slot)
	rt_call_end(call_stack)
	mov_eax_int(0)
	store_stack_var((stack_pos - slot) << word_size_log2)
	be_ctrl_end(done)


# min_binding selects a lexical scope; min_depth selects a jump's unwind
# range. Function exits pass -1 and include parameters. Do not mutate the
# compiler's owner state here: other emitted control-flow edges still need
# their own cleanup, and runtime slots carry the path-dependent state.
void safe_owner_cleanup(int min_binding, int min_depth, int parameters):
	if (type_safe_used == 0): return
	sym_index_sync()
	int i = sym_index_count
	while (i > 0):
		i = i - 1
		int symbol = sym_index_offset(i)
		if (symbol < min_binding): break
		if (safe_owner_binding(symbol) == 0): continue
		if (table[symbol + 1] == 'A'):
			if (parameters == 0): continue
		else if (load_int(table + symbol + 2) < min_depth): continue
		safe_owner_drop_slot(safe_owner_slot(symbol))


void safe_owner_cleanup_returning():
	if (type_safe_used == 0): return
	push_slot()
	safe_owner_cleanup(0, -1, 1)
	pop_eax_slot()


# Called after promotion while eax holds the transferred pointer. The
# expression's captured frame offset survives retained-tree emission.
void safe_owner_move(expression_ast* tree, int root, int destination):
	if (type_safe_kind(destination) != 1): return
	if ((tree == 0) || (root < 0)): return
	if (type_safe_kind(tree.result_type[root]) != 1): return
	if (tree.op[root] != 'v'): return
	if (tree.binding_name[root] < 0): return
	safe_owner_clear_slot(0 - tree.binding_offset[root])
