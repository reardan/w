.global _start
.section .text
_start:
    sub $8, %rsp
    mov (%rsp), %r12
    mov $9, %eax
    xor %edi, %edi
    mov $4096, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    mov %rax, %rbx
#ifdef CLEAN
    xor %r12d, %r12d
#endif
    mov %r12, (%rbx)
    mov %rbx, %rdi
    mov $4096, %esi
    xor %edx, %edx
    mov $10, %eax
    syscall
#ifndef NOACCESS
    mov %rbx, %rdi
    mov $4096, %esi
    mov $3, %edx
    mov $10, %eax
    syscall
#endif
    mov (%rbx), %rax
    test %rax, %rax
    jz finish
finish:
    xor %edi, %edi
    mov $231, %eax
    syscall
.section .note.GNU-stack,"",@progbits
