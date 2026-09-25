# expect_fail
# expect_stderr: from_proto target must be a protobuf message type
import libs.extras.protobuf.message


struct pbe_plain:
	int x


int main():
	pbe_plain* p = from_proto(pbe_plain, c"", 0)
	return 0
# wbuild: fixture_group=protobuf_message_error_test
