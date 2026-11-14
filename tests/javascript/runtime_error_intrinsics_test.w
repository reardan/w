# wbuild: name=javascript_runtime_error_intrinsics_test
# wbuild: target=javascript_runtime_error_intrinsics_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 --strict tests/javascript/runtime_error_intrinsics_test.w -o bin/javascript_runtime_error_intrinsics_test"
# wbuild: step="bin/javascript_runtime_error_intrinsics_test" expect_stdout="javascript_runtime_error_intrinsics_test: OK"
# wbuild: step="bin/javascript_runtime_error_intrinsics_test memory" expect_stdout="javascript_runtime_error_intrinsics_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime

void error_eval(js_runtime* rt, char* source):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != 0 || result.value.number != 1.0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)

void error_status(js_runtime* rt, char* source, int status):
	js_runtime_collect(rt)
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	if (result.status != status):
		println(source)
		println(result.message)
	assert_equal(status, result.status)

int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	js_runtime* rt = js_runtime_new()
	error_eval(rt, c"let constructors=[Error,EvalError,RangeError,ReferenceError,SyntaxError,TypeError,URIError];let names=['Error','EvalError','RangeError','ReferenceError','SyntaxError','TypeError','URIError'];let valid=true;for(let i=0;i<constructors.length;i++){let C=constructors[i];let e=C('detail');let n=new C();if(e===n||e.constructor!==C||!(e instanceof C)||!(e instanceof Error)||e.name!==names[i]||e.message!=='detail'||n.message!==''||Object.hasOwn(n,'message')||Object.hasOwn(e,'name')||C.name!==names[i]||C.length!==1||Object.getPrototypeOf(e)!==C.prototype)valid=false;if(i>0&&(Object.getPrototypeOf(C)!==Error||Object.getPrototypeOf(C.prototype)!==Error.prototype))valid=false;}valid;")
	error_eval(rt, c"valid=true;for(let i=0;i<constructors.length;i++){let C=constructors[i];let pd=Object.getOwnPropertyDescriptor(C,'prototype');let nd=Object.getOwnPropertyDescriptor(C,'name');let ld=Object.getOwnPropertyDescriptor(C,'length');let md=Object.getOwnPropertyDescriptor(C('x'),'message');if(pd.writable||pd.enumerable||pd.configurable||nd.writable||nd.enumerable||!nd.configurable||ld.writable||ld.enumerable||!ld.configurable||!md.writable||md.enumerable||!md.configurable)valid=false;}valid;")
	error_eval(rt, c"valid=true;for(let i=0;i<constructors.length;i++){let C=constructors[i];if(Object.prototype.toString.call(C.prototype)!=='[object Object]'||Object.prototype.toString.call(C())!=='[object Error]'||Object.prototype.toString.call(Object.create(C.prototype))!=='[object Object]')valid=false;}valid;")
	error_eval(rt, c"let savedErrorName=EvalError.prototype.name;EvalError.prototype.name='Custom';let named=EvalError('x');let brand=Object.prototype.toString.call(named);let printed=String(named);EvalError.prototype.name=savedErrorName;brand==='[object Error]' && printed==='Custom: x';")
	error_eval(rt, c"String(EvalError('x'))==='EvalError: x' && String(URIError())==='URIError' && Error.prototype.toString.name==='toString' && Error.prototype.toString.length===0 && !Object.hasOwn(Error.prototype.toString,'prototype');")
	error_eval(rt, c"let cause={value:17};valid=true;for(let i=0;i<constructors.length;i++){let e=new constructors[i](undefined,{cause:cause});let d=Object.getOwnPropertyDescriptor(e,'cause');if(d.value!==cause||!d.writable||d.enumerable||!d.configurable||Object.hasOwn(e,'message'))valid=false;}valid;")
	error_eval(rt, c"let inherited={cause:undefined};let options=Object.create(inherited);let e=URIError('x',options);Object.hasOwn(e,'cause') && e.cause===undefined && !Object.hasOwn(EvalError('x',null),'cause') && !Object.hasOwn(EvalError('x','cause'),'cause');")
	error_eval(rt, c"let order='';let message={toString:function(){order+='m';return 'x';}};options={};Object.defineProperty(options,'cause',{get:function(){order+='c';return cause;}});e=URIError(message,options);e.cause===cause && e.message==='x' && order==='mc';")
	error_eval(rt, c"order='';let thrown=0;try{EvalError({toString:function(){order+='m';throw 31;}},options);}catch(x){thrown=x;}thrown===31 && order==='m';")
	error_eval(rt, c"let badOptions={};Object.defineProperty(badOptions,'cause',{get:function(){throw 41;}});thrown=0;try{URIError('x',badOptions);}catch(x){thrown=x;}thrown===41;")
	error_eval(rt, c"class Derived extends URIError{constructor(m,o){super(m,o);this.extra=9;}}let derived=new Derived('message',{cause});derived instanceof Derived && derived instanceof URIError && derived instanceof Error && derived.cause===cause && derived.extra===9;")
	error_eval(rt, c"let alternate=function(){}.bind(null);let prototype={};Object.defineProperty(alternate,'prototype',{get:function(){order+='p';return prototype;}});order='';let reflected=Reflect.construct(EvalError,[message,options],alternate);order==='pmc' && Object.getPrototypeOf(reflected)===prototype && reflected.message==='x' && reflected.cause===cause;")
	error_eval(rt, c"let Bound=URIError.bind(null,'bound',{cause});let bound=new Bound();bound instanceof URIError && bound.message==='bound' && bound.cause===cause;")
	error_eval(rt, c"thrown=0;try{JSON.parse('{');}catch(x){thrown=x.constructor===SyntaxError && Object.getPrototypeOf(x)===SyntaxError.prototype;}thrown===true;")
	error_eval(rt, c"let retainedEval=EvalError;let retainedURI=URIError;EvalError=17;URIError=19;true;")
	error_eval(rt, c"retainedEval('kept').constructor===retainedEval && retainedURI('kept').constructor===retainedURI;")
	for i in range(8):
		assert1(rt.error_prototypes[i].intrinsic_error_name[0] == 0)
		if (i > 0): assert1(rt.error_prototypes[i].prototype == rt.error_prototypes[0])
	error_eval(rt, c"let agg=new AggregateError([1,2,3],'m',{cause:7});agg.errors.length===3 && agg.errors[2]===3 && agg.message==='m' && agg.cause===7 && agg instanceof AggregateError && agg instanceof Error && Error.isError(agg) && Object.getPrototypeOf(AggregateError)===Error && Object.getPrototypeOf(AggregateError.prototype)===Error.prototype && AggregateError.length===2 && AggregateError.name==='AggregateError' && AggregateError('x').errors===undefined===false;")
	error_eval(rt, c"let ad=Object.getOwnPropertyDescriptor(AggregateError([]),'errors');ad.writable && !ad.enumerable && ad.configurable && AggregateError.prototype.name==='AggregateError' && AggregateError.prototype.message==='' && String(AggregateError([],'x'))==='AggregateError: x';")
	error_eval(rt, c"order='';let src={};src[Symbol.iterator]=function(){order+='i';return [1][Symbol.iterator]();};let od={};Object.defineProperty(od,'cause',{get:function(){order+='c';return 1;}});new AggregateError(src,{toString:function(){order+='m';return 'x';}},od);order==='mci';")
	error_eval(rt, c"let toStringCalls=0;let target={name:'N',message:'M'};Error.prototype.toString.call(target)==='N: M' && Error.prototype.toString.call({})==='Error' && Error.prototype.toString.call({name:'',message:'only'})==='only' && Error.prototype.toString.call({name:'only',message:''})==='only' && Error.prototype.toString.call({name:undefined,message:undefined})==='Error';")
	error_eval(rt, c"let reads='';let probe={};Object.defineProperty(probe,'name',{get:function(){reads+='n';throw 51;}});Object.defineProperty(probe,'message',{get:function(){reads+='m';return 'x';}});thrown=0;try{Error.prototype.toString.call(probe);}catch(x){thrown=x;}thrown===51 && reads==='n';")
	error_eval(rt, c"thrown=0;try{Error.prototype.toString.call(1);}catch(x){thrown=x.constructor===TypeError;}thrown===true;")
	error_eval(rt, c"thrown=0;try{AggregateError(1);}catch(x){thrown=x.constructor===TypeError;}thrown===true;")
	error_status(rt, c"let selfNamed=new Error('x');selfNamed.name=selfNamed;String(selfNamed);", 5)
	error_status(rt, c"let endless={};endless[Symbol.iterator]=function(){return {next:function(){return {done:false,value:1};}};};new AggregateError(endless);", 5)
	js_runtime_free(rt)
	rt = js_runtime_new()
	rt.max_properties = 4
	error_status(rt, c"new AggregateError([1,2,3,4,5,6,7,8]);", 5)
	js_runtime_free(rt)
	rt = js_runtime_new()
	js_runtime* foreign = js_runtime_new()
	list[js_value*] arguments = new list[js_value*]
	arguments.push(foreign.undefined_value)
	js_runtime_call(rt, js_runtime_get(rt, rt.global, c"Error"), arguments)
	assert_equal(2, rt.completion.status)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_free(foreign)
	js_runtime_free(rt)
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_error_intrinsics_test: OK")
	return 0
