# wbuild: binary=cubin_tool
/*
cubin_tool: the cubin-embedding helpers (docs/projects/cuda.md
"Execution notes (cubin embedding)"). Replaces tools/cuda/build_cubin.sh
and tools/cuda/fake_cubin.sh (issue #323 bans shell scripts).

  cubin_tool build <sm_XX|native|wrong> <src.w> <out> [wv2 flags...]
      The W compiler never runs external tools, so this drives the
      three-step flow: compile once with --ptx=<out>.ptx, run
      ptxas -arch=<arch> <out>.ptx -o <out>.cubin, then recompile with
      --cubin-file=<out>.cubin (the PTX stays embedded as the fallback
      when the running GPU rejects the cubin). "native" is GPU 0's
      compute capability from nvidia-smi; "wrong" is an arch GPU 0
      cannot run (SASS only runs on its own major version), for tests.
      $WV2 (default bin/wv2) and $PTXAS (default ptxas) override the
      tools.

  cubin_tool fake <module.ptx> <out-prefix>
      GPU-less fixtures for cuda_cubin_embed_test: minimal stand-in
      cubins that satisfy (or deliberately fail) the compiler's
      --cubin-file checks without ptxas -- a 64-byte ELF64 header
      followed by a string table holding a marker and the PTX dump's
      kernel names:
        <out-prefix>.good.cubin     e_machine EM_CUDA, every .entry name
        <out-prefix>.stale.cubin    last .entry name missing
        <out-prefix>.notcuda.cubin  e_machine EM_X86_64

  cubin_tool scan <file>...
      Prints "<file>: marker" or "<file>: no marker" for each file,
      depending on whether it holds the fake cubins' W_FAKE_CUBIN
      marker (the old "grep -q W_FAKE_CUBIN").
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.stream
import lib.utf8
import structures.string


void cubin_err(char* message):
	wstream* err = stderr_writer()
	stream_write_line(err, message)
	stream_flush(err)


void cubin_usage():
	cubin_err(c"usage: cubin_tool build <sm_XX|native|wrong> <src.w> <out> [wv2 flags...]")
	cubin_err(c"       cubin_tool fake <module.ptx> <out-prefix>")
	cubin_err(c"       cubin_tool scan <file>...")


char* cubin_arg(int argv, int i):
	char** slot = argv + i * __word_size__
	return *slot


char* cubin_concat(char* a, char* b):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	return s.data


int cubin_has_slash(char* name):
	int i = 0
	while (name[i] != 0):
		if (name[i] == '/'):
			return 1
		i = i + 1
	return 0


# The executable path for name: as-is with a slash, else the first
# readable PATH candidate (0 when none).
char* cubin_find(char* name):
	if (cubin_has_slash(name)):
		return name
	char* path = env_get(c"PATH")
	if (path == 0):
		path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != ':') && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length == 0):
			string_append_char(candidate, '.')
		string_append_char(candidate, '/')
		string_append(candidate, name)
		int fd = open(candidate.data, 0, 0)
		if (fd >= 0):
			close(fd)
			return candidate.data
	return 0


char** cubin_vector(list[char*] args):
	char** vector = strv_new(args.length)
	int i = 0
	while (i < args.length):
		strv_set(vector, i, args[i])
		i = i + 1
	return vector


# Runs args with inherited stdio; returns its decoded exit status.
int cubin_run(list[char*] args):
	char* program = cubin_find(args[0])
	if (program == 0):
		cubin_err(cstr(f"cubin_tool: {args[0]}: command not found"))
		return 127
	process* p = process_spawn(program, cubin_vector(args), 0)
	if (p == 0):
		cubin_err(cstr(f"cubin_tool: cannot run {program}"))
		return 126
	return process_wait(p)


# GPU 0's compute capability as digits ("8.9" -> "89"), or 0.
char* cubin_compute_cap():
	list[char*] args = new list[char*]
	args.push(c"nvidia-smi")
	args.push(c"--query-gpu=compute_cap")
	args.push(c"--format=csv,noheader")
	char* program = cubin_find(args[0])
	if (program == 0):
		return 0
	process_result* r = process_run(program, cubin_vector(args), 0, 0, 60000)
	if ((r == 0) || (r.status != 0)):
		return 0
	string_builder* cap = string_new()
	int i = 0
	while ((r.stdout_text[i] != 0) && (r.stdout_text[i] != 10)):
		int c = r.stdout_text[i]
		if ((c >= '0') && (c <= '9')):
			string_append_char(cap, c)
		i = i + 1
	if (cap.length == 0):
		return 0
	return cap.data


char* cubin_env_or(char* name, char* fallback):
	char* value = env_get(name)
	if ((value == 0) || (value[0] == 0)):
		return fallback
	return value


# One wv2 compile: <wv2> x64 --quiet [flags] <src> -o <out> <extra>.
int cubin_compile(char* wv2, int argv, int argc, char* src, char* out, char* extra):
	list[char*] args = new list[char*]
	args.push(wv2)
	args.push(c"x64")
	args.push(c"--quiet")
	for i in range(5, argc):
		args.push(cubin_arg(argv, i))
	args.push(src)
	args.push(c"-o")
	args.push(out)
	args.push(extra)
	return cubin_run(args)


int cubin_build(int argc, int argv):
	char* arch = cubin_arg(argv, 2)
	char* src = cubin_arg(argv, 3)
	char* out = cubin_arg(argv, 4)
	if ((strcmp(arch, c"native") == 0) || (strcmp(arch, c"wrong") == 0)):
		char* cap = cubin_compute_cap()
		if (cap == 0):
			cubin_err(c"cubin_tool: cannot query the GPU compute capability")
			return 1
		if (strcmp(arch, c"native") == 0):
			arch = cubin_concat(c"sm_", cap)
		else if ((strlen(cap) == 2) && (cap[0] == '5')):
			arch = c"sm_75"
		else:
			arch = c"sm_52"
	char* wv2 = cubin_env_or(c"WV2", c"bin/wv2")
	char* ptx = cubin_concat(out, c".ptx")
	char* cubin = cubin_concat(out, c".cubin")
	if (cubin_compile(wv2, argv, argc, src, out, cubin_concat(c"--ptx=", ptx)) != 0):
		return 1
	list[char*] ptxas = new list[char*]
	ptxas.push(cubin_env_or(c"PTXAS", c"ptxas"))
	ptxas.push(cubin_concat(c"-arch=", arch))
	ptxas.push(ptx)
	ptxas.push(c"-o")
	ptxas.push(cubin)
	if (cubin_run(ptxas) != 0):
		return 1
	if (cubin_compile(wv2, argv, argc, src, out, cubin_concat(c"--cubin-file=", cubin)) != 0):
		return 1
	return 0


# 1 when the len bytes at s equal those at prefix.
int cubin_bytes_equal(char* s, char* prefix, int len):
	for i in range(len):
		if (s[i] != prefix[i]):
			return 0
	return 1


int cubin_ident_char(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9')) || (c == '_')


# The kernel names of every ".entry <name>(" in the PTX text, in order.
list[char*] cubin_entries(char* text):
	list[char*] names = new list[char*]
	int i = 0
	while (text[i] != 0):
		if (cubin_bytes_equal(text + i, c".entry ", 7)):
			int start = i + 7
			int end = start
			while (cubin_ident_char(text[end])):
				end = end + 1
			if ((end > start) && (text[end] == '(')):
				string_builder* name = string_new()
				for j in range(start, end):
					string_append_char(name, text[j])
				names.push(name.data)
			i = end
		else:
			i = i + 1
	return names


# Writes a fake cubin: ELF64 LE header with e_machine, zero padded to
# 64 bytes, then "\0W_FAKE_CUBIN\0" and each name NUL-terminated.
int cubin_write_fake(char* path, int machine, list[char*] names, int count):
	string_builder* image = string_new()
	int header = 64
	int i = 0
	while (i < header):
		string_append_char(image, 1)
		i = i + 1
	char* h = image.data
	i = 0
	while (i < header):
		h[i] = 0
		i = i + 1
	h[0] = 127
	h[1] = 'E'
	h[2] = 'L'
	h[3] = 'F'
	h[4] = 2
	h[5] = 1
	h[6] = 1
	h[16] = 2
	h[18] = machine
	string_append_char(image, 1)
	image.data[64] = 0
	string_append(image, c"W_FAKE_CUBIN")
	string_append_char(image, 1)
	image.data[image.length - 1] = 0
	i = 0
	while (i < count):
		string_append(image, names[i])
		string_append_char(image, 1)
		image.data[image.length - 1] = 0
		i = i + 1
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	if (fd < 0):
		cubin_err(cstr(f"cubin_tool: cannot write {path}"))
		return 1
	int ok = write(fd, image.data, image.length) == image.length
	close(fd)
	if (ok == 0):
		cubin_err(cstr(f"cubin_tool: cannot write {path}"))
		return 1
	return 0


int cubin_fake(char* ptx, char* prefix):
	char* text = file_read_text(ptx)
	if (text == 0):
		cubin_err(cstr(f"cubin_tool: cannot read {ptx}"))
		return 1
	list[char*] names = cubin_entries(text)
	if (names.length == 0):
		cubin_err(cstr(f"cubin_tool: no .entry kernels in {ptx}"))
		return 1
	# 190 = EM_CUDA, 62 = EM_X86_64
	if (cubin_write_fake(cubin_concat(prefix, c".good.cubin"), 190, names, names.length)):
		return 1
	if (cubin_write_fake(cubin_concat(prefix, c".stale.cubin"), 190, names, names.length - 1)):
		return 1
	return cubin_write_fake(cubin_concat(prefix, c".notcuda.cubin"), 62, names, names.length)


# 1 when the file's bytes contain needle (binary safe).
int cubin_file_contains(char* path, char* needle):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return -1
	string_builder* data = string_new()
	char* buf = malloc(65536)
	int n = read(fd, buf, 65536)
	while (n > 0):
		for i in range(n):
			string_append_char(data, buf[i])
		n = read(fd, buf, 65536)
	free(buf)
	close(fd)
	int len = strlen(needle)
	int at = 0
	while (at + len <= data.length):
		if (cubin_bytes_equal(data.data + at, needle, len)):
			return 1
		at = at + 1
	return 0


int cubin_scan(int argc, int argv):
	int failed = 0
	for i in range(2, argc):
		char* path = cubin_arg(argv, i)
		int found = cubin_file_contains(path, c"W_FAKE_CUBIN")
		if (found < 0):
			cubin_err(cstr(f"cubin_tool: cannot read {path}"))
			failed = 1
		else if (found):
			println(cstr(f"{path}: marker"))
		else:
			println(cstr(f"{path}: no marker"))
	return failed


int main(int argc, int argv):
	if (argc < 2):
		cubin_usage()
		return 2
	char* mode = cubin_arg(argv, 1)
	if ((strcmp(mode, c"build") == 0) && (argc >= 5)):
		return cubin_build(argc, argv)
	if ((strcmp(mode, c"fake") == 0) && (argc == 4)):
		return cubin_fake(cubin_arg(argv, 2), cubin_arg(argv, 3))
	if ((strcmp(mode, c"scan") == 0) && (argc >= 3)):
		return cubin_scan(argc, argv)
	cubin_usage()
	return 2
