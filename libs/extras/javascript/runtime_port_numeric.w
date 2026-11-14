/*
Seam for the JS builtins port (numeric cluster). Called once from js_runtime_new
after every other install step. This file belongs to the numeric cluster agent.

Already present on origin (not ported): Math round/floor/ceil/trunc/abs/sign/
sqrt/fround/max/min/hypot and PI/E/SQRT2 (runtime_builtins.w), Number.MAX_VALUE
and MIN_VALUE, the Number predicates, Number.prototype valueOf/toString/
toLocaleString (runtime_wrappers.w). Ported here: Math.pow, parseInt,
parseFloat (also as Number statics) and shaped global isNaN/isFinite.
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_harness_math
import libs.extras.javascript.runtime_number_parse
import libs.extras.javascript.runtime_global_numeric


void js_install_numeric(js_runtime* rt):
	js_runtime_install_harness_math(rt)
	js_runtime_install_number_parse(rt)
	js_runtime_install_global_numeric(rt)
