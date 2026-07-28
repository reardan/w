# wbuild: x64
import lib.testing
import lib.math
import lib.edit_distance


# Naive exponential reference: distance between a[ai ..] and b[bi ..].
# Only run on short strings; exists to cross-check the two-row DP.
int reference_levenshtein(char* a, int ai, char* b, int bi):
	if (a[ai] == 0):
		return strlen(&b[bi])
	if (b[bi] == 0):
		return strlen(&a[ai])
	if (a[ai] == b[bi]):
		return reference_levenshtein(a, ai + 1, b, bi + 1)
	int substitute = reference_levenshtein(a, ai + 1, b, bi + 1)
	int delete_a = reference_levenshtein(a, ai + 1, b, bi)
	int insert_a = reference_levenshtein(a, ai, b, bi + 1)
	return 1 + min(substitute, min(delete_a, insert_a))


void test_levenshtein_classic_pairs():
	assert_equal(3, levenshtein(c"kitten", c"sitting"))
	assert_equal(3, levenshtein(c"saturday", c"sunday"))
	assert_equal(5, levenshtein(c"intention", c"execution"))
	assert_equal(2, levenshtein(c"flaw", c"lawn"))
	assert_equal(1, levenshtein(c"horse", c"morse"))
	assert_equal(3, levenshtein(c"horse", c"ros"))
	assert_equal(8, levenshtein(c"rosettacode", c"raisethysword"))


void test_levenshtein_empty_and_identical():
	assert_equal(0, levenshtein(c"", c""))
	assert_equal(3, levenshtein(c"", c"abc"))
	assert_equal(3, levenshtein(c"abc", c""))
	assert_equal(0, levenshtein(c"same", c"same"))
	assert_equal(0, levenshtein(c"x", c"x"))
	assert_equal(1, levenshtein(c"x", c"y"))
	assert_equal(1, levenshtein(c"", c"x"))


void test_levenshtein_pure_operations():
	# pure insertions / deletions
	assert_equal(2, levenshtein(c"abc", c"aXbYc"))
	assert_equal(2, levenshtein(c"aXbYc", c"abc"))
	# pure substitutions
	assert_equal(3, levenshtein(c"abc", c"xyz"))
	# prefix and suffix relations
	assert_equal(3, levenshtein(c"abc", c"abcdef"))
	assert_equal(3, levenshtein(c"def", c"abcdef"))


void test_levenshtein_symmetry():
	assert_equal(levenshtein(c"kitten", c"sitting"), levenshtein(c"sitting", c"kitten"))
	assert_equal(levenshtein(c"", c"abc"), levenshtein(c"abc", c""))
	assert_equal(levenshtein(c"flaw", c"lawn"), levenshtein(c"lawn", c"flaw"))
	assert_equal(levenshtein(c"ab", c"ba"), levenshtein(c"ba", c"ab"))


void test_levenshtein_matches_reference():
	list[char*] words = list[char*]{c"", c"a", c"ab", c"ba", c"abc", c"cab", c"abcd", c"axbc", c"bcda"}
	int i = 0
	while (i < words.length):
		int j = 0
		while (j < words.length):
			int want = reference_levenshtein(words[i], 0, words[j], 0)
			assert_equal(want, levenshtein(words[i], words[j]))
			j = j + 1
		i = i + 1


void test_levenshtein_repeated_characters():
	assert_equal(1, levenshtein(c"aaaa", c"aaaaa"))
	assert_equal(4, levenshtein(c"aaaa", c"bbbb"))
	assert_equal(2, levenshtein(c"abab", c"baba"))


void test_hamming_classic_pairs():
	assert_equal(3, hamming(c"karolin", c"kathrin"))
	assert_equal(3, hamming(c"karolin", c"kerstin"))
	assert_equal(2, hamming(c"1011101", c"1001001"))
	assert_equal(3, hamming(c"2173896", c"2233796"))
	assert_equal(0, hamming(c"same", c"same"))
	assert_equal(4, hamming(c"abcd", c"dcba"))


void test_hamming_empty():
	assert_equal(0, hamming(c"", c""))


void test_hamming_length_mismatch_returns_minus_one():
	assert_equal(-1, hamming(c"abc", c"ab"))
	assert_equal(-1, hamming(c"ab", c"abc"))
	assert_equal(-1, hamming(c"", c"a"))
	assert_equal(-1, hamming(c"a", c""))
	# equal prefix does not mask the length difference
	assert_equal(-1, hamming(c"abc", c"abcd"))


void test_hamming_agrees_with_levenshtein_upper_bound():
	# for equal-length strings, levenshtein <= hamming
	assert1(levenshtein(c"karolin", c"kathrin") <= hamming(c"karolin", c"kathrin"))
	assert1(levenshtein(c"abcd", c"dcba") <= hamming(c"abcd", c"dcba"))
	assert1(levenshtein(c"abab", c"baba") <= hamming(c"abab", c"baba"))
