/*
Small runtime process metadata facade.

Programs call sys_init(argc, argv) when they want sys_executable() and
sys_argc() to reflect their real entry point; sys_argv(argc, argv) is stateless
for tests and one-off helpers.
*/
import lib.lib


list[char*] sys_saved_argv
char* sys_saved_executable


list[char*] sys_argv(int argc, int argv):
	list[char*] out = new list[char*]
	char** words = cast(char**, argv)
	int i = 0
	while (i < argc):
		out.push(words[i])
		i = i + 1
	return out


void sys_init(int argc, int argv):
	sys_saved_argv = sys_argv(argc, argv)
	if (argc > 0):
		sys_saved_executable = sys_saved_argv[0]
	else:
		sys_saved_executable = c""


int sys_argc():
	if (sys_saved_argv == 0):
		return 0
	return sys_saved_argv.length


char* sys_executable():
	if (sys_saved_executable == 0):
		return c""
	return sys_saved_executable


int sys_word_size():
	return __word_size__


char* sys_platform():
	if (__word_size__ == 8):
		return c"linux-x64"
	return c"linux-x86"
