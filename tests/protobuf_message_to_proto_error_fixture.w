# expect_fail
# expect_stderr: to_proto argument must be a protobuf message value or message pointer
import libs.extras.protobuf.message


struct pbe_plain:
	int x


int main():
	pbe_plain s
	pb_bytes* w = to_proto(s)
	return 0
