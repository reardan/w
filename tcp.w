import lib

# split apart asm socket_conenct() into socket() + connect()

# add bind
# add listen
# add accept

# add setsockopt (reuse addr)
# add gethostbyaddr (lookup peer)



int server():
	# socket
	# setsockopt()  re-use,etc.
	# setup sockaddr
	# bind
	# listen
		# accept
		# gethostbyaddr
	return 0


int main(int argc, int argv):
	println("calling socket()")
	int file = socket()
	print_int("file: ", file)
	println("calling connect()")
	int connect_result = connect(file)
	print_int("connect_result: ", connect_result)
	# int file = socket_connect()
	# print_int("file: ", file)
	write_string(file, "How's it going?\x0a")
	char *buf = "0000000000000000000000000000000000000000"
	int read_result = read(file, buf, 40)
	buf[read_result] = 0

	print_int("read_result: ", read_result)
	print_string("received: ", buf)
	close(file)


	exit(0)
