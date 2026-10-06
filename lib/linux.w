# Linux syscall wrappers. The numbers differ between i386 and x86-64, so
# the wrappers live in per-architecture modules; the reserved __arch__
# import segment binds whichever one matches the compile target.
import code_generator.integer
import lib.__arch__.syscalls


# open/pipe2 and fcntl values in the Linux numbering every lib/ caller
# passes (identical on i386, x86-64 and arm64; the arm64_darwin wrappers
# translate o_cloexec).
const int o_cloexec = 524288
const int f_getfd = 1
const int f_setfd = 2
const int fd_cloexec = 1
