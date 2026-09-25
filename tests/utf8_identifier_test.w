# wbuild: x64
# UTF-8 identifiers (issue #287 stage 2): any well-formed UTF-8 sequence
# outside the security floor in compiler/tokenizer.w's
# ident_codepoint_rejection can name a variable, parameter, function,
# struct, field, enum member, generic parameter or type alias. Names are
# compared byte for byte (no normalization); the negative twins in
# tests/utf8_identifier_*_fixture.w cover the rejected codepoints.
import lib.testing


struct Café:
	int größe
	int 数量


enum Farbe:
	ROT
	GRÜN
	BLAU


type Größe = int


int verdoppeln(int π):
	return π * 2


int 合計(Café* c):
	return c.größe + c.数量


struct Paar[T]:
	T ερώτηση
	T απάντηση


T erstes[T](Paar[T]* p):
	return p.ερώτηση


void test_variables_and_functions():
	int naïve = 1
	Größe größe = verdoppeln(naïve + 2)
	assert_equal(6, größe)
	# an emoji is just another non-ASCII codepoint
	int 🎉 = größe + 1
	assert_equal(7, 🎉)
	# inferred declaration
	日本 := 10
	assert_equal(10, 日本)


void test_struct_fields_and_enums():
	Café c
	c.größe = 3
	c.数量 = 4
	assert_equal(7, 合計(&c))
	Farbe f = GRÜN
	assert_equal(1, f)
	assert_equal(2, BLAU)


void test_generics():
	Paar[int] p
	p.ερώτηση = 41
	p.απάντηση = 42
	assert_equal(41, erstes[int](&p))
	assert_equal(42, p.απάντηση)


void test_loops_and_containers():
	int Σ = 0
	for ι in range(4): Σ = Σ + ι
	assert_equal(6, Σ)
	map[int, int] κλειδιά = new map[int, int]
	κλειδιά[1] = 2
	assert_equal(2, κλειδιά[1])
	list[int] λίστα = list[int]{5, 6}
	assert_equal(2, λίστα.length)
	assert_equal(6, λίστα[1])


void test_ascii_prefix_is_not_a_separate_token():
	# The tokenizer used to end the identifier at the first byte >= 0x80;
	# 'caf' and 'café' must be distinct whole names.
	int caf = 1
	int café = 2
	assert_equal(3, caf + café)


void test_goto_label():
	int n = 0
	goto ziel
	n = 100
	ziel:
	n = n + 1
	assert_equal(1, n)
