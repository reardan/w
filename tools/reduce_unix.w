# Failing-program reduction: the user-supplied predicate defines interestingness.
# Imported by compiler.cli; all syntax here must bootstrap with the seed.
import lib.file
import lib.process
import tools.reduce_common


struct reduce_context:
	char* scratch
	int scratch_fd
	char* program
	char** arguments
	int timeout_ms
	int max_tests
	int tests
	int failed
	int timed_out


# Bound options to prevent overflow on the 32-bit bootstrap compiler.
int reduce_positive(char* text):
	int n = 0
	int i = 0
	while (text[i] != 0):
		if ((text[i] < '0') || (text[i] > '9')): return 0
		if (n > 99999): return 0
		n = n * 10 + text[i] - '0'
		i = i + 1
	return n


# Candidate output is discarded rather than accumulated, so a noisy predicate
# cannot exhaust reducer memory. Every invocation gets its own process group.
int reduce_interesting(reduce_context* ctx, char* source):
	if (ctx.tests >= ctx.max_tests): return 0
	if (seek(ctx.scratch_fd, 0, 0) < 0):
		ctx.failed = 1
		return 0
	int length = strlen(source)
	if (sys_ftruncate(ctx.scratch_fd, length) < 0):
		ctx.failed = 1
		return 0
	io_result result
	if (io_write_all(ctx.scratch_fd, source, length, &result) != IO_OK):
		ctx.failed = 1
		return 0
	ctx.tests = ctx.tests + 1
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_null
	opts.stderr_mode = process_null
	opts.new_group = 1
	process* child = process_spawn(ctx.program, ctx.arguments, opts)
	free(opts)
	if (child == 0):
		ctx.failed = 1
		return 0
	int status = process_wait_or_kill(child, ctx.timeout_ms)
	process_free(child)
	ctx.timed_out = status == process_status_timeout
	if ((status < 0) && (ctx.timed_out == 0)): ctx.failed = 1
	return status == 0


# Byte offsets retain original newlines, CRLF and a missing final newline.
list[int] reduce_lines(char* source):
	list[int] starts = new list[int]
	starts.push(0)
	int i = 0
	while (source[i] != 0):
		i = i + 1
		if (source[i - 1] == '\n'): starts.push(i)
	if (starts[starts.length - 1] != i): starts.push(i)
	return starts


int reduce_indent(char* source, int start, int end):
	int width = 0
	int i = start
	while (i < end):
		if (source[i] == '\t'): width = width + 8
		else if (source[i] == ' '): width = width + 1
		else if ((source[i] == '\n') || (source[i] == '\r') || (source[i] == '#')): return -1
		else: return width
		i = i + 1
	return -1


char* reduce_without(char* source, int start, int end):
	string_builder* candidate = string_new()
	string_append_bytes(candidate, source, start)
	string_append(candidate, source + end)
	char* text = candidate.data
	free(candidate)
	return text


int reduce_can_test(reduce_context* ctx):
	return (ctx.failed == 0) && (ctx.tests < ctx.max_tests)


# First remove a declaration/statement with its indented descendants. This
# keeps whole function and control-flow bodies together without requiring the
# failing input to parse. The predicate decides whether syntax must survive.
char* reduce_blocks(reduce_context* ctx, char* source):
	list[int] starts = reduce_lines(source)
	int i = 0
	while ((i + 1 < starts.length) && reduce_can_test(ctx)):
		int indent = reduce_indent(source, starts[i], starts[i + 1])
		int end = i + 1
		if (indent >= 0):
			while (end + 1 < starts.length):
				int next = reduce_indent(source, starts[end], starts[end + 1])
				if ((next >= 0) && (next <= indent)): break
				end = end + 1
		if (end > i + 1):
			char* candidate = reduce_without(source, starts[i], starts[end])
			if (reduce_interesting(ctx, candidate)):
				free(source)
				source = candidate
				__w_list_free(cast(__w_list*, starts))
				starts = reduce_lines(source)
				continue
			free(candidate)
		i = i + 1
	__w_list_free(cast(__w_list*, starts))
	return source


# Delta debugging over contiguous line chunks, ending with individual lines.
# Restart coarse partitions after accepting a deletion; never retain a rejected
# candidate. The outer fixed-point loop retries blocks after line reductions.
char* reduce_chunks(reduce_context* ctx, char* source):
	list[int] starts = reduce_lines(source)
	int count = starts.length - 1
	int granularity = 2
	while ((count > 0) && reduce_can_test(ctx)):
		if (granularity > count): granularity = count
		int chunk = (count + granularity - 1) / granularity
		int i = 0
		int accepted = 0
		while ((i < count) && reduce_can_test(ctx)):
			int end = i + chunk
			if (end > count): end = count
			char* candidate = reduce_without(source, starts[i], starts[end])
			if (reduce_interesting(ctx, candidate)):
				free(source)
				source = candidate
				accepted = 1
				break
			free(candidate)
			i = end
		if (accepted):
			__w_list_free(cast(__w_list*, starts))
			starts = reduce_lines(source)
			count = starts.length - 1
			if (granularity > 2): granularity = granularity - 1
		else:
			if (granularity >= count): break
			granularity = granularity * 2
	__w_list_free(cast(__w_list*, starts))
	return source


# Reject binary input rather than silently reducing only its prefix before NUL.
char* reduce_read_input(char* path):
	wstream* input = stream_open_read(path)
	if (input == 0): return 0
	string_builder* source = string_new()
	io_result result
	int status = stream_read_all_checked(input, source, &result)
	stream_close(input)
	if ((status != IO_OK) || (strlen(source.data) != source.length)):
		string_free(source)
		return 0
	char* text = source.data
	free(source)
	return text


int reduce_main(int argc, int argv):
	char** args = cast(char**, argv)
	if ((argc == 3) && ((strcmp(args[2], c"--help") == 0) || (strcmp(args[2], c"-h") == 0))):
		reduce_usage()
		return 0
	if (argc < 5):
		reduce_usage()
		return 1
	char* input = args[2]
	char* output = 0
	int timeout_ms = 10000
	int max_tests = 1000
	int p = 3
	while ((p < argc) && (strcmp(args[p], c"--") != 0)):
		if (p + 1 >= argc): return reduce_error(c"option needs a value")
		char* option = args[p]
		char* value = args[p + 1]
		if (strcmp(option, c"-o") == 0): output = value
		else if (strcmp(option, c"--timeout-ms") == 0):
			timeout_ms = reduce_positive(value)
			if (timeout_ms == 0): return reduce_error(c"invalid --timeout-ms (expected 1..999999)")
		else if (strcmp(option, c"--max-tests") == 0):
			max_tests = reduce_positive(value)
			if (max_tests == 0): return reduce_error(c"invalid --max-tests (expected 1..999999)")
		else: return reduce_error(c"unknown option")
		p = p + 2
	if (p + 1 >= argc): return reduce_error(c"expected -- and a predicate command")
	p = p + 1
	string_builder* output_name = string_from(input)
	string_append(output_name, c".reduced.w")
	if (output == 0): output = output_name.data
	char* source = reduce_read_input(input)
	if (source == 0):
		string_free(output_name)
		return reduce_error(c"cannot read input as text (embedded NUL is unsupported)")
	reduce_context ctx
	ctx.scratch_fd = -1
	ctx.program = process_which(args[p])
	ctx.timeout_ms = timeout_ms
	ctx.max_tests = max_tests
	ctx.tests = 0
	ctx.failed = 0
	ctx.timed_out = 0
	int result = 0
	if (ctx.program == 0): result = reduce_error(c"predicate command not found")
	# Sibling placement preserves source-relative imports. O_EXCL rejects both
	# existing files and symlinks; PID plus a counter allows concurrent reducers.
	string_builder* scratch = string_new()
	int attempt = 0
	while ((result == 0) && (ctx.scratch_fd < 0) && (attempt < 100)):
		string_clear(scratch)
		string_append(scratch, input)
		string_append(scratch, c".reduce-")
		string_append_int(scratch, getpid())
		string_append_char(scratch, '-')
		string_append_int(scratch, attempt)
		string_append(scratch, c".w")
		ctx.scratch_fd = open(scratch.data, 194, 384)
		attempt = attempt + 1
	if ((result == 0) && (ctx.scratch_fd < 0)): result = reduce_error(c"cannot create candidate beside input")
	ctx.scratch = scratch.data
	ctx.arguments = strv_new(argc - p + 1)
	int n = 0
	int substituted = 0
	while (p < argc):
		char* argument = args[p]
		if (strcmp(argument, c"{}") == 0):
			argument = ctx.scratch
			substituted = 1
		strv_set(ctx.arguments, n, argument)
		n = n + 1
		p = p + 1
	if (substituted == 0): strv_set(ctx.arguments, n, ctx.scratch)
	int original_size = strlen(source)
	if ((result == 0) && (reduce_interesting(&ctx, source) == 0)):
		if (ctx.timed_out): result = reduce_error(c"initial predicate timed out")
		else: result = reduce_error(c"initial predicate must exit 0")
	if (result == 0):
		int previous = -1
		while ((previous != strlen(source)) && reduce_can_test(&ctx)):
			previous = strlen(source)
			source = reduce_blocks(&ctx, source)
			source = reduce_chunks(&ctx, source)
		if (ctx.failed): result = reduce_error(c"candidate I/O or predicate process failed")
	if (result == 0):
		# Exclusive creation protects the original even through hardlink/symlink
		# aliases. Never truncate a user-selected path.
		int fd = open(output, 193, 420)
		if (fd < 0): result = reduce_error(c"output exists or cannot be created")
		else:
			io_result written
			int ok = io_write_all(fd, source, strlen(source), &written) == IO_OK
			if (close(fd) < 0): ok = 0
			if (ok == 0):
				unlink(output)
				result = reduce_error(c"cannot write output")
	if (result == 0):
		print(c"w reduce: ")
		print(itoa(original_size))
		print(c" -> ")
		print(itoa(strlen(source)))
		print(c" bytes, ")
		print(itoa(ctx.tests))
		print(c" predicate tests; ")
		println(output)
		if (ctx.tests >= ctx.max_tests): println(c"w reduce: test limit reached; saved best accepted candidate")
	if (ctx.scratch_fd >= 0):
		close(ctx.scratch_fd)
		unlink(ctx.scratch)
	free(cast(char*, ctx.arguments))
	free(source)
	string_free(scratch)
	string_free(output_name)
	return result
