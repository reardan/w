# A W host engine loading W addons at run time through the addon engine
# API (repl/embed.w, docs/projects/scripting.md). Run from the repository
# root, x86 or x64 Linux:
#
#   ./bin/wv2 x64 examples/scripting/addon_host.w -o bin/addon_host
#   bin/addon_host examples/scripting/addon_v1.w examples/scripting/addon_v2.w examples/scripting/addon_bad.w
#
# The addon source is compiled into the engine's JIT buffer at run time;
# the host exposes its API with engine_bind; addon entry points are looked
# up by name and called through the fault window (engine_call*) or, on the
# hot path, directly through a function pointer; a reload rolls the addon
# back and compiles the new source in its place; a rejected reload keeps
# the running version; a fault or a stack overflow inside the addon is
# reported and the host continues. tests/addon_host_test.w runs this
# program and covers the API in detail.
import repl.embed
import lib.file
import lib.time
import structures.json


type addon_int_fn = fn(int) -> int


void pi(int v):
	print(itoa(v))


# ---- the engine's host API: ordinary W functions in the host binary ----
int host_health
int host_log_lines


void host_log(char* message):
	host_log_lines = host_log_lines + 1
	print(c"  [host] addon says: ")
	println(message)


int host_get_health():
	return host_health


void host_set_health(int value):
	if (value < 0): value = 0
	host_health = value


int host_api_install():
	if (engine_bind(c"host_log", c"fn(char*) -> void", cast(int, host_log)) == 0): return 0
	if (engine_bind(c"host_get_health", c"fn() -> int", cast(int, host_get_health)) == 0): return 0
	return engine_bind(c"host_set_health", c"fn(int) -> void", cast(int, host_set_health))


# The engine hands diagnostics back as NDJSON; the host shows them its
# own way.
void show_diagnostics(char* ndjson):
	list[char*] lines = split(ndjson, '\n')
	for line in lines:
		json_value* d = json_parse(line)
		if (d != 0):
			print(c"  [host] ")
			print(json_object_get(d, c"file").string_value)
			print(c":")
			pi(json_object_get(d, c"line").int_value)
			print(c": ")
			print(json_object_get(d, c"severity").string_value)
			print(c": ")
			println(json_object_get(d, c"message").string_value)
			json_free(d)


# ---- loading / reloading the addon from source ----
int addon_load(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		print(c"  [host] cannot read ")
		println(path)
		return 0
	engine_result r = engine_load(c"demo", text)
	free(text)
	print(c"  [host] load ")
	print(path)
	print(c": status=")
	pi(r.status)
	print(c" (")
	pi(r.ms)
	print(c" ms, jit buffer now ")
	pi(codepos)
	println(c" bytes)")
	show_diagnostics(r.diagnostics)
	if (r.status == engine_faulted):
		print(c"  [host] ")
		println(engine_fault_text)
	return r.status == engine_ok


# ---- calling into the addon with fault isolation ----
int addon_call_int(char* name, int arg, int* ok):
	int address = engine_symbol(name)
	*ok = 0
	if (address == 0):
		print(c"  [host] addon has no ")
		println(name)
		return 0
	int result = engine_call1(address, arg, ok)
	if (*ok == 0):
		print(c"  [host] ")
		print(engine_fault_text)
		println(c" -- engine continues")
	return result


void ticks(int from, int to):
	int ok = 0
	for frame in range(from, to):
		int r = addon_call_int(c"on_tick", frame, &ok)
		print(c"  tick ")
		pi(frame)
		print(c" -> ")
		pi(r)
		print(c"  health=")
		pi(host_get_health())
		println(c"")


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 4):
		println(c"usage: addon_host addon_v1.w addon_v2.w addon_bad.w")
		return 2
	host_health = 100
	asserts(c"engine", engine_init(0, 0))
	print(c"engine_init: ")
	pi(engine_init_ms)
	print(c" ms, prelude code+data ")
	pi(codepos)
	println(c" bytes of the JIT buffer")
	asserts(c"host api", host_api_install())

	println(c"-- load v1")
	asserts(c"v1 loads", addon_load(args[1]))
	int ok = 0
	addon_call_int(c"on_load", 0, &ok)
	ticks(0, 5)

	println(c"-- hot reload: v2 replaces the addon (its state starts over)")
	int before = codepos
	asserts(c"v2 loads", addon_load(args[2]))
	addon_call_int(c"on_load", 0, &ok)
	ticks(5, 8)
	print(c"  on_summary: ")
	pi(addon_call_int(c"on_summary", 0, &ok))
	print(c"  (buffer grew ")
	pi(codepos - before)
	println(c" bytes: the old version was released, not shadowed)")

	println(c"-- a broken reload is rejected and the running version stays live")
	int bad = addon_load(args[3])
	asserts(c"bad addon rejected", bad == 0)
	print(c"  on_tick still v2: ")
	pi(addon_call_int(c"on_tick", 100, &ok))
	println(c"")

	println(c"-- faults inside the addon do not kill the engine")
	addon_call_int(c"on_crash", 0, &ok)
	asserts(c"fault reported", ok == 0)
	addon_call_int(c"on_recurse", 100000000, &ok)
	asserts(c"stack overflow reported", ok == 0)
	print(c"  engine alive, on_tick: ")
	pi(addon_call_int(c"on_tick", 101, &ok))
	println(c"")

	println(c"-- call overhead: 1,000,000 calls into the addon")
	int address = engine_symbol(c"on_query")
	addon_int_fn* on_query = cast(addon_int_fn*, address)
	int t0 = time_monotonic_ms()
	int acc = 0
	for i in range(1000000): acc = acc + on_query(i)
	int t1 = time_monotonic_ms()
	for i in range(1000000): acc = acc + engine_call1(address, i, &ok)
	int t2 = time_monotonic_ms()
	print(c"  direct pointer ")
	pi(t1 - t0)
	print(c" ms, engine_call1 ")
	pi(t2 - t1)
	print(c" ms, acc=")
	pi(acc)
	println(c"")
	engine_shutdown()
	println(c"addon host OK")
	return 0
