
/*
void test_nested_if():
   if (1):
      if (1):
         return

   assserts("test_nested_if() failed", 0)


void test_nested_while():
   while (0):
      while (0):
         return


problem
   void test_int_lookup_0():



int got
   0x0804c06b:  mov    $0x0,%eax
   0x0804c070:  lea    0x0(%esp),%eax
   0x0804c077:  mov    (%eax),%eax
   0x0804c079:  push   %eax

= want[0]
   0x0804c07a:  mov    $0x0,%eax
   0x0804c07f:  pop    %ebx
   0x0804c080:  add    %ebx,%eax
   0x0804c082:  movsbl (%eax),%eax
   0x0804c085:  push   %eax



int got
   0x0804c043:  mov    $0x1,%eax
   0x0804c048:  mov    0x0(%esp),%eax
   0x0804c04f:  mov    (%eax),%eax
   0x0804c051:  push   %eax

= ip[0]
   0x0804c052:  mov    $0x0,%eax
   0x0804c057:  pop    %ebx
   0x0804c058:  add    %ebx,%eax
   0x0804c05a:  movsbl (%eax),%eax
   0x0804c05d:  push   %eax
   0x0804c05e:  int3

void test_int_lookup_0():
	int want = 8888
	int *ip = want
	debugger
	int got = ip[0]
	debugger
	assert_equal(want, got)
*/

/*
problem
   type is promoted to value rather than pointer
   solutions
      change type
   ideal solution
      type = type index -> type list

postfix_expr()
   "("
      promote()
         expression()
         ...
         primary_expression()
            type_name()
            sym_get_value(token)



   0x0804c14e:  mov    $0x804c0c9,%eax   sym_get_value("func2")
   0x0804c153:  push   %eax              be_push()
   0x0804c154:  mov    $0x0,%eax         ?
func2(f)
   0x0804c159:  mov    0x4(%esp),%eax    sym_get_value("f")
   0x0804c160:  mov    (%eax),%eax         promote(2)
   0x0804c162:  push   %eax                be_push()
   0x0804c163:  mov    0x4(%esp),%eax    postfix_expr()
   0x0804c16a:  call   *%eax             postfix_expr()
   0x0804c16c:  add    $0x8,%esp
int got =
   0x0804c172:  push   %eax
   0x0804c173:  int3   
*/


/*void test_func_pointer_argument():
	int *f = func1
	debugger
	int got = func2(f)
	debugger
	assert_equal(99, got)*/



/*void test_func_argument_direct():
	int got = func2(func1)
	assert_equal(99, got)*/


/*
func pointer doesn't work:

int binary(int type, int* func, char* s):
	binary1(type)
	return binary2(func(), strlen(s), s)

binary(type, expression, "\x5b\x01\xd8")
*/


/*int test_dereference():
	int x = 1337
	int* y = &x
	assert1(x - *(y + 10 - 10))
*/
