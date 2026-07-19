/*
lib.nn: a minimal neural-net layer + optimizer surface on top of
lib/autograd.w's tape (docs/projects/torch.md, Stage 5).

v1 scope is deliberately tiny -- exactly what an MLP classifier needs and
nothing else: a linear (fully-connected) layer, plain SGD, and reuse of
ag_relu/ag_softmax_ce for the nonlinearity and loss. No conv, no Adam, no
dropout; those are future work, not this stage.

nn_linear stores its weight/bias as plain (non-pointer) tensor fields,
the same value-with-heap-backed-buffer convention lib/tensor.w's own
tensor uses -- nn_linear_new allocates the buffers, nn_linear_free
releases them, and nn_linear_forward hands `&l.weight` / `&l.bias`
(stable addresses for the lifetime of `l`) to ag_leaf so the tape can
find their gradients by pointer identity across many forward/backward
passes reusing the same tape (ag_tape_reset never touches leaves).

Every call to nn_linear_forward re-registers the layer's weight and bias
as fresh leaves. That is required, not just harmless: ag_tape_reset
drops the tape's node list and its whole grads map, so a param that
isn't re-registered after a reset simply has no leaf record on the new
pass (ag_grad would still allocate it a grad slot on demand, since that
map is keyed by pointer identity independent of leaf registration, but
call sites in this file re-register every pass anyway, matching the
established convention in tests/autograd_gpu.w and keeping the tape's
node log an accurate replay of the whole forward computation).
*/
import lib.lib
import lib.assert
import lib.tensor
import lib.autograd
import lib.fmath


##### linear layer #####


struct nn_linear:
	tensor weight   # (in_dim, out_dim); y = x @ weight (torch.md Stage 5's
	                # ag_matmul convention -- no transpose at the call site)
	tensor bias     # (out_dim); broadcast-added via ag_add_row


# Weight ~ N(0, (1/sqrt(in_dim))^2) (the standard "fan-in" scaling that
# keeps forward activations from blowing up or vanishing across layers),
# bias zero-initialized. `seed` drives tensor_randn's deterministic
# xorshift32 stream, so the same seed reproduces the exact same initial
# weights on every run and every target.
nn_linear nn_linear_new(int in_dim, int out_dim, int seed):
	nn_linear l
	l.weight = tensor_new2(in_dim, out_dim)
	float stddev = 1.0 / fsqrt(cast(float, in_dim))
	tensor_randn(&l.weight, seed, 0.0, stddev)
	l.bias = tensor_new1(out_dim)
	return l


void nn_linear_free(nn_linear* l):
	tensor_free(&l.weight)
	tensor_free(&l.bias)


# y = x @ weight + bias, both parameters registered as tape leaves so
# ag_backward populates their gradients (fetch with ag_grad(t, &l.weight)
# / ag_grad(t, &l.bias), or just call nn_linear_sgd_step below).
tensor* nn_linear_forward(ag_tape* t, nn_linear* l, tensor* x):
	tensor* w = ag_leaf(t, &l.weight)
	tensor* b = ag_leaf(t, &l.bias)
	tensor* y = ag_matmul(t, x, w)
	return ag_add_row(t, y, b)


##### SGD #####


# param -= lr * grad, in place (torch's optimizer.step() for one
# parameter tensor). Reads the gradient already accumulated on the tape
# by the most recent ag_backward -- call this before ag_tape_reset, which
# would otherwise free the gradient buffer out from under it.
void nn_sgd_step(ag_tape* t, tensor* param, float lr):
	tensor* g = ag_grad(t, param)
	tensor_axpy_into(param, -lr, g)


# Convenience: one SGD step for both of a linear layer's parameters.
void nn_linear_sgd_step(ag_tape* t, nn_linear* l, float lr):
	nn_sgd_step(t, &l.weight, lr)
	nn_sgd_step(t, &l.bias, lr)
