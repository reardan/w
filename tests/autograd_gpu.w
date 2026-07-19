# lib.autograd end-to-end test (docs/projects/torch.md, Stage 5): every
# fully-implemented backward rule (add, mul, add_scalar, mul_scalar, relu,
# sum, matmul, add_row, softmax_ce, and the transformer set: matmul_nt,
# layernorm, softmax_causal, embedding) is cross-checked against a
# central-difference numeric gradient computed by an independent
# reference evaluator -- plain host loops over each tensor's own .data
# buffer, sharing no code with lib/autograd.w or lib/tensor.w's op
# implementations -- plus a gradient-accumulation case (a leaf consumed
# by two different ops) and a chain test (sum(mul(add(a,b),c))-shaped).
#
# Mirrors tests/tensor_gpu.w: the autograd_gpu_test target is opt-in
# (running needs libcuda at load time, like every lib.tensor consumer);
# autograd_compile_test compiles this file in the default umbrella so
# device-subset regressions are caught GPU-less. x64-only, so both targets
# are hand-declared in build.base.json (no *_test.w autotwin).
import lib.lib
import lib.autograd
import lib.ndarray
import lib.fmath


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


##### add_row: sum(mul(add_row(a, r), w)) #####


float ref_add_row(tensor* a, tensor* r, tensor* w, int m, int n):
	float total = 0.0
	int i = 0
	while (i < m):
		int j = 0
		while (j < n):
			total = total + (a.data[i * n + j] + r.data[j]) * w.data[i * n + j]
			j = j + 1
		i = i + 1
	return total


int check_add_row():
	int m = 4
	int n = 5
	tensor a = tensor_new2(m, n)
	tensor r = tensor_new1(n)
	tensor w = tensor_new2(m, n)
	int i = 0
	while (i < m * n):
		a.data[i] = cast(float, i % 7 - 3) * 0.4
		w.data[i] = cast(float, i % 5 + 1) * 0.2
		i = i + 1
	i = 0
	while (i < n):
		r.data[i] = cast(float, i - 2) * 0.3
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* la = ag_leaf(t, &a)
	tensor* lr = ag_leaf(t, &r)
	tensor* lw = ag_leaf(t, &w)
	tensor* s = ag_add_row(t, la, lr)
	tensor* mres = ag_mul(t, s, lw)
	ag_sum(t, mres)
	ag_backward(t)
	tensor* ga = ag_grad(t, la)
	tensor* gr = ag_grad(t, lr)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < m * n):
		float orig = a.data[i]
		a.data[i] = orig + h
		float fp = ref_add_row(&a, &r, &w, m, n)
		a.data[i] = orig - h
		float fm = ref_add_row(&a, &r, &w, m, n)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < n):
		float orig2 = r.data[i]
		r.data[i] = orig2 + h
		float fp2 = ref_add_row(&a, &r, &w, m, n)
		r.data[i] = orig2 - h
		float fm2 = ref_add_row(&a, &r, &w, m, n)
		r.data[i] = orig2
		if (feq(central_diff(fp2, fm2, h), gr.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&r)
	tensor_free(&w)
	return ok


##### softmax_ce: fused row-wise softmax + mean cross-entropy #####


float ref_softmax_ce(tensor* logits, ndi* labels, int batch, int classes):
	float total = 0.0
	int i = 0
	while (i < batch):
		float m = logits.data[i * classes]
		int j = 1
		while (j < classes):
			float v = logits.data[i * classes + j]
			if (v > m):
				m = v
			j = j + 1
		float rowsum = 0.0
		j = 0
		while (j < classes):
			rowsum = rowsum + fexp(logits.data[i * classes + j] - m)
			j = j + 1
		int lbl = labels.data[i]
		float p_lbl = fexp(logits.data[i * classes + lbl] - m) / rowsum
		total = total - flog(p_lbl)
		i = i + 1
	return total / cast(float, batch)


int check_softmax_ce():
	int batch = 5
	int classes = 3
	tensor logits = tensor_new2(batch, classes)
	ndi labels = ndi_new1(batch)
	int i = 0
	while (i < batch * classes):
		logits.data[i] = cast(float, (i * 7) % 11 - 5) * 0.3
		i = i + 1
	i = 0
	while (i < batch):
		labels.data[i] = i % classes
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* llog = ag_leaf(t, &logits)
	ag_softmax_ce(t, llog, &labels)
	ag_backward(t)
	tensor* glog = ag_grad(t, llog)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < batch * classes):
		float orig = logits.data[i]
		logits.data[i] = orig + h
		float fp = ref_softmax_ce(&logits, &labels, batch, classes)
		logits.data[i] = orig - h
		float fm = ref_softmax_ce(&logits, &labels, batch, classes)
		logits.data[i] = orig
		if (feq(central_diff(fp, fm, h), glog.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&logits)
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


##### matmul_nt: sum(mul(a @ b^T, w)) #####


float ref_matmul_nt(tensor* a, tensor* b, tensor* w, int m, int k, int n):
	float total = 0.0
	int i = 0
	while (i < m):
		int j = 0
		while (j < n):
			float acc = 0.0
			int l = 0
			while (l < k):
				acc = acc + a.data[i * k + l] * b.data[j * k + l]
				l = l + 1
			total = total + acc * w.data[i * n + j]
			j = j + 1
		i = i + 1
	return total


int check_matmul_nt():
	int m = 3
	int k = 4
	int n = 2
	tensor a = tensor_new2(m, k)
	tensor b = tensor_new2(n, k)
	tensor w = tensor_new2(m, n)
	int i = 0
	while (i < m * k):
		a.data[i] = cast(float, i % 5 - 2) * 0.5
		i = i + 1
	i = 0
	while (i < n * k):
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
	tensor* mm = ag_matmul_nt(t, la, lb)
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
		float fp = ref_matmul_nt(&a, &b, &w, m, k, n)
		a.data[i] = orig - h
		float fm = ref_matmul_nt(&a, &b, &w, m, k, n)
		a.data[i] = orig
		if (feq(central_diff(fp, fm, h), ga.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < n * k):
		float orig = b.data[i]
		b.data[i] = orig + h
		float fp = ref_matmul_nt(&a, &b, &w, m, k, n)
		b.data[i] = orig - h
		float fm = ref_matmul_nt(&a, &b, &w, m, k, n)
		b.data[i] = orig
		if (feq(central_diff(fp, fm, h), gb.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&w)
	return ok


##### layernorm: sum(mul(layernorm(x, gamma, beta), w)) #####


float ref_layernorm(tensor* x, tensor* gamma, tensor* beta, tensor* w, int m, int n):
	float total = 0.0
	float fn = cast(float, n)
	int i = 0
	while (i < m):
		float mean = 0.0
		int j = 0
		while (j < n):
			mean = mean + x.data[i * n + j]
			j = j + 1
		mean = mean / fn
		float vsum = 0.0
		j = 0
		while (j < n):
			float d = x.data[i * n + j] - mean
			vsum = vsum + d * d
			j = j + 1
		float rstd = 1.0 / fsqrt(vsum / fn + 0.00001)
		j = 0
		while (j < n):
			float ln = gamma.data[j] * ((x.data[i * n + j] - mean) * rstd) + beta.data[j]
			total = total + ln * w.data[i * n + j]
			j = j + 1
		i = i + 1
	return total


int check_layernorm():
	int m = 3
	int n = 5
	tensor x = tensor_new2(m, n)
	tensor gamma = tensor_new1(n)
	tensor beta = tensor_new1(n)
	tensor w = tensor_new2(m, n)
	int i = 0
	while (i < m * n):
		x.data[i] = cast(float, i % 7 - 3) * 0.4
		w.data[i] = cast(float, i % 4 + 1) * 0.3
		i = i + 1
	i = 0
	while (i < n):
		gamma.data[i] = 1.0 + cast(float, i) * 0.1
		beta.data[i] = cast(float, i % 3 - 1) * 0.2
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* lx = ag_leaf(t, &x)
	tensor* lg = ag_leaf(t, &gamma)
	tensor* lb = ag_leaf(t, &beta)
	tensor* lw = ag_leaf(t, &w)
	tensor* ln = ag_layernorm(t, lx, lg, lb)
	tensor* mul = ag_mul(t, ln, lw)
	ag_sum(t, mul)
	ag_backward(t)
	tensor* gx = ag_grad(t, lx)
	tensor* gg = ag_grad(t, lg)
	tensor* gb2 = ag_grad(t, lb)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < m * n):
		float orig = x.data[i]
		x.data[i] = orig + h
		float fp = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		x.data[i] = orig - h
		float fm = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		x.data[i] = orig
		if (feq(central_diff(fp, fm, h), gx.data[i], 0.05) == 0):
			ok = 0
		i = i + 1
	i = 0
	while (i < n):
		float orig = gamma.data[i]
		gamma.data[i] = orig + h
		float fp = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		gamma.data[i] = orig - h
		float fm = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		gamma.data[i] = orig
		if (feq(central_diff(fp, fm, h), gg.data[i], 0.05) == 0):
			ok = 0
		float orig2 = beta.data[i]
		beta.data[i] = orig2 + h
		float fp2 = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		beta.data[i] = orig2 - h
		float fm2 = ref_layernorm(&x, &gamma, &beta, &w, m, n)
		beta.data[i] = orig2
		if (feq(central_diff(fp2, fm2, h), gb2.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&x)
	tensor_free(&gamma)
	tensor_free(&beta)
	tensor_free(&w)
	return ok


##### softmax_causal: sum(mul(softmax_causal(s), w)) #####


float ref_softmax_causal(tensor* s, tensor* w, int n):
	float total = 0.0
	int i = 0
	while (i < n):
		float m = s.data[i * n]
		int j = 1
		while (j <= i):
			if (s.data[i * n + j] > m):
				m = s.data[i * n + j]
			j = j + 1
		float rowsum = 0.0
		j = 0
		while (j <= i):
			rowsum = rowsum + fexp(s.data[i * n + j] - m)
			j = j + 1
		j = 0
		while (j <= i):
			total = total + (fexp(s.data[i * n + j] - m) / rowsum) * w.data[i * n + j]
			j = j + 1
		i = i + 1
	return total


int check_softmax_causal():
	int n = 4
	tensor s = tensor_new2(n, n)
	tensor w = tensor_new2(n, n)
	int i = 0
	while (i < n * n):
		s.data[i] = cast(float, i % 5 - 2) * 0.7
		w.data[i] = cast(float, i % 3 + 1) * 0.4
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* ls = ag_leaf(t, &s)
	tensor* lw = ag_leaf(t, &w)
	tensor* p = ag_softmax_causal(t, ls)
	tensor* mul = ag_mul(t, p, lw)
	ag_sum(t, mul)
	ag_backward(t)
	tensor* gs = ag_grad(t, ls)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < n * n):
		float orig = s.data[i]
		s.data[i] = orig + h
		float fp = ref_softmax_causal(&s, &w, n)
		s.data[i] = orig - h
		float fm = ref_softmax_causal(&s, &w, n)
		s.data[i] = orig
		if (feq(central_diff(fp, fm, h), gs.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&s)
	tensor_free(&w)
	return ok


##### embedding: sum(mul(embedding(table, ids), w)), with a repeated id #####


float ref_embedding(tensor* table, ndi* ids, tensor* w, int n, int dim):
	float total = 0.0
	int i = 0
	while (i < n):
		int j = 0
		while (j < dim):
			total = total + table.data[ids.data[i] * dim + j] * w.data[i * dim + j]
			j = j + 1
		i = i + 1
	return total


int check_embedding():
	int vocab = 5
	int dim = 3
	int n = 4
	tensor table = tensor_new2(vocab, dim)
	tensor w = tensor_new2(n, dim)
	ndi ids = ndi_new1(n)
	# id 3 repeats: its gradient row must accumulate both contributions
	ids.data[0] = 3
	ids.data[1] = 1
	ids.data[2] = 3
	ids.data[3] = 0
	int i = 0
	while (i < vocab * dim):
		table.data[i] = cast(float, i % 6 - 2) * 0.3
		i = i + 1
	i = 0
	while (i < n * dim):
		w.data[i] = cast(float, i + 1) * 0.2
		i = i + 1

	ag_tape* t = ag_tape_new()
	tensor* lt = ag_leaf(t, &table)
	tensor* lw = ag_leaf(t, &w)
	tensor* e = ag_embedding(t, lt, &ids)
	tensor* mul = ag_mul(t, e, lw)
	ag_sum(t, mul)
	ag_backward(t)
	tensor* gt = ag_grad(t, lt)

	float h = 0.01
	int ok = 1
	i = 0
	while (i < vocab * dim):
		float orig = table.data[i]
		table.data[i] = orig + h
		float fp = ref_embedding(&table, &ids, &w, n, dim)
		table.data[i] = orig - h
		float fm = ref_embedding(&table, &ids, &w, n, dim)
		table.data[i] = orig
		if (feq(central_diff(fp, fm, h), gt.data[i], 0.05) == 0):
			ok = 0
		i = i + 1

	ag_tape_free(t)
	tensor_free(&table)
	tensor_free(&w)
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
	if (check_add_row() == 0):
		println(c"autograd gpu: FAILED (add_row)")
		return 1
	if (check_softmax_ce() == 0):
		println(c"autograd gpu: FAILED (softmax_ce)")
		return 1
	if (check_accum() == 0):
		println(c"autograd gpu: FAILED (accum)")
		return 1
	if (check_matmul_nt() == 0):
		println(c"autograd gpu: FAILED (matmul_nt)")
		return 1
	if (check_layernorm() == 0):
		println(c"autograd gpu: FAILED (layernorm)")
		return 1
	if (check_softmax_causal() == 0):
		println(c"autograd gpu: FAILED (softmax_causal)")
		return 1
	if (check_embedding() == 0):
		println(c"autograd gpu: FAILED (embedding)")
		return 1
	println(c"autograd OK")
	return 0
