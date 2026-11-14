# wbuild: name=javascript_runtime_reflect_construct_test
# wbuild: target=javascript_runtime_reflect_construct_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_reflect_construct_test.w -o bin/javascript_runtime_reflect_construct_test"
# wbuild: step="bin/javascript_runtime_reflect_construct_test" expect_stdout="javascript_runtime_reflect_construct_test: OK"
# wbuild: step="bin/javascript_runtime_reflect_construct_test memory" expect_stdout="javascript_runtime_reflect_construct_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void reflect_construct_eval(js_runtime* rt, char* source, int status):
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
	reflect_construct_eval(rt, c"function C(a,b){this.sum=a+b;}let x=Reflect.construct(C,[2,3]);x.sum===5 && Object.getPrototypeOf(x)===C.prototype && Reflect.construct.length===2;", 0)
	reflect_construct_eval(rt, c"function N(){}let alt=Reflect.construct(C,[3,4],N);alt.sum===7 && Object.getPrototypeOf(alt)===N.prototype;", 0)
	reflect_construct_eval(rt, c"function Returns(){return {a:7};}Reflect.construct(Returns,[],N).a===7;", 0)
	reflect_construct_eval(rt, c"function Primitive(){return 4;}Object.getPrototypeOf(Reflect.construct(Primitive,[],N))===N.prototype;", 0)
	reflect_construct_eval(rt, c"let bound=C.bind({wrong:1},4);let bx=Reflect.construct(bound,[5]);bx.sum===9 && Object.getPrototypeOf(bx)===C.prototype;", 0)
	reflect_construct_eval(rt, c"let by=Reflect.construct(bound,[6],N);by.sum===10 && Object.getPrototypeOf(by)===N.prototype;", 0)
	reflect_construct_eval(rt, c"function P(){}P.prototype=null;Object.getPrototypeOf(Reflect.construct(C,[1,2],P))===Object.prototype;", 0)
	reflect_construct_eval(rt, c"class Base{constructor(a){this.a=a;}}class Derived extends Base{}let cls=Reflect.construct(Derived,[17],N);cls.a===17 && Object.getPrototypeOf(cls)===N.prototype && Object.getPrototypeOf(Base.prototype)===Object.prototype;", 0)
	reflect_construct_eval(rt, c"class Nil extends null{constructor(){return {};}}Object.getPrototypeOf(Nil.prototype)===null;", 0)
	reflect_construct_eval(rt, c"let log='';let input={};Object.defineProperty(input,'length',{get:function(){log+='l';return 2;}});Object.defineProperty(input,'0',{get:function(){log+='0';return 3;}});Object.defineProperty(input,'1',{get:function(){log+='1';return 4;}});let NT=N.bind(null);let proto={};Object.defineProperty(NT,'prototype',{get:function(){log+='p';return proto;}});function T(a,b){log+='c';this.sum=a+b;}let ordered=Reflect.construct(T,input,NT);log==='l01pc' && ordered.sum===7 && Object.getPrototypeOf(ordered)===proto;", 0)
	reflect_construct_eval(rt, c"let errorOrder='';let ET=N.bind(null);let errorProto={};Object.defineProperty(ET,'prototype',{get:function(){errorOrder+='p';return errorProto;}});let err=Reflect.construct(TypeError,[{toString:function(){errorOrder+='m';return 'boom';}}],ET);errorOrder==='pm' && err.message==='boom' && Object.getPrototypeOf(err)===errorProto;", 0)
	reflect_construct_eval(rt, c"let errors=0;let unread={};Object.defineProperty(unread,'length',{get:function(){throw 90;}});try{Reflect.construct(()=>1,unread);}catch(e){if(e.constructor===TypeError)errors++;}try{Reflect.construct(C,unread,()=>1);}catch(e){if(e.constructor===TypeError)errors++;}try{Reflect.construct(C,[],undefined);}catch(e){if(e.constructor===TypeError)errors++;}errors===3;", 0)
	reflect_construct_eval(rt, c"let invalid=0;try{Reflect.construct(C,'ab');}catch(e){if(e.constructor===TypeError)invalid++;}try{Reflect.construct(C,null);}catch(e){if(e.constructor===TypeError)invalid++;}try{Reflect.construct(Object.is,[]);}catch(e){if(e.constructor===TypeError)invalid++;}invalid===3;", 0)
	reflect_construct_eval(rt, c"let abrupt=0;try{Reflect.construct(C,unread);}catch(e){abrupt=e;}abrupt===90;", 0)
	reflect_construct_eval(rt, c"let throwProto=N.bind(null);Object.defineProperty(throwProto,'prototype',{get:function(){throw 91;}});let beforeMessage=0;let thrown=0;try{Reflect.construct(Error,[{toString:function(){beforeMessage++;return 'x';}}],throwProto);}catch(e){thrown=e;}thrown===91 && beforeMessage===0;", 0)
	reflect_construct_eval(rt, c"let sparseArgs={length:2,1:8};function Sparse(a,b){this.good=a===undefined && b===8;}Reflect.construct(Sparse,sparseArgs).good;", 0)
	reflect_construct_eval(rt, c"Reflect.construct(Number,[3]).valueOf()===3 && Reflect.construct(Error,['m']).message==='m';", 0)
	reflect_construct_eval(rt, c"function BodyThrow(){throw 92;}let bodyError=0;try{Reflect.construct(BodyThrow,[]);}catch(e){bodyError=e;}bodyError===92;", 0)
	reflect_construct_eval(rt, c"Reflect.construct(C,{length:Infinity});", 5)
	js_runtime_collect(rt)
	reflect_construct_eval(rt, c"ordered.sum===7 && Object.getPrototypeOf(ordered)===proto && err.message==='boom';", 0)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_reflect_construct_test: OK")
	return 0
