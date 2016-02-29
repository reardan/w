/*w2.c
Tokenizer: ~ 80-100 lines
Binary Generation: 46 emits -> 50-100 lines
	Use a generic syscall function to simplify and reduce
Symbol Table: ~100 lines
Language Logic: ~500 lines


Stack:
	main arguments
	[main return value]
	main local variables
	

Function:
	push ebp
	mov ebp,esp
	sub esp,12
	...
	mov esp,ebp
	pop ebp
	ret

*/