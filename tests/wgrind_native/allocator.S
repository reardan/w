/* Precompiled SysV allocator fixture. No checker annotations or client
 * requests: malloc/free symbols and CPU instructions are intercepted. */
.global malloc
.type malloc,@function
malloc:
#if defined(CALLBACK)
    call callback
#endif
    mov $9, %eax
    xor %edi, %edi
    mov $4096, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    ret
.size malloc, .-malloc
.global free
.type free,@function
free:
    ret
.size free, .-free
.section .note.GNU-stack,"",@progbits

#if defined(CALLBACK)
.text
.type callback,@function
callback:
    ud2
.size callback, .-callback
#endif
