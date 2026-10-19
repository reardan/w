# wbuild: binary=android_check_bridge
# Verify W/C/Java JNI declarations and operation/event numbering.
import tools.host_tools
import libs.standard.text.re

re_result* bridge_search(char* pattern, char* text, int flags):
	re_pattern* compiled = re_compile(pattern, flags)
	ht_require(re_error(compiled) == 0, c"invalid bridge checker pattern")
	return re_search(compiled, text)

list[re_result*] bridge_matches(char* pattern, char* text):
	re_pattern* compiled = re_compile(pattern, RE_MULTILINE)
	ht_require(re_error(compiled) == 0, c"invalid bridge checker pattern")
	return re_finditer(compiled, text)

map[char*, int] bridge_declarations(char* pattern, char* text):
	map[char*, int] found = new map[char*, int]
	for re_result* match in bridge_matches(pattern, text):
		int count = 0
		for char* param in ht_split(re_group(match, 2), ','):
			re_result* content = bridge_search(c"\\S+", param, 0)
			if (content != 0 && strcmp(re_group(content, 0), c"void") != 0): count = count + 1
		found[re_group(match, 1)] = count
	return found

map[char*, int] bridge_constants(char* pattern, char* text):
	map[char*, int] found = new map[char*, int]
	for re_result* match in bridge_matches(pattern, text): found[re_group(match, 1)] = atoi(re_group(match, 2))
	return found

int main():
	char* host = ht_read(c"tools/android/host.c").data
	char* kit = ht_read(c"tools/android/kit.c").data
	char* java = ht_read(c"tools/android/WKit.java").data
	char* activity = ht_read(c"tools/android/WActivity.java").data
	char* wkit = ht_read(c"graphics/android/kit.w").data
	map[char*, int] defined = bridge_declarations(c"^(?:intptr_t|void)\\s+(wandroid_\\w+)\\(([^)]*)\\)\\s*\\{", strjoin(host, kit))
	map[char*, int] declared = bridge_declarations(c"^extern\\s+\\S+\\s+(\\w+)\\((.*)\\)\\s*$", strjoin(ht_read(c"graphics/android/ui.w").data, wkit))
	for char* name in declared.keys():
		ht_require((name in defined), strjoin(name, c" is declared in W but not defined in host.c/kit.c"))
		ht_require(defined[name] == declared[name], strjoin(name, c": W/C parameter count differs"))
	re_result* enum_match = bridge_search(c"enum \\{\\s*(OP_SCREEN = 32,[^}]*)\\}", kit, 0)
	ht_require(enum_match != 0, c"missing C operation enumeration")
	map[char*, int] c_ops = new map[char*, int]
	int value = 31
	for re_result* match in bridge_matches(c"(OP_\\w+)(?:\\s*=\\s*(\\d+))?", re_group(enum_match, 1)):
		value = value + 1
		char* number = re_group(match, 2)
		if (number != 0): value = atoi(number)
		c_ops[re_group(match, 1)] = value
	map[char*, int] java_ops = bridge_constants(c"\\b(OP_\\w+) = (\\d+)", java)
	ht_require(c_ops.length == java_ops.length, c"C/Java operation count differs")
	for char* name in c_ops.keys(): ht_require((name in java_ops) && c_ops[name] == java_ops[name], strjoin(c"C/Java operation differs: ", name))
	for char* name in ht_command(c"GET_TEXT GET_SECURE GET_URI"):
		char* pattern = strjoin(name, c" = (\\d+)")
		re_result* cm = bridge_search(pattern, kit, 0)
		re_result* jm = bridge_search(pattern, java, 0)
		ht_require(cm != 0 && jm != 0 && strcmp(re_group(cm, 1), re_group(jm, 1)) == 0, strjoin(c"C/Java constant differs: ", name))
	list[char*] signatures = ht_split(c"public long kitCall(int op, long a, long b, byte[] s, byte[] t, byte[] u, byte[] v)\npublic byte[] kitBytes(int op, long a, byte[] s)\npublic long addControl(int kind, byte[] bytes)\npublic void setLabel(long handle, byte[] bytes)", 10)
	for char* signature in signatures: ht_require(ht_contains(activity, signature), strjoin(c"WActivity lacks ", signature))
	ht_require(ht_contains(kit, c"\"kitCall\", \"(IJJ[B[B[B[B)J\"") && ht_contains(kit, c"\"kitBytes\", \"(IJ[B)[B\""), c"kit.c JNI signatures do not match WActivity")
	map[char*, int] events = bridge_constants(c"const int android_event_(\\w+) = (\\d+)", wkit)
	for re_result* match in bridge_matches(c"EVENT_(\\w+) = (\\d+)", java):
		char* name = re_group(match, 1)
		for i in range(strlen(name)):
			if (name[i] >= 'A' && name[i] <= 'Z'): name[i] = name[i] + 32
		if (strcmp(name, c"click") == 0 || strcmp(name, c"text") == 0): continue
		ht_require((name in events) && events[name] == atoi(re_group(match, 2)), strjoin(c"W/Java event differs: ", name))
	println(strjoin(strjoin(strjoin(strjoin(c"Android bridge: ", itoa(declared.length)), c" W externs, "), itoa(c_ops.length)), c" kit operations: OK"))
	return 0
