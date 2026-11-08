/*
Generators, async functions, async generators, for await and yield*
delegation for the bounded interpreter (reardan/w#906).

The evaluator is resumable: a suspension (yield, or await) is completion
status 7, which unwinds like any other abrupt completion. Each construct on
the way out that has local progress (a block's statement index, a call's
evaluated arguments, a loop's iteration scope, ...) records a frame: a
kind 12 record holding the node, a phase, the values computed so far and,
for some constructs, an environment or key. Frames are pushed innermost
first onto the coroutine's activation record. Resuming evaluates the body
again; every construct that saved a frame pops it on entry, restores its
state and re-enters the child that suspended, until the innermost frame
(the yield or await itself) takes the delivered resumption. Frames, the
activation record and its environment are ordinary heap values: they count
against max_values, are traced by collection while the generator or the
awaited promise is reachable, and need no native stack across suspensions.

See docs/projects/javascript.md ("Generators and async functions") for the
semantic and resource contract.
*/
import libs.extras.javascript.runtime


# Activation kinds (coroutine_kind of a kind 12 record). Kinds 10 and 11
# brand built-in iterator objects that are not activations.
const int JS_CO_GENERATOR = 1
const int JS_CO_ASYNC = 2
const int JS_CO_ASYNC_GENERATOR = 3
const int JS_CO_LIST_ITERATOR = 10
const int JS_CO_ASYNC_FROM_SYNC = 11

# Activation states (coroutine_state).
const int JS_CO_START = 0
const int JS_CO_SUSPENDED = 1
const int JS_CO_EXECUTING = 2
const int JS_CO_COMPLETED = 3
const int JS_CO_AWAITING_RETURN = 4

# Pending suspension kinds (rt.suspend_kind while status is 7).
const int JS_SUSPEND_YIELD = 1
const int JS_SUSPEND_AWAIT = 2
const int JS_SUSPEND_YIELD_RAW = 3

# Resumption modes (rt.resume_mode): a value, a throw or a return.
const int JS_RESUME_NEXT = 0
const int JS_RESUME_THROW = 1
const int JS_RESUME_RETURN = 2


int js_coroutine_kind_of(js_node* node):
	if (js_kind(node, c"generator_function") || js_kind(node, c"generator_function_expression")): return JS_CO_GENERATOR
	if (js_kind(node, c"async_function") || js_kind(node, c"async_function_expression") || js_kind(node, c"async_arrow")): return JS_CO_ASYNC
	if (js_kind(node, c"async_generator_function") || js_kind(node, c"async_generator_function_expression")): return JS_CO_ASYNC_GENERATOR
	return 0


int js_runtime_arrow_node(js_node* node):
	return js_kind(node, c"arrow") || js_kind(node, c"async_arrow")


# Every node that starts a new function body (a var-scope boundary).
int js_runtime_function_node(js_node* node):
	return js_kind(node, c"function") || js_kind(node, c"function_expression") || js_runtime_arrow_node(node) || js_coroutine_kind_of(node) != 0


int js_runtime_function_declaration(js_node* node):
	return js_kind(node, c"function") || js_kind(node, c"generator_function") || js_kind(node, c"async_function") || js_kind(node, c"async_generator_function")


# Frames ---------------------------------------------------------------

# The frame node owns no state; frame.array_length is the phase, values are
# in reactions and up to four ints use otherwise unused fields.
js_value* js_frame_get(js_value* frame, int index):
	if (frame == 0 || index >= frame.reactions.length): return 0
	return frame.reactions[index]


void js_frame_put(js_value* frame, js_value* value):
	frame.reactions.push(value)


int js_frame_int(js_value* frame, int slot):
	if (slot == 0): return frame.host
	if (slot == 1): return frame.binary_offset
	if (slot == 2): return frame.binary_length
	return frame.bigint_bits


void js_frame_set_int(js_value* frame, int slot, int value):
	if (slot == 0): frame.host = value
	else if (slot == 1): frame.binary_offset = value
	else if (slot == 2): frame.binary_length = value
	else: frame.bigint_bits = value


# While resuming, pops and returns node's frame (0 when evaluating afresh).
# Popping the innermost frame ends the resumption.
js_value* js_frame_resume(js_runtime* rt, js_node* node):
	if (rt.resuming == 0 || rt.coroutine == 0): return 0
	list[js_value*] frames = rt.coroutine.reactions
	if (frames.length == 0 || frames[frames.length - 1].code != node):
		rt.resuming = 0
		js_runtime_fail(rt, 6, c"generator resumption lost its frame")
		return 0
	js_value* frame = frames.pop()
	if (frames.length == 0): rt.resuming = 0
	return frame


# Records node's frame when the active completion is a suspension; returns
# it for the caller to fill, else 0. A full heap turns the suspension into
# a limit abort.
js_value* js_frame_save(js_runtime* rt, js_node* node, int phase):
	if (rt.completion.status != 7): return 0
	js_value* frame = 0
	if (rt.heap.length < rt.max_values): frame = js_runtime_alloc(rt, 12)
	if (frame == 0 || frame == rt.undefined_value || rt.coroutine == 0):
		rt.completion.status = 5
		rt.completion.message = c"JavaScript heap value limit"
		rt.completion.value = rt.undefined_value
		return 0
	frame.code = node
	frame.array_length = phase
	frame.reactions = new list[js_value*]
	rt.coroutine.reactions.push(frame)
	return frame


# The resumption delivered to the innermost frame: a value is returned; a
# throw (or promise rejection) and a return become abrupt completions.
js_value* js_coroutine_received(js_runtime* rt):
	js_value* value = rt.resume_value
	if (value == 0): value = rt.undefined_value
	rt.resume_value = 0
	int mode = rt.resume_mode
	rt.resume_mode = JS_RESUME_NEXT
	if (mode == JS_RESUME_THROW):
		rt.completion.status = 2
		rt.completion.value = value
		rt.completion.message = c"JavaScript exception"
		return rt.undefined_value
	if (mode == JS_RESUME_RETURN):
		rt.completion.status = 1
		rt.completion.value = value
		return rt.undefined_value
	return value


void js_coroutine_suspend(js_runtime* rt, int kind, js_value* value):
	rt.completion.status = 7
	rt.completion.value = value
	rt.suspend_kind = kind


void js_runtime_mark_coroutine_roots(js_runtime* rt, list[js_value*] pending):
	js_runtime_mark(pending, rt.coroutine)
	js_runtime_mark(pending, rt.resume_value)
	js_runtime_mark(pending, rt.iterator_prototype)
	js_runtime_mark(pending, rt.async_iterator_prototype)
	js_runtime_mark(pending, rt.generator_prototype)
	js_runtime_mark(pending, rt.async_generator_prototype)
	js_runtime_mark(pending, rt.generator_function_prototype)
	js_runtime_mark(pending, rt.async_function_prototype)
	js_runtime_mark(pending, rt.async_generator_function_prototype)
	js_runtime_mark(pending, rt.async_from_sync_prototype)
	js_runtime_mark(pending, rt.list_iterator_prototype)


# The function environment of env (the nearest one with function code).
js_value* js_coroutine_function_env(js_value* env):
	while (env != 0 && env.code == 0): env = env.parent
	return env


int js_coroutine_async_generator_code(js_value* env):
	js_value* scope = js_coroutine_function_env(env)
	return scope != 0 && js_coroutine_kind_of(scope.code) == JS_CO_ASYNC_GENERATOR


# Preflight ------------------------------------------------------------

# Constructs whose evaluation saves and restores frames when a descendant
# suspends. Structural children (declarators, catch, case, spread, property
# parts and template text) are resumed by their parent construct.
int js_coroutine_resumable(js_node* node):
	char* kinds = c"yield await block variable declarator expression_statement return throw label if conditional while do_while for for_of for_await_of try catch switch case default binary unary assignment member computed_member call construct array object spread property computed_property computed_key template class class_expression method static_method"
	int found = 0
	int start = 0
	int length = strlen(node.kind)
	for i in range(strlen(kinds) + 1):
		if (kinds[i] != ' ' && kinds[i] != 0): continue
		if (i - start == length):
			int same = 1
			for j in range(length):
				if (kinds[start + j] != node.kind[j]): same = 0
			if (same): found = 1
		start = i + 1
	if (found == 0): return 0
	# The super forms and update targets are not resumable.
	if ((js_kind(node, c"member") || js_kind(node, c"computed_member") || js_kind(node, c"call")) && js_kind(node.children[0], c"super")): return 0
	if (js_kind(node, c"call") && (js_kind(node.children[0], c"member") || js_kind(node.children[0], c"computed_member")) && js_kind(node.children[0].children[0], c"super")): return 0
	if (js_kind(node, c"call") && js_kind(node.children[0], c"optional_chain")): return 0
	if (js_kind(node, c"assignment") && js_kind(node.children[0], c"identifier") == 0 && js_kind(node.children[0], c"member") == 0 && js_kind(node.children[0], c"computed_member") == 0): return 0
	if (js_kind(node, c"assignment") && js_kind(node.children[0], c"identifier") == 0 && js_kind(node.children[0].children[0], c"super")): return 0
	return 1


# Returns whether node (within one function body) can suspend; clears *ok
# when a suspending node is not resumable.
int js_coroutine_scan(js_node* node, int* ok):
	if (js_runtime_function_node(node)): return 0
	int suspends = js_kind(node, c"yield") || js_kind(node, c"await") || js_kind(node, c"for_await_of")
	for i in range(node.children.length):
		if (js_coroutine_scan(node.children[i], ok)): suspends = 1
	# A variable declarator suspends only in its initializer.
	if (suspends && js_kind(node, c"declarator") && node.children.length == 2):
		int pattern_ok = 1
		if (js_coroutine_scan(node.children[0], &pattern_ok)): *ok = 0
	if (suspends && js_coroutine_resumable(node) == 0): *ok = 0
	return suspends


# A generator or async function is executable when every suspension point
# sits inside resumable constructs. Parameters cannot contain yield/await.
int js_coroutine_supported(js_node* node):
	int ok = 1
	for i in range(node.children.length): js_coroutine_scan(node.children[i], &ok)
	return ok


# Function objects -------------------------------------------------------

# Generator and async closures inherit %GeneratorFunction.prototype% (and
# the async equivalents); generator functions own a prototype object.
void js_runtime_coroutine_function(js_runtime* rt, js_value* callable):
	int kind = js_coroutine_kind_of(callable.code)
	if (kind == 0): return
	js_value* parent = rt.async_function_prototype
	js_value* instances = 0
	if (kind == JS_CO_GENERATOR):
		parent = rt.generator_function_prototype
		instances = rt.generator_prototype
	if (kind == JS_CO_ASYNC_GENERATOR):
		parent = rt.async_generator_function_prototype
		instances = rt.async_generator_prototype
	if (parent != 0): callable.prototype = parent
	if (instances == 0): return
	js_value* prototype = js_runtime_alloc(rt, 5)
	if (prototype == rt.undefined_value): return
	prototype.prototype = instances
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, callable, key, prototype, 1, 0, 0)
	js_text_free(key)


# SetFunctionName for an object-literal generator/async method.
void js_runtime_coroutine_method_name(js_runtime* rt, js_value* callable, js_text* key):
	js_text* name = js_text_new()
	if (key.units.length == 1 && key.units[0] < 0):
		js_value* symbol = 0
		for i in range(rt.symbols.length):
			if (rt.symbols[i].text.units[0] == key.units[0]): symbol = rt.symbols[i]
		if (symbol != 0 && symbol.key != 0):
			name.units.push('[')
			for i in range(symbol.key.units.length): name.units.push(symbol.key.units[i])
			name.units.push(']')
	else:
		for i in range(key.units.length): name.units.push(key.units[i])
	js_value* value = js_runtime_string(rt, name)
	js_text_free(name)
	name = js_runtime_key(c"name")
	if (rt.completion.status == 0): js_runtime_define_data(rt, callable, name, value, 0, 0, 1)
	js_text_free(name)


# Activations ---------------------------------------------------------

void js_async_step(js_runtime* rt, js_value* record, int mode, js_value* value);


js_value* js_coroutine_record(js_runtime* rt, js_value* callable, js_value* env, int kind):
	js_value* record = js_runtime_alloc(rt, 12)
	if (record == rt.undefined_value): return 0
	record.code = callable.code
	record.parent = env
	record.function_object = callable
	record.reactions = new list[js_value*]
	record.coroutine_kind = kind
	record.coroutine_state = JS_CO_START
	if (kind == JS_CO_ASYNC_GENERATOR): record.coroutine_queue = new list[js_value*]
	return record


void js_coroutine_finish(js_value* record):
	record.coroutine_state = JS_CO_COMPLETED
	while (record.reactions.length > 0): record.reactions.pop()
	record.parent = 0


# Evaluates the body from its start, or from the saved frames with the
# resumption (mode, value). Leaves status 7 (suspended: rt.suspend_kind),
# 1 or 0 (returned; an expression-bodied arrow's value is returned), 2
# (thrown) or 5/6 (terminal). Any outcome but a suspension completes it.
js_value* js_coroutine_run(js_runtime* rt, js_value* record, int mode, js_value* value):
	js_value* saved_coroutine = rt.coroutine
	int saved_resuming = rt.resuming
	int saved_mode = rt.resume_mode
	js_value* saved_value = rt.resume_value
	js_runtime_label* saved_label = rt.label
	rt.coroutine = record
	rt.label = 0
	rt.suspend_kind = 0
	rt.resuming = record.reactions.length > 0
	rt.resume_mode = mode
	rt.resume_value = value
	record.coroutine_state = JS_CO_EXECUTING
	js_node* body = record.code.children[1]
	js_value* result = js_runtime_eval_node(rt, body, record.parent)
	rt.coroutine = saved_coroutine
	rt.resuming = saved_resuming
	rt.resume_mode = saved_mode
	rt.resume_value = saved_value
	rt.label = saved_label
	if (rt.completion.status == 7): record.coroutine_state = JS_CO_SUSPENDED
	else:
		js_coroutine_finish(record)
		if (rt.completion.status != 0 || js_kind(body, c"block")): result = rt.undefined_value
	return result


js_value* js_coroutine_take_value(js_runtime* rt):
	js_value* value = rt.completion.value
	rt.completion.status = 0
	rt.completion.message = c""
	rt.completion.value = rt.undefined_value
	return value


# Called after FunctionDeclarationInstantiation (call_code binds the
# parameters). Generators return their object; async functions start at
# once and return their promise, rejecting it for a parameter error.
js_value* js_coroutine_call(js_runtime* rt, js_value* callable, js_value* env):
	int kind = js_coroutine_kind_of(callable.code)
	if (kind == JS_CO_ASYNC):
		if (rt.completion.status != 0 && rt.completion.status != 2): return rt.undefined_value
		js_value* promise = js_runtime_promise_new(rt)
		if (rt.completion.status == 2):
			js_value* reason = js_coroutine_take_value(rt)
			js_runtime_promise_settle(rt, promise, reason, 1)
			return promise
		if (rt.completion.status != 0): return rt.undefined_value
		js_value* record = js_coroutine_record(rt, callable, env, kind)
		if (record == 0): return rt.undefined_value
		record.promise_result = promise
		js_async_step(rt, record, JS_RESUME_NEXT, rt.undefined_value)
		if (rt.completion.status != 0): return rt.undefined_value
		return promise
	if (rt.completion.status != 0): return rt.undefined_value
	# OrdinaryCreateFromConstructor(F, %GeneratorFunction.prototype.prototype%).
	js_value* prototype = js_runtime_prototype_object(rt, callable)
	if (rt.completion.status != 0): return rt.undefined_value
	if (prototype == 0 && kind == JS_CO_GENERATOR): prototype = rt.generator_prototype
	if (prototype == 0): prototype = rt.async_generator_prototype
	js_value* object = js_runtime_alloc(rt, 5)
	js_value* record = js_coroutine_record(rt, callable, env, kind)
	if (object == rt.undefined_value || record == 0): return rt.undefined_value
	object.prototype = prototype
	object.coroutine = record
	return object


# Generators -------------------------------------------------------------

js_value* js_generator_resume(js_runtime* rt, js_value* generator, int mode, js_value* value):
	js_value* record = generator.coroutine
	int state = record.coroutine_state
	if (state == JS_CO_EXECUTING): return js_runtime_type_error(rt, c"generator is already running")
	if (state == JS_CO_START && mode != JS_RESUME_NEXT):
		js_coroutine_finish(record)
		state = JS_CO_COMPLETED
	if (state == JS_CO_COMPLETED):
		if (mode == JS_RESUME_THROW):
			js_runtime_throw(rt, value)
			return rt.undefined_value
		if (mode == JS_RESUME_RETURN): return js_runtime_iter_result(rt, value, 1)
		return js_runtime_iter_result(rt, rt.undefined_value, 1)
	js_value* result = js_coroutine_run(rt, record, mode, value)
	int status = rt.completion.status
	if (status == 7):
		int raw = rt.suspend_kind == JS_SUSPEND_YIELD_RAW
		js_value* yielded = js_coroutine_take_value(rt)
		if (raw): return yielded
		return js_runtime_iter_result(rt, yielded, 0)
	if (status == 1): return js_runtime_iter_result(rt, js_coroutine_take_value(rt), 1)
	if (status == 0): return js_runtime_iter_result(rt, result, 1)
	return rt.undefined_value


int js_generator_brand(js_value* value, int kind):
	return js_runtime_object(value) && value.coroutine != 0 && value.coroutine.coroutine_kind == kind


# %GeneratorPrototype%.next (0), throw (1) and return (2).
js_value* js_generator_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	if (js_generator_brand(receiver, JS_CO_GENERATOR) == 0): return js_runtime_type_error(rt, c"Generator method called on an incompatible receiver")
	return js_generator_resume(rt, receiver, cast(int, context), value)


# Async functions --------------------------------------------------------

# PromiseResolve(%Promise%, value): a native promise whose constructor is
# %Promise% is used as is; anything else settles a new promise.
js_value* js_coroutine_promise_resolve(js_runtime* rt, js_value* value):
	if (value.promise_state != 0):
		js_text* key = js_runtime_key(c"constructor")
		js_value* constructor = js_runtime_member_read(rt, value, key)
		js_text_free(key)
		if (rt.completion.status != 0): return 0
		if (constructor == rt.promise_constructor): return value
	js_value* promise = js_runtime_promise_new(rt)
	if (rt.completion.status != 0): return 0
	js_runtime_promise_settle(rt, promise, value, 0)
	if (rt.completion.status != 0): return 0
	return promise


js_value* js_coroutine_fulfilled(void* runtime, void* context, js_value* receiver, list[js_value*] args);
js_value* js_coroutine_rejected(void* runtime, void* context, js_value* receiver, list[js_value*] args);


# The activation's resolve/reject reactions, created once. Host contexts are
# opaque to collection, so parent retains the record.
int js_coroutine_handlers(js_runtime* rt, js_value* record):
	if (record.getter != 0): return 1
	js_value* fulfilled = js_runtime_host_callable(rt, record, js_coroutine_fulfilled)
	js_value* rejected = js_runtime_host_callable(rt, record, js_coroutine_rejected)
	if (rt.completion.status != 0 || fulfilled == rt.undefined_value || rejected == rt.undefined_value): return 0
	fulfilled.parent = record
	rejected.parent = record
	record.getter = fulfilled
	record.setter = rejected
	return 1


# Await(value) for the running activation: subscribes it to the resolved
# promise and suspends. The caller saves its frame; the frame receives the
# fulfillment (or the rejection as a throw) through js_coroutine_received.
void js_coroutine_await(js_runtime* rt, js_value* value):
	if (rt.completion.status != 0): return
	js_value* record = rt.coroutine
	if (record == 0):
		js_runtime_fail(rt, 6, c"await outside an async function")
		return
	js_value* promise = js_coroutine_promise_resolve(rt, value)
	if (promise == 0 || js_coroutine_handlers(rt, record) == 0): return
	js_runtime_promise_reaction(rt, promise, 0, record.getter, record.setter)
	if (rt.completion.status != 0): return
	js_coroutine_suspend(rt, JS_SUSPEND_AWAIT, rt.undefined_value)


void js_async_gen_step(js_runtime* rt, js_value* record, int mode, js_value* value);
void js_async_gen_return_settled(js_runtime* rt, js_value* record, int rejected, js_value* value);


void js_async_step(js_runtime* rt, js_value* record, int mode, js_value* value):
	js_value* result = js_coroutine_run(rt, record, mode, value)
	int status = rt.completion.status
	if (status == 7):
		js_coroutine_take_value(rt)
		return
	if (status >= 5): return
	js_value* outcome = result
	if (status == 1 || status == 2): outcome = js_coroutine_take_value(rt)
	js_runtime_promise_settle(rt, record.promise_result, outcome, status == 2)


void js_coroutine_settled(js_runtime* rt, js_value* record, int rejected, js_value* value):
	int mode = JS_RESUME_NEXT
	if (rejected): mode = JS_RESUME_THROW
	if (record.coroutine_kind == JS_CO_ASYNC): js_async_step(rt, record, mode, value)
	else if (record.coroutine_state == JS_CO_AWAITING_RETURN): js_async_gen_return_settled(rt, record, rejected, value)
	else: js_async_gen_step(rt, record, mode, value)


js_value* js_coroutine_fulfilled(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_coroutine_settled(rt, cast(js_value*, context), 0, value)
	return rt.undefined_value


js_value* js_coroutine_rejected(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_coroutine_settled(rt, cast(js_value*, context), 1, value)
	return rt.undefined_value


js_value* js_coroutine_await_node(js_runtime* rt, js_node* node, js_value* env):
	# Frame phases: 0 operand, 1 awaiting its promise.
	js_value* frame = js_frame_resume(rt, node)
	if (frame != 0 && frame.array_length == 1): return js_coroutine_received(rt)
	js_value* value = js_runtime_eval_node(rt, node.children[0], env)
	if (js_frame_save(rt, node, 0) != 0 || rt.completion.status != 0): return rt.undefined_value
	js_coroutine_await(rt, value)
	js_frame_save(rt, node, 1)
	return rt.undefined_value


# Async generators -----------------------------------------------------

# A request is a kind 12 record: mode in array_length, value in parent and
# its promise in promise_result.
void js_async_gen_enqueue(js_runtime* rt, js_value* record, int mode, js_value* value, js_value* promise):
	js_value* request = js_runtime_alloc(rt, 12)
	if (request == rt.undefined_value): return
	request.array_length = mode
	request.parent = value
	request.promise_result = promise
	record.coroutine_queue.push(request)


js_value* js_async_gen_dequeue(js_value* record):
	list[js_value*] queue = record.coroutine_queue
	if (queue.length == 0): return 0
	js_value* request = queue[0]
	for i in range(1, queue.length): queue[i - 1] = queue[i]
	queue.pop()
	return request


# AsyncGeneratorCompleteStep: settles the oldest request's promise.
void js_async_gen_complete(js_runtime* rt, js_value* record, int rejected, js_value* value, int done):
	js_value* request = js_async_gen_dequeue(record)
	if (request == 0 || rt.completion.status != 0): return
	if (rejected): js_runtime_promise_settle(rt, request.promise_result, value, 1)
	else:
		js_value* result = js_runtime_iter_result(rt, value, done)
		if (rt.completion.status == 0): js_runtime_promise_settle(rt, request.promise_result, result, 0)


void js_async_gen_await_return(js_runtime* rt, js_value* record);


# AsyncGeneratorDrainQueue for a completed generator.
void js_async_gen_drain(js_runtime* rt, js_value* record):
	while (record.coroutine_queue.length > 0 && rt.completion.status == 0):
		js_value* request = record.coroutine_queue[0]
		if (request.array_length == JS_RESUME_RETURN):
			record.coroutine_state = JS_CO_AWAITING_RETURN
			js_async_gen_await_return(rt, record)
			return
		if (request.array_length == JS_RESUME_THROW): js_async_gen_complete(rt, record, 1, request.parent, 1)
		else: js_async_gen_complete(rt, record, 0, rt.undefined_value, 1)


# AsyncGeneratorAwaitReturn: awaits the oldest (return) request's value.
void js_async_gen_await_return(js_runtime* rt, js_value* record):
	js_value* request = record.coroutine_queue[0]
	js_value* promise = js_coroutine_promise_resolve(rt, request.parent)
	if (rt.completion.status == 2):
		js_value* reason = js_coroutine_take_value(rt)
		record.coroutine_state = JS_CO_COMPLETED
		js_async_gen_complete(rt, record, 1, reason, 1)
		js_async_gen_drain(rt, record)
		return
	if (promise == 0 || js_coroutine_handlers(rt, record) == 0): return
	js_runtime_promise_reaction(rt, promise, 0, record.getter, record.setter)


void js_async_gen_return_settled(js_runtime* rt, js_value* record, int rejected, js_value* value):
	record.coroutine_state = JS_CO_COMPLETED
	js_async_gen_complete(rt, record, rejected, value, 1)
	js_async_gen_drain(rt, record)


# AsyncGeneratorResume plus the completion handling of AsyncGeneratorStart.
void js_async_gen_step(js_runtime* rt, js_value* record, int mode, js_value* value):
	js_value* result = js_coroutine_run(rt, record, mode, value)
	int status = rt.completion.status
	if (status == 7):
		if (rt.suspend_kind == JS_SUSPEND_AWAIT): record.coroutine_state = JS_CO_EXECUTING
		js_coroutine_take_value(rt)
		return
	if (status >= 5): return
	js_value* outcome = rt.undefined_value
	if (status == 1 || status == 2): outcome = js_coroutine_take_value(rt)
	js_async_gen_complete(rt, record, status == 2, outcome, 1)
	js_async_gen_drain(rt, record)


# %AsyncGeneratorPrototype%.next (0), throw (1) and return (2): enqueue a
# request and return its promise.
js_value* js_async_gen_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int mode = cast(int, context)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_value* promise = js_runtime_promise_new(rt)
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_generator_brand(receiver, JS_CO_ASYNC_GENERATOR) == 0):
		js_value* error = js_runtime_error_value(rt, c"AsyncGenerator method called on an incompatible receiver")
		js_runtime_promise_settle(rt, promise, error, 1)
		return promise
	js_value* record = receiver.coroutine
	int state = record.coroutine_state
	if (mode == JS_RESUME_NEXT && state == JS_CO_COMPLETED):
		js_value* result = js_runtime_iter_result(rt, rt.undefined_value, 1)
		if (rt.completion.status == 0): js_runtime_promise_settle(rt, promise, result, 0)
		return promise
	if (mode == JS_RESUME_THROW):
		if (state == JS_CO_START):
			js_coroutine_finish(record)
			state = JS_CO_COMPLETED
		if (state == JS_CO_COMPLETED):
			js_runtime_promise_settle(rt, promise, value, 1)
			return promise
	js_async_gen_enqueue(rt, record, mode, value, promise)
	if (rt.completion.status != 0): return rt.undefined_value
	if (mode == JS_RESUME_RETURN && (state == JS_CO_START || state == JS_CO_COMPLETED)):
		js_coroutine_finish(record)
		record.coroutine_state = JS_CO_AWAITING_RETURN
		js_async_gen_await_return(rt, record)
	else if (state == JS_CO_START || state == JS_CO_SUSPENDED): js_async_gen_step(rt, record, mode, value)
	if (rt.completion.status != 0): return rt.undefined_value
	return promise


# AsyncGeneratorYield: settles the oldest request with {value, done: false}.
# Returns 1 after suspending; 0 when a queued request resumes at once, its
# completion stored in rt.resume_mode / rt.resume_value.
int js_async_gen_yield(js_runtime* rt, js_value* value):
	js_value* record = rt.coroutine
	js_async_gen_complete(rt, record, 0, value, 0)
	if (rt.completion.status != 0): return 0
	if (record.coroutine_queue.length > 0):
		js_value* request = record.coroutine_queue[0]
		rt.resume_mode = request.array_length
		rt.resume_value = request.parent
		return 0
	js_coroutine_suspend(rt, JS_SUSPEND_YIELD, rt.undefined_value)
	return 1


# yield ----------------------------------------------------------------

js_value* js_coroutine_delegate(js_runtime* rt, js_node* node, js_value* env);


# Frame phases: 0 operand, 1 awaiting the operand (async generators), 2
# suspended at the yield, 3 awaiting a return resumption's value.
js_value* js_coroutine_yield(js_runtime* rt, js_node* node, js_value* env):
	if (strcmp(node.text, c"*") == 0): return js_coroutine_delegate(rt, node, env)
	int is_async = rt.coroutine != 0 && rt.coroutine.coroutine_kind == JS_CO_ASYNC_GENERATOR
	js_value* frame = js_frame_resume(rt, node)
	int phase = 0
	if (frame != 0): phase = frame.array_length
	if (phase == 3):
		js_value* awaited = js_coroutine_received(rt)
		if (rt.completion.status == 0):
			rt.completion.status = 1
			rt.completion.value = awaited
		return rt.undefined_value
	if (phase == 2 && is_async == 0): return js_coroutine_received(rt)
	if (phase == 0):
		js_value* value = rt.undefined_value
		if (node.children.length > 0): value = js_runtime_eval_node(rt, node.children[0], env)
		if (js_frame_save(rt, node, 0) != 0 || rt.completion.status != 0): return rt.undefined_value
		if (is_async == 0):
			js_coroutine_suspend(rt, JS_SUSPEND_YIELD, value)
			js_frame_save(rt, node, 2)
			return rt.undefined_value
		js_coroutine_await(rt, value)
		js_frame_save(rt, node, 1)
		return rt.undefined_value
	if (phase == 1):
		js_value* value = js_coroutine_received(rt)
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_async_gen_yield(rt, value)):
			js_frame_save(rt, node, 2)
			return rt.undefined_value
		if (rt.completion.status != 0): return rt.undefined_value
	# AsyncGeneratorUnwrapYieldResumption: a return awaits its value.
	if (rt.resume_mode != JS_RESUME_RETURN): return js_coroutine_received(rt)
	js_value* returned = rt.resume_value
	if (returned == 0): returned = rt.undefined_value
	rt.resume_value = 0
	rt.resume_mode = JS_RESUME_NEXT
	js_coroutine_await(rt, returned)
	js_frame_save(rt, node, 3)
	return rt.undefined_value


# Iterator records (runtime_symbols.w): iterator in this_value, cached next
# method in getter (0 when it is not callable).
js_value* js_coroutine_iterator_next(js_runtime* rt, js_value* record, js_value* argument):
	if (record.getter == 0): return js_runtime_type_error(rt, c"iterator next is not a function")
	list[js_value*] args = new list[js_value*]
	if (argument != 0): args.push(argument)
	js_value* result = js_runtime_call_receiver(rt, record.getter, record.this_value, args)
	__w_list_free(cast(__w_list*, args))
	return result


js_value* js_coroutine_iterator_record(js_runtime* rt, js_value* iterator):
	if (js_runtime_object(iterator) == 0):
		js_runtime_fail(rt, 2, c"iterator is not an object")
		return 0
	js_value* next = js_runtime_get(rt, iterator, c"next")
	if (rt.completion.status != 0): return 0
	js_value* record = js_runtime_alloc(rt, 5)
	if (record == rt.undefined_value): return 0
	record.this_value = iterator
	if (js_runtime_callable(next)): record.getter = next
	return record


# GetIterator(value, async): Symbol.asyncIterator, else an async-from-sync
# wrapper of the sync iterator.
js_value* js_coroutine_async_iterator(js_runtime* rt, js_value* value):
	if (rt.completion.status != 0): return 0
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"value is not async iterable")
		return 0
	js_value* method = js_runtime_get_symbol_method(rt, value, JS_SYMBOL_ASYNC_ITERATOR)
	if (rt.completion.status != 0): return 0
	if (method == 0):
		js_value* sync = js_runtime_iterator_open(rt, value)
		if (sync == 0): return 0
		js_value* wrapper = js_runtime_alloc(rt, 5)
		if (wrapper == rt.undefined_value): return 0
		wrapper.prototype = rt.async_from_sync_prototype
		wrapper.coroutine_kind = JS_CO_ASYNC_FROM_SYNC
		wrapper.home_object = sync
		return js_coroutine_iterator_record(rt, wrapper)
	js_value* iterator = js_runtime_call0(rt, method, value)
	if (rt.completion.status != 0): return 0
	return js_coroutine_iterator_record(rt, iterator)


void js_coroutine_restore(js_runtime* rt, js_value* closing):
	rt.completion.status = closing.array_length
	rt.completion.value = closing.parent
	rt.completion.message = cast(char*, closing.host)
	rt.jump_target = cast(js_node*, closing.binary_offset)


# AsyncIteratorClose(record, C) for the active completion C. When return()
# is called it awaits the result and returns a record of C, for the caller
# to save in its frame; otherwise it applies the outcome and returns 0.
js_value* js_coroutine_close_begin(js_runtime* rt, js_value* record):
	js_value* closing = js_runtime_alloc(rt, 12)
	if (closing == rt.undefined_value): return 0
	closing.array_length = rt.completion.status
	closing.parent = rt.completion.value
	closing.host = cast(int, rt.completion.message)
	closing.binary_offset = cast(int, rt.jump_target)
	rt.completion.status = 0
	rt.completion.message = c""
	js_text* key = js_runtime_key(c"return")
	js_value* method = js_runtime_get_method(rt, record.this_value, key)
	js_text_free(key)
	if (method != 0 && rt.completion.status == 0):
		js_value* inner = js_runtime_call0(rt, method, record.this_value)
		if (rt.completion.status == 0):
			js_coroutine_await(rt, inner)
			if (rt.completion.status == 7): return closing
	if (closing.array_length == 2 || rt.completion.status == 0): js_coroutine_restore(rt, closing)
	return 0


# Completes AsyncIteratorClose with the awaited return() result.
void js_coroutine_close_finish(js_runtime* rt, js_value* closing):
	js_value* result = js_coroutine_received(rt)
	if (closing.array_length == 2):
		js_coroutine_restore(rt, closing)
		return
	if (rt.completion.status != 0): return
	if (js_runtime_object(result) == 0):
		js_runtime_fail(rt, 2, c"iterator return result is not an object")
		return
	js_coroutine_restore(rt, closing)


# yield* -----------------------------------------------------------------

# Frame phases. P_CALL: about to call next/throw/return with the received
# completion; P_INNER: awaiting an async inner result (int slot 0 holds the
# method mode); P_YIELDED: suspended at the delegated yield; P_UNWRAP:
# awaiting a return resumption's value; P_CLOSE: awaiting return() before
# the missing-throw TypeError; P_RETURN: awaiting the value of a return
# with no return() method. Slot 0 is the iterator record.
const int JS_DELEGATE_OPERAND = 0
const int JS_DELEGATE_INNER = 1
const int JS_DELEGATE_YIELDED = 2
const int JS_DELEGATE_UNWRAP = 3
const int JS_DELEGATE_CLOSE = 4
const int JS_DELEGATE_RETURN = 5


js_value* js_coroutine_delegate_save(js_runtime* rt, js_node* node, int phase, js_value* iterator, int mode):
	js_value* saved = js_frame_save(rt, node, phase)
	if (saved != 0):
		js_frame_put(saved, iterator)
		js_frame_set_int(saved, 0, mode)
	return rt.undefined_value


js_value* js_coroutine_delegate(js_runtime* rt, js_node* node, js_value* env):
	int is_async = rt.coroutine != 0 && rt.coroutine.coroutine_kind == JS_CO_ASYNC_GENERATOR
	js_value* frame = js_frame_resume(rt, node)
	int phase = JS_DELEGATE_OPERAND
	js_value* iterator = 0
	int mode = JS_RESUME_NEXT
	js_value* received = rt.undefined_value
	js_value* inner = 0
	if (frame != 0):
		phase = frame.array_length
		iterator = js_frame_get(frame, 0)
		mode = js_frame_int(frame, 0)
	if (phase == JS_DELEGATE_OPERAND):
		js_value* value = js_runtime_eval_node(rt, node.children[0], env)
		if (js_frame_save(rt, node, JS_DELEGATE_OPERAND) != 0 || rt.completion.status != 0): return rt.undefined_value
		if (is_async): iterator = js_coroutine_async_iterator(rt, value)
		else: iterator = js_runtime_iterator_open(rt, value)
		if (iterator == 0): return rt.undefined_value
	else if (phase == JS_DELEGATE_YIELDED):
		mode = rt.resume_mode
		received = rt.resume_value
		if (received == 0): received = rt.undefined_value
		rt.resume_value = 0
		rt.resume_mode = JS_RESUME_NEXT
	else if (phase == JS_DELEGATE_UNWRAP):
		received = js_coroutine_received(rt)
		mode = JS_RESUME_RETURN
		if (rt.completion.status == 2):
			mode = JS_RESUME_THROW
			received = js_coroutine_take_value(rt)
	else if (phase == JS_DELEGATE_INNER):
		inner = js_coroutine_received(rt)
		if (rt.completion.status != 0): return rt.undefined_value
	else if (phase == JS_DELEGATE_CLOSE):
		js_value* result = js_coroutine_received(rt)
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_runtime_object(result) == 0): return js_runtime_type_error(rt, c"iterator return result is not an object")
		return js_runtime_type_error(rt, c"delegated iterator has no throw method")
	else if (phase == JS_DELEGATE_RETURN):
		js_value* value = js_coroutine_received(rt)
		if (rt.completion.status == 0):
			rt.completion.status = 1
			rt.completion.value = value
		return rt.undefined_value
	# A return resumption in an async generator first awaits its value.
	if (is_async && phase == JS_DELEGATE_YIELDED && mode == JS_RESUME_RETURN):
		js_coroutine_await(rt, received)
		return js_coroutine_delegate_save(rt, node, JS_DELEGATE_UNWRAP, iterator, mode)
	while (js_runtime_compat_step(rt)):
		if (inner == 0):
			if (mode == JS_RESUME_NEXT): inner = js_coroutine_iterator_next(rt, iterator, received)
			else:
				js_value* target = iterator.this_value
				js_text* key = js_runtime_key(c"throw")
				if (mode == JS_RESUME_RETURN):
					js_text_free(key)
					key = js_runtime_key(c"return")
				js_value* method = js_runtime_get_method(rt, target, key)
				js_text_free(key)
				if (rt.completion.status != 0): return rt.undefined_value
				if (method == 0 && mode == JS_RESUME_RETURN):
					if (is_async):
						js_coroutine_await(rt, received)
						return js_coroutine_delegate_save(rt, node, JS_DELEGATE_RETURN, iterator, mode)
					rt.completion.status = 1
					rt.completion.value = received
					return rt.undefined_value
				if (method == 0):
					# No throw(): close the iterator, then throw a TypeError.
					if (is_async):
						key = js_runtime_key(c"return")
						js_value* closer = js_runtime_get_method(rt, target, key)
						js_text_free(key)
						if (rt.completion.status != 0): return rt.undefined_value
						if (closer != 0):
							js_value* closed = js_runtime_call0(rt, closer, target)
							if (rt.completion.status != 0): return rt.undefined_value
							js_coroutine_await(rt, closed)
							return js_coroutine_delegate_save(rt, node, JS_DELEGATE_CLOSE, iterator, mode)
					else:
						js_runtime_iterator_close(rt, iterator)
						if (rt.completion.status != 0): return rt.undefined_value
					return js_runtime_type_error(rt, c"delegated iterator has no throw method")
				inner = js_runtime_call1(rt, method, target, received)
			if (rt.completion.status != 0): return rt.undefined_value
			if (is_async):
				js_coroutine_await(rt, inner)
				return js_coroutine_delegate_save(rt, node, JS_DELEGATE_INNER, iterator, mode)
		if (js_runtime_object(inner) == 0): return js_runtime_type_error(rt, c"iterator result is not an object")
		js_value* done = js_runtime_get(rt, inner, c"done")
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_runtime_truth(done)):
			js_value* value = js_runtime_get(rt, inner, c"value")
			if (rt.completion.status != 0): return rt.undefined_value
			if (mode == JS_RESUME_RETURN):
				rt.completion.status = 1
				rt.completion.value = value
				return rt.undefined_value
			return value
		if (is_async == 0):
			js_coroutine_suspend(rt, JS_SUSPEND_YIELD_RAW, inner)
			return js_coroutine_delegate_save(rt, node, JS_DELEGATE_YIELDED, iterator, mode)
		js_value* value = js_runtime_get(rt, inner, c"value")
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_async_gen_yield(rt, value)): return js_coroutine_delegate_save(rt, node, JS_DELEGATE_YIELDED, iterator, mode)
		if (rt.completion.status != 0): return rt.undefined_value
		mode = rt.resume_mode
		received = rt.resume_value
		if (received == 0): received = rt.undefined_value
		rt.resume_value = 0
		rt.resume_mode = JS_RESUME_NEXT
		inner = 0
		if (mode == JS_RESUME_RETURN):
			js_coroutine_await(rt, received)
			return js_coroutine_delegate_save(rt, node, JS_DELEGATE_UNWRAP, iterator, mode)
	return rt.undefined_value


# Built-in iterators -------------------------------------------------------

# Array.prototype[Symbol.iterator]/values and String.prototype[Symbol.iterator]:
# a list iterator over home_object (index in coroutine_state; home_object
# is cleared when exhausted).
js_value* js_list_iterator_create(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* target = receiver
	if (cast(int, context) == 1):
		if (receiver.kind == 0 || receiver.kind == 1): return js_runtime_type_error(rt, c"String iterator requires a value")
		if (receiver.kind != 4):
			target = js_runtime_to_string_value(rt, receiver)
			if (rt.completion.status != 0): return rt.undefined_value
	else if (js_runtime_object(receiver) == 0): return js_runtime_type_error(rt, c"Array iterator requires an object")
	js_value* iterator = js_runtime_alloc(rt, 5)
	if (iterator == rt.undefined_value): return iterator
	iterator.prototype = rt.list_iterator_prototype
	iterator.coroutine_kind = JS_CO_LIST_ITERATOR
	iterator.home_object = target
	return iterator


js_value* js_list_iterator_next(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_runtime_object(receiver) == 0 || receiver.coroutine_kind != JS_CO_LIST_ITERATOR): return js_runtime_type_error(rt, c"iterator next called on an incompatible receiver")
	js_value* target = receiver.home_object
	if (target == 0): return js_runtime_iter_result(rt, rt.undefined_value, 1)
	int index = receiver.coroutine_state
	js_value* value = 0
	if (target.kind == 4):
		value = js_runtime_iter_next(rt, target, &index)
		receiver.coroutine_state = index
	else:
		int length = js_runtime_to_length(rt, js_runtime_get(rt, target, c"length"))
		if (rt.completion.status != 0): return rt.undefined_value
		if (index < length):
			value = js_runtime_index_get(rt, target, index)
			receiver.coroutine_state = index + 1
	if (rt.completion.status != 0): return rt.undefined_value
	if (value == 0):
		receiver.home_object = 0
		return js_runtime_iter_result(rt, rt.undefined_value, 1)
	return js_runtime_iter_result(rt, value, 0)


# %AsyncFromSyncIteratorPrototype% -------------------------------------------

js_value* js_async_from_sync_unwrap(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* self = cast(js_value*, context)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	return js_runtime_iter_result(rt, value, self.coroutine_state)


js_value* js_async_from_sync_close(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* self = cast(js_value*, context)
	js_value* reason = rt.undefined_value
	if (args.length > 0): reason = args[0]
	rt.completion.status = 2
	rt.completion.value = reason
	rt.completion.message = c"JavaScript exception"
	js_runtime_iterator_close(rt, self.parent)
	return rt.undefined_value


js_value* js_async_from_sync_callable(js_runtime* rt, js_host_receiver_function* callback, js_value* sync, int done):
	js_value* callable = js_runtime_host_callable(rt, 0, callback)
	if (callable == rt.undefined_value): return 0
	callable.host_context = callable
	callable.parent = sync
	callable.coroutine_state = done
	return callable


# AsyncFromSyncIteratorContinuation: settles promise from a sync result.
void js_async_from_sync_continue(js_runtime* rt, js_value* result, js_value* promise, js_value* sync, int close_on_rejection):
	js_value* done_value = js_runtime_get(rt, result, c"done")
	int done = 0
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0):
		done = js_runtime_truth(done_value)
		value = js_runtime_get(rt, result, c"value")
	js_value* wrapper = 0
	if (rt.completion.status == 0): wrapper = js_coroutine_promise_resolve(rt, value)
	if (rt.completion.status == 2 && done == 0 && close_on_rejection): js_runtime_iterator_close(rt, sync)
	if (rt.completion.status == 2):
		js_runtime_promise_settle(rt, promise, js_coroutine_take_value(rt), 1)
		return
	if (rt.completion.status != 0): return
	js_value* fulfilled = js_async_from_sync_callable(rt, js_async_from_sync_unwrap, sync, done)
	js_value* rejected = rt.undefined_value
	if (done == 0 && close_on_rejection): rejected = js_async_from_sync_callable(rt, js_async_from_sync_close, sync, done)
	if (fulfilled == 0 || rejected == 0): return
	js_runtime_promise_reaction(rt, wrapper, promise, fulfilled, rejected)


# next (0), throw (1) and return (2).
js_value* js_async_from_sync_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int mode = cast(int, context)
	js_value* promise = js_runtime_promise_new(rt)
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_object(receiver) == 0 || receiver.coroutine_kind != JS_CO_ASYNC_FROM_SYNC):
		js_runtime_promise_settle(rt, promise, js_runtime_error_value(rt, c"async-from-sync iterator method called on an incompatible receiver"), 1)
		return promise
	js_value* sync = receiver.home_object
	js_value* iterator = sync.this_value
	js_value* argument = 0
	if (args.length > 0): argument = args[0]
	js_value* result = 0
	if (mode == JS_RESUME_NEXT): result = js_coroutine_iterator_next(rt, sync, argument)
	else:
		js_text* key = js_runtime_key(c"throw")
		if (mode == JS_RESUME_RETURN):
			js_text_free(key)
			key = js_runtime_key(c"return")
		js_value* method = js_runtime_get_method(rt, iterator, key)
		js_text_free(key)
		if (rt.completion.status == 0 && method == 0):
			js_value* value = rt.undefined_value
			if (argument != 0): value = argument
			if (mode == JS_RESUME_RETURN):
				js_value* done = js_runtime_iter_result(rt, value, 1)
				if (rt.completion.status == 0): js_runtime_promise_settle(rt, promise, done, 0)
				return promise
			# No throw(): close the sync iterator and reject with a TypeError.
			js_runtime_iterator_close(rt, sync)
			if (rt.completion.status == 0): js_runtime_fail(rt, 2, c"sync iterator has no throw method")
		else if (rt.completion.status == 0):
			list[js_value*] call_args = new list[js_value*]
			if (argument != 0): call_args.push(argument)
			result = js_runtime_call_receiver(rt, method, iterator, call_args)
			__w_list_free(cast(__w_list*, call_args))
	if (rt.completion.status == 0 && js_runtime_object(result) == 0): js_runtime_fail(rt, 2, c"iterator result is not an object")
	if (rt.completion.status == 2):
		js_runtime_promise_settle(rt, promise, js_coroutine_take_value(rt), 1)
		return promise
	if (rt.completion.status != 0): return rt.undefined_value
	js_async_from_sync_continue(rt, result, promise, sync, mode != JS_RESUME_RETURN)
	if (rt.completion.status != 0): return rt.undefined_value
	return promise


# `in` (RelationalExpression): HasProperty on an object.
js_value* js_runtime_in(js_runtime* rt, js_value* key, js_value* object):
	if (js_runtime_object(object) == 0): return js_runtime_type_error(rt, c"right-hand side of in is not an object")
	js_text* name = js_runtime_property_key(rt, key)
	if (name == 0): return rt.undefined_value
	int found = 0
	if (object.kind == 6 && js_runtime_key_is(name, c"length")): found = 1
	else:
		if (object.kind == 7): js_runtime_function_prototype(rt, object, name)
		found = js_runtime_has_property(rt, object, name)
	js_text_free(name)
	return js_runtime_boolean(rt, found)


# Intrinsics -------------------------------------------------------------

js_value* js_coroutine_intrinsic(js_runtime* rt, js_value* parent, char* tag):
	js_value* object = js_runtime_alloc(rt, 5)
	if (object == rt.undefined_value): return 0
	object.prototype = parent
	if (tag != 0):
		js_text* name = js_runtime_key(tag)
		js_text* key = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
		js_runtime_define_data(rt, object, key, js_runtime_string(rt, name), 0, 0, 1)
		js_text_free(key)
		js_text_free(name)
	return object


void js_coroutine_link(js_runtime* rt, js_value* function_prototype, js_value* instances):
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, function_prototype, key, instances, 0, 0, 1)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, instances, key, function_prototype, 0, 0, 1)
	js_text_free(key)


void js_runtime_install_coroutines(js_runtime* rt):
	if (rt.function_prototype == 0 || rt.symbol_prototype == 0): return
	js_value* self = js_runtime_host_callable(rt, 0, js_symbol_iterator_self)
	rt.iterator_prototype = js_coroutine_intrinsic(rt, 0, 0)
	rt.async_iterator_prototype = js_coroutine_intrinsic(rt, 0, 0)
	if (rt.iterator_prototype == 0 || rt.async_iterator_prototype == 0): return
	js_runtime_define_symbol_method(rt, rt.iterator_prototype, JS_SYMBOL_ITERATOR, self)
	js_runtime_define_symbol_method(rt, rt.async_iterator_prototype, JS_SYMBOL_ASYNC_ITERATOR, js_runtime_host_callable(rt, 0, js_symbol_iterator_self))
	rt.generator_prototype = js_coroutine_intrinsic(rt, rt.iterator_prototype, c"Generator")
	rt.async_generator_prototype = js_coroutine_intrinsic(rt, rt.async_iterator_prototype, c"AsyncGenerator")
	rt.generator_function_prototype = js_coroutine_intrinsic(rt, rt.function_prototype, c"GeneratorFunction")
	rt.async_function_prototype = js_coroutine_intrinsic(rt, rt.function_prototype, c"AsyncFunction")
	rt.async_generator_function_prototype = js_coroutine_intrinsic(rt, rt.function_prototype, c"AsyncGeneratorFunction")
	rt.async_from_sync_prototype = js_coroutine_intrinsic(rt, rt.async_iterator_prototype, 0)
	rt.list_iterator_prototype = js_coroutine_intrinsic(rt, rt.iterator_prototype, c"Array Iterator")
	if (rt.list_iterator_prototype == 0): return
	js_coroutine_link(rt, rt.generator_function_prototype, rt.generator_prototype)
	js_coroutine_link(rt, rt.async_generator_function_prototype, rt.async_generator_prototype)
	for i in range(3):
		char* name = c"next"
		if (i == JS_RESUME_THROW): name = c"throw"
		if (i == JS_RESUME_RETURN): name = c"return"
		js_runtime_collection_method(rt, rt.generator_prototype, name, i, js_generator_method)
		js_runtime_collection_method(rt, rt.async_generator_prototype, name, i, js_async_gen_method)
		js_runtime_collection_method(rt, rt.async_from_sync_prototype, name, i, js_async_from_sync_method)
	js_runtime_collection_method(rt, rt.list_iterator_prototype, c"next", 0, js_list_iterator_next)
	js_value* values = js_runtime_host_callable(rt, 0, js_list_iterator_create)
	js_runtime_define_symbol_method(rt, rt.array_prototype, JS_SYMBOL_ITERATOR, values)
	js_text* key = js_runtime_key(c"values")
	js_runtime_define_data(rt, rt.array_prototype, key, values, 1, 0, 1)
	js_text_free(key)
	js_runtime_define_symbol_method(rt, rt.string_prototype, JS_SYMBOL_ITERATOR, js_runtime_host_callable(rt, cast(void*, 1), js_list_iterator_create))
	# Promise.prototype.constructor, which PromiseResolve (await) consults.
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, rt.promise_prototype, key, rt.promise_constructor, 1, 0, 1)
	js_text_free(key)
