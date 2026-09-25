# expect_fail
# expect_stderr: a message cannot contain itself
import libs.extras.protobuf.message


message pbe_node:
	pbe_node next = 1


int main():
	return 0
