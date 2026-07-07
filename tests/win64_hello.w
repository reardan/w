# Smoke test for the win64 PE backend: compiled with `w win64`, runs
# under Wine or Windows. Exercises console output through kernel32
# WriteFile, the malloc heap (VirtualAlloc-backed brk) and the
# GetCommandLineA argv startup path.
import lib.lib


int main(int argc, char** argv):
	println(c"hello from win64!")
	print_int(c"argc: ", argc)
	char* copy = malloc(64)
	strcpy(copy, c"heap works")
	println(str_from_cstr(copy))
	return 0
