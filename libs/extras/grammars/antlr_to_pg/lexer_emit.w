import libs.extras.grammars.antlr_to_pg.lexer_lower


void at_lex_emit_word(string_builder* out, int value):
	char* hex = c"0123456789abcdef"
	for shift in range(0, 32, 8):
		int octet = (value >> shift) & 255
		string_append(out, c"\\x")
		string_append_char(out, hex[octet >> 4])
		string_append_char(out, hex[octet & 15])


char* at_exact_generate_matcher(at_rule* rule):
	char* reason = g_at_exact_reasons.get(rule.name, c"unprepared exact lexer rule")
	if (reason != 0):
		at_report(c"UNRECOGNIZED lexer rule ", rule.name, reason)
		return 0
	at_lex_program* p = new at_lex_program()
	p.states = new list[at_lex_state*]
	p.entries = new map[char*, int]
	int entry = at_lex_lower_rule(p, rule)
	if (p.states.length > 32767):
		at_report(c"UNRECOGNIZED lexer rule ", rule.name, c"exact lexer program exceeds state limit")
		at_lex_program_free(p)
		return 0
	char* name = strclone(cstr(f"g_{g_matcher_parser_prefix}_{rule.name}"))
	char* function_name = at_token_matcher_fn_name(name)
	string_append(g_matchers_out, cstr(f"\nint {function_name}(char* input, int index):\n\treturn at_lex_match(c\""))
	for at_lex_state* state in p.states:
		at_lex_emit_word(g_matchers_out, state.op)
		at_lex_emit_word(g_matchers_out, state.next)
		at_lex_emit_word(g_matchers_out, state.other)
		at_lex_emit_word(g_matchers_out, state.low)
		at_lex_emit_word(g_matchers_out, state.high)
		at_lex_emit_word(g_matchers_out, state.nongreedy)
	string_append(g_matchers_out, cstr(f"\", {p.states.length}, {entry}, input, index)\n"))
	free(function_name)
	at_lex_program_free(p)
	return name
