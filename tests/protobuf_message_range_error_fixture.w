# expect_fail
# expect_stderr: protobuf field number must be between 1 and 536870911
import libs.extras.protobuf.message


message pbe_zero:
	int32 a = 0


int main():
	return 0
# wbuild: fixture_group=protobuf_message_error_test
