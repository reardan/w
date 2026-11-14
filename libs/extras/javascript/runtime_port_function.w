/*
Seam for the JS builtins port (function cluster). Called once from js_runtime_new
after every other install step. This file belongs to the function cluster agent.
Function.prototype becomes callable and gets call/apply/bind/toString; the Error
constructors gain cause, AggregateError, Error.isError and branded instances.
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_function
import libs.extras.javascript.runtime_error


void js_install_function(js_runtime* rt):
	js_function_install(rt)
	js_error_install(rt)
