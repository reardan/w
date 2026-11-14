/*
Seam for the JS builtins port (array cluster). Called once from js_runtime_new
after every other install step. The Array constructor and its generic
prototype methods live in the runtime_array*.w leaf files.
*/
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_array_like
import libs.extras.javascript.runtime_array
import libs.extras.javascript.runtime_array_mutation
import libs.extras.javascript.runtime_array_search
import libs.extras.javascript.runtime_array_join
import libs.extras.javascript.runtime_array_concat
import libs.extras.javascript.runtime_array_iteration


void js_install_array(js_runtime* rt):
	if (rt.array_prototype == 0): return
	js_ap_install_constructor(rt)
	js_value* proto = rt.array_prototype
	js_ap_method(rt, proto, c"push", js_ap_mutation, 1, 1)
	js_ap_method(rt, proto, c"pop", js_ap_mutation, 2, 0)
	js_ap_method(rt, proto, c"shift", js_ap_mutation, 3, 0)
	js_ap_method(rt, proto, c"unshift", js_ap_mutation, 4, 1)
	js_ap_method(rt, proto, c"slice", js_ap_slice, 0, 2)
	js_ap_method(rt, proto, c"concat", js_ap_concat, 0, 1)
	js_ap_method(rt, proto, c"join", js_ap_join, 0, 1)
	js_ap_method(rt, proto, c"toString", js_ap_to_string, 0, 0)
	js_ap_method(rt, proto, c"indexOf", js_ap_index_of, 0, 1)
	js_ap_method(rt, proto, c"lastIndexOf", js_ap_index_of, 1, 1)
	js_ap_method(rt, proto, c"every", js_ap_iteration, JS_AP_EVERY, 1)
	js_ap_method(rt, proto, c"some", js_ap_iteration, JS_AP_SOME, 1)
	js_ap_method(rt, proto, c"forEach", js_ap_iteration, JS_AP_FOREACH, 1)
	js_ap_method(rt, proto, c"map", js_ap_iteration, JS_AP_MAP, 1)
	js_ap_method(rt, proto, c"filter", js_ap_iteration, JS_AP_FILTER, 1)
	js_ap_method(rt, proto, c"find", js_ap_iteration, JS_AP_FIND, 1)
	js_ap_method(rt, proto, c"findIndex", js_ap_iteration, JS_AP_FIND_INDEX, 1)
	js_ap_method(rt, proto, c"findLast", js_ap_iteration, JS_AP_FIND_LAST, 1)
	js_ap_method(rt, proto, c"findLastIndex", js_ap_iteration, JS_AP_FIND_LAST_INDEX, 1)
	js_ap_method(rt, proto, c"reduce", js_ap_iteration, JS_AP_REDUCE, 1)
	js_ap_method(rt, proto, c"reduceRight", js_ap_iteration, JS_AP_REDUCE_RIGHT, 1)
