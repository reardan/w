# wbuild: name=javascript_runtime_array_mutation_test
# wbuild: target=javascript_runtime_array_mutation_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_array_mutation_test.w -o bin/javascript_runtime_array_mutation_test"
# wbuild: step="bin/javascript_runtime_array_mutation_test" expect_stdout="javascript_runtime_array_mutation_test: OK"
# wbuild: step="bin/javascript_runtime_array_mutation_test memory" expect_stdout="javascript_runtime_array_mutation_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void mutation_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

js_value* mutation_host_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	int* reads = cast(int*, context)
	assert_equal(-1, js_runtime_collect(rt))
	*reads = *reads + 1
	if (js_runtime_key_is(key, c"length")): return js_runtime_number(rt, 1.0)
	return rt.undefined_value

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	mutation_eval(rt, c"function own(o,k){return Object.getOwnPropertyDescriptor(o,k)!==undefined;}true;")
	mutation_eval(rt, c"let a=[1,2];a.push(3,4)===4 && a.pop()===4 && a.shift()===1 && a.unshift(8,9)===4 && a.join(',')==='8,9,2,3';")
	mutation_eval(rt, c"let empty=[];empty.pop()===undefined && empty.shift()===undefined && empty.push()===0 && empty.unshift()===0 && empty.length===0;")
	mutation_eval(rt, c"let sparse=Array(3);sparse[2]='x';sparse.shift()===undefined && sparse.length===2 && !(0 in sparse) && sparse[1]==='x' && sparse.unshift('a')===3 && sparse[0]==='a' && !(1 in sparse) && sparse[2]==='x';")
	mutation_eval(rt, c"let generic={1:'x',length:3};Array.prototype.shift.call(generic)===undefined && generic[0]==='x' && !own(generic,'1') && generic.length===2 && Array.prototype.unshift.call(generic,'a','b')===4 && generic[0]==='a' && generic[1]==='b' && generic[2]==='x' && !own(generic,'3');")
	mutation_eval(rt, c"let plain={};Array.prototype.push.call(plain,1,2)===2 && plain.length===2 && Array.prototype.pop.call(plain)===2 && plain.length===1 && !own(plain,'1');")
	mutation_eval(rt, c"function Base(){}Base.prototype[0]='first';Base.prototype[2]='last';let inherited=new Base();inherited.length=3;Array.prototype.shift.call(inherited)==='first' && !own(inherited,'0') && inherited[0]==='first' && inherited[1]==='last' && inherited.length===2;")
	mutation_eval(rt, c"function Base2(){}Base2.prototype[1]=17;let inheritedPop=new Base2();inheritedPop.length=2;Array.prototype.pop.call(inheritedPop)===17 && inheritedPop.length===1 && inheritedPop[1]===17 && !own(inheritedPop,'1');")
	mutation_eval(rt, c"let order='';let live={};Object.defineProperty(live,'length',{get:function(){order+='l';return {valueOf:function(){order+='v';return 1;}};},set:function(v){order+='L'+String(v);}});Object.defineProperty(live,'0',{get:function(){order+='g';return 7;},configurable:true});Array.prototype.pop.call(live)===7 && order==='lvgL0' && !own(live,'0');")
	mutation_eval(rt, c"let setterLog='';function Setter(){}Object.defineProperty(Setter.prototype,'0',{set:function(v){setterLog+='s'+String(v);this.length=99;}});let target=new Setter();target.length=0;Array.prototype.push.call(target,5)===1 && setterLog==='s5' && target.length===1 && !own(target,'0');")
	mutation_eval(rt, c"let shiftOrder='';let moving={length:3};Object.defineProperty(moving,'0',{get:function(){shiftOrder+='a';return 10;},set:function(v){shiftOrder+='b'+String(v);},configurable:true});Object.defineProperty(moving,'2',{get:function(){shiftOrder+='c';return 20;},configurable:true});Array.prototype.shift.call(moving)===10 && shiftOrder==='ac' && !own(moving,'0') && moving[1]===20 && !own(moving,'2');")
	mutation_eval(rt, c"let reverseOrder='';let unshifting={length:2};Object.defineProperty(unshifting,'0',{get:function(){reverseOrder+='a';return 4;},set:function(v){reverseOrder+='s'+String(v);},configurable:true});Object.defineProperty(unshifting,'1',{get:function(){reverseOrder+='b';return 5;},set:function(v){reverseOrder+='t'+String(v);},configurable:true});Array.prototype.unshift.call(unshifting,3)===3 && reverseOrder==='bat4s3' && unshifting[2]===5;")
	mutation_eval(rt, c"let zero={length:-1};Array.prototype.shift.call(zero)===undefined && zero.length===0 && Array.prototype.unshift.call({length:1.9})===1 && Array.prototype.push.call({length:NaN},8)===1;")
	mutation_eval(rt, c"let tail=[1,2];Object.defineProperty(tail,'1',{configurable:false});caught=false;try{tail.shift();}catch(e){caught=e.constructor===TypeError;}caught && tail.length===2 && tail[0]===2 && tail[1]===2;")
	mutation_eval(rt, c"let throwing={length:1};Object.defineProperty(throwing,'0',{get:function(){throw 73;},configurable:true});let thrown=0;try{Array.prototype.pop.call(throwing);}catch(e){thrown=e;}thrown===73 && throwing.length===1 && own(throwing,'0');")
	mutation_eval(rt, c"let noLengthWrite={};Object.defineProperty(noLengthWrite,'length',{get:function(){throw 74;}});thrown=0;try{Array.prototype.push.call(noLengthWrite,3);}catch(e){thrown=e;}thrown===74 && !own(noLengthWrite,'0');")
	mutation_eval(rt, c"let names=['push','pop','shift','unshift'];let errors=0;for(let i=0;i<names.length;i++){try{Array.prototype[names[i]].call(null);}catch(e){if(e.constructor===TypeError)errors++;}try{Array.prototype[names[i]].call('');}catch(e){if(e.constructor===TypeError)errors++;}}errors===8;")
	mutation_eval(rt, c"let scalar=Object(7);Array.prototype.push.call(scalar,'x')===1 && scalar[0]==='x' && scalar.length===1 && Array.prototype.pop.call(scalar)==='x' && scalar.length===0;")
	mutation_eval(rt, c"let valid=true;for(let i=0;i<names.length;i++){let method=Array.prototype[names[i]];let d=Object.getOwnPropertyDescriptor(Array.prototype,names[i]);let expected=(i===0||i===3)?1:0;if(method.name!==names[i]||method.length!==expected||own(method,'prototype')||!d.writable||d.enumerable||!d.configurable)valid=false;}valid;")
	js_value* push = js_runtime_get(rt, rt.array_prototype, c"push")
	js_value* pop = js_runtime_get(rt, rt.array_prototype, c"pop")
	js_value* object = js_runtime_alloc(rt, 5)
	assert1(js_runtime_root(rt, object))
	assert1(js_runtime_set(rt, object, c"length", js_runtime_number(rt, 0.0)))
	list[js_value*] arguments = new list[js_value*]
	arguments.push(js_runtime_number(rt, 1.0))
	arguments.push(js_runtime_number(rt, 2.0))
	# One call step, two argument steps, then exactly one element write.
	js_runtime_invoke_receiver(rt, push, object, arguments, 4)
	assert_equal(5, rt.completion.status)
	js_runtime_begin(rt, 1000)
	assert1(js_runtime_get(rt, object, c"0").number == 1.0)
	assert1(js_runtime_get(rt, object, c"length").number == 0.0)
	js_text* one = js_runtime_key(c"1")
	assert1(js_runtime_property(object, one) == 0)
	js_text_free(one)
	js_runtime_begin(rt, 1000)
	js_value* host = js_runtime_alloc(rt, 5)
	int reads = 0
	assert1(js_runtime_set_host_hooks(rt, host, &reads, mutation_host_get, 0))
	assert1(js_runtime_root(rt, host))
	arguments.clear()
	js_runtime_invoke_receiver(rt, pop, host, arguments, 1000)
	assert_equal(0, rt.completion.status)
	assert_equal(2, reads)
	js_runtime* foreign = js_runtime_new()
	js_runtime_begin(rt, 1000)
	arguments.push(foreign.undefined_value)
	js_runtime_call_receiver(rt, push, object, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_begin(rt, 1000)
	arguments.clear()
	js_runtime_call_receiver(rt, pop, foreign.global, arguments)
	assert_equal(2, rt.completion.status)
	js_runtime_free(foreign)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_array_mutation_test: OK")
	return 0
