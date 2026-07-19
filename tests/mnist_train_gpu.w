# Real-MNIST training run (docs/projects/torch.md, Stage 5 acceptance):
# trains a 784 -> 64 -> 10 MLP (linear, relu, linear) with minibatch SGD
# against the fused ag_softmax_ce loss on actual MNIST digit data loaded
# through lib/mnist.w, and checks generalization on the held-out t10k
# test set (accuracy > 0.90 -- an MLP at this scale reaches ~0.93+ even
# on the 10k-image training subset used here).
#
# Data: the four IDX files in bin/mnist/, fetched by tools/fetch_mnist.sh
# (the mnist_train_gpu_test target runs it first; ~11MB, cached in bin/).
# Training uses the first 10000 of the 60000 train images so the
# CPU-fallback rerun stays in tens-of-seconds territory; evaluation uses
# the full 10000-image test set.
#
# Mirrors tests/nn_train_gpu.w: mnist_train_gpu_test is opt-in (needs
# libcuda at load time plus the downloaded data); mnist_train_compile_test
# compiles this file in the default umbrella so device-subset regressions
# are caught GPU-less. x64-only, hand-declared in build.base.json.
import lib.lib
import lib.assert
import lib.format
import lib.tensor
import lib.autograd
import lib.nn
import lib.ndarray
import lib.mnist


# Copies rows [start, start+batch) of the flattened image ndf into x's
# managed buffer and the matching labels into lb. Plain host-side loops:
# tensor data is CUDA managed memory, so the next GPU op sees the writes.
void load_batch(tensor* x, ndi* lb, ndf* flat, ndi* labels, int start, int batch, int dims):
	int r = 0
	while (r < batch):
		int src = (start + r) * dims
		int dst = r * dims
		int j = 0
		while (j < dims):
			x.data[dst + j] = flat.data[src + j]
			j = j + 1
		lb.data[r] = labels.data[start + r]
		r = r + 1


# linear -> relu -> linear.
tensor* mlp_forward(ag_tape* t, nn_linear* l1, nn_linear* l2, tensor* x):
	tensor* h1 = nn_linear_forward(t, l1, x)
	tensor* h1r = ag_relu(t, h1)
	return nn_linear_forward(t, l2, h1r)


# Argmax accuracy of logits (n, classes) against labels (n). Reads the
# logits host-side, so drain any enqueued forward ops first (Stage 4
# async model).
float accuracy(tensor* logits, ndi* labels, int n, int classes):
	tensor_sync()
	int correct = 0
	int i = 0
	while (i < n):
		int best = 0
		float bestv = logits.data[i * classes]
		int j = 1
		while (j < classes):
			float v = logits.data[i * classes + j]
			if (v > bestv):
				bestv = v
				best = j
			j = j + 1
		if (best == labels.data[i]):
			correct = correct + 1
		i = i + 1
	return cast(float, correct) / cast(float, n)


int load_or_die(int rc, char* what):
	if (rc != MNIST_OK()):
		print(c"mnist train: FAILED loading ")
		print(what)
		print(c": ")
		println(mnist_error_string(rc))
		return 0
	return 1


int main(int argc, int argv):
	if (gpu_available()):
		println(c"mnist: gpu path")
	else:
		println(c"mnist: cpu fallback")

	ndf train_images
	ndi train_labels
	ndf test_images
	ndi test_labels
	if (load_or_die(mnist_load_images(c"bin/mnist/train-images-idx3-ubyte", &train_images), c"train images") == 0):
		return 1
	if (load_or_die(mnist_load_labels(c"bin/mnist/train-labels-idx1-ubyte", &train_labels), c"train labels") == 0):
		return 1
	if (load_or_die(mnist_load_images(c"bin/mnist/t10k-images-idx3-ubyte", &test_images), c"test images") == 0):
		return 1
	if (load_or_die(mnist_load_labels(c"bin/mnist/t10k-labels-idx1-ubyte", &test_labels), c"test labels") == 0):
		return 1

	ndf train_flat = mnist_flatten_images(&train_images)
	ndf test_flat = mnist_flatten_images(&test_images)
	int dims = train_flat.n1
	asserts(c"mnist train: unexpected image size", dims == 784)

	int classes = 10
	int hidden = 64
	int batch = 100
	int n_train = 10000
	int epochs = 5
	float lr = 0.1

	nn_linear l1 = nn_linear_new(dims, hidden, 2)
	nn_linear l2 = nn_linear_new(hidden, classes, 4)

	tensor x = tensor_new2(batch, dims)
	ndi lb = ndi_new1(batch)
	ag_tape* t = ag_tape_new()

	int steps_per_epoch = n_train / batch
	int epoch = 0
	while (epoch < epochs):
		float epoch_loss = 0.0
		int step = 0
		while (step < steps_per_epoch):
			load_batch(&x, &lb, &train_flat, &train_labels, step * batch, batch, dims)
			tensor* logits = mlp_forward(t, &l1, &l2, &x)
			tensor* loss = ag_softmax_ce(t, logits, &lb)
			epoch_loss = epoch_loss + loss.data[0]
			ag_backward(t)
			nn_linear_sgd_step(t, &l1, lr)
			nn_linear_sgd_step(t, &l2, lr)
			ag_tape_reset(t)
			step = step + 1
		print(c"epoch loss ")
		println(ftoa(epoch_loss / cast(float, steps_per_epoch)))
		epoch = epoch + 1

	# Held-out evaluation: one forward pass over the full t10k set.
	int n_test = test_flat.n0
	tensor x_test = tensor_from_ndf(&test_flat)
	tensor* logits_test = mlp_forward(t, &l1, &l2, &x_test)
	float test_acc = accuracy(logits_test, &test_labels, n_test, classes)
	print(c"test accuracy ")
	println(ftoa(test_acc))

	ag_tape_free(t)
	nn_linear_free(&l1)
	nn_linear_free(&l2)
	tensor_free(&x)
	tensor_free(&x_test)

	if (test_acc <= 0.90):
		println(c"mnist train: FAILED (test accuracy too low)")
		return 1

	println(c"mnist train OK")
	return 0
