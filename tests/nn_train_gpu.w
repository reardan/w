# lib.nn end-to-end training test (docs/projects/torch.md, Stage 5): a
# self-contained synthetic classification problem -- no downloaded data,
# no MNIST dependency -- trains an 8 -> 32 -> 4 MLP (linear, relu,
# linear) with plain SGD against the fused ag_softmax_ce loss and checks
# it actually learns: initial loss near ln(4) (the random-guess baseline
# over 4 classes), final loss and train accuracy after training.
#
# Data: 4 well-separated Gaussian clusters in 8-D (one per class; only
# the first two dimensions carry signal -- mean (+-3, +-3, 0, ..., 0),
# stddev 0.5, so classes are ~12 stddevs apart and trivially separable
# given enough training -- the other 6 dimensions are pure noise the
# network has to learn to ignore), 64 samples per class (256 total),
# generated with lib.rand's deterministic xorshift32 stream so the run
# is bit-reproducible.
#
# Mirrors tests/autograd_gpu.w: nn_train_gpu_test is opt-in (running
# needs libcuda at load time, like every lib.tensor consumer);
# nn_compile_test compiles this file in the default umbrella so
# device-subset regressions are caught GPU-less. x64-only, hand-declared
# in build.base.json (no *_test.w autotwin -- the run step's
# expect_stdout assertions and CUDA_VISIBLE_DEVICES= fallback rerun need
# a hand-written target, same as autograd_gpu_test).
import lib.lib
import lib.assert
import lib.tensor
import lib.autograd
import lib.nn
import lib.ndarray
import lib.rand
import lib.fmath


# |a - b| <= eps.
int near(float a, float b, float eps):
	float d = a - b
	if (d < 0.0):
		d = 0.0 - d
	return d <= eps


# Fills x (batch = classes*per_class, dims) and labels (batch) with
# `classes` Gaussian blobs: class c's mean is (+-3, +-3, 0, ..., 0) --
# the sign of the first coordinate flips with c's low bit, the sign of
# the second with c's next bit -- and every coordinate gets independent
# N(mean, stddev^2) noise. One rand_state, seeded once, threaded through
# the whole generation in row-major (class, then sample, then feature)
# order, so a fixed seed reproduces the exact same data every run.
void gen_clusters(tensor* x, ndi* labels, int dims, int classes, int per_class, float stddev, int seed):
	rand_state r
	rand_init(&r, seed)
	int c = 0
	while (c < classes):
		float m0 = 3.0
		if (c % 2 == 1):
			m0 = 0.0 - 3.0
		float m1 = 3.0
		if ((c / 2) % 2 == 1):
			m1 = 0.0 - 3.0
		int s = 0
		while (s < per_class):
			int row = c * per_class + s
			int j = 0
			while (j < dims):
				float mean = 0.0
				if (j == 0):
					mean = m0
				else if (j == 1):
					mean = m1
				x.data[row * dims + j] = rand_gaussian_scaled(&r, mean, stddev)
				j = j + 1
			labels.data[row] = c
			s = s + 1
		c = c + 1


# linear -> relu -> linear.
tensor* mlp_forward(ag_tape* t, nn_linear* l1, nn_linear* l2, tensor* x):
	tensor* h1 = nn_linear_forward(t, l1, x)
	tensor* h1r = ag_relu(t, h1)
	return nn_linear_forward(t, l2, h1r)


int main(int argc, int argv):
	if (gpu_available()):
		println(c"nn: gpu path")
	else:
		println(c"nn: cpu fallback")

	int dims = 8
	int classes = 4
	int per_class = 64
	int batch = classes * per_class
	int hidden = 32
	float data_stddev = 0.5
	int data_seed = 4

	tensor x = tensor_new2(batch, dims)
	ndi labels = ndi_new1(batch)
	gen_clusters(&x, &labels, dims, classes, per_class, data_stddev, data_seed)

	nn_linear l1 = nn_linear_new(dims, hidden, 2)
	nn_linear l2 = nn_linear_new(hidden, classes, 4)

	float lr = 0.1
	int epochs = 300

	ag_tape* t = ag_tape_new()

	float initial_loss = 0.0
	int epoch = 0
	while (epoch < epochs):
		tensor* logits = mlp_forward(t, &l1, &l2, &x)
		tensor* loss = ag_softmax_ce(t, logits, &labels)
		if (epoch == 0):
			initial_loss = loss.data[0]
		ag_backward(t)
		nn_linear_sgd_step(t, &l1, lr)
		nn_linear_sgd_step(t, &l2, lr)
		ag_tape_reset(t)
		epoch = epoch + 1

	# Final evaluation pass: fresh forward (no backward/update) so the
	# reported loss and accuracy reflect the fully-trained parameters.
	tensor* logits_final = mlp_forward(t, &l1, &l2, &x)
	tensor* loss_final = ag_softmax_ce(t, logits_final, &labels)
	float final_loss = loss_final.data[0]

	int correct = 0
	int i = 0
	while (i < batch):
		int best = 0
		float bestv = logits_final.data[i * classes]
		int j = 1
		while (j < classes):
			float v = logits_final.data[i * classes + j]
			if (v > bestv):
				bestv = v
				best = j
			j = j + 1
		if (best == labels.data[i]):
			correct = correct + 1
		i = i + 1
	float train_acc = cast(float, correct) / cast(float, batch)

	ag_tape_free(t)
	nn_linear_free(&l1)
	nn_linear_free(&l2)
	tensor_free(&x)

	float ln4 = flog(4.0)
	if (near(initial_loss, ln4, 0.2) == 0):
		println(c"nn train: FAILED (initial loss not near ln(4))")
		return 1
	if (final_loss >= 0.2):
		println(c"nn train: FAILED (final loss too high)")
		return 1
	if (train_acc <= 0.95):
		println(c"nn train: FAILED (train accuracy too low)")
		return 1

	println(c"nn train OK")
	return 0
