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
  add_row:    dA += dOut                                (pass-through)
              dR += column-sum(dOut)                    (tensor_col_sum_into,
                                                          via a scratch temp)
  softmax_ce: dLogits[i,j] += dLoss * (P[i,j] - (j==label_i ? 1 : 0)) / batch
              (fused softmax+mean-cross-entropy; forward caches the
              per-row probabilities P in a tape-owned scratch tensor saved
              on the node -- see ag_op_softmax_ce below)
  embedding:  d_table[ids[i], :] += dOut[i, :]              (host scatter-add)
  layernorm:  the standard LN chain rule (dgamma from dOut*xhat, dx
              through the mean/var terms), row stats recomputed from x
  softmax_causal: dS = P * (dP - rowdot(P, dP)), lower triangle only
  matmul_nt:  dA += dOut @ B          (tensor_matmul2)
              dB += dOut^T @ A        (tensor_matmul2_tn)
Every rule above is complete; there are no stubbed arms in this version
(the ops they need -- tensor_relu_grad_into, tensor_matmul2_nt/_tn,
tensor_add_row_into, tensor_col_sum_into -- landed in the same base as
this file, torch.md Workstream A).
*/
import lib.lib
import lib.assert
import lib.tensor
import lib.container
import lib.ndarray
import lib.fmath


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


int ag_op_add_row():
	return 8


int ag_op_softmax_ce():
	return 9


int ag_op_embedding():
	return 10


int ag_op_layernorm():
	return 11


int ag_op_softmax_causal():
	return 12


int ag_op_matmul_nt():
	return 13


##### tape #####


struct ag_node:
	int op
	tensor* out    # this node's output value
	tensor* a      # first input (or the sole input for unary ops); 0 for leaf
	tensor* b      # second input (add/mul/matmul/add_row); 0 when the op has none
	float scalar   # saved scalar for add_scalar/mul_scalar; unused otherwise
	tensor* saved  # extra forward-cached tensor (currently: ag_op_softmax_ce's
	               # per-row probabilities); tape-owned like `out`; 0 when unused
	ndi* labels    # integer labels for ag_op_softmax_ce; caller-owned, the
	               # tape never frees it; 0 when unused


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


# Like ag_record, plus the two extra fields ag_op_softmax_ce needs (the
# cached probability tensor and the caller-owned label array). Kept as a
# separate entry point rather than widening every existing ag_record call
# site's argument list.
void ag_record_saved(ag_tape* t, int op, tensor* out, tensor* a, tensor* b, float scalar, tensor* saved, ndi* labels):
	ag_node n
	n.op = op
	n.out = out
	n.a = a
	n.b = b
	n.scalar = scalar
	n.saved = saved
	n.labels = labels
	t.nodes.push(n)


void ag_record(ag_tape* t, int op, tensor* out, tensor* a, tensor* b, float scalar):
	ag_record_saved(t, op, out, a, b, scalar, cast(tensor*, 0), cast(ndi*, 0))


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
	# Host-side write on the fresh buffer (not tensor_fill): keeps the
	# caller's loss.data[0] read sync-free under the async model, same
	# as ag_softmax_ce's scalar.
	out.data[0] = s
	ag_record(t, ag_op_sum(), out, a, cast(tensor*, 0), 0.0)
	return out


tensor* ag_matmul(ag_tape* t, tensor* a, tensor* b):
	asserts(c"ag_matmul: rank must be 2", a.rank == 2 && b.rank == 2)
	tensor* out = ag_box_shape(2, a.n0, b.n1, 1, 1)
	t.owned.push(out)
	tensor_matmul2(out, a, b)
	ag_record(t, ag_op_matmul(), out, a, b, 0.0)
	return out


# Bias add: rank-2 a (m, n) + rank-1 r (n), broadcast across every row
# (torch's Linear bias). Forward is a single tensor_add_row_into call;
# the interesting part is the backward shape mismatch between dA (rank 2,
# same shape as a) and dR (rank 1, same shape as r).
tensor* ag_add_row(ag_tape* t, tensor* a, tensor* r):
	asserts(c"ag_add_row: a must be rank 2", a.rank == 2)
	asserts(c"ag_add_row: r must be rank 1", r.rank == 1)
	tensor* out = ag_box_like(a)
	t.owned.push(out)
	tensor_add_row_into(out, a, r)
	ag_record(t, ag_op_add_row(), out, a, r, 0.0)
	return out


# Fused row-wise softmax + mean cross-entropy over a rank-2 logits
# (batch, classes) and integer labels (0..classes-1). Returns a rank-1,
# size-1 tensor carrying the mean loss, exactly like ag_sum, so it stays
# on the tape and chains straight into ag_backward.
#
# Deliberately HOST-computed (both forward and backward loop over the raw
# .data buffers, not a 'gpu for'): managed memory is host-accessible and
# every tensor op syncs before returning, so this is valid on both the
# GPU and CPU-fallback paths. gpu_exp/gpu_log are NOT used here -- they
# are device-only intrinsics, only legal inside a 'gpu for' body
# (grammar/gpu_math_builtin.w), so this op uses lib.fmath's ordinary
# host fexp/flog instead. A device-side fused kernel is future work, not
# this v1.
tensor* ag_softmax_ce(ag_tape* t, tensor* logits, ndi* labels):
	asserts(c"ag_softmax_ce: logits must be rank 2", logits.rank == 2)
	asserts(c"ag_softmax_ce: labels must be rank 1", labels.rank == 1)
	asserts(c"ag_softmax_ce: batch size mismatch", labels.n0 == logits.n0)
	int batch = logits.n0
	int classes = logits.n1
	tensor* probs = ag_box_like(logits)
	t.owned.push(probs)
	# The softmax/CE math runs host-side over the managed logits buffer,
	# which the enqueued forward ops are still writing -- drain first.
	tensor_sync()
	float* plog = logits.data
	float* pp = probs.data
	float total = 0.0
	int i = 0
	while (i < batch):
		# numerically-stable softmax: subtract the row max before exp
		float m = plog[i * classes]
		int j = 1
		while (j < classes):
			float v = plog[i * classes + j]
			if (v > m):
				m = v
			j = j + 1
		float rowsum = 0.0
		j = 0
		while (j < classes):
			float e = fexp(plog[i * classes + j] - m)
			pp[i * classes + j] = e
			rowsum = rowsum + e
			j = j + 1
		j = 0
		while (j < classes):
			pp[i * classes + j] = pp[i * classes + j] / rowsum
			j = j + 1
		int lbl = labels.data[i]
		total = total - flog(pp[i * classes + lbl])
		i = i + 1
	float mean_loss = total / cast(float, batch)
	tensor* out = ag_box_shape(1, 1, 1, 1, 1)
	t.owned.push(out)
	# Host-side write, not tensor_fill: out is a fresh buffer with
	# nothing in flight, and writing it directly keeps the ubiquitous
	# loss.data[0] read on the caller's next line safe with no sync
	# under the Stage 4 async model.
	out.data[0] = mean_loss
	ag_record_saved(t, ag_op_softmax_ce(), out, logits, cast(tensor*, 0), 0.0, probs, labels)
	return out


# Row gather out[i, :] = table[ids[i], :] over a rank-2 (vocab, dim)
# table and rank-1 integer ids -- the token-embedding lookup. Host-
# computed like ag_softmax_ce (managed memory is host-readable, so this
# is valid on both the GPU and CPU-fallback paths); backward is the
# matching host scatter-add into the table's gradient. ids is
# caller-owned and must outlive the tape (it rides the node's labels
# field, the softmax_ce convention).
tensor* ag_embedding(ag_tape* t, tensor* table, ndi* ids):
	asserts(c"ag_embedding: table must be rank 2", table.rank == 2)
	asserts(c"ag_embedding: ids must be rank 1", ids.rank == 1)
	int n = ids.n0
	int dim = table.n1
	tensor* out = ag_box_shape(2, n, dim, 1, 1)
	t.owned.push(out)
	# Host gather below reads the table, which enqueued device ops may
	# still be writing -- drain first.
	tensor_sync()
	float* ptab = table.data
	float* pout = out.data
	int i = 0
	while (i < n):
		int row = ids.data[i]
		asserts(c"ag_embedding: id out of range", (row >= 0) && (row < table.n0))
		int j = 0
		while (j < dim):
			pout[i * dim + j] = ptab[row * dim + j]
			j = j + 1
		i = i + 1
	ag_record_saved(t, ag_op_embedding(), out, table, cast(tensor*, 0), 0.0, cast(tensor*, 0), ids)
	return out


# Row-wise layer normalization scaled by gamma: out[i, j] = gamma[j] *
# (x[i, j] - mean_i) / sqrt(var_i + 1e-5) over rank-2 x and rank-1
# gamma. This is the norm WITHOUT the shift -- it fits the two-input
# node record; the public ag_layernorm below adds beta with the
# existing ag_add_row node. Host-computed (the softmax_ce rationale);
# backward recomputes the row statistics from x instead of caching
# them -- both sides are host loops over the same buffer either way.
tensor* ag_layernorm_core(ag_tape* t, tensor* x, tensor* gamma):
	asserts(c"ag_layernorm: x must be rank 2", x.rank == 2)
	asserts(c"ag_layernorm: gamma must be rank 1", gamma.rank == 1)
	asserts(c"ag_layernorm: gamma size mismatch", gamma.n0 == x.n1)
	int rows = x.n0
	int cols = x.n1
	tensor* out = ag_box_like(x)
	t.owned.push(out)
	tensor_sync()
	float* px = x.data
	float* pg = gamma.data
	float* pout2 = out.data
	float fcols = cast(float, cols)
	int i = 0
	while (i < rows):
		float mean = 0.0
		int j = 0
		while (j < cols):
			mean = mean + px[i * cols + j]
			j = j + 1
		mean = mean / fcols
		float vsum = 0.0
		j = 0
		while (j < cols):
			float d = px[i * cols + j] - mean
			vsum = vsum + d * d
			j = j + 1
		float rstd = 1.0 / fsqrt(vsum / fcols + 0.00001)
		j = 0
		while (j < cols):
			pout2[i * cols + j] = pg[j] * ((px[i * cols + j] - mean) * rstd)
			j = j + 1
		i = i + 1
	ag_record(t, ag_op_layernorm(), out, x, gamma, 0.0)
	return out


# The full affine layer norm: ag_layernorm_core followed by the beta
# shift as an ordinary ag_add_row node.
tensor* ag_layernorm(ag_tape* t, tensor* x, tensor* gamma, tensor* beta):
	return ag_add_row(t, ag_layernorm_core(t, x, gamma), beta)


# Row-wise softmax over the LOWER-TRIANGLE of a rank-2 square scores
# matrix: out[i, j] = exp(s[i, j]) / sum_{k<=i} exp(s[i, k]) for
# j <= i, and exactly 0.0 for j > i -- the causal-attention mask and
# normalization fused into one op (masked positions never enter the
# max/sum, the -inf shortcut without infinities). Host-computed (the
# softmax_ce rationale). Backward reads the probabilities straight
# from the node's own output, so nothing extra is saved.
tensor* ag_softmax_causal(ag_tape* t, tensor* s):
	asserts(c"ag_softmax_causal: scores must be rank 2", s.rank == 2)
	asserts(c"ag_softmax_causal: scores must be square", s.n0 == s.n1)
	int n = s.n0
	tensor* out = ag_box_like(s)
	t.owned.push(out)
	tensor_sync()
	float* ps = s.data
	float* pout3 = out.data
	int i = 0
	while (i < n):
		float m = ps[i * n]
		int j = 1
		while (j <= i):
			float v = ps[i * n + j]
			if (v > m):
				m = v
			j = j + 1
		float rowsum = 0.0
		j = 0
		while (j <= i):
			float e = fexp(ps[i * n + j] - m)
			pout3[i * n + j] = e
			rowsum = rowsum + e
			j = j + 1
		j = 0
		while (j <= i):
			pout3[i * n + j] = pout3[i * n + j] / rowsum
			j = j + 1
		j = i + 1
		while (j < n):
			pout3[i * n + j] = 0.0
			j = j + 1
		i = i + 1
	ag_record(t, ag_op_softmax_causal(), out, s, cast(tensor*, 0), 0.0)
	return out


# out (m, n) = a (m, k) @ b (n, k)^T without materializing the
# transpose (tensor_matmul2_nt) -- attention's q @ k^T shape. Backward:
# dA += dOut @ B (plain matmul), dB += dOut^T @ A (matmul2_tn).
tensor* ag_matmul_nt(ag_tape* t, tensor* a, tensor* b):
	asserts(c"ag_matmul_nt: a must be rank 2", a.rank == 2)
	asserts(c"ag_matmul_nt: b must be rank 2", b.rank == 2)
	asserts(c"ag_matmul_nt: inner dim mismatch", a.n1 == b.n1)
	tensor* out = ag_box_shape(2, a.n0, b.n0, 1, 1)
	t.owned.push(out)
	tensor_matmul2_nt(out, a, b)
	ag_record(t, ag_op_matmul_nt(), out, a, b, 0.0)
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
		t.owned.push(tmp)
		return
	if (nd.op == ag_op_mul_scalar()):
		tensor* da4 = ag_grad(t, nd.a)
		tensor* tmp2 = ag_box_like(nd.a)
		tensor_mul_scalar_into(tmp2, dout, nd.scalar)
		tensor_add_into(da4, da4, tmp2)
		t.owned.push(tmp2)
		return
	if (nd.op == ag_op_relu()):
		tensor* da5 = ag_grad(t, nd.a)
		tensor* tmp3 = ag_box_like(nd.a)
		tensor_relu_grad_into(tmp3, nd.a, dout)
		tensor_add_into(da5, da5, tmp3)
		t.owned.push(tmp3)
		return
	if (nd.op == ag_op_sum()):
		tensor* da6 = ag_grad(t, nd.a)
		# dout was accumulated by enqueued device ops -- drain before
		# the host read.
		tensor_sync()
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
		t.owned.push(tmpA)
		# dB (k,n) += A^T (k,m) @ dOut (m,n), via tensor_matmul2_tn(x, y) =
		# x^T @ y (x's rows are the contraction dim, same shape as A).
		tensor* tmpB = ag_box_like(nd.b)
		tensor_matmul2_tn(tmpB, nd.a, dout)
		tensor_add_into(db7, db7, tmpB)
		t.owned.push(tmpB)
		return
	if (nd.op == ag_op_add_row()):
		tensor* da8 = ag_grad(t, nd.a)
		tensor* dr8 = ag_grad(t, nd.b)
		tensor_add_into(da8, da8, dout)
		# dR (n) += column-sum of dOut (m, n), via a scratch shaped like r
		tensor* tmpR = ag_box_like(nd.b)
		tensor_col_sum_into(tmpR, dout)
		tensor_add_into(dr8, dr8, tmpR)
		t.owned.push(tmpR)
		return
	if (nd.op == ag_op_softmax_ce()):
		# dLogits[i,j] += dLoss * (P[i,j] - (j==label_i ? 1 : 0)) / batch,
		# a host loop straight over the cached probabilities (nd.saved)
		# and the caller-owned labels (nd.labels) -- see ag_softmax_ce's
		# header comment on why this is host- rather than device-computed.
		tensor* dlogits = ag_grad(t, nd.a)
		int batch2 = nd.a.n0
		int classes2 = nd.a.n1
		# Host loop reads dout and writes dlogits, both possibly touched
		# by enqueued device ops -- drain first.
		tensor_sync()
		float dloss = dout.data[0]
		float invbatch = 1.0 / cast(float, batch2)
		float* pg = dlogits.data
		float* pp2 = nd.saved.data
		int i2 = 0
		while (i2 < batch2):
			int lbl2 = nd.labels.data[i2]
			int j2 = 0
			while (j2 < classes2):
				float ind = 0.0
				if (j2 == lbl2):
					ind = 1.0
				pg[i2 * classes2 + j2] = pg[i2 * classes2 + j2] + dloss * (pp2[i2 * classes2 + j2] - ind) * invbatch
				j2 = j2 + 1
			i2 = i2 + 1
		return
	if (nd.op == ag_op_embedding()):
		# d_table[ids[i], :] += dOut[i, :] -- the host scatter-add
		# mirror of the forward gather.
		tensor* dtab = ag_grad(t, nd.a)
		int dim3 = nd.a.n1
		int n3 = nd.labels.n0
		tensor_sync()
		float* pdt = dtab.data
		float* pdo = dout.data
		int i3 = 0
		while (i3 < n3):
			int row3 = nd.labels.data[i3]
			int j3 = 0
			while (j3 < dim3):
				pdt[row3 * dim3 + j3] = pdt[row3 * dim3 + j3] + pdo[i3 * dim3 + j3]
				j3 = j3 + 1
			i3 = i3 + 1
		return
	if (nd.op == ag_op_layernorm()):
		# out = gamma * xhat with xhat = (x - mean) * rstd. Recompute
		# the row statistics from x (forward saved nothing):
		#   dgamma[j] += sum_i dOut[i,j] * xhat[i,j]
		#   dx[i,j]   += rstd * (dxh[j] - mean(dxh) - xhat[j] * mean(dxh*xhat))
		# with dxh[j] = dOut[i,j] * gamma[j], means over the row.
		tensor* dx9 = ag_grad(t, nd.a)
		tensor* dg9 = ag_grad(t, nd.b)
		int rows9 = nd.a.n0
		int cols9 = nd.a.n1
		tensor_sync()
		float* px9 = nd.a.data
		float* pg9 = nd.b.data
		float* pdx9 = dx9.data
		float* pdg9 = dg9.data
		float* pdo9 = dout.data
		float fcols9 = cast(float, cols9)
		int i9 = 0
		while (i9 < rows9):
			float mean9 = 0.0
			int j9 = 0
			while (j9 < cols9):
				mean9 = mean9 + px9[i9 * cols9 + j9]
				j9 = j9 + 1
			mean9 = mean9 / fcols9
			float var9 = 0.0
			j9 = 0
			while (j9 < cols9):
				float d9 = px9[i9 * cols9 + j9] - mean9
				var9 = var9 + d9 * d9
				j9 = j9 + 1
			float rstd9 = 1.0 / fsqrt(var9 / fcols9 + 0.00001)
			float s1 = 0.0
			float s2 = 0.0
			j9 = 0
			while (j9 < cols9):
				float xh = (px9[i9 * cols9 + j9] - mean9) * rstd9
				float dxh = pdo9[i9 * cols9 + j9] * pg9[j9]
				pdg9[j9] = pdg9[j9] + pdo9[i9 * cols9 + j9] * xh
				s1 = s1 + dxh
				s2 = s2 + dxh * xh
				j9 = j9 + 1
			s1 = s1 / fcols9
			s2 = s2 / fcols9
			j9 = 0
			while (j9 < cols9):
				float xh2 = (px9[i9 * cols9 + j9] - mean9) * rstd9
				float dxh2 = pdo9[i9 * cols9 + j9] * pg9[j9]
				pdx9[i9 * cols9 + j9] = pdx9[i9 * cols9 + j9] + rstd9 * (dxh2 - s1 - xh2 * s2)
				j9 = j9 + 1
			i9 = i9 + 1
		return
	if (nd.op == ag_op_softmax_causal()):
		# dS[i,j] += P[i,j] * (dP[i,j] - sum_{k<=i} P[i,k] dP[i,k]),
		# rows independent; masked columns stay untouched (P is 0
		# there, so their true gradient is 0).
		tensor* ds10 = ag_grad(t, nd.a)
		int n10 = nd.a.n0
		tensor_sync()
		float* pp10 = nd.out.data
		float* pdo10 = dout.data
		float* pds10 = ds10.data
		int i10 = 0
		while (i10 < n10):
			float dot = 0.0
			int j10 = 0
			while (j10 <= i10):
				dot = dot + pp10[i10 * n10 + j10] * pdo10[i10 * n10 + j10]
				j10 = j10 + 1
			j10 = 0
			while (j10 <= i10):
				pds10[i10 * n10 + j10] = pds10[i10 * n10 + j10] + pp10[i10 * n10 + j10] * (pdo10[i10 * n10 + j10] - dot)
				j10 = j10 + 1
			i10 = i10 + 1
		return
	if (nd.op == ag_op_matmul_nt()):
		# out = A @ B^T: dA (m,k) += dOut (m,n) @ B (n,k);
		# dB (n,k) += dOut^T (n,m) @ A (m,k), via matmul2_tn.
		tensor* da11 = ag_grad(t, nd.a)
		tensor* db11 = ag_grad(t, nd.b)
		tensor* tmpA11 = ag_box_like(nd.a)
		tensor_matmul2(tmpA11, dout, nd.b)
		tensor_add_into(da11, da11, tmpA11)
		t.owned.push(tmpA11)
		tensor* tmpB11 = ag_box_like(nd.b)
		tensor_matmul2_tn(tmpB11, dout, nd.a)
		tensor_add_into(db11, db11, tmpB11)
		t.owned.push(tmpB11)
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
	# Drain the stream on exit so callers can read gradients (ag_grad +
	# .data) and host-inspect updated values without their own
	# tensor_sync() -- the one hard sync per training step the async
	# model keeps.
	tensor_sync()
