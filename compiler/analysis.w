# Opt-in multi-error checking. Each declaration/statement is first analyzed
# in a forked copy of the compiler. A failed probe cannot leave partially
# updated symbols, types, code, imports or AST ownership in its parent.
# Successful probes are replayed with probing disabled. This deliberately
# pays replay cost for isolation while production parsing still emits code.
# No executable is ever written by check mode, including successful probes.
int analysis_mode
int analysis_errors
int analysis_probe_base
int analysis_limit_hit


# error() can terminate a callback after some nested statements recovered.
# Preserve their count along with the final error instead of reducing the
# whole callback to status 1. 126 propagates the already-reported global
# limit through every enclosing probe without restarting recovery there.
int analysis_failure_status():
	if (analysis_limit_hit): return 126
	int failures = analysis_errors - analysis_probe_base + 1
	if (failures > 125): failures = 125
	return failures


# Recover at the next sibling statement/declaration. The production lexer
# keeps comments and quoted strings opaque; delimiters inside them do not
# affect this scan. Lexical errors during synchronization remain fatal.
void analysis_skip(int declaration):
	int start = token_start_offset
	int indent = tab_level
	if (declaration): indent = 0
	int braces = 0
	int parens = 0
	int brackets = 0
	while (token[0]):
		if (peek(c"{")): braces = braces + 1
		if (peek(c"(")): parens = parens + 1
		if (peek(c"[")): brackets = brackets + 1
		if (peek(c"}")):
			if (braces == 0):
				# Preserve a containing block's delimiter, but consume an
				# unmatched delimiter that was itself the failing item.
				if (declaration || (token_start_offset == start)): get_token()
				return
			braces = braces - 1
		if (peek(c")") && (parens > 0)): parens = parens - 1
		if (peek(c"]") && (brackets > 0)): brackets = brackets - 1
		int semicolon = peek(c";")
		get_token()
		if ((braces == 0) && (parens == 0) && (brackets == 0)):
			if (semicolon): return
			if (peek(c"}") && (declaration == 0)): return
			if (token_newline && (tab_level <= indent)):
				# else/elif belongs to the failing construct, not its sibling.
				if ((peek(c"else") == 0) && (peek(c"elif") == 0)): return


void analysis_run(int operation, int declaration):
	if ((analysis_mode == 0) || (token[0] == 0)):
		operation()
		return
	# fork shares the kernel's open-file offset, but not getchar's userspace
	# buffer. Restore that offset exactly, retaining the parent's buffer.
	int source_fd = file
	int kernel_offset = seek(source_fd, 0, 1)
	if (kernel_offset < 0): error(c"--all-errors requires seekable source files")
	int before = analysis_errors
	char[8] descriptors
	if (pipe(cast(int*, &descriptors)) < 0): error(c"could not create semantic analysis boundary pipe")
	int boundary_read = load_int32(cast(char*, &descriptors))
	int boundary_write = load_int32(cast(char*, &descriptors) + 4)
	int child = fork()
	if (child < 0): error(c"could not fork semantic analysis probe")
	if (child == 0):
		close(boundary_read)
		analysis_probe_depth = analysis_probe_depth + 1
		analysis_probe_base = before
		analysis_probe_error_status = cast(int, analysis_failure_status)
		operation()
		# A compound item can finish after its children recovered errors.
		# Its exact endpoint prevents re-reporting a script suffix or an
		# inline block whose lexical shape has no declaration boundary.
		int boundary = token_start_offset
		write(boundary_write, cast(char*, &boundary), __word_size__)
		close(boundary_write)
		int failures = analysis_errors - before
		if (failures > 125): failures = 125
		exit(failures)
	close(boundary_write)
	int status = 0
	int waited = wait4(child, &status, 0, 0)
	while (waited == -4): waited = wait4(child, &status, 0, 0)
	if (waited < 0): error(c"could not wait for semantic analysis probe")
	int boundary = -1
	int received = read(boundary_read, cast(char*, &boundary), __word_size__)
	while (received == -4): received = read(boundary_read, cast(char*, &boundary), __word_size__)
	close(boundary_read)
	if (seek(source_fd, kernel_offset, 0) < 0): error(c"could not restore analysis source position")
	if ((status & 127) != 0): error(c"semantic analysis probe terminated unexpectedly")
	int failures = (status >> 8) & 255
	if (failures == 126):
		if (analysis_probe_depth): exit(126)
		exit(1)
	if (failures == 0):
		analysis_mode = 0
		operation()
		analysis_mode = 1
		return
	analysis_errors = analysis_errors + failures
	if (analysis_errors >= 100):
		analysis_limit_hit = 1
		error(c"stopping after 100 semantic errors")
	if ((received == __word_size__) && (boundary > token_start_offset)):
		while (token[0] && (token_start_offset < boundary)): get_token()
		return
	analysis_skip(declaration)
