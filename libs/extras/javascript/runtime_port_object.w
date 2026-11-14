/*
Seam for the JS builtins port (object cluster). Called once from js_runtime_new
after every other install step. This file belongs to the object cluster agent.
Object.prototype is created here: the runtime allocated no Object.prototype
before, so ordinary objects built earlier adopt it in js_object_install.
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_object
import libs.extras.javascript.runtime_array_descriptor
import libs.extras.javascript.runtime_object_integrity
import libs.extras.javascript.runtime_reflect_construct
import libs.extras.javascript.runtime_json


void js_install_object(js_runtime* rt):
	js_object_install(rt)
	js_object_install_integrity(rt)
	js_object_install_reflect_construct(rt)
	js_object_install_json(rt)
