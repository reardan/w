.global _start
.section .text
_start:
    sub $8, %rsp
    mov (%rsp), %r12
    mov $9, %eax
    xor %edi, %edi
    mov $65536, %esi
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
parent:
    jmp parent
child:
    test %r12, %r12
    jz failure
failure:
    xor %edi, %edi
    mov $231, %eax
    syscall
.section .note.GNU-stack,"",@progbits
