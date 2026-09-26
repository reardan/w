# win64 register context: lib/context_x86_64.w, identical to the x64
# module because the get_context/store_context stubs
# (define_asm_functions_x64_portable in code_generator/x64_asm.w) are
# pure register operations shared by the Linux and Windows x86-64 targets.
import lib.context_x86_64
