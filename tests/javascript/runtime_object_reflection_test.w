# wbuild: name=javascript_runtime_object_reflection_test
# wbuild: target=javascript_runtime_object_reflection_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_object_reflection_test.w -o bin/javascript_runtime_object_reflection_test"
# wbuild: step="bin/javascript_runtime_object_reflection_test" expect_stdout="javascript_runtime_object_reflection_test: OK"
# wbuild: step="bin/javascript_runtime_object_reflection_test memory" expect_stdout="javascript_runtime_object_reflection_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void reflection_eval(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status || (status == 0 && result.value.number != 1.0)):
		println(source)
		println(result.message)
	assert_equal(status, result.status)
	if (status == 0): assert1(result.value.number == 1.0)

void test_reflection():
	js_runtime* rt = js_runtime_new()
	reflection_eval(rt, c"let o={};Object(o)===o && Object.getPrototypeOf(o)===Object.prototype && Object.getPrototypeOf(Object.create(null))===null;", 0)
	reflection_eval(rt, c"Object.defineProperty(o,'x',{value:7});let d=Object.getOwnPropertyDescriptor(o,'x');d.value===7 && !d.writable && !d.enumerable && !d.configurable;", 0)
	reflection_eval(rt, c"Object.defineProperty(o,'x',{});Reflect.defineProperty(o,'x',{value:7}) && !Reflect.defineProperty(o,'x',{value:8}) && !Reflect.deleteProperty(o,'x');", 0)
	reflection_eval(rt, c"let p={};let child=Object.create(p);Object.defineProperty(p,'x',{get:function(){return this.y;},set:function(v){this.y=v;},configurable:true});child.x=11;child.x===11 && Reflect.get(p,'x',{y:9})===9;", 0)
	reflection_eval(rt, c"let rec={};Reflect.set(p,'x',14,rec) && rec.y===14 && !Object.hasOwn(rec,'x') && Object.hasOwn(p,'x');", 0)
	reflection_eval(rt, c"Object.defineProperty(p,'x',{value:3});let pd=Object.getOwnPropertyDescriptor(p,'x');pd.value===3 && !pd.writable && pd.configurable && !('get' in pd);", 0)
	reflection_eval(rt, c"let inherited=Object.create({value:9,writable:true});Object.defineProperty(o,'z',inherited);o.z===9 && Object.getOwnPropertyDescriptor(o,'z').writable;", 0)
	reflection_eval(rt, c"let order='';let desc={};Object.defineProperty(desc,'enumerable',{get:function(){order+='e';return true;}});Object.defineProperty(desc,'configurable',{get:function(){order+='c';return true;}});Object.defineProperty(desc,'value',{get:function(){order+='v';return 8;}});Object.defineProperty(desc,'writable',{get:function(){order+='w';return true;}});Object.defineProperty(o,'ordered',desc);order==='ecvw' && o.ordered===8;", 0)
	reflection_eval(rt, c"let atomic={};let caught=0;try{Object.defineProperties(atomic,{a:{value:1},b:{get:3}});}catch(e){caught=1;}caught===1 && !Object.hasOwn(atomic,'a');", 0)
	reflection_eval(rt, c"let thrown={};Object.defineProperty(thrown,'value',{get:function(){throw 71;}});let n=0;try{Object.defineProperty(o,'bad',thrown);}catch(e){n=e;}n===71 && !Object.hasOwn(o,'bad');", 0)
	reflection_eval(rt, c"let mixed=0;try{Object.defineProperty(o,'mixed',{get:undefined,value:1});}catch(e){mixed=1;}mixed===1;", 0)
	reflection_eval(rt, c"let names={z:1};Object.defineProperty(names,'2',{value:2,enumerable:true});Object.defineProperty(names,'1',{value:3,enumerable:true});Object.defineProperty(names,'hidden',{value:4});let keys=Object.keys(names);keys.length===3 && keys[0]==='1' && keys[1]==='2' && keys[2]==='z' && Object.getOwnPropertyNames(names)[3]==='hidden';", 0)
	reflection_eval(rt, c"Object.preventExtensions(names);!Object.isExtensible(names) && !Reflect.defineProperty(names,'new',{}) && !Reflect.set(names,'new',3) && Reflect.setPrototypeOf(names,Object.getPrototypeOf(names)) && !Reflect.setPrototypeOf(names,null);", 0)
	reflection_eval(rt, c"let cycle={};let derived=Object.create(cycle);!Reflect.setPrototypeOf(cycle,derived) && Object.getPrototypeOf(cycle)===Object.prototype;", 0)
	reflection_eval(rt, c"Object.is(NaN,NaN) && !Object.is(0,-0) && o.hasOwnProperty('x') && !o.propertyIsEnumerable('x') && Object.prototype.toString.call(null)==='[object Null]';", 0)
	reflection_eval(rt, c"let key={toString:function(){return 'coerced';}};Object.defineProperty(o,key,{value:22});o.coerced===22;", 0)
	reflection_eval(rt, c"let locked={};Object.defineProperty(locked,'x',{value:1});let receiver={};!Reflect.set(locked,'x',2,receiver) && !Object.hasOwn(receiver,'x');", 0)
	reflection_eval(rt, c"let array=[];let ld=Object.getOwnPropertyDescriptor(array,'length');ld.value===0 && ld.writable && !ld.configurable && !ld.enumerable && !Reflect.deleteProperty(array,'length');", 0)
	reflection_eval(rt, c"let typed=0;try{Object.defineProperty({},'x',{get:3});}catch(e){typed=e.constructor===TypeError && e instanceof Error;}typed && new RangeError() instanceof Error && new SyntaxError().constructor===SyntaxError;", 0)
	reflection_eval(rt, c"let range=0;try{Array(-1);}catch(e){range=e.constructor===RangeError;}range===true;", 0)
	reflection_eval(rt, c"let orderedArray=[];orderedArray.foo=1;let arrayKeys=Reflect.ownKeys(orderedArray);arrayKeys[0]==='length' && arrayKeys[1]==='foo' && Reflect.get(orderedArray,'length',{})===0;", 0)
	reflection_eval(rt, c"let deletable={x:1};delete deletable.x && !('x' in deletable) && !delete o.x && delete neverDeclared;", 0)
	reflection_eval(rt, c"let noGet={};Object.defineProperty(noGet,'x',{get:function(){throw 99;},configurable:true});delete noGet.x && !Object.hasOwn(noGet,'x');", 0)
	reflection_eval(rt, c"'use strict';delete o.x;", 2)
	reflection_eval(rt, c"let sparse=[1,2,3];delete sparse[1] && sparse.length===3 && !(1 in sparse) && !delete sparse.length;", 0)
	reflection_eval(rt, c"Object.create.length===2 && Object.defineProperty.length===3 && Reflect.set.length===3 && Object.prototype.isPrototypeOf({}) && !Object.prototype.isPrototypeOf(Object.create(null));", 0)
	reflection_eval(rt, c"function tag(){'use strict';return Object.prototype.toString.call(arguments);}tag()==='[object Arguments]';", 0)
	js_runtime* foreign = js_runtime_new()
	js_value* target = js_runtime_alloc(rt, 5)
	js_value* other = js_runtime_alloc(foreign, 5)
	js_text* key = js_runtime_key(c"foreign")
	assert_equal(0, js_runtime_define_data(rt, target, key, other, 1, 1, 1))
	assert_equal(0, js_runtime_set_prototype(rt, target, other))
	js_text_free(key)
	js_runtime_free(foreign)
	js_runtime_free(rt)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_reflection()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_object_reflection_test: OK")
	return 0
