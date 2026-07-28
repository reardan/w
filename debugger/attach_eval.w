/*
Restricted expression evaluation for wdbg's attach mode (#123 phase 6,
docs/projects/debugger_attach.md).

Attach mode debugs a separate process through ptrace, so the in-process
evaluator (debugger/eval.w, which compiles the expression and RUNS it in
wdbg's own address space against directly-addressable debuggee globals)
cannot be reused: the generated code would read wdbg's memory, not the
target's. Instead this is a small interpreter over the same compiler
tables the attach session already reconstructed by recompiling the source
(symbol table, type table, debug_local_* notes), with every memory access
going through the target-access seam (debugger/memory.w), which attach
mode backs with PTRACE_PEEKDATA/POKEDATA.

The grammar is deliberately restricted -- no function calls (an in-target
call needs execution, out of scope), no assignment operators, integer
arithmetic only:

	expr    := term (('+' | '-') term)*
	term    := unary (('*' | '/' | '%') unary)*
	unary   := '*' unary | '&' unary | '-' unary | postfix
	postfix := primary ('.' field | '[' expr ']')*
	primary := '(' expr ')' | number | name

Semantics mirror the language where they overlap: '.' works on a struct
value or (one level of) struct pointer, '[i]' scales by the element size,
'*' reads at the pointee's width, and 'T* + int' keeps the pointer's type
but offsets by raw bytes, exactly like compiled W. Results carry an
optional lvalue (address + type), so 'set' can write through any field or
element the same walk resolves, and narrow (sub-word) lvalues are written
read-modify-write so a byte-sized field's neighbours survive the ptrace
word poke.
*/
import lib.lib
import debugger.locals


# Result of evaluating one (sub)expression. When is_lval is 1 the value
# lives in target memory at addr (val is then only filled by aev_load);
# otherwise val holds a computed word. vtype is a type-table index, or -1
# for untyped values (literals, arithmetic results).
struct at_val:
	int ok
	int val
	int vtype
	int addr
	int is_lval


# --- evaluation state (one evaluation at a time; no reentrancy needed) ---
char* aev_text
int aev_pos
int aev_pc     /* selected frame's pc, in-process (table) address */
int aev_esp    /* selected frame's sp at its statement boundary */
int aev_failed /* 1 once a diagnostic was printed for this evaluation */


at_val aev_fail():
	at_val v
	v.ok = 0
	v.val = 0
	v.vtype = -1
	v.addr = 0
	v.is_lval = 0
	return v


# Report one diagnostic per evaluation (the first -- deepest -- error
# wins; enclosing productions just propagate the failed result).
at_val aev_error(char* msg, char* detail):
	if (aev_failed == 0):
		print(c"cannot evaluate: ")
		print(msg)
		if (detail[0] != 0):
			print(c" '")
			print(detail)
			print(c"'")
		put_char(10)
	aev_failed = 1
	return aev_fail()


void aev_skip_spaces():
	while (aev_text[aev_pos] == ' '):
		aev_pos = aev_pos + 1


# Next non-space character without consuming it (0 at end of text).
int aev_peek_char():
	aev_skip_spaces()
	return aev_text[aev_pos] & 255


int aev_is_ident_char(int c):
	if ((c >= 'a') && (c <= 'z')):
		return 1
	if ((c >= 'A') && (c <= 'Z')):
		return 1
	if ((c >= '0') && (c <= '9')):
		return 1
	return c == '_'


# Read an identifier at the cursor into a fresh buffer, or 0 when the
# cursor is not at one.
char* aev_read_ident():
	aev_skip_spaces()
	int start = aev_pos
	while (aev_is_ident_char(aev_text[aev_pos] & 255)):
		aev_pos = aev_pos + 1
	int n = aev_pos - start
	if (n == 0):
		return 0
	char* s = malloc(n + 1)
	int i = 0
	while (i < n):
		s[i] = aev_text[start + i]
		i = i + 1
	s[n] = 0
	return s


# 1 when the type is a struct held by value (fields inline at the lvalue
# address), the same test locals.w and eval.w use.
int aev_is_struct_value(int t):
	if (t < 0):
		return 0
	if (type_get_pointer_level(t) != 0):
		return 0
	return type_num_args(t) > 0


# Read width for a type: its size clamped to one word (struct values are
# handled by address, never loaded whole). Untyped values read full words.
int aev_width(int t):
	if (t < 0):
		return __word_size__
	int size = type_get_size(t)
	if ((size <= 0) || (size > __word_size__)):
		return __word_size__
	return size


# Convert an lvalue to its loaded value (through the memory seam, so this
# is a ptrace peek in attach mode). Struct values stay address-flavored:
# their "value" IS the address, like everywhere else in the debugger.
at_val aev_load(at_val v):
	if (v.ok == 0):
		return v
	if (v.is_lval == 0):
		return v
	if (aev_is_struct_value(v.vtype)):
		v.val = v.addr
		return v
	if (dbg_mem_readable(v.addr, aev_width(v.vtype)) == 0):
		return aev_error(c"value is not addressable here", c"")
	v.val = dbg_mem_read(v.addr, aev_width(v.vtype))
	return v


# Write `value` into `width` bytes at addr through the memory seam. A
# narrow write merges into the containing word (read-modify-write): the
# ptrace backend can only poke whole words, and a word-sized store over a
# byte-sized field would clobber its neighbours.
int aev_write(int addr, int width, int value):
	if (dbg_mem_readable(addr, __word_size__) == 0):
		return 0
	if (width >= __word_size__):
		return dbg_mem_write_word(addr, value)
	int word = dbg_mem_read_word(addr)
	int mask = (1 << (width * 8)) - 1
	word = word - (word & mask) + (value & mask)
	return dbg_mem_write_word(addr, word)


# A name: local or argument of the selected frame first (last visible
# declaration wins, so shadowing works), then a defined data global --
# the same resolution order the bare-name lookup always used.
at_val aev_name(char* name):
	at_val v = aev_fail()
	int note = dbg_local_find(name, aev_pc)
	if (note >= 0):
		v.ok = 1
		v.addr = dbg_local_runtime_addr(note, aev_esp)
		v.vtype = dbg_local_type(note)
		v.is_lval = 1
		return v
	int g = dbg_global_find(name)
	if (g >= 0):
		if (dbg_sym_symtype(g) != 2):
			v.ok = 1
			v.addr = dbg_sym_address(g)
			v.vtype = dbg_sym_type(g)
			v.is_lval = 1
			return v
	return aev_error(c"unknown variable", name)


# Decimal or 0x hexadecimal literal at the cursor (first char is a digit).
at_val aev_number():
	int value = 0
	if ((aev_text[aev_pos] == '0') && ((aev_text[aev_pos + 1] == 'x') || (aev_text[aev_pos + 1] == 'X'))):
		aev_pos = aev_pos + 2
		while (1):
			int c = aev_text[aev_pos] & 255
			int d = -1
			if ((c >= '0') && (c <= '9')):
				d = c - '0'
			else if ((c >= 'a') && (c <= 'f')):
				d = c - 'a' + 10
			else if ((c >= 'A') && (c <= 'F')):
				d = c - 'A' + 10
			if (d < 0):
				break
			value = value * 16 + d
			aev_pos = aev_pos + 1
	else:
		while ((aev_text[aev_pos] >= '0') && (aev_text[aev_pos] <= '9')):
			value = value * 10 + (aev_text[aev_pos] - '0')
			aev_pos = aev_pos + 1
	at_val v
	v.ok = 1
	v.val = value
	v.vtype = -1
	v.addr = 0
	v.is_lval = 0
	return v


at_val aev_expr();


at_val aev_primary():
	int c = aev_peek_char()
	if (c == '('):
		aev_pos = aev_pos + 1
		at_val v = aev_expr()
		if (v.ok == 0):
			return v
		if (aev_peek_char() != ')'):
			return aev_error(c"expected ')'", c"")
		aev_pos = aev_pos + 1
		return v
	if ((c >= '0') && (c <= '9')):
		return aev_number()
	if (aev_is_ident_char(c)):
		char* name = aev_read_ident()
		if (aev_peek_char() == '('):
			at_val e = aev_error(c"function calls are not supported in attach mode", name)
			free(name)
			return e
		at_val v = aev_name(name)
		free(name)
		return v
	return aev_error(c"expected a name, number or '('", c"")


# base.field: fields inline for a struct value, through one load for a
# struct pointer -- the same auto-deref compiled '.' performs
# (grammar/postfix_expr.w).
at_val aev_field(at_val base, char* field):
	int t = base.vtype
	if (t < 0):
		return aev_error(c"no fields on an untyped value", field)
	int base_addr = 0
	if (aev_is_struct_value(t)):
		if (base.is_lval == 0):
			return aev_error(c"struct value has no address", field)
		base_addr = base.addr
	else if (type_get_pointer_level(t) > 0):
		int element = type_lookup_previous_pointer(t)
		if ((element < 0) || (type_num_args(element) == 0)):
			return aev_error(c"not a struct", type_get_name(t))
		at_val loaded = aev_load(base)
		if (loaded.ok == 0):
			return loaded
		base_addr = loaded.val
		t = element
	else:
		return aev_error(c"not a struct", type_get_name(t))
	int ftype = type_get_field_type(t, field)
	if (ftype < 0):
		return aev_error(c"no such field", field)
	at_val v
	v.ok = 1
	v.val = 0
	v.addr = base_addr + type_get_field_offset(t, field)
	v.vtype = ftype
	v.is_lval = 1
	return v


# base[i]: pointer indexing, scaled by the element size like compiled
# indexing (never the raw byte offset 'p + i' would give). An untyped
# base is treated as a word pointer.
at_val aev_index(at_val base):
	at_val idx = aev_load(aev_expr())
	if (idx.ok == 0):
		return idx
	if (aev_peek_char() != ']'):
		return aev_error(c"expected ']'", c"")
	aev_pos = aev_pos + 1
	int t = base.vtype
	int element = -1
	if (t >= 0):
		if (type_get_pointer_level(t) == 0):
			return aev_error(c"not indexable", type_get_name(t))
		element = type_lookup_previous_pointer(t)
	at_val loaded = aev_load(base)
	if (loaded.ok == 0):
		return loaded
	int esize = __word_size__
	if (element >= 0):
		if (type_get_size(element) > 0):
			esize = type_get_size(element)
	at_val v
	v.ok = 1
	v.val = 0
	v.addr = loaded.val + idx.val * esize
	v.vtype = element
	v.is_lval = 1
	return v


at_val aev_postfix():
	at_val v = aev_primary()
	while (v.ok):
		int c = aev_peek_char()
		if (c == '.'):
			aev_pos = aev_pos + 1
			char* field = aev_read_ident()
			if (field == 0):
				return aev_error(c"expected a field name after '.'", c"")
			v = aev_field(v, field)
			free(field)
		else if (c == '['):
			aev_pos = aev_pos + 1
			v = aev_index(v)
		else:
			return v
	return v


at_val aev_unary():
	int c = aev_peek_char()
	if (c == '*'):
		aev_pos = aev_pos + 1
		at_val v = aev_load(aev_unary())
		if (v.ok == 0):
			return v
		int element = -1
		if (v.vtype >= 0):
			if (type_get_pointer_level(v.vtype) == 0):
				return aev_error(c"cannot dereference a non-pointer", type_get_name(v.vtype))
			element = type_lookup_previous_pointer(v.vtype)
		at_val r
		r.ok = 1
		r.val = 0
		r.addr = v.val
		r.vtype = element
		r.is_lval = 1
		return r
	if (c == '&'):
		aev_pos = aev_pos + 1
		at_val v = aev_unary()
		if (v.ok == 0):
			return v
		if (v.is_lval == 0):
			return aev_error(c"cannot take the address of a computed value", c"")
		at_val r
		r.ok = 1
		r.val = v.addr
		r.vtype = -1
		if (v.vtype >= 0):
			# Keep the pointer type when its record already exists (it does
			# whenever the program itself mentions T*); untyped otherwise.
			r.vtype = type_lookup_pointer(type_get_name(v.vtype), type_get_pointer_level(v.vtype) + 1)
		r.addr = 0
		r.is_lval = 0
		return r
	if (c == '-'):
		aev_pos = aev_pos + 1
		at_val v = aev_load(aev_unary())
		if (v.ok == 0):
			return v
		v.val = 0 - v.val
		v.vtype = -1
		v.addr = 0
		v.is_lval = 0
		return v
	return aev_postfix()


at_val aev_term():
	at_val left = aev_unary()
	while (left.ok):
		int c = aev_peek_char()
		if ((c != '*') && (c != '/') && (c != '%')):
			return left
		aev_pos = aev_pos + 1
		left = aev_load(left)
		if (left.ok == 0):
			return left
		at_val right = aev_load(aev_unary())
		if (right.ok == 0):
			return right
		if ((c != '*') && (right.val == 0)):
			return aev_error(c"division by zero", c"")
		if (c == '*'):
			left.val = left.val * right.val
		else if (c == '/'):
			left.val = left.val / right.val
		else:
			left.val = left.val % right.val
		left.vtype = -1
		left.addr = 0
		left.is_lval = 0
	return left


at_val aev_expr():
	at_val left = aev_term()
	while (left.ok):
		int c = aev_peek_char()
		if ((c != '+') && (c != '-')):
			return left
		aev_pos = aev_pos + 1
		left = aev_load(left)
		if (left.ok == 0):
			return left
		at_val right = aev_load(aev_term())
		if (right.ok == 0):
			return right
		# 'T* + int' keeps the pointer's type and offsets by raw bytes,
		# exactly like the language itself; use [i] for scaled access.
		int rtype = -1
		if (left.vtype >= 0):
			if (type_get_pointer_level(left.vtype) > 0):
				rtype = left.vtype
		if (c == '+'):
			left.val = left.val + right.val
		else:
			left.val = left.val - right.val
		left.vtype = rtype
		left.addr = 0
		left.is_lval = 0
	return left


# Evaluate `text` at a stop: pc is the selected frame's in-process (table)
# address, esp its statement-boundary sp -- the same pair locals.w takes.
# On failure a diagnostic was already printed and .ok is 0. A successful
# result keeps its lvalue (address + type) un-loaded, so 'set'/'watch' can
# write or watch through it and printing can defer to dbg_print_typed_value
# (which renders structs, string previews and unreadable addresses itself).
at_val at_eval_text(char* text, int pc, int esp):
	aev_text = text
	aev_pos = 0
	aev_pc = pc
	aev_esp = esp
	aev_failed = 0
	at_val v = aev_expr()
	if (v.ok == 0):
		return v
	if (aev_peek_char() != 0):
		return aev_error(c"unexpected text after expression", aev_text + aev_pos)
	return v


# Print an evaluated result: typed lvalues through dbg_print_typed_value
# (struct rendering, char* previews, "<unreadable at ...>"), untyped
# lvalues as one word, computed values directly.
void aev_print_result(at_val v):
	if (v.is_lval):
		if (v.vtype >= 0):
			dbg_print_typed_value(v.addr, v.vtype)
			return;
		if (dbg_mem_readable(v.addr, __word_size__) == 0):
			print(c"<unreadable at ")
			char* h = hex_word(v.addr)
			print(h)
			free(h)
			print(c">")
			return;
		dbg_print_int_value(dbg_mem_read_word(v.addr))
		return;
	dbg_print_int_value(v.val)
