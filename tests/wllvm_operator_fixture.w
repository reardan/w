# Shared differential input for the production x64 backend and wllvm:
# operator overloads (record and scalar results, mixed operand types),
# methods returning records, ndarray comma indexing (read, write and
# compound, float and int elements), a global named operator, bare
# println(), float32 print, and an asm function (lowered from its
# assembled block). Output and exit status must match exactly.
import lib.lib
import lib.ndarray


struct op_pair:
	int x
	int y


op_pair operator+(op_pair a, op_pair b):
	return op_pair(a.x + b.x, a.y + b.y)
int operator*(op_pair a, op_pair b): return a.x * b.x + a.y * b.y
op_pair operator*(op_pair a, float32 scale):
	return op_pair(cast(int, a.x * scale), cast(int, a.y * scale))


op_pair op_pair_doubled(op_pair* self):
	return op_pair(self.x * 2, self.y * 2)


int op_pair_total(op_pair* self): return self.x + self.y


# 'operator' outside a definition-name position is an ordinary global.
int operator


int op_asm_add(int a, int b):
	asm x64:
		"mov rax,[rsp+0x10]"
		"add rax,[rsp+8]"
		"ret"
	return a + b


int main():
	int score = 0
	op_pair a = op_pair(2, 3)
	op_pair b = op_pair(4, 5)
	if ((a + b).x == 6 && (a + b + a).y == 11): score += 1
	if (a * b == 23 && (a * 2.5).y == 7): score += 1
	if (a.doubled().total() == 10 && (a + b).doubled().x == 12): score += 1
	ndi m = ndi_new2(2, 3)
	m[1, 2] = 9
	m[1, 2] += 4
	m[0, 1] = m[1, 2] * 2
	if (m[1, 2] == 13 && m[0, 1] == 26 && ndi_at2(&m, 1, 2) == 13): score += 1
	ndf f = ndf_new2(2, 2)
	ndf* fp = &f
	fp[1, 1] = 1.5
	fp[1, 1] *= 3.0
	if (f[1, 1] == 4.5): score += 1
	operator = 41
	operator = operator + 1
	if (operator == 42): score += 1
	if (op_asm_add(3, 4) == 7): score += 1
	print(score)
	println()
	float32 fraction = 1.5
	println(fraction)
	println(score)
	return score
