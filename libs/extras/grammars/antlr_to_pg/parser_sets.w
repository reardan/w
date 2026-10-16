# Parser wildcards and complements range over token identities, never bytes.
# Lower to ordinary helper alternatives after all implicit literals are known.
import libs.extras.grammars.antlr_to_pg.types

struct at_parser_set:
	char* helper
	map[char*, int] excluded

list[at_parser_set*] g_at_parser_sets

int at_parser_set_supported(at_element* element):
	if (element.kind == 4): return 1
	if ((element.kind != 5) || (element.group_alts == 0)): return 0
	for at_alt* alt in element.group_alts:
		if (alt.elements.length != 1): return 0
		at_element* atom = alt.elements[0]
		if (atom.suffix != 0): return 0
		if (atom.kind == 0): continue
		if ((atom.kind != 2) || (atom.text[0] < 'A') || (atom.text[0] > 'Z')): return 0
	return 1

int at_parser_has_set(list[at_alt*] alts):
	for at_alt* alt in alts:
		for at_element* element in alt.elements:
			if ((element.kind == 4) || (element.kind == 5)): return 1
			if ((element.kind == 3) && at_parser_has_set(element.group_alts)): return 1
	return 0
