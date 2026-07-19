/*
lib.autograd: a tape-based reverse-mode autograd core on top of lib/tensor.w
(docs/projects/torch.md, Stage 5).

Micrograd-shaped: an ag_tape owns an ordered log of ag_node records (op id,
output tensor*, input tensor*(s), a saved float scalar for the scalar ops).
Every ag_* forward call both performs the op with the existing tensor_*
surface and appends a node describing it; ag_backward walks the tape in
reverse, seeding the final node's gradient to 1.0 and dispatching each node
to the backward rule for its op. Because the tape is only ever appended to
in call order, and a value can only be read after it was produced, reverse
tape order is already a valid reverse-topological order -- no separate DAG
or visited-set bookkeeping is needed (the same shortcut micrograd's
topological sort achieves by construction here, for free).

Gradient storage (ag_tape.grads, keyed by tensor* identity) is allocated
LAZILY, one zero-filled tensor per value the first time it is read or
written -- most values (dead ends the loss never depended on) never get an
entry at all. Every write to a gradient tensor is an ACCUMULATION
(tensor_add_into into the existing buffer), never an overwrite, so a value
consumed by two different forward calls -- e.g. a leaf x feeding both
ag_mul_scalar(x, ...) and ag_relu(x) into a shared sum -- correctly sums the
two contributions instead of losing one (tests/autograd_gpu.w's
check_accum). map[K, V] hashes non-char* pointer keys by identity (see
grammar/hash_builtin.w's hash_key_kind_for_type), so map[tensor*, tensor*]
is exactly "one grad slot per distinct tensor value" with no extra key
type.

Ownership: ag_leaf(tape, x) registers a caller-owned tensor (a parameter or
input) as a graph leaf; the tape never allocates or frees it. Every other
ag_* forward call allocates its OUTPUT tensor on the heap (tensor_make's
value result boxed into a `new tensor` via ag_box_shape/ag_box_like, since
there is no pointer-to-slice construction in W to reuse the input's storage
-- torch.md Stage 2's same rationale for tensor_from_ndf/tensor_to_ndf) and
records it in tape.owned; gradient tensors are boxed the same way into
tape.owned_grads. ag_tape_reset frees every tensor* in both lists (data
buffer + wrapper) and drops the bookkeeping so the tape can be reused for a
fresh forward/backward pass; ag_tape_free does the same and then frees the
tape's own containers and struct. Neither ever touches a leaf.

Backward rules, all expressible with the existing tensor_* op surface
(torch.md Stage 5's premise -- no compiler work in this stage):
  add:        dA += dOut,           dB += dOut
  mul:        dA += dOut * B,       dB += dOut * A     (via a scratch temp)
  add_scalar: dA += dOut                                (pass-through)
  mul_scalar: dA += dOut * s                           (via a scratch temp)
  relu:       dA += tensor_relu_grad_into(A, dOut)      (masked pass-through)
  sum:        dA += broadcast(dOut's single scalar)     (tensor_add_scalar_into)
  matmul:     dA += dOut @ B^T  (tensor_matmul2_nt(dOut, B))
              dB += A^T @ dOut  (tensor_matmul2_tn(A, dOut))
Every rule above is complete; there are no stubbed arms in this version
(the ops they need -- tensor_relu_grad_into, tensor_matmul2_nt/_tn -- landed
in the same base as this file, torch.md Workstream A).
*/
import lib.lib
import lib.assert
import lib.tensor
import lib.container


##### op ids #####


int ag_op_leaf():
	return 0


int ag_op_add():
	return 1


int ag_op_mul():
	return 2


int ag_op_add_scalar():
	return 3


int ag_op_mul_scalar():
	return 4


int ag_op_relu():
	return 5


int ag_op_sum():
	return 6


int ag_op_matmul():
	return 7


##### tape #####


struct ag_node:
	int op
	tensor* out    # this node's output value
	tensor* a      # first input (or the sole input for unary ops); 0 for leaf
	tensor* b      # second input (add/mul/matmul); 0 when the op has none
	float scalar   # saved scalar for add_scalar/mul_scalar; unused otherwise


struct ag_tape:
	list[ag_node] nodes       # forward call log, in creation order
	map[tensor*, tensor*] grads  # value (tensor*) -> lazily allocated gradient
	list[tensor*] owned       # intermediate output tensors this tape allocated
	list[tensor*] owned_grads # gradient tensors this tape allocated


ag_tape* ag_tape_new():
	ag_tape* t = new ag_tape
	t.nodes = new list[ag_node]
	t.grads = new map[tensor*, tensor*]
	t.owned = new list[tensor*]
	t.owned_grads = new list[tensor*]
	return t


# Forward decl: defined in the boxing section below, used by ag_tape_reset
# above that section.
void ag_free_boxed(tensor* v);


# Frees every tensor* the tape allocated so far (both forward intermediates
# and gradients) and empties the bookkeeping, leaving the tape ready to
# record a fresh forward/backward pass. Leaves are the caller's and are
# never touched.
void ag_tape_reset(ag_tape* t):
	int i = 0
	while (i < t.owned.length):
		ag_free_boxed(t.owned[i])
		i = i + 1
	i = 0
	while (i < t.owned_grads.length):
		ag_free_boxed(t.owned_grads[i])
		i = i + 1
	t.nodes.clear()
	t.owned.clear()
	t.owned_grads.clear()
	map_free[tensor*, tensor*](t.grads)
	t.grads = new map[tensor*, tensor*]


# Releases everything, including the tape's own containers and the ag_tape
# struct itself. The tape must not be used again after this call.
void ag_tape_free(ag_tape* t):
	ag_tape_reset(t)
	list_free[ag_node](t.nodes)
	list_free[tensor*](t.owned)
	list_free[tensor*](t.owned_grads)
	map_free[tensor*, tensor*](t.grads)
	free(cast(char*, t))


##### tensor boxing (heap tensor* wrappers around a tensor_make value) #####
#
# Forward ops need to hand back a tensor* that outlives the call (so it can
# be chained into further ops and recorded on the tape), but tensor_make
# returns a tensor by value. `new tensor` allocates the wrapper; the value's
# fields are copied in field by field since W has no whole-struct-through-a-
# pointer assignment operator to lean on instead.


void ag_copy_fields(tensor* dst, tensor* src):
	dst.data = src.data
	dst.len = src.len
	dst.on_gpu = src.on_gpu
	dst.rank = src.rank
	dst.n0 = src.n0
	dst.n1 = src.n1
	dst.n2 = src.n2
	dst.n3 = src.n3
	dst.s0 = src.s0
	dst.s1 = src.s1
	dst.s2 = src.s2
	dst.s3 = src.s3


tensor* ag_box_shape(int rank, int n0, int n1, int n2, int n3):
	tensor* box = new tensor
	tensor v = tensor_make(rank, n0, n1, n2, n3)
	ag_copy_fields(box, &v)
	return box


tensor* ag_box_like(tensor* shape):
	return ag_box_shape(shape.rank, shape.n0, shape.n1, shape.n2, shape.n3)


# Frees a boxed tensor*: its data buffer (GPU or host, tensor_free picks the
# right allocator) and then the wrapper struct itself.
void ag_free_boxed(tensor* v):
	tensor_free(v)
	free(cast(char*, v))


void ag_record(ag_tape* t, int op, tensor* out, tensor* a, tensor* b, float scalar):
	ag_node n
	n.op = op
	n.out = out
	n.a = a
	n.b = b
	n.scalar = scalar
	t.nodes.push(n)


##### leaves and gradients #####


# Registers x (a caller-owned input or parameter) as a graph leaf so it can
# be differentiated with respect to. The tape never allocates or frees x.
tensor* ag_leaf(ag_tape* t, tensor* x):
	ag_record(t, ag_op_leaf(), x, cast(tensor*, 0), cast(tensor*, 0), 0.0)
	return x


# The gradient tensor for value v, allocated zero-filled on first access
# (tensor_make already zero-fills) and cached in the tape's grads map so
# later accumulations (and later ag_grad calls) see the same buffer.
tensor* ag_grad(ag_tape* t, tensor* v):
	if (v in t.grads):
		return t.grads[v]
	tensor* g = ag_box_like(v)
	t.grads[v] = g
	t.owned_grads.push(g)
	return g


# Resets every currently-allocated gradient to zero in place (torch's
# optimizer.zero_grad()); does not forget which values have grad slots, so
# a value touched by a previous backward() still gets its slot zeroed
# rather than silently dropped.
void ag_zero_grad(ag_tape* t):
	int i = 0
	while (i < t.owned_grads.length):
		tensor_fill(t.owned_grads[i], 0.0)
		i = i + 1


##### forward ops (perform + record) #####


tensor* ag_add(ag_tape* t, tensor* a, tensor* b):
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_add_into(out, a, b)
	ag_record(t, ag_op_add(), out, a, b, 0.0)
	return out


tensor* ag_mul(ag_tape* t, tensor* a, tensor* b):
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_mul_into(out, a, b)
	ag_record(t, ag_op_mul(), out, a, b, 0.0)
	return out


tensor* ag_add_scalar(ag_tape* t, tensor* a, float s):
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_add_scalar_into(out, a, s)
	ag_record(t, ag_op_add_scalar(), out, a, cast(tensor*, 0), s)
	return out


tensor* ag_mul_scalar(ag_tape* t, tensor* a, float s):
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_mul_scalar_into(out, a, s)
	ag_record(t, ag_op_mul_scalar(), out, a, cast(tensor*, 0), s)
	return out


tensor* ag_relu(ag_tape* t, tensor* a):
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_relu_into(out, a)
	ag_record(t, ag_op_relu(), out, a, cast(tensor*, 0), 0.0)
	return out


# Returns a rank-1, size-1 tensor carrying the sum so the scalar stays on
# the tape like any other value -- ag_grad/ag_backward treat it like every
# other node, and the scalar itself is readable as out.data[0].
tensor* ag_sum(ag_tape* t, tensor* a):
	tensor* out = ag_box_shape(1, 1, 1, 1, 1)
	t.owned.push(out)
	float s = tensor_sum(a)
	tensor_fill(out, s)
	ag_record(t, ag_op_sum(), out, a, cast(tensor*, 0), 0.0)
	return out


tensor* ag_matmul(ag_tape* t, tensor* a, tensor* b):
	asserts(c"ag_matmul: rank must be 2", a.rank == 2 && b.rank == 2)
	tensor* out = ag_box_shape(2, a.n0, b.n1, 1, 1)
	t.owned.push(out)
	tensor_matmul2(out, a, b)
	ag_record(t, ag_op_matmul(), out, a, b, 0.0)
	return out


##### backward #####


void ag_backward_node(ag_tape* t, ag_node* nd):
	if (nd.op == ag_op_leaf()):
		return
	tensor* dout = ag_grad(t, nd.out)
	if (nd.op == ag_op_add()):
		tensor* da = ag_grad(t, nd.a)
		tensor* db = ag_grad(t, nd.b)
		tensor_add_into(da, da, dout)
		tensor_add_into(db, db, dout)
		return
	if (nd.op == ag_op_add_scalar()):
		tensor* da2 = ag_grad(t, nd.a)
		tensor_add_into(da2, da2, dout)
		return
	if (nd.op == ag_op_mul()):
		tensor* da3 = ag_grad(t, nd.a)
		tensor* db3 = ag_grad(t, nd.b)
		tensor* tmp = ag_box_like(nd.a)
		tensor_mul_into(tmp, dout, nd.b)
		tensor_add_into(da3, da3, tmp)
		tensor_mul_into(tmp, dout, nd.a)
		tensor_add_into(db3, db3, tmp)
		ag_free_boxed(tmp)
		return
	if (nd.op == ag_op_mul_scalar()):
		tensor* da4 = ag_grad(t, nd.a)
		tensor* tmp2 = ag_box_like(nd.a)
		tensor_mul_scalar_into(tmp2, dout, nd.scalar)
		tensor_add_into(da4, da4, tmp2)
		ag_free_boxed(tmp2)
		return
	if (nd.op == ag_op_relu()):
		tensor* da5 = ag_grad(t, nd.a)
		tensor* tmp3 = ag_box_like(nd.a)
		tensor_relu_grad_into(tmp3, nd.a, dout)
		tensor_add_into(da5, da5, tmp3)
		ag_free_boxed(tmp3)
		return
	if (nd.op == ag_op_sum()):
		tensor* da6 = ag_grad(t, nd.a)
		float g = dout.data[0]
		tensor_add_scalar_into(da6, da6, g)
		return
	if (nd.op == ag_op_matmul()):
		tensor* da7 = ag_grad(t, nd.a)
		tensor* db7 = ag_grad(t, nd.b)
		# dA (m,k) += dOut (m,n) @ B^T (n,k), via the no-materialized-
		# transpose _nt kernel: tensor_matmul2_nt(out, x, y) = x @ y^T.
		tensor* tmpA = ag_box_like(nd.a)
		tensor_matmul2_nt(tmpA, dout, nd.b)
		tensor_add_into(da7, da7, tmpA)
		ag_free_boxed(tmpA)
		# dB (k,n) += A^T (k,m) @ dOut (m,n), via tensor_matmul2_tn(x, y) =
		# x^T @ y (x's rows are the contraction dim, same shape as A).
		tensor* tmpB = ag_box_like(nd.b)
		tensor_matmul2_tn(tmpB, nd.a, dout)
		tensor_add_into(db7, db7, tmpB)
		ag_free_boxed(tmpB)
		return
	asserts(c"ag_backward: unknown op", 0)


# Seeds the last recorded node's gradient to 1.0 (accumulated, not
# overwritten, so a second backward() without ag_zero_grad correctly adds
# onto whatever is already there -- torch's real accumulation semantics)
# and walks the tape in reverse, dispatching each node to its backward
# rule. Reverse creation order is already a valid reverse-topological
# order: a value can only be used by a node created after it.
void ag_backward(ag_tape* t):
	asserts(c"ag_backward: empty tape", t.nodes.length > 0)
	ag_node last = t.nodes[t.nodes.length - 1]
	tensor* seed = ag_grad(t, last.out)
	tensor_add_scalar_into(seed, seed, 1.0)
	int i = t.nodes.length - 1
	while (i >= 0):
		ag_node nd = t.nodes[i]
		ag_backward_node(t, &nd)
		i = i - 1
