# expect_fail
# expect_stderr: protobuf field numbers 19000-19999 are reserved
import libs.extras.protobuf.message


message pbe_reserved:
	int32 a = 19500


int main():
	return 0
# wbuild: fixture_group=protobuf_message_error_test
