/*
GPU device-side transcendental builtins (docs/projects/torch.md
Workstream E):

  float32 gpu_exp(float32 x)   e^x, via ex2.approx.f32 after a
                                multiply by log2(e)
  float32 gpu_log(float32 x)   ln(x), via lg2.approx.f32 before a
                                multiply by ln(2)

Both are float32-only and device (PTX) bodies only — host use is a
compile error, mirroring the gpu atomics (grammar/atomic_builtin.w):
no host lowering is provided. The .approx PTX variants are the
standard ML-precision choice (what CUDA's fast-math uses) — they trade
a few ULP for throughput; see tests/cuda_gpu.w's cross-check against
lib/fmath.w's host fexp/flog for the tolerance this project accepts.

The intrinsics parse as ordinary calls — no new syntax, so the
parser-generator grammar is untouched — and are not reserved words: a
user symbol with one of these names that is already defined at the
call site takes precedence (the limb-intrinsic shadowing rule).

This file is compiled by the committed seed: only seed-understood
syntax here.
*/
int expression();


# Intrinsic index for the current token: 1 gpu_exp, 2 gpu_log; 0 when
# the token is not an intrinsic name.
int gpu_math_builtin_kind():
	if (peek(c"gpu_exp")):
		return 1
	if (peek(c"gpu_log")):
		return 2
	return 0


char* gpu_math_builtin_name(int kind):
	if (kind == 1):
		return c"gpu_exp"
	return c"gpu_log"


int gpu_math_builtin_ready():
	if (nextc != '('):
		return 0
	if (gpu_math_builtin_kind() == 0):
		return 0
	if (sym_lookup(token) >= 0):
		return 0
	return 1


# gpu_exp(x)/gpu_log(x): the intrinsic's name is the current token and
# '(' directly follows. Leaves ')' current for primary_expr's trailing
# get_token().
int gpu_math_builtin_expr():
	int kind = gpu_math_builtin_kind()
	char* name = gpu_math_builtin_name(kind)
	if (target_isa != 3):
		error(c"gpu_exp/gpu_log are only available in gpu code")
	get_token()
	expect(c"(")
	int got = expression()
	got = promote(got)
	coerce(float32_type, got)
	if (kind == 1):
		ptx_gpu_exp()
	else:
		ptx_gpu_log()
	if (peek(c")") == 0):
		diag_part(c"')' expected in ")
		error(name)
	return float32_value_type
