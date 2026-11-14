/*
Seam for the JS builtins port (promise cluster). Called once from js_runtime_new
after every other install step. This file belongs to the promise cluster agent.
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_promise_combinators


void js_install_promise(js_runtime* rt):
	js_runtime_install_promise_combinators(rt)
