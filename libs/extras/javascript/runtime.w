/*
Embeddable, bounded AST interpreter for the documented JS subset (64-bit W).
Each instance owns its heap, global lexical environment, scripts and roots.
Collection is explicit and only allowed between evaluations/host calls; no
moving pointers. Returned values are borrowed until collection. The most recent
completion is rooted until the next evaluation. Host-retained values need roots.
See docs/projects/javascript.md for the semantic and resource contract.
*/
import libs.extras.javascript.parser
import libs.extras.javascript.lower
import libs.extras.javascript.printer
import lib.float64_format
import lib.fmath64


# kind: undefined=0, null=1, boolean=2, number=3, string=4,
# object=5, array=6, callable=7, environment=8, host-callable=9.
struct js_value:
	void* owner
	int kind
	float64 number
	js_text* text
	list[js_value*] properties
	js_value* parent
	js_node* code
	int host
	int array_length
	int marked
	js_text* key
	js_value* value
	int immutable
	int initialized
	js_value* prototype
	js_value* getter
	js_value* setter
	int accessor
	int writable
	int enumerable
	int configurable
	void* host_context
	int host_get
	int host_set
	int host_receiver
	js_value* this_value


type js_host_function = fn(void*, list[js_value*]) -> js_value*
# Null getter result and zero setter result delegate to ordinary properties.
# Negative setter result signals rejection. Keys/context are borrowed.
type js_host_getter = fn(void*, void*, js_value*, js_text*) -> js_value*
type js_host_setter = fn(void*, void*, js_value*, js_text*, js_value*) -> int
type js_host_receiver_function = fn(void*, void*, js_value*, list[js_value*]) -> js_value*


# status: normal=0, return=1 (internal), throw=2, break=3, continue=4
# (internal), limit=5, unsupported=6. message is static borrowed text.
struct js_completion:
	int status
	js_value* value
	char* message
	int steps


struct js_runtime:
	list[js_value*] heap
	list[js_value*] roots
	list[js_node*] scripts
	js_value* global
	js_value* undefined_value
	js_completion* completion
	int running
	int depth
	int max_depth
	int max_values
	int max_properties
	int max_scripts
	int max_source_bytes
	js_parse_limits* parse_limits
	int remaining
	int empty


js_value* js_runtime_member_read(js_runtime* rt, js_value* object, js_text* key);
int js_runtime_member_write(js_runtime* rt, js_value* object, js_text* key, js_value* value);
js_value* js_runtime_call_receiver(js_runtime* rt, js_value* callable, js_value* receiver, list[js_value*] args);
int js_runtime_same_value(js_value* a, js_value* b);
js_value* js_runtime_error_value(js_runtime* rt, char* message);
int js_runtime_define_data(js_runtime* rt, js_value* object, js_text* key, js_value* value, int writable, int enumerable, int configurable);


void js_runtime_fail(js_runtime* rt, int status, char* message):
	if (rt.completion.status != 0): return
	rt.completion.status = status
	rt.completion.message = message
	rt.completion.value = rt.undefined_value
	if (status == 2): rt.completion.value = js_runtime_error_value(rt, message)


js_value* js_runtime_alloc(js_runtime* rt, int kind):
	if (rt.heap.length >= rt.max_values):
		js_runtime_fail(rt, 5, c"JavaScript heap value limit")
		return rt.undefined_value
	js_value* value = new js_value()
	value.owner = rt
	value.kind = kind
	value.number = 0.0
	value.text = 0
	value.properties = new list[js_value*]
	value.parent = 0
	value.code = 0
	value.host = 0
	value.array_length = 0
	value.marked = 0
	value.key = 0
	value.value = 0
	value.immutable = 0
	value.initialized = 1
	value.prototype = 0
	value.getter = 0
	value.setter = 0
	value.accessor = 0
	value.writable = 1
	value.enumerable = 1
	value.configurable = 1
	value.host_context = 0
	value.host_get = 0
	value.host_set = 0
	value.host_receiver = 0
	value.this_value = 0
	rt.heap.push(value)
	return value


js_value* js_runtime_number(js_runtime* rt, float64 number):
	js_value* value = js_runtime_alloc(rt, 3)
	if (value != rt.undefined_value): value.number = number
	return value


js_value* js_runtime_boolean(js_runtime* rt, int truth):
	js_value* value = js_runtime_alloc(rt, 2)
	if (value != rt.undefined_value): value.number = cast(float64, truth != 0)
	return value


js_value* js_runtime_string(js_runtime* rt, js_text* text):
	if (text == 0 || text.units.length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript string length limit")
		return rt.undefined_value
	for i in range(text.units.length):
		if (text.units[i] < 0 || text.units[i] > 65535):
			js_runtime_fail(rt, 2, c"invalid UTF-16 code unit")
			return rt.undefined_value
	js_value* value = js_runtime_alloc(rt, 4)
	if (value != rt.undefined_value): value.text = js_text_clone(text)
	return value


js_value* js_runtime_property(js_value* object, js_text* key):
	for i in range(object.properties.length):
		if (js_text_equal(object.properties[i].key, key)): return object.properties[i]
	return 0


int js_runtime_put(js_runtime* rt, js_value* object, js_text* key, js_value* value):
	if (object == 0 || value == 0 || object.owner != rt || value.owner != rt): return 0
	if (object.kind < 5 || object.kind > 9): return 0
	if (key == 0 || key.units.length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript property key length limit")
		return 0
	js_value* property = js_runtime_property(object, key)
	if (property == 0):
		if (object.properties.length >= rt.max_properties):
			js_runtime_fail(rt, 5, c"JavaScript property limit")
			return 0
		property = new js_value()
		property.key = js_text_clone(key)
		property.immutable = 0
		property.initialized = 1
		property.accessor = 0
		property.writable = 1
		property.enumerable = 1
		property.configurable = 1
		property.getter = 0
		property.setter = 0
		object.properties.push(property)
	else if (property.immutable):
		js_runtime_fail(rt, 2, c"assignment to constant binding")
		return 0
	property.value = value
	return 1


js_text* js_runtime_key(char* text):
	return js_text_from_utf8(text, strlen(text))


int js_runtime_set(js_runtime* rt, js_value* object, char* key, js_value* value):
	js_text* text = js_runtime_key(key)
	if (text == 0): return 0
	int ok = js_runtime_member_write(rt, object, text, value)
	js_text_free(text)
	return ok


js_value* js_runtime_get(js_runtime* rt, js_value* object, char* key):
	if (object == 0 || object.owner != rt): return rt.undefined_value
	js_text* text = js_runtime_key(key)
	if (text == 0): return rt.undefined_value
	js_value* value = js_runtime_member_read(rt, object, text)
	js_text_free(text)
	return value


# Minimal typed runtime errors. Full Error intrinsics/prototypes are separate;
# allocation failure while reporting an error remains bounded.
js_value* js_runtime_error_value(js_runtime* rt, char* message):
	if (rt.max_values - rt.heap.length < 3 || rt.max_properties < 2 || strlen(message) > rt.max_properties || rt.max_properties < 14): return rt.undefined_value
	char* name = c"TypeError"
	if (strcmp(message, c"uninitialized or missing binding") == 0): name = c"ReferenceError"
	if (strcmp(message, c"duplicate lexical binding") == 0 || strcmp(message, c"duplicate callable binding") == 0): name = c"SyntaxError"
	js_value* error = js_runtime_alloc(rt, 5)
	js_text* key = js_runtime_key(name)
	js_value* label = js_runtime_string(rt, key)
	js_text_free(key)
	key = js_runtime_key(message)
	js_value* detail = js_runtime_string(rt, key)
	js_text_free(key)
	# Error creation bypasses host operations and cannot invoke user code.
	key = js_runtime_key(c"name")
	js_runtime_put(rt, error, key, label)
	js_text_free(key)
	key = js_runtime_key(c"message")
	js_runtime_put(rt, error, key, detail)
	js_text_free(key)
	return error


js_runtime* js_runtime_new():
	js_runtime* rt = new js_runtime()
	rt.heap = new list[js_value*]
	rt.roots = new list[js_value*]
	rt.scripts = new list[js_node*]
	rt.completion = new js_completion()
	rt.completion.status = 0
	rt.completion.value = 0
	rt.completion.message = c""
	rt.completion.steps = 0
	rt.running = 0
	rt.depth = 0
	rt.max_depth = 256
	rt.max_values = 100000
	rt.max_properties = 10000
	rt.max_scripts = 1000
	rt.max_source_bytes = 1048576
	rt.parse_limits = js_parse_limits_new()
	rt.remaining = 0
	rt.empty = 1
	rt.undefined_value = 0
	rt.undefined_value = js_runtime_alloc(rt, 0)
	rt.global = js_runtime_alloc(rt, 8)
	rt.completion.value = rt.undefined_value
	js_runtime_set(rt, rt.global, c"undefined", rt.undefined_value)
	js_runtime_set(rt, rt.global, c"NaN", js_runtime_number(rt, float64_from_bits((0x7ff << 52) | 1)))
	js_runtime_set(rt, rt.global, c"Infinity", js_runtime_number(rt, float64_from_bits(0x7ff << 52)))
	for i in range(rt.global.properties.length): rt.global.properties[i].immutable = 1
	return rt


int js_runtime_root(js_runtime* rt, js_value* value):
	if (value == 0 || value.owner != rt): return 0
	for i in range(rt.roots.length):
		if (rt.roots[i] == value): return 1
	rt.roots.push(value)
	return 1


void js_runtime_unroot(js_runtime* rt, js_value* value):
	for i in range(rt.roots.length):
		if (rt.roots[i] == value):
			rt.roots[i] = rt.roots[rt.roots.length - 1]
			rt.roots.pop()
			return


void js_runtime_value_free(js_value* value):
	js_text_free(value.text)
	for i in range(value.properties.length):
		js_value* property = value.properties[i]
		js_text_free(property.key)
		free(property)
	__w_list_free(cast(__w_list*, value.properties))
	free(value)


void js_runtime_mark(list[js_value*] pending, js_value* value):
	if (value == 0 || value.marked): return
	value.marked = 1
	pending.push(value)


# Returns reclaimed values, or -1 while executing. Iterative tracing handles
# object cycles and closure/environment cycles without recursive C/W calls.
int js_runtime_collect(js_runtime* rt):
	if (rt.running): return -1
	list[js_value*] pending = new list[js_value*]
	js_runtime_mark(pending, rt.global)
	js_runtime_mark(pending, rt.undefined_value)
	js_runtime_mark(pending, rt.completion.value)
	for i in range(rt.roots.length): js_runtime_mark(pending, rt.roots[i])
	while (pending.length > 0):
		js_value* value = pending.pop()
		js_runtime_mark(pending, value.parent)
		js_runtime_mark(pending, value.prototype)
		js_runtime_mark(pending, value.this_value)
		for i in range(value.properties.length):
			js_runtime_mark(pending, value.properties[i].value)
			js_runtime_mark(pending, value.properties[i].getter)
			js_runtime_mark(pending, value.properties[i].setter)
	__w_list_free(cast(__w_list*, pending))
	int live = 0
	int before = rt.heap.length
	for i in range(before):
		js_value* value = rt.heap[i]
		if (value.marked):
			value.marked = 0
			rt.heap[live] = value
			live = live + 1
		else: js_runtime_value_free(value)
	while (rt.heap.length > live): rt.heap.pop()
	return before - live


void js_runtime_free(js_runtime* rt):
	if (rt == 0): return
	for i in range(rt.heap.length): js_runtime_value_free(rt.heap[i])
	for i in range(rt.scripts.length): js_node_free(rt.scripts[i])
	__w_list_free(cast(__w_list*, rt.heap))
	__w_list_free(cast(__w_list*, rt.roots))
	__w_list_free(cast(__w_list*, rt.scripts))
	free(rt.parse_limits)
	free(rt.completion)
	free(rt)


int js_runtime_bind(js_runtime* rt, char* name, js_host_function* callback):
	if (rt.running || callback == 0): return 0
	js_value* callable = js_runtime_alloc(rt, 9)
	if (callable == rt.undefined_value): return 0
	callable.host = cast(int, callback)
	return js_runtime_set(rt, rt.global, name, callable)


void js_runtime_throw(js_runtime* rt, js_value* value):
	if (value == 0 || value.owner != rt):
		js_runtime_fail(rt, 2, c"foreign host exception value")
		return
	if (rt.completion.status != 0): return
	rt.completion.status = 2
	rt.completion.value = value
	rt.completion.message = c"host exception"


int js_runtime_truth(js_value* value):
	if (value.kind == 0 || value.kind == 1): return 0
	if (value.kind == 2 || value.kind == 3): return value.number != 0.0 && f64is_nan(value.number) == 0
	if (value.kind == 4): return value.text.units.length != 0
	return 1


js_value* js_runtime_binding(js_value* env, char* name):
	js_text* key = js_runtime_key(name)
	while (env != 0):
		js_value* property = js_runtime_property(env, key)
		if (property != 0):
			js_text_free(key)
			return property
		env = env.parent
	js_text_free(key)
	return 0


js_value* js_runtime_environment(js_runtime* rt, js_value* parent):
	js_value* env = js_runtime_alloc(rt, 8)
	if (env != rt.undefined_value): env.parent = parent
	return env


js_value* js_runtime_function(js_runtime* rt, js_node* node, js_value* env):
	js_value* callable = js_runtime_alloc(rt, 7)
	if (callable == rt.undefined_value): return callable
	callable.code = node
	callable.parent = env
	js_text* name = js_runtime_key(node.text)
	js_value* name_value = js_runtime_string(rt, name)
	js_text_free(name)
	name = js_runtime_key(c"name")
	js_runtime_define_data(rt, callable, name, name_value, 0, 0, 1)
	js_text_free(name)
	name = js_runtime_key(c"length")
	js_runtime_define_data(rt, callable, name, js_runtime_number(rt, cast(float64, node.children[0].children.length)), 0, 0, 1)
	js_text_free(name)
	if (js_kind(node, c"function_expression") && strlen(node.text) > 0):
		callable.parent = js_runtime_environment(rt, env)
		js_runtime_set(rt, callable.parent, node.text, callable)
		js_value* binding = js_runtime_binding(callable.parent, node.text)
		if (binding != 0): binding.immutable = 1
	return callable


# Predeclare lexical names before evaluating any statement (TDZ), and hoist
# ordinary callable declarations in this lexical scope.
void js_runtime_declare(js_runtime* rt, js_node* node, js_value* env):
	# Check this scope before installing any bindings. A failed subsequent
	# script must not leave earlier declarations permanently uninitialized.
	for i in range(node.children.length):
		js_node* statement = node.children[i]
		if (js_kind(statement, c"variable")):
			for j in range(statement.children.length):
				js_text* key = js_runtime_key(statement.children[j].children[0].text)
				int duplicate = js_runtime_property(env, key) != 0
				js_text_free(key)
				if (duplicate):
					js_runtime_fail(rt, 2, c"duplicate lexical binding")
					return
		else if (js_kind(statement, c"function")):
			js_text* key = js_runtime_key(statement.text)
			int duplicate = js_runtime_property(env, key) != 0
			js_text_free(key)
			if (duplicate):
				js_runtime_fail(rt, 2, c"duplicate callable binding")
				return
	for i in range(node.children.length):
		if (rt.completion.status != 0): return
		js_node* statement = node.children[i]
		if (js_kind(statement, c"variable")):
			for j in range(statement.children.length):
				if (rt.completion.status != 0): return
				char* name = statement.children[j].children[0].text
				js_text* key = js_runtime_key(name)
				if (js_runtime_property(env, key) != 0): js_runtime_fail(rt, 2, c"duplicate lexical binding")
				else:
					js_runtime_put(rt, env, key, rt.undefined_value)
					js_value* binding = js_runtime_property(env, key)
					if (binding != 0):
						binding.initialized = 0
						binding.immutable = strcmp(statement.text, c"const") == 0
				js_text_free(key)
		else if (js_kind(statement, c"function")):
			js_text* key = js_runtime_key(statement.text)
			if (js_runtime_property(env, key) != 0): js_runtime_fail(rt, 2, c"duplicate callable binding")
			else: js_runtime_put(rt, env, key, js_runtime_function(rt, statement, env))
			js_text_free(key)


js_value* js_runtime_eval_node(js_runtime* rt, js_node* node, js_value* env);


int js_runtime_equal(js_value* a, js_value* b):
	if (a.kind != b.kind): return 0
	if (a.kind == 0 || a.kind == 1): return 1
	if (a.kind == 2 || a.kind == 3): return f64is_nan(a.number) == 0 && f64is_nan(b.number) == 0 && a.number == b.number
	if (a.kind == 4): return js_text_equal(a.text, b.text)
	return a == b


js_value* js_runtime_binary(js_runtime* rt, char* op, js_value* a, js_value* b):
	if (strcmp(op, c"===") == 0): return js_runtime_boolean(rt, js_runtime_equal(a, b))
	if (strcmp(op, c"!==") == 0): return js_runtime_boolean(rt, js_runtime_equal(a, b) == 0)
	if (strcmp(op, c"+") == 0 && a.kind == 4 && b.kind == 4):
		if (a.text.units.length > rt.max_properties - b.text.units.length):
			js_runtime_fail(rt, 5, c"JavaScript string length limit")
			return rt.undefined_value
		js_text* joined = js_text_clone(a.text)
		for i in range(b.text.units.length): joined.units.push(b.text.units[i])
		js_value* result = js_runtime_string(rt, joined)
		js_text_free(joined)
		return result
	if (a.kind != 3 || b.kind != 3):
		js_runtime_fail(rt, 6, c"implicit coercion is outside the runtime subset")
		return rt.undefined_value
	float64 x = a.number
	float64 y = b.number
	if (strcmp(op, c"+") == 0): return js_runtime_number(rt, x + y)
	if (strcmp(op, c"-") == 0): return js_runtime_number(rt, x - y)
	if (strcmp(op, c"*") == 0): return js_runtime_number(rt, x * y)
	if (strcmp(op, c"/") == 0): return js_runtime_number(rt, x / y)
	int ordered = f64is_nan(x) == 0 && f64is_nan(y) == 0
	if (strcmp(op, c"<") == 0): return js_runtime_boolean(rt, ordered && x < y)
	if (strcmp(op, c">") == 0): return js_runtime_boolean(rt, ordered && x > y)
	if (strcmp(op, c"<=") == 0): return js_runtime_boolean(rt, ordered && x <= y)
	if (strcmp(op, c">=") == 0): return js_runtime_boolean(rt, ordered && x >= y)
	js_runtime_fail(rt, 6, c"unsupported binary operator")
	return rt.undefined_value


# Property-key conversion is explicit: strings and nonnegative bounded integer
# indices only. Ordinary object ToPrimitive hooks are outside this subset.
js_text* js_runtime_member_key(js_runtime* rt, js_node* node, js_value* env):
	if (js_kind(node, c"member")): return js_runtime_key(node.children[1].text)
	js_value* key = js_runtime_eval_node(rt, node.children[1], env)
	if (key.kind == 4): return js_text_clone(key.text)
	if (key.kind == 3 && key.number >= 0.0 && key.number < cast(float64, rt.max_properties)):
		int index = cast(int, key.number)
		if (cast(float64, index) == key.number):
			char* spelling = itoa(index)
			js_text* text = js_runtime_key(spelling)
			free(spelling)
			return text
	js_runtime_fail(rt, 6, c"unsupported computed property key")
	return 0


int js_runtime_array_index(js_text* key):
	if (key.units.length == 0 || key.units.length > 10): return -1
	if (key.units.length > 1 && key.units[0] == '0'): return -1
	int index = 0
	for i in range(key.units.length):
		int digit = key.units[i] - '0'
		if (digit < 0 || digit > 9): return -1
		index = index * 10 + digit
	if (index >= (1 << 32) - 1): return -1
	return index


int js_runtime_key_is(js_text* key, char* name):
	if (key.units.length != strlen(name)): return 0
	for i in range(key.units.length):
		if (key.units[i] != name[i]): return 0
	return 1


# Object internal operations. Environments keep their own parent/binding path;
# prototype never aliases a closure's environment link.
int js_runtime_object(js_value* value):
	return value != 0 && (value.kind == 5 || value.kind == 6 || value.kind == 7 || value.kind == 9)


int js_runtime_set_prototype(js_runtime* rt, js_value* object, js_value* prototype):
	if (js_runtime_object(object) == 0 || object.owner != rt): return 0
	if (prototype != 0 && (js_runtime_object(prototype) == 0 || prototype.owner != rt)): return 0
	js_value* current = prototype
	int depth = 0
	while (current != 0):
		if (current == object): return 0
		depth = depth + 1
		if (depth >= rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return 0
		current = current.prototype
	object.prototype = prototype
	return 1


int js_runtime_set_host_hooks(js_runtime* rt, js_value* object, void* context, js_host_getter* getter, js_host_setter* setter):
	if (js_runtime_object(object) == 0 || object.owner != rt): return 0
	object.host_context = context
	object.host_get = cast(int, getter)
	object.host_set = cast(int, setter)
	return 1


js_value* js_runtime_host_callable(js_runtime* rt, void* context, js_host_receiver_function* callback):
	if (callback == 0): return rt.undefined_value
	js_value* callable = js_runtime_alloc(rt, 9)
	if (callable != rt.undefined_value):
		callable.host = cast(int, callback)
		callable.host_receiver = 1
		callable.host_context = context
	return callable


# Fully specified descriptors, not partial ECMAScript descriptor records.
# Attributes are booleans. A null getter/setter denotes its absence.
int js_runtime_define(js_runtime* rt, js_value* object, js_text* key, js_value* value, js_value* getter, js_value* setter, int accessor, int writable, int enumerable, int configurable):
	if (js_runtime_object(object) == 0 || object.owner != rt || key == 0): return 0
	if (value == 0 || value.owner != rt): return 0
	if (getter != 0 && (getter.owner != rt || (getter.kind != 7 && getter.kind != 9))): return 0
	if (setter != 0 && (setter.owner != rt || (setter.kind != 7 && setter.kind != 9))): return 0
	js_value* property = js_runtime_property(object, key)
	if (property != 0 && property.configurable == 0):
		if (configurable || enumerable != property.enumerable || accessor != property.accessor): return 0
		if (accessor):
			if (getter != property.getter || setter != property.setter): return 0
		else if (property.writable == 0):
			if (writable || js_runtime_same_value(property.value, value) == 0): return 0
	if (property == 0):
		if (js_runtime_put(rt, object, key, value) == 0): return 0
		property = js_runtime_property(object, key)
	property.value = value
	property.getter = getter
	property.setter = setter
	property.accessor = accessor != 0
	property.writable = writable != 0
	property.enumerable = enumerable != 0
	property.configurable = configurable != 0
	return 1


int js_runtime_same_value(js_value* a, js_value* b):
	if (a.kind == 3 && b.kind == 3):
		if (f64is_nan(a.number) && f64is_nan(b.number)): return 1
		if (a.number == 0.0 && b.number == 0.0): return float64_bits(a.number) == float64_bits(b.number)
	return js_runtime_equal(a, b)


int js_runtime_define_data(js_runtime* rt, js_value* object, js_text* key, js_value* value, int writable, int enumerable, int configurable):
	return js_runtime_define(rt, object, key, value, 0, 0, 0, writable, enumerable, configurable)


int js_runtime_define_accessor(js_runtime* rt, js_value* object, js_text* key, js_value* getter, js_value* setter, int enumerable, int configurable):
	return js_runtime_define(rt, object, key, rt.undefined_value, getter, setter, 1, 0, enumerable, configurable)


int js_runtime_delete(js_runtime* rt, js_value* object, js_text* key):
	if (js_runtime_object(object) == 0 || object.owner != rt || key == 0): return 0
	for i in range(object.properties.length):
		js_value* property = object.properties[i]
		if (js_text_equal(property.key, key)):
			if (property.configurable == 0): return 0
			js_text_free(property.key)
			free(property)
			for j in range(i, object.properties.length - 1): object.properties[j] = object.properties[j + 1]
			object.properties.pop()
			return 1
	return 1


# Property callbacks cannot collect or reenter evaluation, including when a
# host initiates a read outside evaluation. Recursive hooks share depth/budget.
int js_runtime_property_enter(js_runtime* rt):
	if (rt.depth >= rt.max_depth || (rt.running && rt.remaining <= 0)):
		js_runtime_fail(rt, 5, c"JavaScript property execution limit")
		return 0
	if (rt.running == 0): rt.remaining = 10000
	rt.remaining = rt.remaining - 1
	rt.depth = rt.depth + 1
	rt.running = rt.running + 1
	return 1


void js_runtime_property_leave(js_runtime* rt):
	rt.depth = rt.depth - 1
	rt.running = rt.running - 1


js_value* js_runtime_read_receiver(js_runtime* rt, js_value* object, js_text* key, js_value* receiver):
	if (key == 0 || object == 0 || object.owner != rt || receiver == 0 || receiver.owner != rt): return rt.undefined_value
	js_value* current = object
	int depth = 0
	while (current != 0):
		depth = depth + 1
		if (depth > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return rt.undefined_value
		if (current.host_get != 0):
			if (js_runtime_property_enter(rt) == 0): return rt.undefined_value
			js_host_getter* callback = cast(js_host_getter*, current.host_get)
			js_value* value = callback(rt, current.host_context, receiver, key)
			js_runtime_property_leave(rt)
			if (rt.completion.status != 0): return rt.undefined_value
			if (value != 0):
				if (value.owner == rt): return value
				js_runtime_fail(rt, 2, c"host getter returned a foreign value")
				return rt.undefined_value
		js_value* property = js_runtime_property(current, key)
		if (property != 0):
			if (property.accessor == 0): return property.value
			if (property.getter == 0): return rt.undefined_value
			if (js_runtime_property_enter(rt) == 0): return rt.undefined_value
			list[js_value*] arguments = new list[js_value*]
			js_value* value = js_runtime_call_receiver(rt, property.getter, receiver, arguments)
			__w_list_free(cast(__w_list*, arguments))
			js_runtime_property_leave(rt)
			return value
		current = current.prototype
	return rt.undefined_value


js_value* js_runtime_member_read(js_runtime* rt, js_value* object, js_text* key):
	if (key == 0 || object == 0 || object.owner != rt): return rt.undefined_value
	if (js_runtime_key_is(key, c"length")):
		if (object.kind == 6): return js_runtime_number(rt, cast(float64, object.array_length))
		if (object.kind == 4): return js_runtime_number(rt, cast(float64, object.text.units.length))
	if (object.kind == 4):
		int index = js_runtime_array_index(key)
		if (index >= 0 && index < object.text.units.length):
			js_text* unit = js_text_new()
			unit.units.push(object.text.units[index])
			js_value* value = js_runtime_string(rt, unit)
			js_text_free(unit)
			return value
		return rt.undefined_value
	if (object.kind == 2 || object.kind == 3): return rt.undefined_value
	if (object.kind < 5 || object.kind > 9):
		js_runtime_fail(rt, 2, c"property receiver is not an object")
		return rt.undefined_value
	return js_runtime_read_receiver(rt, object, key, object)


int js_runtime_write_receiver(js_runtime* rt, js_value* object, js_text* key, js_value* value, js_value* receiver):
	if (object == 0 || object.owner != rt || value == 0 || value.owner != rt || receiver == 0 || receiver.owner != rt || key == 0): return 0
	js_value* current = object
	int depth = 0
	while (current != 0):
		depth = depth + 1
		if (depth > rt.max_depth):
			js_runtime_fail(rt, 5, c"JavaScript prototype depth limit")
			return 0
		if (current.host_set != 0):
			if (js_runtime_property_enter(rt) == 0): return 0
			js_host_setter* callback = cast(js_host_setter*, current.host_set)
			int handled = callback(rt, current.host_context, receiver, key, value)
			js_runtime_property_leave(rt)
			if (rt.completion.status != 0): return 0
			if (handled > 0): return 1
			if (handled < 0):
				js_runtime_fail(rt, 2, c"host property write rejected")
				return 0
		js_value* property = js_runtime_property(current, key)
		if (property != 0):
			if (property.accessor):
				if (property.setter == 0): return 0
				if (js_runtime_property_enter(rt) == 0): return 0
				list[js_value*] arguments = new list[js_value*]
				arguments.push(value)
				js_runtime_call_receiver(rt, property.setter, receiver, arguments)
				__w_list_free(cast(__w_list*, arguments))
				js_runtime_property_leave(rt)
				return rt.completion.status == 0
			if (property.writable == 0): return 0
			break
		current = current.prototype
	js_value* own = js_runtime_property(receiver, key)
	if (own != 0 && (own.accessor || own.writable == 0)): return 0
	return js_runtime_put(rt, receiver, key, value)


int js_runtime_member_write(js_runtime* rt, js_value* object, js_text* key, js_value* value):
	if (key == 0 || object == 0 || value == 0 || object.owner != rt || value.owner != rt): return 0
	if (object.kind == 8): return js_runtime_put(rt, object, key, value)
	if (js_runtime_object(object) == 0):
		js_runtime_fail(rt, 2, c"property receiver is not mutable")
		return 0
	int index = -1
	if (object.kind == 6):
		if (js_runtime_key_is(key, c"length")):
			js_runtime_fail(rt, 6, c"array length assignment is outside the runtime subset")
			return 0
		index = js_runtime_array_index(key)
		if (index >= rt.max_properties):
			js_runtime_fail(rt, 5, c"JavaScript array length limit")
			return 0
	int ok = js_runtime_write_receiver(rt, object, key, value, object)
	if (ok && index >= object.array_length): object.array_length = index + 1
	return ok


js_value* js_runtime_assign(js_runtime* rt, js_node* node, js_value* env):
	js_node* target = node.children[0]
	js_value* binding = 0
	js_value* object = 0
	js_text* key = 0
	js_value* old = rt.undefined_value
	int update = js_kind(node, c"assignment") == 0
	int read = update || strcmp(node.text, c"=") != 0
	if (js_kind(target, c"identifier")):
		binding = js_runtime_binding(env, target.text)
		if (binding == 0 || binding.initialized == 0): js_runtime_fail(rt, 2, c"uninitialized or missing binding")
		else: old = binding.value
	else:
		object = js_runtime_eval_node(rt, target.children[0], env)
		key = js_runtime_member_key(rt, target, env)
		if (read): old = js_runtime_member_read(rt, object, key)
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0):
		if (update):
			char* op = c"+"
			if (strcmp(node.text, c"--") == 0): op = c"-"
			value = js_runtime_binary(rt, op, old, js_runtime_number(rt, 1.0))
		else:
			value = js_runtime_eval_node(rt, node.children[1], env)
			if (read && rt.completion.status == 0):
				char[2] op
				op[0] = node.text[0]
				op[1] = 0
				value = js_runtime_binary(rt, op, old, value)
	if (rt.completion.status == 0):
		if (binding != 0):
			if (binding.immutable): js_runtime_fail(rt, 2, c"assignment to constant binding")
			else: binding.value = value
		else: js_runtime_member_write(rt, object, key, value)
	js_text_free(key)
	if (js_kind(node, c"update_postfix")): return old
	return value


js_value* js_runtime_call_receiver(js_runtime* rt, js_value* callable, js_value* receiver, list[js_value*] args):
	if (callable.kind == 9):
		js_value* value = rt.undefined_value
		if (callable.host_receiver):
			js_host_receiver_function* callback = cast(js_host_receiver_function*, callable.host)
			value = callback(rt, callable.host_context, receiver, args)
		else:
			js_host_function* callback = cast(js_host_function*, callable.host)
			value = callback(rt, args)
		if (value == 0 || value.owner != rt):
			js_runtime_fail(rt, 2, c"host returned a foreign or null value")
			return rt.undefined_value
		return value
	if (callable.kind != 7):
		js_runtime_fail(rt, 2, c"value is not callable")
		return rt.undefined_value
	js_value* env = js_runtime_environment(rt, callable.parent)
	if (env != rt.undefined_value): env.this_value = receiver
	js_node* parameters = callable.code.children[0]
	for i in range(parameters.children.length):
		js_value* argument = rt.undefined_value
		if (i < args.length): argument = args[i]
		js_runtime_set(rt, env, parameters.children[i].text, argument)
	js_runtime_eval_node(rt, callable.code.children[1], env)
	if (rt.completion.status == 1):
		rt.completion.status = 0
		return rt.completion.value
	return rt.undefined_value


# The initializer and each iteration have distinct let environments. In
# particular a closure created by the initializer cannot observe body writes.
js_value* js_runtime_iteration(js_runtime* rt, js_value* scope):
	js_value* next = js_runtime_environment(rt, scope.parent)
	for i in range(scope.properties.length):
		if (rt.completion.status != 0): break
		js_value* binding = scope.properties[i]
		js_runtime_put(rt, next, binding.key, binding.value)
		js_value* copy = js_runtime_property(next, binding.key)
		if (copy != 0):
			copy.immutable = binding.immutable
			copy.initialized = binding.initialized
	return next


js_value* js_runtime_loop(js_runtime* rt, js_node* node, js_value* env):
	int is_for = js_kind(node, c"for")
	int is_do = js_kind(node, c"do_while")
	js_node* condition = node.children[0]
	js_node* body = node.children[1]
	js_value* scope = env
	int lexical = 0
	if (is_for):
		condition = node.children[1]
		body = node.children[3]
		js_node* init = node.children[0]
		if (js_kind(init, c"variable")):
			lexical = strcmp(init.text, c"let") == 0
			scope = js_runtime_environment(rt, env)
			# A temporary borrowed wrapper drives the ordinary TDZ declaration pass.
			js_node* wrapper = js_node_new(c"block", c"")
			js_node_add(wrapper, init)
			js_runtime_declare(rt, wrapper, scope)
			wrapper.children.pop()
			js_node_free(wrapper)
		js_runtime_eval_node(rt, init, scope)
		if (lexical && rt.completion.status == 0): scope = js_runtime_iteration(rt, scope)
	int first = 1
	js_value* result = rt.undefined_value
	while (rt.completion.status == 0):
		if ((is_do == 0 || first == 0) && js_kind(condition, c"empty") == 0):
			js_value* test = js_runtime_eval_node(rt, condition, scope)
			if (rt.completion.status != 0 || js_runtime_truth(test) == 0): break
		first = 0
		js_value* body_value = js_runtime_eval_node(rt, body, scope)
		if (rt.empty == 0): result = body_value
		if (rt.completion.status == 3):
			rt.completion.status = 0
			break
		if (rt.completion.status == 4): rt.completion.status = 0
		if (rt.completion.status != 0): break
		if (is_for):
			if (lexical): scope = js_runtime_iteration(rt, scope)
			js_runtime_eval_node(rt, node.children[2], scope)
	rt.empty = 0
	return result


js_value* js_runtime_eval_impl(js_runtime* rt, js_node* node, js_value* env):
	int count = node.children.length
	if (js_kind(node, c"try")):
		js_value* value = js_runtime_eval_node(rt, node.children[0], env)
		js_node* handler = node.children[1]
		if (rt.completion.status == 2 && js_kind(handler, c"catch")):
			js_value* exception = rt.completion.value
			rt.completion.status = 0
			rt.completion.message = c""
			js_value* scope = js_runtime_environment(rt, env)
			if (strlen(handler.text) != 0): js_runtime_set(rt, scope, handler.text, exception)
			value = js_runtime_eval_node(rt, handler.children[0], scope)
		# Resource/unsupported failures are terminal, not catchable exceptions.
		if (rt.completion.status < 5 && js_kind(node.children[2], c"empty") == 0):
			int saved_status = rt.completion.status
			js_value* saved_value = rt.completion.value
			char* saved_message = rt.completion.message
			rt.completion.status = 0
			js_runtime_eval_node(rt, node.children[2], env)
			if (rt.completion.status == 0):
				rt.completion.status = saved_status
				rt.completion.value = saved_value
				rt.completion.message = saved_message
		rt.empty = 0
		return value
	if (js_kind(node, c"empty")):
		rt.empty = 1
		return rt.undefined_value
	if (js_kind(node, c"number")):
		int consumed = 0
		float64 number = parse_float64(node.text, &consumed)
		if (consumed != strlen(node.text)):
			js_runtime_fail(rt, 6, c"only decimal number literals are in the runtime subset")
			return rt.undefined_value
		return js_runtime_number(rt, number)
	if (js_kind(node, c"string") || js_kind(node, c"string_non_directive")):
		js_text* text = js_runtime_key(node.text)
		js_value* value = js_runtime_string(rt, text)
		js_text_free(text)
		return value
	if (js_kind(node, c"string_utf16")): return js_runtime_string(rt, node.string_units)
	if (js_kind(node, c"literal")):
		if (strcmp(node.text, c"this") == 0):
			js_value* scope = env
			while (scope != 0):
				if (scope.this_value != 0): return scope.this_value
				scope = scope.parent
			return rt.undefined_value
		if (strcmp(node.text, c"null") == 0): return js_runtime_alloc(rt, 1)
		return js_runtime_boolean(rt, strcmp(node.text, c"true") == 0)
	if (js_kind(node, c"identifier")):
		js_value* property = js_runtime_binding(env, node.text)
		if (property == 0 || property.initialized == 0):
			js_runtime_fail(rt, 2, c"uninitialized or missing binding")
			return rt.undefined_value
		return property.value
	if (js_kind(node, c"function_expression")): return js_runtime_function(rt, node, env)
	if (js_kind(node, c"function")):
		rt.empty = 1
		return rt.undefined_value
	if (js_kind(node, c"program") || js_kind(node, c"block")):
		js_value* scope = env
		if (js_kind(node, c"block")): scope = js_runtime_environment(rt, env)
		js_runtime_declare(rt, node, scope)
		js_value* result = rt.undefined_value
		int empty = 1
		for i in range(count):
			if (rt.completion.status != 0): break
			js_value* value = js_runtime_eval_node(rt, node.children[i], scope)
			if (rt.empty == 0):
				result = value
				empty = 0
		rt.empty = empty
		return result
	if (js_kind(node, c"variable")):
		for i in range(count):
			js_node* declaration = node.children[i]
			js_value* value = rt.undefined_value
			if (declaration.children.length == 2): value = js_runtime_eval_node(rt, declaration.children[1], env)
			if (rt.completion.status != 0): break
			js_value* binding = js_runtime_binding(env, declaration.children[0].text)
			if (binding == 0):
				js_runtime_fail(rt, 6, c"lexical declaration requires a block")
				break
			binding.value = value
			binding.initialized = 1
		rt.empty = 1
		return rt.undefined_value
	if (js_kind(node, c"expression_statement")):
		js_value* value = js_runtime_eval_node(rt, node.children[0], env)
		rt.empty = 0
		return value
	if (js_kind(node, c"return") || js_kind(node, c"throw")):
		js_value* value = rt.undefined_value
		if (count > 0): value = js_runtime_eval_node(rt, node.children[0], env)
		if (rt.completion.status == 0):
			rt.completion.status = 1
			if (js_kind(node, c"throw")):
				rt.completion.status = 2
				rt.completion.message = c"JavaScript exception"
			rt.completion.value = value
		return value
	if (js_kind(node, c"break") || js_kind(node, c"continue")):
		rt.completion.status = 3
		if (js_kind(node, c"continue")): rt.completion.status = 4
		rt.empty = 1
		return rt.undefined_value
	if (js_kind(node, c"if") || js_kind(node, c"conditional")):
		js_value* condition = js_runtime_eval_node(rt, node.children[0], env)
		if (rt.completion.status != 0): return rt.undefined_value
		js_value* value = rt.undefined_value
		if (js_runtime_truth(condition)): value = js_runtime_eval_node(rt, node.children[1], env)
		else if (count == 3): value = js_runtime_eval_node(rt, node.children[2], env)
		rt.empty = 0
		return value
	if (js_kind(node, c"while") || js_kind(node, c"do_while") || js_kind(node, c"for")): return js_runtime_loop(rt, node, env)
	if (js_kind(node, c"assignment") || js_kind(node, c"update_prefix") || js_kind(node, c"update_postfix")): return js_runtime_assign(rt, node, env)
	if (js_kind(node, c"binary")):
		js_value* left = js_runtime_eval_node(rt, node.children[0], env)
		if (rt.completion.status != 0): return rt.undefined_value
		if (strcmp(node.text, c"&&") == 0 && js_runtime_truth(left) == 0): return left
		if (strcmp(node.text, c"||") == 0 && js_runtime_truth(left)): return left
		if (strcmp(node.text, c"??") == 0 && left.kind != 0 && left.kind != 1): return left
		js_value* right = js_runtime_eval_node(rt, node.children[1], env)
		if (rt.completion.status != 0): return rt.undefined_value
		if (strcmp(node.text, c"&&") == 0 || strcmp(node.text, c"||") == 0 || strcmp(node.text, c"??") == 0 || strcmp(node.text, c",") == 0): return right
		return js_runtime_binary(rt, node.text, left, right)
	if (js_kind(node, c"unary")):
		js_value* value = js_runtime_eval_node(rt, node.children[0], env)
		if (rt.completion.status != 0): return rt.undefined_value
		if (strcmp(node.text, c"!") == 0): return js_runtime_boolean(rt, js_runtime_truth(value) == 0)
		if (strcmp(node.text, c"void") == 0): return rt.undefined_value
		if (value.kind != 3):
			js_runtime_fail(rt, 6, c"implicit numeric conversion is outside the runtime subset")
			return rt.undefined_value
		if (strcmp(node.text, c"-") == 0): return js_runtime_number(rt, -value.number)
		return value
	if (js_kind(node, c"member") || js_kind(node, c"computed_member")):
		js_value* object = js_runtime_eval_node(rt, node.children[0], env)
		js_text* key = js_runtime_member_key(rt, node, env)
		js_value* value = js_runtime_member_read(rt, object, key)
		js_text_free(key)
		return value
	if (js_kind(node, c"array") || js_kind(node, c"object")):
		int kind = 5
		if (js_kind(node, c"array")): kind = 6
		js_value* object = js_runtime_alloc(rt, kind)
		for i in range(count):
			if (rt.completion.status != 0): break
			js_text* key = 0
			js_value* value = rt.undefined_value
			if (kind == 6):
				char* index = itoa(i)
				key = js_runtime_key(index)
				free(index)
				value = js_runtime_eval_node(rt, node.children[i], env)
			else:
				js_node* property = node.children[i]
				key = js_runtime_key(property.text)
				if (js_kind(property, c"property_shorthand")):
					js_value* binding = js_runtime_binding(env, property.text)
					if (binding == 0 || binding.initialized == 0): js_runtime_fail(rt, 2, c"uninitialized or missing binding")
					else: value = binding.value
				else: value = js_runtime_eval_node(rt, property.children[0], env)
			if (rt.completion.status == 0): js_runtime_member_write(rt, object, key, value)
			js_text_free(key)
		return object
	if (js_kind(node, c"call")):
		js_node* target = node.children[0]
		js_value* receiver = rt.undefined_value
		js_value* callable = rt.undefined_value
		if (js_kind(target, c"member") || js_kind(target, c"computed_member")):
			receiver = js_runtime_eval_node(rt, target.children[0], env)
			if (rt.completion.status == 0):
				js_text* key = js_runtime_member_key(rt, target, env)
				callable = js_runtime_member_read(rt, receiver, key)
				js_text_free(key)
		else: callable = js_runtime_eval_node(rt, target, env)
		list[js_value*] arguments = new list[js_value*]
		for i in range(1, count):
			if (rt.completion.status != 0): break
			arguments.push(js_runtime_eval_node(rt, node.children[i], env))
		js_value* result = rt.undefined_value
		if (rt.completion.status == 0): result = js_runtime_call_receiver(rt, callable, receiver, arguments)
		__w_list_free(cast(__w_list*, arguments))
		return result
	js_runtime_fail(rt, 6, c"unsupported AST node")
	return rt.undefined_value


js_value* js_runtime_eval_node(js_runtime* rt, js_node* node, js_value* env):
	if (rt.completion.status != 0): return rt.undefined_value
	if (rt.remaining <= 0 || rt.depth >= rt.max_depth):
		js_runtime_fail(rt, 5, c"JavaScript execution limit")
		return rt.undefined_value
	rt.remaining = rt.remaining - 1
	rt.completion.steps = rt.completion.steps + 1
	rt.depth = rt.depth + 1
	rt.empty = 0
	js_value* value = js_runtime_eval_impl(rt, node, env)
	rt.depth = rt.depth - 1
	return value


# Shape validity is established by lowering. Preflight rejects unsupported
# syntax before execution, so unsupported syntax cannot leave partial effects.
int js_runtime_supported(js_node* node):
	char* kind = node.kind
	int supported = js_kind(node, c"try") || js_kind(node, c"catch") || js_kind(node, c"program") || js_kind(node, c"block") || js_kind(node, c"empty") || js_kind(node, c"number") || js_kind(node, c"string") || js_kind(node, c"string_utf16") || js_kind(node, c"string_non_directive") || js_kind(node, c"identifier") || js_kind(node, c"literal") || js_kind(node, c"function") || js_kind(node, c"function_expression") || js_kind(node, c"parameters") || js_kind(node, c"variable") || js_kind(node, c"declarator") || js_kind(node, c"expression_statement") || js_kind(node, c"return") || js_kind(node, c"throw") || js_kind(node, c"break") || js_kind(node, c"continue") || js_kind(node, c"if") || js_kind(node, c"conditional") || js_kind(node, c"while") || js_kind(node, c"do_while") || js_kind(node, c"for") || js_kind(node, c"assignment") || js_kind(node, c"update_prefix") || js_kind(node, c"update_postfix") || js_kind(node, c"binary") || js_kind(node, c"unary") || js_kind(node, c"member") || js_kind(node, c"computed_member") || js_kind(node, c"array") || js_kind(node, c"object") || js_kind(node, c"property") || js_kind(node, c"property_shorthand") || js_kind(node, c"call")
	if (supported == 0): return 0
	if (strcmp(kind, c"number") == 0):
		int consumed = 0
		parse_float64(node.text, &consumed)
		if (consumed != strlen(node.text)): return 0
		if (node.text[0] == '0' && node.text[1] >= '0' && node.text[1] <= '9'): return 0
	if (strcmp(kind, c"variable") == 0 && strcmp(node.text, c"var") == 0): return 0
	if (strcmp(kind, c"property") == 0 && strcmp(node.text, c"__proto__") == 0): return 0
	if (strcmp(kind, c"unary") == 0 && strcmp(node.text, c"!") != 0 && strcmp(node.text, c"+") != 0 && strcmp(node.text, c"-") != 0 && strcmp(node.text, c"void") != 0): return 0
	if (strcmp(kind, c"assignment") == 0 && strcmp(node.text, c"=") != 0 && strcmp(node.text, c"+=") != 0 && strcmp(node.text, c"-=") != 0 && strcmp(node.text, c"*=") != 0 && strcmp(node.text, c"/=") != 0): return 0
	if (strcmp(kind, c"binary") == 0):
		char* op = node.text
		if (strcmp(op, c"+") != 0 && strcmp(op, c"-") != 0 && strcmp(op, c"*") != 0 && strcmp(op, c"/") != 0 && strcmp(op, c"===") != 0 && strcmp(op, c"!==") != 0 && strcmp(op, c"<") != 0 && strcmp(op, c">") != 0 && strcmp(op, c"<=") != 0 && strcmp(op, c">=") != 0 && strcmp(op, c"&&") != 0 && strcmp(op, c"||") != 0 && strcmp(op, c"??") != 0 && strcmp(op, c",") != 0): return 0
	for i in range(node.children.length):
		if (js_runtime_supported(node.children[i]) == 0): return 0
	return 1


# Both script evaluation and host invocation replace the instance completion.
# Reentrant entry returns null without disturbing the active operation.
int js_runtime_begin(js_runtime* rt, int budget):
	if (rt.running): return 0
	rt.completion.status = 0
	rt.completion.value = rt.undefined_value
	rt.completion.message = c""
	rt.completion.steps = 0
	rt.depth = 0
	rt.remaining = budget
	return 1


# Call a borrowed same-instance function with borrowed same-instance arguments.
# The host roots retained functions/arguments across intervening collection.
# Invocation consumes one step plus AST visits, and retains no new script AST.
js_completion* js_runtime_invoke_receiver(js_runtime* rt, js_value* callable, js_value* receiver, list[js_value*] arguments, int budget):
	if (js_runtime_begin(rt, budget) == 0): return 0
	if (budget <= 0 || rt.max_depth <= 0):
		js_runtime_fail(rt, 5, c"JavaScript execution limit")
		return rt.completion
	if (receiver == 0 || receiver.owner != rt):
		js_runtime_fail(rt, 2, c"foreign or null receiver")
		return rt.completion
	if (callable == 0 || callable.owner != rt):
		js_runtime_fail(rt, 2, c"foreign or null callable")
		return rt.completion
	if (arguments == 0):
		js_runtime_fail(rt, 2, c"null argument list")
		return rt.completion
	if (arguments.length > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript host argument count limit")
		return rt.completion
	for i in range(arguments.length):
		js_value* argument = arguments[i]
		if (argument == 0 || argument.owner != rt):
			js_runtime_fail(rt, 2, c"foreign or null argument")
			return rt.completion
	rt.remaining = budget - 1
	rt.completion.steps = 1
	rt.depth = 1
	rt.running = 1
	js_value* value = js_runtime_call_receiver(rt, callable, receiver, arguments)
	rt.running = 0
	rt.depth = 0
	if (rt.completion.status == 0): rt.completion.value = value
	return rt.completion


# Returns the instance-owned completion, overwritten by the next evaluation
# or invocation. Limit aborts return synchronously; they are not resumable.
# Side effects already performed remain visible, as with a thrown exception.
js_completion* js_runtime_eval(js_runtime* rt, char* source, int length, int budget):
	if (js_runtime_begin(rt, budget) == 0): return 0
	if (budget <= 0 || length < 0 || length > rt.max_source_bytes || rt.scripts.length >= rt.max_scripts):
		js_runtime_fail(rt, 5, c"JavaScript input or execution limit")
		return rt.completion
	pg_parse_result* parsed = js_parse_with_limits(source, length, c"<embedded JavaScript>", 0, rt.parse_limits)
	js_node* tree = js_lower(parsed)
	if (tree == 0):
		if (parsed.stream.resource_failed): js_runtime_fail(rt, 5, c"JavaScript parser resource limit")
		else: js_runtime_fail(rt, 6, c"JavaScript parse or AST lowering failed")
		pg_parse_result_free(parsed)
		return rt.completion
	pg_parse_result_free(parsed)
	if (js_runtime_supported(tree) == 0):
		js_node_free(tree)
		js_runtime_fail(rt, 6, c"syntax outside the JavaScript runtime subset")
		return rt.completion
	rt.scripts.push(tree)
	rt.running = 1
	js_value* value = js_runtime_eval_node(rt, tree, rt.global)
	rt.running = 0
	if (rt.completion.status == 0): rt.completion.value = value
	return rt.completion


js_value* js_runtime_call(js_runtime* rt, js_value* callable, list[js_value*] arguments):
	return js_runtime_call_receiver(rt, callable, rt.undefined_value, arguments)


js_completion* js_runtime_invoke(js_runtime* rt, js_value* callable, list[js_value*] arguments, int budget):
	return js_runtime_invoke_receiver(rt, callable, rt.undefined_value, arguments, budget)
