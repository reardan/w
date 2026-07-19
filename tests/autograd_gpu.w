# lib.autograd end-to-end test (docs/projects/torch.md, Stage 5): every
# fully-implemented backward rule (add, mul, add_scalar, mul_scalar, relu,
# sum, matmul) is cross-checked against a central-difference numeric
# gradient computed by an independent reference evaluator -- plain host
# loops over each tensor's own .data buffer, sharing no code with
# lib/autograd.w or lib/tensor.w's op implementations -- plus a
# gradient-accumulation case (a leaf consumed by two different ops) and a
# chain test (sum(mul(add(a,b),c))-shaped).
#
# Mirrors tests/tensor_gpu.w: the autograd_gpu_test target is opt-in
# (running needs libcuda at load time, like every lib.tensor consumer);
# autograd_compile_test compiles this file in the default umbrella so
# device-subset regressions are caught GPU-less. x64-only, so both targets
# are hand-declared in build.base.json (no *_test.w autotwin).
import lib.lib
import lib.autograd


# |a - b| <= eps, without pulling in fmath.
int feq(float a, float b, float eps):
	float d = a - b
	if (d < 0.0):
		d = 0.0 - d
	return d <= eps


# Central-difference derivative of f at x (perturbing by +-h), without
# calling f itself -- callers pass the two already-evaluated samples.
float central_diff(float f_plus, float f_minus, float h):
	return (f_plus - f_minus) / (2.0 * h)


##### chain test: sum(mul(add(a, b), c)) #####


float ref_chain(tensor* a, tensor* b, tensor* c):
	float total = 0.0
	int i = 0
	while (i < a.len):
		total = total + (a.data[i] + b.data[i]) * c.data[i]
		i = i + 1
	return total


int check_chain():
	int n = 6
	tensor a = tensor_new1(n)
	tensor b = tensor_new1(n)
	tensor c = tensor_new1(n)
	int i = 0
	while (i < n):
		a.data[i] = (cast(float, i) - 2.0) * 0.7
		b.data[i] = (cast(float, 2 * i) - 3.0) * 0.5
		c.data[i] = (cast(float, i) + 1.0) * 0.3
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	tensor* lb = ag_leaf(t, &b)
	tensor* lc = ag_leaf(t, &c)
	tensor* s = ag_add(t, la, lb)
	tensor* m = ag_mul(t, s, lc)
	ag_sum(t, m)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)
	tensor* gb = ag_grad(t, lb)
	tensor* gc = ag_grad(t, lc)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_chain(&a, &b, &c)
		a.data[i] = orig - h
		float fm = ref_chain(&a, &b, &c)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < n):
		float orig = b.data[i]
		b.data[i] = orig + h
		float fp = ref_chain(&a, &b, &c)
		b.data[i] = orig - h
		float fm = ref_chain(&a, &b, &c)
		b.data[i] = orig
		if (feq(central_diff(fp, fm, h), gb.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < n):
		float orig = c.data[i]
		c.data[i] = orig + h
		float fp = ref_chain(&a, &b, &c)
		c.data[i] = orig - h
		float fm = ref_chain(&a, &b, &c)
		c.data[i] = orig
		if (feq(central_diff(fp, fm, h), gc.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&c)
	return ok


##### add_scalar: sum(mul(add_scalar(a, k), w)) #####


float ref_add_scalar(tensor* a, tensor* w, float k):
	float total = 0.0
	int i = 0
	while (i < a.len):
		total = total + (a.data[i] + k) * w.data[i]
		i = i + 1
	return total


int check_add_scalar():
	int n = 5
	tensor a = tensor_new1(n)
	tensor w = tensor_new1(n)
	float k = 1.7
	int i = 0
	while (i < n):
		a.data[i] = cast(float, i - 1) * 0.9
		w.data[i] = cast(float, i + 2) * 0.4
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	tensor* lw = ag_leaf(t, &w)
	tensor* s = ag_add_scalar(t, la, k)
	tensor* m = ag_mul(t, s, lw)
	ag_sum(t, m)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_add_scalar(&a, &w, k)
		a.data[i] = orig - h
		float fm = ref_add_scalar(&a, &w, k)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&w)
	return ok


##### mul_scalar: sum(mul_scalar(a, k)) #####


float ref_mul_scalar(tensor* a, float k):
	float total = 0.0
	int i = 0
	while (i < a.len):
		total = total + a.data[i] * k
		i = i + 1
	return total


int check_mul_scalar():
	int n = 5
	tensor a = tensor_new1(n)
	float k = 3.0
	int i = 0
	while (i < n):
		a.data[i] = cast(float, i - 2) * 1.1
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	ag_sum(t, ag_mul_scalar(t, la, k))
	ag_backward(t)
	tensor* ga = ag_grad(t, la)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_mul_scalar(&a, k)
		a.data[i] = orig - h
		float fm = ref_mul_scalar(&a, k)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	return ok


##### sum: sum(a) #####


float ref_sum(tensor* a):
	float total = 0.0
	int i = 0
	while (i < a.len):
		total = total + a.data[i]
		i = i + 1
	return total


int check_sum():
	int n = 7
	tensor a = tensor_new1(n)
	int i = 0
	while (i < n):
		a.data[i] = cast(float, i - 3) * 0.6
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	ag_sum(t, la)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_sum(&a)
		a.data[i] = orig - h
		float fm = ref_sum(&a)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	return ok


##### relu: sum(mul(relu(a), w)) -- inputs kept away from the kink at 0 #####


float ref_relu(tensor* a, tensor* w):
	float total = 0.0
	int i = 0
	while (i < a.len):
		float x = a.data[i]
		if (x < 0.0):
			x = 0.0
		total = total + x * w.data[i]
		i = i + 1
	return total


int check_relu():
	int n = 6
	tensor a = tensor_new1(n)
	tensor w = tensor_new1(n)
	int i = 0
	while (i < n):
		# alternate signs, magnitude >= 0.4 so h=0.01 never crosses 0
		float mag = cast(float, i + 1) * 0.4
		if (i % 2 == 0):
			a.data[i] = mag
		else:
			a.data[i] = 0.0 - mag
		w.data[i] = cast(float, i + 1) * 0.3
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	tensor* lw = ag_leaf(t, &w)
	tensor* r = ag_relu(t, la)
	tensor* m = ag_mul(t, r, lw)
	ag_sum(t, m)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_relu(&a, &w)
		a.data[i] = orig - h
		float fm = ref_relu(&a, &w)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&w)
	return ok


##### matmul: sum(mul(matmul(a, b), w)) #####


float ref_matmul(tensor* a, tensor* b, tensor* w, int m, int k, int n):
	float total = 0.0
	int i = 0
	while (i < m):
		int j = 0
		while (j < n):
			float acc = 0.0
			int p = 0
			while (p < k):
				acc = acc + a.data[i * k + p] * b.data[p * n + j]
				p = p + 1
			total = total + acc * w.data[i * n + j]
			j = j + 1
		i = i + 1
	return total


int check_matmul():
	int m = 3
	int k = 4
	int n = 2
	tensor a = tensor_new2(m, k)
	tensor b = tensor_new2(k, n)
	tensor w = tensor_new2(m, n)
	int i = 0
	while (i < m * k):
		a.data[i] = cast(float, i % 5 - 2) * 0.5
		i = i + 1
	i = 0
	while (i < k * n):
		b.data[i] = cast(float, i % 3 - 1) * 0.6
		i = i + 1
	i = 0
	while (i < m * n):
		w.data[i] = cast(float, i + 1) * 0.25
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	tensor* lb = ag_leaf(t, &b)
	tensor* lw = ag_leaf(t, &w)
	tensor* mm = ag_matmul(t, la, lb)
	tensor* mul = ag_mul(t, mm, lw)
	ag_sum(t, mul)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)
	tensor* gb = ag_grad(t, lb)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < m * k):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_matmul(&a, &b, &w, m, k, n)
		a.data[i] = orig - h
		float fm = ref_matmul(&a, &b, &w, m, k, n)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < k * n):
		float orig = b.data[i]
		b.data[i] = orig + h
		float fp = ref_matmul(&a, &b, &w, m, k, n)
		b.data[i] = orig - h
		float fm = ref_matmul(&a, &b, &w, m, k, n)
		b.data[i] = orig
		if (feq(central_diff(fp, fm, h), gb.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&w)
	return ok


##### accumulation: a leaf x feeding two different ops into a shared sum #####
# loss = sum(mul_scalar(x, 2) + relu(x)); dL/dx_i = 2 + (1 if x_i > 0 else 0).
# The x used by mul_scalar and the x used by relu are the SAME tensor*, so
# ag_grad(t, x) must return one grad tensor that both nodes accumulate into.


float ref_accum(tensor* x):
	float total = 0.0
	int i = 0
	while (i < x.len):
		float v = x.data[i]
		float r = v
		if (r < 0.0):
			r = 0.0
		total = total + 2.0 * v + r
		i = i + 1
	return total


int check_accum():
	int n = 6
	tensor x = tensor_new1(n)
	int i = 0
	while (i < n):
		float mag = cast(float, i + 1) * 0.35
		if (i % 2 == 0):
			x.data[i] = mag
		else:
			x.data[i] = 0.0 - mag
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* lx = ag_leaf(t, &x)
	tensor* p = ag_mul_scalar(t, lx, 2.0)
	tensor* q = ag_relu(t, lx)
	tensor* r = ag_add(t, p, q)
	ag_sum(t, r)
	ag_backward(t)
	tensor* gx = ag_grad(t, lx)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n):
		float orig = x.data[i]
		x.data[i] = orig + h
		float fp = ref_accum(&x)
		x.data[i] = orig - h
		float fm = ref_accum(&x)
		x.data[i] = orig
		if (feq(central_diff(fp, fm, h), gx.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&x)
	return ok


int main(int argc, int argv):
	if (gpu_available()):
		println(c"autograd: gpu path")
	else:
		println(c"autograd: cpu fallback")
	if (check_chain() == 0):
		println(c"autograd gpu: FAILED (chain)")
		return 1
	if (check_add_scalar() == 0):
		println(c"autograd gpu: FAILED (add_scalar)")
		return 1
	if (check_mul_scalar() == 0):
		println(c"autograd gpu: FAILED (mul_scalar)")
		return 1
	if (check_sum() == 0):
		println(c"autograd gpu: FAILED (sum)")
		return 1
	if (check_relu() == 0):
		println(c"autograd gpu: FAILED (relu)")
		return 1
	if (check_matmul() == 0):
		println(c"autograd gpu: FAILED (matmul)")
		return 1
	if (check_accum() == 0):
		println(c"autograd gpu: FAILED (accum)")
		return 1
	println(c"autograd OK")
	return 0
