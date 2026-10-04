import lib.ndarray
import lib.matrix

int ast_nd_order
ndi* ast_nd_receiver(ndi* data):
	ast_nd_order = ast_nd_order * 10 + 1
	return data

int ast_nd_mark(int value, int mark):
	ast_nd_order = ast_nd_order * 10 + mark
	return value

int main():
	ndi values = ndi_new2(2, 2)
	ast_nd_receiver(&values)[ast_nd_mark(0, 2), ast_nd_mark(1, 3)] = ast_nd_mark(7, 4)
	if (ast_nd_order != 1234 || values[0, 1] != 7): return 1
	ast_nd_order = 0
	ast_nd_receiver(&values)[ast_nd_mark(0, 2), ast_nd_mark(1, 3)] += ast_nd_mark(2, 4)
	if (ast_nd_order != 1234 || values[0, 1] != 9): return 2
	int copied = values[1, 0] = values[0, 1]
	if (copied != 9 || values[1, 0] != 9): return 3
	values[0, 0] = 1
	values[values[0, 0], 1] = 12
	if (values[1, 1] != 12): return 4
	if ((values[0, 1]) + values[1, 0] != 18): return 5
	values[0.0, 1.5] *= 2
	if (values[0, 1] != 18): return 6
	ndf real = ndf_new2(2, 2)
	real[0, 1] = 2.5
	ndf_sub(&real, 0, 1)[0, 1] += 1.5
	if (real[0, 1] != 4.0): return 7
	ndi cube = ndi_new3(2, 2, 2)
	cube[1, 0, 1] = 11
	if (cube[1, 0, 1] != 11): return 8
	ndi hyper = ndi_new4(2, 2, 2, 2)
	hyper[1, 0, 1, 0] = 13
	if (hyper[1, 0, 1, 0] != 13): return 9
	matrix mat = matrix_from2(1.0, 2.0, 3.0, 4.0)
	mat[1, 0] += 2.0
	if (mat[1, 0] != 5.0 || (mat + mat)[0, 1] != 4.0): return 10
	return 0
