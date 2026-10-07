/* C twin of tests/bench/regex_backtrack.w (see bench.h): a port of
 * lib/regex.w -- the same recursive backtracking matcher with the same
 * step budget, class walk and quantifier loop -- driven by the same text
 * and patterns. */
#include "bench.h"

#define RX_STEP_BUDGET 1048576

static int rx_is_quantifier(int c) {
	if (c == '*') return 1;
	if (c == '+') return 1;
	return c == '?';
}

static int rx_is_alnum(int c) {
	if (c >= '0' && c <= '9') return 1;
	if (c >= 'a' && c <= 'z') return 1;
	return c >= 'A' && c <= 'Z';
}

static int rx_escape_char(const char* pattern, word pp) {
	int c = pattern[pp + 1] & 255;
	switch (c) {
		case 0: return -1;
		case 't': return 9;
		case 'n': return 10;
		case 'r': return 13;
	}
	if (rx_is_alnum(c)) return -1;
	return c;
}

static word rx_class_end(const char* pattern, word pp) {
	word i = pp + 1;
	if (pattern[i] == '^') i = i + 1;
	int first = 1;
	while (1) {
		if (pattern[i] == 0) return -1;
		if (pattern[i] == ']' && first == 0) return i;
		first = 0;
		int lo = 0;
		if (pattern[i] == '\\') {
			lo = rx_escape_char(pattern, i);
			if (lo < 0) return -1;
			i = i + 2;
		} else {
			lo = pattern[i] & 255;
			i = i + 1;
		}
		if (pattern[i] == '-' && pattern[i + 1] != ']' && pattern[i + 1] != 0) {
			i = i + 1;
			int hi = 0;
			if (pattern[i] == '\\') {
				hi = rx_escape_char(pattern, i);
				if (hi < 0) return -1;
				i = i + 2;
			} else {
				hi = pattern[i] & 255;
				i = i + 1;
			}
			if (lo > hi) return -1;
		}
	}
	return -1;
}

static int rx_class_matches(const char* pattern, word pp, int c) {
	word i = pp + 1;
	int negate = 0;
	if (pattern[i] == '^') {
		negate = 1;
		i = i + 1;
	}
	int found = 0;
	int first = 1;
	while (1) {
		if (pattern[i] == 0 || (pattern[i] == ']' && first == 0)) {
			if (negate) return 1 - found;
			return found;
		}
		first = 0;
		int lo = 0;
		if (pattern[i] == '\\') {
			lo = rx_escape_char(pattern, i);
			i = i + 2;
		} else {
			lo = pattern[i] & 255;
			i = i + 1;
		}
		int hi = lo;
		if (pattern[i] == '-' && pattern[i + 1] != ']' && pattern[i + 1] != 0) {
			i = i + 1;
			if (pattern[i] == '\\') {
				hi = rx_escape_char(pattern, i);
				i = i + 2;
			} else {
				hi = pattern[i] & 255;
				i = i + 1;
			}
		}
		if (c >= lo && c <= hi) found = 1;
	}
	return 0;
}

static word rx_element_length(const char* pattern, word pp) {
	int c = pattern[pp] & 255;
	if (c == '[') {
		word end = rx_class_end(pattern, pp);
		if (end < 0) return -1;
		return end - pp + 1;
	}
	if (c == '\\') {
		if (rx_escape_char(pattern, pp) < 0) return -1;
		return 2;
	}
	return 1;
}

static int rx_element_matches(const char* pattern, word pp, int c) {
	int pc = pattern[pp] & 255;
	if (pc == '[') return rx_class_matches(pattern, pp, c);
	if (pc == '\\') return c == rx_escape_char(pattern, pp);
	if (pc == '.') return c != 10;
	return c == pc;
}

static word rx_here(const char* pattern, word pp, const char* text, word tp, int must_end, word* steps) {
	if (steps[0] <= 0) return -1;
	steps[0] = steps[0] - 1;
	if (pattern[pp] == 0) {
		if (must_end != 0 && text[tp] != 0) return -1;
		return 0;
	}
	if (pattern[pp] == '$' && pattern[pp + 1] == 0) {
		if (text[tp] == 0) return 0;
		return -1;
	}
	word el = rx_element_length(pattern, pp);
	int q = pattern[pp + el] & 255;
	if (rx_is_quantifier(q)) {
		word max_count = 0;
		while (text[tp + max_count] != 0 && rx_element_matches(pattern, pp, text[tp + max_count] & 255)) {
			max_count = max_count + 1;
			steps[0] = steps[0] - 1;
			if (steps[0] <= 0 || (q == '?' && max_count == 1)) break;
		}
		if (steps[0] <= 0) return -1;
		word min_count = 0;
		if (q == '+') min_count = 1;
		word count = max_count;
		while (count >= min_count) {
			word rest = rx_here(pattern, pp + el + 1, text, tp + count, must_end, steps);
			if (rest >= 0) return count + rest;
			if (steps[0] <= 0) return -1;
			count = count - 1;
		}
		return -1;
	}
	if (text[tp] != 0 && rx_element_matches(pattern, pp, text[tp] & 255)) {
		word rest = rx_here(pattern, pp + el, text, tp + 1, must_end, steps);
		if (rest >= 0) return rest + 1;
	}
	return -1;
}

static int regex_valid(const char* pattern) {
	word i = 0;
	if (pattern[i] == '^') i = i + 1;
	int prev_element = 0;
	while (pattern[i] != 0) {
		int c = pattern[i] & 255;
		if (rx_is_quantifier(c)) {
			if (prev_element == 0) return 0;
			prev_element = 0;
			i = i + 1;
		} else if (c == '$' && pattern[i + 1] == 0) i = i + 1;
		else {
			word el = rx_element_length(pattern, i);
			if (el < 0) return 0;
			prev_element = 1;
			i = i + el;
		}
	}
	return 1;
}

static word regex_match(const char* pattern, const char* text) {
	if (regex_valid(pattern) == 0) return 0;
	word pp = 0;
	if (pattern[0] == '^') pp = 1;
	word steps = RX_STEP_BUDGET;
	word length = rx_here(pattern, pp, text, 0, 1, &steps);
	if (length < 0) return 0;
	return 1;
}

static word regex_search(const char* pattern, const char* text) {
	if (regex_valid(pattern) == 0) return -1;
	int anchored = 0;
	word pp = 0;
	if (pattern[0] == '^') {
		anchored = 1;
		pp = 1;
	}
	word steps = RX_STEP_BUDGET;
	word tp = 0;
	while (1) {
		word length = rx_here(pattern, pp, text, tp, 0, &steps);
		if (length >= 0) return tp;
		if (steps <= 0) return -1;
		if (anchored) return -1;
		if (text[tp] == 0) return -1;
		tp = tp + 1;
	}
	return -1;
}

static word regex_match_length(const char* pattern, const char* text, word start) {
	if (start < 0) return -1;
	if (regex_valid(pattern) == 0) return -1;
	word pp = 0;
	if (pattern[0] == '^') {
		if (start != 0) return -1;
		pp = 1;
	}
	word i = 0;
	while (i < start && text[i] != 0) i = i + 1;
	if (i < start) return -1;
	word steps = RX_STEP_BUDGET;
	return rx_here(pattern, pp, text, start, 0, &steps);
}

static char* rb_text(word n) {
	char* text = malloc(n + 1);
	uint32_t state = 123456789;
	word i = 0;
	while (i < n) {
		uint32_t r = bench_rand(&state) & 63;
		if (r < 48) text[i] = 'a' + ((bench_rand(&state) & 0x7fffffff) % 26);
		else if (r < 62) text[i] = ' ';
		else text[i] = 10;
		i = i + 1;
	}
	text[n] = 0;
	return text;
}

int main(int argc, char** argv) {
	word rounds = bench_size(argc, argv, 24);
	char* text = rb_text(16384);
	char run[65];
	memset(run, 'a', 64);
	run[64] = 0;
	uint32_t h = 0;
	word r = 0;
	while (r < rounds) {
		h = bench_fold(h, (uint32_t)regex_match("a*a*a*a*b", run));
		h = bench_fold(h, (uint32_t)regex_search("zq", text));
		h = bench_fold(h, (uint32_t)regex_search("[a-m]+ [n-z]+ [a-m]+ q", text));
		h = bench_fold(h, (uint32_t)regex_search("x.*y.*zz$", text));
		h = bench_fold(h, (uint32_t)regex_search("qu[aeiou]+x", text));
		word pos = 0;
		word lines = 0;
		while (text[pos] != 0) {
			word len = regex_match_length("[a-z ]*[aeiou]q", text, pos);
			if (len > 0) lines = lines + 1;
			while (text[pos] != 0 && text[pos] != 10) pos = pos + 1;
			if (text[pos] == 10) pos = pos + 1;
		}
		h = bench_fold(h, (uint32_t)lines);
		r = r + 1;
	}
	bench_report("regex_backtrack", rounds, h);
	return 0;
}
