/*
Assembly function bodies (docs/projects/asm_functions.md).

A function body may open with one or more per-ISA assembly blocks; the
rest of the body is the function's portable W definition:

	int strlen(char* s):
		asm x86:
			"mov edx,[esp+4]"
			...
		asm x64:
			...
		int n = 0
		while (s[n]): n = n + 1
		return n

When a block names the ISA being compiled (x86, x64 or arm64), the
function's entry is that block, assembled frameless under the runtime
stubs' calling convention (code_generator/asm_body.w). The portable body
is skipped, unless the block branches to the reserved label 'portable':
then the portable body is compiled right after the block, with its
ordinary prologue, so an asm fast path can hand the remaining cases
(traps, rare inputs) to W. Without a matching block, or under --no-asm,
the blocks are skipped and the portable body is the function.

This file is in w.w's import graph, so it is compiled by the pinned seed
and must stay seed-syntax-safe.
*/
import code_generator.asm_body


# --no-asm: ignore every asm block and compile the portable bodies, so a
# program's results can be compared with and without its asm.
int asm_bodies_disabled


# 1 when ISA name `name` is the compile target's, 0 for another known
# ISA; an unknown name is an error.
int asm_isa_matches(char* name):
	int matches = -1
	if (strcmp(name, c"x86") == 0): matches = (target_isa == 0) && (word_size == 4)
	else if (strcmp(name, c"x64") == 0): matches = (target_isa == 0) && (word_size == 8)
	else if (strcmp(name, c"arm64") == 0): matches = (target_isa == 1)
	if (matches < 0): error3(c"unknown asm target '", name, c"' (expected x86, x64 or arm64)")
	return matches


int asm_isa_arch():
	if (target_isa == 1): return ASM_ARCH_ARM64
	if (word_size == 8): return ASM_ARCH_X64
	return ASM_ARCH_X86


# Cheap pre-check on the raw bytes after a function's ':' token: 0 when
# the body certainly does not open with 'asm ', 1 when it might (or the
# buffered window ends before it can tell), so the token-level look-ahead
# below runs only for candidate bodies.
int asm_body_may_follow():
	if ((file < 0) || (file >= 256)): return 1
	char* buf = cast(char*, getchar_buf_addr[file])
	int pos = getchar_pos[file]
	int limit = getchar_limit[file]
	int c = nextc
	int in_comment = 0
	while ((c == ' ') || (c == 9) || (c == 10) || (c == 13) || (c == '#') || in_comment):
		if (c == '#'): in_comment = 1
		if (c == 10): in_comment = 0
		if (pos >= limit): return 1
		c = buf[pos] & 255
		pos = pos + 1
	if (c != 'a'): return 0
	char* rest = c"sm "
	int i = 0
	while (i < 3):
		if (pos >= limit): return 1
		c = buf[pos] & 255
		pos = pos + 1
		if ((i == 2) && (c == 9)): c = ' '
		if (c != rest[i]): return 0
		i = i + 1
	return 1


# Token-level look-ahead from a ':' token: does the body's first line
# read 'asm <name>:'? The tokenizer is restored either way.
int asm_body_follows():
	if (peek(c":") == 0): return 0
	if (asm_body_may_follow() == 0): return 0
	tokenizer_snapshot entry
	tokenizer_snapshot_save(&entry)
	get_token()
	int found = token_newline && peek(c"asm")
	if (found):
		get_token()
		found = is_ident_start_byte(token[0]) && (token_newline == 0)
	if (found):
		get_token()
		found = peek(c":") && (token_newline == 0)
	getchar_seek(file, entry.byte_offset)
	tokenizer_snapshot_restore(&entry, c":")
	return found


# Statement position: 'asm <name>:' anywhere but the opening of a
# function body is an error (statement() asks before treating 'asm' as
# an expression). Returns 0 otherwise, with the tokenizer untouched.
int asm_block_misplaced():
	if (peek(c"asm") == 0): return 0
	if ((nextc != ' ') && (nextc != 9)): return 0
	tokenizer_snapshot entry
	tokenizer_snapshot_save(&entry)
	get_token()
	int found = is_ident_start_byte(token[0]) && (token_newline == 0)
	if (found):
		get_token()
		found = peek(c":") && (token_newline == 0)
	getchar_seek(file, entry.byte_offset)
	tokenizer_snapshot_restore(&entry, c"asm")
	if (found): error(c"an asm block must open a function body, before its first statement")
	return 0


int asm_token_is_string():
	if (token[0] == '"'): return 1
	return (token[0] == 'c') && (token[1] == '"')


# Skip the tokens of a body whose lines are indented at body_level or
# deeper; stops at the first token that starts a shallower line outside
# any bracket.
void asm_skip_body(int body_level):
	int depth = 0
	while (token[0] != 0):
		if (token_newline && (depth == 0) && (tab_level < body_level)): return
		if (token[1] == 0):
			if ((token[0] == '(') || (token[0] == '[') || (token[0] == '{')): depth = depth + 1
			if ((token[0] == ')') || (token[0] == ']') || (token[0] == '}')): depth = depth - 1
		get_token()


# Called with the token at a function body's ':' before anything of the
# function has been emitted. Returns
#   0  no asm block for this target (or none at all): the token is a ':'
#      opening the portable body, which the caller compiles as usual;
#   1  the asm block was emitted as the whole function and the portable
#      body skipped (the token is past the function);
#   2  the asm block was emitted and branches to 'portable': the token is
#      a ':' opening the portable body, which the caller compiles right
#      after it (be_function_define keeps the asm entry as the symbol).
int asm_function_body(int current_symbol, char* name):
	if (asm_body_follows() == 0): return 0
	get_token()   # the ':'
	int body_level = tab_level
	asm_body_reset()
	int matched = 0
	tokenizer_snapshot last
	while (token_newline && (tab_level == body_level) && peek(c"asm")):
		get_token()
		int this_isa = asm_isa_matches(token)
		if (this_isa && matched): error3(c"duplicate asm block for '", token, c"'")
		int keep = this_isa && (asm_bodies_disabled == 0)
		if (keep): matched = 1
		get_token()
		tokenizer_snapshot_save(&last)
		expect(c":")
		if ((token_newline == 0) || (tab_level <= body_level)):
			error(c"an asm block's lines must be indented string literals")
		while ((token[0] != 0) && ((token_newline == 0) || (tab_level > body_level))):
			if (asm_token_is_string() == 0):
				error3(c"asm block lines must be string literals, found '", token, c"'")
			int line = diag_token_line
			int column = diag_token_column
			int length
			if (token[0] == 'c'): length = process_prefixed_string_literal()
			else: length = process_string_literal()
			token[length] = 0
			if (keep): asm_body_add(strclone(token), line, column)
			tokenizer_snapshot_save(&last)
			get_token()
	if ((token[0] == 0) || (tab_level < body_level) || (token_newline == 0)):
		error3(c"function '", name, c"' needs a portable W body after its asm blocks")
	if (matched == 0):
		getchar_seek(file, last.byte_offset)
		tokenizer_snapshot_restore(&last, c":")
		return 0
	be_function_define(current_symbol, name)
	int uses_portable = asm_body_emit(asm_isa_arch())
	if (uses_portable == 0):
		asm_skip_body(body_level)
		return 1
	asm_entry_symbol = current_symbol
	asm_entry_pending = 1
	getchar_seek(file, last.byte_offset)
	tokenizer_snapshot_restore(&last, c":")
	return 2
