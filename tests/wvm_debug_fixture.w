# wbuild: binary=wvm_debug_fixture arch=x64
import lib.lib
import lib.thread

int vm_debug_value


int vm_debug_target(int value):
	vm_debug_value = value + 1
	return vm_debug_value


void vm_debug_child(void* arg):
	vm_debug_target(41)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc > 1 && strcmp(args[1], c"fault") == 0):
		char* invalid = cast(char*, 4096)
		return invalid[0]
	if (argc > 1 && strcmp(args[1], c"thread") == 0):
		wthread* worker = thread_spawn(vm_debug_child, 0)
		if (worker == 0): return 12
		thread_join(worker)
	else: vm_debug_target(41)
	if (vm_debug_value != 42): return 13
	println(c"guest debugger fixture")
	return 0
