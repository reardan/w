import lib.lib
import structures.array_list


struct future:
	int state
	void* result
	char* error
	array_list* callbacks


type future_done_cb = fn(future*, void*) -> void


struct future_callback:
	future_done_cb* callback
	void* context


int future_pending():
	return 0


int future_running():
	return 1


int future_cancelled():
	return 2


int future_finished():
	return 3


int future_failed():
	return 4


future* future_new():
	future* f = new future()
	f.state = future_pending()
	f.result = 0
	f.error = 0
	f.callbacks = array_list_new()
	return f


void future_free(future* f):
	int i = 0
	while (i < f.callbacks.length):
		free(cast(void*, array_list_get(f.callbacks, i)))
		i = i + 1
	array_list_free(f.callbacks)
	free(f)


int future_state(future* f):
	return f.state


int future_done(future* f):
	return (f.state == future_cancelled()) | (f.state == future_finished()) | (f.state == future_failed())


void* future_result(future* f):
	if (f.state != future_finished()):
		return 0
	return f.result


char* future_error(future* f):
	if (f.state != future_failed()):
		return 0
	return f.error


void future_invoke_callbacks(future* f):
	int i = 0
	while (i < f.callbacks.length):
		future_callback* cb = cast(future_callback*, array_list_get(f.callbacks, i))
		cb.callback(f, cb.context)
		i = i + 1


int future_add_done_callback(future* f, future_done_cb* cb, void* ctx):
	if (future_done(f)):
		cb(f, ctx)
		return 1
	future_callback* entry = new future_callback()
	entry.callback = cb
	entry.context = ctx
	array_list_push(f.callbacks, cast(int, entry))
	return 1


int future_set_running(future* f):
	if (f.state != future_pending()):
		return 0
	f.state = future_running()
	return 1


int future_set_result(future* f, void* result):
	if ((f.state != future_pending()) & (f.state != future_running())):
		return 0
	f.result = result
	f.error = 0
	f.state = future_finished()
	future_invoke_callbacks(f)
	return 1


int future_set_error(future* f, char* error):
	if ((f.state != future_pending()) & (f.state != future_running())):
		return 0
	f.result = 0
	f.error = error
	f.state = future_failed()
	future_invoke_callbacks(f)
	return 1


int future_cancel(future* f):
	if ((f.state != future_pending()) & (f.state != future_running())):
		return 0
	f.result = 0
	f.error = 0
	f.state = future_cancelled()
	future_invoke_callbacks(f)
	return 1
