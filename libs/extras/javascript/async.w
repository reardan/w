# Genuine stackful suspension on W generators. Every await returns control to
# the host; only Promise microtasks resume a task. No polling or nested waits.
import lib.generator
import libs.extras.javascript.runtime

type js_async_entry = fn(void*, void*) -> js_value*

struct js_async_frame:
	js_runtime* runtime
	generator* fiber
	js_async_entry* entry
	void* context
	void* owner
	js_value* retained
	js_value* callable
	js_value* receiver
	list[js_value*] arguments
	js_value* promise
	js_value* token
	js_value* resume_value
	int resume_rejected
	list[js_value*] roots
	js_completion completion
	int remaining
	int depth
	int empty
	js_runtime_label* label
	js_node* jump_target
	int cancelled

void js_async_resume(js_async_frame* frame);


void js_runtime_async_mark(js_runtime* rt, list[js_value*] pending):
	for i in range(rt.async_tasks.length):
		js_async_frame* frame = cast(js_async_frame*, rt.async_tasks[i])
		js_runtime_mark(pending, frame.promise)
		js_runtime_mark(pending, frame.token)
		js_runtime_mark(pending, frame.retained)
		js_runtime_mark(pending, frame.callable)
		js_runtime_mark(pending, frame.receiver)
		js_runtime_mark(pending, frame.resume_value)
		js_runtime_mark(pending, frame.completion.value)
		for j in range(frame.arguments.length): js_runtime_mark(pending, frame.arguments[j])
		for j in range(frame.roots.length): js_runtime_mark(pending, frame.roots[j])


void js_async_free(js_async_frame* frame):
	js_runtime* rt = frame.runtime
	frame.token.host_context = 0
	for i in range(rt.async_tasks.length):
		if (rt.async_tasks[i] != cast(void*, frame)): continue
		for j in range(i + 1, rt.async_tasks.length): rt.async_tasks[j - 1] = rt.async_tasks[j]
		rt.async_tasks.pop()
		break
	rt.async_root_count = rt.async_root_count - frame.roots.length
	rt.async_stack_bytes = rt.async_stack_bytes - 262144
	__w_list_free(cast(__w_list*, frame.roots))
	__w_list_free(cast(__w_list*, frame.arguments))
	gen_free(frame.fiber)
	free(frame)


# Copy identities, never inspect arbitrary native stack words. This conservative
# snapshot keeps all potential evaluator temporaries live across suspension.
# It can retain unrelated garbage; task/root/heap budgets bound that tradeoff.
int js_async_capture(js_async_frame* frame):
	js_runtime* rt = frame.runtime
	int retained = rt.async_root_count - frame.roots.length
	if (rt.heap.length > rt.max_async_roots - retained):
		js_runtime_fail(rt, 5, c"JavaScript suspended root limit")
		return 0
	rt.async_root_count = retained + rt.heap.length
	while (frame.roots.length > 0): frame.roots.pop()
	for i in range(rt.heap.length): frame.roots.push(rt.heap[i])
	return 1


js_value* js_async_reaction(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* token = cast(js_value*, context)
	js_value* task_token = token
	if (token.parent != 0): task_token = token.parent
	js_async_frame* frame = cast(js_async_frame*, task_token.host_context)
	if (frame == 0): return rt.undefined_value
	frame.resume_value = rt.undefined_value
	if (args.length > 0): frame.resume_value = args[0]
	frame.resume_rejected = token.number == 1.0
	js_async_resume(frame)
	return rt.undefined_value


js_value* js_runtime_await(js_runtime* rt, js_value* value):
	if (rt.completion.status != 0): return rt.undefined_value
	js_async_frame* frame = cast(js_async_frame*, rt.active_async)
	if (frame == 0):
		js_runtime_fail(rt, 6, c"await requires asynchronous evaluation")
		return rt.undefined_value
	js_value* promise = value
	if (promise.promise_state == 0):
		promise = js_runtime_promise_new(rt)
		if (rt.completion.status == 0): js_runtime_promise_settle(rt, promise, value, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	# Each reaction has its own direction token, pointing to the durable task
	# token rather than directly owning a native frame pointer.
	js_value* fulfill = js_runtime_host_callable(rt, frame.token, js_async_reaction)
	if (rt.completion.status != 0): return rt.undefined_value
	fulfill.parent = frame.token
	js_value* rejected_token = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return rt.undefined_value
	rejected_token.parent = frame.token
	rejected_token.number = 1.0
	js_value* reject = js_runtime_host_callable(rt, rejected_token, js_async_reaction)
	if (rt.completion.status != 0): return rt.undefined_value
	reject.parent = rejected_token
	js_runtime_promise_reaction(rt, promise, 0, fulfill, reject)
	if (rt.completion.status != 0 || js_async_capture(frame) == 0): return rt.undefined_value
	__w_gen_yield(frame.fiber, 1)
	if (rt.completion.status != 0): return rt.undefined_value
	if (frame.resume_rejected): js_runtime_throw(rt, frame.resume_value)
	return frame.resume_value


generator int js_async_body(js_async_frame* frame):
	js_runtime* rt = frame.runtime
	js_value* value = rt.undefined_value
	if (frame.callable != 0): value = js_runtime_call_body(rt, frame.callable, frame.receiver, frame.arguments, 0)
	else: value = frame.entry(rt, frame.context)
	if (rt.completion.status == 0 || rt.completion.status == 2):
		int rejected = rt.completion.status == 2
		if (rejected): value = rt.completion.value
		rt.completion.status = 0
		rt.completion.value = rt.undefined_value
		rt.completion.message = c""
		js_runtime_promise_settle(rt, frame.promise, value, rejected)


void js_async_resume(js_async_frame* frame):
	js_runtime* rt = frame.runtime
	js_completion* outer_completion = rt.completion
	int outer_remaining = rt.remaining
	int outer_depth = rt.depth
	int outer_empty = rt.empty
	js_runtime_label* outer_label = rt.label
	js_node* outer_jump = rt.jump_target
	void* outer_async = rt.active_async
	int available = frame.remaining
	if (outer_remaining < available): available = outer_remaining
	rt.completion = &frame.completion
	rt.remaining = available
	rt.depth = frame.depth
	rt.empty = frame.empty
	rt.label = frame.label
	rt.jump_target = frame.jump_target
	rt.active_async = frame
	gen_next(frame.fiber)
	int consumed = available - rt.remaining
	frame.remaining = frame.remaining - consumed
	frame.depth = rt.depth
	frame.empty = rt.empty
	frame.label = rt.label
	frame.jump_target = rt.jump_target
	int status = frame.completion.status
	char* message = frame.completion.message
	js_value* error = frame.completion.value
	rt.completion = outer_completion
	rt.remaining = outer_remaining - consumed
	rt.completion.steps = rt.completion.steps + consumed
	rt.depth = outer_depth
	rt.empty = outer_empty
	rt.label = outer_label
	rt.jump_target = outer_jump
	rt.active_async = outer_async
	int cancelled = frame.cancelled
	if (gen_done(frame.fiber)): js_async_free(frame)
	if (cancelled == 0 && status >= 5 && rt.completion.status == 0):
		rt.completion.status = status
		rt.completion.message = message
		rt.completion.value = error


js_async_frame* js_async_new(js_runtime* rt, void* owner, js_value* retained):
	if (rt.running == 0 || js_runtime_compat_step(rt) == 0): return 0
	if (rt.async_tasks.length >= rt.max_async_tasks || 262144 > rt.max_async_stack_bytes - rt.async_stack_bytes):
		js_runtime_fail(rt, 5, c"JavaScript asynchronous task or stack limit")
		return 0
	js_value* promise = js_runtime_promise_new(rt)
	js_value* token = js_runtime_alloc(rt, 5)
	if (rt.completion.status != 0): return 0
	js_async_frame* frame = new js_async_frame()
	frame.runtime = rt
	frame.owner = owner
	frame.retained = retained
	frame.promise = promise
	frame.token = token
	frame.resume_value = rt.undefined_value
	frame.arguments = new list[js_value*]
	frame.roots = new list[js_value*]
	frame.remaining = rt.remaining
	frame.completion.value = rt.undefined_value
	frame.completion.message = c""
	frame.empty = 1
	token.host_context = frame
	frame.fiber = js_async_body(frame)
	gen_set_stack_size(frame.fiber, 262144)
	rt.async_stack_bytes = rt.async_stack_bytes + 262144
	rt.async_tasks.push(frame)
	return frame


js_value* js_runtime_async_start(js_runtime* rt, js_async_entry* entry, void* context, void* owner, js_value* retained):
	js_async_frame* frame = js_async_new(rt, owner, retained)
	if (frame == 0): return rt.undefined_value
	frame.entry = entry
	frame.context = context
	js_value* promise = frame.promise
	js_async_resume(frame)
	return promise


js_value* js_runtime_async_call(js_runtime* rt, js_value* callable, js_value* receiver, list[js_value*] args):
	void* owner = 0
	if (rt.active_async != 0):
		js_async_frame* outer = cast(js_async_frame*, rt.active_async)
		owner = outer.owner
	js_async_frame* frame = js_async_new(rt, owner, callable)
	if (frame == 0): return rt.undefined_value
	frame.callable = callable
	frame.receiver = receiver
	for i in range(args.length): frame.arguments.push(args[i])
	js_value* promise = frame.promise
	js_async_resume(frame)
	return promise


# Resume with an uncatchable completion so native temporaries unwind normally.
# Clearing tokens makes queued or subsequently settled reactions harmless.
int js_runtime_async_cancel_owner(js_runtime* rt, void* owner):
	if (rt.running): return 0
	int count = 0
	rt.running = 1
	int i = 0
	while (i < rt.async_tasks.length):
		js_async_frame* frame = cast(js_async_frame*, rt.async_tasks[i])
		if (owner != 0 && frame.owner != owner):
			i = i + 1
			continue
		frame.cancelled = 1
		frame.completion.status = 5
		frame.completion.message = c"JavaScript asynchronous evaluation cancelled"
		frame.completion.value = rt.undefined_value
		js_async_resume(frame)
		count = count + 1
	rt.running = 0
	return count


int js_runtime_async_cancel(js_runtime* rt):
	return js_runtime_async_cancel_owner(rt, 0)
