# https://nullprogram.com/blog/2015/05/15/
# https://nullprogram.com/blog/2016/09/23/
# new, 256 kb, write|read, anon|private|growsdown

import lib
import assert


/* int stack_create():
	# debugger
	int addr = mmap(0, 262144, 3, 290)
	print_int("mmap result addr: ", addr)
	asserts("mmap() failed in stack_create()", addr > 0)
	return addr */


/* int thread_create(int func_ptr):
	int addr = stack_create()
	# CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_PARENT | CLONE_THREAD | CLONE_IO
	sys_clone(2147585792, addr + 262144 - 8)
	return 0 */


