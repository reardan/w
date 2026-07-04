import compiler.tokenizer

/*
mvp for context:
	single length opcodes 
		pushad
		popad
		ret
	mov

*/

int new_node(char* node_type, char* operator, char* binary):
	int node = malloc(16)
	# int* i = node
	# i[0] = node_type
	# i[1] = operator
	# i[2] = binary
	# i[3] = 0
	return node


/*
operator0:
	pushad
	popad
	ret
	nop

*/
int operator0():
	if (accept(c"pushad")):
		return new_node(c"operator0", c"pushad", c"\x60")
	else if (accept(c"popad")):
		return new_node(c"operator0", c"popad", c"\x61")
	else if (accept(c"ret")):
		return new_node(c"operator0", c"ret", c"\xc3")
	else if (accept(c"nop")):
		return new_node(c"operator0", c"nop", c"\x90")
	return 0  # null
/*
future:
	map[string][string] opcode_by_name = {nop: "\x60", popad: "\x61", ret: "\xc3", nop: "\x90"}
	return opcode_by_name[token]
*/

/*
operator1
	call int idiv not push pop sete setge setl setle setne
*/
int operator1():
	# TODO
	return 0

/*operator2
	mov movsbl movsx lea and or xor add sub sar shl shr cmp test */
int operator2():
	# TODO
	return 0

/*
inner_operand:
	register
	int_constant
*/
int inner_operand() {}

/*
operand
	inner_operand
	[ inner_operand ]
	[ inner_operand + inner_operand ]
	[ inner_operand - inner_operand ]
*/
int operand() {}

/*
asm-instruction-list:
	instruction-list instruction

'asm' type identifier:
	asm-instruction-list


*/


/*
instruction: 
	operator0
	operator1 operand
	operator2 operand, operand
*/
int instruction():
	# TODO: return_if(operator0())
	if (operator0()):
		return;
	else if (operator1()):
		operand()
		return;
	else if (operator2()):
		operand()
		accept(c",")
		operand()
	else:
		return 0;


int instruction_list():
	instruction_list()
	instruction()


int asm():
	instruction_list()



char* assemble(char* text):
	char *output = token

	return output
