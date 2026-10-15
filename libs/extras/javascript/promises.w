# Included by runtime.w. Native promises and FIFO host-driven checkpoints.
# promise_state: 0 ordinary value, 1 pending, 2 fulfilled, 3 rejected,
# 4 following another native promise. Reactions are private traced heap nodes.


int js_runtime_callable(js_value* value):
	return value != 0 && (value.kind == 7 || value.kind == 9)


js_value* js_runtime_promise_new(js_runtime* rt):
	js_value* promise = js_runtime_alloc(rt, 5)
	if (promise != rt.undefined_value):
		promise.promise_state = 1
		promise.promise_result = rt.undefined_value
		promise.reactions = new list[js_value*]
		promise.prototype = rt.promise_prototype
	return promise


int js_runtime_enqueue_microtask(js_runtime* rt, js_value* job):
	if (rt.microtasks.length - rt.microtask_head >= rt.max_microtasks):
		js_runtime_fail(rt, 5, c"JavaScript microtask queue limit")
		return 0
	# Compact consumed entries so self-scheduling jobs cannot grow storage.
	if (rt.microtask_head > 0):
		int count = rt.microtasks.length - rt.microtask_head
		for i in range(count): rt.microtasks[i] = rt.microtasks[i + rt.microtask_head]
		while (rt.microtasks.length > count): rt.microtasks.pop()
		rt.microtask_head = 0
	rt.microtasks.push(job)
	return 1


js_value* js_runtime_promise_reaction(js_runtime* rt, js_value* source, js_value* target, js_value* fulfilled, js_value* rejected):
	js_value* reaction = js_runtime_alloc(rt, 5)
	if (reaction == rt.undefined_value): return reaction
	reaction.parent = source
	reaction.this_value = target
	reaction.getter = fulfilled
	reaction.setter = rejected
	if (source.promise_state == 2 || source.promise_state == 3): js_runtime_enqueue_microtask(rt, reaction)
	else:
		if (source.reactions.length >= rt.max_properties): js_runtime_fail(rt, 5, c"JavaScript promise reaction limit")
		else: source.reactions.push(reaction)
	return reaction


# Host values must belong to rt. Settlement is first-call-wins, including
# adoption of a pending native promise. No JS is invoked during settlement.
int js_runtime_promise_settle(js_runtime* rt, js_value* promise, js_value* value, int rejected):
	if (promise == 0 || value == 0 || promise.owner != rt || value.owner != rt || promise.promise_state == 0):
		js_runtime_fail(rt, 2, c"invalid promise settlement")
		return 0
	if (promise.promise_state != 1): return 1
	if (rejected == 0 && value == promise):
		value = js_runtime_error_value(rt, c"promise resolution cycle")
		rejected = 1
	if (rejected == 0 && value.promise_state != 0):
		promise.promise_state = 4
		promise.promise_result = value
		js_runtime_promise_reaction(rt, value, promise, rt.undefined_value, rt.undefined_value)
		return rt.completion.status == 0
	# Reserve the entire fanout before modifying state, avoiding partial delivery.
	if (promise.reactions.length > rt.max_microtasks - (rt.microtasks.length - rt.microtask_head)):
		js_runtime_fail(rt, 5, c"JavaScript microtask queue limit")
		return 0
	promise.promise_state = 2
	if (rejected): promise.promise_state = 3
	promise.promise_result = value
	for i in range(promise.reactions.length): js_runtime_enqueue_microtask(rt, promise.reactions[i])
	while (promise.reactions.length > 0): promise.reactions.pop()
	return rt.completion.status == 0


js_value* js_runtime_promise_then(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.promise_state == 0):
		js_runtime_fail(rt, 2, c"Promise.then receiver is not a promise")
		return rt.undefined_value
	js_value* fulfilled = rt.undefined_value
	js_value* rejected = rt.undefined_value
	if (context == 0):
		if (args.length > 0): fulfilled = args[0]
		if (args.length > 1): rejected = args[1]
	else:
		if (args.length > 0): rejected = args[0]
	js_value* target = js_runtime_promise_new(rt)
	if (rt.completion.status == 0): js_runtime_promise_reaction(rt, receiver, target, fulfilled, rejected)
	return target


js_value* js_runtime_promise_static(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	int rejected = context != 0
	if (rejected == 0 && value.promise_state != 0): return value
	js_value* promise = js_runtime_promise_new(rt)
	if (rt.completion.status == 0): js_runtime_promise_settle(rt, promise, value, rejected)
	return promise


js_value* js_runtime_queue_microtask(void* runtime, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (args.length == 0 || js_runtime_callable(args[0]) == 0):
		js_runtime_fail(rt, 2, c"queueMicrotask callback is not callable")
		return rt.undefined_value
	js_value* job = js_runtime_alloc(rt, 5)
	if (job != rt.undefined_value):
		job.getter = args[0]
		js_runtime_enqueue_microtask(rt, job)
	return rt.undefined_value


js_value* js_runtime_promise_resolve_callback(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_runtime_promise_settle(rt, cast(js_value*, context), value, 0)
	return rt.undefined_value


js_value* js_runtime_promise_reject_callback(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* value = rt.undefined_value
	if (args.length > 0): value = args[0]
	js_runtime_promise_settle(rt, cast(js_value*, context), value, 1)
	return rt.undefined_value


js_value* js_runtime_promise_requires_new(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 2, c"Promise constructor requires new")
	return rt.undefined_value


js_value* js_runtime_promise_construct(js_runtime* rt, list[js_value*] args):
	if (args.length == 0 || js_runtime_callable(args[0]) == 0):
		js_runtime_fail(rt, 2, c"Promise executor is not callable")
		return rt.undefined_value
	js_value* promise = js_runtime_promise_new(rt)
	js_value* resolve = js_runtime_host_callable(rt, promise, js_runtime_promise_resolve_callback)
	js_value* reject = js_runtime_host_callable(rt, promise, js_runtime_promise_reject_callback)
	if (rt.completion.status != 0): return rt.undefined_value
	# Host contexts are opaque to GC; these ordinary edges retain the promise.
	resolve.parent = promise
	reject.parent = promise
	list[js_value*] executor_args = new list[js_value*]
	executor_args.push(resolve)
	executor_args.push(reject)
	js_runtime_call_receiver(rt, args[0], rt.undefined_value, executor_args)
	__w_list_free(cast(__w_list*, executor_args))
	if (rt.completion.status == 2):
		js_value* reason = rt.completion.value
		rt.completion.status = 0
		rt.completion.message = c""
		rt.completion.value = rt.undefined_value
		js_runtime_promise_settle(rt, promise, reason, 1)
	return promise


void js_runtime_clear_microtasks(js_runtime* rt):
	if (rt.running): return
	while (rt.microtasks.length > 0): rt.microtasks.pop()
	rt.microtask_head = 0


void js_runtime_install_promises(js_runtime* rt):
	rt.promise_prototype = js_runtime_alloc(rt, 5)
	js_runtime_set(rt, rt.promise_prototype, c"then", js_runtime_host_callable(rt, 0, js_runtime_promise_then))
	js_runtime_set(rt, rt.promise_prototype, c"catch", js_runtime_host_callable(rt, cast(void*, 1), js_runtime_promise_then))
	js_value* promise = js_runtime_host_callable(rt, 0, js_runtime_promise_requires_new)
	rt.promise_constructor = promise
	js_runtime_set(rt, promise, c"resolve", js_runtime_host_callable(rt, 0, js_runtime_promise_static))
	js_runtime_set(rt, promise, c"reject", js_runtime_host_callable(rt, cast(void*, 1), js_runtime_promise_static))
	js_runtime_set(rt, promise, c"prototype", rt.promise_prototype)
	js_runtime_set(rt, rt.global, c"Promise", promise)
	js_runtime_bind(rt, c"queueMicrotask", js_runtime_queue_microtask)


# Explicit checkpoint. Like invoke/eval, replaces the instance completion;
# reentry returns null. Limits stop the checkpoint; unfinished queued jobs stay
# rooted. A started job is never replayed after a limit or uncaught exception.
js_completion* js_runtime_drain_microtasks(js_runtime* rt, int budget):
	if (js_runtime_begin(rt, budget) == 0): return 0
	rt.running = 1
	while (rt.microtask_head < rt.microtasks.length && rt.completion.status == 0):
		if (rt.remaining <= 0 || rt.max_depth <= 0):
			js_runtime_fail(rt, 5, c"JavaScript microtask execution limit")
			break
		rt.remaining = rt.remaining - 1
		rt.completion.steps = rt.completion.steps + 1
		js_value* job = rt.microtasks[rt.microtask_head]
		rt.microtask_head = rt.microtask_head + 1
		list[js_value*] args = new list[js_value*]
		js_value* handler = job.getter
		js_value* value = rt.undefined_value
		int rejected = 0
		if (job.parent != 0):
			value = job.parent.promise_result
			rejected = job.parent.promise_state == 3
			if (rejected): handler = job.setter
			args.push(value)
		if (js_runtime_callable(handler)):
			rt.depth = 1
			value = js_runtime_call_receiver(rt, handler, rt.undefined_value, args)
			rt.depth = 0
			rejected = 0
			if (job.parent != 0 && rt.completion.status == 2):
				value = rt.completion.value
				rejected = 1
				rt.completion.status = 0
				rt.completion.message = c""
				rt.completion.value = rt.undefined_value
		__w_list_free(cast(__w_list*, args))
		if (job.this_value != 0 && rt.completion.status == 0):
			if (job.this_value.promise_state == 4): job.this_value.promise_state = 1
			js_runtime_promise_settle(rt, job.this_value, value, rejected)
	if (rt.microtask_head == rt.microtasks.length):
		while (rt.microtasks.length > 0): rt.microtasks.pop()
		rt.microtask_head = 0
	rt.running = 0
	return rt.completion
