# Static module-graph linking for ES2020 source text module records
# (sec-parsemodule, sec-resolveexport, sec-moduledeclarationenvironmentsetup).
#
# Loads every module requested from a root, then checks each module's
# IndirectExportEntries and ImportEntries through ResolveExport, including
# `export * from` star exports, ambiguous star bindings, `export * as ns`,
# the default-is-never-star-exported rule and indirect re-export cycles.
# Failures are SyntaxErrors at the "resolution" phase, as Test262 names it.
# This is a pure static pass: it evaluates nothing and keeps no runtime state.
import lib.file
import lib.path
import libs.extras.javascript.parser


struct js_module_text:
	char* identifier
	char* source
	int length


# Returns a record borrowed until the next call, or null when the specifier
# cannot be loaded. Canonical identifiers define module identity.
type js_module_loader = fn(void*, char*, char*) -> js_module_text*


struct js_module_entry:
	char* export_name
	char* import_name
	char* local_name
	int request


struct js_module_record:
	char* identifier
	pg_parse_result* parsed
	list[char*] specifiers
	list[js_module_record*] requested
	list[js_module_entry*] imports
	list[js_module_entry*] local_exports
	list[js_module_entry*] indirect_exports
	list[js_module_entry*] star_exports


struct js_module_graph:
	js_module_loader* loader
	void* context
	list[js_module_record*] records
	int max_modules
	int max_depth
	int max_resolve
	# Set on failure: "SyntaxError" (bad source or link) or "ReferenceError"
	# (a specifier the loader cannot load). Borrowed static strings.
	char* error_type
	char* error_message
	char* error_module


js_module_graph* js_module_graph_new(js_module_loader* loader, void* context):
	js_module_graph* graph = new js_module_graph()
	graph.loader = loader
	graph.context = context
	graph.records = new list[js_module_record*]
	graph.max_modules = 256
	graph.max_depth = 64
	graph.max_resolve = 4096
	graph.error_type = 0
	graph.error_message = 0
	graph.error_module = 0
	return graph


void js_module_entries_free(list[js_module_entry*] entries):
	for js_module_entry* entry in entries:
		free(entry.export_name)
		free(entry.import_name)
		free(entry.local_name)
		free(entry)
	__w_list_free(cast(__w_list*, entries))


void js_module_graph_free(js_module_graph* graph):
	if (graph == 0): return
	for js_module_record* record in graph.records:
		if (record.parsed != 0): pg_parse_result_free(record.parsed)
		for char* specifier in record.specifiers: free(specifier)
		__w_list_free(cast(__w_list*, record.specifiers))
		__w_list_free(cast(__w_list*, record.requested))
		js_module_entries_free(record.imports)
		js_module_entries_free(record.local_exports)
		js_module_entries_free(record.indirect_exports)
		js_module_entries_free(record.star_exports)
		free(record.identifier)
		free(record)
	__w_list_free(cast(__w_list*, graph.records))
	free(graph)


int js_module_graph_fail(js_module_graph* graph, js_module_record* record, char* type, char* message):
	if (graph.error_type == 0):
		graph.error_type = type
		graph.error_message = message
		if (record != 0): graph.error_module = record.identifier
	return 0


char* js_module_name_clone(char* name):
	if (name == 0): return 0
	return strclone(name)


void js_module_entry_add(list[js_module_entry*] entries, char* export_name, char* import_name, char* local_name, int request):
	js_module_entry* entry = new js_module_entry()
	entry.export_name = js_module_name_clone(export_name)
	entry.import_name = js_module_name_clone(import_name)
	entry.local_name = js_module_name_clone(local_name)
	entry.request = request
	entries.push(entry)


int js_module_request_index(js_module_record* record, pg_ast_node* statement):
	pg_ast_node* source = js_cst_child(statement, c"STRING")
	if (source == 0):
		pg_ast_node* from = js_cst_child(statement, c"export_from")
		if (from == 0): from = js_cst_child(statement, c"export_all")
		if (from != 0): source = js_cst_child(from, c"STRING")
	if (source == 0): return -1
	char* specifier = js_string_decode(source.text, record.parsed.diagnostics)
	if (specifier == 0): return -1
	for i in range(record.specifiers.length):
		if (strcmp(record.specifiers[i], specifier) == 0):
			free(specifier)
			return i
	record.specifiers.push(specifier)
	return record.specifiers.length - 1


js_module_entry* js_module_import_entry(js_module_record* record, char* local):
	for js_module_entry* entry in record.imports:
		if (strcmp(entry.local_name, local) == 0): return entry
	return 0


void js_module_import_specifiers(js_module_record* record, pg_ast_node* node, int request):
	if (js_cst_is(node, c"import_specifier")):
		char* imported = js_identifier_decode(node.first_token.text)
		char* local = js_identifier_decode(node.last_token.text)
		js_module_entry_add(record.imports, 0, imported, local, request)
		free(imported)
		free(local)
		return
	if (js_cst_is(node, c"import_namespace")):
		char* local = js_identifier_decode(node.last_token.text)
		js_module_entry_add(record.imports, 0, c"*", local, request)
		free(local)
		return
	if (js_cst_is(node, c"binding_identifier") && js_cst_is(node.parent, c"import_clause")):
		char* local = js_identifier_decode(node.first_token.text)
		js_module_entry_add(record.imports, 0, c"default", local, request)
		free(local)
		return
	for pg_ast_node* child in node.children: js_module_import_specifiers(record, child, request)


void js_module_export_names(list[char*] names, pg_ast_node* node):
	if (node == 0 || js_cst_is(node, c"initializer") || js_cst_is(node, c"property_name")): return
	if (js_cst_is(node, c"binding_identifier")):
		names.push(js_identifier_decode(node.first_token.text))
		return
	for pg_ast_node* child in node.children: js_module_export_names(names, child)


# ParseModule's ExportEntries split, done after the import entries are known.
void js_module_export_entries(js_module_record* record, pg_ast_node* node):
	if (js_cst_child(node, c"KW_DEFAULT") != 0):
		js_module_entry_add(record.local_exports, c"default", 0, c"*default*", -1)
		return
	pg_ast_node* all = js_cst_child(node, c"export_all")
	if (all != 0):
		int request = js_module_request_index(record, node)
		pg_ast_node* alias = js_cst_child(all, c"export_alias")
		if (alias == 0): js_module_entry_add(record.star_exports, 0, c"*", 0, request)
		else:
			char* name = js_identifier_decode(alias.last_token.text)
			js_module_entry_add(record.indirect_exports, name, c"*", 0, request)
			free(name)
		return
	pg_ast_node* named = js_cst_child(node, c"export_named")
	if (named != 0):
		int request = -1
		if (js_cst_child(node, c"export_from") != 0): request = js_module_request_index(record, node)
		list[pg_ast_node*] specifiers = new list[pg_ast_node*]
		pg_ast_node* list_node = js_cst_child(named, c"export_specifiers")
		if (list_node != 0):
			for pg_ast_node* child in list_node.children:
				if (js_cst_is(child, c"export_specifier")): specifiers.push(child)
				else if (js_cst_is(child, c"export_specifier_tail")): specifiers.push(js_cst_child(child, c"export_specifier"))
		for pg_ast_node* specifier in specifiers:
			char* local = js_identifier_decode(specifier.first_token.text)
			char* exported = js_identifier_decode(specifier.last_token.text)
			if (request >= 0): js_module_entry_add(record.indirect_exports, exported, local, 0, request)
			else:
				js_module_entry* imported = js_module_import_entry(record, local)
				if (imported == 0 || strcmp(imported.import_name, c"*") == 0): js_module_entry_add(record.local_exports, exported, 0, local, -1)
				else: js_module_entry_add(record.indirect_exports, exported, imported.import_name, 0, imported.request)
			free(local)
			free(exported)
		__w_list_free(cast(__w_list*, specifiers))
		return
	list[char*] names = new list[char*]
	for pg_ast_node* child in node.children:
		if (js_cst_is(child, c"function_decl") || js_cst_is(child, c"class_decl")): js_module_export_names(names, js_cst_child(child, c"binding_identifier"))
		if (js_cst_is(child, c"variable_statement")): js_module_export_names(names, child)
	for char* name in names:
		js_module_entry_add(record.local_exports, name, 0, name, -1)
		free(name)
	__w_list_free(cast(__w_list*, names))


void js_module_record_entries(js_module_record* record):
	list[pg_ast_node*] statements = new list[pg_ast_node*]
	for pg_ast_node* child in record.parsed.root.children:
		pg_ast_node* statement = child
		if (js_cst_is(statement, c"statement")): statement = statement.children[0]
		if (js_cst_is(statement, c"import_statement") || js_cst_is(statement, c"export_statement")): statements.push(statement)
	# Requests keep source order across imports and re-exports.
	for pg_ast_node* statement in statements:
		if (js_cst_is(statement, c"import_statement")):
			int request = js_module_request_index(record, statement)
			pg_ast_node* clause = js_cst_child(statement, c"import_clause")
			if (clause != 0 && request >= 0): js_module_import_specifiers(record, clause, request)
		else: js_module_export_entries(record, statement)
	__w_list_free(cast(__w_list*, statements))


js_module_record* js_module_graph_find(js_module_graph* graph, char* identifier):
	for js_module_record* record in graph.records:
		if (strcmp(record.identifier, identifier) == 0): return record
	return 0


js_module_record* js_module_graph_add(js_module_graph* graph, char* identifier, char* source, int length, int depth):
	if (graph.records.length >= graph.max_modules || depth > graph.max_depth):
		js_module_graph_fail(graph, 0, c"SyntaxError", c"module graph limit")
		return 0
	js_module_record* record = new js_module_record()
	record.identifier = strclone(identifier)
	record.specifiers = new list[char*]
	record.requested = new list[js_module_record*]
	record.imports = new list[js_module_entry*]
	record.local_exports = new list[js_module_entry*]
	record.indirect_exports = new list[js_module_entry*]
	record.star_exports = new list[js_module_entry*]
	graph.records.push(record)
	record.parsed = js_parse(source, length, record.identifier, 1)
	if (record.parsed.success == 0):
		js_module_graph_fail(graph, record, c"SyntaxError", c"invalid module source text")
		return 0
	js_module_record_entries(record)
	for i in range(record.specifiers.length):
		char* specifier = record.specifiers[i]
		js_module_text* loaded = graph.loader(graph.context, specifier, record.identifier)
		if (loaded == 0 || loaded.identifier == 0 || loaded.source == 0):
			js_module_graph_fail(graph, record, c"ReferenceError", c"module specifier cannot be loaded")
			return 0
		js_module_record* child = js_module_graph_find(graph, loaded.identifier)
		if (child == 0): child = js_module_graph_add(graph, loaded.identifier, loaded.source, loaded.length, depth + 1)
		if (child == 0): return 0
		record.requested.push(child)
	return record


struct js_module_resolution:
	js_module_record* module
	char* binding
	int ambiguous
	list[js_module_record*] seen_modules
	list[char*] seen_names
	int overflow


# ResolveExport(exportName, resolveSet). Returns 1 with module/binding set,
# 0 for null (not found or circular) and 2 for "ambiguous".
int js_module_resolve_export(js_module_record* record, char* name, js_module_resolution* state, int limit):
	for i in range(state.seen_modules.length):
		if (state.seen_modules[i] == record && strcmp(state.seen_names[i], name) == 0): return 0
	if (state.seen_modules.length >= limit):
		state.overflow = 1
		return 0
	state.seen_modules.push(record)
	state.seen_names.push(name)
	for js_module_entry* entry in record.local_exports:
		if (strcmp(entry.export_name, name) == 0):
			state.module = record
			state.binding = entry.local_name
			return 1
	for js_module_entry* entry in record.indirect_exports:
		if (strcmp(entry.export_name, name) != 0): continue
		js_module_record* imported = record.requested[entry.request]
		if (strcmp(entry.import_name, c"*") == 0):
			state.module = imported
			state.binding = c"*namespace*"
			return 1
		return js_module_resolve_export(imported, entry.import_name, state, limit)
	# A default export cannot be provided by an export *.
	if (strcmp(name, c"default") == 0): return 0
	js_module_record* star_module = 0
	char* star_binding = 0
	for js_module_entry* entry in record.star_exports:
		int status = js_module_resolve_export(record.requested[entry.request], name, state, limit)
		if (status == 2): return 2
		if (status == 1):
			if (star_module == 0):
				star_module = state.module
				star_binding = state.binding
			else if (star_module != state.module || strcmp(star_binding, state.binding) != 0): return 2
	if (star_module == 0): return 0
	state.module = star_module
	state.binding = star_binding
	return 1


int js_module_graph_resolve(js_module_graph* graph, js_module_record* record, char* name):
	js_module_resolution state
	state.module = 0
	state.binding = 0
	state.ambiguous = 0
	state.overflow = 0
	state.seen_modules = new list[js_module_record*]
	state.seen_names = new list[char*]
	int status = js_module_resolve_export(record, name, &state, graph.max_resolve)
	if (state.overflow): status = 3
	__w_list_free(cast(__w_list*, state.seen_modules))
	__w_list_free(cast(__w_list*, state.seen_names))
	return status


int js_module_graph_check(js_module_graph* graph, js_module_record* record, char* name, js_module_record* owner):
	int status = js_module_graph_resolve(graph, record, name)
	if (status == 1): return 1
	if (status == 2): return js_module_graph_fail(graph, owner, c"SyntaxError", c"ambiguous star export binding")
	if (status == 3): return js_module_graph_fail(graph, owner, c"SyntaxError", c"module export resolution limit")
	return js_module_graph_fail(graph, owner, c"SyntaxError", c"module export cannot be resolved")


# ModuleDeclarationEnvironmentSetup's static checks for every loaded module.
int js_module_graph_validate(js_module_graph* graph):
	for js_module_record* record in graph.records:
		for js_module_entry* entry in record.indirect_exports:
			if (js_module_graph_check(graph, record, entry.export_name, record) == 0): return 0
		for js_module_entry* entry in record.imports:
			if (strcmp(entry.import_name, c"*") == 0): continue
			if (js_module_graph_check(graph, record.requested[entry.request], entry.import_name, record) == 0): return 0
	return 1


# Loads and links the graph rooted at source. Returns 1 when every module
# parses and every import and indirect export resolves to one binding.
int js_module_graph_link(js_module_graph* graph, char* identifier, char* source, int length):
	if (graph.loader == 0 || identifier == 0 || source == 0 || length < 0): return js_module_graph_fail(graph, 0, c"SyntaxError", c"invalid module graph request")
	if (js_module_graph_add(graph, identifier, source, length, 0) == 0): return 0
	return js_module_graph_validate(graph)


# ExportedNames of a linked record without ambiguous star names (the keys of
# its module namespace object, sec-getmodulenamespace). Caller frees the list.
void js_module_exported_names(js_module_record* record, list[js_module_record*] visited, list[char*] names):
	for js_module_record* seen in visited:
		if (seen == record): return
	visited.push(record)
	for js_module_entry* entry in record.local_exports: names.push(entry.export_name)
	for js_module_entry* entry in record.indirect_exports: names.push(entry.export_name)
	for js_module_entry* entry in record.star_exports:
		list[char*] star = new list[char*]
		js_module_exported_names(record.requested[entry.request], visited, star)
		for char* name in star:
			int duplicate = strcmp(name, c"default") == 0
			for char* existing in names:
				if (strcmp(existing, name) == 0): duplicate = 1
			if (duplicate == 0): names.push(name)
		__w_list_free(cast(__w_list*, star))


list[char*] js_module_namespace_names(js_module_graph* graph, js_module_record* record):
	list[char*] exported = new list[char*]
	list[js_module_record*] visited = new list[js_module_record*]
	js_module_exported_names(record, visited, exported)
	__w_list_free(cast(__w_list*, visited))
	list[char*] names = new list[char*]
	for char* name in exported:
		if (js_module_graph_resolve(graph, record, name) == 1): names.push(name)
	__w_list_free(cast(__w_list*, exported))
	return names


# File-system loader: "./" and "../" specifiers resolve against the
# referrer's directory and must stay inside the loader's root directory.
struct js_module_file_loader:
	char* root
	js_module_text* text


js_module_text* js_module_file_load(void* context, char* specifier, char* referrer):
	js_module_file_loader* loader = cast(js_module_file_loader*, context)
	free(loader.text.identifier)
	free(loader.text.source)
	loader.text.identifier = 0
	loader.text.source = 0
	if (starts_with(specifier, c"./") == 0 && starts_with(specifier, c"../") == 0): return 0
	char* directory = path_dirname(referrer)
	char* path = path_join(directory, specifier)
	free(directory)
	if (path_is_within(loader.root, path) == 0):
		free(path)
		return 0
	char* source = file_read_text(path)
	if (source == 0):
		free(path)
		return 0
	loader.text.identifier = path
	loader.text.source = source
	loader.text.length = strlen(source)
	return loader.text


js_module_file_loader* js_module_file_loader_new(char* root):
	js_module_file_loader* loader = new js_module_file_loader()
	loader.root = strclone(root)
	loader.text = new js_module_text()
	loader.text.identifier = 0
	loader.text.source = 0
	loader.text.length = 0
	return loader


void js_module_file_loader_free(js_module_file_loader* loader):
	if (loader == 0): return
	free(loader.text.identifier)
	free(loader.text.source)
	free(loader.text)
	free(loader.root)
	free(loader)
