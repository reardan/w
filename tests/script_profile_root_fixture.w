# An addon importing curated modules from the curated root (bin/addon_root,
# built by script_root_test from tools/script_modules.txt) compiles under
# the script profile: the modules resolve inside the root and compile as
# trusted imports, so their own pointer casts and raw built-ins are not
# the addon's.
# wfixture: --profile=script --import-root=bin/addon_root
# reject_stderr: script profile:
import lib.str
import lib.format
import lib.math
import structures.json
import structures.deque


int main():
	char* text = strjoin(c"hello ", c"addon")
	json_value* v = json_parse(c"{\"hp\": 7}")
	if (v == 0): return 1
	print(f"{text} {max(3, 4)}")
	return 0
