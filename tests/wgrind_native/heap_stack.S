/* Both heap objects must remain reachable: a live malloc-backed stack,
 * and a pointer stored only in that thread's ABI red zone. */
.global _start
.global malloc
.type malloc,@function
.section .text
malloc:
    mov $9, %eax
    xor %edi, %edi
    mov $65536, %esi
    mov $3, %edx
    mov $34, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    ret
.size malloc, .-malloc
_start:
    mov $8, %edi
    call malloc
    mov %rax, %r12
    mov $4096, %edi
    call malloc
    mov %rax, %rbx
    lea 4000(%rax), %rsi
    mov %r12, (%rsi)
    mov $0x10f00, %edi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    mov $56, %eax
    syscall
    test %rax, %rax
    jz child
    xor %r12d, %r12d
    xor %ebx, %ebx
parent:
    cmpq $1, done(%rip)
    jne parent
    xor %edi, %edi
    mov $231, %eax
    syscall
child:
    mov (%rsp), %rax
    mov %rax, -8(%rsp)
    movq $0, (%rsp)
    xor %eax, %eax
    xor %r12d, %r12d
    xor %ebx, %ebx
    movq $1, done(%rip)
waiting:
    jmp waiting
.section .data
done: .quad 0
.section .note.GNU-stack,"",@progbits
