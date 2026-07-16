/*
LL(1)-style analysis over the pg_grammar model (issue #329 milestone 2).

For every rule this computes, by fixpoint iteration over the grammar:
- nullable: the rule can succeed without consuming a token.
- first: the set of token kinds that can start a successful match. Kinds
  are the dense 0..kind_count-1 numbering the generated parser uses
  (EOF = 0, then tokens and literals in declaration order).
- pure: attempting the rule at a token outside its first set fails (or,
  for a nullable rule, matches empty) without consuming tokens and
  without recording diagnostics. Skipping such an attempt is therefore
  unobservable. Error recovery is the one impurity source: a failed
  iteration of a recover-marked repetition consumes tokens and records
  a diagnostic even when the surrounding attempt is abandoned.
- recovery_free: no recover-marked repetition is reachable anywhere in
  the rule. Re-parsing a recovery-free prefix is deterministic and
  silent, which is what makes left-factoring behavior-preserving.

The generator uses these facts to guard alternatives and repeated or
optional terms with first-set membership tests and to left-factor
shared prefixes; the guarded code keeps today's ordered-choice
semantics exactly, because a guard only skips attempts that provably
fail without side effects.
*/
import lib.lib
import libs.extras.parser_generator.grammar_model


struct pg_rule_facts:
	pg_rule* rule
	int nullable
	int pure
	int recovery_free
	char* first


struct pg_analysis:
	pg_grammar* grammar
	int kind_count
	list[pg_rule_facts*] rules


# A choice unit is one guarded/unguarded attempt in a rule body: either a
# single alternative (member_count 1, prefix_length 0) or a left-factored
# run of consecutive alternatives sharing prefix_length identical leading
# terms. guard_set is a kind_count-byte membership set when guarded.
struct pg_choice_unit:
	int alt_start
	int member_count
	int prefix_length
	int guarded
	char* guard_set


pg_rule_facts* pg_analysis_find(pg_analysis* analysis, char* name):
	int i = 0
	while (i < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[i]
		if (strcmp(facts.rule.name, name) == 0):
			return facts
		i = i + 1
	return 0


char* pg_kind_set_new(pg_analysis* analysis):
	char* kinds = malloc(analysis.kind_count)
	int i = 0
	while (i < analysis.kind_count):
		kinds[i] = 0
		i = i + 1
	return kinds


int pg_kind_set_empty(pg_analysis* analysis, char* kinds):
	int i = 0
	while (i < analysis.kind_count):
		if (kinds[i] != 0):
			return 0
		i = i + 1
	return 1


int pg_kind_set_intersects(pg_analysis* analysis, char* a, char* b):
	int i = 0
	while (i < analysis.kind_count):
		if ((a[i] != 0) & (b[i] != 0)):
			return 1
		i = i + 1
	return 0


# A repetition of a recover-marked rule resynchronizes instead of failing:
# it consumes tokens and records a diagnostic. Mirrors the emitter's
# recovery lookup (token terms never recover).
int pg_analysis_term_recovers(pg_grammar* grammar, pg_term* term):
	if ((term.modifier == '*') | (term.modifier == '+')):
		if (pg_grammar_is_token_term(grammar, term.name) == 0):
			return pg_grammar_find_recover(grammar, term.name) != 0
	return 0


int pg_analysis_term_nullable(pg_analysis* analysis, pg_term* term):
	if ((term.modifier == '?') | (term.modifier == '*')):
		return 1
	if (pg_grammar_is_token_term(analysis.grammar, term.name)):
		return 0
	pg_rule_facts* facts = pg_analysis_find(analysis, term.name)
	if (facts == 0):
		return 0
	return facts.nullable


# Union the term's first set into out. Returns 1 if out gained a kind.
int pg_analysis_term_first(pg_analysis* analysis, pg_term* term, char* out):
	int changed = 0
	if (pg_grammar_is_token_term(analysis.grammar, term.name)):
		int kind = pg_grammar_token_kind(analysis.grammar, term.name)
		if ((kind >= 0) & (kind < analysis.kind_count)):
			if (out[kind] == 0):
				out[kind] = 1
				changed = 1
		return changed
	pg_rule_facts* facts = pg_analysis_find(analysis, term.name)
	if (facts == 0):
		return 0
	int i = 0
	while (i < analysis.kind_count):
		if ((facts.first[i] != 0) & (out[i] == 0)):
			out[i] = 1
			changed = 1
		i = i + 1
	return changed


int pg_analysis_alternative_nullable(pg_analysis* analysis, pg_alternative* alternative, int offset):
	int i = offset
	while (i < alternative.terms.length):
		if (pg_analysis_term_nullable(analysis, alternative.terms[i]) == 0):
			return 0
		i = i + 1
	return 1


# Union the first set of the term sequence starting at offset into out:
# every term up to and including the first non-nullable one contributes.
int pg_analysis_terms_first(pg_analysis* analysis, pg_alternative* alternative, int offset, char* out):
	int changed = 0
	int i = offset
	while (i < alternative.terms.length):
		pg_term* term = alternative.terms[i]
		changed = changed | pg_analysis_term_first(analysis, term, out)
		if (pg_analysis_term_nullable(analysis, term) == 0):
			return changed
		i = i + 1
	return changed


int pg_analysis_nullable_sweep(pg_analysis* analysis):
	int changed = 0
	int r = 0
	while (r < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[r]
		if (facts.nullable == 0):
			int a = 0
			while (a < facts.rule.alternatives.length):
				if (pg_analysis_alternative_nullable(analysis, facts.rule.alternatives[a], 0)):
					facts.nullable = 1
					changed = 1
				a = a + 1
		r = r + 1
	return changed


int pg_analysis_first_sweep(pg_analysis* analysis):
	int changed = 0
	int r = 0
	while (r < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[r]
		int a = 0
		while (a < facts.rule.alternatives.length):
			changed = changed | pg_analysis_terms_first(analysis, facts.rule.alternatives[a], 0, facts.first)
			a = a + 1
		r = r + 1
	return changed


# Purity looks at the terms an on-miss attempt actually reaches: every
# term up to and including the first non-nullable one. Nullable terms
# skip (or match empty) and the first non-nullable term fails, so a miss
# never runs anything beyond that point.
int pg_analysis_prefix_pure(pg_analysis* analysis, pg_alternative* alternative, int offset):
	int i = offset
	while (i < alternative.terms.length):
		pg_term* term = alternative.terms[i]
		if (pg_analysis_term_recovers(analysis.grammar, term)):
			return 0
		if (pg_grammar_is_token_term(analysis.grammar, term.name) == 0):
			pg_rule_facts* facts = pg_analysis_find(analysis, term.name)
			if (facts == 0):
				return 0
			if (facts.pure == 0):
				return 0
		if (pg_analysis_term_nullable(analysis, term) == 0):
			return 1
		i = i + 1
	return 1


int pg_analysis_pure_sweep(pg_analysis* analysis):
	int changed = 0
	int r = 0
	while (r < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[r]
		if (facts.pure):
			int a = 0
			while (a < facts.rule.alternatives.length):
				if (pg_analysis_prefix_pure(analysis, facts.rule.alternatives[a], 0) == 0):
					facts.pure = 0
					changed = 1
				a = a + 1
		r = r + 1
	return changed


int pg_analysis_recovery_free_sweep(pg_analysis* analysis):
	int changed = 0
	int r = 0
	while (r < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[r]
		if (facts.recovery_free):
			int a = 0
			while (a < facts.rule.alternatives.length):
				pg_alternative* alternative = facts.rule.alternatives[a]
				int i = 0
				while (i < alternative.terms.length):
					pg_term* term = alternative.terms[i]
					if (pg_analysis_term_recovers(analysis.grammar, term)):
						facts.recovery_free = 0
						changed = 1
					if (pg_grammar_is_token_term(analysis.grammar, term.name) == 0):
						pg_rule_facts* inner = pg_analysis_find(analysis, term.name)
						if (inner != 0):
							if (inner.recovery_free == 0):
								facts.recovery_free = 0
								changed = 1
					i = i + 1
				a = a + 1
		r = r + 1
	return changed


pg_analysis* pg_analyze_grammar(pg_grammar* grammar):
	pg_analysis* analysis = new pg_analysis()
	analysis.grammar = grammar
	analysis.kind_count = grammar.tokens.length + grammar.literals.length + 1
	analysis.rules = new list[pg_rule_facts*]
	int r = 0
	while (r < grammar.rules.length):
		pg_rule_facts* facts = new pg_rule_facts()
		facts.rule = grammar.rules[r]
		facts.nullable = 0
		facts.pure = 1
		facts.recovery_free = 1
		facts.first = pg_kind_set_new(analysis)
		analysis.rules.push(facts)
		r = r + 1
	while (pg_analysis_nullable_sweep(analysis)):
		pass
	while (pg_analysis_first_sweep(analysis)):
		pass
	while (pg_analysis_pure_sweep(analysis)):
		pass
	while (pg_analysis_recovery_free_sweep(analysis)):
		pass
	return analysis


void pg_analysis_free(pg_analysis* analysis):
	if (analysis == 0):
		return
	int i = 0
	while (i < analysis.rules.length):
		pg_rule_facts* facts = analysis.rules[i]
		free(facts.first)
		free(facts)
		i = i + 1
	list_free[pg_rule_facts*](analysis.rules)
	free(analysis)


# A term sequence is guardable when skipping its attempt on a first-set
# miss is provably unobservable: every on-miss term is pure, the sequence
# cannot match empty, and its first set is non-empty. The returned guard
# only ever skips attempts that would fail without consuming input.
int pg_analysis_terms_guardable(pg_analysis* analysis, pg_alternative* alternative, int offset):
	if (offset >= alternative.terms.length):
		return 0
	if (pg_analysis_alternative_nullable(analysis, alternative, offset)):
		return 0
	if (pg_analysis_prefix_pure(analysis, alternative, offset) == 0):
		return 0
	char* kinds = pg_kind_set_new(analysis)
	pg_analysis_terms_first(analysis, alternative, offset, kinds)
	int empty = pg_kind_set_empty(analysis, kinds)
	free(kinds)
	return empty == 0


# A ?/*/+ term can be entered by first-set test instead of a trial parse
# when a miss is exactly a silent failure: token terms always qualify;
# rule terms need a pure, non-nullable rule (a nullable rule would match
# empty and contribute an empty node, which a skip would lose) with a
# non-empty first set. Recover-marked repetitions must keep the trial
# parse: their failure path is the recovery behavior itself.
int pg_analysis_term_enter_guardable(pg_analysis* analysis, pg_term* term):
	if (pg_analysis_term_recovers(analysis.grammar, term)):
		return 0
	if (pg_grammar_is_token_term(analysis.grammar, term.name)):
		return 1
	pg_rule_facts* facts = pg_analysis_find(analysis, term.name)
	if (facts == 0):
		return 0
	if ((facts.pure == 0) | facts.nullable):
		return 0
	return pg_kind_set_empty(analysis, facts.first) == 0


# --- choice planning -------------------------------------------------------
#
# Plan the body of a rule (or, recursively, the suffixes of a factored
# group) as an ordered list of choice units. Consecutive alternatives
# sharing identical leading plain terms become one factored unit; the
# shared prefix is parsed once and the suffix choice recurses. Prefix
# terms must be recovery-free so the single parse is observationally
# identical to today's deterministic re-parse per alternative.


int pg_plan_term_factorable(pg_analysis* analysis, pg_term* term):
	if (term.modifier != 0):
		return 0
	if (pg_grammar_is_token_term(analysis.grammar, term.name)):
		return 1
	pg_rule_facts* facts = pg_analysis_find(analysis, term.name)
	if (facts == 0):
		return 0
	return facts.recovery_free


int pg_plan_terms_equal(pg_term* a, pg_term* b):
	if (a.modifier != b.modifier):
		return 0
	return strcmp(a.name, b.name) == 0


# Length of the longest factorable prefix shared by alternatives
# alt_start..alt_start+member_count-1 starting at offset.
int pg_plan_prefix_length(pg_analysis* analysis, pg_rule* rule, int alt_start, int member_count, int offset):
	pg_alternative* head = rule.alternatives[alt_start]
	int length = 0
	int scanning = 1
	while (scanning):
		int index = offset + length
		if (index >= head.terms.length):
			return length
		pg_term* term = head.terms[index]
		if (pg_plan_term_factorable(analysis, term) == 0):
			return length
		int m = 1
		while (m < member_count):
			pg_alternative* member = rule.alternatives[alt_start + m]
			if (index >= member.terms.length):
				return length
			if (pg_plan_terms_equal(term, member.terms[index]) == 0):
				return length
			m = m + 1
		length = length + 1
	return length


pg_choice_unit* pg_choice_unit_new(int alt_start, int member_count, int prefix_length):
	pg_choice_unit* unit = new pg_choice_unit()
	unit.alt_start = alt_start
	unit.member_count = member_count
	unit.prefix_length = prefix_length
	unit.guarded = 0
	unit.guard_set = 0
	return unit


# Guard a unit when every member is guardable from offset; the guard set
# is the union of the members' first sets (identical prefixes make these
# mostly equal, but a nullable prefix lets suffixes diverge).
void pg_plan_unit_guard(pg_analysis* analysis, pg_rule* rule, pg_choice_unit* unit, int offset):
	int m = 0
	while (m < unit.member_count):
		if (pg_analysis_terms_guardable(analysis, rule.alternatives[unit.alt_start + m], offset) == 0):
			return
		m = m + 1
	char* kinds = pg_kind_set_new(analysis)
	m = 0
	while (m < unit.member_count):
		pg_analysis_terms_first(analysis, rule.alternatives[unit.alt_start + m], offset, kinds)
		m = m + 1
	unit.guarded = 1
	unit.guard_set = kinds


list[pg_choice_unit*] pg_plan_choice(pg_analysis* analysis, pg_rule* rule, int alt_start, int alt_count, int offset):
	list[pg_choice_unit*] units = new list[pg_choice_unit*]
	int a = alt_start
	while (a < alt_start + alt_count):
		pg_alternative* head = rule.alternatives[a]
		int run = 1
		if (offset < head.terms.length):
			if (pg_plan_term_factorable(analysis, head.terms[offset])):
				while (a + run < alt_start + alt_count):
					pg_alternative* next = rule.alternatives[a + run]
					if (offset >= next.terms.length):
						break
					if (pg_plan_terms_equal(head.terms[offset], next.terms[offset]) == 0):
						break
					run = run + 1
		int prefix_length = 0
		if (run > 1):
			prefix_length = pg_plan_prefix_length(analysis, rule, a, run, offset)
		if (prefix_length == 0):
			run = 1
		pg_choice_unit* unit = pg_choice_unit_new(a, run, prefix_length)
		pg_plan_unit_guard(analysis, rule, unit, offset)
		units.push(unit)
		a = a + run
	return units


void pg_choice_units_free(list[pg_choice_unit*] units):
	int i = 0
	while (i < units.length):
		pg_choice_unit* unit = units[i]
		if (unit.guard_set != 0):
			free(unit.guard_set)
		free(unit)
		i = i + 1
	list_free[pg_choice_unit*](units)


# --- conflict reporting ----------------------------------------------------
#
# Names, on stderr, each rule that keeps ordered-choice backtracking and
# the token kinds on which two of its attempts can both run. This is the
# left-factoring worklist for milestone 3.


char* pg_report_kind_name(pg_grammar* grammar, int kind):
	if (kind == 0):
		return c"EOF"
	int i = 0
	while (i < grammar.tokens.length):
		pg_token_def* token = grammar.tokens[i]
		if (token.kind == kind):
			return token.name
		i = i + 1
	i = 0
	while (i < grammar.literals.length):
		pg_literal_def* literal = grammar.literals[i]
		if (literal.kind == kind):
			return literal.name
		i = i + 1
	return c"<unknown>"


void pg_report_overlap_kinds(pg_analysis* analysis, char* a, char* b):
	int printed = 0
	int kind = 0
	while (kind < analysis.kind_count):
		if ((a[kind] != 0) & (b[kind] != 0)):
			if (printed == 8):
				print2(c" ...")
				return
			print2(c" ")
			print2(pg_report_kind_name(analysis.grammar, kind))
			printed = printed + 1
		kind = kind + 1


# An unguarded unit attempts on every token; model it as the full kind
# set so overlap reporting stays truthful about what actually runs.
char* pg_report_unit_set(pg_analysis* analysis, pg_choice_unit* unit):
	if (unit.guarded):
		return unit.guard_set
	char* kinds = pg_kind_set_new(analysis)
	int i = 0
	while (i < analysis.kind_count):
		kinds[i] = 1
		i = i + 1
	return kinds


int pg_report_unit_is_empty_suffix(pg_rule* rule, pg_choice_unit* unit, int offset):
	if (unit.member_count != 1):
		return 0
	return offset >= rule.alternatives[unit.alt_start].terms.length


void pg_report_unit_span(pg_choice_unit* unit):
	print2(itoa(unit.alt_start + 1))
	if (unit.member_count > 1):
		print2(c"-")
		print2(itoa(unit.alt_start + unit.member_count - 1 + 1))


# Report every pair of units where the later one can attempt to consume
# tokens the earlier one also accepts. A trailing empty alternative is
# exempt: reaching it parses nothing, which is LL(1) epsilon dispatch,
# not backtracking. Returns the number of colliding pairs.
int pg_report_choice(pg_analysis* analysis, pg_rule* rule, list[pg_choice_unit*] units, int offset):
	int conflicts = 0
	int i = 0
	while (i < units.length):
		pg_choice_unit* left = units[i]
		char* left_set = pg_report_unit_set(analysis, left)
		int j = i + 1
		while (j < units.length):
			pg_choice_unit* right = units[j]
			if (pg_report_unit_is_empty_suffix(rule, right, offset) == 0):
				char* right_set = pg_report_unit_set(analysis, right)
				if (pg_kind_set_intersects(analysis, left_set, right_set)):
					conflicts = conflicts + 1
					print2(c"parser_generator: rule ")
					print2(rule.name)
					print2(c": alternatives ")
					pg_report_unit_span(left)
					print2(c" and ")
					pg_report_unit_span(right)
					print2(c" overlap on")
					pg_report_overlap_kinds(analysis, left_set, right_set)
					println2(c"")
				if (right.guarded == 0):
					free(right_set)
			j = j + 1
		if (left.guarded == 0):
			free(left_set)
		i = i + 1
	# Recurse into factored suffix choices.
	i = 0
	while (i < units.length):
		pg_choice_unit* unit = units[i]
		if (unit.member_count > 1):
			list[pg_choice_unit*] inner = pg_plan_choice(analysis, rule, unit.alt_start, unit.member_count, offset + unit.prefix_length)
			conflicts = conflicts + pg_report_choice(analysis, rule, inner, offset + unit.prefix_length)
			pg_choice_units_free(inner)
		i = i + 1
	return conflicts


void pg_report_dispatch(pg_grammar* grammar):
	pg_analysis* analysis = pg_analyze_grammar(grammar)
	int committed = 0
	int backtracking = 0
	int factored = 0
	int r = 0
	while (r < grammar.rules.length):
		pg_rule* rule = grammar.rules[r]
		list[pg_choice_unit*] units = pg_plan_choice(analysis, rule, 0, rule.alternatives.length, 0)
		int i = 0
		while (i < units.length):
			if (units[i].member_count > 1):
				factored = factored + 1
			i = i + 1
		if (pg_report_choice(analysis, rule, units, 0) == 0):
			committed = committed + 1
		else:
			backtracking = backtracking + 1
		pg_choice_units_free(units)
		r = r + 1
	print2(c"parser_generator: ")
	print2(grammar.name)
	print2(c": ")
	print2(itoa(committed))
	print2(c" rules committed dispatch, ")
	print2(itoa(backtracking))
	print2(c" rules keep backtracking, ")
	print2(itoa(factored))
	print2(c" left-factored groups")
	println2(c"")
	pg_analysis_free(analysis)
