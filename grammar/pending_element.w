# Pending pseudo-lvalues: a map element (grammar/hash_builtin.w) or an
# ndarray element (grammar/ndarray_index.w) parks its operands (map and
# key, or receiver and indices) in stack slots until expression()
# decides between a read, a store and a compound store. The finishing
# code first takes a "park" of those operands (base stack position,
# operand count, operand slots), because a nested element inside the
# right-hand side re-fills the module's globals; every access then
# lowers to a runtime call over the parked operands.

int promote(int type);
void coerce_checked(int want, int got, char* context);
int compound_assign_rhs(int op, int left_type);


# A park of n operand slots above stack position base; the caller
# fills park[2 .. n + 2).
int* park_new(int base, int n):
	int* park = cast(int*, malloc((n + 2) * __word_size__))
	park[0] = base
	park[1] = n
	return park


# fn(parked operands[, value_slot]) with the result in eax; the parked
# slots stay. value_slot 0 means no trailing value argument.
void park_call(int* park, char* fn, int value_slot):
	int s = rt_call_begin(fn)
	int i = 0
	while (i < park[1]):
		push_slot_copy(park[i + 2])
		i = i + 1
	if (value_slot): push_slot_copy(value_slot)
	rt_call_end(s)


# Read: fn(parked operands) into eax, then drop the parked slots.
void park_load(int* park, char* fn):
	park_call(park, fn, 0)
	pop_to(park[0])
	free(park)


# Store: fn(parked operands, value). Like '=', the expression yields
# the stored value.
int park_store(int* park, char* fn, int value_slot, int value_type):
	park_call(park, fn, value_slot)
	load_slot(value_slot)
	pop_to(park[0])
	free(park)
	return type_value(value_type)


# element op= rhs: read through get_fn, combine with the parsed
# right-hand side, store through set_fn over the same parked operands,
# so every operand is evaluated exactly once.
int park_compound(int* park, int op, int value_type, char* context, char* get_fn, char* set_fn):
	park_call(park, get_fn, 0)
	# Same shape the scalar path feeds compound_assign_apply: loaded
	# left value on top of the stack, promoted right value in eax.
	int result_type = compound_assign_rhs(op, type_value(value_type))
	coerce_checked(value_type, result_type, context)
	int value_slot = push_slot()
	return park_store(park, set_fn, value_slot, value_type)
