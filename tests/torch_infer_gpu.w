# Stage 6 acceptance (docs/projects/torch.md): run inference with real
# PyTorch-trained weights. tests/data/mnist_mlp.safetensors was written
# by tools/train_mnist_torch.py -- a 784 -> 32 -> 10 MLP trained on MNIST
# in torch, exported in torch's NATIVE state_dict layout (fc*.weight is
# (out_features, in_features)); this test does the transpose torch's
# x @ W^T convention implies, proving W reads real torch checkpoints
# as-is rather than a W-shaped re-export.
#
# The fixture carries its own oracle, so this test needs no Python:
#   probe_input  (8, 784)  the first 8 t10k images as torch saw them
#   probe_logits (8, 10)   torch's logits for those images -- W's forward
#                          must match to 1e-3 (same math, different
#                          accumulation order)
#   test_acc     (1)       torch's t10k accuracy -- W's accuracy over the
#                          real t10k set must land within 0.005 of it
#
# The probe check runs anywhere (fixture is checked in); the full t10k
# accuracy check needs bin/mnist/ (tools/fetch_mnist.sh, run by the
# opt-in torch_infer_gpu_test target). torch_infer_compile_test compiles
# this GPU-less in the default umbrella. x64-only, hand-declared in
# build.base.json.
import lib.lib
import lib.assert
import lib.format
import lib.tensor
import lib.ndarray
import lib.mnist
import lib.safetensors


# Torch stores a linear layer's weight as (out_features, in_features);
# lib.nn's convention is y = x @ W with W (in, out). Plain host-side
# transpose copy (strided views are out of ndarray's v1 scope).
ndf transpose2(ndf* a):
	asserts(c"transpose2: rank must be 2", a.rank == 2)
	ndf out = ndf_new2(a.n1, a.n0)
	int i = 0
	while (i < a.n0):
		int j = 0
		while (j < a.n1):
			ndf_set2(&out, j, i, ndf_at2(a, i, j))
			j = j + 1
		i = i + 1
	return out


# linear -> relu -> linear on raw tensor ops (inference only, no tape).
# Writes logits (n, 10) into out; h is caller-allocated (n, hidden)
# scratch. The elementwise ops are alias-safe (out == a reads and writes
# the same flat index), so bias add and relu run in place.
void mlp_infer(tensor* out, tensor* h, tensor* x, tensor* w1, tensor* b1, tensor* w2, tensor* b2):
	tensor_matmul2(h, x, w1)
	tensor_add_row_into(h, h, b1)
	tensor_relu_into(h, h)
	tensor_matmul2(out, h, w2)
	tensor_add_row_into(out, out, b2)


ndf* need(st_file* f, char* name):
	ndf* t = st_get(f, name)
	if (t == 0):
		print(c"torch infer: FAILED (fixture is missing tensor ")
		print(name)
		println(c")")
		exit(1)
	return t


int main(int argc, int argv):
	if (gpu_available()):
		println(c"torch infer: gpu path")
	else:
		println(c"torch infer: cpu fallback")

	st_file* f = st_load(c"tests/data/mnist_mlp.safetensors")
	if (f == 0):
		println(c"torch infer: FAILED (cannot load fixture)")
		return 1

	ndf w1_torch = *need(f, c"fc1.weight")   # (32, 784)
	ndf w2_torch = *need(f, c"fc2.weight")   # (10, 32)
	int hidden = w1_torch.n0
	int classes = w2_torch.n0
	int dims = w1_torch.n1

	ndf w1_nd = transpose2(&w1_torch)        # (784, 32)
	ndf w2_nd = transpose2(&w2_torch)        # (32, 10)
	tensor w1 = tensor_from_ndf(&w1_nd)
	tensor w2 = tensor_from_ndf(&w2_nd)
	tensor b1 = tensor_from_ndf(need(f, c"fc1.bias"))
	tensor b2 = tensor_from_ndf(need(f, c"fc2.bias"))

	##### probe check: W's forward vs torch's logits on the same input #####

	ndf* probe_in = need(f, c"probe_input")
	ndf* probe_want = need(f, c"probe_logits")
	int n_probe = probe_in.n0
	tensor xp = tensor_from_ndf(probe_in)
	tensor hp = tensor_new2(n_probe, hidden)
	tensor lp = tensor_new2(n_probe, classes)
	mlp_infer(&lp, &hp, &xp, &w1, &b1, &w2, &b2)

	float max_diff = 0.0
	int i = 0
	while (i < n_probe * classes):
		float d = lp.data[i] - probe_want.data[i]
		if (d < 0.0):
			d = 0.0 - d
		if (d > max_diff):
			max_diff = d
		i = i + 1
	print(c"probe max logit diff ")
	println(ftoa(max_diff))
	if (max_diff > 0.001):
		println(c"torch infer: FAILED (logits do not match torch)")
		return 1

	##### full t10k accuracy vs torch's own #####

	float want_acc = need(f, c"test_acc").data[0]
	ndf test_images
	ndi test_labels
	if (mnist_load_images(c"bin/mnist/t10k-images-idx3-ubyte", &test_images) != MNIST_OK()):
		println(c"torch infer: FAILED (cannot load t10k images; run tools/fetch_mnist.sh)")
		return 1
	if (mnist_load_labels(c"bin/mnist/t10k-labels-idx1-ubyte", &test_labels) != MNIST_OK()):
		println(c"torch infer: FAILED (cannot load t10k labels)")
		return 1
	ndf test_flat = mnist_flatten_images(&test_images)
	asserts(c"torch infer: unexpected image size", test_flat.n1 == dims)
	int n_test = test_flat.n0

	tensor xt = tensor_from_ndf(&test_flat)
	tensor ht = tensor_new2(n_test, hidden)
	tensor lt = tensor_new2(n_test, classes)
	mlp_infer(&lt, &ht, &xt, &w1, &b1, &w2, &b2)

	int correct = 0
	i = 0
	while (i < n_test):
		int best = 0
		float bestv = lt.data[i * classes]
		int j = 1
		while (j < classes):
			float v = lt.data[i * classes + j]
			if (v > bestv):
				bestv = v
				best = j
			j = j + 1
		if (best == test_labels.data[i]):
			correct = correct + 1
		i = i + 1
	float acc = cast(float, correct) / cast(float, n_test)
	print(c"torch accuracy ")
	print(ftoa(want_acc))
	print(c", w accuracy ")
	println(ftoa(acc))

	float acc_diff = acc - want_acc
	if (acc_diff < 0.0):
		acc_diff = 0.0 - acc_diff
	if (acc_diff > 0.005):
		println(c"torch infer: FAILED (accuracy does not match torch)")
		return 1
	if (acc <= 0.9):
		println(c"torch infer: FAILED (accuracy too low)")
		return 1

	st_free(f)
	println(c"torch infer OK")
	return 0
