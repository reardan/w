# expect_fail
# expect_stderr: protobuf field 'a' needs a field number: '= N'
import libs.extras.protobuf.message


message pbe_unnumbered:
	int32 a
	int32 b = 2


int main():
	return 0
