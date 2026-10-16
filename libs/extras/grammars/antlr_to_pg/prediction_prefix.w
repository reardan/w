# Bounded token-prefix proof for ordered choices. This is deliberately narrower
# than language equivalence: unknown/recursive/multi-alternative expansion keeps
# the diagnostic. Shared repetitions cancel only with disjoint suffix FIRST sets.
import libs.extras.grammars.antlr_to_pg.normalize_operators


map[char*, int] at_prediction_first_atom(at_element* element);
map[char*, int] at_prediction_first_alt(at_alt* alt);
int at_prediction_atom_nullable(at_element* element);
int at_prediction_overlap(map[char*, int] left, map[char*, int] right);


list[at_element*] at_prediction_drop_first(list[at_element*] elements):
	list[at_element*] rest = new list[at_element*]
	for i in range(1, elements.length): rest.push(elements[i])
	return rest


list[at_element*] at_prediction_expand_prefix(list[at_element*] elements):
	if (elements.length == 0): return elements
	at_element* first = elements[0]
	list[at_alt*] alts = 0
	if (first.kind == 3): alts = first.group_alts
	else if ((first.kind == 2) && (first.text in g_at_rules)):
		at_rule* rule = g_at_rules[first.text]
		if (rule.is_lexer == 0): alts = rule.alts
	if ((alts == 0) || (alts.length != 1)): return elements
	list[at_element*] body = alts[0].elements
	if (first.suffix != 0):
		if ((body.length != 1) || (body[0].suffix != 0)): return elements
	list[at_element*] result = new list[at_element*]
	for at_element* element in body:
		at_element* copy = at_clone_element(element)
		if (first.suffix != 0): copy.suffix = first.suffix
		result.push(copy)
	for i in range(1, elements.length): result.push(elements[i])
	return result


int at_prediction_is_token(at_element* element):
	if (element.kind == 0): return strlen(element.text) > 0
	if (element.kind != 2): return 0
	if (strcmp(element.text, c"EOF") == 0): return 1
	if (element.text in g_at_rules): return g_at_rules[element.text].is_lexer
	return 0


map[char*, int] at_prediction_first_sequence(list[at_element*] elements):
	at_alt* alt = new at_alt()
	alt.elements = elements
	return at_prediction_first_alt(alt)


int at_prediction_prefix_disjoint(at_alt* left, at_alt* right):
	list[at_element*] a = left.elements
	list[at_element*] b = right.elements
	int steps = 0
	while (steps < 64):
		steps++
		list[at_element*] expanded = at_prediction_expand_prefix(a)
		if (expanded != a):
			a = expanded
			continue
		expanded = at_prediction_expand_prefix(b)
		if (expanded != b):
			b = expanded
			continue
		if ((a.length == 0) || (b.length == 0)):
			# Identical complete alternatives choose the first in both models.
			return (a.length == 0) && (b.length == 0)
		at_element* x = a[0]
		at_element* y = b[0]
		map[char*, int] xf = at_prediction_first_atom(x)
		map[char*, int] yf = at_prediction_first_atom(y)
		int xn = (x.suffix == '?') || (x.suffix == '*') || at_prediction_atom_nullable(x)
		int yn = (y.suffix == '?') || (y.suffix == '*') || at_prediction_atom_nullable(y)
		if ((xn == 0) && (yn == 0) && (at_prediction_overlap(xf, yf) == 0)): return 1
		if ((at_prediction_is_token(x) == 0) || (at_prediction_is_token(y) == 0)): return 0
		if ((x.suffix != y.suffix) || (xf.length != 1) || (yf.length != 1)): return 0
		if (at_prediction_overlap(xf, yf) == 0): return 0
		a = at_prediction_drop_first(a)
		b = at_prediction_drop_first(b)
		if (x.suffix != 0):
			if (at_prediction_overlap(xf, at_prediction_first_sequence(a))): return 0
			if (at_prediction_overlap(yf, at_prediction_first_sequence(b))): return 0
	return 0


# A mandatory common terminator makes alternatives prefix-free when no body
# can contain that token. Nested parser choices are still audited separately.
int at_prediction_body_excludes(list[at_element*] elements, int end, map[char*, int] terminator, int depth):
	if (depth > 24): return 0
	for i in range(end):
		at_element* element = elements[i]
		if (at_prediction_is_token(element)):
			if (at_prediction_overlap(at_prediction_first_atom(element), terminator)): return 0
		else:
			list[at_alt*] alts = 0
			if (element.kind == 3): alts = element.group_alts
			else if ((element.kind == 2) && (element.text in g_at_rules)): alts = g_at_rules[element.text].alts
			if (alts == 0): return 0
			for at_alt* alt in alts:
				if (at_prediction_body_excludes(alt.elements, alt.elements.length, terminator, depth + 1) == 0): return 0
	return 1


int at_prediction_common_terminator(at_alt* left, at_alt* right):
	if ((left.elements.length == 0) || (right.elements.length == 0)): return 0
	int a = left.elements.length - 1
	int b = right.elements.length - 1
	at_element* x = left.elements[a]
	at_element* y = right.elements[b]
	if ((x.suffix != 0) || (y.suffix != 0)): return 0
	if ((at_prediction_is_token(x) == 0) || (at_prediction_is_token(y) == 0)): return 0
	map[char*, int] xf = at_prediction_first_atom(x)
	map[char*, int] yf = at_prediction_first_atom(y)
	if ((xf.length != 1) || (yf.length != 1) || (at_prediction_overlap(xf, yf) == 0)): return 0
	return at_prediction_body_excludes(left.elements, a, xf, 0) && at_prediction_body_excludes(right.elements, b, xf, 0)
