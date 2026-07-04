import lib.lib
import lib.assert
import lib.net


int main(int argc, int argv):
	int* fds = malloc(__word_size__ * 2)
	int err = socket_pair(fds)
	assert_equal(0, err)
	write_string(fds[0], c"ok")
	char* buf = malloc(3)
	int count = read(fds[1], buf, 2)
	assert_equal(2, count)
	buf[2] = 0
	assert_strings_equal(c"ok", buf)
	close(fds[0])
	close(fds[1])
	return 0
