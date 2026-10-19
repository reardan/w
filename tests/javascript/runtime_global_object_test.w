# wbuild: name=javascript_runtime_global_object_test
# wbuild: target=javascript_runtime_global_object_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_global_object_test.w -o bin/javascript_runtime_global_object_test"
# wbuild: step="bin/javascript_runtime_global_object_test" expect_stdout="javascript_runtime_global_object_test: OK"
# wbuild: step="bin/javascript_runtime_global_object_test memory" expect_stdout="javascript_runtime_global_object_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void global_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	js_value* window = js_runtime_alloc(rt, 5)
	js_runtime_set(rt, window, c"self", window)
	assert1(js_runtime_set_global_object(rt, window))
	assert_equal(0, js_runtime_set_global_object(rt, window))
	assert1(js_runtime_get(rt, rt.global, c"Object") == js_runtime_get(rt, window, c"Object"))
	assert_equal(0, rt.completion.status)
	global_eval(rt, c"self.dynamic=17;dynamic===17 && this===self && self.Object===Object;", 0)
	global_eval(rt, c"dynamic=18;self.dynamic===18 && typeof missing==='undefined';", 0)
	global_eval(rt, c"let shadow=3;self.shadow=9;shadow===3 && self.shadow===9;", 0)
	global_eval(rt, c"self.tdz=8;let caught=false;try{let value=tdz;let tdz=1;}catch(e){caught=e.constructor===ReferenceError;}caught;", 0)
	global_eval(rt, c"var exposed=4;function published(){return exposed;}self.exposed===4 && self.published===published && published()===4;", 0)
	global_eval(rt, c"self.exposed=6;published()===6 && !Reflect.deleteProperty(self,'exposed');", 0)
	global_eval(rt, c"exposed=7;self.exposed===7;", 0)
	global_eval(rt, c"let access=1;Object.defineProperty(self,'tracked',{get:function(){return access;},set:function(v){access=v;},configurable:true});tracked=12;tracked===12 && access===12;", 0)
	global_eval(rt, c"Object.defineProperty(self,'bad',{get:function(){throw 73;}});let error=0;try{bad;}catch(e){error=e;}error===73;", 0)
	global_eval(rt, c"Object.defineProperty(self,'fixed',{value:9});fixed=10;fixed===9;", 0)
	global_eval(rt, c"'use strict';fixed=11;", 2)
	global_eval(rt, c"Reflect.deleteProperty(self,'dynamic');typeof dynamic==='undefined';", 0)
	global_eval(rt, c"dynamic;", 2)
	global_eval(rt, c"self.exported=22;let short={exported};short.exported===22;", 0)
	global_eval(rt, c"undeclared=5;self.undeclared===5;", 0)
	global_eval(rt, c"'use strict';strictMissing=5;", 2)
	global_eval(rt, c"true;", 0)
	assert1(js_runtime_get(rt, rt.global, c"Object") == js_runtime_get(rt, window, c"Object"))
	assert1(js_runtime_set(rt, rt.global, c"hostNew", js_runtime_number(rt, 42.0)))
	assert1(js_runtime_get(rt, window, c"hostNew").number == 42.0)
	assert1(js_runtime_set(rt, rt.global, c"exposed", js_runtime_number(rt, 25.0)))
	assert1(js_runtime_get(rt, window, c"exposed").number == 25.0)
	assert1(js_runtime_get(rt, rt.global, c"exposed").number == 25.0)
	global_eval(rt, c"exposed===25 && hostNew===42;", 0)
	global_eval(rt, c"function sloppy(){return this;}sloppy()===self && sloppy.call(null)===self && sloppy.apply(undefined,[])===self;", 0)
	global_eval(rt, c"function strictThis(){'use strict';return this;}strictThis()===undefined && strictThis.call(null)===null && strictThis.call(7)===7;", 0)
	global_eval(rt, c"function box(){this.marker=3;return this;}let boxed=box.call(7);boxed.valueOf()===7 && boxed.marker===3 && Object.getPrototypeOf(boxed)===Number.prototype;", 0)
	global_eval(rt, c"function same(){let a=this;return this===a;}same.call('a') && sloppy.call(true).valueOf()===true && sloppy.call(1n).valueOf()===1n;", 0)
	global_eval(rt, c"function capture(){return ()=>this;}let arrow=capture.call('abc');let lexical=arrow.call({});lexical.valueOf()==='abc' && lexical===arrow();", 0)
	global_eval(rt, c"function defaultThis(a=this){return a===this;}defaultThis.call(3);", 0)
	global_eval(rt, c"function Ctor(){this.answer=19;}let made=new Ctor();made.answer===19 && made!==self && !Object.hasOwn(self,'answer');", 0)
	global_eval(rt, c"async function asyncThis(){return this;}let asyncGlobal=false;asyncThis().then(function(value){asyncGlobal=value===self;});true;", 0)
	assert_equal(0, js_runtime_drain_microtasks(rt, 100000).status)
	global_eval(rt, c"asyncGlobal && arrow()===lexical && boxed.marker===3;", 0)
	global_eval(rt, c"let boundNull=sloppy.bind(null);let boundNumber=sloppy.bind(3);boundNull()===self && boundNumber().valueOf()===3 && boundNumber()!==boundNumber();", 0)
	global_eval(rt, c"class StrictMethod{method(){return this;}}StrictMethod.prototype.method.call(null)===null;", 0)
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	js_value* callable = js_runtime_get(rt, rt.global, c"sloppy")
	js_runtime_call_receiver(rt, callable, foreign.undefined_value, arguments)
	assert_equal(2, rt.completion.status)
	global_eval(rt, c"true;", 0)
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, callable, window, arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_global_object_test: OK")
	return 0
