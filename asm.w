/*
mvp for context:
	single length opcodes 
		pushad
		popad
		ret
	mov

*/

int new_node(char* node_type, char* operator, char* binary):
	int node = malloc(16)  # TODO: new node()
	int* i = node
	i[0] = node_type
	i[1] = operator
	i[2] = binary
	i[3] = 0
	return node


/*
operator0:
	pushad
	popad
	ret
	nop

*/
int operator0():
	if (accept("pushad")):
		return new_node("operator0", "pushad", "\x60")
	else if (accept("popad")):
		return new_node("operator0", "popad", "\x61")
	else if (accept("ret")):
		return new_node("operator0", "ret", "\xc3")
	else if (accept("nop")):
		return new_node("operator0", "nop", "\x90")
	return 0  # null
/*
future:
	map[string][string] opcode_by_name = {nop: "\x60", popad: "\x61", ret: "\xc3", nop: "\x90"}
	return opcode_by_name[token]
*/

/*
operator1
	call
	int
	idiv
	not
	push
	pop
	sete
	setge
	setl
	setle
	setne

*/
int operator1():
	# TODO
	return 0

/*operator2
	mov
	movsbl
	movsx
	lea
	and
	or
	xor
	add
	sub
	sar
	shl
	shr
	cmp
	test
*/

/*
inner_operand:
	register
	int_constant

operand
	inner_operand
	[ inner_operand ]
	[ inner_operand + inner_operand ]
	[ inner_operand - inner_operand ]


	 

asm-instruction-list:
	instruction-list instruction

'asm' type identifier:
	asm-instruction-list


*/

void inner_operand() {}
void operand() {}

/*
instruction: 
	operator0
	operator1 operand
	operator2 operand, operand
*/
void instruction():
	# TODO: return_if(operator0())
	if (operator0()):
		return
	if (operator1()):
		operand()
		return
	if (operator2()):
		operand()
		accept(",")
		operand()


void instruction_list():
	instruction_list()
	instruction()


void asm():
	instruction_list()

