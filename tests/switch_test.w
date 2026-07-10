# wbuild: x64
# switch statement (grammar/switch_statement.w): the scrutinee is
# evaluated exactly once, cases compare with == semantics in source
# order, every case body has an implicit break (no fallthrough),
# 'default' must be last, and 'break' exits the switch while 'continue'
# still targets the enclosing loop.
import lib.testing


int classify(int x):
	int r = 0
	switch (x):
		case 1:
			r = 10
		case 2, 3:
			r = 20
		default:
			r = 99
	return r


void test_first_case_match():
	assert_equal(10, classify(1))


void test_later_case_match():
	assert_equal(20, classify(2))


void test_multi_value_case():
	assert_equal(20, classify(3))


void test_default_taken():
	assert_equal(99, classify(0))
	assert_equal(99, classify(4))


void test_no_default_no_match():
	int hits = 0
	# Parentheses around the scrutinee are optional, like if/while
	switch 5:
		case 1:
			hits = hits + 1
		case 2:
			hits = hits + 1
	assert_equal(0, hits)


void test_no_fallthrough():
	int total = 0
	switch (2):
		case 1:
			total = total + 1
		case 2:
			total = total + 10
		case 3:
			total = total + 100
		default:
			total = total + 1000
	assert_equal(10, total)


int eval_count
int counted(int v):
	eval_count = eval_count + 1
	return v


void test_scrutinee_evaluated_once():
	eval_count = 0
	switch (counted(2)):
		case 1:
			pass
		case 2:
			pass
		case 3:
			pass
	assert_equal(1, eval_count)
	# also evaluated exactly once when nothing matches
	eval_count = 0
	switch (counted(7)):
		case 1:
			pass
		case 2:
			pass
	assert_equal(1, eval_count)


void test_case_value_expressions():
	# Case values are general expressions, evaluated in order until a
	# match; values after the match are not evaluated
	eval_count = 0
	int two = 2
	int result = 0
	switch (two):
		case counted(1):
			result = 1
		case counted(2), counted(3):
			result = 2
		case counted(4):
			result = 3
	assert_equal(2, result)
	assert_equal(2, eval_count) /* counted(3) and counted(4) skipped */


void test_break_exits_switch_not_loop():
	int iterations = 0
	int after_break = 0
	for int i in range(4):
		switch (i):
			case 1, 3:
				break
				after_break = after_break + 100
			case 2:
				pass
		iterations = iterations + 1
	assert_equal(4, iterations) /* break left the switch, not the loop */
	assert_equal(0, after_break)


void test_continue_targets_loop():
	int total = 0
	for int i in range(6):
		switch (i % 3):
			case 0:
				continue
			case 1:
				total = total + 100
				break
				total = total + 1000
			default:
				total = total + 1
	assert_equal(202, total)


void test_loop_inside_switch():
	int sum = 0
	switch (1):
		case 1:
			for int i in range(10):
				if (i == 3):
					break
				sum = sum + i
			sum = sum + 1000
		case 2:
			sum = sum + 10000
	assert_equal(1003, sum) /* 0+1+2, break exits only the loop */


void test_break_in_loop_after_switch():
	# A loop's own break still works after a switch inside it finished
	int count = 0
	while (1):
		switch (count):
			case 0:
				pass
		count = count + 1
		if (count == 3):
			break
	assert_equal(3, count)


void test_scoped_locals_in_case_bodies():
	int result = 0
	switch (2):
		case 1:
			int a = 111
			result = a
		case 2:
			int a = 222
			int b = 3
			result = a + b
		default:
			int a = 999
			result = a
	assert_equal(225, result)


void test_nested_switch():
	int r = 0
	switch (1):
		case 1:
			switch (5):
				case 4:
					r = 40
				case 5:
					r = 50
					break
					r = 60
				default:
					r = 70
			r = r + 1
		case 2:
			r = 1000
	assert_equal(51, r)


void test_empty_switch_body():
	# A switch with no clauses is legal: only the scrutinee runs
	eval_count = 0
	switch (counted(3)):
	assert_equal(1, eval_count)


void test_switch_on_char():
	int vowels = 0
	char* s = c"weather"
	int i = 0
	while (s[i]):
		switch (s[i]):
			case 'a', 'e', 'i', 'o', 'u':
				vowels = vowels + 1
		i = i + 1
	assert_equal(3, vowels)


void test_case_and_default_stay_identifiers():
	# 'case' and 'default' are contextual keywords: outside a switch
	# body's clause labels they are ordinary identifiers
	int case = 4
	int default = 8
	switch (case + default):
		case 12:
			case = case + default
		default:
			case = 0
	assert_equal(12, case)
	assert_equal(8, default)


void test_break_in_plain_switch():
	# 'break' works in a switch outside any loop, and unwinds case-body
	# locals pushed after the switch started
	int r = 0
	switch (1):
		case 1:
			int local = 5
			r = r + local
			break
			r = r + 100
		default:
			r = 77
	assert_equal(5, r)


void test_switch_result_used_in_expression():
	assert_equal(30, classify(2) + classify(1))
