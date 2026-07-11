# End-to-end test of c_lib/extern on the wasm target: each extern below
# becomes a typed entry in the module's import section (function indices
# after the fixed WASI set), bound at instantiation by the host runner
# (tools/web/run_env_test.mjs), which drives the callback path and checks
# the exported $ax global. Compiled with 'wv2 wasm' and run under Node by
# the hand-written wasm_extern_test target (build.base.json; the source
# is in generate.exclude, like the other unconventional targets).
import lib.lib
import lib.assert

# An extern declared before any c_lib defaults to import module "env".
extern int env_default_add(int a, int b)

c_lib "env"

extern int env_add(int a, int b)
extern float32 env_scale(float32 x, float32 k)
extern void env_note(int v)
extern int env_get_note()
extern void env_set_callback(int fn)

# A second c_lib groups later externs under their own import module.
c_lib "wtest"

extern int wtest_mul(int a, int b)


int cb_calls

# The host calls this through the exported funcref table: twice from
# inside env_set_callback (re-entering while a host call is live) and
# once more after _start returns. Every W function is wasm [] -> [], so
# the host reads the return value from the exported $ax global.
int on_tick():
	cb_calls = cb_calls + 1
	return cb_calls * 10


int main(int argc, int argv):
	assert_equal(7, env_default_add(3, 4))
	assert_equal(5, env_add(2, 3))

	# float32 arguments and results cross as real f32s (the stub
	# reinterprets the raw bits both ways).
	float32 y = env_scale(1.5, 4.0)
	assert_equal(1, y == 6.0)

	# void import + a value round-tripped through host state
	env_note(41)
	assert_equal(41, env_get_note())

	# second import module
	assert_equal(42, wtest_mul(6, 7))

	# hand the host a W function pointer (its table index); the host
	# calls it back twice before env_set_callback returns
	env_set_callback(cast(int, on_tick))
	assert_equal(2, cb_calls)

	println(c"wasm extern test OK")
	return 0
