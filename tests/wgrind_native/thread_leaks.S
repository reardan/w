.global _start
.extern malloc
.section .text
_start:
    mov $8, %edi
    call malloc
    mov %rax, %r12
    mov $9, %eax
    xor %edi, %edi
    mov $69632, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    lea 65536(%rax), %rsi
    mov $0x10f00, %edi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    mov $56, %eax
    syscall
    test %rax, %rax
    jz child
    xor %r12d, %r12d
parent:
    cmpq $1, done(%rip)
    jne parent
    xor %edi, %edi
    mov $231, %eax
    syscall
child:
#ifdef LOST
    xor %r12d, %r12d
#endif
    movq $1, done(%rip)
waiting:
    jmp waiting
.section .data
done: .quad 0
.section .note.GNU-stack,"",@progbits
