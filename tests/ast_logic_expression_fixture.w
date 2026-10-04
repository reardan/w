# Differential coverage for precedence, control flow and address-valued
# postfix nodes. This fixture runs natively and is compared on every backend.
struct ast_leaf:
	int16 small
	uint8 flag

struct ast_record:
	int prefix
	ast_leaf inner
	ast_leaf* link

union ast_union:
	int32 signed_part
	uint32 unsigned_part

int ast_logic_order

int ast_mark(int n):
	ast_logic_order = ast_logic_order * 10 + n
	return n

int ast_logic_pair(int a, int b): return a * 10 + b
ast_record* ast_record_identity(ast_record* p): return p


int main():
	int zero = 0
	int one = 1
	int two = 2
	if (!(zero && ast_mark(1) && ast_mark(2)) != true): return 1
	if ast_logic_order != 0: return 2
	if ((one || ast_mark(3) || ast_mark(4)) != true): return 3
	if ast_logic_order != 0: return 4
	if ((ast_mark(1) && ast_mark(2) && ast_mark(3)) != true): return 5
	if ast_logic_order != 123: return 6
	ast_logic_order = 0
	if ((zero || ast_mark(4) && ast_mark(5) || ast_mark(6)) != true): return 7
	if ast_logic_order != 45: return 8
	if (((zero || one) && (two && one)) != true): return 9
	if ((zero || (one || two)) != true): return 10
	if (((zero || one) || two) != true): return 11
	if ((one && (zero && two)) != false): return 12
	if (((one && zero) && two) != false): return 13
	if ((one + 2 * two >= 5 && zero == 0 || one > two) != true): return 14
	if ((one < two == one <= two) != true): return 15
	if ((two > one != two >= one) != false): return 16
	if ((two < one < two) != true): return 17
	if ((ast_logic_pair(one < two, zero || two)) != 11): return 18
	int* missing = 0
	if ((missing && missing[0]) != false): return 19
	if ((!missing || *missing) != true): return 20
	int16[3] values
	values[0] = -100
	values[1] = 200
	values[2] = 300
	int16* p = cast(int16*, values)
	if ((p[one] + (p + 2)[one]) != 500): return 21
	if ((p[one < two] == 200 && *p == -100) != true): return 22
	if 1: (p[one]) = 201
	if 1: (p[two]) += 2
	if ((p[one] + p[two]) != 503): return 23
	int16* address = (&p[one])
	if address != p + 2: return 24
	ast_record rec
	rec.prefix = 7
	rec.inner.small = -9
	rec.inner.flag = 250
	rec.link = &rec.inner
	ast_record* rp = &rec
	if ((rec.inner.small + rp.inner.flag) != 241): return 25
	if ((rp[0].link.small == -9 && rec.prefix == 7) != true): return 26
	if ((ast_record_identity(rp).inner.flag) != 250): return 27
	if 1: (rp.inner.small) = -11
	if 1: (rec.inner.flag) += 1
	if ((rec.link.small + rec.inner.flag) != 240): return 28
	int16* member = (&rec.inner.small)
	if (*member != -11): return 29
	float32 x = 1.5
	float32 y = 2.5
	if ((x < y && x <= y && y > x && y >= x) != true): return 30
	if ((x == y || x != x || x > y || x >= y) != false): return 31
	if ((x < 2 && 2 <= y && y > 2 && 2 >= x) != true): return 32
	float32 nan = 0.0 / 0.0
	bool expected = nan == x
	if ((nan == x) != expected): return 33
	expected = nan != x
	if ((nan != x) != expected): return 34
	expected = nan < x
	if ((nan < x) != expected): return 35
	expected = nan >= x
	if ((nan >= x) != expected): return 36
	if ((p == address || p > address) != false): return 37
	if ((p < address && address != p) != true): return 38
	if (((*rp).inner.small) != -11): return 39
	ast_record[2] records
	records[1].inner.small = 1234
	ast_record* rows = cast(ast_record*, records)
	if ((rows[one].inner.small) != 1234): return 40
	ast_union shared
	shared.signed_part = 42
	if ((shared.unsigned_part) != 42): return 41
	ast_logic_order = 0
	if ((p[ast_mark(1)] == 201 && ast_mark(2) > 0) != true): return 42
	if ast_logic_order != 12: return 43
	return 0
