.global _start
.section .text
_start:
    mov $9, %eax
    xor %edi, %edi
    mov $65536, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    lea 65536(%rax), %rsi
    mov $0x90f00, %edi
    xor %edx, %edx
    xor %r10d, %r10d
    lea tls(%rip), %r8
    mov $56, %eax
    syscall
    test %rax, %rax
    jz child
parent:
    cmpq $1, done(%rip)
    jne parent
    xor %edi, %edi
    mov $231, %eax
    syscall
child:
    sub $8, %rsp
    mov %rsp, %rsi
    mov $0x1003, %edi
    mov $158, %eax
    syscall
    mov (%rsp), %rax
    lea tls(%rip), %rdx
    cmp %rdx, %rax
    jne failure
    movq $1, done(%rip)
    xor %edi, %edi
    mov $60, %eax
    syscall
failure:
    mov $1, %edi
    mov $231, %eax
    syscall
.section .data
tls: .quad 42
done: .quad 0
.section .note.GNU-stack,"",@progbits
