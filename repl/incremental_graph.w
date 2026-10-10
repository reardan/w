# Independent native function reuse over the production incremental admission
# rules. An update compiles changed definitions and their transitive users in
# one transaction; unrelated definitions keep their code and addresses even
# after an insertion, deletion or an earlier edit. Code is append-only until
# clear. This is not a relocatable object cache or general module compiler.
import repl.incremental

struct incremental_graph_entry:
	char* name
	char* source
	int address

list[incremental_graph_entry*] incremental_graph_entries
# Includes deleted names: their old compiler symbols remain in the append-only
# session and may be shadowed by a later definition of the same owned name.
list[char*] incremental_graph_owned


void incremental_graph_free(list[incremental_graph_entry*] entries):
	for incremental_graph_entry* entry in entries:
		free(entry.name)
		free(entry.source)
		free(cast(char*, entry))
	entries.free()


void incremental_graph_init():
	incremental_init()
	incremental_strategy = 1
	incremental_graph_entries = new list[incremental_graph_entry*]
	incremental_graph_owned = new list[char*]


int incremental_graph_find(char* name):
	for i in range(incremental_graph_entries.length):
		if (strcmp(incremental_graph_entries[i].name, name) == 0): return i
	return -1


int incremental_graph_current():
	char* options = incremental_options_key()
	int same = strcmp(options, incremental_options) == 0
	free(options)
	if (same == 0): return 0
	if (table != incremental_table_owner): return 0
	if (type_count() != incremental_end.type_count || imported_count != incremental_end.imported_count): return 0
	if (codepos != incremental_end.codepos || table_pos != incremental_end.table_pos): return 0
	return ast_expressions_mode == incremental_ast_mode && ast_required_mode == incremental_required_mode && ast_retain_mode == incremental_retain_mode && ast_emit_retained_mode == incremental_emit_mode


incremental_result incremental_graph_update(list[char*] sources):
	incremental_result result
	result.status = 0
	result.reused = 0
	result.compiled = 0
	result.failed_index = -1
	result.message = c""
	result.tree_reused = 0
	result.tree_probed = 0
	assert1(incremental_active)
	if (incremental_strategy != 1):
		result.message = c"incremental session uses prefix checkpoints"
		return result
	if (incremental_graph_current() == 0):
		result.message = c"incremental session compiler state or options changed"
		return result
	if (sources.length > 256):
		result.message = c"incremental session supports at most 256 functions"
		return result
	list[char*] names = new list[char*]
	for i in range(sources.length):
		if (strlen(sources[i]) > 65536):
			result.message = c"incremental function exceeds 65536 source bytes"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		char* name = incremental_admit(sources[i], names)
		if (name == 0):
			result.message = c"incremental admission requires ordered scalar function definitions"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		if (incremental_contains(names, name) || (sym_probe(name) >= 0 && incremental_contains(incremental_graph_owned, name) == 0)):
			free(name)
			result.message = c"duplicate or pre-existing incremental function name"
			result.failed_index = i
			incremental_strings_free(names)
			return result
		names.push(name)
	# Historical definitions remain in the append-only symbol table. The
	# admission lexer precollects locals and cannot prove lexical scopes,
	# so even a later local declaration could otherwise admit a stale
	# function reference. Reserve deleted names until clear, including
	# local declarations with the same spelling, before any compilation.
	for i in range(sources.length):
		list[char*] tokens = incremental_tokens(sources[i])
		int stale = 0
		for char* historical in incremental_graph_owned:
			if (incremental_contains(names, historical) == 0 && incremental_contains(tokens, historical)): stale = 1
		incremental_strings_free(tokens)
		if (stale):
			result.message = c"deleted incremental function names are reserved until session clear"
			result.failed_index = i
			incremental_strings_free(names)
			return result
	# Admission requires calls to earlier definitions (or self). A forward
	# pass therefore closes the dependency graph. Count every identifier use
	# conservatively, including references shadowed by a scalar local.
	list[int] changed = new list[int]
	string_builder* batch = string_new()
	for i in range(sources.length):
		int old = incremental_graph_find(names[i])
		int dirty = old < 0
		if (old >= 0): dirty = strcmp(incremental_graph_entries[old].source, sources[i]) != 0
		if (dirty == 0):
			list[char*] tokens = incremental_tokens(sources[i])
			for j in range(i):
				if (changed[j] && incremental_contains(tokens, names[j])): dirty = 1
			incremental_strings_free(tokens)
		changed.push(dirty)
		if (dirty):
			string_append(batch, sources[i])
			string_append_char(batch, 10)
		else: result.reused = result.reused + 1
	int warnings_before = warning_count
	if (batch.length > 0):
		int old_no_run = repl_no_run
		repl_no_run = 1
		repl_result compiled = repl_eval(batch.data)
		repl_no_run = old_no_run
		if (compiled.status != 1 || (strict_mode && warning_count > warnings_before)):
			# No-run evaluation discards late-bind patches. Restore the entire
			# update before touching the old registry or any old caller bytes.
			incremental_restore(&incremental_end)
			warning_count = warnings_before
			result.message = c"incremental update failed production compilation; previous definitions retained"
			string_free(batch)
			changed.free()
			incremental_strings_free(names)
			return result
	string_free(batch)
	list[incremental_graph_entry*] next = new list[incremental_graph_entry*]
	for i in range(sources.length):
		incremental_graph_entry* entry = new incremental_graph_entry
		entry.name = strclone(names[i])
		entry.source = strclone(sources[i])
		if (changed[i]):
			int symbol = sym_probe(names[i])
			assert1(symbol >= 0 && table[symbol + 1] == 'D')
			entry.address = load_int(table + symbol + 2)
			result.compiled = result.compiled + 1
			repl_queue_late_bind(entry.name, entry.address)
		else:
			entry.address = incremental_graph_entries[incremental_graph_find(names[i])].address
		next.push(entry)
		if (incremental_contains(incremental_graph_owned, names[i]) == 0): incremental_graph_owned.push(strclone(names[i]))
	# All definitions compiled successfully. This also updates recursive and
	# cross-function address slots recorded by the normal production emitter.
	repl_apply_late_bind()
	incremental_graph_free(incremental_graph_entries)
	incremental_graph_entries = next
	changed.free()
	incremental_strings_free(names)
	repl_state_capture(&incremental_end)
	incremental_table_owner = table
	result.status = 1
	return result


int incremental_graph_address(char* name):
	if (incremental_active == 0 || incremental_strategy != 1): return 0
	int index = incremental_graph_find(name)
	if (index < 0): return 0
	return incremental_graph_entries[index].address


void incremental_graph_clear():
	if (incremental_active == 0): return
	assert1(incremental_strategy == 1)
	incremental_graph_free(incremental_graph_entries)
	incremental_graph_entries = 0
	incremental_strings_free(incremental_graph_owned)
	incremental_graph_owned = 0
	incremental_strategy = 0
	incremental_clear()
