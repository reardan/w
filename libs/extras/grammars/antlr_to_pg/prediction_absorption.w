# Bounded regular-language proof for greedy continuation absorption.
# For every concrete caller suffix C and greedy atom A, prove A^-1 C <= C.
# Unknown recursion, oversized automata, and failed inclusion retain the warning.
import libs.extras.grammars.antlr_to_pg.prediction_prefix


int g_at_abs_remaining
int g_at_abs_grammar_remaining
int g_at_abs_operations


# Optional proof has an aggregate grammar budget, in addition to per-job caps.
# Large grammars retain the ordinary FIRST/FOLLOW findings without attempting
# regular expansion. Exhaustion is sticky until the next grammar audit.
int at_abs_charge(int cost):
	if ((cost < 0) || (cost > g_at_abs_grammar_remaining)):
		g_at_abs_operations = g_at_abs_operations + g_at_abs_grammar_remaining
		g_at_abs_grammar_remaining = 0
		return 0
	g_at_abs_operations = g_at_abs_operations + cost
	g_at_abs_grammar_remaining = g_at_abs_grammar_remaining - cost
	return g_at_abs_grammar_remaining > 0


int at_abs_count_atoms(list[at_alt*] alts, int depth):
	if (depth > 24): return 4097
	int count = 0
	for at_alt* alt in alts:
		for at_element* element in alt.elements:
			count++
			if (element.kind == 3): count = count + at_abs_count_atoms(element.group_alts, depth + 1)
			if (count > 4096): return count
	return count


void at_abs_reset(list[at_rule*] rules):
	g_at_abs_operations = 0
	g_at_abs_grammar_remaining = 750000000
	int parsers = 0
	int atoms = 0
	for at_rule* rule in rules:
		if (rule.is_lexer): continue
		parsers++
		if (parsers > 128):
			g_at_abs_grammar_remaining = 0
			return
		atoms = atoms + at_abs_count_atoms(rule.alts, 0)
		if (atoms > 4096):
			g_at_abs_grammar_remaining = 0
			return



struct at_abs_edge:
	int target
	char* token


struct at_abs_nfa:
	list[list[at_abs_edge*]] edges
	int accept
	int failed


struct at_abs_pair:
	list[int] left
	list[int] right


int at_abs_state(at_abs_nfa* nfa):
	if (nfa.failed || (nfa.edges.length >= 512) || (at_abs_charge(1) == 0)):
		nfa.failed = 1
		return 0
	int result = nfa.edges.length
	nfa.edges.push(new list[at_abs_edge*])
	return result


void at_abs_edge_add(at_abs_nfa* nfa, int from, int to, char* token):
	if (nfa.failed || (at_abs_charge(1) == 0)):
		nfa.failed = 1
		return
	at_abs_edge* edge = new at_abs_edge()
	edge.target = to
	edge.token = token
	nfa.edges[from].push(edge)


int at_abs_alphabet(at_element* element, map[char*, int] alphabet, int depth):
	g_at_abs_remaining--
	if ((depth > 24) || (g_at_abs_remaining <= 0) || (at_abs_charge(1) == 0)): return 0
	if (at_prediction_is_token(element)):
		map[char*, int] first = at_prediction_first_atom(element)
		for char* token in first: alphabet[token] = 1
		return 1
	list[at_alt*] alts = 0
	if (element.kind == 3): alts = element.group_alts
	else if ((element.kind == 2) && (element.text in g_at_rules)): alts = g_at_rules[element.text].alts
	if (alts == 0): return 0
	for at_alt* alt in alts:
		for at_element* child in alt.elements:
			if (at_abs_alphabet(child, alphabet, depth + 1) == 0): return 0
	return 1


void at_abs_compile_atom(at_abs_nfa* nfa, at_element* element, int from, int to, int depth);


void at_abs_compile_term(at_abs_nfa* nfa, at_element* element, int from, int to, int depth):
	if ((depth > 24) || nfa.failed):
		nfa.failed = 1
		return
	int begin = at_abs_state(nfa)
	int end = at_abs_state(nfa)
	at_abs_edge_add(nfa, from, begin, 0)
	at_abs_compile_atom(nfa, element, begin, end, depth + 1)
	at_abs_edge_add(nfa, end, to, 0)
	if ((element.suffix == '?') || (element.suffix == '*')): at_abs_edge_add(nfa, from, to, 0)
	if ((element.suffix == '*') || (element.suffix == '+')): at_abs_edge_add(nfa, end, begin, 0)


void at_abs_compile_sequence(at_abs_nfa* nfa, list[at_element*] elements, int from, int to, int depth):
	int current = from
	for at_element* element in elements:
		if (nfa.failed): return
		int next = at_abs_state(nfa)
		at_abs_compile_term(nfa, element, current, next, depth)
		current = next
	at_abs_edge_add(nfa, current, to, 0)


void at_abs_compile_atom(at_abs_nfa* nfa, at_element* element, int from, int to, int depth):
	if ((depth > 24) || nfa.failed):
		nfa.failed = 1
		return
	if (element.kind == 99):
		# Ordinary token keys always start with "literal " or "token ".
		at_abs_edge_add(nfa, from, to, c"boundary")
		return
	if (at_prediction_is_token(element)):
		map[char*, int] first = at_prediction_first_atom(element)
		for char* token in first: at_abs_edge_add(nfa, from, to, token)
		return
	list[at_alt*] alts = 0
	if (element.kind == 3): alts = element.group_alts
	else if ((element.kind == 2) && (element.text in g_at_rules)): alts = g_at_rules[element.text].alts
	if (alts == 0):
		nfa.failed = 1
		return
	for at_alt* alt in alts:
		if (nfa.failed): return
		at_abs_compile_sequence(nfa, alt.elements, from, to, depth + 1)


at_abs_nfa* at_abs_new():
	at_abs_nfa* nfa = new at_abs_nfa()
	nfa.edges = new list[list[at_abs_edge*]]
	nfa.failed = 0
	at_abs_state(nfa)
	nfa.accept = at_abs_state(nfa)
	return nfa


list[int] at_abs_closure(at_abs_nfa* nfa, list[int] seeds):
	if (nfa.failed || (at_abs_charge(nfa.edges.length * 2 + seeds.length) == 0)):
		nfa.failed = 1
		return new list[int]
	list[int] present = new list[int]
	int slot = 0
	while (slot < nfa.edges.length):
		present.push(0)
		slot++
	list[int] work = new list[int]
	for int seed in seeds:
		if (present[seed] == 0):
			present[seed] = 1
			work.push(seed)
	int i = 0
	while (i < work.length):
		if (at_abs_charge(1 + nfa.edges[work[i]].length) == 0):
			nfa.failed = 1
			break
		for at_abs_edge* edge in nfa.edges[work[i]]:
			if ((edge.token == 0) && (present[edge.target] == 0)):
				present[edge.target] = 1
				work.push(edge.target)
		i++
	list[int] result = new list[int]
	int j = 0
	while (j < present.length):
		if (present[j]): result.push(j)
		j++
	__w_list_free(cast(__w_list*, present))
	__w_list_free(cast(__w_list*, work))
	return result


list[int] at_abs_start(at_abs_nfa* nfa):
	list[int] seeds = new list[int]
	seeds.push(0)
	list[int] result = at_abs_closure(nfa, seeds)
	__w_list_free(cast(__w_list*, seeds))
	return result


list[int] at_abs_move(at_abs_nfa* nfa, list[int] states, char* token):
	list[int] seeds = new list[int]
	for int state in states:
		if (nfa.failed || (at_abs_charge(1 + nfa.edges[state].length) == 0)):
			nfa.failed = 1
			break
		for at_abs_edge* edge in nfa.edges[state]:
			if ((edge.token != 0) && (strcmp(edge.token, token) == 0)): seeds.push(edge.target)
	list[int] result = at_abs_closure(nfa, seeds)
	__w_list_free(cast(__w_list*, seeds))
	return result


int at_abs_accepts(at_abs_nfa* nfa, list[int] states):
	if (nfa.failed || (at_abs_charge(states.length) == 0)):
		nfa.failed = 1
		return 0
	for int state in states:
		if (state == nfa.accept): return 1
	return 0


void at_abs_tokens(at_abs_nfa* nfa, list[int] states, map[char*, int] tokens):
	for int state in states:
		if (nfa.failed || (at_abs_charge(1 + nfa.edges[state].length) == 0)):
			nfa.failed = 1
			break
		for at_abs_edge* edge in nfa.edges[state]:
			if (edge.token != 0): tokens[edge.token] = 1


char* at_abs_pair_key(list[int] left, list[int] right):
	char* key = cast(char*, malloc((left.length + right.length) * 3 + 2))
	int i = 0
	for int state in left:
		key[i] = 'a' + (state & 15)
		i++
		key[i] = 'a' + ((state >> 4) & 15)
		i++
		key[i] = 'a' + ((state >> 8) & 15)
		i++
	key[i] = '/'
	i++
	for int state in right:
		key[i] = 'a' + (state & 15)
		i++
		key[i] = 'a' + ((state >> 4) & 15)
		i++
		key[i] = 'a' + ((state >> 8) & 15)
		i++
	key[i] = 0
	return key


void at_abs_push(list[at_abs_pair*] work, map[char*, int] seen, list[int] left, list[int] right):
	if (at_abs_charge(1 + left.length + right.length) == 0):
		__w_list_free(cast(__w_list*, left))
		__w_list_free(cast(__w_list*, right))
		return
	char* key = at_abs_pair_key(left, right)
	if (key in seen):
		free(key)
		__w_list_free(cast(__w_list*, left))
		__w_list_free(cast(__w_list*, right))
		return
	seen[key] = 1
	free(key)
	at_abs_pair* pair = new at_abs_pair()
	pair.left = left
	pair.right = right
	work.push(pair)


void at_abs_free_work(list[at_abs_pair*] work, map[char*, int] seen):
	for at_abs_pair* pair in work:
		__w_list_free(cast(__w_list*, pair.left))
		__w_list_free(cast(__w_list*, pair.right))
		free(pair)
	__w_list_free(cast(__w_list*, work))
	__w_map_free(cast(__w_hash_table*, seen))


void at_abs_free_nfa(at_abs_nfa* nfa):
	for list[at_abs_edge*] edges in nfa.edges:
		for at_abs_edge* edge in edges: free(edge)
		__w_list_free(cast(__w_list*, edges))
	__w_list_free(cast(__w_list*, nfa.edges))
	free(nfa)


# DFA-subset inclusion, with a shared finite exploration budget.
int at_abs_subset(at_abs_nfa* nfa, list[int] residual, int* budget):
	list[at_abs_pair*] work = new list[at_abs_pair*]
	map[char*, int] seen = new map[char*, int]
	list[int] copy = new list[int]
	for int state in residual: copy.push(state)
	at_abs_push(work, seen, copy, at_abs_start(nfa))
	int result = 1
	int i = 0
	while (i < work.length):
		*budget = *budget - 1
		g_at_abs_remaining--
		if ((*budget <= 0) || (g_at_abs_remaining <= 0) || nfa.failed || (at_abs_charge(1) == 0)):
			result = 0
			break
		at_abs_pair* pair = work[i]
		if (at_abs_accepts(nfa, pair.left) && (at_abs_accepts(nfa, pair.right) == 0)):
			result = 0
			break
		map[char*, int] tokens = new map[char*, int]
		at_abs_tokens(nfa, pair.left, tokens)
		for char* token in tokens:
			at_abs_push(work, seen, at_abs_move(nfa, pair.left, token), at_abs_move(nfa, pair.right, token))
		__w_map_free(cast(__w_hash_table*, tokens))
		i++
	if (nfa.failed || (g_at_abs_grammar_remaining <= 0)): result = 0
	at_abs_free_work(work, seen)
	return result


int at_abs_quotient(at_element* atom, list[at_element*] continuation):
	at_abs_nfa* a = at_abs_new()
	at_abs_nfa* c = at_abs_new()
	at_abs_compile_atom(a, atom, 0, a.accept, 0)
	at_abs_compile_sequence(c, continuation, 0, c.accept, 0)
	if (a.failed || c.failed):
		at_abs_free_nfa(a)
		at_abs_free_nfa(c)
		return 0
	list[at_abs_pair*] work = new list[at_abs_pair*]
	map[char*, int] seen = new map[char*, int]
	at_abs_push(work, seen, at_abs_start(a), at_abs_start(c))
	map[char*, int] proven = new map[char*, int]
	list[int] empty = new list[int]
	int budget = 4096
	int result = 1
	int i = 0
	while (i < work.length):
		budget--
		g_at_abs_remaining--
		if ((budget <= 0) || (g_at_abs_remaining <= 0) || a.failed || c.failed || (at_abs_charge(1) == 0)):
			result = 0
			break
		at_abs_pair* pair = work[i]
		if (at_abs_accepts(a, pair.left)):
			char* residual_key = at_abs_pair_key(pair.right, empty)
			if ((residual_key in proven) == 0):
				if (at_abs_subset(c, pair.right, &budget) == 0): result = 0
				proven[residual_key] = 1
			free(residual_key)
			if (result == 0): break
		map[char*, int] tokens = new map[char*, int]
		at_abs_tokens(a, pair.left, tokens)
		for char* token in tokens:
			list[int] next = at_abs_move(c, pair.right, token)
			if (next.length): at_abs_push(work, seen, at_abs_move(a, pair.left, token), next)
			else: __w_list_free(cast(__w_list*, next))
		__w_map_free(cast(__w_hash_table*, tokens))
		i++
	__w_map_free(cast(__w_hash_table*, proven))
	__w_list_free(cast(__w_list*, empty))
	if (a.failed || c.failed || (g_at_abs_grammar_remaining <= 0)): result = 0
	at_abs_free_work(work, seen)
	at_abs_free_nfa(a)
	at_abs_free_nfa(c)
	return result


list[at_element*] at_abs_concat(list[at_element*] left, list[at_element*] right):
	list[at_element*] result = new list[at_element*]
	if (at_abs_charge(left.length + right.length) == 0): return result
	for at_element* element in left: result.push(element)
	for at_element* element in right: result.push(element)
	return result


list[at_element*] at_abs_tail(at_alt* alt, int index, list[at_element*] outer, int repeat):
	list[at_element*] tail = new list[at_element*]
	at_element* element = alt.elements[index]
	if (repeat && ((element.suffix == '*') || (element.suffix == '+'))):
		at_element* copy = new at_element()
		copy.kind = element.kind
		copy.text = element.text
		copy.group_alts = element.group_alts
		copy.suffix = '*'
		tail.push(copy)
	for i in range(index + 1, alt.elements.length): tail.push(alt.elements[i])
	for at_element* next in outer: tail.push(next)
	return tail


void at_abs_free_tail(list[at_element*] tail, at_element* element, int repeat):
	if (repeat && ((element.suffix == '*') || (element.suffix == '+'))): free(tail[0])
	__w_list_free(cast(__w_list*, tail))


# Stop at a mandatory boundary outside the atom's alphabet. Its actual tail
# cannot be consumed by A and is therefore represented by the same sentinel.
list[at_element*] at_abs_bounded_tail(list[at_element*] tail, map[char*, int] alphabet):
	list[at_element*] result = new list[at_element*]
	for at_element* element in tail:
		if (at_abs_charge(1) == 0):
			__w_list_free(cast(__w_list*, result))
			return 0
		int nullable = (element.suffix == '?') || (element.suffix == '*') || at_prediction_atom_nullable(element)
		if ((nullable == 0) && (at_prediction_overlap(at_prediction_first_atom(element), alphabet) == 0)):
			at_element* marker = new at_element()
			marker.kind = 99
			marker.text = 0
			marker.suffix = 0
			result.push(marker)
			return result
		result.push(element)
	__w_list_free(cast(__w_list*, result))
	return 0


int at_abs_context(at_rule* owner, at_element* atom, list[at_element*] tail, map[char*, int] alphabet, map[char*, int] visiting, int depth);


int at_abs_calls(at_rule* caller, list[at_alt*] alts, list[at_element*] outer, at_rule* owner, at_element* atom, list[at_element*] tail, map[char*, int] alphabet, map[char*, int] visiting, int depth):
	for at_alt* alt in alts:
		for i, element in alt.elements:
			g_at_abs_remaining--
			if ((g_at_abs_remaining <= 0) || (at_abs_charge(1) == 0)): return 0
			int call = (element.kind == 2) && (strcmp(element.text, owner.name) == 0)
			if ((call == 0) && (element.kind != 3)): continue
			list[at_element*] after = at_abs_tail(alt, i, outer, 1)
			int result = 1
			if (call):
				list[at_element*] joined = at_abs_concat(tail, after)
				result = at_abs_context(caller, atom, joined, alphabet, visiting, depth + 1)
				__w_list_free(cast(__w_list*, joined))
			if (element.kind == 3): result = at_abs_calls(caller, element.group_alts, after, owner, atom, tail, alphabet, visiting, depth)
			at_abs_free_tail(after, element, 1)
			if (result == 0): return 0
	return 1


int at_abs_check_bounded(at_element* atom, list[at_element*] bounded):
	int result = at_abs_quotient(atom, bounded)
	free(bounded[bounded.length - 1])
	__w_list_free(cast(__w_list*, bounded))
	return result


int at_abs_context(at_rule* owner, at_element* atom, list[at_element*] tail, map[char*, int] alphabet, map[char*, int] visiting, int depth):
	g_at_abs_remaining--
	if ((depth > 24) || (g_at_abs_remaining <= 0) || (at_abs_charge(1) == 0)): return 0
	list[at_element*] bounded = at_abs_bounded_tail(tail, alphabet)
	if (bounded != 0): return at_abs_check_bounded(atom, bounded)
	# Every public entry also has a standalone complete-input continuation.
	list[at_element*] standalone = new list[at_element*]
	at_element* eof = new at_element()
	eof.kind = 2
	eof.text = c"EOF"
	eof.suffix = 0
	standalone.push(eof)
	list[at_element*] joined = at_abs_concat(tail, standalone)
	bounded = at_abs_bounded_tail(joined, alphabet)
	__w_list_free(cast(__w_list*, joined))
	__w_list_free(cast(__w_list*, standalone))
	free(eof)
	if ((bounded == 0) || (at_abs_check_bounded(atom, bounded) == 0)): return 0
	if ((owner.name in visiting) && visiting[owner.name]): return 0
	visiting[owner.name] = 1
	for char* name in g_at_rules:
		if (at_abs_charge(1) == 0):
			visiting[owner.name] = 0
			return 0
		at_rule* caller = g_at_rules[name]
		if (caller.is_lexer): continue
		list[at_element*] empty = new list[at_element*]
		int valid = at_abs_calls(caller, caller.alts, empty, owner, atom, tail, alphabet, visiting, depth)
		__w_list_free(cast(__w_list*, empty))
		if (valid == 0):
			visiting[owner.name] = 0
			return 0
	visiting[owner.name] = 0
	return 1


int at_prediction_absorption(at_rule* owner, at_element* atom, list[at_element*] tail):
	if (g_at_abs_grammar_remaining <= 0): return 0
	g_at_abs_remaining = 65536
	map[char*, int] alphabet = new map[char*, int]
	map[char*, int] visiting = new map[char*, int]
	int result = 0
	if (at_abs_alphabet(atom, alphabet, 0) && (alphabet.length > 0)):
		result = at_abs_context(owner, atom, tail, alphabet, visiting, 0)
	__w_map_free(cast(__w_hash_table*, alphabet))
	__w_map_free(cast(__w_hash_table*, visiting))
	return result && (g_at_abs_grammar_remaining > 0)
