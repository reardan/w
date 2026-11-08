# ES2020 source text modules for the runtime AST interpreter. module_graph.w
# parses each module into a js_module_record (ParseModule's import, local,
# indirect and star export entries; ResolveExport); this loader adds the
# runtime half on those records: module environments with live import
# bindings, module namespace objects, and the spec's DFS link and evaluation
# order (sec-moduledeclarationlinking, sec-moduleevaluation), including
# cycles, with TDZ for bindings that are not initialized yet. Executable
# statements use the runtime AST.
import libs.extras.javascript.runtime
import libs.extras.javascript.module_graph

# The host resolver is module_graph.w's loader: the result and its strings
# are borrowed until the next call, null on resolution failure. Canonical
# identifiers define module identity.
type js_module_source = js_module_text
type js_module_resolver = js_module_loader

struct js_module:
	char* identifier
	# Null until the source parses; the graph owns it.
	js_module_record* record
	js_node* tree
	js_value* environment
	js_value* namespace
	js_value* retained
	# Parallel to record.requested.
	list[js_module*] requested
	# unlinked=0, linked=1, evaluating=2, evaluated=3, failed=4
	int state
	int dfs_index
	int dfs_ancestor
	# An anonymous `export default function` declared as *default*.
	int default_function
	int error_status
	char* error_message
	js_value* error_value

struct js_modules:
	js_runtime* runtime
	js_module_resolver* resolver
	void* context
	js_module_graph* graph
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
	modules.graph = js_module_graph_new(resolver, context)
	modules.entries = new list[js_module*]
	modules.max_modules = 64
	modules.max_depth = 32
	modules.max_bytes = 4194304
	modules.max_requests = 256
	return modules

# Free before the borrowed runtime. AST ownership stays with the runtime,
# so exported closures rooted by the host remain valid after loader teardown.
void js_modules_free(js_modules* modules):
	if (modules == 0): return
	for i in range(modules.entries.length):
		js_module* entry = modules.entries[i]
		js_runtime_unroot(modules.runtime, entry.retained)
		__w_list_free(cast(__w_list*, entry.requested))
		free(entry.identifier)
		free(entry)
	__w_list_free(cast(__w_list*, modules.entries))
	js_module_graph_free(modules.graph)
	free(modules)

void js_modules_retain(js_runtime* rt, js_module* entry, char* name, js_value* value):
	js_text* key = js_runtime_key(name)
	js_runtime_put(rt, entry.retained, key, value)
	js_text_free(key)

# Returns 0 for an import or re-export whose specifier is not a string
# without embedded NUL or lone surrogates; the record drops such requests.
int js_modules_specifier_ok(pg_ast_node* node, pg_diagnostics* diagnostics):
	pg_ast_node* source = js_cst_child(node, c"STRING")
	if (source == 0):
		pg_ast_node* from = js_cst_child(node, c"export_from")
		if (from == 0): from = js_cst_child(node, c"export_all")
		if (from != 0): source = js_cst_child(from, c"STRING")
	if (source == 0): return 1
	char* text = js_string_decode(source.text, diagnostics)
	if (text == 0): return 0
	free(text)
	return 1

int js_modules_function_kind(js_node* node):
	return js_kind(node, c"function") || js_kind(node, c"generator_function") || js_kind(node, c"async_function") || js_kind(node, c"async_generator_function")

# Lowers one `export default` statement. Declarations go into the body like
# ordinary hoisted functions or classes; an anonymous function declaration
# binds *default* and is renamed "default" once instantiated. Expressions and
# anonymous classes stay wrapped in export_default for js_modules_default.
js_node* js_modules_lower_default(js_module* entry, pg_ast_node* node, pg_diagnostics* diagnostics):
	js_node* wrapper = js_lower_node(node, diagnostics)
	if (wrapper == 0 || js_kind(wrapper, c"export_default") == 0 || wrapper.children.length != 1): return wrapper
	js_node* value = wrapper.children[0]
	int declaration = js_modules_function_kind(value) || js_kind(value, c"class")
	if (declaration == 0 || (strlen(value.text) == 0 && js_kind(value, c"class"))): return wrapper
	if (strlen(value.text) == 0):
		free(value.text)
		value.text = strclone(c"*default*")
		entry.default_function = 1
	wrapper.children.clear()
	js_node_free(wrapper)
	return value

int js_modules_supported(js_node* tree):
	for i in range(tree.children.length):
		js_node* node = tree.children[i]
		if (js_kind(node, c"export_default")): node = node.children[0]
		if (js_runtime_supported(node) == 0): return 0
	return 1

int js_modules_parse(js_modules* modules, js_module* entry, char* source, int length):
	js_runtime* rt = modules.runtime
	pg_parse_result* parsed = js_parse_with_limits(source, length, entry.identifier, 1, rt.parse_limits)
	if (parsed.success == 0):
		if (parsed.stream.resource_failed): js_runtime_fail(rt, 5, c"module parser resource limit")
		else: js_runtime_fail(rt, 6, c"invalid module syntax")
		pg_parse_result_free(parsed)
		return 0
	# The record (owned by the graph) keeps the parse result alive.
	js_module_record* record = js_module_graph_record(modules.graph, entry.identifier, parsed)
	record.host_defined = entry
	entry.record = record
	if (modules.requests + record.specifiers.length > modules.max_requests):
		js_runtime_fail(rt, 5, c"module request limit")
		return 0
	modules.requests = modules.requests + record.specifiers.length
	js_node* tree = js_node_new(c"program", c"")
	entry.tree = tree
	# Register before any allocation/evaluation may expose a closure.
	rt.scripts.push(tree)
	for i in range(parsed.root.children.length):
		if (rt.completion.status != 0): break
		pg_ast_node* node = parsed.root.children[i]
		if (node.token != 0): continue
		if (js_cst_is(node, c"statement")): node = node.children[0]
		int imported = js_cst_is(node, c"import_statement")
		int exported = js_cst_is(node, c"export_statement")
		if ((imported || exported) && js_modules_specifier_ok(node, parsed.diagnostics) == 0):
			js_runtime_fail(rt, 6, c"unsupported module specifier")
			break
		# Import and re-export entries live in the record.
		if (imported || (exported && (js_cst_child(node, c"export_named") != 0 || js_cst_child(node, c"export_all") != 0))): continue
		js_node* lowered = 0
		if (exported && js_cst_child(node, c"KW_DEFAULT") != 0): lowered = js_modules_lower_default(entry, node, parsed.diagnostics)
		else:
			if (exported): node = node.children[1]
			lowered = js_lower_node(node, parsed.diagnostics)
		if (lowered == 0):
			js_runtime_fail(rt, 6, c"module syntax outside the AST subset")
			break
		js_node_add(tree, lowered)
	if (rt.completion.status == 0 && js_modules_supported(tree) == 0): js_runtime_fail(rt, 6, c"module syntax outside the runtime subset")
	return rt.completion.status == 0

void js_modules_failed(js_modules* modules, js_module* entry):
	js_runtime* rt = modules.runtime
	entry.state = 4
	entry.error_status = rt.completion.status
	entry.error_message = rt.completion.message
	entry.error_value = rt.completion.value
	js_modules_retain(rt, entry, c"error", entry.error_value)

void js_modules_restore(js_runtime* rt, js_module* entry):
	rt.completion.status = entry.error_status
	rt.completion.message = entry.error_message
	rt.completion.value = entry.error_value

js_module* js_modules_find(js_modules* modules, char* identifier):
	for i in range(modules.entries.length):
		if (strcmp(modules.entries[i].identifier, identifier) == 0): return modules.entries[i]
	return 0

# HostResolveImportedModule plus ParseModule for the whole unloaded graph.
# New records are appended to loaded; a cached record (also one still
# loading, in a cycle) is returned as is, a cached failure restores it.
js_module* js_modules_load(js_modules* modules, char* specifier, char* referrer, int depth, list[js_module*] loaded):
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
	js_module* cached = js_modules_find(modules, resolved.identifier)
	if (cached != 0):
		if (cached.state == 4):
			js_modules_restore(rt, cached)
			return 0
		return cached
	if (modules.entries.length >= modules.max_modules || rt.scripts.length >= rt.max_scripts || resolved.length < 0 || resolved.length > rt.max_source_bytes || resolved.length > modules.max_bytes - modules.bytes):
		js_runtime_fail(rt, 5, c"module count or source limit")
		return 0
	if (resolved.source == 0):
		js_runtime_fail(rt, 2, c"module resolver returned no source")
		return 0
	js_module* entry = new js_module()
	entry.identifier = strclone(resolved.identifier)
	entry.requested = new list[js_module*]
	entry.retained = js_runtime_alloc(rt, 5)
	js_runtime_root(rt, entry.retained)
	modules.entries.push(entry)
	loaded.push(entry)
	modules.bytes = modules.bytes + resolved.length
	if (rt.completion.status != 0 || js_modules_parse(modules, entry, resolved.source, resolved.length) == 0): return 0
	js_module_record* record = entry.record
	for i in range(record.specifiers.length):
		js_module* child = js_modules_load(modules, record.specifiers[i], entry.identifier, depth + 1, loaded)
		if (child == 0): return 0
		entry.requested.push(child)
		record.requested.push(child.record)
	return entry

js_module* js_modules_host(js_module_record* record):
	return cast(js_module*, record.host_defined)

# GetModuleNamespace: a null-prototype object whose sorted export names are
# live, non-configurable aliases (accessor tag 2) of the resolved bindings,
# plus @@toStringTag "Module". Keys sort by UTF-8 bytes, which matches the
# spec's UTF-16 order except between supplementary and U+E000..U+FFFF
# characters. [[Set]] and new properties are rejected by the runtime brand.
js_value* js_modules_namespace_object(js_modules* modules, js_module* entry):
	js_runtime* rt = modules.runtime
	if (entry.namespace != 0): return entry.namespace
	js_value* namespace = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	namespace.prototype = 0
	entry.namespace = namespace
	js_modules_retain(rt, entry, c"namespace", namespace)
	list[char*] names = js_module_namespace_names(modules.graph, entry.record)
	for i in range(1, names.length):
		int j = i
		while (j > 0 && strcmp(names[j - 1], names[j]) > 0):
			char* swap = names[j]
			names[j] = names[j - 1]
			names[j - 1] = swap
			j = j - 1
	for char* name in names:
		if (rt.completion.status != 0): break
		js_module_record* module = 0
		char* binding = 0
		if (js_module_graph_resolve_binding(modules.graph, entry.record, name, &module, &binding) != 1): continue
		js_text* key = js_runtime_key(name)
		js_module* target = js_modules_host(module)
		if (strcmp(binding, c"*namespace*") == 0): js_runtime_define_data(rt, namespace, key, js_modules_namespace_object(modules, target), 1, 1, 0)
		else:
			js_value* original = js_runtime_binding(target.environment, binding)
			if (original != 0 && js_runtime_put(rt, namespace, key, rt.undefined_value)):
				js_value* property = js_runtime_property(namespace, key)
				property.accessor = 2
				property.getter = target.environment
				property.host_context = original
				property.configurable = 0
		js_text_free(key)
	__w_list_free(cast(__w_list*, names))
	if (rt.completion.status == 0 && rt.symbols.length >= JS_SYMBOL_TO_STRING_TAG):
		js_text* tag = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
		js_runtime_define_data(rt, namespace, tag, js_runtime_string_value(rt, c"Module"), 0, 0, 0)
		js_text_free(tag)
	namespace.builtin_state = JS_BRAND_MODULE_NAMESPACE
	return namespace

# InitializeEnvironment, first half: the module environment with its var,
# lexical (TDZ) and *default* bindings and instantiated functions.
void js_modules_environment(js_modules* modules, js_module* entry):
	js_runtime* rt = modules.runtime
	js_value* env = js_runtime_environment(rt, rt.global)
	if (rt.completion.status != 0): return
	entry.environment = env
	js_modules_retain(rt, entry, c"environment", env)
	env.strict = 1
	env.variable_scope = 1
	env.this_value = rt.undefined_value
	for i in range(entry.tree.children.length):
		if (js_kind(entry.tree.children[i], c"export_default") == 0): continue
		js_text* key = js_runtime_key(c"*default*")
		js_runtime_put(rt, env, key, rt.undefined_value)
		js_value* binding = js_runtime_property(env, key)
		if (binding != 0):
			binding.initialized = 0
			binding.lexical_binding = 1
		js_text_free(key)
	if (rt.completion.status == 0): js_runtime_var_declare(rt, entry.tree, env, 0)
	if (rt.completion.status == 0): js_runtime_declare(rt, entry.tree, env)
	if (rt.completion.status == 0): js_runtime_var_declare(rt, entry.tree, env, 1)
	if (rt.completion.status == 0 && entry.default_function):
		js_value* binding = js_runtime_binding(env, c"*default*")
		js_text* label = js_runtime_key(c"default")
		if (binding != 0): js_runtime_set_name(rt, binding.value, c"", label)
		js_text_free(label)

void js_modules_immutable(js_runtime* rt, js_value* env, char* name, js_value* value):
	js_text* key = js_runtime_key(name)
	js_runtime_put(rt, env, key, value)
	js_value* binding = js_runtime_property(env, key)
	if (binding != 0):
		binding.immutable = 1
		binding.lexical_binding = 1
	js_text_free(key)

# InitializeEnvironment, second half: import bindings. Pass 0 creates every
# namespace import binding, pass 1 stores its namespace object (whose keys
# may alias another module's namespace import), and pass 2 makes named
# imports live read-only aliases of the resolved binding, which may still be
# uninitialized (TDZ) in a cycle.
void js_modules_bind_imports(js_modules* modules, js_module* entry, int pass):
	js_runtime* rt = modules.runtime
	js_module_record* record = entry.record
	for js_module_entry* item in record.imports:
		if (rt.completion.status != 0): return
		js_module_record* module = record.requested[item.request]
		int namespace = strcmp(item.import_name, c"*") == 0
		if (namespace != (pass < 2)): continue
		if (pass == 0):
			js_modules_immutable(rt, entry.environment, item.local_name, rt.undefined_value)
			continue
		if (pass == 1):
			js_value* value = js_modules_namespace_object(modules, js_modules_host(module))
			js_value* binding = js_runtime_binding(entry.environment, item.local_name)
			if (binding != 0): binding.value = value
			continue
		char* name = 0
		if (js_module_graph_resolve_binding(modules.graph, module, item.import_name, &module, &name) != 1):
			js_runtime_fail(rt, 2, c"module export cannot be resolved")
			return
		js_module* target = js_modules_host(module)
		if (strcmp(name, c"*namespace*") == 0):
			js_modules_immutable(rt, entry.environment, item.local_name, js_modules_namespace_object(modules, target))
			continue
		js_value* original = js_runtime_binding(target.environment, name)
		if (original == 0):
			js_runtime_fail(rt, 2, c"module export cannot be resolved")
			return
		js_modules_immutable(rt, entry.environment, item.local_name, original.value)
		js_value* alias = js_runtime_binding(entry.environment, item.local_name)
		if (alias != 0):
			alias.accessor = 2
			alias.getter = target.environment
			alias.host_context = original

# Collects the unlinked modules reachable from entry. A failed dependency
# restores its cached failure.
int js_modules_pending(js_modules* modules, js_module* entry, list[js_module*] pending):
	if (entry.state == 4):
		js_modules_restore(modules.runtime, entry)
		return 0
	if (entry.state != 0): return 1
	for js_module* seen in pending:
		if (seen == entry): return 1
	pending.push(entry)
	for js_module* required in entry.requested:
		if (js_modules_pending(modules, required, pending) == 0): return 0
	return 1

# Link: load the unloaded graph, resolve every import and indirect export of
# its unlinked records, then initialize all their environments before any
# import binding is created, so cycles bind in either order. A failure caches
# on the modules that caused it (an unloadable or invalid source and its
# partially loaded importers, or the record that does not resolve); other
# loaded records stay unlinked, as the spec resets them, and link again later.
js_module* js_modules_link(js_modules* modules, char* specifier, char* referrer, int depth):
	js_runtime* rt = modules.runtime
	list[js_module*] loaded = new list[js_module*]
	list[js_module*] pending = new list[js_module*]
	js_module* root = js_modules_load(modules, specifier, referrer, depth, loaded)
	if (root == 0):
		for js_module* entry in loaded:
			if (entry.record == 0 || entry.requested.length != entry.record.specifiers.length): js_modules_failed(modules, entry)
	else if (js_modules_pending(modules, root, pending)):
		modules.graph.error_type = 0
		for js_module* entry in pending:
			if (js_module_graph_validate_record(modules.graph, entry.record)): continue
			int status = 2
			if (strcmp(modules.graph.error_message, c"module export resolution limit") == 0): status = 5
			js_runtime_fail(rt, status, modules.graph.error_message)
			js_modules_failed(modules, entry)
			break
		if (rt.completion.status == 0):
			for js_module* entry in pending:
				if (rt.completion.status == 0): js_modules_environment(modules, entry)
			for pass in range(3):
				for js_module* entry in pending:
					if (rt.completion.status == 0): js_modules_bind_imports(modules, entry, pass)
			for js_module* entry in pending:
				if (rt.completion.status == 0): entry.state = 1
				else: js_modules_failed(modules, entry)
	__w_list_free(cast(__w_list*, loaded))
	__w_list_free(cast(__w_list*, pending))
	if (rt.completion.status != 0): return 0
	return root

# `export default` of an expression or anonymous class: NamedEvaluation with
# "default", then initialize *default*.
void js_modules_default(js_runtime* rt, js_node* node, js_value* env):
	js_node* value = node.children[0]
	js_value* result = rt.undefined_value
	if (js_kind(value, c"class")): result = js_runtime_class_named(rt, value, env, c"default")
	else: result = js_runtime_named_eval(rt, value, env, c"default")
	if (rt.completion.status != 0): return
	rt.empty = 1
	js_value* binding = js_runtime_binding(env, c"*default*")
	if (binding != 0):
		binding.value = result
		binding.initialized = 1

# InnerModuleEvaluation: depth-first, dependencies in request order; a
# strongly connected component finishes when its root does.
int js_modules_inner_evaluate(js_modules* modules, js_module* entry, list[js_module*] stack, int* index):
	js_runtime* rt = modules.runtime
	if (entry.state == 4):
		js_modules_restore(rt, entry)
		return 0
	if (entry.state == 2 || entry.state == 3): return 1
	entry.state = 2
	entry.dfs_index = *index
	entry.dfs_ancestor = *index
	*index = *index + 1
	stack.push(entry)
	for js_module* required in entry.requested:
		if (js_modules_inner_evaluate(modules, required, stack, index) == 0): return 0
		if (required.state == 2 && required.dfs_ancestor < entry.dfs_ancestor): entry.dfs_ancestor = required.dfs_ancestor
	for i in range(entry.tree.children.length):
		if (rt.completion.status != 0): break
		js_node* node = entry.tree.children[i]
		if (js_kind(node, c"export_default")): js_modules_default(rt, node, entry.environment)
		else: js_runtime_eval_node(rt, node, entry.environment)
	if (rt.completion.status != 0): return 0
	if (entry.dfs_ancestor == entry.dfs_index):
		while (stack.length > 0):
			js_module* done = stack.pop()
			done.state = 3
			if (done == entry): break
	return 1

# Evaluate(): an abrupt completion marks every module still on the stack
# failed with the same error.
int js_modules_execute(js_modules* modules, js_module* entry):
	list[js_module*] stack = new list[js_module*]
	int index = 0
	int ok = js_modules_inner_evaluate(modules, entry, stack, &index)
	if (ok == 0):
		for js_module* failed in stack: js_modules_failed(modules, failed)
	__w_list_free(cast(__w_list*, stack))
	return ok

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
	if (entry != 0 && js_modules_execute(modules, entry) == 0): entry = 0
	rt.running = 0
	return entry

int js_modules_owned(js_modules* modules, js_module* entry):
	for i in range(modules.entries.length):
		if (modules.entries[i] == entry): return 1
	return 0

# The module namespace object of a linked record (GetModuleNamespace), or
# null for a foreign, unlinked or failed record. Borrowed like an export.
js_value* js_modules_namespace(js_modules* modules, js_module* entry):
	if (js_modules_owned(modules, entry) == 0 || entry.state == 0 || entry.state == 4): return 0
	js_runtime* rt = modules.runtime
	if (entry.namespace == 0 && js_runtime_begin(rt, 1) == 0): return 0
	js_value* namespace = js_modules_namespace_object(modules, entry)
	if (rt.completion.status != 0): return 0
	return namespace

# Borrowed value; root it across collection or loader destruction. Missing
# or ambiguous names, uninitialized bindings, foreign records and
# unevaluated modules return null.
js_value* js_modules_export(js_modules* modules, js_module* entry, char* name):
	if (js_modules_owned(modules, entry) == 0 || entry.state != 3): return 0
	js_module_record* module = 0
	char* binding = 0
	if (js_module_graph_resolve_binding(modules.graph, entry.record, name, &module, &binding) != 1): return 0
	js_module* target = js_modules_host(module)
	if (strcmp(binding, c"*namespace*") == 0): return js_modules_namespace(modules, target)
	js_value* found = js_runtime_binding(target.environment, binding)
	if (found == 0 || found.initialized == 0): return 0
	return found.value
