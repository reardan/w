# ANTLR allocates symbolic kinds for undefined uppercase references. Preserve
# those identities in permissive output, while reporting that no lexer can
# produce them. This is compilation compatibility, not executable coverage.
import libs.extras.grammars.antlr_to_pg.types

list[at_element*] g_at_inferred_tokens

void at_infer_token_alts(list[at_alt*] alts):
	for at_alt* alt in alts:
		for at_element* element in alt.elements:
			if (element.kind == 3): at_infer_token_alts(element.group_alts)
			if ((element.kind != 2) || (strcmp(element.text, c"EOF") == 0)): continue
			if ((element.text[0] < 'A') || (element.text[0] > 'Z')): continue
			if ((element.text in g_seen_rule_names) || at_has_token_identity(element.text)): continue
			g_at_token_identities.push(strclone(element.text))
			g_at_inferred_tokens.push(element)

void at_infer_token_identities(list[at_rule*] rules):
	g_at_inferred_tokens = new list[at_element*]
	for at_rule* rule in rules:
		if (rule.is_lexer == 0): at_infer_token_alts(rule.alts)

void at_audit_token_identities():
	for at_element* element in g_at_inferred_tokens:
		at_loss_code(element.first, element.text, c"AT_INFERRED_TOKEN", c"token_identity", c"unsupported", c"undefined uppercase reference has an inferred token identity")
	if (g_at_token_identities == 0): return
	for char* name in g_at_token_identities:
		if ((name in g_parser_refs) == 0): continue
		int produced = name in g_lexer_rules
		for at_rule* rule in g_at_source_rules:
			if (rule.is_lexer == 0): continue
			for at_command* command in rule.commands:
				if ((strcmp(command.name, c"type") == 0) && (command.argument != 0)):
					if (strcmp(command.argument, name) == 0): produced = 1
		if (produced == 0):
			pg_token* location = 0
			for at_element* element in g_at_inferred_tokens:
				if (strcmp(element.text, name) == 0): location = element.first
			at_loss_code(location, name, c"AT_TOKEN_NO_LEXER", c"lexer_implementation", c"unsupported", c"symbolic token has no lexer rule or type command that produces it")
