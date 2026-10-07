/*
Standalone wdbg binary: all of the debugger lives in debugger/wdbg.w
(and the modules it imports); this wrapper only provides main() so
'make wdbg' produces bin/wdbg. The compiler driver reuses the same
wdbg_main() for 'w --debug file.w'.
*/
import debugger.wdbg
import lib.process


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc >= 2 && strcmp(args[1], c"vm") == 0):
		# Keep the Linux x64 VMM outside the seed compiler/debugger graph.
		# This wrapper only dispatches to the separately built helper.
		int slash = -1
		int i = 0
		while (args[0][i] != 0):
			if (args[0][i] == '/'): slash = i
			i = i + 1
		string_builder* helper = string_new()
		if (slash >= 0): string_append_bytes(helper, args[0], slash + 1)
		else: string_append(helper, c"bin/")
		string_append(helper, c"wvm_debug")
		char** command = strv_new(argc - 1)
		strv_set(command, 0, helper.data)
		for j in range(2, argc): strv_set(command, j - 1, args[j])
		process* child = process_spawn(helper.data, command, 0)
		free(cast(void*, command))
		string_free(helper)
		if (child == 0): return 125
		int status = process_wait(child)
		process_free(child)
		if (status == 127): println(c"wdbg: build the VM helper with ./wbuild wvm_debug")
		return status
	return wdbg_main(argc, argv)
