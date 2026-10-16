/* Minimal existing ELF loader: map the precompiled .so privately, then
 * execute its C function by its ELF symbol address, with no annotations. */
.global _start
.text
_start:
    mov 16(%rsp), %rdi
    xor %esi, %esi
    xor %edx, %edx
    mov $2, %eax
    syscall
    mov %rax, %r8
    xor %edi, %edi
    mov $16384, %esi
    mov $1, %edx
    mov $2, %r10d
    xor %r9d, %r9d
    mov $9, %eax
    syscall
    mov %rax, %rbx
    lea 4096(%rbx), %rdi
    mov $4096, %esi
    mov $5, %edx
    mov $10, %eax
    syscall
    sub $32, %rsp
#if defined(CLEAN)
    movb $0, (%rsp)
#endif
    mov %rsp, %rdi
    lea SYMBOL(%rbx), %rax
    call *%rax
    test %eax, %eax
    jnz failure
    add $32, %rsp
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $5, %edi
    mov $60, %eax
    syscall
.section .note.GNU-stack,"",@progbits
