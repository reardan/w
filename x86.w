/*
References:

http://www.mathemainzel.info/files/x86asmref.html

*/


/*
map[byte][int] opcode_length = {
	'\x90': 1,
	# ...
}
*/


/*
What about multi-length bytecodes?
We actually need a tree structure

0x90: 1,
0x90: {
	,
}


*/ 
/*
# this treemap will need to be auto-generated somehow
tree+map[string][bytes] name_opcode = {
	nop: "\x90",
	mov: {
		eax: {
			eax: "\x89\xc0",
		},
	}
}


# another option: just start simple with only the instructions we need
add %ebx,%eax
add eax, 24

and %ebx,%eax

call *%eax
call 0x08004000

cmp %eax,%ebx

idiv ebx
imul eax,ebx

int 0x80
int 30

lea (n * 4)(%esp),%eax

mov $n,%eax
mov $x,%eax
mov %al,(%ebx)
mov %ax,(%ebx)
mov %eax,(%ebx)
mov (%eax),%eax
mov 16(%esp),%eax
mov eax, [esp + ....]

movsbl (%eax),%eax
movsbl (%eax),%eax
movsx eax, word[eax]
movzbl %al,%eax

not eax

or %ebx,%eax

push eax
push 0x8
push word 0x4
push byte 0x1
pop eax

pushad
popad

ret
sar %cl,%eax
sete %al
setge %al
setge %al
setl %al
setle %al
setne %al
shl %cl,%eax
shr %cl,%eax
sub %eax,%ebx
sub eax, 28
test %eax,%eax ; je ...
xor edx,edx
*/



/*
mov eax,

*/
