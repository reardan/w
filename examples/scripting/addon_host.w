# Prototype of a W host engine loading W addons at run time
# (docs/projects/scripting.md). Run from the repository root, x64 Linux:
#
#   ./bin/wv2 x64 examples/scripting/addon_host.w -o bin/addon_host
#   bin/addon_host examples/scripting/addon_v1.w examples/scripting/addon_v2.w examples/scripting/addon_bad.w
#
# A W "engine" that hosts W "addons" in-process through the
# REPL eval engine (repl/core.w). The addon source is compiled into the
# session's JIT buffer at run time; the host exposes an API through
# function-pointer globals it declares in a prelude entry and fills in by
# symbol address; addon entry points are looked up by name and called
# natively; a redefinition hot-swaps every existing call site (#114);
# a runtime fault in addon code is caught by the engine's fault window.
import repl.core
import lib.file
import lib.time
import lib.format

type addon_void_fn = fn() -> void

void pi(int v):
	print(itoa(v))
type addon_int_fn = fn(int) -> int


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


# ---- binding host symbols into the addon namespace ----
# The prelude declares typed function-pointer globals in the session;
# host_bind() then stores the host function's address into each global's
# storage (REPL globals live in the JIT buffer at their symbol address).
void host_bind(char* name, int address):
	int slot = sym_address(name)
	asserts(c"prelude global missing", slot != 0)
	save_word(cast(char*, slot), address)

int host_api_install():
	repl_result r = repl_eval(c"type __host_log_fn = fn(char*) -> void\ntype __host_get_fn = fn() -> int\ntype __host_set_fn = fn(int) -> void\n__host_log_fn* host_log\n__host_get_fn* host_get_health\n__host_set_fn* host_set_health\n")
	if (r.status != 1): return 0
	host_bind(c"host_log", cast(int, host_log))
	host_bind(c"host_get_health", cast(int, host_get_health))
	host_bind(c"host_set_health", cast(int, host_set_health))
	return 1


# ---- loading / reloading an addon from source ----
# The whole file is one entry: a compile error rolls it back and the host
# keeps running; a successful load (re)defines every function in it and
# repatches earlier call sites to the new definitions.
int addon_load(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		print(c"  [host] cannot read "); println(path)
		return 0
	int t0 = time_monotonic_ms()
	repl_result r = repl_eval(text)
	int t1 = time_monotonic_ms()
	free(text)
	print(c"  [host] load "); print(path); print(c": status="); pi(r.status)
	print(c" ("); pi(t1 - t0); print(c" ms, jit buffer now "); pi(codepos); println(c" bytes)")
	return r.status == 1


# ---- calling into the addon with fault isolation ----
# Mirrors repl_eval's fault window: a SIGSEGV/SIGFPE/... inside the addon
# long-jumps back here instead of killing the engine.
int addon_call_int(char* name, int arg, int* ok):
	int address = sym_defined_address(name)
	*ok = 0
	if (address == 0):
		print(c"  [host] addon has no "); println(name)
		return 0
	repl_fault_tid = repl_gettid()
	repl_fault_active = 1
	if (repl_setjmp(repl_fault_jump_buffer)):
		repl_keep_code = 0
		print(c"  [host] fault inside addon function "); print(name); println(c" -- engine continues")
		return 0
	int result = (cast(addon_int_fn*, address))(arg)
	repl_fault_active = 0
	*ok = 1
	return result


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 4):
		println(c"usage: addon_host addon_v1.w addon_v2.w addon_bad.w")
		return 2
	host_health = 100
	int t0 = time_monotonic_ms()
	repl_init()
	int t1 = time_monotonic_ms()
	print(c"repl_init: "); pi(t1 - t0); print(c" ms, prelude code+data "); pi(codepos); println(c" bytes of the 8 MB JIT buffer")
	asserts(c"host api", host_api_install())
	int t2 = time_monotonic_ms()
	print(c"host api prelude: "); pi(t2 - t1); println(c" ms")

	println(c"-- load v1")
	asserts(c"v1 loads", addon_load(args[1]))
	int ok = 0
	addon_call_int(c"on_load", 0, &ok)
	for frame in range(5):
		int r = addon_call_int(c"on_tick", frame, &ok)
		print(c"  tick "); pi(frame); print(c" -> "); pi(r); print(c"  health="); pi(host_get_health()); println(c"")

	println(c"-- hot reload: v2 redefines on_tick and adds on_crash")
	asserts(c"v2 loads", addon_load(args[2]))
	for frame in range(5, 8):
		int r2 = addon_call_int(c"on_tick", frame, &ok)
		print(c"  tick "); pi(frame); print(c" -> "); pi(r2); print(c"  health="); pi(host_get_health()); println(c"")
	# on_summary was compiled in v1 and calls on_tick: late binding must
	# have repatched it to v2's on_tick.
	print(c"  v1's on_summary after reload: "); pi(addon_call_int(c"on_summary", 0, &ok)); println(c"")

	println(c"-- a broken reload is rejected and the previous version stays live")
	int bad = addon_load(args[3])
	asserts(c"bad addon rejected", bad == 0)
	print(c"  on_tick still v2: "); pi(addon_call_int(c"on_tick", 100, &ok)); println(c"")

	println(c"-- a runtime fault inside the addon does not kill the engine")
	addon_call_int(c"on_crash", 0, &ok)
	asserts(c"fault reported", ok == 0)
	print(c"  engine alive, on_tick: "); pi(addon_call_int(c"on_tick", 101, &ok)); println(c"")

	println(c"-- call overhead: 1,000,000 native calls into the addon")
	int address = sym_defined_address(c"on_query")
	addon_int_fn* on_query = cast(addon_int_fn*, address)
	int t3 = time_monotonic_ms()
	int acc = 0
	for i in range(1000000): acc = acc + on_query(i)
	int t4 = time_monotonic_ms()
	print(c"  "); pi(t4 - t3); print(c" ms total, acc="); pi(acc); println(c"")
	repl_cleanup()
	println(c"addon host OK")
	return 0
