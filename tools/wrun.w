# wbuild: binary=wrun
/*
wrun: exec a cross-target binary under the runner its target needs.

Usage:
  bin/wrun arm64 <binary> [args...]
  bin/wrun wasm <module.wasm> [args...]
  bin/wrun node <script.mjs> [args...]

Replaces the former tools/run_arm64.sh, tools/run_wasm.sh and
tools/web/run_node.sh shims (issue #323 bans shell scripts). Every mode
execve()s its runner in place of this process with the current
environment, so exit status, signals and stdio stay exactly the
runner's own -- nothing is spawned and waited on.

- arm64: an aarch64-Linux binary runs natively when the host kernel is
  aarch64 (the w-dev container), otherwise under
  $QEMU_ARM64 (split on whitespace) or the default
  `qemu-aarch64-static -cpu max`. The host is read from
  /proc/sys/kernel/arch rather than uname(2): this binary is usually a
  32-bit x86 build, and under qemu-user emulation (binfmt, as in the
  arm64 container) uname reports the emulated machine, while /proc
  reports the real kernel's.
- wasm: wasmtime on PATH -> `wasmtime run --dir . <module> args`, else
  node on PATH -> `node --no-warnings <root>/tools/run_wasm.mjs <module>
  args` (Node's built-in WASI, node >= 20), where <root> is the parent
  of this binary's directory ("bin/wrun" -> "tools/run_wasm.mjs",
  the old `$(dirname $0)/run_wasm.mjs`). The current directory is the
  guest's preopened filesystem root, matching the
  lib/__arch__/wasm/syscalls.w path convention.
- node: node on PATH -> `node --no-warnings <script> args`. The
  tools/web host scripts (run_env_test.mjs, run_webgl_stub.mjs, ...)
  provide custom "env" import modules and drive table callbacks, which
  the wasmtime CLI cannot, so there is no wasmtime fallback.

PATH lookup mirrors tools/wexec.w's wexec_resolve_program_search: a
name containing '/' is used as-is, otherwise the first PATH entry
(an empty entry meaning the current directory) holding a readable,
executable, non-directory file wins.
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.stat
import lib.stream
import lib.utf8
import structures.string


void wrun_err(char* message):
	wstream* err = stderr_writer()
	stream_write_line(err, message)
	stream_flush(err)


void wrun_usage():
	wrun_err(c"usage: wrun arm64 <binary> [args...]")
	wrun_err(c"       wrun wasm <module.wasm> [args...]")
	wrun_err(c"       wrun node <script.mjs> [args...]")


int wrun_has_slash(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'): return 1
		i = i + 1
	return 0


# Readable (open succeeds) and, when stat works, a non-directory with
# an execute bit. A failed stat keeps readable-implies-usable, the same
# fallback wexec_candidate_is_executable documents for platforms whose
# stat stubs fail.
int wrun_usable(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	close(fd)
	file_stat st
	if (file_stat_path(path, &st) != 0): return 1
	if ((st.mode & FILE_S_IFMT) == FILE_S_IFDIR): return 0
	# 73 = 0111: executable by owner, group, or other.
	return (st.mode & 73) != 0


# The executable path for name, or 0 when PATH has none.
char* wrun_find(char* name):
	if (wrun_has_slash(name)):
		return name
	char* path = env_get(c"PATH")
	if (path == 0): path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0): at_end = 1
		else: p = p + 1
		if (candidate.length == 0): string_append_char(candidate, '.')
		string_append_char(candidate, '/')
		string_append(candidate, name)
		if (wrun_usable(candidate.data)):
			char* found = candidate.data
			free(candidate)
			return found
	string_free(candidate)
	return 0


# execve argv in place of this process; only returns on failure, with
# the shell's exit status for a command that cannot be run.
int wrun_exec(list[char*] argv):
	char* program = wrun_find(argv[0])
	if (program == 0):
		wrun_err(cstr(f"wrun: {argv[0]}: command not found"))
		return 127
	char** vector = strv_new(argv.length)
	int i = 0
	while (i < argv.length):
		strv_set(vector, i, argv[i])
		i = i + 1
	execve(program, vector, env_current())
	wrun_err(cstr(f"wrun: cannot execute {program}"))
	return 126


# Appends argv[from..argc) to out.
void wrun_push_rest(list[char*] out, char** argv, int argc, int from):
	for i in range(from, argc): out.push(argv[i])


# Appends text's whitespace-separated words to out.
void wrun_push_words(list[char*] out, char* text):
	int i = 0
	while (text[i] != 0):
		while ((text[i] == ' ') || (text[i] == 9) || (text[i] == 10)): i = i + 1
		if (text[i] == 0): return
		int start = i
		while ((text[i] != 0) && (text[i] != ' ') && (text[i] != 9) && (text[i] != 10)): i = i + 1
		char* word = malloc(i - start + 1)
		int k = 0
		while (k < i - start):
			word[k] = text[start + k]
			k = k + 1
		word[k] = 0
		out.push(word)


# True when the running kernel is aarch64 Linux.
int wrun_host_is_aarch64():
	char* arch = file_read_text(c"/proc/sys/kernel/arch")
	if (arch == 0): return 0
	int n = strlen(arch)
	while ((n > 0) && ((arch[n - 1] == 10) || (arch[n - 1] == ' '))):
		n = n - 1
		arch[n] = 0
	return strcmp(arch, c"aarch64") == 0


int wrun_arm64(char** argv, int argc):
	list[char*] cmd = new list[char*]
	if (wrun_host_is_aarch64() == 0):
		char* qemu = env_get(c"QEMU_ARM64")
		if (qemu != 0): wrun_push_words(cmd, qemu)
		# ${QEMU_ARM64:-...}: unset, empty or blank all mean the default.
		if (cmd.length == 0):
			cmd.push(c"qemu-aarch64-static")
			cmd.push(c"-cpu")
			cmd.push(c"max")
	wrun_push_rest(cmd, argv, argc, 2)
	return wrun_exec(cmd)


# <root>/tools/run_wasm.mjs, <root> being the parent of the directory
# argv[0] names ("bin/wrun" -> "tools/run_wasm.mjs").
char* wrun_wasm_host(char* self):
	int n = strlen(self)
	int slashes = 0
	int cut = n
	while ((cut > 0) && (slashes < 2)):
		cut = cut - 1
		if (self[cut] == '/'): slashes = slashes + 1
	if (slashes < 2): return c"tools/run_wasm.mjs"
	char* root = malloc(cut + 1)
	for i in range(cut): root[i] = self[i]
	root[cut] = 0
	if ((cut == 0) || (strcmp(root, c".") == 0)):
		if (cut == 0): return c"/tools/run_wasm.mjs"
		return c"tools/run_wasm.mjs"
	return cstr(f"{root}/tools/run_wasm.mjs")


int wrun_wasm(char** argv, int argc):
	list[char*] cmd = new list[char*]
	if (wrun_find(c"wasmtime") != 0):
		cmd.push(c"wasmtime")
		cmd.push(c"run")
		cmd.push(c"--dir")
		cmd.push(c".")
		wrun_push_rest(cmd, argv, argc, 2)
		return wrun_exec(cmd)
	if (wrun_find(c"node") != 0):
		cmd.push(c"node")
		cmd.push(c"--no-warnings")
		cmd.push(wrun_wasm_host(argv[0]))
		wrun_push_rest(cmd, argv, argc, 2)
		return wrun_exec(cmd)
	wrun_err(c"wrun: no WASI runtime found (need wasmtime or node)")
	return 1


int wrun_node(char** argv, int argc):
	if (wrun_find(c"node") == 0):
		wrun_err(c"wrun: node not found (the wasm host tests need Node >= 20)")
		return 1
	list[char*] cmd = new list[char*]
	cmd.push(c"node")
	cmd.push(c"--no-warnings")
	wrun_push_rest(cmd, argv, argc, 2)
	return wrun_exec(cmd)


int main(int argc, char** argv):
	if (argc < 3):
		wrun_usage()
		return 2
	char* mode = argv[1]
	if (strcmp(mode, c"arm64") == 0): return wrun_arm64(argv, argc)
	if (strcmp(mode, c"wasm") == 0): return wrun_wasm(argv, argc)
	if (strcmp(mode, c"node") == 0): return wrun_node(argv, argc)
	wrun_err(cstr(f"wrun: unknown mode '{mode}'"))
	wrun_usage()
	return 2
