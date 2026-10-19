# wbuild: binary=wgrind_native_driver
# Exercise actual ELF execution and separately compiled C/assembly, including
# failure provenance, allocator boundaries, threads, permissions, and leaks.
import tools.host_tools
import lib.str

char* wn_folder

char* wn_compile(char* name, char* fixture, char* defines = 0, char* object = 0):
	char* executable = path_join(wn_folder, name)
	list[char*] command = ht_command(c"cc -nostdlib -static -no-pie")
	if (defines != 0):
		for char* define in split(defines): command.push(strjoin(c"-D", define))
	command.push(strjoin(strjoin(c"tests/wgrind_native/", fixture), c".S"))
	if (object != 0): command.push(object)
	command.push(c"-o")
	command.push(executable)
	ht_checked(command)
	return executable

process_result* wn_run(char* executable, int status, char* kind = 0, char* extra = 0, char* input = 0):
	process_result* result = ht_run(ht_argv(c"bin/wgrind_native", executable, extra), 0, input, 45000)
	if (result.status != status):
		print2(result.stderr_text)
		ht_require(0, strjoin(c"unexpected native checker status for ", executable))
	if (kind != 0):
		json_value* first = json_parse(split(result.stderr_text, 10)[0])
		ht_require(first != 0 && strcmp(ht_text(first, c"kind"), kind) == 0, result.stderr_text)
	return result

json_value* wn_first(process_result* result):
	json_value* first = json_parse(split(result.stderr_text, 10)[0])
	ht_require(first != 0, c"invalid native checker diagnostics")
	return first

void wn_summary(json_value* first, char* category, int blocks, int bytes):
	json_value* summary = ht_field(first, category)
	ht_require(ht_number(summary, c"blocks") == blocks && ht_number(summary, c"bytes") == bytes, c"incorrect native leak summary")

int main():
	wn_folder = ht_temp()
	char* library = path_join(wn_folder, c"library.o")
	ht_checked(ht_argv(c"cc", c"-c", c"-O0", c"-fno-stack-protector", c"-fno-pie", c"tests/wgrind_native/library.c", c"-o", library))
	list[char*] names = split(c"clean undefined masked invalid unsupported")
	list[char*] defines = ht_split(c"CLEAN||MASKED|INVALID|CLEAN UNSUPPORTED", '|')
	list[char*] kinds = ht_split(c"|undefined-value||invalid-read|incomplete", '|')
	for i in range(names.length):
		char* executable = wn_compile(names[i], c"entry", defines[i], library)
		int status = 0
		char* kind = 0
		if (kinds[i][0] != 0):
			status = 99
			kind = kinds[i]
		if (i == 4): status = 100
		process_result* result = wn_run(executable, status, kind)
		ht_require(ht_run(ht_argv(tempfile_abspath(c"bin/wgrind"), c"--native-exec", executable), 0, 0, 45000).status == status, c"native launcher exit differs")
		if (kind == 0): ht_require(result.stderr_length == 0, c"clean program produced diagnostics")
		else:
			json_value* first = wn_first(result)
			ht_require(from_hex(ht_text(first, c"site")) != 0, c"missing diagnostic site")
			if (i == 1): ht_require(from_hex(ht_text(first, c"origin")) != 0, c"missing undefined origin")
	char* allocator = path_join(wn_folder, c"allocator.o")
	ht_checked(ht_argv(c"cc", c"-c", c"tests/wgrind_native/allocator.S", c"-o", allocator))
	names = split(c"HEAP_CLEAN HEAP_UNDEFINED HEAP_OVERFLOW HEAP_UAF HEAP_DOUBLE")
	kinds = ht_split(c"|undefined-value|invalid-write|invalid-write|double-free", '|')
	for i in range(names.length):
		char* executable = wn_compile(names[i], c"heap_entry", names[i], allocator)
		int status = 99
		char* kind = kinds[i]
		if (i == 0):
			status = 0
			kind = 0
		process_result* result = wn_run(executable, status, kind)
		if (i == 0): ht_require(result.stderr_length == 0, c"clean heap program produced diagnostics")
		if (i == 2): ht_require(ht_number(wn_first(result), c"offset") == 8, c"incorrect overflow offset")
	names = split(c"LEAK_DIRECT LEAK_REACHABLE LEAK_POSSIBLE")
	kinds = split(c"definitely-lost still-reachable possibly-lost")
	for i in range(names.length):
		int status = 99
		if (i == 1): status = 0
		wn_summary(wn_first(wn_run(wn_compile(names[i], c"leak_entry", names[i], allocator), status)), kinds[i], 1, 8)
	char* shared = path_join(wn_folder, c"library.so")
	ht_checked(ht_argv(c"cc", c"-shared", c"-nostdlib", c"-fPIC", c"-O0", c"-fno-stack-protector", c"tests/wgrind_native/library.c", c"-o", shared))
	char* symbol = 0
	for char* line in split(ht_checked(ht_argv(c"nm", c"-D", shared)).stdout_text, 10):
		if (ends_with(line, c" wgrind_precompiled_load")): symbol = split(line)[0]
	ht_require(symbol != 0, c"missing precompiled shared symbol")
	for clean in range(2):
		char* defs = strjoin(c"SYMBOL=0x", symbol)
		int status = 99
		char* kind = c"undefined-value"
		if (clean):
			defs = strjoin(defs, c" CLEAN")
			status = 0
			kind = 0
		wn_run(wn_compile(strjoin(c"shared_", itoa(clean)), c"shared_entry", defs), status, kind, shared)
	wn_run(wn_compile(c"page_edge", c"page_edge"), 0)
	wn_run(wn_compile(c"page_truncated", c"page_edge", c"TRUNCATED"), 100, c"incomplete")
	wn_run(wn_compile(c"callback", c"heap_entry", c"CALLBACK HEAP_CLEAN", c"tests/wgrind_native/allocator.S"), 100, c"incomplete")
	for clean in range(2):
		char* defs = 0
		int status = 99
		char* kind = c"undefined-value"
		if (clean):
			defs = c"CLEAN"
			status = 0
			kind = 0
		wn_run(wn_compile(strjoin(c"flags_", itoa(clean)), c"syscall_flags", defs), status, kind)
	for char* name in split(c"thread_clean thread_undefined thread_clear_tid thread_leader_exit thread_clone3 thread_tls"):
		int status = 0
		char* kind = 0
		if (strcmp(name, c"thread_undefined") == 0):
			status = 99
			kind = c"undefined-value"
		wn_run(wn_compile(name, name), status, kind)
	wn_run(wn_compile(c"tls_undefined", c"thread_tls", c"UNDEFINED"), 99, c"undefined-value")
	wn_run(wn_compile(c"tls_invalid", c"thread_tls", c"INVALID"), 99, c"invalid-read")
	for fixture in range(2):
		char* name = c"readv_entry"
		defines = ht_split(c"|TAIL|FAILED", '|')
		kinds = ht_split(c"|undefined-value|undefined-value", '|')
		if (fixture):
			name = c"protect_entry"
			defines = ht_split(c"CLEAN||NOACCESS", '|')
			kinds = ht_split(c"|undefined-value|invalid-read", '|')
		for i in range(3):
			int status = 99
			char* kind = kinds[i]
			if (i == 0):
				status = 0
				kind = 0
			wn_run(wn_compile(strjoin(name, itoa(i)), name, defines[i]), status, kind, 0, c"abc")
	char* stripped = path_join(wn_folder, c"stripped")
	ht_checked(ht_argv(c"strip", c"--strip-all", c"-o", stripped, path_join(wn_folder, c"clean")))
	wn_run(stripped, 100)
	char* ignored = wn_compile(c"syscall_ignored", c"syscall_ignored")
	wn_run(ignored, 0, 0, ignored)
	for char* define in ht_split(c"|LOST|REDZONE", '|'):
		int status = 0
		char* category = c"still-reachable"
		if (strcmp(define, c"LOST") == 0):
			status = 99
			category = c"definitely-lost"
		wn_summary(wn_first(wn_run(wn_compile(strjoin(c"thread_leak_", define), c"thread_leaks", define, allocator), status)), category, 1, 8)
	json_value* summary = wn_first(wn_run(wn_compile(c"heap_stack", c"heap_stack"), 0))
	wn_summary(summary, c"still-reachable", 2, 4104)
	ht_require(ht_number(ht_field(summary, c"possibly-lost"), c"blocks") == 0, c"reachable heap stack classified as possibly lost")
	for char* define in ht_split(c"|GS|CWD|GS CWD", '|'): wn_run(wn_compile(strjoin(c"prefix_convert_", replace(define, c" ", c"_")), c"prefix_convert", define), 100, c"incomplete")
	for protect in range(2):
		char* defs = 0
		if (protect): defs = c"PROTECT"
		char* executable = wn_compile(strjoin(c"execute_only_", itoa(protect)), c"execute_only", defs)
		ht_checked(ht_argv(executable))
		wn_run(executable, 100, c"incomplete")
	string_builder* contents = ht_read(path_join(wn_folder, c"clean"))
	int phoff = ht_uint(contents, 32, 8)
	int phsize = ht_uint(contents, 54, 2)
	int phnum = ht_uint(contents, 56, 2)
	for i in range(phnum):
		int at = phoff + i * phsize
		if (ht_uint(contents, at, 4) == 1 && (ht_uint(contents, at + 4, 4) & 1)): store_le32(contents.data + at + 4, 1)
	char* execute_only = path_join(wn_folder, c"initial_execute_only")
	ht_write(execute_only, contents.data, contents.length)
	ht_require(chmod(execute_only, 493) == 0, c"cannot chmod ELF fixture")
	ht_checked(ht_argv(execute_only))
	wn_run(execute_only, 100, c"incomplete")
	for char* content in ht_split(c"|\x7fELF|#!/bin/sh\nexit 0\n", '|'):
		char* bad = path_join(wn_folder, c"bad")
		ht_write(bad, content, strlen(content))
		ht_require(chmod(bad, 493) == 0, c"cannot chmod malformed fixture")
		wn_run(bad, 100)
	ht_cleanup()
	println(c"wgrind native executable checks OK")
	return 0
