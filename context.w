int eax
int ecx
int edx
int ebx
int esp
int ebp
int esi
int edi


asm push(this):
	mov eax, esp      # save esp
	mov esp, [esp+4]  # this context
	pushad            # push context
	mov esp,eax       # restore esp
	ret


asm pop(this):
	mov esp, [esp+4]  # get this context
	popad             # pop context
	ret
