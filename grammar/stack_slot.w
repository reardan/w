# Stack-slot bookkeeping shared by the grammar rules.
#
# Every word the generated code pushes onto the machine stack must be
# mirrored in stack_pos (compiler/symbol_table.w), which local and slot
# addressing is relative to. These helpers keep the emitted push/pop and
# the bookkeeping together. A "slot" is the stack_pos value right after
# its word was pushed; load_slot/push_slot_copy address it relative to
# the current top of stack.
#
# The runtime-call protocol: rt_call_begin(fn) returns the stack position
# the call is based at and, when fn cannot be called directly (below),
# pushes fn's address above it; the caller pushes the arguments
# (push_slot, push_slot_copy, push_slot_int); rt_call_end(s) emits the
# call and pops the arguments (and the address). A caller that needs
# the address of a slot below the base writes it as lea_slot(slot) /
# load_slot(slot) rather than a fixed esp displacement, since the
# callee word's presence depends on the call shape.
#
# Direct calls (docs/projects/codegen_gap_plan.md §2.4, unit A4): a
# callee that is a known W function (direct_callee_ok,
# compiler/symbol_table.w), a generic instantiation the drain compiles
# later or a lazy runtime helper (grammar/lazy_runtime.w) is called with
# one `call rel32` and no callee word. EVERY call's begin side records
# (base, kind, id) on the call-record stack below -- kind 0 when the
# callee word was parked the old way -- and the end side (rt_call_end,
# grammar/postfix_expr.w's finish_call) pops the record and emits the
# call it describes. Calls nest, so the innermost record is always the
# one being ended; a base that does not match is a begin without an end
# (or the reverse), reported as an internal error rather than compiled.
# (Keying by the base alone would not do: a call's first argument may
# begin another call at the very same base.)
# The streaming primary (grammar/identifier.w, grammar/generic.w) cannot
# see the '(' yet, so it leaves a callee NOTE (direct_callee_kind,
# code_generator/code_emitter.w) that the call suffix converts into a
# record, and primary_expr materializes when no '(' follows.


# push eax as a new slot; returns the slot.
int push_slot():
	push_eax()
	stack_pos = stack_pos + 1
	return stack_pos


# Park eax as a new slot (docs/projects/codegen_gap_plan.md §2.3, unit
# A3): the word goes to a free scratch register when the expression
# register stack has one (code_generator/x86.w, ers_push_eax), to the
# real stack otherwise. The slot is counted in stack_pos exactly like a
# pushed one; the emitters redirect every reference to it. Used where
# an operand waits for the other operand of an operator or the right
# side of an assignment, never for a word a callee or a runtime helper
# reads from the stack.
int ers_slot():
	ers_push_eax(1)
	stack_pos = stack_pos + 1
	return stack_pos


# The same, but the accumulator keeps the value after the park (the
# compound forms load through the address they just parked).
int ers_slot_keep():
	ers_push_eax(0)
	stack_pos = stack_pos + 1
	return stack_pos


void push_slot_int(int v):
	mov_eax_int(v)
	push_slot()


void pop_ebx_slot():
	pop_ebx()
	stack_pos = stack_pos - 1


void pop_eax_slot():
	pop_eax()
	stack_pos = stack_pos - 1


# Discards the top n slots.
void drop_slots(int n):
	be_pop(n)
	stack_pos = stack_pos - n


# Discards every slot above stack position base.
void pop_to(int base):
	be_pop(stack_pos - base)
	stack_pos = base


# mov eax, <slot>
void load_slot(int slot):
	regalloc_slot_assert(slot - 1)  # never a promoted local's word
	mov_eax_esp_plus((stack_pos - slot) << word_size_log2)


# Pushes a copy of an earlier slot as a new slot.
void push_slot_copy(int slot):
	load_slot(slot)
	push_slot()


# lea eax, <address of slot>
void lea_slot(int slot):
	regalloc_slot_assert(slot - 1)
	lea_eax_esp_plus((stack_pos - slot) << word_size_log2)


############################ call records ############################
# (base, kind, id, aux) per call in progress, innermost last; see the
# protocol note at the top of this file. kind 0: the callee word was
# pushed (an indirect call, or direct calls off); 1: a function symbol
# (id = table offset); 2: a generic instantiation (id = instance index);
# 3: a lazy runtime helper (id = the lazy_runtime record, aux = helper
# index); 4: a function symbol whose body finish_call emits in place of
# the call (id = the compiler/inline_table.w record, unit A5).

int direct_call_count
int direct_call_capacity
int* direct_call_base
int* direct_call_kind
int* direct_call_id
int* direct_call_aux
# The record the last direct_call_take popped.
int direct_call_taken_kind
int direct_call_taken_id
int direct_call_taken_aux

void generic_inst_emit_callee(int inst);   /* grammar/generic.w */
void generic_inst_emit_call(int inst);     /* grammar/generic.w */
void lazy_emit_call(int rt_address, int i);   /* grammar/lazy_runtime.w */
int identifier_value(char* name);   /* grammar/identifier.w */
int identifier_value_at(int t, char* name);   /* grammar/identifier.w */


void direct_call_record_aux(int s, int kind, int id, int aux):
	if (direct_call_count == direct_call_capacity):
		int cap = direct_call_capacity * 2
		if (cap == 0): cap = 64
		direct_call_base = cast(int*, realloc(cast(char*, direct_call_base), direct_call_capacity * __word_size__, cap * __word_size__))
		direct_call_kind = cast(int*, realloc(cast(char*, direct_call_kind), direct_call_capacity * __word_size__, cap * __word_size__))
		direct_call_id = cast(int*, realloc(cast(char*, direct_call_id), direct_call_capacity * __word_size__, cap * __word_size__))
		direct_call_aux = cast(int*, realloc(cast(char*, direct_call_aux), direct_call_capacity * __word_size__, cap * __word_size__))
		direct_call_capacity = cap
	direct_call_base[direct_call_count] = s
	direct_call_kind[direct_call_count] = kind
	direct_call_id[direct_call_count] = id
	direct_call_aux[direct_call_count] = aux
	direct_call_count = direct_call_count + 1


void direct_call_record(int s, int kind, int id):
	direct_call_record_aux(s, kind, id, 0)


void direct_call_mismatch():
	error(c"internal error: call record does not match the call being ended (compile with --no-direct-calls and report this)")


# 1 when the call based at s (the innermost one) parked no callee word.
int direct_call_pending(int s):
	if (direct_call_count == 0): direct_call_mismatch()
	if (direct_call_base[direct_call_count - 1] != s): direct_call_mismatch()
	return direct_call_kind[direct_call_count - 1] != 0


# Pop the record of the call based at s into direct_call_taken_*: 1 for
# a direct call, 0 when the callee word was pushed.
int direct_call_take(int s):
	if (direct_call_count == 0): direct_call_mismatch()
	direct_call_count = direct_call_count - 1
	if (direct_call_base[direct_call_count] != s): direct_call_mismatch()
	direct_call_taken_kind = direct_call_kind[direct_call_count]
	direct_call_taken_id = direct_call_id[direct_call_count]
	direct_call_taken_aux = direct_call_aux[direct_call_count]
	return direct_call_taken_kind != 0


# The symbol's name, looked up (a scan of the symbol index) only when a
# consumer will read it: the verbose trace and the REPL's late-binding
# registry.
char* direct_callee_name(int t):
	if ((repl_call_site_hook == 0) && (verbosity < 2)): return c""
	char* name = sym_record_name(t)
	if (name == 0): name = c"?"
	return name


# Emit the call the last taken record describes.
void direct_call_emit_taken():
	int id = direct_call_taken_id
	if (direct_call_taken_kind == 1): sym_emit_call(id, direct_callee_name(id))
	elif (direct_call_taken_kind == 2): generic_inst_emit_call(id)
	else: lazy_emit_call(id, direct_call_taken_aux)


# Call the function symbol t whose arguments are already pushed, either
# way: direct when it qualifies, else through the accumulator.
void call_symbol(int t, char* name):
	if (direct_callee_ok(t)):
		sym_emit_call(t, name)
		return;
	sym_emit_value(t, name)
	call_eax()


# The REPL's entry rollback (repl/core.w): a failed entry leaves the
# records of the calls it was inside.
void direct_call_reset():
	direct_call_count = 0


# ---- the pending-callee note (code_generator/code_emitter.w) ----

# 1 when generic instantiations may be called directly (the symbol
# case asks direct_callee_ok).
int direct_generic_ok():
	if (direct_calls_disabled): return 0
	return target_isa == 0


void direct_callee_note(int kind, int id):
	direct_callee_kind = kind
	direct_callee_id = id
	direct_callee_end = codepos


int direct_callee_current():
	if (direct_callee_kind == 0): return 0
	return direct_callee_end == codepos


# Serial (compiler/tokenizer.w token_serial) of the '(' opening the
# innermost '( expression )' group primary_expr is parsing; 0 outside.
# A bare callee wrapped in parentheses -- '(f)(x)' -- then stays a
# direct call, as the AST emitter makes it (grouping leaves no node).
int direct_callee_group


# At primary_expr's end, with a note current: 1 when the note must stay
# pending. A '(' consumes it as a call; a ')' closing a group this
# primary filled (the group's '(' came right before its first token)
# hands the note to the enclosing primary_expr, which decides again.
int direct_callee_keep(int start_serial):
	if (peek(c"(")): return 1
	if (peek(c")") == 0): return 0
	return direct_callee_group == start_serial - 1


# Emit the noted callee's address into eax the way the primary would
# have without the note (no '(' follows, or a call shape that needs the
# value), and clear the note.
void direct_callee_materialize():
	int kind = direct_callee_kind
	int id = direct_callee_id
	direct_callee_kind = 0
	if (kind == 1): sym_emit_value(id, direct_callee_name(id))
	else: generic_inst_emit_callee(id)


# Turn the current note into the record of the call based at s.
void direct_callee_to_record(int s):
	direct_call_record(s, direct_callee_kind, direct_callee_id)
	direct_callee_kind = 0


# The fail-closed diagnostic: something emitted while a callee note was
# current (code_generator/code_emitter.w's guard).
void direct_callee_guard_fail():
	int kind = direct_callee_kind
	int id = direct_callee_id
	direct_callee_kind = 0
	char* name = c"?"
	if (kind == 1): name = sym_record_name(id)
	if (name == 0): name = c"?"
	error3(c"internal error: direct call target '", name, c"' used by an unhandled path (compile with --no-direct-calls and report this)")


int rt_call_begin(char* fn):
	int s = stack_pos
	int t = sym_lookup(fn)
	if (direct_callee_ok(t)):
		direct_call_record(s, 1, t)
		return s
	if (t < 0): sym_not_found_error(fn)
	sym_emit_value(t, fn)
	push_slot()
	direct_call_record(s, 0, 0)
	return s


void rt_call_end(int s):
	if (direct_call_take(s)): direct_call_emit_taken()
	else:
		load_slot(s + 1)
		call_eax()
	pop_to(s)

