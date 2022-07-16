import lib.lib
import code_generator.integer


# try #3
int socketcall(int call, int args):
	println("socketcall()")
	int *arg1 = args + 0
	print_int("arg1: ", *arg1)
	int *arg2 = args + 4
	print_int("arg2: ", *arg2)
	int *arg3 = args + 8
	print_int("arg3: ", *arg3)
	return syscall(102, call, args)


struct socketargs:
	int protocol
	int type
	int family


int socket3(int protocol, int type, int family):
	println("socket()")
	socketargs args
	args.protocol = protocol
	args.type = type
	args.family = family

	println("calling socketcall()")
	int *ptr = args
	return socketcall(1, ptr)




# try #2
# https://cocomelonc.github.io/tutorial/2021/10/17/linux-shellcoding-2.html
int socketcall2(int call, int args):
	return syscall(102, call, args, 0)


int socket2(int* domain, int type, int protocol):
	# second arg: ???
	return socketcall(1, domain)  


int main(int argc, int argv):
	syscall(102, 1, 0, 0)
	return 0


# try #1
int sockaddr_in(int family, int port, int ip_address):
	int p = malloc(16)
	save_int16(p, family)
	save_int16(p + 2, port)
	save_int(p + 4, ip_address)
	save_int(p + 8, 0)
	save_int(p + 12, 0)
	return p


int main2(int argc, int argv):
	int file = syscall(41, 2, 2, 0)
	print_int("file = ", file)

	int ip = ip4_from_string("127.0.0.1")
	print_hex("ip: ", ip)
	int addr = sockaddr_in(2, 9999, ip)
	print_words(addr, 4)
	int result = syscall7(44, file, "hiya\x0a", 6, 0, addr, 16)
	print_int("result = ", result)

	exit(0)
