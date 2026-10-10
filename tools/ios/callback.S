// Invoke a no-argument W function from a UIKit callback. W uses x28 as
// its evaluation stack and does not implement the AAPCS64 callee-save
// contract. Save all C callee-saved registers, including FP registers.
// Reserve 256 KiB on the native thread stack for the W callback. Keep
// the real sp below it so ordinary W locals stay in allocated stack.
.text
.p2align 2
.globl _wios_invoke
_wios_invoke:
    stp x29, x30, [sp, #-160]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mov x28, sp
    sub sp, sp, #64, lsl #12
    blr x0
    add sp, sp, #64, lsl #12
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret
