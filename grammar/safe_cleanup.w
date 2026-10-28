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


# Compiler-inserted calls bind to their defining file, not a local or
# parameter with the helper's spelling. Follow the same-name symbol chain
# so cleanup remains constant-time in the usual unshadowed case.
int safe_global_symbol(char* name, char* source):
	sym_index_sync()
	if (sym_name_index == 0): return -1
	if ((name in sym_name_index) == 0): return -1
	int position = sym_name_index[name]
	while (position >= 0):
		int symbol = sym_index_offset(position)
		if ((table[symbol + 1] == 'D') || (table[symbol + 1] == 'U')):
			if (ends_with(debug_file_name(sym_decl_file_index(symbol)), source)): return symbol
		position = load_int(sym_index_prev + position * 4)
	return -1


int safe_global_function(char* name, char* source):
	int symbol = safe_global_symbol(name, source)
	if (symbol < 0): return -1
	if (load_int(table + symbol + 10) != 2): return -1
	return symbol


int safe_runtime_call_begin(char* name, char* source):
	int symbol = safe_global_function(name, source)
	if (symbol < 0): error(c"safe: audited cleanup or provenance implementation is missing")
	int saved = stack_pos
	if (direct_callee_ok(symbol)):
		direct_call_record(saved, 1, symbol)
	else:
		sym_emit_value(symbol, name)
		push_slot()
		direct_call_record(saved, 0, 0)
	return saved


# A user foreign contract is a nominal, same-file raw function. Its body is
# audited with the containing module, never inherited from an import or an
# identically named type. Drop declares opacity; send/sync declare threading.
int safe_foreign_file_attested(char* source):
	if (import_attested_paths == 0): return 0
	for i in range(import_attested_paths.length):
		if (import_path_matches_file(import_attested_paths[i], source)): return 1
	return 0


int safe_foreign_hook(int element, char* prefix, int require_definition = 0):
	element = type_unqualified(element)
	if ((type_get_pointer_level(element) != 0) || (type_num_args(element) == 0)): return -1
	if (safe_foreign_file_attested(debug_file_name(type_decl_file_index(element))) == 0): return -1
	char* name = strjoin(prefix, type_get_name(element))
	int symbol = safe_global_symbol(name, debug_file_name(type_decl_file_index(element)))
	free(name)
	if (symbol < 0): return -1
	if (require_definition && (table[symbol + 1] != 'D')):
		error(c"safe: audited foreign hook requires a definition in its type's module")
	if ((load_int(table + symbol + 10) != 2) || (sym_num_args(symbol) != 1) || (load_int(table + symbol + 6) != type_lookup(c"void"))):
		error(c"safe: audited foreign hook requires void hook(Type*)")
	int parameter = type_unqualified(sym_param_type(symbol, 0))
	if ((type_safe_kind(parameter) != 0) || (type_get_pointer_level(parameter) != 1)):
		error(c"safe: audited foreign hook requires void hook(Type*)")
	if (type_unqualified(type_lookup_previous_pointer(parameter)) != element):
		error(c"safe: audited foreign hook requires void hook(Type*)")
	return symbol


# Generated destructor calls have no source expression for the safety pass
# to resolve. Match the sealed type and the already-defined helper against
# the same audited source; safe_audit_runtime also verifies its content hash.
char* safe_owner_drop_helper(int element):
	element = type_unqualified(element)
	char* source = debug_file_name(type_decl_file_index(element))
	char* name = type_get_name(element)
	char* helper = 0
	# The helper's parameter points at this record, except that every
	# WSafeGuard[T] instance shares one helper over its mutex's lock word.
	int pointee = element
	int foreign = safe_foreign_hook(element, c"__w_foreign_drop_")
	if (foreign >= 0): return strjoin(c"__w_foreign_drop_", name)
	# Dropping an unjoined checked thread handle waits for its child.
	if (ends_with(source, c"/lib/safe_thread.w")):
		if (strcmp(name, c"WSafeThread") == 0): helper = c"__w_safe_thread_drop"
		# Dropping a lock guard releases its mutex.
		else if (starts_with(name, c"WSafeGuard$")):
			helper = c"__w_safe_guard_drop"
			pointee = type_lookup(c"wmutex")
	# Every pointer-free WBuffer[T] specialization shares one helper over
	# the common descriptor layout.
	else if (ends_with(source, c"/lib/safe_vector.w")):
		if (starts_with(name, c"WBuffer$")):
			helper = c"__w_buffer_drop"
			pointee = type_lookup(c"void")
	# Every WOwnedBuffer[T] specialization records its element destructor
	# in the descriptor; one helper drops the elements and the storage.
	else if (ends_with(source, c"/lib/safe_owned_vector.w")):
		if (starts_with(name, c"WOwnedBuffer$")):
			helper = c"__w_owned_buffer_drop"
			pointee = type_lookup(c"void")
	# Typed arenas record their object destructor like owned buffers; one
	# helper drops the live objects, skipping holes, and the slot storage.
	else if (ends_with(source, c"/lib/safe_typed_arena.w")):
		if (starts_with(name, c"WTypedArena$")):
			helper = c"__w_typed_arena_drop"
			pointee = type_lookup(c"void")
		# A budget arena also refunds its budget for the objects it drops.
		else if (starts_with(name, c"WBudgetArena$")):
			helper = c"__w_budget_arena_drop"
			pointee = type_lookup(c"void")
	# Keyed maps record their key destructor; one helper drops keys and slots.
	else if (ends_with(source, c"/lib/safe_keyed_map.w")):
		if (starts_with(name, c"WKeyedMap$")):
			helper = c"__w_keyed_map_drop"
			pointee = type_lookup(c"void")
	# A foreign owner runs its recorded release function once.
	else if (ends_with(source, c"/lib/safe_foreign_owner.w")):
		if (starts_with(name, c"WForeign$")):
			helper = c"__w_foreign_drop"
			pointee = type_lookup(c"void")
	# Checked maps/sets wrap one legacy table pointer; one helper frees it.
	else if (ends_with(source, c"/lib/safe_hash.w")):
		if (starts_with(name, c"WMap$") || starts_with(name, c"WSet$")):
			helper = c"__w_checked_hash_drop"
			pointee = type_lookup(c"void")
	else if (ends_with(source, c"/lib/safe_buffer.w") == 0): return 0
	else if (strcmp(name, c"WIntBuffer") == 0): helper = c"__w_int_buffer_drop"
	else if (strcmp(name, c"WByteString") == 0): helper = c"__w_byte_string_drop"
	else if (strcmp(name, c"WOwnedIntBuffer") == 0): helper = c"__w_owned_int_buffer_drop"
	else if (strcmp(name, c"WByteArena") == 0): helper = c"__w_byte_arena_drop"
	if (helper == 0): return 0
	int symbol = safe_global_function(helper, source)
	if (symbol < 0): error(c"safe: audited destructor implementation is missing")
	if ((table[symbol + 1] != 'D') || (strcmp(debug_file_name(sym_decl_file_index(symbol)), source) != 0)):
		error(c"safe: audited destructor resolved to a different implementation")
	if ((sym_num_args(symbol) != 1) || (load_int(table + symbol + 6) != type_lookup(c"void"))):
		error(c"safe: audited destructor signature differs from its contract")
	int parameter = type_unqualified(sym_param_type(symbol, 0))
	if ((type_safe_kind(parameter) != 0) || (type_get_pointer_level(parameter) != 1)):
		error(c"safe: audited destructor signature differs from its contract")
	if ((pointee < 0) || (type_unqualified(type_lookup_previous_pointer(parameter)) != pointee)):
		error(c"safe: audited destructor signature differs from its contract")
	return helper


# Validate owner-valued calls, including calls through a checked function
# value. The runtime is disabled unless the linked program attests a module.
# A nominal foreign destructor deliberately replaces W allocator provenance.
void safe_foreign_owner_result(int type):
	if (type_safe_kind(type) != 1): return
	int element = type_unqualified(type_lookup_previous_pointer(type))
	int size = type_get_size(element)
	if (safe_foreign_hook(element, c"__w_foreign_drop_") >= 0): size = 0 - size
	int value = push_slot()
	int call_stack = safe_runtime_call_begin(c"__w_foreign_owner_check", c"/lib/memory_provenance.w")
	push_slot_copy(value)
	mov_eax_int(size)
	push_slot()
	mov_eax_int(type_get_kind(type_unqualified(type)) == type_kind_optown)
	push_slot()
	rt_call_end(call_stack)
	drop_slots(1)


# Drop owned fields in reverse declaration order, then the allocation.
# The descriptor is held in a stack slot across nested allocator calls.
# Emission is bounded before the semantic pass runs: recursive type graphs
# cannot make the compiler recurse forever while building the destructor.
# A shared node budget also bounds repeated expansion of acyclic DAGs.
void safe_owner_drop_value(int type, int depth, int* remaining):
	if (*remaining <= 0): error(c"safe: owned aggregate destruction exceeds 256 expanded allocations")
	*remaining = *remaining - 1
	if (depth > 32): error(c"safe: recursive owned aggregate destruction is not supported")
	int done = be_ctrl_block()
	be_br_zero(done)
	int object_slot = push_slot()
	int element = type_lookup_previous_pointer(type)
	char* helper = safe_owner_drop_helper(element)
	if (helper != 0):
		int helper_stack = safe_runtime_call_begin(helper, debug_file_name(type_decl_file_index(type_unqualified(element))))
		push_slot_copy(object_slot)
		rt_call_end(helper_stack)
		drop_slots(1)
		be_ctrl_end(done)
		return
	int field = type_num_args(element)
	while (field > 0):
		field = field - 1
		int field_type = type_get_field_type_at(element, field)
		if (type_safe_kind(field_type) == 1):
			load_slot(object_slot)
			add_eax_int32(type_get_field_offset_at(element, field))
			promote(field_type)
			safe_owner_drop_value(field_type, depth + 1, remaining)
	int call_stack = safe_runtime_call_begin(c"free", c"/lib/memory.w")
	push_slot_copy(object_slot)
	rt_call_end(call_stack)
	drop_slots(1)
	be_ctrl_end(done)


# A transferred owner has a cleared source slot; cleanup is idempotent on
# that path, including when an aggregate's child owner moved into its fields.
void safe_owner_drop_slot(int slot, int type):
	int element = type_lookup_previous_pointer(type)
	int recursive = safe_owner_drop_helper(element) != 0
	for field in range(type_num_args(element)):
		if (type_safe_kind(type_get_field_type_at(element, field)) == 1): recursive = 1
	load_slot(slot)
	# Plain allocations retain the original cleanup sequence: the owner
	# slot itself preserves the pointer across free, without a second slot.
	if (recursive == 0):
		int done = be_ctrl_block()
		be_br_zero(done)
		int call_stack = safe_runtime_call_begin(c"free", c"/lib/memory.w")
		push_slot_copy(slot)
		rt_call_end(call_stack)
		mov_eax_int(0)
		store_stack_var((stack_pos - slot) << word_size_log2)
		be_ctrl_end(done)
		return
	int remaining = 256
	safe_owner_drop_value(type, 0, &remaining)
	mov_eax_int(0)
	store_stack_var((stack_pos - slot) << word_size_log2)


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
		safe_owner_drop_slot(safe_owner_slot(symbol), load_int(table + symbol + 6))


void safe_owner_cleanup_returning():
	if (type_safe_used == 0): return
	push_slot()
	safe_owner_cleanup(0, -1, 1)
	pop_eax_slot()


# Produce the address of an owned field along a stable projection chain.
# The semantic pass enforces the same unique-owner path and initialization.
void safe_owner_field_address(expression_ast* tree, int root):
	int base = tree.left[root]
	if ((base < 0) || (type_safe_kind(tree.result_type[base]) != 1)):
		error(c"safe: partial move requires a stable unique owner path")
	if ((tree.op[base] == 'v') && (tree.binding_name[base] >= 0)):
		load_slot(0 - tree.binding_offset[base])
	else if (tree.op[base] == '.'):
		safe_owner_field_address(tree, base)
		promote(tree.result_type[base])
	else: error(c"safe: partial move requires a stable unique owner path")
	add_eax_int32(tree.value[root])


# Called after promotion while eax holds the transferred pointer. The
# expression's captured frame offset survives retained-tree emission.
void safe_owner_move(expression_ast* tree, int root, int destination):
	if (type_safe_kind(destination) != 1): return
	if ((tree == 0) || (root < 0)): return
	if (type_safe_kind(tree.result_type[root]) != 1): return
	if (tree.op[root] == '.'):
		# Preserve the transferred pointer before replaying the effect-free
		# named ownership path and clearing exactly its source slot.
		push_slot()
		safe_owner_field_address(tree, root)
		push_slot()
		pop_ebx_slot()
		mov_eax_int(0)
		assign_store(destination)
		pop_eax_slot()
		return
	if (tree.op[root] != 'v'): return
	if (tree.binding_name[root] < 0): return
	safe_owner_clear_slot(0 - tree.binding_offset[root])
