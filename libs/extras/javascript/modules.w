# Bounded acyclic modules with named const/function exports. Syntax is extracted
# from validated parser nodes; executable statements use the runtime AST.
import libs.extras.javascript.runtime

struct js_module_source:
	char* identifier
	char* source
	int length

# Result and its strings are borrowed until the next resolver call. Return
# null on resolution failure. Canonical identifiers define module identity.
type js_module_resolver = fn(void*, char*, char*) -> js_module_source*

struct js_module_name:
	char* name
	char* local
	int request

struct js_module_request:
	char* specifier
	void* module

struct js_module:
	char* identifier
	js_node* tree
	js_value* environment
	js_value* retained
	list[js_module_request*] requests
	list[js_module_name*] imports
	list[js_module_name*] exports
	# loading=0, linked=1, evaluating=2, evaluated=3, failed=4
	int state
	int error_status
	char* error_message
	js_value* error_value

struct js_modules:
	js_runtime* runtime
	js_module_resolver* resolver
	void* context
	list[js_module*] entries
	int max_modules
	int max_depth
	int max_bytes
	int max_requests
	int bytes
	int requests

js_modules* js_modules_new(js_runtime* runtime, js_module_resolver* resolver, void* context):
	js_modules* modules = new js_modules()
	modules.runtime = runtime
	modules.resolver = resolver
	modules.context = context
	modules.entries = new list[js_module*]
	modules.max_modules = 64
	modules.max_depth = 32
	modules.max_bytes = 4194304
	modules.max_requests = 256
	return modules

void js_modules_names_free(list[js_module_name*] names):
	for i in range(names.length):
		free(names[i].name)
		free(names[i].local)
		free(names[i])
	__w_list_free(cast(__w_list*, names))

# Free before the borrowed runtime. AST ownership stays with the runtime,
# so exported closures rooted by the host remain valid after loader teardown.
void js_modules_free(js_modules* modules):
	if (modules == 0): return
	for i in range(modules.entries.length):
		js_module* entry = modules.entries[i]
		js_runtime_unroot(modules.runtime, entry.retained)
		for j in range(entry.requests.length):
			free(entry.requests[j].specifier)
			free(entry.requests[j])
		__w_list_free(cast(__w_list*, entry.requests))
		js_modules_names_free(entry.imports)
		js_modules_names_free(entry.exports)
		free(entry.identifier)
		free(entry)
	__w_list_free(cast(__w_list*, modules.entries))
	free(modules)

void js_modules_name(list[js_module_name*] names, char* name, char* local, int request):
	js_module_name* entry = new js_module_name()
	entry.name = strclone(name)
	entry.local = strclone(local)
	entry.request = request
	names.push(entry)

void js_modules_specifiers(pg_ast_node* node, list[js_module_name*] names, int request, int importing):
	char* kind = c"export_specifier"
	if (importing): kind = c"import_specifier"
	if (js_cst_is(node, kind)):
		char* first = js_identifier_decode(node.first_token.text)
		char* last = js_identifier_decode(node.last_token.text)
		if (importing): js_modules_name(names, first, last, request)
		else: js_modules_name(names, last, first, request)
		free(first)
		free(last)
		return
	for i in range(node.children.length): js_modules_specifiers(node.children[i], names, request, importing)

int js_modules_const(js_module* entry, char* name):
	for i in range(entry.imports.length):
		if (strcmp(entry.imports[i].local, name) == 0): return 1
	for i in range(entry.tree.children.length):
		js_node* node = entry.tree.children[i]
		if (js_kind(node, c"function") && strcmp(node.text, name) == 0): return 1
		if (js_kind(node, c"variable") == 0 || strcmp(node.text, c"const") != 0): continue
		for j in range(node.children.length):
			list[js_node*] names = new list[js_node*]
			js_runtime_pattern_names(node.children[j].children[0], names)
			int found = 0
			for k in range(names.length):
				if (strcmp(names[k].text, name) == 0): found = 1
			__w_list_free(cast(__w_list*, names))
			if (found): return 1
	return 0

int js_modules_parse(js_modules* modules, js_module* entry, char* source, int length):
	js_runtime* rt = modules.runtime
	pg_parse_result* parsed = js_parse_with_limits(source, length, entry.identifier, 1, rt.parse_limits)
	if (parsed.success == 0):
		if (parsed.stream.resource_failed): js_runtime_fail(rt, 5, c"module parser resource limit")
		else: js_runtime_fail(rt, 6, c"invalid module syntax")
		pg_parse_result_free(parsed)
		return 0
	js_node* tree = js_node_new(c"program", c"")
	entry.tree = tree
	# Register before any allocation/evaluation may expose a closure.
	rt.scripts.push(tree)
	for i in range(parsed.root.children.length):
		if (rt.completion.status != 0): break
		pg_ast_node* node = parsed.root.children[i]
		if (node.token != 0): continue
		if (js_cst_is(node, c"statement")): node = node.children[0]
		if (js_cst_is(node, c"import_statement")):
			pg_ast_node* clause = js_cst_child(node, c"import_clause")
			if (clause != 0 && (clause.children.length != 1 || js_cst_is(clause.children[0], c"import_named") == 0)):
				js_runtime_fail(rt, 6, c"only named and side-effect imports are supported")
				break
			if (modules.requests >= modules.max_requests):
				js_runtime_fail(rt, 5, c"module request limit")
				break
			pg_ast_node* specifier = js_cst_child(node, c"STRING")
			char* text = js_string_decode(specifier.text, parsed.diagnostics)
			if (text == 0):
				js_runtime_fail(rt, 6, c"unsupported module specifier")
				break
			js_module_request* request = new js_module_request()
			request.specifier = text
			int index = entry.requests.length
			entry.requests.push(request)
			modules.requests = modules.requests + 1
			if (clause != 0): js_modules_specifiers(clause, entry.imports, index, 1)
			continue
		int exported = js_cst_is(node, c"export_statement")
		if (exported):
			pg_ast_node* named = js_cst_child(node, c"export_named")
			if (named != 0 && js_cst_child(node, c"export_from") == 0):
				js_modules_specifiers(named, entry.exports, 0, 0)
				continue
			if (node.children.length != 2 || (js_cst_is(node.children[1], c"variable_statement") == 0 && js_cst_is(node.children[1], c"function_decl") == 0)):
				js_runtime_fail(rt, 6, c"only named const and function exports are supported")
				break
			node = node.children[1]
		js_node* lowered = js_lower_node(node, parsed.diagnostics)
		if (lowered == 0):
			js_runtime_fail(rt, 6, c"module syntax outside the AST subset")
			break
		js_node_add(tree, lowered)
		if (exported):
			if (js_kind(lowered, c"function")):
				js_modules_name(entry.exports, lowered.text, lowered.text, 0)
				continue
			if (js_kind(lowered, c"variable") == 0 || strcmp(lowered.text, c"const") != 0):
				js_runtime_fail(rt, 6, c"mutable module exports are unsupported")
				break
			for j in range(lowered.children.length):
				list[js_node*] names = new list[js_node*]
				js_runtime_pattern_names(lowered.children[j].children[0], names)
				for k in range(names.length): js_modules_name(entry.exports, names[k].text, names[k].text, 0)
				__w_list_free(cast(__w_list*, names))
	if (rt.completion.status == 0 && js_runtime_supported(tree) == 0): js_runtime_fail(rt, 6, c"module syntax outside the runtime subset")
	if (rt.completion.status == 0):
		for i in range(entry.exports.length):
			if (js_modules_const(entry, entry.exports[i].local) == 0): js_runtime_fail(rt, 6, c"mutable module exports are unsupported")
	pg_parse_result_free(parsed)
	return rt.completion.status == 0

js_module_name* js_modules_export_name(js_module* entry, char* name):
	for i in range(entry.exports.length):
		if (strcmp(entry.exports[i].name, name) == 0): return entry.exports[i]
	return 0

void js_modules_failed(js_modules* modules, js_module* entry):
	js_runtime* rt = modules.runtime
	entry.state = 4
	entry.error_status = rt.completion.status
	entry.error_message = rt.completion.message
	entry.error_value = rt.completion.value
	js_text* key = js_runtime_key(c"error")
	js_runtime_put(rt, entry.retained, key, entry.error_value)
	js_text_free(key)

js_module* js_modules_link(js_modules* modules, char* specifier, char* referrer, int depth):
	js_runtime* rt = modules.runtime
	if (depth > modules.max_depth || rt.remaining <= 0):
		js_runtime_fail(rt, 5, c"module graph depth or execution limit")
		return 0
	rt.remaining = rt.remaining - 1
	rt.completion.steps = rt.completion.steps + 1
	js_module_source* resolved = modules.resolver(modules.context, specifier, referrer)
	if (rt.completion.status != 0): return 0
	if (resolved == 0 || resolved.identifier == 0 || resolved.identifier[0] == 0):
		js_runtime_fail(rt, 2, c"module resolver failed")
		return 0
	if (strlen(resolved.identifier) > 4096):
		js_runtime_fail(rt, 5, c"module identifier limit")
		return 0
	for i in range(modules.entries.length):
		js_module* cached = modules.entries[i]
		if (strcmp(cached.identifier, resolved.identifier) != 0): continue
		if (cached.state == 0 || cached.state == 2): js_runtime_fail(rt, 6, c"cyclic modules are unsupported")
		if (cached.state == 4):
			rt.completion.status = cached.error_status
			rt.completion.message = cached.error_message
			rt.completion.value = cached.error_value
		if (rt.completion.status != 0): return 0
		return cached
	if (modules.entries.length >= modules.max_modules || rt.scripts.length >= rt.max_scripts || resolved.length < 0 || resolved.length > rt.max_source_bytes || resolved.length > modules.max_bytes - modules.bytes):
		js_runtime_fail(rt, 5, c"module count or source limit")
		return 0
	if (resolved.source == 0):
		js_runtime_fail(rt, 2, c"module resolver returned no source")
		return 0
	js_module* entry = new js_module()
	entry.identifier = strclone(resolved.identifier)
	entry.requests = new list[js_module_request*]
	entry.imports = new list[js_module_name*]
	entry.exports = new list[js_module_name*]
	entry.retained = js_runtime_alloc(rt, 5)
	js_runtime_root(rt, entry.retained)
	modules.entries.push(entry)
	modules.bytes = modules.bytes + resolved.length
	if (rt.completion.status == 0): js_modules_parse(modules, entry, resolved.source, resolved.length)
	for i in range(entry.requests.length):
		if (rt.completion.status != 0): break
		js_module_request* request = entry.requests[i]
		request.module = js_modules_link(modules, request.specifier, entry.identifier, depth + 1)
	# Check the entire graph before running any body, including missing exports.
	for i in range(entry.imports.length):
		if (rt.completion.status != 0): break
		js_module_name* name = entry.imports[i]
		js_module* dependency = cast(js_module*, entry.requests[name.request].module)
		if (js_modules_export_name(dependency, name.name) == 0): js_runtime_fail(rt, 2, c"module does not provide requested export")
	if (rt.completion.status != 0):
		js_modules_failed(modules, entry)
		return 0
	entry.state = 1
	return entry

int js_modules_execute(js_modules* modules, js_module* entry, int depth):
	js_runtime* rt = modules.runtime
	if (entry.state == 3): return 1
	if (entry.state == 4):
		rt.completion.status = entry.error_status
		rt.completion.message = entry.error_message
		rt.completion.value = entry.error_value
		return 0
	if (depth > modules.max_depth):
		js_runtime_fail(rt, 5, c"module graph depth limit")
		return 0
	entry.state = 2
	for i in range(entry.requests.length):
		if (js_modules_execute(modules, cast(js_module*, entry.requests[i].module), depth + 1) == 0):
			js_modules_failed(modules, entry)
			return 0
	entry.environment = js_runtime_environment(rt, rt.global)
	js_text* key = js_runtime_key(c"environment")
	js_runtime_put(rt, entry.retained, key, entry.environment)
	js_text_free(key)
	if (rt.completion.status == 0):
		entry.environment.strict = 1
		entry.environment.variable_scope = 1
		entry.environment.this_value = rt.undefined_value
	for i in range(entry.imports.length):
		if (rt.completion.status != 0): break
		js_module_name* name = entry.imports[i]
		js_module* dependency = cast(js_module*, entry.requests[name.request].module)
		js_module_name* exported = js_modules_export_name(dependency, name.name)
		js_value* original = js_runtime_binding(dependency.environment, exported.local)
		key = js_runtime_key(name.local)
		js_runtime_put(rt, entry.environment, key, original.value)
		js_value* binding = js_runtime_property(entry.environment, key)
		if (binding != 0):
			binding.immutable = 1
			binding.lexical_binding = 1
			binding.accessor = 2
			binding.getter = dependency.environment
			binding.host_context = original
		js_text_free(key)
	if (rt.completion.status == 0): js_runtime_var_declare(rt, entry.tree, entry.environment, 0)
	if (rt.completion.status == 0): js_runtime_declare(rt, entry.tree, entry.environment)
	if (rt.completion.status == 0): js_runtime_var_declare(rt, entry.tree, entry.environment, 1)
	for i in range(entry.tree.children.length):
		if (rt.completion.status != 0): break
		js_runtime_eval_node(rt, entry.tree.children[i], entry.environment)
	if (rt.completion.status != 0):
		js_modules_failed(modules, entry)
		return 0
	entry.state = 3
	return 1

# Returns a borrowed record on success, null on failure. Details are in the
# runtime's completion. One budget covers graph loading and all module bodies.
js_module* js_modules_evaluate(js_modules* modules, char* specifier, char* referrer, int budget):
	js_runtime* rt = modules.runtime
	if (js_runtime_begin(rt, budget) == 0): return 0
	if (modules.resolver == 0 || specifier == 0 || referrer == 0):
		js_runtime_fail(rt, 2, c"invalid module resolver request")
		return 0
	if (budget <= 0 || modules.max_depth <= 0 || modules.max_modules <= 0 || modules.max_bytes <= 0):
		js_runtime_fail(rt, 5, c"module execution limit")
		return 0
	rt.running = 1
	js_module* entry = js_modules_link(modules, specifier, referrer, 1)
	if (entry != 0 && js_modules_execute(modules, entry, 1) == 0): entry = 0
	rt.running = 0
	return entry

# Borrowed value; root it across collection or loader destruction. Missing
# names, foreign records and unevaluated modules return null.
js_value* js_modules_export(js_modules* modules, js_module* entry, char* name):
	int owned = 0
	for i in range(modules.entries.length):
		if (modules.entries[i] == entry): owned = 1
	if (owned == 0 || entry.state != 3): return 0
	js_module_name* exported = js_modules_export_name(entry, name)
	if (exported == 0): return 0
	js_value* binding = js_runtime_binding(entry.environment, exported.local)
	if (binding == 0 || binding.initialized == 0): return 0
	return js_runtime_binding_value(modules.runtime, binding)
