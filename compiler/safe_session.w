# Persistent checked REPL and debugger sessions (#713). Reference:
# docs/projects/safe_mode.md, "Persistent REPL and debugger sessions".
#
# The ownership checker (compiler/safe.w) analyzes one function at a time.
# A session is modeled as one growing function, __w_repl_session: every
# committed top-level item that names a checked session binding is replayed,
# in order, into its body, and each top-level declaration becomes a local of
# that function under a unique alias (name__wsN). A new entry is checked by
# recompiling that transcript with the entry's own items appended and running
# the unchanged whole-program checker over it. Nothing in the transcript
# executes; its code, symbols and retained nodes are rolled back before the
# entry runs. Binding identities, initialization and move state, backing
# roots, reborrow ancestry and live loans across entries are therefore the
# checker's own facts about one straight-line function. An item that names
# no checked session binding cannot change that state; it is checked once,
# in its own function (__w_repl_item_N). Checked functions cannot read
# globals, so the plain persistent variables a transcript function reads
# become its parameters.
#
# The executing entry keeps the REPL's ordinary persistent globals. The
# checker's state where the session block ends (before its scope cleanup)
# is read back through safe_function_end_hook: a session owner the entry
# moved has its global cleared after the entry runs, an owner moved on only
# some paths is rejected before anything runs, and owners still held when a
# generation is replaced or the session ends are destroyed here, through
# the session's own audited helpers or free, exactly once and newest first.
#
# Failed entries publish nothing: their generations, items and replacements
# stay pending until safe_session_commit. A runtime fault in an entry that
# changed checked session state discards every checked session binding;
# their owners are leaked, never destroyed twice.
import compiler.compiler

# One generation of a top-level persistent variable, or (view) one local of
# a debugger stop's frame.
struct safe_session_binding:
	char* name
	char* alias
	int symbol          # the executing entry's global (symbol table offset)
	int type            # its type-table type
	int checked         # its ownership and borrow state is modeled
	int owner           # the session destroys it while it is held
	char* spelling      # parameter type text, or 0 when it has none
	int in_session      # declared by an item of the session function
	int view            # a debugger frame local: always a parameter
	int state           # committed flow state (& 7): 2 held, 4 moved or ended
	int pending_state   # state read back from the pending transcript check
	int captured        # pending_state is valid
	int line            # transcript line of its declaring item (per build)
	int discarded       # lost to a runtime fault; never destroyed
	int dropped
	int retired         # replaced by a later declaration of the same name

# One replayed top-level item.
struct safe_session_text:
	char* text
	char* file
	int line
	safe_session_binding* declares
	list[safe_session_binding*] reads   # generations it reads as parameters

list[safe_session_binding*] safe_session_bindings
list[safe_session_text*] safe_session_items
int safe_session_aliases

# The pending entry. Nothing here is visible to later entries until commit.
list[safe_session_binding*] safe_session_new
list[safe_session_binding*] safe_session_retired
list[safe_session_text*] safe_session_new_items
list[safe_session_text*] safe_session_standalone
char* safe_session_entry_path
char* safe_session_entry_text
# 1 while the pending transcript names a checked session binding.
int safe_session_touched
# A nested evaluation (a 'debugger' stop inside an executing entry, or a
# debugger evaluation) may not name, make or replace checked bindings.
int safe_session_nested
# The pending entry compiles without running (:type).
int safe_session_no_run
# Set by the end hook when the session function was analyzed.
int safe_session_seen
int safe_session_reached
# Transcript line -> (entry staging path, entry line), for diagnostics.
list[char*] safe_session_line_files
list[int] safe_session_line_numbers
char* safe_session_transcript_path
# A debugger stop's frame locals (debugger/eval.w), and the checked ones
# that cannot be presented at this stop.
list[safe_session_binding*] safe_session_views
list[char*] safe_session_hidden
list[char*] safe_session_hidden_reasons


type __safe_session_drop_callback = fn(int) -> void


void safe_session_invalidate();


void safe_session_init():
	if (safe_session_bindings != 0): return
	safe_session_bindings = new list[safe_session_binding*]
	safe_session_items = new list[safe_session_text*]
	safe_session_new = new list[safe_session_binding*]
	safe_session_retired = new list[safe_session_binding*]
	safe_session_new_items = new list[safe_session_text*]
	safe_session_standalone = new list[safe_session_text*]
	safe_session_line_files = new list[char*]
	safe_session_line_numbers = new list[int]
	safe_session_views = new list[safe_session_binding*]
	safe_session_hidden = new list[char*]
	safe_session_hidden_reasons = new list[char*]


# 1 when values of type must be modeled by the checker across entries.
int safe_session_type_checked(int type, int depth):
	if (type < 0): return 0
	if (depth > 16): return 1
	type = type_unqualified(type)
	if (type < 0): return 0
	if (type_safe_kind(type)): return 1
	if (type_checked_function_signature(type) >= 0): return 1
	if (type_is_array(type)): return safe_session_type_checked(type_get_element_type(type), depth + 1)
	if ((type_get_pointer_level(type) == 0) && (type_record(type).kind == 0)):
		for i in range(type_num_args(type)):
			if (safe_session_type_checked(type_get_field_type_at(type, i), depth + 1)): return 1
	return 0


# 1 when type, or a field it holds by value, carries lifetime labels
# (own[a] lock guards, labeled borrows and records): their loans tie them to
# another value, which the session cannot keep across entries.
int safe_session_labeled(int type, int depth):
	if ((type < 0) || (depth > 16)): return 0
	type = type_unqualified(type)
	if (type < 0): return 0
	if (type_record(type).safe_lifetime != 0): return 1
	if (type_is_array(type)): return safe_session_labeled(type_get_element_type(type), depth + 1)
	if ((type_get_pointer_level(type) == 0) && (type_record(type).kind == 0)):
		for i in range(type_num_args(type)):
			if (safe_session_labeled(type_get_field_type_at(type, i), depth + 1)): return 1
	return 0


# Source spelling of a plain named type, or 0 when the name would not
# resolve back to exactly this type (redefined structs, generics, arrays).
char* safe_session_spell(int type):
	if (type < 0): return 0
	if (type_is_array(type) || safe_session_type_checked(type, 0)): return 0
	int level = type_get_pointer_level(type)
	char* name = type_get_name(type)
	if (name == 0): return 0
	int real = type_real(type)
	if (level > 0):
		if (type_lookup_pointer(name, level) != real): return 0
	else if (type_lookup(name) != real): return 0
	string_builder* out = string_new()
	string_append(out, name)
	for i in range(level): string_append_char(out, '*')
	char* result = out.data
	free(out)
	return result


# Point a diagnostic at byte offset at of the pending entry's text.
void safe_session_error_at(int at, char* message):
	if ((safe_session_entry_path != 0) && (safe_session_entry_text != 0)):
		int line = 1
		int column = 1
		int i = 0
		while ((i < at) && (safe_session_entry_text[i] != 0)):
			column = column + 1
			if (safe_session_entry_text[i] == 10):
				line = line + 1
				column = 1
			i = i + 1
		filename = safe_session_entry_path
		diag_token_line = line
		diag_token_column = column
		line_number = line - 1
		# The source context is read from the current file: quote the
		# entry, not the transcript (error recovery closes this copy).
		file = open(safe_session_entry_path, 0, 0)
		getchar_reset(file)
	error(message)


int safe_session_listed(list[safe_session_binding*] items, safe_session_binding* b):
	for i in range(items.length):
		if (items[i] == b): return 1
	return 0


# Newest visible binding named name: a debugger frame local, then pending
# generations, then committed generations not replaced by the pending entry.
safe_session_binding* safe_session_lookup(char* name):
	int i = safe_session_new.length
	while (i > 0):
		i = i - 1
		if (strcmp(safe_session_new[i].name, name) == 0): return safe_session_new[i]
	i = safe_session_views.length
	while (i > 0):
		i = i - 1
		if (strcmp(safe_session_views[i].name, name) == 0): return safe_session_views[i]
	i = safe_session_bindings.length
	while (i > 0):
		i = i - 1
		safe_session_binding* b = safe_session_bindings[i]
		if (strcmp(b.name, name) == 0):
			if (b.retired || safe_session_listed(safe_session_retired, b)): return 0
			return b
	return 0


int safe_session_ident_start(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_') || (c >= 128)


int safe_session_ident_part(int c):
	return safe_session_ident_start(c) || ((c >= '0') && (c <= '9'))


# Skip a string or character literal starting at text[i] (the quote).
int safe_session_skip_literal(char* text, int i, int end):
	int quote = text[i]
	if ((quote == '"') && (i + 2 < end) && (text[i + 1] == '"') && (text[i + 2] == '"')):
		i = i + 3
		while (i < end):
			if ((text[i] == '"') && (i + 2 < end) && (text[i + 1] == '"') && (text[i + 2] == '"')): return i + 3
			i = i + 1
		return end
	i = i + 1
	while ((i < end) && (text[i] != quote) && (text[i] != 10)):
		if ((text[i] == 92) && (i + 1 < end)): i = i + 1
		i = i + 1
	if (i < end): i = i + 1
	return i


char* safe_session_slice(char* text, int start, int end):
	char* word = cast(char*, malloc(end - start + 1))
	for k in range(end - start): word[k] = text[start + k]
	word[end - start] = 0
	return word


int safe_session_blank(int c):
	return (c == ' ') || (c == 9) || (c == 10) || (c == 13)


# Indent every line of text by one tab, dropping trailing blank lines, so a
# top-level item becomes a statement of a function body.
void safe_session_indent(string_builder* out, char* text):
	int length = strlen(text)
	while ((length > 0) && safe_session_blank(text[length - 1])): length = length - 1
	int at_line = 1
	for i in range(length):
		if (at_line): string_append_char(out, 9)
		at_line = 0
		string_append_char(out, text[i])
		if (text[i] == 10): at_line = 1
	string_append_char(out, 10)


# 1 when the word ending at i is the target of a plain or compound
# assignment ('=' but not '==').
int safe_session_assigned(char* text, int i, int end):
	while ((i < end) && ((text[i] == ' ') || (text[i] == 9))): i = i + 1
	if (i >= end): return 0
	if ((text[i] == '=') && ((i + 1 >= end) || (text[i + 1] != '='))): return 1
	if ((i + 1 < end) && (text[i + 1] == '=') && (text[i] != '!') && (text[i] != '<') && (text[i] != '>') && (text[i] != '=')): return safe_session_ident_part(text[i]) == 0
	return 0


int safe_session_line_count(char* text):
	int length = strlen(text)
	while ((length > 0) && safe_session_blank(text[length - 1])): length = length - 1
	int lines = 1
	for i in range(length):
		if (text[i] == 10): lines = lines + 1
	return lines


safe_session_text* safe_session_text_new(char* text, int line):
	safe_session_text* item = new safe_session_text
	item.text = text
	item.file = safe_session_entry_path
	item.line = line
	item.declares = 0
	item.reads = new list[safe_session_binding*]
	return item


void safe_session_text_free(safe_session_text* item):
	free(item.text)
	item.reads.free()
	free(cast(char*, item))


safe_session_binding* safe_session_binding_new(char* name, int symbol, int type):
	safe_session_binding* b = new safe_session_binding
	b.name = strclone(name)
	b.alias = cstr(f"{name}__ws{safe_session_aliases}")
	safe_session_aliases = safe_session_aliases + 1
	b.symbol = symbol
	b.type = type
	b.checked = safe_session_type_checked(type, 0)
	b.owner = b.checked && (type_safe_kind(type) == 1)
	b.spelling = 0
	b.in_session = 0
	b.view = 0
	b.state = 0
	b.pending_state = 0
	b.captured = 0
	b.line = 0
	b.discarded = 0
	b.dropped = 0
	b.retired = 0
	return b


void safe_session_binding_free(safe_session_binding* b):
	free(b.name)
	free(b.alias)
	if (b.spelling != 0): free(b.spelling)
	free(cast(char*, b))


# One pass over an item's text. With out == 0 it only classifies the item:
# bit 0 names a checked session binding (not a frame view), bit 1 holds a
# construct the session function cannot replay. With out it writes the renamed text: checked and
# declared bindings always take their alias; a plain generation does when it
# is a local of the function being built or can be declared as its
# parameter, and otherwise stays the global (which a checked function then
# rejects). Returns the classification and, through leading, the offset+1 of
# a leading 'return' in out.
int safe_session_scan(int start, int end, int kind, int name_at, safe_session_binding* fresh, safe_session_binding* replaced, int session, string_builder* out, int* leading):
	char* text = safe_session_entry_text
	char* declared = 0
	if (fresh != 0): declared = fresh.name
	int named = 0
	int i = start
	int first = 1
	while (i < end):
		int c = text[i]
		if (c == '#'):
			while ((i < end) && (text[i] != 10)):
				if (out != 0): string_append_char(out, text[i])
				i = i + 1
			continue
		if ((c == '"') || (c == 39)):
			int stop = safe_session_skip_literal(text, i, end)
			while (i < stop):
				if (out != 0): string_append_char(out, text[i])
				i = i + 1
			first = 0
			continue
		if (safe_session_ident_start(c) == 0):
			int number = (c >= '0') && (c <= '9')
			if (number == 0):
				if (out != 0): string_append_char(out, c)
				i = i + 1
				if (safe_session_blank(c) == 0): first = 0
				continue
			while ((i < end) && safe_session_ident_part(text[i])):
				if (out != 0): string_append_char(out, text[i])
				i = i + 1
			first = 0
			continue
		int word_start = i
		while ((i < end) && safe_session_ident_part(text[i])): i = i + 1
		char* word = safe_session_slice(text, word_start, i)
		int is_first = first
		first = 0
		# String prefixes (c"..", f"..") and field names are not bindings.
		int previous = word_start - 1
		while ((previous >= start) && ((text[previous] == ' ') || (text[previous] == 9))): previous = previous - 1
		int field = (previous >= start) && (text[previous] == '.')
		int prefix = (i < end) && ((text[i] == '"') || (text[i] == 39))
		if (is_first && (kind == 3) && (strcmp(word, c"return") == 0)):
			if (out != 0):
				*leading = out.length + 1
				string_append(out, word)
			free(word)
			continue
		if ((strcmp(word, c"goto") == 0) || (strcmp(word, c"defer") == 0) || (strcmp(word, c"yield") == 0) || (strcmp(word, c"return") == 0)):
			named = named | 2
		safe_session_binding* target = 0
		if ((field == 0) && (prefix == 0)):
			for h in range(safe_session_hidden.length):
				if ((out == 0) && (strcmp(word, safe_session_hidden[h]) == 0)):
					safe_session_error_at(word_start, safe_session_hidden_reasons[h])
			if ((declared != 0) && (strcmp(word, declared) == 0)):
				int current = word_start >= name_at
				if (kind == 2): current = word_start == name_at
				if (current): target = fresh
				else: target = replaced
			else: target = safe_session_lookup(word)
		if ((target != 0) && target.checked):
			if ((out == 0) && target.discarded):
				safe_session_error_at(word_start, c"safe: this checked session binding was discarded after a runtime fault")
			if ((out == 0) && safe_session_nested && (target.view == 0)):
				safe_session_error_at(word_start, c"safe: checked session bindings are unavailable while another entry or a debugger stop is active")
			if ((out == 0) && target.view && safe_session_assigned(text, i, end)):
				safe_session_error_at(word_start, c"safe: checked debugger locals are read-only views at a stop; assign them in the program")
			# A frame view is a parameter of this entry's own function; it
			# never joins the replayed session.
			if (target.view == 0): named = named | 1
		if ((target != 0) && (target.checked == 0) && (target != fresh)):
			int local = session && target.in_session
			if ((local == 0) && (target.spelling == 0)): target = 0
		if (out != 0):
			if (target != 0): string_append(out, target.alias)
			else: string_append(out, word)
		free(word)
	return named


int safe_session_alias_in(char* text, int end, char* alias):
	int length = strlen(alias)
	int i = 0
	while (i + length <= end):
		int same = 1
		for k in range(length):
			if (text[i + k] != alias[k]):
				same = 0
				break
		if (same && ((i == 0) || (safe_session_ident_part(text[i - 1]) == 0)) && ((i + length == end) || (safe_session_ident_part(text[i + length]) == 0))):
			return 1
		i = i + 1
	return 0


# The parameter bindings an item's renamed text reads: frame locals and
# plain generations it does not declare itself.
void safe_session_collect_reads(safe_session_text* item):
	item.reads.clear()
	int end = strlen(item.text)
	for pass_index in range(3):
		list[safe_session_binding*] generations = safe_session_bindings
		if (pass_index == 1): generations = safe_session_new
		if (pass_index == 2): generations = safe_session_views
		for g in range(generations.length):
			safe_session_binding* b = generations[g]
			if ((b == item.declares) || (b.spelling == 0)): continue
			if ((b.checked != 0) && (b.view == 0)): continue
			if (safe_session_alias_in(item.text, end, b.alias)): item.reads.push(b)


# Record one top-level item of the pending entry after it compiled.
# kind: 1 typed persistent variable, 2 inferred persistent variable,
# 3 statement, 4 bare expression. name_at is the declared name's offset in
# the entry text and symbol the declared global (kinds 1 and 2).
void safe_session_item(int start, int end, int kind, int name_at, int symbol):
	safe_session_init()
	char* text = safe_session_entry_text
	safe_session_binding* fresh = 0
	safe_session_binding* replaced = 0
	if ((kind == 1) || (kind == 2)):
		char* declared = sym_record_name(symbol)
		if (declared == 0): error(c"safe: checked session declaration has no symbol")
		replaced = safe_session_lookup(declared)
		if ((replaced != 0) && replaced.view): replaced = 0
		if ((replaced != 0) && safe_session_listed(safe_session_new, replaced)):
			if (replaced.checked): safe_session_error_at(name_at, c"safe: a checked session binding cannot be redeclared in the entry that declared it")
			replaced = 0
		if ((replaced != 0) && replaced.checked && (safe_session_nested || safe_session_no_run)):
			safe_session_error_at(name_at, c"safe: checked session bindings cannot be replaced by a nested or unrun entry")
		fresh = safe_session_binding_new(declared, symbol, load_int(table + symbol + 6))
		if (fresh.checked && safe_session_nested):
			safe_session_binding_free(fresh)
			safe_session_error_at(name_at, c"safe: checked session bindings cannot be declared while another entry or a debugger stop is active")
		if (fresh.checked && safe_session_labeled(fresh.type, 0)):
			safe_session_binding_free(fresh)
			safe_session_error_at(name_at, c"safe: session bindings cannot have lifetime-labeled checked types (such as lock guards); keep them inside a function")
		if (fresh.checked && safe_session_no_run):
			safe_session_binding_free(fresh)
			safe_session_error_at(name_at, c"safe: an entry that is not run cannot declare checked session bindings")
		if (fresh.checked == 0):
			if (kind == 1):
				int type_end = name_at
				while ((type_end > start) && safe_session_blank(text[type_end - 1])): type_end = type_end - 1
				fresh.spelling = safe_session_slice(text, start, type_end)
			else: fresh.spelling = safe_session_spell(fresh.type)
	int leading = 0
	int named = safe_session_scan(start, end, kind, name_at, fresh, replaced, 0, 0, &leading)
	if ((fresh != 0) && fresh.checked): named = named | 1
	if ((named & 3) == 3):
		if (fresh != 0): safe_session_binding_free(fresh)
		safe_session_error_at(start, c"safe: return, goto, defer and yield are not supported in an entry item that uses checked session bindings")
	int session = named & 1
	string_builder* out = string_new()
	safe_session_scan(start, end, kind, name_at, fresh, replaced, session, out, &leading)
	char* renamed = out.data
	free(out)
	int line = 1
	for k in range(start):
		if (text[k] == 10): line = line + 1
	if (replaced != 0):
		safe_session_retired.push(replaced)
		# Replacing a held owner destroys it; a borrow of it that is used
		# later now conflicts with that destruction.
		if (replaced.owner && ((replaced.state & 7) == 2) && (replaced.discarded == 0)):
			string_builder* block = string_new()
			string_append(block, c"{\x0a\t__w_session_drop_")
			string_append_int(block, safe_session_aliases)
			string_append(block, c" := ")
			string_append(block, replaced.alias)
			string_append(block, c"\x0a}")
			safe_session_aliases = safe_session_aliases + 1
			safe_session_new_items.push(safe_session_text_new(block.data, line))
			free(block)
			safe_session_touched = 1
	safe_session_text* item = safe_session_text_new(renamed, line)
	item.declares = fresh
	# The entry's final value is checked as a plain expression read, so a
	# borrow it yields never escapes the transcript function.
	if (leading): for k in range(6): renamed[leading - 1 + k] = ' '
	if (session):
		if (fresh != 0): fresh.in_session = 1
		safe_session_new_items.push(item)
		safe_session_touched = 1
	else: safe_session_standalone.push(item)
	if (fresh != 0): safe_session_new.push(fresh)
	safe_session_collect_reads(item)


# Begin recording a new entry staged at path with the given source text.
void safe_session_begin(char* path, char* text, int no_run):
	safe_session_init()
	safe_session_no_run = no_run
	safe_session_entry_path = strclone(path)
	safe_session_entry_text = text
	safe_session_touched = 0


# Forget the pending entry (failure, :type, or a nested evaluation).
void safe_session_discard():
	if (safe_session_bindings == 0): return
	for i in range(safe_session_new.length): safe_session_binding_free(safe_session_new[i])
	safe_session_new.clear()
	safe_session_retired.clear()
	for i in range(safe_session_new_items.length): safe_session_text_free(safe_session_new_items[i])
	safe_session_new_items.clear()
	for i in range(safe_session_standalone.length): safe_session_text_free(safe_session_standalone[i])
	safe_session_standalone.clear()
	for i in range(safe_session_bindings.length): safe_session_bindings[i].captured = 0
	safe_session_touched = 0
	safe_session_seen = 0


void safe_session_note_line(char* file, int line):
	safe_session_line_files.push(file)
	safe_session_line_numbers.push(line)


# Append "(type name, ...)" for the parameters a transcript function reads.
void safe_session_parameters(string_builder* out, list[safe_session_binding*] params):
	string_append_char(out, '(')
	for i in range(params.length):
		if (i > 0): string_append(out, c", ")
		string_append(out, params[i].spelling)
		string_append_char(out, ' ')
		string_append(out, params[i].alias)
	string_append(out, c"):\x0a")


# Transcript text: the session function (when the session is touched) and
# one function per independent item. Records each generation's line.
char* safe_session_transcript():
	string_builder* out = string_new()
	safe_session_line_files.clear()
	safe_session_line_numbers.clear()
	if (safe_session_touched):
		int total = safe_session_items.length + safe_session_new_items.length
		list[safe_session_binding*] params = new list[safe_session_binding*]
		for i in range(safe_session_views.length):
			if (safe_session_views[i].checked): params.push(safe_session_views[i])
		for k in range(total):
			safe_session_text* item = 0
			if (k < safe_session_items.length): item = safe_session_items[k]
			else: item = safe_session_new_items[k - safe_session_items.length]
			for r in range(item.reads.length):
				safe_session_binding* b = item.reads[r]
				if ((b.in_session == 0) && (safe_session_listed(params, b) == 0)): params.push(b)
		string_append(out, c"void __w_repl_session")
		safe_session_parameters(out, params)
		params.free()
		safe_session_note_line(0, 0)
		int line = 2
		for k in range(total):
			safe_session_text* item = 0
			if (k < safe_session_items.length): item = safe_session_items[k]
			else: item = safe_session_new_items[k - safe_session_items.length]
			if (item.declares != 0): item.declares.line = line
			int lines = safe_session_line_count(item.text)
			for j in range(lines): safe_session_note_line(item.file, item.line + j)
			safe_session_indent(out, item.text)
			line = line + lines
		string_append(out, c"\tpass\x0a\x0a")
		safe_session_note_line(0, 0)
		safe_session_note_line(0, 0)
	for k in range(safe_session_standalone.length):
		safe_session_text* item = safe_session_standalone[k]
		string_append(out, c"int __w_repl_item_")
		string_append_int(out, k)
		safe_session_parameters(out, item.reads)
		safe_session_note_line(0, 0)
		int lines = safe_session_line_count(item.text)
		for j in range(lines): safe_session_note_line(item.file, item.line + j)
		safe_session_indent(out, item.text)
		string_append(out, c"\treturn 0\x0a\x0a")
		safe_session_note_line(0, 0)
		safe_session_note_line(0, 0)
	char* result = out.data
	free(out)
	return result


# 1 when the pending entry needs a transcript compile at all.
int safe_session_pending():
	if (safe_session_bindings == 0): return 0
	return safe_session_touched || (safe_session_standalone.length > 0)


# After a failed transcript compile or check: name the entry line behind a
# transcript line, since the transcript renames session bindings.
void safe_session_explain(char* failed_file, int failed_line):
	if ((safe_session_transcript_path == 0) || (failed_file == 0)): return
	if (strcmp(failed_file, safe_session_transcript_path) != 0): return
	if ((failed_line < 1) || (failed_line > safe_session_line_files.length)): return
	char* entry = safe_session_line_files[failed_line - 1]
	if (entry == 0): return
	print_error(str_from_cstr(c"note: checked session transcript line "))
	print_error(str_from_cstr(itoa(failed_line)))
	print_error(str_from_cstr(c" replays "))
	print_error(str_from_cstr(entry))
	print_error(str_from_cstr(c":"))
	print_error(str_from_cstr(itoa(safe_session_line_numbers[failed_line - 1])))
	print_error(str_from_cstr(c" (session bindings are renamed name__wsN)\x0a"))


# Debugger stops (debugger/eval.w): the locals of one analyzed function
# that are definitely initialized -- and, for references, still live -- at
# a source line, by name and declaration line.
int safe_session_probe_function = -1
int safe_session_probe_line
list[char*] safe_session_probe_names
list[int] safe_session_probe_lines


int safe_session_node_line(int id):
	retained_node n
	retained_node_load(id, &n)
	return n.line


# The flow states at the first statement at or after the probed line (or
# where the function's outer block ends) decide which locals are usable.
void safe_session_probe_capture(int function):
	int best = -1
	for i in range(safe_graph.length):
		safe_flow* f = safe_graph[i]
		if ((f.reached == 0) || (f.action == 3) || (f.node == function)): continue
		int line = safe_session_node_line(f.node)
		if ((line >= safe_session_probe_line) && ((best < 0) || (line < best))): best = line
	list[safe_flow*] chosen = new list[safe_flow*]
	for i in range(safe_graph.length):
		safe_flow* f = safe_graph[i]
		if ((f.reached == 0) || (f.node == function)): continue
		if (best >= 0):
			if ((f.action != 3) && (safe_session_node_line(f.node) == best)): chosen.push(f)
		else if ((f.action == 3) && (retained_record_at(f.node).parent == function)): chosen.push(f)
	for i in range(safe_real_locals):
		if (chosen.length == 0): break
		# A borrow is only known to be valid while the program still uses
		# it: past its last use its root may already be moved or dropped.
		int borrow = safe_local_kind(i) >= 2
		int alive = 1
		for k in range(chosen.length):
			if ((chosen[k].state[i] & 7) != 2): alive = 0
			if (borrow && (chosen[k].live[i] == 0)): alive = 0
		if (alive):
			retained_binding* local = retained_bindings[safe_locals[i]]
			safe_session_probe_names.push(local.name)
			safe_session_probe_lines.push(local.line)
	chosen.free()


# The retained function named name, in a source whose path matches path,
# that starts last at or before line; -1 when none was analyzed.
int safe_session_find_function(char* name, char* path, int line):
	int best = -1
	int best_line = -1
	for id in range(retained_node_count()):
		if (retained_node_table[id] & 1): continue
		retained_record* r = retained_record_at(id)
		if ((r.kind != retained_function) || (r.binding < 0)): continue
		if (strcmp(retained_bindings[r.binding].name, name) != 0): continue
		if (path != 0):
			char* source = retained_sources[r.source].path
			if ((strcmp(source, path) != 0) && (ends_with(source, path) == 0) && (ends_with(path, source) == 0)): continue
		if ((r.line <= line) && (r.line > best_line)):
			best = id
			best_line = r.line
	return best


# Analyze the program again and record which locals of function are usable
# at line. Errors unwind like any compile error of the evaluated entry.
void safe_session_probe(int function, int line):
	safe_session_init()
	if (safe_session_probe_names == 0):
		safe_session_probe_names = new list[char*]
		safe_session_probe_lines = new list[int]
	safe_session_probe_names.clear()
	safe_session_probe_lines.clear()
	if (function < 0): return
	safe_session_probe_function = function
	safe_session_probe_line = line
	safe_session_invalidate()
	safe_check_finish()
	safe_session_probe_function = -1


# 1 when the probe found local name (declared at line; any line when
# negative) usable at the stop.
int safe_session_probe_alive(char* name, int line):
	if (safe_session_probe_names == 0): return 0
	for i in range(safe_session_probe_names.length):
		if ((strcmp(safe_session_probe_names[i], name) == 0) && ((line < 0) || (safe_session_probe_lines[i] == line))): return 1
	return 0


# Present one local of the stopped frame to the evaluated entry. A checked
# local becomes a shared-reference parameter (spelling "ref T*"); a plain
# one a by-value parameter when its type can be spelled.
void safe_session_view(char* name, int type, char* spelling):
	safe_session_init()
	safe_session_binding* b = new safe_session_binding
	b.name = strclone(name)
	b.alias = strclone(name)
	b.symbol = -1
	b.type = type
	b.checked = safe_session_type_checked(type, 0)
	b.owner = 0
	b.spelling = spelling
	b.in_session = 0
	b.view = 1
	b.state = 2
	b.pending_state = 2
	b.captured = 0
	b.line = 0
	b.discarded = 0
	b.dropped = 0
	b.retired = 0
	safe_session_views.push(b)


# A checked local of the stopped frame that the entry may not name, and the
# diagnostic a reference to it reports.
void safe_session_hide(char* name, char* reason):
	safe_session_init()
	safe_session_hidden.push(strclone(name))
	safe_session_hidden_reasons.push(reason)


void safe_session_views_clear():
	if (safe_session_bindings == 0): return
	for i in range(safe_session_views.length): safe_session_binding_free(safe_session_views[i])
	safe_session_views.clear()
	for i in range(safe_session_hidden.length): free(safe_session_hidden[i])
	safe_session_hidden.clear()
	safe_session_hidden_reasons.clear()


# safe_function_end_hook: for the session function, read the state where
# its outer block ends, before its scope cleanup resets the session locals;
# for a probed debugger function, the state at the stop.
void safe_session_end_hook(int function):
	if (function == safe_session_probe_function): safe_session_probe_capture(function)
	int binding = retained_record_at(function).binding
	if (binding < 0): return
	if (strcmp(retained_bindings[binding].name, c"__w_repl_session") != 0): return
	safe_flow* cleanup = 0
	for i in range(safe_graph.length):
		safe_flow* f = safe_graph[i]
		if ((f.action == 3) && (retained_record_at(f.node).parent == function)): cleanup = f
	safe_session_seen = 1
	safe_session_reached = 0
	if (cleanup == 0): return
	safe_session_reached = cleanup.reached
	for pass_index in range(2):
		list[safe_session_binding*] generations = safe_session_bindings
		if (pass_index == 1): generations = safe_session_new
		for g in range(generations.length):
			safe_session_binding* b = generations[g]
			if (b.checked == 0): continue
			for i in range(safe_real_locals):
				retained_binding* local = retained_bindings[safe_locals[i]]
				if ((strcmp(local.name, b.alias) == 0) && (local.line == b.line)):
					b.pending_state = cleanup.state[i]
					b.captured = 1


# References to a global checked session binding in the nodes created since
# first: only the transcript may name one, through its alias.
void safe_session_capture_check(int first):
	int count = retained_node_count()
	for id in range(first, count):
		retained_node n
		retained_node_load(id, &n)
		if ((n.kind != retained_expression) || (n.op != 'v') || (n.binding < 0)): continue
		retained_binding* binding = retained_bindings[n.binding]
		if ((binding.scope == 'L') || (binding.scope == 'A')): continue
		if (safe_contains_checked(binding.type) == 0): continue
		safe_error(id, c"safe: functions, templates and nested forms cannot use a checked session binding; pass it as an argument", -1)


# A redefinition of a function whose checked contract differs would let
# late binding retarget existing callers (#114) under the wrong contract.
void safe_session_contract_check(int first):
	int count = retained_node_count()
	for id in range(first, count):
		if (retained_node_table[id] & 1): continue
		retained_record* n = retained_record_at(id)
		if ((n.kind != retained_function) || (n.binding < 0)): continue
		retained_binding* definition = retained_bindings[n.binding]
		for other in range(id):
			if (retained_node_table[other] & 1): continue
			retained_record* o = retained_record_at(other)
			if ((o.kind != retained_function) || (o.binding < 0) || (o.binding == n.binding)): continue
			retained_binding* previous = retained_bindings[o.binding]
			if (strcmp(previous.name, definition.name) != 0): continue
			int checked = safe_contains_checked(definition.return_type) || safe_contains_checked(previous.return_type)
			for p in range(definition.parameters.length):
				if (safe_contains_checked(definition.parameters[p])): checked = 1
			for p in range(previous.parameters.length):
				if (safe_contains_checked(previous.parameters[p])): checked = 1
			if (checked && (safe_contract_matches(previous, definition) == 0)):
				safe_error(id, c"safe: redefinition changes a checked function contract that existing callers rely on", other)


# Free the checker's per-type caches. They are sized by and keyed on retained
# type IDs, which grow between entries and are reused after rollback.
void safe_session_invalidate():
	if (safe_owner_masks != 0): free(cast(char*, safe_owner_masks))
	if (safe_owner_mask_state != 0): free(safe_owner_mask_state)
	safe_owner_masks = 0
	safe_owner_mask_state = 0
	if (safe_contains_seen != 0): free(cast(char*, safe_contains_seen))
	safe_contains_seen = 0
	safe_contains_generation = 0
	if (safe_contains_pending != 0): safe_contains_pending.free()
	safe_contains_pending = 0


# Rollback reuses retained source IDs: trust must not outlive its source.
void safe_session_sync_sources():
	if (safe_trusted_sources != 0):
		int count = 0
		if (retained_sources != 0): count = retained_sources.length
		while (safe_trusted_sources.length > count): safe_trusted_sources.pop()
	safe_session_invalidate()


int safe_session_live(safe_session_binding* b):
	return (b.dropped == 0) && (b.discarded == 0) && (b.retired == 0) && (safe_session_listed(safe_session_retired, b) == 0)


# Validate the analyzed pending state before anything runs.
void safe_session_validate():
	if (safe_session_touched == 0): return
	if (safe_session_seen == 0):
		safe_session_error_at(0, c"safe: checked session state was not analyzed")
	if (safe_session_reached == 0):
		safe_session_error_at(0, c"safe: this entry makes the rest of the checked session unreachable")
	for pass_index in range(2):
		list[safe_session_binding*] generations = safe_session_bindings
		if (pass_index == 1): generations = safe_session_new
		for g in range(generations.length):
			safe_session_binding* b = generations[g]
			if ((b.checked == 0) || (safe_session_live(b) == 0)): continue
			if (b.captured == 0):
				safe_session_error_at(0, c"safe: checked session state was not analyzed")
			int state = b.pending_state & 7
			if (b.owner && (state != 2) && (state != 4)):
				print_error(str_from_cstr(c"note: checked session owner '"))
				print_error(str_from_cstr(b.name))
				print_error(str_from_cstr(c"' is not held or moved on every path\x0a"))
				safe_session_error_at(0, c"safe: a checked session owner must be held or moved on every path of an entry")


# Host-side destruction of one owner value: the generated destructor's
# order (owned fields in reverse declaration order, then the allocation, or
# the audited helper of a sealed library type), run through the session's
# own compiled helpers so its allocator owns every release.
void safe_session_call(char* name, int argument):
	int symbol = sym_lookup(name)
	if ((symbol < 0) || (table[symbol + 1] != 'D')): error(c"safe: session destructor implementation is missing")
	__safe_session_drop_callback* callee = cast(__safe_session_drop_callback*, load_int(table + symbol + 2))
	callee(argument)


void safe_session_drop_value(int pointer, int type, int depth, int* remaining):
	if (pointer == 0): return
	if ((*remaining <= 0) || (depth > 32)): error(c"safe: owned aggregate destruction exceeds the session destructor bound")
	*remaining = *remaining - 1
	int element = type_lookup_previous_pointer(type)
	char* helper = safe_owner_drop_helper(element)
	if (helper != 0):
		safe_session_call(helper, pointer)
		return
	int field = type_num_args(element)
	while (field > 0):
		field = field - 1
		int field_type = type_get_field_type_at(element, field)
		if (type_safe_kind(field_type) == 1):
			int child = load_word(cast(char*, pointer + type_get_field_offset_at(element, field)))
			safe_session_drop_value(child, field_type, depth + 1, remaining)
	safe_session_call(c"free", pointer)


void safe_session_drop(safe_session_binding* b):
	if (b.dropped || b.discarded || (b.owner == 0)): return
	b.dropped = 1
	if ((b.state & 7) != 2): return
	char* slot = cast(char*, load_int(table + b.symbol + 2))
	int pointer = load_word(slot)
	save_word(slot, 0)
	int remaining = 256
	safe_session_drop_value(pointer, b.type, 0, &remaining)


# 1 when the pending entry changed checked session state, so a runtime fault
# while it ran leaves that state unknown.
int safe_session_changes():
	if ((safe_session_bindings == 0) || (safe_session_touched == 0)): return 0
	for i in range(safe_session_retired.length):
		if (safe_session_retired[i].checked): return 1
	for i in range(safe_session_bindings.length):
		safe_session_binding* b = safe_session_bindings[i]
		if (b.checked && b.captured && ((b.pending_state & 7) != (b.state & 7))): return 1
	return 0


# The pending entry ran to completion: publish it. Owners it moved are
# cleared and replaced held owners are destroyed.
void safe_session_commit():
	if (safe_session_bindings == 0): return
	# A replaced generation keeps its state from before the entry: the
	# transcript's destruction of it is what commit performs below.
	for i in range(safe_session_retired.length): safe_session_retired[i].captured = 0
	for i in range(safe_session_bindings.length):
		safe_session_binding* b = safe_session_bindings[i]
		if (b.captured): b.state = b.pending_state
		b.captured = 0
	for i in range(safe_session_new.length):
		safe_session_binding* b = safe_session_new[i]
		b.state = b.pending_state
		b.captured = 0
		safe_session_bindings.push(b)
	safe_session_new.clear()
	for i in range(safe_session_new_items.length): safe_session_items.push(safe_session_new_items[i])
	safe_session_new_items.clear()
	for i in range(safe_session_standalone.length): safe_session_text_free(safe_session_standalone[i])
	safe_session_standalone.clear()
	for i in range(safe_session_bindings.length):
		safe_session_binding* b = safe_session_bindings[i]
		if (b.owner && (b.dropped == 0) && (b.discarded == 0) && ((b.state & 7) == 4)):
			save_word(cast(char*, load_int(table + b.symbol + 2)), 0)
	list[safe_session_binding*] retired = safe_session_retired
	safe_session_retired = new list[safe_session_binding*]
	safe_session_touched = 0
	for i in range(retired.length):
		retired[i].retired = 1
		safe_session_drop(retired[i])
	retired.free()


# The pending entry faulted while running. Checked bindings it replaced or
# whose state its analysis changes are discarded: their owners are leaked
# rather than risk a second destruction or a dangling use.
void safe_session_fault():
	if (safe_session_bindings == 0): return
	if (safe_session_changes()):
		# Only bindings the entry could change: those it replaces and those
		# whose state its analysis changes on some path. The rest keep
		# their committed state, which no executed instruction touched.
		int discarded = 0
		for i in range(safe_session_bindings.length):
			safe_session_binding* b = safe_session_bindings[i]
			int changed = safe_session_listed(safe_session_retired, b)
			if (b.captured && ((b.pending_state & 7) != (b.state & 7))): changed = 1
			if (b.checked && changed && (b.dropped == 0) && (b.discarded == 0)):
				b.discarded = 1
				discarded = discarded + 1
		if (discarded > 0):
			println(c"note: checked session bindings were discarded after the fault; their owners are leaked, not dropped")
	safe_session_discard()


# End the session (normal exit, :quit, :reset): destroy every held owner in
# reverse declaration order, then forget all session state.
void safe_session_end():
	if (safe_session_bindings == 0): return
	safe_session_discard()
	int i = safe_session_bindings.length
	while (i > 0):
		i = i - 1
		safe_session_drop(safe_session_bindings[i])
	for k in range(safe_session_bindings.length): safe_session_binding_free(safe_session_bindings[k])
	safe_session_bindings.clear()
	for k in range(safe_session_items.length): safe_session_text_free(safe_session_items[k])
	safe_session_items.clear()
	safe_session_invalidate()


# A nested evaluation runs while an outer entry is still executing: set the
# outer entry's pending state aside and give it back afterwards.
struct safe_session_suspended:
	list[safe_session_binding*] fresh
	list[safe_session_binding*] retired
	list[safe_session_text*] items
	list[safe_session_text*] standalone
	list[int] states
	list[safe_session_binding*] views
	list[char*] hidden
	list[char*] hidden_reasons
	char* path
	char* text
	int touched
	int nested
	int no_run
	int seen
	int reached


char* safe_session_suspend():
	safe_session_init()
	safe_session_suspended* saved = new safe_session_suspended
	saved.fresh = safe_session_new
	saved.retired = safe_session_retired
	saved.items = safe_session_new_items
	saved.standalone = safe_session_standalone
	saved.states = new list[int]
	for i in range(safe_session_bindings.length):
		saved.states.push(safe_session_bindings[i].pending_state)
		saved.states.push(safe_session_bindings[i].captured)
	saved.views = safe_session_views
	saved.hidden = safe_session_hidden
	saved.hidden_reasons = safe_session_hidden_reasons
	safe_session_views = new list[safe_session_binding*]
	safe_session_hidden = new list[char*]
	safe_session_hidden_reasons = new list[char*]
	saved.path = safe_session_entry_path
	saved.text = safe_session_entry_text
	saved.touched = safe_session_touched
	saved.nested = safe_session_nested
	saved.no_run = safe_session_no_run
	saved.seen = safe_session_seen
	saved.reached = safe_session_reached
	safe_session_new = new list[safe_session_binding*]
	safe_session_retired = new list[safe_session_binding*]
	safe_session_new_items = new list[safe_session_text*]
	safe_session_standalone = new list[safe_session_text*]
	safe_session_touched = 0
	return cast(char*, saved)


void safe_session_resume(char* state):
	safe_session_suspended* saved = cast(safe_session_suspended*, state)
	safe_session_discard()
	safe_session_new.free()
	safe_session_retired.free()
	safe_session_new_items.free()
	safe_session_standalone.free()
	safe_session_views_clear()
	safe_session_views.free()
	safe_session_hidden.free()
	safe_session_hidden_reasons.free()
	safe_session_views = saved.views
	safe_session_hidden = saved.hidden
	safe_session_hidden_reasons = saved.hidden_reasons
	safe_session_new = saved.fresh
	safe_session_retired = saved.retired
	safe_session_new_items = saved.items
	safe_session_standalone = saved.standalone
	# Nested entries cannot make or replace checked bindings, but plain
	# generations they commit are appended after the saved ones.
	for i in range(saved.states.length / 2):
		safe_session_bindings[i].pending_state = saved.states[2 * i]
		safe_session_bindings[i].captured = saved.states[2 * i + 1]
	saved.states.free()
	safe_session_entry_path = saved.path
	safe_session_entry_text = saved.text
	safe_session_touched = saved.touched
	safe_session_nested = saved.nested
	safe_session_no_run = saved.no_run
	safe_session_seen = saved.seen
	safe_session_reached = saved.reached
	free(cast(char*, saved))
