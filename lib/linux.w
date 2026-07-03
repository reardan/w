# Linux syscall wrappers. The numbers differ between i386 and x86-64, so
# the wrappers live in per-architecture modules; the reserved __arch__
# import segment binds whichever one matches the compile target.
import code_generator.integer
import lib.__arch__.syscalls
