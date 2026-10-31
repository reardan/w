# wbuild: binary=script_root
/*
script_root: build and check the curated addon import root
(docs/projects/scripting.md, Phase P1).

	bin/script_root <wv2> <manifest> <outdir>

Copies every 'module' and 'runtime' file listed in <manifest>
(tools/script_modules.txt, which documents the line forms) to
<outdir>/<path>, replacing whatever <outdir> held. It then proves the
root closed: for x86 and x64 it writes a probe program next to <outdir>
that imports every 'module' and uses each on-demand runtime (print,
f-strings with float and float64, to_json, var), and runs

	<wv2> [x64] deps --import-root <outdir> <probe>

Every file the compile opened must lie inside <outdir>: a file that
resolved through the upward search is a dependency the manifest lacks
(a curated module that reaches a capability module, or a runtime file
that is missing). A listed file that no probe opened is reported too,
so the manifest stays exact. Prints "script_root OK: <n> modules,
<m> files" and exits 0, or prints one FAIL line per problem and exits 1.

Run from the checkout root (the manifest's paths are repository
relative). The script_root_test target (directives at the end of this
file) builds bin/addon_root/ this way, then compiles the addon fixtures
that need it ('--profile=script --import-root=bin/addon_root', see
tests/script_profile_root_fixture.w) and runs every script-profile
fixture once more under the streaming front end (the
script_profile_error_test fixture group pins the default AST one).
*/
import lib.lib
import lib.file
import lib.dir
import lib.process
import lib.str
import structures.string


int script_root_failed


void script_root_out(char* s):
	write(1, s, strlen(s))


void script_root_fail(char* what, char* detail):
	script_root_out(c"FAIL: ")
	script_root_out(what)
	script_root_out(detail)
	script_root_out(c"\n")
	script_root_failed = 1


# mkdir -p of every directory above path (the file itself excluded).
void script_root_make_parents(char* path):
	char* copy = strclone(path)
	int i = 1
	while (copy[i] != 0):
		if (copy[i] == '/'):
			copy[i] = 0
			mkdir(copy, 493)
			copy[i] = '/'
		i = i + 1
	free(copy)


int script_root_copy(char* from, char* to):
	char* text = file_read_text(from)
	if (text == 0): return 0
	script_root_make_parents(to)
	int ok = file_write_text(to, text)
	free(text)
	return ok


# 'lib/format.w' -> 'lib.format'
char* script_root_dotted(char* path):
	char* dotted = strclone(path)
	int n = strlen(dotted)
	if (ends_with(dotted, c".w")): dotted[n - 2] = 0
	for i in range(n):
		if (dotted[i] == '/'): dotted[i] = '.'
	return dotted


char* script_root_probe_text(list[char*] modules, int wide):
	string_builder* s = string_new()
	for char* m in modules:
		string_append(s, c"import ")
		string_append(s, script_root_dotted(m))
		string_append(s, c"\n")
	string_append(s, c"\n\nstruct script_root_probe_point:\n\tint x\n\n\n")
	string_append(s, c"int main():\n\tscript_root_probe_point p\n\tp.x = 1\n")
	string_append(s, c"\tjson_value* j = to_json(p)\n\tfloat f = 1.5\n")
	string_append(s, c"\tstring t = f\"{p.x} {f}\"\n\tprint(t)\n\tprint(f)\n")
	if (wide): string_append(s, c"\tfloat64 d = 2.5\n\tstring u = f\"{d}\"\n\tprint(u)\n")
	string_append(s, c"\tvar v = 5\n\tprint(v)\n\tif (j == 0): return 1\n\treturn 0\n")
	char* text = s.data
	free(cast(char*, s))
	return text


# Runs one deps probe; marks every listed file it opened in seen.
void script_root_probe(char* wv2, char* outdir, list[char*] modules, char* arch, list[char*] listed, list[int] seen):
	char* probe = strjoin(outdir, strjoin(c"_probe_", strjoin(arch, c".w")))
	file_write_text(probe, script_root_probe_text(modules, strcmp(arch, c"x64") == 0))
	char** argv = strv_new(8)
	int a = 0
	strv_set(argv, a, wv2)
	a = a + 1
	if (strcmp(arch, c"x86") != 0):
		strv_set(argv, a, arch)
		a = a + 1
	strv_set(argv, a, c"deps")
	strv_set(argv, a + 1, c"--import-root")
	strv_set(argv, a + 2, outdir)
	strv_set(argv, a + 3, probe)
	process_result* r = process_run(wv2, argv, 0, 0, 300000)
	if ((r == 0) || (r.status != 0)):
		if (r != 0): script_root_out(r.stderr_text)
		script_root_fail(c"deps probe failed for ", arch)
		return
	char* prefix = strjoin(outdir, c"/")
	list[char*] lines = splitlines(r.stdout_text)
	for char* line in lines:
		if ((line[0] == 0) || (strcmp(line, probe) == 0)): continue
		if (starts_with(line, prefix) == 0):
			script_root_fail(strjoin(arch, c": resolved outside the root (add it or drop the module that imports it): "), line)
			continue
		char* rel = line + strlen(prefix)
		for i in range(listed.length):
			if (strcmp(listed[i], rel) == 0): seen[i] = 1


int main(int argc, int argv):
	if (argc != 4):
		script_root_out(c"usage: script_root <wv2> <manifest> <outdir>\n")
		return 2
	char* wv2 = *cast(char**, argv + __word_size__)
	char* manifest = *cast(char**, argv + 2 * __word_size__)
	char* outdir = *cast(char**, argv + 3 * __word_size__)
	char* text = file_read_text(manifest)
	if (text == 0):
		script_root_fail(c"cannot read ", manifest)
		return 1
	list[char*] listed = new list[char*]
	list[char*] modules = new list[char*]
	for char* line in splitlines(text):
		if ((line[0] == 0) || (line[0] == '#')): continue
		if (starts_with(line, c"module ")):
			listed.push(line + 7)
			modules.push(line + 7)
		else if (starts_with(line, c"runtime ")): listed.push(line + 8)
		else: script_root_fail(c"malformed manifest line: ", line)
	dir_remove_all(outdir)
	mkdir(outdir, 493)
	list[int] seen = new list[int]
	for char* path in listed:
		seen.push(0)
		if (script_root_copy(path, strjoin(outdir, strjoin(c"/", path))) == 0):
			script_root_fail(c"cannot copy ", path)
	if (script_root_failed): return 1
	script_root_probe(wv2, outdir, modules, c"x86", listed, seen)
	script_root_probe(wv2, outdir, modules, c"x64", listed, seen)
	for i in range(listed.length):
		if (seen[i] == 0): script_root_fail(c"listed but no probe opened it: ", listed[i])
	if (script_root_failed): return 1
	script_root_out(f"script_root OK: {modules.length} modules, {listed.length} files\n")
	return 0
# wbuild: target=script_root_test tag=tests dep=wv2 dep=script_root dep=wfixture data=tools/script_modules.txt data=lib/ data=structures/ data=libs/standard/text/ data=code_generator/integer.w
# wbuild: step="bin/script_root bin/wv2 tools/script_modules.txt bin/addon_root" expect_stdout="script_root OK"
# wbuild: step="bin/wfixture bin/wv2 tests/script_profile_root_fixture.w tests/script_profile_root_error_fixture.w"
# wbuild: step="bin/wfixture --streaming bin/wv2 tests/script_profile_asm_error_fixture.w tests/script_profile_c_import_error_fixture.w tests/script_profile_c_lib_error_fixture.w tests/script_profile_cast_int_error_fixture.w tests/script_profile_cast_pointer_error_fixture.w tests/script_profile_extern_error_fixture.w tests/script_profile_import_error_fixture.w tests/script_profile_raw_asm_error_fixture.w tests/script_profile_syscall_error_fixture.w tests/script_profile_thread_error_fixture.w tests/script_profile_unsafe_error_fixture.w tests/script_profile_ok_fixture.w tests/script_profile_root_fixture.w tests/script_profile_root_error_fixture.w"
