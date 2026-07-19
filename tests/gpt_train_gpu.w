# Micro-GPT char-level training on tiny-shakespeare (docs/projects/
# torch.md's transformer capstone): a 2-layer, 4-head, 64-dim
# decoder-only transformer -- token + learned positional embeddings,
# pre-LN attention blocks with causal softmax, a relu MLP, and a
# linear head -- trained with AdamW on next-character prediction.
# Every layer is composed from the lib/autograd.w op surface
# (ag_embedding / ag_layernorm / ag_matmul_nt / ag_softmax_causal
# landed for this test); the O(T^2 C + T C^2) matmul work runs through
# the GPU tensor kernels, the elementwise glue host-side over managed
# memory (the ag_softmax_ce convention), so the same binary trains on
# the CPU-fallback path, just slower and with fewer steps.
#
# Asserts: the initial loss sits near ln(vocab) (sanity that the head
# starts uniform), and training strictly reduces it -- below 2.6 nats
# after 500 GPU steps (a bigram char model on this corpus sits ~2.45;
# the transformer passes through it toward ~1.5 with more steps), or
# merely below the start on the short CPU-fallback run. Ends by
# greedy-sampling 150 characters from the trained model (printed for
# inspection, not asserted -- greedy argmax at this scale produces
# repetitive but structured pseudo-Shakespeare).
#
# Data: bin/shakespeare.txt via tools/fetch_shakespeare.sh (the
# gpt_train_gpu_test target runs it first); ~1.1MB, ~65-char vocab.
import lib.lib
import lib.assert
import lib.format
import lib.stream
import lib.rand
import lib.fmath
import lib.ndarray
import lib.tensor
import lib.autograd
import lib.nn

# Model shape: block size (context length), embedding dim, heads,
# per-head dim, layers, MLP hidden dim.
int BLOCK():
	return 64
int DIM():
	return 64
int NHEAD():
	return 4
int HDIM():
	return 16
int NLAYER():
	return 2
int MLPDIM():
	return 256


##### parameter registry #####
# Parameters are created once in a fixed order and consumed by the
# forward pass with the same cursor walk, so creation order IS the
# network wiring. Each gets AdamW state and a decay flag (weight decay
# only on the 2-D matmul weights, the nanoGPT convention).

list[tensor*] g_params
list[nn_adamw] g_opt
list[int] g_decay
int g_cur       # forward-pass cursor
int g_seed      # per-parameter init-seed counter

tensor* gpt_param2(int n0, int n1, float stddev, int decay):
	tensor* p = ag_box_shape(2, n0, n1, 1, 1)
	g_seed = g_seed + 1
	tensor_randn(p, g_seed, 0.0, stddev)
	g_params.push(p)
	g_opt.push(nn_adamw_new(p))
	g_decay.push(decay)
	return p


tensor* gpt_param1(int n0, float fill_value):
	tensor* p = ag_box_shape(1, n0, 1, 1, 1)
	tensor_fill(p, fill_value)
	g_params.push(p)
	g_opt.push(nn_adamw_new(p))
	g_decay.push(0)
	return p


# Creation order: wte wpe, per layer [ln1g ln1b (wq wk wv wo) x heads
# ln2g ln2b fcw fcb projw projb], lnfg lnfb lmw lmb.
void gpt_build(int vocab):
	g_params = new list[tensor*]
	g_opt = new list[nn_adamw]
	g_decay = new list[int]
	gpt_param2(vocab, DIM(), 0.02, 0)
	gpt_param2(BLOCK(), DIM(), 0.02, 0)
	int l = 0
	while (l < NLAYER()):
		gpt_param1(DIM(), 1.0)
		gpt_param1(DIM(), 0.0)
		int h = 0
		while (h < NHEAD()):
			gpt_param2(DIM(), HDIM(), 0.02, 1)
			gpt_param2(DIM(), HDIM(), 0.02, 1)
			gpt_param2(DIM(), HDIM(), 0.02, 1)
			gpt_param2(HDIM(), DIM(), 0.02, 1)
			h = h + 1
		gpt_param1(DIM(), 1.0)
		gpt_param1(DIM(), 0.0)
		gpt_param2(DIM(), MLPDIM(), 0.02, 1)
		gpt_param1(MLPDIM(), 0.0)
		gpt_param2(MLPDIM(), DIM(), 0.02, 1)
		gpt_param1(DIM(), 0.0)
		l = l + 1
	gpt_param1(DIM(), 1.0)
	gpt_param1(DIM(), 0.0)
	gpt_param2(DIM(), vocab, 0.02, 1)
	gpt_param1(vocab, 0.0)


# The next parameter in wiring order, registered as a tape leaf.
tensor* nextp(ag_tape* t):
	tensor* p = g_params[g_cur]
	g_cur = g_cur + 1
	return ag_leaf(t, p)


##### forward #####
# ids/pos are rank-1 with the same length n <= BLOCK (pos = 0..n-1);
# returns (n, vocab) logits. The positional embedding is an
# ag_embedding gather of wpe by pos, so shorter-than-block contexts
# (sampling) reuse the training path unchanged.
tensor* gpt_forward(ag_tape* t, ndi* ids, ndi* pos):
	g_cur = 0
	tensor* te = ag_embedding(t, nextp(t), ids)
	tensor* pe = ag_embedding(t, nextp(t), pos)
	tensor* x = ag_add(t, te, pe)
	float att_scale = 1.0 / fsqrt(cast(float, HDIM()))
	int l = 0
	while (l < NLAYER()):
		tensor* g1 = nextp(t)
		tensor* b1 = nextp(t)
		tensor* a = ag_layernorm(t, x, g1, b1)
		tensor* att = cast(tensor*, 0)
		int h = 0
		while (h < NHEAD()):
			tensor* wq = nextp(t)
			tensor* wk = nextp(t)
			tensor* wv = nextp(t)
			tensor* wo = nextp(t)
			tensor* q = ag_matmul(t, a, wq)
			tensor* k = ag_matmul(t, a, wk)
			tensor* v = ag_matmul(t, a, wv)
			tensor* s = ag_mul_scalar(t, ag_matmul_nt(t, q, k), att_scale)
			tensor* p2 = ag_softmax_causal(t, s)
			tensor* o = ag_matmul(t, ag_matmul(t, p2, v), wo)
			if (h == 0):
				att = o
			else:
				att = ag_add(t, att, o)
			h = h + 1
		x = ag_add(t, x, att)
		tensor* g2 = nextp(t)
		tensor* b2 = nextp(t)
		tensor* m = ag_layernorm(t, x, g2, b2)
		tensor* fcw = nextp(t)
		tensor* fcb = nextp(t)
		tensor* projw = nextp(t)
		tensor* projb = nextp(t)
		tensor* hidden = ag_relu(t, ag_add_row(t, ag_matmul(t, m, fcw), fcb))
		tensor* mlp = ag_add_row(t, ag_matmul(t, hidden, projw), projb)
		x = ag_add(t, x, mlp)
		l = l + 1
	tensor* gf = nextp(t)
	tensor* bf = nextp(t)
	x = ag_layernorm(t, x, gf, bf)
	tensor* lmw = nextp(t)
	tensor* lmb = nextp(t)
	return ag_add_row(t, ag_matmul(t, x, lmw), lmb)


##### corpus #####

int corpus_len
int[] corpus          # encoded corpus (char class ids)
int[] char_to_id      # 256 entries, -1 = not in vocab
int[] id_to_char
int vocab_size

int load_corpus(char* path):
	wstream* in = stream_open_read(path)
	if (in == cast(wstream*, 0)):
		return 0
	# tiny-shakespeare is ~1.1MB; read in one gulp with slack.
	int cap = 2 * 1024 * 1024
	char* raw = malloc(cap)
	int n = stream_read(in, raw, cap)
	stream_close(in)
	if (n <= 0):
		return 0
	char_to_id = new int[256]
	id_to_char = new int[256]
	int i = 0
	while (i < 256):
		char_to_id[i] = 0 - 1
		i = i + 1
	corpus = new int[n]
	corpus_len = n
	vocab_size = 0
	i = 0
	while (i < n):
		int ch = raw[i]
		if (char_to_id[ch] < 0):
			char_to_id[ch] = vocab_size
			id_to_char[vocab_size] = ch
			vocab_size = vocab_size + 1
		corpus[i] = char_to_id[ch]
		i = i + 1
	free(raw)
	return 1


##### training #####

int main():
	if (load_corpus(c"bin/shakespeare.txt") == 0):
		println(c"gpt train: FAILED loading bin/shakespeare.txt (run tools/fetch_shakespeare.sh)")
		return 1
	int on_gpu = gpu_available()
	if (on_gpu):
		println(c"gpt: gpu path")
	else:
		println(c"gpt: cpu fallback")
	int steps = 500
	if (on_gpu == 0):
		# The CPU-fallback path runs the same loop end to end but far
		# fewer steps: enough to prove the loss moves, cheap enough
		# for CI hardware without a GPU.
		steps = 20
	gpt_build(vocab_size)
	print(c"vocab ")
	print(itoa(vocab_size))
	print(c", params ")
	int np = 0
	int pi = 0
	while (pi < g_params.length):
		np = np + g_params[pi].len
		pi = pi + 1
	println(itoa(np))

	ag_tape* t = ag_tape_new()
	ndi ids = ndi_new1(BLOCK())
	ndi pos = ndi_new1(BLOCK())
	ndi targets = ndi_new1(BLOCK())
	int i = 0
	while (i < BLOCK()):
		pos.data[i] = i
		i = i + 1
	rand_state rng
	rand_init(&rng, 1234)

	float first_loss = 0.0
	float last_loss = 0.0
	int step = 1
	while (step <= steps):
		int base = rand_next31(&rng) % (corpus_len - BLOCK() - 1)
		i = 0
		while (i < BLOCK()):
			ids.data[i] = corpus[base + i]
			targets.data[i] = corpus[base + i + 1]
			i = i + 1
		tensor* logits = gpt_forward(t, &ids, &pos)
		tensor* loss = ag_softmax_ce(t, logits, &targets)
		ag_backward(t)
		float lv = loss.data[0]
		if (step == 1):
			first_loss = lv
		last_loss = lv
		if ((step == 1) || (step % 50 == 0)):
			print(c"step ")
			print(itoa(step))
			print(c" loss ")
			println(ftoa(lv))
		pi = 0
		while (pi < g_params.length):
			float wd = 0.0
			if (g_decay[pi]):
				wd = 0.01
			nn_adamw st = g_opt[pi]
			nn_adamw_step(t, g_params[pi], &st, step, 0.001, 0.9, 0.99, 0.00000001, wd)
			pi = pi + 1
		ag_tape_reset(t)
		step = step + 1

	# The untrained head is ~uniform over the vocab: loss ~ ln(65) ~ 4.17.
	asserts(c"gpt train: initial loss should sit near ln(vocab)", (first_loss > 3.0) && (first_loss < 5.0))
	if (on_gpu):
		asserts(c"gpt train: loss should fall below 2.6 nats", last_loss < 2.6)
	else:
		asserts(c"gpt train: loss should decrease", last_loss < first_loss)

	if (on_gpu):
		# Greedy-sample 150 characters from a newline prime. Uses the
		# training forward unchanged: contexts shorter than BLOCK just
		# gather fewer wpe rows.
		int sample_len = 150
		int* ctx = cast(int*, malloc((sample_len + 1) * __word_size__))
		ctx[0] = char_to_id['\n']
		int have = 1
		while (have <= sample_len):
			int n2 = have
			if (n2 > BLOCK()):
				n2 = BLOCK()
			ndi sids = ndi_new1(n2)
			ndi spos = ndi_new1(n2)
			i = 0
			while (i < n2):
				sids.data[i] = ctx[have - n2 + i]
				spos.data[i] = i
				i = i + 1
			tensor* slogits = gpt_forward(t, &sids, &spos)
			tensor_sync()
			float* row = &slogits.data[(n2 - 1) * vocab_size]
			int best = 0
			i = 1
			while (i < vocab_size):
				if (row[i] > row[best]):
					best = i
				i = i + 1
			ctx[have] = best
			have = have + 1
			ag_tape_reset(t)
		char* sample = malloc(sample_len + 2)
		i = 1
		while (i <= sample_len):
			sample[i - 1] = id_to_char[ctx[i]]
			i = i + 1
		sample[sample_len] = '\n'
		sample[sample_len + 1] = 0
		print(c"sample: ")
		print(sample)
		free(sample)

	println(c"gpt train OK")
	return 0
