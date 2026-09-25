# expect_fail
# expect_stderr: protobuf field type 'int64' needs a 64-bit target (x64 or arm64)
# int64 storage exists only on 8-byte words (tests/protobuf_message_x64_test.w).
import libs.extras.protobuf.message


message pbe_wide:
	int64 a = 1


int main():
	return 0
# wbuild: fixture_group=protobuf_message_error_test
