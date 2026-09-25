# expect_fail
# expect_stderr: message declaration requires 'import libs.extras.protobuf.message'
# A message needs the runtime's pb_bytes type at declaration time.


message pbe_no_import:
	int32 a = 1


int main():
	return 0
# wbuild: fixture_group=protobuf_message_error_test
