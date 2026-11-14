# Promise.prototype.finally and the Promise.all / race / allSettled combinators,
# installed on the native promise by js_install_promise. Handlers are host
# callables whose contexts are traced heap nodes, so the evaluation budget and
# the microtask, property and heap quotas apply exactly as for user code.
import libs.extras.javascript.runtime


js_value* js_runtime_finally_value(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* saved = cast(js_value*, context)
	if (saved.number == 1.0): js_runtime_throw(rt, saved.this_value)
	return saved.this_value


js_value* js_runtime_finally_handler(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* captured = cast(js_value*, context)
	list[js_value*] empty = new list[js_value*]
	js_value* result = js_runtime_call_receiver(rt, captured.getter, rt.undefined_value, empty)
	__w_list_free(cast(__w_list*, empty))
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* promise = result
	if (promise.promise_state == 0):
		promise = js_runtime_promise_new(rt)
		if (rt.completion.status == 0): js_runtime_promise_settle(rt, promise, result, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* saved = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	saved.number = captured.number
	saved.this_value = rt.undefined_value
	if (args.length > 0): saved.this_value = args[0]
	js_value* thunk = js_runtime_host_callable(rt, saved, js_runtime_finally_value)
	if (rt.completion.status != 0): return rt.undefined_value
	thunk.parent = saved
	js_value* target = js_runtime_promise_new(rt)
	if (rt.completion.status == 0): js_runtime_promise_reaction(rt, promise, target, thunk, rt.undefined_value)
	return target


js_value* js_runtime_promise_finally(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.promise_state == 0):
		js_runtime_fail(rt, 2, c"Promise.finally receiver is not a promise")
		return rt.undefined_value
	js_value* callback = rt.undefined_value
	if (args.length > 0): callback = args[0]
	js_value* target = js_runtime_promise_new(rt)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* fulfilled = callback
	js_value* rejected = callback
	if (js_runtime_callable(callback)):
		for i in range(2):
			js_value* captured = js_runtime_alloc(rt, 5)
			if (rt.completion.status != 0): return rt.undefined_value
			captured.number = cast(float64, i)
			captured.getter = callback
			js_value* handler = js_runtime_host_callable(rt, captured, js_runtime_finally_handler)
			if (rt.completion.status != 0): return rt.undefined_value
			handler.parent = captured
			if (i == 0): fulfilled = handler
			else: rejected = handler
	js_runtime_promise_reaction(rt, receiver, target, fulfilled, rejected)
	return target


# Result indices are own data properties; inherited setters must not intercept
# the internal list accumulation required by Promise combinators.
void js_runtime_combinator_store(js_runtime* rt, js_value* array, int index, js_value* value):
	char* name = itoa(index)
	js_text* key = js_runtime_key(name)
	free(name)
	if (js_runtime_put(rt, array, key, value) && index >= array.array_length): array.array_length = index + 1
	js_text_free(key)


# Combinator state and element records use traced heap edges. The shared
# remaining count starts at one so synchronous overridden then methods cannot
# fulfill all/allSettled before iteration has finished.
void js_runtime_combinator_element(js_runtime* rt, js_value* element, js_value* value, int rejected):
	js_value* state = element.parent
	int mode = state.array_length
	if (mode == 1 || (mode == 0 && rejected)):
		js_runtime_promise_settle(rt, state.parent, value, rejected)
		return
	if (element.initialized): return
	element.initialized = 1
	if (mode == 2):
		js_value* record = js_runtime_alloc(rt, 5)
		if (rt.completion.status != 0): return
		char* status = c"fulfilled"
		char* field = c"value"
		if (rejected):
			status = c"rejected"
			field = c"reason"
		js_text* text = js_runtime_key(status)
		js_value* label = js_runtime_string(rt, text)
		js_text_free(text)
		js_runtime_set(rt, record, c"status", label)
		js_runtime_set(rt, record, field, value)
		value = record
	if (rt.completion.status != 0): return
	js_runtime_combinator_store(rt, state.this_value, cast(int, element.number), value)
	state.number = state.number - 1.0
	if (state.number == 0.0 && rt.completion.status == 0): js_runtime_promise_settle(rt, state.parent, state.this_value, 0)


js_value* js_runtime_combinator_fulfill(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_runtime_combinator_element(rt, cast(js_value*, context), value, 0)
	return rt.undefined_value


js_value* js_runtime_combinator_reject(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_runtime_combinator_element(rt, cast(js_value*, context), value, 1)
	return rt.undefined_value


js_value* js_runtime_promise_combinator(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int mode = cast(int, context)
	js_value* target = js_runtime_promise_new(rt)
	if (rt.completion.status != 0): return rt.undefined_value
	# Capture the intrinsic constructor's current resolve method once, as
	# required even when user code replaces it during iteration.
	js_value* resolver = js_runtime_get(rt, rt.promise_constructor, c"resolve")
	if (rt.completion.status == 0 && js_runtime_callable(resolver) == 0): js_runtime_fail(rt, 2, c"Promise resolve is not callable")
	if (rt.completion.status == 2):
		js_value* reason = rt.completion.value
		rt.completion.status = 0
		rt.completion.value = rt.undefined_value
		rt.completion.message = c""
		js_runtime_promise_settle(rt, target, reason, 1)
		return target
	if (rt.completion.status != 0): return rt.undefined_value
	# Arrays and strings are indexed directly; any other value goes through the
	# iterator protocol, and a failure inside the loop closes an open iterator.
	js_value* iterable = rt.undefined_value
	if (args.length > 0): iterable = args[0]
	js_value* iterator = 0
	if (iterable.kind != 6 && iterable.kind != 4):
		iterator = js_runtime_iterator_open(rt, iterable)
		if (iterator == 0 && rt.completion.status == 0): js_runtime_fail(rt, 2, c"Promise iterable is not iterable")
		if (rt.completion.status == 2):
			js_value* reason = rt.completion.value
			rt.completion.status = 0
			rt.completion.value = rt.undefined_value
			rt.completion.message = c""
			js_runtime_promise_settle(rt, target, reason, 1)
			return target
		if (rt.completion.status != 0): return rt.undefined_value
	js_value* state = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	state.parent = target
	state.number = 1.0
	state.array_length = mode
	state.this_value = rt.undefined_value
	if (mode != 1): state.this_value = js_runtime_alloc(rt, 6)
	int index = 0
	int count = 0
	int done = 0
	while (js_runtime_compat_step(rt)):
		js_value* value = 0
		if (iterator != 0): value = js_runtime_iterator_step(rt, iterator)
		else: value = js_runtime_iter_next(rt, iterable, &index)
		if (rt.completion.status != 0 || value == 0):
			# An exhausted or failing next() leaves the iterator done.
			done = 1
			break
		if (count >= rt.max_properties):
			js_runtime_fail(rt, 5, c"JavaScript Promise iterable limit")
			break
		list[js_value*] resolve_args = new list[js_value*]
		resolve_args.push(value)
		js_value* promise = js_runtime_call_receiver(rt, resolver, rt.promise_constructor, resolve_args)
		__w_list_free(cast(__w_list*, resolve_args))
		if (rt.completion.status != 0): break
		js_value* element = js_runtime_alloc(rt, 5)
		if (rt.completion.status != 0): break
		element.parent = state
		element.number = cast(float64, count)
		element.initialized = 0
		if (mode != 1): js_runtime_combinator_store(rt, state.this_value, count, rt.undefined_value)
		state.number = state.number + 1.0
		count = count + 1
		js_value* fulfilled = js_runtime_host_callable(rt, element, js_runtime_combinator_fulfill)
		if (rt.completion.status != 0): break
		fulfilled.parent = element
		js_value* rejected = js_runtime_host_callable(rt, element, js_runtime_combinator_reject)
		if (rt.completion.status != 0): break
		rejected.parent = element
		js_value* then = js_runtime_get(rt, promise, c"then")
		if (rt.completion.status != 0): break
		list[js_value*] handlers = new list[js_value*]
		handlers.push(fulfilled)
		handlers.push(rejected)
		js_runtime_call_receiver(rt, then, promise, handlers)
		__w_list_free(cast(__w_list*, handlers))
		if (rt.completion.status != 0): break
	if (iterator != 0 && done == 0 && rt.completion.status != 5 && rt.completion.status != 6 && rt.completion.status != 7): js_runtime_iterator_close(rt, iterator)
	if (rt.completion.status == 2):
		js_value* reason = rt.completion.value
		rt.completion.status = 0
		rt.completion.value = rt.undefined_value
		rt.completion.message = c""
		js_runtime_promise_settle(rt, target, reason, 1)
	if (rt.completion.status != 0): return rt.undefined_value
	state.number = state.number - 1.0
	if (mode != 1 && state.number == 0.0): js_runtime_promise_settle(rt, target, state.this_value, 0)
	return target


void js_runtime_install_promise_combinators(js_runtime* rt):
	js_runtime_set(rt, rt.promise_prototype, c"finally", js_runtime_host_callable(rt, 0, js_runtime_promise_finally))
	js_runtime_set(rt, rt.promise_constructor, c"all", js_runtime_host_callable(rt, 0, js_runtime_promise_combinator))
	js_runtime_set(rt, rt.promise_constructor, c"race", js_runtime_host_callable(rt, cast(void*, 1), js_runtime_promise_combinator))
	js_runtime_set(rt, rt.promise_constructor, c"allSettled", js_runtime_host_callable(rt, cast(void*, 2), js_runtime_promise_combinator))
