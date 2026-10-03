# Resident leaf compiler state. Content is read on every request; unchanged
# bytes reuse the owned PG tree and AST. Linking/analysis/emission snapshots
# are keyed by the complete reachable graph, including import resolution.
import tools.wc2.snapshot
import tools.wc2.emit
import structures.json


struct wc2_cached_file:
	char* path
	string_builder* content
	int readable
	int revision
	wc2_module* parsed


struct wc2_cached_program:
	char* path
	char* key
	int revision
	wc2_module* linked
	wc2_semantics* semantic
	asm_buffer* image
	json_value* diagnostics
	json_value* symbols
	json_value* deps
	json_value* edges


struct wc2_resident:
	list[wc2_cached_file*] files
	list[wc2_cached_program*] programs
	int reads
	int parses
	int parse_hits
	int analyses
	int emissions
	int program_hits
	int serial


struct wc2_graph:
	wc2_resident* resident
	list[int] files
	list[int] active
	list[int] declaration_files
	list[int] declaration_nodes
	string_builder* key
	json_value* diagnostics
	json_value* edges


json_value* wc2_diagnostic_json(char* file, int line, int column, char* message):
	json_value* result = json_object()
	json_object_set(result, c"file", json_string(file))
	json_object_set(result, c"line", json_int(line))
	json_object_set(result, c"column", json_int(column))
	json_object_set(result, c"severity", json_string(c"error"))
	json_object_set(result, c"message", json_string(message))
	return result


void wc2_collect_diagnostics(json_value* out, wc2_module* m):
	for pg_diagnostic* diagnostic in m.diagnostics.items:
		json_value* item = wc2_diagnostic_json(diagnostic.filename, diagnostic.line, diagnostic.column, diagnostic.message)
		json_object_set(item, c"expected", json_string(diagnostic.expected))
		json_object_set(item, c"found", json_string(diagnostic.found))
		json_array_push(out, item)


wc2_resident* wc2_resident_new():
	wc2_resident* r = new wc2_resident()
	r.files = new list[wc2_cached_file*]
	r.programs = new list[wc2_cached_program*]
	r.reads = 0
	r.parses = 0
	r.parse_hits = 0
	r.analyses = 0
	r.emissions = 0
	r.program_hits = 0
	r.serial = 0
	return r


void wc2_program_free(wc2_cached_program* program):
	if (program.image != 0): asm_buffer_free(program.image)
	if (program.semantic != 0): wc2_semantics_free(program.semantic)
	wc2_module_free(program.linked)
	free(program.path)
	free(program.key)
	json_free(program.diagnostics)
	json_free(program.symbols)
	json_free(program.deps)
	json_free(program.edges)
	free(program)


void wc2_resident_clear(wc2_resident* r):
	while (r.programs.length): wc2_program_free(r.programs.pop())
	while (r.files.length):
		wc2_cached_file* entry = r.files.pop()
		wc2_module_free(entry.parsed)
		string_free(entry.content)
		free(entry.path)
		free(entry)
	# Counters are lifetime totals, so a clear is visible in subsequent work.


void wc2_resident_free(wc2_resident* r):
	wc2_resident_clear(r)
	__w_list_free(cast(__w_list*, r.files))
	__w_list_free(cast(__w_list*, r.programs))
	free(r)


# Absolute paths coalesce './' spellings. Preserve '..': collapsing it across
# a symlink changes filesystem semantics. Alias spellings may occupy separate
# entries, but content/import checks still prevent stale hits.
char* wc2_absolute_path(char* path):
	char* cwd = malloc(4096)
	if (getcwd(cwd, 4096) < 0):
		free(cwd)
		return 0
	char* joined = path_join(cwd, path)
	free(cwd)
	list[char*] parts = new list[char*]
	int start = 0
	int length = strlen(joined)
	for i in range(length + 1):
		if ((joined[i] != '/') && (joined[i] != 0)): continue
		char* part = path_clone_range(joined + start, i - start)
		start = i + 1
		if ((part[0] == 0) || (strcmp(part, c".") == 0)): free(part)
		else: parts.push(part)
	string_builder* out = string_new()
	for char* part in parts:
		string_append_char(out, '/')
		string_append(out, part)
		free(part)
	if (out.length == 0): string_append_char(out, '/')
	__w_list_free(cast(__w_list*, parts))
	free(joined)
	char* result = strclone(out.data)
	string_free(out)
	return result


# Compare full bytes, not mtimes or NUL-terminated prefixes. Read errors
# never create a successful empty source; embedded NULs are diagnosed below.
string_builder* wc2_read_source(char* path, int* readable):
	string_builder* source = string_new()
	*readable = 0
	int fd = open(path, 0, 0)
	if (fd < 0): return source
	char[4096] chunk
	while (1):
		int count = read(fd, chunk, 4096)
		if (count <= 0):
			*readable = count == 0
			break
		string_append_bytes(source, chunk, count)
	close(fd)
	return source


int wc2_resident_file(wc2_resident* r, char* path):
	int index = -1
	for i in range(r.files.length):
		if (strcmp(r.files[i].path, path) == 0): index = i
	if ((index < 0) && (r.files.length >= 256)): return -1
	int readable = 0
	string_builder* content = wc2_read_source(path, &readable)
	r.reads = r.reads + 1
	if (index >= 0):
		wc2_cached_file* old = r.files[index]
		if ((old.readable == readable) && (old.content.length == content.length) && mem_eq(old.content.data, content.data, content.length)):
			string_free(content)
			r.parse_hits = r.parse_hits + 1
			return index
		wc2_module_free(old.parsed)
		string_free(old.content)
	else:
		wc2_cached_file* entry = new wc2_cached_file()
		entry.path = strclone(path)
		index = r.files.length
		r.files.push(entry)
	wc2_cached_file* entry = r.files[index]
	entry.content = content
	entry.readable = readable
	r.serial = r.serial + 1
	entry.revision = r.serial
	if (readable && (strlen(content.data) == content.length)):
		entry.parsed = wc2_parse(content.data, path)
		r.parses = r.parses + 1
	else:
		entry.parsed = wc2_module_new(c"", path)
		char* message = c"wc2: cannot read source file"
		if (readable): message = c"wc2: source contains an embedded NUL"
		pg_diagnostics_add(entry.parsed.diagnostics, entry.parsed.filename, 1, 1, message, c"", c"")
	return index


int wc2_contains_id(list[int] ids, int wanted):
	for int id in ids:
		if (id == wanted): return 1
	return 0


void wc2_graph_problem(wc2_graph* g, wc2_node* node, char* message):
	json_array_push(g.diagnostics, wc2_diagnostic_json(node.filename, node.line, node.column, message))


void wc2_graph_visit(wc2_graph* g, int id, int depth):
	if (wc2_contains_id(g.files, id)): return
	g.files.push(id)
	g.active.push(id)
	wc2_cached_file* entry = g.resident.files[id]
	string_append_int(g.key, id)
	string_append_char(g.key, ':')
	string_append_int(g.key, entry.revision)
	string_append_char(g.key, ';')
	wc2_module* m = entry.parsed
	wc2_collect_diagnostics(g.diagnostics, m)
	if (wc2_module_ok(m)):
		for int node_id in m.nodes[m.root].children:
			wc2_node* node = m.nodes[node_id]
			if (node.kind != wc2_import_kind):
				g.declaration_files.push(id)
				g.declaration_nodes.push(node_id)
				continue
			char* path = wc2_find_import(node.text)
			json_value* edge = json_object()
			json_object_set(edge, c"file", json_string(entry.path))
			json_object_set(edge, c"import", json_string(node.text))
			json_object_set(edge, c"line", json_int(node.line))
			json_array_push(g.edges, edge)
			if (path == 0):
				json_object_set(edge, c"resolved", json_null())
				string_append(g.key, c"missing;")
				wc2_graph_problem(g, node, c"wc2: cannot locate imported module")
				continue
			json_object_set(edge, c"resolved", json_string(path))
			# Repeated edges use the same bytes already read in this request.
			int target = -1
			for int visited in g.files:
				if (strcmp(g.resident.files[visited].path, path) == 0): target = visited
			if (target < 0): target = wc2_resident_file(g.resident, path)
			free(path)
			string_append(g.key, c"edge:")
			string_append_int(g.key, target)
			string_append_char(g.key, ';')
			if (target < 0): wc2_graph_problem(g, node, c"wc2: resident module limit exceeded (256)")
			elif (wc2_contains_id(g.active, target)): wc2_graph_problem(g, node, c"wc2: cyclic import is not supported")
			elif (depth >= 64): wc2_graph_problem(g, node, c"wc2: import nesting limit exceeded")
			else: wc2_graph_visit(g, target, depth + 1)
	g.active.pop()


wc2_graph* wc2_graph_new(wc2_resident* r, int root):
	wc2_graph* g = new wc2_graph()
	g.resident = r
	g.files = new list[int]
	g.active = new list[int]
	g.declaration_files = new list[int]
	g.declaration_nodes = new list[int]
	g.key = string_new()
	g.diagnostics = json_array()
	g.edges = json_array()
	wc2_graph_visit(g, root, 0)
	return g


void wc2_graph_free(wc2_graph* g):
	wc2_free_ints(g.files)
	wc2_free_ints(g.active)
	wc2_free_ints(g.declaration_files)
	wc2_free_ints(g.declaration_nodes)
	string_free(g.key)
	json_free(g.diagnostics)
	json_free(g.edges)
	free(g)


wc2_module* wc2_graph_link(wc2_graph* g):
	int root = g.files[0]
	wc2_module* m = wc2_snapshot(g.resident.files[root].parsed)
	list[int] bases = new list[int]
	for i in range(g.resident.files.length): bases.push(-1)
	bases[root] = 0
	for i in range(1, g.files.length):
		int id = g.files[i]
		bases[id] = m.nodes.length
		wc2_merge_module(m, wc2_snapshot(g.resident.files[id].parsed))
	wc2_node* root_node = m.nodes[m.root]
	wc2_free_ints(root_node.children)
	root_node.children = new list[int]
	for i in range(g.declaration_nodes.length): root_node.children.push(bases[g.declaration_files[i]] + g.declaration_nodes[i])
	wc2_free_ints(bases)
	return m


json_value* wc2_graph_symbols(wc2_graph* g):
	json_value* result = json_array()
	for int id in g.files:
		wc2_module* m = g.resident.files[id].parsed
		for wc2_node* node in m.nodes:
			if ((node.kind != wc2_function_kind) && (node.kind != wc2_struct_kind) && (node.kind != wc2_parameter_kind) && (node.kind != wc2_declaration_kind)): continue
			json_value* symbol = json_object()
			json_object_set(symbol, c"name", json_string(node.text))
			json_object_set(symbol, c"kind", json_string(wc2_kind_name(node.kind)))
			json_object_set(symbol, c"file", json_string(node.filename))
			json_object_set(symbol, c"line", json_int(node.line))
			json_object_set(symbol, c"column", json_int(node.column))
			json_object_set(symbol, c"start", json_int(node.start))
			json_object_set(symbol, c"end", json_int(node.end))
			json_object_set(symbol, c"scope", json_int(node.scope))
			json_object_set(symbol, c"type", json_int(node.type_id))
			json_object_set(symbol, c"type_name", json_string(node.type_name))
			json_array_push(result, symbol)
	return result


# Borrowed until this root is refreshed, evicted, cleared or freed. Older
# snapshots own all their strings/tables, independently of refreshed files.
wc2_cached_program* wc2_resident_program(wc2_resident* r, char* path):
	if (r.files.length >= 256): wc2_resident_clear(r)
	int root = wc2_resident_file(r, path)
	wc2_graph* g = wc2_graph_new(r, root)
	int existing = -1
	for i in range(r.programs.length):
		if (strcmp(r.programs[i].path, path) == 0): existing = i
	if (existing >= 0):
		wc2_cached_program* old = r.programs[existing]
		if (strcmp(old.key, g.key.data) == 0):
			r.program_hits = r.program_hits + 1
			wc2_graph_free(g)
			return old
		wc2_program_free(old)
	wc2_cached_program* program = new wc2_cached_program()
	program.path = strclone(path)
	program.key = strclone(g.key.data)
	r.serial = r.serial + 1
	program.revision = r.serial
	program.linked = 0
	program.semantic = 0
	program.image = 0
	program.diagnostics = json_clone(g.diagnostics)
	program.symbols = wc2_graph_symbols(g)
	program.deps = json_array()
	for int id in g.files: json_array_push(program.deps, json_string(r.files[id].path))
	program.edges = json_clone(g.edges)
	if (json_array_length(g.diagnostics) == 0): program.linked = wc2_graph_link(g)
	if (existing >= 0): r.programs[existing] = program
	else:
		# Bound linked snapshots independently of the parsed-file cache.
		if (r.programs.length == 16):
			wc2_program_free(r.programs[0])
			for i in range(1, r.programs.length): r.programs[i - 1] = r.programs[i]
			r.programs.pop()
		r.programs.push(program)
	wc2_graph_free(g)
	return program


void wc2_resident_check(wc2_resident* r, wc2_cached_program* program):
	if ((program.linked == 0) || (program.semantic != 0)): return
	program.semantic = wc2_analyze(program.linked)
	r.analyses = r.analyses + 1


json_value* wc2_resident_stats(wc2_resident* r):
	json_value* result = json_object()
	json_object_set(result, c"files", json_int(r.files.length))
	json_object_set(result, c"programs", json_int(r.programs.length))
	json_object_set(result, c"reads", json_int(r.reads))
	json_object_set(result, c"parses", json_int(r.parses))
	json_object_set(result, c"parse_hits", json_int(r.parse_hits))
	json_object_set(result, c"analyses", json_int(r.analyses))
	json_object_set(result, c"emissions", json_int(r.emissions))
	json_object_set(result, c"program_hits", json_int(r.program_hits))
	int source_bytes = 0
	int nodes = 0
	for wc2_cached_file* entry in r.files:
		source_bytes = source_bytes + entry.content.length
		nodes = nodes + entry.parsed.nodes.length
	json_object_set(result, c"source_bytes", json_int(source_bytes))
	json_object_set(result, c"ast_nodes", json_int(nodes))
	return result
