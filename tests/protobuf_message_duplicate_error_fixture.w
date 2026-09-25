# expect_fail
# expect_stderr: duplicate protobuf field number in message 'pbe_dup'
import libs.extras.protobuf.message


message pbe_dup:
	int32 a = 1
	int32 b = 1


int main():
	return 0
# wbuild: fixture_group=protobuf_message_error_test
